#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Integration tests for Remove-PipeCompany.

.DESCRIPTION
Verifies Remove-PipeCompany against real files written to an isolated
%LOCALAPPDATA% directory. No mocks are used except where noted.

Coverage includes:
  - Removes the configuration file for an inactive company.
  - Does not remove the data directory when -DeleteFiles is absent.
  - Removes the data directory when -DeleteFiles is specified.
  - Silently ignores a missing data directory when -DeleteFiles is specified.
  - Accepts a formatted CNPJ and normalizes it before removal.
  - Throws ActiveCompanyRemoval when the company is active.
  - Throws CompanyNotFound when the CNPJ does not exist.
  - Does not remove anything when -WhatIf is specified.
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

Describe 'Remove-PipeCompany' -Tag 'Integration' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            $testID = [guid]::NewGuid().ToString('N')

            $Script:OriginalLocalAppData = $env:LOCALAPPDATA

            $Script:TempRoot = [System.IO.Path]::Combine(
                [System.IO.Path]::GetTempPath(),
                ('PipeDFe.Tests-{0}' -f $testID)
            )

            New-Item -Path $Script:TempRoot -ItemType Directory -Force | Out-Null

            $env:LOCALAPPDATA = $Script:TempRoot

            $Script:Cnpj          = '12345678000195'
            $Script:CnpjFormatted = '12.345.678/0001-95'

            function New-InactiveCompany {
                [CmdletBinding()]
                [OutputType([void])]
                param (
                    [Parameter(Mandatory)]
                    [string]$Cnpj
                )

                $company = [PSCustomObject]@{
                    SchemaVersion  = 1
                    Cnpj           = $Cnpj
                    Ie             = [string]::Empty
                    RazaoSocial    = 'EMPRESA TESTE LTDA'
                    NomeFantasia   = 'EMPRESA TESTE'
                    Uf             = 'SP'
                    Ambiente       = [Ambiente]::Homologacao
                    IsActive       = $false
                    XmlPath        = [string]::Empty
                    XmlPathNfse    = [string]::Empty
                    XmlPathEntrada = [string]::Empty
                    OutputPath     = [string]::Empty
                    Certificado    = [PSCustomObject]@{
                        Path              = [string]::Empty
                        EncryptedPassword = [string]::Empty
                    }
                    Email          = [PSCustomObject]@{
                        Para = @()
                        Cc   = @()
                        Cco  = @()
                    }
                    Contato        = [PSCustomObject]@{
                        Email    = [string]::Empty
                        Telefone = [string]::Empty
                    }
                    Smtp           = $null
                    CreatedAt      = (Get-Date).ToUniversalTime().ToString('o')
                    UpdatedAt      = $null
                }

                Save-CompanyConfig -Company $company
            }

            function New-ActiveCompany {
                [CmdletBinding()]
                [OutputType([void])]
                param (
                    [Parameter(Mandatory)]
                    [string]$Cnpj
                )

                $company = [PSCustomObject]@{
                    SchemaVersion  = 1
                    Cnpj           = $Cnpj
                    Ie             = [string]::Empty
                    RazaoSocial    = 'EMPRESA ATIVA LTDA'
                    NomeFantasia   = 'EMPRESA ATIVA'
                    Uf             = 'SP'
                    Ambiente       = [Ambiente]::Homologacao
                    IsActive       = $true
                    XmlPath        = [string]::Empty
                    XmlPathNfse    = [string]::Empty
                    XmlPathEntrada = [string]::Empty
                    OutputPath     = [string]::Empty
                    Certificado    = [PSCustomObject]@{
                        Path              = [string]::Empty
                        EncryptedPassword = [string]::Empty
                    }
                    Email          = [PSCustomObject]@{
                        Para = @()
                        Cc   = @()
                        Cco  = @()
                    }
                    Contato        = [PSCustomObject]@{
                        Email    = [string]::Empty
                        Telefone = [string]::Empty
                    }
                    Smtp           = $null
                    CreatedAt      = (Get-Date).ToUniversalTime().ToString('o')
                    UpdatedAt      = $null
                }

                Save-CompanyConfig -Company $company
            }

            function Get-CompanyConfigFile {
                [CmdletBinding()]
                [OutputType([string])]
                param (
                    [Parameter(Mandatory)]
                    [string]$Cnpj
                )

                $configRoot = Get-StorePath -Scope 'Config' -Cnpj $Cnpj

                return [System.IO.Path]::Combine($configRoot, "$Cnpj.json")
            }

            function Get-CompanyDataDir {
                [CmdletBinding()]
                [OutputType([string])]
                param (
                    [Parameter(Mandatory)]
                    [string]$Cnpj
                )

                $root = Get-StorePath -Scope 'Root'

                return [System.IO.Path]::Combine($root, $Cnpj)
            }
        }

        AfterAll {

            $env:LOCALAPPDATA = $Script:OriginalLocalAppData
            $removeItemParams = @{
                LiteralPath = $Script:TempRoot
                Recurse     = $true
                Force       = $true
                ErrorAction = 'SilentlyContinue'
            }

            Remove-Item @removeItemParams

            Remove-Module -Name PipeDFe -Force -ErrorAction SilentlyContinue
        }

        #region Configuration file removal
        Context 'Configuration file removal' {

            BeforeAll {

                New-InactiveCompany -Cnpj $Script:Cnpj

                $Script:ConfigFile = Get-CompanyConfigFile -Cnpj $Script:Cnpj

                Remove-PipeCompany -Cnpj $Script:Cnpj -Confirm:$false
            }

            It 'Removes the configuration file' {
                Test-Path -LiteralPath $Script:ConfigFile | Should -BeFalse
            }
        }
        #endregion

        #region Data directory not removed without -DeleteFiles
        Context 'Data directory not removed without -DeleteFiles' {

            BeforeAll {

                New-InactiveCompany -Cnpj $Script:Cnpj

                $Script:DataDir = Get-CompanyDataDir -Cnpj $Script:Cnpj

                New-Item -Path $Script:DataDir -ItemType Directory -Force | Out-Null

                Remove-PipeCompany -Cnpj $Script:Cnpj -Confirm:$false
            }

            AfterAll {

                $removeItemParams = @{
                    LiteralPath = $Script:DataDir
                    Recurse     = $true
                    Force       = $true
                    ErrorAction = 'SilentlyContinue'
                }

                Remove-Item @removeItemParams
            }

            It 'Leaves the data directory intact' {
                Test-Path -LiteralPath $Script:DataDir | Should -BeTrue
            }
        }
        #endregion

        #region Data directory removal with -DeleteFiles
        Context 'Data directory removal with -DeleteFiles' {

            BeforeAll {

                New-InactiveCompany -Cnpj $Script:Cnpj

                $Script:DataDir    = Get-CompanyDataDir -Cnpj $Script:Cnpj
                $Script:ConfigFile = Get-CompanyConfigFile -Cnpj $Script:Cnpj

                New-Item -Path $Script:DataDir -ItemType Directory -Force | Out-Null

                $markerFile = [System.IO.Path]::Combine($Script:DataDir, 'index.db')
                Set-Content -LiteralPath $markerFile -Value 'marker'

                Remove-PipeCompany -Cnpj $Script:Cnpj -DeleteFiles -Confirm:$false
            }

            It 'Removes the configuration file' {
                Test-Path -LiteralPath $Script:ConfigFile | Should -BeFalse
            }

            It 'Removes the data directory' {
                Test-Path -LiteralPath $Script:DataDir | Should -BeFalse
            }
        }
        #endregion

        #region Missing data directory is silently ignored
        Context 'Missing data directory is silently ignored' {

            BeforeAll {

                New-InactiveCompany -Cnpj $Script:Cnpj

                $Script:DataDir = Get-CompanyDataDir -Cnpj $Script:Cnpj

                # Deliberately do not create the data directory.

                $Script:Exception = $null

                try {
                    Remove-PipeCompany -Cnpj $Script:Cnpj -DeleteFiles -Confirm:$false
                } catch {
                    $Script:Exception = $_
                }
            }

            It 'Does not throw when the data directory is absent' {
                $Script:Exception | Should -BeNullOrEmpty
            }
        }
        #endregion

        #region Formatted CNPJ normalization
        Context 'Formatted CNPJ normalization' {

            BeforeAll {

                New-InactiveCompany -Cnpj $Script:Cnpj

                $Script:ConfigFile = Get-CompanyConfigFile -Cnpj $Script:Cnpj

                $Script:Exception = $null

                try {
                    Remove-PipeCompany -Cnpj $Script:CnpjFormatted -Confirm:$false
                } catch {
                    $Script:Exception = $_
                }
            }

            It 'Does not throw when given a formatted CNPJ' {
                $Script:Exception | Should -BeNullOrEmpty
            }

            It 'Removes the configuration file for the normalized CNPJ' {
                Test-Path -LiteralPath $Script:ConfigFile | Should -BeFalse
            }
        }
        #endregion

        #region Active company protection
        Context 'Active company protection' {

            BeforeAll {

                New-ActiveCompany -Cnpj $Script:Cnpj

                $Script:ConfigFile = Get-CompanyConfigFile -Cnpj $Script:Cnpj

                $Script:Exception = $null

                try {
                    Remove-PipeCompany -Cnpj $Script:Cnpj -Confirm:$false
                } catch {
                    $Script:Exception = $_
                }
            }

            AfterAll {

                $removeItemParams = @{
                    LiteralPath = $Script:ConfigFile
                    Force       = $true
                    ErrorAction = 'SilentlyContinue'
                }

                Remove-Item @removeItemParams
            }

            It 'Throws when the company is active' {
                $Script:Exception | Should -Not -BeNullOrEmpty
            }

            It 'Uses the ActiveCompanyRemoval error id' {
                $Script:Exception.FullyQualifiedErrorId |
                    Should -BeLike 'ActiveCompanyRemoval*'
            }

            It 'Leaves the configuration file intact' {
                Test-Path -LiteralPath $Script:ConfigFile | Should -BeTrue
            }
        }
        #endregion

        #region Company not found
        Context 'Company not found' {

            BeforeAll {

                $Script:Exception = $null

                try {
                    Remove-PipeCompany -Cnpj $Script:Cnpj -Confirm:$false
                } catch {
                    $Script:Exception = $_
                }
            }

            It 'Throws when the CNPJ does not exist' {
                $Script:Exception | Should -Not -BeNullOrEmpty
            }

            It 'Uses the CompanyNotFound error id' {
                $Script:Exception.FullyQualifiedErrorId |
                    Should -BeLike 'CompanyNotFound*'
            }
        }
        #endregion

        #region WhatIf
        Context 'WhatIf' {

            BeforeAll {

                New-InactiveCompany -Cnpj $Script:Cnpj

                $Script:ConfigFile = Get-CompanyConfigFile -Cnpj $Script:Cnpj

                Remove-PipeCompany -Cnpj $Script:Cnpj -DeleteFiles -WhatIf -Confirm:$false
            }

            AfterAll {

                $removeItemParams = @{
                    LiteralPath = $Script:ConfigFile
                    Force       = $true
                    ErrorAction = 'SilentlyContinue'
                }

                Remove-Item @removeItemParams
            }

            It 'Leaves the configuration file intact when WhatIf is specified' {
                Test-Path -LiteralPath $Script:ConfigFile | Should -BeTrue
            }
        }
        #endregion
    }
}
