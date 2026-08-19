<#
.SYNOPSIS
Handles certificate validation and password encryption for company setup.

.DESCRIPTION
Validates the certificate file and returns the DPAPI-encrypted password
and expiration date.

When -Password is omitted, requests the certificate password interactively
via Read-Host, allowing up to 3 attempts before aborting with a terminating
error. When -Password is supplied, it is used directly without prompting.

Throws InvalidCertificate if the certificate cannot be loaded after all
attempts, or if the supplied password produces an invalid result.
Throws ExpiredCertificate if the certificate is expired.

Used by New-PipeCompany and Set-PipeCompany to avoid logic duplication.

.PARAMETER Path
Full path to the certificate file (.pfx, .p12).

.PARAMETER Password
Optional certificate password as a SecureString. When provided, the
interactive prompt is skipped entirely.

.OUTPUTS
System.Management.Automation.PSCustomObject

EncryptedPassword [string]         DPAPI-encrypted certificate password.
ExpiresOn         [DateTimeOffset] Certificate expiration date.

.EXAMPLE
PS C:\> $result = Invoke-CertificateSetup -Path 'C:\certs\empresa.pfx'

.EXAMPLE
PS C:\> $result = Invoke-CertificateSetup
>> -Path 'C:\certs\empresa.pfx' -Password $secure
#>
function Invoke-CertificateSetup {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter()]
        [ValidateNotNull()]
        [System.Security.SecureString]$Password
    )

    $certResult     = $null
    $securePassword = $null

    if ($PSBoundParameters.ContainsKey('Password')) {
        $securePassword = $Password
        $certResult     = Test-CertificateFile -Path $Path -Password $securePassword
    } else {
        $maxAttempts = 3

        for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
            $prompt = if ($attempt -eq 1) {
                'Senha'
            } else {
                "Senha (tentativa $attempt de $maxAttempts)"
            }

            $securePassword = Read-Host -Prompt $prompt -AsSecureString
            $certResult     = Test-CertificateFile -Path $Path -Password $securePassword

            if ($certResult.IsValid) {
                break
            }

            if ($attempt -lt $maxAttempts) {
                Write-Warning -Message 'Certificado inválido ou senha incorreta. Tente novamente.'
            }
        }
    }

    if (-not $certResult.IsValid) {
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                [System.ArgumentException]::new(
                    'Certificado inválido ou senha incorreta.'
                ),
                'InvalidCertificate',
                [System.Management.Automation.ErrorCategory]::InvalidArgument,
                $Path
            )
        )
    }

    if ($certResult.IsExpired) {
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                [System.ArgumentException]::new(
                    "Certificado vencido desde: $($certResult.ExpiresOn)"
                ),
                'ExpiredCertificate',
                [System.Management.Automation.ErrorCategory]::InvalidArgument,
                $Path
            )
        )
    }

    [PSCustomObject]@{
        EncryptedPassword = ConvertTo-DpapiString -Value $securePassword
        ExpiresOn         = $certResult.ExpiresOn
    }
}
