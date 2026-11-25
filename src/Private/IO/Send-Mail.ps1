<#
.SYNOPSIS
Sends an HTML email through the shared SMTP transport.

.DESCRIPTION
Builds and sends an HTML email using the provided SMTP configuration.

Uses implicit TLS on port 465 and STARTTLS on other ports when SSL is enabled.

Never throws after parameter validation. Runtime failures are caught and
returned as Success = $false with the error message in the Error property.

Invalid recipients are skipped with a warning. Missing attachments and
an empty To list after recipient validation fail before delivery.

.PARAMETER SmtpConfig
Resolved SMTP configuration object as returned by Resolve-DFeSmtp.

.PARAMETER To
One or more To recipients with Name and Email properties.

.PARAMETER Cc
Optional Cc recipients.

.PARAMETER Bcc
Optional Bcc recipients.

.PARAMETER Subject
Email subject.

.PARAMETER Body
HTML email body.

.PARAMETER Attachments
Optional file paths to attach.

.OUTPUTS
System.Management.Automation.PSCustomObject

Success       [bool]     Whether delivery succeeded.
EmailsSent    [string[]] Addresses of To recipients when successful.
Error         [string]   Error message when Success is false. $null otherwise.
AcceptanceUncertain [bool]
                         False on success or when the failure is known to have
                         occurred before the SMTP DATA terminator was sent.
                         True when the terminator may have reached the server
                         but no definitive response was received, meaning the
                         server may or may not have accepted the message.

.NOTES
Private dependencies:
  Add-MailRecipient
  ConvertFrom-DpapiString
  Send-SmtpMessage
#>
function Send-Mail {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject]$SmtpConfig,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject[]]$To,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyCollection()]
        [pscustomobject[]]$Cc,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyCollection()]
        [pscustomobject[]]$Bcc,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Subject,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Body,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$Attachments = @()
    )

    $message             = $null
    $acceptanceUncertain = $false

    try {
        $securePassword = ConvertFrom-DpapiString -Value $SmtpConfig.Password

        $credential = [System.Net.NetworkCredential]::new($SmtpConfig.Username, $securePassword)

        $message = [System.Net.Mail.MailMessage]::new()

        if (-not [string]::IsNullOrWhiteSpace($SmtpConfig.From.Name)) {
            $message.From = [System.Net.Mail.MailAddress]::new(
                $SmtpConfig.From.Email,
                $SmtpConfig.From.Name,
                [System.Text.Encoding]::UTF8
            )
        } else {
            $message.From = [System.Net.Mail.MailAddress]::new($SmtpConfig.From.Email)
        }

        $senderProp = $SmtpConfig.PSObject.Properties['SenderAddress']

        if ($null -ne $senderProp -and $null -ne $senderProp.Value -and
            -not [string]::IsNullOrWhiteSpace($senderProp.Value.Email)
        ) {
            try {
                $message.Sender = [System.Net.Mail.MailAddress]::new(
                    $senderProp.Value.Email,
                    $senderProp.Value.Name
                )
            } catch {
                Write-Warning -Message 'Invalid SenderAddress ignored.'
            }
        }

        $replyToProp = $SmtpConfig.PSObject.Properties['ReplyTo']

        if ($null -ne $replyToProp -and $null -ne $replyToProp.Value -and
            -not [string]::IsNullOrWhiteSpace($replyToProp.Value.Email)
        ) {
            try {
                $message.ReplyToList.Add(
                    [System.Net.Mail.MailAddress]::new(
                        $replyToProp.Value.Email,
                        $replyToProp.Value.Name
                    )
                )
            } catch {
                Write-Warning -Message 'Invalid ReplyTo ignored.'
            }
        }

        $addParams = @{
            Collection = $message.To
            Recipients = $To
        }

        Add-MailRecipient @addParams

        $addCcParams = @{
            Collection = $message.CC
            Recipients = $Cc
        }

        Add-MailRecipient @addCcParams

        $addBccParams = @{
            Collection = $message.Bcc
            Recipients = $Bcc
        }

        Add-MailRecipient @addBccParams

        if ($message.To.Count -eq 0) {
            throw [System.InvalidOperationException]::new(
                'No valid To recipients after address validation.'
            )
        }

        $message.Subject                     = $Subject
        $message.SubjectEncoding             = [System.Text.Encoding]::UTF8
        $message.Body                        = $Body
        $message.BodyEncoding                = [System.Text.Encoding]::UTF8
        $message.BodyTransferEncoding        = [System.Net.Mime.TransferEncoding]::Base64
        $message.IsBodyHtml                  = $true
        $message.Priority                    = [System.Net.Mail.MailPriority]::Normal
        $message.DeliveryNotificationOptions = [System.Net.Mail.DeliveryNotificationOptions]::OnFailure

        foreach ($path in @($Attachments)) {
            if ([string]::IsNullOrWhiteSpace($path)) {
                continue
            }

            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                throw [System.IO.FileNotFoundException]::new(
                    "Attachment not found: '$path'.",
                    $path
                )
            }

            $attachment = [System.Net.Mail.Attachment]::new($path)
            $message.Attachments.Add($attachment)
        }

        $smtpParams = @{
            Server              = $SmtpConfig.Server
            Port                = [int]$SmtpConfig.Port
            EnableSsl           = [bool]$SmtpConfig.Ssl
            Credential          = $credential
            Message             = $message
            TimeoutSeconds      = [int]$SmtpConfig.Timeout
            AcceptanceUncertain = [ref]$acceptanceUncertain
        }

        Send-SmtpMessage @smtpParams

        [PSCustomObject]@{
            Success             = $true
            EmailsSent          = @($message.To | ForEach-Object { $_.Address })
            Error               = $null
            AcceptanceUncertain = $false
        }
    } catch {
        [PSCustomObject]@{
            Success             = $false
            EmailsSent          = @()
            Error               = $_.Exception.Message
            AcceptanceUncertain = $acceptanceUncertain
        }
    } finally {
        if ($null -ne $message) {
            $message.Dispose()
        }
    }
}
