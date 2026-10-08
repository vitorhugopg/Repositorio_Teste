-- Registra no repositório a correção já aplicada no banco.
-- O projeto possui default privilege de EXECUTE para anon em novas funções,
-- portanto REVOKE FROM PUBLIC, isoladamente, não era suficiente.

revoke execute on function public.sou_admin_da_clinica(uuid) from anon;
