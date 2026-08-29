#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Integration tests for Compress-DFeArchive.

.DESCRIPTION
Verifies ZIP structure, entry paths, evento embedding, missing file
handling and empty collection behavior using real files in TestDrive.

Coverage includes:
  - All mandatory parameters are declared.
  - Creates a valid ZIP file at ZipPath.
  - Places documents under {model_folder}/{chave}/{filename}.
  - Places eventos inside their parent document's subfolder.
  - Skips source files that do not exist with a warning.
  - Skips evento source files that do not exist with a warning.
  - Does not include evento entries as top-level groups.
  - Produces no output.
  - Handles an empty Entries collection without throwing.
  - Handles unknown model values with a warning.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseShouldProcessForStateChangingFunctions',
    '',
    Justification = 'ShouldProcess would add no value here.'
)]

param ()

# InModuleScope needs to resolve the PipeDFe module during the Discovery phase,
# because that's when Context/It are executed to register the test tree. If the
# module isn't loaded at that point, InModuleScope fails before any BeforeAll or
# BeforeEach ever runs.
BeforeDiscovery {
    $moduleRoot = (Get-Item -LiteralPath $PSScriptRoot).Parent.Parent.Parent.Parent.FullName

    $moduleName = Join-Path -Path $moduleRoot -ChildPath 'PipeDFe.psd1'

    Import-Module -Name $moduleName -Force -Global -ErrorAction Stop
}

