[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ExtractionPath,
    [Parameter(Mandatory)][string]$OutputPath,
    [Parameter(Mandatory)][string]$CatalogId,
    [Parameter(Mandatory)][string]$CatalogVersion,
    [Parameter(Mandatory)][string]$PackId,
    [Parameter(Mandatory)][string]$PackName,
    [Parameter(Mandatory)][string]$PackVersion
)

$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$repoRoot=Split-Path -Parent $PSScriptRoot
$extractionSchema=Join-Path $repoRoot 'schemas\extraction.schema.json'
$catalogSchema=Join-Path $repoRoot 'schemas\mapping-catalog.schema.json'
$resolvedExtraction=(Resolve-Path -LiteralPath $ExtractionPath).Path
$extractionJson=Get-Content -LiteralPath $resolvedExtraction -Raw
if (-not ($extractionJson | Test-Json -SchemaFile $extractionSchema -ErrorAction Stop)) { throw 'Extraction failed schema validation.' }
$extraction=$extractionJson | ConvertFrom-Json -Depth 100
$output=[IO.Path]::GetFullPath($OutputPath)
if (Test-Path -LiteralPath $output) { throw "OutputPath already exists: $output" }

$seen=[System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$recommendations=@($extraction.recommendations | ForEach-Object {
    $id=[string]$_.recommendationId
    if (-not $seen.Add($id)) { throw "Duplicate extracted recommendation '$id'." }
    [ordered]@{
        recommendationId=$id
        profiles=@($_.profiles)
        cisAssessmentMethod=[string]$_.cisAssessmentMethod
        mappingStatus='unresolved'
        implementationType=$null
        implementationRefs=@()
        decisionRef=$null
        notes=$null
    }
})

$payload=[ordered]@{
    schemaVersion='1.0'
    id=$CatalogId
    version=$CatalogVersion
    benchmark=[ordered]@{
        id=[string]$extraction.benchmark.id
        version=[string]$extraction.benchmark.version
        expectedRecommendationCount=$recommendations.Count
    }
    pack=[ordered]@{ id=$PackId; name=$PackName; version=$PackVersion }
    sourceDocument=[ordered]@{ requiredText=@($extraction.benchmark.requiredTextMatched) }
    recommendations=$recommendations
    administratorInputs=@()
    settingsCatalogPolicies=@()
    settingsCatalogSettings=@()
    graphObjects=@()
}

$parent=Split-Path -Parent $output
if (-not $parent) { $parent=(Get-Location).Path }
[IO.Directory]::CreateDirectory($parent) | Out-Null
$temporary=Join-Path $parent ('.'+[IO.Path]::GetFileName($output)+'.'+[guid]::NewGuid().ToString('N')+'.tmp')
try {
    $rendered=($payload | ConvertTo-Json -Depth 100).Replace("`r`n","`n")+"`n"
    [IO.File]::WriteAllText($temporary,$rendered,[Text.UTF8Encoding]::new($false))
    $rendered=Get-Content -LiteralPath $temporary -Raw
    if (-not ($rendered | Test-Json -SchemaFile $catalogSchema -ErrorAction Stop)) { throw 'Generated mapping catalog failed schema validation.' }
    Move-Item -LiteralPath $temporary -Destination $output
} finally {
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
}

Write-Host "Wrote fail-closed mapping catalog seed with $($recommendations.Count) unresolved recommendations: $output"
Write-Host 'Review every recommendation and add only evidence-backed Intune mappings; never infer Graph identifiers or values.'
