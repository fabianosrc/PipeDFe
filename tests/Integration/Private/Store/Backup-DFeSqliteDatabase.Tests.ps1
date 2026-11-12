#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Integration tests for Backup-DFeSqliteDatabase.

.DESCRIPTION
Uses real SQLite index and audit databases in an isolated data root.
No production data or SMTP connection is used.

Coverage includes:
  - Creates a consistent index backup and reports its metadata.
  - Backs up audit rows while a WAL-mode source connection is open.
  - Rejects a missing source and does not create an empty database.
  - Refuses to overwrite an existing backup.
  - Refuses the source file as its destination.
  - Rejects a missing destination directory.
  - Does not leave a published backup when the source is not SQLite.
  - Does not leave a temporary file on failure.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseShouldProcessForStateChangingFunctions',
    '',
    Justification = 'Test helpers modify isolated SQLite fixtures.'
)]

param ()

BeforeDiscovery {
    # InModuleScope needs to resolve the PipeDFe module during the Discovery phase,
    # because that's when Context/It are executed to register the test tree. If the
    # module isn't loaded at that point, InModuleScope fails before any BeforeAll or
    # BeforeEach ever runs.
    $moduleRoot = (Get-Item -LiteralPath $PSScriptRoot).Parent.Parent.Parent.Parent.FullName

    $modulePath = Join-Path -Path $moduleRoot -ChildPath 'PipeDFe.psd1'

    Import-Module -Name $modulePath -Force -Global -ErrorAction Stop
}

