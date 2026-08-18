[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$MappingCatalogPath,
    [Parameter(Mandatory)][string]$OutputPath
)
$ErrorActionPreference='Stop'
$repoRoot=Split-Path -Parent $PSScriptRoot
$catalogPath=(Resolve-Path -LiteralPath $MappingCatalogPath).Path
$json=Get-Content -LiteralPath $catalogPath -Raw
if (-not ($json | Test-Json -SchemaFile (Join-Path $repoRoot 'schemas\mapping-catalog.schema.json') -ErrorAction Stop)) { throw 'Mapping catalog failed schema validation.' }
$catalog=$json | ConvertFrom-Json -Depth 100
$output=[IO.Path]::GetFullPath($OutputPath)
if (Test-Path -LiteralPath $output) { throw "OutputPath already exists: $output" }
$requiredIds=@($catalog.recommendations | Where-Object mappingStatus -eq 'requires-input' | ForEach-Object {
    $refsProperty=$_.PSObject.Properties['decisionRefs']
    if($refsProperty){@($refsProperty.Value|ForEach-Object{[string]$_})}else{[string]$_.decisionRef}
} | Where-Object {$_} | Sort-Object -Unique)
$definitions=@{}
foreach($definition in @($catalog.administratorInputs)){ $definitions[[string]$definition.id]=$definition }
$items=@($requiredIds | ForEach-Object {
    if (-not $_ -or -not $definitions.ContainsKey($_)) { throw "Catalog requires an undeclared administrator input: $_" }
    $definition=$definitions[$_]
    $allowedProperty=$definition.PSObject.Properties['allowedValues']
    $minimumProperty=$definition.PSObject.Properties['minimum']
    $maximumProperty=$definition.PSObject.Properties['maximum']
    $constraint=if ($allowedProperty) {
        "allowed: $(@($allowedProperty.Value) -join ', ')"
    } elseif($minimumProperty -or $maximumProperty) {
        $minimum=if($minimumProperty){$minimumProperty.Value}else{'no minimum'}
        $maximum=if($maximumProperty){$maximumProperty.Value}else{'no maximum'}
        "type: $($definition.valueType); range: $minimum through $maximum"
    } else {
        "type: $($definition.valueType)"
    }
    Write-Host "$($_): $($definition.prompt) [$constraint]"
    [ordered]@{ id=$_; value=$null; acknowledged=$false; justification='' }
})
$payload=[ordered]@{ schemaVersion='1.0'; catalogId=[string]$catalog.id; catalogVersion=[string]$catalog.version; decisions=$items }
$payload | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $output -Encoding utf8
Write-Host "Wrote administrator decision template: $output"
Write-Host 'Fill every value, set acknowledged to true, and add a non-empty justification before building.'
