-- ============================================================
-- RPCs atômicas de Cadastro/Edição de Paciente + Procedimentos
-- ------------------------------------------------------------
-- Objetivo: cadastro e edição de paciente + sincronização de
-- paciente_procedimentos como uma única operação transacional.
-- Se qualquer etapa falhar, toda a operação sofre rollback
-- automático (uma função plpgsql é uma única transação por
-- chamada — nenhum BEGIN/COMMIT manual é necessário).
--
-- SECURITY INVOKER (não DEFINER): as duas funções rodam com o
-- papel e o contexto RLS de quem chama. Não contornam a RLS —
-- apenas embrulham, em uma única transação, operações que o
-- usuário autenticado já poderia fazer direto (isolamento_pacientes
-- e isolamento_paciente_procedimentos, ambas já scoped por
-- clinica_id in minhas_clinicas()). clinica_id/created_by/updated_by
-- nunca são aceitos como parâmetro — são sempre derivados de
-- auth.uid() + profiles.
--
-- Ajustes incorporados (rodada de revisão aprovada):
-- 1) p_procedimento_ids é normalizado (sem NULL, sem duplicata)
--    DEPOIS de inserir/atualizar o paciente — isso é o que torna
--    possível testar rollback real: uma falha na validação/insert
--    dos vínculos desfaz também o paciente já gravado na mesma
--    transação.
-- 2) telefone_original/telefone_e164 vazios ou só espaço viram
--    NULL (nunca string vazia), direto na função.
--
-- NÃO EXECUTAR ainda — aguardando o operador rodar manualmente
-- no SQL Editor do projeto Supabase da Mori Ortodontia (esta
-- sessão não tem credenciais de banco para aplicar automaticamente).
-- ============================================================

begin;

create or replace function public.criar_paciente_com_procedimentos(
  p_nome text,
  p_telefone_original text default null,
  p_telefone_e164 text default null,
  p_email text default null,
  p_origem_id uuid default null,
  p_procedimento_original text default null,
  p_responsavel_id uuid default null,
  p_data_contato date default null,
  p_marcou_consulta text default null,
  p_data_consulta date default null,
  p_compareceu text default null,
  p_fez_radiografia text default null,
  p_plano_tratamento text default null,
  p_valor_orcamento numeric default null,
  p_fechou_tratamento text default null,
  p_valor_fechado numeric default null,
  p_data_fechamento date default null,
  p_motivo_perda_id uuid default null,
  p_observacoes text default null,
  p_procedimento_ids uuid[] default '{}'
)
returns public.pacientes_com_status
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_profile_id uuid;
  v_clinica_id uuid;
  v_status_depois text;
  v_data_perda date;
  v_paciente_id uuid;
  v_procedimento_ids uuid[];
  v_qtd_procedimentos_validos int;
  v_resultado public.pacientes_com_status;
