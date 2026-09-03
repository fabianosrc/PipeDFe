<#
.SYNOPSIS
Persists the global SMTP configuration.

.DESCRIPTION
Accepts SMTP parameters, encrypts the password via DPAPI, validates the
resulting configuration and writes it atomically to smtp.json.

Throws SmtpConfigInvalid when any required field is missing or invalid.
Throws SmtpConfigSaveFailed when the file cannot be written.

On the first call, CreatedAt is set to the current UTC moment. On
subsequent calls, CreatedAt is preserved and only UpdatedAt is updated.

.PARAMETER Server
SMTP server hostname or IP address.

.PARAMETER Port
SMTP server port number. Must be between 1 and 65535.

.PARAMETER Ssl
Whether the connection requires SSL/TLS.

.PARAMETER Username
SMTP authentication username.

.PARAMETER Password
SMTP authentication password as a SecureString. Encrypted via DPAPI
before being written to disk.

.PARAMETER From
Sender address. Accepts the formats accepted by ConvertTo-MailAddress:
'Display Name <address@domain>' or 'address@domain'.

.PARAMETER SenderAddress
Optional technical sender address used when the From address differs
from the envelope sender. Same format as -From.

.PARAMETER ReplyTo
Optional reply-to address. Same format as -From.

.PARAMETER Timeout
Connection timeout in seconds. Defaults to 30.

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
PS C:\> $pwd = Read-Host -AsSecureString

PS C:\> Set-PipeSmtp -Server smtp.example.com -Port 587 -Ssl $true
>> -Username user@example.com -Password $pwd
>> -From 'Empresa <noreply@example.com>'

.NOTES
Private dependencies:
  ConvertTo-DpapiString
  ConvertTo-MailAddress
  Get-SmtpConfig
  Save-SmtpConfig
#>
function Set-PipeSmtp {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Server,

        [Parameter(Mandatory)]
        [ValidateRange(1, 65535)]
        [int]$Port,

        [Parameter(Mandatory)]
        [bool]$Ssl,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Username,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [System.Security.SecureString]$Password,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$From,

        [Parameter()]
        [AllowEmptyString()]
        [string]$SenderAddress,

        [Parameter()]
        [AllowEmptyString()]
        [string]$ReplyTo,

        [Parameter()]
        [ValidateRange(1, 3600)]
        [int]$Timeout = 30
    )

    # Encrypt and resolve addresses before any persistence attempt.
    $encryptedPassword = ConvertTo-DpapiString -Value $Password

    $fromObj = ConvertTo-MailAddress -Email $From | Select-Object -First 1

    $senderAddressObj = $null
    $replyToObj       = $null

    if (-not [string]::IsNullOrWhiteSpace($SenderAddress)) {
        $senderAddressObj = ConvertTo-MailAddress -Email $SenderAddress.Trim() |
            Select-Object -First 1

    }

    if (-not [string]::IsNullOrWhiteSpace($ReplyTo)) {
        $replyToObj = ConvertTo-MailAddress -Email $ReplyTo.Trim() |
            Select-Object -First 1
    }

    # Attempt to load existing config to preserve CreatedAt.
    # SmtpConfigNotFound is expected on first call and silenced intentionally.
    $existing = $null

    try {
        $existing = Get-SmtpConfig -ErrorAction Stop
    } catch {
        $null = $_
    }

    $now = [System.DateTimeOffset]::UtcNow.ToString('o', [cultureinfo]::InvariantCulture)

    $createdAt = if ($null -ne $existing) {
        [string]$existing.CreatedAt
    } else {
        $now
    }

    $config = [PSCustomObject][ordered]@{
        SchemaVersion = $Script:SmtpSchemaVersion
        Server        = $Server.Trim()
        Port          = $Port
        Ssl           = $Ssl
        Username      = $Username.Trim()
        Password      = $encryptedPassword
        From          = $fromObj
        SenderAddress = $senderAddressObj
        ReplyTo       = $replyToObj
        Timeout       = $Timeout
        CreatedAt     = $createdAt
        UpdatedAt     = $now
    }

    if (-not $PSCmdlet.ShouldProcess('smtp.json', 'Save SMTP configuration')) {
        return
    }

    Save-SmtpConfig -Config $config

    Get-SmtpConfig
}
