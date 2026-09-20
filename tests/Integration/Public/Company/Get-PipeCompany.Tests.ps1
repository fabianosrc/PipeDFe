#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Integration tests for Get-PipeCompany.

.DESCRIPTION
Verifies Get-PipeCompany against real files written to an isolated
%LOCALAPPDATA% directory. No mocks are used.

Coverage includes:
  - Returns a single company when Cnpj is provided.
  - Accepts formatted CNPJ and normalizes it.
  - Throws CompanyNotFound when CNPJ is not registered.
  - Returns all companies when Cnpj is omitted.
  - Filters by IsActive when provided.
  - Returns PipeDFe.Company type name.
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

Describe 'Get-PipeCompany' {

    InModuleScope PipeDFe {

        BeforeAll {

            $testID = [guid]::NewGuid().ToString('N')

            $Script:OriginalLocalAppData = $env:LOCALAPPDATA

            $Script:TempRootPath = [System.IO.Path]::Combine(
                [System.IO.Path]::GetTempPath(),
                ('PipeDFe.Tests-{0}' -f $testID)
            )

            $newItemParams = @{
                Path        = $Script:TempRootPath
                ItemType    = 'Directory'
                Force       = $true
                ErrorAction = 'Stop'
            }

            New-Item @newItemParams | Out-Null

            $env:LOCALAPPDATA = $Script:TempRootPath

            $Script:Cnpj1 = '12345678000195'
            $Script:Cnpj2 = '98765432000100'

            $Script:XmlPath = [System.IO.Path]::Combine($Script:TempRootPath, 'xml')
            New-Item -Path $Script:XmlPath -ItemType Directory -Force | Out-Null

            $regParams1 = @{
                Cnpj        = $Script:Cnpj1
                RazaoSocial = 'ACME COMERCIO LTDA'
                Uf          = 'SP'
                Ambiente    = [Ambiente]::Homologacao
                XmlPath     = $Script:XmlPath
            }

            $regParams2 = @{
                Cnpj        = $Script:Cnpj2
                RazaoSocial = 'BETA INDUSTRIA LTDA'
                Uf          = 'RJ'
                Ambiente    = [Ambiente]::Homologacao
                XmlPath     = $Script:XmlPath
            }

            New-PipeCompany @regParams1 | Out-Null
            New-PipeCompany @regParams2 | Out-Null

            $company2 = Get-CompanyConfig -Cnpj $Script:Cnpj2
            $company2.IsActive = $false
            Save-CompanyConfig -Company $company2 -AsUpdate
        }

        AfterAll {

            $env:LOCALAPPDATA = $Script:OriginalLocalAppData
            $removeItemParams = @{
                LiteralPath = $Script:TempRootPath
                Recurse     = $true
                Force       = $true
                ErrorAction = 'SilentlyContinue'
            }

            Remove-Item @removeItemParams
            Remove-Module -Name PipeDFe -Force -ErrorAction SilentlyContinue
        }

        #region Single company retrieval
        Context 'Single company retrieval' {

            It 'Returns the matching company' {
                $result = Get-PipeCompany -Cnpj $Script:Cnpj1
                $result.Cnpj | Should -Be $Script:Cnpj1
            }

            It 'Returns a PipeDFe.Company object' {
                $result = Get-PipeCompany -Cnpj $Script:Cnpj1
                $result.PSObject.TypeNames | Should -Contain 'PipeDFe.Company'
            }

            It 'Accepts formatted CNPJ and normalizes it' {
                $result = Get-PipeCompany -Cnpj '12.345.678/0001-95'
                $result.Cnpj | Should -Be $Script:Cnpj1
            }

            It 'Throws CompanyNotFound when CNPJ is not registered' {
                { Get-PipeCompany -Cnpj '11111111000191' } |
                    Should -Throw -ErrorId 'CompanyNotFound*'
            }
        }
        #endregion

        #region Bulk retrieval
        Context 'Bulk retrieval' {

            It 'Returns all registered companies' {
                $results = @(Get-PipeCompany)
                $results | Should -HaveCount 2
            }

            It 'Returns PipeDFe.Company objects for all companies' {
                $results = @(Get-PipeCompany)
                $results | ForEach-Object {
                    $_.PSObject.TypeNames | Should -Contain 'PipeDFe.Company'
                }
            }
        }
        #endregion

        #region IsActive filter
        Context 'IsActive filter' {

            It 'Returns only active companies when IsActive is true' {
                $results = @(Get-PipeCompany -IsActive $true)
                $results | Should -HaveCount 1
                $results[0].Cnpj | Should -Be $Script:Cnpj1
            }

            It 'Returns only inactive companies when IsActive is false' {
                $results = @(Get-PipeCompany -IsActive $false)
                $results | Should -HaveCount 1
                $results[0].Cnpj | Should -Be $Script:Cnpj2
            }

            It 'Returns empty when no company matches the filter' {
                $results = @(Get-PipeCompany -Cnpj $Script:Cnpj1 -IsActive $false)
                $results | Should -HaveCount 0
            }
        }
        #endregion
    }
}
