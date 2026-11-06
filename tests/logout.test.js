// Testes do botão "Sair do CRM". Supabase simulado; nenhum dado real.
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { chromium, devices } = require('playwright');

const ARQUIVO = 'file://' + path.resolve(__dirname, '..', 'index.html');
const STUB = `
  window.MORI_SUPABASE_PUBLISHABLE_KEY = 'stub';
  window.__sessao = { user: { id: 'u1' } };
  window.__signOutModo = 'ok';   // 'ok' | 'erro' | 'excecao'
  window.__signOutChamadas = 0;
  window.__signOutArgs = [];
  window.supabase = { createClient: () => ({
    auth: {
      getSession: async () => ({ data: { session: window.__sessao } }),
      signOut: async (...args) => {
        window.__signOutChamadas++;
        window.__signOutArgs.push(args);
        if (window.__signOutModo === 'excecao') throw new Error('rede caiu');
        if (window.__signOutModo === 'erro') return { error: { message: 'falha de rede' } };
        window.__sessao = null;
        return { error: null };
      },
      onAuthStateChange: () => ({ data: { subscription: { unsubscribe(){} } } })
    },
    from: () => { throw new Error('banco não deve ser tocado'); }
  }) };
`;

async function abrirLogado(browser, ctxOpts) {
  const ctx = await browser.newContext(ctxOpts || {});
  const page = await ctx.newPage();
  await page.route('**/*', (r) => r.request().url().startsWith('file://')
    ? r.continue() : r.fulfill({ status: 200, contentType: 'application/javascript', body: '' }));
  await page.addInitScript(STUB);
  await page.goto(ARQUIVO);
  await page.waitForSelector('.login-card'); // sem perfil real: cai no gate; montamos o CRM logado à mão
  await page.evaluate(() => {
    DB = buildInitialState();
    DB.usuarioAtual = { id: 'p1', clinicaId: 'c1', role: 'admin', nome: 'Mariana Teste', cargo: 'Gestora' };
    DB.pacientes = [{ id: 'x1', nome: 'PACIENTE-SIGILOSO-XYZ', telefone: '', procedimentos: [], etapa: 'Novo Lead', origem: '', responsavel: '', dataContato: '2026-01-01' }];
    render();
  });
  return { page, ctx };
}

