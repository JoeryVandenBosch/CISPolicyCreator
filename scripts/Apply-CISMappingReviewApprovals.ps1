[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ExtractionPath,
    [Parameter(Mandatory)][string]$MappingCatalogPath,
    [Parameter(Mandatory)][string]$ReviewWorklistPath,
    [Parameter(Mandatory)][string]$ApprovalsPath,
    [Parameter(Mandatory)][string]$SettingsCatalogSnapshotPath,
    [Parameter(Mandatory)][string]$ReferencePackRoot,
    [Parameter(Mandatory)][string]$OutputPath
)

$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$repoRoot=Split-Path -Parent $PSScriptRoot
$pathComparison=if($IsWindows){[StringComparison]::OrdinalIgnoreCase}else{[StringComparison]::Ordinal}
$outputFull=[IO.Path]::GetFullPath($OutputPath)
if(Test-Path -LiteralPath $outputFull){throw "OutputPath already exists: $outputFull"}
if(-not ([IO.Path]::GetFullPath($ApprovalsPath)).EndsWith('.private-approvals.json',[StringComparison]::Ordinal)){throw 'ApprovalsPath must end with the exact lowercase suffix .private-approvals.json.'}

function Read-ValidatedJson([string]$Path,[string]$SchemaName,[string]$Label) {
    $resolved=(Resolve-Path -LiteralPath $Path).Path
    $json=Get-Content -LiteralPath $resolved -Raw
    $schemaPath=Join-Path $repoRoot "schemas\$SchemaName"
    if(-not ($json|Test-Json -SchemaFile $schemaPath -ErrorAction Stop)){throw "$Label does not satisfy $SchemaName."}
    return [pscustomobject]@{Path=$resolved;Value=($json|ConvertFrom-Json -Depth 100)}
}

function Get-OptionalProperty($Object,[string]$Name,$Default=$null) {
    if($null -eq $Object){return $Default}
    $property=$Object.PSObject.Properties[$Name]
    if($null -eq $property){return $Default}
    return $property.Value
}

function Get-Sha256([string]$Path){return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}

function Normalize-CspPath([AllowNull()][string]$Value) {
    if([string]::IsNullOrWhiteSpace($Value)){return ''}
    return (($Value.Trim()-replace '^\./','').TrimEnd('/')).ToLowerInvariant()
}

function Get-NullableString($Object,[string]$Name) {
    $value=Get-OptionalProperty $Object $Name
    if($null -eq $value){return $null}
    return [string]$value
}

function Test-ExactArray($Left,$Right) {
    $leftArray=@($Left);$rightArray=@($Right)
    if($leftArray.Count -ne $rightArray.Count){return $false}
    for($i=0;$i -lt $leftArray.Count;$i++){if([string]$leftArray[$i] -cne [string]$rightArray[$i]){return $false}}
    return $true
}

function Assert-PolicyEquivalent($Expected,$Actual,[string]$Context) {
    foreach($name in @('id','name','description','platforms','technologies')){
        if([string](Get-OptionalProperty $Expected $name) -cne [string](Get-OptionalProperty $Actual $name)){throw "$Context policy property '$name' does not exactly match."}
    }
    if(-not (Test-ExactArray (Get-OptionalProperty $Expected 'profiles' @()) (Get-OptionalProperty $Actual 'profiles' @()))){throw "$Context policy profiles do not exactly match."}
    $expectedTags=@(Get-OptionalProperty $Expected 'roleScopeTagIds' @('0'))
    $actualTags=@(Get-OptionalProperty $Actual 'roleScopeTagIds' @('0'))
    if(-not (Test-ExactArray $expectedTags $actualTags)){throw "$Context policy roleScopeTagIds do not exactly match."}
}

