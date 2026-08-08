<#
.SYNOPSIS
Extracts the namespace URI from the root element of a DFe XML document.

.DESCRIPTION
Returns the NamespaceURI of the DocumentElement of the provided XmlDocument.

The function performs pure structural extraction. It does not validate or
identify the document type - it returns whatever namespace URI is declared
on the root element, regardless of whether it corresponds to a known DFe
namespace.

The function produces no output when:

* The document has no root element (empty XmlDocument).
* The root element declares no namespace (NamespaceURI is an empty string).

Document type identification and namespace validation are the responsibility
of the caller.

.PARAMETER Xml
The XML document from which to extract the root namespace URI.

.OUTPUTS
System.String

Returns the NamespaceURI of the root element for valid input.

.EXAMPLE
PS C:\> [xml]$doc = Get-Content -Path '.\nfe.xml' -Raw
PS C:\> Get-DFeDocumentNamespace -Xml $doc

http://www.portalfiscal.inf.br/nfe

Extracts the namespace URI from an NF-e document.

.EXAMPLE
PS C:\> [xml]$doc = Get-Content -Path '.\cte.xml' -Raw
PS C:\> $doc | Get-DFeDocumentNamespace

http://www.portalfiscal.inf.br/cte

Extracts the namespace URI from a CT-e document via pipeline.
#>
function Get-DFeDocumentNamespace {
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory, ValueFromPipeline)]
        [ValidateNotNull()]
        [System.Xml.XmlDocument]$Xml
    )

    process {
        $root = $Xml.DocumentElement

        if ($null -eq $root) {
            return
        }

        $namespace = $root.NamespaceURI

        if ([string]::IsNullOrEmpty($namespace)) {
            return
        }

        $namespace
    }
}
