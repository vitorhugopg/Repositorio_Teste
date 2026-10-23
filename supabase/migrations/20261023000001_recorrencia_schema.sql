-- ============================================================
-- Módulo de Recorrência de Pacientes — Schema (tabelas, constraints,
-- índices, RLS)
-- ------------------------------------------------------------
-- NÃO EXECUTAR ainda — aguardando o operador rodar manualmente no SQL
-- Editor do projeto Supabase da Mori Ortodontia (rynlzkdqxbzwcznufnpn),
-- NESTA ORDEM, depois de 20261023000000_clinicas_timezone.sql.
-- Esta sessão não tem credenciais de banco para aplicar automaticamente.
--
-- Escopo desta migration: SOMENTE tabelas + RLS desta camada. As RPCs
-- (iniciar/registrar/finalizar + extensão de criar_paciente_com_procedimentos)
-- estão em 20261023000002_recorrencia_rpcs.sql, que depende desta aqui.
-- Nenhuma alteração de frontend nesta rodada.
--
-- ------------------------------------------------------------
-- Padrão multi-tenant seguido (confirmado no schema real já em produção)
-- ------------------------------------------------------------
-- O banco já usa FKs COMPOSTAS (clinica_id, id) para proteger a
-- integridade multi-tenant — nunca uma FK simples que permitiria
-- vincular um registro de uma clínica a uma linha de outra. Exemplos
-- reais já confirmados: pacientes(clinica_id,responsavel_id) ->
-- profiles(clinica_id,id); pacientes(clinica_id,origem_id) ->
-- origens_lead(clinica_id,id); paciente_procedimentos(clinica_id,
-- paciente_id) -> pacientes(clinica_id,id); acoes_comerciais(clinica_id,
-- paciente_id) -> pacientes(clinica_id,id). Todas as FKs novas abaixo
-- seguem exatamente o mesmo padrão.
-- ============================================================

begin;

-- ------------------------------------------------------------
-- 1) tipos_recorrencia — lista configurável, mesmo padrão de
--    procedimentos / origens_lead / motivos_perda (select para a
--    clínica inteira, escrita só para admin, sem delete físico —
--    "desativar" via `ativo=false` é a única forma de remover).
-- ------------------------------------------------------------
create table public.tipos_recorrencia (
  id                        uuid primary key default gen_random_uuid(),
  clinica_id                uuid not null references public.clinicas(id),
  nome                      text not null,
  frequencia_sugerida_dias  integer null,
  ativo                     boolean not null default true,
  created_at                timestamptz not null default now(),

  -- Preparação para evolução futura (sugestão automática de frequência).
  -- Só aceita valores positivos quando preenchida; NÃO é utilizada por
  -- nenhuma lógica na V1 — a data do próximo retorno continua 100%
  -- manual, escolhida pela clínica.
  constraint tipos_recorrencia_frequencia_positiva
    check (frequencia_sugerida_dias is null or frequencia_sugerida_dias > 0),

  -- Suporta as FKs compostas de ciclos_recorrencia (clinica_id, tipo_recorrencia_id).
  constraint tipos_recorrencia_clinica_id_uniq unique (clinica_id, id),

  -- Mesmo padrão de "nome único por clínica" que procedimentos/
  -- origens_lead/motivos_perda já seguem.
  constraint tipos_recorrencia_nome_uniq unique (clinica_id, nome)
);

comment on table public.tipos_recorrencia is
  'Lista configurável de tipos de recorrência (Manutenção ortodôntica, Limpeza periódica, Acompanhamento, etc.), por clínica. Mesmo padrão de procedimentos/origens_lead/motivos_perda — gerenciada em Configurações, só por admin.';
comment on column public.tipos_recorrencia.frequencia_sugerida_dias is
  'Preparação para evolução futura (sugestão automática de frequência por tipo). NÃO utilizada por nenhuma lógica na V1.';

alter table public.tipos_recorrencia enable row level security;

create policy "ver_tipos_recorrencia_da_clinica" on public.tipos_recorrencia
  for select to authenticated
  using (clinica_id in (select public.minhas_clinicas()));

