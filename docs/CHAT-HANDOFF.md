# CISPolicyCreator chat handoff

**Updated:** 2026-08-18
**Current delivery:** post-PR #10 release hardening for enrollment-template fail-closed behavior
**Architecture:** reproducible PDF-to-pack pipeline, pack schema v2, deterministic split-policy JSON ZIP export, optional fail-closed ZIP importer

## Read this first

CISPolicyCreator is primarily a **policy creation tool**. A user clones the repository,
supplies a legitimately obtained CIS Benchmark PDF authored specifically for Microsoft
Intune, supplies a current Intune Settings Catalog snapshot and any required explicit
administrator decisions, and receives validated importable policy JSON files. ChatGPT,
Codex, Claude, or another AI service is not a runtime dependency.

The optional importer is now included, but it is not required to use the main
PDF-to-JSON product. It creates policies without assignments. Assignment creation is
intentionally outside this repository.

Do not describe every supported benchmark as a complete CIS baseline. Windows 10,
Edge, Office, and macOS are complete **for policy creation** because every recommendation
has a final mapping state and every actual deterministic Intune setting can produce JSON
after required administrator input. iOS/iPadOS has one intentionally unresolved ADE
recommendation described below. Windows 11 v5.0.0 remains a clearly identified partial
catalog. Human/process recommendations correctly produce no fake policy JSON.

## Non-negotiable safety invariants

- Never guess or construct a Microsoft Graph Settings Catalog definition ID.
- Never guess, shorten, or heuristically select a choice/value ID.
- Exact explicit IDs or an exact unique `baseUri + offsetUri` resolver are the only
  setting-resolution mechanisms.
- Ambiguous or unproven mappings remain `unresolved` or fail closed.
- Organizational values require an explicit acknowledged administrator decision.
- Non-policy and human/process controls remain `manual` and emit no policy JSON.
- Static or unknown Settings Catalog payload shapes are rejected.
- Unknown Graph object types, properties, endpoints, and operations are rejected.
- No assignments, groups, or assignment API calls are created automatically.
- A different same-name Intune policy/object is never overwritten or silently skipped.
- No source CIS PDF, raw benchmark prose, credentials, tenant identifiers, private
  decisions, private review evidence, or import logs may be committed.

`cisAssessmentMethod` (`Manual | Automated`) and `mappingStatus`
(`mapped | unresolved | requires-input | manual | not-applicable`) are independent. A
CIS recommendation whose assessment method is `Manual` may still have a deterministic
Intune mapping.

## Delivered pull requests

| PR | Delivery |
|---:|---|
| #1 | Reproducible fail-closed CIS-to-Intune pipeline |
| #2 | Exact selectors and pipelines for the chosen Intune benchmark PDFs |
| #3 | Correct repository-relative output paths and beginner setup documentation |
| #4 | Exact existing-policy comparison that ignores only proven Graph response decoration |
| #5 | Expanded deterministic mappings across six Intune benchmarks |
| #6 | Required Microsoft Office choice-dependency handling |
| #7 | Required Settings Catalog group-dependency evidence and validation |
| #8 | Deterministic portable Intune policy JSON bundle export |
| #9 | Complete PDF-to-policy-JSON creation catalogs for five benchmarks, with Windows-style one-setting-per-file output |
| #10 | Optional fail-closed importer for the validated split-policy JSON ZIPs, plus this updated handoff |

## Supported benchmark state

These are the exact public catalog counts and expected JSON output counts after the
enrollment-template release hardening:

| Supported CIS PDF | Version | Mapped | Requires input | Manual | Unresolved | JSON files with all inputs |
|---|---:|---:|---:|---:|---:|---:|
| CIS Microsoft Intune for Windows 10 Benchmark | 5.0.0 | 312 | 5 | 41 | 0 | 278 |
| CIS Microsoft Intune for Edge Benchmark | 1.0.0 | 135 | 3 | 0 | 0 | 138 |
| CIS Microsoft Intune for Office Benchmark | 1.1.0 | 238 | 0 | 0 | 0 | 234 |
| CIS Apple macOS 26 Tahoe Intune Benchmark | 1.0.0 | 85 | 14 | 1 | 0 | 83 |
| CIS Apple iOS 26 and iPadOS 26 Intune Benchmark | 1.0.0 | 84 | 8 | 1 | 1 | 60 |
| CIS Microsoft Intune for Windows 11 Benchmark | 5.0.0 | 154 | 0 | 0 | 261 | 154 |

