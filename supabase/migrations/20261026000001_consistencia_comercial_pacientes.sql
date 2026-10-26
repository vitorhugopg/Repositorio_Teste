-- ============================================================
-- Fase C2.1 + C2.2 — Coerência comercial (fechou_tratamento x
-- valor_fechado x data_fechamento x motivo_perda_id x data_perda)
-- ------------------------------------------------------------
-- NÃO EXECUTAR ainda — aguardando autorização explícita para rodar
-- manualmente no SQL Editor do projeto Supabase da Mori Ortodontia
-- (rynlzkdqxbzwcznufnpn). Esta sessão não tem credenciais de banco para
-- aplicar automaticamente.
--
-- Escopo: SOMENTE normalização/validação server-side em
-- `criar_paciente_com_procedimentos` e `atualizar_paciente_com_procedimentos`,
-- baseada no STATUS CALCULADO (nunca só em fechou_tratamento — calc_status()
-- também produz 'Perdido' via marcou_consulta='Não'). Nenhuma outra
-- tabela, RLS, grant, constraint ou RPC é tocada. Nenhum UPDATE em massa
-- nos 13 Perdidos sem data_perda, nos 5 Perdidos sem motivo, no Pendente
-- com motivo residual, nem nos Fechados incompletos — nenhum dado
-- histórico é alterado por esta migration.
--
-- ------------------------------------------------------------
-- Auditoria das assinaturas REAIS atuais (pós-C1, homologada)
-- ------------------------------------------------------------
-- As duas funções têm HOJE exatamente as assinaturas definidas em
-- 20261026000000_data_envio_plano.sql (a C1, já homologada no Supabase
-- real):
--   criar_paciente_com_procedimentos: 26 parâmetros (20 originais + 5 de
--     Recorrência + p_data_envio_plano no final).
--   atualizar_paciente_com_procedimentos: 22 parâmetros (20 originais +
--     p_data_envio_plano no final).
-- Esta migration NÃO adiciona nenhum parâmetro novo — só altera a lógica
-- interna de validação/normalização. Por isso aqui é `CREATE OR REPLACE`,
-- não DROP+CREATE: a lista de tipos de parâmetro permanece idêntica à da
-- C1, e o Postgres só exige DROP+CREATE quando o número/tipo de
-- parâmetros muda (foi exatamente o caso da C1, que acrescentou
-- p_data_envio_plano — não é o caso aqui). `CREATE OR REPLACE` também
-- preserva os grants existentes automaticamente (o DROP+CREATE da C1
-- precisou reafirmar REVOKE/GRANT depois; aqui não seria estritamente
-- necessário, mas mantemos a reafirmação por consistência e auditabilidade).
--
-- ------------------------------------------------------------
-- Regra central (reafirmando o que foi pedido): a coerência é decidida
-- pelo STATUS CALCULADO (`public.calc_status(...)`, a mesma função SQL já
-- usada por `pacientes_com_status` e já chamada dentro destas duas RPCs
-- para a lógica de data_perda) — nunca só pelo valor cru de
-- fechou_tratamento. Isso preserva integralmente o caso
-- marcou_consulta='Não' (Perdido mesmo com fechou_tratamento NULL).
--
-- Fechado (Total) ou Fechado (Parcial):
--   valor_fechado e data_fechamento OBRIGATÓRIOS (rejeita se algum vier
--   NULL) — persistidos exatamente como enviados.
--   motivo_perda_id e data_perda SEMPRE NULL (data_perda já era NULL
--   nestes dois status pela lógica existente, preservada sem alteração).
-- Perdido:
--   motivo_perda_id OBRIGATÓRIO (rejeita se vier NULL).
--   data_perda: gerida pela lógica JÁ EXISTENTE, preservada sem nenhuma
--   alteração (ver abaixo) — nunca um campo manual.
--   valor_fechado e data_fechamento SEMPRE NULL.
-- Qualquer outro status (Pendente, Não Precisa no Momento, Novo
-- Paciente, Consulta Marcada, Não Compareceu, Compareceu, Plano de
-- Tratamento, '' ):
--   os quatro campos SEMPRE NULL — nenhuma decisão comercial ainda.
--
-- ------------------------------------------------------------
-- data_perda — ZERO alteração de comportamento (reconfirmado, não só
-- reaproveitado)
-- ------------------------------------------------------------
-- Criação: v_data_perda := current_date SE o status calculado já nasce
-- 'Perdido', senão NULL — EXATAMENTE a mesma linha da C1/versão original.
-- Edição: v_data_perda começa como v_antigo.data_perda (preserva o que já
-- estava, inclusive NULL) e só é sobrescrita nas transições DE/PARA
-- Perdido — a mesma linha da C1/versão original. Isso já cobre
-- corretamente o caso pedido explicitamente (item 3/Teste L): um
-- paciente que ERA Perdido com data_perda NULL e CONTINUA Perdido não
-- recebe current_date, porque nem a condição de entrada
-- (v_status_antes<>'Perdido') nem a de saída (v_status_depois<>'Perdido')
-- são verdadeiras — v_data_perda permanece o valor antigo (NULL). Não
-- precisei mudar nada aqui; só confirmei lendo a lógica já homologada.
--
-- ------------------------------------------------------------
-- concluir_acao_comercial / data_envio_plano / Recorrência / procedimentos
-- ------------------------------------------------------------
-- Nenhuma linha tocada. O corpo das duas funções abaixo é cópia exata da
-- versão da C1, com a ÚNICA adição sendo o bloco de normalização
-- descrito acima, inserido depois do cálculo de v_status_depois/
-- v_data_perda/v_data_envio_plano e antes do INSERT/UPDATE.
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
  p_procedimento_ids uuid[] default '{}',
  p_recorrente_inicial boolean default false,
  p_recorrencia_tipo_id uuid default null,
  p_recorrencia_data_inicio date default null,
  p_recorrencia_proximo_retorno date default null,
  p_recorrencia_responsavel_id uuid default null,
  p_data_envio_plano date default null
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
  v_data_envio_plano date;
  v_valor_fechado numeric;
  v_data_fechamento date;
  v_motivo_perda_id uuid;
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

  -- [Fase C1] data_envio_plano só existe quando plano_tratamento='Sim' —
  -- defesa em profundidade, nunca confia só no frontend (item 6/7).
  v_data_envio_plano := case when p_plano_tratamento = 'Sim' then p_data_envio_plano else null end;

  -- [Fase C2] Coerência comercial baseada no STATUS CALCULADO (nunca só
  -- em p_fechou_tratamento — v_status_depois já cobre o caminho
  -- marcou_consulta='Não' -> 'Perdido' corretamente).
  if v_status_depois in ('Fechado (Total)', 'Fechado (Parcial)') then
    if p_valor_fechado is null then
      raise exception 'Valor fechado é obrigatório quando o tratamento está marcado como fechado.';
    end if;
    if p_data_fechamento is null then
      raise exception 'Data de fechamento é obrigatória quando o tratamento está marcado como fechado.';
    end if;
    v_valor_fechado := p_valor_fechado;
    v_data_fechamento := p_data_fechamento;
    v_motivo_perda_id := null;
  elsif v_status_depois = 'Perdido' then
    if p_motivo_perda_id is null then
      raise exception 'Motivo da perda é obrigatório quando o paciente está marcado como perdido.';
    end if;
    v_motivo_perda_id := p_motivo_perda_id;
    v_valor_fechado := null;
    v_data_fechamento := null;
  else
    v_valor_fechado := null;
    v_data_fechamento := null;
    v_motivo_perda_id := null;
  end if;

  -- 1) Insere o paciente primeiro.
  insert into public.pacientes (
    clinica_id, nome, telefone_original, telefone_e164, email,
    origem_id, procedimento_original, responsavel_id,
    data_contato, marcou_consulta, data_consulta, compareceu,
    fez_radiografia, plano_tratamento, data_envio_plano, valor_orcamento,
    fechou_tratamento, valor_fechado, data_fechamento,
    data_perda, motivo_perda_id, observacoes,
    created_by, updated_by
  ) values (
    v_clinica_id, p_nome, p_telefone_original, p_telefone_e164, p_email,
    p_origem_id, p_procedimento_original, p_responsavel_id,
    p_data_contato, p_marcou_consulta, p_data_consulta, p_compareceu,
    p_fez_radiografia, p_plano_tratamento, v_data_envio_plano, p_valor_orcamento,
    p_fechou_tratamento, v_valor_fechado, v_data_fechamento,
    v_data_perda, v_motivo_perda_id, p_observacoes,
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

  -- 3) [Recorrência] preservado integralmente — nenhuma linha alterada.
  if p_recorrente_inicial then
    perform internal.iniciar_ciclo_recorrencia_core(
      v_clinica_id, v_profile_id, v_paciente_id, p_recorrencia_tipo_id,
      p_recorrencia_data_inicio, p_recorrencia_proximo_retorno,
      coalesce(p_recorrencia_responsavel_id, p_responsavel_id), null
    );
  end if;

  select * into v_resultado from public.pacientes_com_status where id = v_paciente_id;
  return v_resultado;
