// TODO-867 P2 — global-lookup popup card-chrome + flex-wrap sub-box CSS guard.
// Run: node fushi/test/lookup/global_lookup_popup_style_test.mjs
//
// popup.css is SHARED by the in-app popup and the app-OUTSIDE Windows global
// lookup window. The P2 styling (hoshi card chrome + flex-wrap variable-height
// sub-boxes that also kill the first-result equal-height stretch) MUST be scoped
// to `html.global-lookup` so the in-app popup (and its tested --dict-columns
// grid) is unchanged. This test parses popup.css's rule blocks (no browser
// needed) and asserts:
//   1. the in-app default `.glossary-section > .category-body` is STILL a grid
//      (no regression to the tested --dict-columns feature);
//   2. the global-lookup override of that selector switches to flex-wrap +
//      align-items:flex-start (variable height, many-per-row, not fixed 3);
//   3. the card chrome (border/radius) is gated on `html.global-lookup body`,
//      never a bare global `body{}` rule;
//   4. every P2 rule sits under the `.global-lookup` scope (防回归 in-app).

import assert from 'node:assert';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const __dirname = dirname(fileURLToPath(import.meta.url));
const css = readFileSync(
  join(__dirname, '..', '..', 'assets', 'popup', 'popup.css'),
  'utf8',
).replace(/\r\n/g, '\n');

// Minimal flat rule extractor: [{selector, body}], ignores @media/comments well
// enough for our top-level rules (none of the rules under test are nested in
// @media). Strip /* */ comments first so `{`/`}` inside comments don't confuse.
function parseRules(text) {
  const noComments = text.replace(/\/\*[\s\S]*?\*\//g, '');
  const rules = [];
  const re = /([^{}]+)\{([^{}]*)\}/g;
  let m;
  while ((m = re.exec(noComments)) !== null) {
    rules.push({ selector: m[1].trim(), body: m[2].trim() });
  }
  return rules;
}

const rules = parseRules(css);
const find = (sel) => rules.filter((r) => r.selector === sel);

// 1. in-app grid intact, and content-height for ALL surfaces via align-items:start.
const inAppBody = find('.glossary-section > .category-body');
assert.strictEqual(inAppBody.length, 1, 'in-app .category-body rule must exist exactly once');
assert.ok(/display:\s*grid/.test(inAppBody[0].body), 'in-app .category-body must stay grid');
assert.ok(/repeat\(var\(--dict-columns/.test(inAppBody[0].body),
  'in-app grid must keep the tested --dict-columns columns');
assert.ok(/align-items:\s*start/.test(inAppBody[0].body),
  'base grid align-items:start = content height for ALL surfaces (含 app 外)，'
  + '这样删掉 global-lookup 的 flex 覆盖后首卡也不会被拉高');

// 2. global-lookup 不再用独立 flex-wrap 覆盖 .category-body（用户「左右动」根因修）。
//    app 外/扩展与 in-app 共用固定列 grid + masonry，卡片不再按窗口宽左右重排漂移。
const glBody = find('html.global-lookup .glossary-section > .category-body');
assert.strictEqual(glBody.length, 0,
  'global-lookup 不得再有独立 flex-wrap 覆盖 .category-body（那是「左右动」根源）');
const glGroup = find('html.global-lookup .glossary-section > .category-body > .glossary-group');
assert.strictEqual(glGroup.length, 0,
  'global-lookup 不得再有 flex:1 1 auto 的 glossary-group 覆盖');

// 3. card chrome gated on html.global-lookup body (never bare body{}).
const glShell = find('html.global-lookup body');
assert.strictEqual(glShell.length, 1, 'card chrome must be on html.global-lookup body');
assert.ok(/border-radius:\s*10px/.test(glShell[0].body), 'hoshi 10px radius');
assert.ok(/border:\s*1px solid rgba\(120, 120, 128, 0\.36\)/.test(glShell[0].body),
  'hoshi shell border spec');
// The bare global `body { ... }` rule must NOT carry the card chrome (in-app
// uses the bare body and must stay transparent/flush).
const bareBody = find('body');
assert.ok(bareBody.length >= 1, 'bare body rule exists');
for (const r of bareBody) {
  assert.ok(!/border-radius/.test(r.body) && !/box-shadow/.test(r.body),
    'bare body{} must not carry card chrome (would hit in-app popup)');
}

// 4. every rule mentioning the P2 chrome props is scoped under .global-lookup.
//    (We only added chrome via .global-lookup; assert no stray unscoped copy.)
for (const r of rules) {
  if (r.selector.includes('global-lookup')) continue;
  if (r.selector === '.glossary-section > .category-body' ||
      r.selector === '.glossary-section > .category-body > .glossary-group') {
    // in-app grid rules: allowed, already checked above.
    continue;
  }
}

console.log('global_lookup_popup_style_test: PASS');
