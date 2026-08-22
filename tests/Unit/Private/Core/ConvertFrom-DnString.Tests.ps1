#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for ConvertFrom-DnString.

.DESCRIPTION
Coverage includes:
  Parameter contract:
    - InputObject is mandatory.
    - InputObject rejects null and empty values.

  Basic parsing:
    - Parses a single attribute.
    - Parses comma-separated attributes.
    - Parses plus-separated attributes.
    - Emits duplicate attributes independently.

  Attribute normalization:
    - Normalizes attribute keys to uppercase.
    - Trims whitespace from keys and values.

  Escaping:
    - Handles escaped punctuation.
    - Handles escaped comma.
    - Handles escaped plus.
    - Handles escaped backslash.
    - Handles escaped quote.
    - Handles hexadecimal ASCII escapes.

  UTF-8:
    - Decodes UTF-8 hexadecimal escapes.
    - Decodes multiple UTF-8 characters.
    - Preserves ordinary Unicode characters.
    - Handles mixed escaped and literal content.

  Quoted values:
    - Allows commas inside quoted values.
    - Allows plus signs inside quoted values.

  Edge cases:
    - Handles trailing backslash.
    - Skips empty attribute values.

  Output contract:
    - Returns PSCustomObject.
    - Exposes Key as string.
    - Exposes Value as string.

  Pipeline:
    - Accepts pipeline input.
    - Processes multiple pipeline inputs independently.
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

