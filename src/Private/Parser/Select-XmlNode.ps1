<#
.SYNOPSIS
Selects a single XML node using multiple lookup strategies.

.DESCRIPTION
Attempts to locate an XML node using the available lookup strategies in the
following order:

1. Namespace-aware XPath lookup.
2. Namespace-agnostic XPath lookup.
3. DOM traversal by LocalName.

Returns the first matching XML node or $null when no node is found.

.PARAMETER XmlNode
The XML node that serves as the context for the search.

.PARAMETER XPath
The XPath expression used to locate the target node.

.PARAMETER XmlNsManager
Optional XML namespace manager used for namespace-aware XPath evaluation.

.EXAMPLE
PS C:\> Select-XmlNode -XmlNode $document -XPath 'nfe:emit/nfe:xNome' `
>> -XmlNsManager $nsManager

Returns the matching XML node.

.OUTPUTS
System.Xml.XmlNode
#>
function Select-XmlNode {
    [CmdletBinding()]
    [OutputType([System.Xml.XmlNode])]
    param (
        [Parameter(Mandatory)]
        [System.Xml.XmlNode]$XmlNode,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$XPath,

        [Parameter()]
        [System.Xml.XmlNamespaceManager]$XmlNsManager
    )

    # Namespace-aware lookup
    if ($null -ne $XmlNsManager) {
        $namespaceAwareParams = @{
            XmlNode      = $XmlNode
            XPath        = $XPath
            XmlNsManager = $XmlNsManager
        }

        $matchedNode = Find-XmlNodeByNamespace @namespaceAwareParams

        if ($null -ne $matchedNode) {
            return $matchedNode
        }
    }

    # Namespace-agnostic LocalName lookup
    $matchedNode = Find-XmlNodeByLocalName -XmlNode $XmlNode -XPath $XPath

    if ($null -ne $matchedNode) {
        return $matchedNode
    }

    # DOM traversal fallback using LocalName
    $localName = Get-XPathLocalName -XPath $XPath

    if ($null -eq $localName) {
        return $null
    }

    return Find-XmlNodeByTraversal -XmlNode $XmlNode -LocalName $localName
}
