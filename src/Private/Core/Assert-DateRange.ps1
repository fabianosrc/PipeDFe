<#
.SYNOPSIS
Validates a DateRange object.

.DESCRIPTION
Ensures that DateRange exposes Start and End properties, that both
values are DateTimeOffset instances, and that End is not earlier than Start.

Throws a terminating error on the calling command when validation fails.

.PARAMETER DateRange
Object to validate.

.PARAMETER CallerPSCmdlet
The $PSCmdlet instance from the calling function.

.OUTPUTS
None.

.EXAMPLE
PS C:\> Assert-DateRange -DateRange $dateRange -CallerPSCmdlet $PSCmdlet

.NOTES
Pure validation helper. Produces no output and performs no I/O.
#>
function Assert-DateRange {
    [CmdletBinding()]
    [OutputType([void])]
    param (
        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$DateRange,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [System.Management.Automation.PSCmdlet]$CallerPSCmdlet
    )

    foreach ($propertyName in @('Start', 'End')) {
        $property = if ($null -ne $DateRange) {
            $DateRange.PSObject.Properties[$propertyName]
        }

        if ($null -eq $property) {
            $CallerPSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.ArgumentException]::new(
                        "DateRange is missing the required '$propertyName' property."
                    ),
                    "DateRangeMissing$propertyName",
                    [System.Management.Automation.ErrorCategory]::InvalidArgument,
                    $DateRange
                )
            )
        }

        $value = $property.Value

        if ($value -isnot [System.DateTimeOffset]) {
            $actualType = if ($null -eq $value) {
                '<null>'
            } else {
                $value.GetType().FullName
            }

            $CallerPSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.ArgumentException]::new(
                        "DateRange.$propertyName must be a DateTimeOffset. Got: $actualType"
                    ),
                    "DateRangeInvalid$propertyName",
                    [System.Management.Automation.ErrorCategory]::InvalidArgument,
                    $value
                )
            )
        }
    }

    if ($DateRange.End -lt $DateRange.Start) {
        $startRange = $DateRange.Start.ToString('yyyy-MM-dd')
        $endRange   = $DateRange.End.ToString('yyyy-MM-dd')

        $errorMessage = "DateRange.End ($endRange) must not be earlier than DateRange.Start ($startRange)."

        $CallerPSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                [System.ArgumentException]::new($errorMessage),
                'DateRangeEndBeforeStart',
                [System.Management.Automation.ErrorCategory]::InvalidArgument,
                $DateRange
            )
        )
    }
}
