# Security model

CISPolicyCreator treats the PDF, candidate worklist, private mapping approvals, mapping catalog, administrator decision file, definition snapshot, generated pack, and live tenant as distinct trust boundaries.

## Build invariants

1. The benchmark must be Intune-specific and match the catalog's exact identity checks.
2. Extraction is local, private, deterministic, and never assigns mapping status.
3. `cisAssessmentMethod` and `mappingStatus` remain independent.
4. Every expected recommendation must be explicitly classified; incomplete catalogs fail.
5. Missing administrator choices remain `requires-input`.
6. Only final `mapped` recommendations may feed deployable objects.
7. Settings resolve only by reviewed explicit ID or exact unique CSP tuple.
8. Choice values require exact reviewed option IDs.
9. Static Settings Catalog payloads and heuristic fallbacks are rejected.
10. All build inputs are schema-validated and hashed; private definition snapshots record their source tenant and capture time.
11. Generated files are deterministic and contain no source PDF or raw extraction text.
12. Candidate matches cannot change mapping status. A hash-bound rejection records a reviewed false candidate but emits nothing; promotion requires a separate explicit approval of semantic equivalence, the exact occurrence/tree, and a benchmark-prescribed value basis. The new catalog is published only after the exact private extraction compiles into a fully valid offline pack.
13. Mapping audit reports require complete offline pack validation and are not produced from invalid or tampered packs.
14. Repository bootstrap installs only hash-locked offline Python requirements into an explicit virtual environment; Graph tooling remains separate and AI is never a runtime dependency.

## Runtime invariants

1. Offline pack validation finishes before Graph authentication.
2. Dry run requests read-only configuration scope.
3. Every write mode requires an explicit tenant ID and its own acknowledgement before pack validation or Graph authentication.
4. Importing a pack with final `unresolved` or `requires-input` recommendations requires a separate partial-pack acknowledgement before Graph authentication.
5. Live definition/value resolution completes before the first create request.
6. Graph URLs must use HTTPS, the exact `graph.microsoft.com` host, an allowed API version, and a `deviceManagement` path.
7. Encoded or plain assignment path segments and assignment payload properties are rejected.
8. Existing exact-name objects are skipped and never patched.
9. Import stops on the first create error unless `-ContinueOnError` is explicit.
10. A probe must exactly match a generated reviewed leaf setting and policy platform/technology; cleanup is attempted even if later probe processing fails.
11. No automatic assignments or group creation are implemented.

## Residual risks

A valid Graph payload does not prove semantic equivalence to a CIS recommendation. Explicit mapping approval, full pack validation, live dry run, and test-tenant assessment remain required. Microsoft Graph beta behavior can drift; the pinned snapshot makes the build reproducible, while live dry run detects current-tenant drift and fails rather than substituting a different setting.

PDFs are untrusted input. Use the hash-pinned parser version, retain source documents privately, and process them in an appropriately constrained workstation environment. Extraction defaults to a 250 MiB file limit and 2,000-page limit; lower them when appropriate.
