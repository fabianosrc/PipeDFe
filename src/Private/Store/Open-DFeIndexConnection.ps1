<#
.SYNOPSIS
Opens a ready-to-use SQLite connection to a CNPJ's index database.

.DESCRIPTION
Guarantees the database and schema exist via Initialize-DFeIndex, then
opens and returns a live SQLiteConnection via Open-SqliteConnection.

The caller owns the returned connection and is responsible for disposing
it (use try/finally).

.PARAMETER Cnpj
14-digit normalized CNPJ identifying the company index.

.OUTPUTS
System.Data.SQLite.SQLiteConnection

.EXAMPLE
PS C:\> $connection = Open-DFeIndexConnection -Cnpj '12345678000199'

try {
    # use connection
} finally {
    $connection.Dispose()
}

.NOTES
Private dependencies:
    Initialize-DFeIndex
    Open-SqliteConnection
#>
function Open-DFeIndexConnection {
    [CmdletBinding()]
    [OutputType([System.Data.SQLite.SQLiteConnection])]
    param (
        [Parameter(Mandatory)]
        [ValidatePattern('^\d{14}$')]
        [string]$Cnpj
    )

    $databasePath = Initialize-DFeIndex -Cnpj $Cnpj

    try {
        Open-SqliteConnection -Path $databasePath
    } catch {
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                $_.Exception,
                'IndexConnectionOpenFailed',
                [System.Management.Automation.ErrorCategory]::ConnectionError,
                $databasePath
            )
        )
    }
}
