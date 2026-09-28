# Auditoria técnica — Meta Ads real (uso pessoal, sem multiempresa)

> Status: **auditoria e plano, nada implementado.** Nenhuma migration foi executada, nenhuma Edge Function foi criada, nenhuma credencial foi solicitada ou escrita em código, `index.html` não foi alterado, nenhuma chamada real foi feita à Meta. Este documento complementa `docs/arquitetura-meta-ads.md` (que continua valendo como referência conceitual — mas ver a nota no fim da seção 9 sobre um ponto que ele afirma e que esta auditoria não conseguiu confirmar tecnicamente).
>
> **Revisão 2** — depois da sua leitura da primeira versão, corrigi 6 pontos: tratamento de `reach`/`frequency`, segurança do Supabase (Auth em vez de leitura pública), investigação real de LP Views, investigação real da cadeia de atribuição, janela de ressincronização, e uma tabela de fonte da verdade.
>
> **Revisão 3** — fechamento técnico da arquitetura de atribuição, na nova seção **"9A. Fechamento técnico da atribuição"**: como o `ad_id` chega à Landing Page (parâmetros dinâmicos da Meta, confirmados agora), a regra exata de criação/expiração do `attribution_id`, a diferença entre `page_view`/`visit`/`attributed_visit` e qual alimenta LP Views, o schema completo de `landing_page_visits` coluna a coluna, a arquitetura de segurança para escrita pública (visitante não-autenticado), um exemplo fictício completo ponta a ponta, o comportamento da V1 em 9 casos especiais, o schema conceitual final das 3 tabelas com seus relacionamentos, e a tabela de fonte da verdade reapresentada.
>
> **Revisão 4** — fecha a fonte da verdade de Checkout, na nova seção **"9B. Checkout — investigação e fonte da verdade"**: investigação do checkout atual (sem código de Landing Page disponível neste repositório — registrado como pendência explícita), os 10 eventos de webhook reais da Kiwify (pesquisados agora — nenhum deles é "abriu o checkout"), a tabela própria `checkout_events` para suprir essa lacuna, a definição formal de Impressão/Clique/LP View/Checkout/Venda, o registro explícito de que a janela de 7 dias é nossa e não da Meta, a confirmação formal do modelo *last paid click attribution*, o schema final das 4 tabelas, o funil completo com a fonte da verdade ao lado de cada etapa, e a declaração **ARQUITETURA V1 PRONTA PARA IMPLEMENTAÇÃO** com as limitações aceitas. Nada foi implementado nesta revisão — só documentação.

## Escopo confirmado

Uso pessoal, uma única conta de anúncios, sem multiempresa, `workspace_id`, SaaS, cobrança, gestão de usuários (além de você) ou múltiplas contas Meta. A Meta é fonte da verdade para investimento/alcance/impressões/cliques/CTR/CPC/CPM/estrutura — nunca para vendas. O Analista IA não muda: continua lendo só a camada de dados do dashboard.

---

## 1. Estado atual — o que já existe e será reaproveitado

- **Camada de dados assíncrona** (`getAdsPerformance`, `getDashboardSummary`, `getFunnelData`, `getPerformanceAlerts`, `getCampaigns`, `getCreatives`, `getSourceStatus` em `index.html`) — ponto de costura onde o `DATA_SOURCE` vai decidir entre mock e Supabase (seção 13).
- **Catálogo de entidades** (`CAMPAIGNS`, `ADSETS`, `AD_CATALOG` unidos por `adDimensions(ad_id)`) — mesma hierarquia campanha → conjunto → anúncio que a Meta retorna. `ad_id` já é a chave primária em todo o dashboard, nunca `ad_name`.
- **Granularidade diária já modelada** (`metaDailyRaw` / `salesDailyRaw`, 1 registro por dia + `ad_id`).
- **`deriveMetrics()`** nunca guarda CTR/CPC/CPM/CPA/ROAS prontos — sempre calcula a partir dos brutos somados do período (nunca média de taxas diárias). Isso já é exatamente o princípio correto que a seção 3 formaliza para o banco.
- **Status das Fontes** já tem os campos `status`, `last_sync_at`, `error_message` prontos.
- **Investiguei agora, no código atual, e confirmei duas lacunas reais** (detalhes nas seções 8 e 9): `landing_page_views` hoje é só um número de mock, sem nenhuma fonte real; e `attribution_id`/UTMs/`order_id` aparecem só como uma lista de texto decorativa (`FUTURE_FIELDS`) na página Vendas — não existe, em lugar nenhum do projeto, uma tabela que realmente ligue essas informações.
- **Analista IA** já consome só a camada de dados — nenhuma mudança necessária nele.

## 2. Arquitetura geral (visão rápida — detalhada na seção 15)

Duas cadeias que se encontram só na camada de dados do dashboard, nunca antes:

```
Meta Ads → Edge Function → Supabase (dados de mídia) ─┐
                                                        ├─→ Camada de dados → Dashboard → Analista IA
Anúncio → Landing Page → Kiwify → webhook → Supabase (vendas) ─┘
```

O navegador nunca chama a Meta nem a Kiwify. Só Edge Functions falam com elas. Nesta revisão, o navegador também passa a precisar de **login** antes de ler qualquer dado (seção 7) — diferença em relação à primeira versão desta auditoria, que propunha leitura pública.

---

## 3. Quais métricas podem ser somadas entre dias — e quais não

Isso não estava certo na primeira versão desta auditoria, que tratava `reach` como se fosse só mais uma coluna somável. Correção:

| Tipo de métrica | Pode somar linhas diárias? | Por quê |
|---|---|---|
| **Gasto, Impressões, Cliques** | ✅ Sim | Cada evento é uma unidade nova — um clique de hoje não "é o mesmo" clique de ontem. Aditivo por natureza. |
| **LP Views, Checkouts, Vendas** (quando existirem de verdade — seções 8/9) | ✅ Sim | Mesma lógica: cada visita/checkout/venda é um evento discreto. |
| **Alcance (`reach`)** | ❌ Não | `reach` é a contagem de **pessoas únicas** que viram o anúncio numa janela específica. Se a mesma pessoa vê o anúncio na segunda e na terça, ela entra no `reach` dos dois dias — somar os dois dias conta essa pessoa duas vezes. A soma de `reach` diário **superestima** o alcance real do período. |
| **Frequência (`frequency`)** | ❌ Não, a partir das linhas diárias | `frequency = impressões ÷ alcance`. Como o alcance do período não é a soma dos alcances diários, a frequência do período também não pode vir de impressões-somadas ÷ alcance-somado (isso **subestimaria** a frequência real, porque o denominador estaria inflado). |
| **CTR, CPC, CPM** | — (não se "somam", se **recalculam**) | Sempre `soma do numerador do período ÷ soma do denominador do período` (ex.: CTR = cliques do período ÷ impressões do período). **Nunca** média das taxas diárias — isso já é como `deriveMetrics()` funciona hoje no código, e continua correto. |

**O que isso muda na prática:**
- A tabela diária (`marketing_daily_metrics`) vai guardar `reach` e `frequency` **como a Meta reportou para aquele dia específico** — válido e correto para consulta de 1 dia isolado.
- **Não vou propor** um card de "Alcance do período" ou "Frequência do período" somando essas linhas — seria um número tecnicamente errado (o de alcance, inflado; o de frequência, subestimado). Se um dia você quiser esse número certo para um período (ex. "alcance dos últimos 30 dias"), a única forma correta é uma consulta separada à Meta pedindo o intervalo inteiro **sem** `time_increment=1` — uma chamada adicional, fora da sincronização diária. Não é preciso decidir isso agora; só estou deixando registrado por que a arquitetura não tenta "resolver" isso somando linhas, porque não dá.
- Vou pedir o campo `frequency` diretamente da Meta (ela permite, como você apontou) para a linha de cada dia, em vez de recalcular localmente — assim o valor diário bate exatamente com o que a própria Meta calculou para aquele dia.

## 4. Schema — `marketing_daily_metrics` (revisado)

