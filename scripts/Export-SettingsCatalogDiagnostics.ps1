[CmdletBinding()]
param(
    [string]$TenantId,
    [string]$Search,
    [string]$OutputPath = (Join-Path $PWD "settings-catalog-diagnostics-$(Get-Date -Format 'yyyyMMdd-HHmmss').json")
)
$ErrorActionPreference = 'Stop'
if (Test-Path -LiteralPath $OutputPath) { throw "OutputPath already exists: $OutputPath" }
if (-not (Get-Module -ListAvailable Microsoft.Graph.Authentication)) { throw 'Install Microsoft.Graph.Authentication first.' }
Import-Module Microsoft.Graph.Authentication
Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
$args = @{ Scopes='DeviceManagementConfiguration.Read.All'; ContextScope='Process'; NoWelcome=$true }
if ($TenantId) { $args.TenantId=$TenantId }
Connect-MgGraph @args
try {
    $context=Get-MgContext
    $items=@(); $next='https://graph.microsoft.com/beta/deviceManagement/configurationSettings?$top=500'
    while ($next) {
        $r=Invoke-MgGraphRequest -Method GET -Uri $next
        $items += @($r.value)
        $next=$r.'@odata.nextLink'
    }
    if ($Search) {
        $needle=$Search.ToLowerInvariant()
        $items=@($items | Where-Object {
            (([string]$_.id)+' '+([string]$_.displayName)+' '+([string]$_.baseUri)+' '+([string]$_.offsetUri)).ToLowerInvariant().Contains($needle)
        })
    }
    $snapshot=[ordered]@{
        schemaVersion='1.0'
        apiVersion='beta'
        capturedAt=(Get-Date).ToUniversalTime().ToString('o')
        tenantId=[string]$context.TenantId
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
