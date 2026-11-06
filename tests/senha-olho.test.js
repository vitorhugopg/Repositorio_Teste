// Testes do botão de mostrar/ocultar senha (login e criação de acesso).
// Supabase é simulado; nenhuma senha real é usada nem registrada.
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { chromium, devices } = require('playwright');

const ARQUIVO = 'file://' + path.resolve(__dirname, '..', 'index.html');
const STUB = (temSessao) => `
  window.MORI_SUPABASE_PUBLISHABLE_KEY = 'stub';
  window.__chamadas = [];
  window.supabase = { createClient: () => ({
    auth: {
      getSession: async () => ({ data: { session: ${temSessao} ? { user: { id: 'u1' } } : null } }),
      signOut: async () => ({}),
      updateUser: async (x) => { window.__chamadas.push('updateUser'); return { error: null }; },
      signInWithPassword: async () => { window.__chamadas.push('signIn'); return { error: { message: 'x' } }; },
      onAuthStateChange: () => ({ data: { subscription: { unsubscribe(){} } } })
    },
    from: () => { throw new Error('banco não deve ser tocado'); }
  }) };
`;

async function abrir(browser, { hash, temSessao }, contextOpts) {
  const ctx = await browser.newContext(contextOpts || {});
  const page = await ctx.newPage();
  const requisicoes = [];
  await page.route('**/*', (route) => {
    const url = route.request().url();
    if (url.startsWith('file://')) return route.continue();
    requisicoes.push(url);
    return route.fulfill({ status: 200, contentType: 'application/javascript', body: '' });
  });
  await page.addInitScript(STUB(temSessao));
  await page.goto(ARQUIVO + hash);
  await page.waitForSelector('.login-card');
  return { page, ctx, requisicoes };
}

async function verificarAlternancia(page, seletorInput, seletorBotao) {
  const input = page.locator(seletorInput);
  const botao = page.locator(seletorBotao);
  assert.equal(await input.getAttribute('type'), 'password', 'oculta por padrão');
  assert.equal(await botao.getAttribute('aria-label'), 'Mostrar senha');
  assert.equal(await botao.getAttribute('aria-pressed'), 'false');
  assert.equal(await botao.getAttribute('type'), 'button');
  await input.fill('abc123');
  await botao.click();
  assert.equal(await input.getAttribute('type'), 'text');
  assert.equal(await botao.getAttribute('aria-label'), 'Ocultar senha');
  assert.equal(await botao.getAttribute('aria-pressed'), 'true');
  assert.equal(await input.inputValue(), 'abc123', 'valor preservado');
  assert.equal(await botao.locator('.ico-olho-oculto').isVisible(), true, 'ícone de olho cortado visível');
  assert.equal(await botao.locator('.ico-olho').isVisible(), false);
  await botao.click();
  assert.equal(await input.getAttribute('type'), 'password');
  assert.equal(await botao.locator('.ico-olho').isVisible(), true);
}

