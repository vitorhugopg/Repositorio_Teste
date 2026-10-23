-- ============================================================
-- Fase B (preparação) — Endurecimento de segurança de public.indicacoes
-- ------------------------------------------------------------
-- NÃO EXECUTAR ainda — aguardando o operador rodar manualmente no SQL
-- Editor do projeto Supabase da Mori Ortodontia (rynlzkdqxbzwcznufnpn),
-- DEPOIS de todas as migrations anteriores (em particular as de
-- Recorrência, que criam o schema `internal` reaproveitado aqui). Esta
-- sessão não tem credenciais de banco para aplicar automaticamente.
--
-- Escopo desta migration: SOMENTE banco (grants, RLS, constraints, RPC).
-- Nenhuma alteração de frontend — index.html não é tocado nesta rodada;
-- renderIndicacoes()/renderGraficoTipoIndicador()/bindIndicacoesEvents()
-- continuam usando DB.indicacoes local (array vazio em modo Supabase,
-- comportamento inalterado) até a Fase B2.
--
-- ------------------------------------------------------------
-- Contexto (auditoria real já feita pelo usuário, não por esta sessão)
-- ------------------------------------------------------------
-- public.indicacoes hoje: id uuid PK; clinica_id uuid (FK clinicas);
-- paciente_indicado_id uuid (FK composta (clinica_id,paciente_indicado_id)
-- -> pacientes); indicador_paciente_id uuid nullable (FK composta
-- (clinica_id,indicador_paciente_id) -> pacientes); indicador_nome_externo
-- text nullable; tipo_indicador text nullable; legacy_id text nullable;
-- created_at timestamptz. Checks existentes: num_nonnulls(indicador_
-- paciente_id,indicador_nome_externo) <= 1; tipo_indicador in
-- ('paciente','profissional','outro'); unique (clinica_id,legacy_id).
--
-- 52 registros reais: 21 profissional, 31 outro, 0 paciente; 36 com
-- indicador_nome_externo, 16 sem indicador informado; 0 com
-- indicador_paciente_id. Esta sessão NÃO tem credenciais para consultar
-- o Supabase real diretamente — os números acima vêm da auditoria que o
-- usuário já fez manualmente. Por isso esta migration é AUTO-DEFENSIVA:
-- os blocos `do $$ ... raise exception ... end $$` antes de cada
-- constraint nova abortam a transação inteira (rollback automático, nada
-- fica aplicado pela metade) se os dados reais não baterem com o que foi
-- auditado — não dependemos só do operador conferir antes de rodar.
--
-- Verificação aritmética feita ANTES de propor as regras abaixo: se
-- profissional sempre exige nome (21 registros) e paciente sempre exige
-- indicador_paciente_id (0 registros), sobram 36-21=15 "outro" com nome
-- e 31-15=16 "outro" sem nome — bate exatamente com os "16 sem indicador
-- informado" relatados. Ou seja, a regra de coerência abaixo é
-- compatível com os 52 registros reais pela própria aritmética da
-- auditoria, mas o bloco `do $$` confirma isso contra os dados de
-- verdade no momento em que a migration realmente rodar.
--
-- ------------------------------------------------------------
-- Modelo operacional da V1 (consultar + registrar, nada além disso)
-- ------------------------------------------------------------
-- Sem edição, sem exclusão física, sem reclassificação retroativa dos 52
-- registros, sem backfill, sem heurística de nome (Dr/Dra etc.) — nada
-- disso é implementado aqui nem em nenhuma fase futura prevista. A V1
-- só precisa: SELECT (ver indicações da própria clínica) e um jeito
-- seguro de INSERT (a RPC).
--
-- ------------------------------------------------------------
-- Regra de coerência tipo x indicador (V1)
-- ------------------------------------------------------------
-- paciente:      indicador_paciente_id obrigatório, indicador_nome_externo NULL.
-- profissional:  indicador_nome_externo obrigatório, indicador_paciente_id NULL.
-- outro:         indicador_paciente_id sempre NULL (se tivesse paciente,
--                seria tipo='paciente'); indicador_nome_externo
--                OPCIONAL — preserva de propósito os 16 registros
--                históricos "outro" sem nome. Não criamos uma exigência
--                de nome para "outro" nem no banco nem na RPC: forçar
--                isso tornaria obrigatório inventar um nome genérico
--                sempre que a origem realmente não for identificável,
--                o que seria pior que simplesmente aceitar "outro" sem
--                nome, exatamente como a clínica já vinha fazendo.
--
-- ------------------------------------------------------------
-- Regra de duplicidade (V1)
-- ------------------------------------------------------------
-- unique (clinica_id, paciente_indicado_id) — um paciente só pode ter UMA
-- indicação de origem registrada. Auto-defendida pelo bloco `do $$`
-- abaixo: se os 52 registros reais tiverem qualquer duplicidade no
-- momento de rodar, a migration inteira aborta antes de chegar na
-- criação do constraint.
--
-- ------------------------------------------------------------
-- Estratégia de segurança da escrita (mesmo raciocínio já usado em
-- Recorrência, adaptado — não copiado mecanicamente)
-- ------------------------------------------------------------
-- Grants atuais (auditados pelo usuário): anon E authenticated têm
-- INSERT/UPDATE/DELETE/TRUNCATE/SELECT/REFERENCES/TRIGGER na tabela —
-- um resquício de privilégio padrão de quando a tabela foi criada direto
-- no painel, nunca revisado (mesma situação-raiz que já vimos antes:
-- schema-base não versionado). Isso permite exatamente o que o pedido
-- não quer: DELETE físico, TRUNCATE, e acesso de `anon`.
--
-- Correção: revoga TUDO de `anon`/PUBLIC. `authenticated` passa a ter
-- SOMENTE SELECT direto na tabela — nenhum INSERT/UPDATE/DELETE/
-- TRUNCATE/REFERENCES/TRIGGER. A policy antiga `isolamento_indicacoes`
-- (FOR ALL) é substituída por uma única policy de SELECT escopada por
-- clínica — sem nenhuma policy de INSERT/UPDATE/DELETE (fail closed: se
-- um GRANT fosse reintroduzido por engano no futuro, ainda não haveria
-- policy liberando a escrita).
--
-- Com isso, a única forma de criar uma indicação nova é através de
-- `internal.registrar_indicacao_core` (SECURITY DEFINER — mesmo
-- schema `internal` já usado por Recorrência, não exposto pelo
-- PostgREST) chamada por `public.registrar_indicacao` (SECURITY
-- INVOKER, é o que o frontend chama). O núcleo nunca aceita
-- `clinica_id`/`created_at`/`legacy_id` do navegador — sempre deriva
-- `clinica_id` do profile resolvido via `auth.uid()` pelo wrapper, e
-- revalida `clinica_id` explicitamente em toda consulta/INSERT que faz
-- (defesa em profundidade: mesmo rodando com privilégio do dono e
-- bypassando RLS, nunca confia cegamente no que o wrapper já validou).
-- `search_path=''` em ambas as funções, igual ao padrão do projeto.
-- Avaliei e descartei usar SECURITY DEFINER só na função pública (sem
-- núcleo separado): juntaria autenticação/validação de negócio com o
-- privilégio elevado na mesma função, um raio de alcance maior que o
-- necessário — o padrão de núcleo mínimo mantém o privilégio elevado
-- restrito a uma função pequena e auditável, igual Recorrência.
-- ============================================================

