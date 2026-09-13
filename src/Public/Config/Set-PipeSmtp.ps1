<#
.SYNOPSIS
Persists the global SMTP configuration.

.DESCRIPTION
Accepts SMTP parameters, encrypts the password via DPAPI, validates the
resulting configuration and writes it atomically to smtp.json.

On the first call - when smtp.json does not exist - Server, Port, Ssl,
Username, Password and From are required. Subsequent calls may supply any
subset of parameters; omitted parameters are preserved from the existing
configuration.

Partial updates use PSBoundParameters to distinguish an explicit value
from an omitted parameter. This means -Ssl $false correctly sets SSL to
false rather than being treated as absent.

Passing an empty string to -SenderAddress or -ReplyTo clears that field.

When smtp.json exists but is corrupted or fails validation, the error is
propagated unchanged. Corruption is never silently treated as absence.

SchemaVersion is always set to the current version. An existing
configuration is silently promoted when the schema changes.

Throws SmtpConfigSaveFailed when the file cannot be written.

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
Sender address. Accepts 'Display Name <address@domain>' or
'address@domain'. When no display name is supplied, only the email
address is stored.

.PARAMETER SenderAddress
Optional technical sender address used when the From address differs
from the envelope sender. Same format as -From. Pass an empty string
to clear an existing value.

.PARAMETER ReplyTo
Optional reply-to address. Same format as -From. Pass an empty string
to clear an existing value.

.PARAMETER Timeout
Connection timeout in seconds. Defaults to 30 on first save.

.OUTPUTS
System.Management.Automation.PSCustomObject - TypeName: PipeDFe.Smtp

.EXAMPLE
PS C:\> $password = Read-Host -AsSecureString

PS C:\> $smtpParams = @{
    Server   = 'smtp.example.com'
    Port     = 587
    Ssl      = $true
    Username = 'user@example.com'
    Password = $password
    From     = 'Empresa <noreply@example.com>'
}

PS C:\> Set-PipeSmtp @smtpParams

.EXAMPLE
PS C:\> Set-PipeSmtp -Port 465

.EXAMPLE
PS C:\> Set-PipeSmtp -Ssl $false

.EXAMPLE
PS C:\> Set-PipeSmtp -ReplyTo ''

.NOTES
Private dependencies:
  ConvertTo-DpapiString
  ConvertTo-MailAddress
  Get-SmtpConfig
  Save-SmtpConfig
  Get-PipeSmtp
