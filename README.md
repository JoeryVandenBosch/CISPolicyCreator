# CISPolicyCreator

CISPolicyCreator reads a legitimately obtained CIS Benchmark PDF written specifically
for Microsoft Intune and builds a validated Intune policy pack. It can then export that
pack as a portable ZIP containing request-ready Intune policy JSON files. No tenant
login is needed to create the JSON bundle.

The repository also includes an optional fail-closed importer for test-tenant validation,
but importing or assigning policies is not required to use the policy-creation tool.

The tool runs entirely from the scripts in this repository. ChatGPT, Codex, or another
AI service is **not** required at runtime.

> **Independent project notice:** CISPolicyCreator is an independent publication and
> has not been authorized, sponsored, or otherwise approved by the Center for Internet
> Security, Inc. It is provided as a free, non-commercial community project. It is not
> an official CIS Build Kit and does not claim CIS certification, endorsement,
> compliance, or a particular level of consistency with a CIS Benchmark. See
> [Licensing and third-party rights](LICENSING.md) before public, redistributed, or
> commercial use.

## What the status numbers mean

Each CIS benchmark contains a list of security recommendations. This project reviews
every recommendation and puts it into one of four groups. The status describes what
this tool can safely do; it is not a score and it does not mean that recommendations
outside `Mapped` are unimportant.

| Status | Plain-English meaning | Does this tool create policy JSON? | What you need to do |
|---|---|---|---|
| **Mapped** | The exact Intune setting and the exact required value are known and validated. The tool does not need to guess. | **Yes.** A mapped recommendation is included in the generated policies. | Review and test the generated policy before assigning it. |
| **Requires input** | The Intune setting is known, but the correct value depends on your organization. CIS does not provide one universal answer. Examples include a firewall log path, telemetry choice, or session timeout. | **Yes, after you provide the requested value.** No policy is generated from a guessed value. | Choose and supply the value when building the pack. |
| **Manual** | This recommendation needs a person, a documented process, or custom work that this tool cannot honestly represent as a normal Intune policy. For example, it may require an inspection or custom PowerShell handling. | **No.** The tool does not create a fake policy just to increase the count. | Complete and record the action outside this policy pack. |
| **Unresolved** | A safe, complete Intune implementation has not yet been proven. The recommendation is tracked, but the tool does not have enough evidence or required companion settings to create a deployable policy. | **No.** Nothing is generated until the implementation can be proven. | Treat it as not implemented by this tool and handle it separately. |

`Manual` and `Unresolved` are different. `Manual` means we know the recommendation
belongs in a human, process, or custom workflow. `Unresolved` means an automated
implementation may be possible, but this project cannot yet produce it safely and
completely.

## Current benchmark coverage

For each row, `Mapped + Requires input + Manual + Unresolved` equals the total number
of CIS recommendations reviewed in that benchmark.

| Supported CIS PDF | Version | Mapped (ready) | Requires input (you choose) | Manual (human/custom work) | Unresolved (not safely implemented) | Policy JSON files after all inputs |
|---|---:|---:|---:|---:|---:|---:|
| CIS Microsoft Intune for Windows 10 Benchmark | 5.0.0 | 312 | 5 | 41 | 0 | 278 |
| CIS Microsoft Intune for Edge Benchmark | 1.0.0 | 135 | 3 | 0 | 0 | 138 |
| CIS Microsoft Intune for Office Benchmark | 1.1.0 | 238 | 0 | 0 | 0 | 234 |
| CIS Apple macOS 26 Tahoe Intune Benchmark | 1.0.0 | 84 | 14 | 1 | 1 | 82 |
| CIS Apple iOS 26 and iPadOS 26 Intune Benchmark | 1.0.0 | 84 | 8 | 1 | 1 | 60 |
| CIS Microsoft Intune for Windows 11 Benchmark | 5.0.0 | 371 | 8 | 36 | 0 | 326 |

