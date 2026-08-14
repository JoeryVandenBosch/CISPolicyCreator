# CISPolicyCreator - Fail-Closed Mapping and Validation Policy

## Purpose

CISPolicyCreator translates CIS Benchmarks that are explicitly authored for Microsoft Intune into Microsoft Intune policy objects. The project fails closed: when a recommendation cannot be mapped with high confidence to a real Intune policy object, setting, API field, or supported configuration mechanism, it is not deployed.

> **Project principle:** When in doubt, do not deploy. Prefer an explicit `manual` or `unresolved` result over a plausible but unverified configuration.

## Supported scope

Only CIS Benchmarks specifically authored for Microsoft Intune are in scope. Generic platform benchmarks are excluded unless a separate reviewed mapping project explicitly adds support.

## Mapping states

| State | Meaning | Deployable |
|---|---|---|
| `mapped` | Confident Intune mapping and validated target value | Yes |
| `manual` | Human action required or not safely automatable | No |
| `unresolved` | Appears automatable but mapping/value/API representation is not sufficiently certain | No |
| `not-applicable` | Not applicable to the selected platform/profile | No |

## Fail-closed rules

- Never guess `settingDefinitionId`, choice IDs, OMA-URIs, plist keys, Graph properties, value encodings, or policy types.
- UI-path-only guidance is not enough if the corresponding Graph representation cannot be verified.
- Ambiguous matches are `unresolved`.
- API drift is `unresolved` until reviewed.
- CIS controls marked Manual stay manual unless a separately reviewed implementation is explicitly documented.
- Generated policies are never assigned automatically.

## Validation pipeline

1. Parse the CIS Intune recommendation and applicability.
2. Classify the Intune object type.
3. Resolve the current Microsoft Graph/Intune representation.
4. Validate the exact target value/choice.
5. Build a clean writable payload without GET-only/OData metadata.
6. Run `-DryRun` and block unresolved mappings from deployment.
7. Create policies unassigned.
8. Validate behavior in the target tenant and with assessment tooling where available.

## Runtime safety controls

- Tenant verification and optional `-TenantId` pinning.
- `-ProbeOnly` Graph write test.
- `-DryRun` exact payload validation.
- Existing-policy detection.
- Detailed Graph error bodies.
- No automatic assignments or group creation.
- Per-recommendation mapping/status logging.

## Audit requirements

Each recommendation must be traceable to its CIS ID/profile, Intune policy, Graph object/setting definition, configured value, resolution method, mapping state, and run result.

## Definition of done

A benchmark pack is complete only when every in-scope recommendation has an explicit state, unresolved/manual items are excluded from deployable payloads, generated JSON passes validation, live resolution succeeds for mapped settings, write probes pass, policies are unassigned by default, and benchmark-specific decisions are documented.

## Public repository guidance

Do not commit CIS benchmark PDFs to the public repository. Keep original tooling, schemas, mapping metadata, policy-generation logic, and project documentation in GitHub; users should supply legitimately obtained benchmark files locally when needed.
