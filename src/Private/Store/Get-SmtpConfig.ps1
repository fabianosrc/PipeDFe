<#
.SYNOPSIS
Reads the SMTP configuration from smtp.json.

.DESCRIPTION
Deserializes and validates smtp.json from the PipeDFe root directory.
Returns a runtime configuration object with the DPAPI-encrypted password
preserved as-is. Callers must use ConvertFrom-DpapiString to obtain the
usable SecureString.

Throws SmtpConfigNotFound when smtp.json does not exist.
Throws SmtpConfigInvalid when the file cannot be parsed or fails validation.

.OUTPUTS
System.Management.Automation.PSCustomObject

SchemaVersion [int]            - Schema version.
Server        [string]         - SMTP server hostname.
Port          [int]            - SMTP server port.
Ssl           [bool]           - Whether SSL is enabled.
Username      [string]         - SMTP authentication username.
Password      [string]         - DPAPI-encrypted password blob.
From          [pscustomobject] - Sender address object.
SenderAddress [pscustomobject] - Optional technical sender address.
ReplyTo       [pscustomobject] - Optional reply-to address.
Timeout       [int]            - Connection timeout in seconds.
CreatedAt     [string]         - ISO 8601 creation timestamp.
UpdatedAt     [string]         - ISO 8601 last update timestamp.

.EXAMPLE
PS C:\> $smtp = Get-SmtpConfig
>> $secure = ConvertFrom-DpapiString -Value $smtp.Password

.NOTES
Private dependencies:
  Get-StorePath
  Test-Smtp
#>
function Get-SmtpConfig {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param ()

    $path = Join-Path -Path (Get-StorePath -Scope Root) -ChildPath 'smtp.json'

    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                [System.IO.FileNotFoundException]::new(
                    "smtp.json not found. Run Set-PipeSmtp to configure SMTP. Path: '$path'",
                    $path
                ),
                'SmtpConfigNotFound',
                [System.Management.Automation.ErrorCategory]::ObjectNotFound,
                $path
            )
        )
    }

    $raw = $null

    try {
        $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop |
            ConvertFrom-Json -ErrorAction Stop
    } catch {
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                [System.IO.InvalidDataException]::new(
                    "Failed to parse smtp.json: $($_.Exception.Message)",
                    $_.Exception
                ),
                'SmtpConfigInvalid',
                [System.Management.Automation.ErrorCategory]::InvalidData,
                $path
            )
        )
    }

    $validation = Test-Smtp -InputObject $raw

    if (-not $validation.IsValid) {
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                [System.IO.InvalidDataException]::new(
                    "smtp.json failed validation: $($validation.Errors -join '; ')"
                ),
                'SmtpConfigInvalid',
                [System.Management.Automation.ErrorCategory]::InvalidData,
                $path
            )
        )
    }

    [PSCustomObject]@{
        SchemaVersion = $raw.SchemaVersion
        Server        = $raw.Server
        Port          = $raw.Port
        Ssl           = $raw.Ssl
        Username      = $raw.Username
        Password      = $raw.Password
        From          = $raw.From
        SenderAddress = $raw.SenderAddress
        ReplyTo       = $raw.ReplyTo
        Timeout       = $raw.Timeout
        CreatedAt     = $raw.CreatedAt
        UpdatedAt     = $raw.UpdatedAt
    }
}