test('botão de mostrar/ocultar senha', async (t) => {
  const browser = await chromium.launch();
  t.after(() => browser.close());

  await t.test('login: alterna, ícone muda, valor preservado', async () => {
    const { page, ctx } = await abrir(browser, { hash: '', temSessao: false });
    await verificarAlternancia(page, '#form-login input[name=senha]', '#form-login [data-alternar-senha]');
    await ctx.close();
  });

  await t.test('criar acesso: dois campos independentes', async () => {
    const { page, ctx } = await abrir(browser, { hash: '#access_token=a&type=recovery', temSessao: true });
    await verificarAlternancia(page, '#form-criar-acesso input[name=senha]', '#form-criar-acesso .senha-wrap:nth-of-type(1) [data-alternar-senha], #form-criar-acesso label:nth-of-type(1) [data-alternar-senha]');
    // alternar o primeiro não pode afetar o segundo
    assert.equal(await page.locator('#form-criar-acesso input[name=confirmarSenha]').getAttribute('type'), 'password');
    await page.locator('#form-criar-acesso label:nth-of-type(2) [data-alternar-senha]').click();
    assert.equal(await page.locator('#form-criar-acesso input[name=confirmarSenha]').getAttribute('type'), 'text');
    assert.equal(await page.locator('#form-criar-acesso input[name=senha]').getAttribute('type'), 'password');
    await ctx.close();
  });

  await t.test('nenhum campo de senha fica visível por padrão e não há outros campos de senha', async () => {
    const { page, ctx } = await abrir(browser, { hash: '#access_token=a&type=recovery', temSessao: true });
    const tipos = await page.$$eval('input[name=senha], input[name=confirmarSenha]', (els) => els.map((e) => e.type));
    assert.deepEqual(tipos, ['password', 'password']);
    await ctx.close();
  });

  await t.test('teclado: Tab alcança o botão e Enter/Espaço alternam', async () => {
    const { page, ctx } = await abrir(browser, { hash: '', temSessao: false });
    await page.focus('#form-login input[name=email]');
    await page.keyboard.press('Tab'); // senha
    await page.keyboard.press('Tab'); // botão olho
    const foco = await page.evaluate(() => document.activeElement.hasAttribute('data-alternar-senha'));
    assert.equal(foco, true);
    await page.keyboard.press('Enter');
    assert.equal(await page.locator('#form-login input[name=senha]').getAttribute('type'), 'text');
    await page.keyboard.press('Space');
    assert.equal(await page.locator('#form-login input[name=senha]').getAttribute('type'), 'password');
    await ctx.close();
  });

  await t.test('leitor de tela: input tem nome acessível próprio e botão tem nome', async () => {
    const { page, ctx } = await abrir(browser, { hash: '', temSessao: false });
    assert.equal(await page.locator('#form-login input[name=senha]').getAttribute('aria-label'), 'Senha');
    const nome = await page.getByRole('button', { name: 'Mostrar senha' }).count();
    assert.equal(nome, 1);
    assert.equal(await page.getByRole('textbox', { name: 'Senha', exact: true }).count() + await page.locator('input[type=password][aria-label=Senha]').count() > 0, true);
    await ctx.close();
  });

  await t.test('celular: toque alterna, alvo >= 44px, sem rolagem horizontal', async () => {
    const { page, ctx } = await abrir(browser, { hash: '', temSessao: false }, { ...devices['iPhone 12'] });
    const botao = page.locator('#form-login [data-alternar-senha]');
    const caixa = await botao.boundingBox();
    assert.ok(caixa.width >= 44 && caixa.height >= 44, `alvo pequeno: ${caixa.width}x${caixa.height}`);
    await botao.tap();
    assert.equal(await page.locator('#form-login input[name=senha]').getAttribute('type'), 'text');
    const sobra = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
    assert.ok(sobra <= 0, 'rolagem horizontal');
    await ctx.close();
  });

  await t.test('alternar não envia o formulário, não chama autenticação e não faz requisição', async () => {
    const { page, ctx, requisicoes } = await abrir(browser, { hash: '', temSessao: false });
    await page.fill('#form-login input[name=senha]', 'xyz');
    await page.click('#form-login [data-alternar-senha]');
    await page.click('#form-login [data-alternar-senha]');
    assert.deepEqual(await page.evaluate(() => window.__chamadas), []);
    assert.deepEqual(requisicoes.filter((u) => /supabase/i.test(u) && !u.includes('cdn.jsdelivr.net')), []);
    await ctx.close();
  });

  await t.test('senha não é gravada em storage nem logada no console', async () => {
    const { page, ctx } = await abrir(browser, { hash: '', temSessao: false });
    const logs = [];
    page.on('console', (m) => logs.push(m.text()));
    await page.fill('#form-login input[name=senha]', 'SEGREDO-UNICO-123');
    await page.click('#form-login [data-alternar-senha]');
    const storage = await page.evaluate(() => JSON.stringify(localStorage) + JSON.stringify(sessionStorage) + document.cookie);
    assert.equal(storage.includes('SEGREDO-UNICO-123'), false);
    assert.equal(logs.join('\n').includes('SEGREDO-UNICO-123'), false);
    await ctx.close();
  });

  await t.test('criar acesso: enviar o formulário continua chamando updateUser (fluxo intacto)', async () => {
    const { page, ctx } = await abrir(browser, { hash: '#access_token=a&type=recovery', temSessao: true });
    await page.fill('#form-criar-acesso input[name=senha]', 'senha123');
    await page.fill('#form-criar-acesso input[name=confirmarSenha]', 'senha123');
    await page.click('#form-criar-acesso label:nth-of-type(1) [data-alternar-senha]');
    await page.click('#form-criar-acesso button[type=submit]');
    await page.waitForFunction(() => window.__chamadas.includes('updateUser'));
    await ctx.close();
  });
});
