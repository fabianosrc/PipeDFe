#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for Get-DFeNFComFiscalData.

.DESCRIPTION
Verifies fiscal data extraction from NFCom XML documents using
in-memory fixtures. No file or database I/O is performed.

Coverage includes:
  - Extracts fiscal identity, schema version and model.
  - Preserves document number and series as strings.
  - Extracts item number via GetAttribute.
  - Extracts service item values with decimal precision.
  - Extracts ICMS tributes from item nodes.
  - Extracts indSemCST when ICMS is absent.
  - Extracts document totals.
  - Extracts protocolo from nfcomProc root.
  - Extracts assinante and faturamento.
  - Handles multiple items.
  - Rejects an NFCom with an invalid fiscal model.
  - Rejects a document with a missing access key.
  - Rejects a document from another fiscal model.
#>

BeforeDiscovery {
    # InModuleScope needs to resolve the PipeDFe module during the Discovery phase,
    # because that's when Context/It are executed to register the test tree. If the
    # module isn't loaded at that point, InModuleScope fails before any BeforeAll or
    # BeforeEach ever runs.
    $moduleRoot = (Get-Item $PSScriptRoot).Parent.Parent.Parent.Parent.FullName

    $modulePath = Join-Path -Path $moduleRoot -ChildPath 'PipeDFe.psd1'

    Import-Module -Name $modulePath -Force -Global -ErrorAction Stop
}

Describe 'Get-DFeNFComFiscalData' -Tag 'Unit' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            # Minimal NFCom (bare document, single item with ICMS).
            $Script:MinimalNFCom = @'
<NFCom xmlns="http://www.portalfiscal.inf.br/nfcom">
    <infNFCom Id="NFCom35261112345678000199620010000000011234567890">
        <ide>
            <mod>62</mod>
            <serie>001</serie>
            <nNF>000123</nNF>
            <dhEmi>2026-11-01T10:00:00-03:00</dhEmi>
        </ide>
        <emit>
            <CNPJ>12345678000199</CNPJ>
            <xNome>EMITENTE TESTE</xNome>
        </emit>
        <dest>
            <CNPJ>98765432000199</CNPJ>
            <xNome>DESTINATARIO TESTE</xNome>
        </dest>
        <det nItem="1">
            <prod>
                <cProd>SERV001</cProd>
                <xProd>INTERNET BANDA LARGA</xProd>
                <cClass>0100101</cClass>
                <CFOP>5307</CFOP>
                <uMed>4</uMed>
                <qFaturada>1.0000</qFaturada>
                <vItem>99.90000000</vItem>
                <vProd>99.90</vProd>
            </prod>
            <imposto>
                <ICMS00>
                    <CST>00</CST>
                    <vBC>99.90</vBC>
                    <pICMS>18.00</pICMS>
                    <vICMS>17.98</vICMS>
                </ICMS00>
            </imposto>
        </det>
        <total>
            <vProd>99.90</vProd>
            <ICMSTot>
                <vBC>99.90</vBC>
                <vICMS>17.98</vICMS>
            </ICMSTot>
            <vNF>99.90</vNF>
        </total>
    </infNFCom>
</NFCom>
'@

            # nfcomProc with multiple items - based on a real document structure.
            # Items 1, 3 and 5 use indSemCST; items 2 and 4 use ICMSSN.
            $Script:MultiItemProc = @'
