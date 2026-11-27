<#
.SYNOPSIS
Renders a standalone analytical NF-e and NFC-e report.

.DESCRIPTION
Groups the selected documents by model, direction and issuance date.
Confirmed and unconfirmed cancellation events have separate sections.
Document totals use declared values and CFOP totals use item values.

.PARAMETER CompanyName
Company name shown in the report.

.PARAMETER Cnpj
Normalized company CNPJ.

.PARAMETER Ie
Company state tax registration, when configured.

.PARAMETER StartDate
Inclusive start of the selected period.

.PARAMETER EndDate
Inclusive end of the selected period.

.PARAMETER Documents
Fiscal documents returned by Get-DFeAnalyticalReportData.

.OUTPUTS
System.String

.NOTES
Private dependencies:
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

        [Parameter()]
        [string]$Ie,

        [Parameter(Mandatory)]
        [datetimeoffset]$StartDate,

        [Parameter(Mandatory)]
        [datetimeoffset]$EndDate,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [pscustomobject[]]$Documents
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

    # Articles with this many items or fewer render without a scroll region,
    # keeping short notes compact on screen and in print.
    [int]$shortNoteThreshold = 4

    $culture = [System.Globalization.CultureInfo]::GetCultureInfo('pt-BR')

    $encode = {
        param (
            [Parameter()]
            [object]$Value
        )

        if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
            return '&mdash;'
        }

        [System.Net.WebUtility]::HtmlEncode([string]$Value)
    }

    $number = {
        param (
            [Parameter()]
            [object]$Value,

            [Parameter()]
            [string]$Format = 'N2'
        )

        if ($null -eq $Value) { return '&mdash;' }

        ([decimal]$Value).ToString($Format, $culture)
    }

    $sum = {
        param (
            [Parameter()]
            [pscustomobject[]]$Rows,

            [Parameter()]
            [string]$Property
        )

        [decimal]$total = 0

        [bool]$hasValue = $false

        foreach ($row in $Rows) {
            if ($null -ne $row.$Property) {
                $total    += [decimal]$row.$Property
                $hasValue  = $true
            }
        }

        if ($hasValue) { $total } else { $null }
    }

    $company    = & $encode $CompanyName
    $identifier = & $encode (ConvertTo-FormattedCnpj -Value $Cnpj)

    $stateRegistration = if (-not [string]::IsNullOrWhiteSpace($Ie)) {
        ' &middot; IE: {0}' -f (& $encode $Ie)
    } else {
        [string]::Empty
    }

    $start = $StartDate.ToString('dd/MM/yyyy', $culture)
    $end   = $EndDate.ToString('dd/MM/yyyy', $culture)

    $active = @(
        $Documents |
            Where-Object {
                -not $_.Cancelada -and -not $_.CancelamentoSemConfirmar
            }
    )

    $cancelled = @(
        $Documents |
            Where-Object {
                $_.Cancelada
            }
    )

    $unconfirmed = @(
        $Documents |
            Where-Object {
                -not $_.Cancelada -and $_.CancelamentoSemConfirmar
            }
    )

    $groups = @(
        $active |
            Group-Object -Property Modelo, Direcao |
            Sort-Object -Property Name
    )

    $directionLabels = @(
        $Documents |
            Select-Object -ExpandProperty Direcao -Unique |
            ForEach-Object {
                switch ($_) {
                    'Saida' {
                        'Sa&iacute;da'
                    }
                    'Entrada' {
                        'Entrada'
                    }
                    default {
                        'Sem dire&ccedil;&atilde;o atribu&iacute;da'
                    }
                }
            }
    )

    $directionText = if ($directionLabels.Count -gt 0) {
        'Documentos de {0} &middot; ' -f ($directionLabels -join ' e ')
    } else {
        [string]::Empty
    }

    $pendingCount = if ($unconfirmed.Count -gt 0) {
        ' &middot; A Conferir: <strong>{0}</strong>' -f $unconfirmed.Count
    } else {
        [string]::Empty
    }

    $links = [System.Collections.Generic.List[string]]::new()
    $links.Add('<a href="#notas">Documentos</a>')
    $links.Add('<a href="#cfop">Resumo por CFOP</a>')

    if ($cancelled.Count -gt 0) {
        $links.Add('<a href="#canceladas">Cancelamentos</a>')
    }

    if ($unconfirmed.Count -gt 0) {
        $links.Add('<a href="#pendentes">Cancelamentos a conferir</a>')
    }

    $extraFields = [ordered]@{
        PIS           = 'PIS'
        Cofins        = 'COFINS'
        IBS           = 'IBS'
        CBS           = 'CBS'
        IcmsST        = 'ICMS-ST'
        IPI           = 'IPI'
        BaseII        = 'BC II'
        II            = 'II'
        DespAduaneira = 'Desp. aduaneiras'
        IOF           = 'IOF'
    }

    $allItems = @(
        $active |
            ForEach-Object { $_.Itens } |
            Where-Object { $null -ne $_ }
    )

    $extra = @(
        foreach ($field in $extraFields.Keys) {
            if ($null -ne (& $sum $allItems $field)) {
                $field
            }
        }
    )

    $hasExcludedItems = $allItems.Count -gt 0 -and '0' -in $allItems.IndTotal
    $columns = 10 + $extra.Count + [int]$hasExcludedItems

    $widths = [System.Collections.Generic.List[double]]::new()
    $baseWidths = @(34.4, 3.8, 4, 4.6, 2.6, 5.8, 7, 7, 4.5, 6.5)

    foreach ($w in $baseWidths) { $widths.Add($w) }

    $taxWidths = @{
        PIS    = 5
        Cofins = 6
        IBS    = 4.3
        CBS    = 4.3
    }

    foreach ($field in $extra) {
        if ($taxWidths.ContainsKey($field)) {
            $widths.Add($taxWidths[$field])
        } else {
            $widths.Add(6)
        }
    }

    if ($hasExcludedItems) { $widths.Add(6) }

    $widthTotal   = 0

    foreach ($w in $widths) { $widthTotal += $w }

    $columnStyles = foreach ($width in $widths) {
        $pct = (100 * $width / $widthTotal).ToString(
            '0.00000',
            [cultureinfo]::InvariantCulture
        )

        '<col style="width:{0}%">' -f $pct
    }

    $colGroup = '<colgroup>{0}</colgroup>' -f ($columnStyles -join '')

    $noteHeader = {
        param (
            [Parameter()]
            [pscustomobject]$Doc
        )

        $model = if ($Doc.Modelo -eq 55) { 'NF-e' } else { 'NFC-e' }

        $party = if ($Doc.Direcao -eq 'Entrada') {
            'Emitente'
        } else {
            'Destinat&aacute;rio'
        }

        $issued = $Doc.DataEmissao.ToString('dd/MM/yyyy HH:mm:ss', $culture)

        $partyId = [string]$Doc.DocumentoContraparte

        switch ($Doc.TipoDocumentoContraparte) {
            'Cnpj' {
                $partyId = $partyId -creplace (
                    '^([A-Z0-9]{2})([A-Z0-9]{3})([A-Z0-9]{3})([A-Z0-9]{4})([0-9]{2})$',
                    '$1.$2.$3/$4-$5'
                )
            }
            'Cpf' {
                $partyId = $partyId -replace (
                    '^([0-9]{3})([0-9]{3})([0-9]{3})([0-9]{2})$',
                    '$1.$2.$3-$4'
                )
            }
        }

        $partyValues = @(
            foreach ($value in @($partyId, $Doc.Contraparte)) {
                if (-not [string]::IsNullOrWhiteSpace($value)) {
                    & $encode $value
                }
            }
        )

        $partyText = if ($partyValues.Count -gt 0) {
            $partyValues -join ' - '
        } else {
            '&mdash;'
        }

        '<div class="note-head">'
        '<h3><strong>{0} {1}</strong> &middot; S&eacute;rie: {2} &middot; Emiss&atilde;o: {3}</h3>' -f (
            $model,
            (& $encode $Doc.Numero),
            (& $encode $Doc.Serie),
            $issued
        )

        '<p><strong>{0}:</strong> {1}</p>' -f $party, $partyText
        '<p><strong>Natureza da Opera&ccedil;&atilde;o:</strong> {0}</p>' -f (
            & $encode $Doc.Natureza
        )

        '<p class="access"><strong>Chave de Acesso:</strong> <code>{0}</code></p>' -f (
            & $encode $Doc.ChaveAcesso
        )
        '</div>'
    }

    $details = @(
        foreach ($modelGroup in $groups) {
            [pscustomobject]$first = $modelGroup.Group[0]

            $modelLabel = if ($first.Modelo -eq 55) { 'NF-e' } else { 'NFC-e' }

            $directionLabel = switch ($first.Direcao) {
                'Saida' {
                    ' - Sa&iacute;da'
                }
                'Entrada' {
                    ' - Entrada'
                }
                default {
                    [string]::Empty
                }
            }

            if ($groups.Count -gt 1) {
                '<h3 class="group-title">{0}{1}</h3>' -f $modelLabel, $directionLabel
            }

            $dayGroups = $modelGroup.Group |
                Group-Object { $_.DataEmissao.ToString('yyyy-MM-dd') } |
                Sort-Object -Property Name

            foreach ($day in $dayGroups) {
                [pscustomobject]$dayFirst = $day.Group[0]
                $date = $dayFirst.DataEmissao.ToString('dd/MM/yyyy', $culture)

                '<div class="day">'
                '<h4>{0} <span>{1} documentos</span></h4>' -f $date, $day.Count

                $sortedDocs = $day.Group |
                    Sort-Object -Property DataEmissao, ChaveAcesso

                foreach ($doc in $sortedDocs) {
                    if ($doc.Itens.Count -le $shortNoteThreshold) {
                        '<article class="note short-note">'
                    } else {
                        '<article class="note">'
                    }

                    & $noteHeader $doc

                    '<div class="table-wrap" tabindex="0" role="region"' +
                    ' aria-label="Itens da nota"> <table>'
                    $colGroup

                    [bool]$hasCst   = $false
                    [bool]$hasCsosn = $false

                    foreach ($item in $doc.Itens) {
                        $hasCst   = $hasCst   -or -not [string]::IsNullOrWhiteSpace($item.CST)
                        $hasCsosn = $hasCsosn -or -not [string]::IsNullOrWhiteSpace($item.CSOSN)

                        if ($hasCst -and $hasCsosn) { break }
                    }

                    $taxHeader = if ($hasCst -and -not $hasCsosn) {
                        'CST'
                    } elseif ($hasCsosn -and -not $hasCst) {
                        'CSOSN'
                    } else {
                        'CST/CSOSN'
                    }

                    (
                        '<thead> <tr>' +
                        '<th class="product" scope="col">Produto</th>' +
                        '<th scope="col">CFOP</th>' +
                        '<th class="tax-code" scope="col">{0}</th>' +
                        '<th class="num" scope="col">Qtd.</th>' +
                        '<th class="unit" scope="col">Un.</th>' +
                        '<th class="num" scope="col">Vlr. Unit.</th>' +
                        '<th class="num" scope="col">Vlr. Prod.</th>' +
                        '<th class="num" scope="col">BC ICMS</th>' +
                        '<th class="num" scope="col">ICMS %</th>' +
                        '<th class="num" scope="col">Vlr. ICMS</th>'
                    ) -f $taxHeader

                    foreach ($field in $extra) {
                        '<th class="num" scope="col">{0}</th>' -f $extraFields[$field]
                    }

                    if ($hasExcludedItems) {
                        '<th scope="col">Comp&otilde;e vProd</th>'
                    }

                    '</tr></thead>'

                    $orderedItems = @($doc.Itens | Sort-Object -Property Item)

                    if ($orderedItems.Count -gt 1) { '<tbody>' }

                    if ($orderedItems.Count -eq 0) { '<tbody class="note-tail">' }

                    [int]$itemIndex = 0

                    foreach ($item in $orderedItems) {
                        $itemIndex++

                        if ($itemIndex -eq $orderedItems.Count) {
                            if ($itemIndex -gt 1) { '</tbody>' }
                            '<tbody class="note-tail">'
                        }

                        $taxCode = if (-not [string]::IsNullOrWhiteSpace($item.CST)) {
                            $item.CST
                        } else {
                            $item.CSOSN
                        }

                        $taxCodeHtml = & $encode $taxCode

                        if (-not [string]::IsNullOrWhiteSpace($taxCode)) {
                            if ([string]::IsNullOrWhiteSpace($item.Origem)) {
                                $taxCodeHtml += '<small>Origem ausente</small>'
                            } else {
                                $taxCodeHtml = & $encode (
                                    '{0}{1}' -f $item.Origem, $taxCode
                                )
                            }
                        }

                        (
                            '<tr><td class="product">{0}<small>Item {1} &middot; C&oacute;d. {2} &middot; NCM {3}</small></td>' +
                            '<td>{4}</td><td class="tax-code">{5}</td>'
                        ) -f
                        (
                            (& $encode $item.Produto),
                            (& $encode $item.Item),
                            (& $encode $item.Codigo),
                            (& $encode $item.NCM),
                            (& $encode $item.CFOP),
                            $taxCodeHtml
                        )

                        (
                            '<td class="num">{0}</td>' +
                            '<td class="unit">{1}</td>' +
                            '<td class="num">{2}</td>' +
                            '<td class="num">{3}</td>' +
                            '<td class="num">{4}</td>' +
                            '<td class="num">{5}</td>' +
                            '<td class="num">{6}</td>'
                        ) -f
                        (
                            (& $number $item.Quantidade '#,0.####'),
                            (& $encode $item.Unidade),
                            (& $number $item.ValorUnitario '#,0.00########'),
                            (& $number $item.ValorProduto),
                            (& $number $item.BaseIcms),
                            (& $number $item.AliqIcms '0.00##########################'),
                            (& $number $item.Icms)
                        )

                        foreach ($field in $extra) {
                            '<td class="num">{0}</td>' -f (& $number $item.$field)
                        }

                        if ($hasExcludedItems) {
                            $included = switch ($item.IndTotal) {
                                '0'     { 'N&atilde;o' }
                                '1'     { 'Sim'        }
                                default { '&mdash;'    }
                            }

                            '<td>{0}</td>' -f $included
                        }

                        '</tr>'
                    }

                    $commercialFields = @(
                        'Frete'
                        'Seguro'
                        'Desconto'
                        'Outras despesas'
                    )

                    $commercial = @(
                        '<strong>Total dos Produtos:</strong> {0}' -f (
                            & $number $doc.ValorProdutos
                        )

                        foreach ($field in $commercialFields) {
                            $value = $doc.Tributos[$field]
                            if ($null -ne $value -and $value -ne 0) {
                                '{0}: {1}' -f $field, (& $number $value)
                            }
                        }
                    )

                    $taxTotals = @(
                        foreach ($tax in $doc.Tributos.Keys) {
                            $value = $doc.Tributos[$tax]

                            if ($tax -notin $commercialFields -and
                                $null -ne $value -and
                                $value -ne 0
                            ) {
                                '{0}: {1}' -f (& $encode $tax), (& $number $value)
                            }
                        }
                    )

                    '<tr class="total-row"><td colspan="{0}"><div class="note-total">' -f $columns

                    (
                        '<div class="commercial"><span>{0}</span>' +
                        '<strong class="invoice-total">Total da {1}: {2}</strong></div>'
                    ) -f
                    (
                        ($commercial -join ' &middot; '),
                        $modelLabel,
                        (& $number $doc.ValorNota)
                    )

                    if ($taxTotals.Count -gt 0) {
                        '<div class="tax-total"><strong>Tributos:</strong> {0}</div>' -f (
                            $taxTotals -join ' &middot; '
                        )
                    }

                    '</div></td></tr></tbody></table></div></article>'
                }

                '<p class="day-total">Total do dia: <strong>{0}</strong></p></div>' -f (
                    & $number (& $sum $day.Group 'ValorNota')
                )
            }
        }
    )

    $summaryFields = [ordered]@{
        ValorProduto = 'Vlr. Produtos'
        BaseIcms     = 'BC ICMS'
        Icms         = 'ICMS'
        PIS          = 'PIS'
        Cofins       = 'COFINS'
        IBS          = 'IBS'
        CBS          = 'CBS'
    }

    $summaryCells = {
        param (
            [Parameter()]
            [pscustomobject[]]$Items
        )

        '<td class="num">{0}</td>' -f $Items.Count.ToString('N0', $culture)

        foreach ($field in $summaryFields.Keys) {
            '<td class="num">{0}</td>' -f (& $number (& $sum $Items $field))
        }
    }

    $summary = @(
        foreach ($modelGroup in $groups) {
            [pscustomobject]$first = $modelGroup.Group[0]

            $modelLabel = if ($first.Modelo -eq 55) {
                'NF-e'
            } else {
                'NFC-e'
            }

            $directionLabel = switch ($first.Direcao) {
                'Saida' {
                    ' - Sa&iacute;da'
                }
                'Entrada' {
                    ' - Entrada'
                }
                default {
                    [string]::Empty
                }
            }

            if ($groups.Count -gt 1) {
                '<h3 class="group-title">{0}{1}</h3>' -f $modelLabel, $directionLabel
            }

            '<div class="table-wrap" tabindex="0" role="region"' +
            ' aria-label="Resumo por CFOP"><table class="cfop-table">'
            '<thead><tr><th scope="col">CFOP</th><th class="num" scope="col">Itens</th>'

            foreach ($label in $summaryFields.Values) {
                '<th class="num" scope="col">{0}</th>' -f $label
            }

            '</tr></thead><tbody>'

            $items = @(
                $modelGroup.Group |
                    ForEach-Object { $_.Itens } |
                    Where-Object { $null -ne $_ }
            )

            $cfopGroups = $items |
                Group-Object -Property CFOP |
                Sort-Object -Property Name

            foreach ($cfop in $cfopGroups) {
                '<tr><td>{0}</td>' -f (& $encode $cfop.Name)
                & $summaryCells $cfop.Group
                '</tr>'
            }

            '</tbody><tfoot><tr><th scope="row">Total</th>'
            & $summaryCells $items
            '</tr></tfoot></table></div>'

            (
                '<p class="period-total">Total das {0}{1} sem cancelamento identificado: ' +
                '<strong>{2}</strong></p>'
            ) -f
            (
                $modelLabel,
                $directionLabel,
                (& $number (& $sum $modelGroup.Group 'ValorNota'))
            )
        }
    )

    $events = @(
        foreach ($kind in @('canceladas', 'pendentes')) {
            if ($kind -eq 'canceladas') {
                $records = $cancelled
                $title   = 'Cancelamentos Confirmados'
            } else {
                $records = $unconfirmed
                $title   = 'Cancelamentos a conferir'
            }

            if ($records.Count -eq 0) { continue }

            (
                '<section aria-labelledby="{0}">' +
                '<h2 class="section-title" id="{0}">{1}</h2>'
            ) -f $kind, $title
            '<p class="instrucao">Valores das notas originais, exclu&iacute;dos dos ' +
            'totais e do resumo por CFOP.</p>'

            $sortedRecords = $records |
                Sort-Object -Property DataEmissao, ChaveAcesso

            foreach ($doc in $sortedRecords) {
                '<article class="note">'
                & $noteHeader $doc

                if ($doc.Cancelada) {
                    '<p>Cancelamento: <strong>{0}</strong> &middot; Protocolo: <strong>{1}</strong></p>' -f (
                        $(
                            if ($null -eq $doc.DataCancelamento) {
                                '&mdash;'
                            } else {
                                $doc.DataCancelamento.ToString('dd/MM/yyyy HH:mm:ss', $culture)
                            }
                        ),
                        (& $encode $doc.ProtocoloCancelamento)
                    )
                } else {
                    '<p>O XML do evento dispon&iacute;vel no lote n&atilde;o confirma o cancelamento.</p>'
                }

                $modelLabel = if ($doc.Modelo -eq 55) { 'NF-e' } else { 'NFC-e' }

                '<p>Valor original da {0}: <strong>{1}</strong></p></article>' -f (
                    $modelLabel,
                    (& $number $doc.ValorNota)
                )
            }
            '</section>'
        }
    )

    if ($active.Count -eq 0) {
        $details = @('<p>Nenhuma nota para detalhar neste per&iacute;odo.</p>')
        $summary = @('<p>Nenhum item para resumir neste per&iacute;odo.</p>')
    }

    $detailsHtml = $details -join [System.Environment]::NewLine
    $summaryHtml = $summary -join [System.Environment]::NewLine
    $eventsHtml  = $events  -join [System.Environment]::NewLine
    $navLinks    = $links   -join ' '

    @"
