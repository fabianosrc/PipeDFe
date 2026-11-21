<#
.SYNOPSIS
Determines the direction of an NF-e relative to a company.

.DESCRIPTION
Classifies an NF-e as Saida, Entrada, Terceiro or Indeterminado
by comparing the complete company CNPJ with the issuer and
recipient CNPJs extracted from the XML.

Issuer ownership takes precedence over recipient ownership.
An NF-e issued by the company to itself is classified as Saida.

A participant CNPJ that is absent or does not match the
14-digit numeric format (including alphanumeric CNPJs used in
foreign-issued NF-e) causes the document to be classified as
Indeterminado. Missing or non-numeric CNPJs are not treated as
evidence that a document belongs to a third party.

The function does not access the filesystem or persistence layer.

.PARAMETER Xml
NF-e XML document to classify.

.PARAMETER Cnpj
The complete 14-digit CNPJ of the company.

.OUTPUTS
System.String

Returns Saida, Entrada, Terceiro or Indeterminado.

.EXAMPLE
PS C:\> $direction = Get-DFeNFeDirection -Xml $xmlDoc -Cnpj '12345678000195'

.NOTES
Classification contract:

  Issuer = company   Recipient = company   Result
  ----------------   -------------------   -------------
  Yes                (any)                 Saida
  No                 Yes                   Entrada
  No                 No  (valid CNPJ)      Terceiro
  (any)              (any, invalid/absent) Indeterminado

Issuer precedence resolves the self-issued case (company → company)
as Saida, preventing duplication in the Entrada pipeline.
#>
function Get-DFeNFeDirection {
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [System.Xml.XmlDocument]$Xml,

        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9]{14}$')]
        [string]$Cnpj
    )

    $infNFe = $Xml.SelectSingleNode(
        "/*[local-name()='NFe']/*[local-name()='infNFe'] | " +
        "/*[local-name()='nfeProc']/*[local-name()='NFe']/*[local-name()='infNFe']"
    )

    if ($null -eq $infNFe) {
        throw [System.ArgumentException]::new(
            'XML does not contain a supported NF-e infNFe element.'
        )
    }

    $modelNode = $infNFe.SelectSingleNode(
        "*[local-name()='ide']/*[local-name()='mod']"
    )

    if ($null -eq $modelNode -or $modelNode.InnerText.Trim() -ne '55') {
        throw [System.ArgumentException]::new(
            'XML must contain an NF-e document with model 55.'
        )
    }

    $issuerNode = $infNFe.SelectSingleNode(
        "*[local-name()='emit']/*[local-name()='CNPJ']"
    )

    $recipientNode = $infNFe.SelectSingleNode(
        "*[local-name()='dest']/*[local-name()='CNPJ']"
    )

    $issuerCnpj = if ($null -ne $issuerNode) {
        $issuerNode.InnerText.Trim()
    } else {
        $null
    }

    $recipientCnpj = if ($null -ne $recipientNode) {
        $recipientNode.InnerText.Trim()
    } else {
        $null
    }

    if ($issuerCnpj -eq $Cnpj) {
        return 'Saida'
    }

    if ($recipientCnpj -eq $Cnpj) {
        return 'Entrada'
    }

    if ($issuerCnpj -notmatch '^[0-9]{14}$' -or
        $recipientCnpj -notmatch '^[0-9]{14}$'
    ) {
        return 'Indeterminado'
    }

    return 'Terceiro'
}
