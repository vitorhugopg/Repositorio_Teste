# Dashboard de Performance — WhatsApp que Agenda

Dashboard de acompanhamento de mídia paga (Meta Ads) e vendas do produto **WhatsApp que Agenda**, da **Clínica que Converte**.

## Status: V1 homologada, arquitetura de integração em preparação

A estrutura visual (Visão Geral, Campanhas, Criativos, Funil, Vendas) já foi homologada e roda com **dados fictícios**. Agora o projeto está preparando a arquitetura para receber dados reais da Meta Ads — ver `docs/arquitetura-meta-ads.md` para o plano completo.

**Ainda não integrado:**
- Meta Ads API (Marketing API) — nenhum token, nenhuma chamada real
- Supabase
- Kiwify (webhook de vendas)
- Autenticação/login
- Agendamento de sincronização

## Como abrir

Abra `index.html` diretamente no navegador. Projeto single-file (HTML + CSS + JS), sem backend, sem build, sem dependências externas — só as fontes Fraunces/Manrope do Google Fonts.

## Arquitetura de dados

**Catálogo de entidades** (`CAMPAIGNS`, `ADSETS`, `AD_CATALOG`): cada anúncio pertence a um conjunto, que pertence a uma campanha, unidos por `adDimensions(ad_id)`. `ad_id` é sempre a chave primária — nunca `ad_name`. Adicionar uma campanha, um conjunto ou um anúncio nesses arrays é suficiente para ele aparecer em Visão Geral, Campanhas e Criativos, sem tocar em nenhum componente.

**Granularidade diária**: os dados brutos (`metaDailyRaw`, `salesDailyRaw`) são um registro por dia + `ad_id` — a mesma granularidade prevista para a tabela `marketing_daily_metrics` no Supabase (ver `docs/arquitetura-meta-ads.md`). Os filtros de período (Hoje / Ontem / 7 dias / 30 dias / Personalizado) somam os registros do intervalo de datas correspondente; não existe uma cópia dos dados "por período".

**Duas fontes, nunca misturadas na origem**: `metaDailyRaw` só tem o que a Meta reportaria (gasto, impressões, alcance, cliques, `initiate_checkout` — o pixel dela); `salesDailyRaw` só tem o que vem da Landing Page + Kiwify/Supabase (LP views, checkouts reais, vendas, receita). Todas as métricas derivadas (CTR, CPC, CPA, ROAS, custo por checkout, taxas do funil) são **calculadas em tempo real** a partir desses contadores brutos — nunca armazenadas prontas, e nunca a partir do `initiate_checkout` da Meta (ver "fonte da verdade" no doc de arquitetura).

**Camada de dados**: nenhum componente lê os arrays mock diretamente. Todos chamam funções assíncronas (`getAdsPerformance`, `getDashboardSummary`, `getFunnelData`, `getPerformanceAlerts`, `getCampaigns`, `getCreatives`, `getSourceStatus`) que hoje leem os mocks e, quando a sincronização real existir, só têm o corpo trocado por uma consulta ao Supabase — sem reescrever nenhum componente.

## Preparado para o futuro, mas não implementado ainda

- Sincronização real com a Meta Ads API — plano completo em `docs/arquitetura-meta-ads.md` (Edge Function `meta-ads-sync`, proposta de schema `marketing_daily_metrics`, secrets necessários).
- Status das fontes de dados (Meta Ads, Supabase, Kiwify) já preparado para os campos `status`, `last_sync_at`, `error_message`.
- Estados de interface (carregando, sem dados, erro, sem atribuição, atribuição pendente) — ver página **Vendas**, bloco "Modo de desenvolvimento — preview técnico" (só para QA visual, não aparece na versão final).
- Campos de atribuição do fluxo `Landing Page → attribution_id → Kiwify (s1) → webhook → Supabase`: `attribution_id`, `utm_source`, `utm_medium`, `utm_campaign`, `utm_content`, `ad_id`, `campaign_id`, `order_id`.

Nenhuma dessas integrações está implementada — são estrutura e documentação para a próxima etapa.
