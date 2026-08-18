# CISPolicyCreator

CISPolicyCreator reads a legitimately obtained CIS Benchmark PDF written specifically
for Microsoft Intune and builds a validated Intune policy pack. It can then export that
pack as a portable ZIP containing request-ready Intune policy JSON files. No tenant
login is needed to create the JSON bundle.

The repository also includes an optional fail-closed importer for test-tenant validation,
but importing or assigning policies is not required to use the policy-creation tool.

The tool runs entirely from the scripts in this repository. ChatGPT, Codex, or another
AI service is **not** required at runtime.

## What is complete, and what is intentionally skipped

The five newly completed Intune catalogs convert every recommendation that has a real,
deterministic Intune implementation. Recommendations that tell a human to review,
inspect, document, or run an operational process remain `manual` and produce no fake
JSON. Organization-specific values remain `requires-input` until an administrator
chooses them explicitly.

| Supported CIS PDF | Version | Mapped | Requires input | Manual | Unresolved | Policy JSON files with all inputs |
|---|---:|---:|---:|---:|---:|---:|
| CIS Microsoft Intune for Windows 10 Benchmark | 5.0.0 | 312 | 5 | 41 | 0 | 278 |
| CIS Microsoft Intune for Edge Benchmark | 1.0.0 | 135 | 3 | 0 | 0 | 138 |
| CIS Microsoft Intune for Office Benchmark | 1.1.0 | 238 | 0 | 0 | 0 | 234 |
| CIS Apple macOS 26 Tahoe Intune Benchmark | 1.0.0 | 85 | 14 | 1 | 0 | 83 |
| CIS Apple iOS 26 and iPadOS 26 Intune Benchmark | 1.0.0 | 85 | 8 | 1 | 0 | 61 |
| CIS Microsoft Intune for Windows 11 Benchmark | 5.0.0 | 154 | 0 | 0 | 261 | 154 |

The five rows with zero unresolved recommendations are complete for policy creation:
every actual Intune-configurable recommendation is either mapped or waiting for an
explicit administrator value. Windows 11 is the older partial catalog and is clearly
listed separately by its 261 unresolved recommendations.

The number of JSON files can be lower than the number of recommendations because some
CIS recommendations are duplicates or must be bundled with required dependent settings.
The JSON files are always unassigned. Live test-tenant dry runs and earlier import tests
provide additional evidence, but every administrator must validate policies before use.

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

After sign-in, downloading the complete Settings Catalog can take several minutes.
Messages such as `Retrieved Settings Catalog page 36 (500 definitions; 18000 total)`
mean the tool is still working normally. Leave PowerShell open and wait until it says
`Wrote ... definition(s)` and shows the output file path.

If that output file already exists, give the new export a different filename. The tool
does not silently replace evidence files.

Snapshots created before schema 1.2 do not contain the group-dependency evidence needed
for fail-closed builds. If the tool reports an older snapshot schema, export a fresh
snapshot with the current script rather than editing the JSON manually.

## Step 8: choose one benchmark

This example uses Windows 10:

```powershell
$Benchmark = 'Windows10-5.0.0'
$PdfPath = '.\private\pdf\CIS_Microsoft_Intune_for_Windows_10_Benchmark_v5.0.0.pdf'
$RunId = Get-Date -Format 'yyyyMMdd-HHmmss'
$PackPath = ".\work\packs\windows10-v5-$RunId"
$DecisionPath = $null
```

For another PDF, copy its selector, filename, and suggested `$PackPath` from the table
in Step 5. You may choose a different pack folder name if you prefer.

## Step 9: answer any administrator questions

Some CIS settings do not prescribe one universal value. For example, your organization
must choose its own minimum operating-system version or login-window message. The tool
will never invent those answers.

