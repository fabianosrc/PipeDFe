
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Integration tests for Assert-DFeSqliteDatabase.

.DESCRIPTION
Validates real SQLite databases in an isolated PipeDFe data root.

Coverage includes:
  - Valid index database.
  - Valid audit database.
  - Missing database.
  - Invalid SQLite content.
  - Incorrect database scope.
  - Foreign key violations.
  - Missing required tables.
  - Read-only validation.

No production data is accessed.
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

Describe 'Assert-DFeSqliteDatabase' -Tag 'Integration' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            $Script:PreviousDataRoot = $env:LOCALAPPDATA

            $testID = [guid]::NewGuid().ToString('N')

            $Script:TempRoot = [System.IO.Path]::Combine(
                [System.IO.Path]::GetTempPath(),
                'PipeDFe.AssertSqlite.Tests-{0}' -f $testID
            )

            New-Item -Path $Script:TempRoot -ItemType Directory -Force |
                Out-Null

            $env:LOCALAPPDATA = [System.IO.Path]::Combine(
                $Script:TempRoot,
                'data'
            )

            New-Item -Path $env:LOCALAPPDATA -ItemType Directory -Force |
                Out-Null

            $Script:ValidCnpj = '12345678000199'

            $Script:IndexPath = Initialize-DFeIndex -Cnpj $Script:ValidCnpj
            $Script:AuditPath = Initialize-DFeAudit -Cnpj $Script:ValidCnpj


            function Invoke-TestNonQuery {
                [CmdletBinding()]
                [OutputType([void])]
                param (
                    [Parameter(Mandatory)]
                    [string]$Path,

                    [Parameter(Mandatory)]
                    [string]$Sql,

                    [Parameter()]
                    [hashtable]$Parameters = @{},

                    [Parameter()]
                    [switch]$DisableForeignKeys
                )

                $connection = Open-SqliteConnection -Path $Path
                $command = $null

                try {
                    $command = $connection.CreateCommand()

                    if ($DisableForeignKeys) {
                        $command.CommandText = 'PRAGMA foreign_keys = OFF;'
                        $command.ExecuteNonQuery() | Out-Null
                    }

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

            function New-TestPath {
                [CmdletBinding()]
                [OutputType([string])]
                param (
                    [Parameter()]
                    [string]$Name = 'database'
                )

                [System.IO.Path]::Combine(
                    $Script:TempRoot,
                    '{0}-{1}.db' -f ($Name, [guid]::NewGuid().ToString('N')
                    )
                )
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

        Context 'Valid databases' {

            It 'Validates a current index database' {
                $params = @{
                    Path  = $Script:IndexPath
                    Scope = 'Index'
                }

                $result = Assert-DFeSqliteDatabase @params

                $result.PSTypeNames    | Should -Contain 'PipeDFe.SqliteValidation'
                $result.Path           | Should -Be $Script:IndexPath
                $result.Scope          | Should -Be 'Index'
                $result.SchemaVersion  | Should -Be 6
                $result.IntegrityCheck | Should -Be 'ok'
                $result.SizeBytes      | Should -BeGreaterThan 0
            }

            It 'Validates a current audit database' {
                $params = @{
                    Path  = $Script:AuditPath
                    Scope = 'Audit'
                }

                $result = Assert-DFeSqliteDatabase @params

                $result.Scope          | Should -Be 'Audit'
                $result.SchemaVersion  | Should -Be 1
                $result.IntegrityCheck | Should -Be 'ok'
            }

            It 'Preserves the database contents during validation' {
                $hashBefore = Get-FileSha256 -Path $Script:IndexPath

                $params = @{
                    Path  = $Script:IndexPath
                    Scope = 'Index'
                }

                Assert-DFeSqliteDatabase @params | Out-Null

                $hashAfter = Get-FileSha256 -Path $Script:IndexPath

                $hashAfter | Should -Be $hashBefore
            }
        }

        Context 'Invalid databases' {

            It 'Rejects a missing database without creating it' {
                $missingPath = New-TestPath -Name 'missing'

                $params = @{
                    Path  = $missingPath
                    Scope = 'Index'
                }

                { Assert-DFeSqliteDatabase @params }  | Should -Throw

                (Test-Path -LiteralPath $missingPath) | Should -BeFalse
            }

            It 'Rejects invalid SQLite file contents' {
                $invalidPath = New-TestPath -Name 'corrupt'

                [System.IO.File]::WriteAllText(
                    $invalidPath,
                    'not a SQLite database'
                )

                $params = @{
                    Path  = $invalidPath
                    Scope = 'Index'
                }

                { Assert-DFeSqliteDatabase @params } | Should -Throw
            }

            It 'Rejects an audit database when the index schema is expected' {
                $params = @{
                    Path  = $Script:AuditPath
                    Scope = 'Index'
                }

                { Assert-DFeSqliteDatabase @params } | Should -Throw
            }

            It 'Rejects an index database when the audit schema is expected' {
                $params = @{
                    Path  = $Script:IndexPath
                    Scope = 'Audit'
                }

                { Assert-DFeSqliteDatabase @params } | Should -Throw
            }

            It 'Rejects a database with broken foreign key references' {
                $cnpj = '72345678000199'
                $databasePath = Initialize-DFeAudit -Cnpj $cnpj

                $insertParams = @{
                    Path               = $databasePath
                    DisableForeignKeys = $true
                    Sql                = @'
INSERT INTO audit_event (
    execution_id,
    timestamp,
    company_cnpj,
    event_type,
    status
) VALUES (
    @execution_id,
    @timestamp,
    @company_cnpj,
    @event_type,
    @status
);
'@
                    Parameters             = @{
                        '@execution_id' = 'missing-execution'
                        '@timestamp'    = '2026-11-09T20:00:00+00:00'
                        '@company_cnpj' = $cnpj
                        '@event_type'   = 'Test'
                        '@status'       = 'Failed'
                    }
                }

                Invoke-TestNonQuery @insertParams

                $params = @{
                    Path  = $databasePath
                    Scope = 'Audit'
                }

                { Assert-DFeSqliteDatabase @params } | Should -Throw
            }

            It 'Rejects a database missing required tables' {
                $cnpj = '82345678000199'
                $databasePath = Initialize-DFeAudit -Cnpj $cnpj

                $dropParams = @{
                    Path = $databasePath
                    Sql  = 'DROP TABLE audit_event;'
                }

                Invoke-TestNonQuery @dropParams

                $params = @{
                    Path  = $databasePath
                    Scope = 'Audit'
                }

                { Assert-DFeSqliteDatabase @params } | Should -Throw
            }
        }
    }
}
