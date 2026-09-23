#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for Get-DFeNFeFiscalData.

.DESCRIPTION
Verifies fiscal data extraction from NF-e and NFC-e XML documents.

Coverage includes:
  - PSTypeName is PipeDFe.Fiscal.NFeDocument.
  - SchemaVersion is 1.
  - Modelo is resolved as NFe for mod 55.
  - Modelo is resolved as NFCe for mod 65.
  - ChaveAcesso is extracted correctly.
  - Extraction works for nfeProc root.
  - Identificacao fields are extracted.
  - Emitente fields including nested Endereco are extracted.
  - Destinatario fields including nested Endereco are extracted.
  - Destinatario is null when absent (NFC-e pattern).
  - Item list count matches det count.
  - nItem attribute is parsed as int.
  - Produto fields are extracted.
  - Decimal precision is preserved across all monetary fields.
  - ICMS group name and fields are extracted.
  - ICMS ST fields are extracted.
  - IPI fields are extracted (IPITrib and IPINT).
  - PIS fields are extracted.
  - COFINS fields are extracted.
  - IBSCBS per-item fields are extracted when present.
  - IBSCBS is null when absent.
  - Totais ICMSTot fields are extracted.
  - Totais IBSCBSTot fields are extracted when present.
  - Totais IBSCBSTot is null when absent.
  - Totais RetTrib fields are extracted when present.
  - Totais RetTrib is null when absent.
  - Totais is null when ICMSTot is absent.
  - Throws UnsupportedNFeFiscalDocument for non-NF-e XML.
  - Throws NFeNamespaceNotFound when namespace is absent.
  - Throws NFeInfoNodeNotFound when infNFe is absent.
  - Throws NFeAccessKeyInvalid when Id attribute is absent.
#>

# InModuleScope needs to resolve the PipeDFe module during the Discovery phase,
# because that's when Context/It are executed to register the test tree. If the
# module isn't loaded at that point, InModuleScope fails before any BeforeAll or
# BeforeEach ever runs.
BeforeDiscovery {
    $moduleRoot = (Get-Item $PSScriptRoot).Parent.Parent.Parent.Parent.FullName

    $moduleName = Join-Path -Path $moduleRoot -ChildPath 'PipeDFe.psd1'

    Import-Module -Name $moduleName -Force -Global -ErrorAction Stop
}

