<#
.SYNOPSIS
Creates a structured ZIP archive from DFe index entries.

.DESCRIPTION
Builds a ZIP file with the following internal structure:

    {modelo_folder}/{chave}/{filename}

Eventos are placed inside their parent document's subfolder rather than
a dedicated top-level folder. Empty model folders are omitted.

The model folder map is derived at runtime from the ModeloDFe enum so
new models are automatically included without requiring code changes.

Source files are never modified.

.PARAMETER XmlPath
The company's XML source directory. Read-only.

.PARAMETER Entries
DFe index entries to include in the archive.

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
  Add-ZipEntry (private helper defined in this file)
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

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ZipPath,

        [Parameter()]
        [System.IO.Compression.CompressionLevel]$CompressionLevel =
        [System.IO.Compression.CompressionLevel]::Optimal
    )

    Add-Type -AssemblyName 'System.IO.Compression'
    Add-Type -AssemblyName 'System.IO.Compression.FileSystem'

    # Derived directly from the ModeloDFe enum so this map can never drift
    # out of sync when a new model is added. Value 0 is reserved for Eventos,
    # which are embedded in their parent document's subfolder.
    $modelFolders = @{ 0 = $null }

    foreach ($modelName in [System.Enum]::GetNames([ModeloDFe])) {
        $modelValue = [int][ModeloDFe]$modelName
        $modelFolders[$modelValue] = '{0}_{1}' -f $modelValue, $modelName
    }

    # O(1) lookup: chave de acesso -> eventos linked to that document.
    # Group-Object -AsHashTable returns $null when the pipeline is empty.
    # Guard with an empty hashtable so $eventosPorChave[$chave] is always
    # a valid index operation under Set-StrictMode -Version Latest.
    $eventosPorChave = $Entries |
        Where-Object { $_.DfeModel -eq 0 } |
        Group-Object -Property ChavePai -AsHashTable

    if ($null -eq $eventosPorChave) {
        $eventosPorChave = @{}
    }

    $stream  = $null
    $archive = $null

    try {
        # Resolve the full path first so GetDirectoryName always returns
        # a valid directory, even when ZipPath contains only a file name.
        $directory = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($ZipPath))

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

        $groupedByModel = $Entries | Group-Object -Property DfeModel

        foreach ($group in $groupedByModel) {
            $model = [int]$group.Name

            # Eventos are embedded in parent folders - skip as top-level group.
            if ($model -eq 0) {
                continue
            }

            $folder = $modelFolders[$model]

            if ($null -eq $folder) {
                Write-Warning -Message (
                    "Unknown DFe model '$model' - skipping group. " +
                    "This model is not defined in the ModeloDFe enum; " +
                    "the corresponding documents were NOT included in the ZIP."
                )
                continue
            }

            foreach ($entry in $group.Group) {
                $sourcePath = Join-Path -Path $XmlPath -ChildPath $entry.FilePath

                if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
                    Write-Warning -Message "Source file not found, skipping: '$sourcePath'"
                    continue
                }

                $chave        = $entry.ChaveAcesso
                $zipEntryPath = $folder, $chave, $entry.FileName -join '/'

                $addParams = @{
                    Archive          = $archive
                    SourcePath       = $sourcePath
                    ZipEntryPath     = $zipEntryPath
                    CompressionLevel = $CompressionLevel
                }

                Add-ZipEntry @addParams

                $eventos = $eventosPorChave[$chave]

                if ($eventos) {
                    foreach ($evento in $eventos) {
                        $eventoSource = Join-Path -Path $XmlPath -ChildPath $evento.FilePath

                        if (-not (Test-Path -LiteralPath $eventoSource -PathType Leaf)) {
                            Write-Warning -Message "Evento source file not found, skipping: '$eventoSource'"
                            continue
                        }

                        $eventoZipPath = $folder, $chave, $evento.FileName -join '/'

                        $eventoParams = @{
                            Archive          = $archive
                            SourcePath       = $eventoSource
                            ZipEntryPath     = $eventoZipPath
                            CompressionLevel = $CompressionLevel
                        }

                        Add-ZipEntry @eventoParams
                    }
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

#region Private helper
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
    $entryStream = $zipEntry.Open()

    try {
        $sourceStream = [System.IO.File]::OpenRead($SourcePath)

        try {
            $sourceStream.CopyTo($entryStream)
        } finally {
            $sourceStream.Dispose()
        }
    } finally {
        $entryStream.Dispose()
    }

    Write-Verbose -Message "Added to ZIP: $ZipEntryPath"
}
#endregion
