/* Mori Ortodontia CRM — leitura dos parâmetros de links de convite/recovery.
   Sem dependências: usado pelo index.html no navegador e pelos testes em Node.

   O Supabase redireciona para o CRM com os dados no "hash" da URL:
     sucesso: #access_token=...&refresh_token=...&type=recovery   (ou invite)
     falha:   #error=access_denied&error_code=otp_expired&error_description=...
   Este módulo nunca lê nem guarda o valor dos tokens — só diz se existem. */
(function(root){
  function lerParametros(texto, prefixo){
    try{
      return new URLSearchParams((texto||'').replace(prefixo, ''));
    }catch(e){
      return new URLSearchParams('');
    }
  }

  // Retorna { tipo, temToken, erro } onde:
  //  - tipo: 'invite' | 'recovery' | outro tipo do Supabase | null
  //  - temToken: true se o hash traz access_token (nunca expõe o valor)
  //  - erro: null, ou { codigo, descricao } quando o Supabase recusou o link
  function interpretarLinkAuth(hash, search){
    const h = lerParametros(hash, /^#/);
    const q = lerParametros(search, /^\?/);
    const codigo = h.get('error_code') || q.get('error_code') || null;
    const bruto = h.get('error') || q.get('error') || null;
    const descricao = h.get('error_description') || q.get('error_description') || null;
    const erro = (codigo || bruto) ? { codigo: codigo || bruto, descricao: descricao } : null;
    return {
      tipo: h.get('type') || null,
      temToken: !!h.get('access_token'),
      erro: erro
    };
  }

  // Mensagem em português, sem jargão e sem texto técnico cru do Supabase.
  function mensagemErroLinkAuth(erro){
    const codigo = String((erro && erro.codigo) || '').toLowerCase();
    const descricao = String((erro && erro.descricao) || '').toLowerCase();
    if(codigo === 'otp_expired' || /expired|invalid/.test(descricao)){
      return 'Este link de acesso expirou ou já foi usado. Cada link só funciona uma vez e por pouco tempo. Peça ao administrador um novo link e abra-o assim que receber, copiando e colando direto no navegador.';
    }
    if(codigo === 'access_denied'){
      return 'Este link de acesso não é mais válido. Peça ao administrador um novo link e abra-o assim que receber.';
    }
    return 'Não foi possível validar este link de acesso. Peça ao administrador um novo link.';
  }

  const api = { interpretarLinkAuth: interpretarLinkAuth, mensagemErroLinkAuth: mensagemErroLinkAuth };
  if(typeof module !== 'undefined' && module.exports) module.exports = api;
  root.MoriAuthLink = api;
})(typeof window !== 'undefined' ? window : globalThis);