end;
$$;

revoke all on function public.criar_paciente_com_procedimentos(
  text, text, text, text, uuid, text, uuid, date, text, date, text, text, text, numeric, text, numeric, date, uuid, text, uuid[],
  boolean, uuid, date, date, uuid, date
) from public, anon;
grant execute on function public.criar_paciente_com_procedimentos(
  text, text, text, text, uuid, text, uuid, date, text, date, text, text, text, numeric, text, numeric, date, uuid, text, uuid[],
  boolean, uuid, date, date, uuid, date
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
  p_procedimento_ids uuid[] default '{}',
  p_data_envio_plano date default null
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
  v_data_envio_plano date;
  v_valor_fechado numeric;
  v_data_fechamento date;
  v_motivo_perda_id uuid;
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

  -- [data_perda] ZERO alteração de comportamento — preserva o valor
  -- antigo (inclusive NULL) e só sobrescreve nas transições DE/PARA
  -- Perdido. Um paciente que ERA Perdido com data_perda NULL e CONTINUA
  -- Perdido não recebe current_date aqui (nem a condição de entrada nem
  -- a de saída é verdadeira) — exatamente a regra pedida no item 3/Teste L.
  v_data_perda := v_antigo.data_perda;
  if v_status_depois = 'Perdido' and v_status_antes <> 'Perdido' then
    v_data_perda := current_date;
  elsif v_status_antes = 'Perdido' and v_status_depois <> 'Perdido' then
    v_data_perda := null;
  end if;

  -- [Fase C1] data_envio_plano só existe quando plano_tratamento='Sim' —
  -- defesa em profundidade (item 7: Sim->Não deve limpar a data, inclusive
  -- se o cliente, por bug ou má-fé, mandasse os dois juntos).
  v_data_envio_plano := case when p_plano_tratamento = 'Sim' then p_data_envio_plano else null end;

  -- [Fase C2] Coerência comercial baseada no STATUS CALCULADO (v_status_depois
  -- já cobre marcou_consulta='Não' -> 'Perdido' corretamente). Sem
  -- carve-out para histórico: se este registro estava incoerente e está
  -- sendo editado agora, a nova regra passa a valer para este save
  -- (decisão explícita do pedido — nenhum UPDATE em massa é feito aqui,
  -- só a validação do save em curso).
  if v_status_depois in ('Fechado (Total)', 'Fechado (Parcial)') then
    if p_valor_fechado is null then
      raise exception 'Valor fechado é obrigatório quando o tratamento está marcado como fechado.';
    end if;
    if p_data_fechamento is null then
      raise exception 'Data de fechamento é obrigatória quando o tratamento está marcado como fechado.';
    end if;
    v_valor_fechado := p_valor_fechado;
    v_data_fechamento := p_data_fechamento;
    v_motivo_perda_id := null;
  elsif v_status_depois = 'Perdido' then
    if p_motivo_perda_id is null then
      raise exception 'Motivo da perda é obrigatório quando o paciente está marcado como perdido.';
    end if;
    v_motivo_perda_id := p_motivo_perda_id;
    v_valor_fechado := null;
    v_data_fechamento := null;
  else
    v_valor_fechado := null;
    v_data_fechamento := null;
    v_motivo_perda_id := null;
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
    data_envio_plano = v_data_envio_plano,
    valor_orcamento = p_valor_orcamento,
    fechou_tratamento = p_fechou_tratamento,
    valor_fechado = v_valor_fechado,
    data_fechamento = v_data_fechamento,
    data_perda = v_data_perda,
    motivo_perda_id = v_motivo_perda_id,
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
  uuid, text, text, text, text, uuid, text, uuid, date, text, date, text, text, text, numeric, text, numeric, date, uuid, text, uuid[], date
) from public, anon;
grant execute on function public.atualizar_paciente_com_procedimentos(
  uuid, text, text, text, text, uuid, text, uuid, date, text, date, text, text, text, numeric, text, numeric, date, uuid, text, uuid[], date
) to authenticated;

