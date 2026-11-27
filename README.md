<p align="center">
  <img src="docs/assets/PipeDFe.svg" alt="PipeDFe" width="720">
</p>

# PipeDFe

**Automação da ingestão, do processamento e do envio de documentos fiscais eletrônicos (DF-e) com PowerShell.**

O PipeDFe é um módulo PowerShell desenvolvido para automatizar a preparação e o envio de documentos fiscais eletrônicos à contabilidade. A partir dos arquivos XML disponíveis nos diretórios configurados, o módulo identifica e processa os documentos, organiza os arquivos por modelo fiscal, gera relatórios e realiza o envio por e-mail.

O processamento é feito por empresa e por período, sem depender de um ERP específico, de um sistema contábil ou da organização de pastas adotada pelo sistema de origem.

> **Estado do projeto:** em desenvolvimento. O manifesto declara a versão `0.1.0`. A versão `1.0.0` ainda não foi publicada ou homologada para uso em produção.

## Funcionalidades

- Ingestão e indexação de XMLs fiscais disponíveis nas pastas configuradas.
- Processamento dos documentos conforme as regras implementadas para cada modelo.
- Identificação de lacunas de numeração nos modelos aplicáveis, considerando inutilizações conhecidas.
- Geração de arquivos ZIP separados por modelo fiscal e período.
- Geração de relatório analítico HTML para NF-e e NFC-e, separado dos arquivos ZIP.
- Envio por SMTP para os destinatários cadastrados, com configuração global ou específica por empresa.
- Registro persistente das execuções e dos estados de entrega para controlar reprocessamentos e evitar envios duplicados.
- Diagnóstico dos índices SQLite utilizados pelo módulo.

O PipeDFe **não emite documentos fiscais nem realiza a captura ou o download de XMLs** da SEFAZ ou dos municípios. Os arquivos devem estar disponíveis antes da execução. O conteúdo dos XMLs orienta a identificação e o processamento dos documentos, sem exigir uma convenção de nomes de arquivos do ERP.

## Documentos fiscais

| Documento | Modelo | Tratamento |
| --- | --- | --- |
| Nota Fiscal Eletrônica (NF-e) | 55 | Processamento fiscal normalizado, indexação e arquivamento |
| Nota Fiscal de Consumidor Eletrônica (NFC-e) | 65 | Processamento fiscal normalizado, indexação e arquivamento |
| Nota Fiscal Fatura de Serviços de Comunicação Eletrônica (NFCom) | 62 | Processamento fiscal normalizado, indexação e arquivamento |
| Conhecimento de Transporte Eletrônico (CT-e) | 57 | Indexação, análise de lacunas e arquivamento |
| Manifesto Eletrônico de Documentos Fiscais (MDF-e) | 58 | Indexação, análise de lacunas e arquivamento |
| Nota Fiscal de Serviço Eletrônica Nacional (NFS-e) | — | Importação e arquivamento em fluxo próprio |

A NFS-e Nacional utiliza a origem opcional `XmlPathNfse`. Empresas que emitem apenas NFS-e também são atendidas pelo fluxo, embora o cadastro da empresa ainda exija um diretório principal em `XmlPath`.

Os ZIPs são gerados por modelo. Quando há eventos associados a um documento, os arquivos relacionados podem ser agrupados pela chave de acesso. O relatório HTML de NF-e e NFC-e permanece fora dos ZIPs e acompanha o e-mail de fechamento quando há documentos desses modelos.

## Requisitos

- Windows, com Windows PowerShell 5.1 ou PowerShell 7.
- Bibliotecas SQLite gerenciadas e nativas incluídas na distribuição, compatíveis com a arquitetura do processo PowerShell.
- Permissão de leitura nos diretórios de XML e de escrita nos diretórios de configuração, índices e saída.
- Para o envio: servidor SMTP acessível, autenticação quando exigida e destinatários configurados.

O módulo não oferece suporte ao carregamento em sistemas operacionais não Windows. Os arquivos `PipeDFe.psd1` e `PipeDFe.psm1` não são suficientes isoladamente: a distribuição também precisa incluir `src` e `lib`.

## Instalação para desenvolvimento

Clone o repositório e importe o manifesto a partir da raiz do projeto:

```powershell
$repositoryPath = 'C:\Workspace\Projects\PipeDFe'
$manifestPath = Join-Path -Path $repositoryPath -ChildPath 'PipeDFe.psd1'

Import-Module -Name $manifestPath -Force -ErrorAction Stop
Get-Command -Module PipeDFe
```

A instalação pela PowerShell Gallery será documentada após a publicação de uma versão.

## Configuração e uso

### 1. Cadastrar uma empresa

O diretório `XmlPath` deve existir antes do cadastro. Se informado, `XmlPathNfse` também deve existir. O diretório de saída pode ser criado pelo módulo.

```powershell
$companyParams = @{
    Cnpj         = '11222333000181'
    RazaoSocial  = 'EMPRESA EXEMPLO LTDA'
    NomeFantasia = 'EMPRESA EXEMPLO'
    Uf           = 'SP'
    Ambiente     = 'Homologacao'
    XmlPath      = 'C:\Fiscal\EmpresaExemplo\XML'
    XmlPathNfse  = 'C:\Fiscal\EmpresaExemplo\NFSe'
    OutputPath   = 'C:\Fiscal\EmpresaExemplo\Fechamentos'
    EmailPara    = 'contabilidade@example.com'
    ErrorAction  = 'Stop'
}

New-PipeCompany @companyParams
```

Os caminhos, o CNPJ e o endereço eletrônico são ilustrativos. `NomeFantasia`, `XmlPathNfse` e `OutputPath` são opcionais. Para empresas sem NFS-e Nacional, omita `XmlPathNfse`.

