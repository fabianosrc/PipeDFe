#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for ConvertTo-NormalizedMailRecipient.

.DESCRIPTION
Coverage includes:
  - InputObject is optional and allows null and empty collections.
  - Skips null and empty input.
  - Converts string input to a recipient object.
  - Converts objects with Email and optional Name properties.
  - Skips objects without an Email property.
  - Skips null and whitespace-only email values.
  - Trims Email and Name values.
  - Converts non-string Email and Name values to strings.
  - Handles mixed input.
  - Accepts pipeline input.
  - Produces one output per valid pipeline input.
  - Output contract: PSCustomObject with Name and Email properties.
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

Describe 'ConvertTo-NormalizedMailRecipient' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            $Script:Command = Get-Command -Name ConvertTo-NormalizedMailRecipient -ErrorAction Stop
        }

        #region Parameter contract
        Context 'Parameter contract' {

            It 'Declares InputObject as optional' {
                $mandatory = $Script:Command.Parameters['InputObject'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.Mandatory
                    }

                $mandatory | Should -BeNullOrEmpty
            }

            It 'Allows null for InputObject' {
                $allowNull = $Script:Command.Parameters['InputObject'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.AllowNullAttribute]
                    }

                $allowNull | Should -Not -BeNullOrEmpty
            }

            It 'Allows empty collections for InputObject' {
                $allowEmpty = $Script:Command.Parameters['InputObject'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.AllowEmptyCollectionAttribute]
                    }

                $allowEmpty | Should -Not -BeNullOrEmpty
            }

            It 'Accepts InputObject from the pipeline' {
                $pipeline = $Script:Command.Parameters['InputObject'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.ValueFromPipeline
                    }

                $pipeline | Should -Not -BeNullOrEmpty
            }

            It 'Accepts InputObject by property name from the pipeline' {
                $pipelineByPropertyName = $Script:Command.Parameters['InputObject'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.ValueFromPipelineByPropertyName
                    }

                $pipelineByPropertyName | Should -Not -BeNullOrEmpty
            }
        }
        #endregion

        #region Empty and null input
        Context 'Empty and null input' {

            It 'Produces no output for null input' {
                $results = @(ConvertTo-NormalizedMailRecipient -InputObject $null)
                $results | Should -HaveCount 0
            }

            It 'Produces no output for an empty collection' {
                $results = @(ConvertTo-NormalizedMailRecipient -InputObject @())
                $results | Should -HaveCount 0
            }

            It 'Produces no output when all entries are null' {
                $results = @(ConvertTo-NormalizedMailRecipient -InputObject @($null, $null))
                $results | Should -HaveCount 0
            }

            It 'Produces no output when all entries are invalid' {
                $inputParams = @{
                    InputObject = @(
                        $null
                        [PSCustomObject]@{ Name = 'Joao' }
                        '   '
                    )
                }

                $results = @(ConvertTo-NormalizedMailRecipient @inputParams)
                $results | Should -HaveCount 0
            }
        }
        #endregion

        #region String input
        Context 'String input' {

            It 'Uses the string as the email address' {
                $result = ConvertTo-NormalizedMailRecipient -InputObject 'joao@empresa.com.br'
                $result.Email | Should -Be 'joao@empresa.com.br'
            }

            It 'Sets Name to null for string input' {
                $result = ConvertTo-NormalizedMailRecipient -InputObject 'joao@empresa.com.br'
                $result.Name | Should -BeNullOrEmpty
            }

            It 'Skips whitespace-only string input' {
                $results = @(ConvertTo-NormalizedMailRecipient -InputObject '   ')
                $results | Should -HaveCount 0
            }

            It 'Trims surrounding whitespace from string input' {
                $result = ConvertTo-NormalizedMailRecipient -InputObject '  joao@empresa.com.br  '
                $result.Email | Should -Be 'joao@empresa.com.br'
            }
        }
        #endregion

        #region Object input
        Context 'Object input' {

            It 'Converts an object with Name and Email properties' {
                $obj = [PSCustomObject]@{
                    Name  = 'Joao Silva'
                    Email = 'joao@empresa.com.br'
                }

                $result = ConvertTo-NormalizedMailRecipient -InputObject $obj

                $result.Name  | Should -Be 'Joao Silva'
                $result.Email | Should -Be 'joao@empresa.com.br'
            }

            It 'Converts an object with Email only' {
                $obj = [PSCustomObject]@{
                    Email = 'joao@empresa.com.br'
                }

                $result = ConvertTo-NormalizedMailRecipient -InputObject $obj

                $result.Name  | Should -BeNullOrEmpty
                $result.Email | Should -Be 'joao@empresa.com.br'
            }

            It 'Skips objects without an Email property' {
                $obj = [PSCustomObject]@{
                    Name = 'Joao Silva'
                }

                $results = @(ConvertTo-NormalizedMailRecipient -InputObject $obj)
                $results | Should -HaveCount 0
            }

            It 'Skips objects with a null Email value' {
                $obj = [PSCustomObject]@{
                    Name  = 'Joao'
                    Email = $null
                }

                $results = @(ConvertTo-NormalizedMailRecipient -InputObject $obj)
                $results | Should -HaveCount 0
            }

            It 'Skips objects with whitespace-only Email values' {
                $obj = [PSCustomObject]@{
                    Name  = 'Joao'
                    Email = '   '
                }

                $results = @(ConvertTo-NormalizedMailRecipient -InputObject $obj)
                $results | Should -HaveCount 0
            }

            It 'Trims surrounding whitespace from Email' {
                $obj = [PSCustomObject]@{
                    Name  = 'Joao'
                    Email = '  joao@empresa.com.br  '
                }

                $result = ConvertTo-NormalizedMailRecipient -InputObject $obj
                $result.Email | Should -Be 'joao@empresa.com.br'
            }

            It 'Trims surrounding whitespace from Name' {
                $obj = [PSCustomObject]@{
                    Name  = '  Joao Silva  '
                    Email = 'joao@empresa.com.br'
                }

                $result = ConvertTo-NormalizedMailRecipient -InputObject $obj
                $result.Name | Should -Be 'Joao Silva'
            }

            It 'Converts a non-string Email value to string' {
                $obj = [PSCustomObject]@{
                    Email = 12345
                }

                $result = ConvertTo-NormalizedMailRecipient -InputObject $obj

                $result.Email | Should -Be '12345'
                $result.Email | Should -BeOfType [string]
            }

            It 'Converts a non-string Name value to string' {
                $obj = [PSCustomObject]@{
                    Name  = 12345
                    Email = 'joao@empresa.com.br'
                }

                $result = ConvertTo-NormalizedMailRecipient -InputObject $obj

                $result.Name | Should -Be '12345'
                $result.Name | Should -BeOfType [string]
            }
        }
        #endregion

        #region Mixed input
        Context 'Mixed input' {

            It 'Handles strings and objects together' {
                $inputParams = @{
                    InputObject = @(
                        'maria@empresa.com.br'
                        [PSCustomObject]@{
                            Name  = 'Joao'
                            Email = 'joao@empresa.com.br'
                        }
                    )
                }

                $results = @(ConvertTo-NormalizedMailRecipient @inputParams)

                $results | Should -HaveCount 2

                $results[0].Name  | Should -BeNullOrEmpty
                $results[0].Email | Should -Be 'maria@empresa.com.br'

                $results[1].Name  | Should -Be 'Joao'
                $results[1].Email | Should -Be 'joao@empresa.com.br'
            }

            It 'Skips invalid entries while preserving valid entries' {
                $inputParams = @{
                    InputObject = @(
                        'joao@empresa.com.br'
                        $null
                        ''
                        [PSCustomObject]@{
                            Name = 'Maria'
                        }
                        [PSCustomObject]@{
                            Name  = 'Pedro'
                            Email = 'pedro@empresa.com.br'
                        }
                    )
                }

                $results = @(ConvertTo-NormalizedMailRecipient @inputParams)

                $results | Should -HaveCount 2

                $results[0].Name  | Should -BeNullOrEmpty
                $results[0].Email | Should -Be 'joao@empresa.com.br'

                $results[1].Name  | Should -Be 'Pedro'
                $results[1].Email | Should -Be 'pedro@empresa.com.br'
            }
        }
        #endregion

        #region Pipeline support
        Context 'Pipeline support' {

            It 'Accepts a string from the pipeline' {
                $result = 'joao@empresa.com.br' | ConvertTo-NormalizedMailRecipient
                $result.Email | Should -Be 'joao@empresa.com.br'
            }

            It 'Accepts objects from the pipeline' {
                $obj = [PSCustomObject]@{
                    Name  = 'Joao'
                    Email = 'joao@empresa.com.br'
                }

                $result = $obj | ConvertTo-NormalizedMailRecipient

                $result.Name  | Should -Be 'Joao'
                $result.Email | Should -Be 'joao@empresa.com.br'
            }

            It 'Processes multiple pipeline inputs independently' {
                $inputs = @(
                    'joao@empresa.com.br'
                    'maria@empresa.com.br'
                )

                $results = @($inputs | ConvertTo-NormalizedMailRecipient)

                $results | Should -HaveCount 2
                $results[0].Email | Should -Be 'joao@empresa.com.br'
                $results[1].Email | Should -Be 'maria@empresa.com.br'
            }

            It 'Produces one output for each valid pipeline input' {
                $inputs = @(
                    'joao@empresa.com.br'
                    'maria@empresa.com.br'
                    'pedro@empresa.com.br'
                )

                $results = @($inputs | ConvertTo-NormalizedMailRecipient)
                $results | Should -HaveCount $inputs.Count
            }

            It 'Skips invalid pipeline inputs without affecting valid inputs' {
                $inputs = @(
                    'joao@empresa.com.br'
                    ''
                    '   '
                    [PSCustomObject]@{ Name = 'Invalid' }
                    'maria@empresa.com.br'
                )

                $results = @($inputs | ConvertTo-NormalizedMailRecipient)

                $results | Should -HaveCount 2
                $results[0].Email | Should -Be 'joao@empresa.com.br'
                $results[1].Email | Should -Be 'maria@empresa.com.br'
            }
        }
        #endregion

        #region Output contract
        Context 'Output contract' {

            BeforeAll {

                $obj = [PSCustomObject]@{
                    Name  = 'Joao Silva'
                    Email = 'joao@empresa.com.br'
                }

                $Script:Sample = ConvertTo-NormalizedMailRecipient -InputObject $obj
            }

            It 'Returns a PSCustomObject' {
                $Script:Sample |
                    Should -BeOfType [System.Management.Automation.PSCustomObject]
            }

            It 'Exposes exactly Name and Email properties' {
                $expected = @('Name', 'Email')

                $actual = @($Script:Sample.PSObject.Properties.Name)
                $actual | Should -Be $expected
            }

            It 'Exposes Name as string when provided' {
                $Script:Sample.Name | Should -BeOfType [string]
            }

            It 'Exposes Email as string' {
                $Script:Sample.Email | Should -BeOfType [string]
            }

            It 'Returns no output for invalid input' {
                $inputParams = @{
                    InputObject = [PSCustomObject]@{ Name = 'Invalid' }
                }

                $result = @(ConvertTo-NormalizedMailRecipient @inputParams)
                $result | Should -HaveCount 0
            }
        }
        #endregion
    }
}
