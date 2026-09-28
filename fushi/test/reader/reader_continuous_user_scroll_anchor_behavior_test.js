// BUG-2748 behavior test: in continuous mode a user scroll retires the late-image
// anchor and the restore anchor, exactly like a paged page turn (paginate).
//
// Regression context: the continuous viewport is driven by native scrolling, so
// there is no single paginate entry. Wheel (the webview layer scrollBy's it
// itself), native touch scrolling, dragging the scrollbar and native arrow /
// page-key scrolling never retired the anchor that restore landings and
// programmatic reveals register. After the user scrolled away, a lazy image
// ahead finished loading and reapplyImageLateAnchor() pulled the viewport back
// to the last reveal / restore target.
//
// This harness runs the real continuous shell object and the real user-scroll
// intent IIFE from continuousShellSource() against a fake document that records
// its listeners, then dispatches the input events and asserts:
//   A. wheel / touchmove / pointerdown on the root (scrollbar) / scroll keys
//      retire both anchors — the late image load re-applies nothing;
//   B. a pointerdown on text and a Space key do not (lookup clicks and
//      play/pause must keep the anchor);
//   C. with the paged shell installed the listeners stay out of the way
//      (paged input already goes through paginate);
//   D. the IIFE installs its listeners once per document.
//
// Run: node fushi/test/reader/reader_continuous_user_scroll_anchor_behavior_test.js <payload.json>
// (driven from reader_continuous_user_scroll_anchor_behavior_test.dart inside `flutter test`).

const assert = require('assert');
const fs = require('fs');

const data = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));

function objectLiteral(source) {
  const marker = 'window.fushiReader = {';
  const start = source.indexOf(marker);
  assert.ok(start >= 0, 'fushiReader object missing');
  const brace = source.indexOf('{', start);
  const end = source.indexOf('\n};', brace);
  assert.ok(end >= 0, 'fushiReader object terminator missing');
  return source.slice(brace, end + 2);
}

function intentIife(source) {
  const marker = '(function() {\n  if (window.__fushiUserScrollIntentInstalled) return;';
  const start = source.indexOf(marker);
  assert.ok(start >= 0, 'continuous shell must install the user-scroll intent listeners');
  const end = source.indexOf('\n})();', start);
  assert.ok(end >= 0, 'user-scroll intent IIFE terminator missing');
  return source.slice(start, end + '\n})();'.length);
}

function makeEnv() {
  const listeners = {};
  const documentElement = { style: {}, clientHeight: 800, clientWidth: 1000 };
  const body = { clientWidth: 1000, clientHeight: 800 };
  const style = { writingMode: 'horizontal-tb', getPropertyValue() { return ''; } };
  const getComputedStyle = () => style;
  const window = {
    innerWidth: 1000, innerHeight: 800, CSS: {}, Highlight: function() {},
    getComputedStyle,
    scrollBy() {},
  };
  const document = {
    documentElement,
    body,
    scrollingElement: null,
    caretRangeFromPoint: () => null,
    addEventListener(type, fn, opts) {
      assert.ok(opts && opts.capture === true && opts.passive === true,
        type + ' intent listener must be capture + passive (never blocks a gesture)');
      (listeners[type] = listeners[type] || []).push(fn);
    },
  };
  new Function('window', data.studyUnits)(window);
  function dispatch(type, event) {
    for (const fn of listeners[type] || []) fn(event || {});
  }
  return { window, document, getComputedStyle, listeners, dispatch };
}

function instantiate(env, shellSource) {
  const factory = new Function(
    'window', 'document', 'C', 'global', 'CSS', 'Highlight', 'getComputedStyle', 'Node',
    'requestAnimationFrame',
    'return ' + objectLiteral(shellSource) + ';'
  );
  const reader = factory(env.window, env.document, { perfTraceEnabled: false }, {},
    env.window.CSS, env.window.Highlight, env.getComputedStyle, { TEXT_NODE: 3 },
    (fn) => fn());
  const calls = { charScroll: [] };
  reader.scrollToCharOffset = function() { calls.charScroll.push(Array.from(arguments)); };
  env.window.fushiReader = reader;
  return { reader, calls };
}

