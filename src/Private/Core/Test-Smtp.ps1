<#
.SYNOPSIS
Validates an SMTP configuration object.

.DESCRIPTION
Validates the structure and required field values of an SMTP configuration
object. Returns a result object indicating whether the configuration is
valid and listing any validation errors found.

This function validates configuration only. It does not test SMTP
connectivity or authenticate against the server.

.PARAMETER InputObject
The SMTP configuration object to validate.

.OUTPUTS
System.Management.Automation.PSCustomObject

IsValid [bool]     Whether the configuration passed all validation rules.
Errors  [string[]] Validation error messages. Empty when IsValid is true.

.EXAMPLE
PS C:\> $result = Test-Smtp -InputObject $smtpConfig
>> if (-not $result.IsValid) { $result.Errors }

.NOTES
Pure function - no I/O, no side effects.

Private dependencies:
  $Script:SmtpSchemaVersion
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

    if ($InputObject.PSObject.Properties.Name -notcontains 'SchemaVersion') {
        $errors.Add('SchemaVersion property is required.')
    } elseif ($InputObject.SchemaVersion -ne $Script:SmtpSchemaVersion) {
        $errors.Add(
            "Unsupported SMTP schema version '$($InputObject.SchemaVersion)'. " +
            "Expected '$($Script:SmtpSchemaVersion)'."
        )
    }

    if ($InputObject.PSObject.Properties.Name -notcontains 'Server' -or
        [string]::IsNullOrWhiteSpace($InputObject.Server)
    ) {
        $errors.Add('SMTP server is required.')
    }

    if ($InputObject.PSObject.Properties.Name -notcontains 'Port' -or
        $InputObject.Port -lt 1 -or
        $InputObject.Port -gt 65535
    ) {
        $errors.Add('SMTP port must be between 1 and 65535.')
    }

    if ($InputObject.PSObject.Properties.Name -notcontains 'Username' -or
        [string]::IsNullOrWhiteSpace($InputObject.Username)
    ) {
        $errors.Add('SMTP username is required.')
    }

    if ($InputObject.PSObject.Properties.Name -notcontains 'Password' -or
        [string]::IsNullOrWhiteSpace([string]$InputObject.Password)
    ) {
        $errors.Add('SMTP password is required.')
    }

    if ($InputObject.PSObject.Properties.Name -notcontains 'Timeout' -or
        $InputObject.Timeout -lt 1 -or $InputObject.Timeout -gt 120
    ) {
        $errors.Add('SMTP timeout must be between 1 and 120 seconds.')
    }

    foreach ($propertyName in @('From', 'SenderAddress', 'ReplyTo')) {
        $prop = $InputObject.PSObject.Properties[$propertyName]

        if ($null -eq $prop -or $null -eq $prop.Value) {
            continue
        }

        $address = $prop.Value

        if ($address.PSObject.Properties.Name -notcontains 'Email' -or
            [string]::IsNullOrWhiteSpace($address.Email)
        ) {
            $errors.Add("$propertyName must contain an Email value.")
        }
    }

    [PSCustomObject]@{
        IsValid = ($errors.Count -eq 0)
        Errors  = $errors.ToArray()
    }
}
