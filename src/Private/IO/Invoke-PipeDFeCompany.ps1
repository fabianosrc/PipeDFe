<#
.SYNOPSIS
Executes the full DFe pipeline for a single company.

.DESCRIPTION
Orchestrates the complete DFe processing pipeline for one company:

  1. Initializes the SQLite index via Initialize-DFeIndex.
  2. Scans XmlPath and indexes new XML files via Invoke-DFeXmlScan.
  3. Queries indexed documents for the period via Get-DFeDocumentEntry.
  4. Detects sequence gaps via Get-DFeSequenceGap.
  5. Resolves ZIP archive metadata per document type via Resolve-DFeArchiveInfo.
  6. Creates ZIP archives via New-DFeArchive.
  7. Resolves SMTP configuration via Resolve-DFeSmtp.
  8. Sends the delivery notification via Send-DFeNotification when recipients
     are configured and SMTP is available.

Never throws. Any exception raised during the pipeline is caught and surfaced
as Status = 'Falha' in the returned object, allowing the caller to continue
processing other companies. Non-fatal conditions (no documents found for the
period, SMTP not configured, no recipients configured, notification delivery
failure) are captured as Status = 'Aviso' with details in Avisos.

.PARAMETER Company
Company object as returned by Get-CompanyConfig. Must expose at minimum
Cnpj, RazaoSocial, NomeFantasia, XmlPath and Email.

.PARAMETER DateRange
PSCustomObject with Start and End [DateTimeOffset] representing the
inclusive processing period, as returned by Resolve-DateRange.

.OUTPUTS
System.Management.Automation.PSCustomObject - TypeName: PipeDFe.ResultadoEmpresa

  Cnpj            [string]   - Company CNPJ.
  RazaoSocial     [string]   - Company legal name.
  Status          [string]   - 'OK', 'Aviso' or 'Falha'.
  TotalDocumentos [int]      - Total documents found in the period.
  Gaps            [int]      - Sequence gap count detected.
  Arquivos        [string[]] - ZIP file names created.
  EmailEnviado    [bool]     - Whether the notification was sent successfully.
  Avisos          [string[]] - Non-fatal warnings raised during processing.
  Erro            [string]   - Fatal error message; $null on success or warning.

.EXAMPLE
PS C:\> $params = @{
    Company   = $company
    DateRange = $dateRange
}

PS C:\> Invoke-PipeDFeCompany @params

.NOTES
Private dependencies:
  Initialize-DFeIndex
  Invoke-DFeXmlScan
  Get-DFeDocumentEntry
  Get-DFeSequenceGap
  Resolve-DFeArchiveInfo
  New-DFeArchive
  Resolve-DFeSmtp
  Send-DFeNotification
