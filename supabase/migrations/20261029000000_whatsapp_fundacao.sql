-- ============================================================
-- WhatsApp V1.1 — Fundação Supabase (tabelas, RLS, grants, índices)
-- ------------------------------------------------------------
-- NÃO EXECUTAR ainda — aguardando autorização explícita para rodar
-- manualmente no SQL Editor do projeto Supabase da Mori Ortodontia
-- (rynlzkdqxbzwcznufnpn). Esta sessão não tem credenciais de banco para
-- aplicar automaticamente.
--
-- Escopo desta migration (auditoria aprovada — ver relatório da fase
-- anterior): SOMENTE a fundação de dados. Nenhuma integração real com
-- Evolution/Meta, nenhum webhook, nenhum envio real, nenhuma mídia. As
-- três tabelas abaixo nascem e ficarão VAZIAS no Supabase real até a
-- V1.2 (webhook) existir — nada aqui semeia dado fictício.
--
-- ------------------------------------------------------------
-- Princípio de arquitetura (camada de provider — preservado)
-- ------------------------------------------------------------
-- Frontend -> Backend/estrutura WhatsApp do CRM -> WhatsApp Provider ->
-- Evolution (agora) / Meta Cloud API (futuro). Nada aqui conhece
-- "Evolution" como conceito estrutural — `provider` é só um rótulo de
-- rastreabilidade (coluna/CHECK), nunca uma FK ou tabela específica do
-- provider. Histórico pertence ao CRM: id interno sempre uuid gerado
-- aqui; `id_externo_provider`/`provider` são só metadata de auditoria.
--
-- ------------------------------------------------------------
-- Padrão multi-tenant seguido (mesmo já usado em todo o projeto)
-- ------------------------------------------------------------
-- FKs compostas (clinica_id, id) contra as tabelas-pai, RLS habilitada
-- com policy `clinica_id in (select public.minhas_clinicas())`, e
-- SOMENTE SELECT concedido a `authenticated` nas três tabelas — mesmo
-- racional já usado em ciclos_recorrencia/retornos_recorrencia
-- (20261023000001_recorrencia_schema.sql): nesta fase NÃO EXISTE
-- nenhum caminho de escrita direta pelo cliente autenticado (nem RPC,
-- nem policy de insert/update) — estruturalmente impossível, não só
-- "desencorajado". O botão Enviar do frontend fica desabilitado em modo
-- Supabase (ver rodada de frontend) exatamente porque não há como
-- gravar uma mensagem real ainda — não vamos abrir uma porta de escrita
-- "para não ficar vazio" e depois ter que confiar no frontend para não
-- fabricar uma mensagem falsa. A escrita real (V1.2) será feita por um
-- backend com service_role (bypassa RLS) ou por uma RPC SECURITY
-- DEFINER dedicada, nunca por GRANT direto de INSERT ao authenticated.
--
-- ------------------------------------------------------------
-- Decisões de modelagem (auditoria pedida explicitamente — "avalie se
-- todos são necessários ou se algum deve ser derivado")
-- ------------------------------------------------------------
-- 1) whatsapp_conversas.ultima_mensagem_em é uma GENERATED COLUMN
--    (greatest dos outros dois timestamps) — nunca mantida por trigger,
--    nunca pode ficar dessincronizada dos dois campos-fonte.
-- 2) whatsapp_conversas.ultima_mensagem_paciente_em /
--    ultima_mensagem_clinica_em são mantidas por um trigger simples em
--    whatsapp_mensagens (AFTER INSERT) — cada direção escreve só a sua
--    própria coluna, sem precisar comparar com a direção oposta
--    (nenhuma condição de corrida entre "quem chegou por último").
--    "aguardando_resposta" nunca é persistido como booleano — é só a
--    comparação `ultima_mensagem_paciente_em > ultima_mensagem_clinica_em`
--    (ou clinica_em null), calculada em JS/SQL sob demanda, igual ao
--    `statusConversaWhatsapp()` que já existe no frontend hoje.
-- 3) Rejeitado "recebida_em" como coluna separada (estava na sugestão
--    inicial) — `enviada_em` já serve como o único timestamp canônico
--    de "quando a mensagem aconteceu", para os dois autores (o paciente
--    também "envia" a mensagem dele). Reduz uma coluna nullable sem
--    perder nenhuma informação que algo hoje precise. Pode ser
--    reintroduzido na V1.2 se o webhook precisar distinguir
--    "quando o provider recebeu" de "quando o paciente realmente
--    enviou" (nem toda integração garante os dois iguais) — é uma
--    coluna aditiva, não quebraria nada do que existe aqui.
-- 4) Nenhum "contador de minutos" é persistido em lugar nenhum — só
--    timestamps. O cálculo de "aguardando há Xh" continua 100% no
--    frontend (mesma regra já homologada: <90min normal, >=90min
--    atenção, >=120min atrasado).
-- 5) Idempotência de mensagem externa duplicada (V1.2 reentrega de
--    webhook): UNIQUE (clinica_id, provider, id_externo_provider) em
--    whatsapp_mensagens. NULLs não colidem entre si (comportamento
--    padrão do Postgres), então mensagens sem id externo (ex.: uma
--    futura mensagem "enviando" ainda sem confirmação do provider)
--    continuam permitidas sem conflito — a garantia vale exatamente
--    para quando o id externo realmente existe, que é quando duplicação
--    por reentrega de webhook pode acontecer.
-- 6) Telefone duplicado entre pacientes (legítimo em odontologia — mãe/
--    filho, irmãos): `whatsapp_conversas.paciente_id` fica NULL sempre
--    que houver 0 ou mais de 1 paciente com o mesmo telefone_e164 — a
--    escolha automática só é aceitável com exatamente 1 candidato. Essa
--    regra é responsabilidade do futuro webhook/RPC (V1.2), não desta
--    migration — aqui só garantimos que a coluna é nullable e sem
--    nenhum valor-default que force uma associação.
-- 7) Realtime: a publicação é habilitada aqui (ALTER PUBLICATION, no
--    final deste arquivo) porque é inofensivo e aditivo (a tabela só
--    emite eventos quando algo for inserido, e nada insere ainda) — mas
--    a SUBSCRIPTION no frontend fica para a V1.2. Motivo: esta sessão
--    não tem como validar o comportamento real do Supabase Realtime
--    (o Postgres descartável local usado para testar esta migration não
--    roda o serviço de Realtime) — não é prudente escrever código de
--    subscription sem conseguir testá-lo de ponta a ponta contra a
--    infraestrutura real. Ver relatório para o plano técnico detalhado.
-- ============================================================

