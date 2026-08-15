# CISPolicyCreator

CISPolicyCreator is a reproducible, fail-closed scripting pipeline for turning a legitimately obtained **CIS Benchmark authored specifically for Microsoft Intune** into a validated, unassigned Intune policy pack.

The build and import paths use repository-owned PowerShell and Python scripts. ChatGPT, Codex, and other AI systems are not runtime dependencies.

> [!IMPORTANT]
> This repository does not include CIS Benchmark PDFs, SecureSuite Build Kits, or copied benchmark prose. CISPolicyCreator is an independent community project and is not affiliated with or endorsed by CIS.

## Safety model

CIS assessment method and Intune mapping status are separate facts:

| Field | Values | Meaning |
|---|---|---|
| `cisAssessmentMethod` | `Manual`, `Automated` | How CIS says the recommendation is assessed |
| `mappingStatus` | `mapped`, `unresolved`, `requires-input`, `manual`, `not-applicable` | Whether and how the recommendation maps to an Intune implementation |

A CIS recommendation with `cisAssessmentMethod: Manual` may still have `mappingStatus: mapped` when its Intune policy implementation is deterministic and reviewed.

Only `mapped` records may be referenced by deployable objects. A `requires-input` mapping becomes deployable only after a schema-valid, explicitly acknowledged administrator decision is supplied; the generated record retains its original catalog status and decision reference for auditability.

The pipeline also enforces these invariants:

- no guessed `settingDefinitionId` values;
- no guessed choice/value IDs;
- no display-name, substring, suffix, or constructed-ID resolution fallback;
- nested choice, simple-collection, and group-collection nodes require exact definition/type/value validation at every level;
- ambiguous matches remain unresolved or fail the build;
- unvalidated static Settings Catalog payloads are rejected;
- generic Graph endpoints are limited to Microsoft Graph `deviceManagement` resources;
- assignment endpoints and assignment payloads are rejected;
- policies are never assigned automatically;
- existing exact-name objects are skipped, never silently updated.

See [docs/FAIL-CLOSED-POLICY.md](docs/FAIL-CLOSED-POLICY.md).

## Reproducible pipeline

```text
private CIS Intune PDF
        |
        v
deterministic extraction + source identity checks
        |
        +---- all-unresolved catalog seed
        |
        +---- optional candidate-only worklist
                    |
                    +---- explicit hash-bound reviewer approvals
        |
        v
reviewed, versioned mapping catalog
        |
        +---- explicit administrator decisions, when required
        |
        +---- pinned Settings Catalog definition snapshot
        v
deterministic pack compiler
        |
        v
JSON Schema + semantic fail-closed validation
        |
        v
unassigned policy pack -> live dry run -> explicit import
```

The generated manifest records SHA-256 hashes for the PDF, mapping catalog, administrator decisions, and Settings Catalog snapshot. Repeating a build with identical inputs produces byte-identical pack files.

## Requirements

- PowerShell 7+
- Python 3.11+
- `pypdf`, installed from the hash-pinned requirements file; extraction fails if the installed version differs from the schema-bound pin
- `Microsoft.Graph.Authentication` for snapshot export, live dry runs, probes, and imports

```powershell
python -m pip install --require-hashes -r .\tools\requirements.txt
Install-Module Microsoft.Graph.Authentication -Scope CurrentUser
```

The extractor verifies Python's minimum version and cross-checks the installed `pypdf` version against both `tools/requirements.txt` and `schemas/extraction.schema.json` before reading a PDF. Dependency drift therefore stops the pipeline instead of silently changing extraction behavior.

## Build a pack from a PDF

A reviewed mapping catalog must exist for the exact benchmark family and version. When starting a new benchmark, first run the private extractor and create a copyright-safe, fail-closed catalog seed:

```powershell
python .\tools\Extract-CISRecommendations.py C:\Private\Benchmark.pdf `
    --benchmark-id '<benchmark-id>' `
    --benchmark-version '<version>' `
    --require-text '<reviewed source fingerprint>' `
    --output C:\Private\benchmark.private-extraction.json

.\scripts\New-CISMappingCatalog.ps1 `
    -ExtractionPath C:\Private\benchmark.private-extraction.json `
    -OutputPath .\benchmarks\<benchmark>\<version>\mapping-catalog.json `
    -CatalogId '<catalog-id>' `
    -CatalogVersion '0.1.0' `
    -PackId '<pack-id>' `
    -PackName '<pack name>' `
    -PackVersion '0.1.0'
