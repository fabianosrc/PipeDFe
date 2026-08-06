#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for Find-XmlNodeByNamespace.

.DESCRIPTION
Validates namespace-aware XPath lookup against XML documents, including
successful resolution, missing nodes, invalid XPath handling, pipeline
binding, parameter validation, and function metadata.

Contexts:
  Happy path           - successful XPath resolution in namespaced XML
  No match found       - valid XPath expressions that return no node
  Invalid XPath        - XPathException translation to ArgumentException
  Pipeline support     - ValueFromPipeline and ValueFromPipelineByPropertyName
  Parameter validation - Mandatory, ValidateNotNull and ValidateNotNullOrEmpty
  Function metadata    - CmdletBinding, OutputType and comment-based help
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

Describe 'Find-XmlNodeByNamespace' {

    AfterAll {
        Remove-Module -Name PipeDFe -Force -ErrorAction SilentlyContinue
    }

    InModuleScope -ModuleName PipeDFe {

        BeforeEach {
            # Minimal NF-e-shaped fixture: default namespace on the document
            # (mirrors <nfeProc>/<NFe>/<infNFe> from real SEFAZ documents) plus
            # a node under a second namespace (mirrors the <protNFe>/xmldsig
            # signature block), so namespace-prefix resolution is exercised
            # against more than one URI.
            $xmlNfe  = @'
                <nfeProc xmlns="http://www.portalfiscal.inf.br/nfe" versao="4.00">
                    <NFe xmlns="http://www.portalfiscal.inf.br/nfe">
                        <infNFe versao="4.00" Id="NFe35260701234567000189000000000000000000000000">
                            <ide>
                                <cUF>35</cUF>
                                    <natOp>VENDA DE MERCADORIA ADQUIRIDA OU RECEBIDA DE TERCEIROS</natOp>
                            </ide>
                            <emit>
                                <CNPJ>01234567000189</CNPJ>
                                    <xNome>ACME INDUSTRIAS DO BRASIL LTDA</xNome>
                            </emit>
                        </infNFe>
                    </NFe>
                    <protNFe xmlns="http://www.portalfiscal.inf.br/nfe" versao="4.00">
                        <infProt>
                                <chNFe>35260701234567000189000000000000000000000000</chNFe>
                                <nProt>135262196070090</nProt>
                                <cStat>100</cStat>
                                <xMotivo>Autorizado o uso da NF-e</xMotivo>
                        </infProt>
                    </protNFe>
                </nfeProc>
'@
            $xmlDocument = [System.Xml.XmlDocument]::new()
            $xmlDocument.LoadXml($xmlNfe)

            $xmlNsManager = [System.Xml.XmlNamespaceManager]::new($xmlDocument.NameTable)
            $xmlNsManager.AddNamespace('nfe', 'http://www.portalfiscal.inf.br/nfe')
            $xmlNsManager.AddNamespace('ds', 'http://www.w3.org/2000/09/xmldsig#')
        }

        Context 'Happy path: matching node exists' {

            It 'returns the matching node for a direct child XPath' {
                $result = $xmlDocument.DocumentElement |
                    Find-XmlNodeByNamespace -XPath 'nfe:NFe' -XmlNsManager $xmlNsManager

                $result | Should -Not -BeNullOrEmpty
                $result.LocalName | Should -Be 'NFe'
            }

            It 'returns the matching node for a deep descendant XPath' {
                $result = $xmlDocument.DocumentElement |
                    Find-XmlNodeByNamespace -XPath './/nfe:infNFe' -XmlNsManager $xmlNsManager

                $result.GetAttribute('Id') | Should -Be 'NFe35260701234567000189000000000000000000000000'
            }

            It 'resolves nodes across multiple registered namespace prefixes' {
                $result = $xmlDocument.DocumentElement |
                    Find-XmlNodeByNamespace -XPath './/nfe:chNFe' -XmlNsManager $xmlNsManager

                $result.InnerText | Should -Be '35260701234567000189000000000000000000000000'
            }

            It 'returns [System.Xml.XmlNode] as the declared output type' {
                $result = $xmlDocument.DocumentElement |
                    Find-XmlNodeByNamespace -XPath 'nfe:NFe' -XmlNsManager $xmlNsManager

                $result | Should -BeOfType [System.Xml.XmlNode]
            }

            It 'evaluates the XPath relative to the supplied context node, not the document root' {
                $infNFe = $xmlDocument.DocumentElement.SelectSingleNode('.//nfe:infNFe', $xmlNsManager)

                $result = $infNFe |
                    Find-XmlNodeByNamespace -XPath 'nfe:emit/nfe:xNome' -XmlNsManager $xmlNsManager

                $result.InnerText | Should -Be 'ACME INDUSTRIAS DO BRASIL LTDA'
            }
        }

        Context 'No match found' {

            It 'returns $null when the XPath is syntactically valid but matches nothing' {
                $xmlNodeParams = @{
                    XPath        = './/nfe:naoExiste'
                    XmlNsManager =  $xmlNsManager
                }

                $result = $xmlDocument.DocumentElement | Find-XmlNodeByNamespace @xmlNodeParams

                $result | Should -BeNullOrEmpty
            }

            It 'does not throw when no match is found' {
                $xmlNodeParams = @{
                    XPath        = './/nfe:naoExiste'
                    XmlNsManager = $xmlNsManager
                }

                { $xmlDocument.DocumentElement | Find-XmlNodeByNamespace @xmlNodeParams } |
                    Should -Not -Throw
            }
        }

        Context 'Invalid XPath translation to ArgumentException' {

            BeforeAll {
                $Script:InvalidXPath = 'nfe:[[['
            }

            It 'throws System.ArgumentException for a syntactically invalid XPath' {
                $xmlNodeParams = @{
                    XPath        = $Script:InvalidXPath
                    XmlNsManager = $xmlNsManager
                }

                { $xmlDocument.DocumentElement | Find-XmlNodeByNamespace @xmlNodeParams } |
                    Should -Throw -ExceptionType ([System.ArgumentException])
            }

            It 'includes the offending XPath expression in the error message' {
                $invalidXPath = $Script:InvalidXPath.Replace('[', '`[')

                $xmlNodeParams = @{
                    XPath        = $Script:InvalidXPath
                    XmlNsManager = $xmlNsManager
                }

                try {
                    $xmlDocument.DocumentElement | Find-XmlNodeByNamespace @xmlNodeParams
                } catch {
                    $_.Exception.Message | Should -BeLike "*$invalidXPath*"
                    return
                }

                throw 'Expected exception was not thrown.'
            }

            It 'preserves the original XPathException as the InnerException' {
                $xmlNodeParams = @{
                    XPath        = $Script:InvalidXPath
                    XmlNsManager = $xmlNsManager
                }

                try {
                    $xmlDocument.DocumentElement | Find-XmlNodeByNamespace @xmlNodeParams
                } catch {
                    $_.Exception.InnerException | Should -BeOfType ([System.Xml.XPath.XPathException])
                    return
                }

                throw 'Expected exception was not thrown.'
            }

            It 'sets ParamName to XPath on the rethrown exception' {
                $xmlNodeParams = @{
                    XPath        = $Script:InvalidXPath
                    XmlNsManager = $xmlNsManager
                }

                try {
                    $xmlDocument.DocumentElement | Find-XmlNodeByNamespace @xmlNodeParams
                } catch {
                    $_.Exception.ParamName | Should -Be 'XPath'
                    return
                }

                throw 'Expected exception was not thrown.'
            }

            It 'throws ArgumentException for an unregistered namespace prefix (also an XPathException internally)' {
                $xmlNodeParams = @{
                    XPath        = 'naoRegistrado:infNFe'
                    XmlNsManager = $xmlNsManager
                }

                { $xmlDocument.DocumentElement | Find-XmlNodeByNamespace @xmlNodeParams } |
                    Should -Throw -ExceptionType ([System.ArgumentException])
            }
        }

        Context 'Pipeline support' {

            It 'accepts the context node via ValueFromPipeline' {
                $xmlNodeParams = @{
                    XPath        = 'nfe:NFe'
                    XmlNsManager = $xmlNsManager
                }

                $result = $xmlDocument.DocumentElement | Find-XmlNodeByNamespace @xmlNodeParams

                $result.LocalName | Should -Be 'NFe'
            }

            It 'accepts the context node via ValueFromPipelineByPropertyName using the Node alias' {
                $result = [PSCustomObject]@{
                    Node = $xmlDocument.DocumentElement
                } | Find-XmlNodeByNamespace -XPath 'nfe:NFe' -XmlNsManager $xmlNsManager

                $result.LocalName | Should -Be 'NFe'
            }

            It 'processes multiple pipeline items independently, one lookup per input node' {
                $xmlNodeParams = @{
                    XPath        = 'nfe:CNPJ'
                    XmlNsManager = $xmlNsManager
                }

                $infNFe = $xmlDocument.DocumentElement.SelectSingleNode('.//nfe:infNFe', $xmlNsManager)
                $emit   = $xmlDocument.DocumentElement.SelectSingleNode('.//nfe:emit', $xmlNsManager)

                # infNFe has no direct nfe:CNPJ child, so only emit's lookup should match.
                $results = @($infNFe, $emit) | Find-XmlNodeByNamespace @xmlNodeParams

                @($results | Where-Object { $_ }).Count | Should -Be 1
            }
        }

        Context 'Parameter validation' {

            It 'requires XmlNode (Mandatory)' {
                $parameter = (Get-Command -Name Find-XmlNodeByNamespace).Parameters['XmlNode']

                $parameter.Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute]
                    } | Select-Object -ExpandProperty Mandatory |

                    Should -Contain $true
            }

            It 'rejects a $null XmlNode passed by name via ValidateNotNull' {
                $xmlNodeParams = @{
                    XmlNode      = $null
                    XPath        = 'nfe:NFe'
                    XmlNsManager = $xmlNsManager
                }

                { Find-XmlNodeByNamespace @xmlNodeParams } |
                    Should -Throw -ExceptionType ([System.Management.Automation.ParameterBindingException])
            }

            It 'rejects a $null XmlNode arriving via the pipeline' {
                $xmlNodeParams = @{
                    XPath        = 'nfe:NFe'
                    XmlNsManager = $xmlNsManager
                }

                { $null | Find-XmlNodeByNamespace @xmlNodeParams } | Should -Throw
            }

            It 'requires XPath (Mandatory)' {
                $parameter = (Get-Command -Name Find-XmlNodeByNamespace).Parameters['XPath']

                $parameter.Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute]
                    } | Select-Object -ExpandProperty Mandatory |

                    Should -Contain $true
            }

            It 'rejects an empty string XPath via ValidateNotNullOrEmpty' {
                $xmlNodeParams = @{
                    XPath        = ''
                    XmlNsManager = $xmlNsManager
                }

                { $xmlDocument.DocumentElement | Find-XmlNodeByNamespace @xmlNodeParams } |
                    Should -Throw -ExceptionType ([System.Management.Automation.ParameterBindingException])
            }

            It 'rejects a $null XPath' {
                $xmlNodeParams = @{
                    XPath        = $null
                    XmlNsManager = $xmlNsManager
                }

                { $xmlDocument.DocumentElement | Find-XmlNodeByNamespace @xmlNodeParams } |
                    Should -Throw -ExceptionType ([System.Management.Automation.ParameterBindingException])
            }

            It 'requires XmlNsManager (Mandatory)' {
                $parameter = (Get-Command -Name Find-XmlNodeByNamespace).Parameters['XmlNsManager']

                $parameter.Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute]
                    } | Select-Object -ExpandProperty Mandatory |

                    Should -Contain $true
            }

            It 'rejects a $null XmlNsManager via ValidateNotNull' {
                $xmlNodeParams = @{
                    XPath        = 'nfe:NFe'
                    XmlNsManager = $null
                }

                { $xmlDocument.DocumentElement | Find-XmlNodeByNamespace @xmlNodeParams } |
                    Should -Throw -ExceptionType ([System.Management.Automation.ParameterBindingException])
            }

            It 'rejects a value of the wrong type for XmlNsManager' {
                $xmlNodeParams = @{
                    XPath        = 'nfe:NFe'
                    XmlNsManager = 'not-a-namespace-manager'
                }

                { $xmlDocument.DocumentElement | Find-XmlNodeByNamespace @xmlNodeParams } |
                    Should -Throw -ExceptionType ([System.Management.Automation.ParameterBindingException])
            }
        }

        Context 'Function metadata' {

            It 'exposes CmdletBinding (supports common parameters)' {
                (Get-Command -Name Find-XmlNodeByNamespace).CmdletBinding |
                    Should -BeTrue
            }

            It 'declares OutputType of System.Xml.XmlNode' {
                (Get-Command -Name Find-XmlNodeByNamespace).OutputType.Type |
                    Should -Contain ([System.Xml.XmlNode])
            }

            It 'exposes comment-based help with a Synopsis' {
                (Get-Help -Name Find-XmlNodeByNamespace).Synopsis |
                    Should -Not -BeNullOrEmpty
            }
        }
    }
}

