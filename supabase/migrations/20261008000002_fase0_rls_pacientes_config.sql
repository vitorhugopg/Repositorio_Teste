begin;

-- Pacientes: leitura/criação/edição para usuários autorizados da clínica.
-- Nenhuma policy DELETE é criada.
drop policy if exists "isolamento_pacientes" on public.pacientes;

create policy "select_pacientes" on public.pacientes
  for select to authenticated
  using (clinica_id in (select public.minhas_clinicas()));

create policy "insert_pacientes" on public.pacientes
  for insert to authenticated
  with check (clinica_id in (select public.minhas_clinicas()));

create policy "update_pacientes" on public.pacientes
  for update to authenticated
  using (clinica_id in (select public.minhas_clinicas()))
  with check (clinica_id in (select public.minhas_clinicas()));

-- Procedimentos: leitura para a clínica; escrita somente admin.
drop policy if exists "isolamento_procedimentos" on public.procedimentos;

create policy "ver_procedimentos_da_clinica" on public.procedimentos
  for select to authenticated
  using (clinica_id in (select public.minhas_clinicas()));

create policy "gerenciar_procedimentos_admin" on public.procedimentos
  for all to authenticated
  using (
    clinica_id in (select public.minhas_clinicas())
    and public.sou_admin_da_clinica(clinica_id)
  )
  with check (
    clinica_id in (select public.minhas_clinicas())
    and public.sou_admin_da_clinica(clinica_id)
  );

-- Origens: leitura para a clínica; escrita somente admin.
drop policy if exists "isolamento_origens" on public.origens_lead;

create policy "ver_origens_da_clinica" on public.origens_lead
  for select to authenticated
  using (clinica_id in (select public.minhas_clinicas()));

create policy "gerenciar_origens_admin" on public.origens_lead
  for all to authenticated
  using (
    clinica_id in (select public.minhas_clinicas())
    and public.sou_admin_da_clinica(clinica_id)
  )
  with check (
    clinica_id in (select public.minhas_clinicas())
    and public.sou_admin_da_clinica(clinica_id)
  );

-- Motivos de perda: leitura para a clínica; escrita somente admin.
drop policy if exists "isolamento_motivos" on public.motivos_perda;

create policy "ver_motivos_da_clinica" on public.motivos_perda
  for select to authenticated
  using (clinica_id in (select public.minhas_clinicas()));

create policy "gerenciar_motivos_admin" on public.motivos_perda
  for all to authenticated
  using (
    clinica_id in (select public.minhas_clinicas())
    and public.sou_admin_da_clinica(clinica_id)
  )
  with check (
    clinica_id in (select public.minhas_clinicas())
    and public.sou_admin_da_clinica(clinica_id)
  );

commit;
