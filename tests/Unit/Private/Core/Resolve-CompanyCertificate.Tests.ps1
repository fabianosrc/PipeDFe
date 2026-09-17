#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for Resolve-CompanyCertificate.

.DESCRIPTION
Covers parameter contract, early return when CertPath is absent,
error on missing certificate file, password forwarding behavior,
and output contract.

.NOTES
Private dependencies mocked: Test-Path, Invoke-CertificateSetup.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSAvoidUsingConvertToSecureStringWithPlainText',
    '',
    Justification = 'Plain text passwords are acceptable in test context.'
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

Describe 'Resolve-CompanyCertificate' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            $Script:Command = Get-Command -Name Resolve-CompanyCertificate -ErrorAction Stop

            $Script:FakePath              = 'C:\Certs\company.pfx'
            $Script:FakeEncryptedPassword = 'encrypted-password-value'

            $Script:ExistingWithCert = [PSCustomObject]@{
                Path              = $Script:FakePath
                EncryptedPassword = $Script:FakeEncryptedPassword
            }
        }

        #region Parameter contract
        Context 'Parameter contract' {

            It 'Declares Bound as mandatory' {
                $mandatory = $Script:Command.Parameters['Bound'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.Mandatory
                    }

                $mandatory | Should -Not -BeNullOrEmpty
            }

            It 'Declares Existing as mandatory' {
                $mandatory = $Script:Command.Parameters['Existing'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.Mandatory
                    }

                $mandatory | Should -Not -BeNullOrEmpty
            }
        }
        #endregion

        #region CertPath absent from Bound
        Context 'CertPath absent from Bound - no Existing' {

            BeforeAll {

                $resolveParams = @{
                    Bound    = @{}
                    Existing = $null
                }

                $Script:NoExistingResult = Resolve-CompanyCertificate @resolveParams
            }

            It 'Returns a PSCustomObject' {
                $Script:NoExistingResult |
                    Should -BeOfType [System.Management.Automation.PSCustomObject]
            }

            It 'Returns null Path when Existing is null' {
                $Script:NoExistingResult.Path | Should -BeNullOrEmpty
            }

            It 'Returns null EncryptedPassword when Existing is null' {
                $Script:NoExistingResult.EncryptedPassword | Should -BeNullOrEmpty
            }
        }

        Context 'CertPath absent from Bound - with Existing' {

            BeforeAll {

                $resolveParams = @{
                    Bound    = @{}
                    Existing = $Script:ExistingWithCert
                }

                $Script:ExistingResult = Resolve-CompanyCertificate @resolveParams
            }

            It 'Returns the existing Path' {
                $Script:ExistingResult.Path | Should -Be $Script:FakePath
            }

            It 'Returns the existing EncryptedPassword' {
                $Script:ExistingResult.EncryptedPassword |
                    Should -Be $Script:FakeEncryptedPassword
            }
        }
        #endregion

        #region CertPath present - file not found
        Context 'CertPath present - file not found' {

            BeforeAll {

                Mock -CommandName Test-Path -MockWith {
                    return $false
                }

                $Script:NotFoundThrown = $null

                try {
                    $resolveParams = @{
                        Bound    = @{ CertPath = $Script:FakePath }
                        CertPath = $Script:FakePath
                        Existing = $null
                    }

                    Resolve-CompanyCertificate @resolveParams -ErrorAction Stop
                } catch {
                    $Script:NotFoundThrown = $_
                }
            }

            It 'Throws CertNotFound' {
                $Script:NotFoundThrown | Should -Not -BeNullOrEmpty

                $Script:NotFoundThrown.FullyQualifiedErrorId |
                    Should -BeLike 'CertNotFound*'
            }

            It 'Uses ObjectNotFound category' {
                $Script:NotFoundThrown.CategoryInfo.Category |
                    Should -Be ([System.Management.Automation.ErrorCategory]::ObjectNotFound)
            }

            It 'Exposes CertPath as TargetObject' {
                $Script:NotFoundThrown.TargetObject | Should -Be $Script:FakePath
            }
        }
        #endregion

        #region CertPath present - file found, no password
        Context 'CertPath present - file found, no CertPassword in Bound' {

            BeforeAll {

                Mock -CommandName Test-Path -MockWith {
                    return $true
                }

                Mock -CommandName Invoke-CertificateSetup -MockWith {
                    return [PSCustomObject]@{
                        EncryptedPassword = $Script:FakeEncryptedPassword
                    }
                }

                $resolveParams = @{
                    Bound    = @{ CertPath = $Script:FakePath }
                    CertPath = $Script:FakePath
                    Existing = $null
                }

                $Script:NoPwdResult = Resolve-CompanyCertificate @resolveParams
            }

            It 'Returns the supplied CertPath' {
                $Script:NoPwdResult.Path | Should -Be $Script:FakePath
            }

            It 'Returns the EncryptedPassword from Invoke-CertificateSetup' {
                $Script:NoPwdResult.EncryptedPassword |
                    Should -Be $Script:FakeEncryptedPassword
            }

            It 'Calls Invoke-CertificateSetup without Password' {
                $invokeParams = @{
                    CommandName = 'Invoke-CertificateSetup'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'Context'
                    Exactly     = $true
                    Times       = 1
                }

                Should -Invoke @invokeParams
            }
        }
        #endregion

        #region CertPath present - file found, with password
        Context 'CertPath present - file found, CertPassword in Bound' {

            BeforeAll {

                Mock -CommandName Test-Path -MockWith {
                    return $true
                }

                Mock -CommandName Invoke-CertificateSetup -MockWith {
                    return [PSCustomObject]@{
                        EncryptedPassword = $Script:FakeEncryptedPassword
                    }
                }

                $fakePassword = ConvertTo-SecureString -String 'fake' -AsPlainText -Force

                $resolveParams = @{
                    Bound        = @{
                        CertPath     = $Script:FakePath
                        CertPassword = $fakePassword
                    }
                    CertPath     = $Script:FakePath
                    CertPassword = $fakePassword
                    Existing     = $null
                }

                $Script:WithPwdResult = Resolve-CompanyCertificate @resolveParams
            }

            It 'Returns the supplied CertPath' {
                $Script:WithPwdResult.Path | Should -Be $Script:FakePath
            }

            It 'Returns the EncryptedPassword from Invoke-CertificateSetup' {
                $Script:WithPwdResult.EncryptedPassword |
                    Should -Be $Script:FakeEncryptedPassword
            }

            It 'Calls Invoke-CertificateSetup exactly once' {
                $invokeParams = @{
                    CommandName = 'Invoke-CertificateSetup'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'Context'
                    Exactly     = $true
                    Times       = 1
                }

                Should -Invoke @invokeParams
            }
        }
        #endregion

        #region Output contract
        Context 'Output contract' {

            BeforeAll {

                Mock -CommandName Test-Path -MockWith {
                    return $true
                }

                Mock -CommandName Invoke-CertificateSetup -MockWith {
                    return [PSCustomObject]@{
                        EncryptedPassword = $Script:FakeEncryptedPassword
                    }
                }

                $resolveParams = @{
                    Bound    = @{ CertPath = $Script:FakePath }
                    CertPath = $Script:FakePath
                    Existing = $null
                }

                $Script:OutputResult = Resolve-CompanyCertificate @resolveParams
            }

            It 'Returns a PSCustomObject' {
                $Script:OutputResult |
                    Should -BeOfType [System.Management.Automation.PSCustomObject]
            }

            It 'Exposes exactly the documented properties' {
                @($Script:OutputResult.PSObject.Properties.Name) |
                    Should -Be @('Path', 'EncryptedPassword')
            }
        }
        #endregion
    }
}
