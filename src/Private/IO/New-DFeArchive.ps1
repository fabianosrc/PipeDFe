<#
.SYNOPSIS
Creates one ZIP archive per DFe document type.

.DESCRIPTION
Orchestrates archive creation for each pre-calculated archive info:

  1. Loads events from the index for all documents in the batch.
  2. Maps store snake_case entries to PascalCase IO objects.
  3. Preserves indexed SHA-256 values for source-integrity validation.
  4. Groups documents by the archive's DFe model.
  5. Creates the temporary ZIP via Compress-DFeArchive.
  6. Verifies that the temporary ZIP was created.
  7. Computes the temporary ZIP SHA-256.
  8. Copies the ZIP to its destination.

Source-integrity failures raised by Compress-DFeArchive are terminating and
are allowed to propagate unchanged.

Returns one result object per archive created.

.PARAMETER Cnpj
Normalized company CNPJ.

Used to query indexed events.

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
            $modelValue = [int][System.Enum]::Parse(
                [ModeloDFe],
                $archiveInfo.TipoDFe,
                $false
            )
        } catch {
            throw [System.Management.Automation.ErrorRecord]::new(
                [System.InvalidOperationException]::new(
                    (
                        "[$Cnpj] Archive type '$($archiveInfo.TipoDFe)' " +
                        'is not defined in ModeloDFe.'
                    ),
                    $_.Exception
                ),
                'ArchiveModelUnsupported',
                [System.Management.Automation.ErrorCategory]::InvalidData,
                $archiveInfo.TipoDFe
            )
        }

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

        $compressParams = @{
            XmlPath = $Company.XmlPath
            Entries = $groupEntries
            Eventos = $eventosMapped
            ZipPath = $archiveInfo.TempPath
        }

        Compress-DFeArchive @compressParams

        if (-not (Test-Path -LiteralPath $archiveInfo.TempPath -PathType Leaf)) {
            throw [System.Management.Automation.ErrorRecord]::new(
                [System.IO.FileNotFoundException]::new(
                    (
                        "[$Cnpj] Compress-DFeArchive completed but the ZIP " +
                        "was not created: '$($archiveInfo.TempPath)'."
                    )
                ),
                'ZipNotCreated',
                [System.Management.Automation.ErrorCategory]::ResourceUnavailable,
                $archiveInfo.TempPath
            )
        }

        $zipHash = Get-FileSha256 -Path $archiveInfo.TempPath

        $copyParams = @{
            LiteralPath = $archiveInfo.TempPath
            Destination = $archiveInfo.DestPath
            Force       = $true
            ErrorAction = 'Stop'
        }

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
