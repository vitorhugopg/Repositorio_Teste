-- ============================================================
-- CRM Mori Ortodontia — Schema PostgreSQL/Supabase
-- Migration inicial — schema aprovado (arquitetura multi-tenant via
-- clinica_id, RLS, FKs compostas, calc_status(), minhas_clinicas()).
--
-- Esta migration é a ÚNICA fonte de verdade reproduzível do schema.
-- Pode ser aplicada do zero em qualquer projeto Supabase vazio.
--
-- NÃO insere nenhum dado de negócio (nenhuma clínica, paciente ou
-- indicação real). A migração dos 52 pacientes / 37 indicações da
-- Mori Ortodontia é uma etapa separada, posterior a esta.
-- ============================================================

create extension if not exists pgcrypto;

-- ============================================================
-- 1) CLINICAS
-- ============================================================
create table public.clinicas (
  id uuid primary key default gen_random_uuid(),
  nome text not null,
  cidade text,
  tempo_mercado text,
  especialidades text[] default '{}',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ============================================================
-- 2) PROFILES
-- ============================================================
create table public.profiles (
  id uuid primary key default gen_random_uuid(),
  clinica_id uuid not null references public.clinicas(id),
  auth_user_id uuid references auth.users(id),
  nome text not null,
  cargo text,
  role text not null default 'secretaria'
    check (role in ('admin','dentista','secretaria')),
  ativo boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (clinica_id, id),
  unique (clinica_id, auth_user_id)
);
create index idx_profiles_clinica on public.profiles(clinica_id);

-- ============================================================
-- 3) PROCEDIMENTOS
-- ============================================================
create table public.procedimentos (
  id uuid primary key default gen_random_uuid(),
  clinica_id uuid not null references public.clinicas(id),
  nome text not null,
  valor_medio numeric(12,2) default 0,
  ativo boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (clinica_id, nome),
  unique (clinica_id, id)
);
create index idx_procedimentos_clinica on public.procedimentos(clinica_id);

-- ============================================================
-- 4) ORIGENS_LEAD
-- ============================================================
create table public.origens_lead (
  id uuid primary key default gen_random_uuid(),
  clinica_id uuid not null references public.clinicas(id),
  nome text not null,
  ativo boolean not null default true,
  created_at timestamptz not null default now(),
  unique (clinica_id, nome),
  unique (clinica_id, id)
);
create index idx_origens_clinica on public.origens_lead(clinica_id);

-- ============================================================
-- 5) MOTIVOS_PERDA
-- ============================================================
create table public.motivos_perda (
  id uuid primary key default gen_random_uuid(),
  clinica_id uuid not null references public.clinicas(id),
  nome text not null,
  ativo boolean not null default true,
  created_at timestamptz not null default now(),
  unique (clinica_id, nome),
  unique (clinica_id, id)
);
create index idx_motivos_clinica on public.motivos_perda(clinica_id);

-- ============================================================
-- 6) ETAPAS_FUNIL
-- ============================================================
create table public.etapas_funil (
  id uuid primary key default gen_random_uuid(),
  clinica_id uuid not null references public.clinicas(id),
  chave text not null,
  nome text not null,
  cor text not null default '#5c6c70',
  ordem smallint not null,
  created_at timestamptz not null default now(),
  unique (clinica_id, chave)
);
create index idx_etapas_clinica on public.etapas_funil(clinica_id);

-- ============================================================
-- 7) PACIENTES (coração do sistema)
-- ============================================================
create table public.pacientes (
  id uuid primary key default gen_random_uuid(),
  clinica_id uuid not null references public.clinicas(id),
  nome text not null,
  telefone_original text,
  telefone_e164 text,
  email text,
  origem_id uuid,
  procedimento_original text,
  responsavel_id uuid,
  data_contato date,
  marcou_consulta text check (marcou_consulta in ('Sim','Não')),
  data_consulta date,
  compareceu text check (compareceu in ('Sim','Não')),
  fez_radiografia text check (fez_radiografia in ('Sim','Não')),
  plano_tratamento text check (plano_tratamento in ('Sim','Não')),
  data_envio_plano date,
  valor_orcamento numeric(12,2),
  fechou_tratamento text check (fechou_tratamento in ('Sim','Parcial','Pendente','Não precisa no momento','Não')),
  valor_fechado numeric(12,2),
  data_fechamento date,
  data_perda date,
  motivo_perda_id uuid,
  observacoes text,
  legacy_id text,
  created_by uuid,
  updated_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (clinica_id, id),
  unique (clinica_id, legacy_id),
  foreign key (clinica_id, origem_id) references public.origens_lead (clinica_id, id),
  foreign key (clinica_id, motivo_perda_id) references public.motivos_perda (clinica_id, id),
  foreign key (clinica_id, responsavel_id) references public.profiles (clinica_id, id),
  foreign key (clinica_id, created_by) references public.profiles (clinica_id, id),
  foreign key (clinica_id, updated_by) references public.profiles (clinica_id, id)
);
create index idx_pacientes_clinica on public.pacientes(clinica_id);
create index idx_pacientes_responsavel on public.pacientes(responsavel_id);
create index idx_pacientes_origem on public.pacientes(origem_id);
create index idx_pacientes_data_contato on public.pacientes(data_contato);
create index idx_pacientes_nome on public.pacientes(clinica_id, nome);

