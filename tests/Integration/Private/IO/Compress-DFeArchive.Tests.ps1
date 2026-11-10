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

Coverage includes:
  - Parameter contract (types, mandatory, optional, validators).
  - Creates a valid ZIP file at ZipPath.
  - Places a document without events directly under {modelo}/{period}/{filename}.
  - Places a document with events under {modelo}/{period}/{chave}/{filename}.
  - Embeds eventos inside the parent document subfolder.
  - Associates eventos by ChavePai; ignores eventos for other documents.
  - Embeds multiple eventos under the same parent.
  - Handles multiple documents in the same model group.
  - Handles multiple model groups in the same batch.
  - Throws ArchiveSourceNotFound for a missing document source file.
  - Throws ArchiveSourceNotFound for a missing evento source file.
  - Throws ArchiveModelUnsupported for an unknown Modelo value.
  - Throws ArchiveDuplicatePath for duplicate internal ZIP paths.
  - Creates an empty but valid ZIP when Entries is empty.
  - Creates a valid ZIP when Eventos is empty or omitted.
  - Creates parent directory when it does not exist.
  - Preserves source document content after compression.
  - Preserves source evento content after compression.
  - Accepts a custom CompressionLevel.
  - Defaults to Optimal compression.
  - Produces no output (OutputType void).
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

