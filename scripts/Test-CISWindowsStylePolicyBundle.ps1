[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BundlePath,
    [switch]$PassThru
)

$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.IO.Compression
$issues=[System.Collections.Generic.List[string]]::new()
$BundlePath=(Resolve-Path -LiteralPath $BundlePath).Path

function Read-EntryJson($Entry) {
    $stream=$Entry.Open()
    $reader=[IO.StreamReader]::new($stream,[Text.UTF8Encoding]::new($false,$true),$true)
    try {return $reader.ReadToEnd() | ConvertFrom-Json -Depth 100}
    catch {$issues.Add("Invalid UTF-8 JSON '$($Entry.FullName)': $($_.Exception.Message)");return $null}
    finally {$reader.Dispose();$stream.Dispose()}
}

function Test-SafeEntryPath([string]$Path) {
    if([string]::IsNullOrWhiteSpace($Path) -or $Path.Contains('\') -or $Path.StartsWith('/') -or [IO.Path]::IsPathRooted($Path)){return $false}
    $segments=@($Path.Split('/'))
    return $segments.Count -eq 3 -and @($segments | Where-Object {$_ -in @('','.', '..')}).Count -eq 0
}

function Test-SettingInstance($Instance,[string]$Path) {
    if($null -eq $Instance){$issues.Add("$Path has no setting instance.");return}
    if([string]::IsNullOrWhiteSpace([string]$Instance.settingDefinitionId)){$issues.Add("$Path has a setting instance without an explicit settingDefinitionId.")}
    if($Instance.PSObject.Properties['choiceSettingValue']){
        if([string]::IsNullOrWhiteSpace([string]$Instance.choiceSettingValue.value)){$issues.Add("$Path has a choice without an explicit value ID.")}
        foreach($child in @($Instance.choiceSettingValue.children)){Test-SettingInstance $child $Path}
    } elseif($Instance.PSObject.Properties['simpleSettingValue']){
        if($null -eq $Instance.simpleSettingValue.value){$issues.Add("$Path has a null simple value.")}
    } elseif($Instance.PSObject.Properties['simpleSettingCollectionValue']){
        $values=@($Instance.simpleSettingCollectionValue)
        if($values.Count -eq 0 -or @($values | Where-Object {$null -eq $_.value}).Count -gt 0){$issues.Add("$Path has an empty or null simple collection value.")}
    } elseif($Instance.PSObject.Properties['groupSettingCollectionValue']){
        $groups=@($Instance.groupSettingCollectionValue)
        if($groups.Count -eq 0){$issues.Add("$Path has an empty group collection.")}
        foreach($group in $groups){foreach($child in @($group.children)){Test-SettingInstance $child $Path}}
    } else {$issues.Add("$Path has an unsupported setting instance type.")}
}

if([IO.Path]::GetExtension($BundlePath) -cne '.zip'){$issues.Add('Bundle must use the lowercase .zip extension.')}
$archive=$null
$settingsCount=0
$graphCount=0
$rootName=$null
try {
    $archive=[IO.Compression.ZipFile]::OpenRead($BundlePath)
    $entries=@($archive.Entries | Where-Object {-not [string]::IsNullOrEmpty($_.Name)})
    if($entries.Count -eq 0){$issues.Add('Bundle contains no policy JSON files.')}
    $paths=[System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($entry in $entries){
        $path=[string]$entry.FullName
        if(-not (Test-SafeEntryPath $path)){$issues.Add("Entry does not use '<root>/<policy-type>/<file>.json': $path");continue}
        if(-not $paths.Add($path)){$issues.Add("Duplicate case-insensitive entry path: $path")}
        $segments=$path.Split('/')
        if($null -eq $rootName){$rootName=$segments[0]}elseif($rootName -cne $segments[0]){$issues.Add("Bundle contains multiple root folders: $path")}
        if([IO.Path]::GetExtension($segments[2]) -cne '.json'){$issues.Add("Non-JSON policy file: $path");continue}
        $nameFromFile=[IO.Path]::GetFileNameWithoutExtension($segments[2])
        if($nameFromFile.Length -gt 180){$issues.Add("Policy filename exceeds the Windows reference limit of 180 characters: $path")}
        $fullNamePattern='^V\d+-CIS-[A-Z0-9]+-[DU]-.+-Ensure .+ is set to .+$'
        $truncatedNamePattern='^V\d+-CIS-[A-Z0-9]+-[DU]-.+-Ensure .+ - [0-9a-f]{8}$'
        if($nameFromFile -cnotmatch $fullNamePattern -and $nameFromFile -cnotmatch $truncatedNamePattern){$issues.Add("Policy filename does not match the Windows naming convention: $path")}
        $json=Read-EntryJson $entry
        if($null -eq $json){continue}
        $assignmentsProperty=$json.PSObject.Properties['assignments']
        if($assignmentsProperty -and @($assignmentsProperty.Value).Count -gt 0){$issues.Add("$path contains assignments.")}
        switch($segments[1]){
            'SettingsCatalog' {
                $settingsCount++
                if([string]$json.name -cne $nameFromFile){$issues.Add("$path filename does not exactly match its JSON policy name.")}
                if([string]$json.'@odata.type' -cne '#microsoft.graph.deviceManagementConfigurationPolicy'){$issues.Add("$path is not an export-shaped Settings Catalog policy.")}
                if([string]::IsNullOrWhiteSpace([string]$json.id) -or [string]$json.'@odata.id' -notmatch [regex]::Escape([string]$json.id)){$issues.Add("$path has missing or incoherent export IDs.")}
                $settings=@($json.settings)
                if($settings.Count -ne 1 -or [int]$json.settingCount -ne 1){$issues.Add("$path must contain exactly one top-level setting.")}
                if($settings.Count -eq 1){Test-SettingInstance $settings[0].settingInstance $path}
            }
            {$_ -in @('DeviceConfigurations','CompliancePolicies','GraphObjects')} {
                $graphCount++
                if([string]$json.displayName -cne $nameFromFile){$issues.Add("$path filename does not exactly match its JSON displayName.")}
                $metadata=@('@odata.type','displayName','description','id','createdDateTime','lastModifiedDateTime','version','assignments','roleScopeTagIds')
                $configured=@($json.PSObject.Properties | Where-Object {$metadata -notcontains $_.Name})
                if($configured.Count -lt 1){$issues.Add("$path must contain at least one typed Graph configuration property.")}
            }
            default {$issues.Add("Unsupported policy folder '$($segments[1])': $path")}
        }
    }
} catch {$issues.Add("Could not validate Windows-style policy bundle: $($_.Exception.Message)")}
finally {if($archive){$archive.Dispose()}}

$result=[pscustomobject]@{IsValid=($issues.Count -eq 0);Issues=@($issues);RootName=$rootName;SettingsCatalogPolicyCount=$settingsCount;GraphPolicyCount=$graphCount;PolicyCount=$settingsCount+$graphCount}
if($PassThru){return $result}
if(-not $result.IsValid){throw ($result.Issues -join [Environment]::NewLine)}
Write-Host 'PASS: Windows-style split-policy ZIP validation succeeded.'
Write-Host "Root folder              : $($result.RootName)"
Write-Host "Settings Catalog policies: $settingsCount"
Write-Host "Typed Graph policies     : $graphCount"
Write-Host 'Top-level settings/object: one per JSON file'
Write-Host 'Assignments              : none'
