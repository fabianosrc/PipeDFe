<#
.SYNOPSIS
Creates a validated SQLite backup for a company's index or audit database.

.DESCRIPTION
Uses SQLite's online backup API rather than copying a live database file.
A unique temporary database is created in the destination directory. After
SQLite integrity_check and foreign_key_check succeed, the temporary file is
moved to the requested destination. Existing backups are never overwritten.

The source database must already exist. This function never initializes an
empty source database and does not modify production database contents.

.PARAMETER Cnpj
Normalized 14-character company CNPJ.

.PARAMETER Scope
The database to back up: Index or Audit.

.PARAMETER DestinationPath
New backup file path. Its parent directory must already exist.

.OUTPUTS
PipeDFe.SqliteBackup

.NOTES
Dependencies: Get-StorePath, Open-SqliteConnection.
#>
function Backup-DFeSqliteDatabase {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions',
        '',
        Justification = 'Backup creation is controlled by the maintenance workflow.'
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
        [string]$DestinationPath
    )

    $storePath  = (Get-StorePath -Scope $Scope -Cnpj $Cnpj)

    $sourcePath = [System.IO.Path]::GetFullPath($storePath)

    $destination = [System.IO.Path]::GetFullPath($DestinationPath)

    $destinationDirectory = [System.IO.Path]::GetDirectoryName($destination)

    if ($sourcePath.Equals($destination, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw [System.ArgumentException]::new(
            'Backup destination must differ from the source database.'
        )
    }

    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        throw [System.IO.FileNotFoundException]::new(
            'Source SQLite database does not exist.',
            $sourcePath
        )
    }

    if (-not (Test-Path -LiteralPath $destinationDirectory -PathType Container)) {
        throw [System.IO.DirectoryNotFoundException]::new(
            "Backup directory does not exist: '$destinationDirectory'."
        )
    }

    if (Test-Path -LiteralPath $destination) {
        throw [System.IO.IOException]::new(
            "Backup destination already exists: '$destination'."
        )
    }

    $temporary = [System.IO.Path]::Combine(
        $destinationDirectory,
        '{0}.backup-{1}.tmp' -f (
            [System.IO.Path]::GetFileName($destination),
            [guid]::NewGuid().ToString('N')
        )
    )

    $sourceConnection      = $null
    $destinationConnection = $null
    $checkConnection       = $null
    $checkCommand          = $null
    $checkReader           = $null
    $published             = $false
    $integrityResult       = $null

    try {
        $sourceConnection      = Open-SqliteConnection -Path $sourcePath
        $destinationConnection = Open-SqliteConnection -Path $temporary

        $sourceConnection.BackupDatabase(
            $destinationConnection,
            'main',
            'main',
            -1,
            $null,
            0
        )

        $destinationConnection.Dispose()
        $destinationConnection = $null

        $sourceConnection.Dispose()
        $sourceConnection = $null

        $checkConnection = Open-SqliteConnection -Path $temporary
        $checkCommand    = $checkConnection.CreateCommand()
        $checkCommand.CommandText = 'PRAGMA integrity_check;'

        $checkReader   = $checkCommand.ExecuteReader()
        $integrityRows = [System.Collections.Generic.List[string]]::new()

        while ($checkReader.Read()) {
            $integrityRows.Add([string]$checkReader.GetValue(0))
        }

        $checkReader.Dispose()
        $checkReader = $null

        if ($integrityRows.Count -ne 1 -or $integrityRows[0] -ne 'ok') {
            throw [System.IO.InvalidDataException]::new(
                'SQLite backup failed integrity_check: ' +
                ($integrityRows -join '; ')
            )
        }

        $integrityResult = $integrityRows[0]
        $checkCommand.CommandText = 'PRAGMA foreign_key_check;'
        $checkReader = $checkCommand.ExecuteReader()

        if ($checkReader.Read()) {
            throw [System.IO.InvalidDataException]::new(
                'SQLite backup failed foreign_key_check.'
            )
        }

        $checkReader.Dispose()
        $checkReader = $null

        $checkCommand.Dispose()
        $checkCommand = $null

        $checkConnection.Dispose()
        $checkConnection = $null

        # No overwrite: File.Move fails if a concurrent operation created
        # the destination after the initial existence check.
        [System.IO.File]::Move($temporary, $destination)
        $published = $true

        [PSCustomObject]@{
            PSTypeName      = 'PipeDFe.SqliteBackup'
            Cnpj            = $Cnpj
            Scope           = $Scope
            SourcePath      = $sourcePath
            DestinationPath = $destination
            IntegrityCheck  = $integrityResult
            SizeBytes       = [long]([System.IO.FileInfo]::new($destination).Length)
        }
    } finally {
        if ($null -ne $checkReader) {
            $checkReader.Dispose()
        }

        if ($null -ne $checkCommand) {
            $checkCommand.Dispose()
        }

        if ($null -ne $checkConnection) {
            $checkConnection.Dispose()
        }

        if ($null -ne $destinationConnection) {
            $destinationConnection.Dispose()
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
                            "Could not remove temporary SQLite backup file '$candidate': " +
                            $_.Exception.Message
                        )
                    }
                }
            }
        }
    }
}
