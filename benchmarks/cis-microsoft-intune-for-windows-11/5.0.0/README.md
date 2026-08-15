# CIS Microsoft Intune for Windows 11 Benchmark v5.0.0

This directory contains a copyright-safe mapping catalog for the exact Intune-authored benchmark version. It contains 415 recommendation identifiers with profile and CIS assessment metadata, but no benchmark prose.

Twenty-eight recommendations currently have exact Settings Catalog definition and option/value mappings validated against a pinned Microsoft Graph snapshot. They compile into 28 dynamic settings across 10 unassigned policies. The original 18 mappings passed a live tenant dry run; the 10 newly promoted priority Level 1 mappings await a fresh live dry run. The other 387 recommendations remain `unresolved` and emit no implementation. This is a partial reviewed catalog and must not be represented as a complete CIS baseline.

Promote an entry from `unresolved` only after its Intune implementation is reviewed against authoritative Microsoft Graph evidence. Settings Catalog entries require a pinned tenant snapshot and exact definition and option/value identifiers. Organizational choices must use explicit administrator inputs. Process-only recommendations must remain `manual`. No assignments belong in this catalog or in generated packs.

The licensed source PDF, private extraction, tenant snapshot, administrator decisions, and import logs must remain outside Git.
