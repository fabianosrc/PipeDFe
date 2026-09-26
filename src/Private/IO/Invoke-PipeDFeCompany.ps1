<#
.SYNOPSIS
Executes the full DFe pipeline for a single company.

.DESCRIPTION
Orchestrates the complete DFe processing pipeline for one company:

  1. Initializes the SQLite index via Initialize-DFeIndex.
  2. Repairs abandoned Processing states via Repair-DFeDocumentProcessing.
  3. Scans XmlPath and indexes new XML files via Invoke-DFeXmlScan.
  4. Queries indexed documents for the requested period.
  5. Processes indexed NF-e/NFC-e documents through Invoke-DFeDocumentProcessing.
  6. Blocks archive generation and delivery while supported fiscal documents
     remain in Failed or Processing state.
  7. Detects sequence gaps via Get-DFeSequenceGap.
  8. Resolves ZIP archive metadata per document type via Resolve-DFeArchiveInfo.
  9. Creates ZIP archives via New-DFeArchive.
 10. Resolves SMTP configuration via Resolve-DFeSmtp.
 11. Sends the delivery notification via Send-DFeNotification when recipients
     are configured and SMTP is available.

Only NF-e (55) and NFC-e (65) currently participate in the normalized fiscal
processing workflow. Other indexed document models continue through the
existing gap/archive flow without entering that state machine.

Document-processing failures are isolated so that one failing NF-e/NFC-e does
not prevent the remaining eligible documents from being attempted. However,
archive generation and delivery are interrupted if any supported document in
the requested period has unresolved fiscal processing.

Abandoned Processing states are repaired to Failed before document processing
begins. Failed documents are not automatically retried here; retry policy
belongs to a dedicated workflow.

Never throws. Any exception raised during the company pipeline is caught and
surfaced as Status = 'Falha' in the returned object, allowing the caller to
continue processing other companies.

Non-fatal conditions such as no documents found, SMTP not configured, no
recipients configured, or notification delivery failure are surfaced as
Status = 'Aviso'.

.PARAMETER Company
Company object as returned by Get-CompanyConfig. Must expose at minimum
Cnpj, RazaoSocial, NomeFantasia, XmlPath and Email.

.PARAMETER DateRange
PSCustomObject with Start and End [DateTimeOffset] representing the inclusive
processing period, as returned by Resolve-DateRange.

.OUTPUTS
System.Management.Automation.PSCustomObject

PSTypeName:
  PipeDFe.ResultadoEmpresa

Properties:
  Cnpj            [string]
  RazaoSocial     [string]
  Status          [string]   - OK, Aviso or Falha
  TotalDocumentos [int]
  Gaps            [int]
  Arquivos        [string[]]
  EmailEnviado    [bool]
  Avisos          [string[]]
  Erro            [string]
  Scan            [pscustomobject]