begin
  if p_nome is null or btrim(p_nome) = '' then
    raise exception 'Nome do paciente é obrigatório.';
  end if;

  -- Ajuste 2: telefone vazio/whitespace vira NULL, nunca string vazia.
  p_telefone_original := nullif(btrim(p_telefone_original), '');
  p_telefone_e164 := nullif(btrim(p_telefone_e164), '');

  select id, clinica_id into v_profile_id, v_clinica_id
    from public.profiles
    where auth_user_id = auth.uid() and ativo = true
    limit 1;

  if v_profile_id is null then
    raise exception 'Perfil ativo não encontrado para o usuário autenticado.';
  end if;

  v_status_depois := public.calc_status(p_fechou_tratamento, p_plano_tratamento, p_compareceu, p_marcou_consulta, p_nome);
  v_data_perda := case when v_status_depois = 'Perdido' then current_date else null end;

  -- 1) Insere o paciente primeiro.
  insert into public.pacientes (
    clinica_id, nome, telefone_original, telefone_e164, email,
    origem_id, procedimento_original, responsavel_id,
    data_contato, marcou_consulta, data_consulta, compareceu,
    fez_radiografia, plano_tratamento, valor_orcamento,
    fechou_tratamento, valor_fechado, data_fechamento,
    data_perda, motivo_perda_id, observacoes,
    created_by, updated_by
  ) values (
    v_clinica_id, p_nome, p_telefone_original, p_telefone_e164, p_email,
    p_origem_id, p_procedimento_original, p_responsavel_id,
    p_data_contato, p_marcou_consulta, p_data_consulta, p_compareceu,
    p_fez_radiografia, p_plano_tratamento, p_valor_orcamento,
    p_fechou_tratamento, p_valor_fechado, p_data_fechamento,
    v_data_perda, p_motivo_perda_id, p_observacoes,
    v_profile_id, v_profile_id
  )
  returning id into v_paciente_id;

  -- Ajuste 1: normaliza (sem NULL, sem duplicata) só depois do insert do paciente.
  select coalesce(array_agg(distinct pid), '{}') into v_procedimento_ids
    from unnest(p_procedimento_ids) as pid
    where pid is not null;

  -- 2) Valida e insere os vínculos. Se falhar aqui, o paciente já inserido
  --    acima é desfeito junto (rollback automático da função inteira).
  if array_length(v_procedimento_ids, 1) > 0 then
    select count(*) into v_qtd_procedimentos_validos
      from public.procedimentos pr
      where pr.clinica_id = v_clinica_id and pr.id = any(v_procedimento_ids);
    if v_qtd_procedimentos_validos <> array_length(v_procedimento_ids, 1) then
      raise exception 'Um ou mais procedimentos selecionados não pertencem a esta clínica.';
    end if;

    insert into public.paciente_procedimentos (paciente_id, procedimento_id, clinica_id)
    select v_paciente_id, pid, v_clinica_id from unnest(v_procedimento_ids) as pid;
  end if;

  select * into v_resultado from public.pacientes_com_status where id = v_paciente_id;
  return v_resultado;
end;
$$;

revoke all on function public.criar_paciente_com_procedimentos(
  text, text, text, text, uuid, text, uuid, date, text, date, text, text, text, numeric, text, numeric, date, uuid, text, uuid[]
) from public;
revoke execute on function public.criar_paciente_com_procedimentos(
  text, text, text, text, uuid, text, uuid, date, text, date, text, text, text, numeric, text, numeric, date, uuid, text, uuid[]
) from anon;
grant execute on function public.criar_paciente_com_procedimentos(
  text, text, text, text, uuid, text, uuid, date, text, date, text, text, text, numeric, text, numeric, date, uuid, text, uuid[]
) to authenticated;


create or replace function public.atualizar_paciente_com_procedimentos(
  p_paciente_id uuid,
  p_nome text,
  p_telefone_original text default null,
  p_telefone_e164 text default null,
  p_email text default null,
  p_origem_id uuid default null,
  p_procedimento_original text default null,
  p_responsavel_id uuid default null,
  p_data_contato date default null,
  p_marcou_consulta text default null,
  p_data_consulta date default null,
  p_compareceu text default null,
  p_fez_radiografia text default null,
  p_plano_tratamento text default null,
  p_valor_orcamento numeric default null,
  p_fechou_tratamento text default null,
  p_valor_fechado numeric default null,
  p_data_fechamento date default null,
  p_motivo_perda_id uuid default null,
  p_observacoes text default null,
  p_procedimento_ids uuid[] default '{}'
)
returns public.pacientes_com_status
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_profile_id uuid;
  v_clinica_id uuid;
  v_antigo public.pacientes%rowtype;
  v_status_antes text;
  v_status_depois text;
  v_data_perda date;
  v_procedimento_ids uuid[];
  v_qtd_procedimentos_validos int;
  v_ids_atuais uuid[];
  v_ids_remover uuid[];
  v_ids_adicionar uuid[];
  v_resultado public.pacientes_com_status;
