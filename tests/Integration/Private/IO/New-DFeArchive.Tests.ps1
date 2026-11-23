#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Local integration tests for direction-aware, real ZIP archive publishing.

.DESCRIPTION
Uses locally maintained synthetic XML fixtures and real archive compression,
SHA-256 verification, ZIP publishing, and ZIP inspection. The indexed-event
lookup is mocked because SQLite retrieval is tested separately.

Tag LocalFixture allows CI to exclude this suite without excluding other
integration tests.

Coverage includes:
  - Independent incoming and outgoing NFe ZIP contents.
  - CTe content remains separate and direction-free.
  - Events stay with their parent document.
  - Real archive publishing, source integrity and temporary ZIP cleanup.
  - Hash mismatch blocks publication.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseShouldProcessForStateChangingFunctions',
    '',
    Justification = 'ShouldProcess would add no value here.'
)]

param ()

BeforeDiscovery {
    # InModuleScope needs to resolve the PipeDFe module during the Discovery phase,
    # because that's when Context/It are executed to register the test tree. If the
    # module isn't loaded at that point, InModuleScope fails before any BeforeAll or
    # BeforeEach ever runs.
    $moduleRoot = (Get-Item $PSScriptRoot).Parent.Parent.Parent.Parent.FullName

    $modulePath = Join-Path -Path $moduleRoot -ChildPath 'PipeDFe.psd1'

    Import-Module -Name $modulePath -Force -Global -ErrorAction Stop
}

