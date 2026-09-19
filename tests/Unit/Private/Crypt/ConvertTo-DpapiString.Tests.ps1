#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for ConvertTo-DpapiString.

.DESCRIPTION
Covers parameter contract, machine-scoped encryption output,
round-trip decryption via ConvertFrom-DpapiString, and invalid input.
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

Describe 'ConvertTo-DpapiString' -Tag 'Unit' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            $secureParams = @{
                String      = 'PipeDFe-Test-Secret-123!'
                AsPlainText = $true
                Force       = $true
            }

            $Script:SecureValue = ConvertTo-SecureString @secureParams
            $Script:PlainText   = 'PipeDFe-Test-Secret-123!'
        }

        #region Parameter contract
        Context 'Parameter contract' {

            It 'Declares SecureString as mandatory' {
                $command = Get-Command -Name ConvertTo-DpapiString

                $mandatory = $command.Parameters['SecureString'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.Mandatory
                    }

                $mandatory | Should -Not -BeNullOrEmpty
            }

            It 'Declares SecureString as SecureString type' {
                $command = Get-Command -Name ConvertTo-DpapiString

                $command.Parameters['SecureString'].ParameterType |
                    Should -Be ([System.Security.SecureString])
            }

            It 'Rejects a null SecureString' {
                { ConvertTo-DpapiString -SecureString $null } | Should -Throw
            }
        }
        #endregion

        #region Machine-scoped encryption
        Context 'Machine-scoped encryption' {

            It 'Returns a non-empty string' {
                $result = ConvertTo-DpapiString -SecureString $Script:SecureValue

                $result | Should -Not -BeNullOrEmpty
                $result | Should -BeOfType [string]
            }

            It 'Uses the explicit machine DPAPI prefix' {
                $result = ConvertTo-DpapiString -SecureString $Script:SecureValue

                $result | Should -Match '^DPAPI-MACHINE:.+'
            }

            It 'Does not return the plaintext password' {
                $result = ConvertTo-DpapiString -SecureString $Script:SecureValue

                $result | Should -Not -Be $Script:PlainText
                $result | Should -Not -Match [regex]::Escape($Script:PlainText)
            }

            It 'Can be decrypted by ConvertFrom-DpapiString' {
                $encrypted = ConvertTo-DpapiString -SecureString $Script:SecureValue

                $decrypted = ConvertFrom-DpapiString -Value $encrypted

                $credential = [System.Net.NetworkCredential]::new(
                    [string]::Empty,
                    $decrypted
                )

                $credential.Password | Should -Be $Script:PlainText
            }
        }
        #endregion
    }
}
