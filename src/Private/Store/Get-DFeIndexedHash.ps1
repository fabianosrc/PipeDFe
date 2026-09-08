<#
.SYNOPSIS
Returns all SHA-256 hashes currently stored in the DFe index for a given CNPJ.

.DESCRIPTION
Reads all non-null SHA-256 hashes indexed for the specified CNPJ across
dfe_document, dfe_evento and dfe_inutilizacao.

Duplicate hashes are removed by SQLite before being returned.

The function is intended for use as a pre-scan filter in
Invoke-DFeXmlScan, where callers can load the results into a
HashSet[string] for O(1) lookup before scanning files on disk.

Returns no output when the index database does not exist or contains
no indexed hashes.

Database access failures are converted to the stable error identifier
IndexedHashesReadFailed.

.PARAMETER Cnpj
14-digit normalized CNPJ identifying the target company index.

.OUTPUTS
System.String

One unique SHA-256 hash string per indexed document/event/inutilization.

.EXAMPLE
PS C:\> $hashes = [System.Collections.Generic.HashSet[string]]::new(
>>    [System.StringComparer]::OrdinalIgnoreCase
>> )

PS C:\> Get-DFeIndexedHash -Cnpj '12345678000199' |
>>      ForEach-Object { $null = $hashes.Add($_) }

.NOTES
Private dependencies:
  Get-StorePath
  Open-SqliteConnection
#>
function Get-DFeIndexedHash {
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [ValidatePattern('^[A-Z0-9]{14}$')]
        [string]$Cnpj
    )

    $databasePath = Get-StorePath -Scope 'Index' -Cnpj $Cnpj

    if (-not (Test-Path -LiteralPath $databasePath -PathType Leaf)) {
        return
    }

    $connection = $null
    $command    = $null
    $reader     = $null

    try {
        $connection = Open-SqliteConnection -Path $databasePath

        $command = $connection.CreateCommand()

        $command.CommandText = @'
SELECT sha256
FROM dfe_document
WHERE sha256 IS NOT NULL

UNION

SELECT sha256
FROM dfe_evento
WHERE sha256 IS NOT NULL

UNION

SELECT sha256
FROM dfe_inutilizacao
WHERE sha256 IS NOT NULL;
'@

        $reader = $command.ExecuteReader()

        while ($reader.Read()) {
            if (-not $reader.IsDBNull(0)) {
                $reader.GetString(0)
            }
        }
    } catch {
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                $_.Exception,
                'IndexedHashesReadFailed',
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