```sql
-- PROPOSTA REVISADA — ainda não executada.
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
  reach integer not null default 0,        -- válido só para ESTE dia, ver seção 3
  frequency numeric(6,3),                   -- pedido direto da Meta para este dia, ver seção 3
  clicks integer not null default 0,
  landing_page_view integer not null default 0,   -- referência da Meta, ver seção 8
  initiate_checkout integer not null default 0,    -- referência da Meta, nunca fonte de verdade

  attribution_setting text,                 -- qual janela de atribuição gerou esta linha
  raw_actions jsonb,                        -- resposta bruta de `actions`, ver seção 12

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  unique (date, ad_id)
);

create index idx_marketing_daily_metrics_campaign on marketing_daily_metrics (campaign_id, date);
create index idx_marketing_daily_metrics_adset on marketing_daily_metrics (adset_id, date);
```

Único ajuste em relação à versão anterior: adicionei a coluna `frequency` (pedida direto da Meta por dia) e deixei explícito, no comentário, que `reach`/`frequency` só valem isoladamente por dia — não para somar. Chave primária (`id`), chave natural (`unique(date, ad_id)`) e índices continuam como antes.

## 5. Meta Marketing API — o que será consultado

**Estrutura** (uma vez, ou quando mudar): `campaigns`, `adsets`, `ads` — `fields=id,name,status,...` (campaign_id/adset_id incluídos onde aplicável).

**Performance diária:**
```
GET /act_{AD_ACCOUNT_ID}/insights?level=ad&time_increment=1
  &time_range={"since":"...","until":"..."}
  &fields=campaign_id,campaign_name,adset_id,adset_name,ad_id,ad_name,
          spend,impressions,reach,frequency,clicks,ctr,cpc,cpm,actions
```
`level=ad` + `time_increment=1` já entrega "1 linha por dia + `ad_id`" nativamente. `actions` traz os eventos de conversão (LP View, Initiate Checkout) — nomes exatos ainda por confirmar (seção 12).

**Janela de atribuição:** não usar `7d_view`/`28d_view` (removidas pela Meta em jan/2026) — usar o padrão atual (`1d_view`,`7d_click`) ou omitir o parâmetro. Guardado em `attribution_setting` por linha.

**Versão da API:** confirmar a vigente em developers.facebook.com/docs/graph-api/changelog no momento da implementação (referências encontradas citam `v26.x`) — sempre fixar explicitamente na URL.

## 6. Credenciais necessárias

| O que | Onde encontrar | Onde armazenar |
|---|---|---|
| `META_ACCESS_TOKEN` | System User (Business Settings → Usuários do sistema), permissão `ads_read` apenas | Secret da Edge Function |
| `META_AD_ACCOUNT_ID` | Ads Manager, formato `act_XXXXXXXXXX` | Secret da Edge Function |
| `META_API_VERSION` | Confirmar no changelog da Meta no momento da implementação | Secret da Edge Function |
| App ID / App Secret (se exigido pelo tipo de token) | Meta for Developers → seu App → Configurações Básicas | Secret da Edge Function |
| `SUPABASE_SERVICE_ROLE_KEY` | Automático em todo projeto Supabase | Secret da Edge Function |

Nada disso foi solicitado, gerado ou escrito em nenhum arquivo nesta etapa.

## 7. Segurança — revisão: Supabase Auth em vez de leitura pública

**Correção em relação à versão anterior:** eu tinha proposto RLS de leitura pública (qualquer um com a chave anon lê a tabela). Você pediu para fechar isso. Arquitetura revisada:

```
Dashboard → Supabase Auth (login) → sessão autenticada → RLS → leitura liberada
```

- **Login:** um usuário só (você), criado manualmente no painel do Supabase (Authentication → Users → Add user), e-mail + senha. O `index.html` ganha uma tela de login simples antes de mostrar qualquer página — usando o cliente JS do Supabase (`supabase.auth.signInWithPassword(...)`). Isso não é multiempresa nem gestão de usuários: é controle de acesso para 1 pessoa, compatível com "uso pessoal".
- **RLS revisado:** a política de `select` em `marketing_daily_metrics` (e na futura tabela de vendas) passa a exigir `auth.uid() is not null` — só libera leitura para quem está autenticado. `insert`/`update`/`delete` continuam restritos à service role (só a Edge Function escreve), como já estava.
- **Chave `anon`/publicável:** continua podendo (precisa) existir no `index.html` — ela é o que permite o cliente JS do Supabase existir e o login funcionar. Ela sozinha, sem uma sessão autenticada, não lê nada nas tabelas de dados — é justamente isso que o RLS revisado garante.
- **Token da Meta, App Secret, service role key:** nada muda aqui — continuam só nos secrets da Edge Function, nunca no frontend.
- **Permissão do token Meta:** continua só `ads_read`.

Isso adiciona uma peça nova ao plano que a primeira versão não tinha: uma tela de login no dashboard. É pequena (um formulário de e-mail/senha), mas é uma mudança real de comportamento — hoje o dashboard abre direto, sem tela nenhuma antes.

## 8. LP Views — o que existe hoje (investigado, não suposto)

Você pediu para eu confirmar isso no código, não assumir. Fui ao `index.html` e busquei por `attribution_id`, `landing_page_view`, tabelas de sessão/visita — respostas diretas:

- **Existe algum registro de cada acesso à Landing Page no Supabase?** Não. Não há Supabase conectado a este projeto (nenhum arquivo de configuração, nenhum client, nada) — logo, não há onde esse registro estaria.
- **Existe tabela de sessões/visitas?** Não existe em lugar nenhum do repositório.
- **Existe evento próprio `landing_page_view`?** Não, nem como conceito implementado. O que existe é um **campo mock** chamado `landing_page_views` dentro de `salesDailyRaw` (`index.html`), preenchido por uma fórmula de distribuição (`splitByWeights`/`seededVariance`) — é um número fictício para a V1 visual, não um dado real.
- **O número de LP Views hoje vem só do mock?** Sim, 100%.
- **A Kiwify realmente nos dá LP View, ou estamos misturando conceitos?** Você está certo em desconfiar: **não**, a Kiwify não pode nos dar LP View. A Kiwify só entra em cena quando o visitante já chegou no checkout dela — ela não tem como saber que alguém visitou a Landing Page antes disso. "LP View" só pode vir de (a) a própria Landing Page registrando a visita, ou (b) o pixel da Meta (que já é só referência, nunca fonte de verdade — seção 3 do `arquitetura-meta-ads.md`). A documentação anterior estava imprecisa ao listar LP Views como algo que "viria da Kiwify/Supabase" sem detalhar que a origem real teria que ser a própria Landing Page.

**Proposta de arquitetura para LP View real** (não implementar agora) — ver seção 9, porque a mesma estrutura resolve LP View e atribuição juntas.

## 9. Cadeia de atribuição `attribution_id → ad_id` — o que existe hoje (investigado)

- **Onde essa relação é armazenada hoje?** Em lugar nenhum. `FUTURE_FIELDS` no `index.html` (linha ~1421) é uma lista de 8 strings (`attribution_id`, `utm_source`, `utm_medium`, `utm_campaign`, `utm_content`, `ad_id`, `campaign_id`, `order_id`) mostrada como cartõezinhos na página Vendas, só para indicar visualmente "é isso que vamos receber um dia". Não é uma tabela, não relaciona nada com nada, não guarda nenhum valor real.
- **Ela realmente existe?** Não.
- **O `attribution_id` sozinho permite descobrir qual anúncio originou a venda?** Hoje, não — mesmo que a Landing Page já crie esse ID (isso está descrito em `docs/arquitetura-meta-ads.md`, mas é uma afirmação sobre um projeto separado, fora deste repositório; a partir daqui eu não tenho como inspecionar o código da Landing Page para confirmar por mim mesmo — só posso confirmar o que existe *neste* repositório, que é o Dashboard). Sem um registro que ligue `attribution_id` a `ad_id`/UTMs no momento em que ele é criado, receber o `attribution_id` de volta pela Kiwify não ajuda em nada — é um ID solto.
- **O que acontece quando a Kiwify devolver o `attribution_id` pelo webhook (hoje):** nada automático — não há onde procurar esse ID para descobrir o anúncio. É exatamente por isso que a página Vendas já trata "sem atribuição" como um estado de interface esperado, não excepcional.
- **Como chegaremos do `order_id` até o `ad_id`:** só é possível com uma tabela intermediária, criada no momento da visita à Landing Page — proposta abaixo.

