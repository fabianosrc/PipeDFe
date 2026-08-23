<#
.SYNOPSIS
Sends an HTML email via System.Net.Mail.SmtpClient.

.DESCRIPTION
Builds and sends an HTML email using the provided SMTP configuration.

TLS 1.2 is explicitly enabled per project security policy.

Never throws after parameter validation. Runtime failures are caught and
returned as Success = $false with the error message in the Error property.

Invalid recipients are skipped with a warning. Missing or invalid
attachments are skipped with a warning. When no valid To recipients
remain after filtering, the function returns Success = $false.

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

Success    [bool]     Whether delivery succeeded.
EmailsSent [string[]] Addresses of To recipients when successful.
Error      [string]   Error message when Success is false. $null otherwise.

.NOTES
Private dependencies:
  Add-MailRecipient
  ConvertFrom-DpapiString
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

    $message        = $null
    $smtpClient     = $null
    $attachmentList = [System.Collections.Generic.List[System.Net.Mail.Attachment]]::new()

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
        $message.IsBodyHtml                  = $true
        $message.Priority                    = [System.Net.Mail.MailPriority]::Normal
        $message.DeliveryNotificationOptions = [System.Net.Mail.DeliveryNotificationOptions]::OnFailure

        foreach ($path in @($Attachments)) {
            if ([string]::IsNullOrWhiteSpace($path)) {
                continue
            }

            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                Write-Warning -Message ("Attachment not found, skipping: '$path'")
                continue
            }

            try {
                $attachment = [System.Net.Mail.Attachment]::new($path)
                $attachmentList.Add($attachment)
                $message.Attachments.Add($attachment)
            } catch {
                Write-Warning -Message ("Failed to attach file, skipping: '$path'")
            }
        }

        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
        $smtpClient = [System.Net.Mail.SmtpClient]::new($SmtpConfig.Server, $SmtpConfig.Port)

        $smtpClient.EnableSsl             = [bool]$SmtpConfig.Ssl
        $smtpClient.DeliveryMethod        = [System.Net.Mail.SmtpDeliveryMethod]::Network
        $smtpClient.UseDefaultCredentials = $false
        $smtpClient.Credentials           = $credential
        $smtpClient.Timeout               = [int]$SmtpConfig.Timeout * 1000

        $smtpClient.Send($message)

        [PSCustomObject]@{
            Success    = $true
            EmailsSent = @($message.To | ForEach-Object { $_.Address })
            Error      = $null
        }
    } catch {
        [PSCustomObject]@{
            Success    = $false
            EmailsSent = @()
            Error      = $_.Exception.Message
        }
    } finally {
        foreach ($attachment in $attachmentList) {
            if ($null -ne $attachment) {
                $attachment.Dispose()
            }
        }

        if ($null -ne $message) {
            $message.Dispose()
        }

        if ($null -ne $smtpClient) {
            $smtpClient.Dispose()
        }
    }
}
