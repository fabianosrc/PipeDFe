<#
.SYNOPSIS
Exports the monthly DFe report to a standalone XLSX workbook.

.DESCRIPTION
Creates a worksheet for each document model with report data. NF-e and
NFC-e contain the supplied CFOP summary and item details. NFCom, CT-e,
MDF-e, and national NFS-e contain one row per supplied document.
Ocorrências is included when sequence ranges are supplied. A period with
no data has one Resumo sheet describing the empty result.

The exporter does not query the index, select a period, recalculate
totals, or infer missing document numbers.

Identifiers and descriptions are written as text. Counts and amounts
are written as numeric cells. Missing amounts are left blank.

The destination directory must exist. The workbook is staged in that
directory and published only after the package is closed. An existing
destination is never replaced.

.PARAMETER LiteralPath
Destination XLSX file in an existing filesystem directory.

.PARAMETER Cnpj
Normalized company CNPJ shown on all worksheets.

.PARAMETER StartDate
Inclusive start of the period represented by ReportData.

.PARAMETER EndDate
Inclusive end of the period represented by ReportData.

.PARAMETER ReportData
Result returned by Get-DFeNFeCfopReportData.

.PARAMETER DocumentEntries
Indexed documents for the period as returned by Get-DFeDocumentEntry.
Only NFCom, CT-e, and MDF-e are read from this collection.

.PARAMETER NFSeEntries
National NFS-e documents for the period as returned by Get-DFeNFSeEntry.

.PARAMETER Gaps
Sequence ranges for the period as returned by Get-DFeSequenceGap.

