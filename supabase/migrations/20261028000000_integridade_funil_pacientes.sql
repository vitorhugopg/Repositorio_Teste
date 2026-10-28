-- ============================================================
-- Fase C2.3.1 + C2.3.2 — Integridade das etapas do funil
-- (marcou_consulta -> compareceu -> plano_tratamento -> fechou_tratamento)
-- ------------------------------------------------------------
-- NÃO EXECUTAR ainda — aguardando autorização explícita para rodar
-- manualmente no SQL Editor do projeto Supabase da Mori Ortodontia
-- (rynlzkdqxbzwcznufnpn). Esta sessão não tem credenciais de banco para
-- aplicar automaticamente.
--
-- Escopo: SOMENTE normalização/validação server-side em
-- `criar_paciente_com_procedimentos` e `atualizar_paciente_com_procedimentos`.
-- Nenhuma outra tabela, RLS, grant, constraint ou RPC é tocada. Nenhum
-- UPDATE em massa em pacientes históricos incoerentes. `calc_status()` e
-- `calcStatus()` NÃO são alterados nesta migration (decisão explícita do
-- pedido) — a correção acontece na camada de gravação, antes do cálculo
-- de status, exatamente como a C2.3 (auditoria) recomendou.
--
-- ------------------------------------------------------------
-- Assinaturas — SEM MUDANÇA (CREATE OR REPLACE, não DROP+CREATE)
-- ------------------------------------------------------------
-- Nenhum parâmetro novo é adicionado. As duas funções continuam com
-- exatamente as mesmas assinaturas da C1/C2 (26 e 22 parâmetros
-- respectivamente) — só a lógica interna muda. Grants reafirmados por
-- consistência/auditabilidade, como nas rodadas anteriores.
--
-- ------------------------------------------------------------
-- Regras implementadas (aprovadas com ajustes pelo usuário)
-- ------------------------------------------------------------
-- REGRA 4 (bloqueio, roda PRIMEIRO, usa os valores CRUS submetidos,
--   independe de transição/histórico): para aceitar
--   fechou_tratamento em ('Sim','Parcial') exige marcou_consulta='Sim' E
--   compareceu='Sim' E plano_tratamento='Sim' nos valores recém-enviados.
--   Se qualquer um faltar, REJEITA com mensagem amigável — nunca corrige
--   silenciosamente os campos anteriores. Isso vale também para resave de
--   um histórico já incoerente (mesmo racional da C2: "a nova combinação
--   submetida precisa ser validada" — sem carve-out, igual a C2.1/C2.2).
--
-- REGRA 1 (limpeza por TRANSIÇÃO real — marcou_consulta vira 'Não'):
--   só dispara quando o valor ANTIGO não era 'Não' e o NOVO é 'Não' (em
--   criação, não existe "antigo", então dispara sempre que o valor final é
--   'Não'). Limpa (-> NULL): compareceu, fez_radiografia, plano_tratamento,
--   data_consulta, fechou_tratamento (o fechou_tratamento PRECISA ser
--   limpo aqui também, senão reabre o mesmo gap de precedência já
--   diagnosticado: um fechou_tratamento='Pendente' residual bloquearia o
--   calc_status() de produzir 'Perdido' via marcou_consulta). valor_fechado
--   /data_fechamento/motivo_perda_id são zerados em cascata pela
--   normalização comercial C2 (status vira 'Perdido'); motivo_perda_id
--   passa a ser EXIGIDO (igual já fazia a C2) e data_perda é gerida pela
--   lógica já existente (sem alteração, sem override aqui).
--
-- REGRA 2 (limpeza por TRANSIÇÃO real — compareceu vira 'Não', usando o
--   valor JÁ efetivo pós-Regra-1): só dispara quando o valor ANTIGO não
--   era 'Não' e o NOVO (efetivo) é 'Não'. Limpa (-> NULL): fez_radiografia,
--   plano_tratamento, fechou_tratamento — e, diferente da Regra 1, força
--   data_perda para NULL explicitamente (pedido explícito do usuário,
--   mesmo que o status antes/depois não passe pela transição De/Para
--   Perdido da lógica C2 já existente). O status resultante aqui é
--   'Não Compareceu' (nunca 'Perdido'), então motivo_perda_id NÃO é
--   exigido.
--
-- REGRA 3 (plano_tratamento='Não' — SEM NENHUMA limpeza nova): correção
--   explícita do próprio relatório de auditoria anterior — NÃO trata
--   fechou_tratamento em ('Não','Pendente','Não precisa no momento') como
--   incoerente com plano_tratamento='Não', porque existem pacientes
--   históricos reais com exatamente essa combinação. A única normalização
--   que continua valendo é a já existente da C1 (data_envio_plano só
--   existe quando plano_tratamento='Sim').
--
-- valor_orcamento NUNCA é limpo por nenhuma destas regras.
--
-- ------------------------------------------------------------
-- HISTÓRICO — proteção contra limpeza destrutiva em edição não relacionada
-- ------------------------------------------------------------
-- Nenhum UPDATE em massa é feito aqui. As Regras 1 e 2 só disparam quando
-- há uma TRANSIÇÃO REAL no valor (comparando v_antigo.* com o valor
-- recém-submetido) — nunca quando o campo já estava 'Não' antes e
-- continua 'Não' nesta edição. Isso significa que reabrir um paciente
-- histórico incoerente (ex.: marcou_consulta já era 'Não' com
-- fechou_tratamento residual 'Sim') e salvar uma edição não relacionada
-- (ex.: só mudar observações) NÃO apaga esse dado antigo. A REGRA 4
-- (bloqueio) é a exceção deliberada: ela valida a COMBINAÇÃO SUBMETIDA
-- agora, com ou sem transição — um histórico incoerente com
-- fechou_tratamento='Sim' só volta a ser editável quando a combinação for
-- corrigida (mesmo comportamento, sem carve-out, já usado pela validação
-- comercial da C2.1/C2.2 para valor_fechado/motivo_perda_id). Recomenda-se
-- rodar a query de auditoria (seção final deste arquivo) ANTES de aplicar
-- esta migration no Supabase real, para dimensionar quantos pacientes
-- históricos ficariam bloqueados até correção.
--
-- ------------------------------------------------------------
-- Ordem de normalização dentro das duas funções (auditada conforme pedido)
-- ------------------------------------------------------------
--   1) Regra 4 — bloqueio (valores crus, antes de qualquer limpeza)
--   2) Regra 1 — integridade do funil (marcou_consulta -> Não)
--   3) Regra 2 — integridade do funil (compareceu -> Não, usa valores já
--      normalizados pela Regra 1)
--   4) Regra 3 / C1 — data_envio_plano (usa plano_tratamento já normalizado)
--   5) Cálculo do status (calc_status(), usa TODOS os valores já
--      normalizados pelas regras 1-4 — nunca o valor cru)
--   6) data_perda (lógica C2 já existente, inalterada, + override
--      explícito da Regra 2)
--   7) Normalização comercial C2 (valor_fechado/data_fechamento/
--      motivo_perda_id, baseada no status calculado no passo 5)
--   8) Persistência (INSERT/UPDATE)
-- Esta ordem evita que a limpeza do passo 2/3 produza um status no passo 5
-- que o passo 7 "corrija" de um jeito que contradiga a limpeza — porque o
-- passo 7 sempre opera sobre o resultado já coerente dos passos anteriores.
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
  v_marcou_consulta text;
  v_data_consulta date;
  v_compareceu text;
  v_fez_radiografia text;
  v_plano_tratamento text;
  v_fechou_tratamento text;
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

  -- [Fase C2.3 — Regra 4] Bloqueio de fechamento incoerente, usando os
  -- valores CRUS submetidos (antes de qualquer limpeza). Nunca corrige
  -- silenciosamente: rejeita e pede para o usuário corrigir.
  if p_fechou_tratamento in ('Sim', 'Parcial') then
    if p_marcou_consulta is distinct from 'Sim' then
      raise exception 'Para registrar o fechamento, informe que o paciente marcou a consulta.';
    end if;
    if p_compareceu is distinct from 'Sim' then
      raise exception 'Para registrar o fechamento, informe que o paciente compareceu à consulta.';
    end if;
    if p_plano_tratamento is distinct from 'Sim' then
      raise exception 'Para registrar o fechamento, informe que o plano de tratamento foi apresentado.';
    end if;
  end if;

  -- [Fase C2.3 — Regra 1] Em criação não existe "antigo": a limpeza vale
  -- incondicionalmente quando o valor final de marcou_consulta é 'Não'.
  if p_marcou_consulta = 'Não' then
    v_compareceu := null;
    v_fez_radiografia := null;
    v_plano_tratamento := null;
    v_fechou_tratamento := null;
    v_data_consulta := null;
  else
    v_compareceu := p_compareceu;
    v_fez_radiografia := p_fez_radiografia;
    v_plano_tratamento := p_plano_tratamento;
    v_fechou_tratamento := p_fechou_tratamento;
    v_data_consulta := p_data_consulta;
  end if;
  v_marcou_consulta := p_marcou_consulta;

  -- [Fase C2.3 — Regra 2] Mesmo racional, agora sobre compareceu, usando o
  -- valor JÁ normalizado pela Regra 1 acima.
  if v_compareceu = 'Não' then
    v_fez_radiografia := null;
    v_plano_tratamento := null;
    v_fechou_tratamento := null;
  end if;

  -- [Fase C2.3 — Regra 3 / C1] data_envio_plano só existe quando
  -- plano_tratamento='Sim' — defesa em profundidade, agora sobre o valor
  -- JÁ normalizado pelas Regras 1/2 acima (nunca sobre o valor cru).
  v_data_envio_plano := case when v_plano_tratamento = 'Sim' then p_data_envio_plano else null end;

  -- [calc_status] Sempre com os valores JÁ normalizados pelas regras acima
  -- — nunca os valores crus (calc_status() em si não é alterado).
  v_status_depois := public.calc_status(v_fechou_tratamento, v_plano_tratamento, v_compareceu, v_marcou_consulta, p_nome);
  v_data_perda := case when v_status_depois = 'Perdido' then current_date else null end;

  -- [Fase C2] Coerência comercial baseada no STATUS CALCULADO (nunca só
  -- em fechou_tratamento — v_status_depois já cobre o caminho
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
    p_data_contato, v_marcou_consulta, v_data_consulta, v_compareceu,
    v_fez_radiografia, v_plano_tratamento, v_data_envio_plano, p_valor_orcamento,
    v_fechou_tratamento, v_valor_fechado, v_data_fechamento,
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
  v_marcou_consulta text;
  v_data_consulta date;
  v_compareceu text;
  v_fez_radiografia text;
  v_plano_tratamento text;
  v_fechou_tratamento text;
  v_transicao_marcou_nao boolean;
  v_transicao_compareceu_nao boolean;
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

  -- [Fase C2.3 — Regra 4] Bloqueio de fechamento incoerente, usando os
  -- valores CRUS submetidos. Roda ANTES de qualquer limpeza e INDEPENDE de
  -- transição — se o registro já estava incoerente no histórico e esta
  -- combinação (fechou_tratamento 'Sim'/'Parcial' sem marcou/compareceu/
  -- plano='Sim') continua sendo reenviada, o save é rejeitado até a
  -- combinação ser corrigida (mesmo racional, sem carve-out, já usado pela
  -- validação comercial da C2.1/C2.2).
  if p_fechou_tratamento in ('Sim', 'Parcial') then
    if p_marcou_consulta is distinct from 'Sim' then
      raise exception 'Para registrar o fechamento, informe que o paciente marcou a consulta.';
    end if;
    if p_compareceu is distinct from 'Sim' then
      raise exception 'Para registrar o fechamento, informe que o paciente compareceu à consulta.';
    end if;
    if p_plano_tratamento is distinct from 'Sim' then
      raise exception 'Para registrar o fechamento, informe que o plano de tratamento foi apresentado.';
    end if;
  end if;

  -- [Fase C2.3 — Regra 1] Só limpa numa TRANSIÇÃO real (valor antigo não
  -- era 'Não' e o novo é 'Não') — uma edição não relacionada de um
  -- registro que já era 'Não' antes NÃO apaga dado histórico incoerente.
  v_transicao_marcou_nao := (p_marcou_consulta = 'Não') and (v_antigo.marcou_consulta is distinct from 'Não');
  if v_transicao_marcou_nao then
    v_compareceu := null;
    v_fez_radiografia := null;
    v_plano_tratamento := null;
    v_fechou_tratamento := null;
    v_data_consulta := null;
  else
    v_compareceu := p_compareceu;
    v_fez_radiografia := p_fez_radiografia;
    v_plano_tratamento := p_plano_tratamento;
    v_fechou_tratamento := p_fechou_tratamento;
    v_data_consulta := p_data_consulta;
  end if;
  v_marcou_consulta := p_marcou_consulta;

  -- [Fase C2.3 — Regra 2] Mesmo racional, agora sobre compareceu, usando o
  -- valor JÁ normalizado pela Regra 1 acima. Se a Regra 1 já limpou
  -- compareceu para NULL, esta condição naturalmente não dispara de novo
  -- (NULL não é 'Não').
  v_transicao_compareceu_nao := (v_compareceu = 'Não') and (v_antigo.compareceu is distinct from 'Não');
  if v_transicao_compareceu_nao then
    v_fez_radiografia := null;
    v_plano_tratamento := null;
    v_fechou_tratamento := null;
  end if;

  -- [Fase C2.3 — Regra 3 / C1] data_envio_plano só existe quando
  -- plano_tratamento='Sim' — defesa em profundidade, agora sobre o valor
  -- JÁ normalizado pelas Regras 1/2 acima (nunca sobre o valor cru).
  v_data_envio_plano := case when v_plano_tratamento = 'Sim' then p_data_envio_plano else null end;

  -- [calc_status] Sempre com os valores JÁ normalizados pelas regras acima
  -- — nunca os valores crus (calc_status() em si não é alterado). O status
  -- ANTES continua calculado a partir do registro antigo, sem nenhuma
  -- normalização (é só um retrato do que já estava salvo).
  v_status_antes := public.calc_status(v_antigo.fechou_tratamento, v_antigo.plano_tratamento, v_antigo.compareceu, v_antigo.marcou_consulta, v_antigo.nome);
  v_status_depois := public.calc_status(v_fechou_tratamento, v_plano_tratamento, v_compareceu, v_marcou_consulta, p_nome);

  -- [data_perda] ZERO alteração de comportamento da lógica C2 já existente
  -- — preserva o valor antigo (inclusive NULL) e só sobrescreve nas
  -- transições DE/PARA Perdido. Um paciente que ERA Perdido com
  -- data_perda NULL e CONTINUA Perdido não recebe current_date aqui.
  v_data_perda := v_antigo.data_perda;
  if v_status_depois = 'Perdido' and v_status_antes <> 'Perdido' then
    v_data_perda := current_date;
  elsif v_status_antes = 'Perdido' and v_status_depois <> 'Perdido' then
    v_data_perda := null;
  end if;
  -- [Fase C2.3 — Regra 2] Override explícito: quando a transição
  -- compareceu->Não dispara nesta mesma gravação, data_perda é forçada
  -- para NULL independentemente do resultado da lógica acima (pedido
  -- explícito do usuário — o status resultante aqui nunca é 'Perdido',
  -- mas pode existir um data_perda residual de histórico incoerente que
  -- precisa ser limpo justamente porque esta é uma transição real, não
  -- uma resubmissão de valor já existente).
  if v_transicao_compareceu_nao then
    v_data_perda := null;
  end if;

  -- [Fase C2] Coerência comercial baseada no STATUS CALCULADO (v_status_depois
  -- já cobre marcou_consulta='Não' -> 'Perdido' corretamente). Sem
  -- carve-out para histórico: se este registro estava incoerente e está
  -- sendo editado agora, a nova regra passa a valer para este save.
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
    marcou_consulta = v_marcou_consulta,
    data_consulta = v_data_consulta,
    compareceu = v_compareceu,
    fez_radiografia = v_fez_radiografia,
    plano_tratamento = v_plano_tratamento,
    data_envio_plano = v_data_envio_plano,
    valor_orcamento = p_valor_orcamento,
    fechou_tratamento = v_fechou_tratamento,
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
-- QUERIES DE AUDITORIA (read-only, rodar ANTES de aplicar esta migration
-- no Supabase real, para dimensionar o impacto da Regra 4 — bloqueio sem
-- carve-out — em pacientes históricos incoerentes)
-- ============================================================

-- Quantos pacientes ficariam BLOQUEADOS para qualquer novo save até
-- corrigirem a combinação (fechou_tratamento 'Sim'/'Parcial' sem
-- marcou_consulta/compareceu/plano_tratamento = 'Sim'):
select count(*) as pacientes_bloqueados_regra4
from public.pacientes
where fechou_tratamento in ('Sim', 'Parcial')
  and (marcou_consulta is distinct from 'Sim'
    or compareceu is distinct from 'Sim'
    or plano_tratamento is distinct from 'Sim');

-- Detalhe (id, nome, clínica, e qual campo está faltando) para a clínica
-- da Mori Ortodontia:
select id, nome, marcou_consulta, compareceu, plano_tratamento, fechou_tratamento
from public.pacientes
where clinica_id = '4f1d0862-3455-49c6-997b-c8e8f8d165ee'
  and fechou_tratamento in ('Sim', 'Parcial')
  and (marcou_consulta is distinct from 'Sim'
    or compareceu is distinct from 'Sim'
    or plano_tratamento is distinct from 'Sim');

-- ============================================================
-- ROTEIRO DE VERIFICAÇÃO (rodar manualmente no SQL Editor, usando
-- EXCLUSIVAMENTE registros QA — nunca pacientes reais). Ajustar
-- <UID_VITOR> para o auth.uid() real do Vitor antes de rodar.
-- ============================================================

-- ---- 0) Confirmar que nenhum histórico foi tocado ----
select count(*) as total_pacientes from public.pacientes
where clinica_id = '4f1d0862-3455-49c6-997b-c8e8f8d165ee';

