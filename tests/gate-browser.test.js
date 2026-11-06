// Testes de navegador (Chromium/Playwright) do portão de autenticação do index.html.
// Supabase é substituído por um stub: nenhuma chamada de rede, nenhum dado real.
// Rodar: node --test tests/
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { chromium } = require('playwright');

const ARQUIVO = 'file://' + path.resolve(__dirname, '..', 'index.html');

const STUB = (temSessao) => `
  window.MORI_SUPABASE_PUBLISHABLE_KEY = 'stub';
  window.supabase = { createClient: () => ({
    auth: {
      getSession: async () => ({ data: { session: ${temSessao} ? { user: { id: 'u1' } } : null } }),
      signOut: async () => ({}),
      updateUser: async () => ({ error: null }),
      onAuthStateChange: () => ({ data: { subscription: { unsubscribe(){} } } })
    },
    from: () => { throw new Error('banco não deve ser tocado nestes testes'); }
  }) };
`;

async function abrir(browser, { hash, temSessao }) {
  const page = await browser.newPage();
  await page.route('**/*', (route) => {
    const url = route.request().url();
    if (url.startsWith('file://')) return route.continue();
    return route.fulfill({ status: 200, contentType: 'application/javascript', body: '' });
  });
  await page.addInitScript(STUB(temSessao));
  await page.goto(ARQUIVO + hash);
  await page.waitForSelector('.login-card', { timeout: 10000 });
  return page;
}

test('portão de autenticação', async (t) => {
  const browser = await chromium.launch();
  t.after(() => browser.close());

  await t.test('recovery válido com sessão -> "Criar seu acesso"', async () => {
    const page = await abrir(browser, { hash: '#access_token=a&refresh_token=b&type=recovery', temSessao: true });
    assert.match(await page.locator('.login-card').innerText(), /Criar seu acesso/);
    assert.equal(await page.locator('#form-criar-acesso').count(), 1);
    await page.close();
  });

  await t.test('invite válido com sessão -> "Criar seu acesso"', async () => {
    const page = await abrir(browser, { hash: '#access_token=a&type=invite', temSessao: true });
    assert.match(await page.locator('.login-card').innerText(), /Criar seu acesso/);
    await page.close();
  });

  await t.test('recovery sem sessão -> convite inválido (não o login)', async () => {
    const page = await abrir(browser, { hash: '#type=recovery', temSessao: false });
    const txt = await page.locator('.login-card').innerText();
    assert.match(txt, /Convite inválido/);
    assert.equal(await page.locator('#form-login').count(), 0);
    await page.close();
  });

  await t.test('link expirado (otp_expired) -> mensagem clara, não o login', async () => {
    const page = await abrir(browser, {
      hash: '#error=access_denied&error_code=otp_expired&error_description=Email+link+is+invalid+or+has+expired',
      temSessao: false,
    });
    const txt = await page.locator('.login-card').innerText();
    assert.match(txt, /expirou ou já foi usado/);
    assert.equal(await page.locator('#form-login').count(), 0);
    await page.close();
  });

  await t.test('link expirado mesmo havendo sessão antiga -> continua mostrando o aviso', async () => {
    const page = await abrir(browser, { hash: '#error=access_denied&error_code=otp_expired', temSessao: true });
    assert.match(await page.locator('.login-card').innerText(), /expirou ou já foi usado/);
    await page.close();
  });

  await t.test('botão "Ir para o login" leva ao formulário de login', async () => {
    const page = await abrir(browser, { hash: '#error=access_denied&error_code=otp_expired', temSessao: false });
    await page.click('#btn-ir-para-login');
    await page.waitForSelector('#form-login');
    await page.close();
  });

  await t.test('sem hash e sem sessão -> login normal', async () => {
    const page = await abrir(browser, { hash: '', temSessao: false });
    assert.equal(await page.locator('#form-login').count(), 1);
    await page.close();
  });
});
