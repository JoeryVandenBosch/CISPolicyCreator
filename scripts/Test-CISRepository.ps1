[CmdletBinding()]
param(
    [string]$PythonPath,
    [switch]$RequireGraph
)

$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$repoRoot=Split-Path -Parent $PSScriptRoot

Push-Location $repoRoot
try {
    $tracked=@(& git -C $repoRoot ls-files)
    if($LASTEXITCODE -ne 0){throw 'Could not enumerate tracked repository files with git.'}

    $privatePattern='(?i)(\.pdf$|\.zip$|\.7z$|\.xlsx$|(^|/)recommendations\.raw\.json$|\.private-extraction\.json$|\.private-review\.json$|\.private-approvals\.json$|\.private-review-report\.(json|csv)$)'
    $trackedPrivate=@($tracked | Where-Object { $_ -match $privatePattern })
    if($trackedPrivate.Count -gt 0){throw "Tracked source/private benchmark artifacts are forbidden: $($trackedPrivate -join ', ')"}
    Write-Host 'PASS: no source/private benchmark artifacts are tracked.'

    foreach($relativePath in @($tracked | Where-Object { $_.EndsWith('.json',[StringComparison]::OrdinalIgnoreCase) })){
        $path=Join-Path $repoRoot $relativePath
        Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -Depth 100 | Out-Null
    }
    Write-Host 'PASS: tracked JSON syntax.'

    $graphContractSchema=Join-Path $repoRoot 'schemas/graph-object-contract.schema.json'
    $graphContracts=@{}
    $contractRoot=Join-Path $repoRoot 'contracts/graph'
    foreach($path in @(Get-ChildItem -LiteralPath $contractRoot -Filter '*.json' -File | Select-Object -ExpandProperty FullName)){
        $relativePath=[IO.Path]::GetRelativePath($repoRoot,$path)
        $json=Get-Content -LiteralPath $path -Raw
        if(-not ($json | Test-Json -SchemaFile $graphContractSchema -ErrorAction Stop)){throw "Published Graph contract failed schema validation: $relativePath"}
        $contract=$json | ConvertFrom-Json -Depth 100
        $contractId=[string]$contract.id
        if($graphContracts.ContainsKey($contractId)){throw "Duplicate published Graph contract ID: $contractId"}
        $graphContracts[$contractId]=$contract
    }
    Write-Host 'PASS: pinned Graph object contracts.'

    $catalogSchema=Join-Path $repoRoot 'schemas/mapping-catalog.schema.json'
    foreach($relativePath in @($tracked | Where-Object { $_ -match '^benchmarks/.+/mapping-catalog\.json$' })){
        $path=Join-Path $repoRoot $relativePath
        $json=Get-Content -LiteralPath $path -Raw
        if(-not ($json | Test-Json -SchemaFile $catalogSchema -ErrorAction Stop)){throw "Published mapping catalog failed schema validation: $relativePath"}
        $catalog=$json | ConvertFrom-Json -Depth 100
        $ids=@($catalog.recommendations.recommendationId)
        if($ids.Count -ne [int]$catalog.benchmark.expectedRecommendationCount){throw "Published mapping catalog count mismatch: $relativePath"}
        if(@($ids | Sort-Object -Unique).Count -ne $ids.Count){throw "Published mapping catalog contains duplicate recommendation IDs: $relativePath"}
        foreach($graphObject in @($catalog.graphObjects)){
            $contractId=[string]$graphObject.contractId
            if(-not $graphContracts.ContainsKey($contractId)){throw "Published mapping catalog references missing Graph contract '$contractId': $relativePath"}
            $contract=$graphContracts[$contractId]
            if([string]$graphObject.endpoint -cne [string]$contract.endpoint){throw "Published mapping catalog Graph endpoint differs from contract '$contractId': $relativePath"}
            $listEndpoint=if($graphObject.listEndpoint){[string]$graphObject.listEndpoint}else{[string]$graphObject.endpoint}
            if($listEndpoint -cne [string]$contract.listEndpoint){throw "Published mapping catalog Graph list endpoint differs from contract '$contractId': $relativePath"}
        }
    }
    Write-Host 'PASS: published mapping catalogs.'

    $powerShellPaths=[System.Collections.Generic.List[string]]::new()
    foreach($relativePath in @($tracked | Where-Object { $_ -match '(?i)\.(ps1|psm1)$' })){$powerShellPaths.Add((Join-Path $repoRoot $relativePath))}
    if(-not $powerShellPaths.Contains($PSCommandPath)){$powerShellPaths.Add($PSCommandPath)}
    foreach($path in $powerShellPaths){
        $tokens=$null
        $errors=$null
        [System.Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors) | Out-Null
        if($errors.Count -gt 0){
            $details=@($errors | ForEach-Object { "$($_.Extent.File):$($_.Extent.StartLineNumber): $($_.Message)" }) -join [Environment]::NewLine
            throw "PowerShell parser errors:`n$details"
        }
    }
    Write-Host 'PASS: PowerShell parser checks.'

    & (Join-Path $repoRoot 'scripts/Test-CISPolicyPack.ps1') -PackRoot (Join-Path $repoRoot 'templates/baseline')
    & (Join-Path $repoRoot 'tests/Test-OfflinePipeline.ps1')

    $prerequisiteArgs=@{PythonPath=$PythonPath;PassThru=$true}
    if($RequireGraph){$prerequisiteArgs.RequireGraph=$true}
    $prerequisites=& (Join-Path $repoRoot 'scripts/Test-CISPrerequisites.ps1') @prerequisiteArgs
    $python=[string]$prerequisites.PythonPath
    $pythonVersion=[string]$prerequisites.PythonVersion
    & $python -m unittest discover -s tests -p 'test_*.py'
    if($LASTEXITCODE -ne 0){throw "Python extraction tests failed with exit code $LASTEXITCODE."}
    & (Join-Path $repoRoot 'tests/Test-PdfPipeline.ps1') -PythonPath $python

    Write-Host "PASS: complete repository validation with Python $pythonVersion."
} finally {
    Pop-Location
}
