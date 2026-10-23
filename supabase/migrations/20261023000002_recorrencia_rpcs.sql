-- ============================================================
-- Módulo de Recorrência de Pacientes — RPCs
-- ------------------------------------------------------------
-- NÃO EXECUTAR ainda — aguardando o operador rodar manualmente no SQL
-- Editor do projeto Supabase da Mori Ortodontia (rynlzkdqxbzwcznufnpn),
-- DEPOIS de 20261023000000_clinicas_timezone.sql e
-- 20261023000001_recorrencia_schema.sql (esta migration depende das
-- tabelas criadas lá — em particular, depende de ciclos_recorrencia e
-- retornos_recorrencia NÃO concederem INSERT/UPDATE para authenticated,
-- só SELECT). Esta sessão não tem credenciais de banco para aplicar
-- automaticamente.
--
-- ------------------------------------------------------------
-- Estratégia escolhida para impedir bypass das regras de negócio
-- ------------------------------------------------------------
-- Problema identificado na revisão: com `ciclos_recorrencia`/
-- `retornos_recorrencia` concedendo INSERT/UPDATE para `authenticated`
-- (mesmo com RLS escopada por clínica), um cliente autenticado
-- conseguiria, tecnicamente, fazer
--   UPDATE ciclos_recorrencia SET proximo_retorno = X WHERE id = ...
-- direto, sem passar por registrar_retorno_recorrencia — alterando a
-- próxima data sem a linha correspondente em retornos_recorrencia.
-- RLS escopada por clínica protege ISOLAMENTO MULTI-TENANT, mas nunca
-- protegeu REGRA DE NEGÓCIO ("só pode mudar proximo_retorno junto com
-- um retorno novo no histórico") — isso não é algo que GRANT+policy
-- consiga expressar, não importa como a policy seja escrita.
--
-- Solução adotada (ver 20261023000001_recorrencia_schema.sql): o GRANT
-- de INSERT/UPDATE em ciclos_recorrencia e de INSERT em
-- retornos_recorrencia foi REMOVIDO para `authenticated` — resta
-- SOMENTE SELECT nas duas tabelas. Ou seja, não existe MAIS NENHUM
-- caminho de permissão para escrever nessas tabelas além do que está
-- documentado aqui. Isso exige que as RPCs de escrita consigam gravar
-- mesmo sem esse GRANT — por isso, e só para essa necessidade
-- pontual, 3 funções auxiliares (`internal.*_core`, uma por operação de
-- escrita) usam `security definer`.
--
-- Por que SECURITY DEFINER aqui é deliberado, não um atalho para um
-- erro de permissão:
-- 1) Sem GRANT de INSERT/UPDATE para authenticated nas tabelas, a ÚNICA
--    forma de uma função ainda conseguir escrever é rodar com o
--    privilégio de outro papel — SECURITY DEFINER é literalmente o
--    mecanismo do Postgres para isso, não uma forma de "contornar" a
--    falta de GRANT por acidente: é a peça que FAZ a tabela ficar
--    gravável apenas através de um caminho controlado.
-- 2) O preço de SECURITY DEFINER é que a função passa a rodar com os
--    privilégios do DONO (tipicamente `postgres` no Supabase, que tem
--    `BYPASSRLS` — ver passo 0 do roteiro para confirmar isso no
--    projeto real) — ou seja, RLS deixa de filtrar o que a função můé
--    ver/escrever. Por isso cada função `*_core` abaixo:
--      a) NUNCA aceita `clinica_id` do navegador — só recebe
--         `p_clinica_id` já resolvido por quem a chama (o wrapper
--         público, que derivou isso de auth.uid() -> profiles);
--      b) filtra EXPLICITAMENTE por `clinica_id = p_clinica_id` em todo
--         UPDATE/SELECT que faz, dentro do próprio corpo — nunca confia
--         que "o caller já validou" sem repetir o filtro na escrita em
--         si (defesa em profundidade: mesmo que o wrapper tivesse um
--         bug, a escrita em si ainda rejeitaria um ciclo de outra
--         clínica, porque a cláusula WHERE não encontraria a linha);
--      c) usa `set search_path = ''` (mesmo padrão de toda função deste
--         projeto) — todo nome é schema-qualificado, elimina o risco
--         clássico de sequestro de search_path em funções DEFINER;
--      d) é criada em `internal` (não exposto pelo PostgREST — ver
--         seção abaixo) sempre que a função não precisa ser chamada
--         diretamente pelo frontend;
--      e) tem EXECUTE concedido SOMENTE para `authenticated` (nunca
--         anon/public, nunca service_role exposto) — e mesmo assim só é
--         alcançável de fato através do wrapper público auditado, nunca
--         via `supabase.rpc()` direto (schema não exposto).
-- 3) Nenhuma função pública (`iniciar_ciclo_recorrencia`,
--    `registrar_retorno_recorrencia`, `finalizar_ciclo_recorrencia`,
--    `criar_paciente_com_procedimentos`) muda de SECURITY DEFINER —
--    todas continuam `security invoker`, exatamente como antes. Isso
--    mantém o "raio de alcance" do privilégio elevado restrito ao
--    menor código possível: só os 3 `internal.*_core` (um
--    INSERT/validação, um INSERT+UPDATE atômico, um UPDATE), nunca as
--    funções inteiras que fazem autenticação/validação de negócio. A
--    resolução de auth.uid()/profile/clínica, a checagem de
--    "ciclo está ativo?", a validação de motivo de encerramento etc.
--    continuam 100% em funções SECURITY INVOKER, rodando com o
--    privilégio real do usuário autenticado — só a gravação final passa
--    pelo núcleo privilegiado, e esse núcleo nunca pula a filtragem por
--    clínica.
-- 4) Alternativas consideradas e descartadas:
--    - Trigger com uma GUC de sessão como "flag de confiança" (ex.: a
--      RPC roda `set_config('app.via_rpc','true',true)` antes de
--      escrever, e um trigger BEFORE INSERT/UPDATE rejeita quando a flag
--      não está setada): descartada por ser mais frágil e menos auditável
--      que remover o GRANT — depende de toda RPC lembrar de setar a
--      flag corretamente, e uma falha nesse detalhe reabre o bypass
--      silenciosamente. Revogar o GRANT falha de forma mais óbvia
--      (erro de permissão imediato) e não depende de nenhuma disciplina
--      adicional em cada função nova que vier a escrever nestas tabelas.
--    - Manter GRANT direto + confiar só em treinamento/documentação para
--      "sempre usar a RPC": é exatamente o que causou o problema
--      identificado nesta revisão — não resolve nada.
--    - Duplicar toda a lógica de autenticação dentro do núcleo DEFINER
--      (ao invés de confiar nos parâmetros já resolvidos pelo wrapper):
--      rejeitada para não duplicar lógica (princípio já estabelecido
--      neste projeto) — o núcleo não é alcançável de nenhuma forma
--      externa ao wrapper (nem via API, por estar em `internal`; nem via
--      GRANT direto, porque authenticated só o alcança durante a
--      execução já iniciada pelo wrapper SECURITY INVOKER, que já correu
--      sua própria resolução de auth.uid()).
--
-- ------------------------------------------------------------
-- Schema `internal` — não exposto pelo PostgREST (mantido da versão
-- anterior desta migration)
-- ------------------------------------------------------------
-- Por padrão, Supabase expõe só o schema `public` via API/RPC
-- (Dashboard > Settings > API > "Exposed schemas"). Uma função dentro de
-- `internal` pode ter EXECUTE concedido para `authenticated` (necessário
-- para a cadeia de chamada funcionar, já que os wrappers públicos
-- continuam SECURITY INVOKER e chamam o núcleo ainda como
-- `authenticated`), mas `supabase.rpc('...core')` do navegador nunca
-- encontra esse nome — o PostgREST nem considera o schema `internal` ao
-- resolver uma chamada de RPC. Isso restringe a API pública de verdade
-- (na camada que o frontend realmente usa); GRANT/RLS continuam sendo a
-- autoridade real para quem já está dentro do banco (ex.: alguém com a
-- service_role key, ou conexão direta ao Postgres) — por isso o núcleo
-- ainda valida tenant explicitamente, nunca dependendo só de estar
-- "escondido".
--
-- IMPORTANTE — dependência a confirmar: esta solução pressupõe que o
-- projeto expõe só o schema `public` via API. O roteiro de verificação
-- abaixo (passo 0) confirma isso. Mesmo que essa premissa falhe algum
-- dia, a filtragem explícita por clinica_id dentro de cada `*_core`
-- continua sendo uma segunda camada de proteção — ninguém de outra
-- clínica teria uma gravação aceita, só alcançaria a função.
-- ============================================================

