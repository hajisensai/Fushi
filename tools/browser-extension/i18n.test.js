// 扩展多语言（用户 2026-09-18「扩展要支持不同语言、和 Fushi 一致」）：
//  ① 字典守卫：locales/<tag>.json 键集与占位符集合必须与 en.js 逐键一致，SUPPORTED 与 app 的
//     Slang 清单一致，每个 tag 都有文件；
//  ② 运行时决议：extensionLanguage=app 跟 background 写入的 appLocale，缺失回落浏览器语言；
//     browser 只看浏览器；固定 tag 就固定；zh-TW → zh-HK、pt → pt-BR；
//  ③ t() 在目标字典缺键时回落英文；占位符替换；applyToDocument 重写 data-i18n* 与 lang/dir；
//  ④ 各消费模块的 tr() 不带 i18n 时退回键名而不崩；HTML/JS 里不再残留裸中文文案。
const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { loadEn, loadDict } = require('./scripts/i18n-fixture.js');

const LOCALES = path.join(__dirname, 'locales');
const APP_I18N = path.join(__dirname, '..', '..', 'fushi', 'lib', 'i18n');
const I18N_SRC = fs.readFileSync(path.join(__dirname, 'i18n.js'), 'utf8');
const EN_SRC = fs.readFileSync(path.join(LOCALES, 'en.js'), 'utf8');

function placeholders(s) {
  return String(s).match(/\{\w+\}|%d|<kbd>|<b>/g) || [];
}

test('字典守卫：每种语言键集、占位符与英文源逐键一致，且没有值是空串', () => {
  const en = loadEn();
  const enKeys = Object.keys(en);
  assert.ok(enKeys.length > 200, 'en.js 应是完整源字典');
  const files = fs.readdirSync(LOCALES).filter((f) => f.endsWith('.json'));
  assert.ok(files.length >= 16, '至少 16 种非英语语言');
  for (const f of files) {
    const dict = JSON.parse(fs.readFileSync(path.join(LOCALES, f), 'utf8'));
    const keys = Object.keys(dict);
    assert.deepStrictEqual(keys.filter((k) => !(k in en)), [], f + ' 有 en 里没有的键');
    assert.deepStrictEqual(enKeys.filter((k) => !(k in dict)), [], f + ' 缺键');
    for (const k of enKeys) {
      assert.strictEqual(typeof dict[k], 'string', f + ':' + k + ' 不是字符串');
      assert.ok(dict[k].trim() !== '', f + ':' + k + ' 为空');
      assert.deepStrictEqual(placeholders(dict[k]).sort(), placeholders(en[k]).sort(),
        f + ':' + k + ' 占位符/标签与英文不一致');
    }
  }
});

test('SUPPORTED 与 app 的 Slang 语言清单一致，每个 tag（除 en）都有 locales/<tag>.json', () => {
  const appTags = fs.readdirSync(APP_I18N)
    .map((f) => /^strings(?:_([A-Za-z-]+))?\.i18n\.json$/.exec(f))
    .filter(Boolean)
    .map((m) => m[1] || 'en');
  const m = /SUPPORTED = \[([\s\S]*?)\];/.exec(I18N_SRC);
  const supported = m[1].match(/'([^']+)'/g).map((s) => s.slice(1, -1));
  assert.deepStrictEqual(supported.slice().sort(), appTags.slice().sort(), '扩展支持的语言必须与 app 一致');
  for (const tag of supported) {
    if (tag === 'en') continue;
    assert.ok(fs.existsSync(path.join(LOCALES, tag + '.json')), '缺 locales/' + tag + '.json');
  }
});

function loadI18n(opts) {
  opts = opts || {};
  const stored = Object.assign({}, opts.stored);
  const changeListeners = [];
  const fetched = [];
  const dicts = opts.dicts || {};
  const sandbox = {
    console,
    navigator: { language: opts.browser || 'en-US', languages: opts.browser ? [opts.browser] : ['en-US'] },
    location: { protocol: opts.protocol || 'https:' },
    chrome: {
      runtime: { getURL: (rel) => 'chrome-extension://x/' + rel },
      storage: {
        local: {
          get: (keys, cb) => { const out = {}; for (const k of [].concat(keys)) if (k in stored) out[k] = stored[k]; cb(out); },
          set: (patch) => {
            const changes = {};
            for (const k of Object.keys(patch)) { changes[k] = { newValue: patch[k] }; stored[k] = patch[k]; }
            for (const fn of changeListeners) fn(changes, 'local');
          },
        },
        onChanged: { addListener: (fn) => changeListeners.push(fn) },
      },
    },
    fetch: (url) => {
      fetched.push(url);
      const tag = /locales\/(.+)\.json$/.exec(url)[1];
      const dict = dicts[tag] || (fs.existsSync(path.join(LOCALES, tag + '.json')) ? loadDict(tag) : null);
      return Promise.resolve({ ok: !!dict, json: () => Promise.resolve(dict) });
    },
  };
  sandbox.window = sandbox;
  sandbox.self = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(EN_SRC, sandbox, { filename: 'locales/en.js' });
  vm.runInContext(I18N_SRC, sandbox, { filename: 'i18n.js' });
  return { sandbox, stored, fetched, i18n: sandbox.fushiI18n, set: (p) => sandbox.chrome.storage.local.set(p) };
}
const flush = () => new Promise((r) => setTimeout(r, 0));

