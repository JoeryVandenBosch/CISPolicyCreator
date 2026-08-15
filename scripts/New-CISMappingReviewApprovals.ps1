[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$MappingCatalogPath,
    [Parameter(Mandatory)][string]$ReviewWorklistPath,
    [Parameter(Mandatory)][string]$CatalogVersion,
    [Parameter(Mandatory)][string]$PackVersion,
    [Parameter(Mandatory)][string]$OutputPath
)

$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$repoRoot=Split-Path -Parent $PSScriptRoot
$outputFull=[IO.Path]::GetFullPath($OutputPath)
if(-not $outputFull.EndsWith('.private-approvals.json',[StringComparison]::Ordinal)){throw 'OutputPath must end with the exact lowercase suffix .private-approvals.json.'}
if(Test-Path -LiteralPath $outputFull){throw "OutputPath already exists: $outputFull"}

function Read-ValidatedJson([string]$Path,[string]$SchemaName,[string]$Label) {
    $resolved=(Resolve-Path -LiteralPath $Path).Path
    $json=Get-Content -LiteralPath $resolved -Raw
    $schemaPath=Join-Path $repoRoot "schemas\$SchemaName"
    if(-not ($json|Test-Json -SchemaFile $schemaPath -ErrorAction Stop)){throw "$Label does not satisfy $SchemaName."}
    return [pscustomobject]@{Path=$resolved;Value=($json|ConvertFrom-Json -Depth 100)}
}

function Get-Sha256([string]$Path){return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}

function Test-ExactArray($Left,$Right) {
    $leftArray=@($Left);$rightArray=@($Right)
    if($leftArray.Count -ne $rightArray.Count){return $false}
    for($i=0;$i -lt $leftArray.Count;$i++){if([string]$leftArray[$i] -cne [string]$rightArray[$i]){return $false}}
    return $true
}

$catalogInput=Read-ValidatedJson $MappingCatalogPath 'mapping-catalog.schema.json' 'Mapping catalog'
$worklistInput=Read-ValidatedJson $ReviewWorklistPath 'private-mapping-review.schema.json' 'Private mapping review worklist'
$catalog=$catalogInput.Value
$worklist=$worklistInput.Value
if([bool]$worklist.mappingChangesMade){throw 'The review worklist must be candidate-only.'}
if([string]$worklist.benchmark.id -cne [string]$catalog.benchmark.id -or [string]$worklist.benchmark.version -cne [string]$catalog.benchmark.version){throw 'Review worklist and mapping catalog target different benchmarks.'}
if([string]$CatalogVersion -ceq [string]$catalog.version){throw 'CatalogVersion must differ from the input catalog version.'}
if([string]$PackVersion -ceq [string]$catalog.pack.version){throw 'PackVersion must differ from the input pack version.'}

$catalogByRecommendation=[System.Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
foreach($recommendation in @($catalog.recommendations)){
    $id=[string]$recommendation.recommendationId
    if($catalogByRecommendation.ContainsKey($id)){throw "Mapping catalog contains duplicate recommendation '$id'."}
    $catalogByRecommendation.Add($id,$recommendation)
}
if([int]$worklist.summary.recommendationCount -ne [int]$catalog.benchmark.expectedRecommendationCount){throw 'Review worklist and mapping catalog recommendation counts differ.'}

$reviews=[System.Collections.Generic.List[object]]::new()
foreach($recommendation in @($worklist.recommendations)){
    $recommendationId=[string]$recommendation.recommendationId
    if(-not $catalogByRecommendation.ContainsKey($recommendationId)){throw "Review worklist recommendation '$recommendationId' is absent from the mapping catalog."}
    $catalogRecommendation=$catalogByRecommendation[$recommendationId]
    if([string]$catalogRecommendation.cisAssessmentMethod -cne [string]$recommendation.cisAssessmentMethod -or -not (Test-ExactArray $catalogRecommendation.profiles $recommendation.profiles)){throw "Review worklist recommendation '$recommendationId' contradicts mapping catalog metadata."}
    if([string]$catalogRecommendation.mappingStatus -cne 'unresolved'){continue}
    $candidateStatus=[string]$recommendation.candidateStatus
    if($candidateStatus -eq 'none'){continue}
    $reviews.Add([pscustomobject][ordered]@{
        recommendationId=$recommendationId
        candidateStatus=$candidateStatus
        outcome='defer'
        acknowledged=$false
        valueBasis=$null
        reviewedBy=$null
        justification=$null
        publicNotes=$null
        selections=@()
    })|Out-Null
}

$payload=[pscustomobject][ordered]@{
    schemaVersion='1.0'
    catalog=[pscustomobject][ordered]@{
        id=[string]$catalog.id
        version=[string]$catalog.version
        sha256=(Get-Sha256 $catalogInput.Path)
    }
    reviewWorklist=[pscustomobject][ordered]@{
        sha256=(Get-Sha256 $worklistInput.Path)
        settingsCatalogSnapshotSha256=[string]$worklist.source.settingsCatalogSnapshotSha256
    }
    output=[pscustomobject][ordered]@{
        catalogVersion=$CatalogVersion
        packVersion=$PackVersion
    }
    reviews=@($reviews)
}

$json=(ConvertTo-Json -InputObject $payload -Depth 100)-replace "`r`n","`n"
$json+="`n"
$schemaPath=Join-Path $repoRoot 'schemas\mapping-review-approvals.schema.json'
if(-not ($json|Test-Json -SchemaFile $schemaPath -ErrorAction Stop)){throw 'Generated private approval template failed schema validation.'}
$parent=Split-Path -Parent $outputFull
if(-not (Test-Path -LiteralPath $parent)){New-Item -ItemType Directory -Path $parent|Out-Null}
[IO.File]::WriteAllText($outputFull,$json,[Text.UTF8Encoding]::new($false))

Write-Host "Generated private mapping approval template: $outputFull"
Write-Host "Candidate recommendations: $($reviews.Count); approved mappings: 0"
Write-Warning 'Every review defaults to defer. The file contains private reviewer evidence and must not be committed.'
