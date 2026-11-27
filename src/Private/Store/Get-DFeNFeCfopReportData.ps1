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

Each item record includes analytical fiscal fields:
  - NaturezaOperacao (from dfe_nfe)
  - NCM, Unidade, Quantidade, ValorUnitario (from dfe_nfe_item)
  - CST, CSOSN, BaseCalcIcms, AliqIcms, ValorIcms
    (from dfe_nfe_item_icms, joined with LEFT JOIN)

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

Item properties:
  Modelo, ChaveAcesso, DataEmissao, Numero, Serie,
  NaturezaOperacao, Item, CodigoProduto, Descricao, NCM,
  Unidade, Quantidade, ValorUnitario, CFOP, ValorProduto,
  IndCompoeTotal, CST, CSOSN, BaseCalcIcms, AliqIcms, ValorIcms

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
    n.natureza_operacao,
    i.n_item,
    i.cod_produto,
    i.descricao,
    i.ncm,
    i.cfop,
    i.unidade,
    i.qte_comercial,
    i.vlr_unitario,
    i.vlr_produto,
    i.ind_compoe_total,
    icms.cst,
    icms.csosn,
    icms.vlr_bc,
    icms.pct_icms,
    icms.vlr_icms
FROM dfe_document AS d
LEFT JOIN dfe_nfe AS n
    ON n.chave_acesso = d.chave_acesso
    AND n.modelo = d.modelo
    AND n.source_sha256 = d.sha256 COLLATE NOCASE
LEFT JOIN dfe_nfe_item AS i
    ON i.chave_acesso = n.chave_acesso
LEFT JOIN dfe_nfe_item_icms AS icms
    ON icms.chave_acesso = i.chave_acesso
    AND icms.n_item = i.n_item
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

            # Optional decimal fields from dfe_nfe_item.
            $qty = $null

            if ($reader['qte_comercial'] -isnot [System.DBNull]) {
                $rawQty = [string]$reader['qte_comercial']
                if (-not [string]::IsNullOrWhiteSpace($rawQty)) {
                    $qty = [decimal]::Parse(
                        $rawQty,
                        [System.Globalization.NumberStyles]::Float,
                        $culture
                    )
                }
            }

            $unitValue = $null

            if ($reader['vlr_unitario'] -isnot [System.DBNull]) {
                $rawUnit = [string]$reader['vlr_unitario']
                if (-not [string]::IsNullOrWhiteSpace($rawUnit)) {
                    $unitValue = [decimal]::Parse(
                        $rawUnit,
                        [System.Globalization.NumberStyles]::Float,
                        $culture
                    )
                }
            }

            # Optional decimal fields from dfe_nfe_item_icms.
            $baseCalcIcms = $null

            if ($reader['vlr_bc'] -isnot [System.DBNull]) {
                $rawBc = [string]$reader['vlr_bc']
                if (-not [string]::IsNullOrWhiteSpace($rawBc)) {
                    $baseCalcIcms = [decimal]::Parse(
                        $rawBc,
                        [System.Globalization.NumberStyles]::Float,
                        $culture
                    )
                }
            }

            $aliqIcms = $null

            if ($reader['pct_icms'] -isnot [System.DBNull]) {
                $rawAliq = [string]$reader['pct_icms']
                if (-not [string]::IsNullOrWhiteSpace($rawAliq)) {
                    $aliqIcms = [decimal]::Parse(
                        $rawAliq,
                        [System.Globalization.NumberStyles]::Float,
                        $culture
                    )
                }
            }

            $valIcms = $null

            if ($reader['vlr_icms'] -isnot [System.DBNull]) {
                $rawVlrIcms = [string]$reader['vlr_icms']
                if (-not [string]::IsNullOrWhiteSpace($rawVlrIcms)) {
                    $valIcms = [decimal]::Parse(
                        $rawVlrIcms,
                        [System.Globalization.NumberStyles]::Float,
                        $culture
                    )
                }
            }

            # Optional text fields.
            $naturezaOp = $null

            if ($reader['natureza_operacao'] -isnot [System.DBNull]) {
                $naturezaOp = [string]$reader['natureza_operacao']
            }

            $ncm = $null

            if ($reader['ncm'] -isnot [System.DBNull]) {
                $ncm = [string]$reader['ncm']
            }

            $unidade = $null

            if ($reader['unidade'] -isnot [System.DBNull]) {
                $unidade = [string]$reader['unidade']
            }

            $cst = $null

            if ($reader['cst'] -isnot [System.DBNull]) {
                $cst = [string]$reader['cst']
            }

            $csosn = $null

            if ($reader['csosn'] -isnot [System.DBNull]) {
                $csosn = [string]$reader['csosn']
            }

            $items.Add(
                [PSCustomObject]@{
                    Modelo            = [int]$reader['modelo']
                    ChaveAcesso       = $key
                    DataEmissao       = [string]$reader['dh_emi']
                    Numero            = [string]$reader['numero']
                    Serie             = [string]$reader['serie']
                    NaturezaOperacao  = $naturezaOp
                    Item              = [int]$reader['n_item']
                    CodigoProduto     = [string]$reader['cod_produto']
                    Descricao         = [string]$reader['descricao']
                    NCM               = $ncm
                    CFOP              = $cfop
                    Unidade           = $unidade
                    Quantidade        = $qty
                    ValorUnitario     = $unitValue
                    ValorProduto      = $productValue
                    IndCompoeTotal    = [string]$reader['ind_compoe_total']
                    CST               = $cst
                    CSOSN             = $csosn
                    BaseCalcIcms      = $baseCalcIcms
                    AliqIcms          = $aliqIcms
                    ValorIcms         = $valIcms
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
