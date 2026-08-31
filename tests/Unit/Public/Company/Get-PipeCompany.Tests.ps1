#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for Get-PipeCompany.

.DESCRIPTION
Covers the retrieval contract of Get-PipeCompany:
  - Returns a single company when Cnpj is provided.
  - Normalizes Cnpj before lookup.
  - Does not call ConvertTo-NormalizedCnpj when Cnpj is omitted.
  - Returns all companies when Cnpj is omitted.
  - Filters by IsActive when provided.
  - Does not filter by IsActive when omitted.
  - Propagates CompanyNotFound from Get-CompanyConfig.
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

Describe 'Get-PipeCompany' {

    InModuleScope PipeDFe {

        BeforeAll {

            $Script:Cnpj = '12345678000195'

            $Script:CompanyActive = [PSCustomObject]@{
                Cnpj        = $Script:Cnpj
                RazaoSocial = 'ACME COMERCIO LTDA'
                IsActive    = $true
            }

            $Script:CompanyInactive = [PSCustomObject]@{
                Cnpj        = '98765432000100'
                RazaoSocial = 'BETA INDUSTRIA LTDA'
                IsActive    = $false
            }

            Mock -CommandName ConvertTo-NormalizedCnpj -MockWith {
                $Script:Cnpj
            }

            Mock -CommandName Get-CompanyConfig -MockWith {
                $Script:CompanyActive
            } -ParameterFilter {
                -not [string]::IsNullOrWhiteSpace($Cnpj)
            }

            Mock -CommandName Get-CompanyConfig -MockWith {
                $Script:CompanyActive
                $Script:CompanyInactive
            } -ParameterFilter {
                [string]::IsNullOrWhiteSpace($Cnpj)
            }
        }

        #region Single company retrieval
        Context 'Single company retrieval' {

            It 'Calls ConvertTo-NormalizedCnpj with the provided Cnpj' {
                Get-PipeCompany -Cnpj $Script:Cnpj

                Should -Invoke -CommandName ConvertTo-NormalizedCnpj -Times 1 -Exactly -ParameterFilter {
                    $Value -eq $Script:Cnpj
                }
            }

            It 'Calls Get-CompanyConfig with the normalized Cnpj' {
                Get-PipeCompany -Cnpj $Script:Cnpj

                Should -Invoke -CommandName Get-CompanyConfig -Times 1 -Exactly -ParameterFilter {
                    $Cnpj -eq $Script:Cnpj
                }
            }

            It 'Returns the matching company' {
                $result = Get-PipeCompany -Cnpj $Script:Cnpj
                $result.Cnpj | Should -Be $Script:Cnpj
            }
        }
        #endregion

        #region Bulk retrieval
        Context 'Bulk retrieval' {

            It 'Does not call ConvertTo-NormalizedCnpj when Cnpj is omitted' {
                Get-PipeCompany

                Should -Invoke -CommandName ConvertTo-NormalizedCnpj -Times 0 -Exactly
            }

            It 'Calls Get-CompanyConfig without Cnpj' {
                Get-PipeCompany

                Should -Invoke -CommandName Get-CompanyConfig -Times 1 -Exactly
            }

            It 'Returns all companies' {
                $results = @(Get-PipeCompany)
                $results | Should -HaveCount 2
            }
        }
        #endregion

        #region IsActive filter
        Context 'IsActive filter' {

            It 'Returns only active companies when IsActive is true' {
                $results = @(Get-PipeCompany -IsActive $true)
                $results | Should -HaveCount 1
                $results[0].IsActive | Should -BeTrue
            }

            It 'Returns only inactive companies when IsActive is false' {
                $results = @(Get-PipeCompany -IsActive $false)
                $results | Should -HaveCount 1
                $results[0].IsActive | Should -BeFalse
            }

            It 'Does not filter when IsActive is omitted' {
                $results = @(Get-PipeCompany)
                $results | Should -HaveCount 2
            }

            It 'Returns empty when no company matches IsActive filter' {
                $results = @(Get-PipeCompany -Cnpj $Script:Cnpj -IsActive $false)
                $results | Should -HaveCount 0
            }
        }
        #endregion

        #region Error propagation
        Context 'Error propagation' {

            It 'Propagates CompanyNotFound from Get-CompanyConfig' {
                Mock -CommandName Get-CompanyConfig -MockWith {
                    $PSCmdlet.ThrowTerminatingError(
                        [System.Management.Automation.ErrorRecord]::new(
                            [System.IO.FileNotFoundException]::new('Company not found.'),
                            'CompanyNotFound',
                            [System.Management.Automation.ErrorCategory]::ObjectNotFound,
                            '99999999000191'
                        )
                    )
                } -ParameterFilter {
                    $Cnpj -eq '99999999000191'
                }

                Mock -CommandName ConvertTo-NormalizedCnpj -MockWith { '99999999000191' }

                { Get-PipeCompany -Cnpj '99999999000191' } |
                    Should -Throw -ErrorId 'CompanyNotFound*'
            }
        }
        #endregion
    }
}