**Proposta de estrutura** (não implementar agora — resolve LP View e atribuição com a mesma tabela, porque os dois nascem no mesmo evento: a visita):

```sql
-- PROPOSTA — não executada.
create table landing_page_visits (
  id uuid primary key default gen_random_uuid(),
  attribution_id text not null unique,
  visited_at timestamptz not null default now(),

  utm_source text,
  utm_medium text,
  utm_campaign text,
  utm_content text,
  fbclid text,

  campaign_id text,
  adset_id text,
  ad_id text,

  created_at timestamptz not null default now()
);

create index idx_landing_page_visits_attribution on landing_page_visits (attribution_id);
```

**Fluxo completo, do zero até a venda vinculada:**

1. A Landing Page (projeto separado) recebe a visita com UTMs/`fbclid` na URL (e, idealmente, `ad_id`/`campaign_id`/`adset_id` também, se o link do anúncio for configurado para carregar esses parâmetros — nem sempre é o padrão).
2. Ela gera o `attribution_id` e grava uma linha em `landing_page_visits` — isso conta como **LP View real** (uma linha = uma visita) e, ao mesmo tempo, guarda a atribuição.
3. Se `ad_id` não vier direto na URL, dá pra tentar deduzir cruzando `utm_campaign`/`utm_content` com o catálogo de campanhas já sincronizado da Meta — um plano B, menos confiável que receber o `ad_id` direto.
4. A Landing Page redireciona pro checkout da Kiwify, levando o `attribution_id` no parâmetro `s1`.
5. Kiwify processa o pedido, dispara o webhook pro Supabase com `order_id`, valor, status, e `s1`.
6. Uma Edge Function recebe o webhook, procura o `attribution_id` (via `s1`) em `landing_page_visits`.
7. Achou → grava a venda já vinculada a `ad_id`/`campaign_id`/`adset_id`. Não achou → grava como "sem atribuição" (estado que a página Vendas já sabe mostrar).

**Dependência importante a registrar:** essa tabela só existe se a Landing Page (fora deste repositório) for alterada para gravar nela. Isso é trabalho num projeto que não tenho acesso a partir desta sessão — preciso que você confirme se e como posso acessar esse código quando chegarmos nessa etapa, ou se essa parte será feita por você/outra pessoa.

## 9A. Fechamento técnico da atribuição

Esta seção responde, uma a uma, às 9 perguntas que você trouxe antes de aprovarmos o schema definitivo. Nada aqui foi implementado.

### 9A.1 — Como o `ad_id` chega à Landing Page

**Não é automático — pesquisei agora e confirmei que a Meta exige configuração manual, anúncio por anúncio.** A Meta tem um recurso chamado **"Parâmetros de URL"** (URL Parameters), com tokens dinâmicos entre chaves duplas — `{{campaign.id}}`, `{{adset.id}}`, `{{ad.id}}`, `{{campaign.name}}`, `{{ad.name}}` — que ela substitui pelo valor real no momento do clique. Pontos confirmados:

- **Fica só no nível do anúncio** (não existe um "padrão de conta" que se aplique sozinho a todos os anúncios) — cada anúncio (ou um lote de anúncios, via edição em massa no Ads Manager) precisa ter esse campo preenchido.
- **Não deve ir no campo "URL do site"** (que deve ficar só com o link limpo da Landing Page) — os parâmetros ficam num campo separado, "Parâmetros de URL", que a Meta concatena na URL de destino automaticamente.
- **`fbclid` é adicionado sozinho pela própria Meta** — não deve ser incluído manualmente no template; fazer isso quebra o cookie `_fbc` e a deduplicação entre Pixel e Conversions API.
- Os IDs numéricos (`{{campaign.id}}`, `{{adset.id}}`, `{{ad.id}}`) são estáveis para sempre — sobrevivem a troca de nome, reestruturação, e até arquivamento do anúncio. São, portanto, a base mais confiável para `campaign_id`/`adset_id`/`ad_id` (mais confiável que tentar deduzir pelo nome da campanha via UTM).

**Modelo de "Parâmetros de URL" recomendado**, a ser configurado depois, quando formos ligar isso de verdade (não implementar agora):

```
utm_source=meta&utm_medium=paid&utm_campaign={{campaign.name}}&utm_content={{ad.name}}&campaign_id={{campaign.id}}&adset_id={{adset.id}}&ad_id={{ad.id}}
```

A Landing Page recebe isso como query string normal (`?utm_source=meta&...&ad_id=120001`) e só precisa ler os parâmetros da URL no carregamento — não tem nada exótico do lado da Landing Page, a complexidade toda está em garantir que a Meta está configurada certo.

**Limitação que isso implica (ver também 9A.7):** se um anúncio não tiver esse campo preenchido, ele não vai mandar `ad_id`/UTMs pra Landing Page — a venda que vier dele cai em "sem atribuição", mesmo sendo tráfego pago de verdade. Ou seja, checklist operacional futuro: toda vez que criar um anúncio novo, configurar os Parâmetros de URL — isso não é automático nem tem como forçar por código nosso, é uma configuração humana na Meta.

### 9A.2 — Quando o `attribution_id` é criado (e quando é substituído)

**Onde fica guardado:** `localStorage` do navegador (não `sessionStorage` — `sessionStorage` morre ao fechar a aba, e você pediu explicitamente que "fecha e volta depois" seja tratado, então precisa sobreviver ao fechamento do navegador).

**Regra proposta — "último clique em anúncio vence, com janela de continuidade":**

1. A Landing Page carrega e olha o `localStorage`.
2. **Se a URL de chegada tem `ad_id` (ou pelo menos UTMs) válidos** → sempre cria um `attribution_id` **novo**, mesmo que já exista um guardado, e substitui o anterior. Motivo: um novo clique num anúncio é o sinal mais forte disponível de "o que trouxe essa pessoa agora" — inclusive quando ela clica num anúncio diferente do da primeira vez (ver 9A.7, caso "clica no A1 e depois no A2").
3. **Se a URL de chegada NÃO tem nenhum parâmetro de anúncio/UTM** (refresh, navegação interna, ou voltou por um link direto/favorito) → reaproveita o `attribution_id` já guardado, **se ainda estiver dentro da janela de validade** (recomendo **7 dias**, espelhando a janela de clique padrão que a própria Meta usa hoje — mantém tudo consistente com o resto do projeto). Isso é o que garante "refresh mantém o mesmo `attribution_id`" e "ida pra Kiwify mantém o mesmo `attribution_id`".
4. **Se o `attribution_id` guardado expirou** (mais velho que 7 dias) **e a visita não tem parâmetro de anúncio** → cria um `attribution_id` novo mesmo sem sinal de anúncio (visita direta/orgânica — ver 9A.7).

**Por que não "primeiro clique sempre vence" (first-click)?** Consideraria, mas decidi recomendar o oposto pelo seguinte motivo prático: se alguém clica no anúncio A1, não compra, volta dias depois clicando no A2, e aí compra — dar o crédito ao A1 (primeiro clique) esconderia que foi o A2 que efetivamente converteu. Para decisão de qual criativo escalar, o último clique tende a ser mais acionável. **Isso é uma escolha de modelo de atribuição, não uma verdade absoluta** — multi-touch (dar crédito parcial a vários cliques) seria mais completo, mas é complexidade que não se justifica para V1 pessoal. Fica documentado como escolha consciente, revisável depois.

### 9A.3 — `page_view` × `visit`/`session` × `attributed_visit` — e o que alimenta LP Views

| Conceito | Definição | Conta como LP View? |
|---|---|---|
| `page_view` | Todo carregamento de página — inclui cada F5, cada navegação interna. Vários por pessoa, inclusive vários por minuto. | **Não** |
| `visit` / `session` | Um agrupamento de `page_view`s próximos no tempo da mesma pessoa — "uma ida ao site". Um F5 dentro da mesma sessão não cria uma sessão nova. | Não sozinho |
| `attributed_visit` | Uma `visit` que chegou com `ad_id`/UTMs identificáveis — gerou (ou reaproveitou) um `attribution_id` válido. | **Sim — é essa que alimenta o indicador** |

**Por quê `attributed_visit` e não as outras duas:** `page_view` bruto infla o número com refreshes, distorcendo o funil pra cima sem significar mais tráfego real. `visit`/sessão genérica incluiria tráfego orgânico/direto, que não tem relação com o anúncio — misturaria mídia paga com tudo o mais, quebrando a comparação com impressões/cliques (que são 100% sobre anúncio).

