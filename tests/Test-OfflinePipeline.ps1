$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$repoRoot=Split-Path -Parent $PSScriptRoot
$fixtures=Join-Path $PSScriptRoot 'fixtures'
$tempBase=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
$pathComparison=if($IsWindows){[StringComparison]::OrdinalIgnoreCase}else{[StringComparison]::Ordinal}
$testRoot=Join-Path $tempBase ('CISPolicyCreator-tests-'+[guid]::NewGuid().ToString('N'))

function Assert-True([bool]$Condition,[string]$Message) { if (-not $Condition) { throw "ASSERTION FAILED: $Message" } }
function Read-Json([string]$Path) { Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -Depth 100 }

try {
    New-Item -ItemType Directory -Path $testRoot | Out-Null
    $graphContract=Import-PowerShellDataFile -LiteralPath (Join-Path $repoRoot 'tools\powershell-requirements.psd1')
    Assert-True ([string]$graphContract.MicrosoftGraphAuthentication.Name -ceq 'Microsoft.Graph.Authentication') 'The live authentication prerequisite must use the reviewed Graph module.'
    Assert-True ([version]$graphContract.MicrosoftGraphAuthentication.Version -eq [version]'2.28.0') 'The live authentication prerequisite must be locked to an exact tested version.'
    Assert-True ([string]$graphContract.MicrosoftGraphAuthentication.Repository -ceq 'PSGallery') 'The Graph prerequisite must name its exact package repository.'
    Assert-True ([string]$graphContract.MicrosoftGraphAuthentication.TreeSha256 -cmatch '^[0-9a-f]{64}$') 'The Graph module file tree must be content-hash locked.'
    $tamperedGraphRoot=Join-Path $testRoot 'tampered-graph-repository'
    New-Item -ItemType Directory -Path (Join-Path $tamperedGraphRoot 'scripts') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $tamperedGraphRoot 'tools') -Force | Out-Null
    $tamperedModuleRoot=Join-Path $tamperedGraphRoot ".modules\$($graphContract.MicrosoftGraphAuthentication.Name)\$($graphContract.MicrosoftGraphAuthentication.Version)"
    New-Item -ItemType Directory -Path $tamperedModuleRoot -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $repoRoot 'scripts\Import-CISGraphAuthentication.ps1') -Destination (Join-Path $tamperedGraphRoot 'scripts\Import-CISGraphAuthentication.ps1')
    Copy-Item -LiteralPath (Join-Path $repoRoot 'tools\powershell-requirements.psd1') -Destination (Join-Path $tamperedGraphRoot 'tools\powershell-requirements.psd1')
    Set-Content -LiteralPath (Join-Path $tamperedModuleRoot 'Microsoft.Graph.Authentication.psd1') -Value "@{ModuleVersion='2.28.0'}" -Encoding utf8
    $tamperedGraphError=$null
    try { & (Join-Path $tamperedGraphRoot 'scripts\Import-CISGraphAuthentication.ps1') } catch { $tamperedGraphError=$_.Exception.Message }
    Assert-True ([string]$tamperedGraphError -cmatch 'content hash') 'A same-version but altered repository-local Graph module must fail its content lock before import.'
    $initializer=Join-Path $repoRoot 'scripts\Initialize-CISPolicyCreator.ps1'
    $initializerFilePath=Join-Path $testRoot 'not-an-environment'
    Set-Content -LiteralPath $initializerFilePath -Value 'fixture' -Encoding utf8
    $initializerFileFailed=$false
    try { & $initializer -EnvironmentPath $initializerFilePath } catch { $initializerFileFailed=$true }
    Assert-True $initializerFileFailed 'Runtime initialization must not overwrite a file used as EnvironmentPath.'
    $initializerDirectoryPath=Join-Path $testRoot 'existing-unrelated-directory'
    New-Item -ItemType Directory -Path $initializerDirectoryPath | Out-Null
    $initializerDirectoryFailed=$false
    try { & $initializer -EnvironmentPath $initializerDirectoryPath } catch { $initializerDirectoryFailed=$true }
    Assert-True $initializerDirectoryFailed 'Runtime initialization must not treat an existing unrelated directory as a virtual environment.'
    $importScript=Join-Path $repoRoot 'scripts\Import-CISPolicyPack.ps1'
    $missingPack=Join-Path $testRoot 'does-not-exist'
    $tenantId='00000000-0000-0000-0000-000000000001'
    $missingImportAcknowledgement=$null
    try { & $importScript -PackRoot $missingPack -TenantId $tenantId } catch { $missingImportAcknowledgement=$_.Exception.Message }
    Assert-True ($missingImportAcknowledgement -ceq 'Import requires -ConfirmUnassignedImport before pack validation or Graph authentication.') 'Write import must require an explicit acknowledgement before resolving the pack or authenticating.'
    $missingImportTenant=$null
    try { & $importScript -PackRoot $missingPack -ConfirmUnassignedImport } catch { $missingImportTenant=$_.Exception.Message }
    Assert-True ($missingImportTenant -ceq 'Import requires an explicit TenantId before pack validation or Graph authentication.') 'Write import must require a pinned tenant before resolving the pack or authenticating.'
    $missingProbeAcknowledgement=$null
    try { & $importScript -PackRoot $missingPack -TenantId $tenantId -ProbeOnly } catch { $missingProbeAcknowledgement=$_.Exception.Message }
    Assert-True ($missingProbeAcknowledgement -ceq 'ProbeOnly requires -ConfirmTemporaryWriteProbe before pack validation or Graph authentication.') 'The temporary write probe must require its own explicit acknowledgement.'
    $missingProbeTenant=$null
    try { & $importScript -PackRoot $missingPack -ProbeOnly -ConfirmTemporaryWriteProbe } catch { $missingProbeTenant=$_.Exception.Message }
    Assert-True ($missingProbeTenant -ceq 'ProbeOnly requires an explicit TenantId before pack validation or Graph authentication.') 'The temporary write probe must require a pinned tenant.'
    $contradictoryLiveMode=$null
    try { & $importScript -PackRoot $missingPack -DryRun -ProbeOnly } catch { $contradictoryLiveMode=$_.Exception.Message }
    Assert-True ($contradictoryLiveMode -ceq 'DryRun and ProbeOnly cannot be used together.') 'DryRun must not be combinable with the write probe.'
    $dryRunWriteAcknowledgement=$null
    try { & $importScript -PackRoot $missingPack -DryRun -ConfirmUnassignedImport } catch { $dryRunWriteAcknowledgement=$_.Exception.Message }
    Assert-True ($dryRunWriteAcknowledgement -ceq 'DryRun is read-only and cannot be combined with an import or write acknowledgement.') 'DryRun must reject write acknowledgements rather than imply that a write can occur.'
    $dryRunPartialAcknowledgement=$null
    try { & $importScript -PackRoot $missingPack -DryRun -ConfirmPartialPack } catch { $dryRunPartialAcknowledgement=$_.Exception.Message }
    Assert-True ($dryRunPartialAcknowledgement -ceq 'DryRun is read-only and cannot be combined with an import or write acknowledgement.') 'DryRun must reject a partial-import acknowledgement because it performs no import.'
    $probePartialAcknowledgement=$null
    try { & $importScript -PackRoot $missingPack -TenantId $tenantId -ProbeOnly -ConfirmTemporaryWriteProbe -ConfirmPartialPack } catch { $probePartialAcknowledgement=$_.Exception.Message }
    Assert-True ($probePartialAcknowledgement -ceq 'ProbeOnly cannot be combined with ConfirmPartialPack.') 'A temporary probe must not acknowledge a separate partial-pack import.'
    $partialImportAcknowledgement=$null
    try { & $importScript -PackRoot (Join-Path $repoRoot 'templates\baseline') -TenantId $tenantId -ConfirmUnassignedImport } catch { $partialImportAcknowledgement=$_.Exception.Message }
    Assert-True ($partialImportAcknowledgement -ceq 'Import of a partial pack requires -ConfirmPartialPack before Graph authentication. Unresolved=1; requires-input=0.') 'A valid partial pack must require a separate explicit acknowledgement before Graph authentication.'

    $racedOutput=Join-Path $testRoot 'raced-pipeline-output'
    $racedPrivate="$racedOutput.private-extraction.json"
    $racedMarker=Join-Path $racedOutput 'owned-by-another-process.txt'
    $fakePython=Join-Path $testRoot 'fake-python.ps1'
    $escapedOutput=$racedOutput.Replace("'","''")
    $escapedPrivate=$racedPrivate.Replace("'","''")
    @"
