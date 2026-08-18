[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BundlePath,
    [switch]$ValidateOnly,
    [switch]$DryRun,
    [switch]$StopOnError,
    [switch]$ContinueOnError,
    [string]$TenantId,
    [switch]$UseDeviceCode,
    [switch]$UseExistingGraphContext,
    [switch]$ConfirmUnassignedImport,
    [switch]$ConfirmTenantWideSettingsUpdate,
    [switch]$SkipTenantWideSettings
)

$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if($StopOnError -and $ContinueOnError){throw 'StopOnError and ContinueOnError cannot be used together.'}
if($UseDeviceCode -and $UseExistingGraphContext){throw 'UseDeviceCode and UseExistingGraphContext cannot be combined.'}
if($ConfirmTenantWideSettingsUpdate -and $SkipTenantWideSettings){throw 'ConfirmTenantWideSettingsUpdate and SkipTenantWideSettings cannot be combined.'}
if($ValidateOnly){
    if($DryRun -or $ConfirmUnassignedImport -or $ConfirmTenantWideSettingsUpdate -or $TenantId -or $UseDeviceCode -or $UseExistingGraphContext){throw 'ValidateOnly is offline and cannot be combined with Graph or write parameters.'}
}elseif($DryRun){
    if($ConfirmUnassignedImport -or $ConfirmTenantWideSettingsUpdate){throw 'DryRun is read-only and cannot be combined with write acknowledgements.'}
}else{
    if(-not $TenantId){throw 'Import requires an explicit TenantId before bundle validation or Graph authentication.'}
    if(-not $ConfirmUnassignedImport){throw 'Import requires -ConfirmUnassignedImport before bundle validation or Graph authentication.'}
}

$stopOnCreateError=-not $ContinueOnError
$repoRoot=Split-Path -Parent $PSScriptRoot
$BundlePath=(Resolve-Path -LiteralPath $BundlePath).Path
Import-Module (Join-Path $repoRoot 'src\CISPolicyCreator.psm1') -Force -DisableNameChecking
Add-Type -AssemblyName System.IO.Compression

# Validate the complete ZIP before reading a payload or authenticating.
$bundleValidation=& (Join-Path $PSScriptRoot 'Test-CISWindowsStylePolicyBundle.ps1') -BundlePath $BundlePath -PassThru
if(-not $bundleValidation.IsValid){
    $details=($bundleValidation.Issues|ForEach-Object{" - $_"}) -join [Environment]::NewLine
    throw "Policy JSON ZIP failed fail-closed validation. No Graph connection was made.`n$details"
}

function Read-CpcZipJson($Entry){
    $stream=$Entry.Open()
    $reader=[IO.StreamReader]::new($stream,[Text.UTF8Encoding]::new($false,$true),$true)
    try{return $reader.ReadToEnd()|ConvertFrom-Json -Depth 100}
    catch{throw "Invalid UTF-8 JSON '$($Entry.FullName)': $($_.Exception.Message)"}
    finally{$reader.Dispose();$stream.Dispose()}
}

function Get-CpcObjectPropertyNames($Object){
    if($Object -is [System.Collections.IDictionary]){return @($Object.Keys|ForEach-Object{[string]$_})}
    return @($Object.PSObject.Properties.Name|ForEach-Object{[string]$_})
}

function Get-CpcObjectPropertyValue($Object,[string]$Name){
    if($Object -is [System.Collections.IDictionary]){$value=if($Object.Contains($Name)){$Object[$Name]}else{$null}}
    else{
        $property=$Object.PSObject.Properties[$Name]
        $value=if($property){$property.Value}else{$null}
    }
    if($value -is [System.Collections.IEnumerable] -and $value -isnot [string] -and $value -isnot [System.Collections.IDictionary]){return ,$value}
    return $value
}

