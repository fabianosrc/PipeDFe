<#
.SYNOPSIS
Defines the supported DFe event mappings.

.DESCRIPTION
Initializes the internal lookup table used to identify Brazilian
electronic fiscal events (DFe) based on the fiscal model and
the event type code (tpEvento).

Each entry associates a fiscal model and tpEvento code with its
corresponding semantic DFeEvento value.

The same tpEvento code may represent different events depending
on the fiscal model. Therefore, event resolution always requires
both dimensions: ModeloDFe and tpEvento.

This file is loaded when the module is imported and is intended
for internal use only.

.NOTES
This file is not part of the module public API.

EPEC events are intentionally excluded from the current scope.

The tpEvento code 110117 is not used by any supported fiscal model
and is intentionally absent from the map.

CT-e (modelo 57) and CT-e OS (modelo 67) are maintained as separate
mappings because their supported event sets differ.

To add a supported event, add its tpEvento entry under the
appropriate fiscal model. To add a new fiscal model, add a new
top-level mapping.
#>
$Script:DFeEventoMap = @{

    # NF-e - modelo 55
    [ModeloDFe]::NFe = @{
        '110110' = [DFeEvento]::CartaCorrecao
        '110111' = [DFeEvento]::Cancelamento
        '110112' = [DFeEvento]::CancelamentoSubstituicao
        '110150' = [DFeEvento]::AtorInteressadoTransportador
        '111500' = [DFeEvento]::PedidoProrrogacao1Prazo
        '111501' = [DFeEvento]::PedidoProrrogacao2Prazo
        '111502' = [DFeEvento]::CancelamentoProrrogacao1Prazo
        '111503' = [DFeEvento]::CancelamentoProrrogacao2Prazo
    }

    # CT-e - modelo 57
    [ModeloDFe]::CTe = @{
        '110110' = [DFeEvento]::CartaCorrecao
        '110111' = [DFeEvento]::Cancelamento
        '110160' = [DFeEvento]::RegistroMultimodal
        '110180' = [DFeEvento]::ComprovanteEntrega
        '110181' = [DFeEvento]::CancelamentoComprovanteEntrega
    }

    # CT-e OS - modelo 67
    [ModeloDFe]::CTeOS = @{
        '110110' = [DFeEvento]::CartaCorrecao
        '110111' = [DFeEvento]::Cancelamento
        '110170' = [DFeEvento]::InformacoesGTV
    }

    # MDF-e - modelo 58
    [ModeloDFe]::MDFe = @{
        '110111' = [DFeEvento]::Cancelamento
        '110112' = [DFeEvento]::Encerramento
        '110114' = [DFeEvento]::InclusaoCondutor
        '110115' = [DFeEvento]::InclusaoDFe
        '110116' = [DFeEvento]::PagamentoOperacaoTransporte
        '110118' = [DFeEvento]::AlteracaoPagamentoTransporte
    }

    # NFCom - modelo 62
    [ModeloDFe]::NFCom = @{
        '110111' = [DFeEvento]::Cancelamento
    }
}
