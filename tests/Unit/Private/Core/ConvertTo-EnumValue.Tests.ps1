#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for ConvertTo-EnumValue.

.DESCRIPTION
Validates conversion of external values into defined enum members.

Coverage includes:
  - Mandatory parameter contracts.
  - Null validation.
  - Named enum members.
  - Numeric enum values.
  - Numeric strings.
  - Case-insensitive named values.
  - All members of Ambiente.
  - All members of ModeloDFe.
  - Rejection of undefined numeric values.
  - Rejection of invalid named values.
  - Rejection of null values.
  - Correct error identifier.
  - Correct error category.
  - Correct TargetObject.
  - No output for invalid input beyond the terminating error.
  - Correct enum output type.
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

Describe 'ConvertTo-EnumValue' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            $Script:Command = Get-Command -Name ConvertTo-EnumValue -ErrorAction Stop
        }

        #region Parameter contract
        Context 'Parameter contract' {

            It 'Declares EnumType as mandatory' {
                $attribute = $Script:Command.Parameters['EnumType'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute]
                    }

                $attribute.Mandatory | Should -BeTrue
            }

            It 'Declares Value as mandatory' {
                $attribute = $Script:Command.Parameters['Value'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute]
                    }

                $attribute.Mandatory | Should -BeTrue
            }

            It 'Rejects null EnumType' {
                { ConvertTo-EnumValue -EnumType $null -Value 'Producao' } |
                    Should -Throw
            }

            It 'Accepts null Value at parameter binding' {
                # The parameter itself allows null.
                # The function must reject it with InvalidEnumValue.
                { ConvertTo-EnumValue -EnumType ([Ambiente]) -Value $null } |
                    Should -Throw
            }
        }
        #endregion

        #region Ambiente
        Context 'Ambiente enum' {

            It 'Converts Producao by name' {
                $result = ConvertTo-EnumValue -EnumType ([Ambiente]) -Value 'Producao'
                $result | Should -Be ([Ambiente]::Producao)
            }

            It 'Converts Homologacao by name' {
                $result = ConvertTo-EnumValue -EnumType ([Ambiente]) -Value 'Homologacao'
                $result | Should -Be ([Ambiente]::Homologacao)
            }

            It 'Converts numeric value 1 to Producao' {
                $result = ConvertTo-EnumValue -EnumType ([Ambiente]) -Value 1
                $result | Should -Be ([Ambiente]::Producao)
            }

            It 'Converts numeric value 2 to Homologacao' {
                $result = ConvertTo-EnumValue -EnumType ([Ambiente]) -Value 2
                $result | Should -Be ([Ambiente]::Homologacao)
            }

            It 'Converts numeric string 1 to Producao' {
                $result = ConvertTo-EnumValue -EnumType ([Ambiente]) -Value '1'
                $result | Should -Be ([Ambiente]::Producao)
            }

            It 'Converts numeric string 2 to Homologacao' {
                $result = ConvertTo-EnumValue -EnumType ([Ambiente]) -Value '2'
                $result | Should -Be ([Ambiente]::Homologacao)
            }

            It 'Accepts case-insensitive names' {
                $result = ConvertTo-EnumValue -EnumType ([Ambiente]) -Value 'producao'
                $result | Should -Be ([Ambiente]::Producao)
            }

            It 'Rejects undefined numeric value 0' {
                { ConvertTo-EnumValue -EnumType ([Ambiente]) -Value 0 } |
                    Should -Throw
            }

            It 'Rejects undefined numeric value 999' {
                { ConvertTo-EnumValue -EnumType ([Ambiente]) -Value 999 } |
                    Should -Throw
            }

            It 'Rejects an undefined name' {
                { ConvertTo-EnumValue -EnumType ([Ambiente]) -Value 'Desenvolvimento' } |
                    Should -Throw
            }
        }
        #endregion

        #region ModeloDFe
        Context 'ModeloDFe enum' {

            It 'Converts NFe by name' {
                ConvertTo-EnumValue -EnumType ([ModeloDFe]) -Value 'NFe' |
                    Should -Be ([ModeloDFe]::NFe)
            }

            It 'Converts CTe by name' {
                ConvertTo-EnumValue -EnumType ([ModeloDFe]) -Value 'CTe' |
                    Should -Be ([ModeloDFe]::CTe)
            }

            It 'Converts MDFe by name' {
                ConvertTo-EnumValue -EnumType ([ModeloDFe]) -Value 'MDFe' |
                    Should -Be ([ModeloDFe]::MDFe)
            }

            It 'Converts NFCom by name' {
                ConvertTo-EnumValue -EnumType ([ModeloDFe]) -Value 'NFCom' |
                    Should -Be ([ModeloDFe]::NFCom)
            }

            It 'Converts NFCe by name' {
                ConvertTo-EnumValue -EnumType ([ModeloDFe]) -Value 'NFCe' |
                    Should -Be ([ModeloDFe]::NFCe)
            }

            It 'Converts CTeOS by name' {
                ConvertTo-EnumValue -EnumType ([ModeloDFe]) -Value 'CTeOS' |
                    Should -Be ([ModeloDFe]::CTeOS)
            }

            It 'Converts all defined numeric values' {
                $cases = @(
                    @{
                        Value    = 55
                        Expected = [ModeloDFe]::NFe
                    }
                    @{
                        Value    = 57
                        Expected = [ModeloDFe]::CTe
                    }
                    @{
                        Value    = 58
                        Expected = [ModeloDFe]::MDFe
                    }
                    @{
                        Value    = 62
                        Expected = [ModeloDFe]::NFCom
                    }
                    @{
                        Value    = 65
                        Expected = [ModeloDFe]::NFCe
                    }
                    @{
                        Value    = 67
                        Expected = [ModeloDFe]::CTeOS
                    }
                )

                foreach ($case in $cases) {
                    $result = ConvertTo-EnumValue -EnumType ([ModeloDFe]) -Value $case.Value
                    $result | Should -Be $case.Expected
                }
            }

            It 'Converts numeric string 55 to NFe' {
                ConvertTo-EnumValue -EnumType ([ModeloDFe]) -Value '55' |
                    Should -Be ([ModeloDFe]::NFe)
            }

            It 'Accepts case-insensitive names' {
                ConvertTo-EnumValue -EnumType ([ModeloDFe]) -Value 'nfe' |
                    Should -Be ([ModeloDFe]::NFe)
            }

            It 'Rejects undefined numeric value 56' {
                { ConvertTo-EnumValue -EnumType ([ModeloDFe]) -Value 56 } |
                    Should -Throw
            }

            It 'Rejects undefined numeric value 999' {
                { ConvertTo-EnumValue -EnumType ([ModeloDFe]) -Value 999 } |
                    Should -Throw
            }

            It 'Rejects an undefined name' {
                { ConvertTo-EnumValue -EnumType ([ModeloDFe]) -Value 'NFSe' } |
                    Should -Throw
            }
        }
        #endregion

        #region Null and invalid values
        Context 'Invalid values' {

            It 'Throws InvalidEnumValue for null' {
                $errorRecord = $null

                try {
                    ConvertTo-EnumValue -EnumType ([Ambiente]) -Value $null
                } catch {
                    $errorRecord = $_
                }

                $errorRecord | Should -Not -BeNullOrEmpty

                $errorRecord.FullyQualifiedErrorId |
                    Should -BeLike 'InvalidEnumValue*'
            }

            It 'Throws InvalidEnumValue for an invalid name' {
                $errorRecord = $null

                try {
                    ConvertTo-EnumValue -EnumType ([Ambiente]) -Value 'InvalidValue'
                } catch {
                    $errorRecord = $_
                }

                $errorRecord | Should -Not -BeNullOrEmpty

                $errorRecord.FullyQualifiedErrorId |
                    Should -BeLike 'InvalidEnumValue*'
            }

            It 'Throws InvalidEnumValue for an undefined numeric value' {
                $errorRecord = $null

                try {
                    ConvertTo-EnumValue -EnumType ([Ambiente]) -Value 999
                } catch {
                    $errorRecord = $_
                }

                $errorRecord | Should -Not -BeNullOrEmpty

                $errorRecord.FullyQualifiedErrorId |
                    Should -BeLike 'InvalidEnumValue*'
            }
        }
        #endregion

        #region Error contract
        Context 'Error contract' {

            It 'Uses InvalidArgument category for null values' {
                $errorRecord = $null

                try {
                    ConvertTo-EnumValue -EnumType ([Ambiente]) -Value $null
                } catch {
                    $errorRecord = $_
                }

                $errorRecord.CategoryInfo.Category |
                    Should -Be ([System.Management.Automation.ErrorCategory]::InvalidArgument)
            }

            It 'Uses InvalidArgument category for invalid names' {
                $errorRecord = $null

                try {
                    ConvertTo-EnumValue -EnumType ([Ambiente]) -Value 'InvalidValue'
                } catch {
                    $errorRecord = $_
                }

                $errorRecord.CategoryInfo.Category |
                    Should -Be ([System.Management.Automation.ErrorCategory]::InvalidArgument)
            }

            It 'Uses InvalidArgument category for undefined numeric values' {
                $errorRecord = $null

                try {
                    ConvertTo-EnumValue -EnumType ([Ambiente]) -Value 999
                } catch {
                    $errorRecord = $_
                }

                $errorRecord.CategoryInfo.Category |
                    Should -Be ([System.Management.Automation.ErrorCategory]::InvalidArgument)
            }

            It 'Uses the original Value as TargetObject for null input' {
                $errorRecord = $null

                try {
                    ConvertTo-EnumValue -EnumType ([Ambiente]) -Value $null
                } catch {
                    $errorRecord = $_
                }

                $errorRecord.TargetObject | Should -Be $null
            }

            It 'Uses the original Value as TargetObject for invalid input' {
                $invalidValue = 'InvalidValue'
                $errorRecord = $null

                try {
                    ConvertTo-EnumValue -EnumType ([Ambiente]) -Value $invalidValue
                } catch {
                    $errorRecord = $_
                }

                $errorRecord.TargetObject | Should -BeExactly $invalidValue
            }
        }
        #endregion

        #region Output contract
        Context 'Output contract' {

            It 'Returns an Ambiente enum value' {
                $result = ConvertTo-EnumValue -EnumType ([Ambiente]) -Value 'Producao'
                $result.GetType() | Should -Be ([Ambiente])
            }

            It 'Returns a ModeloDFe enum value' {
                $result = ConvertTo-EnumValue -EnumType ([ModeloDFe]) -Value 'NFe'
                $result.GetType() | Should -Be ([ModeloDFe])
            }

            It 'Returns a defined enum member' {
                $result = ConvertTo-EnumValue -EnumType ([ModeloDFe]) -Value 55

                [System.Enum]::IsDefined([ModeloDFe], $result) | Should -BeTrue
            }
        }
        #endregion
    }
}
