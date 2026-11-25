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
  - Initializes the SQLite index via Initialize-DFeIndex.
  - Repairs abandoned Processing states via Repair-DFeDocumentProcessing.
  - Uses a 30-minute abandonment threshold in the company pipeline.
  - A repair failure is fatal and prevents scanning.
  - Repaired Failed documents are blocked by the normal fiscal state policy.
  - Queries indexed DFe documents and NFS-e entries for the requested period.
  - Processes only Indexed NF-e, NFC-e and NFCom documents.
  - Does not reprocess Processed NF-e, NFC-e and NFCom documents.
  - Failed or Processing NF-e, NFC-e and NFCom documents block archive
    and delivery.
  - A processing failure does not prevent the remaining eligible documents
    from being attempted.
  - Unsupported document models do not enter the fiscal processing workflow.
  - Returns Status = 'Aviso' when no documents are found in the period.
  - Detects sequence gaps and creates archives when delivery is allowed.
  - Sends notifications when SMTP and recipients are available.
  - Returns Status = 'Aviso' for non-fatal notification configuration
    or delivery failures.
  - Returns Status = 'Falha' and never throws when a fatal pipeline step
    fails.
  - Never calls real repair or document processing from this unit suite.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseShouldProcessForStateChangingFunctions',
    '',
    Justification = 'ShouldProcess would add no value here.'
)]

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSReviewUnusedParameter',
    '',
    Justification = 'Required by the mock signature for New-DFeArchive.'
)]

param ()

BeforeDiscovery {
    # InModuleScope needs to resolve the PipeDFe module during the Discovery
    # phase, because that's when Context/It are executed to register the test
    # tree. If the module isn't loaded at that point, InModuleScope fails
    # before any BeforeAll or BeforeEach ever runs.
    $moduleRoot = (Get-Item $PSScriptRoot).Parent.Parent.Parent.Parent.FullName

    $moduleName = Join-Path -Path $moduleRoot -ChildPath 'PipeDFe.psd1'

    Import-Module -Name $moduleName -Force -Global -ErrorAction Stop
}

