<#
.SYNOPSIS
Publishes a standalone analytical HTML report for the selected period.

.DESCRIPTION
Uses the selected NF-e and NFC-e XML files. Skips publication when
neither model is present. Publishes the HTML through a staging directory.

Each publication uses a unique directory under Relatorios in the
company's OutputPath. Existing publications are not replaced. This
function does not send email or change delivery state.

.PARAMETER Company
Company configuration with Cnpj, RazaoSocial, and OutputPath, plus optional Ie.
OutputPath must be an existing filesystem directory.

.PARAMETER DateRange
Inclusive report period with Start and End DateTimeOffset values.

.PARAMETER Entries
Indexed fiscal documents selected for the period.

.OUTPUTS
System.String
The published HTML path, or no output when no supported documents were selected.

.NOTES
Private dependencies:
  Get-DFeAnalyticalReportData
  ConvertTo-DFeCfopReportHtml
#>
function New-DFePeriodReport {
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions',
        '',
        Justification = 'Confirmation belongs to the calling workflow.'
    )]
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject]$Company,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject]$DateRange,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [pscustomobject[]]$Entries
    )

    $selected = @($Entries | Where-Object { [int]$_.modelo -in @(55, 65) })

    if ($selected.Count -eq 0) {
        return
    }

    $output = Resolve-Path -LiteralPath $Company.OutputPath -ErrorAction Stop

    if ($output.Provider.Name -ne 'FileSystem' -or -not
        [System.IO.Directory]::Exists($output.ProviderPath)
    ) {
        throw [System.ArgumentException]::new(
            'Company.OutputPath must resolve to an existing filesystem directory.'
        )
    }

    $dataParams = @{
        Cnpj        = [string]$Company.Cnpj
        Entries     = $selected
        ErrorAction = 'Stop'
    }

    $documents = @(Get-DFeAnalyticalReportData @dataParams)

    $htmlParams = @{
        Cnpj        = $dataParams.Cnpj
        StartDate   = $DateRange.Start
        EndDate     = $DateRange.End
        CompanyName = [string]$Company.RazaoSocial
        Documents   = $documents
        ErrorAction = 'Stop'
    }

    $ieProperty = $Company.PSObject.Properties['Ie']

    if ($null -ne $ieProperty) {
        $htmlParams.Ie = [string]$ieProperty.Value
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
        $dataParams.Cnpj,
        $startLabel,
        $endLabel,
        $publicationId
    )

    $root = [System.IO.Path]::Combine($output.ProviderPath, 'Relatorios')

    $stagingPath = [System.IO.Path]::Combine($root, ".$publicationId.tmp")
    $destination = [System.IO.Path]::Combine($root, $directoryName)

    $htmlName = 'RelatorioAnalitico.html'

    $htmlPath = [System.IO.Path]::Combine($stagingPath, $htmlName)

    try {
        [void][System.IO.Directory]::CreateDirectory($stagingPath)

        $encoding = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText($htmlPath, $html, $encoding)

        [System.IO.Directory]::Move($stagingPath, $destination)
    } finally {
        if ([System.IO.Directory]::Exists($stagingPath)) {
            Remove-Item -LiteralPath $stagingPath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    [System.IO.Path]::Combine($destination, $htmlName)
}
