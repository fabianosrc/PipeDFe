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

.PARAMETER Cnpj
14-digit normalized CNPJ identifying the company index.

.OUTPUTS
System.String
Full path to the index.db file.

.EXAMPLE
PS C:\> $databasePath = Initialize-DFeIndex -Cnpj '12345678000199'
#>
function Initialize-DFeIndex {
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [ValidatePattern('^[A-Z0-9]{14}$')]
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
            $command = $connection.CreateCommand()

            try {
                $command.CommandText = $pragma
                $command.ExecuteNonQuery() | Out-Null
            } finally {
                $command.Dispose()
            }
        }

        $transaction = $connection.BeginTransaction()

        try {
            $command = $connection.CreateCommand()
            $command.Transaction = $transaction

            try {
                $command.CommandText = 'PRAGMA user_version;'
                $currentVersion = [int]$command.ExecuteScalar()
            } finally {
                $command.Dispose()
            }

            switch ($currentVersion) {
                0 {
                    $command = $connection.CreateCommand()
                    $command.Transaction = $transaction

                    try {
                        $command.CommandText = @'
CREATE TABLE IF NOT EXISTS dfe_document (
    chave_acesso TEXT    NOT NULL PRIMARY KEY,
    modelo       INTEGER NOT NULL,
    file_path    TEXT    NOT NULL,
    is_proc      INTEGER NOT NULL DEFAULT 0 CHECK (is_proc IN (0, 1)),
    ndoc         INTEGER,
    serie        TEXT,
    dh_emi       TEXT,
    sha256       TEXT    NOT NULL,
    indexed_at   TEXT    NOT NULL
);

CREATE INDEX IF NOT EXISTS ix_dfe_document_modelo_serie
    ON dfe_document (modelo, serie)
    WHERE ndoc IS NOT NULL;

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

PRAGMA user_version = 1;
'@
                        $command.ExecuteNonQuery() | Out-Null
                    } finally {
                        $command.Dispose()
                    }
                }

                1 {
                    # Current schema version.
                }

                default {
                    throw [System.InvalidOperationException]::new(
                        "Unsupported index schema version '$currentVersion'."
                    )
                }
            }

            $transaction.Commit()
        } catch {
            try {
                $transaction.Rollback()
            } catch {
                # Intentionally ignore rollback failure because the original
                # database error must remain the terminating error.
                $null = $_
            }

            throw
        } finally {
            $transaction.Dispose()
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
