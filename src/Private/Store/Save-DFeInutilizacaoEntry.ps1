<#
.SYNOPSIS
Persists an Inutilizacao entry in the CNPJ's index.

.DESCRIPTION
Writes or updates a record in dfe_inutilizacao keyed by id_inut.

id_inut is the structured identifier from infInut/@Id, with the format:
cUF + ano + CNPJ + mod + serie + nNFIni + nNFFin. It is deterministic
by definition - reprocessing the same file always produces the same key.

Idempotency rules (evaluated inside an explicit transaction):

  Same id_inut, same sha256     -> no-op.
  Same id_inut, different sha256 -> updates metadata.
  Different id_inut              -> new record.

nnf_ini and nnf_fin are required. A range without valid bounds has no
value for gap analysis and must never silently enter the index.

indexed_at reflects the moment the record was written or updated, not
when the operation was prepared.

The SHA-256 hash is computed before opening the database connection to
keep the transaction as short as possible. File I/O is not performed
inside the transaction.

All timestamps are stored in UTC, ISO 8601 format.

Write failures always throw - never return silently.

.PARAMETER Cnpj
14-digit normalized CNPJ identifying the company index.

.PARAMETER Metadata
An Inutilizacao metadata object as returned by Get-DFeXmlMetadata.
Must satisfy:
  Tipo          = [TipoXmlDFe]::Inutilizacao
  IdInut        non-null, non-empty
  Modelo        non-null
  Serie         non-null, non-empty
  NNFIni        parseable as Int32
  NNFFin        parseable as Int32
  File          non-null
  File.FullName non-null, non-empty, resolvable on disk

.OUTPUTS
None.

.EXAMPLE
PS C:\> $meta = Get-DFeXmlMetadata -Path 'C:\XMLs\procInutNFe.xml'
>> Save-DFeInutilizacaoEntry -Cnpj '12345678000199' -Metadata $meta

.NOTES
Private dependencies:
  Open-DFeIndexConnection
