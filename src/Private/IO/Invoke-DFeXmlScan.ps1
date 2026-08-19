<#
.SYNOPSIS
Scans a directory recursively and indexes all DFe XML files found.

.DESCRIPTION
Walks XmlPath recursively, collecting every .xml file regardless of
folder structure. For each file it computes a SHA-256 hash, parses the
XML content, classifies the document type and persists the result to the
CNPJ index via the appropriate Save-DFe*Entry function.

Files that are already indexed with the same SHA-256 hash are skipped.
Files whose content cannot be parsed or classified are silently ignored
and do not interrupt the scan.

The XML content is the only source of truth. File names and folder
structure are never used to determine document type or period.

.PARAMETER Cnpj
14-digit normalized CNPJ identifying the target company index.

.PARAMETER XmlPath
Root directory to scan recursively for .xml files.

.OUTPUTS
None.

.EXAMPLE
PS C:\> Invoke-DFeXmlScan -Cnpj '12345678000199' -XmlPath 'D:\ERP\NF-e'

.NOTES
Private dependencies:
  Get-FileSha256
  Get-DFeXmlMetadata
  Save-DFeDocumentEntry
  Save-DFeEventoEntry
  Save-DFeInutilizacaoEntry
  Initialize-DFeIndex
#>
function Invoke-DFeXmlScan {
    [CmdletBinding()]
    [OutputType([void])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [ValidatePattern('^\d{14}$')]
        [string]$Cnpj,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$XmlPath
    )

    process {
        if (-not (Test-Path -LiteralPath $XmlPath -PathType Container)) {
            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.IO.DirectoryNotFoundException]::new(
                        "Directory not found: '$XmlPath'."
                    ),
                    'XmlPathNotFound',
                    [System.Management.Automation.ErrorCategory]::ObjectNotFound,
                    $XmlPath
                )
            )
        }

        $getChildParams = @{
            LiteralPath = $XmlPath
            Filter      = '*.xml'
            Recurse     = $true
            File        = $true
            ErrorAction = 'SilentlyContinue'
        }

        $files = @(Get-ChildItem @getChildParams)

        Write-Verbose -Message "[$Cnpj] Scan started - $($files.Count) XML file(s) found in '$XmlPath'."

        foreach ($file in $files) {
            Write-Verbose -Message "[$Cnpj] Processing '$($file.FullName)'."

            try {
                $sha256   = Get-FileSha256 -Path $file.FullName
                $metadata = Get-DFeXmlMetadata -Path $file.FullName

                if ($null -eq $metadata) {
                    Write-Verbose -Message "[$Cnpj] Skipped '$($file.Name)' - unrecognized document type."
                    continue
                }

                $metadata | Add-Member -NotePropertyName 'Sha256' -NotePropertyValue $sha256 -Force

                $saveParams = @{
                    Cnpj     = $Cnpj
                    Metadata = $metadata
                }

                switch ($metadata.Tipo) {
                    ([TipoXmlDFe]::Documento) {
                        Save-DFeDocumentEntry @saveParams
                    }
                    ([TipoXmlDFe]::Evento) {
                        Save-DFeEventoEntry @saveParams
                    }
                    ([TipoXmlDFe]::Inutilizacao) {
                        Save-DFeInutilizacaoEntry @saveParams
                    }
                }

                Write-Verbose -Message "[$Cnpj] Indexed '$($file.Name)' as $($metadata.Tipo)."
            } catch {
                Write-Verbose -Message "[$Cnpj] Ignored '$($file.Name)' - $($_.Exception.Message)."
                continue
            }
        }

        Write-Verbose -Message "[$Cnpj] Scan complete."
    }
}
