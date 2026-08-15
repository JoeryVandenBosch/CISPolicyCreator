[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PackRoot,
    [string]$CsvPath,
    [string]$JsonPath,
    [switch]$PassThru
)

$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$PackRoot=(Resolve-Path -LiteralPath $PackRoot).Path

function Resolve-NewOutputPath([AllowNull()][string]$Path,[string]$Extension,[string]$Label) {
    if(-not $Path){return $null}
    $full=[IO.Path]::GetFullPath($Path)
    if(-not $full.EndsWith($Extension,[StringComparison]::OrdinalIgnoreCase)){throw "$Label must end with $Extension."}
    if(Test-Path -LiteralPath $full){throw "$Label already exists: $full"}
    return $full
}

function Get-OptionalString($Object,[string]$Name) {
    $property=$Object.PSObject.Properties[$Name]
    if(-not $property -or $null -eq $property.Value){return ''}
    return [string]$property.Value
}

$validation=& (Join-Path $PSScriptRoot 'Test-CISPolicyPack.ps1') -PackRoot $PackRoot -PassThru
if(-not $validation.IsValid){
    $details=(@($validation.Issues) | ForEach-Object { " - $_" }) -join [Environment]::NewLine
    throw "Mapping reports require a valid fail-closed policy pack. No report was written.`n$details"
}

$csvOutput=Resolve-NewOutputPath $CsvPath '.csv' 'CsvPath'
$jsonOutput=Resolve-NewOutputPath $JsonPath '.json' 'JsonPath'
if($csvOutput -and $jsonOutput -and $csvOutput.Equals($jsonOutput,[StringComparison]::OrdinalIgnoreCase)){throw 'CsvPath and JsonPath must be different files.'}

$manifest=Get-Content -LiteralPath (Join-Path $PackRoot 'manifest.json') -Raw | ConvertFrom-Json -Depth 100
$recPath=Join-Path $PackRoot ([string]$manifest.recommendationsSpec)
$recs=@(Get-Content -LiteralPath $recPath -Raw | ConvertFrom-Json -Depth 100)
$rows=@($recs | ForEach-Object {
    [pscustomobject][ordered]@{
        RecommendationId=[string]$_.recommendationId
        Profiles=(@($_.profiles) -join ',')
        CisAssessmentMethod=[string]$_.cisAssessmentMethod
        MappingStatus=[string]$_.mappingStatus
        CatalogMappingStatus=(Get-OptionalString $_ 'catalogMappingStatus')
        DecisionRef=(Get-OptionalString $_ 'decisionRef')
        ImplementationType=(Get-OptionalString $_ 'implementationType')
        ImplementationRefs=if($_.PSObject.Properties['implementationRefs']){@($_.implementationRefs) -join ';'}else{''}
        Notes=(Get-OptionalString $_ 'notes')
    }
})

$summary=[pscustomobject][ordered]@{
    RecommendationCount=$rows.Count
    Automated=@($rows | Where-Object CisAssessmentMethod -eq 'Automated').Count
    ManualAssessment=@($rows | Where-Object CisAssessmentMethod -eq 'Manual').Count
    Mapped=@($rows | Where-Object MappingStatus -eq 'mapped').Count
    Unresolved=@($rows | Where-Object MappingStatus -eq 'unresolved').Count
    RequiresInput=@($rows | Where-Object MappingStatus -eq 'requires-input').Count
    ManualMapping=@($rows | Where-Object MappingStatus -eq 'manual').Count
    NotApplicable=@($rows | Where-Object MappingStatus -eq 'not-applicable').Count
    CatalogComplete=(@($rows | Where-Object { $_.MappingStatus -in @('unresolved','requires-input') }).Count -eq 0)
}

$rows | Sort-Object MappingStatus,RecommendationId | Format-Table -AutoSize | Out-Host
$summary | Format-List | Out-Host

foreach($output in @($csvOutput,$jsonOutput) | Where-Object { $_ }){
    $parent=Split-Path -Parent $output
    if(-not $parent){$parent=(Get-Location).Path}
    if(-not (Test-Path -LiteralPath $parent)){New-Item -ItemType Directory -Path $parent | Out-Null}
}
if($csvOutput){
    $csv=(@($rows | ConvertTo-Csv -NoTypeInformation) -join "`n")+"`n"
    [IO.File]::WriteAllText($csvOutput,$csv,[Text.UTF8Encoding]::new($false))
    Write-Host "CSV: $csvOutput"
}
if($jsonOutput){
    $json=(ConvertTo-Json -InputObject @($rows) -Depth 20)-replace "`r`n","`n"
    [IO.File]::WriteAllText($jsonOutput,$json+"`n",[Text.UTF8Encoding]::new($false))
    Write-Host "JSON: $jsonOutput"
}

if($PassThru){return [pscustomobject]@{Rows=@($rows);Summary=$summary;Validation=$validation}}
