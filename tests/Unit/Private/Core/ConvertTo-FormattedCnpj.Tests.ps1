#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for ConvertTo-FormattedCnpj.

.DESCRIPTION
Coverage includes:
  - Value is mandatory.
  - Value accepts pipeline input.
  - Value accepts pipeline input by property name.
  - Rejects null and empty values.
  - Rejects values shorter or longer than 14 characters.
  - Rejects lowercase characters.
  - Rejects unsupported characters.
  - Applies the standard XX.XXX.XXX/XXXX-XX mask.
  - Supports numeric CNPJs.
  - Supports alphanumeric CNPJs (RFB 2026).
  - Processes multiple values from the pipeline.
  - Returns a string.
#>

# InModuleScope needs to resolve the PipeDFe module during the Discovery phase,
# because that's when Context/It are executed to register the test tree. If the
# module isn't loaded at that point, InModuleScope fails before any BeforeAll
# or BeforeEach ever runs.
BeforeDiscovery {
    $moduleRoot = (Get-Item $PSScriptRoot).Parent.Parent.Parent.Parent.FullName

    $moduleName = Join-Path -Path $moduleRoot -ChildPath 'PipeDFe.psd1'

    Import-Module -Name $moduleName -Force -Global -ErrorAction Stop
}

Describe 'ConvertTo-FormattedCnpj' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            $Script:Command = Get-Command -Name ConvertTo-FormattedCnpj -ErrorAction Stop
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

            It 'Accepts Value from the pipeline' {
                $pipeline = $Script:Command.Parameters['Value'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.ValueFromPipeline
                    }

                $pipeline | Should -Not -BeNullOrEmpty
            }

            It 'Accepts Value from the pipeline by property name' {
                $pipelineByPropertyName = $Script:Command.Parameters['Value'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.ValueFromPipelineByPropertyName
                    }

                $pipelineByPropertyName | Should -Not -BeNullOrEmpty
            }

            It 'Rejects a null Value' {
                { ConvertTo-FormattedCnpj -Value $null } |
                    Should -Throw
            }

            It 'Rejects an empty Value' {
                { ConvertTo-FormattedCnpj -Value '' } |
                    Should -Throw
            }

            It 'Rejects a value shorter than 14 characters' {
                { ConvertTo-FormattedCnpj -Value '1234567800019' } |
                    Should -Throw
            }

            It 'Rejects a value longer than 14 characters' {
                { ConvertTo-FormattedCnpj -Value '123456780001990' } |
                    Should -Throw
            }

            It 'Rejects lowercase characters' {
                { ConvertTo-FormattedCnpj -Value 'ab1cd2ef3gh4i5' } |
                    Should -Throw
            }

            It 'Rejects unsupported characters' {
                { ConvertTo-FormattedCnpj -Value '12ABC34501D_35' } |
                    Should -Throw
            }
        }
        #endregion

        #region Successful formatting
        Context 'Successful formatting' {

            It 'Applies the standard mask to a numeric CNPJ' {
                $result = ConvertTo-FormattedCnpj -Value '00000000000100'

                $result | Should -Be '00.000.000/0001-00'
            }

            It 'Applies the standard mask to a numeric CNPJ with digits' {
                $result = ConvertTo-FormattedCnpj -Value '12345678000199'

                $result | Should -Be '12.345.678/0001-99'
            }

            It 'Applies the standard mask to an alphanumeric CNPJ (RFB 2026)' {
                $result = ConvertTo-FormattedCnpj -Value 'AB1CD2EF3GH4I5'

                $result | Should -Be 'AB.1CD.2EF/3GH4-I5'
            }

            It 'Returns a string' {
                $result = ConvertTo-FormattedCnpj -Value '12345678000199'

                $result | Should -BeOfType [string]
            }
        }
        #endregion

        #region Pipeline support
        Context 'Pipeline support' {

            It 'Accepts Value from the pipeline' {
                $result = '12345678000199' |
                    ConvertTo-FormattedCnpj

                $result | Should -Be '12.345.678/0001-99'
            }

            It 'Accepts Value from the pipeline by property name' {
                $inputObject = [pscustomobject]@{
                    Value = '12345678000199'
                }

                $result = $inputObject |
                    ConvertTo-FormattedCnpj

                $result | Should -Be '12.345.678/0001-99'
            }

            It 'Processes multiple values from the pipeline' {
                $results = @(
                    '12345678000199'
                    '11222333000181'
                ) | ConvertTo-FormattedCnpj

                $results | Should -HaveCount 2
                $results[0] | Should -Be '12.345.678/0001-99'
                $results[1] | Should -Be '11.222.333/0001-81'
            }
        }
        #endregion
    }
}
