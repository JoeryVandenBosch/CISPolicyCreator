[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PackRoot,
    [string]$CsvPath,
    [string]$JsonPath
)
$ErrorActionPreference='Stop'
$PackRoot=(Resolve-Path -LiteralPath $PackRoot).Path
$manifest=Get-Content -LiteralPath (Join-Path $PackRoot 'manifest.json') -Raw | ConvertFrom-Json -Depth 100
$recPath=Join-Path $PackRoot ([string]$manifest.recommendationsSpec)
$recs=@(Get-Content -LiteralPath $recPath -Raw | ConvertFrom-Json -Depth 100)
$rows=@($recs | ForEach-Object {
    [pscustomobject]@{
        RecommendationId=[string]$_.recommendationId
        Profiles=(@($_.profiles) -join ',')
        CisAssessmentMethod=[string]$_.cisAssessmentMethod
        MappingStatus=[string]$_.mappingStatus
        CatalogMappingStatus=[string]$_.catalogMappingStatus
        DecisionRef=[string]$_.decisionRef
        ImplementationType=[string]$_.implementationType
        ImplementationRefs=(@($_.implementationRefs) -join ';')
        Notes=[string]$_.notes
    }
})
$rows | Sort-Object MappingStatus,RecommendationId | Format-Table -AutoSize
Write-Host ''
$rows | Group-Object MappingStatus | Sort-Object Name | ForEach-Object { Write-Host ("{0,-14} {1,5}" -f $_.Name,$_.Count) }
if ($CsvPath) { $rows | Export-Csv -LiteralPath $CsvPath -NoTypeInformation -Encoding utf8; Write-Host "CSV: $CsvPath" }
if ($JsonPath) { $rows | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $JsonPath -Encoding utf8; Write-Host "JSON: $JsonPath" }
