<#
.SYNOPSIS
Finds a single XML node using an XPath expression and namespace manager.

.DESCRIPTION
Executes the .NET SelectSingleNode() method using the specified
XmlNamespaceManager.

Returns the first matching XML node or $null if no matching node is found.

This function performs only namespace-aware XPath lookup and does not
implement fallback strategies. Alternative lookup mechanisms are handled by
higher-level parser functions.

.PARAMETER XmlNode
The XML node that serves as the context for the XPath evaluation.

.PARAMETER XPath
The XPath expression used to locate the target node.

.PARAMETER XmlNsManager
The XML namespace manager used to resolve namespace prefixes referenced by
the XPath expression.

.EXAMPLE
PS C:\> $document.DocumentElement |
>> Find-XmlNodeByNamespace -XPath 'nfe:infNFe' -XmlNsManager $namespaceManager

Returns the first matching <infNFe> element.

.OUTPUTS
System.Xml.XmlNode

.LINK
https://learn.microsoft.com/dotnet/api/system.xml.xmlnode.selectsinglenode
#>
function Find-XmlNodeByNamespace {
    [CmdletBinding()]
    [OutputType([System.Xml.XmlNode])]
    param (
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('Node')]
        [ValidateNotNull()]
        [System.Xml.XmlNode]$XmlNode,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$XPath,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [System.Xml.XmlNamespaceManager]$XmlNsManager
    )

    process {
        try {
            $XmlNode.SelectSingleNode($XPath, $XmlNsManager)
        } catch [System.Xml.XPath.XPathException] {
            throw [System.ArgumentException]::new(
                "Invalid XPath expression '$XPath'",
                'XPath',
                $_.Exception
            )
        }
    }
}
