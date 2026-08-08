#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for Get-DFeAccessKey.

.DESCRIPTION
Covers access key extraction behavior for Brazilian DFe XML elements.

Contexts:
  Valid input       - well-formed Id attributes for all supported document types
  Prefix handling   - exact match, case sensitivity, and ordinal comparison
  Structural format - exactly 44 digits, no more, no less
  Character set     - ASCII digits only, Unicode decimal digits rejected
  Whitespace        - whitespace in Id and surrounding the key is never trimmed
  Null and empty    - null node attribute, empty Id, whitespace-only Id
  Pipeline support  - XmlElement pipeline input
  Return contract   - output type, single value, no extra output
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

Describe 'Get-DFeAccessKey' {

    AfterAll {
        Remove-Module -Name PipeDFe -Force -ErrorAction SilentlyContinue
    }

    InModuleScope PipeDFe {

        BeforeAll {
            #region Helpers
            # Creates a minimal XmlElement with the given Id attribute value.
            # If $IdValue is $null the attribute is omitted entirely.
            function New-TestXmlElement {
                [CmdletBinding()]
                [OutputType([System.Xml.XmlElement])]
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
                    'PSUseShouldProcessForStateChangingFunctions',
                    '',
                    Justification = 'The test helper simply creates an XML element in memory.'
                )]
                param (
                    [Parameter()]
                    [string]$ElementName = 'infNFe',

                    [AllowNull()]
                    [string]$IdValue
                )

                $doc = [System.Xml.XmlDocument]::new()
                $doc.XmlResolver = $null

                $element = $doc.CreateElement($ElementName)

                if ($null -ne $IdValue) {
                    $element.SetAttribute('Id', $IdValue)
                }

                $element
            }

            # 44-digit key used throughout the suite.
            # Chosen to be structurally valid without carrying real fiscal meaning.
            $Script:ValidKey = '35260712345678000195550010000012341234567890'
            #endregion
        }

        Context 'Valid input' {

            It 'Extracts the access key from an NF-e element' {
                $node = New-TestXmlElement -IdValue "NFe$Script:ValidKey"

                $result = Get-DFeAccessKey -Node $node -Prefix 'NFe'
                $result | Should -Be $Script:ValidKey
            }

            It 'Extracts the access key from a CT-e element' {
                $node = New-TestXmlElement -ElementName 'infCte' -IdValue "CTe$Script:ValidKey"

                $result = Get-DFeAccessKey -Node $node -Prefix 'CTe'
                $result | Should -Be $Script:ValidKey
            }

            It 'Extracts the access key from an MDF-e element' {
                $node = New-TestXmlElement -ElementName 'infMDFe' -IdValue "MDFe$Script:ValidKey"

                $result = Get-DFeAccessKey -Node $node -Prefix 'MDFe'
                $result | Should -Be $Script:ValidKey
            }

            It 'Extracts the access key from an NFC-e element' {
                $node = New-TestXmlElement -ElementName 'infNFe' -IdValue "NF3e$Script:ValidKey"

                $result = Get-DFeAccessKey -Node $node -Prefix 'NF3e'
                $result | Should -Be $Script:ValidKey
            }
        }

        Context 'Prefix handling' {

            It 'Returns nothing when the prefix does not match' {
                $node = New-TestXmlElement -IdValue "CTe$Script:ValidKey"

                $result = Get-DFeAccessKey -Node $node -Prefix 'NFe'
                $result | Should -BeNullOrEmpty
            }

            It 'Is case-sensitive - lowercase prefix does not match uppercase Id' {
                $node = New-TestXmlElement -IdValue "NFe$Script:ValidKey"

                $result = Get-DFeAccessKey -Node $node -Prefix 'nfe'
                $result | Should -BeNullOrEmpty
            }

            It 'Is case-sensitive - uppercase prefix does not match lowercase Id' {
                $node = New-TestXmlElement -IdValue "nfe$Script:ValidKey"

                $result = Get-DFeAccessKey -Node $node -Prefix 'NFe'
                $result | Should -BeNullOrEmpty
            }

            It 'Returns nothing when the Id contains only the prefix and no key' {
                $node = New-TestXmlElement -IdValue 'NFe'

                $result = Get-DFeAccessKey -Node $node -Prefix 'NFe'
                $result | Should -BeNullOrEmpty
            }

            It 'Treats the prefix as a literal string - special regex characters are not interpreted' {
                # Prefix contains a regex metacharacter. The function must not
                # treat it as a pattern. The Id does not start with this literal
                # prefix, so the result must be empty.
                $node = New-TestXmlElement -IdValue "NFe$Script:ValidKey"

                $result = Get-DFeAccessKey -Node $node -Prefix 'NF.'
                $result | Should -BeNullOrEmpty
            }
        }

        Context 'Structural format - digit count' {

            It 'Returns nothing when the key contains 43 digits' {
                $shortKey = $Script:ValidKey.Substring(1)   # 43 digits
                $node = New-TestXmlElement -IdValue "NFe$shortKey"

                $result = Get-DFeAccessKey -Node $node -Prefix 'NFe'
                $result | Should -BeNullOrEmpty
            }

            It 'Returns nothing when the key contains 45 digits' {
                $longKey = $Script:ValidKey + '0'   # 45 digits
                $node = New-TestXmlElement -IdValue "NFe$longKey"

                $result = Get-DFeAccessKey -Node $node -Prefix 'NFe'
                $result | Should -BeNullOrEmpty
            }

            It 'Returns nothing when the key contains non-digit characters' {
                $keyWithLetters = $Script:ValidKey.Substring(0, 43) + 'A'
                $node = New-TestXmlElement -IdValue "NFe$keyWithLetters"

                $result = Get-DFeAccessKey -Node $node -Prefix 'NFe'
                $result | Should -BeNullOrEmpty
            }
        }

        Context 'Character set' {

            It 'Accepts only ASCII digits - rejects Unicode decimal digit (Bengali ১)' {
                # U+09E7 BENGALI DIGIT ONE - matched by \d but not by [0-9].
                # The key must be rejected because it contains a non-ASCII digit.
                $unicodeDigit = [char]0x09E7
                $keyWithUnicode = $Script:ValidKey.Substring(0, 43) + $unicodeDigit
                $node = New-TestXmlElement -IdValue "NFe$keyWithUnicode"

                $result = Get-DFeAccessKey -Node $node -Prefix 'NFe'
                $result | Should -BeNullOrEmpty
            }

            It 'Accepts only ASCII digits - rejects Unicode decimal digit (Arabic-Indic ١)' {
                # U+0661 ARABIC-INDIC DIGIT ONE.
                $unicodeDigit = [char]0x0661
                $keyWithUnicode = $Script:ValidKey.Substring(0, 43) + $unicodeDigit
                $node = New-TestXmlElement -IdValue "NFe$keyWithUnicode"

                $result = Get-DFeAccessKey -Node $node -Prefix 'NFe'
                $result | Should -BeNullOrEmpty
            }

            It 'Rejects a key that contains a hyphen' {
                $keyWithHyphen = $Script:ValidKey.Substring(0, 43) + '-'
                $node = New-TestXmlElement -IdValue "NFe$keyWithHyphen"

                $result = Get-DFeAccessKey -Node $node -Prefix 'NFe'
                $result | Should -BeNullOrEmpty
            }
        }

        Context 'Whitespace - never trimmed' {

            It 'Returns nothing when a space follows the prefix before the key' {
                $node = New-TestXmlElement -IdValue "NFe $Script:ValidKey"

                $result = Get-DFeAccessKey -Node $node -Prefix 'NFe'
                $result | Should -BeNullOrEmpty
            }

            It 'Returns nothing when a space follows the key' {
                $node = New-TestXmlElement -IdValue "NFe${ValidKey} "

                $result = Get-DFeAccessKey -Node $node -Prefix 'NFe'
                $result | Should -BeNullOrEmpty
            }

            It 'Returns nothing when the Id is whitespace only' {
                $node = New-TestXmlElement -IdValue '   '

                $result = Get-DFeAccessKey -Node $node -Prefix 'NFe'
                $result | Should -BeNullOrEmpty
            }

            It 'Returns nothing when the Id is an empty string' {
                $node = New-TestXmlElement -IdValue ''

                $result = Get-DFeAccessKey -Node $node -Prefix 'NFe'
                $result | Should -BeNullOrEmpty
            }
        }

        Context 'Missing Id attribute' {

            It 'Returns nothing when the Id attribute is absent' {
                # New-TestXmlElement omits the attribute when $IdValue is $null.
                $node = New-TestXmlElement -IdValue $null

                $result = Get-DFeAccessKey -Node $node -Prefix 'NFe'
                $result | Should -BeNullOrEmpty
            }
        }

        Context 'Pipeline support' {

            It 'Accepts an XmlElement from the pipeline' {
                $node = New-TestXmlElement -IdValue "NFe$Script:ValidKey"

                $result = $node | Get-DFeAccessKey -Prefix 'NFe'
                $result | Should -Be $Script:ValidKey
            }

            It 'Processes multiple elements from the pipeline' {
                $node1 = New-TestXmlElement -IdValue "NFe$Script:ValidKey"
                $node2 = New-TestXmlElement -IdValue "NFe$Script:ValidKey"

                $results = $node1, $node2 | Get-DFeAccessKey -Prefix 'NFe'

                $results | Should -HaveCount 2
                $results | Should -Be @($Script:ValidKey, $Script:ValidKey)
            }

            It 'Produces no output for invalid elements in a mixed pipeline batch' {
                $validNode   = New-TestXmlElement -IdValue "NFe$Script:ValidKey"
                $invalidNode = New-TestXmlElement -IdValue 'NFe_INVALID'

                $results = $validNode, $invalidNode | Get-DFeAccessKey -Prefix 'NFe'

                $results | Should -HaveCount 1
                $results | Should -Be $Script:ValidKey
            }
        }

        Context 'Return contract' {

            It 'Returns a System.String' {
                $node = New-TestXmlElement -IdValue "NFe$Script:ValidKey"

                $result = Get-DFeAccessKey -Node $node -Prefix 'NFe'
                $result | Should -BeOfType [string]
            }

            It 'Returns exactly one value for a valid element' {
                $node = New-TestXmlElement -IdValue "NFe$Script:ValidKey"

                $results = @(Get-DFeAccessKey -Node $node -Prefix 'NFe')
                $results | Should -HaveCount 1
            }

            It 'Returns exactly 44 characters' {
                $node = New-TestXmlElement -IdValue "NFe$Script:ValidKey"

                $result = Get-DFeAccessKey -Node $node -Prefix 'NFe'
                $result.Length | Should -Be 44
            }

            It 'Returns a value composed entirely of ASCII digits' {
                $node = New-TestXmlElement -IdValue "NFe$Script:ValidKey"

                $result = Get-DFeAccessKey -Node $node -Prefix 'NFe'
                $result | Should -Match '^[0-9]{44}$'
            }
        }

        Context 'Input validation' {

            It 'Defines Node as a mandatory parameter' {
                $command = Get-Command -Name Get-DFeAccessKey

                $parameter = $command.Parameters['Node']

                $parameter.Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute]
                    } |

                    ForEach-Object Mandatory | Should -Contain $true
            }

            It 'Defines Prefix as a mandatory parameter' {
                $command = Get-Command -Name Get-DFeAccessKey

                $parameter = $command.Parameters['Prefix']

                $parameter.Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute]
                    } |

                    ForEach-Object Mandatory | Should -Contain $true
            }

            It 'Throws when Prefix is an empty string' {
                $node = New-TestXmlElement -IdValue "NFe$Script:ValidKey"

                { Get-DFeAccessKey -Node $node -Prefix '' } | Should -Throw
            }

            It 'Throws when Prefix is whitespace only' {
                $node = New-TestXmlElement -IdValue "NFe$Script:ValidKey"

                { Get-DFeAccessKey -Node $node -Prefix '   ' } | Should -Throw
            }
        }
    }
}