<nfcomProc versao="1.00" xmlns="http://www.portalfiscal.inf.br/nfcom">
    <NFCom xmlns="http://www.portalfiscal.inf.br/nfcom">
        <infNFCom versao="1.00" Id="NFCom35261018043483000177620010000033901035028041">
            <ide>
                <cUF>35</cUF>
                <tpAmb>1</tpAmb>
                <mod>62</mod>
                <serie>1</serie>
                <nNF>3390</nNF>
                <cNF>3502804</cNF>
                <cDV>1</cDV>
                <dhEmi>2026-10-29T11:37:26-03:00</dhEmi>
                <tpEmis>1</tpEmis>
                <cMunFG>3502804</cMunFG>
                <finNFCom>0</finNFCom>
                <tpFat>0</tpFat>
            </ide>
            <emit>
                <CNPJ>18043483000177</CNPJ>
                <IE>177340215111</IE>
                <CRT>1</CRT>
                <xNome>EMITENTE TESTE</xNome>
            </emit>
            <dest>
                <xNome>DESTINATARIO TESTE</xNome>
                <CPF>30967484898</CPF>
                <indIEDest>9</indIEDest>
            </dest>
            <assinante>
                <iCodAssinante>30967484898</iCodAssinante>
                <tpAssinante>3</tpAssinante>
                <nContrato>0003390</nContrato>
                <dContratoIni>2026-09-01</dContratoIni>
                <dContratoFim>2026-09-30</dContratoFim>
            </assinante>
            <det nItem="1">
                <prod>
                    <cProd>1306663347</cProd>
                    <xProd>LOCACAO DE EQUIPAMENTOS</xProd>
                    <cClass>0600601</cClass>
                    <uMed>4</uMed>
                    <qFaturada>1.0000</qFaturada>
                    <vItem>42.96</vItem>
                    <vProd>42.96</vProd>
                </prod>
                <imposto>
                    <indSemCST>1</indSemCST>
                </imposto>
            </det>
            <det nItem="2">
                <prod>
                    <cProd>773170640</cProd>
                    <xProd>MENSALIDADE DE INTERNET</xProd>
                    <cClass>0400401</cClass>
                    <CFOP>5307</CFOP>
                    <uMed>4</uMed>
                    <qFaturada>1.0000</qFaturada>
                    <vItem>56.94</vItem>
                    <vProd>56.94</vProd>
                </prod>
                <imposto>
                    <ICMSSN>
                        <CST>90</CST>
                        <indSN>1</indSN>
                    </ICMSSN>
                </imposto>
            </det>
            <total>
                <vProd>99.90</vProd>
                <ICMSTot>
                    <vBC>0.00</vBC>
                    <vICMS>0.00</vICMS>
                </ICMSTot>
                <vNF>99.90</vNF>
            </total>
            <gFat>
                <CompetFat>202609</CompetFat>
                <dVencFat>2026-10-10</dVencFat>
                <dPerUsoIni>2026-09-01</dPerUsoIni>
                <dPerUsoFim>2026-09-30</dPerUsoFim>
                <codBarras>1</codBarras>
            </gFat>
        </infNFCom>
    </NFCom>
    <protNFCom versao="1.00" xmlns="http://www.portalfiscal.inf.br/nfcom">
        <infProt Id="NFCom3352600975345124">
            <nProt>3352600975345124</nProt>
            <cStat>100</cStat>
            <xMotivo>Autorizado o uso da NFCom</xMotivo>
            <dhRecbto>2026-10-29T11:37:45-03:00</dhRecbto>
        </infProt>
    </protNFCom>
