# Dashboard de Performance — WhatsApp que Agenda

Dashboard de acompanhamento de mídia paga (Meta Ads) e vendas do produto **WhatsApp que Agenda**, da **Clínica que Converte**.

## Status: V1 visual — dados mock

Esta é a primeira versão navegável do dashboard, com **dados fictícios**. O objetivo é validar layout, hierarquia de informação, navegação e experiência de uso antes de conectar as fontes reais.

**Ainda não integrado nesta etapa:**
- Meta Ads API (Marketing API)
- Supabase
- Kiwify (webhook de vendas)
- Autenticação/login

## Como abrir

Abra `index.html` diretamente no navegador. Projeto single-file (HTML + CSS + JS), sem backend, sem build, sem dependências externas — só as fontes Fraunces/Manrope do Google Fonts.

## Estrutura de dados

Todos os anúncios ficam em um único array (`adsBase`), cada um identificado por `ad_id`. Todas as métricas derivadas (CTR, CPC, CPA, ROAS, custo por checkout, taxas do funil) são **calculadas em tempo real** a partir dos contadores brutos (impressões, cliques, LP views, checkouts, vendas, gasto, receita) — nunca armazenadas prontas. Isso garante que:

- os números sempre fecham matematicamente (`CPA = gasto / vendas`, `ROAS = receita / gasto`, etc.);
- adicionar, remover ou editar um anúncio no array atualiza cards, tabela, funil e alertas automaticamente, sem tocar em nenhum componente da interface;
- a lista de criativos não tem limite de itens — funciona igual com 3, 8 ou 20 anúncios.

O filtro de período (Hoje / Ontem / 7 dias / 30 dias / Personalizado) reescala esses contadores brutos de forma determinística (mesma entrada sempre gera a mesma saída).

## Preparado para o futuro, mas não implementado ainda

O layout já reserva espaço/estrutura para:
- status das fontes de dados (Meta Ads, Supabase, Kiwify);
- estados de interface (carregando, sem dados, erro, sem atribuição, atribuição pendente — ver página **Vendas**);
- os campos de atribuição que virão do fluxo `Landing Page → attribution_id → Kiwify (s1) → webhook → Supabase`: `attribution_id`, `utm_source`, `utm_medium`, `utm_campaign`, `utm_content`, `ad_id`, `campaign_id`, `order_id`.

Nenhuma dessas integrações está implementada — são apenas placeholders visuais para a próxima etapa.
