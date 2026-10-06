/* Mori Ortodontia CRM — bootstrap do Supabase
   A Publishable Key deve ser injetada pelo ambiente/deploy.
   Nunca adicionar service_role neste arquivo. */
(function(){
  const url = 'https://rynlzkdqxbzwcznufnpn.supabase.co';
  const key = window.MORI_SUPABASE_PUBLISHABLE_KEY;

  if (!window.supabase || !window.supabase.createClient) {
    console.error('Supabase JS não foi carregado.');
    return;
  }
  if (!key) {
    console.error('MORI_SUPABASE_PUBLISHABLE_KEY não configurada.');
    return;
  }

  window.moriSupabase = window.supabase.createClient(url, key, {
    auth: {
      persistSession: true,
      autoRefreshToken: true,
      detectSessionInUrl: true
    }
  });
})();
