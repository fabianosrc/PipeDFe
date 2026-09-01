#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Integration tests for Set-PipeCompany.

.DESCRIPTION
Verifies Set-PipeCompany against real files written to an isolated
%LOCALAPPDATA% directory. No mocks are used.

Coverage includes:
  - Returns a PipeDFe.Company object.
  - Updates only the provided field.
  - Preserves unchanged fields.
  - Preserves CreatedAt after update.
  - Stamps UpdatedAt after update.
  - Deactivates a company via IsActive = false.
  - Clears XmlPathNfse when empty string is provided.
  - Clears XmlPathEntrada when empty string is provided.
  - Replaces email recipients.
  - WhatIf does not persist changes.
  - Throws CompanyNotFound when CNPJ is not registered.
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

Describe 'Set-PipeCompany' -Tag 'Integration' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            $testID = [guid]::NewGuid().ToString('N')

            $Script:OriginalLocalAppData = $env:LOCALAPPDATA

            $Script:TempRootPath = [System.IO.Path]::Combine(
                [System.IO.Path]::GetTempPath(),
                ('PipeDFe.Tests-{0}' -f $testID)
            )

            $newItemParams = @{
                Path         = $Script:TempRootPath
                ItemType     = 'Directory'
                Force        = $true
                ErrorAction  = 'Stop'
            }

            New-Item @newItemParams | Out-Null

            $env:LOCALAPPDATA = $Script:TempRootPath

            $Script:Cnpj    = '12345678000195'
            $Script:XmlPath = [System.IO.Path]::Combine($Script:TempRootPath, 'xml')

            New-Item -Path $Script:XmlPath -ItemType Directory -Force | Out-Null

            $Script:XmlPathNfse    = [System.IO.Path]::Combine($Script:TempRootPath, 'nfse')
            $Script:XmlPathEntrada = [System.IO.Path]::Combine($Script:TempRootPath, 'entrada')

            New-Item -Path $Script:XmlPathNfse    -ItemType Directory -Force | Out-Null
            New-Item -Path $Script:XmlPathEntrada -ItemType Directory -Force | Out-Null

            $regParams = @{
                Cnpj        = $Script:Cnpj
                RazaoSocial = 'ACME COMERCIO LTDA'
                NomeFantasia = 'ACME'
                Uf          = 'SP'
                Ambiente    = [Ambiente]::Homologacao
                XmlPath     = $Script:XmlPath
                EmailPara   = 'contador@escritorio.com.br'
            }

            New-PipeCompany @regParams | Out-Null

            $Script:CreatedAt = (Get-PipeCompany -Cnpj $Script:Cnpj).CreatedAt
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

        #region Return contract
        Context 'Return contract' {

            It 'Returns a PipeDFe.Company object' {
                $result = Set-PipeCompany -Cnpj $Script:Cnpj -NomeFantasia 'ACME NOVO'
                $result.PSObject.TypeNames | Should -Contain 'PipeDFe.Company'
            }
        }
        #endregion

        #region Field updates
        Context 'Field updates' {

            It 'Updates NomeFantasia' {
                $result = Set-PipeCompany -Cnpj $Script:Cnpj -NomeFantasia 'ACME ATUALIZADO'
                $result.NomeFantasia | Should -Be 'ACME ATUALIZADO'
            }

            It 'Updates Uf' {
                $result = Set-PipeCompany -Cnpj $Script:Cnpj -Uf 'RJ'
                $result.Uf | Should -Be 'RJ'
            }

            It 'Preserves RazaoSocial when not provided' {
                Set-PipeCompany -Cnpj $Script:Cnpj -NomeFantasia 'QUALQUER' | Out-Null
                $result = Get-PipeCompany -Cnpj $Script:Cnpj
                $result.RazaoSocial | Should -Be 'ACME COMERCIO LTDA'
            }

            It 'Deactivates company when IsActive is false' {
                Set-PipeCompany -Cnpj $Script:Cnpj -IsActive $false | Out-Null
                $result = Get-PipeCompany -Cnpj $Script:Cnpj
                $result.IsActive | Should -BeFalse

                Set-PipeCompany -Cnpj $Script:Cnpj -IsActive $true | Out-Null
            }
        }
        #endregion

        #region Optional XML paths
        Context 'Optional XML paths' {

            It 'Sets XmlPathNfse when provided' {
                $result = Set-PipeCompany -Cnpj $Script:Cnpj -XmlPathNfse $Script:XmlPathNfse
                $result.XmlPathNfse | Should -Be $Script:XmlPathNfse
            }

            It 'Clears XmlPathNfse when empty string is provided' {
                Set-PipeCompany -Cnpj $Script:Cnpj -XmlPathNfse $Script:XmlPathNfse | Out-Null
                $result = Set-PipeCompany -Cnpj $Script:Cnpj -XmlPathNfse ''
                $result.XmlPathNfse | Should -BeNull
            }

            It 'Sets XmlPathEntrada when provided' {
                $result = Set-PipeCompany -Cnpj $Script:Cnpj -XmlPathEntrada $Script:XmlPathEntrada
                $result.XmlPathEntrada | Should -Be $Script:XmlPathEntrada
            }

            It 'Clears XmlPathEntrada when empty string is provided' {
                Set-PipeCompany -Cnpj $Script:Cnpj -XmlPathEntrada $Script:XmlPathEntrada | Out-Null
                $result = Set-PipeCompany -Cnpj $Script:Cnpj -XmlPathEntrada ''
                $result.XmlPathEntrada | Should -BeNull
            }
        }
        #endregion

        #region Timestamp preservation
        Context 'Timestamp preservation' {

            It 'Preserves CreatedAt after update' {
                $result = Set-PipeCompany -Cnpj $Script:Cnpj -NomeFantasia 'QUALQUER'
                $result.CreatedAt | Should -Be $Script:CreatedAt
            }

            It 'Stamps UpdatedAt after update' {
                $result = Set-PipeCompany -Cnpj $Script:Cnpj -NomeFantasia 'QUALQUER'
                $result.UpdatedAt | Should -Not -BeNull
            }
        }
        #endregion

        #region Email recipients
        Context 'Email recipients' {

            It 'Replaces email recipients when provided' {
                $result = Set-PipeCompany -Cnpj $Script:Cnpj -EmailPara 'novo@example.com'
                $result.Email.Para | Should -HaveCount 1
                $result.Email.Para[0].Email | Should -Be 'novo@example.com'
            }

            It 'Preserves existing email recipients when not provided' {
                Set-PipeCompany -Cnpj $Script:Cnpj -EmailPara 'contador@escritorio.com.br' | Out-Null
                $result = Set-PipeCompany -Cnpj $Script:Cnpj -NomeFantasia 'QUALQUER'
                $result.Email.Para | Should -HaveCount 1
            }
        }
        #endregion

        #region WhatIf
        Context 'WhatIf' {

            It 'Does not persist changes when WhatIf is specified' {
                $before = Get-PipeCompany -Cnpj $Script:Cnpj

                Set-PipeCompany -Cnpj $Script:Cnpj -NomeFantasia 'NAO DEVE SALVAR' -WhatIf

                $after = Get-PipeCompany -Cnpj $Script:Cnpj
                $after.NomeFantasia | Should -Not -Be 'NAO DEVE SALVAR'
                $after.NomeFantasia | Should -Be $before.NomeFantasia
            }
        }
        #endregion

        #region Error cases
        Context 'Error cases' {

            It 'Throws CompanyNotFound when CNPJ is not registered' {
                { Set-PipeCompany -Cnpj '99999999000191' } |
                    Should -Throw -ErrorId 'CompanyNotFound*'
            }
        }
        #endregion
    }
}