begin;

create schema if not exists internal;

revoke all on schema internal from public, anon;
grant usage on schema internal to authenticated;

comment on schema internal is
  'Núcleos privilegiados (security definer) de escrita do Módulo de Recorrência, NUNCA expostos via supabase.rpc() — o PostgREST só expõe o schema public por padrão. Ver comentário no topo de 20261023000002_recorrencia_rpcs.sql para a justificativa completa de por que são security definer e como o tenant é validado dentro de cada um.';

-- ------------------------------------------------------------
-- Núcleo 1: iniciar um ciclo — valida tipo + insere.
-- SECURITY DEFINER: só assim consegue INSERT em ciclos_recorrencia,
-- já que authenticated não tem mais esse GRANT (ver schema migration).
-- Recebe clinica_id/profile_id JÁ resolvidos pelo chamador (nunca
-- resolve auth.uid() de novo aqui — quem faz isso são os wrappers
-- públicos iniciar_ciclo_recorrencia e criar_paciente_com_procedimentos,
-- ambos security invoker, rodando com o privilégio real de quem chamou).
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
security definer
set search_path = ''
as $$
declare
  v_resultado public.ciclos_recorrencia;
begin
  if p_tipo_recorrencia_id is null or p_data_inicio is null or p_proximo_retorno is null then
    raise exception 'Tipo de recorrência, data de início e próximo retorno são obrigatórios.';
  end if;

  -- Validação de tenant EXPLÍCITA dentro do núcleo privilegiado — nunca
  -- confia que "quem chamou já validou isso", mesmo sendo verdade nos
  -- dois chamadores atuais. Como esta função roda com privilégio do
  -- dono (bypassa RLS), esta linha É a proteção real contra um tipo de
  -- outra clínica, não a RLS de tipos_recorrencia.
  if not exists (
    select 1 from public.tipos_recorrencia
    where id = p_tipo_recorrencia_id and clinica_id = p_clinica_id and ativo = true
  ) then
    raise exception 'Tipo de recorrência inválido, inativo ou de outra clínica.';
  end if;

  -- Se já existir ciclo ATIVO para este paciente, o índice único
  -- parcial ciclos_recorrencia_um_ativo_por_paciente rejeita o INSERT
  -- abaixo com unique_violation (SQLSTATE 23505) — a garantia real é o
  -- índice, não uma checagem aqui. A FK composta (clinica_id,
  -- paciente_id) -> pacientes(clinica_id,id) também rejeita
  -- estruturalmente um paciente de outra clínica, mesmo sob DEFINER.
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
-- Núcleo 2: registrar um retorno — insere histórico + atualiza o ciclo,
-- ATOMICAMENTE (mesma função = mesma transação; se uma etapa falhar, a
-- outra é desfeita junto). SECURITY DEFINER pelo mesmo motivo do núcleo
-- 1. Recebe tudo já validado/resolvido pelo wrapper público
-- registrar_retorno_recorrencia (clinica_id, paciente_id do ciclo e
-- profile_id de quem está chamando).
-- ------------------------------------------------------------
create or replace function internal.registrar_retorno_recorrencia_core(
  p_clinica_id uuid,
  p_ciclo_id uuid,
  p_paciente_id uuid,
  p_data_retorno_realizado date,
  p_proximo_retorno date,
  p_observacao text,
  p_profile_id uuid
)
returns public.ciclos_recorrencia
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_resultado public.ciclos_recorrencia;
begin
  -- 1) Insere o retorno no histórico (nunca sobrescreve os anteriores).
  insert into public.retornos_recorrencia (
    clinica_id, ciclo_id, paciente_id,
    data_retorno_realizado, proximo_retorno_definido, observacao, usuario_id
  ) values (
    p_clinica_id, p_ciclo_id, p_paciente_id,
    p_data_retorno_realizado, p_proximo_retorno, p_observacao, p_profile_id
  );

  -- 2) Atualiza SOMENTE o próximo retorno + auditoria do ciclo — filtro
  --    EXPLÍCITO por clinica_id também aqui (defesa em profundidade: se
  --    por algum motivo p_ciclo_id não pertencesse a p_clinica_id, este
  --    UPDATE não encontraria a linha, em vez de silenciosamente afetar
  --    o ciclo errado). Se este UPDATE não encontrar nada, o INSERT
  --    acima também é desfeito (rollback automático da função inteira)
  --    — nunca fica um retorno "órfão" sem o ciclo ter sido atualizado.
  update public.ciclos_recorrencia set
    proximo_retorno = p_proximo_retorno,
    updated_at = now(),
    updated_by = p_profile_id
  where id = p_ciclo_id and clinica_id = p_clinica_id
  returning * into v_resultado;

  if v_resultado.id is null then
    raise exception 'Falha ao atualizar o ciclo de recorrência — ciclo não encontrado para esta clínica.';
  end if;

  return v_resultado;