commit;

-- ============================================================
-- ROTEIRO DE VERIFICAÇÃO E TESTES REAIS (rodar manualmente no SQL
-- Editor, NESTA ORDEM, usando EXCLUSIVAMENTE registros QA — nunca
-- pacientes reais). Ajustar <UID_VITOR> para o auth.uid() real do Vitor
-- antes de rodar.
-- ============================================================

-- ---- 0) Confirmar que nenhum histórico foi tocado (contagens antes de
--         rodar esta migration devem ser comparadas com as de depois) ----
select count(*) as total_pacientes from public.pacientes
where clinica_id = '4f1d0862-3455-49c6-997b-c8e8f8d165ee';
select count(*) as perdidos_sem_data_perda from public.pacientes_com_status
where clinica_id = '4f1d0862-3455-49c6-997b-c8e8f8d165ee' and status = 'Perdido' and data_perda is null;
-- Esperado: os mesmos números de antes (migration não faz UPDATE em pacientes).

-- ---- 1) Confirmar assinaturas e grants (sem mudança de parâmetros) ----
select proname, pg_get_function_identity_arguments(oid) as argumentos,
       has_function_privilege('authenticated', oid, 'execute') as authenticated_pode,
       has_function_privilege('anon', oid, 'execute') as anon_pode
