<#
.SYNOPSIS
Renders and sends the DFe delivery notification email.

.DESCRIPTION
Orchestrates three sequential steps:

  1. Validates the primary recipient list before any rendering or I/O.
  2. Renders the email body from the notification template via Build-MailBody.
  3. Sends the email with all ZIP archives as attachments via Send-Mail.

Subject format: 'Documentos Fiscais | {CompanyLabel} | {PeriodLabel}'

The company label is derived from the first three words of NomeFantasia
(or RazaoSocial as fallback) that contain more than one character, with
'&' replaced by 'E' for readability. Single-character tokens such as
the connective 'E' are excluded before the three-word limit is applied.

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

.PARAMETER Entries
DFe document index entries for the period, used to build the fiscal
document summary in the email body. Each entry must expose modelo and
chave_acesso. An empty collection produces an empty summary table.

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
        [AllowEmptyCollection()]
        [pscustomobject[]]$Entries,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string[]]$ZipFileDestination
    )

    # Fail fast: validate primary recipients before any rendering or I/O.
    try {
        $para = @(ConvertTo-NormalizedMailRecipient -InputObject $Company.Email.Para)

        if ($para.Count -eq 0) {
            throw [System.ArgumentException]::new(
                'No primary recipient (Para) configured.'
            )
        }
    } catch {
        return [PSCustomObject]@{
            Success       = $false
            EmailsSent    = @()
            ErrorMessage  = $_.Exception.Message
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

        # Replace '&' with 'E', discard single-character tokens such as the
        # connective 'E', then take the first three remaining words.
        $subjectLabel = @(
            $companyLabel.ToUpper() -replace '&', 'E' -split '\s+' |
                Where-Object { $_.Length -gt 1 } |
                Select-Object -First 3
        ) -join ' '

        # pt-BR month name, e.g. 'Janeiro/2026'
        $periodLabel = $DateRange.Start.ToString('MMMM/yyyy', $ptBr)
        $periodLabel = $periodLabel.Substring(0, 1).ToUpper() + $periodLabel.Substring(1)

        $subject = 'Documentos Fiscais | {0} | {1}' -f $subjectLabel, $periodLabel

        # Build the fiscal document summary from indexed entries grouped by model.
        $resumoDocumentos = @()

        if ($null -ne $Entries -and $Entries.Count -gt 0) {
            $resumoDocumentos = @(
                $Entries |
                    Group-Object -Property modelo |
                    ForEach-Object {
                        $modelValue = [int]$_.Name
                        $modelName  = try {
                            ([ModeloDFe]$modelValue).ToString()
                        } catch {
                            "Modelo $modelValue"
                        }

                        [PSCustomObject]@{
                            Tipo       = $modelName
                            Quantidade = $_.Count
                        }
                    } |
                    Sort-Object -Property Tipo
            )
        }

        $context = [PSCustomObject]@{
            Empresa           = $Company
            PeriodoDisplay    = $periodLabel
            DataEmissao       = [System.DateTimeOffset]::Now.ToString('dd/MM/yyyy HH:mm', $ptBr)
            ReplyTo           = Resolve-SmtpReplyTo -Smtp $Smtp
            NotasNaoLancadas  = $Gaps
            ResumoDocumentos  = $resumoDocumentos
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
