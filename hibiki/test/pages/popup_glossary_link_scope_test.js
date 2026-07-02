// TODO-860 / BUG-435 behavior test: dictionary structured-content TEXT links
// (<a class="gloss-sc-a">) must stay in the inline flow, NOT escape sideways
// via the dictionary inline style (float / position:absolute|fixed).
//
// TODO-1022 / BUG-478: the misplaced glyph can also be a non-<a> span/div
// (Meikyo opening quote, class gloss-sc-span / gloss-sc-div).
//
// BUG-520 (regression of the BUG-478 fix): the blanket CSS rule
//   .structured-content span[class*="gloss-sc-"]:not(.gloss-image-link),
//   .structured-content div[class*="gloss-sc-"]:not(.gloss-image-link)
//   { float:none!important; position:static!important; display:inline; }
// forced display:inline onto EVERY gloss-sc-div. Structured content relies on
// the div's UA block display for line breaks, so every dictionary's lines
// collapsed into one run-on line (Meikyo monolingual AND bilingual dicts) and
// zero-line-height inline-block icon containers started overlapping text.
//
// ROOT FIX (this contract): the pollution source is popup.js
// setStructuredContentElementStyle applying dictionary inline styles verbatim.
// Upstream Yomitan whitelists schema style properties and never lands
// float / position on elements. We now drop the flow-escaping properties at
// the source (float always; position only when absolute|fixed|sticky --
// relative stays, it never leaves the flow), and the blanket CSS rule is GONE.
// The original a.gloss-sc-a CSS rule stays: it also guards against the
// dictionary's own styles.css (secondary cause of BUG-435).
//
// Asserts:
//  (1) <a>/span/div dict float + position:absolute|fixed are filtered at the
//      source (never land on element.style);
//  (2) position:relative and unrelated styles (fontWeight, marginRight) are
//      preserved;
//  (3) NO popup.css rule matches a plain gloss-sc-div/span and forces
//      display:inline or float/position (BUG-520 regression guard);
//  (4) a.gloss-sc-a CSS rule still exists, matches text links only, never the
//      image link;
//  (5) image link internals keep their own position:relative (separate code
//      path, applyImageStyles, TODO-859/350).
//
// Run: node hibiki/test/pages/popup_glossary_link_scope_test.js

const assert = require("assert");
const fs = require("fs");
const path = require("path");
const vm = require("vm");

const popupJsPath = path.resolve(__dirname, "../../assets/popup/popup.js");
const popupCssPath = path.resolve(__dirname, "../../assets/popup/popup.css");
const jsSource = fs.readFileSync(popupJsPath, "utf8");
const cssSource = fs.readFileSync(popupCssPath, "utf8").replace(/\r\n/g, "\n");

function makeElement(tag) {
  const el = {
    tagName: (tag || "div").toUpperCase(),
    nodeType: 1,
    className: "",
    id: "",
    target: "",
    rel: "",
    textContent: "",
    innerHTML: "",
    style: {},
    dataset: {},
    children: [],
    parentElement: null,
    _attrs: {},
    classList: {
      _set: new Set(),
      add(name) { this._set.add(name); },
      remove(name) { this._set.delete(name); },
      contains(name) { return this._set.has(name); },
    },
    appendChild(child) { if (child) child.parentElement = this; this.children.push(child); return child; },
    append(...nodes) { for (const n of nodes) { if (n) n.parentElement = this; } this.children.push(...nodes); },
    setAttribute(k, v) { this._attrs[k] = v; },
    removeAttribute(k) { delete this._attrs[k]; },
    getAttribute(k) { return Object.prototype.hasOwnProperty.call(this._attrs, k) ? this._attrs[k] : null; },
    hasAttribute(k) { return Object.prototype.hasOwnProperty.call(this._attrs, k); },
    addEventListener() {},
    querySelectorAll() { return []; },
    querySelector() { return null; },
    closest() { return null; },
  };
  return el;
}

