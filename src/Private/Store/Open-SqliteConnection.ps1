<#
.SYNOPSIS
Opens a SQLite connection to the specified database file.

.DESCRIPTION
Creates and opens a live System.Data.SQLite.SQLiteConnection for the
specified database path.
The caller owns the returned connection and is responsible for disposing
it when it is no longer needed.

.PARAMETER Path
Full or relative path to the SQLite database file.

.OUTPUTS
System.Data.SQLite.SQLiteConnection

.EXAMPLE
PS C:\> $connection = Open-SqliteConnection -Path 'C:\data\index.db'
#>
function Open-SqliteConnection {
    [CmdletBinding()]
    [OutputType([System.Data.SQLite.SQLiteConnection])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    $connection   = $null
    $databasePath = $null

    try {
        # Normalize the path without requiring the database file to exist.
        # SQLite may legitimately create a new database file.
        $databasePath = [System.IO.Path]::GetFullPath($Path)

        $builder            = [System.Data.SQLite.SQLiteConnectionStringBuilder]::new()
        $builder.DataSource = $databasePath
        $builder.Version    = 3

        $connectionString   = $builder.ConnectionString

        $connection = [System.Data.SQLite.SQLiteConnection]::new($connectionString)

        $connection.Open()

        $connection
    } catch {
        if ($null -ne $connection) {
            $connection.Dispose()
            $connection = $null
        }

        $target = if ($null -ne $databasePath) {
            $databasePath
        } else {
            $Path
        }

        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                $_.Exception,
                'SqliteConnectionFailed',
                [System.Management.Automation.ErrorCategory]::ConnectionError,
                $target
            )
        )
    }
}
