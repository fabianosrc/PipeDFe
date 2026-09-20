#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for ConvertTo-CompanyObject.

.DESCRIPTION
Covers the canonical company object shape produced by ConvertTo-CompanyObject:
  - All mandatory parameters are declared.
  - Output type is PSCustomObject.
  - All documented properties are present and in the correct order.
  - RazaoSocial is normalized to uppercase.
  - Ambiente is stored as string.
  - Certificado block is always present; null when no cert is provided.
  - Certificado block contains Path and EncryptedPassword when cert is provided.
  - XmlPathNfse is null when absent.
  - XmlPathEntrada is null when absent.
  - XmlPathNfse and XmlPathEntrada are stored when provided.
  - Email arrays default to empty collections.
  - CreatedAt is a valid UTC ISO 8601 timestamp.
  - UpdatedAt is null on creation.
  - SchemaVersion matches $Script:JsonSchemaVersion.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSAvoidUsingConvertToSecureStringWithPlainText',
    '',
    Justification = 'Plain text passwords are acceptable in test context.'
)]

param ()

# InModuleScope needs to resolve the PipeDFe module during the Discovery phase,
# because that is when Context/It are executed to register the test tree.
# If the module isn't loaded at that point, InModuleScope fails before any
# BeforeAll or BeforeEach can run.
BeforeDiscovery {
    $moduleRoot = (Get-Item $PSScriptRoot).Parent.Parent.Parent.Parent.FullName

    $moduleName = Join-Path -Path $moduleRoot -ChildPath 'PipeDFe.psd1'

    Import-Module -Name $moduleName -Force -Global -ErrorAction Stop
}

