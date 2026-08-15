[CmdletBinding()]
param(
    [string]$PythonCommand='python',
    [string]$EnvironmentPath,
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
$validation=& (Join-Path $PSScriptRoot 'Test-CISPrerequisites.ps1') -PythonPath $environmentPython -PassThru

$result=[pscustomobject][ordered]@{
    EnvironmentPath=$environmentRoot
    PythonPath=$environmentPython
    Created=$created
    Prerequisites=$validation
}
Write-Host "Offline environment ready: $environmentRoot"
Write-Host 'Microsoft.Graph.Authentication is optional for offline builds and must be installed separately before live operations.'
if($PassThru){return $result}
