<#
.SYNOPSIS
Reads the indexed XMLs selected for the analytical HTML report.

.DESCRIPTION
Uses the selected NF-e and NFC-e XMLs and their indexed events.
Checks the XML SHA-256 before parsing and preserves fiscal values as Decimal.
Event confirmation requires a matching SEFAZ return and protocol.

.PARAMETER Cnpj
Company index identifier.

.PARAMETER Entries
Selected document entries for models 55 and 65.

.OUTPUTS
System.Management.Automation.PSCustomObject
#>
function Get-DFeAnalyticalReportData {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory)]
        [string]$Cnpj,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [pscustomobject[]]$Entries
    )

    $culture   = [System.Globalization.CultureInfo]::InvariantCulture
    $namespace = 'http://www.portalfiscal.inf.br/nfe'

    $readXml = {
        param (
            [Parameter()]
            [pscustomobject]$Entry
        )

        $path = [string]$Entry.file_path

        # Keep a read handle open through parsing so Windows denies
        # writes and replacement.
        $stream = [System.IO.File]::Open(
            $path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::Read
        )

        try {
            $hash = (Get-FileHash -InputStream $stream -Algorithm SHA256).Hash

            if ($hash -ne $Entry.sha256) {
                throw [System.IO.InvalidDataException]::new(
                    "Indexed XML hash mismatch: '$path'."
                )
            }

            Import-DFeXml -Path $path -ErrorAction Stop
        } finally {
            $stream.Dispose()
        }
    }

    $readText = {
        param (
            [Parameter()]
            [System.Xml.XmlNode]$Node,

            [Parameter()]
            [string]$XPath,

            [Parameter()]
            [System.Xml.XmlNamespaceManager]$NamespaceManager
        )

        if ($null -ne $Node) {
            $value = $Node.SelectSingleNode($XPath, $NamespaceManager)

            if ($null -ne $value -and -not
                [string]::IsNullOrWhiteSpace($value.InnerText)
            ) {
                $value.InnerText.Trim()
            }
        }
    }

    $getValue = {
        param (
            [Parameter()]
            [pscustomobject]$Object,

            [Parameter()]
            [string]$Property
        )

        if ($null -ne $Object) {
            $Object.$Property
        }
    }

    foreach ($entry in $Entries) {
        $xml    = & $readXml $entry
        $fiscal = Get-DFeNFeFiscalData -Xml $xml -ErrorAction Stop
        $key    = [string]$entry.chave_acesso

        if ($fiscal.ChaveAcesso -cne $key -or
            [int]$fiscal.Modelo -ne [int]$entry.modelo
        ) {
            throw [System.IO.InvalidDataException]::new(
                "Invalid NF-e identity for indexed key '$key'."
            )
        }

        $eventDate               = $null
        $eventProtocol           = $null
        $unconfirmedCancellation = $false

        $eventEntries = @(
            Get-DFeEventoEntry -Cnpj $Cnpj -ChavePai $key -ErrorAction Stop
        )

        foreach ($eventEntry in $eventEntries) {
            if ($eventEntry.evento_tipo -notin @(
                    'Cancelamento'
                    'CancelamentoSubstituicao'
                )
            ) {
                continue
            }

            $eventXml = & $readXml $eventEntry
            $eventNs  = [System.Xml.XmlNamespaceManager]::new($eventXml.NameTable)
            $eventNs.AddNamespace('n', $namespace)

            $request  = $eventXml.SelectSingleNode(
                '/n:procEventoNFe/n:evento/n:infEvento', $eventNs
            )

            $response = $eventXml.SelectSingleNode(
                '/n:procEventoNFe/n:retEvento/n:infEvento', $eventNs
            )

            $eventType = if ($eventEntry.evento_tipo -eq 'Cancelamento') {
                '110111'
            } else {
                '110112'
            }

            if ($null -eq $request -or $null -eq $response -or
                (& $readText $response 'n:chNFe' $eventNs) -ne $key
            ) {
                $unconfirmedCancellation = $true
                continue
            }

            $protocol = $response.SelectSingleNode('n:nProt', $eventNs)
            $date     = $response.SelectSingleNode('n:dhRegEvento', $eventNs)
            $matched  = $true

            foreach ($field in @('chNFe', 'tpEvento', 'nSeqEvento', 'tpAmb')) {
                $requestField  = & $readText $request  "n:$field" $eventNs
                $responseField = & $readText $response "n:$field" $eventNs

                if ([string]::IsNullOrWhiteSpace($requestField) -or
                    $requestField -ne $responseField
                ) {
                    $matched = $false
                    break
                }
            }

            $ambienteNode   = $request.SelectSingleNode('n:tpAmb', $eventNs)
            $tipoEventoNode = $request.SelectSingleNode('n:tpEvento', $eventNs)
            $cStat          = & $readText $response 'n:cStat' $eventNs

            if (-not $matched -or
                $fiscal.Identificacao.Ambiente -ne $ambienteNode.InnerText -or
                $tipoEventoNode.InnerText -ne $eventType -or
                $cStat -notin @('135', '155') -or
                $null -eq $protocol -or
                $protocol.InnerText -notmatch '^[0-9]{15,17}$' -or
                $null -eq $date
            ) {
                $unconfirmedCancellation = $true
                continue
            }

            $registeredAt = [System.DateTimeOffset]::Parse($date.InnerText, $culture)

            if ($null -eq $eventDate -or $registeredAt -lt $eventDate) {
                $eventDate     = $registeredAt
                $eventProtocol = $protocol.InnerText
            }
        }

        $cancelled = $null -ne $eventProtocol
        $totals    = $fiscal.Totais

        if ($null -eq $totals -or $null -eq $totals.VNF) {
            throw [System.IO.InvalidDataException]::new(
                "Missing declared invoice total for '$key'."
            )
        }

        $items = @(
            foreach ($detail in $fiscal.Itens) {
                $product = $detail.Produto
                $tax     = $detail.Tributos

                [PSCustomObject]@{
                    Item          = $detail.Numero
                    Codigo        = $product.Codigo
                    Produto       = $product.Descricao
                    NCM           = $product.NCM
                    CFOP          = $product.CFOP
                    Origem        = & $getValue $tax.ICMS 'Orig'
                    CST           = & $getValue $tax.ICMS 'CST'
                    CSOSN         = & $getValue $tax.ICMS 'CSOSN'
                    Quantidade    = $product.Quantidade
                    Unidade       = $product.Unidade
                    ValorUnitario = $product.ValorUnitario
                    ValorProduto  = $product.ValorProduto
                    IndTotal      = $product.IndTotal
                    BaseIcms      = & $getValue $tax.ICMS 'VBC'
                    AliqIcms      = & $getValue $tax.ICMS 'PICMS'
                    Icms          = & $getValue $tax.ICMS 'VICMS'
                    IcmsST        = & $getValue $tax.ICMS 'VICMSST'
                    IPI           = & $getValue $tax.IPI 'VIPI'
                    PIS           = & $getValue $tax.PIS 'VPIS'
                    Cofins        = & $getValue $tax.COFINS 'VCOFINS'
                    II            = & $getValue $tax.II 'VII'
                    IOF           = & $getValue $tax.II 'VIOF'
                    BaseII        = & $getValue $tax.II 'VBC'
                    DespAduaneira = & $getValue $tax.II 'VDespAdu'
                    IBS           = & $getValue $tax.IBSCBS 'VIBS'
                    CBS           = & $getValue $tax.IBSCBS 'VCBS'
                }
            }
        )

        if ($items.Count -eq 0) {
            throw [System.IO.InvalidDataException]::new(
                "No fiscal items found for '$key'."
            )
        }

        $direction = [string]$entry.direcao

        if ([int]$entry.modelo -eq 55 -and
            $direction -notin @('Entrada', 'Saida')
        ) {
            throw [System.IO.InvalidDataException]::new(
                "Invalid indexed direction for '$key'."
            )
        }

        $otherParty     = if ($direction -eq 'Entrada') {
            $fiscal.Emitente
        } else {
            $fiscal.Destinatario
        }

        $identifier     = $null
        $identifierType = $null

        if ($null -ne $otherParty) {
            foreach ($property in @('Cnpj', 'Cpf', 'IdEstrangeiro')) {
                if (-not [string]::IsNullOrWhiteSpace($otherParty.$property)) {
                    $identifier     = $otherParty.$property
                    $identifierType = $property
                    break
                }
            }
        }

        $dhEmissao = [System.DateTimeOffset]::Parse(
            $fiscal.Identificacao.DhEmi, $culture
        )

        [PSCustomObject]@{
            Modelo                   = [int]$entry.modelo
            Direcao                  = $direction
            ChaveAcesso              = $key
            DataEmissao              = $dhEmissao
            Numero                   = $fiscal.Identificacao.Numero
            Serie                    = $fiscal.Identificacao.Serie
            Natureza                 = $fiscal.Identificacao.NaturezaOperacao
            Contraparte              = & $getValue $otherParty 'RazaoSocial'
            DocumentoContraparte     = $identifier
            TipoDocumentoContraparte = $identifierType
            Cancelada                = $cancelled
            CancelamentoSemConfirmar = $unconfirmedCancellation -and -not $cancelled
            DataCancelamento         = $eventDate
            ProtocoloCancelamento    = $eventProtocol
            ValorProdutos            = $totals.VProd
            ValorNota                = $totals.VNF
            Tributos                 = [ordered]@{
                ICMS              = $totals.VICMS
                'ICMS-ST'         = $totals.VST
                FCP               = $totals.VFCP
                IPI               = $totals.VIPI
                PIS               = $totals.VPIS
                COFINS            = $totals.VCOFINS
                II                = $totals.VII
                IBS               = & $getValue $totals.IBSCBSTot 'VIBS'
                CBS               = & $getValue $totals.IBSCBSTot 'VCBS'
                Frete             = $totals.VFrete
                Seguro            = $totals.VSeg
                Desconto          = $totals.VDesc
                'Outras despesas' = $totals.VOutro
            }
            Itens                    = $items
        }
    }
}
