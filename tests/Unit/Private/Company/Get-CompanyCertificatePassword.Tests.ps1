#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for Get-CompanyCertificatePassword.

.DESCRIPTION
Covers all behaviors of Get-CompanyCertificatePassword:
  - Returns null when company has no Certificado block.
  - Returns null when EncryptedPassword is null.
  - Returns null when EncryptedPassword is empty or whitespace.
  - Delegates decryption to ConvertFrom-DpapiString.
  - Returns the SecureString produced by ConvertFrom-DpapiString.
#>

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

Describe 'Get-CompanyCertificatePassword' {

    InModuleScope PipeDFe {

        BeforeAll {

            $Script:SecurePassword = [System.Security.SecureString]::new()

            'P@ssw0rd'.ToCharArray() |
                ForEach-Object { $Script:SecurePassword.AppendChar($_) }

            Mock -CommandName ConvertFrom-DpapiString -MockWith {
                $Script:SecurePassword
            }
        }

        #region No certificate configured
        Context 'No certificate configured' {

            It 'Returns null when Certificado block is null' {
                $company = [PSCustomObject]@{ Certificado = $null }

                $result = Get-CompanyCertificatePassword -Company $company

                $result | Should -BeNull
            }

            It 'Returns null when EncryptedPassword is null' {
                $company = [PSCustomObject]@{
                    Certificado = [PSCustomObject]@{
                        EncryptedPassword = $null
                    }
                }

                $result = Get-CompanyCertificatePassword -Company $company

                $result | Should -BeNull
            }

            It 'Returns null when EncryptedPassword is empty' {
                $company = [PSCustomObject]@{
                    Certificado = [PSCustomObject]@{
                        EncryptedPassword = [string]::Empty
                    }
                }

                $result = Get-CompanyCertificatePassword -Company $company

                $result | Should -BeNull
            }

            It 'Returns null when EncryptedPassword is whitespace' {
                $company = [PSCustomObject]@{
                    Certificado = [PSCustomObject]@{
                        EncryptedPassword = '   '
                    }
                }

                $result = Get-CompanyCertificatePassword -Company $company

                $result | Should -BeNull
            }

            It 'Does not call ConvertFrom-DpapiString when no certificate is configured' {
                $company = [PSCustomObject]@{
                    Certificado = $null
                }

                Get-CompanyCertificatePassword -Company $company

                Should -Invoke -CommandName ConvertFrom-DpapiString -Times 0 -Exactly
            }
        }
        #endregion

        #region Certificate configured
        Context 'Certificate configured' {

            BeforeAll {

                Mock -CommandName ConvertFrom-DpapiString -MockWith {
                    $Script:SecurePassword
                }

                $Script:CompanyWithCert = [PSCustomObject]@{
                    Certificado = [PSCustomObject]@{
                        EncryptedPassword = 'dpapi-blob'
                    }
                }

                $Script:CertResult = Get-CompanyCertificatePassword -Company $Script:CompanyWithCert
            }

            It 'Calls ConvertFrom-DpapiString with the encrypted blob' {
                Mock -CommandName ConvertFrom-DpapiString -MockWith {
                    $Script:SecurePassword
                }

                Get-CompanyCertificatePassword -Company $Script:CompanyWithCert

                Should -Invoke -CommandName ConvertFrom-DpapiString -Times 1 -Exactly -ParameterFilter {
                    $Value -eq 'dpapi-blob'
                }
            }

            It 'Returns the SecureString from ConvertFrom-DpapiString' {
                $Script:CertResult | Should -Be $Script:SecurePassword
            }

            It 'Returns a SecureString' {
                $Script:CertResult | Should -BeOfType [System.Security.SecureString]
            }
        }
        #endregion
    }
}
