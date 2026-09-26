<#
.SYNOPSIS
Creates a structured ZIP archive from DFe index entries.

.DESCRIPTION
Builds a ZIP file with the following internal structure:

    {modelo_folder}/{ChaveAcesso}/{filename}

Eventos are placed inside their parent document's subfolder rather than
a dedicated top-level folder.

The model folder name is derived at runtime from the ModeloDFe enum.

Every indexed document and event is validated before being added:

  - The source file must exist.
  - The indexed SHA-256 must be present.
  - The current SHA-256 must match the indexed SHA-256.

An unknown model or invalid source terminates archive creation. Indexed
content is never silently omitted from the archive.

Source files are never modified.

.PARAMETER XmlPath
The company's XML source directory. Read-only.

.PARAMETER Entries
DFe document entries mapped to PascalCase by New-DFeArchive.

Each entry must expose:
  ChaveAcesso
  Modelo
  FilePath
  Sha256

.PARAMETER Eventos
DFe event entries mapped to PascalCase by New-DFeArchive.

Each event must expose:
  ChavePai
  FilePath
  Sha256

Events are associated with their parent document by ChavePai.

When omitted or empty, no events are embedded.

.PARAMETER ZipPath
Full path to the ZIP file to create.

.PARAMETER CompressionLevel
Compression level. Defaults to Optimal.

.OUTPUTS
None.

.EXAMPLE
PS C:\> $compressParams = @{
    XmlPath = 'C:\ERP\XMLs'
    Entries = $entries
    Eventos = $eventos
    ZipPath = 'C:\Temp\DFe.zip'
}

PS C:\> Compress-DFeArchive @compressParams

.NOTES
Private dependencies:
  Add-ZipEntry
  Assert-DFeArchiveSource
  ModeloDFe
#>
function Compress-DFeArchive {
    [CmdletBinding()]
    [OutputType([void])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$XmlPath,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [pscustomobject[]]$Entries,

        [Parameter()]
        [AllowEmptyCollection()]
        [pscustomobject[]]$Eventos,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ZipPath,

        [Parameter()]
        [System.IO.Compression.CompressionLevel]$CompressionLevel =
        [System.IO.Compression.CompressionLevel]::Optimal
    )

    Add-Type -AssemblyName 'System.IO.Compression'
    Add-Type -AssemblyName 'System.IO.Compression.FileSystem'

    $modelFolders = @{}

    foreach ($modelName in [System.Enum]::GetNames([ModeloDFe])) {
        $modelValue = [int][ModeloDFe]$modelName

        $modelFolders[$modelValue] = '{0}_{1}' -f $modelValue, $modelName
    }

    $eventosByChave = @{}

    if ($null -ne $Eventos -and $Eventos.Count -gt 0) {
        foreach ($evento in $Eventos) {
            $chavePai = $evento.ChavePai

            if (-not $eventosByChave.ContainsKey($chavePai)) {
                $eventosByChave[$chavePai] = [System.Collections.Generic.List[pscustomobject]]::new()
            }

            $eventosByChave[$chavePai].Add($evento)
        }
    }

    $stream  = $null
    $archive = $null

    try {
        $directory = [System.IO.Path]::GetDirectoryName(
            [System.IO.Path]::GetFullPath($ZipPath)
        )

        if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
            [System.IO.Directory]::CreateDirectory($directory) | Out-Null
        }

        $stream = [System.IO.FileStream]::new(
            $ZipPath,
            [System.IO.FileMode]::Create,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None
        )

        $archive = [System.IO.Compression.ZipArchive]::new(
            $stream,
            [System.IO.Compression.ZipArchiveMode]::Create
        )

        $groupedByModel = $Entries | Group-Object -Property Modelo

        foreach ($group in $groupedByModel) {
            $modelValue = [int]$group.Name
            $folder = $modelFolders[$modelValue]

            if ($null -eq $folder) {
                throw [System.Management.Automation.ErrorRecord]::new(
                    [System.InvalidOperationException]::new(
                        "DFe model '$modelValue' is not defined in ModeloDFe."
                    ),
                    'ArchiveModelUnsupported',
                    [System.Management.Automation.ErrorCategory]::InvalidData,
                    $modelValue
                )
            }

            foreach ($entry in $group.Group) {
                $sourcePath = [System.IO.Path]::Combine(
                    $XmlPath,
                    $entry.FilePath
                )

                $assertParams = @{
                    SourcePath  = $sourcePath
                    IndexedHash = $entry.Sha256
                    SourceKind  = 'document'
                    SourceId    = $entry.ChaveAcesso
                }

                Assert-DFeArchiveSource @assertParams

                $chave = $entry.ChaveAcesso
                $fileName = [System.IO.Path]::GetFileName($entry.FilePath)
                $zipEntryPath = $folder, $chave, $fileName -join '/'

                $addParams = @{
                    Archive          = $archive
                    SourcePath       = $sourcePath
                    ZipEntryPath     = $zipEntryPath
                    CompressionLevel = $CompressionLevel
                }

                Add-ZipEntry @addParams

                $eventosForChave = $eventosByChave[$chave]

                if ($null -eq $eventosForChave) {
                    continue
                }

                foreach ($evento in $eventosForChave) {
                    $eventoSource = [System.IO.Path]::Combine(
                        $XmlPath,
                        $evento.FilePath
                    )

                    $assertParams = @{
                        SourcePath  = $eventoSource
                        IndexedHash = $evento.Sha256
                        SourceKind  = 'event'
                        SourceId    = $evento.ChavePai
                    }

                    Assert-DFeArchiveSource @assertParams

                    $eventoFileName = [System.IO.Path]::GetFileName(
                        $evento.FilePath
                    )

                    $eventoZipPath = $folder, $chave, $eventoFileName -join '/'

                    $addParams = @{
                        Archive          = $archive
                        SourcePath       = $eventoSource
                        ZipEntryPath     = $eventoZipPath
                        CompressionLevel = $CompressionLevel
                    }

                    Add-ZipEntry @addParams
                }
            }
        }
    } finally {
        if ($null -ne $archive) {
            $archive.Dispose()
        }

        if ($null -ne $stream) {
            $stream.Dispose()
        }
    }
}

#region Private Helper
function Add-ZipEntry {
    [CmdletBinding()]
    [OutputType([void])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [System.IO.Compression.ZipArchive]$Archive,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$SourcePath,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ZipEntryPath,

        [Parameter(Mandatory)]
        [System.IO.Compression.CompressionLevel]$CompressionLevel
    )

    $zipEntry = $Archive.CreateEntry($ZipEntryPath, $CompressionLevel)

    $entryStream = $null
    $sourceStream = $null

    try {
        $entryStream = $zipEntry.Open()

        $sourceStream = [System.IO.File]::Open(
            $SourcePath,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::Read
        )

        $sourceStream.CopyTo($entryStream)
    } finally {
        if ($null -ne $sourceStream) {
            $sourceStream.Dispose()
        }

        if ($null -ne $entryStream) {
            $entryStream.Dispose()
        }
    }

    Write-Verbose -Message "Added to ZIP: $ZipEntryPath"
}
#endregion