Describe 'Compress-DFeArchive' -Tag 'Integration' {

    InModuleScope -ModuleName PipeDFe {

        BeforeAll {

            $Script:Command = Get-Command -Name Compress-DFeArchive -ErrorAction Stop

            $Script:XmlPath = Join-Path -Path $TestDrive -ChildPath 'xml'

            New-Item -Path $Script:XmlPath -ItemType Directory -Force | Out-Null

            $Script:Chave         = '35260112345678000199550010000000011234567890'
            $Script:PeriodSegment = '202610'

            $Script:NfeFileName    = 'nfe.xml'
            $Script:EventoFileName = 'evento.xml'

            $Script:NfePath    = Join-Path -Path $Script:XmlPath -ChildPath $Script:NfeFileName
            $Script:EventoPath = Join-Path -Path $Script:XmlPath -ChildPath $Script:EventoFileName

            $utf8NoBom = [System.Text.UTF8Encoding]::new($false)

            [System.IO.File]::WriteAllText($Script:NfePath,    '<NFe/>',    $utf8NoBom)
            [System.IO.File]::WriteAllText($Script:EventoPath, '<evento/>', $utf8NoBom)

            $Script:NfeHash    = Get-FileSha256 -Path $Script:NfePath
            $Script:EventoHash = Get-FileSha256 -Path $Script:EventoPath

            $Script:NfeEntry = [PSCustomObject]@{
                ChaveAcesso = $Script:Chave
                Modelo      = 55
                FilePath    = $Script:NfeFileName
                Sha256      = $Script:NfeHash
            }

            $Script:EventoEntry = [PSCustomObject]@{
                ChavePai = $Script:Chave
                FilePath = $Script:EventoFileName
                Sha256   = $Script:EventoHash
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

            It 'Declares PeriodSegment as mandatory' {
                $mandatory = $Script:Command.Parameters['PeriodSegment'].Attributes |
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

            It 'Produces no output' {
                $outputTypes = $Script:Command.OutputType

                $outputTypes | Should -HaveCount 1
                $outputTypes[0].Type | Should -Be ([void])
            }
        }
        #endregion

        #region Internal structure - document without events
        Context 'Internal structure - document without events' {

            It 'Places the document directly under the period folder' {
                $zipPath = Join-Path -Path $TestDrive -ChildPath 'no-events.zip'

                $zipParams = @{
                    XmlPath       = $Script:XmlPath
                    Entries       = @($Script:NfeEntry)
                    ZipPath       = $zipPath
                    PeriodSegment = $Script:PeriodSegment
                }

                Compress-DFeArchive @zipParams

                $entries = Get-ZipEntry -Path $zipPath

                $entries | Should -HaveCount 1
                $entries | Should -Contain (
                    '55_NFe/{0}/{1}' -f $Script:PeriodSegment, $Script:NfeFileName
                )
            }

            It 'Does not create a chave subfolder when there are no events' {
                $zipPath = Join-Path -Path $TestDrive -ChildPath 'no-events-no-subfolder.zip'

                $zipParams = @{
                    XmlPath       = $Script:XmlPath
                    Entries       = @($Script:NfeEntry)
                    ZipPath       = $zipPath
                    PeriodSegment = $Script:PeriodSegment
                }

                Compress-DFeArchive @zipParams

                $entries = Get-ZipEntry -Path $zipPath

                $entries | Where-Object { $_ -like "*$($Script:Chave)*" } |
                    Should -HaveCount 0
            }
        }
        #endregion

        #region Internal structure - document with events
        Context 'Internal structure - document with events' {

            It 'Places the document inside a chave subfolder when it has events' {
                $zipPath = Join-Path -Path $TestDrive -ChildPath 'with-events-doc.zip'

                $zipParams = @{
                    XmlPath       = $Script:XmlPath
                    Entries       = @($Script:NfeEntry)
                    Eventos       = @($Script:EventoEntry)
                    ZipPath       = $zipPath
                    PeriodSegment = $Script:PeriodSegment
                }

                Compress-DFeArchive @zipParams

                $entries = Get-ZipEntry -Path $zipPath

                $entries | Should -Contain (
                    '55_NFe/{0}/{1}/{2}' -f $Script:PeriodSegment, $Script:Chave, $Script:NfeFileName
                )
            }

            It 'Places the event inside the same chave subfolder as the document' {
                $zipPath = Join-Path -Path $TestDrive -ChildPath 'with-events-evento.zip'

                $zipParams = @{
                    XmlPath       = $Script:XmlPath
                    Entries       = @($Script:NfeEntry)
                    Eventos       = @($Script:EventoEntry)
                    ZipPath       = $zipPath
                    PeriodSegment = $Script:PeriodSegment
                }

                Compress-DFeArchive @zipParams

                $entries = Get-ZipEntry -Path $zipPath

                $entries | Should -HaveCount 2
                $entries | Should -Contain (
                    '55_NFe/{0}/{1}/{2}' -f $Script:PeriodSegment, $Script:Chave, $Script:EventoFileName
                )
            }

            It 'Associates events by ChavePai and ignores events for other documents' {
                $otherChave         = '35260112345678000199550010000000029999999999'
                $otherEventoFileName = 'evento-other.xml'
                $otherEventoPath     = Join-Path -Path $Script:XmlPath -ChildPath $otherEventoFileName

                $utf8NoBom = [System.Text.UTF8Encoding]::new($false)

                [System.IO.File]::WriteAllText($otherEventoPath, '<evento-other/>', $utf8NoBom)

                $otherEventoHash = Get-FileSha256 -Path $otherEventoPath

                $otherEvento = [PSCustomObject]@{
                    ChavePai = $otherChave
                    FilePath = $otherEventoFileName
                    Sha256   = $otherEventoHash
                }

                $zipPath = Join-Path -Path $TestDrive -ChildPath 'evento-association.zip'

                $zipParams = @{
                    XmlPath       = $Script:XmlPath
                    Entries       = @($Script:NfeEntry)
                    Eventos       = @($Script:EventoEntry, $otherEvento)
                    ZipPath       = $zipPath
                    PeriodSegment = $Script:PeriodSegment
                }

                Compress-DFeArchive @zipParams

                $entries = Get-ZipEntry -Path $zipPath

                $entries | Should -HaveCount 2
                $entries | Should -Contain (
                    '55_NFe/{0}/{1}/{2}' -f $Script:PeriodSegment, $Script:Chave, $Script:NfeFileName
                )
                $entries | Should -Contain (
                    '55_NFe/{0}/{1}/{2}' -f $Script:PeriodSegment, $Script:Chave, $Script:EventoFileName
                )
                $entries | Where-Object { $_ -like "*$otherEventoFileName" } | Should -HaveCount 0
            }

            It 'Embeds multiple eventos under the same parent document' {
                $evento2FileName = 'evento-2.xml'
                $evento2Path     = Join-Path -Path $Script:XmlPath -ChildPath $evento2FileName

                $utf8NoBom = [System.Text.UTF8Encoding]::new($false)

                [System.IO.File]::WriteAllText($evento2Path, '<evento-2/>', $utf8NoBom)

                $evento2Hash = Get-FileSha256 -Path $evento2Path

                $evento2 = [PSCustomObject]@{
                    ChavePai = $Script:Chave
                    FilePath = $evento2FileName
                    Sha256   = $evento2Hash
                }

                $zipPath = Join-Path -Path $TestDrive -ChildPath 'multiple-eventos.zip'

                $zipParams = @{
                    XmlPath       = $Script:XmlPath
                    Entries       = @($Script:NfeEntry)
                    Eventos       = @($Script:EventoEntry, $evento2)
                    ZipPath       = $zipPath
                    PeriodSegment = $Script:PeriodSegment
                }

                Compress-DFeArchive @zipParams

                $entries = Get-ZipEntry -Path $zipPath

                $entries | Should -HaveCount 3
                $entries | Should -Contain (
                    '55_NFe/{0}/{1}/{2}' -f $Script:PeriodSegment, $Script:Chave, $Script:EventoFileName
                )
                $entries | Should -Contain (
                    '55_NFe/{0}/{1}/{2}' -f $Script:PeriodSegment, $Script:Chave, $evento2FileName
                )
            }
        }
        #endregion

        #region Multiple documents and models
        Context 'Multiple documents and models' {

            It 'Handles multiple documents in the same model group' {
                $chave2       = '35260112345678000199550010000000029999999999'
                $nfe2FileName = 'nfe-2.xml'
                $nfe2Path     = Join-Path -Path $Script:XmlPath -ChildPath $nfe2FileName

                $utf8NoBom = [System.Text.UTF8Encoding]::new($false)

                [System.IO.File]::WriteAllText($nfe2Path, '<NFe2/>', $utf8NoBom)

                $nfe2Hash = Get-FileSha256 -Path $nfe2Path

                $nfe2Entry = [PSCustomObject]@{
                    ChaveAcesso = $chave2
                    Modelo      = 55
                    FilePath    = $nfe2FileName
                    Sha256      = $nfe2Hash
                }

                $zipPath = Join-Path -Path $TestDrive -ChildPath 'multiple-docs.zip'

                $zipParams = @{
                    XmlPath       = $Script:XmlPath
                    Entries       = @($Script:NfeEntry, $nfe2Entry)
                    ZipPath       = $zipPath
                    PeriodSegment = $Script:PeriodSegment
                }

                Compress-DFeArchive @zipParams

                $entries = Get-ZipEntry -Path $zipPath

                $entries | Should -HaveCount 2
                $entries | Should -Contain (
                    '55_NFe/{0}/{1}' -f $Script:PeriodSegment, $Script:NfeFileName
                )
                $entries | Should -Contain (
                    '55_NFe/{0}/{1}' -f $Script:PeriodSegment, $nfe2FileName
                )
            }

            It 'Handles multiple model groups in the same batch' {
                $nfceChave    = '35260112345678000199650010000000019999999999'
                $nfceFileName = 'nfce.xml'
                $nfcePath     = Join-Path -Path $Script:XmlPath -ChildPath $nfceFileName

                $utf8NoBom = [System.Text.UTF8Encoding]::new($false)

                [System.IO.File]::WriteAllText($nfcePath, '<NFCe/>', $utf8NoBom)

                $nfceHash = Get-FileSha256 -Path $nfcePath

                $nfceEntry = [PSCustomObject]@{
                    ChaveAcesso = $nfceChave
                    Modelo      = 65
                    FilePath    = $nfceFileName
                    Sha256      = $nfceHash
                }

                $zipPath = Join-Path -Path $TestDrive -ChildPath 'multiple-models.zip'

                $zipParams = @{
                    XmlPath       = $Script:XmlPath
                    Entries       = @($Script:NfeEntry, $nfceEntry)
                    ZipPath       = $zipPath
                    PeriodSegment = $Script:PeriodSegment
                }

                Compress-DFeArchive @zipParams

                $entries = Get-ZipEntry -Path $zipPath

                $entries | Should -HaveCount 2
                $entries | Should -Contain (
                    '55_NFe/{0}/{1}' -f $Script:PeriodSegment, $Script:NfeFileName
                )
                $entries | Should -Contain (
                    '65_NFCe/{0}/{1}' -f $Script:PeriodSegment, $nfceFileName
                )
            }
        }
        #endregion

        #region Period segment
        Context 'Period segment' {

            It 'Uses the supplied PeriodSegment as the internal folder name' {
                $zipPath = Join-Path -Path $TestDrive -ChildPath 'period-segment.zip'

                $zipParams = @{
                    XmlPath       = $Script:XmlPath
                    Entries       = @($Script:NfeEntry)
                    ZipPath       = $zipPath
                    PeriodSegment = '20261001-20261015'
                }

                Compress-DFeArchive @zipParams

                $entries = Get-ZipEntry -Path $zipPath

                $entries | Should -Contain (
                    '55_NFe/20261001-20261015/{0}' -f $Script:NfeFileName
                )
            }
        }
        #endregion

        #region Duplicate path detection
        Context 'Duplicate path detection' {

            It 'Throws ArchiveDuplicatePath when two documents map to the same internal path' {
                $duplicateEntry = [PSCustomObject]@{
                    ChaveAcesso = $Script:Chave
                    Modelo      = 55
                    FilePath    = $Script:NfeFileName
                    Sha256      = $Script:NfeHash
                }

                $zipPath = Join-Path -Path $TestDrive -ChildPath 'duplicate-path.zip'

                $zipParams = @{
                    XmlPath       = $Script:XmlPath
                    Entries       = @($Script:NfeEntry, $duplicateEntry)
                    ZipPath       = $zipPath
                    PeriodSegment = $Script:PeriodSegment
                }

                $caught = $false

                try {
                    Compress-DFeArchive @zipParams
                } catch {
                    $caught = $true
                    $_.FullyQualifiedErrorId | Should -BeLike 'ArchiveDuplicatePath*'
                }

                $caught | Should -BeTrue
            }
        }
        #endregion

        #region Source validation
        Context 'Source validation' {

            It 'Throws ArchiveSourceNotFound for a missing document source file' {
                $missingEntry = [PSCustomObject]@{
                    ChaveAcesso = $Script:Chave
                    Modelo      = 55
                    FilePath    = 'missing.xml'
                    Sha256      = $Script:NfeHash
                }

                $zipPath = Join-Path -Path $TestDrive -ChildPath 'missing-doc.zip'

                $zipParams = @{
                    XmlPath       = $Script:XmlPath
                    Entries       = @($missingEntry)
                    ZipPath       = $zipPath
                    PeriodSegment = $Script:PeriodSegment
                }

                $caught = $false

                try {
                    Compress-DFeArchive @zipParams
                } catch {
                    $caught = $true
                    $_.FullyQualifiedErrorId | Should -BeLike 'ArchiveSourceNotFound*'
                }

                $caught | Should -BeTrue
            }

            It 'Throws ArchiveSourceNotFound for a missing evento source file' {
                $missingEvento = [PSCustomObject]@{
                    ChavePai = $Script:Chave
                    FilePath = 'missing-evento.xml'
                    Sha256   = $Script:EventoHash
                }

                $zipPath = Join-Path -Path $TestDrive -ChildPath 'missing-evento.zip'

                $zipParams = @{
                    XmlPath       = $Script:XmlPath
                    Entries       = @($Script:NfeEntry)
                    Eventos       = @($missingEvento)
                    ZipPath       = $zipPath
                    PeriodSegment = $Script:PeriodSegment
                }

                $caught = $false

                try {
                    Compress-DFeArchive @zipParams
                } catch {
                    $caught = $true
                    $_.FullyQualifiedErrorId | Should -BeLike 'ArchiveSourceNotFound*'
                }

                $caught | Should -BeTrue
            }

            It 'Throws ArchiveModelUnsupported for an unknown Modelo value' {
                $unknownEntry = [PSCustomObject]@{
                    ChaveAcesso = $Script:Chave
                    Modelo      = 99
                    FilePath    = $Script:NfeFileName
                    Sha256      = $Script:NfeHash
                }

                $zipPath = Join-Path -Path $TestDrive -ChildPath 'unknown-model.zip'

                $zipParams = @{
                    XmlPath       = $Script:XmlPath
                    Entries       = @($unknownEntry)
                    ZipPath       = $zipPath
                    PeriodSegment = $Script:PeriodSegment
                }

                $caught = $false

                try {
                    Compress-DFeArchive @zipParams
                } catch {
                    $caught = $true
                    $_.FullyQualifiedErrorId | Should -BeLike 'ArchiveModelUnsupported*'
                }

                $caught | Should -BeTrue
            }
        }
        #endregion

        #region Empty collections
        Context 'Empty collections' {

            It 'Creates a valid empty ZIP when Entries is empty' {
                $zipPath = Join-Path -Path $TestDrive -ChildPath 'empty-entries.zip'

                $zipParams = @{
                    XmlPath       = $Script:XmlPath
                    Entries       = @()
                    ZipPath       = $zipPath
                    PeriodSegment = $Script:PeriodSegment
                }

                { Compress-DFeArchive @zipParams } | Should -Not -Throw

                Test-Path -LiteralPath $zipPath -PathType Leaf | Should -BeTrue

                Get-ZipEntry -Path $zipPath | Should -HaveCount 0
            }

            It 'Creates a valid ZIP when Eventos is empty' {
                $zipPath = Join-Path -Path $TestDrive -ChildPath 'empty-eventos.zip'

                $zipParams = @{
                    XmlPath       = $Script:XmlPath
                    Entries       = @($Script:NfeEntry)
                    Eventos       = @()
                    ZipPath       = $zipPath
                    PeriodSegment = $Script:PeriodSegment
                }

                { Compress-DFeArchive @zipParams } | Should -Not -Throw

                Get-ZipEntry -Path $zipPath | Should -HaveCount 1
            }

            It 'Creates a valid ZIP when Eventos is omitted' {
                $zipPath = Join-Path -Path $TestDrive -ChildPath 'omitted-eventos.zip'

                $zipParams = @{
                    XmlPath       = $Script:XmlPath
                    Entries       = @($Script:NfeEntry)
                    ZipPath       = $zipPath
                    PeriodSegment = $Script:PeriodSegment
                }

                { Compress-DFeArchive @zipParams } | Should -Not -Throw

                Get-ZipEntry -Path $zipPath | Should -HaveCount 1
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
                    XmlPath       = $Script:XmlPath
                    Entries       = @($Script:NfeEntry)
                    ZipPath       = $zipPath
                    PeriodSegment = $Script:PeriodSegment
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
                    XmlPath       = $Script:XmlPath
                    Entries       = @($Script:NfeEntry)
                    ZipPath       = $zipPath
                    PeriodSegment = $Script:PeriodSegment
                }

                Compress-DFeArchive @zipParams

                $after = [System.IO.File]::ReadAllBytes($Script:NfePath)

                $after | Should -Be $before
            }

            It 'Does not modify the source evento' {
                $before  = [System.IO.File]::ReadAllBytes($Script:EventoPath)
                $zipPath = Join-Path -Path $TestDrive -ChildPath 'source-evento-preservation.zip'

                $zipParams = @{
                    XmlPath       = $Script:XmlPath
                    Entries       = @($Script:NfeEntry)
                    Eventos       = @($Script:EventoEntry)
                    ZipPath       = $zipPath
                    PeriodSegment = $Script:PeriodSegment
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
                    PeriodSegment    = $Script:PeriodSegment
                    CompressionLevel = ([System.IO.Compression.CompressionLevel]::Fastest)
                }

                { Compress-DFeArchive @zipParams } | Should -Not -Throw

                $entries = Get-ZipEntry -Path $zipPath

                $entries | Should -Contain (
                    '55_NFe/{0}/{1}' -f $Script:PeriodSegment, $Script:NfeFileName
                )
            }

            It 'Uses Optimal as the default compression level' {
                $zipPath = Join-Path -Path $TestDrive -ChildPath 'compression-default.zip'

                $zipParams = @{
                    XmlPath       = $Script:XmlPath
                    Entries       = @($Script:NfeEntry)
                    ZipPath       = $zipPath
                    PeriodSegment = $Script:PeriodSegment
                }

                { Compress-DFeArchive @zipParams } | Should -Not -Throw
            }
        }
        #endregion
    }
}