begin;

-- ------------------------------------------------------------
-- 0) Verificações auto-defensivas — abortam a transação inteira (e
--    portanto toda a migration) se os dados reais não baterem com o que
--    foi auditado. Rodar isto é a PRIMEIRA coisa que a migration faz.
-- ------------------------------------------------------------
do $$
declare v_duplicados int;
begin
  select count(*) into v_duplicados from (
    select clinica_id, paciente_indicado_id
    from public.indicacoes
    group by clinica_id, paciente_indicado_id
    having count(*) > 1
  ) dup;
  if v_duplicados > 0 then
    raise exception 'Migration abortada: % paciente(s) com mais de uma indicação registrada — revisar antes de aplicar unique(clinica_id, paciente_indicado_id). Nenhuma alteração foi aplicada.', v_duplicados;
  end if;
end $$;

do $$
declare v_incoerentes int;
begin
  select count(*) into v_incoerentes from public.indicacoes
  where not (
    (tipo_indicador = 'paciente' and indicador_paciente_id is not null and indicador_nome_externo is null)
    or (tipo_indicador = 'profissional' and indicador_nome_externo is not null and indicador_paciente_id is null)
    or (tipo_indicador = 'outro' and indicador_paciente_id is null)
  );
  if v_incoerentes > 0 then
    raise exception 'Migration abortada: % registro(s) incoerentes com a regra tipo x indicador (paciente exige indicador_paciente_id; profissional exige indicador_nome_externo; outro nunca tem indicador_paciente_id) — revisar antes de aplicar o CHECK novo. Nenhuma alteração foi aplicada.', v_incoerentes;
  end if;