For example, the Windows 11 row covers all 415 recommendations:
`371 + 8 + 36 + 0 = 415`. After the required organization-specific choices are
provided, the tool creates 326 policy JSON files. The file count is lower because
manual and unresolved recommendations create no JSON, duplicate recommendations can
share one implementation, and settings that depend on each other may be bundled into
one policy.

A benchmark with zero unresolved recommendations is complete **for this tool's policy
creation scope**. It does not mean that every recommendation becomes JSON. It means
that every recommendation has been deliberately classified as mapped, waiting for an
administrator choice, or requiring human/custom work.

macOS and iOS/iPadOS each have one intentionally unresolved Locked enrollment
recommendation (macOS 2.13.1 and iOS/iPadOS 3.10.1). The relevant Intune setting is
known, but Microsoft requires a complete ADE enrollment policy. Several companion
settings need organization-specific choices and have no safe default. The tool therefore
refuses to invent those choices or create JSON that Intune would reject.

All generated JSON files are unassigned. Always review and test them before production
use.

## What the tool will never do

- It never guesses a Microsoft Graph `settingDefinitionId`.
- It never guesses a choice or value ID.
- Ambiguous mappings remain unresolved.
- Organizational decisions require explicit administrator input.
- Non-policy and process controls remain manual.
- It never creates assignments.
- It never uploads or commits your CIS PDF.
- It never overwrites a different same-name Intune policy.

One final terminology note: CIS also labels how a recommendation is assessed as
`Automated` or `Manual`. That is separate from the project status explained above. A
recommendation that CIS says must be checked manually can still be `Mapped` here when
the exact Intune configuration is known. The table reports this project's implementation
status, not the CIS assessment method.

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

Every step below explains what the command does, why it is needed, and what you should
have when it finishes.

## Step 1: create a tools folder

**What this does:** Creates `C:\Tools` if it does not already exist and makes it the
current folder in this PowerShell window. `-Force` allows PowerShell to reuse an existing
folder; it does not erase that folder or its contents.

**Why this is needed:** It gives the repository a predictable local location, which
makes the remaining paths and commands easier to follow.

```powershell
New-Item -ItemType Directory -Path C:\Tools -Force
Set-Location C:\Tools
```

**Outcome:** Your PowerShell prompt is working from `C:\Tools`. Nothing has been
downloaded and nothing in Intune has been accessed.

## Step 2: download CISPolicyCreator

**What this does:** Downloads a local copy of this GitHub repository and then moves the
PowerShell prompt into it.

```powershell
git clone https://github.com/JoeryVandenBosch/CISPolicyCreator.git
Set-Location C:\Tools\CISPolicyCreator
```

If you already cloned it, update it instead:

```powershell
Set-Location C:\Tools\CISPolicyCreator
git pull
```

**Why this is needed:** The repository contains the build scripts, reviewed mapping
catalogs, validation rules, and locked dependency versions that must be used together.
The scripts expect this repository structure, so do not copy individual scripts to a
different folder.

**Outcome:** `C:\Tools\CISPolicyCreator` contains the latest repository files and is the
current folder. This step does not download CIS PDFs and does not connect to Intune.

## Step 3: install the locked local requirements

**What this does:** Creates a Python virtual environment in `.venv`, downloads the exact
hash-locked PDF parser packages, and—with `-IncludeGraph`—downloads the pinned Microsoft
Graph authentication module into `.modules`. Both locations are inside this repository;
the command does not install these packages system-wide.

```powershell
.\scripts\Initialize-CISPolicyCreator.ps1 -IncludeGraph
```

**Why this is needed:** Locked versions make parsing and Graph sign-in behavior
repeatable and prevent an unreviewed package update from silently changing a build.
Internet access is required while missing packages are downloaded. This command installs
the Graph sign-in component but does not sign in or access your tenant.

Check the installation:

```powershell
.\scripts\Test-CISPrerequisites.ps1 -RequireGraph
```

