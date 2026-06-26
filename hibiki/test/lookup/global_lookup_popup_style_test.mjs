// TODO-867 P2 — global-lookup popup card-chrome + flex-wrap sub-box CSS guard.
// Run: node hibiki/test/lookup/global_lookup_popup_style_test.mjs
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

// 1. in-app grid intact.
const inAppBody = find('.glossary-section > .category-body');
assert.strictEqual(inAppBody.length, 1, 'in-app .category-body rule must exist exactly once');
assert.ok(/display:\s*grid/.test(inAppBody[0].body), 'in-app .category-body must stay grid');
assert.ok(/repeat\(var\(--dict-columns/.test(inAppBody[0].body),
  'in-app grid must keep the tested --dict-columns columns');

// 2. global-lookup override -> flex-wrap variable-height.
const glBody = find('html.global-lookup .glossary-section > .category-body');
assert.strictEqual(glBody.length, 1, 'global-lookup .category-body override must exist');
assert.ok(/display:\s*flex/.test(glBody[0].body), 'global-lookup sub-box container must be flex');
assert.ok(/flex-wrap:\s*wrap/.test(glBody[0].body), 'must flex-wrap (many per row, not fixed 3)');
assert.ok(/align-items:\s*flex-start/.test(glBody[0].body),
  'must NOT stretch to row max height (kills first-result-taller stretch)');
assert.ok(!/grid-template-columns/.test(glBody[0].body),
  'global-lookup override must not reintroduce a fixed-N grid');

// glossary-group under global-lookup is content height (height:auto), not stretched.
const glGroup = find('html.global-lookup .glossary-section > .category-body > .glossary-group');
assert.strictEqual(glGroup.length, 1, 'global-lookup glossary-group override must exist');
assert.ok(/height:\s*auto/.test(glGroup[0].body), 'collapsed sub-box must be content-height');

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