| Selector | Catalog path | Questions |
|---|---|---:|
| `Windows10-5.0.0` | `./benchmarks/cis-microsoft-intune-for-windows-10/5.0.0/mapping-catalog.json` | 6 |
| `Edge-1.0.0` | `./benchmarks/edge-intune/1.0.0/mapping-catalog.json` | 3 |
| `Office-1.1.0` | none | 0 |
| `macOS26-Tahoe-1.0.0` | `./benchmarks/macos26-tahoe-intune/1.0.0/mapping-catalog.json` | 15 |
| `iOS26-iPadOS26-1.0.0` | `./benchmarks/ios26-ipados26-intune/1.0.0/mapping-catalog.json` | 8 |
| `Windows11-5.0.0` | none | 0 |

If your selected row has questions, copy its catalog path and run:

```powershell
$CatalogPath = '.\benchmarks\edge-intune\1.0.0\mapping-catalog.json'
$DecisionPath = ".\private\$Benchmark-decisions.json"

.\scripts\New-CISAdministratorDecisions.ps1 `
  -MappingCatalogPath $CatalogPath `
  -OutputPath $DecisionPath

notepad $DecisionPath
```

For every question, enter an allowed `value`, change `acknowledged` to `true`, and add a
short `justification`. Keep this file private and never commit it. If the benchmark has
zero questions, do not set `$DecisionPath`.

## Step 10: create the validated pack and policy JSON ZIP

```powershell
$BundlePath = ".\work\$Benchmark-policies.zip"
$BuildArguments = @{
  Benchmark                   = $Benchmark
  PdfPath                     = $PdfPath
  SettingsCatalogSnapshotPath = '.\private\graph\settings-catalog-snapshot.json'
  OutputPath                  = $PackPath
  PolicyJsonBundlePath        = $BundlePath
  PolicyJsonBundleName        = "$Benchmark-policies"
  Profile                     = 'ALL'
}

if ($DecisionPath) {
  $BuildArguments.AdministratorDecisionsPath = $DecisionPath
}

.\scripts\Build-CISSupportedBenchmark.ps1 @BuildArguments
```

The command checks the PDF title and version, extracts its recommendations locally,
validates the exact mappings against the snapshot, creates the unassigned policy JSON
files, validates the pack and ZIP, and deletes the temporary raw CIS extraction.

The pack folder and ZIP must not already exist. Use new output names when rebuilding.
The ZIP contains one JSON policy for each actual configurable setting, except where
duplicate or dependent settings must be bundled together. Human-only recommendations
produce no JSON. No assignments are included.

## Step 11: inspect and validate the result

```powershell
.\scripts\Test-CISPolicyPack.ps1 -PackRoot $PackPath
.\scripts\Get-CISMappingReport.ps1 -PackRoot $PackPath
.\scripts\Test-CISWindowsStylePolicyBundle.ps1 -BundlePath $BundlePath
```

The report shows which recommendations are mapped, unresolved, require administrator

The ZIP contains:

- `SettingsCatalog\*.json`: importable Settings Catalog policies with exact settings;
- `DeviceConfigurations\*.json`, `CompliancePolicies\*.json`, or `GraphObjects\*.json`
  when a setting uses another typed Intune policy API.

The ZIP contains no CIS PDF, raw benchmark prose, credentials, assignments, tenant IDs,
or raw CIS recommendation text. It uses the same one-policy-per-setting naming and JSON
shape as the proven Windows reference export. Generated IDs exist only to preserve the
portable export shape and are deterministic.

The output path must end in lowercase `.zip` and must not already exist. Repeating the
same export with the same pack, snapshot, and profile produces the same ZIP bytes.

If you only want CISPolicyCreator to create importable policy JSON files, you are finished.
The remaining steps are optional tenant validation and import steps.

## Step 12: optionally perform a read-only Intune dry run

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

## Step 13: optionally import the unassigned policies

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

## Step 14: check Intune

1. Open the Microsoft Intune admin center.
2. Go to **Devices**.
3. Open **Configuration**.
4. Search for policy names beginning with `CIS -`.
5. Open a policy and verify its settings.
6. Leave it unassigned until your organization has reviewed and tested it.

## Build the other supported PDFs

Repeat Steps 8 through 14 for each PDF. Always use the matching selector, exact PDF
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
