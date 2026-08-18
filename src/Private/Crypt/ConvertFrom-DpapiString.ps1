<#
.SYNOPSIS
Converts a DPAPI-encrypted string back into a SecureString.

.DESCRIPTION
The value must have been encrypted by the same user on the same machine.
The caller is responsible for extracting plain text when required, using
System.Net.NetworkCredential or equivalent.

.PARAMETER Value
The DPAPI-encrypted string to decrypt.

.OUTPUTS
System.Security.SecureString

.EXAMPLE
PS C:\> $secure = ConvertFrom-DpapiString -Value $encrypted
#>
function ConvertFrom-DpapiString {
    [CmdletBinding()]
    [OutputType([securestring])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Value
    )

    try {
        ConvertTo-SecureString -String $Value -ErrorAction Stop
    } catch {
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                $_.Exception,
                'DpapiDecryptFailed',
                [System.Management.Automation.ErrorCategory]::SecurityError,
                $Value
            )
        )
    }
}
