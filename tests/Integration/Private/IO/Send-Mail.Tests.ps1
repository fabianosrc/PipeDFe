#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Integration tests for Send-Mail.

.DESCRIPTION
Sends real emails through the SMTP server configured in
tests/Fixtures/smtp-secrets.json.

The suite is skipped unless PIPEDF_SMTP_TEST is set to '1' and
tests/Fixtures/smtp-secrets.json exists. This prevents accidental
SMTP calls during normal test runs and CI environments that do not
explicitly opt in to integration testing.

To run locally:
  1. Create tests/Fixtures/smtp-secrets.json with the following structure:
     {
       "Server":   "smtp.locaweb.com.br",
       "Port":     587,
       "Ssl":      true,
       "Username": "you@domain.com",
       "Password": "plaintext-password",
       "Timeout":  30,
       "From": {
         "Name":  "PipeDFe Teste",
         "Email": "you@domain.com"
       },
       "To": "you@domain.com"
     }
  2. Set $env:PIPEDF_SMTP_TEST = '1'.
  3. Run Invoke-Pester normally.

.NOTES
ConvertFrom-DpapiString is mocked -- the fixture supplies the password
as plaintext so no DPAPI context is required.

The suite uses InModuleScope so Send-Mail and ConvertFrom-DpapiString
are both resolved inside the PipeDFe module without needing -ModuleName.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSAvoidUsingConvertToSecureStringWithPlainText',
    '',
    Justification = 'Plaintext password is acceptable in an explicitly opt-in integration-test fixture.'
)]

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSReviewUnusedParameter',
    'Value',
    Justification = 'Required by ConvertFrom-DpapiString'
)]

param ()

# InModuleScope needs to resolve the PipeDFe module during the Discovery phase,
# because that's when Context/It are executed to register the test tree. If the
# module isn't loaded at that point, InModuleScope fails before any BeforeAll or
# BeforeEach ever runs.
BeforeDiscovery {
    $moduleRoot = (Get-Item $PSScriptRoot).Parent.Parent.Parent.Parent.FullName

    $moduleName = [System.IO.Path]::Combine($moduleRoot, 'PipeDFe.psd1')

    Import-Module -Name $moduleName -Force -Global -ErrorAction Stop

    $Script:SmtpSecretsPath = [System.IO.Path]::Combine(
        (Get-Item -LiteralPath $PSScriptRoot).Parent.Parent.Parent.FullName,
        'Fixtures',
        'smtp-secrets.json'
    )

    $Script:SmtpIntegrationEnabled = (
        $env:PIPEDF_SMTP_TEST -eq '1' -and
        (Test-Path -LiteralPath $Script:SmtpSecretsPath -PathType Leaf)
    )
}

