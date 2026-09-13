<#
.SYNOPSIS
Resolves the certificate path and encrypted password for a company update.

.DESCRIPTION
Determines whether to preserve the existing certificate or apply a new one
based on the parameters provided to Set-PipeCompany.

When CertPath is not in PSBoundParameters, the existing certificate is
preserved unchanged.

When CertPath is provided with CertPassword, Invoke-CertificateSetup
validates the certificate and encrypts the password via DPAPI.

When CertPath is provided without CertPassword, Invoke-CertificateSetup
requests the password interactively via Read-Host (up to 3 attempts).

.PARAMETER Bound
The PSBoundParameters dictionary from the calling cmdlet.

.PARAMETER CertPath
Path to the certificate file. May be null or empty when not supplied.

.PARAMETER CertPassword
Certificate password as SecureString. May be null when not supplied.

.PARAMETER Existing
The existing certificate object from the stored company configuration.
May be null when no certificate was previously configured.

.OUTPUTS
System.Management.Automation.PSCustomObject

  Path              [string] Resolved certificate file path.
  EncryptedPassword [string] DPAPI-encrypted certificate password.

.EXAMPLE
PS C:\> $certParams = @{
    Bound        = $PSBoundParameters
    CertPath     = $CertPath
    CertPassword = $CertPassword
    Existing     = $existing.Certificado
}

PS C:\> $resolved = Resolve-CompanyCertificate @certParams

.NOTES
Private dependencies:
  Invoke-CertificateSetup
#>
function Resolve-CompanyCertificate {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Bound,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$CertPath,

        [Parameter()]
        [AllowNull()]
        [System.Security.SecureString]$CertPassword,

        [Parameter(Mandatory)]
        [AllowNull()]
        [pscustomobject]$Existing
    )

    $existingPath = if ($null -ne $Existing) {
        $Existing.Path
    } else {
        $null
    }

    $existingPassword = if ($null -ne $Existing) {
        $Existing.EncryptedPassword
    } else {
        $null
    }

    if (-not $Bound.ContainsKey('CertPath')) {
        return [PSCustomObject]@{
            Path              = $existingPath
            EncryptedPassword = $existingPassword
        }
    }

    if (-not (Test-Path -LiteralPath $CertPath -PathType Leaf)) {
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                [System.IO.FileNotFoundException]::new(
                    "Certificate file not found: '$CertPath'"
                ),
                'CertNotFound',
                [System.Management.Automation.ErrorCategory]::ObjectNotFound,
                $CertPath
            )
        )
    }

    $certSetupParams = @{
        Path = $CertPath
    }

    if ($Bound.ContainsKey('CertPassword')) {
        $certSetupParams['Password'] = $CertPassword
    }

    $certSetup = Invoke-CertificateSetup @certSetupParams

    [PSCustomObject]@{
        Path              = $CertPath
        EncryptedPassword = $certSetup.EncryptedPassword
    }
}
