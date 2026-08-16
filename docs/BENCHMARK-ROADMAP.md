# Benchmark roadmap

CISPolicyCreator has a deliberately narrow roadmap.

All benchmark catalog work is gated on the reproducible offline pipeline, schema, decision, provenance, and test requirements documented in the repository. Catalogs must use that pipeline; benchmark-specific one-off generation scripts are not accepted.

## 1. Windows 11 Intune

The repository includes a public-safe catalog for all 415 Windows 11 v5.0.0 recommendation identifiers. Twenty-eight recommendations have exact definition and option/value mappings validated against a pinned Settings Catalog snapshot and live tenant mapping resolution, and compile reproducibly into 10 unassigned policies. An earlier explicitly acknowledged Level 1 partial-pack import made no changes because every target policy name was present. Hardened read-only verification then proved that name equality was insufficient: the first existing policy contained 27 settings while the partial pack expected 1, so the importer correctly aborted before writes. The remaining 387 recommendations stay unresolved and emit no implementation. Continue evidence-backed mapping review and administrator-controlled test-device behavior validation before describing this benchmark catalog as complete.

## 2. Selected additional Intune benchmarks

The repository now contains partial, fail-closed catalogs for Windows 10 v5.0.0,
Microsoft Edge v1.0.0, Microsoft Office v1.1.0, Apple macOS 26 Tahoe Intune
v1.0.0, and Apple iOS 26 / iPadOS 26 Intune v1.0.0. Each real supplied PDF
builds successfully into unassigned Settings Catalog policies with exact
snapshot-validated settings. All five packs also pass live dry-run validation and were
imported into a test tenant as nine unassigned policies with their mapped settings.
Continue evidence-backed mapping review; do not represent any of these partial catalogs
as a complete CIS baseline.

## 3. iOS 17 / iPadOS 17 Intune

Implement native Intune configuration and compliance objects from the Intune-specific benchmark using the same fail-closed workflow.

## Not planned

Generic Apple OS, Android, Microsoft Edge, Google Chrome, and Safari benchmarks are not part of this repository's supported benchmark catalog. An explicitly Intune-authored edition, such as CIS Microsoft Intune for Edge v1.0.0, is a separate eligible source.
