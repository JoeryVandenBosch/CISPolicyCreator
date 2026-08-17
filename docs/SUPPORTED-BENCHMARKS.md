# Supported benchmark scope

CISPolicyCreator intentionally supports only CIS benchmarks whose remediation guidance is authored specifically for **Microsoft Intune**.

## In scope

| Benchmark family | Version currently in project workflow | Status |
|---|---:|---|
| CIS Microsoft Intune for Windows 11 | 5.0.0 | Partial catalog: 154 mapped in 14 unassigned policies; 261 unresolved |
| CIS Microsoft Intune for Windows 10 | 5.0.0 | Partial catalog: 121 mapped in 8 unassigned policies; 237 unresolved |
| CIS Microsoft Intune for Edge | 1.0.0 | Partial catalog: 125 mapped in 5 unassigned policies; 13 unresolved |
| CIS Microsoft Intune for Office | 1.1.0 | Partial catalog: 203 mapped in 29 unassigned policies; 35 unresolved |
| CIS Apple macOS 26 Tahoe Intune | 1.0.0 | Partial catalog: 57 mapped in 39 unassigned policies; 43 unresolved |
| CIS Apple iOS 26 and iPadOS 26 Intune | 1.0.0 | Partial catalog: 78 mapped in 8 unassigned policy objects, 2 require one explicit administrator decision, and 14 remain unresolved |

Every row above has passed extraction-bound real-PDF compilation, offline pack
validation, and a live read-only test-tenant dry run. A fresh dry run against the
administrator's own tenant remains required before import.

“Supported” means the exact PDF version is recognized, every extracted recommendation
is explicitly classified, and the mapped subset builds into validated unassigned
policies. It does not mean the complete CIS baseline is implemented. Unresolved rows
never emit settings.

The repository may support later versions of these families after review and validation.

## Out of scope by design

Generic CIS benchmarks for Apple operating systems, Android, Edge, Chrome, Safari, or other products are **not** accepted merely because an Intune implementation might be possible.

A benchmark must provide Intune-specific management/remediation guidance before it is eligible for a supported pack.

This rule exists to keep the project fail-closed: the tool should never infer that a local/GPO/Apple Configurator/Google Admin recommendation is equivalent to a specific Intune object unless that mapping is separately and explicitly reviewed as a different project scope.