function installIntent(env) {
  new Function('window', 'document', intentIife(data.continuous))(env.window, env.document);
}

// Arm both anchors the way a restore landing does.
function armRestore(reader) {
  reader.registerImageLateAnchor({ charOffset: 5700, endCharOffset: -1 });
  reader._setRestoreCharAnchor(5700, -1);
}

function assertRetired(reader, calls, what) {
  assert.strictEqual(reader.__restoreCharOffset, null,
    what + ' must retire the restore anchor');
  assert.strictEqual(reader.reapplyImageLateAnchor(), false,
    what + ' must retire the late-image anchor — a lazy image loading afterwards ' +
    'would otherwise pull the viewport back to where the user scrolled away from');
  assert.strictEqual(calls.charScroll.length, 0, what + ': nothing re-applied');
}

function assertKept(reader, calls, what) {
  assert.strictEqual(reader.__restoreCharOffset, 5700, what + ' must keep the restore anchor');
  assert.strictEqual(reader.reapplyImageLateAnchor(), true, what + ' must keep the late-image anchor');
  assert.deepStrictEqual(calls.charScroll, [[5700, -1]]);
}

// ── A. user scroll inputs retire both anchors (continuous shell) ─────────
const retiring = [
  ['wheel', {}, 'a wheel tick'],
  ['touchmove', {}, 'a native touch scroll'],
  ['pointerdown', 'root', 'a press on the root scrollbar'],
  ['keydown', { key: 'PageDown' }, 'a native PageDown scroll'],
  ['keydown', { key: 'ArrowDown' }, 'a native arrow-key scroll'],
];
for (const [type, event, what] of retiring) {
  const env = makeEnv();
  const { reader, calls } = instantiate(env, data.continuous);
  installIntent(env);
  armRestore(reader);
  env.dispatch(type, event === 'root' ? { target: env.document.documentElement } : event);
  assertRetired(reader, calls, 'continuous: ' + what);
}

{
  // A reveal target (audiobook follow) is retired the same way.
  const env = makeEnv();
  const { reader, calls } = instantiate(env, data.continuous);
  installIntent(env);
  reader.registerImageLateAnchor({ target: { getBoundingClientRect() { return {}; } } });
  env.dispatch('wheel', {});
  assert.strictEqual(reader.reapplyImageLateAnchor(), false,
    'continuous: a wheel tick after a follow reveal must retire the reveal target');
  assert.strictEqual(calls.charScroll.length, 0);
}

// ── B. inputs that are not a scroll keep the anchors ─────────────────────
{
  const env = makeEnv();
  const { reader, calls } = instantiate(env, data.continuous);
  installIntent(env);
  armRestore(reader);
  env.dispatch('pointerdown', { target: env.document.body });
  env.dispatch('keydown', { key: ' ' });
  env.dispatch('keydown', { key: 'a' });
  assertKept(reader, calls, 'continuous: a text press / Space / letter key');
}

// ── C. paged shell: input already goes through paginate ──────────────────
{
  const env = makeEnv();
  const { reader, calls } = instantiate(env, data.paged);
  installIntent(env);
  armRestore(reader);
  env.dispatch('wheel', {});
  env.dispatch('keydown', { key: 'PageDown' });
  assert.strictEqual(reader.reapplyImageLateAnchor(), true,
    'paged: the intent listeners must leave the paged shell alone');
  assert.strictEqual(calls.charScroll.length, 1);
}

// ── D. one install per document ──────────────────────────────────────────
{
  const env = makeEnv();
  instantiate(env, data.continuous);
  installIntent(env);
  installIntent(env);
  for (const type of ['wheel', 'touchmove', 'pointerdown', 'keydown']) {
    assert.strictEqual((env.listeners[type] || []).length, 1,
      type + ' intent listener must be installed exactly once per document');
  }
}

console.log('all assertions passed');