function makeSandbox() {
  const documentObj = {
    documentElement: { style: {}, classList: makeElement().classList },
    head: { appendChild() {} },
    body: makeElement("body"),
    getElementById() { return null; },
    querySelector() { return null; },
    querySelectorAll() { return []; },
    createElement(tag) { return makeElement(tag); },
    createTextNode(text) { return { nodeType: 3, textContent: text }; },
    addEventListener() {},
  };
  const windowObj = {
    audioSources: [],
    needsAudio: false,
    lookupEntries: [],
    dictionaryStyles: {},
    hiddenDictionaryNames: [],
    collapsedDictionaryNames: [],
    collapseDictionaries: false,
    autoExpandDictionaries: 1,
    flutter_inappwebview: { callHandler() { return Promise.resolve(false); } },
    getSelection() { return { toString() { return ""; } }; },
  };
  documentObj.defaultView = windowObj;
  const sandbox = {
    Node: { TEXT_NODE: 3, ELEMENT_NODE: 1 },
    Date, Math, URL, JSON, RegExp, Set, Map, Object, Array, console,
    performance: { now() { return 0; } },
    setTimeout, clearTimeout,
    DOMParser: class { parseFromString() { return { body: makeElement("body"), querySelectorAll() { return []; } }; } },
    document: documentObj,
    window: windowObj,
    getComputedStyle() { return {}; },
    rewriteDictionaryMediaPath(p) { return p; },
  };
  sandbox.globalThis = sandbox;
  return sandbox;
}

function loadPopup() {
  const sandbox = makeSandbox();
  vm.createContext(sandbox);
  const harness = [
    "",
    ";window.__test = {",
    "  renderSc: function(node) {",
    "    const parent = document.createElement('div');",
    "    parent.classList.add('structured-content');",
    "    renderStructuredContent(parent, node, 'ja', 'JMdict', false);",
    "    return parent.children[0];",
    "  },",
    "  makeImageLink: function() {",
    "    return createDefinitionImage({ path: 'media/x.png', width: 50, height: 50 }, 'JMdict', false);",
    "  },",
    "};",
  ].join("\n");
  vm.runInContext(jsSource + harness, sandbox, { filename: "popup.js" });
  return sandbox;
}

function parseRules(text) {
  const noComments = text.replace(/\/\*[\s\S]*?\*\//g, "");
  const rules = [];
  for (const m of noComments.matchAll(/([^{}]+)\{([^{}]*)\}/g)) {
    rules.push({ selector: m[1].trim(), body: m[2].trim() });
  }
  return rules;
}

// Match a single compound selector (no combinators) against one element.
// Understands tag, .class, [class*="..."] substring, and :not(.class).
function compoundMatches(compound, el) {
  let work = compound.trim();
  const notClauses = [];
  work = work.replace(/:not\(([^)]*)\)/g, (_, inner) => {
    notClauses.push(inner.trim());
    return "";
  });
  const tagMatch = work.match(/^[a-z][a-z0-9]*/i);
  const tag = tagMatch ? tagMatch[0] : null;
  if (tag && el.tagName.toLowerCase() !== tag.toLowerCase()) return false;
  const classes = (work.match(/\.[A-Za-z0-9_-]+/g) || []).map((c) => c.slice(1));
  for (const c of classes) {
    if (!el.classList.contains(c)) return false;
  }
  const subAttrs = work.match(/\[class\*="([^"]+)"\]/g) || [];
  for (const raw of subAttrs) {
    const needle = raw.match(/\[class\*="([^"]+)"\]/)[1];
    const joined = Array.from(el.classList._set).join(" ");
    if (joined.indexOf(needle) < 0) return false;
  }
  for (const inner of notClauses) {
    if (compoundMatches(inner, el)) return false;
  }
  return true;
}

