# Benchmark roadmap

CISPolicyCreator has a deliberately narrow roadmap.

All benchmark catalog work is gated on the reproducible offline pipeline, schema, decision, provenance, and test requirements documented in the repository. Catalogs must use that pipeline; benchmark-specific one-off generation scripts are not accepted.

## 1. Windows 11 Intune

The reusable engine is based on the Windows 11 v5.0.0 implementation that was validated against a live Intune test tenant. A public-safe 415-recommendation catalog seed is now included. Every entry remains unresolved until its current Graph implementation is independently reviewed against a pinned Settings Catalog snapshot or another authoritative endpoint; the seed therefore emits no deployable policies.

## 2. macOS 26 Tahoe Intune

Build a normalized recommendation inventory from the user-supplied Intune-specific benchmark, classify every recommendation, resolve current Graph/Settings Catalog implementations, and validate in a test tenant.

## 3. iOS 17 / iPadOS 17 Intune

Implement native Intune configuration and compliance objects from the Intune-specific benchmark using the same fail-closed workflow.

## Not planned

Generic Apple OS, Android, Microsoft Edge, Google Chrome, and Safari benchmarks are not part of this repository's supported benchmark catalog unless CIS publishes an Intune-specific edition or the project scope is explicitly changed in the future.
