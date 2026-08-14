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

function Get-CpcCandidateSettingId {
    param([Parameter(Mandatory)]$Spec)
    $base = Normalize-CpcCspPath $Spec.resolve.baseUri
    $baseId = $base -replace '[^a-z0-9]+','_'
    $offsetId = ([string]$Spec.resolve.offsetUri).Trim().ToLowerInvariant() -replace '[^a-z0-9]+','_'
    return "${baseId}_${offsetId}"
}

function Get-CpcSettingDefinition {
    param([Parameter(Mandatory)]$Spec,[Parameter(Mandatory)]$Definitions)

    if ($Spec.resolve.definitionId) {
        try { return Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceManagement/configurationSettings/$($Spec.resolve.definitionId)" }
        catch { throw "Could not read explicit Settings Catalog definition '$($Spec.resolve.definitionId)' for '$($Spec.displayName)': $(Get-CpcGraphErrorDetail $_)" }
    }

    $base = Normalize-CpcCspPath $Spec.resolve.baseUri
    $offset = ([string]$Spec.resolve.offsetUri).Trim().ToLowerInvariant()
    $matches = @()
    if ($base -and $offset) {
        $matches = @($Definitions | Where-Object {
            (Normalize-CpcCspPath $_.baseUri) -eq $base -and ([string]$_.offsetUri).Trim().ToLowerInvariant() -eq $offset
        })
    }
    if ($matches.Count -eq 0 -and $Spec.resolve.displayName) {
        $needle = ([string]$Spec.resolve.displayName).Trim().ToLowerInvariant()
        $matches = @($Definitions | Where-Object { ([string]$_.displayName).Trim().ToLowerInvariant() -eq $needle })
    }
    if ($matches.Count -ne 1 -and $base -and $offset) {
        $candidateId = Get-CpcCandidateSettingId -Spec $Spec
        try {
            $direct = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceManagement/configurationSettings/$candidateId"
            if ($direct -and $direct.id) { $matches = @($direct) }
        } catch {}
    }
    if ($matches.Count -ne 1) { throw "Could not uniquely resolve Settings Catalog definition for '$($Spec.displayName)'. Matches=$($matches.Count)." }

    $def = $matches[0]
    if (([string]$def.'@odata.type') -match 'ChoiceSettingDefinition' -and @($def.options).Count -eq 0) {
        $def = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceManagement/configurationSettings/$($def.id)"
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
        $choice = $null
        if ($valueSpec.optionId) {
            $candidate = @($options | Where-Object { [string]$_.itemId -eq [string]$valueSpec.optionId })
            if ($candidate.Count -eq 1) { $choice = $candidate[0] }
        }
        if (-not $choice -and $valueSpec.contains) {
            $needle = ([string]$valueSpec.contains).ToLowerInvariant()
            $exclude = if ($valueSpec.exclude) { ([string]$valueSpec.exclude).ToLowerInvariant() } else { $null }
            $candidate = @($options | Where-Object {
                $text = (([string]$_.displayName)+' '+([string]$_.name)+' '+([string]$_.description)+' '+([string]$_.itemId)).ToLowerInvariant()
                ($text -like "*$needle*") -and (-not $exclude -or $text -notlike "*$exclude*")
            })
            if ($candidate.Count -eq 1) { $choice = $candidate[0] }
        }
        if (-not $choice -and $valueSpec.optionSuffix) {
            $suffix = [string]$valueSpec.optionSuffix
            $candidate = @($options | Where-Object { ([string]$_.itemId).EndsWith($suffix,[System.StringComparison]::OrdinalIgnoreCase) })
            if ($candidate.Count -eq 1) { $choice = $candidate[0] }
        }
        if (-not $choice) {
            $available = ($options | ForEach-Object { "$($_.itemId) [$($_.displayName)]" }) -join '; '
            throw "Could not select choice '$($valueSpec.desired)' for '$($Spec.displayName)'. Available: $available"
        }
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
        $simpleValue = if ($kind -eq 'integer') {
            @{ '@odata.type'='#microsoft.graph.deviceManagementConfigurationIntegerSettingValue'; value=[int]$valueSpec.value }
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
        roleScopeTagIds=@($Policy.roleScopeTagIds)
        settings=@(ConvertTo-CpcWritablePayload -InputObject @($Settings))
    }
    if (@($body.roleScopeTagIds).Count -eq 0) { $body.roleScopeTagIds=@('0') }
    if ($Policy.templateReference -and $Policy.templateReference.templateId) {
        $body.templateReference = ConvertTo-CpcWritablePayload -InputObject $Policy.templateReference
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
    if ($Uri -notmatch '^https://graph\.microsoft\.com/(beta|v1\.0)/deviceManagement(?:/|\?|$)') { return $false }
    if ($Uri -match '/assign(?:ments)?(?:\?|$|/)') { return $false }
    return $true
}

function Test-CpcObjectContainsAssignments {
    param([Parameter(Mandatory)]$InputObject)
    function Has-Assignments($node) {
        if ($null -eq $node -or $node -is [string] -or $node -is [ValueType]) { return $false }
        if ($node -is [System.Collections.IDictionary]) {
            foreach ($key in $node.Keys) {
                if ([string]$key -ieq 'assignments') { return $true }
                if (Has-Assignments $node[$key]) { return $true }
            }
            return $false
        }
        if ($node -is [System.Collections.IEnumerable] -and -not ($node -is [string])) {
            foreach ($item in $node) { if (Has-Assignments $item) { return $true } }
            return $false
        }
        foreach ($p in $node.PSObject.Properties) {
            if ($p.Name -ieq 'assignments') { return $true }
            if (Has-Assignments $p.Value) { return $true }
        }
        return $false
    }
    return Has-Assignments $InputObject
}

Export-ModuleMember -Function *-Cpc*