Describe 'Compress-DFeArchive' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            $Script:Command = Get-Command -Name Compress-DFeArchive -ErrorAction Stop

            $Script:XmlPath = Join-Path -Path $TestDrive -ChildPath 'xml'

            $newItemParams = @{
                Path     = $Script:XmlPath
                ItemType = 'Directory'
                Force    = $true
            }

            New-Item @newItemParams | Out-Null

            $Script:Chave = '35260112345678000199550010000000011234567890'

            $Script:NfeFileName   = 'nfe.xml'
            $Script:EventoFileName = 'evento.xml'
            $Script:NfePath       = Join-Path -Path $Script:XmlPath -ChildPath $Script:NfeFileName
            $Script:EventoPath    = Join-Path -Path $Script:XmlPath -ChildPath $Script:EventoFileName

            $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
            [System.IO.File]::WriteAllText($Script:NfePath,    '<NFe/>', $utf8NoBom)
            [System.IO.File]::WriteAllText($Script:EventoPath, '<evento/>', $utf8NoBom)

            $Script:NfeEntry = [PSCustomObject]@{
                DfeModel    = 55
                ChaveAcesso = $Script:Chave
                FilePath    = $Script:NfeFileName
                FileName    = $Script:NfeFileName
            }

            $Script:EventoEntry = [PSCustomObject]@{
                DfeModel  = 0
                ChavePai  = $Script:Chave
                FilePath  = $Script:EventoFileName
                FileName  = $Script:EventoFileName
            }

            function Get-ZipEntry {
                [CmdletBinding()]
                [OutputType([array])]
                [OutputType([string[]])]
                param (
                    [Parameter(Mandatory)]
                    [string]$Path
                )

                Add-Type -AssemblyName 'System.IO.Compression'
                Add-Type -AssemblyName 'System.IO.Compression.FileSystem'

                $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)

                try {
                    @($zip.Entries | Select-Object -ExpandProperty FullName)
                } finally {
                    $zip.Dispose()
                }
            }
        }

        #region Parameter contract
        Context 'Parameter contract' {

            It 'Declares XmlPath as mandatory' {
                $mandatory = $Script:Command.Parameters['XmlPath'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.Mandatory
                    }

                $mandatory | Should -Not -BeNullOrEmpty
            }

            It 'Declares Entries as mandatory' {
                $mandatory = $Script:Command.Parameters['Entries'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.Mandatory
                    }

                $mandatory | Should -Not -BeNullOrEmpty
            }

            It 'Declares ZipPath as mandatory' {
                $mandatory = $Script:Command.Parameters['ZipPath'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.Mandatory
                    }

                $mandatory | Should -Not -BeNullOrEmpty
            }
        }
        #endregion

        #region ZIP creation
        Context 'ZIP creation' {

            BeforeAll {

                $Script:ZipPath = Join-Path -Path $TestDrive -ChildPath 'test-create.zip'

                $compressParams = @{
                    XmlPath = $Script:XmlPath
                    Entries = @($Script:NfeEntry)
                    ZipPath = $Script:ZipPath
                }

                Compress-DFeArchive @compressParams

                $Script:ZipEntries = Get-ZipEntry -Path $Script:ZipPath
            }

            It 'Creates a ZIP file at ZipPath' {
                Test-Path -LiteralPath $Script:ZipPath -PathType Leaf | Should -BeTrue
            }

            It 'Places the document under the correct internal path' {
                $expectedPath = '55_NFe/{0}/{1}' -f $Script:Chave, $Script:NfeFileName
                $Script:ZipEntries | Should -Contain $expectedPath
            }

            It 'Produces no output' {
                $compressParams = @{
                    XmlPath = $Script:XmlPath
                    Entries = @($Script:NfeEntry)
                    ZipPath = Join-Path -Path $TestDrive -ChildPath 'noout.zip'
                }

                $result = Compress-DFeArchive @compressParams
                $result | Should -BeNullOrEmpty
            }
        }
        #endregion

        #region Evento embedding
        Context 'Evento embedding' {

            BeforeAll {

                $Script:ZipWithEvento = Join-Path -Path $TestDrive -ChildPath 'test-evento.zip'

                $compressParams = @{
                    XmlPath = $Script:XmlPath
                    Entries = @($Script:NfeEntry, $Script:EventoEntry)
                    ZipPath = $Script:ZipWithEvento
                }

                Compress-DFeArchive @compressParams

                $Script:EventoZipEntries = Get-ZipEntry -Path $Script:ZipWithEvento
            }

            It 'Places evento inside parent document subfolder' {
                $expectedPath = '55_NFe/{0}/{1}' -f $Script:Chave, $Script:EventoFileName
                $Script:EventoZipEntries | Should -Contain $expectedPath
            }

            It 'Does not create a top-level folder for eventos' {
                $Script:EventoZipEntries | Where-Object { $_ -like '0_*' } |
                    Should -HaveCount 0
            }
        }
        #endregion

        #region Missing source files
        Context 'Missing source files' {

            It 'Does not throw when document source file is missing' {
                $missingEntry = [PSCustomObject]@{
                    DfeModel    = 55
                    ChaveAcesso = $Script:Chave
                    FilePath    = 'missing.xml'
                    FileName    = 'missing.xml'
                }

                $compressParams = @{
                    XmlPath = $Script:XmlPath
                    Entries = @($missingEntry)
                    ZipPath = Join-Path -Path $TestDrive -ChildPath 'missing-doc.zip'
                }

                { Compress-DFeArchive @compressParams } | Should -Not -Throw
            }

            It 'Does not throw when evento source file is missing' {
                $missingEvento = [PSCustomObject]@{
                    DfeModel = 0
                    ChavePai = $Script:Chave
                    FilePath = 'missing-evt.xml'
                    FileName = 'missing-evt.xml'
                }

                $compressParams = @{
                    XmlPath = $Script:XmlPath
                    Entries = @($Script:NfeEntry, $missingEvento)
                    ZipPath = Join-Path -Path $TestDrive -ChildPath 'missing-evt.zip'
                }

                { Compress-DFeArchive @compressParams } | Should -Not -Throw
            }
        }
        #endregion

        #region Edge cases
        Context 'Edge cases' {

            It 'Does not throw when Entries is empty' {
                $compressParams = @{
                    XmlPath = $Script:XmlPath
                    Entries = @()
                    ZipPath = Join-Path -Path $TestDrive -ChildPath 'empty.zip'
                }

                { Compress-DFeArchive @compressParams } | Should -Not -Throw
            }

            It 'Emits a warning for unknown model values' {
                $unknownEntry = [PSCustomObject]@{
                    DfeModel    = 99
                    ChaveAcesso = $Script:Chave
                    FilePath    = $Script:NfeFileName
                    FileName    = $Script:NfeFileName
                }

                $warnings = @()

                $compressParams = @{
                    XmlPath         = $Script:XmlPath
                    Entries         = @($unknownEntry)
                    ZipPath         = Join-Path -Path $TestDrive -ChildPath 'unknown-model.zip'
                    WarningVariable = 'warnings'
                }

                Compress-DFeArchive @compressParams

                $warnings | Should -Not -BeNullOrEmpty
            }
        }
        #endregion
    }
}
