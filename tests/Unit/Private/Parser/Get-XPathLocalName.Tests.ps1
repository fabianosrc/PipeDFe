#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for Get-XPathLocalName.

.DESCRIPTION
Validates extraction of the target element local name from XPath
expressions, including namespace handling, predicates, invalid input,
parameter metadata, and function metadata.

Contexts:
  Happy path         - valid XPath expressions
  Edge cases         - invalid or unsupported XPath expressions
  Parameter behavior - mandatory parameter validation
  Function metadata  - CmdletBinding, OutputType and help metadata
  Parameter metadata - parameter attributes and validation
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

Describe 'Get-XPathLocalName' {

    InModuleScope -ModuleName PipeDFe {

        Context 'Happy path' {

            It 'returns the element name for a simple XPath' {
                Get-XPathLocalName -XPath 'emit' | Should -Be 'emit'
            }

            It 'returns the last element in a relative path' {
                Get-XPathLocalName -XPath 'infNFe/emit/xNome' | Should -Be 'xNome'
            }

            It 'returns the last element in an absolute path' {
                Get-XPathLocalName -XPath '/infNFe/emit/xNome' | Should -Be 'xNome'
            }

            It 'returns the last element in a descendant path' {
                Get-XPathLocalName -XPath '//infNFe/emit/xNome' | Should -Be 'xNome'
            }

            It 'removes namespace prefixes' {
                Get-XPathLocalName -XPath 'nfe:infNFe/nfe:emit/nfe:xNome' | Should -Be 'xNome'
            }

            It 'ignores attribute predicates' {
                Get-XPathLocalName -XPath '//emit[@Id="1"]' | Should -Be 'emit'
            }

            It 'ignores numeric predicates' {
                Get-XPathLocalName -XPath 'root/item[2]' | Should -Be 'item'
            }

            It 'ignores function predicates' {
                Get-XPathLocalName -XPath 'root/item[position()=1]' | Should -Be 'item'
            }

            It 'returns the last element after predicates' {
                Get-XPathLocalName -XPath 'root/item[@Id="1"]/value' | Should -Be 'value'
            }

            It 'handles wildcard segments' {
                Get-XPathLocalName -XPath 'root/*/value' | Should -Be 'value'
            }
        }

        Context 'Edge cases' {

            It 'returns null for a root slash' {
                Get-XPathLocalName -XPath '/' | Should -BeNullOrEmpty
            }

            It 'returns null for descendant operator only' {
                Get-XPathLocalName -XPath '//' | Should -BeNullOrEmpty
            }

            It 'returns null for an attribute XPath' {
                Get-XPathLocalName -XPath '@Id' | Should -BeNullOrEmpty
            }

            It 'returns null for an absolute attribute XPath' {
                Get-XPathLocalName -XPath '/@Id' | Should -BeNullOrEmpty
            }

            It 'returns null for a predicate only' {
                Get-XPathLocalName -XPath '[@Id]' | Should -BeNullOrEmpty
            }
        }

        Context 'Parameter behavior' {

            It 'requires the XPath parameter' {
                $parameter = (Get-Command Get-XPathLocalName).Parameters['XPath']

                $parameter.Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute]
                    } |
                    Select-Object -ExpandProperty Mandatory |

                    Should -Contain $true
            }

            It 'does not accept null' {
                { Get-XPathLocalName -XPath $null } | Should -Throw
            }

            It 'does not accept an empty string' {
                { Get-XPathLocalName -XPath '' } | Should -Throw
            }
        }

        Context 'Function metadata' {

            It 'exposes CmdletBinding' {
                (Get-Command -Name Get-XPathLocalName).CmdletBinding | Should -BeTrue
            }

            It 'declares OutputType of System.String' {
                (Get-Command -Name Get-XPathLocalName).OutputType.Type | Should -Contain ([string])
            }

            It 'exposes comment-based help with a Synopsis' {
                (Get-Help -Name Get-XPathLocalName).Synopsis | Should -Not -BeNullOrEmpty
            }
        }

        Context 'Parameter metadata' {

            BeforeAll {

                $command = Get-Command Get-XPathLocalName

                $parameter = $command.Parameters['XPath']

                $Script:Attribute = $parameter.Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute]
                    }
            }

            It 'uses System.String as parameter type' {
                $parameter.ParameterType | Should -Be ([string])
            }

            It 'is mandatory' {
                $Script:Attribute.Mandatory | Should -BeTrue
            }

            It 'does not accept pipeline input' {
                $Script:Attribute.ValueFromPipeline | Should -BeFalse
            }

            It 'does not accept pipeline input by property name' {
                $Script:Attribute.ValueFromPipelineByPropertyName | Should -BeFalse
            }

            It 'uses ValidateNotNullOrEmpty' {
                $parameter.Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ValidateNotNullOrEmptyAttribute]
                    } |

                    Should -Not -BeNullOrEmpty
            }
        }
    }

    AfterAll {
        Remove-Module -Name PipeDFe -Force -ErrorAction SilentlyContinue
    }
}