```

The seed contains no benchmark prose and marks every recommendation `unresolved`. Reviewers then add only evidence-backed mappings.

First capture the current authoritative Settings Catalog definitions:

```powershell
.\scripts\Export-SettingsCatalogDiagnostics.ps1 `
    -TenantId '<tenant-guid>' `
    -OutputPath C:\Private\settings-catalog-snapshot.json
```

Add `-UseDeviceCode` when running from an embedded or headless terminal that cannot open the interactive browser window. Export records page/count evidence and fails on duplicate IDs or inconsistent pagination rather than accepting a possibly truncated definition set.

If you have a legitimately obtained, previously reviewed configuration-policy pack for the same benchmark, you can create a private candidate worklist:

```powershell
.\scripts\New-CISMappingReviewWorklist.ps1 `
    -ExtractionPath C:\Private\benchmark.private-extraction.json `
    -SettingsCatalogSnapshotPath C:\Private\settings-catalog-snapshot.json `
    -ReferencePackRoot C:\Private\reviewed-reference-pack `
    -OutputPath C:\Private\benchmark.private-review.json
```

The command recursively validates every referenced definition, type, choice ID, and value against the pinned snapshot, then uses deterministic normalized title/display-name containment only to produce review candidates. It never edits the mapping catalog. `unique-candidate` is not mapping proof, ambiguous candidates remain ambiguous, and a reviewer must explicitly approve the exact setting hierarchy and value before changing `mappingStatus`. The worklist contains private benchmark titles and must not be committed.

Create a private approval template tied to the exact catalog and worklist hashes:

```powershell
.\scripts\New-CISMappingReviewApprovals.ps1 `
    -MappingCatalogPath .\benchmarks\<benchmark>\<version>\mapping-catalog.json `
    -ReviewWorklistPath C:\Private\benchmark.private-review.json `
    -CatalogVersion '<next catalog version>' `
    -PackVersion '<next pack version>' `
    -OutputPath C:\Private\benchmark.private-approvals.json
```

Every row starts as `defer`, meaning it has not been decided. A reviewer may set a row to `rejected` with an explicit acknowledgement and rationale; this records that the historical candidate is not semantically equivalent while leaving the recommendation unresolved and nondeployable. A reviewer may set a row to `mapped` only by acknowledging semantic equivalence, asserting `valueBasis: benchmark-prescribed`, and selecting an exact candidate occurrence, complete top-level definition, and explicit unassigned policy metadata. The policy platform/technology must match the hashed reference and only the default role scope tag `0` is accepted.

Generate a deterministic private progress report without changing any decision or mapping:

```powershell
.\scripts\Get-CISMappingReviewReport.ps1 `
    -MappingCatalogPath .\benchmarks\<benchmark>\<version>\mapping-catalog.json `
    -ReviewWorklistPath C:\Private\benchmark.private-review.json `
    -ApprovalsPath C:\Private\benchmark.private-approvals.json `
    -JsonPath C:\Private\benchmark.private-review-report.json `
    -CsvPath C:\Private\benchmark.private-review-report.csv
```

The report is hash-bound, contains recommendation IDs and state counts but no benchmark titles, distinguishes pending, rejected, and approved candidate rows, and explicitly reports whether the review queue or catalog is complete. Keep it private. Apply mapped approvals to a new catalog file:

```powershell
.\scripts\Apply-CISMappingReviewApprovals.ps1 `
    -ExtractionPath C:\Private\benchmark.private-extraction.json `
    -MappingCatalogPath .\benchmarks\<benchmark>\<version>\mapping-catalog.json `
    -ReviewWorklistPath C:\Private\benchmark.private-review.json `
    -ApprovalsPath C:\Private\benchmark.private-approvals.json `
    -SettingsCatalogSnapshotPath C:\Private\settings-catalog-snapshot.json `
    -ReferencePackRoot C:\Private\reviewed-reference-pack `
    -OutputPath C:\Private\mapping-catalog.next.json
```

The apply command rechecks every source hash, including the private extraction, and recursively reconstructs the exact reviewed setting tree. It promotes only currently `unresolved` recommendations with outcome `mapped`; `defer` and `rejected` never emit implementation content. The source catalog is never overwritten. Before publishing the new catalog, the script atomically compiles the complete extraction-bound pack and runs offline validation; any failure leaves no output catalog. This path cannot be used for organizational values that belong in `requires-input`. Live dry run and test-tenant review remain mandatory before publication or import.

If the catalog declares organizational choices, generate and complete a decision file:

