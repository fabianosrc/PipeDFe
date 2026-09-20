#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for Resolve-PeriodLabel.

.DESCRIPTION
Verifies period label resolution for full calendar months and partial
date ranges, DateRange validation delegation and output contract.

Coverage includes:
  - DateRange is mandatory and rejects null.
  - Delegates DateRange validation to Assert-DateRange.
  - Throws when Start property is missing.
  - Throws when End property is missing.
  - Throws when Start is not a DateTimeOffset.
  - Title is the month name in uppercase for a full calendar month.
  - Body is always a full date range string.
  - Title equals Body for a partial date range.
  - Correctly identifies the last day of months with 28, 29, 30 and 31 days.
  - Rejects a range spanning two months as partial.
  - Ignores time-of-day when determining full month.
  - Month names are rendered in Portuguese.
  - Output exposes exactly Title and Body as strings.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseShouldProcessForStateChangingFunctions',
    '',
    Justification = 'Test infrastructure helpers do not ship as module functions.'
)]

param ()

# InModuleScope needs to resolve the PipeDFe module during the Discovery phase,
# because that's when Context/It are executed to register the test tree. If the
# module isn't loaded at that point, InModuleScope fails before any BeforeAll or
# BeforeEach ever runs.
BeforeDiscovery {
    $moduleRoot = (Get-Item -LiteralPath $PSScriptRoot).Parent.Parent.Parent.Parent.FullName

    $moduleName = Join-Path -Path $moduleRoot -ChildPath 'PipeDFe.psd1'

    Import-Module -Name $moduleName -Force -Global -ErrorAction Stop
}

