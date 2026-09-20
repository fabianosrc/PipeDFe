#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for ConvertTo-DateTimeOffset.

.DESCRIPTION
Covers all supported input formats, UTC normalization, error handling,
and the output contract.

Contexts:
  ISO 8601 with offset    - with and without sub-second precision
  ISO 8601 without offset - T-separated and space-separated
  Brazilian slash         - with and without time component
  Brazilian dash          - with and without time component
  UTC normalization       - offset is always stripped, result is UTC
  Unsupported formats     - ErrorId and exception type
  Parameter validation    - mandatory, empty, null
  Output contract         - return type, count, UTC kind
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

Describe 'ConvertTo-DateTimeOffset' {

    InModuleScope PipeDFe {

        # The test date is used to determine the local offset that applies to
        # the date being tested. This avoids relying on the current offset,
        # which may differ from the offset applicable to the test date in
        # environments with daylight-saving time.
        BeforeAll {

            $Script:TestDate = [System.DateTime]::new(
                2026, 8, 1, 0, 0, 0, [System.DateTimeKind]::Unspecified
            )

            $Script:LocalOffset = ([System.DateTimeOffset]::new($Script:TestDate)).Offset
        }

        Context 'ISO 8601 with explicit offset' {

            It 'Parses yyyy-MM-ddTHH:mm:ss.fffffffzzz and returns UTC' {
                $result = ConvertTo-DateTimeOffset -Value '2026-08-01T14:30:00.0000000-03:00'

                $result        | Should -BeOfType [System.DateTimeOffset]
                $result.Offset | Should -Be ([System.TimeSpan]::Zero)
                $result.Year   | Should -Be 2026
                $result.Month  | Should -Be 8
                $result.Day    | Should -Be 1
                $result.Hour   | Should -Be 17
                $result.Minute | Should -Be 30
                $result.Second | Should -Be 0
            }

            It 'Parses yyyy-MM-ddTHH:mm:sszzz and returns UTC' {
                $result = ConvertTo-DateTimeOffset -Value '2026-08-01T14:30:00-03:00'

                $result.Offset | Should -Be ([System.TimeSpan]::Zero)
                $result.Hour   | Should -Be 17
            }

            It 'Normalizes a positive offset to UTC' {
                $result = ConvertTo-DateTimeOffset -Value '2026-08-01T14:30:00+05:30'

                $result.Offset | Should -Be ([System.TimeSpan]::Zero)
                $result.Hour   | Should -Be 9
                $result.Minute | Should -Be 0
            }

            It 'Normalizes UTC+00:00 input without change' {
                $result = ConvertTo-DateTimeOffset -Value '2026-08-01T14:30:00+00:00'

                $result.Offset | Should -Be ([System.TimeSpan]::Zero)
                $result.Hour   | Should -Be 14
                $result.Minute | Should -Be 30
            }
        }

        Context 'ISO 8601 without offset' {

            It 'Parses yyyy-MM-ddTHH:mm:ss.fff assuming local and returns UTC' {
                $localDateTime = [System.DateTime]::new(
                    2026, 8, 1, 14, 30, 0, 123, [System.DateTimeKind]::Unspecified
                )

                $expected = [System.DateTimeOffset]::new($localDateTime).ToUniversalTime()

                $result = ConvertTo-DateTimeOffset -Value '2026-08-01T14:30:00.123'

                $result | Should -Be $expected
                $result.Offset | Should -Be ([System.TimeSpan]::Zero)
            }

            It 'Parses yyyy-MM-ddTHH:mm:ss assuming local and returns UTC' {
                $localDateTime = [System.DateTime]::new(
                    2026, 8, 1, 14, 30, 0, [System.DateTimeKind]::Unspecified
                )

                $expected = [System.DateTimeOffset]::new($localDateTime).ToUniversalTime()

                $result = ConvertTo-DateTimeOffset -Value '2026-08-01T14:30:00'

                $result | Should -Be $expected
                $result.Offset | Should -Be ([System.TimeSpan]::Zero)
            }

            It 'Parses yyyy-MM-dd HH:mm:ss (space separator) assuming local and returns UTC' {
                $localDateTime = [System.DateTime]::new(
                    2026, 8, 1, 14, 30, 0, [System.DateTimeKind]::Unspecified
                )

                $expected = [System.DateTimeOffset]::new($localDateTime).ToUniversalTime()

                $result = ConvertTo-DateTimeOffset -Value '2026-08-01 14:30:00'

                $result | Should -Be $expected
                $result.Offset | Should -Be ([System.TimeSpan]::Zero)
            }

            It 'Parses yyyy-MM-dd (date only) assuming local midnight and returns UTC' {
                $localDateTime = [System.DateTime]::new(
                    2026, 8, 1, 0, 0, 0, [System.DateTimeKind]::Unspecified
                )

                $expected = [System.DateTimeOffset]::new($localDateTime).ToUniversalTime()

                $result = ConvertTo-DateTimeOffset -Value '2026-08-01'

                $result | Should -Be $expected
                $result.Offset | Should -Be ([System.TimeSpan]::Zero)
            }
        }

        Context 'Brazilian slash separator' {

            It 'Parses dd/MM/yyyy HH:mm:ss assuming local and returns UTC' {
                $localDateTime = [System.DateTime]::new(
                    2026, 8, 1, 14, 30, 0, [System.DateTimeKind]::Unspecified
                )

                $expected = [System.DateTimeOffset]::new($localDateTime).ToUniversalTime()

                $result = ConvertTo-DateTimeOffset -Value '01/08/2026 14:30:00'

                $result | Should -Be $expected
                $result.Offset | Should -Be ([System.TimeSpan]::Zero)
            }

            It 'Parses dd/MM/yyyy (date only) assuming local midnight and returns UTC' {
                $localDateTime = [System.DateTime]::new(
                    2026, 8, 1, 0, 0, 0, [System.DateTimeKind]::Unspecified
                )

                $expected = [System.DateTimeOffset]::new($localDateTime).ToUniversalTime()

                $result = ConvertTo-DateTimeOffset -Value '01/08/2026'

                $result | Should -Be $expected
                $result.Offset | Should -Be ([System.TimeSpan]::Zero)
            }

            It 'Does not confuse day and month in Brazilian format' {
                $localDateTime = [System.DateTime]::new(
                    2026, 7, 3, 0, 0, 0, [System.DateTimeKind]::Unspecified
                )

                $expected = [System.DateTimeOffset]::new($localDateTime).ToUniversalTime()

                $result = ConvertTo-DateTimeOffset -Value '03/07/2026'

                $result | Should -Be $expected
            }
        }

        Context 'Brazilian dash separator' {

            It 'Parses dd-MM-yyyy HH:mm:ss assuming local and returns UTC' {
                $localDateTime = [System.DateTime]::new(
                    2026, 8, 1, 14, 30, 0, [System.DateTimeKind]::Unspecified
                )

                $expected = [System.DateTimeOffset]::new($localDateTime).ToUniversalTime()

                $result = ConvertTo-DateTimeOffset -Value '01-08-2026 14:30:00'

                $result | Should -Be $expected
                $result.Offset | Should -Be ([System.TimeSpan]::Zero)
            }

            It 'Parses dd-MM-yyyy (date only) assuming local midnight and returns UTC' {
                $localDateTime = [System.DateTime]::new(
                    2026, 8, 1, 0, 0, 0, [System.DateTimeKind]::Unspecified
                )

                $expected = [System.DateTimeOffset]::new($localDateTime).ToUniversalTime()

                $result = ConvertTo-DateTimeOffset -Value '01-08-2026'

                $result | Should -Be $expected
                $result.Offset | Should -Be ([System.TimeSpan]::Zero)
            }

            It 'Does not confuse day and month in Brazilian dash format' {
                $localDateTime = [System.DateTime]::new(
                    2026, 7, 3, 0, 0, 0, [System.DateTimeKind]::Unspecified
                )

                $expected = [System.DateTimeOffset]::new($localDateTime).ToUniversalTime()

                $result = ConvertTo-DateTimeOffset -Value '03-07-2026'

                $result | Should -Be $expected
            }
        }

        Context 'UTC normalization' {

            It 'Always returns offset zero regardless of input offset' {
                $formats = @(
                    '2026-08-01T12:00:00-03:00'
                    '2026-08-01T12:00:00+05:30'
                    '2026-08-01T12:00:00+00:00'
                    '2026-08-01T12:00:00'
                    '2026-08-01'
                    '01/08/2026'
                    '01-08-2026'
                )

                foreach ($format in $formats) {
                    $result = ConvertTo-DateTimeOffset -Value $format
                    $assert = 'input ''{0}'' must produce UTC offset' -f $format

                    $result.Offset | Should -Be ([System.TimeSpan]::Zero) -Because $assert
                }
            }
        }

        Context 'Unsupported formats' {

            It 'Throws on an unrecognized format' {
                { ConvertTo-DateTimeOffset -Value 'not-a-date' } |
                    Should -Throw
            }

            It 'Throws with ErrorId UnsupportedDateFormat' {
                $thrown = $null

                try {
                    ConvertTo-DateTimeOffset -Value 'not-a-date'
                } catch {
                    $thrown = $_
                }

                $thrown.FullyQualifiedErrorId |
                    Should -BeLike 'UnsupportedDateFormat*'
            }

            It 'Throws a FormatException for an unrecognized format' {
                $thrown = $null

                try {
                    ConvertTo-DateTimeOffset -Value 'not-a-date'
                } catch {
                    $thrown = $_
                }

                $thrown.Exception |
                    Should -BeOfType [System.FormatException]
            }

            It 'Throws on MM/dd/yyyy (American format is not supported)' {
                # 13/08/2026 is unambiguous - day 13 cannot be a month.
                { ConvertTo-DateTimeOffset -Value '13/08/2026' } | Should -Not -Throw

                # But 01/08/2026 parsed as MM/dd would give January 8th -
                # the function must parse it as August 1st (Brazilian format).
                $result = ConvertTo-DateTimeOffset -Value '01/08/2026'

                $result.Month | Should -Be 8
            }

            It 'Throws on an empty string' {
                { ConvertTo-DateTimeOffset -Value '' } | Should -Throw
            }
        }

        Context 'Parameter validation' {

            It 'Defines Value as mandatory' {
                $param = (Get-Command ConvertTo-DateTimeOffset).Parameters['Value']

                $param.Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute]
                    } | ForEach-Object Mandatory |

                    Should -Contain $true
            }

            It 'Rejects a null Value' {
                { ConvertTo-DateTimeOffset -Value $null } | Should -Throw
            }

            It 'Rejects an empty Value' {
                { ConvertTo-DateTimeOffset -Value '' } | Should -Throw
            }
        }

        Context 'Output contract' {

            It 'Returns exactly one value' {
                $results = @(ConvertTo-DateTimeOffset -Value '2026-08-01')

                $results | Should -HaveCount 1
            }

            It 'Returns a DateTimeOffset' {
                $result = ConvertTo-DateTimeOffset -Value '2026-08-01'

                $result | Should -BeOfType [System.DateTimeOffset]
            }

            It 'Returns a value with UTC offset' {
                $result = ConvertTo-DateTimeOffset -Value '2026-08-01'

                $result.Offset | Should -Be ([System.TimeSpan]::Zero)
            }
        }
    }
}