<!doctype html>
<html lang="pt-BR">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Relat&oacute;rio Anal&iacute;tico de Documentos Fiscais Eletr&ocirc;nicos (DF-e)</title>
    <style>
        * {
            box-sizing: border-box;
        }

        body {
            margin: 0;
            color: #111;
            background: #fff;
            font: 13px/1.4 Arial, Helvetica, sans-serif;
        }

        main {
            max-width: 1100px;
            margin: 0 auto;
            padding: 14px 18px 24px;
        }

        h1, h2, h3, h4, p {
            margin: 0;
        }

        h1 {
            font-size: 14px;
        }

        h2, h3, h4 {
            font-size: 13px;
        }

        header {
            display: table;
            width: 100%;
            padding-bottom: 8px;
            border-bottom: 2px solid #222;
        }

        .hd-empresa {
            display: table-cell;
            vertical-align: top;
            width: 40%;
            padding-right: 12px;
            overflow-wrap: anywhere;
        }

        .hd-titulo {
            display: table-cell;
            vertical-align: top;
            width: 60%;
            text-align: right;
        }

        .company {
            font-size: 14px;
            font-weight: bold;
        }

        .identity {
            font-size: 12px;
        }

        .overview {
            padding: 5px 0;
            font-size: 12px;
        }

        nav {
            margin: 6px 0;
        }

        nav a {
            margin-right: 12px;
        }

        a {
            color: #23466d;
        }

        .instrucao {
            font-size: 11px;
            color: #333;
            margin-bottom: 8px;
        }

        .section-title {
            margin: 12px 0 4px;
            padding: 3px 0;
            border-bottom: 1px solid #555;
        }

        .group-title {
            margin: 8px 0 4px;
        }

        .day h4 {
            margin: 12px 0 4px;
            padding: 3px 0;
            border-bottom: 1px solid #555;
        }

        .day h4 span {
            font-size: 12px;
            font-weight: normal;
            margin-left: 6px;
        }

        .day+.day {
            margin-top: 16px;
        }

        .note {
            margin: 8px 0 16px;
        }

        .note-head>h3 {
            background: #eee;
            padding: 4px 5px;
            margin: 0 0 4px;
            font-size: 12px;
            font-weight: normal;
        }

        .note-head>p {
            margin: 1px 0;
            font-size: 12px;
        }

        .access code {
            display: inline;
            font: 12px/1.35 Consolas, "Courier New", monospace;
            word-break: break-all;
            user-select: all;
        }

        .table-wrap {
            overflow-x: auto;
            margin: 8px 0 0;
        }

        table {
            width: 100%;
            border-collapse: collapse;
            font-size: 11px;
        }

        th, td {
            padding: 3px;
            text-align: left;
            vertical-align: top;
            border-bottom: 1px solid #ddd;
        }

        th {
            white-space: normal;
            overflow-wrap: normal;
            border-color: #888;
        }

        tbody tr:nth-child(even) {
            background: #f8f8f8;
        }

        .num {
            text-align: right;
            white-space: nowrap;
            font-variant-numeric: tabular-nums;
        }

        .tax-code, .unit {
            text-align: center;
        }

        .unit {
            overflow-wrap: anywhere;
        }

        th.tax-code {
            overflow-wrap: anywhere;
        }

        .product {
            min-width: 170px;
            overflow-wrap: anywhere;
        }

        td small {
            display: block;
            font-size: 10px;
            color: #555;
        }

        .note table {
            table-layout: fixed;
            min-width: 1000px;
        }

        .note tbody tr:last-child td {
            border-bottom-color: #ddd;
        }

        .note table .note-tail>tr:first-child>td {
            border-bottom: 0;
            padding-bottom: 7px;
        }

        .note table .note-tail>.total-row>td {
            border-top: 1px solid #999;
            border-bottom: 0;
            padding: 5px 0 0;
            background: #fff;
        }

        .note-total {
            padding: 0;
            font-size: 12px;
        }

        .commercial {
            display: flex;
            justify-content: space-between;
            flex-wrap: wrap;
            gap: 2px 12px;
        }

        .invoice-total {
            margin-left: auto;
        }

        .tax-total {
            font-size: 11px;
            color: #333;
            margin-top: 3px;
        }

        .day-total {
            padding: 3px 0;
        }

        .period-total {
            text-align: right;
            padding: 5px 0;
        }

        .cfop-table tfoot th, .cfop-table tfoot td {
            border-top: 1px solid #888;
            font-weight: bold;
            background: #f0f0f0;
        }

        footer {
            border-top: 1px solid #bbb;
            margin-top: 16px;
            padding-top: 8px;
            text-align: center;
        }

        #notas {
            margin-top: 24px;
        }

        #notas>.day:first-child>h4 {
            margin-top: 0;
        }

        @media screen and (max-width: 480px) {
            main {
                padding: 10px;
            }

            .hd-empresa, .hd-titulo {
                display: block;
                width: 100%;
            }

            .hd-titulo {
                margin-top: 4px;
                text-align: left;
            }
        }

        @page {
            size: A4 landscape;
            margin: 10mm 12mm 13mm;

            @bottom-center {
                content: "|> PipeDFe";
                font: bold 10px Arial, sans-serif;
                color: #1f2937;
            }

            @bottom-right {
                content: "P\00E1gina " counter(page) " de " counter(pages);
                font: 10px Arial, sans-serif;
                color: #555;
            }
        }

        @media print {
            main {
                max-width: none;
                padding: 0;
            }

            nav, .screen-only {
                display: none;
            }

            footer {
                display: none;
            }

            .table-wrap {
                overflow: visible;
            }

            .note table {
                min-width: 0;
            }

            .product {
                min-width: 0;
            }

            th, td {
                padding: 2px;
            }

            .num {
                white-space: nowrap;
            }

            thead {
                display: table-header-group;
            }

            tr {
                page-break-inside: avoid;
            }

            .note-head {
                break-inside: avoid;
                break-after: avoid;
            }

            .note-head>h3 {
                print-color-adjust: exact;
                -webkit-print-color-adjust: exact;
            }

            .note .table-wrap {
                overflow: visible;
                break-before: avoid;
            }

            .short-note, section[aria-labelledby="canceladas"] .note {
                break-inside: avoid;
            }

            .note-tail {
                break-inside: avoid;
            }

            .note table .note-tail>.total-row {
                break-inside: avoid;
            }

            .day h4, .section-title {
                break-after: avoid;
            }

            .commercial {
                break-inside: avoid;
            }

            .note-total {
                break-inside: avoid;
            }

            .cfop-table tfoot {
                display: table-row-group;
                break-inside: avoid;
            }

            .day-total {
                break-before: avoid;
            }
        }
    </style>
