// Real extension consumer harness. Deliberately does not reimplement palette
// derivation: these checks define what to do when exact data is unavailable.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
import { runInNewContext } from 'node:vm';

const source = (name) => readFileSync(
  new URL(`../../tools/browser-extension/${name}`, import.meta.url), 'utf8');
const scripts = ['material-color.js', 'theme-palette.js', 'theme.js']
  .map((name) => ({ name, content: source(name) }));

export function createConsumer(mirror, scheme = 'dark') {
  const scope = {
    console,
    matchMedia: () => ({ matches: false, addEventListener() {} }),
  };
  scope.window = scope;
  const stored = {
    extensionPalette: 'app', extensionTheme: scheme, appThemeMirror: mirror,
  };
  scope.chrome = { storage: {
    local: { get: (_keys, callback) => callback(stored) },
    onChanged: { addListener() {} },
  } };
  for (const { name, content } of scripts) {
    runInNewContext(content, scope, { filename: name });
  }
  return scope;
}

export function assertExactMirror(scope, mirror, scheme) {
  const expected = scope.fushiThemePalette.tokensFromAppTheme(mirror, scheme);
  const actual = scope.fushiTheme.tokens(scheme);
  assert.ok(actual, 'an available exact mirror must remain usable');
  for (const key of ['--fushi-primary', '--fushi-bg', '--fushi-text']) {
    assert.equal(actual[key], expected[key], `${scheme} exact mirror: ${key}`);
  }
}

export function assertUnknownOppositeScheme(pair) {
  for (const [present, missing] of [['light', 'dark'], ['dark', 'light']]) {
    const scope = createConsumer({ current: present, [present]: pair[present] }, missing);
    assertExactMirror(scope, pair[present], present);
    assert.equal(scope.fushiTheme.tokens(missing), null,
      `${present} -> ${missing}: a full Android palette cannot be invented from its primary; ` +
      'null delegates to the existing CSS fallback');
  }
}

export function assertPaletteIdentityContract(first, second) {
  const id = '--fushi-theme-palette-id';
  assert.ok(first.light[id], 'producer must identify its complete Android palette');
  assert.equal(first.light[id], first.dark[id], 'both schemes must identify the same palette');
  assert.equal(second.light[id], second.dark[id], 'both new schemes must share their palette id');
  assert.notEqual(first.light[id], second.light[id], 'different palettes must have different identity');

  const scope = createConsumer({ current: 'light', light: first.light, dark: first.dark });
  assertExactMirror(scope, first.light, 'light');
  assertExactMirror(scope, first.dark, 'dark');

  scope.fushiTheme.setAppMirror({ current: 'light', light: second.light, dark: first.dark });
  assertExactMirror(scope, second.light, 'light');
  assert.equal(scope.fushiTheme.tokens('dark'), null,
    'after wallpaper changes, a previous palette dark mirror must not be reused or guessed');

  scope.fushiTheme.setAppMirror({ current: 'dark', light: second.light, dark: second.dark });
  assertExactMirror(scope, second.light, 'light');
  assertExactMirror(scope, second.dark, 'dark');
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const payload = JSON.parse(process.argv[2]);
  if (payload.mode === 'unknown') {
    assertUnknownOppositeScheme(payload.first);
  } else if (payload.mode === 'identity') {
    assertPaletteIdentityContract(payload.first, payload.second);
  } else {
    throw new Error('expected mode unknown or identity');
  }
  console.log(`Android palette ${payload.mode} contract verified`);
}
