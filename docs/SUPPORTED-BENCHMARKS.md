# Supported benchmark scope

CISPolicyCreator intentionally supports only CIS benchmarks whose remediation guidance is authored specifically for **Microsoft Intune**.

## In scope

| Benchmark family | Version currently in project workflow | Status |
|---|---:|---|
| CIS Microsoft Intune for Windows 11 | 5.0.0 | Partial reviewed catalog: 18 live-dry-run-validated mappings in 6 unassigned policies; 397 recommendations remain unresolved |
| CIS Apple macOS 26 Tahoe Intune | 1.0.0 | Next benchmark-pack implementation target |
| CIS Microsoft Intune for Apple iOS 17 and iPadOS 17 | 2.0.0 | Planned after macOS |

The repository may support later versions of these families after review and validation.

## Out of scope by design

Generic CIS benchmarks for Apple operating systems, Android, Edge, Chrome, Safari, or other products are **not** accepted merely because an Intune implementation might be possible.

A benchmark must provide Intune-specific management/remediation guidance before it is eligible for a supported pack.

This rule exists to keep the project fail-closed: the tool should never infer that a local/GPO/Apple Configurator/Google Admin recommendation is equivalent to a specific Intune object unless that mapping is separately and explicitly reviewed as a different project scope.