end $$;

do $$
declare v_autoindicacao int;
begin
  select count(*) into v_autoindicacao from public.indicacoes
  where indicador_paciente_id is not null and indicador_paciente_id = paciente_indicado_id;
  if v_autoindicacao > 0 then
    raise exception 'Migration abortada: % registro(s) onde o paciente indicado é o próprio indicador — revisar antes de aplicar o CHECK de autoindicação. Nenhuma alteração foi aplicada.', v_autoindicacao;
  end if;
end $$;

-- ------------------------------------------------------------
-- 1) Constraints novas — só chegam aqui se os 3 blocos acima não
--    abortaram a transação.
-- ------------------------------------------------------------
alter table public.indicacoes
  add constraint indicacoes_tipo_indicador_coerencia_check
  check (
    (tipo_indicador = 'paciente' and indicador_paciente_id is not null and indicador_nome_externo is null)
    or (tipo_indicador = 'profissional' and indicador_nome_externo is not null and indicador_paciente_id is null)
    or (tipo_indicador = 'outro' and indicador_paciente_id is null)
  );

alter table public.indicacoes
  add constraint indicacoes_sem_autoindicacao_check
  check (indicador_paciente_id is null or indicador_paciente_id <> paciente_indicado_id);

alter table public.indicacoes
  add constraint indicacoes_paciente_indicado_uniq unique (clinica_id, paciente_indicado_id);

comment on constraint indicacoes_tipo_indicador_coerencia_check on public.indicacoes is
  'V1: paciente exige indicador_paciente_id (sem nome externo); profissional exige indicador_nome_externo (sem indicador_paciente_id); outro nunca tem indicador_paciente_id (nome externo fica opcional, de propósito — preserva os registros históricos "outro" sem nome).';
comment on constraint indicacoes_paciente_indicado_uniq on public.indicacoes is
  'V1: um paciente só pode ter uma indicação de origem registrada por clínica.';

-- ------------------------------------------------------------
-- 2) Grants — princípio de menor privilégio (item 2/8 do pedido)
-- ------------------------------------------------------------
revoke all on public.indicacoes from public, anon;
revoke all on public.indicacoes from authenticated;
grant select on public.indicacoes to authenticated;
-- Deliberadamente SEM insert, update, delete, truncate, references,
-- trigger para authenticated — e SEM NENHUM privilégio para anon. A
-- única forma de criar uma indicação é via RPC (ver seção 4 abaixo).

-- ------------------------------------------------------------
-- 3) RLS — substitui a policy antiga (FOR ALL) por uma única policy de
--    SELECT. Sem policy de INSERT/UPDATE/DELETE: fail closed — mesmo
--    que um GRANT fosse reintroduzido por engano, não há policy que
--    libere a escrita.
-- ------------------------------------------------------------
drop policy if exists "isolamento_indicacoes" on public.indicacoes;

create policy "select_indicacoes" on public.indicacoes
  for select to authenticated
  using (clinica_id in (select public.minhas_clinicas()));

-- ------------------------------------------------------------
-- 4) RPC — núcleo privilegiado mínimo (internal, não exposto pelo
--    PostgREST) + wrapper público (invoker, é o que o frontend chama).
-- ------------------------------------------------------------
create schema if not exists internal;
revoke all on schema internal from public, anon;
grant usage on schema internal to authenticated;

