# CISPolicyCreator chat handoff

**Updated:** 2026-08-17
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
- `Build-CISSupportedBenchmark.ps1`: beginner-facing exact-version selector for the six cataloged PDFs;
- `Test-CISPolicyPack.ps1`: offline schema and semantic validator;
- `Test-CISRepository.ps1`: one-command local/CI privacy, schema, parser, pipeline, extractor, and synthetic-PDF verification;
- `Get-CISMappingReport.ps1`: deterministic assessment/mapping audit report generated only from a fully valid pack;
- `Import-CISPolicyPack.ps1`: read-only live dry run plus tenant-pinned, separately acknowledged probe/import write modes; an explicitly requested existing Graph context is accepted only after tenant and scope validation; partial packs require an additional explicit acknowledgement, same-name Settings Catalog policies must exactly match before skip, contract-bound generic objects require an exact expected-property comparison before skip, and policies remain unassigned.

Generated manifests contain SHA-256 provenance for the PDF, mapping catalog, decisions, and definition snapshot. Repeated builds from identical inputs are byte-identical. The compiler and orchestrator publish with atomic same-parent moves and limit failure cleanup to artifacts owned by that run.
When a mapped leaf choice/integer/string exists, the compiler also embeds one deterministic, exact-copy write probe; otherwise the probe remains unavailable rather than being guessed.

## Verification

The repository contains copyright-safe tests for clean runtime initialization, automatic local-environment discovery, extraction, Manual+mapped semantics, private candidate worklists, deferred/rejected/mapped review states, deterministic private progress reports, lowercase private-artifact naming, missing and valid administrator decisions, exact choices, simple collections, nested choice/group trees, ambiguous definitions, assignment rejection, platform-correct path containment, linked-path rejection, exact existing-policy comparison, deterministic repeated builds, and real synthetic-PDF orchestration. GitHub Actions initializes the same hash-pinned environment and runs the complete suite.

## Current benchmark state

The generic pipeline is implemented for the six exact selectors exposed by `Build-CISSupportedBenchmark.ps1`. Deterministic exact-name/value review against the pinned 18,227-definition Settings Catalog snapshot expanded the public-safe catalogs to: Windows 11 v5.0.0, 154 mapped and 261 unresolved; Windows 10 v5.0.0, 121 mapped and 237 unresolved; Edge v1.0.0, 125 mapped and 13 unresolved; Office v1.1.0, 203 mapped and 35 unresolved; and macOS 26 Tahoe Intune v1.0.0, 57 mapped and 43 unresolved.

iOS 26 / iPadOS 26 Intune v1.0.0 now combines six exact Settings Catalog mappings with two typed `iosGeneralDeviceConfiguration` objects protected by a pinned Graph contract. It has 78 mapped recommendations, 2 duplicate password-length recommendations that share one explicit administrator decision, and 14 unresolved recommendations. Supplying a reviewed length from 6 through 14 yields 80 mapped recommendations and a third unassigned Graph object. The importer can skip a unique existing contract-bound object only when every expected property matches; it never patches or assigns it.

All six expanded catalogs have passed extraction-bound builds from the supplied real PDFs, offline policy-pack validation, and one read-only live dry run in the pinned `intunedev.team` test tenant. The catalogs contain 738 mapped recommendations: 666 exact Settings Catalog entries plus 72 iOS/iPadOS recommendations implemented by two contract-bound Graph objects. The live run treated one exactly matching existing macOS policy as an idempotent skip, proposed the other unassigned creates, and made zero writes or assignments. Earlier smaller subsets passed real unassigned test-tenant import. Every catalog remains partial and must not be represented as a complete CIS baseline. Ambiguous device/user definitions, non-exact wording, multi-valid-value recommendations, enrollment/compliance controls without a reviewed adapter, and process controls remain nondeployable rather than guessed.

Source PDFs, raw extraction text, private review/approval/report files, private decisions, tenant identifiers, and import logs must not be committed.