test('Sair do CRM', async (t) => {
  const browser = await chromium.launch();
  t.after(() => browser.close());

  await t.test('botão aparece no rodapé do menu, junto ao nome do usuário, com ícone e rótulo', async () => {
    const { page, ctx } = await abrirLogado(browser);
    const foot = page.locator('.sidebar-foot');
    assert.match(await foot.innerText(), /Mariana Teste/);
    const btn = foot.locator('[data-action="sair-crm"]');
    assert.equal(await btn.count(), 1);
    assert.equal(await btn.locator('svg').count(), 1);
    assert.equal(await page.getByRole('button', { name: 'Sair do CRM' }).count(), 1);
    assert.equal(await btn.getAttribute('type'), 'button');
    await ctx.close();
  });

  await t.test('sucesso: chama signOut uma vez, volta ao login e remove dados da tela e da memória', async () => {
    const { page, ctx } = await abrirLogado(browser);
    await page.evaluate(() => navigate('pacientes'));
    assert.match(await page.locator('#content').innerText(), /PACIENTE-SIGILOSO-XYZ/);
    await page.click('[data-action="sair-crm"]');
    await page.waitForSelector('#form-login');
    assert.equal(await page.evaluate(() => window.__signOutChamadas), 1);
    assert.deepEqual(await page.evaluate(() => window.__signOutArgs), [[{ scope: 'local' }]], 'signOut deve usar scope local');
    assert.equal(await page.evaluate(() => window.__sessao), null);
    assert.equal((await page.content()).includes('PACIENTE-SIGILOSO-XYZ'), false, 'dado sigiloso no DOM');
    assert.equal(await page.evaluate(() => DB.pacientes.length), 0, 'pacientes na memória');
    assert.equal(await page.locator('.sidebar').count(), 0);
    await ctx.close();
  });

  await t.test('após sair, recarregar a página mostra o login (sem sessão)', async () => {
    const { page, ctx } = await abrirLogado(browser);
    await page.click('[data-action="sair-crm"]');
    await page.waitForSelector('#form-login');
    // sessão simulada já nula: um novo boot deve cair no login
    await page.evaluate(() => iniciarSupabase());
    await page.waitForSelector('#form-login');
    assert.equal(await page.locator('.sidebar').count(), 0);
    await ctx.close();
  });

  await t.test('sair fecha modal aberto', async () => {
    const { page, ctx } = await abrirLogado(browser);
    await page.evaluate(() => { document.getElementById('modal-root').innerHTML = '<div class="modal">PACIENTE-SIGILOSO-XYZ</div>'; });
    await page.click('[data-action="sair-crm"]');
    await page.waitForSelector('#form-login');
    assert.equal(await page.locator('#modal-root').innerHTML(), '');
    await ctx.close();
  });

  for (const modo of ['erro', 'excecao']) {
    await t.test(`falha no signOut (${modo}): mensagem clara, continua logado, botão volta a funcionar`, async () => {
      const { page, ctx } = await abrirLogado(browser);
      await page.evaluate((m) => { window.__signOutModo = m; }, modo);
      await page.click('[data-action="sair-crm"]');
      await page.waitForSelector('.toast');
      const msg = await page.locator('.toast').innerText();
      assert.match(msg, /Não foi possível sair/);
      assert.match(msg, /continua conectado/);
      assert.equal(await page.locator('#form-login').count(), 0, 'não pode ir ao login');
      assert.equal(await page.locator('.sidebar').count(), 1, 'CRM continua na tela');
      const btn = page.locator('[data-action="sair-crm"]');
      assert.equal(await btn.isDisabled(), false);
      assert.equal(await btn.innerText(), 'Sair do CRM');
      // nova tentativa com sucesso
      await page.evaluate(() => { window.__signOutModo = 'ok'; });
      await btn.click();
      await page.waitForSelector('#form-login');
      await ctx.close();
    });
  }

  await t.test('clique duplo rápido chama signOut só uma vez', async () => {
    const { page, ctx } = await abrirLogado(browser);
    await page.evaluate(() => { document.querySelector('[data-action="sair-crm"]').click(); document.querySelector('[data-action="sair-crm"]')?.click(); });
    await page.waitForSelector('#form-login');
    assert.equal(await page.evaluate(() => window.__signOutChamadas), 1);
    await ctx.close();
  });

  await t.test('teclado: Enter no botão encerra a sessão', async () => {
    const { page, ctx } = await abrirLogado(browser);
    await page.focus('[data-action="sair-crm"]');
    await page.keyboard.press('Enter');
    await page.waitForSelector('#form-login');
    await ctx.close();
  });

  await t.test('celular: botão visível, alvo >= 44px e toque encerra a sessão', async () => {
    const { page, ctx } = await abrirLogado(browser, { ...devices['iPhone 12'] });
    const btn = page.locator('[data-action="sair-crm"]');
    await btn.scrollIntoViewIfNeeded();
    const caixa = await btn.boundingBox();
    assert.ok(caixa.height >= 44, `altura ${caixa.height}`);
    await btn.tap();
    await page.waitForSelector('#form-login');
    await ctx.close();
  });

  await t.test('não grava nada em storage nem no console durante o logout', async () => {
    const { page, ctx } = await abrirLogado(browser);
    const logs = [];
    page.on('console', (m) => logs.push(m.text()));
    await page.click('[data-action="sair-crm"]');
    await page.waitForSelector('#form-login');
    const storage = await page.evaluate(() => JSON.stringify(localStorage) + JSON.stringify(sessionStorage));
    assert.equal(storage.includes('PACIENTE-SIGILOSO-XYZ'), false);
    assert.equal(logs.join('\n').includes('PACIENTE-SIGILOSO-XYZ'), false);
    await ctx.close();
  });

  await t.test('telas de convite/criação de acesso continuam sem o botão de sair do CRM', async () => {
    const ctx = await browser.newContext();
    const page = await ctx.newPage();
    await page.route('**/*', (r) => r.request().url().startsWith('file://')
      ? r.continue() : r.fulfill({ status: 200, contentType: 'application/javascript', body: '' }));
    await page.addInitScript(STUB);
    await page.goto(ARQUIVO + '#access_token=a&type=recovery');
    await page.waitForSelector('#form-criar-acesso');
    assert.equal(await page.locator('[data-action="sair-crm"]').count(), 0);
    await ctx.close();
  });
});
