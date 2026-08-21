<#
.SYNOPSIS
Formats a normalized CNPJ using the standard mask.

.DESCRIPTION
Formats a normalized 14-character CNPJ into the standard
XX.XXX.XXX/XXXX-XX representation.

The input must contain exactly 14 uppercase alphanumeric characters.
This function does not validate CNPJ check digits. Use Test-Cnpj
for semantic validation.

.PARAMETER Value
A normalized CNPJ containing exactly 14 uppercase alphanumeric
characters (0-9 and A-Z).

.OUTPUTS
System.String

.EXAMPLE
ConvertTo-FormattedCnpj -Value '00000000000100'
Returns: 00.000.000/0001-00

.EXAMPLE
'00000000000100', 'AB1CD2EF3GH4I5' | ConvertTo-FormattedCnpj
Returns:
00.000.000/0001-00
AB.1CD.2EF/3GH4-I5

.NOTES
Pure function.
No I/O, external dependencies, or side effects.
#>
function ConvertTo-FormattedCnpj {
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()]
        [ValidatePattern('(?-i)^[0-9A-Z]{14}$')]
        [string]$Value
    )

    process {
        $parts = @(
            $Value.Substring( 0, 2)
            $Value.Substring( 2, 3)
            $Value.Substring( 5, 3)
            $Value.Substring( 8, 4)
            $Value.Substring(12, 2)
        )

        '{0}.{1}.{2}/{3}-{4}' -f $parts
    }
}
