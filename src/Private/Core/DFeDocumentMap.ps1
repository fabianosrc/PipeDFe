<#
.SYNOPSIS
Defines the supported DFe XML document mappings.

.DESCRIPTION
Initializes the internal lookup table used to identify Brazilian
electronic fiscal documents (DFe) based on the XML root element.

Each entry associates an XML root element with its corresponding
business document category and fiscal model.

This file is loaded when the module is imported and is intended for
internal use only.

.NOTES
This file is not part of the module public API.
#>
$Script:DFeDocumentMap = @{
    NFe = @{
        Tipo   = [TipoXmlDFe]::Documento
        Modelo = [ModeloDFe]::NFe
    }

    nfeProc = @{
        Tipo   = [TipoXmlDFe]::Documento
        Modelo = [ModeloDFe]::NFe
    }

    CTe = @{
        Tipo   = [TipoXmlDFe]::Documento
        Modelo = [ModeloDFe]::CTe
    }

    cteProc = @{
        Tipo   = [TipoXmlDFe]::Documento
        Modelo = [ModeloDFe]::CTe
    }

    CTeOS = @{
        Tipo   = [TipoXmlDFe]::Documento
        Modelo = [ModeloDFe]::CTeOS
    }

    cteOSProc = @{
        Tipo   = [TipoXmlDFe]::Documento
        Modelo = [ModeloDFe]::CTeOS
    }

    MDFe = @{
        Tipo   = [TipoXmlDFe]::Documento
        Modelo = [ModeloDFe]::MDFe
    }

    mdfeProc = @{
        Tipo   = [TipoXmlDFe]::Documento
        Modelo = [ModeloDFe]::MDFe
    }

    NFCom = @{
        Tipo = [TipoXmlDFe]::Documento
        Modelo = [ModeloDFe]::NFCom
    }

    infNFCom = @{
        Tipo = [TipoXmlDFe]::Documento
        Modelo = [ModeloDFe]::NFCom
    }

    procEventoNFe = @{
        Tipo   = [TipoXmlDFe]::Evento
        Modelo = [ModeloDFe]::NFe
    }

    procEventoCTe = @{
        Tipo   = [TipoXmlDFe]::Evento
        Modelo = [ModeloDFe]::CTe
    }

    procEventoMDFe = @{
        Tipo   = [TipoXmlDFe]::Evento
        Modelo = [ModeloDFe]::MDFe
    }

    inutNFe = @{
        Tipo   = [TipoXmlDFe]::Inutilizacao
        Modelo = [ModeloDFe]::NFe
    }

    retInutNFe = @{
        Tipo   = [TipoXmlDFe]::Inutilizacao
        Modelo = [ModeloDFe]::NFe
    }
}
