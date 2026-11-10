
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Integration tests for Restore-DFeSqliteDatabase.

.DESCRIPTION
Verifies safe restoration of new SQLite databases using real backups.

Coverage includes:
  - Restores an index database and its persisted records.
  - Restores an audit database.
  - Rejects an existing destination.
  - Rejects a missing backup.
  - Rejects an invalid SQLite backup.
  - Rejects a backup with an incompatible schema.
  - Rejects the destination database as its own source.

All test data is isolated from production storage.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseShouldProcessForStateChangingFunctions',
    '',
    Justification = 'Test helpers modify isolated SQLite fixtures.'
)]

param ()

BeforeDiscovery {
    # InModuleScope needs to resolve the PipeDFe module during the Discovery phase,
    # because that's when Context/It are executed to register the test tree.
    # If the module isn't loaded at that point, InModuleScope fails before
    # any BeforeAll or BeforeEach ever runs.
    $moduleRoot = (Get-Item -LiteralPath $PSScriptRoot).Parent.Parent.Parent.Parent.FullName

    $modulePath = Join-Path -Path $moduleRoot -ChildPath 'PipeDFe.psd1'

    Import-Module -Name $modulePath -Force -Global -ErrorAction Stop
}

Describe 'Restore-DFeSqliteDatabase' -Tag 'Integration' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            $Script:PreviousDataRoot = $env:LOCALAPPDATA

            $testID = [guid]::NewGuid().ToString('N')

            $Script:TempRoot = [System.IO.Path]::Combine(
                [System.IO.Path]::GetTempPath(),
                'PipeDFe.Restore.Tests-{0}' -f $testID
            )

            New-Item -ItemType Directory -Path $Script:TempRoot -Force |
                Out-Null

            $env:LOCALAPPDATA = [System.IO.Path]::Combine(
                $Script:TempRoot,
                'data'
            )

            New-Item -ItemType Directory -Path $env:LOCALAPPDATA -Force |
                Out-Null

            $Script:BackupDirectory = [System.IO.Path]::Combine(
                $Script:TempRoot,
                'backups'
            )

            New-Item -ItemType Directory -Path $Script:BackupDirectory -Force |
                Out-Null

            $Script:SourceCnpj = '12345678000199'
            $Script:IndexTargetCnpj = '22345678000199'
            $Script:AuditTargetCnpj = '32345678000199'

            Initialize-DFeIndex -Cnpj $Script:SourceCnpj | Out-Null
            Initialize-DFeAudit -Cnpj $Script:SourceCnpj | Out-Null

            function New-TestBackupPath {
                [CmdletBinding()]
                [OutputType([string])]
                param (
                    [Parameter()]
                    [string]$Name = 'backup'
                )

                [System.IO.Path]::Combine(
                    $Script:BackupDirectory,
                    '{0}-{1}.db' -f ($Name, [guid]::NewGuid().ToString('N'))
                )
            }

            function Get-TestScalar {
                [CmdletBinding()]
                [OutputType([object])]
                param (
                    [Parameter(Mandatory)]
                    [string]$Path,

                    [Parameter(Mandatory)]
                    [string]$Sql,

                    [Parameter()]
                    [hashtable]$Parameters = @{}
                )

                $connection = Open-SqliteConnection -Path $Path
                $command = $null

                try {
                    $command = $connection.CreateCommand()
                    $command.CommandText = $Sql

                    foreach ($key in $Parameters.Keys) {
                        $command.Parameters.AddWithValue($key, $Parameters[$key]) |
                            Out-Null
                    }

                    $command.ExecuteScalar()
                } finally {
                    if ($null -ne $command) {
                        $command.Dispose()
                    }

                    $connection.Dispose()
                }
            }

            function Invoke-TestNonQuery {
                [CmdletBinding()]
                [OutputType([void])]
                param (
                    [Parameter(Mandatory)]
                    [string]$Path,

                    [Parameter(Mandatory)]
                    [string]$Sql,

                    [Parameter()]
                    [hashtable]$Parameters = @{}
                )

                $connection = Open-SqliteConnection -Path $Path
                $command = $null

                try {
                    $command = $connection.CreateCommand()
                    $command.CommandText = $Sql

                    foreach ($key in $Parameters.Keys) {
                        $command.Parameters.AddWithValue($key, $Parameters[$key]) |
                            Out-Null
                    }

                    $command.ExecuteNonQuery() | Out-Null
                } finally {
                    if ($null -ne $command) {
                        $command.Dispose()
                    }

                    $connection.Dispose()
                }
            }

            $Script:IndexBackup = New-TestBackupPath -Name 'index'

            $indexBackupParams = @{
                Cnpj            = $Script:SourceCnpj
                Scope           = 'Index'
                DestinationPath = $Script:IndexBackup
            }

            Backup-DFeSqliteDatabase @indexBackupParams | Out-Null

            $Script:AuditExecutionId = [guid]::NewGuid().ToString('N')

            $auditSourcePath = Get-StorePath -Scope Audit -Cnpj $Script:SourceCnpj

            $insertParams = @{
                Path       = $auditSourcePath
                Sql        = @'
INSERT INTO audit_execution (
    execution_id, started_at, mode, status
) VALUES (
    @execution_id, @started_at, @mode, @status
);
'@
                Parameters = @{
                    '@execution_id' = $Script:AuditExecutionId
                    '@started_at'   = '2026-11-09T20:00:00+00:00'
                    '@mode'         = 'Test'
                    '@status'       = 'Running'
                }
            }

            Invoke-TestNonQuery @insertParams

            $Script:AuditBackup = New-TestBackupPath -Name 'audit'

            $auditBackupParams = @{
                Cnpj            = $Script:SourceCnpj
                Scope           = 'Audit'
                DestinationPath = $Script:AuditBackup
            }

            Backup-DFeSqliteDatabase @auditBackupParams | Out-Null
        }

        AfterAll {

            $env:LOCALAPPDATA = $Script:PreviousDataRoot

            $removeItemParams = @{
                LiteralPath = $Script:TempRoot
                Recurse     = $true
                Force       = $true
                ErrorAction = 'SilentlyContinue'
            }

            Remove-Item @removeItemParams
        }

        Context 'Valid restoration' {

            It 'Restores the index schema into a new database' {
                $params = @{
                    Cnpj       = $Script:IndexTargetCnpj
                    Scope      = 'Index'
                    BackupPath = $Script:IndexBackup
                }

                $result = Restore-DFeSqliteDatabase @params

                $result.PSTypeNames    | Should -Contain 'PipeDFe.SqliteRestore'
                $result.Scope          | Should -Be 'Index'
                $result.IntegrityCheck | Should -Be 'ok'
                $result.SchemaVersion  | Should -Be 5
                $result.SizeBytes      | Should -BeGreaterThan 0

                $target = Get-StorePath -Scope Index -Cnpj $Script:IndexTargetCnpj

                (Test-Path -LiteralPath $target -PathType Leaf) |
                    Should -BeTrue

                $queryParams = @{
                    Path = $target
                    Sql  = 'PRAGMA user_version;'
                }

                [int](Get-TestScalar @queryParams) | Should -Be 5
            }

            It 'Restores persisted audit records into a new database' {
                $params = @{
                    Cnpj       = $Script:AuditTargetCnpj
                    Scope      = 'Audit'
                    BackupPath = $Script:AuditBackup
                }

                $result = Restore-DFeSqliteDatabase @params

                $result.IntegrityCheck | Should -Be 'ok'
                $result.SchemaVersion  | Should -Be 1

                $target = Get-StorePath -Scope Audit -Cnpj $Script:AuditTargetCnpj

                $queryParams = @{
                    Path       = $target
                    Sql        = @'
SELECT COUNT(*)
FROM audit_execution
WHERE execution_id = @execution_id;
'@
                    Parameters = @{
                        '@execution_id' = $Script:AuditExecutionId
                    }
                }

                [int](Get-TestScalar @queryParams) | Should -Be 1
            }
        }

        Context 'Destination protection' {

            It 'Rejects restoration over an existing database' {
                $target = Get-StorePath -Scope Index -Cnpj $Script:IndexTargetCnpj

                $params = @{
                    Cnpj       = $Script:IndexTargetCnpj
                    Scope      = 'Index'
                    BackupPath = $Script:IndexBackup
                }

                { Restore-DFeSqliteDatabase @params } | Should -Throw

                $queryParams = @{
                    Path = $target
                    Sql  = 'PRAGMA user_version;'
                }

                [int](Get-TestScalar @queryParams) | Should -Be 5
            }

            It 'Rejects the destination database as its own source' {
                $target = Get-StorePath -Scope Index -Cnpj $Script:IndexTargetCnpj

                $params = @{
                    Cnpj       = $Script:IndexTargetCnpj
                    Scope      = 'Index'
                    BackupPath = $target
                }

                { Restore-DFeSqliteDatabase @params } | Should -Throw
            }
        }

        Context 'Invalid backup protection' {

            It 'Rejects a missing backup without creating a database' {
                $cnpj = '42345678000199'
                $missingBackup = New-TestBackupPath -Name 'missing'

                $params = @{
                    Cnpj       = $cnpj
                    Scope      = 'Index'
                    BackupPath = $missingBackup
                }

                { Restore-DFeSqliteDatabase @params } | Should -Throw

                $target = Get-StorePath -Scope Index -Cnpj $cnpj

                (Test-Path -LiteralPath $target) | Should -BeFalse
            }

            It 'Rejects a corrupt backup without publishing a database' {
                $cnpj = '52345678000199'
                $invalidBackup = New-TestBackupPath -Name 'corrupt'

                [System.IO.File]::WriteAllText(
                    $invalidBackup,
                    'not a SQLite database'
                )

                $params = @{
                    Cnpj       = $cnpj
                    Scope      = 'Index'
                    BackupPath = $invalidBackup
                }

                { Restore-DFeSqliteDatabase @params } | Should -Throw

                $target = Get-StorePath -Scope Index -Cnpj $cnpj

                (Test-Path -LiteralPath $target) | Should -BeFalse

                $targetDirectory = [System.IO.Path]::GetDirectoryName($target)

                $tmpParams = @{
                    LiteralPath = $targetDirectory
                    Filter      = '*.tmp'
                    ErrorAction = 'SilentlyContinue'
                }

                @(Get-ChildItem @tmpParams) | Should -HaveCount 0
            }

            It 'Rejects a backup with an incompatible schema version' {
                $cnpj = '62345678000199'
                $invalidBackup = New-TestBackupPath -Name 'schema'

                $otherParams = @{
                    Cnpj            = $Script:SourceCnpj
                    Scope           = 'Audit'
                    DestinationPath = $invalidBackup
                }

                Backup-DFeSqliteDatabase @otherParams | Out-Null

                $params = @{
                    Cnpj       = $cnpj
                    Scope      = 'Index'
                    BackupPath = $invalidBackup
                }

                { Restore-DFeSqliteDatabase @params } | Should -Throw

                $target = Get-StorePath -Scope Index -Cnpj $cnpj

                (Test-Path -LiteralPath $target) | Should -BeFalse
            }
        }
    }
}
