$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$repoRoot=Split-Path -Parent $PSScriptRoot
$fixtures=Join-Path $PSScriptRoot 'fixtures'
$tempBase=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
$testRoot=Join-Path $tempBase ('CISPolicyCreator-tests-'+[guid]::NewGuid().ToString('N'))

function Assert-True([bool]$Condition,[string]$Message) { if (-not $Condition) { throw "ASSERTION FAILED: $Message" } }
function Read-Json([string]$Path) { Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -Depth 100 }

try {
    New-Item -ItemType Directory -Path $testRoot | Out-Null
    $common=@{
        ExtractionPath=(Join-Path $fixtures 'extraction.json')
        MappingCatalogPath=(Join-Path $fixtures 'mapping-catalog.json')
        AdministratorDecisionsPath=(Join-Path $fixtures 'administrator-decisions.json')
        SettingsCatalogSnapshotPath=(Join-Path $fixtures 'settings-catalog-snapshot.json')
    }
    $reviewCommon=@{
        ExtractionPath=(Join-Path $fixtures 'mapping-review-extraction.json')
        SettingsCatalogSnapshotPath=$common.SettingsCatalogSnapshotPath
        ReferencePackRoot=(Join-Path $fixtures 'reference-pack')
    }
    $mappingCatalogHashBefore=(Get-FileHash -LiteralPath $common.MappingCatalogPath -Algorithm SHA256).Hash
    $reviewPathA=Join-Path $testRoot 'mapping-a.private-review.json'
    $reviewPathB=Join-Path $testRoot 'mapping-b.private-review.json'
    & (Join-Path $repoRoot 'scripts\New-CISMappingReviewWorklist.ps1') @reviewCommon -OutputPath $reviewPathA
    & (Join-Path $repoRoot 'scripts\New-CISMappingReviewWorklist.ps1') @reviewCommon -OutputPath $reviewPathB
    Assert-True (((Get-FileHash -LiteralPath $reviewPathA -Algorithm SHA256).Hash) -ceq ((Get-FileHash -LiteralPath $reviewPathB -Algorithm SHA256).Hash)) 'Repeated candidate worklists must be byte-identical.'
    Assert-True ($mappingCatalogHashBefore -ceq (Get-FileHash -LiteralPath $common.MappingCatalogPath -Algorithm SHA256).Hash) 'Candidate generation must not modify the mapping catalog.'
    $review=Read-Json $reviewPathA
    Assert-True (-not [bool]$review.mappingChangesMade) 'Candidate worklists must explicitly state that no mappings were changed.'
    Assert-True ([string]$review.schemaVersion -ceq '1.1' -and [string]$review.benchmark.id -ceq 'synthetic-intune-review' -and [string]$review.benchmark.version -ceq '1.0.0') 'Candidate worklists must bind evidence to the exact benchmark identity.'
    Assert-True ($review.summary.recommendationCount -eq 5 -and $review.summary.referenceDefinitionCount -eq 9 -and $review.summary.validatedOccurrenceCount -eq 11) 'Candidate worklist summary must count all synthetic recommendations and recursively validated reference settings.'
    Assert-True ($review.summary.uniqueCandidateRecommendations -eq 3 -and $review.summary.ambiguousCandidateRecommendations -eq 1 -and $review.summary.noCandidateRecommendations -eq 1 -and $review.summary.candidateLinkCount -eq 6) 'Candidate worklist status counts must be deterministic.'
    $manualCandidate=@($review.recommendations | Where-Object recommendationId -eq '1.3')[0]
    Assert-True ($manualCandidate.cisAssessmentMethod -ceq 'Manual' -and $manualCandidate.candidateStatus -ceq 'unique-candidate') 'A Manual assessment recommendation may still have a deterministic mapping candidate.'
    $ambiguousCandidate=@($review.recommendations | Where-Object recommendationId -eq '1.2')[0]
    Assert-True ($ambiguousCandidate.candidateStatus -ceq 'ambiguous-candidates' -and @($ambiguousCandidate.candidates).Count -eq 3) 'Multiple normalized title matches must remain explicitly ambiguous.'
    $nestedCandidate=@($ambiguousCandidate.candidates | Where-Object definitionId -eq 'synthetic_group_enabled')[0]
    Assert-True (@($nestedCandidate.occurrences[0].ancestorDefinitionIds).Count -eq 1 -and [string]$nestedCandidate.occurrences[0].observedValue.optionId -ceq 'synthetic_group_enabled_true') 'Nested historical settings must retain their exact ancestor and choice evidence.'
    $noCandidate=@($review.recommendations | Where-Object recommendationId -eq '1.4')[0]
    Assert-True ($noCandidate.candidateStatus -ceq 'none' -and @($noCandidate.candidates).Count -eq 0) 'Recommendations without deterministic title evidence must remain candidate-free.'

    $badReferenceRoot=Join-Path $testRoot 'bad-reference'
    $badReferencePolicies=Join-Path $badReferenceRoot 'configuration-policies'
    New-Item -ItemType Directory -Path $badReferencePolicies | Out-Null
    $referenceFixture=Get-ChildItem -LiteralPath (Join-Path $reviewCommon.ReferencePackRoot 'configuration-policies') -Filter *.json -File | Select-Object -First 1
    $badReference=Read-Json $referenceFixture.FullName
    $badReference.settings[0].settingInstance.choiceSettingValue.value='enabled'
    $badReferencePath=Join-Path $badReferencePolicies $referenceFixture.Name
    $badReference | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $badReferencePath -Encoding utf8
    $badReferenceFailed=$false
    try { & (Join-Path $repoRoot 'scripts\New-CISMappingReviewWorklist.ps1') @reviewCommon -ReferencePackRoot $badReferenceRoot -OutputPath (Join-Path $testRoot 'bad-reference.private-review.json') } catch { $badReferenceFailed=$true }
    Assert-True $badReferenceFailed 'A plausible but non-exact historical choice ID must fail closed.'

    $caseReferenceRoot=Join-Path $testRoot 'case-reference'
    $caseReferencePolicies=Join-Path $caseReferenceRoot 'configuration-policies'
    New-Item -ItemType Directory -Path $caseReferencePolicies | Out-Null
    $caseReference=Read-Json $referenceFixture.FullName
    $caseReference.settings[0].settingInstance.settingDefinitionId='SYNTHETIC_CHOICE'
    $caseReferencePath=Join-Path $caseReferencePolicies $referenceFixture.Name
    $caseReference | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $caseReferencePath -Encoding utf8
    $caseReferenceFailed=$false
    try { & (Join-Path $repoRoot 'scripts\New-CISMappingReviewWorklist.ps1') @reviewCommon -ReferencePackRoot $caseReferenceRoot -OutputPath (Join-Path $testRoot 'case-reference.private-review.json') } catch { $caseReferenceFailed=$true }
    Assert-True $caseReferenceFailed 'A historical definition ID with non-exact casing must fail closed.'

    $unsafeReviewNameFailed=$false
    try { & (Join-Path $repoRoot 'scripts\New-CISMappingReviewWorklist.ps1') @reviewCommon -OutputPath (Join-Path $testRoot 'review.json') } catch { $unsafeReviewNameFailed=$true }
    Assert-True $unsafeReviewNameFailed 'A private review worklist must use the ignored .private-review.json suffix.'

    $reviewCatalogPath=Join-Path $testRoot 'review-catalog.json'
    & (Join-Path $repoRoot 'scripts\New-CISMappingCatalog.ps1') `
        -ExtractionPath $reviewCommon.ExtractionPath `
        -OutputPath $reviewCatalogPath `
        -CatalogId 'synthetic-review-catalog' `
        -CatalogVersion '0.1.0' `
        -PackId 'synthetic-review-pack' `
        -PackName 'Synthetic Review Pack' `
        -PackVersion '0.1.0'
    $reviewCatalogHashBefore=(Get-FileHash -LiteralPath $reviewCatalogPath -Algorithm SHA256).Hash
    $approvalTemplateA=Join-Path $testRoot 'approval-a.private-approvals.json'
    $approvalTemplateB=Join-Path $testRoot 'approval-b.private-approvals.json'
    & (Join-Path $repoRoot 'scripts\New-CISMappingReviewApprovals.ps1') -MappingCatalogPath $reviewCatalogPath -ReviewWorklistPath $reviewPathA -CatalogVersion '0.2.0' -PackVersion '0.2.0' -OutputPath $approvalTemplateA
    & (Join-Path $repoRoot 'scripts\New-CISMappingReviewApprovals.ps1') -MappingCatalogPath $reviewCatalogPath -ReviewWorklistPath $reviewPathA -CatalogVersion '0.2.0' -PackVersion '0.2.0' -OutputPath $approvalTemplateB
    Assert-True (((Get-FileHash -LiteralPath $approvalTemplateA -Algorithm SHA256).Hash) -ceq ((Get-FileHash -LiteralPath $approvalTemplateB -Algorithm SHA256).Hash)) 'Repeated private approval templates must be byte-identical.'
    $approval=Read-Json $approvalTemplateA
    Assert-True (@($approval.reviews).Count -eq 4 -and @($approval.reviews | Where-Object outcome -ne 'defer').Count -eq 0) 'Every candidate review must start deferred and nondeployable.'

    $wrongBenchmarkWorklist=Read-Json $reviewPathA
    $wrongBenchmarkWorklist.benchmark.id='different-benchmark'
    $wrongBenchmarkWorklistPath=Join-Path $testRoot 'wrong-benchmark.private-review.json'
    $wrongBenchmarkWorklist | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $wrongBenchmarkWorklistPath -Encoding utf8
    $wrongBenchmarkFailed=$false
    try { & (Join-Path $repoRoot 'scripts\New-CISMappingReviewApprovals.ps1') -MappingCatalogPath $reviewCatalogPath -ReviewWorklistPath $wrongBenchmarkWorklistPath -CatalogVersion '0.2.0' -PackVersion '0.2.0' -OutputPath (Join-Path $testRoot 'wrong-benchmark.private-approvals.json') } catch { $wrongBenchmarkFailed=$true }
    Assert-True $wrongBenchmarkFailed 'Candidate evidence from a different benchmark identity must fail closed.'

    $approvedPolicy=[pscustomobject][ordered]@{
        id='synthetic-approved-l1'
        name='Synthetic Approved [L1]'
        description='Copyright-safe mapping approval test policy.'
        platforms='windows10'
        technologies='mdm'
        profiles=@('L1')
        roleScopeTagIds=@('0')
    }
    $approvedSelections=@{
        '1.1'=[pscustomobject][ordered]@{candidateDefinitionId='synthetic_choice';sourceFile='configuration-policies/Synthetic Settings [L1].json';path='settings[1]';topLevelDefinitionId='synthetic_choice';policy=$approvedPolicy}
        '1.2'=[pscustomobject][ordered]@{candidateDefinitionId='synthetic_group';sourceFile='configuration-policies/Synthetic Settings [L1].json';path='settings[3]';topLevelDefinitionId='synthetic_group';policy=$approvedPolicy}
        '1.3'=[pscustomobject][ordered]@{candidateDefinitionId='synthetic_string_collection';sourceFile='configuration-policies/Synthetic Settings [L1].json';path='settings[2]';topLevelDefinitionId='synthetic_string_collection';policy=$approvedPolicy}
        '1.5'=[pscustomobject][ordered]@{candidateDefinitionId='synthetic_parent_choice';sourceFile='configuration-policies/Synthetic Settings [L1].json';path='settings[4]';topLevelDefinitionId='synthetic_parent_choice';policy=$approvedPolicy}
    }
    foreach($review in @($approval.reviews)){
        $id=[string]$review.recommendationId
        if(-not $approvedSelections.ContainsKey($id)){continue}
        $review.outcome='mapped'
        $review.acknowledged=$true
        $review.valueBasis='benchmark-prescribed'
        $review.reviewedBy='Synthetic reviewer'
        $review.justification='Synthetic recommendation semantics, setting hierarchy, and exact value were reviewed.'
        $review.publicNotes='Exact synthetic setting hierarchy and value reviewed.'
        $review.selections=@($approvedSelections[$id])
    }
    $approvedPath=Join-Path $testRoot 'approved.private-approvals.json'
    $approval | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $approvedPath -Encoding utf8
    $approvedCatalogA=Join-Path $testRoot 'approved-catalog-a.json'
    $approvedCatalogB=Join-Path $testRoot 'approved-catalog-b.json'
    $applyCommon=@{
        MappingCatalogPath=$reviewCatalogPath
        ReviewWorklistPath=$reviewPathA
        ApprovalsPath=$approvedPath
        SettingsCatalogSnapshotPath=$reviewCommon.SettingsCatalogSnapshotPath
        ReferencePackRoot=$reviewCommon.ReferencePackRoot
    }
    & (Join-Path $repoRoot 'scripts\Apply-CISMappingReviewApprovals.ps1') @applyCommon -OutputPath $approvedCatalogA
    & (Join-Path $repoRoot 'scripts\Apply-CISMappingReviewApprovals.ps1') @applyCommon -OutputPath $approvedCatalogB
    Assert-True (((Get-FileHash -LiteralPath $approvedCatalogA -Algorithm SHA256).Hash) -ceq ((Get-FileHash -LiteralPath $approvedCatalogB -Algorithm SHA256).Hash)) 'Repeated approved catalog promotion must be byte-identical.'
    Assert-True ($reviewCatalogHashBefore -ceq (Get-FileHash -LiteralPath $reviewCatalogPath -Algorithm SHA256).Hash) 'Approval application must never modify the input catalog.'
    $approvedCatalog=Read-Json $approvedCatalogA
    Assert-True ([string]$approvedCatalog.version -ceq '0.2.0' -and [string]$approvedCatalog.pack.version -ceq '0.2.0') 'Approved catalog and pack versions must come from the explicit private approval file.'
    Assert-True (@($approvedCatalog.recommendations | Where-Object mappingStatus -eq 'mapped').Count -eq 4 -and @($approvedCatalog.recommendations | Where-Object mappingStatus -eq 'unresolved').Count -eq 1) 'Only explicitly approved reviews may become mapped.'
    Assert-True (@($approvedCatalog.settingsCatalogPolicies).Count -eq 1 -and @($approvedCatalog.settingsCatalogSettings).Count -eq 4) 'Approved selections must produce one reviewed policy and four exact setting trees.'

    $approvedPack=Join-Path $testRoot 'approved-pack'
    & (Join-Path $repoRoot 'scripts\Build-CISPolicyPack.ps1') -ExtractionPath $reviewCommon.ExtractionPath -MappingCatalogPath $approvedCatalogA -SettingsCatalogSnapshotPath $reviewCommon.SettingsCatalogSnapshotPath -OutputPath $approvedPack
    $approvedValidation=& (Join-Path $repoRoot 'scripts\Test-CISPolicyPack.ps1') -PackRoot $approvedPack -PassThru
    Assert-True $approvedValidation.IsValid 'An explicitly approved catalog must build a valid unassigned pack.'
    $approvedRecommendations=@(Read-Json (Join-Path $approvedPack 'spec\recommendations.json'))
    $approvedManual=@($approvedRecommendations | Where-Object recommendationId -eq '1.3')[0]
    Assert-True ($approvedManual.cisAssessmentMethod -ceq 'Manual' -and $approvedManual.mappingStatus -ceq 'mapped') 'Explicit catalog promotion must keep Manual assessment independent from deterministic mapped status.'
    $approvedSettings=@(Read-Json (Join-Path $approvedPack 'spec\settings-catalog.json'))
    $approvedNested=@($approvedSettings | Where-Object recommendationId -eq '1.5')[0]
    Assert-True (@($approvedNested.value.children).Count -eq 1 -and @($approvedNested.value.children[0].value.items).Count -eq 2) 'Approved historical nested choice/group evidence must retain the complete exact tree.'

    $deferredApplyFailed=$false
    try { & (Join-Path $repoRoot 'scripts\Apply-CISMappingReviewApprovals.ps1') @applyCommon -ApprovalsPath $approvalTemplateA -OutputPath (Join-Path $testRoot 'deferred-catalog.json') } catch { $deferredApplyFailed=$true }
    Assert-True $deferredApplyFailed 'A default all-deferred approval template must not produce a new catalog.'

    $fakeApproval=Read-Json $approvedPath
    @($fakeApproval.reviews | Where-Object recommendationId -eq '1.1')[0].selections[0].candidateDefinitionId='SYNTHETIC_CHOICE'
    $fakeApprovalPath=Join-Path $testRoot 'fake.private-approvals.json'
    $fakeApproval | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $fakeApprovalPath -Encoding utf8
    $fakeApprovalFailed=$false
    try { & (Join-Path $repoRoot 'scripts\Apply-CISMappingReviewApprovals.ps1') @applyCommon -ApprovalsPath $fakeApprovalPath -OutputPath (Join-Path $testRoot 'fake-catalog.json') } catch { $fakeApprovalFailed=$true }
    Assert-True $fakeApprovalFailed 'A case-changed or otherwise non-exact candidate definition must fail approval application.'

    $wrongPlatformApproval=Read-Json $approvedPath
    @($wrongPlatformApproval.reviews | Where-Object recommendationId -eq '1.1')[0].selections[0].policy.platforms='androidDeviceAdministrator'
    $wrongPlatformApprovalPath=Join-Path $testRoot 'wrong-platform.private-approvals.json'
    $wrongPlatformApproval | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $wrongPlatformApprovalPath -Encoding utf8
    $wrongPlatformApprovalFailed=$false
    try { & (Join-Path $repoRoot 'scripts\Apply-CISMappingReviewApprovals.ps1') @applyCommon -ApprovalsPath $wrongPlatformApprovalPath -OutputPath (Join-Path $testRoot 'wrong-platform-catalog.json') } catch { $wrongPlatformApprovalFailed=$true }
    Assert-True $wrongPlatformApprovalFailed 'Approval policy platform and technology must match the hashed reference policy exactly.'

    $organizationalApproval=Read-Json $approvedPath
    @($organizationalApproval.reviews | Where-Object recommendationId -eq '1.1')[0].valueBasis=$null
    $organizationalApprovalPath=Join-Path $testRoot 'organizational.private-approvals.json'
    $organizationalApproval | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $organizationalApprovalPath -Encoding utf8
    $organizationalApprovalFailed=$false
    try { & (Join-Path $repoRoot 'scripts\Apply-CISMappingReviewApprovals.ps1') @applyCommon -ApprovalsPath $organizationalApprovalPath -OutputPath (Join-Path $testRoot 'organizational-catalog.json') } catch { $organizationalApprovalFailed=$true }
    Assert-True $organizationalApprovalFailed 'A mapped review without an explicit benchmark-prescribed value basis must fail closed.'

    $seedCatalogPath=Join-Path $testRoot 'seed-catalog.json'
    & (Join-Path $repoRoot 'scripts\New-CISMappingCatalog.ps1') `
        -ExtractionPath $common.ExtractionPath `
        -OutputPath $seedCatalogPath `
        -CatalogId 'synthetic-seed' `
        -CatalogVersion '0.1.0' `
        -PackId 'synthetic-seed-pack' `
        -PackName 'Synthetic Seed Pack' `
        -PackVersion '0.1.0'
    $seedCatalog=Read-Json $seedCatalogPath
    Assert-True (@($seedCatalog.recommendations).Count -eq 3) 'Catalog seed must include every extracted recommendation.'
    Assert-True (@($seedCatalog.recommendations | Where-Object mappingStatus -ne 'unresolved').Count -eq 0) 'Catalog seed must classify every recommendation as unresolved.'
    Assert-True ($null -eq $seedCatalog.recommendations[0].PSObject.Properties['title']) 'Catalog seed must not copy benchmark titles or prose.'
    $seedPack=Join-Path $testRoot 'seed-pack'
    & (Join-Path $repoRoot 'scripts\Build-CISPolicyPack.ps1') -ExtractionPath $common.ExtractionPath -MappingCatalogPath $seedCatalogPath -OutputPath $seedPack
    $seedValidation=& (Join-Path $repoRoot 'scripts\Test-CISPolicyPack.ps1') -PackRoot $seedPack -PassThru
    Assert-True $seedValidation.IsValid 'All-unresolved catalog seed must build a valid nondeployable pack.'

    $packA=Join-Path $testRoot 'pack-a'
    $packB=Join-Path $testRoot 'pack-b'
    & (Join-Path $repoRoot 'scripts\Build-CISPolicyPack.ps1') @common -OutputPath $packA
    & (Join-Path $repoRoot 'scripts\Build-CISPolicyPack.ps1') @common -OutputPath $packB

    $filesA=@(Get-ChildItem -LiteralPath $packA -Recurse -File | ForEach-Object { $_.FullName.Substring($packA.Length+1) } | Sort-Object)
    $filesB=@(Get-ChildItem -LiteralPath $packB -Recurse -File | ForEach-Object { $_.FullName.Substring($packB.Length+1) } | Sort-Object)
    Assert-True (($filesA -join '|') -ceq ($filesB -join '|')) 'Repeated builds must contain the same files.'
    foreach ($relative in $filesA) {
        $hashA=(Get-FileHash -LiteralPath (Join-Path $packA $relative) -Algorithm SHA256).Hash
        $hashB=(Get-FileHash -LiteralPath (Join-Path $packB $relative) -Algorithm SHA256).Hash
        Assert-True ($hashA -ceq $hashB) "Repeated build differs: $relative"
    }

    $validation=& (Join-Path $repoRoot 'scripts\Test-CISPolicyPack.ps1') -PackRoot $packA -PassThru
    Assert-True $validation.IsValid 'Generated pack must pass validation.'
    $recommendations=@(Read-Json (Join-Path $packA 'spec\recommendations.json'))
    $manualMapped=@($recommendations | Where-Object recommendationId -eq '1.1')[0]
    Assert-True ($manualMapped.cisAssessmentMethod -ceq 'Manual') 'Manual assessment method must be preserved.'
    Assert-True ($manualMapped.mappingStatus -ceq 'mapped') 'Manual assessment may have a deterministic mapped implementation.'
    $inputMapped=@($recommendations | Where-Object recommendationId -eq '1.3')[0]
    Assert-True ($inputMapped.mappingStatus -ceq 'mapped') 'Valid explicit input must materialize a mapped recommendation.'
    Assert-True ($inputMapped.catalogMappingStatus -ceq 'requires-input') 'Original requires-input state must remain auditable.'
    Assert-True ($inputMapped.decisionRef -ceq 'retention-days') 'Decision provenance must be retained.'

    $packWithoutDecision=Join-Path $testRoot 'pack-without-decision'
    & (Join-Path $repoRoot 'scripts\Build-CISPolicyPack.ps1') -ExtractionPath $common.ExtractionPath -MappingCatalogPath $common.MappingCatalogPath -SettingsCatalogSnapshotPath $common.SettingsCatalogSnapshotPath -OutputPath $packWithoutDecision
    $withoutRecommendations=@(Read-Json (Join-Path $packWithoutDecision 'spec\recommendations.json'))
    $unresolvedInput=@($withoutRecommendations | Where-Object recommendationId -eq '1.3')[0]
    Assert-True ($unresolvedInput.mappingStatus -ceq 'requires-input') 'Missing administrator input must remain nondeployable.'
    $withoutSettings=@(Read-Json (Join-Path $packWithoutDecision 'spec\settings-catalog.json'))
    Assert-True ($withoutSettings.Count -eq 4) 'Only the setting that lacks required administrator input must be omitted.'

    $generatedSettings=@(Read-Json (Join-Path $packA 'spec\settings-catalog.json'))
    Assert-True ($generatedSettings.Count -eq 5) 'Scalar, collection, group, nested-choice, and administrator-input settings must all compile.'
    $collectionSpec=@($generatedSettings | Where-Object displayName -eq 'Synthetic string collection')[0]
    Assert-True ([string]$collectionSpec.value.kind -ceq 'string-collection' -and @($collectionSpec.value.values).Count -eq 2) 'String collection values must remain explicit and ordered.'
    $groupSpec=@($generatedSettings | Where-Object displayName -eq 'Synthetic group')[0]
    Assert-True ([string]$groupSpec.value.kind -ceq 'group-collection' -and @($groupSpec.value.items[0].children).Count -eq 2) 'Group collections must retain their reviewed child tree.'
    $nestedChoiceSpec=@($generatedSettings | Where-Object displayName -eq 'Synthetic parent choice')[0]
    Assert-True (@($nestedChoiceSpec.value.children).Count -eq 1 -and @($nestedChoiceSpec.value.children[0].value.items).Count -eq 2) 'Choice-dependent nested group rows must compile deterministically.'

    $ambiguousSnapshot=Read-Json (Join-Path $fixtures 'settings-catalog-snapshot.json')
    $ambiguousSnapshot.definitions=@($ambiguousSnapshot.definitions)+@($ambiguousSnapshot.definitions[0])
    $ambiguousPath=Join-Path $testRoot 'ambiguous-snapshot.json'
    $ambiguousSnapshot | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $ambiguousPath -Encoding utf8
    $ambiguousFailed=$false
    try { & (Join-Path $repoRoot 'scripts\Build-CISPolicyPack.ps1') @common -SettingsCatalogSnapshotPath $ambiguousPath -OutputPath (Join-Path $testRoot 'ambiguous-pack') } catch { $ambiguousFailed=$true }
    Assert-True $ambiguousFailed 'Ambiguous exact definition matches must fail closed.'

    $countMismatchSnapshot=Read-Json (Join-Path $fixtures 'settings-catalog-snapshot.json')
    $countMismatchSnapshot.retrieval.definitionCount++
    $countMismatchPath=Join-Path $testRoot 'count-mismatch-snapshot.json'
    $countMismatchSnapshot | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $countMismatchPath -Encoding utf8
    $countMismatchFailed=$false
    try { & (Join-Path $repoRoot 'scripts\Build-CISPolicyPack.ps1') @common -SettingsCatalogSnapshotPath $countMismatchPath -OutputPath (Join-Path $testRoot 'count-mismatch-pack') } catch { $countMismatchFailed=$true }
    Assert-True $countMismatchFailed 'A snapshot with inconsistent retrieval evidence must fail closed.'

    $badNestedChoiceCatalog=Read-Json (Join-Path $fixtures 'mapping-catalog.json')
    $badNestedGroup=@($badNestedChoiceCatalog.settingsCatalogSettings | Where-Object displayName -eq 'Synthetic group')[0]
    $badNestedGroup.value.items[0].children[0].value.optionId='enabled'
    $badNestedChoicePath=Join-Path $testRoot 'bad-nested-choice-catalog.json'
    $badNestedChoiceCatalog | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $badNestedChoicePath -Encoding utf8
    $badNestedChoiceFailed=$false
    try { & (Join-Path $repoRoot 'scripts\Build-CISPolicyPack.ps1') @common -MappingCatalogPath $badNestedChoicePath -OutputPath (Join-Path $testRoot 'bad-nested-choice-pack') } catch { $badNestedChoiceFailed=$true }
    Assert-True $badNestedChoiceFailed 'A plausible but non-exact nested choice ID must fail closed.'

    $badCollectionCatalog=Read-Json (Join-Path $fixtures 'mapping-catalog.json')
    $badCollection=@($badCollectionCatalog.settingsCatalogSettings | Where-Object displayName -eq 'Synthetic string collection')[0]
    $badCollection.value.values[0]=123
    $badCollectionPath=Join-Path $testRoot 'bad-collection-catalog.json'
    $badCollectionCatalog | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $badCollectionPath -Encoding utf8
    $badCollectionFailed=$false
    try { & (Join-Path $repoRoot 'scripts\Build-CISPolicyPack.ps1') @common -MappingCatalogPath $badCollectionPath -OutputPath (Join-Path $testRoot 'bad-collection-pack') } catch { $badCollectionFailed=$true }
    Assert-True $badCollectionFailed 'A collection element whose type contradicts the snapshot must fail closed.'

    $incompleteCatalog=Read-Json (Join-Path $fixtures 'mapping-catalog.json')
    $incompleteCatalog.recommendations=@($incompleteCatalog.recommendations | Where-Object recommendationId -ne '1.3')
    $incompletePath=Join-Path $testRoot 'incomplete-catalog.json'
    $incompleteCatalog | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $incompletePath -Encoding utf8
    $incompleteFailed=$false
    try { & (Join-Path $repoRoot 'scripts\Build-CISPolicyPack.ps1') -ExtractionPath $common.ExtractionPath -MappingCatalogPath $incompletePath -SettingsCatalogSnapshotPath $common.SettingsCatalogSnapshotPath -OutputPath (Join-Path $testRoot 'incomplete-pack') } catch { $incompleteFailed=$true }
    Assert-True $incompleteFailed 'A catalog that does not classify every expected recommendation must fail.'

    $bundlePath=Get-ChildItem -LiteralPath (Join-Path $packB 'policies\settings-catalog') -Filter *.json | Select-Object -First 1 -ExpandProperty FullName
    $bundle=Read-Json $bundlePath
    $bundle.settings=@([ordered]@{ settingInstance=[ordered]@{ settingDefinitionId='unvalidated-static-id' } })
    ConvertTo-Json -InputObject $bundle -Depth 100 | Set-Content -LiteralPath $bundlePath -Encoding utf8
    $staticValidation=& (Join-Path $repoRoot 'scripts\Test-CISPolicyPack.ps1') -PackRoot $packB -PassThru
    Assert-True (-not $staticValidation.IsValid) 'Unvalidated static Settings Catalog settings must be rejected.'

    $incompatibleSpecPath=Join-Path $packA 'spec\settings-catalog.json'
    $incompatibleSpecs=@(Read-Json $incompatibleSpecPath)
    $incompatibleSpecs[0].value | Add-Member -NotePropertyName values -NotePropertyValue @('misleading-extra-value')
    ConvertTo-Json -InputObject $incompatibleSpecs -Depth 100 | Set-Content -LiteralPath $incompatibleSpecPath -Encoding utf8
    $incompatibleValidation=& (Join-Path $repoRoot 'scripts\Test-CISPolicyPack.ps1') -PackRoot $packA -PassThru
    Assert-True (-not $incompatibleValidation.IsValid) 'A value kind with incompatible extra fields must be rejected.'

    Import-Module (Join-Path $repoRoot 'src\CISPolicyCreator.psm1') -Force -DisableNameChecking
    Assert-True (-not (Get-Command Get-CpcCandidateSettingId -ErrorAction SilentlyContinue)) 'Constructed candidate definition-ID helper must not exist.'
    $emptyResults=[System.Collections.Generic.List[object]]::new()
    Add-CpcResult -Results $emptyResults -Stage 'test' -Name 'first' -Status 'validated'
    Assert-True ($emptyResults.Count -eq 1) 'The first live validation result must be accepted into an empty result collection.'
    Assert-True (-not (Test-CpcGraphEndpointSafe 'https://graph.microsoft.com/beta/deviceManagement/configurationPolicies/1/assignments')) 'Assignment endpoint must be rejected.'
    Assert-True (-not (Test-CpcGraphEndpointSafe 'https://graph.microsoft.com:444/beta/deviceManagement/configurationPolicies')) 'Non-default Graph ports must be rejected.'
    Assert-True (-not (Test-CpcGraphEndpointSafe 'https://graph.microsoft.com/beta/deviceManagement/%2e%2e/groups')) 'Dot-segment path escape must be rejected.'
    Assert-True (-not (Test-CpcGraphEndpointSafe 'https://graph.microsoft.com/beta/deviceManagement/%2561ssignments')) 'Double-encoded path components must be rejected.'
    Assert-True (Test-CpcObjectContainsAssignments ([pscustomobject]@{ nested=[pscustomobject]@{ assignments=@() } })) 'Nested assignment payload must be detected.'
    $cpcModule=Get-Module CISPolicyCreator
    $pagingResult=& $cpcModule {
        $script:CpcMockCalls=0
        function script:Invoke-MgGraphRequest {
            param([string]$Method,[string]$Uri)
            $script:CpcMockCalls++
            if($Uri.Contains('$skip=2')){return [pscustomobject]@{value=@([pscustomobject]@{id='c'})}}
            return [pscustomobject]@{value=@([pscustomobject]@{id='a'},[pscustomobject]@{id='b'})}
        }
        try {
            $pagedItems=@(Invoke-CpcGraphPaged 'https://graph.microsoft.com/beta/test?$top=2')
            [pscustomobject]@{itemCount=$pagedItems.Count; callCount=$script:CpcMockCalls}
        } finally {
            Remove-Item Function:\script:Invoke-MgGraphRequest -ErrorAction SilentlyContinue
            Remove-Variable CpcMockCalls -Scope Script -ErrorAction SilentlyContinue
        }
    }
    Assert-True ($pagingResult.itemCount -eq 3 -and $pagingResult.callCount -eq 2) 'A full page without nextLink must continue using explicit skip pagination.'
    $duplicatePageFailed=& $cpcModule {
        $script:CpcMockCalls=0
        function script:Invoke-MgGraphRequest {
            param([string]$Method,[string]$Uri)
            $script:CpcMockCalls++
            if($script:CpcMockCalls -eq 1){return [pscustomobject]@{value=@([pscustomobject]@{id='a'},[pscustomobject]@{id='b'})}}
            return [pscustomobject]@{value=@([pscustomobject]@{id='b'})}
        }
        try {
            try { Invoke-CpcGraphPaged 'https://graph.microsoft.com/beta/test?$top=2' | Out-Null; return $false } catch { return $true }
        } finally {
            Remove-Item Function:\script:Invoke-MgGraphRequest -ErrorAction SilentlyContinue
            Remove-Variable CpcMockCalls -Scope Script -ErrorAction SilentlyContinue
        }
    }
    Assert-True $duplicatePageFailed 'Duplicate IDs across Graph pages must fail closed.'
    $omittedPathResult=& $cpcModule {
        function script:Invoke-MgGraphRequest {
            param([string]$Method,[string]$Uri)
            return [pscustomobject]@{id='explicit_definition'; '@odata.type'='#microsoft.graph.deviceManagementConfigurationSimpleSettingDefinition'}
        }
        try {
            $spec=[pscustomobject]@{
                displayName='Explicit definition'
                resolve=[pscustomobject]@{definitionId='explicit_definition'; baseUri='./Device/Vendor/MSFT/Policy'; offsetUri='/Config/Test/Value'; expectedType='#microsoft.graph.deviceManagementConfigurationSimpleSettingDefinition'}
            }
            $resolvedDefinition=Get-CpcSettingDefinition -Spec $spec -Definitions @()
            [string]$resolvedDefinition.id
        } finally {
            Remove-Item Function:\script:Invoke-MgGraphRequest -ErrorAction SilentlyContinue
        }
    }
    Assert-True ($omittedPathResult -ceq 'explicit_definition') 'An explicit live definition that omits optional CSP path metadata must still resolve by exact ID.'
    $contradictoryPathFailed=& $cpcModule {
        function script:Invoke-MgGraphRequest {
            param([string]$Method,[string]$Uri)
            return [pscustomobject]@{id='explicit_definition'; baseUri='./Device/Vendor/MSFT/Different'; offsetUri='/Config/Test/Value'; '@odata.type'='#microsoft.graph.deviceManagementConfigurationSimpleSettingDefinition'}
        }
        try {
            $spec=[pscustomobject]@{
                displayName='Explicit definition'
                resolve=[pscustomobject]@{definitionId='explicit_definition'; baseUri='./Device/Vendor/MSFT/Policy'; offsetUri='/Config/Test/Value'; expectedType='#microsoft.graph.deviceManagementConfigurationSimpleSettingDefinition'}
            }
            try { Get-CpcSettingDefinition -Spec $spec -Definitions @() | Out-Null; return $false } catch { return $true }
        } finally {
            Remove-Item Function:\script:Invoke-MgGraphRequest -ErrorAction SilentlyContinue
        }
    }
    Assert-True $contradictoryPathFailed 'A live CSP path that contradicts reviewed metadata must fail closed.'
    $snapshotFixture=Read-Json (Join-Path $fixtures 'settings-catalog-snapshot.json')
    $definitionCache=@{}
    foreach($fixtureDefinition in @($snapshotFixture.definitions)){$definitionCache[[string]$fixtureDefinition.id]=$fixtureDefinition}
    $collectionDefinition=@($snapshotFixture.definitions | Where-Object id -eq 'synthetic_string_collection')[0]
    $collectionBody=New-CpcConfigurationSettingBody -Definition $collectionDefinition -Spec $collectionSpec -Definitions @() -DefinitionCache $definitionCache
    Assert-True ([string]$collectionBody.settingInstance.'@odata.type' -ceq '#microsoft.graph.deviceManagementConfigurationSimpleSettingCollectionInstance') 'String collection must use the Graph collection instance type.'
    Assert-True (@($collectionBody.settingInstance.simpleSettingCollectionValue).Count -eq 2 -and [string]$collectionBody.settingInstance.simpleSettingCollectionValue[0].value -ceq 'principal-a') 'String collection payload must preserve exact reviewed values.'
    $groupDefinition=@($snapshotFixture.definitions | Where-Object id -eq 'synthetic_group')[0]
    $groupBody=New-CpcConfigurationSettingBody -Definition $groupDefinition -Spec $groupSpec -Definitions @() -DefinitionCache $definitionCache
    $groupChildren=@($groupBody.settingInstance.groupSettingCollectionValue[0].children)
    Assert-True ([string]$groupBody.settingInstance.'@odata.type' -ceq '#microsoft.graph.deviceManagementConfigurationGroupSettingCollectionInstance' -and $groupChildren.Count -eq 2) 'Group collection must emit the exact Graph group instance tree.'
    Assert-True ([int64]$groupChildren[1].simpleSettingValue.value -eq 90) 'Nested group integer must preserve its reviewed value.'
    $parentDefinition=@($snapshotFixture.definitions | Where-Object id -eq 'synthetic_parent_choice')[0]
    $parentBody=New-CpcConfigurationSettingBody -Definition $parentDefinition -Spec $nestedChoiceSpec -Definitions @() -DefinitionCache $definitionCache
    $nestedGroupInstance=@($parentBody.settingInstance.choiceSettingValue.children)[0]
    Assert-True ([string]$nestedGroupInstance.settingDefinitionId -ceq 'synthetic_nested_group' -and @($nestedGroupInstance.groupSettingCollectionValue).Count -eq 2) 'Choice-dependent nested group must emit all reviewed rows.'
    $choiceDefinition=@($snapshotFixture.definitions | Where-Object id -eq 'synthetic_choice')[0]
    $choiceSpec=[pscustomobject]@{ displayName='Synthetic choice'; value=[pscustomobject]@{ kind='choice'; optionId='synthetic_choice_enabled' } }
    $choiceBody=New-CpcConfigurationSettingBody -Definition $choiceDefinition -Spec $choiceSpec
    Assert-True ($choiceBody.settingInstance.choiceSettingValue.value -ceq 'synthetic_choice_enabled') 'Exact reviewed choice option must be emitted.'
    $badChoiceFailed=$false
    try { New-CpcConfigurationSettingBody -Definition $choiceDefinition -Spec ([pscustomobject]@{ displayName='Synthetic choice'; value=[pscustomobject]@{ kind='choice'; optionId='enabled' } }) | Out-Null } catch { $badChoiceFailed=$true }
    Assert-True $badChoiceFailed 'A plausible but non-exact choice ID must fail.'
    $integerDefinition=@($snapshotFixture.definitions | Where-Object id -eq 'synthetic_retention')[0]
    $rangeFailed=$false
    try { New-CpcConfigurationSettingBody -Definition $integerDefinition -Spec ([pscustomobject]@{ displayName='Synthetic retention'; value=[pscustomobject]@{ kind='integer'; value=500 } }) | Out-Null } catch { $rangeFailed=$true }
    Assert-True $rangeFailed 'Simple values outside the live definition range must fail.'
    Write-Host 'PASS: offline reproducible pipeline and fail-closed behavior.'
} finally {
    $resolvedTestRoot=[IO.Path]::GetFullPath($testRoot)
    if (-not $resolvedTestRoot.StartsWith($tempBase,[StringComparison]::OrdinalIgnoreCase)) { throw "Refusing unsafe test cleanup path: $resolvedTestRoot" }
    if (Test-Path -LiteralPath $resolvedTestRoot) { Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force }
}
