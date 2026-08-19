# CIS Microsoft Intune for Windows 11 Benchmark v5.0.0

This directory contains a copyright-safe mapping catalog for the exact Intune-authored benchmark version. It contains 415 recommendation identifiers with profile and CIS assessment metadata, but no benchmark prose.

All 415 recommendations are explicitly classified: 371 have deterministic Intune
mappings, 8 require explicit administrator values, 36 are non-policy/manual controls,
and none remain unresolved. `cisAssessmentMethod` remains independent: seven
recommendations assessed manually by CIS still have deterministic Windows compliance
policy mappings.

With all nine administrator decisions supplied, the real PDF compiles into 325 Settings
Catalog JSON policies and one Windows compliance JSON policy. Required dependent
settings and duplicate CIS rows are bundled where necessary, every filename starts
with `V5-`, and no assignments are present. Pack validation, split-policy ZIP
validation, offline importer validation, and repeated-build byte reproducibility pass
against the pinned 18,227-definition Microsoft Graph snapshot.

Future benchmark revisions must repeat the same review. Settings Catalog entries require
a pinned tenant snapshot and exact definition and option/value identifiers.
Organizational choices use explicit administrator inputs. Process-only recommendations
remain `manual`. No assignments belong in this catalog or in generated packs.

The licensed source PDF, private extraction, tenant snapshot, administrator decisions, and import logs must remain outside Git.
