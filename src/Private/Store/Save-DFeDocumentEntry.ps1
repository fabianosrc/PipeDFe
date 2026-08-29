<#
.SYNOPSIS
Persists a Documento entry in the CNPJ's index, applying file preference rules.

.DESCRIPTION
Writes or updates a record in dfe_document keyed by chave_acesso. The record
always represents the best physical file known for that fiscal identity.

Preference rules (evaluated inside an explicit transaction):

  Rule 1 - Proc beats bare:
      Incoming is_proc = 1, stored is_proc = 0 -> replace stored record.

  Rule 2 - Bare never replaces Proc:
      Incoming is_proc = 0, stored is_proc = 1 -> no-op, stored record kept.

  Rule 3 - Same type, same content:
      Incoming sha256 equals stored sha256 -> no-op.

  Rule 4 - Same type, different content:
      Incoming sha256 differs from stored sha256 -> replace stored record.

indexed_at reflects the moment the record was written or updated, not
when the operation was prepared.

Never creates two records for the same chave_acesso.

The SHA-256 hash is computed before opening the database connection to
keep the transaction as short as possible. File I/O is not performed
inside the transaction.

All timestamps are stored in UTC, ISO 8601 format.

Write failures always throw - never return silently.

.PARAMETER Cnpj
14-digit normalized CNPJ identifying the company index.

.PARAMETER Metadata
A Documento metadata object as returned by Get-DFeXmlMetadata.
Must satisfy:
  Tipo          = [TipoXmlDFe]::Documento
  Chave         non-null, non-empty
  Modelo        non-null
  File          non-null
  File.FullName non-null, non-empty, resolvable on disk

.OUTPUTS
None.

.EXAMPLE
PS C:\> $meta = Get-DFeXmlMetadata -Path 'C:\XMLs\nfeProc.xml'
>> Save-DFeDocumentEntry -Cnpj '12345678000199' -Metadata $meta

.NOTES
Private dependencies:
  Open-DFeIndexConnection
#>
function Save-DFeDocumentEntry {
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

    if ($Metadata.Tipo -ne [TipoXmlDFe]::Documento) {
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                [System.ArgumentException]::new(
                    "Metadata.Tipo must be 'Documento', got '$($Metadata.Tipo)'."
                ),
                'InvalidMetadataTipo',
                [System.Management.Automation.ErrorCategory]::InvalidArgument,
                $Metadata
            )
        )
    }

    if ([string]::IsNullOrWhiteSpace($Metadata.Chave)) {
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                [System.ArgumentException]::new('Metadata.Chave is required.'),
                'MissingChave',
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

    if ($null -eq $Metadata.File -or [string]::IsNullOrWhiteSpace($Metadata.File.FullName)) {
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                [System.ArgumentException]::new('Metadata.File.FullName is required.'),
                'MissingFilePath',
                [System.Management.Automation.ErrorCategory]::InvalidArgument,
                $Metadata
            )
        )
    }

    # Compute SHA-256 before opening the connection - file I/O must not
    # happen inside the transaction.
    $hashParams = @{
        LiteralPath = $Metadata.File.FullName
        Algorithm   = 'SHA256'
        ErrorAction = 'Stop'
    }

    $incomingIsProc = [int][bool]$Metadata.IsProc
    $incomingSha256 = (Get-FileHash @hashParams).Hash

    $ndoc = if ($null -eq $Metadata.Ndoc -or
        [string]::IsNullOrWhiteSpace([string]$Metadata.Ndoc)) {
        [System.DBNull]::Value
    } else {
        [int]$Metadata.Ndoc
    }

    $serie = if ([string]::IsNullOrWhiteSpace($Metadata.Serie)) {
        [System.DBNull]::Value
    } else {
        $Metadata.Serie
    }

    # TODO: remove conversion once Get-DFeXmlMetadata normalizes DhEmi to UTC.
    $dhEmi = if ([string]::IsNullOrWhiteSpace($Metadata.DhEmi)) {
        [System.DBNull]::Value
    } else {
        [System.DateTimeOffset]::Parse($Metadata.DhEmi).ToUniversalTime().ToString('o')
    }

    $connection  = $null
    $transaction = $null

    try {
        $connection  = Open-DFeIndexConnection -Cnpj $Cnpj
        $transaction = $connection.BeginTransaction()

        # Read the current record inside the transaction so the preference
        # decision and the subsequent write use the same database snapshot.
        $selectCmd = $connection.CreateCommand()

        $selectCmd.Transaction = $transaction
        $selectCmd.CommandText = @'
SELECT is_proc, sha256
FROM dfe_document
WHERE chave_acesso = @chave;
'@

        $selectCmd.Parameters.AddWithValue('@chave', $Metadata.Chave) | Out-Null

        $storedIsProc = $null
        $storedSha256 = $null

        $reader = $selectCmd.ExecuteReader()
        try {
            if ($reader.Read()) {
                $storedIsProc = [int]$reader['is_proc']
                $storedSha256 = [string]$reader['sha256']
            }
        } finally {
            $reader.Dispose()
            $selectCmd.Dispose()
        }

        # Rule 2: bare never replaces Proc.
        if ($null -ne $storedIsProc -and
            $incomingIsProc -eq 0 -and $storedIsProc -eq 1)
        {
            $transaction.Rollback()
            return
        }

        # Rule 3: same type, same content.
        if ($null -ne $storedIsProc -and
            $incomingIsProc -eq $storedIsProc -and
            $incomingSha256 -eq $storedSha256)
        {
            $transaction.Rollback()
            return
        }

        # Rule 1 and Rule 4: proceed with upsert.
        # indexed_at is set here to reflect the moment of the actual write.
        $indexedAt = [System.DateTimeOffset]::UtcNow.ToString('o')
        $upsertCmd = $connection.CreateCommand()
        $upsertCmd.Transaction = $transaction
        $upsertCmd.CommandText = @'
INSERT INTO dfe_document (
    chave_acesso, modelo, file_path, is_proc, ndoc, serie, dh_emi, sha256, indexed_at
) VALUES (
    @chave, @modelo, @file_path, @is_proc, @ndoc, @serie, @dh_emi, @sha256, @indexed_at
)
ON CONFLICT (chave_acesso) DO UPDATE SET
    modelo     = excluded.modelo,
    file_path  = excluded.file_path,
    is_proc    = excluded.is_proc,
    ndoc       = excluded.ndoc,
    serie      = excluded.serie,
    dh_emi     = excluded.dh_emi,
    sha256     = excluded.sha256,
    indexed_at = excluded.indexed_at;
'@

        $upsertCmd.Parameters.AddWithValue('@chave',      $Metadata.Chave)         | Out-Null
        $upsertCmd.Parameters.AddWithValue('@modelo',     [int]$Metadata.Modelo)   | Out-Null
        $upsertCmd.Parameters.AddWithValue('@file_path',  $Metadata.File.FullName) | Out-Null
        $upsertCmd.Parameters.AddWithValue('@is_proc',    $incomingIsProc)         | Out-Null
        $upsertCmd.Parameters.AddWithValue('@ndoc',       $ndoc)                   | Out-Null
        $upsertCmd.Parameters.AddWithValue('@serie',      $serie)                  | Out-Null
        $upsertCmd.Parameters.AddWithValue('@dh_emi',     $dhEmi)                  | Out-Null
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
                'DocumentEntrySaveFailed',
                [System.Management.Automation.ErrorCategory]::WriteError,
                $Metadata.Chave
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
