#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for ConvertTo-MailAddress.

.DESCRIPTION
Coverage includes:
  - Email is mandatory.
  - Email accepts pipeline input.
  - Email accepts pipeline property binding.
  - Email allows null and empty values.
  - EmailList is a valid alias for Email.
  - Strict is a switch parameter.
  - Parses a plain email address.
  - Parses a display name format address.
  - Uses the email as Name when no display name exists.
  - Parses comma-separated addresses.
  - Parses semicolon-separated addresses.
  - Parses mixed delimiters.
  - Handles whitespace around delimiters.
  - Normalizes addresses to lowercase.
  - Deduplicates addresses case-insensitively.
  - Deduplicates across pipeline input.
  - Does not leak deduplication state between invocations.
  - Skips null, empty and whitespace-only entries.
  - Skips invalid addresses silently in normal mode.
  - Produces no warning for invalid addresses.
  - Throws InvalidMailAddress in strict mode.
  - Uses InvalidData category in strict mode.
  - Produces a terminating error in strict mode.
  - Returns PSCustomObject output.
  - Exposes exactly Name and Email properties.
  - Exposes Name and Email as strings.
  - Accepts pipeline input.
  - Processes multiple pipeline inputs independently.
#>

# InModuleScope needs to resolve the PipeDFe module during the Discovery phase,
# because that is when Context/It are executed to register the test tree.
# If the module isn't loaded at that point, InModuleScope fails before any
# BeforeAll or BeforeEach can run.
BeforeDiscovery {
    $moduleRoot = (Get-Item $PSScriptRoot).Parent.Parent.Parent.Parent.FullName

    $moduleName = Join-Path -Path $moduleRoot -ChildPath 'PipeDFe.psd1'

    Import-Module -Name $moduleName -Force -Global -ErrorAction Stop
}

