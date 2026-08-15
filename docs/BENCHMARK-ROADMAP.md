# Benchmark roadmap

CISPolicyCreator has a deliberately narrow roadmap.

All benchmark catalog work is gated on the reproducible offline pipeline, schema, decision, provenance, and test requirements documented in the repository. Catalogs must use that pipeline; benchmark-specific one-off generation scripts are not accepted.

## 1. Windows 11 Intune

The repository includes a public-safe catalog for all 415 Windows 11 v5.0.0 recommendation identifiers. Twenty-eight recommendations have exact definition and option/value mappings validated against a pinned Settings Catalog snapshot and a live tenant dry run, and compile reproducibly into 10 unassigned policies. An explicitly acknowledged Level 1 partial-pack import found every target policy name already present, skipped them without modification, and created no assignments. The remaining 387 recommendations stay unresolved and emit no implementation. Continue evidence-backed mapping review and administrator-controlled test-device behavior validation before describing this benchmark catalog as complete.

## 2. macOS 26 Tahoe Intune

Build a normalized recommendation inventory from the user-supplied Intune-specific benchmark, classify every recommendation, resolve current Graph/Settings Catalog implementations, and validate in a test tenant.

## 3. iOS 17 / iPadOS 17 Intune

Implement native Intune configuration and compliance objects from the Intune-specific benchmark using the same fail-closed workflow.

## Not planned

Generic Apple OS, Android, Microsoft Edge, Google Chrome, and Safari benchmarks are not part of this repository's supported benchmark catalog unless CIS publishes an Intune-specific edition or the project scope is explicitly changed in the future.
