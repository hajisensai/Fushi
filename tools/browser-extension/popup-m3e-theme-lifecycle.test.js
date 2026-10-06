// 查词弹窗 M3E 调色生命周期 + 「跟随 Fushi」镜像（由 tool/review_repros/popup_m3e_theme_round5.repro.mjs
// 迁来，Codex 第五轮 HBK-AUDIT-029 / 030；015 的观察器路径一并保留）。真源函数 + 最小 DOM / CSS /
// MutationObserver / RAF 边界。
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const path = require('node:path');
const { runInNewContext } = require('node:vm');

const source = readFileSync(path.join(__dirname, 'vendor', 'popup.js'), 'utf8');
const start = source.indexOf('var __fushiM3eToneRoots = null;');
const end = source.indexOf('// BUG-1898:', start);
assert.ok(start >= 0 && end > start);

function fixture(initialTheme, initialM3e = true) {
  const frames = [];
  const observations = [];
  function mutate(target, attribute) {
    for (const o of observations) {
      if (o.target === target && o.options.attributeFilter.includes(attribute)) o.callback([]);
    }
  }
  function element() {
    const props = new Map();
    const attributes = new Map();
    const classes = new Set();
    const node = {
      tagName: 'DIV', isConnected: true, children: [],
      matches: () => false,
      querySelectorAll: () => node.children,
      computed: { backgroundColor: 'rgba(0, 0, 0, 0)', color: 'rgb(0, 0, 0)' },
      style: {
        setProperty: (key, value, priority = '') => { props.set(key, { value, priority }); mutate(node, 'style'); },
        removeProperty: (key) => { props.delete(key); mutate(node, 'style'); },
        getPropertyValue: (key) => props.get(key)?.value ?? '',
        getPropertyPriority: (key) => props.get(key)?.priority ?? '',
      },
      getAttribute: (key) => attributes.get(key),
      setAttribute: (key, value) => { attributes.set(key, value); mutate(node, key); },
      classList: {
        contains: (name) => classes.has(name),
        toggle: (name, enabled) => { enabled ? classes.add(name) : classes.delete(name); mutate(node, 'class'); },
      },
    };
    return node;
  }
  const html = element();
  const root = element();
  html.classList.toggle('fushi-m3e', initialM3e);
  html.setAttribute('data-theme', initialTheme);
  const scope = {
    window: {}, console,
    document: { documentElement: html, body: root },
    __fushiContainer: () => root,
    requestAnimationFrame: (callback) => (frames.push(callback), frames.length),
    MutationObserver: function (callback) {
      this.observe = (target, options) => observations.push({ target, options, callback });
    },
    getComputedStyle: (node) => ({
      backgroundColor: node.style.getPropertyValue('background-color') || node.computed.backgroundColor,
      color: node.style.getPropertyValue('color') || node.computed.color,
    }),
  };
  runInNewContext(source.slice(start, end), scope);
  function flush() {
    let count = 0;
    while (frames.length) {
      assert.ok(++count < 100, 'theme observers must not self-trigger forever');
      frames.shift()();
    }
  }
  function replaceCard() {
    root.children.forEach((node) => { node.isConnected = false; });
    const card = element();
    card.computed = { backgroundColor: 'rgb(255, 255, 255)', color: 'rgb(0, 0, 0)' };
    root.children = [card];
    scope.__fushiScheduleM3eDictTone(root);
    flush();
    return card;
  }
  return { scope, html, root, flush, replaceCard };
}

test('015 observer: dark -> light -> dark restores and reapplies on identical DOM', () => {
  const world = fixture('dark');
  const card = world.replaceCard();
  assert.match(card.style.getPropertyValue('background-color'), /^hsl/);
  world.html.setAttribute('data-theme', 'light');
  world.flush();
  assert.equal(card.style.getPropertyValue('background-color'), '');
  world.html.setAttribute('data-theme', 'dark');
  world.flush();
  assert.match(card.style.getPropertyValue('background-color'), /^hsl/);
  assert.equal(world.root.children[0], card);
});

test('015 observer: initially light DOM responds to first dark transition', () => {
  const world = fixture('light');
  const card = world.replaceCard();
  assert.equal(card.style.getPropertyValue('background-color'), '');
  world.html.setAttribute('data-theme', 'dark');
  world.flush();
  assert.match(card.style.getPropertyValue('background-color'), /^hsl/);
});

test('015 in-app explicit retone hook plus observer is idempotent', () => {
  const world = fixture('dark');
  const card = world.replaceCard();
  world.html.setAttribute('data-theme', 'light');
  world.scope.window.__fushiRetoneDictColors();
  world.flush();
  assert.equal(card.style.getPropertyValue('background-color'), '');
  assert.equal(card.style.getPropertyValue('color'), '');
});

