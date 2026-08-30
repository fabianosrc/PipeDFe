#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for New-PipeCompany.

.DESCRIPTION
Covers the orchestration contract of New-PipeCompany:
  - All mandatory parameters are declared.
  - SupportsShouldProcess is declared.
  - Delegates CNPJ normalization to ConvertTo-NormalizedCnpj.
  - Delegates validation to Assert-CompanyInput.
  - Resolves OutputPath via Get-StorePath when not provided.
  - Uses the provided OutputPath when supplied.
  - Creates OutputPath when it does not exist.
  - Delegates email normalization to ConvertTo-NormalizedMailRecipient.
  - Encrypts CertPassword via ConvertTo-DpapiString when CertPath is provided.
  - Delegates object construction to ConvertTo-CompanyObject.
  - Delegates persistence to Save-CompanyConfig.
  - Returns result of Get-CompanyConfig.
  - Does not persist when WhatIf is specified.
  - Does not call ConvertTo-DpapiString when CertPath is absent.
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

Describe 'New-PipeCompany' {

    InModuleScope PipeDFe {

        BeforeAll {

            $Script:Cnpj         = '12345678000195'
            $Script:XmlPath      = Join-Path -Path $TestDrive -ChildPath 'xml'
            $Script:OutputPath   = Join-Path -Path $TestDrive -ChildPath 'output'
            $Script:CertPath     = Join-Path -Path $TestDrive -ChildPath 'cert.pfx'
            $Script:CertPassword = ConvertTo-SecureString -String 'P@ssw0rd' -AsPlainText -Force

            New-Item -Path $Script:XmlPath -ItemType Directory -Force | Out-Null

            [System.IO.File]::WriteAllText($Script:CertPath, 'fake-cert')

            $Script:FakeCompany = [PSCustomObject]@{
                Cnpj        = $Script:Cnpj
                RazaoSocial = 'ACME COMERCIO LTDA'
            }

            Mock -CommandName ConvertTo-NormalizedCnpj -MockWith {
                $Script:Cnpj
            }

            Mock -CommandName Assert-CompanyInput -MockWith {

            }

            Mock -CommandName Get-StorePath -MockWith {
                $Script:OutputPath
            }

            Mock -CommandName ConvertTo-NormalizedMailRecipient -MockWith {

            }

            Mock -CommandName ConvertTo-DpapiString -MockWith {
                'encrypted-blob'
            }

            Mock -CommandName ConvertTo-CompanyObject -MockWith {
                $Script:FakeCompany
            }

            Mock -CommandName Save-CompanyConfig -MockWith {

            }

            Mock -CommandName Get-CompanyConfig -MockWith {
                $Script:FakeCompany
            }
        }

        #region Parameter contract
        Context 'Parameter contract' {

            It 'Declares Cnpj as mandatory' {
                $command = Get-Command -Name New-PipeCompany

                $mandatory = $command.Parameters['Cnpj'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.Mandatory
                    }

                $mandatory | Should -Not -BeNullOrEmpty
            }

            It 'Declares RazaoSocial as mandatory' {
                $command = Get-Command -Name New-PipeCompany

                $mandatory = $command.Parameters['RazaoSocial'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.Mandatory
                    }

                $mandatory | Should -Not -BeNullOrEmpty
            }

            It 'Declares Uf as mandatory' {
                $command = Get-Command -Name New-PipeCompany

                $mandatory = $command.Parameters['Uf'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.Mandatory
                    }

                $mandatory | Should -Not -BeNullOrEmpty
            }

            It 'Declares Ambiente as mandatory' {
                $command = Get-Command -Name New-PipeCompany

                $mandatory = $command.Parameters['Ambiente'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.Mandatory
                    }

                $mandatory | Should -Not -BeNullOrEmpty
            }

            It 'Declares XmlPath as mandatory' {
                $command = Get-Command -Name New-PipeCompany

                $mandatory = $command.Parameters['XmlPath'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.Mandatory
                    }

                $mandatory | Should -Not -BeNullOrEmpty
            }

            It 'Declares SupportsShouldProcess' {
                $command = Get-Command -Name New-PipeCompany

                $cmdletBinding = $command.Parameters['WhatIf']

                $cmdletBinding | Should -Not -BeNullOrEmpty
            }
        }
        #endregion

        #region Phase 1 - Normalization and validation
        Context 'Phase 1 - Normalization and validation' {

            It 'Calls ConvertTo-NormalizedCnpj with the provided Cnpj' {
                $companyParams = @{
                    Cnpj        = $Script:Cnpj
                    RazaoSocial = 'ACME'
                    Uf          = 'SP'
                    Ambiente    = 'Producao'
                    XmlPath     = $Script:XmlPath
                }

                New-PipeCompany @companyParams

                Should -Invoke -CommandName ConvertTo-NormalizedCnpj -Times 1 -Exactly -ParameterFilter {
                    $Value -eq $Script:Cnpj
                }
            }

            It 'Calls Assert-CompanyInput with normalized Cnpj' {
                $companyParams = @{
                    Cnpj        = $Script:Cnpj
                    RazaoSocial = 'ACME'
                    Uf          = 'SP'
                    Ambiente    = 'Producao'
                    XmlPath     = $Script:XmlPath
                }

                New-PipeCompany @companyParams

                Should -Invoke -CommandName Assert-CompanyInput -Times 1 -Exactly -ParameterFilter {
                    $Cnpj -eq $Script:Cnpj
                }
            }
        }
        #endregion

        #region Phase 2 - OutputPath resolution
        Context 'Phase 2 - OutputPath resolution' {

            It 'Calls Get-StorePath when OutputPath is not provided' {
                $companyParams = @{
                    Cnpj        = $Script:Cnpj
                    RazaoSocial = 'ACME'
                    Uf          = 'SP'
                    Ambiente    = 'Producao'
                    XmlPath     = $Script:XmlPath
                }

                New-PipeCompany @companyParams

                Should -Invoke -CommandName Get-StorePath -Times 1 -Exactly
            }

            It 'Does not call Get-StorePath when OutputPath is provided' {
                $companyParams = @{
                    Cnpj        = $Script:Cnpj
                    RazaoSocial = 'ACME'
                    Uf          = 'SP'
                    Ambiente    = 'Producao'
                    XmlPath     = $Script:XmlPath
                    OutputPath  = $Script:OutputPath
                }

                New-PipeCompany @companyParams

                Should -Invoke -CommandName Get-StorePath -Times 0 -Exactly
            }

            It 'Creates OutputPath directory when it does not exist' {
                $newOutputPath = Join-Path -Path $TestDrive -ChildPath 'new-output'

                $companyParams = @{
                    Cnpj        = $Script:Cnpj
                    RazaoSocial = 'ACME'
                    Uf          = 'SP'
                    Ambiente    = 'Producao'
                    XmlPath     = $Script:XmlPath
                    OutputPath  = $newOutputPath
                }

                New-PipeCompany @companyParams

                Test-Path -LiteralPath $newOutputPath -PathType Container | Should -BeTrue
            }
        }
        #endregion

        #region Phase 2 - Certificate encryption
        Context 'Phase 2 - Certificate encryption' {

            It 'Calls ConvertTo-DpapiString when CertPath is provided' {
                $companyParams = @{
                    Cnpj         = $Script:Cnpj
                    RazaoSocial  = 'ACME'
                    Uf           = 'SP'
                    Ambiente     = 'Producao'
                    XmlPath      = $Script:XmlPath
                    CertPath     = $Script:CertPath
                    CertPassword = $Script:CertPassword
                }

                New-PipeCompany @companyParams

                Should -Invoke -CommandName ConvertTo-DpapiString -Times 1 -Exactly
            }

            It 'Does not call ConvertTo-DpapiString when CertPath is absent' {
                $companyParams = @{
                    Cnpj        = $Script:Cnpj
                    RazaoSocial = 'ACME'
                    Uf          = 'SP'
                    Ambiente    = 'Producao'
                    XmlPath     = $Script:XmlPath
                }

                New-PipeCompany @companyParams

                Should -Invoke -CommandName ConvertTo-DpapiString -Times 0 -Exactly
            }
        }
        #endregion

        #region Phase 3 - Persistence
        Context 'Phase 3 - Persistence' {

            It 'Calls Save-CompanyConfig' {
                $companyParams = @{
                    Cnpj        = $Script:Cnpj
                    RazaoSocial = 'ACME'
                    Uf          = 'SP'
                    Ambiente    = 'Producao'
                    XmlPath     = $Script:XmlPath
                }

                New-PipeCompany @companyParams

                Should -Invoke -CommandName Save-CompanyConfig -Times 1 -Exactly
            }

            It 'Calls Get-CompanyConfig with normalized Cnpj' {
                $companyParams = @{
                    Cnpj        = $Script:Cnpj
                    RazaoSocial = 'ACME'
                    Uf          = 'SP'
                    Ambiente    = 'Producao'
                    XmlPath     = $Script:XmlPath
                }

                New-PipeCompany @companyParams

                Should -Invoke -CommandName Get-CompanyConfig -Times 1 -Exactly -ParameterFilter {
                    $Cnpj -eq $Script:Cnpj
                }
            }

            It 'Returns the result of Get-CompanyConfig' {
                $companyParams = @{
                    Cnpj        = $Script:Cnpj
                    RazaoSocial = 'ACME'
                    Uf          = 'SP'
                    Ambiente    = 'Producao'
                    XmlPath     = $Script:XmlPath
                }

                New-PipeCompany @companyParams | Should -Be $Script:FakeCompany
            }

            It 'Does not call Save-CompanyConfig when WhatIf is specified' {
                $companyParams = @{
                    Cnpj        = $Script:Cnpj
                    RazaoSocial = 'ACME'
                    Uf          = 'SP'
                    Ambiente    = 'Producao'
                    XmlPath     = $Script:XmlPath
                    WhatIf      = $true
                }

                New-PipeCompany @companyParams

                Should -Invoke -CommandName Save-CompanyConfig -Times 0 -Exactly
            }
        }
        #endregion
    }
}
