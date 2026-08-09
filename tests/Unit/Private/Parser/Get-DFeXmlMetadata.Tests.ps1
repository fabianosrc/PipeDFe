#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for Get-DFeXmlMetadata.

.DESCRIPTION
Covers metadata extraction for all supported DFe XML types using mocked
private dependencies. Real XML structures from production samples are used
to build test fixtures, but no file I/O or SEFAZ communication occurs.

Contexts:
  Documento       - NF-e, CT-e, CT-e OS, MDF-e, NFCom (bare and Proc)
  Evento          - procEventoNFe, procEventoCTe, procEventoMDFe, procEventoNFCom
  Evento edge     - unsupported tpEvento, absent tpEvento, absent Modelo
  Inutilizacao    - inutNFe (bare) and procInutNFe (processed)
  Output contract - all fields present, correct types and exact shape
  Failure paths   - classification failure, namespace failure,
                    missing infNode, invalid chave
Architectural     - DFeExtractionMap gap invariant and runtime guard
Delegation        - Get-DFeAccessKey and Resolve-DFeEvento contracts

The suite intentionally tests the public contract of Get-DFeXmlMetadata
while also protecting the architectural contracts between its private
dependencies.
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

Describe 'Get-DFeXmlMetadata' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            #region Helpers
            function New-XmlDocument {
                [CmdletBinding()]
                [OutputType([System.Xml.XmlDocument])]
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
                    'PSUseShouldProcessForStateChangingFunctions',
                    '',
                    Justification = 'No state change outside test scope.'
                )]
                param (
                    [Parameter(Mandatory)]
                    [string]$XmlContent
                )

                $xmlDocument = [System.Xml.XmlDocument]::new()
                $xmlDocument.XmlResolver = $null
                $xmlDocument.LoadXml($XmlContent)

                $xmlDocument
            }

            function New-MockFileInfo {
                [CmdletBinding()]
                [OutputType([System.IO.FileInfo])]
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
                    'PSUseShouldProcessForStateChangingFunctions',
                    '',
                    Justification = 'No state change outside test scope.'
                )]
                param (
                    [Parameter()]
                    [string]$FileName = 'test.xml'
                )

                $filePath = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), $FileName)

                [System.IO.FileInfo]::new($filePath)
            }

            function Assert-MetadataContract {
                [CmdletBinding()]
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
                    'PSUseShouldProcessForStateChangingFunctions',
                    '',
                    Justification = 'No state change outside test scope. Assertions only.'
                )]
                param (
                    [Parameter(Mandatory)]
                    [pscustomobject]$Metadata
                )

                $Metadata | Should -Not -BeNullOrEmpty
                $Metadata | Should -BeOfType [PSCustomObject]

                $Metadata.PSObject.Properties.Name | Should -HaveCount 17

                $Metadata.File | Should -BeOfType [System.IO.FileInfo]
                $Metadata.Tipo | Should -BeOfType [TipoXmlDFe]

                if ($null -ne $Metadata.Modelo) {
                    $Metadata.Modelo | Should -BeOfType [ModeloDFe]
                }

                $Metadata.IsProc | Should -BeOfType [bool]

                if ($null -ne $Metadata.EventoTipo) {
                    $Metadata.EventoTipo | Should -BeOfType [DFeEvento]
                }

                foreach ($propertyName in @(
                        'Chave',
                        'ChavePai',
                        'TpEvento',
                        'DescEvento',
                        'DhEmi',
                        'NNF',
                        'Serie',
                        'NNFIni',
                        'NNFFin',
                        'cStat',
                        'xMotivo'
                    )) {
                    if ($null -ne $Metadata.$propertyName) {
                        $Metadata.$propertyName | Should -BeOfType [string]
                    }
                }
            }
            #endregion

            #region Namespaces
            $Script:nfeXmlns   = 'http://www.portalfiscal.inf.br/nfe'
            $Script:mdfeXmlns  = 'http://www.portalfiscal.inf.br/mdfe'
            $Script:cteXmlns   = 'http://www.portalfiscal.inf.br/cte'
            $Script:nfcomXmlns = 'http://www.portalfiscal.inf.br/nfcom'
            #endregion

            #region Chave de Acesso
            $chNFe   = '35260821647099000198550010000039171159579058'
            $chCTe   = '35260821647099000198570010000039171159579058'
            $chMDFe  = '35260821647099000198580010000039171159579058'
            $chNFCom = '35260618043483000177620010000017681035028042'

            # Distinct chave for event fixtures to prove ChavePai is extracted
            # from the event XML itself.
            $chNFeEvento = '35260827544456000179550010000140941809759307'
            #endregion

            #region Fixtures
            # Documento
            $Script:nfeProc = New-XmlDocument -XmlContent @"
<?xml version="1.0" encoding="utf-8"?>
<nfeProc versao="4.00" xmlns="http://www.portalfiscal.inf.br/nfe">
    <NFe xmlns="http://www.portalfiscal.inf.br/nfe">
        <infNFe versao="4.00" Id="NFe$chNFe">
            <ide>
                <mod>55</mod>
                <serie>1</serie>
                <nNF>3917</nNF>
                <dhEmi>2026-08-03T09:28:36-03:00</dhEmi>
            </ide>
        </infNFe>
    </NFe>
    <protNFe versao="4.00">
        <infProt>
            <chNFe>$chNFe</chNFe>
            <cStat>100</cStat>
            <xMotivo>Autorizado o uso da NF-e</xMotivo>
        </infProt>
    </protNFe>
</nfeProc>
"@

            $Script:nfe = New-XmlDocument -XmlContent @"
<?xml version="1.0" encoding="utf-8"?>
<NFe xmlns="http://www.portalfiscal.inf.br/nfe">
    <infNFe versao="4.00" Id="NFe$chNFe">
        <ide>
            <mod>55</mod>
            <serie>1</serie>
            <nNF>3917</nNF>
            <dhEmi>2026-08-03T09:28:36-03:00</dhEmi>
        </ide>
    </infNFe>
</NFe>
"@

            $Script:cteProc = New-XmlDocument -XmlContent @"
<?xml version="1.0" encoding="utf-8"?>
<cteProc versao="4.00" xmlns="http://www.portalfiscal.inf.br/cte">
    <CTe xmlns="http://www.portalfiscal.inf.br/cte">
        <infCte versao="4.00" Id="CTe$chCTe">
            <ide>
                <mod>57</mod>
                <serie>1</serie>
                <nCT>3917</nCT>
                <dhEmi>2026-08-03T09:28:36-03:00</dhEmi>
            </ide>
        </infCte>
    </CTe>
</cteProc>
"@

            $Script:cteOsProc = New-XmlDocument -XmlContent @"
