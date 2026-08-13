<#
.SYNOPSIS
Extracts metadata from a DFe XML file.

.DESCRIPTION
Loads and inspects a DFe XML file, classifies its document type,
and extracts fiscal metadata from its content.

The XML content is the only source of truth. Filename conventions
are ignored.

The function does not resolve duplicates or priorities. It only
describes the physical XML document.

Returns $null when:
  - The file cannot be loaded or parsed.
  - The document type cannot be determined by Get-DFeDocumentInfo.
  - The document namespace cannot be determined.
  - For Documento: the root is absent from DFeExtractionMap (configuration bug),
    the expected info node is absent, or Get-DFeAccessKey returns no output.

Supported document types (via DFeDocumentMap):
  NF-e   (modelo 55) - nfeProc   / NFe
  CT-e   (modelo 57) - cteProc   / CTe    (CTeOS also supported)
  MDF-e  (modelo 58) - mdfeProc  / MDFe
  NFCom  (modelo 62) - nfcomProc / NFCom

Supported evento types (via DFeDocumentMap):
  procEventoNFe
  procEventoCTe
  procEventoMDFe
  procEventoNFCom

Supported inutilizacao types (via DFeDocumentMap):
  inutNFe
  retInutNFe
  procInutNFe

.PARAMETER Path
Full path to the XML file.

.OUTPUTS
PSCustomObject

  File       [System.IO.FileInfo] - source file
  Tipo       [TipoXmlDFe]         - Documento, Evento, or Inutilizacao
  Modelo     [ModeloDFe]          - fiscal model, or $null when undetermined
  Root       [string]             - XML root element local name
  IsProc     [bool]               - true when the root ends with Proc
  Chave      [string]             - 44-digit chave de acesso (Documento only)
  ChavePai   [string]             - parent chave de acesso (Evento only)
  EventoTipo [DFeEvento]          - resolved semantic event type (Evento only)
  TpEvento   [string]             - raw tpEvento code from XML (Evento only)
  DescEvento [string]             - descEvento from XML (Evento only)
  DhEmi      [string]             - emission datetime (Documento only)
  Ndoc       [string]             - document number (Documento only)
  Serie      [string]             - serie (Documento and Inutilizacao)
  NNFIni     [string]             - first number in inutilized range (Inutilizacao only)
  NNFFin     [string]             - last number in inutilized range (Inutilizacao only)
  IdInut     [string]             - inutilizacao identifier from infInut/@Id (Inutilizacao only)
  cStat      [string]             - SEFAZ status code (procInutNFe only)
  xMotivo    [string]             - SEFAZ status description (procInutNFe only)

Fields not applicable to the document type are $null.

.EXAMPLE
PS C:\> $meta = Get-DFeXmlMetadata -Path 'C:\DFe\nfeProc.xml'

Extracts metadata from a processed NF-e file.

.EXAMPLE
PS C:\> $metas = Get-ChildItem -Path $folder -Filter '*.xml' |
>> ForEach-Object { Get-DFeXmlMetadata -Path $_.FullName } |
>> Where-Object { $null -ne $_ }

Extracts metadata from all XML files in a folder, discarding unrecognized files.

.NOTES
Private dependencies:
  Import-DFeXml
  Get-DFeDocumentInfo
  Get-DFeDocumentNamespace
  Get-DFeAccessKey
  Resolve-DFeEvento
  Select-XmlNode
  DFeDocumentMap   (classification)
  DFeExtractionMap (InfoNode + IdPrefix for Documento roots)
  DFeEventoMap     (event code resolution used by Resolve-DFeEvento)