</head>
<body>
    <main>
        <header>
            <div class="hd-empresa">
                <p class="company">$company</p>
                <p class="identity">CNPJ: $identifier$stateRegistration</p>
            </div>
            <div class="hd-titulo">
                <h1>Relat&oacute;rio Anal&iacute;tico de Documentos Fiscais Eletr&ocirc;nicos (DF-e)</h1>
                <p class="identity">${directionText}Per&iacute;odo de emiss&atilde;o: $start a $end</p>
            </div>
        </header>
        <div class="overview">
            Processados: <strong>$($Documents.Count)</strong> &middot; Cancelados: <strong>$($cancelled.Count)</strong>$pendingCount
        </div>
        <nav aria-label="Se&ccedil;&otilde;es do relat&oacute;rio">$navLinks</nav>
        <p class="instrucao screen-only">
            Copie a chave para a <a href="https://dfe-portal.svrs.rs.gov.br/NFE/Consulta">consulta oficial da NF-e</a>.
            Em telas estreitas, deslize a tabela para ver as demais colunas.
        </p>
        <section id="notas" aria-label="Documentos por data de emiss&atilde;o">
            $detailsHtml
        </section>
        <section aria-labelledby="cfop">
            <h2 class="section-title" id="cfop">Resumo Fiscal por CFOP</h2>
            <p class="instrucao">
                Valores dos itens consolidados por CFOP, exclu&iacute;dos os cancelamentos confirmados e os documentos a conferir.
                Incluem itens que n&atilde;o comp&otilde;em o total de produtos da nota. O travess&atilde;o indica informa&ccedil;&atilde;o
                ausente no XML. Os totalizadores consideram os valores informados. O relat&oacute;rio consolida informa&ccedil;&otilde;es
                dos documentos fiscais, sem realizar escritura&ccedil;&atilde;o ou apura&ccedil;&atilde;o de impostos.
            </p>
            $summaryHtml
        </section>
        $eventsHtml
        <footer>
            <span style="color:#00bcf2;font-weight:bold;">|&gt;</span>
            <span style="color:#1f2937;font-weight:bold;">PipeDFe</span>
        </footer>
    </main>
</body>
</html>
"@
}
