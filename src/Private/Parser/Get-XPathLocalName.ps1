<#
.SYNOPSIS
Extracts the target element local name from an XPath expression.

.DESCRIPTION
Extracts the local name of the last element referenced by an XPath expression.

Namespace prefixes, predicates, and attribute selectors are ignored.

Returns $null if the XPath expression does not contain a valid element name.

.PARAMETER XPath
The XPath expression to analyze.

.EXAMPLE
PS C:\> Get-XPathLocalName -XPath 'nfe:infNFe/nfe:emit/nfe:xNome'

Returns: xNome

.EXAMPLE
PS C:\> Get-XPathLocalName -XPath '//cte:emit[@Id="1"]'

Returns: emit

.OUTPUTS
System.String
#>
function Get-XPathLocalName {
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$XPath
    )

    $normalizedXPath = $XPath -replace '\[[^\]]+\]', ''

    $localName = (
        $normalizedXPath -split '/' |
            Where-Object {
                $_ -and $_ -notmatch '^@'
            } |
            ForEach-Object {
                ($_ -split ':')[-1]
            } |
            Select-Object -Last 1
    )

    if ([string]::IsNullOrWhiteSpace($localName)) {
        return $null
    }

    return $localName
}
