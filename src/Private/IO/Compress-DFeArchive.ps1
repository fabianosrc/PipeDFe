<#
.SYNOPSIS
Creates a structured ZIP archive from DFe index entries.

.DESCRIPTION
Builds a ZIP file with the following internal structure:

    {modelo_folder}/{ChaveAcesso}/{filename}

Eventos are placed inside their parent document's subfolder rather than
a dedicated top-level folder.

The model folder name is derived at runtime from the ModeloDFe enum so
new models are automatically included without requiring code changes.

Source files are never modified.

.PARAMETER XmlPath
The company's XML source directory. Read-only.

.PARAMETER Entries
DFe document entries mapped to PascalCase by New-DFeArchive.
Each entry must expose: ChaveAcesso, Modelo, FilePath.

.PARAMETER Eventos
DFe evento entries mapped to PascalCase by New-DFeArchive.
Each entry must expose: ChavePai, FilePath.

Events are associated with their parent document by ChavePai.
When omitted or empty, no eventos are embedded.

.PARAMETER ZipPath
Full path to the output ZIP file.

.PARAMETER CompressionLevel
Compression level. Defaults to Optimal.

.OUTPUTS
None.

.EXAMPLE
PS C:\> $compressParams = @{
    XmlPath = 'C:\ERP\XMLs'
    Entries = $entries
    ZipPath = 'C:\Temp\DFe.zip'
}

PS C:\> Compress-DFeArchive @compressParams

.NOTES
Private dependencies:
  Add-ZipEntry
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
        [System.IO.Compression.CompressionLevel]$CompressionLevel = [System.IO.Compression.CompressionLevel]::Optimal
    )

    Add-Type -AssemblyName 'System.IO.Compression'
    Add-Type -AssemblyName 'System.IO.Compression.FileSystem'

    # Build the model-folder lookup directly from ModeloDFe.
    # This keeps the archive structure synchronized with the enum.
    $modelFolders = @{}

    foreach ($modelName in [System.Enum]::GetNames([ModeloDFe])) {
        $modelValue = [int][ModeloDFe]$modelName

        $modelFolders[$modelValue] = '{0}_{1}' -f $modelValue, $modelName
    }

    # Index eventos by their parent document key.
    # This avoids repeatedly filtering the complete Eventos collection.
    $eventosPorChave = @{}

    if ($null -ne $Eventos -and $Eventos.Count -gt 0) {
        foreach ($evento in $Eventos) {
            $chave = $evento.ChavePai

            if (-not $eventosPorChave.ContainsKey($chave)) {
                $eventosPorChave[$chave] = [System.Collections.Generic.List[pscustomobject]]::new()
            }

            $eventosPorChave[$chave].Add($evento)
        }
    }

    $stream  = $null
    $archive = $null

    try {
        # Ensure the output directory exists.
        $directory = [System.IO.Path]::GetDirectoryName(
            [System.IO.Path]::GetFullPath($ZipPath)
        )

        if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
            [System.IO.Directory]::CreateDirectory($directory) | Out-Null
        }

        # Create the destination ZIP directly.
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

        # Group documents by model so the model folder is calculated once
        # per group instead of once per document.
        $groupedByModel = $Entries | Group-Object -Property Modelo

        foreach ($group in $groupedByModel) {
            $modelValue = [int]$group.Name

            $folder = $modelFolders[$modelValue]

            if ($null -eq $folder) {
                Write-Warning -Message (
                    "Unknown DFe model '$modelValue' - skipping group. " +
                    'This model is not defined in the ModeloDFe enum; ' +
                    'the corresponding documents were NOT included in the ZIP.'
                )

                continue
            }

            foreach ($entry in $group.Group) {
                $sourcePath = [System.IO.Path]::Combine($XmlPath, $entry.FilePath)

                if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
                    Write-Warning -Message "Source file not found, skipping: '$sourcePath'"
                    continue
                }

                $chave    = $entry.ChaveAcesso
                $fileName = [System.IO.Path]::GetFileName($entry.FilePath)

                $zipEntryPath = $folder, $chave, $fileName -join '/'

                $addZipParams = @{
                    Archive          = $archive
                    SourcePath       = $sourcePath
                    ZipEntryPath     = $zipEntryPath
                    CompressionLevel = $CompressionLevel
                }

                Add-ZipEntry @addZipParams

                # Embed eventos inside the parent document's directory.
                $eventosForChave = $eventosPorChave[$chave]

                if ($null -eq $eventosForChave) {
                    continue
                }

                foreach ($evento in $eventosForChave) {
                    $eventoSource = [System.IO.Path]::Combine($XmlPath, $evento.FilePath)

                    if (-not (Test-Path -LiteralPath $eventoSource -PathType Leaf)) {
                        Write-Warning -Message "Evento source file not found, skipping: '$eventoSource'"
                        continue
                    }

                    $eventoFileName = [System.IO.Path]::GetFileName($evento.FilePath)
                    $eventoZipPath  = $folder, $chave, $eventoFileName -join '/'

                    $addZipParams = @{
                        Archive          = $archive
                        SourcePath       = $eventoSource
                        ZipEntryPath     = $eventoZipPath
                        CompressionLevel = $CompressionLevel
                    }

                    Add-ZipEntry @addZipParams
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

    $zipEntry     = $Archive.CreateEntry($ZipEntryPath, $CompressionLevel)
    $entryStream  = $null
    $sourceStream = $null

    try {
        $entryStream  = $zipEntry.Open()
        $sourceStream = [System.IO.File]::OpenRead($SourcePath)

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
