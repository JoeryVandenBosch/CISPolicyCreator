# CIS Apple macOS 26 Tahoe Intune v1.0.0

This directory contains a public-safe, fully classified catalog for all 100 recommendations in the exact Intune-authored benchmark version. It contains no benchmark prose.

The catalog has 84 deterministic Intune mappings, 14 recommendations requiring explicit administrator values, one non-policy/manual control, and one deliberately unresolved recommendation. With all administrator values supplied, it emits 82 unassigned Settings Catalog policy JSON files.

Recommendation 2.13.1, Locked enrollment, remains unresolved. The exact setting and value are known, but Microsoft requires a complete ADE enrollment profile with organization-specific companion settings. The project does not invent those choices or emit an incomplete standalone policy.

Future benchmark revisions must repeat the same fail-closed review. Source PDFs, private extraction data, tenant snapshots, administrator decisions, and import logs must remain outside Git.
