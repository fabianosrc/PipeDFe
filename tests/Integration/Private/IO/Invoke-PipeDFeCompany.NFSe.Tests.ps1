#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Integration tests for national NFS-e in the company closing pipeline.

.DESCRIPTION
Runs the company pipeline with real XML files, ZIP archives, and an
isolated SQLite index. SMTP configuration and mail transport are mocked.

Coverage includes:
  - NFS-e-only closing with a ZIP, email summary, and persisted delivery.
  - Selection by NFS-e generation rather than DPS issuance or competence.
  - Separate NFS-e and MDF-e ZIP attachments and summary counts.
  - Stable ZIP metadata and no additional send after confirmed delivery.
  - Persistence of uncertain SMTP outcomes and blocked automatic resend.
  - No archive or send when all imported NFS-e documents are out of period.
  - Partial report pair is not sent when XLSX generation fails.
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
    $moduleRoot = (Get-Item -LiteralPath $PSScriptRoot).Parent.Parent.Parent.Parent.FullName

    $moduleName = Join-Path -Path $moduleRoot -ChildPath 'PipeDFe.psd1'

    Import-Module -Name $moduleName -Force -Global -ErrorAction Stop
}

Describe 'Invoke-PipeDFeCompany with national NFS-e' -Tag 'Integration' {

    InModuleScope -ModuleName PipeDFe {

        #region Infrastructure
        BeforeAll {

            Add-Type -AssemblyName 'System.IO.Compression'
            Add-Type -AssemblyName 'System.IO.Compression.FileSystem'

            $Script:OriginalLocalAppData = $env:LOCALAPPDATA
            $Script:OriginalDataRoot = $env:PIPEDFE_DATA_ROOT

            # NFS-e XML whose dhProc falls in November 2026 while dhEmi and
            # dCompet are in October 2026.  The pipeline must select this document
            # for the November closing (dhProc), not for October (dhEmi/dCompet).
            $accessKey = '35503082123456780001990000000000001261100000012345'
            $Script:NfseXml = @"
<NFSe xmlns="http://www.sped.fazenda.gov.br/nfse" versao="1.01">
    <infNFSe Id="NFS$accessKey">
        <nNFSe>9876543210123</nNFSe>
        <dhProc>2026-11-01T00:05:00-03:00</dhProc>
        <valores><vLiq>98.00</vLiq></valores>
        <DPS>
            <infDPS>
                <dhEmi>2026-10-31T23:58:00-03:00</dhEmi>
                <dCompet>2026-10-31</dCompet>
                <valores><vServPrest><vServ>100.00</vServ></vServPrest></valores>
            </infDPS>
        </DPS>
    </infNFSe>
</NFSe>
"@
            # MDF-e XML used by the multi-archive test.
            $mdfeKey = '2' * 44
            $Script:MdfeXml = @"
<mdfeProc xmlns="http://www.portalfiscal.inf.br/mdfe" versao="3.00">
    <MDFe>
        <infMDFe Id="MDFe$mdfeKey">
            <ide>
                <mod>58</mod>
                <serie>1</serie>
                <nMDF>1</nMDF>
                <dhEmi>2026-11-15T09:00:00-03:00</dhEmi>
            </ide>
        </infMDFe>
    </MDFe>
</mdfeProc>
"@

            # Shared helper: query the concatenated delivery_status values for a CNPJ.
            function Get-ClosingDeliveryStatus {
                [CmdletBinding()]
                [OutputType([string])]
                param (
                    [Parameter(Mandatory)]
                    [string]$Cnpj
                )

                $connection = Open-DFeIndexConnection -Cnpj $Cnpj

                try {
                    $command = $connection.CreateCommand()

                    try {
                        $command.CommandText = @'
SELECT group_concat(delivery_status, ',')
FROM dfe_delivery;
'@
                        [string]$command.ExecuteScalar()
                    } finally {
                        $command.Dispose()
                    }
                } finally {
                    $connection.Dispose()
                }
            }

            # Shared helper: resolve the XLSX worksheet entry by sheet name via
            # workbook.xml rather than a hardcoded positional path.
            function Get-XlsxWorksheetEntry {
                [CmdletBinding()]
                [OutputType([System.IO.Compression.ZipArchiveEntry])]
                param (
                    [Parameter(Mandatory)]
                    [System.IO.Compression.ZipArchive]$Workbook,

                    [Parameter(Mandatory)]
                    [string]$SheetName
                )

                $wbEntry = $Workbook.GetEntry('xl/workbook.xml')

                if ($null -eq $wbEntry) {
                    throw "xl/workbook.xml not found in XLSX."
                }

                $wbStream = $wbEntry.Open()

                try {
                    $wbXml = [System.Xml.XmlDocument]::new()
                    $wbXml.Load($wbStream)
                } finally {
                    $wbStream.Dispose()
                }

                $ns = [System.Xml.XmlNamespaceManager]::new($wbXml.NameTable)
                $ns.AddNamespace('x', 'http://schemas.openxmlformats.org/spreadsheetml/2006/main')
                $ns.AddNamespace('r', 'http://schemas.openxmlformats.org/officeDocument/2006/relationships')

                $sheetNode = $wbXml.SelectSingleNode(
                    "//x:sheet[@name='$SheetName']", $ns
                )

                if ($null -eq $sheetNode) {
                    throw "Sheet '$SheetName' not found in workbook.xml."
                }

                $rId = $sheetNode.GetAttribute(
                    'id',
                    'http://schemas.openxmlformats.org/officeDocument/2006/relationships'
                )

                $relsEntry = $Workbook.GetEntry('xl/_rels/workbook.xml.rels')

                if ($null -eq $relsEntry) {
                    throw "xl/_rels/workbook.xml.rels not found in XLSX."
                }

                $relsStream = $relsEntry.Open()

                try {
                    $relsXml = [System.Xml.XmlDocument]::new()
                    $relsXml.Load($relsStream)
                } finally {
                    $relsStream.Dispose()
                }

                $relNode = $relsXml.SelectSingleNode(
                    "//*[local-name()='Relationship' and @Id='$rId']"
                )

                if ($null -eq $relNode) {
                    throw "Relationship '$rId' not found in workbook.xml.rels."
                }

                $target = $relNode.GetAttribute('Target')

                if ([string]::IsNullOrWhiteSpace($target)) {
                    throw "Relationship '$rId' has an empty target."
                }

                $entryPath = if ($target.StartsWith('/')) {
                    $target.TrimStart('/')
                } else {
                    'xl/' + $target
                }

                $entry = $Workbook.GetEntry($entryPath)

                if ($null -eq $entry) {
                    throw "Worksheet entry '$entryPath' not found in XLSX."
                }

                $entry
            }
        }

        BeforeEach {
            # Every test case gets its own isolated store, xml folders and output
            # folder via a GUID subdirectory of Pester's $TestDrive.
            $casePath = [System.IO.Path]::Combine(
                $TestDrive,
                [guid]::NewGuid().ToString('N')
            )

            $env:LOCALAPPDATA = Join-Path -Path $casePath -ChildPath 'store'
            $env:PIPEDFE_DATA_ROOT = $null

            $Script:ClosingCompany = [PSCustomObject]@{
                Cnpj         = '12345678000199'
                NomeFantasia = 'Empresa Teste'
                RazaoSocial  = 'Empresa Teste Ltda'
                Ie           = ''
                XmlPath      = Join-Path -Path $casePath -ChildPath 'dfe'
                XmlPathNfse  = Join-Path -Path $casePath -ChildPath 'nfse'
                OutputPath   = Join-Path -Path $casePath -ChildPath 'output'
                Email        = [PSCustomObject]@{
                    Para = @('dest@example.com')
                    Cc   = @()
                    Cco  = @()
                }
            }

            [void][System.IO.Directory]::CreateDirectory(
                $Script:ClosingCompany.XmlPath
            )

            [void][System.IO.Directory]::CreateDirectory(
                $Script:ClosingCompany.XmlPathNfse
            )

            $Script:ClosingParams = @{
                Company   = $Script:ClosingCompany
                DateRange = [PSCustomObject]@{
                    Start = [System.DateTimeOffset]'2026-11-01T00:00:00-03:00'
                    End   = [System.DateTimeOffset]'2026-11-30T23:59:59-03:00'
                }
            }

            # Write the NFS-e fixture to the NFS-e folder.
            [System.IO.File]::WriteAllText(
                (Join-Path -Path $Script:ClosingCompany.XmlPathNfse -ChildPath 'nota.xml'),
                $Script:NfseXml
            )

            Mock -CommandName Resolve-DFeSmtp -MockWith {
                [PSCustomObject]@{
                    Server = 'smtp.example.invalid'
                    Port   = 587
                }
            }

            Mock -CommandName Send-Mail -MockWith {
                [PSCustomObject]@{
                    Success       = $true
                    EmailsSent    = @('dest@example.com')
                    Error         = $null
                    SendAttempted = $true
                }
            }
        }

        AfterAll {

            $env:LOCALAPPDATA = $Script:OriginalLocalAppData
            $env:PIPEDFE_DATA_ROOT = $Script:OriginalDataRoot
        }
        #endregion

        #region Confirmed delivery
        Context 'Confirmed delivery' {

            It 'Closes an NFS-e-only period and does not send the same ZIP twice' {
                $params = $Script:ClosingParams
                $first  = Invoke-PipeDFeCompany @params

                $first.Erro            | Should -BeNullOrEmpty
                $first.Status          | Should -BeExactly 'OK'
                $first.TotalDocumentos | Should -Be 1
                $first.Gaps            | Should -Be 0
                $first.EmailEnviado    | Should -BeTrue
                $first.Arquivos        | Should -HaveCount 1
                $first.Arquivos[0]     | Should -BeExactly 'NFSe_12345678000199_EMPRESA_TESTE_202611.zip'

                $zipPath   = Join-Path -Path $params.Company.OutputPath -ChildPath $first.Arquivos[0]
                $firstHash = Get-FileSha256 -Path $zipPath

                $zip = [System.IO.Compression.ZipFile]::OpenRead($zipPath)

                try {
                    $zip.Entries             | Should -HaveCount 1
                    $zip.Entries[0].FullName | Should -BeExactly 'NFSe/202611/nota.xml'
                    $zip.Entries[0].LastWriteTime.DateTime | Should -Be ([datetime]::new(1980, 1, 1))
                } finally {
                    $zip.Dispose()
                }

                $second = Invoke-PipeDFeCompany @params

                $second.Erro            | Should -BeNullOrEmpty
                $second.Status          | Should -BeExactly 'OK'
                $second.TotalDocumentos | Should -Be 1
                $second.Arquivos        | Should -HaveCount 1

                # Archive must be byte-identical - reexecution must not rebuild it.
                Get-FileSha256 -Path $zipPath | Should -BeExactly $firstHash

                Get-ClosingDeliveryStatus -Cnpj $params.Company.Cnpj |
                    Should -BeExactly 'Delivered'

                # Exactly one SMTP call across both executions.
                Should -Invoke Send-Mail -Exactly -Times 1 -Scope It -ModuleName PipeDFe

                # Report assertions
                $reportRoot = Join-Path -Path $params.Company.OutputPath -ChildPath 'Relatorios'

                @(Get-ChildItem -LiteralPath $reportRoot -Directory -Force) | Should -HaveCount 1

                $reportDir   = (Get-ChildItem -LiteralPath $reportRoot -Directory -Force)[0].FullName
                $reportFiles = @(Get-ChildItem -LiteralPath $reportDir -File -Force)
                $reportFiles | Should -HaveCount 2

                $htmlPath = Join-Path -Path $reportDir -ChildPath 'Resumo-CFOP.html'
                $xlsxPath = Join-Path -Path $reportDir -ChildPath 'Fechamento.xlsx'

                $html = [System.IO.File]::ReadAllText($htmlPath)
                $html | Should -Match '<h1>Resumo por CFOP</h1>'
                $html | Should -Match 'Nenhum item de NF-e ou NFC-e'

                # Verify the NFS-e number is present in the XLSX using
                # the sheet name, not a hardcoded positional entry path.
                $workbook = [System.IO.Compression.ZipFile]::OpenRead($xlsxPath)

                try {
                    $wsEntry = Get-XlsxWorksheetEntry -Workbook $workbook -SheetName 'NFS-e'
                    $wsEntry | Should -Not -BeNullOrEmpty

                    $stream = $wsEntry.Open()

                    try {
                        $sheet = [System.Xml.XmlDocument]::new()
                        $sheet.Load($stream)
                    } finally {
                        $stream.Dispose()
                    }

                    $numberCell = $sheet.SelectSingleNode(
                        "//*[local-name()='c' and @r='B6']"
                    )
                    $numberCell          | Should -Not -BeNullOrEmpty
                    $numberCell.InnerText | Should -BeExactly '9876543210123'
                } finally {
                    $workbook.Dispose()
                }

                # --- Send-Mail parameter assertions ---
                $sendAssertion = @{
                    CommandName     = 'Send-Mail'
                    ModuleName      = 'PipeDFe'
                    Exactly         = $true
                    Times           = 1
                    Scope           = 'It'
                    ParameterFilter = {
                        $names = @($Attachments | ForEach-Object {
                                [System.IO.Path]::GetFileName($_)
                            }
                        )

                        $names.Count -eq 3 -and
                        ($names -contains 'NFSe_12345678000199_EMPRESA_TESTE_202611.zip') -and
                        ($names -contains 'Resumo-CFOP.html') -and
                        ($names -contains 'Fechamento.xlsx')  -and
                        $Body -match '>NFSe</td>\s*<td[^>]*>1</td>'
                    }
                }

                Should -Invoke @sendAssertion
            }

            It 'Keeps the NFS-e and MDF-e archives separate in one delivery' {
                $params = $Script:ClosingParams

                # Add an MDF-e to the DFe folder.
                [System.IO.File]::WriteAllText(
                    (Join-Path -Path $params.Company.XmlPath -ChildPath 'manifesto.xml'),
                    $Script:MdfeXml
                )

                $first  = Invoke-PipeDFeCompany @params
                $second = Invoke-PipeDFeCompany @params

                $first.Erro            | Should -BeNullOrEmpty
                $first.Status          | Should -BeExactly 'OK'
                $first.TotalDocumentos | Should -Be 2
                $first.Arquivos        | Should -HaveCount 2
                $first.Arquivos        | Should -Contain 'MDFe_12345678000199_EMPRESA_TESTE_202611.zip'
                $first.Arquivos        | Should -Contain 'NFSe_12345678000199_EMPRESA_TESTE_202611.zip'

                $second.Status   | Should -BeExactly 'OK'
                $second.Arquivos | Should -HaveCount 2

                # Exactly one SMTP call across both executions.
                Should -Invoke Send-Mail -Exactly -Times 1 -Scope It -ModuleName PipeDFe

                $sendAssertion = @{
                    CommandName     = 'Send-Mail'
                    ModuleName      = 'PipeDFe'
                    Exactly         = $true
                    Times           = 1
                    Scope           = 'It'
                    ParameterFilter = {
                        $names = @($Attachments | ForEach-Object {
                                [System.IO.Path]::GetFileName($_)
                            }
                        )

                        $names.Count -eq 4 -and
                        ($names -contains 'MDFe_12345678000199_EMPRESA_TESTE_202611.zip') -and
                        ($names -contains 'NFSe_12345678000199_EMPRESA_TESTE_202611.zip') -and
                        ($names -contains 'Resumo-CFOP.html') -and
                        ($names -contains 'Fechamento.xlsx')  -and
                        $Body -match '>MDFe</td>\s*<td[^>]*>1</td>' -and
                        $Body -match '>NFSe</td>\s*<td[^>]*>1</td>'
                    }
                }

                Should -Invoke @sendAssertion
            }
        }
        #endregion

        #region Uncertain delivery
        Context 'Uncertain delivery' {

            It 'Persists Indeterminate and blocks a second send' {
                Mock -CommandName Send-Mail -MockWith {
                    [PSCustomObject]@{
                        Success       = $false
                        EmailsSent    = @()
                        Error         = 'Connection lost after SMTP transmission started.'
                        SendAttempted = $true
                    }
                }

                $params = $Script:ClosingParams
                $first  = Invoke-PipeDFeCompany @params
                $second = Invoke-PipeDFeCompany @params

                $first.Status        | Should -BeExactly 'Falha'
                $first.EmailEnviado  | Should -BeFalse
                $second.Status       | Should -BeExactly 'Falha'
                $second.EmailEnviado | Should -BeFalse

                # The aviso must name the blocking state explicitly.
                ($second.Avisos -join ' ') |
                    Should -Match "Falha no envio da notificação em 'State'"

                ($second.Avisos -join ' ') |
                    Should -Match 'Connection lost after SMTP transmission started'

                Get-ClosingDeliveryStatus -Cnpj $params.Company.Cnpj |
                    Should -BeExactly 'Indeterminate'

                # Exactly one SMTP call - the second execution must not retry.
                Should -Invoke Send-Mail -Exactly -Times 1 -Scope It -ModuleName PipeDFe

                # Reports must still have been generated on the first run.
                $reportRoot = Join-Path -Path $params.Company.OutputPath -ChildPath 'Relatorios'

                @(Get-ChildItem -LiteralPath $reportRoot -Directory -Force) | Should -HaveCount 1
            }
        }
        #endregion

        #region Empty period
        Context 'Empty period' {

            It 'Imports an NFS-e without closing the month of its DPS or competence' {
                # The fixture's dhProc is 2026-11-01; request October - no documents.
                $params = @{
                    Company   = $Script:ClosingCompany
                    DateRange = [PSCustomObject]@{
                        Start = [System.DateTimeOffset]'2026-10-01T00:00:00-03:00'
                        End   = [System.DateTimeOffset]'2026-10-31T23:59:59-03:00'
                    }
                }

                $result = Invoke-PipeDFeCompany @params

                $result.Status                 | Should -BeExactly 'Aviso'
                $result.NFSeScan.FilesImported | Should -Be 1
                $result.TotalDocumentos        | Should -Be 0
                $result.Arquivos               | Should -HaveCount 0

                # No OutputPath must be created when there is nothing to deliver.
                Test-Path -LiteralPath $params.Company.OutputPath | Should -BeFalse

                Should -Invoke Send-Mail -Exactly -Times 0 -Scope It -ModuleName PipeDFe
            }
        }
        #endregion

        #region Monthly report
        Context 'Monthly report preparation' {

            It 'Does not send or publish a partial report pair when XLSX generation fails' {
                Mock -CommandName Export-DFeCfopReportXlsx -MockWith {
                    throw [System.IO.IOException]::new('Workbook write failed.')
                }

                $params = $Script:ClosingParams
                $result = Invoke-PipeDFeCompany @params

                $result.Status       | Should -BeExactly 'Falha'
                $result.EmailEnviado | Should -BeFalse

                # The aviso must name the failing stage and propagate the message.
                ($result.Avisos -join ' ') | Should -Match "'Reports'"
                ($result.Avisos -join ' ') | Should -Match 'Workbook write failed'

                # Delivery row must remain at Prepared - delivery was never attempted.
                Get-ClosingDeliveryStatus -Cnpj $params.Company.Cnpj |
                    Should -BeExactly 'Prepared'

                # No report files should have been left on disk.
                $reportRoot = Join-Path -Path $params.Company.OutputPath -ChildPath 'Relatorios'

                @(Get-ChildItem -LiteralPath $reportRoot -Force -Recurse -ErrorAction Stop) |
                    Should -HaveCount 0

                Should -Invoke Export-DFeCfopReportXlsx -Exactly -Times 1 -Scope It -ModuleName PipeDFe
                Should -Invoke Send-Mail -Exactly -Times 0 -Scope It -ModuleName PipeDFe
            }
        }
        #endregion
    }
}