begin;

-- ------------------------------------------------------------
-- 1) whatsapp_instancias — a conexão de WhatsApp de uma clínica.
--    Nasce vazia: nenhuma instância real existe até a V1.2 (Evolution).
-- ------------------------------------------------------------
create table public.whatsapp_instancias (
  id                     uuid primary key default gen_random_uuid(),
  clinica_id             uuid not null references public.clinicas(id),
  provider               text not null,
  identificador_externo  text null,
  telefone_e164          text null,
  nome_exibicao          text null,
  status_conexao         text not null default 'nao_conectado',
  metadata               jsonb not null default '{}'::jsonb,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),

  -- Suporta as FKs compostas de whatsapp_conversas (clinica_id, instancia_id).
  constraint whatsapp_instancias_clinica_id_uniq unique (clinica_id, id),

  -- Enum fechado e pequeno de propósito: só os provedores que o CRM
  -- realmente sabe falar. Adicionar um novo provider é uma migration
  -- pequena e explícita, nunca um valor livre vindo do frontend.
  constraint whatsapp_instancias_provider_check
    check (provider in ('evolution', 'meta')),

  constraint whatsapp_instancias_status_check
    check (status_conexao in ('nao_conectado', 'conectando', 'conectado', 'desconectado', 'erro')),

  -- Evita duas instâncias "apontando" para o mesmo identificador externo
  -- na mesma clínica/provider — NULL (instância ainda não pareada) não
  -- colide consigo mesmo, então várias instâncias "nao_conectado" sem
  -- identificador ainda podem coexistir sem conflito.
  constraint whatsapp_instancias_identificador_uniq
    unique (clinica_id, provider, identificador_externo)
);

comment on table public.whatsapp_instancias is
  'Conexão de WhatsApp de uma clínica (V1.1: schema apenas — nenhuma instância real existe até a Evolution ser conectada na V1.2). provider é rastreabilidade/roteamento, nunca lógica de negócio central.';
comment on column public.whatsapp_instancias.metadata is
  'Dados específicos do provider (ex.: parâmetros internos da Evolution) — nunca lido pela lógica central do CRM, só pela camada de provider.';

create index whatsapp_instancias_clinica_idx on public.whatsapp_instancias (clinica_id);

alter table public.whatsapp_instancias enable row level security;