begin
  if p_nome is null or btrim(p_nome) = '' then
    raise exception 'Nome do paciente é obrigatório.';
  end if;

  -- Ajuste 2: telefone vazio/whitespace vira NULL, nunca string vazia.
  p_telefone_original := nullif(btrim(p_telefone_original), '');
  p_telefone_e164 := nullif(btrim(p_telefone_e164), '');

  select id, clinica_id into v_profile_id, v_clinica_id
    from public.profiles
    where auth_user_id = auth.uid() and ativo = true
    limit 1;

  if v_profile_id is null then
    raise exception 'Perfil ativo não encontrado para o usuário autenticado.';
  end if;

  select * into v_antigo from public.pacientes where id = p_paciente_id;

  if v_antigo.id is null then
    raise exception 'Paciente não encontrado ou sem permissão de acesso.';
  end if;

  v_status_antes := public.calc_status(v_antigo.fechou_tratamento, v_antigo.plano_tratamento, v_antigo.compareceu, v_antigo.marcou_consulta, v_antigo.nome);
  v_status_depois := public.calc_status(p_fechou_tratamento, p_plano_tratamento, p_compareceu, p_marcou_consulta, p_nome);

  v_data_perda := v_antigo.data_perda;
  if v_status_depois = 'Perdido' and v_status_antes <> 'Perdido' then
    v_data_perda := current_date;
  elsif v_status_antes = 'Perdido' and v_status_depois <> 'Perdido' then
    v_data_perda := null;
  end if;

  -- 1) Atualiza o paciente primeiro.
  update public.pacientes set
    nome = p_nome,
    telefone_original = p_telefone_original,
    telefone_e164 = p_telefone_e164,
    email = p_email,
    origem_id = p_origem_id,
    procedimento_original = p_procedimento_original,
    responsavel_id = p_responsavel_id,
    data_contato = p_data_contato,
    marcou_consulta = p_marcou_consulta,
    data_consulta = p_data_consulta,
    compareceu = p_compareceu,
    fez_radiografia = p_fez_radiografia,
    plano_tratamento = p_plano_tratamento,
    valor_orcamento = p_valor_orcamento,
    fechou_tratamento = p_fechou_tratamento,
    valor_fechado = p_valor_fechado,
    data_fechamento = p_data_fechamento,
    data_perda = v_data_perda,
    motivo_perda_id = p_motivo_perda_id,
    observacoes = p_observacoes,
    updated_by = v_profile_id,
    updated_at = now()
  where id = p_paciente_id;

  if not found then
    raise exception 'Paciente não encontrado ou sem permissão de atualização.';
  end if;

  -- Ajuste 1: normaliza (sem NULL, sem duplicata) só depois do update do paciente.
  select coalesce(array_agg(distinct pid), '{}') into v_procedimento_ids
    from unnest(p_procedimento_ids) as pid
    where pid is not null;

  -- 2) Valida e sincroniza os vínculos. Se falhar aqui, o UPDATE acima
  --    também é desfeito (rollback automático da função inteira).
  if array_length(v_procedimento_ids, 1) > 0 then
    select count(*) into v_qtd_procedimentos_validos
      from public.procedimentos pr
      where pr.clinica_id = v_clinica_id and pr.id = any(v_procedimento_ids);
    if v_qtd_procedimentos_validos <> array_length(v_procedimento_ids, 1) then
      raise exception 'Um ou mais procedimentos selecionados não pertencem a esta clínica.';
    end if;
  end if;

  select coalesce(array_agg(procedimento_id), '{}') into v_ids_atuais
    from public.paciente_procedimentos where paciente_id = p_paciente_id;

  select coalesce(array_agg(x), '{}') into v_ids_remover
    from unnest(v_ids_atuais) as x
    where x <> all (v_procedimento_ids);

  select coalesce(array_agg(x), '{}') into v_ids_adicionar
    from unnest(v_procedimento_ids) as x
    where x <> all (v_ids_atuais);

  if array_length(v_ids_remover, 1) > 0 then
    delete from public.paciente_procedimentos
      where paciente_id = p_paciente_id and procedimento_id = any(v_ids_remover);
  end if;

  if array_length(v_ids_adicionar, 1) > 0 then
    insert into public.paciente_procedimentos (paciente_id, procedimento_id, clinica_id)
    select p_paciente_id, pid, v_clinica_id from unnest(v_ids_adicionar) as pid;
  end if;

  select * into v_resultado from public.pacientes_com_status where id = p_paciente_id;
  return v_resultado;
