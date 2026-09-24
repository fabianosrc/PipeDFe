#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Integration tests for Save-DFeNFeFiscalData.

.DESCRIPTION
Verifies that Save-DFeNFeFiscalData persists a normalized NF-e/NFC-e fiscal
projection atomically in the schema v4 company index.

The suite intentionally tests the Store layer in isolation. FiscalData objects
are built directly instead of being produced by Get-DFeNFeFiscalData, so parser
failures cannot mask persistence failures.

Coverage includes:
- Complete NF-e persistence: aggregate root, provenance, participants, items,
  representative item-tax mappings, decimal TEXT storage, SQLite NULL
  semantics, totals, IBSCBSTot, RetTrib.
- UTC normalization of extraction timestamps.
- NFC-e persistence without a destinatario.
- Full projection replacement: idempotency, cascade removal of absent rows.
- Source consistency guards: case-insensitive SHA-256 matching and
  normalization, mismatch, model mismatch, missing document.
- Fiscal object validation: PSTypeName, schema version, empty/invalid item
  collections, duplicate item numbers.
- Transaction rollback: projection restored on mid-write SQLite error.
- Company isolation: persistence scoped to the target CNPJ database.
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
    $moduleRoot = (Get-Item -LiteralPath $PSScriptRoot).Parent.Parent.Parent.Parent.FullName

    $moduleName = [System.IO.Path]::Combine($moduleRoot, 'PipeDFe.psd1')

    Import-Module -Name $moduleName -Force -Global -ErrorAction Stop
}

