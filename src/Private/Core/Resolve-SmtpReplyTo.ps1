<#
.SYNOPSIS
Extracts the ReplyTo address string from an SMTP configuration object.

.DESCRIPTION
Handles all known shapes of the ReplyTo property:

  Absent  : property not present on the object -> $null
  Null    : property present but null          -> $null
  Blank   : empty or whitespace string         -> $null
  String  : 'reply@domain.com'                 -> 'reply@domain.com'
  Object  : @{ Email = 'reply@domain.com' }    -> 'reply@domain.com'

Never throws. Always returns a string or $null.

.PARAMETER Smtp
SMTP configuration object. The ReplyTo property is optional.

.OUTPUTS
System.String

.EXAMPLE
PS C:\> $replyTo = Resolve-SmtpReplyTo -Smtp $smtp

.NOTES
Pure function - no I/O, no side effects.
#>
function Resolve-SmtpReplyTo {
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject]$Smtp
    )

    $prop = $Smtp.PSObject.Properties['ReplyTo']

    if ($null -eq $prop -or $null -eq $prop.Value) {
        return $null
    }

    $value = $prop.Value

    if ($value -is [string]) {
        if ([string]::IsNullOrWhiteSpace($value)) {
            return $null
        }

        return $value
    }

    $emailProp = $value.PSObject.Properties['Email']

    if ($null -ne $emailProp -and -not
        [string]::IsNullOrWhiteSpace($emailProp.Value)
    ) {
        return [string]$emailProp.Value
    }

    return $null
}