Describe 'ConvertTo-CompanyObject' {

    InModuleScope PipeDFe {

        BeforeAll {

            $Script:Cnpj        = '12345678000195'
            $Script:RazaoSocial = 'acme comercio ltda'
            $Script:Uf          = 'SP'
            $Script:XmlPath     = 'C:\ERP\XML'
            $Script:OutputPath  = 'C:\Out'

            Mock -CommandName ConvertTo-SafeString -MockWith {
                param ($InputObject)
                $InputObject.ToUpper()
            }

            $objParams = @{
                Cnpj        = $Script:Cnpj
                RazaoSocial = $Script:RazaoSocial
                Uf          = $Script:Uf
                Ambiente    = ([Ambiente]::Producao)
                XmlPath     = $Script:XmlPath
                OutputPath  = $Script:OutputPath
            }

            $Script:Result = ConvertTo-CompanyObject @objParams

        }

        #region Parameter contract
        Context 'Parameter contract' {

            It 'Declares Cnpj as mandatory' {
                $command = Get-Command -Name ConvertTo-CompanyObject

                $mandatory = $command.Parameters['Cnpj'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.Mandatory
                    }

                $mandatory | Should -Not -BeNullOrEmpty
            }

            It 'Declares RazaoSocial as mandatory' {
                $command = Get-Command -Name ConvertTo-CompanyObject

                $mandatory = $command.Parameters['RazaoSocial'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.Mandatory
                    }

                $mandatory | Should -Not -BeNullOrEmpty
            }

            It 'Declares Uf as mandatory' {
                $command = Get-Command -Name ConvertTo-CompanyObject

                $mandatory = $command.Parameters['Uf'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.Mandatory
                    }

                $mandatory | Should -Not -BeNullOrEmpty
            }

            It 'Declares Ambiente as mandatory' {
                $command = Get-Command -Name ConvertTo-CompanyObject

                $mandatory = $command.Parameters['Ambiente'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.Mandatory
                    }

                $mandatory | Should -Not -BeNullOrEmpty
            }

            It 'Declares XmlPath as mandatory' {
                $command = Get-Command -Name ConvertTo-CompanyObject

                $mandatory = $command.Parameters['XmlPath'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.Mandatory
                    }

                $mandatory | Should -Not -BeNullOrEmpty
            }

            It 'Declares OutputPath as mandatory' {
                $command = Get-Command -Name ConvertTo-CompanyObject

                $mandatory = $command.Parameters['OutputPath'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.Mandatory
                    }

                $mandatory | Should -Not -BeNullOrEmpty
            }
        }
        #endregion

        #region Output type and shape
        Context 'Output type and shape' {

            It 'Returns a PSCustomObject' {
                $Script:Result |
                    Should -BeOfType [System.Management.Automation.PSCustomObject]
            }

            It 'Exposes exactly the documented properties in order' {
                $expected = @(
                    'SchemaVersion', 'Cnpj', 'Ie', 'RazaoSocial', 'NomeFantasia',
                    'Uf','Ambiente', 'IsActive', 'XmlPath', 'XmlPathNfse',
                    'XmlPathEntrada', 'OutputPath', 'Certificado', 'Email',
                    'Contato', 'Smtp', 'CreatedAt', 'UpdatedAt'
                )

                $actual = @($Script:Result.PSObject.Properties.Name)
                $actual | Should -Be $expected
            }
        }
        #endregion

        #region Field values
        Context 'Field values' {

            It 'Stores Cnpj as-is' {
                $Script:Result.Cnpj | Should -Be $Script:Cnpj
            }

            It 'Normalizes RazaoSocial to uppercase' {
                $Script:Result.RazaoSocial | Should -Be 'ACME COMERCIO LTDA'
            }

            It 'Stores Ambiente as string' {
                $Script:Result.Ambiente | Should -Be 'Producao'
                $Script:Result.Ambiente | Should -BeOfType [string]
            }

            It 'Sets IsActive to true' {
                $Script:Result.IsActive | Should -BeTrue
            }

            It 'Stores XmlPath as-is' {
                $Script:Result.XmlPath | Should -Be $Script:XmlPath
            }

            It 'Stores OutputPath as-is' {
                $Script:Result.OutputPath | Should -Be $Script:OutputPath
            }

            It 'Sets UpdatedAt to null on creation' {
                $Script:Result.UpdatedAt | Should -BeNull
            }

            It 'Sets CreatedAt to a valid UTC ISO 8601 timestamp' {
                { [System.DateTimeOffset]::Parse($Script:Result.CreatedAt) } |
                    Should -Not -Throw
            }

            It 'SchemaVersion matches module JsonSchemaVersion' {
                $Script:Result.SchemaVersion | Should -Be $Script:JsonSchemaVersion
            }
        }
        #endregion

        #region Certificado block
        Context 'Certificado block' {

            It 'Certificado block is present when no cert is provided' {
                $Script:Result.Certificado | Should -Not -BeNull
            }

            It 'Certificado.Path is null when no cert is provided' {
                $Script:Result.Certificado.Path | Should -BeNull
            }

            It 'Certificado.EncryptedPassword is null when no cert is provided' {
                $Script:Result.Certificado.EncryptedPassword | Should -BeNull
            }

            It 'Certificado.Path contains CertPath when cert is provided' {
                $objParams = @{
                    Cnpj         = $Script:Cnpj
                    RazaoSocial  = $Script:RazaoSocial
                    Uf           = $Script:Uf
                    Ambiente     = ([Ambiente]::Producao)
                    XmlPath      = $Script:XmlPath
                    OutputPath   = $Script:OutputPath
                    CertPath     = 'C:\cert.pfx'
                    CertPassword = 'encrypted-blob'
                }

                $result = ConvertTo-CompanyObject @objParams

                $result.Certificado.Path | Should -Be 'C:\cert.pfx'
            }

            It 'Certificado.EncryptedPassword contains CertPassword when cert is provided' {
                $objParams = @{
                    Cnpj         = $Script:Cnpj
                    RazaoSocial  = $Script:RazaoSocial
                    Uf           = $Script:Uf
                    Ambiente     = ([Ambiente]::Producao)
                    XmlPath      = $Script:XmlPath
                    OutputPath   = $Script:OutputPath
                    CertPath     = 'C:\cert.pfx'
                    CertPassword = 'encrypted-blob'
                }

                $result = ConvertTo-CompanyObject @objParams

                $result.Certificado.EncryptedPassword | Should -Be 'encrypted-blob'
            }
        }
        #endregion

        #region Optional XML paths
        Context 'Optional XML paths' {

            It 'XmlPathNfse is null when not provided' {
                $Script:Result.XmlPathNfse | Should -BeNull
            }

            It 'XmlPathEntrada is null when not provided' {
                $Script:Result.XmlPathEntrada | Should -BeNull
            }

            It 'Stores XmlPathNfse when provided' {
                $objParams = @{
                    Cnpj        = $Script:Cnpj
                    RazaoSocial = $Script:RazaoSocial
                    Uf          = $Script:Uf
                    Ambiente    = ([Ambiente]::Producao)
                    XmlPath     = $Script:XmlPath
                    OutputPath  = $Script:OutputPath
                    XmlPathNfse = 'C:\ERP\NFSe'
                }

                $result = ConvertTo-CompanyObject @objParams

                $result.XmlPathNfse | Should -Be 'C:\ERP\NFSe'
            }

            It 'Stores XmlPathEntrada when provided' {
                $objParams = @{
                    Cnpj           = $Script:Cnpj
                    RazaoSocial    = $Script:RazaoSocial
                    Uf             = $Script:Uf
                    Ambiente       = ([Ambiente]::Producao)
                    XmlPath        = $Script:XmlPath
                    OutputPath     = $Script:OutputPath
                    XmlPathEntrada = 'C:\ERP\Entrada'
                }

                $result = ConvertTo-CompanyObject @objParams

                $result.XmlPathEntrada | Should -Be 'C:\ERP\Entrada'
            }
        }
        #endregion

        #region Email collections
        Context 'Email collections' {

            It 'Email.Para defaults to empty array' {
                $Script:Result.Email.Para | Should -HaveCount 0
            }

            It 'Email.Cc defaults to empty array' {
                $Script:Result.Email.Cc | Should -HaveCount 0
            }

            It 'Email.Cco defaults to empty array' {
                $Script:Result.Email.Cco | Should -HaveCount 0
            }

            It 'Stores EmailPara when provided' {
                $recipient = [PSCustomObject]@{
                    Nome  = 'Joao'
                    Email = 'joao@example.com'
                }

                $objParams = @{
                    Cnpj        = $Script:Cnpj
                    RazaoSocial = $Script:RazaoSocial
                    Uf          = $Script:Uf
                    Ambiente    = ([Ambiente]::Producao)
                    XmlPath     = $Script:XmlPath
                    OutputPath  = $Script:OutputPath
                    EmailPara   = @($recipient)
                }

                $result = ConvertTo-CompanyObject @objParams

                $result.Email.Para          | Should -HaveCount 1
                $result.Email.Para[0].Email | Should -Be 'joao@example.com'
            }
        }
        #endregion
    }
}
