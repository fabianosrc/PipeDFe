<#
.SYNOPSIS
Defines the structural extraction mappings for supported DFe XML documents.

.DESCRIPTION
Initializes the internal lookup table used to determine how fiscal data
is extracted from supported DFe XML document roots.

Each entry maps an XML root element to the information node containing
the document identity and the prefix used by its Id attribute.

Document classification is handled separately by DFeDocumentMap.
This map is responsible only for XML extraction structure.

Only fiscal documents that contain a DFe access key are included.
Events and inutilization documents do not use InfoNode or IdPrefix
and must not be added to this map.

Each supported document must define entries for both its bare root
element and its processed (*Proc) root element.

.NOTES
This file initializes the internal DFeExtractionMap used by the parser.

A document classified as a fiscal Documento and requiring access-key
extraction must have a corresponding entry in this map.

This file is not part of the module public API.
#>
$Script:DFeExtractionMap = @{
    'NFe' = @{
        InfoNode = 'infNFe'
        IdPrefix = 'NFe'
    }

    'nfeProc' = @{
        InfoNode = 'infNFe'
        IdPrefix = 'NFe'
    }

    'CTe' = @{
        InfoNode = 'infCte'
        IdPrefix = 'CTe'
    }

    'cteProc' = @{
        InfoNode = 'infCte'
        IdPrefix = 'CTe'
    }

    'CTeOS' = @{
        InfoNode = 'infCte'
        IdPrefix = 'CTe'
    }

    'cteOSProc' = @{
        InfoNode = 'infCte'
        IdPrefix = 'CTe'
    }

    'MDFe' = @{
        InfoNode = 'infMDFe'
        IdPrefix = 'MDFe'
    }

    'mdfeProc' = @{
        InfoNode = 'infMDFe'
        IdPrefix = 'MDFe'
    }

    'NFCom' = @{
        InfoNode = 'infNFCom'
        IdPrefix = 'NFCom'
    }

    'nfcomProc' = @{
        InfoNode = 'infNFCom'
        IdPrefix = 'NFCom'
    }
}
