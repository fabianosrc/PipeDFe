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

Each missing number is classified as:
  Faltante    - not found in the index and not covered by any CoveredRanges entry.
  Inutilizada - covered by an entry in CoveredRanges (nnf_ini <= n <= nnf_fin).

Contiguous missing numbers of the same Tipo, Especie and Serie are merged
into a single output object.

CoveredRanges entries are indexed by modelo and serie before the main loop,
so the coverage check for each missing number iterates only over the ranges
relevant to that group and stops at the first match.

Sorting is O(n log n). Gap detection and range merging are O(n + m), where
n is the number of observed documents and m is the number of missing numbers.
Coverage lookup per missing number is O(k), where k is the number of
CoveredRanges entries for the same modelo and serie.

Returns one object per contiguous range of the same Tipo. Returns no pipeline
output when no gaps are detected.

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

CoveredRanges entries with null or incomplete fields are silently skipped.

.PARAMETER Entries
Document entries as returned by Get-DFeDocumentEntry.

Must not be null. An empty collection is valid.

Entries with null ndoc or null, empty, or whitespace-only serie are ignored.

.PARAMETER CoveredRanges
Optional inutilizacao entries as returned by Get-DFeInutilizacaoEntry.

Each entry must expose modelo, serie, nnf_ini and nnf_fin.

Entries with null or incomplete fields are silently skipped.

When omitted or empty, all missing numbers are classified as Faltante.

.OUTPUTS
System.Management.Automation.PSCustomObject

Each emitted object represents one contiguous range of the same Tipo and contains:

  Tipo    [string] - 'Faltante' or 'Inutilizada'.
  Especie [string] - Document type label, such as 'NFe' or 'CTe'.
  Serie   [string] - Document serie.
  Inicial [int]    - First number in the range.
  Final   [int]    - Last number in the range.

No output is emitted when no gaps are detected.

.EXAMPLE
PS C:\> $gaps = @(Get-DFeSequenceGap -Entries $entries)

Returns all detected sequence gaps classified as Faltante.

.EXAMPLE
PS C:\> $inut = @(Get-DFeInutilizacaoEntry -Cnpj $cnpj)
PS C:\> $gaps = @(Get-DFeSequenceGap -Entries $entries -CoveredRanges $inut)

Returns gaps classified as Faltante or Inutilizada.

.EXAMPLE
PS C:\> Get-DFeSequenceGap -Entries $entries -CoveredRanges $inut |
>> Format-Table Tipo, Especie, Serie, Inicial, Final

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
        [pscustomobject[]]$Entries,

        [Parameter()]
        [AllowEmptyCollection()]
        [pscustomobject[]]$CoveredRanges = @()
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
                $null -ne $_.ndoc -and
                $null -ne $_.serie -and -not
                [string]::IsNullOrWhiteSpace([string]$_.serie) -and
                $sequenceModels.Contains([int]$_.modelo)
            }
    )

    if ($filteredEntries.Count -eq 0) {
        return
    }

    # Index CoveredRanges by modelo_serie for O(k) lookup per group,
    # avoiding a full scan of CoveredRanges for every missing number.
    # Entries with null or incomplete fields are silently skipped.
    $rangesByGroup = @{}

    foreach ($range in $CoveredRanges) {
        if (
            $null -eq $range.modelo -or
            $null -eq $range.serie  -or
            [string]::IsNullOrWhiteSpace([string]$range.serie) -or
            $null -eq $range.nnf_ini -or
            $null -eq $range.nnf_fin
        ) {
            continue
        }

        $key = '{0}_{1}' -f [int]$range.modelo, [string]$range.serie

        if (-not $rangesByGroup.ContainsKey($key)) {
            $rangesByGroup[$key] = [System.Collections.Generic.List[pscustomobject]]::new()
        }

        $rangesByGroup[$key].Add($range)
    }

    $groups = @(
        $filteredEntries |
            Group-Object {
                '{0}_{1}' -f $_.modelo, $_.serie
            }
    )

    foreach ($group in $groups) {
        $firstEntry = $group.Group[0]

        $modelo   = [int]$firstEntry.modelo
        $especie  = ([ModeloDFe]$modelo).ToString()
        $serie    = [string]$firstEntry.serie
        $groupKey = $group.Name

        $numbers = @(
            $group.Group |
                ForEach-Object { [int]$_.ndoc } |
                Sort-Object -Unique
        )

        $ranges = if ($rangesByGroup.ContainsKey($groupKey)) {
            $rangesByGroup[$groupKey]
        } else {
            @()
        }

        $rangeInicial = $null
        $rangeFinal   = $null
        $rangeTipo    = $null

        for ($i = 1; $i -lt $numbers.Count; $i++) {
            $previous = $numbers[$i - 1]
            $current  = $numbers[$i]

            for ($n = $previous + 1; $n -lt $current; $n++) {
                $isCovered = $false

                foreach ($range in $ranges) {
                    if ([int]$range.nnf_ini -le $n -and [int]$range.nnf_fin -ge $n) {
                        $isCovered = $true
                        break
                    }
                }

                $tipo = if ($isCovered) { 'Inutilizada' } else { 'Faltante' }

                # Open the first range.
                if ($null -eq $rangeTipo) {
                    $rangeInicial = $n
                    $rangeFinal   = $n
                    $rangeTipo    = $tipo
                    continue
                }

                $isContiguous = $n -eq ($rangeFinal + 1)
                $isSameTipo   = $tipo -eq $rangeTipo

                if ($isContiguous -and $isSameTipo) {
                    $rangeFinal = $n
                    continue
                }

                # Close the current range and open a new one.
                [PSCustomObject]@{
                    Tipo    = [string]$rangeTipo
                    Especie = [string]$especie
                    Serie   = [string]$serie
                    Inicial = [int]$rangeInicial
                    Final   = [int]$rangeFinal
                }

                $rangeInicial = $n
                $rangeFinal   = $n
                $rangeTipo    = $tipo
            }
        }

        # Close the last range.
        if ($null -ne $rangeTipo) {
            [PSCustomObject]@{
                Tipo    = [string]$rangeTipo
                Especie = [string]$especie
                Serie   = [string]$serie
                Inicial = [int]$rangeInicial
                Final   = [int]$rangeFinal
            }
        }
    }
}
