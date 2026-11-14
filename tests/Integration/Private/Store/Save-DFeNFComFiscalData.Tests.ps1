#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Integration tests for Save-DFeNFComFiscalData.

.DESCRIPTION
Verifies NFCom fiscal projection persistence against a real SQLite index.
No production data is accessed. SMTP and file I/O are not used.

Coverage includes:
  - Persists NFCom header with invariant Decimal TEXT.
  - Stores nullable tax groups as SQLite NULL.
  - Replaces an existing projection without duplicating items.
  - Persists IBS/CBS values when present.
  - Removes IBS/CBS rows when projection is replaced without them.
  - Rejects a source SHA-256 mismatch without changing persisted data.
  - Rolls back all changes when a mid-write SQLite error occurs.
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

Describe 'Save-DFeNFComFiscalData' -Tag 'Integration' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            $Script:OriginalLocalAppData = $env:LOCALAPPDATA

            $testID = [guid]::NewGuid().ToString('N')

            $Script:TempRoot = [System.IO.Path]::Combine(
                [System.IO.Path]::GetTempPath(),
                'PipeDFe.Save-DFeNFComFiscalData.Tests-{0}' -f $testID
            )

            New-Item -Path $Script:TempRoot -ItemType Directory -Force | Out-Null

            $env:LOCALAPPDATA = $Script:TempRoot

            $Script:Cnpj = '12345678000199'
            $Script:Key  = '35261012345678000199620010000000011234567890'
            $Script:Hash = 'a' * 64

            $Script:IndexPath = Initialize-DFeIndex -Cnpj $Script:Cnpj

            function Get-TestScalar {
                [CmdletBinding()]
                [OutputType([object])]
                param (
                    [Parameter(Mandatory)]
                    [string]$Sql,

                    [Parameter()]
                    [hashtable]$Parameters = @{}
                )

                $connection = Open-SqliteConnection -Path $Script:IndexPath
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
                    [string]$Sql,

                    [Parameter()]
                    [hashtable]$Parameters = @{}
                )

                $connection = Open-SqliteConnection -Path $Script:IndexPath
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

            $insertDocumentParams = @{
                Sql        = @'
INSERT INTO dfe_document (
    chave_acesso, modelo, file_path, is_proc, dh_emi, sha256, indexed_at
) VALUES (
    @key, 62, 'nfcom.xml', 1,
    '2026-10-29T11:37:26-03:00', @hash, '2026-10-29T12:00:00Z'
);
'@
                Parameters = @{
                    '@key'  = $Script:Key
                    '@hash' = $Script:Hash
                }
            }

            Invoke-TestNonQuery @insertDocumentParams

            function New-NFComProjection {
                [CmdletBinding()]
                [OutputType([pscustomobject])]
                param (
                    [Parameter()]
                    [switch]$WithIBSCBS,

                    [Parameter()]
                    [decimal]$VNF = [decimal]'222.76'
                )

                $ibscbs = $null

                if ($WithIBSCBS) {
                    $ibscbs = [PSCustomObject]@{
                        CST        = '000'
                        CClassTrib = '000001'
                        IndDoacao  = $null
                        Valores    = [PSCustomObject]@{
                            VBC           = [decimal]'222.76'
                            VIBS          = [decimal]'0.22'
                            IBSUF         = [PSCustomObject]@{
                                PIBSUF = [decimal]'0.10'
                                VIBSUF = [decimal]'0.22'
                            }
                            IBSMun        = $null
                            CBS           = [PSCustomObject]@{
                                PCBS = [decimal]'0.90'
                                VCBS = [decimal]'2.00'
                            }
                            TribRegular   = $null
                            TribCompraGov = $null
                        }
                    }
                }

                $item = [PSCustomObject]@{
                    Numero   = '1'
                    Produto  = [PSCustomObject]@{
                        Codigo         = 'SERV1'
                        Descricao      = 'Internet'
                        Classificacao  = '0400401'
                        CFOP           = '5307'
                        Unidade        = '4'
                        Quantidade     = [decimal]'1.0000'
                        ValorUnitario  = [decimal]'222.76'
                        ValorProduto   = [decimal]'222.76'
                        Desconto       = $null
                        OutrasDespesas = $null
                    }
                    Tributos = [PSCustomObject]@{
                        IndSemCST = $null
                        ICMS      = $null
                        IBSCBS    = $ibscbs
                    }
                }

                [PSCustomObject]@{
                    PSTypeName    = 'PipeDFe.Fiscal.NFComDocument'
                    SchemaVersion = 1
                    Modelo        = [ModeloDFe]::NFCom
                    ChaveAcesso   = $Script:Key
                    Identificacao = [PSCustomObject]@{
                        CUF      = '35'
                        Ambiente = '1'
                        Serie    = '1'
                        Numero   = '3390'
                        DhEmi    = '2026-10-29T11:37:26-03:00'
                    }
                    Emitente     = [PSCustomObject]@{
                        Cnpj        = $Script:Cnpj
                        RazaoSocial = 'Emissor de Teste'
                    }
                    Destinatario = $null
                    Assinante    = $null
                    Faturamento  = [PSCustomObject]@{
                        Competencia = '202609'
                    }
                    Protocolo    = $null
                    Totais       = [PSCustomObject]@{
                        VProd     = [decimal]'222.76'
                        VNF       = $VNF
                        IBSCBSTot = $null
                    }
                    Itens        = @($item)
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

        It 'Persists NFCom header with invariant Decimal TEXT and nullable tax groups' {
            $data   = New-NFComProjection
            $params = @{
                Cnpj         = $Script:Cnpj
                FiscalData   = $data
                SourceSha256 = $Script:Hash
            }

            Save-DFeNFComFiscalData @params

            $vnfParams = @{
                Sql        = 'SELECT vnf FROM dfe_nfcom_total WHERE chave_acesso = @key;'
                Parameters = @{ '@key' = $Script:Key }
            }

            $typeofParams = @{
                Sql        = 'SELECT typeof(vnf) FROM dfe_nfcom_total WHERE chave_acesso = @key;'
                Parameters = @{ '@key' = $Script:Key }
            }

            $ibscbsParams = @{
                Sql        = 'SELECT COUNT(*) FROM dfe_nfcom_item_ibscbs WHERE chave_acesso = @key;'
                Parameters = @{ '@key' = $Script:Key }
            }

            $competenciaParams = @{
                Sql        = 'SELECT faturamento_competencia FROM dfe_nfcom WHERE chave_acesso = @key;'
                Parameters = @{ '@key' = $Script:Key }
            }

            [decimal](Get-TestScalar @vnfParams) | Should -Be ([decimal]'222.76')
            Get-TestScalar @typeofParams         | Should -Be 'text'

            [int](Get-TestScalar @ibscbsParams)  | Should -Be 0
            Get-TestScalar @competenciaParams    | Should -Be '202609'
        }

        It 'Replaces an existing projection without duplicating items' {
            $data   = New-NFComProjection
            $params = @{
                Cnpj         = $Script:Cnpj
                FiscalData   = $data
                SourceSha256 = $Script:Hash
            }

            Save-DFeNFComFiscalData @params
            Save-DFeNFComFiscalData @params

            $countParams = @{
                Sql        = 'SELECT COUNT(*) FROM dfe_nfcom_item WHERE chave_acesso = @key;'
                Parameters = @{ '@key' = $Script:Key }
            }

            [int](Get-TestScalar @countParams) | Should -Be 1
        }

        It 'Persists IBS/CBS values when present and removes them on replacement' {
            $data   = New-NFComProjection -WithIBSCBS
            $params = @{
                Cnpj         = $Script:Cnpj
                FiscalData   = $data
                SourceSha256 = $Script:Hash
            }

            Save-DFeNFComFiscalData @params

            $cstParams = @{
                Sql        = 'SELECT cst FROM dfe_nfcom_item_ibscbs WHERE chave_acesso = @key;'
                Parameters = @{ '@key' = $Script:Key }
            }

            $vbcParams = @{
                Sql        = 'SELECT vbc FROM dfe_nfcom_item_ibscbs WHERE chave_acesso = @key;'
                Parameters = @{ '@key' = $Script:Key }
            }

            $cbsParams = @{
                Sql        = 'SELECT cbs_vcbs FROM dfe_nfcom_item_ibscbs WHERE chave_acesso = @key;'
                Parameters = @{ '@key' = $Script:Key }
            }

            Get-TestScalar @cstParams            | Should -Be '000'
            [decimal](Get-TestScalar @vbcParams) | Should -Be ([decimal]'222.76')
            [decimal](Get-TestScalar @cbsParams) | Should -Be ([decimal]'2.00')

            # Recreate the projection without IBS/CBS - PSCustomObject property
            # assignment is not reliable across PowerShell versions.
            $params.FiscalData = New-NFComProjection

            Save-DFeNFComFiscalData @params

            $countParams = @{
                Sql        = 'SELECT COUNT(*) FROM dfe_nfcom_item_ibscbs WHERE chave_acesso = @key;'
                Parameters = @{ '@key' = $Script:Key }
            }

            [int](Get-TestScalar @countParams) | Should -Be 0
        }

        It 'Rejects a source SHA-256 mismatch without changing persisted data' {
            $data   = New-NFComProjection -VNF ([decimal]'9.99')
            $params = @{
                Cnpj         = $Script:Cnpj
                FiscalData   = $data
                SourceSha256 = 'b' * 64
            }

            { Save-DFeNFComFiscalData @params } | Should -Throw

            $vnfParams = @{
                Sql        = 'SELECT vnf FROM dfe_nfcom_total WHERE chave_acesso = @key;'
                Parameters = @{ '@key' = $Script:Key }
            }

            [decimal](Get-TestScalar @vnfParams) | Should -Be ([decimal]'222.76')
        }

        It 'Rolls back all changes when a mid-write SQLite error occurs' {
            $data   = New-NFComProjection -VNF ([decimal]'9.99')
            $params = @{
                Cnpj         = $Script:Cnpj
                FiscalData   = $data
                SourceSha256 = $Script:Hash
            }

            $triggerSql = @'
CREATE TRIGGER fail_nfcom_item_insert
BEFORE INSERT ON dfe_nfcom_item
BEGIN
    SELECT RAISE(ABORT, 'simulated NFCom insert failure');
END;
'@

            Invoke-TestNonQuery -Sql $triggerSql

            try {
                { Save-DFeNFComFiscalData @params } | Should -Throw

                $vnfParams = @{
                    Sql        = 'SELECT vnf FROM dfe_nfcom_total WHERE chave_acesso = @key;'
                    Parameters = @{ '@key' = $Script:Key }
                }

                $itemParams = @{
                    Sql        = 'SELECT COUNT(*) FROM dfe_nfcom_item WHERE chave_acesso = @key;'
                    Parameters = @{ '@key' = $Script:Key }
                }

                [decimal](Get-TestScalar @vnfParams) | Should -Be ([decimal]'222.76')
                [int](Get-TestScalar @itemParams)  | Should -Be 1
            } finally {
                Invoke-TestNonQuery -Sql 'DROP TRIGGER IF EXISTS fail_nfcom_item_insert;'
            }
        }
    }
}
