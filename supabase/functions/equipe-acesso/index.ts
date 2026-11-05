// ============================================================
// Equipe — Gestão de Acesso (Edge Function administrativa)
// ------------------------------------------------------------
// NÃO FAZER DEPLOY ainda — aguardando autorização explícita. Este
// arquivo só existe no repositório; nenhuma chamada real ao projeto
// Supabase da Mori (rynlzkdqxbzwcznufnpn) foi feita a partir desta
// sessão.
//
// Por que uma Edge Function e não chamadas diretas do navegador:
// toda operação aqui dentro usa o SERVICE_ROLE_KEY (via
// `Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')`, injetado automaticamente
// pelo runtime do Supabase em toda Edge Function — nunca commitado,
// nunca visível no navegador). O frontend só manda o JWT da sessão do
// próprio usuário (Authorization: Bearer <access_token>, igual a
// qualquer outra chamada autenticada do CRM) — esta função decide, no
// servidor, SE aquele usuário pode fazer o que está pedindo.
//
// Nenhuma decisão de autorização confia em nada que o navegador possa
// ter manipulado (clinica_id, role, isAdmin no payload são IGNORADOS
// de propósito — sempre derivados de novo aqui, a partir do profile do
// JWT, lido com o service_role, ignorando RLS).
// ============================================================

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.4';

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

// Banir "para sempre" na prática: Supabase Auth não tem um "desativado"
// nativo fora de ban_duration. Um valor bem alto é o jeito documentado
// de revogar acesso sem apagar o usuário (reversível com ban_duration:'none').
const BAN_DURATION_INDEFINIDO = '876000h'; // ~100 anos
const BAN_DURATION_REMOVER = 'none';

function respostaJson(corpo, status = 200) {
  return new Response(JSON.stringify(corpo), {
    status,
    headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
  });
}
function erroAmigavel(mensagem, status = 400) {
  return respostaJson({ error: mensagem }, status);
}

const EMAIL_REGEX = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
function emailValido(email) {
  return typeof email === 'string' && EMAIL_REGEX.test(email.trim());
}

// Nunca loga e-mail, link, token ou senha — só o necessário para
// auditoria/depuração operacional (item 19 do pedido).
function logAcao(acao, detalhe) {
  console.log(JSON.stringify({ acao, ...detalhe, em: new Date().toISOString() }));
}

function clienteAdmin() {
  const url = Deno.env.get('SUPABASE_URL');
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!url || !serviceRoleKey) {
    throw new Error('SUPABASE_URL/SUPABASE_SERVICE_ROLE_KEY não configurados na Edge Function.');
  }
  return createClient(url, serviceRoleKey, { auth: { persistSession: false } });
}

function appBaseUrl() {
  // [Ambiente] Precisa ser configurado como secret da função antes do
  // deploy (homologação usa a Preview URL do Vercel; produção, o
  // domínio definitivo — nunca hardcoded aqui, exatamente para não
  // precisar alterar código ao trocar de ambiente, item "não alterar
  // domínio definitivo" do pedido).
  const base = Deno.env.get('APP_BASE_URL');
  if (!base) throw new Error('APP_BASE_URL não configurada na Edge Function.');
  return base.replace(/\/+$/, '') + '/';
}

