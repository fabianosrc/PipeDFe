#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for Invoke-PipeDFeCompany.

.DESCRIPTION
Verifies the orchestration contract of Invoke-PipeDFeCompany using mocks
for all private dependencies. No real SQLite, file system I/O, or SMTP
connections are used.

Coverage includes:
  - Company and DateRange are mandatory.
  - Returns PipeDFe.ResultadoEmpresa on every code path.
  - Initializes the index before repairing Processing state.
  - Repairs Processing state before scanning the configured XML path.
  - Uses a 30-minute abandonment threshold in the company pipeline.
  - A repair failure is fatal and prevents scanning.
  - Repaired Failed documents are blocked by the normal fiscal state policy.
  - Queries documents for the requested period.
  - Processes only Indexed NF-e and NFC-e documents.
  - Does not reprocess Processed NF-e and NFC-e documents.
  - Failed or Processing NF-e and NFC-e documents block archive and delivery.
  - A processing failure does not prevent the remaining eligible documents
    from being attempted.
  - Unsupported document models do not enter the NF-e/NFC-e processing
    workflow.
  - Returns Status = 'Aviso' when no documents are found in the period.
  - Detects sequence gaps and creates archives when delivery is allowed.
  - Sends notifications when SMTP and recipients are available.
  - Returns Status = 'Aviso' for non-fatal notification configuration
    or delivery failures.
  - Returns Status = 'Falha' and never throws when a fatal pipeline step fails.
  - Never calls real repair or document processing from this unit suite.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseShouldProcessForStateChangingFunctions',
    '',
    Justification = 'ShouldProcess would add no value here.'
)]

param ()

# InModuleScope needs to resolve the PipeDFe module during the Discovery phase,
# because that's when Context/It are executed to register the test tree. If the
# module isn't loaded at that point, InModuleScope fails before any BeforeAll or
# BeforeEach ever runs.
BeforeDiscovery {
    $moduleRoot = (Get-Item $PSScriptRoot).Parent.Parent.Parent.Parent.FullName

    $moduleName = Join-Path -Path $moduleRoot -ChildPath 'PipeDFe.psd1'

    Import-Module -Name $moduleName -Force -Global -ErrorAction Stop
}

