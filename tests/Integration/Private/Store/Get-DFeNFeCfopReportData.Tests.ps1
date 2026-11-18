#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Integration tests for Get-DFeNFeCfopReportData.

.DESCRIPTION
Verifies that Get-DFeNFeCfopReportData reads processed NF-e and NFC-e
item data from a real SQLite index and returns the correct Itens and
ResumoPorCFOP arrays according to its public contract.

The tests use a real SQLite database in an isolated temporary
%LOCALAPPDATA% directory. No production data is accessed.

Coverage includes:
  - Reversed date range: EndDate earlier than StartDate throws InvalidDateRange.
  - Empty result: no Processed documents in period returns two empty arrays of
    type [array].
  - Stale projection: a Processed document with no matching dfe_nfe row (LEFT
    JOIN returns null for n_item) throws NFeCfopReportReadFailed.
  - Happy path: single document with two items of the same CFOP returns the
    correct Itens count, populates ChaveAcesso, CFOP, and ValorProduto (Decimal),
    and produces one ResumoPorCFOP group with correct Quantidade, ValorProdutos
    sum, and zero ItensSemValor.
  - Item without ValorProduto: null vlr_produto increments ItensSemValor,
    is excluded from ValorProdutos sum, and is included in Quantidade.
  - Multiple CFOPs: items with distinct CFOPs produce separate ResumoPorCFOP
    groups, each with the correct independent sum and count.
  - Period boundary inclusiveness: documents exactly on StartDate and EndDate
    are included; documents one second after EndDate are excluded.
  - CNPJ isolation: each context uses a distinct CNPJ and its own index database.
#>

BeforeDiscovery {
    # InModuleScope needs to resolve the PipeDFe module during the Discovery phase,
    # because that's when Context/It are executed to register the test tree. If the
    # module isn't loaded at that point, InModuleScope fails before any BeforeAll or
    # BeforeEach ever runs.
    $moduleRoot = (Get-Item $PSScriptRoot).Parent.Parent.Parent.Parent.FullName

    $moduleName = Join-Path -Path $moduleRoot -ChildPath 'PipeDFe.psd1'

    Import-Module -Name $moduleName -Force -Global -ErrorAction Stop
}

