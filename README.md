# CISPolicyCreator

CISPolicyCreator reads a legitimately obtained CIS Benchmark PDF written specifically
for Microsoft Intune and builds a validated Intune policy pack. The pack can then be
imported into Microsoft Intune as real, unassigned policies with settings.

The tool runs entirely from the scripts in this repository. ChatGPT, Codex, or another
AI service is **not** required at runtime.

## Important: these are partial policy packs

The supported PDFs are recognized completely: every extracted CIS recommendation is
recorded and classified. Only recommendations with an exact, evidence-backed Microsoft
Graph setting and value are emitted as policy settings.

| Supported CIS PDF | Version | Mapped settings | Unresolved | Unassigned policies |
|---|---:|---:|---:|---:|
| CIS Microsoft Intune for Windows 11 Benchmark | 5.0.0 | 28 | 387 | 10 |
| CIS Microsoft Intune for Windows 10 Benchmark | 5.0.0 | 9 | 349 | 4 |
| CIS Microsoft Intune for Edge Benchmark | 1.0.0 | 13 | 125 | 2 |
| CIS Microsoft Intune for Office Benchmark | 1.1.0 | 2 | 236 | 1 |
| CIS Apple macOS 26 Tahoe Intune Benchmark | 1.0.0 | 1 | 99 | 1 |
| CIS Apple iOS 26 and iPadOS 26 Intune Benchmark | 1.0.0 | 1 | 93 | 1 |

The five additional Windows 10, Edge, Office, macOS, and iOS/iPadOS packs have passed
live dry-run validation and a real unassigned import with all mapped settings. The
Windows 11 pack has separately passed live mapping validation. No assignments are
created by any pack.

These numbers do **not** describe complete CIS baselines. Unresolved recommendations do
not create settings. More exact mappings can be added later without weakening the
fail-closed rules.

## What the tool will never do

- It never guesses a Microsoft Graph `settingDefinitionId`.
- It never guesses a choice or value ID.
- Ambiguous mappings remain unresolved.
- Organizational decisions require explicit administrator input.
- Non-policy and process controls remain manual.
- It never creates assignments.
- It never uploads or commits your CIS PDF.
- It never overwrites a different same-name Intune policy.

`cisAssessmentMethod` and `mappingStatus` mean different things. A CIS recommendation
marked `Manual` can still have an exact Intune policy mapping. `mappingStatus` records
whether this project can safely produce that mapping.

## Before you begin

You need:

