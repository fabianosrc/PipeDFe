<#
.SYNOPSIS
Reads fiscal document entries from the index for a given CNPJ.

.DESCRIPTION
Queries dfe_document and returns one object per matching record.

All parameters except -Cnpj are optional. When -StartDate and -EndDate
are both omitted, no period filter is applied and all indexed documents
for the CNPJ are returned. When -Modelo is omitted, documents of every
model are returned. When -ProcessingStatus is omitted, documents in all
processing states are returned.

StartDate and EndDate are converted by ConvertTo-DateTimeOffset before
the database operation. The resulting values are serialized as ISO 8601
round-trip strings in UTC and compared against the dh_emi column.

StartDate and EndDate are inclusive. The supplied values therefore
represent exact instants. For date-only values, the time component
produced by ConvertTo-DateTimeOffset is used as-is.

Modelo is compared as an Int32 parameter.

Returns no output when no records match. An empty result is not an error.

Database and SQL failures are converted to DocumentEntryReadFailed.

.PARAMETER Cnpj
14-character normalized CNPJ identifying the company index.

.PARAMETER StartDate
Optional start of the period filter (inclusive). Accepts any format
supported by ConvertTo-DateTimeOffset.

.PARAMETER EndDate
Optional end of the period filter (inclusive). Accepts any format
supported by ConvertTo-DateTimeOffset.

.PARAMETER Modelo
Optional model filter. When provided, only documents of that model
are returned.

.PARAMETER ProcessingStatus
Optional processing-state filter. When provided, only documents in the
specified persistent processing state are returned.

.OUTPUTS
System.Management.Automation.PSCustomObject

Each object contains:
  [string] - chave_acesso
  [int]    - modelo
  [string] - dh_emi
  [string] - file_path
  [bool]   - is_proc
  [int]    - ndoc
  [string] - serie
  [string] - sha256
  [string] - indexed_at
  [string] - processing_status
  [string] - processing_started_at
  [string] - processed_at
  [string] - processing_error

.EXAMPLE
PS C:\> Get-DFeDocumentEntry -Cnpj '12345678000199'

Returns all indexed documents for the CNPJ.

.EXAMPLE
PS C:\> $params = @{
    Cnpj      = '12345678000199'
    StartDate = '01/08/2026'
    EndDate   = '31/08/2026'
}

PS C:\> Get-DFeDocumentEntry @params

Returns indexed documents whose dh_emi is between the two
normalized instants, inclusively.

.EXAMPLE
PS C:\> $params = @{
     Cnpj   = '12345678000199'
     Modelo = [ModeloDFe]::NFe
}

PS C:\> Get-DFeDocumentEntry @params

Returns only indexed NFe documents for the CNPJ.

.EXAMPLE
PS C:\> $params = @{
    Cnpj             = '12345678000199'
    ProcessingStatus = 'Indexed'
}

PS C:\> Get-DFeDocumentEntry @params

Returns only documents awaiting processing.

.NOTES
Private dependencies:
  Get-StorePath
  Open-SqliteConnection
  ConvertTo-DateTimeOffset
#>
function Get-DFeDocumentEntry {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [ValidatePattern('^(?-i)[A-Z0-9]{14}$')]
        [string]$Cnpj,

        [Parameter()]
        [string]$StartDate,

        [Parameter()]
        [string]$EndDate,

        [Parameter()]
        [ModeloDFe]$Modelo,

        [Parameter()]
        [ValidateSet('Indexed', 'Processing', 'Processed', 'Failed')]
        [string]$ProcessingStatus
    )

    # Date conversion intentionally happens before the database operation.
    # Invalid date input must preserve ConvertTo-DateTimeOffset's error
    # contract instead of being reported as a database read failure.
    $startUtc = $null
    $endUtc   = $null

    if (-not [string]::IsNullOrWhiteSpace($StartDate)) {
        $startUtc = ConvertTo-DateTimeOffset -Value $StartDate
    }

    if (-not [string]::IsNullOrWhiteSpace($EndDate)) {
        $endUtc = ConvertTo-DateTimeOffset -Value $EndDate
    }

    $databasePath = Get-StorePath -Scope 'Index' -Cnpj $Cnpj

    $connection = $null
    $command    = $null
    $reader     = $null

    try {
        $connection = Open-SqliteConnection -Path $databasePath
        $command    = $connection.CreateCommand()

        $conditions = [System.Collections.Generic.List[string]]::new()

        if ($null -ne $startUtc) {
            $conditions.Add('dh_emi >= @startDate')

            $parameter = $command.Parameters.Add(
                '@startDate',
                [System.Data.DbType]::String
            )

            $parameter.Value = $startUtc.ToString('o')
        }

        if ($null -ne $endUtc) {
            $conditions.Add('dh_emi <= @endDate')

            $parameter = $command.Parameters.Add(
                '@endDate',
                [System.Data.DbType]::String
            )

            $parameter.Value = $endUtc.ToString('o')
        }

        if ($PSBoundParameters.ContainsKey('Modelo')) {
            $conditions.Add('modelo = @modelo')

            $parameter = $command.Parameters.Add(
                '@modelo',
                [System.Data.DbType]::Int32
            )

            $parameter.Value = [int]$Modelo
        }

        if ($PSBoundParameters.ContainsKey('ProcessingStatus')) {
            $conditions.Add(
                'processing_status = @processingStatus'
            )

            $parameter = $command.Parameters.Add(
                '@processingStatus',
                [System.Data.DbType]::String
            )

            $parameter.Value = $ProcessingStatus
        }

        $whereClause = if ($conditions.Count -gt 0) {
            "WHERE $($conditions -join ' AND ')"
        } else {
            [string]::Empty
        }

        $command.CommandText = @"
SELECT
    chave_acesso,
    modelo,
    dh_emi,
    file_path,
    is_proc,
    ndoc,
    serie,
    sha256,
    indexed_at,
    processing_status,
    processing_started_at,
    processed_at,
    processing_error
FROM
    dfe_document
$whereClause
ORDER BY
    dh_emi ASC;
"@

        $reader = $command.ExecuteReader()

        while ($reader.Read()) {
            [pscustomobject]@{
                chave_acesso          = $reader.GetString(0)
                modelo                = $reader.GetInt32(1)
                dh_emi                = $reader.GetString(2)
                file_path             = $reader.GetString(3)
                is_proc               = [bool]$reader.GetInt32(4)
                ndoc                  = if ($reader.IsDBNull(5)) { $null } else { $reader.GetInt32(5)  }
                serie                 = if ($reader.IsDBNull(6)) { $null } else { $reader.GetString(6) }
                sha256                = $reader.GetString(7)
                indexed_at            = $reader.GetString(8)
                processing_status     = $reader.GetString(9)
                processing_started_at = if ($reader.IsDBNull(10)) { $null } else { $reader.GetString(10) }
                processed_at          = if ($reader.IsDBNull(11)) { $null } else { $reader.GetString(11) }
                processing_error      = if ($reader.IsDBNull(12)) { $null } else { $reader.GetString(12) }
            }
        }
    } catch {
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                $_.Exception,
                'DocumentEntryReadFailed',
                [System.Management.Automation.ErrorCategory]::ReadError,
                $databasePath
            )
        )
    } finally {
        if ($null -ne $reader) {
            $reader.Dispose()
        }

        if ($null -ne $command) {
            $command.Dispose()
        }

        if ($null -ne $connection) {
            $connection.Dispose()
        }
    }
}
