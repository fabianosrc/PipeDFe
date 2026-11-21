# PipeDFe

**Fechamento de documentos fiscais eletrônicos com PowerShell, por empresa e por período.**

O PipeDFe é um módulo PowerShell para organizar o fechamento de XMLs fiscais e preparar sua entrega à contabilidade. O projeto foi concebido para trabalhar com os XMLs já disponíveis nas pastas configuradas, sem depender de um ERP específico, de um sistema contábil ou de uma estrutura fixa de diretórios de origem.

> **Status do projeto:** em desenvolvimento, versão `0.1.0` declarada no manifesto consultado. A versão `1.0` ainda não deve ser considerada publicada ou homologada para uso em produção. Antes de operar com dados reais, confira o código e os testes da versão que você está executando.

## Objetivo e limites

O fluxo do PipeDFe tem como finalidade:

1. Identificar a empresa e o período do fechamento.
2. Ler os XMLs existentes nos diretórios configurados e indexar os documentos reconhecidos.
3. Aplicar as validações e o processamento fiscal implementados para cada modelo.
4. Identificar possíveis lacunas de numeração nos modelos aplicáveis.
5. Gerar arquivos ZIP separados por modelo de documento fiscal.
6. Preparar relatórios do período e, quando configurada, a entrega por SMTP.
7. Registrar o processamento e o estado da entrega para permitir diagnóstico e reexecução controlada.

**O PipeDFe não é um emissor de documentos fiscais e não realiza, por si, a captura ou o download de XMLs da SEFAZ ou dos municípios.** Os documentos de entrada devem existir previamente. Ele também não substitui a conferência fiscal e contábil.

O XML é a fonte utilizada para interpretar os documentos; nomes e caminhos dos arquivos de origem não são tratados como um contrato específico de ERP.

## Documentos e processamento

O projeto contempla os seguintes modelos no fluxo de indexação, organização e arquivamento, conforme as rotinas existentes:

| Documento | Modelo | Observação |
| --- | --- | --- |
| NF-e | 55 | Participa do processamento fiscal normalizado |
| NFC-e | 65 | Participa do processamento fiscal normalizado |
| NFCom | 62 | Participa do processamento fiscal normalizado |
| CT-e | 57 | Participa do fluxo de indexação, lacunas e arquivamento |
| MDF-e | 58 | Participa do fluxo de indexação, lacunas e arquivamento |
| NFS-e Nacional | - | Usa uma origem opcional específica e um fluxo próprio de importação/arquivo |

O tratamento não é idêntico para todos os modelos. A implementação atual distingue o processamento fiscal normalizado de NF-e, NFC-e e NFCom das demais rotinas de indexação, lacunas e arquivos.

Empresas que trabalham **somente com NFS-e** fazem parte do escopo do projeto. A origem desses XMLs é configurada por `XmlPathNfse`; não é necessário inventar documentos de outros modelos para realizar seu fechamento.

### Organização dos arquivos

O fechamento gera ZIPs **separados por modelo**, respeitando a empresa e o período. Nos arquivos compactados, a organização usa um segmento de período e os XMLs não recebem uma subpasta individual apenas por sua chave de acesso.

Quando um documento possui eventos associados, o agrupamento por chave pode ser necessário para manter o documento e seus eventos relacionados. Não se deve criar essa profundidade extra para todo XML indiscriminadamente.

Os relatórios **HTML e XLSX ficam fora dos ZIPs**, como artefatos independentes do fechamento e da entrega.

> O layout exato dos nomes e caminhos gerados é definido pelas rotinas de arquivamento da versão utilizada; os exemplos deste README não devem ser interpretados como uma garantia de nomenclatura de arquivos.

## Requisitos

- **Windows**: o módulo verifica a plataforma e não oferece suporte a sistemas não Windows no carregamento atual.
- **Windows PowerShell 5.1** ou **PowerShell 7**.
- Bibliotecas gerenciadas e nativas do SQLite incluídas na distribuição do módulo, compatíveis com a arquitetura do processo PowerShell.
- Permissão de leitura nas pastas de XML e de escrita nas pastas de configuração, índices e saída.
- Para envio de e-mails: servidor SMTP acessível, credenciais e destinatários configurados.

