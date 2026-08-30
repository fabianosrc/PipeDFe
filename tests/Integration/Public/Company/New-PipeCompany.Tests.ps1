#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Integration tests for New-PipeCompany.

.DESCRIPTION
Verifies New-PipeCompany against real files written to an isolated
%LOCALAPPDATA% directory. No mocks are used.

Coverage includes:
  - Registers a company and returns a PipeDFe.Company object.
  - Returns correct field values.
  - Creates the config file at the expected path.
  - Creates OutputPath when it does not exist.
  - Accepts formatted CNPJ and normalizes it.
  - Throws DuplicateCompany when CNPJ is already registered.
  - Accepts optional XmlPathNfse and XmlPathEntrada.
  - Stores email recipients correctly.
  - WhatIf does not persist the company.
  - CNPJ isolation - each company writes to its own file.
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

Describe 'New-PipeCompany' {

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

            $Script:Cnpj    = '12345678000195'
            $Script:XmlPath = [System.IO.Path]::Combine($Script:TempRootPath, 'xml')

            New-Item -Path $Script:XmlPath -ItemType Directory -Force | Out-Null

            $Script:XmlPathNfse    = [System.IO.Path]::Combine($Script:TempRootPath, 'nfse')
            $Script:XmlPathEntrada = [System.IO.Path]::Combine($Script:TempRootPath, 'entrada')

            New-Item -Path $Script:XmlPathNfse    -ItemType Directory -Force | Out-Null
            New-Item -Path $Script:XmlPathEntrada -ItemType Directory -Force | Out-Null

            function Get-ExpectedCompanyFile {
                [CmdletBinding()]
                [OutputType([string])]
                param (
                    [Parameter(Mandatory)]
                    [string]$Cnpj
                )

                [System.IO.Path]::Combine(
                    $Script:TempRootPath, 'PipeDFe', $Cnpj, 'config', "$Cnpj.json"
                )
            }
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

        #region Happy path
        Context 'Happy path' {

            BeforeAll {

                $regParams = @{
                    Cnpj        = $Script:Cnpj
                    RazaoSocial = 'ACME COMERCIO LTDA'
                    Uf          = 'SP'
                    Ambiente    = [Ambiente]::Homologacao
                    XmlPath     = $Script:XmlPath
                }

                $Script:Result = New-PipeCompany @regParams
            }

            It 'Returns a result' {
                $Script:Result | Should -Not -BeNullOrEmpty
            }

            It 'Returns a PipeDFe.Company object' {
                $Script:Result.PSObject.TypeNames | Should -Contain 'PipeDFe.Company'
            }

            It 'Returns correct Cnpj' {
                $Script:Result.Cnpj | Should -Be $Script:Cnpj
            }

            It 'Returns correct RazaoSocial' {
                $Script:Result.RazaoSocial | Should -Be 'ACME COMERCIO LTDA'
            }

            It 'Returns correct Uf' {
                $Script:Result.Uf | Should -Be 'SP'
            }

            It 'Returns correct Ambiente' {
                $Script:Result.Ambiente | Should -Be 'Homologacao'
            }

            It 'Creates the config file at the expected path' {
                $file = Get-ExpectedCompanyFile -Cnpj $Script:Cnpj
                Test-Path -LiteralPath $file -PathType Leaf | Should -BeTrue
            }

            It 'Creates OutputPath when it does not exist' {
                Test-Path -LiteralPath $Script:Result.OutputPath -PathType Container | Should -BeTrue
            }
        }
        #endregion

        #region CNPJ normalization
        Context 'CNPJ normalization' {

            It 'Accepts formatted CNPJ and normalizes it' {
                $cnpj2 = '98765432000100'
                $xml2  = [System.IO.Path]::Combine($Script:TempRootPath, 'xml2')

                New-Item -Path $xml2 -ItemType Directory -Force | Out-Null

                $regParams = @{
                    Cnpj        = '98.765.432/0001-00'
                    RazaoSocial = 'BETA LTDA'
                    Uf          = 'RJ'
                    Ambiente    = [Ambiente]::Homologacao
                    XmlPath     = $xml2
                }

                $result = New-PipeCompany @regParams
                $result.Cnpj | Should -Be $cnpj2

                $file = Get-ExpectedCompanyFile -Cnpj $cnpj2
                Test-Path -LiteralPath $file -PathType Leaf | Should -BeTrue
            }
        }
        #endregion

        #region Duplicate detection
        Context 'Duplicate detection' {

            It 'Throws DuplicateCompany when CNPJ is already registered' {
                $regParams = @{
                    Cnpj        = $Script:Cnpj
                    RazaoSocial = 'ACME DUPLICADO'
                    Uf          = 'SP'
                    Ambiente    = [Ambiente]::Homologacao
                    XmlPath     = $Script:XmlPath
                }

                { New-PipeCompany @regParams } | Should -Throw -ErrorId 'DuplicateCompany*'
            }
        }
        #endregion

        #region Optional paths
        Context 'Optional paths' {

            It 'Stores XmlPathNfse when provided' {
                $cnpj3 = '11111111000191'
                $xml3  = [System.IO.Path]::Combine($Script:TempRootPath, 'xml3')

                New-Item -Path $xml3 -ItemType Directory -Force | Out-Null

                $regParams = @{
                    Cnpj        = $cnpj3
                    RazaoSocial = 'GAMMA LTDA'
                    Uf          = 'MG'
                    Ambiente    = [Ambiente]::Homologacao
                    XmlPath     = $xml3
                    XmlPathNfse = $Script:XmlPathNfse
                }

                $result = New-PipeCompany @regParams

                $result.XmlPathNfse | Should -Be $Script:XmlPathNfse
            }

            It 'Stores XmlPathEntrada when provided' {
                $cnpj4 = '22222222000172'
                $xml4  = [System.IO.Path]::Combine($Script:TempRootPath, 'xml4')

                New-Item -Path $xml4 -ItemType Directory -Force | Out-Null

                $regParams = @{
                    Cnpj           = $cnpj4
                    RazaoSocial    = 'DELTA LTDA'
                    Uf             = 'RS'
                    Ambiente       = [Ambiente]::Homologacao
                    XmlPath        = $xml4
                    XmlPathEntrada = $Script:XmlPathEntrada
                }

                $result = New-PipeCompany @regParams

                $result.XmlPathEntrada | Should -Be $Script:XmlPathEntrada
            }
        }
        #endregion

        #region Email recipients
        Context 'Email recipients' {

            It 'Stores email recipients correctly' {
                $cnpj5 = '33333333000187'
                $xml5  = [System.IO.Path]::Combine($Script:TempRootPath, 'xml5')

                New-Item -Path $xml5 -ItemType Directory -Force | Out-Null

                $regParams = @{
                    Cnpj        = $cnpj5
                    RazaoSocial = 'EPSILON LTDA'
                    Uf          = 'SC'
                    Ambiente    = [Ambiente]::Homologacao
                    XmlPath     = $xml5
                    EmailPara   = 'contador@escritorio.com.br'
                }

                $result = New-PipeCompany @regParams

                $result.Email.Para | Should -HaveCount 1
                $result.Email.Para[0].Email | Should -Be 'contador@escritorio.com.br'
            }
        }
        #endregion

        #region WhatIf
        Context 'WhatIf' {

            It 'Does not create the config file when WhatIf is specified' {
                $cnpj6 = '44444444000153'
                $xml6  = [System.IO.Path]::Combine($Script:TempRootPath, 'xml6')

                New-Item -Path $xml6 -ItemType Directory -Force | Out-Null

                $regParams = @{
                    Cnpj        = $cnpj6
                    RazaoSocial = 'ZETA LTDA'
                    Uf          = 'PR'
                    Ambiente    = [Ambiente]::Homologacao
                    XmlPath     = $xml6
                    WhatIf      = $true
                }

                New-PipeCompany @regParams

                $file = Get-ExpectedCompanyFile -Cnpj $cnpj6
                Test-Path -LiteralPath $file | Should -BeFalse
            }
        }
        #endregion

        #region CNPJ isolation
        Context 'CNPJ isolation' {

            It 'Each company writes to its own config file' {
                $file1 = Get-ExpectedCompanyFile -Cnpj $Script:Cnpj
                $file2 = Get-ExpectedCompanyFile -Cnpj '98765432000100'

                Test-Path -LiteralPath $file1 -PathType Leaf | Should -BeTrue
                Test-Path -LiteralPath $file2 -PathType Leaf | Should -BeTrue

                $file1 | Should -Not -Be $file2
            }
        }
        #endregion
    }
}
