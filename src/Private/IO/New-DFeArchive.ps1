<#
.SYNOPSIS
Creates one ZIP archive per DFe document type.

.DESCRIPTION
Orchestrates archive creation for each pre-calculated archive info:

  1. Compresses matching entries to a temporary ZIP via Compress-DFeArchive.
  2. Validates the ZIP was created and throws ZipNotCreated when absent.
  3. Computes SHA-256 of the temporary ZIP.
  4. Copies the temporary ZIP to the destination path.

Eventos (DfeModel = 0) are not grouped into their own archive - they are
embedded inside their parent document's subfolder by Compress-DFeArchive.

Returns one result object per archive created.

.PARAMETER Cnpj
Empresa CNPJ. Used in error messages only.

.PARAMETER Company
Empresa object exposing XmlPath and OutputPath.

.PARAMETER Entries
Index entries to include in the archive. Mixed document types are supported.

.PARAMETER ArchiveInfos
Pre-calculated archive metadata from Resolve-DFeArchiveInfo, one per
document type. Each object must expose TipoDFe, FileName, TempPath
and DestPath.

.OUTPUTS
System.Management.Automation.PSCustomObject

TipoDFe  [string] - Document type label matching DFeModelo enum name.
FileName [string] - ZIP file name.
FileHash [string] - SHA-256 hash of the temporary ZIP.
TempPath [string] - Full path to the temporary ZIP.
DestPath [string] - Full path to the destination ZIP.

.EXAMPLE
PS C:\> $archiveParams = @{
    Cnpj         = $cnpj
    Company      = $company
    Entries      = $entries
    ArchiveInfos = $archiveInfos
}

PS C:\> $archives = New-DFeArchive @archiveParams

.NOTES
Private dependencies:
  Compress-DFeArchive
  Get-FileSha256
#>
function New-DFeArchive {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions',
        '',
        Justification = 'ShouldProcess would add no value here.'
    )]
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Cnpj,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject]$Company,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [pscustomobject[]]$Entries,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject[]]$ArchiveInfos
    )

    if (-not (Test-Path -LiteralPath $Company.OutputPath -PathType Container)) {
        [System.IO.Directory]::CreateDirectory($Company.OutputPath) | Out-Null
    }

    foreach ($archiveInfo in $ArchiveInfos) {
        $modelValue = [int][System.Enum]::Parse([ModeloDFe], $archiveInfo.TipoDFe)

        $groupEntries = @(
            $Entries | Where-Object { $_.DfeModel -eq $modelValue }
            $Entries | Where-Object { $_.DfeModel -eq 0 }
        )

        $compressParams = @{
            XmlPath = $Company.XmlPath
            Entries = $groupEntries
            ZipPath = $archiveInfo.TempPath
        }

        Compress-DFeArchive @compressParams

        if (-not (Test-Path -LiteralPath $archiveInfo.TempPath -PathType Leaf)) {
            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.IO.FileNotFoundException]::new(
                        "[$Cnpj] Compress-DFeArchive completed but the ZIP was not created: '$($archiveInfo.TempPath)'."
                    ),
                    'ZipNotCreated',
                    [System.Management.Automation.ErrorCategory]::ResourceUnavailable,
                    $archiveInfo.TempPath
                )
            )
        }

        $copyParams = @{
            LiteralPath = $archiveInfo.TempPath
            Destination = $archiveInfo.DestPath
            Force       = $true
        }

        $zipHash = Get-FileSha256 -Path $archiveInfo.TempPath

        Copy-Item @copyParams

        [PSCustomObject]@{
            TipoDFe  = $archiveInfo.TipoDFe
            FileName = $archiveInfo.FileName
            FileHash = $zipHash
            TempPath = $archiveInfo.TempPath
            DestPath = $archiveInfo.DestPath
        }
    }
}
