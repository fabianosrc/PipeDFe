<#
.SYNOPSIS
Scans a directory recursively and indexes all DFe XML files found.

.DESCRIPTION
Walks XmlPath recursively, collecting every .xml file regardless of
folder structure. For each file it computes a SHA-256 hash, parses the
XML content, classifies the document type and persists the result to the
CNPJ index via the appropriate Save-DFe*Entry function.

Before scanning, all SHA-256 hashes already present in the index are
loaded into a HashSet via Get-DFeIndexedHash. Files whose hash is
already known are skipped immediately without opening the file content,
making subsequent executions significantly faster on large directories.

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
PS C:\> Invoke-DFeXmlScan -Cnpj '12345678000199' -XmlPath 'C:\ERP\NF-e'

.NOTES
Private dependencies:
  Get-DFeIndexedHash
  Get-FileSha256
  Get-DFeXmlMetadata
  Save-DFeDocumentEntry
  Save-DFeEventoEntry
  Save-DFeInutilizacaoEntry
#>
function Invoke-DFeXmlScan {
    [CmdletBinding()]
    [OutputType([void])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [ValidatePattern('^[A-Z0-9]{14}$')]
        [string]$Cnpj,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$XmlPath
    )

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

    # Load all hashes already indexed into a HashSet for O(1) lookups.
    # A single UNION query across the three tables via Get-DFeIndexedHash
    # prevents already indexed files from being processed again.
    $knownHashes = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )

    Get-DFeIndexedHash -Cnpj $Cnpj -ErrorAction SilentlyContinue |
        ForEach-Object { $null = $knownHashes.Add($_) }

    Write-Verbose -Message "[$Cnpj] $($knownHashes.Count) indexed hash(es) loaded."

    # Scan XML files.
    $getChildParams = @{
        LiteralPath = $XmlPath
        Filter      = '*.xml'
        Recurse     = $true
        File        = $true
        ErrorAction = 'SilentlyContinue'
    }

    $files = @(Get-ChildItem @getChildParams)

    Write-Verbose -Message (
        "[$Cnpj] Scan started - $($files.Count) XML file(s) found in '$XmlPath'."
    )

    $skipped = 0
    $indexed = 0
    $ignored = 0

    foreach ($file in $files) {
        try {
            $sha256 = Get-FileSha256 -Path $file.FullName

            # Skip immediately when the file hash is already indexed.
            if ($knownHashes.Contains($sha256)) {
                $skipped++

                Write-Verbose -Message "[$Cnpj] Skipped (already indexed): '$($file.Name)'."
                continue
            }

            $metadata = Get-DFeXmlMetadata -Path $file.FullName

            if ($null -eq $metadata) {
                $ignored++

                Write-Verbose -Message "[$Cnpj] Skipped (unrecognized type): '$($file.Name)'."
                continue
            }

            $memberParams = @{
                NotePropertyName  = 'Sha256'
                NotePropertyValue = $sha256
                Force             = $true
            }

            $metadata | Add-Member @memberParams

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

            # Add the hash only after the corresponding entry was saved
            # successfully, preventing failed saves from being treated as
            # successfully indexed files during the current scan.
            $null = $knownHashes.Add($sha256)

            $indexed++

            Write-Verbose -Message "[$Cnpj] Indexed '$($file.Name)' as $($metadata.Tipo)."
        } catch {
            $ignored++

            Write-Verbose -Message "[$Cnpj] Skipped '$($file.Name)' - $($_.Exception.Message)."
            continue
        }
    }

    Write-Verbose -Message (
        "[$Cnpj] Scan completed - $indexed new, " +
        "$skipped already indexed, $ignored skipped."
    )
}
