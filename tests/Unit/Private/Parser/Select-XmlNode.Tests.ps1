#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for Select-XmlNode.

.DESCRIPTION
Covers XML node selection behavior across all supported lookup strategies.

Contexts:
  Namespace-aware lookup    - XmlNamespaceManager resolution
  Namespace-agnostic lookup - LocalName XPath resolution
  DOM traversal fallback    - recursive LocalName search
  Lookup precedence         - strategy evaluation order
  Result contract           - XmlNode and null results
  Input validation          - mandatory parameters
#>
BeforeDiscovery {
    $moduleRoot = (Get-Item $PSScriptRoot).Parent.Parent.Parent.Parent.FullName

    $moduleName = Join-Path -Path $moduleRoot -ChildPath 'PipeDFe.psd1'

    Import-Module -Name $moduleName -Force -Global -ErrorAction Stop
}

InModuleScope PipeDFe {

    Describe 'Select-XmlNode' {

        BeforeEach {

            [xml]$xml = @'
            <root xmlns="urn:test">
                <parent>
                    <child>value</child>
                </parent>
            </root>
'@
            $ns = [System.Xml.XmlNamespaceManager]::new($xml.NameTable)
            $ns.AddNamespace('t','urn:test')

            $Script:ChildNode = $xml.DocumentElement.FirstChild.FirstChild
        }

        Context 'Namespace-aware lookup' {

            It 'Returns the node when namespace lookup succeeds' {
                Mock -CommandName Find-XmlNodeByNamespace {
                    $Script:ChildNode
                }

                Mock -CommandName Find-XmlNodeByLocalName { }
                Mock -CommandName Find-XmlNodeByTraversal { }

                $xmlNodeParams = @{
                    XmlNode      = $xml
                    XPath        = 't:parent/t:child'
                    XmlNsManager = $ns
                }

                $node = Select-XmlNode @xmlNodeParams
                $node.LocalName | Should -Be 'child'

                Should -Invoke Find-XmlNodeByNamespace -Times 1
                Should -Invoke Find-XmlNodeByLocalName -Times 0
                Should -Invoke Find-XmlNodeByTraversal -Times 0
            }

            It 'Falls back when namespace lookup returns null' {
                Mock -CommandName Find-XmlNodeByNamespace { $null }

                Mock -CommandName Find-XmlNodeByLocalName {
                    $Script:ChildNode
                }

                Mock -CommandName Find-XmlNodeByTraversal { }

                $xmlNodeParams = @{
                    XmlNode      = $xml
                    XPath        = 't:parent/t:child'
                    XmlNsManager = $ns
                }

                $node = Select-XmlNode @xmlNodeParams
                $node.LocalName | Should -Be 'child'

                Should -Invoke Find-XmlNodeByNamespace -Times 1
                Should -Invoke Find-XmlNodeByLocalName -Times 1
                Should -Invoke Find-XmlNodeByTraversal -Times 0
            }
        }

        Context 'Namespace-agnostic LocalName lookup' {

            It 'Returns the node when LocalName lookup succeeds' {
                Mock -CommandName Find-XmlNodeByLocalName {
                    $Script:ChildNode
                }

                Mock -CommandName Find-XmlNodeByTraversal { }

                $node = Select-XmlNode -XmlNode $xml -XPath 'parent/child'
                $node.LocalName | Should -Be 'child'

                Should -Invoke Find-XmlNodeByLocalName -Times 1
                Should -Invoke Find-XmlNodeByTraversal -Times 0
            }
        }

        Context 'DOM traversal fallback' {

            It 'Uses traversal when previous strategies fail' {
                Mock -CommandName Find-XmlNodeByLocalName { $null }
                Mock -CommandName Get-XPathLocalName { 'child' }

                Mock -CommandName Find-XmlNodeByTraversal {
                    $Script:ChildNode
                }

                $node = Select-XmlNode -XmlNode $xml -XPath 'parent/child'
                $node.LocalName | Should -Be 'child'

                Should -Invoke Find-XmlNodeByTraversal -Times 1
            }

            It 'Returns null when LocalName cannot be extracted' {
                Mock -CommandName Find-XmlNodeByLocalName { $null }
                Mock -CommandName Get-XPathLocalName { $null }
                Mock -CommandName Find-XmlNodeByTraversal { }

                $node = Select-XmlNode -XmlNode $xml -XPath 'parent/child'
                $node | Should -BeNullOrEmpty

                Should -Invoke Find-XmlNodeByTraversal -Times 0
            }
        }

        Context 'Lookup precedence' {

            It 'Stops after namespace-aware success' {
                Mock -CommandName Find-XmlNodeByNamespace {
                    $xml.DocumentElement
                }

                Mock -CommandName Find-XmlNodeByLocalName { }
                Mock -CommandName Get-XPathLocalName { }
                Mock -CommandName Find-XmlNodeByTraversal { }

                $xmlNodeParams = @{
                    XmlNode      = $xml
                    XPath        = 't:root'
                    XmlNsManager = $ns
                }

                Select-XmlNode @xmlNodeParams  | Out-Null

                Should -Invoke Find-XmlNodeByNamespace -Times 1
                Should -Invoke Find-XmlNodeByLocalName -Times 0
                Should -Invoke Get-XPathLocalName -Times 0
                Should -Invoke Find-XmlNodeByTraversal -Times 0
            }

            It 'Stops after LocalName success' {
                Mock -CommandName Find-XmlNodeByLocalName {
                    $xml.DocumentElement
                }

                Mock -CommandName Get-XPathLocalName { }
                Mock -CommandName Find-XmlNodeByTraversal { }

                Select-XmlNode -XmlNode $xml -XPath 'root' | Out-Null

                Should -Invoke Get-XPathLocalName -Times 0
                Should -Invoke Find-XmlNodeByTraversal -Times 0
            }
        }

        Context 'Result contract' {

            It 'Returns XmlNode' {
                Mock -CommandName Find-XmlNodeByLocalName {
                    $xml.DocumentElement
                }

                $result = Select-XmlNode -XmlNode $xml -XPath 'root'
                $result | Should -BeOfType System.Xml.XmlNode
            }

            It 'Returns null when all lookup strategies fail' {
                Mock -CommandName Find-XmlNodeByLocalName { $null }
                Mock -CommandName Get-XPathLocalName { 'child' }
                Mock -CommandName Find-XmlNodeByTraversal { $null }

                $result = Select-XmlNode -XmlNode $xml -XPath 'child'
                $result | Should -BeNullOrEmpty
            }
        }

        Context 'Input validation' {

            It 'Throws when XmlNode is omitted' {
                { Select-XmlNode -XmlNode $null -XPath 'child' } | Should -Throw
            }

            It 'Throws when XPath is omitted' {
                { Select-XmlNode -XmlNode $xml -XPath $null } | Should -Throw
            }

            It 'Throws when XPath is empty' {
                { Select-XmlNode -XmlNode $xml -XPath '' } | Should -Throw
            }
        }
    }
}
