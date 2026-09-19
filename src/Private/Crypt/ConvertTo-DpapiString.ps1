<#
.SYNOPSIS
Converts a SecureString to a DPAPI-encrypted string.

.DESCRIPTION
Encrypts the supplied SecureString using Windows DPAPI with machine scope.

The resulting value is bound to the current machine rather than to the
interactive user. This allows unattended executions, such as Windows Task
Scheduler jobs running under a service account or SYSTEM, to decrypt
secrets that were provisioned for the same machine.

The returned value contains an explicit format prefix:

DPAPI-MACHINE:<payload>

This prefix allows PipeDFe to distinguish the new machine-scoped format
from the legacy format produced by ConvertFrom-SecureString without an
explicit key.

DPAPI is Windows-only. This function assumes the module has already
enforced platform requirements at load time (psm1 throws on non-Windows).
The platform guard inside this function is intentionally kept as a
defence-in-depth measure for future Linux porting work.

.PARAMETER SecureString
The SecureString to encrypt.

.OUTPUTS
System.String

.EXAMPLE
PS C:\> $secure = ConvertTo-SecureString 'mypassword' -AsPlainText -Force

PS C:\> ConvertTo-DpapiString -SecureString $secure

Returns a machine-scoped DPAPI payload.

.NOTES
Private dependencies:
  None.
#>
function ConvertTo-DpapiString {
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [System.Security.SecureString]$SecureString
    )

    $plainText      = $null
    $plainBytes     = $null
    $encryptedBytes = $null

    try {
        # TODO: remove when Linux support is implemented.
        # The psm1 already throws on non-Windows, so this is dead code
        # for now -- kept as defence-in-depth for the future port.
        if (-not $Script:IsWindowsPlatform) {
            throw [System.PlatformNotSupportedException]::new(
                'DPAPI is only supported on Windows.'
            )
        }

        $plainText = [System.Net.NetworkCredential]::new(
            [string]::Empty,
            $SecureString
        ).Password

        if ($null -eq $plainText) {
            throw [System.Security.SecurityException]::new(
                'Unable to extract the SecureString for DPAPI encryption.'
            )
        }

        $plainBytes = [System.Text.Encoding]::UTF8.GetBytes($plainText)

        $encryptedBytes = [System.Security.Cryptography.ProtectedData]::Protect(
            $plainBytes,
            $null,
            [System.Security.Cryptography.DataProtectionScope]::LocalMachine
        )

        if ($null -eq $encryptedBytes -or $encryptedBytes.Length -eq 0) {
            throw [System.Security.SecurityException]::new(
                'DPAPI encryption returned an empty value.'
            )
        }

        $payload = [System.Convert]::ToBase64String($encryptedBytes)

        if ([string]::IsNullOrWhiteSpace($payload)) {
            throw [System.Security.SecurityException]::new(
                'DPAPI encryption returned an empty payload.'
            )
        }

        'DPAPI-MACHINE:{0}' -f $payload

    } catch {
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                [System.Security.SecurityException]::new(
                    'Failed to encrypt the secret with machine-scoped DPAPI.',
                    $_.Exception
                ),
                'DpapiEncryptFailed',
                [System.Management.Automation.ErrorCategory]::SecurityError,
                $SecureString
            )
        )

    } finally {
        if ($null -ne $plainBytes) {
            [System.Array]::Clear($plainBytes, 0, $plainBytes.Length)
        }

        if ($null -ne $encryptedBytes) {
            [System.Array]::Clear($encryptedBytes, 0, $encryptedBytes.Length)
        }

        $plainText      = $null
        $plainBytes     = $null
        $encryptedBytes = $null
    }
}