If a root is classified as Documento in DFeDocumentMap but has no entry in
DFeExtractionMap, the function emits a warning and returns $null. This is a
configuration bug, not a recoverable condition.
#>
function Get-DFeXmlMetadata {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseSingularNouns',
        '',
        Justification = 'Metadata is an uncountable noun.'
    )]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    process {
        $file = Get-Item -LiteralPath $Path -ErrorAction Stop
        $xml = Import-DFeXml -Path $file.FullName

        $docInfo = Get-DFeDocumentInfo -Xml $xml

        if ($null -eq $docInfo) {
            return
        }

        $root = $xml.DocumentElement.LocalName

        $namespace = Get-DFeDocumentNamespace -Xml $xml

        if ($null -eq $namespace) {
            return
        }

        # XPath expressions require a namespace prefix when querying namespaced XML.
        # The prefix 'dfe' is local to this function and does not need to match
        # the prefix used by the source document.
        $nsm = [System.Xml.XmlNamespaceManager]::new($xml.NameTable)
        $nsm.AddNamespace('dfe', $namespace)

        # Reads the InnerText of the first matching element via XPath.
        #
        # Defined as a scriptblock instead of a nested function to avoid PS 5.1
        # scoping issues. Captures $xml and $nsm from the enclosing scope.
        $getText = {
            param ([string]$XPath)

            $nodeParams = @{
                XmlNode      = $xml
                XPath        = $XPath
                XmlNsManager = $nsm
            }

            $node = Select-XmlNode @nodeParams

            if ($null -ne $node) {
                $node.InnerText.Trim()
            } else {
                $null
            }
        }

        # Evento
        if ($docInfo.Tipo -eq [TipoXmlDFe]::Evento) {
            # tpEvento is read from the original evento element, not from
            # retEvento. Each model uses a different envelope element name:
            #   NF-e  -> evento
            #   CT-e  -> eventoCTe
            #   MDF-e -> eventoMDFe
            #   NFCom -> eventoNFCom
            # Using explicit alternatives guarantees isolation from retEvento
            # regardless of document order.
            $tpEvento = & $getText (
                '//dfe:evento/dfe:infEvento/dfe:tpEvento       |' +
                '//dfe:eventoCTe/dfe:infEvento/dfe:tpEvento    |' +
                '//dfe:eventoMDFe/dfe:infEvento/dfe:tpEvento   |' +
                '//dfe:eventoNFCom/dfe:infEvento/dfe:tpEvento'
            )

            $eventoTipo = $null

            if ($null -ne $tpEvento -and $null -ne $docInfo.Modelo) {
                $eventoTipo = Resolve-DFeEvento -Modelo $docInfo.Modelo -TipoEvento $tpEvento
            }

            # descEvento may be nested inside a model-specific wrapper element
            # (e.g. evEncMDFe, evCancNFCom). //dfe:descEvento resolves all cases
            # regardless of nesting depth.
            $descEvento = & $getText '//dfe:descEvento'

            # Each model uses a different element name for the parent document key.
            # Exactly one of these will be present depending on the parent model.
            # ChavePai is plain text content, not a structured Id attribute.
            # Trimming is intentional and safe here.
            $nodeParams = @{
                XmlNode      = $xml
                XPath        = '//dfe:chNFe | //dfe:chCTe | //dfe:chMDFe | //dfe:chNFCom'
                XmlNsManager = $nsm
            }

            $chavePaiNode = Select-XmlNode @nodeParams

            $chavePai = if ($null -ne $chavePaiNode) {
                $chavePaiNode.InnerText.Trim()
            } else {
                $null
            }

            # Explicit return: without it, execution falls through to the
            # Documento branch below, which fails to find $root in
            # DFeExtractionMap and emits a false 'configuration bug' warning
            # for every single Evento processed.
            return [PSCustomObject]@{
                File       = $file
                Tipo       = $docInfo.Tipo
                Modelo     = $docInfo.Modelo
                Root       = $root
                IsProc     = $root -match 'Proc$'
                Chave      = $null
                ChavePai   = $chavePai
                EventoTipo = $eventoTipo
                TpEvento   = $tpEvento
                DescEvento = $descEvento
                DhEmi      = $null
                Ndoc       = $null
                Serie      = $null
                NNFIni     = $null
                NNFFin     = $null
                IdInut     = $null
                cStat      = $null
                xMotivo    = $null
            }
        }

        # Inutilizacao
        if ($docInfo.Tipo -eq [TipoXmlDFe]::Inutilizacao) {
            # Id lives only in inutNFe/infInut/@Id - retInutNFe/infInut has no @Id.
            # This is a structured identifier (cUF+ano+CNPJ+mod+serie+nNFIni+nNFFin),
            # not a chave de acesso in the NFe/NFCe sense - kept as a distinct field.
            $nodeParams = @{
                XmlNode      = $xml
                XPath        = '//dfe:inutNFe/dfe:infInut'
                XmlNsManager = $nsm
            }

            $infInutNode = Select-XmlNode @nodeParams

            $idInut = $null

            if ($null -ne $infInutNode) {
                $idAttr = $infInutNode.Attributes.GetNamedItem('Id')

                if ($null -ne $idAttr -and -not [string]::IsNullOrWhiteSpace($idAttr.Value)) {
                    $idInut = $idAttr.Value.Trim()
                }
            }

            # Explicit return: same fallthrough hazard as the Evento branch above.
            return [PSCustomObject]@{
                File       = $file
                Tipo       = $docInfo.Tipo
                Modelo     = $docInfo.Modelo
                Root       = $root
                IsProc     = $root -match 'Proc$'
                Chave      = $null
                ChavePai   = $null
                EventoTipo = $null
                TpEvento   = $null
                DescEvento = $null
                DhEmi      = $null
                Ndoc       = $null
                Serie      = & $getText '//dfe:infInut/dfe:serie'
                NNFIni     = & $getText '//dfe:infInut/dfe:nNFIni'
                NNFFin     = & $getText '//dfe:infInut/dfe:nNFFin'
                IdInut     = $idInut
                cStat      = & $getText '//dfe:retInutNFe/dfe:infInut/dfe:cStat'
                xMotivo    = & $getText '//dfe:retInutNFe/dfe:infInut/dfe:xMotivo'
            }
        }

        # Documento
        $extraction = $Script:DFeExtractionMap[$root]

        if ($null -eq $extraction) {
            # A root classified as Documento by DFeDocumentMap has no entry in
            # DFeExtractionMap. This is a configuration bug -- fail loudly.
            Write-Warning -Message (
                "[$($file.Name)] Root '$root' is classified as Documento but has " +
                'no entry in DFeExtractionMap. This is a configuration bug.'
            )
            return
        }

        $nodeParams = @{
            XmlNode      = $xml
            XPath        = "//dfe:$($extraction.InfoNode)"
            XmlNsManager = $nsm
        }

        $infNode = Select-XmlNode @nodeParams

        if ($null -eq $infNode) {
            return
        }

        # Get-DFeAccessKey is the sole authority over chave de acesso extraction
        # and format validation. Returns $null for any structural violation.
        $chave = Get-DFeAccessKey -Node $infNode -Prefix $extraction.IdPrefix

        if ($null -eq $chave) {
            Write-Warning -Message "[$($file.Name)] Invalid or missing chave de acesso."
            return
        }

        [PSCustomObject]@{
            File       = $file
            Tipo       = $docInfo.Tipo
            Modelo     = $docInfo.Modelo
            Root       = $root
            IsProc     = $root -match 'Proc$'
            Chave      = $chave
            ChavePai   = $null
            EventoTipo = $null
            TpEvento   = $null
            DescEvento = $null
            DhEmi      = & $getText '//dfe:dhEmi'
            Ndoc       = & $getText '//dfe:nNF'
            Serie      = & $getText '//dfe:serie'
            NNFIni     = $null
            NNFFin     = $null
            IdInut     = $null
            cStat      = $null
            xMotivo    = $null
        }
    }
}
