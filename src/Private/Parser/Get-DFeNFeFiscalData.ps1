<#
.SYNOPSIS
Extracts normalized fiscal data from an NF-e or NFC-e XML document.

.DESCRIPTION
Reads fiscal facts from the NF-e XML family and returns a normalized,
in-memory representation suitable for subsequent validation and persistence.

Supports:

  NF-e  - model 55
  NFC-e - model 65

This function performs fiscal extraction only.

It does not:

  - access the filesystem;
  - modify the index;
  - change processing state;
  - generate reports;
  - generate archives;
  - perform delivery.

The original XML remains the authoritative fiscal source. The returned object
is a normalized projection used by the PipeDFe processing layer.

Monetary values, quantities, tax bases and rates are represented as Decimal.
Fiscal codes such as CFOP, CST, CSOSN and NCM remain strings.

.PARAMETER Xml
NF-e/NFC-e XmlDocument to extract.

.OUTPUTS
PSCustomObject
  PSTypeName    - PipeDFe.Fiscal.NFeDocument
  SchemaVersion - [int]      Schema version of the returned object (currently 1).
  Modelo        - [ModeloDFe]
  ChaveAcesso   - [string]   44-digit fiscal access key.
  Identificacao - [pscustomobject] ide fields: CUF, NaturezaOperacao, Modelo,
                             Serie, Numero, DhEmi, DhSaiEnt, TipoOperacao,
                             IdDestino, CodigoMunicipioFatoGerador,
                             TipoImpressao, TipoEmissao, Finalidade,
                             ConsumidorFinal, IndicadorPresenca.
  Emitente      - [pscustomobject] emit fields including nested Endereco.
  Destinatario  - [pscustomobject] dest fields including nested Endereco. $null
                             when absent (NFC-e).
  Totais        - [pscustomobject] ICMSTot fields. $null when absent.
  Itens         - [pscustomobject[]] One entry per det element.

.NOTES
Private dependencies:
  ConvertFrom-DFeDecimal
  Get-DFeAccessKey
  Get-DFeDocumentInfo
  Get-DFeDocumentNamespace
  Select-XmlNode
  DFeExtractionMap
