<#
.SYNOPSIS
Validates an SMTP configuration object.

.DESCRIPTION
Checks that all required properties are present and within acceptable
ranges. Returns a result object indicating whether the configuration
is valid and listing any validation errors.

Does not connect to any SMTP server. Does not decrypt the password.

Display name (Name) in From, SenderAddress and ReplyTo is optional.
Only the Email address is required when these objects are present.

.PARAMETER InputObject
The SMTP configuration object to validate. Accepts the shape produced
by Get-SmtpConfig and Save-SmtpConfig.

.OUTPUTS
System.Management.Automation.PSCustomObject

  IsValid [bool]     - Whether the configuration passed all checks.
  Errors  [string[]] - List of validation error messages. Empty on success.

.EXAMPLE
PS C:\> $result = Test-Smtp -InputObject $config

if (-not $result.IsValid) {
    Write-Warning ($result.Errors -join ' ')
}
#>
function Test-Smtp {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject]$InputObject
    )

    $errors = [System.Collections.Generic.List[string]]::new()

    $propertyNames = @($InputObject.PSObject.Properties.Name)

    #region SchemaVersion
    if ($propertyNames -notcontains 'SchemaVersion') {
        $errors.Add('SchemaVersion property is required.')
    } elseif ($InputObject.SchemaVersion -isnot [int] -and
        $InputObject.SchemaVersion -isnot [long]
    ) {
        $errors.Add('SchemaVersion must be an integer.')
    } elseif ([int]$InputObject.SchemaVersion -ne
        [int]$Script:SmtpSchemaVersion
    ) {
        $errors.Add(
            "Unsupported SMTP schema version '$($InputObject.SchemaVersion)'. " +
            "Expected '$($Script:SmtpSchemaVersion)'."
        )
    }
    #endregion

    #region Server
    if ($propertyNames -notcontains 'Server' -or
        [string]::IsNullOrWhiteSpace([string]$InputObject.Server)
    ) {
        $errors.Add('SMTP server is required.')
    }
    #endregion

    #region Port
    if ($propertyNames -notcontains 'Port') {
        $errors.Add('SMTP port is required.')
    } elseif ($InputObject.Port -isnot [int] -and
        $InputObject.Port -isnot [long] -and
        $InputObject.Port -isnot [int16]
    ) {
        $errors.Add('SMTP port must be an integer.')
    } elseif ([int64]$InputObject.Port -lt 1 -or
        [int64]$InputObject.Port -gt 65535
    ) {
        $errors.Add('SMTP port must be between 1 and 65535.')
    }
    #endregion

    #region Ssl
    if ($propertyNames -notcontains 'Ssl') {
        $errors.Add('Ssl property is required.')
    } elseif ($InputObject.Ssl -isnot [bool]) {
        $errors.Add('Ssl must be a boolean value.')
    }
    #endregion

    #region Username
    if ($propertyNames -notcontains 'Username' -or
        [string]::IsNullOrWhiteSpace([string]$InputObject.Username)
    ) {
        $errors.Add('SMTP username is required.')
    }
    #endregion

    #region Password
    if ($propertyNames -notcontains 'Password' -or
        [string]::IsNullOrWhiteSpace([string]$InputObject.Password)
    ) {
        $errors.Add('SMTP password is required.')
    }
    #endregion

    #region Timeout
    if ($propertyNames -notcontains 'Timeout') {
        $errors.Add('SMTP timeout is required.')
    } elseif ($InputObject.Timeout -isnot [int] -and
        $InputObject.Timeout -isnot [long] -and
        $InputObject.Timeout -isnot [int16]
    ) {
        $errors.Add('SMTP timeout must be an integer.')
    } elseif ([int64]$InputObject.Timeout -lt 1 -or
        [int64]$InputObject.Timeout -gt 120
    ) {
        $errors.Add('SMTP timeout must be between 1 and 120 seconds.')
    }
    #endregion

    #region CreatedAt
    if ($propertyNames -contains 'CreatedAt') {
        if ([string]::IsNullOrWhiteSpace([string]$InputObject.CreatedAt)
        ) {
            $errors.Add('CreatedAt cannot be empty.')
        } else {
            $createdAt = [System.DateTimeOffset]::MinValue

            $createdAtValid = [System.DateTimeOffset]::TryParse(
                [string]$InputObject.CreatedAt,
                [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::RoundtripKind,
                [ref]$createdAt
            )

            if (-not $createdAtValid) {
                $errors.Add('CreatedAt must be a valid ISO-8601 timestamp.')
            }
        }
    }
    #endregion

    #region UpdatedAt
    if ($propertyNames -contains 'UpdatedAt') {
        $updatedAtValue = $InputObject.UpdatedAt

        $updatedAtHasValue = (
            $null -ne $updatedAtValue -and -not
            [string]::IsNullOrWhiteSpace([string]$updatedAtValue)
        )

        if ($updatedAtHasValue) {
            $updatedAt = [System.DateTimeOffset]::MinValue

            $updatedAtValid = [System.DateTimeOffset]::TryParse(
                [string]$updatedAtValue,
                [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::RoundtripKind,
                [ref]$updatedAt
            )

            if (-not $updatedAtValid) {
                $errors.Add('UpdatedAt must be a valid ISO-8601 timestamp.')
            }
        }
    }
    #endregion

    #region From
    if ($propertyNames -notcontains 'From' -or $null -eq $InputObject.From) {
        $errors.Add('From is required.')
    } else {
        $from = $InputObject.From
        $fromPropertyNames = @($from.PSObject.Properties.Name)

        if ($fromPropertyNames -notcontains 'Email' -or
            [string]::IsNullOrWhiteSpace([string]$from.Email)
        ) {
            $errors.Add('From must contain an Email value.')
        }
    }
    #endregion

    #region SenderAddress
    if ($propertyNames -contains 'SenderAddress' -and
        $null -ne $InputObject.SenderAddress
    ) {
        $senderAddress = $InputObject.SenderAddress
        $senderAddressPropertyNames = @($senderAddress.PSObject.Properties.Name)

        if ($senderAddressPropertyNames -notcontains 'Email' -or
            [string]::IsNullOrWhiteSpace([string]$senderAddress.Email)
        ) {
            $errors.Add('SenderAddress must contain an Email value.')
        }
    }
    #endregion

    #region ReplyTo
    if ($propertyNames -contains 'ReplyTo' -and
        $null -ne $InputObject.ReplyTo
    ) {
        $replyTo = $InputObject.ReplyTo
        $replyToPropertyNames = @($replyTo.PSObject.Properties.Name)

        if ($replyToPropertyNames -notcontains 'Email' -or
            [string]::IsNullOrWhiteSpace([string]$replyTo.Email)
        ) {
            $errors.Add('ReplyTo must contain an Email value.')
        }
    }
    #endregion

    [PSCustomObject]@{
        IsValid = ($errors.Count -eq 0)
        Errors  = $errors.ToArray()
    }
}