.NOTES
Private dependencies:
  Initialize-DFeIndex
  Repair-DFeDocumentProcessing
  Invoke-DFeXmlScan
  Get-DFeDocumentEntry
  Invoke-DFeDocumentProcessing
  Get-DFeInutilizacaoEntry
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
    $scanResult      = $null

    $periodoDisplay = (
        "$($DateRange.Start.ToString('dd/MM/yyyy')) a " +
        "$($DateRange.End.ToString('dd/MM/yyyy'))"
    )

    try {
        Initialize-DFeIndex -Cnpj $cnpj | Out-Null

        $repairParams = @{
            Cnpj         = $cnpj
            AbandonAfter = [System.TimeSpan]::FromMinutes(30)
        }

        $repairResult = Repair-DFeDocumentProcessing @repairParams

        if ($repairResult.Recovered -gt 0) {
            Write-Verbose -Message (
                "[$cnpj] $($repairResult.Recovered) processamento(s) abandonado(s) " +
                'reparado(s) para Failed.'
            )
        }

        if ($repairResult.Inconsistent -gt 0) {
            Write-Warning -Message (
                "[$cnpj] $($repairResult.Inconsistent) documento(s) possuíam estado " +
                'Processing com processing_started_at ausente ou inválido.'
            )
        }

        $scanParams = @{
            Cnpj    = $cnpj
            XmlPath = $Company.XmlPath
        }

        $scanResult = Invoke-DFeXmlScan @scanParams

        $entryParams = @{
            Cnpj      = $cnpj
            StartDate = $DateRange.Start.ToString('o')
            EndDate   = $DateRange.End.ToString('o')
        }

        $entries = @(Get-DFeDocumentEntry @entryParams)

        $totalDocumentos = $entries.Count

        Write-Verbose -Message (
            "[$cnpj] $totalDocumentos documento(s) encontrado(s) no período."
        )

        if ($entries.Count -eq 0) {
            $aviso = (
                "Nenhum documento encontrado no período de $periodoDisplay. " +
                'Verifique o XmlPath ou ajuste o período.'
            )

            $avisos.Add($aviso)

            Write-Warning -Message "[$cnpj] $aviso"

            $status = 'Aviso'

            Write-Verbose -Message "[$cnpj] Concluído com status '$status'."

            return [pscustomobject]@{
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
                Scan            = if ($null -eq $scanResult) {
                    $null
                } else {
                    [pscustomobject]@{
                        FilesFound   = $scanResult.FilesFound
                        FilesIndexed = $scanResult.FilesIndexed
                        FilesSkipped = $scanResult.FilesSkipped
                        FilesIgnored = $scanResult.FilesIgnored
                    }
                }
            }
        }

        # -----------------------------------------------------------------
        # Fiscal processing
        #
        # Only NF-e/NFC-e currently have normalized fiscal processing.
        # -----------------------------------------------------------------
        $supportedEntries = @(
            $entries | Where-Object { [int]$_.modelo -in @(55, 65) }
        )

        $blockedEntries = @(
            $supportedEntries |
                Where-Object {
                    $_.processing_status -in @('Failed', 'Processing')
                }
        )

        foreach ($entry in $blockedEntries) {
            $detail = if (-not [string]::IsNullOrWhiteSpace(
                    [string]$entry.processing_error)
            ) {
                " $($entry.processing_error)"
            } else {
                [string]::Empty
            }

            $aviso = (
                "Documento '$($entry.chave_acesso)' possui estado fiscal " +
                "'$($entry.processing_status)' e impede a conclusão da entrega." +
                $detail
            )

            $avisos.Add($aviso)

            Write-Warning -Message "[$cnpj] $aviso"
        }

        $indexedEntries = @(
            $supportedEntries |
                Where-Object { $_.processing_status -eq 'Indexed' }
        )

        $processingFailures = [System.Collections.Generic.List[string]]::new()

        foreach ($entry in $indexedEntries) {
            try {
                $processingParams = @{
                    Cnpj  = $cnpj
                    Entry = $entry
                }

                Invoke-DFeDocumentProcessing @processingParams

                Write-Verbose -Message (
                    "[$cnpj] Documento '$($entry.chave_acesso)' " +
                    'processado fiscalmente com sucesso.'
                )
            } catch {
                $processingFailures.Add([string]$entry.chave_acesso)

                $aviso = (
                    'Falha no processamento fiscal do documento ' +
                    "'$($entry.chave_acesso)': $($_.Exception.Message)"
                )

                $avisos.Add($aviso)

                Write-Warning -Message "[$cnpj] $aviso"
            }
        }

        $unresolvedCount = $blockedEntries.Count + $processingFailures.Count

        if ($unresolvedCount -gt 0) {
            throw [System.InvalidOperationException]::new(
                "$unresolvedCount documento(s) NF-e/NFC-e possuem " +
                'processamento fiscal não concluído. ' +
                'A geração de arquivos e a entrega foram interrompidas.'
            )
        }

        # -----------------------------------------------------------------
        # Existing sequence/archive/delivery flow.
        # -----------------------------------------------------------------
        $inutilizacoes = @(Get-DFeInutilizacaoEntry -Cnpj $cnpj)

        $gapEntries = @(
            Get-DFeSequenceGap -Entries $entries -CoveredRanges $inutilizacoes
        )

        $gaps = $gapEntries.Count

        if ($gaps -gt 0) {
            Write-Verbose -Message (
                "[$cnpj] $gaps gap(s) de sequência detectado(s)."
            )
        }

        $tipoDFeList = @(
            $entries |
                Select-Object -ExpandProperty modelo -Unique |
                ForEach-Object { ([ModeloDFe]$_).ToString() }
        )

        $archiveInfos = @(
            foreach ($tipoDFe in $tipoDFeList) {
                $archiveInfoParams = @{
                    TipoDFe   = $tipoDFe
                    Cnpj      = $cnpj
                    Company   = $Company
                    DateRange = $DateRange
                }

                Resolve-DFeArchiveInfo @archiveInfoParams
            }
        )

        $archiveParams = @{
            Cnpj         = $cnpj
            Company      = $Company
            Entries      = $entries
            ArchiveInfos = $archiveInfos
        }

        $archives = @(New-DFeArchive @archiveParams)

        $arquivos = @($archives | Select-Object -ExpandProperty FileName)

        # -----------------------------------------------------------------
        # Notification
        # -----------------------------------------------------------------
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
                    'Falha no envio da notificação em ' +
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

        $status = if ($avisos.Count -gt 0) { 'Aviso' } else { 'OK' }

        Write-Verbose -Message "[$cnpj] Concluído com status '$status'."

        [pscustomobject]@{
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
            Scan            = if ($null -eq $scanResult) {
                $null
            } else {
                [pscustomobject]@{
                    FilesFound   = $scanResult.FilesFound
                    FilesIndexed = $scanResult.FilesIndexed
                    FilesSkipped = $scanResult.FilesSkipped
                    FilesIgnored = $scanResult.FilesIgnored
                }
            }
        }

    } catch {
        $errorMessage = $_.Exception.Message

        Write-Warning -Message "[$cnpj] Falha no processamento - $errorMessage"

        [pscustomobject]@{
            PSTypeName      = 'PipeDFe.ResultadoEmpresa'
            Cnpj            = $cnpj
            RazaoSocial     = $Company.RazaoSocial
            Status          = 'Falha'
            TotalDocumentos = $totalDocumentos
            Gaps            = $gaps
            Arquivos        = $arquivos
            EmailEnviado    = $false
            Avisos          = $avisos.ToArray()
            Erro            = $errorMessage
            Scan            = $scanResult
        }
    }
}
