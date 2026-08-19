# Supported benchmark scope

CISPolicyCreator intentionally supports only CIS benchmarks whose remediation guidance is authored specifically for **Microsoft Intune**.

## In scope

| Benchmark family | Version | Mapped | Requires input | Manual | Unresolved | Split policy JSON files with all inputs |
|---|---:|---:|---:|---:|---:|---:|
| CIS Microsoft Intune for Windows 10 | 5.0.0 | 312 | 5 | 41 | 0 | 278 |
| CIS Microsoft Intune for Edge | 1.0.0 | 135 | 3 | 0 | 0 | 138 |
| CIS Microsoft Intune for Office | 1.1.0 | 238 | 0 | 0 | 0 | 234 |
| CIS Apple macOS 26 Tahoe Intune | 1.0.0 | 85 | 14 | 1 | 0 | 83 |
| CIS Apple iOS 26 and iPadOS 26 Intune | 1.0.0 | 84 | 8 | 1 | 1 | 60 |
| CIS Microsoft Intune for Windows 11 | 5.0.0 | 371 | 8 | 36 | 0 | 326 |

The five zero-unresolved catalogs have passed extraction-bound real-PDF compilation,
offline pack validation, and deterministic split-policy ZIP validation. The Edge
catalog has also passed the complete one-command PDF-to-ZIP path. Earlier mapped subsets
passed live dry runs and unassigned test-tenant creation. A fresh dry run against the
administrator's own tenant remains required before import.

“Supported for policy creation” means the exact PDF version is recognized, every
extracted recommendation is explicitly classified, and every actual Intune-configurable
recommendation has a deterministic policy mapping or an explicit administrator-input
gate. Human review/process controls remain `manual` and emit no JSON. Duplicate CIS
rows and required dependency trees can share one policy file, so recommendation and JSON
counts need not match. Unresolved rows never emit settings.

The repository may support later versions of these families after review and validation.

## Out of scope by design

Generic CIS benchmarks for Apple operating systems, Android, Edge, Chrome, Safari, or other products are **not** accepted merely because an Intune implementation might be possible.

A benchmark must provide Intune-specific management/remediation guidance before it is eligible for a supported pack.

This rule exists to keep the project fail-closed: the tool should never infer that a local/GPO/Apple Configurator/Google Admin recommendation is equivalent to a specific Intune object unless that mapping is separately and explicitly reviewed as a different project scope.
