#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for Assert-DateRange.

.DESCRIPTION
Validates the complete contract of Assert-DateRange:

  - Mandatory DateRange parameter.
  - Mandatory CallerPSCmdlet parameter.
  - Null parameter rejection.
  - Successful validation of a valid DateRange.
  - No output on successful validation.
  - Missing Start property.
  - Missing End property.
  - Null Start value.
  - Null End value.
  - Invalid Start type.
  - Invalid End type.
  - Correct FullyQualifiedErrorId.
  - Correct ErrorCategory.
  - Correct TargetObject.

The production function uses PSCmdlet.ThrowTerminatingError(), therefore
errors are captured outside the advanced-function wrapper that supplies
CallerPSCmdlet.
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

Describe 'Assert-DateRange' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            $Script:Command = Get-Command -Name Assert-DateRange -ErrorAction Stop

            $Script:ValidDateRange = [PSCustomObject]@{
                Start = [System.DateTimeOffset]::new(2026, 8,  1,  0,  0,  0, [System.TimeSpan]::Zero)
                End   = [System.DateTimeOffset]::new(2026, 8, 31, 23, 59, 59, [System.TimeSpan]::Zero)
            }

            # The production function requires the caller's PSCmdlet because
            # it intentionally calls ThrowTerminatingError() against it.
            #
            # IMPORTANT:
            # Do not catch the error inside this function.
            # The error is intentionally allowed to terminate this wrapper.
            # The tests catch it outside this function.
            function Invoke-TestAssertDateRange {
                [CmdletBinding()]
                param (
                    [AllowNull()]
                    [pscustomobject]$DateRange
                )

                process {
                    Assert-DateRange -DateRange $DateRange -CallerPSCmdlet $PSCmdlet
                }
            }

            function Get-TestAssertDateRangeError {
                [CmdletBinding()]
                param (
                    [AllowNull()]
                    [pscustomobject]$DateRange
                )

                try {
                    Invoke-TestAssertDateRange -DateRange $DateRange
                } catch {
                    return $_
                }

                return $null
            }
        }

        #region Parameter contract
        Context 'Parameter contract' {

            It 'Declares DateRange as mandatory' {

                $attribute = $Script:Command.Parameters['DateRange'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute]
                    }

                $attribute.Mandatory | Should -BeTrue
            }

            It 'Declares CallerPSCmdlet as mandatory' {

                $attribute = $Script:Command.Parameters['CallerPSCmdlet'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute]
                    }

                $attribute.Mandatory | Should -BeTrue
            }

            It 'Rejects null DateRange' {

                {
                    & {
                        [CmdletBinding()]
                        param ()

                        process {
                            Assert-DateRange -DateRange $null -CallerPSCmdlet $PSCmdlet
                        }
                    }
                } | Should -Throw
            }

            It 'Rejects null CallerPSCmdlet' {

                {
                    Assert-DateRange -DateRange $Script:ValidDateRange -CallerPSCmdlet $null
                } | Should -Throw
            }
        }
        #endregion

        #region Valid DateRange
        Context 'Valid DateRange' {

            It 'Completes without throwing' {

                {
                    Invoke-TestAssertDateRange -DateRange $Script:ValidDateRange
                } | Should -Not -Throw
            }

            It 'Produces no output' {

                $result = Invoke-TestAssertDateRange -DateRange $Script:ValidDateRange
                $result | Should -BeNullOrEmpty
            }
        }
        #endregion

        #region Missing properties
        Context 'Missing properties' {

            It 'Throws DateRangeMissingStart when Start is absent' {

                $dateRange = [PSCustomObject]@{
                    End = [System.DateTimeOffset]::UtcNow
                }

                $errorRecord = Get-TestAssertDateRangeError -DateRange $dateRange
                $errorRecord | Should -Not -BeNullOrEmpty

                $errorRecord.FullyQualifiedErrorId | Should -BeLike 'DateRangeMissingStart*'
            }

            It 'Throws DateRangeMissingEnd when End is absent' {

                $dateRange = [PSCustomObject]@{
                    Start = [System.DateTimeOffset]::UtcNow
                }

                $errorRecord = Get-TestAssertDateRangeError -DateRange $dateRange
                $errorRecord | Should -Not -BeNullOrEmpty

                $errorRecord.FullyQualifiedErrorId | Should -BeLike 'DateRangeMissingEnd*'
            }

            It 'Uses DateRange as TargetObject when Start is absent' {

                $dateRange = [PSCustomObject]@{
                    End = [System.DateTimeOffset]::UtcNow
                }

                $errorRecord = Get-TestAssertDateRangeError -DateRange $dateRange
                $errorRecord.TargetObject | Should -BeExactly $dateRange
            }

            It 'Uses DateRange as TargetObject when End is absent' {

                $dateRange = [PSCustomObject]@{
                    Start = [System.DateTimeOffset]::UtcNow
                }

                $errorRecord = Get-TestAssertDateRangeError -DateRange $dateRange
                $errorRecord.TargetObject | Should -BeExactly $dateRange
            }
        }
        #endregion

        #region Invalid values
        Context 'Invalid values' {

            It 'Throws DateRangeInvalidStart when Start is null' {

                $dateRange = [PSCustomObject]@{
                    Start = $null
                    End   = [System.DateTimeOffset]::UtcNow
                }

                $errorRecord = Get-TestAssertDateRangeError -DateRange $dateRange
                $errorRecord | Should -Not -BeNullOrEmpty

                $errorRecord.FullyQualifiedErrorId | Should -BeLike 'DateRangeInvalidStart*'
            }

            It 'Throws DateRangeInvalidEnd when End is null' {

                $dateRange = [PSCustomObject]@{
                    Start = [System.DateTimeOffset]::UtcNow
                    End   = $null
                }

                $errorRecord = Get-TestAssertDateRangeError -DateRange $dateRange
                $errorRecord | Should -Not -BeNullOrEmpty

                $errorRecord.FullyQualifiedErrorId | Should -BeLike 'DateRangeInvalidEnd*'
            }

            It 'Throws DateRangeInvalidStart when Start has the wrong type' {

                $dateRange = [PSCustomObject]@{
                    Start = '2026-08-01'
                    End   = [System.DateTimeOffset]::UtcNow
                }

                $errorRecord = Get-TestAssertDateRangeError -DateRange $dateRange
                $errorRecord | Should -Not -BeNullOrEmpty

                $errorRecord.FullyQualifiedErrorId | Should -BeLike 'DateRangeInvalidStart*'
            }

            It 'Throws DateRangeInvalidEnd when End has the wrong type' {

                $dateRange = [PSCustomObject]@{
                    Start = [System.DateTimeOffset]::UtcNow
                    End   = '2026-08-31'
                }

                $errorRecord = Get-TestAssertDateRangeError -DateRange $dateRange
                $errorRecord | Should -Not -BeNullOrEmpty

                $errorRecord.FullyQualifiedErrorId | Should -BeLike 'DateRangeInvalidEnd*'
            }

            It 'Uses the invalid Start value as TargetObject' {

                $invalidStart = '2026-08-01'

                $dateRange = [PSCustomObject]@{
                    Start = $invalidStart
                    End   = [System.DateTimeOffset]::UtcNow
                }

                $errorRecord = Get-TestAssertDateRangeError -DateRange $dateRange
                $errorRecord.TargetObject | Should -BeExactly $invalidStart
            }

            It 'Uses the invalid End value as TargetObject' {

                $invalidEnd = '2026-08-31'

                $dateRange = [PSCustomObject]@{
                    Start = [System.DateTimeOffset]::UtcNow
                    End   = $invalidEnd
                }

                $errorRecord = Get-TestAssertDateRangeError -DateRange $dateRange
                $errorRecord.TargetObject | Should -BeExactly $invalidEnd
            }
        }
        #endregion

        #region Error contract
        Context 'Error contract' {

            It 'Uses InvalidArgument for missing properties' {

                $dateRange = [PSCustomObject]@{
                    End = [System.DateTimeOffset]::UtcNow
                }

                $errorRecord = Get-TestAssertDateRangeError -DateRange $dateRange
                $errorRecord.CategoryInfo.Category |
                    Should -Be ([System.Management.Automation.ErrorCategory]::InvalidArgument)
            }

            It 'Uses InvalidArgument for invalid values' {

                $dateRange = [PSCustomObject]@{
                    Start = 'invalid'
                    End   = [System.DateTimeOffset]::UtcNow
                }

                $errorRecord = Get-TestAssertDateRangeError -DateRange $dateRange
                $errorRecord.CategoryInfo.Category |
                    Should -Be ([System.Management.Automation.ErrorCategory]::InvalidArgument)
            }
        }
        #endregion
    }
}
