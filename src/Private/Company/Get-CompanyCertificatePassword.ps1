<#
.SYNOPSIS
Returns the certificate password for a company as a SecureString.

.DESCRIPTION
Decrypts the DPAPI-encrypted certificate password stored in a company
object and returns it as a SecureString.

This is the only sanctioned way to access Certificado.EncryptedPassword
at runtime. Never use $company.Certificado.EncryptedPassword directly -
it is a DPAPI blob, not a usable password.

Returns null if the company has no certificate configured.

Note: DPAPI encryption is bound to the current user and machine.
The password can only be decrypted by the same user on the same machine
that encrypted it.

.PARAMETER Company
The company object returned by Get-CompanyConfig.

.OUTPUTS
System.Security.SecureString

.EXAMPLE
PS C:\> $password = Get-CompanyCertificatePassword -Company $company

.NOTES
Private dependencies:
  ConvertFrom-DpapiString
#>
function Get-CompanyCertificatePassword {
    [CmdletBinding()]
    [OutputType([System.Security.SecureString])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject]$Company
    )

    $cert = $Company.Certificado

    if ($null -eq $cert -or [string]::IsNullOrWhiteSpace($cert.EncryptedPassword)) {
        return $null
    }

    ConvertFrom-DpapiString -Value $cert.EncryptedPassword
}
