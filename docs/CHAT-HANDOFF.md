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

- `Initialize-CISPolicyCreator.ps1`: create or reuse the local virtual environment, install the hash-locked offline parser dependency, and optionally install the exact pinned Graph authentication module into ignored local storage;
- `Import-CISGraphAuthentication.ps1`: load only the exact repository-pinned local or installed Graph authentication module before live operations;
- `Test-CISPrerequisites.ps1`: verify PowerShell, Python, the parser contract, and optionally the locked Graph authentication contract;
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
- `Get-CISMappingReport.ps1`: deterministic assessment/mapping audit report generated only from a fully valid pack;
- `Import-CISPolicyPack.ps1`: read-only live dry run plus tenant-pinned, separately acknowledged probe/import write modes; partial packs require an additional explicit acknowledgement, same-name Settings Catalog policies must exactly match before skip, generic-object name collisions abort, and policies remain unassigned.

Generated manifests contain SHA-256 provenance for the PDF, mapping catalog, decisions, and definition snapshot. Repeated builds from identical inputs are byte-identical. The compiler and orchestrator publish with atomic same-parent moves and limit failure cleanup to artifacts owned by that run.
When a mapped leaf choice/integer/string exists, the compiler also embeds one deterministic, exact-copy write probe; otherwise the probe remains unavailable rather than being guessed.

## Verification

The repository contains copyright-safe tests for clean runtime initialization, automatic local-environment discovery, extraction, Manual+mapped semantics, private candidate worklists, deferred/rejected/mapped review states, deterministic private progress reports, missing and valid administrator decisions, exact choices, simple collections, nested choice/group trees, ambiguous definitions, assignment rejection, linked-path rejection, exact existing-policy comparison, deterministic repeated builds, and real synthetic-PDF orchestration. GitHub Actions initializes the same hash-pinned environment and runs the complete suite.

## Current benchmark state

The generic pipeline is implemented. The supplied Windows 11 v5.0.0 source extracts to 415 unique recommendations (408 Automated and 7 Manual). The public-safe catalog now contains 28 exact Settings Catalog mappings validated against a pinned 18,227-definition Graph snapshot; 387 recommendations remain unresolved. The full PDF orchestrator produces 28 dynamic settings in 10 unassigned policies, and repeated real-PDF builds are byte-identical. All 28 mappings pass pinned-tenant live mapping validation. An earlier explicitly acknowledged Level 1 partial-pack import made no changes because all eight target policy names were present. The importer now reads a unique same-name Settings Catalog policy and requires exact metadata plus complete nested setting/value equivalence before skipping it. A subsequent read-only live run validated all 25 selected Level 1 mappings, found that the first existing policy had 27 settings while the partial pack expected 1, and correctly aborted before any write or assignment. The private deterministic review worklist reports 265 unique candidates, 50 ambiguous recommendations, and 100 without candidates. A targeted hash-bound review promoted only 10 exact, top-level, priority Level 1 occurrences and left the other 305 candidate rows deferred. Three initially shortlisted rows were deliberately left unresolved because their required sub-value or exact option label was not proven. Administrator-controlled assignment and test-device behavior validation remain manual. The catalog is partial and must not be represented as a complete CIS baseline.

Source PDFs, raw extraction text, private review/approval/report files, private decisions, tenant identifiers, and import logs must not be committed.