end;
$$;

revoke all on function internal.registrar_retorno_recorrencia_core(uuid,uuid,uuid,date,date,text,uuid) from public, anon;
grant execute on function internal.registrar_retorno_recorrencia_core(uuid,uuid,uuid,date,date,text,uuid) to authenticated;

-- ------------------------------------------------------------
-- Núcleo 3: finalizar um ciclo. SECURITY DEFINER pelo mesmo motivo.
-- Grava a observação de encerramento em `observacao_encerramento`
-- (NUNCA em `observacoes`, que é a observação geral/original do ciclo e
-- não deve ser alterada por este fluxo).
-- ------------------------------------------------------------
create or replace function internal.finalizar_ciclo_recorrencia_core(
  p_clinica_id uuid,
  p_ciclo_id uuid,
  p_data_encerramento date,
  p_motivo_encerramento text,
  p_observacao_encerramento text,
  p_profile_id uuid
)
returns public.ciclos_recorrencia
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_resultado public.ciclos_recorrencia;
begin
  update public.ciclos_recorrencia set
    status = 'finalizado',
    data_encerramento = p_data_encerramento,
    motivo_encerramento = p_motivo_encerramento,
    observacao_encerramento = p_observacao_encerramento,
    updated_at = now(),
    updated_by = p_profile_id
  where id = p_ciclo_id and clinica_id = p_clinica_id
  returning * into v_resultado;

  if v_resultado.id is null then
    raise exception 'Falha ao finalizar o ciclo de recorrência — ciclo não encontrado para esta clínica.';
  end if;

  return v_resultado;