**Como evitamos que F5 infle o número, na prática:** a gravação em `landing_page_visits` só acontece quando um `attribution_id` **novo** é criado (regra 9A.2, passo 2 ou 4). Um refresh que reaproveita o `attribution_id` existente (passo 3) não cria linha nova — só atualiza o campo `last_seen_at` da linha já existente. **LP Views de um período = contagem de linhas criadas em `landing_page_visits` naquele período com `ad_id` preenchido** — nunca a contagem de `page_view`.

### 9A.4 — Schema de `landing_page_visits` (proposta — sem SQL, sem executar nada)

| Coluna | Tipo | Obrigatória? | Origem | Exemplo | Finalidade |
|---|---|---|---|---|---|
| `id` | uuid | Sim | Gerada pelo banco | `a1b2c3...` | Chave primária técnica |
| `attribution_id` | text | Sim (única) | Gerado pela Landing Page (9A.2) | `attr_7f3a9c21` | Elo entre visita e venda |
| `session_id` | text | Opcional | Gerado pela Landing Page, 1x por sessão de navegador (`sessionStorage`) | `sess_a1b2` | Agrupar múltiplos `attribution_id` da mesma pessoa na mesma sessão (ex.: caso 9A.7 "clica no A1 e depois no A2") — não é usado na atribuição em si, só análise futura |
| `created_at` | timestamptz | Sim | Momento da criação do `attribution_id` | `2026-09-28 14:32:00` | Quando essa visita/atribuição nasceu |
| `last_seen_at` | timestamptz | Sim | Atualizado a cada "toque" (refresh reaproveitando o mesmo `attribution_id`) | `2026-09-28 14:47:00` | Saber se a sessão ainda está ativa, sem criar linha nova |
| `utm_source` | text | Opcional | Query string | `meta` | Dimensão de análise |
| `utm_medium` | text | Opcional | Query string | `paid` | Dimensão de análise |
| `utm_campaign` | text | Opcional | Query string (`{{campaign.name}}`) | `WhatsApp-que-Agenda-Conversao` | Dimensão de análise |
| `utm_content` | text | Opcional | Query string (`{{ad.name}}`) | `A1-Demonstracao-Video` | Dimensão de análise |
| `campaign_id` | text | Opcional | Query string (`{{campaign.id}}`) | `c_001` | Junta com `marketing_daily_metrics` |
| `adset_id` | text | Opcional | Query string (`{{adset.id}}`) | `as_001` | Junta com `marketing_daily_metrics` |
| `ad_id` | text | Opcional | Query string (`{{ad.id}}`) | `120001` | **É o que importa de verdade** — junta a venda ao anúncio |
| `fbclid` | text | Opcional | Query string (auto-adicionado pela Meta) | `IwAR...` | Sinal extra de origem Meta; útil para uma futura Conversions API |
| `landing_page_url` | text | Recomendada | URL completa de chegada | `https://.../` | Saber qual página específica, se um dia houver mais de uma LP |
| `referrer` | text | Opcional, baixa prioridade | `document.referrer` | `https://facebook.com/` | Pouco valor aqui (tráfego é 100% pago via anúncio; referrer raramente diz mais que "veio do app Meta") — incluir ou não é indiferente |
| `user_agent` | — | **Não incluir na V1** | — | — | Avaliei e recomendo **omitir**: não ajuda em nada a cadeia de atribuição (não diz qual anúncio converteu), só serve para diagnóstico técnico futuro (mobile vs. desktop, detecção de bot) — não é necessário para o objetivo do projeto, e você pediu para não guardar dado desnecessário |

**Dados pessoais:** nenhuma coluna aqui identifica a pessoa (nome, e-mail, telefone, IP). O vínculo com a pessoa (se precisar) fica inteiramente do lado da Kiwify/tabela de vendas, que é regida pelas regras de dado pessoal dela — esta tabela só conecta uma visita anônima a um anúncio.

### 9A.5 — Segurança: Landing Page pública precisa ESCREVER, sem poder LER

Duas opções avaliadas:

**(a) RLS com `insert` público direto (chave anon insere na tabela, sem Edge Function no meio).** Mais simples — menos peças. Risco real: como a chave anon é pública por natureza (qualquer um consegue abrir o JS da Landing Page e copiá-la), e o endpoint do Supabase é previsível, alguém poderia mandar inserções falsas direto pro banco, sem passar pela sua Landing Page de verdade — não vaza dado nenhum (porque não existe `select` público), mas pode **poluir** a tabela com lixo.

**(b) Edge Function dedicada (`track-visit`) — recomendada.** A Landing Page chama essa função (endpoint HTTPS), que valida a requisição (ex.: conferir se veio do domínio esperado, limitar quantas requisições por IP num curto intervalo) e só ela grava na tabela, usando a service role — a chave anon nunca toca a tabela diretamente. Mesmo padrão que já vamos usar para `meta-ads-sync`, então não é uma peça conceitualmente nova no projeto.

**Recomendação para este projeto pessoal:** opção (b). O ganho de segurança (mitigar poluição de dados) compensa a peça extra, principalmente porque já vamos ter o hábito de escrever Edge Functions de qualquer forma.

**Regra de RLS, com qualquer uma das duas opções:** `landing_page_visits` **nunca** tem política de `select` para o público/anônimo — só `service_role` (sempre) e usuário autenticado via Supabase Auth (você, seção 7) podem ler. Isso impede um visitante de "consultar a tabela de visitas", "consultar métricas" ou "acessar dados do Dashboard" — ele só consegue, na melhor das hipóteses (opção a), inserir uma linha nova; nunca ler, alterar ou apagar o que já existe.

### 9A.6 — Exemplo completo, do clique à venda atribuída

1. Pessoa vê o anúncio **A1 | Demonstração | Vídeo** (`ad_id=120001`, `adset_id=as_001`, `campaign_id=c_001`) no Instagram e clica.
2. A Meta monta a URL de destino com os Parâmetros de URL configurados (9A.1):
   `https://landingpage.com/?utm_source=meta&utm_medium=paid&utm_campaign=WhatsApp-que-Agenda-Conversao&utm_content=A1-Demonstracao-Video&campaign_id=c_001&adset_id=as_001&ad_id=120001&fbclid=IwAR...`
3. A Landing Page carrega, olha o `localStorage`: não há `attribution_id` guardado (primeira visita).
4. Gera `attribution_id = "attr_7f3a9c21"`, guarda no `localStorage` junto com os parâmetros.
5. Chama a Edge Function `track-visit`, que grava em `landing_page_visits`:
   ```
   attribution_id: attr_7f3a9c21
   created_at / last_seen_at: 2026-09-28 14:32:00
   utm_source: meta · utm_medium: paid
   utm_campaign: WhatsApp-que-Agenda-Conversao · utm_content: A1-Demonstracao-Video
   campaign_id: c_001 · adset_id: as_001 · ad_id: 120001
   fbclid: IwAR...
   ```
6. Pessoa navega, dá um F5 sem querer — `localStorage` já tinha o `attribution_id`, então só `last_seen_at` é atualizado; nenhuma linha nova.
7. Pessoa clica em "Comprar" → checkout da Kiwify, com `s1=attr_7f3a9c21` na URL.
8. Pessoa paga, compra aprovada. Kiwify gera `order_id: "kw_998877"`.
9. Webhook Kiwify → Supabase: `{ order_id: "kw_998877", amount: 297.00, status: "approved", s1: "attr_7f3a9c21" }`.
10. Função de recebimento do webhook extrai `attr_7f3a9c21`, procura em `landing_page_visits` → encontra a linha do passo 5 → pega `ad_id=120001`, `adset_id=as_001`, `campaign_id=c_001`.
11. Grava a venda na tabela de vendas (9A.8), já vinculada:
    ```
    order_id: kw_998877 · attribution_id: attr_7f3a9c21
    ad_id: 120001 · adset_id: as_001 · campaign_id: c_001
    amount: 297.00 · status: approved
    ```
12. No próximo carregamento, o Dashboard mostra essa venda contando para **A1 | Demonstração | Vídeo** — CPA e ROAS de A1 já refletem.

