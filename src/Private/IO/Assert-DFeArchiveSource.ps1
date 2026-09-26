<#
.SYNOPSIS
Validates an indexed source file before it is added to a DFe archive.

.DESCRIPTION
Validates that an indexed DFe document or event source still represents the
same physical content that was indexed.

The function verifies:

  - The source file exists.
  - The indexed SHA-256 is present.
  - The current SHA-256 matches the indexed SHA-256.

Any validation failure is terminating because silently omitting or accepting
a changed indexed source would produce an incomplete or inconsistent archive.

.PARAMETER SourcePath
Full path to the source file.

.PARAMETER IndexedHash
SHA-256 stored in the DFe index for the source file.

.PARAMETER SourceKind
Logical source type. Accepted values are document and event.

.PARAMETER SourceId
Logical identifier used for diagnostic context.

For documents, this is normally the chave de acesso.
For events, this is normally the parent document chave.

.OUTPUTS
None.

.EXAMPLE
PS C:\> $assertParams = @{
    SourcePath  = 'C:\ERP\XMLs\nfe.xml'
    IndexedHash = $entry.sha256
    SourceKind  = 'document'
    SourceId    = $entry.chave_acesso
}

PS C:\> Assert-DFeArchiveSource @assertParams

.NOTES
Private dependencies:
  Get-FileSha256
#>
function Assert-DFeArchiveSource {
    [CmdletBinding()]
    [OutputType([void])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$SourcePath,

        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$IndexedHash,

        [Parameter(Mandatory)]
        [ValidateSet('document', 'event')]
        [string]$SourceKind,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$SourceId
    )

    if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) {
        throw [System.Management.Automation.ErrorRecord]::new(
            [System.IO.FileNotFoundException]::new(
                "Archive $SourceKind source not found: '$SourcePath'."
            ),
            'ArchiveSourceNotFound',
            [System.Management.Automation.ErrorCategory]::ObjectNotFound,
            $SourcePath
        )
    }

    if ([string]::IsNullOrWhiteSpace($IndexedHash)) {
        throw [System.Management.Automation.ErrorRecord]::new(
            [System.InvalidOperationException]::new(
                "Archive $SourceKind '$SourceId' has no indexed SHA-256."
            ),
            'ArchiveSourceHashMissing',
            [System.Management.Automation.ErrorCategory]::InvalidData,
            $SourcePath
        )
    }

    $currentHash = Get-FileSha256 -Path $SourcePath

    $hashMatches = [string]::Equals(
        $currentHash,
        $IndexedHash,
        [System.StringComparison]::OrdinalIgnoreCase
    )

    if (-not $hashMatches) {
        throw [System.Management.Automation.ErrorRecord]::new(
            [System.IO.InvalidDataException]::new(
                "Archive $SourceKind source changed after indexing: '$SourcePath'."
            ),
            'ArchiveSourceHashMismatch',
            [System.Management.Automation.ErrorCategory]::InvalidData,
            $SourcePath
        )
    }
}
