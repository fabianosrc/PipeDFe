#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for Get-DFeNFSeFiscalData.

.DESCRIPTION
Verifies fiscal field extraction from national NFS-e XML documents.

Coverage includes:
  - 50-digit access key stripped from infNFSe/@Id prefix.
  - NFS-e number kept separate from DPS number and series.
  - DPS issuance time, NFS-e generation time, and service competence kept distinct.
  - Party extraction by role (issuer, provider, recipient, intermediary).
  - Absent intermediary returns null.
  - Service and tax field extraction without inventing optional amounts.
  - Optional IBS/CBS totals present in layout 1.01.
  - Absent IBS/CBS block returns null.
  - Common fiscal fields readable in layout 1.00.
  - Rejection of municipal format or standalone DPS root element.
  - Rejection of malformed or short access key.
  - Rejection of impossible competence date.
  - Rejection of missing NFS-e generation time.
  - Rejection of malformed fiscal decimal amount.
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

Describe 'Get-DFeNFSeFiscalData' -Tag 'Unit' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            $Script:Key = '35503082123456780001990000000000001261100000012345'

            # Synthetic projection fixture, not a signed schema-validation fixture.
            $Script:NFSeXml = @"
<NFSe xmlns="http://www.sped.fazenda.gov.br/nfse" versao="1.01">
    <infNFSe Id="NFS$($Script:Key)">
        <nNFSe>9876543210123</nNFSe>
        <cLocIncid>3550308</cLocIncid>
        <cStat>100</cStat>
        <dhProc>2026-11-01T00:05:00-03:00</dhProc>
        <emit>
            <CNPJ>12345678000199</CNPJ>
            <xNome>EMITENTE TESTE</xNome>
        </emit>
        <valores>
            <vBC>100.00</vBC>
            <vISSQN>2.00</vISSQN>
            <vLiq>98.00</vLiq>
        </valores>
        <DPS versao="1.01">
            <infDPS>
                <tpAmb>1</tpAmb>
                <dhEmi>2026-10-31T23:58:00-03:00</dhEmi>
                <serie>00001</serie>
                <nDPS>42</nDPS>
                <dCompet>2026-10-31</dCompet>
                <cLocEmi>3550308</cLocEmi>
                <prest>
                    <CPF>12345678901</CPF>
                </prest>
                <toma>
                    <NIF>EXT-123</NIF>
                    <xNome>TOMADOR TESTE</xNome>
                </toma>
                <serv>
                    <locPrest>
                        <cLocPrestacao>3550308</cLocPrestacao>
                    </locPrest>
                    <cServ>
                        <cTribNac>010701</cTribNac>
                        <xDescServ>Suporte</xDescServ>
                    </cServ>
                </serv>
                <valores>
                    <vServPrest>
                        <vServ>100.00</vServ>
                    </vServPrest>
                    <trib>
                        <tribMun>
                            <tpRetISSQN>2</tpRetISSQN>
                        </tribMun>
                    </trib>
                </valores>
            </infDPS>
        </DPS>
    </infNFSe>
