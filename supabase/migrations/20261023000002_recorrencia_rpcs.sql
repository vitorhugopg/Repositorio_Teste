-- ============================================================
-- Módulo de Recorrência de Pacientes — RPCs
-- ------------------------------------------------------------
-- NÃO EXECUTAR ainda — aguardando o operador rodar manualmente no SQL
-- Editor do projeto Supabase da Mori Ortodontia (rynlzkdqxbzwcznufnpn),
-- DEPOIS de 20261023000000_clinicas_timezone.sql e
-- 20261023000001_recorrencia_schema.sql (esta migration depende das
-- tabelas criadas lá). Esta sessão não tem credenciais de banco para
-- aplicar automaticamente.
--
-- ------------------------------------------------------------
-- Decisão de arquitetura: função compartilhada sem aumentar a
-- superfície pública de RPCs
-- ------------------------------------------------------------
-- O fluxo "Novo Paciente + primeira recorrência" (atômico, dentro de
-- criar_paciente_com_procedimentos) e o fluxo "paciente existente +
-- início de recorrência" (iniciar_ciclo_recorrencia, isolada)
-- precisam da MESMA validação e do MESMO INSERT em ciclos_recorrencia —
-- sem duplicar essa lógica em dois lugares.
--
-- Problema: em Postgres, uma função SECURITY INVOKER que chama outra
-- função SECURITY INVOKER continua executando como o papel ORIGINAL
-- (authenticated) na chamada interna — não existe "chamada privilegiada
-- só porque veio de dentro de outra função". Ou seja, se a função
-- compartilhada fosse criada em public, ela precisaria de
-- EXECUTE para authenticated MESMO que só seja chamada internamente, o
-- que a tornaria tecnicamente invocável direto pelo frontend via
-- `supabase.rpc(...)` — exatamente o aumento de superfície pública que
-- não queremos.
--
-- Solução adotada: colocar a função compartilhada em um schema
-- chamado `internal`, que NÃO está na lista de schemas que o PostgREST
-- expõe como API (por padrão, Supabase expõe só o schema `public` —
-- Dashboard > Settings > API > "Exposed schemas"). A função continua
-- precisando de EXECUTE para `authenticated` (Postgres exige isso para
-- a cadeia de chamada SECURITY INVOKER funcionar), mas
-- `supabase.rpc('iniciar_ciclo_recorrencia_core')` do navegador nunca
-- encontra esse nome, porque o PostgREST nem considera o schema
-- `internal` ao resolver uma chamada de RPC — é uma camada de
-- roteamento completamente separada do GRANT/EXECUTE do Postgres.
--
-- Isso NÃO é "segurança por obscuridade": GRANT e RLS continuam sendo
-- a autoridade real para qualquer um que já esteja dentro do banco (ex.:
-- alguém com a service_role key, ou conexão direta ao Postgres) — o que
-- este schema resolve é especificamente "o que o navegador do cliente
-- autenticado consegue chamar via API", que é a preocupação relevante
-- aqui. A função continua `security invoker` (nunca `security definer`)
-- — ela NUNCA ganha privilégio extra; roda com o papel e a RLS de quem
-- chamou, exatamente como qualquer outra função deste projeto. RLS não
-- é enfraquecida em nenhum momento: todo INSERT feito por ela em
-- ciclos_recorrencia ainda passa pela policy "insert_ciclos_recorrencia"
-- (clinica_id in minhas_clinicas()), igual passaria se o navegador
-- inserisse direto.
--
-- IMPORTANTE — dependência a confirmar: esta solução pressupõe que o
-- projeto expõe só o schema `public` via API (configuração padrão do
-- Supabase). O roteiro de verificação abaixo inclui um passo para
-- confirmar isso. Se o projeto algum dia expuser também o schema
-- `internal`, esta proteção deixa de valer — nesse caso, a função
-- precisaria ser revisada (ex.: mover para um schema ainda mais
-- específico, ou aceitar a duplicação de ~15 linhas de SQL como
-- alternativa mais simples).
-- ============================================================

