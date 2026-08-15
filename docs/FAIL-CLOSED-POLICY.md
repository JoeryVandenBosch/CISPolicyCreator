# Fail-closed mapping and validation policy

## Purpose

CISPolicyCreator converts CIS Benchmarks authored specifically for Microsoft Intune into Microsoft Intune policy objects. When any source identity, mapping, value, administrator decision, API representation, or cross-file reference is uncertain, the affected implementation is not emitted.

The project optimizes for accuracy and auditability, not maximum automation.

The PDF extractor accepts only Python 3.11 or later and the exact `pypdf` version jointly pinned by the hash-locked requirements file and extraction schema. Missing hashes, version drift, or disagreement between those repository contracts stops extraction before the PDF is read.

Repository-owned initialization creates or reuses a local virtual environment and installs the hash-locked offline parser dependency. Its optional `-IncludeGraph` mode downloads only the exact repository-pinned authentication module into ignored repository-local storage; it does not authenticate or perform tenant operations. Live scripts reject a different Graph module version or deterministic file-tree SHA-256. The same bootstrap and locked prerequisite checks run in CI, and no AI runtime is installed.

## Independent classification axes

`cisAssessmentMethod` records the benchmark's assessment classification:

- `Manual`
- `Automated`

`mappingStatus` records the state of the Intune mapping:

- `mapped`: a deterministic, reviewed implementation exists;
- `unresolved`: a possible implementation has not been proven exactly;
- `requires-input`: the implementation path is known but an organizational value requires explicit administrator choice;
- `manual`: the control is a non-policy/process action outside the supported deployment path;
- `not-applicable`: the recommendation is excluded by a documented applicability rule.

These fields must not be inferred from each other. In particular, a CIS `Manual` recommendation may be `mapped` when a deterministic Intune implementation exists.

Only final `mapped` recommendations are deployable. When an administrator supplies a required decision, the compiler validates the value against the catalog's reviewed constraints and emits a final `mapped` record with `catalogMappingStatus: requires-input` and `decisionRef` provenance. Without that input, the record remains `requires-input` and its deployable object is omitted.

## Non-negotiable rules

- Never construct, derive, or guess a `settingDefinitionId`.
- Resolve a setting only by an explicit reviewed ID or an exact `baseUri + offsetUri` tuple that matches exactly one definition.
- Never use a display-name fallback to make a deployment decision.
- Normalized title/display-name matches may appear only in a private candidate worklist; even a unique candidate cannot change `mappingStatus` without explicit review of the exact definition hierarchy and value.
- Never guess or heuristically select a choice/value ID.
- Choice settings require an exact reviewed `optionId` present exactly once in the pinned and live definition.
- Simple collections validate every element's type and constraints; group collections and choice-dependent children validate every nested definition, type, choice, value, and bounded depth.
- Ambiguous or missing definition/value matches fail closed.
- Static embedded Settings Catalog settings are rejected because they bypass definition/value validation.
- Organizational choices require an explicit acknowledged decision from the administrator.
- Non-policy and process controls remain `manual`.
- No assignment endpoints, assignment payloads, group creation, or automatic policy assignments are permitted.

## Validation layers

1. Verify benchmark identity and required document text declared by the reviewed catalog.
2. Extract recommendation ID, profile, assessment method, and private review text locally.
3. Reject empty extraction, duplicate IDs, unknown profiles, or assessment-method mismatches.
4. Require the exact expected recommendation count and an explicit catalog classification for every extracted ID; incomplete catalogs fail.
5. Validate explicit administrator decisions against type/range/allowed-value constraints.
6. Resolve each Settings Catalog mapping against a pinned definition snapshot.
7. Generate deterministic pack files and provenance hashes.
8. Evaluate JSON Schemas and semantic cross-file rules.
9. During live dry run, validate the exact current Graph definition and option before any create request.
10. Create policies unassigned only after all selected mappings and payloads pass preflight.

## Reproducibility and audit

The generated manifest records the source PDF name/hash/page count, compiler/extractor/PDF-parser versions, mapping catalog identity/hash, decision-file hash, and Settings Catalog snapshot hash. Pack JSON uses stable ordering and contains no build timestamp. Identical input bytes produce identical generated pack bytes.

Mapping audit reports are derived only after the complete pack validator succeeds. Invalid or tampered packs produce no report; report outputs are deterministic and never overwrite existing files.

Every recommendation remains visible in the inventory, including unresolved, requires-input, manual, and not-applicable items. A reviewer can trace every deployable object back to recommendation IDs, profiles, assessment method, mapping status, implementation references, exact Graph definition/value, and administrator decision where applicable.

Private candidate worklists are reproducible reviewer aids, not compiler inputs or mapping authority. They record hashes for the extraction, pinned snapshot, and reference policy files, preserve exact historical occurrences, and declare `mappingChangesMade: false`. They must remain private because they contain benchmark titles.

Candidate promotion is a separate explicit trust boundary. Approval templates default every row to undecided `defer`. A reviewer may explicitly mark a false historical candidate `rejected` with an acknowledged rationale; rejection never changes mapping status or emits implementation content. A mapped review must acknowledge semantic equivalence, select an exact occurrence and complete top-level setting tree, and assert that the value is prescribed by the benchmark. Application rechecks the private extraction and all other pinned hashes, then compiles and validates the complete pack before atomically writing a new catalog without modifying the source. Organizational values cannot use this path and remain `requires-input` until an administrator supplies a separate decision. Hash-bound private progress reports expose pending/rejected/approved counts without copying benchmark titles or changing review state.

## Runtime controls

An actual import of a pack that still contains `unresolved` or `requires-input` recommendations requires a separate `-ConfirmPartialPack` acknowledgement after offline validation and before Graph authentication. Dry runs and temporary probes cannot carry this acknowledgement. Partial recommendations remain nondeployable and are never silently presented as an implemented baseline.

- Offline validation happens before authentication.
- Dry run requests read-only Graph scope.
- Every write mode requires an explicit pinned tenant ID and a mode-specific acknowledgement before pack validation or authentication.
- A case-insensitive same-name Settings Catalog policy is skipped only after exactly one match is read and its policy metadata and complete nested setting/value payload are proven equivalent; duplicates, read failures, and any difference abort before writes.
- A same-name generic Graph object aborts preflight because the endpoint-agnostic adapter cannot prove content equivalence; it is never skipped as successful or patched.
- The write probe is copied only from an exact generated leaf setting and matching policy metadata; it is temporary, unassigned, and cleanup is attempted in `finally`.
- Creation stops on the first Graph error by default.
- Partial/preflight results are preserved when possible.
- Import never creates assignments.

## Definition of done

A benchmark catalog is complete only when every extracted recommendation has an explicit final state, all mapped objects have exact reviewed evidence, all administrator decisions are explicit, repeated builds are byte-identical, offline tests pass, live dry run resolves every selected mapping, test-tenant behavior is validated, and all policies remain unassigned by default.
