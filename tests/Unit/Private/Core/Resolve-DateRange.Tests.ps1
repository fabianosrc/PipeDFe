#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for Resolve-DateRange.

.DESCRIPTION
Coverage includes:
  - No parameters return the previous calendar month range.
  - Whitespace-only parameters are treated as absent.
  - StartDate only normalizes Start to 00:00:00 and End to the current moment.
  - StartDate and EndDate normalize the range boundaries correctly.
  - EndDate resolving to today sets End to the current moment.
  - EndDate without StartDate throws EndDateWithoutStartDate.
  - StartDate after EndDate throws StartDateAfterEndDate.
  - Both errors use InvalidArgument category.
  - Invalid dates are rejected.
  - Output is a PSCustomObject.
  - Start and End are DateTimeOffset values.
  - Local timezone offsets are applied to normalized boundaries.
  - Start is never after End.
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

Describe 'Resolve-DateRange' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            $Script:Command  = Get-Command -Name Resolve-DateRange -ErrorAction Stop

            $Script:TimeZone = [System.TimeZoneInfo]::Local
        }

        #region Parameter contract
        Context 'Parameter contract' {

            It 'Declares StartDate as a string parameter' {
                $Script:Command.Parameters['StartDate'].ParameterType | Should -Be ([string])
            }

            It 'Declares EndDate as a string parameter' {
                $Script:Command.Parameters['EndDate'].ParameterType | Should -Be ([string])
            }

            It 'Does not require StartDate' {
                $mandatory = $Script:Command.Parameters['StartDate'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.Mandatory
                    }

                $mandatory | Should -BeNullOrEmpty
            }

            It 'Does not require EndDate' {
                $mandatory = $Script:Command.Parameters['EndDate'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.Mandatory
                    }

                $mandatory | Should -BeNullOrEmpty
            }
        }
        #endregion

        #region No parameters
        Context 'No parameters' {

            BeforeAll {

                $Script:DefaultResult = Resolve-DateRange
                $Script:PreviousMonth = Get-PreviousMonthDateRange
            }

            It 'Returns a PSCustomObject' {
                $Script:DefaultResult |
                    Should -BeOfType [System.Management.Automation.PSCustomObject]
            }

            It 'Returns the previous month Start' {
                $Script:DefaultResult.Start | Should -Be $Script:PreviousMonth.Start
            }

            It 'Returns the previous month End' {
                $Script:DefaultResult.End | Should -Be $Script:PreviousMonth.End
            }

            It 'Returns Start and End as DateTimeOffset' {
                $Script:DefaultResult.Start | Should -BeOfType [System.DateTimeOffset]
                $Script:DefaultResult.End   | Should -BeOfType [System.DateTimeOffset]
            }

            It 'Returns Start before or equal to End' {
                $Script:DefaultResult.Start |
                    Should -BeLessOrEqual $Script:DefaultResult.End
            }
        }
        #endregion

        #region Whitespace parameters
        Context 'Whitespace parameters' {

            It 'Treats whitespace-only StartDate and EndDate as absent' {
                $result = Resolve-DateRange -StartDate '   ' -EndDate '   '

                $expected = Get-PreviousMonthDateRange

                $result.Start | Should -Be $expected.Start
                $result.End   | Should -Be $expected.End
            }

            It 'Treats whitespace-only EndDate as absent when StartDate is supplied' {
                $before = [System.DateTimeOffset]::Now

                $result = Resolve-DateRange -StartDate '01/08/2026' -EndDate '   '

                $after = [System.DateTimeOffset]::Now

                $result.Start.Day   | Should -Be 1
                $result.Start.Month | Should -Be 8
                $result.Start.Year  | Should -Be 2026

                $result.End | Should -BeGreaterOrEqual $before
                $result.End | Should -BeLessOrEqual $after
            }
        }
        #endregion

        #region StartDate only
        Context 'StartDate only' {

            BeforeAll {

                $Script:StartOnlyResult = Resolve-DateRange -StartDate '01/08/2026'
            }

            It 'Normalizes Start to the first moment of StartDate' {
                $Script:StartOnlyResult.Start.Day    | Should -Be 1
                $Script:StartOnlyResult.Start.Month  | Should -Be 8
                $Script:StartOnlyResult.Start.Year   | Should -Be 2026
                $Script:StartOnlyResult.Start.Hour   | Should -Be 0
                $Script:StartOnlyResult.Start.Minute | Should -Be 0
                $Script:StartOnlyResult.Start.Second | Should -Be 0
            }

            It 'Applies the local timezone offset to Start' {
                $localDate = [System.DateTime]::new(
                    2026,
                    8,
                    1,
                    0,
                    0,
                    0,
                    [System.DateTimeKind]::Unspecified
                )

                $expectedOffset = $Script:TimeZone.GetUtcOffset($localDate)

                $Script:StartOnlyResult.Start.Offset | Should -Be $expectedOffset
            }

            It 'Sets End to the current moment' {
                $now = [System.DateTimeOffset]::Now

                $Script:StartOnlyResult.End | Should -BeLessOrEqual $now
            }

            It 'Sets End close to the current moment' {
                $now = [System.DateTimeOffset]::Now
                $elapsed = ($now - $Script:StartOnlyResult.End).TotalSeconds

                $elapsed | Should -BeGreaterOrEqual 0
                $elapsed | Should -BeLessThan 5
            }

            It 'Returns Start before End' {
                $Script:StartOnlyResult.Start |
                    Should -BeLessThan $Script:StartOnlyResult.End
            }
        }
        #endregion

        #region StartDate and EndDate
        Context 'StartDate and EndDate' {

            BeforeAll {
                $resolveParams = @{
                    StartDate = '01/07/2026'
                    EndDate   = '31/07/2026'
                }

                $Script:RangeResult = Resolve-DateRange @resolveParams
            }

            It 'Normalizes Start to the first moment of StartDate' {
                $Script:RangeResult.Start.Day    | Should -Be 1
                $Script:RangeResult.Start.Month  | Should -Be 7
                $Script:RangeResult.Start.Year   | Should -Be 2026
                $Script:RangeResult.Start.Hour   | Should -Be 0
                $Script:RangeResult.Start.Minute | Should -Be 0
                $Script:RangeResult.Start.Second | Should -Be 0
            }

            It 'Normalizes End to the last second of EndDate' {
                $Script:RangeResult.End.Day    | Should -Be 31
                $Script:RangeResult.End.Month  | Should -Be 7
                $Script:RangeResult.End.Year   | Should -Be 2026
                $Script:RangeResult.End.Hour   | Should -Be 23
                $Script:RangeResult.End.Minute | Should -Be 59
                $Script:RangeResult.End.Second | Should -Be 59
            }

            It 'Applies the local timezone offset to Start' {
                $localDate = [System.DateTime]::new(
                    2026,
                    7,
                    1,
                    0,
                    0,
                    0,
                    [System.DateTimeKind]::Unspecified
                )

                $expectedOffset = $Script:TimeZone.GetUtcOffset($localDate)

                $Script:RangeResult.Start.Offset | Should -Be $expectedOffset
            }

            It 'Applies the local timezone offset to End' {
                $localDate = [System.DateTime]::new(
                    2026,
                    7,
                    31,
                    0,
                    0,
                    0,
                    [System.DateTimeKind]::Unspecified
                )

                $expectedOffset = $Script:TimeZone.GetUtcOffset($localDate)

                $Script:RangeResult.End.Offset | Should -Be $expectedOffset
            }

            It 'Returns Start before End' {
                $Script:RangeResult.Start | Should -BeLessThan $Script:RangeResult.End
            }
        }
        #endregion

        #region EndDate resolves to today
        Context 'EndDate resolves to today' {

            It 'Sets End to the current moment when EndDate is today' {
                $today = [System.DateTimeOffset]::Now.ToString('dd/MM/yyyy')

                $before = [System.DateTimeOffset]::Now

                $resolveParams = @{
                    StartDate = '01/01/2020'
                    EndDate   = $today
                }

                $result = Resolve-DateRange @resolveParams

                $after = [System.DateTimeOffset]::Now

                $result.End | Should -BeGreaterOrEqual $before
                $result.End | Should -BeLessOrEqual $after
            }

            It 'Does not normalize today End to 23:59:59' {
                $today = [System.DateTimeOffset]::Now.ToString('dd/MM/yyyy')

                $result = Resolve-DateRange -StartDate '01/01/2020' -EndDate $today

                $result.End |
                    Should -Not -Be (
                        [System.DateTimeOffset]::new(
                            $result.End.Year,
                            $result.End.Month,
                            $result.End.Day,
                            23,
                            59,
                            59,
                            $result.End.Offset
                        )
                    )
            }
        }
        #endregion

        #region Error cases
        Context 'Error cases' {

            BeforeAll {

                $Script:EndOnlyThrown = $null

                try {
                    Resolve-DateRange -EndDate '31/08/2026' -ErrorAction Stop
                } catch {
                    $Script:EndOnlyThrown = $_
                }

                $Script:StartAfterEndThrown = $null

                try {
                    Resolve-DateRange -StartDate '31/08/2026' -EndDate '01/08/2026' -ErrorAction Stop
                } catch {
                    $Script:StartAfterEndThrown = $_
                }
            }

            It 'Throws EndDateWithoutStartDate when only EndDate is supplied' {
                $Script:EndOnlyThrown | Should -Not -BeNullOrEmpty

                $Script:EndOnlyThrown.FullyQualifiedErrorId |
                    Should -BeLike 'EndDateWithoutStartDate*'
            }

            It 'Uses InvalidArgument category for EndDateWithoutStartDate' {
                $Script:EndOnlyThrown.CategoryInfo.Category |
                    Should -Be ([System.Management.Automation.ErrorCategory]::InvalidArgument)
            }

            It 'Exposes EndDate as TargetObject for EndDateWithoutStartDate' {
                $Script:EndOnlyThrown.TargetObject | Should -Be '31/08/2026'
            }

            It 'Throws StartDateAfterEndDate when StartDate is after EndDate' {
                $Script:StartAfterEndThrown | Should -Not -BeNullOrEmpty

                $Script:StartAfterEndThrown.FullyQualifiedErrorId |
                    Should -BeLike 'StartDateAfterEndDate*'
            }

            It 'Uses InvalidArgument category for StartDateAfterEndDate' {
                $Script:StartAfterEndThrown.CategoryInfo.Category |
                    Should -Be ([System.Management.Automation.ErrorCategory]::InvalidArgument)
            }

            It 'Exposes StartDate as TargetObject for StartDateAfterEndDate' {
                $Script:StartAfterEndThrown.TargetObject | Should -Be '31/08/2026'
            }
        }
        #endregion

        #region Invalid date input
        Context 'Invalid date input' {

            It 'Rejects an invalid StartDate' {
                {
                    Resolve-DateRange -StartDate 'not-a-date' -ErrorAction Stop
                } | Should -Throw
            }

            It 'Rejects an invalid EndDate' {
                {
                    Resolve-DateRange -StartDate '01/08/2026' -EndDate 'not-a-date' -ErrorAction Stop
                } | Should -Throw
            }
        }
        #endregion

        #region Output contract
        Context 'Output contract' {

            BeforeAll {

                $Script:OutputResult = Resolve-DateRange -StartDate '01/07/2026' -EndDate '31/07/2026'
            }

            It 'Returns a PSCustomObject' {
                $Script:OutputResult |
                    Should -BeOfType [System.Management.Automation.PSCustomObject]
            }

            It 'Exposes a Start property' {
                $Script:OutputResult.PSObject.Properties.Name | Should -Contain 'Start'
            }

            It 'Exposes an End property' {
                $Script:OutputResult.PSObject.Properties.Name | Should -Contain 'End'
            }

            It 'Exposes Start as DateTimeOffset' {
                $Script:OutputResult.Start | Should -BeOfType [System.DateTimeOffset]
            }

            It 'Exposes End as DateTimeOffset' {
                $Script:OutputResult.End | Should -BeOfType [System.DateTimeOffset]
            }

            It 'Returns Start before or equal to End' {
                $Script:OutputResult.Start | Should -BeLessOrEqual $Script:OutputResult.End
            }
        }
        #endregion
    }
}
