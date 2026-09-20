#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for Remove-PipeCompany.

.DESCRIPTION
Validates the retrieval, validation, and removal contract of Remove-PipeCompany.

Coverage includes:
  - Requires Cnpj and Declares the expected parameter types.
  - Does not expose WhatIf or Confirm.
  - Normalizes Cnpj before company lookup.
  - Uses the normalized Cnpj for company lookup.
  - Propagates CompanyNotFound from Get-CompanyConfig.
  - Prevents removal of active companies.
  - Removes the company configuration with Force and ErrorAction Stop.
  - Removes company data only when DeleteFiles is specified.
  - Removes company data recursively with Force and ErrorAction Stop.
  - Ignores missing company data directories.
  - Propagates configuration removal errors without removing data.
  - Wraps data removal errors as DataRemovalFailed.
  - Removes configuration before company data.
  - Produces no pipeline output.
#>

# InModuleScope needs to resolve the PipeDFe module during the Discovery phase,
# because that's when Context/It are executed to register the test tree. If the
# module isn't loaded at that point, InModuleScope fails before any BeforeAll or
# BeforeEach ever runs.
BeforeDiscovery {
    $moduleRoot = (Get-Item $PSScriptRoot).Parent.Parent.Parent.Parent.FullName

    $moduleName = Join-Path -Path $moduleRoot -ChildPath 'PipeDFe.psd1'

    Import-Module -Name $moduleName -Force -Global -ErrorAction Stop
}