Describe 'Send-Mail' -Tag 'Integration' -Skip:(-not $Script:SmtpIntegrationEnabled) {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            $secretsPath = [System.IO.Path]::Combine(
                (Get-Item -LiteralPath $PSScriptRoot).Parent.Parent.Parent.FullName,
                'Fixtures',
                'smtp-secrets.json'
            )

            $secrets = Get-Content -LiteralPath $secretsPath -Raw |
                ConvertFrom-Json

            $requiredProperties = @(
                'Server'
                'Port'
                'Ssl'
                'Username'
                'Password'
                'Timeout'
                'From'
                'To'
            )

            foreach ($property in $requiredProperties) {
                if ($null -eq $secrets.PSObject.Properties[$property]) {
                    throw "SMTP fixture is missing required property '$property'."
                }
            }

            $requiredFromProperties = @('Name', 'Email')

            foreach ($property in $requiredFromProperties) {
                if ($null -eq $secrets.From.PSObject.Properties[$property]) {
                    throw "SMTP fixture is missing required property 'From.$property'."
                }
            }

            $validations = @(
                @{
                    Value = [string]$secrets.Server
                    Label = 'Server'
                }
                @{
                    Value = [string]$secrets.Username;
                    Label = 'Username'
                }
                @{
                    Value = [string]$secrets.Password;
                    Label = 'Password'
                }
                @{
                    Value = [string]$secrets.From.Email
                    Label = 'From.Email'
                }
                @{
                    Value = [string]$secrets.To
                    Label = 'To'
                }
            )

            foreach ($validation in $validations) {
                if ([string]::IsNullOrWhiteSpace($validation.Value)) {
                    throw "SMTP fixture property '$($validation.Label)' must not be empty."
                }
            }

            if ([int]$secrets.Port -lt 1 -or [int]$secrets.Port -gt 65535) {
                throw "SMTP fixture property 'Port' must be between 1 and 65535."
            }

            if ([int]$secrets.Timeout -le 0) {
                throw "SMTP fixture property 'Timeout' must be greater than zero."
            }

            $Script:SmtpConfig = [PSCustomObject]@{
                Server   = [string]$secrets.Server
                Port     = [int]$secrets.Port
                Ssl      = [bool]$secrets.Ssl
                Username = [string]$secrets.Username
                Password = 'mocked-not-used'
                Timeout  = [int]$secrets.Timeout
                From     = [PSCustomObject]@{
                    Name  = [string]$secrets.From.Name
                    Email = [string]$secrets.From.Email
                }
            }

            $Script:PlaintextPassword = [string]$secrets.Password

            $Script:ToRecipient = @(
                [PSCustomObject]@{
                    Name  = 'PipeDFe Teste'
                    Email = [string]$secrets.To
                }
            )
        }

        BeforeEach {

            $plaintext = $Script:PlaintextPassword

            Mock -CommandName ConvertFrom-DpapiString -MockWith {
                param (
                    [Parameter()]
                    [string]$Value
                )

                ConvertTo-SecureString -String $plaintext -AsPlainText -Force
            }
        }

        #region Happy path
        Context 'Happy path' {

            It 'Returns Success = true after delivering the message' {

                $sendParams = @{
                    SmtpConfig = $Script:SmtpConfig
                    To         = $Script:ToRecipient
                    Subject    = '[PipeDFe] Integration test - ignore'
                    Body       = '<p>Automated integration test. You can ignore this message.</p>'
                }

                $result = Send-Mail @sendParams

                $result.Success | Should -BeTrue
                $result.Error   | Should -BeNullOrEmpty
            }

            It 'Returns the To address in EmailsSent' {

                $sendParams = @{
                    SmtpConfig = $Script:SmtpConfig
                    To         = $Script:ToRecipient
                    Subject    = '[PipeDFe] Integration test - recipient - ignore'
                    Body       = '<p>Automated integration test. You can ignore this message.</p>'
                }

                $result = Send-Mail @sendParams

                $result.Success    | Should -BeTrue
                $result.EmailsSent | Should -Contain ([string]$Script:ToRecipient[0].Email)
            }
        }
        #endregion

        #region From without display name
        Context 'From without display name' {

            It 'Delivers successfully when From.Name is blank' {

                $smtpNoName = [PSCustomObject]@{
                    Server   = $Script:SmtpConfig.Server
                    Port     = $Script:SmtpConfig.Port
                    Ssl      = $Script:SmtpConfig.Ssl
                    Username = $Script:SmtpConfig.Username
                    Password = 'mocked-not-used'
                    Timeout  = $Script:SmtpConfig.Timeout
                    From     = [PSCustomObject]@{
                        Name  = [string]::Empty
                        Email = $Script:SmtpConfig.From.Email
                    }
                }

                $sendParams = @{
                    SmtpConfig = $smtpNoName
                    To         = $Script:ToRecipient
                    Subject    = '[PipeDFe] Integration test - no display name - ignore'
                    Body       = '<p>Automated integration test without a display name.</p>'
                }

                $result = Send-Mail @sendParams

                $result.Success | Should -BeTrue
                $result.Error   | Should -BeNullOrEmpty
            }
        }
        #endregion

        #region Attachment handling
        Context 'Attachment handling' {

            BeforeAll {

                $plaintext = $Script:PlaintextPassword

                Mock -CommandName ConvertFrom-DpapiString -MockWith {
                    param (
                        [Parameter()]
                        [string]$Value
                    )

                    ConvertTo-SecureString -String $plaintext -AsPlainText -Force
                }

                $Script:AttachmentPath = [System.IO.Path]::Combine(
                    [System.IO.Path]::GetTempPath(),
                    'PipeDFe-attach-test.txt'
                )

                [System.IO.File]::WriteAllText(
                    $Script:AttachmentPath,
                    'PipeDFe attachment integration test.'
                )
            }

            AfterAll {

                $removeParams = @{
                    LiteralPath = $Script:AttachmentPath
                    Force       = $true
                    ErrorAction = 'SilentlyContinue'
                }

                Remove-Item @removeParams
            }

            It 'Delivers successfully with a valid attachment' {

                $sendParams = @{
                    SmtpConfig  = $Script:SmtpConfig
                    To          = $Script:ToRecipient
                    Subject     = '[PipeDFe] Integration test - attachment - ignore'
                    Body        = '<p>Automated integration test with attachment.</p>'
                    Attachments = @($Script:AttachmentPath)
                }

                $result = Send-Mail @sendParams

                $result.Success | Should -BeTrue
                $result.Error   | Should -BeNullOrEmpty
            }

            It 'Skips a missing attachment and still delivers' {

                $missingPath = [System.IO.Path]::Combine(
                    [System.IO.Path]::GetTempPath(),
                    'PipeDFe-nonexistent-attachment.zip'
                )

                $sendParams = @{
                    SmtpConfig  = $Script:SmtpConfig
                    To          = $Script:ToRecipient
                    Subject     = '[PipeDFe] Integration test - missing attachment - ignore'
                    Body        = '<p>Automated integration test with missing attachment.</p>'
                    Attachments = @($missingPath)
                }

                $result = Send-Mail @sendParams

                $result.Success | Should -BeTrue
                $result.Error   | Should -BeNullOrEmpty
            }
        }
        #endregion
    }
}