Describe 'Backup-DFeSqliteDatabase' -Tag 'Integration' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            $Script:PreviousDataRoot = $env:LOCALAPPDATA

            $testId = [guid]::NewGuid().ToString('N')

            $Script:TempRoot = [System.IO.Path]::Combine(
                [System.IO.Path]::GetTempPath(),
                'PipeDFe.Backup.Tests-{0}' -f $testId
            )

            New-Item -ItemType Directory -Path $Script:TempRoot -Force | Out-Null

            $env:LOCALAPPDATA = [System.IO.Path]::Combine(
                $Script:TempRoot,
                'data'
            )

            New-Item -ItemType Directory -Path $env:LOCALAPPDATA -Force | Out-Null

            $Script:BackupDirectory = [System.IO.Path]::Combine(
                $Script:TempRoot,
                'backups'
            )

            New-Item -ItemType Directory -Path $Script:BackupDirectory -Force | Out-Null

            $Script:Cnpj = '12345678000199'

            Initialize-DFeIndex -Cnpj $Script:Cnpj | Out-Null
            Initialize-DFeAudit -Cnpj $Script:Cnpj | Out-Null

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
                $command    = $null

                try {
                    $command = $connection.CreateCommand()
                    $command.CommandText = $Sql

                    foreach ($key in $Parameters.Keys) {
                        $command.Parameters.AddWithValue($key, $Parameters[$key]) | Out-Null
                    }

                    $command.ExecuteScalar()
                } finally {
                    if ($null -ne $command) {
                        $command.Dispose()
                    }

                    $connection.Dispose()
                }
            }
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

        It 'Creates a consistent index backup and reports its metadata' {
            $destination = New-TestBackupPath -Name 'index'

            $params = @{
                Cnpj            = $Script:Cnpj
                Scope           = 'Index'
                DestinationPath = $destination
            }

            $result = Backup-DFeSqliteDatabase @params

            $result.PSTypeNames       | Should -Contain 'PipeDFe.SqliteBackup'
            $result.Cnpj              | Should -Be $Script:Cnpj
            $result.Scope             | Should -Be 'Index'
            $result.DestinationPath   | Should -Be $destination
            $result.IntegrityCheck    | Should -Be 'ok'
            $result.SizeBytes         | Should -BeGreaterThan 0

            (Test-Path -LiteralPath $destination -PathType Leaf) | Should -BeTrue

            $userVersionParams = @{
                Path = $destination
                Sql  = 'PRAGMA user_version;'
            }

            $integrityParams = @{
                Path = $destination
                Sql  = 'PRAGMA integrity_check;'
            }

            [int](Get-TestScalar @userVersionParams)  | Should -Be 6
            [string](Get-TestScalar @integrityParams) | Should -Be 'ok'
        }

        It 'Backs up audit rows while a WAL-mode source connection is open' {
            $sourcePath  = Get-StorePath -Scope Audit -Cnpj $Script:Cnpj
            $source      = Open-SqliteConnection -Path $sourcePath
            $executionId = [guid]::NewGuid().ToString('N')

            try {
                $command = $source.CreateCommand()

                try {
                    $command.CommandText = @'
INSERT INTO audit_execution (
    execution_id, started_at, mode, status
) VALUES (
    @execution_id, '2026-11-09T20:00:00.0000000+00:00', 'Test', 'Running'
);
'@
                    $command.Parameters.AddWithValue('@execution_id', $executionId) | Out-Null
                    $command.ExecuteNonQuery() | Out-Null
                } finally {
                    $command.Dispose()
                }

                $destination = New-TestBackupPath -Name 'audit'

                $params = @{
                    Cnpj            = $Script:Cnpj
                    Scope           = 'Audit'
                    DestinationPath = $destination
                }

                $result = Backup-DFeSqliteDatabase @params

                $result.IntegrityCheck | Should -Be 'ok'

                $userVersionParams = @{
                    Path = $destination
                    Sql  = 'PRAGMA user_version;'
                }

                $countParams = @{
                    Path       = $destination
                    Sql        = 'SELECT COUNT(*) FROM audit_execution WHERE execution_id = @id;'
                    Parameters = @{ '@id' = $executionId }
                }

                [int](Get-TestScalar @userVersionParams) | Should -Be 1
                [int](Get-TestScalar @countParams)       | Should -Be 1
            } finally {
                $source.Dispose()
            }
        }

        It 'Rejects a missing source and does not create an empty database' {
            $missingCnpj = '11111111000191'
            $destination = New-TestBackupPath -Name 'missing'
            $sourcePath  = Get-StorePath -Scope Index -Cnpj $missingCnpj

            $params = @{
                Cnpj            = $missingCnpj
                Scope           = 'Index'
                DestinationPath = $destination
            }

            { Backup-DFeSqliteDatabase @params } | Should -Throw

            (Test-Path -LiteralPath $destination) | Should -BeFalse
            (Test-Path -LiteralPath $sourcePath)  | Should -BeFalse
        }

        It 'Refuses to overwrite an existing backup' {
            $destination = New-TestBackupPath -Name 'existing'

            [System.IO.File]::WriteAllText($destination, 'untouched')

            $params = @{
                Cnpj            = $Script:Cnpj
                Scope           = 'Index'
                DestinationPath = $destination
            }

            { Backup-DFeSqliteDatabase @params } | Should -Throw

            [System.IO.File]::ReadAllText($destination) | Should -Be 'untouched'
        }

        It 'Refuses the source file as its destination' {
            $sourcePath = Get-StorePath -Scope Index -Cnpj $Script:Cnpj

            $params = @{
                Cnpj            = $Script:Cnpj
                Scope           = 'Index'
                DestinationPath = $sourcePath
            }

            { Backup-DFeSqliteDatabase @params } | Should -Throw

            $userVersionParams = @{
                Path = $sourcePath
                Sql  = 'PRAGMA user_version;'
            }

            [int](Get-TestScalar @userVersionParams) | Should -Be 6
        }

        It 'Rejects a missing destination directory' {
            $destination = [System.IO.Path]::Combine(
                $Script:TempRoot,
                'missing-folder',
                'backup.db'
            )

            $params = @{
                Cnpj            = $Script:Cnpj
                Scope           = 'Index'
                DestinationPath = $destination
            }

            { Backup-DFeSqliteDatabase @params } | Should -Throw

            (Test-Path -LiteralPath $destination) | Should -BeFalse
        }

        It 'Does not leave a published backup or temporary file when the source is not SQLite' {
            $corruptCnpj = '22222222000172'
            $sourcePath  = Get-StorePath -Scope Index -Cnpj $corruptCnpj

            New-Item -ItemType Directory -Path (
                [System.IO.Path]::GetDirectoryName($sourcePath)
            ) -Force | Out-Null

            [System.IO.File]::WriteAllText($sourcePath, 'not a SQLite database')

            $destination = New-TestBackupPath -Name 'corrupt'

            $params = @{
                Cnpj            = $corruptCnpj
                Scope           = 'Index'
                DestinationPath = $destination
            }

            { Backup-DFeSqliteDatabase @params } | Should -Throw

            (Test-Path -LiteralPath $destination) | Should -BeFalse

            $tmpParams = @{
                LiteralPath = $Script:BackupDirectory
                Filter      = '*.tmp'
            }

            @(Get-ChildItem @tmpParams) | Should -HaveCount 0
        }
    }
}
