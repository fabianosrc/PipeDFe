#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Integration tests for the NFCom schema migration in Initialize-DFeIndex (v6).

.DESCRIPTION
Verifies that Initialize-DFeIndex correctly creates the NFCom schema tables
in a new index, migrates an existing v5 index to v6 without data loss,
handles idempotent re-initialization and rejects unsupported future versions.

Run in addition to the existing Initialize-DFeIndex.Tests.ps1.

Coverage includes:
  - Creates the full NFCom schema for a new index at user_version 6.
  - Migrates an existing v5 index to v6 without losing legacy records.
  - Is idempotent for databases already at v6.
  - Rejects unsupported future schema versions with IndexSchemaInitFailed.
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

Describe 'Initialize-DFeIndex NFCom schema v6' -Tag 'Integration' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            $Script:OriginalLocalAppData = $env:LOCALAPPDATA

            $testID = [guid]::NewGuid().ToString('N')

            $Script:TempRoot = [System.IO.Path]::Combine(
                [System.IO.Path]::GetTempPath(),
                'PipeDFe.Initialize-DFeIndex-NFComV6.Tests-{0}' -f $testID
            )

            New-Item -Path $Script:TempRoot -ItemType Directory -Force | Out-Null

            $env:LOCALAPPDATA = $Script:TempRoot

            $Script:BaseCnpj = '12345678000199'

            $Script:NFComTables = @(
                'dfe_nfcom'
                'dfe_nfcom_participante'
                'dfe_nfcom_item'
                'dfe_nfcom_item_ibscbs'
                'dfe_nfcom_total'
            )

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

                    foreach ($entry in $Parameters.GetEnumerator()) {
                        $param = $command.Parameters.Add(
                            [string]$entry.Key,
                            [System.Data.DbType]::String
                        )

                        $param.Value = $entry.Value
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
                $command    = $null

                try {
                    $command = $connection.CreateCommand()
                    $command.CommandText = $Sql

                    foreach ($entry in $Parameters.GetEnumerator()) {
                        $param = $command.Parameters.Add(
                            [string]$entry.Key,
                            [System.Data.DbType]::String
                        )

                        $param.Value = $entry.Value
                    }

                    $command.ExecuteNonQuery() | Out-Null
                } finally {
                    if ($null -ne $command) {
                        $command.Dispose()
                    }

                    $connection.Dispose()
                }
            }
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

        It 'Creates the full NFCom schema for a new index at user_version 6' {
            $path = Initialize-DFeIndex -Cnpj $Script:BaseCnpj

            $versionParams = @{
                Path = $path
                Sql  = 'PRAGMA user_version;'
            }

            [int](Get-TestScalar @versionParams) | Should -Be 6

            foreach ($tableName in $Script:NFComTables) {
                $tableParams = @{
                    Path       = $path
                    Sql        = "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = @name;"
                    Parameters = @{ '@name' = $tableName }
                }

                [int](Get-TestScalar @tableParams) |
                    Should -Be 1 -Because "table '$tableName' must exist after initialization"
            }
        }

        It 'Migrates an existing v5 index to v6 without losing legacy records' {
            $cnpj = '12345678000188'
            $path = Initialize-DFeIndex -Cnpj $cnpj

            # Simulate a v5 index by removing only the new NFCom tables
            # and resetting the version. Pre-existing tables and records
            # must survive the migration.
            foreach ($tableName in @(
                    'dfe_nfcom_item_ibscbs'
                    'dfe_nfcom_total'
                    'dfe_nfcom_item'
                    'dfe_nfcom_participante'
                    'dfe_nfcom'
                )
            ) {
                $dropParams = @{
                    Path = $path
                    Sql  = "DROP TABLE IF EXISTS $tableName;"
                }

                Invoke-TestNonQuery @dropParams
            }

            $resetVersionParams = @{
                Path = $path
                Sql  = 'PRAGMA user_version = 5;'
            }

            Invoke-TestNonQuery @resetVersionParams

            $insertDocParams = @{
                Path       = $path
                Sql        = @'
INSERT INTO dfe_document (
    chave_acesso, modelo, file_path, is_proc, dh_emi, sha256, indexed_at
) VALUES (
    @key, 62, 'sample.xml', 1,
    '2026-10-29T11:37:26-03:00', lower(hex(zeroblob(32))), '2026-10-29T12:00:00Z'
);
'@
                Parameters = @{
                    '@key' = '35261012345678000199620010000000011234567890'
                }
            }

            Invoke-TestNonQuery @insertDocParams

            $result = Initialize-DFeIndex -Cnpj $cnpj

            $result | Should -Be $path

            $versionParams = @{
                Path = $path
                Sql  = 'PRAGMA user_version;'
            }

            [int](Get-TestScalar @versionParams) | Should -Be 6

            $docCountParams = @{
                Path = $path
                Sql  = 'SELECT COUNT(*) FROM dfe_document;'
            }

            [int](Get-TestScalar @docCountParams) | Should -Be 1

            $nfcomTableParams = @{
                Path       = $path
                Sql        = "SELECT COUNT(*) FROM sqlite_master WHERE name = 'dfe_nfcom';"
            }

            [int](Get-TestScalar @nfcomTableParams) | Should -Be 1
        }

        It 'Is idempotent for databases already at v6' {
            $path   = Initialize-DFeIndex -Cnpj $Script:BaseCnpj
            $second = Initialize-DFeIndex -Cnpj $Script:BaseCnpj

            $second | Should -Be $path

            $versionParams = @{
                Path = $path
                Sql  = 'PRAGMA user_version;'
            }

            [int](Get-TestScalar @versionParams) | Should -Be 6
        }

        It 'Rejects unsupported future schema versions with IndexSchemaInitFailed' {
            $cnpj = '12345678000177'
            $path = Initialize-DFeIndex -Cnpj $cnpj

            $bumpParams = @{
                Path = $path
                Sql  = 'PRAGMA user_version = 7;'
            }

            Invoke-TestNonQuery @bumpParams

            $caught = $false

            try {
                Initialize-DFeIndex -Cnpj $cnpj
            } catch {
                $caught = $true
                $_.FullyQualifiedErrorId | Should -BeLike 'IndexSchemaInitFailed*'
            }

            $caught | Should -BeTrue
        }
    }
}
