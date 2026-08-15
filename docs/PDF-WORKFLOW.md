# PDF-to-Intune workflow

CISPolicyCreator separates private document extraction, reviewed mapping, deterministic compilation, live validation, and deployment.

Before reading the source, the extractor requires Python 3.11 or later and verifies that the installed `pypdf` version exactly matches the SHA-256-locked requirement and extraction schema. Install with `python -m pip install --require-hashes -r .\tools\requirements.txt`; a different parser version fails closed.

## 1. Eligibility and privacy

Use only a legitimately obtained CIS Benchmark explicitly authored for Microsoft Intune. Never commit the PDF or raw extracted benchmark prose. A reviewed mapping catalog declares required source text and exact benchmark identity; extraction stops when those checks fail.

## 2. Install the pinned extractor

```powershell
python -m pip install --require-hashes -r .\tools\requirements.txt
```

The PDF parser runs locally. It extracts `cisAssessmentMethod` independently from mapping status and fails on empty output, duplicate recommendation IDs, or unrecognized profile applicability.

## 3. Use a reviewed mapping catalog

The catalog is original, public-safe project metadata keyed by exact benchmark ID/version and recommendation ID. It classifies each recommendation as `mapped`, `unresolved`, `requires-input`, `manual`, or `not-applicable` and contains only reviewed Intune implementations.

For a new benchmark, create the private extraction first, then generate an all-unresolved catalog without copying benchmark prose:

```powershell
.\scripts\New-CISMappingCatalog.ps1 `
  -ExtractionPath C:\Private\benchmark.private-extraction.json `
  -OutputPath .\benchmarks\example\1.0.0\mapping-catalog.json `
  -CatalogId 'example-mappings' `
  -CatalogVersion '0.1.0' `
  -PackId 'example-pack' `
  -PackName 'Example Intune Pack' `
  -PackVersion '0.1.0'
```

This initializer is deterministic and fail-closed: all entries start `unresolved`, implementation arrays are empty, and no Graph identifiers or values are inferred.

The catalog records the reviewed expected recommendation count and must explicitly classify every extracted ID. Use `unresolved` for mappings that have not been proven. Missing/extra IDs or count mismatches fail source validation rather than silently producing an incomplete inventory.

## 4. Capture authoritative definitions

```powershell
.\scripts\Export-SettingsCatalogDiagnostics.ps1 `
  -TenantId '<guid>' `
  -OutputPath C:\Private\settings-catalog-snapshot.json
```

Use `-UseDeviceCode` in embedded or headless terminals where browser-based authentication is unavailable. The exporter records pagination evidence, follows server continuation links, falls back to explicit `$skip` paging when necessary, and rejects duplicate IDs or inconsistent counts.

This private snapshot records API version, capture time, and tenant ID. Exact setting and option IDs are checked against it, and its SHA-256—not its tenant ID—is recorded in the generated pack. Do not commit tenant snapshots.

## 5. Optionally create a private mapping-review worklist

If a legitimately obtained, previously reviewed configuration-policy pack exists for the exact benchmark, it can be used as candidate evidence:

```powershell
.\scripts\New-CISMappingReviewWorklist.ps1 `
  -ExtractionPath C:\Private\benchmark.private-extraction.json `
  -SettingsCatalogSnapshotPath C:\Private\settings-catalog-snapshot.json `
  -ReferencePackRoot C:\Private\reviewed-reference-pack `
  -OutputPath C:\Private\benchmark.private-review.json
```

The reference root must contain `configuration-policies\*.json` with an exact `[L1]`, `[L2]`, or `[BL]` marker in each policy name. Before creating candidates, the script recursively validates every historical setting definition, instance type, exact choice ID, simple value constraint, collection element, and nested group value against the pinned snapshot. Input file hashes and exact observed values are retained as review evidence, and identical inputs produce byte-identical worklists.

The normalized title/display-name rule is only a reviewer shortcut. The output explicitly sets `mappingChangesMade` to `false`; `unique-candidate` does not prove a mapping, ambiguous candidates remain ambiguous, and no catalog is modified. The worklist contains private benchmark titles, is ignored by Git through `*.private-review.json`, and must not be committed.

## 6. Approve exact mapping evidence explicitly

Create a private, all-deferred approval template bound to the exact catalog and review-worklist hashes:

```powershell
.\scripts\New-CISMappingReviewApprovals.ps1 `
  -MappingCatalogPath .\benchmarks\example\1.0.0\mapping-catalog.json `
  -ReviewWorklistPath C:\Private\benchmark.private-review.json `
  -CatalogVersion '0.2.0' `
  -PackVersion '0.2.0' `
  -OutputPath C:\Private\benchmark.private-approvals.json
```