// ------------------------------------------------------------
// Autenticação + autorização — chamado por TODA ação administrativa
// (tudo exceto complete_invite, que é autoatendimento do convidado).
// ------------------------------------------------------------
async function carregarChamadorAdmin(admin, req) {
  const authHeader = req.headers.get('Authorization') || '';
  const jwt = authHeader.replace(/^Bearer\s+/i, '').trim();
  if (!jwt) throw { publico: 'Sessão inválida. Faça login novamente.', status: 401 };

  const { data: userData, error: userErro } = await admin.auth.getUser(jwt);
  if (userErro || !userData || !userData.user) {
    throw { publico: 'Sessão inválida. Faça login novamente.', status: 401 };
  }

  const { data: perfil, error: perfilErro } = await admin
    .from('profiles')
    .select('id, clinica_id, nome, role, ativo, status_acesso, auth_user_id')
    .eq('auth_user_id', userData.user.id)
    .maybeSingle();
  if (perfilErro) throw { publico: 'Erro ao verificar seu perfil.', status: 500, interno: perfilErro };
  if (!perfil) throw { publico: 'Perfil não encontrado.', status: 403 };

  // [Segurança — item 16 do pedido] Checagem SEMPRE no servidor, nunca
  // confia em nada enviado pelo navegador — isto aqui é a autorização
  // real, a interface só esconde botões por conveniência.
  if (!perfil.ativo || perfil.status_acesso !== 'ativo') {
    throw { publico: 'Seu acesso não está ativo.', status: 403 };
  }
  if (perfil.role !== 'admin') {
    throw { publico: 'Apenas administradores podem gerenciar a equipe.', status: 403 };
  }
  return { ...perfil, authUserId: userData.user.id };
}

async function carregarPerfilAlvoNaMesmaClinica(admin, chamador, targetProfileId) {
  if (!targetProfileId) throw { publico: 'Pessoa inválida.', status: 400 };
  const { data: alvo, error } = await admin
    .from('profiles')
    .select('id, clinica_id, nome, email, role, ativo, status_acesso, auth_user_id, convite_auth_user_id')
    .eq('id', targetProfileId)
    .maybeSingle();
  if (error) throw { publico: 'Erro ao consultar a pessoa.', status: 500, interno: error };
  if (!alvo) throw { publico: 'Pessoa não encontrada.', status: 404 };
  // [Multi-tenant — item 7/16 do pedido] Nunca confia em clinica_id do
  // navegador — compara com a clínica do CHAMADOR, resolvida no passo
  // anterior a partir do próprio JWT.
  if (alvo.clinica_id !== chamador.clinica_id) {
    throw { publico: 'Pessoa não encontrada.', status: 404 };
  }
  return alvo;
}

// ------------------------------------------------------------
// [Correção — ativação de usuários] Antes de QUALQUER ação sobre um
// convite pendente (reenviar, gerar link), verificamos o estado REAL do
// usuário Auth referenciado por convite_auth_user_id — nunca decidimos
// "o que fazer com ele" só a partir do que está em profiles. Isso evita
// o bug que afetou Mariana: tratar como "ainda não confirmado" alguém
// que já abriu o link e já tem sessão (email_confirmed_at preenchido),
// e por isso jamais apagar essa conta.
// ------------------------------------------------------------
async function carregarUsuarioAuthDoAlvo(admin, alvo) {
  if (!alvo.convite_auth_user_id) return null;
  const { data, error } = await admin.auth.admin.getUserById(alvo.convite_auth_user_id);
  if (error) {
    // 404/"user not found" = o vínculo está desatualizado (conta não
    // existe mais) — tratamos como "sem usuário Auth ainda", não como
    // falha. Qualquer outro erro é uma falha técnica real, que não
    // podemos simplesmente ignorar (decidiríamos no escuro).
    if (error.status === 404 || /not.*found/i.test(error.message || '')) return null;
    throw { publico: 'Não foi possível verificar o estado atual do convite agora. Tente novamente.', status: 502, interno: error };
  }
  return (data && data.user) || null;
}

function contaJaIniciouAtivacao(authUser) {
  // "Iniciou a ativação" = já abriu um link e o GoTrue já confirmou o
  // e-mail dela — isso acontece ANTES de definir senha. A partir daqui a
  // conta tem história real (pode até já ter uma sessão aberta no
  // navegador da pessoa) e nunca mais deve ser apagada automaticamente.
  return !!(authUser && (authUser.email_confirmed_at || authUser.confirmed_at));
}

function contaBloqueada(authUser) {
  if (!authUser || !authUser.banned_until) return false;
  const ate = new Date(authUser.banned_until).getTime();
  return Number.isFinite(ate) && ate > Date.now();
}

