#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for Resolve-IcpBrasilSubject.

.DESCRIPTION
Coverage includes:
  Parameter contract:
    - Subject is mandatory.
    - Subject accepts pipeline input.
    - Subject rejects empty strings.

  CN resolution:
    - Returns null fields when CN is absent.
    - Returns the raw CN as TitularNome without a document separator.
    - Uses the first CN attribute.

  CPF identification:
    - Identifies an 11-digit CPF.
    - Preserves the raw CPF.
    - Preserves the titular name.
    - Supports CPF with birth-date segment.

  CNPJ identification:
    - Identifies a 14-digit numeric CNPJ.
    - Identifies uppercase alphanumeric CNPJ.
    - Rejects lowercase alphanumeric CNPJ.
    - Rejects invalid CNPJ length.
    - Rejects invalid CNPJ characters.

  Invalid documents:
    - Preserves unknown document values.
    - Leaves TipoDocumento null for unknown formats.
    - Preserves an empty document segment.

  Output contract:
    - Returns a PSCustomObject.
    - Exposes exactly the documented properties.
    - Exposes documented values as strings when present.

  Pipeline:
    - Accepts a single Subject from the pipeline.
    - Processes multiple Subject values independently.
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

Describe 'Resolve-IcpBrasilSubject' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            $Script:Command = Get-Command -Name Resolve-IcpBrasilSubject -ErrorAction Stop
        }

        #region Parameter contract
        Context 'Parameter contract' {

            It 'Declares Subject as mandatory' {
                $mandatory = $Script:Command.Parameters['Subject'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.Mandatory
                    }

                $mandatory | Should -Not -BeNullOrEmpty
            }

            It 'Accepts Subject from the pipeline' {
                $parameter = $Script:Command.Parameters['Subject']

                $parameter.Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.ValueFromPipeline
                    } |

                    Should -Not -BeNullOrEmpty
            }

            It 'Rejects an empty Subject' {
                { Resolve-IcpBrasilSubject -Subject '' } | Should -Throw
            }

            It 'Rejects a null Subject' {
                { Resolve-IcpBrasilSubject -Subject $null } | Should -Throw
            }
        }
        #endregion

        #region No CN attribute
        Context 'No CN attribute' {

            It 'Returns null TitularNome when CN is absent' {
                $result = Resolve-IcpBrasilSubject -Subject 'O=ICP-Brasil,C=BR'
                $result.TitularNome | Should -BeNullOrEmpty
            }

            It 'Returns null TitularDocumento when CN is absent' {
                $result = Resolve-IcpBrasilSubject -Subject 'O=ICP-Brasil,C=BR'
                $result.TitularDocumento | Should -BeNullOrEmpty
            }

            It 'Returns null TipoDocumento when CN is absent' {
                $result = Resolve-IcpBrasilSubject -Subject 'O=ICP-Brasil,C=BR'
                $result.TipoDocumento | Should -BeNullOrEmpty
            }
        }
        #endregion

        #region CN without document
        Context 'CN without document' {

            It 'Returns the raw CN as TitularNome' {
                $subject = @{
                    Subject = 'CN=Equipment Certificate,O=ICP-Brasil'
                }

                $result = Resolve-IcpBrasilSubject @subject
                $result.TitularNome | Should -Be 'Equipment Certificate'
            }

            It 'Returns null TitularDocumento' {
                $subject = @{
                    Subject = 'CN=Equipment Certificate,O=ICP-Brasil'
                }

                $result = Resolve-IcpBrasilSubject @subject
                $result.TitularDocumento | Should -BeNullOrEmpty
            }

            It 'Returns null TipoDocumento' {
                $subject = @{
                    Subject = 'CN=Equipment Certificate,O=ICP-Brasil'
                }

                $result = Resolve-IcpBrasilSubject @subject
                $result.TipoDocumento | Should -BeNullOrEmpty
            }

            It 'Trims the raw CN when no document separator exists' {
                $subject = @{
                    Subject = 'CN=  Equipment Certificate  ,O=ICP-Brasil'
                }

                $result = Resolve-IcpBrasilSubject @subject
                $result.TitularNome | Should -Be 'Equipment Certificate'
            }
        }
        #endregion

        #region CPF identification
        Context 'CPF identification' {

            It 'Identifies an 11-digit CPF' {
                $subject = @{
                    Subject = 'CN=JOAO DA SILVA:12345678900,O=ICP-Brasil,C=BR'
                }

                $result = Resolve-IcpBrasilSubject @subject
                $result.TipoDocumento | Should -Be 'CPF'
            }

            It 'Returns the correct titular name' {
                $subject = @{
                    Subject = 'CN=JOAO DA SILVA:12345678900,O=ICP-Brasil,C=BR'
                }

                $result = Resolve-IcpBrasilSubject @subject
                $result.TitularNome | Should -Be 'JOAO DA SILVA'
            }

            It 'Preserves the raw CPF' {
                $subject = @{
                    Subject = 'CN=JOAO DA SILVA:12345678900,O=ICP-Brasil,C=BR'
                }

                $result = Resolve-IcpBrasilSubject @subject
                $result.TitularDocumento | Should -Be '12345678900'
            }

            It 'Handles CPF with birth-date segment' {
                $subject = @{
                    Subject = 'CN=JOAO DA SILVA:12345678900:01011980,O=ICP-Brasil,C=BR'
                }

                $result = Resolve-IcpBrasilSubject @subject

                $result.TipoDocumento    | Should -Be 'CPF'
                $result.TitularDocumento | Should -Be '12345678900'
            }

            It 'Ignores the birth-date segment for document classification' {
                $subject = @{
                    Subject = 'CN=MARIA SILVA:98765432100:31121990,O=ICP-Brasil,C=BR'
                }

                $result = Resolve-IcpBrasilSubject @subject
                $result.TipoDocumento | Should -Be 'CPF'
            }

            It 'Trims whitespace around the CPF' {
                $subject = @{
                    Subject = 'CN=JOAO DA SILVA: 12345678900 ,O=ICP-Brasil,C=BR'
                }

                $result = Resolve-IcpBrasilSubject @subject

                $result.TitularDocumento | Should -Be '12345678900'
                $result.TipoDocumento    | Should -Be 'CPF'
            }
        }
        #endregion

        #region CNPJ identification
        Context 'CNPJ identification' {

            It 'Identifies a 14-digit numeric CNPJ' {
                $subject = @{
                    Subject = 'CN=ACME LTDA:12345678000195,O=ICP-Brasil,C=BR'
                }

                $result = Resolve-IcpBrasilSubject @subject
                $result.TipoDocumento | Should -Be 'CNPJ'
            }

            It 'Returns the correct titular name' {
                $subject = @{
                    Subject = 'CN=ACME LTDA:12345678000195,O=ICP-Brasil,C=BR'
                }

                $result = Resolve-IcpBrasilSubject @subject
                $result.TitularNome | Should -Be 'ACME LTDA'
            }

            It 'Preserves the raw CNPJ' {
                $subject = @{
                    Subject = 'CN=ACME LTDA:12345678000195,O=ICP-Brasil,C=BR'
                }

                $result = Resolve-IcpBrasilSubject @subject
                $result.TitularDocumento | Should -Be '12345678000195'
            }

            It 'Identifies an uppercase alphanumeric CNPJ' {
                $subject = @{
                    Subject = 'CN=ACME LTDA:AB1CD2EF3GH4I5,O=ICP-Brasil,C=BR'
                }

                $result = Resolve-IcpBrasilSubject @subject
                $result.TipoDocumento | Should -Be 'CNPJ'
            }

            It 'Preserves an uppercase alphanumeric CNPJ exactly' {
                $subject = @{
                    Subject = 'CN=ACME LTDA:AB1CD2EF3GH4I5,O=ICP-Brasil,C=BR'
                }

                $result = Resolve-IcpBrasilSubject @subject
                $result.TitularDocumento | Should -Be 'AB1CD2EF3GH4I5'
            }

            It 'Does not classify lowercase alphanumeric CNPJ' {
                $subject = @{
                    Subject = 'CN=ACME LTDA:ab1cd2ef3gh4i5,O=ICP-Brasil,C=BR'
                }

                $result = Resolve-IcpBrasilSubject @subject
                $result.TipoDocumento | Should -BeNullOrEmpty
            }

            It 'Rejects CNPJ with fewer than 14 characters' {
                $subject = @{
                    Subject = 'CN=ACME LTDA:AB1CD2EF3GH4I,O=ICP-Brasil,C=BR'
                }

                $result = Resolve-IcpBrasilSubject @subject
                $result.TipoDocumento | Should -BeNullOrEmpty
            }

            It 'Rejects CNPJ with more than 14 characters' {
                $subject = @{
                    Subject = 'CN=ACME LTDA:AB1CD2EF3GH4I56,O=ICP-Brasil,C=BR'
                }

                $result = Resolve-IcpBrasilSubject @subject
                $result.TipoDocumento | Should -BeNullOrEmpty
            }

            It 'Rejects alphanumeric CNPJ containing lowercase characters' {
                $subject = @{
                    Subject = 'CN=ACME LTDA:AB1cd2EF3GH4I5,O=ICP-Brasil,C=BR'
                }

                $result = Resolve-IcpBrasilSubject @subject
                $result.TipoDocumento | Should -BeNullOrEmpty
            }

            It 'Rejects CNPJ containing punctuation' {
                $subject = @{
                    Subject = 'CN=ACME LTDA:AB1-CD2EF3GH4I5,O=ICP-Brasil,C=BR'
                }

                $result = Resolve-IcpBrasilSubject @subject
                $result.TipoDocumento | Should -BeNullOrEmpty
            }
        }
        #endregion

        #region Unrecognized document
        Context 'Unrecognized document' {

            It 'Leaves TipoDocumento null for an unknown value' {
                $subject = @{
                    Subject = 'CN=ACME LTDA:UNKNOWN,O=ICP-Brasil,C=BR'
                }

                $result = Resolve-IcpBrasilSubject @subject
                $result.TipoDocumento | Should -BeNullOrEmpty
            }

            It 'Preserves an unknown document value' {
                $subject = @{
                    Subject = 'CN=ACME LTDA:UNKNOWN,O=ICP-Brasil,C=BR'
                }

                $result = Resolve-IcpBrasilSubject @subject
                $result.TitularDocumento | Should -Be 'UNKNOWN'
            }

            It 'Preserves an empty document segment' {
                $subject = @{
                    Subject = 'CN=ACME LTDA:,O=ICP-Brasil,C=BR'
                }

                $result = Resolve-IcpBrasilSubject @subject

                $result.TitularNome      | Should -Be 'ACME LTDA'
                $result.TitularDocumento | Should -Be ''
                $result.TipoDocumento    | Should -BeNullOrEmpty
            }

            It 'Does not classify a decimal-formatted CPF' {
                $subject = @{

                }

                $result = Resolve-IcpBrasilSubject -Subject 'CN=JOAO DA SILVA:123.456.789-00,O=ICP-Brasil,C=BR'

                $result.TipoDocumento    | Should -BeNullOrEmpty
                $result.TitularDocumento | Should -Be '123.456.789-00'
            }

            It 'Does not classify a formatted CNPJ' {
                $subject = @{

                }

                $result = Resolve-IcpBrasilSubject -Subject 'CN=ACME LTDA:12.345.678/0001-95,O=ICP-Brasil,C=BR'

                $result.TipoDocumento    | Should -BeNullOrEmpty
                $result.TitularDocumento | Should -Be '12.345.678/0001-95'
            }
        }
        #endregion

        #region Multiple CN attributes
        Context 'Multiple CN attributes' {

            It 'Uses the first CN attribute' {
                $subject = @{

                }

                $result = Resolve-IcpBrasilSubject -Subject 'CN=FIRST:12345678900,CN=SECOND:12345678000195,O=ICP-Brasil'

                $result.TitularNome      | Should -Be 'FIRST'
                $result.TitularDocumento | Should -Be '12345678900'
                $result.TipoDocumento    | Should -Be 'CPF'
            }
        }
        #endregion

        #region Output contract
        Context 'Output contract' {

            BeforeAll {

                $subject = @{
                    Subject = 'CN=ACME LTDA:12345678000195,O=ICP-Brasil,C=BR'
                }

                $Script:Sample = Resolve-IcpBrasilSubject @subject
            }

            It 'Returns a PSCustomObject' {
                $Script:Sample | Should -BeOfType [System.Management.Automation.PSCustomObject]
            }

            It 'Exposes exactly the documented properties' {
                $expected = @('TitularNome', 'TitularDocumento', 'TipoDocumento')

                $actual = @($Script:Sample.PSObject.Properties.Name)
                $actual | Should -Be $expected
            }

            It 'Exposes TitularNome as string' {
                $Script:Sample.TitularNome | Should -BeOfType [string]
            }

            It 'Exposes TitularDocumento as string' {
                $Script:Sample.TitularDocumento | Should -BeOfType [string]
            }

            It 'Exposes TipoDocumento as string' {
                $Script:Sample.TipoDocumento | Should -BeOfType [string]
            }

            It 'Returns null values with the expected properties when CN is absent' {
                $result = Resolve-IcpBrasilSubject -Subject 'O=ICP-Brasil,C=BR'

                @($result.PSObject.Properties.Name) |
                    Should -Be @('TitularNome', 'TitularDocumento', 'TipoDocumento')

                $result.TitularNome      | Should -BeNullOrEmpty
                $result.TitularDocumento | Should -BeNullOrEmpty
                $result.TipoDocumento    | Should -BeNullOrEmpty
            }
        }
        #endregion

        #region Pipeline support
        Context 'Pipeline support' {

            It 'Accepts Subject from the pipeline' {
                $result = 'CN=ACME LTDA:12345678000195,O=ICP-Brasil,C=BR' |
                    Resolve-IcpBrasilSubject

                $result.TipoDocumento | Should -Be 'CNPJ'
            }

            It 'Processes multiple pipeline inputs independently' {
                $subjects = @(
                    'CN=ACME LTDA:12345678000195,O=ICP-Brasil,C=BR'
                    'CN=JOAO DA SILVA:12345678900,O=ICP-Brasil,C=BR'
                )

                $results = @($subjects | Resolve-IcpBrasilSubject)
                $results | Should -HaveCount 2

                $results[0].TipoDocumento | Should -Be 'CNPJ'
                $results[1].TipoDocumento | Should -Be 'CPF'
            }

            It 'Maintains input order across pipeline processing' {
                $subjects = @(
                    'CN=FIRST:12345678900,O=ICP-Brasil,C=BR'
                    'CN=SECOND:12345678000195,O=ICP-Brasil,C=BR'
                    'CN=THIRD:AB1CD2EF3GH4I5,O=ICP-Brasil,C=BR'
                )

                $results = @($subjects | Resolve-IcpBrasilSubject)
                $results | Should -HaveCount 3

                $results[0].TitularNome | Should -Be 'FIRST'
                $results[1].TitularNome | Should -Be 'SECOND'
                $results[2].TitularNome | Should -Be 'THIRD'
            }
        }
        #endregion
    }
}