create policy "select_whatsapp_instancias" on public.whatsapp_instancias
  for select to authenticated
  using (clinica_id in (select public.minhas_clinicas()));

-- Sem policy de insert/update/delete — propositalmente (ver cabeçalho).
-- RLS habilitada + zero policy de escrita = fail closed.

revoke all on public.whatsapp_instancias from public, anon;
grant select on public.whatsapp_instancias to authenticated;
-- Deliberadamente SEM insert, SEM update, SEM delete nesta fase.

-- ------------------------------------------------------------
-- 2) whatsapp_conversas — uma conversa, independente de provider.
-- ------------------------------------------------------------
create table public.whatsapp_conversas (
  id                            uuid primary key default gen_random_uuid(),
  clinica_id                    uuid not null references public.clinicas(id),
  instancia_id                  uuid null,
  paciente_id                   uuid null,
  telefone_e164                 text not null,
  nome_contato                  text null,
  ultima_mensagem_paciente_em   timestamptz null,
  ultima_mensagem_clinica_em    timestamptz null,
  -- Derivada, nunca mantida por trigger — ver decisão de modelagem (1) no cabeçalho.
  ultima_mensagem_em            timestamptz
    generated always as (greatest(ultima_mensagem_paciente_em, ultima_mensagem_clinica_em)) stored,
  created_at                    timestamptz not null default now(),
  updated_at                    timestamptz not null default now(),

  constraint whatsapp_conversas_clinica_id_uniq unique (clinica_id, id),

  constraint whatsapp_conversas_instancia_fk
    foreign key (clinica_id, instancia_id) references public.whatsapp_instancias (clinica_id, id),

  -- paciente_id é NULLABLE de propósito (conversa pode nunca ser
  -- associada, ou ficar sem associação automática por telefone
  -- duplicado — ver decisão de modelagem (6) no cabeçalho). A FK
  -- composta garante que, quando preenchido, só pode apontar para um
  -- paciente da MESMA clínica da conversa.
  constraint whatsapp_conversas_paciente_fk
    foreign key (clinica_id, paciente_id) references public.pacientes (clinica_id, id)
);

comment on table public.whatsapp_conversas is
  'Conversa de WhatsApp, independente de provider. paciente_id fica NULL até associação automática (exatamente 1 paciente com o mesmo telefone_e164) ou escolha humana futura — nunca associação arbitrária entre múltiplos candidatos.';
comment on column public.whatsapp_conversas.nome_contato is
  'Nome vindo do provider (ex.: nome de perfil do WhatsApp) — usado só quando NÃO há paciente_id associado; com paciente_id, a interface usa pacientes.nome.';
comment on column public.whatsapp_conversas.ultima_mensagem_em is
  'Derivada (GENERATED), só para ordenação da lista por recência — nunca a fonte de verdade de "aguardando resposta", que compara ultima_mensagem_paciente_em com ultima_mensagem_clinica_em.';

-- Conversas por clínica ordenadas por última mensagem (lista principal).
create index whatsapp_conversas_clinica_ultima_msg_idx
  on public.whatsapp_conversas (clinica_id, ultima_mensagem_em desc nulls last);

-- Busca por telefone (associação/consulta direta), independente de instância.
create index whatsapp_conversas_telefone_idx
  on public.whatsapp_conversas (clinica_id, telefone_e164);

-- Uma conversa por telefone por instância — só quando a instância já é
-- conhecida (parcial: ignora linhas com instancia_id NULL, que ainda não
-- se aplicam na V1.1, onde nenhuma instância existe de verdade).
create unique index whatsapp_conversas_instancia_telefone_uniq
  on public.whatsapp_conversas (clinica_id, instancia_id, telefone_e164)
  where instancia_id is not null;

-- Associação por paciente (só indexa quem realmente está associado).
create index whatsapp_conversas_paciente_idx
  on public.whatsapp_conversas (paciente_id)
  where paciente_id is not null;

alter table public.whatsapp_conversas enable row level security;

create policy "select_whatsapp_conversas" on public.whatsapp_conversas
  for select to authenticated
  using (clinica_id in (select public.minhas_clinicas()));

-- Sem policy de insert/update/delete — propositalmente (ver cabeçalho).

revoke all on public.whatsapp_conversas from public, anon;
grant select on public.whatsapp_conversas to authenticated;
-- Deliberadamente SEM insert, SEM update, SEM delete nesta fase.

