<#
.SYNOPSIS
Resolves ZIP archive metadata for a specific DFe document type.

.DESCRIPTION
Generates a standardized ZIP file name from document type, CNPJ, company
label (NomeFantasia preferred, RazaoSocial as fallback), and period label.
Name format: {TipoDFe}_{CNPJ}_{Label}_{PeriodLabel}.zip

The company label is derived from the first two words of the source name
that contain at least one alphanumeric character. Tokens consisting
entirely of non-alphanumeric characters (e.g. '&', '-') are discarded
before the two-word limit is applied, ensuring the label is always
meaningful.

Returns an object with TipoDFe, FileName, TempPath and DestPath so callers
never construct paths independently or re-derive the document type from the
file name.

.PARAMETER TipoDFe
Document type prefix for the ZIP name (e.g. 'NFe', 'CTe', 'MDFe').

.PARAMETER Cnpj
Empresa CNPJ.

.PARAMETER Company
Empresa object with NomeFantasia, RazaoSocial and OutputPath.

.PARAMETER DateRange
PSCustomObject with Start and End [DateTimeOffset] used for period label.

.OUTPUTS
System.Management.Automation.PSCustomObject

TipoDFe  [string] Document type label (e.g. 'NFe', 'CTe', 'MDFe').
FileName [string] ZIP file name.
TempPath [string] Full path to the temporary ZIP location.
DestPath [string] Full path to the destination in Company.OutputPath.

.EXAMPLE
PS C:\> $info = Resolve-DFeArchiveInfo -TipoDFe 'NFe'
>> -Cnpj $cnpj -Company $company -DateRange $range

>> $info.FileName
Returns NFe_11222333000181_RIBEIRO_BONAFE_202606.zip

.NOTES
Pure function - no I/O, no side effects.

Private dependencies:
  ConvertTo-SafeString
  Get-ArchivePeriodSegment
#>
function Resolve-DFeArchiveInfo {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$TipoDFe,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Cnpj,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject]$Company,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject]$DateRange
    )

    # Validate required Company properties up front so every failure produces
    # a clear terminating error rather than a silent null or malformed path.
    foreach ($propertyName in @('NomeFantasia', 'RazaoSocial', 'OutputPath')) {
        $property = $Company.PSObject.Properties[$propertyName]

        if ($null -eq $property) {
            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.ArgumentException]::new(
                        "Company is missing the required '$propertyName' property."
                    ),
                    "CompanyMissing$propertyName",
                    [System.Management.Automation.ErrorCategory]::InvalidArgument,
                    $Company
                )
            )
        }
    }

    if ([string]::IsNullOrWhiteSpace($Company.OutputPath)) {
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                [System.ArgumentException]::new(
                    'Company.OutputPath must not be null or empty.'
                ),
                'CompanyOutputPathNullOrEmpty',
                [System.Management.Automation.ErrorCategory]::InvalidArgument,
                $Company
            )
        )
    }

    $sourceName = if (-not [string]::IsNullOrWhiteSpace($Company.NomeFantasia)) {
        $Company.NomeFantasia
    } else {
        $Company.RazaoSocial
    }

    if ([string]::IsNullOrWhiteSpace($sourceName)) {
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                [System.ArgumentException]::new(
                    'Company must have a non-empty NomeFantasia or RazaoSocial.'
                ),
                'CompanyNameNullOrEmpty',
                [System.Management.Automation.ErrorCategory]::InvalidArgument,
                $Company
            )
        )
    }

    # Split into words, discard tokens with no alphanumeric characters
    # (e.g. '&', '-'), then take the first two meaningful words.
    $safeParams = @{
        InputObject = $sourceName
        UpperCase   = $true
        AsciiOnly   = $true
        Separator   = ' '
    }

    $labelWords = (ConvertTo-SafeString @safeParams) -split '\s+' |
        Where-Object { $_ -match '[A-Z0-9]' } |
        Select-Object -First 2

    $periodSegment = Get-ArchivePeriodSegment -DateRange $DateRange
    $companyLabel  = $labelWords -join '_'
    $fileName      = '{0}_{1}_{2}_{3}.zip' -f $TipoDFe, $Cnpj, $companyLabel, $periodSegment

    $tempPathParams = @{
        Path      = [System.IO.Path]::GetTempPath()
        ChildPath = $fileName
    }

    $destPathParams = @{
        Path      = $Company.OutputPath
        ChildPath = $fileName
    }

    [PSCustomObject]@{
        TipoDFe  = $TipoDFe
        FileName = $fileName
        TempPath = Join-Path @tempPathParams
        DestPath = Join-Path @destPathParams
    }
}
