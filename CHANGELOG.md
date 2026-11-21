# Changelog

All notable changes to PipeDFe will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project intends to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html) for releases.

## [Unreleased]

### Added
- Integration coverage for `Get-PipeDFeHealth`, including real company registration, SQLite schema validation, trade-name resolution, missing indexes, and output contracts.

### Changed
- Health diagnostics use the centralized SQLite index schema version instead of a hardcoded expected version.
- Health results display `NomeFantasia` when configured and fall back to `RazaoSocial` otherwise.
- Health unit tests use company fixtures aligned with the actual registration contract and the current index schema.
- Expanded the project README with setup, operating guidance, fiscal document scope, and delivery safeguards.

### Fixed
- Health classification distinguishes outdated index schemas from database inspection failures.

## Release history

The repository manifest currently declares module version `0.1.0`. No dated or tagged releases are listed here until their published history is verified.

When a version is published, move its relevant entries from **Unreleased** to a dated release heading, for example `## [1.0.0] - YYYY-MM-DD`. Document only changes included in that release.
