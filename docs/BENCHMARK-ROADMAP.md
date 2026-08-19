# Benchmark roadmap

CISPolicyCreator has a deliberately narrow roadmap.

All benchmark catalog work is gated on the reproducible offline pipeline, schema, decision, provenance, and test requirements documented in the repository. Catalogs must use that pipeline; benchmark-specific one-off generation scripts are not accepted.

## 1. Windows 11 Intune

The repository includes a public-safe, fully classified catalog for all 415 Windows 11
v5.0.0 recommendations: 371 deterministic mappings, 8 administrator-input gates, 36
non-policy/manual controls, and zero unresolved recommendations. With all nine explicit
administrator decisions supplied, the real PDF compiles reproducibly into 325 Settings
Catalog policy JSON files and one Windows compliance policy JSON file. Every filename
uses the Windows benchmark convention beginning with `V5-`; all files are unassigned.
The complete build, pack, ZIP, and offline importer validations pass, and a repeated
build produces identical ZIP bytes. Administrators must still dry-run and test policies
against their own tenant before production rollout.

## 2. Selected additional Intune benchmarks

The repository also contains fully classified policy-creation catalogs for Windows 10
v5.0.0, Microsoft Edge v1.0.0, Microsoft Office v1.1.0, and Apple macOS 26 Tahoe
Intune v1.0.0. Apple iOS 26 / iPadOS 26 Intune v1.0.0 has one deliberately unresolved
ADE enrollment recommendation because Microsoft requires a complete 40-setting
organization-specific profile. Each real supplied PDF builds successfully into
offline-validated unassigned policies. iOS/iPadOS combines Settings Catalog with
contract-bound typed Graph objects. Administrators must still dry-run against their own
tenant and must not describe the deliberately omitted ADE policy as implemented.

## 3. iOS 17 / iPadOS 17 Intune

Implement native Intune configuration and compliance objects from the Intune-specific benchmark using the same fail-closed workflow.

## Not planned

Generic Apple OS, Android, Microsoft Edge, Google Chrome, and Safari benchmarks are not part of this repository's supported benchmark catalog. An explicitly Intune-authored edition, such as CIS Microsoft Intune for Edge v1.0.0, is a separate eligible source.
