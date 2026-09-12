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
  CreatedAt     [string]         - ISO 8601 UTC creation timestamp.
  UpdatedAt     [string]         - ISO 8601 UTC last update timestamp,
                                   or $null on first save.

.EXAMPLE
PS C:> $smtp   = Get-SmtpConfig
PS C:> $secure = ConvertFrom-DpapiString -Value $smtp.Password

.NOTES
Private dependencies:
  Get-StorePath
  Test-Smtp
#>
function Get-SmtpConfig {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param ()

    $rootPath   = Get-StorePath -Scope Root
    $configPath = Join-Path -Path $rootPath -ChildPath 'smtp.json'

    if (-not [System.IO.File]::Exists($configPath)) {
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                [System.IO.FileNotFoundException]::new(
                    'SMTP configuration file was not found.',
                    $configPath
                ),
                'SmtpConfigNotFound',
                [System.Management.Automation.ErrorCategory]::ObjectNotFound,
                $configPath
            )
        )
    }

    try {
        $json = [System.IO.File]::ReadAllText(
            $configPath,
            [System.Text.UTF8Encoding]::new($false)
        )

        if ([string]::IsNullOrWhiteSpace($json)) {
            throw [System.IO.InvalidDataException]::new(
                'SMTP configuration file is empty.'
            )
        }

        $config = $json | ConvertFrom-Json
    } catch {
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                [System.IO.InvalidDataException]::new(
                    'Failed to read or parse the SMTP configuration file.',
                    $_.Exception
                ),
                'SmtpConfigInvalid',
                [System.Management.Automation.ErrorCategory]::InvalidData,
                $configPath
            )
        )
    }

    $validation = Test-Smtp -InputObject $config

    if (-not $validation.IsValid) {
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                [System.IO.InvalidDataException]::new(
                    "SMTP configuration is invalid. $($validation.Errors -join ' ')"
                ),
                'SmtpConfigInvalid',
                [System.Management.Automation.ErrorCategory]::InvalidData,
                $configPath
            )
        )
    }

    # Timestamps are returned as strings to preserve the ISO 8601 UTC format
    # written by Save-SmtpConfig. Casting to [datetime] or [DateTimeOffset]
    # here would lose the offset on .NET Framework and break the round-trip
    # contract with Save-SmtpConfig.
    $createdAt = if ($null -ne $config.CreatedAt) {
        [string]$config.CreatedAt
    } else {
        $null
    }

    $updatedAt = if ($null -ne $config.UpdatedAt) {
        [string]$config.UpdatedAt
    } else {
        $null
    }

    [PSCustomObject][ordered]@{
        SchemaVersion = [int]$config.SchemaVersion
        Server        = [string]$config.Server
        Port          = [int]$config.Port
        Ssl           = [bool]$config.Ssl
        Username      = [string]$config.Username
        Password      = [string]$config.Password
        From          = $config.From
        SenderAddress = $config.SenderAddress
        ReplyTo       = $config.ReplyTo
        Timeout       = [int]$config.Timeout
        CreatedAt     = $createdAt
        UpdatedAt     = $updatedAt
    }
}