end;
$$;

revoke all on function internal.finalizar_ciclo_recorrencia_core(uuid,uuid,date,text,text,uuid) from public, anon;
grant execute on function internal.finalizar_ciclo_recorrencia_core(uuid,uuid,date,text,text,uuid) to authenticated;

-- ------------------------------------------------------------
-- RPC pública 1: iniciar_ciclo_recorrencia — paciente JÁ EXISTENTE
-- (fluxo B: não atomiza com edição geral do paciente). SECURITY
-- INVOKER — sem mudança de tipo de segurança; a única diferença desta
-- revisão é que o núcleo que ela chama agora grava mesmo sem GRANT
-- direto na tabela.
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
-- RPC pública 2: registrar_retorno_recorrencia. SECURITY INVOKER — toda
-- a resolução de auth/validação de negócio (ciclo existe? está ativo?)
-- continua rodando com o privilégio real do usuário, via SELECT
-- filtrado pela RLS de select_ciclos_recorrencia. Só a gravação final
-- (insert + update atômicos) passa para o núcleo privilegiado.
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

  return internal.registrar_retorno_recorrencia_core(
    v_clinica_id, p_ciclo_id, v_ciclo.paciente_id,
    p_data_retorno_realizado, p_proximo_retorno, p_observacao, v_profile_id
  );
end;
$$;

revoke all on function public.registrar_retorno_recorrencia(uuid,date,date,text) from public, anon;
grant execute on function public.registrar_retorno_recorrencia(uuid,date,date,text) to authenticated;

