#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for Resolve-DFeArchiveInfo.

.DESCRIPTION
Verifies file name generation, company label extraction, path resolution,
output contract, and Company validation. Get-ArchivePeriodSegment and
ConvertTo-SafeString are mocked.

Coverage includes:
  - All four parameters are mandatory.
  - Company missing NomeFantasia, RazaoSocial or OutputPath throws.
  - OutputPath empty or whitespace throws.
  - NomeFantasia and RazaoSocial both empty throws.
  - Uses NomeFantasia when present.
  - Falls back to RazaoSocial when NomeFantasia is blank.
  - Discards non-alphanumeric tokens from the company label.
  - Takes only the first two meaningful words for the label.
  - FileName follows the expected format.
  - TempPath uses the system temp directory.
  - DestPath uses Company.OutputPath.
  - TipoDFe is preserved as-is in the output.
  - Output contract: TipoDFe, FileName, TempPath, DestPath as strings.
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

Describe 'Resolve-DFeArchiveInfo' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            $Script:Command = Get-Command -Name Resolve-DFeArchiveInfo -ErrorAction Stop
            $Script:Utc     = [System.TimeSpan]::Zero

            $Script:ValidCompany = [PSCustomObject]@{
                NomeFantasia = 'Ribeiro & Bonafe'
                RazaoSocial  = 'Ribeiro e Bonafe Ltda'
                OutputPath   = 'C:\Output'
            }

            $Script:ValidDateRange = [PSCustomObject]@{
                Start = [System.DateTimeOffset]::new(2026, 6,  1, 0, 0, 0, $Script:Utc)
                End   = [System.DateTimeOffset]::new(2026, 6, 30, 0, 0, 0, $Script:Utc)
            }

            $Script:Cnpj    = '11222333000181'
            $Script:TipoDFe = 'NFe'
        }

        BeforeEach {

            Mock -CommandName Get-ArchivePeriodSegment -MockWith { '202606' }

            # Simulates the real behaviour: uppercase, ASCII, spaces preserved so
            # the label-extraction logic under test can split and filter normally.
            Mock -CommandName ConvertTo-SafeString -MockWith {
                param($InputObject)
                $InputObject.ToUpperInvariant()
            }
        }

        #region Parameter contract
        Context 'Parameter contract' {

            It 'Declares TipoDFe as mandatory' {
                $mandatory = $Script:Command.Parameters['TipoDFe'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.Mandatory
                    }

                $mandatory | Should -Not -BeNullOrEmpty
            }

            It 'Declares Cnpj as mandatory' {
                $mandatory = $Script:Command.Parameters['Cnpj'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.Mandatory
                    }

                $mandatory | Should -Not -BeNullOrEmpty
            }

            It 'Declares Company as mandatory' {
                $mandatory = $Script:Command.Parameters['Company'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.Mandatory
                    }

                $mandatory | Should -Not -BeNullOrEmpty
            }

            It 'Declares DateRange as mandatory' {
                $mandatory = $Script:Command.Parameters['DateRange'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.Mandatory
                    }

                $mandatory | Should -Not -BeNullOrEmpty
            }
        }
        #endregion

        #region Company validation
        Context 'Company validation' {

            It 'Throws when NomeFantasia property is missing' {
                $company = [PSCustomObject]@{
                    RazaoSocial = 'Ribeiro e Bonafe Ltda'
                    OutputPath  = 'C:\Output'
                }

                $resolveParams = @{
                    TipoDFe   = $Script:TipoDFe
                    Cnpj      = $Script:Cnpj
                    Company   = $company
                    DateRange = $Script:ValidDateRange
                }

                { Resolve-DFeArchiveInfo @resolveParams -ErrorAction Stop } | Should -Throw
            }

            It 'Throws when RazaoSocial property is missing' {
                $company = [PSCustomObject]@{
                    NomeFantasia = ''
                    OutputPath   = 'C:\Output'
                }

                $resolveParams = @{
                    TipoDFe   = $Script:TipoDFe
                    Cnpj      = $Script:Cnpj
                    Company   = $company
                    DateRange = $Script:ValidDateRange
                }

                { Resolve-DFeArchiveInfo @resolveParams -ErrorAction Stop } | Should -Throw
            }

            It 'Throws when OutputPath property is missing' {
                $company = [PSCustomObject]@{
                    NomeFantasia = 'Ribeiro & Bonafe'
                    RazaoSocial  = 'Ribeiro e Bonafe Ltda'
                }

                $resolveParams = @{
                    TipoDFe   = $Script:TipoDFe
                    Cnpj      = $Script:Cnpj
                    Company   = $company
                    DateRange = $Script:ValidDateRange
                }

                { Resolve-DFeArchiveInfo @resolveParams -ErrorAction Stop } | Should -Throw
            }

            It 'Throws when OutputPath is empty' {
                $company = [PSCustomObject]@{
                    NomeFantasia = 'Ribeiro & Bonafe'
                    RazaoSocial  = 'Ribeiro e Bonafe Ltda'
                    OutputPath   = ''
                }

                $resolveParams = @{
                    TipoDFe   = $Script:TipoDFe
                    Cnpj      = $Script:Cnpj
                    Company   = $company
                    DateRange = $Script:ValidDateRange
                }

                { Resolve-DFeArchiveInfo @resolveParams -ErrorAction Stop } | Should -Throw
            }

            It 'Throws when OutputPath is whitespace' {
                $company = [PSCustomObject]@{
                    NomeFantasia = 'Ribeiro & Bonafe'
                    RazaoSocial  = 'Ribeiro e Bonafe Ltda'
                    OutputPath   = '   '
                }

                $resolveParams = @{
                    TipoDFe   = $Script:TipoDFe
                    Cnpj      = $Script:Cnpj
                    Company   = $company
                    DateRange = $Script:ValidDateRange
                }

                { Resolve-DFeArchiveInfo @resolveParams -ErrorAction Stop } | Should -Throw
            }

            It 'Throws when both NomeFantasia and RazaoSocial are empty' {
                $company = [PSCustomObject]@{
                    NomeFantasia = ''
                    RazaoSocial  = ''
                    OutputPath   = 'C:\Output'
                }

                $resolveParams = @{
                    TipoDFe   = $Script:TipoDFe
                    Cnpj      = $Script:Cnpj
                    Company   = $company
                    DateRange = $Script:ValidDateRange
                }

                { Resolve-DFeArchiveInfo @resolveParams -ErrorAction Stop } | Should -Throw
            }

            It 'Throws when both NomeFantasia and RazaoSocial are whitespace' {
                $company = [PSCustomObject]@{
                    NomeFantasia = '   '
                    RazaoSocial  = '   '
                    OutputPath   = 'C:\Output'
                }

                $resolveParams = @{
                    TipoDFe   = $Script:TipoDFe
                    Cnpj      = $Script:Cnpj
                    Company   = $company
                    DateRange = $Script:ValidDateRange
                }

                { Resolve-DFeArchiveInfo @resolveParams -ErrorAction Stop } | Should -Throw
            }
        }
        #endregion

        #region Company label extraction
        Context 'Company label extraction' {

            It 'Uses NomeFantasia when present' {
                $resolveParams = @{
                    TipoDFe   = $Script:TipoDFe
                    Cnpj      = $Script:Cnpj
                    Company   = $Script:ValidCompany
                    DateRange = $Script:ValidDateRange
                }

                $result = Resolve-DFeArchiveInfo @resolveParams

                $result.FileName | Should -Match 'RIBEIRO'
            }

            It 'Falls back to RazaoSocial when NomeFantasia is blank' {
                $company = [PSCustomObject]@{
                    NomeFantasia = ''
                    RazaoSocial  = 'Silva Comercio Ltda'
                    OutputPath   = 'C:\Output'
                }

                $resolveParams = @{
                    TipoDFe   = $Script:TipoDFe
                    Cnpj      = $Script:Cnpj
                    Company   = $company
                    DateRange = $Script:ValidDateRange
                }

                $result = Resolve-DFeArchiveInfo @resolveParams

                $result.FileName | Should -Match 'SILVA'
            }

            It 'Discards non-alphanumeric tokens from the label' {
                $company = [PSCustomObject]@{
                    NomeFantasia = 'Ribeiro & Bonafe Comercio'
                    RazaoSocial  = 'Ribeiro e Bonafe Ltda'
                    OutputPath   = 'C:\Output'
                }

                $resolveParams = @{
                    TipoDFe   = $Script:TipoDFe
                    Cnpj      = $Script:Cnpj
                    Company   = $company
                    DateRange = $Script:ValidDateRange
                }

                $result = Resolve-DFeArchiveInfo @resolveParams

                $result.FileName | Should -Not -Match '_&_'
            }

            It 'Uses only the first two meaningful words' {
                $company = [PSCustomObject]@{
                    NomeFantasia = 'Alpha Beta Gamma Delta'
                    RazaoSocial  = 'Alpha Beta Ltda'
                    OutputPath   = 'C:\Output'
                }

                $resolveParams = @{
                    TipoDFe   = $Script:TipoDFe
                    Cnpj      = $Script:Cnpj
                    Company   = $company
                    DateRange = $Script:ValidDateRange
                }

                $result = Resolve-DFeArchiveInfo @resolveParams

                $result.FileName | Should -Match 'ALPHA_BETA'
                $result.FileName | Should -Not -Match 'GAMMA'
            }
        }
        #endregion

        #region File name format
        Context 'File name format' {

            BeforeAll {

                $resolveParams = @{
                    TipoDFe   = $Script:TipoDFe
                    Cnpj      = $Script:Cnpj
                    Company   = $Script:ValidCompany
                    DateRange = $Script:ValidDateRange
                }

                $Script:Result = Resolve-DFeArchiveInfo @resolveParams
            }

            It 'FileName starts with TipoDFe' {
                $Script:Result.FileName | Should -Match '^NFe_'
            }

            It 'FileName contains the CNPJ' {
                $Script:Result.FileName | Should -Match $Script:Cnpj
            }

            It 'FileName ends with the period segment and .zip' {
                $Script:Result.FileName | Should -Match '202606\.zip$'
            }

            It 'FileName follows the expected format' {
                $Script:Result.FileName | Should -Be 'NFe_11222333000181_RIBEIRO_BONAFE_202606.zip'
            }
        }
        #endregion

        #region Path resolution
        Context 'Path resolution' {

            BeforeAll {

                $resolveParams = @{
                    TipoDFe   = $Script:TipoDFe
                    Cnpj      = $Script:Cnpj
                    Company   = $Script:ValidCompany
                    DateRange = $Script:ValidDateRange
                }

                $Script:PathResult = Resolve-DFeArchiveInfo @resolveParams
            }

            It 'TempPath uses the system temp directory' {
                $pathParams = @{
                    Path      = ([System.IO.Path]::GetTempPath())
                    ChildPath = $Script:PathResult.FileName
                }

                $Script:PathResult.TempPath | Should -Be (Join-Path @pathParams)
            }

            It 'DestPath uses Company.OutputPath' {
                $pathParams = @{
                    Path      = $Script:ValidCompany.OutputPath
                    ChildPath = $Script:PathResult.FileName
                }

                $Script:PathResult.DestPath | Should -Be (Join-Path @pathParams)
            }
        }
        #endregion

        #region Output contract
        Context 'Output contract' {

            BeforeAll {

                $resolveParams = @{
                    TipoDFe   = $Script:TipoDFe
                    Cnpj      = $Script:Cnpj
                    Company   = $Script:ValidCompany
                    DateRange = $Script:ValidDateRange
                }

                $Script:Sample = Resolve-DFeArchiveInfo @resolveParams
            }

            It 'Returns a PSCustomObject' {
                $Script:Sample | Should -BeOfType [System.Management.Automation.PSCustomObject]
            }

            It 'Exposes exactly the documented properties' {
                $expected = @('TipoDFe', 'FileName', 'TempPath', 'DestPath')
                $actual   = @($Script:Sample.PSObject.Properties.Name)

                $actual | Should -Be $expected
            }

            It 'Exposes TipoDFe as string' {
                $Script:Sample.TipoDFe | Should -BeOfType [string]
            }

            It 'Exposes FileName as string' {
                $Script:Sample.FileName | Should -BeOfType [string]
            }

            It 'Exposes TempPath as string' {
                $Script:Sample.TempPath | Should -BeOfType [string]
            }

            It 'Exposes DestPath as string' {
                $Script:Sample.DestPath | Should -BeOfType [string]
            }

            It 'Preserves TipoDFe as-is in the output' {
                $Script:Sample.TipoDFe | Should -Be 'NFe'
            }
        }
        #endregion
    }
}
