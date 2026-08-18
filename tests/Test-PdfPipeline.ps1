[CmdletBinding()]
param([string]$PythonPath='python')
$ErrorActionPreference='Stop'
$repoRoot=Split-Path -Parent $PSScriptRoot
$fixtures=Join-Path $PSScriptRoot 'fixtures'
$python=(Get-Command $PythonPath -ErrorAction Stop).Source
$tempBase=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
$pathComparison=if($IsWindows){[StringComparison]::OrdinalIgnoreCase}else{[StringComparison]::Ordinal}
$testRoot=Join-Path $tempBase ('CISPolicyCreator-pdf-test-'+[guid]::NewGuid().ToString('N'))
try{
    New-Item -ItemType Directory -Path $testRoot | Out-Null
    $pdf=Join-Path $testRoot 'synthetic.pdf'
    $pack=Join-Path $testRoot 'pack'
    $bundle=Join-Path $testRoot 'synthetic-policies.zip'
    $autoPack=Join-Path $testRoot 'pack-auto-runtime'
    & $python (Join-Path $PSScriptRoot 'Create-SyntheticBenchmarkPdf.py') $pdf
    if($LASTEXITCODE -ne 0){ throw 'Synthetic PDF creation failed.' }
    & (Join-Path $repoRoot 'scripts\Invoke-CISPolicyPipeline.ps1') `
        -PdfPath $pdf `
        -MappingCatalogPath (Join-Path $fixtures 'mapping-catalog.json') `
        -SettingsCatalogSnapshotPath (Join-Path $fixtures 'settings-catalog-snapshot.json') `
        -AdministratorDecisionsPath (Join-Path $fixtures 'administrator-decisions.json') `
        -OutputPath $pack `
        -PolicyJsonBundlePath $bundle `
        -PolicyJsonBundleName synthetic-policies `
        -PythonPath $python
    & (Join-Path $repoRoot 'scripts\Invoke-CISPolicyPipeline.ps1') `
        -PdfPath $pdf `
        -MappingCatalogPath (Join-Path $fixtures 'mapping-catalog.json') `
        -SettingsCatalogSnapshotPath (Join-Path $fixtures 'settings-catalog-snapshot.json') `
        -AdministratorDecisionsPath (Join-Path $fixtures 'administrator-decisions.json') `
        -OutputPath $autoPack
    $validation=& (Join-Path $repoRoot 'scripts\Test-CISPolicyPack.ps1') -PackRoot $pack -PassThru
    if(-not $validation.IsValid){ throw 'PDF-to-pack result failed validation.' }
    $bundleValidation=& (Join-Path $repoRoot 'scripts\Test-CISWindowsStylePolicyBundle.ps1') -BundlePath $bundle -PassThru
    if(-not $bundleValidation.IsValid){ throw 'One-command PDF-to-policy-JSON result failed validation.' }
    & (Join-Path $repoRoot 'scripts\Import-CISWindowsStylePolicyBundle.ps1') -BundlePath $bundle -ValidateOnly
    if(Test-Path -LiteralPath "$pack.private-extraction.json"){throw 'Policy JSON export retained private benchmark text without explicit authorization.'}
    $manifest=Get-Content -LiteralPath (Join-Path $pack 'manifest.json') -Raw | ConvertFrom-Json -Depth 100
    $actualHash=(Get-FileHash -LiteralPath $pdf -Algorithm SHA256).Hash.ToLowerInvariant()
    if([string]$manifest.source.sha256 -cne $actualHash){ throw 'Generated manifest does not contain the actual PDF hash.' }
    $explicitFiles=@(Get-ChildItem -LiteralPath $pack -Recurse -File | ForEach-Object { $_.FullName.Substring($pack.Length+1) } | Sort-Object)
    $autoFiles=@(Get-ChildItem -LiteralPath $autoPack -Recurse -File | ForEach-Object { $_.FullName.Substring($autoPack.Length+1) } | Sort-Object)
    if(($explicitFiles -join '|') -cne ($autoFiles -join '|')){throw 'Automatic runtime discovery produced a different pack file set.'}
    foreach($relativePath in $explicitFiles){
        $explicitHash=(Get-FileHash -LiteralPath (Join-Path $pack $relativePath) -Algorithm SHA256).Hash
        $autoHash=(Get-FileHash -LiteralPath (Join-Path $autoPack $relativePath) -Algorithm SHA256).Hash
        if($explicitHash -cne $autoHash){throw "Automatic runtime discovery produced different bytes: $relativePath"}
    }
    Write-Host 'PASS: real PDF extraction, pack compilation, and split-policy JSON orchestration.'
} finally {
    $resolved=[IO.Path]::GetFullPath($testRoot)
    if(-not $resolved.StartsWith($tempBase,$pathComparison)){ throw "Refusing unsafe cleanup path: $resolved" }
    if(Test-Path -LiteralPath $resolved){ Remove-Item -LiteralPath $resolved -Recurse -Force }
}