begin;

create schema if not exists internal;

revoke all on schema internal from public, anon;
grant usage on schema internal to authenticated;

comment on schema internal is
  'Funções auxiliares compartilhadas entre RPCs públicas, NUNCA expostas via supabase.rpc() — o PostgREST só expõe o schema public por padrão. Ver comentário no topo de 20261023000002_recorrencia_rpcs.sql para a justificativa completa.';

-- ------------------------------------------------------------
-- Função compartilhada: valida + insere um ciclo de recorrência.
-- Recebe clinica_id/profile_id JÁ resolvidos pelo chamador (nunca
-- resolve auth.uid() de novo aqui), para poder rodar tanto dentro de
-- criar_paciente_com_procedimentos (que já resolveu esses valores)
-- quanto dentro do wrapper público iniciar_ciclo_recorrencia.
-- ------------------------------------------------------------
create or replace function internal.iniciar_ciclo_recorrencia_core(
  p_clinica_id uuid,
  p_profile_id uuid,
  p_paciente_id uuid,
  p_tipo_recorrencia_id uuid,
  p_data_inicio date,
  p_proximo_retorno date,
  p_responsavel_id uuid default null,
  p_observacoes text default null
)
returns public.ciclos_recorrencia
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_resultado public.ciclos_recorrencia;
begin
  if p_tipo_recorrencia_id is null or p_data_inicio is null or p_proximo_retorno is null then
    raise exception 'Tipo de recorrência, data de início e próximo retorno são obrigatórios.';
  end if;

  if not exists (
    select 1 from public.tipos_recorrencia
    where id = p_tipo_recorrencia_id and clinica_id = p_clinica_id and ativo = true
  ) then
    raise exception 'Tipo de recorrência inválido, inativo ou de outra clínica.';
  end if;

  -- Se já existir ciclo ATIVO para este paciente, o índice único
  -- parcial ciclos_recorrencia_um_ativo_por_paciente rejeita o INSERT
  -- abaixo com unique_violation (SQLSTATE 23505) — a garantia real é o
  -- índice, não esta checagem. Não duplicamos a checagem aqui porque o
  -- INSERT já falha corretamente; o wrapper público é quem traduz o
  -- erro em uma mensagem amigável, se necessário.
  insert into public.ciclos_recorrencia (
    clinica_id, paciente_id, tipo_recorrencia_id, responsavel_id,
    data_inicio, proximo_retorno, observacoes, created_by, updated_by
  ) values (
    p_clinica_id, p_paciente_id, p_tipo_recorrencia_id, p_responsavel_id,
    p_data_inicio, p_proximo_retorno, p_observacoes, p_profile_id, p_profile_id
  )
  returning * into v_resultado;

  return v_resultado;
end;
$$;

revoke all on function internal.iniciar_ciclo_recorrencia_core(uuid,uuid,uuid,uuid,date,date,uuid,text) from public, anon;
grant execute on function internal.iniciar_ciclo_recorrencia_core(uuid,uuid,uuid,uuid,date,date,uuid,text) to authenticated;

-- ------------------------------------------------------------
-- RPC pública 1: iniciar_ciclo_recorrencia — paciente JÁ EXISTENTE
-- (item 8/9 do pedido: não atomiza com edição geral do paciente).
-- ------------------------------------------------------------
create or replace function public.iniciar_ciclo_recorrencia(
  p_paciente_id uuid,
  p_tipo_recorrencia_id uuid,
  p_data_inicio date,
  p_proximo_retorno date,
  p_responsavel_id uuid default null,
  p_observacoes text default null
)
returns public.ciclos_recorrencia
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_profile_id uuid;
  v_clinica_id uuid;
  v_paciente public.pacientes%rowtype;
