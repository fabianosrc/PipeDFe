#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for Get-DFeNFeDirection.

.DESCRIPTION
Covers NF-e direction classification relative to a company CNPJ.

Coverage includes:
  Direction classification - outgoing, incoming and third-party invoices
  Classification priority  - issuer takes precedence over recipient
  Incomplete documents     - missing or invalid participant CNPJs
  Company identification   - full CNPJ matching and branch isolation
  XML structure            - NFe, nfeProc and namespace handling
  Unsupported documents    - invalid roots, missing infNFe and fiscal models
  Result contract          - supported direction values and output type
  Input validation         - mandatory parameters and invalid inputs
  Invocation isolation     - independent classification across calls
#>

BeforeDiscovery {
    # InModuleScope needs to resolve the PipeDFe module during the Discovery phase,
    # because that's when Context/It are executed to register the test tree. If the
    # module isn't loaded at that point, InModuleScope fails before any BeforeAll or
    # BeforeEach ever runs.
    $moduleRoot = (Get-Item $PSScriptRoot).Parent.Parent.Parent.Parent.FullName

    $modulePath = Join-Path -Path $moduleRoot -ChildPath 'PipeDFe.psd1'

    Import-Module -Name $modulePath -Force -Global -ErrorAction Stop
}

Describe 'Get-DFeNFeDirection' -Tag 'Unit' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {
            $script:CompanyCnpj  = '28775139000126'
            $script:BranchCnpj   = '28775139000207'
            $script:SupplierCnpj = '12345678000199'
            $script:OtherCnpj    = '11222333000144'

            function New-TestNFeXml {
                [CmdletBinding()]
                [OutputType([System.Xml.XmlDocument])]
                param (
                    [Parameter()]
                    [AllowNull()]
                    [string]$IssuerCnpj,

                    [Parameter()]
                    [AllowNull()]
                    [string]$RecipientCnpj,

                    [Parameter()]
                    [string]$Model = '55',

                    [Parameter()]
                    [switch]$WithoutWrapper,

                    [Parameter()]
                    [switch]$WithoutNamespace
                )

                $issuerElement = if ($null -eq $IssuerCnpj) {
                    '<emit />'
                } else {
                    "<emit><CNPJ>$IssuerCnpj</CNPJ></emit>"
                }

                $recipientElement = if ($null -eq $RecipientCnpj) {
                    '<dest />'
                } else {
                    "<dest><CNPJ>$RecipientCnpj</CNPJ></dest>"
                }

                $namespace = if ($WithoutNamespace) {
                    [string]::Empty
                } else {
                    ' xmlns="http://www.portalfiscal.inf.br/nfe"'
                }

                $nfeContent = @"
<NFe$namespace>
    <infNFe>
        <ide>
            <mod>$Model</mod>
        </ide>
        $issuerElement
        $recipientElement
    </infNFe>
</NFe>
"@

                $xmlContent = if ($WithoutWrapper) {
                    $nfeContent
                } else {
                    "<nfeProc$namespace>$nfeContent</nfeProc>"
                }

                return [System.Xml.XmlDocument]$xmlContent
            }
        }

        #region Direction classification
        Context 'Direction classification' {

            It 'Classifies an invoice issued by the company as Saida' {
                $xmlParams = @{
                    IssuerCnpj    = $script:CompanyCnpj
                    RecipientCnpj = $script:SupplierCnpj
                }

                $xml    = New-TestNFeXml @xmlParams
                $result = Get-DFeNFeDirection -Xml $xml -Cnpj $script:CompanyCnpj

                $result | Should -Be 'Saida'
            }

            It 'Classifies an invoice received by the company as Entrada' {
                $xmlParams = @{
                    IssuerCnpj    = $script:SupplierCnpj
                    RecipientCnpj = $script:CompanyCnpj
                }

                $xml    = New-TestNFeXml @xmlParams
                $result = Get-DFeNFeDirection -Xml $xml -Cnpj $script:CompanyCnpj

                $result | Should -Be 'Entrada'
            }

            It 'Classifies an invoice unrelated to the company as Terceiro' {
                $xmlParams = @{
                    IssuerCnpj    = $script:SupplierCnpj
                    RecipientCnpj = $script:OtherCnpj
                }

                $xml    = New-TestNFeXml @xmlParams
                $result = Get-DFeNFeDirection -Xml $xml -Cnpj $script:CompanyCnpj

                $result | Should -Be 'Terceiro'
            }
        }
        #endregion

        #region Classification priority
        Context 'Classification priority' {

            It 'Classifies a self-issued invoice as Saida' {
                $xmlParams = @{
                    IssuerCnpj    = $script:CompanyCnpj
                    RecipientCnpj = $script:CompanyCnpj
                }

                $xml    = New-TestNFeXml @xmlParams
                $result = Get-DFeNFeDirection -Xml $xml -Cnpj $script:CompanyCnpj

                $result | Should -Be 'Saida'
            }

            It 'Prioritizes issuer ownership when recipient CNPJ is missing' {
                $xmlParams = @{
                    IssuerCnpj    = $script:CompanyCnpj
                    RecipientCnpj = $null
                }

                $xml    = New-TestNFeXml @xmlParams
                $result = Get-DFeNFeDirection -Xml $xml -Cnpj $script:CompanyCnpj

                $result | Should -Be 'Saida'
            }

            It 'Classifies as Entrada when issuer CNPJ is missing but recipient matches' {
                $xmlParams = @{
                    IssuerCnpj    = $null
                    RecipientCnpj = $script:CompanyCnpj
                }

                $xml    = New-TestNFeXml @xmlParams
                $result = Get-DFeNFeDirection -Xml $xml -Cnpj $script:CompanyCnpj

                $result | Should -Be 'Entrada'
            }
        }
        #endregion

        #region Incomplete documents
        Context 'Incomplete documents' {

            It 'Returns Indeterminado when issuer CNPJ is missing and recipient does not match' {
                $xmlParams = @{
                    IssuerCnpj    = $null
                    RecipientCnpj = $script:SupplierCnpj
                }

                $xml    = New-TestNFeXml @xmlParams
                $result = Get-DFeNFeDirection -Xml $xml -Cnpj $script:CompanyCnpj

                $result | Should -Be 'Indeterminado'
            }

            It 'Returns Indeterminado when recipient CNPJ is missing and issuer does not match' {
                $xmlParams = @{
                    IssuerCnpj    = $script:SupplierCnpj
                    RecipientCnpj = $null
                }

                $xml    = New-TestNFeXml @xmlParams
                $result = Get-DFeNFeDirection -Xml $xml -Cnpj $script:CompanyCnpj

                $result | Should -Be 'Indeterminado'
            }

            It 'Returns Indeterminado when both participant CNPJs are missing' {
                $xml    = New-TestNFeXml -IssuerCnpj $null -RecipientCnpj $null
                $result = Get-DFeNFeDirection -Xml $xml -Cnpj $script:CompanyCnpj

                $result | Should -Be 'Indeterminado'
            }

            It 'Returns Indeterminado when issuer CNPJ has an invalid format' {
                $xmlParams = @{
                    IssuerCnpj    = '123'
                    RecipientCnpj = $script:SupplierCnpj
                }

                $xml    = New-TestNFeXml @xmlParams
                $result = Get-DFeNFeDirection -Xml $xml -Cnpj $script:CompanyCnpj

                $result | Should -Be 'Indeterminado'
            }

            It 'Returns Indeterminado when recipient CNPJ has an invalid format' {
                $xmlParams = @{
                    IssuerCnpj    = $script:SupplierCnpj
                    RecipientCnpj = '123'
                }

                $xml    = New-TestNFeXml @xmlParams
                $result = Get-DFeNFeDirection -Xml $xml -Cnpj $script:CompanyCnpj

                $result | Should -Be 'Indeterminado'
            }
        }
        #endregion

        #region Company identification
        Context 'Company identification' {

            It 'Uses the complete company CNPJ rather than the eight-digit root' {
                $xmlParams = @{
                    IssuerCnpj    = $script:BranchCnpj
                    RecipientCnpj = $script:SupplierCnpj
                }

                $xml    = New-TestNFeXml @xmlParams
                $result = Get-DFeNFeDirection -Xml $xml -Cnpj $script:CompanyCnpj

                $result | Should -Be 'Terceiro'
            }

            It 'Classifies another branch as Entrada only when it is the recipient' {
                $xmlParams = @{
                    IssuerCnpj    = $script:BranchCnpj
                    RecipientCnpj = $script:CompanyCnpj
                }

                $xml    = New-TestNFeXml @xmlParams
                $result = Get-DFeNFeDirection -Xml $xml -Cnpj $script:CompanyCnpj

                $result | Should -Be 'Entrada'
            }

            It 'Uses the supplied company CNPJ rather than a fixed company identity' {
                $xmlParams = @{
                    IssuerCnpj    = $script:BranchCnpj
                    RecipientCnpj = $script:SupplierCnpj
                }

                $xml    = New-TestNFeXml @xmlParams
                $result = Get-DFeNFeDirection -Xml $xml -Cnpj $script:BranchCnpj

                $result | Should -Be 'Saida'
            }
        }
        #endregion

        #region XML structure
        Context 'XML structure' {

            It 'Supports NFe as the document root' {
                $xmlParams = @{
                    IssuerCnpj    = $script:CompanyCnpj
                    RecipientCnpj = $script:SupplierCnpj
                    WithoutWrapper = $true
                }

                $xml    = New-TestNFeXml @xmlParams
                $result = Get-DFeNFeDirection -Xml $xml -Cnpj $script:CompanyCnpj

                $result | Should -Be 'Saida'
            }

            It 'Supports nfeProc as the document root' {
                $xmlParams = @{
                    IssuerCnpj    = $script:SupplierCnpj
                    RecipientCnpj = $script:CompanyCnpj
                }

                $xml    = New-TestNFeXml @xmlParams
                $result = Get-DFeNFeDirection -Xml $xml -Cnpj $script:CompanyCnpj

                $result | Should -Be 'Entrada'
            }

            It 'Supports XML documents without a namespace' {
                $xmlParams = @{
                    IssuerCnpj      = $script:CompanyCnpj
                    RecipientCnpj   = $script:SupplierCnpj
                    WithoutNamespace = $true
                }

                $xml    = New-TestNFeXml @xmlParams
                $result = Get-DFeNFeDirection -Xml $xml -Cnpj $script:CompanyCnpj

                $result | Should -Be 'Saida'
            }

            It 'Supports explicitly prefixed XML elements' {
                [xml]$xml = @"
<nfe:nfeProc xmlns:nfe="http://www.portalfiscal.inf.br/nfe">
    <nfe:NFe>
        <nfe:infNFe>
            <nfe:ide>
                <nfe:mod>55</nfe:mod>
            </nfe:ide>
            <nfe:emit>
                <nfe:CNPJ>$($script:CompanyCnpj)</nfe:CNPJ>
            </nfe:emit>
            <nfe:dest>
                <nfe:CNPJ>$($script:SupplierCnpj)</nfe:CNPJ>
            </nfe:dest>
        </nfe:infNFe>
    </nfe:NFe>
</nfe:nfeProc>
"@

                $result = Get-DFeNFeDirection -Xml $xml -Cnpj $script:CompanyCnpj

                $result | Should -Be 'Saida'
            }
        }
        #endregion

        #region Unsupported documents
        Context 'Unsupported documents' {

            It 'Rejects XML with an unsupported root' {
                [xml]$xml = '<UnknownDocument />'

                { Get-DFeNFeDirection -Xml $xml -Cnpj $script:CompanyCnpj } |
                    Should -Throw
            }

            It 'Rejects XML without infNFe' {
                [xml]$xml = '<NFe xmlns="http://www.portalfiscal.inf.br/nfe" />'

                { Get-DFeNFeDirection -Xml $xml -Cnpj $script:CompanyCnpj } |
                    Should -Throw
            }

            It 'Rejects an NFC-e document with model 65' {
                $xmlParams = @{
                    IssuerCnpj    = $script:CompanyCnpj
                    RecipientCnpj = $script:SupplierCnpj
                    Model         = '65'
                }

                $xml = New-TestNFeXml @xmlParams

                { Get-DFeNFeDirection -Xml $xml -Cnpj $script:CompanyCnpj } |
                    Should -Throw
            }

            It 'Rejects an unsupported fiscal model' {
                $xmlParams = @{
                    IssuerCnpj    = $script:CompanyCnpj
                    RecipientCnpj = $script:SupplierCnpj
                    Model         = '99'
                }

                $xml = New-TestNFeXml @xmlParams

                { Get-DFeNFeDirection -Xml $xml -Cnpj $script:CompanyCnpj } |
                    Should -Throw
            }

            It 'Rejects XML with a missing fiscal model' {
                [xml]$xml = @"
<NFe xmlns="http://www.portalfiscal.inf.br/nfe">
    <infNFe>
        <ide />
        <emit>
            <CNPJ>$($script:CompanyCnpj)</CNPJ>
        </emit>
    </infNFe>
</NFe>
"@

                { Get-DFeNFeDirection -Xml $xml -Cnpj $script:CompanyCnpj } |
                    Should -Throw
            }
        }
        #endregion

        #region Result contract
        Context 'Result contract' {

            It 'Returns a String' {
                $xmlParams = @{
                    IssuerCnpj    = $script:CompanyCnpj
                    RecipientCnpj = $script:SupplierCnpj
                }

                $xml    = New-TestNFeXml @xmlParams
                $result = Get-DFeNFeDirection -Xml $xml -Cnpj $script:CompanyCnpj

                $result | Should -BeOfType ([string])
            }

            It 'Returns exactly one result per invocation' {
                $xmlParams = @{
                    IssuerCnpj    = $script:CompanyCnpj
                    RecipientCnpj = $script:SupplierCnpj
                }

                $xml     = New-TestNFeXml @xmlParams
                $results = @(Get-DFeNFeDirection -Xml $xml -Cnpj $script:CompanyCnpj)

                $results    | Should -HaveCount 1
                $results[0] | Should -Be 'Saida'
            }

            It 'Returns only supported direction values' {
                $cases = @(
                    @{
                        Issuer    = $script:CompanyCnpj
                        Recipient = $script:SupplierCnpj
                    }
                    @{
                        Issuer    = $script:SupplierCnpj
                        Recipient = $script:CompanyCnpj
                    }
                    @{
                        Issuer    = $script:SupplierCnpj
                        Recipient = $script:OtherCnpj
                    }
                    @{
                        Issuer    = $null
                        Recipient = $script:SupplierCnpj
                    }
                )

                $supportedValues = @('Saida', 'Entrada', 'Terceiro', 'Indeterminado')

                foreach ($case in $cases) {
                    $xmlParams = @{
                        IssuerCnpj    = $case.Issuer
                        RecipientCnpj = $case.Recipient
                    }

                    $xml    = New-TestNFeXml @xmlParams
                    $result = Get-DFeNFeDirection -Xml $xml -Cnpj $script:CompanyCnpj

                    $result | Should -BeIn $supportedValues
                }
            }
        }
        #endregion

        #region Input validation
        Context 'Input validation' {

            BeforeAll {

                $script:Command = Get-Command -Name Get-DFeNFeDirection
            }

            It 'Requires Xml' {
                $parameter = $script:Command.Parameters['Xml']

                $parameter.Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute]
                    } |

                    Select-Object -First 1 |
                    ForEach-Object { $_.Mandatory | Should -BeTrue }
            }

            It 'Requires Cnpj' {
                $parameter = $script:Command.Parameters['Cnpj']

                $parameter.Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute]
                    } |

                    Select-Object -First 1 |
                    ForEach-Object { $_.Mandatory | Should -BeTrue }
            }

            It 'Declares Xml as XmlDocument' {
                $script:Command.Parameters['Xml'].ParameterType |
                    Should -Be ([System.Xml.XmlDocument])
            }

            It 'Declares Cnpj as String' {
                $script:Command.Parameters['Cnpj'].ParameterType |
                    Should -Be ([string])
            }

            It 'Rejects null Xml' {
                { Get-DFeNFeDirection -Xml $null -Cnpj $script:CompanyCnpj } |
                    Should -Throw
            }

            It 'Rejects an empty company CNPJ' {
                $xml = New-TestNFeXml

                { Get-DFeNFeDirection -Xml $xml -Cnpj '' } | Should -Throw
            }

            It 'Rejects a company CNPJ shorter than 14 digits' {
                $xml = New-TestNFeXml

                {Get-DFeNFeDirection -Xml $xml -Cnpj '12345678' } |
                    Should -Throw
            }

            It 'Rejects a company CNPJ longer than 14 digits' {
                $xml = New-TestNFeXml

                {Get-DFeNFeDirection -Xml $xml -Cnpj '123456789012345' } |
                    Should -Throw
            }

            It 'Rejects a company CNPJ containing non-digit characters' {
                $xml = New-TestNFeXml

                {Get-DFeNFeDirection -Xml $xml -Cnpj '28.775.139/0001-26' } |
                    Should -Throw
            }
        }
        #endregion

        #region Invocation isolation
        Context 'Invocation isolation' {

            It 'Classifies consecutive invocations independently' {
                $outgoingParams = @{
                    IssuerCnpj    = $script:CompanyCnpj
                    RecipientCnpj = $script:SupplierCnpj
                }

                $incomingParams = @{
                    IssuerCnpj    = $script:SupplierCnpj
                    RecipientCnpj = $script:CompanyCnpj
                }

                $thirdPartyParams = @{
                    IssuerCnpj    = $script:SupplierCnpj
                    RecipientCnpj = $script:OtherCnpj
                }

                $outgoingXml   = New-TestNFeXml @outgoingParams
                $incomingXml   = New-TestNFeXml @incomingParams
                $thirdPartyXml = New-TestNFeXml @thirdPartyParams

                $outgoingResult   = Get-DFeNFeDirection -Xml $outgoingXml   -Cnpj $script:CompanyCnpj
                $incomingResult   = Get-DFeNFeDirection -Xml $incomingXml   -Cnpj $script:CompanyCnpj
                $thirdPartyResult = Get-DFeNFeDirection -Xml $thirdPartyXml -Cnpj $script:CompanyCnpj

                $outgoingResult   | Should -Be 'Saida'
                $incomingResult   | Should -Be 'Entrada'
                $thirdPartyResult | Should -Be 'Terceiro'
            }

            It 'Does not modify the source XML' {
                $xmlParams = @{
                    IssuerCnpj    = $script:CompanyCnpj
                    RecipientCnpj = $script:SupplierCnpj
                }

                $xml         = New-TestNFeXml @xmlParams
                $originalXml = $xml.OuterXml

                Get-DFeNFeDirection -Xml $xml -Cnpj $script:CompanyCnpj | Out-Null

                $xml.OuterXml | Should -BeExactly $originalXml
            }
        }
        #endregion
    }
}
