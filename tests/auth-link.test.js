// Testes unitários do leitor de links de convite/recovery.
// Rodar: node --test tests/
const test = require('node:test');
const assert = require('node:assert/strict');
const { interpretarLinkAuth, mensagemErroLinkAuth } = require('../auth-link.js');

test('link recovery válido: tipo recovery, com token, sem erro', () => {
  const r = interpretarLinkAuth('#access_token=abc&refresh_token=def&expires_in=3600&type=recovery', '');
  assert.equal(r.tipo, 'recovery');
  assert.equal(r.temToken, true);
  assert.equal(r.erro, null);
});

test('link invite válido', () => {
  const r = interpretarLinkAuth('#access_token=abc&type=invite', '');
  assert.equal(r.tipo, 'invite');
  assert.equal(r.erro, null);
});

test('link expirado/já usado: erro otp_expired e nenhum tipo', () => {
  const r = interpretarLinkAuth('#error=access_denied&error_code=otp_expired&error_description=Email+link+is+invalid+or+has+expired', '');
  assert.equal(r.tipo, null);
  assert.equal(r.temToken, false);
  assert.equal(r.erro.codigo, 'otp_expired');
  assert.match(mensagemErroLinkAuth(r.erro), /expirou ou já foi usado/);
});

test('erro access_denied sem código usa mensagem de link inválido', () => {
  const r = interpretarLinkAuth('#error=access_denied', '');
  assert.equal(r.erro.codigo, 'access_denied');
  assert.match(mensagemErroLinkAuth(r.erro), /não é mais válido/);
});

test('erro desconhecido usa mensagem genérica, sem texto técnico cru', () => {
  const r = interpretarLinkAuth('#error=server_error&error_code=unexpected_failure&error_description=boom', '');
  const msg = mensagemErroLinkAuth(r.erro);
  assert.match(msg, /Não foi possível validar/);
  assert.doesNotMatch(msg, /boom|unexpected_failure/);
});

test('erro também é lido da query string', () => {
  const r = interpretarLinkAuth('', '?error=access_denied&error_code=otp_expired');
  assert.equal(r.erro.codigo, 'otp_expired');
});

test('sem hash: nada de especial', () => {
  const r = interpretarLinkAuth('', '');
  assert.deepEqual(r, { tipo: null, temToken: false, erro: null });
});

test('entradas inválidas não lançam exceção', () => {
  assert.doesNotThrow(() => interpretarLinkAuth(undefined, null));
});

test('o resultado nunca carrega o valor do token', () => {
  const r = interpretarLinkAuth('#access_token=SEGREDO123&type=recovery', '');
  assert.equal(JSON.stringify(r).includes('SEGREDO123'), false);
});
