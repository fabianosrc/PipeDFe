<#
.SYNOPSIS
Reads the global SMTP configuration.

.DESCRIPTION
Returns the SMTP configuration stored in smtp.json. The password field
is a DPAPI-encrypted blob and is not decrypted; it is returned as-is
so the caller can inspect metadata without triggering decryption.

Throws SmtpConfigNotFound when smtp.json does not exist.

.OUTPUTS
System.Management.Automation.PSCustomObject

  SchemaVersion [int]            - Schema version.
  Server        [string]         - SMTP server hostname.
  Port          [int]            - SMTP server port.
  Ssl           [bool]           - Whether SSL is enabled.
  Username      [string]         - SMTP authentication username.
  Password      [string]         - DPAPI-encrypted password blob.
  From          [pscustomobject] - Sender display name and address.
  SenderAddress [pscustomobject] - Optional technical sender address.
  ReplyTo       [pscustomobject] - Optional reply-to address.
  Timeout       [int]            - Connection timeout in seconds.
  CreatedAt     [string]         - ISO 8601 UTC creation timestamp.
  UpdatedAt     [string]         - ISO 8601 UTC last update timestamp.

.EXAMPLE
PS C:\> Get-PipeSmtp

.NOTES
Private dependencies:
  Get-SmtpConfig
#>
function Get-PipeSmtp {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param ()

    Get-SmtpConfig
}
