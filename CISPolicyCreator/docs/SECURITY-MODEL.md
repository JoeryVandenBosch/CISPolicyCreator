# Security model

CISPolicyCreator is designed to make accidental deployment harder than review.

## Safety invariants

1. A pack must declare `benchmarkScope: microsoft-intune`.
2. Recommendation mappings default to `unresolved`.
3. Only `mapped` recommendations can appear in deployable objects.
4. Runtime Settings Catalog resolution must succeed before any create request.
5. Unsupported setting types stop the import rather than being guessed.
6. Generic Graph endpoints are restricted to Microsoft Graph `deviceManagement` resources.
7. Assignment endpoints and payloads are rejected.
8. Existing objects are skipped and never patched by the importer.
9. Settings Catalog policies are deep-created with at least one setting.
10. Known read-only OData response annotations are removed from create payloads.
11. `-TenantId` can pin authentication to the intended tenant.
12. `-ProbeOnly` and `-DryRun` are available before real creation.
13. The importer never creates assignments.

## What this tool does not guarantee

A structurally valid Graph payload is not proof that a benchmark recommendation is semantically correct. Mapping review and test-tenant validation remain required.

Microsoft Graph beta behavior and Intune setting definitions can evolve. Runtime resolution reduces stale-ID risk but cannot replace validation.
