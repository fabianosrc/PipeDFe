#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for Get-DFeDocumentInfo.

.DESCRIPTION
Covers DFe document information resolution based on XML root elements.

Contexts:
  Document resolution - supported DFe document roots
  Event resolution    - supported DFe event roots
  Inutilizacao        - supported inutilizacao roots
  Result contract     - returned object and property types
  Pipeline support    - single and multiple XML documents
  Unknown documents   - unsupported root elements
  Empty documents     - XML documents without a root element
  Input validation    - mandatory and null input
  Pipeline isolation  - independent processing of each XML document
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

Describe 'Get-DFeDocumentInfo' {

    AfterAll {
        Remove-Module -Name PipeDFe -Force -ErrorAction SilentlyContinue
    }

    InModuleScope PipeDFe {

        Context 'Document resolution' {

            It 'Identifies NFe from NFe root' {
                [xml]$xml = '<NFe />'

                $result = Get-DFeDocumentInfo -Xml $xml

                $result.Tipo | Should -Be ([TipoXmlDFe]::Documento)
                $result.Modelo | Should -Be ([ModeloDFe]::NFe)
            }

            It 'Identifies NFe from nfeProc root' {
                [xml]$xml = '<nfeProc />'

                $result = Get-DFeDocumentInfo -Xml $xml

                $result.Tipo | Should -Be ([TipoXmlDFe]::Documento)
                $result.Modelo | Should -Be ([ModeloDFe]::NFe)
            }

            It 'Identifies CTe from CTe root' {
                [xml]$xml = '<CTe />'

                $result = Get-DFeDocumentInfo -Xml $xml

                $result.Tipo | Should -Be ([TipoXmlDFe]::Documento)
                $result.Modelo | Should -Be ([ModeloDFe]::CTe)
            }

            It 'Identifies CTe from cteProc root' {
                [xml]$xml = '<cteProc />'

                $result = Get-DFeDocumentInfo -Xml $xml

                $result.Tipo | Should -Be ([TipoXmlDFe]::Documento)
                $result.Modelo | Should -Be ([ModeloDFe]::CTe)
            }

            It 'Identifies CTeOS from CTeOS root' {
                [xml]$xml = '<CTeOS />'

                $result = Get-DFeDocumentInfo -Xml $xml

                $result.Tipo | Should -Be ([TipoXmlDFe]::Documento)
                $result.Modelo | Should -Be ([ModeloDFe]::CTeOS)
            }

            It 'Identifies CTeOS from cteOSProc root' {
                [xml]$xml = '<cteOSProc />'

                $result = Get-DFeDocumentInfo -Xml $xml

                $result.Tipo | Should -Be ([TipoXmlDFe]::Documento)
                $result.Modelo | Should -Be ([ModeloDFe]::CTeOS)
            }

            It 'Identifies MDFe from MDFe root' {
                [xml]$xml = '<MDFe />'

                $result = Get-DFeDocumentInfo -Xml $xml

                $result.Tipo | Should -Be ([TipoXmlDFe]::Documento)
                $result.Modelo | Should -Be ([ModeloDFe]::MDFe)
            }

            It 'Identifies MDFe from mdfeProc root' {
                [xml]$xml = '<mdfeProc />'

                $result = Get-DFeDocumentInfo -Xml $xml

                $result.Tipo | Should -Be ([TipoXmlDFe]::Documento)
                $result.Modelo | Should -Be ([ModeloDFe]::MDFe)
            }
        }

        Context 'Event resolution' {

            It 'Identifies NFe events from procEventoNFe root' {
                [xml]$xml = '<procEventoNFe />'

                $result = Get-DFeDocumentInfo -Xml $xml

                $result.Tipo | Should -Be ([TipoXmlDFe]::Evento)
                $result.Modelo | Should -Be ([ModeloDFe]::NFe)
            }

            It 'Identifies CTe events from procEventoCTe root' {
                [xml]$xml = '<procEventoCTe />'

                $result = Get-DFeDocumentInfo -Xml $xml

                $result.Tipo | Should -Be ([TipoXmlDFe]::Evento)
                $result.Modelo | Should -Be ([ModeloDFe]::CTe)
            }

            It 'Identifies MDFe events from procEventoMDFe root' {
                [xml]$xml = '<procEventoMDFe />'

                $result = Get-DFeDocumentInfo -Xml $xml

                $result.Tipo | Should -Be ([TipoXmlDFe]::Evento)
                $result.Modelo | Should -Be ([ModeloDFe]::MDFe)
            }
        }

        Context 'Inutilizacao resolution' {

            It 'Identifies NFe inutilizacao from inutNFe root' {
                [xml]$xml = '<inutNFe />'

                $result = Get-DFeDocumentInfo -Xml $xml

                $result.Tipo | Should -Be ([TipoXmlDFe]::Inutilizacao)
                $result.Modelo | Should -Be ([ModeloDFe]::NFe)
            }

            It 'Identifies NFe inutilizacao from retInutNFe root' {
                [xml]$xml = '<retInutNFe />'

                $result = Get-DFeDocumentInfo -Xml $xml

                $result.Tipo | Should -Be ([TipoXmlDFe]::Inutilizacao)
                $result.Modelo | Should -Be ([ModeloDFe]::NFe)
            }
        }

        Context 'Result contract' {

            It 'Returns a PSCustomObject' {
                [xml]$xml = '<CTe />'

                $result = Get-DFeDocumentInfo -Xml $xml
                $result | Should -BeOfType [pscustomobject]
            }

            It 'Returns the Tipo property as TipoXmlDFe' {
                [xml]$xml = '<CTe />'

                $result = Get-DFeDocumentInfo -Xml $xml
                $result.Tipo.GetType().Name | Should -Be 'TipoXmlDFe'
            }

            It 'Returns the Modelo property as ModeloDFe' {
                [xml]$xml = '<CTe />'

                $result = Get-DFeDocumentInfo -Xml $xml
                $result.Modelo.GetType().Name | Should -Be 'ModeloDFe'
            }

            It 'Returns exactly the expected properties' {
                [xml]$xml = '<CTe />'

                $result = Get-DFeDocumentInfo -Xml $xml
                @($result.PSObject.Properties.Name) | Should -Be @('Tipo', 'Modelo')
            }

            It 'Returns non-null Tipo and Modelo for a supported document' {
                [xml]$xml = '<CTe />'

                $result = Get-DFeDocumentInfo -Xml $xml

                $result.Tipo | Should -Not -BeNullOrEmpty
                $result.Modelo | Should -Not -BeNullOrEmpty
            }
        }

        Context 'Namespace handling' {

            It 'Identifies a document using a default XML namespace' {
                [xml]$xml = @'
<NFe xmlns="http://www.portalfiscal.inf.br/nfe" />
'@
                $result = Get-DFeDocumentInfo -Xml $xml

                $result.Tipo | Should -Be ([TipoXmlDFe]::Documento)
                $result.Modelo | Should -Be ([ModeloDFe]::NFe)
            }

            It 'Identifies a document using a prefixed XML namespace' {
                [xml]$xml = @'
<nfe:NFe xmlns:nfe="http://www.portalfiscal.inf.br/nfe" />
'@
                $result = Get-DFeDocumentInfo -Xml $xml

                $result.Tipo | Should -Be ([TipoXmlDFe]::Documento)
                $result.Modelo | Should -Be ([ModeloDFe]::NFe)
            }
        }

        Context 'Unknown documents' {

            It 'Returns no output for an unsupported root element' {
                [xml]$xml = '<UnknownDocument />'

                $result = Get-DFeDocumentInfo -Xml $xml
                $result | Should -BeNullOrEmpty
            }

            It 'Returns no output for an unsupported DFe root element' {
                [xml]$xml = '<UnknownDFeDocument />'

                $result = Get-DFeDocumentInfo -Xml $xml
                $result | Should -BeNullOrEmpty
            }
        }

        Context 'Empty documents' {

            It 'Returns no output when the document has no root element' {
                $xml = [System.Xml.XmlDocument]::new()

                $result = Get-DFeDocumentInfo -Xml $xml
                $result | Should -BeNullOrEmpty
            }
        }

        Context 'Pipeline support' {

            It 'Accepts an XmlDocument from the pipeline' {
                [xml]$xml = '<CTe />'

                $result = $xml | Get-DFeDocumentInfo

                $result.Tipo | Should -Be ([TipoXmlDFe]::Documento)
                $result.Modelo | Should -Be ([ModeloDFe]::CTe)
            }

            It 'Processes multiple XmlDocuments from the pipeline' {
                [xml]$xml1 = '<NFe />'
                [xml]$xml2 = '<CTe />'
                [xml]$xml3 = '<MDFe />'

                $results = @($xml1, $xml2, $xml3) | Get-DFeDocumentInfo

                $results.Count | Should -Be 3

                $results[0].Modelo | Should -Be ([ModeloDFe]::NFe)
                $results[1].Modelo | Should -Be ([ModeloDFe]::CTe)
                $results[2].Modelo | Should -Be ([ModeloDFe]::MDFe)
            }

            It 'Processes supported and unsupported documents independently' {
                [xml]$xml1 = '<NFe />'
                [xml]$xml2 = '<UnknownDocument />'
                [xml]$xml3 = '<CTe />'

                $results = @($xml1, $xml2, $xml3) | Get-DFeDocumentInfo

                $results.Count | Should -Be 2

                $results[0].Modelo | Should -Be ([ModeloDFe]::NFe)
                $results[1].Modelo | Should -Be ([ModeloDFe]::CTe)
            }

            It 'Does not reuse information from a previous pipeline input' {
                [xml]$xml1 = '<NFe />'
                [xml]$xml2 = '<UnknownDocument />'

                $results = @($xml1, $xml2) | Get-DFeDocumentInfo

                $results.Count | Should -Be 1

                $results[0].Modelo | Should -Be ([ModeloDFe]::NFe)
            }
        }

        Context 'Input validation' {

            It 'Defines Xml as a mandatory parameter' {
                $command = Get-Command -Name Get-DFeDocumentInfo

                $parameter = $command.Parameters['Xml']

                $parameter.Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute]
                    } |

                    ForEach-Object Mandatory | Should -Contain $true
            }

            It 'Validates Xml as non-null' {
                $command = Get-Command -Name Get-DFeDocumentInfo

                $parameter = $command.Parameters['Xml']

                $parameter.Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ValidateNotNullAttribute]
                    } |

                    Should -Not -BeNullOrEmpty
            }

            It 'Throws when Xml is null' {
                { Get-DFeDocumentInfo -Xml $null } | Should -Throw
            }
        }
    }
}
