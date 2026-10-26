-- ============================================================
-- Fase C1 — data_envio_plano nas RPCs de paciente
-- ------------------------------------------------------------
-- NÃO EXECUTAR ainda — aguardando autorização explícita para rodar
-- manualmente no SQL Editor do projeto Supabase da Mori Ortodontia
-- (rynlzkdqxbzwcznufnpn). Esta sessão não tem credenciais de banco para
-- aplicar automaticamente.
--
-- Escopo desta migration: SOMENTE adicionar suporte a
-- `p_data_envio_plano` em `criar_paciente_com_procedimentos` e
-- `atualizar_paciente_com_procedimentos`, persistindo em
-- `pacientes.data_envio_plano`. Nenhuma outra coluna, tabela, RLS, grant
-- ou RPC é tocada. `concluir_acao_comercial` (Fase A) NÃO precisa de
-- nenhuma alteração — já implementa exatamente a regra aprovada para
-- Follow-up de Plano (ver seção 3 abaixo).
--
-- ------------------------------------------------------------
-- Auditoria das assinaturas REAIS atuais (antes de alterar qualquer
-- coisa — exatamente como pedido)
-- ------------------------------------------------------------
-- `criar_paciente_com_procedimentos` HOJE tem 25 parâmetros — não é mais
-- a versão de 20 parâmetros de 20261010000000_rpc_paciente_atomico.sql.
-- Ela foi substituída (DROP+CREATE) por 20261023000002_recorrencia_rpcs.sql,
-- que acrescentou 5 parâmetros opcionais de Recorrência no final:
--   p_recorrente_inicial boolean default false,
--   p_recorrencia_tipo_id uuid default null,
--   p_recorrencia_data_inicio date default null,
--   p_recorrencia_proximo_retorno date default null,
--   p_recorrencia_responsavel_id uuid default null
-- O corpo atual real (confirmado lendo 20261023000002_recorrencia_rpcs.sql,
-- não a versão antiga) já inclui o bloco de criação atômica do primeiro
-- ciclo de recorrência (`if p_recorrente_inicial then perform
-- internal.iniciar_ciclo_recorrencia_core(...)`) — esse bloco é
-- preservado abaixo exatamente como está, sem nenhuma alteração.
--
-- `atualizar_paciente_com_procedimentos` HOJE tem 21 parâmetros — a MESMA
-- assinatura e o MESMO corpo de 20261010000000_rpc_paciente_atomico.sql.
-- Confirmei (grep em todas as migrations por "atualizar_paciente_com_procedimentos")
-- que nenhuma migration posterior a alterou — a Recorrência deliberadamente
-- não a tocou (paciente existente usa iniciar_ciclo_recorrencia, isolada;
-- comentário explícito no final de 20261023000002_recorrencia_rpcs.sql).
--
-- Portanto: o DROP abaixo usa a lista de tipos EXATA de cada uma dessas
-- duas versões reais — não a versão original de 20 parâmetros de
-- criar_paciente_com_procedimentos, que não existe mais no banco.
--
-- ------------------------------------------------------------
-- Por que DROP + CREATE, não CREATE OR REPLACE (mesmo motivo já
-- documentado em 20261023000002_recorrencia_rpcs.sql)
-- ------------------------------------------------------------
-- Adicionar um novo parâmetro muda a assinatura da função, mesmo com
-- DEFAULT — CREATE OR REPLACE só substitui no lugar quando a lista de
-- tipos de parâmetro é EXATAMENTE a mesma; caso contrário cria uma
-- SEGUNDA função (overload) coexistindo com a antiga, o que o PostgREST
-- lida mal (erro "Could not choose the best candidate function"). Por
-- isso: DROP explícito da assinatura antiga + CREATE da nova, dentro da
-- mesma transação (sem janela de indisponibilidade).
--
-- O novo parâmetro é sempre acrescentado NO FINAL da lista (depois dos 5
-- de Recorrência, na criação; depois de p_procedimento_ids, na edição) —
-- nunca no meio — para não reordenar nenhum parâmetro já em uso por
-- quem já chama estas funções.
--
-- ------------------------------------------------------------
-- 1) Regra de consistência de data_envio_plano (item 6/7 do pedido)
-- ------------------------------------------------------------
-- `data_envio_plano` só pode valer algo quando `plano_tratamento = 'Sim'`.
-- Isso é garantido DENTRO da própria RPC (defesa em profundidade — nunca
-- confia só no frontend esconder/limpar o campo):
--   v_data_envio_plano := case when p_plano_tratamento = 'Sim'
--                               then p_data_envio_plano else null end;
-- Isso cobre os dois sentidos pedidos:
--   a) plano_tratamento != 'Sim' -> data_envio_plano é SEMPRE gravada como
--      NULL, mesmo que o parâmetro recebido não seja nulo (protege contra
--      um cliente malicioso/com bug enviando os dois juntos, e cobre a
--      regra do item 7: Sim->Não limpa a data, inclusive no servidor).
--   b) plano_tratamento = 'Sim' com p_data_envio_plano NULL -> permanece
--      NULL (nunca inventa uma data) — é exatamente o caso dos pacientes
--      históricos (item 3) e do paciente real já identificado com a data
--      preenchida (item 4): nenhum dos dois é alterado por esta migration,
--      porque esta migration não faz nenhum UPDATE/backfill em linha
--      nenhuma — só troca a definição das duas funções.
-- Nenhum CHECK/NOT NULL novo na tabela (item 6 — deliberado, para não
-- quebrar os registros históricos com plano_tratamento='Sim' e
-- data_envio_plano NULL que sabemos que existem).
--
-- ------------------------------------------------------------
-- 2) Lógica de data_perda — preservada INTEGRALMENTE, sem nenhuma
--    alteração de comportamento
-- ------------------------------------------------------------
-- As linhas de cálculo de v_status_depois/v_data_perda (criação) e
-- v_status_antes/v_status_depois/v_data_perda (edição) são copiadas
-- caractere por caractere das versões atuais — nenhuma reordenação,
-- nenhuma mudança de condição.
--
-- ------------------------------------------------------------
-- 3) concluir_acao_comercial (Fase A) — NENHUMA ALTERAÇÃO NECESSÁRIA
-- ------------------------------------------------------------
-- Auditei o corpo real de public.concluir_acao_comercial (migration
-- 20261015000000_fase_a_acoes_comerciais.sql). Para `followup_plano` ela
-- já faz exatamente:
--   v_data_envio_efetiva := coalesce(v_paciente.data_envio_plano,
--                                    v_paciente.data_consulta,
--                                    v_paciente.data_contato);
--   v_data_elegivel := v_data_envio_efetiva + 1;
-- Ou seja: já prioriza o campo real sobre o fallback (coalesce) e já
-- calcula o primeiro alerta como D+1 — exatamente a regra aprovada nesta
-- rodada (item 2/11/12 do pedido). A função já foi escrita antecipando
-- esta fase (comentário original: "Fase C vai garantir o mesmo para
-- data_envio_plano" — ela já garantia, só faltava a RPC de paciente
-- aceitar o campo, que é o que esta migration resolve). Nenhuma mudança
-- de segurança (continua security invoker), nenhuma mudança de RLS.
--
-- ------------------------------------------------------------
-- 4) Fora do escopo desta migration (preservado sem alteração)
-- ------------------------------------------------------------
-- Comportamento com NULL idêntico ao de hoje (UPDATE de todas as colunas
-- listadas, sempre). Validações existentes (nome obrigatório, telefone
-- vazio->NULL, procedimentos da própria clínica, paciente existente e
-- visível pela RLS) preservadas sem nenhuma mudança. Parâmetros de
-- Recorrência na criação preservados integralmente, na mesma posição.
-- Nenhuma função muda de SECURITY INVOKER para DEFINER. Nenhum grant
-- muda de verbo (authenticated continua só com EXECUTE; anon/public
-- continuam sem nenhum).
-- ============================================================

