Set-StrictMode -Version Latest

function Add-CpcResult {
    param(
        [Parameter(Mandatory)][System.Collections.Generic.List[object]]$Results,
        [Parameter(Mandatory)][string]$Stage,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Status,
        [string]$Detail = ''
    )
    $Results.Add([pscustomobject]@{ stage=$Stage; name=$Name; status=$Status; detail=$Detail })
}

function Invoke-CpcGraphPaged {
    param([Parameter(Mandatory)][string]$Uri)
    $items = @()
    $next = $Uri
    while ($next) {
        $r = Invoke-MgGraphRequest -Method GET -Uri $next
        if ($null -ne $r.value) {
            $items += @($r.value)
            $next = $r.'@odata.nextLink'
        } else {
            $items += $r
            $next = $null
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
    param([Parameter(Mandatory)]$Spec,[Parameter(Mandatory)]$Definitions)

    if ($Spec.resolve.definitionId) {
        $encodedDefinitionId=[Uri]::EscapeDataString([string]$Spec.resolve.definitionId)
        try { $def = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceManagement/configurationSettings/$encodedDefinitionId" }
        catch { throw "Could not read explicit Settings Catalog definition '$($Spec.resolve.definitionId)' for '$($Spec.displayName)': $(Get-CpcGraphErrorDetail $_)" }
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
    }
    $definitionBaseUri=if ($def.PSObject.Properties['baseUri']) { [string]$def.baseUri } else { $null }
    $definitionOffsetUri=if ($def.PSObject.Properties['offsetUri']) { [string]$def.offsetUri } else { $null }
    if ($Spec.resolve.baseUri -and (Normalize-CpcCspPath $definitionBaseUri) -ne (Normalize-CpcCspPath $Spec.resolve.baseUri)) {
        throw "Definition '$($def.id)' baseUri does not match the reviewed resolver for '$($Spec.displayName)'."
    }
    if ($Spec.resolve.offsetUri -and ([string]$definitionOffsetUri).Trim() -ine ([string]$Spec.resolve.offsetUri).Trim()) {
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
    }
    return $def
}

function New-CpcConfigurationSettingBody {
    param([Parameter(Mandatory)]$Definition,[Parameter(Mandatory)]$Spec)

    $type = [string]$Definition.'@odata.type'
    $valueSpec = $Spec.value

    if ($type -match 'ChoiceSettingDefinition') {
        if ([string]$valueSpec.kind -ne 'choice') { throw "Value kind '$($valueSpec.kind)' does not match choice definition '$($Spec.displayName)'." }
        $options = @($Definition.options)
        if ($options.Count -eq 0) { throw "No choice options returned for '$($Spec.displayName)'." }
        if (-not $valueSpec.optionId) { throw "An exact reviewed optionId is required for choice setting '$($Spec.displayName)'." }
        $candidate = @($options | Where-Object { [string]$_.itemId -ceq [string]$valueSpec.optionId })
        if ($candidate.Count -ne 1) {
            $available = ($options | ForEach-Object { "$($_.itemId) [$($_.displayName)]" }) -join '; '
            throw "Exact choice optionId '$($valueSpec.optionId)' was not uniquely present for '$($Spec.displayName)'. Available: $available"
        }
        $choice = $candidate[0]
        return @{
            '@odata.type'='#microsoft.graph.deviceManagementConfigurationSetting'
            settingInstance=@{
                '@odata.type'='#microsoft.graph.deviceManagementConfigurationChoiceSettingInstance'
                settingDefinitionId=$Definition.id
                choiceSettingValue=@{
                    '@odata.type'='#microsoft.graph.deviceManagementConfigurationChoiceSettingValue'
                    value=$choice.itemId
                    children=@()
                }
            }
        }
    }

    if ($type -match 'SimpleSettingDefinition') {
        $kind = [string]$valueSpec.kind
        if ($kind -notin @('integer','string')) { throw "Value kind '$kind' is unsupported for simple definition '$($Spec.displayName)'." }
        if ($null -eq $valueSpec.value) { throw "No simple value supplied for '$($Spec.displayName)'." }
        $valueDefinitionProperty=$Definition.PSObject.Properties['valueDefinition']
        $valueDefinition=if ($valueDefinitionProperty) { $valueDefinitionProperty.Value } else { $null }
        if ($kind -eq 'integer' -and $valueDefinition) {
            $minimumProperty=$valueDefinition.PSObject.Properties['minimumValue']
            $maximumProperty=$valueDefinition.PSObject.Properties['maximumValue']
            if ($minimumProperty -and [int64]$valueSpec.value -lt [int64]$minimumProperty.Value) { throw "Value for '$($Spec.displayName)' is below the live definition minimum." }
            if ($maximumProperty -and [int64]$valueSpec.value -gt [int64]$maximumProperty.Value) { throw "Value for '$($Spec.displayName)' is above the live definition maximum." }
        }
        if ($kind -eq 'string' -and $valueDefinition) {
            $minimumLengthProperty=$valueDefinition.PSObject.Properties['minimumLength']
            $maximumLengthProperty=$valueDefinition.PSObject.Properties['maximumLength']
            if ($minimumLengthProperty -and ([string]$valueSpec.value).Length -lt [int]$minimumLengthProperty.Value) { throw "Value for '$($Spec.displayName)' is shorter than the live definition minimumLength." }
            if ($maximumLengthProperty -and ([string]$valueSpec.value).Length -gt [int]$maximumLengthProperty.Value) { throw "Value for '$($Spec.displayName)' is longer than the live definition maximumLength." }
        }
        $simpleValue = if ($kind -eq 'integer') {
            @{ '@odata.type'='#microsoft.graph.deviceManagementConfigurationIntegerSettingValue'; value=[int64]$valueSpec.value }
        } else {
            @{ '@odata.type'='#microsoft.graph.deviceManagementConfigurationStringSettingValue'; value=[string]$valueSpec.value }
        }
        return @{
            '@odata.type'='#microsoft.graph.deviceManagementConfigurationSetting'
            settingInstance=@{
                '@odata.type'='#microsoft.graph.deviceManagementConfigurationSimpleSettingInstance'
                settingDefinitionId=$Definition.id
                simpleSettingValue=$simpleValue
            }
        }
    }

    throw "Unsupported Settings Catalog definition type '$type' for '$($Spec.displayName)'. Leave the recommendation unresolved until this type is explicitly supported."
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
            return @($node | ForEach-Object { Convert-Node $_ })
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
    $body = [ordered]@{
        name=[string]$Policy.name
        description=[string]$Policy.description
        platforms=[string]$Policy.platforms
        technologies=[string]$Policy.technologies
        roleScopeTagIds=if ($Policy.PSObject.Properties['roleScopeTagIds']) { @($Policy.roleScopeTagIds) } else { @('0') }
        settings=@(ConvertTo-CpcWritablePayload -InputObject @($Settings))
    }
    if (@($body.roleScopeTagIds).Count -eq 0) { $body.roleScopeTagIds=@('0') }
    $templateProperty=$Policy.PSObject.Properties['templateReference']
    if ($templateProperty -and $templateProperty.Value -and $templateProperty.Value.templateId) {
        $body.templateReference = ConvertTo-CpcWritablePayload -InputObject $templateProperty.Value
    }
    return $body
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