// Limpeza best-effort de um usuário Auth RECÉM-CRIADO por esta própria
// chamada quando o passo seguinte (vincular ao profile) falha. Diferente
// de apagar a conta de alguém que já usou o link: aqui o usuário não tem
// nenhuma história (acabou de ser criado, ninguém nunca o usou) e, sem o
// vínculo em profiles, ele ficaria orfão e inacessível por qualquer
// fluxo do CRM — item "falhas parciais não deixem o sistema em um
// estado inconsistente" do pedido.
async function limparUsuarioOrfao(admin, authUserId) {
  if (!authUserId) return;
  try { await admin.auth.admin.deleteUser(authUserId); } catch (_e) { /* best-effort */ }
}

async function existeOutroAdminAtivo(admin, clinicaId, idExcluido) {
  const { data, error } = await admin
    .from('profiles')
    .select('id')
    .eq('clinica_id', clinicaId)
    .eq('role', 'admin')
    .eq('ativo', true)
    .eq('status_acesso', 'ativo')
    .neq('id', idExcluido)
    .limit(1);
  if (error) throw { publico: 'Erro ao verificar administradores da clínica.', status: 500, interno: error };
  return (data || []).length > 0;
}

// ------------------------------------------------------------
// Ações administrativas
// ------------------------------------------------------------

async function acaoInvite(admin, chamador, body) {
  const targetProfileId = body.target_profile_id;
  const email = (body.email || '').trim().toLowerCase();
  const role = body.role;

  if (!emailValido(email)) throw { publico: 'Informe um e-mail válido.', status: 400 };
  if (role !== 'admin' && role !== 'usuario') throw { publico: 'Permissão inválida.', status: 400 };

  const alvo = await carregarPerfilAlvoNaMesmaClinica(admin, chamador, targetProfileId);
  if (alvo.status_acesso) {
    throw { publico: 'Esta pessoa já possui um acesso em andamento. Use Reenviar, Copiar link ou Reativar.', status: 409 };
  }

  // [Item 8 do pedido] Checagem amigável de e-mail já em uso por OUTRO
  // integrante da mesma clínica (convite pendente ou já ativo).
  const { data: colisao, error: erroColisao } = await admin
    .from('profiles')
    .select('id, nome')
    .eq('clinica_id', chamador.clinica_id)
    .eq('email', email)
    .not('status_acesso', 'is', null)
    .neq('id', alvo.id)
    .limit(1);
  if (erroColisao) throw { publico: 'Erro ao validar o e-mail.', status: 500, interno: erroColisao };
  if ((colisao || []).length) {
    throw { publico: `Este e-mail já está em uso pelo acesso de ${colisao[0].nome}.`, status: 409 };
  }

  const { data: convite, error: erroConvite } = await admin.auth.admin.inviteUserByEmail(email, {
    redirectTo: appBaseUrl(),
  });
  if (erroConvite || !convite || !convite.user) {
    const msg = (erroConvite && erroConvite.message) || '';
    if (/already.*registered|already.*exists/i.test(msg)) {
      throw { publico: 'Este e-mail já possui uma conta no Supabase Auth (fora deste fluxo). Verifique com o suporte técnico.', status: 409 };
    }
    throw { publico: 'Não foi possível criar o convite agora. Tente novamente.', status: 502, interno: erroConvite };
  }

  const { error: erroUpdate } = await admin
    .from('profiles')
    .update({ email, role, status_acesso: 'pendente', convite_auth_user_id: convite.user.id })
    .eq('id', alvo.id);
  if (erroUpdate) {
    // [Correção — falha parcial não deixa estado inconsistente] O
    // usuário Auth acabou de ser criado agora mesmo, ninguém nunca abriu
    // o link dele — sem o vínculo em profiles ele fica órfão e
    // inacessível por qualquer fluxo do CRM. Como não há história real
    // para preservar, desfazemos a criação em vez de deixar para o
    // suporte consertar manualmente.
    await limparUsuarioOrfao(admin, convite.user.id);
    throw { publico: 'Não foi possível concluir o convite agora. Tente novamente.', status: 500, interno: erroUpdate };
  }

  logAcao('invite', { clinica_id: chamador.clinica_id, chamador_id: chamador.id, alvo_id: alvo.id });
  return { ok: true, status_acesso: 'pendente' };
}

