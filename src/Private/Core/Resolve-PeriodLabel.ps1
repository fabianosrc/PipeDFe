<#
.SYNOPSIS
Resolves period label strings for e-mail subject and body.

.DESCRIPTION
Returns a structured object with two period label formats derived from a
DateRange object.

Title - used in the e-mail subject line:
  Full month   : 'JUNHO/2026'
  Partial range: '01/06/2026 a 15/06/2026'

Body - used in the e-mail body (always a full date range):
  Full month   : '01/06/2026 a 30/06/2026'
  Partial range: '01/06/2026 a 15/06/2026'

A range is considered a full calendar month when Start falls on the first
day of the month, End falls on the last calendar day of the same month,
and both belong to the same month and year. Time-of-day is ignored.

Throws a terminating error via Assert-DateRange when DateRange is missing
Start or End, or when either value is not a DateTimeOffset.

.PARAMETER DateRange
PSCustomObject containing:
  Start [DateTimeOffset]
  End   [DateTimeOffset]

.OUTPUTS
System.Management.Automation.PSCustomObject

Title [string] Period label for the e-mail subject line.
Body  [string] Period label for the e-mail body.

.EXAMPLE
PS C:\> $range = [PSCustomObject]@{
    Start = [System.DateTimeOffset]::new(
        2026, 6,  1, 0, 0, 0, [System.TimeSpan]::Zero
    )
    End   = [System.DateTimeOffset]::new(
        2026, 6, 30, 0, 0, 0, [System.TimeSpan]::Zero
    )
}

PS C:\> $label = Resolve-PeriodLabel -DateRange $range
PS C:\> $label.Title  # JUNHO/2026
PS C:\> $label.Body   # 01/06/2026 a 30/06/2026

.EXAMPLE
PS C:\> $range = [PSCustomObject]@{
    Start = [System.DateTimeOffset]::new(
        2026, 6,  1, 0, 0, 0, [System.TimeSpan]::Zero
    )
    End   = [System.DateTimeOffset]::new(
        2026, 6, 15, 0, 0, 0, [System.TimeSpan]::Zero
    )
}

PS C:\> $label = Resolve-PeriodLabel -DateRange $range
PS C:\> $label.Title  # 01/06/2026 a 15/06/2026
PS C:\> $label.Body   # 01/06/2026 a 15/06/2026

.NOTES
Pure function - no I/O, no side effects.

Private dependencies:
  Assert-DateRange
#>
function Resolve-PeriodLabel {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject]$DateRange
    )

    Assert-DateRange -DateRange $DateRange -CallerPSCmdlet $PSCmdlet

    $start = $DateRange.Start
    $end   = $DateRange.End

    $lastDayOfMonth = [System.DateTime]::DaysInMonth($start.Year, $start.Month)

    $isFullMonth = (
        $start.Year  -eq $end.Year  -and
        $start.Month -eq $end.Month -and
        $start.Day   -eq 1          -and
        $end.Day     -eq $lastDayOfMonth
    )

    $culture   = [System.Globalization.CultureInfo]::GetCultureInfo('pt-BR')
    $startDate = $start.ToString('dd/MM/yyyy', $culture)
    $endDate   = $end.ToString('dd/MM/yyyy',   $culture)
    $bodyLabel = '{0} a {1}' -f $startDate, $endDate

    $titleLabel = if ($isFullMonth) {
        $start.ToString('MMMM/yyyy', $culture).ToUpper($culture)
    } else {
        $bodyLabel
    }

    [PSCustomObject]@{
        Title = $titleLabel
        Body  = $bodyLabel
    }
}