begin
  select id, clinica_id into v_profile_id, v_clinica_id
    from public.profiles
    where auth_user_id = auth.uid() and ativo = true
    limit 1;

  if v_profile_id is null then
    raise exception 'Perfil ativo não encontrado para o usuário autenticado.';
  end if;

  -- O SELECT abaixo já é filtrado pela RLS de select_pacientes
  -- (clinica_id in minhas_clinicas()), porque esta função é SECURITY
  -- INVOKER — um paciente de outra clínica simplesmente não é
  -- encontrado (v_paciente.id fica null), nunca "encontrado mas de
  -- clínica errada". Mesmo idioma já usado em
  -- atualizar_paciente_com_procedimentos.
  select * into v_paciente from public.pacientes where id = p_paciente_id;
  if v_paciente.id is null then
    raise exception 'Paciente não encontrado ou sem permissão de acesso.';
  end if;

  return internal.iniciar_ciclo_recorrencia_core(
    v_clinica_id, v_profile_id, p_paciente_id, p_tipo_recorrencia_id,
    p_data_inicio, p_proximo_retorno, p_responsavel_id, p_observacoes
  );
end;
$$;

revoke all on function public.iniciar_ciclo_recorrencia(uuid,uuid,date,date,uuid,text) from public, anon;
grant execute on function public.iniciar_ciclo_recorrencia(uuid,uuid,date,date,uuid,text) to authenticated;

-- ------------------------------------------------------------
-- RPC pública 2: registrar_retorno_recorrencia
-- ------------------------------------------------------------
create or replace function public.registrar_retorno_recorrencia(
  p_ciclo_id uuid,
  p_data_retorno_realizado date,
  p_proximo_retorno date,
  p_observacao text default null
)
returns public.ciclos_recorrencia
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_profile_id uuid;
  v_clinica_id uuid;
  v_ciclo public.ciclos_recorrencia%rowtype;
  v_resultado public.ciclos_recorrencia;
begin
  if p_data_retorno_realizado is null or p_proximo_retorno is null then
    raise exception 'Data do retorno realizado e próximo retorno são obrigatórios.';
  end if;

  select id, clinica_id into v_profile_id, v_clinica_id
    from public.profiles
    where auth_user_id = auth.uid() and ativo = true
    limit 1;

  if v_profile_id is null then
    raise exception 'Perfil ativo não encontrado para o usuário autenticado.';
  end if;

  -- Mesmo idioma: SELECT já filtrado pela RLS de select_ciclos_recorrencia.
  select * into v_ciclo from public.ciclos_recorrencia where id = p_ciclo_id;
  if v_ciclo.id is null then
    raise exception 'Ciclo de recorrência não encontrado ou sem permissão de acesso.';
  end if;

  if v_ciclo.status <> 'ativo' then
    raise exception 'Este ciclo de recorrência já foi finalizado — não é possível registrar retorno.';
  end if;

  -- 1) Insere o retorno no histórico (nunca sobrescreve os anteriores).
  insert into public.retornos_recorrencia (
    clinica_id, ciclo_id, paciente_id,
    data_retorno_realizado, proximo_retorno_definido, observacao, usuario_id
  ) values (
    v_clinica_id, p_ciclo_id, v_ciclo.paciente_id,
    p_data_retorno_realizado, p_proximo_retorno, p_observacao, v_profile_id
  );

  -- 2) Atualiza SOMENTE o próximo retorno + auditoria do ciclo. Se este
  --    UPDATE falhar por qualquer motivo, o INSERT acima também é
  --    desfeito (rollback automático da função inteira) — nunca fica um
  --    retorno "órfão" sem o ciclo ter sido atualizado.
  update public.ciclos_recorrencia set
    proximo_retorno = p_proximo_retorno,
    updated_at = now(),
    updated_by = v_profile_id
  where id = p_ciclo_id
  returning * into v_resultado;

  return v_resultado;
end;
$$;

revoke all on function public.registrar_retorno_recorrencia(uuid,date,date,text) from public, anon;
grant execute on function public.registrar_retorno_recorrencia(uuid,date,date,text) to authenticated;

