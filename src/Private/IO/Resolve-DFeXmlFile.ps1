<#
.SYNOPSIS
Classifies DFe XML files into Documents, Events, Inutilizacoes and Unresolved.

.DESCRIPTION
Reads XML metadata exclusively through Get-DFeXmlMetadata and classifies each
candidate according to the metadata returned by that function.

Documents are deduplicated by Chave using case-insensitive comparison.
When both an unprocessed and processed version of the same document exist,
the processed version (IsProc = $true) is preferred.

Document output preserves the order in which each unique Chave was first
encountered. If a processed version replaces an unprocessed version, it
retains the original position.

The XML content is the only source of truth. File names are never used for
classification.

Files that cannot be parsed, classified, or do not contain the metadata
required for their classification are returned through Unresolved.

.PARAMETER Candidates
One or more XML files to classify.

.OUTPUTS
System.Management.Automation.PSCustomObject

Properties:
  Documents
    Deduplicated document metadata. Processed versions are preferred.

  Events
    Event metadata, one entry per file.

  Inutilizacoes
    Inutilizacao metadata, one entry per file.

  Unresolved
    FileInfo objects that could not be parsed or classified.

.EXAMPLE
PS C:\> $files = Get-ChildItem -Path 'D:\ERP\xml' -Filter '*.xml' -Recurse
>> $result = Resolve-DFeXmlFile -Candidates $files
>> $result.Documents | ForEach-Object { $_.Chave }

.NOTES
Private dependencies:
  Get-DFeXmlMetadata
  TipoXmlDFe
#>
function Resolve-DFeXmlFile {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [System.IO.FileInfo[]]$Candidates
    )

    # Maps Chave -> position in $documents.
    # This allows case-insensitive deduplication while preserving input order.
    $documentIndexes = [System.Collections.Generic.Dictionary[string, int]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )

    $documents     = [System.Collections.Generic.List[object]]::new()
    $events        = [System.Collections.Generic.List[object]]::new()
    $inutilizacoes = [System.Collections.Generic.List[object]]::new()
    $unresolved    = [System.Collections.Generic.List[System.IO.FileInfo]]::new()

    foreach ($file in $Candidates) {
        if ($null -eq $file) {
            continue
        }

        Write-Verbose -Message "Classifying '$($file.FullName)'"

        $metadata = $null

        try {
            $metadata = Get-DFeXmlMetadata -Path $file.FullName -ErrorAction Stop
        } catch {
            Write-Verbose -Message (
                "Unable to read metadata from '{0}': {1}" -f
                $file.FullName,
                $_.Exception.Message
            )

            $unresolved.Add($file)
            continue
        }

        # A classifier expects exactly one metadata object per file.
        if ($null -eq $metadata -or $metadata -is [System.Array]) {
            Write-Verbose -Message (
                "Invalid metadata result for '{0}'" -f $file.FullName
            )

            $unresolved.Add($file)
            continue
        }

        $tipoProperty = $metadata.PSObject.Properties['Tipo']

        if ($null -eq $tipoProperty -or $null -eq $metadata.Tipo) {
            Write-Verbose -Message (
                "Metadata type is missing for '{0}'" -f $file.FullName
            )

            $unresolved.Add($file)
            continue
        }

        # Get-DFeXmlMetadata is expected to expose the strongly typed enum.
        if ($metadata.Tipo -isnot [TipoXmlDFe]) {
            Write-Verbose -Message (
                "Invalid metadata type '{0}' for '{1}'" -f
                $metadata.Tipo, $file.FullName
            )

            $unresolved.Add($file)
            continue
        }

        switch ($metadata.Tipo) {

            ([TipoXmlDFe]::Documento) {
                $chaveProperty  = $metadata.PSObject.Properties['Chave']
                $isProcProperty = $metadata.PSObject.Properties['IsProc']

                if ($null -eq $chaveProperty -or
                    [string]::IsNullOrWhiteSpace([string]$metadata.Chave)
                ) {
                    Write-Verbose -Message ("Document key is missing for '{0}'" -f $file.FullName)

                    $unresolved.Add($file)
                    continue
                }

                if ($null -eq $isProcProperty -or $metadata.IsProc -isnot [bool]) {
                    Write-Verbose -Message ("Invalid IsProc metadata for '{0}'" -f $file.FullName)

                    $unresolved.Add($file)
                    continue
                }

                $chave = [string]$metadata.Chave

                $existingIndex = 0

                if ($documentIndexes.TryGetValue($chave, [ref]$existingIndex)) {
                    $current = $documents[$existingIndex]

                    # A processed document always wins over an unprocessed one.
                    # If both have the same processing state, the first one wins.
                    if ($metadata.IsProc -and -not $current.IsProc) {
                        $documents[$existingIndex] = $metadata

                        Write-Verbose -Message ("Processed document selected for key '{0}'" -f $chave)
                    }
                } else {
                    $documentIndexes.Add($chave, $documents.Count)
                    $documents.Add($metadata)
                }

                continue
            }

            ([TipoXmlDFe]::Evento) {
                $events.Add($metadata)
                continue
            }

            ([TipoXmlDFe]::Inutilizacao) {
                $inutilizacoes.Add($metadata)
                continue
            }

            default {
                Write-Verbose -Message (
                    "Unsupported XML type '{0}' for '{1}'" -f
                    $metadata.Tipo, $file.FullName
                )

                $unresolved.Add($file)
                continue
            }
        }
    }

    [PSCustomObject]@{
        Documents     = @($documents)
        Events        = @($events)
        Inutilizacoes = @($inutilizacoes)
        Unresolved    = @($unresolved)
    }
}
