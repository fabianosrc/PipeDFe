#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for ConvertTo-DpapiString.

.DESCRIPTION
Verifies that ConvertTo-DpapiString delegates to ConvertFrom-SecureString
and wraps failures in a structured terminating error.

Coverage includes:
  - Value is mandatory.
  - Value rejects null.
  - Returns the encrypted string produced by ConvertFrom-SecureString.
  - Throws DpapiEncryptFailed when ConvertFrom-SecureString fails.
  - DpapiEncryptFailed uses SecurityError category.
  - DpapiEncryptFailed preserves the original exception.
  - DpapiEncryptFailed exposes the SecureString as TargetObject.
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

Describe 'ConvertTo-DpapiString' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            $Script:Command       = Get-Command -Name ConvertTo-DpapiString -ErrorAction Stop
            $Script:SecureValue   = ConvertTo-SecureString -String 'vgqTHH9Gyci9UG' -AsPlainText -Force
            $Script:EncryptedBlob = 'encrypted-blob-placeholder'
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

            It 'Declares Value as SecureString' {
                $Script:Command.Parameters['Value'].ParameterType |
                    Should -Be ([securestring])
            }

            It 'Rejects a null Value' {
                { ConvertTo-DpapiString -Value $null } | Should -Throw
            }
        }
        #endregion

        #region Successful encryption
        Context 'Successful encryption' {

            It 'Returns the encrypted string from ConvertFrom-SecureString' {
                Mock -CommandName ConvertFrom-SecureString -MockWith {
                    $Script:EncryptedBlob
                }

                $result = ConvertTo-DpapiString -Value $Script:SecureValue

                $result | Should -Be $Script:EncryptedBlob
            }

            It 'Returns a string' {
                Mock -CommandName ConvertFrom-SecureString -MockWith {
                    $Script:EncryptedBlob
                }

                $result = ConvertTo-DpapiString -Value $Script:SecureValue

                $result | Should -BeOfType [string]
            }

            It 'Passes the SecureString to ConvertFrom-SecureString' {
                Mock -CommandName ConvertFrom-SecureString -MockWith {
                    $Script:EncryptedBlob
                }

                ConvertTo-DpapiString -Value $Script:SecureValue

                Should -Invoke -CommandName ConvertFrom-SecureString -Times 1 -Exactly
            }
        }
        #endregion

        #region Encryption failure
        Context 'Encryption failure' {

            BeforeAll {

                $Script:OriginalException = [System.Exception]::new('DPAPI unavailable.')

                Mock -CommandName ConvertFrom-SecureString -MockWith {
                    throw $Script:OriginalException
                }

                $Script:Thrown = $null

                try {
                    ConvertTo-DpapiString -Value $Script:SecureValue -ErrorAction Stop
                } catch {
                    $Script:Thrown = $_
                }
            }

            It 'Throws DpapiEncryptFailed' {
                $Script:Thrown | Should -Not -BeNullOrEmpty
                $Script:Thrown.FullyQualifiedErrorId | Should -BeLike 'DpapiEncryptFailed*'
            }

            It 'Uses SecurityError category' {
                $Script:Thrown.CategoryInfo.Category |
                    Should -Be ([System.Management.Automation.ErrorCategory]::SecurityError)
            }

            It 'Preserves the original exception' {
                $Script:Thrown.Exception.Message |
                    Should -Be $Script:OriginalException.Message
            }

            It 'Exposes the SecureString as TargetObject' {
                $Script:Thrown.TargetObject | Should -Be $Script:SecureValue
            }
        }
        #endregion
    }
}
