# CISPolicyCreator

CISPolicyCreator is a reusable PowerShell toolkit for turning **user-supplied CIS Benchmarks that are explicitly authored for Microsoft Intune** into safe, reviewable, testable Intune policy packs.

The project grew out of a live conversion of a CIS Microsoft Intune for Windows 11 baseline and incorporates the Graph behaviors that were proven during that work: Settings Catalog deep-create, runtime definition resolution, tenant pinning, write probes, duplicate detection, detailed Graph errors, response-metadata sanitization, and **no assignments by default**.

> [!IMPORTANT]
> This repository does **not** include CIS Benchmark PDFs, CIS SecureSuite Build Kits, or copied benchmark prose. Supply benchmark documents yourself and follow the applicable CIS terms of use. CISPolicyCreator is an independent community project and is not affiliated with or endorsed by the Center for Internet Security (CIS).

## Scope

Only benchmarks **specifically written for Microsoft Intune** are accepted as first-class benchmark packs.

Initial supported/target benchmark families:

- CIS Microsoft Intune for Windows 11
- CIS Apple macOS Intune
- CIS Microsoft Intune for Apple iOS/iPadOS

Generic CIS operating-system or browser benchmarks are intentionally out of scope, even if some controls could technically be translated into Intune. This keeps mappings deterministic and avoids inventing management semantics that are not present in the source benchmark.

See [docs/SUPPORTED-BENCHMARKS.md](docs/SUPPORTED-BENCHMARKS.md).

## Fail-closed mapping model

A recommendation can be classified as:

- `mapped` - a reviewed, explicit Intune/API implementation exists;
- `manual` - CIS requires an administrator/user action or an assessment that is not represented as a deployable Intune object;
- `unresolved` - the recommendation might be deployable, but the exact Intune/API mapping is not yet proven;
- `not-applicable` - intentionally excluded for the selected platform/profile with documented reasoning.

Only `mapped` recommendations are allowed to generate deployable objects. `manual` and `unresolved` recommendations remain visible in the mapping inventory but cannot silently turn into policies.

See [docs/FAIL-CLOSED-POLICY.md](docs/FAIL-CLOSED-POLICY.md) and the companion Word document in `docs/`.

## What the engine does

- Uses a **manifest-driven policy pack** format rather than benchmark-specific import scripts.
- Validates a recommendation inventory before connecting to Graph.
- Refuses benchmark packs that are not declared `microsoft-intune` scope.
- Refuses deployable entries that are not explicitly `mapped`.
- Deep-creates Intune Settings Catalog policies with all settings in the initial Graph POST.
- Resolves Settings Catalog definitions at runtime using an explicit definition ID or a reviewed resolver.
- Supports choice, integer, and string Settings Catalog values.
- Fails closed on unsupported Settings Catalog definition/value types.
- Supports reviewed generic Graph objects for compliance policies and other Intune resources.
- Restricts generic Graph endpoints to Microsoft Graph `deviceManagement` paths.
- Rejects assignment endpoints/payloads.
- Removes known read-only OData response metadata before create requests.
- Verifies signed-in account, tenant ID, organization, and Graph scopes before writes.
- Provides `-ProbeOnly` and `-DryRun`.
- Detects existing objects by exact name and never updates them by default.
- Creates **no assignments**.
- Writes machine-readable import results.

## Repository layout

```text
CISPolicyCreator/
├─ src/
│  └─ CISPolicyCreator.psm1
├─ scripts/
│  ├─ Import-CISPolicyPack.ps1
│  ├─ Test-CISPolicyPack.ps1
│  ├─ Get-CISMappingReport.ps1
│  ├─ New-CISPolicyPack.ps1
│  └─ Export-SettingsCatalogDiagnostics.ps1
├─ schemas/
│  ├─ manifest.schema.json
│  ├─ recommendations.schema.json
│  ├─ settings-catalog.schema.json
│  ├─ graph-objects.schema.json
│  └─ policy-bundle.schema.json
├─ templates/
│  └─ baseline/
├─ benchmarks/
│  └─ README.md
├─ tools/
│  ├─ Extract-CISRecommendations.py
│  └─ requirements.txt
└─ docs/
   ├─ FAIL-CLOSED-POLICY.md
   ├─ CISPolicyCreator_Fail_Closed_Mapping_Policy.docx
   ├─ PACK-FORMAT.md
   ├─ PDF-WORKFLOW.md
   └─ SUPPORTED-BENCHMARKS.md
```

## Quick start

### Requirements

- PowerShell 7+
- `Microsoft.Graph.Authentication`

```powershell
Install-Module Microsoft.Graph.Authentication -Scope CurrentUser
```

Optional PDF extraction helper:

```powershell
python -m pip install -r .\tools\requirements.txt
```

### Create a new pack

```powershell
.\scripts\New-CISPolicyPack.ps1 `
    -OutputPath .\work\macos26-intune `
    -PackId cis-macos26-tahoe-intune-1.0.0 `
    -Name "CIS Apple macOS 26 Tahoe Intune" `
    -Version "1.0.0" `
    -Platform macOS
```

The new recommendation inventory starts empty. Recommendations extracted from a PDF should enter the workflow as `unresolved`, never `mapped` automatically.

### Validate

```powershell
.\scripts\Test-CISPolicyPack.ps1 -PackRoot .\work\macos26-intune
```

### Mapping report

```powershell
.\scripts\Get-CISMappingReport.ps1 -PackRoot .\work\macos26-intune
```

### Test the Graph write path

```powershell
.\scripts\Import-CISPolicyPack.ps1 `
    -PackRoot .\work\macos26-intune `
    -Profile L1 `
    -TenantId '<tenant-guid>' `
    -ProbeOnly
```

### Dry run

```powershell
.\scripts\Import-CISPolicyPack.ps1 `
    -PackRoot .\work\macos26-intune `
    -Profile L1 `
    -TenantId '<tenant-guid>' `
    -DryRun
```

### Import

```powershell
.\scripts\Import-CISPolicyPack.ps1 `
    -PackRoot .\work\macos26-intune `
    -Profile L1 `
    -TenantId '<tenant-guid>'
```

No assignments are created.

## PDF to Intune

The parser is an extraction aid, not an Intune mapper:

```powershell
python .\tools\Extract-CISRecommendations.py `
    C:\Private\Benchmark.pdf `
    -o C:\Private\recommendations.raw.json
```

Every extracted recommendation is emitted as `unresolved`. A human/review process must prove the Intune implementation before it can become `mapped`.

See [docs/PDF-WORKFLOW.md](docs/PDF-WORKFLOW.md).

## Public-repository rules

Do not commit:

- CIS PDF source documents;
- SecureSuite Build Kits;
- large copied benchmark sections;
- raw extraction files containing benchmark prose;
- tenant IDs, credentials, exports containing secrets, or import-result logs.

Public benchmark packs should contain only the minimum implementation metadata needed to reproduce the Intune policy and an auditable recommendation identifier/status mapping.

## License

MIT. See [LICENSE](LICENSE).
