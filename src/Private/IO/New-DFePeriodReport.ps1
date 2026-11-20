<#
.SYNOPSIS
Publishes standalone HTML and XLSX reports for a selected period.

.DESCRIPTION
Reads the CFOP projection once and uses it for both reports. Writes
the reports to a staging directory and publishes the pair only after
the HTML has been written and a non-empty workbook exists.

Each publication uses a unique directory under Relatorios in the
company's OutputPath. Existing publications are not replaced. This
function does not send email or change delivery state.

.PARAMETER Company
Company configuration with Cnpj, NomeFantasia, RazaoSocial, and
OutputPath. OutputPath must be an existing filesystem directory.

.PARAMETER DateRange
Inclusive report period with Start and End DateTimeOffset values.

.PARAMETER Entries
Indexed fiscal documents selected for the period.

.PARAMETER NFSeEntries
Indexed National NFS-e documents selected for the period.

.PARAMETER Gaps
Sequence ranges selected for the period.

.OUTPUTS
System.String
The full paths of the published HTML and XLSX files, in that order.

.NOTES
Private dependencies:
  Get-DFeNFeCfopReportData
  ConvertTo-DFeCfopReportHtml
  Export-DFeCfopReportXlsx
#>
function New-DFePeriodReport {
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions',
        '',
        Justification = 'Confirmation belongs to the calling workflow.'
    )]
    [CmdletBinding()]
    [OutputType([string], [string])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject]$Company,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject]$DateRange,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [pscustomobject[]]$Entries,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [pscustomobject[]]$NFSeEntries,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [pscustomobject[]]$Gaps
    )

    $output = Resolve-Path -LiteralPath $Company.OutputPath -ErrorAction Stop

    if ($output.Provider.Name -ne 'FileSystem' -or -not
        [System.IO.Directory]::Exists($output.ProviderPath)
    ) {
        throw [System.ArgumentException]::new(
            'Company.OutputPath must resolve to an existing filesystem directory.'
        )
    }

    $queryParams = @{
        Cnpj        = [string]$Company.Cnpj
        StartDate   = $DateRange.Start
        EndDate     = $DateRange.End
        ErrorAction = 'Stop'
    }

    $reportData = Get-DFeNFeCfopReportData @queryParams

    $companyName = if ([string]::IsNullOrWhiteSpace($Company.NomeFantasia)) {
        [string]$Company.RazaoSocial
    } else {
        [string]$Company.NomeFantasia
    }

    $htmlParams = @{
        Cnpj        = $queryParams.Cnpj
        StartDate   = $queryParams.StartDate
        EndDate     = $queryParams.EndDate
        CompanyName = $companyName
        Summary     = $reportData.ResumoPorCFOP
        ErrorAction = 'Stop'
    }

    $html = ConvertTo-DFeCfopReportHtml @htmlParams

    if ([string]::IsNullOrWhiteSpace($html)) {
        throw [System.InvalidOperationException]::new(
            'The HTML renderer did not produce a non-empty report.'
        )
    }

    $culture    = [System.Globalization.CultureInfo]::InvariantCulture
    $startLabel = $DateRange.Start.ToString('yyyyMMdd', $culture)
    $endLabel   = $DateRange.End.ToString('yyyyMMdd', $culture)

    $publicationId = [guid]::NewGuid().ToString('N')
    $directoryName = '{0}_{1}-{2}_{3}' -f (
        $queryParams.Cnpj,
        $startLabel,
        $endLabel,
        $publicationId
    )

    $root = [System.IO.Path]::Combine($output.ProviderPath, 'Relatorios')

    $stagingPath = [System.IO.Path]::Combine($root, ".$publicationId.tmp")
    $destination = [System.IO.Path]::Combine($root, $directoryName)

    $htmlName = 'Resumo-CFOP.html'
    $xlsxName = 'Fechamento.xlsx'
    $htmlPath = [System.IO.Path]::Combine($stagingPath, $htmlName)
    $xlsxPath = [System.IO.Path]::Combine($stagingPath, $xlsxName)

    $xlsxParams = @{
        Cnpj            = $queryParams.Cnpj
        StartDate       = $queryParams.StartDate
        EndDate         = $queryParams.EndDate
        LiteralPath     = $xlsxPath
        ReportData      = $reportData
        DocumentEntries = $Entries
        NFSeEntries     = $NFSeEntries
        Gaps            = $Gaps
        ErrorAction     = 'Stop'
    }

    try {
        [void][System.IO.Directory]::CreateDirectory($stagingPath)

        $encoding = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText($htmlPath, $html, $encoding)

        Export-DFeCfopReportXlsx @xlsxParams | Out-Null

        $workbook = [System.IO.FileInfo]::new($xlsxPath)

        if (-not $workbook.Exists -or $workbook.Length -eq 0) {
            throw [System.IO.IOException]::new(
                "The XLSX exporter did not create a non-empty workbook at '$xlsxPath'."
            )
        }

        [System.IO.Directory]::Move($stagingPath, $destination)
    } finally {
        if ([System.IO.Directory]::Exists($stagingPath)) {
            Remove-Item -LiteralPath $stagingPath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    [System.IO.Path]::Combine($destination, $htmlName)
    [System.IO.Path]::Combine($destination, $xlsxName)
}