param([Parameter(ValueFromRemainingArguments=`$true)][object[]]`$RemainingArguments)
New-Item -ItemType Directory -Path '$escapedOutput' | Out-Null
Set-Content -LiteralPath (Join-Path '$escapedOutput' 'owned-by-another-process.txt') -Value 'preserve me'
Set-Content -LiteralPath '$escapedPrivate' -Value 'preserve me too'
throw 'Synthetic extractor failure after another process claimed both outputs.'
"@ | Set-Content -LiteralPath $fakePython -Encoding utf8
    $racedPipelineFailed=$false
    try {
        & (Join-Path $repoRoot 'scripts\Invoke-CISPolicyPipeline.ps1') -PdfPath (Join-Path $fixtures 'extraction.json') -MappingCatalogPath (Join-Path $fixtures 'mapping-catalog.json') -OutputPath $racedOutput -PythonPath $fakePython -KeepPrivateExtraction
    } catch { $racedPipelineFailed=$true }
    Assert-True $racedPipelineFailed 'The synthetic extractor failure must abort the orchestrator.'
    Assert-True ((Test-Path -LiteralPath $racedMarker) -and (Test-Path -LiteralPath $racedPrivate)) 'Failed pipeline cleanup must not delete output paths claimed by another process after preflight.'

    $existingCompilerOutput=Join-Path $testRoot 'existing-compiler-output'
    New-Item -ItemType Directory -Path $existingCompilerOutput | Out-Null
    $existingCompilerMarker=Join-Path $existingCompilerOutput 'owned-by-another-process.txt'
    Set-Content -LiteralPath $existingCompilerMarker -Value 'preserve me'
    $existingCompilerFailed=$false
    try { & (Join-Path $repoRoot 'scripts\Build-CISPolicyPack.ps1') -ExtractionPath (Join-Path $fixtures 'extraction.json') -MappingCatalogPath (Join-Path $fixtures 'mapping-catalog.json') -SettingsCatalogSnapshotPath (Join-Path $fixtures 'settings-catalog-snapshot.json') -OutputPath $existingCompilerOutput } catch { $existingCompilerFailed=$true }
    Assert-True ($existingCompilerFailed -and (Test-Path -LiteralPath $existingCompilerMarker)) 'The standalone compiler must refuse and preserve a claimed output directory.'

    $linkedPack=Join-Path $testRoot 'linked-pack'
    Copy-Item -LiteralPath (Join-Path $repoRoot 'templates\baseline') -Destination $linkedPack -Recurse
    $outsideSpec=Join-Path $testRoot 'outside-spec'
    Copy-Item -LiteralPath (Join-Path $linkedPack 'spec') -Destination $outsideSpec -Recurse
    $linkedSpec=Join-Path $linkedPack 'spec'
    Remove-Item -LiteralPath $linkedSpec -Recurse -Force
    if($IsWindows){New-Item -ItemType Junction -Path $linkedSpec -Target $outsideSpec | Out-Null}
    else{New-Item -ItemType SymbolicLink -Path $linkedSpec -Target $outsideSpec | Out-Null}
    $linkedValidation=& (Join-Path $repoRoot 'scripts\Test-CISPolicyPack.ps1') -PackRoot $linkedPack -PassThru
    Assert-True ((-not $linkedValidation.IsValid) -and @($linkedValidation.Issues | Where-Object {$_ -cmatch 'Filesystem links are not allowed'}).Count -gt 0) 'A pack containing a symlink or junction must fail before linked content is read.'

    $linkedPackRoot=Join-Path $testRoot 'linked-pack-root'
    if($IsWindows){New-Item -ItemType Junction -Path $linkedPackRoot -Target (Join-Path $repoRoot 'templates\baseline') | Out-Null}
    else{New-Item -ItemType SymbolicLink -Path $linkedPackRoot -Target (Join-Path $repoRoot 'templates\baseline') | Out-Null}
    $linkedRootValidation=& (Join-Path $repoRoot 'scripts\Test-CISPolicyPack.ps1') -PackRoot $linkedPackRoot -PassThru
    Assert-True ((-not $linkedRootValidation.IsValid) -and @($linkedRootValidation.Issues | Where-Object {$_ -cmatch 'Filesystem links are not allowed.*pack root'}).Count -gt 0) 'A pack root that is itself a symlink or junction must fail before content is read.'

    if($IsLinux){
        $caseEscapingPack=Join-Path $testRoot 'case-escaping-pack'
        $caseSiblingPack=Join-Path $testRoot 'CASE-ESCAPING-PACK'
        Copy-Item -LiteralPath (Join-Path $repoRoot 'templates\baseline') -Destination $caseEscapingPack -Recurse
        New-Item -ItemType Directory -Path (Join-Path $caseSiblingPack 'spec') -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $caseEscapingPack 'spec\recommendations.json') -Destination (Join-Path $caseSiblingPack 'spec\recommendations.json')
        $caseManifest=Read-Json (Join-Path $caseEscapingPack 'manifest.json')
        $caseManifest.recommendationsSpec='../CASE-ESCAPING-PACK/spec/recommendations.json'
        $caseManifest | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath (Join-Path $caseEscapingPack 'manifest.json') -Encoding utf8
        $caseEscapeValidation=& (Join-Path $repoRoot 'scripts\Test-CISPolicyPack.ps1') -PackRoot $caseEscapingPack -PassThru
        Assert-True ((-not $caseEscapeValidation.IsValid) -and @($caseEscapeValidation.Issues | Where-Object {$_ -cmatch 'escapes the pack root'}).Count -gt 0) 'Case-distinct sibling paths must not pass pack-root containment on a case-sensitive filesystem.'
    }

    $common=@{
        ExtractionPath=(Join-Path $fixtures 'extraction.json')
        MappingCatalogPath=(Join-Path $fixtures 'mapping-catalog.json')
        AdministratorDecisionsPath=(Join-Path $fixtures 'administrator-decisions.json')
        SettingsCatalogSnapshotPath=(Join-Path $fixtures 'settings-catalog-snapshot.json')
    }
    $powershellLocation=Join-Path $testRoot 'powershell-location'
    $nativeCurrentDirectory=Join-Path $testRoot 'native-current-directory'
    New-Item -ItemType Directory -Path $powershellLocation,$nativeCurrentDirectory | Out-Null
    $originalNativeCurrentDirectory=[Environment]::CurrentDirectory
    Push-Location -LiteralPath $powershellLocation
    try {
        [Environment]::CurrentDirectory=$nativeCurrentDirectory
        & (Join-Path $repoRoot 'scripts\Build-CISPolicyPack.ps1') @common -OutputPath '.\relative-pack'
    } finally {
        [Environment]::CurrentDirectory=$originalNativeCurrentDirectory
        Pop-Location
    }
    Assert-True (Test-Path -LiteralPath (Join-Path $powershellLocation 'relative-pack\manifest.json')) 'A relative pack OutputPath must resolve from the PowerShell location.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $nativeCurrentDirectory 'relative-pack'))) 'A relative pack OutputPath must not resolve from the hidden native process directory.'
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
    $uppercaseReviewNameFailed=$false
    try { & (Join-Path $repoRoot 'scripts\New-CISMappingReviewWorklist.ps1') @reviewCommon -OutputPath (Join-Path $testRoot 'review.PRIVATE-REVIEW.JSON') } catch { $uppercaseReviewNameFailed=$true }
    Assert-True $uppercaseReviewNameFailed 'A private review worklist must use the exact lowercase suffix covered by .gitignore.'

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
    $uppercaseApprovalNameFailed=$false
    try { & (Join-Path $repoRoot 'scripts\New-CISMappingReviewApprovals.ps1') -MappingCatalogPath $reviewCatalogPath -ReviewWorklistPath $reviewPathA -CatalogVersion '0.2.0' -PackVersion '0.2.0' -OutputPath (Join-Path $testRoot 'approval.PRIVATE-APPROVALS.JSON') } catch { $uppercaseApprovalNameFailed=$true }
    Assert-True $uppercaseApprovalNameFailed 'A private approval template must use the exact lowercase suffix covered by .gitignore.'
    $approval=Read-Json $approvalTemplateA
    Assert-True (@($approval.reviews).Count -eq 4 -and @($approval.reviews | Where-Object outcome -ne 'defer').Count -eq 0) 'Every candidate review must start deferred and nondeployable.'

    $reviewReportA=Join-Path $testRoot 'progress-a.private-review-report.json'
    $reviewReportB=Join-Path $testRoot 'progress-b.private-review-report.json'
    $reviewReportCsv=Join-Path $testRoot 'progress.private-review-report.csv'
    $reportCommon=@{MappingCatalogPath=$reviewCatalogPath;ReviewWorklistPath=$reviewPathA;ApprovalsPath=$approvalTemplateA}
    & (Join-Path $repoRoot 'scripts\Get-CISMappingReviewReport.ps1') @reportCommon -JsonPath $reviewReportA -CsvPath $reviewReportCsv
    & (Join-Path $repoRoot 'scripts\Get-CISMappingReviewReport.ps1') @reportCommon -JsonPath $reviewReportB
    Assert-True (((Get-FileHash -LiteralPath $reviewReportA -Algorithm SHA256).Hash) -ceq ((Get-FileHash -LiteralPath $reviewReportB -Algorithm SHA256).Hash)) 'Repeated private review reports must be byte-identical.'
    $reviewReport=Read-Json $reviewReportA
    Assert-True (-not [bool]$reviewReport.mappingChangesMade -and $reviewReport.summary.recommendationCount -eq 5 -and $reviewReport.summary.pendingReviewRows -eq 4) 'A review report must be candidate-only and count every pending candidate review.'
    Assert-True ($reviewReport.summary.uniqueCandidates -eq 3 -and $reviewReport.summary.ambiguousCandidates -eq 1 -and $reviewReport.summary.noCandidates -eq 1) 'A review report must preserve deterministic candidate classifications.'
    Assert-True (-not $reviewReport.summary.reviewQueueComplete -and -not $reviewReport.summary.catalogComplete -and -not $reviewReport.summary.readyForCatalogPromotion) 'An all-deferred unresolved review queue must not report completion or promotion readiness.'
    $manualReportRow=@($reviewReport.recommendations | Where-Object recommendationId -eq '1.3')[0]
    Assert-True ($manualReportRow.cisAssessmentMethod -ceq 'Manual' -and $manualReportRow.state -ceq 'pending-review') 'Review reporting must keep Manual assessment independent from candidate mapping state.'
    Assert-True (@($reviewReport.recommendations | Where-Object { $null -ne $_.PSObject.Properties['title'] }).Count -eq 0) 'Review progress reports must not copy private benchmark titles.'
    $unsafeReportNameFailed=$false
    try { & (Join-Path $repoRoot 'scripts\Get-CISMappingReviewReport.ps1') @reportCommon -JsonPath (Join-Path $testRoot 'progress.json') } catch { $unsafeReportNameFailed=$true }
    Assert-True $unsafeReportNameFailed 'A private review report must use the ignored .private-review-report.json suffix.'
    $uppercaseReportNameFailed=$false
    try { & (Join-Path $repoRoot 'scripts\Get-CISMappingReviewReport.ps1') @reportCommon -JsonPath (Join-Path $testRoot 'progress.PRIVATE-REVIEW-REPORT.JSON') } catch { $uppercaseReportNameFailed=$true }
    Assert-True $uppercaseReportNameFailed 'A private review report must use the exact lowercase suffix covered by .gitignore.'

    $uppercaseApplyApprovalNameFailed=$false
    try { & (Join-Path $repoRoot 'scripts\Apply-CISMappingReviewApprovals.ps1') -ExtractionPath $reviewCommon.ExtractionPath -MappingCatalogPath $reviewCatalogPath -ReviewWorklistPath $reviewPathA -ApprovalsPath (Join-Path $testRoot 'approval.PRIVATE-APPROVALS.JSON') -SettingsCatalogSnapshotPath $reviewCommon.SettingsCatalogSnapshotPath -ReferencePackRoot $reviewCommon.ReferencePackRoot -OutputPath (Join-Path $testRoot 'uppercase-approval-output.json') } catch { $uppercaseApplyApprovalNameFailed=$true }
    Assert-True $uppercaseApplyApprovalNameFailed 'Applying approvals must require the exact lowercase private approval suffix.'

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
        ExtractionPath=$reviewCommon.ExtractionPath
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

    $partiallyRejectedApproval=Read-Json $approvedPath
    $rejectedReview=@($partiallyRejectedApproval.reviews | Where-Object recommendationId -eq '1.1')[0]
    $rejectedReview.outcome='rejected'
    $rejectedReview.acknowledged=$true
    $rejectedReview.valueBasis=$null
    $rejectedReview.reviewedBy='Synthetic reviewer'
    $rejectedReview.justification='The historical candidate was reviewed and is not semantically equivalent.'
    $rejectedReview.publicNotes='Historical candidate rejected; recommendation remains unresolved.'
    $rejectedReview.selections=@()
    $partiallyRejectedPath=Join-Path $testRoot 'partially-rejected.private-approvals.json'
    $partiallyRejectedApproval | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $partiallyRejectedPath -Encoding utf8
    $partiallyRejectedReportPath=Join-Path $testRoot 'partially-rejected.private-review-report.json'
    & (Join-Path $repoRoot 'scripts\Get-CISMappingReviewReport.ps1') @reportCommon -ApprovalsPath $partiallyRejectedPath -JsonPath $partiallyRejectedReportPath
    $partiallyRejectedReport=Read-Json $partiallyRejectedReportPath
    Assert-True ($partiallyRejectedReport.summary.rejectedReviews -eq 1 -and $partiallyRejectedReport.summary.mappedReviews -eq 3 -and $partiallyRejectedReport.summary.pendingReviewRows -eq 0 -and $partiallyRejectedReport.summary.reviewQueueComplete) 'Explicit rejections must close review rows without claiming a mapping.'
    $partiallyRejectedCatalogPath=Join-Path $testRoot 'partially-rejected-catalog.json'
    & (Join-Path $repoRoot 'scripts\Apply-CISMappingReviewApprovals.ps1') @applyCommon -ApprovalsPath $partiallyRejectedPath -OutputPath $partiallyRejectedCatalogPath
    $partiallyRejectedCatalog=Read-Json $partiallyRejectedCatalogPath
    $rejectedCatalogRecommendation=@($partiallyRejectedCatalog.recommendations | Where-Object recommendationId -eq '1.1')[0]
    Assert-True ($rejectedCatalogRecommendation.mappingStatus -ceq 'unresolved' -and @($partiallyRejectedCatalog.settingsCatalogSettings | Where-Object recommendationId -eq '1.1').Count -eq 0) 'A rejected candidate must remain unresolved and emit no policy setting.'

    $allRejectedApproval=Read-Json $approvalTemplateA
    foreach($review in @($allRejectedApproval.reviews)){
        $review.outcome='rejected';$review.acknowledged=$true;$review.valueBasis=$null
        $review.reviewedBy='Synthetic reviewer';$review.justification='Synthetic false candidate reviewed.';$review.publicNotes='Candidate rejected; unresolved retained.';$review.selections=@()
    }
    $allRejectedPath=Join-Path $testRoot 'all-rejected.private-approvals.json'
    $allRejectedApproval | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $allRejectedPath -Encoding utf8
    $allRejectedOutput=Join-Path $testRoot 'all-rejected-catalog.json'
    $allRejectedFailed=$false
    try { & (Join-Path $repoRoot 'scripts\Apply-CISMappingReviewApprovals.ps1') @applyCommon -ApprovalsPath $allRejectedPath -OutputPath $allRejectedOutput } catch { $allRejectedFailed=$true }
    Assert-True ($allRejectedFailed -and -not (Test-Path -LiteralPath $allRejectedOutput)) 'An all-rejected review file must write no catalog because rejection is never a mapping.'

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

    $wrongExtraction=Read-Json $reviewCommon.ExtractionPath
    $wrongExtraction.source.sha256=('3'*64)
    $wrongExtractionPath=Join-Path $testRoot 'wrong-extraction.json'
    $wrongExtraction | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $wrongExtractionPath -Encoding utf8
    $wrongExtractionOutput=Join-Path $testRoot 'wrong-extraction-catalog.json'
    $wrongExtractionFailed=$false
    try { & (Join-Path $repoRoot 'scripts\Apply-CISMappingReviewApprovals.ps1') @applyCommon -ExtractionPath $wrongExtractionPath -OutputPath $wrongExtractionOutput } catch { $wrongExtractionFailed=$true }
    Assert-True ($wrongExtractionFailed -and -not (Test-Path -LiteralPath $wrongExtractionOutput)) 'Approval application must reject an extraction whose file hash differs from the reviewed evidence and write nothing.'

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

    $invalidExistingCatalog=Read-Json $reviewCatalogPath
    $invalidExistingCatalog.graphObjects=@([pscustomobject][ordered]@{
        name='Invalid pre-existing synthetic object'
        recommendationIds=@('missing-recommendation')
        profiles=@('L1')
        endpoint='https://graph.microsoft.com/beta/deviceManagement/deviceCompliancePolicies'
        payload=[pscustomobject]@{}
    })
    $invalidExistingCatalogPath=Join-Path $testRoot 'invalid-existing-catalog.json'
    $invalidExistingCatalog | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $invalidExistingCatalogPath -Encoding utf8
    $invalidApprovalTemplate=Join-Path $testRoot 'invalid-existing.private-approvals.json'
    & (Join-Path $repoRoot 'scripts\New-CISMappingReviewApprovals.ps1') -MappingCatalogPath $invalidExistingCatalogPath -ReviewWorklistPath $reviewPathA -CatalogVersion '0.2.0' -PackVersion '0.2.0' -OutputPath $invalidApprovalTemplate
    $invalidApproval=Read-Json $invalidApprovalTemplate
    $invalidApproval.reviews=@($approval.reviews)
    $invalidApproval | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $invalidApprovalTemplate -Encoding utf8
    $invalidPromotionOutput=Join-Path $testRoot 'invalid-promotion-catalog.json'
    $invalidPromotionFailed=$false
    try { & (Join-Path $repoRoot 'scripts\Apply-CISMappingReviewApprovals.ps1') @applyCommon -MappingCatalogPath $invalidExistingCatalogPath -ApprovalsPath $invalidApprovalTemplate -OutputPath $invalidPromotionOutput } catch { $invalidPromotionFailed=$true }
    Assert-True ($invalidPromotionFailed -and -not (Test-Path -LiteralPath $invalidPromotionOutput)) 'A promoted catalog that fails complete pack compilation must not be published.'

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
    $seedManifest=Read-Json (Join-Path $seedPack 'manifest.json')
    Assert-True ($null -eq $seedManifest.settingsCatalogProbe) 'A pack without an eligible mapped leaf setting must not invent a write probe.'

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
    $mappingReportJsonA=Join-Path $testRoot 'mapping-report-a.json'
    $mappingReportJsonB=Join-Path $testRoot 'mapping-report-b.json'
    $mappingReportCsv=Join-Path $testRoot 'mapping-report-a.csv'
    $mappingReportResult=& (Join-Path $repoRoot 'scripts\Get-CISMappingReport.ps1') -PackRoot $packA -JsonPath $mappingReportJsonA -CsvPath $mappingReportCsv -PassThru
    & (Join-Path $repoRoot 'scripts\Get-CISMappingReport.ps1') -PackRoot $packA -JsonPath $mappingReportJsonB
    Assert-True (((Get-FileHash -LiteralPath $mappingReportJsonA -Algorithm SHA256).Hash) -ceq ((Get-FileHash -LiteralPath $mappingReportJsonB -Algorithm SHA256).Hash)) 'Repeated mapping reports must be byte-identical.'
    Assert-True ($mappingReportResult.Summary.RecommendationCount -eq 3 -and $mappingReportResult.Summary.Mapped -eq 3 -and $mappingReportResult.Summary.CatalogComplete) 'A validated fully resolved pack must report complete without conflating assessment and mapping states.'
    $mappingReportManual=@($mappingReportResult.Rows | Where-Object RecommendationId -eq '1.1')[0]
    Assert-True ($mappingReportManual.CisAssessmentMethod -ceq 'Manual' -and $mappingReportManual.MappingStatus -ceq 'mapped') 'Mapping reporting must preserve Manual assessment independently from mapped status.'
    $mappingReportOverwriteFailed=$false
    try { & (Join-Path $repoRoot 'scripts\Get-CISMappingReport.ps1') -PackRoot $packA -JsonPath $mappingReportJsonA } catch { $mappingReportOverwriteFailed=$true }
    Assert-True $mappingReportOverwriteFailed 'Mapping reports must not overwrite an existing output file.'
    $manifest=Read-Json (Join-Path $packA 'manifest.json')
    Assert-True ([string]$manifest.settingsCatalogProbe.recommendationId -ceq '1.2') 'The compiler must bind its deterministic probe to the originating mapped recommendation.'
    Assert-True ([string]$manifest.settingsCatalogProbe.resolve.definitionId -ceq 'synthetic_choice' -and [string]$manifest.settingsCatalogProbe.value.optionId -ceq 'synthetic_choice_enabled') 'The probe must copy an exact snapshot-resolved definition and reviewed option.'
    Assert-True ([string]$manifest.settingsCatalogProbe.platforms -ceq 'windows10' -and [string]$manifest.settingsCatalogProbe.technologies -ceq 'mdm') 'The probe must copy its policy platform and technology.'

    $tamperedProbePack=Join-Path $testRoot 'tampered-probe-pack'
    Copy-Item -LiteralPath $packA -Destination $tamperedProbePack -Recurse
    $tamperedProbeManifestPath=Join-Path $tamperedProbePack 'manifest.json'
    $tamperedProbeManifest=Read-Json $tamperedProbeManifestPath
    $tamperedProbeManifest.settingsCatalogProbe.value.optionId='plausible-but-unreviewed'
    $tamperedProbeManifest | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $tamperedProbeManifestPath -Encoding utf8
    $tamperedProbeValidation=& (Join-Path $repoRoot 'scripts\Test-CISPolicyPack.ps1') -PackRoot $tamperedProbePack -PassThru
    Assert-True (-not $tamperedProbeValidation.IsValid) 'A probe value that differs from the generated reviewed setting must fail pack validation.'
    $invalidMappingReportPath=Join-Path $testRoot 'mapping-report-invalid.json'
    $invalidMappingReportFailed=$false
    try { & (Join-Path $repoRoot 'scripts\Get-CISMappingReport.ps1') -PackRoot $tamperedProbePack -JsonPath $invalidMappingReportPath } catch { $invalidMappingReportFailed=$true }
    Assert-True ($invalidMappingReportFailed -and -not (Test-Path -LiteralPath $invalidMappingReportPath)) 'A tampered pack must not produce a mapping report.'
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
    $withoutDecisionReport=& (Join-Path $repoRoot 'scripts\Get-CISMappingReport.ps1') -PackRoot $packWithoutDecision -PassThru
    Assert-True (-not $withoutDecisionReport.Summary.CatalogComplete -and $withoutDecisionReport.Summary.RequiresInput -eq 1) 'A valid pack with an unsupplied administrator decision must report incomplete without treating it as invalid.'
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
    $expectedPolicy=[ordered]@{
        name='Synthetic existing policy';description='Expected description';platforms='windows10';technologies='mdm';roleScopeTagIds=@('tag-b','tag-a')
        settings=@(
            [ordered]@{'@odata.type'='#microsoft.graph.deviceManagementConfigurationSetting';settingInstance=[ordered]@{'@odata.type'='#microsoft.graph.deviceManagementConfigurationChoiceSettingInstance';settingDefinitionId='definition-b';choiceSettingValue=[ordered]@{'@odata.type'='#microsoft.graph.deviceManagementConfigurationChoiceSettingValue';value='definition-b_enabled';children=@()}}},
            [ordered]@{'@odata.type'='#microsoft.graph.deviceManagementConfigurationSetting';settingInstance=[ordered]@{'@odata.type'='#microsoft.graph.deviceManagementConfigurationSimpleSettingInstance';settingDefinitionId='definition-a';simpleSettingValue=[ordered]@{'@odata.type'='#microsoft.graph.deviceManagementConfigurationIntegerSettingValue';value=1}}}
        )
    }
    $actualPolicy=[pscustomobject]@{id='server-policy-id';name='Synthetic existing policy';description='Expected description';platforms='windows10';technologies='mdm';roleScopeTagIds=@('tag-a','tag-b');templateReference=[pscustomobject]@{templateId='';templateFamily='none'};createdDateTime='server-managed'}
    $actualSettings=@(
        [pscustomobject]@{id='server-setting-a';'@odata.type'='#microsoft.graph.deviceManagementConfigurationSetting';'@odata.etag'='ignored';settingInstance=[pscustomobject]@{'@odata.type'='#microsoft.graph.deviceManagementConfigurationSimpleSettingInstance';settingDefinitionId='definition-a';simpleSettingValue=[pscustomobject]@{'@odata.type'='#microsoft.graph.deviceManagementConfigurationIntegerSettingValue';value=1}}},
        [pscustomobject]@{id='server-setting-b';'@odata.type'='#microsoft.graph.deviceManagementConfigurationSetting';settingInstance=[pscustomobject]@{'@odata.type'='#microsoft.graph.deviceManagementConfigurationChoiceSettingInstance';settingDefinitionId='definition-b';choiceSettingValue=[pscustomobject]@{'@odata.type'='#microsoft.graph.deviceManagementConfigurationChoiceSettingValue';value='definition-b_enabled';children=@()}}}
    )
    $equivalentPolicy=Compare-CpcSettingsCatalogPolicy -ExpectedPolicy $expectedPolicy -ActualPolicy $actualPolicy -ActualSettings $actualSettings
    Assert-True ($equivalentPolicy.equivalent -and $equivalentPolicy.expectedSettingCount -eq 2 -and $equivalentPolicy.actualSettingCount -eq 2) 'Existing policy verification must ignore only response metadata, wrapper IDs, role-tag ordering, and an empty template reference.'
    $wrongValueSettings=@($actualSettings | ConvertTo-Json -Depth 100 | ConvertFrom-Json -Depth 100)
    $wrongValueSettings[1].settingInstance.choiceSettingValue.value='definition-b_disabled'
    Assert-True (-not (Compare-CpcSettingsCatalogPolicy -ExpectedPolicy $expectedPolicy -ActualPolicy $actualPolicy -ActualSettings $wrongValueSettings).equivalent) 'An existing policy with a different exact choice ID must not be skipped.'
    $extraSettings=@($actualSettings)+@([pscustomobject]@{id='server-setting-c';'@odata.type'='#microsoft.graph.deviceManagementConfigurationSetting';settingInstance=[pscustomobject]@{'@odata.type'='#microsoft.graph.deviceManagementConfigurationSimpleSettingInstance';settingDefinitionId='definition-c';simpleSettingValue=[pscustomobject]@{'@odata.type'='#microsoft.graph.deviceManagementConfigurationIntegerSettingValue';value=3}}})
    Assert-True (-not (Compare-CpcSettingsCatalogPolicy -ExpectedPolicy $expectedPolicy -ActualPolicy $actualPolicy -ActualSettings $extraSettings).equivalent) 'An existing policy with an extra setting must not be skipped.'
    $wrongMetadataPolicy=$actualPolicy.PSObject.Copy();$wrongMetadataPolicy.description='Different description'
    Assert-True (-not (Compare-CpcSettingsCatalogPolicy -ExpectedPolicy $expectedPolicy -ActualPolicy $wrongMetadataPolicy -ActualSettings $actualSettings).equivalent) 'An existing policy with different policy metadata must not be skipped.'
    $duplicateExistingSettingFailed=$false
    try { Compare-CpcSettingsCatalogPolicy -ExpectedPolicy $expectedPolicy -ActualPolicy $actualPolicy -ActualSettings @($actualSettings+$actualSettings[0]) | Out-Null } catch { $duplicateExistingSettingFailed=$true }
    Assert-True $duplicateExistingSettingFailed 'Duplicate top-level setting definition IDs in an existing policy must fail closed.'
    Assert-CpcNoGenericGraphObjectCollision -Name 'New generic object' -ExistingObjects @()
    $genericCollisionError=$null
    try { Assert-CpcNoGenericGraphObjectCollision -Name 'Existing generic object' -ExistingObjects @([pscustomobject]@{id='existing-object-id'}) } catch { $genericCollisionError=$_.Exception.Message }
    Assert-True ([string]$genericCollisionError -cmatch 'cannot prove their content equivalent') 'A same-name generic Graph object must fail closed because endpoint-agnostic equivalence cannot be proven.'
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
    $policyBody=New-CpcSettingsCatalogPolicyBody -Policy ([pscustomobject]@{name='Array shape test';description='';platforms='windows10';technologies='mdm';roleScopeTagIds=@('0')}) -Settings @($choiceBody)
    Assert-True ($policyBody.roleScopeTagIds -is [array] -and $policyBody.roleScopeTagIds.Count -eq 1) 'A single role scope tag must remain a JSON array.'
    Assert-True ($policyBody.settings -is [array] -and $policyBody.settings.Count -eq 1) 'A single Settings Catalog setting must remain a JSON array.'
    Assert-True ($policyBody.settings[0].settingInstance.choiceSettingValue.children -is [array] -and $policyBody.settings[0].settingInstance.choiceSettingValue.children.Count -eq 0) 'An empty Settings Catalog children collection must remain a JSON array.'
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
    if (-not $resolvedTestRoot.StartsWith($tempBase,$pathComparison)) { throw "Refusing unsafe test cleanup path: $resolvedTestRoot" }
    if (Test-Path -LiteralPath $resolvedTestRoot) { Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force }
}
