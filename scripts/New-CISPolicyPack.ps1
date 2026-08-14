[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$OutputPath,
    [Parameter(Mandatory)][string]$PackId,
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string]$Version,
    [Parameter(Mandatory)][string]$SourceFileName,
    [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$SourceSha256,
    [Parameter(Mandatory)][ValidateRange(1,[int]::MaxValue)][int]$SourcePageCount,
    [Parameter(Mandatory)][string]$MappingCatalogId,
    [Parameter(Mandatory)][string]$MappingCatalogVersion,
    [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$MappingCatalogSha256
)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath($OutputPath)
if (Test-Path -LiteralPath $root) { throw "OutputPath already exists: $root" }
New-Item -ItemType Directory -Path (Join-Path $root 'policies\settings-catalog') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $root 'spec') -Force | Out-Null
$manifest=[ordered]@{
    schemaVersion='2.0'; id=$PackId; name=$Name; version=$Version
    benchmarkScope='microsoft-intune'; sourceDocumentIncluded=$false
    source=[ordered]@{ fileName=$SourceFileName; sha256=$SourceSha256.ToLowerInvariant(); pageCount=$SourcePageCount }
    build=[ordered]@{ toolVersion='0.2.0'; extractorVersion='0.2.0'; pdfParser='pypdf'; pdfParserVersion='6.15.0'; mappingCatalogId=$MappingCatalogId; mappingCatalogVersion=$MappingCatalogVersion; mappingCatalogSha256=$MappingCatalogSha256.ToLowerInvariant(); administratorDecisionsSha256=$null; settingsCatalogSnapshotSha256=$null }
    recommendationsSpec='spec/recommendations.json'
    settingsCatalogPolicyDirectory='policies/settings-catalog'
    settingsCatalogSpec='spec/settings-catalog.json'
    graphObjects='spec/graph-objects.json'
    settingsCatalogProbe=$null
}
$manifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $root 'manifest.json') -Encoding utf8
$placeholder=@([ordered]@{ recommendationId='replace-me'; profiles=@('L1'); cisAssessmentMethod='Automated'; mappingStatus='unresolved'; implementationType=$null; implementationRefs=@(); notes='Scaffold placeholder; replace through the reproducible pipeline.' })
ConvertTo-Json -InputObject $placeholder -Depth 20 | Set-Content -LiteralPath (Join-Path $root 'spec\recommendations.json') -Encoding utf8
'[]' | Set-Content -LiteralPath (Join-Path $root 'spec\settings-catalog.json') -Encoding utf8
'[]' | Set-Content -LiteralPath (Join-Path $root 'spec\graph-objects.json') -Encoding utf8
Write-Host "Created provenance-pinned policy-pack scaffold: $root"
Write-Warning 'Prefer Invoke-CISPolicyPipeline.ps1 for reproducible generation from a benchmark PDF.'
