#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for Send-DFeNotification.

.DESCRIPTION
Covers parameter contracts, result object shape, validation stage
(no primary recipient), render stage failure, send stage failure
and happy path. All inner dependencies are mocked.

Coverage includes:
  - Returns a PSCustomObject with Success, EmailsSent, ErrorMessage and FailedAt.
  - Never throws on any failure path.
  - Returns FailedAt = Validation when Para is empty.
  - Does not call Build-MailBody on validation failure.
  - Returns FailedAt = Render when Build-MailBody throws.
  - Does not call Send-Mail on render failure.
  - Returns FailedAt = Send when Send-Mail returns Success = false.
  - Surfaces Send-Mail error on send failure.
  - Returns Success = true on successful send.
  - Returns the recipient addresses from Send-Mail.
  - Returns null ErrorMessage and FailedAt on success.
  - Passes Gaps to Build-MailBody context.
  - Uses RazaoSocial in subject when NomeFantasia is blank.
#>

# InModuleScope needs to resolve the PipeDFe module during the Discovery phase,
# because that's when Context/It are executed to register the test tree. If the
# module isn't loaded at that point, InModuleScope fails before any BeforeAll or
# BeforeEach ever runs.
BeforeDiscovery {
    $moduleRoot = (Get-Item -LiteralPath $PSScriptRoot).Parent.Parent.Parent.Parent.FullName

    $moduleName = Join-Path -Path $moduleRoot -ChildPath 'PipeDFe.psd1'

    Import-Module -Name $moduleName -Force -Global -ErrorAction Stop
}

