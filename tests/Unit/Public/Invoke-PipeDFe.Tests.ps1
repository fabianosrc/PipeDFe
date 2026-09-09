#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for Invoke-PipeDFe.

.DESCRIPTION
Verifies the orchestration contract of Invoke-PipeDFe using mocks for all
private dependencies. No real SQLite, file system I/O, or SMTP connections
are used.

Coverage includes:
  - Cnpj, StartDate and EndDate are optional.
  - Calls Resolve-DateRange with no arguments when dates are omitted.
  - Calls Resolve-DateRange with StartDate and EndDate when provided.
  - Calls ConvertTo-NormalizedCnpj for each supplied Cnpj.
  - Calls Get-CompanyConfig with the normalized Cnpj when Cnpj is supplied.
  - Calls Get-CompanyConfig without arguments when Cnpj is omitted.
  - Ignores inactive companies with a warning.
  - Returns a ResultadoInvoke with empty Results when no active company exists.
  - Calls Invoke-PipeDFeCompany once per active company.
  - Passes Company and DateRange correctly to Invoke-PipeDFeCompany.
  - Skips Invoke-PipeDFeCompany and records a placeholder result under -WhatIf.
  - Aggregates results from Invoke-PipeDFeCompany into Results.
  - Returns Success = $true when all companies succeed.
  - Returns Success = $false when any company returns Status = 'Falha'.
  - Propagates errors from Resolve-DateRange (global failure).
  - Propagates errors from Get-CompanyConfig (global failure).
  - Returns correct ResultadoInvoke property types.
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
    $moduleRoot = (Get-Item $PSScriptRoot).Parent.Parent.Parent.FullName

    $moduleName = Join-Path -Path $moduleRoot -ChildPath 'PipeDFe.psd1'

    Import-Module -Name $moduleName -Force -Global -ErrorAction Stop
}