$preparedSettings=[System.Collections.Generic.List[object]]::new()
$preparedGraph=[System.Collections.Generic.List[object]]::new()
$archive=[IO.Compression.ZipFile]::OpenRead($BundlePath)
try{
    foreach($entry in @($archive.Entries|Where-Object{-not [string]::IsNullOrEmpty($_.Name)}|Sort-Object FullName)){
        $segments=$entry.FullName.Split('/')
        $folder=[string]$segments[1]
        $raw=Read-CpcZipJson $entry
        if($folder -eq 'SettingsCatalog'){
            if([string]$raw.'@odata.type' -cne '#microsoft.graph.deviceManagementConfigurationPolicy'){throw "'$($entry.FullName)' is not a Settings Catalog policy."}
            $settings=@($raw.settings)
            if($settings.Count -ne 1){throw "'$($entry.FullName)' must contain exactly one top-level setting."}
            $setting=$settings[0]
            if([string]$setting.'@odata.type' -cne '#microsoft.graph.deviceManagementConfigurationSetting'){throw "'$($entry.FullName)' has an unexpected top-level setting type."}
            if(-not $setting.PSObject.Properties['settingInstance']){throw "'$($entry.FullName)' has no settingInstance."}
            $spec=ConvertTo-CpcSettingSpecFromExportInstance -Instance $setting.settingInstance -Context ([string]$raw.name)
            $preparedSettings.Add([pscustomobject]@{entryPath=[string]$entry.FullName;name=[string]$raw.name;policy=$raw;spec=$spec})|Out-Null
            continue
        }

        $odataType=[string]$raw.'@odata.type'
        $contractInfo=Get-CpcGraphObjectContractByOdataType -OdataType $odataType -RepoRoot $repoRoot
        $contract=$contractInfo.Contract
        $contractPropertyNames=@($contract.properties.PSObject.Properties.Name|ForEach-Object{[string]$_})
        $exportMetadata=@('assignments','createdDateTime','description','displayName','id','lastModifiedDateTime','version')
        $unexpected=@(Get-CpcObjectPropertyNames $raw|Where-Object{$contractPropertyNames -cnotcontains $_ -and $exportMetadata -cnotcontains $_})
        if($unexpected.Count -gt 0){throw "'$($entry.FullName)' contains properties absent from its pinned Graph contract: $($unexpected -join ', ')."}
        $assignments=@(Get-CpcObjectPropertyValue $raw 'assignments')
        if($assignments.Count -gt 0){throw "'$($entry.FullName)' contains assignments."}
        $payload=[ordered]@{}
        foreach($contractProperty in $contract.properties.PSObject.Properties){
            $propertyName=[string]$contractProperty.Name
            $rawProperty=$raw.PSObject.Properties[$propertyName]
            if($rawProperty){$payload[$propertyName]=$rawProperty.Value}
        }
        $nameProperty=if($null -eq $contract.nameProperty){$null}else{[string]$contract.nameProperty}
        $name=if($nameProperty){[string](Get-CpcObjectPropertyValue $raw $nameProperty)}else{[string](Get-CpcObjectPropertyValue $raw 'displayName')}
        if([string]::IsNullOrWhiteSpace($name)){throw "'$($entry.FullName)' has no usable policy label."}
        $operation=if($contract.PSObject.Properties['operation']){[string]$contract.operation}else{'create'}
        $envelope=[pscustomobject][ordered]@{
            name=$name
            endpoint=[string]$contract.endpoint
            listEndpoint=[string]$contract.listEndpoint
            nameProperty=$nameProperty
            operation=$operation
            payload=[pscustomobject]$payload
        }
        Assert-CpcGraphObjectMatchesContract -GraphObject $envelope -Contract $contract
        $preparedGraph.Add([pscustomobject]@{entryPath=[string]$entry.FullName;name=$name;folder=$folder;payload=$envelope.payload;operation=$operation;contractInfo=$contractInfo})|Out-Null
    }
}finally{$archive.Dispose()}

$singletonCount=@($preparedGraph|Where-Object operation -eq 'update-singleton').Count
if(-not $ValidateOnly -and -not $DryRun -and $singletonCount -gt 0 -and -not $SkipTenantWideSettings -and -not $ConfirmTenantWideSettingsUpdate){
    throw "Bundle contains $singletonCount tenant-wide Intune setting update(s). Add -ConfirmTenantWideSettingsUpdate or -SkipTenantWideSettings before Graph authentication."
}

Write-Host 'PASS: offline import preparation succeeded.'
Write-Host "Bundle                    : $BundlePath"
Write-Host "Settings Catalog policies : $($preparedSettings.Count)"
Write-Host "Typed Graph objects       : $($preparedGraph.Count-$singletonCount)"
Write-Host "Tenant-wide updates       : $singletonCount"
Write-Host 'Assignments                : none'
if($ValidateOnly){return}

