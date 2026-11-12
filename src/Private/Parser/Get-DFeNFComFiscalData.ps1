<#
.SYNOPSIS
Extracts normalized fiscal data from an NFCom XML document.

.DESCRIPTION
Reads the NFCom (model 62) fiscal structure and returns an in-memory fiscal
projection. Supports NFCom and nfcomProc roots, including optional IBS/CBS.
Does not access files, SQLite, processing states, reports or SMTP.

This is an extraction contract, not XSD, signature or authorization validation.
Absent optional values remain null. Numeric fiscal values use Decimal.

.PARAMETER Xml
NFCom XML document.

.OUTPUTS
PSCustomObject with PSTypeName PipeDFe.Fiscal.NFComDocument.

.NOTES
Private dependencies:
  Get-DFeDocumentInfo
  Get-DFeDocumentNamespace
  Get-DFeAccessKey
  ConvertFrom-DFeDecimal
  DFeExtractionMap
#>
function Get-DFeNFComFiscalData {
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
            $documentInfo.Modelo -ne [ModeloDFe]::NFCom) {

            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.ArgumentException]::new(
                        'Xml must contain an NFCom fiscal document.'
                    ),
                    'UnsupportedNFComFiscalDocument',
                    [System.Management.Automation.ErrorCategory]::InvalidArgument,
                    $Xml
                )
            )
        }

        $namespace = Get-DFeDocumentNamespace -Xml $Xml

        if ([string]::IsNullOrWhiteSpace($namespace)) {
            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.InvalidOperationException]::new(
                        'Unable to determine the NFCom XML namespace.'
                    ),
                    'NFComNamespaceNotFound',
                    [System.Management.Automation.ErrorCategory]::InvalidData,
                    $Xml
                )
            )
        }

        $nsm = [System.Xml.XmlNamespaceManager]::new($Xml.NameTable)
        $nsm.AddNamespace('dfe', $namespace)

        $root       = $Xml.DocumentElement.LocalName
        $extraction = $Script:DFeExtractionMap[$root]

        if ($null -eq $extraction) {
            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.InvalidOperationException]::new(
                        "No extraction mapping exists for XML root '$root'."
                    ),
                    'NFComExtractionMappingNotFound',
                    [System.Management.Automation.ErrorCategory]::InvalidData,
                    $root
                )
            )
        }

        $infNode = $Xml.SelectSingleNode(
            "//dfe:$($extraction.InfoNode)",
            $nsm
        )

        if ($null -eq $infNode) {
            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.InvalidOperationException]::new(
                        'Required infNFCom node was not found.'
                    ),
                    'NFComInfoNodeNotFound',
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
                        'NFCom access key is invalid or missing.'
                    ),
                    'NFComAccessKeyInvalid',
                    [System.Management.Automation.ErrorCategory]::InvalidData,
                    $Xml
                )
            )
        }

        # Scriptblocks capture the local namespace manager. They do not
        # modify module state and remain compatible with PowerShell 5.1.
        $getText = {
            param (
                [System.Xml.XmlNode]$Node,
                [string]$XPath
            )

            if ($null -eq $Node) { return }

            $selected = $Node.SelectSingleNode($XPath, $nsm)

            if ($null -eq $selected) { return }
            if ([string]::IsNullOrWhiteSpace($selected.InnerText)) { return }

            $selected.InnerText.Trim()
        }

        $getDecimal = {
            param (
                [System.Xml.XmlNode]$Node,
                [string]$XPath
            )

            $value = & $getText $Node $XPath

            if ($null -ne $value) {
                ConvertFrom-DFeDecimal -Value $value
            }
        }

        $getParticipant = {
            param (
                [System.Xml.XmlNode]$Node,
                [string]$AddressName
            )

            if ($null -eq $Node) { return }

            $address = $Node.SelectSingleNode("dfe:$AddressName", $nsm)

            [pscustomobject]@{
                Cnpj         = & $getText $Node 'dfe:CNPJ'
                Cpf          = & $getText $Node 'dfe:CPF'
                RazaoSocial  = & $getText $Node 'dfe:xNome'
                NomeFantasia = & $getText $Node 'dfe:xFant'
                IE           = & $getText $Node 'dfe:IE'
                CRT          = & $getText $Node 'dfe:CRT'
                IndIEDest    = & $getText $Node 'dfe:indIEDest'
                Email        = & $getText $Node 'dfe:email'
                Endereco     = if ($null -eq $address) {
                    $null
                } else {
                    [pscustomobject]@{
                        Logradouro   = & $getText $address 'dfe:xLgr'
                        Numero       = & $getText $address 'dfe:nro'
                        Complemento  = & $getText $address 'dfe:xCpl'
                        Bairro       = & $getText $address 'dfe:xBairro'
                        CodMunicipio = & $getText $address 'dfe:cMun'
                        Municipio    = & $getText $address 'dfe:xMun'
                        UF           = & $getText $address 'dfe:UF'
                        CEP          = & $getText $address 'dfe:CEP'
                        CodPais      = & $getText $address 'dfe:cPais'
                        Pais         = & $getText $address 'dfe:xPais'
                        Telefone     = & $getText $address 'dfe:fone'
                        Email        = & $getText $address 'dfe:email'
                    }
                }
            }
        }

        $getIbsCbsTax = {
            param ([System.Xml.XmlNode]$TaxNode)

            if ($null -eq $TaxNode) { return }

            $values = $TaxNode.SelectSingleNode('dfe:gIBSCBS', $nsm)

            [pscustomobject]@{
                CST        = & $getText $TaxNode 'dfe:CST'
                CClassTrib = & $getText $TaxNode 'dfe:cClassTrib'
                IndDoacao  = & $getText $TaxNode 'dfe:indDoacao'
                Valores    = if ($null -eq $values) {
                    $null
                } else {
                    [pscustomobject]@{
                        VBC   = & $getDecimal $values 'dfe:vBC'
                        VIBS  = & $getDecimal $values 'dfe:vIBS'
                        IBSUF = [pscustomobject]@{
                            PIBSUF    = & $getDecimal $values 'dfe:gIBSUF/dfe:pIBSUF'
                            VIBSUF    = & $getDecimal $values 'dfe:gIBSUF/dfe:vIBSUF'
                            PDif      = & $getDecimal $values 'dfe:gIBSUF/dfe:gDif/dfe:pDif'
                            VDif      = & $getDecimal $values 'dfe:gIBSUF/dfe:gDif/dfe:vDif'
                            VDevTrib  = & $getDecimal $values 'dfe:gIBSUF/dfe:gDevTrib/dfe:vDevTrib'
                            PRedAliq  = & $getDecimal $values 'dfe:gIBSUF/dfe:gRed/dfe:pRedAliq'
                            PAliqEfet = & $getDecimal $values 'dfe:gIBSUF/dfe:gRed/dfe:pAliqEfet'
                        }
                        IBSMun = [pscustomobject]@{
                            PIBSMun   = & $getDecimal $values 'dfe:gIBSMun/dfe:pIBSMun'
                            VIBSMun   = & $getDecimal $values 'dfe:gIBSMun/dfe:vIBSMun'
                            PDif      = & $getDecimal $values 'dfe:gIBSMun/dfe:gDif/dfe:pDif'
                            VDif      = & $getDecimal $values 'dfe:gIBSMun/dfe:gDif/dfe:vDif'
                            VDevTrib  = & $getDecimal $values 'dfe:gIBSMun/dfe:gDevTrib/dfe:vDevTrib'
                            PRedAliq  = & $getDecimal $values 'dfe:gIBSMun/dfe:gRed/dfe:pRedAliq'
                            PAliqEfet = & $getDecimal $values 'dfe:gIBSMun/dfe:gRed/dfe:pAliqEfet'
                        }
                        CBS = [pscustomobject]@{
                            PCBS      = & $getDecimal $values 'dfe:gCBS/dfe:pCBS'
                            VCBS      = & $getDecimal $values 'dfe:gCBS/dfe:vCBS'
                            PDif      = & $getDecimal $values 'dfe:gCBS/dfe:gDif/dfe:pDif'
                            VDif      = & $getDecimal $values 'dfe:gCBS/dfe:gDif/dfe:vDif'
                            VDevTrib  = & $getDecimal $values 'dfe:gCBS/dfe:gDevTrib/dfe:vDevTrib'
                            PRedAliq  = & $getDecimal $values 'dfe:gCBS/dfe:gRed/dfe:pRedAliq'
                            PAliqEfet = & $getDecimal $values 'dfe:gCBS/dfe:gRed/dfe:pAliqEfet'
                        }
                        TribRegular = if ($null -eq $values.SelectSingleNode('dfe:gTribRegular', $nsm)) {
                            $null
                        } else {
                            [pscustomobject]@{
                                CSTReg          = & $getText $values 'dfe:gTribRegular/dfe:CSTReg'
                                CClassTribReg   = & $getText $values 'dfe:gTribRegular/dfe:cClassTribReg'
                                PAliqEfetIBSUF  = & $getDecimal $values 'dfe:gTribRegular/dfe:pAliqEfetRegIBSUF'
                                VTribIBSUF      = & $getDecimal $values 'dfe:gTribRegular/dfe:vTribRegIBSUF'
                                PAliqEfetIBSMun = & $getDecimal $values 'dfe:gTribRegular/dfe:pAliqEfetRegIBSMun'
                                VTribIBSMun     = & $getDecimal $values 'dfe:gTribRegular/dfe:vTribRegIBSMun'
                                PAliqEfetCBS    = & $getDecimal $values 'dfe:gTribRegular/dfe:pAliqEfetRegCBS'
                                VTribCBS        = & $getDecimal $values 'dfe:gTribRegular/dfe:vTribRegCBS'
                            }
                        }
                        TribCompraGov = if ($null -eq $values.SelectSingleNode('dfe:gTribCompraGov', $nsm)) {
                            $null
                        } else {
                            [pscustomobject]@{
                                PAliqIBSUF  = & $getDecimal $values 'dfe:gTribCompraGov/dfe:pAliqIBSUF'
                                VTribIBSUF  = & $getDecimal $values 'dfe:gTribCompraGov/dfe:vTribIBSUF'
                                PAliqIBSMun = & $getDecimal $values 'dfe:gTribCompraGov/dfe:pAliqIBSMun'
                                VTribIBSMun = & $getDecimal $values 'dfe:gTribCompraGov/dfe:vTribIBSMun'
                                PAliqCBS    = & $getDecimal $values 'dfe:gTribCompraGov/dfe:pAliqCBS'
                                VTribCBS    = & $getDecimal $values 'dfe:gTribCompraGov/dfe:vTribCBS'
                            }
                        }
                    }
                }
            }
        }

        $ide = $infNode.SelectSingleNode('dfe:ide', $nsm)

        if ((& $getText $ide 'dfe:mod') -ne '62') {
            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.IO.InvalidDataException]::new(
                        'NFCom ide/mod must be 62.'
                    ),
                    'NFComModelMismatch',
                    [System.Management.Automation.ErrorCategory]::InvalidData,
                    $Xml
                )
            )
        }

        $emit        = $infNode.SelectSingleNode('dfe:emit', $nsm)
        $dest        = $infNode.SelectSingleNode('dfe:dest', $nsm)
        $assinante   = $infNode.SelectSingleNode('dfe:assinante', $nsm)
        $fatura      = $infNode.SelectSingleNode('dfe:gFat', $nsm)
        $total       = $infNode.SelectSingleNode('dfe:total', $nsm)
        $totalIbsCbs = if ($null -ne $total) {
            $total.SelectSingleNode('dfe:IBSCBSTot', $nsm)
        } else {
            $null
        }

        $protocolo = $null

        if ($root -eq 'nfcomProc') {
            $protocolo = $Xml.SelectSingleNode(
                '/dfe:nfcomProc/dfe:protNFCom/dfe:infProt',
                $nsm
            )
        }

        $items = [System.Collections.Generic.List[pscustomobject]]::new()

        foreach ($det in $infNode.SelectNodes('dfe:det', $nsm)) {
            $produto    = $det.SelectSingleNode('dfe:prod', $nsm)
            $imposto    = $det.SelectSingleNode('dfe:imposto', $nsm)

            $icmsNode = if ($null -ne $imposto) {
                $imposto.SelectSingleNode(
                    'dfe:ICMS00 | dfe:ICMS20 | dfe:ICMS40 | ' +
                    'dfe:ICMS51 | dfe:ICMS90 | dfe:ICMSSN',
                    $nsm
                )
            } else {
                $null
            }

            $ibsCbsNode = if ($null -ne $imposto) {
                $imposto.SelectSingleNode('dfe:IBSCBS', $nsm)
            } else {
                $null
            }

            $items.Add(
                [pscustomobject]@{
                    Numero  = [string]$det.GetAttribute('nItem')
                    Produto = [pscustomobject]@{
                        Codigo         = & $getText $produto 'dfe:cProd'
                        Descricao      = & $getText $produto 'dfe:xProd'
                        Classificacao  = & $getText $produto 'dfe:cClass'
                        CFOP           = & $getText $produto 'dfe:CFOP'
                        Unidade        = & $getText $produto 'dfe:uMed'
                        Quantidade     = & $getDecimal $produto 'dfe:qFaturada'
                        ValorUnitario  = & $getDecimal $produto 'dfe:vItem'
                        ValorProduto   = & $getDecimal $produto 'dfe:vProd'
                        Desconto       = & $getDecimal $produto 'dfe:vDesc'
                        OutrasDespesas = & $getDecimal $produto 'dfe:vOutro'
                    }
                    Tributos = [pscustomobject]@{
                        IndSemCST = & $getText $imposto 'dfe:indSemCST'
                        ICMS      = if ($null -eq $icmsNode) {
                            $null
                        } else {
                            [pscustomobject]@{
                                Grupo = $icmsNode.LocalName
                                CST   = & $getText $icmsNode 'dfe:CST'
                                IndSN = & $getText $icmsNode 'dfe:indSN'
                                VBC   = & $getDecimal $icmsNode 'dfe:vBC'
                                PICMS = & $getDecimal $icmsNode 'dfe:pICMS'
                                VICMS = & $getDecimal $icmsNode 'dfe:vICMS'
                            }
                        }
                        IBSCBS = & $getIbsCbsTax $ibsCbsNode
                    }
                }
            )
        }

        [pscustomobject]@{
            PSTypeName    = 'PipeDFe.Fiscal.NFComDocument'
            SchemaVersion = 1
            Modelo        = [ModeloDFe]::NFCom
            ChaveAcesso   = $chave
            Identificacao = [pscustomobject]@{
                CUF               = & $getText $ide 'dfe:cUF'
                Ambiente          = & $getText $ide 'dfe:tpAmb'
                Serie             = & $getText $ide 'dfe:serie'
                Numero            = & $getText $ide 'dfe:nNF'
                CodigoNumerico    = & $getText $ide 'dfe:cNF'
                DigitoVerificador = & $getText $ide 'dfe:cDV'
                DhEmi             = & $getText $ide 'dfe:dhEmi'
                TipoEmissao       = & $getText $ide 'dfe:tpEmis'
                MunicipioFG       = & $getText $ide 'dfe:cMunFG'
                Finalidade        = & $getText $ide 'dfe:finNFCom'
                TipoFaturamento   = & $getText $ide 'dfe:tpFat'
                VersaoProcesso    = & $getText $ide 'dfe:verProc'
            }
            Emitente     = & $getParticipant $emit 'enderEmit'
            Destinatario = & $getParticipant $dest 'enderDest'
            Assinante    = if ($null -eq $assinante) {
                $null
            } else {
                [pscustomobject]@{
                    Codigo         = & $getText $assinante 'dfe:iCodAssinante'
                    Tipo           = & $getText $assinante 'dfe:tpAssinante'
                    TipoServico    = & $getText $assinante 'dfe:tpServUtil'
                    Contrato       = & $getText $assinante 'dfe:nContrato'
                    ContratoInicio = & $getText $assinante 'dfe:dContratoIni'
                    ContratoFim    = & $getText $assinante 'dfe:dContratoFim'
                    Terminal       = & $getText $assinante 'dfe:NroTermPrinc'
                    UFPrincipal    = & $getText $assinante 'dfe:cUFPrinc'
                }
            }
            Faturamento = if ($null -eq $fatura) {
                $null
            } else {
                [pscustomobject]@{
                    Competencia   = & $getText $fatura 'dfe:CompetFat'
                    Vencimento    = & $getText $fatura 'dfe:dVencFat'
                    PeriodoInicio = & $getText $fatura 'dfe:dPerUsoIni'
                    PeriodoFim    = & $getText $fatura 'dfe:dPerUsoFim'
                    CodigoBarras  = & $getText $fatura 'dfe:codBarras'
                }
            }
            Totais = if ($null -eq $total) {
                $null
            } else {
                [pscustomobject]@{
                    VProd      = & $getDecimal $total 'dfe:vProd'
                    VBC        = & $getDecimal $total 'dfe:ICMSTot/dfe:vBC'
                    VICMS      = & $getDecimal $total 'dfe:ICMSTot/dfe:vICMS'
                    VICMSDeson = & $getDecimal $total 'dfe:ICMSTot/dfe:vICMSDeson'
                    VFCP       = & $getDecimal $total 'dfe:ICMSTot/dfe:vFCP'
                    VPIS       = & $getDecimal $total 'dfe:vPIS'
                    VCOFINS    = & $getDecimal $total 'dfe:vCOFINS'
                    VFUST      = & $getDecimal $total 'dfe:vFUST'
                    VFUNTTEL   = & $getDecimal $total 'dfe:vFUNTTEL'
                    VDesc      = & $getDecimal $total 'dfe:vDesc'
                    VOutro     = & $getDecimal $total 'dfe:vOutro'
                    VNF        = & $getDecimal $total 'dfe:vNF'
                    RetTrib    = if ($null -eq $total.SelectSingleNode('dfe:vRetTribTot', $nsm)) {
                        $null
                    } else {
                        [pscustomobject]@{
                            VRetPIS    = & $getDecimal $total 'dfe:vRetTribTot/dfe:vRetPIS'
                            VRetCOFINS = & $getDecimal $total 'dfe:vRetTribTot/dfe:vRetCofins'
                            VRetCSLL   = & $getDecimal $total 'dfe:vRetTribTot/dfe:vRetCSLL'
                            VIRRF      = & $getDecimal $total 'dfe:vRetTribTot/dfe:vIRRF'
                        }
                    }
                    IBSCBSTot  = if ($null -eq $totalIbsCbs) {
                        $null
                    } else {
                        [pscustomobject]@{
                            VBCIBSCBS      = & $getDecimal $totalIbsCbs 'dfe:vBCIBSCBS'
                            VIBSUF         = & $getDecimal $totalIbsCbs 'dfe:gIBS/dfe:gIBSUF/dfe:vIBSUF'
                            VIBSMun        = & $getDecimal $totalIbsCbs 'dfe:gIBS/dfe:gIBSMun/dfe:vIBSMun'
                            VIBS           = & $getDecimal $totalIbsCbs 'dfe:gIBS/dfe:vIBS'
                            VCBS           = & $getDecimal $totalIbsCbs 'dfe:gCBS/dfe:vCBS'
                            VDifIBSUF      = & $getDecimal $totalIbsCbs 'dfe:gIBS/dfe:gIBSUF/dfe:vDif'
                            VDevTribIBSUF  = & $getDecimal $totalIbsCbs 'dfe:gIBS/dfe:gIBSUF/dfe:vDevTrib'
                            VDifIBSMun     = & $getDecimal $totalIbsCbs 'dfe:gIBS/dfe:gIBSMun/dfe:vDif'
                            VDevTribIBSMun = & $getDecimal $totalIbsCbs 'dfe:gIBS/dfe:gIBSMun/dfe:vDevTrib'
                            VDifCBS        = & $getDecimal $totalIbsCbs 'dfe:gCBS/dfe:vDif'
                            VDevTribCBS    = & $getDecimal $totalIbsCbs 'dfe:gCBS/dfe:vDevTrib'
                            VIBSEstCred    = & $getDecimal $totalIbsCbs 'dfe:gEstornoCred/dfe:vIBSEstCred'
                            VCBSEstCred    = & $getDecimal $totalIbsCbs 'dfe:gEstornoCred/dfe:vCBSEstCred'
                        }
                    }
                }
            }
            Protocolo = if ($null -eq $protocolo) {
                $null
            } else {
                [pscustomobject]@{
                    Numero     = & $getText $protocolo 'dfe:nProt'
                    Status     = & $getText $protocolo 'dfe:cStat'
                    Motivo     = & $getText $protocolo 'dfe:xMotivo'
                    RecebidoEm = & $getText $protocolo 'dfe:dhRecbto'
                }
            }
            Itens = $items.ToArray()
        }
    }
}
