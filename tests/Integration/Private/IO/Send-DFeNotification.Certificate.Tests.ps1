#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Tests certificate validity notices in monthly DFe notifications.

.DESCRIPTION
Exercises certificate notice classification and renders the real email
template. Password retrieval, certificate file validation, and mail
transport are mocked.

Coverage includes:
  - Missing, null, or blank certificate configuration.
  - A valid certificate outside the renewal window.
  - Expiration at the 30-day boundary and at the reference instant.
  - Missing passwords, unreadable files, and missing expiration dates.
  - Password retrieval and certificate validation exceptions.
  - Footer omission when no certificate is configured.
  - Successful notification with expired or unavailable certificates.
  - Preservation of attachments without leaking certificate details.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSReviewUnusedParameter',
    '',
    Justification = 'Required by Send-Mail mock'
)]

param ()

BeforeDiscovery {
    # InModuleScope needs to resolve the PipeDFe module during the Discovery phase,
    # because that's when Context/It are executed to register the test tree. If the
    # module isn't loaded at that point, InModuleScope fails before any BeforeAll or
    # BeforeEach ever runs.
    $moduleRoot = (Get-Item $PSScriptRoot).Parent.Parent.Parent.Parent.FullName

    $modulePath = Join-Path -Path $moduleRoot -ChildPath 'PipeDFe.psd1'

    Import-Module -Name $modulePath -Force -Global -ErrorAction Stop
}

