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

Every deployable recommendation must be `mapped` and reference a reviewed Intune implementation. If an exact Graph object, setting definition, value, platform requirement, or enrollment prerequisite cannot be proven, use `unresolved` or `manual`.

## Pull requests

Before opening a PR:

```powershell
.\scripts\Test-CISPolicyPack.ps1 -PackRoot <pack>
```

Run a `-DryRun` against a test tenant when the pack is intended for deployment and include non-sensitive validation notes in the PR description.
