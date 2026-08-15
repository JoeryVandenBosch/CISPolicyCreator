[CmdletBinding()]
param(
    [string]$PythonCommand='python',
    [string]$EnvironmentPath,
    [switch]$IncludeGraph,
    [switch]$PassThru
)

$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$repoRoot=Split-Path -Parent $PSScriptRoot
if($PSVersionTable.PSVersion -lt [version]'7.0'){
    throw "PowerShell 7 or later is required; found $($PSVersionTable.PSVersion)."
}

$basePython=if(Test-Path -LiteralPath $PythonCommand){
    (Resolve-Path -LiteralPath $PythonCommand).Path
}else{
    (Get-Command $PythonCommand -ErrorAction Stop).Source
}
$baseVersionText=& $basePython -c 'import sys; print(".".join(map(str, sys.version_info[:3])))'
if($LASTEXITCODE -ne 0){throw 'Could not determine the base Python version.'}
if([version]$baseVersionText -lt [version]'3.11'){throw "Python 3.11 or later is required; found $baseVersionText."}

$environmentRoot=if($EnvironmentPath){[IO.Path]::GetFullPath($EnvironmentPath)}else{Join-Path $repoRoot '.venv'}
if(Test-Path -LiteralPath $environmentRoot -PathType Leaf){throw "EnvironmentPath is a file: $environmentRoot"}
$created=$false
if(-not (Test-Path -LiteralPath $environmentRoot)){
    $parent=Split-Path -Parent $environmentRoot
    if($parent -and -not (Test-Path -LiteralPath $parent)){New-Item -ItemType Directory -Path $parent | Out-Null}
    & $basePython -m venv $environmentRoot
    if($LASTEXITCODE -ne 0){throw "Python failed to create the virtual environment: $environmentRoot"}
    $created=$true
}

$environmentPythonCandidates=if($IsWindows){
    @((Join-Path $environmentRoot 'Scripts\python.exe'))
}else{
    @((Join-Path $environmentRoot 'bin/python'))
}
$environmentPython=@($environmentPythonCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1)
if($environmentPython.Count -ne 1){throw "EnvironmentPath is not a usable Python virtual environment: $environmentRoot"}
$environmentPython=(Resolve-Path -LiteralPath $environmentPython[0]).Path

$requirements=Join-Path $repoRoot 'tools\requirements.txt'
& $environmentPython -m pip install --require-hashes -r $requirements | Out-Host
if($LASTEXITCODE -ne 0){throw 'Hash-locked Python dependency installation failed.'}

if($IncludeGraph){
    $graphContract=Import-PowerShellDataFile -LiteralPath (Join-Path $repoRoot 'tools\powershell-requirements.psd1')
    $graphName=[string]$graphContract.MicrosoftGraphAuthentication.Name
    $graphVersion=[version]$graphContract.MicrosoftGraphAuthentication.Version
    $graphRepository=[string]$graphContract.MicrosoftGraphAuthentication.Repository
    $moduleRoot=Join-Path $repoRoot '.modules'
    if(Test-Path -LiteralPath $moduleRoot -PathType Leaf){throw "Graph module root is a file: $moduleRoot"}
    $localManifest=Join-Path $moduleRoot "$graphName\$graphVersion\$graphName.psd1"
    if(-not (Test-Path -LiteralPath $localManifest -PathType Leaf)){
        if(-not (Get-Command Save-Module -ErrorAction SilentlyContinue)){
            throw 'PowerShellGet Save-Module is required to bootstrap the repository-local Graph prerequisite.'
        }
        if(-not (Test-Path -LiteralPath $moduleRoot)){New-Item -ItemType Directory -Path $moduleRoot | Out-Null}
        Save-Module -Name $graphName -RequiredVersion ([string]$graphVersion) -Repository $graphRepository -Path $moduleRoot -AcceptLicense -Force -ErrorAction Stop
    }
    if(-not (Test-Path -LiteralPath $localManifest -PathType Leaf)){
        throw "Graph bootstrap did not produce the locked module manifest: $localManifest"
    }
}

$validationArgs=@{PythonPath=$environmentPython;PassThru=$true}
if($IncludeGraph){$validationArgs.RequireGraph=$true}
$validation=& (Join-Path $PSScriptRoot 'Test-CISPrerequisites.ps1') @validationArgs

$result=[pscustomobject][ordered]@{
    EnvironmentPath=$environmentRoot
    PythonPath=$environmentPython
    Created=$created
    Prerequisites=$validation
}
Write-Host "Offline environment ready: $environmentRoot"
if(-not $IncludeGraph){Write-Host 'Graph tooling remains optional. Run this initializer with -IncludeGraph before live operations.'}
if($PassThru){return $result}