async function acaoResendInvite(admin, chamador, body) {
  const alvo = await carregarPerfilAlvoNaMesmaClinica(admin, chamador, body.target_profile_id);
  if (alvo.status_acesso !== 'pendente' || !alvo.email) {
    throw { publico: 'Esta pessoa não tem um convite pendente para reenviar.', status: 409 };
  }

  // [Correção — ativação de usuários] NUNCA mais apaga o usuário Auth
  // antes de decidir o que fazer. Primeiro verificamos o estado real
  // dele (pode não existir mais, pode nunca ter sido aberto, ou pode já
  // ter sido confirmado por quem recebeu o convite) e só então agimos —
  // cada caso tem uma ação diferente, nenhuma delas envolve excluir uma
  // conta que já tem história.
  const authUser = await carregarUsuarioAuthDoAlvo(admin, alvo);

  if (contaBloqueada(authUser)) {
    throw { publico: 'Esta pessoa está com o acesso bloqueado no momento. Verifique o status de acesso antes de reenviar.', status: 409 };
  }

  if (!authUser) {
    // Vínculo desatualizado (conta não existe mais) ou primeiro convite
    // de fato nunca chegou a criar um usuário Auth válido — convida do
    // zero. Nada para apagar: não há conta anterior.
    const { data: convite, error: erroConvite } = await admin.auth.admin.inviteUserByEmail(alvo.email, {
      redirectTo: appBaseUrl(),
    });
    if (erroConvite || !convite || !convite.user) {
      throw { publico: 'Não foi possível reenviar agora. Tente novamente.', status: 502, interno: erroConvite };
    }
    const { error: erroUpdate } = await admin
      .from('profiles')
      .update({ convite_auth_user_id: convite.user.id })
      .eq('id', alvo.id);
    if (erroUpdate) {
      await limparUsuarioOrfao(admin, convite.user.id);
      throw { publico: 'Não foi possível reenviar agora. Tente novamente.', status: 500, interno: erroUpdate };
    }
    logAcao('resend_invite', { clinica_id: chamador.clinica_id, chamador_id: chamador.id, alvo_id: alvo.id, via: 'invite_novo' });
    return { ok: true };
  }

  if (!contaJaIniciouAtivacao(authUser)) {
    // Ainda não abriu nenhum link — reenviar é seguro: o GoTrue reaproveita
    // o MESMO usuário Auth e invalida o token/link anterior (comportamento
    // oficial documentado para convite a um e-mail ainda não confirmado).
    // Continua sem precisar excluir nada.
    const { data: convite, error: erroConvite } = await admin.auth.admin.inviteUserByEmail(alvo.email, {
      redirectTo: appBaseUrl(),
    });
    if (erroConvite || !convite || !convite.user) {
      throw { publico: 'Não foi possível reenviar agora. Tente novamente.', status: 502, interno: erroConvite };
    }
    if (convite.user.id !== alvo.convite_auth_user_id) {
      const { error: erroUpdate } = await admin
        .from('profiles')
        .update({ convite_auth_user_id: convite.user.id })
        .eq('id', alvo.id);
      if (erroUpdate) throw { publico: 'Convite reenviado, mas houve erro ao atualizar o perfil. Avise o suporte técnico.', status: 500, interno: erroUpdate };
    }
    logAcao('resend_invite', { clinica_id: chamador.clinica_id, chamador_id: chamador.id, alvo_id: alvo.id, via: 'invite_reaproveitado' });
    return { ok: true };
  }

  // Já confirmou o e-mail (abriu o link, iniciou a ativação) mas ainda
  // não definiu senha/concluiu o cadastro — exatamente o caso de Mariana.
  // Reenviar um "convite" aqui não é a ferramenta certa (o GoTrue trata
  // um e-mail já confirmado como já registrado) e jamais apaga a conta:
  // envia um e-mail de recuperação de senha para a MESMA conta, que ela
  // pode usar para terminar de definir a senha e cair na mesma tela
  // "Criar seu acesso" (TIPO_LINK_AUTH_INICIAL já trata type=recovery
  // igual a type=invite no frontend).
  const { error: erroRecovery } = await admin.auth.resetPasswordForEmail(alvo.email, {
    redirectTo: appBaseUrl(),
  });
  if (erroRecovery) {
    throw { publico: 'Não foi possível reenviar agora. Tente novamente.', status: 502, interno: erroRecovery };
  }

  logAcao('resend_invite', { clinica_id: chamador.clinica_id, chamador_id: chamador.id, alvo_id: alvo.id, via: 'recovery_conta_existente' });
  return { ok: true };
}

