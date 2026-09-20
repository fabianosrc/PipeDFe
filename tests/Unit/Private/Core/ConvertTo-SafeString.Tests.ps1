#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for ConvertTo-SafeString.

.DESCRIPTION
Coverage includes:
  - InputObject is not mandatory.
  - InputObject allows null values.
  - InputObject accepts pipeline input.
  - Text and Value are valid aliases for InputObject.
  - Separator is a string parameter.
  - Returns an empty string for null input.
  - Returns an empty string for empty input.
  - Returns an empty string for whitespace-only input.
  - Removes diacritical marks from accented characters.
  - Handles multiple accented characters.
  - Handles cedilla.
  - Preserves valid non-ASCII letters when AsciiOnly is not specified.
  - Removes invalid characters.
  - Preserves ampersand as a valid character.
  - Preserves decimal digits.
  - Returns an empty string when all characters are removed.
  - Replaces whitespace sequences with the default separator.
  - Replaces multiple consecutive whitespace characters with one separator.
  - Trims leading and trailing whitespace.
  - Supports custom separators.
  - Supports multi-character separators.
  - Treats separator values literally during replacement.
  - Removes remaining non-ASCII characters with AsciiOnly.
  - Produces only ASCII output with AsciiOnly.
  - Converts output to uppercase with UpperCase.
  - Applies the specified Culture during uppercase conversion.
  - Supports combining AsciiOnly and UpperCase.
  - Accepts pipeline input.
  - Processes multiple pipeline inputs independently.
  - Produces exactly one string for each non-empty pipeline input.
  - Returns System.String output.
#>

# InModuleScope needs to resolve the PipeDFe module during the Discovery phase,
# because that is when Context/It are executed to register the test tree.
# If the module isn't loaded at that point, InModuleScope fails before any
# BeforeAll or BeforeEach can run.
BeforeDiscovery {
    $moduleRoot = (Get-Item $PSScriptRoot).Parent.Parent.Parent.Parent.FullName

    $modulePath = Join-Path -Path $moduleRoot -ChildPath 'PipeDFe.psd1'

    Import-Module -Name $modulePath -Force -Global -ErrorAction Stop
}

