-- ============================================================
-- clinicas.timezone — preparação de banco para o Módulo de Recorrência
-- ------------------------------------------------------------
-- NÃO EXECUTAR ainda — aguardando o operador rodar manualmente no SQL
-- Editor do projeto Supabase da Mori Ortodontia (rynlzkdqxbzwcznufnpn).
-- Esta sessão não tem credenciais de banco para aplicar automaticamente.
--
-- Escopo: SOMENTE a coluna no banco. Esta migration não lê nem escreve
-- nenhuma lógica de frontend — hojeISO() e as regras de Resgate/
-- Pós-Consulta continuam exatamente como estão, sem nenhuma alteração.
-- O uso de `timezone` para calcular a "data civil de hoje" do módulo de
-- Recorrência fica para a etapa de interface, fora desta entrega.
--
-- Aditiva, não destrutiva: coluna nova com DEFAULT, nenhum dado
-- existente é alterado além do preenchimento explícito do valor para a
-- Mori (única clínica hoje) — mesmo padrão já usado na migration de
-- `data_inicio_acoes_comerciais` (20261016000000).
-- ============================================================

begin;

alter table public.clinicas
  add column if not exists timezone text not null default 'America/Sao_Paulo';

comment on column public.clinicas.timezone is
  'Fuso horário IANA da clínica (ex: America/Sao_Paulo). Preparação para o Módulo de Recorrência calcular a "data civil de hoje" sem depender de UTC. Não utilizado ainda por nenhuma lógica existente (Resgate, Pós-Consulta, hojeISO()) nem pelo frontend — a leitura/uso deste valor é escopo de uma etapa futura (interface da Recorrência).';

-- Valor inicial explícito da Mori Ortodontia (já é o valor do DEFAULT,
-- mas deixamos o UPDATE explícito por clareza e documentação, mesmo
-- padrão da migration de corte operacional).
update public.clinicas
  set timezone = 'America/Sao_Paulo'
  where id = '4f1d0862-3455-49c6-997b-c8e8f8d165ee'::uuid;

commit;

-- ============================================================
-- ROTEIRO DE VERIFICAÇÃO (rodar manualmente no SQL Editor)
-- ============================================================

select id, nome, timezone from public.clinicas;
-- Esperado: Mori Ortodontia com timezone = 'America/Sao_Paulo'.

select column_name, data_type, is_nullable, column_default
from information_schema.columns
where table_schema='public' and table_name='clinicas' and column_name='timezone';
-- Esperado: text, NOT NULL, default 'America/Sao_Paulo'::text.