// Walk ancestor chain (via parentElement) to satisfy descendant combinators.
function descendantMatches(selector, el) {
  const parts = selector.trim().split(/\s+(?![^\[]*\])/);
  let i = parts.length - 1;
  if (!compoundMatches(parts[i], el)) return false;
  i -= 1;
  let node = el.parentElement;
  while (i >= 0) {
    let found = false;
    while (node) {
      if (compoundMatches(parts[i], node)) { found = true; node = node.parentElement; break; }
      node = node.parentElement;
    }
    if (!found) return false;
    i -= 1;
  }
  return true;
}

function selectorListMatches(selectorList, el) {
  return selectorList.split(",").some((s) => descendantMatches(s, el));
}

function findChildByClass(root, className) {
  if (root.classList && root.classList.contains(className)) return root;
  for (const c of root.children || []) {
    const hit = findChildByClass(c, className);
    if (hit) return hit;
  }
  return null;
}

(function run() {
  const sb = loadPopup();

  // ---- (1) Source filter: flow-escaping inline styles never land ---------
  const textLink = sb.window.__test.renderSc({
    tag: "a",
    href: "?query=foo",
    style: { position: "absolute", float: "right", fontWeight: "bold" },
    content: "foo",
  });
  assert.ok(textLink, "structured-content <a> must render");
  assert.strictEqual(textLink.tagName, "A", "text link is an <a> element");
  assert.ok(textLink.classList.contains("gloss-sc-a"),
    "text link must carry class gloss-sc-a");
  assert.strictEqual(textLink.style.position, undefined,
    "ROOT FIX: dict inline position:absolute must be filtered at the source");
  assert.strictEqual(textLink.style.float, undefined,
    "ROOT FIX: dict inline float must be filtered at the source");
  assert.strictEqual(textLink.style.fontWeight, "bold",
    "unrelated dict styles must still be applied");

  const quoteSpan = sb.window.__test.renderSc({
    tag: "span",
    style: { position: "absolute", float: "right" },
    content: "Q",
  });
  assert.ok(quoteSpan.classList.contains("gloss-sc-span"),
    "quote span must carry class gloss-sc-span");
  assert.strictEqual(quoteSpan.style.position, undefined,
    "BUG-478: span position:absolute must be filtered at the source");
  assert.strictEqual(quoteSpan.style.float, undefined,
    "BUG-478: span float must be filtered at the source");

  const blockDiv = sb.window.__test.renderSc({
    tag: "div",
    style: { position: "fixed", float: "left", marginRight: 0.5 },
    content: "x",
  });
  assert.ok(blockDiv.classList.contains("gloss-sc-div"),
    "div must carry class gloss-sc-div");
  assert.strictEqual(blockDiv.style.position, undefined,
    "BUG-478: div position:fixed must be filtered at the source");
  assert.strictEqual(blockDiv.style.float, undefined,
    "BUG-478: div float must be filtered at the source");
  assert.strictEqual(blockDiv.style.marginRight, "0.5em",
    "numeric margin conversion must survive the filter");
  assert.strictEqual(blockDiv.style.display, undefined,
    "BUG-520: nothing may force a display onto a dict div -- line breaks " +
    "depend on its UA block display");

  // ---- (2) position:relative stays in the flow -> preserved --------------
  const relSpan = sb.window.__test.renderSc({
    tag: "span",
    style: { position: "relative", top: "-0.2em" },
    content: "r",
  });
  assert.strictEqual(relSpan.style.position, "relative",
    "position:relative never leaves the flow and must be preserved");
  assert.strictEqual(relSpan.style.top, "-0.2em",
    "relative offset must be preserved");

  const stickyDiv = sb.window.__test.renderSc({
    tag: "div",
    style: { position: "sticky" },
    content: "s",
  });
  assert.strictEqual(stickyDiv.style.position, undefined,
    "position:sticky escapes the flow and must be filtered");

  // ---- (3) BUG-520 regression guard: no blanket CSS on gloss-sc div/span -
  const rules = parseRules(cssSource);
  const plainDiv = sb.window.__test.renderSc({ tag: "div", content: "x" });
  const plainSpan = sb.window.__test.renderSc({ tag: "span", content: "y" });
  for (const el of [plainDiv, plainSpan]) {
    const label = el.tagName.toLowerCase();
    for (const rule of rules) {
      if (!selectorListMatches(rule.selector, el)) continue;
      const norm = rule.body.replace(/\s+/g, "");
      assert.ok(!/display:inline(?![-a-z])/.test(norm),
        "BUG-520: no popup.css rule may force display:inline onto a plain " +
        "gloss-sc-" + label + " (div line breaks depend on block display); " +
        "offending selector: " + rule.selector);
      assert.ok(!/float:none!important/.test(norm)
        && !/position:static!important/.test(norm),
        "BUG-520: no blanket popup.css rule may neutralize float/position " +
        "on a plain gloss-sc-" + label + "; offending selector: " + rule.selector);
    }
  }

  // ---- (4) a.gloss-sc-a CSS rule stays (dictionary styles.css guard) -----
  const imageLink = sb.window.__test.makeImageLink();
  assert.ok(imageLink, "image link must render");
  assert.ok(imageLink.classList.contains("gloss-image-link"),
    "image link must carry class gloss-image-link");
  assert.ok(!imageLink.classList.contains("gloss-sc-a"),
    "image link must NOT carry gloss-sc-a");

  const anchorRules = rules.filter((r) => /a\.gloss-sc-a\b/.test(r.selector));
  assert.strictEqual(anchorRules.length, 1,
    "exactly one popup.css rule must target a.gloss-sc-a");
  const anchorFix = anchorRules[0];
  assert.ok(!/gloss-image-link/.test(anchorFix.selector),
    "SCOPE: a.gloss-sc-a fix selector must NOT mention gloss-image-link");
  const anchorNorm = anchorFix.body.replace(/\s+/g, "");
  assert.ok(/float:none!important/.test(anchorNorm),
    "a.gloss-sc-a fix must neutralize float to none !important");
  assert.ok(/position:static!important/.test(anchorNorm),
    "a.gloss-sc-a fix must neutralize position to static !important");
  assert.ok(descendantMatches(".structured-content a.gloss-sc-a", textLink),
    "a.gloss-sc-a rule must match the gloss-sc-a text link");
  assert.ok(!descendantMatches(".structured-content a.gloss-sc-a", imageLink),
    "REVERSE GUARD: a.gloss-sc-a rule must NOT match the gloss-image-link");

  // ---- (5) image internals keep their own position (separate path) -------
  // In the popup (non-exporting) path the image link is styled by popup.css
  // classes, not by setStructuredContentElementStyle, so the source filter
  // cannot touch it. Assert popup.css still positions .gloss-image-link
  // (TODO-859/350: image sizer/lightbox depend on position:relative).
  const imageLinkRules = rules.filter((r) =>
    selectorListMatches(r.selector, imageLink));
  assert.ok(imageLinkRules.some((r) =>
    /position:\s*relative/.test(r.body)),
    "popup.css must keep .gloss-image-link position:relative " +
    "(TODO-859/350 image layout)");

  // ---- ruby/rt: uniform source filter, other styles preserved ------------
  const rubyRoot = sb.window.__test.renderSc({
    tag: "ruby",
    style: { float: "right" },
    content: [
      { tag: "rt", style: { position: "absolute", fontSize: "0.6em" }, content: "a" },
    ],
  });
  assert.ok(rubyRoot.classList.contains("gloss-sc-ruby"),
    "ruby node must carry class gloss-sc-ruby");
  assert.strictEqual(rubyRoot.style.float, undefined,
    "source filter applies uniformly: ruby float filtered");
  const rtNode = findChildByClass(rubyRoot, "gloss-sc-rt");
  assert.ok(rtNode, "ruby must contain an rt child");
  assert.strictEqual(rtNode.style.position, undefined,
    "source filter applies uniformly: rt position:absolute filtered");
  assert.strictEqual(rtNode.style.fontSize, "0.6em",
    "rt keeps its legitimate fontSize");

  console.log("popup_glossary_link_scope_test.js: all assertions passed");
})();
