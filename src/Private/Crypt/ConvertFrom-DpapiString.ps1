<#
.SYNOPSIS
    Converts a PipeDFe DPAPI-encrypted string back into a SecureString.

.DESCRIPTION
Supports two formats:

1. New machine-scoped format:

    DPAPI-MACHINE:<base64-payload>

    This format is decryptable by any security principal that can access
    the machine DPAPI key.

2. Legacy PipeDFe format:

    <DPAPI payload without explicit prefix>

    Legacy values are delegated to ConvertTo-SecureString and therefore
    remain bound to the user and machine that originally created them.

Legacy values are intentionally not silently migrated. Migration must be
an explicit operational action so that a backup and recovery procedure
can be performed before changing the cryptographic binding.

DPAPI is Windows-only. This function assumes the module has already
enforced platform requirements at load time (psm1 throws on non-Windows).
The platform guards inside this function are intentionally kept as a
defence-in-depth measure for future Linux porting work.

.PARAMETER Value
The encrypted value.

.OUTPUTS
System.Security.SecureString

.EXAMPLE
PS C:\> $secure = ConvertFrom-DpapiString -Value $encrypted

.NOTES
Private dependencies:
  None.
#>

Add-Type -AssemblyName 'System.Security'

function ConvertFrom-DpapiString {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSAvoidUsingConvertToSecureStringWithPlainText',
        '',
        Justification = 'Legacy DPAPI format passes an opaque encrypted blob, not plain text.'
    )]
    [CmdletBinding()]
    [OutputType([System.Security.SecureString])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Value
    )

    $encryptedBytes = $null
    $plainBytes     = $null
    $plainText      = $null

    try {
        if ($Value.StartsWith('DPAPI-MACHINE:', [System.StringComparison]::Ordinal)) {
            # TODO: remove this guard when Linux support is implemented.
            # The psm1 already throws on non-Windows, so this is dead code
            # for now -- kept as defence-in-depth for the future port.
            if (-not $Script:IsWindowsPlatform) {
                throw [System.PlatformNotSupportedException]::new(
                    'Machine-scoped DPAPI is only supported on Windows.'
                )
            }

            $payload = $Value.Substring('DPAPI-MACHINE:'.Length)

            if ([string]::IsNullOrWhiteSpace($payload)) {
                throw [System.Security.SecurityException]::new(
                    'The machine-scoped DPAPI payload is empty.'
                )
            }

            try {
                $encryptedBytes = [System.Convert]::FromBase64String($payload)
            } catch {
                throw [System.Security.SecurityException]::new(
                    'The machine-scoped DPAPI payload is not valid Base64.',
                    $_.Exception
                )
            }

            $plainBytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
                $encryptedBytes,
                $null,
                [System.Security.Cryptography.DataProtectionScope]::LocalMachine
            )

            if ($null -eq $plainBytes) {
                throw [System.Security.SecurityException]::new(
                    'DPAPI returned an empty plaintext value.'
                )
            }

            $plainText = [System.Text.Encoding]::UTF8.GetString($plainBytes)

            ConvertTo-SecureString -String $plainText -AsPlainText -Force

        } else {
            # Legacy PipeDFe format.
            #
            # Preserves the previous behavior intentionally. The legacy payload
            # is user-scoped DPAPI and can only be decrypted by the original
            # user on the original machine.
            ConvertTo-SecureString -String $Value -ErrorAction Stop
        }

    } catch {
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                [System.Security.SecurityException]::new(
                    'Failed to decrypt the secret with DPAPI.',
                    $_.Exception
                ),
                'DpapiDecryptFailed',
                [System.Management.Automation.ErrorCategory]::SecurityError,
                $Value
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
