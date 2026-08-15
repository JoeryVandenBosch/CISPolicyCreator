# Contributing

Contributions are welcome, with one non-negotiable rule: **fail closed**.

## Benchmark scope

Supported benchmark packs must be based on a CIS benchmark explicitly authored for Microsoft Intune.

## Do not submit

- CIS PDF source files;
- CIS SecureSuite Build Kits;
- raw extraction JSON containing copied benchmark prose;
- secrets, tenant-specific credentials, or exported tokens;
- policy mappings based on guesses.

## Mapping requirements

Record `cisAssessmentMethod` (`Manual` or `Automated`) independently from `mappingStatus`. A CIS Manual recommendation may be mapped when its Intune implementation is deterministic.

Every deployable recommendation must be `mapped` and reference a reviewed Intune implementation. Use `requires-input` for organizational choices, `manual` for non-policy/process work, and `unresolved` whenever an exact Graph object, setting definition, value, platform requirement, or enrollment prerequisite cannot be proven.

Private mapping reviews use `defer` for undecided candidates, `rejected` for explicitly reviewed false candidates, and `mapped` only for acknowledged exact evidence. Rejection never changes the catalog mapping status or emits implementation content.

Mapping catalogs must never use constructed IDs, display-name fallback, substring/suffix option matching, or unvalidated static Settings Catalog payloads. Add copyright-safe fixtures and fail-closed tests with every new implementation mechanism.

## Pull requests

Before opening a PR:

```powershell
.\scripts\Test-CISRepository.ps1 -PythonPath .\.venv\Scripts\python.exe
```

Run a `-DryRun` against a test tenant when the pack is intended for deployment and include non-sensitive validation notes in the PR description.