create or replace function internal.registrar_indicacao_core(
  p_clinica_id uuid,
  p_paciente_indicado_id uuid,
  p_tipo_indicador text,
  p_indicador_paciente_id uuid,
  p_indicador_nome_externo text
)
returns public.indicacoes
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_resultado public.indicacoes;
begin
  -- Validação de tenant EXPLÍCITA dentro do núcleo privilegiado — nunca
  -- confia que "quem chamou já validou isso" sozinho, mesmo sendo
  -- verdade no único chamador atual (public.registrar_indicacao). Como
  -- esta função roda com privilégio do dono (bypassa RLS), esta
  -- validação É a proteção real contra um paciente/indicador de outra
  -- clínica, não a RLS de pacientes.
  if not exists (
    select 1 from public.pacientes
    where id = p_paciente_indicado_id and clinica_id = p_clinica_id
  ) then
    raise exception 'Paciente indicado não encontrado ou de outra clínica.';
  end if;

  if p_indicador_paciente_id is not null and not exists (
    select 1 from public.pacientes
    where id = p_indicador_paciente_id and clinica_id = p_clinica_id
  ) then
    raise exception 'Paciente indicador não encontrado ou de outra clínica.';
  end if;

  -- Já existe uma indicação para este paciente? O índice único
  -- (indicacoes_paciente_indicado_uniq) é a garantia real; esta
  -- checagem só devolve uma mensagem amigável antes do erro de
  -- unique_violation.
  if exists (
    select 1 from public.indicacoes
    where clinica_id = p_clinica_id and paciente_indicado_id = p_paciente_indicado_id
  ) then
    raise exception 'Este paciente já possui uma indicação de origem registrada.';
  end if;

  insert into public.indicacoes (
    clinica_id, paciente_indicado_id, indicador_paciente_id, indicador_nome_externo, tipo_indicador
  ) values (
    p_clinica_id, p_paciente_indicado_id, p_indicador_paciente_id, p_indicador_nome_externo, p_tipo_indicador
  )
  returning * into v_resultado;

  return v_resultado;
end;
$$;

revoke all on function internal.registrar_indicacao_core(uuid,uuid,text,uuid,text) from public, anon;
grant execute on function internal.registrar_indicacao_core(uuid,uuid,text,uuid,text) to authenticated;

create or replace function public.registrar_indicacao(
  p_paciente_indicado_id uuid,
  p_tipo_indicador text,
  p_indicador_paciente_id uuid default null,
  p_indicador_nome_externo text default null
)
returns public.indicacoes
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_profile_id uuid;
  v_clinica_id uuid;
  v_paciente public.pacientes%rowtype;
  v_nome_externo text;
begin
  select id, clinica_id into v_profile_id, v_clinica_id
    from public.profiles
    where auth_user_id = auth.uid() and ativo = true
    limit 1;

  if v_profile_id is null then
    raise exception 'Perfil ativo não encontrado para o usuário autenticado.';
  end if;

  if p_tipo_indicador not in ('paciente', 'profissional', 'outro') then
    raise exception 'Tipo de indicador inválido: %', p_tipo_indicador;
  end if;

  -- O SELECT abaixo já é filtrado pela RLS de select_pacientes
  -- (clinica_id in minhas_clinicas()), porque esta função é SECURITY
  -- INVOKER — um paciente de outra clínica simplesmente não é
  -- encontrado. Mesmo idioma já usado em iniciar_ciclo_recorrencia/
  -- atualizar_paciente_com_procedimentos.
  select * into v_paciente from public.pacientes where id = p_paciente_indicado_id;
  if v_paciente.id is null then
    raise exception 'Paciente indicado não encontrado ou sem permissão de acesso.';
  end if;

  v_nome_externo := nullif(btrim(p_indicador_nome_externo), '');

  -- Coerência tipo x indicador — mesma regra protegida no banco
  -- (indicacoes_tipo_indicador_coerencia_check); validar aqui só dá uma
  -- mensagem de erro mais legível antes de chegar no banco.
  if p_tipo_indicador = 'paciente' then
    if p_indicador_paciente_id is null then
      raise exception 'Indicação do tipo "paciente" exige o paciente indicador.';
    end if;
    if v_nome_externo is not null then
      raise exception 'Indicação do tipo "paciente" não deve informar nome externo.';
    end if;
    if p_indicador_paciente_id = p_paciente_indicado_id then
      raise exception 'Um paciente não pode indicar a si mesmo.';
    end if;
    -- Mesmo idioma de validação de tenant do paciente indicado acima —
    -- RLS de pacientes garante que só aparece se for da mesma clínica.
    if not exists (select 1 from public.pacientes where id = p_indicador_paciente_id) then
      raise exception 'Paciente indicador não encontrado ou sem permissão de acesso.';
    end if;
  elsif p_tipo_indicador = 'profissional' then
    if v_nome_externo is null then
      raise exception 'Indicação do tipo "profissional" exige o nome do profissional.';
    end if;
    if p_indicador_paciente_id is not null then
      raise exception 'Indicação do tipo "profissional" não deve informar paciente indicador.';
    end if;
  else -- 'outro'
    if p_indicador_paciente_id is not null then
      raise exception 'Indicação do tipo "outro" não deve informar paciente indicador.';
    end if;
    -- Nome externo é opcional para "outro" — de propósito, ver
    -- comentário no topo da migration (preserva o padrão dos 16
    -- registros históricos "outro" sem nome).
  end if;

  return internal.registrar_indicacao_core(
    v_clinica_id, p_paciente_indicado_id, p_tipo_indicador, p_indicador_paciente_id, v_nome_externo
  );
