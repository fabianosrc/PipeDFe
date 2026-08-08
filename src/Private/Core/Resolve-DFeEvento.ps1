<#
.SYNOPSIS
Resolves a DFe event from its fiscal model and event type code.

.DESCRIPTION
Resolves the semantic DFeEvento value associated with a fiscal model
(ModeloDFe) and an event type code (tpEvento).

The same tpEvento may represent different events depending on the
fiscal model, therefore both values are required for resolution.

Returns no output when the fiscal model or tpEvento combination is not
supported.

.PARAMETER Modelo
The fiscal model of the parent DFe document.

.PARAMETER TipoEvento
The six-digit SEFAZ event type code.

.OUTPUTS
DFeEvento

.EXAMPLE
PS C:\> Resolve-DFeEvento -Modelo ([ModeloDFe]::NFe) -TipoEvento '110111'

Returns [DFeEvento]::Cancelamento.

.EXAMPLE
PS C:\> Resolve-DFeEvento -Modelo ([ModeloDFe]::MDFe) -TipoEvento '110112'

Returns [DFeEvento]::Encerramento.

.EXAMPLE
PS C:\> Resolve-DFeEvento -Modelo ([ModeloDFe]::NFe) -TipoEvento '999999'

Returns no output because the event is not supported.

.NOTES
Resolution is delegated entirely to DFeEventoMap, which is the single
source of truth for supported ModeloDFe and tpEvento combinations.
#>
function Resolve-DFeEvento {
    [CmdletBinding()]
    [OutputType([DFeEvento])]
    param (
        [Parameter(Mandatory)]
        [ModeloDFe]$Modelo,

        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9]{6}$')]
        [string]$TipoEvento
    )

    process {
        $modelMap = $Script:DFeEventoMap[$Modelo]

        if ($null -eq $modelMap) {
            return
        }

        $evento = $modelMap[$TipoEvento]

        if ($null -eq $evento) {
            return
        }

        $evento
    }
}