& (Join-Path $PSScriptRoot 'Import-CISGraphAuthentication.ps1')
$graphScope=if($DryRun){'DeviceManagementConfiguration.Read.All'}else{'DeviceManagementConfiguration.ReadWrite.All'}
$ownsGraphConnection=-not $UseExistingGraphContext
if($UseExistingGraphContext){
    $context=Get-MgContext
    if(-not $context){throw 'UseExistingGraphContext requires an authenticated Microsoft Graph context.'}
    $accepted=if($DryRun){@($context.Scopes)-contains 'DeviceManagementConfiguration.Read.All' -or @($context.Scopes)-contains 'DeviceManagementConfiguration.ReadWrite.All'}else{@($context.Scopes)-contains 'DeviceManagementConfiguration.ReadWrite.All'}
    if(-not $accepted){throw "The existing Microsoft Graph context lacks required scope '$graphScope'."}
}else{
    Disconnect-MgGraph -ErrorAction SilentlyContinue|Out-Null
    $connectArgs=@{Scopes=$graphScope;ContextScope='Process';NoWelcome=$true}
    if($TenantId){$connectArgs.TenantId=$TenantId}else{Write-Warning 'Dry-run TenantId was not pinned. Pass -TenantId for production-quality validation.'}
    if($UseDeviceCode){$connectArgs.UseDeviceCode=$true}
    Connect-MgGraph @connectArgs
    $context=Get-MgContext
}
if($TenantId -and [string]$context.TenantId -cne $TenantId){throw "Authenticated tenant '$($context.TenantId)' does not match requested TenantId '$TenantId'."}
Write-Host "Graph account              : $($context.Account)"
Write-Host "Graph tenant               : $($context.TenantId)"
Write-Host "Graph app                  : $($context.AppName)"
Write-Host "Graph scopes               : $((@($context.Scopes)-join ', '))"
try{
    $org=Invoke-MgGraphRequest -Method GET -Uri 'https://graph.microsoft.com/v1.0/organization?$select=id,displayName,verifiedDomains'
    $orgItem=@($org.value)[0]
    if($orgItem){$domains=@($orgItem.verifiedDomains|Where-Object isDefault|ForEach-Object name)-join ', ';Write-Host "Organization               : $($orgItem.displayName) [$($orgItem.id)] defaultDomain=$domains"}
}catch{Write-Warning "Could not read organization metadata: $($_.Exception.Message)"}

$results=[System.Collections.Generic.List[object]]::new()
$resultWritten=$false
function Save-CpcBundleImportResults {
    if($resultWritten -or $results.Count -eq 0){return $null}
    $directory=Split-Path -Parent $BundlePath
    $base=[IO.Path]::GetFileNameWithoutExtension($BundlePath)
    $path=Join-Path $directory "$base-import-results-$(Get-Date -Format 'yyyyMMdd-HHmmss-fff').json"
    $results|ConvertTo-Json -Depth 30|Set-Content -LiteralPath $path -Encoding utf8
    $script:resultWritten=$true
    return $path
}

