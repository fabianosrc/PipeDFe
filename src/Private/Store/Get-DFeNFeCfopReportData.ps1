<#
.SYNOPSIS
Reads NF-e and NFC-e item details and summarizes them by model and CFOP.

.DESCRIPTION
Reads processed NF-e (model 55) and NFC-e (model 65) documents
from the company SQLite index.

Documents are selected using their issuance instant (dh_emi).
Both date boundaries are inclusive.

The indexed issuance timestamps must be stored in canonical UTC
ISO 8601 round-trip format to allow correct lexical comparison.

Each selected document must have a matching fiscal projection,
identified by access key, model and source XML SHA-256, and
at least one item. The hexadecimal SHA-256 comparison ignores letter case.

The summary:
  - Groups items independently by Modelo and CFOP.
  - Preserves missing CFOP as a separate group per model.
  - Sums vProd using System.Decimal.
  - Counts missing vProd values in ItensSemValor.
  - Does not include missing values in ValorProdutos.
  - Does not apply discounts or filter by indTot.
  - Returns zero as subtotal when all group values are missing.

.PARAMETER Cnpj
Normalized 14-character uppercase alphanumeric CNPJ identifying
the company index.

.PARAMETER StartDate
Inclusive lower bound for document issuance.

.PARAMETER EndDate
Inclusive upper bound for document issuance.

.OUTPUTS
System.Management.Automation.PSCustomObject

Properties:
  Itens         - Array of document item details.
  ResumoPorCFOP - Array summarized by model and CFOP.

Both properties are arrays, including when no documents match
or when they contain a single result.

.NOTES
Private dependency:
  Open-DFeIndexConnection

Error identifiers:
  InvalidDateRange
  NFeCfopReportReadFailed
#>
function Get-DFeNFeCfopReportData {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory)]
        [ValidatePattern('\A(?-i:[A-Z0-9]{14})\z')]
        [string]$Cnpj,

        [Parameter(Mandatory)]
        [System.DateTimeOffset]$StartDate,

        [Parameter(Mandatory)]
        [System.DateTimeOffset]$EndDate
    )

    #region Validate date range
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
    #endregion

    #region Initialize
    $culture = [System.Globalization.CultureInfo]::InvariantCulture

    # Normalize both boundaries to UTC.
    $startUtc = $StartDate.ToUniversalTime().ToString('o', $culture)
    $endUtc   = $EndDate.ToUniversalTime().ToString('o', $culture)

    $items = [System.Collections.Generic.List[pscustomobject]]::new()

    $connection = $null
    $command    = $null
    $reader     = $null
    $failure    = $null
    #endregion

    #region Read SQLite index
    try {
        $connectionParams = @{
            Cnpj        = $Cnpj
            ErrorAction = 'Stop'
        }

        $connection = Open-DFeIndexConnection @connectionParams

        $command = $connection.CreateCommand()
        $command.CommandText = @'
SELECT
    d.modelo,
    d.chave_acesso,
    d.dh_emi,
    n.numero,
    n.serie,
    i.n_item,
    i.cod_produto,
    i.descricao,
    i.cfop,
    i.vlr_produto,
    i.ind_compoe_total
FROM dfe_document AS d
LEFT JOIN dfe_nfe AS n
    ON n.chave_acesso = d.chave_acesso
    AND n.modelo = d.modelo
    AND n.source_sha256 = d.sha256 COLLATE NOCASE
LEFT JOIN dfe_nfe_item AS i
    ON i.chave_acesso = n.chave_acesso
WHERE
    d.modelo IN (55, 65)
    AND d.processing_status = 'Processed'
    AND d.dh_emi >= @startDate
    AND d.dh_emi <= @endDate
ORDER BY
    d.modelo,
    d.dh_emi,
    d.chave_acesso,
    i.n_item;
'@

        # Parameterized query.
        $command.Parameters.AddWithValue('@startDate', $startUtc) | Out-Null
        $command.Parameters.AddWithValue('@endDate', $endUtc) | Out-Null

        $reader = $command.ExecuteReader()

        while ($reader.Read()) {
            $key = [string]$reader['chave_acesso']

            # A processed document without a matching fiscal item
            # indicates an inconsistent or stale projection.
            if ($reader['n_item'] -is [System.DBNull]) {
                throw [System.IO.InvalidDataException]::new(
                    "Processed document '$key' has no matching fiscal items."
                )
            }

            # Normalize missing and whitespace-only CFOP values.
            $cfop = $null

            if ($reader['cfop'] -isnot [System.DBNull]) {
                $rawCfop = [string]$reader['cfop']

                if (-not [string]::IsNullOrWhiteSpace($rawCfop)) {
                    $cfop = $rawCfop.Trim()
                }
            }

            # Preserve missing monetary values as $null.
            # A real numeric zero remains Decimal zero.
            $productValue = $null

            if ($reader['vlr_produto'] -isnot [System.DBNull]) {
                $productValue = [decimal]::Parse(
                    [string]$reader['vlr_produto'],
                    [System.Globalization.NumberStyles]::Float,
                    $culture
                )
            }

            $items.Add(
                [PSCustomObject]@{
                    Modelo         = [int]$reader['modelo']
                    ChaveAcesso    = $key
                    DataEmissao    = [string]$reader['dh_emi']
                    Numero         = [string]$reader['numero']
                    Serie          = [string]$reader['serie']
                    Item           = [int]$reader['n_item']
                    CodigoProduto  = [string]$reader['cod_produto']
                    Descricao      = [string]$reader['descricao']
                    CFOP           = $cfop
                    ValorProduto   = $productValue
                    IndCompoeTotal = [string]$reader['ind_compoe_total']
                }
            )
        }
    } catch {
        # Preserve the original failure for later error translation.
        $failure = $_
    } finally {
        # Release every acquired resource in reverse order.
        # A cleanup failure must not replace an existing read failure.
        foreach ($resource in @($reader, $command, $connection)) {
            if ($null -eq $resource) {
                continue
            }

            try {
                $resource.Dispose()
            } catch {
                if ($null -eq $failure) {
                    $failure = $_
                }
            }
        }
    }

    # Translate read and cleanup failures into a stable error identifier.
    if ($null -ne $failure) {
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                $failure.Exception,
                'NFeCfopReportReadFailed',
                [System.Management.Automation.ErrorCategory]::ReadError,
                $Cnpj
            )
        )
    }
    #endregion

    #region Build summary
    $summary = @(
        $items |
            Group-Object -Property Modelo, CFOP |
            ForEach-Object {
                $group = $_.Group

                [decimal]$total = 0
                [int]$missingValues = 0

                foreach ($item in $group) {
                    if ($null -eq $item.ValorProduto) {
                        $missingValues++
                    } else {
                        $total += [decimal]$item.ValorProduto
                    }
                }

                [PSCustomObject]@{
                    Modelo        = $group[0].Modelo
                    CFOP          = $group[0].CFOP
                    Quantidade    = $group.Count
                    ItensSemValor = $missingValues
                    ValorProdutos = $total
                }
            } |

            Sort-Object -Property Modelo, CFOP
    )
    #endregion

    #region Return report data
    [PSCustomObject]@{
        Itens         = [object[]]$items.ToArray()
        ResumoPorCFOP = [object[]]$summary
    }
    #endregion
}
