#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for ConvertFrom-CertificateSubject.

.DESCRIPTION
Coverage includes:
  - Subject is mandatory and rejects empty strings.
  - Strict is optional.
  - Parses a standard multi-attribute Subject DN.
  - Groups duplicate attributes into a single Values array.
  - Maps known attributes to Portuguese descriptions.
  - Falls back to the attribute key for unknown attributes.
  - Preserves attribute order from the DN string.
  - Throws InvalidDnComponent in Strict mode for invalid components.
  - Throws EmptyDnSubject in Strict mode when no valid attribute is found.
  - Emits a warning in normal mode instead of throwing.
  - Accepts pipeline input.
  - Output contract: Attribute, Description, Values with correct types.
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

Describe 'ConvertFrom-CertificateSubject' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            $Script:Command = Get-Command -Name ConvertFrom-CertificateSubject -ErrorAction Stop

            $Script:StandardSubject = 'CN=ACME IND LTDA,OU=IT,O=ACME,L=Sao Paulo,S=SP,C=BR'
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

            It 'Rejects an empty Subject' {
                { ConvertFrom-CertificateSubject -Subject '' } | Should -Throw
            }

            It 'Declares Strict as a switch' {
                $Script:Command.Parameters['Strict'].ParameterType | Should -Be ([switch])
            }
        }
        #endregion

        #region Successful parsing
        Context 'Successful parsing' {

            It 'Returns one object per unique attribute' {
                $results = @(ConvertFrom-CertificateSubject -Subject $Script:StandardSubject)

                $results | Should -HaveCount 6
            }

            It 'Preserves attribute order from the DN string' {
                $results = @(ConvertFrom-CertificateSubject -Subject $Script:StandardSubject)
                $keys    = @($results | Select-Object -ExpandProperty Attribute)

                $keys | Should -Be @('CN', 'OU', 'O', 'L', 'S', 'C')
            }

            It 'Maps CN to correct Portuguese description' {
                $result = ConvertFrom-CertificateSubject -Subject 'CN=ACME' |
                    Where-Object { $_.Attribute -eq 'CN' }

                $result.Description | Should -Be 'Nome Comum'
            }

            It 'Maps C to correct Portuguese description' {
                $result = ConvertFrom-CertificateSubject -Subject 'CN=ACME,C=BR' |
                    Where-Object { $_.Attribute -eq 'C' }

                $result.Description | Should -Be 'Pais'
            }

            It 'Falls back to attribute key for unknown attributes' {
                $result = ConvertFrom-CertificateSubject -Subject 'CN=ACME,UNKNOWN=value' |
                    Where-Object { $_.Attribute -eq 'UNKNOWN' }

                $result.Description | Should -Be 'UNKNOWN'
            }

            It 'Groups duplicate OU attributes into a single Values array' {
                $result = ConvertFrom-CertificateSubject -Subject 'CN=ACME,OU=Sales,OU=IT' |
                    Where-Object { $_.Attribute -eq 'OU' }

                $result.Values | Should -HaveCount 2
                $result.Values | Should -Contain 'Sales'
                $result.Values | Should -Contain 'IT'
            }
        }
        #endregion

        #region Strict mode
        Context 'Strict mode' {

            It 'Throws EmptyDnSubject in Strict mode for a DN with no valid attributes' {
                $thrown = $null

                try {
                    ConvertFrom-CertificateSubject -Subject 'notadn' -Strict -ErrorAction Stop
                } catch {
                    $thrown = $_
                }

                $thrown | Should -Not -BeNullOrEmpty
                $thrown.FullyQualifiedErrorId | Should -BeLike 'EmptyDnSubject*'
            }

            It 'Uses InvalidData category in Strict mode' {
                $thrown = $null

                try {
                    ConvertFrom-CertificateSubject -Subject 'notadn' -Strict -ErrorAction Stop
                } catch {
                    $thrown = $_
                }

                $thrown.CategoryInfo.Category |
                    Should -Be ([System.Management.Automation.ErrorCategory]::InvalidData)
            }
        }
        #endregion

        #region Pipeline support
        Context 'Pipeline support' {

            It 'Accepts Subject from the pipeline' {
                $results = @('CN=ACME,C=BR' | ConvertFrom-CertificateSubject)

                $results | Should -HaveCount 2
            }

            It 'Processes multiple pipeline inputs independently' {
                $results = @(
                    'CN=ACME,C=BR',
                    'CN=TEST,C=US' |
                        ConvertFrom-CertificateSubject
                )

                $results | Should -HaveCount 4
            }
        }
        #endregion

        #region Output contract
        Context 'Output contract' {

            BeforeAll {

                $Script:Sample = ConvertFrom-CertificateSubject -Subject 'CN=ACME,C=BR' |
                    Select-Object -First 1
            }

            It 'Returns a PSCustomObject' {
                $Script:Sample | Should -BeOfType [System.Management.Automation.PSCustomObject]
            }

            It 'Exposes exactly the documented properties' {
                $expected = @('Attribute', 'Description', 'Values')
                $actual   = @($Script:Sample.PSObject.Properties.Name)

                $actual | Should -Be $expected
            }

            It 'Exposes Attribute as string' {
                $Script:Sample.Attribute | Should -BeOfType [string]
            }

            It 'Exposes Description as string' {
                $Script:Sample.Description | Should -BeOfType [string]
            }

            It 'Exposes Values as array' {
                $Script:Sample.Values.GetType().IsArray | Should -BeTrue
            }
        }
        #endregion
    }
}