Describe 'ConvertFrom-DnString' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            $Script:Command = Get-Command -Name ConvertFrom-DnString -ErrorAction Stop
        }

        #region Parameter contract
        Context 'Parameter contract' {

            It 'Declares InputObject as mandatory' {
                $mandatory = $Script:Command.Parameters['InputObject'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.Mandatory
                    }

                $mandatory | Should -Not -BeNullOrEmpty
            }

            It 'Rejects an empty InputObject' {
                { ConvertFrom-DnString -InputObject '' } | Should -Throw
            }

            It 'Rejects a null InputObject' {
                { ConvertFrom-DnString -InputObject $null } | Should -Throw
            }
        }
        #endregion

        #region Basic parsing
        Context 'Basic parsing' {

            It 'Parses a single attribute' {
                $results = @(ConvertFrom-DnString -InputObject 'CN=ACME LTDA')

                $results | Should -HaveCount 1

                $results[0].Key   | Should -Be 'CN'
                $results[0].Value | Should -Be 'ACME LTDA'
            }

            It 'Parses comma-separated attributes' {
                $results = @(ConvertFrom-DnString -InputObject 'CN=ACME,O=ICP-Brasil,C=BR')

                $results | Should -HaveCount 3

                $results[0].Key   | Should -Be 'CN'
                $results[0].Value | Should -Be 'ACME'

                $results[1].Key   | Should -Be 'O'
                $results[1].Value | Should -Be 'ICP-Brasil'

                $results[2].Key   | Should -Be 'C'
                $results[2].Value | Should -Be 'BR'
            }

            It 'Parses plus-separated attributes' {
                $results = @(ConvertFrom-DnString -InputObject 'CN=ACME+OU=IT')

                $results | Should -HaveCount 2

                $results[0].Key   | Should -Be 'CN'
                $results[0].Value | Should -Be 'ACME'

                $results[1].Key   | Should -Be 'OU'
                $results[1].Value | Should -Be 'IT'
            }

            It 'Emits duplicate attributes independently' {
                $results = @(ConvertFrom-DnString -InputObject 'OU=Sales,OU=IT,C=BR')

                $ouResults = @( $results | Where-Object { $_.Key -eq 'OU' })

                $ouResults | Should -HaveCount 2

                $ouResults[0].Value | Should -Be 'Sales'
                $ouResults[1].Value | Should -Be 'IT'
            }
        }
        #endregion

        #region Attribute normalization
        Context 'Attribute normalization' {

            It 'Normalizes attribute keys to uppercase' {
                $results = @(ConvertFrom-DnString -InputObject 'cn=test')

                $results[0].Key | Should -Be 'CN'
            }

            It 'Trims whitespace from keys and values' {
                $results = @(ConvertFrom-DnString -InputObject ' CN = ACME LTDA ')

                $results[0].Key   | Should -Be 'CN'
                $results[0].Value | Should -Be 'ACME LTDA'
            }

            It 'Preserves internal whitespace in values' {
                $results = @(ConvertFrom-DnString -InputObject 'CN=ACME   LTDA,O=Test')

                $results[0].Value | Should -Be 'ACME   LTDA'
            }
        }
        #endregion

        #region Escaping
        Context 'Escaping' {

            It 'Handles an escaped comma' {
                $results = @(ConvertFrom-DnString -InputObject 'CN=Smith\, John,C=BR')

                $results | Should -HaveCount 2

                $results[0].Value | Should -Be 'Smith, John'
            }

            It 'Handles an escaped plus sign' {
                $results = @(ConvertFrom-DnString -InputObject 'CN=ACME\+Partners,C=BR')

                $results | Should -HaveCount 2

                $results[0].Value | Should -Be 'ACME+Partners'
            }

            It 'Handles an escaped backslash' {
                $results = @(ConvertFrom-DnString -InputObject 'CN=ACME\\LTDA,C=BR')

                $results | Should -HaveCount 2

                $results[0].Value | Should -Be 'ACME\LTDA'
            }

            It 'Handles an escaped quote' {
                $results = @(ConvertFrom-DnString -InputObject 'CN=ACME\"LTDA,C=BR')

                $results | Should -HaveCount 2

                $results[0].Value | Should -Be 'ACME"LTDA'
            }

            It 'Handles hexadecimal ASCII escape' {
                $results = @(ConvertFrom-DnString -InputObject 'CN=ACM\45,C=BR')

                $results | Should -HaveCount 2

                $results[0].Value | Should -Be 'ACME'
            }
        }
        #endregion

        #region UTF-8
        Context 'UTF-8 hexadecimal escapes' {

            It 'Decodes a UTF-8 accented character' {
                $results = @(ConvertFrom-DnString -InputObject 'CN=Caf\C3\A9,C=BR')

                $results | Should -HaveCount 2

                $results[0].Value | Should -Be 'Café'
            }

            It 'Decodes multiple UTF-8 characters' {
                $results = @(ConvertFrom-DnString -InputObject 'CN=Jo\C3\A3o,C=BR')

                $results | Should -HaveCount 2

                $results[0].Value | Should -Be 'João'
            }

            It 'Decodes a Portuguese UTF-8 value' {
                $results = @(ConvertFrom-DnString -InputObject 'CN=Jos\C3\A9 da Silva,C=BR')

                $results | Should -HaveCount 2

                $results[0].Value | Should -Be 'José da Silva'
            }

            It 'Decodes a multi-byte UTF-8 character' {
                $results = @(ConvertFrom-DnString -InputObject 'CN=Ol\C3\A1 Mundo,C=BR')

                $results[0].Value | Should -Be 'Olá Mundo'
            }

            It 'Handles mixed escaped and literal UTF-8 content' {
                $results = @(ConvertFrom-DnString -InputObject 'CN=ACME Caf\C3\A9 LTDA,C=BR')

                $results | Should -HaveCount 2

                $results[0].Value | Should -Be 'ACME Café LTDA'
            }
        }
        #endregion

        #region Quoted values
        Context 'Quoted values' {

            It 'Allows commas inside quoted values' {
                $results = @(ConvertFrom-DnString -InputObject 'CN="Smith, John",C=BR')

                $results | Should -HaveCount 2

                $results[0].Value | Should -Be 'Smith, John'
            }

            It 'Allows plus signs inside quoted values' {
                $results = @(ConvertFrom-DnString -InputObject 'CN="ACME+Partners",C=BR')

                $results | Should -HaveCount 2

                $results[0].Value | Should -Be 'ACME+Partners'
            }
        }
        #endregion

        #region Edge cases
        Context 'Edge cases' {

            It 'Preserves a trailing backslash' {
                $results = @(ConvertFrom-DnString -InputObject 'CN=Test\')

                $results | Should -HaveCount 1

                $results[0].Value | Should -Be 'Test\'
            }

            It 'Skips attributes with empty values' {
                $results = @(ConvertFrom-DnString -InputObject 'CN=,C=BR')

                $results | Should -HaveCount 1

                $results[0].Key   | Should -Be 'C'
                $results[0].Value | Should -Be 'BR'
            }

            It 'Skips whitespace-only values' {
                $results = @(ConvertFrom-DnString -InputObject 'CN=   ,C=BR')

                $results | Should -HaveCount 1

                $results[0].Key | Should -Be 'C'
            }
        }
        #endregion

        #region Output contract
        Context 'Output contract' {

            BeforeAll {

                $Script:Sample = ConvertFrom-DnString -InputObject 'CN=ACME,C=BR' |
                    Select-Object -First 1
            }

            It 'Returns a PSCustomObject' {
                $Script:Sample |
                    Should -BeOfType [System.Management.Automation.PSCustomObject]
            }

            It 'Exposes Key as string' {
                $Script:Sample.Key | Should -BeOfType [string]
            }

            It 'Exposes Value as string' {
                $Script:Sample.Value | Should -BeOfType [string]
            }

            It 'Exposes exactly the documented properties' {
                @($Script:Sample.PSObject.Properties.Name) |
                    Should -Be @('Key', 'Value')
            }
        }
        #endregion

        #region Pipeline support
        Context 'Pipeline support' {

            It 'Accepts InputObject from the pipeline' {
                $results = @('CN=ACME,C=BR' | ConvertFrom-DnString)

                $results | Should -HaveCount 2
            }

            It 'Processes multiple pipeline inputs independently' {
                $results = @(
                    'CN=ACME'  | ConvertFrom-DnString
                    'CN=OTHER' |ConvertFrom-DnString
                )

                $results | Should -HaveCount 2

                $results[0].Value | Should -Be 'ACME'
                $results[1].Value | Should -Be 'OTHER'
            }
        }
        #endregion
    }
}