#>
function Invoke-PipeDFeCompany {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject]$Company,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject]$DateRange
    )

    $cnpj   = $Company.Cnpj
    $avisos = [System.Collections.Generic.List[string]]::new()

    $totalDocumentos = 0
    $gaps            = 0
    $gapEntries      = @()
    $arquivos        = @()
    $emailEnviado    = $false

    $periodoDisplay = (
        "$($DateRange.Start.ToString('dd/MM/yyyy')) a " +
        "$($DateRange.End.ToString('dd/MM/yyyy'))"
    )

    try {
        Initialize-DFeIndex -Cnpj $cnpj | Out-Null

        $scanParams = @{
            Cnpj    = $cnpj
            XmlPath = $Company.XmlPath
        }

        Invoke-DFeXmlScan @scanParams

        $entryParams = @{
            Cnpj      = $cnpj
            StartDate = $DateRange.Start.ToString('o')
            EndDate   = $DateRange.End.ToString('o')
        }

        $entries         = @(Get-DFeDocumentEntry @entryParams)
        $totalDocumentos = $entries.Count

        Write-Verbose -Message "[$cnpj] $totalDocumentos documento(s) encontrado(s) no período."

        if ($entries.Count -gt 0) {
            $gapEntries = @(Get-DFeSequenceGap -Entries $entries)
            $gaps       = $gapEntries.Count

            if ($gaps -gt 0) {
                Write-Verbose -Message "[$cnpj] $gaps gap(s) de sequência detectado(s)."
            }

            $tipoDFeList = @(
                $entries |
                    Select-Object -ExpandProperty modelo -Unique |
                    ForEach-Object { ([ModeloDFe]$_).ToString() }
            )

            $archiveInfos = foreach ($tipoDFe in $tipoDFeList) {
                $archiveInfoParams = @{
                    TipoDFe   = $tipoDFe
                    Cnpj      = $cnpj
                    Company   = $Company
                    DateRange = $DateRange
                }

                Resolve-DFeArchiveInfo @archiveInfoParams
            }

            $archiveParams = @{
                Cnpj         = $cnpj
                Company      = $Company
                Entries      = $entries
                ArchiveInfos = @($archiveInfos)
            }

            $archives = @(New-DFeArchive @archiveParams)
            $arquivos = @($archives | Select-Object -ExpandProperty FileName)

            $smtp = $null

            try {
                $smtp = Resolve-DFeSmtp -Company $Company
            } catch {
                $aviso = (
                    'SMTP não configurado - notificação por e-mail ignorada. ' +
                    'Execute Set-PipeSmtp para configurar.'
                )

                $avisos.Add($aviso)
                Write-Warning -Message "[$cnpj] $aviso"
                $null = $_
            }

            $para = @(
                $Company.Email.Para |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            )

            if ($null -ne $smtp -and $para.Count -gt 0) {
                $notificationParams = @{
                    Company            = $Company
                    DateRange          = $DateRange
                    Smtp               = $smtp
                    Gaps               = $gapEntries
                    ZipFileDestination = @($archives | Select-Object -ExpandProperty DestPath)
                }

                $notificationResult = Send-DFeNotification @notificationParams

                if ($notificationResult.Success) {
                    $emailEnviado = $true
                } else {
                    $aviso = (
                        "Falha no envio da notificação em " +
                        "'$($notificationResult.FailedAt)': " +
                        $notificationResult.ErrorMessage
                    )

                    $avisos.Add($aviso)
                    Write-Warning -Message "[$cnpj] $aviso"
                }
            } elseif ($null -ne $smtp -and $para.Count -eq 0) {
                $aviso = (
                    'Nenhum destinatário configurado - notificação por e-mail ignorada. ' +
                    'Configure os destinatários com Set-PipeCompany.'
                )

                $avisos.Add($aviso)
                Write-Warning -Message "[$cnpj] $aviso"
            }
        } else {
            $aviso = (
                "Nenhum documento encontrado no período de $periodoDisplay. " +
                'Verifique o XmlPath ou ajuste o período.'
            )

            $avisos.Add($aviso)
            Write-Warning -Message "[$cnpj] $aviso"
        }

        $status = if ($avisos.Count -gt 0) { 'Aviso' } else { 'OK' }

        Write-Verbose -Message "[$cnpj] Concluído com status '$status'."

        [PSCustomObject]@{
            PSTypeName      = 'PipeDFe.ResultadoEmpresa'
            Cnpj            = $cnpj
            RazaoSocial     = $Company.RazaoSocial
            Status          = $status
            TotalDocumentos = $totalDocumentos
            Gaps            = $gaps
            Arquivos        = $arquivos
            EmailEnviado    = $emailEnviado
            Avisos          = $avisos.ToArray()
            Erro            = $null
        }

    } catch {
        $errMsg = $_.Exception.Message
        Write-Warning -Message "[$cnpj] Falha no processamento - $errMsg"

        [PSCustomObject]@{
            PSTypeName      = 'PipeDFe.ResultadoEmpresa'
            Cnpj            = $cnpj
            RazaoSocial     = $Company.RazaoSocial
            Status          = 'Falha'
            TotalDocumentos = $totalDocumentos
            Gaps            = $gaps
            Arquivos        = $arquivos
            EmailEnviado    = $false
            Avisos          = $avisos.ToArray()
            Erro            = $errMsg
        }
    }
}
