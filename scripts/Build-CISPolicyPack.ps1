[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ExtractionPath,
    [Parameter(Mandatory)][string]$MappingCatalogPath,
    [Parameter(Mandatory)][string]$OutputPath,
    [string]$AdministratorDecisionsPath,
    [string]$SettingsCatalogSnapshotPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repoRoot 'src\CISPolicyCreator.psm1') -Force -DisableNameChecking

function Read-ValidatedJson {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Schema,[Parameter(Mandatory)][string]$Label)
    $resolved = (Resolve-Path -LiteralPath $Path).Path
    $schemaPath = Join-Path $repoRoot "schemas\$Schema"
    $json = Get-Content -LiteralPath $resolved -Raw
    try {
        if (-not ($json | Test-Json -SchemaFile $schemaPath -ErrorAction Stop)) { throw 'Schema validation returned false.' }
    } catch { throw "$Label does not satisfy $Schema`: $($_.Exception.Message)" }
    return [pscustomobject]@{ Path=$resolved; Value=($json | ConvertFrom-Json -Depth 100) }
}

function Get-FileSha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-OptionalProperty($Object,[string]$Name,$Default=$null) {
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    return $property.Value
}

function Write-StableJson([string]$Path,$Value) {
    $json = ConvertTo-Json -InputObject $Value -Depth 100
    $json = ($json -replace "`r`n","`n") + "`n"
    [IO.File]::WriteAllText($Path,$json,[Text.UTF8Encoding]::new($false))
}

function Normalize-CspPath([AllowNull()][string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    return (($Value.Trim() -replace '^\./','').TrimEnd('/')).ToLowerInvariant()
}

function Test-DecisionValue($Definition,$Decision) {
    $value = $Decision.value
    $allowedValues = @(Get-OptionalProperty $Definition 'allowedValues' @())
    switch ([string]$Definition.valueType) {
        'choice' {
            if ($allowedValues.Count -eq 0) { throw "Decision '$($Definition.id)' has no reviewed allowedValues." }
            if (@($allowedValues | Where-Object { $_ -ceq $value }).Count -ne 1) { throw "Decision '$($Definition.id)' value is not an exact reviewed allowed value." }
        }
        'integer' {
            if ($value -isnot [byte] -and $value -isnot [int16] -and $value -isnot [int32] -and $value -isnot [int64]) { throw "Decision '$($Definition.id)' must be an integer." }
            if ($null -ne $Definition.PSObject.Properties['minimum'] -and [int64]$value -lt [int64]$Definition.minimum) { throw "Decision '$($Definition.id)' is below its reviewed minimum." }
            if ($null -ne $Definition.PSObject.Properties['maximum'] -and [int64]$value -gt [int64]$Definition.maximum) { throw "Decision '$($Definition.id)' is above its reviewed maximum." }
            if ($allowedValues.Count -gt 0 -and @($allowedValues | Where-Object { [int64]$_ -eq [int64]$value }).Count -ne 1) { throw "Decision '$($Definition.id)' value is not allowed." }
        }
        'string' {
            if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace($value)) { throw "Decision '$($Definition.id)' must be a non-empty string." }
            if ($allowedValues.Count -gt 0 -and @($allowedValues | Where-Object { $_ -ceq $value }).Count -ne 1) { throw "Decision '$($Definition.id)' value is not allowed." }
        }
        'boolean' { if ($value -isnot [bool]) { throw "Decision '$($Definition.id)' must be boolean." } }
        default { throw "Unsupported decision type '$($Definition.valueType)' for '$($Definition.id)'." }
    }
}

