# PDF-to-Intune workflow

CISPolicyCreator deliberately separates **document extraction**, **mapping review**, and **deployment**.

## Eligibility gate

Before extraction, confirm that the source benchmark is explicitly authored for Microsoft Intune. Generic OS/browser benchmarks are out of scope for this project.

## 1. Keep the PDF private

Do not place source benchmark PDFs in the public repository unless redistribution is explicitly permitted.

## 2. Extract candidate recommendations locally

```powershell
python .\tools\Extract-CISRecommendations.py `
    C:\Private\Benchmark.pdf `
    -o C:\Private\recommendations.raw.json
```

The extractor captures recommendation-shaped blocks for review. Every extracted recommendation is emitted with `status: unresolved`.

The extractor **never** decides that a recommendation is deployable.

## 3. Build the public recommendation inventory

Create `spec/recommendations.json` using only the minimum metadata needed for auditability:

- recommendation ID;
- applicable profile(s);
- mapping status;
- implementation type/reference;
- short original notes written by the pack author.

Avoid copying rationale, audit, remediation, or other benchmark prose into a public pack.

## 4. Classify each recommendation

Use exactly one status:

- `mapped`
- `manual`
- `unresolved`
- `not-applicable`

`unresolved` is the safe default.

## 5. Prove the Intune mapping

For a recommendation to become `mapped`, the implementation must be reproducible through an actual Intune/Graph object and value. Examples include:

- Settings Catalog definition + valid value/choice;
- compliance-policy property;
- reviewed platform-specific Intune configuration payload.

If the API object or exact value cannot be proven, leave it `unresolved`.

## 6. Validate the pack

```powershell
.\scripts\Test-CISPolicyPack.ps1 -PackRoot .\work\example
```

Validation fails if a deployable entry is not `mapped`, references a `manual`/`unresolved` recommendation, uses an unsafe Graph endpoint, includes assignment behavior, or violates structural requirements.

## 7. Review the mapping report

```powershell
.\scripts\Get-CISMappingReport.ps1 -PackRoot .\work\example
```

## 8. Probe the Graph write path

Configure a harmless known Settings Catalog probe in the manifest and run:

```powershell
.\scripts\Import-CISPolicyPack.ps1 -PackRoot .\work\example -TenantId '<guid>' -ProbeOnly
```

The probe creates one temporary unassigned policy and deletes it immediately.

## 9. Dry run

```powershell
.\scripts\Import-CISPolicyPack.ps1 -PackRoot .\work\example -Profile L1 -TenantId '<guid>' -DryRun
```

The dry run resolves all dynamic Settings Catalog definitions and values. Any unresolved runtime mapping aborts before policy creation.

## 10. Import unassigned policies

```powershell
.\scripts\Import-CISPolicyPack.ps1 -PackRoot .\work\example -Profile L1 -TenantId '<guid>'
```

No assignments are created.

## 11. Validate in a test scope

Assignments are intentionally outside the importer. Assign only to a dedicated test group/device, sync, and validate against the benchmark assessment process.
