[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PackRoot,
    [switch]$PassThru
)

$ErrorActionPreference='Stop'
$PackRoot=(Resolve-Path -LiteralPath $PackRoot).Path
$modulePath=Join-Path (Split-Path -Parent $PSScriptRoot) 'src\CISPolicyCreator.psm1'
Import-Module $modulePath -Force
$issues=[System.Collections.Generic.List[string]]::new()

function Read-JsonFile([string]$Path,[string]$Label) {
    if (-not (Test-Path -LiteralPath $Path)) { $issues.Add("$Label missing: $Path"); return $null }
    try { return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -Depth 100 }
    catch { $issues.Add("$Label invalid JSON: $($_.Exception.Message)"); return $null }
}

$manifestPath=Join-Path $PackRoot 'manifest.json'
$manifest=Read-JsonFile $manifestPath 'manifest.json'
if (-not $manifest) {
    $result=[pscustomobject]@{ IsValid=$false; Issues=@($issues); RecommendationCounts=@{}; DeployableCount=0 }
    if ($PassThru) { return $result }
    throw ($issues -join [Environment]::NewLine)
}

foreach ($required in @('schemaVersion','id','name','version','benchmarkScope','recommendationsSpec')) {
    if (-not $manifest.$required) { $issues.Add("manifest.$required is required") }
}
if ([string]$manifest.schemaVersion -ne '1.1') { $issues.Add("manifest.schemaVersion must be 1.1") }
if ([string]$manifest.benchmarkScope -ne 'microsoft-intune') { $issues.Add("manifest.benchmarkScope must be 'microsoft-intune'; generic CIS benchmarks are out of scope") }
if ($manifest.sourceDocumentIncluded -eq $true) { $issues.Add('manifest.sourceDocumentIncluded must be false for public-safe packs') }

$recommendations=@()
$recById=@{}
if ($manifest.recommendationsSpec) {
    $recPath=Join-Path $PackRoot ([string]$manifest.recommendationsSpec)
    $raw=Read-JsonFile $recPath 'recommendations spec'
    if ($null -ne $raw) { $recommendations=@($raw) }
}
$allowedStatuses=@('mapped','manual','unresolved','not-applicable')
foreach ($r in $recommendations) {
    $id=[string]$r.recommendationId
    if (-not $id) { $issues.Add('Recommendation missing recommendationId'); continue }
    if ($recById.ContainsKey($id)) { $issues.Add("Duplicate recommendationId: $id") } else { $recById[$id]=$r }
    if (@($r.profiles).Count -eq 0) { $issues.Add("Recommendation '$id' missing profiles") }
    if ([string]$r.status -notin $allowedStatuses) { $issues.Add("Recommendation '$id' has invalid status '$($r.status)'") }
}