Describe 'Invoke-PipeDFe' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            $Script:CnpjOne  = '12345678000199'
            $Script:CnpjTwo = '98765432000100'

            $Script:DateRange = [PSCustomObject]@{
                Start = [System.DateTimeOffset]::new(
                    2026, 8,  1,  0,  0,  0, [System.TimeSpan]::Zero
                )
                End   = [System.DateTimeOffset]::new(
                    2026, 8, 31, 23, 59, 59, [System.TimeSpan]::Zero
                )
            }

            $Script:CompanyActiveOne = [PSCustomObject]@{
                Cnpj         = $Script:CnpjOne
                RazaoSocial  = 'EMPRESA ALPHA LTDA'
                NomeFantasia = [string]::Empty
                IsActive     = $true
                XmlPath      = 'C:\xml'
                OutputPath   = 'C:\output'
                Email        = [PSCustomObject]@{
                    Para = @()
                    Cc   = @()
                    Cco  = @()
                }
            }

            $Script:CompanyActiveTwo = [PSCustomObject]@{
                Cnpj         = $Script:CnpjTwo
                RazaoSocial  = 'EMPRESA BETA LTDA'
                NomeFantasia = [string]::Empty
                IsActive     = $true
                XmlPath      = 'C:\xml'
                OutputPath   = 'C:\output'
                Email        = [PSCustomObject]@{
                    Para = @()
                    Cc   = @()
                    Cco  = @()
                }
            }

            $Script:CompanyInactive = [PSCustomObject]@{
                Cnpj         = $Script:CnpjOne
                RazaoSocial  = 'EMPRESA INATIVA LTDA'
                NomeFantasia = [string]::Empty
                IsActive     = $false
                XmlPath      = 'C:\xml'
                OutputPath   = 'C:\output'
                Email        = [PSCustomObject]@{
                    Para = @()
                    Cc   = @()
                    Cco  = @()
                }
            }

            $Script:ResultadoOK = [PSCustomObject]@{
                PSTypeName      = 'PipeDFe.ResultadoEmpresa'
                Cnpj            = $Script:CnpjOne
                RazaoSocial     = 'EMPRESA ALPHA LTDA'
                Status          = 'OK'
                TotalDocumentos = 5
                Gaps            = 0
                Arquivos        = @('NFe_12345678000199_202608.zip')
                EmailEnviado    = $true
                Avisos          = @()
                Erro            = $null
            }

            $Script:ResultadoFalha = [PSCustomObject]@{
                PSTypeName      = 'PipeDFe.ResultadoEmpresa'
                Cnpj            = $Script:CnpjTwo
                RazaoSocial     = 'EMPRESA BETA LTDA'
                Status          = 'Falha'
                TotalDocumentos = 0
                Gaps            = 0
                Arquivos        = @()
                EmailEnviado    = $false
                Avisos          = @()
                Erro            = 'Index failure.'
            }
        }

        AfterAll {

            Remove-Module -Name PipeDFe -Force -ErrorAction SilentlyContinue
        }

        #region Date range resolution
        Context 'Date range resolution' {

            BeforeAll {

                Mock -CommandName Resolve-DateRange -MockWith {
                    param (
                        [string]$StartDate,
                        [string]$EndDate
                    )

                    $null = $StartDate
                    $null = $EndDate
                    return $Script:DateRange
                }

                Mock -CommandName ConvertTo-NormalizedCnpj -MockWith {
                    param ([string]$Value)
                    $null = $Value
                    return $Script:CnpjOne
                }

                Mock -CommandName Get-CompanyConfig -MockWith {
                    param ([string]$Cnpj)
                    $null = $Cnpj
                    return $Script:CompanyActiveOne
                }

                Mock -CommandName Invoke-PipeDFeCompany -MockWith {
                    param (
                        [pscustomobject]$Company,
                        [pscustomobject]$DateRange
                    )

                    $null = $Company
                    $null = $DateRange
                    return $Script:ResultadoOK
                }
            }

            It 'Calls Resolve-DateRange with no arguments when dates are omitted' {
                Invoke-PipeDFe -Cnpj $Script:CnpjOne | Out-Null

                $invokeParams = @{
                    CommandName     = 'Resolve-DateRange'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'It'
                    Exactly         = $true
                    Times           = 1
                    ParameterFilter = {
                        -not $PSBoundParameters.ContainsKey('StartDate') -and
                        -not $PSBoundParameters.ContainsKey('EndDate')
                    }
                }

                Should -Invoke @invokeParams
            }

            It 'Calls Resolve-DateRange with StartDate and EndDate when provided' {
                $pipeParams = @{
                    Cnpj      = $Script:CnpjOne
                    StartDate = '01/08/2026'
                    EndDate   = '31/08/2026'
                }

                Invoke-PipeDFe @pipeParams | Out-Null

                $invokeParams = @{
                    CommandName     = 'Resolve-DateRange'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'It'
                    Exactly         = $true
                    Times           = 1
                    ParameterFilter = {
                        $StartDate -eq '01/08/2026' -and $EndDate -eq '31/08/2026'
                    }
                }

                Should -Invoke @invokeParams
            }
        }
        #endregion

        #region Company resolution - Cnpj supplied
        Context 'Company resolution when Cnpj is supplied' {

            BeforeAll {

                Mock -CommandName Resolve-DateRange -MockWith {
                    param (
                        [string]$StartDate,
                        [string]$EndDate
                    )

                    $null = $StartDate
                    $null = $EndDate
                    return $Script:DateRange
                }

                Mock -CommandName ConvertTo-NormalizedCnpj -MockWith {
                    param ([string]$Value)
                    $null = $Value
                    return $Script:CnpjOne
                }

                Mock -CommandName Get-CompanyConfig -MockWith {
                    param ([string]$Cnpj)
                    $null = $Cnpj
                    return $Script:CompanyActiveOne
                }

                Mock -CommandName Invoke-PipeDFeCompany -MockWith {
                    param (
                        [pscustomobject]$Company,
                        [pscustomobject]$DateRange
                    )

                    $null = $Company
                    $null = $DateRange
                    return $Script:ResultadoOK
                }
            }

            It 'Calls ConvertTo-NormalizedCnpj for the supplied Cnpj' {
                Invoke-PipeDFe -Cnpj $Script:CnpjOne | Out-Null

                $invokeParams = @{
                    CommandName     = 'ConvertTo-NormalizedCnpj'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'It'
                    Exactly         = $true
                    Times           = 1
                    ParameterFilter = { $Value -eq $Script:CnpjOne }
                }

                Should -Invoke @invokeParams
            }

            It 'Calls Get-CompanyConfig with the normalized Cnpj' {
                Invoke-PipeDFe -Cnpj $Script:CnpjOne | Out-Null

                $invokeParams = @{
                    CommandName     = 'Get-CompanyConfig'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'It'
                    Exactly         = $true
                    Times           = 1
                    ParameterFilter = { $Cnpj -eq $Script:CnpjOne }
                }

                Should -Invoke @invokeParams
            }

            It 'Calls ConvertTo-NormalizedCnpj once per supplied Cnpj' {

                Mock -CommandName Get-CompanyConfig -MockWith {
                    param ([string]$Cnpj)
                    $null = $Cnpj
                    return $Script:CompanyActiveOne
                } -ParameterFilter {
                    $Cnpj -eq $Script:CnpjOne
                }

                Mock -CommandName Get-CompanyConfig -MockWith {
                    param ([string]$Cnpj)
                    $null = $Cnpj
                    return $Script:CompanyActiveTwo
                } -ParameterFilter {
                    $Cnpj -eq $Script:CnpjTwo
                }

                Mock -CommandName ConvertTo-NormalizedCnpj -MockWith {
                    param ([string]$Value)
                    $null = $Value
                    return $Script:CnpjOne
                } -ParameterFilter {
                    $Value -eq $Script:CnpjOne
                }

                Mock -CommandName ConvertTo-NormalizedCnpj -MockWith {
                    param ([string]$Value)
                    $null = $Value
                    return $Script:CnpjTwo
                } -ParameterFilter {
                    $Value -eq $Script:CnpjTwo
                }

                Mock -CommandName Invoke-PipeDFeCompany -MockWith {
                    param (
                        [pscustomobject]$Company,
                        [pscustomobject]$DateRange
                    )

                    $null = $Company
                    $null = $DateRange
                    return $Script:ResultadoOK
                }

                Invoke-PipeDFe -Cnpj $Script:CnpjOne, $Script:CnpjTwo | Out-Null

                $invokeParams = @{
                    CommandName = 'ConvertTo-NormalizedCnpj'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'It'
                    Exactly     = $true
                    Times       = 2
                }

                Should -Invoke @invokeParams
            }
        }
        #endregion

        #region Company resolution - Cnpj omitted
        Context 'Company resolution when Cnpj is omitted' {

            BeforeAll {

                Mock -CommandName Resolve-DateRange -MockWith {
                    param ([string]$StartDate, [string]$EndDate)
                    $null = $StartDate
                    $null = $EndDate
                    return $Script:DateRange
                }

                Mock -CommandName ConvertTo-NormalizedCnpj -MockWith {
                    param ([string]$Value)
                    $null = $Value
                    return $Script:CnpjOne
                }

                Mock -CommandName Get-CompanyConfig -MockWith {
                    param ([string]$Cnpj)
                    $null = $Cnpj
                    return @($Script:CompanyActiveOne, $Script:CompanyActiveTwo)
                }

                Mock -CommandName Invoke-PipeDFeCompany -MockWith {
                    param ([pscustomobject]$Company, [pscustomobject]$DateRange)
                    $null = $Company
                    $null = $DateRange
                    return $Script:ResultadoOK
                }
            }

            It 'Does not call ConvertTo-NormalizedCnpj when Cnpj is omitted' {
                Invoke-PipeDFe | Out-Null

                $invokeParams = @{
                    CommandName = 'ConvertTo-NormalizedCnpj'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'It'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke @invokeParams
            }

            It 'Calls Get-CompanyConfig without arguments' {
                Invoke-PipeDFe | Out-Null

                $invokeParams = @{
                    CommandName     = 'Get-CompanyConfig'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'It'
                    Exactly         = $true
                    Times           = 1
                    ParameterFilter = { -not $PSBoundParameters.ContainsKey('Cnpj') }
                }

                Should -Invoke @invokeParams
            }
        }
        #endregion

        #region Inactive company filtering
        Context 'Inactive company filtering' {

            BeforeAll {

                Mock -CommandName Resolve-DateRange -MockWith {
                    param (
                        [string]$StartDate,
                        [string]$EndDate
                    )

                    $null = $StartDate
                    $null = $EndDate
                    return $Script:DateRange
                }

                Mock -CommandName ConvertTo-NormalizedCnpj -MockWith {
                    param ([string]$Value)
                    $null = $Value
                    return $Script:CnpjOne
                }

                Mock -CommandName Get-CompanyConfig -MockWith {
                    param ([string]$Cnpj)
                    $null = $Cnpj
                    return $Script:CompanyInactive
                }

                Mock -CommandName Invoke-PipeDFeCompany -MockWith {
                    param (
                        [pscustomobject]$Company,
                        [pscustomobject]$DateRange
                    )

                    $null = $Company
                    $null = $DateRange
                    return $Script:ResultadoOK
                }

                $pipeParams = @{
                    Cnpj          = $Script:CnpjOne
                    WarningAction = 'SilentlyContinue'
                }

                $Script:Result = Invoke-PipeDFe @pipeParams
            }

            It 'Does not call Invoke-PipeDFeCompany for an inactive company' {
                $invokeParams = @{
                    CommandName = 'Invoke-PipeDFeCompany'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'Context'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke @invokeParams
            }

            It 'Returns an empty Results array' {
                $Script:Result.Results | Should -HaveCount 0
            }

            It 'Returns Success true' {
                $Script:Result.Success | Should -BeTrue
            }
        }
        #endregion

        #region Pipeline execution - single company
        Context 'Pipeline execution - single active company' {

            BeforeAll {

                Mock -CommandName Resolve-DateRange -MockWith {
                    param (
                        [string]$StartDate,
                        [string]$EndDate
                    )

                    $null = $StartDate
                    $null = $EndDate
                    return $Script:DateRange
                }

                Mock -CommandName ConvertTo-NormalizedCnpj -MockWith {
                    param ([string]$Value)
                    $null = $Value
                    return $Script:CnpjOne
                }

                Mock -CommandName Get-CompanyConfig -MockWith {
                    param ([string]$Cnpj)
                    $null = $Cnpj
                    return $Script:CompanyActiveOne
                }

                Mock -CommandName Invoke-PipeDFeCompany -MockWith {
                    param (
                        [pscustomobject]$Company,
                        [pscustomobject]$DateRange
                    )

                    $null = $Company
                    $null = $DateRange
                    return $Script:ResultadoOK
                }

                $Script:Result = Invoke-PipeDFe -Cnpj $Script:CnpjOne
            }

            It 'Calls Invoke-PipeDFeCompany exactly once' {
                $invokeParams = @{
                    CommandName = 'Invoke-PipeDFeCompany'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'Context'
                    Exactly     = $true
                    Times       = 1
                }

                Should -Invoke @invokeParams
            }

            It 'Passes the correct Company to Invoke-PipeDFeCompany' {
                $invokeParams = @{
                    CommandName     = 'Invoke-PipeDFeCompany'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'Context'
                    Exactly         = $true
                    Times           = 1
                    ParameterFilter = { $Company.Cnpj -eq $Script:CnpjOne }
                }

                Should -Invoke @invokeParams
            }

            It 'Passes the resolved DateRange to Invoke-PipeDFeCompany' {
                $invokeParams = @{
                    CommandName     = 'Invoke-PipeDFeCompany'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'Context'
                    Exactly         = $true
                    Times           = 1
                    ParameterFilter = {
                        $DateRange.Start -eq $Script:DateRange.Start -and
                        $DateRange.End   -eq $Script:DateRange.End
                    }
                }

                Should -Invoke @invokeParams
            }

            It 'Includes the company result in Results' {
                $Script:Result.Results | Should -HaveCount 1
            }

            It 'Returns Success true when the company result is OK' {
                $Script:Result.Success | Should -BeTrue
            }
        }
        #endregion

        #region Pipeline execution - multiple companies
        Context 'Pipeline execution - multiple active companies' {

            BeforeAll {

                Mock -CommandName Resolve-DateRange -MockWith {
                    param (
                        [string]$StartDate,
                        [string]$EndDate
                    )

                    $null = $StartDate
                    $null = $EndDate
                    return $Script:DateRange
                }

                Mock -CommandName ConvertTo-NormalizedCnpj -MockWith {
                    param ([string]$Value)
                    $null = $Value
                    return $Script:CnpjOne
                } -ParameterFilter {
                    $Value -eq $Script:CnpjOne
                }

                Mock -CommandName ConvertTo-NormalizedCnpj -MockWith {
                    param ([string]$Value)
                    $null = $Value
                    return $Script:CnpjTwo
                } -ParameterFilter {
                    $Value -eq $Script:CnpjTwo
                }

                Mock -CommandName Get-CompanyConfig -MockWith {
                    param ([string]$Cnpj)
                    $null = $Cnpj
                    return $Script:CompanyActiveOne
                } -ParameterFilter {
                    $Cnpj -eq $Script:CnpjOne
                }

                Mock -CommandName Get-CompanyConfig -MockWith {
                    param ([string]$Cnpj)
                    $null = $Cnpj
                    return $Script:CompanyActiveTwo
                } -ParameterFilter {
                    $Cnpj -eq $Script:CnpjTwo
                }

                Mock -CommandName Invoke-PipeDFeCompany -MockWith {
                    param (
                        [pscustomobject]$Company,
                        [pscustomobject]$DateRange
                    )

                    $null = $Company
                    $null = $DateRange
                    return $Script:ResultadoOK
                } -ParameterFilter {
                    $Company.Cnpj -eq $Script:CnpjOne
                }

                Mock -CommandName Invoke-PipeDFeCompany -MockWith {
                    param (
                        [pscustomobject]$Company,
                        [pscustomobject]$DateRange
                    )

                    $null = $Company
                    $null = $DateRange
                    return $Script:ResultadoFalha
                } -ParameterFilter {
                    $Company.Cnpj -eq $Script:CnpjTwo
                }

                $Script:Result = Invoke-PipeDFe -Cnpj $Script:CnpjOne, $Script:CnpjTwo
            }

            It 'Calls Invoke-PipeDFeCompany once per active company' {
                $invokeParams = @{
                    CommandName = 'Invoke-PipeDFeCompany'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'Context'
                    Exactly     = $true
                    Times       = 2
                }

                Should -Invoke @invokeParams
            }

            It 'Includes one result per company in Results' {
                $Script:Result.Results | Should -HaveCount 2
            }

            It 'Returns Success false when any company returns Status Falha' {
                $Script:Result.Success | Should -BeFalse
            }
        }
        #endregion

        #region WhatIf
        Context 'WhatIf' {

            BeforeAll {

                Mock -CommandName Resolve-DateRange -MockWith {
                    param (
                        [string]$StartDate,
                        [string]$EndDate
                    )

                    $null = $StartDate
                    $null = $EndDate
                    return $Script:DateRange
                }

                Mock -CommandName ConvertTo-NormalizedCnpj -MockWith {
                    param ([string]$Value)
                    $null = $Value
                    return $Script:CnpjOne
                }

                Mock -CommandName Get-CompanyConfig -MockWith {
                    param ([string]$Cnpj)
                    $null = $Cnpj
                    return $Script:CompanyActiveOne
                }

                Mock -CommandName Invoke-PipeDFeCompany -MockWith {
                    param (
                        [pscustomobject]$Company,
                        [pscustomobject]$DateRange
                    )

                    $null = $Company
                    $null = $DateRange
                    return $Script:ResultadoOK
                }

                $Script:Result = Invoke-PipeDFe -Cnpj $Script:CnpjOne -WhatIf
            }

            It 'Does not call Invoke-PipeDFeCompany under -WhatIf' {
                $invokeParams = @{
                    CommandName = 'Invoke-PipeDFeCompany'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'Context'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke @invokeParams
            }

            It 'Returns a placeholder result with Status OK under -WhatIf' {
                $Script:Result.Results[0].Status | Should -Be 'OK'
            }

            It 'Returns a placeholder result with TotalDocumentos 0 under -WhatIf' {
                $Script:Result.Results[0].TotalDocumentos | Should -Be 0
            }
        }
        #endregion

        #region Global error propagation - Resolve-DateRange
        Context 'Resolve-DateRange throws' {

            BeforeAll {

                Mock -CommandName Resolve-DateRange -MockWith {
                    param (
                        [string]$StartDate,
                        [string]$EndDate
                    )

                    $null = $StartDate
                    $null = $EndDate
                    $PSCmdlet.ThrowTerminatingError(
                        [System.Management.Automation.ErrorRecord]::new(
                            [System.ArgumentException]::new('Invalid date range.'),
                            'InvalidDateRange',
                            [System.Management.Automation.ErrorCategory]::InvalidArgument,
                            $null
                        )
                    )
                }

                Mock -CommandName ConvertTo-NormalizedCnpj -MockWith {
                    param ([string]$Value)
                    $null = $Value
                    return $Script:CnpjOne
                }

                Mock -CommandName Get-CompanyConfig -MockWith {
                    param ([string]$Cnpj)
                    $null = $Cnpj
                    return $Script:CompanyActiveOne
                }

                Mock -CommandName Invoke-PipeDFeCompany -MockWith {
                    param (
                        [pscustomobject]$Company,
                        [pscustomobject]$DateRange
                    )

                    $null = $Company
                    $null = $DateRange
                    return $Script:ResultadoOK
                }

                $Script:DateRangeError = $null

                try {
                    Invoke-PipeDFe -StartDate 'invalid' | Out-Null
                } catch {
                    $Script:DateRangeError = $_
                }
            }

            It 'Propagates the error' {
                $Script:DateRangeError | Should -Not -BeNullOrEmpty
            }

            It 'Does not call Invoke-PipeDFeCompany' {
                $invokeParams = @{
                    CommandName = 'Invoke-PipeDFeCompany'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'Context'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke @invokeParams
            }
        }
        #endregion

        #region Global error propagation - Get-CompanyConfig
        Context 'Get-CompanyConfig throws' {

            BeforeAll {

                Mock -CommandName Resolve-DateRange -MockWith {
                    param (
                        [string]$StartDate,
                        [string]$EndDate
                    )

                    $null = $StartDate
                    $null = $EndDate
                    return $Script:DateRange
                }

                Mock -CommandName ConvertTo-NormalizedCnpj -MockWith {
                    param ([string]$Value)
                    $null = $Value
                    return $Script:CnpjOne
                }

                Mock -CommandName Get-CompanyConfig -MockWith {
                    param ([string]$Cnpj)
                    $null = $Cnpj
                    $PSCmdlet.ThrowTerminatingError(
                        [System.Management.Automation.ErrorRecord]::new(
                            [System.IO.FileNotFoundException]::new('Company not found.'),
                            'CompanyNotFound',
                            [System.Management.Automation.ErrorCategory]::ObjectNotFound,
                            $Script:CnpjOne
                        )
                    )
                }

                Mock -CommandName Invoke-PipeDFeCompany -MockWith {
                    param (
                        [pscustomobject]$Company,
                        [pscustomobject]$DateRange
                    )

                    $null = $Company
                    $null = $DateRange
                    return $Script:ResultadoOK
                }

                $Script:CompanyConfigError = $null

                try {
                    Invoke-PipeDFe -Cnpj $Script:CnpjOne | Out-Null
                } catch {
                    $Script:CompanyConfigError = $_
                }
            }

            It 'Propagates the error' {
                $Script:CompanyConfigError | Should -Not -BeNullOrEmpty
            }

            It 'Does not call Invoke-PipeDFeCompany' {
                $invokeParams = @{
                    CommandName = 'Invoke-PipeDFeCompany'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'Context'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke @invokeParams
            }
        }
        #endregion

        #region Return type contract
        Context 'Return type contract' {

            BeforeAll {

                Mock -CommandName Resolve-DateRange -MockWith {
                    param (
                        [string]$StartDate,
                        [string]$EndDate
                    )

                    $null = $StartDate
                    $null = $EndDate
                    return $Script:DateRange
                }

                Mock -CommandName ConvertTo-NormalizedCnpj -MockWith {
                    param ([string]$Value)
                    $null = $Value
                    return $Script:CnpjOne
                }

                Mock -CommandName Get-CompanyConfig -MockWith {
                    param ([string]$Cnpj)
                    $null = $Cnpj
                    return $Script:CompanyActiveOne
                }

                Mock -CommandName Invoke-PipeDFeCompany -MockWith {
                    param (
                        [pscustomobject]$Company,
                        [pscustomobject]$DateRange
                    )

                    $null = $Company
                    $null = $DateRange
                    return $Script:ResultadoOK
                }

                $Script:Result = Invoke-PipeDFe -Cnpj $Script:CnpjOne
            }

            It 'Returns a PipeDFe.ResultadoInvoke object' {
                $Script:Result.PSTypeNames | Should -Contain 'PipeDFe.ResultadoInvoke'
            }

            It 'Success is a bool' {
                $Script:Result.Success | Should -BeOfType [bool]
            }

            It 'ProcessedAt is a non-empty string' {
                $Script:Result.ProcessedAt | Should -Not -BeNullOrEmpty
            }

            It 'PeriodStart is a non-empty string' {
                $Script:Result.PeriodStart | Should -Not -BeNullOrEmpty
            }

            It 'PeriodEnd is a non-empty string' {
                $Script:Result.PeriodEnd | Should -Not -BeNullOrEmpty
            }

            It 'Results is an array' {
                $Script:Result.Results.GetType().IsArray | Should -BeTrue
            }
        }
        #endregion
    }
}
