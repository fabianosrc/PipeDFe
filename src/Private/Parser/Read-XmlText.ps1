<#
.SYNOPSIS
Safely extracts the inner text of an XML node.

.DESCRIPTION
Returns the trimmed InnerText of an XML node.
Returns $null if the node is null or if its InnerText is empty or consists
only of whitespace.

.PARAMETER XmlNode
The XML node to read from. Accepts $null and pipeline input (by value or by
property name), allowing multiple nodes to be processed in a single call.

.EXAMPLE
PS C:\> $node | Read-XmlText

.OUTPUTS
System.String
#>
function Read-XmlText {
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('Node')]
        [AllowNull()]
        [System.Xml.XmlNode]$XmlNode
    )

    process {
        if ($null -eq $XmlNode) {
            return $null
        }

        $innerText = $XmlNode.InnerText

        if (-not [string]::IsNullOrWhiteSpace($innerText)) {
            return $innerText.Trim()
        }
    }
}
