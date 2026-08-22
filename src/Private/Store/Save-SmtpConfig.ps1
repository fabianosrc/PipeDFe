<#
.SYNOPSIS
Persists the SMTP configuration to smtp.json.

.DESCRIPTION
Normalizes, validates and writes the SMTP configuration using an atomic
write pattern.

The configuration is first serialized to a uniquely named temporary file.
The temporary file is then atomically promoted to smtp.json.

Password must contain the DPAPI-encrypted password blob. This function
does not decrypt or otherwise transform the password.

CreatedAt is preserved when supplied by the caller. When CreatedAt is
absent or blank, the current UTC timestamp is assigned.

UpdatedAt is always replaced with the current UTC timestamp.

Throws SmtpConfigInvalid when the configuration fails validation.

Throws SmtpConfigSaveFailed when the configuration cannot be persisted.

.PARAMETER Config
The SMTP configuration object to persist.

.OUTPUTS
None.

.EXAMPLE
PS C:\> Save-SmtpConfig -Config $smtpConfig

.NOTES
Private dependencies:
  Get-StorePath
  Test-Smtp

Pure validation is performed before any file-system write occurs.
#>
function Save-SmtpConfig {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions',
        '',
        Justification = 'Internal persistence layer. Not a user-facing cmdlet.'
    )]
    [CmdletBinding()]
    [OutputType([void])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject]$Config
    )

    $now = [System.DateTimeOffset]::UtcNow.ToString('o')

    $createdAt = [string]$Config.CreatedAt

    if ([string]::IsNullOrWhiteSpace($createdAt)) {
        $createdAt = $now
    }

    $model = [ordered]@{
        SchemaVersion = $Script:SmtpSchemaVersion
        Server        = [string]$Config.Server
        Port          = [int]$Config.Port
        Ssl           = [bool]$Config.Ssl
        Username      = [string]$Config.Username
        Password      = [string]$Config.Password
        From          = $Config.From
        SenderAddress = $Config.SenderAddress
        ReplyTo       = $Config.ReplyTo
        Timeout       = [int]$Config.Timeout
        CreatedAt     = $createdAt
        UpdatedAt     = $now
    }

    $validation = Test-Smtp -InputObject ([pscustomobject]$model)

    if (-not $validation.IsValid) {
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                [System.ArgumentException]::new(
                    "Invalid SMTP configuration: $($validation.Errors -join '; ')"
                ),
                'SmtpConfigInvalid',
                [System.Management.Automation.ErrorCategory]::InvalidArgument,
                $Config
            )
        )
    }

    $rootPath = Get-StorePath -Scope Root

    $targetPath = Join-Path -Path $rootPath -ChildPath 'smtp.json'

    $smtpFile = 'smtp.{0}.tmp' -f [guid]::NewGuid().ToString('N')

    $tempPath = Join-Path -Path $rootPath -ChildPath $smtpFile

    try {
        if (-not (Test-Path -LiteralPath $rootPath -PathType Container)) {
            New-Item -Path $rootPath -ItemType Directory -Force -ErrorAction Stop |
                Out-Null
        }

        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)

        $json = $model |
            ConvertTo-Json -Depth 5 -ErrorAction Stop

        [System.IO.File]::WriteAllText($tempPath, $json, $utf8NoBom)

        if (Test-Path -LiteralPath $targetPath -PathType Leaf) {
            [System.IO.File]::Replace($tempPath, $targetPath, [NullString]::Value)
        } else {
            [System.IO.File]::Move($tempPath, $targetPath)
        }
    } catch {
        if (Test-Path -LiteralPath $tempPath -PathType Leaf) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }

        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                [System.IO.IOException]::new(
                    "Failed to write smtp.json: $($_.Exception.Message)",
                    $_.Exception
                ),
                'SmtpConfigSaveFailed',
                [System.Management.Automation.ErrorCategory]::WriteError,
                $targetPath
            )
        )
    }
}
