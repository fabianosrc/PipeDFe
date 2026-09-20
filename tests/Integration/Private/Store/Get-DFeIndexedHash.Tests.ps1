#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Integration tests for Get-DFeIndexedHash.

.DESCRIPTION
Verifies Get-DFeIndexedHash against a real SQLite database using the
actual index schema from Initialize-DFeIndex. Each test runs against
an isolated database in TestDrive.

Coverage includes:
  - Returns hashes from dfe_document.
  - Returns hashes from dfe_evento.
  - Returns hashes from dfe_inutilizacao.
  - Returns hashes from all three tables combined.
  - Deduplicates hashes via UNION when the same hash appears in multiple tables.
  - Returns no output when all tables are empty.
  - Returns no output when the database file does not exist.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseShouldProcessForStateChangingFunctions',
    '',
    Justification = 'ShouldProcess would add no value here.'
)]

param ()

# InModuleScope needs to resolve the PipeDFe module during the Discovery phase,
# because that's when Context/It are executed to register the test tree. If the
# module isn't loaded at that point, InModuleScope fails before any BeforeAll or
# BeforeEach ever runs.
BeforeDiscovery {
    $moduleRoot = (Get-Item $PSScriptRoot).Parent.Parent.Parent.Parent.FullName

    $moduleName = Join-Path -Path $moduleRoot -ChildPath 'PipeDFe.psd1'

    Import-Module -Name $moduleName -Force -Global -ErrorAction Stop
}

