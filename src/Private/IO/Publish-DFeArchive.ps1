<#
.SYNOPSIS
Publishes a validated DFe archive to its final destination.

.DESCRIPTION
Copies a completed archive into a uniquely named staging file in the
destination directory, flushes the staged data, and validates its SHA-256
before publication.

The staged file is published using File.Move when the destination does
not exist, or File.Replace when the destination exists.

Staging in the destination directory keeps the publication operation
within the same directory and normally the same filesystem volume.

The existing destination is not modified until the staged archive has
passed SHA-256 validation.

Publication failures are reported as terminating errors. Temporary
staging and backup files are removed on a best-effort basis.

Concurrent publishers are not serialized by this function. If multiple
processes publish to the same destination, coordinate them externally
when deterministic ordering is required.

.PARAMETER SourcePath
Path to the completed source archive.

.PARAMETER DestinationPath
Path to the final archive destination.

.PARAMETER ExpectedHash
Expected SHA-256 of the source archive, represented by 64 hexadecimal
characters.

.OUTPUTS
None.

.NOTES
Private dependency:
  Get-FileSha256

ErrorIds:
  ArchivePublishFailed
  ArchiveStageCopyFailed
  ArchiveStageHashFailed
  ArchiveStageHashMismatch

Requires a filesystem that supports the requested move and replacement
operations. Validate behavior on every supported operating system and
filesystem.
#>
function Publish-DFeArchive {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSAvoidUsingEmptyCatchBlock',
        '',
        Justification = 'Cleanup failures are intentionally ignored.'
    )]
    [CmdletBinding()]
    [OutputType([void])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$SourcePath,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$DestinationPath,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [ValidatePattern('^(?i:[a-f0-9]{64})$')]
        [string]$ExpectedHash
    )

    $operationID = [guid]::NewGuid().ToString('N')

    try {
        $sourceFullPath = [System.IO.Path]::GetFullPath($SourcePath)
        $destinationFullPath = [System.IO.Path]::GetFullPath($DestinationPath)
        $destinationDirectory = [System.IO.Path]::GetDirectoryName($destinationFullPath)

        if ([string]::IsNullOrWhiteSpace($destinationDirectory) -or
            [string]::IsNullOrWhiteSpace([System.IO.Path]::GetFileName($destinationFullPath))
        ) {
            throw [System.ArgumentException]::new(
                'The destination must identify a file inside a directory.'
            )
        }
    } catch {
        throw [System.Management.Automation.ErrorRecord]::new(
            [System.IO.IOException]::new(
                'Failed to resolve the archive source or destination path.',
                $_.Exception
            ),
            'ArchivePublishFailed',
            [System.Management.Automation.ErrorCategory]::InvalidArgument,
            $DestinationPath
        )
    }

    try {
        [void][System.IO.Directory]::CreateDirectory($destinationDirectory)
    } catch {
        throw [System.Management.Automation.ErrorRecord]::new(
            [System.IO.IOException]::new(
                "Failed to prepare destination directory '$destinationDirectory'.",
                $_.Exception
            ),
            'ArchivePublishFailed',
            [System.Management.Automation.ErrorCategory]::WriteError,
            $destinationDirectory
        )
    }

    $stagePath = Join-Path -Path $destinationDirectory -ChildPath (
        '.publish-{0}.tmp' -f $operationID
    )

    $backupPath = Join-Path -Path $destinationDirectory -ChildPath (
        '.publish-{0}.backup' -f $operationID
    )

    $sourceStream = $null
    $stageStream  = $null

    try {
        # CreateNew prevents accidental reuse of an existing staging file.
        try {
            $sourceStream = [System.IO.File]::Open(
                $sourceFullPath,
                [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::Read,
                [System.IO.FileShare]::Read
            )

            $stageStream = [System.IO.File]::Open(
                $stagePath,
                [System.IO.FileMode]::CreateNew,
                [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::None
            )

            $sourceStream.CopyTo($stageStream)

            # Request that buffered file data be flushed to the device.
            $stageStream.Flush($true)
        } catch {
            throw [System.Management.Automation.ErrorRecord]::new(
                [System.IO.IOException]::new(
                    "Failed to stage archive '$sourceFullPath' to '$stagePath'.",
                    $_.Exception
                ),
                'ArchiveStageCopyFailed',
                [System.Management.Automation.ErrorCategory]::WriteError,
                $stagePath
            )
        } finally {
            if ($null -ne $stageStream) {
                $stageStream.Dispose()
                $stageStream = $null
            }

            if ($null -ne $sourceStream) {
                $sourceStream.Dispose()
                $sourceStream = $null
            }
        }

        # Validate the completed staging file, not merely the source.
        try {
            $stageHash = Get-FileSha256 -Path $stagePath -ErrorAction Stop
        } catch {
            throw [System.Management.Automation.ErrorRecord]::new(
                [System.IO.IOException]::new(
                    "Failed to calculate SHA-256 for staged archive '$stagePath'.",
                    $_.Exception
                ),
                'ArchiveStageHashFailed',
                [System.Management.Automation.ErrorCategory]::ReadError,
                $stagePath
            )
        }

        if (-not [string]::Equals(
                $stageHash,
                $ExpectedHash,
                [System.StringComparison]::OrdinalIgnoreCase)
        ) {
            throw [System.Management.Automation.ErrorRecord]::new(
                [System.IO.InvalidDataException]::new(
                    "Staged archive SHA-256 does not match the expected hash: '$stagePath'."
                ),
                'ArchiveStageHashMismatch',
                [System.Management.Automation.ErrorCategory]::InvalidData,
                $stagePath
            )
        }

        # Publish only after successful staging and hash validation.
        try {
            if ([System.IO.File]::Exists($destinationFullPath)) {
                [System.IO.File]::Replace(
                    $stagePath,
                    $destinationFullPath,
                    $backupPath
                )
            } else {
                [System.IO.File]::Move($stagePath, $destinationFullPath)
            }
        } catch {
            throw [System.Management.Automation.ErrorRecord]::new(
                [System.IO.IOException]::new(
                    "Failed to publish archive to '$destinationFullPath'.",
                    $_.Exception
                ),
                'ArchivePublishFailed',
                [System.Management.Automation.ErrorCategory]::WriteError,
                $destinationFullPath
            )
        }
    } finally {
        # Dispose streams even if an unexpected error occurs.
        if ($null -ne $stageStream) {
            $stageStream.Dispose()
        }

        if ($null -ne $sourceStream) {
            $sourceStream.Dispose()
        }

        # Cleanup is best-effort and must not mask the primary failure.
        foreach ($temporaryPath in @($stagePath, $backupPath)) {
            if ([string]::IsNullOrWhiteSpace($temporaryPath)) {
                continue
            }

            try {
                if ([System.IO.File]::Exists($temporaryPath)) {
                    [System.IO.File]::Delete($temporaryPath)
                }
            } catch {
                # Intentionally suppress cleanup failures.
            }
        }
    }
}