#>
function Set-PipeSmtp {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param (
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$Server,

        [Parameter()]
        [ValidateRange(1, 65535)]
        [int]$Port,

        [Parameter()]
        [bool]$Ssl,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$Username,

        [Parameter()]
        [ValidateNotNull()]
        [System.Security.SecureString]$Password,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$From,

        [Parameter()]
        [AllowEmptyString()]
        [string]$SenderAddress,

        [Parameter()]
        [AllowEmptyString()]
        [string]$ReplyTo,

        [Parameter()]
        [ValidateRange(1, 120)]
        [int]$Timeout
    )

    $existingConfig       = $null
    $isFirstConfiguration = $false

    try {
        $existingConfig = Get-SmtpConfig
    } catch {
        if ($_.FullyQualifiedErrorId -like 'SmtpConfigNotFound*') {
            $isFirstConfiguration = $true
        } else {
            throw
        }
    }

    $bound = $PSBoundParameters

    if ($isFirstConfiguration) {
        $requiredParameters = @('Server', 'Port', 'Ssl', 'Username', 'Password', 'From')

        $missingParameters = @(
            $requiredParameters | Where-Object { -not $bound.ContainsKey($_) }
        )

        if ($missingParameters.Count -gt 0) {
            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.ArgumentException]::new(
                        "The following parameters are required for the first " +
                        "SMTP configuration: $($missingParameters -join ', ')."
                    ),
                    'SmtpInitialConfigIncomplete',
                    [System.Management.Automation.ErrorCategory]::InvalidArgument,
                    $missingParameters
                )
            )
        }

        $timeoutSeconds = if ($bound.ContainsKey('Timeout')) {
            $Timeout
        } else {
            30
        }

        $createdAtUtc = [System.DateTimeOffset]::UtcNow.ToString(
            'o',
            [System.Globalization.CultureInfo]::InvariantCulture
        )

        $config = [PSCustomObject][ordered]@{
            SchemaVersion = [int]$Script:SmtpSchemaVersion
            Server        = $Server
            Port          = $Port
            Ssl           = $Ssl
            Username      = $Username
            Password      = ConvertTo-DpapiString -SecureString $Password
            From          = $null
            SenderAddress = $null
            ReplyTo       = $null
            Timeout       = $timeoutSeconds
            CreatedAt     = $createdAtUtc
            UpdatedAt     = $null
        }

        $config.From = ConvertTo-MailAddress -InputObject $From -Strict |
            Select-Object -First 1

        if ($bound.ContainsKey('SenderAddress') -and -not
            [string]::IsNullOrWhiteSpace($SenderAddress)
        ) {
            $senderAddressParams = @{
                InputObject = $SenderAddress
                Strict      = $true
            }

            $config.SenderAddress = ConvertTo-MailAddress @senderAddressParams |
                Select-Object -First 1
        }

        if ($bound.ContainsKey('ReplyTo') -and -not
            [string]::IsNullOrWhiteSpace($ReplyTo)
        ) {
            $replyToParams = @{
                InputObject = $ReplyTo
                Strict      = $true
            }

            $config.ReplyTo = ConvertTo-MailAddress @replyToParams |
                Select-Object -First 1
        }
    } else {
        $serverName = if ($bound.ContainsKey('Server')) {
            $Server.Trim()
        } else {
            $existingConfig.Server
        }

        $portNumber = if ($bound.ContainsKey('Port')) {
            $Port
        } else {
            $existingConfig.Port
        }

        $enableSsl = if ($bound.ContainsKey('Ssl')) {
            $Ssl
        } else {
            $existingConfig.Ssl
        }

        $effectiveUsername = if ($bound.ContainsKey('Username')) {
            $Username.Trim()
        } else {
            $existingConfig.Username
        }

        $effectivePassword = if ($bound.ContainsKey('Password')) {
            ConvertTo-DpapiString -SecureString $Password
        } else {
            $existingConfig.Password
        }

        $timeoutSeconds = if ($bound.ContainsKey('Timeout')) {
            $Timeout
        } else {
            $existingConfig.Timeout
        }

        $config = [PSCustomObject][ordered]@{
            SchemaVersion = [int]$Script:SmtpSchemaVersion
            Server        = $serverName
            Port          = $portNumber
            Ssl           = $enableSsl
            Username      = $effectiveUsername
            Password      = $effectivePassword
            From          = $null
            SenderAddress = $null
            ReplyTo       = $null
            Timeout       = $timeoutSeconds
            CreatedAt     = $existingConfig.CreatedAt
            UpdatedAt     = $null
        }

        $config.From = if ($bound.ContainsKey('From')) {
            ConvertTo-MailAddress -InputObject $From -Strict | Select-Object -First 1
        } else {
            $existingConfig.From
        }

        $config.SenderAddress = if ($bound.ContainsKey('SenderAddress')) {
            if ([string]::IsNullOrWhiteSpace($SenderAddress)) {
                $null
            } else {
                $senderAddressParams = @{
                    InputObject = $SenderAddress.Trim()
                    Strict      = $true
                }

                ConvertTo-MailAddress @senderAddressParams | Select-Object -First 1
            }
        } else {
            $existingConfig.SenderAddress
        }

        $config.ReplyTo = if ($bound.ContainsKey('ReplyTo')) {
            if ([string]::IsNullOrWhiteSpace($ReplyTo)) {
                $null
            } else {
                $replyToParams = @{
                    InputObject = $ReplyTo.Trim()
                    Strict      = $true
                }

                ConvertTo-MailAddress @replyToParams | Select-Object -First 1
            }
        } else {
            $existingConfig.ReplyTo
        }
    }

    $validation = Test-Smtp -InputObject $config

    if (-not $validation.IsValid) {
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                [System.IO.InvalidDataException]::new(
                    "SMTP configuration is invalid. $($validation.Errors -join ' ')"
                ),
                'SmtpConfigValidationFailed',
                [System.Management.Automation.ErrorCategory]::InvalidData,
                $config
            )
        )
    }

    if ($PSCmdlet.ShouldProcess('smtp.json', 'Save SMTP configuration')) {
        Save-SmtpConfig -Config $config
        Get-PipeSmtp
    }
}
