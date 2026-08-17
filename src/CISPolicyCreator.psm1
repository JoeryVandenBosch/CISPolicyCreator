Set-StrictMode -Version Latest

function Add-CpcResult {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Results,
        [Parameter(Mandatory)][string]$Stage,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Status,
        [string]$Detail = ''
    )
    $Results.Add([pscustomobject]@{ stage=$Stage; name=$Name; status=$Status; detail=$Detail })
}

function Invoke-CpcGraphPaged {
    param([Parameter(Mandatory)][string]$Uri)

    $topMatch=[regex]::Match($Uri,'(?i)(?:[?&])\$top=(\d+)')
    $pageSize=if($topMatch.Success){[int]$topMatch.Groups[1].Value}else{0}
    if($Uri -match '(?i)(?:[?&])\$skip=') { throw 'Invoke-CpcGraphPaged requires an unskipped collection URI.' }

    $items=[System.Collections.Generic.List[object]]::new()
    $seenIds=[System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $next = $Uri
    $pageCount=0
    while ($next) {
        $pageCount++
        if($pageCount -gt 1000){throw 'Graph pagination exceeded 1000 pages; refusing an unbounded read.'}
        $r = Invoke-MgGraphRequest -Method GET -Uri $next

        $isDictionary=$r -is [System.Collections.IDictionary]
        $valueProperty=if($isDictionary){$r.Contains('value')}else{$null -ne $r.PSObject.Properties['value']}
        if(-not $valueProperty){
            $items.Add($r)
            $next = $null
            continue
        }

        if($isDictionary){$pageItems=@($r['value'])}else{$pageItems=@($r.PSObject.Properties['value'].Value)}
        foreach($item in $pageItems){
            $itemIsDictionary=$item -is [System.Collections.IDictionary]
            $idProperty=if($itemIsDictionary){$item.Contains('id')}else{$null -ne $item.PSObject.Properties['id']}
            $id=''
            if($idProperty){
                if($itemIsDictionary){$id=[string]$item['id']}else{$id=[string]$item.PSObject.Properties['id'].Value}
            }
            if([string]::IsNullOrWhiteSpace($id)){throw "Graph collection page $pageCount returned an item without an ID."}
            if(-not $seenIds.Add($id)){throw "Graph pagination returned duplicate object ID '$id'; completeness cannot be proven."}
            $items.Add($item)
        }

        $nextProperty=if($isDictionary){$r.Contains('@odata.nextLink')}else{$null -ne $r.PSObject.Properties['@odata.nextLink']}
        $serverNext=''
        if($nextProperty){
            if($isDictionary){$serverNext=[string]$r['@odata.nextLink']}else{$serverNext=[string]$r.PSObject.Properties['@odata.nextLink'].Value}
        }
        if(-not [string]::IsNullOrWhiteSpace($serverNext)){
            $next=$serverNext
        }elseif($pageSize -gt 0 -and $pageItems.Count -eq $pageSize){
            $separator=if($Uri.Contains('?')){'&'}else{'?'}
            $next=$Uri+$separator+'$skip='+$items.Count
        }else{
            $next=$null
        }
    }
    return @($items)
}

function Get-CpcGraphErrorDetail {
    param([Parameter(Mandatory)]$ErrorRecord)
    $parts = [System.Collections.Generic.List[string]]::new()
    if ($ErrorRecord.Exception -and $ErrorRecord.Exception.Message) { $parts.Add([string]$ErrorRecord.Exception.Message) }
    if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) { $parts.Add([string]$ErrorRecord.ErrorDetails.Message) }
    foreach ($propName in @('ResponseBody','ResponseContent','Body','RawResponseBody')) {
        try { $v = $ErrorRecord.Exception.$propName; if ($v) { $parts.Add([string]$v) } } catch {}
    }
    try { if ($ErrorRecord.Exception.Response) { $parts.Add("HTTP response: $($ErrorRecord.Exception.Response)") } } catch {}
    $detail = ($parts | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique) -join ' | '
    if ([string]::IsNullOrWhiteSpace($detail)) { $detail = [string]$ErrorRecord }
    return $detail
}

