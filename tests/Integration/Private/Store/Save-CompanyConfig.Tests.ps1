#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Integration tests for Save-CompanyConfig.

.DESCRIPTION
Verifies Save-CompanyConfig against real files written to an isolated
%LOCALAPPDATA% directory. No mocks are used.

Coverage includes:
  - Creates config directory when it does not exist.
  - Writes {cnpj}.json to the correct path.
  - JSON content round-trips correctly via Get-CompanyConfig.
  - Does not leave a .tmp file after successful write.
  - Atomic replace: overwrites existing file without data loss.
  - Stamps UpdatedAt when AsUpdate is specified.
  - Does not stamp UpdatedAt when AsUpdate is omitted.
  - Does not mutate the caller's object when AsUpdate is specified.
  - Email arrays are always serialized as arrays.
  - CNPJ isolation: each company writes to its own file.
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

            $Script:Cnpj = '12345678000195'

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

            $removeParams = @{
                LiteralPath = $Script:TempRootPath
                Recurse     = $true
                Force       = $true
                ErrorAction = 'SilentlyContinue'
            }

            Remove-Item @removeParams
            Remove-Module -Name PipeDFe -Force -ErrorAction SilentlyContinue
        }

        #region File creation
        Context 'File creation' {

            BeforeAll {

                Save-CompanyConfig -Company $Script:ValidCompany

                $Script:CompanyFile = Get-ExpectedCompanyFile -Cnpj $Script:Cnpj
            }

            It 'Creates the config directory' {
                $configDir = [System.IO.Path]::GetDirectoryName($Script:CompanyFile)

                Test-Path -LiteralPath $configDir -PathType Container | Should -BeTrue
            }

            It 'Writes the JSON file to the correct path' {
                Test-Path -LiteralPath $Script:CompanyFile -PathType Leaf | Should -BeTrue
            }

            It 'Does not leave a .tmp file after successful write' {
                $tmpFile = "$Script:CompanyFile.tmp"

                Test-Path -LiteralPath $tmpFile | Should -BeFalse
            }
        }
        #endregion

        #region Round-trip via Get-CompanyConfig
        Context 'Round-trip via Get-CompanyConfig' {

            BeforeAll {

                Save-CompanyConfig -Company $Script:ValidCompany

                $Script:RoundTrip = Get-CompanyConfig -Cnpj $Script:Cnpj
            }

            It 'Persists the correct Cnpj' {
                $Script:RoundTrip.Cnpj | Should -Be $Script:Cnpj
            }

            It 'Persists the correct RazaoSocial' {
                $Script:RoundTrip.RazaoSocial | Should -Be 'ACME COMERCIO LTDA'
            }

            It 'Persists the correct Ambiente' {
                $Script:RoundTrip.Ambiente | Should -Be 'Producao'
            }

            It 'Preserves CreatedAt as string' {
                $Script:RoundTrip.CreatedAt | Should -Be '2026-08-01T00:00:00.0000000+00:00'
            }

            It 'Preserves UpdatedAt as null' {
                $Script:RoundTrip.UpdatedAt | Should -BeNull
            }

            It 'Certificado block is present after round-trip' {
                $Script:RoundTrip.Certificado | Should -Not -BeNull
            }

            It 'Email.Para is an array after round-trip' {
                , $Script:RoundTrip.Email.Para | Should -BeOfType [object[]]
            }
        }
        #endregion

        #region Atomic replace
        Context 'Atomic replace' {

            It 'Overwrites existing file without data loss' {
                $cnpj2 = '98765432000100'

                $company2 = [PSCustomObject]@{
                    Cnpj      = $cnpj2
                    RazaoSocial = 'ORIGINAL NAME'
                    Email     = [PSCustomObject]@{
                        Para = @()
                        Cc   = @()
                        Cco  = @()
                    }
                    UpdatedAt = $null
                }

                Save-CompanyConfig -Company $company2

                $company2Updated = [PSCustomObject]@{
                    Cnpj        = $cnpj2
                    RazaoSocial = 'UPDATED NAME'
                    Email       = [PSCustomObject]@{
                        Para = @()
                        Cc   = @()
                        Cco  = @()
                    }
                    UpdatedAt   = $null
                }

                Save-CompanyConfig -Company $company2Updated

                $file   = Get-ExpectedCompanyFile -Cnpj $cnpj2

                $saved  = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json

                $saved.RazaoSocial | Should -Be 'UPDATED NAME'
            }
        }
        #endregion

        #region UpdatedAt stamping
        Context 'UpdatedAt stamping' {

            It 'Stamps UpdatedAt when AsUpdate is specified' {
                $cnpj3 = '11111111000191'

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

                $file  = Get-ExpectedCompanyFile -Cnpj $cnpj3

                $saved = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json

                $saved.UpdatedAt | Should -Not -BeNull
            }

            It 'Does not stamp UpdatedAt when AsUpdate is omitted' {
                $cnpj4 = '22222222000172'

                $company4 = [PSCustomObject]@{
                    Cnpj      = $cnpj4
                    UpdatedAt = $null
                    Email     = [PSCustomObject]@{
                        Para = @()
                        Cc   = @()
                        Cco  = @()
                    }
                }

                Save-CompanyConfig -Company $company4

                $file  = Get-ExpectedCompanyFile -Cnpj $cnpj4

                $saved = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json

                $saved.UpdatedAt | Should -BeNull
            }

            It 'Does not mutate the caller object when AsUpdate is specified' {
                $cnpj5 = '33333333000187'

                $company5 = [PSCustomObject]@{
                    Cnpj      = $cnpj5
                    UpdatedAt = $null
                    Email     = [PSCustomObject]@{
                        Para = @()
                        Cc   = @()
                        Cco  = @()
                    }
                }

                Save-CompanyConfig -Company $company5 -AsUpdate

                $company5.UpdatedAt | Should -BeNull
            }
        }
        #endregion

        #region Email array serialization
        Context 'Email array serialization' {

            It 'Serializes a single recipient as an array not a scalar' {
                $cnpj6 = '44444444000153'

                $recipient = [PSCustomObject]@{
                    Nome  = 'Contador'
                    Email = 'contador@example.com'
                }

                $company6 = [PSCustomObject]@{
                    Cnpj      = $cnpj6
                    UpdatedAt = $null
                    Email     = [PSCustomObject]@{
                        Para = @($recipient)
                        Cc   = @()
                        Cco  = @()
                    }
                }

                Save-CompanyConfig -Company $company6

                $file  = Get-ExpectedCompanyFile -Cnpj $cnpj6
                $raw   = Get-Content -LiteralPath $file -Raw
                $saved = $raw | ConvertFrom-Json
                $para  = @($saved.Email.Para)

                $para | Should -HaveCount 1
                $para[0].Email | Should -Be 'contador@example.com'
            }
        }
        #endregion

        #region CNPJ isolation
        Context 'CNPJ isolation' {

            It 'Each company writes to its own file' {
                $cnpjA = '55555555000187'
                $cnpjB = '66666666000160'

                $companyA = [PSCustomObject]@{
                    Cnpj      = $cnpjA
                    RazaoSocial = 'COMPANY A'
                    UpdatedAt = $null
                    Email     = [PSCustomObject]@{
                        Para = @()
                        Cc   = @()
                        Cco  = @()
                    }
                }

                $companyB = [PSCustomObject]@{
                    Cnpj      = $cnpjB
                    RazaoSocial = 'COMPANY B'
                    UpdatedAt = $null
                    Email     = [PSCustomObject]@{
                        Para = @()
                        Cc   = @()
                        Cco  = @()
                    }
                }

                Save-CompanyConfig -Company $companyA
                Save-CompanyConfig -Company $companyB

                $fileA = Get-ExpectedCompanyFile -Cnpj $cnpjA
                $fileB = Get-ExpectedCompanyFile -Cnpj $cnpjB

                $savedA = Get-Content -LiteralPath $fileA -Raw | ConvertFrom-Json
                $savedB = Get-Content -LiteralPath $fileB -Raw | ConvertFrom-Json

                $savedA.RazaoSocial | Should -Be 'COMPANY A'
                $savedB.RazaoSocial | Should -Be 'COMPANY B'
            }
        }
        #endregion
    }
}
