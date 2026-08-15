<#
.SYNOPSIS
Converts a date/time string to a DateTimeOffset normalized to UTC.

.DESCRIPTION
Parses a date/time string using the predefined set of supported formats and
returns the result as a DateTimeOffset in UTC.

When no UTC offset is present in the input, the local system offset is
assumed. The result is always returned in UTC regardless of the input offset.

Throws a terminating error with ErrorId 'UnsupportedDateFormat' when the
input does not match any supported format.

.PARAMETER Value
The date/time string to convert.

.OUTPUTS
System.DateTimeOffset

.EXAMPLE
PS C:\> ConvertTo-DateTimeOffset -Value '2026-08-01'

Returns the parsed date normalized to UTC using the local system offset.

.EXAMPLE
PS C:\> ConvertTo-DateTimeOffset -Value '01/08/2026 14:30:00'

Returns the parsed date/time normalized to UTC using the local system offset.

.EXAMPLE
PS C:\> ConvertTo-DateTimeOffset -Value '2026-08-01T14:30:00-03:00'

Returns 2026-08-01 17:30:00 +00:00 (UTC).

.NOTES
Pure function - no I/O, no side effects.

Private dependencies:
  DateTimeOffsetFormats (module-scoped)
#>
function ConvertTo-DateTimeOffset {
    [CmdletBinding()]
    [OutputType([System.DateTimeOffset])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Value
    )

    foreach ($entry in $Script:DateTimeOffsetFormats) {
        $parsed = [System.DateTimeOffset]::MinValue

        if ([System.DateTimeOffset]::TryParseExact(
                $Value,
                $entry.Format,
                $entry.Culture,
                $entry.Styles,
                [ref]$parsed
            )
        ) {
            return $parsed.ToUniversalTime()
        }
    }

    $PSCmdlet.ThrowTerminatingError(
        [System.Management.Automation.ErrorRecord]::new(
            [System.FormatException]::new("Unsupported date format: '$Value'."),
            'UnsupportedDateFormat',
            [System.Management.Automation.ErrorCategory]::InvalidArgument,
            $Value
        )
    )
}