from pg_proc
where pronamespace = 'public'::regnamespace
  and proname in ('criar_paciente_com_procedimentos', 'atualizar_paciente_com_procedimentos');

set local role authenticated;
set local request.jwt.claims = '{"sub":"<UID_VITOR>","role":"authenticated"}';

-- ---- Teste A/B — Fechado Total sem valor/data: rejeitar ----
select * from public.criar_paciente_com_procedimentos(
  p_nome := 'QA C2 TESTE A - remover', p_fechou_tratamento := 'Sim'
);
-- Esperado: erro "Valor fechado é obrigatório..."
select * from public.criar_paciente_com_procedimentos(
  p_nome := 'QA C2 TESTE B - remover', p_fechou_tratamento := 'Sim', p_valor_fechado := 1000
);
-- Esperado: erro "Data de fechamento é obrigatória..."

-- ---- Teste C — Fechado Total com valor+data: salvar, motivo/perda NULL ----
select status, valor_fechado, data_fechamento, motivo_perda_id, data_perda
from public.criar_paciente_com_procedimentos(
  p_nome := 'QA C2 TESTE C - remover', p_fechou_tratamento := 'Sim',
  p_valor_fechado := 1000, p_data_fechamento := current_date
);

-- ---- Teste E/F — Perdido sem motivo (os dois caminhos): rejeitar ----
select * from public.criar_paciente_com_procedimentos(
  p_nome := 'QA C2 TESTE E - remover', p_fechou_tratamento := 'Não'
);
select * from public.criar_paciente_com_procedimentos(
  p_nome := 'QA C2 TESTE F - remover', p_marcou_consulta := 'Não'
);
-- Esperado (ambos): erro "Motivo da perda é obrigatório..."

-- ---- Teste G — mesmo cenário F, com motivo: salvar ----
select status, motivo_perda_id, data_perda, valor_fechado, data_fechamento
from public.criar_paciente_com_procedimentos(
  p_nome := 'QA C2 TESTE G - remover', p_marcou_consulta := 'Não',
  p_motivo_perda_id := (select id from public.motivos_perda where clinica_id = '4f1d0862-3455-49c6-997b-c8e8f8d165ee' limit 1)
);
-- Guardar o id retornado como <QA_G_ID>.

-- ---- Teste H — Perdido -> Pendente: limpa tudo ----
select status, motivo_perda_id, data_perda, valor_fechado, data_fechamento
from public.atualizar_paciente_com_procedimentos(
  p_paciente_id := '<QA_G_ID>', p_nome := 'QA C2 TESTE G - remover',
  p_fechou_tratamento := 'Pendente'
);

reset role;

-- ---- Limpeza ----
delete from public.pacientes where nome ilike 'QA C2 %';
select count(*) as deve_ser_zero from public.pacientes where nome ilike 'QA C2 %';
