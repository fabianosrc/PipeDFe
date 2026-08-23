<#
.SYNOPSIS
Adds normalized recipient objects to a MailAddressCollection.

.DESCRIPTION
Iterates over recipient objects with Name and Email properties and adds
each valid recipient to the supplied MailAddressCollection.

Recipients with a null or whitespace Email are skipped silently.

Recipients with an invalid email address emit a warning and are skipped
without interrupting processing of subsequent recipients.

Recipients with a null or whitespace Name are added without a display name.

.PARAMETER Collection
The MailAddressCollection to which recipients are added.

.PARAMETER Recipients
One or more recipient objects exposing Name and Email properties.

Null recipients and empty recipient collections are accepted and ignored.

.OUTPUTS
None.

.EXAMPLE
PS C:\> Add-MailRecipient -Collection $message.To -Recipients $recipients

.NOTES
Private helper for Send-Mail.

Dependencies:
  None.
#>
function Add-MailRecipient {
    [CmdletBinding()]
    [OutputType([void])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [AllowEmptyCollection()]
        [System.Net.Mail.MailAddressCollection]$Collection,

        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [pscustomobject[]]$Recipients
    )

    foreach ($recipient in @($Recipients)) {
        if ($null -eq $recipient) {
            continue
        }

        $email = [string]$recipient.Email
        $name  = [string]$recipient.Name

        if ([string]::IsNullOrWhiteSpace($email)) {
            continue
        }

        try {
            if ([string]::IsNullOrWhiteSpace($name)) {
                $address = [System.Net.Mail.MailAddress]::new($email)
            } else {
                $address = [System.Net.Mail.MailAddress]::new(
                    $email,
                    $name,
                    [System.Text.Encoding]::UTF8
                )
            }

            $Collection.Add($address)
        } catch {
            Write-Warning -Message (
                'Invalid email address ignored: {0}' -f $email
            )
        }
    }
}
