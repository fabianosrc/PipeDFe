<#
.SYNOPSIS
Sends a message using the supplied SMTP client.

.DESCRIPTION
Thin internal wrapper around SmtpClient.Send that provides a mockable
seam for unit tests. This function intentionally contains no business
logic, validation, message construction, error handling, or SMTP
configuration. Those responsibilities belong to the caller.

ShouldProcess is intentionally not implemented here because the
public caller owns the confirmation semantics for the state-changing
operation.

.PARAMETER Client
The configured SmtpClient instance used to send the message.

.PARAMETER Message
The MailMessage to send.

.OUTPUTS
None.

.EXAMPLE
PS C:\> Send-PipeSmtpTestMessage -Client $smtpClient -Message $testMessage

.NOTES
Internal helper.
Compatible with Windows PowerShell 5.1 and PowerShell Core.
No private dependencies.
#>
function Send-PipeSmtpTestMessage {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions',
        '',
        Justification = 'ShouldProcess is handled by the public caller.'
    )]
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [System.Net.Mail.SmtpClient]$Client,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [System.Net.Mail.MailMessage]$Message
    )

    $Client.Send($Message)
}
