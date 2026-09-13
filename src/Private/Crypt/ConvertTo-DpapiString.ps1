<#
.SYNOPSIS
Converts a SecureString to a DPAPI-encrypted string.

.DESCRIPTION
The result is bound to the current user and machine and is safe to
persist to disk. A SecureString encrypted on one machine cannot be
decrypted on another.

.PARAMETER SecureString
The SecureString to encrypt.

.OUTPUTS
System.String

.EXAMPLE
PS C:\> $secure    = ConvertTo-SecureString 'mypassword' -AsPlainText -Force
PS C:\> $encrypted = ConvertTo-DpapiString -SecureString $secure
#>
function ConvertTo-DpapiString {
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [System.Security.SecureString]$SecureString
    )

    try {
        $encrypted = ConvertFrom-SecureString -SecureString $SecureString

        if ([string]::IsNullOrWhiteSpace($encrypted)) {
            throw [System.Security.SecurityException]::new(
                'DPAPI encryption returned an empty value.'
            )
        }

        $encrypted
    } catch {
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                [System.Security.SecurityException]::new(
                    'Failed to encrypt the SMTP password with DPAPI.',
                    $_.Exception
                ),
                'DpapiEncryptFailed',
                [System.Management.Automation.ErrorCategory]::SecurityError,
                $SecureString
            )
        )
    }
}
