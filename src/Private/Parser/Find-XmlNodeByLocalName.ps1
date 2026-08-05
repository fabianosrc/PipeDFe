<#
.SYNOPSIS
Finds a single XML node using a namespace-agnostic XPath expression.

.DESCRIPTION
Converts namespace-qualified element names in the supplied XPath expression
to equivalent local-name() predicates and executes the resulting XPath
expression.

This strategy is intended as a fallback when namespace-aware XPath lookup
fails or when namespace prefixes differ from those expected.

Returns the first matching XML node or $null if no matching node is found.

This function does not perform manual DOM traversal. That responsibility
belongs to higher-level fallback strategies.

.PARAMETER XmlNode
The XML node that serves as the context for the XPath evaluation.

.PARAMETER XPath
The XPath expression used to locate the target node.

Namespace-qualified element names are converted to local-name() predicates
before evaluation.

.EXAMPLE
PS C:\> $document.DocumentElement |
>> Find-XmlNodeByLocalName -XPath 'nfe:infNFe/nfe:emit'

Returns the first matching <emit> element regardless of namespace prefix.

.OUTPUTS
System.Xml.XmlNode

.LINK
https://learn.microsoft.com/dotnet/api/system.xml.xmlnode.selectsinglenode
#>
function Find-XmlNodeByLocalName {
    [CmdletBinding()]
    [OutputType([System.Xml.XmlNode])]
    param (
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('Node')]
        [System.Xml.XmlNode]$XmlNode,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$XPath
    )

    process {
        # Convert namespace-qualified element names into local-name() predicates.
        $localNameXPath = (
            $XPath -split '/' | ForEach-Object {
                if ($_ -match '^([A-Za-z_][A-Za-z0-9_.-]*:)?([A-Za-z_][A-Za-z0-9_.-]*)$') {
                    '*[local-name()="' + $Matches[2] + '"]'
                } else {
                    $_
                }
            }
        ) -join '/'

        try {
            return $XmlNode.SelectSingleNode($localNameXPath)
        } catch [System.Xml.XPath.XPathException] {
            throw [System.ArgumentException]::new(
                "Invalid XPath expression '$XPath'",
                'XPath',
                $_.Exception
            )
        }
    }
}