async function acaoGenerateLink(admin, chamador, body) {
  const alvo = await carregarPerfilAlvoNaMesmaClinica(admin, chamador, body.target_profile_id);
  if (alvo.status_acesso !== 'pendente' || !alvo.email) {
    throw { publico: 'Esta pessoa não tem um convite pendente.', status: 409 };
  }

  // [Correção — ativação de usuários] generate_link NUNCA mais usa
  // deleteUser() como mecanismo de recuperação. Em vez de tentar
  // type:'invite' e só "remediar" depois de falhar, verificamos ANTES o
  // estado real do usuário Auth e escolhemos o tipo de link certo desde
  // o início:
  //  - ainda não confirmou (nunca abriu nenhum link) -> type:'invite',
  //    que reaproveita o mesmo usuário e invalida o link anterior;
  //  - já confirmou o e-mail mas não concluiu o cadastro (caso de
  //    Mariana) -> type:'invite' falharia (GoTrue trata e-mail já
  //    confirmado como já registrado); usamos type:'recovery', que gera
  //    um novo link válido PARA A MESMA conta, sem excluir nada.
  const authUser = await carregarUsuarioAuthDoAlvo(admin, alvo);

  if (contaBloqueada(authUser)) {
    throw { publico: 'Esta pessoa está com o acesso bloqueado no momento. Verifique o status de acesso antes de gerar um novo link.', status: 409 };
  }

  const tipoLink = contaJaIniciouAtivacao(authUser) ? 'recovery' : 'invite';
  const { data: linkGerado, error: erroGerar } = await admin.auth.admin.generateLink({
    type: tipoLink,
    email: alvo.email,
    options: { redirectTo: appBaseUrl() },
  });
  if (erroGerar || !linkGerado) {
    throw { publico: 'Não foi possível gerar o link. Tente novamente.', status: 502, interno: erroGerar };
  }

  // [Vínculo auth.users <-> profiles validado] Só é esperado um
  // auth.users.id novo quando authUser era null (type:'invite' criando o
  // usuário por não existir nenhum ainda) — nos outros casos o id
  // retornado deve ser sempre o mesmo que já tínhamos.
  const idRetornado = linkGerado.user && linkGerado.user.id;
  if (idRetornado && idRetornado !== alvo.convite_auth_user_id) {
    const { error: erroUpdateId } = await admin.from('profiles').update({ convite_auth_user_id: idRetornado }).eq('id', alvo.id);
    if (erroUpdateId) {
      // O usuário Auth só é "órfão de verdade" (sem história) se não
      // havia nenhum authUser antes desta chamada — só nesse caso é
      // seguro desfazer a criação; se já existia authUser, idRetornado
      // nunca deveria ter mudado (sinal de inconsistência, não limpamos
      // nada automaticamente).
      if (!authUser) await limparUsuarioOrfao(admin, idRetornado);
      throw { publico: 'Link gerado, mas houve erro ao atualizar o perfil. Avise o suporte técnico.', status: 500, interno: erroUpdateId };
    }
  }

  const actionLink = linkGerado.properties && linkGerado.properties.action_link;
  if (!actionLink) throw { publico: 'Não foi possível gerar o link. Tente novamente.', status: 502 };

  logAcao('generate_link', { clinica_id: chamador.clinica_id, chamador_id: chamador.id, alvo_id: alvo.id, tipo: tipoLink });
  // [Item 20 do pedido] O link NUNCA é persistido no banco — só retorna
  // nesta resposta HTTP, direto para o navegador do administrador copiar.
  return { ok: true, link: actionLink };
}