-- ------------------------------------------------------------
-- RPC pública 3: finalizar_ciclo_recorrencia. SECURITY INVOKER, mesmo
-- raciocínio de registrar_retorno_recorrencia acima.
--
-- [Revisão] p_observacao renomeado para p_observacao_encerramento —
-- grava em ciclos_recorrencia.observacao_encerramento, NUNCA em
-- observacoes (observação geral/original do ciclo, preservada
-- intacta). Quando motivo = 'Outro', a observação de encerramento
-- passa a ser obrigatória — validado aqui (mensagem amigável) E também
-- protegido na tabela por
-- ciclos_recorrencia_observacao_encerramento_outro_check (defesa em
-- profundidade, mesmo padrão já usado para o check de motivo).
-- ------------------------------------------------------------
create or replace function public.finalizar_ciclo_recorrencia(
  p_ciclo_id uuid,
  p_data_encerramento date,
  p_motivo_encerramento text,
  p_observacao_encerramento text default null
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

  -- [Revisão] "Outro" exige observação de encerramento preenchida —
  -- mesma regra do check ciclos_recorrencia_observacao_encerramento_outro_check,
  -- validada aqui também só para dar uma mensagem amigável antes de
  -- chegar no banco.
  if p_motivo_encerramento = 'Outro'
     and (p_observacao_encerramento is null or btrim(p_observacao_encerramento) = '') then
    raise exception 'Ao selecionar "Outro" como motivo, é obrigatório informar uma observação de encerramento.';
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

  return internal.finalizar_ciclo_recorrencia_core(
    v_clinica_id, p_ciclo_id, p_data_encerramento, p_motivo_encerramento,
    p_observacao_encerramento, v_profile_id
  );
end;
$$;

revoke all on function public.finalizar_ciclo_recorrencia(uuid,date,text,text) from public, anon;
grant execute on function public.finalizar_ciclo_recorrencia(uuid,date,text,text) to authenticated;

-- ------------------------------------------------------------
-- Extensão de criar_paciente_com_procedimentos (Novo Paciente + primeira
-- recorrência, ATÔMICO). SEM NENHUMA MUDANÇA nesta revisão — continua
-- SECURITY INVOKER, chamando internal.iniciar_ciclo_recorrencia_core()
-- exatamente como antes. A única diferença é que esse núcleo agora é
-- SECURITY DEFINER (acima), o que esta função nem precisa saber: ela só
-- chama a mesma assinatura de sempre, e passa a funcionar mesmo sem
-- authenticated ter GRANT de INSERT em ciclos_recorrencia.
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
-- nenhuma necessidade técnica inevitável foi encontrada. Paciente
-- existente usa iniciar_ciclo_recorrencia, isolada.

commit;

-- ============================================================
-- ROTEIRO COMPLETO DE HOMOLOGAÇÃO (rodar manualmente no SQL Editor,
-- NESTA ORDEM, usando EXCLUSIVAMENTE registros QA — nunca pacientes
-- reais). Ajustar <UID_VITOR> para o auth.uid() real do Vitor (admin
-- ativo da Mori) antes de rodar. Todos os blocos abaixo limpam os
-- próprios dados de teste ao final, exceto onde indicado.
-- ============================================================

-- ---- 0) Confirmar que o schema `internal` NÃO é exposto pela API, e
--          que o dono das funções tem BYPASSRLS (pré-requisito para o
--          SECURITY DEFINER funcionar como descrito) ----
show pgrst.db_schemas;
-- Esperado: o valor não deve listar "internal" (só "public", ou
-- "public, graphql_public", conforme o padrão do projeto).

select r.rolname, r.rolbypassrls
from pg_proc p
join pg_roles r on r.oid = p.proowner
where p.pronamespace = 'internal'::regnamespace
  and p.proname = 'iniciar_ciclo_recorrencia_core';
-- Esperado: rolbypassrls = true (normalmente a role `postgres`, dona de
-- tudo que é criado via SQL Editor no Supabase). Se for false, o
-- SECURITY DEFINER aqui NÃO bypassa RLS sozinho — avisar antes de
-- prosseguir, pois a arquitetura descrita no topo deste arquivo
-- pressupõe que bypassa.

-- ---- 1) Confirmar RPCs/núcleos e seus grants (authenticated sim,
--          anon/public não) ----
select p.proname,
       pg_get_function_identity_arguments(p.oid) as argumentos,
       p.prosecdef as security_definer,
       has_function_privilege('authenticated', p.oid, 'execute') as authenticated_pode,
       has_function_privilege('anon', p.oid, 'execute') as anon_pode