-- ------------------------------------------------------------
-- RPC pública 3: finalizar_ciclo_recorrencia
-- ------------------------------------------------------------
create or replace function public.finalizar_ciclo_recorrencia(
  p_ciclo_id uuid,
  p_data_encerramento date,
  p_motivo_encerramento text,
  p_observacao text default null
)
returns public.ciclos_recorrencia
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_profile_id uuid;
  v_clinica_id uuid;
  v_ciclo public.ciclos_recorrencia%rowtype;
  v_resultado public.ciclos_recorrencia;
begin
  if p_data_encerramento is null then
    raise exception 'Data de encerramento é obrigatória.';
  end if;

  -- A tabela já tem o mesmo check (ciclos_recorrencia_motivo_encerramento_check);
  -- validar aqui também só dá uma mensagem de erro mais legível, mesmo
  -- padrão de concluir_acao_comercial (p_tipo not in (...)).
  if p_motivo_encerramento is null or p_motivo_encerramento not in (
    'Tratamento concluído',
    'Paciente não continuará o tratamento',
    'Mudou de clínica/profissional',
    'Recorrência não é mais necessária',
    'Outro'
  ) then
    raise exception 'Motivo de encerramento inválido: %', p_motivo_encerramento;
  end if;

  select id, clinica_id into v_profile_id, v_clinica_id
    from public.profiles
    where auth_user_id = auth.uid() and ativo = true
    limit 1;

  if v_profile_id is null then
    raise exception 'Perfil ativo não encontrado para o usuário autenticado.';
  end if;

  select * into v_ciclo from public.ciclos_recorrencia where id = p_ciclo_id;
  if v_ciclo.id is null then
    raise exception 'Ciclo de recorrência não encontrado ou sem permissão de acesso.';
  end if;

  if v_ciclo.status <> 'ativo' then
    raise exception 'Este ciclo de recorrência já está finalizado.';
  end if;

  update public.ciclos_recorrencia set
    status = 'finalizado',
    data_encerramento = p_data_encerramento,
    motivo_encerramento = p_motivo_encerramento,
    observacoes = coalesce(p_observacao, observacoes),
    updated_at = now(),
    updated_by = v_profile_id
  where id = p_ciclo_id
  returning * into v_resultado;

  return v_resultado;
end;
$$;

revoke all on function public.finalizar_ciclo_recorrencia(uuid,date,text,text) from public, anon;
grant execute on function public.finalizar_ciclo_recorrencia(uuid,date,text,text) to authenticated;

-- ------------------------------------------------------------
-- Extensão de criar_paciente_com_procedimentos (Novo Paciente + primeira
-- recorrência, ATÔMICO).
-- ------------------------------------------------------------
-- ATENÇÃO — por que isto é um DROP + CREATE, não um CREATE OR REPLACE
-- simples: em Postgres, CREATE OR REPLACE FUNCTION só "substitui no
-- lugar" quando a lista de tipos de parâmetro é EXATAMENTE a mesma.
-- Adicionar novos parâmetros muda a assinatura da função — mesmo todos
-- opcionais com DEFAULT — e um CREATE OR REPLACE nessa situação criaria
-- uma SEGUNDA função (overload) com o mesmo nome, deixando a função
-- antiga (20 parâmetros) intacta e coexistindo com a nova (25
-- parâmetros). PostgREST lida mal com funções sobrecarregadas pelo
-- mesmo nome (erro "Could not choose the best candidate function" é
-- comum), então isso seria um bug sutil e perigoso numa RPC crítica já
-- em produção/homologação.
--
-- Por isso: DROP explícito da assinatura antiga, depois CREATE da nova
-- — dentro da mesma transação (begin/commit), então não há nenhuma
-- janela em que a função fica indisponível para outras sessões.
--
-- O corpo da função abaixo é EXATAMENTE o mesmo da versão em produção
-- (20261010000000_rpc_paciente_atomico.sql, linhas 35-134), com apenas
-- duas adições: os 5 novos parâmetros opcionais no final da lista, e o
-- bloco de recorrência logo antes do SELECT final de retorno. Nenhuma
-- linha do comportamento existente foi alterada — quando os 5 novos
-- parâmetros não são informados (p_recorrente_inicial default false),
-- o comportamento é 100% idêntico ao de hoje.
-- ------------------------------------------------------------