async function acaoCancelInvite(admin, chamador, body) {
  const alvo = await carregarPerfilAlvoNaMesmaClinica(admin, chamador, body.target_profile_id);
  if (alvo.status_acesso !== 'pendente') {
    throw { publico: 'Esta pessoa não tem um convite pendente para cancelar.', status: 409 };
  }

  if (alvo.convite_auth_user_id) {
    const { error: erroDelete } = await admin.auth.admin.deleteUser(alvo.convite_auth_user_id);
    if (erroDelete && erroDelete.status !== 404) {
      throw { publico: 'Não foi possível cancelar agora. Tente novamente.', status: 502, interno: erroDelete };
    }
  }

  const { error: erroUpdate } = await admin
    .from('profiles')
    .update({ status_acesso: null, convite_auth_user_id: null })
    .eq('id', alvo.id);
  if (erroUpdate) throw { publico: 'Erro ao cancelar o convite. Tente novamente.', status: 500, interno: erroUpdate };

  logAcao('cancel_invite', { clinica_id: chamador.clinica_id, chamador_id: chamador.id, alvo_id: alvo.id });
  return { ok: true, status_acesso: null };
}

async function acaoDeactivateAccess(admin, chamador, body) {
  const alvo = await carregarPerfilAlvoNaMesmaClinica(admin, chamador, body.target_profile_id);
  if (alvo.id === chamador.id) {
    throw { publico: 'Você não pode desativar o seu próprio acesso.', status: 403 };
  }
  if (alvo.status_acesso !== 'ativo') {
    throw { publico: 'Esta pessoa não está com acesso ativo.', status: 409 };
  }
  if (alvo.role === 'admin') {
    const outroAdmin = await existeOutroAdminAtivo(admin, chamador.clinica_id, alvo.id);
    if (!outroAdmin) throw { publico: 'A clínica precisa ter ao menos um administrador ativo. Torne outra pessoa administradora antes de desativar esta.', status: 409 };
  }

  const { error: erroBan } = await admin.auth.admin.updateUserById(alvo.auth_user_id, { ban_duration: BAN_DURATION_INDEFINIDO });
  if (erroBan) throw { publico: 'Não foi possível desativar o acesso agora. Tente novamente.', status: 502, interno: erroBan };

  const { error: erroUpdate } = await admin.from('profiles').update({ status_acesso: 'desativado' }).eq('id', alvo.id);
  if (erroUpdate) throw { publico: 'Acesso revogado no Auth, mas houve erro ao atualizar o perfil. Avise o suporte técnico.', status: 500, interno: erroUpdate };

  logAcao('deactivate_access', { clinica_id: chamador.clinica_id, chamador_id: chamador.id, alvo_id: alvo.id });
  return { ok: true, status_acesso: 'desativado' };
}