</nfcomProc>
'@
        }

        Context 'Fiscal identity' {

            It 'Extracts the NFCom fiscal identity' {
                [xml]$xml = $Script:MinimalNFCom

                $result = Get-DFeNFComFiscalData -Xml $xml

                $result.PSTypeNames   | Should -Contain 'PipeDFe.Fiscal.NFComDocument'
                $result.SchemaVersion | Should -Be 1
                $result.Modelo        | Should -Be ([ModeloDFe]::NFCom)
                $result.ChaveAcesso   | Should -Be '35261112345678000199620010000000011234567890'
            }

            It 'Preserves document number and series as strings' {
                [xml]$xml = $Script:MinimalNFCom

                $result = Get-DFeNFComFiscalData -Xml $xml

                $result.Identificacao.Numero | Should -Be '000123'
                $result.Identificacao.Serie  | Should -Be '001'
            }
        }

        Context 'Item extraction' {

            It 'Extracts the item number via GetAttribute' {
                [xml]$xml = $Script:MinimalNFCom

                $result = Get-DFeNFComFiscalData -Xml $xml

                $result.Itens[0].Numero | Should -Be '1'
            }

            It 'Extracts service values with decimal precision' {
                [xml]$xml = $Script:MinimalNFCom

                $result = Get-DFeNFComFiscalData -Xml $xml

                $result.Itens | Should -HaveCount 1
                $result.Itens[0].Produto.Classificacao | Should -Be '0100101'
                $result.Itens[0].Produto.ValorUnitario | Should -BeOfType [decimal]
                $result.Itens[0].Produto.ValorUnitario | Should -Be ([decimal]'99.90000000')
                $result.Totais.VNF | Should -Be ([decimal]'99.90')
            }

            It 'Extracts ICMS tributes from item nodes' {
                [xml]$xml = $Script:MinimalNFCom

                $result = Get-DFeNFComFiscalData -Xml $xml

                $result.Itens[0].Tributos.ICMS.Grupo | Should -Be 'ICMS00'
                $result.Itens[0].Tributos.ICMS.CST   | Should -Be '00'
                $result.Itens[0].Tributos.ICMS.VICMS | Should -Be ([decimal]'17.98')
            }

            It 'Extracts indSemCST when ICMS is absent' {
                [xml]$xml = $Script:MultiItemProc

                $result = Get-DFeNFComFiscalData -Xml $xml

                $result.Itens[0].Tributos.IndSemCST | Should -Be '1'
                $result.Itens[0].Tributos.ICMS      | Should -BeNullOrEmpty
            }

            It 'Extracts ICMSSN from item nodes' {
                [xml]$xml = $Script:MultiItemProc

                $result = Get-DFeNFComFiscalData -Xml $xml

                $result.Itens[1].Tributos.ICMS.Grupo | Should -Be 'ICMSSN'
                $result.Itens[1].Tributos.ICMS.CST   | Should -Be '90'
                $result.Itens[1].Tributos.ICMS.IndSN | Should -Be '1'
            }

            It 'Extracts multiple items in document order' {
                [xml]$xml = $Script:MultiItemProc

                $result = Get-DFeNFComFiscalData -Xml $xml

                $result.Itens | Should -HaveCount 2
                $result.Itens[0].Numero | Should -Be '1'
                $result.Itens[1].Numero | Should -Be '2'
            }
        }

        Context 'Totals and supplementary data' {

            It 'Extracts document totals' {
                [xml]$xml = $Script:MinimalNFCom

                $result = Get-DFeNFComFiscalData -Xml $xml

                $result.Totais.VProd | Should -Be ([decimal]'99.90')
                $result.Totais.VBC   | Should -Be ([decimal]'99.90')
                $result.Totais.VICMS | Should -Be ([decimal]'17.98')
            }

            It 'Extracts protocolo from nfcomProc root' {
                [xml]$xml = $Script:MultiItemProc

                $result = Get-DFeNFComFiscalData -Xml $xml

                $result.Protocolo            | Should -Not -BeNullOrEmpty
                $result.Protocolo.Numero     | Should -Be '3352600975345124'
                $result.Protocolo.Status     | Should -Be '100'
                $result.Protocolo.RecebidoEm | Should -Not -BeNullOrEmpty
            }

            It 'Extracts assinante when present' {
                [xml]$xml = $Script:MultiItemProc

                $result = Get-DFeNFComFiscalData -Xml $xml

                $result.Assinante          | Should -Not -BeNullOrEmpty
                $result.Assinante.Codigo   | Should -Be '30967484898'
                $result.Assinante.Contrato | Should -Be '0003390'
            }

            It 'Extracts faturamento when present' {
                [xml]$xml = $Script:MultiItemProc

                $result = Get-DFeNFComFiscalData -Xml $xml

                $result.Faturamento             | Should -Not -BeNullOrEmpty
                $result.Faturamento.Competencia | Should -Be '202609'
                $result.Faturamento.Vencimento  | Should -Be '2026-10-10'
            }

            It 'Returns null protocolo for a bare NFCom document' {
                [xml]$xml = $Script:MinimalNFCom

                $result = Get-DFeNFComFiscalData -Xml $xml

                $result.Protocolo | Should -BeNullOrEmpty
            }
        }

        Context 'Validation failures' {

            It 'Rejects an NFCom with an invalid fiscal model' {
                [xml]$xml = $Script:MinimalNFCom.Replace(
                    '<mod>62</mod>',
                    '<mod>55</mod>'
                )

                { Get-DFeNFComFiscalData -Xml $xml } |
                    Should -Throw -ErrorId 'NFComModelMismatch*'
            }

            It 'Rejects a missing access key' {
                [xml]$xml = $Script:MinimalNFCom.Replace(
                    'Id="NFCom35261112345678000199620010000000011234567890"',
                    ''
                )

                { Get-DFeNFComFiscalData -Xml $xml } |
                    Should -Throw -ErrorId 'NFComAccessKeyInvalid*'
            }

            It 'Rejects a document from another fiscal model' {
                [xml]$xml = @'
<NFe xmlns="http://www.portalfiscal.inf.br/nfe">
    <infNFe Id="NFe35261112345678000199550010000000011234567890">
        <ide><mod>55</mod></ide>
    </infNFe>
</NFe>
'@

                { Get-DFeNFComFiscalData -Xml $xml } |
                    Should -Throw -ErrorId 'UnsupportedNFComFiscalDocument*'
            }
        }
    }
}