`defer` means undecided. Use `rejected` with an explicit reviewer, acknowledgement, rationale, and public-safe note when a historical candidate is not semantically equivalent; rejection remains nondeployable and leaves the recommendation unresolved. Changing a review to `mapped` requires all of the following explicit evidence: `acknowledged: true`, a reviewer identity and justification, a public-safe note, `valueBasis: benchmark-prescribed`, one or more exact candidate occurrences, the complete top-level definition ID, and unassigned policy metadata. The platform and technology must equal the hashed reference policy, profiles must equal the selected occurrence profile, and only default role scope tag `0` is allowed. Ambiguous candidates may be selected only through this explicit review. `Manual` assessment remains independent and is preserved when its deterministic mapping is approved.

Use `Get-CISMappingReviewReport.ps1` to create hash-bound private JSON/CSV progress reports. Reports contain no benchmark titles, make pending/rejected/approved counts explicit, and never alter the approval file or catalog.

Copy selector fields exactly from one occurrence in the private worklist. An approved review has this shape:

```json
{
  "recommendationId": "1.2.3",
  "candidateStatus": "unique-candidate",
  "outcome": "mapped",
  "acknowledged": true,
  "valueBasis": "benchmark-prescribed",
  "reviewedBy": "reviewer identity",
  "justification": "Why the recommendation semantics and complete setting tree are equivalent.",
  "publicNotes": "Exact Settings Catalog hierarchy and value reviewed.",
  "selections": [
    {
      "candidateDefinitionId": "exact_candidate_definition_id",
      "sourceFile": "configuration-policies/reference-policy.json",
      "path": "settings[1]",
      "topLevelDefinitionId": "exact_top_level_definition_id",
      "policy": {
        "id": "public-safe-policy-id",
        "name": "Public-safe policy name [L1]",
        "description": "Original project description.",
        "platforms": "windows10",
        "technologies": "mdm",
        "profiles": ["L1"],
        "roleScopeTagIds": ["0"]
      }
    }
  ]
}
```

Apply the approvals to a new catalog; the source catalog is never overwritten:

```powershell
.\scripts\Apply-CISMappingReviewApprovals.ps1 `
  -ExtractionPath C:\Private\benchmark.private-extraction.json `
  -MappingCatalogPath .\benchmarks\example\1.0.0\mapping-catalog.json `
  -ReviewWorklistPath C:\Private\benchmark.private-review.json `
  -ApprovalsPath C:\Private\benchmark.private-approvals.json `
  -SettingsCatalogSnapshotPath C:\Private\settings-catalog-snapshot.json `
  -ReferencePackRoot C:\Private\reviewed-reference-pack `
  -OutputPath C:\Private\mapping-catalog.next.json
```

The script verifies the private extraction, catalog, worklist, snapshot, and every reference-policy hash; revalidates exact definitions, types, choices, values, collections, and nested groups; and promotes only currently `unresolved` recommendations whose review outcome is `mapped`. Rejected reviews are audit evidence only and emit nothing. It writes the candidate catalog to a temporary file, compiles the complete extraction-bound pack, and runs offline pack validation before atomically publishing the new catalog. Any failure removes the temporary pack/catalog and leaves the requested output absent. An all-deferred or all-rejected file writes nothing. This path intentionally cannot authorize organizational values: use `requires-input` and an administrator decision instead. Keep private approval/report files private, then run live dry-run and test-tenant validation before publishing the new catalog.

## 7. Supply organizational decisions

```powershell
.\scripts\New-CISAdministratorDecisions.ps1 `
  -MappingCatalogPath .\benchmarks\example\1.0.0\mapping-catalog.json `
  -OutputPath C:\Private\decisions.json
```

Complete every required value, set `acknowledged` to `true`, and add a justification. Values outside reviewed allowed sets/ranges fail validation. Missing decisions remain nondeployable `requires-input`; they are never defaulted.

## 8. Build atomically

```powershell
.\scripts\Invoke-CISPolicyPipeline.ps1 `
  -PdfPath C:\Private\Benchmark.pdf `
  -MappingCatalogPath .\benchmarks\example\1.0.0\mapping-catalog.json `
  -SettingsCatalogSnapshotPath C:\Private\settings-catalog-snapshot.json `
  -AdministratorDecisionsPath C:\Private\decisions.json `
  -OutputPath .\work\example
```

The script extracts to a private staging directory, compiles and validates the pack, moves the finished pack into place, and removes staging data. It refuses to overwrite an existing output path. `-KeepPrivateExtraction` retains raw text outside the pack only when explicitly requested.

## 9. Review and validate offline

```powershell
.\scripts\Test-CISPolicyPack.ps1 -PackRoot .\work\example
.\scripts\Get-CISMappingReport.ps1 -PackRoot .\work\example
```

## 10. Validate live, then import explicitly

Run `-DryRun` with a pinned tenant. It uses read-only Graph scope and validates current definitions/options before any write. Add `-UseDeviceCode` in embedded or headless terminals. A temporary write-path test requires `-ProbeOnly -ConfirmTemporaryWriteProbe` and an explicit `-TenantId`. Final unassigned creation requires `-ConfirmUnassignedImport` and an explicit `-TenantId`; omission of `-DryRun` alone never authorizes a write.

Assignments remain a separate administrator-controlled operation outside this repository's importer.
