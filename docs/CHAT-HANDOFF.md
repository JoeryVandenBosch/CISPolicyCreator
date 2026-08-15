# CISPolicyCreator chat handoff

**Updated:** 2026-08-15
**Active architecture:** reproducible pipeline / pack schema v2

## Goal

A user clones the repository, supplies a legitimately obtained CIS Benchmark PDF authored specifically for Microsoft Intune, selects the repository's reviewed catalog for that exact benchmark/version, and generates a validated Intune policy pack using repository scripts. AI is not a runtime dependency.

## Safety invariants

- Never guess or construct a Settings Catalog definition ID.
- Never guess or heuristically choose a choice/value ID.
- Exact explicit IDs or an exact unique `baseUri + offsetUri` tuple are the only setting resolvers.
- Ambiguous mappings remain unresolved or fail validation.
- Organizational decisions require an explicit acknowledged administrator input.
- Non-policy/process recommendations remain manual.
- Static unvalidated Settings Catalog payloads are rejected.
- No assignments or groups are created automatically.

`cisAssessmentMethod` (`Manual | Automated`) is independent from `mappingStatus` (`mapped | unresolved | requires-input | manual | not-applicable`). A CIS Manual recommendation may have a deterministic mapped Intune policy.

## Pipeline

`scripts/Invoke-CISPolicyPipeline.ps1` orchestrates private PDF extraction, source eligibility checks, reviewed catalog compilation, administrator decisions, exact definition-snapshot validation, deterministic pack generation, JSON Schema evaluation, and semantic fail-closed checks.

Extraction first verifies Python 3.11+ and requires the installed `pypdf` version to match both the SHA-256-locked requirements file and extraction schema exactly.

Important supporting commands:

- `Export-SettingsCatalogDiagnostics.ps1`: capture a pinned definition snapshot;
- `New-CISMappingCatalog.ps1`: create a copyright-safe all-unresolved catalog seed from private extraction;
- `New-CISMappingReviewWorklist.ps1`: recursively validate a private historical policy pack against a pinned snapshot and emit candidate-only review evidence without changing mappings;
- `New-CISMappingReviewApprovals.ps1`: create an all-deferred, hash-bound private reviewer template;
- `Get-CISMappingReviewReport.ps1`: generate deterministic private progress reports that distinguish undecided, rejected, and mapped candidate reviews without benchmark titles or state changes;
- `Apply-CISMappingReviewApprovals.ps1`: promote only explicitly acknowledged exact occurrences, then atomically publish a new catalog only after extraction-bound full-pack compilation and offline validation;
- `New-CISAdministratorDecisions.ps1`: generate an explicit decision template;
- `Build-CISPolicyPack.ps1`: deterministic compiler for already extracted input;
- `Test-CISPolicyPack.ps1`: offline schema and semantic validator;
- `Test-CISRepository.ps1`: one-command local/CI privacy, schema, parser, pipeline, extractor, and synthetic-PDF verification;
- `Get-CISMappingReport.ps1`: assessment/mapping audit report;
- `Import-CISPolicyPack.ps1`: read-only live dry run plus tenant-pinned, separately acknowledged probe/import write modes; policies remain unassigned.

Generated manifests contain SHA-256 provenance for the PDF, mapping catalog, decisions, and definition snapshot. Repeated builds from identical inputs are byte-identical.
When a mapped leaf choice/integer/string exists, the compiler also embeds one deterministic, exact-copy write probe; otherwise the probe remains unavailable rather than being guessed.

## Verification

The repository contains copyright-safe tests for extraction, Manual+mapped semantics, private candidate worklists, deferred/rejected/mapped review states, deterministic private progress reports, missing and valid administrator decisions, exact choices, simple collections, nested choice/group trees, ambiguous definitions, assignment rejection, deterministic repeated builds, and real synthetic-PDF orchestration. GitHub Actions installs the hash-pinned PDF dependency and runs the complete suite.

## Current benchmark state

The generic pipeline is implemented. The supplied Windows 11 v5.0.0 source extracts to 415 unique recommendations (408 Automated and 7 Manual). The public-safe catalog now contains 18 exact Settings Catalog mappings validated against a pinned 18,227-definition Graph snapshot; 397 recommendations remain unresolved. The full PDF orchestrator produces 18 dynamic settings in 6 unassigned policies, repeated direct/PDF builds are byte-identical, and all 18 settings pass a pinned-tenant live dry run with zero writes. A private deterministic review worklist derived from the pinned snapshot and historical policies reports 265 unique candidates, 50 ambiguous recommendations, and 100 without candidates. The hash-bound approval template contains 315 unresolved candidate rows, all defaulted to undecided `defer`; the deterministic progress report confirms zero mapped or rejected reviews and no public catalog change. The catalog is partial and must not be represented as a complete CIS baseline. Continue explicit evidence-backed review and test-tenant import/behavior validation before advancing to the later benchmark roadmap.

Source PDFs, raw extraction text, private review/approval/report files, private decisions, tenant identifiers, and import logs must not be committed.
