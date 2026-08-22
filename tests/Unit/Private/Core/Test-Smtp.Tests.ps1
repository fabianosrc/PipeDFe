#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for Test-Smtp.

.DESCRIPTION
Validates the public contract of Test-Smtp, including:

  - Mandatory and non-null InputObject parameter.
  - Fully valid SMTP configurations.
  - Missing and unsupported schema versions.
  - Missing, empty, and invalid server values.
  - Missing and out-of-range ports.
  - Missing, empty, and invalid username values.
  - Missing and empty password values.
  - Missing and out-of-range timeout values.
  - Optional From, SenderAddress, and ReplyTo fields.
  - Invalid address structures and empty Email values.
  - Accumulation of multiple validation errors.
  - Stable output structure and types.

The tests validate observable behavior rather than implementation details.

.NOTES
The test suite intentionally exercises malformed configuration objects to
ensure Test-Smtp reports validation errors instead of throwing unexpectedly.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseShouldProcessForStateChangingFunctions',
    '',
    Justification = 'Test infrastructure helpers do not ship as module functions.'
)]

param ()

# InModuleScope needs to resolve the PipeDFe module during the Discovery phase,
# because that is when Context/It are executed to register the test tree.
# If the module isn't loaded at that point, InModuleScope fails before any
# BeforeAll or BeforeEach can run.
BeforeDiscovery {
    $moduleRoot = (Get-Item $PSScriptRoot).Parent.Parent.Parent.Parent.FullName

    $moduleName = Join-Path -Path $moduleRoot -ChildPath 'PipeDFe.psd1'

    Import-Module -Name $moduleName -Force -Global -ErrorAction Stop
}

