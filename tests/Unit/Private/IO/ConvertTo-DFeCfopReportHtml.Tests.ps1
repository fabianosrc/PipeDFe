#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for analytical NF-e and NFC-e report rendering.

.DESCRIPTION
Coverage includes:
  - HTML encoding of company name and special characters.
  - Separate model and direction groups.
  - Date and time formatting for issuance and cancellation.
  - Tax column header derived from CST/CSOSN presence across items.
  - ICMS code composition from Origem + CST or CSOSN.
  - Dynamic import tax columns present only when items carry values.
  - Quantity and unit value formatting with variable decimal places.
  - Declared document totals independent of item subtotals.
  - CFOP summary totals using item values, not document values.
  - Confirmed and unconfirmed cancellations excluded from active totals.
  - Indicator IndTotal rendered and triggering the composed-total column.
  - Typed counterpart identifiers formatted as CPF and CNPJ.
  - Period reversal rejected with a terminating error.
  - Formatting placeholders, commercial totals and exact column assertions.
  - Explicit zero versus absent import tax and summary values.
  - Empty item lists and mutually exclusive cancellation sections.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseShouldProcessForStateChangingFunctions',
    '',
    Justification = 'ShouldProcess has no value in test helpers.'
)]

param ()

BeforeDiscovery {
    # InModuleScope requires the module to be loaded during Discovery, because
    # that is when Context/It blocks register the test tree. Without this,
    # InModuleScope fails before BeforeAll or BeforeEach can run.
    $moduleRoot = (Get-Item -LiteralPath $PSScriptRoot).Parent.Parent.Parent.Parent.FullName

    $modulePath = Join-Path -Path $moduleRoot -ChildPath 'PipeDFe.psd1'

    Import-Module -Name $modulePath -Force -Global -ErrorAction Stop
}