Consulte os cadastros com:

```powershell
Get-PipeCompany
Get-PipeCompany -Cnpj '11222333000181'
```

Os destinatários podem ser definidos por `EmailPara`, `EmailCc` e `EmailCco` no cadastro ou atualizados com `Set-PipeCompany`.

### 2. Configurar o SMTP

O SMTP pode ser configurado globalmente ou por empresa. As credenciais persistidas são protegidas com DPAPI, vinculada ao contexto do Windows; leve isso em consideração ao migrar configurações entre usuários ou computadores.

```powershell
$password = Read-Host -Prompt 'SMTP password' -AsSecureString

$smtpParams = @{
    Server      = 'smtp.example.com'
    Port        = 587
    Ssl         = $true
    Username    = 'conta@example.com'
    Password    = $password
    From        = 'Empresa Exemplo <conta@example.com>'
    ErrorAction = 'Stop'
}

Set-PipeSmtp @smtpParams
```

Antes de usar destinatários reais, teste a configuração em um ambiente controlado:

```powershell
Test-PipeSmtp
```

**Atenção:** `Test-PipeSmtp` envia uma mensagem de teste para o endereço configurado como remetente.

### 3. Executar o processamento e o envio

Por padrão, `Invoke-PipeDFe` utiliza o mês civil completo anterior e considera todas as empresas ativas. É possível restringir a execução a uma empresa e a um intervalo de datas.

```powershell
# Visualizar as operações previstas
Invoke-PipeDFe -WhatIf

# Processar uma empresa em um período específico
$invokeParams = @{
    Cnpj      = '11222333000181'
    StartDate = '01/10/2026'
    EndDate   = '31/10/2026'
    Verbose   = $true
}

$result = Invoke-PipeDFe @invokeParams
$result.Results | Format-Table Cnpj, Status, TotalDocumentos, Gaps, EmailEnviado
```

`-WhatIf` apresenta uma prévia da execução; não valida integralmente os XMLs nem realiza um teste de entrega por SMTP. Após o processamento, consulte `Status`, `Avisos` e `Erro` nos resultados por empresa. A geração dos arquivos não comprova que o envio foi concluído.

### 4. Consultar lacunas de numeração

```powershell
$gapParams = @{
    Cnpj      = '11222333000181'
    StartDate = '01/10/2026'
    EndDate   = '31/10/2026'
}

Get-PipeDFeSequenceGap @gapParams
```

Uma lacuna indica que determinado número não foi localizado no índice. Isso não comprova, isoladamente, a emissão ou a ausência de um documento fiscal. A análise considera inutilizações conhecidas, e NFS-e não participa da verificação de sequência.

## Controle das entregas

O PipeDFe mantém um histórico persistente das entregas, com estados como `Prepared`, `Sending`, `Delivered`, `Failed` e `Indeterminate`.

Uma entrega confirmada como `Delivered` não deve ser reenviada automaticamente nas mesmas condições. Quando o resultado de uma tentativa de SMTP não pode ser determinado, a entrega permanece em `Indeterminate` e o reenvio automático é bloqueado. Interrupções durante a etapa de envio exigem o mesmo cuidado.

Antes de realizar qualquer reenvio manual, confira os registros da execução e confirme o recebimento com o destinatário. A aceitação da mensagem pelo servidor SMTP não garante sua entrega final à caixa postal.

## Diagnóstico

```powershell
Get-PipeCompany
Get-PipeSmtp
Get-PipeDFeHealth
```

`Get-PipeDFeHealth` verifica a presença e a versão do schema dos índices SQLite das empresas cadastradas. Os diagnósticos são classificados como `Healthy`, `Degraded` ou `Unhealthy`. Esse comando não testa a conectividade SMTP.

## Testes e build

Os testes automatizados utilizam Pester e estão organizados em suítes unitárias e de integração. Os testes de integração incluem cenários que exercitam persistência e SQLite reais.

```powershell
Invoke-Pester -Path .\tests\Unit -Output Detailed
Invoke-Pester -Path .\tests\Integration -Output Detailed
```

O pipeline de CI executa verificações no Windows PowerShell 5.1 e no PowerShell 7, com meta mínima de 80% de cobertura de código.

Para gerar uma distribuição local, execute:

```powershell
.\tools\Invoke-Build.ps1
```

O processo de build executa as verificações previstas pelo script da versão utilizada. O empacotamento da ajuda localizada e a validação dos artefatos devem ser confirmados antes de qualquer publicação. Consulte [`RELEASE.md`](RELEASE.md) para os critérios de preparação e homologação de uma versão.

## Ajuda

O módulo possui documentação de comandos e tópicos conceituais em português do Brasil (`pt-BR`) e inglês (`en-US`).

```powershell
Get-Help about_PipeDFe
Get-Help Invoke-PipeDFe -Full
Get-Help Get-PipeDFeHealth -Examples
```

A documentação localizada é distribuída com o módulo empacotado. Ao importar diretamente o código-fonte do repositório, a descoberta da ajuda pode depender do layout de instalação.

## Limitações e cuidados

- Utilize XMLs de teste ou dados autorizados durante a homologação.
- Não inclua documentos fiscais de clientes, certificados ou credenciais em commits e artefatos públicos.
- Confira os ZIPs e os relatórios gerados antes de habilitar envios para destinatários reais.
- Teste reexecuções e falhas de transporte sem contornar o controle persistente de entregas.
- O módulo não substitui a conferência fiscal e contábil.

## Licença

Distribuído sob a [Apache License 2.0](LICENSE).

---

[Repositório no GitHub](https://github.com/fabianosrc/PipeDFe) · [Histórico de alterações](CHANGELOG.md) · [Processo de release](RELEASE.md)
