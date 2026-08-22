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

Display names are preserved as provided by the email parser. When no
display name is present, Name is set to the normalized email address.

.PARAMETER Email
One or more email address strings. Accepts pipeline input and
ValueFromPipelineByPropertyName.

.PARAMETER Strict
Throws a terminating InvalidData error when an invalid address is found.

.OUTPUTS
System.Management.Automation.PSCustomObject

Properties:
  Name  [string] Display name, or normalized email when absent.
  Email [string] Normalized lowercase email address.

.EXAMPLE
PS C:\> ConvertTo-MailAddress -Email 'joao@empresa.com.br'

.EXAMPLE
PS C:\> 'Joao Silva <joao@empresa.com.br>', 'maria@empresa.com.br' |
>> ConvertTo-MailAddress

.EXAMPLE
PS C:\> ConvertTo-MailAddress `
>> -Email 'joao@empresa.com.br; maria@empresa.com.br'

.EXAMPLE
PS C:\> ConvertTo-MailAddress `
>> -Email 'valid@example.com; invalid'

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
        [AllowNull()]
        [AllowEmptyString()]
        [string[]]$Email,

        [Parameter()]
        [switch]$Strict
    )

    begin {
        $seenEmails = [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase
        )
    }

    process {
        if ($null -eq $Email) {
            return
        }

        foreach ($inputValue in $Email) {
            if ([string]::IsNullOrWhiteSpace($inputValue)) {
                continue
            }

            $entries = $inputValue -split '\s*[,;]\s*'

            foreach ($entry in $entries) {
                $value = $entry.Trim()

                if ([string]::IsNullOrWhiteSpace($value)) {
                    continue
                }

                $mailAddress = $null

                try {
                    $mailAddress = [System.Net.Mail.MailAddress]::new($value)
                } catch [System.FormatException] {
                    if (-not $Strict) {
                        continue
                    }

                    $message = "Invalid email address: '$value'."

                    $errorRecord = [System.Management.Automation.ErrorRecord]::new(
                        [System.FormatException]::new($message),
                        'InvalidMailAddress',
                        [System.Management.Automation.ErrorCategory]::InvalidData,
                        $value
                    )

                    $PSCmdlet.ThrowTerminatingError($errorRecord)
                }

                if ($null -eq $mailAddress) {
                    continue
                }

                $normalizedEmail = $mailAddress.Address.Trim().ToLowerInvariant()

                if (-not $seenEmails.Add($normalizedEmail)) {
                    continue
                }

                $displayName = $mailAddress.DisplayName.Trim()

                if ([string]::IsNullOrWhiteSpace($displayName)) {
                    $displayName = $normalizedEmail
                }

                [PSCustomObject]@{
                    Name  = $displayName
                    Email = $normalizedEmail
                }
            }
        }
    }
}