drop function if exists public.criar_paciente_com_procedimentos(
  text, text, text, text, uuid, text, uuid, date, text, date, text, text, text, numeric, text, numeric, date, uuid, text, uuid[]
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
  -- [Recorrência] novos parâmetros, todos opcionais e com DEFAULT —
  -- retrocompatíveis com qualquer chamada existente que não os informe.
  p_recorrente_inicial boolean default false,
  p_recorrencia_tipo_id uuid default null,
  p_recorrencia_data_inicio date default null,
  p_recorrencia_proximo_retorno date default null,
  p_recorrencia_responsavel_id uuid default null
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

  -- 3) [Recorrência] Se solicitado, cria o primeiro ciclo na MESMA
  --    transação do cadastro — ou tudo é salvo (paciente + procedimentos
  --    + ciclo), ou nada é: qualquer exceção aqui desfaz também o INSERT
  --    do paciente e dos vínculos de procedimentos feitos acima, porque
  --    uma função plpgsql é uma única transação por chamada. Reaproveita
  --    EXATAMENTE a mesma validação/INSERT de iniciar_ciclo_recorrencia
  --    (via internal.iniciar_ciclo_recorrencia_core) — nenhuma lógica
  --    duplicada entre os dois fluxos.
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
  boolean, uuid, date, date, uuid
) from public, anon;
grant execute on function public.criar_paciente_com_procedimentos(
  text, text, text, text, uuid, text, uuid, date, text, date, text, text, text, numeric, text, numeric, date, uuid, text, uuid[],
  boolean, uuid, date, date, uuid
) to authenticated;

-- atualizar_paciente_com_procedimentos NÃO é tocada nesta migration —
-- nenhuma necessidade técnica inevitável foi encontrada (item 7 do
-- pedido). Paciente existente usa iniciar_ciclo_recorrencia, isolada.

commit;

-- ============================================================
-- ROTEIRO COMPLETO DE HOMOLOGAÇÃO (rodar manualmente no SQL Editor,
-- NESTA ORDEM, usando EXCLUSIVAMENTE registros QA — nunca pacientes
-- reais). Ajustar <UID_VITOR> para o auth.uid() real do Vitor (admin
-- ativo da Mori) antes de rodar. Todos os blocos abaixo limpam os
-- próprios dados de teste ao final, exceto onde indicado.
-- ============================================================

-- ---- 0) Confirmar que o schema `internal` NÃO é exposto pela API ----
-- (rodar isto como dono/service do projeto, fora de qualquer simulação
-- de authenticated). Verifica a configuração real do PostgREST.
show pgrst.db_schemas;
-- Esperado: o valor não deve listar "internal" (só "public", ou
-- "public, graphql_public", conforme o padrão do projeto). Se
-- "internal" aparecer aqui, a proteção de superfície pública da Seção
-- 11 não está valendo — avisar antes de prosseguir.

-- ---- 1) Confirmar que as 3 novas RPCs e a extensão existem, com os
--         grants esperados (authenticated sim, anon/public não) ----
select p.proname,
       pg_get_function_identity_arguments(p.oid) as argumentos,
       has_function_privilege('authenticated', p.oid, 'execute') as authenticated_pode,
       has_function_privilege('anon', p.oid, 'execute') as anon_pode,
       has_function_privilege('public', p.oid, 'execute') as public_pode
from pg_proc p
where p.pronamespace = 'public'::regnamespace
  and p.proname in ('iniciar_ciclo_recorrencia','registrar_retorno_recorrencia','finalizar_ciclo_recorrencia','criar_paciente_com_procedimentos');
-- Esperado: authenticated_pode=true, anon_pode=false, public_pode=false
-- em todas. criar_paciente_com_procedimentos deve aparecer com a NOVA
-- assinatura (25 argumentos) — confirma que o DROP+CREATE funcionou e
-- não sobrou nenhuma versão antiga (20 argumentos) coexistindo.

