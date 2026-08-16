# Supported benchmark scope

CISPolicyCreator intentionally supports only CIS benchmarks whose remediation guidance is authored specifically for **Microsoft Intune**.

## In scope

| Benchmark family | Version currently in project workflow | Status |
|---|---:|---|
| CIS Microsoft Intune for Windows 11 | 5.0.0 | Partial catalog: 28 snapshot- and live-dry-run-validated mappings in 10 unassigned policies; 387 unresolved |
| CIS Microsoft Intune for Windows 10 | 5.0.0 | Partial catalog: 9 exact snapshot- and live-import-validated mappings in 4 unassigned policies; 349 unresolved |
| CIS Microsoft Intune for Edge | 1.0.0 | Partial catalog: 13 exact snapshot- and live-import-validated mappings in 2 unassigned policies; 125 unresolved |
| CIS Microsoft Intune for Office | 1.1.0 | Partial catalog: 2 exact snapshot- and live-import-validated mappings in 1 unassigned policy; 236 unresolved |
| CIS Apple macOS 26 Tahoe Intune | 1.0.0 | Partial catalog: 1 exact nested snapshot- and live-import-validated mapping in 1 unassigned policy; 99 unresolved |
| CIS Apple iOS 26 and iPadOS 26 Intune | 1.0.0 | Partial catalog: 1 exact nested snapshot- and live-import-validated mapping in 1 unassigned policy; 93 unresolved |
| CIS Microsoft Intune for Apple iOS 17 and iPadOS 17 | 2.0.0 | Eligible PDF; catalog not yet implemented |

“Supported” means the exact PDF version is recognized, every extracted recommendation
is explicitly classified, and the mapped subset builds into validated unassigned
policies. It does not mean the complete CIS baseline is implemented. Unresolved rows
never emit settings.

The repository may support later versions of these families after review and validation.

## Out of scope by design

Generic CIS benchmarks for Apple operating systems, Android, Edge, Chrome, Safari, or other products are **not** accepted merely because an Intune implementation might be possible.

A benchmark must provide Intune-specific management/remediation guidance before it is eligible for a supported pack.

This rule exists to keep the project fail-closed: the tool should never infer that a local/GPO/Apple Configurator/Google Admin recommendation is equivalent to a specific Intune object unless that mapping is separately and explicitly reviewed as a different project scope.