### 9A.7 — Casos especiais: o que a V1 faz, e o que aceitamos como limitação

| Caso | Comportamento na V1 |
|---|---|
| Entra direto, sem anúncio | Pode gerar um `attribution_id` "sem origem" (todos os campos de anúncio nulos) — não conta como LP View pago (9A.3), mas ainda rastreia até o checkout, caso compre. |
| Google/Instagram orgânico | Igual ao caso acima — sem parâmetro de anúncio, `ad_id` nulo. |
| Anúncio sem parâmetros configurados | Mesmo clicando num anúncio real, chega sem `ad_id`/UTM — cai como "sem atribuição". **Limitação aceita**: só anúncios com Parâmetros de URL configurados (9A.1) geram atribuição completa. Ação futura: checklist operacional para configurar todo anúncio novo. |
| Usuário dá F5 | Reaproveita `attribution_id`, só atualiza `last_seen_at`, não cria linha nova, não infla LP Views. |
| Fecha e volta depois | Dentro de 7 dias sem novo clique em anúncio → mesmo `attribution_id`. Depois de 7 dias → novo `attribution_id` (tratado como nova visita). |
| Clica no A1, depois no A2 | O clique no A2 cria um `attribution_id` novo, substituindo o do A1 (regra "último clique vence", 9A.2). Se comprar depois disso, a venda é atribuída ao A2. **Limitação aceita**: não fazemos atribuição multi-touch nem first-click na V1 — decisão consciente de simplicidade. |
| Acessa no celular, compra depois em outro dispositivo | **Limitação real e aceita**: `localStorage` é por navegador/aparelho — não existe (nem está no escopo da V1) uma forma de ligar os dois sem pedir e-mail/telefone antes da compra. A venda no segundo aparelho chega sem `attribution_id` reconhecível → "sem atribuição". Resolver isso direito exigiria uma estratégia de identidade entre dispositivos, fora de escopo agora. |
| Kiwify não devolve `attribution_id` (`s1` vazio/ausente) | A função do webhook não encontra nada em `landing_page_visits` → venda gravada como "sem atribuição" (estado que a página Vendas já trata). A venda ainda conta na receita total do negócio, só não entra no CPA/ROAS de nenhum anúncio específico. |
| Webhook chega duas vezes | `order_id` como chave única na tabela de vendas (9A.8) — o segundo envio faz upsert (atualiza status/valor se mudou), nunca duplica a venda. Mesmo princípio de idempotência já usado para a sincronização da Meta (seção 10). |

### 9A.8 — Schema conceitual final (as 3 tabelas, sem SQL)

**`marketing_daily_metrics`** — 1 linha por dia + `ad_id`, vinda da Meta (detalhe completo na seção 4). Colunas-chave: `date`, `ad_id`, `campaign_id`, `adset_id`, `spend`, `impressions`, `reach`, `frequency`, `clicks`, `landing_page_view` (referência Meta), `initiate_checkout` (referência Meta), `raw_actions`. Chave natural: `(date, ad_id)`.

**`landing_page_visits`** — 1 linha por visita atribuída (9A.4). Colunas-chave: `attribution_id` (única), `ad_id`/`adset_id`/`campaign_id`, UTMs, `fbclid`, `created_at`, `last_seen_at`. Chave natural: `attribution_id`.

**`sales`/`orders`** (nova nesta revisão — ainda não detalhada antes):

| Coluna | Tipo | Obrigatória? | Origem | Finalidade |
|---|---|---|---|---|
| `order_id` | text | Sim (única) | Kiwify | Chave natural do pedido |
| `attribution_id` | text | Opcional | Webhook (`s1`) | Elo com `landing_page_visits` |
| `ad_id` / `adset_id` / `campaign_id` | text | Opcionais | Copiados de `landing_page_visits` no momento do webhook, se encontrado | Permitem CPA/ROAS por anúncio |
| `amount` | numeric | Sim | Kiwify | Receita |
| `status` | text | Sim | Kiwify | `pending`/`approved`/`refunded`/`chargeback` |
| `created_at` / `updated_at` | timestamptz | Sim | Sistema | Auditoria e idempotência |

**Relacionamentos** (todos por valor de texto, sem chave estrangeira formal — mesma decisão já adotada para `marketing_daily_metrics`, apropriada para este porte de projeto):
- `sales.attribution_id` ↔ `landing_page_visits.attribution_id` — é aqui que a venda "descobre" o anúncio, no momento em que o webhook é processado.
- `sales.ad_id` ↔ `marketing_daily_metrics.ad_id` — é o que permite a camada de dados do Dashboard juntar gasto (Meta) com venda (Kiwify) por anúncio e por dia.

### 9A.9 — Fonte da verdade (reapresentada no formato pedido)

| Métrica | Fonte da verdade | Como é calculada |
|---|---|---|
| Gasto | Meta Ads | Soma de `spend` das linhas do período |
| Impressões | Meta Ads | Soma de `impressions` das linhas do período |
| Cliques | Meta Ads | Soma de `clicks` das linhas do período |
| CTR | Calculado | Cliques do período ÷ Impressões do período (nunca média de CTRs diários) |
| CPC | Calculado | Gasto do período ÷ Cliques do período |
| CPM | Calculado | Gasto do período ÷ Impressões do período × 1000 |
| LP Views | Landing Page (`landing_page_visits`, proposta em 9A.4) | Contagem de `attributed_visit` (9A.3) criadas no período, com `ad_id` preenchido |
| Checkouts | **Nossa infraestrutura** (`checkout_events`, ver 9B.3 — não é a Kiwify) | Contagem de eventos `checkout_started` no período |
| Vendas | Kiwify/Supabase | Contagem de pedidos com `status = approved` no período |
| Receita | Kiwify/Supabase | Soma de `amount` dos pedidos aprovados no período |
| CPA | Calculado | Gasto do período ÷ Vendas do período |
| ROAS | Calculado | Receita do período ÷ Gasto do período |

> **Correção em relação à primeira versão desta tabela (Revisão 2):** eu tinha listado "Checkouts" como vindo de "Kiwify/Supabase". Isso estava errado — investiguei (seção 9B) e a Kiwify **não** oferece um evento confiável para "checkout iniciado". Checkouts vêm da nossa própria infraestrutura.

## 9B. Checkout — investigação e fonte da verdade (Revisão 4)

### 9B.1 — Investigação do checkout atual no projeto (pendência explícita)

Busquei em todo este repositório (`Repositorio_Teste`, não só na pasta do dashboard) por qualquer referência a Kiwify, link de checkout, CTA de compra. Resultado:

- **Onde está o link do checkout hoje?** Não encontrado neste repositório. O único material de "landing page" que existe aqui é de um produto **diferente** (a landing do CRM "Clínica que Converte", em `Contexto/04-marketing-e-branding-clinica-que-converte.md`), e o CTA dela leva para o WhatsApp, não para a Kiwify — não tem relação com o funil do WhatsApp que Agenda.
- **Como o `attribution_id` é enviado hoje?** Não posso confirmar — a Landing Page do WhatsApp que Agenda (a que teria esse código) não está neste repositório.
- **Quais parâmetros são enviados hoje?** Não posso confirmar, mesmo motivo.
- **Existe algum evento nosso antes do redirecionamento, hoje?** Não — nem poderia existir: a própria infraestrutura de `landing_page_visits`/`checkout_events` ainda é só uma proposta desta auditoria (seção 9A), não foi implementada em lugar nenhum ainda.
- **Existe hoje qualquer registro no Supabase quando alguém clica em comprar?** Não — não existe nenhum Supabase conectado a nenhum projeto deste repositório (confirmado já na Revisão 2).
- **Conseguimos hoje saber que uma visita avançou para o checkout?** Não.

**Pendência explícita:** preciso de acesso ao código real da Landing Page do WhatsApp que Agenda (projeto fora deste repositório) para confirmar tecnicamente como o link/redirecionamento para a Kiwify está montado hoje. Até lá, tudo sobre o comportamento *atual* da Landing Page é o que você me descreveu, não algo que eu verifiquei em código — mesma ressalva já registrada nas seções 9 e 9A sobre o `attribution_id`.

### 9B.2 — O que a Kiwify realmente oferece (pesquisado agora, não suposto)

A Kiwify expõe **10 eventos de webhook**, e nenhum deles é "abriu o checkout":