**Outcome:** The check prints the detected PowerShell version, Python version, PDF parser
version, and Graph authentication module version. Continue only when the check completes
without an error.

## Step 4: create private working folders

**What this does:** Creates three local folders. Existing folders are reused without
deleting their contents.

```powershell
New-Item -ItemType Directory -Path .\private\pdf -Force
New-Item -ItemType Directory -Path .\private\graph -Force
New-Item -ItemType Directory -Path .\work\packs -Force
```

**Why this is needed:** `private\pdf` holds licensed CIS source PDFs,
`private\graph` holds tenant-specific Settings Catalog evidence, and `work\packs` holds
generated build output. Keeping them separate reduces the chance of publishing private
inputs accidentally.

**Outcome:** The three empty or existing folders are ready. The repository ignores
`private` and `work` in Git, but you must still avoid manually committing or sharing
private files.

## Step 5: download the correct CIS PDFs

**What this does:** You manually download the licensed, Intune-specific CIS Benchmark
PDF for the product and version you want to build. CISPolicyCreator does not download a
CIS PDF for you.

Download only PDFs explicitly written for Microsoft Intune. Obtain them from the
[official CIS Microsoft Intune page](https://www.cisecurity.org/benchmark/intune) or
the [official CIS Intune for Apple page](https://www.cisecurity.org/benchmark/apple_macos_ios_intune).

Follow the CIS terms and licensing requirements. Never commit, publish, or upload the
PDFs to GitHub.

The CIS non-member terms currently refer to CC BY-NC-SA 4.0 for Benchmark PDFs and also
state additional restrictions, including a restriction on direct derivative works.
This project does not resolve or interpret that tension as permission. If you plan to
publish, redistribute, or use benchmark-derived catalogs or policy bundles commercially,
obtain written permission from CIS or qualified legal advice first. See
[Licensing and third-party rights](LICENSING.md).

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

**Why this is needed:** Each selector is tied to one exact benchmark title and version.
The tool extracts recommendation IDs from that PDF and compares them with the matching
reviewed catalog. A generic or different-version PDF would not describe the same Intune
policy set, so the build rejects it.

**Outcome:** The exact PDF for your chosen selector exists in
`C:\Tools\CISPolicyCreator\private\pdf`. No policy has been generated or imported yet.

## Step 6: record your tenant ID

**What this does:** Stores your Microsoft Entra tenant ID in a temporary PowerShell
variable named `$TenantId`.

Replace the example with your real Microsoft Entra tenant ID:

```powershell
$TenantId = '00000000-0000-0000-0000-000000000000'
```

**Why this is needed:** Later Graph commands use this value to pin sign-in to the
intended tenant and reject an authenticated session for a different tenant.

**Outcome:** `$TenantId` is available to later commands in this PowerShell window. This
step does not validate the ID, sign in, or change the tenant. If you close PowerShell,
set the variable again in the new window.

## Step 7: download a read-only Settings Catalog lookup file

**What this does:** Signs in to Microsoft Graph with the read-only
`DeviceManagementConfiguration.Read.All` permission, downloads Microsoft's current
Settings Catalog definitions, and saves them as a private JSON lookup file. The script
only calls the Settings Catalog definition endpoint.

This step does **not** export your existing Intune policies. It does not create, edit,
assign, or delete policies, and it does not export assignments, users, devices,
compliance results, or the contents of your existing policies.

Think of this file as a current dictionary for the tool. It contains:

- the internal Microsoft Graph ID for each setting;
- the allowed values and data type for each setting; and
- required parent, child, and dependency relationships between settings.

**Why this is needed:** An Intune policy refers to internal Microsoft Graph IDs, not
only to the friendly setting names shown in the Intune portal. During a build, the tool
checks every reviewed CIS mapping against this current lookup. If an ID, value, or
required companion setting is missing, the build stops instead of producing policy JSON
that Intune may reject or interpret incorrectly.

```powershell
.\scripts\Export-SettingsCatalogDiagnostics.ps1 `
  -TenantId $TenantId `
  -UseDeviceCode `
  -OutputPath .\private\graph\settings-catalog-snapshot.json
```

PowerShell displays a Microsoft sign-in address and a short code. Open the address,
enter the code, sign in, and return to PowerShell. The sign-in authorizes this read-only
download. The resulting file is also build evidence: it records which catalog IDs,
values, and dependencies Microsoft returned when the policies were generated.

After sign-in, downloading the complete Settings Catalog can take several minutes.
Messages such as `Retrieved Settings Catalog page 36 (500 definitions; 18000 total)`
mean the tool is still working normally. Leave PowerShell open and wait until it says
`Wrote ... definition(s)` and shows the output file path.

Keep the resulting JSON in `private`; it contains your tenant ID and tenant-specific
retrieval evidence and should not be committed to Git. If that output file already
exists, give the new export a different filename. The tool does not silently replace
evidence files.

Snapshots created before schema 1.2 do not contain the group-dependency evidence needed
for fail-closed builds. If the tool reports an older snapshot schema, export a fresh
snapshot with the current script rather than editing the JSON manually.

**Outcome:** `private\graph\settings-catalog-snapshot.json` contains a current,
tenant-observed Settings Catalog dictionary and its retrieval evidence. Continue only
after PowerShell reports `Wrote ... definition(s)` and the output path. No Intune policy
has been changed.

## Step 8: choose one benchmark

**What this does:** Sets local variables that tell the build which supported benchmark
to use, where its PDF is located, and where new output should be written. It does not
run the build yet.

This example uses Windows 10:

```powershell
$Benchmark = 'Windows10-5.0.0'
$PdfPath = '.\private\pdf\CIS_Microsoft_Intune_for_Windows_10_Benchmark_v5.0.0.pdf'
$RunId = Get-Date -Format 'yyyyMMdd-HHmmss'
$PackPath = ".\work\packs\windows10-v5-$RunId"
$DecisionPath = $null
```

**Why this is needed:** The selector, PDF, and reviewed mapping catalog must describe the
same product and benchmark version. `$RunId` adds the current date and time to the pack
folder name so a new build does not overwrite an older one. `$DecisionPath` starts as
`$null` because Step 9 has not created an answer file yet.

For another PDF, copy its selector, filename, and suggested `$PackPath` from the table
in Step 5. You may choose a different pack folder name if you prefer.

One build handles exactly one selector. Windows 10 and Windows 11 are never combined by
this command; build them separately with different output paths.

**Outcome:** `$Benchmark`, `$PdfPath`, `$PackPath`, and `$DecisionPath` are ready in the
current PowerShell window. No file has been created and no tenant has been contacted.

## Step 9: answer any administrator questions

**What this does:** Creates a local JSON questionnaire for settings where CIS requires
an organization-specific value. You edit that file and explicitly record each chosen
value, your acknowledgement, and a short justification. The command only reads the
repository's mapping catalog and writes the questionnaire; it does not contact Intune.

Some CIS settings do not prescribe one universal value. For example, your organization
must choose its own minimum operating-system version or login-window message. The tool
will never invent those answers.

A single recommendation can need more than one value. Therefore, the number of answer
fields can be higher than the number of recommendations marked `Requires input`. For
Windows 11, eight recommendations need administrator input, but one of them needs two
values, so the generated decision file contains nine answer fields.

| Selector | Catalog path | Recommendations needing input | Answer fields |
|---|---|---:|---:|
| `Windows10-5.0.0` | `./benchmarks/cis-microsoft-intune-for-windows-10/5.0.0/mapping-catalog.json` | 5 | 6 |
| `Edge-1.0.0` | `./benchmarks/edge-intune/1.0.0/mapping-catalog.json` | 3 | 3 |
| `Office-1.1.0` | none | 0 | 0 |
| `macOS26-Tahoe-1.0.0` | `./benchmarks/macos26-tahoe-intune/1.0.0/mapping-catalog.json` | 14 | 15 |
| `iOS26-iPadOS26-1.0.0` | `./benchmarks/ios26-ipados26-intune/1.0.0/mapping-catalog.json` | 8 | 8 |
| `Windows11-5.0.0` | `./benchmarks/cis-microsoft-intune-for-windows-11/5.0.0/mapping-catalog.json` | 8 | 9 |

If your selected row has questions, copy its catalog path and run:

```powershell
$CatalogPath = '.\benchmarks\cis-microsoft-intune-for-windows-10\5.0.0\mapping-catalog.json'
$DecisionPath = ".\private\$Benchmark-decisions.json"

.\scripts\New-CISAdministratorDecisions.ps1 `
  -MappingCatalogPath $CatalogPath `
  -OutputPath $DecisionPath

notepad $DecisionPath
```

The example now matches the Windows 10 selector from Step 8. If you selected another
benchmark, use that benchmark's catalog path from the table.

**Why this is needed:** Values such as a company message or minimum OS version cannot
be chosen safely by the tool. Requiring a recorded answer prevents an arbitrary default
from entering a security policy unnoticed.

For every question, enter an allowed `value`, change `acknowledged` to `true`, and add a
short `justification`. Keep this file private and never commit it. If the benchmark has
zero questions, do not run the questionnaire command and leave `$DecisionPath` as
`$null`. The questionnaire output path must not already exist; use a new filename when
creating another one.

**Outcome:** For a benchmark with questions, `$DecisionPath` points to a completed,
private decisions file. For a benchmark without questions, it remains `$null`. The
builder can now either apply every required answer or stop clearly if one is missing or
invalid.

## Step 10: create the validated pack and policy JSON ZIP

**What this does:** Runs the complete local build for the one benchmark selected in
Step 8.

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

In order, the command:

1. checks that the PDF title and version match `$Benchmark`;
2. extracts the recommendation structure locally from the PDF;
3. compares it with the reviewed repository mapping catalog;
4. applies the completed administrator decisions, when required;
5. validates every setting ID, value, and dependency against the Step 7 snapshot;
6. creates the evidence pack and unassigned policy JSON files;
7. creates and validates the policy ZIP; and
8. deletes the temporary raw CIS text extraction.

**Why this is needed:** This fail-closed pipeline ties the source PDF, reviewed mappings,
administrator choices, live catalog evidence, and generated JSON together. If they do
not agree, the build stops instead of guessing or silently producing incomplete output.

The pack folder and ZIP must not already exist. Use new output names when rebuilding.
The ZIP contains one JSON policy for each actual configurable setting, except where
duplicate or dependent settings must be bundled together. Human-only recommendations
produce no JSON. No assignments are included.

This is still a local operation. It reads the local PDF, catalog, decisions, and
snapshot; it does not sign in to Graph or create anything in Intune.

**Outcome:** `$PackPath` contains the traceable build evidence and `$BundlePath` is a ZIP
containing the importable, unassigned policy JSON for only the selected benchmark. The
command ends with validation results; continue only when it reports success.

## Step 11: inspect and validate the result

**What this does:** Runs three local checks against the pack and ZIP created in Step 10.
These commands do not sign in to Microsoft Graph or change Intune.

```powershell
.\scripts\Test-CISPolicyPack.ps1 -PackRoot $PackPath
.\scripts\Get-CISMappingReport.ps1 -PackRoot $PackPath
.\scripts\Test-CISWindowsStylePolicyBundle.ps1 -BundlePath $BundlePath
```

Each command answers a different question:

| Command | What it checks or displays |
|---|---|
| `Test-CISPolicyPack.ps1` | Checks the evidence pack's schemas, hashes, source identity, mapping records, counts, and internal consistency. |
| `Get-CISMappingReport.ps1` | Displays the human-readable recommendation totals and classifications: mapped, requires input, manual, and unresolved. |
| `Test-CISWindowsStylePolicyBundle.ps1` | Opens the ZIP and strictly checks every supported policy JSON shape, value, filename, dependency, and absence of assignments. |

**Why this is needed:** A build can create files and still be unsuitable for import if a
file was later changed, a count no longer matches, or the ZIP contract is wrong. These
checks independently verify the evidence and the portable policy output before you use
it.

The ZIP contains:

- `NOTICE.txt`: licensing, attribution, trademark, and independent-project notice;
- `SettingsCatalog\*.json`: importable Settings Catalog policies with exact settings;
- `DeviceConfigurations\*.json`, `CompliancePolicies\*.json`, or `GraphObjects\*.json`
  when a setting uses another typed Intune policy API.

The ZIP contains no CIS PDF, raw benchmark prose, credentials, assignments, tenant IDs,
or raw CIS recommendation text. It uses the same one-policy-per-setting naming and JSON
shape as the proven Windows reference export. Generated IDs exist only to preserve the
portable export shape and are deterministic.

Repeating the same export with the same pack, snapshot, decisions, and profile produces
the same ZIP bytes.

**Outcome:** All test commands finish with a pass result, the report explains how every
recommendation was classified, and you understand exactly what is—and is not—in the
ZIP. If any check fails, do not import the ZIP; fix the reported cause and create a new
pack and ZIP.

If you only want CISPolicyCreator to create importable policy JSON files, you are finished.
The remaining steps are optional tenant validation and import steps.

## Step 12: optionally validate the ZIP for import

**What this does:** Runs the importer's own offline preflight against the complete ZIP.
It reads each file directly from the ZIP and prepares the exact request shape that the
importer would use, but stops before authentication.

```powershell
.\scripts\Import-CISWindowsStylePolicyBundle.ps1 `
  -BundlePath $BundlePath `
  -ValidateOnly
```

**Why this is needed:** Step 11 validates the exported bundle; this step additionally
proves that the importer accepts every policy type and pinned API contract. It rejects
assignments, unexpected properties, unsupported operations, and malformed payloads
before any sign-in can occur.

**Outcome:** PowerShell reports `PASS: offline import preparation succeeded` and prints
the numbers of Settings Catalog policies, typed Graph objects, tenant-wide updates, and
assignments. The bundle validator also requires the exact `NOTICE.txt`. Assignments must
be `none`. No Graph connection is made and no Intune data is read or changed.

## Step 13: optionally perform a read-only Intune dry run

**What this does:** Signs in with the read-only
`DeviceManagementConfiguration.Read.All` permission and compares the ZIP with the live
Intune tenant. It validates current setting definitions, values, templates, required
companion settings, and existing objects with the same name.

```powershell
.\scripts\Import-CISWindowsStylePolicyBundle.ps1 `
  -BundlePath $BundlePath `
  -TenantId $TenantId `
  -UseDeviceCode `
  -DryRun
```

**Why this is needed:** The Step 7 snapshot proves what Microsoft returned when you
built the ZIP, but the live tenant can change afterward. The dry run is the final check
for retired definitions, changed requirements, exact existing matches, or conflicting
same-name policies before granting write permission.

The dry run uses GET/read operations only. It shows which objects would be created,
which exact existing matches would be skipped, and whether a conflicting object blocks
the import. It never creates, updates, assigns, or deletes anything. Depending on bundle
size, it can take several minutes.

**Outcome:** The console shows a complete dry-run result and a timestamped
`*-import-results-*.json` file is written next to the ZIP. Continue only if all live
validation passes and every proposed action is expected.

## Step 14: optionally import the unassigned policies

**What this does:** Signs in with
`DeviceManagementConfiguration.ReadWrite.All`, repeats all offline and live validation,
and then creates the missing policy objects in Intune. It does not assign them to any
user, device, or group.

Only continue after the dry run succeeds:

```powershell
.\scripts\Import-CISWindowsStylePolicyBundle.ps1 `
  -BundlePath $BundlePath `
  -TenantId $TenantId `
  -UseDeviceCode `
  -ConfirmUnassignedImport
```

`-ConfirmUnassignedImport` is an explicit acknowledgement that you intend to perform
write operations and that the new policies will be unassigned.

**Why this is needed:** Generating a ZIP is separate from changing a tenant. This
deliberate import step lets an administrator review the exact bundle and dry-run result
before granting write access.

The importer validates the entire ZIP before signing in, validates every exact live
Graph definition and value before its first write, validates exact template references
and all live-required companion settings, and refuses a different same-name policy. An
exactly matching policy is left unchanged. Creation stops on the first Graph error
unless you explicitly add `-ContinueOnError`.

Import is not an all-or-nothing transaction. If Microsoft Graph returns an error after
some policies have been created, those earlier policies remain in Intune. The timestamped
results file records each created, skipped, updated, or failed object. Review that file
before retrying. Avoid `-ContinueOnError` unless you deliberately accept a partial
result.

The iOS/iPadOS bundle contains 58 assignable policy objects plus two tenant-wide Intune
settings. They are not assignable policies. For the safest policy-only import, add
`-SkipTenantWideSettings`.
To apply those two settings instead, review them and explicitly add
`-ConfirmTenantWideSettingsUpdate`. The importer refuses to choose between these two
options for you.

The bundle does not contain CIS recommendation 3.10.1 (Locked enrollment). Microsoft
requires a complete ADE profile for that setting, including enrollment and Setup
Assistant decisions that CIS does not choose. macOS recommendation 2.13.1 is omitted for
the same reason. Both remain `unresolved`; the tool emits no fake or incomplete JSON.

The policies are created without assignments. CISPolicyCreator does not select users,
devices, or groups, and the importer contains no assignment operation. Assignments and
production rollout remain administrator actions.

**Outcome:** Missing policies are created unassigned, exact existing matches are left
unchanged, and a timestamped `*-import-results-*.json` file next to the ZIP records the
result. A same-name object with different settings blocks the import rather than being
overwritten. No policy affects users or devices until an administrator later assigns
it in Intune. Tenant-wide settings are the explicitly confirmed exception described
above and can take effect without an assignment.

## Step 15: check Intune

**What this does:** You manually inspect the imported objects in the Intune admin center.
This is a review step; opening and viewing a policy does not assign or deploy it.

1. Open the [Microsoft Intune admin center](https://intune.microsoft.com/).
2. Go to **Devices** > **Manage devices** > **Configuration**.
3. Search for policy names beginning with `V5-CIS-` for the Windows 10 or Windows 11
   v5 benchmarks. Other benchmark versions use the same `V<major>-CIS-` convention.
4. Open a policy and verify its settings.
5. Leave it unassigned until your organization has reviewed and tested it.

**Why this is needed:** A successful API response proves that Intune accepted an object;
it does not replace an administrator's review of the policy name, platform, scope, and
settings in the destination tenant.

**Outcome:** You have confirmed that the expected policies exist with the expected
settings and no assignments. The policies are still inactive. Assignment, pilot testing,
monitoring, and production rollout are separate administrator-controlled activities.

## Build the other supported PDFs

Repeat Steps 8 through 15 for each PDF. Always use the matching selector, exact PDF
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

The original software and general documentation are licensed under the
[MIT License](LICENSE). Original contributor rights in `benchmarks` are offered under
[CC BY-NC-SA 4.0](https://creativecommons.org/licenses/by-nc-sa/4.0/) to the extent those
rights apply. This does not license CIS-owned material or trademarks and does not
override CIS's additional terms.

Read [Licensing and third-party rights](LICENSING.md) for the directory-level scope,
attribution, independent-project disclaimer, commercial-use warning, and links to the
current CIS terms. Generated policy ZIPs include a copy of `benchmarks/NOTICE.txt` when
created with the current exporter.