Describe 'Certificate validity in monthly DFe notifications' -Tag 'Integration' {

    InModuleScope -ModuleName PipeDFe {

        BeforeEach {

            $Script:NoticeCompany = [PSCustomObject]@{
                Cnpj         = '12345678000199'
                NomeFantasia = 'Empresa Teste'
                RazaoSocial  = 'Empresa Teste Ltda'
                Ie           = ''
                Certificado  = [PSCustomObject]@{
                    Path              = 'C:\Private\certificate.pfx'
                    EncryptedPassword = 'encrypted-test-value'
                }
                Email        = [PSCustomObject]@{
                    Para = @('dest@example.com')
                    Cc   = @()
                    Cco  = @()
                }
            }

            $Script:NoticeNow = [System.DateTimeOffset]::new(
                2026, 11, 1, 12, 0, 0, [System.TimeSpan]::Zero
            )

            $Script:NoticeCertificate = [PSCustomObject]@{
                IsValid    = $true
                ExpiresOn  = $Script:NoticeNow.AddDays(60)
                Thumbprint = 'test-thumbprint'
                Subject    = 'CN=Private Subject'
            }

            $Script:NoticeMailBody = $null

            Mock -CommandName Get-CompanyCertificatePassword -MockWith {
                [System.Security.SecureString]::new()
            }

            Mock -CommandName Test-CertificateFile -MockWith {
                $Script:NoticeCertificate
            }

            Mock -CommandName Send-Mail -MockWith {
                param (
                    [Parameter()]
                    [pscustomobject]$SmtpConfig,

                    [Parameter()]
                    [pscustomobject[]]$To,

                    [Parameter()]
                    [pscustomobject[]]$Cc,

                    [Parameter()]
                    [pscustomobject[]]$Bcc,

                    [Parameter()]
                    [string]$Subject,

                    [Parameter()]
                    [string]$Body,

                    [Parameter()]
                    [string[]]$Attachments = @()
                )

                $Script:NoticeMailBody = [System.Net.WebUtility]::HtmlDecode($Body)

                [PSCustomObject]@{
                    Success       = $true
                    EmailsSent    = @('dest@example.com')
                    Error         = $null
                    SendAttempted = $true
                }
            }
        }

        Context 'Certificate notice classification' {

            It 'Omits the notice for <Scenario> without reading a password or file' -ForEach @(
                @{
                    Scenario = 'a missing certificate property'
                }
                @{
                    Scenario = 'a null certificate'
                }
                @{
                    Scenario = 'a missing path property'
                }
                @{
                    Scenario = 'a blank path'
                }
            ) {
                $company = $Script:NoticeCompany

                switch ($Scenario) {
                    'a missing certificate property' {
                        $company.PSObject.Properties.Remove('Certificado')
                    }
                    'a null certificate' {
                        $company.Certificado = $null
                    }
                    'a missing path property' {
                        $company.Certificado.PSObject.Properties.Remove('Path')
                    }
                    'a blank path' {
                        $company.Certificado.Path = ' '
                    }
                }

                Get-DFeCertificateNotice -Company $company | Should -HaveCount 0

                $invokeParamsOne = @{
                    CommandName = 'Get-CompanyCertificatePassword'
                    Exactly     = $true
                    Times       = 0
                    Scope       = 'It'
                    ModuleName  = 'PipeDFe'
                }

                $invokeParamsTwo = @{
                    CommandName = 'Test-CertificateFile'
                    Exactly     = $true
                    Times       = 0
                    Scope       = 'It'
                    ModuleName  = 'PipeDFe'
                }

                Should -Invoke @invokeParamsOne
                Should -Invoke @invokeParamsTwo
            }

            It 'Classifies <Scenario> by the exact expiration instant' -ForEach @(
                @{
                    Scenario   = 'past expiration'
                    OffsetDays = -1
                    ExtraTicks = 0
                    Expected   = 'Certificado vencido em 31/10/2026.'
                }
                @{
                    Scenario   = 'expiration at the reference instant'
                    OffsetDays = 0
                    ExtraTicks = 0
                    Expected   = 'Certificado vencido em 01/11/2026.'
                }
                @{
                    Scenario   = 'expiration at the 30-day boundary'
                    OffsetDays = 30
                    ExtraTicks = 0
                    Expected   = 'Certificado com vencimento próximo: 01/12/2026.'
                }
                @{
                    Scenario   = 'expiration just outside the renewal window'
                    OffsetDays = 30
                    ExtraTicks = 1
                    Expected   = 'Certificado válido até 01/12/2026.'
                }
            ) {
                $expiresOn = $Script:NoticeNow.AddDays($OffsetDays).AddTicks($ExtraTicks)
                $Script:NoticeCertificate.ExpiresOn = $expiresOn.ToOffset(
                    [System.TimeSpan]::FromHours(-3)
                )

                $noticeParams = @{
                    Company = $Script:NoticeCompany
                    Now     = $Script:NoticeNow
                }

                Get-DFeCertificateNotice @noticeParams | Should -BeExactly $Expected
            }

            It 'Reports an unavailable certificate without a password' {
                Mock -CommandName Get-CompanyCertificatePassword -MockWith {
                    $null
                }

                Get-DFeCertificateNotice -Company $Script:NoticeCompany |
                    Should -BeExactly 'Validade do certificado: indisponível.'

                $invokeParams = @{
                    CommandName = 'Test-CertificateFile'
                    Exactly     = $true
                    Times       = 0
                    Scope       = 'It'
                    ModuleName  = 'PipeDFe'
                }

                Should -Invoke @invokeParams
            }

            It 'Reports an unavailable certificate when the reader rejects the file' {
                $Script:NoticeCertificate.IsValid = $false

                Get-DFeCertificateNotice -Company $Script:NoticeCompany |
                    Should -BeExactly 'Validade do certificado: indisponível.'
            }

            It 'Reports an unavailable certificate when no expiration date is returned' {
                $Script:NoticeCertificate.ExpiresOn = $null

                Get-DFeCertificateNotice -Company $Script:NoticeCompany |
                    Should -BeExactly 'Validade do certificado: indisponível.'
            }

            It 'Reports an unavailable certificate when the reader throws' {
                Mock -CommandName Test-CertificateFile -MockWith {
                    throw 'Private certificate read failure.'
                }

                Get-DFeCertificateNotice -Company $Script:NoticeCompany |
                    Should -BeExactly 'Validade do certificado: indisponível.'
            }
        }

        Context 'Monthly email' {

            It 'Sends the attachments with the expected footer for <Scenario>' -ForEach @(
                @{
                    Scenario = 'no configured certificate'
                    Expected = $null
                }
                @{
                    Scenario = 'an expired certificate'
                    Expected = 'Certificado vencido em 01/01/2000.'
                }
                @{
                    Scenario = 'a password that cannot be decrypted'
                    Expected = 'Validade do certificado: indisponível.'
                }
            ) {
                $company = $Script:NoticeCompany

                switch ($Scenario) {
                    'no configured certificate' {
                        $company.Certificado.Path = $null
                    }
                    'an expired certificate' {
                        $Script:NoticeCertificate.ExpiresOn = [System.DateTimeOffset]::new(
                            2000, 1, 1, 12, 0, 0, [System.TimeSpan]::Zero
                        )
                    }
                    'a password that cannot be decrypted' {
                        Mock -CommandName Get-CompanyCertificatePassword -MockWith {
                            throw 'Private DPAPI error containing encrypted-test-value.'
                        }
                    }
                }

                $notificationParams = @{
                    Company            = $company
                    DateRange          = [PSCustomObject]@{ Start = $Script:NoticeNow }
                    Smtp               = [PSCustomObject]@{ Server = 'smtp.example.invalid' }
                    Gaps               = @()
                    Entries            = @()
                    NFSeCount          = 1
                    ZipFileDestination = @('C:\Output\NFSe.zip')
                }

                $result = Send-DFeNotification @notificationParams

                $result.Success        | Should -BeTrue
                $result.ErrorMessage   | Should -BeNullOrEmpty
                $Script:NoticeMailBody | Should -Match '>NFSe</td>'
                $Script:NoticeMailBody | Should -Not -Match '\{\{[^}]*Certificado'

                if ($null -eq $Expected) {
                    $Script:NoticeMailBody | Should -Not -Match '(?i)certificado'
                } else {
                    $footerPattern = [regex]::Escape($Expected) + '(?s:.*?)Enviado por'
                    $Script:NoticeMailBody | Should -Match $footerPattern
                }

                $Script:NoticeMailBody | Should -Not -Match (
                    'certificate\.pfx|encrypted-test-value|test-thumbprint|' +
                    'Private Subject|Private DPAPI error'
                )

                $sendAssertion = @{
                    CommandName     = 'Send-Mail'
                    ModuleName      = 'PipeDFe'
                    Exactly         = $true
                    Times           = 1
                    Scope           = 'It'
                    ParameterFilter = {
                        $Attachments.Count -eq 1 -and
                        $Attachments[0] -eq 'C:\Output\NFSe.zip'
                    }
                }

                Should -Invoke @sendAssertion
            }
        }
    }
}
