# Changelog

## 0.2.1 - 2026-08-14

- Add the first 18 exact Windows 11 v5.0.0 Settings Catalog mappings, validated against a pinned Graph definition snapshot and compiled into 6 unassigned policies; retain the other 397 recommendations as unresolved.
- Support explicit device-code authentication for live dry-run, probe, and import commands.
- Anchor recommendation extraction to physical PDF page starts so similarly numbered CIS Controls references cannot be misclassified as benchmark recommendations.
- Add regression coverage for recommendation-like CIS Controls text.
- Add a deterministic catalog initializer that converts a private extraction into a public-safe, all-unresolved mapping catalog without benchmark prose.
- Add an explicit device-code authentication option for Settings Catalog snapshot export from embedded or headless terminals.
- Record Settings Catalog pagination evidence and fail closed on duplicate IDs, inconsistent counts, or unbounded retrieval.
- Preserve authoritative definitions whose Graph `displayName` is empty; exact resolution continues to rely only on reviewed IDs or unique CSP paths.

## 0.2.0 - 2026-08-14

- Added deterministic PDF-to-pack orchestration with atomic private staging.
- Separated `cisAssessmentMethod` from five-state `mappingStatus`, including `requires-input`.
- Added versioned mapping catalog, administrator decision, private extraction, and Settings Catalog snapshot schemas.
- Added SHA-256 source/build provenance and byte-stable generated JSON.
- Removed constructed definition IDs and heuristic choice matching.
- Rejected unvalidated static Settings Catalog settings.
- Added actual JSON Schema evaluation, path containment, and cross-file semantic validation.
- Added read-only dry-run scope, guaranteed probe cleanup attempt, fail-fast import default, and failure result preservation.
- Added copyright-safe offline end-to-end and extractor tests.
- Hash-pinned the PDF dependency to a patched release.

## 0.1.0 - 2026-08-14

- Initial reusable CISPolicyCreator framework.
- Microsoft-Intune-only benchmark scope gate.
- Fail-closed recommendation mapping states.
- Settings Catalog deep-create importer.
- Runtime Settings Catalog resolution and value validation.
- Generic Intune Graph-object adapter with endpoint/assignment safety checks.
- Read-only OData response metadata sanitization.
- Tenant pinning, write probe, dry run, duplicate detection, and no assignments.
- Mapping report, schemas, local PDF extraction helper, CI validation, and design documentation.
