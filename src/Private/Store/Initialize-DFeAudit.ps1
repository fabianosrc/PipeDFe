<#
.SYNOPSIS
Ensures the SQLite operational audit database and schema exist for a CNPJ.

.DESCRIPTION
Creates the audit database and its parent directory when missing, then
initializes or upgrades the audit schema to the current version.

The audit database stores operational execution history and events.
It does not store fiscal XML content or sensitive credentials.

The database uses:
  - WAL journal mode for concurrent readers.
  - NORMAL synchronous mode for a balance between durability and performance.
  - Foreign-key enforcement for schema integrity.

Schema:
  audit_execution
      One record per PipeDFe execution associated with the company.

  audit_event
      One record per operational event generated during an execution.

Schema evolution is tracked through SQLite PRAGMA user_version.

Current schema version: 1.

.PARAMETER Cnpj
14-digit normalized CNPJ identifying the company audit database.

.OUTPUTS
System.String
Full path to the audit.db file.

.EXAMPLE
PS C:\> $databasePath = Initialize-DFeAudit -Cnpj '12345678000199'

.NOTES
Private dependencies:
  Get-StorePath
  Open-SqliteConnection
#>
function Initialize-DFeAudit {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSAvoidUsingEmptyCatchBlock',
        '',
        Justification = 'Rollback is best-effort; do not mask the original exception.'
    )]
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [ValidatePattern('^[A-Z0-9]{14}$')]
        [string]$Cnpj
    )

    $databasePath = Get-StorePath -Scope 'Audit' -Cnpj $Cnpj
    $databaseDir  = [System.IO.Path]::GetDirectoryName($databasePath)

    if (-not (Test-Path -LiteralPath $databaseDir -PathType Container)) {
        try {
            $newItemParams = @{
                Path        = $databaseDir
                ItemType    = 'Directory'
                Force       = $true
                ErrorAction = 'Stop '
            }

            New-Item @newItemParams | Out-Null
        } catch {
            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    $_.Exception,
                    'AuditDirectoryCreateFailed',
                    [System.Management.Automation.ErrorCategory]::WriteError,
                    $databaseDir
                )
            )
        }
    }

    $connection = $null

    try {
        $connection = Open-SqliteConnection -Path $databasePath

        $pragmaStatements = @(
            'PRAGMA journal_mode = WAL;'
            'PRAGMA synchronous  = NORMAL;'
            'PRAGMA foreign_keys = ON;'
        )

        foreach ($pragma in $pragmaStatements) {
            $pragmaCommand = $null

            try {
                $pragmaCommand = $connection.CreateCommand()
                $pragmaCommand.CommandText = $pragma
                $pragmaCommand.ExecuteNonQuery() | Out-Null
            } finally {
                if ($null -ne $pragmaCommand) {
                    $pragmaCommand.Dispose()
                }
            }
        }

        $transaction = $null
        $command = $null

        try {
            $transaction = $connection.BeginTransaction()
            $command = $connection.CreateCommand()
            $command.Transaction = $transaction

            $command.CommandText = 'PRAGMA user_version;'
            $currentVersion = [int]$command.ExecuteScalar()

            switch ($currentVersion) {
                0 {
                    $command.CommandText = @'
CREATE TABLE IF NOT EXISTS audit_execution (
    execution_id      TEXT NOT NULL PRIMARY KEY,
    started_at        TEXT NOT NULL,
    completed_at      TEXT,
    mode              TEXT NOT NULL,
    requested_period  TEXT,
    status            TEXT NOT NULL,
    module_version    TEXT,
    error_summary     TEXT
);

CREATE TABLE IF NOT EXISTS audit_event (
    event_id       INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
    execution_id   TEXT NOT NULL,
    timestamp      TEXT NOT NULL,
    company_cnpj   TEXT NOT NULL,
    document_id    TEXT,
    event_type     TEXT NOT NULL,
    status         TEXT NOT NULL,
    message        TEXT,
    error_code     TEXT,
    duration_ms    INTEGER,

    CONSTRAINT fk_audit_event_execution
        FOREIGN KEY (execution_id)
        REFERENCES audit_execution (execution_id)
        ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS ix_audit_execution_started_at
    ON audit_execution (started_at);

CREATE INDEX IF NOT EXISTS ix_audit_execution_status
    ON audit_execution (status);

CREATE INDEX IF NOT EXISTS ix_audit_event_execution_id
    ON audit_event (execution_id);

CREATE INDEX IF NOT EXISTS ix_audit_event_company_timestamp
    ON audit_event (company_cnpj, timestamp);

CREATE INDEX IF NOT EXISTS ix_audit_event_document_id
    ON audit_event (document_id)
    WHERE document_id IS NOT NULL;

PRAGMA user_version = 1;
'@
                    $null = $command.ExecuteNonQuery()
                }

                1 {
                    # Current schema. No migration required.
                }

                default {
                    throw [System.InvalidOperationException]::new(
                        "Unsupported audit schema version '$currentVersion'."
                    )
                }
            }

            $transaction.Commit()
        } catch {
            if ($null -ne $transaction) {
                try {
                    $transaction.Rollback()
                } catch {
                    # Ignore rollback failure to preserve the original exception.
                }
            }

            throw
        } finally {
            if ($null -ne $command) {
                $command.Dispose()
            }

            if ($null -ne $transaction) {
                $transaction.Dispose()
            }
        }
    } catch {
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                $_.Exception,
                'AuditSchemaInitFailed',
                [System.Management.Automation.ErrorCategory]::WriteError,
                $databasePath
            )
        )
    } finally {
        if ($null -ne $connection) {
            $connection.Dispose()
        }
    }

    $databasePath
}
