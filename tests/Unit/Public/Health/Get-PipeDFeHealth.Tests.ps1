#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for Get-PipeDFeHealth.

.DESCRIPTION
All external dependencies are mocked. No filesystem or database I/O occurs.

Coverage includes:
  - Parameter contract
  - No companies registered
  - Single CNPJ supplied
  - Single CNPJ supplied checks company regardless of active state
  - All active companies checked when no CNPJ supplied
  - Healthy company
  - Unhealthy company - database/index does not exist
  - Degraded company - outdated schema version
  - Unexpected exception during company check
  - Overall status precedence - Unhealthy wins over Degraded
  - Overall status precedence - Degraded wins over Healthy
  - Output contract
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

Describe 'Get-PipeDFeHealth' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            #region Test data
            $Script:CnpjInput      = '12.345.678/0001-95'
            $Script:CnpjNormalized = '12345678000195'

            $Script:DbPathA = 'C:\PipeDFe\12345678000195\data\index.db'
            $Script:DbPathB = 'C:\PipeDFe\98765432000100\data\index.db'

            $Script:CompanyA = [PSCustomObject]@{
                Cnpj     = '12345678000195'
                Name     = 'Empresa A'
                IsActive = $true
            }

            $Script:CompanyB = [PSCustomObject]@{
                Cnpj     = '98765432000100'
                Name     = 'Empresa B'
                IsActive = $true
            }

            $Script:InactiveCompany = [PSCustomObject]@{
                Cnpj     = '11111111000111'
                Name     = 'Empresa Inativa'
                IsActive = $false
            }
            #endregion

            #region Test helpers
            function New-MockSqliteConnection {
                [CmdletBinding()]
                [OutputType([PSCustomObject])]
                param (
                    [Parameter(Mandatory)]
                    [int]$SchemaVersion
                )

                $connection = [PSCustomObject]@{
                    PSTypeName    = 'MockSqliteConnection'
                    SchemaVersion = $SchemaVersion
                }

                $connection |
                    Add-Member -MemberType ScriptMethod -Name Dispose -Value {

                    }

                $connection |
                    Add-Member -MemberType ScriptMethod -Name CreateCommand -Value {
                        $command = [PSCustomObject]@{
                            CommandText   = [string]::Empty
                            SchemaVersion = $this.SchemaVersion
                        }

                        $memberParamsOne = @{
                            MemberType = 'ScriptMethod'
                            Name       = 'ExecuteScalar'
                            Value      = { return $this.SchemaVersion }
                        }

                        $command | Add-Member @memberParamsOne

                        $memberParamsTwo = @{
                            MemberType = 'ScriptMethod'
                            Name       = 'Dispose'
                            Value      = { }
                        }

                        $command | Add-Member @memberParamsTwo

                        return $command
                    }

                return $connection
            }

            function New-MockHealthyDatabase {
                [CmdletBinding()]
                [OutputType([void])]
                param (
                    [int]$SchemaVersion = 2
                )

                $Script:MockSchemaVersion = $SchemaVersion

                Mock -CommandName Get-StorePath -MockWith {
                    param (
                        [string]$Cnpj
                    )

                    switch ($Cnpj) {
                        $Script:CompanyA.Cnpj {
                            return $Script:DbPathA
                        }

                        $Script:CompanyB.Cnpj {
                            return $Script:DbPathB
                        }

                        default {
                            return "C:\PipeDFe\$Cnpj\data\index.db"
                        }
                    }
                }

                Mock -CommandName Test-Path -MockWith {
                    return $true
                }

                Mock -CommandName Open-SqliteConnection -MockWith {
                    return New-MockSqliteConnection -SchemaVersion $Script:MockSchemaVersion
                }
            }

            function Get-CompanyResult {
                [CmdletBinding()]
                [OutputType([PSCustomObject])]
                param (
                    [Parameter(Mandatory)]
                    [PSCustomObject]$Result,

                    [Parameter()]
                    [int]$Index = 0
                )

                return $Result.Companies[$Index]
            }
            #endregion
        }

        #region Parameter contract
        Context 'Parameter contract' {

            BeforeAll {

                $Script:Command = Get-Command -Name Get-PipeDFeHealth
            }

            It 'Declares Cnpj as an optional string' {
                $Script:Command.Parameters['Cnpj'].ParameterType |
                    Should -Be ([string])

                $Script:Command.Parameters['Cnpj'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute]
                    } |

                    Select-Object -First 1 |
                    ForEach-Object { $_.Mandatory | Should -BeFalse }
            }

            It 'Does not expose WhatIf' {
                $Script:Command.Parameters.ContainsKey('WhatIf') | Should -BeFalse
            }

            It 'Does not expose Confirm' {
                $Script:Command.Parameters.ContainsKey('Confirm') | Should -BeFalse
            }
        }
        #endregion

        #region No companies registered
        Context 'No companies registered' {

            BeforeAll {

                Mock -CommandName Get-PipeCompany -MockWith {
                    return @()
                }

                Mock -CommandName Get-StorePath -MockWith {

                }

                Mock -CommandName Open-SqliteConnection -MockWith {

                }

                $Script:Result = Get-PipeDFeHealth
            }

            It 'Returns a single object' {
                @($Script:Result) | Should -HaveCount 1
            }

            It 'Sets overall Status to Degraded' {
                $Script:Result.Status | Should -Be 'Degraded'
            }

            It 'Returns an empty Companies collection' {
                @($Script:Result.Companies) | Should -HaveCount 0
            }

            It 'Sets CheckedAt to a non-empty string' {
                $Script:Result.CheckedAt | Should -Not -BeNullOrEmpty
            }

            It 'Does not check any company database' {
                $invokeParamsOne = @{
                    CommandName = 'Get-StorePath'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'Context'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke @invokeParamsOne

                $invokeParamsTwo = @{
                    CommandName = 'Open-SqliteConnection'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'Context'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke @invokeParamsTwo
            }
        }
        #endregion

        #region Single CNPJ supplied
        Context 'Single CNPJ supplied' {

            BeforeAll {

                Mock -CommandName ConvertTo-NormalizedCnpj -MockWith {
                    return $Script:CnpjNormalized
                }

                Mock -CommandName Get-PipeCompany -MockWith {
                    return @($Script:CompanyA)
                }

                New-MockHealthyDatabase

                $Script:Result = Get-PipeDFeHealth -Cnpj $Script:CnpjInput
            }

            It 'Normalizes the supplied CNPJ exactly once' {
                $invokeParams = @{
                    CommandName     = 'ConvertTo-NormalizedCnpj'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'Context'
                    Exactly         = $true
                    Times           = 1
                    ParameterFilter = {
                        $Value -eq $Script:CnpjInput
                    }
                }

                Should -Invoke @invokeParams
            }

            It 'Calls Get-PipeCompany with the normalized CNPJ' {
                $invokeParams = @{
                    CommandName     = 'Get-PipeCompany'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'Context'
                    Exactly         = $true
                    Times           = 1
                    ParameterFilter = {
                        $Cnpj -eq $Script:CnpjNormalized
                    }
                }

                Should -Invoke @invokeParams
            }

            It 'Does not filter by IsActive' {
                $invokeParams = @{
                    CommandName     = 'Get-PipeCompany'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'Context'
                    Exactly         = $true
                    Times           = 1
                    ParameterFilter = {
                        -not $PSBoundParameters.ContainsKey('IsActive')
                    }
                }

                Should -Invoke @invokeParams
            }

            It 'Checks the explicitly requested company regardless of active state' {
                Mock -CommandName Get-PipeCompany -MockWith {
                    return @($Script:InactiveCompany)
                }

                $inactiveResult = Get-PipeDFeHealth -Cnpj $Script:CnpjInput

                @($inactiveResult.Companies) | Should -HaveCount 1

                $inactiveResult.Companies[0].Cnpj | Should -Be $Script:InactiveCompany.Cnpj
            }
        }
        #endregion

        #region All active companies

        Context 'All active companies when no CNPJ is supplied' {

            BeforeAll {

                Mock -CommandName ConvertTo-NormalizedCnpj -MockWith {

                }

                Mock -CommandName Get-PipeCompany -MockWith {
                    return @($Script:CompanyA, $Script:CompanyB)
                }

                New-MockHealthyDatabase

                $Script:Result = Get-PipeDFeHealth
            }

            It 'Calls Get-PipeCompany with IsActive true' {
                $invokeParams = @{
                    CommandName     = 'Get-PipeCompany'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'Context'
                    Exactly         = $true
                    Times           = 1
                    ParameterFilter = {
                        $IsActive -eq $true
                    }
                }

                Should -Invoke @invokeParams
            }

            It 'Does not call ConvertTo-NormalizedCnpj' {
                $invokeParams = @{
                    CommandName = 'ConvertTo-NormalizedCnpj'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'Context'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke @invokeParams
            }

            It 'Checks all returned active companies' {
                @($Script:Result.Companies) | Should -HaveCount 2
            }
        }
        #endregion

        #region Healthy company
        Context 'Healthy company' {

            BeforeAll {

                Mock -CommandName Get-PipeCompany -MockWith {
                    return @($Script:CompanyA)
                }

                New-MockHealthyDatabase -SchemaVersion 2

                $Script:Result = Get-PipeDFeHealth

                $Script:CompanyResult = Get-CompanyResult -Result $Script:Result
            }

            It 'Sets company Status to Healthy' {
                $Script:CompanyResult.Status | Should -Be 'Healthy'
            }

            It 'Sets DbExists to true' {
                $Script:CompanyResult.DbExists | Should -BeTrue
            }

            It 'Sets DbVersion to 2' {
                $Script:CompanyResult.DbVersion | Should -Be 2
            }

            It 'Sets DbVersionOk to true' {
                $Script:CompanyResult.DbVersionOk | Should -BeTrue
            }

            It 'Returns no issues' {
                @($Script:CompanyResult.Issues) | Should -HaveCount 0
            }

            It 'Sets overall Status to Healthy' {
                $Script:Result.Status | Should -Be 'Healthy'
            }

            It 'Calls Get-StorePath with the company CNPJ' {
                $invokeParams = @{
                    CommandName     = 'Get-StorePath'
                    ModuleName      = 'PipeDFe'
                    Scope           = 'Context'
                    Exactly         = $true
                    Times           = 1
                    ParameterFilter = {
                        $Cnpj -eq $Script:CompanyA.Cnpj
                    }
                }

                Should -Invoke @invokeParams
            }

            It 'Calls Open-SqliteConnection exactly once' {
                $invokeParams = @{
                    CommandName = 'Open-SqliteConnection'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'Context'
                    Exactly     = $true
                    Times       = 1
                }

                Should -Invoke @invokeParams
            }
        }
        #endregion

        #region Unhealthy company
        Context 'Unhealthy company - database does not exist' {

            BeforeAll {

                Mock -CommandName Get-PipeCompany -MockWith {
                    return @($Script:CompanyA)
                }

                Mock -CommandName Get-StorePath -MockWith {
                    return $Script:DbPathA
                }

                Mock -CommandName Test-Path -MockWith {
                    return $false
                }

                Mock -CommandName Open-SqliteConnection -MockWith {
                    throw 'Open-SqliteConnection should not be called.'
                }

                $Script:Result = Get-PipeDFeHealth

                $Script:CompanyResult = Get-CompanyResult -Result $Script:Result
            }

            It 'Sets company Status to Unhealthy' {
                $Script:CompanyResult.Status | Should -Be 'Unhealthy'
            }

            It 'Sets DbExists to false' {
                $Script:CompanyResult.DbExists | Should -BeFalse
            }

            It 'Does not call Open-SqliteConnection' {
                $invokeParams = @{
                    CommandName = 'Open-SqliteConnection'
                    ModuleName  = 'PipeDFe'
                    Scope       = 'Context'
                    Exactly     = $true
                    Times       = 0
                }

                Should -Invoke @invokeParams
            }

            It 'Returns one issue' {
                @($Script:CompanyResult.Issues) | Should -HaveCount 1
            }

            It 'Returns a non-empty issue' {
                $Script:CompanyResult.Issues[0] | Should -Not -BeNullOrEmpty
            }

            It 'Sets overall Status to Unhealthy' {
                $Script:Result.Status | Should -Be 'Unhealthy'
            }
        }
        #endregion

        #region Degraded company
        Context 'Degraded company - schema version outdated' {

            BeforeAll {

                Mock -CommandName Get-PipeCompany -MockWith {
                    return @($Script:CompanyA)
                }

                New-MockHealthyDatabase -SchemaVersion 1

                $Script:Result = Get-PipeDFeHealth

                $Script:CompanyResult = Get-CompanyResult -Result $Script:Result
            }

            It 'Sets company Status to Degraded' {
                $Script:CompanyResult.Status | Should -Be 'Degraded'
            }

            It 'Sets DbExists to true' {
                $Script:CompanyResult.DbExists | Should -BeTrue
            }

            It 'Sets DbVersion to 1' {
                $Script:CompanyResult.DbVersion | Should -Be 1
            }

            It 'Sets DbVersionOk to false' {
                $Script:CompanyResult.DbVersionOk | Should -BeFalse
            }

            It 'Returns one issue' {
                @($Script:CompanyResult.Issues) | Should -HaveCount 1
            }

            It 'Sets overall Status to Degraded' {
                $Script:Result.Status | Should -Be 'Degraded'
            }
        }
        #endregion

        #region Unexpected exception
        Context 'Unexpected exception during company check' {

            BeforeAll {

                Mock -CommandName Get-PipeCompany -MockWith {
                    return @($Script:CompanyA)
                }

                Mock -CommandName Get-StorePath -MockWith {
                    throw [System.Exception]::new('Simulated failure')
                }

                $Script:Result = Get-PipeDFeHealth

                $Script:CompanyResult = Get-CompanyResult -Result $Script:Result
            }

            It 'Does not throw' {
                { Get-PipeDFeHealth } | Should -Not -Throw
            }

            It 'Sets company Status to Unhealthy' {
                $Script:CompanyResult.Status | Should -Be 'Unhealthy'
            }

            It 'Captures the exception message as an issue' {
                $Script:CompanyResult.Issues[0] | Should -BeLike '*Simulated failure*'
            }

            It 'Sets overall Status to Unhealthy' {
                $Script:Result.Status | Should -Be 'Unhealthy'
            }
        }
        #endregion

        #region Overall status precedence
        Context 'Overall status - Unhealthy wins over Degraded' {

            BeforeAll {

                Mock -CommandName Get-PipeCompany -MockWith {
                    return @($Script:CompanyA, $Script:CompanyB)
                }

                Mock -CommandName Get-StorePath -MockWith {
                    param (
                        [string]$Cnpj
                    )

                    if ($Cnpj -eq $Script:CompanyA.Cnpj) {
                        return $Script:DbPathA
                    }

                    return $Script:DbPathB
                }

                # CompanyA: index exists, schema outdated (Degraded)
                # CompanyB: index missing (Unhealthy)
                Mock -CommandName Test-Path -MockWith {
                    param (
                        [string]$LiteralPath
                    )

                    return $LiteralPath -like '*12345678000195*'
                }

                Mock -CommandName Open-SqliteConnection -MockWith {
                    return New-MockSqliteConnection -SchemaVersion 1
                }

                $Script:Result = Get-PipeDFeHealth
            }

            It 'Reports two companies' {
                @($Script:Result.Companies) | Should -HaveCount 2
            }

            It 'Reports Company A as Degraded' {
                $Script:Result.Companies[0].Status | Should -Be 'Degraded'
            }

            It 'Reports Company B as Unhealthy' {
                $Script:Result.Companies[1].Status | Should -Be 'Unhealthy'
            }

            It 'Sets overall Status to Unhealthy' {
                $Script:Result.Status | Should -Be 'Unhealthy'
            }
        }

        Context 'Overall status - Degraded wins over Healthy' {

            BeforeAll {

                Mock -CommandName Get-PipeCompany -MockWith {
                    return @($Script:CompanyA, $Script:CompanyB)
                }

                # CompanyA: schema v2 (Healthy), CompanyB: schema v1 (Degraded)
                Mock -CommandName Get-StorePath -MockWith {
                    param (
                        [string]$Cnpj
                    )

                    if ($Cnpj -eq $Script:CompanyA.Cnpj) {
                        return $Script:DbPathA
                    }

                    return $Script:DbPathB
                }

                Mock -CommandName Test-Path -MockWith {
                    return $true
                }

                Mock -CommandName Open-SqliteConnection -MockWith {
                    param (
                        [string]$Path
                    )

                    if ($Path -eq $Script:DbPathA) {
                        return New-MockSqliteConnection -SchemaVersion 2
                    }

                    return New-MockSqliteConnection -SchemaVersion 1
                }

                $Script:Result = Get-PipeDFeHealth
            }

            It 'Reports Company A as Healthy' {
                $Script:Result.Companies[0].Status | Should -Be 'Healthy'
            }

            It 'Reports Company B as Degraded' {
                $Script:Result.Companies[1].Status | Should -Be 'Degraded'
            }

            It 'Sets overall Status to Degraded' {
                $Script:Result.Status | Should -Be 'Degraded'
            }
        }
        #endregion

        #region Output contract
        Context 'Output contract' {

            BeforeAll {

                Mock -CommandName Get-PipeCompany -MockWith {
                    return @($Script:CompanyA)
                }

                New-MockHealthyDatabase -SchemaVersion 2

                $Script:Result = Get-PipeDFeHealth

                $Script:CompanyResult = Get-CompanyResult -Result $Script:Result
            }

            It 'Returns exactly one top-level object' {
                @($Script:Result) | Should -HaveCount 1
            }

            It 'Returns a PSCustomObject' {
                $Script:Result | Should -BeOfType [PSCustomObject]
            }

            It 'Exposes the expected top-level properties' {
                $properties = $Script:Result.PSObject.Properties.Name

                $properties | Should -Contain 'Status'
                $properties | Should -Contain 'CheckedAt'
                $properties | Should -Contain 'Companies'
            }

            It 'Exposes Status as string' {
                $Script:Result.Status | Should -BeOfType [string]
            }

            It 'Exposes CheckedAt as string' {
                $Script:Result.CheckedAt | Should -BeOfType [string]
            }

            It 'Exposes Companies as a collection' {
                @($Script:Result.Companies) | Should -HaveCount 1
            }

            It 'Exposes the expected company properties' {
                $properties = $Script:CompanyResult.PSObject.Properties.Name

                $properties | Should -Contain 'Cnpj'
                $properties | Should -Contain 'Name'
                $properties | Should -Contain 'Status'
                $properties | Should -Contain 'DbExists'
                $properties | Should -Contain 'DbVersion'
                $properties | Should -Contain 'DbVersionOk'
                $properties | Should -Contain 'Issues'
            }

            It 'Exposes Cnpj as string' {
                $Script:CompanyResult.Cnpj | Should -BeOfType [string]
            }

            It 'Exposes Name as string' {
                $Script:CompanyResult.Name | Should -BeOfType [string]
            }

            It 'Exposes Status as string' {
                $Script:CompanyResult.Status | Should -BeOfType [string]
            }

            It 'Exposes DbExists as bool' {
                $Script:CompanyResult.DbExists | Should -BeOfType [bool]
            }

            It 'Exposes DbVersion as int' {
                $Script:CompanyResult.DbVersion | Should -BeOfType [int]
            }

            It 'Exposes DbVersionOk as bool' {
                $Script:CompanyResult.DbVersionOk | Should -BeOfType [bool]
            }

            It 'Exposes Issues as a collection of strings' {
                @($Script:CompanyResult.Issues) | ForEach-Object {
                    $_ | Should -BeOfType [string]
                }
            }
        }
        #endregion
    }
}