O carregamento do módulo depende dos arquivos `lib` esperados pelo `PipeDFe.psm1`. Copiar apenas os arquivos `.psm1` e `.psd1` não é suficiente.

## Instalação para desenvolvimento

Clone o repositório e importe o manifesto a partir da raiz do projeto:

```powershell
$repositoryPath = 'C:\Workspace\Projects\PipeDFe'
$manifestPath = Join-Path -Path $repositoryPath -ChildPath 'PipeDFe.psd1'

Import-Module -Name $manifestPath -Force -ErrorAction Stop
Get-Module -Name PipeDFe
```

Não há, neste README, instrução de instalação pela PowerShell Gallery: a publicação de uma versão estável ainda precisa ser confirmada.

## Início rápido

### 1. Registrar uma empresa

O diretório de origem `XmlPath` precisa existir. A pasta de saída pode ser criada durante o cadastro.

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
    ErrorAction  = 'Stop'
}

New-PipeCompany @companyParams
```

Os caminhos acima são ilustrativos. Informe somente `XmlPathNfse` se houver uma pasta separada para NFS-e Nacional. No cadastro, `NomeFantasia` e `XmlPathNfse` são opcionais.

Para consultar o cadastro:

```powershell
Get-PipeCompany
Get-PipeCompany -Cnpj '11222333000181'
```

### 2. Configurar SMTP (opcional para o cadastro)

O servidor SMTP pode ser configurado globalmente e, quando aplicável, substituído por uma configuração específica da empresa. As senhas são protegidas com DPAPI na persistência atual; considere as implicações de usuário e máquina ao mover configurações.

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

Teste a conectividade e o envio **em uma caixa de homologação**, antes de qualquer execução com destinatários reais:

```powershell
Test-PipeSmtp
```

O teste SMTP realiza uma tentativa real de envio para o endereço configurado como remetente.

Configure os destinatários da empresa por meio dos parâmetros `EmailPara`, `EmailCc` e `EmailCco` de `New-PipeCompany`, ou atualize-os com `Set-PipeCompany`, conforme a versão instalada.

### 3. Executar o fechamento

Sem um período informado, a execução usa o **mês calendário completo anterior**. Sem `Cnpj`, considera as empresas ativas cadastradas.

```powershell
Invoke-PipeDFe -WhatIf
```

Para processar uma empresa e um intervalo específico:

```powershell
$invokeParams = @{
    Cnpj      = '11222333000181'
    StartDate = '01/10/2026'
    EndDate   = '31/10/2026'
    Verbose   = $true
}

$result = Invoke-PipeDFe @invokeParams
$result | Format-List
$result.Results | Format-Table Cnpj, Status, TotalDocumentos, Gaps, EmailEnviado
```

`-WhatIf` é uma prévia de execução, não uma homologação completa dos XMLs ou do transporte SMTP. A execução efetiva pode gerar arquivos, atualizar índices e enviar mensagens conforme a configuração.

**Atenção:** no fluxo atual, quando há documentos para entregar, a falta de SMTP ou de destinatários pode impedir que o fechamento seja considerado concluído, mesmo que arquivos já tenham sido gerados. Um fechamento sem documentos gera aviso. Consulte sempre `Status`, `Avisos` e `Erro`.

### 4. Consultar lacunas de numeração

Após existir índice para a empresa:

```powershell
$gapParams = @{
    Cnpj      = '11222333000181'
    StartDate = '01/10/2026'
    EndDate   = '31/10/2026'
}