Describe 'Invoke-PipeDFeCompany' -Tag 'Unit' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            $Script:Cnpj = '12345678000199'

            $Script:Company = [pscustomobject]@{
                Cnpj         = $Script:Cnpj
                RazaoSocial  = 'EMPRESA TESTE LTDA'
                NomeFantasia = [string]::Empty
                XmlPath      = 'C:\xml'
                OutputPath   = 'C:\output'
                Email        = [pscustomobject]@{
                    Para = @('dest@exemplo.com.br')
                    Cc   = @()
                    Cco  = @()
                }
            }

            $Script:CompanyWithoutRecipients = [pscustomobject]@{
                Cnpj         = $Script:Cnpj
                RazaoSocial  = 'EMPRESA TESTE LTDA'
                NomeFantasia = [string]::Empty
                XmlPath      = 'C:\xml'
                OutputPath   = 'C:\output'
                Email        = [pscustomobject]@{
                    Para = @()
                    Cc   = @()
                    Cco  = @()
                }
            }

            $Script:DateRange = [pscustomobject]@{
                Start = [System.DateTimeOffset]::new(
                    2026, 8, 1, 0, 0, 0, [System.TimeSpan]::Zero
                )
                End = [System.DateTimeOffset]::new(
                    2026, 8, 31, 23, 59, 59, [System.TimeSpan]::Zero
                )
            }

            $Script:Entry = [pscustomobject]@{
                chave_acesso          = '35260112345678000199550010000000011234567890'
                modelo                = 55
                dh_emi                = '2026-08-15T10:00:00+00:00'
                file_path             = 'C:\xml\nfe.xml'
                is_proc               = $false
                ndoc                  = 1
                serie                 = '001'
                sha256                = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
                indexed_at            = '2026-08-15T10:00:00+00:00'
                processing_status     = 'Indexed'
                processing_started_at = $null
                processed_at          = $null
                processing_error      = $null
            }

            $Script:SecondEntry = [pscustomobject]@{
                chave_acesso          = '35260112345678000199550010000000021234567891'
                modelo                = 65
                dh_emi                = '2026-08-16T10:00:00+00:00'
                file_path             = 'C:\xml\nfce.xml'
                is_proc               = $false
                ndoc                  = 2
                serie                 = '001'
                sha256                = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
                indexed_at            = '2026-08-16T10:00:00+00:00'
                processing_status     = 'Indexed'
                processing_started_at = $null
                processed_at          = $null
                processing_error      = $null
            }

            $Script:ArchiveInfo = [pscustomobject]@{
                TipoDFe  = 'NFe'
                FileName = 'NFe_12345678000199_EMPRESA_TESTE_202608.zip'
                TempPath = 'C:\temp\NFe_12345678000199_EMPRESA_TESTE_202608.zip'
                DestPath = 'C:\output\NFe_12345678000199_EMPRESA_TESTE_202608.zip'
            }

            $Script:Archive = [pscustomobject]@{
                TipoDFe  = 'NFe'
                FileName = 'NFe_12345678000199_EMPRESA_TESTE_202608.zip'
                FileHash = 'deadbeef'
                TempPath = 'C:\temp\NFe_12345678000199_EMPRESA_TESTE_202608.zip'
                DestPath = 'C:\output\NFe_12345678000199_EMPRESA_TESTE_202608.zip'
            }

            $Script:Smtp = [pscustomobject]@{
                Host = 'smtp.exemplo.com.br'
                Port = 587
            }

            $Script:NotificationSuccess = [pscustomobject]@{
                Success      = $true
                EmailsSent   = @('dest@exemplo.com.br')
                ErrorMessage = $null
                FailedAt     = $null
            }

            $Script:NotificationFailure = [pscustomobject]@{
                Success      = $false
                EmailsSent   = @()
                ErrorMessage = 'Connection refused.'
                FailedAt     = 'Send'
            }

            $Script:RepairEmpty = [pscustomobject]@{
                ProcessingFound     = 0
                Active              = 0
                Recovered           = 0
                Inconsistent        = 0
                ConcurrentlyChanged = 0
            }

            function Copy-TestEntry {
                [CmdletBinding()]
                [OutputType([pscustomobject])]
                param (
                    [Parameter(Mandatory)]
                    [pscustomobject]$Entry,

                    [Parameter()]
                    [AllowNull()]
                    [string]$ProcessingStatus,

                    [Parameter()]
                    [AllowNull()]
                    [string]$ProcessingError,

                    [Parameter()]
                    [AllowNull()]
                    [Nullable[int]]$Modelo
                )

                if (-not $PSBoundParameters.ContainsKey('ProcessingStatus')) {
                    $ProcessingStatus = [string]$Entry.processing_status
                }

                if (-not $PSBoundParameters.ContainsKey('ProcessingError')) {
                    $ProcessingError = $Entry.processing_error
                }

                if (-not $PSBoundParameters.ContainsKey('Modelo')) {
                    $Modelo = [int]$Entry.modelo
                }

                [pscustomobject]@{
                    chave_acesso          = $Entry.chave_acesso
                    modelo                = [int]$Modelo
                    dh_emi                = $Entry.dh_emi
                    file_path             = $Entry.file_path
                    is_proc               = $Entry.is_proc
                    ndoc                  = $Entry.ndoc
                    serie                 = $Entry.serie
                    sha256                = $Entry.sha256
                    indexed_at            = $Entry.indexed_at
                    processing_status     = $ProcessingStatus
                    processing_started_at = $Entry.processing_started_at
                    processed_at          = $Entry.processed_at
                    processing_error      = $ProcessingError
                }
            }

            function Invoke-TestCompany {
                [CmdletBinding()]
                [OutputType([pscustomobject])]
                param (
                    [Parameter()]
                    [pscustomobject]$Company = $Script:Company
                )

                $invokeParams = @{
                    Company   = $Company
                    DateRange = $Script:DateRange
                }

                Invoke-PipeDFeCompany @invokeParams
            }
        }

        BeforeEach {

            Mock -CommandName Initialize-DFeIndex -MockWith {
                return 'C:\store\12345678000199\index.db'
            }

            Mock -CommandName Repair-DFeDocumentProcessing -MockWith {
                return $Script:RepairEmpty
            }

            Mock -CommandName Invoke-DFeXmlScan -MockWith {
                return [pscustomobject]@{
                    FilesFound   = 3
                    FilesIndexed = 2
                    FilesSkipped = 1
                    FilesIgnored = 0
                }
            }

            Mock -CommandName Get-DFeDocumentEntry -MockWith {
                return $Script:Entry
            }

            Mock -CommandName Invoke-DFeDocumentProcessing

            Mock -CommandName Get-DFeInutilizacaoEntry -MockWith {
                return @()
            }

            Mock -CommandName Get-DFeSequenceGap -MockWith {
                return @()
            }

            Mock -CommandName Resolve-DFeArchiveInfo -MockWith {
                return $Script:ArchiveInfo
            }

            Mock -CommandName New-DFeArchive -MockWith {
                return $Script:Archive
            }

            Mock -CommandName Resolve-DFeSmtp -MockWith {
                return $Script:Smtp
            }

            Mock -CommandName Send-DFeNotification -MockWith {
                return $Script:NotificationSuccess
            }
        }

        #region Parameter contract
        Context 'Parameter contract' {

            BeforeAll {

                $Script:Command = Get-Command -Name Invoke-PipeDFeCompany -ErrorAction Stop
            }

            It 'Declares Company as mandatory' {
                $mandatory = $Script:Command.Parameters['Company'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.Mandatory
                    }

                $mandatory | Should -Not -BeNullOrEmpty
            }

            It 'Declares DateRange as mandatory' {
                $mandatory = $Script:Command.Parameters['DateRange'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.Mandatory
                    }

                $mandatory | Should -Not -BeNullOrEmpty
            }
        }
        #endregion

        #region Happy path
        Context 'Documents found, SMTP configured, notification sent' {

            BeforeEach {

                $Script:Result = Invoke-TestCompany
            }

            It 'Returns a PipeDFe.ResultadoEmpresa object' {
                $Script:Result.PSTypeNames | Should -Contain 'PipeDFe.ResultadoEmpresa'
            }

            It 'Calls Initialize-DFeIndex once with the correct Cnpj' {
                $shouldParams = @{
                    CommandName     = 'Initialize-DFeIndex'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'It'
                    Exactly         = $true
                    Times           = 1
                    ParameterFilter = { $Cnpj -eq $Script:Cnpj }
                }

                Should -Invoke @shouldParams
            }

            It 'Calls Repair-DFeDocumentProcessing once with the pipeline policy' {
                $shouldParams = @{
                    CommandName     = 'Repair-DFeDocumentProcessing'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'It'
                    Exactly         = $true
                    Times           = 1
                    ParameterFilter = {
                        $Cnpj -eq $Script:Cnpj -and
                        $AbandonAfter -eq [System.TimeSpan]::FromMinutes(30)
                    }
                }

                Should -Invoke @shouldParams
            }

            It 'Calls Invoke-DFeXmlScan once with the correct parameters' {
                $shouldParams = @{
                    CommandName     = 'Invoke-DFeXmlScan'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'It'
                    Exactly         = $true
                    Times           = 1
                    ParameterFilter = {
                        $Cnpj -eq $Script:Cnpj -and
                        $XmlPath -eq $Script:Company.XmlPath
                    }
                }

                Should -Invoke @shouldParams
            }

            It 'Calls Get-DFeDocumentEntry once with the correct period' {
                $shouldParams = @{
                    CommandName     = 'Get-DFeDocumentEntry'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'It'
                    Exactly         = $true
                    Times           = 1
                    ParameterFilter = {
                        $Cnpj -eq $Script:Cnpj -and
                        $StartDate -eq $Script:DateRange.Start.ToString('o') -and
                        $EndDate -eq $Script:DateRange.End.ToString('o')
                    }
                }

                Should -Invoke @shouldParams
            }

            It 'Processes the Indexed NF-e document once' {
                $shouldParams = @{
                    CommandName     = 'Invoke-DFeDocumentProcessing'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'It'
                    Exactly         = $true
                    Times           = 1
                    ParameterFilter = {
                        $Cnpj -eq $Script:Cnpj -and
                        $Entry.chave_acesso -eq $Script:Entry.chave_acesso
                    }
                }

                Should -Invoke @shouldParams
            }

            It 'Calls Get-DFeSequenceGap once' {
                $shouldParams = @{
                    CommandName = 'Get-DFeSequenceGap'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'It'
                    Exactly     = $true
                    Times       = 1
                }

                Should -Invoke @shouldParams
            }

            It 'Calls Resolve-DFeArchiveInfo once per document type' {
                $shouldParams = @{
                    CommandName = 'Resolve-DFeArchiveInfo'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'It'
                    Exactly     = $true
                    Times       = 1
                }

                Should -Invoke @shouldParams
            }

            It 'Calls New-DFeArchive once' {
                $shouldParams = @{
                    CommandName = 'New-DFeArchive'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'It'
                    Exactly     = $true
                    Times       = 1
                }

                Should -Invoke @shouldParams
            }

            It 'Calls Send-DFeNotification once' {
                $shouldParams = @{
                    CommandName = 'Send-DFeNotification'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'It'
                    Exactly     = $true
                    Times       = 1
                }

                Should -Invoke @shouldParams
            }

            It 'Returns Status OK' {
                $Script:Result.Status | Should -Be 'OK'
            }

            It 'Returns TotalDocumentos matching the entry count' {
                $Script:Result.TotalDocumentos | Should -Be 1
            }

            It 'Returns the archive file name' {
                $Script:Result.Arquivos | Should -Contain $Script:Archive.FileName
            }

            It 'Returns EmailEnviado true' {
                $Script:Result.EmailEnviado | Should -BeTrue
            }

            It 'Returns an empty Avisos array' {
                $Script:Result.Avisos | Should -HaveCount 0
            }

            It 'Returns Erro as null' {
                $Script:Result.Erro | Should -BeNullOrEmpty
            }
        }
        #endregion

        #region Processing state repair
        Context 'Processing state repair' {

            It 'Runs Initialize, Repair and Scan in that order' {
                $Script:CallOrder = [System.Collections.Generic.List[string]]::new()

                Mock -CommandName Initialize-DFeIndex -MockWith {
                    $Script:CallOrder.Add('Initialize')
                    return 'C:\store\12345678000199\index.db'
                }

                Mock -CommandName Repair-DFeDocumentProcessing -MockWith {
                    $Script:CallOrder.Add('Repair')
                    return $Script:RepairEmpty
                }

                Mock -CommandName Invoke-DFeXmlScan -MockWith {
                    $Script:CallOrder.Add('Scan')

                    return [pscustomobject]@{
                        FilesFound   = 3
                        FilesIndexed = 2
                        FilesSkipped = 1
                        FilesIgnored = 0
                    }
                }

                Invoke-TestCompany | Out-Null

                $Script:CallOrder | Should -HaveCount 3
                $Script:CallOrder[0] | Should -Be 'Initialize'
                $Script:CallOrder[1] | Should -Be 'Repair'
                $Script:CallOrder[2] | Should -Be 'Scan'
            }

            It 'Allows the normal pipeline when repair finds no Processing documents' {
                $result = Invoke-TestCompany

                $result.Status | Should -Be 'OK'
                $result.Avisos | Should -HaveCount 0
            }

            It 'Does not add repair activity to company warnings' {
                $repairResult = [pscustomobject]@{
                    ProcessingFound     = 2
                    Active              = 1
                    Recovered           = 1
                    Inconsistent        = 0
                    ConcurrentlyChanged = 0
                }

                Mock -CommandName Repair-DFeDocumentProcessing -MockWith {
                    return $repairResult
                }

                $result = Invoke-TestCompany

                $result.Status | Should -Be 'OK'
                $result.Avisos | Should -HaveCount 0
            }

            It 'Blocks delivery when the period query sees a repaired document as Failed' {
                $repairResult = [pscustomobject]@{
                    ProcessingFound     = 1
                    Active              = 0
                    Recovered           = 1
                    Inconsistent        = 0
                    ConcurrentlyChanged = 0
                }

                $failedEntryParams = @{
                    Entry            = $Script:Entry
                    ProcessingStatus = 'Failed'
                    ProcessingError  = 'Processing recovery marked the document as Failed.'
                }

                $failedEntry = Copy-TestEntry @failedEntryParams

                Mock -CommandName Repair-DFeDocumentProcessing -MockWith {
                    return $repairResult
                }

                Mock -CommandName Get-DFeDocumentEntry -MockWith {
                    return $failedEntry
                }

                $result = Invoke-TestCompany

                $result.Status | Should -Be 'Falha'
                $result.Erro | Should -Match 'processamento fiscal não concluído'

                $archiveShouldParams = @{
                    CommandName = 'New-DFeArchive'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'It'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke @archiveShouldParams

                $notificationShouldParams = @{
                    CommandName = 'Send-DFeNotification'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'It'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke @notificationShouldParams
            }

            It 'Returns Falha and prevents scan when repair fails' {
                Mock -CommandName Repair-DFeDocumentProcessing -MockWith {
                    throw [System.IO.IOException]::new('Repair failed.')
                }

                $result = Invoke-TestCompany

                $result.Status | Should -Be 'Falha'
                $result.Erro | Should -Be 'Repair failed.'

                $scanShouldParams = @{
                    CommandName = 'Invoke-DFeXmlScan'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'It'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke @scanShouldParams

                $queryShouldParams = @{
                    CommandName = 'Get-DFeDocumentEntry'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'It'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke @queryShouldParams
            }
        }
        #endregion

        #region Fiscal processing
        Context 'Fiscal processing selection' {

            It 'Does not process a Processed NF-e document' {
                $processedEntryParams = @{
                    Entry            = $Script:Entry
                    ProcessingStatus = 'Processed'
                }

                $processedEntry = Copy-TestEntry @processedEntryParams

                Mock -CommandName Get-DFeDocumentEntry -MockWith {
                    return $processedEntry
                }

                $result = Invoke-TestCompany

                $result.Status | Should -Be 'OK'

                $shouldParams = @{
                    CommandName = 'Invoke-DFeDocumentProcessing'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'It'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke @shouldParams
            }

            It 'Does not process an unsupported document model' {
                $cteEntryParams = @{
                    Entry            = $Script:Entry
                    ProcessingStatus = 'Indexed'
                    Modelo           = 57
                }

                $cteEntry = Copy-TestEntry @cteEntryParams

                Mock -CommandName Get-DFeDocumentEntry -MockWith {
                    return $cteEntry
                }

                $result = Invoke-TestCompany

                $result.Status | Should -Be 'OK'

                $shouldParams = @{
                    CommandName = 'Invoke-DFeDocumentProcessing'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'It'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke @shouldParams
            }

            It 'Blocks archive and notification when a supported document is Failed' {
                $failedEntryParams = @{
                    Entry            = $Script:Entry
                    ProcessingStatus = 'Failed'
                    ProcessingError  = 'Invalid XML.'
                }

                $failedEntry = Copy-TestEntry @failedEntryParams

                Mock -CommandName Get-DFeDocumentEntry -MockWith {
                    return $failedEntry
                }

                $result = Invoke-TestCompany

                $result.Status | Should -Be 'Falha'
                $result.Erro | Should -Match 'processamento fiscal não concluído'

                $archiveShouldParams = @{
                    CommandName = 'New-DFeArchive'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'It'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke @archiveShouldParams

                $notificationShouldParams = @{
                    CommandName = 'Send-DFeNotification'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'It'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke @notificationShouldParams
            }

            It 'Blocks archive and notification when a supported document is Processing' {
                $processingEntryParams = @{
                    Entry            = $Script:Entry
                    ProcessingStatus = 'Processing'
                }

                $processingEntry = Copy-TestEntry @processingEntryParams

                Mock -CommandName Get-DFeDocumentEntry -MockWith {
                    return $processingEntry
                }

                $result = Invoke-TestCompany

                $result.Status | Should -Be 'Falha'

                $archiveShouldParams = @{
                    CommandName = 'New-DFeArchive'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'It'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke @archiveShouldParams

                $notificationShouldParams = @{
                    CommandName = 'Send-DFeNotification'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'It'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke @notificationShouldParams
            }

            It 'Attempts every Indexed supported document even when one fails' {
                Mock -CommandName Get-DFeDocumentEntry -MockWith {
                    return @(
                        $Script:Entry
                        $Script:SecondEntry
                    )
                }

                Mock -CommandName Invoke-DFeDocumentProcessing -MockWith {
                    if ($Entry.chave_acesso -eq $Script:Entry.chave_acesso) {
                        throw [System.InvalidOperationException]::new('First document failed.')
                    }
                }

                $result = Invoke-TestCompany

                $result.Status | Should -Be 'Falha'

                $shouldParams = @{
                    CommandName = 'Invoke-DFeDocumentProcessing'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'It'
                    Exactly     = $true
                    Times       = 2
                }

                Should -Invoke @shouldParams

                $secondShouldParams = @{
                    CommandName     = 'Invoke-DFeDocumentProcessing'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'It'
                    Exactly         = $true
                    Times           = 1
                    ParameterFilter = {
                        $Entry.chave_acesso -eq $Script:SecondEntry.chave_acesso
                    }
                }

                Should -Invoke @secondShouldParams
            }

            It 'Blocks archive after an Indexed document processing failure' {
                Mock -CommandName Invoke-DFeDocumentProcessing -MockWith {
                    throw [System.InvalidOperationException]::new('Fiscal processing failed.')
                }

                $result = Invoke-TestCompany

                $result.Status | Should -Be 'Falha'

                $shouldParams = @{
                    CommandName = 'New-DFeArchive'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'It'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke @shouldParams
            }
        }
        #endregion

        #region No documents
        Context 'No documents found in the period' {

            BeforeEach {

                Mock -CommandName Get-DFeDocumentEntry

                $Script:Result = Invoke-TestCompany
            }

            It 'Returns Status Aviso' {
                $Script:Result.Status | Should -Be 'Aviso'
            }

            It 'Returns TotalDocumentos 0' {
                $Script:Result.TotalDocumentos | Should -Be 0
            }

            It 'Records a warning in Avisos' {
                $Script:Result.Avisos | Should -HaveCount 1
            }

            It 'Does not process fiscal documents' {
                $shouldParams = @{
                    CommandName = 'Invoke-DFeDocumentProcessing'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'It'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke @shouldParams
            }

            It 'Does not call Get-DFeSequenceGap' {
                $shouldParams = @{
                    CommandName = 'Get-DFeSequenceGap'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'It'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke @shouldParams
            }

            It 'Does not call New-DFeArchive' {
                $shouldParams = @{
                    CommandName = 'New-DFeArchive'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'It'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke @shouldParams
            }

            It 'Does not call Send-DFeNotification' {
                $shouldParams = @{
                    CommandName = 'Send-DFeNotification'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'It'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke @shouldParams
            }

            It 'Returns Erro as null' {
                $Script:Result.Erro | Should -BeNullOrEmpty
            }
        }
        #endregion

        #region SMTP
        Context 'SMTP not configured' {

            BeforeEach {

                Mock -CommandName Resolve-DFeSmtp -MockWith {
                    throw [System.InvalidOperationException]::new(
                        'SMTP not configured.'
                    )
                }

                $Script:Result = Invoke-TestCompany
            }

            It 'Returns Status Aviso' {
                $Script:Result.Status | Should -Be 'Aviso'
            }

            It 'Records a warning about missing SMTP in Avisos' {
                $Script:Result.Avisos |
                    Should -Contain (
                        'SMTP não configurado - notificação por e-mail ignorada. ' +
                        'Execute Set-PipeSmtp para configurar.'
                    )
            }

            It 'Does not call Send-DFeNotification' {
                $shouldParams = @{
                    CommandName = 'Send-DFeNotification'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'It'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke @shouldParams
            }

            It 'Returns EmailEnviado false' {
                $Script:Result.EmailEnviado | Should -BeFalse
            }

            It 'Returns Erro as null' {
                $Script:Result.Erro | Should -BeNullOrEmpty
            }
        }

        Context 'SMTP configured but no recipients' {

            BeforeEach {

                $Script:Result = Invoke-TestCompany -Company $Script:CompanyWithoutRecipients
            }

            It 'Returns Status Aviso' {
                $Script:Result.Status | Should -Be 'Aviso'
            }

            It 'Records a warning about missing recipients in Avisos' {
                $Script:Result.Avisos |
                    Should -Contain (
                        'Nenhum destinatário configurado - notificação por e-mail ignorada. ' +
                        'Configure os destinatários com Set-PipeCompany.'
                    )
            }

            It 'Does not call Send-DFeNotification' {
                $shouldParams = @{
                    CommandName = 'Send-DFeNotification'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'It'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke @shouldParams
            }

            It 'Returns EmailEnviado false' {
                $Script:Result.EmailEnviado | Should -BeFalse
            }
        }
        #endregion

        #region Notification
        Context 'Notification delivery failure' {

            BeforeEach {

                Mock -CommandName Send-DFeNotification -MockWith {
                    return $Script:NotificationFailure
                }

                $Script:Result = Invoke-TestCompany
            }

            It 'Returns Status Aviso' {
                $Script:Result.Status | Should -Be 'Aviso'
            }

            It 'Records a warning about the failed notification in Avisos' {
                $Script:Result.Avisos |
                    Should -Contain "Falha no envio da notificação em 'Send': Connection refused."
            }

            It 'Returns EmailEnviado false' {
                $Script:Result.EmailEnviado | Should -BeFalse
            }

            It 'Returns Erro as null' {
                $Script:Result.Erro | Should -BeNullOrEmpty
            }
        }
        #endregion

        #region Fatal errors
        Context 'Initialize-DFeIndex throws' {

            BeforeEach {

                Mock -CommandName Initialize-DFeIndex -MockWith {
                    throw [System.IO.IOException]::new('Disk full.')
                }

                $Script:Result = Invoke-TestCompany
            }

            It 'Returns Status Falha' {
                $Script:Result.Status | Should -Be 'Falha'
            }

            It 'Captures the error message in Erro' {
                $Script:Result.Erro | Should -Be 'Disk full.'
            }

            It 'Does not call Repair-DFeDocumentProcessing' {
                $shouldParams = @{
                    CommandName = 'Repair-DFeDocumentProcessing'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'It'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke @shouldParams
            }

            It 'Does not call Invoke-DFeXmlScan' {
                $shouldParams = @{
                    CommandName = 'Invoke-DFeXmlScan'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'It'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke @shouldParams
            }
        }

        Context 'Repair-DFeDocumentProcessing throws' {

            BeforeEach {

                Mock -CommandName Repair-DFeDocumentProcessing -MockWith {
                    throw [System.IO.IOException]::new('Repair failed.')
                }

                $Script:Result = Invoke-TestCompany
            }

            It 'Returns Status Falha' {
                $Script:Result.Status | Should -Be 'Falha'
            }

            It 'Captures the error message in Erro' {
                $Script:Result.Erro | Should -Be 'Repair failed.'
            }

            It 'Does not call Invoke-DFeXmlScan' {
                $shouldParams = @{
                    CommandName = 'Invoke-DFeXmlScan'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'It'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke @shouldParams
            }
        }

        Context 'Invoke-DFeXmlScan throws' {

            BeforeEach {

                Mock -CommandName Invoke-DFeXmlScan -MockWith {
                    throw [System.UnauthorizedAccessException]::new('Access denied.')
                }

                $Script:Result = Invoke-TestCompany
            }

            It 'Returns Status Falha' {
                $Script:Result.Status | Should -Be 'Falha'
            }

            It 'Captures the error message in Erro' {
                $Script:Result.Erro | Should -Be 'Access denied.'
            }

            It 'Does not call Get-DFeDocumentEntry' {
                $shouldParams = @{
                    CommandName = 'Get-DFeDocumentEntry'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'It'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke @shouldParams
            }
        }

        Context 'New-DFeArchive throws' {

            BeforeEach {

                Mock -CommandName New-DFeArchive -MockWith {
                    throw [System.IO.IOException]::new('ZIP creation failed.')
                }

                $Script:Result = Invoke-TestCompany
            }

            It 'Returns Status Falha' {
                $Script:Result.Status | Should -Be 'Falha'
            }

            It 'Captures the error message in Erro' {
                $Script:Result.Erro | Should -Be 'ZIP creation failed.'
            }

            It 'Does not call Send-DFeNotification' {
                $shouldParams = @{
                    CommandName = 'Send-DFeNotification'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'It'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke @shouldParams
            }

            It 'Uses the mocked fiscal processing dependency' {
                $shouldParams = @{
                    CommandName = 'Invoke-DFeDocumentProcessing'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'It'
                    Exactly     = $true
                    Times       = 1
                }

                Should -Invoke @shouldParams
            }
        }
        #endregion

        #region Never throws
        Context 'Never throws' {

            It 'Does not throw when Initialize-DFeIndex throws' {
                Mock -CommandName Initialize-DFeIndex -MockWith {
                    throw [System.InvalidOperationException]::new('boom')
                }

                { Invoke-TestCompany } | Should -Not -Throw
            }

            It 'Does not throw when Repair-DFeDocumentProcessing throws' {
                Mock -CommandName Repair-DFeDocumentProcessing -MockWith {
                    throw [System.InvalidOperationException]::new('boom')
                }

                { Invoke-TestCompany } | Should -Not -Throw
            }

            It 'Does not throw when Get-DFeDocumentEntry throws' {
                Mock -CommandName Get-DFeDocumentEntry -MockWith {
                    throw [System.InvalidOperationException]::new('boom')
                }

                { Invoke-TestCompany } | Should -Not -Throw
            }

            It 'Does not throw when Invoke-DFeDocumentProcessing throws' {
                Mock -CommandName Invoke-DFeDocumentProcessing -MockWith {
                    throw [System.InvalidOperationException]::new('boom')
                }

                { Invoke-TestCompany } | Should -Not -Throw
            }

            It 'Does not throw when New-DFeArchive throws' {
                Mock -CommandName New-DFeArchive -MockWith {
                    throw [System.InvalidOperationException]::new('boom')
                }

                { Invoke-TestCompany } | Should -Not -Throw
            }
        }
        #endregion

        #region Return type contract
        Context 'Return type contract' {

            BeforeEach {

                $Script:Result = Invoke-TestCompany
            }

            It 'Returns exactly one object' {
                @($Script:Result) | Should -HaveCount 1
            }

            It 'Cnpj is a string' {
                $Script:Result.Cnpj | Should -BeOfType ([string])
            }

            It 'RazaoSocial is a string' {
                $Script:Result.RazaoSocial | Should -BeOfType ([string])
            }

            It 'Status is a string' {
                $Script:Result.Status | Should -BeOfType ([string])
            }

            It 'TotalDocumentos is an int' {
                $Script:Result.TotalDocumentos | Should -BeOfType ([int])
            }

            It 'Gaps is an int' {
                $Script:Result.Gaps | Should -BeOfType ([int])
            }

            It 'Arquivos is an array' {
                ($Script:Result.Arquivos -is [array]) | Should -BeTrue
                $Script:Result.Arquivos | Should -HaveCount 1
            }

            It 'EmailEnviado is a bool' {
                $Script:Result.EmailEnviado | Should -BeOfType ([bool])
            }

            It 'Avisos is an array' {
                ($Script:Result.Avisos -is [array]) | Should -BeTrue
                $Script:Result.Avisos | Should -HaveCount 0
            }

            It 'Erro is null on success' {
                $Script:Result.Erro | Should -BeNullOrEmpty
            }

            It 'Scan exposes the expected counters' {
                @($Script:Result.Scan.PSObject.Properties.Name) | Should -Be @(
                    'FilesFound'
                    'FilesIndexed'
                    'FilesSkipped'
                    'FilesIgnored'
                )
            }
        }
        #endregion
    }
}
