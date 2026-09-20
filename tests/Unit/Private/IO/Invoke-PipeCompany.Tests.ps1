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
  - Calls Initialize-DFeIndex, Invoke-DFeXmlScan and Get-DFeDocumentEntry
    with the correct arguments on every successful run.
  - Returns Status = 'Aviso' when no documents are found in the period.
  - Calls Get-DFeSequenceGap, Resolve-DFeArchiveInfo and New-DFeArchive
    when documents are present.
  - Calls Resolve-DFeSmtp and Send-DFeNotification when documents and
    recipients are present.
  - Returns EmailEnviado = $true when Send-DFeNotification succeeds.
  - Returns Status = 'Aviso' and records a warning when Send-DFeNotification
    fails.
  - Returns Status = 'Aviso' and records a warning when SMTP is not
    configured.
  - Returns Status = 'Aviso' and records a warning when no recipients are
    configured.
  - Returns Status = 'Falha' and never throws when any pipeline step throws.
  - Never throws under any circumstance.
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

Describe 'Invoke-PipeDFeCompany' {

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

            $Script:DateRange = [PSCustomObject]@{
                Start = [System.DateTimeOffset]::new(
                    2026, 8,  1,  0,  0,  0, [System.TimeSpan]::Zero
                )
                End   = [System.DateTimeOffset]::new(
                    2026, 8, 31, 23, 59, 59, [System.TimeSpan]::Zero
                )
            }

            $Script:Entry = [PSCustomObject]@{
                chave_acesso = '35260112345678000199550010000000011234567890'
                modelo       = 55
                dh_emi       = '2026-08-15T10:00:00+00:00'
                file_path    = 'C:\xml\nfe.xml'
                is_proc      = $false
                ndoc         = 1
                serie        = '001'
                sha256       = 'abc123'
                indexed_at   = '2026-08-15T10:00:00+00:00'
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
        }

        AfterAll {

            Remove-Module -Name PipeDFe -Force -ErrorAction SilentlyContinue
        }

        #region Parameter contract
        Context 'Parameter contract' {

            It 'Declares Company as mandatory' {
                $mandatory = (Get-Command Invoke-PipeDFeCompany).Parameters['Company'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.Mandatory
                    }

                $mandatory | Should -Not -BeNullOrEmpty
            }

            It 'Declares DateRange as mandatory' {
                $mandatory = (Get-Command Invoke-PipeDFeCompany).Parameters['DateRange'].Attributes |
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

                Mock -CommandName Initialize-DFeIndex -MockWith {
                    param ([string]$Cnpj)
                    $null = $Cnpj
                    return 'C:\store\12345678000199\index.db'
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
                    param (
                        [string]$Cnpj,
                        [string]$StartDate,
                        [string]$EndDate
                    )

                    $null = $Cnpj
                    $null = $StartDate
                    $null = $EndDate
                    return $Script:Entry
                }

                Mock -CommandName Get-DFeSequenceGap -MockWith {
                    param ([pscustomobject[]]$Entries)
                    $null = $Entries
                }

                Mock -CommandName Resolve-DFeArchiveInfo -MockWith {
                    param (
                        [string]$TipoDFe,
                        [string]$Cnpj,
                        [pscustomobject]$Company,
                        [pscustomobject]$DateRange
                    )

                    $null = $TipoDFe
                    $null = $Cnpj
                    $null = $Company
                    $null = $DateRange
                    return $Script:ArchiveInfo
                }

                Mock -CommandName New-DFeArchive -MockWith {
                    param (
                        [string]$Cnpj,
                        [pscustomobject]$Company,
                        [pscustomobject[]]$Entries,
                        [pscustomobject[]]$ArchiveInfos
                    )

                    $null = $Cnpj
                    $null = $Company
                    $null = $Entries
                    $null = $ArchiveInfos
                    return $Script:Archive
                }

                Mock -CommandName Resolve-DFeSmtp -MockWith {
                    param ([pscustomobject]$Company)
                    $null = $Company
                    return $Script:Smtp
                }

                Mock -CommandName Send-DFeNotification -MockWith {
                    param (
                        [pscustomobject]$Company,
                        [pscustomobject]$DateRange,
                        [pscustomobject]$Smtp,
                        [pscustomobject[]]$Gaps,
                        [string[]]$ZipFileDestination
                    )

                    $null = $Company
                    $null = $DateRange
                    $null = $Smtp
                    $null = $Gaps
                    $null = $ZipFileDestination
                    return $Script:NotificationSuccess
                }

                $invokeParams = @{
                    Company   = $Script:Company
                    DateRange = $Script:DateRange
                }

                $Script:Result = Invoke-PipeDFeCompany @invokeParams
            }

            It 'Returns a PipeDFe.ResultadoEmpresa object' {
                $Script:Result.PSTypeNames | Should -Contain 'PipeDFe.ResultadoEmpresa'
            }

            It 'Calls Initialize-DFeIndex once with the correct Cnpj' {
                $invokeParams = @{
                    CommandName     = 'Initialize-DFeIndex'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'Context'
                    Exactly         = $true
                    Times           = 1
                    ParameterFilter = { $Cnpj -eq $Script:Cnpj }
                }

                Should -Invoke @invokeParams
            }

            It 'Calls Invoke-DFeXmlScan once with the correct parameters' {
                $invokeParams = @{
                    CommandName     = 'Invoke-DFeXmlScan'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'Context'
                    Exactly         = $true
                    Times           = 1
                    ParameterFilter = {
                        $Cnpj    -eq $Script:Cnpj -and
                        $XmlPath -eq $Script:Company.XmlPath
                    }
                }

                Should -Invoke @invokeParams
            }

            It 'Calls Get-DFeDocumentEntry once with the correct period' {
                $invokeParams = @{
                    CommandName     = 'Get-DFeDocumentEntry'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'Context'
                    Exactly         = $true
                    Times           = 1
                    ParameterFilter = {
                        $Cnpj      -eq $Script:Cnpj -and
                        $StartDate -eq $Script:DateRange.Start.ToString('o') -and
                        $EndDate   -eq $Script:DateRange.End.ToString('o')
                    }
                }

                Should -Invoke @invokeParams
            }

            It 'Calls Get-DFeSequenceGap once' {
                $invokeParams = @{
                    CommandName = 'Get-DFeSequenceGap'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'Context'
                    Exactly     = $true
                    Times       = 1
                }

                Should -Invoke @invokeParams
            }

            It 'Calls Resolve-DFeArchiveInfo once per document type' {
                $invokeParams = @{
                    CommandName = 'Resolve-DFeArchiveInfo'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'Context'
                    Exactly     = $true
                    Times       = 1
                }

                Should -Invoke @invokeParams
            }

            It 'Calls New-DFeArchive once' {
                $invokeParams = @{
                    CommandName = 'New-DFeArchive'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'Context'
                    Exactly     = $true
                    Times       = 1
                }

                Should -Invoke @invokeParams
            }

            It 'Calls Send-DFeNotification once' {
                $invokeParams = @{
                    CommandName = 'Send-DFeNotification'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'Context'
                    Exactly     = $true
                    Times       = 1
                }

                Should -Invoke @invokeParams
            }

            It 'Returns Status OK' {
                $Script:Result.Status | Should -Be 'OK'
            }

            It 'Returns the correct Cnpj' {
                $Script:Result.Cnpj | Should -Be $Script:Cnpj
            }

            It 'Returns the correct RazaoSocial' {
                $Script:Result.RazaoSocial | Should -Be $Script:Company.RazaoSocial
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

        #region No documents
        Context 'No documents found in the period' {

            BeforeAll {

                Mock -CommandName Initialize-DFeIndex -MockWith {
                    param ([string]$Cnpj)
                    $null = $Cnpj
                    return 'C:\store\12345678000199\index.db'
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
                    param (
                        [string]$Cnpj,
                        [string]$StartDate,
                        [string]$EndDate
                    )

                    $null = $Cnpj
                    $null = $StartDate
                    $null = $EndDate
                }

                Mock -CommandName Get-DFeSequenceGap -MockWith {
                    param ([pscustomobject[]]$Entries)
                    $null = $Entries
                }

                Mock -CommandName Resolve-DFeArchiveInfo -MockWith {
                    param (
                        [string]$TipoDFe,
                        [string]$Cnpj,
                        [pscustomobject]$Company,
                        [pscustomobject]$DateRange
                    )

                    $null = $TipoDFe
                    $null = $Cnpj
                    $null = $Company
                    $null = $DateRange
                }

                Mock -CommandName New-DFeArchive -MockWith {
                    param (
                        [string]$Cnpj,
                        [pscustomobject]$Company,
                        [pscustomobject[]]$Entries,
                        [pscustomobject[]]$ArchiveInfos
                    )

                    $null = $Cnpj
                    $null = $Company
                    $null = $Entries
                    $null = $ArchiveInfos
                }

                Mock -CommandName Resolve-DFeSmtp -MockWith {
                    param ([pscustomobject]$Company)
                    $null = $Company
                }

                Mock -CommandName Send-DFeNotification -MockWith {
                    param (
                        [pscustomobject]$Company,
                        [pscustomobject]$DateRange,
                        [pscustomobject]$Smtp,
                        [pscustomobject[]]$Gaps,
                        [string[]]$ZipFileDestination
                    )

                    $null = $Company
                    $null = $DateRange
                    $null = $Smtp
                    $null = $Gaps
                    $null = $ZipFileDestination
                }

                $invokeParams = @{
                    Company   = $Script:Company
                    DateRange = $Script:DateRange
                }

                $Script:Result = Invoke-PipeDFeCompany @invokeParams
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

            It 'Does not call Get-DFeSequenceGap' {
                $invokeParams = @{
                    CommandName = 'Get-DFeSequenceGap'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'Context'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke @invokeParams
            }

            It 'Does not call New-DFeArchive' {
                $invokeParams = @{
                    CommandName = 'New-DFeArchive'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'Context'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke @invokeParams
            }

            It 'Does not call Send-DFeNotification' {
                $invokeParams = @{
                    CommandName = 'Send-DFeNotification'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'Context'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke @invokeParams
            }

            It 'Returns Erro as null' {
                $Script:Result.Erro | Should -BeNullOrEmpty
            }
        }
        #endregion

        #region SMTP not configured
        Context 'SMTP not configured' {

            BeforeAll {

                Mock -CommandName Initialize-DFeIndex -MockWith {
                    param ([string]$Cnpj)
                    $null = $Cnpj
                    return 'C:\store\12345678000199\index.db'
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
                    param ([string]$Cnpj, [string]$StartDate, [string]$EndDate)
                    $null = $Cnpj
                    $null = $StartDate
                    $null = $EndDate
                    return $Script:Entry
                }

                Mock -CommandName Get-DFeSequenceGap -MockWith {
                    param ([pscustomobject[]]$Entries)
                    $null = $Entries
                }

                Mock -CommandName Resolve-DFeArchiveInfo -MockWith {
                    param (
                        [string]$TipoDFe,
                        [string]$Cnpj,
                        [pscustomobject]$Company,
                        [pscustomobject]$DateRange
                    )

                    $null = $TipoDFe
                    $null = $Cnpj
                    $null = $Company
                    $null = $DateRange
                    return $Script:ArchiveInfo
                }

                Mock -CommandName New-DFeArchive -MockWith {
                    param (
                        [string]$Cnpj,
                        [pscustomobject]$Company,
                        [pscustomobject[]]$Entries,
                        [pscustomobject[]]$ArchiveInfos
                    )

                    $null = $Cnpj
                    $null = $Company
                    $null = $Entries
                    $null = $ArchiveInfos
                    return $Script:Archive
                }

                Mock -CommandName Resolve-DFeSmtp -MockWith {
                    param ([pscustomobject]$Company)
                    $null = $Company
                    $PSCmdlet.ThrowTerminatingError(
                        [System.Management.Automation.ErrorRecord]::new(
                            [System.InvalidOperationException]::new('SmtpNotConfigured'),
                            'SmtpNotConfigured',
                            [System.Management.Automation.ErrorCategory]::InvalidOperation,
                            $null
                        )
                    )
                }

                Mock -CommandName Send-DFeNotification -MockWith {
                    param (
                        [pscustomobject]$Company,
                        [pscustomobject]$DateRange,
                        [pscustomobject]$Smtp,
                        [pscustomobject[]]$Gaps,
                        [string[]]$ZipFileDestination
                    )

                    $null = $Company
                    $null = $DateRange
                    $null = $Smtp
                    $null = $Gaps
                    $null = $ZipFileDestination
                }

                $invokeParams = @{
                    Company   = $Script:Company
                    DateRange = $Script:DateRange
                }

                $Script:Result = Invoke-PipeDFeCompany @invokeParams
            }

            It 'Returns Status Aviso' {
                $Script:Result.Status | Should -Be 'Aviso'
            }

            It 'Records a warning about missing SMTP in Avisos' {
                $Script:Result.Avisos | Should -HaveCount 1
            }

            It 'Does not call Send-DFeNotification' {
                $invokeParams = @{
                    CommandName = 'Send-DFeNotification'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'Context'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke @invokeParams
            }

            It 'Returns EmailEnviado false' {
                $Script:Result.EmailEnviado | Should -BeFalse
            }

            It 'Returns Erro as null' {
                $Script:Result.Erro | Should -BeNullOrEmpty
            }
        }
        #endregion

        #region No recipients
        Context 'SMTP configured but no recipients' {

            BeforeAll {

                $Script:CompanyNoRecipients = [PSCustomObject]@{
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

                Mock -CommandName Initialize-DFeIndex -MockWith {
                    param ([string]$Cnpj)
                    $null = $Cnpj
                    return 'C:\store\12345678000199\index.db'
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
                    param ([string]$Cnpj, [string]$StartDate, [string]$EndDate)
                    $null = $Cnpj
                    $null = $StartDate
                    $null = $EndDate
                    return $Script:Entry
                }

                Mock -CommandName Get-DFeSequenceGap -MockWith {
                    param ([pscustomobject[]]$Entries)
                    $null = $Entries
                }

                Mock -CommandName Resolve-DFeArchiveInfo -MockWith {
                    param (
                        [string]$TipoDFe,
                        [string]$Cnpj,
                        [pscustomobject]$Company,
                        [pscustomobject]$DateRange
                    )

                    $null = $TipoDFe
                    $null = $Cnpj
                    $null = $Company
                    $null = $DateRange
                    return $Script:ArchiveInfo
                }

                Mock -CommandName New-DFeArchive -MockWith {
                    param (
                        [string]$Cnpj,
                        [pscustomobject]$Company,
                        [pscustomobject[]]$Entries,
                        [pscustomobject[]]$ArchiveInfos
                    )

                    $null = $Cnpj
                    $null = $Company
                    $null = $Entries
                    $null = $ArchiveInfos
                    return $Script:Archive
                }

                Mock -CommandName Resolve-DFeSmtp -MockWith {
                    param ([pscustomobject]$Company)
                    $null = $Company
                    return $Script:Smtp
                }

                Mock -CommandName Send-DFeNotification -MockWith {
                    param (
                        [pscustomobject]$Company,
                        [pscustomobject]$DateRange,
                        [pscustomobject]$Smtp,
                        [pscustomobject[]]$Gaps,
                        [string[]]$ZipFileDestination
                    )

                    $null = $Company
                    $null = $DateRange
                    $null = $Smtp
                    $null = $Gaps
                    $null = $ZipFileDestination
                }

                $invokeParams = @{
                    Company   = $Script:CompanyNoRecipients
                    DateRange = $Script:DateRange
                }

                $Script:Result = Invoke-PipeDFeCompany @invokeParams
            }

            It 'Returns Status Aviso' {
                $Script:Result.Status | Should -Be 'Aviso'
            }

            It 'Records a warning about missing recipients in Avisos' {
                $Script:Result.Avisos | Should -HaveCount 1
            }

            It 'Does not call Send-DFeNotification' {
                $invokeParams = @{
                    CommandName = 'Send-DFeNotification'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'Context'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke @invokeParams
            }

            It 'Returns EmailEnviado false' {
                $Script:Result.EmailEnviado | Should -BeFalse
            }
        }
        #endregion

        #region Notification failure
        Context 'Notification delivery failure' {

            BeforeAll {

                Mock -CommandName Initialize-DFeIndex -MockWith {
                    param ([string]$Cnpj)
                    $null = $Cnpj
                    return 'C:\store\12345678000199\index.db'
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
                    param (
                        [string]$Cnpj,
                        [string]$StartDate,
                        [string]$EndDate
                    )

                    $null = $Cnpj
                    $null = $StartDate
                    $null = $EndDate
                    return $Script:Entry
                }

                Mock -CommandName Get-DFeSequenceGap -MockWith {
                    param ([pscustomobject[]]$Entries)
                    $null = $Entries
                }

                Mock -CommandName Resolve-DFeArchiveInfo -MockWith {
                    param (
                        [string]$TipoDFe,
                        [string]$Cnpj,
                        [pscustomobject]$Company,
                        [pscustomobject]$DateRange
                    )

                    $null = $TipoDFe
                    $null = $Cnpj
                    $null = $Company
                    $null = $DateRange
                    return $Script:ArchiveInfo
                }

                Mock -CommandName New-DFeArchive -MockWith {
                    param (
                        [string]$Cnpj,
                        [pscustomobject]$Company,
                        [pscustomobject[]]$Entries,
                        [pscustomobject[]]$ArchiveInfos
                    )

                    $null = $Cnpj
                    $null = $Company
                    $null = $Entries
                    $null = $ArchiveInfos
                    return $Script:Archive
                }

                Mock -CommandName Resolve-DFeSmtp -MockWith {
                    param ([pscustomobject]$Company)
                    $null = $Company
                    return $Script:Smtp
                }

                Mock -CommandName Send-DFeNotification -MockWith {
                    param (
                        [pscustomobject]$Company,
                        [pscustomobject]$DateRange,
                        [pscustomobject]$Smtp,
                        [pscustomobject[]]$Gaps,
                        [string[]]$ZipFileDestination
                    )

                    $null = $Company
                    $null = $DateRange
                    $null = $Smtp
                    $null = $Gaps
                    $null = $ZipFileDestination
                    return $Script:NotificationFailure
                }

                $invokeParams = @{
                    Company   = $Script:Company
                    DateRange = $Script:DateRange
                }

                $Script:Result = Invoke-PipeDFeCompany @invokeParams
            }

            It 'Returns Status Aviso' {
                $Script:Result.Status | Should -Be 'Aviso'
            }

            It 'Records a warning about the failed notification in Avisos' {
                $Script:Result.Avisos | Should -HaveCount 1
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

            BeforeAll {

                Mock -CommandName Initialize-DFeIndex -MockWith {
                    param ([string]$Cnpj)
                    $null = $Cnpj
                    throw [System.IO.IOException]::new('Disk full.')
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
                    param ([string]$Cnpj, [string]$StartDate, [string]$EndDate)
                    $null = $Cnpj
                    $null = $StartDate
                    $null = $EndDate
                }

                $invokeParams = @{
                    Company   = $Script:Company
                    DateRange = $Script:DateRange
                }

                $Script:Result = Invoke-PipeDFeCompany @invokeParams
            }

            It 'Returns Status Falha' {
                $Script:Result.Status | Should -Be 'Falha'
            }

            It 'Captures the error message in Erro' {
                $Script:Result.Erro | Should -Be 'Disk full.'
            }

            It 'Does not call Invoke-DFeXmlScan' {
                $invokeParams = @{
                    CommandName = 'Invoke-DFeXmlScan'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'Context'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke @invokeParams
            }
        }
        #endregion

        #region Invoke-DFeXmlScan throws
        Context 'Invoke-DFeXmlScan throws' {

            BeforeAll {

                Mock -CommandName Initialize-DFeIndex -MockWith {
                    param ([string]$Cnpj)
                    $null = $Cnpj
                    return 'C:\store\12345678000199\index.db'
                }

                Mock -CommandName Invoke-DFeXmlScan -MockWith {
                    throw [System.UnauthorizedAccessException]::new('Access denied.')
                }

                Mock -CommandName Get-DFeDocumentEntry -MockWith {
                    param ([string]$Cnpj, [string]$StartDate, [string]$EndDate)
                    $null = $Cnpj
                    $null = $StartDate
                    $null = $EndDate
                }

                $invokeParams = @{
                    Company   = $Script:Company
                    DateRange = $Script:DateRange
                }

                $Script:Result = Invoke-PipeDFeCompany @invokeParams
            }

            It 'Returns Status Falha' {
                $Script:Result.Status | Should -Be 'Falha'
            }

            It 'Captures the error message in Erro' {
                $Script:Result.Erro | Should -Be 'Access denied.'
            }

            It 'Does not call Get-DFeDocumentEntry' {
                $invokeParams = @{
                    CommandName = 'Get-DFeDocumentEntry'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'Context'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke @invokeParams
            }
        }
        #endregion

        #region New-DFeArchive throws
        Context 'New-DFeArchive throws' {

            BeforeAll {

                Mock -CommandName Initialize-DFeIndex -MockWith {
                    param ([string]$Cnpj)
                    $null = $Cnpj
                    return 'C:\store\12345678000199\index.db'
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
                    param (
                        [string]$Cnpj,
                        [string]$StartDate,
                        [string]$EndDate
                    )

                    $null = $Cnpj
                    $null = $StartDate
                    $null = $EndDate
                    return $Script:Entry
                }

                Mock -CommandName Get-DFeSequenceGap -MockWith {
                    param ([pscustomobject[]]$Entries)
                    $null = $Entries
                }

                Mock -CommandName Resolve-DFeArchiveInfo -MockWith {
                    param (
                        [string]$TipoDFe,
                        [string]$Cnpj,
                        [pscustomobject]$Company,
                        [pscustomobject]$DateRange
                    )

                    $null = $TipoDFe
                    $null = $Cnpj
                    $null = $Company
                    $null = $DateRange
                    return $Script:ArchiveInfo
                }

                Mock -CommandName New-DFeArchive -MockWith {
                    param (
                        [string]$Cnpj,
                        [pscustomobject]$Company,
                        [pscustomobject[]]$Entries,
                        [pscustomobject[]]$ArchiveInfos
                    )

                    $null = $Cnpj
                    $null = $Company
                    $null = $Entries
                    $null = $ArchiveInfos
                    throw [System.IO.IOException]::new('ZIP creation failed.')
                }

                Mock -CommandName Resolve-DFeSmtp -MockWith {
                    param ([pscustomobject]$Company)
                    $null = $Company
                }

                Mock -CommandName Send-DFeNotification -MockWith {
                    param (
                        [pscustomobject]$Company,
                        [pscustomobject]$DateRange,
                        [pscustomobject]$Smtp,
                        [pscustomobject[]]$Gaps,
                        [string[]]$ZipFileDestination
                    )

                    $null = $Company
                    $null = $DateRange
                    $null = $Smtp
                    $null = $Gaps
                    $null = $ZipFileDestination
                }

                $invokeParams = @{
                    Company   = $Script:Company
                    DateRange = $Script:DateRange
                }

                $Script:Result = Invoke-PipeDFeCompany @invokeParams
            }

            It 'Returns Status Falha' {
                $Script:Result.Status | Should -Be 'Falha'
            }

            It 'Captures the error message in Erro' {
                $Script:Result.Erro | Should -Be 'ZIP creation failed.'
            }

            It 'Does not call Send-DFeNotification' {
                $invokeParams = @{
                    CommandName = 'Send-DFeNotification'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'Context'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke @invokeParams
            }
        }
        #endregion

        #region Never throws
        Context 'Never throws' {

            It 'Does not throw when Initialize-DFeIndex throws' {
                Mock -CommandName Initialize-DFeIndex -MockWith {
                    param ([string]$Cnpj)
                    $null = $Cnpj
                    throw [System.Exception]::new('boom')
                }

                $invokeParams = @{
                    Company   = $Script:Company
                    DateRange = $Script:DateRange
                }

                { Invoke-PipeDFeCompany @invokeParams } | Should -Not -Throw
            }

            It 'Does not throw when Get-DFeDocumentEntry throws' {
                Mock -CommandName Initialize-DFeIndex -MockWith {
                    param ([string]$Cnpj)
                    $null = $Cnpj
                    return 'C:\store\12345678000199\index.db'
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
                    param (
                        [string]$Cnpj,
                        [string]$StartDate,
                        [string]$EndDate
                    )

                    $null = $Cnpj
                    $null = $StartDate
                    $null = $EndDate
                    throw [System.Exception]::new('boom')
                }

                $invokeParams = @{
                    Company   = $Script:Company
                    DateRange = $Script:DateRange
                }

                { Invoke-PipeDFeCompany @invokeParams } | Should -Not -Throw
            }

            It 'Does not throw when New-DFeArchive throws' {
                Mock -CommandName Initialize-DFeIndex -MockWith {
                    param ([string]$Cnpj)
                    $null = $Cnpj
                    return 'C:\store\12345678000199\index.db'
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
                    param (
                        [string]$Cnpj,
                        [string]$StartDate,
                        [string]$EndDate
                    )

                    $null = $Cnpj
                    $null = $StartDate
                    $null = $EndDate
                    return $Script:Entry
                }

                Mock -CommandName Get-DFeSequenceGap -MockWith {
                    param ([pscustomobject[]]$Entries)
                    $null = $Entries
                }

                Mock -CommandName Resolve-DFeArchiveInfo -MockWith {
                    param (
                        [string]$TipoDFe,
                        [string]$Cnpj,
                        [pscustomobject]$Company,
                        [pscustomobject]$DateRange
                    )

                    $null = $TipoDFe
                    $null = $Cnpj
                    $null = $Company
                    $null = $DateRange
                    return $Script:ArchiveInfo
                }

                Mock -CommandName New-DFeArchive -MockWith {
                    param (
                        [string]$Cnpj,
                        [pscustomobject]$Company,
                        [pscustomobject[]]$Entries,
                        [pscustomobject[]]$ArchiveInfos
                    )

                    $null = $Cnpj
                    $null = $Company
                    $null = $Entries
                    $null = $ArchiveInfos
                    throw [System.Exception]::new('boom')
                }

                $invokeParams = @{
                    Company   = $Script:Company
                    DateRange = $Script:DateRange
                }

                { Invoke-PipeDFeCompany @invokeParams } | Should -Not -Throw
            }
        }
        #endregion

        #region Return type contract
        Context 'Return type contract' {

            BeforeAll {

                Mock -CommandName Initialize-DFeIndex -MockWith {
                    param ([string]$Cnpj)
                    $null = $Cnpj
                    return 'C:\store\12345678000199\index.db'
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
                    param (
                        [string]$Cnpj,
                        [string]$StartDate,
                        [string]$EndDate
                    )

                    $null = $Cnpj
                    $null = $StartDate
                    $null = $EndDate
                    return $Script:Entry
                }

                Mock -CommandName Get-DFeSequenceGap -MockWith {
                    param ([pscustomobject[]]$Entries)
                    $null = $Entries
                }

                Mock -CommandName Resolve-DFeArchiveInfo -MockWith {
                    param (
                        [string]$TipoDFe,
                        [string]$Cnpj,
                        [pscustomobject]$Company,
                        [pscustomobject]$DateRange
                    )

                    $null = $TipoDFe
                    $null = $Cnpj
                    $null = $Company
                    $null = $DateRange
                    return $Script:ArchiveInfo
                }

                Mock -CommandName New-DFeArchive -MockWith {
                    param (
                        [string]$Cnpj,
                        [pscustomobject]$Company,
                        [pscustomobject[]]$Entries,
                        [pscustomobject[]]$ArchiveInfos
                    )

                    $null = $Cnpj
                    $null = $Company
                    $null = $Entries
                    $null = $ArchiveInfos
                    return $Script:Archive
                }

                Mock -CommandName Resolve-DFeSmtp -MockWith {
                    param ([pscustomobject]$Company)
                    $null = $Company
                    return $Script:Smtp
                }

                Mock -CommandName Send-DFeNotification -MockWith {
                    param (
                        [pscustomobject]$Company,
                        [pscustomobject]$DateRange,
                        [pscustomobject]$Smtp,
                        [pscustomobject[]]$Gaps,
                        [string[]]$ZipFileDestination
                    )

                    $null = $Company
                    $null = $DateRange
                    $null = $Smtp
                    $null = $Gaps
                    $null = $ZipFileDestination
                    return $Script:NotificationSuccess
                }

                $invokeParams = @{
                    Company   = $Script:Company
                    DateRange = $Script:DateRange
                }

                $Script:Result = Invoke-PipeDFeCompany @invokeParams
            }

            It 'Returns exactly one object' {
                $invokeParams = @{
                    Company   = $Script:Company
                    DateRange = $Script:DateRange
                }

                @(Invoke-PipeDFeCompany @invokeParams) | Should -HaveCount 1
            }

            It 'Cnpj is a string' {
                $Script:Result.Cnpj | Should -BeOfType [string]
            }

            It 'RazaoSocial is a string' {
                $Script:Result.RazaoSocial | Should -BeOfType [string]
            }

            It 'Status is a string' {
                $Script:Result.Status | Should -BeOfType [string]
            }

            It 'TotalDocumentos is an int' {
                $Script:Result.TotalDocumentos | Should -BeOfType [int]
            }

            It 'Gaps is an int' {
                $Script:Result.Gaps | Should -BeOfType [int]
            }

            It 'Arquivos is an array' {
                $Script:Result.Arquivos.GetType().IsArray | Should -BeTrue
            }

            It 'EmailEnviado is a bool' {
                $Script:Result.EmailEnviado | Should -BeOfType [bool]
            }

            It 'Avisos is an array' {
                $Script:Result.Avisos.GetType().IsArray | Should -BeTrue
            }
        }
        #endregion
    }
}