Describe 'ConvertTo-SafeString' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {
            $Script:Command = Get-Command `
                -Name ConvertTo-SafeString `
                -ErrorAction Stop
        }

        #region Parameter contract
        Context 'Parameter contract' {

            It 'Does not declare InputObject as mandatory' {
                $mandatory = $Script:Command.Parameters['InputObject'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.Mandatory
                    }

                $mandatory | Should -BeNullOrEmpty
            }

            It 'Allows null values for InputObject' {
                $allowNull = $Script:Command.Parameters['InputObject'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.AllowNullAttribute]
                    }

                $allowNull | Should -Not -BeNullOrEmpty
            }

            It 'Accepts InputObject from the pipeline' {
                $pipeline = $Script:Command.Parameters['InputObject'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.ValueFromPipeline
                    }

                $pipeline | Should -Not -BeNullOrEmpty
            }

            It 'Declares InputObject as a string parameter' {
                $Script:Command.Parameters['InputObject'].ParameterType |
                    Should -Be ([string])
            }

            It 'Declares Separator as a string parameter' {
                $Script:Command.Parameters['Separator'].ParameterType |
                    Should -Be ([string])
            }

            It 'Accepts Text as an alias for InputObject' {
                $aliases = $Script:Command.Parameters['InputObject'].Aliases

                $aliases | Should -Contain 'Text'
            }

            It 'Accepts Value as an alias for InputObject' {
                $aliases = $Script:Command.Parameters['InputObject'].Aliases

                $aliases | Should -Contain 'Value'
            }
        }
        #endregion

        #region Empty and whitespace input
        Context 'Empty and whitespace input' {

            It 'Returns an empty string for null input' {
                $result = ConvertTo-SafeString -InputObject $null

                $result | Should -Be ([string]::Empty)
            }

            It 'Returns an empty string for empty input' {
                $result = ConvertTo-SafeString -InputObject ''

                $result | Should -Be ([string]::Empty)
            }

            It 'Returns an empty string for whitespace-only input' {
                $result = ConvertTo-SafeString -InputObject '   '

                $result | Should -Be ([string]::Empty)
            }

            It 'Returns an empty string for tab and newline whitespace' {
                $result = ConvertTo-SafeString -InputObject "`t`n`r"

                $result | Should -Be ([string]::Empty)
            }
        }
        #endregion

        #region Diacritics removal
        Context 'Diacritics removal' {

            It 'Removes diacritical marks from accented characters' {
                $result = ConvertTo-SafeString `
                    -InputObject 'Comércio'

                $result | Should -Be 'Comercio'
            }

            It 'Handles multiple accented characters' {
                $result = ConvertTo-SafeString `
                    -InputObject 'João Ação'

                $result | Should -Be 'Joao_Acao'
            }

            It 'Handles cedilla' {
                $result = ConvertTo-SafeString `
                    -InputObject 'Araçatuba'

                $result | Should -Be 'Aracatuba'
            }

            It 'Preserves valid non-ASCII letters when AsciiOnly is not specified' {
                $result = ConvertTo-SafeString `
                    -InputObject 'Женева'

                $result | Should -Be 'Женева'
            }
        }
        #endregion

        #region Invalid character removal
        Context 'Invalid character removal' {

            It 'Removes punctuation and symbols outside the allowed character set' {
                $result = ConvertTo-SafeString `
                    -InputObject 'ABC-123/XYZ:TEST.'

                $result | Should -Be 'ABC123XYZTEST'
            }

            It 'Removes special characters except ampersand' {
                $result = ConvertTo-SafeString `
                    -InputObject 'Empresa! @ # $'

                $result | Should -Be 'Empresa'
            }

            It 'Preserves ampersand as a valid character' {
                $result = ConvertTo-SafeString `
                    -InputObject 'João & Cia'

                $result | Should -Be 'Joao_&_Cia'
            }

            It 'Preserves decimal digits' {
                $result = ConvertTo-SafeString `
                    -InputObject 'Empresa 123'

                $result | Should -Be 'Empresa_123'
            }

            It 'Returns an empty string when all characters are removed' {
                $result = ConvertTo-SafeString `
                    -InputObject '!@#$%^'

                $result | Should -Be ([string]::Empty)
            }
        }
        #endregion

        #region Whitespace handling
        Context 'Whitespace handling' {

            It 'Uses underscore as the default separator' {
                $result = ConvertTo-SafeString `
                    -InputObject 'Empresa Comercio'

                $result | Should -Be 'Empresa_Comercio'
            }

            It 'Replaces multiple consecutive spaces with a single separator' {
                $result = ConvertTo-SafeString `
                    -InputObject 'Empresa  Comercio'

                $result | Should -Be 'Empresa_Comercio'
            }

            It 'Replaces mixed whitespace sequences with a single separator' {
                $result = ConvertTo-SafeString `
                    -InputObject "Empresa`t`tComercio`nLtda"

                $result | Should -Be 'Empresa_Comercio_Ltda'
            }

            It 'Trims leading and trailing whitespace' {
                $result = ConvertTo-SafeString `
                    -InputObject '  Empresa  '

                $result | Should -Be 'Empresa'
            }

            It 'Trims mixed leading and trailing whitespace' {
                $result = ConvertTo-SafeString `
                    -InputObject "`t Empresa Comercio `n"

                $result | Should -Be 'Empresa_Comercio'
            }

            It 'Replaces whitespace with a custom separator' {
                $result = ConvertTo-SafeString `
                    -InputObject 'Empresa Comercio' `
                    -Separator '-'

                $result | Should -Be 'Empresa-Comercio'
            }

            It 'Supports a multi-character separator' {
                $result = ConvertTo-SafeString `
                    -InputObject 'Empresa Comercio' `
                    -Separator '---'

                $result | Should -Be 'Empresa---Comercio'
            }

            It 'Treats separator values literally during replacement' {
                $result = ConvertTo-SafeString `
                    -InputObject 'Empresa Comercio' `
                    -Separator '$&'

                $result | Should -Be 'Empresa$&Comercio'
            }

            It 'Treats a dollar sign separator literally' {
                $result = ConvertTo-SafeString `
                    -InputObject 'Empresa Comercio' `
                    -Separator '$'

                $result | Should -Be 'Empresa$Comercio'
            }
        }
        #endregion

        #region AsciiOnly
        Context 'AsciiOnly' {

            It 'Removes remaining non-ASCII characters when AsciiOnly is set' {
                $result = ConvertTo-SafeString `
                    -InputObject 'Olá € 世界' `
                    -AsciiOnly

                $result | Should -Be 'Ola'
            }

            It 'Returns only ASCII characters when AsciiOnly is set' {
                $result = ConvertTo-SafeString `
                    -InputObject 'Empresa Comércio Ltda' `
                    -AsciiOnly

                $result | Should -Match '^[\x00-\x7F]*$'
            }

            It 'Preserves ASCII characters when AsciiOnly is set' {
                $result = ConvertTo-SafeString `
                    -InputObject 'Empresa 123 & Ltda' `
                    -AsciiOnly

                $result | Should -Be 'Empresa_123_&_Ltda'
            }

            It 'Does not leave orphan separators after removing non-ASCII characters' {
                $result = ConvertTo-SafeString `
                    -InputObject 'Olá 世界' `
                    -AsciiOnly

                $result | Should -Be 'Ola'
            }
        }
        #endregion

        #region UpperCase
        Context 'UpperCase' {

            It 'Converts the result to uppercase when UpperCase is set' {
                $result = ConvertTo-SafeString `
                    -InputObject 'Empresa Comercio' `
                    -UpperCase

                $result | Should -Be 'EMPRESA_COMERCIO'
            }

            It 'Applies the specified Culture during uppercase conversion' {
                $culture = [System.Globalization.CultureInfo]::new('tr-TR')

                $result = ConvertTo-SafeString `
                    -InputObject 'istanbul' `
                    -UpperCase `
                    -Culture $culture

                $result | Should -Be 'İSTANBUL'
            }

            It 'Combines AsciiOnly and UpperCase' {
                $result = ConvertTo-SafeString `
                    -InputObject 'Empresa Comércio Ltda' `
                    -UpperCase `
                    -AsciiOnly

                $result | Should -Be 'EMPRESA_COMERCIO_LTDA'
            }
        }
        #endregion

        #region Pipeline support
        Context 'Pipeline support' {

            It 'Accepts InputObject from the pipeline' {
                $result = 'Empresa Comércio' |
                    ConvertTo-SafeString

                $result | Should -Be 'Empresa_Comercio'
            }

            It 'Processes multiple values from the pipeline independently' {
                $results = @(
                    'Empresa Comércio'
                    'João & Cia'
                ) | ConvertTo-SafeString

                $results | Should -HaveCount 2
                $results[0] | Should -Be 'Empresa_Comercio'
                $results[1] | Should -Be 'Joao_&_Cia'
            }

            It 'Produces exactly one output for each non-empty pipeline input' {
                $inputs = @(
                    'Empresa Comércio'
                    'João'
                    'São Paulo'
                )

                $results = $inputs | ConvertTo-SafeString

                $results | Should -HaveCount $inputs.Count

                foreach ($result in $results) {
                    $result | Should -BeOfType [string]
                }
            }

            It 'Processes empty input independently from direct invocation' {
                $result = ConvertTo-SafeString -InputObject ''

                $result | Should -Be ([string]::Empty)
            }

            It 'Processes null input independently from direct invocation' {
                $result = ConvertTo-SafeString -InputObject $null

                $result | Should -Be ([string]::Empty)
            }

            It 'Processes null, empty and non-empty inputs independently' {
                $results = @(
                    ConvertTo-SafeString -InputObject $null
                    ConvertTo-SafeString -InputObject ''
                    ConvertTo-SafeString -InputObject 'João'
                    ConvertTo-SafeString -InputObject '   '
                    ConvertTo-SafeString -InputObject 'Empresa Comércio'
                )

                $results | Should -HaveCount 5
                $results[0] | Should -Be ([string]::Empty)
                $results[1] | Should -Be ([string]::Empty)
                $results[2] | Should -Be 'Joao'
                $results[3] | Should -Be ([string]::Empty)
                $results[4] | Should -Be 'Empresa_Comercio'
            }
        }
        #endregion

        #region Alias behavior
        Context 'Alias behavior' {

            It 'Accepts Text as an alias for InputObject' {
                $result = ConvertTo-SafeString `
                    -Text 'João Silva'

                $result | Should -Be 'Joao_Silva'
            }

            It 'Accepts Value as an alias for InputObject' {
                $result = ConvertTo-SafeString `
                    -Value 'João Silva'

                $result | Should -Be 'Joao_Silva'
            }
        }
        #endregion

        #region Output contract
        Context 'Output contract' {

            It 'Returns a string for normal input' {
                $result = ConvertTo-SafeString `
                    -InputObject 'Empresa'

                $result | Should -BeOfType [string]
            }

            It 'Returns a string for empty input' {
                $result = ConvertTo-SafeString `
                    -InputObject ''

                $result | Should -BeOfType [string]
            }

            It 'Returns a string for null input' {
                $result = ConvertTo-SafeString `
                    -InputObject $null

                $result | Should -BeOfType [string]
            }

            It 'Returns an empty string when sanitization removes all characters' {
                $result = ConvertTo-SafeString `
                    -InputObject '!@#$%'

                $result | Should -BeOfType [string]
                $result | Should -Be ([string]::Empty)
            }
        }
        #endregion
    }
}
