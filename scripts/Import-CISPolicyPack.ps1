[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PackRoot,
    [string]$Profile='L1',
    [switch]$DryRun,
    [switch]$StopOnError,
    [switch]$ContinueOnError,
    [string]$TenantId,
    [switch]$UseDeviceCode,
    [switch]$UseExistingGraphContext,
    [switch]$ProbeOnly,
    [switch]$ConfirmUnassignedImport,
    [switch]$ConfirmTemporaryWriteProbe,
    [switch]$ConfirmPartialPack
)

$ErrorActionPreference='Stop'
if ($StopOnError -and $ContinueOnError) { throw 'StopOnError and ContinueOnError cannot be used together.' }
if ($UseDeviceCode -and $UseExistingGraphContext) { throw 'UseDeviceCode and UseExistingGraphContext cannot be combined.' }
if ($DryRun -and $ProbeOnly) { throw 'DryRun and ProbeOnly cannot be used together.' }
if ($DryRun) {
    if ($ConfirmUnassignedImport -or $ConfirmTemporaryWriteProbe -or $ConfirmPartialPack) { throw 'DryRun is read-only and cannot be combined with an import or write acknowledgement.' }
} elseif ($ProbeOnly) {
    if (-not $TenantId) { throw 'ProbeOnly requires an explicit TenantId before pack validation or Graph authentication.' }
    if (-not $ConfirmTemporaryWriteProbe) { throw 'ProbeOnly requires -ConfirmTemporaryWriteProbe before pack validation or Graph authentication.' }
    if ($ConfirmUnassignedImport) { throw 'ProbeOnly cannot be combined with ConfirmUnassignedImport.' }
    if ($ConfirmPartialPack) { throw 'ProbeOnly cannot be combined with ConfirmPartialPack.' }
} else {
    if (-not $TenantId) { throw 'Import requires an explicit TenantId before pack validation or Graph authentication.' }
    if (-not $ConfirmUnassignedImport) { throw 'Import requires -ConfirmUnassignedImport before pack validation or Graph authentication.' }
    if ($ConfirmTemporaryWriteProbe) { throw 'Import cannot be combined with ConfirmTemporaryWriteProbe.' }
}
$stopOnCreateError = -not $ContinueOnError
$PackRoot=(Resolve-Path -LiteralPath $PackRoot).Path
$repoRoot=Split-Path -Parent $PSScriptRoot
$modulePath=Join-Path $repoRoot 'src\CISPolicyCreator.psm1'
Import-Module $modulePath -Force -DisableNameChecking

# Fail closed before authentication or writes.
$validation=& (Join-Path $PSScriptRoot 'Test-CISPolicyPack.ps1') -PackRoot $PackRoot -PassThru
if (-not $validation.IsValid) {
    $text=($validation.Issues | ForEach-Object { " - $_" }) -join [Environment]::NewLine
    throw "Policy pack failed fail-closed validation. No Graph connection was made.`n$text"
}

$manifest=Get-Content -LiteralPath (Join-Path $PackRoot 'manifest.json') -Raw | ConvertFrom-Json -Depth 100
if ($ProbeOnly -and -not $manifest.settingsCatalogProbe) { throw 'Pack does not define settingsCatalogProbe in manifest.json. No Graph connection was made.' }
if (-not $DryRun -and -not $ProbeOnly) {
    $recommendationsPath=Join-Path $PackRoot ([string]$manifest.recommendationsSpec)
    $recommendations=@(Get-Content -LiteralPath $recommendationsPath -Raw | ConvertFrom-Json -Depth 100)
    $unresolvedCount=@($recommendations | Where-Object mappingStatus -eq 'unresolved').Count
    $requiresInputCount=@($recommendations | Where-Object mappingStatus -eq 'requires-input').Count
    if (($unresolvedCount+$requiresInputCount) -gt 0) {
        if (-not $ConfirmPartialPack) {
            throw "Import of a partial pack requires -ConfirmPartialPack before Graph authentication. Unresolved=$unresolvedCount; requires-input=$requiresInputCount."
        }
        Write-Warning "Partial-pack import explicitly acknowledged: unresolved=$unresolvedCount; requires-input=$requiresInputCount. Those recommendations emit no policy implementation."
    }
}

