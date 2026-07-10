#!/usr/bin/env node
//
//  generate-content-css.mjs
//
//  Single source of truth for the browser-extension popup styling.
//
//  The in-app dictionary popup is a standalone WebView document styled by
//  hibiki/assets/popup/popup.css. The extension injects the SAME popup.js render
//  output into a #entries-container <div> on every host page via a content
//  script, so popup.css's document-level rules (*, html, body, bare hr/a,
//  ::selection, ::-webkit-scrollbar, html[data-theme]) would reset / recolor /
//  re-font the host page (TODO-1090). This generator re-roots every such
//  document-level rule at #entries-container while keeping the class rules
//  verbatim, then appends the extension-only overlay (content-css-overlay.css:
//  floating-popup sizing, Netflix subtitle panel, mining queue chip).
//
//  Historically content.css was hand-ported from popup.css and silently drifted
//  (TODO-1267 / BUG: extension popup looked completely different + ugly + buttons
//  misplaced, because ~59 new popup.css selectors — favorite / clear-draft /
//  sentence-context / inline-action / kanji-card / pitch-transcription / scrollbar
//  — never got re-ported). This script mechanizes the documented transform so a
//  guard test can prove content.css is complete relative to popup.css.
//
//  Usage:
//    node tools/browser-extension/scripts/generate-content-css.mjs          # write
//    node tools/browser-extension/scripts/generate-content-css.mjs --check  # verify only (CI/guard)
//
//  Unknown document-level selectors throw loudly: a human must decide whether a
//  new bare / html / body / :: rule should be scoped or dropped — it must never
//  silently leak to the host page.
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//
import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const scriptsDir = dirname(fileURLToPath(import.meta.url));
// scripts -> browser-extension -> tools -> <repo root>
const repoRoot = join(scriptsDir, '..', '..', '..');

const POPUP_CSS = join(repoRoot, 'hibiki', 'assets', 'popup', 'popup.css');
const OVERLAY = join(scriptsDir, 'content-css-overlay.css');
const OUTPUTS = [
  join(repoRoot, 'tools', 'browser-extension', 'vendor', 'content.css'),
  join(repoRoot, 'hibiki', 'assets', 'browser_extension', 'vendor', 'content.css'),
];

/** Split a selector list on TOP-LEVEL commas only (commas inside :where(...) etc. are kept). */
function splitSelectorList(sel) {
  const parts = [];
  let depth = 0;
  let cur = '';
  for (const ch of sel) {
    if (ch === '(' || ch === '[') depth++;
    else if (ch === ')' || ch === ']') depth--;
    if (ch === ',' && depth === 0) {
      parts.push(cur);
      cur = '';
    } else {
      cur += ch;
    }
  }
  if (cur.trim() !== '') parts.push(cur);
  return parts;
}

/**
 * Transform one selector (a single comma-part).
 * @returns {string|null} scoped/verbatim selector, or null to drop it.
 */
