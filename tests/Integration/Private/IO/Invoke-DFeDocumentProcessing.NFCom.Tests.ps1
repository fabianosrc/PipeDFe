#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Verifies NFCom processing from XML indexing through SQLite persistence.
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

Describe 'Invoke-DFeDocumentProcessing with NFCom' -Tag 'Integration' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            $Script:OriginalDataRoot = $env:PIPEDFE_DATA_ROOT

            $testID = [guid]::NewGuid().ToString('N')

            $Script:TempRoot = [System.IO.Path]::Combine(
                [System.IO.Path]::GetTempPath(),
                'PipeDFe.Invoke-DFeDocumentProcessing.NFCom.Tests-{0}' -f $testID
            )

            $Script:XmlDir = Join-Path -Path $Script:TempRoot -ChildPath 'xml'
            New-Item -Path $Script:XmlDir -ItemType Directory -Force | Out-Null

            $env:PIPEDFE_DATA_ROOT = Join-Path -Path $Script:TempRoot -ChildPath 'data'

            $Script:Cnpj = '12345678000199'
            $Script:Key  = '35261112345678000199620010000000011234567890'
            $xmlPath     = Join-Path -Path $Script:XmlDir -ChildPath 'nfcom.xml'

            # Synthetic document. No taxpayer data or SMTP configuration is required.
            $xmlContent = @"
<NFCom xmlns="http://www.portalfiscal.inf.br/nfcom">
    <infNFCom Id="NFCom$($Script:Key)">
        <ide>
            <mod>62</mod>
            <serie>001</serie>
            <nNF>1</nNF>
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
"@

            [System.IO.File]::WriteAllText(
                $xmlPath,
                $xmlContent,
                [System.Text.Encoding]::UTF8
            )
        }

        AfterAll {

            $env:PIPEDFE_DATA_ROOT = $Script:OriginalDataRoot

            $removeItemParams = @{
                LiteralPath = $Script:TempRoot
                Recurse     = $true
                Force       = $true
                ErrorAction = 'SilentlyContinue'
            }

            Remove-Item @removeItemParams
        }

        It 'Indexes the XML and persists its item and total before leaving the entry Processed' {
            $scanParams = @{
                Cnpj    = $Script:Cnpj
                XmlPath = $Script:XmlDir
            }

            $scan = Invoke-DFeXmlScan @scanParams
            $scan.FilesFound   | Should -Be 1
            $scan.FilesIndexed | Should -Be 1

            $queryParams = @{
                Cnpj   = $Script:Cnpj
                Modelo = [ModeloDFe]::NFCom
            }

            $entries = @(Get-DFeDocumentEntry @queryParams)
            $entries                      | Should -HaveCount 1
            $entries[0].chave_acesso      | Should -Be $Script:Key
            $entries[0].processing_status | Should -Be 'Indexed'

            $processParams = @{
                Cnpj  = $Script:Cnpj
                Entry = $entries[0]
            }

            Invoke-DFeDocumentProcessing @processParams

            $processedEntries = @(Get-DFeDocumentEntry @queryParams)

            $processedEntries                      | Should -HaveCount 1
            $processedEntries[0].processing_status | Should -Be 'Processed'
            $processedEntries[0].processing_error  | Should -BeNullOrEmpty

            $connection = Open-DFeIndexConnection -Cnpj $Script:Cnpj
            $command    = $null
            $reader     = $null

            try {
                $command = $connection.CreateCommand()
                $command.CommandText = @'
SELECT i.cod_produto, t.vnf
FROM dfe_nfcom AS h
INNER JOIN dfe_nfcom_item AS i ON i.chave_acesso = h.chave_acesso
INNER JOIN dfe_nfcom_total AS t ON t.chave_acesso = h.chave_acesso
WHERE h.chave_acesso = @key;
'@

                $command.Parameters.AddWithValue('@key', $Script:Key) | Out-Null
                $reader = $command.ExecuteReader()

                $reader.Read()       | Should -BeTrue
                $reader.GetString(0) | Should -Be 'SERV001'

                $total = [decimal]::Parse(
                    $reader.GetString(1),
                    [System.Globalization.CultureInfo]::InvariantCulture
                )

                $total         | Should -Be 99.9
                $reader.Read() | Should -BeFalse
            } finally {
                if ($null -ne $reader) {
                    $reader.Dispose()
                }

                if ($null -ne $command) {
                    $command.Dispose()
                }

                $connection.Dispose()
            }
        }
    }
}
