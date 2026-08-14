[CmdletBinding()]
param(
    [string]$TenantId,
    [string]$Search,
    [string]$OutputPath = (Join-Path $PWD "settings-catalog-diagnostics-$(Get-Date -Format 'yyyyMMdd-HHmmss').json")
)
$ErrorActionPreference = 'Stop'
if (-not (Get-Module -ListAvailable Microsoft.Graph.Authentication)) { throw 'Install Microsoft.Graph.Authentication first.' }
Import-Module Microsoft.Graph.Authentication
Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
$args = @{ Scopes='DeviceManagementConfiguration.Read.All'; ContextScope='Process'; NoWelcome=$true }
if ($TenantId) { $args.TenantId=$TenantId }
Connect-MgGraph @args
try {
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
    $items | Select-Object id,displayName,baseUri,offsetUri,'@odata.type',options,valueDefinition | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $OutputPath -Encoding utf8
    Write-Host "Wrote $(@($items).Count) definition(s): $OutputPath"
}
finally { Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null }
