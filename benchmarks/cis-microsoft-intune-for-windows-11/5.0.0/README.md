# CIS Microsoft Intune for Windows 11 Benchmark v5.0.0

This directory contains a copyright-safe mapping-catalog seed for the exact Intune-authored benchmark version. It contains 415 recommendation identifiers with profile and CIS assessment metadata, but no benchmark prose.

Every recommendation intentionally starts with `mappingStatus: unresolved`. Consequently, the catalog currently generates a structurally valid inventory pack with zero deployable policies. It must not be represented as an implemented CIS baseline.

Promote an entry from `unresolved` only after its Intune implementation is reviewed against authoritative Microsoft Graph evidence. Settings Catalog entries require a pinned tenant snapshot and exact definition and option/value identifiers. Organizational choices must use explicit administrator inputs. Process-only recommendations must remain `manual`. No assignments belong in this catalog or in generated packs.

The licensed source PDF, private extraction, tenant snapshot, administrator decisions, and import logs must remain outside Git.
