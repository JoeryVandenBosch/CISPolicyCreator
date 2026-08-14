[CmdletBinding()]
param([string]$PythonPath='python')
$ErrorActionPreference='Stop'
$repoRoot=Split-Path -Parent $PSScriptRoot
$fixtures=Join-Path $PSScriptRoot 'fixtures'
$python=(Get-Command $PythonPath -ErrorAction Stop).Source
$tempBase=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
$testRoot=Join-Path $tempBase ('CISPolicyCreator-pdf-test-'+[guid]::NewGuid().ToString('N'))
try{
    New-Item -ItemType Directory -Path $testRoot | Out-Null
    $pdf=Join-Path $testRoot 'synthetic.pdf'
    $pack=Join-Path $testRoot 'pack'
    & $python (Join-Path $PSScriptRoot 'Create-SyntheticBenchmarkPdf.py') $pdf
    if($LASTEXITCODE -ne 0){ throw 'Synthetic PDF creation failed.' }
    & (Join-Path $repoRoot 'scripts\Invoke-CISPolicyPipeline.ps1') `
        -PdfPath $pdf `
        -MappingCatalogPath (Join-Path $fixtures 'mapping-catalog.json') `
        -SettingsCatalogSnapshotPath (Join-Path $fixtures 'settings-catalog-snapshot.json') `
        -AdministratorDecisionsPath (Join-Path $fixtures 'administrator-decisions.json') `
        -OutputPath $pack `
        -PythonPath $python
    $validation=& (Join-Path $repoRoot 'scripts\Test-CISPolicyPack.ps1') -PackRoot $pack -PassThru
    if(-not $validation.IsValid){ throw 'PDF-to-pack result failed validation.' }
    $manifest=Get-Content -LiteralPath (Join-Path $pack 'manifest.json') -Raw | ConvertFrom-Json -Depth 100
    $actualHash=(Get-FileHash -LiteralPath $pdf -Algorithm SHA256).Hash.ToLowerInvariant()
    if([string]$manifest.source.sha256 -cne $actualHash){ throw 'Generated manifest does not contain the actual PDF hash.' }
    Write-Host 'PASS: real PDF extraction and top-level pipeline orchestration.'
} finally {
    $resolved=[IO.Path]::GetFullPath($testRoot)
    if(-not $resolved.StartsWith($tempBase,[StringComparison]::OrdinalIgnoreCase)){ throw "Refusing unsafe cleanup path: $resolved" }
    if(Test-Path -LiteralPath $resolved){ Remove-Item -LiteralPath $resolved -Recurse -Force }
}
