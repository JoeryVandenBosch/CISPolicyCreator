[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ExtractionPath,
    [Parameter(Mandatory)][string]$SettingsCatalogSnapshotPath,
    [Parameter(Mandatory)][string]$ReferencePackRoot,
    [Parameter(Mandatory)][string]$OutputPath,
    [ValidateRange(1,200)][int]$MinimumNormalizedLength=8
)

$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$repoRoot=Split-Path -Parent $PSScriptRoot
$outputFull=[IO.Path]::GetFullPath($OutputPath)
if(-not $outputFull.EndsWith('.private-review.json',[StringComparison]::OrdinalIgnoreCase)){throw 'OutputPath must end with .private-review.json so private benchmark titles are covered by .gitignore.'}
if(Test-Path -LiteralPath $outputFull){throw "OutputPath already exists: $outputFull"}

function Read-ValidatedJson([string]$Path,[string]$SchemaName,[string]$Label) {
    $resolved=(Resolve-Path -LiteralPath $Path).Path
    $json=Get-Content -LiteralPath $resolved -Raw
    $schemaPath=Join-Path $repoRoot "schemas\$SchemaName"
    if(-not ($json | Test-Json -SchemaFile $schemaPath -ErrorAction Stop)){throw "$Label does not satisfy $SchemaName."}
    return [pscustomobject]@{Path=$resolved;Value=($json|ConvertFrom-Json -Depth 100)}
}

function Get-OptionalProperty($Object,[string]$Name,$Default=$null) {
    if($null -eq $Object){return $Default}
    $property=$Object.PSObject.Properties[$Name]
    if($null -eq $property){return $Default}
    return $property.Value
}

function Get-Sha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Normalize-ReviewText([string]$Value) {
    if([string]::IsNullOrWhiteSpace($Value)){return ''}
    return (($Value.ToLowerInvariant() -replace '[^\p{L}\p{Nd}]+',' ').Trim() -replace '\s+',' ')
}

