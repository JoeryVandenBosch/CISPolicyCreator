[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$MappingCatalogPath,
    [Parameter(Mandatory)][string]$ReviewWorklistPath,
    [Parameter(Mandatory)][string]$ApprovalsPath,
    [string]$JsonPath,
    [string]$CsvPath,
    [switch]$ShowRows
)

$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$repoRoot=Split-Path -Parent $PSScriptRoot

function Read-ValidatedJson([string]$Path,[string]$SchemaName,[string]$Label) {
    $resolved=(Resolve-Path -LiteralPath $Path).Path
    $json=Get-Content -LiteralPath $resolved -Raw
    $schemaPath=Join-Path $repoRoot "schemas\$SchemaName"
    if(-not ($json | Test-Json -SchemaFile $schemaPath -ErrorAction Stop)){throw "$Label does not satisfy $SchemaName."}
    return [pscustomobject]@{Path=$resolved;Value=($json | ConvertFrom-Json -Depth 100)}
}

function Get-Sha256([string]$Path){return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}

function Test-ExactArray($Left,$Right) {
    $leftArray=@($Left);$rightArray=@($Right)
    if($leftArray.Count -ne $rightArray.Count){return $false}
    for($index=0;$index -lt $leftArray.Count;$index++){if([string]$leftArray[$index] -cne [string]$rightArray[$index]){return $false}}
    return $true
}

function Resolve-NewOutputPath([AllowNull()][string]$Path,[string]$Suffix,[string]$Label) {
    if(-not $Path){return $null}
    $full=[IO.Path]::GetFullPath($Path)
    if(-not $full.EndsWith($Suffix,[StringComparison]::OrdinalIgnoreCase)){throw "$Label must end with $Suffix."}
    if(Test-Path -LiteralPath $full){throw "$Label already exists: $full"}
    $parent=Split-Path -Parent $full
    if(-not $parent){$parent=(Get-Location).Path}
    if(-not (Test-Path -LiteralPath $parent)){New-Item -ItemType Directory -Path $parent | Out-Null}
    return $full
}

$catalogInput=Read-ValidatedJson $MappingCatalogPath 'mapping-catalog.schema.json' 'Mapping catalog'
$worklistInput=Read-ValidatedJson $ReviewWorklistPath 'private-mapping-review.schema.json' 'Private mapping review worklist'
$approvalsInput=Read-ValidatedJson $ApprovalsPath 'mapping-review-approvals.schema.json' 'Private mapping review approvals'
$catalog=$catalogInput.Value
$worklist=$worklistInput.Value
$approvals=$approvalsInput.Value

if([bool]$worklist.mappingChangesMade){throw 'The review worklist must be candidate-only.'}
if([string]$worklist.benchmark.id -cne [string]$catalog.benchmark.id -or [string]$worklist.benchmark.version -cne [string]$catalog.benchmark.version){throw 'Review worklist and mapping catalog target different benchmarks.'}
if((Get-Sha256 $catalogInput.Path) -cne [string]$approvals.catalog.sha256){throw 'Approval catalog hash does not match MappingCatalogPath.'}
if([string]$catalog.id -cne [string]$approvals.catalog.id -or [string]$catalog.version -cne [string]$approvals.catalog.version){throw 'Approvals target a different mapping catalog identity or version.'}
if((Get-Sha256 $worklistInput.Path) -cne [string]$approvals.reviewWorklist.sha256){throw 'Approval worklist hash does not match ReviewWorklistPath.'}
if([string]$worklist.source.settingsCatalogSnapshotSha256 -cne [string]$approvals.reviewWorklist.settingsCatalogSnapshotSha256){throw 'Approval snapshot hash does not match the review worklist.'}
if([int]$worklist.summary.recommendationCount -ne [int]$catalog.benchmark.expectedRecommendationCount){throw 'Review worklist and mapping catalog recommendation counts differ.'}

