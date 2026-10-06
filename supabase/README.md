# Supabase — CRM Mori Ortodontia

Infraestrutura de banco de dados (PostgreSQL/Supabase) do CRM, separada do
frontend (`index.html`). O CRM ainda **não está conectado** a este banco —
continua rodando 100% em `localStorage`, como hoje.

## Estrutura

- `migrations/20261006000000_schema_inicial.sql` — schema completo aprovado:
  11 tabelas, `calc_status()`, `pacientes_com_status`, `minhas_clinicas()`,
  RLS e permissões. Não insere nenhum dado de negócio (nenhuma clínica,
  paciente ou indicação real) — só estrutura.

## Como reproduzir em um projeto Supabase vazio

1. Crie um projeto novo no [painel do Supabase](https://supabase.com/dashboard).
2. Abra **SQL Editor** → **New query**.
3. Cole o conteúdo de `migrations/20261006000000_schema_inicial.sql` e execute.
4. Confirme que as 11 tabelas, a função `calc_status`, a view
   `pacientes_com_status` e a função `minhas_clinicas` foram criadas, e que
   RLS está habilitado em todas as tabelas de negócio.

Se no futuro o [Supabase CLI](https://supabase.com/docs/guides/cli) for
adotado, esta pasta já segue a convenção `supabase/migrations/<timestamp>_<nome>.sql`
esperada por `supabase db push`.

## Credenciais

Nenhuma credencial (senha do banco, `service_role key`, access token) deve
ser commitada neste repositório. Um eventual arquivo `.env`/`.env.local`
com essas informações fica de fora do Git (ver `.gitignore` na raiz).