.OUTPUTS
System.String
The full path of the published workbook.
#>
function Export-DFeCfopReportXlsx {
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$LiteralPath,

        [Parameter(Mandatory)]
        [ValidatePattern('\A(?-i:[A-Z0-9]{14})\z')]
        [string]$Cnpj,

        [Parameter(Mandatory)]
        [System.DateTimeOffset]$StartDate,

        [Parameter(Mandatory)]
        [System.DateTimeOffset]$EndDate,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject]$ReportData,

        [Parameter()]
        [AllowEmptyCollection()]
        [pscustomobject[]]$DocumentEntries = @(),

        [Parameter()]
        [AllowEmptyCollection()]
        [pscustomobject[]]$NFSeEntries = @(),

        [Parameter()]
        [AllowEmptyCollection()]
        [pscustomobject[]]$Gaps = @()
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

    $provider = $null
    $drive    = $null

    $unresolvedPath = $ExecutionContext.SessionState.Path

    $path = $unresolvedPath.GetUnresolvedProviderPathFromPSPath(
        $LiteralPath,
        [ref]$provider,
        [ref]$drive
    )

    if ($provider.Name -ne 'FileSystem' -or
        [System.IO.Path]::GetExtension($path) -ine '.xlsx') {
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                [System.ArgumentException]::new(
                    'The destination must be a filesystem path with an .xlsx extension.',
                    'LiteralPath'
                ),
                'InvalidLiteralPath',
                [System.Management.Automation.ErrorCategory]::InvalidArgument,
                $LiteralPath
            )
        )
    }

    $directory = [System.IO.Path]::GetDirectoryName($path)

    if (-not [System.IO.Directory]::Exists($directory)) {
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                [System.IO.DirectoryNotFoundException]::new(
                    "The destination directory '$directory' does not exist."
                ),
                'DestinationDirectoryNotFound',
                [System.Management.Automation.ErrorCategory]::ObjectNotFound,
                $directory
            )
        )
    }

    if ([System.IO.File]::Exists($path)) {
        $PSCmdlet.ThrowTerminatingError(
            [System.Management.Automation.ErrorRecord]::new(
                [System.IO.IOException]::new(
                    "The workbook '$path' already exists."
                ),
                'WorkbookAlreadyExists',
                [System.Management.Automation.ErrorCategory]::ResourceExists,
                $path
            )
        )
    }

    foreach ($collection in 'ResumoPorCFOP', 'Itens') {
        $property = $ReportData.PSObject.Properties[$collection]

        if ($null -eq $property -or $property.Value -isnot [array]) {
            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.ArgumentException]::new(
                        "ReportData must expose '$collection' as an array.",
                        'ReportData'
                    ),
                    'InvalidReportData',
                    [System.Management.Automation.ErrorCategory]::InvalidArgument,
                    $ReportData
                )
            )
        }

        foreach ($row in $property.Value) {
            if ($null -eq $row -or $row.Modelo -notin @(55, 65)) {
                $PSCmdlet.ThrowTerminatingError(
                    [System.Management.Automation.ErrorRecord]::new(
                        [System.ArgumentException]::new(
                            'ReportData contains a row outside the NF-e and NFC-e contract.',
                            'ReportData'
                        ),
                        'InvalidReportData',
                        [System.Management.Automation.ErrorCategory]::InvalidArgument,
                        $row
                    )
                )
            }
        }
    }

    Add-Type -AssemblyName 'System.IO.Compression' -ErrorAction Stop

    $culture  = [System.Globalization.CultureInfo]::InvariantCulture
    $encoding = [System.Text.UTF8Encoding]::new($false)

    $sheetNamespace        = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'
    $relationshipNamespace = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'
    $packageNamespace      = 'http://schemas.openxmlformats.org/package/2006/relationships'

    $startLabel = $StartDate.ToString('dd/MM/yyyy', $culture)
    $endLabel   = $EndDate.ToString('dd/MM/yyyy', $culture)

    $cfopModels = @(
        foreach ($row in $ReportData.Itens) { $row.Modelo }
        foreach ($row in $ReportData.ResumoPorCFOP) { $row.Modelo }
    )
    $documentModels = @(
        foreach ($entry in $DocumentEntries) { $entry.modelo }
    )

    $sheetDefinitions = @(
        @{
            Name  = 'NF-e'
            Model = 55
            Kind  = 'Cfop'
        }
        @{
            Name  = 'NFC-e'
            Model = 65
            Kind  = 'Cfop'
        }
        @{
            Name  = 'NFCom'
            Model = 62
            Kind  = 'Document'
        }
        @{
            Name  = 'CT-e'
            Model = 57
            Kind  = 'Document'
        }
        @{
            Name  = 'MDF-e'
            Model = 58
            Kind  = 'Document'
        }
        @{
            Name = 'NFS-e'
            Kind = 'NFSe'
        }
        @{
            Name = 'Ocorrências'
            Kind = 'Gap'
        }
    )

    $sheets = @(
        foreach ($definition in $sheetDefinitions) {
            $hasData = switch ($definition.Kind) {
                'Cfop'     { $definition.Model -in $cfopModels }
                'Document' { $definition.Model -in $documentModels }
                'NFSe'     { $NFSeEntries.Count -gt 0 }
                'Gap'      { $Gaps.Count -gt 0 }
            }

            if ($hasData) {
                $definition
            }
        }
    )

    if ($sheets.Count -eq 0) {
        $sheets = @(@{ Name = 'Resumo'; Kind = 'Empty' })
    }

    $columnWidths = @{
        Cfop     = @(52, 34, 20, 30, 10, 20, 52, 12, 23, 12)
        Document = @(52, 34, 18, 10)
        NFSe     = @(57, 19, 34, 34, 18, 22, 25, 24)
        Gap      = @(23, 15, 12, 22, 22)
        Empty    = @(53, 19, 19)
    }

    # Indices in the cellXfs table below.
    $cellStyles = @{
        Title = 1
        Section = 2
        Header = 3
        Alternate = 4
        Currency = 5
        AlternateCurrency = 6
    }

    $sheetElements = @(
        for ($index = 0; $index -lt $sheets.Count; $index++) {
            '<sheet name="{0}" sheetId="{1}" r:id="rId{1}"/>' -f (
                $sheets[$index].Name
            ), ($index + 1)
        }
    ) -join [System.Environment]::NewLine

    $sheetRelationships = @(
        for ($number = 1; $number -le $sheets.Count; $number++) {
            '<Relationship Id="rId{0}" Type="{1}/worksheet" Target="worksheets/sheet{0}.xml"/>' -f (
                $number
            ), $relationshipNamespace
        }
    ) -join [System.Environment]::NewLine

    $sheetContentTypes = @(
        for ($number = 1; $number -le $sheets.Count; $number++) {
            '<Override PartName="/xl/worksheets/sheet{0}.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>' -f $number
        }
    ) -join [System.Environment]::NewLine

    $parts = [ordered]@{
        '[Content_Types].xml' = @"
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="xml" ContentType="application/xml"/>
  <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
  <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
$sheetContentTypes
</Types>
"@
        '_rels/.rels' = @"
<Relationships xmlns="$packageNamespace">
  <Relationship Id="rId1" Type="$relationshipNamespace/officeDocument" Target="xl/workbook.xml"/>
</Relationships>
"@
        'xl/workbook.xml' = @"
<workbook xmlns="$sheetNamespace" xmlns:r="$relationshipNamespace">
  <bookViews><workbookView/></bookViews>
  <sheets>
$sheetElements
  </sheets>
</workbook>
"@
        'xl/_rels/workbook.xml.rels' = @"
<Relationships xmlns="$packageNamespace">
$sheetRelationships
  <Relationship Id="rIdStyles" Type="$relationshipNamespace/styles" Target="styles.xml"/>
</Relationships>
"@
        'xl/styles.xml' = @'
<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
  <numFmts count="1"><numFmt numFmtId="164" formatCode="&quot;R$&quot; #,##0.00"/></numFmts>
  <fonts count="4">
    <font><sz val="11"/><color rgb="FF18283D"/><name val="Calibri"/></font>
    <font><b/><sz val="16"/><color rgb="FFFFFFFF"/><name val="Calibri"/></font>
    <font><b/><sz val="11"/><color rgb="FF17375E"/><name val="Calibri"/></font>
    <font><b/><sz val="11"/><color rgb="FFFFFFFF"/><name val="Calibri"/></font>
  </fonts>
  <fills count="6">
    <fill><patternFill patternType="none"/></fill>
    <fill><patternFill patternType="gray125"/></fill>
    <fill><patternFill patternType="solid"><fgColor rgb="FF17375E"/><bgColor indexed="64"/></patternFill></fill>
    <fill><patternFill patternType="solid"><fgColor rgb="FFE4EDF7"/><bgColor indexed="64"/></patternFill></fill>
    <fill><patternFill patternType="solid"><fgColor rgb="FF294D75"/><bgColor indexed="64"/></patternFill></fill>
    <fill><patternFill patternType="solid"><fgColor rgb="FFF3F6FA"/><bgColor indexed="64"/></patternFill></fill>
  </fills>
  <borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>
  <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
  <cellXfs count="7">
    <xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>
    <xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1" applyAlignment="1"><alignment vertical="center"/></xf>
    <xf numFmtId="0" fontId="2" fillId="3" borderId="0" xfId="0" applyFont="1" applyFill="1"/>
    <xf numFmtId="0" fontId="3" fillId="4" borderId="0" xfId="0" applyFont="1" applyFill="1" applyAlignment="1"><alignment vertical="center" wrapText="1"/></xf>
    <xf numFmtId="0" fontId="0" fillId="5" borderId="0" xfId="0" applyFill="1"/>
    <xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>
    <xf numFmtId="164" fontId="0" fillId="5" borderId="0" xfId="0" applyNumberFormat="1" applyFill="1"/>
  </cellXfs>
  <cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>
</styleSheet>
'@
    }

    $writeRow = {
        param (
            [Parameter()]
            [System.Xml.XmlWriter]$Writer,

            [Parameter()]
            [int]$RowNumber,

            [Parameter()]
            [object[]]$Cells,

            [Parameter()]
            [int]$Style
        )

        $rowLabel = $RowNumber.ToString($culture)
        $Writer.WriteStartElement('row', $sheetNamespace)
        $Writer.WriteAttributeString('r', $rowLabel)

        if ($Style -eq $cellStyles.Title -or $Style -eq $cellStyles.Header) {
            $Writer.WriteAttributeString('ht', '28')
            $Writer.WriteAttributeString('customHeight', '1')
        }

        for ($index = 0; $index -lt $Cells.Count; $index++) {
            $value = $Cells[$index]

            if ($null -eq $value) {
                continue
            }

            $column = [char]([int][char]'A' + $index)
            $Writer.WriteStartElement('c', $sheetNamespace)
            $Writer.WriteAttributeString('r', ([string]$column + $rowLabel))

            $cellStyle = if ($Style -ne 0) {
                $Style
            } elseif ($value -is [decimal]) {
                if ($RowNumber % 2 -eq 0) {
                    $cellStyles.AlternateCurrency
                } else {
                    $cellStyles.Currency
                }
            } elseif ($RowNumber -gt 5 -and $RowNumber % 2 -eq 0) {
                $cellStyles.Alternate
            } else {
                0
            }

            if ($cellStyle -ne 0) {
                $Writer.WriteAttributeString('s', $cellStyle.ToString($culture))
            }

            if ($value -is [int] -or $value -is [decimal]) {
                $Writer.WriteElementString('v', $sheetNamespace, $value.ToString($culture))
            } else {
                $Writer.WriteAttributeString('t', 'inlineStr')
                $Writer.WriteStartElement('is', $sheetNamespace)
                $Writer.WriteStartElement('t', $sheetNamespace)
                $Writer.WriteAttributeString(
                    'xml', 'space', 'http://www.w3.org/XML/1998/namespace', 'preserve'
                )

                # Preserve literal text that resembles a SpreadsheetML escape.
                $cellText = [regex]::Replace(
                    [string]$value, '(?i)_(?=x[0-9a-f]{4}_)', '_x005F_'
                )

                $Writer.WriteString($cellText)
                $Writer.WriteEndElement()
                $Writer.WriteEndElement()
            }

            $Writer.WriteEndElement()
        }

        $Writer.WriteEndElement()
    }

    $writeSupplementalSheet = {
        param (
            [Parameter()]
            [System.Xml.XmlWriter]$Writer,

            [Parameter()]
            [hashtable]$Sheet,

            [Parameter()]
            [pscustomobject[]]$DocumentEntries,

            [Parameter()]
            [pscustomobject[]]$NFSeEntries,

            [Parameter()]
            [pscustomobject[]]$Gaps
        )

        $rowNumber = 6

        switch ($Sheet.Kind) {
            'Document' {
                & $writeRow $Writer 5 @('Chave de acesso', 'Emissão', 'Número', 'Série') $cellStyles.Header

                foreach ($record in $DocumentEntries) {
                    if ($record.modelo -ne $Sheet.Model) {
                        continue
                    }

                    $documentNumber = if ($null -ne $record.ndoc) {
                        [string]$record.ndoc
                    }

                    # The array literal collapses $null elements; use [object[]] to
                    # preserve the slot for Número when ndoc is absent.
                    $cells    = [object[]]::new(4)
                    $cells[0] = [string]$record.chave_acesso
                    $cells[1] = [string]$record.dh_emi
                    $cells[2] = $documentNumber
                    $cells[3] = $record.serie

                    & $writeRow $Writer $rowNumber $cells

                    $rowNumber++
                }
            }

            'NFSe' {
                & $writeRow $Writer 5 @(
                    'Chave de acesso', 'Número', 'Geração da NFS-e',
                    'Emissão da DPS', 'Competência', 'Código de situação',
                    'Valor dos serviços (R$)', 'Valor líquido (R$)'
                ) $cellStyles.Header

                $numberStyle = [System.Globalization.NumberStyles]::Float

                foreach ($record in $NFSeEntries) {
                    $cells    = [object[]]::new(8)
                    $cells[0] = [string]$record.chave_acesso
                    $cells[1] = [string]$record.numero
                    $cells[2] = [string]$record.gerado_em
                    $cells[3] = [string]$record.dps_emitida_em
                    $cells[4] = [string]$record.competencia
                    $cells[5] = $record.status

                    if (-not [string]::IsNullOrWhiteSpace([string]$record.valor_servico)) {
                        $cells[6] = [decimal]::Parse($record.valor_servico, $numberStyle, $culture)
                    }

                    if (-not [string]::IsNullOrWhiteSpace([string]$record.valor_liquido)) {
                        $cells[7] = [decimal]::Parse($record.valor_liquido, $numberStyle, $culture)
                    }

                    & $writeRow $Writer $rowNumber $cells

                    $rowNumber++
                }
            }

            'Gap' {
                & $writeRow $Writer 5 @('Tipo', 'Modelo', 'Série', 'Número inicial', 'Número final') $cellStyles.Header

                foreach ($record in $Gaps) {
                    & $writeRow $Writer $rowNumber @(
                        [string]$record.Tipo
                        [string]$record.Especie
                        [string]$record.Serie
                        [int]$record.Inicial
                        [int]$record.Final
                    )

                    $rowNumber++
                }
            }
        }

        return ($rowNumber - 1)
    }

    $tempName = '.pipedfe-{0}.tmp' -f [guid]::NewGuid().ToString('N')
    $tempPath = [System.IO.Path]::Combine($directory, $tempName)
    $stream   = $null

    try {
        $stream = [System.IO.File]::Open(
            $tempPath,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None
        )

        try {
            $archive = [System.IO.Compression.ZipArchive]::new(
                $stream, [System.IO.Compression.ZipArchiveMode]::Create, $true
            )

            try {
                foreach ($part in $parts.GetEnumerator()) {
                    $entry = $archive.CreateEntry($part.Key)
                    $entryStream = $entry.Open()

                    try {
                        $bytes = $encoding.GetBytes($part.Value)
                        $entryStream.Write($bytes, 0, $bytes.Length)
                    } finally {
                        $entryStream.Dispose()
                    }
                }

                $settings = [System.Xml.XmlWriterSettings]::new()
                $settings.Encoding = $encoding

                $sheetNumber = 0

                foreach ($sheet in $sheets) {
                    $sheetNumber++
                    $entryPath = 'xl/worksheets/sheet{0}.xml' -f $sheetNumber
                    $sheetStream = $archive.CreateEntry($entryPath).Open()

                    try {
                        $writer = [System.Xml.XmlWriter]::Create($sheetStream, $settings)

                        try {
                            $writer.WriteStartDocument()
                            $writer.WriteStartElement('worksheet', $sheetNamespace)
                            $widths = $columnWidths[$sheet.Kind]
                            $lastColumn = [char]([int][char]'A' + $widths.Count - 1)
                            $frozenRows = if ($sheet.Kind -in @('Cfop', 'Empty')) { 3 } else { 5 }

                            $writer.WriteStartElement('sheetViews', $sheetNamespace)
                            $writer.WriteStartElement('sheetView', $sheetNamespace)
                            $writer.WriteAttributeString('workbookViewId', '0')
                            $writer.WriteAttributeString('showGridLines', '0')
                            $writer.WriteStartElement('pane', $sheetNamespace)
                            $writer.WriteAttributeString('ySplit', $frozenRows.ToString($culture))
                            $writer.WriteAttributeString('topLeftCell', ('A{0}' -f ($frozenRows + 1)))
                            $writer.WriteAttributeString('activePane', 'bottomLeft')
                            $writer.WriteAttributeString('state', 'frozen')
                            $writer.WriteEndElement()
                            $writer.WriteEndElement()
                            $writer.WriteEndElement()

                            $writer.WriteStartElement('cols', $sheetNamespace)
                            for ($column = 0; $column -lt $widths.Count; $column++) {
                                $position = ($column + 1).ToString($culture)
                                $writer.WriteStartElement('col', $sheetNamespace)
                                $writer.WriteAttributeString('min', $position)
                                $writer.WriteAttributeString('max', $position)
                                $writer.WriteAttributeString('width', $widths[$column].ToString($culture))
                                $writer.WriteAttributeString('customWidth', '1')
                                $writer.WriteEndElement()
                            }
                            $writer.WriteEndElement()

                            $writer.WriteStartElement('sheetData', $sheetNamespace)

                            & $writeRow $writer 1 @('Relatório de fechamento fiscal') $cellStyles.Title
                            & $writeRow $writer 2 @('CNPJ', $Cnpj)
                            & $writeRow $writer 3 @('Período', $startLabel, $endLabel)

                            $filterHeader = 0
                            $lastDataRow = 0

                            if ($sheet.Kind -eq 'Cfop') {
                                $model = $sheet.Model

                                & $writeRow $writer 5 @('Resumo por CFOP') $cellStyles.Section
                                & $writeRow $writer 6 @(
                                    'CFOP', 'Itens', 'Itens sem valor',
                                    'Valor bruto dos produtos (R$)'
                                ) $cellStyles.Header

                                $rowNumber = 7

                                foreach ($row in $ReportData.ResumoPorCFOP) {
                                    if ($row.Modelo -ne $model) {
                                        continue
                                    }

                                    if ($rowNumber -gt 1048576) {
                                        $PSCmdlet.ThrowTerminatingError(
                                            [System.Management.Automation.ErrorRecord]::new(
                                                [System.IO.InvalidDataException]::new(
                                                    'The report exceeds the worksheet row limit.'
                                                ),
                                                'WorksheetRowLimitExceeded',
                                                [System.Management.Automation.ErrorCategory]::LimitsExceeded,
                                                $rowNumber
                                            )
                                        )
                                    }

                                    $cfop = if ([string]::IsNullOrWhiteSpace($row.CFOP)) {
                                        'Não informado'
                                    } else {
                                        [string]$row.CFOP
                                    }

                                    & $writeRow $writer $rowNumber @(
                                        $cfop
                                        [int]$row.Quantidade
                                        [int]$row.ItensSemValor
                                        [decimal]$row.ValorProdutos
                                    )

                                    $rowNumber++
                                }

                                $rowNumber++
                                & $writeRow $writer $rowNumber @('Detalhamento por item') $cellStyles.Section
                                $rowNumber++

                                $filterHeader = $rowNumber
                                & $writeRow $writer $rowNumber @(
                                    'Chave de acesso', 'Emissão', 'Número', 'Série', 'Item'
                                    'Código do produto', 'Descrição', 'CFOP', 'Valor bruto (R$)', 'indTot'
                                ) $cellStyles.Header

                                $rowNumber++

                                foreach ($item in $ReportData.Itens) {
                                    if ($item.Modelo -ne $model) {
                                        continue
                                    }

                                    if ($rowNumber -gt 1048576) {
                                        $PSCmdlet.ThrowTerminatingError(
                                            [System.Management.Automation.ErrorRecord]::new(
                                                [System.IO.InvalidDataException]::new(
                                                    'The report exceeds the worksheet row limit.'
                                                ),
                                                'WorksheetRowLimitExceeded',
                                                [System.Management.Automation.ErrorCategory]::LimitsExceeded,
                                                $rowNumber
                                            )
                                        )
                                    }

                                    $productValue = if ($null -ne $item.ValorProduto) {
                                        [decimal]$item.ValorProduto
                                    }

                                    # The array literal collapses $null elements, shifting subsequent
                                    # column indices. A typed [object[]] cast preserves the $null slot
                                    # so $productValue stays at index 8 (column I) even when absent.
                                    $cells = [object[]]::new(10)
                                    $cells[0] = [string]$item.ChaveAcesso
                                    $cells[1] = [string]$item.DataEmissao
                                    $cells[2] = [string]$item.Numero
                                    $cells[3] = [string]$item.Serie
                                    $cells[4] = [int]$item.Item
                                    $cells[5] = [string]$item.CodigoProduto
                                    $cells[6] = [string]$item.Descricao
                                    $cells[7] = [string]$item.CFOP
                                    $cells[8] = $productValue
                                    $cells[9] = [string]$item.IndCompoeTotal

                                    & $writeRow $writer $rowNumber $cells

                                    $rowNumber++
                                }
                                $lastDataRow = $rowNumber - 1
                            } elseif ($sheet.Kind -eq 'Empty') {
                                & $writeRow $writer 5 @('Nenhum documento ou ocorrência no período.')
                            } else {
                                $filterHeader = 5
                                $lastDataRow = & $writeSupplementalSheet $writer $sheet $DocumentEntries $NFSeEntries $Gaps
                            }

                            $writer.WriteEndElement()

                            if ($filterHeader -gt 0 -and $lastDataRow -gt $filterHeader) {
                                $writer.WriteStartElement('autoFilter', $sheetNamespace)
                                $writer.WriteAttributeString(
                                    'ref', ('A{0}:{1}{2}' -f $filterHeader, $lastColumn, $lastDataRow)
                                )
                                $writer.WriteEndElement()
                            }

                            $writer.WriteStartElement('mergeCells', $sheetNamespace)
                            $writer.WriteAttributeString('count', '1')
                            $writer.WriteStartElement('mergeCell', $sheetNamespace)
                            $writer.WriteAttributeString('ref', ('A1:{0}1' -f $lastColumn))
                            $writer.WriteEndElement()
                            $writer.WriteEndElement()

                            $writer.WriteEndElement()
                            $writer.WriteEndDocument()
                        } finally {
                            $writer.Dispose()
                        }
                    } finally {
                        $sheetStream.Dispose()
                    }
                }
            } finally {
                $archive.Dispose()
            }
        } finally {
            $stream.Dispose()
        }

        # File.Move also protects a destination created by another process.
        [System.IO.File]::Move($tempPath, $path)
        $path
    } finally {
        if ([System.IO.File]::Exists($tempPath)) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
    }
}
