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

  dfe_nfe
      Normalized NF-e/NFC-e fiscal projection for a dfe_document record.
      Stores identification and extraction provenance.

  dfe_nfe_participante
      Emitente and destinatario data for the normalized NF-e/NFC-e projection.

  dfe_nfe_item
      One record per NF-e/NFC-e det item.

  dfe_nfe_item_*
      Normalized per-item tax groups for ICMS, IPI, PIS, COFINS and IBS/CBS.

  dfe_nfe_total_*
      Normalized document totals for ICMS, IBS/CBS and retained taxes.

Schema evolution is tracked through SQLite PRAGMA user_version.

Current schema version: 4.

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
        $command = $null

        try {
            $transaction = $connection.BeginTransaction()
            $command = $connection.CreateCommand()
            $command.Transaction = $transaction

            $command.CommandText = 'PRAGMA user_version;'
            $currentVersion = [int]$command.ExecuteScalar()

            # -------------------------------------------------------------------------
            # Schema definitions and migration steps.
            #
            # Each legacy version is upgraded to the current schema in a single call and
            # inside the same transaction. This keeps Initialize-DFeIndex aligned with
            # its contract: after successful return, the database is at the current
            # schema version.
            # -------------------------------------------------------------------------
            $createCoreSchemaSql = @'
CREATE TABLE IF NOT EXISTS dfe_document (
    chave_acesso          TEXT     NOT NULL PRIMARY KEY,
    modelo                INTEGER  NOT NULL,
    file_path             TEXT     NOT NULL,
    is_proc               INTEGER  NOT NULL DEFAULT 0 CHECK (is_proc IN (0, 1)),
    ndoc                  INTEGER,
    serie                 TEXT,
    dh_emi                TEXT,
    sha256                TEXT     NOT NULL,
    indexed_at            TEXT     NOT NULL,
    processing_status     TEXT     NOT NULL DEFAULT 'Indexed',
    processing_started_at TEXT,
    processed_at          TEXT,
    processing_error      TEXT,
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

CREATE INDEX IF NOT EXISTS ix_dfe_document_processing_status
    ON dfe_document (processing_status);

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
'@

            $migrateV1ToV2Sql = @'
CREATE INDEX IF NOT EXISTS ix_dfe_document_sha256
    ON dfe_document (sha256)
    WHERE sha256 IS NOT NULL;

CREATE INDEX IF NOT EXISTS ix_dfe_evento_sha256
    ON dfe_evento (sha256)
    WHERE sha256 IS NOT NULL;

CREATE INDEX IF NOT EXISTS ix_dfe_inutilizacao_sha256
    ON dfe_inutilizacao (sha256)
    WHERE sha256 IS NOT NULL;
'@

            $migrateV2ToV3Sql = @'
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
'@

            $createFiscalSchemaV4Sql = @'
CREATE INDEX IF NOT EXISTS ix_dfe_document_processing_status
    ON dfe_document (processing_status);

CREATE TABLE IF NOT EXISTS dfe_nfe (
    chave_acesso            TEXT    NOT NULL PRIMARY KEY,
    schema_version          INTEGER NOT NULL CHECK (schema_version > 0),
    source_sha256           TEXT    NOT NULL,
    extracted_at            TEXT    NOT NULL,

    modelo                  INTEGER NOT NULL CHECK (modelo IN (55, 65)),
    uf_emissao              TEXT,
    natureza_operacao       TEXT,
    serie                   TEXT,
    numero                  TEXT,
    emitido_em              TEXT,
    saida_entrada_em        TEXT,
    tipo_operacao           TEXT,
    destino                 TEXT,
    municipio_fato_gerador  TEXT,
    tipo_impressao          TEXT,
    tipo_emissao            TEXT,
    finalidade              TEXT,
    ind_consumidor_final    TEXT,
    ind_presenca            TEXT,

    FOREIGN KEY (chave_acesso)
        REFERENCES dfe_document (chave_acesso)
        ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS dfe_nfe_participante (
    chave_acesso        TEXT NOT NULL,
    tipo_participante   TEXT NOT NULL CHECK (tipo_participante IN ('Emitente', 'Destinatario')),
    cnpj                TEXT,
    cpf                 TEXT,
    razao_social        TEXT,
    nome_fantasia       TEXT,
    inscricao_estadual  TEXT,
    ind_ie              TEXT,
    regime_tributario   TEXT,
    email               TEXT,
    logradouro          TEXT,
    numero              TEXT,
    complemento         TEXT,
    bairro              TEXT,
    cod_municipio       TEXT,
    municipio           TEXT,
    uf                  TEXT,
    cep                 TEXT,
    cod_pais            TEXT,
    pais                TEXT,
    telefone            TEXT,

    PRIMARY KEY (chave_acesso, tipo_participante),

    FOREIGN KEY (chave_acesso)
        REFERENCES dfe_nfe (chave_acesso)
        ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS dfe_nfe_item (
    chave_acesso            TEXT    NOT NULL,
    n_item                  INTEGER NOT NULL CHECK (n_item > 0),
    cod_produto             TEXT,
    ean                     TEXT,
    descricao               TEXT,
    ncm                     TEXT,
    cest                    TEXT,
    cfop                    TEXT,
    unidade                 TEXT,
    qte_comercial           TEXT,
    vlr_unitario            TEXT,
    vlr_produto             TEXT,
    ean_tributavel          TEXT,
    unidade_tributavel      TEXT,
    qte_tributavel          TEXT,
    vlr_unitario_tributavel TEXT,
    vlr_frete               TEXT,
    vlr_seguro              TEXT,
    vlr_desconto            TEXT,
    vlr_outras_despesas     TEXT,
    ind_compoe_total        TEXT,

    PRIMARY KEY (chave_acesso, n_item),

    FOREIGN KEY (chave_acesso)
        REFERENCES dfe_nfe (chave_acesso)
        ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS ix_dfe_nfe_item_cfop
    ON dfe_nfe_item (cfop);

CREATE INDEX IF NOT EXISTS ix_dfe_nfe_item_ncm
    ON dfe_nfe_item (ncm);

CREATE TABLE IF NOT EXISTS dfe_nfe_item_icms (
    chave_acesso            TEXT    NOT NULL,
    n_item                  INTEGER NOT NULL,
    grupo                   TEXT,
    origem                  TEXT,
    cst                     TEXT,
    csosn                   TEXT,
    modalidade_bc           TEXT,
    vlr_bc                  TEXT,
    pct_reducao_bc          TEXT,
    pct_icms                TEXT,
    vlr_icms                TEXT,
    modalidade_bc_st        TEXT,
    pct_mva_st              TEXT,
    pct_reducao_bc_st       TEXT,
    vlr_bc_st               TEXT,
    pct_icms_st             TEXT,
    vlr_icms_st             TEXT,
    vlr_icms_desonerado     TEXT,
    motivo_desoneracao      TEXT,
    vlr_bc_fcp              TEXT,
    pct_fcp                 TEXT,
    vlr_fcp                 TEXT,
    vlr_bc_fcp_st           TEXT,
    pct_fcp_st              TEXT,
    vlr_fcp_st              TEXT,

    PRIMARY KEY (chave_acesso, n_item),

    FOREIGN KEY (chave_acesso, n_item)
        REFERENCES dfe_nfe_item (chave_acesso, n_item)
        ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS dfe_nfe_item_ipi (
    chave_acesso    TEXT    NOT NULL,
    n_item          INTEGER NOT NULL,
    grupo           TEXT,
    enquadramento   TEXT,
    cst             TEXT,
    vlr_bc          TEXT,
    pct_ipi         TEXT,
    qte_unidade     TEXT,
    vlr_unidade     TEXT,
    vlr_ipi         TEXT,

    PRIMARY KEY (chave_acesso, n_item),

    FOREIGN KEY (chave_acesso, n_item)
        REFERENCES dfe_nfe_item (chave_acesso, n_item)
        ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS dfe_nfe_item_pis (
    chave_acesso            TEXT    NOT NULL,
    n_item                  INTEGER NOT NULL,
    grupo                   TEXT,
    cst                     TEXT,
    vlr_bc                  TEXT,
    pct_pis                 TEXT,
    qte_bc                  TEXT,
    vlr_aliquota_unidade    TEXT,
    vlr_pis                 TEXT,

    PRIMARY KEY (chave_acesso, n_item),

    FOREIGN KEY (chave_acesso, n_item)
        REFERENCES dfe_nfe_item (chave_acesso, n_item)
        ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS dfe_nfe_item_cofins (
    chave_acesso            TEXT    NOT NULL,
    n_item                  INTEGER NOT NULL,
    grupo                   TEXT,
    cst                     TEXT,
    vlr_bc                  TEXT,
    pct_cofins              TEXT,
    qte_bc                  TEXT,
    vlr_aliquota_unidade    TEXT,
    vlr_cofins              TEXT,

    PRIMARY KEY (chave_acesso, n_item),

    FOREIGN KEY (chave_acesso, n_item)
        REFERENCES dfe_nfe_item (chave_acesso, n_item)
        ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS dfe_nfe_item_ibscbs (
    chave_acesso             TEXT    NOT NULL,
    n_item                   INTEGER NOT NULL,
    cst                      TEXT,
    classificacao_tributaria TEXT,
    vlr_bc                   TEXT,
    pct_ibs_uf               TEXT,
    vlr_ibs_uf               TEXT,
    pct_ibs_municipio        TEXT,
    vlr_ibs_municipio        TEXT,
    vlr_ibs                  TEXT,
    pct_cbs                  TEXT,
    vlr_cbs                  TEXT,

    PRIMARY KEY (chave_acesso, n_item),

    FOREIGN KEY (chave_acesso, n_item)
        REFERENCES dfe_nfe_item (chave_acesso, n_item)
        ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS dfe_nfe_total_icms (
    chave_acesso            TEXT NOT NULL PRIMARY KEY,
    vlr_bc_icms             TEXT,
    vlr_icms                TEXT,
    vlr_icms_desonerado     TEXT,
    vlr_fcp                 TEXT,
    vlr_bc_st               TEXT,
    vlr_st                  TEXT,
    vlr_fcp_st              TEXT,
    vlr_fcp_st_retido       TEXT,
    vlr_produtos            TEXT,
    vlr_frete               TEXT,
    vlr_seguro              TEXT,
    vlr_desconto            TEXT,
    vlr_ii                  TEXT,
    vlr_ipi                 TEXT,
    vlr_ipi_devolucao       TEXT,
    vlr_pis                 TEXT,
    vlr_cofins              TEXT,
    vlr_outras_despesas     TEXT,
    vlr_nota                TEXT,
    vlr_total_tributos      TEXT,

    FOREIGN KEY (chave_acesso)
        REFERENCES dfe_nfe (chave_acesso)
        ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS dfe_nfe_total_ibscbs (
    chave_acesso                        TEXT NOT NULL PRIMARY KEY,
    vlr_bc                              TEXT,
    vlr_ibs_uf                          TEXT,
    vlr_diferimento_ibs_uf              TEXT,
    vlr_devolucao_tributo_ibs_uf        TEXT,
    vlr_ibs_municipio                   TEXT,
    vlr_diferimento_ibs_municipio       TEXT,
    vlr_devolucao_tributo_ibs_municipio TEXT,
    vlr_ibs                             TEXT,
    vlr_credito_presumido_ibs           TEXT,
    vlr_credito_presumido_cond_sus_ibs  TEXT,
    vlr_cbs                             TEXT,
    vlr_diferimento_cbs                 TEXT,
    vlr_devolucao_tributo_cbs           TEXT,
    vlr_credito_presumido_cbs           TEXT,
    vlr_credito_presumido_cond_sus_cbs  TEXT,

    FOREIGN KEY (chave_acesso)
        REFERENCES dfe_nfe (chave_acesso)
        ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS dfe_nfe_total_rettrib (
    chave_acesso        TEXT NOT NULL PRIMARY KEY,
    vlr_csll_retido     TEXT,
    vlr_bc_irrf         TEXT,
    vlr_irrf            TEXT,

    FOREIGN KEY (chave_acesso)
        REFERENCES dfe_nfe (chave_acesso)
        ON DELETE CASCADE
);
'@

            # -------------------------------------------------------------------------
            # Schema object inventory for v4.
            #
            # Defines the columns that dfe_document must have for the schema to be
            # structurally compatible with v3+. Used to distinguish a partially-created
            # v4 database (recoverable) from a v1/v2 database left with user_version = 0
            # after an interrupted migration (structurally incompatible).
            # -------------------------------------------------------------------------
            $v4DocumentColumns = @(
                'chave_acesso'
                'modelo'
                'file_path'
                'is_proc'
                'ndoc'
                'serie'
                'dh_emi'
                'sha256'
                'indexed_at'
                'processing_status'
                'processing_started_at'
                'processed_at'
                'processing_error'
            )

            # -------------------------------------------------------------------------
            # Helper: query a scalar from sqlite_master inside the current transaction.
            # -------------------------------------------------------------------------
            $getObjectCount = {
                param ([string]$Type, [string]$Name)

                $countCmd = $connection.CreateCommand()
                $countCmd.Transaction = $transaction

                try {
                    $countCmd.CommandText = @'
SELECT COUNT(*)
FROM sqlite_master
WHERE type = @type
  AND name = @name;
'@
                    $countCmd.Parameters.AddWithValue('@type', $Type) | Out-Null
                    $countCmd.Parameters.AddWithValue('@name', $Name) | Out-Null

                    [int]$countCmd.ExecuteScalar()
                } finally {
                    $countCmd.Dispose()
                }
            }

            $getColumnNames = {
                param (
                    [Parameter()]
                    [string]$TableName
                )

                # PRAGMA table_info does not support parameter binding.
                # TableName is always a hardcoded literal in this function - never
                # external input - so bracket-quoting is a safe identifier escape.
                $pragmaCmd = $connection.CreateCommand()
                $pragmaCmd.Transaction = $transaction

                try {
                    $pragmaCmd.CommandText = "PRAGMA table_info([$TableName]);"

                    $pragmaReader = $pragmaCmd.ExecuteReader()

                    try {
                        $names = [System.Collections.Generic.List[string]]::new()

                        while ($pragmaReader.Read()) {
                            $names.Add([string]$pragmaReader['name'])
                        }

                        $names.ToArray()
                    } finally {
                        $pragmaReader.Dispose()
                    }
                } finally {
                    $pragmaCmd.Dispose()
                }
            }

            $sqlSteps = switch ($currentVersion) {

                # =====================================================================
                # Version 0
                #
                # user_version = 0 means no schema version has been committed yet.
                # This covers two distinct physical states:
                #
                #   (a) Empty database     - no tables or indexes exist.
                #   (b) Partial creation   - some objects were created but the
                #       transaction was interrupted before PRAGMA user_version = 4
                #       and COMMIT could execute.
                #
                # Strategy: inspect sqlite_master to determine the physical state,
                # then act deterministically without assumptions.
                #
                #   Empty → execute the full v4 schema (CREATE TABLE IF NOT EXISTS
                #           is a safe no-op for any object that already exists).
                #
                #   Partial with compatible dfe_document columns → execute the same
                #           full v4 DDL; CREATE TABLE/INDEX IF NOT EXISTS safely
                #           skips already-present objects and creates any that are
                #           missing. No object is dropped or altered.
                #
                #   Partial with incompatible dfe_document (e.g. a v1/v2 table left
                #           with user_version = 0 after a crash before migration) →
                #           fail explicitly. This database cannot be recovered by the
                #           v0 path; it must go through the versioned migration path
                #           (versions 1 or 2), which requires a known user_version.
                #           Silently altering an incompatible table would risk data
                #           loss or schema corruption.
                # =====================================================================
                0 {
                    $documentExists = (& $getObjectCount 'table' 'dfe_document') -eq 1

                    if ($documentExists) {
                        $existingColumns = @(& $getColumnNames 'dfe_document')

                        $missingColumns = @(
                            $v4DocumentColumns |
                                Where-Object { $_ -notin $existingColumns }
                        )

                        if ($missingColumns.Count -gt 0) {
                            $missingColumnList = $missingColumns -join ', '

                            throw [System.InvalidOperationException]::new(
                                "The existing 'dfe_document' table is structurally " +
                                'incompatible with the current schema. Missing required ' +
                                "column(s): $missingColumnList. The database may have " +
                                'been created by an older version of PipeDFe and left ' +
                                'with user_version = 0 after an interrupted migration. ' +
                                'Inspect the database manually and apply the appropriate ' +
                                'versioned migration before continuing.'
                            )
                        }
                    }

                    # Whether the database is empty or partially created with a
                    # compatible dfe_document, executing the full v4 DDL is safe and
                    # idempotent: CREATE TABLE IF NOT EXISTS and CREATE INDEX IF NOT
                    # EXISTS skip objects that already exist and create those that are
                    # missing. The result is always a complete, consistent v4 schema.
                    @(
                        $createCoreSchemaSql
                        $createFiscalSchemaV4Sql
                    )
                }

                # =====================================================================
                # Version 1
                #
                # Upgrade through every remaining migration.
                # =====================================================================
                1 {
                    @(
                        $migrateV1ToV2Sql
                        $migrateV2ToV3Sql
                        $createFiscalSchemaV4Sql
                    )
                }

                # =====================================================================
                # Version 2
                #
                # Add processing state columns, then normalized fiscal schema.
                # =====================================================================
                2 {
                    @(
                        $migrateV2ToV3Sql
                        $createFiscalSchemaV4Sql
                    )
                }

                # =====================================================================
                # Version 3
                #
                # Add normalized NF-e/NFC-e fiscal persistence schema.
                # =====================================================================
                3 {
                    @(
                        $createFiscalSchemaV4Sql
                    )
                }

                # =====================================================================
                # Version 4
                #
                # Current schema. No migration required.
                # =====================================================================
                4 {
                    @()
                }

                default {
                    throw [System.InvalidOperationException]::new(
                        "Unsupported index schema version '$currentVersion'."
                    )
                }
            }

            foreach ($sqlStep in $sqlSteps) {
                if ([string]::IsNullOrWhiteSpace($sqlStep)) {
                    continue
                }

                $command.CommandText = $sqlStep
                $null = $command.ExecuteNonQuery()
            }

            if ($currentVersion -ne 4) {
                $command.CommandText = 'PRAGMA user_version = 4;'
                $null = $command.ExecuteNonQuery()
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
