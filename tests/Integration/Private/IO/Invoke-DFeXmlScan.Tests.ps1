#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Integration tests for Invoke-DFeXmlScan.

.DESCRIPTION
Verifies that Invoke-DFeXmlScan correctly discovers, parses and indexes
DFe XML files using a real SQLite index in an isolated temporary directory.

XML fixtures are minimal but structurally valid DFe documents generated
inline. All files are written to TestDrive.

Coverage includes:
  - Cnpj is mandatory and enforces 14-digit pattern.
  - XmlPath is mandatory and throws XmlPathNotFound when missing.
  - Indexes a bare NF-e document.
  - Indexes a processed NF-e document.
  - Indexes an evento document.
  - Indexes an inutilizacao document.
  - Scans subdirectories recursively.
  - Ignores non-XML files.
  - Ignores unrecognized XML files silently.
  - Ignores malformed XML files silently.
  - Does not reindex a file with the same SHA-256.
  - Produces no output.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseShouldProcessForStateChangingFunctions',
    '',
    Justification = 'Test infrastructure helpers do not ship as module functions.'
)]

param ()

# InModuleScope needs to resolve the PipeDFe module during the Discovery phase,
# because that's when Context/It are executed to register the test tree. If the
# module isn't loaded at that point, InModuleScope fails before any BeforeAll or
# BeforeEach ever runs.
BeforeDiscovery {
    $moduleRoot = (Get-Item $PSScriptRoot).Parent.Parent.Parent.Parent.FullName

    $moduleName = Join-Path -Path $moduleRoot -ChildPath 'PipeDFe.psd1'

    Import-Module -Name $moduleName -Force -Global -ErrorAction Stop
}

Describe 'Invoke-DFeXmlScan' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            $Script:OriginalLocalAppData = $env:LOCALAPPDATA

            $joinPathParams = @{
                Path      = [System.IO.Path]::GetTempPath()
                ChildPath = 'PipeDFe.Tests-' + [guid]::NewGuid().ToString('N')
            }

            $Script:TempRoot = Join-Path @joinPathParams

            New-Item -Path $Script:TempRoot -ItemType Directory -Force | Out-Null

            $env:LOCALAPPDATA = $Script:TempRoot

            $Script:Cnpj    = '12345678000199'
            $Script:XmlDir  = Join-Path -Path $TestDrive -ChildPath 'xml'

            New-Item -Path $Script:XmlDir -ItemType Directory -Force | Out-Null

            Initialize-DFeIndex -Cnpj $Script:Cnpj | Out-Null

            # Minimal valid NF-e bare XML.
            # chave is 44 digits: cUF(2) + AAMM(4) + CNPJ(14) + mod(2) + serie(3) + nNF(9) + tpEmis(1) + cNF(8) + cDV(1)
            $Script:ChaveNFe    = '35260112345678000199550010000000011234567890'
            $Script:ChaveNFeTwo = '35260112345678000199550010000000021234567890'
            $Script:ChavePai    = $Script:ChaveNFe

            $Script:NFeXml = @"
<?xml version="1.0" encoding="utf-8"?>
<NFe xmlns="http://www.portalfiscal.inf.br/nfe">
    <infNFe Id="NFe$($Script:ChaveNFe)">
        <ide>
            <dhEmi>2026-08-15T10:00:00-03:00</dhEmi>
            <serie>001</serie>
            <nNF>1</nNF>
        </ide>
    </infNFe>
</NFe>
"@

            $Script:NFeProcXml = @"
<?xml version="1.0" encoding="utf-8"?>
<nfeProc xmlns="http://www.portalfiscal.inf.br/nfe">
    <NFe>
        <infNFe Id="NFe$($Script:ChaveNFeTwo)">
        <ide>
            <dhEmi>2026-08-15T10:00:00-03:00</dhEmi>
            <serie>001</serie>
            <nNF>2</nNF>
        </ide>
        </infNFe>
    </NFe>
</nfeProc>
"@

            $Script:EventoXml = @"
<?xml version="1.0" encoding="utf-8"?>
<procEventoNFe xmlns="http://www.portalfiscal.inf.br/nfe">
    <evento>
        <infEvento>
        <chNFe>$($Script:ChavePai)</chNFe>
        <tpEvento>110111</tpEvento>
        <detEvento>
            <descEvento>Carta de Correcao</descEvento>
        </detEvento>
        </infEvento>
    </evento>
</procEventoNFe>
"@

            $Script:InutXml = @"