test('默认跟随 Fushi：appLocale=ja → 装 ja 字典；app 没告诉过语言 → 回落浏览器语言', async () => {
  const h = loadI18n({ stored: { appLocale: 'ja' }, browser: 'de-DE' });
  await flush();
  assert.strictEqual(h.i18n.locale, 'ja');
  assert.strictEqual(h.i18n.t('ctx_cancel'), loadDict('ja').ctx_cancel);
  const h2 = loadI18n({ browser: 'de-DE' });
  await flush();
  assert.strictEqual(h2.i18n.locale, 'de', '拿不到 app 语言时用浏览器语言');
});

test('extensionLanguage=browser 只看浏览器；固定 tag 就固定；改设置即切换', async () => {
  const h = loadI18n({ stored: { appLocale: 'ja', extensionLanguage: 'browser' }, browser: 'ko' });
  await flush();
  assert.strictEqual(h.i18n.locale, 'ko');
  h.set({ extensionLanguage: 'fr' });
  await flush();
  assert.strictEqual(h.i18n.locale, 'fr');
  h.set({ extensionLanguage: 'app' });
  await flush();
  assert.strictEqual(h.i18n.locale, 'ja');
  h.set({ appLocale: 'zh-CN' });
  await flush();
  assert.strictEqual(h.i18n.locale, 'zh-CN', 'app 切语言（background 写 appLocale）扩展跟着切');
});

test('tag 归一：zh-TW/zh-Hant → zh-HK，zh → zh-CN，pt → pt-BR，en-GB → en，未知 → null', () => {
  const h = loadI18n();
  const n = h.i18n.normalizeTag;
  assert.strictEqual(n('zh-TW'), 'zh-HK');
  assert.strictEqual(n('zh-Hant-HK'), 'zh-HK');
  assert.strictEqual(n('zh'), 'zh-CN');
  assert.strictEqual(n('zh_CN'), 'zh-CN');
  assert.strictEqual(n('pt'), 'pt-BR');
  assert.strictEqual(n('pt-PT'), 'pt-BR');
  assert.strictEqual(n('en-GB'), 'en');
  assert.strictEqual(n('xx'), null);
  assert.strictEqual(n(''), null);
});

test('t()：目标字典缺键回落英文、未知键回落键名、占位符替换', async () => {
  const h = loadI18n({ stored: { extensionLanguage: 'ja' }, dicts: { ja: { ctx_cancel: 'キャンセル' } } });
  await flush();
  assert.strictEqual(h.i18n.t('ctx_cancel'), 'キャンセル');
  assert.strictEqual(h.i18n.t('ctx_confirm'), loadEn().ctx_confirm, '缺键回落英文');
  assert.strictEqual(h.i18n.t('nope_key'), 'nope_key');
  assert.strictEqual(h.i18n.t('gen_progress', { done: 2, total: 5 }), 'Generating… 2/5');
});

test('applyToDocument：重写 data-i18n / -html / -title / -placeholder / -aria-label 与 lang/dir，换语言即重写', async () => {
  const h = loadI18n({ stored: { extensionLanguage: 'ar' } });
  const nodes = [
    { attrs: { 'data-i18n': 'ctx_cancel' }, textContent: '' },
    { attrs: { 'data-i18n-title': 'sp_load_title' } },
    { attrs: { 'data-i18n-placeholder': 'sp_subs_ep_placeholder' } },
    { attrs: { 'data-i18n-aria-label': 'sp_track_aria_label' } },
    { attrs: { 'data-i18n-html': 'opt_subtitleHidden_desc' }, innerHTML: '' },
  ];
  for (const n of nodes) {
    n.getAttribute = (k) => (k in n.attrs ? n.attrs[k] : null);
    n.setAttribute = (k, v) => { n.attrs[k] = v; };
  }
  const rootAttrs = {};
  const doc = {
    documentElement: { setAttribute: (k, v) => { rootAttrs[k] = v; } },
    querySelectorAll: () => nodes,
    querySelector: () => null,
  };
  h.i18n.applyToDocument(doc);
  await flush();
  const ar = loadDict('ar');
  assert.strictEqual(nodes[0].textContent, ar.ctx_cancel);
  assert.strictEqual(nodes[1].attrs.title, ar.sp_load_title);
  assert.strictEqual(nodes[2].attrs.placeholder, ar.sp_subs_ep_placeholder);
  assert.strictEqual(nodes[3].attrs['aria-label'], ar.sp_track_aria_label);
  assert.strictEqual(nodes[4].innerHTML, ar.opt_subtitleHidden_desc);
  assert.strictEqual(rootAttrs.lang, 'ar');
  assert.strictEqual(rootAttrs.dir, 'rtl', '阿拉伯语要 rtl');
  h.set({ extensionLanguage: 'en' });
  await flush();
  assert.strictEqual(nodes[0].textContent, loadEn().ctx_cancel);
  assert.strictEqual(rootAttrs.dir, 'ltr');
});

