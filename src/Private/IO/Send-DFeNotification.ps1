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
This preserves names like 'RIBEIRO & BONAFE' as 'RIBEIRO E BONAFE'.

This function never throws. Any exception raised during validation,
rendering, or sending is caught and surfaced as Success = $false with
FailedAt identifying the pipeline stage. Retry logic is the caller's
responsibility.

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

  Success      [bool]     - Whether the message was sent successfully.
  EmailsSent   [string[]] - Addresses the message was delivered to.
  ErrorMessage [string]   - Error description on failure; $null on success.
  FailedAt     [string]   - Stage that failed: 'Validation', 'Render', or
                            'Send'. $null on success.

.EXAMPLE
PS C:\> $params = @{
            Company            = $company
            DateRange          = $range
            Smtp               = $smtp
            Gaps               = $gaps
            ZipFileDestination = @($archive.DestPath)
        }

PS C:\> $result = Send-DFeNotification @params

        if (-not $result.Success) {
            Write-Warning "[$($result.FailedAt)] $($result.ErrorMessage)"
        }

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
            Success      = $false
            EmailsSent   = @()
            ErrorMessage = 'No primary recipient (Para) configured.'
            FailedAt     = 'Validation'
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
        # Preserves 'RIBEIRO & BONAFE' as 'RIBEIRO E BONAFE' without
        # stripping meaningful tokens the way the ZIP label strategy does.
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
            Success      = $false
            EmailsSent   = @()
            ErrorMessage = $_.Exception.Message
            FailedAt     = 'Render'
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

        # Send-Mail never throws - result must always be read from the object.
        if (-not $mailResult.Success) {
            return [PSCustomObject]@{
                Success      = $false
                EmailsSent   = @()
                ErrorMessage = $mailResult.Error
                FailedAt     = 'Send'
            }
        }

        [PSCustomObject]@{
            Success      = $true
            EmailsSent   = @($mailResult.EmailsSent)
            ErrorMessage = $null
            FailedAt     = $null
        }

    } catch {
        [PSCustomObject]@{
            Success      = $false
            EmailsSent   = @()
            ErrorMessage = $_.Exception.Message
            FailedAt     = 'Send'
        }
    }
}
