#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for Find-XmlNodeByTraversal.

.DESCRIPTION
Validates iterative XML DOM traversal based on LocalName matching,
including nested elements, namespace independence, pipeline support,
parameter validation, and function metadata.

Contexts:
  Happy path           - matching nodes returned from the XML tree
  Traversal behavior   - iterative depth-first traversal characteristics
  No match found       - valid searches returning no result
  Pipeline support     - ValueFromPipeline and ValueFromPipelineByPropertyName
  Parameter validation - Mandatory and ValidateNotNullOrEmpty behavior
  Function metadata    - CmdletBinding, OutputType and help metadata
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

Describe 'Find-XmlNodeByTraversal' {

    AfterAll {
        Remove-Module PipeDFe -Force -ErrorAction SilentlyContinue
    }

    InModuleScope PipeDFe {

        BeforeEach {

            $xmlNfe = @'
            <nfeProc xmlns="http://www.portalfiscal.inf.br/nfe">
                <NFe>
                    <infNFe>
                        <ide>
                            <cUF>35</cUF>
                        </ide>
                    <emit>
                        <CNPJ>01234567000189</CNPJ>
                        <xNome>ACME INDUSTRIAS DO BRASIL LTDA</xNome>
                    </emit>
                </infNFe>
                </NFe>
                <protNFe>
                    <infProt>
                        <chNFe>35260701234567000189000000000000000000000000</chNFe>
                    </infProt>
                </protNFe>
            </nfeProc>
'@
            $xmlDocument = [System.Xml.XmlDocument]::new()
            $xmlDocument.LoadXml($xmlNfe)
        }

        Context 'Happy path: matching node exists' {

            It 'returns the root node when its LocalName matches' {
                $result = $xmlDocument.DocumentElement |
                    Find-XmlNodeByTraversal -LocalName 'nfeProc'

                $result | Should -Not -BeNullOrEmpty
                $result.LocalName | Should -Be 'nfeProc'
            }

            It 'returns a matching descendant' {
                $result = $xmlDocument.DocumentElement |
                    Find-XmlNodeByTraversal -LocalName 'emit'

                $result.LocalName | Should -Be 'emit'
            }

            It 'ignores namespaces and matches LocalName only' {
                $result = $xmlDocument.DocumentElement |
                    Find-XmlNodeByTraversal -LocalName 'infProt'

                $result.LocalName | Should -Be 'infProt'
            }

            It 'returns System.Xml.XmlNode' {
                $result = $xmlDocument.DocumentElement |
                    Find-XmlNodeByTraversal -LocalName 'emit'

                $result | Should -BeOfType ([System.Xml.XmlNode])
            }
        }

        Context 'Traversal behavior' {

            It 'finds deeply nested descendants' {
                $result = $xmlDocument.DocumentElement |
                    Find-XmlNodeByTraversal -LocalName 'xNome'

                $result.InnerText |
                    Should -Be 'ACME INDUSTRIAS DO BRASIL LTDA'
            }

            It 'searches relative to the supplied context node' {
                $emit = $xmlDocument.DocumentElement.SelectSingleNode("//*[local-name()='emit']")

                $result = $emit | Find-XmlNodeByTraversal -LocalName 'CNPJ'
                $result.InnerText | Should -Be '01234567000189'
            }

            It 'returns the first match according to stack traversal order' {
                $xml = @'
                <root>
                    <A>
                        <Target>A</Target>
                    </A>
                    <B>
                        <Target>B</Target>
                    </B>
                </root>
'@
                $doc = [xml]$xml

                $result = $doc.DocumentElement | Find-XmlNodeByTraversal -LocalName 'Target'
                $result.InnerText | Should -Be 'B'
            }
        }

        Context 'No match found' {

            It 'returns $null when no element matches' {
                $result = $xmlDocument.DocumentElement |
                    Find-XmlNodeByTraversal -LocalName 'DoesNotExist'

                $result | Should -BeNullOrEmpty
            }

            It 'does not throw when no match exists' {
                { $xmlDocument.DocumentElement | Find-XmlNodeByTraversal -LocalName 'DoesNotExist' } |
                    Should -Not -Throw
            }
        }

        Context 'Pipeline support' {

            It 'accepts XmlNode via ValueFromPipeline' {
                $result = $xmlDocument.DocumentElement | Find-XmlNodeByTraversal -LocalName 'emit'

                $result.LocalName | Should -Be 'emit'
            }

            It 'accepts XmlNode via ValueFromPipelineByPropertyName using the Node alias' {
                $result = [PSCustomObject]@{ Node = $xmlDocument.DocumentElement } |
                    Find-XmlNodeByTraversal -LocalName 'emit'

                $result.LocalName | Should -Be 'emit'
            }

            It 'processes multiple pipeline items independently' {
                $ide = $xmlDocument.DocumentElement.SelectSingleNode("//*[local-name()='ide']")

                $emit = $xmlDocument.DocumentElement.SelectSingleNode("//*[local-name()='emit']")

                $results = @($ide, $emit) | Find-XmlNodeByTraversal -LocalName 'CNPJ'

                @($results | Where-Object { $_ }).Count | Should -Be 1
            }
        }

        Context 'Parameter validation' {

            It 'requires XmlNode (Mandatory)' {
                $parameter = (Get-Command Find-XmlNodeByTraversal).Parameters['XmlNode']

                $parameter.Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute]
                    } |
                    Select-Object -ExpandProperty Mandatory |

                    Should -Contain $true
            }

            It 'rejects a $null XmlNode passed by name' {
                { Find-XmlNodeByTraversal -XmlNode $null -LocalName 'emit' } |
                    Should -Throw -ExceptionType ([System.Management.Automation.ParameterBindingException])
            }

            It 'rejects a $null XmlNode arriving via the pipeline' {
                { $null | Find-XmlNodeByTraversal -LocalName 'emit' } | Should -Throw
            }

            It 'requires LocalName (Mandatory)' {
                $parameter = (Get-Command -Name Find-XmlNodeByTraversal).Parameters['LocalName']

                $parameter.Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute]
                    } | Select-Object -ExpandProperty Mandatory |

                    Should -Contain $true
            }

            It 'rejects an empty LocalName' {
                { $xmlDocument.DocumentElement | Find-XmlNodeByTraversal -LocalName '' } |
                    Should -Throw -ExceptionType ([System.Management.Automation.ParameterBindingException])
            }

            It 'rejects a $null LocalName' {
                { $xmlDocument.DocumentElement | Find-XmlNodeByTraversal -LocalName $null } |
                    Should -Throw -ExceptionType ([System.Management.Automation.ParameterBindingException])
            }
        }

        Context 'Function metadata' {

            It 'exposes CmdletBinding (supports common parameters)' {
                (Get-Command -Name Find-XmlNodeByTraversal).CmdletBinding |
                    Should -BeTrue
            }

            It 'declares OutputType of System.Xml.XmlNode' {
                (Get-Command -Name Find-XmlNodeByTraversal).OutputType.Type |
                    Should -Contain ([System.Xml.XmlNode])
            }

            It 'exposes comment-based help with a Synopsis' {
                (Get-Help -Name Find-XmlNodeByTraversal).Synopsis |
                    Should -Not -BeNullOrEmpty
            }
        }
    }
}
