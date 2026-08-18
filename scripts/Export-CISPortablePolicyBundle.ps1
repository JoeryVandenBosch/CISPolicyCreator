[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PackRoot,
    [Parameter(Mandatory)][string]$SettingsCatalogSnapshotPath,
    [Parameter(Mandatory)][string]$OutputPath,
    [ValidateSet('L1','L2','BL','L1BL','ALL')][string]$Profile='ALL'
)

$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$repoRoot=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repoRoot 'src\CISPolicyCreator.psm1') -Force -DisableNameChecking
Add-Type -AssemblyName System.IO.Compression

$PackRoot=(Resolve-Path -LiteralPath $PackRoot).Path
$SettingsCatalogSnapshotPath=(Resolve-Path -LiteralPath $SettingsCatalogSnapshotPath).Path
$OutputPath=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
$Profile=$Profile.ToUpperInvariant()
if([IO.Path]::GetExtension($OutputPath) -cne '.zip'){throw 'OutputPath must use the lowercase .zip extension.'}
if(Test-Path -LiteralPath $OutputPath){throw "OutputPath already exists: $OutputPath"}

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
    $property=$Object.PSObject.Properties[$Name]
    if($property){return $property.Value}
    return $Default
}

function Get-SafeFileStem([string]$Value,[string]$Fallback) {
    $stem=($Value -replace '[^A-Za-z0-9._-]','-').Trim('-','.',' ')
    $stem=$stem -replace '-+','-'
    if([string]::IsNullOrWhiteSpace($stem)){$stem=$Fallback}
    if($stem.Length -gt 100){
        [byte[]]$nameBytes=[Text.UTF8Encoding]::new($false).GetBytes($Value)
        $suffix=(Get-BytesSha256 $nameBytes).Substring(0,8)
        $stem=$stem.Substring(0,91).TrimEnd('-','.')+'-'+$suffix
    }
    return $stem
}

$manifestPath=Join-Path $PackRoot 'manifest.json'
$manifest=Read-JsonFile $manifestPath 'Pack manifest'
$snapshotJson=Get-Content -LiteralPath $SettingsCatalogSnapshotPath -Raw
$snapshotSchema=Join-Path $repoRoot 'schemas\settings-catalog-snapshot.schema.json'
if(-not ($snapshotJson | Test-Json -SchemaFile $snapshotSchema -ErrorAction Stop)){throw 'Settings Catalog snapshot failed schema validation.'}
$snapshot=$snapshotJson | ConvertFrom-Json -Depth 100
$snapshotHash=Get-FileSha256 $SettingsCatalogSnapshotPath
$expectedSnapshotHash=[string]$manifest.build.settingsCatalogSnapshotSha256
if([string]::IsNullOrWhiteSpace($expectedSnapshotHash)){throw 'Pack manifest has no Settings Catalog snapshot hash; portable export cannot prove its definition evidence.'}
if($snapshotHash -cne $expectedSnapshotHash){throw "Snapshot SHA-256 does not match the pack manifest. Expected=$expectedSnapshotHash; actual=$snapshotHash"}
if([int]$snapshot.retrieval.definitionCount -ne @($snapshot.definitions).Count){throw 'Settings Catalog snapshot definition count is inconsistent.'}

$definitions=@($snapshot.definitions)
$definitionCache=@{}
foreach($definition in $definitions){
    $id=[string]$definition.id
    if($definitionCache.ContainsKey($id)){throw "Settings Catalog snapshot contains duplicate definition ID '$id'."}
    $definitionCache[$id]=$definition
}

$dynamicByPolicy=@{}
$settingsSpecPath=Join-Path $PackRoot ([string]$manifest.settingsCatalogSpec)
$dynamicSpecs=if(Test-Path -LiteralPath $settingsSpecPath){@(Read-JsonFile $settingsSpecPath 'Settings Catalog specification')}else{@()}
foreach($spec in $dynamicSpecs){
    if(-not (Test-CpcProfileSelected -Profiles $spec.profiles -Selector $Profile)){continue}
    $definitionId=[string]$spec.resolve.definitionId
    if([string]::IsNullOrWhiteSpace($definitionId)){throw "Portable offline export requires an explicit definitionId for recommendation '$($spec.recommendationId)'."}
    if(-not $definitionCache.ContainsKey($definitionId)){throw "Snapshot lacks reviewed definition '$definitionId' for recommendation '$($spec.recommendationId)'."}
    $definition=Get-CpcSettingDefinition -Spec $spec -Definitions $definitions -Cache $definitionCache
    $body=New-CpcConfigurationSettingBody -Definition $definition -Spec $spec -Definitions $definitions -DefinitionCache $definitionCache
    $policyName=[string]$spec.policy
    if(-not $dynamicByPolicy.ContainsKey($policyName)){$dynamicByPolicy[$policyName]=[System.Collections.Generic.List[object]]::new()}
    $dynamicByPolicy[$policyName].Add([pscustomobject]@{spec=$spec;body=$body}) | Out-Null
}

