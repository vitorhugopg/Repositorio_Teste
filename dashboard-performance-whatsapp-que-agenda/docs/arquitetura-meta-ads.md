# Arquitetura da integração com Meta Ads

> Status: **proposta / preparação**. Nada neste documento está implementado — sem token, sem chamada real à Meta, sem tabela criada no Supabase. É o mapa para a próxima etapa, não a etapa em si.

## 1. Objetivo

Cruzar dados de mídia paga da Meta Ads com vendas reais registradas via Kiwify/Supabase, para o Dashboard de Performance responder: quais anúncios trazem vendas, quanto se gasta, quanto se fatura, qual o CPA e ROAS reais, e onde está o vazamento no funil.

## 2. Duas arquiteturas, uma só regra: o frontend nunca fala com fontes externas

```
Meta Marketing API → Supabase Edge Function (meta-ads-sync) → Supabase → Dashboard
```

```
Anúncio → Landing Page → attribution_id → Kiwify (s1) → webhook → Supabase → Dashboard
```

O dashboard **nunca** chama a Meta API nem a Kiwify diretamente. Ele só lê dados já normalizados no Supabase. Isso significa:

- Credenciais da Meta (token, ad account id) ficam **só** em secrets server-side (Supabase Edge Function), nunca no navegador.
- O dashboard não é mais lento nem mais frágil por causa de uma chamada externa lenta ou fora do ar — ele lê uma tabela local.
- A Meta é sincronizada **periodicamente** (frequência a definir), não a cada abertura do dashboard. Esta etapa **não implementa** esse agendamento — só prepara a estrutura para ele existir depois (cron job / Supabase scheduled function).

## 3. O que já está validado e o que ainda não está

**Já validado:** UTMs → Landing Page → Checkout Kiwify. A Landing Page já preserva UTMs e `fbclid`, cria um `attribution_id` e envia esse `attribution_id` para a Kiwify pelo parâmetro `s1`.

**Ainda NÃO validado:** Kiwify → webhook → Supabase retornando `s1`. Essa ponta só é confirmada com uma venda real passando pelo fluxo inteiro — é por isso que a página **Vendas** do dashboard trata "atribuição pendente de validação" como um estado de interface de primeira classe (ver `index.html`, seção "Preview de estados de interface" / dev-preview-block), e não como algo já resolvido.

## 4. Fonte da verdade

Duas fontes, cada uma dona de um pedaço dos dados — o dashboard nunca deve tentar tirar de uma fonte um número que só a outra pode responder com precisão.

**Meta Ads** é fonte da verdade para: gasto, impressões, alcance, cliques, CTR, CPC, CPM, estrutura de campanha, estrutura de conjunto, estrutura de anúncio.

**Supabase / Kiwify** é fonte da verdade para: venda, receita, status do pedido, reembolso, chargeback, `attribution_id`, UTMs vinculadas ao pedido.

Regra explícita: **o dashboard não usa o "Purchase" reportado pela Meta como fonte de vendas reais.** O campo `initiate_checkout` que vamos sincronizar da Meta (seção 6) é o pixel dela — útil como referência, mas nunca como substituto do checkout real do Kiwify, porque os dois tendem a divergir (atribuição, deduplicação, janela de conversão). O mock já modela essa divergência de propósito: cada registro diário tem um `initiate_checkout` da Meta e um `checkouts` do Kiwify, gerados a partir de números diferentes, para o cálculo nunca depender do campo errado.

## 5. Métricas que a Meta nunca vai nos dar prontas

Estas continuam sendo calculadas na nossa camada de dados, a partir de gasto (Meta) cruzado com vendas reais (Supabase/Kiwify) — nunca reportadas prontas por nenhuma das duas APIs:

| Métrica | Fórmula |
|---|---|
| CPA real | gasto Meta / vendas reais |
| ROAS real | receita real / gasto Meta |
| Custo por Checkout | gasto Meta / checkouts |
| Taxa LP → Checkout | checkouts / landing_page_views |
| Taxa Checkout → Venda | vendas / checkouts |

No código atual (`index.html`), isso já é assim por construção: `deriveMetrics()` sempre calcula essas razões a partir dos contadores brutos, nunca as recebe prontas — é o mesmo princípio que a tabela acima descreve, só que já implementado no mock.

## 6. Granularidade: 1 registro por dia + `ad_id`

```
2026-09-24, ad_id 120001  → um registro
2026-09-25, ad_id 120001  → outro registro
```

O dashboard soma os registros do intervalo do filtro de período (Hoje / Ontem / 7 dias / 30 dias / Personalizado) — não existe uma tabela "por período", existe uma tabela diária e uma soma em cima dela. É exatamente assim que o mock já funciona hoje (`metaDailyRaw` / `salesDailyRaw` em `index.html`, uma linha por dia e por `ad_id`).

## 7. Campos da Meta previstos para a V1

```
date, account_id,
campaign_id, campaign_name,
adset_id, adset_name,
ad_id, ad_name,
status,
spend, impressions, reach, clicks, ctr, cpc, cpm,
initiate_checkout
```

Nenhum campo além destes é necessário para a V1 — não faz sentido sincronizar dezenas de métricas que o dashboard ainda não usa.

## 8. Camada de dados no frontend

O `index.html` não lê mais os arrays mock diretamente nos componentes. Existe uma camada de funções que todo componente chama:

```js
getAdsPerformance(period)   // anúncios com métricas do período
getDashboardSummary(period) // agregado para os cards
getFunnelData(period)       // etapas do funil
getPerformanceAlerts(period)// alertas
getCampaigns(period)        // agrupado por campaign_id
getCreatives(period)        // base completa por anúncio
getSourceStatus()           // status das fontes (sidebar)
```