try{
    # Resolve and validate every Settings Catalog definition/value before any write.
    $definitionCache=@{}
    $settingsReady=[System.Collections.Generic.List[object]]::new()
    foreach($item in $preparedSettings){
        try{
            $definition=Get-CpcSettingDefinition -Spec $item.spec -Definitions @() -Cache $definitionCache
            $settingBody=New-CpcConfigurationSettingBody -Definition $definition -Spec $item.spec -Definitions @() -DefinitionCache $definitionCache
            $policyBody=New-CpcSettingsCatalogPolicyBody -Policy $item.policy -Settings @($settingBody)
            if(Test-CpcObjectContainsAssignments -InputObject $policyBody){throw "Prepared policy '$($item.name)' contains assignments."}
            $settingsReady.Add([pscustomobject]@{name=$item.name;body=$policyBody;entryPath=$item.entryPath})|Out-Null
            Add-CpcResult -Results $results -Stage 'settings-catalog-definition' -Name $item.name -Status 'validated' -Detail ([string]$definition.id)
        }catch{
            $detail=Get-CpcGraphErrorDetail $_
            Add-CpcResult -Results $results -Stage 'settings-catalog-definition' -Name $item.name -Status 'failed' -Detail $detail
            throw "Live setting validation failed for '$($item.name)': $detail No Intune objects were created."
        }
    }

    # Prove every same-name collision and singleton value before any write.
    $settingsExisting=Invoke-CpcGraphPaged 'https://graph.microsoft.com/beta/deviceManagement/configurationPolicies?$select=id,name&$top=500'
    foreach($item in $settingsReady){
        $matches=@($settingsExisting|Where-Object{[string]$_.name -ieq $item.name})
        if($matches.Count -gt 1){throw "Existing-policy verification failed for '$($item.name)': found $($matches.Count) case-insensitive matches. No Intune objects were created."}
        $item|Add-Member -NotePropertyName existingVerification -NotePropertyValue $null
        if($matches.Count -eq 1){
            $id=[string]$matches[0].id
            if([string]::IsNullOrWhiteSpace($id)){throw "Existing-policy verification failed for '$($item.name)': Graph returned an empty ID. No Intune objects were created."}
            $encoded=[Uri]::EscapeDataString($id)
            $actual=Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies/$encoded"
            $actualSettings=Invoke-CpcGraphPaged "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies/$encoded/settings?`$top=100"
            $comparison=Compare-CpcSettingsCatalogPolicy -ExpectedPolicy $item.body -ActualPolicy $actual -ActualSettings @($actualSettings)
            if(-not $comparison.equivalent){throw "Existing-policy verification failed for '$($item.name)': existing policy '$id' differs (expectedSha256=$($comparison.expectedSha256); actualSha256=$($comparison.actualSha256)). No Intune objects were created."}
            $item.existingVerification=[pscustomobject]@{id=$id;comparison=$comparison}
        }
    }

    $graphReady=[System.Collections.Generic.List[object]]::new()
    $listCache=@{}
    foreach($item in $preparedGraph){
        $contract=$item.contractInfo.Contract
        if($item.operation -eq 'update-singleton'){
            if($SkipTenantWideSettings){Add-CpcResult -Results $results -Stage 'tenant-wide-setting' -Name $item.name -Status 'skipped-explicitly' -Detail ([string]$contract.endpoint);continue}
            $actual=Invoke-MgGraphRequest -Method GET -Uri ([string]$contract.endpoint)
            $comparison=Compare-CpcGenericGraphObject -ExpectedPayload $item.payload -ActualPayload $actual -Contract $contract
            $graphReady.Add([pscustomobject]@{name=$item.name;payload=$item.payload;operation=$item.operation;endpoint=[string]$contract.endpoint;contract=$contract;existingVerification=if($comparison.equivalent){[pscustomobject]@{comparison=$comparison}}else{$null}})|Out-Null
            continue
        }
        if($item.operation -ne 'create'){throw "Unsupported pinned Graph operation '$($item.operation)' for '$($item.name)'. No Intune objects were created."}
        $listEndpoint=[string]$contract.listEndpoint
        if(-not $listCache.ContainsKey($listEndpoint)){$listCache[$listEndpoint]=@(Invoke-CpcGraphPaged $listEndpoint)}
        $nameProperty=[string]$contract.nameProperty
        $matches=@($listCache[$listEndpoint]|Where-Object{[string]$_.$nameProperty -ieq $item.name})
        if($matches.Count -gt 1){throw "Existing Graph-object verification failed for '$($item.name)': found $($matches.Count) case-insensitive matches. No Intune objects were created."}
        $verification=$null
        if($matches.Count -eq 1){
            $id=[string]$matches[0].id
            if([string]::IsNullOrWhiteSpace($id)){throw "Existing Graph-object verification failed for '$($item.name)': Graph returned an empty ID. No Intune objects were created."}
            $actual=Invoke-MgGraphRequest -Method GET -Uri (Get-CpcGraphObjectItemUri -Contract $contract -Id $id)
            $comparison=Compare-CpcGenericGraphObject -ExpectedPayload $item.payload -ActualPayload $actual -Contract $contract
            if(-not $comparison.equivalent){throw "Existing Graph-object verification failed for '$($item.name)': existing object '$id' differs (expectedSha256=$($comparison.expectedSha256); actualSha256=$($comparison.actualSha256)). No Intune objects were created."}
            $verification=[pscustomobject]@{id=$id;comparison=$comparison}
        }
        $graphReady.Add([pscustomobject]@{name=$item.name;payload=$item.payload;operation=$item.operation;endpoint=[string]$contract.endpoint;contract=$contract;existingVerification=$verification})|Out-Null
    }

    if($DryRun){
        foreach($item in $settingsReady){
            if($item.existingVerification){Write-Host "[DRY RUN] Existing policy exactly matches; would skip: $($item.name) [$($item.existingVerification.id)]";Add-CpcResult -Results $results -Stage 'settings-catalog-policy' -Name $item.name -Status 'existing-equivalent' -Detail ([string]$item.existingVerification.id)}
            else{Write-Host "[DRY RUN] Would create unassigned Settings Catalog policy: $($item.name)";Add-CpcResult -Results $results -Stage 'settings-catalog-policy' -Name $item.name -Status 'dry-run-create' -Detail '1 top-level setting; no assignments'}
        }
        foreach($item in $graphReady){
            $stage=if($item.operation -eq 'update-singleton'){'tenant-wide-setting'}else{'graph-object'}
            if($item.existingVerification){Write-Host "[DRY RUN] Existing value/object exactly matches; would skip: $($item.name)";Add-CpcResult -Results $results -Stage $stage -Name $item.name -Status 'existing-equivalent' -Detail $item.endpoint}
            elseif($item.operation -eq 'update-singleton'){Write-Host "[DRY RUN] Would update tenant-wide Intune setting: $($item.name)";Add-CpcResult -Results $results -Stage $stage -Name $item.name -Status 'dry-run-update' -Detail $item.endpoint}
            else{Write-Host "[DRY RUN] Would create unassigned Graph policy: $($item.name)";Add-CpcResult -Results $results -Stage $stage -Name $item.name -Status 'dry-run-create' -Detail $item.endpoint}
        }
    }else{
        foreach($item in $settingsReady){
            if($item.existingVerification){Write-Warning "Policy already exists, exactly matches, and will not be modified: $($item.name)";Add-CpcResult -Results $results -Stage 'settings-catalog-policy' -Name $item.name -Status 'existing-equivalent' -Detail ([string]$item.existingVerification.id);continue}
            try{$created=Invoke-MgGraphRequest -Method POST -Uri 'https://graph.microsoft.com/beta/deviceManagement/configurationPolicies' -ContentType 'application/json' -Body ($item.body|ConvertTo-Json -Depth 100);Write-Host "Created unassigned Settings Catalog policy: $($item.name)";Add-CpcResult -Results $results -Stage 'settings-catalog-policy' -Name $item.name -Status 'created' -Detail ([string]$created.id)}catch{$detail=Get-CpcGraphErrorDetail $_;Add-CpcResult -Results $results -Stage 'settings-catalog-policy' -Name $item.name -Status 'failed' -Detail $detail;Write-Warning "Failed policy '$($item.name)': $detail";if($stopOnCreateError){throw}}
        }
        foreach($item in $graphReady){
            $stage=if($item.operation -eq 'update-singleton'){'tenant-wide-setting'}else{'graph-object'}
            if($item.existingVerification){Write-Warning "Object/value already exists and exactly matches; it will not be modified: $($item.name)";Add-CpcResult -Results $results -Stage $stage -Name $item.name -Status 'existing-equivalent' -Detail $item.endpoint;continue}
            try{
                if($item.operation -eq 'update-singleton'){Invoke-MgGraphRequest -Method PATCH -Uri $item.endpoint -ContentType 'application/json' -Body ($item.payload|ConvertTo-Json -Depth 100)|Out-Null;Write-Host "Updated tenant-wide Intune setting: $($item.name)";Add-CpcResult -Results $results -Stage $stage -Name $item.name -Status 'updated' -Detail $item.endpoint}
                else{$created=Invoke-MgGraphRequest -Method POST -Uri $item.endpoint -ContentType 'application/json' -Body ($item.payload|ConvertTo-Json -Depth 100);Write-Host "Created unassigned Graph policy: $($item.name)";Add-CpcResult -Results $results -Stage $stage -Name $item.name -Status 'created' -Detail ([string]$created.id)}
            }catch{$detail=Get-CpcGraphErrorDetail $_;Add-CpcResult -Results $results -Stage $stage -Name $item.name -Status 'failed' -Detail $detail;Write-Warning "Failed '$($item.name)': $detail";if($stopOnCreateError){throw}}
        }
    }

    $resultPath=Save-CpcBundleImportResults
    Write-Host ''
    Write-Host 'Import processing complete. No assignments were created.'
    Write-Host "Results: $resultPath"
}catch{
    $failure=$_
    $resultPath=Save-CpcBundleImportResults
    if($resultPath){Write-Warning "Import aborted. Partial/preflight results: $resultPath"}
    throw $failure
}finally{if($ownsGraphConnection){Disconnect-MgGraph -ErrorAction SilentlyContinue|Out-Null}}