The JSON-file count may be lower than the mapped-recommendation count because duplicate
recommendations can share one implementation and settings with required dependencies
must be bundled into one valid policy. It may be higher in other cases when one
recommendation requires more than one policy object.

iOS/iPadOS recommendation 3.10.1, Locked enrollment, is intentionally `unresolved`.
The exact `ade_lockedenrollment` definition, Yes option, ADE policy template, setting
instance template, and setting value template were proven live. A real create then
proved that Microsoft requires 40 settings in every ADE profile. Read-only inspection
showed that the required companion settings include organization-specific enrollment
and Setup Assistant choices, most without template defaults. The repository therefore
does not guess those values and no longer emits the rejected one-setting ADE JSON.

The four catalogs with organizational questions (Windows 10, Edge, macOS, and
iOS/iPadOS) require private administrator-decision files. Any ZIPs under ignored local
`work` folders that were built with test decisions are validation artifacts, not
production defaults and not release inputs. Office has no administrator questions.

Only exact Intune-authored PDFs and versions exposed by
`Build-CISSupportedBenchmark.ps1` are supported. A generic Edge, Office, Apple OS,
Android, Chrome, or Safari CIS Benchmark is not interchangeable with an Intune-specific
benchmark.

## End-to-end creation pipeline

The beginner path is documented in `README.md`. The important scripts are:

- `Initialize-CISPolicyCreator.ps1`: create/reuse repository-local `.venv` and
  `.modules`, install the SHA-256-locked PDF parser, and optionally install the pinned
  Graph authentication module.
- `Test-CISPrerequisites.ps1`: verify PowerShell, Python, parser, and optionally Graph
  module contracts.
- `Export-SettingsCatalogDiagnostics.ps1`: export a private schema-1.2 Settings Catalog
  snapshot, including required group-dependency evidence.
- `New-CISAdministratorDecisions.ps1`: create a private all-unanswered decision
  template for one exact catalog.
- `Build-CISSupportedBenchmark.ps1`: select one of the six exact benchmark/version
  catalogs and run the reproducible pipeline.
- `Invoke-CISPolicyPipeline.ps1`: verify source eligibility, privately extract the PDF,
  compile the catalog plus decisions, validate exact snapshot-bound mappings, validate
  the pack, export the split-policy ZIP, and atomically publish outputs.
- `Test-CISPolicyPack.ps1`: perform schema and semantic pack validation.
- `Get-CISMappingReport.ps1`: emit deterministic mapping audit reports only after full
  pack validation.
- `Export-CISWindowsStylePolicyBundle.ps1`: generate a deterministic portable ZIP with
  one top-level Intune setting/object per JSON file except necessary dependency bundles.
- `Test-CISWindowsStylePolicyBundle.ps1`: independently validate the complete ZIP and
  reject assignments, unexpected paths, invalid JSON shapes, and tenant metadata.
- `Import-CISWindowsStylePolicyBundle.ps1`: optional importer added by PR #10.
- `Test-CISRepository.ps1`: run the complete local/CI regression suite.

The pipeline deletes private extraction data after a normal build. Generated manifests
bind the PDF, mapping catalog, administrator decisions, definition snapshot, compiler,
extractor, and parser versions/hashes. Identical input bytes produce identical pack and
ZIP bytes. Existing output paths are never silently replaced.

### Typical build