select has_function_privilege('authenticated', oid, 'execute') as authenticated_pode,
       has_function_privilege('anon', oid, 'execute') as anon_pode
from pg_proc where pronamespace = 'internal'::regnamespace and proname = 'iniciar_ciclo_recorrencia_core';
-- Esperado: authenticated_pode=true (necessário para a cadeia de
-- chamada funcionar), anon_pode=false. O ponto 0 acima é quem garante
-- que isso não é alcançável via API mesmo com authenticated_pode=true.

set local role authenticated;
set local request.jwt.claims = '{"sub":"<UID_VITOR>","role":"authenticated"}';

-- ---- 2) TESTE DE REGRESSÃO — criação normal de paciente SEM
--          recorrência, idêntica ao comportamento de antes da migration ----
select id, nome, status, data_perda
from public.criar_paciente_com_procedimentos(
  p_nome := 'QA RECORRENCIA REGRESSAO NORMAL - remover'
);
-- Esperado: funciona exatamente como antes (status calculado, sem
-- erro), SEM nenhum ciclo de recorrência criado.
select count(*) from public.ciclos_recorrencia cr
  join public.pacientes p on p.id = cr.paciente_id
  where p.nome = 'QA RECORRENCIA REGRESSAO NORMAL - remover';
-- Esperado: 0.

-- ---- 3) TESTE DE ATOMICIDADE — Novo Paciente + recorrência, com um
--          tipo_recorrencia_id INVÁLIDO para forçar falha DEPOIS do
--          paciente já ter sido inserido (dentro da mesma função) ----
select count(*) from public.pacientes where nome = 'QA RECORRENCIA ATOMICIDADE - remover';
-- Esperado antes: 0.
select * from public.criar_paciente_com_procedimentos(
  p_nome := 'QA RECORRENCIA ATOMICIDADE - remover',
  p_recorrente_inicial := true,
  p_recorrencia_tipo_id := gen_random_uuid(), -- não existe -> deve falhar
  p_recorrencia_data_inicio := current_date,
  p_recorrencia_proximo_retorno := current_date + 30
);
-- Esperado: erro "Tipo de recorrência inválido, inativo ou de outra clínica."
select count(*) from public.pacientes where nome = 'QA RECORRENCIA ATOMICIDADE - remover';
-- Esperado depois: ainda 0 (prova que o paciente NÃO ficou salvo
-- parcialmente — rollback completo da transação).

-- ---- 4) TESTE DE ATOMICIDADE (caminho feliz) — Novo Paciente +
--          recorrência com um tipo_recorrencia_id REAL, confirmando que
--          paciente + ciclo aparecem juntos ----
-- Pré-requisito: criar um tipo de recorrência QA primeiro.
insert into public.tipos_recorrencia (clinica_id, nome)
  select clinica_id, 'QA TIPO RECORRENCIA - remover' from public.profiles
  where auth_user_id = '<UID_VITOR>' limit 1
  returning id;
-- Guardar o id retornado como <QA_TIPO_ID>.

select id, nome, status
from public.criar_paciente_com_procedimentos(
  p_nome := 'QA RECORRENCIA CAMINHO FELIZ - remover',
  p_recorrente_inicial := true,
  p_recorrencia_tipo_id := '<QA_TIPO_ID>',
  p_recorrencia_data_inicio := current_date,
  p_recorrencia_proximo_retorno := current_date + 30
);
-- Guardar o id retornado como <QA_PACIENTE_ID>.
select count(*) from public.ciclos_recorrencia where paciente_id = '<QA_PACIENTE_ID>';
-- Esperado: 1 (ciclo criado junto, mesma transação).

-- ---- 5) TESTE: impedir DOIS ciclos ativos para o mesmo paciente ----
select * from public.iniciar_ciclo_recorrencia(
  p_paciente_id := '<QA_PACIENTE_ID>',
  p_tipo_recorrencia_id := '<QA_TIPO_ID>',
  p_data_inicio := current_date,
  p_proximo_retorno := current_date + 60
);
-- Esperado: erro de violação de unicidade (o índice único parcial
-- ciclos_recorrencia_um_ativo_por_paciente rejeita — este paciente já
-- tem um ciclo ativo do passo 4).
select count(*) from public.ciclos_recorrencia
  where paciente_id = '<QA_PACIENTE_ID>' and status = 'ativo';
