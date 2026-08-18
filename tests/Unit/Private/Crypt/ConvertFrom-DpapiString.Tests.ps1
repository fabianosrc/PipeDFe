#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for ConvertFrom-DpapiString.

.DESCRIPTION
Verifies that ConvertFrom-DpapiString delegates to ConvertTo-SecureString
and wraps failures in a structured terminating error.

Coverage includes:
  - Value is mandatory.
  - Value rejects null and empty string.
  - Returns the SecureString produced by ConvertTo-SecureString.
  - Returns a SecureString instance.
  - Throws DpapiDecryptFailed when ConvertTo-SecureString fails.
  - DpapiDecryptFailed uses SecurityError category.
  - DpapiDecryptFailed preserves the original exception.
  - DpapiDecryptFailed exposes the encrypted string as TargetObject.
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
    $moduleRoot = (Get-Item $PSScriptRoot).Parent.Parent.Parent.Parent.FullName

    $moduleName = Join-Path -Path $moduleRoot -ChildPath 'PipeDFe.psd1'

    Import-Module -Name $moduleName -Force -Global -ErrorAction Stop
}

Describe 'ConvertFrom-DpapiString' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            $Script:Command        = Get-Command -Name ConvertFrom-DpapiString -ErrorAction Stop
            $Script:EncryptedBlob  = 'encrypted-blob-placeholder'
            $Script:ExpectedSecure = ConvertTo-SecureString -String 'vgqTHH9Gyci9UG' -AsPlainText -Force
        }

        #region Parameter contract
        Context 'Parameter contract' {

            It 'Declares Value as mandatory' {
                $mandatory = $Script:Command.Parameters['Value'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.Mandatory
                    }

                $mandatory | Should -Not -BeNullOrEmpty
            }

            It 'Declares Value as string' {
                $Script:Command.Parameters['Value'].ParameterType | Should -Be ([string])
            }

            It 'Rejects a null Value' {
                { ConvertFrom-DpapiString -Value $null } | Should -Throw
            }

            It 'Rejects an empty Value' {
                { ConvertFrom-DpapiString -Value '' } | Should -Throw
            }
        }
        #endregion

        #region Successful decryption
        Context 'Successful decryption' {

            It 'Returns the SecureString from ConvertTo-SecureString' {
                Mock -CommandName ConvertTo-SecureString -MockWith {
                    $Script:ExpectedSecure
                }

                $result = ConvertFrom-DpapiString -Value $Script:EncryptedBlob

                $result | Should -Be $Script:ExpectedSecure
            }

            It 'Returns a SecureString' {
                Mock -CommandName ConvertTo-SecureString -MockWith {
                    $Script:ExpectedSecure
                }

                $result = ConvertFrom-DpapiString -Value $Script:EncryptedBlob

                $result | Should -BeOfType [System.Security.SecureString]
            }

            It 'Passes the encrypted string to ConvertTo-SecureString' {
                Mock -CommandName ConvertTo-SecureString -MockWith {
                    $Script:ExpectedSecure
                }

                ConvertFrom-DpapiString -Value $Script:EncryptedBlob

                Should -Invoke -CommandName ConvertTo-SecureString -Times 1 -Exactly
            }
        }
        #endregion

        #region Decryption failure
        Context 'Decryption failure' {

            BeforeAll {
                $Script:OriginalException = [System.Exception]::new('DPAPI unavailable.')

                Mock -CommandName ConvertTo-SecureString -MockWith {
                    throw $Script:OriginalException
                }

                $Script:Thrown = $null

                try {
                    ConvertFrom-DpapiString -Value $Script:EncryptedBlob -ErrorAction Stop
                } catch {
                    $Script:Thrown = $_
                }
            }

            It 'Throws DpapiDecryptFailed' {
                $Script:Thrown | Should -Not -BeNullOrEmpty
                $Script:Thrown.FullyQualifiedErrorId | Should -BeLike 'DpapiDecryptFailed*'
            }

            It 'Uses SecurityError category' {
                $Script:Thrown.CategoryInfo.Category |
                    Should -Be ([System.Management.Automation.ErrorCategory]::SecurityError)
            }

            It 'Preserves the original exception' {
                $Script:Thrown.Exception.Message |
                    Should -Be $Script:OriginalException.Message
            }

            It 'Exposes the encrypted string as TargetObject' {
                $Script:Thrown.TargetObject | Should -Be $Script:EncryptedBlob
            }
        }
        #endregion
    }
}
