#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Tests report extraction from indexed XML fixtures.

.DESCRIPTION
Covers import amounts, hash failures and cancellation response validation.
The event lookup is mocked; both documents and events use real XML files.

Coverage includes:
  - Import tax fields (II, IOF, DespAduaneira) preserved with correct decimal values.
  - Cancellation confirmed by event return code (135, 155) rather than request.
  - Unconfirmed cancellation detected when event return code is not authoritative (136).
  - Hash mismatch on source XML raises a terminating error before event lookup.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseShouldProcessForStateChangingFunctions',
    '',
    Justification = 'Integration tests create isolated fixtures.'
)]

param ()

BeforeDiscovery {
    # InModuleScope needs to resolve the PipeDFe module during the Discovery phase,
    # because that's when Context/It are executed to register the test tree. If the
    # module isn't loaded at that point, InModuleScope fails before any BeforeAll or
    # BeforeEach ever runs.
    $moduleRoot = (Get-Item $PSScriptRoot).Parent.Parent.Parent.Parent.FullName

    $moduleName = Join-Path -Path $moduleRoot -ChildPath 'PipeDFe.psd1'

    Import-Module -Name $moduleName -Force -Global -ErrorAction Stop
}


Describe 'Get-DFeAnalyticalReportData' -Tag 'Unit' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            #region Helpers
            function New-IndexedReportTestXml {
                [CmdletBinding()]
                [OutputType([pscustomobject])]
                param (
                    [Parameter(Mandatory)]
                    [string]$Path,

                    [Parameter(Mandatory)]
                    [string]$Content
                )

                [System.IO.File]::WriteAllText($Path, $Content)

                [PSCustomObject]@{
                    chave_acesso = '35261112345678000199550010000018011823409412'
                    modelo       = 55
                    direcao      = 'Entrada'
                    sha256       = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
                    file_path    = $Path
                    evento_tipo  = 'Cancelamento'
                }
            }
            #endregion
        }

        BeforeEach {

            $key      = '35261112345678000199550010000018011823409412'
            $document = @"
<NFe xmlns="http://www.portalfiscal.inf.br/nfe">
    <infNFe Id="NFe$key">
        <ide>
            <mod>55</mod>
            <serie>1</serie>
            <nNF>1801</nNF>
            <dhEmi>2026-11-25T10:00:00-03:00</dhEmi>
            <tpAmb>2</tpAmb>
        </ide>
        <emit>
            <CNPJ>98765432000198</CNPJ>
            <xNome>Fornecedor</xNome>
        </emit>
        <det nItem="1">
            <prod>
                <xProd>Importado</xProd>
                <CFOP>3102</CFOP>
                <vProd>100.00</vProd>
            </prod>
        <imposto>
            <ICMS>
                <ICMS00>
                    <orig>0</orig>
                    <CST>00</CST>
                    <vICMS>0.00</vICMS>
                </ICMS00>
            </ICMS>
            <II>
                <vBC>100.00</vBC>
                <vDespAdu>0.00</vDespAdu>
                <vII>15.50</vII>
                <vIOF>1.25</vIOF>
            </II>
      </imposto>
    </det>
        <total>
            <ICMSTot>
                <vProd>100.00</vProd>
                <vII>15.50</vII>
                <vNF>117.00</vNF>
            </ICMSTot>
        </total>
    </infNFe>
</NFe>
"@

            $Script:ReportEventXml = @"
<procEventoNFe xmlns="http://www.portalfiscal.inf.br/nfe">
    <evento>
        <infEvento>
            <tpAmb>2</tpAmb>
            <chNFe>$key</chNFe>
            <tpEvento>110111</tpEvento>
            <nSeqEvento>1</nSeqEvento>
        </infEvento>
    </evento>
    <retEvento>
        <infEvento>
            <tpAmb>2</tpAmb>
            <chNFe>$key</chNFe>
            <tpEvento>110111</tpEvento>
            <nSeqEvento>1</nSeqEvento>
            <cStat>{0}</cStat>
            <nProt>123456789012345</nProt>
            <dhRegEvento>2026-12-02T11:00:00-03:00</dhRegEvento>
        </infEvento>
    </retEvento>
</procEventoNFe>
"@

            $documentPath           = Join-Path -Path $TestDrive -ChildPath 'invoice.xml'
            $Script:ReportEventPath = Join-Path -Path $TestDrive -ChildPath 'event.xml'

            $entry = New-IndexedReportTestXml -Path $documentPath -Content $document

            $Script:ReportParams = @{
                Cnpj    = '12345678000199'
                Entries = @($entry)
            }
        }

        It 'Preserves zero, missing and declared import values independently' {
            Mock -CommandName Get-DFeEventoEntry -MockWith {

            }

            $result = Get-DFeAnalyticalReportData @Script:ReportParams

            $result.Contraparte              | Should -BeExactly 'Fornecedor'
            $result.TipoDocumentoContraparte | Should -BeExactly 'Cnpj'
            $result.ValorNota                | Should -Be 117d
            $result.ValorProdutos            | Should -Be 100d
            $result.Itens[0].Origem          | Should -BeExactly '0'
            $result.Itens[0].CST             | Should -BeExactly '00'
            $result.Itens[0].BaseII          | Should -Be 100d
            $result.Itens[0].DespAduaneira   | Should -Be 0d
            $result.Itens[0].II              | Should -Be 15.50d
            $result.Itens[0].IOF             | Should -Be 1.25d
            $result.Itens[0].IPI             | Should -Be $null
            $result.Cancelada                | Should -BeFalse
        }

        It 'Classifies response <Status> using the event return rather than the request' -ForEach @(
            @{
                Status    = '135'
                Confirmed = $true
            }
            @{
                Status    = '155'
                Confirmed = $true
            }
            @{
                Status    = '136'
                Confirmed = $false
            }
        ) {
            $eventParams = @{
                Path    = $Script:ReportEventPath
                Content = ($Script:ReportEventXml -f $Status)
            }

            $Script:ReportTestEvent = New-IndexedReportTestXml @eventParams

            Mock -CommandName Get-DFeEventoEntry -MockWith {
                $Script:ReportTestEvent
            }

            $result = Get-DFeAnalyticalReportData @Script:ReportParams

            $result.Cancelada                | Should -Be $Confirmed
            $result.CancelamentoSemConfirmar | Should -Be (-not $Confirmed)

            if ($Confirmed) {
                $result.ProtocoloCancelamento | Should -BeExactly '123456789012345'
                $result.DataCancelamento      |
                    Should -Be ([System.DateTimeOffset]'2026-12-02T11:00:00-03:00')
            }
        }

        It 'Stops on a changed source XML' {
            $entry.sha256 = '0' * 64

            Mock -CommandName Get-DFeEventoEntry -MockWith {

            }

            { Get-DFeAnalyticalReportData @Script:ReportParams } |
                Should -Throw -ExpectedMessage '*Indexed XML hash mismatch*'

            Should -Invoke Get-DFeEventoEntry -Times 0 -Exactly -Scope It
        }
    }
}
