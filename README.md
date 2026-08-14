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
- `pypdf`, installed from the hash-pinned requirements file
- `Microsoft.Graph.Authentication` for snapshot export, live dry runs, probes, and imports

```powershell
python -m pip install --require-hashes -r .\tools\requirements.txt
Install-Module Microsoft.Graph.Authentication -Scope CurrentUser
```

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

## Live validation and import

Dry run uses read-only Graph scope, resolves every selected setting, validates exact option IDs, and prepares every payload before any write:

```powershell
.\scripts\Import-CISPolicyPack.ps1 `
    -PackRoot .\work\generated-pack `
    -Profile L1 `
    -TenantId '<tenant-guid>' `
    -DryRun
```

An optional probe creates one temporary unassigned policy and always attempts cleanup:

```powershell
.\scripts\Import-CISPolicyPack.ps1 `
    -PackRoot .\work\generated-pack `
    -TenantId '<tenant-guid>' `
    -ProbeOnly
```

Import remains a separate explicit operation:

```powershell
.\scripts\Import-CISPolicyPack.ps1 `
    -PackRoot .\work\generated-pack `
    -Profile L1 `
    -TenantId '<tenant-guid>'
```

Creation stops on the first Graph error by default. `-ContinueOnError` must be supplied explicitly to permit a partial run. No assignments are created in either mode.

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

The reusable engine is derived from a privately validated Windows 11 Intune implementation. Public normalized catalogs are not yet included. The next milestone is to author catalogs through this reproducible pipeline, starting with the planned benchmark sequence in [docs/SUPPORTED-BENCHMARKS.md](docs/SUPPORTED-BENCHMARKS.md).

## Public repository rules

Never commit source PDFs, Build Kits, raw extraction JSON, administrator decision files containing organizational details, tenant identifiers, credentials, diagnostic exports, or import-result logs. Public catalogs contain only minimal recommendation identifiers, mapping metadata, reviewed Graph identifiers/values, and original project code.

## License

MIT. See [LICENSE](LICENSE).
