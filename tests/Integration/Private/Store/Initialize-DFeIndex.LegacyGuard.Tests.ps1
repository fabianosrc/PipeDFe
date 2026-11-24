#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Integration tests for safe rejection of unsupported index schema versions.

.DESCRIPTION
Coverage includes:
- Existing index databases stamped with versions 1 through 6 are migrated
  to the current schema without destroying existing rows.
- An actual v7 database created by Initialize-DFeIndex is accepted without
  migration and its schema version is not changed.
- An incompatible version 0 database (dfe_document exists but is missing
  required columns) is rejected without altering its schema.

The version 1-6 fixtures intentionally test the migration path only; they
are not asserted to be faithful historical schemas. Rejection of unsupported
future versions is covered by Initialize-DFeIndex.Tests.ps1.
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

Describe 'Initialize-DFeIndex legacy schema guard' -Tag 'Integration' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            $testID = [guid]::NewGuid().ToString('N')

            $Script:PreviousLocalAppData = $env:LOCALAPPDATA
            $Script:PreviousDataRoot     = $env:PIPEDFE_DATA_ROOT

            $testRootParams  = @{
                Path      = [System.IO.Path]::GetTempPath()
                ChildPath = 'PipeDFe.LegacyGuard-{0}' -f $testID
            }

            $Script:TestRoot = Join-Path @testRootParams

            $null = [System.IO.Directory]::CreateDirectory($Script:TestRoot)

            $env:LOCALAPPDATA      = $Script:TestRoot
            $env:PIPEDFE_DATA_ROOT = $null

            #region Helpers
            function Invoke-FixtureSql {
                [CmdletBinding()]
                param (
                    [Parameter(Mandatory)]
                    [string]$Path,

                    [Parameter(Mandatory)]
                    [string]$Sql,

                    [Parameter()]
                    [switch]$Scalar
                )

                $connection = Open-SqliteConnection -Path $Path

                try {
                    $command = $connection.CreateCommand()

                    try {
                        $command.CommandText = $Sql
                        if ($Scalar) {
                            return $command.ExecuteScalar()
                        }

                        $null = $command.ExecuteNonQuery()
                    } finally {
                        $command.Dispose()
                    }
                } finally {
                    $connection.Dispose()
                }
            }

            function New-VersionGuardFixture {
                [CmdletBinding()]
                [OutputType([string])]
                param (
                    [Parameter(Mandatory)]
                    [string]$Cnpj,

                    [Parameter(Mandatory)]
                    [int]$Version,

                    [Parameter()]
                    [string]$ExtraSql = ''
                )

                $path = Get-StorePath -Scope Index -Cnpj $Cnpj

                $null = [System.IO.Directory]::CreateDirectory(
                    [System.IO.Path]::GetDirectoryName($path)
                )

                $sql = @'
CREATE TABLE guard_sentinel (
    id INTEGER PRIMARY KEY,
    value TEXT NOT NULL
);
INSERT INTO guard_sentinel (value) VALUES ('preserved');
'@

                if (-not [string]::IsNullOrWhiteSpace($ExtraSql)) {
                    $sql += [Environment]::NewLine + $ExtraSql
                }

                $sql += [Environment]::NewLine + "PRAGMA user_version = $Version;"

                Invoke-FixtureSql -Path $path -Sql $sql

                return $path
            }
        }

        AfterAll {

            $env:LOCALAPPDATA      = $Script:PreviousLocalAppData
            $env:PIPEDFE_DATA_ROOT = $Script:PreviousDataRoot

            $removeItemParams = @{
                LiteralPath = $Script:TestRoot
                Recurse     = $true
                Force       = $true
                ErrorAction = 'SilentlyContinue'
            }

            Remove-Item @removeItemParams
        }

        #region Unsupported historical index
        Context 'Unsupported historical index versions' {

            It 'Rejects version <_> without modifying the database' -ForEach @(1, 2, 3, 4, 5, 6, 7) {
                $version = [int]$_

                $cnpj = '12345678{0:D6}' -f $version
                $path = New-VersionGuardFixture -Cnpj $cnpj -Version $version

                { Initialize-DFeIndex -Cnpj $cnpj -ErrorAction Stop } |
                    Should -Throw -ErrorId 'IndexSchemaInitFailed*'

                [int](Invoke-FixtureSql -Path $path -Sql 'PRAGMA user_version;' -Scalar) |
                    Should -Be $version

                [string](Invoke-FixtureSql -Path $path -Sql 'SELECT value FROM guard_sentinel;' -Scalar) |
                    Should -BeExactly 'preserved'

                # A rejected version must not have the current schema created over it.
                $sqlParams = @{
                    Path   = $path
                    Sql    = "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'dfe_delivery_archive';"
                    Scalar = $true
                }

                [int](Invoke-FixtureSql @sqlParams) | Should -Be 0
            }
        }
        #endregion

        Context 'Current index schema' {

            BeforeAll {

                $Script:CurrentCnpj = '12345678000800'
                $Script:CurrentPath = Initialize-DFeIndex -Cnpj $Script:CurrentCnpj -ErrorAction Stop

                Invoke-FixtureSql -Path $Script:CurrentPath -Sql @'
CREATE TABLE guard_sentinel (
    id INTEGER PRIMARY KEY,
    value TEXT NOT NULL
);
INSERT INTO guard_sentinel (value) VALUES ('preserved');
'@

            }

            It 'Accepts an actual v8 index without migration' {
                { Initialize-DFeIndex -Cnpj $Script:CurrentCnpj -ErrorAction Stop } |
                    Should -Not -Throw
            }

            It 'Keeps the current schema version' {
                $sqlParamsOne = @{
                    Path   = $Script:CurrentPath
                    Sql    = 'PRAGMA user_version;'
                    Scalar = $true
                }

                [int](Invoke-FixtureSql @sqlParamsOne) |
                    Should -Be $Script:DFeIndexSchemaVersion
            }

            It 'Preserves existing rows' {
                $sqlParamsTwo = @{
                    Path   = $Script:CurrentPath
                    Sql    = 'SELECT value FROM guard_sentinel;'
                    Scalar = $true
                }

                [string](Invoke-FixtureSql @sqlParamsTwo) |
                    Should -BeExactly 'preserved'
            }
        }
        #endregion

        #region Incompatible unversioned index
        Context 'Incompatible unversioned index' {

            BeforeAll {

                $Script:IncompatibleCnpj   = '12345678000900'

                $guardFixtureParams = @{
                    Cnpj     = $Script:IncompatibleCnpj
                    Version  = 0
                    ExtraSql = @'
CREATE TABLE dfe_document (
    chave_acesso TEXT NOT NULL PRIMARY KEY,
    is_proc INTEGER NOT NULL DEFAULT 0
);
'@

                }

                $Script:IncompatiblePath   = New-VersionGuardFixture @guardFixtureParams
            }

            It 'Rejects incomplete schema with the correct error ID' {
                $sqlParams = @{
                    Cnpj        = $Script:IncompatibleCnpj
                    ErrorAction = 'Stop'
                }

                { Initialize-DFeIndex @sqlParams } |
                    Should -Throw -ErrorId 'IndexSchemaInitFailed*'
            }

            It 'Preserves user_version and the original table structure' {
                $sqlParamsOne = @{
                    Path   = $Script:IncompatiblePath
                    Sql    = 'PRAGMA user_version;'
                    Scalar = $true
                }

                $sqlParamsTwo = @{
                    Path   = $Script:IncompatiblePath
                    Sql    = @"
SELECT COUNT(*)
FROM pragma_table_info ('dfe_document')
WHERE name IN ('file_path', 'indexed_at', 'processing_status');
"@
                    Scalar = $true
                }

                [int](Invoke-FixtureSql @sqlParamsOne) | Should -Be 0
                [int](Invoke-FixtureSql @sqlParamsTwo) | Should -Be 0
            }

            It 'Preserves pre-existing records' {
                $sqlParams = @{
                    Path   = $Script:IncompatiblePath
                    Sql    = 'SELECT value FROM guard_sentinel;'
                    Scalar = $true
                }

                [string](Invoke-FixtureSql @sqlParams) |
                    Should -BeExactly 'preserved'
            }
        }
        #endregion
    }
}