Todas são `async` e devolvem `Promise`, mesmo hoje sendo síncronas por baixo (leem os arrays mock). Isso é proposital: quando a sincronização real existir, só o **corpo** de cada função muda — para um `await supabase.from('marketing_daily_metrics').select(...)` — a assinatura e o formato de retorno continuam os mesmos, então nenhum componente (cards, tabela, funil, alertas, Campanhas, Criativos) precisa ser reescrito para receber dados reais.

## 9. Estrutura de anúncio (nunca hardcoded)

```js
{
  ad_id,          // chave primária — nunca ad_name
  ad_name,
  adset_id,
  adset_name,
  campaign_id,
  campaign_name,
  status,
}
```

No mock, isso vem de três arrays pequenos (`CAMPAIGNS`, `ADSETS`, `AD_CATALOG`) unidos por `adDimensions(ad_id)`. Testado adicionando uma campanha, um conjunto e um anúncio novos: as páginas Visão Geral, Campanhas e Criativos atualizaram sozinhas, sem qualquer alteração de componente.

## 10. Proposta de tabela: `marketing_daily_metrics`

```sql
-- PROPOSTA — não executada. Nenhuma migration foi criada nesta etapa.
create table marketing_daily_metrics (
  id uuid primary key default gen_random_uuid(),
  date date not null,
  account_id text not null,

  campaign_id text not null,
  campaign_name text not null,
  adset_id text not null,
  adset_name text not null,
  ad_id text not null,
  ad_name text not null,
  ad_status text not null,

  spend numeric(12,2) not null default 0,
  impressions integer not null default 0,
  reach integer not null default 0,
  clicks integer not null default 0,
  initiate_checkout integer not null default 0,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  unique (date, ad_id)
);
```

**Avaliação da estrutura sugerida no briefing e mudanças propostas:**

- **Removi `ctr`, `cpc`, `cpm` da tabela.** São derivadas de `spend`/`impressions`/`clicks` — guardá-las prontas cria risco de ficarem desatualizadas se um valor for corrigido num re-sync (upsert). A Edge Function faz upsert só dos brutos; quem calcula a razão é a mesma camada que já calcula CPA/ROAS/Custo-por-Checkout (seção 5) — um único lugar responsável por toda métrica derivada, no banco ou no frontend.
- **Adicionei `unique (date, ad_id)`.** É a chave natural do grão desta tabela (seção 6) e o alvo do `upsert` da Edge Function — sem ela, um re-sync duplicaria linhas em vez de atualizar.
- `campaign_name`/`adset_name`/`ad_name` ficam desnormalizados (repetidos em cada linha diária do mesmo anúncio). Aceitável para a V1 — evita joins extras nas consultas do dashboard; se o catálogo de campanhas crescer muito, dá para extrair depois numa tabela `meta_entities` separada, sem pressa agora.
- **Sugestão opcional, não obrigatória:** uma coluna `raw_payload jsonb` guardando a resposta original da Meta por linha, útil para depurar uma divergência sem precisar chamar a API de novo. Fica como ideia para quando a sincronização real for implementada, não faz parte desta proposta mínima.
- `updated_at` deve ser setado pela própria Edge Function a cada upsert (`updated_at: now()`), não por trigger — mantém a lógica de sincronização inteira num só lugar.

Com essas mudanças, a estrutura proposta no briefing é suficiente para a V1.

## 11. Edge Function `meta-ads-sync` (ainda não criada)

Responsabilidade, nesta ordem:

1. Ler credenciais da Meta através de secrets (nunca hardcoded).
2. Consultar a Meta Marketing API (Insights por `ad_id`, por dia).
3. Receber métricas por anúncio e por dia.
4. Normalizar o resultado para o formato de `marketing_daily_metrics`.
5. Fazer upsert em `marketing_daily_metrics` usando `(date, ad_id)` como chave de conflito.
6. Registrar erro de sincronização (para alimentar `error_message`/`last_sync_at` do status das fontes — ver seção 12).

Nada disso está implementado. Não há pasta `supabase/functions/` neste repositório ainda — ela só deve ser criada quando o projeto tiver um Supabase real conectado.

## 12. Status das fontes — pronto para receber dados reais

O componente na sidebar (`dataSourceStatus` em `index.html`) já usa os três campos que a sincronização real vai precisar preencher:

```js
{ name, status, note, last_sync_at, error_message }
```

Na V1 mock, `status` só assume `"mock"` (Meta Ads, Supabase) ou `"pending"` (Kiwify), e `last_sync_at`/`error_message` ficam `null`. As cores para `"synced"`/`"online"`/`"error"` já existem no CSS, só não são usadas ainda. Quando a sincronização real existir, essas linhas passam a vir de uma consulta ao Supabase, não de um array fixo.

## 13. Secrets futuros

Quando a Edge Function for implementada, ela vai precisar de:

```
META_ACCESS_TOKEN
META_AD_ACCOUNT_ID
META_API_VERSION
```

Nenhum valor — real ou fictício com aparência de real — foi criado neste momento. Regra permanente: essas credenciais **nunca** vão para o HTML, para o JS que roda no navegador, para um arquivo versionado no git, para querystring ou para o README. Elas vivem exclusivamente nos secrets do ambiente server-side da Edge Function (Supabase).

## 14. O que esta etapa explicitamente NÃO inclui

Token real da Meta · credenciais no frontend · chamadas reais à Meta API · escrita na Meta (pausar/criar/alterar campanha ou anúncio) · agendamento de sincronização · migration executada no Supabase · Google Ads · IA · automação de otimização.

A integração Meta, quando implementada, será **somente leitura**.
