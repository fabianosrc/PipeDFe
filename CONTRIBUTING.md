# Contribuindo com o PipeDFe

Obrigado por contribuir com o PipeDFe!

Este documento descreve as diretrizes para desenvolvimento, submissão de alterações e colaboração no projeto.

## Código de Conduta

Este projeto segue o [Contributor Covenant Code of Conduct](https://www.contributor-covenant.org/).

Esperamos que todos os participantes mantenham um ambiente respeitoso, colaborativo e construtivo em todas as interações.

## Como Contribuir

### Reportar bugs, sugerir funcionalidades ou tirar dúvidas

Abra uma issue utilizando o template adequado:

* **Bug Report** — para relatar problemas encontrados
* **Feature Request** — para sugerir novas funcionalidades
* **Question** — para dúvidas ou discussões

Forneça o máximo de informações possíveis para facilitar a análise e reprodução do problema.

### Enviar código

Antes de enviar alterações:

1. Faça um fork do repositório
2. Clone seu fork localmente
3. Mantenha seu fork atualizado com a branch `main`
4. Crie uma branch a partir de `main` seguindo o padrão:

```
feat/nome-da-feature
fix/nome-do-bug
docs/nome-da-documentacao
test/nome-do-teste
refactor/nome-da-alteracao
chore/nome-da-tarefa
```

5. Desenvolva a alteração seguindo as convenções do projeto
6. Adicione ou atualize testes quando aplicável
7. Garanta que os testes existentes continuam passando
8. Abra um Pull Request direcionado para a branch `main`

## Convenções

## Commits

Seguimos o padrão [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/).

Os commits devem ser escritos em inglês e utilizar mensagens claras e objetivas.

Exemplos:

```
feat: add NFCe support
fix: correct CNPJ validation
docs: update README examples
test: add tests for Invoke-PipeDFe
refactor: simplify period parser
chore: update dependencies
```

Evite mensagens genéricas:

```
update code
fix bug
changes
alterações
```

## Código

O código deve seguir estas diretrizes:

* Compatível com **PowerShell 5.1+**
* Seguir as diretrizes oficiais da Microsoft para desenvolvimento PowerShell
* Utilizar somente verbos aprovados pelo PowerShell (`Get-Verb`)
* Funções privadas devem permanecer em `Private/`
* Funções públicas devem permanecer em `Public/`
* Manter separação clara entre código público, interno e infraestrutura
* Termos do domínio fiscal brasileiro devem permanecer em português
* Demais termos técnicos devem utilizar inglês
* Workarounds devem ser documentados explicando o motivo técnico e a limitação envolvida

Exemplos de termos fiscais que devem permanecer em português:

```
NFe
CTe
MDFe
NFCom
Cancelamento
CartaCorrecao
Inutilizacao
Producao
Homologacao
```

## Compatibilidade

Alterações devem manter compatibilidade com:

* Windows PowerShell 5.1
* PowerShell 7+

Caso uma alteração exija comportamento diferente entre versões do PowerShell, a diferença deve ser documentada.

## Testes

O projeto utiliza:

* **Framework:** Pester 5.x
* **Fixtures XML:** `tests/Fixtures/xml/`

Diretrizes:

* Novas funcionalidades devem incluir testes quando aplicável
* Correções de bugs devem incluir testes que reproduzam o problema
* Alterações críticas devem manter ou aumentar a cobertura existente
* A cobertura esperada do projeto é de no mínimo **80%**

Pull Requests sem testes poderão ser rejeitados quando a alteração exigir cobertura automatizada.

## Pull Requests

Antes de abrir um Pull Request:

* Execute todos os testes localmente
* Verifique se não existem erros de análise ou carregamento do módulo
* Atualize a documentação quando necessário
* Descreva claramente o problema resolvido ou a funcionalidade adicionada
* Informe possíveis impactos ou mudanças de comportamento
* Mantenha o Pull Request focado em uma única alteração

Pull Requests grandes ou contendo múltiplas funcionalidades independentes podem ser solicitados para divisão.

## Revisão de Código

Todas as alterações passam por revisão antes da integração.

A revisão considera:

* Qualidade e legibilidade do código
* Compatibilidade com versões suportadas
* Cobertura de testes
* Impacto em compatibilidade futura
* Consistência com a arquitetura existente

## Idioma

O projeto utiliza os seguintes padrões:

* **Issues, Pull Requests e discussões:** português do Brasil
* **Código e comentários:** inglês
* **Termos oficiais do domínio fiscal brasileiro:** português do Brasil

Essa separação tem como objetivo manter o projeto acessível para a comunidade brasileira e, ao mesmo tempo, seguir padrões internacionais de desenvolvimento.