-- ---- 1) Confirmar assinaturas e grants (sem mudança de parâmetros) ----
select proname, pg_get_function_identity_arguments(oid) as argumentos,
       has_function_privilege('authenticated', oid, 'execute') as authenticated_pode,
       has_function_privilege('anon', oid, 'execute') as anon_pode
from pg_proc
where pronamespace = 'public'::regnamespace
  and proname in ('criar_paciente_com_procedimentos', 'atualizar_paciente_com_procedimentos');

set local role authenticated;
set local request.jwt.claims = '{"sub":"<UID_VITOR>","role":"authenticated"}';

-- ---- Teste 1 — fechou=Sim + compareceu=Não (mesma ação): bloqueado ----
select * from public.criar_paciente_com_procedimentos(
  p_nome := 'QA C2.3 TESTE 1 - remover', p_marcou_consulta := 'Sim', p_compareceu := 'Não',
  p_fechou_tratamento := 'Sim', p_valor_fechado := 1000, p_data_fechamento := current_date
);
-- Esperado: erro "...informe que o paciente compareceu à consulta."

-- ---- Teste 2 — marcou=Não limpa downstream e vira Perdido ----
select status, compareceu, plano_tratamento, fechou_tratamento, motivo_perda_id
from public.criar_paciente_com_procedimentos(
  p_nome := 'QA C2.3 TESTE 2 - remover', p_marcou_consulta := 'Não',
  p_motivo_perda_id := (select id from public.motivos_perda where clinica_id = '4f1d0862-3455-49c6-997b-c8e8f8d165ee' limit 1)
);

reset role;

-- ---- Limpeza ----
delete from public.pacientes where nome ilike 'QA C2.3 %';
select count(*) as deve_ser_zero from public.pacientes where nome ilike 'QA C2.3 %';
