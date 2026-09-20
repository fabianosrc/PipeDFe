
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for Assert-CompanyInput.

.DESCRIPTION
Covers all validation rules enforced by Assert-CompanyInput:
  - Cnpj format (14 uppercase alphanumeric characters).
  - Mathematical CNPJ validation in Producao.
  - Fictitious CNPJ accepted in Homologacao.
  - Duplicate detection via company config file.
  - Duplicate check skipped when IsUpdate is specified.
  - XmlPath must exist and be a directory.
  - XmlPathNfse must exist when provided.
  - XmlPathEntrada must exist when provided.
  - CertPath and CertPassword must be provided together.
  - CertPath must resolve to an existing file.
  - Does not throw when all inputs are valid.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSAvoidUsingConvertToSecureStringWithPlainText',
    '',
    Justification = 'Plain text passwords are acceptable in test context.'
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

Describe 'Assert-CompanyInput' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            $Script:ValidCnpj    = '12345678000195'
            $Script:ValidXmlPath = Join-Path -Path $TestDrive -ChildPath 'xmls'

            New-Item -Path $Script:ValidXmlPath -ItemType Directory -Force | Out-Null

            $Script:ValidCertPath = Join-Path -Path $TestDrive -ChildPath 'cert.pfx'

            [System.IO.File]::WriteAllText($Script:ValidCertPath, 'fake-cert')

            $certParams = @{
                String      = 'P@ssw0rd'
                AsPlainText = $true
                Force       = $true
            }

            $Script:ValidCertPassword = ConvertTo-SecureString @certParams

            Mock -CommandName Test-Cnpj -MockWith {
                $true
            }

            Mock -CommandName Get-StorePath -MockWith {
                $joinParams = @{
                    Path      = $TestDrive
                    ChildPath = [System.IO.Path]::Combine('companies', $Cnpj, 'config')
                }

                Join-Path @joinParams
            }
        }

        Context 'CNPJ format' {

            It 'rejects fewer than 14 characters' {
                $params = @{
                    Cnpj     = '1234567800019'
                    Ambiente = [Ambiente]::Homologacao
                    XmlPath  = $Script:ValidXmlPath
                }

                { Assert-CompanyInput @params } |
                    Should -Throw -ErrorId 'CnpjNotNormalized*'
            }

            It 'rejects lowercase characters' {
                $params = @{
                    Cnpj     = '1234567800019a'
                    Ambiente = [Ambiente]::Homologacao
                    XmlPath  = $Script:ValidXmlPath
                }

                { Assert-CompanyInput @params } |
                    Should -Throw -ErrorId 'CnpjNotNormalized*'
            }

            It 'rejects punctuation' {
                $params = @{
                    Cnpj     = '12.345.678/0001-95'
                    Ambiente = [Ambiente]::Homologacao
                    XmlPath  = $Script:ValidXmlPath
                }

                { Assert-CompanyInput @params } |
                    Should -Throw -ErrorId 'CnpjNotNormalized*'
            }

            It 'accepts uppercase alphanumeric CNPJ in Homologacao' {
                $params = @{
                    Cnpj     = 'AB345678000195'
                    Ambiente = [Ambiente]::Homologacao
                    XmlPath  = $Script:ValidXmlPath
                }

                { Assert-CompanyInput @params } |
                    Should -Not -Throw
            }
        }

        Context 'CNPJ validation - Producao' {

            BeforeEach {

                Mock -CommandName Test-Cnpj -MockWith {
                    $false
                }
            }

            It 'rejects mathematically invalid CNPJ' {
                $params = @{
                    Cnpj     = '11111111000111'
                    Ambiente = ([Ambiente]::Producao)
                    XmlPath  = $Script:ValidXmlPath
                }

                { Assert-CompanyInput @params } |
                    Should -Throw -ErrorId 'InvalidCnpj*'
            }

            It 'calls Test-Cnpj exactly once' {
                $params = @{
                    Cnpj     = '11111111000111'
                    Ambiente = [Ambiente]::Producao
                    XmlPath  = $Script:ValidXmlPath
                }

                try {
                    Assert-CompanyInput @params
                } catch {
                    $null = $_
                }

                Should -Invoke Test-Cnpj -Exactly -Times 1
            }
        }

        Context 'CNPJ validation - Homologacao' {

            BeforeEach {

                Mock -CommandName Test-Cnpj -MockWith {
                    $false
                }
            }

            It 'accepts mathematically invalid CNPJ' {
                $params = @{
                    Cnpj     = '11111111000111'
                    Ambiente = [Ambiente]::Homologacao
                    XmlPath  = $Script:ValidXmlPath
                }

                { Assert-CompanyInput @params } | Should -Not -Throw
            }

            It 'does not call Test-Cnpj' {
                $params = @{
                    Cnpj     = '11111111000111'
                    Ambiente = [Ambiente]::Homologacao
                    XmlPath  = $Script:ValidXmlPath
                }

                Assert-CompanyInput @params

                Should -Invoke Test-Cnpj -Exactly -Times 0
            }
        }

        Context 'Duplicate detection' {

            BeforeEach {

                Mock -CommandName Test-Cnpj -MockWith {
                    $true
                }
            }

            It 'rejects an existing company' {
                $joinParams = @{
                    Path      = $TestDrive
                    ChildPath = [System.IO.Path]::Combine('companies', $Script:ValidCnpj, 'config')
                }

                $configPath  = Join-Path @joinParams
                $companyFile = Join-Path -Path $configPath -ChildPath "$Script:ValidCnpj.json"

                New-Item -Path $configPath -ItemType Directory -Force | Out-Null

                [System.IO.File]::WriteAllText($companyFile, '{}')

                $params = @{
                    Cnpj     = $Script:ValidCnpj
                    Ambiente = [Ambiente]::Producao
                    XmlPath  = $Script:ValidXmlPath
                }

                { Assert-CompanyInput @params } |
                    Should -Throw -ErrorId 'DuplicateCompany*'
            }

            It 'skips duplicate detection during update' {
                $joinParams = @{
                    Path      = $TestDrive
                    ChildPath = [System.IO.Path]::Combine('companies', $Script:ValidCnpj, 'config')
                }

                $configPath  = Join-Path @joinParams
                $companyFile = Join-Path -Path $configPath -ChildPath 'company.json'

                New-Item -Path $configPath -ItemType Directory -Force | Out-Null

                [System.IO.File]::WriteAllText($companyFile, '{}')

                $params = @{
                    Cnpj     = $Script:ValidCnpj
                    Ambiente = [Ambiente]::Producao
                    XmlPath  = $Script:ValidXmlPath
                    IsUpdate = $true
                }

                { Assert-CompanyInput @params } | Should -Not -Throw

                Should -Invoke Get-StorePath -Exactly -Times 0
            }
        }

        Context 'XmlPath validation' {

            It 'rejects a nonexistent directory' {
                $params = @{
                    Cnpj     = $Script:ValidCnpj
                    Ambiente = [Ambiente]::Producao
                    XmlPath  = Join-Path -Path $TestDrive -ChildPath 'missing'
                }

                { Assert-CompanyInput @params } |
                    Should -Throw -ErrorId 'XmlPathNotFound*'
            }

            It 'rejects a file' {
                $file = Join-Path -Path $TestDrive -ChildPath 'not-a-directory.txt'

                [System.IO.File]::WriteAllText($file, [string]::Empty)

                $params = @{
                    Cnpj     = $Script:ValidCnpj
                    Ambiente = [Ambiente]::Producao
                    XmlPath  = $file
                }

                { Assert-CompanyInput @params } |
                    Should -Throw -ErrorId 'XmlPathNotFound*'
            }
        }

        Context 'XmlPathNfse validation' {

            It 'allows an omitted path' {
                $params = @{
                    Cnpj     = $Script:ValidCnpj
                    Ambiente = [Ambiente]::Producao
                    XmlPath  = $Script:ValidXmlPath
                }

                { Assert-CompanyInput @params } | Should -Not -Throw
            }

            It 'accepts an existing directory' {
                $path = Join-Path -Path $TestDrive -ChildPath 'nfse'

                New-Item -Path $path -ItemType Directory -Force | Out-Null

                $params = @{
                    Cnpj        = $Script:ValidCnpj
                    Ambiente    = [Ambiente]::Producao
                    XmlPath     = $Script:ValidXmlPath
                    XmlPathNfse = $path
                }

                { Assert-CompanyInput @params } | Should -Not -Throw
            }

            It 'rejects a nonexistent directory' {
                $params = @{
                    Cnpj        = $Script:ValidCnpj
                    Ambiente    = [Ambiente]::Producao
                    XmlPath     = $Script:ValidXmlPath
                    XmlPathNfse = Join-Path -Path $TestDrive -ChildPath 'missing-nfse'
                }

                { Assert-CompanyInput @params } |
                    Should -Throw -ErrorId 'XmlPathNfseNotFound*'
            }
        }

        Context 'XmlPathEntrada validation' {

            It 'allows an omitted path' {
                $params = @{
                    Cnpj     = $Script:ValidCnpj
                    Ambiente = [Ambiente]::Producao
                    XmlPath  = $Script:ValidXmlPath
                }

                { Assert-CompanyInput @params } | Should -Not -Throw
            }

            It 'accepts an existing directory' {
                $path = Join-Path -Path $TestDrive -ChildPath 'entrada'

                New-Item -Path $path -ItemType Directory -Force | Out-Null

                $params = @{
                    Cnpj           = $Script:ValidCnpj
                    Ambiente       = [Ambiente]::Producao
                    XmlPath        = $Script:ValidXmlPath
                    XmlPathEntrada = $path
                }

                { Assert-CompanyInput @params } | Should -Not -Throw
            }

            It 'rejects a nonexistent directory' {
                $params = @{
                    Cnpj           = $Script:ValidCnpj
                    Ambiente       = [Ambiente]::Producao
                    XmlPath        = $Script:ValidXmlPath
                    XmlPathEntrada = Join-Path -Path $TestDrive -ChildPath 'missing-entrada'
                }

                { Assert-CompanyInput @params } |
                    Should -Throw -ErrorId 'XmlPathEntradaNotFound*'
            }
        }

        Context 'Certificate validation' {

            It 'rejects CertPath without password' {
                $params = @{
                    Cnpj     = $Script:ValidCnpj
                    Ambiente = [Ambiente]::Producao
                    XmlPath  = $Script:ValidXmlPath
                    CertPath = $Script:ValidCertPath
                }

                { Assert-CompanyInput @params } |
                    Should -Throw -ErrorId 'MissingCertPassword*'
            }

            It 'rejects password without CertPath' {
                $params = @{
                    Cnpj         = $Script:ValidCnpj
                    Ambiente     = [Ambiente]::Producao
                    XmlPath      = $Script:ValidXmlPath
                    CertPassword = $Script:ValidCertPassword
                }

                { Assert-CompanyInput @params } |
                    Should -Throw -ErrorId 'MissingCertPath*'
            }

            It 'rejects a nonexistent certificate' {
                $params = @{
                    Cnpj         = $Script:ValidCnpj
                    Ambiente     = [Ambiente]::Producao
                    XmlPath      = $Script:ValidXmlPath
                    CertPath     = Join-Path -Path $TestDrive -ChildPath 'missing.pfx'
                    CertPassword = $Script:ValidCertPassword
                }

                { Assert-CompanyInput @params } |
                    Should -Throw -ErrorId 'CertNotFound*'
            }

            It 'accepts no certificate' {
                $params = @{
                    Cnpj     = $Script:ValidCnpj
                    Ambiente = [Ambiente]::Producao
                    XmlPath  = $Script:ValidXmlPath
                }

                { Assert-CompanyInput @params } | Should -Not -Throw
            }

            It 'accepts a valid certificate pair' {
                $params = @{
                    Cnpj         = $Script:ValidCnpj
                    Ambiente     = [Ambiente]::Producao
                    XmlPath      = $Script:ValidXmlPath
                    CertPath     = $Script:ValidCertPath
                    CertPassword = $Script:ValidCertPassword
                }

                { Assert-CompanyInput @params } | Should -Not -Throw
            }
        }

        Context 'Happy path' {

            It 'produces no output' {
                $params = @{
                    Cnpj     = $Script:ValidCnpj
                    Ambiente = [Ambiente]::Producao
                    XmlPath  = $Script:ValidXmlPath
                }

                $result = Assert-CompanyInput @params
                $result | Should -BeNullOrEmpty
            }
        }
    }
}