function Normalize-CpcCspPath {
    param([AllowNull()][string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    $v = $Value.Trim().ToLowerInvariant() -replace '^\./',''
    return $v.TrimEnd('/')
}

function Get-CpcSettingDefinition {
    param([Parameter(Mandatory)]$Spec,[Parameter(Mandatory)]$Definitions,[hashtable]$Cache)

    if ($Spec.resolve.definitionId) {
        $reviewedId=[string]$Spec.resolve.definitionId
        if($Cache -and $Cache.ContainsKey($reviewedId)){
            $def=$Cache[$reviewedId]
        }else{
            $encodedDefinitionId=[Uri]::EscapeDataString($reviewedId)
            try { $def = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceManagement/configurationSettings/$encodedDefinitionId" }
            catch { throw "Could not read explicit Settings Catalog definition '$reviewedId' for '$($Spec.displayName)': $(Get-CpcGraphErrorDetail $_)" }
            if($Cache){$Cache[$reviewedId]=$def}
        }
        if ([string]$def.id -cne [string]$Spec.resolve.definitionId) { throw "Graph returned definition '$($def.id)' instead of reviewed definition '$($Spec.resolve.definitionId)' for '$($Spec.displayName)'." }
    } else {
        $base = Normalize-CpcCspPath $Spec.resolve.baseUri
        $offset = ([string]$Spec.resolve.offsetUri).Trim().ToLowerInvariant()
        if (-not $base -or -not $offset) {
            throw "'$($Spec.displayName)' must use an explicit definitionId or an exact baseUri + offsetUri resolver."
        }
        $matches = @($Definitions | Where-Object {
            (Normalize-CpcCspPath $_.baseUri) -eq $base -and ([string]$_.offsetUri).Trim().ToLowerInvariant() -eq $offset
        })
        if ($matches.Count -ne 1) { throw "Could not uniquely resolve Settings Catalog definition for '$($Spec.displayName)' by exact baseUri + offsetUri. Matches=$($matches.Count)." }
        $def = $matches[0]
        if($Cache){$Cache[[string]$def.id]=$def}
    }
    $definitionBaseUriProperty=$def.PSObject.Properties['baseUri']
    $definitionOffsetUriProperty=$def.PSObject.Properties['offsetUri']
    $definitionBaseUri=if ($definitionBaseUriProperty) { [string]$definitionBaseUriProperty.Value } else { $null }
    $definitionOffsetUri=if ($definitionOffsetUriProperty) { [string]$definitionOffsetUriProperty.Value } else { $null }
    if ($Spec.resolve.baseUri -and -not [string]::IsNullOrWhiteSpace($definitionBaseUri) -and (Normalize-CpcCspPath $definitionBaseUri) -ne (Normalize-CpcCspPath $Spec.resolve.baseUri)) {
        throw "Definition '$($def.id)' baseUri does not match the reviewed resolver for '$($Spec.displayName)'."
    }
    if ($Spec.resolve.offsetUri -and -not [string]::IsNullOrWhiteSpace($definitionOffsetUri) -and ([string]$definitionOffsetUri).Trim() -ine ([string]$Spec.resolve.offsetUri).Trim()) {
        throw "Definition '$($def.id)' offsetUri does not match the reviewed resolver for '$($Spec.displayName)'."
    }
    if ($Spec.resolve.expectedType -and [string]$def.'@odata.type' -ne [string]$Spec.resolve.expectedType) {
        throw "Definition '$($def.id)' type '$($def.'@odata.type')' does not match reviewed type '$($Spec.resolve.expectedType)' for '$($Spec.displayName)'."
    }
    $optionsProperty=$def.PSObject.Properties['options']
    if (([string]$def.'@odata.type') -match 'ChoiceSettingDefinition' -and (-not $optionsProperty -or @($optionsProperty.Value).Count -eq 0)) {
        $encodedResolvedId=[Uri]::EscapeDataString([string]$def.id)
        $def = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceManagement/configurationSettings/$encodedResolvedId"
        if ($Spec.resolve.definitionId -and [string]$def.id -cne [string]$Spec.resolve.definitionId) { throw "Graph returned a different definition while loading choice options for '$($Spec.displayName)'." }
        if ([string]$def.'@odata.type' -cne [string]$Spec.resolve.expectedType) { throw "Graph definition type changed while loading choice options for '$($Spec.displayName)'." }
        if($Cache){$Cache[[string]$def.id]=$def}
    }
    return $def
}

function Assert-CpcLiveSimpleValue {
    param([Parameter(Mandatory)]$Definition,[Parameter(Mandatory)][string]$Kind,$Value,[Parameter(Mandatory)][string]$DisplayName)
    if($Kind -eq 'integer'){
        if($Value -isnot [byte] -and $Value -isnot [int16] -and $Value -isnot [int32] -and $Value -isnot [int64]){throw "Value for '$DisplayName' must be an integer."}
    }elseif($Kind -eq 'string'){
        if($Value -isnot [string]){throw "Value for '$DisplayName' must be a string."}
    }else{throw "Unsupported simple value kind '$Kind' for '$DisplayName'."}

    $valueDefinitionProperty=$Definition.PSObject.Properties['valueDefinition']
    $valueDefinition=if($valueDefinitionProperty){$valueDefinitionProperty.Value}else{$null}
    if(-not $valueDefinition){return}
    $definitionValueTypeProperty=$valueDefinition.PSObject.Properties['@odata.type']
    $definitionValueType=if($definitionValueTypeProperty){[string]$definitionValueTypeProperty.Value}else{''}
    if($definitionValueType -match 'IntegerSettingValueDefinition$' -and $Kind -ne 'integer'){throw "Value kind for '$DisplayName' does not match the live integer definition."}
    if($definitionValueType -match 'StringSettingValueDefinition$' -and $Kind -ne 'string'){throw "Value kind for '$DisplayName' does not match the live string definition."}
    if($Kind -eq 'integer'){
        $minimumProperty=$valueDefinition.PSObject.Properties['minimumValue']
        $maximumProperty=$valueDefinition.PSObject.Properties['maximumValue']
        if($minimumProperty -and [int64]$Value -lt [int64]$minimumProperty.Value){throw "Value for '$DisplayName' is below the live definition minimum."}
        if($maximumProperty -and [int64]$Value -gt [int64]$maximumProperty.Value){throw "Value for '$DisplayName' is above the live definition maximum."}
    }else{
        $minimumLengthProperty=$valueDefinition.PSObject.Properties['minimumLength']
        $maximumLengthProperty=$valueDefinition.PSObject.Properties['maximumLength']
        if($minimumLengthProperty -and ([string]$Value).Length -lt [int]$minimumLengthProperty.Value){throw "Value for '$DisplayName' is shorter than the live definition minimumLength."}
        if($maximumLengthProperty -and ([string]$Value).Length -gt [int]$maximumLengthProperty.Value){throw "Value for '$DisplayName' is longer than the live definition maximumLength."}
    }
}

function New-CpcSimpleSettingValue {
    param([Parameter(Mandatory)][string]$Kind,$Value)
    if($Kind -eq 'integer'){
        return @{'@odata.type'='#microsoft.graph.deviceManagementConfigurationIntegerSettingValue';value=[int64]$Value}
    }
    return @{'@odata.type'='#microsoft.graph.deviceManagementConfigurationStringSettingValue';value=[string]$Value}
}

function New-CpcConfigurationSettingInstances {
    param([Parameter(Mandatory)]$Specs,[Parameter(Mandatory)]$Definitions,[hashtable]$DefinitionCache,[Parameter(Mandatory)][int]$Depth,[Parameter(Mandatory)][string]$Context)
    $instances=[System.Collections.Generic.List[object]]::new()
    $ids=[System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $index=0
    foreach($childSpec in @($Specs)){
        $index++
        $childDefinition=Get-CpcSettingDefinition -Spec $childSpec -Definitions $Definitions -Cache $DefinitionCache
        if(-not $ids.Add([string]$childDefinition.id)){throw "$Context contains duplicate child definition '$($childDefinition.id)' in one value."}
        $instances.Add((New-CpcConfigurationSettingInstance -Definition $childDefinition -Spec $childSpec -Definitions $Definitions -DefinitionCache $DefinitionCache -Depth $Depth)) | Out-Null
    }
    return @($instances)
}

function Get-CpcRequiredChildDefinitionIds {
    param([Parameter(Mandatory)]$Definition,$SelectedOption=$null)
    $dependencies=[System.Collections.Generic.List[object]]::new()
    foreach($source in @($Definition,$SelectedOption)){
        if($null -eq $source){continue}
        $property=$source.PSObject.Properties['dependedOnBy']
        if($property){foreach($dependency in @($property.Value)){$dependencies.Add($dependency) | Out-Null}}
    }
    return @($dependencies | Where-Object {
        $requiredProperty=$_.PSObject.Properties['required']
        $childProperty=$_.PSObject.Properties['dependedOnBy']
        $requiredProperty -and $requiredProperty.Value -eq $true -and $childProperty -and [string]$childProperty.Value
    } | ForEach-Object { [string]$_.PSObject.Properties['dependedOnBy'].Value } | Sort-Object -Unique)
}

function Assert-CpcRequiredChildDefinitions {
    param([Parameter(Mandatory)]$Definition,$SelectedOption=$null,[Parameter(Mandatory)]$Children,[Parameter(Mandatory)][string]$Context)
    $requiredChildIds=@(Get-CpcRequiredChildDefinitionIds -Definition $Definition -SelectedOption $SelectedOption)
    $actualChildIds=@($Children | ForEach-Object { [string]$_.settingDefinitionId })
    $missingRequiredChildIds=@($requiredChildIds | Where-Object { $actualChildIds -notcontains [string]$_ })
    if($missingRequiredChildIds.Count -gt 0){
        throw "$Context is missing live-required child definition(s): $($missingRequiredChildIds -join ', ')."
    }
}

function New-CpcConfigurationSettingInstance {
    param([Parameter(Mandatory)]$Definition,[Parameter(Mandatory)]$Spec,[Parameter(Mandatory)]$Definitions,[hashtable]$DefinitionCache,[int]$Depth=0)
    if($Depth -gt 16){throw "'$($Spec.displayName)' exceeds the maximum nested Settings Catalog depth."}
    $type=[string]$Definition.'@odata.type'
    $valueSpec=$Spec.value
    $kind=[string]$valueSpec.kind

    if($type -match 'ChoiceSettingDefinition$'){
        if($kind -ne 'choice'){throw "Value kind '$kind' does not match choice definition '$($Spec.displayName)'."}
        $options=@($Definition.options)
        if($options.Count -eq 0){throw "No choice options returned for '$($Spec.displayName)'."}
        if(-not $valueSpec.optionId){throw "An exact reviewed optionId is required for choice setting '$($Spec.displayName)'."}
        $candidate=@($options | Where-Object { [string]$_.itemId -ceq [string]$valueSpec.optionId })
        if($candidate.Count -ne 1){
            $available=($options | ForEach-Object { "$($_.itemId) [$($_.displayName)]" }) -join '; '
            throw "Exact choice optionId '$($valueSpec.optionId)' was not uniquely present for '$($Spec.displayName)'. Available: $available"
        }
        $childrenProperty=$valueSpec.PSObject.Properties['children']
        [object[]]$children=@()
        if($childrenProperty){$children=@(New-CpcConfigurationSettingInstances -Specs @($childrenProperty.Value) -Definitions $Definitions -DefinitionCache $DefinitionCache -Depth ($Depth+1) -Context "Choice '$($Spec.displayName)'")}
        Assert-CpcRequiredChildDefinitions -Definition $Definition -SelectedOption $candidate[0] -Children $children -Context "Choice '$($Spec.displayName)' option '$($valueSpec.optionId)'"
        return @{
            '@odata.type'='#microsoft.graph.deviceManagementConfigurationChoiceSettingInstance'
            settingDefinitionId=[string]$Definition.id
            choiceSettingValue=@{'@odata.type'='#microsoft.graph.deviceManagementConfigurationChoiceSettingValue';value=[string]$candidate[0].itemId;children=@($children)}
        }
    }

    if($type -match 'SimpleSettingCollectionDefinition$'){
        if($kind -notin @('integer-collection','string-collection')){throw "Value kind '$kind' does not match simple collection definition '$($Spec.displayName)'."}
        $valuesProperty=$valueSpec.PSObject.Properties['values']
        $values=if($valuesProperty){@($valuesProperty.Value)}else{@()}
        if($values.Count -eq 0){throw "At least one collection value is required for '$($Spec.displayName)'."}
        $elementKind=if($kind -eq 'integer-collection'){'integer'}else{'string'}
        $settingValues=[System.Collections.Generic.List[object]]::new()
        $index=0
        foreach($itemValue in $values){
            $index++
            Assert-CpcLiveSimpleValue -Definition $Definition -Kind $elementKind -Value $itemValue -DisplayName "$($Spec.displayName) value $index"
            $settingValues.Add((New-CpcSimpleSettingValue -Kind $elementKind -Value $itemValue)) | Out-Null
        }
        return @{
            '@odata.type'='#microsoft.graph.deviceManagementConfigurationSimpleSettingCollectionInstance'
            settingDefinitionId=[string]$Definition.id
            simpleSettingCollectionValue=@($settingValues)
        }
    }

    if($type -match 'SimpleSettingDefinition$'){
        if($kind -notin @('integer','string')){throw "Value kind '$kind' is unsupported for simple definition '$($Spec.displayName)'."}
        $valueProperty=$valueSpec.PSObject.Properties['value']
        if(-not $valueProperty -or $null -eq $valueProperty.Value){throw "No simple value supplied for '$($Spec.displayName)'."}
        Assert-CpcLiveSimpleValue -Definition $Definition -Kind $kind -Value $valueProperty.Value -DisplayName ([string]$Spec.displayName)
        return @{
            '@odata.type'='#microsoft.graph.deviceManagementConfigurationSimpleSettingInstance'
            settingDefinitionId=[string]$Definition.id
            simpleSettingValue=(New-CpcSimpleSettingValue -Kind $kind -Value $valueProperty.Value)
        }
    }

    if($type -match 'SettingGroupCollectionDefinition$'){
        if($kind -ne 'group-collection'){throw "Value kind '$kind' does not match group collection definition '$($Spec.displayName)'."}
        $itemsProperty=$valueSpec.PSObject.Properties['items']
        $items=if($itemsProperty){@($itemsProperty.Value)}else{@()}
        if($items.Count -eq 0){throw "At least one group item is required for '$($Spec.displayName)'."}
        $groupValues=[System.Collections.Generic.List[object]]::new()
        $itemIndex=0
        foreach($item in $items){
            $itemIndex++
            $childrenProperty=$item.PSObject.Properties['children']
            $childSpecs=if($childrenProperty){@($childrenProperty.Value)}else{@()}
            if($childSpecs.Count -eq 0){throw "Group '$($Spec.displayName)' item $itemIndex requires at least one child."}
            $children=@(New-CpcConfigurationSettingInstances -Specs $childSpecs -Definitions $Definitions -DefinitionCache $DefinitionCache -Depth ($Depth+1) -Context "Group '$($Spec.displayName)' item $itemIndex")
            Assert-CpcRequiredChildDefinitions -Definition $Definition -Children $children -Context "Group '$($Spec.displayName)' item $itemIndex"
            $groupValues.Add(@{'@odata.type'='#microsoft.graph.deviceManagementConfigurationGroupSettingValue';children=@($children)}) | Out-Null
        }
        return @{
            '@odata.type'='#microsoft.graph.deviceManagementConfigurationGroupSettingCollectionInstance'
            settingDefinitionId=[string]$Definition.id
            groupSettingCollectionValue=@($groupValues)
        }
    }

    throw "Unsupported Settings Catalog definition type '$type' for '$($Spec.displayName)'. Leave the recommendation unresolved until this type is explicitly supported."
}

function New-CpcConfigurationSettingBody {
    param([Parameter(Mandatory)]$Definition,[Parameter(Mandatory)]$Spec,$Definitions=@(),[hashtable]$DefinitionCache)
    return @{
        '@odata.type'='#microsoft.graph.deviceManagementConfigurationSetting'
        settingInstance=(New-CpcConfigurationSettingInstance -Definition $Definition -Spec $Spec -Definitions $Definitions -DefinitionCache $DefinitionCache -Depth 0)
    }
}

function Get-CpcTopLevelSettingDefinitionId {
    param([Parameter(Mandatory)]$Setting)
    try { return [string]$Setting.settingInstance.settingDefinitionId } catch { return '' }
}

function Merge-CpcConfigurationSettings {
    param([Parameter(Mandatory)]$StaticSettings,[AllowNull()]$DynamicEntries)
    $merged = @($StaticSettings)
    foreach ($entry in @($DynamicEntries)) {
        if ($null -eq $entry -or $null -eq $entry.body) { continue }
        $dynamicId = Get-CpcTopLevelSettingDefinitionId -Setting $entry.body
        if ($dynamicId) { $merged = @($merged | Where-Object { (Get-CpcTopLevelSettingDefinitionId -Setting $_) -ne $dynamicId }) }
        $merged += $entry.body
    }
    return @($merged)
}

function ConvertTo-CpcWritablePayload {
    param([Parameter(Mandatory)]$InputObject)
    $blocked = @('@odata.context','@odata.etag','@odata.id','@odata.editLink','@odata.readLink','@odata.nextLink')

    function Convert-Node($node) {
        if ($null -eq $node) { return $null }
        if ($node -is [string] -or $node -is [ValueType]) { return $node }
        if ($node -is [System.Collections.IDictionary]) {
            $out = [ordered]@{}
            foreach ($key in $node.Keys) {
                $k = [string]$key
                if ($blocked -contains $k -or $k -match '@odata\.(associationLink|navigationLink|nextLink)$') { continue }
                $out[$k] = Convert-Node $node[$key]
            }
            return $out
        }
        if ($node -is [System.Collections.IEnumerable] -and -not ($node -is [string])) {
            # PowerShell normally unwraps empty and single-item arrays when a function
            # returns them. Graph distinguishes [] from null and [value] from value,
            # so preserve the collection object at every nested payload level.
            $items=[System.Collections.Generic.List[object]]::new()
            foreach($item in $node){$items.Add((Convert-Node $item)) | Out-Null}
            return ,$items.ToArray()
        }
        $out = [ordered]@{}
        foreach ($p in $node.PSObject.Properties) {
            $k = [string]$p.Name
            if ($blocked -contains $k -or $k -match '@odata\.(associationLink|navigationLink|nextLink)$') { continue }
            $out[$k] = Convert-Node $p.Value
        }
        return $out
    }
    return Convert-Node $InputObject
}

function New-CpcSettingsCatalogPolicyBody {
    param([Parameter(Mandatory)]$Policy,[Parameter(Mandatory)]$Settings)
    [object[]]$roleScopeTagIds=@('0')
    if ($Policy.PSObject.Properties['roleScopeTagIds']) {
        [object[]]$roleScopeTagIds=@($Policy.roleScopeTagIds)
    }
    if ($roleScopeTagIds.Count -eq 0) { [object[]]$roleScopeTagIds=@('0') }
    $body = [ordered]@{
        name=[string]$Policy.name
        description=[string]$Policy.description
        platforms=[string]$Policy.platforms
        technologies=[string]$Policy.technologies
        roleScopeTagIds=$roleScopeTagIds
        settings=(ConvertTo-CpcWritablePayload -InputObject @($Settings))
    }
    $templateProperty=$Policy.PSObject.Properties['templateReference']
    if ($templateProperty -and $templateProperty.Value -and $templateProperty.Value.templateId) {
        $body.templateReference = ConvertTo-CpcWritablePayload -InputObject $templateProperty.Value
    }
    return $body
}

function ConvertTo-CpcCanonicalObject {
    param([AllowNull()]$InputObject)

    function Convert-CanonicalNode($node) {
        if ($null -eq $node) { return $null }
        if ($node -is [string] -or $node -is [ValueType]) { return $node }
        if ($node -is [System.Collections.IDictionary]) {
            $out=[ordered]@{}
            [string[]]$keys=@($node.Keys | ForEach-Object { [string]$_ })
            [Array]::Sort($keys,[StringComparer]::Ordinal)
            foreach($key in $keys){$out[$key]=Convert-CanonicalNode $node[$key]}
            return $out
        }
        if ($node -is [System.Collections.IEnumerable] -and -not ($node -is [string])) {
            $items=[System.Collections.Generic.List[object]]::new()
            foreach($item in $node){$items.Add((Convert-CanonicalNode $item)) | Out-Null}
            return ,$items.ToArray()
        }
        $out=[ordered]@{}
        [string[]]$names=@($node.PSObject.Properties.Name | ForEach-Object { [string]$_ })
        [Array]::Sort($names,[StringComparer]::Ordinal)
        foreach($name in $names){$out[$name]=Convert-CanonicalNode $node.PSObject.Properties[$name].Value}
        return $out
    }

    return Convert-CanonicalNode $InputObject
}

function New-CpcSettingsCatalogPolicyFingerprint {
    param(
        [Parameter(Mandatory)]$Policy,
        [Parameter(Mandatory)][AllowEmptyCollection()]$Settings
    )

    function Get-RequiredProperty($node,[string]$name,[string]$context) {
        if ($null -eq $node) { throw "$context is null." }
        if ($node -is [System.Collections.IDictionary]) {
            if (-not $node.Contains($name)) { throw "$context is missing required property '$name'." }
            return $node[$name]
        }
        $property=$node.PSObject.Properties[$name]
        if (-not $property) { throw "$context is missing required property '$name'." }
        return $property.Value
    }

    function Get-OptionalProperty($node,[string]$name) {
        if ($null -eq $node) { return $null }
        if ($node -is [System.Collections.IDictionary]) {
            if ($node.Contains($name)) { return $node[$name] }
            return $null
        }
        $property=$node.PSObject.Properties[$name]
        if ($property) { return $property.Value }
        return $null
    }

    function Convert-ComparableSettingNode($node) {
        if ($null -eq $node) { return $null }
        if ($node -is [string] -or $node -is [ValueType]) { return $node }
        if ($node -is [System.Collections.IEnumerable] -and -not ($node -is [string]) -and -not ($node -is [System.Collections.IDictionary])) {
            $items=[System.Collections.Generic.List[object]]::new()
            foreach($item in $node){$items.Add((Convert-ComparableSettingNode $item)) | Out-Null}
            return ,$items.ToArray()
        }

        $isDictionary=$node -is [System.Collections.IDictionary]
        [string[]]$names=if($isDictionary){@($node.Keys | ForEach-Object {[string]$_})}else{@($node.PSObject.Properties.Name | ForEach-Object {[string]$_})}
        $hasSettingDefinitionId=if($isDictionary){$node.Contains('settingDefinitionId')}else{$null -ne $node.PSObject.Properties['settingDefinitionId']}
        $out=[ordered]@{}
        foreach($name in $names){
            $value=if($isDictionary){$node[$name]}else{$node.PSObject.Properties[$name].Value}
            # Graph adds service IDs and null response metadata after creation. It also
            # omits @odata.type on setting/value wrappers while retaining it on the
            # semantic setting instances. Normalize only those proven response-shape
            # differences; exact instance types, definition IDs, values, and children
            # remain part of the fingerprint.
            if($name -ceq 'id' -or $null -eq $value){continue}
            if($name -ceq '@odata.type' -and -not $hasSettingDefinitionId){continue}
            $out[$name]=Convert-ComparableSettingNode $value
        }
        return $out
    }

    [string[]]$roleScopeTagIds=@(Get-RequiredProperty $Policy 'roleScopeTagIds' 'Settings Catalog policy' | ForEach-Object { [string]$_ })
    if ($roleScopeTagIds.Count -eq 0 -or @($roleScopeTagIds | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
        throw 'Settings Catalog policy roleScopeTagIds must contain only non-empty IDs.'
    }
    [Array]::Sort($roleScopeTagIds,[StringComparer]::Ordinal)

    $templateReference=$null
    $rawTemplate=Get-OptionalProperty $Policy 'templateReference'
    if ($rawTemplate) {
        $templateId=[string](Get-OptionalProperty $rawTemplate 'templateId')
        if (-not [string]::IsNullOrWhiteSpace($templateId)) {
            $templateReference=[ordered]@{templateId=$templateId}
        }
    }

    $settingsByDefinitionId=[System.Collections.Generic.SortedDictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach($setting in @($Settings)) {
        if ($null -eq $setting) { throw 'Settings Catalog policy contains a null setting.' }
        $definitionId=Get-CpcTopLevelSettingDefinitionId -Setting $setting
        if ([string]::IsNullOrWhiteSpace($definitionId)) { throw 'Settings Catalog policy contains a setting without a top-level settingDefinitionId.' }
        if ($settingsByDefinitionId.ContainsKey($definitionId)) { throw "Settings Catalog policy contains duplicate top-level settingDefinitionId '$definitionId'." }
        $writable=ConvertTo-CpcWritablePayload -InputObject $setting
        if (-not ($writable -is [System.Collections.IDictionary])) { throw "Settings Catalog setting '$definitionId' is not an object." }
        $comparableSetting=Convert-ComparableSettingNode $writable
        $settingsByDefinitionId.Add($definitionId,(ConvertTo-CpcCanonicalObject $comparableSetting))
    }

    $canonicalSettings=[System.Collections.Generic.List[object]]::new()
    foreach($entry in $settingsByDefinitionId.GetEnumerator()){$canonicalSettings.Add($entry.Value) | Out-Null}
    $comparable=[ordered]@{
        name=[string](Get-RequiredProperty $Policy 'name' 'Settings Catalog policy')
        description=[string](Get-RequiredProperty $Policy 'description' 'Settings Catalog policy')
        platforms=[string](Get-RequiredProperty $Policy 'platforms' 'Settings Catalog policy')
        technologies=[string](Get-RequiredProperty $Policy 'technologies' 'Settings Catalog policy')
        roleScopeTagIds=@($roleScopeTagIds)
        templateReference=$templateReference
        settings=@($canonicalSettings)
    }
    $json=$comparable | ConvertTo-Json -Depth 100 -Compress
    $sha=[Security.Cryptography.SHA256]::Create()
    try {$hash=[Convert]::ToHexString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($json))).ToLowerInvariant()}
    finally {$sha.Dispose()}
    return [pscustomobject]@{sha256=$hash;settingCount=$canonicalSettings.Count}
}

function Compare-CpcSettingsCatalogPolicy {
    param(
        [Parameter(Mandatory)]$ExpectedPolicy,
        [Parameter(Mandatory)]$ActualPolicy,
        [Parameter(Mandatory)][AllowEmptyCollection()]$ActualSettings
    )
    $expectedSettings=if($ExpectedPolicy -is [System.Collections.IDictionary]){$ExpectedPolicy['settings']}else{$ExpectedPolicy.settings}
    $expected=New-CpcSettingsCatalogPolicyFingerprint -Policy $ExpectedPolicy -Settings @($expectedSettings)
    $actual=New-CpcSettingsCatalogPolicyFingerprint -Policy $ActualPolicy -Settings @($ActualSettings)
    return [pscustomobject]@{
        equivalent=([string]$expected.sha256 -ceq [string]$actual.sha256)
        expectedSha256=[string]$expected.sha256
        actualSha256=[string]$actual.sha256
        expectedSettingCount=[int]$expected.settingCount
        actualSettingCount=[int]$actual.settingCount
    }
}

function Get-CpcGraphObjectContract {
    param(
        [Parameter(Mandatory)][string]$ContractId,
        [Parameter(Mandatory)][string]$RepoRoot,
        [string]$ExpectedSha256
    )
    $contractRoot=Join-Path $RepoRoot 'contracts\graph'
    if(-not (Test-Path -LiteralPath $contractRoot -PathType Container)){throw "Graph contract directory is missing: $contractRoot"}
    $matches=[System.Collections.Generic.List[object]]::new()
    foreach($file in Get-ChildItem -LiteralPath $contractRoot -Filter '*.json' -File){
        try {$contract=Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json -Depth 100}
        catch {throw "Graph contract '$($file.FullName)' is invalid JSON: $($_.Exception.Message)"}
        if([string]$contract.id -ceq $ContractId){$matches.Add([pscustomobject]@{Path=$file.FullName;Contract=$contract}) | Out-Null}
    }
    if($matches.Count -ne 1){throw "Graph contract '$ContractId' did not resolve exactly once; matches=$($matches.Count)."}
    $schemaPath=Join-Path $RepoRoot 'schemas\graph-object-contract.schema.json'
    $raw=Get-Content -LiteralPath $matches[0].Path -Raw
    if(-not ($raw | Test-Json -SchemaFile $schemaPath -ErrorAction Stop)){throw "Graph contract '$ContractId' failed schema validation."}
    $hash=(Get-FileHash -LiteralPath $matches[0].Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if($ExpectedSha256 -and $hash -cne $ExpectedSha256){throw "Graph contract '$ContractId' hash differs from the pack binding."}
    $contract=$matches[0].Contract
    foreach($uri in @([string]$contract.endpoint,[string]$contract.listEndpoint,([string]$contract.itemEndpointTemplate).Replace('{id}','contract-validation-id'))){
        if(-not (Test-CpcGraphEndpointSafe -Uri $uri)){throw "Graph contract '$ContractId' contains an unsafe endpoint."}
    }
    return [pscustomobject]@{Path=$matches[0].Path;Sha256=$hash;Contract=$contract}
}

function Assert-CpcGraphObjectMatchesContract {
    param(
        [Parameter(Mandatory)]$GraphObject,
        [Parameter(Mandatory)]$Contract
    )

    function Get-ContractProperty($node,[string]$name,[switch]$Required){
        $property=if($node -is [System.Collections.IDictionary]){
            if($node.Contains($name)){[pscustomobject]@{Value=$node[$name]}}else{$null}
        }else{$node.PSObject.Properties[$name]}
        if($Required -and -not $property){throw "Graph object is missing required property '$name'."}
        if($property){return $property.Value}
        return $null
    }

    $name=[string](Get-ContractProperty $GraphObject 'name' -Required)
    $endpoint=[string](Get-ContractProperty $GraphObject 'endpoint' -Required)
    $listEndpoint=[string](Get-ContractProperty $GraphObject 'listEndpoint')
    if([string]::IsNullOrWhiteSpace($listEndpoint)){$listEndpoint=$endpoint}
    $nameProperty=[string](Get-ContractProperty $GraphObject 'nameProperty')
    if([string]::IsNullOrWhiteSpace($nameProperty)){$nameProperty='displayName'}
    if($endpoint -cne [string]$Contract.endpoint){throw "Graph object '$name' endpoint differs from its pinned contract."}
    if($listEndpoint -cne [string]$Contract.listEndpoint){throw "Graph object '$name' listEndpoint differs from its pinned contract."}
    if($nameProperty -cne [string]$Contract.nameProperty){throw "Graph object '$name' nameProperty differs from its pinned contract."}

    $payload=Get-ContractProperty $GraphObject 'payload' -Required
    if($payload -isnot [System.Collections.IDictionary] -and $payload -isnot [pscustomobject]){throw "Graph object '$name' payload must be an object."}
    $payloadNames=if($payload -is [System.Collections.IDictionary]){@($payload.Keys | ForEach-Object {[string]$_})}else{@($payload.PSObject.Properties.Name | ForEach-Object {[string]$_})}
    $contractNames=@($Contract.properties.PSObject.Properties.Name | ForEach-Object {[string]$_})
    $unexpected=@($payloadNames | Where-Object {$contractNames -cnotcontains [string]$_})
    if($unexpected.Count -gt 0){throw "Graph object '$name' contains properties absent from contract '$($Contract.id)': $($unexpected -join ', ')."}

    foreach($contractProperty in $Contract.properties.PSObject.Properties){
        $propertyName=[string]$contractProperty.Name
        $rule=$contractProperty.Value
        $payloadProperty=if($payload -is [System.Collections.IDictionary]){
            if($payload.Contains($propertyName)){[pscustomobject]@{Value=$payload[$propertyName]}}else{$null}
        }else{$payload.PSObject.Properties[$propertyName]}
        if($rule.required -eq $true -and -not $payloadProperty){throw "Graph object '$name' is missing contract-required payload property '$propertyName'."}
        if(-not $payloadProperty){continue}
        $value=$payloadProperty.Value
        switch([string]$rule.type){
            'boolean' {if($value -isnot [bool]){throw "Graph object '$name' payload property '$propertyName' must be boolean."}}
            'integer' {if($value -isnot [byte] -and $value -isnot [int16] -and $value -isnot [int32] -and $value -isnot [int64]){throw "Graph object '$name' payload property '$propertyName' must be integer."}}
            'string' {if($value -isnot [string]){throw "Graph object '$name' payload property '$propertyName' must be string."}}
            default {throw "Graph contract '$($Contract.id)' has unsupported type '$($rule.type)'."}
        }
        $constProperty=$rule.PSObject.Properties['const']
        if($constProperty -and $value -cne $constProperty.Value){throw "Graph object '$name' payload property '$propertyName' differs from its contract constant."}
        $enumProperty=$rule.PSObject.Properties['enum']
        if($enumProperty -and @($enumProperty.Value | Where-Object {$_ -ceq $value}).Count -ne 1){throw "Graph object '$name' payload property '$propertyName' is outside its contract enum."}
        $minimumProperty=$rule.PSObject.Properties['minimum']
        $maximumProperty=$rule.PSObject.Properties['maximum']
        if($minimumProperty -and [int64]$value -lt [int64]$minimumProperty.Value){throw "Graph object '$name' payload property '$propertyName' is below its contract minimum."}
        if($maximumProperty -and [int64]$value -gt [int64]$maximumProperty.Value){throw "Graph object '$name' payload property '$propertyName' is above its contract maximum."}
        $minLengthProperty=$rule.PSObject.Properties['minLength']
        $maxLengthProperty=$rule.PSObject.Properties['maxLength']
        if($minLengthProperty -and ([string]$value).Length -lt [int]$minLengthProperty.Value){throw "Graph object '$name' payload property '$propertyName' is shorter than its contract minimum."}
        if($maxLengthProperty -and ([string]$value).Length -gt [int]$maxLengthProperty.Value){throw "Graph object '$name' payload property '$propertyName' is longer than its contract maximum."}
    }
    $payloadName=if($payload -is [System.Collections.IDictionary]){$payload[$nameProperty]}else{$payload.PSObject.Properties[$nameProperty].Value}
    if([string]$payloadName -cne $name){throw "Graph object '$name' payload name does not exactly match its object name."}
    $odataType=if($payload -is [System.Collections.IDictionary]){$payload['@odata.type']}else{$payload.PSObject.Properties['@odata.type'].Value}
    if([string]$odataType -cne [string]$Contract.odataType){throw "Graph object '$name' @odata.type differs from its pinned contract."}
}

function Compare-CpcGenericGraphObject {
    param(
        [Parameter(Mandatory)]$ExpectedPayload,
        [Parameter(Mandatory)]$ActualPayload,
        [Parameter(Mandatory)]$Contract
    )
    $expectedWritable=ConvertTo-CpcWritablePayload -InputObject $ExpectedPayload
    $actualWritable=ConvertTo-CpcWritablePayload -InputObject $ActualPayload
    $actualProjection=[ordered]@{}
    foreach($key in $expectedWritable.Keys){
        if(-not $actualWritable.Contains($key)){
            return [pscustomobject]@{equivalent=$false;expectedSha256=$null;actualSha256=$null;detail="Existing object is missing expected property '$key'."}
        }
        $actualProjection[$key]=$actualWritable[$key]
    }
    $expectedCanonical=ConvertTo-CpcCanonicalObject $expectedWritable
    $actualCanonical=ConvertTo-CpcCanonicalObject $actualProjection
    $expectedJson=$expectedCanonical | ConvertTo-Json -Depth 100 -Compress
    $actualJson=$actualCanonical | ConvertTo-Json -Depth 100 -Compress
    $sha=[Security.Cryptography.SHA256]::Create()
    try {
        $expectedHash=[Convert]::ToHexString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($expectedJson))).ToLowerInvariant()
        $sha.Initialize()
        $actualHash=[Convert]::ToHexString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($actualJson))).ToLowerInvariant()
    } finally {$sha.Dispose()}
    return [pscustomobject]@{
        equivalent=($expectedHash -ceq $actualHash)
        expectedSha256=$expectedHash
        actualSha256=$actualHash
        detail=if($expectedHash -ceq $actualHash){'Exact expected-property subset match.'}else{'Expected-property subset differs.'}
    }
}

function Get-CpcGraphObjectItemUri {
    param([Parameter(Mandatory)]$Contract,[Parameter(Mandatory)][string]$Id)
    if([string]::IsNullOrWhiteSpace($Id)){throw 'Cannot create a Graph item URI from an empty object ID.'}
    $uri=([string]$Contract.itemEndpointTemplate).Replace('{id}',[Uri]::EscapeDataString($Id))
    if(-not (Test-CpcGraphEndpointSafe -Uri $uri)){throw "Pinned Graph item endpoint produced an unsafe URI."}
    return $uri
}

function Assert-CpcNoGenericGraphObjectCollision {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowEmptyCollection()]$ExistingObjects
    )
    $matches=@($ExistingObjects | Where-Object { $null -ne $_ })
    if($matches.Count -eq 0){return}
    $ids=@($matches | ForEach-Object { if($_.id){[string]$_.id}else{'<missing-id>'} }) -join ', '
    throw "Found $($matches.Count) existing generic Graph object(s) named '$Name' (IDs: $ids). The endpoint-agnostic importer cannot prove their content equivalent to the pack."
}