async function acaoReactivateAccess(admin, chamador, body) {
  const alvo = await carregarPerfilAlvoNaMesmaClinica(admin, chamador, body.target_profile_id);
  if (!alvo.ativo) {
    throw { publico: 'Esta pessoa foi removida da equipe. Adicione-a novamente antes de reativar o acesso.', status: 409 };
  }
  if (alvo.status_acesso !== 'desativado') {
    throw { publico: 'Esta pessoa não está com o acesso desativado.', status: 409 };
  }

  const { error: erroUnban } = await admin.auth.admin.updateUserById(alvo.auth_user_id, { ban_duration: BAN_DURATION_REMOVER });
  if (erroUnban) throw { publico: 'Não foi possível reativar o acesso agora. Tente novamente.', status: 502, interno: erroUnban };

  const { error: erroUpdate } = await admin.from('profiles').update({ status_acesso: 'ativo' }).eq('id', alvo.id);
  if (erroUpdate) throw { publico: 'Acesso reativado no Auth, mas houve erro ao atualizar o perfil. Avise o suporte técnico.', status: 500, interno: erroUpdate };

  logAcao('reactivate_access', { clinica_id: chamador.clinica_id, chamador_id: chamador.id, alvo_id: alvo.id });
  return { ok: true, status_acesso: 'ativo' };
}

async function acaoRemoveFromTeam(admin, chamador, body) {
  const alvo = await carregarPerfilAlvoNaMesmaClinica(admin, chamador, body.target_profile_id);
  if (alvo.id === chamador.id) {
    throw { publico: 'Você não pode remover a si mesmo da equipe.', status: 403 };
  }
  if (alvo.role === 'admin' && alvo.ativo && alvo.status_acesso === 'ativo') {
    const outroAdmin = await existeOutroAdminAtivo(admin, chamador.clinica_id, alvo.id);
    if (!outroAdmin) throw { publico: 'A clínica precisa ter ao menos um administrador ativo. Torne outra pessoa administradora antes de remover esta.', status: 409 };
  }

  // [Item 13 do pedido] Convite pendente nunca teve história real
  // associada -> pode ser apagado do Auth por completo. Acesso já
  // ATIVO é banido (reversível), nunca apagado, porque preservar o
  // vínculo histórico (quem fez o quê) depende só de `profiles.id`,
  // nunca de `auth.users` continuar existindo — mas apagar um usuário
  // Auth de verdade é uma operação mais arriscada/irreversível do que
  // o necessário aqui.
  if (alvo.convite_auth_user_id) {
    const { error: erroDelete } = await admin.auth.admin.deleteUser(alvo.convite_auth_user_id);
    if (erroDelete && erroDelete.status !== 404) {
      throw { publico: 'Não foi possível remover agora. Tente novamente.', status: 502, interno: erroDelete };
    }
  } else if (alvo.auth_user_id && alvo.status_acesso === 'ativo') {
    const { error: erroBan } = await admin.auth.admin.updateUserById(alvo.auth_user_id, { ban_duration: BAN_DURATION_INDEFINIDO });
    if (erroBan) throw { publico: 'Não foi possível remover agora. Tente novamente.', status: 502, interno: erroBan };
  }

  const novoStatusAcesso = alvo.auth_user_id ? 'desativado' : null;
  const { error: erroUpdate } = await admin
    .from('profiles')
    .update({ ativo: false, status_acesso: novoStatusAcesso, convite_auth_user_id: null })
    .eq('id', alvo.id);
  if (erroUpdate) throw { publico: 'Erro ao remover da equipe. Tente novamente.', status: 500, interno: erroUpdate };

  logAcao('remove_from_team', { clinica_id: chamador.clinica_id, chamador_id: chamador.id, alvo_id: alvo.id });
  return { ok: true };
}

