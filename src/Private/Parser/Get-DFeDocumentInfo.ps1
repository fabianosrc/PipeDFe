<#
.SYNOPSIS
Gets the document type and fiscal model from a DFe XML document.

.DESCRIPTION
Identifies the DFe document based on the XML root element.

Accepts pipeline input and returns an object containing the
document type and fiscal model.

If the document cannot be identified, no object is returned.

.PARAMETER Xml
The XML document to inspect. Accepts pipeline input, allowing
multiple documents to be processed in a single call.

.OUTPUTS
PSCustomObject

.EXAMPLE
PS C:> $xml | Get-DFeDocumentInfo

Returns the document type and fiscal model of the XML document.

.EXAMPLE
PS C:> $documents | Get-DFeDocumentInfo

Processes multiple XML documents from the pipeline.

.EXAMPLE
PS C:> $info = Get-DFeDocumentInfo -Xml $xml
PS C:> $info.Modelo

Returns the fiscal model of the document.
#>
function Get-DFeDocumentInfo {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
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

        $mapping = $Script:DFeDocumentMap[$root.LocalName]

        if ($null -eq $mapping) {
            return
        }

        [PSCustomObject]@{
            Tipo   = $mapping.Tipo
            Modelo = $mapping.Modelo
        }
    }
}
