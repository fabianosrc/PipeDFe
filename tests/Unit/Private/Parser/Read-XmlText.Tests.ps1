#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for Read-XmlText.

.DESCRIPTION
Validates safe extraction of XML node text, including trimming behavior,
null handling, whitespace handling, pipeline input, parameter metadata,
and function metadata.

Contexts:
  Happy path          - valid XML nodes returning text
  Null and whitespace - null nodes and empty text handling
  Pipeline support    - ValueFromPipeline and ValueFromPipelineByPropertyName
  Parameter behavior  - AllowNull and optional parameter metadata
  Function metadata   - CmdletBinding, OutputType and help metadata
#>

BeforeDiscovery {
    $moduleRoot = (Get-Item $PSScriptRoot).Parent.Parent.Parent.Parent.FullName

    $moduleName = Join-Path -Path $moduleRoot -ChildPath 'PipeDFe.psd1'

    Import-Module -Name $moduleName -Force -Global -ErrorAction Stop
}

Describe 'Read-XmlText' {

    AfterAll {
        Remove-Module PipeDFe -Force -ErrorAction SilentlyContinue
    }

    InModuleScope PipeDFe {

        BeforeEach {

            $xml = @'
            <root>
                <value>ACME LTDA</value>
                <spaces>   ACME LTDA   </spaces>
                <empty></empty>
                <blank>     </blank>
                <mixed> ACME <b>LTDA</b> </mixed>
            </root>
'@
            $xmlDocument = [System.Xml.XmlDocument]::new()
            $xmlDocument.LoadXml($xml)
        }

        Context 'Happy path' {

            It 'returns the InnerText of the supplied node' {
                $node = $xmlDocument.DocumentElement.SelectSingleNode('value')

                $result = $node | Read-XmlText
                $result | Should -Be 'ACME LTDA'
            }

            It 'returns concatenated InnerText for mixed nodes' {
                $node = $xmlDocument.DocumentElement.SelectSingleNode('mixed')

                $result = $node | Read-XmlText
                $result | Should -Be 'ACME LTDA'
            }

            It 'trims leading and trailing whitespace' {
                $node = $xmlDocument.DocumentElement.SelectSingleNode('spaces')

                $result = $node | Read-XmlText
                $result | Should -Be 'ACME LTDA'
            }
        }

        Context 'Null and whitespace handling' {

            It 'returns $null when XmlNode is $null' {
                $result = $null | Read-XmlText
                $result | Should -BeNullOrEmpty
            }

            It 'returns $null for an empty element' {
                $node = $xmlDocument.DocumentElement.SelectSingleNode('empty')

                $result = $node | Read-XmlText
                $result | Should -BeNullOrEmpty
            }

            It 'does not emit pipeline output for empty elements' {
                $node = $xmlDocument.DocumentElement.SelectSingleNode('empty')

                @($node | Read-XmlText).Count | Should -Be 0
            }

            It 'returns $null when InnerText contains only whitespace' {
                $node = $xmlDocument.DocumentElement.SelectSingleNode('blank')

                $result = $node | Read-XmlText
                $result | Should -BeNullOrEmpty
            }

            It 'does not throw when XmlNode is $null' {
                { $null | Read-XmlText } | Should -Not -Throw
            }
        }

        Context 'Pipeline support' {

            It 'accepts XmlNode via ValueFromPipeline' {
                $node = $xmlDocument.DocumentElement.SelectSingleNode('value')

                $result = $node | Read-XmlText
                $result | Should -Be 'ACME LTDA'
            }

            It 'accepts XmlNode via ValueFromPipelineByPropertyName using the Node alias' {
                $node = $xmlDocument.DocumentElement.SelectSingleNode('value')

                $result = [PSCustomObject]@{ Node = $node } | Read-XmlText
                $result | Should -Be 'ACME LTDA'
            }

            It 'processes multiple pipeline items independently' {
                $results = @(
                    $xmlDocument.DocumentElement.SelectSingleNode('value')
                    $xmlDocument.DocumentElement.SelectSingleNode('empty')
                    $xmlDocument.DocumentElement.SelectSingleNode('spaces')
                ) | Read-XmlText

                $results.Count | Should -Be 2

                $results[0] | Should -Be 'ACME LTDA'
                $results[1] | Should -Be 'ACME LTDA'
            }
        }

        Context 'Parameter behavior' {

            It 'does not require XmlNode (not Mandatory)' {
                $parameter = (Get-Command Read-XmlText).Parameters['XmlNode']

                $parameter.Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute]
                    } |
                    Select-Object -ExpandProperty Mandatory |
                    Should -Not -Contain $true
            }

            It 'allows a null XmlNode' {
                $parameter = (Get-Command Read-XmlText).Parameters['XmlNode']

                $parameter.Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.AllowNullAttribute]
                    } |
                    Should -Not -BeNullOrEmpty
            }
        }

        Context 'Function metadata' {

            It 'exposes CmdletBinding (supports common parameters)' {
                (Get-Command -Name Read-XmlText).CmdletBinding | Should -BeTrue
            }

            It 'declares OutputType of System.String' {
                (Get-Command -Name Read-XmlText).OutputType.Type | Should -Contain ([string])
            }

            It 'exposes comment-based help with a Synopsis' {
                (Get-Help -Name Read-XmlText).Synopsis | Should -Not -BeNullOrEmpty
            }
        }

        Context 'Parameter metadata' {

            BeforeAll {
                $command = Get-Command -Name Read-XmlText

                $parameter = $command.Parameters['XmlNode']

                $Script:Attribute = $parameter.Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute]
                    }
            }

            It 'uses System.Xml.XmlNode as parameter type' {
                $parameter.ParameterType | Should -Be ([System.Xml.XmlNode])
            }

            It 'accepts pipeline input' {
                $Script:Attribute.ValueFromPipeline | Should -BeTrue
            }

            It 'accepts pipeline input by property name' {
                $Script:Attribute.ValueFromPipelineByPropertyName | Should -BeTrue
            }

            It 'defines the Node alias' {
                $parameter.Aliases | Should -Contain 'Node'
            }

            It 'is optional' {
                $Script:Attribute.Mandatory | Should -BeFalse
            }

            It 'allows null values' {
                $parameter.Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.AllowNullAttribute]
                    } |
                    Should -Not -BeNullOrEmpty
            }
        }
    }
}
