#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for ConvertTo-NormalizedCnpj.

.DESCRIPTION
Coverage includes:
  - Value is mandatory and rejects null and empty strings.
  - Strips dots, slashes and dashes from formatted CNPJs.
  - Converts lowercase letters to uppercase.
  - Supports alphanumeric CNPJs (RFB 2026).
  - Returns only 14 uppercase alphanumeric characters.
  - Rejects unsupported characters.
  - Rejects values shorter or longer than 14 normalized characters.
  - Throws NormalizedCnpjEmpty when result is empty after stripping.
  - Accepts pipeline input.
  - Accepts pipeline input by property name.
  - Processes multiple values from the pipeline.
  - Returns a string.
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

Describe 'ConvertTo-NormalizedCnpj' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            $Script:Command = Get-Command -Name ConvertTo-NormalizedCnpj -ErrorAction Stop
        }

        #region Parameter contract
        Context 'Parameter contract' {

            It 'Declares Value as mandatory' {
                $mandatory = $Script:Command.Parameters['Value'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.Mandatory
                    }

                $mandatory | Should -Not -BeNullOrEmpty
            }

            It 'Accepts Value from the pipeline' {
                $pipeline = $Script:Command.Parameters['Value'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.ValueFromPipeline
                    }

                $pipeline | Should -Not -BeNullOrEmpty
            }

            It 'Accepts Value from the pipeline by property name' {
                $pipelineByPropertyName = $Script:Command.Parameters['Value'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.ValueFromPipelineByPropertyName
                    }

                $pipelineByPropertyName | Should -Not -BeNullOrEmpty
            }

            It 'Rejects a null Value' {
                { ConvertTo-NormalizedCnpj -Value $null } | Should -Throw
            }

            It 'Rejects an empty Value' {
                { ConvertTo-NormalizedCnpj -Value '' } | Should -Throw
            }
        }
        #endregion

        #region Successful normalization
        Context 'Successful normalization' {

            It 'Strips dots, slashes and dashes from a formatted CNPJ' {
                $result = ConvertTo-NormalizedCnpj -Value '00.000.000/0001-00'
                $result | Should -Be '00000000000100'
            }

            It 'Converts lowercase letters to uppercase' {
                $result = ConvertTo-NormalizedCnpj -Value 'ab.1cd.2ef/3gh4-i5'
                $result | Should -Be 'AB1CD2EF3GH4I5'
            }

            It 'Returns only alphanumeric characters' {
                $result = ConvertTo-NormalizedCnpj -Value '12.345.678/0001-99'
                $result | Should -Match '^[0-9A-Z]{14}$'
            }

            It 'Handles a plain 14-digit numeric CNPJ' {
                $result = ConvertTo-NormalizedCnpj -Value '12345678000199'
                $result | Should -Be '12345678000199'
            }

            It 'Handles an alphanumeric CNPJ (RFB 2026)' {
                $result = ConvertTo-NormalizedCnpj -Value '12.ABC.345/01DE-35'
                $result | Should -Be '12ABC34501DE35'
            }

            It 'Returns a string' {
                $result = ConvertTo-NormalizedCnpj -Value '12345678000199'
                $result | Should -BeOfType [string]
            }
        }
        #endregion

        #region Invalid input
        Context 'Invalid input' {

            It 'Rejects unsupported characters' {
                { ConvertTo-NormalizedCnpj -Value '12.ABC.345/01D_-35' } |
                    Should -Throw
            }

            It 'Rejects values shorter than 14 normalized characters' {
                { ConvertTo-NormalizedCnpj -Value '12.ABC.345/01D' } |
                    Should -Throw
            }

            It 'Rejects values longer than 14 normalized characters' {
                { ConvertTo-NormalizedCnpj -Value '12.ABC.345/01DE-356' } |
                    Should -Throw
            }

            It 'Throws CnpjContainsUnsupportedCharacters for unsupported characters' {
                try {
                    ConvertTo-NormalizedCnpj -Value '12.ABC.345/01D_-35' -ErrorAction Stop
                    throw 'Expected ConvertTo-NormalizedCnpj to throw.'
                } catch {
                    $_.FullyQualifiedErrorId | Should -BeLike 'CnpjContainsUnsupportedCharacters*'
                }
            }

            It 'Throws CnpjInvalidLength for invalid normalized length' {
                try {
                    ConvertTo-NormalizedCnpj -Value '12.ABC.345/01D' -ErrorAction Stop
                    throw 'Expected ConvertTo-NormalizedCnpj to throw.'
                } catch {
                    $_.FullyQualifiedErrorId | Should -BeLike 'CnpjInvalidLength*'
                }
            }
        }
        #endregion

        #region Empty after normalization
        Context 'Empty after normalization' {

            BeforeAll {

                $Script:Thrown = $null

                try {
                    ConvertTo-NormalizedCnpj -Value '...' -ErrorAction Stop
                } catch {
                    $Script:Thrown = $_
                }
            }

            It 'Throws NormalizedCnpjEmpty when result is empty after stripping' {
                $Script:Thrown | Should -Not -BeNullOrEmpty
                $Script:Thrown.FullyQualifiedErrorId | Should -BeLike 'NormalizedCnpjEmpty*'
            }

            It 'Uses InvalidArgument category' {
                $Script:Thrown.CategoryInfo.Category |
                    Should -Be ([System.Management.Automation.ErrorCategory]::InvalidArgument)
            }

            It 'Exposes the original value as TargetObject' {
                $Script:Thrown.TargetObject | Should -Be '...'
            }
        }
        #endregion

        #region Pipeline support
        Context 'Pipeline support' {

            It 'Accepts Value from the pipeline' {
                $result = '12.345.678/0001-99' | ConvertTo-NormalizedCnpj
                $result | Should -Be '12345678000199'
            }

            It 'Accepts Value from the pipeline by property name' {
                $inputObject = [pscustomobject]@{
                    Value = '12.345.678/0001-99'
                }

                $result = $inputObject | ConvertTo-NormalizedCnpj
                $result | Should -Be '12345678000199'
            }

            It 'Processes multiple values from the pipeline' {
                $results = @(
                    '12.345.678/0001-99'
                    '11.222.333/0001-81'
                ) | ConvertTo-NormalizedCnpj

                $results | Should -HaveCount 2
                $results[0] | Should -Be '12345678000199'
                $results[1] | Should -Be '11222333000181'
            }
        }
        #endregion
    }
}
