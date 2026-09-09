<#
.SYNOPSIS
Detects sequence gaps in DFe document series for a given company and period.

.DESCRIPTION
Queries the DFe index for the specified company and period, then identifies
missing document numbers (ndoc) within each serie and modelo combination.

Gaps represent document numbers that were not found in the DFe index for the
requested period. They may indicate unreported cancellations, inutilizations,
or missing XMLs and should not be interpreted as proof that a document was
actually issued.

Only models with emitente-controlled numbering are analyzed:
  NF-e (55), NFC-e (65), NFCom (62), CT-e (57), MDF-e (58).

NFS-e is excluded because its numbering is controlled by the service
municipality or other external authority.

When -StartDate and -EndDate are omitted, the previous full calendar month
is used. -StartDate and -EndDate follow the same resolution rules as
Invoke-PipeDFe: both are optional, but -EndDate requires -StartDate.

Returns no pipeline objects when no gaps are detected. An empty result is
not an error.

.PARAMETER Cnpj
Company CNPJ. Accepts formatted (XX.XXX.XXX/XXXX-XX) or digits-only input.

.PARAMETER StartDate
Optional start of the period filter. Accepts any format supported by
ConvertTo-DateTimeOffset. Requires -EndDate when supplied.

.PARAMETER EndDate
Optional end of the period filter. Accepts any format supported by
ConvertTo-DateTimeOffset. Requires -StartDate when supplied.

.OUTPUTS
System.Management.Automation.PSCustomObject

One object per contiguous gap range:
  Especie [string] - Document type label (e.g. 'NFe', 'CTe').
  Serie   [string] - Document serie.
  Inicial [int]    - First missing document number in the range.
  Final   [int]    - Last missing document number in the range.

.EXAMPLE
PS C:\> Get-PipeDFeSequenceGap -Cnpj '12345678000195'

.EXAMPLE
PS C:\> Get-PipeDFeSequenceGap -Cnpj '12.345.678/0001-95'
>>     -StartDate '01/08/2026' -EndDate '31/08/2026'

.NOTES
Private dependencies:
  ConvertTo-NormalizedCnpj
  Resolve-DateRange
  Get-DFeDocumentEntry
  Get-DFeSequenceGap
#>
function Get-PipeDFeSequenceGap {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory)]
        [string]$Cnpj,

        [Parameter()]
        [string]$StartDate,

        [Parameter()]
        [string]$EndDate
    )

    $cnpjNormalized = ConvertTo-NormalizedCnpj -Value $Cnpj
    $resolveParams  = @{}

    if (-not [string]::IsNullOrWhiteSpace($StartDate)) {
        $resolveParams['StartDate'] = $StartDate
    }

    if (-not [string]::IsNullOrWhiteSpace($EndDate)) {
        $resolveParams['EndDate'] = $EndDate
    }

    $dateRange = Resolve-DateRange @resolveParams

    $entryParams = @{
        Cnpj      = $cnpjNormalized
        StartDate = $dateRange.Start.ToString('o')
        EndDate   = $dateRange.End.ToString('o')
    }

    $entries = @(Get-DFeDocumentEntry @entryParams)

    if ($entries.Count -eq 0) {
        return
    }

    Get-DFeSequenceGap -Entries $entries
}