#>
function Save-DFeInutilizacaoEntry {
    [CmdletBinding()]
    [OutputType([void])]
    param (
        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Z0-9]{14}$')]
        [string]$Cnpj,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject]$Metadata
    )

    if ($Metadata.Tipo -ne [TipoXmlDFe]::Inutilizacao) {
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                [System.ArgumentException]::new(
                    "Metadata.Tipo must be 'Inutilizacao', got '$($Metadata.Tipo)'."
                ),
                'InvalidMetadataTipo',
                [System.Management.Automation.ErrorCategory]::InvalidArgument,
                $Metadata
            )
        )
    }

    if ([string]::IsNullOrWhiteSpace($Metadata.IdInut)) {
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                [System.ArgumentException]::new('Metadata.IdInut is required.'),
                'MissingIdInut',
                [System.Management.Automation.ErrorCategory]::InvalidArgument,
                $Metadata
            )
        )
    }

    if ($null -eq $Metadata.Modelo) {
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                [System.ArgumentException]::new('Metadata.Modelo is required.'),
                'MissingModelo',
                [System.Management.Automation.ErrorCategory]::InvalidArgument,
                $Metadata
            )
        )
    }

    if ([string]::IsNullOrWhiteSpace($Metadata.Serie)) {
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                [System.ArgumentException]::new('Metadata.Serie is required.'),
                'MissingSerie',
                [System.Management.Automation.ErrorCategory]::InvalidArgument,
                $Metadata
            )
        )
    }

    if ($null -eq $Metadata.File -or
        [string]::IsNullOrWhiteSpace($Metadata.File.FullName)) {
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                [System.ArgumentException]::new('Metadata.File.FullName is required.'),
                'MissingFilePath',
                [System.Management.Automation.ErrorCategory]::InvalidArgument,
                $Metadata
            )
        )
    }

    # NNFIni/NNFFin are required for gap analysis. Unparseable values must
    # never silently enter the index - throw immediately.
    $nnfIni = 0
    $nnfFin = 0

    if (-not [int]::TryParse($Metadata.NNFIni, [ref]$nnfIni) -or
        -not [int]::TryParse($Metadata.NNFFin, [ref]$nnfFin)) {
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                [System.FormatException]::new(
                    "NNFIni/NNFFin must be numeric. Got NNFIni='$($Metadata.NNFIni)', NNFFin='$($Metadata.NNFFin)'."
                ),
                'InvalidNNFRange',
                [System.Management.Automation.ErrorCategory]::InvalidData,
                $Metadata
            )
        )
    }

    # Compute SHA-256 before opening the connection - file I/O must not
    # happen inside the transaction.
    $fileHashParams = @{
        LiteralPath = $Metadata.File.FullName
        Algorithm   = 'SHA256'
        ErrorAction = 'Stop'
    }

    $incomingSha256 = (Get-FileHash @fileHashParams).Hash

    $connection  = $null
    $transaction = $null

    try {
        $connection  = Open-DFeIndexConnection -Cnpj $Cnpj
        $transaction = $connection.BeginTransaction()

        # Read the current record inside the transaction so the idempotency
        # decision and write operate on the same database state.
        $selectCmd = $connection.CreateCommand()
        $selectCmd.Transaction = $transaction
        $selectCmd.CommandText = @'
SELECT sha256
FROM   dfe_inutilizacao
WHERE  id_inut = @id_inut;
'@
        $selectCmd.Parameters.AddWithValue('@id_inut', $Metadata.IdInut) | Out-Null

        $storedSha256 = $null

        $reader = $selectCmd.ExecuteReader()
        try {
            if ($reader.Read()) {
                $storedSha256 = [string]$reader['sha256']
            }
        } finally {
            $reader.Dispose()
            $selectCmd.Dispose()
        }

        # Same id_inut, same content - no-op; close the transaction cleanly.
        if ($null -ne $storedSha256 -and $storedSha256 -eq $incomingSha256) {
            $transaction.Rollback()
            return
        }

        # New entry or changed content - proceed with upsert.
        # indexed_at is set here to reflect the moment of the actual write.
        $indexedAt = [System.DateTimeOffset]::UtcNow.ToString('o')

        $upsertCmd = $connection.CreateCommand()
        $upsertCmd.Transaction = $transaction
        $upsertCmd.CommandText = @'
INSERT INTO dfe_inutilizacao (
    id_inut, modelo, serie, nnf_ini, nnf_fin, file_path, sha256, indexed_at
) VALUES (
    @id_inut, @modelo, @serie, @nnf_ini, @nnf_fin, @file_path, @sha256, @indexed_at
)
ON CONFLICT (id_inut) DO UPDATE SET
    modelo     = excluded.modelo,
    serie      = excluded.serie,
    nnf_ini    = excluded.nnf_ini,
    nnf_fin    = excluded.nnf_fin,
    file_path  = excluded.file_path,
    sha256     = excluded.sha256,
    indexed_at = excluded.indexed_at;
'@

        $upsertCmd.Parameters.AddWithValue('@id_inut',    $Metadata.IdInut)        | Out-Null
        $upsertCmd.Parameters.AddWithValue('@modelo',     [int]$Metadata.Modelo)   | Out-Null
        $upsertCmd.Parameters.AddWithValue('@serie',      $Metadata.Serie)         | Out-Null
        $upsertCmd.Parameters.AddWithValue('@nnf_ini',    $nnfIni)                 | Out-Null
        $upsertCmd.Parameters.AddWithValue('@nnf_fin',    $nnfFin)                 | Out-Null
        $upsertCmd.Parameters.AddWithValue('@file_path',  $Metadata.File.FullName) | Out-Null
        $upsertCmd.Parameters.AddWithValue('@sha256',     $incomingSha256)         | Out-Null
        $upsertCmd.Parameters.AddWithValue('@indexed_at', $indexedAt)              | Out-Null

        try {
            $upsertCmd.ExecuteNonQuery() | Out-Null
        } finally {
            $upsertCmd.Dispose()
        }

        $transaction.Commit()

    } catch {
        if ($null -ne $transaction) {
            try {
                $transaction.Rollback()
            } catch {
                $null = $_
            }
        }

        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                $_.Exception,
                'InutilizacaoEntrySaveFailed',
                [System.Management.Automation.ErrorCategory]::WriteError,
                $Metadata.IdInut
            )
        )
    } finally {
        if ($null -ne $transaction) {
            $transaction.Dispose()
        }

        if ($null -ne $connection) {
            $connection.Dispose()
        }
    }
}