begin;

-- ------------------------------------------------------------
-- criar_paciente_com_procedimentos — DROP da assinatura REAL atual (25
-- parâmetros, já com os 5 de Recorrência) + CREATE com o 26º parâmetro
-- (p_data_envio_plano) acrescentado no final.
-- ------------------------------------------------------------
drop function if exists public.criar_paciente_com_procedimentos(
  text, text, text, text, uuid, text, uuid, date, text, date, text, text, text, numeric, text, numeric, date, uuid, text, uuid[],
  boolean, uuid, date, date, uuid
);

create function public.criar_paciente_com_procedimentos(
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
  -- [Recorrência] preservados integralmente, mesma posição, mesmo default.
  p_recorrente_inicial boolean default false,
  p_recorrencia_tipo_id uuid default null,
  p_recorrencia_data_inicio date default null,
  p_recorrencia_proximo_retorno date default null,
  p_recorrencia_responsavel_id uuid default null,
  -- [Fase C1] novo parâmetro, acrescentado no final, nunca no meio.
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

-- ------------------------------------------------------------
-- atualizar_paciente_com_procedimentos — DROP da assinatura REAL atual
-- (21 parâmetros, idêntica à original de 20261010000000) + CREATE com o
-- 22º parâmetro (p_data_envio_plano) acrescentado no final.
-- ------------------------------------------------------------
drop function if exists public.atualizar_paciente_com_procedimentos(
  uuid, text, text, text, text, uuid, text, uuid, date, text, date, text, text, text, numeric, text, numeric, date, uuid, text, uuid[]
);

create function public.atualizar_paciente_com_procedimentos(
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
  -- [Fase C1] novo parâmetro, acrescentado no final.
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

  -- [Fase C1] data_envio_plano só existe quando plano_tratamento='Sim' —
  -- defesa em profundidade (item 7: Sim->Não deve limpar a data, inclusive
  -- se o cliente, por bug ou má-fé, mandasse os dois juntos).
  v_data_envio_plano := case when p_plano_tratamento = 'Sim' then p_data_envio_plano else null end;

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

-- ---- 0) Confirmar que o paciente real já identificado na auditoria C0
--         com data_envio_plano preenchida continua intacto (nenhuma
--         UPDATE/backfill rodou nesta migration) ----
select count(*) as total_com_data_envio_plano_antes_e_depois
from public.pacientes
where clinica_id = '4f1d0862-3455-49c6-997b-c8e8f8d165ee' and data_envio_plano is not null;
-- Esperado: o mesmo número de antes de aplicar esta migration (rode esta
-- mesma query ANTES de aplicar, para comparar).

-- ---- 1) Confirmar as novas assinaturas e grants ----
select proname, pg_get_function_identity_arguments(oid) as argumentos,
       has_function_privilege('authenticated', oid, 'execute') as authenticated_pode,
       has_function_privilege('anon', oid, 'execute') as anon_pode
