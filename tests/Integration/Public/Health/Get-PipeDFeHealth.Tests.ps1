#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Integration tests for Get-PipeDFeHealth.

.DESCRIPTION
Tests health diagnostics using real company registration and SQLite indexes.

No internal dependencies are mocked. Each test uses an isolated data store
and restores the original environment variables after execution.

Coverage includes:
  - Health of a registered company with a newly initialized SQLite index
  - Detection of the current SQLite schema version
  - Verification of the schema version persisted in SQLite
  - Trade name resolution and legal name fallback
  - Detection of missing SQLite indexes
  - Health diagnostic output and type contracts
  - Isolation of test data and environment variables
#>

BeforeDiscovery {
    # InModuleScope needs to resolve the PipeDFe module during the Discovery phase,
    # because that's when Context/It are executed to register the test tree. If the
    # module isn't loaded at that point, InModuleScope fails before any BeforeAll or
    # BeforeEach ever runs.
    $moduleRoot = (Get-Item $PSScriptRoot).Parent.Parent.Parent.Parent.FullName

    $moduleName = Join-Path -Path $moduleRoot -ChildPath 'PipeDFe.psd1'

    Import-Module -Name $moduleName -Force -Global -ErrorAction Stop
}

Describe 'Get-PipeDFeHealth' -Tag 'Integration' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            #region Test data
            $Script:Cnpj = '11222333000181'
            $Script:RazaoSocial  = 'EMPRESA TESTE LTDA'
            $Script:NomeFantasia = 'EMPRESA TESTE'

            $Script:ExpectedSchemaVersion = $Script:DFeIndexSchemaVersion
            #endregion
        }

        BeforeEach {

            #region Environment isolation
            $Script:OriginalLocalAppData = $env:LOCALAPPDATA
            $Script:OriginalDataRoot     = $env:PIPEDFE_DATA_ROOT

            $joinPathParams = @{
                Path      = $TestDrive
                ChildPath = [guid]::NewGuid().ToString('N')
            }

            $Script:CasePath   = Join-Path @joinPathParams
            $Script:StorePath  = Join-Path -Path $Script:CasePath -ChildPath 'store'
            $Script:XmlPath    = Join-Path -Path $Script:CasePath -ChildPath 'xml'
            $Script:OutputPath = Join-Path -Path $Script:CasePath -ChildPath 'output'

            [void][System.IO.Directory]::CreateDirectory($Script:StorePath)
            [void][System.IO.Directory]::CreateDirectory($Script:XmlPath)

            $env:LOCALAPPDATA      = $Script:StorePath
            $env:PIPEDFE_DATA_ROOT = $null
            #endregion
        }

        AfterEach {

            #region Environment restoration
            $env:LOCALAPPDATA      = $Script:OriginalLocalAppData
            $env:PIPEDFE_DATA_ROOT = $Script:OriginalDataRoot
            #endregion
        }

        #region Healthy company
        Context 'Registered company with a newly initialized index' {

            BeforeEach {

                $companyParams = @{
                    Cnpj        = $Script:Cnpj
                    RazaoSocial = $Script:RazaoSocial
                    Uf          = 'SP'
                    Ambiente    = 'Homologacao'
                    XmlPath     = $Script:XmlPath
                    OutputPath  = $Script:OutputPath
                    Confirm     = $false
                    ErrorAction = 'Stop'
                }

                New-PipeCompany @companyParams | Out-Null

                $indexParams = @{
                    Cnpj        = $Script:Cnpj
                    ErrorAction = 'Stop'
                }

                Initialize-DFeIndex @indexParams | Out-Null

                $healthParams = @{
                    Cnpj        = $Script:Cnpj
                    ErrorAction = 'Stop'
                }

                $Script:Result = Get-PipeDFeHealth @healthParams
                $Script:CompanyHealth = $Script:Result.Companies[0]
            }

            It 'Returns exactly one company' {
                @($Script:Result.Companies) | Should -HaveCount 1
            }

            It 'Reports the overall status as Healthy' {
                $Script:Result.Status | Should -BeExactly 'Healthy'
            }

            It 'Reports the company status as Healthy' {
                $Script:CompanyHealth.Status | Should -BeExactly 'Healthy'
            }

            It 'Returns the registered company CNPJ' {
                $Script:CompanyHealth.Cnpj | Should -BeExactly $Script:Cnpj
            }

            It 'Reports that the SQLite index exists' {
                $Script:CompanyHealth.DbExists | Should -BeTrue
            }

            It 'Reports the current SQLite schema version' {
                $Script:CompanyHealth.DbVersion |
                    Should -Be $Script:ExpectedSchemaVersion
            }

            It 'Reports the SQLite schema version as valid' {
                $Script:CompanyHealth.DbVersionOk | Should -BeTrue
            }

            It 'Returns no diagnostic issues' {
                @($Script:CompanyHealth.Issues) | Should -HaveCount 0
            }

            It 'Persists the expected schema version in SQLite' {
                $databasePath = Get-StorePath -Scope 'Index' -Cnpj $Script:Cnpj

                $connection = $null
                $command    = $null

                try {
                    $connection = Open-SqliteConnection -Path $databasePath
                    $command = $connection.CreateCommand()

                    $command.CommandText = 'PRAGMA user_version;'

                    $actualVersion = [int]$command.ExecuteScalar()

                    $actualVersion |
                        Should -Be $Script:ExpectedSchemaVersion
                } finally {
                    if ($null -ne $command) {
                        $command.Dispose()
                    }

                    if ($null -ne $connection) {
                        $connection.Dispose()
                    }
                }
            }
        }
        #endregion

        #region Trade name resolution
        Context 'Registered company with a trade name' {

            BeforeEach {

                $companyParams = @{
                    Cnpj         = $Script:Cnpj
                    RazaoSocial  = $Script:RazaoSocial
                    NomeFantasia = $Script:NomeFantasia
                    Uf           = 'SP'
                    Ambiente     = 'Homologacao'
                    XmlPath      = $Script:XmlPath
                    OutputPath   = $Script:OutputPath
                    Confirm      = $false
                    ErrorAction  = 'Stop'
                }

                New-PipeCompany @companyParams | Out-Null

                $healthParams = @{
                    Cnpj        = $Script:Cnpj
                    ErrorAction = 'Stop'
                }

                $Script:Result = Get-PipeDFeHealth @healthParams
                $Script:CompanyHealth = $Script:Result.Companies[0]
            }

            It 'Uses the trade name as the company display name' {
                $Script:CompanyHealth.Name |
                    Should -BeExactly $Script:NomeFantasia
            }

            It 'Preserves the registered company CNPJ' {
                $Script:CompanyHealth.Cnpj |
                    Should -BeExactly $Script:Cnpj
            }
        }
        #endregion

        #region Legal name fallback
        Context 'Registered company without a trade name' {

            BeforeEach {

                $companyParams = @{
                    Cnpj        = $Script:Cnpj
                    RazaoSocial = $Script:RazaoSocial
                    Uf          = 'SP'
                    Ambiente    = 'Homologacao'
                    XmlPath     = $Script:XmlPath
                    OutputPath  = $Script:OutputPath
                    Confirm     = $false
                    ErrorAction = 'Stop'
                }

                New-PipeCompany @companyParams | Out-Null

                $healthParams = @{
                    Cnpj        = $Script:Cnpj
                    ErrorAction = 'Stop'
                }

                $Script:Result = Get-PipeDFeHealth @healthParams
                $Script:CompanyHealth = $Script:Result.Companies[0]
            }

            It 'Returns the legal name when no trade name is configured' {
                $Script:CompanyHealth.Name |
                    Should -BeExactly $Script:RazaoSocial
            }

            It 'Preserves the registered company CNPJ' {
                $Script:CompanyHealth.Cnpj |
                    Should -BeExactly $Script:Cnpj
            }
        }
        #endregion

        #region Missing index
        Context 'Registered company without an initialized index' {

            BeforeEach {

                $companyParams = @{
                    Cnpj        = $Script:Cnpj
                    RazaoSocial = $Script:RazaoSocial
                    Uf          = 'SP'
                    Ambiente    = 'Homologacao'
                    XmlPath     = $Script:XmlPath
                    OutputPath  = $Script:OutputPath
                    Confirm     = $false
                    ErrorAction = 'Stop'
                }

                New-PipeCompany @companyParams | Out-Null

                $healthParams = @{
                    Cnpj        = $Script:Cnpj
                    ErrorAction = 'Stop'
                }

                $Script:Result = Get-PipeDFeHealth @healthParams
                $Script:CompanyHealth = $Script:Result.Companies[0]
            }

            It 'Reports the company status as Unhealthy' {
                $Script:CompanyHealth.Status |
                    Should -BeExactly 'Unhealthy'
            }

            It 'Reports the overall status as Unhealthy' {
                $Script:Result.Status |
                    Should -BeExactly 'Unhealthy'
            }

            It 'Reports that the SQLite index does not exist' {
                $Script:CompanyHealth.DbExists | Should -BeFalse
            }

            It 'Reports an unknown schema version' {
                $Script:CompanyHealth.DbVersion | Should -Be -1
            }

            It 'Reports the schema version as invalid' {
                $Script:CompanyHealth.DbVersionOk | Should -BeFalse
            }

            It 'Returns a diagnostic issue for the missing index' {
                @($Script:CompanyHealth.Issues) | Should -HaveCount 1

                $Script:CompanyHealth.Issues[0] |
                    Should -Match 'Index database does not exist'
            }
        }
        #endregion

        #region Output contract
        Context 'Health diagnostic output contract' {

            BeforeEach {

                $companyParams = @{
                    Cnpj        = $Script:Cnpj
                    RazaoSocial = $Script:RazaoSocial
                    Uf          = 'SP'
                    Ambiente    = 'Homologacao'
                    XmlPath     = $Script:XmlPath
                    OutputPath  = $Script:OutputPath
                    Confirm     = $false
                    ErrorAction = 'Stop'
                }

                New-PipeCompany @companyParams | Out-Null

                $indexParams = @{
                    Cnpj        = $Script:Cnpj
                    ErrorAction = 'Stop'
                }

                Initialize-DFeIndex @indexParams | Out-Null

                $healthParams = @{
                    Cnpj        = $Script:Cnpj
                    ErrorAction = 'Stop'
                }

                $Script:Result = Get-PipeDFeHealth @healthParams
                $Script:CompanyHealth = $Script:Result.Companies[0]
            }

            It 'Returns a single top-level object' {
                @($Script:Result) | Should -HaveCount 1
            }

            It 'Returns a PSCustomObject' {
                $Script:Result | Should -BeOfType [PSCustomObject]
            }

            It 'Returns the expected health type name' {
                $Script:Result.PSObject.TypeNames[0] |
                    Should -BeExactly 'PipeDFe.Health'
            }

            It 'Returns the expected company health type name' {
                $Script:CompanyHealth.PSObject.TypeNames[0] |
                    Should -BeExactly 'PipeDFe.CompanyHealth'
            }

            It 'Exposes the expected top-level properties' {

                $properties = $Script:Result.PSObject.Properties.Name

                $properties | Should -Contain 'Status'
                $properties | Should -Contain 'CheckedAt'
                $properties | Should -Contain 'Companies'
            }

            It 'Returns a non-empty diagnostic timestamp' {
                $Script:Result.CheckedAt |
                    Should -Not -BeNullOrEmpty
            }

            It 'Returns a valid UTC diagnostic timestamp' {

                $timestamp = [datetimeoffset]::Parse(
                    $Script:Result.CheckedAt,
                    [System.Globalization.CultureInfo]::InvariantCulture
                )

                $timestamp.Offset |
                    Should -Be ([timespan]::Zero)
            }

            It 'Exposes the expected company properties' {

                $properties = $Script:CompanyHealth.PSObject.Properties.Name

                $properties | Should -Contain 'Cnpj'
                $properties | Should -Contain 'Name'
                $properties | Should -Contain 'Status'
                $properties | Should -Contain 'DbExists'
                $properties | Should -Contain 'DbVersion'
                $properties | Should -Contain 'DbVersionOk'
                $properties | Should -Contain 'Issues'
            }

            It 'Returns the database version as an integer' {
                $Script:CompanyHealth.DbVersion |
                    Should -BeOfType [int]
            }

            It 'Returns the database existence flag as a boolean' {
                $Script:CompanyHealth.DbExists |
                    Should -BeOfType [bool]
            }

            It 'Returns the schema validation flag as a boolean' {
                $Script:CompanyHealth.DbVersionOk |
                    Should -BeOfType [bool]
            }

            It 'Returns diagnostic issues as a string array' {
                $Script:CompanyHealth.Issues.GetType() |
                    Should -Be ([string[]])
            }

            It 'Returns a company health entry as a PSCustomObject' {
                $Script:CompanyHealth |
                    Should -BeOfType [PSCustomObject]
            }
        }
        #endregion
    }
}