Describe 'Send-DFeNotification' {

    InModuleScope PipeDFe {

        BeforeAll {

            $Script:ValidCompany = [PSCustomObject]@{
                NomeFantasia = 'Empresa Teste'
                RazaoSocial  = 'Empresa Teste Ltda'
                Cnpj         = '11222333000181'
                Ie           = $null
                Email        = [PSCustomObject]@{
                    Para = @([PSCustomObject]@{ Name = 'Dest'; Email = 'dest@example.com' })
                    Cc   = @()
                    Cco  = @()
                }
            }

            $Script:ValidDateRange = [PSCustomObject]@{
                Start = [System.DateTimeOffset]::new(2026, 1,  1,  0,  0,  0, [System.TimeSpan]::Zero)
                End   = [System.DateTimeOffset]::new(2026, 1, 31, 23, 59, 59, [System.TimeSpan]::Zero)
            }

            $Script:ValidSmtp = [PSCustomObject]@{
                Server = 'smtp.example.com'
                Port   = 587
            }

            $Script:ValidZips = @('C:\Temp\NFe.zip')

            $Script:SuccessMailResult = [PSCustomObject]@{
                Success    = $true
                EmailsSent = @('dest@example.com')
                Error      = $null
            }

            $Script:BaseParams = @{
                Company            = $Script:ValidCompany
                DateRange          = $Script:ValidDateRange
                Smtp               = $Script:ValidSmtp
                Gaps               = @()
                ZipFileDestination = $Script:ValidZips
            }
        }

        BeforeEach {

            Mock -CommandName ConvertTo-NormalizedMailRecipient -MockWith {
                [PSCustomObject]@{ Name = 'Dest'; Email = 'dest@example.com' }
            }

            Mock -CommandName Resolve-SmtpReplyTo -MockWith { $null }

            Mock -CommandName Build-MailBody -MockWith { '<html>body</html>' }

            Mock -CommandName Send-Mail -MockWith { $Script:SuccessMailResult }
        }

        #region Result object shape
        Context 'Result object shape' {

            It 'Returns a PSCustomObject' {
                $result = Send-DFeNotification @Script:BaseParams
                $result | Should -BeOfType [System.Management.Automation.PSCustomObject]
            }

            It 'Exposes exactly the documented properties' {
                $result   = Send-DFeNotification @Script:BaseParams
                $expected = @('Success', 'EmailsSent', 'ErrorMessage', 'FailedAt')
                $actual   = @($result.PSObject.Properties.Name)

                $actual | Should -Be $expected
            }
        }
        #endregion

        #region Never throws
        Context 'Never throws' {

            It 'Does not throw when Build-MailBody throws' {
                Mock -CommandName Build-MailBody -MockWith { throw 'render error' }

                { Send-DFeNotification @Script:BaseParams } | Should -Not -Throw
            }

            It 'Does not throw when Send-Mail returns failure' {
                Mock -CommandName Send-Mail -MockWith {
                    [PSCustomObject]@{
                        Success    = $false
                        EmailsSent = @()
                        Error      = 'Connection refused'
                    }
                }

                { Send-DFeNotification @Script:BaseParams } | Should -Not -Throw
            }
        }
        #endregion

        #region Validation stage
        Context 'Validation stage' {

            BeforeAll {

                Mock -CommandName ConvertTo-NormalizedMailRecipient -MockWith { }
                Mock -CommandName Build-MailBody -MockWith { '<html>body</html>' }
                Mock -CommandName Send-Mail -MockWith { $Script:SuccessMailResult }

                $Script:ValidationResult = Send-DFeNotification @Script:BaseParams
            }

            It 'Returns Success = false when Para is empty' {
                $Script:ValidationResult.Success | Should -BeFalse
            }

            It 'Returns FailedAt = Validation when Para is empty' {
                $Script:ValidationResult.FailedAt | Should -Be 'Validation'
            }

            It 'Returns empty EmailsSent on validation failure' {
                $Script:ValidationResult.EmailsSent | Should -HaveCount 0
            }

            It 'Returns an error message on validation failure' {
                $Script:ValidationResult.ErrorMessage | Should -Not -BeNullOrEmpty
            }

            It 'Does not call Build-MailBody on validation failure' {
                Should -Invoke -CommandName Build-MailBody -Times 0 -Exactly
            }

            It 'Does not call Send-Mail on validation failure' {
                Should -Invoke -CommandName Send-Mail -Times 0 -Exactly
            }
        }
        #endregion

        #region Render stage
        Context 'Render stage' {

            BeforeAll {

                Mock -CommandName ConvertTo-NormalizedMailRecipient -MockWith {
                    [PSCustomObject]@{ Name = 'Dest'; Email = 'dest@example.com' }
                }
                Mock -CommandName Resolve-SmtpReplyTo -MockWith { $null }
                Mock -CommandName Build-MailBody -MockWith { throw 'template missing' }
                Mock -CommandName Send-Mail -MockWith { $Script:SuccessMailResult }

                $Script:RenderResult = Send-DFeNotification @Script:BaseParams
            }

            It 'Returns Success = false when Build-MailBody throws' {
                $Script:RenderResult.Success | Should -BeFalse
            }

            It 'Returns FailedAt = Render when Build-MailBody throws' {
                $Script:RenderResult.FailedAt | Should -Be 'Render'
            }

            It 'Surfaces the exception message on render failure' {
                $Script:RenderResult.ErrorMessage | Should -Match 'template missing'
            }

            It 'Does not call Send-Mail on render failure' {
                Should -Invoke -CommandName Send-Mail -Times 0 -Exactly
            }
        }
        #endregion

        #region Send stage
        Context 'Send stage' {

            BeforeAll {

                Mock -CommandName ConvertTo-NormalizedMailRecipient -MockWith {
                    [PSCustomObject]@{ Name = 'Dest'; Email = 'dest@example.com' }
                }
                Mock -CommandName Resolve-SmtpReplyTo -MockWith { $null }
                Mock -CommandName Build-MailBody -MockWith { '<html>body</html>' }
                Mock -CommandName Send-Mail -MockWith {
                    [PSCustomObject]@{
                        Success    = $false
                        EmailsSent = @()
                        Error      = 'Connection refused'
                    }
                }

                $Script:SendResult = Send-DFeNotification @Script:BaseParams
            }

            It 'Returns Success = false when Send-Mail returns failure' {
                $Script:SendResult.Success | Should -BeFalse
            }

            It 'Returns FailedAt = Send when Send-Mail returns failure' {
                $Script:SendResult.FailedAt | Should -Be 'Send'
            }

            It 'Surfaces Send-Mail error message on send failure' {
                $Script:SendResult.ErrorMessage | Should -Match 'Connection refused'
            }

            It 'Returns empty EmailsSent on send failure' {
                $Script:SendResult.EmailsSent | Should -HaveCount 0
            }
        }
        #endregion

        #region Happy path
        Context 'Happy path' {

            BeforeAll {

                Mock -CommandName ConvertTo-NormalizedMailRecipient -MockWith {
                    [PSCustomObject]@{ Name = 'Dest'; Email = 'dest@example.com' }
                }
                Mock -CommandName Resolve-SmtpReplyTo -MockWith { $null }
                Mock -CommandName Build-MailBody -MockWith { '<html>body</html>' }
                Mock -CommandName Send-Mail -MockWith { $Script:SuccessMailResult }

                $Script:HappyResult = Send-DFeNotification @Script:BaseParams
            }

            It 'Returns Success = true on successful send' {
                $Script:HappyResult.Success | Should -BeTrue
            }

            It 'Returns the recipient addresses from Send-Mail' {
                $Script:HappyResult.EmailsSent | Should -Contain 'dest@example.com'
            }

            It 'Returns null ErrorMessage on success' {
                $Script:HappyResult.ErrorMessage | Should -BeNullOrEmpty
            }

            It 'Returns null FailedAt on success' {
                $Script:HappyResult.FailedAt | Should -BeNullOrEmpty
            }
        }
        #endregion

        #region Context building
        Context 'Context building' {

            It 'Passes Gaps to Build-MailBody context' {
                $gaps = @(
                    [PSCustomObject]@{
                        Inicial = 1
                        Final   = 3
                        Serie   = '001'
                        Especie = 'NF-e'
                    }
                )

                Mock -CommandName Build-MailBody -MockWith {
                    param ($Context)
                    $Context.NotasNaoLancadas | Should -HaveCount 1
                    '<html/>'
                }

                $gapParams = $Script:BaseParams.Clone()
                $gapParams.Gaps = $gaps

                Send-DFeNotification @gapParams | Out-Null
            }

            It 'Uses RazaoSocial in subject when NomeFantasia is blank' {
                $company = [PSCustomObject]@{
                    NomeFantasia = ''
                    RazaoSocial  = 'Empresa Razao Ltda'
                    Cnpj         = '11222333000181'
                    Ie           = $null
                    Email        = [PSCustomObject]@{
                        Para = @([PSCustomObject]@{ Name = 'D'; Email = 'dest@example.com' })
                        Cc   = @()
                        Cco  = @()
                    }
                }

                $companyParams = $Script:BaseParams.Clone()
                $companyParams.Company = $company

                Send-DFeNotification @companyParams | Out-Null

                Should -Invoke -CommandName Send-Mail -Times 1 -Exactly -ParameterFilter {
                    $Subject -match 'EMPRESA'
                }
            }
        }
        #endregion
    }
}
