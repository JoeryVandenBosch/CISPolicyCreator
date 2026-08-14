# CISPolicyCreator chat handoff

**Updated:** 2026-08-14
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

Important supporting commands:

- `Export-SettingsCatalogDiagnostics.ps1`: capture a pinned definition snapshot;
- `New-CISMappingCatalog.ps1`: create a copyright-safe all-unresolved catalog seed from private extraction;
- `New-CISAdministratorDecisions.ps1`: generate an explicit decision template;
- `Build-CISPolicyPack.ps1`: deterministic compiler for already extracted input;
- `Test-CISPolicyPack.ps1`: offline schema and semantic validator;
- `Get-CISMappingReport.ps1`: assessment/mapping audit report;
- `Import-CISPolicyPack.ps1`: live dry run and explicit unassigned import.

Generated manifests contain SHA-256 provenance for the PDF, mapping catalog, decisions, and definition snapshot. Repeated builds from identical inputs are byte-identical.

## Verification

The repository contains copyright-safe tests for extraction, Manual+mapped semantics, missing and valid administrator decisions, exact choices, ambiguous definitions, assignment rejection, deterministic repeated builds, and real synthetic-PDF orchestration. GitHub Actions installs the hash-pinned PDF dependency and runs the complete suite.

## Current benchmark state

The generic pipeline is implemented. The supplied Windows 11 v5.0.0 source extracts to 415 unique recommendations (408 Automated and 7 Manual), and the repository contains a public-safe all-unresolved inventory catalog for those identifiers. The full orchestrator produces a validated nondeployable pack with zero settings, Graph objects, or assignments. The next content milestone is evidence-backed review of that catalog against a pinned tenant snapshot, followed by macOS 26 Tahoe Intune and iOS/iPadOS Intune according to the supported roadmap.

Source PDFs, raw extraction text, private decisions, tenant identifiers, and import logs must not be committed.
