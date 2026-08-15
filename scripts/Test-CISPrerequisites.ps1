[CmdletBinding()]
param(
    [string]$PythonPath,
    [switch]$RequireGraph,
    [switch]$PassThru
)

$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$repoRoot=Split-Path -Parent $PSScriptRoot

if($PSVersionTable.PSVersion -lt [version]'7.0'){
    throw "PowerShell 7 or later is required; found $($PSVersionTable.PSVersion)."
}

function Resolve-Python([AllowNull()][string]$RequestedPath) {
    if($RequestedPath){
        if(Test-Path -LiteralPath $RequestedPath){return (Resolve-Path -LiteralPath $RequestedPath).Path}
        return (Get-Command $RequestedPath -ErrorAction Stop).Source
    }
    $localCandidates=if($IsWindows){
        @((Join-Path $repoRoot '.venv\Scripts\python.exe'))
    }else{
        @((Join-Path $repoRoot '.venv/bin/python'))
    }
    foreach($candidate in $localCandidates){if(Test-Path -LiteralPath $candidate){return (Resolve-Path -LiteralPath $candidate).Path}}
    return (Get-Command python -ErrorAction Stop).Source
}

$python=Resolve-Python $PythonPath
$versionText=& $python -c 'import sys; print(".".join(map(str, sys.version_info[:3])))'
if($LASTEXITCODE -ne 0){throw 'Could not determine the Python version.'}
$pythonVersion=[version]$versionText
if($pythonVersion -lt [version]'3.11') { throw "Python 3.11 or later is required; found $pythonVersion." }

$extractor=Join-Path $repoRoot 'tools\Extract-CISRecommendations.py'
$runtimeOutput=@(& $python $extractor --check-runtime 2>&1)
if($LASTEXITCODE -ne 0){throw "PDF runtime prerequisite validation failed: $($runtimeOutput -join [Environment]::NewLine)"}

$graphContract=Import-PowerShellDataFile -LiteralPath (Join-Path $repoRoot 'tools\powershell-requirements.psd1')
$graphName=[string]$graphContract.MicrosoftGraphAuthentication.Name
$graphVersion=[version]$graphContract.MicrosoftGraphAuthentication.Version
$localGraphManifest=Join-Path $repoRoot ".modules\$graphName\$graphVersion\$graphName.psd1"
$localGraphAvailable=Test-Path -LiteralPath $localGraphManifest -PathType Leaf
$installedGraph=@(Get-Module -ListAvailable -Name $graphName | Where-Object Version -eq $graphVersion | Select-Object -First 1)
$graphAvailable=$localGraphAvailable -or $installedGraph.Count -eq 1
$graphSource=if($localGraphAvailable){'repository-local'}elseif($installedGraph.Count){'installed'}else{$null}
if($RequireGraph){
    $graphValidation=& (Join-Path $PSScriptRoot 'Import-CISGraphAuthentication.ps1') -PassThru
    $graphAvailable=$true
    $graphSource=[string]$graphValidation.Source
}

$result=[pscustomobject][ordered]@{
    IsValid=$true
    PowerShellVersion=[string]$PSVersionTable.PSVersion
    PythonPath=$python
    PythonVersion=[string]$pythonVersion
    PdfParser='pypdf'
    PdfParserVersion=([regex]::Match(($runtimeOutput -join ' '),'pypdf ([0-9]+(?:\.[0-9]+)+(?:[A-Za-z0-9+-]*)?)').Groups[1].Value)
    GraphAuthenticationAvailable=$graphAvailable
    GraphAuthenticationVersion=if($graphAvailable){[string]$graphVersion}else{$null}
    GraphAuthenticationSource=$graphSource
}

Write-Host "PowerShell     : $($result.PowerShellVersion)"
Write-Host "Python         : $($result.PythonVersion) [$($result.PythonPath)]"
Write-Host "PDF parser     : $($result.PdfParser) $($result.PdfParserVersion) (hash-locked contract valid)"
Write-Host "Graph module   : $(if($result.GraphAuthenticationAvailable){$result.GraphAuthenticationVersion+' ('+$result.GraphAuthenticationSource+')'}else{'locked version not installed; offline build remains available'})"
if($PassThru){return $result}