end;
$$;

revoke all on function public.registrar_indicacao(uuid,text,uuid,text) from public, anon;
grant execute on function public.registrar_indicacao(uuid,text,uuid,text) to authenticated;

commit;

-- ============================================================
-- ROTEIRO COMPLETO DE HOMOLOGAÇÃO (rodar manualmente no SQL Editor,
-- NESTA ORDEM, usando EXCLUSIVAMENTE registros QA — nunca pacientes
-- reais). Ajustar <UID_VITOR> para o auth.uid() real do Vitor (admin
-- ativo da Mori) antes de rodar. Todos os blocos abaixo limpam os
-- próprios dados de teste ao final.
-- ============================================================

-- ---- 0) Confirmar que a migration acima já rodou sem abortar (se
--         chegou até aqui, os 3 blocos de verificação passaram) ----
select count(*) as total_indicacoes_historicas from public.indicacoes;
-- Esperado: 52 (nenhum registro histórico foi alterado — nem INSERT nem
-- UPDATE nem DELETE acontece nos 52 originais, só ALTER TABLE/políticas/
-- grants/funções novas).

select conname, pg_get_constraintdef(oid)
from pg_constraint
where conrelid = 'public.indicacoes'::regclass and contype in ('c','u');
-- Esperado: incluir indicacoes_tipo_indicador_coerencia_check,
-- indicacoes_sem_autoindicacao_check, indicacoes_paciente_indicado_uniq,
-- além dos checks antigos (num_nonnulls, tipo_indicador in (...)) e do
-- unique (clinica_id, legacy_id) antigo — nenhum constraint antigo foi
-- removido.

-- ---- 1) Confirmar grants (item 2 — anon zero acesso; authenticated só
--         SELECT) ----
select grantee, privilege_type
from information_schema.role_table_grants
where table_schema='public' and table_name='indicacoes'
order by grantee, privilege_type;
-- Esperado: nenhuma linha com grantee='anon' nem 'PUBLIC'; authenticated
-- só com privilege_type='SELECT' (nenhum INSERT/UPDATE/DELETE/TRUNCATE/
-- REFERENCES/TRIGGER).

-- ---- 2) Confirmar policies (RLS) ----
select policyname, cmd from pg_policies
where schemaname='public' and tablename='indicacoes';
-- Esperado: 1 linha só, select_indicacoes / SELECT. isolamento_indicacoes
-- não deve mais existir.

-- ---- 3) Confirmar RPCs e grants (authenticated sim, anon/public não) ----
select p.proname, p.prosecdef as security_definer,
       has_function_privilege('authenticated', p.oid, 'execute') as authenticated_pode,
       has_function_privilege('anon', p.oid, 'execute') as anon_pode
from pg_proc p
where (p.pronamespace = 'public'::regnamespace and p.proname = 'registrar_indicacao')
   or (p.pronamespace = 'internal'::regnamespace and p.proname = 'registrar_indicacao_core');
-- Esperado: registrar_indicacao com security_definer=false (invoker);
-- registrar_indicacao_core com security_definer=true; ambas
-- authenticated_pode=true, anon_pode=false.

-- ---- Preparação: 2 pacientes QA na mesma clínica do Vitor, para os
--      testes de RPC abaixo ----
insert into public.pacientes (clinica_id, nome, created_by, updated_by)
  select clinica_id, 'QA INDICACAO PACIENTE INDICADO', id, id from public.profiles
  where auth_user_id = '<UID_VITOR>' limit 1
  returning id;
-- Guardar como <QA_PACIENTE_INDICADO_ID>.
insert into public.pacientes (clinica_id, nome, created_by, updated_by)
  select clinica_id, 'QA INDICACAO PACIENTE INDICADOR', id, id from public.profiles
  where auth_user_id = '<UID_VITOR>' limit 1
  returning id;
-- Guardar como <QA_PACIENTE_INDICADOR_ID>.

