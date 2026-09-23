<#
.SYNOPSIS
Converts a DFe numeric XML value to System.Decimal.

.DESCRIPTION
Parses decimal values from DFe XML using invariant culture.

DFe numeric values use "." as the decimal separator and must never depend
on the operating system regional settings.

Returns no output for null, empty, or whitespace input.

Invalid non-empty values throw a terminating InvalidDFeDecimal error.

.PARAMETER Value
Raw numeric value extracted from a DFe XML field.

.OUTPUTS
System.Decimal
  Parsed decimal value. No output is returned when Value is null, empty,
  or whitespace.
#>
function ConvertFrom-DFeDecimal {
    [CmdletBinding()]
    [OutputType([decimal])]
    param (
        [Parameter(ValueFromPipeline)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Value
    )

    process {
        if ([string]::IsNullOrWhiteSpace($Value)) {
            return
        }

        $parsed = [decimal]0

        $numberStyles = (
            [System.Globalization.NumberStyles]::AllowLeadingSign -bor
            [System.Globalization.NumberStyles]::AllowDecimalPoint
        )

        $success = [decimal]::TryParse(
            $Value.Trim(),
            $numberStyles,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [ref]$parsed
        )

        if (-not $success) {
            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.FormatException]::new(
                        "Invalid DFe decimal value '$Value'."
                    ),
                    'InvalidDFeDecimal',
                    [System.Management.Automation.ErrorCategory]::InvalidData,
                    $Value
                )
            )
        }

        $parsed
    }
}