function Resolve-DecisionMarkers($Node,$DecisionById) {
    if ($null -eq $Node -or $Node -is [string] -or $Node -is [ValueType]) { return $Node }
    if ($Node -is [System.Collections.IEnumerable] -and $Node -isnot [System.Collections.IDictionary] -and $Node -isnot [pscustomobject]) {
        return @($Node | ForEach-Object { Resolve-DecisionMarkers $_ $DecisionById })
    }
    [object[]]$properties = if ($Node -is [System.Collections.IDictionary]) { @($Node.Keys | ForEach-Object { [pscustomobject]@{ Name=[string]$_; Value=$Node[$_] } }) } else { @($Node.PSObject.Properties) }
    if ($properties.Count -eq 1 -and $properties[0].Name -ceq '$decision') {
        $id = [string]$properties[0].Value
        if (-not $DecisionById.ContainsKey($id)) { throw "Graph payload requires missing administrator decision '$id'." }
        return $DecisionById[$id].value
    }
    $out = [ordered]@{}
    foreach ($property in $properties) { $out[$property.Name] = Resolve-DecisionMarkers $property.Value $DecisionById }
    return $out
}

function Get-SnapshotSettingDefinition($Resolve,[string]$Context) {
    $definitionMatches=@()
    $reviewedDefinitionId=Get-OptionalProperty $Resolve 'definitionId'
    if($reviewedDefinitionId){
        $definitionMatches=@($snapshot.definitions | Where-Object { [string]$_.id -ceq [string]$reviewedDefinitionId })
    }else{
        $base=Normalize-CspPath (Get-OptionalProperty $Resolve 'baseUri')
        $offset=([string](Get-OptionalProperty $Resolve 'offsetUri')).Trim().ToLowerInvariant()
        if(-not $base -or -not $offset){throw "$Context lacks an exact Settings Catalog resolver."}
        $definitionMatches=@($snapshot.definitions | Where-Object { (Normalize-CspPath $_.baseUri) -eq $base -and ([string]$_.offsetUri).Trim().ToLowerInvariant() -eq $offset })
    }
    if($definitionMatches.Count -ne 1){throw "$Context did not resolve exactly once in the pinned snapshot; matches=$($definitionMatches.Count)."}
    $definition=$definitionMatches[0]
    if([string]$definition.'@odata.type' -cne [string]$Resolve.expectedType){throw "$Context definition type does not match the reviewed expectedType."}
    return $definition
}

function Assert-SnapshotSimpleValue($Definition,[string]$Kind,$RawValue,[string]$Context) {
    if($Kind -eq 'integer'){
        if($RawValue -isnot [byte] -and $RawValue -isnot [int16] -and $RawValue -isnot [int32] -and $RawValue -isnot [int64]){throw "$Context requires an integer value."}
    }elseif($Kind -eq 'string'){
        if($RawValue -isnot [string]){throw "$Context requires a string value."}
    }else{throw "$Context has unsupported simple value kind '$Kind'."}

    $valueDefinition=Get-OptionalProperty $Definition 'valueDefinition'
    if(-not $valueDefinition){return}
    $valueType=[string](Get-OptionalProperty $valueDefinition '@odata.type')
    if($valueType -match 'IntegerSettingValueDefinition$' -and $Kind -ne 'integer'){throw "$Context kind does not match the snapshot integer value definition."}
    if($valueType -match 'StringSettingValueDefinition$' -and $Kind -ne 'string'){throw "$Context kind does not match the snapshot string value definition."}
    if($Kind -eq 'integer'){
        $minimum=Get-OptionalProperty $valueDefinition 'minimumValue'
        $maximum=Get-OptionalProperty $valueDefinition 'maximumValue'
        if($null -ne $minimum -and [int64]$RawValue -lt [int64]$minimum){throw "$Context is below the snapshot minimum."}
        if($null -ne $maximum -and [int64]$RawValue -gt [int64]$maximum){throw "$Context is above the snapshot maximum."}
    }else{
        $minimumLength=Get-OptionalProperty $valueDefinition 'minimumLength'
        $maximumLength=Get-OptionalProperty $valueDefinition 'maximumLength'
        if($null -ne $minimumLength -and ([string]$RawValue).Length -lt [int]$minimumLength){throw "$Context is shorter than the snapshot minimumLength."}
        if($null -ne $maximumLength -and ([string]$RawValue).Length -gt [int]$maximumLength){throw "$Context is longer than the snapshot maximumLength."}
    }
}