</NFSe>
"@
        }

        It 'Keeps the 50-digit key and the NFS-e number separate from the DPS number' {
            $result = Get-DFeNFSeFiscalData -Xml ([xml]$Script:NFSeXml)

            $result.PSTypeNames        | Should -Contain 'PipeDFe.Fiscal.NFSeDocument'
            $result.ChaveAcesso        | Should -BeExactly $Script:Key
            $result.ChaveAcesso.Length | Should -Be 50
            $result.Numero             | Should -BeExactly '9876543210123'
            $result.DPS.Numero         | Should -BeExactly '42'
            $result.DPS.Serie          | Should -BeExactly '00001'
        }

        It 'Keeps the DPS issuance, NFS-e generation, and service competence separate' {
            $result = [xml]$Script:NFSeXml | Get-DFeNFSeFiscalData

            $result.DhProcessamento.ToString('yyyy-MM-ddTHH:mm:sszzz') |
                Should -BeExactly '2026-11-01T00:05:00-03:00'
            $result.DPS.DhEmissao.ToString('yyyy-MM-ddTHH:mm:sszzz') |
                Should -BeExactly '2026-10-31T23:58:00-03:00'
            $result.DPS.Competencia | Should -BeExactly '2026-10-31'
        }

        It 'Extracts parties by role without replacing the provider with the issuer' {
            $result = Get-DFeNFSeFiscalData -Xml ([xml]$Script:NFSeXml)

            $result.Emitente.Cnpj | Should -BeExactly '12345678000199'
            $result.Prestador.Cpf | Should -BeExactly '12345678901'
            $result.Tomador.Nif   | Should -BeExactly 'EXT-123'
            $result.Intermediario | Should -BeNullOrEmpty
        }

        It 'Extracts declared service and taxes without inventing optional amounts' {
            $result = Get-DFeNFSeFiscalData -Xml ([xml]$Script:NFSeXml)

            $result.Servico.CodigoTributacaoNacional | Should -BeExactly '010701'
            $result.Servico.MunicipioPrestacao       | Should -BeExactly '3550308'
            $result.Totais.ValorServico              | Should -BeOfType ([decimal])
            $result.Totais.ValorServico              | Should -Be 100
            $result.Totais.ValorISSQN                | Should -Be 2
            $result.Totais.ValorLiquido              | Should -Be 98
            $result.Totais.ValorTotalRetencoes       | Should -BeNullOrEmpty
            $result.ISSQN.TipoRetencao               | Should -BeExactly '2'
            $result.IBSCBS                           | Should -BeNullOrEmpty
        }

        It 'Reads optional IBS and CBS from the generated NFS-e totals' {
            $totals = @'
<IBSCBS><totCIBS><vTotNF>110.00</vTotNF>
<gIBS><vIBSTot>3.00</vIBSTot></gIBS><gCBS><vCBS>7.00</vCBS></gCBS>
</totCIBS></IBSCBS>
'@
            $xml = [xml]$Script:NFSeXml.Replace('<DPS versao="1.01">', "$totals<DPS versao=""1.01"">")
            $result = Get-DFeNFSeFiscalData -Xml $xml

            $result.IBSCBS.ValorTotalNF | Should -Be 110
            $result.IBSCBS.ValorIBS     | Should -Be 3
            $result.IBSCBS.ValorCBS     | Should -Be 7
        }

        It 'Reads the common fiscal fields in layout 1.00' {
            $xml = [xml]$Script:NFSeXml.Replace('versao="1.01"', 'versao="1.00"')
            $result = Get-DFeNFSeFiscalData -Xml $xml

            $result.VersaoLeiaute       | Should -BeExactly '1.00'
            $result.Totais.ValorLiquido | Should -Be 98
        }

        It 'Rejects a municipal format or standalone DPS' -ForEach @(
            @{ Payload = '<NFSe xmlns="urn:municipal" />' }
            @{ Payload = '<DPS xmlns="http://www.sped.fazenda.gov.br/nfse" />' }
        ) {
            param ($Payload)

            $xml = [xml]$Payload

            { Get-DFeNFSeFiscalData -Xml $xml } |
                Should -Throw -ErrorId 'UnsupportedNFSeFiscalDocument*'
        }

        It 'Rejects an invalid key without using the DPS identifier' {
            $xml = [xml]$Script:NFSeXml.Replace("NFS$($Script:Key)", ('NFS' + ('1' * 44)))

            { Get-DFeNFSeFiscalData -Xml $xml } |
                Should -Throw -ErrorId 'InvalidNFSeAccessKey*'
        }

        It 'Rejects an impossible competence date instead of normalizing it' {
            $xml = [xml]$Script:NFSeXml.Replace('2026-10-31</dCompet>', '2026-02-30</dCompet>')

            { Get-DFeNFSeFiscalData -Xml $xml } |
                Should -Throw -ErrorId 'InvalidNFSeFiscalField*'
        }

        It 'Does not substitute the DPS issuance when generation time is missing' {
            $xml = [xml]$Script:NFSeXml.Replace('<dhProc>2026-11-01T00:05:00-03:00</dhProc>', '')

            { Get-DFeNFSeFiscalData -Xml $xml } |
                Should -Throw -ErrorId 'InvalidNFSeFiscalField*'
        }

        It 'Rejects a malformed nonempty fiscal amount' {
            $xml = [xml]$Script:NFSeXml.Replace('98.00</vLiq>', '98,00</vLiq>')

            { Get-DFeNFSeFiscalData -Xml $xml } |
                Should -Throw -ErrorId 'InvalidDFeDecimal*'
        }
    }
}