create policy "gerenciar_tipos_recorrencia_admin" on public.tipos_recorrencia
  for all to authenticated
  using (
    clinica_id in (select public.minhas_clinicas())
    and public.sou_admin_da_clinica(clinica_id)
  )
  with check (
    clinica_id in (select public.minhas_clinicas())
    and public.sou_admin_da_clinica(clinica_id)
  );

revoke all on public.tipos_recorrencia from public, anon;
grant select, insert, update on public.tipos_recorrencia to authenticated;
-- Sem grant de delete — igual procedimentos/origens_lead/motivos_perda.

-- ------------------------------------------------------------
-- 2) ciclos_recorrencia — 1 linha = 1 ciclo. Um paciente pode ter vários
--    ciclos ao longo do tempo (histórico), mas só 1 pode estar 'ativo'
--    simultaneamente (garantido por índice único parcial abaixo).
-- ------------------------------------------------------------
create table public.ciclos_recorrencia (
  id                     uuid primary key default gen_random_uuid(),
  clinica_id             uuid not null references public.clinicas(id),
  paciente_id            uuid not null,
  tipo_recorrencia_id    uuid not null,
  responsavel_id         uuid null,
  data_inicio            date not null,
  proximo_retorno        date not null,
  status                 text not null default 'ativo',
  data_encerramento      date null,
  motivo_encerramento    text null,
  observacoes            text null,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),
  created_by             uuid not null,
  updated_by             uuid not null,

  constraint ciclos_recorrencia_status_check
    check (status in ('ativo','finalizado')),

  -- Lista fixa de motivos de encerramento aprovada nesta rodada —
  -- NÃO é uma tabela configurável (decisão explícita, diferente de
  -- tipos_recorrencia).
  constraint ciclos_recorrencia_motivo_encerramento_check
    check (motivo_encerramento is null or motivo_encerramento in (
      'Tratamento concluído',
      'Paciente não continuará o tratamento',
      'Mudou de clínica/profissional',
      'Recorrência não é mais necessária',
      'Outro'
    )),

  -- Integridade entre status e os campos de encerramento: finalizado
  -- SEMPRE tem data+motivo; ativo NUNCA tem.
  constraint ciclos_recorrencia_encerramento_consistente
    check ((status = 'finalizado') = (data_encerramento is not null)),
  constraint ciclos_recorrencia_motivo_consistente
    check ((status = 'finalizado') = (motivo_encerramento is not null)),

  -- FKs COMPOSTAS (padrão multi-tenant real do projeto) — impossível
  -- vincular um ciclo da clínica A a um paciente/tipo/responsável da
  -- clínica B, porque clinica_id participa da própria FK, não só da
  -- RLS. responsavel_id/created_by/updated_by aceitam NULL em
  -- responsavel_id (paciente sem responsável definido) — MATCH SIMPLE
  -- (padrão do Postgres) permite a FK composta passar quando a coluna
  -- opcional é NULL, mesmo comportamento que pacientes.responsavel_id
  -- já tem hoje.
  constraint ciclos_recorrencia_paciente_fk
    foreign key (clinica_id, paciente_id) references public.pacientes (clinica_id, id),
  constraint ciclos_recorrencia_tipo_fk
    foreign key (clinica_id, tipo_recorrencia_id) references public.tipos_recorrencia (clinica_id, id),
  constraint ciclos_recorrencia_responsavel_fk
    foreign key (clinica_id, responsavel_id) references public.profiles (clinica_id, id),
  constraint ciclos_recorrencia_created_by_fk
    foreign key (clinica_id, created_by) references public.profiles (clinica_id, id),
  constraint ciclos_recorrencia_updated_by_fk
    foreign key (clinica_id, updated_by) references public.profiles (clinica_id, id),

  -- unique (clinica_id, id): padrão geral do projeto para qualquer FK
  -- composta futura que precise referenciar um ciclo inteiro.
  constraint ciclos_recorrencia_clinica_id_uniq unique (clinica_id, id),
  -- unique (clinica_id, id, paciente_id): suporta especificamente a FK
  -- tripla de retornos_recorrencia abaixo (garante clínica + ciclo +
  -- paciente consistentes numa única checagem).
  constraint ciclos_recorrencia_clinica_id_paciente_uniq unique (clinica_id, id, paciente_id)
);

