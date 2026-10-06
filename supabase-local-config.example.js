/* Mori Ortodontia CRM — exemplo de configuração local do Supabase.

   Para testar a integração Supabase no seu navegador:
   1. Copie este arquivo para `supabase-local-config.js` (mesmo diretório).
   2. Troque o valor abaixo pela Publishable Key do projeto
      (Supabase → Project Settings → API Keys → Publishable key).
   3. Abra index.html normalmente.

   `supabase-local-config.js` está no .gitignore — nunca será commitado.
   Sem esse arquivo (ou sem editar a chave), o CRM continua 100% em
   localStorage, exatamente como hoje — nada quebra. */
window.MORI_SUPABASE_PUBLISHABLE_KEY = 'cole-aqui-a-publishable-key';
