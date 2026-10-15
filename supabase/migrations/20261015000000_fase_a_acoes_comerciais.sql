-- ============================================================
-- Fase A — Ações Comerciais reais (Resgate / Follow-up de Plano /
-- Pós-Consulta) + rename pos_venda -> pos_consulta
-- ------------------------------------------------------------
-- NÃO EXECUTAR ainda — aguardando o operador rodar manualmente no SQL
-- Editor do projeto Supabase da Mori Ortodontia (rynlzkdqxbzwcznufnpn).
-- Esta sessão não tem credenciais de banco para aplicar automaticamente.
--
-- Nenhuma alteração destrutiva: o rename abaixo primeiro faz UPDATE dos
-- dados existentes (se houver) e só depois troca a constraint — nenhuma
-- linha é apagada, nenhum paciente é tocado.
-- ============================================================

begin;

-- 1) Rename do valor do enum: pos_venda -> pos_consulta, sem perda.
--    Primeiro atualiza eventuais linhas existentes, depois troca a
--    constraint de CHECK. O nome real da constraint é descoberto
--    dinamicamente (nunca assumido às cegas).
update public.acoes_comerciais set tipo = 'pos_consulta' where tipo = 'pos_venda';

do $$
declare
  v_nome_constraint text;
begin
  select conname into v_nome_constraint
  from pg_constraint
  where conrelid = 'public.acoes_comerciais'::regclass
    and contype = 'c'
    and pg_get_constraintdef(oid) ilike '%tipo%';
  if v_nome_constraint is not null then
    execute format('alter table public.acoes_comerciais drop constraint %I', v_nome_constraint);
  end if;
end $$;

alter table public.acoes_comerciais
  add constraint acoes_comerciais_tipo_check
  check (tipo in ('pos_consulta', 'followup_plano', 'resgate'));

-- 2) RPC concluir_acao_comercial() — única forma de gravar uma conclusão.
--    SECURITY INVOKER (não DEFINER): roda com o papel e RLS de quem
--    chama — isolamento_acoes_comerciais já existente (for all, scoped
--    por clinica_id in minhas_clinicas()) continua sendo a autoridade
--    real; esta função só deriva clinica_id/usuario_id/data_elegivel no
--    servidor (nunca aceitos do navegador) e trata idempotência.
--
--    data_elegivel = "primeira data em que a ação está elegível"
--    (data-âncora + N dias), NUNCA a data-âncora em si:
--      resgate        -> data_perda (ou fallback legado) + 30 dias
--      followup_plano -> data_envio_plano (ou fallback legado) + 1 dia
--      pos_consulta   -> data_consulta + 1 dia
--    O fallback legado (quando o campo real ainda não existe, caso dos
--    79 pacientes migrados e de pacientes de teste criados antes da Fase
--    C introduzir o campo real de data_envio_plano) replica EXATAMENTE
--    obterDataPerdaComFallbackLegado()/obterDataEnvioPlanoComFallbackLegado()
--    do index.html — as duas implementações (SQL aqui, JS lá) precisam
--    ficar em sincronia, senão o "já concluído?" calculado no frontend
--    nunca bateria com o data_elegivel gravado de verdade aqui.
--    Idempotência: ON CONFLICT DO NOTHING na unique constraint já
--    existente (clinica_id, paciente_id, tipo, data_elegivel) — um
--    segundo clique/chamada repetida só devolve a linha já gravada, sem
--    erro.
create or replace function public.concluir_acao_comercial(
  p_paciente_id uuid,
  p_tipo text,
  p_observacao text default null
)
returns public.acoes_comerciais
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_profile_id uuid;
  v_clinica_id uuid;
  v_paciente public.pacientes%rowtype;
  v_data_perda_efetiva date;
  v_data_envio_efetiva date;
  v_data_elegivel date;
  v_resultado public.acoes_comerciais;
