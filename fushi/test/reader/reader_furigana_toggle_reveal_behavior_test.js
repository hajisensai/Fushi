// 振假名三态 `toggle`（对齐 Hoshi Reader iOS FuriganaMode.toggle）的行为测试：
// 点到「注音被 CSS 藏起来」的 <ruby> 时，fushiSelection.selectText 必须只揭示它
// （加 `furigana-revealed`）、清选区、**不查词**（不调 getCharacterAtPoint /
// selectFromPosition）、也不当作点空白（不 fire onTapEmpty）；而 hidden 态
// （rt display:none）、已揭示、注音本就可见、悬停查词（fromHover）四种情况都照常走
// 查词路径。
//
// 本测试从 reader_selection_scripts.dart 原样切出生产的 `_hiddenFuriganaRubyAt`
// 与 `selectText` 两个方法在 node vm 里执行，配一个最小假 DOM。
//
// Run: node fushi/test/reader/reader_furigana_toggle_reveal_behavior_test.js
// (also driven from reader_furigana_toggle_reveal_behavior_test.dart so it runs
//  inside `flutter test`).

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const scriptsPath = path.resolve(
  __dirname,
  '../../lib/src/reader/reader_selection_scripts.dart',
);
const source = fs.readFileSync(scriptsPath, 'utf8').replace(/\r\n/g, '\n');

function extractMethod(name) {
  const start = source.indexOf(`\n  ${name}: function(`);
  assert.ok(start >= 0, `missing ${name} in reader_selection_scripts.dart`);
  const end = source.indexOf('\n  },\n', start);
  assert.ok(end > start, `unterminated ${name}`);
  // "  name: function(...) { ... }" (without the trailing comma).
  return source.slice(start + 1, end + 4);
}

const hiddenRubyAt = extractMethod('_hiddenFuriganaRubyAt');
const selectText = extractMethod('selectText');

function makeClassList(initial) {
  const set = new Set(initial || []);
  return {
    add(n) { set.add(n); },
    contains(n) { return set.has(n); },
    has(n) { return set.has(n); },
  };
}

// scenario: { rtDisplay, rtVisibility, revealed, hasRt, hitTextNode }
function makeHarness(sc) {
  const rt = sc.hasRt === false ? null : { tag: 'rt' };
  const ruby = {
    classList: makeClassList(sc.revealed ? ['furigana-revealed'] : []),
    querySelector(sel) { return sel === 'rt' ? rt : null; },
  };
  const rb = {
    closest(sel) {
      if (sel === 'a') return null;
      if (sel === 'ruby') return ruby;
      return null;
    },
  };
  const calls = { getCharacterAtPoint: 0, selectFromPosition: 0, clearSelection: 0, onTapEmpty: 0 };
  const documentObj = {
    elementFromPoint() { return rb; },
  };
  const windowObj = {
    flutter_inappwebview: { callHandler(name) { if (name === 'onTapEmpty') calls.onTapEmpty++; } },
  };
  const sandbox = {
    document: documentObj,
    window: windowObj,
    getComputedStyle(el) {
      assert.strictEqual(el, rt, 'must read the computed style of the ruby\'s <rt>');
      return { display: sc.rtDisplay || 'ruby-text', visibility: sc.rtVisibility || 'visible' };
    },
  };
  vm.createContext(sandbox);
  const prepared =
    '(function(){ var o = {\n' +
    hiddenRubyAt + ',\n' +
    selectText + ',\n' +
    '  selection: null,\n' +
    '  getCharacterAtPoint: function() { calls.getCharacterAtPoint++; return { node: {}, offset: 0 }; },\n' +
    '  clearSelection: function() { calls.clearSelection++; },\n' +
    '  selectFromPosition: function() { calls.selectFromPosition++; return "looked-up"; }\n' +
    '}; return o; })()';
  sandbox.calls = calls;
  const obj = vm.runInContext(prepared, sandbox, { filename: 'furigana-toggle-reveal.js' });
  return { obj, ruby, calls };
}

// 1. toggle 态未揭示（rt visibility:hidden）：点击 = 揭示，不查词、不算点空白。
(function () {
  const h = makeHarness({ rtVisibility: 'hidden' });
  const r = h.obj.selectText(10, 20, 50, false);
  assert.strictEqual(r, null, 'reveal tap returns null (no selection payload)');
  assert.strictEqual(h.ruby.classList.contains('furigana-revealed'), true, 'ruby must be revealed');
  assert.strictEqual(h.calls.getCharacterAtPoint, 0, 'reveal tap must NOT look up a word');
  assert.strictEqual(h.calls.selectFromPosition, 0, 'reveal tap must NOT build a selection');
  assert.strictEqual(h.calls.onTapEmpty, 0, 'reveal tap is not an empty tap');
  assert.strictEqual(h.calls.clearSelection, 1, 'reveal tap clears any prior selection');
})();

// 2. 已揭示的 ruby：照常查词。
(function () {
  const h = makeHarness({ rtVisibility: 'hidden', revealed: true });
  const r = h.obj.selectText(10, 20, 50, false);
  assert.strictEqual(r, 'looked-up', 'revealed ruby taps look up normally');
  assert.strictEqual(h.calls.getCharacterAtPoint, 1);
})();

// 3. hidden 态（rt display:none）：不是「可揭示」，照常查词。
(function () {
  const h = makeHarness({ rtDisplay: 'none', rtVisibility: 'hidden' });
  const r = h.obj.selectText(10, 20, 50, false);
  assert.strictEqual(r, 'looked-up', 'display:none furigana (hidden mode) is not revealable');
  assert.strictEqual(h.ruby.classList.contains('furigana-revealed'), false);
})();

// 4. off 态 / 快捷键整页揭示后（rt 可见）：照常查词。
(function () {
  const h = makeHarness({ rtVisibility: 'visible' });
  const r = h.obj.selectText(10, 20, 50, false);
  assert.strictEqual(r, 'looked-up', 'visible furigana taps look up normally');
  assert.strictEqual(h.ruby.classList.contains('furigana-revealed'), false);
})();

// 5. 悬停查词（fromHover）不揭示：鼠标滑过不能把注音一路翻开。
(function () {
  const h = makeHarness({ rtVisibility: 'hidden' });
  const r = h.obj.selectText(10, 20, 50, true);
  assert.strictEqual(r, 'looked-up', 'hover lookup ignores hidden furigana');
  assert.strictEqual(h.ruby.classList.contains('furigana-revealed'), false, 'hover must not reveal');
})();

// 6. ruby 里没有 rt（只有 rp 之类）：没什么可揭示，照常查词。
(function () {
  const h = makeHarness({ hasRt: false, rtVisibility: 'hidden' });
  const r = h.obj.selectText(10, 20, 50, false);
  assert.strictEqual(r, 'looked-up', 'ruby without <rt> is not revealable');
})();

console.log('reader_furigana_toggle_reveal_behavior_test.js: all assertions passed');
