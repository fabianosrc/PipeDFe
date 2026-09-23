<#
.SYNOPSIS
Gets the document type and fiscal model from a DFe XML document.

.DESCRIPTION
Identifies the DFe document based on its XML structure.

For document families whose XML root uniquely identifies the fiscal model,
the model is resolved directly from DFeDocumentMap.

NF-e and NFC-e share the same NFe/nfeProc XML root family. When the document
contains ide/mod, that value is therefore authoritative for distinguishing:

    55 -> NF-e
    65 -> NFC-e

When ide/mod is absent, the root mapping is retained as a compatibility
fallback. This preserves classification of structural/minimal XML documents
used by existing callers and tests.

If an explicit ide/mod value is present for the NFe family but is unsupported,
no document information is returned.

.PARAMETER Xml
The XML document to inspect.

.OUTPUTS
PSCustomObject
  Tipo   [TipoXmlDFe]
  Modelo [ModeloDFe]
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

        $modelo = $mapping.Modelo

        # NF-e and NFC-e share the same XML root family. Root name alone
        # cannot distinguish model 55 from model 65.
        if ($root.LocalName -in @('NFe', 'nfeProc')) {
            $modNode = $Xml.SelectSingleNode(
                "//*[local-name()='infNFe']" +
                "/*[local-name()='ide']" +
                "/*[local-name()='mod']"
            )

            if ($null -ne $modNode -and
                -not [string]::IsNullOrWhiteSpace($modNode.InnerText)) {

                $modelo = switch ($modNode.InnerText.Trim()) {
                    '55' {
                        [ModeloDFe]::NFe
                        break
                    }

                    '65' {
                        [ModeloDFe]::NFCe
                        break
                    }

                    default {
                        return
                    }
                }
            }
        }

        [pscustomobject]@{
            Tipo   = $mapping.Tipo
            Modelo = $modelo
        }
    }
}