Describe 'New-DFeArchive' -Tag 'Integration' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            $root = (Get-Item $PSScriptRoot).Parent.Parent.Parent.Parent.FullName

            $Script:Fixtures   = Join-Path -Path $root -ChildPath 'tests/Fixtures/ArchiveDirection'
            $Script:XmlPath    = Join-Path -Path $TestDrive -ChildPath 'xml'
            $Script:OutputPath = Join-Path -Path $TestDrive -ChildPath 'output'

            [void][System.IO.Directory]::CreateDirectory($Script:XmlPath)
            [void][System.IO.Directory]::CreateDirectory($Script:OutputPath)

            $requiredFiles = @(
                'nfe-entrada.xml'
                'nfe-saida.xml'
                'cte.xml'
                'evento-entrada.xml'
                'evento-saida.xml'
                'evento-cte.xml'
            )

            foreach ($name in $requiredFiles) {
                $source = Join-Path -Path $Script:Fixtures -ChildPath $name

                if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
                    throw "Required local XML fixture is missing: '$source'."
                }

                Copy-Item -LiteralPath $source -Destination $Script:XmlPath -Force
            }

            $Script:Cnpj       = '12345678000199'
            $Script:EntradaKey = '1' * 44
            $Script:SaidaKey   = '2' * 44
            $Script:CTeKey     = '3' * 44

            $Script:Company = [PSCustomObject]@{
                XmlPath    = $Script:XmlPath
                OutputPath = $Script:OutputPath
            }

            $Script:DateRange = [PSCustomObject]@{
                Start = [System.DateTimeOffset]::new(
                    2026, 10, 1, 0, 0, 0, [TimeSpan]::Zero
                )
                End = [System.DateTimeOffset]::new(
                    2026, 10, 31, 23, 59, 59, [TimeSpan]::Zero
                )
            }

            #region Helpers
            function New-LocalDocument {
                [CmdletBinding()]
                [OutputType([pscustomobject])]
                param (
                    [Parameter()]
                    [string]$Key,

                    [Parameter()]
                    [int]$Model,

                    [Parameter()]
                    [string]$Name,

                    [Parameter()]
                    [string]$Direction
                )

                $path = Join-Path -Path $Script:XmlPath -ChildPath $Name

                [PSCustomObject]@{
                    chave_acesso = $Key
                    modelo       = $Model
                    direcao      = $Direction
                    file_path    = $Name
                    sha256       = Get-FileSha256 -Path $path
                }
            }

            function New-LocalEvent {
                param (
                    [Parameter()]
                    [string]$Key,

                    [Parameter()]
                    [string]$Name
                )

                $path = Join-Path -Path $Script:XmlPath -ChildPath $Name

                [PSCustomObject]@{
                    chave_pai = $Key
                    file_path = $Name
                    sha256    = Get-FileSha256 -Path $path
                }
            }

            $documentParamsOne = @{
                Key       = $Script:EntradaKey
                Model     = 55
                Name      = 'nfe-entrada.xml'
                Direction = 'Entrada'
            }

            $documentParamsTwo = @{
                Key       = $Script:SaidaKey
                Model     = 55
                Name      = 'nfe-saida.xml'
                Direction = 'Saida'
            }

            $documentParamsThree = @{
                Key       = $Script:CTeKey
                Model     = 57
                Name      = 'cte.xml'
                Direction = $null
            }

            $Script:Documents = @(
                New-LocalDocument @documentParamsOne
                New-LocalDocument @documentParamsTwo
                New-LocalDocument @documentParamsThree
            )

            $Script:Events = @(
                New-LocalEvent -Key $Script:EntradaKey -Name 'evento-entrada.xml'
                New-LocalEvent -Key $Script:SaidaKey   -Name 'evento-saida.xml'
                New-LocalEvent -Key $Script:CTeKey     -Name 'evento-cte.xml'
            )

            $Script:Infos = @(
                [PSCustomObject]@{
                    TipoDFe  ='NFe'
                    Direcao  = 'Entrada'
                    FileName ='NFe_Entrada.zip'
                    TempPath = (Join-Path $TestDrive 'NFe_Entrada.tmp.zip')
                    DestPath = (Join-Path $Script:OutputPath 'NFe_Entrada.zip')
                }

                [PSCustomObject]@{
                    TipoDFe  ='NFe'
                    Direcao  ='Saida'
                    FileName ='NFe_Saida.zip'
                    TempPath =(Join-Path $TestDrive 'NFe_Saida.tmp.zip')
                    DestPath =(Join-Path $Script:OutputPath 'NFe_Saida.zip')
                }

                [PSCustomObject]@{
                    TipoDFe  = 'CTe'
                    Direcao  = $null
                    FileName = 'CTe.zip'
                    TempPath =(Join-Path $TestDrive 'CTe.tmp.zip')
                    DestPath =(Join-Path $Script:OutputPath 'CTe.zip')
                }
            )

            Add-Type -AssemblyName 'System.IO.Compression'
            Add-Type -AssemblyName 'System.IO.Compression.FileSystem'

            function Get-LocalZipEntry {
                param (
                    [Parameter()]
                    [string]$Path
                )

                $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)

                try {
                    @($zip.Entries | ForEach-Object { $_.FullName })
                } finally {
                    $zip.Dispose()
                }
            }
        }
        #endregion

        BeforeEach {

            foreach ($info in $Script:Infos) {
                foreach ($path in @($info.TempPath, $info.DestPath)) {
                    if ([System.IO.File]::Exists($path)) {
                        [System.IO.File]::Delete($path)
                    }
                }
            }

            Mock -CommandName Get-DFeEventoEntry -MockWith {
                @($Script:Events | Where-Object { $_.chave_pai -eq $ChavePai })
            }
        }

        It 'Publishes independent Entrada, Saida and CTe ZIPs with their own events' {
            $params = @{
                Cnpj         = $Script:Cnpj
                Company      = $Script:Company
                Entries      = $Script:Documents
                ArchiveInfos = $Script:Infos
                DateRange    = $Script:DateRange
                ErrorAction  = 'Stop'
            }

            $results = @(New-DFeArchive @params)

            $results | Should -HaveCount 3

            foreach ($info in $Script:Infos) {
                Test-Path -LiteralPath $info.DestPath -PathType Leaf | Should -BeTrue
                Test-Path -LiteralPath $info.TempPath -PathType Leaf | Should -BeFalse
            }

            $entrada = @(Get-LocalZipEntry -Path $Script:Infos[0].DestPath)
            $saida   = @(Get-LocalZipEntry -Path $Script:Infos[1].DestPath)
            $cte     = @(Get-LocalZipEntry -Path $Script:Infos[2].DestPath)

            $entrada | Should -HaveCount 2
            $saida   | Should -HaveCount 2
            $cte     | Should -HaveCount 2

            $entrada | Should -Contain "55_NFe/202610/$($Script:EntradaKey)/nfe-entrada.xml"
            $entrada | Should -Contain "55_NFe/202610/$($Script:EntradaKey)/evento-entrada.xml"

            $saida | Should -Contain "55_NFe/202610/$($Script:SaidaKey)/nfe-saida.xml"
            $saida | Should -Contain "55_NFe/202610/$($Script:SaidaKey)/evento-saida.xml"

            $cte | Should -Contain "57_CTe/202610/$($Script:CTeKey)/cte.xml"
            $cte | Should -Contain "57_CTe/202610/$($Script:CTeKey)/evento-cte.xml"
        }

        It 'Rejects a changed source hash before publishing its ZIP' {
            $document = $Script:Documents[0].PSObject.Copy()
            $document.sha256 = '0' * 64

            $params = @{
                Cnpj         = $Script:Cnpj
                Company      = $Script:Company
                Entries      = @($document)
                ArchiveInfos = @($Script:Infos[0])
                DateRange    = $Script:DateRange
                ErrorAction  = 'Stop'
            }

            { New-DFeArchive @params } | Should -Throw

            $testPathParamsOne = @{
                LiteralPath = $Script:Infos[0].DestPath
                PathType    = 'Leaf'
            }

            $testPathParamsTwo = @{
                LiteralPath = $Script:Infos[0].TempPath
                PathType    = 'Leaf'
            }

            Test-Path @testPathParamsOne | Should -BeFalse
            Test-Path @testPathParamsTwo | Should -BeFalse
        }
    }
}
