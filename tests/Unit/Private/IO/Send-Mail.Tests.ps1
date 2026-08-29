#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for Send-Mail.

.DESCRIPTION
Covers parameter validation, result contract, recipient filtering,
optional SMTP metadata, attachments and runtime error handling.

No real SMTP connection is performed by these tests. The success path
(Success = true, EmailsSent populated) requires a live SMTP connection
and is covered by integration tests only.

Coverage includes:
  - Mandatory parameters reject null and empty values.
  - Returns a PSCustomObject with Success, EmailsSent and Error.
  - Does not throw when SMTP delivery fails.
  - Returns Success = false when delivery fails.
  - Returns Success = false when no valid To recipients remain.
  - Returns Success = false when password decryption fails.
  - Does not throw when SenderAddress is absent.
  - Does not throw when ReplyTo is absent.
  - Does not throw when attachment does not exist.
  - Does not throw when Attachments is empty.
  - Ignores null and whitespace attachment paths.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSAvoidUsingConvertToSecureStringWithPlainText',
    '',
    Justification = 'Plain text is acceptable in test context.'
)]

param ()

# InModuleScope needs to resolve the PipeDFe module during the Discovery phase,
# because that's when Context/It are executed to register the test tree. If the
# module isn't loaded at that point, InModuleScope fails before any BeforeAll or
# BeforeEach ever runs.
BeforeDiscovery {
    $moduleRoot = (Get-Item -LiteralPath $PSScriptRoot).Parent.Parent.Parent.Parent.FullName

    $moduleName = Join-Path -Path $moduleRoot -ChildPath 'PipeDFe.psd1'

    Import-Module -Name $moduleName -Force -Global -ErrorAction Stop
}