`boleto_gerado` · `pix_gerado` · `carrinho_abandonado` · `compra_recusada` · `compra_aprovada` · `compra_reembolsada` · `chargeback` · `subscription_canceled` · `subscription_late` · `subscription_renewed`

| Evento nosso/dela | O que realmente significa | Confunde com "abriu o checkout"? |
|---|---|---|
| Visita ao checkout | Página carregou no navegador da pessoa | **Não existe webhook da Kiwify para isso** |
| `carrinho_abandonado` | Formulário parcialmente preenchido + tempo de inatividade | **Não é a mesma coisa** — depende de preenchimento e/ou tempo, exatamente como você suspeitava. Não confundir com "checkout iniciado". |
| `pix_gerado` / `boleto_gerado` | Pessoa escolheu a forma de pagamento e o código foi criado | Não — acontece mais adiante, depois de preencher dados |
| `compra_aprovada` | Pagamento confirmado | Não — é o fim do funil, não o início |

Confirmei também que a Kiwify aceita parâmetros de rastreamento na URL do checkout — `utm_campaign`, `utm_term`, `utm_content`, **`s1`, `s2`, `s3`** — guardados via cookie e devolvidos junto com o pedido. Isso valida a premissa já usada desde a Revisão 1 (`attribution_id` viajando pelo `s1`). O que ainda não confirmei é o caminho exato desse campo dentro do JSON do webhook — mesma ressalva do `action_type` da Meta: **confirmar com uma chamada/webhook de teste real antes de escrever qualquer parser definitivo**, não assumir o formato agora.

**Sobre o "Initiate Checkout" da Meta (pixel):** é um evento disparado pela Kiwify (ou pelo script dela) **direto no navegador da pessoa, para o pixel da Meta** — nunca passa pelo nosso backend. Só voltamos a ver esse número indiretamente, dentro do relatório de Insights da Meta (`initiate_checkout`, já tratado como referência desde a Revisão 1, nunca fonte de verdade). É um evento completamente diferente de qualquer webhook que a Kiwify nos envia.

**Conclusão confirmada:** não existe, hoje, nenhuma forma de a Kiwify nos avisar de cada abertura simples do checkout. Precisamos de infraestrutura própria.

### 9B.3 — Proposta própria: `checkout_events`

Avaliando o modelo que você propôs:

```
Landing Page → clique no CTA de compra → nossa infraestrutura registra checkout_started → só depois redireciona para a Kiwify
```

**Adequado**, e é a mesma filosofia já usada em `landing_page_visits` (grava antes de agir).

**Tabela separada, e não um campo em `landing_page_visits`.** Motivos: (1) a mesma pessoa pode clicar em "comprar" mais de uma vez na mesma visita (tentou, voltou, tentou de novo) — um único campo na visita perderia essas tentativas repetidas; (2) manter "visita" e "intenção de compra" em tabelas separadas deixa cada uma responsável por uma coisa só, e não exige redesenhar `landing_page_visits` se um dia quisermos mais eventos de funil. Custo extra de manter uma tabela a mais é baixo; ganho é real.

**Limitação que você pediu para eu explicar, documentada: clique no CTA ≠ página de checkout efetivamente carregada.** Registrar no clique garante capturar a *intenção*, mas não garante que:
- o navegador completou a navegação até a Kiwify (conexão caiu, aba fechada no meio do caminho);
- a página de pagamento da Kiwify terminou de carregar do outro lado.

`checkout_started` (nosso) mede "a pessoa clicou querendo comprar" — é uma aproximação, do mesmo jeito que praticamente toda ferramenta de analytics trata "iniciar checkout" (é raro ter confirmação de carregamento do lado do provedor de pagamento). Não é uma falha nossa específica, mas precisa ficar documentado como o que realmente é, para não ser lido como "número exato" no futuro.

**Existe forma tecnicamente melhor?** Duas alternativas avaliadas, nenhuma adotada para a V1:
- (a) Um script/pixel de confirmação inserido na própria página de checkout da Kiwify — dependeria de a Kiwify permitir isso (ela permite inserir o pixel da Meta; não confirmei se permite um script arbitrário nosso — ficaria para avaliar quando chegarmos nessa etapa).
- (b) **Recomendado para a V1:** aceitar `checkout_started` (nosso, no clique) como a aproximação de "checkout iniciado", e tratar `pix_gerado`/`boleto_gerado`/`compra_aprovada` (esses sim confirmados pela Kiwify) como os sinais reais mais adiante no funil. Mais simples, não depende de uma permissão da Kiwify que não confirmei existir, e é honesto sobre o que está medindo.

### 9B.4 — Definições das etapas do funil

| Etapa | Fonte | Evento | Quando é contabilizada | Deduplicação | Limitações |
|---|---|---|---|---|---|
| **IMPRESSÃO** | Meta Ads | `impressions` (Insights) | Cada exibição do anúncio | Nenhuma — contagem bruta, não de pessoas (para pessoas únicas existe `reach`, não somável entre dias — seção 3) | Confiamos no que a Meta reporta; não auditável de fora |
| **CLIQUE** | Meta Ads | `clicks` (Insights) | Cada clique no anúncio | Nenhuma — contagem bruta | Nem todo clique vira LP View real (conexão cai, pessoa desiste antes de carregar) — CLIQUE ≥ LP VIEW sempre esperado |
| **LP VIEW** | Nossa (`landing_page_visits`, 9A) | Criação de `attribution_id` novo com `ad_id` preenchido (= `attributed_visit`, 9A.3) | Na 1ª carga que traz um clique de anúncio válido — nunca em refresh (9A.3) | Por `attribution_id`; refresh dentro de 7 dias reaproveita, não gera linha nova | Só conta se o anúncio tiver Parâmetros de URL configurados (9A.1); tráfego direto/orgânico nunca entra aqui |
| **CHECKOUT** | **Nossa** (`checkout_events`, 9B.3) — a Kiwify não oferece isso | `checkout_started`, no clique do CTA, antes do redirecionamento | No clique — aproximação de intenção, não confirmação de chegada (9B.3) | Por `attribution_id` + `started_at`; múltiplos cliques da mesma visita **são** contados (cada tentativa é um sinal real) | Mede intenção de clicar, não confirmação de que a Kiwify carregou (9B.3) |
| **VENDA** | Kiwify/Supabase | Webhook `compra_aprovada` | Quando a Kiwify confirma pagamento aprovado | Por `order_id` (chave única) — reenvio do webhook faz upsert, nunca duplica | Só conta o que a Kiwify classifica como aprovado; `compra_reembolsada`/`chargeback` são eventos separados, sem fluxo de estorno automático detalhado nesta V1 (ver limitações, 9B.9) |

### 9B.5 — A janela de 7 dias é NOSSA, não da Meta

Registro explícito, para nunca confundirmos uma diferença de número com um bug no futuro: a janela de 7 dias (regra de expiração do `attribution_id`, 9A.2, e a janela de ressincronização, seção 10) é uma **decisão nossa de projeto** — escolhida por *espelhar*, não por *reproduzir*, a janela de clique padrão que a Meta usa hoje. Isso não garante que:

- a metodologia de atribuição interna do Ads Manager (que decide o que ele credita a cada anúncio nos relatórios dele) funcione exatamente assim — a Meta pode cruzar múltiplos touchpoints, Pixel e Conversions API, de um jeito que não temos visibilidade nem controle;
- os números do nosso Dashboard batam com os do Ads Manager — inclusive porque, por desenho (desde a primeira versão desta auditoria), nunca usamos o "Purchase" da Meta como fonte de venda. Uma divergência aqui é esperada, não indício de erro.

### 9B.6 — Last-click confirmado (*last paid click attribution*)

Confirmando formalmente a regra: se a pessoa clica no A1 (gera `attribution_id` X) e depois clica no A2 (gera `attribution_id` Y, substituindo X), uma venda associada a Y é atribuída ao A2. Chamo isso de **last paid click attribution** — o último clique *pago* (com `ad_id`/UTM na URL) sempre vence.

