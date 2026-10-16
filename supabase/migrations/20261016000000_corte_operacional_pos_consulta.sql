-- ============================================================
-- Corte operacional de Pós-Consulta (data_inicio_acoes_comerciais)
-- ------------------------------------------------------------
-- NÃO EXECUTAR ainda — aguardando o operador rodar manualmente no SQL
-- Editor do projeto Supabase da Mori Ortodontia (rynlzkdqxbzwcznufnpn).
-- Esta sessão não tem credenciais de banco para aplicar automaticamente.
--
-- Contexto: ao corrigir a fila de Pós-Consulta para considerar D+1 como
-- data de ELEGIBILIDADE (e não janela de 1 dia), 61 pacientes históricos
-- passaram a aparecer como pendentes — consultas anteriores à existência
-- do CRM não devem virar tarefa operacional retroativa.
--
-- Migration aditiva, não destrutiva: nova coluna nullable em `clinicas`
-- (nenhum dado existente é alterado) + 1 UPDATE pontual para a Mori +
-- CREATE OR REPLACE da RPC já existente (mesma assinatura, grants
-- preservados).
--
-- Escopo desta correção: SOMENTE Pós-Consulta. Resgate não muda nesta
-- rodada (decisão explícita — reativação de base antiga pode ser
-- comercialmente útil, análise de impacto fica para depois). Follow-up
-- de Plano também não muda nesta rodada (só Pós-Consulta está no escopo
-- aprovado); a orientação de produto é que fluxos futuros de Follow-up
-- também considerem esta mesma coluna, mas isso não foi implementado
-- agora — não generalizar automaticamente.
-- ============================================================

begin;

-- 1) Nova coluna em clinicas — nullable, sem default forçado: NULL
--    significa "esta clínica ainda não tem corte configurado", o que
--    mantém o comportamento IDÊNTICO ao que existia antes desta correção
--    (sem corte nenhum) até que a clínica seja configurada. Cada clínica
--    nova (futuro multi-tenant) deve receber seu próprio valor no
--    onboarding — não existe "data padrão" universal sensata.
alter table public.clinicas
  add column if not exists data_inicio_acoes_comerciais date;

comment on column public.clinicas.data_inicio_acoes_comerciais is
  'Data a partir da qual eventos desta clínica (ex: data_consulta) podem gerar novas pendências operacionais de ações comerciais. NULL = sem corte (compatibilidade retroativa). Configuração técnica nesta fase, sem edição pela interface.';

-- 2) Valor inicial da Mori Ortodontia (única clínica existente hoje).
update public.clinicas
  set data_inicio_acoes_comerciais = '2026-10-15'
  where id = '4f1d0862-3455-49c6-997b-c8e8f8d165ee'::uuid;

-- 3) Recria concluir_acao_comercial() — mesma assinatura (grants
--    preservados automaticamente pelo CREATE OR REPLACE), único trecho
--    novo é o corte dentro do branch pos_consulta. resgate/followup_plano
--    ficam byte-a-byte iguais à versão anterior.
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
  v_data_inicio_acoes date;
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
    v_data_perda_efetiva := coalesce(v_paciente.data_perda, v_paciente.data_fechamento, v_paciente.data_consulta, v_paciente.data_contato);
    if v_data_perda_efetiva is null then
      raise exception 'Este paciente não tem data de perda (nem fallback) registrada — resgate não aplicável.';
    end if;
    v_data_elegivel := v_data_perda_efetiva + 30;
  elsif p_tipo = 'followup_plano' then
    v_data_envio_efetiva := coalesce(v_paciente.data_envio_plano, v_paciente.data_consulta, v_paciente.data_contato);
    if v_data_envio_efetiva is null then
      raise exception 'Este paciente não tem data de apresentação do plano (nem fallback) registrada — follow-up não aplicável.';
    end if;
    v_data_elegivel := v_data_envio_efetiva + 1;
  else -- pos_consulta
    if v_paciente.data_consulta is null then
      raise exception 'Este paciente não tem data de consulta registrada — pós-consulta não aplicável.';
    end if;

    -- [Corte operacional — só pos_consulta nesta rodada] a UI já esconde
    -- a ação para consultas anteriores ao corte, mas a RPC precisa
    -- bloquear da mesma forma: nunca confiar só na UI. A data que importa
    -- é a do evento (data_consulta), não a data de hoje.
    select data_inicio_acoes_comerciais into v_data_inicio_acoes
      from public.clinicas where id = v_clinica_id;

    if v_data_inicio_acoes is not null and v_paciente.data_consulta < v_data_inicio_acoes then
      raise exception 'Esta consulta (%) é anterior ao início operacional das ações comerciais desta clínica (%) — pós-consulta não aplicável.', v_paciente.data_consulta, v_data_inicio_acoes;
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

-- Reafirma os grants explicitamente (CREATE OR REPLACE já preserva os
-- existentes já que a assinatura não mudou, mas deixamos explícito por
-- clareza e para o roteiro de verificação abaixo fazer sentido sozinho).
revoke all on function public.concluir_acao_comercial(uuid, text, text) from public;
revoke execute on function public.concluir_acao_comercial(uuid, text, text) from anon;
grant execute on function public.concluir_acao_comercial(uuid, text, text) to authenticated;

commit;

-- ============================================================
-- ROTEIRO DE VERIFICAÇÃO E TESTES REAIS (rodar manualmente no SQL
-- Editor). Ajustar <UID_VITOR> para o auth.uid() real do Vitor.
-- ============================================================

-- ---- Confirmar a coluna e o valor da Mori ----
select id, nome, data_inicio_acoes_comerciais from public.clinicas;
-- Esperado: Mori Ortodontia com data_inicio_acoes_comerciais = 2026-10-15.

-- ---- Confirmar quantos pacientes ficam pendentes de Pós-Consulta após o
--      corte (consultas >= 2026-10-15, compareceram, sem conclusão) ----
select count(*) from public.pacientes_com_status
where compareceu = 'Sim'
  and data_consulta >= '2026-10-15'
  and data_consulta is not null
  and current_date >= data_consulta + 1
  and not exists (
    select 1 from public.acoes_comerciais ac
    where ac.paciente_id = pacientes_com_status.id and ac.tipo = 'pos_consulta'
  );

-- ---- Confirmar que a RPC bloqueia consulta anterior ao corte, mesmo que
--      a UI (hipoteticamente) tentasse concluir mesmo assim ----
set local role authenticated;
set local request.jwt.claims = '{"sub":"<UID_VITOR>","role":"authenticated"}';

-- QA POS VENDA (consulta em 12/10/2026, antes do corte de 15/10) — esta
-- chamada DEVE FALHAR com a mensagem "anterior ao início operacional".
select * from public.concluir_acao_comercial(
  p_paciente_id := (select id from public.pacientes where nome = 'QA POS VENDA' limit 1),
  p_tipo := 'pos_consulta'
);

reset role;
