<#
.SYNOPSIS
Converts an external value to a typed enum member.

.DESCRIPTION
Converts a string or numeric value to the specified enum type.

Named values are matched case-insensitively. Numeric values are converted
to the enum's underlying numeric type and accepted only when they correspond
to a defined enum member.

Throws InvalidEnumValue when the value is null, cannot be converted, or does
not correspond to a defined enum member.

.PARAMETER EnumType
The target enum type.

.PARAMETER Value
The value to convert. Accepts enum names and numeric values.

.OUTPUTS
System.Enum

.EXAMPLE
PS C:\> ConvertTo-EnumValue -EnumType ([Ambiente]) -Value 'Producao'

Returns the Producao enum member.

.EXAMPLE
PS C:\> ConvertTo-EnumValue -EnumType ([Ambiente]) -Value '1'

Returns the Producao enum member.

.EXAMPLE
PS C:\> ConvertTo-EnumValue -EnumType ([ModeloDFe]) -Value 55

Returns the NFe enum member.

.NOTES
Pure function - no I/O and no side effects.
#>
function ConvertTo-EnumValue {
    [CmdletBinding()]
    [OutputType([System.Enum])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [System.Type]$EnumType,

        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$Value
    )

    process {
        # Ensure the target type is actually an enum.
        if (-not $EnumType.IsEnum) {
            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.ArgumentException]::new(
                        "Type '$($EnumType.FullName)' is not an enum."
                    ),
                    'InvalidEnumType',
                    [System.Management.Automation.ErrorCategory]::InvalidArgument,
                    $EnumType
                )
            )
        }

        # Null is never a valid enum value.
        if ($null -eq $Value) {
            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.ArgumentException]::new(
                        "Value cannot be null for enum '$($EnumType.Name)'."
                    ),
                    'InvalidEnumValue',
                    [System.Management.Automation.ErrorCategory]::InvalidArgument,
                    $Value
                )
            )
        }

        $text = $Value.ToString().Trim()

        # Empty or whitespace-only values are invalid.
        if ([string]::IsNullOrWhiteSpace($text)) {
            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.ArgumentException]::new(
                        "Value cannot be empty for enum '$($EnumType.Name)'."
                    ),
                    'InvalidEnumValue',
                    [System.Management.Automation.ErrorCategory]::InvalidArgument,
                    $Value
                )
            )
        }

        $parsed = $null

        try {
            $parsed = [System.Enum]::Parse(
                $EnumType,
                $text,
                $true
            )
        } catch {
            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.ArgumentException]::new(
                        "Invalid value '$Value' for enum '$($EnumType.Name)'."
                    ),
                    'InvalidEnumValue',
                    [System.Management.Automation.ErrorCategory]::InvalidArgument,
                    $Value
                )
            )
        }

        # Enum.Parse() accepts undefined numeric values.
        # IsDefined() prevents values such as 999 from being silently accepted.
        if (-not [System.Enum]::IsDefined($EnumType, $parsed)) {
            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.ArgumentException]::new(
                        "Value '$Value' is not a defined member of enum '$($EnumType.Name)'."
                    ),
                    'InvalidEnumValue',
                    [System.Management.Automation.ErrorCategory]::InvalidArgument,
                    $Value
                )
            )
        }

        $parsed
    }
}