set local role authenticated;
set local request.jwt.claims = '{"sub":"<UID_VITOR>","role":"authenticated"}';

-- ---- 4) authenticated consegue SELECT da própria clínica ----
select count(*) from public.indicacoes;
-- Esperado: 52 (ou mais, se já houver QA de rodadas anteriores — mas
-- nunca erro de permissão).

-- ---- 5) authenticated NÃO consegue escrever direto (item 5/6/7/8 dos testes) ----
insert into public.indicacoes (clinica_id, paciente_indicado_id, tipo_indicador, indicador_nome_externo)
  values ((select clinica_id from public.profiles where auth_user_id='<UID_VITOR>'), '<QA_PACIENTE_INDICADO_ID>', 'outro', 'tentativa direta');
-- Esperado: erro de permissão ("permission denied for table indicacoes").

update public.indicacoes set tipo_indicador='outro' where id = (select id from public.indicacoes limit 1);
-- Esperado: erro de permissão.

delete from public.indicacoes where id = (select id from public.indicacoes limit 1);
-- Esperado: erro de permissão.

truncate public.indicacoes;
-- Esperado: erro de permissão.

-- ---- 6) RPC cria indicação tipo profissional válida ----
select * from public.registrar_indicacao(
  p_paciente_indicado_id := '<QA_PACIENTE_INDICADO_ID>',
  p_tipo_indicador := 'profissional',
  p_indicador_nome_externo := 'Dr. QA Profissional'
);
-- Esperado: sucesso, 1 linha criada.

-- ---- 7) RPC rejeita duplicidade (item 16) — mesmo paciente indicado de novo ----
select * from public.registrar_indicacao(
  p_paciente_indicado_id := '<QA_PACIENTE_INDICADO_ID>',
  p_tipo_indicador := 'outro',
  p_indicador_nome_externo := 'Segunda tentativa'
);
-- Esperado: erro "Este paciente já possui uma indicação de origem registrada."

-- ---- 8) RPC cria indicação tipo paciente válida (em outro paciente) ----
insert into public.pacientes (clinica_id, nome, created_by, updated_by)
  select clinica_id, 'QA INDICACAO SEGUNDO INDICADO', id, id from public.profiles
  where auth_user_id = '<UID_VITOR>' limit 1
  returning id;
-- Guardar como <QA_SEGUNDO_INDICADO_ID>.
reset role;
set local role authenticated;
set local request.jwt.claims = '{"sub":"<UID_VITOR>","role":"authenticated"}';

select * from public.registrar_indicacao(
  p_paciente_indicado_id := '<QA_SEGUNDO_INDICADO_ID>',
  p_tipo_indicador := 'paciente',
  p_indicador_paciente_id := '<QA_PACIENTE_INDICADOR_ID>'
);
-- Esperado: sucesso.

-- ---- 9) RPC rejeita tipo inválido ----
select * from public.registrar_indicacao(
  p_paciente_indicado_id := '<QA_SEGUNDO_INDICADO_ID>',
  p_tipo_indicador := 'invalido'
);
-- Esperado: erro "Tipo de indicador inválido: invalido" (e, de qualquer
-- forma, cairia na duplicidade também, já que esse paciente acabou de
-- receber uma indicação no passo 8 — usar outro paciente QA se quiser
-- isolar só o erro de tipo).

-- ---- 10) RPC rejeita incoerência entre tipo e campos ----
insert into public.pacientes (clinica_id, nome, created_by, updated_by)
  select clinica_id, 'QA INDICACAO INCOERENCIA', id, id from public.profiles
  where auth_user_id = '<UID_VITOR>' limit 1
  returning id;
-- Guardar como <QA_INCOERENCIA_ID>.
select * from public.registrar_indicacao(
  p_paciente_indicado_id := '<QA_INCOERENCIA_ID>',
  p_tipo_indicador := 'profissional',
  p_indicador_paciente_id := '<QA_PACIENTE_INDICADOR_ID>'
);
-- Esperado: erro "Indicação do tipo \"profissional\" não deve informar paciente indicador."

select * from public.registrar_indicacao(
  p_paciente_indicado_id := '<QA_INCOERENCIA_ID>',
  p_tipo_indicador := 'paciente'
);
-- Esperado: erro "Indicação do tipo \"paciente\" exige o paciente indicador."

