<#
.SYNOPSIS
Resolves and normalizes a date range for use in queries and filters.

.DESCRIPTION
Returns a normalized date range as a PSCustomObject with Start and End
DateTimeOffset values.

Resolution rules:
  - No parameters: defaults to the previous calendar month via
    Get-PreviousMonthDateRange.
  - StartDate only: Start is normalized to 00:00:00 local time;
    End is set to the current moment.
  - StartDate and EndDate: Start is normalized to 00:00:00 local time;
    End is normalized to 23:59:59 local time, unless EndDate resolves
    to today, in which case End is set to the current moment.
  - EndDate only: throws EndDateWithoutStartDate - a range without a
    start is not defined.
  - StartDate later than EndDate: throws StartDateAfterEndDate.

Date strings are parsed by ConvertTo-DateTimeOffset. When an input contains
an explicit timezone offset, it is converted to the local system timezone
before its calendar date is extracted.

Normalized boundaries use the local system timezone offset applicable to
each boundary date. This ensures correct behavior across daylight saving
time transitions.

.PARAMETER StartDate
Optional start date string. Accepts any format supported by
ConvertTo-DateTimeOffset.

.PARAMETER EndDate
Optional end date string. Accepts any format supported by
ConvertTo-DateTimeOffset. Requires StartDate to be present.

.OUTPUTS
System.Management.Automation.PSCustomObject

Start [System.DateTimeOffset]
    Normalized start of the date range.

End [System.DateTimeOffset]
    Normalized end of the date range.

.EXAMPLE
PS C:\> Resolve-DateRange

Returns the previous calendar month range.

.EXAMPLE
PS C:\> Resolve-DateRange -StartDate '01/08/2026' -EndDate '31/08/2026'

Returns:
  Start = 2026-08-01 00:00:00 local time
  End   = 2026-08-31 23:59:59 local time

.EXAMPLE
PS C:\> Resolve-DateRange -StartDate '01/08/2026'

Returns the range from 2026-08-01 00:00:00 local time until the current moment.

.NOTES
No I/O or external side effects.

The result depends on the current system date/time and local timezone.

Private dependencies:
  ConvertTo-DateTimeOffset
  Get-PreviousMonthDateRange
#>
function Resolve-DateRange {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param (
        [Parameter()]
        [string]$StartDate,

        [Parameter()]
        [string]$EndDate
    )

    $hasStart = -not [string]::IsNullOrWhiteSpace($StartDate)
    $hasEnd   = -not [string]::IsNullOrWhiteSpace($EndDate)

    if (-not $hasStart -and -not $hasEnd) {
        return Get-PreviousMonthDateRange
    }

    if (-not $hasStart -and $hasEnd) {
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                [System.ArgumentException]::new(
                    '-StartDate is required when -EndDate is provided.'
                ),
                'EndDateWithoutStartDate',
                [System.Management.Automation.ErrorCategory]::InvalidArgument,
                $EndDate
            )
        )
    }

    $now      = [System.DateTimeOffset]::Now
    $timeZone = [System.TimeZoneInfo]::Local

    $startDateTimeOffset = ConvertTo-DateTimeOffset -Value $StartDate
    $startLocalDate      = $startDateTimeOffset.LocalDateTime.Date
    $startOffset         = $timeZone.GetUtcOffset($startLocalDate)

    $resolvedStart = [System.DateTimeOffset]::new($startLocalDate, $startOffset)

    if ($hasEnd) {
        $endDateTimeOffset = ConvertTo-DateTimeOffset -Value $EndDate
        $endLocalDate      = $endDateTimeOffset.LocalDateTime.Date

        if ($startLocalDate -gt $endLocalDate) {
            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.ArgumentException]::new(
                        '-StartDate cannot be greater than -EndDate.'
                    ),
                    'StartDateAfterEndDate',
                    [System.Management.Automation.ErrorCategory]::InvalidArgument,
                    $StartDate
                )
            )
        }

        if ($endLocalDate -eq $now.LocalDateTime.Date) {
            $resolvedEnd = $now
        } else {
            $endOffset = $timeZone.GetUtcOffset($endLocalDate)

            $resolvedEnd = [System.DateTimeOffset]::new(
                $endLocalDate.Year,
                $endLocalDate.Month,
                $endLocalDate.Day,
                23,
                59,
                59,
                $endOffset
            )
        }
    } else {
        $resolvedEnd = $now

        if ($resolvedStart -gt $resolvedEnd) {
            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.ArgumentException]::new(
                        '-StartDate cannot be greater than the current date and time.'
                    ),
                    'StartDateAfterEndDate',
                    [System.Management.Automation.ErrorCategory]::InvalidArgument,
                    $StartDate
                )
            )
        }
    }

    [PSCustomObject]@{
        Start = $resolvedStart
        End   = $resolvedEnd
    }
}
