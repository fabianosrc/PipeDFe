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

Describe 'Invoke-PipeDFeCompany with national NFS-e' -Tag 'Integration' {

    InModuleScope -ModuleName PipeDFe {

        #region Infrastructure
        BeforeAll {

            $Script:OriginalLocalAppData = $env:LOCALAPPDATA
            $Script:OriginalDataRoot = $env:PIPEDFE_DATA_ROOT

            Add-Type -AssemblyName 'System.IO.Compression'
            Add-Type -AssemblyName 'System.IO.Compression.FileSystem'

            function Get-TestClosingDeliveryStatus {
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
        }

        BeforeEach {

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
                    Start = [datetimeoffset]'2026-11-01T00:00:00-03:00'
                    End   = [datetimeoffset]'2026-11-30T23:59:59-03:00'
                }
            }

            $accessKey = '35503082123456780001990000000000001261100000012345'
            $Script:ClosingXml = @"
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

            $sourcePathParams = @{
                Path      = $Script:ClosingCompany.XmlPathNfse
                ChildPath = 'nota.xml'
            }

            $Script:ClosingSourcePath = Join-Path @sourcePathParams

            [System.IO.File]::WriteAllText(
                $Script:ClosingSourcePath,
                $Script:ClosingXml
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
                $first = Invoke-PipeDFeCompany @params

                $first.Erro            | Should -BeNullOrEmpty
                $first.Status          | Should -BeExactly 'OK'
                $first.TotalDocumentos | Should -Be 1
                $first.Gaps            | Should -Be 0
                $first.EmailEnviado    | Should -BeTrue
                $first.Arquivos        | Should -HaveCount 1
                $first.Arquivos[0]     | Should -BeExactly 'NFSe_12345678000199_EMPRESA_TESTE_202611.zip'

                $zipPath = Join-Path -Path $params.Company.OutputPath -ChildPath $first.Arquivos[0]

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

                Get-FileSha256 -Path $zipPath | Should -BeExactly $firstHash
                Get-TestClosingDeliveryStatus -Cnpj $params.Company.Cnpj |
                    Should -BeExactly 'Delivered'

                Should -Invoke Send-Mail -Exactly -Times 1 -Scope It -ModuleName PipeDFe

                $sendAssertion = @{
                    CommandName     = 'Send-Mail'
                    ModuleName      = 'PipeDFe'
                    Exactly         = $true
                    Times           = 1
                    Scope           = 'It'
                    ParameterFilter = {
                        $Attachments.Count -eq 1 -and
                        [System.IO.Path]::GetFileName($Attachments[0]) -eq
                        'NFSe_12345678000199_EMPRESA_TESTE_202611.zip' -and
                        $Body -match '>NFSe</td>\s*<td[^>]*>1</td>'
                    }
                }

                Should -Invoke @sendAssertion
            }

            It 'Keeps the NFS-e and MDF-e archives separate in one delivery' {
                $params  = $Script:ClosingParams
                $mdfeKey = '2' * 44
                $mdfeXml = @"
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

                $mdfePath = Join-Path -Path $params.Company.XmlPath -ChildPath 'manifesto.xml'

                [System.IO.File]::WriteAllText($mdfePath, $mdfeXml)

                $first  = Invoke-PipeDFeCompany @params
                $second = Invoke-PipeDFeCompany @params

                $first.Erro            | Should -BeNullOrEmpty
                $first.Status          | Should -BeExactly 'OK'
                $first.TotalDocumentos | Should -Be 2
                $first.Arquivos        | Should -HaveCount 2
                $first.Arquivos        | Should -Contain 'MDFe_12345678000199_EMPRESA_TESTE_202611.zip'
                $first.Arquivos        | Should -Contain 'NFSe_12345678000199_EMPRESA_TESTE_202611.zip'
                $second.Status         | Should -BeExactly 'OK'

                Should -Invoke Send-Mail -Exactly -Times 1 -Scope It -ModuleName PipeDFe

                $sendAssertion = @{
                    CommandName     = 'Send-Mail'
                    ModuleName      = 'PipeDFe'
                    Exactly         = $true
                    Times           = 1
                    Scope           = 'It'
                    ParameterFilter = {
                        $Attachments.Count -eq 2 -and
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

                $first.Status              | Should -BeExactly 'Falha'
                $first.EmailEnviado        | Should -BeFalse
                $second.Status             | Should -BeExactly 'Falha'
                $second.EmailEnviado       | Should -BeFalse
                ($second.Avisos -join ' ') | Should -Match "'State'"

                Get-TestClosingDeliveryStatus -Cnpj $params.Company.Cnpj |
                    Should -BeExactly 'Indeterminate'

                Should -Invoke Send-Mail -Exactly -Times 1 -Scope It -ModuleName PipeDFe
            }
        }
        #endregion

        #region Empty period
        Context 'Empty period' {

            It 'Imports an NFS-e without closing the month of its DPS or competence' {
                $params = $Script:ClosingParams.Clone()

                $params.DateRange = [PSCustomObject]@{
                    Start = [System.DateTimeOffset]'2026-10-01T00:00:00-03:00'
                    End   = [System.DateTimeOffset]'2026-10-31T23:59:59-03:00'
                }

                $result = Invoke-PipeDFeCompany @params

                $result.Status                 | Should -BeExactly 'Aviso'
                $result.NFSeScan.FilesImported | Should -Be 1
                $result.TotalDocumentos        | Should -Be 0
                $result.Arquivos               | Should -HaveCount 0

                Test-Path -LiteralPath $params.Company.OutputPath | Should -BeFalse

                Should -Invoke Send-Mail -Exactly -Times 0 -Scope It -ModuleName PipeDFe
            }
        }
        #endregion
    }
}
