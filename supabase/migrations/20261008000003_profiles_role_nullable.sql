begin;

alter table public.profiles
  alter column role drop not null;

commit;