```powershell
$Benchmark = 'Windows10-5.0.0'
$PdfPath = '.\private\pdf\CIS_Microsoft_Intune_for_Windows_10_Benchmark_v5.0.0.pdf'
$RunId = Get-Date -Format 'yyyyMMdd-HHmmss'
$PackPath = ".\work\packs\windows10-v5-$RunId"
$BundlePath = ".\work\windows10-v5-$RunId-policies.zip"

$BuildArguments = @{
  Benchmark                   = $Benchmark
  PdfPath                     = $PdfPath
  SettingsCatalogSnapshotPath = '.\private\graph\settings-catalog-snapshot.json'
  OutputPath                  = $PackPath
  PolicyJsonBundlePath        = $BundlePath
  PolicyJsonBundleName        = "windows10-v5-$RunId-policies"
  Profile                     = 'ALL'
}

# Add this only when the benchmark requires completed private decisions:
# $BuildArguments.AdministratorDecisionsPath = '.\private\Windows10-5.0.0-decisions.json'

.\scripts\Build-CISSupportedBenchmark.ps1 @BuildArguments
.\scripts\Test-CISPolicyPack.ps1 -PackRoot $PackPath
.\scripts\Test-CISWindowsStylePolicyBundle.ps1 -BundlePath $BundlePath
```

## Split-policy JSON ZIP format

The ZIP root contains supported folders such as:

- `SettingsCatalog/*.json`: complete Settings Catalog policy exports with one top-level
  setting and every required nested dependency;
- `DeviceConfigurations/*.json`, `CompliancePolicies/*.json`, or
  `GraphObjects/*.json`: typed non-Settings-Catalog Intune objects protected by exact
  repository Graph contracts.

Filenames and exported IDs are deterministic. Export IDs exist only to preserve the
portable export shape; the importer reconstructs fresh request bodies and does not send
tenant-generated export metadata back to Graph. The ZIP contains no assignment,
credential, tenant ID, source PDF, or raw CIS recommendation prose.

## Optional ZIP importer (PR #10)

`Import-CISWindowsStylePolicyBundle.ps1` consumes only a ZIP that passes the repository
bundle validator. It reads the archive in memory without extracting it.

### Modes

```powershell
# 1. Completely offline: no login and no Graph call
.\scripts\Import-CISWindowsStylePolicyBundle.ps1 `
  -BundlePath $BundlePath `
  -ValidateOnly

# 2. Read-only live validation: no writes and no assignments
.\scripts\Import-CISWindowsStylePolicyBundle.ps1 `
  -BundlePath $BundlePath `
  -TenantId $TenantId `
  -UseDeviceCode `
  -DryRun

# 3. Explicit unassigned creation
.\scripts\Import-CISWindowsStylePolicyBundle.ps1 `
  -BundlePath $BundlePath `
  -TenantId $TenantId `
  -UseDeviceCode `
  -ConfirmUnassignedImport
```

Actual import requires both a pinned `TenantId` and `-ConfirmUnassignedImport` before
bundle validation or Graph authentication. `-DryRun` requests read-only scope. An
explicitly requested existing Graph context is accepted only after scope and tenant
validation.

### Import preflight and collision behavior

Before the first write, the importer:

1. validates the complete ZIP offline;
2. converts each exported Settings Catalog instance into a strict internal specification;
3. resolves every explicit live definition ID and exact choice/value ID;
4. recreates every supported simple, collection, choice, group, and dependency payload;
5. validates exact policy, instance, and value template IDs and rejects a template
   policy that omits any live-required companion setting;
6. resolves every typed Graph object by exactly one SHA-256-bound repository contract;
7. rejects unexpected properties, types, endpoints, operations, or assignment data;
8. reads all same-name objects and proves an exact expected-property match;
9. aborts before any write on a duplicate, ambiguous, unreadable, or different collision.

An exactly matching existing object is left unchanged. Ordinary objects use create-only
POST operations. Existing different objects are never patched. Creation stops on the
first Graph error by default; `-ContinueOnError` must be explicit. Results are written
beside the ZIP when processing produces results.

### iOS/iPadOS tenant-wide settings

The iOS/iPadOS bundle contains 58 assignable policy objects plus two Intune-wide
`deviceManagementSettings` values. Those two values are singleton tenant settings, not
policies and not assignments. Actual import refuses to choose silently:

- add `-SkipTenantWideSettings` to import only the ordinary policies; or
- review the values and add `-ConfirmTenantWideSettingsUpdate` to permit the two exact
  guarded singleton PATCH operations.

The two switches are mutually exclusive. Dry run reports what would happen without
changing either value.

### No-assignment guarantee