#>
function Get-DFeNFeFiscalData {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory, ValueFromPipeline)]
        [ValidateNotNull()]
        [System.Xml.XmlDocument]$Xml
    )

    process {
        $documentInfo = Get-DFeDocumentInfo -Xml $Xml

        if ($null -eq $documentInfo -or
            $documentInfo.Tipo -ne [TipoXmlDFe]::Documento -or
            $documentInfo.Modelo -notin @([ModeloDFe]::NFe, [ModeloDFe]::NFCe)
        ) {

            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.ArgumentException]::new(
                        'Xml must contain an NF-e or NFC-e fiscal document.'
                    ),
                    'UnsupportedNFeFiscalDocument',
                    [System.Management.Automation.ErrorCategory]::InvalidArgument,
                    $Xml
                )
            )
        }

        $root      = $Xml.DocumentElement.LocalName
        $namespace = Get-DFeDocumentNamespace -Xml $Xml

        if ([string]::IsNullOrWhiteSpace($namespace)) {
            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.InvalidOperationException]::new(
                        'Unable to determine the NF-e XML namespace.'
                    ),
                    'NFeNamespaceNotFound',
                    [System.Management.Automation.ErrorCategory]::InvalidData,
                    $Xml
                )
            )
        }

        $nsm = [System.Xml.XmlNamespaceManager]::new($Xml.NameTable)
        $nsm.AddNamespace('dfe', $namespace)

        $extraction = $Script:DFeExtractionMap[$root]

        if ($null -eq $extraction) {
            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.InvalidOperationException]::new(
                        "No extraction mapping exists for XML root '$root'."
                    ),
                    'NFeExtractionMappingNotFound',
                    [System.Management.Automation.ErrorCategory]::InvalidData,
                    $root
                )
            )
        }

        $infNode = $Xml.SelectSingleNode("//dfe:$($extraction.InfoNode)", $nsm)

        if ($null -eq $infNode) {
            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.InvalidOperationException]::new(
                        "Required '$($extraction.InfoNode)' node was not found."
                    ),
                    'NFeInfoNodeNotFound',
                    [System.Management.Automation.ErrorCategory]::InvalidData,
                    $Xml
                )
            )
        }

        $accessKeyParams = @{
            Node   = $infNode
            Prefix = $extraction.IdPrefix
        }

        $chave = Get-DFeAccessKey @accessKeyParams

        if ([string]::IsNullOrWhiteSpace($chave)) {
            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.InvalidOperationException]::new(
                        'NF-e access key is invalid or missing.'
                    ),
                    'NFeAccessKeyInvalid',
                    [System.Management.Automation.ErrorCategory]::InvalidData,
                    $Xml
                )
            )
        }

        # -----------------------------------------------------------------
        # Local extraction helpers.
        #
        # Scriptblocks are intentionally used instead of nested functions
        # to preserve Windows PowerShell 5.1 scope behavior.
        # -----------------------------------------------------------------
        $getText = {
            param (
                [Parameter()]
                [System.Xml.XmlNode]$Node,

                [Parameter()]
                [string]$XPath
            )

            if ($null -eq $Node) {
                return
            }

            $selected = $Node.SelectSingleNode($XPath, $nsm)

            if ($null -eq $selected) {
                return
            }

            $value = $selected.InnerText

            if ([string]::IsNullOrWhiteSpace($value)) {
                return
            }

            $value.Trim()
        }

        $getDecimal = {
            param (
                [Parameter()]
                [System.Xml.XmlNode]$Node,

                [Parameter()]
                [string]$XPath
            )

            $value = & $getText $Node $XPath

            if ($null -eq $value) {
                return
            }

            ConvertFrom-DFeDecimal -Value $value
        }

        $getParticipant = {
            param (
                [Parameter()]
                [System.Xml.XmlNode]$Node
            )

            if ($null -eq $Node) {
                return
            }

            $address = $Node.SelectSingleNode(
                'dfe:enderEmit | dfe:enderDest',
                $nsm
            )

            [PSCustomObject]@{
                Cnpj         = & $getText $Node 'dfe:CNPJ'
                Cpf          = & $getText $Node 'dfe:CPF'
                RazaoSocial  = & $getText $Node 'dfe:xNome'
                NomeFantasia = & $getText $Node 'dfe:xFant'
                IE           = & $getText $Node 'dfe:IE'
                IndIEDest    = & $getText $Node 'dfe:indIEDest'
                CRT          = & $getText $Node 'dfe:CRT'
                Email        = & $getText $Node 'dfe:email'

                Endereco = if ($null -eq $address) {
                    $null
                } else {
                    [PSCustomObject]@{
                        Logradouro      = & $getText $address 'dfe:xLgr'
                        Numero          = & $getText $address 'dfe:nro'
                        Complemento     = & $getText $address 'dfe:xCpl'
                        Bairro          = & $getText $address 'dfe:xBairro'
                        CodigoMunicipio = & $getText $address 'dfe:cMun'
                        Municipio       = & $getText $address 'dfe:xMun'
                        UF              = & $getText $address 'dfe:UF'
                        CEP             = & $getText $address 'dfe:CEP'
                        CodigoPais      = & $getText $address 'dfe:cPais'
                        Pais            = & $getText $address 'dfe:xPais'
                        Telefone        = & $getText $address 'dfe:fone'
                    }
                }
            }
        }

        $ide  = $infNode.SelectSingleNode('dfe:ide', $nsm)
        $emit = $infNode.SelectSingleNode('dfe:emit', $nsm)
        $dest = $infNode.SelectSingleNode('dfe:dest', $nsm)

        $totalNode     = $infNode.SelectSingleNode('dfe:total/dfe:ICMSTot', $nsm)
        $ibscbsTotNode = $infNode.SelectSingleNode('dfe:total/dfe:IBSCBSTot', $nsm)
        $retTribNode   = $infNode.SelectSingleNode('dfe:total/dfe:retTrib', $nsm)

        $items = [System.Collections.Generic.List[pscustomobject]]::new()

        foreach ($det in $infNode.SelectNodes('dfe:det', $nsm)) {
            $produto = $det.SelectSingleNode('dfe:prod', $nsm)
            $imposto = $det.SelectSingleNode('dfe:imposto', $nsm)

            $icms    = $null
            $pis     = $null
            $cofins  = $null
            $ipi     = $null
            $ibscbs  = $null

            if ($null -ne $imposto) {
                $icmsContainer = $imposto.SelectSingleNode('dfe:ICMS', $nsm)

                if ($null -ne $icmsContainer) {
                    $icmsGroup = $null

                    foreach ($child in $icmsContainer.ChildNodes) {
                        if ($child.NodeType -eq [System.Xml.XmlNodeType]::Element) {
                            $icmsGroup = $child
                            break
                        }
                    }

                    if ($null -ne $icmsGroup) {
                        $icms = [PSCustomObject]@{
                            Grupo      = $icmsGroup.LocalName
                            Orig       = & $getText $icmsGroup 'dfe:orig'
                            CST        = & $getText $icmsGroup 'dfe:CST'
                            CSOSN      = & $getText $icmsGroup 'dfe:CSOSN'
                            ModBC      = & $getText $icmsGroup 'dfe:modBC'
                            VBC        = & $getDecimal $icmsGroup 'dfe:vBC'
                            PRedBC     = & $getDecimal $icmsGroup 'dfe:pRedBC'
                            PICMS      = & $getDecimal $icmsGroup 'dfe:pICMS'
                            VICMS      = & $getDecimal $icmsGroup 'dfe:vICMS'
                            ModBCST    = & $getText $icmsGroup 'dfe:modBCST'
                            PMVAST     = & $getDecimal $icmsGroup 'dfe:pMVAST'
                            PRedBCST   = & $getDecimal $icmsGroup 'dfe:pRedBCST'
                            VBCST      = & $getDecimal $icmsGroup 'dfe:vBCST'
                            PICMSST    = & $getDecimal $icmsGroup 'dfe:pICMSST'
                            VICMSST    = & $getDecimal $icmsGroup 'dfe:vICMSST'
                            VICMSDeson = & $getDecimal $icmsGroup 'dfe:vICMSDeson'
                            MotDesICMS = & $getText $icmsGroup 'dfe:motDesICMS'
                            VBCFCP     = & $getDecimal $icmsGroup 'dfe:vBCFCP'
                            PFCP       = & $getDecimal $icmsGroup 'dfe:pFCP'
                            VFCP       = & $getDecimal $icmsGroup 'dfe:vFCP'
                            VBCFCPST   = & $getDecimal $icmsGroup 'dfe:vBCFCPST'
                            PFCPST     = & $getDecimal $icmsGroup 'dfe:pFCPST'
                            VFCPST     = & $getDecimal $icmsGroup 'dfe:vFCPST'
                        }
                    }
                }

                $pisContainer = $imposto.SelectSingleNode('dfe:PIS', $nsm)

                if ($null -ne $pisContainer) {
                    $pisGroup = $null

                    foreach ($child in $pisContainer.ChildNodes) {
                        if ($child.NodeType -eq [System.Xml.XmlNodeType]::Element) {
                            $pisGroup = $child
                            break
                        }
                    }

                    if ($null -ne $pisGroup) {
                        $pis = [PSCustomObject]@{
                            Grupo     = $pisGroup.LocalName
                            CST       = & $getText $pisGroup 'dfe:CST'
                            VBC       = & $getDecimal $pisGroup 'dfe:vBC'
                            PPIS      = & $getDecimal $pisGroup 'dfe:pPIS'
                            QBCProd   = & $getDecimal $pisGroup 'dfe:qBCProd'
                            VAliqProd = & $getDecimal $pisGroup 'dfe:vAliqProd'
                            VPIS      = & $getDecimal $pisGroup 'dfe:vPIS'
                        }
                    }
                }

                $cofinsContainer = $imposto.SelectSingleNode('dfe:COFINS', $nsm)

                if ($null -ne $cofinsContainer) {
                    $cofinsGroup = $null

                    foreach ($child in $cofinsContainer.ChildNodes) {
                        if ($child.NodeType -eq [System.Xml.XmlNodeType]::Element) {
                            $cofinsGroup = $child
                            break
                        }
                    }

                    if ($null -ne $cofinsGroup) {
                        $cofins = [PSCustomObject]@{
                            Grupo     = $cofinsGroup.LocalName
                            CST       = & $getText $cofinsGroup 'dfe:CST'
                            VBC       = & $getDecimal $cofinsGroup 'dfe:vBC'
                            PCOFINS   = & $getDecimal $cofinsGroup 'dfe:pCOFINS'
                            QBCProd   = & $getDecimal $cofinsGroup 'dfe:qBCProd'
                            VAliqProd = & $getDecimal $cofinsGroup 'dfe:vAliqProd'
                            VCOFINS   = & $getDecimal $cofinsGroup 'dfe:vCOFINS'
                        }
                    }
                }

                $ipiContainer = $imposto.SelectSingleNode('dfe:IPI', $nsm)

                if ($null -ne $ipiContainer) {
                    $ipiGroup = $ipiContainer.SelectSingleNode(
                        'dfe:IPITrib | dfe:IPINT',
                        $nsm
                    )

                    if ($null -ne $ipiGroup) {
                        $ipi = [PSCustomObject]@{
                            Grupo = $ipiGroup.LocalName
                            CEnq  = & $getText $ipiContainer 'dfe:cEnq'
                            CST   = & $getText $ipiGroup 'dfe:CST'
                            VBC   = & $getDecimal $ipiGroup 'dfe:vBC'
                            PIPI  = & $getDecimal $ipiGroup 'dfe:pIPI'
                            QUnid = & $getDecimal $ipiGroup 'dfe:qUnid'
                            VUnid = & $getDecimal $ipiGroup 'dfe:vUnid'
                            VIPI  = & $getDecimal $ipiGroup 'dfe:vIPI'
                        }
                    }
                }

                $ibscbsContainer = $imposto.SelectSingleNode('dfe:IBSCBS', $nsm)

                if ($null -ne $ibscbsContainer) {
                    $ibscbsGroup = $ibscbsContainer.SelectSingleNode('dfe:gIBSCBS', $nsm)

                    $ibscbs = [PSCustomObject]@{
                        CST        = & $getText $ibscbsContainer 'dfe:CST'
                        CClassTrib = & $getText $ibscbsContainer 'dfe:cClassTrib'
                        VBC        = & $getDecimal $ibscbsGroup 'dfe:vBC'
                        PIBSUF     = & $getDecimal $ibscbsGroup 'dfe:gIBSUF/dfe:pIBSUF'
                        VIBSUF     = & $getDecimal $ibscbsGroup 'dfe:gIBSUF/dfe:vIBSUF'
                        PIBSMun    = & $getDecimal $ibscbsGroup 'dfe:gIBSMun/dfe:pIBSMun'
                        VIBSMun    = & $getDecimal $ibscbsGroup 'dfe:gIBSMun/dfe:vIBSMun'
                        VIBS       = & $getDecimal $ibscbsGroup 'dfe:vIBS'
                        PCBS       = & $getDecimal $ibscbsGroup 'dfe:gCBS/dfe:pCBS'
                        VCBS       = & $getDecimal $ibscbsGroup 'dfe:gCBS/dfe:vCBS'
                    }
                }
            }

            $nItemAttr = $det.Attributes['nItem']
            $nItem     = $null

            if ($null -ne $nItemAttr) {
                $nItemParsed = 0

                if ([int]::TryParse($nItemAttr.Value, [ref]$nItemParsed)) {
                    $nItem = $nItemParsed
                }
            }

            $items.Add(
                [PSCustomObject]@{
                    Numero  = $nItem

                    Produto = [PSCustomObject]@{
                        Codigo             = & $getText $produto 'dfe:cProd'
                        EAN                = & $getText $produto 'dfe:cEAN'
                        Descricao          = & $getText $produto 'dfe:xProd'
                        NCM                = & $getText $produto 'dfe:NCM'
                        CEST               = & $getText $produto 'dfe:CEST'
                        CFOP               = & $getText $produto 'dfe:CFOP'
                        Unidade            = & $getText $produto 'dfe:uCom'
                        Quantidade         = & $getDecimal $produto 'dfe:qCom'
                        ValorUnitario      = & $getDecimal $produto 'dfe:vUnCom'
                        ValorProduto       = & $getDecimal $produto 'dfe:vProd'
                        EANTrib            = & $getText $produto 'dfe:cEANTrib'
                        UnidadeTrib        = & $getText $produto 'dfe:uTrib'
                        QuantidadeTrib     = & $getDecimal $produto 'dfe:qTrib'
                        ValorUnitarioTrib  = & $getDecimal $produto 'dfe:vUnTrib'
                        ValorFrete         = & $getDecimal $produto 'dfe:vFrete'
                        ValorSeguro        = & $getDecimal $produto 'dfe:vSeg'
                        ValorDesconto      = & $getDecimal $produto 'dfe:vDesc'
                        OutrasDespesas     = & $getDecimal $produto 'dfe:vOutro'
                        IndTotal           = & $getText $produto 'dfe:indTot'
                    }

                    Tributos = [PSCustomObject]@{
                        ICMS   = $icms
                        IPI    = $ipi
                        PIS    = $pis
                        COFINS = $cofins
                        IBSCBS = $ibscbs
                    }
                }
            )
        }

        [PSCustomObject]@{
            PSTypeName    = 'PipeDFe.Fiscal.NFeDocument'
            SchemaVersion = 1
            Modelo        = $documentInfo.Modelo
            ChaveAcesso   = $chave

            Identificacao = [PSCustomObject]@{
                CUF                        = & $getText $ide 'dfe:cUF'
                NaturezaOperacao           = & $getText $ide 'dfe:natOp'
                Modelo                     = & $getText $ide 'dfe:mod'
                Serie                      = & $getText $ide 'dfe:serie'
                Numero                     = & $getText $ide 'dfe:nNF'
                DhEmi                      = & $getText $ide 'dfe:dhEmi'
                DhSaiEnt                   = & $getText $ide 'dfe:dhSaiEnt'
                TipoOperacao               = & $getText $ide 'dfe:tpNF'
                IdDestino                  = & $getText $ide 'dfe:idDest'
                CodigoMunicipioFatoGerador = & $getText $ide 'dfe:cMunFG'
                TipoImpressao              = & $getText $ide 'dfe:tpImp'
                TipoEmissao                = & $getText $ide 'dfe:tpEmis'
                Finalidade                 = & $getText $ide 'dfe:finNFe'
                ConsumidorFinal            = & $getText $ide 'dfe:indFinal'
                IndicadorPresenca          = & $getText $ide 'dfe:indPres'
            }

            Emitente     = & $getParticipant $emit
            Destinatario = & $getParticipant $dest

            Totais = if ($null -eq $totalNode) {
                $null
            } else {
                [PSCustomObject]@{
                    VBC        = & $getDecimal $totalNode 'dfe:vBC'
                    VICMS      = & $getDecimal $totalNode 'dfe:vICMS'
                    VICMSDeson = & $getDecimal $totalNode 'dfe:vICMSDeson'
                    VFCP       = & $getDecimal $totalNode 'dfe:vFCP'
                    VBCST      = & $getDecimal $totalNode 'dfe:vBCST'
                    VST        = & $getDecimal $totalNode 'dfe:vST'
                    VFCPST     = & $getDecimal $totalNode 'dfe:vFCPST'
                    VFCPSTRet  = & $getDecimal $totalNode 'dfe:vFCPSTRet'
                    VProd      = & $getDecimal $totalNode 'dfe:vProd'
                    VFrete     = & $getDecimal $totalNode 'dfe:vFrete'
                    VSeg       = & $getDecimal $totalNode 'dfe:vSeg'
                    VDesc      = & $getDecimal $totalNode 'dfe:vDesc'
                    VII        = & $getDecimal $totalNode 'dfe:vII'
                    VIPI       = & $getDecimal $totalNode 'dfe:vIPI'
                    VIPIDevol  = & $getDecimal $totalNode 'dfe:vIPIDevol'
                    VPIS       = & $getDecimal $totalNode 'dfe:vPIS'
                    VCOFINS    = & $getDecimal $totalNode 'dfe:vCOFINS'
                    VOutro     = & $getDecimal $totalNode 'dfe:vOutro'
                    VNF        = & $getDecimal $totalNode 'dfe:vNF'
                    VTotTrib   = & $getDecimal $totalNode 'dfe:vTotTrib'

                    IBSCBSTot = if ($null -eq $ibscbsTotNode) {
                        $null
                    } else {
                        $ibsNode = $ibscbsTotNode.SelectSingleNode('dfe:gIBS', $nsm)
                        $cbsNode = $ibscbsTotNode.SelectSingleNode('dfe:gCBS', $nsm)

                        [PSCustomObject]@{
                            VBCIBSCbs        = & $getDecimal $ibscbsTotNode 'dfe:vBCIBSCBS'
                            VIBSUF           = & $getDecimal $ibsNode 'dfe:gIBSUF/dfe:vIBSUF'
                            VDifIBSUF        = & $getDecimal $ibsNode 'dfe:gIBSUF/dfe:vDif'
                            VDevTribIBSUF    = & $getDecimal $ibsNode 'dfe:gIBSUF/dfe:vDevTrib'
                            VIBSMun          = & $getDecimal $ibsNode 'dfe:gIBSMun/dfe:vIBSMun'
                            VDifIBSMun       = & $getDecimal $ibsNode 'dfe:gIBSMun/dfe:vDif'
                            VDevTribIBSMun   = & $getDecimal $ibsNode 'dfe:gIBSMun/dfe:vDevTrib'
                            VIBS             = & $getDecimal $ibsNode 'dfe:vIBS'
                            VCredPres        = & $getDecimal $ibsNode 'dfe:vCredPres'
                            VCredPresCondSus = & $getDecimal $ibsNode 'dfe:vCredPresCondSus'
                            VCBS             = & $getDecimal $cbsNode 'dfe:vCBS'
                            VDifCBS          = & $getDecimal $cbsNode 'dfe:vDif'
                            VDevTribCBS      = & $getDecimal $cbsNode 'dfe:vDevTrib'
                            VCredPresCBS        = & $getDecimal $cbsNode 'dfe:vCredPres'
                            VCredPresCondSusCBS = & $getDecimal $cbsNode 'dfe:vCredPresCondSus'
                        }
                    }

                    RetTrib = if ($null -eq $retTribNode) {
                        $null
                    } else {
                        [PSCustomObject]@{
                            VRetCSLL = & $getDecimal $retTribNode 'dfe:vRetCSLL'
                            VBCIrrf  = & $getDecimal $retTribNode 'dfe:vBCIRRF'
                            VIrrf    = & $getDecimal $retTribNode 'dfe:vIRRF'
                        }
                    }
                }
            }

            Itens = $items.ToArray()
        }
    }
}
