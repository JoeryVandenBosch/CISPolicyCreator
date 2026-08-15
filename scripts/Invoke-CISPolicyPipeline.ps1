[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PdfPath,
    [Parameter(Mandatory)][string]$MappingCatalogPath,
    [Parameter(Mandatory)][string]$OutputPath,
    [string]$PythonPath,
    [string]$AdministratorDecisionsPath,
    [string]$SettingsCatalogSnapshotPath,
    [ValidateRange(1,4096)][int]$MaxPdfSizeMiB=250,
    [ValidateRange(1,10000)][int]$MaxPdfPages=2000,
    [switch]$KeepPrivateExtraction
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repoRoot = Split-Path -Parent $PSScriptRoot
$pdf = (Resolve-Path -LiteralPath $PdfPath).Path
$catalogPath = (Resolve-Path -LiteralPath $MappingCatalogPath).Path
$catalogJson = Get-Content -LiteralPath $catalogPath -Raw
$catalogSchema = Join-Path $repoRoot 'schemas\mapping-catalog.schema.json'
if (-not ($catalogJson | Test-Json -SchemaFile $catalogSchema -ErrorAction Stop)) { throw 'Mapping catalog failed schema validation.' }
$catalog = $catalogJson | ConvertFrom-Json -Depth 100

$pythonExecutable=if ($PythonPath) {
    (Resolve-Path -LiteralPath $PythonPath).Path
} else {
    $localPython=if($IsWindows){Join-Path $repoRoot '.venv\Scripts\python.exe'}else{Join-Path $repoRoot '.venv/bin/python'}
    if(Test-Path -LiteralPath $localPython){
        (Resolve-Path -LiteralPath $localPython).Path
    }else{
        $pythonCommand=Get-Command python -ErrorAction SilentlyContinue
        if ($pythonCommand) { $pythonCommand.Source } else { $null }
    }
}
if (-not $pythonExecutable) { throw 'Python 3 is required for local PDF extraction. Run scripts/Initialize-CISPolicyCreator.ps1.' }
$extractor = Join-Path $repoRoot 'tools\Extract-CISRecommendations.py'
$outputRoot = [IO.Path]::GetFullPath($OutputPath)
if (Test-Path -LiteralPath $outputRoot) { throw "OutputPath already exists: $outputRoot" }
$parent = Split-Path -Parent $outputRoot
if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
$stagingRoot = Join-Path $parent ('.cpc-staging-' + [guid]::NewGuid().ToString('N'))
$packStaging = Join-Path $stagingRoot 'pack'
$extractionPath = Join-Path $stagingRoot 'source-extraction.private.json'
$privatePath = if ($KeepPrivateExtraction) { "$outputRoot.private-extraction.json" } else { $null }
if ($privatePath -and (Test-Path -LiteralPath $privatePath)) { throw "Private extraction output already exists: $privatePath" }
$completed=$false
$privatePublished=$false

try {
    New-Item -ItemType Directory -Path $stagingRoot | Out-Null
    $extractArgs = [System.Collections.Generic.List[string]]::new()
    foreach ($argument in @($extractor,$pdf,'--benchmark-id',[string]$catalog.benchmark.id,'--benchmark-version',[string]$catalog.benchmark.version,'--max-file-size-mib',[string]$MaxPdfSizeMiB,'--max-pages',[string]$MaxPdfPages,'--output',$extractionPath)) { $extractArgs.Add($argument) }
    foreach ($requiredText in @($catalog.sourceDocument.requiredText)) { $extractArgs.Add('--require-text'); $extractArgs.Add([string]$requiredText) }
    & $pythonExecutable @extractArgs
    if ($LASTEXITCODE -ne 0) { throw "PDF extraction failed with exit code $LASTEXITCODE." }

    $buildArgs = @{
        ExtractionPath=$extractionPath
        MappingCatalogPath=$catalogPath
        OutputPath=$packStaging
    }
    if ($AdministratorDecisionsPath) { $buildArgs.AdministratorDecisionsPath=(Resolve-Path -LiteralPath $AdministratorDecisionsPath).Path }
    if ($SettingsCatalogSnapshotPath) { $buildArgs.SettingsCatalogSnapshotPath=(Resolve-Path -LiteralPath $SettingsCatalogSnapshotPath).Path }
    & (Join-Path $PSScriptRoot 'Build-CISPolicyPack.ps1') @buildArgs

    if ($KeepPrivateExtraction) {
        [IO.File]::Move($extractionPath,$privatePath)
        $privatePublished=$true
    }
    # Staging and output share a parent, so this is an atomic rename that refuses a raced destination.
    [IO.Directory]::Move($packStaging,$outputRoot)
    $completed=$true
    if ($KeepPrivateExtraction) { Write-Warning "Private benchmark text retained outside the pack: $privatePath" }
    Write-Host "Reproducible pipeline complete: $outputRoot"
    Write-Host 'The generated pack contains no source PDF, raw benchmark prose, credentials, assignments, or AI-generated runtime artifacts.'
} finally {
    if (Test-Path -LiteralPath $stagingRoot) { Remove-Item -LiteralPath $stagingRoot -Recurse -Force }
    if (-not $completed -and $privatePublished -and (Test-Path -LiteralPath $privatePath)) { Remove-Item -LiteralPath $privatePath -Force }
}
