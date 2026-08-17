# Benchmark roadmap

CISPolicyCreator has a deliberately narrow roadmap.

All benchmark catalog work is gated on the reproducible offline pipeline, schema, decision, provenance, and test requirements documented in the repository. Catalogs must use that pipeline; benchmark-specific one-off generation scripts are not accepted.

## 1. Windows 11 Intune

The repository includes a public-safe catalog for all 415 Windows 11 v5.0.0 recommendation identifiers. It now contains 154 exact definition and option/value mappings validated against a pinned Settings Catalog snapshot and compiles reproducibly into 14 unassigned policies; 261 recommendations remain unresolved and emit no implementation. The expanded catalog passes live tenant resolution. Hardened read-only verification previously proved that name equality alone was insufficient by detecting a different same-name policy before writes. Continue administrator-controlled test-device behavior validation before describing it as complete.

## 2. Selected additional Intune benchmarks

The repository contains partial, fail-closed catalogs for Windows 10 v5.0.0 (121
mapped), Microsoft Edge v1.0.0 (125 mapped), Microsoft Office v1.1.0 (203 mapped),
Apple macOS 26 Tahoe Intune v1.0.0 (57 mapped), and Apple iOS 26 / iPadOS 26
Intune v1.0.0 (78 mapped plus 2 explicit administrator-input recommendations). Each
real supplied PDF builds successfully into offline-validated unassigned policies.
iOS/iPadOS combines Settings Catalog with contract-bound typed Graph objects. Earlier
smaller subsets passed unassigned import, and all expanded catalogs pass a live
read-only test-tenant dry run. Administrators must still dry-run against their own
tenant. Do not represent any partial catalog as a complete CIS baseline.

## 3. iOS 17 / iPadOS 17 Intune

Implement native Intune configuration and compliance objects from the Intune-specific benchmark using the same fail-closed workflow.

## Not planned

Generic Apple OS, Android, Microsoft Edge, Google Chrome, and Safari benchmarks are not part of this repository's supported benchmark catalog. An explicitly Intune-authored edition, such as CIS Microsoft Intune for Edge v1.0.0, is a separate eligible source.
