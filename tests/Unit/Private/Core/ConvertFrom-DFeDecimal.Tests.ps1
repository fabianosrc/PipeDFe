#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for ConvertFrom-DFeDecimal.

.DESCRIPTION
Verifies decimal parsing using invariant culture, handling of null/empty/whitespace
input, valid decimal formats, rejection of invalid formats, overflow handling,
and culture independence.

Coverage includes:
  - Value is null.
  - Value is empty.
  - Value is whitespace.
  - Integer values are parsed correctly.
  - Decimal values use invariant culture dot separator.
  - Fiscal decimal precision is preserved.
  - Zero is accepted.
  - Negative values are accepted.
  - Leading and trailing whitespace is trimmed before parsing.
  - Comma as decimal separator is rejected with InvalidDFeDecimal.
  - Arbitrary text is rejected with InvalidDFeDecimal.
  - Thousand separator dot is rejected with InvalidDFeDecimal.
  - Parsing is independent from the current thread culture.
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

Describe 'ConvertFrom-DFeDecimal' -Tag 'Unit' {

    InModuleScope -ModuleName PipeDFe {

        Context 'Valid values' {

            It 'Converts an integer value to Decimal' {
                $result = ConvertFrom-DFeDecimal -Value '100'

                $result | Should -BeOfType [decimal]
                $result | Should -Be ([decimal]100)
            }

            It 'Converts a decimal value using invariant culture' {
                ConvertFrom-DFeDecimal -Value '1234.56' |
                    Should -Be ([decimal]1234.56)
            }

            It 'Preserves fiscal decimal precision' {
                ConvertFrom-DFeDecimal -Value '0.1234567890' |
                    Should -Be ([decimal]0.1234567890)
            }

            It 'Accepts zero' {
                ConvertFrom-DFeDecimal -Value '0.00' |
                    Should -Be ([decimal]0)
            }

            It 'Accepts a negative value' {
                ConvertFrom-DFeDecimal -Value '-1234.56' |
                    Should -Be ([decimal]-1234.56)
            }

            It 'Accepts a positive value with an explicit plus sign' {
                ConvertFrom-DFeDecimal -Value '+1234.56' |
                    Should -Be ([decimal]1234.56)
            }

            It 'Accepts a decimal without leading zero' {
                ConvertFrom-DFeDecimal -Value '.56' |
                    Should -Be ([decimal]0.56)
            }

            It 'Accepts a decimal without trailing fractional digits' {
                ConvertFrom-DFeDecimal -Value '1234.' |
                    Should -Be ([decimal]1234)
            }

            It 'Trims surrounding whitespace before parsing' {
                ConvertFrom-DFeDecimal -Value '  1234.56  ' |
                    Should -Be ([decimal]1234.56)
            }
        }

        Context 'Empty input' {

            It 'Returns no output for null' {
                ConvertFrom-DFeDecimal -Value $null | Should -BeNullOrEmpty
            }

            It 'Returns no output for an empty string' {
                ConvertFrom-DFeDecimal -Value '' |
                    Should -BeNullOrEmpty
            }

            It 'Returns no output for whitespace' {
                ConvertFrom-DFeDecimal -Value '   ' |
                    Should -BeNullOrEmpty
            }
        }

        Context 'Invalid values' {

            It 'Rejects comma as decimal separator' {
                { ConvertFrom-DFeDecimal -Value '1234,56' } |
                    Should -Throw -ErrorId 'InvalidDFeDecimal*'
            }

            It 'Rejects arbitrary text' {
                { ConvertFrom-DFeDecimal -Value 'abc' } |
                    Should -Throw -ErrorId 'InvalidDFeDecimal*'
            }

            It 'Rejects a value with thousand separators' {
                { ConvertFrom-DFeDecimal -Value '1.234.56' } |
                    Should -Throw -ErrorId 'InvalidDFeDecimal*'
            }

            It 'Rejects scientific notation' {
                { ConvertFrom-DFeDecimal -Value '1e2' } |
                    Should -Throw -ErrorId 'InvalidDFeDecimal*'
            }

            It 'Rejects hexadecimal notation' {
                { ConvertFrom-DFeDecimal -Value '0x10' } |
                    Should -Throw -ErrorId 'InvalidDFeDecimal*'
            }

            It 'Rejects values that overflow Decimal' {
                {
                    ConvertFrom-DFeDecimal -Value '79228162514264337593543950336'
                } | Should -Throw -ErrorId 'InvalidDFeDecimal*'
            }
        }

        Context 'Decimal boundaries' {

            It 'Accepts Decimal.MaxValue' {
                ConvertFrom-DFeDecimal -Value '79228162514264337593543950335' |
                    Should -Be ([decimal]::MaxValue)
            }

            It 'Accepts Decimal.MinValue' {
                ConvertFrom-DFeDecimal -Value '-79228162514264337593543950335' |
                    Should -Be ([decimal]::MinValue)
            }
        }

        Context 'Culture independence' {

            It 'Is independent from the current culture' {
                $originalCulture = [System.Threading.Thread]::CurrentThread.CurrentCulture

                try {
                    [System.Threading.Thread]::CurrentThread.CurrentCulture =
                    [System.Globalization.CultureInfo]::GetCultureInfo('pt-BR')

                    ConvertFrom-DFeDecimal -Value '1234.56' | Should -Be ([decimal]1234.56)
                } finally {
                    [System.Threading.Thread]::CurrentThread.CurrentCulture = $originalCulture
                }
            }
        }
    }
}
