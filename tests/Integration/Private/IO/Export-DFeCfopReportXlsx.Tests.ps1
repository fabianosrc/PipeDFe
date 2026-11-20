#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Integration tests for Export-DFeCfopReportXlsx.

.DESCRIPTION
Creates real XLSX packages in isolated directories and inspects the
package parts, worksheet relationships, and persisted cell values.

Coverage includes:
  - Workbook and worksheet relationships and content types (7 sheets).
  - Separate NF-e and NFC-e worksheets with summaries and item details.
  - Multiple CFOPs on the same invoice and preservation of supplied subtotals.
  - Exact text identifiers, numeric counts and amounts, and blank missing values.
  - Formula-like descriptions stored as text.
  - Empty reports and summaries without a CFOP.
  - Relative literal paths and rejection of non-filesystem destinations.
  - Rejection of invalid periods, paths, and report data.
  - Preservation of an existing destination.
  - Cleanup after an actual worksheet serialization failure.
  - Supplemental worksheets: Document (NFCom, CT-e, MDF-e), NFS-e, and Gaps.
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

Describe 'Export-DFeCfopReportXlsx' -Tag 'Integration' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            Add-Type -AssemblyName 'System.IO.Compression.FileSystem' -ErrorAction Stop

            function Read-TestWorkbookPart {
                [CmdletBinding()]
                [OutputType([System.Xml.XmlDocument])]
                param (
                    [Parameter(Mandatory)]
                    [string]$Path,

                    [Parameter(Mandatory)]
                    [string]$PartName
                )

                $archive = [System.IO.Compression.ZipFile]::OpenRead($Path)

                try {
                    $entry = $archive.GetEntry($PartName)

                    if ($null -eq $entry) {
                        throw "Workbook part '$PartName' was not found."
                    }

                    $stream = $entry.Open()

                    try {
                        $document = [System.Xml.XmlDocument]::new()
                        $document.Load($stream)

                        Write-Output -InputObject $document -NoEnumerate
                    } finally {
                        $stream.Dispose()
                    }
                } finally {
                    $archive.Dispose()
                }
            }

            function Get-TestWorkbookCell {
                [CmdletBinding()]
                [OutputType([System.Xml.XmlNode])]
                param (
                    [Parameter(Mandatory)]
                    [System.Xml.XmlDocument]$Sheet,

                    [Parameter(Mandatory)]
                    [string]$Address
                )

                $Sheet.SelectSingleNode(
                    "//*[local-name()='c' and @r='$Address']"
                )
            }
        }

        BeforeEach {

            $joinPathParamsOne = @{
                Path      = $TestDrive
                ChildPath = [guid]::NewGuid().ToString('N')
            }

            $Script:WorkbookTestDirectory = Join-Path @joinPathParamsOne

            [void][System.IO.Directory]::CreateDirectory(
                $Script:WorkbookTestDirectory
            )

            $joinPathParamsTwo = @{
                Path      = $Script:WorkbookTestDirectory
                ChildPath = 'cfop.xlsx'
            }

            $Script:WorkbookPath = Join-Path @joinPathParamsTwo

            $nfeKey  = '35261112345678000199550010000001231123456789'
            $nfceKey = '35261112345678000199650010000003211123456789'
            $issued  = '2026-11-12T12:00:00.0000000+00:00'

            $Script:WorkbookExportParams = @{
                LiteralPath = $Script:WorkbookPath
                Cnpj        = '12345678000199'
                StartDate   = [System.DateTimeOffset]'2026-11-01T00:00:00-03:00'
                EndDate     = [System.DateTimeOffset]'2026-11-30T23:59:59-03:00'
                ReportData  = [PSCustomObject]@{
                    Itens = @(
                        [PSCustomObject]@{
                            Modelo         = 55
                            ChaveAcesso    = $nfeKey
                            DataEmissao    = $issued
                            Numero         = '000123'
                            Serie          = '001'
                            Item           = 1
                            CodigoProduto  = '0007'
                            Descricao      = '=1+2 & <teste> _x0041_'
                            CFOP           = '5102'
                            ValorProduto   = 60.10d
                            IndCompoeTotal = '1'
                        }
                        [PSCustomObject]@{
                            Modelo         = 55
                            ChaveAcesso    = $nfeKey
                            DataEmissao    = $issued
                            Numero         = '000123'
                            Serie          = '001'
                            Item           = 2
                            CodigoProduto  = '0008'
                            Descricao      = 'Produto B'
                            CFOP           = '5405'
                            ValorProduto   = $null
                            IndCompoeTotal = '0'
                        }
                        [PSCustomObject]@{
                            Modelo         = 65
                            ChaveAcesso    = $nfceKey
                            DataEmissao    = $issued
                            Numero         = '321'
                            Serie          = '001'
                            Item           = 1
                            CodigoProduto  = '0007'
                            Descricao      = 'Produto A'
                            CFOP           = '5102'
                            ValorProduto   = 9.10d
                            IndCompoeTotal = '1'
                        }
                    )

                    ResumoPorCFOP = @(
                        [PSCustomObject]@{
                            Modelo        = 55
                            CFOP          = '5102'
                            Quantidade    = 1
                            ItensSemValor = 0
                            ValorProdutos = 60.10d
                        }
                        [PSCustomObject]@{
                            Modelo        = 55
                            CFOP          = '5405'
                            Quantidade    = 1
                            ItensSemValor = 1
                            ValorProdutos = 0d
                        }
                        [PSCustomObject]@{
                            Modelo        = 65
                            CFOP          = '5102'
                            Quantidade    = 1
                            ItensSemValor = 0
                            ValorProdutos = 9.10d
                        }
                    )
                }
                DocumentEntries = @(
                    [PSCustomObject]@{
                        modelo       = 62
                        chave_acesso = '62261112345678000195620010000000011000000011'
                        dh_emi       = '2026-11-10'
                        ndoc         = '1'
                        serie        = '1'
                    }
                    [PSCustomObject]@{
                        modelo       = 57
                        chave_acesso = '57261112345678000195570010000000011000000011'
                        dh_emi       = '2026-11-11'
                        ndoc         = $null
                        serie        = '1'
                    }
                    [PSCustomObject]@{
                        modelo       = 58
                        chave_acesso = '58261112345678000195580010000000011000000011'
                        dh_emi       = '2026-11-12'
                        ndoc         = '1'
                        serie        = '1'
                    }
                )
                NFSeEntries = @(
                    [PSCustomObject]@{
                        chave_acesso   = 'NFSe261112345678000199'
                        numero         = '100'
                        gerado_em      = '2026-11-15T10:00:00Z'
                        dps_emitida_em = '2026-11-15T09:00:00Z'
                        competencia    = '2026-11'
                        status         = 1
                        valor_servico  = '500.00'
                        valor_liquido  = '475.50'
                    }
                )
                Gaps = @(
                    [PSCustomObject]@{
                        Tipo    = 'gap'
                        Especie = '55'
                        Serie   = '1'
                        Inicial = 5
                        Final   = 9
                    }
                )
            }
        }

        Context 'Workbook package' {

            It 'Publishes a workbook with all 7 worksheets and valid part references' {
                $params = $Script:WorkbookExportParams
                Export-DFeCfopReportXlsx @params | Should -BeExactly $Script:WorkbookPath

                $part = @{
                    Path     = $Script:WorkbookPath
                    PartName = '_rels/.rels'
                }

                $officeNamespace  = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'
                $sheetNamespace   = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'
                $packageNamespace = 'http://schemas.openxmlformats.org/package/2006/relationships'

                $packageRelationships = Read-TestWorkbookPart @part
                $packageRelationships.DocumentElement.NamespaceURI |
                    Should -BeExactly $packageNamespace

                $officeDocument = $packageRelationships.SelectSingleNode(
                    "//*[@Type='$officeNamespace/officeDocument']"
                )

                $officeDocument.GetAttribute('Target') | Should -BeExactly 'xl/workbook.xml'

                $part.PartName = 'xl/workbook.xml'
                $workbook = Read-TestWorkbookPart @part
                $workbook.DocumentElement.NamespaceURI | Should -BeExactly $sheetNamespace

                $sheets = $workbook.SelectNodes("//*[local-name()='sheet']")
                $sheets | Should -HaveCount 7

                $expectedNames = 'NF-e', 'NFC-e', 'NFCom', 'CT-e', 'MDF-e', 'NFS-e', 'Ocorrências'

                for ($i = 0; $i -lt $expectedNames.Count; $i++) {
                    $sheets[$i].GetAttribute('name') |
                        Should -BeExactly $expectedNames[$i] -Because "sheet index $i must be $($expectedNames[$i])"
                }

                $part.PartName = 'xl/_rels/workbook.xml.rels'
                $relationships = Read-TestWorkbookPart @part
                $relationships.DocumentElement.NamespaceURI | Should -BeExactly $packageNamespace

                $part.PartName = '[Content_Types].xml'
                $contentTypes = Read-TestWorkbookPart @part

                $workbookType = $contentTypes.SelectSingleNode("//*[@PartName='/xl/workbook.xml']")
                $workbookType.GetAttribute('ContentType') |
                    Should -BeExactly 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml'

                for ($index = 0; $index -lt $sheets.Count; $index++) {
                    $id = $sheets[$index].GetAttribute('id', $officeNamespace)
                    $id | Should -Not -BeNullOrEmpty

                    $link = $relationships.SelectSingleNode("//*[@Id='$id']")
                    $link.GetAttribute('Type') | Should -BeExactly "$officeNamespace/worksheet"

                    $target = 'worksheets/sheet{0}.xml' -f ($index + 1)
                    $link.GetAttribute('Target') | Should -BeExactly $target

                    $part.PartName = "xl/$target"
                    $sheet = Read-TestWorkbookPart @part
                    $sheet.DocumentElement.LocalName | Should -BeExactly 'worksheet'
                    $sheet.DocumentElement.NamespaceURI | Should -BeExactly $sheetNamespace

                    $sheetType = $contentTypes.SelectSingleNode("//*[@PartName='/xl/$target']")
                    $sheetType.GetAttribute('ContentType') |
                        Should -BeExactly 'application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml'
                }
            }
        }

        Context 'Worksheet contents' {

            It 'Separates models and preserves identifiers, numeric values, and blank amounts' {
                $params = $Script:WorkbookExportParams

                Export-DFeCfopReportXlsx @params | Out-Null

                $part = @{
                    Path     = $Script:WorkbookPath
                    PartName = 'xl/worksheets/sheet1.xml'
                }

                $nfe = Read-TestWorkbookPart @part

                $part.PartName = 'xl/worksheets/sheet2.xml'
                $nfce = Read-TestWorkbookPart @part

                # Layout - NF-e sheet:
                #   Row 1: title
                #   Row 2: B2=CNPJ
                #   Row 3: B3=StartDate, C3=EndDate
                #   Row 5: "Resumo por CFOP"
                #   Row 6: header (A6=CFOP, B6=Itens, C6=Itens sem valor, D6=Valor bruto)
                #   Row 7: 5102 summary  (A7=CFOP, B7=Quantidade, C7=ItensSemValor, D7=ValorProdutos)
                #   Row 8: 5405 summary
                #   Row 9: blank (rowNumber++ after loop)
                #   Row 10: "Detalhamento por item"
                #   Row 11: header (A=ChaveAcesso, B=Emissão, C=Número, D=Série, E=Item,
                #                   F=CódigoProduto, G=Descrição, H=CFOP, I=ValorBruto, J=indTot)
                #   Row 12: item 1  (NF-e, 5102, ValorProduto=60.10, IndCompoeTotal='1')
                #   Row 13: item 2  (NF-e, 5405, ValorProduto=null→I omitted, IndCompoeTotal='0'→J13)
                $checks = @(
                    @{
                        Sheet   = $nfe
                        Address = 'B2'
                        Type    = 'inlineStr'
                        Text    = '12345678000199'
                    }
                    @{
                        Sheet   = $nfe
                        Address = 'B3'
                        Type    = 'inlineStr'
                        Text    = '2026-11-01'
                    }
                    @{
                        Sheet   = $nfe
                        Address = 'C3'
                        Type    = 'inlineStr'
                        Text    = '2026-11-30'
                    }
                    @{
                        Sheet   = $nfe
                        Address = 'A7'
                        Type    = 'inlineStr'
                        Text    = '5102'
                    }
                    @{
                        Sheet   = $nfe
                        Address = 'D7'
                        Type    = $null
                        Text    = '60.10'
                    }
                    @{
                        Sheet   = $nfe
                        Address = 'A8'
                        Type    = 'inlineStr'
                        Text    = '5405'
                    }
                    @{
                        Sheet   = $nfe
                        Address = 'B8'
                        Type    = $null
                        Text    = '1'
                    }
                    @{
                        Sheet   = $nfe
                        Address = 'C8'
                        Type    = $null
                        Text    = '1'
                    }
                    @{
                        Sheet   = $nfe
                        Address = 'D8'
                        Type    = $null
                        Text    = '0'
                    }
                    @{
                        Sheet   = $nfe
                        Address = 'C12'
                        Type    = 'inlineStr'
                        Text    = '000123'
                    }
                    @{
                        Sheet   = $nfe
                        Address = 'D12'
                        Type    = 'inlineStr'
                        Text    = '001'
                    }
                    @{
                        Sheet   = $nfe
                        Address = 'E12'
                        Type    = $null
                        Text    = '1'
                    }
                    @{
                        Sheet   = $nfe
                        Address = 'E13'
                        Type    = $null
                        Text    = '2'
                    }
                    @{
                        Sheet   = $nfe
                        Address = 'F12'
                        Type    = 'inlineStr'
                        Text    = '0007'
                    }
                    @{
                        Sheet   = $nfe
                        Address = 'H12'
                        Type    = 'inlineStr'
                        Text    = '5102'
                    }
                    @{
                        Sheet   = $nfe
                        Address = 'H13'
                        Type    = 'inlineStr'
                        Text    = '5405'
                    }
                    @{
                        Sheet   = $nfce
                        Address = 'A7'
                        Type    = 'inlineStr'
                        Text    = '5102'
                    }
                    @{
                        Sheet   = $nfce
                        Address = 'D7'
                        Type    = $null
                        Text    = '9.10'
                    }
                )

                foreach ($check in $checks) {
                    $cellParams = @{
                        Sheet   = $check.Sheet
                        Address = $check.Address
                    }

                    $cell = Get-TestWorkbookCell @cellParams
                    $cell | Should -Not -BeNullOrEmpty -Because "cell $($check.Address) is required"
                    $cell.InnerText | Should -BeExactly $check.Text -Because $check.Address

                    if ($null -eq $check.Type) {
                        # Numeric cells omit the 't' attribute - absence is the OOXML default for numbers.
                        $cell.GetAttribute('t') | Should -BeNullOrEmpty -Because $check.Address
                    } else {
                        $cell.GetAttribute('t') | Should -BeExactly $check.Type -Because $check.Address
                    }
                }

                $firstKey  = Get-TestWorkbookCell -Sheet $nfe  -Address 'A12'
                $secondKey = Get-TestWorkbookCell -Sheet $nfe  -Address 'A13'
                $nfceKey   = Get-TestWorkbookCell -Sheet $nfce -Address 'A11'

                $firstKey.GetAttribute('t') | Should -BeExactly 'inlineStr'
                $firstKey.InnerText         | Should -BeExactly $params.ReportData.Itens[0].ChaveAcesso
                $secondKey.InnerText        | Should -BeExactly $firstKey.InnerText
                $nfceKey.InnerText          | Should -BeExactly $params.ReportData.Itens[2].ChaveAcesso

                # Numeric cells omit the 't' attribute - absence is the OOXML default for numbers.
                (Get-TestWorkbookCell -Sheet $nfe -Address 'I12').GetAttribute('t') |
                    Should -BeNullOrEmpty

                (Get-TestWorkbookCell -Sheet $nfe -Address 'I12').InnerText |
                    Should -BeExactly '60.10'

                # I13 is absent because ValorProduto is null for item 2.
                (Get-TestWorkbookCell -Sheet $nfe  -Address 'I13') | Should -BeNullOrEmpty

                # J13 = IndCompoeTotal for item 2 ('0' as inlineStr; I13 is omitted so J stays in column J).
                (Get-TestWorkbookCell -Sheet $nfe -Address 'J13') | Should -Not -BeNullOrEmpty
                (Get-TestWorkbookCell -Sheet $nfe -Address 'J13').GetAttribute('t') | Should -BeExactly 'inlineStr'
                (Get-TestWorkbookCell -Sheet $nfe -Address 'J13').InnerText | Should -BeExactly '0'

                (Get-TestWorkbookCell -Sheet $nfe  -Address 'A14') | Should -BeNullOrEmpty
                (Get-TestWorkbookCell -Sheet $nfce -Address 'A12') | Should -BeNullOrEmpty
            }

            It 'Exports the supplied subtotal instead of rebuilding it from item values' {
                # Build an independent copy to avoid mutating $Script:WorkbookExportParams.
                # ValorProdutos = 72.35 deliberately differs from the item's ValorProduto = 60.10
                # to distinguish a renderer that re-sums from one that uses the supplied value.
                $nfeKey  = '35261112345678000199550010000001231123456789'
                $nfceKey = '35261112345678000199650010000003211123456789'
                $issued  = '2026-11-12T12:00:00.0000000+00:00'

                # Use a dedicated path so this It does not collide with cfop.xlsx from a sibling It.
                $subtotalPath = Join-Path -Path $Script:WorkbookTestDirectory -ChildPath 'subtotal.xlsx'

                $params = @{
                    LiteralPath = $subtotalPath
                    Cnpj        = '12345678000199'
                    StartDate   = [System.DateTimeOffset]'2026-11-01T00:00:00-03:00'
                    EndDate     = [System.DateTimeOffset]'2026-11-30T23:59:59-03:00'
                    ReportData  = [PSCustomObject]@{
                        Itens         = @(
                            [PSCustomObject]@{
                                Modelo         = 55
                                ChaveAcesso    = $nfeKey
                                DataEmissao    = $issued
                                Numero         = '000123'
                                Serie          = '001'
                                Item           = 1
                                CodigoProduto  = '0007'
                                Descricao      = 'Produto A'
                                CFOP           = '5102'
                                ValorProduto   = 60.10d
                                IndCompoeTotal = '1'
                            }
                            [PSCustomObject]@{
                                Modelo         = 65
                                ChaveAcesso    = $nfceKey
                                DataEmissao    = $issued
                                Numero         = '321'
                                Serie          = '001'
                                Item           = 1
                                CodigoProduto  = '0007'
                                Descricao      = 'Produto A'
                                CFOP           = '5102'
                                ValorProduto   = 9.10d
                                IndCompoeTotal = '1'
                            }
                        )
                        ResumoPorCFOP = @(
                            [PSCustomObject]@{
                                Modelo        = 55
                                CFOP          = '5102'
                                Quantidade    = 1
                                ItensSemValor = 0
                                ValorProdutos = 72.35d
                            }
                            [PSCustomObject]@{
                                Modelo        = 65
                                CFOP          = '5102'
                                Quantidade    = 1
                                ItensSemValor = 0
                                ValorProdutos = 9.10d
                            }
                        )
                    }
                }

                Export-DFeCfopReportXlsx @params | Out-Null

                $part = @{
                    Path     = $subtotalPath
                    PartName = 'xl/worksheets/sheet1.xml'
                }

                $sheet = Read-TestWorkbookPart @part

                (Get-TestWorkbookCell -Sheet $sheet -Address 'D7').InnerText |
                    Should -BeExactly '72.35'

                (Get-TestWorkbookCell -Sheet $sheet -Address 'I11').InnerText |
                    Should -BeExactly '60.10'
            }

            It 'Writes formula-like descriptions as text without creating formula cells' {
                $params = $Script:WorkbookExportParams

                Export-DFeCfopReportXlsx @params | Out-Null

                $part = @{
                    Path     = $Script:WorkbookPath
                    PartName = 'xl/worksheets/sheet1.xml'
                }

                $sheet = Read-TestWorkbookPart @part
                $cell  = Get-TestWorkbookCell -Sheet $sheet -Address 'G12'

                $cell.GetAttribute('t') | Should -BeExactly 'inlineStr'
                $cell.InnerText | Should -BeExactly '=1+2 & <teste> _x005F_x0041_'
                $sheet.SelectNodes("//*[local-name()='f']") | Should -HaveCount 0
            }

            It 'Labels a summary group without a CFOP' {
                # Build an independent copy to avoid mutating $Script:WorkbookExportParams.
                $nfeKey = '35261112345678000199550010000001231123456789'
                $issued = '2026-11-12T12:00:00.0000000+00:00'

                $params = @{
                    LiteralPath = $Script:WorkbookPath
                    Cnpj        = '12345678000199'
                    StartDate   = [System.DateTimeOffset]'2026-11-01T00:00:00-03:00'
                    EndDate     = [System.DateTimeOffset]'2026-11-30T23:59:59-03:00'
                    ReportData  = [PSCustomObject]@{
                        Itens         = @(
                            [PSCustomObject]@{
                                Modelo         = 55
                                ChaveAcesso    = $nfeKey
                                DataEmissao    = $issued
                                Numero         = '000123'
                                Serie          = '001'
                                Item           = 1
                                CodigoProduto  = '0007'
                                Descricao      = 'Produto A'
                                CFOP           = $null
                                ValorProduto   = 60.10d
                                IndCompoeTotal = '1'
                            }
                        )
                        ResumoPorCFOP = @(
                            [PSCustomObject]@{
                                Modelo        = 55
                                CFOP          = $null
                                Quantidade    = 1
                                ItensSemValor = 0
                                ValorProdutos = 60.10d
                            }
                        )
                    }
                }

                Export-DFeCfopReportXlsx @params | Out-Null

                $part = @{
                    Path     = $Script:WorkbookPath
                    PartName = 'xl/worksheets/sheet1.xml'
                }

                $sheet = Read-TestWorkbookPart @part

                (Get-TestWorkbookCell -Sheet $sheet -Address 'A7').InnerText |
                    Should -BeExactly 'Não informado'
            }

            It 'Keeps both worksheet sections without fabricating fiscal rows for an empty report' {
                $params = @{
                    LiteralPath = $Script:WorkbookPath
                    Cnpj        = '12345678000199'
                    StartDate   = [System.DateTimeOffset]'2026-11-01T00:00:00-03:00'
                    EndDate     = [System.DateTimeOffset]'2026-11-30T23:59:59-03:00'
                    ReportData  = [PSCustomObject]@{
                        Itens         = @()
                        ResumoPorCFOP = @()
                    }
                }

                Export-DFeCfopReportXlsx @params | Out-Null

                # Sheets 1 (NF-e) and 2 (NFC-e) have both CFOP and item sections.
                foreach ($number in 1, 2) {
                    $part = @{
                        Path     = $Script:WorkbookPath
                        PartName = 'xl/worksheets/sheet{0}.xml' -f $number
                    }

                    $sheet = Read-TestWorkbookPart @part

                    (Get-TestWorkbookCell -Sheet $sheet -Address 'A6').InnerText |
                        Should -BeExactly 'CFOP'

                    (Get-TestWorkbookCell -Sheet $sheet -Address 'A7') |
                        Should -BeNullOrEmpty

                    (Get-TestWorkbookCell -Sheet $sheet -Address 'A9').InnerText |
                        Should -BeExactly 'Chave de acesso'

                    (Get-TestWorkbookCell -Sheet $sheet -Address 'A10') |
                        Should -BeNullOrEmpty
                }

                # Sheets 3–7 are supplemental: they write column headers in row 5
                # and no data rows when the supplied collections are empty.
                foreach ($number in 3, 4, 5) {
                    $part = @{
                        Path     = $Script:WorkbookPath
                        PartName = 'xl/worksheets/sheet{0}.xml' -f $number
                    }

                    $sheet = Read-TestWorkbookPart @part

                    (Get-TestWorkbookCell -Sheet $sheet -Address 'A5').InnerText |
                        Should -BeExactly 'Chave de acesso'

                    (Get-TestWorkbookCell -Sheet $sheet -Address 'A6') |
                        Should -BeNullOrEmpty
                }

                $nfseSheet = Read-TestWorkbookPart -Path $Script:WorkbookPath -PartName 'xl/worksheets/sheet6.xml'

                (Get-TestWorkbookCell -Sheet $nfseSheet -Address 'A5').InnerText |
                    Should -BeExactly 'Chave de acesso'

                (Get-TestWorkbookCell -Sheet $nfseSheet -Address 'A6') |
                    Should -BeNullOrEmpty

                $gapSheet = Read-TestWorkbookPart -Path $Script:WorkbookPath -PartName 'xl/worksheets/sheet7.xml'

                (Get-TestWorkbookCell -Sheet $gapSheet -Address 'A5').InnerText |
                    Should -BeExactly 'Tipo'

                (Get-TestWorkbookCell -Sheet $gapSheet -Address 'A6') |
                    Should -BeNullOrEmpty
            }
        }

        Context 'Supplemental worksheets' {

            It 'Writes the NFCom document entry with chave_acesso, dh_emi, and ndoc' {
                $params = $Script:WorkbookExportParams
                Export-DFeCfopReportXlsx @params | Out-Null

                $sheet = Read-TestWorkbookPart -Path $Script:WorkbookPath -PartName 'xl/worksheets/sheet3.xml'

                (Get-TestWorkbookCell -Sheet $sheet -Address 'A6').InnerText |
                    Should -BeExactly '62261112345678000195620010000000011000000011'

                (Get-TestWorkbookCell -Sheet $sheet -Address 'B6').InnerText |
                    Should -BeExactly '2026-11-10'

                (Get-TestWorkbookCell -Sheet $sheet -Address 'C6').InnerText |
                    Should -BeExactly '1'
            }

            It 'Leaves column C empty when ndoc is null for a CT-e entry' {
                $params = $Script:WorkbookExportParams
                Export-DFeCfopReportXlsx @params | Out-Null

                $sheet = Read-TestWorkbookPart -Path $Script:WorkbookPath -PartName 'xl/worksheets/sheet4.xml'

                Get-TestWorkbookCell -Sheet $sheet -Address 'C6' |
                    Should -BeNullOrEmpty
            }

            It 'Writes NFS-e amounts as numeric cells in columns G and H' {
                $params = $Script:WorkbookExportParams
                Export-DFeCfopReportXlsx @params | Out-Null

                $sheet = Read-TestWorkbookPart -Path $Script:WorkbookPath -PartName 'xl/worksheets/sheet6.xml'

                $g6 = Get-TestWorkbookCell -Sheet $sheet -Address 'G6'
                $g6 | Should -Not -BeNullOrEmpty
                $g6.InnerText | Should -BeExactly '500.00'
                $g6.GetAttribute('t') | Should -BeNullOrEmpty

                $h6 = Get-TestWorkbookCell -Sheet $sheet -Address 'H6'
                $h6 | Should -Not -BeNullOrEmpty
                $h6.InnerText | Should -BeExactly '475.50'
                $h6.GetAttribute('t') | Should -BeNullOrEmpty
            }

            It 'Writes the gap range with numeric start and end in columns D and E' {
                $params = $Script:WorkbookExportParams
                Export-DFeCfopReportXlsx @params | Out-Null

                $sheet = Read-TestWorkbookPart -Path $Script:WorkbookPath -PartName 'xl/worksheets/sheet7.xml'

                $d6 = Get-TestWorkbookCell -Sheet $sheet -Address 'D6'
                $d6 | Should -Not -BeNullOrEmpty
                $d6.InnerText | Should -BeExactly '5'
                $d6.GetAttribute('t') | Should -BeNullOrEmpty

                $e6 = Get-TestWorkbookCell -Sheet $sheet -Address 'E6'
                $e6 | Should -Not -BeNullOrEmpty
                $e6.InnerText | Should -BeExactly '9'
                $e6.GetAttribute('t') | Should -BeNullOrEmpty
            }

            It 'Preserves National NFS-e identifiers and dates without shifting a missing amount' {
                $params = $Script:WorkbookExportParams.Clone()
                $params.NFSeEntries = @(
                    [PSCustomObject]@{
                        chave_acesso   = '1234567890' * 5
                        numero         = '0000000000100'
                        gerado_em      = '2026-11-15T10:00:00Z'
                        dps_emitida_em = '2026-11-14T09:00:00Z'
                        competencia    = '2026-10-31'
                        status         = 1
                        valor_servico  = $null
                        valor_liquido  = '0.00'
                    }
                )

                Export-DFeCfopReportXlsx @params | Out-Null

                $part = @{
                    Path     = $Script:WorkbookPath
                    PartName = 'xl/worksheets/sheet6.xml'
                }

                $sheet = Read-TestWorkbookPart @part

                $keyCell = Get-TestWorkbookCell -Sheet $sheet -Address 'A6'
                $keyCell.GetAttribute('t') | Should -BeExactly 'inlineStr'
                $keyCell.InnerText         | Should -BeExactly ('1234567890' * 5)

                $numberCell = Get-TestWorkbookCell -Sheet $sheet -Address 'B6'
                $numberCell.GetAttribute('t') | Should -BeExactly 'inlineStr'
                $numberCell.InnerText         | Should -BeExactly '0000000000100'

                (Get-TestWorkbookCell -Sheet $sheet -Address 'C6').InnerText |
                    Should -BeExactly '2026-11-15T10:00:00Z'

                (Get-TestWorkbookCell -Sheet $sheet -Address 'D6').InnerText |
                    Should -BeExactly '2026-11-14T09:00:00Z'

                (Get-TestWorkbookCell -Sheet $sheet -Address 'E6').InnerText |
                    Should -BeExactly '2026-10-31'

                Get-TestWorkbookCell -Sheet $sheet -Address 'G6' |
                    Should -BeNullOrEmpty

                $netCell = Get-TestWorkbookCell -Sheet $sheet -Address 'H6'
                $netCell.GetAttribute('t') | Should -BeNullOrEmpty
                $netCell.InnerText         | Should -BeExactly '0.00'
            }
        }

        Context 'Destination and input validation' {

            It 'Creates a new workbook at a relative literal path with brackets' {
                $params = @{
                    LiteralPath = 'cfop[novembro].xlsx'
                    Cnpj        = '12345678000199'
                    StartDate   = [System.DateTimeOffset]'2026-11-01T00:00:00-03:00'
                    EndDate     = [System.DateTimeOffset]'2026-11-30T23:59:59-03:00'
                    ReportData  = [PSCustomObject]@{ Itens = @(); ResumoPorCFOP = @() }
                }

                $joinPathParam = @{
                    Path      = $Script:WorkbookTestDirectory
                    ChildPath = $params.LiteralPath
                }

                $expectedPath = Join-Path @joinPathParam

                Push-Location -LiteralPath $Script:WorkbookTestDirectory

                try {
                    $actualPath = Export-DFeCfopReportXlsx @params
                } finally {
                    Pop-Location
                }

                $actualPath | Should -BeExactly $expectedPath
                Test-Path -LiteralPath $expectedPath -PathType Leaf | Should -BeTrue
            }

            It 'Rejects <Scenario> before publishing a workbook' -ForEach @(
                @{
                    Scenario = 'a reversed period'
                    ErrorId  = 'InvalidDateRange*'
                }
                @{
                    Scenario = 'a non-XLSX path'
                    ErrorId  = 'InvalidLiteralPath*'
                }
                @{
                    Scenario = 'a non-filesystem path'
                    ErrorId  = 'InvalidLiteralPath*'
                }
                @{
                    Scenario = 'a missing output directory'
                    ErrorId  = 'DestinationDirectoryNotFound*'
                }
                @{
                    Scenario = 'a missing report collection'
                    ErrorId  = 'InvalidReportData*'
                }
                @{
                    Scenario = 'an unsupported model'
                    ErrorId  = 'InvalidReportData*'
                }
            ) {
                # Build an independent copy for each scenario to avoid cross-scenario mutation.
                $nfeKey = '35261112345678000199550010000001231123456789'

                $params = @{
                    LiteralPath = $Script:WorkbookPath
                    Cnpj        = '12345678000199'
                    StartDate   = [System.DateTimeOffset]'2026-11-01T00:00:00-03:00'
                    EndDate     = [System.DateTimeOffset]'2026-11-30T23:59:59-03:00'
                    ReportData  = [PSCustomObject]@{
                        Itens         = @(
                            [PSCustomObject]@{
                                Modelo         = 55
                                ChaveAcesso    = $nfeKey
                                DataEmissao    = '2026-11-12T12:00:00.0000000+00:00'
                                Numero         = '000123'
                                Serie          = '001'
                                Item           = 1
                                CodigoProduto  = '0007'
                                Descricao      = 'Produto A'
                                CFOP           = '5102'
                                ValorProduto   = 60.10d
                                IndCompoeTotal = '1'
                            }
                        )
                        ResumoPorCFOP = @(
                            [PSCustomObject]@{
                                Modelo        = 55
                                CFOP          = '5102'
                                Quantidade    = 1
                                ItensSemValor = 0
                                ValorProdutos = 60.10d
                            }
                        )
                    }
                }

                switch ($Scenario) {
                    'a reversed period' {
                        $params.EndDate = $params.StartDate.AddTicks(-1)
                    }
                    'a non-XLSX path' {
                        $params.LiteralPath = [System.IO.Path]::ChangeExtension(
                            $params.LiteralPath, '.txt'
                        )
                    }
                    'a non-filesystem path' {
                        $params.LiteralPath = 'Env:PipeDFeTestWorkbook.xlsx'
                    }
                    'a missing output directory' {
                        $params.LiteralPath = [System.IO.Path]::Combine(
                            $Script:WorkbookTestDirectory, 'missing', 'cfop.xlsx'
                        )
                    }
                    'a missing report collection' {
                        $params.ReportData.PSObject.Properties.Remove('Itens')
                    }
                    'an unsupported model' {
                        $params.ReportData.Itens[0].Modelo = 62
                    }
                }

                { Export-DFeCfopReportXlsx @params } | Should -Throw -ErrorId $ErrorId

                @(Get-ChildItem -LiteralPath $Script:WorkbookTestDirectory -Force) |
                    Should -HaveCount 0
            }

            It 'Preserves an existing destination without leaving a staging file' {
                $params = @{
                    LiteralPath = $Script:WorkbookPath
                    Cnpj        = '12345678000199'
                    StartDate   = [System.DateTimeOffset]'2026-11-01T00:00:00-03:00'
                    EndDate     = [System.DateTimeOffset]'2026-11-30T23:59:59-03:00'
                    ReportData  = [PSCustomObject]@{ Itens = @(); ResumoPorCFOP = @() }
                }

                [System.IO.File]::WriteAllText($params.LiteralPath, 'original')

                { Export-DFeCfopReportXlsx @params } |
                    Should -Throw -ErrorId 'WorkbookAlreadyExists*'

                [System.IO.File]::ReadAllText($params.LiteralPath) |
                    Should -BeExactly 'original'

                @(Get-ChildItem -LiteralPath $Script:WorkbookTestDirectory -Force) |
                    Should -HaveCount 1
            }
        }

        Context 'Failed publication' {

            It 'Removes the staging file when worksheet XML serialization fails' {
                $params = @{
                    LiteralPath = $Script:WorkbookPath
                    Cnpj        = '12345678000199'
                    StartDate   = [System.DateTimeOffset]'2026-11-01T00:00:00-03:00'
                    EndDate     = [System.DateTimeOffset]'2026-11-30T23:59:59-03:00'
                    ReportData  = [PSCustomObject]@{
                        Itens         = @(
                            [PSCustomObject]@{
                                Modelo         = 55
                                ChaveAcesso    = '35261112345678000199550010000001231123456789'
                                DataEmissao    = '2026-11-12T12:00:00.0000000+00:00'
                                Numero         = '000123'
                                Serie          = '001'
                                Item           = 1
                                CodigoProduto  = '0007'
                                Descricao      = 'Invalid XML ' + [char]1
                                CFOP           = '5102'
                                ValorProduto   = 60.10d
                                IndCompoeTotal = '1'
                            }
                        )
                        ResumoPorCFOP = @(
                            [PSCustomObject]@{
                                Modelo        = 55
                                CFOP          = '5102'
                                Quantidade    = 1
                                ItensSemValor = 0
                                ValorProdutos = 60.10d
                            }
                        )
                    }
                }

                { Export-DFeCfopReportXlsx @params } | Should -Throw

                Test-Path -LiteralPath $params.LiteralPath | Should -BeFalse

                @(Get-ChildItem -LiteralPath $Script:WorkbookTestDirectory -Force) |
                    Should -HaveCount 0
            }
        }
    }
}
