<#
.SYNOPSIS
Ensures the SQLite index database and schema exist for a given CNPJ.

.DESCRIPTION
Creates the index database and its parent directory when missing, then
initializes or upgrades the database schema to the current version.

The function is idempotent and safe to call on every run.

The database uses:
  - WAL journal mode for concurrent readers.
  - NORMAL synchronous mode for a balance between durability and performance.
  - Foreign-key enforcement for schema integrity.

Schema:
  dfe_document
      One record per fiscal document (chave de acesso).
      A Proc document takes precedence over a bare document.
      ndoc and serie are optional - their presence depends on the
      document model. MDF-e, for example, has no serie.

  dfe_evento
      One record per physical evento file, keyed by
      (chave_pai, file_path).

  dfe_inutilizacao
      One record per inutilizacao range, keyed by id_inut.
      Required for correct gap analysis.

Schema evolution is tracked through SQLite PRAGMA user_version.

Current schema version: 3.

.PARAMETER Cnpj
14-digit normalized CNPJ identifying the company index.

.OUTPUTS
System.String
Full path to the index.db file.

.EXAMPLE
PS C:\> $databasePath = Initialize-DFeIndex -Cnpj '12345678000199'

.NOTES
Private dependencies:
  Get-StorePath
  Open-SqliteConnection
#>
function Initialize-DFeIndex {
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
        [ValidatePattern('^(?-i)[A-Z0-9]{14}$')]
        [string]$Cnpj
    )

    $databasePath = Get-StorePath -Scope 'Index' -Cnpj $Cnpj
    $databaseDir  = [System.IO.Path]::GetDirectoryName($databasePath)

    if (-not (Test-Path -LiteralPath $databaseDir -PathType Container)) {
        try {
            New-Item -Path $databaseDir -ItemType Directory -Force | Out-Null
        } catch {
            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    $_.Exception,
                    'IndexDirectoryCreateFailed',
                    [System.Management.Automation.ErrorCategory]::WriteError,
                    $databaseDir
                )
            )
        }
    }

    $connection = $null

    try {
        $connection = Open-SqliteConnection -Path $databasePath

        # Execute PRAGMAs individually for provider compatibility.
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
        $command     = $null

        try {
            $transaction = $connection.BeginTransaction()
            $command = $connection.CreateCommand()
            $command.Transaction = $transaction

            $command.CommandText = 'PRAGMA user_version;'
            $currentVersion = [int]$command.ExecuteScalar()

            switch ($currentVersion) {

                # =====================================================
                # Version 0
                #
                # New database. Create the complete v2 schema.
                # =====================================================
                0 {
                    $command.CommandText = @'
CREATE TABLE IF NOT EXISTS dfe_document (
    chave_acesso TEXT    NOT NULL PRIMARY KEY,
    modelo       INTEGER NOT NULL,
    file_path    TEXT    NOT NULL,
    is_proc      INTEGER NOT NULL DEFAULT 0 CHECK (is_proc IN (0, 1)),
    ndoc         INTEGER,
    serie        TEXT,
    dh_emi       TEXT,
    sha256                  TEXT    NOT NULL,
    indexed_at              TEXT    NOT NULL,
    processing_status       TEXT    NOT NULL DEFAULT 'Indexed',
    processing_started_at   TEXT,
    processed_at            TEXT,
    processing_error        TEXT,
    CHECK (
        processing_status IN (
            'Indexed',
            'Processing',
            'Processed',
            'Failed'
        )
    )
);

CREATE INDEX IF NOT EXISTS ix_dfe_document_modelo_serie
    ON dfe_document (modelo, serie)
    WHERE ndoc IS NOT NULL;

CREATE INDEX IF NOT EXISTS ix_dfe_document_sha256
    ON dfe_document (sha256)
    WHERE sha256 IS NOT NULL;

CREATE TABLE IF NOT EXISTS dfe_evento (
    chave_pai   TEXT NOT NULL,
    file_path   TEXT NOT NULL,
    evento_tipo TEXT,
    dh_emi      TEXT,
    sha256      TEXT NOT NULL,
    indexed_at  TEXT NOT NULL,
    PRIMARY KEY (chave_pai, file_path)
);

CREATE INDEX IF NOT EXISTS ix_dfe_evento_chave_pai
    ON dfe_evento (chave_pai);

CREATE INDEX IF NOT EXISTS ix_dfe_evento_sha256
    ON dfe_evento (sha256)
    WHERE sha256 IS NOT NULL;

CREATE TABLE IF NOT EXISTS dfe_inutilizacao (
    id_inut    TEXT    NOT NULL PRIMARY KEY,
    modelo     INTEGER NOT NULL,
    serie      TEXT    NOT NULL,
    nnf_ini    INTEGER NOT NULL,
    nnf_fin    INTEGER NOT NULL CHECK (nnf_fin >= nnf_ini),
    file_path  TEXT    NOT NULL,
    sha256     TEXT    NOT NULL,
    indexed_at TEXT    NOT NULL
);

CREATE INDEX IF NOT EXISTS ix_dfe_inutilizacao_modelo_serie
    ON dfe_inutilizacao (modelo, serie);

CREATE INDEX IF NOT EXISTS ix_dfe_inutilizacao_sha256
    ON dfe_inutilizacao (sha256)
    WHERE sha256 IS NOT NULL;

PRAGMA user_version = 3;
'@
                    $null = $command.ExecuteNonQuery()
                }

                # =====================================================
                # Version 1
                #
                # Legacy database. Add sha256 partial indexes.
                # =====================================================
                1 {
                    $command.CommandText = @'
CREATE INDEX IF NOT EXISTS ix_dfe_document_sha256
    ON dfe_document (sha256)
    WHERE sha256 IS NOT NULL;

CREATE INDEX IF NOT EXISTS ix_dfe_evento_sha256
    ON dfe_evento (sha256)
    WHERE sha256 IS NOT NULL;

CREATE INDEX IF NOT EXISTS ix_dfe_inutilizacao_sha256
    ON dfe_inutilizacao (sha256)
    WHERE sha256 IS NOT NULL;

PRAGMA user_version = 2;
'@
                    $null = $command.ExecuteNonQuery()
                }

                # =====================================================
                # Version 2
                #
                # Legacy current schema. Add document processing state.
                # =====================================================
                2 {
                    $command.CommandText = @'
ALTER TABLE dfe_document
ADD COLUMN processing_status TEXT NOT NULL DEFAULT 'Indexed';

ALTER TABLE dfe_document
ADD COLUMN processing_started_at TEXT;

ALTER TABLE dfe_document
ADD COLUMN processed_at TEXT;

ALTER TABLE dfe_document
ADD COLUMN processing_error TEXT;

CREATE INDEX IF NOT EXISTS ix_dfe_document_processing_status
    ON dfe_document (processing_status);

PRAGMA user_version = 3;
'@
                    $null = $command.ExecuteNonQuery()
                }

                # =====================================================
                # Version 3
                #
                # Current schema. No migration required.
                # =====================================================
                3 {
                    # No migration required.
                }

                default {
                    throw [System.InvalidOperationException]::new(
                        "Unsupported index schema version '$currentVersion'."
                    )
                }
            }

            $transaction.Commit()
        } catch {
            if ($null -ne $transaction) {
                try {
                    $transaction.Rollback()
                } catch {
                    # Intentionally ignore rollback failure - the original
                    # database error must remain the terminating error.
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
                'IndexSchemaInitFailed',
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