Describe 'Invoke-PipeDFeCompany' -Tag 'Unit' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            $Script:Cnpj = '12345678000199'

            $Script:Company = [PSCustomObject]@{
                Cnpj         = $Script:Cnpj
                RazaoSocial  = 'EMPRESA TESTE LTDA'
                NomeFantasia = [string]::Empty
                XmlPath      = 'C:\xml'
                OutputPath   = 'C:\output'
                Email        = [PSCustomObject]@{
                    Para = @('dest@exemplo.com.br')
                    Cc   = @()
                    Cco  = @()
                }
            }

            $Script:CompanyWithoutRecipients = [PSCustomObject]@{
                Cnpj         = $Script:Cnpj
                RazaoSocial  = 'EMPRESA TESTE LTDA'
                NomeFantasia = [string]::Empty
                XmlPath      = 'C:\xml'
                OutputPath   = 'C:\output'
                Email        = [PSCustomObject]@{
                    Para = @()
                    Cc   = @()
                    Cco  = @()
                }
            }

            $Script:DateRange = [PSCustomObject]@{
                Start = [System.DateTimeOffset]::new(
                    2026, 8, 1, 0, 0, 0, [System.TimeSpan]::Zero
                )
                End = [System.DateTimeOffset]::new(
                    2026, 8, 31, 23, 59, 59, [System.TimeSpan]::Zero
                )
            }

            $Script:Entry = [PSCustomObject]@{
                chave_acesso          = '35260112345678000199550010000000011234567890'
                modelo                = 55
                direcao               = 'Saida'
                dh_emi                = '2026-08-15T10:00:00+00:00'
                file_path             = 'C:\xml\nfe.xml'
                is_proc               = $false
                ndoc                  = 1
                serie                 = '001'
                sha256                = 'aaaa' * 16
                indexed_at            = '2026-08-15T10:00:00+00:00'
                processing_status     = 'Indexed'
                processing_started_at = $null
                processed_at          = $null
                processing_error      = $null
            }

            $Script:SecondEntry = [PSCustomObject]@{
                chave_acesso          = '35260112345678000199550010000000021234567891'
                modelo                = 65
                direcao               = $null
                dh_emi                = '2026-08-16T10:00:00+00:00'
                file_path             = 'C:\xml\nfce.xml'
                is_proc               = $false
                ndoc                  = 2
                serie                 = '001'
                sha256                = 'bbbb' * 16
                indexed_at            = '2026-08-16T10:00:00+00:00'
                processing_status     = 'Indexed'
                processing_started_at = $null
                processed_at          = $null
                processing_error      = $null
            }

            $Script:ArchiveInfo = [PSCustomObject]@{
                TipoDFe  = 'NFe'
                FileName = 'NFe_12345678000199_EMPRESA_TESTE_202608.zip'
                TempPath = 'C:\temp\NFe_12345678000199_EMPRESA_TESTE_202608.zip'
                DestPath = 'C:\output\NFe_12345678000199_EMPRESA_TESTE_202608.zip'
            }

            $Script:Archive = [PSCustomObject]@{
                TipoDFe  = 'NFe'
                FileName = 'NFe_12345678000199_EMPRESA_TESTE_202608.zip'
                FileHash = 'deadbeef'
                TempPath = 'C:\temp\NFe_12345678000199_EMPRESA_TESTE_202608.zip'
                DestPath = 'C:\output\NFe_12345678000199_EMPRESA_TESTE_202608.zip'
            }

            $Script:Smtp = [PSCustomObject]@{
                Host = 'smtp.exemplo.com.br'
                Port = 587
            }

            $Script:NotificationSuccess = [PSCustomObject]@{
                Success      = $true
                EmailsSent   = @('dest@exemplo.com.br')
                ErrorMessage = $null
                FailedAt     = $null
            }

            $Script:NotificationFailure = [PSCustomObject]@{
                Success      = $false
                EmailsSent   = @()
                ErrorMessage = 'Connection refused.'
                FailedAt     = 'Send'
            }

            $Script:RepairEmpty = [PSCustomObject]@{
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

                [PSCustomObject]@{
                    chave_acesso          = $Entry.chave_acesso
                    modelo                = [int]$Modelo
                    direcao               = $Entry.direcao
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

        BeforeAll {

            Mock -CommandName Initialize-DFeIndex -MockWith {
                return 'C:\store\12345678000199\index.db'
            }

            Mock -CommandName Repair-DFeDocumentProcessing -MockWith {
                return $Script:RepairEmpty
            }

            Mock -CommandName Invoke-DFeXmlScan -MockWith {
                return [PSCustomObject]@{
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
                param (
                    [Parameter()]
                    [string]$Cnpj,

                    [Parameter()]
                    [pscustomobject]$Company,

                    [Parameter()]
                    [pscustomobject[]]$Entries,

                    [Parameter()]
                    [pscustomobject[]]$ArchiveInfos,

                    [Parameter()]
                    [pscustomobject]$DateRange
                )

                return $Script:Archive
            }

            Mock -CommandName Resolve-DFeSmtp -MockWith {
                return $Script:Smtp
            }

            Mock -CommandName Invoke-DFeDelivery -MockWith {
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

            BeforeAll {
                $Script:HappyResult = Invoke-TestCompany
            }

            It 'Returns a PipeDFe.ResultadoEmpresa object' {
                $Script:HappyResult.PSTypeNames | Should -Contain 'PipeDFe.ResultadoEmpresa'
            }

            It 'Calls Initialize-DFeIndex once with the correct Cnpj' {
                $shouldParams = @{
                    CommandName     = 'Initialize-DFeIndex'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'Context'
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
                    Scope           = 'Context'
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
                    Scope           = 'Context'
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
                    Scope           = 'Context'
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
                    Scope           = 'Context'
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
                    Scope       = 'Context'
                    Exactly     = $true
                    Times       = 1
                }

                Should -Invoke @shouldParams
            }

            It 'Calls Resolve-DFeArchiveInfo once per document type' {
                $shouldParams = @{
                    CommandName = 'Resolve-DFeArchiveInfo'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'Context'
                    Exactly     = $true
                    Times       = 1
                }

                Should -Invoke @shouldParams
            }

            It 'Calls New-DFeArchive once' {
                $shouldParams = @{
                    CommandName = 'New-DFeArchive'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'Context'
                    Exactly     = $true
                    Times       = 1
                }

                Should -Invoke @shouldParams
            }

            It 'Calls Invoke-DFeDelivery once' {
                $shouldParams = @{
                    CommandName = 'Invoke-DFeDelivery'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'Context'
                    Exactly     = $true
                    Times       = 1
                }

                Should -Invoke @shouldParams
            }

            It 'Returns Status OK' {
                $Script:HappyResult.Status | Should -Be 'OK'
            }

            It 'Returns TotalDocumentos matching the entry count' {
                $Script:HappyResult.TotalDocumentos | Should -Be 1
            }

            It 'Returns the archive file name' {
                $Script:HappyResult.Arquivos | Should -Contain $Script:Archive.FileName
            }

            It 'Returns EmailEnviado true' {
                $Script:HappyResult.EmailEnviado | Should -BeTrue
            }

            It 'Returns an empty Avisos array' {
                $Script:HappyResult.Avisos | Should -HaveCount 0
            }

            It 'Returns Erro as null' {
                $Script:HappyResult.Erro | Should -BeNullOrEmpty
            }
        }
        #endregion

        #region NFS-e Nacional import
        Context 'NFS-e Nacional import' {

            Context 'XmlPathNfse configured' {

                BeforeAll {

                    $Script:NfseCompany  = $Script:Company.PSObject.Copy()

                    $nfseAddMemberParams = @{
                        NotePropertyName  = 'XmlPathNfse'
                        NotePropertyValue = 'C:\nfse'
                    }

                    $Script:NfseCompany | Add-Member @nfseAddMemberParams

                    Mock -CommandName Invoke-DFeNFSeXmlScan -MockWith {
                        [pscustomobject]@{
                            FilesFound    = 1
                            FilesImported = 1
                            FilesIgnored  = 0
                        }
                    }

                    Mock -CommandName Get-DFeNFSeEntry -MockWith {
                        @()
                    }

                    $Script:NfseResult = Invoke-TestCompany -Company $Script:NfseCompany
                }

                It 'Calls Invoke-DFeNFSeXmlScan with the correct path' {
                    $shouldParams = @{
                        CommandName     = 'Invoke-DFeNFSeXmlScan'
                        ModuleName      = 'PipeDFe'
                        Scope           = 'Context'
                        Exactly         = $true
                        Times           = 1
                        ParameterFilter = {
                            $Cnpj -eq $Script:Cnpj -and $XmlPath -eq 'C:\nfse'
                        }
                    }

                    Should -Invoke @shouldParams
                }

                It 'Populates NFSeScan in the result' {
                    $Script:NfseResult.NFSeScan.FilesImported | Should -Be 1
                }
            }

            Context 'XmlPathNfse absent' {

                BeforeAll {

                    Mock -CommandName Invoke-DFeNFSeXmlScan -MockWith {

                    }

                    $Script:NoNfseResult = Invoke-TestCompany
                }

                It 'Does not invoke the NFS-e scanner' {
                    $shouldParams = @{
                        CommandName = 'Invoke-DFeNFSeXmlScan'
                        ModuleName  = 'PipeDFe'
                        Scope       = 'Context'
                        Exactly     = $true
                        Times       = 0
                    }

                    Should -Invoke @shouldParams
                }

                It 'Returns NFSeScan as null' {
                    $Script:NoNfseResult.NFSeScan | Should -BeNullOrEmpty
                }

                It 'Returns Status OK' {
                    $Script:NoNfseResult.Status | Should -Be 'OK'
                }
            }

            Context 'NFS-e scanner throws' {

                BeforeAll {
                    $Script:NfseFailCompany  = $Script:Company.PSObject.Copy()

                    $nfseFailAddMemberParams = @{
                        NotePropertyName  = 'XmlPathNfse'
                        NotePropertyValue = 'C:\nfse'
                    }

                    $Script:NfseFailCompany | Add-Member @nfseFailAddMemberParams

                    Mock -CommandName Invoke-DFeNFSeXmlScan -MockWith {
                        throw 'Unable to import NFS-e.'
                    }

                    $Script:NfseFailResult = Invoke-TestCompany -Company $Script:NfseFailCompany
                }

                It 'Returns Status Falha' {
                    $Script:NfseFailResult.Status | Should -Be 'Falha'
                }

                It 'Captures the error message in Erro' {
                    $Script:NfseFailResult.Erro | Should -Be 'Unable to import NFS-e.'
                }

                It 'Does not call New-DFeArchive' {
                    $shouldParams = @{
                        CommandName = 'New-DFeArchive'
                        ModuleName  = 'PipeDFe'
                        Scope       = 'Context'
                        Exactly     = $true
                        Times       = 0
                    }

                    Should -Invoke @shouldParams
                }
            }
        }
        #endregion

        #region Processing state repair
        Context 'Processing state repair' {

            Context 'Runs Initialize, Repair and Scan in that order' {

                BeforeAll {

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

                        return [PSCustomObject]@{
                            FilesFound   = 3
                            FilesIndexed = 2
                            FilesSkipped = 1
                            FilesIgnored = 0
                        }
                    }

                    Invoke-TestCompany | Out-Null
                }

                It 'Records exactly 3 steps' {
                    $Script:CallOrder | Should -HaveCount 3
                }

                It 'Calls Initialize first' {
                    $Script:CallOrder[0] | Should -Be 'Initialize'
                }

                It 'Calls Repair second' {
                    $Script:CallOrder[1] | Should -Be 'Repair'
                }

                It 'Calls Scan third' {
                    $Script:CallOrder[2] | Should -Be 'Scan'
                }
            }

            Context 'No Processing documents found' {

                BeforeAll {
                    $Script:NoRepairResult = Invoke-TestCompany
                }

                It 'Allows the normal pipeline' {
                    $Script:NoRepairResult.Status | Should -Be 'OK'
                }

                It 'Does not add repair activity to Avisos' {
                    $Script:NoRepairResult.Avisos | Should -HaveCount 0
                }
            }

            Context 'Repair recovers abandoned documents' {

                BeforeAll {
                    $repairResult = [PSCustomObject]@{
                        ProcessingFound     = 2
                        Active              = 1
                        Recovered           = 1
                        Inconsistent        = 0
                        ConcurrentlyChanged = 0
                    }

                    Mock -CommandName Repair-DFeDocumentProcessing -MockWith {
                        return $repairResult
                    }

                    $Script:RepairRecoverResult = Invoke-TestCompany
                }

                It 'Continues pipeline after recovery' {
                    $Script:RepairRecoverResult.Status | Should -Be 'OK'
                }

                It 'Does not surface recovery in Avisos' {
                    $Script:RepairRecoverResult.Avisos | Should -HaveCount 0
                }
            }

            Context 'Repaired document re-appears as Failed in the period query' {

                BeforeAll {
                    $repairResult = [PSCustomObject]@{
                        ProcessingFound     = 1
                        Active              = 0
                        Recovered           = 1
                        Inconsistent        = 0
                        ConcurrentlyChanged = 0
                    }

                    $entryParams = @{
                        Entry            = $Script:Entry
                        ProcessingStatus = 'Failed'
                        ProcessingError  = 'Processing recovery marked the document as Failed.'
                    }

                    $failedEntry = Copy-TestEntry @entryParams

                    Mock -CommandName Repair-DFeDocumentProcessing -MockWith {
                        return $repairResult
                    }

                    Mock -CommandName Get-DFeDocumentEntry -MockWith {
                        return $failedEntry
                    }

                    $Script:RepairedFailedResult = Invoke-TestCompany
                }

                It 'Returns Status Falha' {
                    $Script:RepairedFailedResult.Status | Should -Be 'Falha'
                }

                It 'Reports unresolved fiscal processing in Erro' {
                    $Script:RepairedFailedResult.Erro |
                        Should -Match 'processamento fiscal não concluído'
                }

                It 'Does not call New-DFeArchive' {
                    $shouldParams = @{
                        CommandName = 'New-DFeArchive'
                        ModuleName  = 'PipeDFe'
                        Scope       = 'Context'
                        Exactly     = $true
                        Times       = 0
                    }

                    Should -Invoke @shouldParams
                }

                It 'Does not call Invoke-DFeDelivery' {
                    $shouldParams = @{
                        CommandName = 'Invoke-DFeDelivery'
                        ModuleName  = 'PipeDFe'
                        Scope       = 'Context'
                        Exactly     = $true
                        Times       = 0
                    }

                    Should -Invoke @shouldParams
                }
            }
        }
        #endregion

        #region Fiscal processing selection
        Context 'Fiscal processing selection' {

            Context 'Indexed NFCom is processed before archive generation' {

                BeforeAll {

                    $Script:NFComEntry = Copy-TestEntry -Entry $Script:Entry -Modelo 62
                    $Script:NFComEntry.chave_acesso = '35260812345678000199620010000000011234567890'
                    $Script:NFComProcessed          = $false
                    $Script:NFComProcessedAtArchive = $false

                    Mock -CommandName Get-DFeDocumentEntry -MockWith {
                        return $Script:NFComEntry
                    }

                    Mock -CommandName Invoke-DFeDocumentProcessing -MockWith {
                        $Script:NFComProcessed = $true
                    } -ParameterFilter {
                        $Entry.modelo -eq 62 -and
                        $Entry.chave_acesso -eq $Script:NFComEntry.chave_acesso
                    }

                    Mock -CommandName New-DFeArchive -MockWith {
                        param (
                            [Parameter()]
                            [string]$Cnpj,

                            [Parameter()]
                            [pscustomobject]$Company,

                            [Parameter()]
                            [pscustomobject[]]$Entries,

                            [Parameter()]
                            [pscustomobject[]]$ArchiveInfos,

                            [Parameter()]
                            [pscustomobject]$DateRange
                        )

                        $Script:NFComProcessedAtArchive = $Script:NFComProcessed
                        return $Script:Archive
                    }

                    $Script:NFComResult = Invoke-TestCompany
                }

                It 'Returns Status OK' {
                    $Script:NFComResult.Status | Should -Be 'OK'
                }

                It 'Processing flag was set before archive creation' {
                    $Script:NFComProcessedAtArchive | Should -BeTrue
                }
            }

            It 'Does not process a Processed document of model <Model>' -ForEach @(
                @{ Model = 55 }
                @{ Model = 62 }
                @{ Model = 65 }
            ) {
                param ($Model)

                $entryParams = @{
                    Entry            = $Script:Entry
                    ProcessingStatus = 'Processed'
                    Modelo           = $Model
                }

                $processedEntry = Copy-TestEntry @entryParams

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
                $entryParams = @{
                    Entry            = $Script:Entry
                    ProcessingStatus = 'Indexed'
                    Modelo           = 57
                }

                $cteEntry = Copy-TestEntry @entryParams

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

            It 'Blocks archive and notification when model <Model> is Failed' -ForEach @(
                @{ Model = 55 }
                @{ Model = 62 }
                @{ Model = 65 }
            ) {
                param ($Model)

                $entryParams = @{
                    Entry            = $Script:Entry
                    ProcessingStatus = 'Failed'
                    Modelo           = $Model
                    ProcessingError  = 'Invalid XML.'
                }

                $failedEntry = Copy-TestEntry @entryParams

                Mock -CommandName Get-DFeDocumentEntry -MockWith {
                    return $failedEntry
                }

                $result = Invoke-TestCompany

                $result.Status | Should -Be 'Falha'
                $result.Erro | Should -Match 'processamento fiscal não concluído'

                $shouldParams = @{
                    CommandName = 'New-DFeArchive'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'It'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke @shouldParams

                $shouldParams = @{
                    CommandName = 'Invoke-DFeDelivery'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'It'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke @shouldParams
            }

            It 'Blocks archive and notification when model <Model> is Processing' -ForEach @(
                @{ Model = 55 }
                @{ Model = 62 }
                @{ Model = 65 }
            ) {
                param ($Model)

                $entryParams = @{
                    Entry            = $Script:Entry
                    ProcessingStatus = 'Processing'
                    Modelo           = $Model
                }

                $processingEntry = Copy-TestEntry @entryParams

                Mock -CommandName Get-DFeDocumentEntry -MockWith {
                    return $processingEntry
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

                $shouldParams = @{
                    CommandName = 'Invoke-DFeDelivery'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'It'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke @shouldParams
            }

            Context 'Processing failure does not prevent remaining documents' {

                BeforeAll {

                    Mock -CommandName Get-DFeDocumentEntry -MockWith {
                        return @(
                            $Script:Entry
                            $Script:SecondEntry
                        )
                    }

                    Mock -CommandName Invoke-DFeDocumentProcessing -MockWith {
                        if ($Entry.chave_acesso -eq $Script:Entry.chave_acesso) {
                            throw [System.InvalidOperationException]::new(
                                'First document failed.'
                            )
                        }
                    }

                    $Script:PartialFailResult = Invoke-TestCompany
                }

                It 'Returns Status Falha' {
                    $Script:PartialFailResult.Status | Should -Be 'Falha'
                }

                It 'Calls Invoke-DFeDocumentProcessing for every Indexed document' {
                    $shouldParams = @{
                        CommandName = 'Invoke-DFeDocumentProcessing'
                        ModuleName  = 'PipeDFe'
                        Scope       = 'Context'
                        Exactly     = $true
                        Times       = 2
                    }

                    Should -Invoke @shouldParams
                }

                It 'Calls Invoke-DFeDocumentProcessing for the second document' {
                    $shouldParams = @{
                        CommandName     = 'Invoke-DFeDocumentProcessing'
                        ModuleName      = 'PipeDFe'
                        Scope           = 'Context'
                        Exactly         = $true
                        Times           = 1
                        ParameterFilter = {
                            $Entry.chave_acesso -eq $Script:SecondEntry.chave_acesso
                        }
                    }

                    Should -Invoke @shouldParams
                }
            }

            Context 'Archive is blocked after a processing failure' {

                BeforeAll {

                    Mock -CommandName Invoke-DFeDocumentProcessing -MockWith {
                        throw [System.InvalidOperationException]::new(
                            'Fiscal processing failed.'
                        )
                    }

                    $Script:ArchiveBlockResult = Invoke-TestCompany
                }

                It 'Returns Status Falha' {
                    $Script:ArchiveBlockResult.Status | Should -Be 'Falha'
                }

                It 'Does not call New-DFeArchive' {
                    $shouldParams = @{
                        CommandName = 'New-DFeArchive'
                        ModuleName  = 'PipeDFe'
                        Scope       = 'Context'
                        Exactly     = $true
                        Times       = 0
                    }

                    Should -Invoke @shouldParams
                }
            }
        }
        #endregion

        #region No documents
        Context 'No documents found in the period' {

            BeforeAll {

                Mock -CommandName Get-DFeDocumentEntry

                $Script:NoDocsResult = Invoke-TestCompany
            }

            It 'Returns Status Aviso' {
                $Script:NoDocsResult.Status | Should -Be 'Aviso'
            }

            It 'Returns TotalDocumentos 0' {
                $Script:NoDocsResult.TotalDocumentos | Should -Be 0
            }

            It 'Records a warning in Avisos' {
                $Script:NoDocsResult.Avisos | Should -HaveCount 1
            }

            It 'Does not process fiscal documents' {
                $shouldParams = @{
                    CommandName = 'Invoke-DFeDocumentProcessing'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'Context'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke @shouldParams
            }

            It 'Does not call Get-DFeSequenceGap' {
                $shouldParams = @{
                    CommandName = 'Get-DFeSequenceGap'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'Context'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke @shouldParams
            }

            It 'Does not call New-DFeArchive' {
                $shouldParams = @{
                    CommandName = 'New-DFeArchive'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'Context'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke @shouldParams
            }

            It 'Does not call Invoke-DFeDelivery' {
                $shouldParams = @{
                    CommandName = 'Invoke-DFeDelivery'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'Context'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke @shouldParams
            }

            It 'Returns Erro as null' {
                $Script:NoDocsResult.Erro | Should -BeNullOrEmpty
            }
        }
        #endregion

        #region SMTP
        Context 'SMTP not configured' {

            BeforeAll {

                Mock -CommandName Resolve-DFeSmtp -MockWith {
                    throw [System.Management.Automation.ErrorRecord]::new(
                        [System.InvalidOperationException]::new('SMTP not configured.'),
                        'SmtpNotConfigured',
                        [System.Management.Automation.ErrorCategory]::InvalidOperation,
                        $null
                    )
                }

                $Script:NoSmtpResult = Invoke-TestCompany
            }

            It 'Returns Status Falha' {
                $Script:NoSmtpResult.Status | Should -Be 'Falha'
            }

            It 'Records a warning about missing SMTP in Avisos' {
                $Script:NoSmtpResult.Avisos |
                    Should -Contain (
                        'A entrega dos arquivos XML não foi concluída porque ' +
                        'não há configuração SMTP para esta empresa. ' +
                        'Execute Set-PipeSmtp para configurar.'
                    )
            }

            It 'Does not call Invoke-DFeDelivery' {
                $shouldParams = @{
                    CommandName = 'Invoke-DFeDelivery'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'Context'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke @shouldParams
            }

            It 'Returns EmailEnviado false' {
                $Script:NoSmtpResult.EmailEnviado | Should -BeFalse
            }

            It 'Explains in Erro that delivery failed because SMTP is missing' {
                $Script:NoSmtpResult.Erro | Should -Match 'não há configuração SMTP'
                $Script:NoSmtpResult.Erro | Should -Match 'Set-PipeSmtp'
            }
        }

        Context 'Unreadable SMTP configuration' {

            BeforeAll {

                Mock -CommandName Resolve-DFeSmtp -MockWith {
                    throw [System.IO.InvalidDataException]::new(
                        'Invalid SMTP configuration.'
                    )
                }

                $Script:BadSmtpResult = Invoke-TestCompany
            }

            It 'Returns Status Falha' {
                $Script:BadSmtpResult.Status | Should -Be 'Falha'
            }

            It 'Reports the configuration error in Erro' {
                $Script:BadSmtpResult.Erro |
                    Should -Match 'a configuração SMTP não pôde ser carregada'

                $Script:BadSmtpResult.Erro |
                    Should -Match 'Invalid SMTP configuration.'
            }
        }

        Context 'SMTP configured but no recipients' {

            BeforeAll {

                $Script:NoRecipientsResult = Invoke-TestCompany -Company $Script:CompanyWithoutRecipients
            }

            It 'Returns Status Falha' {
                $Script:NoRecipientsResult.Status | Should -Be 'Falha'
            }

            It 'Reports that XML delivery was not completed in Erro' {
                $Script:NoRecipientsResult.Erro |
                    Should -Match 'A entrega dos arquivos XML não foi concluída'
            }

            It 'Records a warning about missing recipients in Avisos' {
                $Script:NoRecipientsResult.Avisos |
                    Should -Contain (
                        'Nenhum destinatário configurado - notificação por e-mail ignorada. ' +
                        'Configure os destinatários com Set-PipeCompany.'
                    )
            }

            It 'Does not call Invoke-DFeDelivery' {
                $shouldParams = @{
                    CommandName = 'Invoke-DFeDelivery'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'Context'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke @shouldParams
            }

            It 'Returns EmailEnviado false' {
                $Script:NoRecipientsResult.EmailEnviado | Should -BeFalse
            }
        }
        #endregion

        #region Notification
        Context 'Notification delivery failure' {

            BeforeAll {

                Mock -CommandName Invoke-DFeDelivery -MockWith {
                    return $Script:NotificationFailure
                }

                $Script:DeliveryFailResult = Invoke-TestCompany
            }

            It 'Returns Status Falha' {
                $Script:DeliveryFailResult.Status | Should -Be 'Falha'
            }

            It 'Reports that XML delivery was not completed in Erro' {
                $Script:DeliveryFailResult.Erro |
                    Should -Match 'A entrega dos arquivos XML não foi concluída'
            }

            It 'Records a warning about the failed notification in Avisos' {
                $Script:DeliveryFailResult.Avisos |
                    Should -Contain "Falha no envio da notificação em 'Send': Connection refused."
            }

            It 'Returns EmailEnviado false' {
                $Script:DeliveryFailResult.EmailEnviado | Should -BeFalse
            }
        }
        #endregion

        #region Fatal errors
        Context 'Initialize-DFeIndex throws' {

            BeforeAll {

                Mock -CommandName Initialize-DFeIndex -MockWith {
                    throw [System.IO.IOException]::new('Disk full.')
                }

                $Script:InitFailResult = Invoke-TestCompany
            }

            It 'Returns Status Falha' {
                $Script:InitFailResult.Status | Should -Be 'Falha'
            }

            It 'Captures the error message in Erro' {
                $Script:InitFailResult.Erro | Should -Be 'Disk full.'
            }

            It 'Does not call Repair-DFeDocumentProcessing' {
                $shouldParams = @{
                    CommandName = 'Repair-DFeDocumentProcessing'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'Context'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke @shouldParams
            }

            It 'Does not call Invoke-DFeXmlScan' {
                $shouldParams = @{
                    CommandName = 'Invoke-DFeXmlScan'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'Context'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke @shouldParams
            }
        }

        Context 'Repair-DFeDocumentProcessing throws' {

            BeforeAll {

                Mock -CommandName Repair-DFeDocumentProcessing -MockWith {
                    throw [System.IO.IOException]::new('Repair failed.')
                }

                $Script:RepairFailResult = Invoke-TestCompany
            }

            It 'Returns Status Falha' {
                $Script:RepairFailResult.Status | Should -Be 'Falha'
            }

            It 'Captures the error message in Erro' {
                $Script:RepairFailResult.Erro | Should -Be 'Repair failed.'
            }

            It 'Does not call Invoke-DFeXmlScan' {
                $shouldParams = @{
                    CommandName = 'Invoke-DFeXmlScan'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'Context'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke @shouldParams
            }
        }

        Context 'Invoke-DFeXmlScan throws' {

            BeforeAll {

                Mock -CommandName Invoke-DFeXmlScan -MockWith {
                    throw [System.UnauthorizedAccessException]::new(
                        'Access denied.'
                    )
                }

                $Script:ScanFailResult = Invoke-TestCompany
            }

            It 'Returns Status Falha' {
                $Script:ScanFailResult.Status | Should -Be 'Falha'
            }

            It 'Captures the error message in Erro' {
                $Script:ScanFailResult.Erro | Should -Be 'Access denied.'
            }

            It 'Does not call Get-DFeDocumentEntry' {
                $shouldParams = @{
                    CommandName = 'Get-DFeDocumentEntry'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'Context'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke @shouldParams
            }
        }

        Context 'New-DFeArchive throws' {

            BeforeAll {
                Mock -CommandName New-DFeArchive -MockWith {
                    param (
                        [Parameter()]
                        [string]$Cnpj,

                        [Parameter()]
                        [pscustomobject]$Company,

                        [Parameter()]
                        [pscustomobject[]]$Entries,

                        [Parameter()]
                        [pscustomobject[]]$ArchiveInfos,

                        [Parameter()]
                        [pscustomobject]$DateRange
                    )

                    throw [System.IO.IOException]::new('ZIP creation failed.')
                }

                $Script:ArchiveFailResult = Invoke-TestCompany
            }

            It 'Returns Status Falha' {
                $Script:ArchiveFailResult.Status | Should -Be 'Falha'
            }

            It 'Captures the error message in Erro' {
                $Script:ArchiveFailResult.Erro | Should -Be 'ZIP creation failed.'
            }

            It 'Does not call Invoke-DFeDelivery' {
                $shouldParams = @{
                    CommandName = 'Invoke-DFeDelivery'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'Context'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke @shouldParams
            }

            It 'Uses the mocked fiscal processing dependency' {
                $shouldParams = @{
                    CommandName = 'Invoke-DFeDocumentProcessing'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'Context'
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
                    param (
                        [Parameter()]
                        [string]$Cnpj,

                        [Parameter()]
                        [pscustomobject]$Company,

                        [Parameter()]
                        [pscustomobject[]]$Entries,

                        [Parameter()]
                        [pscustomobject[]]$ArchiveInfos,

                        [Parameter()]
                        [pscustomobject]$DateRange
                    )

                    throw [System.InvalidOperationException]::new('boom')
                }

                { Invoke-TestCompany } | Should -Not -Throw
            }
        }
        #endregion

        #region Return type contract
        Context 'Return type contract' {

            BeforeAll {

                $Script:ContractResult = Invoke-TestCompany
            }

            It 'Returns exactly one object' {
                @($Script:ContractResult) | Should -HaveCount 1
            }

            It 'Cnpj is a string' {
                $Script:ContractResult.Cnpj | Should -BeOfType ([string])
            }

            It 'RazaoSocial is a string' {
                $Script:ContractResult.RazaoSocial | Should -BeOfType ([string])
            }

            It 'Status is a string' {
                $Script:ContractResult.Status | Should -BeOfType ([string])
            }

            It 'TotalDocumentos is an int' {
                $Script:ContractResult.TotalDocumentos | Should -BeOfType ([int])
            }

            It 'Gaps is an int' {
                $Script:ContractResult.Gaps | Should -BeOfType ([int])
            }

            It 'Arquivos is an array' {
                ($Script:ContractResult.Arquivos -is [array]) | Should -BeTrue
                $Script:ContractResult.Arquivos | Should -HaveCount 1
            }

            It 'EmailEnviado is a bool' {
                $Script:ContractResult.EmailEnviado | Should -BeOfType ([bool])
            }

            It 'Avisos is an array' {
                ($Script:ContractResult.Avisos -is [array]) | Should -BeTrue
                $Script:ContractResult.Avisos | Should -HaveCount 0
            }

            It 'Erro is null on success' {
                $Script:ContractResult.Erro | Should -BeNullOrEmpty
            }

            It 'Scan exposes the expected counters' {
                @($Script:ContractResult.Scan.PSObject.Properties.Name) |
                    Should -Be @(
                        'FilesFound'
                        'FilesIndexed'
                        'FilesSkipped'
                        'FilesIgnored'
                    )
            }
        }
        #endregion

        #region NFe archive direction planning
        Context 'NFe archive direction planning' {

            Context 'Both Entrada and Saida in the same period' {

                BeforeAll {

                    $entradaEntry = Copy-TestEntry -Entry $Script:Entry
                    $entradaEntry.chave_acesso = '3' * 44
                    $entradaEntry.direcao      = 'Entrada'

                    Mock -CommandName Get-DFeDocumentEntry -MockWith {
                        @($Script:Entry, $entradaEntry)
                    }

                    Invoke-TestCompany | Out-Null
                }

                It 'Resolves a separate archive for Entrada' {
                    $shouldParams = @{
                        CommandName     = 'Resolve-DFeArchiveInfo'
                        Scope           = 'Context'
                        Times           = 1
                        Exactly         = $true
                        ParameterFilter = {
                            $TipoDFe -eq 'NFe' -and $Direcao -eq 'Entrada'
                        }
                    }

                    Should -Invoke @shouldParams
                }

                It 'Resolves a separate archive for Saida' {
                    $shouldParams = @{
                        CommandName     = 'Resolve-DFeArchiveInfo'
                        Scope           = 'Context'
                        Times           = 1
                        Exactly         = $true
                        ParameterFilter = {
                            $TipoDFe -eq 'NFe' -and $Direcao -eq 'Saida'
                        }
                    }

                    Should -Invoke @shouldParams
                }
            }

            Context 'Saida only' {

                BeforeAll {
                    Mock -CommandName Get-DFeDocumentEntry -MockWith {
                        return $Script:Entry
                    }

                    Invoke-TestCompany | Out-Null
                }

                It 'Calls Resolve-DFeArchiveInfo exactly once' {
                    $shouldParams = @{
                        CommandName = 'Resolve-DFeArchiveInfo'
                        Scope       = 'Context'
                        Times       = 1
                        Exactly     = $true
                    }
                    Should -Invoke @shouldParams
                }
            }

            Context 'NFe without direction' {

                BeforeAll {

                    $invalidEntry = Copy-TestEntry -Entry $Script:Entry
                    $invalidEntry.direcao = $null

                    Mock -CommandName Get-DFeDocumentEntry -MockWith {
                        return $invalidEntry
                    }

                    $Script:NoDirectionResult = Invoke-TestCompany
                }

                It 'Returns Status Falha' {
                    $Script:NoDirectionResult.Status | Should -Be 'Falha'
                }

                It 'Reports an invalid direction in Erro' {
                    $Script:NoDirectionResult.Erro | Should -Match 'valid direction'
                }

                It 'Does not call New-DFeArchive' {
                    $shouldParams = @{
                        CommandName = 'New-DFeArchive'
                        Scope       = 'Context'
                        Times       = 0
                        Exactly     = $true
                    }
                    Should -Invoke @shouldParams
                }

                It 'Does not call Invoke-DFeDelivery' {
                    $shouldParams = @{
                        CommandName = 'Invoke-DFeDelivery'
                        Scope       = 'Context'
                        Times       = 0
                        Exactly     = $true
                    }
                    Should -Invoke @shouldParams
                }
            }
        }
        #endregion
    }
}