comment on table public.ciclos_recorrencia is
  'Um ciclo de recorrência (ex: "Manutenção ortodôntica, retornos mensais"). Paciente pode ter vários ciclos ao longo do tempo (histórico); só 1 pode estar ativo por vez (ver índice único parcial). Nunca excluído fisicamente — encerramento é sempre lógico (status=finalizado).';
comment on column public.ciclos_recorrencia.responsavel_id is
  'Snapshot do responsável NO MOMENTO da criação do ciclo — independente de pacientes.responsavel_id. Uma mudança futura do responsável geral do paciente NUNCA altera retroativamente ciclos já existentes (preserva histórico e futuras métricas por profissional).';

create index ciclos_recorrencia_clinica_status_idx
  on public.ciclos_recorrencia (clinica_id, status);
create index ciclos_recorrencia_paciente_idx
  on public.ciclos_recorrencia (paciente_id);
create index ciclos_recorrencia_fila_idx
  on public.ciclos_recorrencia (clinica_id, status, proximo_retorno);

-- Regra de negócio protegida NO BANCO (não só na aplicação/RPC): só 1
-- ciclo ATIVO por paciente. Formato (clinica_id, paciente_id) — não
-- apenas (paciente_id) — para manter a arquitetura multi-tenant
-- explícita e consistente com o restante do schema, mesmo que
-- paciente_id já pertença a uma única clínica (garantido pela FK
-- composta acima).
create unique index ciclos_recorrencia_um_ativo_por_paciente
  on public.ciclos_recorrencia (clinica_id, paciente_id)
  where status = 'ativo';

alter table public.ciclos_recorrencia enable row level security;

-- SELECT/INSERT/UPDATE escopados por clínica, igual a toda tabela de
-- paciente já existente. Importante: isso NÃO substitui a validação de
-- negócio das RPCs (ex.: "só pode registrar retorno se o ciclo estiver
-- ativo") — a RLS garante isolamento entre clínicas; a RPC garante a
-- regra de negócio. São camadas complementares, não redundantes: uma
-- chamada direta à tabela (fora das RPCs) continuaria respeitando o
-- isolamento por clínica, mas não as regras de negócio — por isso as
-- RPCs são o caminho documentado e esperado para escrever nesta tabela.
create policy "select_ciclos_recorrencia" on public.ciclos_recorrencia
  for select to authenticated
  using (clinica_id in (select public.minhas_clinicas()));

create policy "insert_ciclos_recorrencia" on public.ciclos_recorrencia
  for insert to authenticated
  with check (clinica_id in (select public.minhas_clinicas()));

create policy "update_ciclos_recorrencia" on public.ciclos_recorrencia
  for update to authenticated
  using (clinica_id in (select public.minhas_clinicas()))
  with check (clinica_id in (select public.minhas_clinicas()));

-- Sem policy de DELETE — encerramento é sempre lógico (status='finalizado').

revoke all on public.ciclos_recorrencia from public, anon;
grant select, insert, update on public.ciclos_recorrencia to authenticated;
-- Sem grant de delete.

-- ------------------------------------------------------------
-- 3) retornos_recorrencia — histórico append-only de cada "Registrar
--    retorno" dentro de um ciclo. Nunca sobrescrito nem apagado.
-- ------------------------------------------------------------
create table public.retornos_recorrencia (
  id                          uuid primary key default gen_random_uuid(),
  clinica_id                  uuid not null references public.clinicas(id),
  ciclo_id                    uuid not null,
  paciente_id                 uuid not null,
  data_retorno_realizado      date not null,
  proximo_retorno_definido    date not null,
  observacao                  text null,
  usuario_id                  uuid not null,
  created_at                  timestamptz not null default now(),

  -- FK composta TRIPLA: clinica_id + ciclo_id + paciente_id precisam
  -- bater, todos de uma vez, com uma linha real de ciclos_recorrencia —
  -- torna estruturalmente impossível um retorno da clínica A referenciar
  -- um ciclo ou paciente da clínica B, e também impossível um retorno
  -- apontar para um paciente diferente do dono real do ciclo.
  constraint retornos_recorrencia_ciclo_fk
    foreign key (clinica_id, ciclo_id, paciente_id)
    references public.ciclos_recorrencia (clinica_id, id, paciente_id),

  constraint retornos_recorrencia_usuario_fk
    foreign key (clinica_id, usuario_id) references public.profiles (clinica_id, id)
);

