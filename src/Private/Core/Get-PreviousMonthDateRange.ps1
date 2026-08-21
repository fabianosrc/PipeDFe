<#
.SYNOPSIS
Returns the date range boundaries of the previous calendar month.

.DESCRIPTION
Calculates the start and end boundaries of the previous calendar month
relative to the current local date and time.

Start is set to the first whole second of the first day (00:00:00).
End is set to the last whole second of the last day (23:59:59).

Both values are returned as DateTimeOffset instances using the local
system timezone offset applicable to each boundary. This ensures correct
behavior across daylight saving time transitions.

.OUTPUTS
System.Management.Automation.PSCustomObject

Start [System.DateTimeOffset]
    First whole second of the previous month (00:00:00).

End [System.DateTimeOffset]
    Last whole second of the previous month (23:59:59).

.EXAMPLE
PS C:\> Get-PreviousMonthDateRange

Start : 2026-07-01T00:00:00-03:00
End   : 2026-07-31T23:59:59-03:00

.NOTES
No I/O or side effects.
The result depends on the current system date/time and local timezone.
#>
function Get-PreviousMonthDateRange {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param ()

    $now      = [System.DateTimeOffset]::Now
    $timeZone = [System.TimeZoneInfo]::Local

    $firstOfCurrentMonth = [System.DateTime]::new(
        $now.Year,
        $now.Month,
        1,
        0,
        0,
        0,
        [System.DateTimeKind]::Unspecified
    )

    $firstOfPreviousMonth = $firstOfCurrentMonth.AddMonths(-1)

    $daysInMonth = [System.DateTime]::DaysInMonth(
        $firstOfPreviousMonth.Year,
        $firstOfPreviousMonth.Month
    )

    $lastOfPreviousMonth = [System.DateTime]::new(
        $firstOfPreviousMonth.Year,
        $firstOfPreviousMonth.Month,
        $daysInMonth,
        23,
        59,
        59,
        [System.DateTimeKind]::Unspecified
    )

    $startOffset = $timeZone.GetUtcOffset($firstOfPreviousMonth)
    $endOffset   = $timeZone.GetUtcOffset($lastOfPreviousMonth)

    [PSCustomObject]@{
        Start = [System.DateTimeOffset]::new($firstOfPreviousMonth, $startOffset)
        End   = [System.DateTimeOffset]::new($lastOfPreviousMonth, $endOffset)
    }
}
