[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BundlePath,
    [switch]$PassThru
)

$ErrorActionPreference='Stop'
$repoRoot=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repoRoot 'src\CISPolicyCreator.psm1') -Force -DisableNameChecking
Add-Type -AssemblyName System.IO.Compression
$issues=[System.Collections.Generic.List[string]]::new()
$BundlePath=(Resolve-Path -LiteralPath $BundlePath).Path

function Get-BytesSha256([byte[]]$Bytes) {
    $sha=[Security.Cryptography.SHA256]::Create()
    try { return ([Convert]::ToHexString($sha.ComputeHash($Bytes))).ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-ZipEntryBytes($Entry) {
    $stream=$Entry.Open()
    $memory=[IO.MemoryStream]::new()
    try { $stream.CopyTo($memory); return ,$memory.ToArray() }
    finally { $stream.Dispose(); $memory.Dispose() }
}

function Read-ZipJson($Entry,[string]$Label) {
    try {
        [byte[]]$bytes=Get-ZipEntryBytes $Entry
        $encoding=[Text.UTF8Encoding]::new($false,$true)
        $text=$encoding.GetString($bytes)
        return [pscustomobject]@{Text=$text;Bytes=$bytes;Value=($text | ConvertFrom-Json -Depth 100)}
    } catch {
        $issues.Add("$Label is not valid UTF-8 JSON: $($_.Exception.Message)")
        return $null
    }
}

function Test-SafeEntryPath([string]$Path) {
    if([string]::IsNullOrWhiteSpace($Path) -or $Path.Contains('\') -or $Path.StartsWith('/') -or [IO.Path]::IsPathRooted($Path)){return $false}
    $segments=@($Path.Split('/'))
    if($segments.Count -eq 0 -or @($segments | Where-Object { $_ -in @('','.', '..') }).Count -gt 0){return $false}
    return $true
}

if([IO.Path]::GetExtension($BundlePath) -cne '.zip'){$issues.Add('Portable policy bundle must use the lowercase .zip extension.')}
$archive=$null
try {
    $archive=[IO.Compression.ZipFile]::OpenRead($BundlePath)
    $entries=@($archive.Entries | Where-Object { -not [string]::IsNullOrEmpty($_.Name) })
    $entryByPath=@{}
    foreach($entry in $entries){
        $path=[string]$entry.FullName
        if(-not (Test-SafeEntryPath $path)){$issues.Add("Unsafe ZIP entry path: $path");continue}
        if([IO.Path]::GetExtension($path) -cne '.json'){$issues.Add("Only JSON files are allowed in a portable policy bundle: $path")}
        $key=$path.ToLowerInvariant()
        if($entryByPath.ContainsKey($key)){$issues.Add("Duplicate case-insensitive ZIP entry path: $path")}else{$entryByPath[$key]=$entry}
    }

    $manifestEntry=if($entryByPath.ContainsKey('bundle-manifest.json')){$entryByPath['bundle-manifest.json']}else{$null}
    if(-not $manifestEntry){$issues.Add('bundle-manifest.json is missing.')}
    $manifestRead=if($manifestEntry){Read-ZipJson $manifestEntry 'bundle-manifest.json'}else{$null}
    $manifest=if($manifestRead){$manifestRead.Value}else{$null}
    if($manifestRead){
        try {
            $schema=Join-Path $repoRoot 'schemas\portable-policy-bundle.schema.json'
            if(-not ($manifestRead.Text | Test-Json -SchemaFile $schema -ErrorAction Stop)){$issues.Add('bundle-manifest.json failed schema validation.')}
        } catch {$issues.Add("bundle-manifest.json failed schema validation: $($_.Exception.Message)")}
    }

    if($manifest){
        if(Test-CpcObjectContainsAssignments -InputObject $manifest){$issues.Add('bundle-manifest.json contains assignment data.')}
        $expectedPaths=[System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $null=$expectedPaths.Add('bundle-manifest.json')
        $null=$expectedPaths.Add([string]$manifest.files.mappingReport.path)
        foreach($record in @($manifest.files.settingsCatalog)+@($manifest.files.graphObjects)){$null=$expectedPaths.Add([string]$record.path)}
        foreach($entry in $entries){if(-not $expectedPaths.Contains([string]$entry.FullName)){$issues.Add("ZIP contains an unlisted file: $($entry.FullName)")}}
        foreach($path in $expectedPaths){if(-not $entryByPath.ContainsKey($path.ToLowerInvariant())){$issues.Add("Manifest lists a missing file: $path")}}

        $mappingPath=[string]$manifest.files.mappingReport.path
        if($entryByPath.ContainsKey($mappingPath.ToLowerInvariant())){
            $mappingRead=Read-ZipJson $entryByPath[$mappingPath.ToLowerInvariant()] $mappingPath
            if($mappingRead){
                if((Get-BytesSha256 $mappingRead.Bytes) -cne [string]$manifest.files.mappingReport.sha256){$issues.Add("SHA-256 mismatch: $mappingPath")}
                if(Test-CpcObjectContainsAssignments -InputObject $mappingRead.Value){$issues.Add("$mappingPath contains assignment data.")}
                if([string]$mappingRead.Value.pack.id -cne [string]$manifest.pack.id -or [string]$mappingRead.Value.profile -cne [string]$manifest.profile){$issues.Add("$mappingPath does not match the manifest pack/profile identity.")}
                if(@($mappingRead.Value.recommendations).Count -ne [int]$manifest.summary.recommendationCount){$issues.Add("$mappingPath recommendation count does not match the manifest summary.")}
                if(@($mappingRead.Value.recommendations | Where-Object {$_.PSObject.Properties['title'] -or $_.PSObject.Properties['description']}).Count -gt 0){$issues.Add("$mappingPath contains benchmark prose fields.")}
            }
        }

        $totalSettings=0
        foreach($record in @($manifest.files.settingsCatalog)){
            $path=[string]$record.path
            if(-not $entryByPath.ContainsKey($path.ToLowerInvariant())){continue}
            $read=Read-ZipJson $entryByPath[$path.ToLowerInvariant()] $path
            if(-not $read){continue}
            if((Get-BytesSha256 $read.Bytes) -cne [string]$record.sha256){$issues.Add("SHA-256 mismatch: $path")}
            $payload=$read.Value
            if(Test-CpcObjectContainsAssignments -InputObject $payload){$issues.Add("$path contains assignment data.")}
            $allowed=@('name','description','platforms','technologies','roleScopeTagIds','settings','templateReference')
            $unexpected=@($payload.PSObject.Properties.Name | Where-Object {$allowed -notcontains [string]$_})
            if($unexpected.Count -gt 0){$issues.Add("$path contains non-portable top-level properties: $($unexpected -join ', ')")}
            if([string]$payload.name -cne [string]$record.name -or [string]$payload.platforms -cne [string]$record.platforms -or [string]$payload.technologies -cne [string]$record.technologies){$issues.Add("$path policy metadata differs from its manifest record.")}
            $settings=@($payload.settings)
            if($settings.Count -ne [int]$record.settingCount -or $settings.Count -eq 0){$issues.Add("$path setting count differs from its manifest record or is zero.")}
            foreach($setting in $settings){
                if([string]$setting.'@odata.type' -cne '#microsoft.graph.deviceManagementConfigurationSetting' -or -not $setting.settingInstance.settingDefinitionId){$issues.Add("$path contains an invalid Settings Catalog setting body.")}
            }
            $totalSettings+=$settings.Count
        }

        foreach($record in @($manifest.files.graphObjects)){
            $path=[string]$record.path
            if(-not $entryByPath.ContainsKey($path.ToLowerInvariant())){continue}
            $read=Read-ZipJson $entryByPath[$path.ToLowerInvariant()] $path
            if(-not $read){continue}
            if((Get-BytesSha256 $read.Bytes) -cne [string]$record.sha256){$issues.Add("SHA-256 mismatch: $path")}
            if(Test-CpcObjectContainsAssignments -InputObject $read.Value){$issues.Add("$path contains assignment data.")}
            if(-not (Test-CpcGraphEndpointSafe -Uri ([string]$record.endpoint)) -or -not (Test-CpcGraphEndpointSafe -Uri ([string]$record.listEndpoint))){$issues.Add("$path has an unsafe Graph endpoint.")}
            $nameProperty=[string]$record.nameProperty
            $actualNameProperty=$read.Value.PSObject.Properties[$nameProperty]
            if(-not $actualNameProperty -or [string]$actualNameProperty.Value -cne [string]$record.name){$issues.Add("$path does not contain its manifest name in '$nameProperty'.")}
            try {
                $contractInfo=Get-CpcGraphObjectContract -ContractId ([string]$record.contractId) -ExpectedSha256 ([string]$record.contractSha256) -RepoRoot $repoRoot
                $envelope=[pscustomobject]@{name=[string]$record.name;endpoint=[string]$record.endpoint;listEndpoint=[string]$record.listEndpoint;nameProperty=$nameProperty;payload=$read.Value}
                Assert-CpcGraphObjectMatchesContract -GraphObject $envelope -Contract $contractInfo.Contract
            } catch {$issues.Add("$path failed its pinned Graph contract: $($_.Exception.Message)")}
        }

        $statusTotal=[int]$manifest.summary.mapped+[int]$manifest.summary.unresolved+[int]$manifest.summary.requiresInput+[int]$manifest.summary.manual+[int]$manifest.summary.notApplicable
        if($statusTotal -ne [int]$manifest.summary.recommendationCount){$issues.Add('Manifest recommendation status counts do not add up.')}
        if(@($manifest.files.settingsCatalog).Count -ne [int]$manifest.summary.settingsCatalogPolicyCount){$issues.Add('Manifest Settings Catalog policy count does not match its file list.')}
        if($totalSettings -ne [int]$manifest.summary.settingsCatalogSettingCount){$issues.Add('Manifest Settings Catalog setting count does not match the payloads.')}
        if(@($manifest.files.graphObjects).Count -ne [int]$manifest.summary.graphObjectCount){$issues.Add('Manifest Graph object count does not match its file list.')}
        $shouldBePartial=([int]$manifest.summary.unresolved+[int]$manifest.summary.requiresInput+[int]$manifest.summary.manual) -gt 0
        if([bool]$manifest.summary.partial -ne $shouldBePartial){$issues.Add('Manifest partial flag does not match its nondeployable recommendation counts.')}
    }
} catch {
    $issues.Add("Could not validate portable policy bundle: $($_.Exception.Message)")
} finally {
    if($archive){$archive.Dispose()}
}

$result=[pscustomobject]@{
    IsValid=($issues.Count -eq 0)
    Issues=@($issues)
    SettingsCatalogPolicyCount=if($manifest){@($manifest.files.settingsCatalog).Count}else{0}
    GraphObjectCount=if($manifest){@($manifest.files.graphObjects).Count}else{0}
    RecommendationCount=if($manifest){[int]$manifest.summary.recommendationCount}else{0}
}
if($PassThru){return $result}
if(-not $result.IsValid){throw ($result.Issues -join [Environment]::NewLine)}
Write-Host 'PASS: portable Intune policy JSON bundle validation succeeded.'
Write-Host "Settings Catalog policies : $($result.SettingsCatalogPolicyCount)"
Write-Host "Generic Graph objects      : $($result.GraphObjectCount)"
Write-Host "Recommendations recorded   : $($result.RecommendationCount)"
Write-Host 'Assignments                : none'