<?xml version="1.0" encoding="utf-8"?>
<cteOSProc versao="4.00" xmlns="http://www.portalfiscal.inf.br/cte">
    <CTeOS xmlns="http://www.portalfiscal.inf.br/cte">
        <infCte versao="4.00" Id="CTe$chCTe">
            <ide>
                <mod>67</mod>
                <serie>1</serie>
                <nCT>3917</nCT>
                <dhEmi>2026-08-03T09:28:36-03:00</dhEmi>
            </ide>
        </infCte>
    </CTeOS>
</cteOSProc>
"@

            $Script:mdfeProc = New-XmlDocument -XmlContent @"
<?xml version="1.0" encoding="utf-8"?>
<mdfeProc versao="3.00" xmlns="http://www.portalfiscal.inf.br/mdfe">
    <MDFe xmlns="http://www.portalfiscal.inf.br/mdfe">
        <infMDFe versao="3.00" Id="MDFe$chMDFe">
            <ide>
                <mod>58</mod>
                <serie>1</serie>
                <nMDF>3917</nMDF>
                <dhEmi>2026-08-03T09:28:36-03:00</dhEmi>
            </ide>
        </infMDFe>
    </MDFe>
</mdfeProc>
"@

            $Script:nfcomProc = New-XmlDocument -XmlContent @"
<?xml version="1.0" encoding="utf-8"?>
<nfcomProc versao="1.00" xmlns="http://www.portalfiscal.inf.br/nfcom">
    <NFCom xmlns="http://www.portalfiscal.inf.br/nfcom">
        <infNFCom versao="1.00" Id="NFCom$chNFCom">
            <ide>
                <mod>62</mod>
                <serie>1</serie>
                <nNF>1768</nNF>
                <dhEmi>2026-06-25T17:43:20+00:00</dhEmi>
            </ide>
        </infNFCom>
    </NFCom>
</nfcomProc>
"@

            $Script:nfcom = New-XmlDocument -XmlContent @"
<?xml version="1.0" encoding="utf-8"?>
<NFCom xmlns="http://www.portalfiscal.inf.br/nfcom">
    <infNFCom versao="1.00" Id="NFCom$chNFCom">
        <ide>
            <mod>62</mod>
            <serie>1</serie>
            <nNF>1768</nNF>
            <dhEmi>2026-06-25T17:43:20+00:00</dhEmi>
        </ide>
    </infNFCom>
</NFCom>
"@
            # Evento
            $Script:procEventoNFe = New-XmlDocument -XmlContent @"
<?xml version="1.0" encoding="utf-8"?>
<procEventoNFe versao="1.00" xmlns="http://www.portalfiscal.inf.br/nfe">
    <evento versao="1.00">
        <infEvento Id="ID110111...">
            <chNFe>$chNFeEvento</chNFe>
            <tpEvento>110111</tpEvento>
            <detEvento versao="1.00">
                <descEvento>Cancelamento</descEvento>
            </detEvento>
        </infEvento>
    </evento>
    <retEvento versao="1.00">
        <infEvento>
            <tpEvento>999999</tpEvento>
            <descEvento>IGNORAR</descEvento>
        </infEvento>
    </retEvento>
</procEventoNFe>
"@

            $Script:procEventoCTe = New-XmlDocument -XmlContent @"
<?xml version="1.0" encoding="utf-8"?>
<procEventoCTe versao="4.00" xmlns="http://www.portalfiscal.inf.br/cte">
    <eventoCTe versao="4.00">
        <infEvento>
            <chCTe>$chCTe</chCTe>
            <tpEvento>110111</tpEvento>
            <detEvento>
                <descEvento>Cancelamento</descEvento>
            </detEvento>
        </infEvento>
    </eventoCTe>
</procEventoCTe>
"@

            $Script:procEventoMDFe = New-XmlDocument -XmlContent @"
<?xml version="1.0" encoding="utf-8"?>
<procEventoMDFe versao="3.00" xmlns="http://www.portalfiscal.inf.br/mdfe">
    <eventoMDFe versao="3.00">
        <infEvento>
            <chMDFe>$chMDFe</chMDFe>
            <tpEvento>110112</tpEvento>
            <detEvento>
                <evEncMDFe>
                    <descEvento>Encerramento</descEvento>
                </evEncMDFe>
            </detEvento>
        </infEvento>
    </eventoMDFe>
</procEventoMDFe>
"@

            $Script:procEventoNFCom = New-XmlDocument -XmlContent @"
<?xml version="1.0" encoding="utf-8"?>
<procEventoNFCom versao="1.00" xmlns="http://www.portalfiscal.inf.br/nfcom">
    <eventoNFCom versao="1.00">
        <infEvento Id="ID110111...">
            <chNFCom>$chNFCom</chNFCom>
            <tpEvento>110111</tpEvento>
            <detEvento versaoEvento="1.00">
                <evCancNFCom>
                    <descEvento>Cancelamento</descEvento>
                </evCancNFCom>
            </detEvento>
        </infEvento>
    </eventoNFCom>
    <retEventoNFCom versao="1.00">
        <infEvento>
            <tpEvento>999999</tpEvento>
            <descEvento>IGNORAR</descEvento>
        </infEvento>
    </retEventoNFCom>
</procEventoNFCom>
"@

            $Script:procEventoNfeSemTpEvento = New-XmlDocument -XmlContent @"
<?xml version="1.0" encoding="utf-8"?>
<procEventoNFe versao="1.00" xmlns="http://www.portalfiscal.inf.br/nfe">
    <evento versao="1.00">
        <infEvento>
            <chNFe>$chNFeEvento</chNFe>
            <detEvento>
                <descEvento>Cancelamento</descEvento>
            </detEvento>
        </infEvento>
    </evento>
</procEventoNFe>
"@

            # Inutilizacao
            $Script:inutNFe = New-XmlDocument -XmlContent @"
<?xml version="1.0" encoding="utf-8"?>
<inutNFe versao="4.00" xmlns="http://www.portalfiscal.inf.br/nfe">
    <infInut Id="ID...">
        <mod>65</mod>
        <serie>1</serie>
        <nNFIni>2528</nNFIni>
        <nNFFin>2528</nNFFin>
    </infInut>
</inutNFe>
"@

            $Script:procInutNFe = New-XmlDocument -XmlContent @"
<?xml version="1.0" encoding="utf-8"?>
<procInutNFe versao="4.00" xmlns="http://www.portalfiscal.inf.br/nfe">
    <inutNFe versao="4.00">
        <infInut Id="ID...">
            <mod>65</mod>
            <serie>1</serie>
            <nNFIni>2528</nNFIni>
            <nNFFin>2528</nNFFin>
        </infInut>
    </inutNFe>
    <retInutNFe versao="4.00">
        <infInut>
            <cStat>102</cStat>
            <xMotivo>Inutilizacao de numero homologado</xMotivo>
        </infInut>
    </retInutNFe>
