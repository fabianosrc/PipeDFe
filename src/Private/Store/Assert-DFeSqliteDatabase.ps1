<#
.SYNOPSIS
Validates an existing PipeDFe SQLite database.

.DESCRIPTION
Opens an existing database in read-only mode and verifies its integrity,
foreign key constraints, schema version and required tables.

The function never creates a database or modifies its contents.

.PARAMETER Path
Path to an existing SQLite database.

.PARAMETER Scope
Expected database type: Index or Audit.

.OUTPUTS
PipeDFe.SqliteValidation

.NOTES
Dependencies: System.Data.SQLite.

Validation establishes structural compatibility, not company identity.
#>
function Assert-DFeSqliteDatabase {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(Mandatory)]
        [ValidateSet('Index', 'Audit')]
        [string]$Scope
    )

    $databasePath = [System.IO.Path]::GetFullPath($Path)

    if (-not [System.IO.File]::Exists($databasePath)) {
        throw [System.IO.FileNotFoundException]::new(
            'SQLite database does not exist.',
            $databasePath
        )
    }

    $expectedVersion = if ($Scope -eq 'Index') { 6 } else { 1 }

    $requiredTables = if ($Scope -eq 'Index') {
        @(
            'dfe_document'
            'dfe_evento'
            'dfe_inutilizacao'
            'dfe_nfe'
            'dfe_delivery'
            'dfe_delivery_archive'
            'dfe_delivery_recipient'
            'dfe_nfcom'
            'dfe_nfcom_participante'
            'dfe_nfcom_item'
            'dfe_nfcom_item_ibscbs'
            'dfe_nfcom_total'
        )
    } else {
        @(
            'audit_execution'
            'audit_event'
        )
    }

    $builder             = [System.Data.SQLite.SQLiteConnectionStringBuilder]::new()
    $builder.DataSource  = $databasePath
    $builder.Version     = 3
    $builder.ReadOnly    = $true
    $builder.BusyTimeout = 5000

    $connection = $null
    $command    = $null
    $reader     = $null

    try {
        $connection = [System.Data.SQLite.SQLiteConnection]::new(
            $builder.ConnectionString
        )

        $connection.Open()

        $command = $connection.CreateCommand()

        # Validate the complete SQLite database.
        $command.CommandText = 'PRAGMA integrity_check;'
        $reader = $command.ExecuteReader()

        $integrityRows = [System.Collections.Generic.List[string]]::new()

        while ($reader.Read()) {
            $integrityRows.Add([string]$reader.GetValue(0))
        }

        $reader.Dispose()
        $reader = $null

        if ($integrityRows.Count -ne 1 -or $integrityRows[0] -ne 'ok') {
            throw [System.IO.InvalidDataException]::new(
                'SQLite integrity_check failed: ' +
                ($integrityRows -join '; ')
            )
        }

        # Reject databases containing broken foreign key references.
        $command.CommandText = 'PRAGMA foreign_key_check;'
        $reader = $command.ExecuteReader()

        if ($reader.Read()) {
            throw [System.IO.InvalidDataException]::new(
                'SQLite foreign_key_check failed.'
            )
        }

        $reader.Dispose()
        $reader = $null

        # Validate the expected PipeDFe schema version.
        $command.CommandText = 'PRAGMA user_version;'
        $schemaVersion = [int]$command.ExecuteScalar()

        if ($schemaVersion -ne $expectedVersion) {
            throw [System.IO.InvalidDataException]::new(
                "Unexpected $Scope schema version '$schemaVersion'. " +
                "Expected '$expectedVersion'."
            )
        }

        # Validate the minimum required tables for this database scope.
        $command.CommandText = @'
SELECT COUNT(*)
FROM sqlite_master
WHERE type = 'table'
  AND name = @table_name;
'@

        $command.Parameters.AddWithValue('@table_name', '') | Out-Null

        foreach ($tableName in $requiredTables) {
            $command.Parameters['@table_name'].Value = $tableName

            if ([int]$command.ExecuteScalar() -ne 1) {
                throw [System.IO.InvalidDataException]::new(
                    "Required SQLite table is missing: '$tableName'."
                )
            }
        }

        [PSCustomObject]@{
            PSTypeName     = 'PipeDFe.SqliteValidation'
            Path           = $databasePath
            Scope          = $Scope
            SchemaVersion  = $schemaVersion
            IntegrityCheck = 'ok'
            SizeBytes      = [long]([System.IO.FileInfo]::new($databasePath).Length)
        }
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
