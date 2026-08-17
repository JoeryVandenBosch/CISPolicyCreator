[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PackRoot,
    [switch]$PassThru
)

$ErrorActionPreference='Stop'
$PackRoot=(Resolve-Path -LiteralPath $PackRoot).Path
$modulePath=Join-Path (Split-Path -Parent $PSScriptRoot) 'src\CISPolicyCreator.psm1'
Import-Module $modulePath -Force -DisableNameChecking
$issues=[System.Collections.Generic.List[string]]::new()
$pathComparison=if($IsWindows){[StringComparison]::OrdinalIgnoreCase}else{[StringComparison]::Ordinal}

# A lexical in-root path can still escape through a symlink/junction. Reject links before reading the manifest.
try {
    $packEntries=@(Get-Item -LiteralPath $PackRoot -Force -ErrorAction Stop)+@(Get-ChildItem -LiteralPath $PackRoot -Recurse -Force -ErrorAction Stop)
    foreach($entry in $packEntries){
        $linkTypeProperty=$entry.PSObject.Properties['LinkType']
        $isLink=(($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) -or ($linkTypeProperty -and $linkTypeProperty.Value)
        if($isLink){
            $displayPath=if($entry.FullName -eq $PackRoot){'. (pack root)'}else{$entry.FullName.Substring($PackRoot.Length+1)}
            $issues.Add("Filesystem links are not allowed in a policy pack: $displayPath")
        }
    }
} catch {$issues.Add("Could not safely enumerate policy pack paths: $($_.Exception.Message)")}
if($issues.Count -gt 0){
    $result=[pscustomobject]@{IsValid=$false;Issues=@($issues);RecommendationCounts=@{};DeployableCount=0}
    if($PassThru){return $result}
    throw ($issues -join [Environment]::NewLine)
}

function Read-JsonFile([string]$Path,[string]$Label) {
    if (-not (Test-Path -LiteralPath $Path)) { $issues.Add("$Label missing: $Path"); return $null }
    try { return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -Depth 100 }
    catch { $issues.Add("$Label invalid JSON: $($_.Exception.Message)"); return $null }
}

function Assert-JsonSchema([string]$Path,[string]$SchemaName,[string]$Label) {
    $schemaPath=Join-Path (Split-Path -Parent $PSScriptRoot) "schemas\$SchemaName"
    try {
        $json=Get-Content -LiteralPath $Path -Raw
        if (-not ($json | Test-Json -SchemaFile $schemaPath -ErrorAction Stop)) { $issues.Add("$Label does not satisfy $SchemaName") }
    } catch { $issues.Add("$Label does not satisfy $SchemaName`: $($_.Exception.Message)") }
}

function Resolve-PackPath([string]$RelativePath,[string]$Label) {
    if ([string]::IsNullOrWhiteSpace($RelativePath)) { return $null }
    if ([IO.Path]::IsPathRooted($RelativePath)) { $issues.Add("$Label must be relative to the pack root"); return $null }
    $full=[IO.Path]::GetFullPath((Join-Path $PackRoot $RelativePath))
    $prefix=$PackRoot.TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
    if (-not $full.StartsWith($prefix,$pathComparison)) { $issues.Add("$Label escapes the pack root"); return $null }
    if (Test-Path -LiteralPath $full) {
        $resolved=(Resolve-Path -LiteralPath $full).Path
        if (-not $resolved.StartsWith($prefix,$pathComparison)) { $issues.Add("$Label resolves through a link outside the pack root"); return $null }
    }
    return $full
}

foreach ($privateArtifact in Get-ChildItem -LiteralPath $PackRoot -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in @('.pdf','.zip','.7z','.xlsx') -or $_.Name -eq 'recommendations.raw.json' -or $_.Name -like '*.private-extraction.json' }) {
    $issues.Add("Private/source artifact is not allowed in a policy pack: $($privateArtifact.FullName.Substring($PackRoot.Length+1))")
}