Describe 'Get-DFeNFeFiscalData' -Tag 'Unit' {

    InModuleScope -ModuleName PipeDFe {

        # ---------------------------------------------------------------------
        # Minimal reusable XML fragments.
        # ---------------------------------------------------------------------
        BeforeAll {

            $Script:NFeNamespace = 'xmlns="http://www.portalfiscal.inf.br/nfe"'

            $Script:MinimalNFe = @'
<NFe xmlns="http://www.portalfiscal.inf.br/nfe">
    <infNFe Id="NFe35260912345678000199550010000000011234567890">
        <ide>
            <cUF>35</cUF>
            <natOp>VENDA</natOp>
            <mod>55</mod>
            <serie>1</serie>
            <nNF>1</nNF>
            <dhEmi>2026-09-23T10:00:00-03:00</dhEmi>
            <tpNF>1</tpNF>
            <idDest>1</idDest>
            <cMunFG>3550308</cMunFG>
            <tpImp>1</tpImp>
            <tpEmis>1</tpEmis>
            <finNFe>1</finNFe>
            <indFinal>1</indFinal>
            <indPres>1</indPres>
        </ide>
        <emit>
            <CNPJ>12345678000199</CNPJ>
            <xNome>EMPRESA TESTE LTDA</xNome>
            <IE>123456789</IE>
            <CRT>3</CRT>
        </emit>
        <dest>
            <CNPJ>98765432000199</CNPJ>
            <xNome>CLIENTE TESTE LTDA</xNome>
            <indIEDest>1</indIEDest>
        </dest>
        <det nItem="1">
            <prod>
                <cProd>ABC001</cProd>
                <xProd>PRODUTO TESTE</xProd>
                <NCM>12345678</NCM>
                <CFOP>5102</CFOP>
                <uCom>UN</uCom>
                <qCom>2.0000</qCom>
                <vUnCom>50.00</vUnCom>
                <vProd>100.00</vProd>
                <uTrib>UN</uTrib>
                <qTrib>2.0000</qTrib>
                <vUnTrib>50.00</vUnTrib>
                <indTot>1</indTot>
            </prod>
            <imposto>
                <ICMS>
                    <ICMS00>
                        <orig>0</orig>
                        <CST>00</CST>
                        <modBC>3</modBC>
                        <vBC>100.00</vBC>
                        <pICMS>18.0000</pICMS>
                        <vICMS>18.00</vICMS>
                    </ICMS00>
                </ICMS>
                <PIS>
                    <PISAliq>
                        <CST>01</CST>
                        <vBC>100.00</vBC>
                        <pPIS>1.6500</pPIS>
                        <vPIS>1.65</vPIS>
                    </PISAliq>
                </PIS>
                <COFINS>
                    <COFINSAliq>
                        <CST>01</CST>
                        <vBC>100.00</vBC>
                        <pCOFINS>7.6000</pCOFINS>
                        <vCOFINS>7.60</vCOFINS>
                    </COFINSAliq>
                </COFINS>
            </imposto>
        </det>
        <total>
            <ICMSTot>
                <vBC>100.00</vBC>
                <vICMS>18.00</vICMS>
                <vICMSDeson>0.00</vICMSDeson>
                <vFCP>0.00</vFCP>
                <vBCST>0.00</vBCST>
                <vST>0.00</vST>
                <vFCPST>0.00</vFCPST>
                <vFCPSTRet>0.00</vFCPSTRet>
                <vProd>100.00</vProd>
                <vFrete>0.00</vFrete>
                <vSeg>0.00</vSeg>
                <vDesc>0.00</vDesc>
                <vII>0.00</vII>
                <vIPI>0.00</vIPI>
                <vIPIDevol>0.00</vIPIDevol>
                <vPIS>1.65</vPIS>
                <vCOFINS>7.60</vCOFINS>
                <vOutro>0.00</vOutro>
                <vNF>100.00</vNF>
            </ICMSTot>
        </total>
    </infNFe>
</NFe>
'@
        }

        #region Output contract
        Context 'Output contract' {

            It 'Returns PSTypeName PipeDFe.Fiscal.NFeDocument' {
                [xml]$xml = $Script:MinimalNFe

                $result = Get-DFeNFeFiscalData -Xml $xml

                $result.PSTypeNames | Should -Contain 'PipeDFe.Fiscal.NFeDocument'
            }

            It 'Returns SchemaVersion 1' {
                [xml]$xml = $Script:MinimalNFe

                $result = Get-DFeNFeFiscalData -Xml $xml

                $result.SchemaVersion | Should -Be 1
            }

            It 'Resolves Modelo as NFe for mod 55' {
                [xml]$xml = $Script:MinimalNFe

                $result = Get-DFeNFeFiscalData -Xml $xml

                $result.Modelo | Should -Be ([ModeloDFe]::NFe)
            }

            It 'Resolves Modelo as NFCe for mod 65' {
                [xml]$xml = @'
<NFe xmlns="http://www.portalfiscal.inf.br/nfe">
    <infNFe Id="NFe35260912345678000199650010000000011234567890">
        <ide>
            <mod>65</mod>
        </ide>
        <emit>
            <CNPJ>12345678000199</CNPJ>
            <xNome>EMPRESA</xNome>
            <CRT>3</CRT>
        </emit>
        <det nItem="1">
            <prod>
                <cProd>P1</cProd>
                <xProd>PROD</xProd>
                <NCM>00000000</NCM>
                <CFOP>5102</CFOP>
                <uCom>UN</uCom>
                <qCom>1.0000</qCom>
                <vUnCom>10.00</vUnCom>
                <vProd>10.00</vProd>
                <uTrib>UN</uTrib>
                <qTrib>1.0000</qTrib>
                <vUnTrib>10.00</vUnTrib>
                <indTot>1</indTot>
            </prod>
            <imposto>
                <ICMS>
                    <ICMS00>
                        <orig>0</orig>
                        <CST>00</CST>
                        <modBC>3</modBC>
                        <vBC>10.00</vBC>
                        <pICMS>0.0000</pICMS>
                        <vICMS>0.00</vICMS>
                    </ICMS00>
                </ICMS>
                <PIS>
                    <PISNT>
                        <CST>07</CST>
                    </PISNT>
                </PIS>
                <COFINS>
                    <COFINSNT>
                        <CST>07</CST>
                    </COFINSNT>
                </COFINS>
            </imposto>
        </det>
        <total>
            <ICMSTot>
                <vBC>0.00</vBC>
                <vICMS>0.00</vICMS>
                <vICMSDeson>0.00</vICMSDeson>
                <vFCP>0.00</vFCP>
                <vBCST>0.00</vBCST>
                <vST>0.00</vST>
                <vFCPST>0.00</vFCPST>
                <vFCPSTRet>0.00</vFCPSTRet>
                <vProd>10.00</vProd>
                <vFrete>0.00</vFrete>
                <vSeg>0.00</vSeg>
                <vDesc>0.00</vDesc>
                <vII>0.00</vII>
                <vIPI>0.00</vIPI>
                <vIPIDevol>0.00</vIPIDevol>
                <vPIS>0.00</vPIS>
                <vCOFINS>0.00</vCOFINS>
                <vOutro>0.00</vOutro>
                <vNF>10.00</vNF>
            </ICMSTot>
        </total>
    </infNFe>
</NFe>
'@

                $result = Get-DFeNFeFiscalData -Xml $xml

                $result.Modelo | Should -Be ([ModeloDFe]::NFCe)
            }

            It 'Extracts ChaveAcesso from the Id attribute' {
                [xml]$xml = $Script:MinimalNFe

                $result = Get-DFeNFeFiscalData -Xml $xml

                $result.ChaveAcesso | Should -Be '35260912345678000199550010000000011234567890'
            }

            It 'Extracts from nfeProc root' {
                [xml]$xml = @'
<nfeProc xmlns="http://www.portalfiscal.inf.br/nfe">
    <NFe>
        <infNFe Id="NFe35260912345678000199550010000000021234567890">
            <ide>
                <mod>55</mod>
            </ide>
            <emit>
                <CNPJ>12345678000199</CNPJ>
                <xNome>EMPRESA</xNome>
                <CRT>3</CRT>
            </emit>
            <det nItem="1">
                <prod>
                    <cProd>P1</cProd>
                    <xProd>PROD</xProd>
                    <NCM>00000000</NCM>
                    <CFOP>5102</CFOP>
                    <uCom>UN</uCom>
                    <qCom>1.0000</qCom>
                    <vUnCom>10.00</vUnCom>
                    <vProd>10.00</vProd>
                    <uTrib>UN</uTrib>
                    <qTrib>1.0000</qTrib>
                    <vUnTrib>10.00</vUnTrib>
                    <indTot>1</indTot>
                </prod>
                <imposto>
                    <ICMS>
                        <ICMS00>
                            <orig>0</orig>
                            <CST>00</CST>
                            <modBC>3</modBC>
                            <vBC>10.00</vBC>
                            <pICMS>0.0000</pICMS>
                            <vICMS>0.00</vICMS>
                        </ICMS00>
                    </ICMS>
                    <PIS>
                        <PISNT>
                            <CST>07</CST>
                        </PISNT>
                    </PIS>
                    <COFINS>
                        <COFINSNT>
                            <CST>07</CST>
                        </COFINSNT>
                    </COFINS>
                </imposto>
            </det>
            <total>
                <ICMSTot>
                    <vBC>0.00</vBC>
                    <vICMS>0.00</vICMS>
                    <vICMSDeson>0.00</vICMSDeson>
                    <vFCP>0.00</vFCP>
                    <vBCST>0.00</vBCST>
                    <vST>0.00</vST>
                    <vFCPST>0.00</vFCPST>
                    <vFCPSTRet>0.00</vFCPSTRet>
                    <vProd>10.00</vProd>
                    <vFrete>0.00</vFrete>
                    <vSeg>0.00</vSeg>
                    <vDesc>0.00</vDesc>
                    <vII>0.00</vII>
                    <vIPI>0.00</vIPI>
                    <vIPIDevol>0.00</vIPIDevol>
                    <vPIS>0.00</vPIS>
                    <vCOFINS>0.00</vCOFINS>
                    <vOutro>0.00</vOutro>
                    <vNF>10.00</vNF>
                </ICMSTot>
            </total>
        </infNFe>
    </NFe>
</nfeProc>
'@

                $result = Get-DFeNFeFiscalData -Xml $xml

                $result.ChaveAcesso | Should -Be '35260912345678000199550010000000021234567890'
                $result.Modelo      | Should -Be ([ModeloDFe]::NFe)
            }
        }
        #endregion


        #region Identificacao
        Context 'Identificacao' {

            It 'Extracts ide fields' {
                [xml]$xml = $Script:MinimalNFe

                $result = Get-DFeNFeFiscalData -Xml $xml

                $result.Identificacao.CUF               | Should -Be '35'
                $result.Identificacao.NaturezaOperacao  | Should -Be 'VENDA'
                $result.Identificacao.Modelo            | Should -Be '55'
                $result.Identificacao.Serie             | Should -Be '1'
                $result.Identificacao.Numero            | Should -Be '1'
                $result.Identificacao.DhEmi             | Should -Be '2026-09-23T10:00:00-03:00'
                $result.Identificacao.TipoOperacao      | Should -Be '1'
                $result.Identificacao.IdDestino         | Should -Be '1'
                $result.Identificacao.Finalidade        | Should -Be '1'
                $result.Identificacao.ConsumidorFinal   | Should -Be '1'
                $result.Identificacao.IndicadorPresenca | Should -Be '1'
            }
        }
        #endregion


        #region Participantes
        Context 'Emitente' {

            It 'Extracts emit fields' {
                [xml]$xml = $Script:MinimalNFe

                $result = Get-DFeNFeFiscalData -Xml $xml

                $result.Emitente.Cnpj        | Should -Be '12345678000199'
                $result.Emitente.RazaoSocial | Should -Be 'EMPRESA TESTE LTDA'
                $result.Emitente.IE          | Should -Be '123456789'
                $result.Emitente.CRT         | Should -Be '3'
            }

            It 'Extracts emit Endereco fields' {
                [xml]$xml = @'
<NFe xmlns="http://www.portalfiscal.inf.br/nfe">
    <infNFe Id="NFe35260912345678000199550010000000011234567890">
        <ide>
            <mod>55</mod>
        </ide>
        <emit>
            <CNPJ>12345678000199</CNPJ>
            <xNome>EMPRESA TESTE LTDA</xNome>
            <CRT>3</CRT>
            <enderEmit>
                <xLgr>RUA TESTE</xLgr>
                <nro>100</nro>
                <xBairro>CENTRO</xBairro>
                <cMun>3550308</cMun>
                <xMun>SAO PAULO</xMun>
                <UF>SP</UF>
                <CEP>01310100</CEP>
                <cPais>1058</cPais>
                <xPais>BRASIL</xPais>
                <fone>1133334444</fone>
            </enderEmit>
        </emit>
        <det nItem="1">
            <prod>
                <cProd>P1</cProd>
                <xProd>P</xProd>
                <NCM>00000000</NCM>
                <CFOP>5102</CFOP>
                <uCom>UN</uCom>
                <qCom>1.0000</qCom>
                <vUnCom>10.00</vUnCom>
                <vProd>10.00</vProd>
                <uTrib>UN</uTrib>
                <qTrib>1.0000</qTrib>
                <vUnTrib>10.00</vUnTrib>
                <indTot>1</indTot>
            </prod>
            <imposto>
                <ICMS>
                    <ICMS00>
                        <orig>0</orig>
                        <CST>00</CST>
                        <modBC>3</modBC>
                        <vBC>10.00</vBC>
                        <pICMS>0.0000</pICMS>
                        <vICMS>0.00</vICMS>
                    </ICMS00>
                </ICMS>
                <PIS>
                    <PISNT>
                        <CST>07</CST>
                    </PISNT>
                </PIS>
                <COFINS>
                    <COFINSNT>
                        <CST>07</CST>
                    </COFINSNT>
                </COFINS>
            </imposto>
        </det>
        <total>
            <ICMSTot>
                <vBC>0.00</vBC>
                <vICMS>0.00</vICMS>
                <vICMSDeson>0.00</vICMSDeson>
                <vFCP>0.00</vFCP>
                <vBCST>0.00</vBCST>
                <vST>0.00</vST>
                <vFCPST>0.00</vFCPST>
                <vFCPSTRet>0.00</vFCPSTRet>
                <vProd>10.00</vProd>
                <vFrete>0.00</vFrete>
                <vSeg>0.00</vSeg>
                <vDesc>0.00</vDesc>
                <vII>0.00</vII>
                <vIPI>0.00</vIPI>
                <vIPIDevol>0.00</vIPIDevol>
                <vPIS>0.00</vPIS>
                <vCOFINS>0.00</vCOFINS>
                <vOutro>0.00</vOutro>
                <vNF>10.00</vNF>
            </ICMSTot>
        </total>
    </infNFe>
</NFe>
'@

                $result = Get-DFeNFeFiscalData -Xml $xml

                $result.Emitente.Endereco.Logradouro      | Should -Be 'RUA TESTE'
                $result.Emitente.Endereco.Numero          | Should -Be '100'
                $result.Emitente.Endereco.Bairro          | Should -Be 'CENTRO'
                $result.Emitente.Endereco.CodigoMunicipio | Should -Be '3550308'
                $result.Emitente.Endereco.Municipio       | Should -Be 'SAO PAULO'
                $result.Emitente.Endereco.UF              | Should -Be 'SP'
                $result.Emitente.Endereco.CEP             | Should -Be '01310100'
                $result.Emitente.Endereco.Pais            | Should -Be 'BRASIL'
                $result.Emitente.Endereco.Telefone        | Should -Be '1133334444'
            }
        }

        Context 'Destinatario' {

            It 'Extracts dest fields' {
                [xml]$xml = $Script:MinimalNFe

                $result = Get-DFeNFeFiscalData -Xml $xml

                $result.Destinatario.Cnpj        | Should -Be '98765432000199'
                $result.Destinatario.RazaoSocial | Should -Be 'CLIENTE TESTE LTDA'
                $result.Destinatario.IndIEDest   | Should -Be '1'
            }

            It 'Returns null Destinatario when dest is absent' {
                [xml]$xml = @'
<NFe xmlns="http://www.portalfiscal.inf.br/nfe">
    <infNFe Id="NFe35260912345678000199650010000000011234567890">
        <ide>
            <mod>65</mod>
        </ide>
        <emit>
            <CNPJ>12345678000199</CNPJ>
            <xNome>EMPRESA</xNome>
            <CRT>3</CRT>
        </emit>
        <det nItem="1">
            <prod>
                <cProd>P1</cProd>
                <xProd>P</xProd>
                <NCM>00000000</NCM>
                <CFOP>5102</CFOP>
                <uCom>UN</uCom>
                <qCom>1.0000</qCom>
                <vUnCom>10.00</vUnCom>
                <vProd>10.00</vProd>
                <uTrib>UN</uTrib>
                <qTrib>1.0000</qTrib>
                <vUnTrib>10.00</vUnTrib>
                <indTot>1</indTot>
            </prod>
            <imposto>
                <ICMS>
                    <ICMS00>
                        <orig>0</orig>
                        <CST>00</CST>
                        <modBC>3</modBC>
                        <vBC>10.00</vBC>
                        <pICMS>0.0000</pICMS>
                        <vICMS>0.00</vICMS>
                    </ICMS00>
                </ICMS>
                <PIS>
                    <PISNT>
                        <CST>07</CST>
                    </PISNT>
                </PIS>
                <COFINS>
                    <COFINSNT>
                        <CST>07</CST>
                    </COFINSNT>
                </COFINS>
            </imposto>
        </det>
        <total>
            <ICMSTot>
                <vBC>0.00</vBC>
                <vICMS>0.00</vICMS>
                <vICMSDeson>0.00</vICMSDeson>
                <vFCP>0.00</vFCP>
                <vBCST>0.00</vBCST>
                <vST>0.00</vST>
                <vFCPST>0.00</vFCPST>
                <vFCPSTRet>0.00</vFCPSTRet>
                <vProd>10.00</vProd>
                <vFrete>0.00</vFrete>
                <vSeg>0.00</vSeg>
                <vDesc>0.00</vDesc>
                <vII>0.00</vII>
                <vIPI>0.00</vIPI>
                <vIPIDevol>0.00</vIPIDevol>
                <vPIS>0.00</vPIS>
                <vCOFINS>0.00</vCOFINS>
                <vOutro>0.00</vOutro>
                <vNF>10.00</vNF>
            </ICMSTot>
        </total>
    </infNFe>
</NFe>
'@

                $result = Get-DFeNFeFiscalData -Xml $xml

                $result.Destinatario | Should -BeNullOrEmpty
            }
        }
        #endregion


        #region Itens
        Context 'Itens' {

            It 'Returns item count matching det count' {
                [xml]$xml = $Script:MinimalNFe

                $result = Get-DFeNFeFiscalData -Xml $xml

                $result.Itens | Should -HaveCount 1
            }

            It 'Parses nItem attribute as int' {
                [xml]$xml = $Script:MinimalNFe

                $result = Get-DFeNFeFiscalData -Xml $xml

                $result.Itens[0].Numero | Should -Be 1
                $result.Itens[0].Numero | Should -BeOfType [int]
            }

            It 'Extracts Produto fields' {
                [xml]$xml = $Script:MinimalNFe

                $result = Get-DFeNFeFiscalData -Xml $xml

                $result.Itens[0].Produto.Codigo       | Should -Be 'ABC001'
                $result.Itens[0].Produto.Descricao    | Should -Be 'PRODUTO TESTE'
                $result.Itens[0].Produto.NCM          | Should -Be '12345678'
                $result.Itens[0].Produto.CFOP         | Should -Be '5102'
                $result.Itens[0].Produto.Unidade      | Should -Be 'UN'
                $result.Itens[0].Produto.IndTotal     | Should -Be '1'
            }

            It 'Preserves decimal precision on Produto monetary fields' {
                [xml]$xml = $Script:MinimalNFe

                $result = Get-DFeNFeFiscalData -Xml $xml

                $result.Itens[0].Produto.Quantidade    | Should -Be ([decimal]2)
                $result.Itens[0].Produto.ValorUnitario | Should -Be ([decimal]50)
                $result.Itens[0].Produto.ValorProduto  | Should -Be ([decimal]100)
            }
        }
        #endregion

        #region Tributos por item
        Context 'ICMS' {

            It 'Extracts ICMS00 group name and fields' {
                [xml]$xml = $Script:MinimalNFe

                $result = Get-DFeNFeFiscalData -Xml $xml

                $result.Itens[0].Tributos.ICMS.Grupo | Should -Be 'ICMS00'
                $result.Itens[0].Tributos.ICMS.Orig  | Should -Be '0'
                $result.Itens[0].Tributos.ICMS.CST   | Should -Be '00'
                $result.Itens[0].Tributos.ICMS.ModBC | Should -Be '3'
                $result.Itens[0].Tributos.ICMS.VBC   | Should -Be ([decimal]100)
                $result.Itens[0].Tributos.ICMS.PICMS | Should -Be ([decimal]18)
                $result.Itens[0].Tributos.ICMS.VICMS | Should -Be ([decimal]18)
            }

            It 'Extracts ICMS10 ST fields' {
                [xml]$xml = @'
<NFe xmlns="http://www.portalfiscal.inf.br/nfe">
    <infNFe Id="NFe35260912345678000199550010000000011234567890">
        <ide>
            <mod>55</mod>
        </ide>
        <emit>
            <CNPJ>12345678000199</CNPJ>
            <xNome>EMPRESA</xNome>
            <CRT>2</CRT>
        </emit>
        <det nItem="1">
            <prod>
                <cProd>P1</cProd>
                <xProd>P</xProd>
                <NCM>00000000</NCM>
                <CFOP>5401</CFOP>
                <uCom>UN</uCom>
                <qCom>1.0000</qCom>
                <vUnCom>50.00</vUnCom>
                <vProd>50.00</vProd>
                <uTrib>UN</uTrib>
                <qTrib>1.0000</qTrib>
                <vUnTrib>50.00</vUnTrib>
                <indTot>1</indTot>
            </prod>
            <imposto>
                <ICMS>
                    <ICMS10>
                        <orig>0</orig>
                        <CST>10</CST>
                        <modBC>3</modBC>
                        <vBC>50.00</vBC>
                        <pICMS>18.0000</pICMS>
                        <vICMS>9.00</vICMS>
                        <modBCST>3</modBCST>
                        <pMVAST>72.1500</pMVAST>
                        <pRedBCST>0.0000</pRedBCST>
                        <vBCST>86.08</vBCST>
                        <pICMSST>18.0000</pICMSST>
                        <vICMSST>6.49</vICMSST>
                    </ICMS10>
                </ICMS>
                <PIS>
                    <PISNT>
                        <CST>99</CST>
                    </PISNT>
                </PIS>
                <COFINS>
                    <COFINSNT>
                        <CST>99</CST>
                    </COFINSNT>
                </COFINS>
            </imposto>
        </det>
        <total>
            <ICMSTot>
                <vBC>50.00</vBC>
                <vICMS>9.00</vICMS>
                <vICMSDeson>0.00</vICMSDeson>
                <vFCP>0.00</vFCP>
                <vBCST>86.08</vBCST>
                <vST>6.49</vST>
                <vFCPST>0.00</vFCPST>
                <vFCPSTRet>0.00</vFCPSTRet>
                <vProd>50.00</vProd>
                <vFrete>0.00</vFrete>
                <vSeg>0.00</vSeg>
                <vDesc>0.00</vDesc>
                <vII>0.00</vII>
                <vIPI>0.00</vIPI>
                <vIPIDevol>0.00</vIPIDevol>
                <vPIS>0.00</vPIS>
                <vCOFINS>0.00</vCOFINS>
                <vOutro>0.00</vOutro>
                <vNF>56.49</vNF>
            </ICMSTot>
        </total>
    </infNFe>
</NFe>
'@

                $result = Get-DFeNFeFiscalData -Xml $xml

                $result.Itens[0].Tributos.ICMS.Grupo   | Should -Be 'ICMS10'
                $result.Itens[0].Tributos.ICMS.ModBCST | Should -Be '3'
                $result.Itens[0].Tributos.ICMS.PMVAST  | Should -Be ([decimal]72.15)
                $result.Itens[0].Tributos.ICMS.VBCST   | Should -Be ([decimal]86.08)
                $result.Itens[0].Tributos.ICMS.PICMSST | Should -Be ([decimal]18)
                $result.Itens[0].Tributos.ICMS.VICMSST | Should -Be ([decimal]6.49)
            }

            It 'Extracts CSOSN from Simples Nacional ICMS group' {
                [xml]$xml = @'
<NFe xmlns="http://www.portalfiscal.inf.br/nfe">
    <infNFe Id="NFe35260912345678000199550010000000011234567890">
        <ide>
            <mod>55</mod>
        </ide>
        <emit>
            <CNPJ>12345678000199</CNPJ>
            <xNome>EMPRESA</xNome>
            <CRT>1</CRT>
        </emit>
        <det nItem="1">
            <prod>
                <cProd>P1</cProd>
                <xProd>P</xProd>
                <NCM>00000000</NCM>
                <CFOP>5102</CFOP>
                <uCom>UN</uCom>
                <qCom>1.0000</qCom>
                <vUnCom>10.00</vUnCom>
                <vProd>10.00</vProd>
                <uTrib>UN</uTrib>
                <qTrib>1.0000</qTrib>
                <vUnTrib>10.00</vUnTrib>
                <indTot>1</indTot>
            </prod>
            <imposto>
                <ICMS>
                    <ICMSSN102>
                        <orig>0</orig>
                        <CSOSN>102</CSOSN>
                    </ICMSSN102>
                </ICMS>
                <PIS>
                    <PISNT>
                        <CST>07</CST>
                    </PISNT>
                </PIS>
                <COFINS>
                    <COFINSNT>
                        <CST>07</CST>
                    </COFINSNT>
                </COFINS>
            </imposto>
        </det>
        <total>
            <ICMSTot>
                <vBC>0.00</vBC>
                <vICMS>0.00</vICMS>
                <vICMSDeson>0.00</vICMSDeson>
                <vFCP>0.00</vFCP>
                <vBCST>0.00</vBCST>
                <vST>0.00</vST>
                <vFCPST>0.00</vFCPST>
                <vFCPSTRet>0.00</vFCPSTRet>
                <vProd>10.00</vProd>
                <vFrete>0.00</vFrete>
                <vSeg>0.00</vSeg>
                <vDesc>0.00</vDesc>
                <vII>0.00</vII>
                <vIPI>0.00</vIPI>
                <vIPIDevol>0.00</vIPIDevol>
                <vPIS>0.00</vPIS>
                <vCOFINS>0.00</vCOFINS>
                <vOutro>0.00</vOutro>
                <vNF>10.00</vNF>
            </ICMSTot>
        </total>
    </infNFe>
</NFe>
'@

                $result = Get-DFeNFeFiscalData -Xml $xml

                $result.Itens[0].Tributos.ICMS.Grupo | Should -Be 'ICMSSN102'
                $result.Itens[0].Tributos.ICMS.CSOSN | Should -Be '102'
            }
        }

        Context 'IPI' {

            It 'Extracts IPITrib fields' {
                [xml]$xml = @'
<NFe xmlns="http://www.portalfiscal.inf.br/nfe">
    <infNFe Id="NFe35260912345678000199550010000000011234567890">
        <ide>
            <mod>55</mod>
        </ide>
        <emit>
            <CNPJ>12345678000199</CNPJ>
            <xNome>EMPRESA</xNome>
            <CRT>3</CRT>
        </emit>
        <det nItem="1">
            <prod>
                <cProd>P1</cProd>
                <xProd>P</xProd>
                <NCM>00000000</NCM>
                <CFOP>5102</CFOP>
                <uCom>UN</uCom>
                <qCom>1.0000</qCom>
                <vUnCom>100.00</vUnCom>
                <vProd>100.00</vProd>
                <uTrib>UN</uTrib>
                <qTrib>1.0000</qTrib>
                <vUnTrib>100.00</vUnTrib>
                <indTot>1</indTot>
            </prod>
            <imposto>
                <ICMS>
                    <ICMS00>
                        <orig>0</orig>
                        <CST>00</CST>
                        <modBC>3</modBC>
                        <vBC>100.00</vBC>
                        <pICMS>0.0000</pICMS>
                        <vICMS>0.00</vICMS>
                    </ICMS00>
                </ICMS>
                <IPI>
                    <cEnq>999</cEnq>
                    <IPITrib>
                        <CST>50</CST>
                        <vBC>100.00</vBC>
                        <pIPI>5.0000</pIPI>
                        <vIPI>5.00</vIPI>
                    </IPITrib>
                </IPI>
                <PIS>
                    <PISNT>
                        <CST>07</CST>
                    </PISNT>
                </PIS>
                <COFINS>
                    <COFINSNT>
                        <CST>07</CST>
                    </COFINSNT>
                </COFINS>
            </imposto>
        </det>
        <total>
            <ICMSTot>
                <vBC>0.00</vBC>
                <vICMS>0.00</vICMS>
                <vICMSDeson>0.00</vICMSDeson>
                <vFCP>0.00</vFCP>
                <vBCST>0.00</vBCST>
                <vST>0.00</vST>
                <vFCPST>0.00</vFCPST>
                <vFCPSTRet>0.00</vFCPSTRet>
                <vProd>100.00</vProd>
                <vFrete>0.00</vFrete>
                <vSeg>0.00</vSeg>
                <vDesc>0.00</vDesc>
                <vII>0.00</vII>
                <vIPI>5.00</vIPI>
                <vIPIDevol>0.00</vIPIDevol>
                <vPIS>0.00</vPIS>
                <vCOFINS>0.00</vCOFINS>
                <vOutro>0.00</vOutro>
                <vNF>105.00</vNF>
            </ICMSTot>
        </total>
    </infNFe>
</NFe>
'@

                $result = Get-DFeNFeFiscalData -Xml $xml

                $result.Itens[0].Tributos.IPI.Grupo | Should -Be 'IPITrib'
                $result.Itens[0].Tributos.IPI.CEnq  | Should -Be '999'
                $result.Itens[0].Tributos.IPI.CST   | Should -Be '50'
                $result.Itens[0].Tributos.IPI.VBC   | Should -Be ([decimal]100)
                $result.Itens[0].Tributos.IPI.PIPI  | Should -Be ([decimal]5)
                $result.Itens[0].Tributos.IPI.VIPI  | Should -Be ([decimal]5)
            }

            It 'Extracts IPINT group name' {
                [xml]$xml = $Script:MinimalNFe

                # MinimalNFe does not have IPI - inject one via string replacement
                [xml]$xml = $Script:MinimalNFe.Replace(
                    '</imposto>',
                    @'
                        <IPI>
                            <cEnq>999</cEnq>
                            <IPINT>
                                <CST>53</CST>
                            </IPINT>
                        </IPI>
                    </imposto>
'@

                )

                $result = Get-DFeNFeFiscalData -Xml $xml

                $result.Itens[0].Tributos.IPI.Grupo | Should -Be 'IPINT'
                $result.Itens[0].Tributos.IPI.CST   | Should -Be '53'
            }

            It 'Returns null IPI when absent' {
                [xml]$xml = $Script:MinimalNFe

                $result = Get-DFeNFeFiscalData -Xml $xml

                $result.Itens[0].Tributos.IPI | Should -BeNullOrEmpty
            }
        }

        Context 'PIS' {

            It 'Extracts PISAliq fields' {
                [xml]$xml = $Script:MinimalNFe

                $result = Get-DFeNFeFiscalData -Xml $xml

                $result.Itens[0].Tributos.PIS.Grupo | Should -Be 'PISAliq'
                $result.Itens[0].Tributos.PIS.CST   | Should -Be '01'
                $result.Itens[0].Tributos.PIS.VBC   | Should -Be ([decimal]100)
                $result.Itens[0].Tributos.PIS.PPIS  | Should -Be ([decimal]1.65)
                $result.Itens[0].Tributos.PIS.VPIS  | Should -Be ([decimal]1.65)
            }

            It 'Extracts PISNT group name' {
                [xml]$xml = @'
<NFe xmlns="http://www.portalfiscal.inf.br/nfe">
    <infNFe Id="NFe35260912345678000199550010000000011234567890">
        <ide>
            <mod>55</mod>
        </ide>
        <emit>
            <CNPJ>12345678000199</CNPJ>
            <xNome>EMPRESA</xNome>
            <CRT>3</CRT>
        </emit>
        <det nItem="1">
            <prod>
                <cProd>P1</cProd>
                <xProd>P</xProd>
                <NCM>00000000</NCM>
                <CFOP>5102</CFOP>
                <uCom>UN</uCom>
                <qCom>1.0000</qCom>
                <vUnCom>10.00</vUnCom>
                <vProd>10.00</vProd>
                <uTrib>UN</uTrib>
                <qTrib>1.0000</qTrib>
                <vUnTrib>10.00</vUnTrib>
                <indTot>1</indTot>
            </prod>
            <imposto>
                <ICMS>
                    <ICMS00>
                        <orig>0</orig>
                        <CST>00</CST>
                        <modBC>3</modBC>
                        <vBC>10.00</vBC>
                        <pICMS>0.0000</pICMS>
                        <vICMS>0.00</vICMS>
                    </ICMS00>
                </ICMS>
                <PIS>
                    <PISNT>
                        <CST>04</CST>
                    </PISNT>
                </PIS>
                <COFINS>
                    <COFINSNT>
                        <CST>04</CST>
                    </COFINSNT>
                </COFINS>
            </imposto>
        </det>
        <total>
            <ICMSTot>
                <vBC>0.00</vBC>
                <vICMS>0.00</vICMS>
                <vICMSDeson>0.00</vICMSDeson>
                <vFCP>0.00</vFCP>
                <vBCST>0.00</vBCST>
                <vST>0.00</vST>
                <vFCPST>0.00</vFCPST>
                <vFCPSTRet>0.00</vFCPSTRet>
                <vProd>10.00</vProd>
                <vFrete>0.00</vFrete>
                <vSeg>0.00</vSeg>
                <vDesc>0.00</vDesc>
                <vII>0.00</vII>
                <vIPI>0.00</vIPI>
                <vIPIDevol>0.00</vIPIDevol>
                <vPIS>0.00</vPIS>
                <vCOFINS>0.00</vCOFINS>
                <vOutro>0.00</vOutro>
                <vNF>10.00</vNF>
            </ICMSTot>
        </total>
    </infNFe>
</NFe>
'@

                $result = Get-DFeNFeFiscalData -Xml $xml

                $result.Itens[0].Tributos.PIS.Grupo | Should -Be 'PISNT'
                $result.Itens[0].Tributos.PIS.CST   | Should -Be '04'
                $result.Itens[0].Tributos.PIS.VPIS  | Should -BeNullOrEmpty
            }
        }

        Context 'COFINS' {

            It 'Extracts COFINSAliq fields' {
                [xml]$xml = $Script:MinimalNFe

                $result = Get-DFeNFeFiscalData -Xml $xml

                $result.Itens[0].Tributos.COFINS.Grupo   | Should -Be 'COFINSAliq'
                $result.Itens[0].Tributos.COFINS.CST     | Should -Be '01'
                $result.Itens[0].Tributos.COFINS.VBC     | Should -Be ([decimal]100)
                $result.Itens[0].Tributos.COFINS.PCOFINS | Should -Be ([decimal]7.6)
                $result.Itens[0].Tributos.COFINS.VCOFINS | Should -Be ([decimal]7.6)
            }

            It 'Extracts COFINSNT group name' {
                [xml]$xml = @'
<NFe xmlns="http://www.portalfiscal.inf.br/nfe">
    <infNFe Id="NFe35260912345678000199550010000000011234567890">
        <ide>
            <mod>55</mod>
        </ide>
        <emit>
            <CNPJ>12345678000199</CNPJ>
            <xNome>EMPRESA</xNome>
            <CRT>3</CRT>
        </emit>
        <det nItem="1">
            <prod>
                <cProd>P1</cProd>
                <xProd>P</xProd>
                <NCM>00000000</NCM>
                <CFOP>5102</CFOP>
                <uCom>UN</uCom>
                <qCom>1.0000</qCom>
                <vUnCom>10.00</vUnCom>
                <vProd>10.00</vProd>
                <uTrib>UN</uTrib>
                <qTrib>1.0000</qTrib>
                <vUnTrib>10.00</vUnTrib>
                <indTot>1</indTot>
            </prod>
            <imposto>
                <ICMS>
                    <ICMS00>
                        <orig>0</orig>
                        <CST>00</CST>
                        <modBC>3</modBC>
                        <vBC>10.00</vBC>
                        <pICMS>0.0000</pICMS>
                        <vICMS>0.00</vICMS>
                    </ICMS00>
                </ICMS>
                <PIS>
                    <PISNT>
                        <CST>04</CST>
                    </PISNT>
                </PIS>
                <COFINS>
                    <COFINSNT>
                        <CST>04</CST>
                    </COFINSNT>
                </COFINS>
            </imposto>
        </det>
        <total>
            <ICMSTot>
                <vBC>0.00</vBC>
                <vICMS>0.00</vICMS>
                <vICMSDeson>0.00</vICMSDeson>
                <vFCP>0.00</vFCP>
                <vBCST>0.00</vBCST>
                <vST>0.00</vST>
                <vFCPST>0.00</vFCPST>
                <vFCPSTRet>0.00</vFCPSTRet>
                <vProd>10.00</vProd>
                <vFrete>0.00</vFrete>
                <vSeg>0.00</vSeg>
                <vDesc>0.00</vDesc>
                <vII>0.00</vII>
                <vIPI>0.00</vIPI>
                <vIPIDevol>0.00</vIPIDevol>
                <vPIS>0.00</vPIS>
                <vCOFINS>0.00</vCOFINS>
                <vOutro>0.00</vOutro>
                <vNF>10.00</vNF>
            </ICMSTot>
        </total>
    </infNFe>
</NFe>
'@

                $result = Get-DFeNFeFiscalData -Xml $xml

                $result.Itens[0].Tributos.COFINS.Grupo   | Should -Be 'COFINSNT'
                $result.Itens[0].Tributos.COFINS.CST     | Should -Be '04'
                $result.Itens[0].Tributos.COFINS.VCOFINS | Should -BeNullOrEmpty
            }
        }

        Context 'IBSCBS por item' {

            It 'Extracts IBSCBS fields when present' {
                [xml]$xml = @'
<NFe xmlns="http://www.portalfiscal.inf.br/nfe">
    <infNFe Id="NFe35260912345678000199550010000000011234567890">
        <ide>
            <mod>55</mod>
        </ide>
        <emit>
            <CNPJ>12345678000199</CNPJ>
            <xNome>EMPRESA</xNome>
            <CRT>3</CRT>
        </emit>
        <det nItem="1">
            <prod>
                <cProd>P1</cProd>
                <xProd>P</xProd>
                <NCM>00000000</NCM>
                <CFOP>5102</CFOP>
                <uCom>UN</uCom>
                <qCom>1.0000</qCom>
                <vUnCom>10.00</vUnCom>
                <vProd>10.00</vProd>
                <uTrib>UN</uTrib>
                <qTrib>1.0000</qTrib>
                <vUnTrib>10.00</vUnTrib>
                <indTot>1</indTot>
            </prod>
            <imposto>
                <ICMS>
                    <ICMS00>
                        <orig>0</orig>
                        <CST>00</CST>
                        <modBC>3</modBC>
                        <vBC>10.00</vBC>
                        <pICMS>0.0000</pICMS>
                        <vICMS>0.00</vICMS>
                    </ICMS00>
                </ICMS>
                <PIS>
                    <PISNT>
                        <CST>07</CST>
                    </PISNT>
                </PIS>
                <COFINS>
                    <COFINSNT>
                        <CST>07</CST>
                    </COFINSNT>
                </COFINS>
                <IBSCBS>
                    <CST>000</CST>
                    <cClassTrib>000001</cClassTrib>
                    <gIBSCBS>
                        <vBC>95.24</vBC>
                        <gIBSUF>
                            <pIBSUF>0.1000</pIBSUF>
                            <vIBSUF>0.10</vIBSUF>
                        </gIBSUF>
                        <gIBSMun>
                            <pIBSMun>0.0000</pIBSMun>
                            <vIBSMun>0.00</vIBSMun>
                        </gIBSMun>
                        <vIBS>0.10</vIBS>
                        <gCBS>
                            <pCBS>0.9000</pCBS>
                            <vCBS>0.86</vCBS>
                        </gCBS>
                    </gIBSCBS>
                </IBSCBS>
            </imposto>
        </det>
        <total>
            <ICMSTot>
                <vBC>0.00</vBC>
                <vICMS>0.00</vICMS>
                <vICMSDeson>0.00</vICMSDeson>
                <vFCP>0.00</vFCP>
                <vBCST>0.00</vBCST>
                <vST>0.00</vST>
                <vFCPST>0.00</vFCPST>
                <vFCPSTRet>0.00</vFCPSTRet>
                <vProd>10.00</vProd>
                <vFrete>0.00</vFrete>
                <vSeg>0.00</vSeg>
                <vDesc>0.00</vDesc>
                <vII>0.00</vII>
                <vIPI>0.00</vIPI>
                <vIPIDevol>0.00</vIPIDevol>
                <vPIS>0.00</vPIS>
                <vCOFINS>0.00</vCOFINS>
                <vOutro>0.00</vOutro>
                <vNF>10.00</vNF>
            </ICMSTot>
        </total>
    </infNFe>
</NFe>
'@

                $result = Get-DFeNFeFiscalData -Xml $xml

                $result.Itens[0].Tributos.IBSCBS.CST        | Should -Be '000'
                $result.Itens[0].Tributos.IBSCBS.CClassTrib | Should -Be '000001'
                $result.Itens[0].Tributos.IBSCBS.VBC        | Should -Be ([decimal]95.24)
                $result.Itens[0].Tributos.IBSCBS.PIBSUF     | Should -Be ([decimal]0.1)
                $result.Itens[0].Tributos.IBSCBS.VIBSUF     | Should -Be ([decimal]0.10)
                $result.Itens[0].Tributos.IBSCBS.PIBSMun    | Should -Be ([decimal]0)
                $result.Itens[0].Tributos.IBSCBS.VIBSMun    | Should -Be ([decimal]0)
                $result.Itens[0].Tributos.IBSCBS.VIBS       | Should -Be ([decimal]0.10)
                $result.Itens[0].Tributos.IBSCBS.PCBS       | Should -Be ([decimal]0.9)
                $result.Itens[0].Tributos.IBSCBS.VCBS       | Should -Be ([decimal]0.86)
            }

            It 'Returns null IBSCBS when absent' {
                [xml]$xml = $Script:MinimalNFe

                $result = Get-DFeNFeFiscalData -Xml $xml

                $result.Itens[0].Tributos.IBSCBS | Should -BeNullOrEmpty
            }
        }
        #endregion

        #region Totais
        Context 'Totais' {

            It 'Extracts ICMSTot fields' {
                [xml]$xml = $Script:MinimalNFe

                $result = Get-DFeNFeFiscalData -Xml $xml

                $result.Totais.VBC     | Should -Be ([decimal]100)
                $result.Totais.VICMS   | Should -Be ([decimal]18)
                $result.Totais.VProd   | Should -Be ([decimal]100)
                $result.Totais.VPIS    | Should -Be ([decimal]1.65)
                $result.Totais.VCOFINS | Should -Be ([decimal]7.6)
                $result.Totais.VNF     | Should -Be ([decimal]100)
            }

            It 'Returns null Totais when ICMSTot is absent' {
                [xml]$xml = @'
<NFe xmlns="http://www.portalfiscal.inf.br/nfe">
    <infNFe Id="NFe35260912345678000199550010000000011234567890">
        <ide>
            <mod>55</mod>
        </ide>
        <emit>
            <CNPJ>12345678000199</CNPJ>
            <xNome>EMPRESA</xNome>
            <CRT>3</CRT>
        </emit>
        <det nItem="1">
            <prod>
                <cProd>P1</cProd>
                <xProd>P</xProd>
                <NCM>00000000</NCM>
                <CFOP>5102</CFOP>
                <uCom>UN</uCom>
                <qCom>1.0000</qCom>
                <vUnCom>10.00</vUnCom>
                <vProd>10.00</vProd>
                <uTrib>UN</uTrib>
                <qTrib>1.0000</qTrib>
                <vUnTrib>10.00</vUnTrib>
                <indTot>1</indTot>
            </prod>
            <imposto>
                <ICMS>
                    <ICMS00>
                        <orig>0</orig>
                        <CST>00</CST>
                        <modBC>3</modBC>
                        <vBC>10.00</vBC>
                        <pICMS>0.0000</pICMS>
                        <vICMS>0.00</vICMS>
                    </ICMS00>
                </ICMS>
                <PIS>
                    <PISNT>
                        <CST>07</CST>
                    </PISNT>
                </PIS>
                <COFINS>
                    <COFINSNT>
                        <CST>07</CST>
                    </COFINSNT>
                </COFINS>
            </imposto>
        </det>
        <total />
    </infNFe>
</NFe>
'@

                $result = Get-DFeNFeFiscalData -Xml $xml

                $result.Totais | Should -BeNullOrEmpty
            }

            It 'Extracts IBSCBSTot fields when present' {
                [xml]$xml = $Script:MinimalNFe.Replace(
                    '</total>',
                    @'
                        <IBSCBSTot>
                            <vBCIBSCBS>95.24</vBCIBSCBS>
                            <gIBS>
                                <gIBSUF>
                                    <vIBSUF>0.10</vIBSUF>
                                    <vDif>0.00</vDif>
                                    <vDevTrib>0.00</vDevTrib>
                                </gIBSUF>
                                <gIBSMun>
                                    <vIBSMun>0.00</vIBSMun>
                                    <vDif>0.00</vDif>
                                    <vDevTrib>0.00</vDevTrib>
                                </gIBSMun>
                                <vIBS>0.10</vIBS>
                                <vCredPres>0.00</vCredPres>
                                <vCredPresCondSus>0.00</vCredPresCondSus>
                            </gIBS>
                            <gCBS>
                                <vCBS>0.86</vCBS>
                                <vDif>0.00</vDif>
                                <vDevTrib>0.00</vDevTrib>
                                <vCredPres>0.00</vCredPres>
                                <vCredPresCondSus>0.00</vCredPresCondSus>
                            </gCBS>
                        </IBSCBSTot>
                    </total>
'@
                )

                $result = Get-DFeNFeFiscalData -Xml $xml

                $result.Totais.IBSCBSTot.VBCIBSCbs        | Should -Be ([decimal]95.24)
                $result.Totais.IBSCBSTot.VIBSUF           | Should -Be ([decimal]0.10)
                $result.Totais.IBSCBSTot.VIBSMun          | Should -Be ([decimal]0)
                $result.Totais.IBSCBSTot.VIBS             | Should -Be ([decimal]0.10)
                $result.Totais.IBSCBSTot.VCredPres        | Should -Be ([decimal]0)
                $result.Totais.IBSCBSTot.VCredPresCondSus | Should -Be ([decimal]0)
                $result.Totais.IBSCBSTot.VCBS             | Should -Be ([decimal]0.86)
            }

            It 'Returns null IBSCBSTot when absent' {
                [xml]$xml = $Script:MinimalNFe

                $result = Get-DFeNFeFiscalData -Xml $xml

                $result.Totais.IBSCBSTot | Should -BeNullOrEmpty
            }

            It 'Extracts RetTrib fields when present' {
                [xml]$xml = $Script:MinimalNFe.Replace(
                    '</total>',
                    @'
                        <retTrib>
                            <vRetCSLL>4.15</vRetCSLL>
                            <vBCIRRF>415.29</vBCIRRF>
                            <vIRRF>4.98</vIRRF>
                        </retTrib>
                    </total>
'@
                )

                $result = Get-DFeNFeFiscalData -Xml $xml

                $result.Totais.RetTrib.VRetCSLL | Should -Be ([decimal]4.15)
                $result.Totais.RetTrib.VBCIrrf  | Should -Be ([decimal]415.29)
                $result.Totais.RetTrib.VIrrf    | Should -Be ([decimal]4.98)
            }

            It 'Returns null RetTrib when absent' {
                [xml]$xml = $Script:MinimalNFe

                $result = Get-DFeNFeFiscalData -Xml $xml

                $result.Totais.RetTrib | Should -BeNullOrEmpty
            }
        }
        #endregion

        #region Erros
        Context 'Erros' {

            It 'Throws UnsupportedNFeFiscalDocument for a CTe XML' {
                [xml]$xml = @'
<CTe xmlns="http://www.portalfiscal.inf.br/cte">
    <infCte Id="CTe35260912345678000199570010000000011234567890" />
</CTe>
'@

                { Get-DFeNFeFiscalData -Xml $xml } |
                    Should -Throw -ErrorId 'UnsupportedNFeFiscalDocument*'
            }

            It 'Throws NFeNamespaceNotFound when namespace is absent' {
                [xml]$xml = @'
<NFe>
    <infNFe Id="NFe35260912345678000199550010000000011234567890">
        <ide>
            <mod>55</mod>
        </ide>
    </infNFe>
</NFe>
'@

                {
                    Get-DFeNFeFiscalData -Xml $xml
                } | Should -Throw -ErrorId 'NFeNamespaceNotFound*'
            }

            It 'Throws NFeInfoNodeNotFound when infNFe is absent' {
                [xml]$xml = @'
<NFe xmlns="http://www.portalfiscal.inf.br/nfe">
    <ide>
        <mod>55</mod>
    </ide>
</NFe>
'@

                { Get-DFeNFeFiscalData -Xml $xml } |
                    Should -Throw -ErrorId 'NFeInfoNodeNotFound*'
            }

            It 'Throws NFeAccessKeyInvalid when Id attribute is absent' {
                [xml]$xml = @'
<NFe xmlns="http://www.portalfiscal.inf.br/nfe">
    <infNFe>
        <ide>
            <mod>55</mod>
        </ide>
    </infNFe>
</NFe>
'@

                { Get-DFeNFeFiscalData -Xml $xml } |
                    Should -Throw -ErrorId 'NFeAccessKeyInvalid*'
            }

            It 'Throws UnsupportedNFeFiscalDocument when mod is unsupported' {
                [xml]$xml = @'
<NFe xmlns="http://www.portalfiscal.inf.br/nfe">
    <infNFe Id="NFe35260912345678000199550010000000011234567890">
        <ide>
            <mod>99</mod>
        </ide>
    </infNFe>
</NFe>
'@

                { Get-DFeNFeFiscalData -Xml $xml } |
                    Should -Throw -ErrorId 'UnsupportedNFeFiscalDocument*'
            }
        }
        #endregion
    }
}
