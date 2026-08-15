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
- existing Settings Catalog policies are skipped only after their metadata and complete setting/value payloads exactly match; ambiguous names or differences abort before writes;
- existing generic Graph objects are skipped by exact name and never silently updated.

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
- the exact `Microsoft.Graph.Authentication` version pinned in `tools/powershell-requirements.psd1` for snapshot export, live dry runs, probes, and imports

```powershell
.\scripts\Initialize-CISPolicyCreator.ps1

# Required only for snapshot export and live Graph operations:
.\scripts\Initialize-CISPolicyCreator.ps1 -IncludeGraph
.\scripts\Test-CISPrerequisites.ps1 -RequireGraph
```

The initializer creates or reuses `.venv`, installs the PDF dependency with `--require-hashes`, and verifies the result. `-IncludeGraph` additionally downloads the exact locked authentication module from PowerShell Gallery into the ignored repository-local `.modules` directory; it does not authenticate or contact Microsoft Graph. Live scripts verify both its version and deterministic file-tree SHA-256 before loading it. No mode installs an AI runtime. The main PDF pipeline automatically prefers the local Python environment. The extractor independently verifies Python's minimum version and cross-checks the installed `pypdf` version against both `tools/requirements.txt` and `schemas/extraction.schema.json` before reading a PDF. Dependency drift therefore stops the pipeline instead of silently changing extraction behavior.

## Build a pack from a PDF

A reviewed mapping catalog must exist for the exact benchmark family and version. When starting a new benchmark, first run the private extractor and create a copyright-safe, fail-closed catalog seed:

```powershell
$python=(.\scripts\Test-CISPrerequisites.ps1 -PassThru).PythonPath
& $python .\tools\Extract-CISRecommendations.py C:\Private\Benchmark.pdf `
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
.\scripts\Get-CISMappingReport.ps1 `
    -PackRoot .\work\generated-pack `
    -JsonPath .\work\mapping-report-pack.json `
    -CsvPath .\work\mapping-report-pack.csv
```

Validation evaluates the JSON Schemas and cross-file semantic rules. It runs without Graph access. Mapping reporting invokes that same validation first, refuses invalid/tampered packs and existing output files, emits byte-stable UTF-8 JSON/CSV, and reports `cisAssessmentMethod` independently from mapping completeness.

To run the same complete privacy, schema, parser, offline-pipeline, extractor, and synthetic-PDF checks as GitHub Actions:

```powershell
.\scripts\Test-CISRepository.ps1
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
    -ConfirmUnassignedImport `
    -ConfirmPartialPack
```

`-ConfirmPartialPack` is required only when final recommendations remain `unresolved` or `requires-input`; those recommendations emit nothing, and the separate acknowledgement prevents a partial catalog from being mistaken for a complete baseline. Omit it for a complete pack. The unassigned-import acknowledgement is always required before pack validation or Graph authentication; omission of `-DryRun` alone is never sufficient write intent. Creation stops on the first Graph error by default. `-ContinueOnError` must be supplied explicitly to permit continuing after a Graph error. No assignments are created in either mode.

Before any create request, every case-insensitive same-name Settings Catalog policy is read back with all of its settings. Exactly one match may be skipped only when its name, description, platform, technology, role scope tags, template identity, definition IDs, and complete nested option/value payloads match the prepared pack. Duplicate names, unreadable content, extra or missing settings, or any metadata/value difference abort the import before writes. Graph response metadata and server-generated setting wrapper IDs are the only payload details ignored by this comparison.

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

The repository includes a public-safe Windows 11 v5.0.0 catalog with all 415 recommendation identifiers. Twenty-eight recommendations currently have exact, snapshot-validated Settings Catalog mappings, producing 28 settings in 10 unassigned policies; all 28 have passed live tenant mapping validation. An earlier explicitly acknowledged Level 1 partial-pack import made no changes because every target policy name was already present. After same-name readback verification was hardened, a read-only live run correctly aborted before writes because the first existing policy contained 27 settings while the partial pack expected 1; names are no longer treated as proof of equivalence. The other 387 recommendations remain unresolved and nondeployable. This is a reviewed partial catalog, not a complete CIS baseline. See [docs/SUPPORTED-BENCHMARKS.md](docs/SUPPORTED-BENCHMARKS.md) for the benchmark roadmap.

## Public repository rules

Never commit source PDFs, Build Kits, raw extraction JSON, private review/approval/report files, administrator decision files containing organizational details, tenant identifiers, credentials, diagnostic exports, or import-result logs. Public catalogs contain only minimal recommendation identifiers, mapping metadata, reviewed Graph identifiers/values, and original project code.

## License

MIT. See [LICENSE](LICENSE).
