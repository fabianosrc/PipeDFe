#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for Get-DFeDocumentNamespace.

.DESCRIPTION
Covers XML namespace resolution from the document root.

Contexts:
  Document namespace - namespace resolution from supported DFe documents
  Namespace handling - default and prefixed namespaces
  Result contract    - returned value and type
  Unknown documents  - namespace resolution is independent of DFe type
  Empty documents    - XML documents without a root element
  No namespace       - XML documents without a namespace
  Pipeline support   - single and multiple XML documents
  Pipeline isolation - independent processing of each XML document
  Input validation   - mandatory and null input
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

Describe 'Get-DFeDocumentNamespace' {

    AfterAll {
        Remove-Module -Name PipeDFe -Force -ErrorAction SilentlyContinue
    }

    InModuleScope PipeDFe {

        Context 'Document namespace' {

            It 'Gets the namespace from a NFe document' {
                [xml]$xml = '<NFe xmlns="http://www.portalfiscal.inf.br/nfe" />'

                $result = Get-DFeDocumentNamespace -Xml $xml
                $result | Should -Be 'http://www.portalfiscal.inf.br/nfe'
            }

            It 'Gets the namespace from a CTe document' {
                [xml]$xml = '<CTe xmlns="http://www.portalfiscal.inf.br/cte" />'

                $result = Get-DFeDocumentNamespace -Xml $xml
                $result | Should -Be 'http://www.portalfiscal.inf.br/cte'
            }

            It 'Gets the namespace from an MDFe document' {
                [xml]$xml = '<MDFe xmlns="http://www.portalfiscal.inf.br/mdfe" />'

                $result = Get-DFeDocumentNamespace -Xml $xml
                $result | Should -Be 'http://www.portalfiscal.inf.br/mdfe'
            }
        }

        Context 'Namespace handling' {

            It 'Gets a default XML namespace' {
                [xml]$xml = '<NFe xmlns="http://www.portalfiscal.inf.br/nfe" />'

                $result = Get-DFeDocumentNamespace -Xml $xml
                $result | Should -Be 'http://www.portalfiscal.inf.br/nfe'
            }

            It 'Gets a prefixed XML namespace' {
                [xml]$xml = '<nfe:NFe xmlns:nfe="http://www.portalfiscal.inf.br/nfe" />'

                $result = Get-DFeDocumentNamespace -Xml $xml
                $result | Should -Be 'http://www.portalfiscal.inf.br/nfe'
            }

            It 'Returns the namespace URI and not the prefix' {
                [xml]$xml = '<nfe:NFe xmlns:nfe="http://www.portalfiscal.inf.br/nfe" />'

                $result = Get-DFeDocumentNamespace -Xml $xml

                $result | Should -Not -Be 'nfe'
                $result | Should -Be 'http://www.portalfiscal.inf.br/nfe'
            }
        }

        Context 'Result contract' {

            It 'Returns a string' {
                [xml]$xml = '<NFe xmlns="http://www.portalfiscal.inf.br/nfe" />'

                $result = Get-DFeDocumentNamespace -Xml $xml
                $result | Should -BeOfType [string]
            }
        }

        Context 'Unknown documents' {

            It 'Gets the namespace from an unknown document' {
                [xml]$xml = '<UnknownDocument xmlns="urn:example:unknown" />'

                $result = Get-DFeDocumentNamespace -Xml $xml
                $result | Should -Be 'urn:example:unknown'
            }
        }

        Context 'Empty documents' {

            It 'Returns no output when the document has no root element' {
                $xml = [System.Xml.XmlDocument]::new()

                $result = Get-DFeDocumentNamespace -Xml $xml
                $result | Should -BeNullOrEmpty
            }
        }

        Context 'No namespace' {

            It 'Returns no output when the root has no namespace' {
                [xml]$xml = '<NFe />'

                $result = Get-DFeDocumentNamespace -Xml $xml
                $result | Should -BeNullOrEmpty
            }
        }

        Context 'Pipeline support' {

            It 'Accepts an XmlDocument from the pipeline' {
                [xml]$xml = '<NFe xmlns="http://www.portalfiscal.inf.br/nfe" />'

                $result = $xml | Get-DFeDocumentNamespace
                $result | Should -Be 'http://www.portalfiscal.inf.br/nfe'
            }

            It 'Processes multiple XmlDocuments from the pipeline' {
                [xml]$xml1 = '<NFe xmlns="http://www.portalfiscal.inf.br/nfe" />'
                [xml]$xml2 = '<CTe xmlns="http://www.portalfiscal.inf.br/cte" />'
                [xml]$xml3 = '<MDFe xmlns="http://www.portalfiscal.inf.br/mdfe" />'

                $results = @($xml1, $xml2, $xml3) | Get-DFeDocumentNamespace

                $results.Count | Should -Be 3

                $results[0] | Should -Be 'http://www.portalfiscal.inf.br/nfe'
                $results[1] | Should -Be 'http://www.portalfiscal.inf.br/cte'
                $results[2] | Should -Be 'http://www.portalfiscal.inf.br/mdfe'
            }

            It 'Processes documents with and without namespace independently' {
                [xml]$xml1 = '<NFe xmlns="http://www.portalfiscal.inf.br/nfe" />'
                [xml]$xml2 = '<UnknownDocument />'
                [xml]$xml3 = '<CTe xmlns="http://www.portalfiscal.inf.br/cte" />'

                $results = @($xml1, $xml2, $xml3) | Get-DFeDocumentNamespace

                $results.Count | Should -Be 2

                $results[0] | Should -Be 'http://www.portalfiscal.inf.br/nfe'
                $results[1] | Should -Be 'http://www.portalfiscal.inf.br/cte'
            }
        }

        Context 'Input validation' {

            It 'Defines Xml as a mandatory parameter' {
                $command = Get-Command -Name Get-DFeDocumentNamespace

                $parameter = $command.Parameters['Xml']

                $parameter.Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute]
                    } |

                    ForEach-Object Mandatory | Should -Contain $true
            }

            It 'Defines Xml with null validation' {
                $command = Get-Command -Name Get-DFeDocumentNamespace

                $parameter = $command.Parameters['Xml']

                $parameter.Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ValidateNotNullAttribute]
                    } |

                    Should -Not -BeNullOrEmpty
            }

            It 'Throws when Xml is null' {
                { Get-DFeDocumentNamespace -Xml $null } | Should -Throw
            }
        }
    }
}
