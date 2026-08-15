<#
.SYNOPSIS
Persists an Evento entry in the CNPJ's index.

.DESCRIPTION
Writes or updates a record in dfe_evento keyed by (chave_pai, file_path).

Identity is (chave_pai, file_path). Different file_path values therefore
represent distinct physical evento records, even when chave_pai is the same.
There is no Proc/bare priority rule for eventos.

Idempotency rules (evaluated inside an explicit transaction):

  Same (chave_pai, file_path), same sha256     -> no-op.
  Same (chave_pai, file_path), different sha256 -> updates metadata.

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
An Evento metadata object as returned by Get-DFeXmlMetadata.
Must satisfy:
  Tipo          = [TipoXmlDFe]::Evento
  ChavePai      non-null, non-empty
  File          non-null
  File.FullName non-null, non-empty, resolvable on disk

.OUTPUTS
None.

.EXAMPLE
PS C:\> $meta = Get-DFeXmlMetadata -Path 'C:\XMLs\procEventoNFe.xml'
>> Save-DFeEventoEntry -Cnpj '12345678000199' -Metadata $meta

.NOTES
Private dependencies:
  Open-DFeIndexConnection
#>
function Save-DFeEventoEntry {
    [CmdletBinding()]
    [OutputType([void])]
    param (
        [Parameter(Mandatory)]
        [ValidatePattern('^\d{14}$')]
        [string]$Cnpj,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject]$Metadata
    )

    if ($Metadata.Tipo -ne [TipoXmlDFe]::Evento) {
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                [System.ArgumentException]::new(
                    "Metadata.Tipo must be 'Evento', got '$($Metadata.Tipo)'."
                ),
                'InvalidMetadataTipo',
                [System.Management.Automation.ErrorCategory]::InvalidArgument,
                $Metadata
            )
        )
    }

    if ([string]::IsNullOrWhiteSpace($Metadata.ChavePai)) {
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                [System.ArgumentException]::new(
                    'Metadata.ChavePai is required.'
                ),
                'MissingChavePai',
                [System.Management.Automation.ErrorCategory]::InvalidArgument,
                $Metadata
            )
        )
    }

    if ($null -eq $Metadata.File -or
        [string]::IsNullOrWhiteSpace($Metadata.File.FullName)) {
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                [System.ArgumentException]::new(
                    'Metadata.File.FullName is required.'
                ),
                'MissingFilePath',
                [System.Management.Automation.ErrorCategory]::InvalidArgument,
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
    $filePath = $Metadata.File.FullName

    # EventoTipo is a [DFeEvento] enum - .ToString() produces the named value.
    $eventoTipo = if ($null -eq $Metadata.EventoTipo) {
        [System.DBNull]::Value
    } else {
        $Metadata.EventoTipo.ToString()
    }

    # TODO: remove conversion once Get-DFeXmlMetadata normalizes DhEmi to UTC.
    $dhEmi = if ([string]::IsNullOrWhiteSpace($Metadata.DhEmi)) {
        [System.DBNull]::Value
    } else {
        [System.DateTimeOffset]::Parse(
            $Metadata.DhEmi
        ).ToUniversalTime().ToString('o')
    }

    $connection = $null
    $transaction = $null

    try {
        # Keep connection opening inside the outer try so connection
        # failures are normalized to EventoEntrySaveFailed as well.
        $connection = Open-DFeIndexConnection -Cnpj $Cnpj
        $transaction = $connection.BeginTransaction()

        # Read the current record inside the transaction so the idempotency
        # decision and write operate on the same database state.
        $selectCmd = $connection.CreateCommand()
        $selectCmd.Transaction = $transaction
        $selectCmd.CommandText = @'
SELECT sha256
FROM   dfe_evento
WHERE  chave_pai = @chave_pai
AND    file_path = @file_path;
'@
        $selectCmd.Parameters.AddWithValue('@chave_pai', $Metadata.ChavePai) | Out-Null
        $selectCmd.Parameters.AddWithValue('@file_path', $filePath)          | Out-Null

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

        # Same file, same content - no-op; close the transaction cleanly.
        if ($null -ne $storedSha256 -and $storedSha256 -eq $incomingSha256) {
            $transaction.Rollback()
            return
        }

        # New file or changed content - proceed with upsert.
        # indexed_at is set here to reflect the moment of the actual write.
        $indexedAt = [System.DateTimeOffset]::UtcNow.ToString('o')

        $upsertCmd = $connection.CreateCommand()
        $upsertCmd.Transaction = $transaction
        $upsertCmd.CommandText = @'
INSERT INTO dfe_evento (
    chave_pai, file_path, evento_tipo, dh_emi, sha256, indexed_at
) VALUES (
    @chave_pai, @file_path, @evento_tipo, @dh_emi, @sha256, @indexed_at
)
ON CONFLICT (chave_pai, file_path) DO UPDATE SET
    evento_tipo = excluded.evento_tipo,
    dh_emi      = excluded.dh_emi,
    sha256      = excluded.sha256,
    indexed_at  = excluded.indexed_at;
'@

        $upsertCmd.Parameters.AddWithValue('@chave_pai', $Metadata.ChavePai) | Out-Null
        $upsertCmd.Parameters.AddWithValue('@file_path', $filePath)          | Out-Null
        $upsertCmd.Parameters.AddWithValue('@evento_tipo', $eventoTipo)      | Out-Null
        $upsertCmd.Parameters.AddWithValue('@dh_emi', $dhEmi)                | Out-Null
        $upsertCmd.Parameters.AddWithValue('@sha256', $incomingSha256)       | Out-Null
        $upsertCmd.Parameters.AddWithValue('@indexed_at', $indexedAt)        | Out-Null

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
                'EventoEntrySaveFailed',
                [System.Management.Automation.ErrorCategory]::WriteError,
                $Metadata.ChavePai
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
