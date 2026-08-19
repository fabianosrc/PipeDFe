<#
.SYNOPSIS
Tests whether a certificate file can be loaded with the given password.

.DESCRIPTION
Validates that the specified certificate file exists and that the provided
password is correct. Returns a structured object with validity, valid from
date, expiration date, expiration status, thumbprint, and raw Subject and
Issuer DN strings.

Never throws - returns IsValid = false for any failure.
The certificate is loaded into memory only for validation and immediately
disposed.

Certificates without a private key are considered invalid. A1 certificates
used for DFe signing must include a private key.

When EphemeralKeySet fails, falls back to UserKeySet. This fallback may
persist the private key in the Windows user key store as a side effect.
The caller should be aware of this when handling legacy CSP certificates.

Subject and Issuer are returned as raw DN strings. Parsing is the
caller's responsibility.

.PARAMETER Path
Full path to the certificate file (.pfx, .p12).

.PARAMETER Password
The certificate password as a SecureString.

.OUTPUTS
System.Management.Automation.PSCustomObject

IsValid    [bool]           Whether the certificate loaded successfully.
IsExpired  [bool]           Whether the certificate is expired.
ValidFrom  [DateTimeOffset] Certificate start date.
ExpiresOn  [DateTimeOffset] Certificate expiration date.
Thumbprint [string]         Certificate thumbprint.
Subject    [string]         Raw certificate subject DN string.
Issuer     [string]         Raw certificate issuer DN string.

.EXAMPLE
PS C:\> Test-CertificateFile -Path 'C:\certs\empresa.pfx' -Password $securePassword
#>
function Test-CertificateFile {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [System.Security.SecureString]$Password
    )

    $invalid = [PSCustomObject]@{
        IsValid    = $false
        IsExpired  = $null
        ValidFrom  = $null
        ExpiresOn  = $null
        Thumbprint = $null
        Subject    = $null
        Issuer     = $null
    }

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $invalid
    }

    $cert = $null

    try {
        try {
            $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new(
                $Path,
                $Password,
                [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet
            )
        } catch {
            # EphemeralKeySet is not supported by some legacy CSP-based A1
            # certificates. UserKeySet may persist the key in the Windows
            # user key store as a side effect.
            $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new(
                $Path,
                $Password,
                [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::UserKeySet
            )
        }

        if (-not $cert.HasPrivateKey) {
            return $invalid
        }

        $validFrom = [System.DateTimeOffset]$cert.NotBefore
        $expiresOn = [System.DateTimeOffset]$cert.NotAfter
        $now       = [System.DateTimeOffset]::UtcNow

        [PSCustomObject]@{
            IsValid    = $true
            IsExpired  = $expiresOn.ToUniversalTime() -lt $now
            ValidFrom  = $validFrom
            ExpiresOn  = $expiresOn
            Thumbprint = $cert.Thumbprint
            Subject    = $cert.Subject
            Issuer     = $cert.Issuer
        }
    } catch {
        $invalid
    } finally {
        if ($null -ne $cert) {
            $cert.Dispose()
        }
    }
}
