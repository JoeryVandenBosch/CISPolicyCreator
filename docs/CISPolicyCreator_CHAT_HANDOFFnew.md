# CISPolicyCreator – Chat Handoff

> **Historical note:** This handoff records the original v0.1 framework state. The normative v0.2 architecture and safety model are now documented in `README.md`, `docs/FAIL-CLOSED-POLICY.md`, `docs/PACK-FORMAT.md`, and `docs/PDF-WORKFLOW.md`. In v0.2, `cisAssessmentMethod` is independent from the five-state `mappingStatus`, and the reproducible scripting pipeline takes priority over additional benchmark catalogs.

**Date:** 2026-08-14  
**Repository:** `https://github.com/JoeryVandenBosch/CISPolicyCreator`

## 1. Goal

Build a reusable, public GitHub project named **CISPolicyCreator** that can turn **CIS Benchmarks explicitly authored for Microsoft Intune** into deployable Intune policy packs.

The project must be conservative and **fail closed**:

> If a CIS recommendation cannot be mapped confidently to a real Intune policy/API setting, it must be marked `manual` or `unresolved` instead of generating a speculative deployment.

The project is intentionally **not** a generic “CIS-to-any-MDM” translator.

---

## 2. Scope

Only use CIS benchmark PDFs that are explicitly Intune-oriented.

### In scope

1. **CIS Microsoft Intune for Windows 11 Benchmark v5.0.0**
   - Already implemented and successfully imported into a test tenant.
   - This is the proven reference implementation.

2. **CIS Apple macOS 26 Tahoe Intune Benchmark v1.0.0**
   - Next benchmark to implement.

3. **CIS Microsoft Intune for Apple iOS 17 and iPadOS 17 Benchmark v2.0.0**
   - Planned after macOS.

### Out of scope

Do not automatically convert the generic platform/browser benchmarks below, even if some individual settings could technically be managed through Intune:

- CIS Apple iOS 26 Benchmark
- CIS Apple iPadOS 26 Benchmark
- CIS Apple macOS 26 Tahoe Benchmark
- CIS Google Android Benchmark
- CIS Google Chrome Enterprise Core Browser Benchmark
- CIS Microsoft Edge Benchmark
- CIS macOS Safari Benchmark archive

These may contain useful settings, but they are not dedicated CIS-for-Intune benchmarks and therefore require translation assumptions that the project is intentionally avoiding.

---

## 3. Proven Windows 11 v5 implementation

A working Intune deployment pack was built from:

- Official CIS Microsoft Intune for Windows 11 Benchmark v5.0.0 PDF
- Existing Inforcer CIS Windows 11 v4 export

The final deployment approach proved the following concepts:

- Settings Catalog deep-create via Microsoft Graph
- Runtime resolution of `settingDefinitionId`
- Exact choice/simple value validation
- Removal of GET-only / response-only OData metadata
- Duplicate policy detection
- Existing-policy readback and exact metadata/setting/value verification before skip
- Tenant validation
- `-DryRun`
- Temporary Graph write probe
- Compliance policy creation
- No automatic assignments
- Detailed Graph error reporting
- Fail-safe re-runs

### Key Graph issue discovered

Current Intune requires Settings Catalog settings to be embedded in the initial policy POST. An empty policy POST fails because `Settings` is required.

### WUfB issue discovered and fixed

The first Windows Update for Business import failed because an inherited source object contained response-only Graph metadata such as:

- `@odata.id`
- `@odata.editLink`
- `settingDefinitions@odata.associationLink`
- `settingDefinitions@odata.navigationLink`

The repair also removed an inherited `Defer Quality Updates Period in Days = 0` setting because it was not part of CIS Windows 11 v5 section 104.

Final result:

- **35 / 35 L1 + BL configuration policies**
- **1 compliance policy**
- **No assignments**

This implementation is the reference behavior for CISPolicyCreator.

---

## 4. Fail-closed design

The project uses these recommendation states:

### `mapped`

A real deployable Intune mapping has been verified.