& (Join-Path $PSScriptRoot 'Import-CISGraphAuthentication.ps1')

$graphScope=if ($DryRun -and -not $ProbeOnly) { 'DeviceManagementConfiguration.Read.All' } else { 'DeviceManagementConfiguration.ReadWrite.All' }
$ownsGraphConnection=-not $UseExistingGraphContext
if($UseExistingGraphContext){
    $context=Get-MgContext
    if(-not $context){throw 'UseExistingGraphContext requires an authenticated Microsoft Graph context.'}
    $availableScopes=@($context.Scopes)
    $scopeAccepted=if($graphScope -eq 'DeviceManagementConfiguration.Read.All'){
        $availableScopes -contains 'DeviceManagementConfiguration.Read.All' -or $availableScopes -contains 'DeviceManagementConfiguration.ReadWrite.All'
    }else{
        $availableScopes -contains 'DeviceManagementConfiguration.ReadWrite.All'
    }
    if(-not $scopeAccepted){throw "The existing Microsoft Graph context lacks required scope '$graphScope'."}
}else{
    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
    $connectArgs=@{ Scopes=$graphScope; ContextScope='Process'; NoWelcome=$true }
    if ($TenantId) { $connectArgs.TenantId=$TenantId } else { Write-Warning 'Dry-run TenantId was not pinned. For production-quality testing, pass -TenantId explicitly.' }
    if ($UseDeviceCode) { $connectArgs.UseDeviceCode=$true }
    Connect-MgGraph @connectArgs
    $context=Get-MgContext
}
if ($TenantId -and $context.TenantId -ne $TenantId) { throw "Authenticated tenant '$($context.TenantId)' does not match requested TenantId '$TenantId'." }
Write-Host "Graph account : $($context.Account)"
Write-Host "Graph tenant  : $($context.TenantId)"
Write-Host "Graph app     : $($context.AppName)"
Write-Host "Graph scopes  : $((@($context.Scopes) -join ', '))"
try {
    $org=Invoke-MgGraphRequest -Method GET -Uri 'https://graph.microsoft.com/v1.0/organization?$select=id,displayName,verifiedDomains'
    $orgItem=@($org.value)[0]
    if ($orgItem) {
        $domains=@($orgItem.verifiedDomains | Where-Object isDefault | ForEach-Object name) -join ', '
        Write-Host "Organization   : $($orgItem.displayName) [$($orgItem.id)] defaultDomain=$domains"
    }
} catch { Write-Warning "Could not read organization metadata: $($_.Exception.Message)" }

$results=[System.Collections.Generic.List[object]]::new()
$resultWritten=$false

function Save-CpcImportResults {
    if ($resultWritten -or $results.Count -eq 0) { return $null }
    $stamp=Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $path=Join-Path $PackRoot "import-results-$stamp.json"
    $results | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $path -Encoding utf8
    $script:resultWritten=$true
    return $path
}

function Invoke-SettingsCatalogProbe {
    param([Parameter(Mandatory)]$Probe)
    if (-not $Probe) { throw 'Pack does not define settingsCatalogProbe in manifest.json.' }
    $spec=[pscustomobject]@{ displayName=[string]$Probe.displayName; resolve=$Probe.resolve; value=$Probe.value }
    $definitions=Invoke-CpcGraphPaged 'https://graph.microsoft.com/beta/deviceManagement/configurationSettings?$top=500'
    $def=Get-CpcSettingDefinition -Spec $spec -Definitions $definitions
    $setting=New-CpcConfigurationSettingBody -Definition $def -Spec $spec
    $probePolicy=[pscustomobject]@{
        name="CISPolicyCreator Write Probe $(Get-Date -Format 'yyyyMMdd-HHmmss')"
        description='Temporary unassigned Settings Catalog deep-create probe. Deleted immediately after creation.'
        platforms=[string]$Probe.platforms; technologies=[string]$Probe.technologies; roleScopeTagIds=@('0'); templateReference=$null
    }
    $body=New-CpcSettingsCatalogPolicyBody -Policy $probePolicy -Settings @($setting)
    Write-Host "Running Settings Catalog deep-create probe in tenant $($context.TenantId)..."
    $created=$null
    try {
        $created=Invoke-MgGraphRequest -Method POST -Uri 'https://graph.microsoft.com/beta/deviceManagement/configurationPolicies' -ContentType 'application/json' -Body ($body | ConvertTo-Json -Depth 100)
        Write-Host "WRITE PROBE PASS: created temporary policy $($created.id)."
    } finally {
        if ($created -and $created.id) {
            Invoke-MgGraphRequest -Method DELETE -Uri "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies/$($created.id)" | Out-Null
            Write-Host 'WRITE PROBE CLEANUP PASS: temporary policy deleted.'
        }
    }
}