Describe 'Get-DFeNFeCfopReportData' -Tag 'Integration' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            $testID = [guid]::NewGuid().ToString('N')

            $Script:OriginalLocalAppData = $env:LOCALAPPDATA

            $joinPathParams = @{
                Path      = [System.IO.Path]::GetTempPath()
                ChildPath = 'PipeDFe.Tests-{0}' -f $testID

            }

            $Script:TempRoot = Join-Path @joinPathParams

            New-Item -Path $Script:TempRoot -ItemType Directory -Force |
                Out-Null

            $env:LOCALAPPDATA = $Script:TempRoot

            # Define the shared fixture helper before the child contexts run.
            function Invoke-TestCfopSql {
                [CmdletBinding()]
                [OutputType([void])]
                param (
                    [Parameter(Mandatory)]
                    [string]$Cnpj,

                    [Parameter(Mandatory)]
                    [string]$Sql
                )

                $connection = Open-DFeIndexConnection -Cnpj $Cnpj
                $command = $null

                try {
                    $command = $connection.CreateCommand()
                    $command.CommandText = $Sql

                    $command.ExecuteNonQuery() | Out-Null
                } finally {
                    try {
                        if ($null -ne $command) {
                            $command.Dispose()
                        }
                    } finally {
                        $connection.Dispose()
                    }
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

        #region Reversed date range
        Context 'Reversed date range' {

            It 'Throws InvalidDateRange when EndDate is earlier than StartDate' {
                $params = @{
                    Cnpj      = '12345678000195'
                    StartDate = [System.DateTimeOffset]::UtcNow
                    EndDate   = [System.DateTimeOffset]::UtcNow.AddDays(-1)
                }

                { Get-DFeNFeCfopReportData @params } |
                    Should -Throw -ErrorId 'InvalidDateRange*'
            }
        }
        #endregion

        #region No documents in period
        Context 'No documents in period' {

            BeforeAll {

                $Script:EmptyCnpj = '11111111000191'

                $null = Initialize-DFeIndex -Cnpj $Script:EmptyCnpj

                $reportDataParams = @{
                    Cnpj      = $Script:EmptyCnpj
                    StartDate = ([System.DateTimeOffset]::UtcNow.AddDays(-30))
                    EndDate   = ([System.DateTimeOffset]::UtcNow)
                }

                $Script:EmptyResult = Get-DFeNFeCfopReportData @reportDataParams
            }

            It 'Returns an Itens array' {
                $Script:EmptyResult.Itens | Should -HaveCount 0
            }

            It 'Returns a ResumoPorCFOP array' {
                $Script:EmptyResult.ResumoPorCFOP | Should -HaveCount 0
            }

            It 'Returns arrays even when count is zero' {
                $Script:EmptyResult.Itens -is [array]         | Should -BeTrue
                $Script:EmptyResult.ResumoPorCFOP -is [array] | Should -BeTrue
            }
        }
        #endregion

        #region Stale projection (missing n_item)
        Context 'Stale projection' {

            BeforeAll {

                $Script:StaleCnpj = '22222222000100'

                $null = Initialize-DFeIndex -Cnpj $Script:StaleCnpj

                # Insert a Processed document with no matching dfe_nfe row
                # (LEFT JOIN will return null for n_item).
                Invoke-TestCfopSql -Cnpj $Script:StaleCnpj -Sql @'
INSERT INTO dfe_document (
    chave_acesso,
    modelo,
    file_path,
    sha256,
    processing_status,
    dh_emi,
    indexed_at
) VALUES (
    '35240112345678000195550010000000011000000011',
    55,
    'fixture.xml',
    '00000000000000000000000000000000000000000000000000000000aabbccdd',
    'Processed',
    '2024-01-15T12:00:00.0000000+00:00',
    '2024-01-15T12:00:00.0000000+00:00'
);
'@
            }

            It 'Throws NFeCfopReportReadFailed when a projection row is missing' {
                $params = @{
                    Cnpj      = $Script:StaleCnpj
                    StartDate = [System.DateTimeOffset]::new(
                        2024, 1, 1, 0, 0, 0, [System.TimeSpan]::Zero
                    )
                    EndDate   = [System.DateTimeOffset]::new(
                        2024, 1, 31, 23, 59, 59, [System.TimeSpan]::Zero
                    )
                }

                { Get-DFeNFeCfopReportData @params } |
                    Should -Throw -ErrorId 'NFeCfopReportReadFailed*'
            }
        }
        #endregion

        Context 'Projection with a different source hash' {

            BeforeAll {

                $Script:MismatchCnpj = '77777777000149'

                $fixtureParams = @{
                    Cnpj = $Script:MismatchCnpj
                    Sql  = @'
INSERT INTO dfe_document (
    chave_acesso,
    modelo,
    file_path,
    sha256,
    processing_status,
    dh_emi,
    indexed_at
) VALUES (
    '35240112345678000195550010000000081000000081',
    55,
    'fixture.xml',
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    'Processed',
    '2024-01-15T12:00:00.0000000+00:00',
    '2024-01-15T12:00:00.0000000+00:00'
);

INSERT INTO dfe_nfe (
    chave_acesso,
    modelo,
    schema_version,
    source_sha256,
    extracted_at,
    numero,
    serie
) VALUES (
    '35240112345678000195550010000000081000000081',
    55,
    1,
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAB',
    '2024-01-15T12:00:00.0000000+00:00',
    '81',
    '001'
);

INSERT INTO dfe_nfe_item (
    chave_acesso,
    n_item,
    cfop,
    vlr_produto
) VALUES (
    '35240112345678000195550010000000081000000081',
    1,
    '5102',
    '100.00'
);
'@
                }

                Invoke-TestCfopSql @fixtureParams
            }

            It 'Rejects the projection even when the access key, model and item exist' {
                $reportDataParams = @{
                    Cnpj      = $Script:MismatchCnpj
                    StartDate = [System.DateTimeOffset]::new(
                        2024, 1, 1, 0, 0, 0, [System.TimeSpan]::Zero
                    )
                    EndDate   = [System.DateTimeOffset]::new(
                        2024, 1, 31, 23, 59, 59, [System.TimeSpan]::Zero
                    )
                }

                { Get-DFeNFeCfopReportData @reportDataParams } |
                    Should -Throw -ErrorId 'NFeCfopReportReadFailed*'
            }
        }

        #region Happy path - single document with items
        Context 'Single document with two items and matching hashes in different cases' {

            BeforeAll {

                $Script:HappyCnpj = '33333333000187'

                $null = Initialize-DFeIndex -Cnpj $Script:HappyCnpj

                Invoke-TestCfopSql -Cnpj $Script:HappyCnpj -Sql @'
INSERT INTO dfe_document (
    chave_acesso,
    modelo,
    file_path,
    sha256,
    processing_status,
    dh_emi,
    indexed_at
) VALUES (
    '35240112345678000195550010000000021000000021',
    55,
    'fixture.xml',
    '000000000000000000000000000000000000000000000000000000deadbeef01',
    'Processed',
    '2024-02-10T10:00:00.0000000+00:00',
    '2024-02-10T10:00:00.0000000+00:00'
);

INSERT INTO dfe_nfe (
    chave_acesso,
    modelo,
    schema_version,
    extracted_at,
    source_sha256,
    numero,
    serie
) VALUES (
    '35240112345678000195550010000000021000000021',
    55,
    1,
    '2024-01-01T00:00:00.0000000+00:00',
    '000000000000000000000000000000000000000000000000000000DEADBEEF01',
    '21',
    '001'
);

INSERT INTO dfe_nfe_item (
    chave_acesso,
    n_item,
    cod_produto,
    descricao,
    cfop,
    vlr_produto,
    ind_compoe_total
) VALUES (
    '35240112345678000195550010000000021000000021',
    1,
    'P001',
    'Produto A',
    '5102',
    '100.50',
    '1'
), (
    '35240112345678000195550010000000021000000021',
    2,
    'P002',
    'Produto B',
    '5102',
    '200.75',
    '1'
);
'@

                $reportDataParams = @{
                    Cnpj      = $Script:HappyCnpj
                    StartDate = (
                        [System.DateTimeOffset]::new(
                            2024, 2, 1, 0, 0, 0, [System.TimeSpan]::Zero
                        )
                    )
                    EndDate   = (
                        [System.DateTimeOffset]::new(
                            2024, 2, 28, 23, 59, 59, [System.TimeSpan]::Zero
                        )
                    )
                }

                $Script:HappyResult = Get-DFeNFeCfopReportData @reportDataParams
            }

            It 'Returns two Itens' {
                $Script:HappyResult.Itens | Should -HaveCount 2
            }

            It 'Populates ChaveAcesso on each item' {
                $Script:HappyResult.Itens[0].ChaveAcesso |
                    Should -Be '35240112345678000195550010000000021000000021'
            }

            It 'Populates CFOP on each item' {
                $Script:HappyResult.Itens[0].CFOP | Should -Be '5102'
            }

            It 'Populates ValorProduto as Decimal' {
                $Script:HappyResult.Itens[0].ValorProduto |
                    Should -BeOfType [decimal]
            }

            It 'Returns one ResumoPorCFOP group' {
                $Script:HappyResult.ResumoPorCFOP | Should -HaveCount 1
            }

            It 'Sums ValorProdutos correctly' {
                $Script:HappyResult.ResumoPorCFOP[0].ValorProdutos |
                    Should -Be ([decimal]301.25)
            }

            It 'Counts Quantidade correctly' {
                $Script:HappyResult.ResumoPorCFOP[0].Quantidade | Should -Be 2
            }

            It 'Reports zero ItensSemValor when all items have values' {
                $Script:HappyResult.ResumoPorCFOP[0].ItensSemValor | Should -Be 0
            }
        }
        #endregion

        #region Item without ValorProduto
        Context 'Item without ValorProduto' {

            BeforeAll {

                $Script:NullValCnpj = '44444444000153'

                $null = Initialize-DFeIndex -Cnpj $Script:NullValCnpj

                Invoke-TestCfopSql -Cnpj $Script:NullValCnpj -Sql @'
INSERT INTO dfe_document (
    chave_acesso,
    modelo,
    file_path,
    sha256,
    processing_status,
    dh_emi,
    indexed_at
) VALUES (
    '35240112345678000195550010000000031000000031',
    55,
    'fixture.xml',
    '000000000000000000000000000000000000000000000000000000cafebabe01',
    'Processed',
    '2024-03-05T08:00:00.0000000+00:00',
    '2024-03-05T08:00:00.0000000+00:00'
);

INSERT INTO dfe_nfe (
    chave_acesso,
    modelo,
    schema_version,
    extracted_at,
    source_sha256,
    numero,
    serie
) VALUES (
    '35240112345678000195550010000000031000000031',
    55,
    1,
    '2024-01-01T00:00:00.0000000+00:00',
    '000000000000000000000000000000000000000000000000000000CAFEBABE01',
    '31',
    '001'
);

INSERT INTO dfe_nfe_item (
    chave_acesso,
    n_item,
    cod_produto,
    descricao,
    cfop,
    vlr_produto,
    ind_compoe_total
) VALUES (
    '35240112345678000195550010000000031000000031',
    1,
    'P010',
    'Com Valor',
    '6102',
    '50.00',
    '1'
), (
    '35240112345678000195550010000000031000000031',
    2,
    'P011',
    'Sem Valor',
    '6102',
    NULL,
    '0'
);
'@

                $reportDataParams = @{
                    Cnpj      = $Script:NullValCnpj
                    StartDate = (
                        [System.DateTimeOffset]::new(
                            2024, 3, 1, 0, 0, 0, [System.TimeSpan]::Zero
                        )
                    )
                    EndDate   = (
                        [System.DateTimeOffset]::new(
                            2024, 3, 31, 23, 59, 59, [System.TimeSpan]::Zero
                        )
                    )
                }

                $Script:NullValResult = Get-DFeNFeCfopReportData @reportDataParams
            }

            It 'Reports one ItensSemValor in the summary' {
                $Script:NullValResult.ResumoPorCFOP[0].ItensSemValor | Should -Be 1
            }

            It 'Excludes null values from ValorProdutos sum' {
                $Script:NullValResult.ResumoPorCFOP[0].ValorProdutos |
                    Should -Be ([decimal]50.00)
            }

            It 'Includes the item with null value in Quantidade' {
                $Script:NullValResult.ResumoPorCFOP[0].Quantidade | Should -Be 2
            }
        }
        #endregion

        #region Multiple CFOPs produce separate summary groups
        Context 'Multiple CFOPs' {

            BeforeAll {

                $Script:MultiCnpj = '55555555000181'

                $null = Initialize-DFeIndex -Cnpj $Script:MultiCnpj

                Invoke-TestCfopSql -Cnpj $Script:MultiCnpj -Sql @'
INSERT INTO dfe_document (
    chave_acesso,
    modelo,
    file_path,
    sha256,
    processing_status,
    dh_emi,
    indexed_at
) VALUES (
    '35240112345678000195550010000000041000000041',
    55,
    'fixture.xml',
    '000000000000000000000000000000000000000000000000000000f00df00d01',
    'Processed',
    '2024-04-01T09:00:00.0000000+00:00',
    '2024-04-01T09:00:00.0000000+00:00'
);

INSERT INTO dfe_nfe (
    chave_acesso,
    modelo,
    schema_version,
    extracted_at,
    source_sha256,
    numero,
    serie
) VALUES (
    '35240112345678000195550010000000041000000041',
    55,
    1,
    '2024-01-01T00:00:00.0000000+00:00',
    '000000000000000000000000000000000000000000000000000000F00DF00D01',
    '41',
    '001'
);

INSERT INTO dfe_nfe_item (
    chave_acesso,
    n_item,
    cod_produto,
    descricao,
    cfop,
    vlr_produto,
    ind_compoe_total
) VALUES (
    '35240112345678000195550010000000041000000041',
    1,
    'PA',
    'Prod A',
    '5102',
    '10.00',
    '1'
), (
    '35240112345678000195550010000000041000000041',
    2,
    'PB',
    'Prod B',
    '5405',
    '20.00',
    '1'
), (
    '35240112345678000195550010000000041000000041',
    3,
    'PC',
    'Prod C',
    '5102',
    '30.00',
    '1'
);
'@

                $reportDataParams = @{
                    Cnpj      = $Script:MultiCnpj
                    StartDate = (
                        [System.DateTimeOffset]::new(
                            2024, 4, 1, 0, 0, 0, [System.TimeSpan]::Zero
                        )
                    )
                    EndDate   = (
                        [System.DateTimeOffset]::new(
                            2024, 4, 30, 23, 59, 59, [System.TimeSpan]::Zero
                        )
                    )
                }

                $Script:MultiResult = Get-DFeNFeCfopReportData @reportDataParams
            }

            It 'Returns two ResumoPorCFOP groups' {
                $Script:MultiResult.ResumoPorCFOP | Should -HaveCount 2
            }

            It 'Returns all three Itens' {
                $Script:MultiResult.Itens | Should -HaveCount 3
            }

            It 'Sums 5102 group correctly' {
                $group = $Script:MultiResult.ResumoPorCFOP |
                    Where-Object { $_.CFOP -eq '5102' }

                $group.ValorProdutos | Should -Be ([decimal]40.00)
                $group.Quantidade    | Should -Be 2
            }

            It 'Sums 5405 group correctly' {
                $group = $Script:MultiResult.ResumoPorCFOP |
                    Where-Object { $_.CFOP -eq '5405' }

                $group.ValorProdutos | Should -Be ([decimal]20.00)
                $group.Quantidade    | Should -Be 1
            }
        }
        #endregion

        #region Period boundary is inclusive
        Context 'Period boundary inclusiveness' {

            BeforeAll {

                $Script:BoundaryCnpj = '66666666000115'

                $null = Initialize-DFeIndex -Cnpj $Script:BoundaryCnpj

                # One document exactly on StartDate, one exactly on EndDate,
                # one outside the period.
                Invoke-TestCfopSql -Cnpj $Script:BoundaryCnpj -Sql @'
INSERT INTO dfe_document (
    chave_acesso,
    modelo,
    file_path,
    sha256,
    processing_status,
    dh_emi,
    indexed_at
) VALUES (
    '35240112345678000195550010000000051000000051',
    55,
    'fixture.xml',
    '000000000000000000000000000000000000000000000000000000000000aa01',
    'Processed',
    '2024-05-01T00:00:00.0000000+00:00',
    '2024-05-01T00:00:00.0000000+00:00'
), (
    '35240112345678000195550010000000061000000061',
    55,
    'fixture.xml',
    '000000000000000000000000000000000000000000000000000000000000aa02',
    'Processed',
    '2024-05-31T23:59:59.0000000+00:00',
    '2024-05-31T23:59:59.0000000+00:00'
), (
    '35240112345678000195550010000000071000000071',
    55,
    'fixture.xml',
    '000000000000000000000000000000000000000000000000000000000000aa03',
    'Processed',
    '2024-06-01T00:00:00.0000000+00:00',
    '2024-06-01T00:00:00.0000000+00:00'
);

INSERT INTO dfe_nfe (
    chave_acesso,
    modelo,
    schema_version,
    extracted_at,
    source_sha256,
    numero,
    serie
) VALUES (
    '35240112345678000195550010000000051000000051',
    55,
    1,
    '2024-01-01T00:00:00.0000000+00:00',
    '000000000000000000000000000000000000000000000000000000000000AA01',
    '51',
    '001'
), (
    '35240112345678000195550010000000061000000061',
    55,
    1,
    '2024-01-01T00:00:00.0000000+00:00',
    '000000000000000000000000000000000000000000000000000000000000AA02',
    '61',
    '001'
), (
    '35240112345678000195550010000000071000000071',
    55,
    1,
    '2024-01-01T00:00:00.0000000+00:00',
    '000000000000000000000000000000000000000000000000000000000000AA03',
    '71',
    '001'
);

INSERT INTO dfe_nfe_item (
    chave_acesso,
    n_item,
    cod_produto,
    descricao,
    cfop,
    vlr_produto,
    ind_compoe_total
) VALUES (
    '35240112345678000195550010000000051000000051',
    1,
    'P1',
    'Item 1',
    '5102',
    '1.00',
    '1'
), (
    '35240112345678000195550010000000061000000061',
    1,
    'P2',
    'Item 2',
    '5102',
    '2.00',
    '1'
), (
    '35240112345678000195550010000000071000000071',
    1,
    'P3',
    'Item 3',
    '5102',
    '3.00',
    '1'
);
'@

                $reportDataParams = @{
                    Cnpj      = $Script:BoundaryCnpj
                    StartDate = (
                        [System.DateTimeOffset]::new(
                            2024, 5, 1, 0, 0, 0, [System.TimeSpan]::Zero
                        )
                    )
                    EndDate   = (
                        [System.DateTimeOffset]::new(
                            2024, 5, 31, 23, 59, 59, [System.TimeSpan]::Zero
                        )
                    )
                }

                $Script:BoundaryResult = Get-DFeNFeCfopReportData @reportDataParams
            }

            It 'Includes documents on StartDate and EndDate' {
                $Script:BoundaryResult.Itens | Should -HaveCount 2
            }

            It 'Excludes documents after EndDate' {
                $outsideKey = '35240112345678000195550010000000071000000071'

                $found = $Script:BoundaryResult.Itens |
                    Where-Object { $_.ChaveAcesso -eq $outsideKey }

                $found | Should -HaveCount 0
            }
        }
        #endregion

    }
}