end;
$$;

revoke all on function public.atualizar_paciente_com_procedimentos(
  uuid, text, text, text, text, uuid, text, uuid, date, text, date, text, text, text, numeric, text, numeric, date, uuid, text, uuid[]
) from public;
revoke execute on function public.atualizar_paciente_com_procedimentos(
  uuid, text, text, text, text, uuid, text, uuid, date, text, date, text, text, text, numeric, text, numeric, date, uuid, text, uuid[]
) from anon;
grant execute on function public.atualizar_paciente_com_procedimentos(
  uuid, text, text, text, text, uuid, text, uuid, date, text, date, text, text, text, numeric, text, numeric, date, uuid, text, uuid[]
) to authenticated;

commit;

-- ============================================================
-- ROTEIRO DE VERIFICAÇÃO E TESTES REAIS (rodar manualmente no
-- SQL Editor do projeto Supabase da Mori, nesta ordem, colando
-- os resultados de volta para o Claude Code analisar).
--
-- Ajuste <UID_VITOR> para o auth.uid() real do Vitor (admin ativo)
-- e <PROCEDIMENTO_REAL_ID> para um id real de public.procedimentos
-- desta clínica antes de rodar.
-- ============================================================

-- ---- 3) Confirmar que as duas funções existem ----
select proname, pg_get_function_identity_arguments(oid) as argumentos
from pg_proc
where pronamespace = 'public'::regnamespace
  and proname in ('criar_paciente_com_procedimentos', 'atualizar_paciente_com_procedimentos');

-- ---- 4) Confirmar grants (authenticated sim, anon/public não) ----
select p.proname,
       has_function_privilege('authenticated', p.oid, 'execute') as authenticated_pode,
       has_function_privilege('anon', p.oid, 'execute') as anon_pode,
       has_function_privilege('public', p.oid, 'execute') as public_pode
from pg_proc p
where p.pronamespace = 'public'::regnamespace
  and p.proname in ('criar_paciente_com_procedimentos', 'atualizar_paciente_com_procedimentos');
-- Esperado: authenticated_pode = true, anon_pode = false, public_pode = false.

-- ---- 5) Testes reais (simulando a sessão autenticada do Vitor) ----
set local role authenticated;
set local request.jwt.claims = '{"sub":"<UID_VITOR>","role":"authenticated"}';

-- 5a. Cadastro normal
select id, nome, status, data_perda, telefone_original, telefone_e164
from public.criar_paciente_com_procedimentos(
  p_nome := 'QA CADASTRO NORMAL - remover'
);

-- 5b. Procedimentos duplicados -> deve virar 1 vínculo só, sem erro
with novo as (
  select id from public.criar_paciente_com_procedimentos(
    p_nome := 'QA PROC DUPLICADO - remover',
    p_procedimento_ids := array['<PROCEDIMENTO_REAL_ID>'::uuid, '<PROCEDIMENTO_REAL_ID>'::uuid]
  )
)
select (select count(*) from public.paciente_procedimentos where paciente_id = (select id from novo)) as qtd_vinculos;
-- Esperado: 1

-- 5c. Telefone vazio/whitespace -> NULL, nunca string vazia
select telefone_original, telefone_e164
from public.criar_paciente_com_procedimentos(
  p_nome := 'QA TELEFONE VAZIO - remover',
  p_telefone_original := '   ',
  p_telefone_e164 := ''
);
-- Esperado: ambos NULL