**Tráfego direto/orgânico depois de um clique pago ainda válido:** pela regra 9A.2, um acesso **sem** parâmetro de anúncio (direto, digitou a URL, orgânico) **não** cria um `attribution_id` novo enquanto um válido (dentro da janela de 7 dias) já existir — ele **reaproveita** o `attribution_id` pago existente. Ou seja: tráfego direto/orgânico dentro da janela **não rouba** a atribuição do clique pago anterior; só um **novo clique em anúncio** (com `ad_id`/UTM) substitui.

### 9B.7 — Schema final (4 tabelas, sem SQL)

**`marketing_daily_metrics`** (Meta, 1 linha/dia/`ad_id`) — sem mudanças desde a Revisão 2 (seção 4).

**`landing_page_visits`** (1 linha por visita atribuída) — sem mudanças desde a Revisão 3 (9A.4).

**`checkout_events`** (nova nesta revisão — 1 linha por clique no CTA de compra):

| Coluna | Tipo | Obrigatória? | Origem | Finalidade |
|---|---|---|---|---|
| `id` | uuid | Sim | Gerada pelo banco | PK técnica |
| `attribution_id` | text | Sim | `localStorage`, no momento do clique | Elo com `landing_page_visits` |
| `session_id` | text | Opcional | `sessionStorage` | Agrupamento por sessão (mesmo uso de 9A.4) |
| `campaign_id` / `adset_id` / `ad_id` | text | Opcionais | Copiados do `attribution_id` ativo no momento do clique | Permite funil Checkout por anúncio |
| `started_at` | timestamptz | Sim | Momento do clique no CTA | Quando a intenção aconteceu |
| `created_at` | timestamptz | Sim | Sistema | Auditoria |

Chave natural: `(attribution_id, started_at)` — evita duplicar o exato mesmo clique reenviado duas vezes por engano, mas **permite** múltiplos cliques genuinamente diferentes da mesma visita (diferente de `landing_page_visits`, aqui repetição é sinal válido, não ruído).

**`sales`/`orders`** — sem mudanças desde a Revisão 3 (9A.8).

**Relacionamentos (todos por valor de texto, sem FK formal):**
- `checkout_events.attribution_id` ↔ `landing_page_visits.attribution_id`
- `sales.attribution_id` ↔ `landing_page_visits.attribution_id`
- `sales.ad_id` ↔ `marketing_daily_metrics.ad_id`

`checkout_events` não precisa de relação direta com `sales` — as duas já se conectam indiretamente via `attribution_id`, que é o elo central de toda a cadeia.

### 9B.8 — Funil final, com fonte da verdade ao lado

```
META
  Impressão ─────────── fonte: Meta Ads (Insights)
      ↓
  Clique ──────────────  fonte: Meta Ads (Insights)
      ↓
LANDING PAGE
  LP View ─────────────  fonte: NOSSA (landing_page_visits, 9A)
      ↓
  Checkout ────────────  fonte: NOSSA (checkout_events, 9B.3) — a Kiwify não confirma isso
      ↓
KIWIFY
      ↓
  Venda aprovada ──────  fonte: Kiwify/Supabase (webhook compra_aprovada, 9B.4)
```

### 9B.9 — Congelamento da arquitetura

Revisando as 3 rodadas desta auditoria (Revisões 2, 3 e 4): todo indicador do Dashboard agora tem uma fonte da verdade definida, uma regra de deduplicação definida, e um comportamento definido para os casos de borda relevantes. As únicas pendências restantes são de **acesso/confirmação no momento da implementação**, não de desenho:

- Confirmar o `action_type` exato retornado pela sua conta Meta (chamada de teste real, já planejada — 9A.1/12).
- Confirmar o caminho exato do campo `s1` dentro do JSON do webhook da Kiwify (webhook de teste real, mesma lógica).
- Obter acesso ao código da Landing Page (fora deste repositório) para implementar `landing_page_visits`/`checkout_events` (9B.1).

Nenhuma dessas é uma lacuna de arquitetura — são passos de implementação já previstos na ordem da seção 16.

**Declaro: ARQUITETURA V1 PRONTA PARA IMPLEMENTAÇÃO.**

Limitações conhecidas que estamos aceitando conscientemente:
- `checkout_started` mede intenção de clique, não confirmação de que a página da Kiwify carregou (9B.3).
- Sem atribuição entre dispositivos diferentes (9A.7).
- Modelo *last paid click* — não first-click, não multi-touch (9B.6).
- Números do Dashboard podem divergir do Ads Manager — janela de atribuição própria (9B.5) e fonte de venda diferente (nunca o "Purchase" da Meta) por desenho.
- Depende de configuração manual em cada anúncio da Meta (Parâmetros de URL, 9A.1) — sem isso, aquele anúncio específico fica sem atribuição, mesmo sendo tráfego pago real.
- `reach`/frequência de período não são derivados com precisão das linhas diárias (seção 3).
- Reembolso/chargeback (`compra_reembolsada`/`chargeback`) não têm fluxo de estorno automático detalhado nesta V1 — a venda permanece contada até tratarmos isso numa iteração futura.

## 10. Sincronização — janela móvel de 7 dias

Sua proposta (ressincronizar os últimos 7 dias todo dia, em vez de só "hoje") é adequada e mais simples do que a versão anterior desta auditoria (que sugeria "3–7 dias" de forma vaga). Fechando em **7 dias fixos**:

- Cobre com folga a janela de revisão da Meta (~72h) para números que ela ainda pode ajustar.
- Coincide com o filtro "7 dias" do próprio dashboard — depois de cada sincronização, essa visão está sempre 100% atualizada.
- Idempotente por construção: `upsert(..., { onConflict: 'date,ad_id' })` bate com a `unique(date, ad_id)` da tabela — rodar de novo sobre os mesmos 7 dias só atualiza as linhas existentes, nunca duplica.

## 11. Backfill

Mesma Edge Function, chamada uma vez com um intervalo maior (ex. 30–60 dias) — sem mudanças em relação à versão anterior desta auditoria.

## 12. Raw actions — mantido

Continua a proposta: guardar a resposta bruta de `actions` (coluna `raw_actions`) e **não** criar nenhum parser definitivo de LP View/Checkout/Purchase antes de uma chamada real à sua conta confirmar os nomes exatos de `action_type` que ela retorna (múltiplas variantes confirmadas na revisão anterior desta auditoria — ex. `omni_initiated_checkout`, `offsite_conversion.fb_pixel_initiate_checkout`).

## 13. Migração dos mocks sem quebrar o dashboard atual

```js
const DATA_SOURCE = "mock"; // depois: "supabase"
```

Sem mudança na ideia central em relação à versão anterior — só uma consequência nova da seção 7: quando `DATA_SOURCE = "supabase"`, o dashboard também precisa de uma sessão de login válida antes de conseguir ler qualquer coisa (senão o RLS bloqueia). Continua recomendado não virar a chave para `"supabase"` até Meta **e** Kiwify (com a tabela `landing_page_visits` funcionando) estarem validados — misturar gasto real com vendas mock continua distorcendo CPA/ROAS.

## 14. Fonte da verdade — tabela conceitual

| Métrica | Fonte da verdade | Campo/origem | Soma entre dias? | Observação |
|---|---|---|---|---|
| Gasto | Meta Ads | `spend` (Insights) | Sim | Aditivo |
| Impressões | Meta Ads | `impressions` (Insights) | Sim | Aditivo |
| Alcance | Meta Ads | `reach` (Insights) | **Não** | Válido só por dia; soma superestima o período (seção 3) |
| Cliques | Meta Ads | `clicks` (Insights) | Sim | Aditivo |
| CTR | Calculado | cliques(período) ÷ impressões(período) | — | Nunca média de CTRs diários |
| CPC | Calculado | gasto(período) ÷ cliques(período) | — | Nunca média de CPCs diários |
| CPM | Calculado | gasto(período) ÷ impressões(período) × 1000 | — | Nunca média de CPMs diários |
| Frequência | Meta Ads (por dia) / calculado com ressalva | `frequency` (Insights, por dia) | **Não** a partir das linhas diárias | Período exato exige consulta dedicada sem `time_increment` |
| LP Views | Landing Page (própria) | tabela `landing_page_visits` — proposta, não existe ainda | Sim, quando existir | Nunca da Meta nem da Kiwify como fonte de verdade |
| Checkouts | Kiwify/Supabase | pedido iniciado | Sim | `initiate_checkout` da Meta é só referência |
| Vendas | Kiwify/Supabase | pedido aprovado, vinculado por `attribution_id` | Sim | Nunca o "Purchase" da Meta |
| Receita | Kiwify/Supabase | valor do pedido aprovado | Sim | Idem |
| CPA | Calculado | gasto(período) ÷ vendas(período) | — | Cruza Meta (gasto) com Kiwify (vendas) |
| ROAS | Calculado | receita(período) ÷ gasto(período) | — | Idem |

