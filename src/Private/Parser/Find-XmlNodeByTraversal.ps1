<#
.SYNOPSIS
Finds the first XML element with the specified local name.

.DESCRIPTION
Traverses the XML DOM starting from the specified root node and returns the
first element whose LocalName matches the supplied value.

Traversal is performed iteratively using a stack to avoid recursion.

This function does not evaluate XPath expressions and should be used only as
a last-resort lookup strategy when XPath-based searches fail.

.PARAMETER XmlNode
The root XML node where the search begins.

.PARAMETER LocalName
The XML local name to search for.

.EXAMPLE
PS C:\> $document.DocumentElement |
>> Find-XmlNodeByTraversal -LocalName 'emit'

Returns the first <emit> element found in the document.

.OUTPUTS
System.Xml.XmlNode

.LINK
https://learn.microsoft.com/dotnet/api/system.xml.xmlnode.selectsinglenode
#>
function Find-XmlNodeByTraversal {
    [CmdletBinding()]
    [OutputType([System.Xml.XmlNode])]
    param (
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('Node')]
        [System.Xml.XmlNode]$XmlNode,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$LocalName
    )

    process {
        $stack = [System.Collections.Generic.Stack[System.Xml.XmlNode]]::new()
        $stack.Push($XmlNode)

        while ($stack.Count -gt 0) {
            $currentNode = $stack.Pop()

            if ($currentNode -is [System.Xml.XmlElement] -and
                $currentNode.LocalName -eq $LocalName
            ) {
                return $currentNode
            }

            foreach ($childNode in $currentNode.ChildNodes) {
                if ($childNode -is [System.Xml.XmlElement]) {
                    $stack.Push($childNode)
                }
            }
        }

        return
    }
}
