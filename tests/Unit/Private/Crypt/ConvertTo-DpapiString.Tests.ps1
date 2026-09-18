#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for ConvertTo-DpapiString.

.DESCRIPTION
Verifies that ConvertTo-DpapiString delegates to ConvertFrom-SecureString
and wraps failures in a structured terminating error.

Coverage includes:
  - SecureString is mandatory.
  - SecureString rejects null.
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

            $Script:Command = Get-Command -Name ConvertTo-DpapiString -ErrorAction Stop

            $secureStringParams = @{
                String      = 'vgqTHH9Gyci9UG'
                AsPlainText = $true
                Force       = $true
            }

            $Script:SecureValue = ConvertTo-SecureString @secureStringParams

            $Script:EncryptedBlob = 'encrypted-blob-placeholder'
        }

        AfterAll {

            Remove-Module -Name PipeDFe -Force -ErrorAction SilentlyContinue
        }

        #region Parameter contract
        Context 'Parameter contract' {

            It 'Declares SecureString as mandatory' {
                $mandatory = $Script:Command.Parameters['SecureString'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.Mandatory
                    }

                $mandatory | Should -Not -BeNullOrEmpty
            }

            It 'Declares SecureString as SecureString type' {
                $Script:Command.Parameters['SecureString'].ParameterType |
                    Should -Be ([securestring])
            }

            It 'Rejects a null SecureString' {
                { ConvertTo-DpapiString -SecureString $null } | Should -Throw
            }
        }
        #endregion

        #region Successful encryption
        Context 'Successful encryption' {

            BeforeEach {

                Mock -CommandName ConvertFrom-SecureString -MockWith {
                    return $Script:EncryptedBlob
                }
            }

            It 'Returns the encrypted string from ConvertFrom-SecureString' {
                $result = ConvertTo-DpapiString -SecureString $Script:SecureValue

                $result | Should -Be $Script:EncryptedBlob
            }

            It 'Returns a string' {
                $result = ConvertTo-DpapiString -SecureString $Script:SecureValue

                $result | Should -BeOfType [string]
            }

            It 'Calls ConvertFrom-SecureString exactly once' {
                ConvertTo-DpapiString -SecureString $Script:SecureValue | Out-Null

                $invokeParams = @{
                    CommandName = 'ConvertFrom-SecureString'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'It'
                    Exactly     = $true
                    Times       = 1
                }

                Should -Invoke @invokeParams
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
                    ConvertTo-DpapiString -SecureString $Script:SecureValue -ErrorAction Stop
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
                $Script:Thrown.Exception.InnerException.Message |
                    Should -Be $Script:OriginalException.Message
            }

            It 'Exposes the SecureString as TargetObject' {
                $Script:Thrown.TargetObject | Should -Be $Script:SecureValue
            }
        }
        #endregion

        #region Successful encryption
        Context 'Successful encryption' {

            BeforeEach {

                Mock -CommandName ConvertFrom-SecureString -MockWith {
                    return $Script:EncryptedBlob
                }
            }

            It 'Returns the encrypted string from ConvertFrom-SecureString' {
                $result = ConvertTo-DpapiString -SecureString $Script:SecureValue

                $result | Should -Be $Script:EncryptedBlob
            }

            It 'Returns a string' {
                $result = ConvertTo-DpapiString -SecureString $Script:SecureValue

                $result | Should -BeOfType [string]
            }

            It 'Calls ConvertFrom-SecureString exactly once' {
                ConvertTo-DpapiString -SecureString $Script:SecureValue | Out-Null

                $invokeParams = @{
                    CommandName = 'ConvertFrom-SecureString'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'It'
                    Exactly     = $true
                    Times       = 1
                }

                Should -Invoke @invokeParams
            }

            It 'Throws DpapiEncryptFailed when ConvertFrom-SecureString returns empty' {
                Mock -CommandName ConvertFrom-SecureString -MockWith {
                    return [string]::Empty
                }

                try {
                    ConvertTo-DpapiString -SecureString $Script:SecureValue -ErrorAction Stop
                    throw 'Expected ConvertTo-DpapiString to fail.'
                } catch {
                    $_.FullyQualifiedErrorId | Should -BeLike 'DpapiEncryptFailed*'
                }
            }

            It 'Throws DpapiEncryptFailed when ConvertFrom-SecureString returns whitespace' {
                Mock -CommandName ConvertFrom-SecureString -MockWith {
                    return '   '
                }

                try {
                    ConvertTo-DpapiString -SecureString $Script:SecureValue -ErrorAction Stop
                    throw 'Expected ConvertTo-DpapiString to fail.'
                } catch {
                    $_.FullyQualifiedErrorId | Should -BeLike 'DpapiEncryptFailed*'
                }
            }
        }
        #endregion
    }
}
