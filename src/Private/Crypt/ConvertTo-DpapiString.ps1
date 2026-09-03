<#
.SYNOPSIS
Converts a SecureString to a DPAPI-encrypted string.

.DESCRIPTION
The result is bound to the current user and machine and is safe to
persist to disk. A SecureString encrypted on one machine cannot be
decrypted on another.

.PARAMETER Value
The SecureString to encrypt.

.OUTPUTS
System.String

.EXAMPLE
PS C:\> $secure = ConvertTo-SecureString 'mypassword' -AsPlainText -Force
>> $encrypted = ConvertTo-DpapiString -Value $secure
#>
function ConvertTo-DpapiString {
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [securestring]$Value
    )

    try {
        ConvertFrom-SecureString -SecureString $Value -ErrorAction Stop
    } catch {
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                $_.Exception,
                'DpapiEncryptFailed',
                [System.Management.Automation.ErrorCategory]::SecurityError,
                $Value
            )
        )
    }
}
