[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PackRoot,
    [Parameter(Mandatory)][string]$PrivateExtractionPath,
    [Parameter(Mandatory)][string]$SettingsCatalogSnapshotPath,
    [Parameter(Mandatory)][string]$OutputPath,
    [string]$BundleName,
    [ValidateSet('L1','L2','BL','L1BL','ALL')][string]$Profile='ALL'
)

$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$repoRoot=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repoRoot 'src\CISPolicyCreator.psm1') -Force -DisableNameChecking
Add-Type -AssemblyName System.IO.Compression

$PackRoot=(Resolve-Path -LiteralPath $PackRoot).Path
$PrivateExtractionPath=(Resolve-Path -LiteralPath $PrivateExtractionPath).Path
$SettingsCatalogSnapshotPath=(Resolve-Path -LiteralPath $SettingsCatalogSnapshotPath).Path
$OutputPath=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
$Profile=$Profile.ToUpperInvariant()
if([IO.Path]::GetExtension($OutputPath) -cne '.zip'){throw 'OutputPath must use the lowercase .zip extension.'}
if(Test-Path -LiteralPath $OutputPath){throw "OutputPath already exists: $OutputPath"}
if([string]::IsNullOrWhiteSpace($BundleName)){$BundleName=[IO.Path]::GetFileNameWithoutExtension($OutputPath)}
if($BundleName -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$'){throw 'BundleName must be 1-100 characters and use only letters, numbers, dot, underscore, or hyphen.'}

$packValidation=& (Join-Path $PSScriptRoot 'Test-CISPolicyPack.ps1') -PackRoot $PackRoot -PassThru
if(-not $packValidation.IsValid){throw "Policy pack failed validation:`n$($packValidation.Issues -join [Environment]::NewLine)"}

function Read-JsonFile([string]$Path,[string]$Label) {
    try { return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -Depth 100 }
    catch { throw "$Label is invalid JSON: $($_.Exception.Message)" }
}

function Get-FileSha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-BytesSha256([byte[]]$Bytes) {
    $sha=[Security.Cryptography.SHA256]::Create()
    try { return ([Convert]::ToHexString($sha.ComputeHash($Bytes))).ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function ConvertTo-StableJsonBytes($Value) {
    $canonical=ConvertTo-CpcCanonicalObject -InputObject $Value
    $json=(ConvertTo-Json -InputObject $canonical -Depth 100) -replace "`r`n","`n"
    if(-not $json.EndsWith("`n",[StringComparison]::Ordinal)){$json+="`n"}
    return ,[Text.UTF8Encoding]::new($false).GetBytes($json)
}

function Get-OptionalProperty($Object,[string]$Name,$Default=$null) {
    if($null -eq $Object){return $Default}
    if($Object -is [System.Collections.IDictionary]){
        if($Object.Contains($Name)){return $Object[$Name]}
        return $Default
    }
    $property=$Object.PSObject.Properties[$Name]
    if($property){return $property.Value}
    return $Default
}

function Test-ObjectProperty($Object,[string]$Name) {
    if($null -eq $Object){return $false}
    if($Object -is [System.Collections.IDictionary]){return $Object.Contains($Name)}
    return $null -ne $Object.PSObject.Properties[$Name]
}

function New-DeterministicGuid([string]$Seed) {
    [byte[]]$seedBytes=[Text.UTF8Encoding]::new($false).GetBytes($Seed)
    $sha=[Security.Cryptography.SHA256]::Create()
    try {$hex=([Convert]::ToHexString($sha.ComputeHash($seedBytes))).ToLowerInvariant().Substring(0,32)}finally{$sha.Dispose()}
    $hex=$hex.Substring(0,12)+'5'+$hex.Substring(13)
    $variant=[Convert]::ToInt32($hex.Substring(16,1),16)
    $hex=$hex.Substring(0,16)+('89ab'[($variant -band 3)])+$hex.Substring(17)
    return "$($hex.Substring(0,8))-$($hex.Substring(8,4))-$($hex.Substring(12,4))-$($hex.Substring(16,4))-$($hex.Substring(20,12))"
}

function ConvertTo-PolicySafeText([string]$Value) {
    if([string]::IsNullOrWhiteSpace($Value)){return ''}
    $text=$Value -replace '[\r\n\t]+',' '
    $text=$text -replace '[\u2018\u2019\u201C\u201D''"]',''
    $text=$text -replace '[:<>/\\|?*]',' - '
    $text=$text -replace '\s+-\s+-\s+',' - '
    $text=$text -replace '\s+',' '
    return $text.Trim(' ','.','-')
}

function Limit-PolicyName([string]$Name,[string]$CollisionSeed) {
    $safe=ConvertTo-PolicySafeText $Name
    if([string]::IsNullOrWhiteSpace($safe)){throw 'A Windows-style policy name resolved to an empty value.'}
    if($safe.Length -le 180){return $safe}
    [byte[]]$bytes=[Text.UTF8Encoding]::new($false).GetBytes($CollisionSeed+'|'+$safe)
    $suffix=(Get-BytesSha256 $bytes).Substring(0,8)
    return $safe.Substring(0,169).TrimEnd(' ','.','-')+' - '+$suffix
}

function Get-ProfileToken($Profiles) {
    $values=@($Profiles | ForEach-Object {([string]$_).ToUpperInvariant()} | Sort-Object -Unique)
    if($values.Count -ne 1){throw "Windows-style split policy naming requires exactly one profile per setting; found: $($values -join ', ')"}
    if($values[0] -cnotmatch '^[A-Z0-9]+$'){throw "Unsafe profile token: $($values[0])"}
    return $values[0]
}

function Get-SettingScopeToken($Spec) {
    $definitionId=[string]$Spec.resolve.definitionId
    if($definitionId.StartsWith('user_',[StringComparison]::OrdinalIgnoreCase)){return 'U'}
    return 'D'
}

function Get-AreaFromRemediation($Recommendation) {
    $remediation=[string](Get-OptionalProperty $Recommendation 'remediation' '')
    if([string]::IsNullOrWhiteSpace($remediation)){return $null}
    $lines=@($remediation -split '\r?\n' | ForEach-Object {($_ -replace '^\s*\d+[.)]\s*','').Trim()} | Where-Object {$_})
    $addIndex=-1
    for($i=0;$i -lt $lines.Count;$i++){if($lines[$i] -match '(?i)Add settings'){$addIndex=$i;break}}
    $search=if($addIndex -ge 0 -and $addIndex+1 -lt $lines.Count){@($lines[($addIndex+1)..($lines.Count-1)])}else{$lines}
    foreach($line in $search){
        if($line -match '(?i)^Select\s+(?:the\s+)?(.+?)\s+heading\s*$'){return ConvertTo-PolicySafeText $Matches[1]}
        if($line -match '(?i)^Select\s+(.+?)\s+then\s+(.+?)\s*$'){return (ConvertTo-PolicySafeText ($Matches[1]+' - '+$Matches[2]))}
        if($addIndex -ge 0 -and $line -match '(?i)^Select\s+(.+?)\s*$'){
            $candidate=ConvertTo-PolicySafeText $Matches[1]
            if($candidate -notmatch '(?i)^(Devices|Configuration|the profile)'){return $candidate}
        }
    }
    return $null
}

function Get-PolicyArea($Spec,$Recommendation,[string]$BenchmarkId) {
    if($BenchmarkId -match '(?i)edge'){return 'Microsoft Edge'}
    if($BenchmarkId -match '(?i)office'){return 'Microsoft Office'}
    if($BenchmarkId -match '(?i)(macos|ios)'){
        $fromRemediation=Get-AreaFromRemediation $Recommendation
        if($fromRemediation){return $fromRemediation}
    }
    $policy=[string](Get-OptionalProperty $Spec 'policy' '')
    if($policy -match '^CIS - (?<area>.+?) \[[^\]]+\]'){
        $area=($Matches.area -replace '(?i)\s+Verified$','').Trim()
        if($area){return ConvertTo-PolicySafeText $area}
    }
    $offset=[string]$Spec.resolve.offsetUri
    if($offset -match '(?i)/Config/([^/~]+)'){return ConvertTo-PolicySafeText $Matches[1]}
    $fallback=ConvertTo-PolicySafeText $BenchmarkId
    if($fallback){return $fallback}
    throw "Could not derive a deterministic policy area for recommendation '$($Spec.recommendationId)'."
}

function Get-PrimarySettingSpec($Spec) {
    if([string]$Spec.value.kind -eq 'group-collection'){
        $items=@(Get-OptionalProperty $Spec.value 'items' @())
        if($items.Count -eq 0){throw "Group setting '$($Spec.recommendationId)' has no items."}
        $children=@(Get-OptionalProperty $items[0] 'children' @())
        if($children.Count -eq 0){throw "Group setting '$($Spec.recommendationId)' has no children."}
        return $children[0]
    }
    return $Spec
}

function Get-ConfiguredValueText($Spec,[hashtable]$DefinitionCache,[int]$Depth=0) {
    if($Depth -gt 16){throw "Setting '$($Spec.recommendationId)' exceeds the naming recursion limit."}
    $value=$Spec.value
    $kind=[string]$value.kind
    if($kind -eq 'choice'){
        $definitionId=[string]$Spec.resolve.definitionId
        if(-not $DefinitionCache.ContainsKey($definitionId)){throw "Snapshot lacks definition '$definitionId' while naming a policy."}
        $optionId=[string]$value.optionId
        $matches=@($DefinitionCache[$definitionId].options | Where-Object {[string]$_.itemId -ceq $optionId})
        if($matches.Count -ne 1){throw "Snapshot does not contain exact option '$optionId' while naming a policy."}
        $optionText=[string](Get-OptionalProperty $matches[0] 'displayName' '')
        if([string]::IsNullOrWhiteSpace($optionText)){$optionText=[string](Get-OptionalProperty $matches[0] 'name' '')}
        if([string]::IsNullOrWhiteSpace($optionText)){$optionText=$optionId}
        $children=@(Get-OptionalProperty $value 'children' @())
        if($children.Count -gt 0){
            $childText=Get-ConfiguredValueText $children[0] $DefinitionCache ($Depth+1)
            if($childText -and $childText -cne $optionText){$optionText="$optionText - $childText"}
        }
        return ConvertTo-PolicySafeText $optionText
    }
    if($kind -in @('integer','string')){return ConvertTo-PolicySafeText ([string]$value.value)}
    if($kind -in @('integer-collection','string-collection')){
        $values=@(Get-OptionalProperty $value 'values' @())
        return ConvertTo-PolicySafeText ($values -join ', ')
    }
    if($kind -eq 'group-collection'){
        $primary=Get-PrimarySettingSpec $Spec
        return Get-ConfiguredValueText $primary $DefinitionCache ($Depth+1)
    }
    throw "Unsupported value kind '$kind' while naming recommendation '$($Spec.recommendationId)'."
}

function ConvertTo-RawSimpleValue($Value) {
    return [ordered]@{
        '@odata.type'=[string](Get-OptionalProperty $Value '@odata.type' '')
        settingValueTemplateReference=$null
        value=Get-OptionalProperty $Value 'value'
    }
}

function ConvertTo-RawSettingInstance($Instance) {
    $result=[ordered]@{
        '@odata.type'=[string](Get-OptionalProperty $Instance '@odata.type' '')
        settingDefinitionId=[string](Get-OptionalProperty $Instance 'settingDefinitionId' '')
        settingInstanceTemplateReference=$null
        auditRuleInformation=$null
    }
    if(Test-ObjectProperty $Instance 'choiceSettingValue'){
        $choice=Get-OptionalProperty $Instance 'choiceSettingValue'
        $children=@((Get-OptionalProperty $choice 'children' @()) | ForEach-Object {ConvertTo-RawSettingInstance $_})
        $result.choiceSettingValue=[ordered]@{
            '@odata.type'=[string](Get-OptionalProperty $choice '@odata.type' '')
            settingValueTemplateReference=$null
            value=[string](Get-OptionalProperty $choice 'value' '')
            'children@odata.type'='#Collection(microsoft.graph.deviceManagementConfigurationSettingInstance)'
            children=$children
        }
    } elseif(Test-ObjectProperty $Instance 'simpleSettingValue'){
        $result.simpleSettingValue=ConvertTo-RawSimpleValue (Get-OptionalProperty $Instance 'simpleSettingValue')
    } elseif(Test-ObjectProperty $Instance 'simpleSettingCollectionValue'){
        $result['simpleSettingCollectionValue@odata.type']='#Collection(microsoft.graph.deviceManagementConfigurationSimpleSettingValue)'
        $result.simpleSettingCollectionValue=@((Get-OptionalProperty $Instance 'simpleSettingCollectionValue' @()) | ForEach-Object {ConvertTo-RawSimpleValue $_})
    } elseif(Test-ObjectProperty $Instance 'groupSettingCollectionValue'){
        $result['groupSettingCollectionValue@odata.type']='#Collection(microsoft.graph.deviceManagementConfigurationGroupSettingValue)'
        $result.groupSettingCollectionValue=@((Get-OptionalProperty $Instance 'groupSettingCollectionValue' @()) | ForEach-Object {
            [ordered]@{
                '@odata.type'=[string](Get-OptionalProperty $_ '@odata.type' '')
                settingValueTemplateReference=$null
                'children@odata.type'='#Collection(microsoft.graph.deviceManagementConfigurationSettingInstance)'
                children=@((Get-OptionalProperty $_ 'children' @()) | ForEach-Object {ConvertTo-RawSettingInstance $_})
            }
        })
    } else {throw "Unsupported compiled Settings Catalog instance '$([string](Get-OptionalProperty $Instance '@odata.type' '') )'."}
    return $result
}

function New-RawSettingsCatalogPolicy([string]$Name,[string]$Description,[string]$Platforms,[string]$Technologies,$Setting,[string]$Seed) {
    $id=New-DeterministicGuid "policy|$Seed|$Name"
    $relative="deviceManagement/configurationPolicies('$id')"
    $absolute="https://graph.microsoft.com/beta/$relative"
    $settingRelative="$relative/settings('0')"
    $settingAbsolute="https://graph.microsoft.com/beta/$settingRelative"
    $rawSetting=[ordered]@{
        '@odata.type'='#microsoft.graph.deviceManagementConfigurationSetting'
        '@odata.id'=$settingRelative
        '@odata.editLink'=$settingRelative
        id='0'
        settingInstance=ConvertTo-RawSettingInstance $Setting.settingInstance
        'settingDefinitions@odata.associationLink'="$settingAbsolute/settingDefinitions/`$ref"
        'settingDefinitions@odata.navigationLink'="$settingAbsolute/settingDefinitions"
    }
    return [ordered]@{
        '@odata.context'='https://graph.microsoft.com/beta/$metadata#deviceManagement/configurationPolicies(assignments(),settings())/$entity'
        '@odata.type'='#microsoft.graph.deviceManagementConfigurationPolicy'
        '@odata.id'=$relative
        '@odata.editLink'=$relative
        'createdDateTime@odata.type'='#DateTimeOffset'
        createdDateTime='2000-01-01T00:00:00Z'
        creationSource=$null
        description=$Description
        'lastModifiedDateTime@odata.type'='#DateTimeOffset'
        lastModifiedDateTime='2000-01-01T00:00:00Z'
        name=$Name
        'platforms@odata.type'='#microsoft.graph.deviceManagementConfigurationPlatforms'
        platforms=$Platforms
        priorityMetaData=$null
        'roleScopeTagIds@odata.type'='#Collection(String)'
        roleScopeTagIds=@('0')
        settingCount=1
        'technologies@odata.type'='#microsoft.graph.deviceManagementConfigurationTechnologies'
        technologies=$Technologies
        id=$id
        templateReference=[ordered]@{
            '@odata.type'='#microsoft.graph.deviceManagementConfigurationPolicyTemplateReference'
            templateId=''
            'templateFamily@odata.type'='#microsoft.graph.deviceManagementConfigurationTemplateFamily'
            templateFamily='none'
            templateDisplayName=$null
            templateDisplayVersion=$null
        }
        'assignments@odata.context'="https://graph.microsoft.com/beta/`$metadata#$relative/assignments"
        'assignments@odata.associationLink'="$absolute/assignments/`$ref"
        'assignments@odata.navigationLink'="$absolute/assignments"
        assignments=@()
        'settings@odata.context'="https://graph.microsoft.com/beta/`$metadata#$relative/settings"
        'settings@odata.associationLink'="$absolute/settings/`$ref"
        'settings@odata.navigationLink'="$absolute/settings"
        settings=@($rawSetting)
        '#microsoft.graph.assign'=[ordered]@{title='microsoft.graph.assign';target="$absolute/microsoft.graph.assign"}
        '#microsoft.graph.clearEnrollmentTimeDeviceMembershipTarget'=[ordered]@{title='microsoft.graph.clearEnrollmentTimeDeviceMembershipTarget';target="$absolute/microsoft.graph.clearEnrollmentTimeDeviceMembershipTarget"}
        '#microsoft.graph.createCopy'=[ordered]@{title='microsoft.graph.createCopy';target="$absolute/microsoft.graph.createCopy"}
        '#microsoft.graph.reorder'=[ordered]@{title='microsoft.graph.reorder';target="$absolute/microsoft.graph.reorder"}
        '#microsoft.graph.retrieveEnrollmentTimeDeviceMembershipTarget'=[ordered]@{title='microsoft.graph.retrieveEnrollmentTimeDeviceMembershipTarget';target="$absolute/microsoft.graph.retrieveEnrollmentTimeDeviceMembershipTarget"}
        '#microsoft.graph.setEnrollmentTimeDeviceMembershipTarget'=[ordered]@{title='microsoft.graph.setEnrollmentTimeDeviceMembershipTarget';target="$absolute/microsoft.graph.setEnrollmentTimeDeviceMembershipTarget"}
        '#microsoft.graph.retrieveLatestUpgradeDefaultBaselinePolicy'=[ordered]@{title='microsoft.graph.retrieveLatestUpgradeDefaultBaselinePolicy';target="$absolute/microsoft.graph.retrieveLatestUpgradeDefaultBaselinePolicy"}
    }
}

function ConvertTo-HumanPropertyName([string]$Name) {
    $text=$Name -creplace '([a-z0-9])([A-Z])','$1 $2'
    $text=$text -creplace '([A-Z])([A-Z][a-z])','$1 $2'
    $text=$text -replace '(?i)^i Cloud\b','iCloud'
    $text=$text -replace '(?i)Air Drop','AirDrop'
    $text=$text -replace '(?i)Air Play','AirPlay'
    return $text.Trim()
}

function Get-GraphValueText($Value) {
    if($Value -is [bool]){return $(if($Value){'True'}else{'False'})}
    if($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]){return (@($Value) -join ', ')}
    return [string]$Value
}

function New-RawGenericGraphObject($Payload,[string]$Name,[string]$Description,[string]$Seed) {
    $raw=[ordered]@{}
    foreach($property in $Payload.PSObject.Properties){$raw[$property.Name]=$property.Value}
    if(-not $raw.Contains('displayName')){$raw.displayName=$Name}
    $raw.id=New-DeterministicGuid "graph|$Seed|$Name"
    $raw.createdDateTime='2000-01-01T00:00:00Z'
    $raw.lastModifiedDateTime='2000-01-01T00:00:00Z'
    $raw.version=1
    $raw.description=$Description
    $raw.assignments=@()
    return $raw
}

$manifestPath=Join-Path $PackRoot 'manifest.json'
$manifest=Read-JsonFile $manifestPath 'Pack manifest'
$extractionJson=Get-Content -LiteralPath $PrivateExtractionPath -Raw
if(-not ($extractionJson | Test-Json -SchemaFile (Join-Path $repoRoot 'schemas\extraction.schema.json') -ErrorAction Stop)){throw 'Private extraction failed schema validation.'}
$extraction=$extractionJson | ConvertFrom-Json -Depth 100
if([string]$extraction.benchmark.id -cne [string]$manifest.build.mappingCatalogId -and [string]$extraction.benchmark.id -cne ([string]$manifest.id -replace '^cis-','')){
    # Exact source identity below remains authoritative; benchmark IDs differ intentionally for some older catalogs.
}
if([string]$extraction.benchmark.version -cne [string]$manifest.version){throw 'Private extraction benchmark version differs from the pack.'}
if([string]$extraction.source.sha256 -cne [string]$manifest.source.sha256 -or [string]$extraction.source.fileName -cne [string]$manifest.source.fileName){throw 'Private extraction source identity differs from the pack manifest.'}
$recommendationById=@{}
foreach($recommendation in @($extraction.recommendations)){
    $id=[string]$recommendation.recommendationId
    if($recommendationById.ContainsKey($id)){throw "Private extraction contains duplicate recommendation '$id'."}
    $recommendationById[$id]=$recommendation
}

$snapshotJson=Get-Content -LiteralPath $SettingsCatalogSnapshotPath -Raw
if(-not ($snapshotJson | Test-Json -SchemaFile (Join-Path $repoRoot 'schemas\settings-catalog-snapshot.schema.json') -ErrorAction Stop)){throw 'Settings Catalog snapshot failed schema validation.'}
$snapshot=$snapshotJson | ConvertFrom-Json -Depth 100
$snapshotHash=Get-FileSha256 $SettingsCatalogSnapshotPath
if($snapshotHash -cne [string]$manifest.build.settingsCatalogSnapshotSha256){throw "Snapshot SHA-256 does not match the pack manifest. Expected=$($manifest.build.settingsCatalogSnapshotSha256); actual=$snapshotHash"}
$definitions=@($snapshot.definitions)
$definitionCache=@{}
foreach($definition in $definitions){
    $id=[string]$definition.id
    if($definitionCache.ContainsKey($id)){throw "Settings Catalog snapshot contains duplicate definition ID '$id'."}
    $definitionCache[$id]=$definition
}

$policyByName=@{}
$policyDirectory=Join-Path $PackRoot ([string]$manifest.settingsCatalogPolicyDirectory)
foreach($file in @(Get-ChildItem -LiteralPath $policyDirectory -Filter '*.json' -File)){
    $bundle=Read-JsonFile $file.FullName "Policy bundle '$($file.Name)'"
    $policyByName[[string]$bundle.policy.name]=$bundle.policy
}

$entries=[System.Collections.Generic.List[object]]::new()
$entryPaths=[System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
function Add-Entry([string]$Folder,[string]$Name,$Value,[string]$Seed) {
    $finalName=Limit-PolicyName $Name $Seed
    $path="$BundleName/$Folder/$finalName.json"
    if(-not $entryPaths.Add($path)){
        $hash=(Get-BytesSha256 ([Text.UTF8Encoding]::new($false).GetBytes($Seed+'|'+$path))).Substring(0,8)
        $finalName=Limit-PolicyName ($finalName+' - '+$hash) ($Seed+'|collision')
        $path="$BundleName/$Folder/$finalName.json"
        if(-not $entryPaths.Add($path)){throw "Windows-style policy path collision: $path"}
        if($Value -is [System.Collections.IDictionary]){if($Value.Contains('name')){$Value.name=$finalName};if($Value.Contains('displayName')){$Value.displayName=$finalName}}
        else{if($Value.PSObject.Properties['name']){$Value.name=$finalName};if($Value.PSObject.Properties['displayName']){$Value.displayName=$finalName}}
    }
    [byte[]]$bytes=ConvertTo-StableJsonBytes $Value
    $entries.Add([pscustomobject]@{Path=$path;Bytes=$bytes}) | Out-Null
    return $finalName
}

$major=([version]$manifest.version).Major
$settingsCount=0
$settingsSpecs=@(Read-JsonFile (Join-Path $PackRoot ([string]$manifest.settingsCatalogSpec)) 'Settings Catalog specification')
foreach($spec in $settingsSpecs | Sort-Object recommendationId,displayName){
    if(-not (Test-CpcProfileSelected -Profiles $spec.profiles -Selector $Profile)){continue}
    $recommendationId=[string]$spec.recommendationId
    $recommendationIdsProperty=$spec.PSObject.Properties['recommendationIds']
    $recommendationIds=if($recommendationIdsProperty){@($recommendationIdsProperty.Value|ForEach-Object{[string]$_})}else{@($recommendationId)}
    $recommendationIds=@($recommendationIds)
    if(-not $recommendationById.ContainsKey($recommendationId)){throw "Private extraction lacks mapped recommendation '$recommendationId'."}
    foreach($mappedId in $recommendationIds){if(-not $recommendationById.ContainsKey($mappedId)){throw "Private extraction lacks mapped recommendation '$mappedId'."}}
    $recommendation=$recommendationById[$recommendationId]
    $definitionId=[string]$spec.resolve.definitionId
    if([string]::IsNullOrWhiteSpace($definitionId) -or -not $definitionCache.ContainsKey($definitionId)){throw "Snapshot lacks explicit definition '$definitionId' for recommendation '$recommendationId'."}
    $definition=Get-CpcSettingDefinition -Spec $spec -Definitions $definitions -Cache $definitionCache
    $body=New-CpcConfigurationSettingBody -Definition $definition -Spec $spec -Definitions $definitions -DefinitionCache $definitionCache
    $policyName=[string]$spec.policy
    if(-not $policyByName.ContainsKey($policyName)){throw "Pack lacks policy metadata '$policyName'."}
    $policy=$policyByName[$policyName]
    $primary=Get-PrimarySettingSpec $spec
    $displayName=ConvertTo-PolicySafeText ([string]$primary.displayName)
    $configured=Get-ConfiguredValueText $primary $definitionCache
    $area=Get-PolicyArea $spec $recommendation ([string]$extraction.benchmark.id)
    $profileToken=Get-ProfileToken $spec.profiles
    $scope=Get-SettingScopeToken $primary
    $name="V$major-CIS-$profileToken-$scope-$area-Ensure $displayName is set to $configured"
    $seed="$($manifest.id)|$($recommendationIds -join ',')|$definitionId"
    $name=Limit-PolicyName $name $seed
    $description="Generated from $($manifest.name) $($manifest.version), recommendation(s) $($recommendationIds -join ', '). Exact setting/value identifiers are compiled from the validated pack and pinned snapshot. Unassigned. Not an official CIS Build Kit."
    $raw=New-RawSettingsCatalogPolicy -Name $name -Description $description -Platforms ([string]$policy.platforms) -Technologies ([string]$policy.technologies) -Setting $body -Seed $seed
    $null=Add-Entry 'SettingsCatalog' $name $raw $seed
    $settingsCount++
}

$graphCount=0
$graphObjects=@(Read-JsonFile (Join-Path $PackRoot ([string]$manifest.graphObjects)) 'Graph object specification')
foreach($object in $graphObjects | Sort-Object name){
    if(-not (Test-CpcProfileSelected -Profiles $object.profiles -Selector $Profile)){continue}
    $contractInfo=Get-CpcGraphObjectContract -ContractId ([string]$object.contractId) -ExpectedSha256 ([string]$object.contractSha256) -RepoRoot $repoRoot
    Assert-CpcGraphObjectMatchesContract -GraphObject $object -Contract $contractInfo.Contract
    $profileToken=Get-ProfileToken $object.profiles
    $area=if([string]$object.name -match '^CIS - (?<area>.+?) \[[^\]]+\]'){ConvertTo-PolicySafeText $Matches.area}else{ConvertTo-PolicySafeText ([string]$manifest.name)}
    $endpointLeaf=([Uri]([string]$object.endpoint)).AbsolutePath.TrimEnd('/').Split('/')[-1]
    $folder=switch($endpointLeaf){'deviceConfigurations'{'DeviceConfigurations'}'deviceCompliancePolicies'{'CompliancePolicies'}default{'GraphObjects'}}
    $excluded=@('@odata.type',[string]$object.nameProperty,'description','roleScopeTagIds')
    $configurableProperties=@($object.payload.PSObject.Properties | Where-Object {$excluded -notcontains $_.Name} | Sort-Object Name)
    $propertyMappingsProperty=$object.PSObject.Properties['propertyMappings']
    if($configurableProperties.Count -gt 1 -and -not $propertyMappingsProperty){throw "Graph object '$($object.name)' has multiple configurable properties but no exact propertyMappings."}
    $exportGroups=[System.Collections.Generic.List[object]]::new()
    if($propertyMappingsProperty){
        $mappingGroups=@($propertyMappingsProperty.Value|Group-Object {if($_.PSObject.Properties['bundleId']){[string]$_.bundleId}else{[string]$_.propertyName}})
        foreach($mappingGroup in $mappingGroups){
            $groupProperties=[System.Collections.Generic.List[object]]::new()
            $groupRecommendationIds=[System.Collections.Generic.List[string]]::new()
            foreach($mapping in @($mappingGroup.Group)){
                $matches=@($configurableProperties|Where-Object{[string]$_.Name -ceq [string]$mapping.propertyName})
                if($matches.Count -ne 1){throw "Graph object '$($object.name)' mapping '$($mapping.propertyName)' did not resolve to exactly one payload property."}
                $groupProperties.Add($matches[0])|Out-Null
                foreach($mappedId in @($mapping.recommendationIds|ForEach-Object{[string]$_})){if(-not $groupRecommendationIds.Contains($mappedId)){$groupRecommendationIds.Add($mappedId)|Out-Null}}
            }
            $exportGroups.Add([pscustomobject]@{Properties=@($groupProperties);RecommendationIds=@($groupRecommendationIds)})|Out-Null
        }
    }else{
        foreach($property in $configurableProperties){$exportGroups.Add([pscustomobject]@{Properties=@($property);RecommendationIds=@($object.recommendationIds|ForEach-Object{[string]$_})})|Out-Null}
    }
    foreach($exportGroup in $exportGroups){
        $groupProperties=@($exportGroup.Properties)
        $propertyRecommendationIds=@($exportGroup.RecommendationIds)
        foreach($mappedId in $propertyRecommendationIds){if(-not $recommendationById.ContainsKey($mappedId)){throw "Private extraction lacks Graph-mapped recommendation '$mappedId'."}}
        $primaryRecommendation=$recommendationById[$propertyRecommendationIds[0]]
        $primaryProperty=$groupProperties[0]
        $displayName=ConvertTo-HumanPropertyName $primaryProperty.Name
        $configured=if($groupProperties.Count -eq 1){ConvertTo-PolicySafeText (Get-GraphValueText $primaryProperty.Value)}else{'configured as a validated bundle'}
        if([string]::IsNullOrWhiteSpace($configured)){$configured='configured'}
        $recommendationTitle=ConvertTo-PolicySafeText ([string]$primaryRecommendation.title)
        $settingText=if($recommendationTitle -match '(?i)\bis set to\b'){$recommendationTitle}else{"$displayName is set to $configured"}
        $name="V$major-CIS-$profileToken-D-$area-Ensure $settingText"
        $seed="$($manifest.id)|$($propertyRecommendationIds -join ',')|$($object.name)|$(($groupProperties.Name) -join ',')"
        $name=Limit-PolicyName $name $seed
        $description="Generated from $($manifest.name) $($manifest.version), recommendation(s) $($propertyRecommendationIds -join ', '). Exact typed Graph properties '$(($groupProperties.Name) -join ', ')' are exported from the validated pack. Unassigned. Not an official CIS Build Kit."
        $payload=[ordered]@{'@odata.type'=[string]$object.payload.'@odata.type'}
        $nameProperty=[string]$object.nameProperty
        if($nameProperty){$payload[$nameProperty]=$name}
        if($object.payload.PSObject.Properties['description']){$payload.description=$description}
        foreach($property in $groupProperties){$payload[$property.Name]=$property.Value}
        $payloadObject=[pscustomobject]$payload
        $envelope=[ordered]@{name=$name;endpoint=[string]$object.endpoint;listEndpoint=[string]$object.listEndpoint;nameProperty=(Get-OptionalProperty $object 'nameProperty');payload=$payloadObject}
        $operation=Get-OptionalProperty $object 'operation'
        if($operation){$envelope.operation=[string]$operation}
        $envelope=[pscustomobject]$envelope
        Assert-CpcGraphObjectMatchesContract -GraphObject $envelope -Contract $contractInfo.Contract
        $raw=New-RawGenericGraphObject $payloadObject $name $description $seed
        $null=Add-Entry $folder $name $raw $seed
        $graphCount++
    }
}

if($entries.Count -eq 0){throw 'No mapped policy settings were selected for the Windows-style bundle.'}
$outputParent=Split-Path -Parent $OutputPath
if(-not $outputParent){$outputParent=(Get-Location).Path}
if(-not (Test-Path -LiteralPath $outputParent)){New-Item -ItemType Directory -Path $outputParent -Force | Out-Null}
$stagePath=Join-Path $outputParent ('.cpc-windows-style-'+[guid]::NewGuid().ToString('N')+'.zip')
try {
    $fileStream=[IO.File]::Open($stagePath,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try {
        $archive=[IO.Compression.ZipArchive]::new($fileStream,[IO.Compression.ZipArchiveMode]::Create,$false)
        try {
            foreach($item in $entries | Sort-Object Path){
                $entry=$archive.CreateEntry([string]$item.Path,[IO.Compression.CompressionLevel]::Optimal)
                $entry.LastWriteTime=[DateTimeOffset]::new(1980,1,1,0,0,0,[TimeSpan]::Zero)
                $stream=$entry.Open()
                try {$stream.Write($item.Bytes,0,$item.Bytes.Length)}finally{$stream.Dispose()}
            }
        } finally {$archive.Dispose()}
    } finally {$fileStream.Dispose()}
    $validation=& (Join-Path $PSScriptRoot 'Test-CISWindowsStylePolicyBundle.ps1') -BundlePath $stagePath -PassThru
    if(-not $validation.IsValid){throw "Generated Windows-style bundle failed validation:`n$($validation.Issues -join [Environment]::NewLine)"}
    [IO.File]::Move($stagePath,$OutputPath)
} finally {if(Test-Path -LiteralPath $stagePath){Remove-Item -LiteralPath $stagePath -Force}}

Write-Host "Generated validated Windows-style policy ZIP: $OutputPath"
Write-Host "Root folder              : $BundleName"
Write-Host "Settings Catalog policies: $settingsCount"
Write-Host "Typed Graph policies     : $graphCount"
Write-Host 'Top-level settings/object: one per JSON file'
Write-Host 'Assignments              : none'