function transformSelector(raw) {
  const p = raw.trim().replace(/\s+/g, ' ');
  if (p === '') return null;
  // App-external-window-only modes: the extension host #entries-container never
  // carries these classes, so drop them entirely (dead weight otherwise).
  if (p.startsWith('html.global-lookup') || p.startsWith('html.mobile-external')) {
    return null;
  }
  // Named custom highlight (CSS Custom Highlight API) is global by design and its
  // name (hoshi-selection) is unique — keep verbatim.
  if (p.startsWith('::highlight')) return p;
  // @font-face (TODO-1368/BUG-685: embedded "Hibiki Symbols" glyph subset for the
  // mine button's ✓/✓↩ text marks) cannot be scoped by design — font-face rules
  // are document-global. Keep verbatim: the family name is app-namespaced and the
  // src is a self-contained data: URI, so nothing leaks from / depends on the host.
  if (p.startsWith('@font-face')) return p;
  // Verbatim class/id/:where() rules — already popup-scoped in practice.
  if (p.startsWith('.') || p.startsWith('#') || p.startsWith(':where(')) return p;
  // Document-level rules → re-root at #entries-container.
  if (p === 'body') return '#entries-container';
  if (/^html([.[ ]|$)/.test(p)) return '#entries-container' + p.slice(4);
  if (p === '::selection') return '#entries-container ::selection';
  if (p.startsWith('::-webkit-scrollbar')) return '#entries-container ' + p;
  if (/^(hr|a)$/.test(p)) return '#entries-container ' + p;
  throw new Error(
    `[generate-content-css] UNKNOWN document-level selector ${JSON.stringify(p)}: ` +
      'decide whether to scope it to #entries-container or drop it, then update transformSelector().',
  );
}

/** Transform a whole selector list; returns replacement text, or null to drop the rule. */
function transformSelectorList(sel) {
  if (sel.trim() === '*') return '#entries-container,\n#entries-container *';
  const out = [];
  for (const part of splitSelectorList(sel)) {
    const t = transformSelector(part);
    // Dedupe: `html, body` both map to `#entries-container`, so collapse repeats.
    if (t !== null && !out.includes(t)) out.push(t);
  }
  if (out.length === 0) return null;
  return out.join(',\n');
}

/** Tokenize CSS into comments / whitespace / rules (no nested at-rules in popup.css). */
function tokenize(css) {
  const tokens = [];
  let i = 0;
  const n = css.length;
  while (i < n) {
    if (css.startsWith('/*', i)) {
      const end = css.indexOf('*/', i + 2);
      const stop = end < 0 ? n : end + 2;
      tokens.push({ type: 'comment', text: css.slice(i, stop) });
      i = stop;
      continue;
    }
    if (/\s/.test(css[i])) {
      let j = i;
      while (j < n && /\s/.test(css[j])) j++;
      tokens.push({ type: 'ws', text: css.slice(i, j) });
      i = j;
      continue;
    }
    // Rule: selector up to '{', body up to matching '}'. Skip comments while
    // scanning the selector so a comment brace never confuses us.
    let j = i;
    while (j < n && css[j] !== '{') {
      if (css.startsWith('/*', j)) {
        const e = css.indexOf('*/', j + 2);
        j = e < 0 ? n : e + 2;
      } else j++;
    }
    if (j >= n) {
      tokens.push({ type: 'ws', text: css.slice(i) });
      break;
    }
    const selector = css.slice(i, j);
    // body: from '{' to matching '}' (declarations only, but count depth defensively).
    let depth = 0;
    let k = j;
    for (; k < n; k++) {
      if (css.startsWith('/*', k)) {
        const e = css.indexOf('*/', k + 2);
        k = e < 0 ? n : e + 1;
        continue;
      }
      if (css[k] === '{') depth++;
      else if (css[k] === '}') {
        depth--;
        if (depth === 0) break;
      }
    }
    const body = css.slice(j, Math.min(k + 1, n));
    tokens.push({ type: 'rule', selector, body });
    i = k + 1;
  }
  return tokens;
}

function generate() {
  const popupCss = readFileSync(POPUP_CSS, 'utf8');
  const overlay = readFileSync(OVERLAY, 'utf8');
  const tokens = tokenize(popupCss);

  const banner =
    '/*\n' +
    ' *  content.css — GENERATED, DO NOT EDIT BY HAND.\n' +
    ' *\n' +
    ' *  Produced by tools/browser-extension/scripts/generate-content-css.mjs from\n' +
    ' *  hibiki/assets/popup/popup.css (shared dictionary-popup styling, document-\n' +
    ' *  level rules re-rooted at #entries-container so nothing leaks to the host\n' +
    ' *  page — TODO-1090) plus content-css-overlay.css (extension-only rules).\n' +
    ' *\n' +
    ' *  Edit popup.css / content-css-overlay.css and re-run the generator; never\n' +
    ' *  hand-edit this file. A guard test keeps it in sync (TODO-1267).\n' +
    ' *  SPDX-License-Identifier: GPL-3.0-or-later\n' +
    ' */\n\n';

  // Precompute which rule tokens are dropped (app-external-only) so we can also
  // drop the explanatory comment that immediately precedes such a rule — otherwise
  // the generated file keeps orphan comments describing rules that no longer exist.
  const ruleDrops = tokens.map((tok) =>
    tok.type === 'rule'
      ? transformSelectorList(tok.selector.replace(/\/\*[\s\S]*?\*\//g, '').trim()) === null
      : false,
  );
  /** A comment "leads" a dropped rule if the next non-ws token is a dropped rule
   *  separated by at most one blank line (≤2 newlines) — covers both an inline
   *  comment glued to the rule and a section header above the dropped block. Only
   *  ever skips comments whose immediate next rule is itself dropped, so section
   *  comments that introduce kept rules are never lost. */
  function commentLeadsDroppedRule(idx) {
    let j = idx + 1;
    let gap = '';
    while (j < tokens.length && tokens[j].type === 'ws') {
      gap += tokens[j].text;
      j++;
    }
    if (j >= tokens.length || tokens[j].type !== 'rule' || !ruleDrops[j]) return false;
    return (gap.match(/\n/g) || []).length <= 2;
  }

  let out = banner;
  for (let i = 0; i < tokens.length; i++) {
    const tok = tokens[i];
    if (tok.type === 'comment') {
      if (commentLeadsDroppedRule(i)) continue; // skip orphan comment of a dropped rule
      out += tok.text;
      continue;
    }
    if (tok.type === 'ws') {
      out += tok.text;
      continue;
    }
    // rule: transform the selector, keep the original body verbatim.
    const cleanSel = tok.selector.replace(/\/\*[\s\S]*?\*\//g, '').trim();
    const rep = transformSelectorList(cleanSel);
    if (rep === null) {
      // Dropped rule (app-external only). Collapse a blank line we just emitted so
      // drops don't pile up blank gaps.
      out = out.replace(/\n[ \t]*\n$/, '\n');
      continue;
    }
    out += rep + ' ' + tok.body.trim();
  }

  // Normalize the popup.css portion: collapse any 3+ newline runs left by drops
  // into a single blank line, then append the extension-only overlay.
  out = out.replace(/\n{3,}/g, '\n\n').replace(/\s+$/, '') + '\n\n';
  out += overlay.replace(/^\s+/, '').replace(/\s+$/, '') + '\n';
  return out;
}

function main() {
  const check = process.argv.includes('--check');
  const generated = generate();
  let ok = true;
  for (const target of OUTPUTS) {
    const current = (() => {
      try {
        return readFileSync(target, 'utf8');
      } catch {
        return null;
      }
    })();
    if (check) {
      if (current !== generated) {
        ok = false;
        console.error(`[generate-content-css] OUT OF SYNC: ${target}`);
      }
    } else {
      writeFileSync(target, generated);
      console.log(`[generate-content-css] wrote ${target} (${generated.length} bytes)`);
    }
  }
  if (check && !ok) {
    console.error(
      '\nRun: node tools/browser-extension/scripts/generate-content-css.mjs to regenerate.',
    );
    process.exit(1);
  }
  if (check && ok) console.log('[generate-content-css] content.css is in sync.');
}

main();