$manifestPath=Join-Path $PackRoot 'manifest.json'
$manifest=Read-JsonFile $manifestPath 'manifest.json'
if (-not $manifest) {
    $result=[pscustomobject]@{ IsValid=$false; Issues=@($issues); RecommendationCounts=@{}; DeployableCount=0 }
    if ($PassThru) { return $result }
    throw ($issues -join [Environment]::NewLine)
}
if ([string]$manifest.schemaVersion -ne '2.0') {
    $issues.Add("manifest.schemaVersion must be 2.0; older packs require explicit migration")
} else { Assert-JsonSchema $manifestPath 'manifest.schema.json' 'manifest.json' }

foreach ($required in @('schemaVersion','id','name','version','benchmarkScope','recommendationsSpec')) {
    if (-not $manifest.$required) { $issues.Add("manifest.$required is required") }
}
if ([string]$manifest.benchmarkScope -ne 'microsoft-intune') { $issues.Add("manifest.benchmarkScope must be 'microsoft-intune'; generic CIS benchmarks are out of scope") }
if ($manifest.sourceDocumentIncluded -eq $true) { $issues.Add('manifest.sourceDocumentIncluded must be false for public-safe packs') }
if ($manifest.settingsCatalogProbe) {
    $probe=$manifest.settingsCatalogProbe
    if (Test-CpcObjectContainsAssignments -InputObject $probe) { $issues.Add('settingsCatalogProbe contains assignment data') }
}

$recommendations=@()
$recById=@{}
if ($manifest.recommendationsSpec) {
    $recPath=Resolve-PackPath ([string]$manifest.recommendationsSpec) 'manifest.recommendationsSpec'
    if ($recPath) {
        $raw=Read-JsonFile $recPath 'recommendations spec'
        if ($null -ne $raw) { Assert-JsonSchema $recPath 'recommendations.schema.json' 'recommendations spec'; $recommendations=@($raw) }
    }
}
$allowedStatuses=@('mapped','unresolved','requires-input','manual','not-applicable')
foreach ($r in $recommendations) {
    $id=[string]$r.recommendationId
    if (-not $id) { $issues.Add('Recommendation missing recommendationId'); continue }
    if ($recById.ContainsKey($id)) { $issues.Add("Duplicate recommendationId: $id") } else { $recById[$id]=$r }
    if (@($r.profiles).Count -eq 0) { $issues.Add("Recommendation '$id' missing profiles") }
    $catalogStatusProperty=$r.PSObject.Properties['catalogMappingStatus']
    $decisionRefProperty=$r.PSObject.Properties['decisionRef']
    if ([string]$r.cisAssessmentMethod -notin @('Manual','Automated')) { $issues.Add("Recommendation '$id' has invalid cisAssessmentMethod '$($r.cisAssessmentMethod)'") }
    if ([string]$r.mappingStatus -notin $allowedStatuses) { $issues.Add("Recommendation '$id' has invalid mappingStatus '$($r.mappingStatus)'") }
    if ([string]$r.mappingStatus -eq 'mapped' -and @($r.implementationRefs).Count -eq 0) { $issues.Add("Recommendation '$id' is mapped but has no implementationRefs") }
    if ([string]$r.mappingStatus -eq 'requires-input' -and (-not $decisionRefProperty -or -not $decisionRefProperty.Value)) { $issues.Add("Recommendation '$id' requires-input but has no decisionRef") }
    if ($catalogStatusProperty -and [string]$catalogStatusProperty.Value -eq 'requires-input' -and ([string]$r.mappingStatus -eq 'mapped') -and (-not $decisionRefProperty -or -not $decisionRefProperty.Value)) { $issues.Add("Recommendation '$id' was resolved from requires-input without decisionRef provenance") }
}

