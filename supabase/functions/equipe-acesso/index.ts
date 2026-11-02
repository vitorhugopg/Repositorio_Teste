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
  if (erroUpdate) throw { publico: 'Convite criado, mas houve erro ao vincular ao perfil. Avise o suporte técnico.', status: 500, interno: erroUpdate };

  logAcao('invite', { clinica_id: chamador.clinica_id, chamador_id: chamador.id, alvo_id: alvo.id });
  return { ok: true, status_acesso: 'pendente' };
}

async function acaoResendInvite(admin, chamador, body) {
  const alvo = await carregarPerfilAlvoNaMesmaClinica(admin, chamador, body.target_profile_id);
  if (alvo.status_acesso !== 'pendente' || !alvo.email) {
    throw { publico: 'Esta pessoa não tem um convite pendente para reenviar.', status: 409 };
  }

  // [Item 10 do pedido — "não fingir que um link expirado continua
  // válido"] Reenviar sempre substitui o convite anterior por um novo
  // (apaga o usuário Auth pendente anterior, nunca usado, e cria outro)
  // — garante um e-mail novo de verdade, sem depender do comportamento
  // ambíguo do Supabase para "convidar de novo o mesmo e-mail ainda não
  // confirmado" (ver relatório desta rodada).
  if (alvo.convite_auth_user_id) {
    const { error: erroDelete } = await admin.auth.admin.deleteUser(alvo.convite_auth_user_id);
    if (erroDelete && erroDelete.status !== 404) {
      throw { publico: 'Não foi possível reenviar agora. Tente novamente.', status: 502, interno: erroDelete };
    }
  }

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
  if (erroUpdate) throw { publico: 'Convite reenviado, mas houve erro ao atualizar o perfil. Avise o suporte técnico.', status: 500, interno: erroUpdate };

  logAcao('resend_invite', { clinica_id: chamador.clinica_id, chamador_id: chamador.id, alvo_id: alvo.id });
  return { ok: true };
}

async function acaoGenerateLink(admin, chamador, body) {
  const alvo = await carregarPerfilAlvoNaMesmaClinica(admin, chamador, body.target_profile_id);
  if (alvo.status_acesso !== 'pendente' || !alvo.email) {
    throw { publico: 'Esta pessoa não tem um convite pendente.', status: 409 };
  }

  // [Correção pedida pelo administrador] Convite e recuperação de senha
  // são fluxos deliberadamente separados — generate_link NUNCA usa
  // type:'recovery'. Confirmado lendo o código-fonte oficial do GoTrue
  // (supabase/auth, internal/api/mail.go, adminGenerateLink — branch
  // `case mail.InviteVerification`, e internal/api/invite.go, mesmo
  // racional): gerar um link de convite (`type:'invite'`) para um
  // e-mail que já tem um usuário Auth PENDENTE (ainda não confirmado)
  // NÃO é erro — o servidor reutiliza o MESMO usuário, sobrescreve o
  // token de confirmação anterior (invalidando o link antigo) e retorna
  // um novo `action_link` válido. Essa chamada só falha de verdade se o
  // usuário já estiver CONFIRMADO (não deveria acontecer para um
  // profile que acabamos de validar como status_acesso='pendente') ou
  // por uma falha técnica passageira — nunca por "já existir um
  // usuário pendente", que é exatamente o caso normal de uso aqui.
  const gerarLinkDeConvite = () => admin.auth.admin.generateLink({
    type: 'invite',
    email: alvo.email,
    options: { redirectTo: appBaseUrl() },
  });

  let { data: linkGerado, error: erroGerar } = await gerarLinkDeConvite();

  if (erroGerar || !linkGerado) {
    // [Rede de segurança — só entra aqui numa falha técnica real, nunca
    // no caminho normal] Recria o convite pendente do zero, usando
    // SOMENTE o mecanismo oficial de convite (nunca recovery) — mesma
    // estratégia já usada em resend_invite: invalida/remove o usuário
    // Auth pendente anterior e convida de novo.
    if (alvo.convite_auth_user_id) {
      const { error: erroDelete } = await admin.auth.admin.deleteUser(alvo.convite_auth_user_id);
      if (erroDelete && erroDelete.status !== 404) {
        throw { publico: 'Não foi possível gerar o link. Tente novamente.', status: 502, interno: erroDelete };
      }
    }
    ({ data: linkGerado, error: erroGerar } = await gerarLinkDeConvite());
    if (erroGerar || !linkGerado) {
      throw { publico: 'Não foi possível gerar o link. Tente novamente.', status: 502, interno: erroGerar };
    }
    // A recriação pode ter gerado um novo auth.users.id — mantém
    // convite_auth_user_id apontando para o usuário Auth que o link
    // retornado realmente referencia (nunca para o antigo, já apagado).
    const novoAuthUserId = linkGerado.user && linkGerado.user.id;
    if (novoAuthUserId && novoAuthUserId !== alvo.convite_auth_user_id) {
      const { error: erroUpdateId } = await admin.from('profiles').update({ convite_auth_user_id: novoAuthUserId }).eq('id', alvo.id);
      if (erroUpdateId) throw { publico: 'Link gerado, mas houve erro ao atualizar o perfil. Avise o suporte técnico.', status: 500, interno: erroUpdateId };
    }
  }

  const actionLink = linkGerado.properties && linkGerado.properties.action_link;
  if (!actionLink) throw { publico: 'Não foi possível gerar o link. Tente novamente.', status: 502 };

  logAcao('generate_link', { clinica_id: chamador.clinica_id, chamador_id: chamador.id, alvo_id: alvo.id });
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
    // [Item 8 do pedido] Violação do índice único de auth_user_id cai
    // aqui — nunca deixa dois profiles com o mesmo usuário Auth.
    throw { publico: 'Não foi possível concluir o acesso. Fale com o administrador.', status: 409, interno: erroUpdate };
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