-- ------------------------------------------------------------
-- 3) whatsapp_mensagens — mensagens de uma conversa. V1.1 só precisa
--    suportar tipo_conteudo='texto' funcionalmente, mas o modelo já
--    aceita os outros tipos sem precisar de ALTER TABLE depois.
-- ------------------------------------------------------------
create table public.whatsapp_mensagens (
  id                    uuid primary key default gen_random_uuid(),
  clinica_id            uuid not null,
  conversa_id           uuid not null,
  autor                 text not null,
  tipo_conteudo         text not null default 'texto',
  texto                 text null,
  midia_url             text null,
  status_envio          text not null,
  enviada_em            timestamptz not null default now(),
  provider              text null,
  id_externo_provider   text null,
  metadata              jsonb not null default '{}'::jsonb,
  created_at            timestamptz not null default now(),

  constraint whatsapp_mensagens_conversa_fk
    foreign key (clinica_id, conversa_id) references public.whatsapp_conversas (clinica_id, id),

  constraint whatsapp_mensagens_autor_check
    check (autor in ('paciente', 'clinica')),

  -- Preparado para imagem/documento/áudio/vídeo (item 15 do pedido) sem
  -- redesenho — só falta a coluna midia_url ser preenchida e a
  -- interface saber renderizar cada tipo (fora de escopo da V1.1).
  constraint whatsapp_mensagens_tipo_conteudo_check
    check (tipo_conteudo in ('texto', 'imagem', 'documento', 'audio', 'video')),

  -- Mensagem de texto precisa ter texto; os demais tipos (V1.2+) vão
  -- exigir midia_url em vez disso — sem acoplar aqui uma regra que
  -- ainda não sabemos os detalhes exatos (upload, formato de URL etc.).
  constraint whatsapp_mensagens_texto_obrigatorio_check
    check (tipo_conteudo <> 'texto' or texto is not null),

  constraint whatsapp_mensagens_status_envio_check
    check (status_envio in ('recebida', 'enviando', 'enviada', 'entregue', 'lida', 'falhou')),

  constraint whatsapp_mensagens_provider_check
    check (provider is null or provider in ('evolution', 'meta')),

  -- [Idempotência — item 13 do pedido] Garante, no próprio banco, que a
  -- reentrega de um mesmo webhook (ou uma corrida de dois workers) nunca
  -- grava a mesma mensagem duas vezes — nunca dependendo só do
  -- frontend/backend "lembrarem" de checar antes de inserir. NULL não
  -- colide com NULL (padrão Postgres), então mensagens sem id externo
  -- continuam permitidas sem conflito.
  constraint whatsapp_mensagens_id_externo_uniq
    unique (clinica_id, provider, id_externo_provider)
);

comment on table public.whatsapp_mensagens is
  'Mensagens de uma conversa, independente de provider. V1.1: tabela existe e está pronta para leitura, mas nada grava nela ainda (nenhum GRANT de insert) — nasce e fica vazia até a V1.2 (webhook/RPC de envio).';
comment on column public.whatsapp_mensagens.provider is
  'Rastreabilidade apenas — de qual provider esta mensagem específica veio/foi enviada. Nunca usado por lógica central (Follow-up, Kanban, etc.), só pela camada de provider e por auditoria.';
comment on column public.whatsapp_mensagens.id_externo_provider is
  'ID da mensagem no provider (ex.: message id da Evolution/Meta) — referência de rastreabilidade e chave de idempotência, nunca o identificador interno real (esse é sempre o uuid da coluna id).';

-- Mensagens por conversa, ordenadas cronologicamente (e já filtráveis
-- por clínica na mesma consulta — cobre RLS + ordenação numa só).
create index whatsapp_mensagens_clinica_conversa_idx
  on public.whatsapp_mensagens (clinica_id, conversa_id, enviada_em);

alter table public.whatsapp_mensagens enable row level security;

create policy "select_whatsapp_mensagens" on public.whatsapp_mensagens
  for select to authenticated
  using (clinica_id in (select public.minhas_clinicas()));

-- Sem policy de insert/update/delete — propositalmente (ver cabeçalho):
-- "Evitar escrita direta desnecessária... não criar arquitetura onde
-- qualquer usuário autenticado possa inserir arbitrariamente mensagens
-- como se fossem recebidas do WhatsApp." Sem GRANT de insert, isso é
-- estruturalmente impossível, não só desencorajado.

revoke all on public.whatsapp_mensagens from public, anon;
grant select on public.whatsapp_mensagens to authenticated;
-- Deliberadamente SEM insert, SEM update, SEM delete nesta fase.

