<#
.SYNOPSIS
Renders a standalone HTML report for NF-e and NFC-e CFOP summaries.

.DESCRIPTION
Renders the precomputed summary from Get-DFeNFeCfopReportData in the
supplied row order. The report shows item counts, missing-value counts,
and gross product subtotals using Brazilian Portuguese formatting.

The function does not query the index, recalculate totals, write files,
or use the notification email template.

.PARAMETER CompanyName
Company name shown in the report.

.PARAMETER Cnpj
Normalized CNPJ identifying the company.

.PARAMETER StartDate
Inclusive lower bound of the report period. The supplied offset is
preserved when displaying the calendar date.

.PARAMETER EndDate
Inclusive upper bound of the report period. The supplied offset is
preserved when displaying the calendar date.

.PARAMETER Summary
ResumoPorCFOP rows returned by Get-DFeNFeCfopReportData. Each row must
expose Modelo, CFOP, Quantidade, ItensSemValor, and ValorProdutos.
An empty collection is valid.

.OUTPUTS
System.String
A complete HTML document intended to be saved as UTF-8.

.NOTES
Private dependency:
  ConvertTo-FormattedCnpj
#>
function ConvertTo-DFeCfopReportHtml {
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$CompanyName,

        [Parameter(Mandatory)]
        [ValidatePattern('\A(?-i:[A-Z0-9]{14})\z')]
        [string]$Cnpj,

        [Parameter(Mandatory)]
        [System.DateTimeOffset]$StartDate,

        [Parameter(Mandatory)]
        [System.DateTimeOffset]$EndDate,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [ValidateNotNull()]
        [pscustomobject[]]$Summary
    )

    if ($EndDate -lt $StartDate) {
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                [System.ArgumentException]::new(
                    'EndDate must not be earlier than StartDate.',
                    'EndDate'
                ),
                'InvalidDateRange',
                [System.Management.Automation.ErrorCategory]::InvalidArgument,
                $EndDate
            )
        )
    }

    $culture       = [System.Globalization.CultureInfo]::GetCultureInfo('pt-BR')
    $companyHtml   = [System.Net.WebUtility]::HtmlEncode($CompanyName)
    $formattedCnpj = ConvertTo-FormattedCnpj -Value $Cnpj
    $startLabel    = $StartDate.ToString('dd/MM/yyyy', $culture)
    $endLabel      = $EndDate.ToString('dd/MM/yyyy', $culture)

    $rowTemplate = @'
        <tr>
            <td>{0}</td>
            <td>{1}</td>
            <td class="number">{2}</td>
            <td class="number">{3}</td>
            <td class="number">{4}</td>
        </tr>
'@

    $rows = @(
        foreach ($row in $Summary) {
            $modelLabel = switch ($row.Modelo) {
                55 {
                    'NF-e'
                }
                65 {
                    'NFC-e'
                }
                default {
                    $PSCmdlet.ThrowTerminatingError(
                        [System.Management.Automation.ErrorRecord]::new(
                            [System.ArgumentException]::new(
                                "Unsupported CFOP summary model '$($row.Modelo)'.",
                                'Summary'
                            ),
                            'UnsupportedCfopSummaryModel',
                            [System.Management.Automation.ErrorCategory]::InvalidArgument,
                            $row.Modelo
                        )
                    )
                }
            }

            $cfopLabel = if ([string]::IsNullOrWhiteSpace($row.CFOP)) {
                'Não informado'
            } else {
                [System.Net.WebUtility]::HtmlEncode([string]$row.CFOP)
            }

            $itemCount    = ([int]$row.Quantidade).ToString('N0', $culture)
            $missingCount = ([int]$row.ItensSemValor).ToString('N0', $culture)
            $subtotal     = ([decimal]$row.ValorProdutos).ToString('N2', $culture)

            $rowTemplate -f $modelLabel, $cfopLabel, $itemCount, $missingCount, $subtotal
        }
    )

    if ($rows.Count -eq 0) {
        $rows = @(
            '<tr>
                <td colspan="5">Nenhum item de NF-e ou NFC-e no período.</td>
            </tr>'
        )
    }

    $tableRows = $rows -join [System.Environment]::NewLine

    @"
<!DOCTYPE html>
<html lang="pt-BR">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Resumo por CFOP</title>
    <title></title>
    <style>
        body {
            margin: 2rem auto;
            padding: 0 1rem;
            max-width: 56rem;
            color: #222;
            font: 1rem/1.5 system-ui, sans-serif;
        }

        table {
            width: 100%;
            border-collapse: collapse;
        }

        caption {
            text-align: left;
            font-weight: bold;
            margin-bottom: .5rem;
        }

        th,
        td {
            padding: .5rem .75rem;
            border-bottom: 1px solid #ddd;
            text-align: left;
        }

        thead {
            background: #eef2f6;
        }

        .number {
            text-align: right;
            font-variant-numeric: tabular-nums;
        }
    </style>
</head>
<body>
    <main>
        <h1>Resumo por CFOP</h1>
        <p><strong>Empresa:</strong> $companyHtml<br>
            <strong>CNPJ:</strong> $formattedCnpj<br>
            <strong>Período:</strong> $startLabel a $endLabel
        </p>
        <table>
            <caption>NF-e e NFC-e por modelo e CFOP</caption>
            <thead>
                <tr>
                    <th scope="col">Modelo</th>
                    <th scope="col">CFOP</th>
                    <th scope="col" class="number">Itens</th>
                    <th scope="col" class="number">Itens sem valor</th>
                    <th scope="col" class="number">Valor bruto dos produtos (R$)</th>
                </tr>
            </thead>
            <tbody>
                $tableRows
            </tbody>
        </table>
        <p>Os subtotais somam o valor bruto dos itens (vProd), sem descontar
            valores ou excluir itens pelo indicador indTot. Itens sem valor
            informado são contados, mas não contribuem para o subtotal.
        </p>
    </main>
</body>
</html>
"@
}