-- ============================================================
-- 8) PACIENTE_PROCEDIMENTOS
-- ============================================================
create table public.paciente_procedimentos (
  paciente_id uuid not null,
  procedimento_id uuid not null,
  clinica_id uuid not null,
  created_at timestamptz not null default now(),
  primary key (paciente_id, procedimento_id),
  foreign key (clinica_id, paciente_id) references public.pacientes (clinica_id, id) on delete cascade,
  foreign key (clinica_id, procedimento_id) references public.procedimentos (clinica_id, id)
);
create index idx_pp_procedimento on public.paciente_procedimentos(procedimento_id);
create index idx_pp_clinica on public.paciente_procedimentos(clinica_id);

-- ============================================================
-- 9) INDICACOES
-- ============================================================
create table public.indicacoes (
  id uuid primary key default gen_random_uuid(),
  clinica_id uuid not null references public.clinicas(id),
  paciente_indicado_id uuid not null,
  indicador_paciente_id uuid,
  indicador_nome_externo text,
  tipo_indicador text check (tipo_indicador in ('paciente','profissional','outro')),
  legacy_id text,
  created_at timestamptz not null default now(),
  check (num_nonnulls(indicador_paciente_id, indicador_nome_externo) <= 1),
  unique (clinica_id, legacy_id),
  foreign key (clinica_id, paciente_indicado_id) references public.pacientes (clinica_id, id),
  foreign key (clinica_id, indicador_paciente_id) references public.pacientes (clinica_id, id)
);
create index idx_indicacoes_clinica on public.indicacoes(clinica_id);
create index idx_indicacoes_paciente on public.indicacoes(paciente_indicado_id);

-- ============================================================
-- 10) FOLLOWUPS — histórico livre de contatos
-- ============================================================
create table public.followups (
  id uuid primary key default gen_random_uuid(),
  clinica_id uuid not null references public.clinicas(id),
  paciente_id uuid not null,
  usuario_id uuid,
  data timestamptz not null default now(),
  observacao text not null,
  proximo_contato date,
  created_at timestamptz not null default now(),
  foreign key (clinica_id, paciente_id) references public.pacientes (clinica_id, id) on delete cascade,
  foreign key (clinica_id, usuario_id) references public.profiles (clinica_id, id)
);
create index idx_followups_paciente on public.followups(paciente_id);
create index idx_followups_clinica on public.followups(clinica_id);

-- ============================================================
-- 11) ACOES_COMERCIAIS — histórico de ocorrências concluídas
--     (pós-venda / follow-up de plano / resgate). Toda linha aqui
--     significa "aconteceu" — não existe estado "pendente" gravado.
-- ============================================================
create table public.acoes_comerciais (
  id uuid primary key default gen_random_uuid(),
  clinica_id uuid not null references public.clinicas(id),
  paciente_id uuid not null,
  tipo text not null check (tipo in ('pos_venda','followup_plano','resgate')),
  data_elegivel date not null,
  usuario_id uuid,
  data_conclusao timestamptz not null default now(),
  observacao text,
  created_at timestamptz not null default now(),
  unique (clinica_id, paciente_id, tipo, data_elegivel),
  foreign key (clinica_id, paciente_id) references public.pacientes (clinica_id, id) on delete cascade,
  foreign key (clinica_id, usuario_id) references public.profiles (clinica_id, id)
);
create index idx_acoes_comerciais_clinica on public.acoes_comerciais(clinica_id);
create index idx_acoes_comerciais_tipo on public.acoes_comerciais(clinica_id, tipo);
create index idx_acoes_comerciais_paciente on public.acoes_comerciais(paciente_id);

-- ============================================================
-- 12) calc_status() — tradução mecânica de calcStatus() (index.html).
--     Fonte da verdade única. NÃO altera a regra de negócio.
-- ============================================================
create or replace function public.calc_status(
  p_fechou_tratamento text,
  p_plano_tratamento text,
  p_compareceu text,
  p_marcou_consulta text,
  p_nome text
) returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when p_fechou_tratamento = 'Sim' then 'Fechado (Total)'
    when p_fechou_tratamento = 'Parcial' then 'Fechado (Parcial)'
    when p_fechou_tratamento = 'Não' then 'Perdido'
    when p_fechou_tratamento = 'Pendente' then 'Pendente'
    when p_fechou_tratamento = 'Não precisa no momento' then 'Não Precisa no Momento'
    when p_plano_tratamento = 'Sim' then 'Plano de Tratamento'
    when p_compareceu = 'Não' then 'Não Compareceu'
    when p_compareceu = 'Sim' then 'Compareceu'
    when p_marcou_consulta = 'Não' then 'Perdido'
    when p_marcou_consulta = 'Sim' then 'Consulta Marcada'
    when p_nome is null or p_nome = '' then ''
    else 'Novo Paciente'
  end;
