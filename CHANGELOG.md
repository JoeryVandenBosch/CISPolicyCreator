# Changelog

## 0.3.0 - 2026-08-16

- Add exact-version partial catalogs for Windows 10 v5.0.0, Microsoft Edge v1.0.0, Microsoft Office v1.1.0, Apple macOS 26 Tahoe Intune v1.0.0, and Apple iOS 26 / iPadOS 26 Intune v1.0.0.
- Build all five supplied PDFs into validated, unassigned Settings Catalog policy packs while leaving every unproven recommendation unresolved.
- Add a beginner-facing supported-benchmark wrapper with an explicit benchmark selector; source title/version checks remain mandatory.
- Allow an explicitly requested, tenant- and scope-validated Graph context to be reused for safe multi-pack validation without repeated sign-ins.
- Extend deterministic PDF extraction to Apple page banners and the Windows Next Generation Security profile, and bump the extractor contract to 0.3.0.
- Replace the root README with a start-to-finish installation, build, dry-run, and unassigned-import guide.
- Preserve empty and single-item JSON arrays in writable Graph payloads, including role scope tags, settings, and nested children.
- Live dry-run all five new partial catalogs and import their nine policies with mapped settings into a test tenant without assignments.
- Resolve relative pack output paths from PowerShell's visible current location instead of the hidden native process directory used by elevated shells.
- Normalize only proven Microsoft Graph response decoration when verifying an existing Settings Catalog policy, while retaining exact semantic instance, definition, value, child, and template-reference checks.

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
- Add optional repository-local installation of an exact pinned Graph authentication module, require that version for live scripts, and verify the live prerequisite in clean CI without authenticating.
- Add recursively validated Settings Catalog choice children, integer/string collections, and group collections with exact nested definitions, values, bounded depth, and live payload generation.
- Add the first 18 exact Windows 11 v5.0.0 Settings Catalog mappings, validated against a pinned Graph definition snapshot and compiled into 6 unassigned policies; retain the other 397 recommendations as unresolved.
- Promote 10 additional priority Level 1 mappings only after exact private title, top-level definition, occurrence, and option review; compile 28 total settings into 10 unassigned policies while leaving 387 recommendations unresolved. All 28 mappings pass live mapping validation, and an acknowledged Level 1 import made no changes when existing names were found.
- Support explicit device-code authentication for live dry-run, probe, and import commands.
- Harden live Graph collection reads for missing continuation links, explicit skip fallback, duplicate IDs, and unbounded pagination.
- Accept the first live validation record in an initially empty typed result collection.
- Treat CSP path metadata omitted by Graph's single-definition response as unavailable rather than contradictory, while still rejecting any returned mismatch.
- Skip the full Settings Catalog collection read when every mapping already uses an explicit definition ID.
- Require a unique same-name Settings Catalog policy to pass read-only, full metadata and nested setting/value equivalence checks before it can be skipped; abort before writes on duplicates or drift. A live read-only regression check detected 27 existing settings where the partial pack expected 1 and stopped with zero creates or assignments.
- Abort preflight on any same-name generic Graph object because an endpoint-agnostic importer cannot safely prove arbitrary resource equivalence; never report a name-only collision as successfully deployed.
- Publish standalone-compiled and orchestrated packs with atomic same-parent moves and ownership-scoped cleanup so a raced output path created by another process is never overwritten or deleted.
- Reject symbolic links, junctions, and other reparse points used as or inside policy packs before manifest processing so linked content cannot escape the validated pack root.
- Use platform-correct case semantics for containment checks and require exact lowercase private reviewer suffixes so Linux paths cannot escape by case and private artifacts remain covered by repository ignore rules.
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
