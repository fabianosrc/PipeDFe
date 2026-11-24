#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Integration tests for Save-DFeNFSeFiscalData.

.DESCRIPTION
Verifies NFS-e Nacional fiscal persistence against a real SQLite index.

Coverage includes:
  - Schema upgrade from v6 to v7 without touching existing fiscal and delivery tables.
  - Idempotent upgrade across multiple Initialize-DFeIndex calls.
  - Key, number, dates, and amounts persisted correctly without inventing missing values.
  - Decimal amounts stored as invariant text.
  - Dates converted to UTC before storage.
  - Optional amounts stored as NULL when absent.
  - No-op when source hash is identical.
  - Projection replaced when source hash changes.
  - Source path refreshed on same hash with different path.
  - Rollback leaves previous projection intact on SQLite write failure.
  - Rejection of a projection with an invalid PSTypeName.
  - Rejection of a projection with an invalid schema version.
  - Rejection of a projection with a 44-digit key.
  - Rejection of a relative SourcePath.
#>

BeforeDiscovery {
    # InModuleScope needs to resolve the PipeDFe module during the Discovery phase,
    # because that's when Context/It are executed to register the test tree. If the
    # module isn't loaded at that point, InModuleScope fails before any BeforeAll or
    # BeforeEach ever runs.
    $moduleRoot = (Get-Item -LiteralPath $PSScriptRoot).Parent.Parent.Parent.Parent.FullName

    $modulePath = Join-Path -Path $moduleRoot -ChildPath 'PipeDFe.psd1'

    Import-Module -Name $modulePath -Force -Global -ErrorAction Stop
}

Describe 'Save-DFeNFSeFiscalData' -Tag 'Integration' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            $Script:PreviousDataRoot = $env:LOCALAPPDATA
            $env:LOCALAPPDATA        = $TestDrive

            $Script:Cnpj = '12345678000199'
            $Script:Key  = '35503082123456780001990000000000001261100000012345'

            $Script:NFSeXml = @"
<NFSe xmlns="http://www.sped.fazenda.gov.br/nfse" versao="1.01">
    <infNFSe Id="NFS$($Script:Key)">
        <nNFSe>9876543210123</nNFSe>
        <cStat>100</cStat>
        <dhProc>2026-11-01T00:05:00-03:00</dhProc>
        <emit>
            <CNPJ>12345678000199</CNPJ>
        </emit>
        <valores>
            <vISSQN>2.00</vISSQN>
            <vLiq>98.00</vLiq>
        </valores>
        <DPS versao="1.01">
            <infDPS>
                <dhEmi>2026-10-31T23:58:00-03:00</dhEmi>
                <dCompet>2026-10-31</dCompet>
                <prest>
                    <CPF>12345678901</CPF>
                </prest>
                <toma>
                    <NIF>
                        EXT-123
                    </NIF>
                </toma>
                <valores>
                    <vServPrest>
                        <vServ>100.00</vServ>
                    </vServPrest>
                </valores>
            </infDPS>
        </DPS>
    </infNFSe>
