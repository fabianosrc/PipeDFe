#Requires -Version 5.1

<#
.SYNOPSIS
Creates a ZIP archive containing national NFS-e XML documents.

.DESCRIPTION
Creates and publishes a ZIP archive for national NFS-e documents
previously imported into the company's SQLite index.

Coverage includes:
  - Empty document collections.
  - National NFS-e archive metadata resolution.
  - Absolute source path validation.
  - Source file existence and SHA-256 integrity.
  - Duplicate archive entry detection.
  - Deterministic internal archive paths.
  - Temporary archive creation.
  - Archive hash calculation.
  - Atomic archive publication.
  - Temporary file cleanup after success or failure.

The archive contains only national NFS-e documents supplied by the
caller. Period filtering belongs to Get-DFeNFSeEntry.

The function does not modify source XML files, query the database,
send email, or manage persistent delivery state.

.PARAMETER Cnpj
Normalized company CNPJ.

.PARAMETER Company
Company configuration containing archive output information.

.PARAMETER Entries
National NFS-e entries returned by Get-DFeNFSeEntry.

.PARAMETER DateRange
Processing period returned by Resolve-DateRange.

.OUTPUTS
System.Management.Automation.PSCustomObject

Returns archive metadata containing:
  TipoDFe
  FileName
  FileHash
  TempPath
  DestPath

Returns no output when Entries is empty.

.NOTES
Private dependencies:
  Resolve-DFeArchiveInfo
  Get-ArchivePeriodSegment
  Assert-DFeArchiveSource
  Add-ZipEntry
  Get-FileSha256
  Publish-DFeArchive
#>

function New-DFeNFSeArchive {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'ShouldProcess not part of the internal contract.'
    )]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory)]
        [ValidatePattern('^(?-i)[A-Z0-9]{14}$')]
        [string]$Cnpj,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject]$Company,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [pscustomobject[]]$Entries,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject]$DateRange
    )

    if ($Entries.Count -eq 0) {
        return
    }

    $archiveInfoParams = @{
        TipoDFe   = 'NFSe'
        Cnpj      = $Cnpj
        Company   = $Company
        DateRange = $DateRange
    }

    $archiveInfo   = Resolve-DFeArchiveInfo @archiveInfoParams

    $periodSegment = Get-ArchivePeriodSegment -DateRange $DateRange

    $seenPaths = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )

    $archiveEntries = [System.Collections.Generic.List[pscustomobject]]::new()

    foreach ($entry in $Entries) {
        $sourcePath = [string]$entry.file_path
        $accessKey  = [string]$entry.chave_acesso

        if ($accessKey -cnotmatch '^[0-9]{50}$' -or -not
            [System.IO.Path]::IsPathRooted($sourcePath)
        ) {
            throw [System.Management.Automation.ErrorRecord]::new(
                [System.ArgumentException]::new(
                    'Invalid national NFS-e archive entry.'
                ),
                'InvalidNFSeArchiveEntry',
                [System.Management.Automation.ErrorCategory]::InvalidData,
                $entry
            )
        }

        $fileName = [System.IO.Path]::GetFileName($sourcePath)
        $zipEntryPath = @('NFSe', $periodSegment, $fileName) -join '/'

        if (-not $seenPaths.Add($zipEntryPath)) {
            throw [System.Management.Automation.ErrorRecord]::new(
                [System.InvalidOperationException]::new(
                    "Duplicate archive path: '$zipEntryPath'."
                ),
                'ArchiveDuplicatePath',
                [System.Management.Automation.ErrorCategory]::InvalidData,
                $zipEntryPath
            )
        }

        $archiveEntries.Add(
            [PSCustomObject]@{
                SourcePath   = $sourcePath
                IndexedHash  = [string]$entry.source_sha256
                AccessKey    = $accessKey
                ZipEntryPath = $zipEntryPath
            }
        )
    }

    $stream  = $null
    $archive = $null

    try {
        foreach ($entry in $archiveEntries) {
            $assertParams = @{
                SourcePath  = $entry.SourcePath
                IndexedHash = $entry.IndexedHash
                SourceKind  = 'document'
                SourceId    = $entry.AccessKey
            }

            Assert-DFeArchiveSource @assertParams
        }

        $tempDirectory = [System.IO.Path]::GetDirectoryName(
            $archiveInfo.TempPath
        )

        if (-not (Test-Path -LiteralPath $tempDirectory -PathType Container)) {
            [System.IO.Directory]::CreateDirectory(
                $tempDirectory
            ) | Out-Null
        }

        Add-Type -AssemblyName 'System.IO.Compression'
        Add-Type -AssemblyName 'System.IO.Compression.FileSystem'

        $stream = [System.IO.FileStream]::new(
            $archiveInfo.TempPath,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None
        )

        $archive = [System.IO.Compression.ZipArchive]::new(
            $stream,
            [System.IO.Compression.ZipArchiveMode]::Create
        )

        foreach ($entry in $archiveEntries) {
            $addParams = @{
                Archive          = $archive
                SourcePath       = $entry.SourcePath
                ZipEntryPath     = $entry.ZipEntryPath
                CompressionLevel = [System.IO.Compression.CompressionLevel]::Optimal
            }

            Add-ZipEntry @addParams
        }

        $archive.Dispose()
        $archive = $null

        $stream.Dispose()
        $stream = $null

        $hashParams = @{
            Path        = $archiveInfo.TempPath
            ErrorAction = 'Stop'
        }

        $zipHash = Get-FileSha256 @hashParams

        $publishParams = @{
            SourcePath      = $archiveInfo.TempPath
            DestinationPath = $archiveInfo.DestPath
            ExpectedHash    = $zipHash
            ErrorAction     = 'Stop'
        }

        Publish-DFeArchive @publishParams

        [PSCustomObject]@{
            TipoDFe  = $archiveInfo.TipoDFe
            FileName = $archiveInfo.FileName
            FileHash = $zipHash
            TempPath = $archiveInfo.TempPath
            DestPath = $archiveInfo.DestPath
        }
    } finally {
        if ($null -ne $archive) {
            $archive.Dispose()
        }

        if ($null -ne $stream) {
            $stream.Dispose()
        }

        if (Test-Path -LiteralPath $archiveInfo.TempPath -PathType Leaf) {
            $removeItemParams = @{
                LiteralPath = $archiveInfo.TempPath
                Force       = $true
                ErrorAction = 'SilentlyContinue'
            }

            Remove-Item @removeItemParams
        }
    }
}