<?xml version="1.0" encoding="utf-8"?>
<inutNFe xmlns="http://www.portalfiscal.inf.br/nfe">
    <infInut Id="ID35260112345678000199550010000000110000002">
        <serie>001</serie>
        <nNFIni>11</nNFIni>
        <nNFFin>20</nNFFin>
    </infInut>
</inutNFe>
"@

            $Script:UnknownXml = @"
<?xml version="1.0" encoding="utf-8"?>
<UnknownDocument xmlns="http://unknown.ns/">
    <data>test</data>
</UnknownDocument>
"@

            function Write-XmlFixture {
                [CmdletBinding()]
                param (
                    [Parameter(Mandatory)]
                    [string]$Path,

                    [Parameter(Mandatory)]
                    [string]$Content
                )

                $bytes = [System.Text.Encoding]::UTF8.GetBytes($Content)
                [System.IO.File]::WriteAllBytes($Path, $bytes)
            }
        }

        AfterAll {

            $env:LOCALAPPDATA = $Script:OriginalLocalAppData

            $removeItemParams = @{
                LiteralPath = $Script:TempRoot
                Recurse     = $true
                Force       = $true
                ErrorAction  = 'SilentlyContinue'
            }

            Remove-Item @removeItemParams
        }

        #region Parameter contract
        Context 'Parameter contract' {

            It 'Declares Cnpj as mandatory' {
                $mandatory = (Get-Command Invoke-DFeXmlScan).Parameters['Cnpj'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.Mandatory
                    }

                $mandatory | Should -Not -BeNullOrEmpty
            }

            It 'Declares XmlPath as mandatory' {
                $mandatory = (Get-Command Invoke-DFeXmlScan).Parameters['XmlPath'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.Mandatory
                    }

                $mandatory | Should -Not -BeNullOrEmpty
            }

            It 'Rejects a Cnpj shorter than 14 digits' {
                $scanParams = @{
                    Cnpj    = '1234567800019'
                    XmlPath = $Script:XmlDir
                }

                { Invoke-DFeXmlScan @scanParams } | Should -Throw
            }

            It 'Rejects a Cnpj with invalid characters' {
                $scanParams = @{
                    Cnpj    = '12345678000!9X'
                    XmlPath = $Script:XmlDir
                }

                { Invoke-DFeXmlScan @scanParams } | Should -Throw
            }

            It 'Throws XmlPathNotFound when XmlPath does not exist' {
                $thrown = $null

                try {
                    $scanParams = @{
                        Cnpj        = $Script:Cnpj
                        XmlPath     = 'C:\does\not\exist'
                        ErrorAction = 'Stop'
                    }

                    Invoke-DFeXmlScan @scanParams
                } catch {
                    $thrown = $_
                }

                $thrown.FullyQualifiedErrorId | Should -BeLike 'XmlPathNotFound*'
            }
        }
        #endregion

        #region Document indexing
        Context 'Document indexing' {

            BeforeAll {

                $Script:ScanDir = Join-Path -Path $TestDrive -ChildPath 'scan-doc'

                New-Item -Path $Script:ScanDir -ItemType Directory -Force | Out-Null

                $xmlFixtureParamsOne = @{
                    Path    = Join-Path $Script:ScanDir 'nfe.xml'
                    Content = $Script:NFeXml
                }

                Write-XmlFixture @xmlFixtureParamsOne

                $xmlFixtureParamsTwo = @{
                    Path    = Join-Path $Script:ScanDir 'nfeProc.xml'
                    Content = $Script:NFeProcXml
                }

                Write-XmlFixture @xmlFixtureParamsTwo

                $scanParams = @{
                    Cnpj    = $Script:Cnpj
                    XmlPath = $Script:ScanDir
                }

                Invoke-DFeXmlScan @scanParams
            }

            It 'Indexes a bare NF-e document' {
                $getParams = @{
                    Cnpj = $Script:Cnpj
                }

                $results = @(Get-DFeDocumentEntry @getParams)

                $chaves  = $results | Select-Object -ExpandProperty chave_acesso
                $chaves | Should -Contain $Script:ChaveNFe
            }

            It 'Indexes a processed NF-e document' {
                $getParams = @{
                    Cnpj = $Script:Cnpj
                }

                $results = @(Get-DFeDocumentEntry @getParams)

                $chaves  = $results | Select-Object -ExpandProperty chave_acesso
                $chaves | Should -Contain $Script:ChaveNFeTwo
            }
        }
        #endregion

        #region Evento indexing
        Context 'Evento indexing' {

            BeforeAll {

                $Script:ScanDirEvento = Join-Path -Path $TestDrive -ChildPath 'scan-evento'

                New-Item -Path $Script:ScanDirEvento -ItemType Directory -Force | Out-Null

                $xmlFixtureParams = @{
                    Path    = Join-Path $Script:ScanDirEvento 'evento.xml'
                    Content = $Script:EventoXml
                }

                Write-XmlFixture @xmlFixtureParams

                $scanParams = @{
                    Cnpj    = $Script:Cnpj
                    XmlPath = $Script:ScanDirEvento
                }

                Invoke-DFeXmlScan @scanParams
            }

            It 'Indexes an evento document' {
                $getParams = @{
                    Cnpj     = $Script:Cnpj
                    ChavePai = $Script:ChavePai
                }

                $results = @(Get-DFeEventoEntry @getParams)
                $results | Should -HaveCount 1
            }
        }
        #endregion

        #region Inutilizacao indexing
        Context 'Inutilizacao indexing' {

            BeforeAll {

                $Script:ScanDirInut = Join-Path -Path $TestDrive -ChildPath 'scan-inut'

                New-Item -Path $Script:ScanDirInut -ItemType Directory -Force | Out-Null

                $xmlFixtureParams = @{
                    Path    = Join-Path $Script:ScanDirInut 'inut.xml'
                    Content = $Script:InutXml
                }

                Write-XmlFixture @xmlFixtureParams

                $scanParams = @{
                    Cnpj    = $Script:Cnpj
                    XmlPath = $Script:ScanDirInut
                }

                Invoke-DFeXmlScan @scanParams
            }

            It 'Indexes an inutilizacao document' {
                $getParams = @{
                    Cnpj   = $Script:Cnpj
                    Modelo = [ModeloDFe]::NFe
                }

                $results = @(Get-DFeInutilizacaoEntry @getParams)
                $results | Should -HaveCount 1
            }
        }
        #endregion

        #region Recursive scan
        Context 'Recursive scan' {

            BeforeAll {

                $Script:ScanDirRecurse = Join-Path -Path $TestDrive -ChildPath 'scan-recurse'

                $Script:SubDir = Join-Path -Path $Script:ScanDirRecurse -ChildPath 'sub1\sub2'

                New-Item -Path $Script:SubDir -ItemType Directory -Force | Out-Null

                $Script:ChaveRecurse = '35260112345678000199550010000000031234567890'

                $deepXml = @"
<?xml version="1.0" encoding="utf-8"?>
<NFe xmlns="http://www.portalfiscal.inf.br/nfe">
    <infNFe Id="NFe$($Script:ChaveRecurse)">
        <ide>
            <dhEmi>2026-08-15T10:00:00-03:00</dhEmi>
            <serie>001</serie>
            <nNF>3</nNF>
        </ide>
    </infNFe>
</NFe>
"@
                $xmlFixtureParams = @{
                    Path    = Join-Path $Script:SubDir 'deep.xml'
                    Content = $deepXml
                }

                Write-XmlFixture @xmlFixtureParams

                $scanParams = @{
                    Cnpj    = $Script:Cnpj
                    XmlPath = $Script:ScanDirRecurse
                }

                Invoke-DFeXmlScan @scanParams
            }

            It 'Indexes files found in subdirectories' {
                $getParams = @{
                    Cnpj = $Script:Cnpj
                }

                $results = @(Get-DFeDocumentEntry @getParams)

                $chaves  = $results | Select-Object -ExpandProperty chave_acesso
                $chaves | Should -Contain $Script:ChaveRecurse
            }
        }
        #endregion

        #region Resilience
        Context 'Resilience' {

            BeforeAll {

                $Script:ScanDirResilience = Join-Path -Path $TestDrive -ChildPath 'scan-resilience'

                New-Item -Path $Script:ScanDirResilience -ItemType Directory -Force | Out-Null

                $Script:ChaveValid = '35260112345678000199550010000000041234567890'

                $validXml = @"
<?xml version="1.0" encoding="utf-8"?>
<NFe xmlns="http://www.portalfiscal.inf.br/nfe">
    <infNFe Id="NFe$($Script:ChaveValid)">
        <ide>
            <dhEmi>2026-08-15T10:00:00-03:00</dhEmi>
            <serie>001</serie>
            <nNF>4</nNF>
        </ide>
    </infNFe>
</NFe>
"@

                $xmlFixtureParamsOne = @{
                    Path    = Join-Path $Script:ScanDirResilience 'valid.xml'
                    Content = $validXml
                }

                Write-XmlFixture @xmlFixtureParamsOne

                $xmlFixtureParamsTwo = @{
                    Path    = Join-Path $Script:ScanDirResilience 'unknown.xml'
                    Content = $Script:UnknownXml
                }

                Write-XmlFixture @xmlFixtureParamsTwo

                $xmlFixtureParamsThree = @{
                    Path    = (Join-Path $Script:ScanDirResilience 'malformed.xml')
                    Content = 'this is not xml <<<<'
                }

                Write-XmlFixture @xmlFixtureParamsThree

                $bytes = [System.Text.Encoding]::UTF8.GetBytes('not xml at all')

                [System.IO.File]::WriteAllBytes(
                    (Join-Path $Script:ScanDirResilience 'document.pdf'),
                    $bytes
                )

                $scanParams = @{
                    Cnpj    = $Script:Cnpj
                    XmlPath = $Script:ScanDirResilience
                }

                Invoke-DFeXmlScan @scanParams
            }

            It 'Does not throw when an unrecognized XML is present' {
                $scanParams = @{
                    Cnpj    = $Script:Cnpj
                    XmlPath = $Script:ScanDirResilience
                }

                { Invoke-DFeXmlScan @scanParams } | Should -Not -Throw
            }

            It 'Does not throw when a malformed XML is present' {
                $scanParams = @{
                    Cnpj    = $Script:Cnpj
                    XmlPath = $Script:ScanDirResilience
                }

                { Invoke-DFeXmlScan @scanParams } | Should -Not -Throw
            }

            It 'Still indexes valid documents when invalid ones are present' {
                $getParams = @{
                    Cnpj = $Script:Cnpj
                }

                $results = @(Get-DFeDocumentEntry @getParams)

                $chaves  = $results | Select-Object -ExpandProperty chave_acesso
                $chaves | Should -Contain $Script:ChaveValid
            }

            It 'Ignores non-XML files' {
                $getParams = @{
                    Cnpj = $Script:Cnpj
                }

                $before = @(Get-DFeDocumentEntry @getParams).Count

                $scanParams = @{
                    Cnpj    = $Script:Cnpj
                    XmlPath = $Script:ScanDirResilience
                }

                Invoke-DFeXmlScan @scanParams

                $after = @(Get-DFeDocumentEntry @getParams).Count
                $after | Should -Be $before
            }
        }
        #endregion

        #region Idempotency
        Context 'Idempotency' {

            BeforeAll {

                $Script:ScanDirIdem = Join-Path -Path $TestDrive -ChildPath 'scan-idem'

                New-Item -Path $Script:ScanDirIdem -ItemType Directory -Force | Out-Null

                $Script:ChaveIdem = '35260112345678000199550010000000051234567890'

                $idemXml = @"
<?xml version="1.0" encoding="utf-8"?>
<NFe xmlns="http://www.portalfiscal.inf.br/nfe">
    <infNFe Id="NFe$($Script:ChaveIdem)">
        <ide>
            <dhEmi>2026-08-15T10:00:00-03:00</dhEmi>
            <serie>001</serie>
            <nNF>5</nNF>
        </ide>
    </infNFe>
</NFe>
"@

                $xmlFixtureParams = @{
                    Path    = Join-Path $Script:ScanDirIdem 'idem.xml'
                    Content = $idemXml
                }

                Write-XmlFixture @XmlFixtureParams

                $scanParams = @{
                    Cnpj    = $Script:Cnpj
                    XmlPath = $Script:ScanDirIdem
                }

                Invoke-DFeXmlScan @scanParams
                Invoke-DFeXmlScan @scanParams
            }

            It 'Does not create duplicate entries when scanned twice' {
                $results = @(
                    Get-DFeDocumentEntry -Cnpj $Script:Cnpj |
                        Where-Object {
                            $_.chave_acesso -eq $Script:ChaveIdem
                        }
                )

                $results | Should -HaveCount 1
            }
        }
        #endregion

        #region No output
        Context 'No output' {

            It 'Produces no output' {
                $scanParams = @{
                    Cnpj    = $Script:Cnpj
                    XmlPath = $Script:XmlDir
                }

                $result = Invoke-DFeXmlScan @scanParams
                $result | Should -BeNullOrEmpty
            }
        }
        #endregion
    }
}
