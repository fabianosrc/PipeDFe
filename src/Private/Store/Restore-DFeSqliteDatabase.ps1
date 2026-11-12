
<#
.SYNOPSIS
Restores a validated SQLite backup to a database that does not exist.

.DESCRIPTION
Restores an index or audit database using the SQLite online backup API.

The backup is copied into a unique temporary database in the target
directory. Integrity, foreign keys, schema version and required tables
are verified before the temporary database is published.

Existing destination databases are never replaced. Replacing an active
database requires a separate maintenance workflow.

The function does not initialize a new database schema and does not
modify the source backup.

.PARAMETER Cnpj
Normalized 14-character company CNPJ.

.PARAMETER Scope
The database to restore: Index or Audit.

.PARAMETER BackupPath
Path to an existing SQLite backup file.

.OUTPUTS
PipeDFe.SqliteRestore

.NOTES
Dependencies: Get-StorePath, Open-SqliteConnection.

The SQLite databases do not contain a verified company identity.
The caller must ensure the backup belongs to the intended CNPJ.

Only database contents are restored. External archives and configuration
files are outside the scope of this function.
#>
function Restore-DFeSqliteDatabase {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions',
        '',
        Justification = 'Restoration publishes only a new database file.'
    )]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [ValidatePattern('^(?-i)[A-Z0-9]{14}$')]
        [string]$Cnpj,

        [Parameter(Mandatory)]
        [ValidateSet('Index', 'Audit')]
        [string]$Scope,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$BackupPath
    )

    $storePath  =(Get-StorePath -Scope $Scope -Cnpj $Cnpj)

    $sourcePath = [System.IO.Path]::GetFullPath($BackupPath)

    $targetPath = [System.IO.Path]::GetFullPath($storePath)

    if ($sourcePath.Equals($targetPath,
            [System.StringComparison]::OrdinalIgnoreCase)
    ) {
        throw [System.ArgumentException]::new(
            'Restore source must differ from the destination database.'
        )
    }

    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        throw [System.IO.FileNotFoundException]::new(
            'SQLite backup does not exist.',
            $sourcePath
        )
    }

    if (Test-Path -LiteralPath $targetPath) {
        throw [System.IO.IOException]::new(
            "Destination database already exists: '$targetPath'."
        )
    }

    $targetDirectory = [System.IO.Path]::GetDirectoryName($targetPath)

    $expectedVersion = if ($Scope -eq 'Index') { 6 } else { 1 }

    $requiredTables = if ($Scope -eq 'Index') {
        @(
            'dfe_document'
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

    $temporary = [System.IO.Path]::Combine(
        $targetDirectory,
        '{0}.restore-{1}.tmp' -f (
            [System.IO.Path]::GetFileName($targetPath),
            [guid]::NewGuid().ToString('N')
        )
    )

    $sourceConnection = $null
    $targetConnection = $null
    $checkConnection  = $null
    $command          = $null
    $reader           = $null
    $published        = $false

    try {
        if (-not (Test-Path -LiteralPath $targetDirectory -PathType Container)) {
            New-Item -ItemType Directory -Path $targetDirectory -Force |
                Out-Null
        }

        $sourceConnection = Open-SqliteConnection -Path $sourcePath
        $targetConnection = Open-SqliteConnection -Path $temporary

        $sourceConnection.BackupDatabase(
            $targetConnection,
            'main',
            'main',
            -1,
            $null,
            0
        )

        $targetConnection.Dispose()
        $targetConnection = $null

        $sourceConnection.Dispose()
        $sourceConnection = $null

        $checkConnection = Open-SqliteConnection -Path $temporary
        $command = $checkConnection.CreateCommand()

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
                'SQLite restore failed integrity_check: ' +
                ($integrityRows -join '; ')
            )
        }

        $command.CommandText = 'PRAGMA foreign_key_check;'
        $reader = $command.ExecuteReader()

        if ($reader.Read()) {
            throw [System.IO.InvalidDataException]::new(
                'SQLite restore failed foreign_key_check.'
            )
        }

        $reader.Dispose()
        $reader = $null

        $command.CommandText = 'PRAGMA user_version;'
        $actualVersion = [int]$command.ExecuteScalar()

        if ($actualVersion -ne $expectedVersion) {
            throw [System.IO.InvalidDataException]::new(
                "Unexpected $Scope schema version '$actualVersion'. " +
                "Expected '$expectedVersion'."
            )
        }

        $command.CommandText = @'
SELECT COUNT(*)
FROM sqlite_master
WHERE type = 'table'
  AND name = @table_name;
'@

        $tableParameter = $command.Parameters.Add(
            '@table_name',
            [System.Data.DbType]::String
        )

        foreach ($tableName in $requiredTables) {
            $tableParameter.Value = $tableName

            if ([int]$command.ExecuteScalar() -ne 1) {
                throw [System.IO.InvalidDataException]::new(
                    "Required SQLite table is missing: '$tableName'."
                )
            }
        }

        $command.Dispose()
        $command = $null

        $checkConnection.Dispose()
        $checkConnection = $null

        # File.Move will not overwrite a destination created concurrently.
        [System.IO.File]::Move($temporary, $targetPath)

        $published = $true

        [PSCustomObject]@{
            PSTypeName     = 'PipeDFe.SqliteRestore'
            Cnpj           = $Cnpj
            Scope          = $Scope
            BackupPath     = $sourcePath
            DestinationPath = $targetPath
            SchemaVersion  = $actualVersion
            IntegrityCheck = 'ok'
            SizeBytes      = [long]([System.IO.FileInfo]::new($targetPath).Length)
        }
    } finally {
        if ($null -ne $reader) {
            $reader.Dispose()
        }

        if ($null -ne $command) {
            $command.Dispose()
        }

        if ($null -ne $checkConnection) {
            $checkConnection.Dispose()
        }

        if ($null -ne $targetConnection) {
            $targetConnection.Dispose()
        }

        if ($null -ne $sourceConnection) {
            $sourceConnection.Dispose()
        }

        if (-not $published) {
            foreach ($suffix in @('', '-wal', '-shm')) {
                $candidate = $temporary + $suffix

                if ([System.IO.File]::Exists($candidate)) {
                    try {
                        [System.IO.File]::Delete($candidate)
                    } catch {
                        Write-Warning -Message (
                            "Could not remove temporary SQLite file '$candidate': " +
                            $_.Exception.Message
                        )
                    }
                }
            }
        }
    }
}