function Resolve-CatalogSettingNodes($Nodes,[string]$Context,[int]$Depth) {
    $resolved=[System.Collections.Generic.List[object]]::new()
    $childIds=[System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $index=0
    foreach($node in @($Nodes)){
        $index++
        $child=Resolve-CatalogSettingNode $node "$Context child $index" $Depth
        if(-not $childIds.Add([string]$child.resolve.definitionId)){throw "$Context contains duplicate child definition '$($child.resolve.definitionId)' in one value."}
        $resolved.Add($child) | Out-Null
    }
    return @($resolved)
}

function Get-SnapshotRequiredChildIds($Definition,$SelectedOption=$null) {
    $dependencies=[System.Collections.Generic.List[object]]::new()
    foreach($source in @($Definition,$SelectedOption)){
        if($null -eq $source){continue}
        foreach($dependency in @(Get-OptionalProperty $source 'dependedOnBy' @())){$dependencies.Add($dependency) | Out-Null}
    }
    return @($dependencies | Where-Object {
        (Get-OptionalProperty $_ 'required' $false) -eq $true -and (Get-OptionalProperty $_ 'dependedOnBy')
    } | ForEach-Object { [string](Get-OptionalProperty $_ 'dependedOnBy') } | Sort-Object -Unique)
}

function Assert-SnapshotRequiredChildren($Definition,$SelectedOption,$ResolvedChildren,[string]$Context) {
    $requiredChildIds=@(Get-SnapshotRequiredChildIds $Definition $SelectedOption)
    $actualChildIds=@($ResolvedChildren | ForEach-Object { [string]$_.resolve.definitionId })
    $missingRequiredChildIds=@($requiredChildIds | Where-Object { $actualChildIds -notcontains [string]$_ })
    if($missingRequiredChildIds.Count -gt 0){
        throw "$Context is missing snapshot-required child definition(s): $($missingRequiredChildIds -join ', ')."
    }
}

function Resolve-CatalogSettingNode($Node,[string]$Context,[int]$Depth=0) {
    if($Depth -gt 16){throw "$Context exceeds the maximum nested Settings Catalog depth."}
    if(-not $snapshot){throw "A Settings Catalog snapshot is required to validate $Context."}
    $definition=Get-SnapshotSettingDefinition $Node.resolve $Context
    $definitionType=[string]$definition.'@odata.type'
    $kind=[string]$Node.value.kind

    if($definitionType -match 'ChoiceSettingDefinition$'){
        if($kind -ne 'choice'){throw "$Context value kind does not match its choice definition."}
    }elseif($definitionType -match 'SimpleSettingCollectionDefinition$'){
        if($kind -notin @('integer-collection','string-collection')){throw "$Context value kind does not match its simple collection definition."}
    }elseif($definitionType -match 'SimpleSettingDefinition$'){
        if($kind -notin @('integer','string')){throw "$Context value kind does not match its simple definition."}
    }elseif($definitionType -match 'SettingGroupCollectionDefinition$'){
        if($kind -ne 'group-collection'){throw "$Context value kind does not match its group collection definition."}
    }else{throw "$Context uses unsupported definition type '$definitionType'."}

    $value=$Node.value
    $decisionRef=Get-OptionalProperty $value 'decisionRef'
    if($decisionRef -and $kind -notin @('choice','integer','string')){throw "$Context cannot use an administrator decision for collection or group values."}
    $allowedValueProperties=switch($kind){
        'choice' {@('kind','optionId','children','decisionRef')}
        {$_ -in @('integer','string')} {@('kind','value','decisionRef')}
        {$_ -in @('integer-collection','string-collection')} {@('kind','values','decisionRef')}
        'group-collection' {@('kind','items','decisionRef')}
        default {@('kind')}
    }
    $unexpectedValueProperties=@($value.PSObject.Properties.Name | Where-Object { $allowedValueProperties -notcontains [string]$_ })
    if($unexpectedValueProperties.Count -gt 0){throw "$Context value kind '$kind' contains incompatible properties: $($unexpectedValueProperties -join ', ')."}
    $outputValue=[ordered]@{kind=$kind}

    switch($kind){
        'choice' {
            $resolvedValue=if($decisionRef){
                if(-not $decisionById.ContainsKey([string]$decisionRef)){throw "$Context requires missing decision '$decisionRef'."}
                $decisionById[[string]$decisionRef].value
            }else{Get-OptionalProperty $value 'optionId'}
            if(-not $resolvedValue){throw "$Context lacks an exact optionId."}
            $options=@($definition.options | Where-Object { [string]$_.itemId -ceq [string]$resolvedValue })
            if($options.Count -ne 1){throw "$Context optionId '$resolvedValue' was not uniquely present in the pinned snapshot."}
            $outputValue.optionId=[string]$resolvedValue
            $children=@(Get-OptionalProperty $value 'children' @())
            [object[]]$resolvedChildren=@()
            if($children.Count -gt 0){$resolvedChildren=@(Resolve-CatalogSettingNodes $children $Context ($Depth+1))}
            Assert-SnapshotRequiredChildren $definition $options[0] $resolvedChildren "$Context choice '$resolvedValue'"
            if($resolvedChildren.Count -gt 0){$outputValue.children=$resolvedChildren}
        }
        {$_ -in @('integer','string')} {
            $resolvedValue=if($decisionRef){
                if(-not $decisionById.ContainsKey([string]$decisionRef)){throw "$Context requires missing decision '$decisionRef'."}
                $decisionById[[string]$decisionRef].value
            }else{Get-OptionalProperty $value 'value'}
            if($null -eq $resolvedValue){throw "$Context lacks a simple value."}
            Assert-SnapshotSimpleValue $definition $kind $resolvedValue $Context
            $outputValue.value=if($kind -eq 'integer'){[int64]$resolvedValue}else{[string]$resolvedValue}
        }
        {$_ -in @('integer-collection','string-collection')} {
            $elementKind=if($kind -eq 'integer-collection'){'integer'}else{'string'}
            $values=@(Get-OptionalProperty $value 'values' @())
            if($values.Count -eq 0){throw "$Context requires at least one collection value."}
            $outputValues=[System.Collections.Generic.List[object]]::new()
            $valueIndex=0
            foreach($itemValue in $values){
                $valueIndex++
                Assert-SnapshotSimpleValue $definition $elementKind $itemValue "$Context value $valueIndex"
                $normalizedValue=if($elementKind -eq 'integer'){[int64]$itemValue}else{[string]$itemValue}
                $outputValues.Add($normalizedValue) | Out-Null
            }
            $outputValue.values=@($outputValues)
        }
        'group-collection' {
            $items=@(Get-OptionalProperty $value 'items' @())
            if($items.Count -eq 0){throw "$Context requires at least one group item."}
            $outputItems=[System.Collections.Generic.List[object]]::new()
            $itemIndex=0
            foreach($item in $items){
                $itemIndex++
                $children=@(Get-OptionalProperty $item 'children' @())
                if($children.Count -eq 0){throw "$Context group item $itemIndex requires at least one child."}
                $resolvedChildren=@(Resolve-CatalogSettingNodes $children "$Context group item $itemIndex" ($Depth+1))
                Assert-SnapshotRequiredChildren $definition $null $resolvedChildren "$Context group item $itemIndex"
                $outputItems.Add([pscustomobject][ordered]@{children=$resolvedChildren}) | Out-Null
            }
            $outputValue.items=@($outputItems)
        }
        default {throw "$Context has unsupported value kind '$kind'."}
    }

    $resolve=[ordered]@{
        definitionId=[string]$definition.id
        baseUri=(Get-OptionalProperty $definition 'baseUri')
        offsetUri=(Get-OptionalProperty $definition 'offsetUri')
        expectedType=$definitionType
    }
    return [pscustomobject][ordered]@{displayName=[string]$Node.displayName;resolve=[pscustomobject]$resolve;value=[pscustomobject]$outputValue}
}

$extractionInput = Read-ValidatedJson $ExtractionPath 'extraction.schema.json' 'Extraction'
$catalogInput = Read-ValidatedJson $MappingCatalogPath 'mapping-catalog.schema.json' 'Mapping catalog'
$extraction = $extractionInput.Value
$catalog = $catalogInput.Value

if ([string]$extraction.benchmark.id -cne [string]$catalog.benchmark.id -or [string]$extraction.benchmark.version -cne [string]$catalog.benchmark.version) {
    throw 'Extraction benchmark identity does not exactly match the mapping catalog.'
}
if ((@($extraction.benchmark.requiredTextMatched) -join '|') -cne (@($catalog.sourceDocument.requiredText) -join '|')) {
    throw 'Extraction source-eligibility evidence does not exactly match the mapping catalog.'
}
if (@($extraction.recommendations).Count -ne [int]$catalog.benchmark.expectedRecommendationCount) {
    throw "Extraction count does not match the reviewed expectedRecommendationCount. Extracted=$(@($extraction.recommendations).Count); expected=$($catalog.benchmark.expectedRecommendationCount)."
}
if (@($catalog.recommendations).Count -ne [int]$catalog.benchmark.expectedRecommendationCount) {
    throw "Mapping catalog must explicitly classify every expected recommendation. Catalog=$(@($catalog.recommendations).Count); expected=$($catalog.benchmark.expectedRecommendationCount)."
}

$decisions = $null
$decisionHash = $null
if ($AdministratorDecisionsPath) {
    $decisionInput = Read-ValidatedJson $AdministratorDecisionsPath 'administrator-decisions.schema.json' 'Administrator decisions'
    $decisions = $decisionInput.Value
    $decisionHash = Get-FileSha256 $decisionInput.Path
    if ([string]$decisions.catalogId -cne [string]$catalog.id -or [string]$decisions.catalogVersion -cne [string]$catalog.version) { throw 'Administrator decisions target a different mapping catalog.' }
}

$snapshot = $null
$snapshotHash = $null
if ($SettingsCatalogSnapshotPath) {
    $snapshotInput = Read-ValidatedJson $SettingsCatalogSnapshotPath 'settings-catalog-snapshot.schema.json' 'Settings Catalog snapshot'
    $snapshot = $snapshotInput.Value
    $snapshotHash = Get-FileSha256 $snapshotInput.Path
    if ([int]$snapshot.retrieval.definitionCount -ne @($snapshot.definitions).Count) { throw 'Settings Catalog snapshot retrieval count does not match its definitions array.' }
    $snapshotIds=@($snapshot.definitions | ForEach-Object { [string]$_.id })
    if (@($snapshotIds | Sort-Object -Unique).Count -ne $snapshotIds.Count) { throw 'Settings Catalog snapshot contains duplicate definition IDs.' }
}

$extractedById = @{}
foreach ($recommendation in @($extraction.recommendations)) {
    $id = [string]$recommendation.recommendationId
    if ($extractedById.ContainsKey($id)) { throw "Duplicate extracted recommendation '$id'." }
    $extractedById[$id] = $recommendation
}
$catalogById = @{}
foreach ($recommendation in @($catalog.recommendations)) {
    $id = [string]$recommendation.recommendationId
    if ($catalogById.ContainsKey($id)) { throw "Duplicate catalog recommendation '$id'." }
    if (-not $extractedById.ContainsKey($id)) { throw "Mapping catalog references recommendation '$id' that is absent from the supplied PDF extraction." }
    if ([string]$recommendation.cisAssessmentMethod -cne [string]$extractedById[$id].cisAssessmentMethod) { throw "CIS assessment method mismatch for recommendation '$id'." }
    if ((@($recommendation.profiles) -join '|') -cne (@($extractedById[$id].profiles) -join '|')) { throw "Profile mismatch for recommendation '$id'." }
    $catalogById[$id] = $recommendation
}

$inputDefinitions = @{}
foreach ($definition in @($catalog.administratorInputs)) {
    if ($inputDefinitions.ContainsKey([string]$definition.id)) { throw "Duplicate administrator input definition '$($definition.id)'." }
    if (-not $catalogById.ContainsKey([string]$definition.recommendationId)) { throw "Administrator input '$($definition.id)' references unknown recommendation '$($definition.recommendationId)'." }
    $inputDefinitions[[string]$definition.id] = $definition
}
$requiredDecisionRefs=@($catalog.recommendations | Where-Object mappingStatus -eq 'requires-input' | ForEach-Object { [string]$_.decisionRef } | Sort-Object -Unique)
$unusedInputDefinitions=@($inputDefinitions.Keys | Where-Object { $requiredDecisionRefs -notcontains [string]$_ })
if ($unusedInputDefinitions.Count -gt 0) { throw "Administrator input definitions are not referenced by requires-input recommendations: $($unusedInputDefinitions -join ', ')." }
$decisionById = @{}
if ($decisions) {
    foreach ($decision in @($decisions.decisions)) {
        $id = [string]$decision.id
        if ($decisionById.ContainsKey($id)) { throw "Duplicate administrator decision '$id'." }
        if (-not $inputDefinitions.ContainsKey($id)) { throw "Administrator decision '$id' is not declared by the mapping catalog." }
        if ($requiredDecisionRefs -notcontains $id) { throw "Administrator decision '$id' is not required by the mapping catalog." }
        Test-DecisionValue $inputDefinitions[$id] $decision
        $decisionById[$id] = $decision
    }
}

$finalRecommendations = [System.Collections.Generic.List[object]]::new()
$finalById = @{}
foreach ($extracted in @($extraction.recommendations)) {
    $id = [string]$extracted.recommendationId
    if (-not $catalogById.ContainsKey($id)) { throw "Mapping catalog does not explicitly classify extracted recommendation '$id'." }
    $mapped = $catalogById[$id]
    $status = [string]$mapped.mappingStatus
    $catalogStatus = $status
    $decisionRef = if ($null -ne $mapped.PSObject.Properties['decisionRef']) { [string]$mapped.decisionRef } else { $null }
    if ($status -eq 'requires-input') {
        if (-not $decisionRef -or -not $inputDefinitions.ContainsKey($decisionRef)) { throw "Recommendation '$id' requires input but has no valid decisionRef." }
        if ($decisionById.ContainsKey($decisionRef)) { $status = 'mapped' }
    } elseif ($decisionRef) { throw "Recommendation '$id' has decisionRef but mappingStatus is '$status'." }
    $record = [ordered]@{
        recommendationId=$id; profiles=@($extracted.profiles); cisAssessmentMethod=[string]$extracted.cisAssessmentMethod
        mappingStatus=$status; implementationType=(Get-OptionalProperty $mapped 'implementationType'); implementationRefs=@($mapped.implementationRefs); notes=(Get-OptionalProperty $mapped 'notes')
    }
    if ($catalogStatus -eq 'requires-input') { $record.catalogMappingStatus='requires-input'; $record.decisionRef=$decisionRef }
    $object = [pscustomobject]$record
    $finalRecommendations.Add($object)
    $finalById[$id] = $object
}

$policyById = @{}
foreach ($policy in @($catalog.settingsCatalogPolicies)) {
    if ($policyById.ContainsKey([string]$policy.id)) { throw "Duplicate Settings Catalog policy ID '$($policy.id)'." }
    $policyById[[string]$policy.id] = $policy
}
$generatedSettings = [System.Collections.Generic.List[object]]::new()
$probeCandidates = [System.Collections.Generic.List[object]]::new()
$settingsByPolicy = @{}
$settingKeys=[System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($setting in @($catalog.settingsCatalogSettings)) {
    $id = [string]$setting.recommendationId
    if (-not $finalById.ContainsKey($id)) { throw "Settings Catalog entry references unknown recommendation '$id'." }
    if ([string]$finalById[$id].mappingStatus -ne 'mapped') { continue }
    if (-not $policyById.ContainsKey([string]$setting.policyId)) { throw "Settings Catalog entry '$id' references unknown policy '$($setting.policyId)'." }
    if (-not $snapshot) { throw "A Settings Catalog snapshot is required to validate mapped setting '$id'." }

    $resolvedNode=Resolve-CatalogSettingNode $setting "Settings Catalog entry '$id'" 0
    $settingKey=([string]$setting.policyId)+"`n"+([string]$resolvedNode.resolve.definitionId)
    if (-not $settingKeys.Add($settingKey)) { throw "Policy '$($setting.policyId)' contains multiple mappings for definition '$($resolvedNode.resolve.definitionId)'." }
    $generated = [pscustomobject][ordered]@{
        recommendationId=$id; mappingStatus='mapped'; policy=[string]$policyById[[string]$setting.policyId].name
        displayName=[string]$resolvedNode.displayName; profiles=@($setting.profiles); resolve=$resolvedNode.resolve; value=$resolvedNode.value
    }
    $generatedSettings.Add($generated)
    $valueKind=[string]$resolvedNode.value.kind
    $childrenProperty=$resolvedNode.value.PSObject.Properties['children']
    $hasChildren=$childrenProperty -and @($childrenProperty.Value).Count -gt 0
    if($valueKind -in @('choice','integer','string') -and -not $hasChildren){
        $policy=$policyById[[string]$setting.policyId]
        $probeCandidates.Add([pscustomobject][ordered]@{
            SortKey=([string]$id)+'|'+([string]$setting.policyId)+'|'+([string]$resolvedNode.resolve.definitionId)
            Probe=[pscustomobject][ordered]@{
                recommendationId=$id
                policy=[string]$policy.name
                displayName=[string]$resolvedNode.displayName
                platforms=[string]$policy.platforms
                technologies=[string]$policy.technologies
                resolve=$resolvedNode.resolve
                value=$resolvedNode.value
            }
        }) | Out-Null
    }
    if (-not $settingsByPolicy.ContainsKey([string]$setting.policyId)) { $settingsByPolicy[[string]$setting.policyId] = [System.Collections.Generic.List[string]]::new() }
    $settingsByPolicy[[string]$setting.policyId].Add($id)
}

$generatedGraphObjects = [System.Collections.Generic.List[object]]::new()
foreach ($graphObject in @($catalog.graphObjects)) {
    $ids = @($graphObject.recommendationIds | ForEach-Object { [string]$_ })
    foreach ($id in $ids) { if (-not $finalById.ContainsKey($id)) { throw "Graph object '$($graphObject.name)' references unknown recommendation '$id'." } }
    if (@($ids | Where-Object { [string]$finalById[$_].mappingStatus -ne 'mapped' }).Count -gt 0) { continue }
    $contractId=[string]$graphObject.contractId
    $contractInfo=Get-CpcGraphObjectContract -ContractId $contractId -RepoRoot $repoRoot
    $generatedGraphObject=[pscustomobject][ordered]@{
        name=[string]$graphObject.name; mappingStatus='mapped'; recommendationIds=$ids; profiles=@($graphObject.profiles)
        contractId=$contractId; contractSha256=[string]$contractInfo.Sha256
        endpoint=[string]$graphObject.endpoint; listEndpoint=(Get-OptionalProperty $graphObject 'listEndpoint'); nameProperty=(Get-OptionalProperty $graphObject 'nameProperty')
        payload=(Resolve-DecisionMarkers $graphObject.payload $decisionById)
    }
    Assert-CpcGraphObjectMatchesContract -GraphObject $generatedGraphObject -Contract $contractInfo.Contract
    $generatedGraphObjects.Add($generatedGraphObject)
}

$outputRoot = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
if (Test-Path -LiteralPath $outputRoot) { throw "OutputPath already exists: $outputRoot" }
$outputParent=Split-Path -Parent $outputRoot
if(-not $outputParent){$outputParent=(Get-Location).Path}
if(-not (Test-Path -LiteralPath $outputParent)){New-Item -ItemType Directory -Path $outputParent -Force | Out-Null}
$buildRoot=Join-Path $outputParent ('.cpc-build-'+[guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path (Join-Path $buildRoot 'policies\settings-catalog') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $buildRoot 'spec') -Force | Out-Null
    $generatedFileNames=[System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($policyId in @($settingsByPolicy.Keys | Sort-Object)) {
        $policy = $policyById[$policyId]
        $safeName = $policyId -replace '[^a-zA-Z0-9._-]','-'
        if (-not $generatedFileNames.Add($safeName)) { throw "Settings Catalog policy IDs collide after filename sanitization: $policyId" }
        $bundle = [ordered]@{
            mappingStatus='mapped'; recommendationIds=@($settingsByPolicy[$policyId] | Sort-Object -Unique); profiles=@($policy.profiles)
            policy=[ordered]@{ name=[string]$policy.name; description=[string]$policy.description; platforms=[string]$policy.platforms; technologies=[string]$policy.technologies; roleScopeTagIds=@(Get-OptionalProperty $policy 'roleScopeTagIds' @('0')) }
            settings=@()
        }
        Write-StableJson (Join-Path $buildRoot "policies\settings-catalog\$safeName.json") $bundle
    }
    Write-StableJson (Join-Path $buildRoot 'spec\recommendations.json') @($finalRecommendations)
    Write-StableJson (Join-Path $buildRoot 'spec\settings-catalog.json') @($generatedSettings)
    Write-StableJson (Join-Path $buildRoot 'spec\graph-objects.json') @($generatedGraphObjects)
    $settingsCatalogProbe=$null
    if($probeCandidates.Count -gt 0){$settingsCatalogProbe=($probeCandidates | Sort-Object SortKey | Select-Object -First 1).Probe}
    $manifest = [ordered]@{
        schemaVersion='2.0'; id=[string]$catalog.pack.id; name=[string]$catalog.pack.name; version=[string]$catalog.pack.version
        benchmarkScope='microsoft-intune'; sourceDocumentIncluded=$false
        source=[ordered]@{ fileName=[string]$extraction.source.fileName; sha256=[string]$extraction.source.sha256; pageCount=[int]$extraction.source.pageCount }
        build=[ordered]@{
            toolVersion='0.2.0'; extractorVersion=[string]$extraction.tool.extractorVersion; pdfParser=[string]$extraction.tool.pdfParser; pdfParserVersion=[string]$extraction.tool.pdfParserVersion
            mappingCatalogId=[string]$catalog.id; mappingCatalogVersion=[string]$catalog.version
            mappingCatalogSha256=(Get-FileSha256 $catalogInput.Path); administratorDecisionsSha256=$decisionHash; settingsCatalogSnapshotSha256=$snapshotHash
        }
        recommendationsSpec='spec/recommendations.json'; settingsCatalogPolicyDirectory='policies/settings-catalog'
        settingsCatalogSpec='spec/settings-catalog.json'; graphObjects='spec/graph-objects.json'; settingsCatalogProbe=$settingsCatalogProbe
    }
    Write-StableJson (Join-Path $buildRoot 'manifest.json') $manifest
    $validation = & (Join-Path $PSScriptRoot 'Test-CISPolicyPack.ps1') -PackRoot $buildRoot -PassThru
    if (-not $validation.IsValid) { throw "Generated pack failed validation:`n$($validation.Issues -join "`n")" }
    # Build and destination share a parent, so publication is atomic and refuses a raced destination.
    [IO.Directory]::Move($buildRoot,$outputRoot)
    Write-Host "Generated validated policy pack: $outputRoot"
} finally {
    if(Test-Path -LiteralPath $buildRoot){Remove-Item -LiteralPath $buildRoot -Recurse -Force}
}
