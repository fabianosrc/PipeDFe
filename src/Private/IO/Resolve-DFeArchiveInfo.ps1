<#
.SYNOPSIS
Resolves ZIP archive metadata for a specific DFe document type.

.DESCRIPTION
Generates a standardized ZIP file name from document type, CNPJ, company
label (NomeFantasia preferred, RazaoSocial as fallback), and period label.

Name format:

    {TipoDFe}_{CNPJ}_{Label}_{PeriodLabel}.zip

The company label is derived from the first two words of the source name
that contain at least one alphanumeric character. Tokens consisting
entirely of non-alphanumeric characters are discarded before the two-word
limit is applied.

Returns TipoDFe, FileName, TempPath and DestPath so callers never construct
archive paths independently or re-derive the document type from FileName.

TempPath is unique per invocation to prevent stale temporary files or
parallel executions from referring to the same intermediate ZIP.

FileName and DestPath remain deterministic.

.PARAMETER TipoDFe
Document type prefix for the ZIP name.

.PARAMETER Cnpj
Normalized company CNPJ.

.PARAMETER Company
Company object exposing NomeFantasia, RazaoSocial and OutputPath.

.PARAMETER DateRange
Object exposing Start and End DateTimeOffset values used for the period
segment.

.OUTPUTS
System.Management.Automation.PSCustomObject

Properties:

    TipoDFe  [string]
    FileName [string]
    TempPath [string]
    DestPath [string]

.EXAMPLE
PS C:\> $params = @{
    TipoDFe   = 'NFe'
    Cnpj      = $cnpj
    Company   = $company
    DateRange = $range
}

PS C:\> $info = Resolve-DFeArchiveInfo @params

.NOTES
Performs no filesystem I/O.

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

    foreach ($propertyName in @('NomeFantasia', 'RazaoSocial', 'OutputPath')) {
        $property = $Company.PSObject.Properties[$propertyName]

        if ($null -eq $property) {
            throw [System.Management.Automation.ErrorRecord]::new(
                [System.ArgumentException]::new(
                    "Company is missing the required '$propertyName' property."
                ),
                "CompanyMissing$propertyName",
                [System.Management.Automation.ErrorCategory]::InvalidArgument,
                $Company
            )
        }
    }

    if ([string]::IsNullOrWhiteSpace($Company.OutputPath)) {
        throw [System.Management.Automation.ErrorRecord]::new(
            [System.ArgumentException]::new(
                'Company.OutputPath must not be null or empty.'
            ),
            'CompanyOutputPathNullOrEmpty',
            [System.Management.Automation.ErrorCategory]::InvalidArgument,
            $Company
        )
    }

    $sourceName = if (-not [string]::IsNullOrWhiteSpace($Company.NomeFantasia)) {
        $Company.NomeFantasia
    } else {
        $Company.RazaoSocial
    }

    if ([string]::IsNullOrWhiteSpace($sourceName)) {
        throw [System.Management.Automation.ErrorRecord]::new(
            [System.ArgumentException]::new(
                'Company must have a non-empty NomeFantasia or RazaoSocial.'
            ),
            'CompanyNameNullOrEmpty',
            [System.Management.Automation.ErrorCategory]::InvalidArgument,
            $Company
        )
    }

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
    $companyLabel = $labelWords -join '_'

    $fileName = '{0}_{1}_{2}_{3}.zip' -f (
        $TipoDFe,
        $Cnpj,
        $companyLabel,
        $periodSegment
    )

    $tempFileName = '{0}.{1}.tmp' -f (
        $fileName,
        [guid]::NewGuid().ToString('N')
    )

    $tempPathParams = @{
        Path      = [System.IO.Path]::GetTempPath()
        ChildPath = $tempFileName
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
