<#
.SYNOPSIS
Creates one ZIP archive per DFe document type.

.DESCRIPTION
Orchestrates archive creation for each pre-calculated archive info:

  1. Loads eventos from the index for all documents in the group.
  2. Maps snake_case index entries to PascalCase objects for the IO layer.
  3. Compresses matching entries to a temporary ZIP via Compress-DFeArchive.
  4. Validates the ZIP was created and throws ZipNotCreated when absent.
  5. Computes SHA-256 of the temporary ZIP.
  6. Copies the temporary ZIP to the destination path.

Returns one result object per archive created.

.PARAMETER Cnpj
Empresa CNPJ. Used to query eventos from the index.

.PARAMETER Company
Empresa object exposing XmlPath and OutputPath.

.PARAMETER Entries
Document index entries as returned by Get-DFeDocumentEntry.

.PARAMETER ArchiveInfos
Pre-calculated archive metadata from Resolve-DFeArchiveInfo, one per
document type. Each object must expose TipoDFe, FileName, TempPath
and DestPath.

.OUTPUTS
System.Management.Automation.PSCustomObject

  TipoDFe  [string] - Document type label matching ModeloDFe enum name.
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

    # Load all eventos for the documents in this batch.
    # Eventos are embedded inside their parent document's subfolder in the ZIP.
    $allEventos = [System.Collections.Generic.List[pscustomobject]]::new()

    foreach ($entry in $Entries) {
        $eventoParams = @{
            Cnpj        = $Cnpj
            ChavePai    = $entry.chave_acesso
            ErrorAction = 'SilentlyContinue'
        }

        foreach ($evento in @(Get-DFeEventoEntry @eventoParams)) {
            $allEventos.Add($evento)
        }
    }

    # Map snake_case index entries to PascalCase for the IO layer.
    # Store uses snake_case (database contract).
    # IO uses PascalCase (PowerShell/.NET contract).
    $eventosMapped = @(
        $allEventos | ForEach-Object {
            [PSCustomObject]@{
                ChavePai = $_.chave_pai
                FilePath = $_.file_path
            }
        }
    )

    foreach ($archiveInfo in $ArchiveInfos) {
        $modelValue = [int][System.Enum]::Parse([ModeloDFe], $archiveInfo.TipoDFe)

        $groupEntries = @(
            $Entries | Where-Object { $_.modelo -eq $modelValue } |
                ForEach-Object {
                    [PSCustomObject]@{
                        ChaveAcesso = $_.chave_acesso
                        Modelo      = $_.modelo
                        FilePath    = $_.file_path
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

        $zipHash = Get-FileSha256 -Path $archiveInfo.TempPath

        $copyParams = @{
            LiteralPath = $archiveInfo.TempPath
            Destination = $archiveInfo.DestPath
            Force       = $true
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