from pg_proc
where pronamespace = 'public'::regnamespace
  and proname in ('criar_paciente_com_procedimentos', 'atualizar_paciente_com_procedimentos');
-- Esperado: criar_... com 26 argumentos terminando em "p_data_envio_plano date DEFAULT NULL::date";
-- atualizar_... com 22 argumentos, mesmo final. authenticated_pode=true, anon_pode=false nas duas.

set local role authenticated;
set local request.jwt.claims = '{"sub":"<UID_VITOR>","role":"authenticated"}';

-- ---- Cenário A — paciente novo, Plano=Sim, data informada ----
select id, nome, plano_tratamento, data_envio_plano
from public.criar_paciente_com_procedimentos(
  p_nome := 'QA C1 CENARIO A - remover',
  p_plano_tratamento := 'Sim',
  p_data_envio_plano := current_date
);
-- Esperado: data_envio_plano = current_date.

-- ---- Cenário envio sem Sim (item 6/7, defesa em profundidade no servidor) ----
select plano_tratamento, data_envio_plano
from public.criar_paciente_com_procedimentos(
  p_nome := 'QA C1 INCOERENTE - remover',
  p_plano_tratamento := 'Não',
  p_data_envio_plano := current_date
);
-- Esperado: data_envio_plano = NULL, mesmo tendo sido enviada — a RPC
-- normaliza, nunca persiste incoerente (item 9 dos testes do pedido).

-- ---- Cenário D — paciente com Plano=Sim e data existente, muda para Não ----
with novo as (
  select id from public.criar_paciente_com_procedimentos(
    p_nome := 'QA C1 CENARIO D - remover',
    p_plano_tratamento := 'Sim',
    p_data_envio_plano := current_date - 5
  )
)
select id from novo \gset
-- guarda o id em :id (psql) — ajustar manualmente se rodar fora do psql.

select plano_tratamento, data_envio_plano
from public.atualizar_paciente_com_procedimentos(
  p_paciente_id := :'id',
  p_nome := 'QA C1 CENARIO D - remover',
  p_plano_tratamento := 'Não'
);
-- Esperado: data_envio_plano = NULL (limpa automaticamente, também no servidor).

-- ---- Confirmar que data_perda continua automática (regressão) ----
select id, status, data_perda
from public.criar_paciente_com_procedimentos(
  p_nome := 'QA C1 REGRESSAO DATA PERDA - remover',
  p_marcou_consulta := 'Não'
);
-- Esperado: status='Perdido', data_perda=current_date (inalterado).

-- ---- Confirmar que Recorrência continua funcionando junto (regressão) ----
-- (usar um <TIPO_RECORRENCIA_REAL_ID> da clínica para este teste)
-- select id, status from public.criar_paciente_com_procedimentos(
--   p_nome := 'QA C1 REGRESSAO RECORRENCIA - remover',
--   p_recorrente_inicial := true,
--   p_recorrencia_tipo_id := '<TIPO_RECORRENCIA_REAL_ID>',
--   p_recorrencia_data_inicio := current_date,
--   p_recorrencia_proximo_retorno := current_date + 30
-- );

reset role;

-- ---- Limpeza dos registros QA ----
delete from public.pacientes where nome ilike 'QA C1 %';

select count(*) as total_qa_c1_restante from public.pacientes where nome ilike 'QA C1 %';
-- Esperado: 0.