Requirements include:

- Exact Intune policy type is known
- Graph endpoint/object type is known
- Exact setting or definition can be resolved
- Desired value is known and validated
- No speculative translation is required

Only `mapped` recommendations may be deployed.

### `manual`

The CIS recommendation is valid but requires a manual action, review, or process outside the supported automation path.

### `unresolved`

The recommendation may be automatable, but the exact Intune / Graph mapping has not yet been proven.

### `not-applicable`

The recommendation is intentionally not applicable to the selected platform/profile/scope.

### Important rule

**Extraction from a PDF never automatically means deployment.**

Anything extracted from a CIS PDF starts as unresolved until reviewed and mapped.

---

## 5. Repository architecture

The intended repository structure is:

```text
CISPolicyCreator/
├─ .github/
├─ benchmarks/
│  ├─ windows11/
│  │  └─ 5.0.0/
│  ├─ macos26-tahoe-intune/
│  │  └─ 1.0.0/
│  └─ ios17-ipados17-intune/
│     └─ 2.0.0/
├─ docs/
├─ schemas/
├─ scripts/
├─ src/
├─ templates/
├─ tools/
├─ README.md
├─ CHANGELOG.md
├─ CONTRIBUTING.md
├─ LICENSE
└─ .gitignore
```

A benchmark pack should evolve toward:

```text
benchmarks/
└─ macos26-tahoe-intune/
   └─ 1.0.0/
      ├─ benchmark.json
      ├─ recommendations.json
      ├─ policies/
      ├─ unresolved.json
      ├─ manual.json
      └─ mapping-report.csv
```

---

## 6. Repository package created

A reusable **CISPolicyCreator v0.1.0** framework was created with:

- Generic PowerShell module
- `Import-CISPolicyPack.ps1`
- `Test-CISPolicyPack.ps1`
- `New-CISPolicyPack.ps1`
- `Get-CISMappingReport.ps1`
- Settings Catalog diagnostics
- Repository publishing helper
- Runtime Settings Catalog resolution
- Graph deep-create logic
- OData metadata cleanup
- Tenant pinning
- Probe / dry-run support
- Endpoint restrictions
- Assignment blocking
- JSON schemas
- GitHub Actions validation
- Mapping-gap issue template
- Security / contribution docs
- PDF extraction helper
- Fail-closed documentation

The PDF extraction helper intentionally creates unresolved recommendation candidates only.

---

## 7. Fail-closed documentation created

Two files were created:

- `docs/FAIL-CLOSED-POLICY.md`
- `docs/CISPolicyCreator_Fail_Closed_Mapping_Policy.docx`

The documentation covers:

- Mapping states
- Deployment gating
- Runtime validation
- Graph drift
- Auditability
- `-ProbeOnly`
- `-DryRun`
- No automatic assignments
- Definition of done for a benchmark pack

---

## 8. GitHub state

Repository:

```text
https://github.com/JoeryVandenBosch/CISPolicyCreator
```

The repository was initially empty except for a tiny README.

The local package was pushed successfully afterward.

The live repo now contains the expected top-level structure, including:

- `.github`
- `benchmarks`
- `docs`
- `schemas`
- `scripts`
- `src`
- `templates`
- `tools`
- `README.md`
- `CHANGELOG.md`
- `CONTRIBUTING.md`
- `LICENSE`

The docs folder contains the fail-closed Markdown and Word documents.

---

## 9. Repository cleanup still recommended

The pushed repository was found to contain two unwanted items:

### Duplicate nested repository

A full duplicate exists under:

```text
CISPolicyCreator/
```

inside the repository root.

This duplicates folders such as:

```text
CISPolicyCreator/benchmarks
CISPolicyCreator/docs
CISPolicyCreator/scripts
CISPolicyCreator/src
...
```

### Local Git bundle

This file also exists at repository root:

```text
CISPolicyCreator_v0.1.0.bundle
```

Both should be removed.

Recommended commands:

```powershell
cd C:\Temp\CISPolicyCreator

git rm -r CISPolicyCreator
git rm CISPolicyCreator_v0.1.0.bundle

git commit -m "Remove duplicate repository copy and local git bundle"
git push
```

---

## 10. GitHub integration limitation

The ChatGPT GitHub connector could read the repository but direct write attempts returned:

```text
403 Resource not accessible by integration
```

The root cause found was that the ChatGPT GitHub App installation did not include `CISPolicyCreator` in its allowed repository list.

The app installation did include other repositories such as:

- BaselineSyncPro
- Sartoria
- AIFramework

If direct GitHub editing from ChatGPT is desired later, add `CISPolicyCreator` to the GitHub App installation repository access.

---

## 11. Current next milestone

Implement:

# CIS Apple macOS 26 Tahoe Intune Benchmark v1.0.0

Workflow:

1. Parse every CIS recommendation.
2. Preserve:
   - CIS recommendation ID
   - profile applicability
   - policy area
   - remediation path
   - required state/value
3. Classify each control as:
   - `mapped`
   - `manual`
   - `unresolved`
   - `not-applicable`
4. Map only verified controls to real Intune / Graph objects.
5. Resolve current Intune setting definitions dynamically where possible.
6. Generate policy payloads.
7. Run structural validation.
8. Run Graph write probe.
9. Run `-DryRun`.
10. Import only unassigned policies into a test tenant.
11. Validate resulting policies.
12. Produce mapping reports and unresolved/manual reports.

---

## 12. Safety requirements for benchmark packs

Every benchmark implementation must follow these rules:

- Never assign policies automatically.
- Never guess a Graph setting ID.
- Never guess a value ID.
- Never silently convert a manual control into a policy.
- Never create a policy when required mappings are unresolved.
- Do not include CIS benchmark PDFs in the public repository.
- Do not reproduce large portions of CIS benchmark text.
- Store implementation metadata, recommendation IDs, mappings, values, and original project code only.
- Prefer exact-name duplicate detection.
- Make re-runs safe.
- Validate the tenant before writes.
- Provide `-DryRun`.
- Provide write probes before deployment.
- Surface exact Graph errors.
- Strip response-only OData metadata from payloads.
- Keep policy assignment as a separate explicit action.

---

## 13. Supported benchmark roadmap

### Supported / proven

- CIS Microsoft Intune for Windows 11 Benchmark v5.0.0

### Next

- CIS Apple macOS 26 Tahoe Intune Benchmark v1.0.0

### Planned

- CIS Microsoft Intune for Apple iOS 17 and iPadOS 17 Benchmark v2.0.0

### Intentionally excluded

Generic/non-Intune CIS benchmarks unless a future decision explicitly expands project scope.

---

## 14. Project positioning

Suggested concise project description:

> **CISPolicyCreator converts CIS Benchmarks specifically authored for Microsoft Intune into validated, fail-closed, unassigned Intune policy packs using Microsoft Graph.**

Suggested safety statement:

> CISPolicyCreator never treats a PDF recommendation as automatically deployable. A recommendation must first be mapped to a verified Intune / Graph implementation. Uncertain recommendations remain manual or unresolved.

---

## 15. Immediate actions for the next session

1. Clean the duplicate nested `CISPolicyCreator/` folder from GitHub.
2. Remove `CISPolicyCreator_v0.1.0.bundle` from GitHub.
3. Re-check the repository structure.
4. Start the macOS 26 Tahoe Intune v1.0.0 recommendation inventory.
5. Build the normalized recommendation spec.
6. Produce the first mapping report showing:
   - mapped
   - manual
   - unresolved
   - not-applicable
7. Only after the mapping is verified, generate deployable Intune policies.
8. Test using the same probe → dry-run → import cycle that worked for Windows 11 v5.

---

## 16. Important principle to preserve

The value of this project is **trustworthiness**, not maximum automation.

If the exact Intune implementation is uncertain, CISPolicyCreator must say:

```text
unresolved
```

rather than producing something that merely looks plausible.

That principle should remain the design constraint for all future development.