test('扩展页面（chrome-extension:）自动套用；宿主页里不动 <html>', async () => {
  let applied = 0;
  const mk = (protocol) => {
    const h = loadI18n({ protocol });
    return h;
  };
  // 宿主页：没有 document 时也不能抛（content script 在 window 上、无自动套用）
  mk('https:');
  const ext = loadI18n({ protocol: 'chrome-extension:' });
  ext.sandbox.document = { readyState: 'complete', documentElement: { setAttribute() { applied += 1; } }, querySelectorAll: () => [], querySelector: () => null };
  // 自动套用发生在装入时（document 需先存在）：重装一次验证
  const again = loadI18n({ protocol: 'chrome-extension:' });
  again.sandbox.document = ext.sandbox.document;
  vm.runInContext(I18N_SRC, again.sandbox, { filename: 'i18n.js' });
  await flush();
  assert.ok(applied >= 2, '扩展页面装入即写 lang/dir');
});

test('各模块的 tr() 没有 i18n 时退回键名而不崩；HTML 与 JS 不再残留裸中文界面文案', () => {
  const cjk = /[一-鿿]/;
  for (const f of ['options.html', 'side-panel.html', 'vendor/action-popup.html', 'nested-popup.html']) {
    const html = fs.readFileSync(path.join(__dirname, f), 'utf8')
      .replace(/<!--[\s\S]*?-->/g, '')
      .replace(/<style>[\s\S]*?<\/style>/g, '');
    // 每个含中文的文本节点 / 属性都必须挂 data-i18n*；语言选项的本地语名除外。
    const leaks = [];
    for (const m of html.matchAll(/<([a-z0-9]+)\b([^>]*)>([^<]*)/g)) {
      const [, tag, attrs, text] = m;
      if (!cjk.test(text)) continue;
      if (tag === 'option' && /value="[a-z]{2}(-[A-Z]{2})?"/.test(attrs)) continue;
      if (tag === 'b' || tag === 'kbd') continue; // 父节点经 data-i18n-html 整段注入
      if (!/data-i18n/.test(attrs)) leaks.push(f + ': <' + tag + '> ' + text.trim().slice(0, 30));
    }
    for (const m of html.matchAll(/\b(title|placeholder|aria-label)="([^"]*)"/g)) {
      if (cjk.test(m[2]) && !html.includes('data-i18n-' + m[1] + '="')) leaks.push(f + ': ' + m[1]);
    }
    assert.deepStrictEqual(leaks, [], f + ' 有未国际化的中文文案');
  }
  // JS：除注释、字幕轨身份前缀（'外挂:'、' (自动)'、' →译' 是 store key 的一部分，改了会拆轨）
  // 与 console 诊断外，不得再有中文字符串字面量。
  const allow = new Set(["'外挂:'", "' (自动)'", "' →译'"]);
  const files = fs.readdirSync(__dirname).filter((f) => f.endsWith('.js') && !f.endsWith('.test.js'))
    .concat(['vendor/action-popup.js']);
  const leaks = [];
  for (const f of files) {
    const src = fs.readFileSync(path.join(__dirname, f), 'utf8').replace(/\/\*[\s\S]*?\*\//g, '');
    for (const line of src.split('\n')) {
      const code = line.replace(/(^|[^:\\])\/\/.*$/, '$1');
      if (/console\.(warn|log|error)/.test(code)) continue;
      for (const m of code.matchAll(/'(?:[^'\\\n]|\\.)*'|"(?:[^"\\\n]|\\.)*"|`(?:[^`\\]|\\.)*`/g)) {
        if (cjk.test(m[0]) && !allow.has(m[0])) leaks.push(f + ': ' + m[0].slice(0, 40));
      }
    }
  }
  assert.deepStrictEqual(leaks, [], '有未走 i18n 的中文字面量');
  // 没装 i18n 的壳：tr 退回键名
  const sandbox = { window: {}, self: {}, console };
  sandbox.window.window = sandbox.window;
  vm.createContext(sandbox);
  vm.runInContext(fs.readFileSync(path.join(__dirname, 'connection-diagnostics.js'), 'utf8'), sandbox);
  assert.strictEqual(sandbox.self.FUSHI_CONNECTION.copy('connected', 19633).title, 'conn_state_connected_title');
});
