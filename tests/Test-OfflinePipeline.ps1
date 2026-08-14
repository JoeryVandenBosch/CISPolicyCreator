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
