#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for Test-Cnpj.

.DESCRIPTION
Coverage includes:
  - Value and Ambiente are mandatory.
  - Ambiente is typed as the Ambiente enum.
  - Returns true for a valid numeric CNPJ in Producao.
  - Returns false for an invalid check digit in Producao.
  - Returns false for all-same-character sequences.
  - Returns false for structurally invalid CNPJs.
  - Returns false when normalization rejects the input.
  - Returns false when check digits are non-numeric.
  - Returns true for a valid alphanumeric CNPJ (RFB 2026) in Producao.
  - Accepts lowercase input through normalization.
  - Accepts formatted CNPJs.
  - Returns true for structurally valid CNPJs in Homologacao
    without checking digits.
  - Returns false for structurally invalid CNPJs in Homologacao.
  - Accepts pipeline input.
  - Processes multiple values from the pipeline.
  - Returns a bool.
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

Describe 'Test-Cnpj' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            $Script:Command = Get-Command -Name Test-Cnpj -ErrorAction Stop

            # Known valid numeric CNPJs.
            $Script:ValidNumericOne = '11222333000181'
            $Script:ValidNumericTwo = '12345678000195'

            # Known valid alphanumeric CNPJ (RFB 2026).
            $Script:ValidAlphanumeric = '12ABC34501DE35'

            # Known invalid CNPJ with incorrect check digit.
            $Script:InvalidCheckDigit = '11222333000182'
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

            It 'Declares Ambiente as mandatory' {
                $mandatory = $Script:Command.Parameters['Ambiente'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.Mandatory
                    }

                $mandatory | Should -Not -BeNullOrEmpty
            }

            It 'Declares Ambiente as Ambiente enum' {
                $Script:Command.Parameters['Ambiente'].ParameterType |
                    Should -Be ([Ambiente])
            }

            It 'Rejects a null Value' {
                { Test-Cnpj -Value $null -Ambiente Producao } |
                    Should -Throw
            }

            It 'Rejects an empty Value' {
                { Test-Cnpj -Value '' -Ambiente Producao } |
                    Should -Throw
            }
        }
        #endregion

        #region Producao validation
        Context 'Producao validation' {

            It 'Returns true for a valid numeric CNPJ' {
                $result = Test-Cnpj -Value $Script:ValidNumericOne -Ambiente Producao
                $result | Should -BeTrue
            }

            It 'Returns false for a CNPJ with an invalid check digit' {
                $result = Test-Cnpj -Value $Script:InvalidCheckDigit -Ambiente Producao
                $result | Should -BeFalse
            }

            It 'Returns true for a valid alphanumeric CNPJ' {
                $result = Test-Cnpj -Value $Script:ValidAlphanumeric -Ambiente Producao
                $result | Should -BeTrue
            }

            It 'Accepts lowercase alphanumeric input through normalization' {
                $result = Test-Cnpj -Value '12abc34501de35' -Ambiente Producao
                $result | Should -BeTrue
            }

            It 'Accepts a formatted numeric CNPJ' {
                $result = Test-Cnpj -Value '11.222.333/0001-81' -Ambiente Producao
                $result | Should -BeTrue
            }

            It 'Accepts a formatted alphanumeric CNPJ' {
                $result = Test-Cnpj -Value '12.ABC.345/01DE-35' -Ambiente Producao
                $result | Should -BeTrue
            }

            It 'Returns false for an all-zeros CNPJ' {
                $result = Test-Cnpj -Value '00000000000000' -Ambiente Producao
                $result | Should -BeFalse
            }

            It 'Returns false for an all-same-character sequence' {
                $result = Test-Cnpj -Value '11111111111111' -Ambiente Producao
                $result | Should -BeFalse
            }

            It 'Returns false for an alphanumeric all-same-character sequence' {
                $result = Test-Cnpj -Value 'AAAAAAAAAAAAAA' -Ambiente Producao
                $result | Should -BeFalse
            }

            It 'Returns false for a CNPJ shorter than 14 characters' {
                $result = Test-Cnpj -Value '1234567800019' -Ambiente Producao
                $result | Should -BeFalse
            }

            It 'Returns false for a CNPJ longer than 14 characters' {
                $result = Test-Cnpj -Value '123456780001990' -Ambiente Producao
                $result | Should -BeFalse
            }

            It 'Returns false when check digits are non-numeric' {
                $result = Test-Cnpj -Value '112223330001AB' -Ambiente Producao
                $result | Should -BeFalse
            }

            It 'Returns false for unsupported characters' {
                $result = Test-Cnpj -Value '12ABC34501D_35' -Ambiente Producao
                $result | Should -BeFalse
            }

            It 'Returns false when normalization produces an invalid length' {
                $result = Test-Cnpj -Value '12.345.678/0001' -Ambiente Producao
                $result | Should -BeFalse
            }

            It 'Returns a bool' {
                $result = Test-Cnpj -Value $Script:ValidNumericOne -Ambiente Producao
                $result | Should -BeOfType [bool]
            }
        }
        #endregion

        #region Homologacao validation
        Context 'Homologacao validation' {

            It 'Returns true for a structurally valid CNPJ with invalid check digits' {
                $result = Test-Cnpj -Value $Script:InvalidCheckDigit -Ambiente Homologacao
                $result | Should -BeTrue
            }

            It 'Returns true for a valid numeric CNPJ' {
                $result = Test-Cnpj -Value $Script:ValidNumericOne -Ambiente Homologacao
                $result | Should -BeTrue
            }

            It 'Returns true for a structurally valid alphanumeric CNPJ' {
                $result = Test-Cnpj -Value $Script:ValidAlphanumeric -Ambiente Homologacao
                $result | Should -BeTrue
            }

            It 'Returns true for a structurally valid CNPJ with non-matching check digits' {
                $result = Test-Cnpj -Value '12ABC34501DE99' -Ambiente Homologacao
                $result | Should -BeTrue
            }

            It 'Returns false for a CNPJ shorter than 14 characters' {
                $result = Test-Cnpj -Value '1234567800019' -Ambiente Homologacao
                $result | Should -BeFalse
            }

            It 'Returns false for a CNPJ longer than 14 characters' {
                $result = Test-Cnpj -Value '123456780001990' -Ambiente Homologacao
                $result | Should -BeFalse
            }

            It 'Returns false for an all-same-character sequence' {
                $result = Test-Cnpj -Value '00000000000000' -Ambiente Homologacao
                $result | Should -BeFalse
            }

            It 'Returns false for unsupported characters' {
                $result = Test-Cnpj -Value '12ABC34501D_35' -Ambiente Homologacao
                $result | Should -BeFalse
            }
        }
        #endregion

        #region Pipeline support
        Context 'Pipeline support' {

            It 'Accepts Value from the pipeline' {
                $result = $Script:ValidNumericOne |Test-Cnpj -Ambiente Producao
                $result | Should -BeTrue
            }

            It 'Accepts formatted Value from the pipeline' {
                $result = '11.222.333/0001-81' |Test-Cnpj -Ambiente Producao
                $result | Should -BeTrue
            }

            It 'Processes multiple values from the pipeline' {
                $results = @($Script:ValidNumericOne, $Script:ValidNumericTwo) |
                    Test-Cnpj -Ambiente Producao

                $results | Should -HaveCount 2
                $results[0] | Should -BeTrue
                $results[1] | Should -BeTrue
            }

            It 'Processes multiple mixed-validity values from the pipeline' {
                $results = @($Script:ValidNumericOne, $Script:InvalidCheckDigit) |
                    Test-Cnpj -Ambiente Producao

                $results | Should -HaveCount 2
                $results[0] | Should -BeTrue
                $results[1] | Should -BeFalse
            }
        }
        #endregion
    }
}