test('015 design-system switch: leaving M3E restores original colors in dark mode', () => {
  const world = fixture('dark');
  const card = world.replaceCard();
  world.html.classList.toggle('fushi-m3e', false);
  world.flush();
  assert.equal(card.style.getPropertyValue('background-color'), '');
});

test('new lifecycle contract: repeated same-theme lookups must release detached toned nodes', () => {
  const world = fixture('dark');
  for (let i = 0; i < 100; i++) world.replaceCard();
  const retained = [...world.scope.__fushiM3eTonedNodes];
  assert.equal(retained.filter((node) => !node.isConnected).length, 0,
    '100 same-theme lookups retain 99 detached dictionary cards in a global strong Set');
});

test('new mirror contract: first light system-accent mirror must derive matching dark scheme', () => {
  const scope = { console, matchMedia: () => ({ matches: false, addEventListener() {} }) };
  scope.window = scope;
  const extensionSource = (name) => readFileSync(path.join(__dirname, name), 'utf8');
  runInNewContext(extensionSource('material-color.js'), scope);
  runInNewContext(extensionSource('theme-palette.js'), scope);
  const palette = scope.fushiThemePalette;
  const osSeed = '#e91e63';
  const light = palette.derive({ seed: osSeed }, 'light');
  // Desktop system-theme builds from OS accent (theme_notifier.dart:68), but
  // activeSeedColor returns _seedColor (:1476), whose system-theme branch falls
  // through preset lookup to kFushiDefaultSeed (:1464). app_model.dart:3841 sends it.
  const mirror = {
    current: 'light',
    light: {
      '--text-color': light['--fushi-text'],
      '--background-color': light['--fushi-bg'],
      '--md-primary': light['--fushi-primary'],
      // HBK-AUDIT-030 修复后 app 下发的是实际生成方案的强调色（ThemeNotifier.activeSeedColor）。
      '--fushi-theme-seed': osSeed,
      '--fushi-theme-variant': 'vibrant',
      '--fushi-theme-neutral': '0',
      '--fushi-pure-black': '0',
      '--fushi-theme-system': '1',
    },
  };
  const stored = { extensionPalette: 'app', extensionTheme: 'dark', appThemeMirror: mirror };
  scope.chrome = { storage: {
    local: { get: (_keys, cb) => { cb(stored); } },
    onChanged: { addListener() {} },
  } };
  runInNewContext(extensionSource('theme.js'), scope);
  assert.equal(scope.fushiTheme.tokens('light')['--fushi-primary'], light['--fushi-primary'],
    'control: available exact mirror stays correct');
  assert.equal(scope.fushiTheme.tokens('dark')['--fushi-primary'],
    palette.derive({ seed: osSeed, systemAccent: true }, 'dark')['--fushi-primary'],
    'missing dark mirror must use the actual OS accent instead of default teal metadata');
});

test('HBK-AUDIT-030：两种明暗都下发过时直接用镜像；本明暗那份早于 app 当前主题时按当前种子派生', () => {
  const scope = { console, matchMedia: () => ({ matches: false, addEventListener() {} }) };
  scope.window = scope;
  const src = (name) => readFileSync(path.join(__dirname, name), 'utf8');
  runInNewContext(src('material-color.js'), scope);
  runInNewContext(src('theme-palette.js'), scope);
  const P = scope.fushiThemePalette;
  const mirrorOf = (seed, scheme) => {
    const t = P.derive({ seed }, scheme);
    return {
      '--text-color': t['--fushi-text'], '--background-color': t['--fushi-bg'], '--md-primary': t['--fushi-primary'],
      '--fushi-theme-seed': seed, '--fushi-theme-variant': 'vibrant', '--fushi-theme-neutral': '0',
      '--fushi-pure-black': '0', '--fushi-theme-system': '0',
    };
  };
  const stored = { extensionPalette: 'app', appThemeMirror: {
    current: 'light', light: mirrorOf('#e91e63', 'light'), dark: mirrorOf('#e91e63', 'dark'),
  } };
  scope.chrome = { storage: { local: { get: (_k, cb) => cb(stored) }, onChanged: { addListener() {} } } };
  runInNewContext(src('theme.js'), scope);
  const T = scope.fushiTheme;
  assert.equal(T.tokens('dark')['--fushi-primary'], stored.appThemeMirror.dark['--md-primary'], '同源镜像原样采用');
  // app 换成蓝色主题、只查过浅色：深色那份是旧粉色镜像，必须按当前种子派生。
  T.setAppMirror({ current: 'light', light: mirrorOf('#0b57d0', 'light'), dark: mirrorOf('#e91e63', 'dark') });
  assert.equal(T.tokens('dark')['--fushi-primary'], P.derive({ seed: '#0b57d0' }, 'dark')['--fushi-primary']);
});
