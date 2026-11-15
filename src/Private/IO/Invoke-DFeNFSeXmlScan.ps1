<#
.SYNOPSIS
Imports NFS-e Nacional XML files from one company's configured directory.

.DESCRIPTION
Recursively scans XML files and persists generated national NFS-e documents.
Other well-formed XML roots are ignored. Malformed XML, invalid national
documents, source changes, and storage failures stop the scan. Previously
imported rows remain committed. Unchanged documents are handled by the store.

.PARAMETER Cnpj
Company whose SQLite index receives the fiscal projections.

.PARAMETER XmlPath
Directory containing the NFS-e XML files.

.OUTPUTS
PSCustomObject with FilesFound, FilesImported and FilesIgnored counts.
FilesImported counts successful imports, including unchanged documents.
#>
function Invoke-DFeNFSeXmlScan {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory)]
        [ValidatePattern('^(?-i)[A-Z0-9]{14}$')]
        [string]$Cnpj,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$XmlPath
    )

    $getChildParams = @{
        LiteralPath = $XmlPath
        Filter      = '*.xml'
        File        = $true
        Recurse     = $true
        ErrorAction = 'Stop'
    }

    if (-not (Test-Path -LiteralPath $XmlPath -PathType Container)) {
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                [System.IO.DirectoryNotFoundException]::new(
                    "NFS-e XML directory not found: '$XmlPath'."
                ),
                'NFSeXmlPathNotFound',
                [System.Management.Automation.ErrorCategory]::ObjectNotFound,
                $XmlPath
            )
        )
    }

    $script:NFSeNamespace = 'http://www.sped.fazenda.gov.br/nfse'

    $files      = @(Get-ChildItem @getChildParams | Sort-Object -Property FullName)
    $imported   = 0
    $ignored    = 0
    $seenHashes = @{}

    foreach ($file in $files) {
        $path = $file.FullName

        Write-Verbose -Message "[$Cnpj] Reading NFS-e XML candidate '$path'."

        $sourceHash = Get-FileSha256 -Path $path
        $xml        = Import-DFeXml -Path $path
        $root       = $xml.DocumentElement

        if ($null -eq $root -or $root.LocalName -cne 'NFSe' -or
            $root.NamespaceURI -cne $script:NFSeNamespace
        ) {
            $ignored++
            continue
        }

        $fiscalData = Get-DFeNFSeFiscalData -Xml $xml

        if ((Get-FileSha256 -Path $path) -ine $sourceHash) {
            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.IO.InvalidDataException]::new(
                        "NFS-e XML changed during import: '$path'."
                    ),
                    'NFSeSourceChangedDuringImport',
                    [System.Management.Automation.ErrorCategory]::InvalidData,
                    $path
                )
            )
        }

        $key = $fiscalData.ChaveAcesso
        if ($seenHashes.ContainsKey($key)) {
            if ($seenHashes[$key] -ine $sourceHash) {
                $PSCmdlet.ThrowTerminatingError(
                    [System.Management.Automation.ErrorRecord]::new(
                        [System.IO.InvalidDataException]::new(
                            "Conflicting XML files for NFS-e '$key': '$path'."
                        ),
                        'NFSeConflictingSource',
                        [System.Management.Automation.ErrorCategory]::InvalidData,
                        $path
                    )
                )
            }

            $ignored++
            continue
        }

        $saveParams = @{
            Cnpj         = $Cnpj
            FiscalData   = $fiscalData
            SourcePath   = $path
            SourceSha256 = $sourceHash
        }

        Save-DFeNFSeFiscalData @saveParams
        $seenHashes[$key] = $sourceHash
        $imported++
    }

    [pscustomobject]@{
        FilesFound    = $files.Count
        FilesImported = $imported
        FilesIgnored  = $ignored
    }
}