Describe 'ConvertTo-DFeCfopReportHtml' -Tag 'Unit' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            #region Helpers
            function New-ReportTestItem {
                [CmdletBinding()]
                [OutputType([pscustomobject])]
                param (
                    [Parameter(Mandatory)]
                    [string]$CFOP,

                    [Parameter()]
                    [decimal]$Value = 100d,

                    [Parameter()]
                    [Nullable[decimal]]$II = $null
                )

                [PSCustomObject]@{
                    Item          = 1
                    Codigo        = '001'
                    Produto       = '<Produto>'
                    NCM           = '10063021'
                    CFOP          = $CFOP
                    IndTotal      = '1'
                    Origem        = '0'
                    CST           = $null
                    CSOSN         = '0102'
                    Quantidade    = 1d
                    Unidade       = 'UN'
                    ValorUnitario = $Value
                    ValorProduto  = $Value
                    BaseIcms      = $null
                    AliqIcms      = $null
                    Icms          = 0d
                    IcmsST        = $null
                    IPI           = $null
                    PIS           = $null
                    Cofins        = $null
                    II            = $II
                    IOF           = $null
                    BaseII        = $null
                    DespAduaneira = $null
                    IBS           = $null
                    CBS           = $null
                }
            }

            function New-ReportTestDocument {
                [CmdletBinding()]
                [OutputType([pscustomobject])]
                param (
                    [Parameter(Mandatory)]
                    [string]$Key,

                    [Parameter(Mandatory)]
                    [int]$Model,

                    [Parameter(Mandatory)]
                    [string]$Direction,

                    [Parameter(Mandatory)]
                    [decimal]$Value
                )

                [PSCustomObject]@{
                    Modelo                   = $Model
                    Direcao                  = $Direction
                    ChaveAcesso              = $Key
                    DataEmissao              = [System.DateTimeOffset]'2026-11-02T23:00:00-03:00'
                    Numero                   = '001'
                    Serie                    = '1'
                    Natureza                 = 'Operação'
                    Contraparte              = $null
                    DocumentoContraparte     = $null
                    TipoDocumentoContraparte = $null
                    Cancelada                = $false
                    CancelamentoSemConfirmar = $false
                    DataCancelamento         = $null
                    ProtocoloCancelamento    = $null
                    ValorProdutos            = 100d
                    ValorNota                = $Value
                    Tributos                 = [ordered]@{ ICMS = 0d }
                    Itens                    = @(New-ReportTestItem -CFOP '6102' -Value 100d)
                }
            }
            #endregion
        }

        BeforeEach {

            $Script:ReportParams = @{
                CompanyName = 'Empresa & Cliente'
                Cnpj        = '12345678000199'
                StartDate   = [System.DateTimeOffset]'2026-11-01T00:00:00-03:00'
                EndDate     = [System.DateTimeOffset]'2026-11-30T23:59:59-03:00'
                Documents   = @()
            }
        }

        #region Encoding and structure
        Context 'Encoding and structure' {

            It 'Encodes the company name and renders a complete HTML document' {
                $Script:ReportParams.Documents = @(
                    $docParams = @{
                        Key       = ('1' * 44)
                        Model     = 55
                        Direction = 'Saida'
                        Value     = 100d
                    }

                    New-ReportTestDocument @docParams
                )

                $html = ConvertTo-DFeCfopReportHtml @Script:ReportParams

                $html | Should -BeOfType ([string])
                $html | Should -Match '(?s)^<!doctype html>.*</html>\s*$'
                $html | Should -Match '<html lang="pt-BR">'
                $html | Should -Match 'Empresa &amp; Cliente'
                $html | Should -Match '12\.345\.678/0001-99'
                $html | Should -Not -Match '\{\d+\}'
            }

            It 'Encodes item product names that contain markup characters' {
                $Script:ReportParams.Documents = @(
                    $docParams = @{
                        Key       = ('1' * 44)
                        Model     = 55
                        Direction = 'Saida'
                        Value     = 100d
                    }

                    New-ReportTestDocument @docParams
                )

                $html = ConvertTo-DFeCfopReportHtml @Script:ReportParams

                $html | Should -Match '&lt;Produto&gt;'
            }

            It 'Renders the empty state when there are no active documents' {
                $html = ConvertTo-DFeCfopReportHtml @Script:ReportParams

                $html | Should -Match 'Nenhuma nota para detalhar'
                $html | Should -Match 'Nenhum item para resumir'
                $html | Should -Not -Match 'class="day"'
            }
        }
        #endregion

        #region Model and direction groups
        Context 'Model and direction groups' {

            It 'Renders a group title for each distinct model and direction combination' {
                $docParamsOne = @{
                    Key       = ('1' * 44)
                    Model     = 55
                    Direction = 'Entrada'
                    Value     = 200d
                }

                $docParamsTwo = @{
                    Key       = ('2' * 44)
                    Model     = 65
                    Direction = 'Saida'
                    Value     = 100d
                }

                $nfe  = New-ReportTestDocument @docParamsOne
                $nfce = New-ReportTestDocument @docParamsTwo

                $Script:ReportParams.Documents = @($nfe, $nfce)

                $html = ConvertTo-DFeCfopReportHtml @Script:ReportParams

                $html | Should -Match 'NF-e - Entrada'
                $html | Should -Match 'NFC-e - Sa'
            }

            It 'Formats the issuance date and time using pt-BR culture' {
                $Script:ReportParams.Documents = @(
                    $docParams = @{
                        Key       = ('1' * 44)
                        Model     = 55
                        Direction = 'Saida'
                        Value     = 100d
                    }

                    New-ReportTestDocument @docParams
                )

                $html = ConvertTo-DFeCfopReportHtml @Script:ReportParams

                $html | Should -Match '02/11/2026 23:00:00'
            }
        }
        #endregion

        #region Tax column header
        Context 'Tax column header' {

            It 'Labels the tax column <Expected> from all items in the note' -ForEach @(
                @{
                    Cst      = '00'
                    Csosn    = $null
                    Expected = 'CST'
                }
                @{
                    Cst      = '60'
                    Csosn    = '102'
                    Expected = 'CST/CSOSN'
                }
                @{
                    Cst      = $null
                    Csosn    = '102'
                    Expected = 'CSOSN'
                }
                @{
                    Cst      = $null
                    Csosn    = $null
                    Expected = 'CST/CSOSN'
                }
            ) {
                $docParams = @{
                    Key       = ('1' * 44)
                    Model     = 55
                    Direction = 'Entrada'
                    Value     = 100d
                }

                $doc = New-ReportTestDocument @docParams

                $doc.Itens[0].CST   = $null
                $doc.Itens[0].CSOSN = $null
                $doc.Itens += New-ReportTestItem -CFOP '6102'

                $doc.Itens[1].CST   = $Cst
                $doc.Itens[1].CSOSN = $null
                $doc.Itens += New-ReportTestItem -CFOP '6102'

                $doc.Itens[2].CSOSN = $Csosn
                $Script:ReportParams.Documents = @($doc)

                $html = ConvertTo-DFeCfopReportHtml @Script:ReportParams

                $html | Should -Match (
                    '<th class="tax-code" scope="col">{0}</th>' -f $Expected
                )
            }
        }
        #endregion

        #region ICMS code rendering
        Context 'ICMS code rendering' {

            It 'Renders the ICMS code as <Expected>' -ForEach @(
                @{
                    Origin   = '0'
                    Cst      = '00'
                    Csosn    = $null
                    Expected = '000'
                }
                @{
                    Origin   = '0'
                    Cst      = '60'
                    Csosn    = $null
                    Expected = '060'
                }
                @{
                    Origin   = '1'
                    Cst      = '00'
                    Csosn    = $null
                    Expected = '100'
                }
                @{
                    Origin   = '2'
                    Cst      = '60'
                    Csosn    = $null
                    Expected = '260'
                }
                @{
                    Origin   = '0'
                    Cst      = $null
                    Csosn    = '102'
                    Expected = '0102'
                }
                @{
                    Origin   = '0'
                    Cst      = $null
                    Csosn    = '500'
                    Expected = '0500'
                }
                @{
                    Origin   = '2'
                    Cst      = $null
                    Csosn    = '102'
                    Expected = '2102'
                }
                @{
                    Origin   = $null
                    Cst      = '00'
                    Csosn    = $null
                    Expected = '00<small>Origem ausente</small>'
                }
                @{
                    Origin   = '0'
                    Cst      = $null
                    Csosn    = $null
                    Expected = '&mdash;'
                }
            ) {
                $docParams = @{
                    Key       = ('1' * 44)
                    Model     = 55
                    Direction = 'Entrada'
                    Value     = 100d
                }

                $doc = New-ReportTestDocument @docParams

                $doc.Itens[0].Origem = $Origin
                $doc.Itens[0].CST    = $Cst
                $doc.Itens[0].CSOSN  = $Csosn
                $Script:ReportParams.Documents = @($doc)

                $html = ConvertTo-DFeCfopReportHtml @Script:ReportParams

                $html | Should -Match (
                    '</small></td><td>6102</td><td class="tax-code">{0}</td>' -f
                    [regex]::Escape($Expected)
                )
            }
        }
        #endregion

        #region Import tax columns
        Context 'Import tax columns' {

            It 'Adds the II column only when at least one item carries a value' {
                $docParams = @{
                    Key       = ('1' * 44)
                    Model     = 55
                    Direction = 'Entrada'
                    Value     = 100d
                }

                $doc = New-ReportTestDocument @docParams

                $doc.Itens += New-ReportTestItem -CFOP '3102' -Value 20d -II 3.25d
                $Script:ReportParams.Documents = @($doc)

                $html = ConvertTo-DFeCfopReportHtml @Script:ReportParams

                $html | Should -Match 'class="num" scope="col">II</th>'
                $html | Should -Match 'class="num">3,25</td>'
            }

            It 'Omits import tax columns when no item carries a value' {
                $Script:ReportParams.Documents = @(
                    $docParams = @{
                        Key       = ('1' * 44)
                        Model     = 55
                        Direction = 'Saida'
                        Value     = 100d
                    }

                    New-ReportTestDocument @docParams
                )

                $html = ConvertTo-DFeCfopReportHtml @Script:ReportParams

                $html | Should -Not -Match 'scope="col">II</th>'
                $html | Should -Not -Match 'scope="col">BC II</th>'
            }
        }
        #endregion

        #region IndTotal column
        Context 'IndTotal column' {

            It 'Adds the composed-total column and renders N&atilde;o for IndTotal 0' {
                $docParams = @{
                    Key       = ('1' * 44)
                    Model     = 55
                    Direction = 'Entrada'
                    Value     = 200d
                }

                $doc = New-ReportTestDocument @docParams

                $doc.Itens += New-ReportTestItem -CFOP '3102' -Value 20d
                $doc.Itens[1].IndTotal = '0'
                $Script:ReportParams.Documents = @($doc)

                $html = ConvertTo-DFeCfopReportHtml @Script:ReportParams

                $html | Should -Match '<th scope="col">Comp&otilde;e vProd</th>'
                $html | Should -Match '<td>N&atilde;o</td>'
            }

            It 'Omits the composed-total column when all items have IndTotal 1' {
                $Script:ReportParams.Documents = @(
                    $docParams = @{
                        Key       = ('1' * 44)
                        Model     = 55
                        Direction = 'Saida'
                        Value     = 100d
                    }

                    New-ReportTestDocument @docParams
                )

                $html = ConvertTo-DFeCfopReportHtml @Script:ReportParams

                $html | Should -Not -Match '<th scope="col">Comp&otilde;e vProd</th>'
            }
        }
        #endregion

        #region Number formatting
        Context 'Number formatting' {

            It 'Formats large integer quantities without decimal places' {
                $docParams = @{
                    Key       = ('1' * 44)
                    Model     = 55
                    Direction = 'Entrada'
                    Value     = 100d
                }

                $doc = New-ReportTestDocument @docParams

                $doc.Itens[0].Quantidade       = 3492d
                $Script:ReportParams.Documents = @($doc)

                $html = ConvertTo-DFeCfopReportHtml @Script:ReportParams

                $html | Should -Match '>3\.492</td>'
            }

            It 'Formats fractional quantities preserving significant decimals' {
                $docParams = @{
                    Key       = ('1' * 44)
                    Model     = 55
                    Direction = 'Entrada'
                    Value     = 100d
                }

                $doc = New-ReportTestDocument @docParams

                $doc.Itens[0].Quantidade       = 10.5d
                $Script:ReportParams.Documents = @($doc)

                $html = ConvertTo-DFeCfopReportHtml @Script:ReportParams

                $html | Should -Match '>10,5</td>'
            }

            It 'Formats unit values preserving up to ten decimal places' {
                $docParams = @{
                    Key       = ('1' * 44)
                    Model     = 55
                    Direction = 'Entrada'
                    Value     = 100d
                }

                $doc = New-ReportTestDocument @docParams

                $doc.Itens[0].ValorUnitario    = 7.1234567891d
                $Script:ReportParams.Documents = @($doc)

                $html = ConvertTo-DFeCfopReportHtml @Script:ReportParams

                $html | Should -Match '>7,1234567891</td>'
            }

            It 'Formats the ICMS rate preserving variable decimal places' {
                $docParams = @{
                    Key       = ('1' * 44)
                    Model     = 55
                    Direction = 'Entrada'
                    Value     = 100d
                }

                $doc = New-ReportTestDocument @docParams

                $doc.Itens[0].AliqIcms         = 12.1234d
                $Script:ReportParams.Documents = @($doc)

                $html = ConvertTo-DFeCfopReportHtml @Script:ReportParams

                $html | Should -Match '>12,1234</td>'
            }
        }
        #endregion

        #region Document and CFOP totals
        Context 'Document and CFOP totals' {

            It 'Uses the declared document value for the note total' {
                $docParams = @{
                    Key       = ('1' * 44)
                    Model     = 55
                    Direction = 'Saida'
                    Value     = 200d
                }

                $doc = New-ReportTestDocument @docParams

                $doc.Itens += New-ReportTestItem -CFOP '6102' -Value 20d
                $Script:ReportParams.Documents = @($doc)

                $html = ConvertTo-DFeCfopReportHtml @Script:ReportParams

                $html | Should -Match 'Total da NF-e: 200,00'
            }

            It 'Uses item values for CFOP subtotals, not document values' {
                $docParams = @{
                    Key       = ('1' * 44)
                    Model     = 55
                    Direction = 'Entrada'
                    Value     = 200d
                }

                $doc = New-ReportTestDocument @docParams

                $doc.Itens += New-ReportTestItem -CFOP '3102' -Value 20d
                $doc.Itens += New-ReportTestItem -CFOP '3102' -Value 10d
                $Script:ReportParams.Documents = @($doc)

                $html = ConvertTo-DFeCfopReportHtml @Script:ReportParams

                $html | Should -Match (
                    '<td>3102</td>\s*<td class="num">2</td>\s*<td class="num">30,00</td>'
                )
            }

            It 'Reports separate period totals for each model and direction group' {
                $docParamsOne = @{
                    Key       = ('1' * 44)
                    Model     = 55
                    Direction = 'Entrada'
                    Value     = 100d
                }

                $docParamsTwo = @{
                    Key       = ('2' * 44)
                    Model     = 55
                    Direction = 'Saida'
                    Value     = 200d
                }

                $entry = New-ReportTestDocument @docParamsOne
                $exit  = New-ReportTestDocument @docParamsTwo
                $Script:ReportParams.Documents = @($entry, $exit)

                $html = ConvertTo-DFeCfopReportHtml @Script:ReportParams

                $html | Should -Match (
                    'Total das NF-e - Entrada sem cancelamento identificado: ' +
                    '<strong>100,00'
                )

                $html | Should -Match (
                    'Total das NF-e - Sa.* sem cancelamento identificado: ' +
                    '<strong>200,00'
                )

                $html | Should -Not -Match '300,00'
            }

            It 'Counts each CFOP group appearing in both NF-e and NFC-e separately' {
                $docParamsOne = @{
                    Key       = ('1' * 44)
                    Model     = 55
                    Direction = 'Saida'
                    Value     = 100d
                }

                $docParamsTwo = @{
                    Key       = ('2' * 44)
                    Model     = 65
                    Direction = 'Saida'
                    Value     = 100d
                }

                $nfe  = New-ReportTestDocument @docParamsOne
                $nfce = New-ReportTestDocument @docParamsTwo

                $Script:ReportParams.Documents = @($nfe, $nfce)
                $html = ConvertTo-DFeCfopReportHtml @Script:ReportParams

                ([regex]::Matches(
                    $html,
                    '<td>6102</td>\s*<td class="num">1</td>'
                )).Count | Should -Be 2
            }
        }
        #endregion

        #region Counterpart identifiers
        Context 'Counterpart identifiers' {

            It 'Formats a CPF counterpart with the standard mask' {
                $docParams = @{
                    Key       = ('1' * 44)
                    Model     = 55
                    Direction = 'Entrada'
                    Value     = 100d
                }

                $doc = New-ReportTestDocument @docParams

                $doc.DocumentoContraparte      = '12345678901'
                $doc.TipoDocumentoContraparte  = 'Cpf'
                $Script:ReportParams.Documents = @($doc)

                $html = ConvertTo-DFeCfopReportHtml @Script:ReportParams

                $html | Should -Match '123\.456\.789-01'
            }

            It 'Formats a CNPJ counterpart with the standard mask' {
                $docParams = @{
                    Key       = ('1' * 44)
                    Model     = 55
                    Direction = 'Saida'
                    Value     = 100d
                }

                $doc = New-ReportTestDocument @docParams

                $doc.DocumentoContraparte      = '98765432000188'
                $doc.TipoDocumentoContraparte  = 'Cnpj'
                $Script:ReportParams.Documents = @($doc)

                $html = ConvertTo-DFeCfopReportHtml @Script:ReportParams

                $html | Should -Match '98\.765\.432/0001-88'
            }

            It 'Formats an alphanumeric CNPJ counterpart with the standard mask' {
                $docParams = @{
                    Key       = ('1' * 44)
                    Model     = 55
                    Direction = 'Saida'
                    Value     = 100d
                }

                $doc = New-ReportTestDocument @docParams

                $doc.DocumentoContraparte      = '12ABC34501DE88'
                $doc.TipoDocumentoContraparte  = 'Cnpj'
                $Script:ReportParams.Documents = @($doc)

                $html = ConvertTo-DFeCfopReportHtml @Script:ReportParams

                $html | Should -Match '12\.ABC\.345/01DE-88'
            }
        }
        #endregion

        #region Cancellations
        Context 'Cancellations' {

            It 'Excludes confirmed cancellations from active sections' {
                $docParams = @{
                    Key       = ('1' * 44)
                    Model     = 55
                    Direction = 'Saida'
                    Value     = 300d
                }

                $cancelled = New-ReportTestDocument @docParams

                $cancelled.Cancelada             = $true
                $cancelled.DataCancelamento      = [System.DateTimeOffset]'2026-12-01T08:00:00-03:00'
                $cancelled.ProtocoloCancelamento = '123456789012345'
                $Script:ReportParams.Documents   = @($cancelled)

                $html = ConvertTo-DFeCfopReportHtml @Script:ReportParams

                $html | Should -Match 'Cancelamentos Confirmados'
                $html | Should -Match '01/12/2026 08:00:00'
                $html | Should -Match '123456789012345'
                $html | Should -Match 'Valor original da NF-e: <strong>300,00'
                $html | Should -Not -Match 'class="period-total"'
                $html | Should -Not -Match '<td>6102</td>'
            }

            It 'Excludes unconfirmed cancellations and shows the pending badge' {
                $docParams = @{
                    Key       = ('2' * 44)
                    Model     = 55
                    Direction = 'Saida'
                    Value     = 400d
                }

                $pending = New-ReportTestDocument @docParams

                $pending.CancelamentoSemConfirmar = $true
                $Script:ReportParams.Documents    = @($pending)

                $html = ConvertTo-DFeCfopReportHtml @Script:ReportParams

                $html | Should -Match 'Cancelamentos a conferir'
                $html | Should -Match 'Valor original da NF-e: <strong>400,00'
                $html | Should -Match 'A Conferir: <strong>1</strong>'
                $html | Should -Not -Match 'class="period-total"'
                $html | Should -Not -Match '<td>6102</td>'
            }
        }
        #endregion

        #region Rendering regression tests
        Context 'Rendering regressions' {

            It 'Renders commercial totals and leaves no format placeholders' {
                $docParams = @{
                    Key       = ('1' * 44)
                    Model     = 55
                    Direction = 'Entrada'
                    Value     = 100d
                }

                $doc = New-ReportTestDocument @docParams
                $doc.Tributos['Frete'] = 5d
                $Script:ReportParams.Documents = @($doc)

                $html = ConvertTo-DFeCfopReportHtml @Script:ReportParams

                $html | Should -Match '<strong>Total dos Produtos:</strong> 100,00 &middot; Frete: 5,00'
                $html | Should -Match 'Total das NF-e - Entrada sem cancelamento identificado: <strong>100,00'
                $html | Should -Not -Match '\{\d+\}'
            }

            It 'Distinguishes explicit zero import tax from a missing value' {
                $docParams = @{
                    Key       = ('1' * 44)
                    Model     = 55
                    Direction = 'Entrada'
                    Value     = 100d
                }

                $doc = New-ReportTestDocument @docParams

                $doc.Itens[0].II = $null
                $doc.Itens += New-ReportTestItem -CFOP '3102' -II 0d
                $Script:ReportParams.Documents = @($doc)

                $html = ConvertTo-DFeCfopReportHtml @Script:ReportParams

                $html | Should -Match 'scope="col">II</th>'
                $html | Should -Match '(?s)<td>6102</td>(?:(?!</tr>).)*<td class="num">&mdash;</td>\s*</tr>'
                $html | Should -Match '(?s)<td>3102</td>(?:(?!</tr>).)*<td class="num">0,00</td>\s*</tr>'
            }

            It 'Renders missing summary taxes without converting them to zero' {
                $docParams = @{
                    Key       = ('1' * 44)
                    Model     = 55
                    Direction = 'Entrada'
                    Value     = 100d
                }

                $doc = New-ReportTestDocument @docParams
                $Script:ReportParams.Documents = @($doc)

                $html = ConvertTo-DFeCfopReportHtml @Script:ReportParams

                $html | Should -Match '<td>6102</td>\s*<td class="num">1</td>\s*<td class="num">100,00</td>\s*<td class="num">&mdash;</td>\s*<td class="num">0,00</td>'
            }

            It 'Renders a balanced note body when no items are present' {
                $docParams = @{
                    Key       = ('1' * 44)
                    Model     = 55
                    Direction = 'Entrada'
                    Value     = 100d
                }

                $doc = New-ReportTestDocument @docParams
                $doc.Itens = @()
                $Script:ReportParams.Documents = @($doc)

                $html = ConvertTo-DFeCfopReportHtml @Script:ReportParams

                ([regex]::Matches($html, '<tbody(?:\s[^>]*)?>')).Count |
                    Should -Be ([regex]::Matches($html, '</tbody>')).Count

                $html |
                    Should -Match '<tbody class="note-tail">\s*<tr class="total-row">'
            }

            It 'Gives confirmed cancellation precedence over an unconfirmed event' {
                $docParams = @{
                    Key       = ('1' * 44)
                    Model     = 55
                    Direction = 'Entrada'
                    Value     = 100d
                }

                $doc = New-ReportTestDocument @docParams

                $doc.Cancelada = $true
                $doc.CancelamentoSemConfirmar = $true
                $doc.DataCancelamento = [System.DateTimeOffset]'2026-12-01T08:00:00-03:00'

                $Script:ReportParams.Documents = @($doc)
                $html = ConvertTo-DFeCfopReportHtml @Script:ReportParams

                $html | Should -Match '<section aria-labelledby="canceladas">'
                $html | Should -Not -Match '<section aria-labelledby="pendentes">'
                $html | Should -Not -Match '\{\d+\}'

                ([regex]::Matches($html, '<code>' + $doc.ChaveAcesso + '</code>')).Count | Should -Be 1
            }
        }
        #endregion

        #region Period validation
        Context 'Period validation' {

            It 'Rejects a reversed report period' {
                $Script:ReportParams.EndDate = $Script:ReportParams.StartDate.AddSeconds(-1)

                { ConvertTo-DFeCfopReportHtml @Script:ReportParams } |
                    Should -Throw -ErrorId 'InvalidDateRange,ConvertTo-DFeCfopReportHtml'
            }
        }
        #endregion
    }
}
