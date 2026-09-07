<#
.SYNOPSIS
Detects sequence gaps in emitente-controlled DFe document series

.DESCRIPTION
Analyzes document entries grouped by modelo and serie. For each group,
identifies missing ndoc values by walking the sorted sequence and comparing
each value with its predecessor.

A gap exists when the difference between two consecutive observed ndoc values
is greater than one. Only missing values between observed documents are
reported. Numbers before the first observed document are not considered gaps.

The function does not iterate over the min..max range. Sorting is O(n log n)
and gap detection is O(n).

Returns one object per contiguous missing range. Returns no pipeline output
when no gaps are detected.

Supported models whose document numbering is controlled by the emitente:
  NF-e   (55)
  NFC-e  (65)
  NFCom  (62)
  CT-e   (57)
  MDF-e  (58)

Excluded models:
  NFS-e  (67)  - numbering is not controlled by the emitente.
  Evento       - events are not subject to document sequence gap analysis.
  Other models - not supported by this function.

Entries with null ndoc or null, empty, or whitespace-only serie are ignored.

Duplicate ndoc values within the same modelo and serie do not create gaps.

.PARAMETER Entries
Document entries as returned by Get-DFeDocumentEntry.

Must not be null. An empty collection is valid.

Entries with null ndoc or null, empty, or whitespace-only serie are ignored.

.OUTPUTS
System.Management.Automation.PSCustomObject

Each emitted object represents one contiguous gap range and contains:

  Especie [string] - Document type label, such as 'NFe' or 'CTe'.
  Serie   [string] - Document serie.
  Inicial [int]    - First missing ndoc in the range.
  Final   [int]    - Last missing ndoc in the range.

No output is emitted when no gaps are detected.

.EXAMPLE
PS C:\> $gaps = @(Get-DFeSequenceGap -Entries $entries)

Returns all detected sequence gaps.

.EXAMPLE
PS C:\> Get-DFeSequenceGap -Entries $entries |
>> Format-Table Especie, Serie, Inicial, Final

Displays detected gaps in tabular form.

.NOTES
Pure function with no I/O or side effects.
Depends on the ModeloDFe enum.
#>
function Get-DFeSequenceGap {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [AllowEmptyCollection()]
        [pscustomobject[]]$Entries
    )

    # These are the DFe models whose document numbering is controlled by the
    # emitente and is therefore meaningful for sequence gap analysis.
    $sequenceModels = [System.Collections.Generic.HashSet[int]]::new(
        [int[]]@(
            [int][ModeloDFe]::NFe,
            [int][ModeloDFe]::NFCe,
            [int][ModeloDFe]::NFCom,
            [int][ModeloDFe]::CTe,
            [int][ModeloDFe]::MDFe
        ),
        [System.Collections.Generic.EqualityComparer[int]]::Default
    )

    $filteredEntries = @(
        $Entries |
            Where-Object {
                $null -ne $_.ndoc -and $null -ne $_.serie -and
                -not [string]::IsNullOrWhiteSpace([string]$_.serie) -and
                $sequenceModels.Contains([int]$_.modelo)
            }
    )

    if ($filteredEntries.Count -eq 0) {
        return
    }

    $groups = @(
        $filteredEntries |
            Group-Object {
                '{0}_{1}' -f $_.modelo, $_.serie
            }
    )

    foreach ($group in $groups) {
        $firstEntry = $group.Group[0]

        $modelo  = [int]$firstEntry.modelo
        $especie = ([ModeloDFe]$modelo).ToString()
        $serie   = [string]$firstEntry.serie

        $numbers = @(
            $group.Group |
                ForEach-Object { [int]$_.ndoc } |
                Sort-Object
        )

        for ($i = 1; $i -lt $numbers.Count; $i++) {
            $previous = $numbers[$i - 1]
            $current  = $numbers[$i]

            if ($current -gt ($previous + 1)) {
                [PSCustomObject]@{
                    Especie = [string]$especie
                    Serie   = [string]$serie
                    Inicial = [int]($previous + 1)
                    Final   = [int]($current - 1)
                }
            }
        }
    }
}