-- 5d. Entrada em Perdido
select id, status, data_perda
from public.criar_paciente_com_procedimentos(
  p_nome := 'QA ENTRADA PERDIDO - remover',
  p_marcou_consulta := 'Não'
);
-- Esperado: status = 'Perdido', data_perda = hoje. Guardar o id retornado como <ID_QA_PERDIDO>.

-- 5e. Saída de Perdido (editar o paciente do teste anterior)
select id, status, data_perda
from public.atualizar_paciente_com_procedimentos(
  p_paciente_id := '<ID_QA_PERDIDO>',
  p_nome := 'QA ENTRADA PERDIDO - remover',
  p_marcou_consulta := 'Sim',
  p_data_consulta := current_date
);
-- Esperado: status != 'Perdido', data_perda = NULL.

-- 5f. data_envio_plano continua NULL mesmo com plano_tratamento = 'Sim'
select data_envio_plano
from public.criar_paciente_com_procedimentos(
  p_nome := 'QA SEM ENVIO PLANO - remover',
  p_plano_tratamento := 'Sim'
);
-- Esperado: NULL

-- 5g. Rollback atômico no CADASTRO
select count(*) from public.pacientes where nome = 'QA ATOMICIDADE CADASTRO - remover';
-- Esperado antes: 0
select * from public.criar_paciente_com_procedimentos(
  p_nome := 'QA ATOMICIDADE CADASTRO - remover',
  p_procedimento_ids := array['<PROCEDIMENTO_REAL_ID>'::uuid, gen_random_uuid()]
);
-- Esperado: erro "Um ou mais procedimentos selecionados não pertencem a esta clínica."
select count(*) from public.pacientes where nome = 'QA ATOMICIDADE CADASTRO - remover';
-- Esperado depois: 0 (prova que o INSERT foi desfeito)

-- 5h. Rollback atômico na EDIÇÃO
select id, observacoes
from public.criar_paciente_com_procedimentos(
  p_nome := 'QA ATOMICIDADE EDICAO - remover',
  p_observacoes := 'estado original'
);
-- Guardar o id retornado como <ID_QA_EDICAO>.
select * from public.atualizar_paciente_com_procedimentos(
  p_paciente_id := '<ID_QA_EDICAO>',
  p_nome := 'QA ATOMICIDADE EDICAO - remover',
  p_observacoes := 'ALTERACAO QUE NAO DEVE PERSISTIR',
  p_procedimento_ids := array[gen_random_uuid()]
);
-- Esperado: erro.
select observacoes from public.pacientes where id = '<ID_QA_EDICAO>';
-- Esperado: 'estado original' (prova que o UPDATE foi desfeito)

reset role;

-- ---- 6) Confirmar que DELETE físico continua bloqueado para authenticated ----
set local role authenticated;
set local request.jwt.claims = '{"sub":"<UID_VITOR>","role":"authenticated"}';
delete from public.pacientes where nome = 'QA CADASTRO NORMAL - remover';
-- Esperado: erro de permissão (RLS nega DELETE) ou "0 rows affected" sem erro,
-- nunca uma exclusão de verdade. Confirmar com o select abaixo.
select count(*) from public.pacientes where nome = 'QA CADASTRO NORMAL - remover';
-- Esperado: ainda 1 (não foi excluído)
reset role;

-- ---- 7) Limpeza dos registros QA (contexto administrativo — fora de
--         "authenticated" simulado, roda como dono/service do projeto) ----
delete from public.paciente_procedimentos
  where paciente_id in (select id from public.pacientes where nome ilike 'QA %');
delete from public.pacientes where nome ilike 'QA %';

-- ---- 8) Confirmações finais ----
select count(*) as total_pacientes from public.pacientes;
-- Esperado: 79

select count(*) as total_qa_restante from public.pacientes where nome ilike 'QA %';
-- Esperado: 0

select count(*) as vinculos_qa_restantes
from public.paciente_procedimentos pp
join public.pacientes p on p.id = pp.paciente_id
where p.nome ilike 'QA %';
-- Esperado: 0