function Assert-ReferenceSimpleValue($Definition,$SettingValue,[string]$Context) {
    if(-not $SettingValue){throw "$Context is missing its simple value."}
    $valueType=[string](Get-OptionalProperty $SettingValue '@odata.type')
    $value=Get-OptionalProperty $SettingValue 'value'
    $definitionValue=Get-OptionalProperty $Definition 'valueDefinition'
    $definitionValueType=[string](Get-OptionalProperty $definitionValue '@odata.type')
    if($valueType -ceq '#microsoft.graph.deviceManagementConfigurationIntegerSettingValue'){
        if($value -isnot [byte] -and $value -isnot [int16] -and $value -isnot [int32] -and $value -isnot [int64]){throw "$Context does not contain an integer value."}
        if($definitionValueType -and $definitionValueType -cne '#microsoft.graph.deviceManagementConfigurationIntegerSettingValueDefinition'){throw "$Context contradicts the snapshot value type."}
        $minimum=Get-OptionalProperty $definitionValue 'minimumValue'
        $maximum=Get-OptionalProperty $definitionValue 'maximumValue'
        if($null -ne $minimum -and [int64]$value -lt [int64]$minimum){throw "$Context is below the snapshot minimum."}
        if($null -ne $maximum -and [int64]$value -gt [int64]$maximum){throw "$Context is above the snapshot maximum."}
        return [pscustomobject][ordered]@{kind='integer';value=[int64]$value}
    }
    if($valueType -ceq '#microsoft.graph.deviceManagementConfigurationStringSettingValue'){
        if($value -isnot [string]){throw "$Context does not contain a string value."}
        if($definitionValueType -and $definitionValueType -cne '#microsoft.graph.deviceManagementConfigurationStringSettingValueDefinition'){throw "$Context contradicts the snapshot value type."}
        $minimumLength=Get-OptionalProperty $definitionValue 'minimumLength'
        $maximumLength=Get-OptionalProperty $definitionValue 'maximumLength'
        if($null -ne $minimumLength -and ([string]$value).Length -lt [int]$minimumLength){throw "$Context is shorter than the snapshot minimumLength."}
        if($null -ne $maximumLength -and ([string]$value).Length -gt [int]$maximumLength){throw "$Context is longer than the snapshot maximumLength."}
        return [pscustomobject][ordered]@{kind='string';value=[string]$value}
    }
    throw "$Context uses unsupported simple value type '$valueType'."
}

$extractionInput=Read-ValidatedJson $ExtractionPath 'extraction.schema.json' 'Private extraction'
$catalogInput=Read-ValidatedJson $MappingCatalogPath 'mapping-catalog.schema.json' 'Mapping catalog'
$worklistInput=Read-ValidatedJson $ReviewWorklistPath 'private-mapping-review.schema.json' 'Private mapping review worklist'
$approvalsInput=Read-ValidatedJson $ApprovalsPath 'mapping-review-approvals.schema.json' 'Private mapping review approvals'
$snapshotInput=Read-ValidatedJson $SettingsCatalogSnapshotPath 'settings-catalog-snapshot.schema.json' 'Settings Catalog snapshot'
$extraction=$extractionInput.Value
$catalog=$catalogInput.Value
$worklist=$worklistInput.Value
$approvals=$approvalsInput.Value
$snapshot=$snapshotInput.Value

if([bool]$worklist.mappingChangesMade){throw 'The review worklist must be candidate-only.'}
if((Get-Sha256 $extractionInput.Path) -cne [string]$worklist.source.extractionSha256){throw 'Private extraction hash does not match the reviewed worklist evidence.'}
if([string]$extraction.benchmark.id -cne [string]$worklist.benchmark.id -or [string]$extraction.benchmark.version -cne [string]$worklist.benchmark.version){throw 'Private extraction and review worklist target different benchmarks.'}
if([string]$worklist.benchmark.id -cne [string]$catalog.benchmark.id -or [string]$worklist.benchmark.version -cne [string]$catalog.benchmark.version){throw 'Review worklist and mapping catalog target different benchmarks.'}
if((Get-Sha256 $catalogInput.Path) -cne [string]$approvals.catalog.sha256){throw 'Approval catalog hash does not match MappingCatalogPath.'}
if([string]$catalog.id -cne [string]$approvals.catalog.id -or [string]$catalog.version -cne [string]$approvals.catalog.version){throw 'Approvals target a different mapping catalog identity or version.'}
if((Get-Sha256 $worklistInput.Path) -cne [string]$approvals.reviewWorklist.sha256){throw 'Approval worklist hash does not match ReviewWorklistPath.'}
$snapshotHash=Get-Sha256 $snapshotInput.Path
if($snapshotHash -cne [string]$worklist.source.settingsCatalogSnapshotSha256 -or $snapshotHash -cne [string]$approvals.reviewWorklist.settingsCatalogSnapshotSha256){throw 'Pinned Settings Catalog snapshot hash does not match the reviewed evidence.'}
if([int]$snapshot.retrieval.definitionCount -ne @($snapshot.definitions).Count){throw 'Settings Catalog snapshot retrieval count does not match its definitions array.'}
if([string]$approvals.output.catalogVersion -ceq [string]$catalog.version){throw 'Approved output catalogVersion must differ from the input catalog version.'}
if([string]$approvals.output.packVersion -ceq [string]$catalog.pack.version){throw 'Approved output packVersion must differ from the input pack version.'}

