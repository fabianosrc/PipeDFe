#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
Unit tests for Resolve-DFeEvento.

.DESCRIPTION
Covers event resolution by fiscal model and TipoEvento,
including model-specific event meanings, unsupported events,
unknown models, input validation, and return contract.

Contexts:
  NF-e events                  - all eight supported TipoEvento codes
  CT-e events                  - all five supported TipoEvento codes
  CT-e OS events               - all three supported TipoEvento codes
  MDF-e events                 - all six supported TipoEvento codes
  NFCom events                 - Cancelamento only
  Model-specific resolution    - ambiguous codes and cross-model isolation
  Unsupported events           - unknown codes, excluded EPEC, absent 110117
  Input validation             - mandatory parameters and ValidatePattern
  Result contract              - return type, count, and silent failure
#>

BeforeDiscovery {
    $moduleRoot = (Get-Item $PSScriptRoot).Parent.Parent.Parent.Parent.FullName

    $moduleName = Join-Path -Path $moduleRoot -ChildPath 'PipeDFe.psd1'

    Import-Module -Name $moduleName -Force -Global -ErrorAction Stop
}

Describe 'Resolve-DFeEvento' {

    InModuleScope PipeDFe {

        Context 'NF-e events' {

            It 'Resolves CartaCorrecao' {
                $result = Resolve-DFeEvento -Modelo ([ModeloDFe]::NFe) -TipoEvento '110110'
                $result | Should -Be ([DFeEvento]::CartaCorrecao)
            }

            It 'Resolves Cancelamento' {
                $result = Resolve-DFeEvento -Modelo ([ModeloDFe]::NFe) -TipoEvento '110111'
                $result | Should -Be ([DFeEvento]::Cancelamento)
            }

            It 'Resolves CancelamentoSubstituicao' {
                $result = Resolve-DFeEvento -Modelo ([ModeloDFe]::NFe) -TipoEvento '110112'
                $result | Should -Be ([DFeEvento]::CancelamentoSubstituicao)
            }

            It 'Resolves AtorInteressadoTransportador' {
                $result = Resolve-DFeEvento -Modelo ([ModeloDFe]::NFe) -TipoEvento '110150'
                $result | Should -Be ([DFeEvento]::AtorInteressadoTransportador)
            }

            It 'Resolves PedidoProrrogacao1Prazo' {
                $result = Resolve-DFeEvento -Modelo ([ModeloDFe]::NFe) -TipoEvento '111500'
                $result | Should -Be ([DFeEvento]::PedidoProrrogacao1Prazo)
            }

            It 'Resolves PedidoProrrogacao2Prazo' {
                $result = Resolve-DFeEvento -Modelo ([ModeloDFe]::NFe) -TipoEvento '111501'
                $result | Should -Be ([DFeEvento]::PedidoProrrogacao2Prazo)
            }

            It 'Resolves CancelamentoProrrogacao1Prazo' {
                $result = Resolve-DFeEvento -Modelo ([ModeloDFe]::NFe) -TipoEvento '111502'
                $result | Should -Be ([DFeEvento]::CancelamentoProrrogacao1Prazo)
            }

            It 'Resolves CancelamentoProrrogacao2Prazo' {
                $result = Resolve-DFeEvento -Modelo ([ModeloDFe]::NFe) -TipoEvento '111503'
                $result | Should -Be ([DFeEvento]::CancelamentoProrrogacao2Prazo)
            }
        }

        Context 'CT-e events' {

            It 'Resolves CartaCorrecao' {
                $result = Resolve-DFeEvento -Modelo ([ModeloDFe]::CTe) -TipoEvento '110110'
                $result | Should -Be ([DFeEvento]::CartaCorrecao)
            }

            It 'Resolves Cancelamento' {
                $result = Resolve-DFeEvento -Modelo ([ModeloDFe]::CTe) -TipoEvento '110111'
                $result | Should -Be ([DFeEvento]::Cancelamento)
            }

            It 'Resolves RegistroMultimodal' {
                $result = Resolve-DFeEvento -Modelo ([ModeloDFe]::CTe) -TipoEvento '110160'
                $result | Should -Be ([DFeEvento]::RegistroMultimodal)
            }

            It 'Resolves ComprovanteEntrega' {
                $result = Resolve-DFeEvento -Modelo ([ModeloDFe]::CTe) -TipoEvento '110180'
                $result | Should -Be ([DFeEvento]::ComprovanteEntrega)
            }

            It 'Resolves CancelamentoComprovanteEntrega' {
                $result = Resolve-DFeEvento -Modelo ([ModeloDFe]::CTe) -TipoEvento '110181'
                $result | Should -Be ([DFeEvento]::CancelamentoComprovanteEntrega)
            }
        }

        Context 'CT-e OS events' {

            It 'Resolves CartaCorrecao' {
                $result = Resolve-DFeEvento -Modelo ([ModeloDFe]::CTeOS) -TipoEvento '110110'
                $result | Should -Be ([DFeEvento]::CartaCorrecao)
            }

            It 'Resolves Cancelamento' {
                $result = Resolve-DFeEvento -Modelo ([ModeloDFe]::CTeOS) -TipoEvento '110111'
                $result | Should -Be ([DFeEvento]::Cancelamento)
            }

            It 'Resolves InformacoesGTV' {
                $result = Resolve-DFeEvento -Modelo ([ModeloDFe]::CTeOS) -TipoEvento '110170'
                $result | Should -Be ([DFeEvento]::InformacoesGTV)
            }
        }

        Context 'MDF-e events' {

            It 'Resolves Cancelamento' {
                $result = Resolve-DFeEvento -Modelo ([ModeloDFe]::MDFe) -TipoEvento '110111'
                $result | Should -Be ([DFeEvento]::Cancelamento)
            }

            It 'Resolves Encerramento' {
                $result = Resolve-DFeEvento -Modelo ([ModeloDFe]::MDFe) -TipoEvento '110112'
                $result | Should -Be ([DFeEvento]::Encerramento)
            }

            It 'Resolves InclusaoCondutor' {
                $result = Resolve-DFeEvento -Modelo ([ModeloDFe]::MDFe) -TipoEvento '110114'
                $result | Should -Be ([DFeEvento]::InclusaoCondutor)
            }

            It 'Resolves InclusaoDFe' {
                $result = Resolve-DFeEvento -Modelo ([ModeloDFe]::MDFe) -TipoEvento '110115'
                $result | Should -Be ([DFeEvento]::InclusaoDFe)
            }

            It 'Resolves PagamentoOperacaoTransporte' {
                $result = Resolve-DFeEvento -Modelo ([ModeloDFe]::MDFe) -TipoEvento '110116'
                $result | Should -Be ([DFeEvento]::PagamentoOperacaoTransporte)
            }

            It 'Resolves AlteracaoPagamentoTransporte' {
                $result = Resolve-DFeEvento -Modelo ([ModeloDFe]::MDFe) -TipoEvento '110118'
                $result | Should -Be ([DFeEvento]::AlteracaoPagamentoTransporte)
            }
        }

        Context 'NFCom events' {

            It 'Resolves Cancelamento' {
                $result = Resolve-DFeEvento -Modelo ([ModeloDFe]::NFCom) -TipoEvento '110111'
                $result | Should -Be ([DFeEvento]::Cancelamento)
            }
        }

        Context 'Model-specific resolution' {

            It 'Resolves 110112 as CancelamentoSubstituicao for NF-e and as Encerramento for MDF-e' {
                $nfe  = Resolve-DFeEvento -Modelo ([ModeloDFe]::NFe)  -TipoEvento '110112'
                $mdfe = Resolve-DFeEvento -Modelo ([ModeloDFe]::MDFe) -TipoEvento '110112'

                $nfe  | Should -Be ([DFeEvento]::CancelamentoSubstituicao)
                $mdfe | Should -Be ([DFeEvento]::Encerramento)
            }

            It 'Does not resolve a CT-e-only event for CT-e OS' {
                Resolve-DFeEvento -Modelo ([ModeloDFe]::CTeOS) -TipoEvento '110160' |
                    Should -BeNullOrEmpty
            }

            It 'Does not resolve a CT-e OS-only event for CT-e' {
                Resolve-DFeEvento -Modelo ([ModeloDFe]::CTe) -TipoEvento '110170' |
                    Should -BeNullOrEmpty
            }

            It 'Does not resolve an NF-e-only event for CT-e' {
                Resolve-DFeEvento -Modelo ([ModeloDFe]::CTe) -TipoEvento '111500' |
                    Should -BeNullOrEmpty
            }
        }

        Context 'Unsupported events' {

            It 'Returns no output for an unknown TipoEvento' {
                Resolve-DFeEvento -Modelo ([ModeloDFe]::NFe) -TipoEvento '999999' |
                    Should -BeNullOrEmpty
            }

            It 'Returns no output for 110117' {
                Resolve-DFeEvento -Modelo ([ModeloDFe]::MDFe) -TipoEvento '110117' |
                    Should -BeNullOrEmpty
            }

            It 'Returns no output for the NF-e EPEC event' {
                Resolve-DFeEvento -Modelo ([ModeloDFe]::NFe) -TipoEvento '110140' |
                    Should -BeNullOrEmpty
            }

            It 'Returns no output for the CT-e EPEC event' {
                Resolve-DFeEvento -Modelo ([ModeloDFe]::CTe) -TipoEvento '110113' |
                    Should -BeNullOrEmpty
            }
        }

        Context 'Input validation' {

            It 'Defines Modelo as mandatory' {
                $command   = Get-Command -Name Resolve-DFeEvento
                $parameter = $command.Parameters['Modelo']

                $parameter.Attributes |
                    Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] } |
                    ForEach-Object Mandatory |
                    Should -Contain $true
            }

            It 'Defines TipoEvento as mandatory' {
                $command   = Get-Command -Name Resolve-DFeEvento
                $parameter = $command.Parameters['TipoEvento']

                $parameter.Attributes |
                    Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] } |
                    ForEach-Object Mandatory |
                    Should -Contain $true
            }

            It 'Rejects a null TipoEvento' {
                { Resolve-DFeEvento -Modelo ([ModeloDFe]::NFe) -TipoEvento $null } |
                    Should -Throw
            }

            It 'Rejects an empty TipoEvento' {
                { Resolve-DFeEvento -Modelo ([ModeloDFe]::NFe) -TipoEvento '' } |
                    Should -Throw
            }

            It 'Rejects a TipoEvento with fewer than six digits' {
                { Resolve-DFeEvento -Modelo ([ModeloDFe]::NFe) -TipoEvento '11011' } |
                    Should -Throw
            }

            It 'Rejects a TipoEvento with more than six digits' {
                { Resolve-DFeEvento -Modelo ([ModeloDFe]::NFe) -TipoEvento '1101100' } |
                    Should -Throw
            }

            It 'Rejects a TipoEvento with non-ASCII digits' {
                { Resolve-DFeEvento -Modelo ([ModeloDFe]::NFe) -TipoEvento 'ABCDEF' } |
                    Should -Throw
            }
        }

        Context 'Result contract' {

            It 'Returns a value of type DFeEvento for a supported combination' {
                $result = Resolve-DFeEvento -Modelo ([ModeloDFe]::NFe) -TipoEvento '110111'
                $result.GetType() | Should -Be ([DFeEvento])
            }

            It 'Returns exactly one value for a supported combination' {
                $results = @(Resolve-DFeEvento -Modelo ([ModeloDFe]::NFe) -TipoEvento '110111')
                $results | Should -HaveCount 1
            }

            It 'Returns no output for an unsupported combination' {
                $results = @(Resolve-DFeEvento -Modelo ([ModeloDFe]::NFe) -TipoEvento '999999')
                $results | Should -HaveCount 0
            }
        }
    }

    AfterAll {
        Remove-Module -Name PipeDFe -Force -ErrorAction SilentlyContinue
    }
}