Describe 'Test-Smtp' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            $Script:Command = Get-Command -Name Test-Smtp -ErrorAction Stop

            function New-ValidSmtpConfig {
                [PSCustomObject]@{
                    SchemaVersion = $Script:SmtpSchemaVersion
                    Server        = 'smtp.office365.com'
                    Port          = 587
                    Ssl           = $true
                    Username      = 'user@domain.com'
                    Password      = 'encrypted-blob'
                    From          = [PSCustomObject]@{
                        Name  = 'PipeDFe'
                        Email = 'noreply@domain.com'
                    }
                    SenderAddress = $null
                    ReplyTo       = $null
                    Timeout       = 30
                    CreatedAt     = '2026-08-01T00:00:00+00:00'
                    UpdatedAt     = '2026-08-01T00:00:00+00:00'
                }
            }
        }

        #region Parameter contract
        Context 'Parameter contract' {

            It 'Declares InputObject as mandatory' {
                $mandatory = $Script:Command.Parameters['InputObject'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.Mandatory
                    }

                $mandatory | Should -Not -BeNullOrEmpty
            }

            It 'Rejects null InputObject' {
                { Test-Smtp -InputObject $null } |
                    Should -Throw
            }
        }
        #endregion

        #region Valid configuration
        Context 'Valid configuration' {

            It 'Returns a valid result for a fully valid configuration' {
                $result = Test-Smtp -InputObject (New-ValidSmtpConfig)

                $result.IsValid | Should -BeTrue
                $result.Errors  | Should -HaveCount 0
            }

            It 'Accepts the minimum valid port value' {
                $config = New-ValidSmtpConfig
                $config.Port = 1

                $result = Test-Smtp -InputObject $config

                $result.IsValid | Should -BeTrue
                $result.Errors  | Should -HaveCount 0
            }

            It 'Accepts the maximum valid port value' {
                $config = New-ValidSmtpConfig
                $config.Port = 65535

                $result = Test-Smtp -InputObject $config

                $result.IsValid | Should -BeTrue
                $result.Errors  | Should -HaveCount 0
            }

            It 'Accepts the minimum valid timeout value' {
                $config = New-ValidSmtpConfig
                $config.Timeout = 1

                $result = Test-Smtp -InputObject $config

                $result.IsValid | Should -BeTrue
                $result.Errors  | Should -HaveCount 0
            }

            It 'Accepts the maximum valid timeout value' {
                $config = New-ValidSmtpConfig
                $config.Timeout = 120

                $result = Test-Smtp -InputObject $config

                $result.IsValid | Should -BeTrue
                $result.Errors  | Should -HaveCount 0
            }
        }
        #endregion

        #region SchemaVersion validation
        Context 'SchemaVersion validation' {

            It 'Returns an error when SchemaVersion is absent' {
                $config = New-ValidSmtpConfig
                $config.PSObject.Properties.Remove('SchemaVersion')

                $result = Test-Smtp -InputObject $config

                $result.IsValid | Should -BeFalse
                $result.Errors  | Should -Contain 'SchemaVersion property is required.'
            }

            It 'Returns an error when SchemaVersion is unsupported' {
                $config = New-ValidSmtpConfig
                $config.SchemaVersion = 999

                $result = Test-Smtp -InputObject $config

                $result.IsValid | Should -BeFalse
                $result.Errors  | Should -Contain (
                    "Unsupported SMTP schema version '999'. " +
                    "Expected '$($Script:SmtpSchemaVersion)'."
                )
            }
        }
        #endregion

        #region Server validation
        Context 'Server validation' {

            It 'Returns an error when Server is absent' {
                $config = New-ValidSmtpConfig
                $config.PSObject.Properties.Remove('Server')

                $result = Test-Smtp -InputObject $config

                $result.IsValid | Should -BeFalse
                $result.Errors  | Should -Contain 'SMTP server is required.'
            }

            It 'Returns an error when Server is empty' {
                $config = New-ValidSmtpConfig
                $config.Server = ''

                $result = Test-Smtp -InputObject $config

                $result.IsValid | Should -BeFalse
                $result.Errors  | Should -Contain 'SMTP server is required.'
            }

            It 'Returns an error when Server contains only whitespace' {
                $config = New-ValidSmtpConfig
                $config.Server = '   '

                $result = Test-Smtp -InputObject $config

                $result.IsValid | Should -BeFalse
                $result.Errors  | Should -Contain 'SMTP server is required.'
            }
        }
        #endregion

        #region Port validation
        Context 'Port validation' {

            It 'Returns an error when Port is absent' {
                $config = New-ValidSmtpConfig
                $config.PSObject.Properties.Remove('Port')

                $result = Test-Smtp -InputObject $config

                $result.IsValid | Should -BeFalse
                $result.Errors  | Should -Contain 'SMTP port must be between 1 and 65535.'
            }

            It 'Returns an error when Port is zero' {
                $config = New-ValidSmtpConfig
                $config.Port = 0

                $result = Test-Smtp -InputObject $config

                $result.IsValid | Should -BeFalse
                $result.Errors  | Should -Contain 'SMTP port must be between 1 and 65535.'
            }

            It 'Returns an error when Port is below the valid range' {
                $config = New-ValidSmtpConfig
                $config.Port = -1

                $result = Test-Smtp -InputObject $config

                $result.IsValid | Should -BeFalse
                $result.Errors  | Should -Contain 'SMTP port must be between 1 and 65535.'
            }

            It 'Returns an error when Port is above the valid range' {
                $config = New-ValidSmtpConfig
                $config.Port = 65536

                $result = Test-Smtp -InputObject $config

                $result.IsValid | Should -BeFalse
                $result.Errors  | Should -Contain 'SMTP port must be between 1 and 65535.'
            }

            It 'Returns an error when Port has an invalid type' {
                $config = New-ValidSmtpConfig
                $config.Port = 'invalid'

                $result = Test-Smtp -InputObject $config

                $result.IsValid | Should -BeFalse
                $result.Errors  | Should -Contain 'SMTP port must be between 1 and 65535.'
            }
        }
        #endregion

        #region Username validation
        Context 'Username validation' {

            It 'Returns an error when Username is absent' {
                $config = New-ValidSmtpConfig
                $config.PSObject.Properties.Remove('Username')

                $result = Test-Smtp -InputObject $config

                $result.IsValid | Should -BeFalse
                $result.Errors  | Should -Contain 'SMTP username is required.'
            }

            It 'Returns an error when Username is empty' {
                $config = New-ValidSmtpConfig
                $config.Username = ''

                $result = Test-Smtp -InputObject $config

                $result.IsValid | Should -BeFalse
                $result.Errors  | Should -Contain 'SMTP username is required.'
            }

            It 'Returns an error when Username contains only whitespace' {
                $config = New-ValidSmtpConfig
                $config.Username = '   '

                $result = Test-Smtp -InputObject $config

                $result.IsValid | Should -BeFalse
                $result.Errors  | Should -Contain 'SMTP username is required.'
            }
        }
        #endregion

        #region Password validation
        Context 'Password validation' {

            It 'Returns an error when Password is absent' {
                $config = New-ValidSmtpConfig
                $config.PSObject.Properties.Remove('Password')

                $result = Test-Smtp -InputObject $config

                $result.IsValid | Should -BeFalse
                $result.Errors  | Should -Contain 'SMTP password is required.'
            }

            It 'Returns an error when Password is empty' {
                $config = New-ValidSmtpConfig
                $config.Password = ''

                $result = Test-Smtp -InputObject $config

                $result.IsValid | Should -BeFalse
                $result.Errors  | Should -Contain 'SMTP password is required.'
            }

            It 'Returns an error when Password contains only whitespace' {
                $config = New-ValidSmtpConfig
                $config.Password = '   '

                $result = Test-Smtp -InputObject $config

                $result.IsValid | Should -BeFalse
                $result.Errors  | Should -Contain 'SMTP password is required.'
            }
        }
        #endregion

        #region Timeout validation
        Context 'Timeout validation' {

            It 'Returns an error when Timeout is absent' {
                $config = New-ValidSmtpConfig
                $config.PSObject.Properties.Remove('Timeout')

                $result = Test-Smtp -InputObject $config

                $result.IsValid | Should -BeFalse
                $result.Errors  | Should -Contain 'SMTP timeout must be between 1 and 120 seconds.'
            }

            It 'Returns an error when Timeout is zero' {
                $config = New-ValidSmtpConfig
                $config.Timeout = 0

                $result = Test-Smtp -InputObject $config

                $result.IsValid | Should -BeFalse
                $result.Errors  | Should -Contain 'SMTP timeout must be between 1 and 120 seconds.'
            }

            It 'Returns an error when Timeout is below the valid range' {
                $config = New-ValidSmtpConfig
                $config.Timeout = -1

                $result = Test-Smtp -InputObject $config

                $result.IsValid | Should -BeFalse
                $result.Errors  | Should -Contain 'SMTP timeout must be between 1 and 120 seconds.'
            }

            It 'Returns an error when Timeout is above the valid range' {
                $config = New-ValidSmtpConfig
                $config.Timeout = 121

                $result = Test-Smtp -InputObject $config

                $result.IsValid | Should -BeFalse
                $result.Errors  | Should -Contain 'SMTP timeout must be between 1 and 120 seconds.'
            }

            It 'Returns an error when Timeout has an invalid type' {
                $config = New-ValidSmtpConfig
                $config.Timeout = 'invalid'

                $result = Test-Smtp -InputObject $config

                $result.IsValid | Should -BeFalse
                $result.Errors  | Should -Contain 'SMTP timeout must be between 1 and 120 seconds.'
            }
        }
        #endregion

        #region Address validation
        Context 'Address validation' {

            It 'Accepts a valid From address' {
                $result = Test-Smtp -InputObject (New-ValidSmtpConfig)

                $result.IsValid | Should -BeTrue
            }

            It 'Returns an error when From has no Email property' {
                $config = New-ValidSmtpConfig
                $config.From = [PSCustomObject]@{
                    Name = 'PipeDFe'
                }

                $result = Test-Smtp -InputObject $config

                $result.IsValid | Should -BeFalse
                $result.Errors  | Should -Contain 'From must contain an Email value.'
            }

            It 'Returns an error when From Email is empty' {
                $config = New-ValidSmtpConfig
                $config.From = [PSCustomObject]@{
                    Name  = 'PipeDFe'
                    Email = ''
                }

                $result = Test-Smtp -InputObject $config

                $result.IsValid | Should -BeFalse
                $result.Errors  | Should -Contain 'From must contain an Email value.'
            }

            It 'Accepts a null SenderAddress' {
                $config = New-ValidSmtpConfig
                $config.SenderAddress = $null

                $result = Test-Smtp -InputObject $config

                $result.IsValid | Should -BeTrue
            }

            It 'Accepts an absent SenderAddress' {
                $config = New-ValidSmtpConfig
                $config.PSObject.Properties.Remove('SenderAddress')

                $result = Test-Smtp -InputObject $config

                $result.IsValid | Should -BeTrue
            }

            It 'Returns an error when SenderAddress has no Email property' {
                $config = New-ValidSmtpConfig
                $config.SenderAddress = [PSCustomObject]@{
                    Name = 'Sender'
                }

                $result = Test-Smtp -InputObject $config

                $result.IsValid | Should -BeFalse
                $result.Errors  | Should -Contain 'SenderAddress must contain an Email value.'
            }

            It 'Returns an error when SenderAddress Email is empty' {
                $config = New-ValidSmtpConfig
                $config.SenderAddress = [PSCustomObject]@{
                    Name  = 'Sender'
                    Email = ''
                }

                $result = Test-Smtp -InputObject $config

                $result.IsValid | Should -BeFalse
                $result.Errors  | Should -Contain 'SenderAddress must contain an Email value.'
            }

            It 'Accepts a null ReplyTo' {
                $config = New-ValidSmtpConfig
                $config.ReplyTo = $null

                $result = Test-Smtp -InputObject $config

                $result.IsValid | Should -BeTrue
            }

            It 'Returns an error when ReplyTo has no Email property' {
                $config = New-ValidSmtpConfig
                $config.ReplyTo = [PSCustomObject]@{
                    Name = 'Reply'
                }

                $result = Test-Smtp -InputObject $config

                $result.IsValid | Should -BeFalse
                $result.Errors  | Should -Contain 'ReplyTo must contain an Email value.'
            }

            It 'Returns an error when ReplyTo Email is empty' {
                $config = New-ValidSmtpConfig
                $config.ReplyTo = [PSCustomObject]@{
                    Name  = 'Reply'
                    Email = ''
                }

                $result = Test-Smtp -InputObject $config

                $result.IsValid | Should -BeFalse
                $result.Errors  | Should -Contain 'ReplyTo must contain an Email value.'
            }
        }
        #endregion

        #region Error accumulation
        Context 'Error accumulation' {

            It 'Accumulates all validation errors' {
                $config = New-ValidSmtpConfig
                $config.Server   = ''
                $config.Username = ''
                $config.Password = ''
                $config.Port     = 0
                $config.Timeout  = 0

                $result = Test-Smtp -InputObject $config

                $result.IsValid | Should -BeFalse
                $result.Errors | Should -HaveCount 5
                $result.Errors | Should -Contain 'SMTP server is required.'
                $result.Errors | Should -Contain 'SMTP port must be between 1 and 65535.'
                $result.Errors | Should -Contain 'SMTP username is required.'
                $result.Errors | Should -Contain 'SMTP password is required.'
                $result.Errors | Should -Contain 'SMTP timeout must be between 1 and 120 seconds.'
            }
        }
        #endregion

        #region Output contract
        Context 'Output contract' {

            It 'Returns a PSCustomObject' {
                $result = Test-Smtp -InputObject (New-ValidSmtpConfig)

                $result | Should -BeOfType [System.Management.Automation.PSCustomObject]
            }

            It 'Exposes IsValid as bool' {
                $result = Test-Smtp -InputObject (New-ValidSmtpConfig)

                $result.IsValid | Should -BeOfType [bool]
            }

            It 'Exposes Errors as a string array' {
                $result = Test-Smtp -InputObject (New-ValidSmtpConfig)

                $result.PSObject.Properties['Errors'].Value.GetType() |
                    Should -Be ([string[]])
            }

            It 'Exposes exactly the expected result properties' {
                $result = Test-Smtp -InputObject (New-ValidSmtpConfig)

                @($result.PSObject.Properties.Name) |
                    Should -Be @('IsValid', 'Errors')
            }
        }
        #endregion
    }
}