$entries=[System.Collections.Generic.List[object]]::new()
$entryPaths=[System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
function Add-BundleEntry([string]$Path,$Value) {
    if(-not $entryPaths.Add($Path)){throw "Portable bundle path collision: $Path"}
    [byte[]]$bytes=ConvertTo-StableJsonBytes $Value
    $record=[pscustomobject]@{Path=$Path;Bytes=$bytes;Sha256=(Get-BytesSha256 $bytes)}
    $entries.Add($record) | Out-Null
    return $record
}

$selectedRecommendations=@(Read-JsonFile (Join-Path $PackRoot ([string]$manifest.recommendationsSpec)) 'Recommendation specification' | Where-Object {Test-CpcProfileSelected -Profiles $_.profiles -Selector $Profile})
$selectedRecommendationIds=[System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach($recommendation in $selectedRecommendations){$null=$selectedRecommendationIds.Add([string]$recommendation.recommendationId)}

$settingsCatalogRecords=[System.Collections.Generic.List[object]]::new()
$totalSettings=0
$policyDirectory=Join-Path $PackRoot ([string]$manifest.settingsCatalogPolicyDirectory)
if(Test-Path -LiteralPath $policyDirectory){
    foreach($file in Get-ChildItem -LiteralPath $policyDirectory -Filter '*.json' | Sort-Object Name){
        $bundle=Read-JsonFile $file.FullName "Policy bundle '$($file.Name)'"
        if(-not (Test-CpcProfileSelected -Profiles $bundle.profiles -Selector $Profile)){continue}
        $name=[string]$bundle.policy.name
        $dynamicEntries=if($dynamicByPolicy.ContainsKey($name)){@($dynamicByPolicy[$name])}else{@()}
        $static=ConvertTo-CpcWritablePayload -InputObject @($bundle.settings)
        $merged=Merge-CpcConfigurationSettings -StaticSettings $static -DynamicEntries $dynamicEntries
        if(@($merged).Count -eq 0){throw "Selected policy '$name' has zero settings."}
        $payload=New-CpcSettingsCatalogPolicyBody -Policy $bundle.policy -Settings $merged
        if(Test-CpcObjectContainsAssignments -InputObject $payload){throw "Selected policy '$name' contains assignment data."}
        $path='SettingsCatalog/'+(Get-SafeFileStem $file.BaseName 'policy')+'.json'
        $entry=Add-BundleEntry $path $payload
        $recommendationIds=@($bundle.recommendationIds | Where-Object {$selectedRecommendationIds.Contains([string]$_)} | ForEach-Object {[string]$_} | Sort-Object -Unique)
        if($recommendationIds.Count -eq 0){throw "Selected policy '$name' has no selected mapped recommendation IDs."}
        $record=[pscustomobject][ordered]@{
            path=$path;name=$name;platforms=[string]$payload.platforms;technologies=[string]$payload.technologies
            recommendationIds=$recommendationIds;settingCount=@($payload.settings).Count;sha256=$entry.Sha256
        }
        $settingsCatalogRecords.Add($record) | Out-Null
        $totalSettings+=@($payload.settings).Count
    }
}

$graphObjectRecords=[System.Collections.Generic.List[object]]::new()
$graphObjectsPath=Join-Path $PackRoot ([string]$manifest.graphObjects)
$graphObjects=if(Test-Path -LiteralPath $graphObjectsPath){@(Read-JsonFile $graphObjectsPath 'Graph object specification')}else{@()}
$graphIndex=0
foreach($object in $graphObjects){
    if(-not (Test-CpcProfileSelected -Profiles $object.profiles -Selector $Profile)){continue}
    $graphIndex++
    $endpoint=[string]$object.endpoint
    $listEndpoint=if(Get-OptionalProperty $object 'listEndpoint') {[string]$object.listEndpoint}else{$endpoint}
    if(-not (Test-CpcGraphEndpointSafe -Uri $endpoint) -or -not (Test-CpcGraphEndpointSafe -Uri $listEndpoint)){throw "Graph object '$($object.name)' has an unsafe endpoint."}
    $payload=ConvertTo-CpcWritablePayload -InputObject $object.payload
    if(Test-CpcObjectContainsAssignments -InputObject $payload){throw "Graph object '$($object.name)' contains assignment data."}
    $contractInfo=Get-CpcGraphObjectContract -ContractId ([string]$object.contractId) -ExpectedSha256 ([string]$object.contractSha256) -RepoRoot $repoRoot
    Assert-CpcGraphObjectMatchesContract -GraphObject $object -Contract $contractInfo.Contract
    $leaf=([Uri]$endpoint).AbsolutePath.TrimEnd('/').Split('/')[-1]
    $folder=switch($leaf){'deviceConfigurations'{'DeviceConfigurations'}'compliancePolicies'{'CompliancePolicies'}default{'GraphObjects'}}
    $path=$folder+'/'+(Get-SafeFileStem ([string]$object.name) "graph-object-$graphIndex")+'.json'
    $entry=Add-BundleEntry $path $payload
    $recommendationIds=@($object.recommendationIds | Where-Object {$selectedRecommendationIds.Contains([string]$_)} | ForEach-Object {[string]$_} | Sort-Object -Unique)
    if($recommendationIds.Count -eq 0){throw "Graph object '$($object.name)' has no selected mapped recommendation IDs."}
    $graphObjectRecords.Add([pscustomobject][ordered]@{
        path=$path;name=[string]$object.name;endpoint=$endpoint;listEndpoint=$listEndpoint
        nameProperty=[string]$object.nameProperty;contractId=[string]$object.contractId;contractSha256=[string]$object.contractSha256
        recommendationIds=$recommendationIds;sha256=$entry.Sha256
    }) | Out-Null
}

$counts=[ordered]@{
    recommendationCount=$selectedRecommendations.Count
    mapped=@($selectedRecommendations | Where-Object mappingStatus -eq 'mapped').Count
    unresolved=@($selectedRecommendations | Where-Object mappingStatus -eq 'unresolved').Count
    requiresInput=@($selectedRecommendations | Where-Object mappingStatus -eq 'requires-input').Count
    manual=@($selectedRecommendations | Where-Object mappingStatus -eq 'manual').Count
    notApplicable=@($selectedRecommendations | Where-Object mappingStatus -eq 'not-applicable').Count
    settingsCatalogPolicyCount=$settingsCatalogRecords.Count
    settingsCatalogSettingCount=$totalSettings
    graphObjectCount=$graphObjectRecords.Count
}
$counts.partial=($counts.unresolved+$counts.requiresInput+$counts.manual) -gt 0

$mappingRows=[System.Collections.Generic.List[object]]::new()
foreach($recommendation in $selectedRecommendations | Sort-Object recommendationId){
    $mappingRows.Add([pscustomobject][ordered]@{
        recommendationId=[string]$recommendation.recommendationId
        profiles=@($recommendation.profiles)
        cisAssessmentMethod=[string]$recommendation.cisAssessmentMethod
        mappingStatus=[string]$recommendation.mappingStatus
        catalogMappingStatus=Get-OptionalProperty $recommendation 'catalogMappingStatus'
        decisionRef=Get-OptionalProperty $recommendation 'decisionRef'
        implementationType=Get-OptionalProperty $recommendation 'implementationType'
        implementationRefs=@(Get-OptionalProperty $recommendation 'implementationRefs' @())
    }) | Out-Null
}
$mappingReport=[ordered]@{
    schemaVersion='1.0'
    pack=[ordered]@{id=[string]$manifest.id;name=[string]$manifest.name;version=[string]$manifest.version}
    profile=$Profile
    summary=$counts
    recommendations=@($mappingRows)
}
$mappingEntry=Add-BundleEntry 'mapping-report.json' $mappingReport

$portableManifest=[ordered]@{
    schemaVersion='1.0'
    bundleType='cispolicycreator-portable-intune-json'
    pack=[ordered]@{id=[string]$manifest.id;name=[string]$manifest.name;version=[string]$manifest.version}
    profile=$Profile
    source=[ordered]@{fileName=[string]$manifest.source.fileName;sha256=[string]$manifest.source.sha256;pageCount=[int]$manifest.source.pageCount;documentIncluded=$false}
    build=[ordered]@{packManifestSha256=(Get-FileSha256 $manifestPath);settingsCatalogSnapshotSha256=$snapshotHash}
    assignmentsIncluded=$false
    tenantMetadataIncluded=$false
    files=[ordered]@{
        mappingReport=[ordered]@{path='mapping-report.json';sha256=$mappingEntry.Sha256}
        settingsCatalog=@($settingsCatalogRecords | Sort-Object path)
        graphObjects=@($graphObjectRecords | Sort-Object path)
    }
    summary=$counts
}
$null=Add-BundleEntry 'bundle-manifest.json' $portableManifest

$outputParent=Split-Path -Parent $OutputPath
if(-not $outputParent){$outputParent=(Get-Location).Path}
if(-not (Test-Path -LiteralPath $outputParent)){New-Item -ItemType Directory -Path $outputParent -Force | Out-Null}
$stagePath=Join-Path $outputParent ('.cpc-portable-'+[guid]::NewGuid().ToString('N')+'.zip')
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
    $validation=& (Join-Path $PSScriptRoot 'Test-CISPortablePolicyBundle.ps1') -BundlePath $stagePath -PassThru
    if(-not $validation.IsValid){throw "Generated portable bundle failed validation:`n$($validation.Issues -join [Environment]::NewLine)"}
    [IO.File]::Move($stagePath,$OutputPath)
} finally {
    if(Test-Path -LiteralPath $stagePath){Remove-Item -LiteralPath $stagePath -Force}
}

Write-Host "Generated validated portable policy JSON bundle: $OutputPath"
Write-Host "Settings Catalog policies : $($settingsCatalogRecords.Count)"
Write-Host "Generic Graph objects      : $($graphObjectRecords.Count)"
Write-Host "Mapped recommendations     : $($counts.mapped)"
Write-Host "Unresolved/requires input  : $($counts.unresolved+$counts.requiresInput)"
Write-Host 'Assignments                : none'
Write-Host 'Tenant-generated metadata  : none'
