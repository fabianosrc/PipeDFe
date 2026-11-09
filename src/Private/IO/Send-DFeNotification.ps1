
<#
.SYNOPSIS
Renders and sends the DFe delivery notification email.

.DESCRIPTION
Orchestrates three sequential steps:

  1. Validates the primary recipient list before any rendering or I/O.
  2. Renders the email body from the notification template via Build-MailBody.
  3. Sends the email with all ZIP archives as attachments via Send-Mail.

Subject format: 'Arquivo XML {CompanyLabel} {PeriodLabel}'

The company label is derived from the first three words of NomeFantasia
(or RazaoSocial as fallback), with '&' replaced by 'E' for readability.

This function never throws. Any exception raised during validation,
rendering, or sending is caught and surfaced as Success = $false with
FailedAt identifying the pipeline stage.

SendAttempted is propagated from Send-Mail so callers can distinguish
failures before SMTP transmission from failures with an uncertain outcome.
When the property is missing, the result is treated conservatively as true.

.PARAMETER Company
Company object with Email (Para, Cc, Cco), NomeFantasia, RazaoSocial,
Cnpj, and Ie properties.

.PARAMETER DateRange
PSCustomObject with Start [DateTimeOffset] used for the period label.

.PARAMETER Smtp
SMTP configuration object as returned by Resolve-DFeSmtp.

.PARAMETER Gaps
Sequence gaps for inclusion in the mail body. An empty collection
is valid and means no gaps were detected.

.PARAMETER ZipFileDestination
Full paths to the destination ZIP files used as email attachments.

.OUTPUTS
System.Management.Automation.PSCustomObject

  Success        [bool]
  EmailsSent     [string[]]
  ErrorMessage   [string]
  FailedAt       [string]
  SendAttempted  [bool]

.NOTES
Dependencies:
  ConvertTo-NormalizedMailRecipient
  Resolve-SmtpReplyTo
  Build-MailBody
  Send-Mail
#>
function Send-DFeNotification {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject]$Company,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject]$DateRange,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject]$Smtp,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [pscustomobject[]]$Gaps,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string[]]$ZipFileDestination
    )

    # Fail fast: validate primary recipients before any rendering or I/O.
    $para = @(ConvertTo-NormalizedMailRecipient -InputObject $Company.Email.Para)

    if ($para.Count -eq 0) {
        return [PSCustomObject]@{
            Success       = $false
            EmailsSent    = @()
            ErrorMessage  = 'No primary recipient (Para) configured.'
            FailedAt      = 'Validation'
            SendAttempted = $false
        }
    }

    try {
        $ptBr = [System.Globalization.CultureInfo]::GetCultureInfo('pt-BR')

        $companyLabel = if (-not [string]::IsNullOrWhiteSpace($Company.NomeFantasia)) {
            $Company.NomeFantasia
        } else {
            $Company.RazaoSocial
        }

        # Replace '&' with 'E' then take the first three words.
        $subjectLabel = @(
            $companyLabel.ToUpper() -replace '&', 'E' -split '\s+' |
                Where-Object { $_ } |
                Select-Object -First 3
        ) -join ' '

        # pt-BR month name, e.g. 'Janeiro/2026'
        $periodLabel = $DateRange.Start.ToString('MMMM/yyyy', $ptBr)
        $periodLabel = $periodLabel.Substring(0, 1).ToUpper() + $periodLabel.Substring(1)

        $subject = 'Arquivo XML {0} {1}' -f $subjectLabel, $periodLabel

        $context = [PSCustomObject]@{
            Empresa          = $Company
            PeriodoDisplay   = $periodLabel
            DataEmissao      = [System.DateTimeOffset]::Now.ToString('dd/MM/yyyy HH:mm', $ptBr)
            ReplyTo          = Resolve-SmtpReplyTo -Smtp $Smtp
            NotasNaoLancadas = $Gaps
        }

        $body = Build-MailBody -Context $context

    } catch {
        return [PSCustomObject]@{
            Success       = $false
            EmailsSent    = @()
            ErrorMessage  = $_.Exception.Message
            FailedAt      = 'Render'
            SendAttempted = $false
        }
    }

    try {
        $cc  = @(ConvertTo-NormalizedMailRecipient -InputObject $Company.Email.Cc)
        $cco = @(ConvertTo-NormalizedMailRecipient -InputObject $Company.Email.Cco)

        $mailParams = @{
            SmtpConfig  = $Smtp
            To          = $para
            Cc          = $cc
            Bcc         = $cco
            Subject     = $subject
            Body        = $body
            Attachments = $ZipFileDestination
        }

        $mailResult = Send-Mail @mailParams

        if (-not $mailResult.Success) {
            $sendAttemptedProp = if ($null -ne $mailResult) {
                $mailResult.PSObject.Properties['SendAttempted']
            } else {
                $null
            }

            # Missing information must never make an uncertain send retryable.
            $sendAttempted = if ($null -eq $sendAttemptedProp) {
                $true
            } else {
                [bool]$sendAttemptedProp.Value
            }

            return [PSCustomObject]@{
                Success       = $false
                EmailsSent    = @()
                ErrorMessage  = $mailResult.Error
                FailedAt      = 'Send'
                SendAttempted = $sendAttempted
            }
        }

        [PSCustomObject]@{
            Success       = $true
            EmailsSent    = @($mailResult.EmailsSent)
            ErrorMessage  = $null
            FailedAt      = $null
            SendAttempted = $true
        }

    } catch {
        [PSCustomObject]@{
            Success       = $false
            EmailsSent    = @()
            ErrorMessage  = $_.Exception.Message
            FailedAt      = 'Send'
            SendAttempted = $true
        }
    }
}
