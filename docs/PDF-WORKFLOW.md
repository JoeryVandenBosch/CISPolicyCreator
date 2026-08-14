# PDF-to-Intune workflow

CISPolicyCreator separates private document extraction, reviewed mapping, deterministic compilation, live validation, and deployment.

## 1. Eligibility and privacy

Use only a legitimately obtained CIS Benchmark explicitly authored for Microsoft Intune. Never commit the PDF or raw extracted benchmark prose. A reviewed mapping catalog declares required source text and exact benchmark identity; extraction stops when those checks fail.

## 2. Install the pinned extractor

```powershell
python -m pip install --require-hashes -r .\tools\requirements.txt
```

The PDF parser runs locally. It extracts `cisAssessmentMethod` independently from mapping status and fails on empty output, duplicate recommendation IDs, or unrecognized profile applicability.

## 3. Use a reviewed mapping catalog

The catalog is original, public-safe project metadata keyed by exact benchmark ID/version and recommendation ID. It classifies each recommendation as `mapped`, `unresolved`, `requires-input`, `manual`, or `not-applicable` and contains only reviewed Intune implementations.

The catalog records the reviewed expected recommendation count and must explicitly classify every extracted ID. Use `unresolved` for mappings that have not been proven. Missing/extra IDs or count mismatches fail source validation rather than silently producing an incomplete inventory.

## 4. Capture authoritative definitions

```powershell
.\scripts\Export-SettingsCatalogDiagnostics.ps1 `
  -TenantId '<guid>' `
  -OutputPath C:\Private\settings-catalog-snapshot.json
```

This private snapshot records API version, capture time, and tenant ID. Exact setting and option IDs are checked against it, and its SHA-256—not its tenant ID—is recorded in the generated pack. Do not commit tenant snapshots.

## 5. Supply organizational decisions

```powershell
.\scripts\New-CISAdministratorDecisions.ps1 `
  -MappingCatalogPath .\benchmarks\example\1.0.0\mapping-catalog.json `
  -OutputPath C:\Private\decisions.json
```

Complete every required value, set `acknowledged` to `true`, and add a justification. Values outside reviewed allowed sets/ranges fail validation. Missing decisions remain nondeployable `requires-input`; they are never defaulted.

## 6. Build atomically

```powershell
.\scripts\Invoke-CISPolicyPipeline.ps1 `
  -PdfPath C:\Private\Benchmark.pdf `
  -MappingCatalogPath .\benchmarks\example\1.0.0\mapping-catalog.json `
  -SettingsCatalogSnapshotPath C:\Private\settings-catalog-snapshot.json `
  -AdministratorDecisionsPath C:\Private\decisions.json `
  -OutputPath .\work\example
```

The script extracts to a private staging directory, compiles and validates the pack, moves the finished pack into place, and removes staging data. It refuses to overwrite an existing output path. `-KeepPrivateExtraction` retains raw text outside the pack only when explicitly requested.

## 7. Review and validate offline

```powershell
.\scripts\Test-CISPolicyPack.ps1 -PackRoot .\work\example
.\scripts\Get-CISMappingReport.ps1 -PackRoot .\work\example
```

## 8. Validate live, then import explicitly

Run `-DryRun` with a pinned tenant. It uses read-only Graph scope and validates current definitions/options before any write. Run `-ProbeOnly` if a temporary write-path test is required. Finally, invoke the importer without either switch to create unassigned policies.

Assignments remain a separate administrator-controlled operation outside this repository's importer.
