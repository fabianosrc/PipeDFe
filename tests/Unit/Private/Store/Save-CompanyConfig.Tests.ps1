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

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSReviewUnusedParameter',
    'Scope',
    Justification = 'Required by Get-StorePath Scope'
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

                [System.IO.Path]::Combine($TestDrive, $Cnpj, 'config')
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
                $configPath = [System.IO.Path]::Combine($TestDrive, $Script:Cnpj, 'config')

                Test-Path -LiteralPath $configPath -PathType Container | Should -BeTrue
            }

            It 'Writes the JSON file to the config directory' {
                $configPath  = [System.IO.Path]::Combine($TestDrive, $Script:Cnpj, 'config')
                $companyFile = Join-Path -Path $configPath -ChildPath "$Script:Cnpj.json"

                Test-Path -LiteralPath $companyFile -PathType Leaf | Should -BeTrue
            }

            It 'Does not leave a .tmp file after successful write' {
                $configPath = [System.IO.Path]::Combine($TestDrive, $Script:Cnpj, 'config')
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

                $configPath  = [System.IO.Path]::Combine($TestDrive, $cnpj2, 'config')
                $companyFile = Join-Path -Path $configPath -ChildPath "$cnpj2.json"

                $saved = Get-Content -LiteralPath $companyFile -Raw | ConvertFrom-Json

                $saved.UpdatedAt | Should -Not -BeNull
            }

            It 'Does not stamp UpdatedAt when AsUpdate is not specified' {
                Save-CompanyConfig -Company $Script:ValidCompany

                $configPath  = [System.IO.Path]::Combine($TestDrive, $Script:Cnpj, 'config')
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

                $configPath   = [System.IO.Path]::Combine($TestDrive, $Script:Cnpj, 'config')
                $companyFile  = Join-Path -Path $configPath -ChildPath "$Script:Cnpj.json"
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

        #region Write failure
        Context 'Write failure' {

            BeforeAll {

                Mock -CommandName Get-StorePath -MockWith {
                    param (
                        [Parameter()]
                        [string]$Scope,

                        [Parameter()]
                        [string]$Cnpj
                    )

                    [System.IO.Path]::Combine($TestDrive, $Cnpj, 'config')
                } -ParameterFilter {
                    $Scope -eq 'Config'
                }

                $Script:FailCnpj = '11222333000181'

                $configPath = [System.IO.Path]::Combine(
                    $TestDrive,
                    $Script:FailCnpj,
                    'config'
                )

                $targetParams = @{
                    Path      = $configPath
                    ChildPath = ('{0}.json' -f $Script:FailCnpj)
                }

                $targetPath  = Join-Path @targetParams
                $blockedTemp = '{0}.tmp' -f $targetPath

                [System.IO.Directory]::CreateDirectory($configPath)  | Out-Null

                # Create the .tmp file as read-only to force WriteAllText to fail
                # when the file already exists as Leaf.
                [System.IO.File]::WriteAllText($blockedTemp, 'placeholder')
                $fileInfo = [System.IO.FileInfo]::new($blockedTemp)
                $fileInfo.IsReadOnly = $true

                $Script:WriteFailThrown = $null

                $writeFailCompany = [PSCustomObject]@{
                    Cnpj      = $Script:FailCnpj
                    UpdatedAt = $null
                    Email     = [PSCustomObject]@{
                        Para = @()
                        Cc   = @()
                        Cco  = @()
                    }
                }

                try {
                    Save-CompanyConfig -Company $writeFailCompany -ErrorAction Stop
                } catch {
                    $Script:WriteFailThrown = $_
                }
            }

            It 'Throws CompanyConfigSaveFailed on write failure' {
                $Script:WriteFailThrown | Should -Not -BeNullOrEmpty

                $Script:WriteFailThrown.FullyQualifiedErrorId |
                    Should -BeLike 'CompanyConfigSaveFailed*'
            }

            It 'Uses WriteError category on write failure' {
                $Script:WriteFailThrown.CategoryInfo.Category |
                    Should -Be ([System.Management.Automation.ErrorCategory]::WriteError)
            }
        }
        #endregion


        #region Promotion failure
        Context 'Promotion failure' {

            BeforeAll {

                Mock -CommandName Get-StorePath -MockWith {
                    param (
                        [Parameter()]
                        [string]$Scope,

                        [Parameter()]
                        [string]$Cnpj
                    )

                    [System.IO.Path]::Combine($TestDrive, $Cnpj, 'config')
                } -ParameterFilter {
                    $Scope -eq 'Config'
                }

                $Script:PromoteCnpj = '12345678000195'

                $configPath = [System.IO.Path]::Combine(
                    $TestDrive,
                    $Script:PromoteCnpj,
                    'config'
                )

                $targetParams = @{
                    Path      = $configPath
                    ChildPath = '{0}.json' -f $Script:PromoteCnpj
                }

                $targetPath   = Join-Path @targetParams

                [System.IO.Directory]::CreateDirectory($configPath) | Out-Null
                [System.IO.Directory]::CreateDirectory($targetPath) | Out-Null

                $Script:PromoteFailThrown = $null

                $promoteFailCompany = [PSCustomObject]@{
                    Cnpj      = $Script:PromoteCnpj
                    UpdatedAt = $null
                    Email     = [PSCustomObject]@{
                        Para = @()
                        Cc   = @()
                        Cco  = @()
                    }
                }

                try {
                    Save-CompanyConfig -Company $promoteFailCompany -ErrorAction Stop
                } catch {
                    $Script:PromoteFailThrown = $_
                }
            }

            It 'Throws CompanyConfigSaveFailed on promotion failure' {
                $Script:PromoteFailThrown | Should -Not -BeNullOrEmpty

                $Script:PromoteFailThrown.FullyQualifiedErrorId |
                    Should -BeLike 'CompanyConfigSaveFailed*'
            }

            It 'Uses WriteError category on promotion failure' {
                $Script:PromoteFailThrown.CategoryInfo.Category |
                    Should -Be ([System.Management.Automation.ErrorCategory]::WriteError)
            }
        }
        #endregion
    }
}
