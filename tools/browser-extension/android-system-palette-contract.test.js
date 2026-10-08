// HBK-AUDIT-030: an Android OS palette is not reconstructible from primary.
// Exercise actual theme consumers and background persistence, including old
// producer payloads. Dart tests cover CorePalette -> AppModel production data.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const source = (name) => fs.readFileSync(path.join(__dirname, name), 'utf8');

function consumer(mirror, scheme = 'dark') {
  const scope = { console, matchMedia: () => ({ matches: false, addEventListener() {} }) };
  scope.window = scope;
  const stored = { extensionPalette: 'app', extensionTheme: scheme, appThemeMirror: mirror };
  scope.chrome = { storage: {
    local: { get: (_keys, callback) => callback(stored) },
    onChanged: { addListener() {} },
  } };
  for (const name of ['material-color.js', 'theme-palette.js', 'theme.js']) {
    vm.runInNewContext(source(name), scope, { filename: name });
  }
  return scope;
}

function mirror(primary, scheme, paletteId) {
  return {
    '--md-primary': primary,
    '--text-color': scheme === 'dark' ? '#f8f8f8' : '#161616',
    '--background-color': scheme === 'dark' ? '#121212' : '#fafafa',
    '--fushi-color-scheme': scheme,
    '--fushi-theme-variant': 'vibrant',
    '--fushi-theme-system': '1',
    '--fushi-theme-neutral': '0',
    '--fushi-pure-black': '0',
    ...(paletteId ? { '--fushi-theme-palette-id': paletteId } : {}),
  };
}

const first = {
  light: mirror('#973772', 'light', 'android:palette-a'),
  dark: mirror('#fface0', 'dark', 'android:palette-a'),
};
const second = {
  light: mirror('#006c52', 'light', 'android:palette-b'),
  dark: mirror('#52dcb0', 'dark', 'android:palette-b'),
};

function exact(scope, value, scheme) {
  const expected = scope.fushiThemePalette.tokensFromAppTheme(value, scheme);
  const actual = scope.fushiTheme.tokens(scheme);
  assert.ok(actual, 'an available exact mirror remains usable');
  for (const key of ['--fushi-primary', '--fushi-bg', '--fushi-text']) {
    assert.equal(actual[key], expected[key]);
  }
}

test('system mirror without seed does not fabricate a derivation spec', () => {
  const scope = consumer({ current: 'light', light: first.light });
  assert.equal(scope.fushiThemePalette.specFromAppTheme(first.light), null);
});

for (const [present, missing] of [['light', 'dark'], ['dark', 'light']]) {
  test(`missing Android ${missing} scheme uses fallback and preserves exact ${present}`, () => {
    const scope = consumer({ current: present, [present]: first[present] });
    exact(scope, first[present], present);
    assert.equal(scope.fushiTheme.tokens(missing), null);
  });
}

test('complete mirrors sharing palette identity are reused exactly', () => {
  const scope = consumer({ current: 'light', ...first });
  exact(scope, first.light, 'light');
  exact(scope, first.dark, 'dark');
});

test('wallpaper change rejects old opposite scheme until its exact replacement arrives', () => {
  const scope = consumer({ current: 'light', light: second.light, dark: first.dark });
  exact(scope, second.light, 'light');
  assert.equal(scope.fushiTheme.tokens('dark'), null);
  scope.fushiTheme.setAppMirror({ current: 'dark', ...second });
  exact(scope, second.light, 'light');
  exact(scope, second.dark, 'dark');
});

test('old opposite mirror without identity is invalid against a new palette identity', () => {
  const oldDark = { ...first.dark };
  delete oldDark['--fushi-theme-palette-id'];
  const scope = consumer({ current: 'light', light: second.light, dark: oldDark });
  exact(scope, second.light, 'light');
  assert.equal(scope.fushiTheme.tokens('dark'), null);
});

test('legacy Android producer keeps current exact colors without trusting old opposite data', () => {
  const light = { ...second.light };
  const dark = { ...first.dark };
  delete light['--fushi-theme-palette-id'];
  delete dark['--fushi-theme-palette-id'];
  const scope = consumer({ current: 'light', light, dark });
  exact(scope, light, 'light');
  assert.equal(scope.fushiTheme.tokens('dark'), null);
});

test('identity mismatch is honored even when legacy variant metadata is missing', () => {
  const light = { ...second.light };
  delete light['--fushi-theme-variant'];
  const scope = consumer({ current: 'light', light, dark: first.dark });
  exact(scope, light, 'light');
  assert.equal(scope.fushiTheme.tokens('dark'), null);
});

test('desktop accent with explicit seed still derives its missing scheme', () => {
  const light = { ...first.light, '--fushi-theme-seed': '#e91e63' };
  delete light['--fushi-theme-palette-id'];
  const scope = consumer({ current: 'light', light });
  const expected = scope.fushiThemePalette.derive({ seed: '#e91e63', systemAccent: true }, 'dark');
  assert.equal(scope.fushiTheme.tokens('dark')['--fushi-primary'], expected['--fushi-primary']);
});

test('non-system legacy mirror retains its approximate primary fallback', () => {
  const light = { ...first.light, '--fushi-theme-system': '0' };
  delete light['--fushi-theme-palette-id'];
  const scope = consumer({ current: 'light', light });
  const spec = scope.fushiThemePalette.specFromAppTheme(light);
  assert.ok(spec);
  assert.equal(spec.approximate, true);
});

test('background preserves opaque palette identity and does not rewrite identical mirrors', async () => {
  const background = source('background.js');
  const start = background.indexOf('const APP_THEME_MIRROR_KEYS = [');
  const end = background.indexOf('let studyBackoffUntil', start);
  assert.ok(start >= 0 && end > start);
  const writes = [];
  const scope = { chrome: { storage: { local: {
    get: async () => ({}),
    set: (value) => { writes.push(structuredClone(value)); return Promise.resolve(); },
  } } } };
  vm.runInNewContext(background.slice(start, end) +
    '\nglobalThis.remember = rememberAppTheme;', scope);
  scope.remember(first.light);
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(writes.length, 1);
  assert.equal(writes[0].appThemeMirror.light['--fushi-theme-palette-id'], 'android:palette-a');
  scope.remember(first.light);
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(writes.length, 1);
  scope.remember(second.light);
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(writes.length, 2);
  assert.equal(writes[1].appThemeMirror.light['--fushi-theme-palette-id'], 'android:palette-b');
});