$referencedIds=[System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$policyCount=0; $staticCount=0; $dynamicCount=0; $graphCount=0
$policyNames=[System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

function Assert-MappedRecommendation([string]$Id,[string]$Where) {
    if (-not $Id) { $issues.Add("$Where missing recommendationId"); return }
    $null=$referencedIds.Add($Id)
    if (-not $recById.ContainsKey($Id)) { $issues.Add("$Where references unknown recommendation '$Id'"); return }
    if ([string]$recById[$Id].status -ne 'mapped') { $issues.Add("$Where references recommendation '$Id' with status '$($recById[$Id].status)' instead of mapped") }
}

if ($manifest.settingsCatalogPolicyDirectory) {
    $policyDir=Join-Path $PackRoot ([string]$manifest.settingsCatalogPolicyDirectory)
    if (-not (Test-Path -LiteralPath $policyDir)) { $issues.Add("Settings Catalog policy directory missing: $policyDir") }
    else {
        foreach ($file in Get-ChildItem -LiteralPath $policyDir -Filter '*.json' | Sort-Object Name) {
            $b=Read-JsonFile $file.FullName $file.Name
            if (-not $b) { continue }
            if ([string]$b.mappingStatus -ne 'mapped') { $issues.Add("$($file.Name): mappingStatus must be mapped") }
            if (-not $b.policy.name) { $issues.Add("$($file.Name): policy.name is required") }
            elseif (-not $policyNames.Add([string]$b.policy.name)) { $issues.Add("Duplicate policy name: $($b.policy.name)") }
            if (-not $b.policy.platforms) { $issues.Add("$($file.Name): policy.platforms is required") }
            if (-not $b.policy.technologies) { $issues.Add("$($file.Name): policy.technologies is required") }
            if (@($b.profiles).Count -eq 0) { $issues.Add("$($file.Name): profiles is required") }
            $settings=@($b.settings)
            if ($settings.Count -gt 0 -and @($b.recommendationIds).Count -eq 0) { $issues.Add("$($file.Name): static settings require recommendationIds") }
            foreach ($rid in @($b.recommendationIds)) { Assert-MappedRecommendation ([string]$rid) "$($file.Name)" }
            if (Test-CpcObjectContainsAssignments -InputObject $b) { $issues.Add("$($file.Name): assignment data is not allowed") }
            $policyCount++; $staticCount += $settings.Count
        }
    }
}

if ($manifest.settingsCatalogSpec) {
    $path=Join-Path $PackRoot ([string]$manifest.settingsCatalogSpec)
    $raw=Read-JsonFile $path 'Settings Catalog spec'
    if ($null -ne $raw) {
        $specs=@($raw); $dynamicCount=$specs.Count
        foreach ($s in $specs) {
            $label=if ($s.recommendationId) { [string]$s.recommendationId } else { [string]$s.displayName }
            if ([string]$s.mappingStatus -ne 'mapped') { $issues.Add("Dynamic setting '$label' mappingStatus must be mapped") }
            Assert-MappedRecommendation ([string]$s.recommendationId) "Dynamic setting '$label'"
            if (-not $s.policy) { $issues.Add("Dynamic setting '$label' missing policy") }
            if (-not $s.displayName) { $issues.Add("Dynamic setting '$label' missing displayName") }
            if (@($s.profiles).Count -eq 0) { $issues.Add("Dynamic setting '$label' missing profiles") }
            if (-not $s.resolve.definitionId -and (-not $s.resolve.baseUri -or -not $s.resolve.offsetUri) -and -not $s.resolve.displayName) { $issues.Add("Dynamic setting '$label' has no usable resolver") }
            if (-not $s.value -or [string]$s.value.kind -notin @('choice','integer','string')) { $issues.Add("Dynamic setting '$label' has unsupported or missing value kind") }
            if ($s.policy -and -not $policyNames.Contains([string]$s.policy)) { $issues.Add("Dynamic setting '$label' targets policy '$($s.policy)' that has no policy bundle") }
        }
    }
}

if ($manifest.graphObjects) {
    $path=Join-Path $PackRoot ([string]$manifest.graphObjects)
    $raw=Read-JsonFile $path 'Graph objects spec'
    if ($null -ne $raw) {
        $objects=@($raw); $graphCount=$objects.Count
        foreach ($o in $objects) {
            $name=[string]$o.name
            if ([string]$o.mappingStatus -ne 'mapped') { $issues.Add("Graph object '$name' mappingStatus must be mapped") }
            if (-not $name) { $issues.Add('Graph object missing name') }
            if (@($o.profiles).Count -eq 0) { $issues.Add("Graph object '$name' missing profiles") }
            if (@($o.recommendationIds).Count -eq 0) { $issues.Add("Graph object '$name' missing recommendationIds") }
            foreach ($rid in @($o.recommendationIds)) { Assert-MappedRecommendation ([string]$rid) "Graph object '$name'" }
            if (-not $o.endpoint -or -not (Test-CpcGraphEndpointSafe -Uri ([string]$o.endpoint))) { $issues.Add("Graph object '$name' has unsafe/non-deviceManagement endpoint '$($o.endpoint)'") }
            if ($o.listEndpoint -and -not (Test-CpcGraphEndpointSafe -Uri ([string]$o.listEndpoint))) { $issues.Add("Graph object '$name' has unsafe listEndpoint '$($o.listEndpoint)'") }
            if (-not $o.payload) { $issues.Add("Graph object '$name' missing payload") }
            elseif (Test-CpcObjectContainsAssignments -InputObject $o.payload) { $issues.Add("Graph object '$name' payload contains assignments") }
        }
    }
}

foreach ($r in $recommendations) {
    if ([string]$r.status -eq 'mapped' -and -not $referencedIds.Contains([string]$r.recommendationId)) {
        $issues.Add("Recommendation '$($r.recommendationId)' is marked mapped but is not referenced by any deployable object")
    }
}

$statusCounts=[ordered]@{}
foreach ($status in $allowedStatuses) { $statusCounts[$status]=@($recommendations | Where-Object { [string]$_.status -eq $status }).Count }
$result=[pscustomobject]@{
    IsValid=($issues.Count -eq 0)
    Issues=@($issues)
    RecommendationCounts=$statusCounts
    SettingsCatalogPolicies=$policyCount
    StaticSettings=$staticCount
    DynamicSettings=$dynamicCount
    GraphObjects=$graphCount
    DeployableCount=($staticCount+$dynamicCount+$graphCount)
}

if ($PassThru) { return $result }
if (-not $result.IsValid) {
    Write-Host "FAILED: $($issues.Count) validation issue(s)"
    $issues | ForEach-Object { Write-Host " - $_" }
    exit 1
}
Write-Host 'PASS: CISPolicyCreator policy pack structural + fail-closed checks succeeded.'
Write-Host "Recommendations            : $($recommendations.Count) (mapped=$($statusCounts.mapped), manual=$($statusCounts.manual), unresolved=$($statusCounts.unresolved), not-applicable=$($statusCounts['not-applicable']))"
Write-Host "Settings Catalog policies : $policyCount"
Write-Host "Static embedded settings   : $staticCount"
Write-Host "Dynamic setting specs      : $dynamicCount"
Write-Host "Generic Graph objects      : $graphCount"
Write-Host 'Assignments                : none'
