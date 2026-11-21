# Release process

This document describes the release checklist for PipeDFe. It is intended for maintainers and does not itself announce a release.

## Versioning

- The module version is declared in `PipeDFe.psd1` (`ModuleVersion`).
- Use [Semantic Versioning](https://semver.org/spec/v2.0.0.html) when assigning release versions.
- Keep development changes under `Unreleased` in `CHANGELOG.md`.
- Do not mark `1.0.0` as published until the release has been validated and tagged.
- Use a Git tag in the format `vX.Y.Z` (for example, `v1.0.0`).

## 1. Prepare the release

- [ ] Confirm the intended release scope and close or explicitly defer outstanding blockers.
- [ ] Confirm the working tree is clean and all intended changes are committed.
- [ ] Check that `README.md`, help text, and public command documentation match the source code.
- [ ] Confirm `FunctionsToExport` in `PipeDFe.psd1` includes the intended public commands, including `Get-PipeDFeHealth` if it is part of the release.
- [ ] Confirm `ModuleVersion`, module metadata, and licensing information are accurate.
- [ ] Confirm no test credentials, personal data, customer XMLs, database files, or other secrets are included in the release.
- [ ] Confirm required managed and native SQLite dependencies are included for supported PowerShell editions and process architectures.

## 2. Validate the module

Run these checks on **Windows PowerShell 5.1** and **PowerShell 7** where supported. The integration suite may require a properly configured Windows test environment.

```powershell
$manifestPath = Join-Path -Path (Get-Location) -ChildPath 'PipeDFe.psd1'

Test-ModuleManifest -Path $manifestPath
Import-Module -Name $manifestPath -Force -ErrorAction Stop
Get-Command -Module PipeDFe
```

Run the Pester suites:

```powershell
$unitParams = @{
    Path   = '.\tests\Unit'
    Output = 'Detailed'
}

Invoke-Pester @unitParams

$integrationParams = @{
    Path   = '.\tests\Integration'
    Output = 'Detailed'
}

Invoke-Pester @integrationParams
```

- [ ] Unit tests pass without unexpected skips or failures.
- [ ] Integration tests pass in an isolated data store, without modifying real company data.
- [ ] Confirm test coverage meets the project's agreed threshold, using the repository's current coverage configuration.
- [ ] Confirm the module loads on Windows PowerShell 5.1 and PowerShell 7.
- [ ] Confirm SQLite assembly and native library loading for the supported architectures in the distribution.
- [ ] Confirm module import and public command discovery work from a clean session.

## 3. Validate the fiscal workflow

Use **synthetic or authorized test data** and a controlled email environment.

- [ ] Register, read, update, and remove test company configurations as appropriate.
- [ ] Verify an NF-e/NFC-e/NFCom workflow with representative XML fixtures.
- [ ] Verify CT-e and MDF-e indexing and archive generation with representative fixtures.
- [ ] Verify a company containing only national NFS-e XMLs.
- [ ] Verify the default previous-calendar-month period and an explicit date range.
- [ ] Verify one ZIP is generated per applicable document model and document events are handled correctly.
- [ ] Verify source XML files are not modified and archive integrity checks behave as intended.
- [ ] Verify monthly HTML and XLSX reports are separate from ZIP archives.
- [ ] Verify the index schema is current and `Get-PipeDFeHealth` returns expected results.
- [ ] Verify sequence-gap behavior, including known inutilizations.
- [ ] Validate SMTP configuration and a test send to a controlled mailbox.
- [ ] Verify persistent delivery behavior, including no duplicate sending after `Delivered` and no automatic retry after `Indeterminate`.
- [ ] Verify a failure in one company does not silently hide or incorrectly report results for other companies.

Do not use real accounting recipients or customer data in release smoke tests without authorization.

## 4. Update release documentation

- [ ] Review each `Unreleased` entry in `CHANGELOG.md` against the actual commit history.
- [ ] Add a dated heading for the release and move only changes shipped in that version into it.
- [ ] Update `ModuleVersion` in `PipeDFe.psd1`.
- [ ] Confirm the README describes the released behavior and any important limitations.
- [ ] Commit the final version and documentation changes before tagging.

## 5. Tag and publish

After all checks pass, create and push the annotated tag from the intended release commit:

```powershell
git status --short
git tag -a v1.0.0 -m 'PipeDFe v1.0.0'
git push origin v1.0.0
```

Replace `v1.0.0` with the actual version being released. Do **not** execute the example until the release is approved.

Create a GitHub Release from that tag. Include a concise summary, relevant changelog entries, tested PowerShell versions, known limitations, and any necessary upgrade notes. Attach only verified distributable artifacts, if artifacts are provided.

Publication to PowerShell Gallery is **not** implied by creating a GitHub Release; evaluate packaging, dependencies, and distribution requirements separately before publishing there.

## 6. Post-release

- [ ] Verify the tag references the intended commit.
- [ ] Verify the GitHub Release and any downloadable artifacts are accessible and match the release version.
- [ ] Perform a clean installation/import smoke test using the published artifacts.
- [ ] Open a new `Unreleased` section in `CHANGELOG.md` for subsequent changes.
- [ ] Record follow-up issues for defects or deferred functionality.

## Release principles

Prefer explicit contracts, safe failure behavior, and reliable re-execution over premature optimization. Never bypass delivery-state safeguards merely to make a release test pass. The maintainer reviews and performs commits, tags, and publishing manually.