from pg_proc p
where p.pronamespace = 'public'::regnamespace
  and p.proname in ('iniciar_ciclo_recorrencia','registrar_retorno_recorrencia','finalizar_ciclo_recorrencia','criar_paciente_com_procedimentos');
-- Esperado: as 4 com security_definer=false (continuam invoker),
-- authenticated_pode=true, anon_pode=false. criar_paciente_com_procedimentos
-- deve aparecer com a NOVA assinatura (25 argumentos).

select p.proname, p.prosecdef as security_definer,
       has_function_privilege('authenticated', p.oid, 'execute') as authenticated_pode,
       has_function_privilege('anon', p.oid, 'execute') as anon_pode
from pg_proc p
where p.pronamespace = 'internal'::regnamespace
  and p.proname in ('iniciar_ciclo_recorrencia_core','registrar_retorno_recorrencia_core','finalizar_ciclo_recorrencia_core');
-- Esperado: as 3 com security_definer=true, authenticated_pode=true,
-- anon_pode=false. O passo 0 é quem garante que isso não é alcançável
-- via API mesmo com authenticated_pode=true.

-- ---- 2) Confirmar que NENHUM grant de INSERT/UPDATE existe para
--          authenticated nas tabelas (pré-requisito desta revisão) ----
select table_name, privilege_type
from information_schema.role_table_grants
where table_schema='public'
  and table_name in ('ciclos_recorrencia','retornos_recorrencia')
  and grantee='authenticated';
-- Esperado: SOMENTE linhas com privilege_type='SELECT', uma por tabela.
-- Nenhuma linha INSERT/UPDATE/DELETE.

set local role authenticated;
set local request.jwt.claims = '{"sub":"<UID_VITOR>","role":"authenticated"}';

-- ---- 3) TESTE DE REGRESSÃO (I) — criação normal de paciente SEM
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

-- ---- 4) TESTE DE ATOMICIDADE (J) — Novo Paciente + recorrência, com um
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
-- parcialmente — rollback completo da transação, mesmo com o núcleo
-- de recorrência agora sendo security definer).

-- ---- 5) TESTE DE ATOMICIDADE (J, caminho feliz) — Novo Paciente +
--          recorrência com um tipo_recorrencia_id REAL ----
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

-- ---- 6) TESTE: impedir DOIS ciclos ativos para o mesmo paciente ----
select * from public.iniciar_ciclo_recorrencia(
  p_paciente_id := '<QA_PACIENTE_ID>',
  p_tipo_recorrencia_id := '<QA_TIPO_ID>',
  p_data_inicio := current_date,
  p_proximo_retorno := current_date + 60
);
-- Esperado: erro de violação de unicidade (o índice único parcial
-- ciclos_recorrencia_um_ativo_por_paciente rejeita — este paciente já
-- tem um ciclo ativo do passo 5).
select count(*) from public.ciclos_recorrencia
  where paciente_id = '<QA_PACIENTE_ID>' and status = 'ativo';
-- Esperado: continua 1 (não virou 2).

select id, proximo_retorno from public.ciclos_recorrencia where paciente_id = '<QA_PACIENTE_ID>' and status='ativo';
-- Guardar o id retornado como <QA_CICLO_ID>.

-- ---- 7) TESTE A — usuário authenticated NÃO consegue alterar
--          diretamente proximo_retorno, contornando o histórico ----
update public.ciclos_recorrencia set proximo_retorno = current_date + 9999 where id = '<QA_CICLO_ID>';
-- Esperado: erro de permissão ("permission denied for table
-- ciclos_recorrencia") — sem GRANT de UPDATE, não existe policy que
-- importe.
select proximo_retorno from public.ciclos_recorrencia where id = '<QA_CICLO_ID>';
-- Esperado: ainda current_date + 30 (valor do passo 5), não foi alterado.

-- ---- 7b) TESTE D — usuário authenticated NÃO consegue finalizar um
--           ciclo por escrita direta ----
update public.ciclos_recorrencia set status = 'finalizado', data_encerramento = current_date, motivo_encerramento = 'Tratamento concluído' where id = '<QA_CICLO_ID>';
-- Esperado: erro de permissão, mesmo motivo do teste A.
select status from public.ciclos_recorrencia where id = '<QA_CICLO_ID>';
-- Esperado: ainda 'ativo'.

