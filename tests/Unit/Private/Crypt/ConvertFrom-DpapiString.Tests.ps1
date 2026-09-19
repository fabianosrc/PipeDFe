#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for ConvertFrom-DpapiString.

.DESCRIPTION
Verifies that ConvertFrom-DpapiString decrypts machine-scoped DPAPI values,
preserves compatibility with legacy DPAPI values, and wraps decryption
failures in a structured terminating error.

Coverage includes:
  - Value is mandatory.
  - Value rejects null and empty string.
  - Machine-scoped values use the DPAPI-MACHINE prefix.
  - Machine-scoped values are decrypted into a SecureString.
  - Machine-scoped values support a successful round trip.
  - Legacy DPAPI values remain supported.
  - DpapiDecryptFailed is raised when decryption fails.
  - DpapiDecryptFailed uses SecurityError category.
  - DpapiDecryptFailed preserves the original exception.
  - DpapiDecryptFailed exposes the encrypted string as TargetObject.
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

Describe 'ConvertFrom-DpapiString' -Tag 'Unit' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            $secureParams = @{
                String      = 'PipeDFe-Test-Secret-123!'
                AsPlainText = $true
                Force       = $true
            }

            $Script:ExpectedSecure = ConvertTo-SecureString @secureParams
            $Script:EncryptedBlob  = 'encrypted-blob-placeholder'
        }

        #region Parameter contract
        Context 'Parameter contract' {

            It 'Declares Value as mandatory' {
                $command = Get-Command -Name ConvertFrom-DpapiString

                $mandatory = $command.Parameters['Value'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.Mandatory
                    }

                $mandatory | Should -Not -BeNullOrEmpty
            }

            It 'Declares Value as string' {
                $command = Get-Command -Name ConvertFrom-DpapiString

                $command.Parameters['Value'].ParameterType | Should -Be ([string])
            }

            It 'Rejects a null Value' {
                { ConvertFrom-DpapiString -Value $null } | Should -Throw
            }

            It 'Rejects an empty Value' {
                { ConvertFrom-DpapiString -Value '' } | Should -Throw
            }
        }
        #endregion

        #region Machine-scoped decryption
        Context 'Machine-scoped decryption' {

            BeforeEach {

                $Script:MachineEncryptedValue = $null

                if ($Script:IsWindowsPlatform) {
                    $expected = @{ SecureString = $Script:ExpectedSecure }

                    $Script:MachineEncryptedValue = ConvertTo-DpapiString @expected
                }
            }

            It 'Prefixes the encrypted value with DPAPI-MACHINE' -Skip:(
                -not $Script:IsWindowsPlatform
            ) {
                $Script:MachineEncryptedValue | Should -BeLike 'DPAPI-MACHINE:*'
            }

            It 'Returns a SecureString' -Skip:(-not $Script:IsWindowsPlatform) {
                $result = ConvertFrom-DpapiString -Value $Script:MachineEncryptedValue

                $result | Should -BeOfType [System.Security.SecureString]
            }

            It 'Successfully decrypts a machine-scoped value' -Skip:(
                -not $Script:IsWindowsPlatform
            ) {
                $result = ConvertFrom-DpapiString -Value $Script:MachineEncryptedValue

                $plainText = [System.Net.NetworkCredential]::new(
                    [string]::Empty,
                    $result
                ).Password

                $plainText | Should -Be 'PipeDFe-Test-Secret-123!'
            }
        }
        #endregion

        #region Legacy decryption
        Context 'Legacy decryption' {

            It 'Supports a legacy DPAPI value' {
                Mock -CommandName ConvertTo-SecureString -MockWith {
                    $Script:ExpectedSecure
                }

                $result = ConvertFrom-DpapiString -Value $Script:EncryptedBlob

                $result | Should -Be $Script:ExpectedSecure
            }

            It 'Returns a SecureString for a legacy value' {
                Mock -CommandName ConvertTo-SecureString -MockWith {
                    $Script:ExpectedSecure
                }

                $result = ConvertFrom-DpapiString -Value $Script:EncryptedBlob

                $result | Should -BeOfType [System.Security.SecureString]
            }

            It 'Passes the legacy value to ConvertTo-SecureString exactly once' {
                Mock -CommandName ConvertTo-SecureString -MockWith {
                    $Script:ExpectedSecure
                }

                ConvertFrom-DpapiString -Value $Script:EncryptedBlob | Out-Null

                $invokeParams = @{
                    CommandName = 'ConvertTo-SecureString'
                    Scope       = 'It'
                    Exactly     = $true
                    Times       = 1
                }

                Should -Invoke @invokeParams
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
                $expected = [System.Management.Automation.ErrorCategory]::SecurityError

                $Script:Thrown.CategoryInfo.Category | Should -Be $expected
            }

            It 'Preserves the original exception' {
                $Script:Thrown.Exception.InnerException | Should -Be $Script:OriginalException
            }

            It 'Exposes the encrypted string as TargetObject' {
                $Script:Thrown.TargetObject | Should -Be $Script:EncryptedBlob
            }
        }
        #endregion
    }
}