function Test-CpcProfileSelected {
    param([Parameter(Mandatory)]$Profiles,[Parameter(Mandatory)][string]$Selector)
    $p=@($Profiles | ForEach-Object { ([string]$_).ToUpperInvariant() })
    switch ($Selector.ToUpperInvariant()) {
        'L1BL' { return ($p -contains 'L1' -or $p -contains 'BL') }
        'L1'   { return ($p -contains 'L1') }
        'L2'   { return ($p -contains 'L1' -or $p -contains 'L2') }
        'BL'   { return ($p -contains 'BL') }
        'ALL'  { return $true }
        default { return ($p -contains $Selector.ToUpperInvariant()) }
    }
}

function Test-CpcGraphEndpointSafe {
    param([Parameter(Mandatory)][string]$Uri)
    try { $parsed=[Uri]$Uri } catch { return $false }
    if (-not $parsed.IsAbsoluteUri -or $parsed.Scheme -cne 'https' -or $parsed.Host -cne 'graph.microsoft.com' -or -not $parsed.IsDefaultPort -or $parsed.UserInfo -or $parsed.Fragment) { return $false }
    $path=[Uri]::UnescapeDataString($parsed.AbsolutePath)
    if ($path.Contains('%')) { return $false }
    if ($path -notmatch '^/(beta|v1\.0)/deviceManagement(?:/|$)') { return $false }
    $segments=@($path.Split('/',[StringSplitOptions]::RemoveEmptyEntries))
    if (@($segments | Where-Object { $_ -in @('.','..') }).Count -gt 0) { return $false }
    if (@($segments | Where-Object { $_ -in @('assign','assignment','assignments') }).Count -gt 0) { return $false }
    return $true
}

function Test-CpcObjectContainsAssignments {
    param([Parameter(Mandatory)]$InputObject)
    function Has-Assignments($node) {
        if ($null -eq $node -or $node -is [string] -or $node -is [ValueType]) { return $false }
        if ($node -is [System.Collections.IDictionary]) {
            foreach ($key in $node.Keys) {
                if ([string]$key -imatch '^assignments?(?:@|$)') { return $true }
                if (Has-Assignments $node[$key]) { return $true }
            }
            return $false
        }
        if ($node -is [System.Collections.IEnumerable] -and -not ($node -is [string])) {
            foreach ($item in $node) { if (Has-Assignments $item) { return $true } }
            return $false
        }
        foreach ($p in $node.PSObject.Properties) {
            if ($p.Name -imatch '^assignments?(?:@|$)') { return $true }
            if (Has-Assignments $p.Value) { return $true }
        }
        return $false
    }
    return Has-Assignments $InputObject
}

Export-ModuleMember -Function *-Cpc*
