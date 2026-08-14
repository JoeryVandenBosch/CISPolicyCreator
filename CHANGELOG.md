# Changelog

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
