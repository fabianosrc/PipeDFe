<#
.SYNOPSIS
Executes the full DFe pipeline for one or more companies.

.DESCRIPTION
Orchestrates the DFe pipeline execution for N companies:

  1. Acquires the global PipeDFe execution lock unless -WhatIf is used.
  2. Resolves the processing period via Resolve-DateRange - previous full
     calendar month by default, or the period defined by -StartDate and
     -EndDate.
  3. Resolves the target company list - all active companies when -Cnpj is
     omitted, or the specified companies (normalized via
     ConvertTo-NormalizedCnpj and retrieved via Get-CompanyConfig) when one
     or more CNPJs are supplied. Inactive companies are skipped with a warning.
  4. For each company, applies ShouldProcess and delegates the full pipeline
     to Invoke-PipeDFeCompany.
  5. Creates and completes a durable audit execution for each processed
     company.
  6. Aggregates per-company results into a single ResultadoInvoke object.
  7. Releases the global execution lock after pipeline execution.

Period or company-list resolution failures are global errors that terminate
execution and propagate the original exception. Per-company failures are
isolated: Invoke-PipeDFeCompany normally returns Status = 'Falha', and
processing continues for remaining companies. Unexpected exceptions raised
during company processing are also isolated to the affected company.

Audit persistence is performed per company because audit.db is scoped to the
company CNPJ. Failure to initialize or start the audit execution prevents
that company from being processed. The failure is recorded in the aggregated
company result and processing continues for remaining companies.

The global execution lock prevents concurrent PipeDFe executions on the same
machine. The lock is intentionally not acquired when -WhatIf is used.

.PARAMETER Cnpj
One or more CNPJs identifying companies to process. Accepts formatted
(XX.XXX.XXX/XXXX-XX) or digits-only. When omitted, all active registered
companies are processed.

.PARAMETER StartDate
Optional start of the processing period. Accepts any format supported by
ConvertTo-DateTimeOffset.

.PARAMETER EndDate
Optional end of the processing period. Accepts any format supported by
ConvertTo-DateTimeOffset. Requires -StartDate when supplied.

.OUTPUTS
System.Management.Automation.PSCustomObject - TypeName: PipeDFe.ResultadoInvoke

  Success         [bool]       - Whether all companies were processed without
                                 fatal error.
  ProcessedAt     [string]     - ISO 8601 UTC timestamp of the pipeline execution.
  PeriodStart     [string]     - ISO 8601 start of the period processed.
  PeriodEnd       [string]     - ISO 8601 end of the period processed.
  Results         [psobject[]] - One result object per company -
                                 TypeName: PipeDFe.ResultadoEmpresa:
  Cnpj            [string]     - Company CNPJ.
  RazaoSocial     [string]     - Company legal name.
  Status          [string]     - 'OK', 'Aviso' or 'Falha'.
  TotalDocumentos [int]        - Total documents found in the period.
  Gaps            [int]        - Sequence gap count detected.
  Arquivos        [string[]]   - ZIP file names created.
  EmailEnviado    [bool]       - Whether the notification was sent successfully.
  Avisos          [string[]]   - Non-fatal warnings raised during processing.
  Erro            [string]     - Fatal error message; $null on success or warning.

.EXAMPLE
PS C:\> Invoke-PipeDFe

.EXAMPLE
PS C:\> Invoke-PipeDFe -Cnpj '12345678000195'

.EXAMPLE
PS C:\> Invoke-PipeDFe -Cnpj '12345678000195', '98765432000100'

.EXAMPLE
PS C:\> Invoke-PipeDFe -StartDate '01/08/2026' -EndDate '31/08/2026'

.NOTES
Private dependencies:
  ConvertTo-NormalizedCnpj
  Enter-PipeDFeExecutionLock
  Exit-PipeDFeExecutionLock
  Get-CompanyConfig
  Initialize-DFeAudit
  Resolve-DateRange
  Start-DFeAuditExecution
  Complete-DFeAuditExecution
  Invoke-PipeDFeCompany

The global execution lock prevents concurrent PipeDFe executions on the
same machine.