Describe 'Send-Mail' {

    InModuleScope PipeDFe {

        BeforeAll {

            $Script:ValidSmtp = [PSCustomObject]@{
                Server   = 'smtp.example.com'
                Port     = 587
                Ssl      = $true
                Username = 'user@example.com'
                Password = 'encrypted-password'
                Timeout  = 30
                From     = [PSCustomObject]@{
                    Email = 'from@example.com'
                    Name  = 'From Name'
                }
            }

            $Script:ValidTo = @(
                [PSCustomObject]@{
                    Name  = 'Recipient'
                    Email = 'to@example.com'
                }
            )

            $Script:ValidSubject = 'Test Subject'
            $Script:ValidBody    = '<p>Test</p>'
        }

        BeforeEach {
            Mock -CommandName ConvertFrom-DpapiString -MockWith {
                ConvertTo-SecureString -String 'Ta0r0912yV1cmJ' -AsPlainText -Force
            }
        }

        #region Parameter contract
        Context 'Parameter contract' {

            It 'Rejects null SmtpConfig' {
                $sendParams = @{
                    SmtpConfig = $null
                    To         = $Script:ValidTo
                    Subject    = $Script:ValidSubject
                    Body       = $Script:ValidBody
                }

                { Send-Mail @sendParams } | Should -Throw
            }

            It 'Rejects null To' {
                $sendParams = @{
                    SmtpConfig = $Script:ValidSmtp
                    To         = $null
                    Subject    = $Script:ValidSubject
                    Body       = $Script:ValidBody
                }

                { Send-Mail @sendParams } | Should -Throw
            }

            It 'Rejects empty Subject' {
                $sendParams = @{
                    SmtpConfig = $Script:ValidSmtp
                    To         = $Script:ValidTo
                    Subject    = ''
                    Body       = $Script:ValidBody
                }

                { Send-Mail @sendParams } | Should -Throw
            }

            It 'Rejects empty Body' {
                $sendParams = @{
                    SmtpConfig = $Script:ValidSmtp
                    To         = $Script:ValidTo
                    Subject    = $Script:ValidSubject
                    Body       = ''
                }

                { Send-Mail @sendParams } | Should -Throw
            }
        }
        #endregion

        #region Result contract
        Context 'Result contract' {

            It 'Returns a PSCustomObject' {
                $sendParams = @{
                    SmtpConfig = $Script:ValidSmtp
                    To         = $Script:ValidTo
                    Subject    = $Script:ValidSubject
                    Body       = $Script:ValidBody
                }

                $result = Send-Mail @sendParams

                $result | Should -BeOfType [System.Management.Automation.PSCustomObject]
            }

            It 'Always exposes Success, EmailsSent and Error properties' {
                $sendParams = @{
                    SmtpConfig = $Script:ValidSmtp
                    To         = $Script:ValidTo
                    Subject    = $Script:ValidSubject
                    Body       = $Script:ValidBody
                }

                $result = Send-Mail @sendParams
                $names  = @($result.PSObject.Properties.Name)

                $names | Should -Contain 'Success'
                $names | Should -Contain 'EmailsSent'
                $names | Should -Contain 'Error'
            }
        }
        #endregion

        #region Error handling
        Context 'Error handling' {

            It 'Does not throw when SMTP delivery fails' {
                $sendParams = @{
                    SmtpConfig = $Script:ValidSmtp
                    To         = $Script:ValidTo
                    Subject    = $Script:ValidSubject
                    Body       = $Script:ValidBody
                }

                { Send-Mail @sendParams } | Should -Not -Throw
            }

            It 'Returns Success = false when SMTP delivery fails' {
                $sendParams = @{
                    SmtpConfig = $Script:ValidSmtp
                    To         = $Script:ValidTo
                    Subject    = $Script:ValidSubject
                    Body       = $Script:ValidBody
                }

                $result = Send-Mail @sendParams

                $result.Success    | Should -BeFalse
                $result.Error      | Should -Not -BeNullOrEmpty
                $result.EmailsSent | Should -HaveCount 0
            }

            It 'Does not throw when all To recipients are invalid' {
                $badTo = @(
                    [PSCustomObject]@{ Name = 'Bad'; Email = 'not-an-email' }
                )

                $sendParams = @{
                    SmtpConfig = $Script:ValidSmtp
                    To         = $badTo
                    Subject    = $Script:ValidSubject
                    Body       = $Script:ValidBody
                }

                { Send-Mail @sendParams } | Should -Not -Throw
            }

            It 'Returns Success = false when no valid To recipients remain' {
                $badTo = @(
                    [PSCustomObject]@{
                        Name  = 'Bad'
                        Email = ''
                    }
                )

                $sendParams = @{
                    SmtpConfig = $Script:ValidSmtp
                    To         = $badTo
                    Subject    = $Script:ValidSubject
                    Body       = $Script:ValidBody
                }

                $result = Send-Mail @sendParams

                $result.Success | Should -BeFalse
                $result.Error   | Should -Not -BeNullOrEmpty
            }

            It 'Returns Success = false when password decryption fails' {
                Mock -CommandName ConvertFrom-DpapiString -MockWith {
                    throw 'DPAPI failure'
                }

                $sendParams = @{
                    SmtpConfig = $Script:ValidSmtp
                    To         = $Script:ValidTo
                    Subject    = $Script:ValidSubject
                    Body       = $Script:ValidBody
                }

                $result = Send-Mail @sendParams

                $result.Success | Should -BeFalse
                $result.Error   | Should -Be 'DPAPI failure'
            }

            It 'Does not throw when password decryption fails' {
                Mock -CommandName ConvertFrom-DpapiString -MockWith {
                    throw 'DPAPI failure'
                }

                $sendParams = @{
                    SmtpConfig = $Script:ValidSmtp
                    To         = $Script:ValidTo
                    Subject    = $Script:ValidSubject
                    Body       = $Script:ValidBody
                }

                { Send-Mail @sendParams } | Should -Not -Throw
            }
        }
        #endregion

        #region Optional metadata
        Context 'Optional sender metadata' {

            It 'Does not throw when SenderAddress is absent' {
                $sendParams = @{
                    SmtpConfig = $Script:ValidSmtp
                    To         = $Script:ValidTo
                    Subject    = $Script:ValidSubject
                    Body       = $Script:ValidBody
                }

                { Send-Mail @sendParams } | Should -Not -Throw
            }

            It 'Does not throw when ReplyTo is absent' {
                $sendParams = @{
                    SmtpConfig = $Script:ValidSmtp
                    To         = $Script:ValidTo
                    Subject    = $Script:ValidSubject
                    Body       = $Script:ValidBody
                }

                { Send-Mail @sendParams } | Should -Not -Throw
            }
        }
        #endregion

        #region Attachment handling
        Context 'Attachment handling' {

            It 'Does not throw when attachment does not exist' {
                $sendParams = @{
                    SmtpConfig  = $Script:ValidSmtp
                    To          = $Script:ValidTo
                    Subject     = $Script:ValidSubject
                    Body        = $Script:ValidBody
                    Attachments = @('C:\nonexistent.zip')
                }

                { Send-Mail @sendParams } | Should -Not -Throw
            }

            It 'Does not throw when Attachments is empty' {
                $sendParams = @{
                    SmtpConfig  = $Script:ValidSmtp
                    To          = $Script:ValidTo
                    Subject     = $Script:ValidSubject
                    Body        = $Script:ValidBody
                    Attachments = @()
                }

                { Send-Mail @sendParams } | Should -Not -Throw
            }

            It 'Ignores null and whitespace attachment paths' {
                $sendParams = @{
                    SmtpConfig  = $Script:ValidSmtp
                    To          = $Script:ValidTo
                    Subject     = $Script:ValidSubject
                    Body        = $Script:ValidBody
                    Attachments = @($null, '', '   ')
                }

                { Send-Mail @sendParams } | Should -Not -Throw
            }
        }
        #endregion

        #region SenderAddress
        Context 'SenderAddress in SmtpConfig' {

            It 'Does not throw when SenderAddress has a valid email' {
                $smtpWithSender = [PSCustomObject]@{
                    Server        = $Script:ValidSmtp.Server
                    Port          = $Script:ValidSmtp.Port
                    Ssl           = $Script:ValidSmtp.Ssl
                    Username      = $Script:ValidSmtp.Username
                    Password      = $Script:ValidSmtp.Password
                    Timeout       = $Script:ValidSmtp.Timeout
                    From          = $Script:ValidSmtp.From
                    SenderAddress = [PSCustomObject]@{
                        Email = 'sender@example.com'
                        Name  = 'Sender'
                    }
                }

                $sendParams = @{
                    SmtpConfig = $smtpWithSender
                    To         = $Script:ValidTo
                    Subject    = $Script:ValidSubject
                    Body       = $Script:ValidBody
                }

                { Send-Mail @sendParams } | Should -Not -Throw
            }

            It 'Emits a warning when SenderAddress email is invalid' {
                $smtpWithBadSender = [PSCustomObject]@{
                    Server        = $Script:ValidSmtp.Server
                    Port          = $Script:ValidSmtp.Port
                    Ssl           = $Script:ValidSmtp.Ssl
                    Username      = $Script:ValidSmtp.Username
                    Password      = $Script:ValidSmtp.Password
                    Timeout       = $Script:ValidSmtp.Timeout
                    From          = $Script:ValidSmtp.From
                    SenderAddress = [PSCustomObject]@{
                        Email = 'not-an-email'
                        Name  = 'Bad'
                    }
                }

                $sendParams = @{
                    SmtpConfig = $smtpWithBadSender
                    To         = $Script:ValidTo
                    Subject    = $Script:ValidSubject
                    Body       = $Script:ValidBody
                }

                $warnings = @(
                    Send-Mail @sendParams 3>&1 |
                        Where-Object { $_ -is [System.Management.Automation.WarningRecord] }
                )

                $warnings | Should -Not -BeNullOrEmpty
            }
        }
        #endregion

        #region ReplyTo
        Context 'ReplyTo in SmtpConfig' {

            It 'Does not throw when ReplyTo has a valid email' {
                $smtpWithReplyTo = [PSCustomObject]@{
                    Server  = $Script:ValidSmtp.Server
                    Port    = $Script:ValidSmtp.Port
                    Ssl     = $Script:ValidSmtp.Ssl
                    Username = $Script:ValidSmtp.Username
                    Password = $Script:ValidSmtp.Password
                    Timeout = $Script:ValidSmtp.Timeout
                    From    = $Script:ValidSmtp.From
                    ReplyTo = [PSCustomObject]@{
                        Email = 'reply@example.com'
                        Name  = 'Reply'
                    }
                }

                $sendParams = @{
                    SmtpConfig = $smtpWithReplyTo
                    To         = $Script:ValidTo
                    Subject    = $Script:ValidSubject
                    Body       = $Script:ValidBody
                }

                { Send-Mail @sendParams } | Should -Not -Throw
            }

            It 'Emits a warning when ReplyTo email is invalid' {
                $smtpWithBadReplyTo = [PSCustomObject]@{
                    Server   = $Script:ValidSmtp.Server
                    Port     = $Script:ValidSmtp.Port
                    Ssl      = $Script:ValidSmtp.Ssl
                    Username = $Script:ValidSmtp.Username
                    Password = $Script:ValidSmtp.Password
                    Timeout  = $Script:ValidSmtp.Timeout
                    From     = $Script:ValidSmtp.From
                    ReplyTo  = [PSCustomObject]@{
                        Email = 'not-an-email'
                        Name  = 'Bad'
                    }
                }

                $sendParams = @{
                    SmtpConfig = $smtpWithBadReplyTo
                    To         = $Script:ValidTo
                    Subject    = $Script:ValidSubject
                    Body       = $Script:ValidBody
                }

                $warnings = @(
                    Send-Mail @sendParams 3>&1 |
                        Where-Object { $_ -is [System.Management.Automation.WarningRecord] }
                )

                $warnings | Should -Not -BeNullOrEmpty
            }
        }
        #endregion
    }
}
