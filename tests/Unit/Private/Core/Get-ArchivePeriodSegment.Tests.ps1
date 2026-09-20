#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for Get-ArchivePeriodSegment.

.DESCRIPTION
Coverage includes:
  - DateRange is mandatory and rejects null.
  - Delegates validation to Assert-DateRange (missing Start, missing End).
  - Returns yyyyMM for a full calendar month.
  - Returns yyyyMMdd_yyyyMMdd for a partial date range.
  - Returns yyyyMMdd_yyyyMMdd for a range spanning two months.
  - Ignores time-of-day when determining full month.
  - Handles February in a leap year correctly (day 29 = full month).
  - Handles February in a non-leap year correctly (day 28 = full month).
  - Rejects February/28 in a leap year as partial (day 29 is missing).
  - Handles a 31-day month correctly.
  - Returns yyyyMMdd_yyyyMMdd for a single-day range.
  - Throws when End is before Start.
  - Output is always [string].
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseShouldProcessForStateChangingFunctions',
    '',
    Justification = 'ShouldProcess would add no value here.'
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

Describe 'Get-ArchivePeriodSegment' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            $Script:Command = Get-Command -Name Get-ArchivePeriodSegment -ErrorAction Stop
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
                { Get-ArchivePeriodSegment -DateRange $null } | Should -Throw
            }
        }
        #endregion

        #region DateRange validation (delegated to Assert-DateRange)
        Context 'DateRange validation' {

            It 'Throws when Start property is missing' {
                $range = [PSCustomObject]@{
                    End = [System.DateTimeOffset]::new(2026, 6, 30, 0, 0, 0, $Script:Utc)
                }

                { Get-ArchivePeriodSegment -DateRange $range -ErrorAction Stop } | Should -Throw
            }

            It 'Throws when End property is missing' {
                $range = [PSCustomObject]@{
                    Start = [System.DateTimeOffset]::new(2026, 6, 1, 0, 0, 0, $Script:Utc)
                }

                { Get-ArchivePeriodSegment -DateRange $range -ErrorAction Stop } | Should -Throw
            }

            It 'Throws when End is before Start' {
                $rangeParams = @{
                    Start = [System.DateTimeOffset]::new(2026, 6, 15, 0, 0, 0, $Script:Utc)
                    End   = [System.DateTimeOffset]::new(2026, 6,  1, 0, 0, 0, $Script:Utc)
                }

                { Get-ArchivePeriodSegment -DateRange (New-DateRange @rangeParams) -ErrorAction Stop } |
                    Should -Throw
            }
        }
        #endregion

        #region Full calendar month
        Context 'Full calendar month' {

            It 'Returns yyyyMM for a full 30-day month' {
                $rangeParams = @{
                    Start = [System.DateTimeOffset]::new(2026, 6,  1, 0, 0, 0, $Script:Utc)
                    End   = [System.DateTimeOffset]::new(2026, 6, 30, 0, 0, 0, $Script:Utc)
                }

                Get-ArchivePeriodSegment -DateRange (New-DateRange @rangeParams) |
                    Should -Be '202606'
            }

            It 'Returns yyyyMM for a full 31-day month' {
                $rangeParams = @{
                    Start = [System.DateTimeOffset]::new(2026, 1,  1, 0, 0, 0, $Script:Utc)
                    End   = [System.DateTimeOffset]::new(2026, 1, 31, 0, 0, 0, $Script:Utc)
                }

                Get-ArchivePeriodSegment -DateRange (New-DateRange @rangeParams) |
                    Should -Be '202601'
            }

            It 'Returns yyyyMM for February in a non-leap year (28 days)' {
                $rangeParams = @{
                    Start = [System.DateTimeOffset]::new(2026, 2,  1, 0, 0, 0, $Script:Utc)
                    End   = [System.DateTimeOffset]::new(2026, 2, 28, 0, 0, 0, $Script:Utc)
                }

                Get-ArchivePeriodSegment -DateRange (New-DateRange @rangeParams) |
                    Should -Be '202602'
            }

            It 'Returns yyyyMM for February in a leap year (29 days)' {
                $rangeParams = @{
                    Start = [System.DateTimeOffset]::new(2028, 2,  1, 0, 0, 0, $Script:Utc)
                    End   = [System.DateTimeOffset]::new(2028, 2, 29, 0, 0, 0, $Script:Utc)
                }

                Get-ArchivePeriodSegment -DateRange (New-DateRange @rangeParams) |
                    Should -Be '202802'
            }

            It 'Ignores time-of-day when determining full month' {
                # Start at end-of-day, End at midnight - still a full month by date.
                $rangeParams = @{
                    Start = [System.DateTimeOffset]::new(2026, 6,  1, 23, 59, 59, $Script:Utc)
                    End   = [System.DateTimeOffset]::new(2026, 6, 30,  0,  0,  0, $Script:Utc)
                }

                Get-ArchivePeriodSegment -DateRange (New-DateRange @rangeParams) |
                    Should -Be '202606'
            }
        }
        #endregion

        #region Partial date range
        Context 'Partial date range' {

            It 'Returns yyyyMMdd_yyyyMMdd for a mid-month range' {
                $rangeParams = @{
                    Start = [System.DateTimeOffset]::new(2026, 6,  1, 0, 0, 0, $Script:Utc)
                    End   = [System.DateTimeOffset]::new(2026, 6, 15, 0, 0, 0, $Script:Utc)
                }

                Get-ArchivePeriodSegment -DateRange (New-DateRange @rangeParams) |
                    Should -Be '20260601_20260615'
            }

            It 'Returns yyyyMMdd_yyyyMMdd for a range spanning two months' {
                $rangeParams = @{
                    Start = [System.DateTimeOffset]::new(2026, 6,  1, 0, 0, 0, $Script:Utc)
                    End   = [System.DateTimeOffset]::new(2026, 7, 31, 0, 0, 0, $Script:Utc)
                }

                Get-ArchivePeriodSegment -DateRange (New-DateRange @rangeParams) |
                    Should -Be '20260601_20260731'
            }

            It 'Returns yyyyMMdd_yyyyMMdd for a single-day range' {
                $rangeParams = @{
                    Start = [System.DateTimeOffset]::new(2026, 6, 15, 0, 0, 0, $Script:Utc)
                    End   = [System.DateTimeOffset]::new(2026, 6, 15, 0, 0, 0, $Script:Utc)
                }

                Get-ArchivePeriodSegment -DateRange (New-DateRange @rangeParams) |
                    Should -Be '20260615_20260615'
            }

            It 'Treats February/28 as partial in a leap year (day 29 is missing)' {
                $rangeParams = @{
                    Start = [System.DateTimeOffset]::new(2028, 2,  1, 0, 0, 0, $Script:Utc)
                    End   = [System.DateTimeOffset]::new(2028, 2, 28, 0, 0, 0, $Script:Utc)
                }

                Get-ArchivePeriodSegment -DateRange (New-DateRange @rangeParams) |
                    Should -Be '20280201_20280228'
            }
        }
        #endregion

        #region Output contract
        Context 'Output contract' {

            It 'Returns [string] for a full month' {
                $rangeParams = @{
                    Start = [System.DateTimeOffset]::new(2026, 6,  1, 0, 0, 0, $Script:Utc)
                    End   = [System.DateTimeOffset]::new(2026, 6, 30, 0, 0, 0, $Script:Utc)
                }

                Get-ArchivePeriodSegment -DateRange (New-DateRange @rangeParams) |
                    Should -BeOfType [string]
            }

            It 'Returns [string] for a partial range' {
                $rangeParams = @{
                    Start = [System.DateTimeOffset]::new(2026, 6,  1, 0, 0, 0, $Script:Utc)
                    End   = [System.DateTimeOffset]::new(2026, 6, 15, 0, 0, 0, $Script:Utc)
                }

                Get-ArchivePeriodSegment -DateRange (New-DateRange @rangeParams) |
                    Should -BeOfType [string]
            }
        }
        #endregion
    }
}