-- ------------------------------------------------------------
-- 4) Trigger — mantém ultima_mensagem_paciente_em/clinica_em em
--    whatsapp_conversas a cada INSERT em whatsapp_mensagens. SECURITY
--    DEFINER para já funcionar independente de qual mecanismo futuro
--    (service_role do backend, ou uma RPC SECURITY DEFINER própria)
--    acabar fazendo o insert — só toca as duas colunas de timestamp da
--    própria conversa referenciada pela mensagem, nunca lê/escreve nada
--    fora desse escopo, então não abre nenhum caminho novo de escrita
--    para outra clínica ou outra linha.
-- ------------------------------------------------------------
create or replace function public.whatsapp_mensagens_atualizar_conversa()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.autor = 'paciente' then
    update public.whatsapp_conversas
      set ultima_mensagem_paciente_em = greatest(coalesce(ultima_mensagem_paciente_em, '-infinity'::timestamptz), new.enviada_em),
          updated_at = now()
      where id = new.conversa_id and clinica_id = new.clinica_id;
  elsif new.autor = 'clinica' then
    update public.whatsapp_conversas
      set ultima_mensagem_clinica_em = greatest(coalesce(ultima_mensagem_clinica_em, '-infinity'::timestamptz), new.enviada_em),
          updated_at = now()
      where id = new.conversa_id and clinica_id = new.clinica_id;
  end if;
  return new;
end;
$$;

comment on function public.whatsapp_mensagens_atualizar_conversa() is
  'Mantém whatsapp_conversas.ultima_mensagem_paciente_em/clinica_em sincronizadas a cada mensagem inserida — cada direção escreve só a própria coluna (sem comparação cruzada, sem condição de corrida). Usa greatest() para ficar correta mesmo com mensagens entregues fora de ordem (reentrega de webhook).';

create trigger trg_whatsapp_mensagens_atualizar_conversa
  after insert on public.whatsapp_mensagens
  for each row execute function public.whatsapp_mensagens_atualizar_conversa();

-- ------------------------------------------------------------
-- 5) Realtime — habilita a publicação (aditivo, inofensivo, nada emite
--    enquanto nada for inserido). Subscription no frontend fica para a
--    V1.2 — ver decisão de modelagem (7) no cabeçalho e o relatório
--    desta rodada para o plano técnico completo.
-- ------------------------------------------------------------
alter publication supabase_realtime add table public.whatsapp_conversas;
alter publication supabase_realtime add table public.whatsapp_mensagens;

commit;

-- ============================================================
-- ROTEIRO DE VERIFICAÇÃO (rodar manualmente no SQL Editor, usando
-- EXCLUSIVAMENTE registros QA — nunca paciente/conversa real).
-- ============================================================

-- ---- 0) Confirmar que as 3 tabelas nascem vazias ----
select count(*) as deve_ser_zero from public.whatsapp_instancias;
select count(*) as deve_ser_zero from public.whatsapp_conversas;
select count(*) as deve_ser_zero from public.whatsapp_mensagens;

-- ---- 1) Confirmar grants (authenticated só com select; anon sem nada) ----
select table_name, grantee, privilege_type
from information_schema.role_table_grants
where table_schema = 'public'
  and table_name in ('whatsapp_instancias', 'whatsapp_conversas', 'whatsapp_mensagens')
order by table_name, grantee, privilege_type;
-- Esperado: só linhas com grantee='authenticated' e privilege_type='SELECT'.

-- ---- 2) Teste de idempotência (SAVEPOINT + rollback, não deixa rastro) ----
-- begin;
-- savepoint teste_idempotencia;
-- insert into public.whatsapp_conversas (clinica_id, telefone_e164)
--   values ('<clinica-qa>', '+5531999990000') returning id \gset conv_
-- insert into public.whatsapp_mensagens (clinica_id, conversa_id, autor, status_envio, provider, id_externo_provider)
--   values ('<clinica-qa>', :'conv_id', 'paciente', 'recebida', 'evolution', 'ext-123');
-- -- Repetir o mesmo id_externo_provider deve falhar (unique violation):
-- insert into public.whatsapp_mensagens (clinica_id, conversa_id, autor, status_envio, provider, id_externo_provider)
--   values ('<clinica-qa>', :'conv_id', 'paciente', 'recebida', 'evolution', 'ext-123');
-- rollback to savepoint teste_idempotencia;
-- commit;