-- Esperado: continua 1 (não virou 2).

-- ---- 6) TESTE: Registrar retorno — transacional, nunca sobrescreve
--          histórico anterior ----
select id, proximo_retorno from public.ciclos_recorrencia where paciente_id = '<QA_PACIENTE_ID>' and status='ativo';
-- Guardar o id retornado como <QA_CICLO_ID>.

select * from public.registrar_retorno_recorrencia(
  p_ciclo_id := '<QA_CICLO_ID>',
  p_data_retorno_realizado := current_date,
  p_proximo_retorno := current_date + 30,
  p_observacao := 'primeiro retorno QA'
);
select * from public.registrar_retorno_recorrencia(
  p_ciclo_id := '<QA_CICLO_ID>',
  p_data_retorno_realizado := current_date,
  p_proximo_retorno := current_date + 60,
  p_observacao := 'segundo retorno QA'
);
select count(*) from public.retornos_recorrencia where ciclo_id = '<QA_CICLO_ID>';
-- Esperado: 2 (as duas linhas permanecem, nenhuma foi sobrescrita).
select proximo_retorno from public.ciclos_recorrencia where id = '<QA_CICLO_ID>';
-- Esperado: current_date + 60 (só o último valor venceu no CICLO,
-- histórico das duas chamadas continua intacto em retornos_recorrencia).

-- ---- 7) TESTE: append-only — UPDATE/DELETE direto em
--          retornos_recorrencia deve ser rejeitado (sem policy
--          permissiva e sem grant) ----
update public.retornos_recorrencia set observacao = 'tentativa de alterar histórico' where ciclo_id = '<QA_CICLO_ID>';
-- Esperado: erro de permissão (grant ausente) ou 0 linhas afetadas por
-- RLS — nunca uma alteração de verdade. Confirmar com o select abaixo.
select observacao from public.retornos_recorrencia where ciclo_id = '<QA_CICLO_ID>' order by created_at;
-- Esperado: ainda 'primeiro retorno QA' e 'segundo retorno QA', sem alteração.
delete from public.retornos_recorrencia where ciclo_id = '<QA_CICLO_ID>';
-- Esperado: erro de permissão ou 0 linhas afetadas.
select count(*) from public.retornos_recorrencia where ciclo_id = '<QA_CICLO_ID>';
-- Esperado: ainda 2.

-- ---- 8) TESTE: Finalizar recorrência ----
select * from public.finalizar_ciclo_recorrencia(
  p_ciclo_id := '<QA_CICLO_ID>',
  p_data_encerramento := current_date,
  p_motivo_encerramento := 'Tratamento concluído',
  p_observacao := 'encerramento QA'
);
select status, data_encerramento, motivo_encerramento from public.ciclos_recorrencia where id = '<QA_CICLO_ID>';
-- Esperado: status='finalizado', data_encerramento=hoje, motivo preenchido.

-- Depois de finalizado, deve ser possível iniciar um NOVO ciclo para o
-- mesmo paciente (Ciclo 2):
select * from public.iniciar_ciclo_recorrencia(
  p_paciente_id := '<QA_PACIENTE_ID>',
  p_tipo_recorrencia_id := '<QA_TIPO_ID>',
  p_data_inicio := current_date,
  p_proximo_retorno := current_date + 180
);
-- Esperado: sucesso (não há mais ciclo ativo bloqueando).

reset role;

-- ---- 9) TESTE DE ISOLAMENTO ENTRE CLÍNICAS — bloco autocontido, SEMPRE
--          termina em ROLLBACK, não deixa nenhum traço nos dados reais.
--          Cria uma segunda clínica + profile temporários só para provar
--          que RLS/FK impedem referência cruzada. ----
begin;