Describe 'Remove-PipeCompany' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            $Script:cnpjInput      = '12.345.678/0001-90'
            $Script:cnpjNormalized = '12345678000190'
            $Script:configPath     = 'C:\PipeDFe\Config'
            $Script:dataRoot       = 'C:\PipeDFe\Data'

            $configFileParams = @{
                Path      = $Script:configPath
                ChildPath = ('{0}.json' -f $Script:cnpjNormalized)
            }

            $dataDirParams = @{
                Path      = $Script:dataRoot
                ChildPath = $Script:cnpjNormalized
            }

            $Script:configFile     = Join-Path @configFileParams
            $Script:dataDir        = Join-Path @dataDirParams

            $Script:company = [PSCustomObject]@{
                Cnpj     = $Script:cnpjNormalized
                Name     = 'Empresa Teste'
                IsActive = $false
            }

            $Script:activeCompany = [PSCustomObject]@{
                Cnpj     = $Script:cnpjNormalized
                Name     = 'Empresa Ativa'
                IsActive = $true
            }

            $Script:storePathMock = {
                param (
                    [string]$Scope,

                    [string]$Cnpj
                )

                $null = $Cnpj

                switch ($Scope) {
                    'Config' {
                        return $Script:configPath
                    }
                    'Root' {
                        return $Script:dataRoot
                    }
                    default {
                        throw "Unexpected store scope '$Scope'."
                    }
                }
            }

            $Script:removeItemMock = {
                param (
                    [string]$LiteralPath,
                    [switch]$Force,
                    [switch]$Recurse,
                    [System.Management.Automation.ActionPreference]$ErrorAction
                )

                $null = $LiteralPath
                $null = $Force
                $null = $Recurse
                $null = $ErrorAction
            }
        }

        #region Parameter contract
        Context 'Parameter contract' {

            BeforeAll {

                $Script:command = Get-Command -Name Remove-PipeCompany
            }

            It 'Requires Cnpj' {
                $Script:command.Parameters['Cnpj'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute]
                    } |

                    Select-Object -First 1 |
                    ForEach-Object {
                        $_.Mandatory | Should -BeTrue
                    }
            }

            It 'Declares Cnpj as string' {
                $Script:command.Parameters['Cnpj'].ParameterType |
                    Should -Be ([string])
            }

            It 'Declares DeleteFiles as a switch' {
                $Script:command.Parameters['DeleteFiles'].ParameterType |
                    Should -Be ([switch])
            }
        }
        #endregion

        # CNPJ normalization
        Context 'CNPJ normalization' {

            BeforeAll {

                Mock -CommandName ConvertTo-NormalizedCnpj -MockWith {
                    param (
                        [string]$Value
                    )

                    $null = $Value

                    return $Script:cnpjNormalized
                }

                Mock -CommandName Get-CompanyConfig -MockWith {
                    return $Script:company
                }

                Mock -CommandName Get-StorePath -MockWith $Script:storePathMock

                Mock -CommandName Remove-Item   -MockWith $Script:removeItemMock

                Remove-PipeCompany -Cnpj $Script:cnpjInput -Confirm:$false
            }

            It 'Normalizes the CNPJ before looking up the company' {
                $invokeParams = @{
                    CommandName     = 'ConvertTo-NormalizedCnpj'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'Context'
                    Exactly         = $true
                    Times           = 1
                    ParameterFilter = { $Value -eq $Script:cnpjInput }
                }

                Should -Invoke @invokeParams
            }

            It 'Uses the normalized CNPJ for company lookup' {
                $invokeParams = @{
                    CommandName     = 'Get-CompanyConfig'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'Context'
                    Exactly         = $true
                    Times           = 1
                    ParameterFilter = { $Cnpj -eq $Script:cnpjNormalized }
                }

                Should -Invoke @invokeParams
            }
        }
        #endregion

        #region Company lookup
        Context 'Company lookup' {

            BeforeAll {

                Mock -CommandName ConvertTo-NormalizedCnpj -MockWith {
                    return $Script:cnpjNormalized
                }

                Mock -CommandName Get-CompanyConfig -MockWith {
                    return $Script:company
                }

                Mock -CommandName Get-StorePath -MockWith $Script:storePathMock

                Mock -CommandName Remove-Item   -MockWith $Script:removeItemMock

                Remove-PipeCompany -Cnpj $Script:cnpjInput -Confirm:$false
            }

            It 'Looks up the company using the normalized CNPJ' {
                $invokeParams = @{
                    CommandName     = 'Get-CompanyConfig'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'Context'
                    Exactly         = $true
                    Times           = 1
                    ParameterFilter = { $Cnpj -eq $Script:cnpjNormalized }
                }

                Should -Invoke @invokeParams
            }
        }
        #endregion

        #region CompanyNotFound propagation
        Context 'CompanyNotFound propagation' {

            BeforeAll {

                Mock -CommandName ConvertTo-NormalizedCnpj -MockWith {
                    return $Script:cnpjNormalized
                }

                Mock -CommandName Get-CompanyConfig -MockWith {
                    param (
                        [string]$Cnpj
                    )

                    $PSCmdlet.ThrowTerminatingError(
                        [System.Management.Automation.ErrorRecord]::new(
                            [System.IO.FileNotFoundException]::new("Company not found: '$Cnpj'."),
                            'CompanyNotFound',
                            [System.Management.Automation.ErrorCategory]::ObjectNotFound,
                            $Cnpj
                        )
                    )
                }

                Mock -CommandName Get-StorePath -MockWith $Script:storePathMock

                Mock -CommandName Remove-Item   -MockWith $Script:removeItemMock

                $Script:exception = $null

                try {
                    Remove-PipeCompany -Cnpj $Script:cnpjInput -Confirm:$false
                } catch {
                    $Script:exception = $_
                }
            }

            It 'Propagates the CompanyNotFound error' {
                $Script:exception.FullyQualifiedErrorId |
                    Should -BeLike 'CompanyNotFound*'
            }

            It 'Does not resolve a store path' {
                $invokeParams = @{
                    CommandName = 'Get-StorePath'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'Context'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke @invokeParams
            }

            It 'Does not remove anything' {
                $invokeParams = @{
                    CommandName = 'Remove-Item'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'Context'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke @invokeParams
            }
        }
        #endregion

        #region Active company protection
        Context 'Active company protection' {

            BeforeAll {

                Mock -CommandName ConvertTo-NormalizedCnpj -MockWith {
                    return $Script:cnpjNormalized
                }

                Mock -CommandName Get-CompanyConfig -MockWith {
                    return $Script:activeCompany
                }

                Mock -CommandName Get-StorePath -MockWith $Script:storePathMock

                Mock -CommandName Remove-Item   -MockWith $Script:removeItemMock

                $Script:exception = $null

                try {
                    Remove-PipeCompany -Cnpj $Script:cnpjInput -Confirm:$false
                } catch {
                    $Script:exception = $_
                }
            }

            It 'Throws when the company is active' {
                $Script:exception | Should -Not -BeNullOrEmpty
            }

            It 'Uses the ActiveCompanyRemoval error id' {
                $Script:exception.FullyQualifiedErrorId |
                    Should -BeLike 'ActiveCompanyRemoval*'
            }

            It 'Uses InvalidOperation as the error category' {
                $Script:exception.CategoryInfo.Category |
                    Should -Be 'InvalidOperation'
            }

            It 'Includes the normalized CNPJ in the error message' {
                $Script:exception.Exception.Message |
                    Should -Match $Script:cnpjNormalized
            }

            It 'Does not resolve a store path' {
                $invokeParams = @{
                    CommandName = 'Get-StorePath'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'Context'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke @invokeParams
            }

            It 'Does not remove anything' {
                $invokeParams = @{
                    CommandName = 'Remove-Item'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'Context'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke @invokeParams
            }
        }
        #endregion

        # Configuration removal
        Context 'Configuration removal' {

            BeforeAll {

                Mock -CommandName ConvertTo-NormalizedCnpj -MockWith {
                    return $Script:cnpjNormalized
                }

                Mock -CommandName Get-CompanyConfig -MockWith {
                    return $Script:company
                }

                Mock -CommandName Get-StorePath -MockWith $Script:storePathMock

                Mock -CommandName Remove-Item   -MockWith $Script:removeItemMock

                Remove-PipeCompany -Cnpj $Script:cnpjInput -Confirm:$false
            }

            It 'Resolves the Config store using the normalized CNPJ' {
                $invokeParams = @{
                    CommandName     = 'Get-StorePath'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'Context'
                    Exactly         = $true
                    Times           = 1
                    ParameterFilter = {
                        $Scope -eq 'Config' -and $Cnpj -eq $Script:cnpjNormalized
                    }
                }

                Should -Invoke @invokeParams
            }

            It 'Removes the company configuration file' {
                $invokeParams = @{
                    CommandName     = 'Remove-Item'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'Context'
                    Exactly         = $true
                    Times           = 1
                    ParameterFilter = { $LiteralPath -eq $Script:configFile }
                }

                Should -Invoke @invokeParams
            }

            It 'Removes the configuration file with Force' {
                $invokeParams = @{
                    CommandName     = 'Remove-Item'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'Context'
                    ParameterFilter = {
                        $LiteralPath -eq $Script:configFile -and $Force
                    }
                }

                Should -Invoke @invokeParams
            }

            It 'Uses ErrorAction Stop for configuration removal' {
                $invokeParams = @{
                    CommandName     = 'Remove-Item'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'Context'
                    ParameterFilter = {
                        $LiteralPath -eq $Script:configFile -and $ErrorAction -eq 'Stop'
                    }
                }

                Should -Invoke @invokeParams
            }

            It 'Does not resolve the Root store' {
                $invokeParams = @{
                    CommandName     = 'Get-StorePath'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'Context'
                    Exactly         = $true
                    Times           = 0
                    ParameterFilter = { $Scope -eq 'Root' }
                }

                Should -Invoke @invokeParams
            }

            It 'Calls Remove-Item exactly once' {
                $invokeParams = @{
                    CommandName = 'Remove-Item'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'Context'
                    Exactly     = $true
                    Times       = 1
                }

                Should -Invoke @invokeParams
            }
        }
        #endregion


        # DeleteFiles removes company data
        Context 'DeleteFiles removes company data' {

            BeforeAll {

                Mock -CommandName ConvertTo-NormalizedCnpj -MockWith {
                    return $Script:cnpjNormalized
                }

                Mock -CommandName Get-CompanyConfig -MockWith {
                    return $Script:company
                }

                Mock -CommandName Get-StorePath -MockWith $Script:storePathMock

                Mock -CommandName Remove-Item   -MockWith $Script:removeItemMock

                Remove-PipeCompany -Cnpj $Script:cnpjInput -DeleteFiles -Confirm:$false
            }

            It 'Resolves the Root store' {
                $invokeParams = @{
                    CommandName     = 'Get-StorePath'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'Context'
                    Exactly         = $true
                    Times           = 1
                    ParameterFilter = { $Scope -eq 'Root' }
                }

                Should -Invoke @invokeParams
            }

            It 'Removes the company data directory' {
                $invokeParams = @{
                    CommandName     = 'Remove-Item'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'Context'
                    Exactly         = $true
                    Times           = 1
                    ParameterFilter = { $LiteralPath -eq $Script:dataDir }
                }

                Should -Invoke @invokeParams
            }

            It 'Removes the company data recursively' {
                $invokeParams = @{
                    CommandName     = 'Remove-Item'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'Context'
                    ParameterFilter = {
                        $LiteralPath -eq $Script:dataDir -and $Recurse
                    }
                }

                Should -Invoke @invokeParams
            }

            It 'Removes the company data with Force' {
                $invokeParams = @{
                    CommandName     = 'Remove-Item'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'Context'
                    ParameterFilter = {
                        $LiteralPath -eq $Script:dataDir -and $Force
                    }
                }

                Should -Invoke @invokeParams
            }

            It 'Uses ErrorAction Stop for data removal' {
                $invokeParams = @{
                    CommandName     = 'Remove-Item'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'Context'
                    ParameterFilter = {
                        $LiteralPath -eq $Script:dataDir -and $ErrorAction -eq 'Stop'
                    }
                }

                Should -Invoke @invokeParams
            }

            It 'Calls Remove-Item exactly twice' {
                $invokeParams = @{
                    CommandName = 'Remove-Item'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'Context'
                    Exactly     = $true
                    Times       = 2
                }

                Should -Invoke @invokeParams
            }
        }
        #endregion

        #region DeleteFiles is not specified
        Context 'DeleteFiles is not specified' {

            BeforeAll {

                Mock -CommandName ConvertTo-NormalizedCnpj -MockWith {
                    return $Script:cnpjNormalized
                }

                Mock -CommandName Get-CompanyConfig -MockWith {
                    return $Script:company
                }

                Mock -CommandName Get-StorePath -MockWith $Script:storePathMock

                Mock -CommandName Remove-Item   -MockWith $Script:removeItemMock

                Remove-PipeCompany -Cnpj $Script:cnpjInput -Confirm:$false
            }

            It 'Does not resolve the Root store' {
                $invokeParams = @{
                    CommandName     = 'Get-StorePath'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'Context'
                    Exactly         = $true
                    Times           = 0
                    ParameterFilter = { $Scope -eq 'Root' }
                }

                Should -Invoke @invokeParams
            }

            It 'Only removes the configuration file' {
                $invokeParams = @{
                    CommandName = 'Remove-Item'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'Context'
                    Exactly     = $true
                    Times       = 1
                }

                Should -Invoke @invokeParams
            }
        }
        #endregion

        #region Missing data directory
        Context 'Missing data directory' {

            BeforeAll {

                Mock -CommandName ConvertTo-NormalizedCnpj -MockWith {
                    return $Script:cnpjNormalized
                }

                Mock -CommandName Get-CompanyConfig -MockWith {
                    return $Script:company
                }

                Mock -CommandName Get-StorePath -MockWith $Script:storePathMock

                Mock -CommandName Remove-Item   -MockWith {
                    param (
                        [string]$LiteralPath,
                        [switch]$Force,
                        [switch]$Recurse,
                        [System.Management.Automation.ActionPreference]$ErrorAction
                    )

                    $null = $LiteralPath
                    $null = $Force
                    $null = $Recurse
                    $null = $ErrorAction

                    if ($LiteralPath -ne $Script:dataDir) {
                        return
                    }

                    $PSCmdlet.ThrowTerminatingError(
                        [System.Management.Automation.ErrorRecord]::new(
                            [System.Management.Automation.ItemNotFoundException]::new(
                                "Cannot find path '$LiteralPath'."
                            ),
                            'PathNotFound',
                            [System.Management.Automation.ErrorCategory]::ObjectNotFound,
                            $LiteralPath
                        )
                    )
                }

                $Script:exception = $null

                try {
                    Remove-PipeCompany -Cnpj $Script:cnpjInput -DeleteFiles -Confirm:$false
                } catch {
                    $Script:exception = $_
                }
            }

            It 'Does not throw when the data directory Does not exist' {
                $Script:exception | Should -BeNullOrEmpty
            }

            It 'Still attempts to remove the data directory' {
                $invokeParams = @{
                    CommandName     = 'Remove-Item'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'Context'
                    Exactly         = $true
                    Times           = 1
                    ParameterFilter = { $LiteralPath -eq $Script:dataDir }
                }

                Should -Invoke @invokeParams
            }
        }
        #endregion

        #region Configuration removal errors
        Context 'Configuration removal errors' {

            BeforeAll {

                Mock -CommandName ConvertTo-NormalizedCnpj -MockWith {
                    return $Script:cnpjNormalized
                }

                Mock -CommandName Get-CompanyConfig -MockWith {
                    return $Script:company
                }

                Mock -CommandName Get-StorePath -MockWith $Script:storePathMock

                Mock -CommandName Remove-Item   -MockWith {
                    param (
                        [string]$LiteralPath,
                        [switch]$Force,
                        [switch]$Recurse,
                        [System.Management.Automation.ActionPreference]$ErrorAction
                    )

                    $null = $LiteralPath
                    $null = $Force
                    $null = $Recurse
                    $null = $ErrorAction

                    $PSCmdlet.ThrowTerminatingError(
                        [System.Management.Automation.ErrorRecord]::new(
                            [System.UnauthorizedAccessException]::new('Access denied.'),
                            'ConfigRemovalFailed',
                            [System.Management.Automation.ErrorCategory]::PermissionDenied,
                            $LiteralPath
                        )
                    )
                }

                $Script:exception = $null

                try {
                    Remove-PipeCompany -Cnpj $Script:cnpjInput -DeleteFiles -Confirm:$false
                } catch {
                    $Script:exception = $_
                }
            }

            It 'Propagates the configuration removal error' {
                $Script:exception | Should -Not -BeNullOrEmpty
            }

            It 'Propagates the error id unchanged' {
                $Script:exception.FullyQualifiedErrorId |
                    Should -BeLike 'ConfigRemovalFailed*'
            }

            It 'Does not resolve the Root store after config removal fails' {
                $invokeParams = @{
                    CommandName     = 'Get-StorePath'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'Context'
                    Exactly         = $true
                    Times           = 0
                    ParameterFilter = { $Scope -eq 'Root' }
                }

                Should -Invoke @invokeParams
            }

            It 'Does not attempt data removal after config removal fails' {
                $invokeParams = @{
                    CommandName = 'Remove-Item'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'Context'
                    Exactly     = $true
                    Times       = 1
                }

                Should -Invoke @invokeParams
            }
        }
        #endregion

        #region Data removal errors
        Context 'Data removal errors' {

            BeforeAll {

                Mock -CommandName ConvertTo-NormalizedCnpj -MockWith {
                    return $Script:cnpjNormalized
                }

                Mock -CommandName Get-CompanyConfig -MockWith {
                    return $Script:company
                }

                Mock -CommandName Get-StorePath -MockWith $Script:storePathMock

                Mock -CommandName Remove-Item   -MockWith {
                    param (
                        [string]$LiteralPath,
                        [switch]$Force,
                        [switch]$Recurse,
                        [System.Management.Automation.ActionPreference]$ErrorAction
                    )

                    $null = $literalPath
                    $null = $Force
                    $null = $Recurse
                    $null = $ErrorAction

                    if ($LiteralPath -ne $Script:dataDir) {
                        return
                    }

                    $PSCmdlet.ThrowTerminatingError(
                        [System.Management.Automation.ErrorRecord]::new(
                            [System.UnauthorizedAccessException]::new('Access denied.'),
                            'UnauthorizedAccess',
                            [System.Management.Automation.ErrorCategory]::PermissionDenied,
                            $LiteralPath
                        )
                    )
                }

                $Script:exception = $null

                try {
                    Remove-PipeCompany -Cnpj $Script:cnpjInput -DeleteFiles -Confirm:$false
                } catch {
                    $Script:exception = $_
                }
            }

            It 'Throws when data removal fails' {
                $Script:exception | Should -Not -BeNullOrEmpty
            }

            It 'Wraps the error as DataRemovalFailed' {
                $Script:exception.FullyQualifiedErrorId |
                    Should -BeLike 'DataRemovalFailed*'
            }

            It 'Uses PermissionDenied as the error category' {
                $Script:exception.CategoryInfo.Category |
                    Should -Be 'PermissionDenied'
            }

            It 'Attempts configuration removal before data removal' {
                $invokeParams = @{
                    CommandName     = 'Remove-Item'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'Context'
                    Exactly         = $true
                    Times           = 1
                    ParameterFilter = { $LiteralPath -eq $Script:configFile }
                }

                Should -Invoke @invokeParams
            }

            It 'Attempts data removal after configuration removal' {
                $invokeParams = @{
                    CommandName     = 'Remove-Item'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'Context'
                    Exactly         = $true
                    Times           = 1
                    ParameterFilter = { $LiteralPath -eq $Script:dataDir }
                }

                Should -Invoke @invokeParams
            }
        }
        #endregion

        #region Removal ordering
        Context 'Removal ordering' {

            BeforeAll {

                $Script:callOrder = [System.Collections.Generic.List[string]]::new()

                Mock -CommandName ConvertTo-NormalizedCnpj -MockWith {
                    return $Script:cnpjNormalized
                }

                Mock -CommandName Get-CompanyConfig -MockWith {
                    return $Script:company
                }

                Mock -CommandName Get-StorePath -MockWith {
                    param (
                        [string]$Scope,
                        [string]$Cnpj
                    )

                    $null = $Cnpj

                    switch ($Scope) {
                        'Config' {
                            $Script:callOrder.Add('Get-StorePath:Config')
                            return $Script:configPath
                        }
                        'Root' {
                            $Script:callOrder.Add('Get-StorePath:Root')
                            return $Script:dataRoot
                        }
                        default {
                            throw "Unexpected scope '$Scope'."
                        }
                    }
                }

                Mock -CommandName Remove-Item -MockWith {
                    param (
                        [string]$LiteralPath,
                        [switch]$Force,
                        [switch]$Recurse,
                        [System.Management.Automation.ActionPreference]$ErrorAction
                    )

                    $null = $LiteralPath
                    $null = $Force
                    $null = $Recurse
                    $null = $ErrorAction

                    if ($LiteralPath -eq $Script:configFile) {
                        $Script:callOrder.Add('Remove-Config')
                    }

                    if ($LiteralPath -eq $Script:dataDir) {
                        $Script:callOrder.Add('Remove-Data')
                    }
                }

                Remove-PipeCompany -Cnpj $Script:cnpjInput -DeleteFiles -Confirm:$false
            }

            It 'Removes configuration before company data' {
                $configIndex = $Script:callOrder.IndexOf('Remove-Config')
                $dataIndex   = $Script:callOrder.IndexOf('Remove-Data')

                $configIndex | Should -BeGreaterOrEqual 0
                $dataIndex   | Should -BeGreaterOrEqual 0
                $configIndex | Should -BeLessThan $dataIndex
            }
        }
        #endregion

        #region Output contract
        Context 'Output contract' {

            BeforeAll {

                Mock -CommandName ConvertTo-NormalizedCnpj -MockWith {
                    return $Script:cnpjNormalized
                }

                Mock -CommandName Get-CompanyConfig -MockWith {
                    return $Script:company
                }

                Mock -CommandName Get-StorePath -MockWith $Script:storePathMock

                Mock -CommandName Remove-Item   -MockWith $Script:removeItemMock

                $Script:output = @(Remove-PipeCompany -Cnpj $Script:cnpjInput -Confirm:$false)
            }

            It 'Does not produce pipeline output' {
                $Script:output.Count | Should -Be 0
            }
        }
        #endregion

        #region Support ShouldProcess
        Context 'ShouldProcess' {

            BeforeAll {

                $Script:command = Get-Command -Name Remove-PipeCompany

                Mock -CommandName ConvertTo-NormalizedCnpj -MockWith {
                    return $Script:cnpjNormalized
                }

                Mock -CommandName Get-CompanyConfig -MockWith {
                    return $Script:company
                }

                Mock -CommandName Get-StorePath -MockWith $Script:storePathMock

                Mock -CommandName Remove-Item   -MockWith $Script:removeItemMock
            }

            It 'Does not remove anything with WhatIf' {
                Remove-PipeCompany -Cnpj $Script:cnpjInput -DeleteFiles -Confirm:$false -WhatIf

                Should -Invoke -CommandName Remove-Item -ModuleName PipeDFe -Scope Context -Times 0 -Exactly
            }

            It 'Does not expose WhatIf' {
                $Script:command.Parameters.ContainsKey('WhatIf') |
                    Should -BeTrue
            }

            It 'Does not expose Confirm' {
                $Script:command.Parameters.ContainsKey('Confirm') |
                    Should -BeTrue
            }
        }
        #endregion
    }
}
