<#
.SYNOPSIS
Replaces an existing PipeDFe SQLite database from a validated backup.

.DESCRIPTION
Validates the supplied backup, acquires the PipeDFe execution lock and
creates a recovery backup of the existing database before replacing it.

Uses the SQLite online backup API for both replacement and recovery.
No database files or WAL companions are manually replaced or deleted.

The recovery backup is retained after success or failure.

The execution lock coordinates with Invoke-PipeDFe. External SQLite
clients that do not honor this mutex must be stopped separately.

.PARAMETER Cnpj
Normalized company CNPJ.

.PARAMETER Scope
Database type: Index or Audit.

.PARAMETER BackupPath
Existing database backup to restore.

.OUTPUTS
PipeDFe.SqliteReplacement

.NOTES
Dependencies:
  Get-StorePath
  Assert-DFeSqliteDatabase
  Backup-DFeSqliteDatabase
  Open-SqliteConnection
  Enter-PipeDFeExecutionLock
  Exit-PipeDFeExecutionLock

The caller must verify that the backup belongs to the intended CNPJ.
#>
function Set-DFeSqliteDatabase {
    [CmdletBinding(
        SupportsShouldProcess = $true,
        ConfirmImpact = 'High'
    )]
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

    $storePath  = (Get-StorePath -Scope $Scope -Cnpj $Cnpj)

    $sourcePath = [System.IO.Path]::GetFullPath($BackupPath)

    $targetPath = [System.IO.Path]::GetFullPath($storePath)

    if ($sourcePath.Equals($targetPath,
            [System.StringComparison]::OrdinalIgnoreCase)
    ) {
        throw [System.ArgumentException]::new(
            'Restore source must differ from the destination database.'
        )
    }

    if (-not [System.IO.File]::Exists($sourcePath)) {
        throw [System.IO.FileNotFoundException]::new(
            'SQLite backup does not exist.',
            $sourcePath
        )
    }

    if (-not [System.IO.File]::Exists($targetPath)) {
        throw [System.IO.FileNotFoundException]::new(
            'Destination database does not exist. Use Restore-DFeSqliteDatabase.',
            $targetPath
        )
    }

    $action = 'Replace existing {0} SQLite database from backup' -f $Scope

    if (-not $PSCmdlet.ShouldProcess($targetPath, $action)) {
        return
    }

    $executionLock      = $null
    $recoveryPath       = $null
    $replacementStarted = $false

    try {
        $executionLock = Enter-PipeDFeExecutionLock

        # Validate under the execution lock, before changing the target.
        Assert-DFeSqliteDatabase -Path $sourcePath -Scope $Scope |
            Out-Null

        # Keep the recovery backup in the same company data directory.
        $targetDirectory = [System.IO.Path]::GetDirectoryName($targetPath)

        $recoveryPath = [System.IO.Path]::Combine(
            $targetDirectory,
            '{0}.recovery-{1}.db' -f (
                [System.IO.Path]::GetFileName($targetPath),
                [guid]::NewGuid().ToString('N')
            )
        )

        $backupParams = @{
            Cnpj            = $Cnpj
            Scope           = $Scope
            DestinationPath = $recoveryPath
        }

        Backup-DFeSqliteDatabase @backupParams | Out-Null

        # Verify the recovery backup before proceeding with replacement.
        Assert-DFeSqliteDatabase -Path $recoveryPath -Scope $Scope |
            Out-Null

        $sourceConnection = $null
        $targetConnection = $null

        try {
            $sourceConnection = Open-SqliteConnection -Path $sourcePath
            $targetConnection = Open-SqliteConnection -Path $targetPath

            $replacementStarted = $true

            $sourceConnection.BackupDatabase(
                $targetConnection,
                'main',
                'main',
                -1,
                $null,
                0
            )
        } finally {
            if ($null -ne $targetConnection) {
                $targetConnection.Dispose()
            }

            if ($null -ne $sourceConnection) {
                $sourceConnection.Dispose()
            }
        }

        # Validate the replaced destination, not just the source backup.
        $validation = Assert-DFeSqliteDatabase -Path $targetPath -Scope $Scope

        [PSCustomObject]@{
            PSTypeName      = 'PipeDFe.SqliteReplacement'
            Cnpj            = $Cnpj
            Scope           = $Scope
            BackupPath      = $sourcePath
            DestinationPath = $targetPath
            RecoveryPath    = $recoveryPath
            SchemaVersion   = $validation.SchemaVersion
            IntegrityCheck  = $validation.IntegrityCheck
        }
    } catch {
        $originalError = $_

        if ($replacementStarted -and
            -not [string]::IsNullOrWhiteSpace($recoveryPath) -and
            [System.IO.File]::Exists($recoveryPath)
        ) {
            $recoverySource = $null
            $recoveryTarget = $null

            try {
                $recoverySource = Open-SqliteConnection -Path $recoveryPath
                $recoveryTarget = Open-SqliteConnection -Path $targetPath

                $recoverySource.BackupDatabase(
                    $recoveryTarget,
                    'main',
                    'main',
                    -1,
                    $null,
                    0
                )
            } catch {
                throw [System.InvalidOperationException]::new(
                    (
                        'SQLite replacement failed and automatic recovery ' +
                        'also failed. Original error: {0}. Recovery error: {1}. ' +
                        'Recovery backup: {2}'
                    ) -f (
                        $originalError.Exception.Message,
                        $_.Exception.Message,
                        $recoveryPath
                    ),
                    $originalError.Exception
                )
            } finally {
                if ($null -ne $recoveryTarget) {
                    $recoveryTarget.Dispose()
                }

                if ($null -ne $recoverySource) {
                    $recoverySource.Dispose()
                }
            }

            # Confirm that automatic recovery produced a valid database.
            try {
                Assert-DFeSqliteDatabase -Path $targetPath -Scope $Scope |
                    Out-Null
            } catch {
                throw [System.InvalidOperationException]::new(
                    (
                        'SQLite replacement failed. Recovery was attempted ' +
                        'but validation failed: {0}. Recovery backup: {1}'
                    ) -f ($_.Exception.Message, $recoveryPath),
                    $originalError.Exception
                )
            }
        }

        throw $originalError
    } finally {
        if ($null -ne $executionLock) {
            Exit-PipeDFeExecutionLock -Lock $executionLock
        }
    }
}
