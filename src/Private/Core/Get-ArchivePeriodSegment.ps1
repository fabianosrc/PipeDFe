<#
.SYNOPSIS
Resolves the period segment of a ZIP archive file name.

.DESCRIPTION
Returns 'yyyyMM' when the date range covers an exact calendar month,
or 'yyyyMMdd_yyyyMMdd' for partial or multi-month ranges.

A range is considered a full calendar month when Start falls on the 1st,
End falls on the last calendar day of the same month and both belong to
the same month and year. Time-of-day is ignored.

Throws a terminating error via Assert-DateRange when DateRange is missing
Start or End, or when either value is not a DateTimeOffset.

.PARAMETER DateRange
PSCustomObject containing:
  Start [DateTimeOffset]
  End   [DateTimeOffset]

.OUTPUTS
System.String

Full month   : 'yyyyMM'            (e.g. '202605')
Partial range: 'yyyyMMdd_yyyyMMdd' (e.g. '20260501_20260515')

.EXAMPLE
PS C:\> Get-ArchivePeriodSegment -DateRange $range

Returns '202605' when the range covers the full month of May 2026.

.NOTES
Pure function - no I/O, no side effects.

Private dependencies:
  Assert-DateRange
#>
function Get-ArchivePeriodSegment {
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject]$DateRange
    )

    Assert-DateRange -DateRange $DateRange -CallerPSCmdlet $PSCmdlet

    $start = $DateRange.Start
    $end   = $DateRange.End

    $daysInMonth = [System.DateTime]::DaysInMonth($start.Year, $start.Month)

    $isFullMonth = (
        $start.Year  -eq $end.Year     -and
        $start.Month -eq $end.Month    -and
        $start.Day   -eq 1             -and
        $end.Day     -eq $daysInMonth
    )

    if ($isFullMonth) {
        $start.ToString('yyyyMM')
    } else {
        '{0}_{1}' -f $start.ToString('yyyyMMdd'), $end.ToString('yyyyMMdd')
    }
}
