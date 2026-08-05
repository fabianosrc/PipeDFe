#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for Find-XmlNodeByLocalName.

.DESCRIPTION
Covers XML node lookup behavior with namespace handling and XPath validation.

Contexts:
  Namespace handling - prefixes, defaults, mixed namespaces
  XML compatibility  - namespaced and non-namespaced documents
  Node resolution    - nested paths and child node contexts
  Pipeline support   - XmlNode pipeline input
  Result contract    - return type and selected node behavior
  Missing nodes      - null results when no match exists
  Input validation   - invalid XPath and missing parameters
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

Describe 'Find-XmlNodeByLocalName' {

    AfterAll {
        Remove-Module -Name PipeDFe -Force -ErrorAction SilentlyContinue
    }

    InModuleScope -ModuleName PipeDFe {

        BeforeEach {
            # XML sample using a default namespace.
            # The function must resolve nodes regardless of namespace prefix.
            [xml]$xmlSample = @'
                <NFe xmlns="http://www.portalfiscal.inf.br/nfe">
                    <infNFe versao="4.00" Id="NFe12345678910111213141516171819202122232425267">
                        <emit>
                            <CNPJ>01234567000190</CNPJ>
                            <xNome>ACME INDUSTRIES CORP LTD.</xNome>
                        </emit>
                        <dest>
                        <CNPJ>01234567000166</CNPJ>
                            <xNome>JOHN DOE</xNome>
                        </dest>
                    </infNFe>
                </NFe>
'@
            $Script:RootNode = $xmlSample.DocumentElement
        }

        Context 'When resolving namespace qualified paths' {

            It 'Should find a node using an unknown namespace prefix' {
                $result = $Script:RootNode |
                    Find-XmlNodeByLocalName -XPath 'nfe:infNFe/nfe:emit'

                $result | Should -Not -BeNullOrEmpty
                $result.LocalName | Should -Be 'emit'
            }

            It 'Should find a node using a different namespace prefix' {
                $result = $Script:RootNode |
                    Find-XmlNodeByLocalName -XPath 'foo:infNFe/foo:dest'

                $result | Should -Not -BeNullOrEmpty
                $result.LocalName | Should -Be 'dest'
            }

            It 'Should work with nested nodes' {
                $result = $Script:RootNode |
                    Find-XmlNodeByLocalName -XPath 'nfe:infNFe/nfe:dest/nfe:xNome'

                $result | Should -Not -BeNullOrEmpty
                $result.InnerText | Should -Be 'JOHN DOE'
            }
        }

        Context 'When XML does not use namespaces' {

            It 'Should find nodes without a namespace declaration' {
                [xml]$XmlSample = @'
                    <NFe>
                        <infNFe>
                            <emit>
                                <xNome>NO NAMESPACE</xNome>
                            </emit>
                        </infNFe>
                    </NFe>
'@
                $result = $XmlSample.DocumentElement |
                    Find-XmlNodeByLocalName -XPath 'nfe:infNFe/nfe:emit'

                $result | Should -Not -BeNullOrEmpty
                $result.LocalName | Should -Be 'emit'
            }
        }

        Context 'When receiving pipeline input' {

            It 'Should accept XmlNode through the pipeline' {
                $result = $Script:RootNode |
                    Find-XmlNodeByLocalName -XPath 'nfe:infNFe/nfe:emit'

                $result.LocalName | Should -Be 'emit'
            }
        }

        Context 'When using a child XmlNode as context' {

            It 'Should resolve XPath relative to the provided node' {
                $contextNode = $Script:RootNode.SelectSingleNode('*[local-name()="infNFe"]')

                $result = $contextNode | Find-XmlNodeByLocalName -XPath 'emit'

                $result | Should -Not -BeNullOrEmpty
                $result.LocalName | Should -Be 'emit'
            }
        }

        Context 'When multiple nodes match' {

            It 'Should return only the first matching node' {
                [xml]$XmlSample = @'
                    <NFe xmlns="http://www.portalfiscal.inf.br/nfe">
                        <emit>
                            <xNome>FIRST</xNome>
                        </emit>
                        <emit>
                            <xNome>SECOND</xNome>
                        </emit>
                    </NFe>
'@
                $result = $XmlSample.DocumentElement |
                    Find-XmlNodeByLocalName -XPath 'emit'

                $result.InnerText | Should -Be 'FIRST'
            }
        }

        Context 'When no node matches' {

            It 'Should return null when XPath does not find a node' {
                $result = $Script:RootNode |
                    Find-XmlNodeByLocalName -XPath 'nfe:infNFe/nfe:unknown'

                $result | Should -BeNullOrEmpty
            }
        }

        Context 'When returning results' {

            It 'Should return an XmlNode instance' {
                $result = $Script:RootNode |
                    Find-XmlNodeByLocalName -XPath 'nfe:infNFe/nfe:emit'

                $result | Should -BeOfType ([System.Xml.XmlNode])
            }
        }

        Context 'When XPath input is invalid' {

            It 'Should reject an empty XPath expression' {
                {
                    Find-XmlNodeByLocalName -XmlNode $Script:RootNode -XPath ''
                } | Should -Throw
            }

            It 'Should throw ArgumentException for malformed XPath' {
                {
                    Find-XmlNodeByLocalName -XmlNode $Script:RootNode -XPath 'nfe:infNFe['
                } | Should -Throw -ExceptionType ([System.ArgumentException])
            }
        }

        Context 'When using a nested XmlNode as context' {

            It 'Should resolve XPath relative to the supplied child node' {
                $emit = $Script:RootNode |
                    Find-XmlNodeByLocalName -XPath 'nfe:infNFe/nfe:emit'

                $result = $emit |
                    Find-XmlNodeByLocalName -XPath 'xNome'

                $result | Should -Not -BeNullOrEmpty
                $result.LocalName | Should -Be 'xNome'
                $result.InnerText | Should -Be 'ACME INDUSTRIES CORP LTD.'
            }
        }

        Context 'When XML contains mixed namespaces' {

            It 'Should ignore namespace changes between parent and child elements' {
                [xml]$XmlSample = @'
                    <root xmlns="urn:one">
                        <parent xmlns="urn:two">
                            <child>VALUE</child>
                        </parent>
                    </root>
'@
                $result = $XmlSample.DocumentElement |
                    Find-XmlNodeByLocalName -XPath 'parent/child'

                $result | Should -Not -BeNullOrEmpty
                $result.LocalName | Should -Be 'child'
                $result.InnerText | Should -Be 'VALUE'
            }
        }

        Context 'When XML is empty' {

            It 'Should return null when no matching node exists' {
                [xml]$XmlSample = '<NFe />'

                $result = $XmlSample.DocumentElement |
                    Find-XmlNodeByLocalName -XPath 'emit'

                $result | Should -BeNullOrEmpty
            }
        }
    }
}
