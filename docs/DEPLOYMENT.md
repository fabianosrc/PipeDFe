# Production deployment

## Preparation

- Use a dedicated Windows account with a loaded user profile and least-privilege access.
- Validate the exact distributable artifact on the intended PowerShell edition and architecture. Run the release checklist before installation.
- Set PIPEDFE_DATA_ROOT to an absolute, persistent local directory in the scheduled process environment. Restrict access to the service account and authorized administrators.
- Grant read access to source XML directories and write access to the configured output and data directories.
- Configure SMTP under the same Windows account that will run the scheduled task. Verify credential decryption and a controlled test delivery under that identity; do not assume DPAPI credentials are portable.
- Run Get-PipeDFeHealth and resolve all unexpected findings before enabling scheduled delivery.

## Scheduling and acceptance

Configure Windows Task Scheduler to run the selected PowerShell executable with NoProfile and NonInteractive, using an approved script that imports the pinned module version and invokes Invoke-PipeDFe with the intended parameters. Set the task to avoid overlapping instances. Capture execution results and restrict access to logs.

Before enabling real recipients, validate representative fiscal models, an NFS-e-only company, event handling, ZIP integrity, standalone HTML reports, repeated execution, SMTP failures, interrupted delivery, manual resolution, and isolation between companies. Verify audit records and task execution under the actual scheduled identity.

## Backup and recovery

Disable the scheduled task and wait for active executions to finish before taking a consistent backup. Preserve the entire data root, including company configuration, indexes, audit databases and any SQLite sidecar files, plus configured output directories and source XMLs according to the organization's backup policy. Protect backups as confidential fiscal data.

Test restoration in an isolated environment with controlled recipients. Verify health and delivery history before resuming production. Never rebuild an index as a substitute for preserving delivery history. An unsupported legacy schema requires a separately validated migration; do not delete the original index.

If delivery is indeterminate, inspect the SMTP provider evidence and audit records. Use Get-Help Resolve-PipeDFeDelivery -Full for the exact command contract. Resolve only the matching attempt with a documented reason and verified acceptance or nonacceptance. Do not automatically retry an uncertain delivery.

## Rollback and retention

Stop scheduling before rollback. Verify schema compatibility with the previous module version; do not downgrade an index in place. Preserve current delivery history and reconcile any messages accepted since the backup before restoring or resuming delivery.

Define retention periods with the responsible accounting and security teams. Do not automatically delete archives, reports, audit records or indexes in version 1.0. Monitor free disk space and validate backup recovery periodically.