begin
  if p_tipo not in ('resgate', 'followup_plano', 'pos_consulta') then
    raise exception 'Tipo de ação comercial inválido: %', p_tipo;
  end if;

  select id, clinica_id into v_profile_id, v_clinica_id
    from public.profiles
    where auth_user_id = auth.uid() and ativo = true
    limit 1;

  if v_profile_id is null then
    raise exception 'Perfil ativo não encontrado para o usuário autenticado.';
  end if;

  select * into v_paciente from public.pacientes where id = p_paciente_id;

  if v_paciente.id is null then
    raise exception 'Paciente não encontrado ou sem permissão de acesso.';
  end if;

  if p_tipo = 'resgate' then
    -- fallback legado: data_fechamento || data_consulta || data_contato
    v_data_perda_efetiva := coalesce(v_paciente.data_perda, v_paciente.data_fechamento, v_paciente.data_consulta, v_paciente.data_contato);
    if v_data_perda_efetiva is null then
      raise exception 'Este paciente não tem data de perda (nem fallback) registrada — resgate não aplicável.';
    end if;
    v_data_elegivel := v_data_perda_efetiva + 30;
  elsif p_tipo = 'followup_plano' then
    -- fallback legado: data_consulta || data_contato
    v_data_envio_efetiva := coalesce(v_paciente.data_envio_plano, v_paciente.data_consulta, v_paciente.data_contato);
    if v_data_envio_efetiva is null then
      raise exception 'Este paciente não tem data de apresentação do plano (nem fallback) registrada — follow-up não aplicável.';
    end if;
    v_data_elegivel := v_data_envio_efetiva + 1;
  else -- pos_consulta
    if v_paciente.data_consulta is null then
      raise exception 'Este paciente não tem data de consulta registrada — pós-consulta não aplicável.';
    end if;
    v_data_elegivel := v_paciente.data_consulta + 1;
  end if;

  if current_date < v_data_elegivel then
    raise exception 'Esta ação ainda não está disponível (elegível somente a partir de %).', v_data_elegivel;
  end if;

  insert into public.acoes_comerciais (clinica_id, paciente_id, tipo, data_elegivel, usuario_id, observacao)
  values (v_clinica_id, p_paciente_id, p_tipo, v_data_elegivel, v_profile_id, nullif(btrim(p_observacao), ''))
  on conflict (clinica_id, paciente_id, tipo, data_elegivel) do nothing;

  select * into v_resultado
    from public.acoes_comerciais
    where clinica_id = v_clinica_id
      and paciente_id = p_paciente_id
      and tipo = p_tipo
      and data_elegivel = v_data_elegivel;

  return v_resultado;
end;
$$;

revoke all on function public.concluir_acao_comercial(uuid, text, text) from public;
revoke execute on function public.concluir_acao_comercial(uuid, text, text) from anon;
grant execute on function public.concluir_acao_comercial(uuid, text, text) to authenticated;

commit;

-- ============================================================
-- ROTEIRO DE VERIFICAÇÃO E TESTES REAIS (rodar manualmente no SQL
-- Editor, usando EXCLUSIVAMENTE os registros QA já existentes).
-- Ajustar <UID_VITOR> para o auth.uid() real do Vitor.
-- ============================================================

-- ---- Confirmar a constraint renomeada ----
select conname, pg_get_constraintdef(oid)
from pg_constraint
where conrelid = 'public.acoes_comerciais'::regclass and contype = 'c';
-- Esperado: a definição lista ('pos_consulta', 'followup_plano', 'resgate').

-- ---- Confirmar a função e os grants ----
select proname, pg_get_function_identity_arguments(oid)
from pg_proc where pronamespace = 'public'::regnamespace and proname = 'concluir_acao_comercial';

select has_function_privilege('authenticated', oid, 'execute') as authenticated_pode,
       has_function_privilege('anon', oid, 'execute') as anon_pode,
       has_function_privilege('public', oid, 'execute') as public_pode
from pg_proc where pronamespace = 'public'::regnamespace and proname = 'concluir_acao_comercial';
-- Esperado: authenticated_pode = true, anon_pode = false, public_pode = false.

-- ---- Testes reais com os registros QA (NUNCA com paciente real) ----
set local role authenticated;
set local request.jwt.claims = '{"sub":"<UID_VITOR>","role":"authenticated"}';

-- QA KANBAN TESTE (bc6df513-6216-4987-99f8-f7fe01442cba) — se este
-- paciente estiver em Perdido com data_perda há menos de 30 dias, a
-- chamada abaixo deve FALHAR com a mensagem de "ainda não disponível".
select * from public.concluir_acao_comercial(
  p_paciente_id := 'bc6df513-6216-4987-99f8-f7fe01442cba',
  p_tipo := 'resgate'
);

-- Duplo clique / idempotência: repetir a MESMA chamada que teve sucesso
-- acima não deve gerar erro, nem segunda linha.
select count(*) from public.acoes_comerciais
  where paciente_id = 'bc6df513-6216-4987-99f8-f7fe01442cba' and tipo = 'resgate';
-- Esperado: no máximo 1, mesmo chamando a RPC duas vezes.

reset role;
