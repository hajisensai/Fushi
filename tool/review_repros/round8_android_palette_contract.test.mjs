// Consumer protocol tests. Fixtures represent already-received CSS roles, not
// mocked MCU output; actual CorePalette -> AppModel maps are tested by Dart.
import assert from 'node:assert/strict';
import test from 'node:test';
import {
  assertExactMirror,
  assertPaletteIdentityContract,
  assertUnknownOppositeScheme,
  createConsumer,
} from './round8_android_palette_contract.mjs';

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

test('Android system mirror without seed is explicitly non-derivable', () => {
  const scope = createConsumer({ current: 'light', light: first.light });
  assert.equal(scope.fushiThemePalette.specFromAppTheme(first.light), null);
});

test('missing opposite Android scheme returns CSS fallback, not a primary-seeded guess', () => {
  assertUnknownOppositeScheme(first);
});

test('same-identity complete mirrors retain exact colors', () => {
  const scope = createConsumer({ current: 'light', ...first });
  assertExactMirror(scope, first.light, 'light');
  assertExactMirror(scope, first.dark, 'dark');
});

test('palette identity rejects stale opposite mirror after wallpaper change', () => {
  assertPaletteIdentityContract(first, second);
});

test('desktop OS accent mirror with explicit seed remains derivable', () => {
  const light = {
    ...first.light,
    '--fushi-theme-seed': '#e91e63',
  };
  delete light['--fushi-theme-palette-id'];
  const scope = createConsumer({ current: 'light', light });
  const expected = scope.fushiThemePalette.derive({ seed: '#e91e63', systemAccent: true }, 'dark');
  assert.equal(scope.fushiTheme.tokens('dark')['--fushi-primary'], expected['--fushi-primary']);
});

test('legacy non-system mirror keeps its explicitly approximate compatibility path', () => {
  const legacy = { ...first.light, '--fushi-theme-system': '0' };
  delete legacy['--fushi-theme-palette-id'];
  const scope = createConsumer({ current: 'light', light: legacy });
  const spec = scope.fushiThemePalette.specFromAppTheme(legacy);
  assert.ok(spec);
  assert.equal(spec.approximate, true);
});
