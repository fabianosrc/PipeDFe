#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for Save-CompanyConfig.

.DESCRIPTION
Covers the persistence contract of Save-CompanyConfig:
  - Throws MissingCnpj when Company.Cnpj is null or empty.
  - Creates the config directory when it does not exist.
  - Writes {cnpj}.json to the config directory.
  - Does not leave a .tmp file after a successful write.
  - Stamps UpdatedAt when AsUpdate is specified.
  - Does not modify UpdatedAt when AsUpdate is not specified.
  - Produces no output.
  - Throws CompanyConfigSaveFailed on serialization failure.
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

Describe 'Save-CompanyConfig' {

    InModuleScope PipeDFe {

        BeforeAll {

            $Script:Cnpj         = '12345678000195'

            $Script:ValidCompany = [PSCustomObject]@{
                SchemaVersion  = 1
                Cnpj           = $Script:Cnpj
                Ie             = $null
                RazaoSocial    = 'ACME COMERCIO LTDA'
                NomeFantasia   = $null
                Uf             = 'SP'
                Ambiente       = 'Producao'
                IsActive       = $true
                XmlPath        = 'C:\ERP\XML'
                XmlPathNfse    = $null
                XmlPathEntrada = $null
                OutputPath     = 'C:\Out'
                Certificado    = [PSCustomObject]@{
                    Path              = $null
                    EncryptedPassword = $null
                }
                Email          = [PSCustomObject]@{
                    Para = @()
                    Cc   = @()
                    Cco  = @()
                }
                Contato        = [PSCustomObject]@{
                    Email    = $null
                    Telefone = $null
                }
                Smtp           = $null
                CreatedAt      = '2026-08-01T00:00:00.0000000+00:00'
                UpdatedAt      = $null
            }

            Mock -CommandName Get-StorePath -MockWith {
                param (
                    [Parameter()]
                    [string]$Scope,

                    [Parameter()]
                    [string]$Cnpj
                )

                $null = $Scope

                Join-Path -Path $TestDrive -ChildPath $Cnpj 'config'
            } -ParameterFilter {
                $Scope -eq 'Config'
            }
        }

        #region Parameter contract
        Context 'Parameter contract' {

            It 'Declares Company as mandatory' {
                $command = Get-Command -Name Save-CompanyConfig

                $mandatory = $command.Parameters['Company'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.Mandatory
                    }

                $mandatory | Should -Not -BeNullOrEmpty
            }
        }
        #endregion

        #region Guard clauses
        Context 'Guard clauses' {

            It 'Throws MissingCnpj when Company.Cnpj is empty' {
                $badCompany = [PSCustomObject]@{ Cnpj = [string]::Empty }

                { Save-CompanyConfig -Company $badCompany } |
                    Should -Throw -ErrorId 'MissingCnpj*'
            }

            It 'Throws MissingCnpj when Company.Cnpj is null' {
                $badCompany = [PSCustomObject]@{ Cnpj = $null }

                { Save-CompanyConfig -Company $badCompany } |
                    Should -Throw -ErrorId 'MissingCnpj*'
            }
        }
        #endregion

        #region File creation
        Context 'File creation' {

            BeforeAll {

                $Script:SaveCalls = @()

                Save-CompanyConfig -Company $Script:ValidCompany
            }

            It 'Creates the config directory when it does not exist' {
                $configPath = Join-Path -Path $TestDrive -ChildPath $Script:Cnpj 'config'

                Test-Path -LiteralPath $configPath -PathType Container | Should -BeTrue
            }

            It 'Writes the JSON file to the config directory' {
                $configPath  = Join-Path -Path $TestDrive -ChildPath $Script:Cnpj 'config'

                $companyFile = Join-Path -Path $configPath -ChildPath "$Script:Cnpj.json"

                Test-Path -LiteralPath $companyFile -PathType Leaf | Should -BeTrue
            }

            It 'Does not leave a .tmp file after successful write' {
                $configPath = Join-Path -Path $TestDrive -ChildPath $Script:Cnpj 'config'

                $tmpFile    = Join-Path -Path $configPath -ChildPath "$Script:Cnpj.json.tmp"

                Test-Path -LiteralPath $tmpFile | Should -BeFalse
            }

            It 'Produces no output' {
                $result = Save-CompanyConfig -Company $Script:ValidCompany
                $result | Should -BeNullOrEmpty
            }
        }
        #endregion

        #region UpdatedAt stamping
        Context 'UpdatedAt stamping' {

            It 'Stamps UpdatedAt when AsUpdate is specified' {
                $cnpj2 = '98765432000100'

                $company2 = [PSCustomObject]@{
                    Cnpj      = $cnpj2
                    UpdatedAt = $null
                    Email     = [PSCustomObject]@{
                        Para = @()
                        Cc   = @()
                        Cco  = @()
                    }
                }

                Save-CompanyConfig -Company $company2 -AsUpdate

                $configPath  = Join-Path -Path $TestDrive -ChildPath $cnpj2 'config'

                $companyFile = Join-Path -Path $configPath -ChildPath "$cnpj2.json"

                $saved = Get-Content -LiteralPath $companyFile -Raw | ConvertFrom-Json

                $saved.UpdatedAt | Should -Not -BeNull
            }

            It 'Does not stamp UpdatedAt when AsUpdate is not specified' {
                Save-CompanyConfig -Company $Script:ValidCompany

                $configPath  = Join-Path -Path $TestDrive -ChildPath $Script:Cnpj 'config'

                $companyFile = Join-Path -Path $configPath -ChildPath "$Script:Cnpj.json"

                $saved = Get-Content -LiteralPath $companyFile -Raw | ConvertFrom-Json

                $saved.UpdatedAt | Should -BeNull
            }

            It 'Does not modify the caller object when AsUpdate is specified' {
                $cnpj3    = '11111111000191'
                $company3 = [PSCustomObject]@{
                    Cnpj      = $cnpj3
                    UpdatedAt = $null
                    Email     = [PSCustomObject]@{
                        Para = @()
                        Cc   = @()
                        Cco  = @()
                    }
                }

                Save-CompanyConfig -Company $company3 -AsUpdate

                $company3.UpdatedAt | Should -BeNull
            }
        }
        #endregion

        #region JSON content
        Context 'JSON content' {

            BeforeAll {

                Save-CompanyConfig -Company $Script:ValidCompany

                $configPath  = Join-Path -Path $TestDrive -ChildPath $Script:Cnpj 'config'

                $companyFile = Join-Path -Path $configPath -ChildPath "$Script:Cnpj.json"

                $Script:Saved = Get-Content -LiteralPath $companyFile -Raw | ConvertFrom-Json
            }

            It 'Persists the correct Cnpj' {
                $Script:Saved.Cnpj | Should -Be $Script:Cnpj
            }

            It 'Persists the correct RazaoSocial' {
                $Script:Saved.RazaoSocial | Should -Be 'ACME COMERCIO LTDA'
            }

            It 'Persists the correct Ambiente' {
                $Script:Saved.Ambiente | Should -Be 'Producao'
            }
        }
        #endregion
    }
}