$referencedIds=[System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$policyCount=0; $staticCount=0; $dynamicCount=0; $graphCount=0
$policyNames=[System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$policyMetadata=@{}
$graphNames=[System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$dynamicKeys=[System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$settingsCatalogSpecs=@()

function Assert-MappedRecommendation([string]$Id,[string]$Where,$Profiles) {
    if (-not $Id) { $issues.Add("$Where missing recommendationId"); return }
    $null=$referencedIds.Add($Id)
    if (-not $recById.ContainsKey($Id)) { $issues.Add("$Where references unknown recommendation '$Id'"); return }
    if ([string]$recById[$Id].mappingStatus -ne 'mapped') { $issues.Add("$Where references recommendation '$Id' with mappingStatus '$($recById[$Id].mappingStatus)' instead of mapped") }
    $recommendationProfiles=@($recById[$Id].profiles | ForEach-Object { ([string]$_).ToUpperInvariant() })
    foreach ($profile in @($Profiles)) {
        if ($recommendationProfiles -notcontains ([string]$profile).ToUpperInvariant()) { $issues.Add("$Where profile '$profile' is not declared by recommendation '$Id'") }
    }
}

function Test-DynamicSettingNode($Node,[string]$Label,[int]$Depth=0) {
    if($Depth -gt 16){$issues.Add("$Label exceeds the maximum nested Settings Catalog depth");return}
    if(-not $Node){$issues.Add("$Label is missing");return}
    if(-not $Node.displayName){$issues.Add("$Label missing displayName")}
    if(-not $Node.resolve -or (-not $Node.resolve.definitionId -and (-not $Node.resolve.baseUri -or -not $Node.resolve.offsetUri))){$issues.Add("$Label must have an explicit definitionId or exact baseUri + offsetUri")}
    if(-not $Node.resolve.expectedType){$issues.Add("$Label missing expectedType")}
    if(-not $Node.value){$issues.Add("$Label missing value");return}
    $kind=[string]$Node.value.kind
    if($kind -notin @('choice','integer','string','integer-collection','string-collection','group-collection')){$issues.Add("$Label has unsupported or missing value kind");return}
    $allowedValueProperties=switch($kind){
        'choice' {@('kind','optionId','children')}
        {$_ -in @('integer','string')} {@('kind','value')}
        {$_ -in @('integer-collection','string-collection')} {@('kind','values')}
        'group-collection' {@('kind','items')}
        default {@('kind')}
    }
    $unexpectedValueProperties=@($Node.value.PSObject.Properties.Name | Where-Object { $allowedValueProperties -notcontains [string]$_ })
    if($unexpectedValueProperties.Count -gt 0){$issues.Add("$Label value kind '$kind' contains incompatible properties: $($unexpectedValueProperties -join ', ')")}

    switch($kind){
        'choice' {
            if(-not $Node.value.optionId){$issues.Add("$Label requires an exact reviewed optionId")}
            $childrenProperty=$Node.value.PSObject.Properties['children']
            $children=if($childrenProperty){@($childrenProperty.Value)}else{@()}
            $childIndex=0
            foreach($child in $children){$childIndex++;Test-DynamicSettingNode $child "$Label choice child $childIndex" ($Depth+1)}
        }
        {$_ -in @('integer','string')} {
            $valueProperty=$Node.value.PSObject.Properties['value']
            if(-not $valueProperty -or $null -eq $valueProperty.Value){$issues.Add("$Label requires a simple value")}
            elseif($kind -eq 'integer' -and $valueProperty.Value -isnot [byte] -and $valueProperty.Value -isnot [int16] -and $valueProperty.Value -isnot [int32] -and $valueProperty.Value -isnot [int64]){$issues.Add("$Label requires an integer value")}
            elseif($kind -eq 'string' -and $valueProperty.Value -isnot [string]){$issues.Add("$Label requires a string value")}
        }
        {$_ -in @('integer-collection','string-collection')} {
            $valuesProperty=$Node.value.PSObject.Properties['values']
            $values=if($valuesProperty){@($valuesProperty.Value)}else{@()}
            if($values.Count -eq 0){$issues.Add("$Label requires at least one collection value")}
            $valueIndex=0
            foreach($itemValue in $values){
                $valueIndex++
                if($kind -eq 'integer-collection' -and $itemValue -isnot [byte] -and $itemValue -isnot [int16] -and $itemValue -isnot [int32] -and $itemValue -isnot [int64]){$issues.Add("$Label collection value $valueIndex must be an integer")}
                if($kind -eq 'string-collection' -and $itemValue -isnot [string]){$issues.Add("$Label collection value $valueIndex must be a string")}
            }
        }
        'group-collection' {
            $itemsProperty=$Node.value.PSObject.Properties['items']
            $items=if($itemsProperty){@($itemsProperty.Value)}else{@()}
            if($items.Count -eq 0){$issues.Add("$Label requires at least one group item")}
            $itemIndex=0
            foreach($item in $items){
                $itemIndex++
                $childrenProperty=$item.PSObject.Properties['children']
                $children=if($childrenProperty){@($childrenProperty.Value)}else{@()}
                if($children.Count -eq 0){$issues.Add("$Label group item $itemIndex requires at least one child")}
                $childIndex=0
                foreach($child in $children){$childIndex++;Test-DynamicSettingNode $child "$Label group item $itemIndex child $childIndex" ($Depth+1)}
            }
        }
    }
}

if ($manifest.settingsCatalogPolicyDirectory) {
    $policyDir=Resolve-PackPath ([string]$manifest.settingsCatalogPolicyDirectory) 'manifest.settingsCatalogPolicyDirectory'
    if (-not $policyDir) {}
    elseif (-not (Test-Path -LiteralPath $policyDir)) { $issues.Add("Settings Catalog policy directory missing: $policyDir") }
    else {
        foreach ($file in Get-ChildItem -LiteralPath $policyDir -Filter '*.json' | Sort-Object Name) {
            $b=Read-JsonFile $file.FullName $file.Name
            if (-not $b) { continue }
            Assert-JsonSchema $file.FullName 'policy-bundle.schema.json' $file.Name
            if ([string]$b.mappingStatus -ne 'mapped') { $issues.Add("$($file.Name): mappingStatus must be mapped") }
            if (-not $b.policy.name) { $issues.Add("$($file.Name): policy.name is required") }
            elseif (-not $policyNames.Add([string]$b.policy.name)) { $issues.Add("Duplicate policy name: $($b.policy.name)") }
            else { $policyMetadata[[string]$b.policy.name]=$b.policy }
            if (-not $b.policy.platforms) { $issues.Add("$($file.Name): policy.platforms is required") }
            if (-not $b.policy.technologies) { $issues.Add("$($file.Name): policy.technologies is required") }
            if (@($b.profiles).Count -eq 0) { $issues.Add("$($file.Name): profiles is required") }
            $settings=@($b.settings)
            if ($settings.Count -gt 0) { $issues.Add("$($file.Name): static embedded settings are not allowed in schema 2.0; use the validated dynamic Settings Catalog spec") }
            foreach ($rid in @($b.recommendationIds)) { Assert-MappedRecommendation ([string]$rid) "$($file.Name)" $b.profiles }
            if (Test-CpcObjectContainsAssignments -InputObject $b) { $issues.Add("$($file.Name): assignment data is not allowed") }
            $policyCount++; $staticCount += $settings.Count
        }
    }
}

if ($manifest.settingsCatalogSpec) {
    $path=Resolve-PackPath ([string]$manifest.settingsCatalogSpec) 'manifest.settingsCatalogSpec'
    $raw=if ($path) { Read-JsonFile $path 'Settings Catalog spec' } else { $null }
    if ($null -ne $raw -and $path) {
        Assert-JsonSchema $path 'settings-catalog.schema.json' 'Settings Catalog spec'
        $settingsCatalogSpecs=@($raw); $dynamicCount=$settingsCatalogSpecs.Count
        foreach ($s in $settingsCatalogSpecs) {
            $label=if ($s.recommendationId) { [string]$s.recommendationId } else { [string]$s.displayName }
            if ([string]$s.mappingStatus -ne 'mapped') { $issues.Add("Dynamic setting '$label' mappingStatus must be mapped") }
            Assert-MappedRecommendation ([string]$s.recommendationId) "Dynamic setting '$label'" $s.profiles
            if (-not $s.policy) { $issues.Add("Dynamic setting '$label' missing policy") }
            if (-not $s.displayName) { $issues.Add("Dynamic setting '$label' missing displayName") }
            if (@($s.profiles).Count -eq 0) { $issues.Add("Dynamic setting '$label' missing profiles") }
            if (-not $s.resolve.definitionId -and (-not $s.resolve.baseUri -or -not $s.resolve.offsetUri)) { $issues.Add("Dynamic setting '$label' must have an explicit definitionId or exact baseUri + offsetUri") }
            else {
                $resolverKey=if($s.resolve.definitionId){'id:'+[string]$s.resolve.definitionId}else{'path:'+([string]$s.resolve.baseUri).TrimEnd('/')+'|'+[string]$s.resolve.offsetUri}
                if(-not $dynamicKeys.Add(([string]$s.policy)+'|'+$resolverKey)){ $issues.Add("Dynamic setting '$label' duplicates a definition resolver within policy '$($s.policy)'") }
            }
            Test-DynamicSettingNode $s "Dynamic setting '$label'" 0
            if ($s.policy -and -not $policyNames.Contains([string]$s.policy)) { $issues.Add("Dynamic setting '$label' targets policy '$($s.policy)' that has no policy bundle") }
        }
    }
}

if($manifest.settingsCatalogProbe){
    $probe=$manifest.settingsCatalogProbe
    $requiredProbeProperties=@('recommendationId','policy','displayName','platforms','technologies','resolve','value')
    $probeShapeReady=@($requiredProbeProperties | Where-Object { $null -eq $probe.PSObject.Properties[$_] }).Count -eq 0 -and $null -ne $probe.resolve -and $null -ne $probe.value
    if($probeShapeReady){
        $requiredResolverProperties=@('definitionId','baseUri','offsetUri','expectedType')
        $probeShapeReady=@($requiredResolverProperties | Where-Object { $null -eq $probe.resolve.PSObject.Properties[$_] }).Count -eq 0 -and $null -ne $probe.value.PSObject.Properties['kind']
    }
    if($probeShapeReady){
        $probeMatches=@($settingsCatalogSpecs | Where-Object {
            [string]$_.recommendationId -ceq [string]$probe.recommendationId -and
            [string]$_.policy -ceq [string]$probe.policy -and
            [string]$_.displayName -ceq [string]$probe.displayName -and
            [string]$_.resolve.definitionId -ceq [string]$probe.resolve.definitionId
        })
        if($probeMatches.Count -ne 1){
            $issues.Add("settingsCatalogProbe must match exactly one generated dynamic setting; matches=$($probeMatches.Count)")
        }else{
            $sourceSetting=$probeMatches[0]
            foreach($propertyName in $requiredResolverProperties){
                $probeValue=$probe.resolve.PSObject.Properties[$propertyName].Value
                $sourceValue=$sourceSetting.resolve.PSObject.Properties[$propertyName].Value
                if(($null -eq $probeValue) -ne ($null -eq $sourceValue) -or ($null -ne $probeValue -and [string]$probeValue -cne [string]$sourceValue)){
                    $issues.Add("settingsCatalogProbe resolver '$propertyName' differs from its generated dynamic setting")
                }
            }
            $kind=[string]$probe.value.kind
            if($kind -cne [string]$sourceSetting.value.kind){$issues.Add('settingsCatalogProbe value kind differs from its generated dynamic setting')}
            elseif($kind -eq 'choice'){
                $probeOption=$probe.value.PSObject.Properties['optionId']
                if($probeOption -and [string]$probeOption.Value -cne [string]$sourceSetting.value.optionId){$issues.Add('settingsCatalogProbe optionId differs from its generated dynamic setting')}
                $sourceChildren=$sourceSetting.value.PSObject.Properties['children']
                if($sourceChildren -and @($sourceChildren.Value).Count -gt 0){$issues.Add('settingsCatalogProbe cannot omit choice-dependent children')}
            }elseif($kind -eq 'integer'){
                $probeSimpleValue=$probe.value.PSObject.Properties['value']
                if($probeSimpleValue -and ($probeSimpleValue.Value -is [byte] -or $probeSimpleValue.Value -is [int16] -or $probeSimpleValue.Value -is [int32] -or $probeSimpleValue.Value -is [int64])){
                    if([int64]$probeSimpleValue.Value -ne [int64]$sourceSetting.value.value){$issues.Add('settingsCatalogProbe integer differs from its generated dynamic setting')}
                }
            }elseif($kind -eq 'string'){
                $probeSimpleValue=$probe.value.PSObject.Properties['value']
                if($probeSimpleValue -and $probeSimpleValue.Value -is [string] -and [string]$probeSimpleValue.Value -cne [string]$sourceSetting.value.value){$issues.Add('settingsCatalogProbe string differs from its generated dynamic setting')}
            }
        }
        if(-not $policyMetadata.ContainsKey([string]$probe.policy)){
            $issues.Add("settingsCatalogProbe targets missing policy '$($probe.policy)'")
        }else{
            $probePolicy=$policyMetadata[[string]$probe.policy]
            if([string]$probe.platforms -cne [string]$probePolicy.platforms){$issues.Add('settingsCatalogProbe platforms differs from its policy bundle')}
            if([string]$probe.technologies -cne [string]$probePolicy.technologies){$issues.Add('settingsCatalogProbe technologies differs from its policy bundle')}
        }
    }
}

if ($manifest.graphObjects) {
    $path=Resolve-PackPath ([string]$manifest.graphObjects) 'manifest.graphObjects'
    $raw=if ($path) { Read-JsonFile $path 'Graph objects spec' } else { $null }
    if ($null -ne $raw -and $path) {
        Assert-JsonSchema $path 'graph-objects.schema.json' 'Graph objects spec'
        $objects=@($raw); $graphCount=$objects.Count
        foreach ($o in $objects) {
            $name=[string]$o.name
            if ([string]$o.mappingStatus -ne 'mapped') { $issues.Add("Graph object '$name' mappingStatus must be mapped") }
            if (-not $name) { $issues.Add('Graph object missing name') }
            elseif (-not $graphNames.Add($name)) { $issues.Add("Duplicate Graph object name: $name") }
            if (@($o.profiles).Count -eq 0) { $issues.Add("Graph object '$name' missing profiles") }
            if (@($o.recommendationIds).Count -eq 0) { $issues.Add("Graph object '$name' missing recommendationIds") }
            foreach ($rid in @($o.recommendationIds)) { Assert-MappedRecommendation ([string]$rid) "Graph object '$name'" $o.profiles }
            try {
                $contractInfo=Get-CpcGraphObjectContract -ContractId ([string]$o.contractId) -ExpectedSha256 ([string]$o.contractSha256) -RepoRoot (Split-Path -Parent $PSScriptRoot)
                Assert-CpcGraphObjectMatchesContract -GraphObject $o -Contract $contractInfo.Contract
            } catch {$issues.Add("Graph object '$name' failed its pinned contract: $($_.Exception.Message)")}
            if (-not $o.endpoint -or -not (Test-CpcGraphEndpointSafe -Uri ([string]$o.endpoint))) { $issues.Add("Graph object '$name' has unsafe/non-deviceManagement endpoint '$($o.endpoint)'") }
            if ($o.listEndpoint -and -not (Test-CpcGraphEndpointSafe -Uri ([string]$o.listEndpoint))) { $issues.Add("Graph object '$name' has unsafe listEndpoint '$($o.listEndpoint)'") }
            if (-not $o.payload) { $issues.Add("Graph object '$name' missing payload") }
            elseif (Test-CpcObjectContainsAssignments -InputObject $o.payload) { $issues.Add("Graph object '$name' payload contains assignments") }
        }
    }
}

foreach ($r in $recommendations) {
    if ([string]$r.mappingStatus -eq 'mapped' -and -not $referencedIds.Contains([string]$r.recommendationId)) {
        $issues.Add("Recommendation '$($r.recommendationId)' is marked mapped but is not referenced by any deployable object")
    }
}

$statusCounts=[ordered]@{}
foreach ($status in $allowedStatuses) { $statusCounts[$status]=@($recommendations | Where-Object { [string]$_.mappingStatus -eq $status }).Count }
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
Write-Host "Recommendations            : $($recommendations.Count) (mapped=$($statusCounts.mapped), unresolved=$($statusCounts.unresolved), requires-input=$($statusCounts['requires-input']), manual=$($statusCounts.manual), not-applicable=$($statusCounts['not-applicable']))"
Write-Host "Settings Catalog policies : $policyCount"
Write-Host "Static embedded settings   : $staticCount"
Write-Host "Dynamic setting specs      : $dynamicCount"
Write-Host "Generic Graph objects      : $graphCount"
Write-Host 'Assignments                : none'
