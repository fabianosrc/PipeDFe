<#
.SYNOPSIS
Converts mixed recipient input into normalized mail recipient objects.

.DESCRIPTION
Accepts recipients as strings or objects with Name and Email properties.
Returns one PSCustomObject for each valid recipient.

String inputs are treated as email addresses. Object inputs must expose
an Email property; Name is optional.

Null, empty and whitespace-only entries are skipped.
Objects without an Email property are skipped.
Email and Name values are trimmed before being returned.

The function is pipeline-safe and preserves one-to-zero output semantics:
each input produces exactly one recipient object or no output when invalid.

.PARAMETER InputObject
One or more recipient entries. Accepted formats:
  - String: used as the email address; Name is null.
  - Object: any object with an Email property; Name is optional.

Accepts pipeline input.

.OUTPUTS
System.Management.Automation.PSCustomObject

.EXAMPLE
PS C:\> ConvertTo-NormalizedMailRecipient -InputObject 'joao@empresa.com.br'

Name Email
---- -----
     joao@empresa.com.br

.EXAMPLE
PS C:\> $recipients = @(
    [PSCustomObject]@{
        Name  = 'Joao'
        Email = 'joao@empresa.com.br'
    }
    'maria@empresa.com.br'
)

PS C:\> $recipients | ConvertTo-NormalizedMailRecipient

.EXAMPLE
PS C:\> ConvertTo-NormalizedMailRecipient -InputObject $null

Returns no output.

.NOTES
Pure function - no I/O, no side effects.
#>
function ConvertTo-NormalizedMailRecipient {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param (
        [Parameter(ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object]$InputObject
    )

    process {
        foreach ($entry in $InputObject) {
            if ($null -eq $entry) {
                continue
            }

            if ($entry -is [string]) {
                $email = $entry
                $name  = $null
            } else {
                $emailProperty = $entry.PSObject.Properties['Email']

                if ($null -eq $emailProperty) {
                    continue
                }

                $email = $emailProperty.Value

                $nameProperty = $entry.PSObject.Properties['Name']

                $name = if ($null -ne $nameProperty) {
                    $nameProperty.Value
                } else {
                    $null
                }
            }

            if ($null -eq $email) {
                continue
            }

            $email = ([string]$email).Trim()

            if ([string]::IsNullOrWhiteSpace($email)) {
                continue
            }

            if ($null -ne $name) {
                $name = ([string]$name).Trim()
            }

            [PSCustomObject]@{
                Name  = $name
                Email = $email
            }
        }
    }
}