-- ---- 7c) complemento do teste A/D — INSERT direto em
--           retornos_recorrencia também deve falhar (fabricar histórico
--           sem passar pela RPC) ----
insert into public.retornos_recorrencia (
  clinica_id, ciclo_id, paciente_id, data_retorno_realizado, proximo_retorno_definido, usuario_id
) values (
  (select clinica_id from public.ciclos_recorrencia where id='<QA_CICLO_ID>'),
  '<QA_CICLO_ID>', '<QA_PACIENTE_ID>', current_date, current_date + 30,
  (select id from public.profiles where auth_user_id='<UID_VITOR>')
);
-- Esperado: erro de permissão ("permission denied for table retornos_recorrencia").

-- ---- 8) TESTE B/C — registrar_retorno_recorrencia continua
--          funcionando normalmente, e atomicamente: histórico novo +
--          proximo_retorno atualizado, as duas coisas juntas ----
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
-- Esperado: 2 (histórico novo criado nas duas chamadas, nenhuma linha
-- anterior sobrescrita).
select proximo_retorno from public.ciclos_recorrencia where id = '<QA_CICLO_ID>';
-- Esperado: current_date + 60 (atualizado corretamente, mesma chamada
-- que criou o histórico — prova a atomicidade insert+update).

-- ---- 9) TESTE append-only (reforço) — UPDATE/DELETE direto em
--          retornos_recorrencia continua rejeitado ----
update public.retornos_recorrencia set observacao = 'tentativa de alterar histórico' where ciclo_id = '<QA_CICLO_ID>';
delete from public.retornos_recorrencia where ciclo_id = '<QA_CICLO_ID>';
-- Esperado (ambos): erro de permissão.
select observacao from public.retornos_recorrencia where ciclo_id = '<QA_CICLO_ID>' order by created_at;
-- Esperado: ainda 'primeiro retorno QA' e 'segundo retorno QA', intactas.

-- ---- 10) TESTE E/F/G — Finalizar recorrência: funciona, preserva
--           `observacoes` original, grava `observacao_encerramento`
--           separadamente ----
-- Primeiro, registra uma observação GERAL no ciclo (simulando que já
-- existia antes do encerramento) — via UPDATE direto só é possível
-- porque estamos fora da role authenticated aqui (ver linha abaixo);
-- em produção esse campo seria preenchido por um fluxo futuro de
-- edição do ciclo, fora do escopo desta entrega.
reset role;
update public.ciclos_recorrencia set observacoes = 'observação geral original do ciclo' where id = '<QA_CICLO_ID>';
set local role authenticated;
set local request.jwt.claims = '{"sub":"<UID_VITOR>","role":"authenticated"}';

select * from public.finalizar_ciclo_recorrencia(
  p_ciclo_id := '<QA_CICLO_ID>',
  p_data_encerramento := current_date,
  p_motivo_encerramento := 'Tratamento concluído',
  p_observacao_encerramento := 'observação específica do encerramento'
);
select status, data_encerramento, motivo_encerramento, observacoes, observacao_encerramento
from public.ciclos_recorrencia where id = '<QA_CICLO_ID>';
-- Esperado: status='finalizado'; observacoes ainda
-- 'observação geral original do ciclo' (INTACTA, não sobrescrita);
-- observacao_encerramento='observação específica do encerramento'.

-- ---- 10b) TESTE da constraint nova — motivo='Outro' sem observação de
--            encerramento deve ser rejeitado, tanto pela RPC quanto
--            (se alguém tentasse via UPDATE direto, hipoteticamente)
--            pela constraint da tabela ----
select * from public.iniciar_ciclo_recorrencia(
  p_paciente_id := '<QA_PACIENTE_ID>',
  p_tipo_recorrencia_id := '<QA_TIPO_ID>',
  p_data_inicio := current_date,
  p_proximo_retorno := current_date + 90
);
-- Novo ciclo criado (o anterior já está finalizado) -- guardar como <QA_CICLO_2_ID>.

select * from public.finalizar_ciclo_recorrencia(
  p_ciclo_id := '<QA_CICLO_2_ID>',
  p_data_encerramento := current_date,
  p_motivo_encerramento := 'Outro',
  p_observacao_encerramento := null
);
-- Esperado: erro "Ao selecionar \"Outro\" como motivo, é obrigatório
-- informar uma observação de encerramento." (rejeitado pela RPC antes
-- de chegar no banco).