try {
    if ($ProbeOnly) { Invoke-SettingsCatalogProbe -Probe $manifest.settingsCatalogProbe; return }

    Write-Host "Pack           : $($manifest.name) $($manifest.version)"
    Write-Host "Profile        : $Profile"
    Write-Host "Fail-closed    : enabled"

    # Phase 1: resolve every selected dynamic mapping before any create request.
    $definitions=@(); $dynamicSpecs=@(); $dynamicByPolicy=@{}; $mappingFailures=[System.Collections.Generic.List[string]]::new(); $definitionCache=@{}
    if ($manifest.settingsCatalogSpec) {
        $specPath=Join-Path $PackRoot ([string]$manifest.settingsCatalogSpec)
        if (Test-Path -LiteralPath $specPath) {
            $dynamicSpecs=@(Get-Content -LiteralPath $specPath -Raw | ConvertFrom-Json -Depth 100)
            $pathResolvedSpecs=@($dynamicSpecs | Where-Object { -not $_.resolve.definitionId })
            if ($pathResolvedSpecs.Count -gt 0) {
                Write-Host 'Loading current Settings Catalog definitions from Microsoft Graph...'
                $definitions=Invoke-CpcGraphPaged 'https://graph.microsoft.com/beta/deviceManagement/configurationSettings?$top=500'
            } elseif ($dynamicSpecs.Count -gt 0) {
                Write-Host 'Every Settings Catalog mapping uses an explicit definition ID; validating definitions individually.'
            }
        }
    }

    foreach ($spec in $dynamicSpecs) {
        $label="$($spec.recommendationId) $($spec.displayName)"
        if (-not (Test-CpcProfileSelected -Profiles $spec.profiles -Selector $Profile)) {
            Add-CpcResult -Results $results -Stage 'dynamic-setting' -Name $label -Status 'skipped-profile' -Detail "Profile selector: $Profile"
            continue
        }
        try {
            $def=Get-CpcSettingDefinition -Spec $spec -Definitions $definitions -Cache $definitionCache
            $body=New-CpcConfigurationSettingBody -Definition $def -Spec $spec -Definitions $definitions -DefinitionCache $definitionCache
            $policyName=[string]$spec.policy
            if (-not $dynamicByPolicy.ContainsKey($policyName)) { $dynamicByPolicy[$policyName]=[System.Collections.Generic.List[object]]::new() }
            $dynamicByPolicy[$policyName].Add([pscustomobject]@{ spec=$spec; definition=$def; body=$body; label=$label })
            $preview=switch([string]$spec.value.kind){
                'choice' {[string]$spec.value.optionId}
                'integer' {[string]$spec.value.value}
                'string' {[string]$spec.value.value}
                'integer-collection' {"$(@($spec.value.values).Count) integer values"}
                'string-collection' {"$(@($spec.value.values).Count) string values"}
                'group-collection' {"$(@($spec.value.items).Count) group values"}
                default {'unsupported'}
            }
            Add-CpcResult -Results $results -Stage 'dynamic-setting' -Name $label -Status 'validated' -Detail "$policyName :: $($def.id) :: value=$preview"
            if ($DryRun) { Write-Host "[DRY RUN] Validated $label -> $($def.id) :: payload value=$preview" }
        } catch {
            $detail=Get-CpcGraphErrorDetail $_
            $mappingFailures.Add("$label :: $detail")
            Add-CpcResult -Results $results -Stage 'dynamic-setting' -Name $label -Status 'failed' -Detail $detail
        }
    }

    if ($mappingFailures.Count -gt 0) {
        $text=($mappingFailures | ForEach-Object { " - $_" }) -join [Environment]::NewLine
        throw "Fail-closed runtime mapping validation failed. No Intune policies were created.`n$text"
    }

    # Phase 2: build/validate selected Settings Catalog policy payloads.
    $preparedPolicies=[System.Collections.Generic.List[object]]::new()
    $existingPolicies=Invoke-CpcGraphPaged 'https://graph.microsoft.com/beta/deviceManagement/configurationPolicies?$select=id,name&$top=500'
    $policyDir=Join-Path $PackRoot ([string]$manifest.settingsCatalogPolicyDirectory)
    if (Test-Path -LiteralPath $policyDir) {
        foreach ($file in Get-ChildItem -LiteralPath $policyDir -Filter '*.json' | Sort-Object Name) {
            $bundle=Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json -Depth 100
            $name=[string]$bundle.policy.name
            if (-not (Test-CpcProfileSelected -Profiles $bundle.profiles -Selector $Profile)) {
                Add-CpcResult -Results $results -Stage 'settings-catalog-policy' -Name $name -Status 'skipped-profile' -Detail "Profile selector: $Profile"
                continue
            }
            $dynamicEntries=if ($dynamicByPolicy.ContainsKey($name)) { @($dynamicByPolicy[$name]) } else { @() }
            $static=ConvertTo-CpcWritablePayload -InputObject @($bundle.settings)
            $merged=Merge-CpcConfigurationSettings -StaticSettings $static -DynamicEntries $dynamicEntries
            if (@($merged).Count -eq 0) { throw "Selected policy '$name' has zero settings; Intune deep-create requires at least one setting." }
            $body=New-CpcSettingsCatalogPolicyBody -Policy $bundle.policy -Settings $merged
            if (Test-CpcObjectContainsAssignments -InputObject $body) { throw "Selected policy '$name' unexpectedly contains assignments." }
            # A matching name is only a collision candidate. Prove complete equivalence before any skip or write.
            $existing=@($existingPolicies | Where-Object { [string]$_.name -ieq $name })
            if ($existing.Count -gt 1) {
                $detail="Found $($existing.Count) existing policies with the same case-insensitive name. Exact identity is ambiguous."
                Add-CpcResult -Results $results -Stage 'settings-catalog-policy' -Name $name -Status 'failed-existing-verification' -Detail $detail
                throw "Existing-policy verification failed for '$name': $detail No Intune policies were created."
            }
            $existingVerification=$null
            if ($existing.Count -eq 1) {
                $existingId=[string]$existing[0].id
                if ([string]::IsNullOrWhiteSpace($existingId)) { throw "Existing-policy verification failed for '$name': Graph returned an empty policy ID. No Intune policies were created." }
                $encodedId=[Uri]::EscapeDataString($existingId)
                try {
                    $existingDetail=Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies/$encodedId"
                    $existingSettings=Invoke-CpcGraphPaged "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies/$encodedId/settings?`$top=100"
                    $comparison=Compare-CpcSettingsCatalogPolicy -ExpectedPolicy $body -ActualPolicy $existingDetail -ActualSettings @($existingSettings)
                } catch {
                    $detail=Get-CpcGraphErrorDetail $_
                    Add-CpcResult -Results $results -Stage 'settings-catalog-policy' -Name $name -Status 'failed-existing-verification' -Detail $detail
                    throw "Existing-policy verification failed for '$name': $detail No Intune policies were created."
                }
                if (-not $comparison.equivalent) {
                    $detail="Existing policy '$existingId' differs from the pack (expectedSettings=$($comparison.expectedSettingCount); actualSettings=$($comparison.actualSettingCount); expectedSha256=$($comparison.expectedSha256); actualSha256=$($comparison.actualSha256))."
                    Add-CpcResult -Results $results -Stage 'settings-catalog-policy' -Name $name -Status 'failed-existing-verification' -Detail $detail
                    throw "Existing-policy verification failed for '$name': $detail No Intune policies were created."
                }
                $existingVerification=[pscustomobject]@{id=$existingId;comparison=$comparison}
            }
            $preparedPolicies.Add([pscustomobject]@{ name=$name; body=$body; settingCount=@($merged).Count; existingVerification=$existingVerification })
        }
    }

    # Phase 3: validate generic Graph objects before writes.
    $preparedGraphObjects=[System.Collections.Generic.List[object]]::new()
    if ($manifest.graphObjects) {
        $objectsPath=Join-Path $PackRoot ([string]$manifest.graphObjects)
        if (Test-Path -LiteralPath $objectsPath) {
            foreach ($obj in @(Get-Content -LiteralPath $objectsPath -Raw | ConvertFrom-Json -Depth 100)) {
                $name=[string]$obj.name
                if (-not (Test-CpcProfileSelected -Profiles $obj.profiles -Selector $Profile)) {
                    Add-CpcResult -Results $results -Stage 'graph-object' -Name $name -Status 'skipped-profile' -Detail "Profile selector: $Profile"
                    continue
                }
                $endpoint=[string]$obj.endpoint
                $listEndpoint=if ($obj.listEndpoint) { [string]$obj.listEndpoint } else { $endpoint }
                if (-not (Test-CpcGraphEndpointSafe -Uri $endpoint) -or -not (Test-CpcGraphEndpointSafe -Uri $listEndpoint)) { throw "Unsafe Graph endpoint in '$name'." }
                $payload=ConvertTo-CpcWritablePayload -InputObject $obj.payload
                if (Test-CpcObjectContainsAssignments -InputObject $payload) { throw "Graph object '$name' contains assignments." }
                $contractInfo=Get-CpcGraphObjectContract -ContractId ([string]$obj.contractId) -ExpectedSha256 ([string]$obj.contractSha256) -RepoRoot $repoRoot
                Assert-CpcGraphObjectMatchesContract -GraphObject $obj -Contract $contractInfo.Contract
                $nameProperty=if ($obj.nameProperty) { [string]$obj.nameProperty } else { 'displayName' }
                $existingObjects=Invoke-CpcGraphPaged $listEndpoint
                $match=@($existingObjects | Where-Object { [string]$_.$nameProperty -ieq $name })
                if($match.Count -gt 1){
                    $detail="Found $($match.Count) existing objects with the same case-insensitive name. Exact identity is ambiguous."
                    Add-CpcResult -Results $results -Stage 'graph-object' -Name $name -Status 'failed-existing-verification' -Detail $detail
                    throw "Existing Graph-object verification failed for '$name': $detail No Intune objects were created."
                }
                $existingVerification=$null
                if($match.Count -eq 1){
                    $existingId=[string]$match[0].id
                    if([string]::IsNullOrWhiteSpace($existingId)){throw "Existing Graph-object verification failed for '$name': Graph returned an empty object ID. No Intune objects were created."}
                    try {
                        $itemUri=Get-CpcGraphObjectItemUri -Contract $contractInfo.Contract -Id $existingId
                        $existingDetail=Invoke-MgGraphRequest -Method GET -Uri $itemUri
                        $comparison=Compare-CpcGenericGraphObject -ExpectedPayload $payload -ActualPayload $existingDetail -Contract $contractInfo.Contract
                    } catch {
                        $detail=Get-CpcGraphErrorDetail $_
                        Add-CpcResult -Results $results -Stage 'graph-object' -Name $name -Status 'failed-existing-verification' -Detail $detail
                        throw "Existing Graph-object verification failed for '$name': $detail No Intune objects were created."
                    }
                    if(-not $comparison.equivalent){
                        $detail="Existing object '$existingId' differs from the pack (expectedSha256=$($comparison.expectedSha256); actualSha256=$($comparison.actualSha256); $($comparison.detail))."
                        Add-CpcResult -Results $results -Stage 'graph-object' -Name $name -Status 'failed-existing-verification' -Detail $detail
                        throw "Existing Graph-object verification failed for '$name': $detail No Intune objects were created."
                    }
                    $existingVerification=[pscustomobject]@{id=$existingId;comparison=$comparison}
                }
                $preparedGraphObjects.Add([pscustomobject]@{ name=$name; endpoint=$endpoint; payload=$payload; existingVerification=$existingVerification })
            }
        }
    }

    if ($DryRun) {
        foreach ($p in $preparedPolicies) {
            if ($p.existingVerification) { Write-Host "[DRY RUN] Existing policy exactly matches; would skip: $($p.name) [$($p.existingVerification.id)]"; Add-CpcResult -Results $results -Stage 'settings-catalog-policy' -Name $p.name -Status 'existing-equivalent' -Detail ([string]$p.existingVerification.id) }
            else { Write-Host "[DRY RUN] Would deep-create policy: $($p.name) ($($p.settingCount) embedded settings)"; Add-CpcResult -Results $results -Stage 'settings-catalog-policy' -Name $p.name -Status 'dry-run-deep-create' -Detail "$($p.settingCount) embedded settings" }
        }
        foreach ($o in $preparedGraphObjects) {
            if($o.existingVerification){Write-Host "[DRY RUN] Existing Graph object exactly matches; would skip: $($o.name) [$($o.existingVerification.id)]";Add-CpcResult -Results $results -Stage 'graph-object' -Name $o.name -Status 'existing-equivalent' -Detail ([string]$o.existingVerification.id)}
            else {Write-Host "[DRY RUN] Would create Graph object: $($o.name) -> $($o.endpoint)"; Add-CpcResult -Results $results -Stage 'graph-object' -Name $o.name -Status 'dry-run' -Detail $o.endpoint}
        }
    } else {
        foreach ($p in $preparedPolicies) {
            if ($p.existingVerification) { Write-Warning "Policy already exists, exactly matches, and will not be modified: $($p.name)"; Add-CpcResult -Results $results -Stage 'settings-catalog-policy' -Name $p.name -Status 'existing-equivalent' -Detail ([string]$p.existingVerification.id); continue }
            try {
                $created=Invoke-MgGraphRequest -Method POST -Uri 'https://graph.microsoft.com/beta/deviceManagement/configurationPolicies' -ContentType 'application/json' -Body ($p.body | ConvertTo-Json -Depth 100)
                Write-Host "Created policy: $($p.name) ($($p.settingCount) embedded settings)"
                Add-CpcResult -Results $results -Stage 'settings-catalog-policy' -Name $p.name -Status 'created' -Detail "$($created.id) :: $($p.settingCount) settings"
            } catch {
                $detail=Get-CpcGraphErrorDetail $_; Add-CpcResult -Results $results -Stage 'settings-catalog-policy' -Name $p.name -Status 'failed' -Detail $detail; Write-Warning "Failed policy '$($p.name)': $detail"; if ($stopOnCreateError) { throw }
            }
        }
        foreach ($o in $preparedGraphObjects) {
            if($o.existingVerification){Write-Warning "Graph object already exists, exactly matches, and will not be modified: $($o.name)";Add-CpcResult -Results $results -Stage 'graph-object' -Name $o.name -Status 'existing-equivalent' -Detail ([string]$o.existingVerification.id);continue}
            try {
                $created=Invoke-MgGraphRequest -Method POST -Uri $o.endpoint -ContentType 'application/json' -Body ($o.payload | ConvertTo-Json -Depth 100)
                Write-Host "Created Graph object: $($o.name)"
                Add-CpcResult -Results $results -Stage 'graph-object' -Name $o.name -Status 'created' -Detail ([string]$created.id)
            } catch {
                $detail=Get-CpcGraphErrorDetail $_; Add-CpcResult -Results $results -Stage 'graph-object' -Name $o.name -Status 'failed' -Detail $detail; Write-Warning "Failed Graph object '$($o.name)': $detail"; if ($stopOnCreateError) { throw }
            }
        }
    }

    $resultPath=Save-CpcImportResults
    Write-Host ''
    Write-Host "Import complete for profile '$Profile'. No assignments were created."
    Write-Host "Results: $resultPath"
}
catch {
    $failure=$_
    $resultPath=Save-CpcImportResults
    if ($resultPath) { Write-Warning "Import aborted. Partial/preflight results: $resultPath" }
    throw $failure
}
finally { if($ownsGraphConnection){Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null} }