insert into public.clinicas (nome, cidade, timezone)
  values ('QA CLINICA ISOLAMENTO - rollback', 'Teste', 'America/Sao_Paulo')
  returning id;
-- Guardar como <QA_CLINICA_B_ID> (só existe dentro desta transação).

insert into public.profiles (clinica_id, nome, cargo, role, ativo, auth_user_id)
  values ('<QA_CLINICA_B_ID>', 'QA Profile Clinica B', 'Teste', 'admin', true, gen_random_uuid())
  returning id;
-- Guardar como <QA_PROFILE_B_ID>.

insert into public.tipos_recorrencia (clinica_id, nome)
  values ('<QA_CLINICA_B_ID>', 'QA Tipo Clinica B')
  returning id;
-- Guardar como <QA_TIPO_B_ID>.

-- Tentativa 1: ciclo da Clínica B apontando para o <QA_TIPO_ID> da Mori
-- (clínica A) — a FK composta ciclos_recorrencia_tipo_fk deve rejeitar,
-- porque (clinica_id=<QA_CLINICA_B_ID>, tipo_recorrencia_id=<QA_TIPO_ID>)
-- não existe em tipos_recorrencia (o <QA_TIPO_ID> real pertence à Mori).
insert into public.ciclos_recorrencia (
  clinica_id, paciente_id, tipo_recorrencia_id, data_inicio, proximo_retorno, created_by, updated_by
) values (
  '<QA_CLINICA_B_ID>', '<QA_PACIENTE_ID>', '<QA_TIPO_ID>', current_date, current_date + 30,
  '<QA_PROFILE_B_ID>', '<QA_PROFILE_B_ID>'
);
-- Esperado: erro de violação de FK (insert or update on table
-- "ciclos_recorrencia" violates foreign key constraint
-- "ciclos_recorrencia_tipo_fk").

-- Tentativa 2: retorno da Clínica B apontando para um ciclo real da
-- Mori (<QA_CICLO_ID>, já finalizado acima) — a FK tripla
-- retornos_recorrencia_ciclo_fk deve rejeitar pelo mesmo motivo.
insert into public.retornos_recorrencia (
  clinica_id, ciclo_id, paciente_id, data_retorno_realizado, proximo_retorno_definido, usuario_id
) values (
  '<QA_CLINICA_B_ID>', '<QA_CICLO_ID>', '<QA_PACIENTE_ID>', current_date, current_date + 30, '<QA_PROFILE_B_ID>'
);
-- Esperado: erro de violação de FK (retornos_recorrencia_ciclo_fk).

rollback;
-- Desfaz TUDO deste bloco — nenhuma clínica, profile, tipo ou tentativa
-- de insert cruzado permanece no banco depois daqui.

-- ---- 10) LIMPEZA dos registros QA restantes (fora de qualquer
--           simulação de authenticated — contexto administrativo) ----
delete from public.retornos_recorrencia
  where paciente_id in (select id from public.pacientes where nome ilike 'QA RECORRENCIA%');
delete from public.ciclos_recorrencia
  where paciente_id in (select id from public.pacientes where nome ilike 'QA RECORRENCIA%');
delete from public.pacientes where nome ilike 'QA RECORRENCIA%';
delete from public.tipos_recorrencia where nome ilike 'QA TIPO RECORRENCIA%';

-- ---- 11) Confirmações finais ----
select count(*) as total_qa_recorrencia_restante
from public.pacientes where nome ilike 'QA RECORRENCIA%';
-- Esperado: 0.
select count(*) as total_ciclos_orfaos
from public.ciclos_recorrencia cr
where not exists (select 1 from public.pacientes p where p.id = cr.paciente_id);
-- Esperado: 0 (nenhum ciclo órfão — a FK composta já impediria isso
-- estruturalmente, mas confirmar reforça).
select count(*) as total_clinicas
from public.clinicas where nome ilike 'QA CLINICA%';
-- Esperado: 0 (o bloco 9 usou ROLLBACK, não deveria ter sobrado nada).