select * from public.finalizar_ciclo_recorrencia(
  p_ciclo_id := '<QA_CICLO_2_ID>',
  p_data_encerramento := current_date,
  p_motivo_encerramento := 'Outro',
  p_observacao_encerramento := 'motivo não listado: paciente mudou de cidade'
);
-- Esperado: sucesso desta vez (observação de encerramento preenchida).

reset role;

-- ---- 11) TESTE H — isolamento entre clínicas continua funcionando
--           (bloco autocontido, SEMPRE termina em ROLLBACK). Usa
--           SAVEPOINT para testar as duas FKs separadamente mesmo que a
--           primeira tentativa aborte a sub-transação. ----
begin;

insert into public.clinicas (nome, cidade, timezone)
  values ('QA CLINICA ISOLAMENTO - rollback', 'Teste', 'America/Sao_Paulo')
  returning id;
-- Guardar como <QA_CLINICA_B_ID> (só existe dentro desta transação).

insert into public.profiles (clinica_id, nome, cargo, role, ativo, auth_user_id)
  values ('<QA_CLINICA_B_ID>', 'QA Profile Clinica B', 'Teste', 'admin', true, gen_random_uuid())
  returning id;
-- Guardar como <QA_PROFILE_B_ID>.

savepoint antes_tentativa_1;
insert into public.ciclos_recorrencia (
  clinica_id, paciente_id, tipo_recorrencia_id, data_inicio, proximo_retorno, created_by, updated_by
) values (
  '<QA_CLINICA_B_ID>', '<QA_PACIENTE_ID>', '<QA_TIPO_ID>', current_date, current_date + 30,
  '<QA_PROFILE_B_ID>', '<QA_PROFILE_B_ID>'
);
-- Esperado: erro de FK (ciclos_recorrencia_paciente_fk ou _tipo_fk,
-- a que o Postgres avaliar primeiro — ambas impedem, o que importa é
-- que uma delas rejeita).
rollback to savepoint antes_tentativa_1;

savepoint antes_tentativa_2;
insert into public.retornos_recorrencia (
  clinica_id, ciclo_id, paciente_id, data_retorno_realizado, proximo_retorno_definido, usuario_id
) values (
  '<QA_CLINICA_B_ID>', '<QA_CICLO_ID>', '<QA_PACIENTE_ID>', current_date, current_date + 30, '<QA_PROFILE_B_ID>'
);
-- Esperado: erro de FK (retornos_recorrencia_ciclo_fk) — a clinica_id
-- errada por si só já quebra a FK tripla, mesmo com ciclo/paciente
-- reais e corretamente pareados.
rollback to savepoint antes_tentativa_2;

rollback;
-- Desfaz TUDO deste bloco — nenhuma clínica, profile ou tentativa de
-- insert cruzado permanece no banco depois daqui.

select count(*) as deve_ser_zero_clinicas_qa from public.clinicas where nome ilike 'QA CLINICA%';

-- ---- 12) LIMPEZA dos registros QA restantes (fora de qualquer
--           simulação de authenticated — contexto administrativo) ----
delete from public.retornos_recorrencia
  where paciente_id in (select id from public.pacientes where nome ilike 'QA RECORRENCIA%');
delete from public.ciclos_recorrencia
  where paciente_id in (select id from public.pacientes where nome ilike 'QA RECORRENCIA%');
delete from public.pacientes where nome ilike 'QA RECORRENCIA%';
delete from public.tipos_recorrencia where nome ilike 'QA TIPO RECORRENCIA%';

-- ---- 13) Confirmações finais ----
select count(*) as total_qa_recorrencia_restante
from public.pacientes where nome ilike 'QA RECORRENCIA%';
-- Esperado: 0.
select count(*) as total_ciclos_orfaos
from public.ciclos_recorrencia cr
where not exists (select 1 from public.pacientes p where p.id = cr.paciente_id);
-- Esperado: 0 (nenhum ciclo órfão — a FK composta já impediria isso
-- estruturalmente, mas confirmar reforça).
select count(*) as total_clinicas_qa
from public.clinicas where nome ilike 'QA CLINICA%';
-- Esperado: 0 (o bloco 11 usou ROLLBACK, não deveria ter sobrado nada).