// ------------------------------------------------------------
// Ação de autoatendimento — NÃO exige admin. É a própria pessoa
// convidada, autenticada pela sessão criada ao abrir o link de
// convite/recovery, concluindo o próprio cadastro.
// ------------------------------------------------------------
async function acaoCompleteInvite(admin, req) {
  const authHeader = req.headers.get('Authorization') || '';
  const jwt = authHeader.replace(/^Bearer\s+/i, '').trim();
  if (!jwt) throw { publico: 'Sessão inválida. Abra o link de convite novamente.', status: 401 };

  const { data: userData, error: userErro } = await admin.auth.getUser(jwt);
  if (userErro || !userData || !userData.user) {
    throw { publico: 'Sessão inválida. Abra o link de convite novamente.', status: 401 };
  }
  const uid = userData.user.id;

  // Idempotência: se já foi concluído antes (ex.: clique duplicado,
  // outra aba), não é erro — só confirma o estado já concluído.
  const { data: jaAtivo } = await admin
    .from('profiles')
    .select('id')
    .eq('auth_user_id', uid)
    .eq('status_acesso', 'ativo')
    .maybeSingle();
  if (jaAtivo) return { ok: true, already_done: true };

  const { data: pendente, error: erroPendente } = await admin
    .from('profiles')
    .select('id, clinica_id')
    .eq('convite_auth_user_id', uid)
    .eq('status_acesso', 'pendente')
    .maybeSingle();
  if (erroPendente) throw { publico: 'Erro ao concluir o acesso.', status: 500, interno: erroPendente };
  if (!pendente) throw { publico: 'Convite inválido ou já utilizado.', status: 404 };

  const { error: erroUpdate } = await admin
    .from('profiles')
    .update({ auth_user_id: uid, status_acesso: 'ativo', convite_auth_user_id: null })
    .eq('id', pendente.id);
  if (erroUpdate) {
    // [Item 8 do pedido] Violação do índice único de auth_user_id
    // (código 23505 do Postgres) cai aqui — nunca deixa dois profiles
    // com o mesmo usuário Auth. Diferenciamos essa causa específica de
    // uma falha técnica passageira (rede, timeout) para não dizer
    // "fale com o administrador" quando simplesmente tentar de novo
    // resolveria.
    if (erroUpdate.code === '23505') {
      throw { publico: 'Este usuário já está vinculado a outro perfil. Fale com o administrador.', status: 409, interno: erroUpdate };
    }
    throw { publico: 'Não foi possível concluir o acesso agora. Tente novamente.', status: 502, interno: erroUpdate };
  }

  logAcao('complete_invite', { clinica_id: pendente.clinica_id, alvo_id: pendente.id });
  return { ok: true };
}

// ------------------------------------------------------------
// Dispatch HTTP
// ------------------------------------------------------------
Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS_HEADERS });
  if (req.method !== 'POST') return erroAmigavel('Método não suportado.', 405);

  let body;
  try {
    body = await req.json();
  } catch {
    return erroAmigavel('Corpo da requisição inválido.', 400);
  }

  const acao = body && body.action;
  const admin = clienteAdmin();

  try {
    if (acao === 'complete_invite') {
      const resultado = await acaoCompleteInvite(admin, req);
      return respostaJson(resultado);
    }

    // Toda ação abaixo é administrativa — exige admin ativo da clínica.
    const chamador = await carregarChamadorAdmin(admin, req);
    let resultado;
    switch (acao) {
      case 'invite': resultado = await acaoInvite(admin, chamador, body); break;
      case 'resend_invite': resultado = await acaoResendInvite(admin, chamador, body); break;
      case 'generate_link': resultado = await acaoGenerateLink(admin, chamador, body); break;
      case 'cancel_invite': resultado = await acaoCancelInvite(admin, chamador, body); break;
      case 'deactivate_access': resultado = await acaoDeactivateAccess(admin, chamador, body); break;
      case 'reactivate_access': resultado = await acaoReactivateAccess(admin, chamador, body); break;
      case 'remove_from_team': resultado = await acaoRemoveFromTeam(admin, chamador, body); break;
      default: return erroAmigavel('Ação desconhecida.', 400);
    }
    return respostaJson(resultado);
  } catch (e) {
    if (e && e.publico) {
      if (e.interno) console.error(JSON.stringify({ acao, erro_interno: String(e.interno.message || e.interno) }));
      return erroAmigavel(e.publico, e.status || 400);
    }
    console.error('Erro inesperado na Edge Function equipe-acesso.', e);
    return erroAmigavel('Erro inesperado. Tente novamente.', 500);
  }
});
