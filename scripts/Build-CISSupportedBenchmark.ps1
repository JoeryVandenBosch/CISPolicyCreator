[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet(
        'Windows11-5.0.0',
        'Windows10-5.0.0',
        'Edge-1.0.0',
        'Office-1.1.0',
        'macOS26-Tahoe-1.0.0',
        'iOS26-iPadOS26-1.0.0'
    )]
    [string]$Benchmark,
    [Parameter(Mandatory)][string]$PdfPath,
    [Parameter(Mandatory)][string]$SettingsCatalogSnapshotPath,
    [Parameter(Mandatory)][string]$OutputPath,
    [string]$PythonPath,
    [string]$AdministratorDecisionsPath,
    [switch]$KeepPrivateExtraction
)

$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$repoRoot=Split-Path -Parent $PSScriptRoot
$catalogByBenchmark=@{
    'Windows11-5.0.0'='benchmarks\cis-microsoft-intune-for-windows-11\5.0.0\mapping-catalog.json'
    'Windows10-5.0.0'='benchmarks\cis-microsoft-intune-for-windows-10\5.0.0\mapping-catalog.json'
    'Edge-1.0.0'='benchmarks\edge-intune\1.0.0\mapping-catalog.json'
    'Office-1.1.0'='benchmarks\office-intune\1.1.0\mapping-catalog.json'
    'macOS26-Tahoe-1.0.0'='benchmarks\macos26-tahoe-intune\1.0.0\mapping-catalog.json'
    'iOS26-iPadOS26-1.0.0'='benchmarks\ios26-ipados26-intune\1.0.0\mapping-catalog.json'
}
$catalogPath=Join-Path $repoRoot $catalogByBenchmark[$Benchmark]
if(-not (Test-Path -LiteralPath $catalogPath -PathType Leaf)){
    throw "The repository is missing the catalog for supported benchmark '$Benchmark': $catalogPath"
}

$arguments=@{
    PdfPath=$PdfPath
    MappingCatalogPath=$catalogPath
    SettingsCatalogSnapshotPath=$SettingsCatalogSnapshotPath
    OutputPath=$OutputPath
}
if($PythonPath){$arguments.PythonPath=$PythonPath}
if($AdministratorDecisionsPath){$arguments.AdministratorDecisionsPath=$AdministratorDecisionsPath}
if($KeepPrivateExtraction){$arguments.KeepPrivateExtraction=$true}

& (Join-Path $PSScriptRoot 'Invoke-CISPolicyPipeline.ps1') @arguments
