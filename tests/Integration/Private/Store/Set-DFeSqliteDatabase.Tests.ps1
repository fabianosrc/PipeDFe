#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Integration tests for Set-DFeSqliteDatabase.

.DESCRIPTION
Verifies controlled replacement of existing SQLite databases.

Coverage includes:
  - Replaces an audit database with a validated backup.
  - Preserves the previous database in a recovery backup.
  - Replaces an index database.
  - Rejects invalid backups without changing the destination.
  - Rejects missing destination databases.
  - Respects the execution mutex.
  - Supports WhatIf without changing the destination.

All databases are isolated from production storage.
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

Describe 'Set-DFeSqliteDatabase' -Tag 'Integration' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            $Script:OriginalLocalAppData = $env:LOCALAPPDATA

            $testID = [guid]::NewGuid().ToString('N')

            $Script:TempRoot = [System.IO.Path]::Combine(
                [System.IO.Path]::GetTempPath(),
                'PipeDFe.Set-DFeSqliteDatabase.Tests-{0}' -f $testID
            )

            New-Item -Path $Script:TempRoot -ItemType Directory -Force |
                Out-Null

            $env:LOCALAPPDATA = $Script:TempRoot

            $Script:BackupDirectory = [System.IO.Path]::Combine(
                $Script:TempRoot,
                'backups'
            )

            New-Item -Path $Script:BackupDirectory -ItemType Directory -Force |
                Out-Null

            $Script:SourceCnpj = '12345678000199'

            $Script:SourceAuditPath = Initialize-DFeAudit -Cnpj $Script:SourceCnpj
            $Script:SourceIndexPath = Initialize-DFeIndex -Cnpj $Script:SourceCnpj

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
                $command    = $null

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

            function Add-TestAuditExecution {
                [CmdletBinding()]
                [OutputType([void])]
                param (
                    [Parameter(Mandatory)]
                    [string]$Path,

                    [Parameter(Mandatory)]
                    [string]$ExecutionId
                )

                $insertParams = @{
                    Path       = $Path
                    Sql        = @'
INSERT INTO audit_execution (
    execution_id,
    started_at,
    mode,
    status
) VALUES (
    @execution_id,
    @started_at,
    @mode,
    @status
);
'@
                    Parameters = @{
                        '@execution_id' = $ExecutionId
                        '@started_at'   = '2026-11-09T20:00:00+00:00'
                        '@mode'         = 'Test'
                        '@status'       = 'Running'
                    }
                }

                Invoke-TestNonQuery @insertParams
            }

            function Get-TestAuditExecutionCount {
                [CmdletBinding()]
                [OutputType([int])]
                param (
                    [Parameter(Mandatory)]
                    [string]$Path,

                    [Parameter(Mandatory)]
                    [string]$ExecutionId
                )

                $queryParams = @{
                    Path       = $Path
                    Sql        = @'
SELECT COUNT(*)
FROM audit_execution
WHERE execution_id = @execution_id;
'@
                    Parameters = @{
                        '@execution_id' = $ExecutionId
                    }
                }

                [int](Get-TestScalar @queryParams)
            }

            function New-TestBackupPath {
                [CmdletBinding()]
                [OutputType([string])]
                param (
                    [Parameter()]
                    [string]$Name = 'backup'
                )

                [System.IO.Path]::Combine(
                    $Script:BackupDirectory,
                    '{0}-{1}.db' -f ($Name, [guid]::NewGuid().ToString('N')
                    )
                )
            }

            $Script:SourceExecutionId = [guid]::NewGuid().ToString('N')

            $testAuditExecutionParams = @{
                Path        = $Script:SourceAuditPath
                ExecutionId = $Script:SourceExecutionId

            }

            Add-TestAuditExecution @testAuditExecutionParams

            $Script:AuditBackupPath = New-TestBackupPath -Name 'audit'

            $auditBackupParams = @{
                Cnpj            = $Script:SourceCnpj
                Scope           = 'Audit'
                DestinationPath = $Script:AuditBackupPath
            }

            Backup-DFeSqliteDatabase @auditBackupParams | Out-Null

            $Script:IndexBackupPath = New-TestBackupPath -Name 'index'

            $indexBackupParams = @{
                Cnpj            = $Script:SourceCnpj
                Scope           = 'Index'
                DestinationPath = $Script:IndexBackupPath
            }

            Backup-DFeSqliteDatabase @indexBackupParams | Out-Null
        }

        AfterAll {

            $env:LOCALAPPDATA = $Script:OriginalLocalAppData

            $removeItemParams = @{
                LiteralPath = $Script:TempRoot
                Recurse     = $true
                Force       = $true
                ErrorAction = 'SilentlyContinue'
            }

            Remove-Item @removeItemParams
        }

        Context 'Successful replacement' {

            It 'Replaces audit data and preserves the previous database' {
                $cnpj       = '22345678000199'
                $target     = Initialize-DFeAudit -Cnpj $cnpj
                $originalId = [guid]::NewGuid().ToString('N')

                Add-TestAuditExecution -Path $target -ExecutionId $originalId

                $params = @{
                    Cnpj       = $cnpj
                    Scope      = 'Audit'
                    BackupPath = $Script:AuditBackupPath
                    Confirm    = $false
                }

                $result = Set-DFeSqliteDatabase @params

                $result.PSTypeNames |
                    Should -Contain 'PipeDFe.SqliteReplacement'

                $result.Cnpj           | Should -Be $cnpj
                $result.Scope          | Should -Be 'Audit'
                $result.SchemaVersion  | Should -Be 1
                $result.IntegrityCheck | Should -Be 'ok'

                (Test-Path -LiteralPath $result.RecoveryPath -PathType Leaf) |
                    Should -BeTrue

                $sourceCountParams = @{
                    Path        = $target
                    ExecutionId = $Script:SourceExecutionId
                }

                $originalCountParams = @{
                    Path        = $target
                    ExecutionId = $originalId
                }

                $recoverySourceCountParams = @{
                    Path        = $result.RecoveryPath
                    ExecutionId = $Script:SourceExecutionId
                }

                $recoveryOriginalCountParams = @{
                    Path        = $result.RecoveryPath
                    ExecutionId = $originalId
                }

                (Get-TestAuditExecutionCount @sourceCountParams)           | Should -Be 1
                (Get-TestAuditExecutionCount @originalCountParams)         | Should -Be 0
                (Get-TestAuditExecutionCount @recoveryOriginalCountParams) | Should -Be 1
                (Get-TestAuditExecutionCount @recoverySourceCountParams)   | Should -Be 0
            }

            It 'Replaces an existing index database' {
                $cnpj   = '32345678000199'
                $target = Initialize-DFeIndex -Cnpj $cnpj

                $params = @{
                    Cnpj       = $cnpj
                    Scope      = 'Index'
                    BackupPath = $Script:IndexBackupPath
                    Confirm    = $false
                }

                $result = Set-DFeSqliteDatabase @params

                $result.Scope         | Should -Be 'Index'
                $result.SchemaVersion | Should -Be 5

                $validationParams = @{
                    Path  = $target
                    Scope = 'Index'
                }

                $validation = Assert-DFeSqliteDatabase @validationParams

                $validation.IntegrityCheck | Should -Be 'ok'

                (Test-Path -LiteralPath $result.RecoveryPath -PathType Leaf) |
                    Should -BeTrue
            }
        }

        Context 'Invalid source protection' {

            It 'Rejects an invalid backup without changing existing data' {
                $cnpj       = '42345678000199'
                $target     = Initialize-DFeAudit -Cnpj $cnpj
                $originalId = [guid]::NewGuid().ToString('N')

                Add-TestAuditExecution -Path $target -ExecutionId $originalId

                $invalidPath = New-TestBackupPath -Name 'invalid'

                [System.IO.File]::WriteAllText(
                    $invalidPath,
                    'not a SQLite database'
                )

                $params = @{
                    Cnpj       = $cnpj
                    Scope      = 'Audit'
                    BackupPath = $invalidPath
                    Confirm    = $false
                }

                { Set-DFeSqliteDatabase @params } | Should -Throw

                $countParams = @{
                    Path        = $target
                    ExecutionId = $originalId
                }

                (Get-TestAuditExecutionCount @countParams) | Should -Be 1
            }

            It 'Rejects a missing destination database' {
                $cnpj   = '52345678000199'
                $target = Get-StorePath -Scope Audit -Cnpj $cnpj

                $params = @{
                    Cnpj       = $cnpj
                    Scope      = 'Audit'
                    BackupPath = $Script:AuditBackupPath
                    Confirm    = $false
                }

                { Set-DFeSqliteDatabase @params } | Should -Throw

                (Test-Path -LiteralPath $target)  | Should -BeFalse
            }
        }

        Context 'Execution coordination' {

            It 'Rejects replacement when the execution lock is unavailable' {
                $cnpj       = '62345678000199'
                $target     = Initialize-DFeAudit -Cnpj $cnpj
                $originalId = [guid]::NewGuid().ToString('N')

                Add-TestAuditExecution -Path $target -ExecutionId $originalId

                Mock -CommandName Enter-PipeDFeExecutionLock -MockWith {
                    throw 'Execution lock unavailable.'
                }

                $params = @{
                    Cnpj       = $cnpj
                    Scope      = 'Audit'
                    BackupPath = $Script:AuditBackupPath
                    Confirm    = $false
                }

                { Set-DFeSqliteDatabase @params } | Should -Throw

                $countParams = @{
                    Path        = $target
                    ExecutionId = $originalId
                }

                (Get-TestAuditExecutionCount @countParams) | Should -Be 1
            }

            It 'Leaves the database unchanged when WhatIf is used' {
                $cnpj       = '72345678000199'
                $target     = Initialize-DFeAudit -Cnpj $cnpj
                $originalId = [guid]::NewGuid().ToString('N')

                Add-TestAuditExecution -Path $target -ExecutionId $originalId

                $params = @{
                    Cnpj       = $cnpj
                    Scope      = 'Audit'
                    BackupPath = $Script:AuditBackupPath
                    WhatIf     = $true
                }

                Set-DFeSqliteDatabase @params | Out-Null

                $originalCountParams = @{
                    Path        = $target
                    ExecutionId = $originalId
                }

                $sourceCountParams = @{
                    Path        = $target
                    ExecutionId = $Script:SourceExecutionId
                }

                (Get-TestAuditExecutionCount @originalCountParams) | Should -Be 1
                (Get-TestAuditExecutionCount @sourceCountParams)   | Should -Be 0
            }
        }
    }
}
