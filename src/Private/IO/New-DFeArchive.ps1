<#
.SYNOPSIS
Creates one ZIP archive per DFe document type.

.DESCRIPTION
Orchestrates archive creation for each pre-calculated archive info:

    1. Ensures the company output directory exists.
    2. Loads events from the index for all documents in the batch.
    3. Maps store snake_case entries to PascalCase IO objects.
    4. Preserves indexed SHA-256 values for source-integrity validation.
    5. Groups documents by the archive's DFe model.
    6. Selects only events belonging to documents in that archive.
    7. Creates the temporary ZIP via Compress-DFeArchive.
    8. Verifies that the temporary ZIP was created.
    9. Computes the temporary ZIP SHA-256.
   10. Publishes the validated ZIP atomically to its destination.
   11. Removes the temporary ZIP on a best-effort basis.

Source-integrity failures raised by Compress-DFeArchive are terminating and
are allowed to propagate unchanged.

Temporary archives are cleaned whether processing succeeds or fails.

Returns one result object per successfully published archive.

.PARAMETER Cnpj
Normalized company CNPJ.

.PARAMETER Company
Company object exposing XmlPath and OutputPath.

.PARAMETER Entries
Document index entries returned by Get-DFeDocumentEntry.

.PARAMETER ArchiveInfos
Pre-calculated archive metadata returned by Resolve-DFeArchiveInfo.

Each object must expose:

  TipoDFe
  FileName
  TempPath
  DestPath

.OUTPUTS
System.Management.Automation.PSCustomObject

Properties:

  TipoDFe  [string]
  FileName [string]
  FileHash [string]
  TempPath [string]
  DestPath [string]

TempPath identifies the temporary path used during creation. The temporary
file is removed before processing continues to the next archive.

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
  Get-DFeEventoEntry
  Get-FileSha256
  Publish-DFeArchive
#>
function New-DFeArchive {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions',
        '',
        Justification = 'ShouldProcess would add no value here.'
    )]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
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

    # Load every event once.
    $allEventos = [System.Collections.Generic.List[pscustomobject]]::new()

    foreach ($entry in $Entries) {
        $eventoParams = @{
            Cnpj        = $Cnpj
            ChavePai    = $entry.chave_acesso
            ErrorAction = 'Stop'
        }

        foreach ($evento in @(Get-DFeEventoEntry @eventoParams)) {
            $allEventos.Add($evento)
        }
    }

    # Map persistence DTOs into the IO contract expected by the compressor.
    $eventosMapped = @(
        $allEventos |
            ForEach-Object {
                [PSCustomObject]@{
                    ChavePai = $_.chave_pai
                    FilePath = $_.file_path
                    Sha256   = $_.sha256
                }
            }
    )

    foreach ($archiveInfo in $ArchiveInfos) {
        try {
            # TipoDFe must correspond to a ModeloDFe enum member.
            try {
                $modelValue = [int][System.Enum]::Parse(
                    [ModeloDFe],
                    $archiveInfo.TipoDFe,
                    $false
                )
            } catch {
                throw [System.Management.Automation.ErrorRecord]::new(
                    [System.InvalidOperationException]::new(
                        "[$Cnpj] Archive type '$($archiveInfo.TipoDFe)' is not defined in ModeloDFe.",
                        $_.Exception
                    ),
                    'ArchiveModelUnsupported',
                    [System.Management.Automation.ErrorCategory]::InvalidData,
                    $archiveInfo.TipoDFe
                )
            }

            # Select and map only documents belonging to this archive.
            $groupEntries = @(
                $Entries |
                    Where-Object { $_.modelo -eq $modelValue } |
                    ForEach-Object {
                        [PSCustomObject]@{
                            ChaveAcesso = $_.chave_acesso
                            Modelo      = $_.modelo
                            FilePath    = $_.file_path
                            Sha256      = $_.sha256
                        }
                    }
            )

            # Build a lookup so only events belonging to documents in this
            # archive are passed to Compress-DFeArchive.
            $groupKeys = [System.Collections.Generic.HashSet[string]]::new(
                [System.StringComparer]::Ordinal
            )

            foreach ($entry in $groupEntries) {
                $null = $groupKeys.Add($entry.ChaveAcesso)
            }

            $groupEventos = @(
                $eventosMapped |
                    Where-Object { $groupKeys.Contains($_.ChavePai) }
            )

            $compressParams = @{
                XmlPath     = $Company.XmlPath
                Entries     = $groupEntries
                Eventos     = $groupEventos
                ZipPath     = $archiveInfo.TempPath
                ErrorAction = 'Stop'
            }

            Compress-DFeArchive @compressParams

            # Compress-DFeArchive completing without throwing is not enough:
            # its output artifact must actually exist.
            if (-not (Test-Path -LiteralPath $archiveInfo.TempPath -PathType Leaf)) {
                throw [System.Management.Automation.ErrorRecord]::new(
                    [System.IO.FileNotFoundException]::new(
                        "[$Cnpj] Compress-DFeArchive completed but the ZIP " +
                        "was not created: '$($archiveInfo.TempPath)'."
                    ),
                    'ZipNotCreated',
                    [System.Management.Automation.ErrorCategory]::ResourceUnavailable,
                    $archiveInfo.TempPath
                )
            }

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
            # TempPath is never retained after an archive attempt.
            if (Test-Path -LiteralPath $archiveInfo.TempPath -PathType Leaf) {
                $removeParams = @{
                    LiteralPath = $archiveInfo.TempPath
                    Force       = $true
                    ErrorAction = 'SilentlyContinue'
                }

                Remove-Item @removeParams
            }
        }
    }
}
