[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$OutputPath,
    [Parameter(Mandatory)][string]$PackId,
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string]$Version,
    [ValidateSet('windows10','macOS','iOS')][string]$Platform='windows10',
    [string]$Technologies='mdm'
)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath($OutputPath)
if (Test-Path -LiteralPath $root) { throw "OutputPath already exists: $root" }
New-Item -ItemType Directory -Path (Join-Path $root 'policies\settings-catalog') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $root 'spec') -Force | Out-Null
$manifest=[ordered]@{
    schemaVersion='1.1'; id=$PackId; name=$Name; version=$Version
    benchmarkScope='microsoft-intune'; sourceDocumentIncluded=$false
    defaultPlatform=$Platform; defaultTechnologies=$Technologies
    recommendationsSpec='spec/recommendations.json'
    settingsCatalogPolicyDirectory='policies/settings-catalog'
    settingsCatalogSpec='spec/settings-catalog.json'
    graphObjects='spec/graph-objects.json'
    settingsCatalogProbe=$null
}
$manifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $root 'manifest.json') -Encoding utf8
'[]' | Set-Content -LiteralPath (Join-Path $root 'spec\recommendations.json') -Encoding utf8
'[]' | Set-Content -LiteralPath (Join-Path $root 'spec\settings-catalog.json') -Encoding utf8
'[]' | Set-Content -LiteralPath (Join-Path $root 'spec\graph-objects.json') -Encoding utf8
Write-Host "Created Microsoft-Intune-only policy-pack scaffold: $root"
Write-Host 'Note: extracted recommendations should start as unresolved; no deployable policy is generated automatically.'
