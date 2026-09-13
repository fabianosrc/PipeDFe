<#
.SYNOPSIS
Converts email address strings into structured objects.

.DESCRIPTION
Parses plain email addresses and display-name formats such as
'Name <email@domain>'. Supports comma and semicolon-separated addresses
within each input value.

Addresses are normalized to lowercase and deduplicated case-insensitively
across the entire pipeline invocation.

Invalid addresses are skipped by default. When -Strict is specified,
a terminating InvalidData error is thrown for the first invalid address.

When no display name is present, Name is set to an empty string.

.PARAMETER InputObject
One or more email address strings. Accepts pipeline input and
ValueFromPipelineByPropertyName.

.PARAMETER Strict
Throws a terminating InvalidData error when an invalid address is found.

.OUTPUTS
System.Management.Automation.PSCustomObject

Properties:
  Name  [string] Display name, or empty string when absent.
  Email [string] Normalized lowercase email address.

.EXAMPLE
PS C:\> ConvertTo-MailAddress -InputObject 'joao@empresa.com.br'

.EXAMPLE
PS C:\> 'Joao Silva <joao@empresa.com.br>', 'maria@empresa.com.br' |
>> ConvertTo-MailAddress

.EXAMPLE
PS C:\> ConvertTo-MailAddress -InputObject 'joao@empresa.com.br;
>> maria@empresa.com.br'

.EXAMPLE
PS C:\> ConvertTo-MailAddress -InputObject 'valid@example.com; invalid'

.NOTES
No external I/O or warnings are produced.

Invalid input is ignored unless -Strict is specified.

The HashSet used for deduplication is scoped to the current pipeline
invocation and is discarded when processing completes.
#>
function ConvertTo-MailAddress {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('EmailList')]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$InputObject,

        [Parameter()]
        [switch]$Strict
    )

    begin {
        $seen = [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase
        )

        $emailPattern = '^[^@\s]+@[^@\s]+$'
    }

    process {
        foreach ($value in $InputObject) {
            if ([string]::IsNullOrWhiteSpace($value)) {
                continue
            }

            foreach ($candidate in ($value -split '[,;]')) {
                $candidate = $candidate.Trim()

                if ([string]::IsNullOrWhiteSpace($candidate)) {
                    continue
                }

                try {
                    $mailAddress = [System.Net.Mail.MailAddress]::new($candidate)

                    if ($Strict -and $mailAddress.Address -notmatch $emailPattern) {
                        throw [System.FormatException]::new("Invalid email address '$candidate'.")
                    }
                } catch {
                    if ($Strict) {
                        $PSCmdlet.ThrowTerminatingError(
                            [System.Management.Automation.ErrorRecord]::new(
                                [System.FormatException]::new(
                                    "Invalid email address '$candidate'.",
                                    $_.Exception
                                ),
                                'InvalidMailAddress',
                                [System.Management.Automation.ErrorCategory]::InvalidData,
                                $candidate
                            )
                        )
                    }

                    continue
                }

                $email = $mailAddress.Address.Trim().ToLowerInvariant()

                if (-not $seen.Add($email)) {
                    continue
                }

                [PSCustomObject]@{
                    Name  = $mailAddress.DisplayName
                    Email = $email
                }
            }
        }
    }
}