## 15. Arquitetura final — com os pontos exatos de criação/captura/armazenamento

**Fluxo de mídia (Meta):**

```
META ADS
  │  campaign_id, adset_id, ad_id nascem AQUI (atribuídos pela própria Meta)
  ▼
EDGE FUNCTION "meta-ads-sync"
  │  única detentora do token · roda 1x/dia · ressincroniza os últimos 7 dias (seção 10)
  ▼
SUPABASE — marketing_daily_metrics
  │  RLS: leitura só para usuário autenticado (seção 7) · escrita só via service role
  ▼
DASHBOARD  (login via Supabase Auth → sessão → RLS libera leitura)
  ▼
ANALISTA IA  (lê a mesma camada de dados — nunca fala com a Meta)
```

**Fluxo de atribuição e vendas (Landing Page + Kiwify):**

```
ANÚNCIO (Meta Ads)
  │  campaign_id / adset_id / ad_id já existem aqui
  ▼
LANDING PAGE  (projeto separado, fora deste repositório)
  │  usuário chega com utm_source/utm_medium/utm_campaign/utm_content/fbclid na URL
  │  a LP CRIA o attribution_id aqui
  ▼
[PROPOSTO] SUPABASE — landing_page_visits
  │  attribution_id + UTMs + fbclid + campaign_id/adset_id/ad_id GRAVADOS AQUI
  │  (este é o único lugar do sistema que vai guardar essa relação)
  ▼
LANDING PAGE redireciona pro checkout Kiwify, levando attribution_id no parâmetro s1
  ▼
KIWIFY processa o pedido (order_id, valor, status)
  ▼
WEBHOOK Kiwify → Supabase  (chega com order_id + s1)
  ▼
[PROPOSTA] Função de recebimento do webhook
  │  procura attribution_id em landing_page_visits
  │  achou → venda vinculada a ad_id/campaign_id/adset_id
  │  não achou → venda "sem atribuição" (já tratado na página Vendas)
  ▼
SUPABASE — tabela de vendas (Kiwify)
  ▼
CAMADA DE DADOS DO DASHBOARD
  │  junta marketing_daily_metrics (Meta) + vendas (Kiwify) por ad_id + date
  ▼
VISÃO GERAL · CAMPANHAS · CRIATIVOS · FUNIL · VENDAS
  ▼
ANALISTA IA
```

As duas cadeias só se encontram na "camada de dados do dashboard" — nunca antes disso.

## 16. Ordem de implementação (atualizada)

1. Você garante o Meta App + System User + token `ads_read`.
2. Chamada de teste manual à Insights API para confirmar os `action_type` reais da sua conta.
3. Aprovação do schema final de `marketing_daily_metrics`, `landing_page_visits`, `checkout_events` e `sales`/`orders` (seção 9B.7).
4. Criar as tabelas no Supabase (SQL fornecido por mim, você executa/autoriza).
5. Configurar Supabase Auth (criar seu usuário) e as políticas de RLS revisadas (seção 7 e 9A.5).
6. Configurar os secrets da Edge Function.
7. Construir a Edge Function `meta-ads-sync`, testada manualmente.
8. Validar os dados contra o Ads Manager.
9. Backfill do período desejado.
10. Agendamento (cron, janela de 7 dias).
11. Configurar os **Parâmetros de URL** nos anúncios da Meta (9A.1) — ação manual sua, anúncio por anúncio.
12. Confirmar acesso ao código da Landing Page (pendência da seção 9B.1) e construir a Edge Function `track-visit` + a lógica de `attribution_id` no `localStorage` (9A.2/9A.5).
13. Construir a Edge Function que registra `checkout_started` no clique do CTA, antes do redirecionamento para a Kiwify (9B.3).
14. Fazer um webhook de teste real da Kiwify para confirmar o caminho exato do campo `s1` no payload (9B.2), então construir a função de recebimento do webhook, gravando em `sales` (9A.6/9A.7).
15. Implementar a tela de login no `index.html` + cliente Supabase, ainda com `DATA_SOURCE = "mock"`.
16. Testar com `DATA_SOURCE = "supabase"` sem commitar/publicar até você validar visualmente.
17. Só com Meta e Kiwify validados: revisão de diff, commit, push — com sua autorização.

## 17. Riscos (atualizado)

- Nome exato do `action_type` incerto até a chamada de teste — mitigado por `raw_actions`.
- Mudança de janelas de atribuição da Meta (jan/2026) — documentado em `attribution_setting`.
- Token expira/é revogado — depende da Edge Function escrever em `error_message`/`last_sync_at`.
- Rate limit em backfills grandes — mitigado por lotes menores.
- Mistura acidental mock + real — mitigado pela recomendação da seção 13.
- **[Novo]** `reach`/`frequência` de período não podem ser derivados com precisão das linhas diárias — se um dia isso for necessário, exige uma chamada adicional à Meta, fora do desenho atual (seção 3).
- **[Novo]** A parte de LP View/atribuição real depende de alterar um projeto (a Landing Page) que está **fora deste repositório** — não tenho como avaliar o esforço nem o código de lá a partir desta sessão; é uma dependência externa, não só uma tarefa de banco de dados.
- **[Novo]** Adicionar login (Supabase Auth) muda o comportamento atual do dashboard (hoje abre direto, sem tela nenhuma) — pequeno, mas é uma mudança real de experiência a ter em mente.
- **[Novo]** O modelo de atribuição "último clique vence" (9A.2) é uma escolha, não uma verdade absoluta — em campanhas com retargeting pesado, pode dar crédito a um anúncio de retargeting por uma venda que o anúncio original de prospecção "preparou". Aceito conscientemente para V1.
- **[Novo]** Atribuição entre dispositivos diferentes (celular → compra no computador) não é resolvida — venda cai como "sem atribuição" (9A.7). Limitação conhecida, não um bug.
- **[Novo]** Se um anúncio não tiver os Parâmetros de URL configurados na Meta (9A.1), toda venda dele cai como "sem atribuição" mesmo sendo tráfego pago real — depende de checklist manual, não é garantido por código.
- **[Novo — Revisão 4]** A Kiwify não confirma "checkout iniciado" — `checkout_started` é uma aproximação nossa (clique no CTA), não uma confirmação de que a página de pagamento carregou (9B.3).
- **[Novo — Revisão 4]** A janela de atribuição de 7 dias é nossa, não da metodologia interna da Meta — divergências com o Ads Manager são esperadas, não indício de bug (9B.5).
- **[Novo — Revisão 4]** Reembolso/chargeback (`compra_reembolsada`/`chargeback`) não têm fluxo de estorno automático detalhado nesta V1 — fica para uma iteração futura (9B.9).

## 18. Ações que dependem de você (atualizado)

1. Meta: App + System User + token `ads_read` + Ad Account ID.
2. Configurar os Parâmetros de URL em cada anúncio ativo (9A.1) — sem isso, aquele anúncio não gera atribuição.
3. Confirmar/criar o projeto Supabase.
4. Criar seu usuário no Supabase Auth (Authentication → Users → Add user) quando chegarmos na etapa 5 da seção 16.
5. Me dizer como (ou se) terei acesso ao código da Landing Page quando chegarmos na etapa 12 da seção 16 (pendência 9B.1) — ou se essa parte específica você/outra pessoa vai implementar, e eu só forneço a especificação.
6. Colar os secrets no painel do Supabase quando eu indicar exatamente onde — nunca no chat.

---

**ARQUITETURA V1 PRONTA PARA IMPLEMENTAÇÃO** (declarado na seção 9B.9), com as limitações conhecidas listadas na seção 17 e em 9B.9. Nada neste documento foi executado — nenhuma tabela criada, nenhum SQL rodado, nenhuma credencial configurada, nenhuma Edge Function escrita, `index.html` e a Landing Page intocados. Aguardando sua aprovação final antes de começar a implementação pelo passo 1 da seção 16.