The importer contains no assignment mode. It rejects assignment data recursively,
constructs request payloads without assignments, and uses no `/assign` or
`/assignments` endpoint. Users, devices, and groups remain untouched. Administrators
must review, test, and assign policies separately in Intune.

## Validation completed through the release candidate

- All five selected generated ZIPs passed offline importer preparation:
  - Windows 10: 277 Settings Catalog policies and 1 compliance policy;
  - Edge: 138 Settings Catalog policies;
  - Office: 234 Settings Catalog policies;
  - macOS: 83 Settings Catalog policies;
  - iOS/iPadOS: 6 Settings Catalog policies, 52 typed Graph policies, and 2 guarded
    tenant-wide values.
- A live read-only Edge dry run validated all 138 Settings Catalog policies in the
  pinned test tenant.
- A live read-only iOS/iPadOS dry run validated all 60 objects/values in the same test
  tenant.
- The first iOS dry run exposed a one-item group conversion bug. Exported group rows
  were retained as `OrderedDictionary` values, while the strict live request builder
  expects property-bearing objects. The converter now emits `PSCustomObject` rows, and
  a regression test proves an exported group can round-trip back into a valid live
  request body without losing its child array.
- The first actual ZIP import attempt proved that the ADE template rejects a standalone
  Locked enrollment policy because 39 other template settings are required. The create
  stopped on the first error. Read-only inspection found 40 required settings and no
  usable defaults for most organization-specific companion choices. Recommendation
  3.10.1 was therefore moved to `unresolved` and its incomplete JSON was removed.
- The corrected actual ZIP import completed for all 58 assignable iOS/iPadOS policies.
  The importer skipped exact existing matches, created only missing objects, skipped
  both tenant-wide settings, and a final Graph read verified zero assignments on every
  one of the 58 policies.
- `Test-CISRepository.ps1` passed with PowerShell 7.6.4, Python 3.14.0, the pinned Graph
  module, 12 Python tests, synthetic PDF extraction, deterministic build/export, bundle
  validation, and offline importer preparation. Rerun it after the final documentation
  edits and require GitHub Actions to pass before merge.

## Legacy pack importer

`Import-CISPolicyPack.ps1` remains in the repository for validated internal pack
workflows, write probes, partial-pack acknowledgement, and earlier testing. New end-user
documentation recommends the ZIP importer because the ZIP is the requested portable
policy deliverable. Do not remove the pack importer without a separate compatibility
decision and migration plan.

## Private/local artifacts

The following are deliberately ignored or untracked and must not be committed:

- licensed CIS PDFs and raw extraction text;
- Settings Catalog snapshots containing tenant-derived evidence;
- administrator decisions and mapping-review work files;
- generated packs, ZIP previews, import results, and live-test transcripts under
  `private` or `work`;
- the workspace-root files `CISPolicyCreator_CHAT_HANDOFF.md` and
  `CISPolicyCreator_CHAT_HANDOFFnew.md`, which are user-owned local files. The canonical
  committed handoff is this file: `docs/CHAT-HANDOFF.md`.

## What is finished and what remains

Finished:

- reproducible local PDF extraction and exact source/version eligibility checks;
- fail-closed mapping, decision, compilation, schema, and semantic validation;
- completed policy-creation catalogs for Windows 10, Edge, Office, and macOS;
- iOS/iPadOS policy creation with one clearly documented, intentionally unresolved ADE
  recommendation instead of an invalid or guessed enrollment profile;
- clearly labeled partial Windows 11 catalog;
- deterministic Windows-style split-policy JSON ZIP creation;
- optional fail-closed ZIP import with no assignments;
- beginner install/build/validate/dry-run/import documentation;
- offline, live read-only, actual unassigned import, zero-assignment verification, and
  local regression validation described above.

The remaining known mapping work is an explicit administrator-decision model for all
required ADE enrollment-profile settings before iOS/iPadOS recommendation 3.10.1 can
emit one valid bundled policy. Do not shortcut that work with guessed options or hidden
defaults. Other future work is optional: add newly released exact CIS Intune benchmark
versions through new reviewed catalogs, or design a separate administrator-controlled
assignment feature. An assignment feature would change a core safety invariant and
requires an explicit product decision; it must never be inferred from the current tool.