$catalogById=[System.Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
foreach($recommendation in @($catalog.recommendations)){
    $id=[string]$recommendation.recommendationId
    if($catalogById.ContainsKey($id)){throw "Mapping catalog contains duplicate recommendation '$id'."}
    $catalogById.Add($id,$recommendation)
}
$worklistById=[System.Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
foreach($recommendation in @($worklist.recommendations)){
    $id=[string]$recommendation.recommendationId
    if($worklistById.ContainsKey($id)){throw "Review worklist contains duplicate recommendation '$id'."}
    if(-not $catalogById.ContainsKey($id)){throw "Review worklist recommendation '$id' is absent from the mapping catalog."}
    $catalogRecommendation=$catalogById[$id]
    if([string]$catalogRecommendation.cisAssessmentMethod -cne [string]$recommendation.cisAssessmentMethod -or -not (Test-ExactArray $catalogRecommendation.profiles $recommendation.profiles)){throw "Review worklist recommendation '$id' contradicts catalog metadata."}
    $worklistById.Add($id,$recommendation)
}
if($worklistById.Count -ne $catalogById.Count){throw 'Review worklist does not cover every catalog recommendation.'}

$reviewById=[System.Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
foreach($review in @($approvals.reviews)){
    $id=[string]$review.recommendationId
    if($reviewById.ContainsKey($id)){throw "Approvals contain duplicate review '$id'."}
    if(-not $worklistById.ContainsKey($id)){throw "Approval review '$id' is absent from the worklist."}
    $worklistRecommendation=$worklistById[$id]
    if([string]$catalogById[$id].mappingStatus -cne 'unresolved'){throw "Approval review '$id' does not target an unresolved recommendation."}
    if([string]$worklistRecommendation.candidateStatus -ceq 'none' -or [string]$review.candidateStatus -cne [string]$worklistRecommendation.candidateStatus){throw "Approval review '$id' has missing or stale candidate evidence."}
    $reviewById.Add($id,$review)
}

$rows=[System.Collections.Generic.List[object]]::new()
foreach($worklistRecommendation in @($worklist.recommendations)){
    $id=[string]$worklistRecommendation.recommendationId
    $catalogRecommendation=$catalogById[$id]
    $review=if($reviewById.ContainsKey($id)){$reviewById[$id]}else{$null}
    $candidateCount=@($worklistRecommendation.candidates).Count
    $occurrenceCount=0
    foreach($candidate in @($worklistRecommendation.candidates)){$occurrenceCount+=@($candidate.occurrences).Count}
    $outcome=if($review){[string]$review.outcome}else{$null}
    $state=if([string]$catalogRecommendation.mappingStatus -cne 'unresolved'){
        'catalog-resolved'
    }elseif([string]$worklistRecommendation.candidateStatus -ceq 'none'){
        'no-candidate'
    }elseif($outcome -ceq 'mapped'){
        'candidate-approved'
    }elseif($outcome -ceq 'rejected'){
        'candidate-rejected'
    }else{
        'pending-review'
    }
    $rows.Add([pscustomobject][ordered]@{
        recommendationId=$id
        profiles=@($catalogRecommendation.profiles)
        cisAssessmentMethod=[string]$catalogRecommendation.cisAssessmentMethod
        catalogMappingStatus=[string]$catalogRecommendation.mappingStatus
        candidateStatus=[string]$worklistRecommendation.candidateStatus
        candidateCount=$candidateCount
        occurrenceCount=$occurrenceCount
        reviewOutcome=$outcome
        acknowledged=if($review){[bool]$review.acknowledged}else{$false}
        selectionCount=if($review){@($review.selections).Count}else{0}
        state=$state
    }) | Out-Null
}

$deferredReviews=@($approvals.reviews | Where-Object outcome -eq 'defer').Count
$rejectedReviews=@($approvals.reviews | Where-Object outcome -eq 'rejected').Count
$mappedReviews=@($approvals.reviews | Where-Object outcome -eq 'mapped').Count
$pendingReviewRows=@($rows | Where-Object state -eq 'pending-review').Count
$summary=[pscustomobject][ordered]@{
    recommendationCount=$rows.Count
    catalogMapped=@($rows | Where-Object catalogMappingStatus -eq 'mapped').Count
    catalogUnresolved=@($rows | Where-Object catalogMappingStatus -eq 'unresolved').Count
    catalogRequiresInput=@($rows | Where-Object catalogMappingStatus -eq 'requires-input').Count
    catalogManual=@($rows | Where-Object catalogMappingStatus -eq 'manual').Count
    catalogNotApplicable=@($rows | Where-Object catalogMappingStatus -eq 'not-applicable').Count
    uniqueCandidates=@($rows | Where-Object candidateStatus -eq 'unique-candidate').Count
    ambiguousCandidates=@($rows | Where-Object candidateStatus -eq 'ambiguous-candidates').Count
    noCandidates=@($rows | Where-Object candidateStatus -eq 'none').Count
    reviewRows=@($approvals.reviews).Count
    deferredReviews=$deferredReviews
    rejectedReviews=$rejectedReviews
    mappedReviews=$mappedReviews
    reviewedRows=($rejectedReviews+$mappedReviews)
    pendingReviewRows=$pendingReviewRows
    selectionCount=@($approvals.reviews | ForEach-Object {@($_.selections)}).Count
    reviewQueueComplete=($pendingReviewRows -eq 0)
    catalogComplete=(@($rows | Where-Object { $_.catalogMappingStatus -in @('unresolved','requires-input') }).Count -eq 0)
    readyForCatalogPromotion=($mappedReviews -gt 0)
}
$report=[pscustomobject][ordered]@{
    schemaVersion='1.0'
    tool=[pscustomobject][ordered]@{name='Get-CISMappingReviewReport.ps1';version='0.1.0'}
    mappingChangesMade=$false
    benchmark=[pscustomobject][ordered]@{id=[string]$catalog.benchmark.id;version=[string]$catalog.benchmark.version}
    source=[pscustomobject][ordered]@{
        catalogSha256=(Get-Sha256 $catalogInput.Path)
        reviewWorklistSha256=(Get-Sha256 $worklistInput.Path)
        approvalsSha256=(Get-Sha256 $approvalsInput.Path)
        settingsCatalogSnapshotSha256=[string]$worklist.source.settingsCatalogSnapshotSha256
    }
    summary=$summary
    recommendations=@($rows)
}

$json=(ConvertTo-Json -InputObject $report -Depth 100)-replace "`r`n","`n"
$json+="`n"
$reportSchema=Join-Path $repoRoot 'schemas\private-mapping-review-report.schema.json'
if(-not ($json | Test-Json -SchemaFile $reportSchema -ErrorAction Stop)){throw 'Generated private mapping review report failed schema validation.'}

$jsonOutput=Resolve-NewOutputPath $JsonPath '.private-review-report.json' 'JsonPath'
$csvOutput=Resolve-NewOutputPath $CsvPath '.private-review-report.csv' 'CsvPath'
if($jsonOutput){[IO.File]::WriteAllText($jsonOutput,$json,[Text.UTF8Encoding]::new($false))}
if($csvOutput){
    $csvRows=@($rows | ForEach-Object {[pscustomobject][ordered]@{
        RecommendationId=$_.recommendationId
        Profiles=(@($_.profiles) -join ',')
        CisAssessmentMethod=$_.cisAssessmentMethod
        CatalogMappingStatus=$_.catalogMappingStatus
        CandidateStatus=$_.candidateStatus
        CandidateCount=$_.candidateCount
        OccurrenceCount=$_.occurrenceCount
        ReviewOutcome=$_.reviewOutcome
        Acknowledged=$_.acknowledged
        SelectionCount=$_.selectionCount
        State=$_.state
    }})
    $csv=(@($csvRows | ConvertTo-Csv -NoTypeInformation) -join "`n")+"`n"
    [IO.File]::WriteAllText($csvOutput,$csv,[Text.UTF8Encoding]::new($false))
}

if($ShowRows){$rows | Format-Table recommendationId,cisAssessmentMethod,catalogMappingStatus,candidateStatus,reviewOutcome,state -AutoSize}
$summary | Format-List
if($jsonOutput){Write-Host "Private JSON report: $jsonOutput"}
if($csvOutput){Write-Host "Private CSV report: $csvOutput"}
Write-Warning 'Report outputs are hash-bound private review artifacts. They change no mapping or approval state and must not be committed.'
