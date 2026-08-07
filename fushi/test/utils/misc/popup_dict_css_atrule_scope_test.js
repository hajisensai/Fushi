const assert = require('assert');
const fs = require('fs');
const path = require('path');
const vm = require('vm');

// TODO-812: 明鏡国語辞典 第三版 ships a styles.css that contains an `@media`
// at-rule. The legacy `constructDictCss` (a hand-written CSS scoper) treated the
// whole text before the first `{` as a selector list, so `@media (max-width:
// 500px)` got the `[data-dictionary="X"]` prefix glued in front, producing the
// ILLEGAL `[data-dictionary="X"] @media (...) { ... }` — the browser drops the
// entire @media block. This harness executes the real `constructDictCss` and
// asserts at-rules are scoped correctly while ordinary selectors keep their
// prefix. Mirrors the Hoshi-Reader-Android rendering baseline.

const dictMediaPath = path.resolve(__dirname, '../../../assets/popup/dict-media.js');

function load() {
  const context = { console };
  context.globalThis = context;
  vm.runInNewContext(fs.readFileSync(dictMediaPath, 'utf8'), context, {
    filename: dictMediaPath,
  });
  return context;
}

const DICT = '明鏡国語辞典 第三版';
const PREFIX = `.yomitan-glossary [data-dictionary="${DICT}"]`;

function scope(css) {
  return load().constructDictCss(css, DICT, PREFIX);
}

// Real fragment lifted verbatim from the meikyo styles.css.
const MEIKYO_MEDIA = `
table[data-sc-class="img"] .gloss-image-link {
    max-width: 70% !important;
}
@media (max-width: 500px) {
	table[data-sc-class="img"] .gloss-image-link {
		max-width: 65% !important;
	}
}
div[data-sc-head2] {
	margin-block-start: 0.25em;
}`;

function testMediaPreludeNotPrefixed() {
  const out = scope(MEIKYO_MEDIA);
  // The @media prelude must stay raw, never glued behind the scope prefix.
  assert.ok(
    !/\[data-dictionary="[^"]*"\]\s*@media/.test(out),
    '@media prelude was illegally prefixed:\n' + out,
  );
  assert.ok(
    /@media\s*\(max-width:\s*500px\)\s*\{/.test(out),
    '@media prelude missing or mangled:\n' + out,
  );
}

function testMediaInnerRuleStillScoped() {
  const out = scope(MEIKYO_MEDIA);
  // Inside @media, the nested style rule MUST still receive the scope prefix.
  const mediaStart = out.indexOf('@media');
  const inner = out.slice(mediaStart);
  assert.ok(
    inner.includes(`${PREFIX} table[data-sc-class="img"] .gloss-image-link`),
    'inner @media rule lost its scope prefix:\n' + out,
  );
}

function testOrdinaryRulesUnaffected() {
  const out = scope(MEIKYO_MEDIA);
  assert.ok(
    out.includes(`${PREFIX} div[data-sc-head2]`),
    'ordinary selector lost its prefix (regression):\n' + out,
  );
  assert.ok(
    out.includes(`${PREFIX} table[data-sc-class="img"] .gloss-image-link`),
    'ordinary selector before @media lost its prefix (regression):\n' + out,
  );
}

function testKeyframesBodyNeverPrefixed() {
  const out = scope('@keyframes spin { 0% { opacity: 0; } 100% { opacity: 1; } }');
  assert.ok(/@keyframes spin\s*\{/.test(out), '@keyframes prelude mangled:\n' + out);
  assert.ok(
    !/\[data-dictionary="[^"]*"\]\s*0%/.test(out),
    '@keyframes selector (0%) was illegally prefixed:\n' + out,
  );
  assert.ok(out.includes('0% { opacity: 0; }'), '@keyframes body altered:\n' + out);
}

function testFontFaceBodyNeverPrefixed() {
  const out = scope('@font-face { font-family: X; src: url(a.woff); }');
  assert.ok(
    !/\[data-dictionary="[^"]*"\]\s*@font-face/.test(out),
    '@font-face prelude was illegally prefixed:\n' + out,
  );
  assert.ok(out.includes('font-family: X;'), '@font-face body altered:\n' + out);
}

function testStatementAtRulePassthrough() {
  const out = scope('@import "x.css"; span[data-sc-b] { color: red; }');
  assert.ok(out.includes('@import "x.css";'), '@import statement not preserved:\n' + out);
  assert.ok(
    !/\[data-dictionary="[^"]*"\]\s*@import/.test(out),
    '@import was illegally prefixed:\n' + out,
  );
  assert.ok(
    out.includes(`${PREFIX} span[data-sc-b]`),
    'rule after @import statement lost its prefix:\n' + out,
  );
}

function testCjkDataKeyExpansionMatchesBaseline() {
  // Guard the data-key → attribute expansion contract shared with the
  // Hoshi-Reader-Android baseline: CJK-leading keys drop the hyphen
  // (`data-sc` + key) while ASCII keys keep it (`data-sc-<kebab>`). This is the
  // intentional daijisen/meikyo behavior; both apps agree. Replicated from
  // popup.js so the guard is self-contained.
  function toKebabCase(str) {
    return str.replace(/([A-Z])/g, (_, c, i) => (i ? '-' : '') + c.toLowerCase());
  }
  function attrName(k) {
    const isCJK = /^[　-鿿豈-﫿]/.test(k);
    return `data-sc${isCJK ? '' : '-'}${toKebabCase(k)}`;
  }
  assert.strictEqual(attrName('headword'), 'data-sc-headword');
  assert.strictEqual(attrName('class'), 'data-sc-class');
  assert.strictEqual(attrName('カナ'), 'data-scカナ');
  assert.strictEqual(attrName('表記'), 'data-sc表記');
}

testMediaPreludeNotPrefixed();
testMediaInnerRuleStillScoped();
testOrdinaryRulesUnaffected();
testKeyframesBodyNeverPrefixed();
testFontFaceBodyNeverPrefixed();
testStatementAtRulePassthrough();
testCjkDataKeyExpansionMatchesBaseline();

console.log('all assertions passed');
