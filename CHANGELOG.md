# Changelog

All notable changes to PipeDFe will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project intends to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html) for releases.

## [Unreleased]

### Added
- Closing-stage audit events for indexing, fiscal processing, archives, reports and delivery.
- Production deployment and recovery checklist.
- Public `Get-PipeDFeHealth` command export and localized MAML help for all public commands in pt-BR and en-US.
- Localized `about_PipeDFe` conceptual help topics and integration tests for real PowerShell help resolution.
- Build artifact verification for module imports and localized help in separate PowerShell processes.
- Integration coverage for versioned and PowerShell Gallery build layouts, localized help installation, and SHA-256 inventory integrity.
- Integration coverage for `Get-PipeDFeHealth`, including real company registration, SQLite schema validation, trade-name resolution, missing indexes, and output contracts.

### Changed
- Closing reports are standalone HTML files; XLSX generation is outside the 1.0 scope.
- Health guidance explicitly identifies unsupported index schema versions and the need to preserve delivery history during migration.
- Module build now stages a versioned installation layout and a PowerShell Gallery-compatible `PipeDFe` directory, including localized help at the module root.
- Release instructions now cover both layouts, validation, and explicit opt-in publishing.
- Health diagnostics use the centralized SQLite index schema version instead of a hardcoded expected version.
- Health results display `NomeFantasia` when configured and fall back to `RazaoSocial` otherwise.
- Health unit tests use company fixtures aligned with the actual registration contract and the current index schema.
- Reworked the project README to emphasize DF-e ingestion, processing, and automated email delivery as the module's primary purpose.

### Fixed
- Standardized the Brazilian Portuguese culture directory name to `pt-BR`.
- Removed obsolete operational guide references from conceptual help topics.
- Health classification distinguishes outdated index schemas from database inspection failures.

## Release history

The repository manifest currently declares module version `0.1.0`. No dated or tagged releases are listed here until their published history is verified.

When a version is published, move its relevant entries from **Unreleased** to a dated release heading, for example `## [1.0.0] - YYYY-MM-DD`. Document only changes included in that release.
