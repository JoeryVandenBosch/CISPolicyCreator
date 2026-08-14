[CmdletBinding()]
param(
    [string]$TenantId,
    [string]$Search,
    [string]$OutputPath = (Join-Path $PWD "settings-catalog-diagnostics-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"),
    [switch]$UseDeviceCode,
    [ValidateRange(1,500)][int]$PageSize=500
)
$ErrorActionPreference = 'Stop'
if (Test-Path -LiteralPath $OutputPath) { throw "OutputPath already exists: $OutputPath" }
if (-not (Get-Module -ListAvailable Microsoft.Graph.Authentication)) { throw 'Install Microsoft.Graph.Authentication first.' }
Import-Module Microsoft.Graph.Authentication
Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
$args = @{ Scopes='DeviceManagementConfiguration.Read.All'; ContextScope='Process'; NoWelcome=$true }
if ($TenantId) { $args.TenantId=$TenantId }
if ($UseDeviceCode) { $args.UseDeviceCode=$true }
Connect-MgGraph @args
try {
    $context=Get-MgContext
    $collectionUri='https://graph.microsoft.com/beta/deviceManagement/configurationSettings'
    $items=[System.Collections.Generic.List[object]]::new()
    $seenIds=[System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $next=$collectionUri+'?$top='+$PageSize
    $pageCount=0
    $usedODataNextLink=$false
    $usedSkipFallback=$false
    while ($next) {
        $pageCount++
        if ($pageCount -gt 1000) { throw 'Settings Catalog pagination exceeded 1000 pages; refusing an unbounded export.' }
        $r=Invoke-MgGraphRequest -Method GET -Uri $next
        $pageItems=@($r.value)
        foreach($item in $pageItems){
            $id=[string]$item.id
            if(-not $id){throw "Settings Catalog page $pageCount returned a definition without an ID."}
            if(-not $seenIds.Add($id)){throw "Settings Catalog pagination returned duplicate definition ID '$id'; completeness cannot be proven."}
            $items.Add($item)
        }
        Write-Host "Retrieved Settings Catalog page $pageCount ($($pageItems.Count) definitions; $($items.Count) total)."
        $serverNext=[string]$r.'@odata.nextLink'
        if($serverNext){
            $usedODataNextLink=$true
            $next=$serverNext
        } elseif($pageItems.Count -eq $PageSize) {
            $usedSkipFallback=$true
            $next=$collectionUri+'?$top='+$PageSize+'&$skip='+$items.Count
        } else {
            $next=$null
        }
    }
    if ($Search) {
        $needle=$Search.ToLowerInvariant()
        $items=@($items | Where-Object {
            (([string]$_.id)+' '+([string]$_.displayName)+' '+([string]$_.baseUri)+' '+([string]$_.offsetUri)).ToLowerInvariant().Contains($needle)
        })
    }
    $snapshot=[ordered]@{
        schemaVersion='1.1'
        apiVersion='beta'
        capturedAt=(Get-Date).ToUniversalTime().ToString('o')
        tenantId=[string]$context.TenantId
        retrieval=[ordered]@{
            collectionUri=$collectionUri
            pageSize=$PageSize
            pageCount=$pageCount
            definitionCount=@($items).Count
            usedODataNextLink=$usedODataNextLink
            usedSkipFallback=$usedSkipFallback
        }
        definitions=@($items | ForEach-Object {
            [ordered]@{
                id=[string]$_.id; displayName=[string]$_.displayName; baseUri=$_.baseUri; offsetUri=$_.offsetUri
                '@odata.type'=[string]$_.'@odata.type'; options=@($_.options); valueDefinition=$_.valueDefinition
            }
        })
    }
    $snapshotJson=$snapshot | ConvertTo-Json -Depth 30
    $snapshotSchema=Join-Path (Split-Path -Parent $PSScriptRoot) 'schemas\settings-catalog-snapshot.schema.json'
    if (-not ($snapshotJson | Test-Json -SchemaFile $snapshotSchema -ErrorAction Stop)) { throw 'Generated Settings Catalog snapshot failed schema validation.' }
    $snapshotJson | Set-Content -LiteralPath $OutputPath -Encoding utf8
    Write-Host "Wrote $(@($items).Count) definition(s): $OutputPath"
}
finally { Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null }