1. A Windows computer.
2. [PowerShell 7](https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows).
3. [Git for Windows](https://git-scm.com/download/win).
4. [Python 3.11 or later](https://www.python.org/downloads/windows/).
5. A Microsoft Intune tenant.
6. An account allowed to read and create Intune device configuration policies.
7. The correct CIS Benchmark PDFs, downloaded under the applicable CIS terms.

Open **PowerShell 7** for all commands below. Do not use the older Windows PowerShell
5.1 application.

## Step 1: create a tools folder

```powershell
New-Item -ItemType Directory -Path C:\Tools -Force
Set-Location C:\Tools
```

## Step 2: download CISPolicyCreator

```powershell
git clone https://github.com/JoeryVandenBosch/CISPolicyCreator.git
Set-Location C:\Tools\CISPolicyCreator
```

If you already cloned it, update it instead:

```powershell
Set-Location C:\Tools\CISPolicyCreator
git pull
```

The scripts are already inside the repository's `scripts` folder. Do not copy the
scripts into another directory.

## Step 3: install the locked local requirements

```powershell
.\scripts\Initialize-CISPolicyCreator.ps1 -IncludeGraph
```

This creates repository-local `.venv` and `.modules` folders. It installs the exact
locked PDF parser and Microsoft Graph authentication module versions used by the tool.

Check the installation:

```powershell
.\scripts\Test-CISPrerequisites.ps1 -RequireGraph
```

## Step 4: create private working folders

```powershell
New-Item -ItemType Directory -Path .\private\pdf -Force
New-Item -ItemType Directory -Path .\private\graph -Force
New-Item -ItemType Directory -Path .\work\packs -Force
```

The `private` and `work` folders are ignored by Git.

## Step 5: download the correct CIS PDFs

Download only PDFs explicitly written for Microsoft Intune. Obtain them from the
[official CIS Microsoft Intune page](https://www.cisecurity.org/benchmark/intune) or
the [official CIS Intune for Apple page](https://www.cisecurity.org/benchmark/apple_macos_ios_intune).

Follow the CIS terms and licensing requirements. Never commit, publish, or upload the
PDFs to GitHub.

Save the PDFs in `C:\Tools\CISPolicyCreator\private\pdf`.

| Benchmark selector | Expected PDF | Suggested pack folder (`$PackPath`) |
|---|---|---|
| `Windows11-5.0.0` | `CIS_Microsoft_Intune_for_Windows_11_Benchmark_v5.0.0.pdf` | `.\work\packs\windows11-v5-pack` |
| `Windows10-5.0.0` | `CIS_Microsoft_Intune_for_Windows_10_Benchmark_v5.0.0.pdf` | `.\work\packs\windows10-v5-pack` |
| `Edge-1.0.0` | `CIS_Microsoft_Intune_for_Edge_Benchmark_v1.0.0.pdf` | `.\work\packs\edge-v1-pack` |
| `Office-1.1.0` | `CIS_Microsoft_Intune_for_Office_Benchmark_v1.1.0.pdf` | `.\work\packs\office-v1.1-pack` |
| `macOS26-Tahoe-1.0.0` | `CIS_Apple_MacOS_26_Tahoe_Intune_Benchmark_v1.0.0.pdf` | `.\work\packs\macos26-tahoe-v1-pack` |
| `iOS26-iPadOS26-1.0.0` | `CIS_Apple_iOS_26_and_iPadOS_26_Intune_Benchmark_v1.0.0.pdf` | `.\work\packs\ios26-ipados26-v1-pack` |

The pack folder is only the local output folder where the tool saves the generated
files. You may use any folder name you want. It does not become the Intune policy name.
The folder must not already exist when you build the pack; using the suggested names
above is easiest.

A generic Microsoft Edge, Microsoft Office, Apple operating system, Android, Chrome,
or Safari benchmark is not a substitute for an Intune-specific PDF.

## Step 6: record your tenant ID

Replace the example with your real Microsoft Entra tenant ID:

```powershell
$TenantId = '00000000-0000-0000-0000-000000000000'
```

## Step 7: export the current Intune Settings Catalog

```powershell
.\scripts\Export-SettingsCatalogDiagnostics.ps1 `
  -TenantId $TenantId `
  -UseDeviceCode `
  -OutputPath .\private\graph\settings-catalog-snapshot.json
```

PowerShell displays a Microsoft sign-in address and a short code. Open the address,
enter the code, sign in, and return to PowerShell. The export is private tenant evidence
used to prove that every mapped setting and option still exists.

If that output file already exists, give the new export a different filename. The tool
does not silently replace evidence files.

## Step 8: choose one benchmark

This example uses Windows 10:

```powershell
$Benchmark = 'Windows10-5.0.0'
$PdfPath = '.\private\pdf\CIS_Microsoft_Intune_for_Windows_10_Benchmark_v5.0.0.pdf'
$PackPath = '.\work\packs\windows10-v5-pack'
```

For another PDF, copy its selector, filename, and suggested `$PackPath` from the table
in Step 5. You may choose a different pack folder name if you prefer.

## Step 9: build the validated policy pack

```powershell
.\scripts\Build-CISSupportedBenchmark.ps1 `
  -Benchmark $Benchmark `
  -PdfPath $PdfPath `
  -SettingsCatalogSnapshotPath .\private\graph\settings-catalog-snapshot.json `
  -OutputPath $PackPath
```

The command checks the PDF title and version, extracts its recommendations locally,
validates the exact mappings against the snapshot, creates the unassigned policy
payloads, and validates the finished pack.

The output folder must not already exist. Use a new output name when rebuilding.

## Step 10: inspect the result

```powershell
.\scripts\Test-CISPolicyPack.ps1 -PackRoot $PackPath
.\scripts\Get-CISMappingReport.ps1 -PackRoot $PackPath
```

The report shows which recommendations are mapped, unresolved, require administrator
input, remain manual, or are not applicable.

## Step 11: perform a read-only Intune dry run

```powershell
.\scripts\Import-CISPolicyPack.ps1 `
  -PackRoot $PackPath `
  -Profile ALL `
  -TenantId $TenantId `
  -UseDeviceCode `
  -DryRun
```

The dry run signs in to Microsoft Graph, verifies the live setting definitions and
values, checks for same-name policies, and shows what would be created. It does not
write or assign anything.

## Step 12: import the unassigned policies

Only continue after the dry run succeeds:

```powershell
.\scripts\Import-CISPolicyPack.ps1 `
  -PackRoot $PackPath `
  -Profile ALL `
  -TenantId $TenantId `
  -UseDeviceCode `
  -ConfirmUnassignedImport `
  -ConfirmPartialPack
```

`-ConfirmPartialPack` means you understand that only the mapped subset is imported.
Unresolved recommendations remain absent.

The policies are created without assignments. CISPolicyCreator does not select users,
devices, or groups. Assignments and production rollout remain administrator actions.

## Step 13: check Intune

1. Open the Microsoft Intune admin center.
2. Go to **Devices**.
3. Open **Configuration**.
4. Search for policy names beginning with `CIS -`.
5. Open a policy and verify its settings.
6. Leave it unassigned until your organization has reviewed and tested it.

## Build the other supported PDFs

Repeat Steps 8 through 13 for each PDF. Always use the matching selector, exact PDF
version, and a different pack output folder.

## Common problems

### “Source eligibility check failed”

The PDF title or version does not match the selected catalog. Use the exact
Intune-specific PDF and selector from Step 5.

### “OutputPath already exists”

Choose a new pack folder name. Existing output is never overwritten automatically.

### “Runtime mapping validation failed”

A live Microsoft Graph definition or option differs from the reviewed catalog. The tool
stops before creating policies. Export a fresh Settings Catalog snapshot and investigate
the change; do not invent a replacement ID.

### “Existing-policy verification failed”

An Intune policy has the same name but different metadata or settings. The importer
refuses to assume they are equivalent. Review the existing policy manually.

### Microsoft says the sign-in code is invalid

Use the newest code shown in PowerShell. Device codes expire and old codes cannot be
reused.

## Privacy and repository safety

- CIS source PDFs stay in `private\pdf` and are ignored by Git.
- Raw extracted recommendation text is private and is not included in generated packs.
- Tenant snapshots stay in `private\graph` and are ignored by Git.
- Generated packs contain no credentials, assignments, source PDF, or AI artifacts.
- Before publishing changes, always check `git status` and ensure no private material is
  staged.

## Technical documentation

- [Fail-closed policy](docs/FAIL-CLOSED-POLICY.md)
- [PDF workflow](docs/PDF-WORKFLOW.md)
- [Policy pack format](docs/PACK-FORMAT.md)
- [Supported benchmark scope](docs/SUPPORTED-BENCHMARKS.md)
- [Security model](docs/SECURITY-MODEL.md)
- [Benchmark roadmap](docs/BENCHMARK-ROADMAP.md)

## License

Repository code is licensed under [LICENSE](LICENSE). CIS Benchmarks remain subject to
CIS terms and licensing requirements.