```powershell
.\scripts\New-CISAdministratorDecisions.ps1 `
    -MappingCatalogPath .\benchmarks\<benchmark>\<version>\mapping-catalog.json `
    -OutputPath C:\Private\administrator-decisions.json
```

Run the complete local build:

```powershell
.\scripts\Invoke-CISPolicyPipeline.ps1 `
    -PdfPath C:\Private\Benchmark.pdf `
    -MappingCatalogPath .\benchmarks\<benchmark>\<version>\mapping-catalog.json `
    -SettingsCatalogSnapshotPath C:\Private\settings-catalog-snapshot.json `
    -AdministratorDecisionsPath C:\Private\administrator-decisions.json `
    -OutputPath .\work\generated-pack
```

The PDF and private extraction text are not copied into the pack. Omit `-AdministratorDecisionsPath` to produce a valid partial pack in which those recommendations remain `requires-input` and no corresponding deployable settings are emitted.

## Validate and review

```powershell
.\scripts\Test-CISPolicyPack.ps1 -PackRoot .\work\generated-pack
.\scripts\Get-CISMappingReport.ps1 -PackRoot .\work\generated-pack
```

Validation evaluates the JSON Schemas and cross-file semantic rules. It runs without Graph access.

To run the same complete privacy, schema, parser, offline-pipeline, extractor, and synthetic-PDF checks as GitHub Actions:

```powershell
.\scripts\Test-CISRepository.ps1 -PythonPath .\.venv\Scripts\python.exe
```

## Live validation and import

Dry run uses read-only Graph scope, resolves every selected setting, validates exact option IDs, and prepares every payload before any write:

```powershell
.\scripts\Import-CISPolicyPack.ps1 `
    -PackRoot .\work\generated-pack `
    -Profile L1 `
    -TenantId '<tenant-guid>' `
    -UseDeviceCode `
    -DryRun
```

`-UseDeviceCode` is optional, but is useful in embedded or headless terminals that cannot complete browser-based authentication.

When the compiler found an eligible reviewed leaf setting, the pack contains a deterministic probe that creates one temporary unassigned policy and always attempts cleanup:

```powershell
.\scripts\Import-CISPolicyPack.ps1 `
    -PackRoot .\work\generated-pack `
    -TenantId '<tenant-guid>' `
    -ProbeOnly `
    -ConfirmTemporaryWriteProbe
```

The probe acknowledgement is required because this mode creates one temporary unassigned policy and then attempts deletion. A pinned `-TenantId` is mandatory for every write mode.

Import remains a separate explicit operation:

```powershell
.\scripts\Import-CISPolicyPack.ps1 `
    -PackRoot .\work\generated-pack `
    -Profile L1 `
    -TenantId '<tenant-guid>' `
    -ConfirmUnassignedImport
```

The import acknowledgement is required before pack validation or Graph authentication; omission of `-DryRun` alone is never sufficient write intent. Creation stops on the first Graph error by default. `-ContinueOnError` must be supplied explicitly to permit a partial run. No assignments are created in either mode.

## Repository layout

```text
scripts/    extraction orchestration, compilation, validation, reporting, import
src/        fail-closed Graph and payload helpers
schemas/    build-input and generated-pack JSON Schemas
tools/      deterministic local PDF extractor and pinned dependency
templates/  schema-valid empty pack template
tests/      copyright-safe offline fixtures and behavioral tests
benchmarks/ public-safe inventory seeds and reviewed mapping catalogs
docs/       format, workflow, security, and scope documentation
```

See [docs/CHAT-HANDOFF.md](docs/CHAT-HANDOFF.md) for the concise current-state handoff. The longer `CISPolicyCreator_CHAT_HANDOFFnew.md` is retained as historical v0.1 context only.

## Current benchmark status

The repository includes a public-safe Windows 11 v5.0.0 catalog with all 415 recommendation identifiers. Eighteen recommendations currently have exact, snapshot-validated Settings Catalog mappings, producing 18 settings in 6 unassigned policies; all 18 also pass live tenant dry-run validation. The other 397 recommendations remain unresolved and nondeployable. This is a reviewed partial catalog, not a complete CIS baseline. See [docs/SUPPORTED-BENCHMARKS.md](docs/SUPPORTED-BENCHMARKS.md) for the benchmark roadmap.

## Public repository rules

Never commit source PDFs, Build Kits, raw extraction JSON, private review/approval/report files, administrator decision files containing organizational details, tenant identifiers, credentials, diagnostic exports, or import-result logs. Public catalogs contain only minimal recommendation identifiers, mapping metadata, reviewed Graph identifiers/values, and original project code.

## License

MIT. See [LICENSE](LICENSE).
