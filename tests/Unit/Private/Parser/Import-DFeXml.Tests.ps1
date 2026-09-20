#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for Import-DFeXml.

.DESCRIPTION
Covers XML document loading, parser security configuration, pipeline support,
error handling, parameter validation and return contract.

Contexts:
  XML loading      - valid XML documents
  Pipeline support - ValueFromPipeline and FullName binding
  Return contract  - XmlDocument output
  File handling    - missing files
  XML validation   - malformed XML
  Secure parsing   - DTD and XXE protection
  Encoding         - UTF-8 and UTF-16 documents
  Input validation - mandatory parameters
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

Describe 'Import-DFeXml' {

    InModuleScope -ModuleName PipeDFe {

        BeforeEach {

            $testDirectory = Join-Path -Path $TestDrive -ChildPath 'Xml'

            New-Item -ItemType Directory -Path $testDirectory -Force | Out-Null

            $validXmlPath = Join-Path -Path $testDirectory -ChildPath 'valid.xml'

            @'
<?xml version="1.0" encoding="utf-8"?>
<root>
    <parent>
        <child>value</child>
    </parent>
</root>
'@ | Set-Content -LiteralPath $validXmlPath -Encoding UTF8

            $invalidXmlPath = Join-Path -Path $testDirectory -ChildPath 'invalid.xml'

            @'
<?xml version="1.0" encoding="utf-8"?>
<root>
    <parent>
</root>
'@ | Set-Content -LiteralPath $invalidXmlPath -Encoding UTF8

            $utf16XmlPath = Join-Path -Path $testDirectory -ChildPath 'utf16.xml'

            @'
<?xml version="1.0" encoding="utf-16"?>
    <root>
        <value>UTF16</value>
</root>
'@ | Set-Content -LiteralPath $utf16XmlPath -Encoding Unicode

            $dtdXmlPath = Join-Path -Path $testDirectory -ChildPath 'dtd.xml'

            @'
<!DOCTYPE root [ <!ELEMENT root ANY> ]>
<root/>
'@ | Set-Content -LiteralPath $dtdXmlPath -Encoding UTF8

            $xxeXmlPath = Join-Path -Path $testDirectory -ChildPath 'xxe.xml'
            @'
<!DOCTYPE root [ <!ENTITY xxe SYSTEM "file:///etc/passwd"> ]>
<root>&xxe;</root>
'@ | Set-Content -LiteralPath $xxeXmlPath -Encoding UTF8

            $Script:MissingXmlPath = Join-Path -Path $testDirectory -ChildPath 'missing.xml'
        }

        Context 'XML loading' {

            It 'Loads a valid XML document' {
                $result = Import-DFeXml -Path $validXmlPath
                $result | Should -BeOfType System.Xml.XmlDocument
            }

            It 'Returns a document element' {
                $result = Import-DFeXml -Path $validXmlPath
                $result.DocumentElement | Should -Not -BeNullOrEmpty
            }

            It 'Loads the expected root element' {
                $result = Import-DFeXml -Path $validXmlPath
                $result.DocumentElement.LocalName | Should -Be 'root'
            }

            It 'Preserves nested elements' {
                $result = Import-DFeXml -Path $validXmlPath
                $result.DocumentElement.SelectSingleNode('parent/child').InnerText |
                    Should -Be 'value'
            }
        }

        Context 'Encoding' {
            It 'Loads UTF-8 documents' {
                { Import-DFeXml -Path $validXmlPath } | Should -Not -Throw
            }

            It 'Loads UTF-16 documents' {
                $result = Import-DFeXml -Path $utf16XmlPath
                $result.DocumentElement.LocalName | Should -Be 'root'
            }
        }

        Context 'Pipeline support' {

            It 'Accepts pipeline input by value' {
                $result = $validXmlPath | Import-DFeXml
                $result.DocumentElement.LocalName | Should -Be 'root'
            }

            It 'Accepts pipeline input by FullName property' {
                $result = [pscustomobject]@{ FullName = $validXmlPath } | Import-DFeXml
                $result | Should -BeOfType System.Xml.XmlDocument
            }

            It 'Processes multiple XML files from pipeline' {
                $secondXmlPath = Join-Path -Path $testDirectory -ChildPath 'second.xml'

                @'
<?xml version="1.0" encoding="utf-8"?>
<second>
    <value>two</value>
</second>
'@ | Set-Content -LiteralPath $secondXmlPath -Encoding utf8

                $result = Get-ChildItem -Path $testDirectory -Filter '*.xml' |
                    Where-Object {
                        $_.Name -in @('valid.xml', 'second.xml')
                    } |
                    Import-DFeXml

                $result.Count | Should -Be 2
            }
        }


        Context 'Return contract' {

            It 'Does not return strings' {
                $result = Import-DFeXml -Path $validXmlPath
                $result | Should -Not -BeOfType System.String
            }
        }

        Context 'File handling' {

            It 'Throws when the XML file does not exist' {
                { Import-DFeXml -Path $Script:MissingXmlPath } | Should -Throw
            }

            It 'Returns XmlFileNotFound error id' {
                try {
                    Import-DFeXml -Path $Script:MissingXmlPath
                } catch {
                    $_.FullyQualifiedErrorId | Should -Match 'XmlFileNotFound'
                }
            }

            It 'Returns ObjectNotFound category for missing files' {
                try {
                    Import-DFeXml -Path $Script:MissingXmlPath
                } catch {
                    $_.CategoryInfo.Category | Should -Be 'ObjectNotFound'
                }
            }
        }

        Context 'XML validation' {

            It 'Throws when XML is malformed' {
                { Import-DFeXml -Path $invalidXmlPath } | Should -Throw
            }

            It 'Returns InvalidXml error id' {
                $errorRecord = $null

                try {
                    Import-DFeXml -Path $invalidXmlPath
                } catch {
                    $errorRecord = $_
                }

                $errorRecord | Should -Not -BeNullOrEmpty
                $errorRecord.FullyQualifiedErrorId | Should -Match 'InvalidXml'
            }

            It 'Returns InvalidData category for malformed XML' {
                try {
                    Import-DFeXml -Path $invalidXmlPath
                } catch {
                    $_.CategoryInfo.Category | Should -Be 'InvalidData'
                }
            }
        }

        Context 'Input validation' {

            It 'Rejects null Path' {
                { Import-DFeXml -Path $null } | Should -Throw
            }

            It 'Rejects empty Path' {
                { Import-DFeXml -Path '' } | Should -Throw
            }
        }

        Context 'Secure XML parsing' {

            It 'Rejects documents containing DTD declarations' {
                { Import-DFeXml -Path $dtdXmlPath } | Should -Throw
            }

            It 'Does not allow external entity resolution' {
                { Import-DFeXml -Path $xxeXmlPath } | Should -Throw
            }

            It 'Prevents XXE file disclosure attempts' {
                try {
                    $result = Import-DFeXml -Path $xxeXmlPath
                    $result.InnerText | Should -Not -Match 'root:'
                } catch {
                    $_.Exception | Should -Not -BeNullOrEmpty
                }
            }

            It 'Loads normal XML after secure parser configuration' {
                $result = Import-DFeXml -Path $validXmlPath
                $result.DocumentElement.LocalName | Should -Be 'root'
            }
        }

        Context 'Multiple executions' {

            It 'Can load the same XML file more than once' {
                $first = Import-DFeXml -Path $validXmlPath
                $second = Import-DFeXml -Path $validXmlPath

                $first.DocumentElement.LocalName |
                    Should -Be $second.DocumentElement.LocalName
            }

            It 'Returns independent XmlDocument instances' {
                $first = Import-DFeXml -Path $validXmlPath
                $second = Import-DFeXml -Path $validXmlPath

                [object]::ReferenceEquals($first, $second) | Should -BeFalse
            }
        }

        Context 'Regression checks' {

            It 'Does not modify the source XML file' {
                $before = Get-Content -LiteralPath $validXmlPath -Raw

                Import-DFeXml -Path $validXmlPath | Out-Null

                $after = Get-Content -LiteralPath $validXmlPath -Raw
                $after | Should -Be $before
            }
        }
    }

    AfterAll {
        Remove-Module -Name PipeDFe -Force -ErrorAction SilentlyContinue
    }
}
