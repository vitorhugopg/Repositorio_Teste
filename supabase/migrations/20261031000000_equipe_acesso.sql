-- ============================================================
-- Equipe — Gestão de Acesso (convite, link, desativação, remoção)
-- ------------------------------------------------------------
-- NÃO EXECUTAR ainda — aguardando autorização explícita para rodar
-- manualmente no SQL Editor do projeto Supabase da Mori Ortodontia
-- (rynlzkdqxbzwcznufnpn). Esta sessão não tem credenciais de banco para
-- aplicar automaticamente.
--
-- ------------------------------------------------------------
-- Decisão de modelagem (por que só 3 colunas novas, nenhuma tabela nova)
-- ------------------------------------------------------------
-- O pedido distingue duas coisas que `profiles` hoje expressa só com
-- `ativo`+`role`+`auth_user_id`, de forma ambígua (ver auditoria no
-- relatório desta rodada — ex.: a Mariana, que JAMAIS recebeu um
-- convite, já cairia como "pendente" pela heurística antiga só por já
-- ter `role='admin'` pré-configurado):
--
--   1) MEMBRO DA EQUIPE (emprego) — já existe, é `profiles.ativo`.
--      Não é redefinido aqui. Continua controlando quem aparece como
--      "Responsável" em novos registros e quem conta para as funções de
--      RLS abaixo. "Remover da equipe" usa exatamente este campo
--      (`ativo=false`), exatamente como qualquer outro "desativar" já
--      homologado no projeto (procedimentos/origens/motivos).
--
--   2) ACESSO AO CRM (login) — NOVO, explícito, independente de (1):
--      `status_acesso` ('pendente' | 'ativo' | 'desativado' | NULL).
--      NULL = nunca convidado (ou convite cancelado — depois de
--      cancelar, o estado volta a ser indistinguível de "nunca
--      convidado", exatamente como o pedido descreve: "o administrador
--      poderá convidar novamente no futuro").
--      Por quê separado de `ativo`: uma pessoa pode ser membro da
--      equipe sem NUNCA ter acesso (Thamiris sem login) — e um usuário
--      pode ter o ACESSO desativado (ex.: afastamento) sem deixar de
--      ser um membro válido para fins de "Responsável" (ver pedido,
--      item 5: são conceitos diferentes). Misturar os dois em `ativo`
--      geraria exatamente a ambiguidade que o pedido pede para evitar
--      (item 12).
--
--   `email` — texto simples, só para ter ONDE guardar o e-mail de
--   acesso ANTES de existir um auth_user_id (profiles não tinha
--   nenhuma coluna de e-mail). Não é uma segunda fonte de verdade do
--   e-mail de login — é sempre o mesmo e-mail passado para o
--   Supabase Auth (Edge Function), guardado aqui só para exibição/
--   reenvio pela interface.
--
--   `convite_auth_user_id` — o auth.users.id criado pela Edge Function
--   no momento do convite (admin.inviteUserByEmail já cria o usuário
--   Auth de verdade, mesmo antes da pessoa definir senha). Fica
--   SEPARADO de `auth_user_id` propositalmente: `auth_user_id` só é
--   preenchido quando a PRÓPRIA pessoa conclui a criação de senha
--   (ver Edge Function, ação complete_invite) — nunca no momento do
--   convite. Isso faz a RLS (minhas_clinicas/sou_admin_da_clinica)
--   continuar retornando ZERO linhas para quem está "pendente", mesmo
--   que a pessoa já tenha uma sessão válida (criada ao abrir o link de
--   convite, antes mesmo de definir senha) — sem precisar de nenhuma
--   lógica extra de RLS para isso: basta `auth_user_id` ainda ser NULL.
--
-- ------------------------------------------------------------
-- Por que ALTERAR minhas_clinicas()/sou_admin_da_clinica()
-- ------------------------------------------------------------
-- As duas funções SECURITY DEFINER já existentes são o único portão de
-- RLS usado em TODO o projeto (pacientes, procedimentos, profiles,
-- recorrência, indicações, whatsapp...). Hoje checam só `ativo=true`.
-- "Desativar acesso" (sem remover da equipe) PRECISA continuar
-- bloqueando a RLS mesmo com `ativo=true` preservado — por isso o
-- `and status_acesso = 'ativo'` entra como uma condição ADICIONAL (uma
-- pessoa só passa a RLS se for membro da equipe E tiver acesso ativo).
--
-- Risco óbvio: todo profile HOJE já ativo/logado (ex.: Vitor) tem
-- `status_acesso` NULL antes desta migration — sem o backfill abaixo,
-- o próprio Vitor perderia acesso imediatamente. O backfill marca como
-- 'ativo' exatamente quem já tem `auth_user_id` preenchido (login real
-- já funcionando hoje) — não é uma alteração de dado de negócio, é o
-- equivalente a popular uma coluna nova para preservar o comportamento
-- atual (mesmo espírito do profiles_role_nullable, mas na direção
-- inversa: aqui precisamos POPULAR para não quebrar, não afrouxar).
--
-- ------------------------------------------------------------
-- Unicidade (pedido item 8: "impedir que um mesmo usuário Auth seja
-- vinculado incorretamente a múltiplos profiles")
-- ------------------------------------------------------------
-- auth_user_id e convite_auth_user_id nunca tinham constraint de
-- unicidade. Índices parciais (ignoram NULL) — nunca houve, até onde
-- esta sessão conseguiu auditar, mais de um profile com o mesmo
-- auth_user_id, mas a migration falha alto e claro no CREATE UNIQUE
-- INDEX se isso já existir — rode a query de verificação no roteiro
-- abaixo ANTES de aplicar, e resolva manualmente qualquer duplicidade
-- encontrada antes de prosseguir.
-- ============================================================

begin;

alter table public.profiles
  add column if not exists email text null,
  add column if not exists status_acesso text null,
  add column if not exists convite_auth_user_id uuid null;

alter table public.profiles
  add constraint profiles_status_acesso_check
  check (status_acesso is null or status_acesso in ('pendente', 'ativo', 'desativado'));

comment on column public.profiles.email is
  'E-mail de acesso ao CRM (mesmo e-mail usado no Supabase Auth). Guardado aqui só para exibição/reenvio pela interface — nunca uma segunda fonte de verdade.';
comment on column public.profiles.status_acesso is
  'Situação do ACESSO ao CRM (login), independente de `ativo` (situação de EMPREGO/equipe). NULL = nunca convidado ou convite cancelado. Ver cabeçalho desta migration para a justificativa completa.';
comment on column public.profiles.convite_auth_user_id is
  'auth.users.id criado pela Edge Function no momento do convite — só vira `auth_user_id` quando a própria pessoa conclui a criação de senha (ação complete_invite). Nunca usado por RLS.';

-- Backfill: preserva o acesso de quem já está logando hoje.
update public.profiles
  set status_acesso = 'ativo'
  where auth_user_id is not null and status_acesso is null;

-- Unicidade (item 8 do pedido) — nunca existia.
create unique index if not exists profiles_auth_user_id_uniq
  on public.profiles (auth_user_id) where auth_user_id is not null;
create unique index if not exists profiles_convite_auth_user_id_uniq
  on public.profiles (convite_auth_user_id) where convite_auth_user_id is not null;

-- Portão de RLS: ativo (equipe) E status_acesso='ativo' (login ativo).
-- CREATE OR REPLACE preserva GRANTs/REVOKEs já aplicados nestas funções.
create or replace function public.minhas_clinicas()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select clinica_id
  from public.profiles
  where auth_user_id = auth.uid()
    and ativo = true
    and status_acesso = 'ativo';
$$;

create or replace function public.sou_admin_da_clinica(p_clinica_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.profiles
    where auth_user_id = auth.uid()
      and clinica_id = p_clinica_id
      and role = 'admin'
      and ativo = true
      and status_acesso = 'ativo'
  );
$$;

commit;

-- ============================================================
-- ROTEIRO DE VERIFICAÇÃO (rodar manualmente no SQL Editor)
-- ============================================================

-- ---- 0) ANTES de aplicar — confirmar que não há duplicidade que vá
--         quebrar os índices únicos (deve retornar 0 linhas nas duas):
-- select auth_user_id, count(*) from public.profiles
--   where auth_user_id is not null group by auth_user_id having count(*) > 1;
-- select convite_auth_user_id, count(*) from public.profiles
--   where convite_auth_user_id is not null group by convite_auth_user_id having count(*) > 1;

-- ---- 1) Depois de aplicar — confirma que ninguém hoje ativo perdeu acesso.
-- select id, nome, auth_user_id, ativo, status_acesso from public.profiles
--   where auth_user_id is not null;
-- Esperado: todas as linhas com status_acesso = 'ativo'.

-- ---- 2) Login do Vitor continua funcionando (teste real, não aqui).

-- ---- 3) Confirma a constraint.
-- insert into public.profiles (clinica_id, nome, status_acesso) values (
--   (select id from public.clinicas limit 1), 'QA status inválido', 'xyz'
-- );
-- Esperado: erro de check constraint (profiles_status_acesso_check).

-- ---- 4) Confirma os índices únicos.
-- select indexname from pg_indexes where tablename = 'profiles'
--   and indexname in ('profiles_auth_user_id_uniq', 'profiles_convite_auth_user_id_uniq');
-- Esperado: as duas linhas.