Describe 'Get-DFeIndexedHash' -Tag 'Integration' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            $Script:Cnpj         = '12345678000199'
            $Script:DatabasePath = [System.IO.Path]::Combine($TestDrive, 'index.db')

            # Each company has its own isolated index.db - no cnpj column needed.
            function New-TestSchema {
                [CmdletBinding()]
                [OutputType([void])]
                param (
                    [Parameter(Mandatory)]
                    [string]$Path
                )

                $conn = Open-SqliteConnection -Path $Path

                try {
                    $cmd = $conn.CreateCommand()

                    try {
                        $cmd.CommandText = @'
CREATE TABLE dfe_document (
    chave_acesso TEXT    NOT NULL PRIMARY KEY,
    modelo       INTEGER NOT NULL,
    file_path    TEXT    NOT NULL,
    is_proc      INTEGER NOT NULL DEFAULT 0,
    ndoc         INTEGER,
    serie        TEXT,
    dh_emi       TEXT,
    sha256       TEXT    NOT NULL,
    indexed_at   TEXT    NOT NULL
);

CREATE TABLE dfe_evento (
    chave_pai   TEXT NOT NULL,
    file_path   TEXT NOT NULL,
    evento_tipo TEXT,
    dh_emi      TEXT,
    sha256      TEXT NOT NULL,
    indexed_at  TEXT NOT NULL,
    PRIMARY KEY (chave_pai, file_path)
);

CREATE TABLE dfe_inutilizacao (
    id_inut    TEXT    NOT NULL PRIMARY KEY,
    modelo     INTEGER NOT NULL,
    serie      TEXT    NOT NULL,
    nnf_ini    INTEGER NOT NULL,
    nnf_fin    INTEGER NOT NULL,
    file_path  TEXT    NOT NULL,
    sha256     TEXT    NOT NULL,
    indexed_at TEXT    NOT NULL
);
'@
                        $cmd.ExecuteNonQuery() | Out-Null
                    } finally {
                        $cmd.Dispose()
                    }
                } finally {
                    $conn.Dispose()
                }
            }

            function Add-TestDocument {
                [CmdletBinding()]
                [OutputType([void])]
                param (
                    [Parameter(Mandatory)]
                    [string]$Path,

                    [Parameter(Mandatory)]
                    [string]$ChaveAcesso,

                    [Parameter(Mandatory)]
                    [string]$Sha256
                )

                $conn = Open-SqliteConnection -Path $Path

                try {
                    $cmd = $conn.CreateCommand()

                    try {
                        $cmd.CommandText = @'
INSERT INTO dfe_document (
    chave_acesso,
    modelo,
    file_path,
    sha256,
    indexed_at
) VALUES (
    @chave,
    55,
    'doc.xml',
    @sha256,
    '2026-08-01T00:00:00+00:00'
);
'@
                        $cmd.Parameters.AddWithValue('@chave',  $ChaveAcesso) | Out-Null
                        $cmd.Parameters.AddWithValue('@sha256', $Sha256)      | Out-Null
                        $cmd.ExecuteNonQuery() | Out-Null
                    } finally {
                        $cmd.Dispose()
                    }
                } finally {
                    $conn.Dispose()
                }
            }

            function Add-TestEvento {
                [CmdletBinding()]
                [OutputType([void])]
                param (
                    [Parameter(Mandatory)]
                    [string]$Path,

                    [Parameter(Mandatory)]
                    [string]$ChavePai,

                    [Parameter(Mandatory)]
                    [string]$FilePath,

                    [Parameter(Mandatory)]
                    [string]$Sha256
                )

                $conn = Open-SqliteConnection -Path $Path

                try {
                    $cmd = $conn.CreateCommand()

                    try {
                        $cmd.CommandText = @'
INSERT INTO dfe_evento (
    chave_pai,
    file_path,
    sha256,
    indexed_at
) VALUES (
    @chave_pai,
    @file_path,
    @sha256,
    '2026-08-01T00:00:00+00:00'
);
'@
                        $cmd.Parameters.AddWithValue('@chave_pai',  $ChavePai)  | Out-Null
                        $cmd.Parameters.AddWithValue('@file_path',  $FilePath)  | Out-Null
                        $cmd.Parameters.AddWithValue('@sha256',     $Sha256)    | Out-Null
                        $cmd.ExecuteNonQuery() | Out-Null
                    } finally {
                        $cmd.Dispose()
                    }
                } finally {
                    $conn.Dispose()
                }
            }

            function Add-TestInutilizacao {
                [CmdletBinding()]
                [OutputType([void])]
                param (
                    [Parameter(Mandatory)]
                    [string]$Path,

                    [Parameter(Mandatory)]
                    [string]$IdInut,

                    [Parameter(Mandatory)]
                    [string]$Sha256
                )

                $conn = Open-SqliteConnection -Path $Path

                try {
                    $cmd = $conn.CreateCommand()

                    try {
                        $cmd.CommandText = @'
INSERT INTO dfe_inutilizacao (
    id_inut,
    modelo,
    serie,
    nnf_ini,
    nnf_fin,
    file_path,
    sha256,
    indexed_at
) VALUES (
    @id_inut,
    55,
    '001',
    1,
    1,
    'inut.xml',
    @sha256,
    '2026-08-01T00:00:00+00:00'
);
'@
                        $cmd.Parameters.AddWithValue('@id_inut', $IdInut) | Out-Null
                        $cmd.Parameters.AddWithValue('@sha256',  $Sha256) | Out-Null
                        $cmd.ExecuteNonQuery() | Out-Null
                    } finally {
                        $cmd.Dispose()
                    }
                } finally {
                    $conn.Dispose()
                }
            }

            New-TestSchema -Path $Script:DatabasePath

            Mock -CommandName Get-StorePath -MockWith {
                param (
                    [Parameter()]
                    [string]$Scope,

                    [Parameter()]
                    [string]$Cnpj
                )

                $null = $Scope
                $null = $Cnpj

                return $Script:DatabasePath
            }
        }

        AfterAll {

            Remove-Module -Name PipeDFe -Force -ErrorAction SilentlyContinue
        }

        #region dfe_document
        Context 'dfe_document hashes' {

            BeforeAll {

                $document = @{
                    Path        = $Script:DatabasePath
                    ChaveAcesso = ('1' * 44)
                    Sha256      = 'DOCUMENT-HASH-001'
                }

                Add-TestDocument @document

                $Script:Result = @(Get-DFeIndexedHash -Cnpj $Script:Cnpj)
            }

            It 'Returns the hash from dfe_document' {
                $Script:Result | Should -Contain 'DOCUMENT-HASH-001'
            }
        }
        #endregion

        #region All tables
        Context 'All three tables combined' {

            BeforeAll {

                $documentParams = @{
                    Path        = $Script:DatabasePath
                    ChaveAcesso = ('2' * 44)
                    Sha256      = 'DOCUMENT-HASH-002'
                }

                Add-TestDocument @documentParams

                $eventParams = @{
                    Path      = $Script:DatabasePath
                    ChavePai  = ('2' * 44)
                    FilePath  = 'evt.xml'
                    Sha256    = 'EVENTO-HASH-001'
                }

                Add-TestEvento @eventParams

                $inutilizacaoParams = @{
                    Path      = $Script:DatabasePath
                    IdInut    = 'INUT001'
                    Sha256    = 'INUTILIZACAO-HASH-001'
                }

                Add-TestInutilizacao @inutilizacaoParams

                $Script:Result = @(Get-DFeIndexedHash -Cnpj $Script:Cnpj)
            }

            It 'Returns hashes from all three tables' {
                $Script:Result | Should -Contain 'DOCUMENT-HASH-002'
                $Script:Result | Should -Contain 'EVENTO-HASH-001'
                $Script:Result | Should -Contain 'INUTILIZACAO-HASH-001'
            }
        }
        #endregion

        #region UNION deduplication
        Context 'UNION deduplication' {

            BeforeAll {

                $documentParams = @{
                    Path        = $Script:DatabasePath
                    ChaveAcesso = ('3' * 44)
                    Sha256      = 'DUPLICATE-HASH'
                }

                Add-TestDocument @documentParams


                $eventParams = @{
                    Path      = $Script:DatabasePath
                    ChavePai  = ('3' * 44)
                    FilePath  = 'evt1.xml'
                    Sha256    = 'DUPLICATE-HASH'
                }

                Add-TestEvento @eventParams

                $inutilizacaoParams = @{
                    Path      = $Script:DatabasePath
                    IdInut    = 'INUT002'
                    Sha256    = 'DUPLICATE-HASH'
                }

                Add-TestInutilizacao @inutilizacaoParams

                $Script:Result = @(
                    Get-DFeIndexedHash -Cnpj $Script:Cnpj |
                        Where-Object { $_ -eq 'DUPLICATE-HASH' }
                )
            }

            It 'Returns the duplicate hash exactly once' {
                $Script:Result | Should -HaveCount 1
            }
        }
        #endregion

        #region Empty database
        Context 'Empty database' {

            BeforeAll {

                $databasePath = [System.IO.Path]::Combine($TestDrive, 'empty.db')

                New-TestSchema -Path $databasePath

                Mock -CommandName Get-StorePath -MockWith {
                    param (
                        [Parameter()]
                        [string]$Scope,

                        [Parameter()]
                        [string]$Cnpj
                    )

                    $null = $Scope
                    $null = $Cnpj

                    return $databasePath
                }

                $Script:Result = @(Get-DFeIndexedHash -Cnpj $Script:Cnpj)
            }

            It 'Returns no output when all tables are empty' {
                $Script:Result | Should -HaveCount 0
            }
        }
        #endregion

        #region Database does not exist
        Context 'Database does not exist' {

            BeforeAll {

                Mock -CommandName Get-StorePath -MockWith {
                    param (
                        [Parameter()]
                        [string]$Scope,

                        [Parameter()]
                        [string]$Cnpj
                    )

                    $null = $Scope
                    $null = $Cnpj

                    return [System.IO.Path]::Combine($TestDrive, 'nonexistent.db')
                }

                $Script:Result = @(Get-DFeIndexedHash -Cnpj $Script:Cnpj)
            }

            It 'Returns no output when the database file does not exist' {
                $Script:Result | Should -HaveCount 0
            }
        }
        #endregion
    }
}