Describe 'ConvertTo-MailAddress' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            $Script:Command = Get-Command -Name ConvertTo-MailAddress -ErrorAction Stop
        }

        #region Parameter contract
        Context 'Parameter contract' {

            It 'Declares Email as mandatory' {
                $mandatory = $Script:Command.Parameters['Email'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.Mandatory
                    }

                $mandatory | Should -Not -BeNullOrEmpty
            }

            It 'Accepts Email from the pipeline' {
                $pipeline = $Script:Command.Parameters['Email'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.ValueFromPipeline
                    }

                $pipeline | Should -Not -BeNullOrEmpty
            }

            It 'Accepts Email from pipeline property binding' {
                $propertyBinding = $Script:Command.Parameters['Email'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.ValueFromPipelineByPropertyName
                    }

                $propertyBinding | Should -Not -BeNullOrEmpty
            }

            It 'Allows null values for Email' {
                $allowNull = $Script:Command.Parameters['Email'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.AllowNullAttribute]
                    }

                $allowNull | Should -Not -BeNullOrEmpty
            }

            It 'Allows empty strings for Email' {
                $allowEmpty = $Script:Command.Parameters['Email'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.AllowEmptyStringAttribute]
                    }

                $allowEmpty | Should -Not -BeNullOrEmpty
            }

            It 'Declares Email as a string array' {
                $Script:Command.Parameters['Email'].ParameterType |
                    Should -Be ([string[]])
            }

            It 'Accepts EmailList as alias for Email' {
                $Script:Command.Parameters['Email'].Aliases |
                    Should -Contain 'EmailList'
            }

            It 'Declares Strict as a switch' {
                $Script:Command.Parameters['Strict'].ParameterType |
                    Should -Be ([switch])
            }
        }
        #endregion

        #region Parsing
        Context 'Parsing' {

            It 'Parses a plain email address' {
                $result = ConvertTo-MailAddress -Email 'joao@empresa.com.br'
                $result.Email | Should -Be 'joao@empresa.com.br'
            }

            It 'Parses a display name format address' {
                $result = ConvertTo-MailAddress -Email 'Joao Silva <joao@empresa.com.br>'

                $result.Email | Should -Be 'joao@empresa.com.br'
                $result.Name  | Should -Be 'Joao Silva'
            }

            It 'Preserves the display name' {
                $result = ConvertTo-MailAddress -Email '"Joao Silva" <joao@empresa.com.br>'
                $result.Name | Should -Be 'Joao Silva'
            }

            It 'Uses the email address as Name when no display name is present' {
                $result = ConvertTo-MailAddress -Email 'joao@empresa.com.br'
                $result.Name | Should -Be 'joao@empresa.com.br'
            }

            It 'Parses a comma-separated list in a single string' {
                $results = @(
                    ConvertTo-MailAddress -Email 'joao@empresa.com.br, maria@empresa.com.br'
                )

                $results | Should -HaveCount 2
                $results[0].Email | Should -Be 'joao@empresa.com.br'
                $results[1].Email | Should -Be 'maria@empresa.com.br'
            }

            It 'Parses a semicolon-separated list in a single string' {
                $results = @(
                    ConvertTo-MailAddress -Email 'joao@empresa.com.br; maria@empresa.com.br'
                )

                $results | Should -HaveCount 2
                $results[0].Email | Should -Be 'joao@empresa.com.br'
                $results[1].Email | Should -Be 'maria@empresa.com.br'
            }

            It 'Parses mixed comma and semicolon delimiters' {
                $results = @(
                    ConvertTo-MailAddress -Email 'joao@empresa.com.br, maria@empresa.com.br; ana@empresa.com.br'
                )

                $results | Should -HaveCount 3
            }

            It 'Handles whitespace around delimiters' {
                $results = @(
                    ConvertTo-MailAddress -Email '  joao@empresa.com.br  ;  maria@empresa.com.br  '
                )

                $results | Should -HaveCount 2
            }
        }
        #endregion

        #region Normalization
        Context 'Normalization' {

            It 'Normalizes email addresses to lowercase' {
                $result = ConvertTo-MailAddress -Email 'JOAO@EMPRESA.COM.BR'
                $result.Email | Should -Be 'joao@empresa.com.br'
            }

            It 'Deduplicates addresses case-insensitively' {
                $results = @(
                    'joao@empresa.com.br'
                    'JOAO@EMPRESA.COM.BR'
                ) | ConvertTo-MailAddress

                $results | Should -HaveCount 1
                $results[0].Email | Should -Be 'joao@empresa.com.br'
            }

            It 'Deduplicates addresses within a single input' {
                $results = @(
                    ConvertTo-MailAddress -Email 'joao@empresa.com.br, JOAO@EMPRESA.COM.BR'
                )

                $results | Should -HaveCount 1
            }

            It 'Deduplicates across multiple pipeline inputs' {
                $results = @(
                    'joao@empresa.com.br'
                    'maria@empresa.com.br'
                    'joao@empresa.com.br'
                ) | ConvertTo-MailAddress

                $results | Should -HaveCount 2
                $results.Email | Should -Contain 'joao@empresa.com.br'
                $results.Email | Should -Contain 'maria@empresa.com.br'
            }

            It 'Does not leak deduplication state between invocations' {
                $first  = ConvertTo-MailAddress -Email 'joao@empresa.com.br'
                $second = ConvertTo-MailAddress -Email 'joao@empresa.com.br'

                $first  | Should -HaveCount 1
                $second | Should -HaveCount 1
            }
        }
        #endregion

        #region Invalid input
        Context 'Invalid input' {

            It 'Skips an empty string silently' {
                $results = @(ConvertTo-MailAddress -Email '')
                $results | Should -HaveCount 0
            }

            It 'Skips whitespace-only input silently' {
                $results = @(ConvertTo-MailAddress -Email '   ')
                $results | Should -HaveCount 0
            }

            It 'Skips invalid addresses in normal mode' {
                $results = @(ConvertTo-MailAddress -Email 'not-an-email')

                $results | Should -HaveCount 0
            }

            It 'Does not emit a warning for an invalid address' {
                $warnings = @()

                ConvertTo-MailAddress -Email 'not-an-email' -WarningVariable warnings | Out-Null

                $warnings | Should -HaveCount 0
            }

            It 'Skips invalid addresses while preserving valid addresses' {
                $results = @(
                    ConvertTo-MailAddress -Email 'valid@example.com; invalid'
                )

                $results | Should -HaveCount 1
                $results[0].Email | Should -Be 'valid@example.com'
            }

            It 'Throws InvalidMailAddress in strict mode' {
                $thrown = $null

                try {
                    ConvertTo-MailAddress -Email 'not-an-email' -Strict -ErrorAction Stop
                } catch {
                    $thrown = $_
                }

                $thrown | Should -Not -BeNullOrEmpty
                $thrown.FullyQualifiedErrorId | Should -BeLike 'InvalidMailAddress*'
            }

            It 'Uses InvalidData category in strict mode' {
                $thrown = $null

                try {
                    ConvertTo-MailAddress -Email 'not-an-email' -Strict -ErrorAction Stop
                } catch {
                    $thrown = $_
                }

                $thrown.CategoryInfo.Category |
                    Should -Be ([System.Management.Automation.ErrorCategory]::InvalidData)
            }

            It 'Throws a terminating error in strict mode' {
                $thrown = $null

                try {
                    ConvertTo-MailAddress -Email 'not-an-email' -Strict -ErrorAction Stop
                } catch {
                    $thrown = $_
                }

                $thrown | Should -Not -BeNullOrEmpty
                $thrown.FullyQualifiedErrorId | Should -BeLike 'InvalidMailAddress,*'
            }

            It 'Skips empty entries between delimiters' {
                $params = @{
                    Email = 'joao@empresa.com.br,,; ;maria@empresa.com.br'
                }

                $results = @(ConvertTo-MailAddress @params)
                $results | Should -HaveCount 2
            }
        }
        #endregion

        #region Pipeline support
        Context 'Pipeline support' {

            It 'Accepts Email from the pipeline' {
                $result = 'joao@empresa.com.br' | ConvertTo-MailAddress
                $result.Email | Should -Be 'joao@empresa.com.br'
            }

            It 'Processes multiple pipeline inputs independently' {
                $results = @(
                    'joao@empresa.com.br'
                    'maria@empresa.com.br'
                ) | ConvertTo-MailAddress

                $results | Should -HaveCount 2
                $results[0].Email | Should -Be 'joao@empresa.com.br'
                $results[1].Email | Should -Be 'maria@empresa.com.br'
            }

            It 'Deduplicates multiple pipeline inputs globally' {
                $results = @(
                    'joao@empresa.com.br'
                    'JOAO@EMPRESA.COM.BR'
                    'maria@empresa.com.br'
                ) | ConvertTo-MailAddress

                $results | Should -HaveCount 2
            }

            It 'Accepts pipeline property binding' {
                $inputObject = [PSCustomObject]@{
                    Email = 'joao@empresa.com.br'
                }

                $result = $inputObject | ConvertTo-MailAddress
                $result.Email | Should -Be 'joao@empresa.com.br'
            }

            It 'Produces one object for each unique valid address' {
                $results = @(
                    'joao@empresa.com.br'
                    'maria@empresa.com.br'
                    'JOAO@EMPRESA.COM.BR'
                ) | ConvertTo-MailAddress

                $results | Should -HaveCount 2
            }
        }
        #endregion

        #region Output contract
        Context 'Output contract' {

            BeforeAll {

                $Script:Sample = ConvertTo-MailAddress -Email 'Joao Silva <joao@empresa.com.br>'
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

            It 'Exposes Name as string' {
                $Script:Sample.Name | Should -BeOfType [string]
            }

            It 'Exposes Email as string' {
                $Script:Sample.Email | Should -BeOfType [string]
            }

            It 'Returns normalized lowercase Email' {
                $Script:Sample.Email | Should -Be 'joao@empresa.com.br'
            }

            It 'Returns the expected display Name' {
                $Script:Sample.Name | Should -Be 'Joao Silva'
            }
        }
        #endregion
    }
}