comment on table public.retornos_recorrencia is
  'Histórico append-only de retornos realizados dentro de um ciclo de recorrência. Nunca UPDATE, nunca DELETE — cada "Registrar retorno" insere uma linha nova; o próximo retorno do ciclo é atualizado separadamente em ciclos_recorrencia.proximo_retorno.';

create index retornos_recorrencia_ciclo_idx on public.retornos_recorrencia (ciclo_id);
create index retornos_recorrencia_paciente_idx on public.retornos_recorrencia (paciente_id);
create index retornos_recorrencia_clinica_data_idx
  on public.retornos_recorrencia (clinica_id, data_retorno_realizado);

alter table public.retornos_recorrencia enable row level security;

create policy "select_retornos_recorrencia" on public.retornos_recorrencia
  for select to authenticated
  using (clinica_id in (select public.minhas_clinicas()));

create policy "insert_retornos_recorrencia" on public.retornos_recorrencia
  for insert to authenticated
  with check (clinica_id in (select public.minhas_clinicas()));

-- Sem policy de UPDATE, sem policy de DELETE — append-only garantido em
-- DUAS camadas independentes: nenhuma RLS permissiva para essas
-- operações E (abaixo) nenhum GRANT de UPDATE/DELETE também. Mesmo que
-- uma das duas camadas tivesse um erro de configuração no futuro, a
-- outra ainda bloquearia.

revoke all on public.retornos_recorrencia from public, anon;
grant select, insert on public.retornos_recorrencia to authenticated;
-- Deliberadamente SEM update, SEM delete.

commit;

-- ============================================================
-- ROTEIRO DE VERIFICAÇÃO ESTRUTURAL (rodar manualmente no SQL Editor,
-- logo após aplicar esta migration — testes funcionais/RPC ficam no
-- roteiro de 20261023000002_recorrencia_rpcs.sql, que depende disto)
-- ============================================================

-- ---- Confirmar as 3 tabelas e RLS habilitada ----
select relname, relrowsecurity
from pg_class
where relname in ('tipos_recorrencia','ciclos_recorrencia','retornos_recorrencia');
-- Esperado: relrowsecurity = true nas 3.

-- ---- Confirmar as policies ----
select tablename, policyname, cmd
from pg_policies
where schemaname='public'
  and tablename in ('tipos_recorrencia','ciclos_recorrencia','retornos_recorrencia')
order by tablename, cmd;
-- Esperado: nenhuma linha com cmd='DELETE' em nenhuma das 3 tabelas;
-- nenhuma linha com cmd='UPDATE' em retornos_recorrencia.

-- ---- Confirmar os índices (inclusive o único parcial) ----
select indexname, indexdef
from pg_indexes
where schemaname='public'
  and tablename in ('tipos_recorrencia','ciclos_recorrencia','retornos_recorrencia')
order by tablename, indexname;
-- Esperado: ciclos_recorrencia_um_ativo_por_paciente presente, com
-- "WHERE (status = 'ativo'::text)" na definição.

-- ---- Confirmar os grants (anon sem nada, authenticated sem delete) ----
select table_name, grantee, privilege_type
from information_schema.role_table_grants
where table_schema='public'
  and table_name in ('tipos_recorrencia','ciclos_recorrencia','retornos_recorrencia')
  and grantee in ('anon','authenticated')
order by table_name, grantee, privilege_type;
-- Esperado: nenhuma linha com grantee='anon'; authenticated sem DELETE
-- em nenhuma tabela, e sem UPDATE em retornos_recorrencia.
