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
    Assert-True ($withoutSettings.Count -eq 1) 'Setting that lacks required administrator input must not be emitted.'

    $ambiguousSnapshot=Read-Json (Join-Path $fixtures 'settings-catalog-snapshot.json')
    $ambiguousSnapshot.definitions=@($ambiguousSnapshot.definitions)+@($ambiguousSnapshot.definitions[0])
    $ambiguousPath=Join-Path $testRoot 'ambiguous-snapshot.json'
    $ambiguousSnapshot | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $ambiguousPath -Encoding utf8
    $ambiguousFailed=$false
    try { & (Join-Path $repoRoot 'scripts\Build-CISPolicyPack.ps1') @common -SettingsCatalogSnapshotPath $ambiguousPath -OutputPath (Join-Path $testRoot 'ambiguous-pack') } catch { $ambiguousFailed=$true }
    Assert-True $ambiguousFailed 'Ambiguous exact definition matches must fail closed.'

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

    Import-Module (Join-Path $repoRoot 'src\CISPolicyCreator.psm1') -Force -DisableNameChecking
    Assert-True (-not (Get-Command Get-CpcCandidateSettingId -ErrorAction SilentlyContinue)) 'Constructed candidate definition-ID helper must not exist.'
    Assert-True (-not (Test-CpcGraphEndpointSafe 'https://graph.microsoft.com/beta/deviceManagement/configurationPolicies/1/assignments')) 'Assignment endpoint must be rejected.'
    Assert-True (-not (Test-CpcGraphEndpointSafe 'https://graph.microsoft.com:444/beta/deviceManagement/configurationPolicies')) 'Non-default Graph ports must be rejected.'
    Assert-True (-not (Test-CpcGraphEndpointSafe 'https://graph.microsoft.com/beta/deviceManagement/%2e%2e/groups')) 'Dot-segment path escape must be rejected.'
    Assert-True (-not (Test-CpcGraphEndpointSafe 'https://graph.microsoft.com/beta/deviceManagement/%2561ssignments')) 'Double-encoded path components must be rejected.'
    Assert-True (Test-CpcObjectContainsAssignments ([pscustomobject]@{ nested=[pscustomobject]@{ assignments=@() } })) 'Nested assignment payload must be detected.'
    $snapshotFixture=Read-Json (Join-Path $fixtures 'settings-catalog-snapshot.json')
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
