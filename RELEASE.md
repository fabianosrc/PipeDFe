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
- [ ] Check that `README.md`, `CHANGELOG.md`, `RELEASE.md` and localized MAML/about help match the source code.
- [ ] Confirm `FunctionsToExport` in `PipeDFe.psd1` lists all eleven public commands, including `Get-PipeDFeHealth` and `Resolve-PipeDFeDelivery`.
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

## 2.1 Build and validate the distributable package

Run the build **without** `-Publish`. By default it runs lint and Pester with at least 80% coverage before preparing the module:

```powershell
.\tools\Invoke-Build.ps1
```

The build produces two directories containing the same module contents:

```text
output/
├── PipeDFe/
│   └── 0.1.0/                 # Versioned installation layout
│       ├── PipeDFe.psd1
│       ├── PipeDFe.psm1
│       ├── pt-BR/
│       ├── en-US/
│       ├── src/
│       └── lib/
└── PSGallery/
    └── PipeDFe/               # Publish-Module -Path layout
        ├── PipeDFe.psd1
        ├── PipeDFe.psm1
        ├── pt-BR/
        ├── en-US/
        ├── src/
        └── lib/
```

`0.1.0` above is illustrative and must be replaced with the current `ModuleVersion` in `PipeDFe.psd1`.

The source-of-truth help files stay in `src/pt-BR` and `src/en-US` in the repository. The build copies them to the module root culture directories in each distributable layout. Both staged packages are checked using isolated PowerShell processes for each culture, including `Get-Help` MAML and `about_PipeDFe` loading.

The verification command may also be run directly:

```powershell
.\tools\Test-BuildArtifact.ps1 -ModulePath '.\output\PipeDFe\0.1.0'
.\tools\Test-BuildArtifact.ps1 -ModulePath '.\output\PSGallery\PipeDFe'
```

- [ ] The build integration test passes in an isolated artifact directory (`tests/Integration/Tools/Invoke-Build.Tests.ps1`).
- [ ] Build completes without skipped lint or tests.
- [ ] Staged manifest and public commands load from a clean PowerShell process.
- [ ] Both `pt-BR` and `en-US` MAML synopses resolve through `Get-Help`.
- [ ] Both localized `about_PipeDFe` topics resolve through `Get-Help`.
- [ ] `output/PipeDFe/<version>` and `output/PSGallery/PipeDFe` contain all required DLLs and module resources.
- [ ] Run the build and artifact verification on both Windows PowerShell 5.1 and PowerShell 7.

The build produces a directory ready for import or packaging. It does **not** prove that the PowerShell Gallery has accepted the package. A real publication requires an approved release, gallery access and an API key. Do not set `-Publish` as part of CI or ordinary local builds.

## 3. Validate the fiscal workflow

Use **synthetic or authorized test data** and a controlled email environment.

- [ ] Register, read, update, and remove test company configurations as appropriate.
- [ ] Verify an NF-e/NFC-e/NFCom workflow with representative XML fixtures.
- [ ] Verify CT-e and MDF-e indexing and archive generation with representative fixtures.
- [ ] Verify a company containing only national NFS-e XMLs.
- [ ] Verify the default previous-calendar-month period and an explicit date range.
- [ ] Verify one ZIP is generated per applicable document model and document events are handled correctly.
- [ ] Verify source XML files are not modified and archive integrity checks behave as intended.
- [ ] Verify that the NF-e/NFC-e HTML report is attached separately from the ZIP archives and omitted when neither model is present.
- [ ] Verify the index schema is current and `Get-PipeDFeHealth` returns expected results.
- [ ] Verify sequence-gap behavior, including known inutilizations.
- [ ] Validate SMTP configuration and a test send to a controlled mailbox.
- [ ] Verify persistent delivery behavior, including no duplicate sending after `Delivered` and no automatic retry after `Indeterminate`.
- [ ] Verify manual resolution of an indeterminate delivery using the matching attempt timestamp, documented evidence, and an explicit reason.
- [ ] Complete the production deployment and recovery checks in [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md).
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

Create a GitHub Release from that tag. Include a concise summary, relevant changelog entries, tested PowerShell versions, known limitations, and any necessary upgrade notes. Attach only verified distributable artifacts, if artifacts are provided. For PowerShellGet, `Publish-Module -Path` must reference a directory named `PipeDFe`, such as `output/PSGallery/PipeDFe`, rather than the version-number directory.

Publication to PowerShell Gallery is **not** implied by creating a GitHub Release; evaluate packaging, dependencies, and distribution requirements separately before publishing there.

## 6. Post-release

- [ ] Verify the tag references the intended commit.
- [ ] Verify the GitHub Release and any downloadable artifacts are accessible and match the release version.
- [ ] Perform a clean installation/import smoke test using the published artifacts.
- [ ] Open a new `Unreleased` section in `CHANGELOG.md` for subsequent changes.
- [ ] Record follow-up issues for defects or deferred functionality.

## Release principles

Prefer explicit contracts, safe failure behavior, and reliable re-execution over premature optimization. Never bypass delivery-state safeguards merely to make a release test pass. The maintainer reviews and performs commits, tags, and publishing manually.
