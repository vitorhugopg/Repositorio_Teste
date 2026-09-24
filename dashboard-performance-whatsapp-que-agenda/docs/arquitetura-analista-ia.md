# Arquitetura do Analista IA

> Status: **proposta / preparação visual**. Nesta etapa o Analista IA é 100% local — regras JavaScript sobre os dados mock, sem nenhuma chamada a modelo de IA, sem token, sem provedor (OpenAI, Anthropic ou qualquer outro). Este documento descreve como a versão real será conectada, não implementa nada disso.

## 1. O que o Analista IA é (e o que nunca vai ser)

Função: **observar → diagnosticar → explicar → sugerir.**

Ele nunca **altera → pausa → aumenta orçamento → edita campanha** automaticamente. Essa fronteira é estrutural, não uma promessa de copy: o Analista IA não tem, e nunca terá nesta arquitetura, nenhum caminho de escrita até a Meta. Ver seção 4.

## 2. Arquitetura futura

```
Dashboard → função server-side → contexto estruturado da campanha → modelo de IA → resposta → Dashboard
```

O Dashboard nunca chama um modelo de IA diretamente do navegador (evita expor a chave da API de IA no frontend, e mantém o mesmo padrão já usado para a Meta — ver `docs/arquitetura-meta-ads.md`). Uma função server-side monta o contexto (seção 3), chama o modelo, e devolve só a resposta já formatada.

**A IA nunca recebe token da Meta diretamente.** Ela recebe apenas dados já normalizados do Supabase — os mesmos que os componentes do dashboard já consomem pela camada de dados (`getDashboardSummary`, `getAdsPerformance`, `getFunnelData`, `getPerformanceAlerts`). A função server-side lê do Supabase, monta o contexto, e só então chama o modelo — a Meta e a IA nunca se tocam diretamente em nenhum ponto do fluxo.

## 3. Contexto que a futura IA poderá receber

```text
período

gasto total
receita
vendas
CPA
ROAS

funil

campanhas
criativos

CTR
CPC
checkouts
vendas
CPA por anúncio
ROAS por anúncio

comparação com período anterior

CPA máximo configurado
ROAS de equilíbrio
```

**Nunca enviar informações pessoais de compradores para o modelo** — nome, e-mail, telefone, documento, endereço. O contexto é sempre agregado por período/campanha/anúncio, nunca por pedido individual. Isso é coerente com a separação de fontes já documentada em `docs/arquitetura-meta-ads.md`: o Analista IA trabalha com métricas, não com o histórico de compra de uma pessoa.

## 4. O que o Analista IA NÃO poderá fazer

- alterar campanhas
- pausar anúncios
- aumentar orçamento
- reduzir orçamento
- criar anúncios
- editar públicos
- alterar checkout
- executar qualquer ação na conta Meta

Ele somente:

- interpreta
- compara
- aponta anomalias
- sugere hipóteses
- recomenda próximos testes
- responde perguntas

Essa lista não é apenas uma diretriz de produto — é o motivo pelo qual esta etapa não implementa nenhuma credencial de escrita na Meta em lugar nenhum do projeto (ver `docs/arquitetura-meta-ads.md`, que já define a integração real como **somente leitura**). Não existe, nesta arquitetura, um caminho técnico para o Analista IA (real ou mock) executar uma ação sobre uma campanha.

## 5. Por que a linguagem das respostas importa

Tanto o mock atual quanto o modelo real, no futuro, devem evitar afirmações categóricas do tipo "aumente o orçamento" ou "seu ROAS está excelente". Sem uma meta de negócio configurada (CPA máximo, ROAS de equilíbrio — ainda não existem no produto), qualquer julgamento absoluto de ROAS é arbitrário. Por isso as respostas usam sempre linguagem de hipótese: "pode ser candidato a teste", "há indício de...", "vale acompanhar", "há sinal para avaliar". A decisão final é sempre de quem usa o dashboard, nunca do Analista.

## 6. O motor de regras mock (implementado nesta etapa)

Nenhum destes pontos chama IA — são condicionais em JavaScript (`generateDiagnostics` em `index.html`) sobre os dados que já vêm de `getAdsPerformance`/`getDashboardSummary`. Nenhuma regra é "definitiva"; todas seguem a linguagem de hipótese da seção 5.

| Regra | Condição | Resultado |
|---|---|---|
| D — dados insuficientes | `checkouts < 8` | nunca classifica o criativo como bom/ruim; só sinaliza volume baixo |
| A/B — gargalo checkout→venda | `sales === 0` (com volume mínimo já garantido pela regra D) | "atenção": leva ao checkout, mas não converte |
| E — fadiga de CTR | CTR atual < CTR do período anterior, queda > 10% | "atenção": possível fadiga de criativo |
| C — oportunidade | CPA do anúncio < CPA médio da campanha, com `sales >= 2` | "oportunidade": candidato a teste de escala |

A regra D é checada **antes** de qualquer outra — é a garantia de que um anúncio novo/com pouco volume nunca é rotulado como ruim só por falta de dados. Os limiares (`MIN_CHECKOUTS_FOR_CONFIDENCE`, `RELEVANT_SPEND_THRESHOLD`, `CTR_DROP_THRESHOLD`, `BENCHMARK_CHECKOUT_RATE`) são os mesmos já usados pelos badges de saúde da tabela de criativos e pelos Alertas de Performance da Visão Geral — um único critério de "o que é confiável" e "o que é relevante" em todo o dashboard, não um critério novo só para o Analista IA.

## 7. "Pergunte ao seu Analista" — hoje vs. futuro

Hoje: um conjunto fixo de padrões de texto (`QA_HANDLERS` em `index.html`) reconhece palavras-chave na pergunta (ex.: "cpa" + "melhor", "fadiga", "gargalo") e monta uma resposta a partir dos mesmos dados usados nos diagnósticos — nunca a partir de um array de respostas prontas por pergunta. Perguntas fora desse conjunto recebem uma resposta padrão explicando o que o Analista já sabe responder nesta versão.

Futuro: a mesma pergunta em texto livre vai para a função server-side (seção 2), que monta o contexto estruturado (seção 3) e chama o modelo de IA. A interface (campo de texto, botão "Analisar", chips de perguntas sugeridas, painel de resposta) já está pronta para receber esse fluxo sem mudança visual — só a origem da resposta muda, de regra local para modelo real.