-- ---- 11) RPC rejeita autoindicação ----
select * from public.registrar_indicacao(
  p_paciente_indicado_id := '<QA_INCOERENCIA_ID>',
  p_tipo_indicador := 'paciente',
  p_indicador_paciente_id := '<QA_INCOERENCIA_ID>'
);
-- Esperado: erro "Um paciente não pode indicar a si mesmo."

-- ---- 12) RPC cria indicação tipo outro, sem nome (preserva o padrão
--          histórico de "outro" sem indicador) ----
select * from public.registrar_indicacao(
  p_paciente_indicado_id := '<QA_INCOERENCIA_ID>',
  p_tipo_indicador := 'outro'
);
-- Esperado: sucesso, indicador_nome_externo NULL.

reset role;

-- ---- 13) Isolamento entre clínicas — bloco autocontido, SEMPRE termina
--          em ROLLBACK. Mais simples que simular login como a clínica B:
--          basta criar um PACIENTE em uma clínica B qualquer e tentar
--          usá-lo (como indicado OU como indicador) a partir da sessão
--          já autenticada do Vitor (clínica A/Mori) — exatamente o risco
--          real ("nenhum vínculo cross-tenant", item 5.8). A RLS de
--          pacientes garante que o SELECT dentro do wrapper não encontra
--          esse paciente para a sessão do Vitor, então a RPC rejeita sem
--          precisar simular outra sessão autenticada. ----
begin;

insert into public.clinicas (nome, cidade) values ('QA CLINICA INDICACAO ISOLAMENTO - rollback', 'Teste') returning id;
-- Guardar como <QA_CLINICA_B_ID>.
insert into public.pacientes (clinica_id, nome)
  values ('<QA_CLINICA_B_ID>', 'QA PACIENTE CLINICA B - rollback')
  returning id;
-- Guardar como <QA_PACIENTE_CLINICA_B_ID>.

set local role authenticated;
set local request.jwt.claims = '{"sub":"<UID_VITOR>","role":"authenticated"}';

-- Tentativa 1: paciente INDICADO é da clínica B (Vitor é da Mori).
-- SAVEPOINT antes de cada tentativa que deve falhar — sem isso, a
-- primeira exceção aborta toda a transação e a segunda tentativa nem
-- chega a rodar (erro "current transaction is aborted").
savepoint antes_tentativa_1;
select * from public.registrar_indicacao(
  p_paciente_indicado_id := '<QA_PACIENTE_CLINICA_B_ID>',
  p_tipo_indicador := 'outro'
);
-- Esperado: erro "Paciente indicado não encontrado ou sem permissão de acesso."
-- (a RLS de select_pacientes, escopada por minhas_clinicas(), não
-- encontra esse paciente para a sessão do Vitor — nunca "encontrado mas
-- de clínica errada".)
rollback to savepoint antes_tentativa_1;

-- Tentativa 2: paciente INDICADOR é da clínica B, indicado é um QA real
-- do Vitor (<QA_PACIENTE_INDICADO_ID>, da seção 6 acima).
savepoint antes_tentativa_2;
select * from public.registrar_indicacao(
  p_paciente_indicado_id := '<QA_PACIENTE_INDICADO_ID>',
  p_tipo_indicador := 'paciente',
  p_indicador_paciente_id := '<QA_PACIENTE_CLINICA_B_ID>'
);
-- Esperado: erro "Paciente indicador não encontrado ou sem permissão de acesso."
rollback to savepoint antes_tentativa_2;

reset role;
rollback;
-- Desfaz TUDO deste bloco — nenhuma clínica/paciente cruzado permanece.

-- ---- 14) LIMPEZA dos registros QA restantes (fora de qualquer
--          simulação de authenticated — contexto administrativo) ----
delete from public.indicacoes
  where paciente_indicado_id in (select id from public.pacientes where nome ilike 'QA INDICACAO%');
delete from public.pacientes where nome ilike 'QA INDICACAO%';

-- ---- 15) Confirmações finais ----
select count(*) as total_indicacoes_depois_da_limpeza from public.indicacoes;
-- Esperado: 52 (voltou exatamente ao número original — nenhum registro
-- histórico foi tocado em nenhum momento deste roteiro).
select count(*) as total_qa_pacientes_restante from public.pacientes where nome ilike 'QA INDICACAO%';
-- Esperado: 0.
select count(*) as total_qa_clinicas_restante from public.clinicas where nome ilike 'QA CLINICA INDICACAO%';
-- Esperado: 0 (o bloco 13 usou ROLLBACK).
