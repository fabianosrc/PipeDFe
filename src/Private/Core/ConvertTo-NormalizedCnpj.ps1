<#
.SYNOPSIS
Removes formatting characters from a CNPJ string.

.DESCRIPTION
Removes supported formatting characters from a CNPJ string and converts
it to uppercase, returning exactly 14 ASCII alphanumeric characters.

Supports both standard numeric and alphanumeric CNPJ formats (RFB 2026).

Only '.', '/', and '-' are treated as formatting characters.
Other characters are rejected.

Does not validate the CNPJ check digits - use Test-Cnpj for validation.

Throws CnpjContainsUnsupportedCharacters when unsupported characters
are present.

Throws CnpjInvalidLength when the normalized value does not contain
exactly 14 characters.

.PARAMETER Value
The CNPJ string to normalize. Accepts pipeline input.

.OUTPUTS
System.String

.EXAMPLE
PS C:\> ConvertTo-NormalizedCnpj -Value '00.000.000/0001-00'

.EXAMPLE
PS C:\> '00.000.000/0001-00', '11.111.111/0001-11' | ConvertTo-NormalizedCnpj

.NOTES
Pure function - no I/O, no side effects.
#>
function ConvertTo-NormalizedCnpj {
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()]
        [string]$Value
    )

    process {
        $normalized = $Value.ToUpperInvariant()

        # Remove only supported formatting characters.
        $normalized = $normalized -replace '[./-]', ''

        # Reject values that become empty after removing formatting.
        if ([string]::IsNullOrEmpty($normalized)) {
            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.ArgumentException]::new(
                        'CNPJ cannot be empty after normalization.'
                    ),
                    'NormalizedCnpjEmpty',
                    [System.Management.Automation.ErrorCategory]::InvalidArgument,
                    $Value
                )
            )
        }

        # Reject anything other than ASCII uppercase letters and digits.
        if ($normalized -notmatch '^[0-9A-Z]+$') {
            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.ArgumentException]::new(
                        'CNPJ contains unsupported characters.'
                    ),
                    'CnpjContainsUnsupportedCharacters',
                    [System.Management.Automation.ErrorCategory]::InvalidArgument,
                    $Value
                )
            )
        }

        if ($normalized.Length -ne 14) {
            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.ArgumentException]::new(
                        'CNPJ must contain exactly 14 characters after normalization.'
                    ),
                    'CnpjInvalidLength',
                    [System.Management.Automation.ErrorCategory]::InvalidArgument,
                    $Value
                )
            )
        }

        $normalized
    }
}