$$;

-- ============================================================
-- View com security_invoker = true: a RLS de "pacientes" é avaliada
-- como o usuário que consulta, nunca como o dono da view.
-- ============================================================
create view public.pacientes_com_status
with (security_invoker = true)
as
select p.*,
  public.calc_status(p.fechou_tratamento, p.plano_tratamento, p.compareceu, p.marcou_consulta, p.nome) as status
from public.pacientes p;

-- ============================================================
-- 13) minhas_clinicas() — helper de RLS, versão final endurecida:
--     SECURITY DEFINER + STABLE + search_path fixo vazio + referências
--     totalmente qualificadas. Não amplia responsabilidade: só
--     identifica as clínicas do usuário autenticado via profile ativo.
-- ============================================================
create or replace function public.minhas_clinicas()
returns setof uuid
language sql
security definer
stable
set search_path = ''
as $$
  select clinica_id
  from public.profiles
  where auth_user_id = auth.uid()
    and ativo = true;
$$;

revoke execute on function public.minhas_clinicas() from public;
grant execute on function public.minhas_clinicas() to authenticated;

-- ============================================================
-- 14) RLS — isolamento por clínica
-- ============================================================
alter table public.clinicas enable row level security;
create policy "ver_minha_clinica" on public.clinicas
  for select to authenticated
  using (id in (select public.minhas_clinicas()));

alter table public.profiles enable row level security;
create policy "ver_perfis_da_clinica" on public.profiles
  for select to authenticated
  using (clinica_id in (select public.minhas_clinicas()));
create policy "gerenciar_perfis_admin" on public.profiles
  for all to authenticated
  using (
    clinica_id in (select public.minhas_clinicas())
    and exists (select 1 from public.profiles me where me.auth_user_id = auth.uid() and me.clinica_id = profiles.clinica_id and me.role = 'admin')
  )
  with check (
    clinica_id in (select public.minhas_clinicas())
    and exists (select 1 from public.profiles me where me.auth_user_id = auth.uid() and me.clinica_id = profiles.clinica_id and me.role = 'admin')
  );

alter table public.procedimentos enable row level security;
create policy "isolamento_procedimentos" on public.procedimentos
  for all to authenticated
  using (clinica_id in (select public.minhas_clinicas()))
  with check (clinica_id in (select public.minhas_clinicas()));

alter table public.origens_lead enable row level security;
create policy "isolamento_origens" on public.origens_lead
  for all to authenticated
  using (clinica_id in (select public.minhas_clinicas()))
  with check (clinica_id in (select public.minhas_clinicas()));

alter table public.motivos_perda enable row level security;
create policy "isolamento_motivos" on public.motivos_perda
  for all to authenticated
  using (clinica_id in (select public.minhas_clinicas()))
  with check (clinica_id in (select public.minhas_clinicas()));

alter table public.etapas_funil enable row level security;
create policy "isolamento_etapas" on public.etapas_funil
  for all to authenticated
  using (clinica_id in (select public.minhas_clinicas()))
  with check (clinica_id in (select public.minhas_clinicas()));

alter table public.pacientes enable row level security;
create policy "isolamento_pacientes" on public.pacientes
  for all to authenticated
  using (clinica_id in (select public.minhas_clinicas()))
  with check (clinica_id in (select public.minhas_clinicas()));

alter table public.paciente_procedimentos enable row level security;
create policy "isolamento_paciente_procedimentos" on public.paciente_procedimentos
  for all to authenticated
  using (clinica_id in (select public.minhas_clinicas()))
  with check (clinica_id in (select public.minhas_clinicas()));

alter table public.indicacoes enable row level security;
create policy "isolamento_indicacoes" on public.indicacoes
  for all to authenticated
  using (clinica_id in (select public.minhas_clinicas()))
  with check (clinica_id in (select public.minhas_clinicas()));

alter table public.followups enable row level security;
create policy "isolamento_followups" on public.followups
  for all to authenticated
  using (clinica_id in (select public.minhas_clinicas()))
  with check (clinica_id in (select public.minhas_clinicas()));

alter table public.acoes_comerciais enable row level security;
create policy "isolamento_acoes_comerciais" on public.acoes_comerciais
  for all to authenticated
  using (clinica_id in (select public.minhas_clinicas()))
  with check (clinica_id in (select public.minhas_clinicas()));

-- Nenhuma policy concede nada ao papel "anon" — bloqueio total por padrão.