</procInutNFe>
"@
            #endregion

            #region Common Mocks
            Mock -CommandName Get-Item {
                New-MockFileInfo -FileName 'test.xml'
            }

            Mock -CommandName Select-XmlNode {
                param (
                    [Parameter()]
                    [System.Xml.XmlNode]$XmlNode,

                    [Parameter()]
                    [string]$XPath,

                    [Parameter()]
                    [System.Xml.XmlNamespaceManager]$XmlNsManager
                )

                $XmlNode.SelectSingleNode($XPath, $XmlNsManager)
            }
            #endregion
        }

        #region Documento - NF-e
        Context 'Documento - nfeProc' {

            BeforeAll {

                Mock -CommandName Import-DFeXml { $nfeProc }

                Mock -CommandName Get-DFeDocumentInfo {
                    [PSCustomObject]@{
                        Tipo   = [TipoXmlDFe]::Documento
                        Modelo = [ModeloDFe]::NFe
                    }
                }

                Mock -CommandName Get-DFeDocumentNamespace { $nfeXmlns }

                Mock -CommandName Get-DFeAccessKey { $chNFe }
            }

            It 'Returns the expected documento contract' {
                $result = Get-DFeXmlMetadata -Path 'test.xml'

                $result.Tipo   | Should -Be ([TipoXmlDFe]::Documento)
                $result.Modelo | Should -Be ([ModeloDFe]::NFe)
                $result.Root   | Should -Be 'nfeProc'
                $result.IsProc | Should -BeTrue
                $result.Chave  | Should -Be $chNFe
                $result.DhEmi  | Should -Be '2026-08-03T09:28:36-03:00'
                $result.NNF    | Should -Be '3917'
                $result.Serie  | Should -Be '1'
            }

            It 'Returns a structurally valid metadata object' {
                $result = Get-DFeXmlMetadata -Path 'test.xml'

                Assert-MetadataContract -Metadata $result
            }

            It 'Sets all non-document fields to null' {
                $result = Get-DFeXmlMetadata -Path 'test.xml'

                $result.ChavePai   | Should -BeNullOrEmpty
                $result.EventoTipo | Should -BeNullOrEmpty
                $result.TpEvento   | Should -BeNullOrEmpty
                $result.DescEvento | Should -BeNullOrEmpty
                $result.NNFIni     | Should -BeNullOrEmpty
                $result.NNFFin     | Should -BeNullOrEmpty
                $result.cStat      | Should -BeNullOrEmpty
                $result.xMotivo    | Should -BeNullOrEmpty
            }

            It 'Does not populate inutilizacao or evento metadata from unrelated nodes' {
                $result = Get-DFeXmlMetadata -Path 'test.xml'

                $result.ChavePai   | Should -BeNullOrEmpty
                $result.EventoTipo | Should -BeNullOrEmpty
                $result.TpEvento   | Should -BeNullOrEmpty
                $result.DescEvento | Should -BeNullOrEmpty
                $result.NNFIni     | Should -BeNullOrEmpty
                $result.NNFFin     | Should -BeNullOrEmpty
            }
        }

        Context 'Documento - NFe bare root' {

            BeforeAll {

                Mock -CommandName Import-DFeXml { $nfe }

                Mock -CommandName Get-DFeDocumentInfo {
                    [PSCustomObject]@{
                        Tipo   = [TipoXmlDFe]::Documento
                        Modelo = [ModeloDFe]::NFe
                    }
                }

                Mock -CommandName Get-DFeDocumentNamespace { $nfeXmlns }

                Mock -CommandName Get-DFeAccessKey { $chNFe }
            }

            It 'Sets Root to NFe and IsProc to false' {
                $result = Get-DFeXmlMetadata -Path 'test.xml'

                $result.Root   | Should -Be 'NFe'
                $result.IsProc | Should -BeFalse
            }

            It 'Extracts the document number, series and emission date' {
                $result = Get-DFeXmlMetadata -Path 'test.xml'

                $result.NNF    | Should -Be '3917'
                $result.Serie  | Should -Be '1'
                $result.DhEmi  | Should -Be '2026-08-03T09:28:36-03:00'
            }
        }
        #endregion

        #region Documento - CT-e and CT-e OS
        Context 'Documento - cteProc' {

            BeforeAll {

                Mock -CommandName Import-DFeXml { $cteProc }

                Mock -CommandName Get-DFeDocumentInfo {
                    [PSCustomObject]@{
                        Tipo   = [TipoXmlDFe]::Documento
                        Modelo = [ModeloDFe]::CTe
                    }
                }

                Mock -CommandName Get-DFeDocumentNamespace { $cteXmlns }

                Mock -CommandName Get-DFeAccessKey { $chCTe }
            }

            It 'Returns the expected documento contract for CT-e' {
                $result = Get-DFeXmlMetadata -Path 'test.xml'

                $result.Modelo | Should -Be ([ModeloDFe]::CTe)
                $result.Root   | Should -Be 'cteProc'
                $result.IsProc | Should -BeTrue
                $result.Chave  | Should -Be $chCTe
                $result.DhEmi  | Should -Be '2026-08-03T09:28:36-03:00'
                $result.NNF    | Should -BeNullOrEmpty
                $result.Serie  | Should -Be '1'
            }

            It 'Does not confuse nCT with NNF' {
                $result = Get-DFeXmlMetadata -Path 'test.xml'
                $result.NNF | Should -BeNullOrEmpty
            }
        }

        Context 'Documento - cteOSProc' {

            BeforeAll {

                Mock -CommandName Import-DFeXml { $cteOsProc }

                Mock -CommandName Get-DFeDocumentInfo {
                    [PSCustomObject]@{
                        Tipo   = [TipoXmlDFe]::Documento
                        Modelo = [ModeloDFe]::CTeOS
                    }
                }

                Mock -CommandName Get-DFeDocumentNamespace { $cteXmlns }

                Mock -CommandName Get-DFeAccessKey { $chCTe }
            }

            It 'Returns the expected documento contract for CT-e OS' {
                $result = Get-DFeXmlMetadata -Path 'test.xml'

                $result.Modelo | Should -Be ([ModeloDFe]::CTeOS)
                $result.Root   | Should -Be 'cteOSProc'
                $result.IsProc | Should -BeTrue
                $result.Chave  | Should -Be $chCTe
                $result.DhEmi  | Should -Be '2026-08-03T09:28:36-03:00'
                $result.NNF    | Should -BeNullOrEmpty
                $result.Serie  | Should -Be '1'
            }
        }
        #endregion

        #region Documento - MDF-e
        Context 'Documento - mdfeProc' {

            BeforeAll {

                Mock -CommandName Import-DFeXml { $mdfeProc }

                Mock -CommandName Get-DFeDocumentInfo {
                    [PSCustomObject]@{
                        Tipo   = [TipoXmlDFe]::Documento
                        Modelo = [ModeloDFe]::MDFe
                    }
                }

                Mock -CommandName Get-DFeDocumentNamespace { $mdfeXmlns }

                Mock -CommandName Get-DFeAccessKey { $chMDFe }
            }

            It 'Returns the expected documento contract for MDF-e' {
                $result = Get-DFeXmlMetadata -Path 'test.xml'

                $result.Modelo | Should -Be ([ModeloDFe]::MDFe)
                $result.Root   | Should -Be 'mdfeProc'
                $result.IsProc | Should -BeTrue
                $result.Chave  | Should -Be $chMDFe
                $result.DhEmi  | Should -Be '2026-08-03T09:28:36-03:00'
                $result.NNF    | Should -BeNullOrEmpty
                $result.Serie  | Should -Be '1'
            }

            It 'Does not confuse nMDF with NNF' {
                $result = Get-DFeXmlMetadata -Path 'test.xml'
                $result.NNF | Should -BeNullOrEmpty
            }
        }
        #endregion

        #region Documento - NFCom
        Context 'Documento - nfcomProc' {

            BeforeAll {

                Mock -CommandName Import-DFeXml { $nfcomProc }

                Mock -CommandName Get-DFeDocumentInfo {
                    [PSCustomObject]@{
                        Tipo   = [TipoXmlDFe]::Documento
                        Modelo = [ModeloDFe]::NFCom
                    }
                }

                Mock -CommandName Get-DFeDocumentNamespace { $nfcomXmlns }

                Mock -CommandName Get-DFeAccessKey { $chNFCom }
            }

            It 'Returns the expected documento contract for NFCom' {
                $result = Get-DFeXmlMetadata -Path 'test.xml'

                $result.Modelo | Should -Be ([ModeloDFe]::NFCom)
                $result.Root   | Should -Be 'nfcomProc'
                $result.IsProc | Should -BeTrue
                $result.Chave  | Should -Be $chNFCom
                $result.NNF    | Should -Be '1768'
                $result.Serie  | Should -Be '1'
                $result.DhEmi  | Should -Be '2026-06-25T17:43:20+00:00'
            }
        }

        Context 'Documento - NFCom bare root' {

            BeforeAll {

                Mock -CommandName Import-DFeXml { $nfcom }

                Mock -CommandName Get-DFeDocumentInfo {
                    [PSCustomObject]@{
                        Tipo   = [TipoXmlDFe]::Documento
                        Modelo = [ModeloDFe]::NFCom
                    }
                }

                Mock -CommandName Get-DFeDocumentNamespace { $nfcomXmlns }

                Mock -CommandName Get-DFeAccessKey { $chNFCom }
            }

            It 'Sets Root to NFCom and IsProc to false' {
                $result = Get-DFeXmlMetadata -Path 'test.xml'

                $result.Root   | Should -Be 'NFCom'
                $result.IsProc | Should -BeFalse
            }

            It 'Extracts NFCom number, series and emission date' {
                $result = Get-DFeXmlMetadata -Path 'test.xml'

                $result.NNF   | Should -Be '1768'
                $result.Serie | Should -Be '1'
                $result.DhEmi | Should -Be '2026-06-25T17:43:20+00:00'
            }
        }
        #endregion

        #region Evento - NF-e
        Context 'Evento - procEventoNFe Cancelamento' {

            BeforeAll {

                Mock -CommandName Import-DFeXml { $procEventoNFe }

                Mock -CommandName Get-DFeDocumentInfo {
                    [PSCustomObject]@{
                        Tipo   = [TipoXmlDFe]::Evento
                        Modelo = [ModeloDFe]::NFe
                    }
                }

                Mock -CommandName Get-DFeDocumentNamespace { $nfeXmlns }

                Mock -CommandName Resolve-DFeEvento { [DFeEvento]::Cancelamento }
            }

            It 'Returns the expected evento contract' {
                $result = Get-DFeXmlMetadata -Path 'test.xml'

                $result.Tipo       | Should -Be ([TipoXmlDFe]::Evento)
                $result.Modelo     | Should -Be ([ModeloDFe]::NFe)
                $result.TpEvento   | Should -Be '110111'
                $result.DescEvento | Should -Be 'Cancelamento'
                $result.EventoTipo | Should -Be ([DFeEvento]::Cancelamento)
                $result.ChavePai   | Should -Be $chNFeEvento

                # procEventoNFe ends with NFe, not Proc
                $result.IsProc     | Should -BeFalse
            }

            It 'Sets TpEvento from evento/infEvento, never retEvento/infEvento' {
                $result = Get-DFeXmlMetadata -Path 'test.xml'

                $result.TpEvento | Should -Be '110111'
                $result.TpEvento | Should -Not -Be '999999'
            }

            It 'Sets DescEvento from evento and never from retEvento' {
                $result = Get-DFeXmlMetadata -Path 'test.xml'

                $result.DescEvento | Should -Be 'Cancelamento'
                $result.DescEvento | Should -Not -Be 'IGNORAR'
            }

            It 'Sets documento and inutilizacao fields to null' {
                $result = Get-DFeXmlMetadata -Path 'test.xml'

                $result.Chave   | Should -BeNullOrEmpty
                $result.DhEmi   | Should -BeNullOrEmpty
                $result.NNF     | Should -BeNullOrEmpty
                $result.Serie   | Should -BeNullOrEmpty
                $result.NNFIni  | Should -BeNullOrEmpty
                $result.NNFFin  | Should -BeNullOrEmpty
                $result.cStat   | Should -BeNullOrEmpty
                $result.xMotivo | Should -BeNullOrEmpty
            }
        }
        #endregion

        #region Evento - CT-e
        Context 'Evento - procEventoCTe Cancelamento' {

            BeforeAll {

                Mock -CommandName Import-DFeXml { $procEventoCTe }

                Mock -CommandName Get-DFeDocumentInfo {
                    [PSCustomObject]@{
                        Tipo   = [TipoXmlDFe]::Evento
                        Modelo = [ModeloDFe]::CTe
                    }
                }

                Mock -CommandName Get-DFeDocumentNamespace { $cteXmlns }

                Mock -CommandName Resolve-DFeEvento { [DFeEvento]::Cancelamento }
            }

            It 'Returns the expected evento contract for CT-e' {
                $result = Get-DFeXmlMetadata -Path 'test.xml'

                $result.TpEvento   | Should -Be '110111'
                $result.EventoTipo | Should -Be ([DFeEvento]::Cancelamento)
                $result.ChavePai   | Should -Be $chCTe
            }
        }
        #endregion

        #region Evento - MDF-e
        Context 'Evento - procEventoMDFe Encerramento' {

            BeforeAll {

                Mock -CommandName Import-DFeXml { $procEventoMDFe }

                Mock -CommandName Get-DFeDocumentInfo {
                    [PSCustomObject]@{
                        Tipo   = [TipoXmlDFe]::Evento
                        Modelo = [ModeloDFe]::MDFe
                    }
                }

                Mock -CommandName Get-DFeDocumentNamespace { $mdfeXmlns }

                Mock -CommandName Resolve-DFeEvento { [DFeEvento]::Encerramento }
            }

            It 'Returns the expected evento contract for MDF-e' {
                $result = Get-DFeXmlMetadata -Path 'test.xml'

                $result.TpEvento   | Should -Be '110112'
                $result.EventoTipo | Should -Be ([DFeEvento]::Encerramento)
                $result.ChavePai   | Should -Be $chMDFe
            }

            It 'Extracts DescEvento from nested evEncMDFe' {
                $result = Get-DFeXmlMetadata -Path 'test.xml'

                $result.DescEvento | Should -Be 'Encerramento'
            }
        }
        #endregion

        #region Evento - NFCom
        Context 'Evento - procEventoNFCom Cancelamento' {

            BeforeAll {

                Mock -CommandName Import-DFeXml { $procEventoNFCom }

                Mock -CommandName Get-DFeDocumentInfo {
                    [PSCustomObject]@{
                        Tipo   = [TipoXmlDFe]::Evento
                        Modelo = [ModeloDFe]::NFCom
                    }
                }

                Mock -CommandName Get-DFeDocumentNamespace { $nfcomXmlns }

                Mock -CommandName Resolve-DFeEvento { [DFeEvento]::Cancelamento }
            }

            It 'Returns the expected evento contract for NFCom' {
                $result = Get-DFeXmlMetadata -Path 'test.xml'

                $result.TpEvento   | Should -Be '110111'
                $result.EventoTipo | Should -Be ([DFeEvento]::Cancelamento)
                $result.ChavePai   | Should -Be $chNFCom
            }

            It 'Reads TpEvento from eventoNFCom and not retEventoNFCom' {
                $result = Get-DFeXmlMetadata -Path 'test.xml'

                $result.TpEvento | Should -Be '110111'
                $result.TpEvento | Should -Not -Be '999999'
            }

            It 'Reads DescEvento from eventoNFCom and not retEventoNFCom' {
                $result = Get-DFeXmlMetadata -Path 'test.xml'

                $result.DescEvento | Should -Be 'Cancelamento'
                $result.DescEvento | Should -Not -Be 'IGNORAR'
            }

            It 'Extracts DescEvento from nested evCancNFCom' {
                $result = Get-DFeXmlMetadata -Path 'test.xml'

                $result.DescEvento | Should -Be 'Cancelamento'
            }
        }
        #endregion

        #region Evento - Edge cases
        Context 'Evento - unsupported tpEvento' {

            BeforeAll {

                Mock -CommandName Import-DFeXml { $procEventoNFe }

                Mock -CommandName Get-DFeDocumentInfo {
                    [PSCustomObject]@{
                        Tipo   = [TipoXmlDFe]::Evento
                        Modelo = [ModeloDFe]::NFe
                    }
                }

                Mock -CommandName Get-DFeDocumentNamespace { $nfeXmlns }

                Mock -CommandName Resolve-DFeEvento { }
            }

            It 'Sets EventoTipo to null but preserves event metadata' {
                $result = Get-DFeXmlMetadata -Path 'test.xml'

                $result.EventoTipo | Should -BeNullOrEmpty
                $result.TpEvento   | Should -Be '110111'
                $result.DescEvento | Should -Be 'Cancelamento'
                $result.ChavePai   | Should -Be $chNFeEvento
            }

            It 'Still produces the normal metadata contract' {
                $result = Get-DFeXmlMetadata -Path 'test.xml'

                Assert-MetadataContract -Metadata $result
            }
        }

        Context 'Evento - tpEvento absent from XML' {

            BeforeAll {

                Mock -CommandName Import-DFeXml { $procEventoNfeSemTpEvento }

                Mock -CommandName Get-DFeDocumentInfo {
                    [PSCustomObject]@{
                        Tipo   = [TipoXmlDFe]::Evento
                        Modelo = [ModeloDFe]::NFe
                    }
                }

                Mock -CommandName Get-DFeDocumentNamespace { $nfeXmlns }

                # Mock must exist for Should -Invoke -Times 0 to work.
                Mock -CommandName Resolve-DFeEvento { }
            }

            It 'Sets TpEvento and EventoTipo to null' {
                $result = Get-DFeXmlMetadata -Path 'test.xml'

                $result.TpEvento   | Should -BeNullOrEmpty
                $result.EventoTipo | Should -BeNullOrEmpty
            }

            It 'Does not call Resolve-DFeEvento without tpEvento' {
                Get-DFeXmlMetadata -Path 'test.xml' | Out-Null

                Should -Invoke Resolve-DFeEvento -Times 0 -Exactly
            }

            It 'Still returns metadata' {
                Get-DFeXmlMetadata -Path 'test.xml' | Should -Not -BeNullOrEmpty
            }

            It 'Preserves ChavePai and DescEvento' {
                $result = Get-DFeXmlMetadata -Path 'test.xml'

                $result.ChavePai   | Should -Be $chNFeEvento
                $result.DescEvento | Should -Be 'Cancelamento'
            }
        }

        Context 'Evento - Modelo is null' {

            BeforeAll {

                Mock -CommandName Import-DFeXml { $procEventoNFe }

                Mock -CommandName Get-DFeDocumentInfo {
                    [PSCustomObject]@{
                        Tipo   = [TipoXmlDFe]::Evento
                        Modelo = $null
                    }
                }

                Mock -CommandName Get-DFeDocumentNamespace { $nfeXmlns }

                # Mock must exist for Should -Invoke -Times 0 to work.
                Mock -CommandName Resolve-DFeEvento { }
            }

            It 'Sets Modelo and EventoTipo to null' {
                $result = Get-DFeXmlMetadata -Path 'test.xml'

                $result.Modelo     | Should -BeNullOrEmpty
                $result.EventoTipo | Should -BeNullOrEmpty
            }

            It 'Does not call Resolve-DFeEvento without Modelo' {
                Get-DFeXmlMetadata -Path 'test.xml' | Out-Null

                Should -Invoke Resolve-DFeEvento -Times 0 -Exactly
            }

            It 'Still extracts XML-owned event metadata' {
                $result = Get-DFeXmlMetadata -Path 'test.xml'

                $result.TpEvento   | Should -Be '110111'
                $result.DescEvento | Should -Be 'Cancelamento'
                $result.ChavePai   | Should -Be $chNFeEvento
            }
        }
        #endregion

        #region Inutilizacao
        Context 'Inutilizacao - inutNFe bare' {

            BeforeAll {

                Mock -CommandName Import-DFeXml { $inutNFe }

                Mock -CommandName Get-DFeDocumentInfo {
                    [PSCustomObject]@{
                        Tipo   = [TipoXmlDFe]::Inutilizacao
                        Modelo = [ModeloDFe]::NFCe
                    }
                }

                Mock -CommandName Get-DFeDocumentNamespace { $nfeXmlns }
            }

            It 'Returns the expected inutilizacao contract' {
                $result = Get-DFeXmlMetadata -Path 'test.xml'

                $result.Tipo   | Should -Be ([TipoXmlDFe]::Inutilizacao)
                $result.Modelo | Should -Be ([ModeloDFe]::NFCe)
                $result.Root   | Should -Be 'inutNFe'
                $result.IsProc | Should -BeFalse
                $result.Serie  | Should -Be '1'
                $result.NNFIni | Should -Be '2528'
                $result.NNFFin | Should -Be '2528'
            }

            It 'Sets cStat and xMotivo to null when not processed' {
                $result = Get-DFeXmlMetadata -Path 'test.xml'

                $result.cStat   | Should -BeNullOrEmpty
                $result.xMotivo | Should -BeNullOrEmpty
            }

            It 'Sets documento and evento fields to null' {
                $result = Get-DFeXmlMetadata -Path 'test.xml'

                $result.Chave      | Should -BeNullOrEmpty
                $result.DhEmi      | Should -BeNullOrEmpty
                $result.NNF        | Should -BeNullOrEmpty
                $result.ChavePai   | Should -BeNullOrEmpty
                $result.EventoTipo | Should -BeNullOrEmpty
                $result.TpEvento   | Should -BeNullOrEmpty
                $result.DescEvento | Should -BeNullOrEmpty
            }

            It 'Returns the common metadata contract' {
                $result = Get-DFeXmlMetadata -Path 'test.xml'

                Assert-MetadataContract -Metadata $result
            }
        }

        Context 'Inutilizacao - procInutNFe processed' {

            BeforeAll {

                Mock -CommandName Import-DFeXml { $procInutNFe }

                Mock -CommandName Get-DFeDocumentInfo {
                    [PSCustomObject]@{
                        Tipo   = [TipoXmlDFe]::Inutilizacao
                        Modelo = [ModeloDFe]::NFCe
                    }
                }

                Mock -CommandName Get-DFeDocumentNamespace { $nfeXmlns }
            }

            It 'Returns the expected processed inutilizacao contract' {
                $result = Get-DFeXmlMetadata -Path 'test.xml'

                $result.Root    | Should -Be 'procInutNFe'

                # procInutNFe ends with NFe, not Proc
                $result.IsProc  | Should -BeFalse
                $result.cStat   | Should -Be '102'
                $result.xMotivo | Should -Be 'Inutilizacao de numero homologado'
                $result.Serie   | Should -Be '1'
                $result.NNFIni  | Should -Be '2528'
                $result.NNFFin  | Should -Be '2528'
            }

            It 'Does not expose return-protocol data as document metadata' {
                $result = Get-DFeXmlMetadata -Path 'test.xml'

                $result.Chave      | Should -BeNullOrEmpty
                $result.ChavePai   | Should -BeNullOrEmpty
                $result.EventoTipo | Should -BeNullOrEmpty
                $result.TpEvento   | Should -BeNullOrEmpty
                $result.DescEvento | Should -BeNullOrEmpty
                $result.DhEmi      | Should -BeNullOrEmpty
                $result.NNF        | Should -BeNullOrEmpty
            }
        }
        #endregion

        #region Output contract
        Context 'Output contract' {

            BeforeAll {

                Mock -CommandName Import-DFeXml { $nfeProc }

                Mock -CommandName Get-DFeDocumentInfo {
                    [PSCustomObject]@{
                        Tipo   = [TipoXmlDFe]::Documento
                        Modelo = [ModeloDFe]::NFe
                    }
                }

                Mock -CommandName Get-DFeDocumentNamespace { $nfeXmlns }

                Mock -CommandName Get-DFeAccessKey { $chNFe }
            }

            $expectedFields = @(
                'File',
                'Tipo',
                'Modelo',
                'Root',
                'IsProc',
                'Chave',
                'ChavePai',
                'EventoTipo',
                'TpEvento',
                'DescEvento',
                'DhEmi',
                'NNF',
                'Serie',
                'NNFIni',
                'NNFFin',
                'cStat',
                'xMotivo'
            )

            It 'Returns exactly one PSCustomObject' {
                $result = Get-DFeXmlMetadata -Path 'test.xml'

                @($result) | Should -HaveCount 1
                $result | Should -BeOfType [PSCustomObject]
            }

            It 'Contains exactly the declared metadata fields' {
                $result = Get-DFeXmlMetadata -Path 'test.xml'

                $fields = @(
                    'File',
                    'Tipo',
                    'Modelo',
                    'Root',
                    'IsProc',
                    'Chave',
                    'ChavePai',
                    'EventoTipo',
                    'TpEvento',
                    'DescEvento',
                    'DhEmi',
                    'NNF',
                    'Serie',
                    'NNFIni',
                    'NNFFin',
                    'cStat',
                    'xMotivo'
                )

                $result.PSObject.Properties.Name | Should -HaveCount $fields.Count
                $result.PSObject.Properties.Name | Should -Be $fields
            }

            It "Contains field '<_>'" -ForEach $expectedFields {
                $result = Get-DFeXmlMetadata -Path 'test.xml'
                $result.PSObject.Properties.Name | Should -Contain $_
            }

            It 'Returns File as a FileInfo object' {
                $result = Get-DFeXmlMetadata -Path 'test.xml'
                $result.File | Should -BeOfType [System.IO.FileInfo]
            }

            It 'Returns the file selected by Get-Item' {
                $filePath = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), 'test.xml')

                $result = Get-DFeXmlMetadata -Path 'test.xml'
                $result.File.FullName | Should -Be $filePath
            }

            It 'Returns IsProc as a Boolean' {
                $result = Get-DFeXmlMetadata -Path 'test.xml'
                $result.IsProc | Should -BeOfType [bool]
            }

            It 'Returns enum-backed fields using their declared enum types' {
                $result = Get-DFeXmlMetadata -Path 'test.xml'

                $result.Tipo | Should -BeOfType [TipoXmlDFe]
                $result.Modelo | Should -BeOfType [ModeloDFe]
            }

            It 'Returns all expected properties in stable order' {
                $result = Get-DFeXmlMetadata -Path 'test.xml'

                $fields = @(
                    'File',
                    'Tipo',
                    'Modelo',
                    'Root',
                    'IsProc',
                    'Chave',
                    'ChavePai',
                    'EventoTipo',
                    'TpEvento',
                    'DescEvento',
                    'DhEmi',
                    'NNF',
                    'Serie',
                    'NNFIni',
                    'NNFFin',
                    'cStat',
                    'xMotivo'
                )

                $result.PSObject.Properties.Name | Should -Be $fields
            }
        }
        #endregion

        #region Failure paths
        Context 'Failure paths' {

            It 'Returns null when document classification fails' {
                Mock -CommandName Import-DFeXml { $nfeProc }

                Mock -CommandName Get-DFeDocumentInfo { }

                Mock -CommandName Get-DFeDocumentNamespace { $nfeXmlns }

                $result = Get-DFeXmlMetadata -Path 'test.xml'
                $result | Should -BeNullOrEmpty
            }

            It 'Does not continue to namespace resolution after classification failure' {
                Mock -CommandName Import-DFeXml { $nfeProc }

                Mock -CommandName Get-DFeDocumentInfo { }

                Mock -CommandName Get-DFeDocumentNamespace { $nfeXmlns }

                Get-DFeXmlMetadata -Path 'test.xml' | Out-Null

                Should -Invoke Get-DFeDocumentNamespace -Times 0 -Exactly
            }

            It 'Returns null when namespace cannot be determined' {
                Mock -CommandName Import-DFeXml { $nfeProc }

                Mock -CommandName Get-DFeDocumentInfo {
                    [PSCustomObject]@{
                        Tipo   = [TipoXmlDFe]::Documento
                        Modelo = [ModeloDFe]::NFe
                    }
                }

                Mock -CommandName Get-DFeDocumentNamespace { }

                $result = Get-DFeXmlMetadata -Path 'test.xml'

                $result | Should -BeNullOrEmpty
            }

            It 'Does not attempt extraction when namespace is unavailable' {
                Mock -CommandName Import-DFeXml { $nfeProc }

                Mock -CommandName Get-DFeDocumentInfo {
                    [PSCustomObject]@{
                        Tipo   = [TipoXmlDFe]::Documento
                        Modelo = [ModeloDFe]::NFe
                    }
                }

                Mock -CommandName Get-DFeDocumentNamespace { }

                Mock -CommandName Get-DFeAccessKey { $chNFe }

                Get-DFeXmlMetadata -Path 'test.xml' | Out-Null

                Should -Invoke Get-DFeAccessKey -Times 0 -Exactly
            }

            It 'Returns null when infNode is not found in XML' {
                Mock -CommandName Import-DFeXml { $nfeProc }

                Mock -CommandName Get-DFeDocumentInfo {
                    [PSCustomObject]@{
                        Tipo   = [TipoXmlDFe]::Documento
                        Modelo = [ModeloDFe]::NFe
                    }
                }

                Mock -CommandName Get-DFeDocumentNamespace { $nfeXmlns }

                Mock -CommandName Select-XmlNode { $null }

                $result = Get-DFeXmlMetadata -Path 'test.xml'
                $result | Should -BeNullOrEmpty
            }

            It 'Returns null and emits a warning when Get-DFeAccessKey returns null' {
                Mock -CommandName Import-DFeXml { $nfeProc }

                Mock -CommandName Get-DFeDocumentInfo {
                    [PSCustomObject]@{
                        Tipo   = [TipoXmlDFe]::Documento
                        Modelo = [ModeloDFe]::NFe
                    }
                }

                Mock -CommandName Get-DFeDocumentNamespace { $nfeXmlns }

                Mock -CommandName Get-DFeAccessKey { }

                $result = Get-DFeXmlMetadata -Path 'test.xml' -WarningVariable warnings
                $result   | Should -BeNullOrEmpty

                $warnings | Should -Not -BeNullOrEmpty
            }

            It 'Stops processing after an invalid access key' {
                Mock -CommandName Import-DFeXml { $nfeProc }

                Mock -CommandName Get-DFeDocumentInfo {
                    [PSCustomObject]@{
                        Tipo   = [TipoXmlDFe]::Documento
                        Modelo = [ModeloDFe]::NFe
                    }
                }

                Mock -CommandName Get-DFeDocumentNamespace { $nfeXmlns }

                Mock -CommandName Get-DFeAccessKey { }

                Get-DFeXmlMetadata -Path 'test.xml' -WarningVariable warnings | Out-Null

                Should -Invoke Get-DFeAccessKey -Times 1 -Exactly
            }
        }
        #endregion

        #region Architectural invariants
        Context 'Architectural invariants' {

            It 'Every Documento root in DFeDocumentMap has a corresponding DFeExtractionMap entry' {
                $documentoRoots = $Script:DFeDocumentMap.Keys |
                    Where-Object {
                        $Script:DFeDocumentMap[$_].Tipo -eq [TipoXmlDFe]::Documento
                    }

                $missing = $documentoRoots |
                    Where-Object {
                        -not $Script:DFeExtractionMap.ContainsKey($_)
                    }

                $missing | Should -BeNullOrEmpty -Because (
                    "these Documento roots have no entry in " +
                    "DFeExtractionMap: $($missing -join ', ')"
                )
            }

            It 'Every Documento extraction mapping has a corresponding document root' {
                $documentoRoots = @(
                    $Script:DFeDocumentMap.Keys |
                        Where-Object {
                            $Script:DFeDocumentMap[$_].Tipo -eq [TipoXmlDFe]::Documento
                        }
                )

                $orphanMappings = $Script:DFeExtractionMap.Keys |
                    Where-Object {
                        $_ -notin $documentoRoots
                    }

                $orphanMappings | Should -BeNullOrEmpty -Because (
                    "these extraction mappings do not correspond to " +
                    "Documento roots: $($orphanMappings -join ', ')"
                )
            }

            It 'Every extraction mapping has a non-empty IdPrefix' {
                $invalidMappings = $Script:DFeExtractionMap.GetEnumerator() |
                    Where-Object {
                        [string]::IsNullOrWhiteSpace($_.Value.IdPrefix)
                    }

                $invalidMappings | Should -BeNullOrEmpty -Because (
                    'every extraction mapping must define IdPrefix'
                )
            }

            It 'Returns null and emits a warning when a Documento root has no extraction mapping' {
                $saved = $Script:DFeExtractionMap['NFe']
                $Script:DFeExtractionMap.Remove('NFe')

                try {
                    Mock -CommandName Import-DFeXml { $nfeProc }

                    Mock -CommandName Get-DFeDocumentInfo {
                        [PSCustomObject]@{
                            Tipo   = [TipoXmlDFe]::Documento
                            Modelo = [ModeloDFe]::NFe
                        }
                    }

                    Mock -CommandName Get-DFeDocumentNamespace { $nfeXmlns }

                    # No-op mock prevents any stale global mock from
                    # masking the extraction map gap.
                    Mock -CommandName Get-DFeAccessKey { }

                    $result = Get-DFeXmlMetadata -Path 'test.xml' -WarningVariable warnings
                    $result   | Should -BeNullOrEmpty

                    $warnings | Should -Not -BeNullOrEmpty
                } finally {
                    $Script:DFeExtractionMap['NFe'] = $saved
                }
            }

            It 'Restores DFeExtractionMap after the missing-mapping simulation' {
                $before = $Script:DFeExtractionMap['NFe']
                $saved = $Script:DFeExtractionMap['NFe']

                try {
                    $Script:DFeExtractionMap.Remove('NFe')

                    Mock -CommandName Import-DFeXml { $nfeProc }

                    Mock -CommandName Get-DFeDocumentInfo {
                        [PSCustomObject]@{
                            Tipo   = [TipoXmlDFe]::Documento
                            Modelo = [ModeloDFe]::NFe
                        }
                    }

                    Mock -CommandName Get-DFeDocumentNamespace { $nfeXmlns }

                    Get-DFeXmlMetadata -Path 'test.xml' -WarningVariable warnings | Out-Null
                } finally {
                    $Script:DFeExtractionMap['NFe'] = $saved
                }

                $Script:DFeExtractionMap['NFe'] | Should -Be $before
            }
        }
        #endregion

        #region Delegation
        Context 'Delegation - Get-DFeAccessKey receives correct arguments' {

            BeforeAll {

                Mock -CommandName Import-DFeXml { $nfeProc }

                Mock -CommandName Get-DFeDocumentInfo {
                    [PSCustomObject]@{
                        Tipo   = [TipoXmlDFe]::Documento
                        Modelo = [ModeloDFe]::NFe
                    }
                }

                Mock -CommandName Get-DFeDocumentNamespace { $nfeXmlns }

                Mock -CommandName Get-DFeAccessKey { $chNFe }
            }

            It 'Calls Get-DFeAccessKey exactly once' {
                Get-DFeXmlMetadata -Path 'test.xml' | Out-Null

                Should -Invoke Get-DFeAccessKey -Times 1 -Exactly
            }

            It 'Passes the IdPrefix from DFeExtractionMap' {
                Get-DFeXmlMetadata -Path 'test.xml' | Out-Null

                Should -Invoke Get-DFeAccessKey -Times 1 -Exactly -ParameterFilter {
                    $Prefix -eq 'NFe'
                }
            }

            It 'Passes an XmlElement as Node' {
                Get-DFeXmlMetadata -Path 'test.xml' | Out-Null

                Should -Invoke Get-DFeAccessKey -Times 1 -Exactly -ParameterFilter {
                    $Node -is [System.Xml.XmlElement]
                }
            }

            It 'Passes both the expected prefix and XML node together' {
                Get-DFeXmlMetadata -Path 'test.xml' | Out-Null

                Should -Invoke Get-DFeAccessKey -Times 1 -Exactly -ParameterFilter {
                    $Prefix -eq 'NFe' -and $Node -is [System.Xml.XmlElement]
                }
            }
        }

        # Delegation - Resolve-DFeEvento
        Context 'Delegation - Resolve-DFeEvento receives correct arguments' {

            BeforeAll {

                Mock -CommandName Import-DFeXml { $procEventoNFe }

                Mock -CommandName Get-DFeDocumentInfo {
                    [PSCustomObject]@{
                        Tipo   = [TipoXmlDFe]::Evento
                        Modelo = [ModeloDFe]::NFe
                    }
                }

                Mock -CommandName Get-DFeDocumentNamespace { $nfeXmlns }

                Mock -CommandName Resolve-DFeEvento { [DFeEvento]::Cancelamento }
            }

            It 'Calls Resolve-DFeEvento exactly once' {
                Get-DFeXmlMetadata -Path 'test.xml' | Out-Null

                Should -Invoke Resolve-DFeEvento -Times 1 -Exactly
            }

            It 'Passes Modelo and TipoEvento from XML' {
                Get-DFeXmlMetadata -Path 'test.xml' | Out-Null

                Should -Invoke Resolve-DFeEvento -Times 1 -Exactly -ParameterFilter {
                    $Modelo -eq [ModeloDFe]::NFe -and $TipoEvento -eq '110111'
                }
            }
        }

        # General delegation guards
        Context 'Delegation guards' {

            BeforeEach {

                Mock -CommandName Get-DFeDocumentNamespace { $nfeXmlns }

                Mock -CommandName Get-DFeAccessKey { $chNFe }

                # Mock must exist for Should -Invoke -Times 0 to work.
                Mock -CommandName Resolve-DFeEvento { }
            }

            It 'Does not resolve an event for a Documento' {
                Mock -CommandName Import-DFeXml { $nfeProc }

                Mock -CommandName Get-DFeDocumentInfo {
                    [PSCustomObject]@{
                        Tipo   = [TipoXmlDFe]::Documento
                        Modelo = [ModeloDFe]::NFe
                    }
                }

                Get-DFeXmlMetadata -Path 'test.xml' | Out-Null

                Should -Invoke Resolve-DFeEvento -Times 0 -Exactly
            }

            It 'Does not resolve an event for an Inutilizacao' {
                Mock -CommandName Import-DFeXml { $inutNFe }

                Mock -CommandName Get-DFeDocumentInfo {
                    [PSCustomObject]@{
                        Tipo   = [TipoXmlDFe]::Inutilizacao
                        Modelo = [ModeloDFe]::NFCe
                    }
                }

                Get-DFeXmlMetadata -Path 'test.xml' | Out-Null

                Should -Invoke Resolve-DFeEvento -Times 0 -Exactly
            }
        }
        #endregion
    }

    AfterAll {
        Remove-Module -Name PipeDFe -Force -ErrorAction SilentlyContinue
    }
}