Describe 'Save-DFeNFeFiscalData' -Tag 'Integration' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            $Script:OriginalLocalAppData = $env:LOCALAPPDATA

            $testId = [guid]::NewGuid().ToString('N')

            $Script:TempRootPath = [System.IO.Path]::Combine(
                [System.IO.Path]::GetTempPath(),
                'PipeDFe.Tests-{0}' -f $testId
            )

            $newItemParams = @{
                Path        = $Script:TempRootPath
                ItemType    = 'Directory'
                Force       = $true
                ErrorAction = 'Stop'
            }

            New-Item @newItemParams | Out-Null

            $env:LOCALAPPDATA = $Script:TempRootPath

            $Script:Cnpj      = '12345678000199'
            $Script:OtherCnpj = '98765432000188'

            $Script:AccessKey = '35260912345678000199550010000001231123456789'
            $Script:NfceKey   = '35260912345678000199650010000004561123456780'
            $Script:OtherKey  = '35260998765432000188550010000007891123456781'

            $Script:Sha256    = 'A' * 64
            $Script:OtherSha256 = 'B' * 64

            $Script:ExtractedAt = [System.DateTimeOffset]::Parse(
                '2026-09-23T22:30:00.0000000+00:00',
                [System.Globalization.CultureInfo]::InvariantCulture
            )

            #region SQLite Helpers
            function Open-TestConnection {
                [CmdletBinding()]
                [OutputType([System.Data.SQLite.SQLiteConnection])]
                param (
                    [Parameter(Mandatory)]
                    [string]$Path
                )

                $connection = Open-SqliteConnection -Path $Path
                $pragma = $connection.CreateCommand()

                try {
                    $pragma.CommandText = 'PRAGMA foreign_keys = ON;'
                    $pragma.ExecuteNonQuery() | Out-Null
                } finally {
                    $pragma.Dispose()
                }

                $connection
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

                $connection = Open-TestConnection -Path $Path
                $command = $connection.CreateCommand()

                try {
                    $command.CommandText = $Sql

                    foreach ($name in $Parameters.Keys) {
                        $value = $Parameters[$name]

                        if ($null -eq $value) {
                            $value = [System.DBNull]::Value
                        }

                        $command.Parameters.AddWithValue($name, $value) | Out-Null
                    }

                    $command.ExecuteNonQuery() | Out-Null
                } finally {
                    $command.Dispose()
                    $connection.Dispose()
                }
            }

            function Invoke-TestScalar {
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

                $connection = Open-TestConnection -Path $Path
                $command = $connection.CreateCommand()

                try {
                    $command.CommandText = $Sql

                    foreach ($name in $Parameters.Keys) {
                        $value = $Parameters[$name]

                        if ($null -eq $value) {
                            $value = [System.DBNull]::Value
                        }

                        $command.Parameters.AddWithValue($name, $value) | Out-Null
                    }

                    $command.ExecuteScalar()
                } finally {
                    $command.Dispose()
                    $connection.Dispose()
                }
            }

            function Invoke-TestRow {
                [CmdletBinding()]
                [OutputType([pscustomobject])]
                param (
                    [Parameter(Mandatory)]
                    [string]$Path,

                    [Parameter(Mandatory)]
                    [string]$Sql,

                    [Parameter()]
                    [hashtable]$Parameters = @{}
                )

                $connection = Open-TestConnection -Path $Path
                $command = $connection.CreateCommand()

                try {
                    $command.CommandText = $Sql

                    foreach ($name in $Parameters.Keys) {
                        $value = $Parameters[$name]

                        if ($null -eq $value) {
                            $value = [System.DBNull]::Value
                        }

                        $command.Parameters.AddWithValue($name, $value) | Out-Null
                    }

                    $reader = $command.ExecuteReader()

                    try {
                        if (-not $reader.Read()) {
                            return
                        }

                        $row = [ordered]@{}

                        for ($i = 0; $i -lt $reader.FieldCount; $i++) {
                            $name = $reader.GetName($i)
                            $value = $reader.GetValue($i)

                            if ($value -is [System.DBNull]) {
                                $value = $null
                            }

                            $row[$name] = $value
                        }

                        [pscustomobject]$row
                    } finally {
                        $reader.Dispose()
                    }
                } finally {
                    $command.Dispose()
                    $connection.Dispose()
                }
            }
            #endregion

            #region Fiscal Data Factories
            function New-TestParticipant {
                [CmdletBinding()]
                [OutputType([pscustomobject])]
                param (
                    [Parameter(Mandatory)]
                    [string]$Name,

                    [Parameter()]
                    [string]$Cnpj,

                    [Parameter()]
                    [string]$Cpf,

                    [Parameter()]
                    [string]$IndIe
                )

                [pscustomobject]@{
                    Cnpj         = $Cnpj
                    Cpf          = $Cpf
                    RazaoSocial  = $Name
                    NomeFantasia = "$Name Fantasia"
                    IE           = '123456789'
                    IndIEDest    = $IndIe
                    CRT          = '3'
                    Email        = 'fiscal@example.test'
                    Endereco     = [pscustomobject]@{
                        Logradouro      = 'Rua Fiscal'
                        Numero          = '100'
                        Complemento     = 'Sala 1'
                        Bairro          = 'Centro'
                        CodigoMunicipio = '3550308'
                        Municipio       = 'Sao Paulo'
                        UF              = 'SP'
                        CEP             = '01001000'
                        CodigoPais      = '1058'
                        Pais            = 'Brasil'
                        Telefone        = '1133334444'
                    }
                }
            }

            function New-TestFiscalData {
                [CmdletBinding()]
                [OutputType([pscustomobject])]
                param (
                    [Parameter()]
                    [ValidateSet(55, 65)]
                    [int]$Modelo = 55,

                    [Parameter()]
                    [string]$ChaveAcesso = $Script:AccessKey,

                    [Parameter()]
                    [bool]$IncludeDestinatario = $true,

                    [Parameter()]
                    [bool]$IncludeSecondItem = $true
                )

                $emitenteParams = @{
                    Name = 'Emitente Teste Ltda'
                    Cnpj = '12345678000199'
                }

                $emitente = New-TestParticipant @emitenteParams

                $destinatario = if ($IncludeDestinatario) {
                    $destinatarioParams = @{
                        Name  = 'Destinatario Teste Ltda'
                        Cnpj  = '99887766000155'
                        IndIe = '1'
                    }

                    New-TestParticipant @destinatarioParams
                } else {
                    $null
                }

                $items = [System.Collections.Generic.List[pscustomobject]]::new()

                #region Item 1
                $item1 = [pscustomobject]@{
                    Numero   = 1
                    Produto  = [pscustomobject]@{
                        Codigo            = 'PROD-001'
                        EAN               = '7890000000001'
                        Descricao         = 'Produto fiscal 1'
                        NCM               = '84713012'
                        CEST              = '2100100'
                        CFOP              = '5102'
                        Unidade           = 'UN'
                        Quantidade        = [decimal]'2.5000'
                        ValorUnitario     = [decimal]'10.123456789'
                        ValorProduto      = [decimal]'25.3086419725'
                        EANTrib           = '7890000000001'
                        UnidadeTrib       = 'UN'
                        QuantidadeTrib    = [decimal]'2.5000'
                        ValorUnitarioTrib = [decimal]'10.123456789'
                        ValorFrete        = [decimal]'1.10'
                        ValorSeguro       = [decimal]'0.20'
                        ValorDesconto     = [decimal]'0.30'
                        OutrasDespesas    = [decimal]'0.40'
                        IndTotal          = '1'
                    }

                    Tributos = [pscustomobject]@{
                        ICMS   = [pscustomobject]@{
                            Grupo      = 'ICMS00'
                            Orig       = '0'
                            CST        = '00'
                            CSOSN      = $null
                            ModBC      = '3'
                            VBC        = [decimal]'25.3086419725'
                            PRedBC     = $null
                            PICMS      = [decimal]'18.0000'
                            VICMS      = [decimal]'4.5555555551'
                            ModBCST    = $null
                            PMVAST     = $null
                            PRedBCST   = $null
                            VBCST      = $null
                            PICMSST    = $null
                            VICMSST    = $null
                            VICMSDeson = $null
                            MotDesICMS = $null
                            VBCFCP     = [decimal]'25.3086419725'
                            PFCP       = [decimal]'2.0000'
                            VFCP       = [decimal]'0.5061728395'
                            VBCFCPST   = $null
                            PFCPST     = $null
                            VFCPST     = $null
                        }

                        IPI    = [pscustomobject]@{
                            Grupo = 'IPITrib'
                            CEnq  = '999'
                            CST   = '50'
                            VBC   = [decimal]'25.3086419725'
                            PIPI  = [decimal]'5.0000'
                            QUnid = $null
                            VUnid = $null
                            VIPI  = [decimal]'1.2654320986'
                        }

                        PIS    = [pscustomobject]@{
                            Grupo     = 'PISAliq'
                            CST       = '01'
                            VBC       = [decimal]'25.3086419725'
                            PPIS      = [decimal]'1.6500'
                            QBCProd   = $null
                            VAliqProd = $null
                            VPIS      = [decimal]'0.4175925925'
                        }

                        COFINS = [pscustomobject]@{
                            Grupo     = 'COFINSAliq'
                            CST       = '01'
                            VBC       = [decimal]'25.3086419725'
                            PCOFINS   = [decimal]'7.6000'
                            QBCProd   = $null
                            VAliqProd = $null
                            VCOFINS   = [decimal]'1.9234567899'
                        }

                        IBSCBS = [pscustomobject]@{
                            CST        = '000'
                            CClassTrib = '000001'
                            VBC        = [decimal]'25.3086419725'
                            PIBSUF     = [decimal]'0.1000'
                            VIBSUF     = [decimal]'0.0253086420'
                            PIBSMun    = [decimal]'0.0000'
                            VIBSMun    = [decimal]'0.0000000000'
                            VIBS       = [decimal]'0.0253086420'
                            PCBS       = [decimal]'0.9000'
                            VCBS       = [decimal]'0.2277777778'
                        }
                    }
                }

                $items.Add($item1)
                #endregion

                #region Item 2
                if ($IncludeSecondItem) {
                    $item2 = [pscustomobject]@{
                        Numero   = 2

                        Produto  = [pscustomobject]@{
                            Codigo            = 'PROD-002'
                            EAN               = $null
                            Descricao         = 'Produto fiscal 2'
                            NCM               = '39269090'
                            CEST              = $null
                            CFOP              = '6108'
                            Unidade           = 'UN'
                            Quantidade        = [decimal]'1.0000'
                            ValorUnitario     = [decimal]'50.00'
                            ValorProduto      = [decimal]'50.00'
                            EANTrib           = $null
                            UnidadeTrib       = 'UN'
                            QuantidadeTrib    = [decimal]'1.0000'
                            ValorUnitarioTrib = [decimal]'50.00'
                            ValorFrete        = $null
                            ValorSeguro       = $null
                            ValorDesconto     = $null
                            OutrasDespesas    = $null
                            IndTotal          = '1'
                        }

                        Tributos = [pscustomobject]@{
                            ICMS   = $null
                            IPI    = $null
                            PIS    = $null
                            COFINS = $null
                            IBSCBS = $null
                        }
                    }

                    $items.Add($item2)
                }
                #endregion

                $fiscalModel = if ($Modelo -eq 55) {
                    [ModeloDFe]::NFe
                } else {
                    [ModeloDFe]::NFCe
                }

                [pscustomobject]@{
                    PSTypeName    = 'PipeDFe.Fiscal.NFeDocument'
                    SchemaVersion = 1
                    Modelo        = $fiscalModel
                    ChaveAcesso   = $ChaveAcesso
                    Identificacao = [pscustomobject]@{
                        CUF                        = '35'
                        NaturezaOperacao           = 'VENDA'
                        Modelo                     = [string]$Modelo
                        Serie                      = '1'
                        Numero                     = '123'
                        DhEmi                      = '2026-09-23T18:30:00-03:00'
                        DhSaiEnt                   = '2026-09-23T18:35:00-03:00'
                        TipoOperacao               = '1'
                        IdDestino                  = '1'
                        CodigoMunicipioFatoGerador = '3550308'
                        TipoImpressao              = '1'
                        TipoEmissao                = '1'
                        Finalidade                 = '1'
                        ConsumidorFinal            = '1'
                        IndicadorPresenca          = '1'
                    }

                    Emitente       = $emitente
                    Destinatario   = $destinatario
                    Totais         = [pscustomobject]@{
                        VBC        = [decimal]'75.3086419725'
                        VICMS      = [decimal]'4.5555555551'
                        VICMSDeson = [decimal]'0.00'
                        VFCP       = [decimal]'0.5061728395'
                        VBCST      = [decimal]'0.00'
                        VST        = [decimal]'0.00'
                        VFCPST     = [decimal]'0.00'
                        VFCPSTRet  = [decimal]'0.00'
                        VProd      = [decimal]'75.3086419725'
                        VFrete     = [decimal]'1.10'
                        VSeg       = [decimal]'0.20'
                        VDesc      = [decimal]'0.30'
                        VII        = [decimal]'0.00'
                        VIPI       = [decimal]'1.2654320986'
                        VIPIDevol  = [decimal]'0.00'
                        VPIS       = [decimal]'0.4175925925'
                        VCOFINS    = [decimal]'1.9234567899'
                        VOutro     = [decimal]'0.40'
                        VNF        = [decimal]'77.9740740711'
                        VTotTrib   = [decimal]'8.8955386574'
                        IBSCBSTot  = [pscustomobject]@{
                            VBCIBSCbs           = [decimal]'75.3086419725'
                            VIBSUF              = [decimal]'0.0753086420'
                            VDifIBSUF           = [decimal]'0.00'
                            VDevTribIBSUF       = [decimal]'0.00'
                            VIBSMun             = [decimal]'0.00'
                            VDifIBSMun          = [decimal]'0.00'
                            VDevTribIBSMun      = [decimal]'0.00'
                            VIBS                = [decimal]'0.0753086420'
                            VCredPres           = [decimal]'0.01'
                            VCredPresCondSus    = [decimal]'0.02'
                            VCBS                = [decimal]'0.6777777778'
                            VDifCBS             = [decimal]'0.03'
                            VDevTribCBS         = [decimal]'0.04'
                            VCredPresCBS        = [decimal]'0.05'
                            VCredPresCondSusCBS = [decimal]'0.06'
                        }

                        RetTrib    = [pscustomobject]@{
                            VRetCSLL = [decimal]'1.11'
                            VBCIrrf  = [decimal]'10.00'
                            VIrrf    = [decimal]'1.50'
                        }
                    }

                    Itens         = $items.ToArray()
                }
            }
            #endregion

            #region Document Helpers
            function Reset-TestDocument {
                [CmdletBinding()]
                [OutputType([void])]
                param (
                    [Parameter(Mandatory)]
                    [string]$Path,

                    [Parameter(Mandatory)]
                    [string]$Chave,

                    [Parameter()]
                    [ValidateSet(55, 65)]
                    [int]$Modelo = 55,

                    [Parameter()]
                    [string]$Sha256 = $Script:Sha256
                )

                $deleteParams = @{
                    Path       = $Path
                    Sql        = 'DELETE FROM dfe_document WHERE chave_acesso = @chave;'
                    Parameters = @{ '@chave' = $Chave }
                }

                Invoke-TestNonQuery @deleteParams

                $insertParams = @{
                    Path       = $Path
                    Sql        = @'
INSERT INTO dfe_document (
    chave_acesso,
    modelo,
    file_path,
    is_proc,
    ndoc,
    serie,
    dh_emi,
    sha256,
    indexed_at,
    processing_status,
    processing_started_at,
    processed_at,
    processing_error
) VALUES (
    @chave,
    @modelo,
    @file_path,
    1,
    123,
    '1',
    '2026-09-23T21:30:00.0000000Z',
    @sha256,
    '2026-09-23T21:35:00.0000000Z',
    'Processing',
    '2026-09-23T21:36:00.0000000Z',
    NULL,
    NULL
);
'@
                    Parameters = @{
                        '@chave'     = $Chave
                        '@modelo'    = $Modelo
                        '@file_path' = 'C:\Fiscal\documento.xml'
                        '@sha256'    = $Sha256
                    }
                }

                Invoke-TestNonQuery @insertParams
            }
            #endregion

            #region Database Initialization
            $Script:DbPath = Initialize-DFeIndex -Cnpj $Script:Cnpj

            $Script:OtherDbPath = Initialize-DFeIndex -Cnpj $Script:OtherCnpj
            #endregion Database Initialization
        }

        AfterAll {

            $env:LOCALAPPDATA = $Script:OriginalLocalAppData

            if (Test-Path -LiteralPath $Script:TempRootPath) {
                $removeItemParams = @{
                    LiteralPath = $Script:TempRootPath
                    Recurse     = $true
                    Force       = $true
                    ErrorAction = 'SilentlyContinue'
                }

                Remove-Item @removeItemParams
            }
        }

        BeforeEach {

            $resetDocumentParams = @{
                Path   = $Script:DbPath
                Chave  = $Script:AccessKey
                Modelo = 55
                Sha256 = $Script:Sha256
            }

            Reset-TestDocument @resetDocumentParams

            $dropTriggerParams = @{
                Path = $Script:DbPath
                Sql  = 'DROP TRIGGER IF EXISTS test_fail_nfe_item_insert;'
            }

            Invoke-TestNonQuery @dropTriggerParams
        }
        #endregion

        #region Complete NF-e Persistence
        Context 'Complete NF-e persistence' {

            BeforeEach {
                $Script:FiscalData = New-TestFiscalData

                $saveParams = @{
                    Cnpj         = $Script:Cnpj
                    FiscalData   = $Script:FiscalData
                    SourceSha256 = $Script:Sha256
                    ExtractedAt  = $Script:ExtractedAt
                }

                Save-DFeNFeFiscalData @saveParams
            }

            It 'Persists the fiscal aggregate root and extraction provenance' {
                $queryParams = @{
                    Path       = $Script:DbPath
                    Sql        = @'
SELECT
    chave_acesso,
    schema_version,
    source_sha256,
    extracted_at,
    modelo,
    uf_emissao,
    natureza_operacao,
    serie,
    numero,
    emitido_em
FROM dfe_nfe
WHERE chave_acesso = @chave;
'@
                    Parameters = @{
                        '@chave' = $Script:AccessKey
                    }
                }

                $row = Invoke-TestRow @queryParams

                $row.chave_acesso        | Should -Be $Script:AccessKey

                [int]$row.schema_version | Should -Be 1

                $row.source_sha256       | Should -Be $Script:Sha256
                $row.extracted_at        | Should -Be ($Script:ExtractedAt.ToUniversalTime().ToString('o'))

                [int]$row.modelo         | Should -Be 55

                $row.uf_emissao          | Should -Be '35'
                $row.natureza_operacao   | Should -Be 'VENDA'
                $row.numero              | Should -Be '123'
                $row.emitido_em          | Should -Be '2026-09-23T18:30:00-03:00'
            }

            It 'Normalizes ExtractedAt to UTC before persistence' {
                $offsetTimestamp = [System.DateTimeOffset]::Parse(
                    '2026-09-23T19:30:00.0000000-03:00',
                    [System.Globalization.CultureInfo]::InvariantCulture
                )

                $data = New-TestFiscalData

                $saveParams = @{
                    Cnpj         = $Script:Cnpj
                    FiscalData   = $data
                    SourceSha256 = $Script:Sha256
                    ExtractedAt  = $offsetTimestamp
                }

                Save-DFeNFeFiscalData @saveParams

                $queryParams = @{
                    Path       = $Script:DbPath
                    Sql        = @'
SELECT extracted_at
FROM dfe_nfe
WHERE chave_acesso = @chave;
'@
                    Parameters = @{
                        '@chave' = $Script:AccessKey
                    }
                }

                $row = Invoke-TestRow @queryParams

                $row.extracted_at |
                    Should -Be ($offsetTimestamp.ToUniversalTime().ToString('o'))
            }

            It 'Persists emitente and destinatario' {
                $queryParams = @{
                    Path       = $Script:DbPath
                    Sql        = @'
SELECT COUNT(*)
FROM dfe_nfe_participante
WHERE chave_acesso = @chave;
'@
                    Parameters = @{
                        '@chave' = $Script:AccessKey
                    }
                }

                [int](Invoke-TestScalar @queryParams) | Should -Be 2
            }

            It 'Persists all fiscal items' {
                $queryParams = @{
                    Path       = $Script:DbPath
                    Sql        = 'SELECT COUNT(*) FROM dfe_nfe_item WHERE chave_acesso = @chave;'
                    Parameters = @{ '@chave' = $Script:AccessKey }
                }

                [int](Invoke-TestScalar @queryParams) | Should -Be 2
            }

            It 'Preserves item codes and normalized fiscal values' {
                $queryParams = @{
                    Path       = $Script:DbPath
                    Sql        = @'
SELECT
    cod_produto,
    ncm,
    cfop,
    qte_comercial,
    vlr_unitario,
    vlr_produto,
    ind_compoe_total
FROM dfe_nfe_item
WHERE chave_acesso = @chave
  AND n_item = 1;
'@
                    Parameters = @{
                        '@chave' = $Script:AccessKey
                    }
                }

                $row = Invoke-TestRow @queryParams

                $row.cod_produto      | Should -Be 'PROD-001'
                $row.ncm              | Should -Be '84713012'
                $row.cfop             | Should -Be '5102'
                $row.qte_comercial    | Should -Be ([decimal]'2.5000')
                $row.vlr_unitario     | Should -Be '10.123456789'
                $row.vlr_produto      | Should -Be '25.3086419725'
                $row.ind_compoe_total | Should -Be '1'
            }

            It 'Stores Decimal values as SQLite TEXT' {
                $queryParams = @{
                    Path       = $Script:DbPath
                    Sql        = @'
SELECT
    typeof(qte_comercial) AS qte_type,
    typeof(vlr_unitario) AS unit_type,
    typeof(vlr_produto) AS product_type
FROM dfe_nfe_item
WHERE chave_acesso = @chave
  AND n_item = 1;
'@
                    Parameters = @{
                        '@chave' = $Script:AccessKey
                    }
                }

                $row = Invoke-TestRow @queryParams

                $row.qte_type     | Should -Be 'text'
                $row.unit_type    | Should -Be 'text'
                $row.product_type | Should -Be 'text'
            }

            It 'Stores absent optional fiscal values as SQLite NULL' {
                $itemQueryParams = @{
                    Path       = $Script:DbPath
                    Sql        = @'
SELECT
    typeof(cest) AS cest_type,
    typeof(vlr_frete) AS freight_type,
    typeof(vlr_seguro) AS insurance_type
FROM dfe_nfe_item
WHERE chave_acesso = @chave
  AND n_item = 2;
'@
                    Parameters = @{
                        '@chave' = $Script:AccessKey
                    }
                }

                $itemRow = Invoke-TestRow @itemQueryParams

                $itemRow.cest_type      | Should -Be 'null'
                $itemRow.freight_type   | Should -Be 'null'
                $itemRow.insurance_type | Should -Be 'null'

                $icmsQueryParams = @{
                    Path       = $Script:DbPath
                    Sql        = @'
SELECT
    typeof(csosn) AS csosn_type,
    typeof(modalidade_bc_st) AS bc_st_type
FROM dfe_nfe_item_icms
WHERE chave_acesso = @chave
  AND n_item = 1;
'@
                    Parameters = @{
                        '@chave' = $Script:AccessKey
                    }
                }

                $icmsRow = Invoke-TestRow @icmsQueryParams

                $icmsRow.csosn_type | Should -Be 'null'
                $icmsRow.bc_st_type | Should -Be 'null'
            }

            It 'Persists ICMS, IPI, PIS, COFINS and IBS/CBS item groups' {
                $tables = @(
                    'dfe_nfe_item_icms'
                    'dfe_nfe_item_ipi'
                    'dfe_nfe_item_pis'
                    'dfe_nfe_item_cofins'
                    'dfe_nfe_item_ibscbs'
                )

                foreach ($table in $tables) {
                    $queryParams = @{
                        Path       = $Script:DbPath
                        Sql        = "SELECT COUNT(*) FROM $table WHERE chave_acesso = @chave AND n_item = 1;"
                        Parameters = @{ '@chave' = $Script:AccessKey }
                    }

                    $count = Invoke-TestScalar @queryParams

                    [int]$count | Should -Be 1 -Because ("item 1 must be persisted in '$table'")
                }
            }

            It 'Maps representative values for each item tax group' {
                $icms = Invoke-TestRow -Path $Script:DbPath -Sql @'
SELECT grupo, origem, cst, pct_icms, vlr_icms
FROM dfe_nfe_item_icms
WHERE chave_acesso = @chave
  AND n_item = 1;
'@ -Parameters @{ '@chave' = $Script:AccessKey }

                $icms.grupo    | Should -Be 'ICMS00'
                $icms.origem   | Should -Be '0'
                $icms.cst      | Should -Be '00'
                $icms.pct_icms | Should -Be ([decimal]'18.0000')
                $icms.vlr_icms | Should -Be '4.5555555551'

                $ipi = Invoke-TestRow -Path $Script:DbPath -Sql @'
SELECT grupo, enquadramento, cst, pct_ipi, vlr_ipi
FROM dfe_nfe_item_ipi
WHERE chave_acesso = @chave
  AND n_item = 1;
'@ -Parameters @{ '@chave' = $Script:AccessKey }

                $ipi.grupo         | Should -Be 'IPITrib'
                $ipi.enquadramento | Should -Be '999'
                $ipi.cst           | Should -Be '50'
                $ipi.pct_ipi       | Should -Be ([decimal]'5.0000')
                $ipi.vlr_ipi       | Should -Be '1.2654320986'

                $pis = Invoke-TestRow -Path $Script:DbPath -Sql @'
SELECT grupo, cst, pct_pis, vlr_pis
FROM dfe_nfe_item_pis
WHERE chave_acesso = @chave
  AND n_item = 1;
'@ -Parameters @{ '@chave' = $Script:AccessKey }

                $pis.grupo   | Should -Be 'PISAliq'
                $pis.cst     | Should -Be '01'
                $pis.pct_pis | Should -Be ([decimal]'1.6500')
                $pis.vlr_pis | Should -Be '0.4175925925'

                $cofins = Invoke-TestRow -Path $Script:DbPath -Sql @'
SELECT grupo, cst, pct_cofins, vlr_cofins
FROM dfe_nfe_item_cofins
WHERE chave_acesso = @chave
  AND n_item = 1;
'@ -Parameters @{ '@chave' = $Script:AccessKey }

                $cofins.grupo      | Should -Be 'COFINSAliq'
                $cofins.cst        | Should -Be '01'
                $cofins.pct_cofins | Should -Be ([decimal]'7.6000')
                $cofins.vlr_cofins | Should -Be '1.9234567899'

                $ibscbs = Invoke-TestRow -Path $Script:DbPath -Sql @'
SELECT cst, classificacao_tributaria, pct_ibs_uf, vlr_cbs
FROM dfe_nfe_item_ibscbs
WHERE chave_acesso = @chave
  AND n_item = 1;
'@ -Parameters @{ '@chave' = $Script:AccessKey }

                $ibscbs.cst                      | Should -Be '000'
                $ibscbs.classificacao_tributaria | Should -Be '000001'
                $ibscbs.pct_ibs_uf               | Should -Be ([decimal]'0.1000')
                $ibscbs.vlr_cbs                  | Should -Be '0.2277777778'
            }

            It 'Persists document totals' {
                $tables = @(
                    'dfe_nfe_total_icms'
                    'dfe_nfe_total_ibscbs'
                    'dfe_nfe_total_rettrib'
                )

                foreach ($table in $tables) {
                    $queryParams = @{
                        Path       = $Script:DbPath
                        Sql        = "SELECT COUNT(*) FROM $table WHERE chave_acesso = @chave;"
                        Parameters = @{ '@chave' = $Script:AccessKey }
                    }

                    [int](Invoke-TestScalar @queryParams) | Should -Be 1
                }
            }

            It 'Persists conditional presumed credits with cond_sus naming' {
                $queryParams = @{
                    Path       = $Script:DbPath
                    Sql        = @'
SELECT
    vlr_credito_presumido_cond_sus_ibs,
    vlr_credito_presumido_cond_sus_cbs
FROM dfe_nfe_total_ibscbs
WHERE chave_acesso = @chave;
'@
                    Parameters = @{
                        '@chave' = $Script:AccessKey
                    }
                }

                $row = Invoke-TestRow @queryParams

                $row.vlr_credito_presumido_cond_sus_ibs | Should -Be '0.02'
                $row.vlr_credito_presumido_cond_sus_cbs | Should -Be '0.06'
            }

            It 'Does not change document processing state' {
                $queryParams = @{
                    Path       = $Script:DbPath
                    Sql        = @'
SELECT
    processing_status,
    processing_started_at,
    processed_at,
    processing_error
FROM dfe_document
WHERE chave_acesso = @chave;
'@
                    Parameters = @{
                        '@chave' = $Script:AccessKey
                    }
                }

                $row = Invoke-TestRow @queryParams

                $row.processing_status     | Should -Be 'Processing'
                $row.processing_started_at | Should -Be '2026-09-23T21:36:00.0000000Z'
                $row.processed_at          | Should -BeNullOrEmpty
                $row.processing_error      | Should -BeNullOrEmpty
            }
        }
        #endregion

        #region NFC-e Persistence
        Context 'NFC-e persistence' {

            It 'Persists model 65 without a destinatario' {
                $resetDocumentParams = @{
                    Path   = $Script:DbPath
                    Chave  = $Script:NfceKey
                    Modelo = 65
                    Sha256 = $Script:Sha256
                }

                Reset-TestDocument @resetDocumentParams

                $newFiscalDataParams = @{
                    Modelo              = 65
                    ChaveAcesso         = $Script:NfceKey
                    IncludeDestinatario = $false
                    IncludeSecondItem   = $false
                }

                $data = New-TestFiscalData @newFiscalDataParams

                $saveParams = @{
                    Cnpj         = $Script:Cnpj
                    FiscalData   = $data
                    SourceSha256 = $Script:Sha256
                    ExtractedAt  = $Script:ExtractedAt
                }

                { Save-DFeNFeFiscalData @saveParams } | Should -Not -Throw

                $modelQueryParams = @{
                    Path       = $Script:DbPath
                    Sql        = @'
SELECT modelo
FROM dfe_nfe
WHERE chave_acesso = @chave;
'@
                    Parameters = @{
                        '@chave' = $Script:NfceKey
                    }
                }

                [int](Invoke-TestScalar @modelQueryParams) | Should -Be 65

                $participantQueryParams = @{
                    Path       = $Script:DbPath
                    Sql        = @'
SELECT COUNT(*)
FROM dfe_nfe_participante
WHERE chave_acesso = @chave
  AND tipo_participante = 'Destinatario';
'@
                    Parameters = @{
                        '@chave' = $Script:NfceKey
                    }
                }

                [int](Invoke-TestScalar @participantQueryParams) | Should -Be 0
            }
        }
        #endregion

        #region Full Projection Replacement
        Context 'Full projection replacement' {

            It 'Can persist the same projection repeatedly without duplicates' {
                $data = New-TestFiscalData

                $saveParams = @{
                    Cnpj         = $Script:Cnpj
                    FiscalData   = $data
                    SourceSha256 = $Script:Sha256
                    ExtractedAt  = $Script:ExtractedAt
                }

                Save-DFeNFeFiscalData @saveParams

                { Save-DFeNFeFiscalData @saveParams } | Should -Not -Throw

                $rootQueryParams = @{
                    Path       = $Script:DbPath
                    Sql        = 'SELECT COUNT(*) FROM dfe_nfe WHERE chave_acesso = @chave;'
                    Parameters = @{ '@chave' = $Script:AccessKey }
                }

                [int](Invoke-TestScalar @rootQueryParams) | Should -Be 1

                $itemQueryParams = @{
                    Path       = $Script:DbPath
                    Sql        = 'SELECT COUNT(*) FROM dfe_nfe_item WHERE chave_acesso = @chave;'
                    Parameters = @{ '@chave' = $Script:AccessKey }
                }

                [int](Invoke-TestScalar @itemQueryParams) | Should -Be 2
            }

            It 'Removes child rows absent from the replacement projection' {
                $original = New-TestFiscalData

                $saveOriginalParams = @{
                    Cnpj         = $Script:Cnpj
                    FiscalData   = $original
                    SourceSha256 = $Script:Sha256
                    ExtractedAt  = $Script:ExtractedAt
                }

                Save-DFeNFeFiscalData @saveOriginalParams

                $replacement = New-TestFiscalData -IncludeSecondItem $false

                $replacement.Itens[0].Tributos.IPI = $null
                $replacement.Itens[0].Tributos.PIS = $null

                $saveReplacementParams = @{
                    Cnpj         = $Script:Cnpj
                    FiscalData   = $replacement
                    SourceSha256 = $Script:Sha256
                    ExtractedAt  = $Script:ExtractedAt
                }

                Save-DFeNFeFiscalData @saveReplacementParams

                $itemQueryParams = @{
                    Path       = $Script:DbPath
                    Sql        = 'SELECT COUNT(*) FROM dfe_nfe_item WHERE chave_acesso = @chave;'
                    Parameters = @{ '@chave' = $Script:AccessKey }
                }

                [int](Invoke-TestScalar @itemQueryParams) | Should -Be 1

                $ipiQueryParams = @{
                    Path       = $Script:DbPath
                    Sql        = 'SELECT COUNT(*) FROM dfe_nfe_item_ipi WHERE chave_acesso = @chave;'
                    Parameters = @{ '@chave' = $Script:AccessKey }
                }

                [int](Invoke-TestScalar @ipiQueryParams) | Should -Be 0

                $pisQueryParams = @{
                    Path       = $Script:DbPath
                    Sql        = 'SELECT COUNT(*) FROM dfe_nfe_item_pis WHERE chave_acesso = @chave;'
                    Parameters = @{ '@chave' = $Script:AccessKey }
                }

                [int](Invoke-TestScalar @pisQueryParams) | Should -Be 0
            }
        }
        #endregion

        #region Source Consistency Guards
        Context 'Source consistency guards' {

            It 'Accepts SourceSha256 case-insensitively and stores it normalized' {
                $data = New-TestFiscalData
                $lowercaseSha = $Script:Sha256.ToLowerInvariant()

                $saveParams = @{
                    Cnpj         = $Script:Cnpj
                    FiscalData   = $data
                    SourceSha256 = $lowercaseSha
                    ExtractedAt  = $Script:ExtractedAt
                }

                Save-DFeNFeFiscalData @saveParams

                $queryParams = @{
                    Path       = $Script:DbPath
                    Sql        = @'
SELECT source_sha256
FROM dfe_nfe
WHERE chave_acesso = @chave;
'@
                    Parameters = @{
                        '@chave' = $Script:AccessKey
                    }
                }

                $row = Invoke-TestRow @queryParams

                $row.source_sha256 | Should -Be $Script:Sha256
            }

            It 'Rejects a fiscal projection when source SHA-256 differs' {
                $data = New-TestFiscalData

                $saveParams = @{
                    Cnpj         = $Script:Cnpj
                    FiscalData   = $data
                    SourceSha256 = $Script:OtherSha256
                    ExtractedAt  = $Script:ExtractedAt
                }

                { Save-DFeNFeFiscalData @saveParams } |
                    Should -Throw -ErrorId 'NFeFiscalSourceHashMismatch*'
            }

            It 'Does not persist rows after a SHA-256 mismatch' {
                $data = New-TestFiscalData

                $saveParams = @{
                    Cnpj         = $Script:Cnpj
                    FiscalData   = $data
                    SourceSha256 = $Script:OtherSha256
                    ExtractedAt  = $Script:ExtractedAt
                }

                try {
                    Save-DFeNFeFiscalData @saveParams
                } catch {
                    $null = $_
                }

                $queryParams = @{
                    Path       = $Script:DbPath
                    Sql        = 'SELECT COUNT(*) FROM dfe_nfe WHERE chave_acesso = @chave;'
                    Parameters = @{ '@chave' = $Script:AccessKey }
                }

                [int](Invoke-TestScalar @queryParams) | Should -Be 0
            }

            It 'Rejects a projection whose model differs from dfe_document' {
                $data = New-TestFiscalData
                $data.Modelo = [ModeloDFe]::NFCe

                $saveParams = @{
                    Cnpj         = $Script:Cnpj
                    FiscalData   = $data
                    SourceSha256 = $Script:Sha256
                    ExtractedAt  = $Script:ExtractedAt
                }

                { Save-DFeNFeFiscalData @saveParams } |
                    Should -Throw -ErrorId 'NFeFiscalSourceModelMismatch*'
            }

            It 'Rejects a projection when source document is not indexed' {
                $missingKey = '35260912345678000199550010000009991123456782'

                $newFiscalDataParams = @{
                    ChaveAcesso = $missingKey
                }

                $data = New-TestFiscalData @newFiscalDataParams

                $saveParams = @{
                    Cnpj         = $Script:Cnpj
                    FiscalData   = $data
                    SourceSha256 = $Script:Sha256
                    ExtractedAt  = $Script:ExtractedAt
                }

                { Save-DFeNFeFiscalData @saveParams } |
                    Should -Throw -ErrorId 'NFeFiscalSourceDocumentNotFound*'
            }


            It 'Preserves an existing projection after a source SHA-256 mismatch' {
                $original = New-TestFiscalData

                Save-DFeNFeFiscalData -Cnpj $Script:Cnpj -FiscalData $original `
                    -SourceSha256 $Script:Sha256 -ExtractedAt $Script:ExtractedAt

                $replacement = New-TestFiscalData
                $replacement.Identificacao.Numero = '999'

                {
                    Save-DFeNFeFiscalData -Cnpj $Script:Cnpj -FiscalData $replacement `
                        -SourceSha256 $Script:OtherSha256 -ExtractedAt $Script:ExtractedAt
                } | Should -Throw -ErrorId 'NFeFiscalSourceHashMismatch*'

                $row = Invoke-TestRow -Path $Script:DbPath -Sql @'
SELECT numero
FROM dfe_nfe
WHERE chave_acesso = @chave;
'@ -Parameters @{ '@chave' = $Script:AccessKey }

                $row.numero | Should -Be '123'
            }
        }
        #endregion

        #region Fiscal Object Validation
        Context 'Fiscal object validation' {

            It 'Rejects an object without the expected PSTypeName' {
                $data = New-TestFiscalData

                $invalid = [pscustomobject]@{
                    SchemaVersion = $data.SchemaVersion
                    Modelo        = $data.Modelo
                    ChaveAcesso   = $data.ChaveAcesso
                    Identificacao = $data.Identificacao
                    Emitente      = $data.Emitente
                    Destinatario  = $data.Destinatario
                    Totais        = $data.Totais
                    Itens         = $data.Itens
                }

                $saveParams = @{
                    Cnpj         = $Script:Cnpj
                    FiscalData   = $invalid
                    SourceSha256 = $Script:Sha256
                }

                { Save-DFeNFeFiscalData @saveParams } |
                    Should -Throw -ErrorId 'InvalidNFeFiscalDataType*'
            }

            It 'Rejects a non-positive schema version' {
                $data = New-TestFiscalData
                $data.SchemaVersion = 0

                $saveParams = @{
                    Cnpj         = $Script:Cnpj
                    FiscalData   = $data
                    SourceSha256 = $Script:Sha256
                }

                { Save-DFeNFeFiscalData @saveParams } |
                    Should -Throw -ErrorId 'InvalidNFeFiscalSchemaVersion*'
            }


            It 'Rejects an unsupported future schema version' {
                $data = New-TestFiscalData
                $data.SchemaVersion = 2

                {
                    Save-DFeNFeFiscalData -Cnpj $Script:Cnpj -FiscalData $data `
                        -SourceSha256 $Script:Sha256
                } | Should -Throw -ErrorId 'UnsupportedNFeFiscalSchemaVersion*'
            }

            It 'Rejects null elements in the item collection' {
                $data = New-TestFiscalData -IncludeSecondItem:$false
                $data.Itens = @($data.Itens[0], $null)

                {
                    Save-DFeNFeFiscalData -Cnpj $Script:Cnpj -FiscalData $data `
                        -SourceSha256 $Script:Sha256
                } | Should -Throw -ErrorId 'InvalidNFeFiscalItem*'
            }

            It 'Rejects an empty fiscal item collection' {
                $data = New-TestFiscalData -IncludeSecondItem:$false
                $data.Itens = @()

                {
                    Save-DFeNFeFiscalData -Cnpj $Script:Cnpj -FiscalData $data `
                        -SourceSha256 $Script:Sha256
                } | Should -Throw -ErrorId 'InvalidNFeFiscalItemCollection*'
            }

            It 'Rejects contract drift in nested product properties' {
                $data = New-TestFiscalData -IncludeSecondItem:$false
                $data.Itens[0].Produto.PSObject.Properties.Remove('ValorProduto')

                {
                    Save-DFeNFeFiscalData -Cnpj $Script:Cnpj -FiscalData $data `
                        -SourceSha256 $Script:Sha256
                } | Should -Throw -ErrorId 'InvalidNFeFiscalDataStructure*'
            }

            It 'Rejects a non-convertible model with the public model ErrorId' {
                $data = New-TestFiscalData
                $data.Modelo = 'not-a-model'

                {
                    Save-DFeNFeFiscalData -Cnpj $Script:Cnpj -FiscalData $data `
                        -SourceSha256 $Script:Sha256
                } | Should -Throw -ErrorId 'InvalidNFeFiscalModel*'
            }

            It 'Rejects duplicate fiscal item numbers' {
                $data = New-TestFiscalData
                $data.Itens[1].Numero = 1

                $saveParams = @{
                    Cnpj         = $Script:Cnpj
                    FiscalData   = $data
                    SourceSha256 = $Script:Sha256
                }

                { Save-DFeNFeFiscalData @saveParams } |
                    Should -Throw  -ErrorId 'DuplicateNFeFiscalItemNumber*'
            }
        }
        #endregion

        #region Transaction Rollback
        Context 'Transaction rollback' {

            It 'Restores previous projection after a mid-write SQLite error' {
                $original = New-TestFiscalData

                $saveOriginalParams = @{
                    Cnpj         = $Script:Cnpj
                    FiscalData   = $original
                    SourceSha256 = $Script:Sha256
                    ExtractedAt  = $Script:ExtractedAt
                }

                Save-DFeNFeFiscalData @saveOriginalParams

                $createTriggerParams = @{
                    Path = $Script:DbPath
                    Sql  = @'
CREATE TRIGGER test_fail_nfe_item_insert
BEFORE INSERT ON dfe_nfe_item
BEGIN
    SELECT RAISE(ABORT, 'forced test failure');
END;
'@
                }

                Invoke-TestNonQuery @createTriggerParams

                $replacement = New-TestFiscalData -IncludeSecondItem $false

                $replacement.Identificacao.Numero = '999'

                $saveReplacementParams = @{
                    Cnpj         = $Script:Cnpj
                    FiscalData   = $replacement
                    SourceSha256 = $Script:Sha256
                    ExtractedAt  = $Script:ExtractedAt
                }

                { Save-DFeNFeFiscalData @saveReplacementParams } |
                    Should -Throw -ErrorId 'NFeFiscalDataSaveFailed*'

                $rootQueryParams = @{
                    Path       = $Script:DbPath
                    Sql        = 'SELECT numero FROM dfe_nfe WHERE chave_acesso = @chave;'
                    Parameters = @{ '@chave' = $Script:AccessKey }
                }

                $row = Invoke-TestRow @rootQueryParams

                $row.numero | Should -Be '123'

                $itemQueryParams = @{
                    Path       = $Script:DbPath
                    Sql        = 'SELECT COUNT(*) FROM dfe_nfe_item WHERE chave_acesso = @chave;'
                    Parameters = @{ '@chave' = $Script:AccessKey }
                }

                [int](Invoke-TestScalar @itemQueryParams) | Should -Be 2
            }
        }
        #endregion

        #region Company Isolation
        Context 'Company isolation' {

            It 'Persists only in the target CNPJ database' {
                $resetDocumentParams = @{
                    Path   = $Script:OtherDbPath
                    Chave  = $Script:OtherKey
                    Modelo = 55
                    Sha256 = $Script:Sha256
                }

                Reset-TestDocument @resetDocumentParams

                $data = New-TestFiscalData -ChaveAcesso $Script:OtherKey

                $saveParams = @{
                    Cnpj         = $Script:OtherCnpj
                    FiscalData   = $data
                    SourceSha256 = $Script:Sha256
                    ExtractedAt  = $Script:ExtractedAt
                }

                Save-DFeNFeFiscalData @saveParams

                $targetQueryParams = @{
                    Path       = $Script:OtherDbPath
                    Sql        = 'SELECT COUNT(*) FROM dfe_nfe WHERE chave_acesso = @chave;'
                    Parameters = @{ '@chave' = $Script:OtherKey }
                }

                [int](Invoke-TestScalar @targetQueryParams) | Should -Be 1

                $otherQueryParams = @{
                    Path       = $Script:DbPath
                    Sql        = 'SELECT COUNT(*) FROM dfe_nfe WHERE chave_acesso = @chave;'
                    Parameters = @{ '@chave' = $Script:OtherKey }
                }

                [int](Invoke-TestScalar @otherQueryParams) | Should -Be 0
            }
        }
        #endregion
    }
}