function Get-PolicyProfile([string]$PolicyName) {
    $match=[regex]::Match($PolicyName,'\[(L1|L2|BL)\]',[Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if(-not $match.Success){throw "Reference policy '$PolicyName' does not contain an exact [L1], [L2], or [BL] profile marker."}
    return $match.Groups[1].Value.ToUpperInvariant()
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

$extractionInput=Read-ValidatedJson $ExtractionPath 'extraction.schema.json' 'Extraction'
$snapshotInput=Read-ValidatedJson $SettingsCatalogSnapshotPath 'settings-catalog-snapshot.schema.json' 'Settings Catalog snapshot'
$extraction=$extractionInput.Value
$snapshot=$snapshotInput.Value

if([int]$snapshot.retrieval.definitionCount -ne @($snapshot.definitions).Count){throw 'Settings Catalog snapshot retrieval count does not match its definitions array.'}
$definitionById=[System.Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
$definitionIdsIgnoreCase=[System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach($definition in @($snapshot.definitions)){
    $id=[string]$definition.id
    if(-not $definitionIdsIgnoreCase.Add($id)){throw "Settings Catalog snapshot contains duplicate or case-conflicting definition ID '$id'."}
    $definitionById.Add($id,$definition)
}

$referenceRoot=(Resolve-Path -LiteralPath $ReferencePackRoot).Path
$configurationRoot=Join-Path $referenceRoot 'configuration-policies'
if(-not (Test-Path -LiteralPath $configurationRoot -PathType Container)){throw "Reference pack is missing configuration-policies: $configurationRoot"}
$referenceFileList=[System.Collections.Generic.List[System.IO.FileInfo]]::new()
foreach($referenceFile in @(Get-ChildItem -LiteralPath $configurationRoot -Filter *.json -File)){$referenceFileList.Add($referenceFile)}
$referenceFileList.Sort([System.Collections.Generic.Comparer[System.IO.FileInfo]]::Create({param($Left,$Right) [StringComparer]::Ordinal.Compare($Left.Name,$Right.Name)}))
$referenceFiles=@($referenceFileList)
if($referenceFiles.Count -eq 0){throw 'Reference pack contains no configuration-policy JSON files.'}

$occurrences=[System.Collections.Generic.List[object]]::new()
function Add-ReferenceInstance {
    param(
        [Parameter(Mandatory)]$Instance,
        [Parameter(Mandatory)][string]$PolicyName,
        [Parameter(Mandatory)][string]$Profile,
        [Parameter(Mandatory)][string]$SourceFile,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$TopLevelDefinitionId,
        [Parameter(Mandatory)]$AncestorDefinitionIds,
        [int]$Depth=0
    )
    if($Depth -gt 32){throw "$SourceFile $Path exceeds the maximum reference traversal depth."}
    $definitionId=[string](Get-OptionalProperty $Instance 'settingDefinitionId')
    if(-not $definitionId){throw "$SourceFile $Path is missing settingDefinitionId."}
    if(-not $definitionById.ContainsKey($definitionId)){throw "$SourceFile $Path references definition '$definitionId' absent from the pinned snapshot."}
    $definition=$definitionById[$definitionId]
    $instanceType=[string](Get-OptionalProperty $Instance '@odata.type')
    $definitionType=[string]$definition.'@odata.type'
    $observedValue=$null

    if($instanceType -ceq '#microsoft.graph.deviceManagementConfigurationChoiceSettingInstance'){
        if($definitionType -cne '#microsoft.graph.deviceManagementConfigurationChoiceSettingDefinition'){throw "$SourceFile $Path instance type contradicts definition '$definitionId'."}
        $choiceValue=Get-OptionalProperty $Instance 'choiceSettingValue'
        if([string](Get-OptionalProperty $choiceValue '@odata.type') -cne '#microsoft.graph.deviceManagementConfigurationChoiceSettingValue'){throw "$SourceFile $Path has an invalid choice value type."}
        $optionId=[string](Get-OptionalProperty $choiceValue 'value')
        if(-not $optionId){throw "$SourceFile $Path is missing its exact choice option ID."}
        if(@($definition.options | Where-Object { [string]$_.itemId -ceq $optionId }).Count -ne 1){throw "$SourceFile $Path option '$optionId' is not uniquely present in definition '$definitionId'."}
        $observedValue=[pscustomobject][ordered]@{kind='choice';optionId=$optionId}
    }elseif($instanceType -ceq '#microsoft.graph.deviceManagementConfigurationSimpleSettingCollectionInstance'){
        if($definitionType -cne '#microsoft.graph.deviceManagementConfigurationSimpleSettingCollectionDefinition'){throw "$SourceFile $Path instance type contradicts definition '$definitionId'."}
        $rawValues=@(Get-OptionalProperty $Instance 'simpleSettingCollectionValue' @())
        if($rawValues.Count -eq 0){throw "$SourceFile $Path contains an empty simple collection."}
        $validatedValues=[System.Collections.Generic.List[object]]::new()
        $valueIndex=0
        foreach($rawValue in $rawValues){$valueIndex++;$validatedValues.Add((Assert-ReferenceSimpleValue $definition $rawValue "$SourceFile $Path value $valueIndex"))|Out-Null}
        $elementKinds=@($validatedValues.kind | Sort-Object -Unique)
        if($elementKinds.Count -ne 1){throw "$SourceFile $Path mixes simple collection value types."}
        $observedValue=[pscustomobject][ordered]@{kind=([string]$elementKinds[0]+'-collection');values=@($validatedValues.value)}
    }elseif($instanceType -ceq '#microsoft.graph.deviceManagementConfigurationSimpleSettingInstance'){
        if($definitionType -cne '#microsoft.graph.deviceManagementConfigurationSimpleSettingDefinition'){throw "$SourceFile $Path instance type contradicts definition '$definitionId'."}
        $observedValue=Assert-ReferenceSimpleValue $definition (Get-OptionalProperty $Instance 'simpleSettingValue') "$SourceFile $Path"
    }elseif($instanceType -ceq '#microsoft.graph.deviceManagementConfigurationGroupSettingCollectionInstance'){
        if($definitionType -cne '#microsoft.graph.deviceManagementConfigurationSettingGroupCollectionDefinition'){throw "$SourceFile $Path instance type contradicts definition '$definitionId'."}
        $groups=@(Get-OptionalProperty $Instance 'groupSettingCollectionValue' @())
        if($groups.Count -eq 0){throw "$SourceFile $Path contains an empty group collection."}
        $observedValue=[pscustomobject][ordered]@{kind='group-collection';itemCount=$groups.Count}
    }else{throw "$SourceFile $Path uses unsupported instance type '$instanceType'."}

    $occurrences.Add([pscustomobject][ordered]@{
        definitionId=$definitionId
        policyName=$PolicyName
        profile=$Profile
        sourceFile=$SourceFile
        path=$Path
        topLevelDefinitionId=$TopLevelDefinitionId
        ancestorDefinitionIds=@($AncestorDefinitionIds)
        instanceType=$instanceType
        observedValue=$observedValue
    }) | Out-Null

    $nextAncestors=@($AncestorDefinitionIds)+@($definitionId)
    if($instanceType -ceq '#microsoft.graph.deviceManagementConfigurationChoiceSettingInstance'){
        $choiceValue=Get-OptionalProperty $Instance 'choiceSettingValue'
        $childDefinitionIds=[System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $childIndex=0
        foreach($child in @(Get-OptionalProperty $choiceValue 'children' @())){
            $childIndex++
            $childDefinitionId=[string](Get-OptionalProperty $child 'settingDefinitionId')
            if(-not $childDefinitionIds.Add($childDefinitionId)){throw "$SourceFile $Path contains duplicate choice child definition '$childDefinitionId'."}
            Add-ReferenceInstance $child $PolicyName $Profile $SourceFile "$Path/choice.children[$childIndex]" $TopLevelDefinitionId $nextAncestors ($Depth+1)
        }
    }elseif($instanceType -ceq '#microsoft.graph.deviceManagementConfigurationGroupSettingCollectionInstance'){
        $groupIndex=0
        foreach($group in @(Get-OptionalProperty $Instance 'groupSettingCollectionValue' @())){
            $groupIndex++
            if([string](Get-OptionalProperty $group '@odata.type') -cne '#microsoft.graph.deviceManagementConfigurationGroupSettingValue'){throw "$SourceFile $Path group $groupIndex has an invalid group value type."}
            $children=@(Get-OptionalProperty $group 'children' @())
            if($children.Count -eq 0){throw "$SourceFile $Path group $groupIndex contains no children."}
            $childDefinitionIds=[System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            $childIndex=0
            foreach($child in $children){
                $childIndex++
                $childDefinitionId=[string](Get-OptionalProperty $child 'settingDefinitionId')
                if(-not $childDefinitionIds.Add($childDefinitionId)){throw "$SourceFile $Path group $groupIndex contains duplicate child definition '$childDefinitionId'."}
                Add-ReferenceInstance $child $PolicyName $Profile $SourceFile "$Path/groups[$groupIndex].children[$childIndex]" $TopLevelDefinitionId $nextAncestors ($Depth+1)
            }
        }
    }
}

$referenceFileRecords=[System.Collections.Generic.List[object]]::new()
foreach($file in $referenceFiles){
    $relativePath=$file.FullName.Substring($referenceRoot.Length+1).Replace('\','/')
    $referenceFileRecords.Add([pscustomobject][ordered]@{path=$relativePath;sha256=(Get-Sha256 $file.FullName)})|Out-Null
    try{$document=Get-Content -LiteralPath $file.FullName -Raw|ConvertFrom-Json -Depth 100}catch{throw "Reference policy '$relativePath' is invalid JSON: $($_.Exception.Message)"}
    $policy=Get-OptionalProperty $document 'policy'
    $policyName=[string](Get-OptionalProperty $policy 'name')
    if(-not $policyName){throw "Reference policy '$relativePath' is missing policy.name."}
    $profile=Get-PolicyProfile $policyName
    $settings=@(Get-OptionalProperty $document 'settings' @())
    $topLevelDefinitionIds=[System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $settingIndex=0
    foreach($setting in $settings){
        $settingIndex++
        if([string](Get-OptionalProperty $setting '@odata.type') -cne '#microsoft.graph.deviceManagementConfigurationSetting'){throw "Reference policy '$relativePath' settings[$settingIndex] has an invalid setting wrapper type."}
        $instance=Get-OptionalProperty $setting 'settingInstance'
        if(-not $instance){throw "Reference policy '$relativePath' settings[$settingIndex] is missing settingInstance."}
        $topLevelDefinitionId=[string](Get-OptionalProperty $instance 'settingDefinitionId')
        if(-not $topLevelDefinitionIds.Add($topLevelDefinitionId)){throw "Reference policy '$relativePath' contains duplicate top-level definition '$topLevelDefinitionId'."}
        Add-ReferenceInstance $instance $policyName $profile $relativePath "settings[$settingIndex]" $topLevelDefinitionId @() 0
    }
}

$occurrencesByDefinition=[System.Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
foreach($occurrence in $occurrences){
    $id=[string]$occurrence.definitionId
    if(-not $occurrencesByDefinition.ContainsKey($id)){$occurrencesByDefinition[$id]=[System.Collections.Generic.List[object]]::new()}
    $occurrencesByDefinition[$id].Add($occurrence)|Out-Null
}

$recommendationResults=[System.Collections.Generic.List[object]]::new()
$uniqueCount=0;$ambiguousCount=0;$noneCount=0;$candidateLinkCount=0
$referenceDefinitionIds=[string[]]@($occurrencesByDefinition.Keys)
[Array]::Sort($referenceDefinitionIds,[StringComparer]::Ordinal)
foreach($recommendation in @($extraction.recommendations)){
    $normalizedTitle=Normalize-ReviewText ([string]$recommendation.title)
    $recommendationProfiles=@($recommendation.profiles | ForEach-Object { ([string]$_).ToUpperInvariant() })
    $candidates=[System.Collections.Generic.List[object]]::new()
    foreach($definitionId in $referenceDefinitionIds){
        $definition=$definitionById[$definitionId]
        $displayName=[string]$definition.displayName
        $normalizedDisplayName=Normalize-ReviewText $displayName
        if($normalizedDisplayName.Length -lt $MinimumNormalizedLength){continue}
        $direction=$null
        if($normalizedTitle -ceq $normalizedDisplayName){$direction='exact'}
        elseif($normalizedTitle.Contains($normalizedDisplayName)){$direction='recommendation-contains-definition'}
        elseif($normalizedDisplayName.Contains($normalizedTitle)){$direction='definition-contains-recommendation'}
        if(-not $direction){continue}
        $eligibleOccurrences=@($occurrencesByDefinition[$definitionId] | Where-Object { $recommendationProfiles -contains ([string]$_.profile).ToUpperInvariant() })
        if($eligibleOccurrences.Count -eq 0){continue}
        $candidates.Add([pscustomobject][ordered]@{
            definitionId=$definitionId
            displayName=$displayName
            expectedType=[string]$definition.'@odata.type'
            matchDirection=$direction
            occurrences=@($eligibleOccurrences | ForEach-Object {
                [pscustomobject][ordered]@{
                    policyName=$_.policyName;profile=$_.profile;sourceFile=$_.sourceFile;path=$_.path
                    topLevelDefinitionId=$_.topLevelDefinitionId;ancestorDefinitionIds=@($_.ancestorDefinitionIds)
                    instanceType=$_.instanceType;observedValue=$_.observedValue
                }
            })
        })|Out-Null
    }
    $status=if($candidates.Count -eq 0){$noneCount++;'none'}elseif($candidates.Count -eq 1){$uniqueCount++;'unique-candidate'}else{$ambiguousCount++;'ambiguous-candidates'}
    $candidateLinkCount+=$candidates.Count
    $recommendationResults.Add([pscustomobject][ordered]@{
        recommendationId=[string]$recommendation.recommendationId
        title=[string]$recommendation.title
        page=[int]$recommendation.page
        profiles=@($recommendation.profiles)
        cisAssessmentMethod=[string]$recommendation.cisAssessmentMethod
        candidateStatus=$status
        candidates=@($candidates)
    })|Out-Null
}

$worklist=[pscustomobject][ordered]@{
    schemaVersion='1.0'
    tool=[pscustomobject][ordered]@{
        name='New-CISMappingReviewWorklist.ps1'
        version='0.1.0'
        matchRule='exact-normalized-title-display-containment'
        minimumNormalizedLength=$MinimumNormalizedLength
    }
    mappingChangesMade=$false
    source=[pscustomobject][ordered]@{
        extractionSha256=(Get-Sha256 $extractionInput.Path)
        settingsCatalogSnapshotSha256=(Get-Sha256 $snapshotInput.Path)
        referenceFiles=@($referenceFileRecords)
    }
    summary=[pscustomobject][ordered]@{
        recommendationCount=@($recommendationResults).Count
        referenceDefinitionCount=$occurrencesByDefinition.Count
        validatedOccurrenceCount=$occurrences.Count
        uniqueCandidateRecommendations=$uniqueCount
        ambiguousCandidateRecommendations=$ambiguousCount
        noCandidateRecommendations=$noneCount
        candidateLinkCount=$candidateLinkCount
    }
    recommendations=@($recommendationResults)
}

$outputDirectory=Split-Path -Parent $outputFull
if(-not (Test-Path -LiteralPath $outputDirectory)){New-Item -ItemType Directory -Path $outputDirectory|Out-Null}
$json=(ConvertTo-Json -InputObject $worklist -Depth 100) -replace "`r`n","`n"
$json+="`n"
$schemaPath=Join-Path $repoRoot 'schemas\private-mapping-review.schema.json'
if(-not ($json|Test-Json -SchemaFile $schemaPath -ErrorAction Stop)){throw 'Generated private review worklist failed schema validation.'}
[IO.File]::WriteAllText($outputFull,$json,[Text.UTF8Encoding]::new($false))

Write-Host "Generated private candidate-only review worklist: $outputFull"
Write-Host "Recommendations: $(@($recommendationResults).Count); unique candidates: $uniqueCount; ambiguous: $ambiguousCount; none: $noneCount"
Write-Warning 'This file contains private benchmark titles. It does not change mappingStatus and must not be committed.'