</NFSe>
"@

            # Executes a SQL statement against a path-identified SQLite database.
            # Returns the scalar result, or nothing when -NonQuery is specified.
            function Invoke-NFSeTestSql {
                [CmdletBinding()]
                [OutputType([object])]
                param (
                    [Parameter(Mandatory)]
                    [string]$Path,

                    [Parameter(Mandatory)]
                    [string]$Sql,

                    [Parameter()]
                    [switch]$NonQuery
                )

                $connection = Open-SqliteConnection -Path $Path
                try {
                    $command = $connection.CreateCommand()
                    try {
                        $command.CommandText = $Sql
                        if ($NonQuery) {
                            $null = $command.ExecuteNonQuery()
                        } else {
                            $command.ExecuteScalar()
                        }
                    } finally {
                        $command.Dispose()
                    }
                } finally {
                    $connection.Dispose()
                }
            }
        }

        AfterAll {

            $env:LOCALAPPDATA = $Script:PreviousDataRoot
        }

        #region Schema migration
        It 'Upgrades a v6 index without changing existing fiscal and delivery tables' {
            $cnpj = '12345678000188'
            $path = Initialize-DFeIndex -Cnpj $cnpj

            $setupParams = @{
                Path     = $path
                NonQuery = $true
                Sql      = @'
DROP TABLE IF EXISTS dfe_nfse;

PRAGMA user_version = 6;

INSERT INTO dfe_document (
    chave_acesso,
    modelo,
    file_path,
    sha256,
    indexed_at
) VALUES (
    '35261012345678000199620010000000011234567890',
    62,
    'nfcom.xml',
    lower(hex(zeroblob(32))),
    '2026-11-01'
);

INSERT INTO dfe_nfcom (
    chave_acesso,
    schema_version,
    source_sha256,
    extracted_at,
    numero
) SELECT
    chave_acesso,
    1,
    sha256,
    indexed_at,
    '123'
FROM
    dfe_document;
'@
            }

            Invoke-NFSeTestSql @setupParams

            Initialize-DFeIndex -Cnpj $cnpj | Should -BeExactly $path
            Initialize-DFeIndex -Cnpj $cnpj | Should -BeExactly $path

            Invoke-NFSeTestSql -Path $path -Sql 'PRAGMA user_version;' |
                Should -Be $Script:DFeIndexSchemaVersion

            $legacyParams = @{
                Path = $path
                Sql  = @'
SELECT d.file_path || '|' || n.numero
FROM dfe_document AS d
INNER JOIN dfe_nfcom AS n ON n.chave_acesso = d.chave_acesso;
'@
            }

            Invoke-NFSeTestSql @legacyParams | Should -BeExactly 'nfcom.xml|123'

            $tableParams = @{
                Path = $path
                Sql  = @'
SELECT COUNT(*) FROM sqlite_master
WHERE type = 'table' AND name IN ('dfe_nfse', 'dfe_nfcom', 'dfe_nfe', 'dfe_delivery');
'@
            }

            Invoke-NFSeTestSql @tableParams | Should -Be 4
        }
        #endregion

        #region Fiscal persistence
        Context 'Writes a projection from the parser' {

            BeforeEach {

                $Script:DbPath = Initialize-DFeIndex -Cnpj $Script:Cnpj

                $clearParams = @{
                    Path     = $Script:DbPath
                    Sql      = 'DELETE FROM dfe_nfse;'
                    NonQuery = $true
                }

                Invoke-NFSeTestSql @clearParams

                $Script:SaveParams = @{
                    Cnpj         = $Script:Cnpj
                    FiscalData   = Get-DFeNFSeFiscalData -Xml ([xml]$Script:NFSeXml)
                    SourcePath   = Join-Path -Path $TestDrive -ChildPath 'nfse.xml'
                    SourceSha256 = 'a' * 64
                }
            }

            It 'Preserves key, number, dates and amounts without inventing missing values' {
                $saveParams = $Script:SaveParams

                Save-DFeNFSeFiscalData @saveParams

                $queryParams = @{
                    Path = $Script:DbPath
                    Sql  = @'
SELECT chave_acesso || '|' || numero || '|' || typeof(numero) || '|' ||
       gerado_em || '|' || dps_emitida_em || '|' || competencia || '|' ||
       prestador_cpf || '|' || tomador_nif || '|' || valor_liquido
FROM dfe_nfse WHERE valor_ibs IS NULL AND valor_retencoes IS NULL;
'@
                }

                $expected = @(
                    $Script:Key
                    '9876543210123'
                    'text'
                    '2026-11-01T03:05:00.0000000+00:00'
                    '2026-11-01T02:58:00.0000000+00:00'
                    '2026-10-31'
                    '12345678901'
                    'EXT-123'
                    '98'
                ) -join '|'

                Invoke-NFSeTestSql @queryParams | Should -BeExactly $expected
            }

            It 'Is a no-op for an identical source and replaces the projection on a new hash' {
                $saveParams = $Script:SaveParams

                Save-DFeNFSeFiscalData @saveParams

                $updatedXml = [xml]$Script:NFSeXml.Replace('98.00</vLiq>', '96.25</vLiq>')

                $saveParams.FiscalData = Get-DFeNFSeFiscalData -Xml $updatedXml

                Save-DFeNFSeFiscalData @saveParams

                $queryParams = @{
                    Path = $Script:DbPath
                    Sql  = 'SELECT valor_liquido FROM dfe_nfse;'
                }

                Invoke-NFSeTestSql @queryParams | Should -BeExactly '98'

                $saveParams.SourceSha256 = 'b' * 64

                Save-DFeNFSeFiscalData @saveParams

                Invoke-NFSeTestSql @queryParams | Should -BeExactly '96.25'

                $countParams = @{
                    Path = $Script:DbPath
                    Sql  = 'SELECT COUNT(*) FROM dfe_nfse;'
                }

                Invoke-NFSeTestSql @countParams | Should -Be 1
            }

            It 'Refreshes a moved source path without rewriting the fiscal projection' {
                $saveParams = $Script:SaveParams

                Save-DFeNFSeFiscalData @saveParams

                $saveParams.SourcePath = Join-Path -Path $TestDrive -ChildPath 'moved.xml'

                $updatedXml = [xml]$Script:NFSeXml.Replace('98.00</vLiq>', '96.25</vLiq>')

                $saveParams.FiscalData = Get-DFeNFSeFiscalData -Xml $updatedXml

                Save-DFeNFSeFiscalData @saveParams

                $pathParams = @{
                    Path = $Script:DbPath
                    Sql  = 'SELECT file_path FROM dfe_nfse;'
                }

                Invoke-NFSeTestSql @pathParams | Should -BeExactly $saveParams.SourcePath

                $valueParams = @{
                    Path = $Script:DbPath
                    Sql  = 'SELECT valor_liquido FROM dfe_nfse;'
                }

                Invoke-NFSeTestSql @valueParams | Should -BeExactly '98'
            }

            It 'Leaves the previous projection intact if SQLite refuses the update' {
                $saveParams = $Script:SaveParams
                Save-DFeNFSeFiscalData @saveParams

                $triggerParams = @{
                    Path     = $Script:DbPath
                    NonQuery = $true
                    Sql      = @'
CREATE TRIGGER fail_nfse_update BEFORE UPDATE ON dfe_nfse
BEGIN
    SELECT RAISE(ABORT, 'forced NFSe update failure');
END;
'@
                }

                Invoke-NFSeTestSql @triggerParams

                try {
                    $saveParams.SourceSha256 = 'b' * 64

                    { Save-DFeNFSeFiscalData @saveParams } |
                        Should -Throw -ErrorId 'NFSeFiscalDataSaveFailed*'

                    $hashParams = @{
                        Path = $Script:DbPath
                        Sql  = 'SELECT source_sha256 FROM dfe_nfse;'
                    }

                    Invoke-NFSeTestSql @hashParams | Should -BeExactly ('a' * 64)
                } finally {
                    $dropParams = @{
                        Path     = $Script:DbPath
                        NonQuery = $true
                        Sql      = 'DROP TRIGGER fail_nfse_update;'
                    }

                    Invoke-NFSeTestSql @dropParams
                }
            }
        }
        #endregion

        #region Parameter validation
        Context 'Rejects invalid input before touching the database' {

            BeforeAll {

                $Script:DbPath    = Initialize-DFeIndex -Cnpj $Script:Cnpj
                $Script:ValidData = Get-DFeNFSeFiscalData -Xml ([xml]$Script:NFSeXml)
                $Script:ValidPath = Join-Path -Path $TestDrive -ChildPath 'nfse.xml'
                $Script:ValidHash = 'a' * 64
            }

            It 'Rejects a projection with an invalid PSTypeName' {
                $bad = [pscustomobject]@{
                    PSTypeName    = 'SomeOtherType'
                    SchemaVersion = 1
                    ChaveAcesso   = $Script:Key
                    Numero        = '1'
                }

                $rejectParams = @{
                    Cnpj         = $Script:Cnpj
                    FiscalData   = $bad
                    SourcePath   = $Script:ValidPath
                    SourceSha256 = $Script:ValidHash
                }

                { Save-DFeNFSeFiscalData @rejectParams } |
                    Should -Throw -ErrorId 'InvalidNFSeFiscalData*'
            }

            It 'Rejects a projection with an invalid schema version' {
                $bad = $Script:ValidData.PSObject.Copy()

                $bad.SchemaVersion = 99

                $rejectParams = @{
                    Cnpj         = $Script:Cnpj
                    FiscalData   = $bad
                    SourcePath   = $Script:ValidPath
                    SourceSha256 = $Script:ValidHash
                }

                { Save-DFeNFSeFiscalData @rejectParams } |
                    Should -Throw -ErrorId 'InvalidNFSeFiscalData*'
            }

            It 'Rejects a forged projection with a 44-digit key' {
                $bad = $Script:ValidData.PSObject.Copy()

                $bad.ChaveAcesso = '1' * 44

                $rejectParams = @{
                    Cnpj         = $Script:Cnpj
                    FiscalData   = $bad
                    SourcePath   = $Script:ValidPath
                    SourceSha256 = $Script:ValidHash
                }

                { Save-DFeNFSeFiscalData @rejectParams } |
                    Should -Throw -ErrorId 'InvalidNFSeFiscalData*'
            }

            It 'Rejects a relative SourcePath' {
                $rejectParams = @{
                    Cnpj         = $Script:Cnpj
                    FiscalData   = $Script:ValidData
                    SourcePath   = 'relative\nfse.xml'
                    SourceSha256 = $Script:ValidHash
                }

                { Save-DFeNFSeFiscalData @rejectParams } |
                    Should -Throw -ErrorId 'InvalidNFSeSourcePath*'
            }

        }
        #endregion
    }
}
