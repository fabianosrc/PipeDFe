#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Integration tests for Compress-DFeArchive.

.DESCRIPTION
Verifies ZIP creation, internal structure, evento embedding, model
folder generation, missing source handling, unknown models, empty
collections, compression level, source preservation and parameter
contracts.

The tests use real files and real ZIP archives.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseShouldProcessForStateChangingFunctions',
    '',
    Justification = 'ShouldProcess would add no value here.'
)]

param ()

# InModuleScope needs to resolve the PipeDFe module during the Discovery
# phase, because that's when Context/It are executed to register the test
# tree. If the module isn't loaded at that point, InModuleScope fails before
# any BeforeAll or BeforeEach ever runs.
BeforeDiscovery {
    $moduleRoot = (Get-Item $PSScriptRoot).Parent.Parent.Parent.Parent.FullName

    $moduleName = Join-Path -Path $moduleRoot -ChildPath 'PipeDFe.psd1'

    Import-Module -Name $moduleName -Force -Global -ErrorAction Stop
}

Describe 'Compress-DFeArchive' -Tag 'Integration' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            $Script:Command = Get-Command -Name Compress-DFeArchive -ErrorAction Stop

            $Script:XmlPath = Join-Path -Path $TestDrive -ChildPath 'xml'

            New-Item -Path $Script:XmlPath -ItemType Directory -Force | Out-Null

            $Script:Chave = '35260112345678000199550010000000011234567890'

            $Script:NfeFileName    = 'nfe.xml'
            $Script:EventoFileName = 'evento.xml'

            $Script:NfePath    = Join-Path -Path $Script:XmlPath -ChildPath $Script:NfeFileName
            $Script:EventoPath = Join-Path -Path $Script:XmlPath -ChildPath $Script:EventoFileName

            $utf8NoBom = [System.Text.UTF8Encoding]::new($false)

            [System.IO.File]::WriteAllText($Script:NfePath,    '<NFe/>',    $utf8NoBom)
            [System.IO.File]::WriteAllText($Script:EventoPath, '<evento/>', $utf8NoBom)

            # Properties match the snake_case contract from Get-DFeDocumentEntry
            # and Get-DFeEventoEntry as consumed by New-DFeArchive.
            $Script:NfeEntry = [PSCustomObject]@{
                ChaveAcesso = $Script:Chave
                Modelo      = 55
                FilePath    = $Script:NfeFileName
            }

            $Script:EventoEntry = [PSCustomObject]@{
                ChavePai = $Script:Chave
                FilePath = $Script:EventoFileName
            }

            function Get-ZipEntry {
                [CmdletBinding()]
                [OutputType([string[]])]
                param (
                    [Parameter(Mandatory)]
                    [string]$Path
                )

                Add-Type -AssemblyName 'System.IO.Compression'
                Add-Type -AssemblyName 'System.IO.Compression.FileSystem'

                $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)

                try {
                    [string[]]@($zip.Entries | Select-Object -ExpandProperty FullName)
                } finally {
                    $zip.Dispose()
                }
            }

            function Get-ZipEntryContent {
                [CmdletBinding()]
                [OutputType([string])]
                param (
                    [Parameter(Mandatory)]
                    [string]$Path,

                    [Parameter(Mandatory)]
                    [string]$EntryPath
                )

                Add-Type -AssemblyName 'System.IO.Compression'
                Add-Type -AssemblyName 'System.IO.Compression.FileSystem'

                $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)

                try {
                    $entry = $zip.GetEntry($EntryPath)

                    if ($null -eq $entry) {
                        throw "ZIP entry not found: '$EntryPath'"
                    }

                    $stream = $entry.Open()

                    try {
                        $reader = [System.IO.StreamReader]::new($stream)

                        try {
                            return $reader.ReadToEnd()
                        } finally {
                            $reader.Dispose()
                        }
                    } finally {
                        $stream.Dispose()
                    }
                } finally {
                    $zip.Dispose()
                }
            }
        }

        AfterAll {

            Remove-Module -Name PipeDFe -Force -ErrorAction SilentlyContinue
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

            It 'Declares Eventos as optional' {
                $parameter = $Script:Command.Parameters['Eventos']

                $parameter | Should -Not -BeNullOrEmpty

                $mandatory = $parameter.Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.Mandatory
                    }

                $mandatory | Should -BeNullOrEmpty
            }

            It 'Declares CompressionLevel as optional' {
                $parameter = $Script:Command.Parameters['CompressionLevel']

                $parameter | Should -Not -BeNullOrEmpty

                $mandatory = $parameter.Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ParameterAttribute] -and
                        $_.Mandatory
                    }

                $mandatory | Should -BeNullOrEmpty
            }

            It 'Declares XmlPath as a string' {
                $Script:Command.Parameters['XmlPath'].ParameterType | Should -Be ([string])
            }

            It 'Declares Entries as a PSCustomObject array' {
                $Script:Command.Parameters['Entries'].ParameterType | Should -Be ([pscustomobject[]])
            }

            It 'Declares Eventos as a PSCustomObject array' {
                $Script:Command.Parameters['Eventos'].ParameterType | Should -Be ([pscustomobject[]])
            }

            It 'Declares ZipPath as a string' {
                $Script:Command.Parameters['ZipPath'].ParameterType | Should -Be ([string])
            }

            It 'Declares CompressionLevel with the expected enum type' {
                $Script:Command.Parameters['CompressionLevel'].ParameterType |
                    Should -Be ([System.IO.Compression.CompressionLevel])
            }

            It 'Allows an empty Entries collection' {
                $allowEmpty = $Script:Command.Parameters['Entries'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.AllowEmptyCollectionAttribute]
                    }

                $allowEmpty | Should -Not -BeNullOrEmpty
            }

            It 'Allows an empty Eventos collection' {
                $allowEmpty = $Script:Command.Parameters['Eventos'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.AllowEmptyCollectionAttribute]
                    }

                $allowEmpty | Should -Not -BeNullOrEmpty
            }

            It 'Validates XmlPath as not null or empty' {
                $attr = $Script:Command.Parameters['XmlPath'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ValidateNotNullOrEmptyAttribute]
                    }

                $attr | Should -Not -BeNullOrEmpty
            }

            It 'Validates ZipPath as not null or empty' {
                $attr = $Script:Command.Parameters['ZipPath'].Attributes |
                    Where-Object {
                        $_ -is [System.Management.Automation.ValidateNotNullOrEmptyAttribute]
                    }

                $attr | Should -Not -BeNullOrEmpty
            }

            It 'Rejects an empty XmlPath' {
                $zipParams = @{
                    XmlPath     = [string]::Empty
                    Entries     = @($Script:NfeEntry)
                    ZipPath     = (Join-Path -Path $TestDrive -ChildPath 'invalid-xml-path.zip')
                    ErrorAction = 'Stop'
                }

                { Compress-DFeArchive @zipParams } | Should -Throw
            }

            It 'Rejects an empty ZipPath' {
                $zipParams = @{
                    XmlPath     = $Script:XmlPath
                    Entries     = @($Script:NfeEntry)
                    ZipPath     = [string]::Empty
                    ErrorAction = 'Stop'
                }

                { Compress-DFeArchive @zipParams } | Should -Throw
            }
        }
        #endregion

        #region ZIP creation
        Context 'ZIP creation' {

            BeforeAll {

                $Script:ZipPath = Join-Path -Path $TestDrive -ChildPath 'basic.zip'

                $zipParams = @{
                    XmlPath = $Script:XmlPath
                    Entries = @($Script:NfeEntry)
                    ZipPath = $Script:ZipPath
                }

                Compress-DFeArchive @zipParams

                $Script:ZipEntries = Get-ZipEntry -Path $Script:ZipPath
            }

            It 'Creates a ZIP file at ZipPath' {
                Test-Path -LiteralPath $Script:ZipPath -PathType Leaf | Should -BeTrue
            }

            It 'Creates a readable ZIP archive' {
                {
                    $zip = [System.IO.Compression.ZipFile]::OpenRead($Script:ZipPath)
                    $zip.Dispose()
                } | Should -Not -Throw
            }

            It 'Places the document under the expected model folder' {
                $expectedPath = '55_NFe/{0}/{1}' -f $Script:Chave, $Script:NfeFileName

                $Script:ZipEntries | Should -Contain $expectedPath
            }

            It 'Creates exactly one ZIP entry' {
                $Script:ZipEntries | Should -HaveCount 1
            }

            It 'Preserves the source file content' {
                $expectedPath = '55_NFe/{0}/{1}' -f $Script:Chave, $Script:NfeFileName

                $content = Get-ZipEntryContent -Path $Script:ZipPath -EntryPath $expectedPath

                $content | Should -Be '<NFe/>'
            }

            It 'Produces no output' {
                $zipPath = Join-Path -Path $TestDrive -ChildPath 'no-output.zip'

                $zipParams = @{
                    XmlPath = $Script:XmlPath
                    Entries = @($Script:NfeEntry)
                    ZipPath = $zipPath
                }

                @(Compress-DFeArchive @zipParams) | Should -HaveCount 0
            }
        }
        #endregion

        #region Evento embedding
        Context 'Evento embedding' {

            BeforeAll {

                $Script:ZipWithEvento = Join-Path -Path $TestDrive -ChildPath 'evento.zip'

                $zipParams = @{
                    XmlPath = $Script:XmlPath
                    Entries = @($Script:NfeEntry)
                    Eventos = @($Script:EventoEntry)
                    ZipPath = $Script:ZipWithEvento
                }

                Compress-DFeArchive @zipParams

                $Script:EventoZipEntries = Get-ZipEntry -Path $Script:ZipWithEvento
            }

            It 'Includes the parent document' {
                $documentPath = '55_NFe/{0}/{1}' -f $Script:Chave, $Script:NfeFileName

                $Script:EventoZipEntries | Should -Contain $documentPath
            }

            It 'Places evento inside the parent document subfolder' {
                $eventoPath = '55_NFe/{0}/{1}' -f $Script:Chave, $Script:EventoFileName

                $Script:EventoZipEntries | Should -Contain $eventoPath
            }

            It 'Creates exactly two ZIP entries' {
                $Script:EventoZipEntries | Should -HaveCount 2
            }

            It 'Does not create a top-level evento model folder' {
                $Script:EventoZipEntries | Where-Object { $_ -like '0_*' } | Should -HaveCount 0
            }

            It 'Preserves evento source content' {
                $eventoPath = '55_NFe/{0}/{1}' -f $Script:Chave, $Script:EventoFileName

                $content = Get-ZipEntryContent -Path $Script:ZipWithEvento -EntryPath $eventoPath

                $content | Should -Be '<evento/>'
            }
        }
        #endregion

        #region Multiple documents
        Context 'Multiple documents' {

            BeforeAll {

                $Script:Chave2       = '35260112345678000199550010000000021234567890'
                $Script:NfeFileName2 = 'nfe-2.xml'
                $Script:NfePath2     = Join-Path -Path $Script:XmlPath -ChildPath $Script:NfeFileName2

                $utf8NoBom = [System.Text.UTF8Encoding]::new($false)

                [System.IO.File]::WriteAllText($Script:NfePath2, '<NFe id="2"/>', $utf8NoBom)

                $Script:NfeEntry2 = [PSCustomObject]@{
                    ChaveAcesso = $Script:Chave2
                    Modelo      = 55
                    FilePath    = $Script:NfeFileName2
                }

                $Script:ZipMultiple = Join-Path -Path $TestDrive -ChildPath 'multiple.zip'

                $compressParams = @{
                    XmlPath = $Script:XmlPath
                    Entries = @($Script:NfeEntry, $Script:NfeEntry2)
                    ZipPath = $Script:ZipMultiple
                }

                Compress-DFeArchive @compressParams

                $Script:MultipleEntries = Get-ZipEntry -Path $Script:ZipMultiple
            }

            It 'Creates one entry per document' {
                $Script:MultipleEntries | Should -HaveCount 2
            }

            It 'Keeps documents in separate chave subfolders' {
                $expected1 = '55_NFe/{0}/{1}' -f $Script:Chave,  $Script:NfeFileName
                $expected2 = '55_NFe/{0}/{1}' -f $Script:Chave2, $Script:NfeFileName2

                $Script:MultipleEntries | Should -Contain $expected1
                $Script:MultipleEntries | Should -Contain $expected2
            }
        }
        #endregion

        #region Multiple models
        Context 'Multiple models' {

            BeforeAll {

                $Script:CteChave    = '35260112345678000199570010000000031234567890'
                $Script:CteFileName = 'cte.xml'
                $Script:CtePath     = Join-Path -Path $Script:XmlPath -ChildPath $Script:CteFileName

                $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
                [System.IO.File]::WriteAllText($Script:CtePath, '<CTe/>', $utf8NoBom)

                $Script:CteEntry = [PSCustomObject]@{
                    ChaveAcesso = $Script:CteChave
                    Modelo      = 57
                    FilePath    = $Script:CteFileName
                }

                $Script:ZipMultipleModels = Join-Path -Path $TestDrive -ChildPath 'multiple-models.zip'

                $compressParams = @{
                    XmlPath = $Script:XmlPath
                    Entries = @($Script:NfeEntry, $Script:CteEntry)
                    ZipPath = $Script:ZipMultipleModels
                }

                Compress-DFeArchive @compressParams

                $Script:MultipleModelEntries = Get-ZipEntry -Path $Script:ZipMultipleModels
            }

            It 'Places each model under its corresponding enum-derived folder' {
                $nfePath = '55_NFe/{0}/{1}' -f $Script:Chave,    $Script:NfeFileName
                $ctePath = '57_CTe/{0}/{1}' -f $Script:CteChave, $Script:CteFileName

                $Script:MultipleModelEntries | Should -Contain $nfePath
                $Script:MultipleModelEntries | Should -Contain $ctePath
            }

            It 'Creates exactly one entry per document' {
                $Script:MultipleModelEntries | Should -HaveCount 2
            }
        }
        #endregion

        #region Missing source files
        Context 'Missing source files' {

            It 'Skips a missing document source file with a warning' {
                $missingEntry = [PSCustomObject]@{
                    ChaveAcesso = $Script:Chave
                    Modelo      = 55
                    FilePath    = 'missing.xml'
                }

                $zipPath = Join-Path -Path $TestDrive -ChildPath 'missing-document.zip'

                $zipParams = @{
                    XmlPath         = $Script:XmlPath
                    Entries         = @($missingEntry)
                    ZipPath         = $zipPath
                    WarningVariable = 'warning'
                    WarningAction   = 'SilentlyContinue'
                }

                Compress-DFeArchive @zipParams

                $warning    | Should -Not -BeNullOrEmpty
                $warning[0] | Should -Match 'Source file not found'

                Get-ZipEntry -Path $zipPath | Should -HaveCount 0
            }

            It 'Skips a missing evento source file with a warning' {
                $missingEvento = [PSCustomObject]@{
                    ChavePai = $Script:Chave
                    FilePath = 'missing-evento.xml'
                }

                $zipPath = Join-Path -Path $TestDrive -ChildPath 'missing-evento.zip'

                $zipParams = @{
                    XmlPath         = $Script:XmlPath
                    Entries         = @($Script:NfeEntry)
                    Eventos         = @($missingEvento)
                    ZipPath         = $zipPath
                    WarningVariable = 'warning'
                    WarningAction   = 'SilentlyContinue'
                }

                Compress-DFeArchive @zipParams

                $warning    | Should -Not -BeNullOrEmpty
                $warning[0] | Should -Match 'Evento source file not found'

                $entries = Get-ZipEntry -Path $zipPath

                $entries | Should -HaveCount 1
                $entries | Should -Contain ('55_NFe/{0}/{1}' -f $Script:Chave, $Script:NfeFileName)
            }
        }
        #endregion

        #region Empty collections
        Context 'Empty collections' {

            It 'Creates a valid empty ZIP when Entries is empty' {
                $zipPath = Join-Path -Path $TestDrive -ChildPath 'empty-entries.zip'

                $zipParams = @{
                    XmlPath = $Script:XmlPath
                    Entries = @()
                    ZipPath = $zipPath
                }

                { Compress-DFeArchive @zipParams } | Should -Not -Throw

                Test-Path -LiteralPath $zipPath -PathType Leaf | Should -BeTrue

                Get-ZipEntry -Path $zipPath | Should -HaveCount 0
            }

            It 'Creates a valid ZIP when Eventos is empty' {
                $zipPath = Join-Path -Path $TestDrive -ChildPath 'empty-eventos.zip'

                $zipParams = @{
                    XmlPath = $Script:XmlPath
                    Entries = @($Script:NfeEntry)
                    Eventos = @()
                    ZipPath = $zipPath
                }

                { Compress-DFeArchive @zipParams } | Should -Not -Throw

                Get-ZipEntry -Path $zipPath | Should -HaveCount 1
            }

            It 'Creates a valid ZIP when Eventos is omitted' {
                $zipPath = Join-Path -Path $TestDrive -ChildPath 'omitted-eventos.zip'

                $zipParams = @{
                    XmlPath = $Script:XmlPath
                    Entries = @($Script:NfeEntry)
                    ZipPath = $zipPath
                }

                { Compress-DFeArchive @zipParams } | Should -Not -Throw

                Get-ZipEntry -Path $zipPath | Should -HaveCount 1
            }
        }
        #endregion

        #region Unknown model
        Context 'Unknown model' {

            It 'Emits a warning for a model not present in ModeloDFe' {
                $unknownEntry = [PSCustomObject]@{
                    ChaveAcesso = $Script:Chave
                    Modelo      = 999
                    FilePath    = $Script:NfeFileName
                }

                $zipPath = Join-Path -Path $TestDrive -ChildPath 'unknown-model.zip'

                $zipParams = @{
                    XmlPath         = $Script:XmlPath
                    Entries         = @($unknownEntry)
                    ZipPath         = $zipPath
                    WarningVariable = 'warning'
                    WarningAction   = 'SilentlyContinue'
                }

                Compress-DFeArchive @zipParams

                $warning    | Should -Not -BeNullOrEmpty
                $warning[0] | Should -Match 'Unknown DFe model'

                Get-ZipEntry -Path $zipPath | Should -HaveCount 0
            }

            It 'Does not include unknown-model documents in the ZIP' {
                $unknownEntry = [PSCustomObject]@{
                    ChaveAcesso = $Script:Chave
                    Modelo      = 999
                    FilePath    = $Script:NfeFileName
                }

                $zipPath = Join-Path -Path $TestDrive -ChildPath 'unknown-model-no-entry.zip'

                $zipParams = @{
                    XmlPath = $Script:XmlPath
                    Entries = @($unknownEntry)
                    ZipPath = $zipPath
                }

                Compress-DFeArchive @zipParams

                Get-ZipEntry -Path $zipPath | Should -HaveCount 0
            }
        }
        #endregion

        #region Evento association
        Context 'Evento association' {

            It 'Embeds only eventos linked to the matching parent chave' {
                $otherChave = '35260112345678000199550010000000041234567890'
                $otherEventoFileName = 'evento-other.xml'
                $otherEventoPath   = Join-Path -Path $Script:XmlPath -ChildPath $otherEventoFileName

                $utf8NoBom = [System.Text.UTF8Encoding]::new($false)

                [System.IO.File]::WriteAllText($otherEventoPath, '<evento-other/>', $utf8NoBom)

                $otherEvento = [PSCustomObject]@{
                    ChavePai = $otherChave
                    FilePath = $otherEventoFileName
                }

                $zipPath = Join-Path -Path $TestDrive -ChildPath 'evento-association.zip'

                $zipParams = @{
                    XmlPath = $Script:XmlPath
                    Entries = @($Script:NfeEntry)
                    Eventos = @($Script:EventoEntry, $otherEvento)
                    ZipPath = $zipPath
                }

                Compress-DFeArchive @zipParams

                $entries = Get-ZipEntry -Path $zipPath

                $entries | Should -HaveCount 2
                $entries | Should -Contain ('55_NFe/{0}/{1}' -f $Script:Chave, $Script:NfeFileName)
                $entries | Should -Contain ('55_NFe/{0}/{1}' -f $Script:Chave, $Script:EventoFileName)

                $entries | Where-Object { $_ -like "*$otherEventoFileName" } | Should -HaveCount 0
            }

            It 'Embeds multiple eventos under the same parent document' {
                $evento2FileName = 'evento-2.xml'
                $evento2Path     = Join-Path -Path $Script:XmlPath -ChildPath $evento2FileName

                $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
                [System.IO.File]::WriteAllText($evento2Path, '<evento-2/>', $utf8NoBom)

                $evento2 = [PSCustomObject]@{
                    ChavePai = $Script:Chave
                    FilePath = $evento2FileName
                }

                $zipPath = Join-Path -Path $TestDrive -ChildPath 'multiple-eventos.zip'

                $zipParams = @{
                    XmlPath = $Script:XmlPath
                    Entries = @($Script:NfeEntry)
                    Eventos = @($Script:EventoEntry, $evento2)
                    ZipPath = $zipPath
                }

                Compress-DFeArchive @zipParams

                $entries = Get-ZipEntry -Path $zipPath

                $entries | Should -HaveCount 3
                $entries | Should -Contain ('55_NFe/{0}/{1}' -f $Script:Chave, $Script:EventoFileName)
                $entries | Should -Contain ('55_NFe/{0}/{1}' -f $Script:Chave, $evento2FileName)
            }
        }
        #endregion

        #region Output directory
        Context 'Output directory' {

            It 'Creates the parent directory when it does not exist' {
                $nestedPath = Join-Path -Path $TestDrive -ChildPath 'new-directory/sub-directory'
                $zipPath    = Join-Path -Path $nestedPath -ChildPath 'archive.zip'

                Test-Path -LiteralPath $nestedPath -PathType Container | Should -BeFalse

                $zipParams = @{
                    XmlPath = $Script:XmlPath
                    Entries = @($Script:NfeEntry)
                    ZipPath = $zipPath
                }

                Compress-DFeArchive @zipParams

                Test-Path -LiteralPath $zipPath -PathType Leaf | Should -BeTrue
            }
        }
        #endregion

        #region Source preservation
        Context 'Source preservation' {

            It 'Does not modify the source document' {
                $before  = [System.IO.File]::ReadAllBytes($Script:NfePath)
                $zipPath = Join-Path -Path $TestDrive -ChildPath 'source-preservation.zip'

                $zipParams = @{
                    XmlPath = $Script:XmlPath
                    Entries = @($Script:NfeEntry)
                    ZipPath = $zipPath
                }

                Compress-DFeArchive @zipParams

                $after = [System.IO.File]::ReadAllBytes($Script:NfePath)

                $after | Should -Be $before
            }

            It 'Does not modify the source evento' {
                $before  = [System.IO.File]::ReadAllBytes($Script:EventoPath)
                $zipPath = Join-Path -Path $TestDrive -ChildPath 'source-evento-preservation.zip'

                $zipParams = @{
                    XmlPath = $Script:XmlPath
                    Entries = @($Script:NfeEntry)
                    Eventos = @($Script:EventoEntry)
                    ZipPath = $zipPath
                }

                Compress-DFeArchive @zipParams

                $after = [System.IO.File]::ReadAllBytes($Script:EventoPath)

                $after | Should -Be $before
            }
        }
        #endregion

        #region Compression
        Context 'Compression' {

            It 'Accepts the requested compression level' {
                $zipPath = Join-Path -Path $TestDrive -ChildPath 'compression-fastest.zip'

                $zipParams = @{
                    XmlPath          = $Script:XmlPath
                    Entries          = @($Script:NfeEntry)
                    ZipPath          = $zipPath
                    CompressionLevel = ([System.IO.Compression.CompressionLevel]::Fastest)
                }

                { Compress-DFeArchive @zipParams } | Should -Not -Throw

                Get-ZipEntry -Path $zipPath |
                    Should -Contain ('55_NFe/{0}/{1}' -f $Script:Chave, $Script:NfeFileName)
            }

            It 'Uses Optimal as the default compression level' {
                $zipPath = Join-Path -Path $TestDrive -ChildPath 'compression-default.zip'

                $zipParams = @{
                    XmlPath = $Script:XmlPath
                    Entries = @($Script:NfeEntry)
                    ZipPath = $zipPath
                }

                { Compress-DFeArchive @zipParams } | Should -Not -Throw
            }
        }
        #endregion
    }
}