Get-PipeDFeSequenceGap @gapParams
```

Uma lacuna indica um número **não encontrado no índice**, não prova que uma nota tenha sido emitida ou omitida. Inutilizações conhecidas são consideradas na análise. NFS-e não participa dessa verificação de sequencialidade.

## Resultado e segurança da entrega

`Invoke-PipeDFe` retorna um resultado geral (`PipeDFe.ResultadoInvoke`) e resultados por empresa (`PipeDFe.ResultadoEmpresa`). Entre os campos relevantes estão `Success`, `Results`, `Status`, `TotalDocumentos`, `Gaps`, `Arquivos`, `EmailEnviado`, `Avisos` e `Erro`.

A entrega por e-mail usa um **estado persistente**. Os estados previstos no fluxo incluem `Prepared`, `Sending`, `Delivered`, `Failed` e `Indeterminate`:

- Uma entrega já confirmada como `Delivered` não deve produzir novo envio automático da mesma entrega.
- Uma falha identificada antes da tentativa de envio pode ser tratada como `Failed` e seguir a política de reexecução do fluxo.
- Se o SMTP chegou a ser acionado e não é possível confirmar o resultado, o estado `Indeterminate` **bloqueia o reenvio automático**, para evitar duplicidade.
- Uma execução interrompida durante `Sending` também deve ser tratada conservadoramente como indeterminada.

**Não force novos envios nem apague o estado persistido para contornar um resultado indeterminado.** Verifique o histórico e o recebimento com a contabilidade antes de qualquer ação manual.

Os relatórios mensais HTML e XLSX são produzidos separadamente dos ZIPs durante o preparo da entrega, conforme o fluxo implementado. Sua geração não deve ser presumida em todo cenário, especialmente quando não há documentos ou a entrega é bloqueada antecipadamente.

## Diagnóstico e operação

Verifique os cadastros e a configuração antes de uma execução:

```powershell
Get-PipeCompany
Get-PipeSmtp
```

O projeto também possui implementação de `Get-PipeDFeHealth`, que verifica a existência do índice SQLite e compara a versão de schema de cada empresa. **A disponibilização desse comando como API pública deve ser conferida no manifesto da versão instalada**: ele não consta da lista `FunctionsToExport` do manifesto público consultado.

Ao investigar problemas, confira a pasta de origem, a data dos XMLs, o resultado por empresa, os avisos, a conectividade SMTP e os registros de auditoria/entrega. Não trate `Status = 'Aviso'` como equivalente a um envio confirmado.

### Cuidados na homologação

- Trabalhe com empresas e documentos de teste ou dados autorizados, nunca publique XMLs fiscais, certificados ou credenciais no repositório.
- Teste o SMTP em um destinatário controlado; o comando de teste realmente envia uma mensagem.
- Confira conteúdo e integridade dos ZIPs e a localização separada dos relatórios antes do uso com contabilidades reais.
- Valide reexecuções, falhas e resultados indeterminados sem provocar entregas duplicadas.

## Testes

A suíte usa **Pester** e separa os cenários unitários dos testes de integração, que exercitam persistência e SQLite reais.

```powershell
Invoke-Pester -Path .\tests\Unit -Output Detailed
Invoke-Pester -Path .\tests\Integration -Output Detailed
```

Para executar somente a integração do diagnóstico de saúde:

```powershell
Invoke-Pester -Path .\tests\Integration\Public\Health\Get-PipeDFeHealth.Tests.ps1 -Output Detailed
```

Execute os testes nos ambientes Windows PowerShell 5.1 e PowerShell 7 relevantes antes de publicar uma versão. Passar nos testes não substitui a homologação de ponta a ponta com o SMTP e os documentos fiscais pretendidos.

## Estado da versão 1.0

O objetivo para a v1.0 inclui fechamento mensal confiável por empresa; modelos fiscais suportados; NFS-e Nacional; ZIPs por modelo com eventos associados; relatórios HTML/XLSX externos aos ZIPs; entrega SMTP com deduplicação persistente; avisos operacionais, inclusive de certificado quando aplicáveis; e documentação de operação e homologação.

**Esse é o escopo-alvo, não uma declaração de que todos os itens já foram concluídos ou homologados.** A verificação final deve ser feita contra o código, testes, pendências e checklist de release da versão candidata. Não se deve confundir a existência de uma função interna ou de testes parciais com uma funcionalidade pública estável.

A evolução da documentação contempla um guia operacional, checklist de release, changelog e ajuda localizada em português do Brasil e inglês. Esses materiais devem ser vinculados aqui somente quando estiverem efetivamente versionados no repositório.

## Licença

Licenciado sob **Apache License 2.0**, conforme o manifesto do projeto. Consulte o arquivo de licença incluído na distribuição ou o [texto da licença](https://www.apache.org/licenses/LICENSE-2.0).

---

Repositório: [fabianosrc/PipeDFe](https://github.com/fabianosrc/PipeDFe)
