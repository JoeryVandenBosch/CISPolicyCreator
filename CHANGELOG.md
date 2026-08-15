# Changelog

## 0.2.1 - 2026-08-14

- Add deterministic private mapping-review worklists that recursively validate historical definitions and values against a pinned snapshot, preserve ambiguous/no-match outcomes, and never modify mapping status.
- Add an all-deferred, hash-bound private approval workflow that can promote only explicitly reviewed, benchmark-prescribed candidate occurrences into a new catalog while preserving Manual assessment semantics and complete nested setting trees.
- Make approved catalog promotion atomic: bind it to the exact private extraction, compile the complete resulting pack, and publish the new catalog only after offline validation succeeds.
- Add one repository-owned validation entry point shared by local contributors and GitHub Actions.
- Require a pinned tenant and mode-specific acknowledgement before any probe or unassigned import can authenticate or write.
- Generate a deterministic temporary-write probe only from an exact mapped leaf setting, and reject any probe drift from its generated setting or policy metadata.
- Distinguish undecided candidate reviews from explicit nondeployable rejections, and add hash-bound deterministic private JSON/CSV progress reporting without benchmark titles.
- Fail PDF extraction before reading the source when Python is too old or the installed parser differs from the hash-locked, schema-bound `pypdf` version.
- Require a separate pre-authentication acknowledgement before importing a pack with unresolved or unsupplied-input recommendations.
- Validate packs before deterministic mapping-report generation, refuse output overwrite, and expose mapping completeness separately from CIS assessment method.
- Add repository-owned, cross-platform virtual-environment initialization and prerequisite verification, and run CI through the same clean-clone bootstrap.
- Add recursively validated Settings Catalog choice children, integer/string collections, and group collections with exact nested definitions, values, bounded depth, and live payload generation.
- Add the first 18 exact Windows 11 v5.0.0 Settings Catalog mappings, validated against a pinned Graph definition snapshot and compiled into 6 unassigned policies; retain the other 397 recommendations as unresolved.
- Support explicit device-code authentication for live dry-run, probe, and import commands.
- Harden live Graph collection reads for missing continuation links, explicit skip fallback, duplicate IDs, and unbounded pagination.
- Accept the first live validation record in an initially empty typed result collection.
- Treat CSP path metadata omitted by Graph's single-definition response as unavailable rather than contradictory, while still rejecting any returned mismatch.
- Skip the full Settings Catalog collection read when every mapping already uses an explicit definition ID.
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
