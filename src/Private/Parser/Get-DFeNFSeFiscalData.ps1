<#
.SYNOPSIS
Extracts a fiscal projection from an NFS-e Nacional XML document.

.DESCRIPTION
Reads the common fields of national layouts 1.00 and 1.01 and the optional
IBS/CBS totals in 1.01. This is field extraction, not XSD or signature validation.

The NFS-e generation time (dhProc), DPS issuance time (dhEmi), and service
competence (dCompet) are kept distinct. The access key comes exclusively
from infNFSe/@Id. Optional amounts remain null when absent.

nNFSe accepts 1 to 13 digits without leading zeros, matching the nDec13
type defined in tiposSimples_v1.01.xsd.

.PARAMETER Xml
An XML document containing the generated national NFSe root.

.OUTPUTS
PipeDFe.Fiscal.NFSeDocument
#>
function Get-DFeNFSeFiscalData {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory, ValueFromPipeline)]
        [ValidateNotNull()]
        [System.Xml.XmlDocument]$Xml
    )

    process {
        $root      = $Xml.DocumentElement
        $namespace = 'http://www.sped.fazenda.gov.br/nfse'

        if ($null -eq $root -or $root.LocalName -cne 'NFSe' -or
            $root.NamespaceURI -cne $namespace)
        {
            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.ArgumentException]::new('Expected a national NFSe XML document.'),
                    'UnsupportedNFSeFiscalDocument',
                    [System.Management.Automation.ErrorCategory]::InvalidArgument,
                    $Xml
                )
            )
        }

        $version = $root.GetAttribute('versao')

        if ($version -cnotin @('1.00', '1.01')) {
            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.NotSupportedException]::new(
                        "Unsupported NFSe layout version '$version'."
                    ),
                    'UnsupportedNFSeLayoutVersion',
                    [System.Management.Automation.ErrorCategory]::InvalidData,
                    $version
                )
            )
        }

        $nsm = [System.Xml.XmlNamespaceManager]::new($Xml.NameTable)
        $nsm.AddNamespace('n', $namespace)

        $infNFSe = $root.SelectSingleNode('n:infNFSe', $nsm)
        $id      = if ($null -ne $infNFSe) { $infNFSe.GetAttribute('Id') }

        if ($null -eq $infNFSe -or $id -cnotmatch '\ANFS[0-9]{50}\z') {
            $PSCmdlet.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.FormatException]::new(
                        'infNFSe/@Id must contain NFS followed by 50 digits.'
                    ),
                    'InvalidNFSeAccessKey',
                    [System.Management.Automation.ErrorCategory]::InvalidData,
                    $id
                )
            )
        }

        # Capture $PSCmdlet so the $invalidField scriptblock can call
        # ThrowTerminatingError from the correct cmdlet context.
        $PSCmdletRef = $PSCmdlet

        $infDps = $infNFSe.SelectSingleNode('n:DPS/n:infDPS', $nsm)

        $readText = {
            param ([System.Xml.XmlNode]$Node, [string]$XPath)

            if ($null -ne $Node) {
                $match = $Node.SelectSingleNode($XPath, $nsm)
                if ($null -ne $match -and -not [string]::IsNullOrWhiteSpace($match.InnerText)) {
                    $match.InnerText.Trim()
                }
            }
        }

        $invalidField = {
            param ([string]$Field)

            $PSCmdletRef.ThrowTerminatingError(
                [System.Management.Automation.ErrorRecord]::new(
                    [System.FormatException]::new(
                        "Missing or invalid NFSe field '$Field'."
                    ),
                    'InvalidNFSeFiscalField',
                    [System.Management.Automation.ErrorCategory]::InvalidData,
                    $Field
                )
            )
        }

        $invariant = [System.Globalization.CultureInfo]::InvariantCulture
        $dateStyles = [System.Globalization.DateTimeStyles]::None

        $readDateTime = {
            param ([string]$Value, [string]$Field)

            $instant = [System.DateTimeOffset]::MinValue
            if (-not [System.DateTimeOffset]::TryParseExact(
                    $Value,
                    "yyyy-MM-dd'T'HH:mm:sszzz",
                    $invariant,
                    $dateStyles,
                    [ref]$instant
                )
            ) {
                & $invalidField $Field
            }

            $instant
        }

        $readParty = {
            param ([System.Xml.XmlNode]$Node)

            if ($null -ne $Node) {
                [pscustomobject]@{
                    Cnpj                = & $readText $Node 'n:CNPJ'
                    Cpf                 = & $readText $Node 'n:CPF'
                    Nif                 = & $readText $Node 'n:NIF'
                    CodigoAusenciaNif   = & $readText $Node 'n:cNaoNIF'
                    InscricaoMunicipal  = & $readText $Node 'n:IM'
                    Nome                = & $readText $Node 'n:xNome'
                }
            }
        }

        $number = & $readText $infNFSe 'n:nNFSe'

        if ($number -notmatch '\A[1-9][0-9]{0,12}\z') {
            & $invalidField 'infNFSe/nNFSe'
        }

        $dhProc = & $readDateTime (
            & $readText $infNFSe 'n:dhProc'
        ) 'infNFSe/dhProc'

        if ($null -eq $infDps) {
            & $invalidField 'infNFSe/DPS/infDPS'
        }

        $dhEmi = & $readDateTime (
            & $readText $infDps 'n:dhEmi'
        ) 'infDPS/dhEmi'

        $competence = & $readText $infDps 'n:dCompet'
        $calendarDate = [datetime]::MinValue
        if (-not [datetime]::TryParseExact(
                $competence,
                'yyyy-MM-dd',
                $invariant,
                $dateStyles,
                [ref]$calendarDate
            )
        ) {
            & $invalidField 'infDPS/dCompet'
        }

        $serv         = $infDps.SelectSingleNode('n:serv', $nsm)
        $values       = $infNFSe.SelectSingleNode('n:valores', $nsm)
        $municipalTax = $infDps.SelectSingleNode('n:valores/n:trib/n:tribMun', $nsm)
        $ibsCbsTotals = $infNFSe.SelectSingleNode('n:IBSCBS/n:totCIBS', $nsm)

        $serviceAmount = ConvertFrom-DFeDecimal -Value (
            & $readText $infDps 'n:valores/n:vServPrest/n:vServ'
        )

        if ($null -eq $serviceAmount) {
            & $invalidField 'infDPS/valores/vServPrest/vServ'
        }

        $netAmount = ConvertFrom-DFeDecimal -Value (& $readText $values 'n:vLiq')
        if ($null -eq $netAmount) {
            & $invalidField 'infNFSe/valores/vLiq'
        }

        [PSCustomObject]@{
            PSTypeName          = 'PipeDFe.Fiscal.NFSeDocument'
            SchemaVersion       = 1
            VersaoLeiaute       = $version
            ChaveAcesso         = $id.Substring(3)
            Numero              = $number
            Status              = & $readText $infNFSe 'n:cStat'
            DhProcessamento     = $dhProc
            MunicipioIncidencia = & $readText $infNFSe 'n:cLocIncid'
            Emitente            = & $readParty ($infNFSe.SelectSingleNode('n:emit', $nsm))
            Prestador           = & $readParty ($infDps.SelectSingleNode('n:prest', $nsm))
            Tomador             = & $readParty ($infDps.SelectSingleNode('n:toma', $nsm))
            Intermediario       = & $readParty ($infDps.SelectSingleNode('n:interm', $nsm))
            DPS                 = [pscustomobject]@{
                Id               = $infDps.GetAttribute('Id')
                Numero           = & $readText $infDps 'n:nDPS'
                Serie            = & $readText $infDps 'n:serie'
                Ambiente         = & $readText $infDps 'n:tpAmb'
                MunicipioEmissao = & $readText $infDps 'n:cLocEmi'
                DhEmissao        = $dhEmi
                Competencia      = $calendarDate.ToString('yyyy-MM-dd', $invariant)
            }
            Servico             = [pscustomobject]@{
                CodigoTributacaoNacional  = & $readText $serv 'n:cServ/n:cTribNac'
                CodigoTributacaoMunicipal = & $readText $serv 'n:cServ/n:cTribMun'
                CodigoNbs                 = & $readText $serv 'n:cServ/n:cNBS'
                Descricao                 = & $readText $serv 'n:cServ/n:xDescServ'
                MunicipioPrestacao        = & $readText $serv 'n:locPrest/n:cLocPrestacao'
                PaisPrestacao             = & $readText $serv 'n:locPrest/n:cPaisPrestacao'
            }
            ISSQN               = [pscustomobject]@{
                Tributacao   = & $readText $municipalTax 'n:tribISSQN'
                TipoRetencao = & $readText $municipalTax 'n:tpRetISSQN'
                BaseCalculo  = ConvertFrom-DFeDecimal -Value (& $readText $values 'n:vBC')
                Aliquota     = ConvertFrom-DFeDecimal -Value (& $readText $values 'n:pAliqAplic')
            }
            Totais              = [pscustomobject]@{
                ValorServico        = $serviceAmount
                ValorLiquido        = $netAmount
                ValorISSQN          = ConvertFrom-DFeDecimal -Value (& $readText $values 'n:vISSQN')
                ValorTotalRetencoes = ConvertFrom-DFeDecimal -Value (& $readText $values 'n:vTotalRet')
            }
            IBSCBS              = if ($null -ne $ibsCbsTotals) {
                [pscustomobject]@{
                    ValorTotalNF = ConvertFrom-DFeDecimal -Value (& $readText $ibsCbsTotals 'n:vTotNF')
                    ValorIBS     = ConvertFrom-DFeDecimal -Value (& $readText $ibsCbsTotals 'n:gIBS/n:vIBSTot')
                    ValorCBS     = ConvertFrom-DFeDecimal -Value (& $readText $ibsCbsTotals 'n:gCBS/n:vCBS')
                }
            } else {
                $null
            }
        }
    }
}
