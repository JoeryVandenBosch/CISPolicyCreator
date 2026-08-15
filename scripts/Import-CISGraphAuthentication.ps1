[CmdletBinding()]
param([switch]$PassThru)

$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$repoRoot=Split-Path -Parent $PSScriptRoot
$contract=Import-PowerShellDataFile -LiteralPath (Join-Path $repoRoot 'tools\powershell-requirements.psd1')
$name=[string]$contract.MicrosoftGraphAuthentication.Name
$requiredVersion=[version]$contract.MicrosoftGraphAuthentication.Version
$requiredTreeHash=[string]$contract.MicrosoftGraphAuthentication.TreeSha256
$localManifest=Join-Path $repoRoot ".modules\$name\$requiredVersion\$name.psd1"

if(Test-Path -LiteralPath $localManifest -PathType Leaf){
    $moduleBase=Split-Path -Parent $localManifest
    $moduleReference=$localManifest
    $source='repository-local'
}else{
    $available=@(Get-Module -ListAvailable -Name $name | Where-Object Version -eq $requiredVersion | Select-Object -First 1)
    if($available.Count -ne 1){
        throw "$name $requiredVersion is required for live operations. Run .\scripts\Initialize-CISPolicyCreator.ps1 -IncludeGraph."
    }
    $moduleBase=[string]$available[0].ModuleBase
    $moduleReference=@{ModuleName=$name;RequiredVersion=$requiredVersion}
    $source='installed'
}

$hashEntries=[Collections.Generic.List[string]]::new()
foreach($file in @(Get-ChildItem -LiteralPath $moduleBase -Recurse -File -Force | Where-Object Name -ne 'PSGetModuleInfo.xml')){
    $relative=[IO.Path]::GetRelativePath($moduleBase,$file.FullName).Replace([IO.Path]::DirectorySeparatorChar,[char]'/')
    $fileHash=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    $hashEntries.Add("$relative`t$fileHash")
}
if($hashEntries.Count -eq 0){throw "$name $requiredVersion contains no verifiable module files."}
$hashEntries.Sort([StringComparer]::Ordinal)
$treePayload=[string]::Join("`n",$hashEntries)
$sha256=[Security.Cryptography.SHA256]::Create()
try{$actualTreeHash=([BitConverter]::ToString($sha256.ComputeHash([Text.Encoding]::UTF8.GetBytes($treePayload))) -replace '-','').ToLowerInvariant()}
finally{$sha256.Dispose()}
if($actualTreeHash -cne $requiredTreeHash){
    throw "$name $requiredVersion content hash '$actualTreeHash' does not match the repository lock '$requiredTreeHash'."
}

$module=@(Import-Module -Name $moduleReference -Global -Force -PassThru -ErrorAction Stop | Where-Object Name -eq $name | Select-Object -First 1)
if($module.Count -ne 1 -or [version]$module[0].Version -ne $requiredVersion){
    throw "$name did not load at the required version $requiredVersion."
}
foreach($commandName in @('Connect-MgGraph','Disconnect-MgGraph','Get-MgContext','Invoke-MgGraphRequest')){
    $command=Get-Command -Name $commandName -ErrorAction SilentlyContinue
    if(-not $command -or [string]$command.Source -cne $name){
        throw "$name $requiredVersion did not provide required command '$commandName'."
    }
}

$result=[pscustomobject][ordered]@{
    Name=$name
    Version=[string]$requiredVersion
    Source=$source
    ModuleBase=[string]$module[0].ModuleBase
    ContentSha256=$actualTreeHash
}
Write-Host "Graph module   : $name $requiredVersion ($source)"
if($PassThru){return $result}