$definitionById=[System.Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
$definitionIdsIgnoreCase=[System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach($definition in @($snapshot.definitions)){
    $definitionId=[string]$definition.id
    if(-not $definitionIdsIgnoreCase.Add($definitionId)){throw "Snapshot contains duplicate or case-conflicting definition '$definitionId'."}
    $definitionById.Add($definitionId,$definition)
}

$referenceRoot=(Resolve-Path -LiteralPath $ReferencePackRoot).Path
$referenceRootPrefix=$referenceRoot.TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
$referenceByPath=[System.Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
foreach($record in @($worklist.source.referenceFiles)){
    $relativePath=[string]$record.path
    if([IO.Path]::IsPathRooted($relativePath)){throw "Reference evidence path is rooted: $relativePath"}
    $segments=@($relativePath -split '[\\/]')
    if($segments.Count -eq 0 -or @($segments|Where-Object{$_ -in @('','.', '..')}).Count -gt 0){throw "Reference evidence path is unsafe: $relativePath"}
    $fullPath=[IO.Path]::GetFullPath((Join-Path $referenceRoot ($segments -join [IO.Path]::DirectorySeparatorChar)))
    if(-not $fullPath.StartsWith($referenceRootPrefix,$pathComparison)){throw "Reference evidence escapes ReferencePackRoot: $relativePath"}
    if(-not (Test-Path -LiteralPath $fullPath -PathType Leaf)){throw "Reference evidence file is missing: $relativePath"}
    if((Get-Sha256 $fullPath) -cne [string]$record.sha256){throw "Reference evidence hash mismatch: $relativePath"}
    if($referenceByPath.ContainsKey($relativePath)){throw "Duplicate reference evidence path: $relativePath"}
    $referenceByPath.Add($relativePath,[pscustomobject]@{Path=$fullPath;Document=$null})
}

function Convert-ReferenceInstance {
    param(
        [Parameter(Mandatory)]$Instance,
        [Parameter(Mandatory)][string]$SourceFile,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$EvidenceByPath,
        [int]$Depth=0
    )
    if($Depth -gt 32){throw "$SourceFile $Path exceeds the maximum reference traversal depth."}
    $definitionId=[string](Get-OptionalProperty $Instance 'settingDefinitionId')
    if(-not $definitionId){throw "$SourceFile $Path is missing settingDefinitionId."}
    if(-not $definitionById.ContainsKey($definitionId)){throw "$SourceFile $Path references definition '$definitionId' absent from the pinned snapshot."}
    $definition=$definitionById[$definitionId]
    $instanceType=[string](Get-OptionalProperty $Instance '@odata.type')
    $definitionType=[string]$definition.'@odata.type'
    $catalogValue=$null
    $observedValue=$null

    if($instanceType -ceq '#microsoft.graph.deviceManagementConfigurationChoiceSettingInstance'){
        if($definitionType -cne '#microsoft.graph.deviceManagementConfigurationChoiceSettingDefinition'){throw "$SourceFile $Path instance type contradicts definition '$definitionId'."}
        $choiceValue=Get-OptionalProperty $Instance 'choiceSettingValue'
        if([string](Get-OptionalProperty $choiceValue '@odata.type') -cne '#microsoft.graph.deviceManagementConfigurationChoiceSettingValue'){throw "$SourceFile $Path has an invalid choice value type."}
        $optionId=[string](Get-OptionalProperty $choiceValue 'value')
        if(-not $optionId -or @($definition.options|Where-Object{[string]$_.itemId -ceq $optionId}).Count -ne 1){throw "$SourceFile $Path option '$optionId' is not uniquely present in definition '$definitionId'."}
        $catalogValue=[ordered]@{kind='choice';optionId=$optionId}
        $observedValue=[pscustomobject][ordered]@{kind='choice';optionId=$optionId}
        $children=@(Get-OptionalProperty $choiceValue 'children' @())
        if($children.Count -gt 0){
            $childIds=[System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            $converted=[System.Collections.Generic.List[object]]::new();$childIndex=0
            foreach($child in $children){
                $childIndex++;$childId=[string](Get-OptionalProperty $child 'settingDefinitionId')
                if(-not $childIds.Add($childId)){throw "$SourceFile $Path contains duplicate choice child definition '$childId'."}
                $converted.Add((Convert-ReferenceInstance $child $SourceFile "$Path/choice.children[$childIndex]" $EvidenceByPath ($Depth+1)))|Out-Null
            }
            $catalogValue.children=@($converted)
        }
    }elseif($instanceType -ceq '#microsoft.graph.deviceManagementConfigurationSimpleSettingCollectionInstance'){
        if($definitionType -cne '#microsoft.graph.deviceManagementConfigurationSimpleSettingCollectionDefinition'){throw "$SourceFile $Path instance type contradicts definition '$definitionId'."}
        $rawValues=@(Get-OptionalProperty $Instance 'simpleSettingCollectionValue' @())
        if($rawValues.Count -eq 0){throw "$SourceFile $Path contains an empty simple collection."}
        $validated=[System.Collections.Generic.List[object]]::new();$valueIndex=0
        foreach($rawValue in $rawValues){$valueIndex++;$validated.Add((Assert-ReferenceSimpleValue $definition $rawValue "$SourceFile $Path value $valueIndex"))|Out-Null}
        $kinds=@($validated.kind|Sort-Object -Unique)
        if($kinds.Count -ne 1){throw "$SourceFile $Path mixes simple collection value types."}
        $kind=[string]$kinds[0]+'-collection'
        $catalogValue=[ordered]@{kind=$kind;values=@($validated.value)}
        $observedValue=[pscustomobject][ordered]@{kind=$kind;values=@($validated.value)}
    }elseif($instanceType -ceq '#microsoft.graph.deviceManagementConfigurationSimpleSettingInstance'){
        if($definitionType -cne '#microsoft.graph.deviceManagementConfigurationSimpleSettingDefinition'){throw "$SourceFile $Path instance type contradicts definition '$definitionId'."}
        $simple=Assert-ReferenceSimpleValue $definition (Get-OptionalProperty $Instance 'simpleSettingValue') "$SourceFile $Path"
        $catalogValue=[ordered]@{kind=[string]$simple.kind;value=$simple.value}
        $observedValue=$simple
    }elseif($instanceType -ceq '#microsoft.graph.deviceManagementConfigurationGroupSettingCollectionInstance'){
        if($definitionType -cne '#microsoft.graph.deviceManagementConfigurationSettingGroupCollectionDefinition'){throw "$SourceFile $Path instance type contradicts definition '$definitionId'."}
        $groups=@(Get-OptionalProperty $Instance 'groupSettingCollectionValue' @())
        if($groups.Count -eq 0){throw "$SourceFile $Path contains an empty group collection."}
        $items=[System.Collections.Generic.List[object]]::new();$groupIndex=0
        foreach($group in $groups){
            $groupIndex++
            if([string](Get-OptionalProperty $group '@odata.type') -cne '#microsoft.graph.deviceManagementConfigurationGroupSettingValue'){throw "$SourceFile $Path group $groupIndex has an invalid group value type."}
            $children=@(Get-OptionalProperty $group 'children' @())
            if($children.Count -eq 0){throw "$SourceFile $Path group $groupIndex contains no children."}
            $childIds=[System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            $converted=[System.Collections.Generic.List[object]]::new();$childIndex=0
            foreach($child in $children){
                $childIndex++;$childId=[string](Get-OptionalProperty $child 'settingDefinitionId')
                if(-not $childIds.Add($childId)){throw "$SourceFile $Path group $groupIndex contains duplicate child definition '$childId'."}
                $converted.Add((Convert-ReferenceInstance $child $SourceFile "$Path/groups[$groupIndex].children[$childIndex]" $EvidenceByPath ($Depth+1)))|Out-Null
            }
            $items.Add([pscustomobject][ordered]@{children=@($converted)})|Out-Null
        }
        $catalogValue=[ordered]@{kind='group-collection';items=@($items)}
        $observedValue=[pscustomobject][ordered]@{kind='group-collection';itemCount=$groups.Count}
    }else{throw "$SourceFile $Path uses unsupported instance type '$instanceType'."}

    if($EvidenceByPath.ContainsKey($Path)){throw "$SourceFile contains duplicate evidence path '$Path'."}
    $EvidenceByPath.Add($Path,[pscustomobject]@{definitionId=$definitionId;observedValue=$observedValue})
    $displayName=[string](Get-OptionalProperty $definition 'displayName')
    if([string]::IsNullOrWhiteSpace($displayName)){$displayName=$definitionId}
    return [pscustomobject][ordered]@{
        displayName=$displayName
        resolve=[pscustomobject][ordered]@{
            definitionId=$definitionId
            baseUri=(Get-NullableString $definition 'baseUri')
            offsetUri=(Get-NullableString $definition 'offsetUri')
            expectedType=$definitionType
        }
        value=[pscustomobject]$catalogValue
    }
}

$catalogByRecommendation=[System.Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
foreach($recommendation in @($catalog.recommendations)){
    $id=[string]$recommendation.recommendationId
    if($catalogByRecommendation.ContainsKey($id)){throw "Mapping catalog contains duplicate recommendation '$id'."}
    $catalogByRecommendation.Add($id,$recommendation)
}
$worklistByRecommendation=[System.Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
foreach($recommendation in @($worklist.recommendations)){
    $id=[string]$recommendation.recommendationId
    if($worklistByRecommendation.ContainsKey($id)){throw "Review worklist contains duplicate recommendation '$id'."}
    $worklistByRecommendation.Add($id,$recommendation)
}
$reviewByRecommendation=[System.Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
foreach($review in @($approvals.reviews)){
    $id=[string]$review.recommendationId
    if($reviewByRecommendation.ContainsKey($id)){throw "Approvals contain duplicate review '$id'."}
    if(-not $worklistByRecommendation.ContainsKey($id) -or -not $catalogByRecommendation.ContainsKey($id)){throw "Approval recommendation '$id' is absent from its evidence or catalog."}
    if([string]$review.candidateStatus -cne [string]$worklistByRecommendation[$id].candidateStatus){throw "Approval recommendation '$id' has stale candidateStatus."}
    $reviewByRecommendation.Add($id,$review)
}

$policyById=[System.Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
foreach($policy in @($catalog.settingsCatalogPolicies)){
    if($policyById.ContainsKey([string]$policy.id)){throw "Mapping catalog contains duplicate policy '$($policy.id)'."}
    $policyById.Add([string]$policy.id,$policy)
}
$newPolicyById=[System.Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
$newSettings=[System.Collections.Generic.List[object]]::new()
$settingKeys=[System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach($setting in @($catalog.settingsCatalogSettings)){
    $existingDefinitionId=[string](Get-OptionalProperty $setting.resolve 'definitionId')
    if($existingDefinitionId){
        if(-not $definitionById.ContainsKey($existingDefinitionId)){throw "Existing catalog setting references definition '$existingDefinitionId' absent from the pinned snapshot."}
        $resolvedExisting=$definitionById[$existingDefinitionId]
    }else{
        $base=Normalize-CspPath (Get-OptionalProperty $setting.resolve 'baseUri')
        $offset=([string](Get-OptionalProperty $setting.resolve 'offsetUri')).Trim().ToLowerInvariant()
        if(-not $base -or -not $offset){throw 'Existing catalog setting lacks an exact resolver.'}
        $matches=@($snapshot.definitions|Where-Object{(Normalize-CspPath $_.baseUri) -ceq $base -and ([string]$_.offsetUri).Trim().ToLowerInvariant() -ceq $offset})
        if($matches.Count -ne 1){throw "Existing catalog setting CSP resolver did not match exactly once; matches=$($matches.Count)."}
        $resolvedExisting=$matches[0]
        $existingDefinitionId=[string]$resolvedExisting.id
    }
    if([string]$resolvedExisting.'@odata.type' -cne [string]$setting.resolve.expectedType){throw "Existing catalog setting '$existingDefinitionId' contradicts its reviewed expectedType."}
    if(-not $settingKeys.Add(([string]$setting.policyId)+"`n"+$existingDefinitionId)){throw "Existing catalog policy '$($setting.policyId)' contains duplicate definition '$existingDefinitionId'."}
}
$selectionKeys=[System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$mappedReviewCount=0

foreach($catalogRecommendation in @($catalog.recommendations)){
    $recommendationId=[string]$catalogRecommendation.recommendationId
    if(-not $reviewByRecommendation.ContainsKey($recommendationId)){continue}
    $review=$reviewByRecommendation[$recommendationId]
    if([string]$review.outcome -in @('defer','rejected')){continue}
    if([string]$review.outcome -cne 'mapped'){throw "Unsupported review outcome for '$recommendationId'."}
    if([string]$catalogRecommendation.mappingStatus -cne 'unresolved'){throw "Only unresolved recommendation '$recommendationId' can be promoted by this tool."}
    if(@($catalogRecommendation.implementationRefs).Count -ne 0 -or $null -ne (Get-OptionalProperty $catalogRecommendation 'implementationType') -or $null -ne (Get-OptionalProperty $catalogRecommendation 'decisionRef')){throw "Unresolved recommendation '$recommendationId' contains pre-existing implementation or decision data."}
    $worklistRecommendation=$worklistByRecommendation[$recommendationId]
    if([string]$worklistRecommendation.candidateStatus -ceq 'none'){throw "Recommendation '$recommendationId' has no candidate evidence."}
    if([string]$catalogRecommendation.cisAssessmentMethod -cne [string]$worklistRecommendation.cisAssessmentMethod -or -not (Test-ExactArray $catalogRecommendation.profiles $worklistRecommendation.profiles)){throw "Recommendation '$recommendationId' catalog metadata contradicts the review worklist."}

    $implementationRefs=[System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($selection in @($review.selections)){
        $candidateDefinitionId=[string]$selection.candidateDefinitionId
        $sourceFile=[string]$selection.sourceFile
        $path=[string]$selection.path
        $topLevelDefinitionId=[string]$selection.topLevelDefinitionId
        $selectionKey="$recommendationId`n$candidateDefinitionId`n$sourceFile`n$path`n$topLevelDefinitionId"
        if(-not $selectionKeys.Add($selectionKey)){throw "Duplicate approval selection for recommendation '$recommendationId'."}
        $candidateMatches=@($worklistRecommendation.candidates|Where-Object{[string]$_.definitionId -ceq $candidateDefinitionId})
        if($candidateMatches.Count -ne 1){throw "Recommendation '$recommendationId' selection does not identify exactly one reviewed candidate '$candidateDefinitionId'."}
        $occurrenceMatches=@($candidateMatches[0].occurrences|Where-Object{
            [string]$_.sourceFile -ceq $sourceFile -and [string]$_.path -ceq $path -and [string]$_.topLevelDefinitionId -ceq $topLevelDefinitionId
        })
        if($occurrenceMatches.Count -ne 1){throw "Recommendation '$recommendationId' selection does not identify exactly one reviewed occurrence."}
        $occurrence=$occurrenceMatches[0]
        $profile=[string]$occurrence.profile
        if(@($catalogRecommendation.profiles|Where-Object{[string]$_ -ceq $profile}).Count -ne 1){throw "Recommendation '$recommendationId' does not declare occurrence profile '$profile'."}
        if(-not (Test-ExactArray $selection.policy.profiles @($profile))){throw "Approval policy '$($selection.policy.id)' profiles must exactly equal the selected occurrence profile '$profile'."}
        if(-not $referenceByPath.ContainsKey($sourceFile)){throw "Approved source file is absent from the hashed evidence set: $sourceFile"}

        $reference=$referenceByPath[$sourceFile]
        if($null -eq $reference.Document){
            try{$reference.Document=Get-Content -LiteralPath $reference.Path -Raw|ConvertFrom-Json -Depth 100}catch{throw "Reference policy '$sourceFile' is invalid JSON: $($_.Exception.Message)"}
        }
        $referencePolicy=Get-OptionalProperty $reference.Document 'policy'
        if(-not $referencePolicy){throw "Reference policy '$sourceFile' is missing policy metadata."}
        foreach($policyProperty in @('platforms','technologies')){
            if([string](Get-OptionalProperty $selection.policy $policyProperty) -cne [string](Get-OptionalProperty $referencePolicy $policyProperty)){throw "Approval policy '$($selection.policy.id)' property '$policyProperty' contradicts the hashed reference policy."}
        }
        if(-not (Test-ExactArray $selection.policy.roleScopeTagIds (Get-OptionalProperty $referencePolicy 'roleScopeTagIds' @('0')))){throw "Approval policy '$($selection.policy.id)' roleScopeTagIds contradict the hashed reference policy."}
        if(-not (Test-ExactArray $selection.policy.roleScopeTagIds @('0'))){throw "Approval policy '$($selection.policy.id)' must use only the default role scope tag '0'."}
        $pathMatch=[regex]::Match($path,'^settings\[([1-9][0-9]*)\](?:/|$)')
        if(-not $pathMatch.Success){throw "Approved occurrence path is invalid: $path"}
        $settingIndex=[int]$pathMatch.Groups[1].Value
        $referenceSettings=@(Get-OptionalProperty $reference.Document 'settings' @())
        if($settingIndex -gt $referenceSettings.Count){throw "Approved occurrence path is outside reference settings: $path"}
        $wrapper=$referenceSettings[$settingIndex-1]
        if([string](Get-OptionalProperty $wrapper '@odata.type') -cne '#microsoft.graph.deviceManagementConfigurationSetting'){throw "Reference policy '$sourceFile' settings[$settingIndex] has an invalid wrapper type."}
        $instance=Get-OptionalProperty $wrapper 'settingInstance'
        if([string](Get-OptionalProperty $instance 'settingDefinitionId') -cne $topLevelDefinitionId){throw "Approved top-level definition does not match reference evidence for '$path'."}
        $evidenceByPath=[System.Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
        $catalogNode=Convert-ReferenceInstance $instance $sourceFile "settings[$settingIndex]" $evidenceByPath 0
        if(-not $evidenceByPath.ContainsKey($path) -or [string]$evidenceByPath[$path].definitionId -cne $candidateDefinitionId){throw "Approved candidate path no longer identifies '$candidateDefinitionId'."}
        $actualObserved=ConvertTo-Json -InputObject $evidenceByPath[$path].observedValue -Depth 100 -Compress
        $reviewedObserved=ConvertTo-Json -InputObject $occurrence.observedValue -Depth 100 -Compress
        if($actualObserved -cne $reviewedObserved){throw "Approved occurrence value no longer matches the reviewed evidence for '$path'."}

        $policy=$selection.policy
        $policyId=[string]$policy.id
        if($policyById.ContainsKey($policyId)){Assert-PolicyEquivalent $policy $policyById[$policyId] "Approval '$recommendationId'"}
        elseif($newPolicyById.ContainsKey($policyId)){Assert-PolicyEquivalent $policy $newPolicyById[$policyId] "Approval '$recommendationId'"}
        else{
            $newPolicy=[pscustomobject][ordered]@{
                id=$policyId;name=[string]$policy.name;description=[string]$policy.description
                platforms=[string]$policy.platforms;technologies=[string]$policy.technologies
                profiles=@($policy.profiles);roleScopeTagIds=@($policy.roleScopeTagIds)
            }
            $newPolicyById.Add($policyId,$newPolicy)
        }
        $settingKey=$policyId+"`n"+$topLevelDefinitionId
        if(-not $settingKeys.Add($settingKey)){throw "Policy '$policyId' already contains or selects top-level definition '$topLevelDefinitionId'."}
        $newSettings.Add([pscustomobject][ordered]@{
            recommendationId=$recommendationId
            policyId=$policyId
            displayName=[string]$catalogNode.displayName
            profiles=@($profile)
            resolve=$catalogNode.resolve
            value=$catalogNode.value
        })|Out-Null
        $implementationRefs.Add('settings-catalog:'+$policyId)|Out-Null
    }

    $refs=[string[]]@($implementationRefs)
    [Array]::Sort($refs,[StringComparer]::Ordinal)
    $catalogRecommendation.mappingStatus='mapped'
    $catalogRecommendation.implementationType='settings-catalog'
    $catalogRecommendation.implementationRefs=@($refs)
    $catalogRecommendation.decisionRef=$null
    $catalogRecommendation.notes=[string]$review.publicNotes
    $mappedReviewCount++
}

if($mappedReviewCount -eq 0){throw 'Approvals contain no explicitly acknowledged mapped reviews; no output was written.'}

$newPolicyIds=[string[]]@($newPolicyById.Keys)
[Array]::Sort($newPolicyIds,[StringComparer]::Ordinal)
$catalog.settingsCatalogPolicies=@($catalog.settingsCatalogPolicies)+@($newPolicyIds|ForEach-Object{$newPolicyById[$_]})
$newSettings.Sort([System.Collections.Generic.Comparer[object]]::Create({
    param($Left,$Right)
    $leftKey=([string]$Left.recommendationId)+"`n"+([string]$Left.policyId)+"`n"+([string]$Left.resolve.definitionId)
    $rightKey=([string]$Right.recommendationId)+"`n"+([string]$Right.policyId)+"`n"+([string]$Right.resolve.definitionId)
    return [StringComparer]::Ordinal.Compare($leftKey,$rightKey)
}))
$catalog.settingsCatalogSettings=@($catalog.settingsCatalogSettings)+@($newSettings)
$catalog.version=[string]$approvals.output.catalogVersion
$catalog.pack.version=[string]$approvals.output.packVersion

$json=(ConvertTo-Json -InputObject $catalog -Depth 100)-replace "`r`n","`n"
$json+="`n"
$catalogSchema=Join-Path $repoRoot 'schemas\mapping-catalog.schema.json'
if(-not ($json|Test-Json -SchemaFile $catalogSchema -ErrorAction Stop)){throw 'Approved output mapping catalog failed schema validation.'}
$parent=Split-Path -Parent $outputFull
if(-not $parent){$parent=(Get-Location).Path}
if(-not (Test-Path -LiteralPath $parent)){New-Item -ItemType Directory -Path $parent|Out-Null}
$temporary=Join-Path $parent ('.'+[IO.Path]::GetFileName($outputFull)+'.'+[guid]::NewGuid().ToString('N')+'.tmp')
$tempBase=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
$validationRoot=Join-Path $tempBase ('CISPolicyCreator-approval-validation-'+[guid]::NewGuid().ToString('N'))
try{
    [IO.File]::WriteAllText($temporary,$json,[Text.UTF8Encoding]::new($false))
    & (Join-Path $repoRoot 'scripts\Build-CISPolicyPack.ps1') -ExtractionPath $extractionInput.Path -MappingCatalogPath $temporary -SettingsCatalogSnapshotPath $snapshotInput.Path -OutputPath $validationRoot
    $validation=& (Join-Path $repoRoot 'scripts\Test-CISPolicyPack.ps1') -PackRoot $validationRoot -PassThru
    if(-not $validation.IsValid){throw 'Approved catalog did not compile into a valid fail-closed policy pack.'}
    $resolvedValidationRoot=[IO.Path]::GetFullPath($validationRoot)
    if(-not $resolvedValidationRoot.StartsWith($tempBase,$pathComparison)){throw "Refusing unsafe validation cleanup path: $resolvedValidationRoot"}
    Remove-Item -LiteralPath $resolvedValidationRoot -Recurse -Force
    Move-Item -LiteralPath $temporary -Destination $outputFull
}finally{
    if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Force}
    if(Test-Path -LiteralPath $validationRoot){
        $resolvedValidationRoot=[IO.Path]::GetFullPath($validationRoot)
        if(-not $resolvedValidationRoot.StartsWith($tempBase,$pathComparison)){throw "Refusing unsafe validation cleanup path: $resolvedValidationRoot"}
        Remove-Item -LiteralPath $resolvedValidationRoot -Recurse -Force
    }
}

Write-Host "Applied $mappedReviewCount explicit mapping review(s): $outputFull"
Write-Host "New Settings Catalog settings: $($newSettings.Count); new policies: $($newPolicyById.Count)"
Write-Host 'Full private-extraction-bound pack compilation and offline validation passed before catalog publication.'
Write-Warning 'The output is still subject to live dry run, test-tenant validation, and unassigned-only import.'
