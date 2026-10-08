-- ============================================================
-- Fix: recursão infinita na RLS de public.profiles (Postgres 42P17)
-- ------------------------------------------------------------
-- Causa raiz: a policy "gerenciar_perfis_admin" é FOR ALL (cobre SELECT
-- também) e consulta `profiles` diretamente dentro do seu próprio
-- USING/WITH CHECK (`exists (select 1 from profiles me where ...)`).
-- Toda leitura de profiles precisa avaliar essa policy; para avaliá-la,
-- o Postgres roda essa subconsulta, que é OUTRA leitura de profiles,
-- que precisa avaliar a mesma policy de novo — recursão infinita.
--
-- Correção: mover a checagem "sou admin desta clínica?" para uma função
-- SECURITY DEFINER (mesmo padrão de minhas_clinicas()), que lê profiles
-- com os privilégios do dono da função — sem reavaliar a RLS de
-- profiles, logo sem recursão.
--
-- NÃO EXECUTAR ainda — aguardando aprovação.
-- ============================================================

begin;

create or replace function public.sou_admin_da_clinica(p_clinica_id uuid)
returns boolean
language sql
security definer
stable
set search_path = ''
as $$
  select exists (
    select 1
    from public.profiles
    where auth_user_id = auth.uid()
      and clinica_id = p_clinica_id
      and role = 'admin'
      and ativo = true
  );
$$;

revoke execute on function public.sou_admin_da_clinica(uuid) from public;
grant execute on function public.sou_admin_da_clinica(uuid) to authenticated;

drop policy if exists "gerenciar_perfis_admin" on public.profiles;

create policy "gerenciar_perfis_admin" on public.profiles
  for all to authenticated
  using (
    clinica_id in (select public.minhas_clinicas())
    and public.sou_admin_da_clinica(clinica_id)
  )
  with check (
    clinica_id in (select public.minhas_clinicas())
    and public.sou_admin_da_clinica(clinica_id)
  );

commit;

-- ============================================================
-- TESTES DE VALIDAÇÃO PÓS-MIGRATION (rodar no SQL Editor, como dono do
-- projeto — simula a sessão autenticada via request.jwt.claims, sem
-- precisar de senha de ninguém).
-- ============================================================

-- Teste 1 — a consulta que antes retornava 42P17 agora funciona para o
-- Vitor (admin da Mori). Esperado: exatamente 1 linha, sem erro.
-- set local role authenticated;
-- set local request.jwt.claims = '{"sub":"<uid-do-vitor>","role":"authenticated"}';
-- select id, clinica_id, nome, role, ativo from public.profiles
--   where auth_user_id = '<uid-do-vitor>' and ativo = true;
-- reset role;

-- Teste 2 — admin ainda consegue gerenciar (UPDATE) um profile da
-- própria clínica. Esperado: 1 linha afetada, sem erro.
-- set local role authenticated;
-- set local request.jwt.claims = '{"sub":"<uid-do-vitor>","role":"authenticated"}';
-- update public.profiles set cargo = cargo where id = '<id-de-um-profile-da-mori>';
-- reset role;

-- Teste 3 — um profile não-admin da mesma clínica continua conseguindo
-- SELECT (via ver_perfis_da_clinica, que não foi tocada) mas não deveria
-- conseguir UPDATE em outro profile. Esperado: SELECT ok, UPDATE 0 linhas
-- ou erro de permissão.
-- set local role authenticated;
-- set local request.jwt.claims = '{"sub":"<uid-de-um-profile-nao-admin>","role":"authenticated"}';
-- select id, nome, role from public.profiles; -- deve ver os profiles da própria clínica
-- update public.profiles set cargo = cargo where id = '<id-de-outro-profile>'; -- deve falhar/0 linhas
-- reset role;

-- Teste 4 — anon continua sem nenhum acesso. Esperado: 0 linhas.
-- set local role anon;
-- select * from public.profiles;
-- reset role;

-- Teste 5 — confirma que nenhuma outra policy do projeto tem o mesmo
-- padrão de auto-referência. Esperado: 0 linhas após a migration.
select schemaname, tablename, policyname, qual, with_check
from pg_policies
where schemaname = 'public'
  and (qual ilike '%from profiles%' or with_check ilike '%from profiles%' or qual ilike '%from public.profiles%' or with_check ilike '%from public.profiles%');

-- Teste 6 — repetir a consulta real que o frontend faz (via console do
-- navegador, já logado) e confirmar que não retorna mais HTTP 500 / 42P17.