Describe 'Resolve-PeriodLabel' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            $Script:Command = Get-Command -Name Resolve-PeriodLabel -ErrorAction Stop
            $Script:Utc     = [System.TimeSpan]::Zero

            function New-DateRange {
                [CmdletBinding()]
                [OutputType([pscustomobject])]
                param (
                    [Parameter(Mandatory)]
                    [System.DateTimeOffset]$Start,

                    [Parameter(Mandatory)]
                    [System.DateTimeOffset]$End
                )

                [PSCustomObject]@{
                    Start = $Start
                    End   = $End
                }
            }

            $newDateRangeParams = @{
                Start = [System.DateTimeOffset]::new(2026, 6,  1, 0, 0, 0, $Script:Utc)
                End   = [System.DateTimeOffset]::new(2026, 6, 30, 0, 0, 0, $Script:Utc)
            }

            $Script:FullJune2026 = New-DateRange @newDateRangeParams

            $newPartialParams = @{
                Start = [System.DateTimeOffset]::new(2026, 6,  1, 0, 0, 0, $Script:Utc)
                End   = [System.DateTimeOffset]::new(2026, 6, 15, 0, 0, 0, $Script:Utc)
            }

            $Script:PartialJune2026 = New-DateRange @newPartialParams
        }

        #region Parameter contract
        Context 'Parameter contract' {

            It 'Declares DateRange as mandatory' {
                $mandatory = $Script:Command.Parameters['DateRange'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.Mandatory
                    }

                $mandatory | Should -Not -BeNullOrEmpty
            }

            It 'Rejects null DateRange' {
                { Resolve-PeriodLabel -DateRange $null } | Should -Throw
            }
        }
        #endregion

        #region DateRange validation
        Context 'DateRange validation' {

            It 'Throws when Start property is missing' {
                $range = [PSCustomObject]@{
                    End = [System.DateTimeOffset]::new(2026, 6, 30, 0, 0, 0, $Script:Utc)
                }

                { Resolve-PeriodLabel -DateRange $range -ErrorAction Stop } | Should -Throw
            }

            It 'Throws when End property is missing' {
                $range = [PSCustomObject]@{
                    Start = [System.DateTimeOffset]::new(2026, 6, 1, 0, 0, 0, $Script:Utc)
                }

                { Resolve-PeriodLabel -DateRange $range -ErrorAction Stop } | Should -Throw
            }

            It 'Throws when Start is not a DateTimeOffset' {
                $range = [PSCustomObject]@{
                    Start = '2026-06-01'
                    End   = [System.DateTimeOffset]::new(2026, 6, 30, 0, 0, 0, $Script:Utc)
                }

                { Resolve-PeriodLabel -DateRange $range -ErrorAction Stop } | Should -Throw
            }
        }
        #endregion

        #region Full calendar month
        Context 'Full calendar month' {

            BeforeAll {

                $Script:FullResult = Resolve-PeriodLabel -DateRange $Script:FullJune2026
            }

            It 'Sets Title to the month name in uppercase' {
                $Script:FullResult.Title | Should -Be 'JUNHO/2026'
            }

            It 'Sets Body to the full date range string' {
                $Script:FullResult.Body | Should -Be '01/06/2026 a 30/06/2026'
            }

            It 'Title and Body differ for a full month' {
                $Script:FullResult.Title | Should -Not -Be $Script:FullResult.Body
            }
        }
        #endregion

        #region Partial date range
        Context 'Partial date range' {

            BeforeAll {

                $Script:PartialResult = Resolve-PeriodLabel -DateRange $Script:PartialJune2026
            }

            It 'Sets Title to the date range string' {
                $Script:PartialResult.Title | Should -Be '01/06/2026 a 15/06/2026'
            }

            It 'Sets Body to the date range string' {
                $Script:PartialResult.Body | Should -Be '01/06/2026 a 15/06/2026'
            }

            It 'Title equals Body for a partial range' {
                $Script:PartialResult.Title | Should -Be $Script:PartialResult.Body
            }
        }
        #endregion

        #region Month boundary detection
        Context 'Month boundary detection' {

            It 'Recognizes February with 28 days as a full month' {
                $rangeParams = @{
                    Start = [System.DateTimeOffset]::new(2026, 2,  1, 0, 0, 0, $Script:Utc)
                    End   = [System.DateTimeOffset]::new(2026, 2, 28, 0, 0, 0, $Script:Utc)
                }

                $result = Resolve-PeriodLabel -DateRange (New-DateRange @rangeParams)

                $result.Title | Should -Be 'FEVEREIRO/2026'
            }

            It 'Recognizes February with 29 days as a full month in a leap year' {
                $rangeParams = @{
                    Start = [System.DateTimeOffset]::new(2028, 2,  1, 0, 0, 0, $Script:Utc)
                    End   = [System.DateTimeOffset]::new(2028, 2, 29, 0, 0, 0, $Script:Utc)
                }

                $result = Resolve-PeriodLabel -DateRange (New-DateRange @rangeParams)

                $result.Title | Should -Be 'FEVEREIRO/2028'
            }

            It 'Rejects February ending on day 28 in a leap year as partial' {
                $rangeParams = @{
                    Start = [System.DateTimeOffset]::new(2028, 2,  1, 0, 0, 0, $Script:Utc)
                    End   = [System.DateTimeOffset]::new(2028, 2, 28, 0, 0, 0, $Script:Utc)
                }

                $result = Resolve-PeriodLabel -DateRange (New-DateRange @rangeParams)

                $result.Title | Should -Be '01/02/2028 a 28/02/2028'
            }

            It 'Recognizes a 31-day month as a full month' {
                $rangeParams = @{
                    Start = [System.DateTimeOffset]::new(2026, 1,  1, 0, 0, 0, $Script:Utc)
                    End   = [System.DateTimeOffset]::new(2026, 1, 31, 0, 0, 0, $Script:Utc)
                }

                $result = Resolve-PeriodLabel -DateRange (New-DateRange @rangeParams)

                $result.Title | Should -Be 'JANEIRO/2026'
            }

            It 'Rejects a range spanning two months as partial' {
                $rangeParams = @{
                    Start = [System.DateTimeOffset]::new(2026, 6,  1, 0, 0, 0, $Script:Utc)
                    End   = [System.DateTimeOffset]::new(2026, 7, 31, 0, 0, 0, $Script:Utc)
                }

                $result = Resolve-PeriodLabel -DateRange (New-DateRange @rangeParams)

                $result.Title | Should -Be '01/06/2026 a 31/07/2026'
            }

            It 'Ignores time-of-day when determining full month' {
                $rangeParams = @{
                    Start = [System.DateTimeOffset]::new(2026, 6,  1, 23, 59, 59, $Script:Utc)
                    End   = [System.DateTimeOffset]::new(2026, 6, 30,  0,  0,  0, $Script:Utc)
                }

                $result = Resolve-PeriodLabel -DateRange (New-DateRange @rangeParams)

                $result.Title | Should -Be 'JUNHO/2026'
            }
        }
        #endregion

        #region Portuguese month names
        Context 'Portuguese month names' {

            It 'Renders January in Portuguese' {
                $rangeParams = @{
                    Start = [System.DateTimeOffset]::new(2026,  1,  1, 0, 0, 0, $Script:Utc)
                    End   = [System.DateTimeOffset]::new(2026,  1, 31, 0, 0, 0, $Script:Utc)
                }

                (Resolve-PeriodLabel -DateRange (New-DateRange @rangeParams)).Title |
                    Should -Be 'JANEIRO/2026'
            }

            It 'Renders March in Portuguese' {
                $rangeParams = @{
                    Start = [System.DateTimeOffset]::new(2026, 3,  1, 0, 0, 0, $Script:Utc)
                    End   = [System.DateTimeOffset]::new(2026, 3, 31, 0, 0, 0, $Script:Utc)
                }

                (Resolve-PeriodLabel -DateRange (New-DateRange @rangeParams)).Title |
                    Should -Be 'MARÇO/2026'
            }

            It 'Renders December in Portuguese' {
                $rangeParams = @{
                    Start = [System.DateTimeOffset]::new(2026, 12,  1, 0, 0, 0, $Script:Utc)
                    End   = [System.DateTimeOffset]::new(2026, 12, 31, 0, 0, 0, $Script:Utc)
                }

                (Resolve-PeriodLabel -DateRange (New-DateRange @rangeParams)).Title |
                    Should -Be 'DEZEMBRO/2026'
            }
        }
        #endregion

        #region Output contract
        Context 'Output contract' {

            BeforeAll {

                $Script:Sample = Resolve-PeriodLabel -DateRange $Script:FullJune2026
            }

            It 'Returns a PSCustomObject' {
                $Script:Sample | Should -BeOfType [System.Management.Automation.PSCustomObject]
            }

            It 'Exposes exactly Title and Body' {
                $expected = @('Title', 'Body')
                $actual   = @($Script:Sample.PSObject.Properties.Name)

                $actual | Should -Be $expected
            }

            It 'Exposes Title as string' {
                $Script:Sample.Title | Should -BeOfType [string]
            }

            It 'Exposes Body as string' {
                $Script:Sample.Body | Should -BeOfType [string]
            }
        }
        #endregion
    }
}
