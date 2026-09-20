#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for Get-PreviousMonthDateRange.

.DESCRIPTION
Coverage includes:
  - Returns a PSCustomObject with Start and End properties.
  - Start is the first moment of the previous month (00:00:00).
  - End is the last whole second of the previous month (23:59:59).
  - Start and End use the local system timezone offset applicable
    to each boundary.
  - Start is before End.
  - Start and End are in the same month and year.
  - End is the last day of the previous month.
  - Handles the year boundary correctly (e.g. January returns December).
  - Output contract: Start and End are DateTimeOffset values.
  - Correctly handles timezone offset changes between the current
    date and the previous month.
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

Describe 'Get-PreviousMonthDateRange' {

    InModuleScope -ModuleName PipeDFe {


        BeforeAll {
            $Script:Now = [System.DateTimeOffset]::Now
            $Script:TimeZone = [System.TimeZoneInfo]::Local

            $Script:ExpectedYear = $Script:Now.AddMonths(-1).Year
            $Script:ExpectedMonth = $Script:Now.AddMonths(-1).Month

            $Script:ExpectedLastDay = [System.DateTime]::DaysInMonth(
                $Script:ExpectedYear,
                $Script:ExpectedMonth
            )

            $Script:ExpectedStartLocal = [System.DateTime]::new(
                $Script:ExpectedYear,
                $Script:ExpectedMonth,
                1,
                0,
                0,
                0,
                [System.DateTimeKind]::Unspecified
            )

            $Script:ExpectedEndLocal = [System.DateTime]::new(
                $Script:ExpectedYear,
                $Script:ExpectedMonth,
                $Script:ExpectedLastDay,
                23,
                59,
                59,
                [System.DateTimeKind]::Unspecified
            )

            $Script:ExpectedStartOffset = $Script:TimeZone.GetUtcOffset($Script:ExpectedStartLocal)
            $Script:ExpectedEndOffset   = $Script:TimeZone.GetUtcOffset($Script:ExpectedEndLocal)

            $Script:Result = Get-PreviousMonthDateRange
        }

        #region Output contract
        Context 'Output contract' {

            It 'Returns a PSCustomObject' {
                $Script:Result | Should -BeOfType [System.Management.Automation.PSCustomObject]
            }

            It 'Exposes a Start property' {
                $Script:Result.PSObject.Properties.Name | Should -Contain 'Start'
            }

            It 'Exposes an End property' {
                $Script:Result.PSObject.Properties.Name | Should -Contain 'End'
            }

            It 'Exposes Start as DateTimeOffset' {
                $Script:Result.Start | Should -BeOfType [System.DateTimeOffset]
            }

            It 'Exposes End as DateTimeOffset' {
                $Script:Result.End | Should -BeOfType [System.DateTimeOffset]
            }
        }
        #endregion

        #region Start boundary
        Context 'Start boundary' {

            It 'Start is the first day of the previous month' {
                $Script:Result.Start.Day | Should -Be 1
            }

            It 'Start is in the correct month' {
                $Script:Result.Start.Month | Should -Be $Script:ExpectedMonth
            }

            It 'Start is in the correct year' {
                $Script:Result.Start.Year | Should -Be $Script:ExpectedYear
            }

            It 'Start time is 00:00:00' {
                $Script:Result.Start.Hour | Should -Be 0
                $Script:Result.Start.Minute | Should -Be 0
                $Script:Result.Start.Second | Should -Be 0
            }

            It 'Start uses the timezone offset applicable to the start date' {
                $Script:Result.Start.Offset | Should -Be $Script:ExpectedStartOffset
            }
        }
        #endregion

        #region End boundary
        Context 'End boundary' {

            It 'End is the last day of the previous month' {
                $Script:Result.End.Day | Should -Be $Script:ExpectedLastDay
            }

            It 'End is in the correct month' {
                $Script:Result.End.Month | Should -Be $Script:ExpectedMonth
            }

            It 'End is in the correct year' {
                $Script:Result.End.Year | Should -Be $Script:ExpectedYear
            }

            It 'End time is 23:59:59' {
                $Script:Result.End.Hour | Should -Be 23
                $Script:Result.End.Minute | Should -Be 59
                $Script:Result.End.Second | Should -Be 59
            }

            It 'End uses the timezone offset applicable to the end date' {
                $Script:Result.End.Offset | Should -Be $Script:ExpectedEndOffset
            }
        }
        #endregion

        #region Range consistency
        Context 'Range consistency' {

            It 'Start is before End' {
                $Script:Result.Start | Should -BeLessThan $Script:Result.End
            }

            It 'Start and End are in the same month' {
                $Script:Result.Start.Month | Should -Be $Script:Result.End.Month
            }

            It 'Start and End are in the same year' {
                $Script:Result.Start.Year | Should -Be $Script:Result.End.Year
            }

            It 'Start is exactly the expected local boundary' {
                $Script:Result.Start | Should -Be (
                    [System.DateTimeOffset]::new(
                        $Script:ExpectedStartLocal,
                        $Script:ExpectedStartOffset
                    )
                )
            }

            It 'End is exactly the expected local boundary' {
                $Script:Result.End | Should -Be (
                    [System.DateTimeOffset]::new(
                        $Script:ExpectedEndLocal,
                        $Script:ExpectedEndOffset
                    )
                )
            }
        }
        #endregion

        #region Calendar boundary
        Context 'Calendar boundary' {

            It 'Returns December of the previous year when the current month is January' {
                if ($Script:Now.Month -eq 1) {
                    $Script:Result.Start.Year | Should -Be ($Script:Now.Year - 1)
                    $Script:Result.Start.Month |Should -Be 12
                    $Script:Result.End.Year | Should -Be ($Script:Now.Year - 1)
                    $Script:Result.End.Month |Should -Be 12
                }
            }

            It 'Returns the correct number of days for the previous month' {
                $Script:Result.End.Day | Should -Be $Script:ExpectedLastDay
            }
        }
        #endregion
    }
}