The lock is intentionally not acquired when -WhatIf is used.

Audit executions are scoped per company because audit.db is scoped by CNPJ.

The mutex is handled defensively for the possibility of an
AbandonedMutexException being reported by WaitOne().

Automated coverage for the abandoned-mutex recovery path is intentionally
not included. Attempts to reproduce mutex abandonment deterministically
within the supported PowerShell test environments were not reliable and
thread-based approaches can require a PowerShell runspace, making them
unsuitable for this test.

Cross-process contention is covered by the integration test suite.
#>
function Invoke-PipeDFe {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param (
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string[]]$Cnpj,

        [Parameter()]
        [string]$StartDate,

        [Parameter()]
        [string]$EndDate
    )

    $executionLock = $null

    if (-not $WhatIfPreference) {
        $executionLock = Enter-PipeDFeExecutionLock
    }

    try {
        $processedAt = [System.DateTimeOffset]::UtcNow.ToString('o')

        # Resolve period
        # Global failure: propagates and terminates execution.
        $resolveDateRangeParams = @{}

        if (-not [string]::IsNullOrWhiteSpace($StartDate)) {
            $resolveDateRangeParams['StartDate'] = $StartDate
        }

        if (-not [string]::IsNullOrWhiteSpace($EndDate)) {
            $resolveDateRangeParams['EndDate'] = $EndDate
        }

        $dateRange = Resolve-DateRange @resolveDateRangeParams

        # Resolve company list
        # Global failure: propagates and terminates execution.
        $companies = [System.Collections.Generic.List[pscustomobject]]::new()

        if ($PSBoundParameters.ContainsKey('Cnpj')) {
            foreach ($cnpjValue in $Cnpj) {
                $cnpjNormalized = ConvertTo-NormalizedCnpj -Value $cnpjValue
                $company = Get-CompanyConfig -Cnpj $cnpjNormalized

                if ($company.IsActive) {
                    $companies.Add($company)
                } else {
                    Write-Warning -Message "[$cnpjNormalized] Empresa inativa e será ignorada."
                }
            }
        } else {
            $allCompanies = @(Get-CompanyConfig)

            foreach ($company in $allCompanies) {
                if ($company.IsActive) {
                    $companies.Add($company)
                }
            }
        }

        if ($companies.Count -eq 0) {
            Write-Warning -Message (
                'Nenhuma empresa ativa encontrada. Cadastre uma empresa ' +
                'com New-PipeCompany antes de executar Invoke-PipeDFe.'
            )

            return [PSCustomObject]@{
                PSTypeName  = 'PipeDFe.ResultadoInvoke'
                Success     = $true
                ProcessedAt = $processedAt
                PeriodStart = $dateRange.Start.ToString('o')
                PeriodEnd   = $dateRange.End.ToString('o')
                Results     = @()
            }
        }

        $empresaWord = if ($companies.Count -eq 1) {
            'empresa'
        } else {
            'empresas'
        }

        Write-Verbose -Message (
            "$($companies.Count) $empresaWord " +
            "ativa(s) encontrada(s) para processamento."
        )

        # Process each company
        # Failures are isolated by company.
        $results = [System.Collections.Generic.List[pscustomobject]]::new()
        $activity = 'Invoke-PipeDFe'

        try {
            $i = 0

            foreach ($company in $companies) {
                $i++
                $cnpjNormalized = $company.Cnpj

                $displayName = if (-not
                    [string]::IsNullOrWhiteSpace($company.NomeFantasia)
                ) {
                    $company.NomeFantasia
                } else {
                    $company.RazaoSocial
                }

                $progressParams = @{
                    Activity        = $activity
                    Status          = "[$i/$($companies.Count)] $displayName"
                    PercentComplete = [int]($i / $companies.Count * 100)
                }

                Write-Progress @progressParams -CurrentOperation 'Iniciando...'
                Write-Verbose -Message "[$cnpjNormalized] Processando '$displayName'."

                if (-not $PSCmdlet.ShouldProcess($cnpjNormalized, "Executar pipeline DFe para '$displayName'")) {
                    $results.Add(
                        [PSCustomObject]@{
                            PSTypeName      = 'PipeDFe.ResultadoEmpresa'
                            Cnpj            = $cnpjNormalized
                            RazaoSocial     = $company.RazaoSocial
                            Status          = 'OK'
                            TotalDocumentos = 0
                            Gaps            = 0
                            Arquivos        = @()
                            EmailEnviado    = $false
                            Avisos          = @()
                            Erro            = $null
                        }
                    )

                    continue
                }

                $auditExecutionId = $null
                $companyResult = $null

                try {
                    Initialize-DFeAudit -Cnpj $cnpjNormalized | Out-Null

                    $moduleVersion = if (
                        $null -ne $MyInvocation.MyCommand.Module
                    ) {
                        $MyInvocation.MyCommand.Module.Version.ToString()
                    } else {
                        'Unknown'
                    }

                    $requestedPeriod = '{0}/{1}' -f (
                        $dateRange.Start.ToString('yyyy-MM-dd'),
                        $dateRange.End.ToString('yyyy-MM-dd')
                    )

                    $startAuditParams = @{
                        Cnpj            = $cnpjNormalized
                        Mode            = 'Invoke-PipeDFe'
                        RequestedPeriod = $requestedPeriod
                        ModuleVersion   = $moduleVersion
                    }

                    $auditExecutionId = Start-DFeAuditExecution @startAuditParams

                    $companyParams = @{
                        Company   = $company
                        DateRange = $dateRange
                    }

                    $companyResult = Invoke-PipeDFeCompany @companyParams
                } catch {
                    $companyResult = [PSCustomObject]@{
                        PSTypeName      = 'PipeDFe.ResultadoEmpresa'
                        Cnpj            = $cnpjNormalized
                        RazaoSocial     = $company.RazaoSocial
                        Status          = 'Falha'
                        TotalDocumentos = 0
                        Gaps            = 0
                        Arquivos        = @()
                        EmailEnviado    = $false
                        Avisos          = @()
                        Erro            = $_.Exception.Message
                    }

                    Write-Warning -Message (
                        "[$cnpjNormalized] Falha no processamento de '$displayName': " +
                        $_.Exception.Message
                    )
                }

                if ($null -ne $auditExecutionId) {
                    try {
                        if ($companyResult.Status -eq 'Falha') {
                            $errorSummary = $companyResult.Erro

                            if ([string]::IsNullOrWhiteSpace($errorSummary)) {
                                $errorSummary = 'Company processing returned Status = Falha.'
                            }

                            $completeAuditParams = @{
                                Cnpj         = $cnpjNormalized
                                ExecutionId  = $auditExecutionId
                                Status       = 'Failed'
                                ErrorSummary = $errorSummary
                            }

                            Complete-DFeAuditExecution @completeAuditParams
                        } else {
                            $completeAuditParams = @{
                                Cnpj        = $cnpjNormalized
                                ExecutionId = $auditExecutionId
                                Status      = 'Succeeded'
                            }

                            Complete-DFeAuditExecution @completeAuditParams
                        }
                    } catch {
                        Write-Warning -Message (
                            "[$cnpjNormalized] Falha ao concluir a auditoria: " +
                            $_.Exception.Message
                        )
                    }
                }

                $results.Add($companyResult)

                Write-Progress @progressParams -CurrentOperation 'Concluído.'
            }
        } finally {
            Write-Progress -Activity $activity -Completed
        }

        $allSucceeded = @(
            $results | Where-Object { $_.Status -eq 'Falha' }
        ).Count -eq 0

        [PSCustomObject]@{
            PSTypeName  = 'PipeDFe.ResultadoInvoke'
            Success     = [bool]$allSucceeded
            ProcessedAt = $processedAt
            PeriodStart = $dateRange.Start.ToString('o')
            PeriodEnd   = $dateRange.End.ToString('o')
            Results     = $results.ToArray()
        }
    } finally {
        if ($null -ne $executionLock) {
            Exit-PipeDFeExecutionLock -Lock $executionLock
        }
    }
}
