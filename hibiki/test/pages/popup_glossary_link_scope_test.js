// TODO-860 / BUG-435 behavior test: dictionary structured-content TEXT links
// (<a class="gloss-sc-a">) must stay in the inline flow, NOT escape sideways
// via the dictionary inline style (float / position:absolute|fixed) that
// popup.js:setStructuredContentElementStyle lands on element.style with no
// whitelist.
//
// The fix is a pure CSS rule in popup.css:
//   .structured-content a.gloss-sc-a { float:none!important; position:static!important; display:inline; }
//
// TODO-1022 / BUG-435 regression (uncovered branch): the misplaced glyph is NOT
// an <a> but a structured-content span/div -- Meikyo opening quote carries
// class gloss-sc-span / gloss-sc-div, which the original a.gloss-sc-a rule never
// reached, so it escaped sideways again. The fix extends the neutralization to:
//   .structured-content span[class*="gloss-sc-"]:not(.gloss-image-link),
//   .structured-content div[class*="gloss-sc-"]:not(.gloss-image-link)
// while a second rule reverts float/position for span/div nested inside an
// image link or inside ruby/rt (TODO-859/350 + furigana layout stay intact).
//
// Asserts (1) <a> text link reproduces+neutralized, (2) image link untouched by
// a.gloss-sc-a rule, (3) TODO-1022 span/div quote reproduces+neutralized by the
// new rule, (4) image-link element + ruby/rt NOT matched by the new rule.
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
  const re = /([^{}]+)\{([^{}]*)\}/g;
  let m;
  while ((m = re.exec(noComments)) !== null) {
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

  // ---- Existing TODO-860 <a> text-link coverage --------------------------
  const textLink = sb.window.__test.renderSc({
    tag: "a",
    href: "?query=foo",
    style: { position: "absolute", float: "right" },
    content: "foo",
  });
  assert.ok(textLink, "structured-content <a> must render");
  assert.strictEqual(textLink.tagName, "A", "text link is an <a> element");
  assert.ok(textLink.classList.contains("gloss-sc-a"),
    "text link must carry class gloss-sc-a (popup.js:1353)");
  assert.strictEqual(textLink.style.position, "absolute",
    "reproduction: dict inline position escaped onto element.style");
  assert.strictEqual(textLink.style.float, "right",
    "reproduction: dict inline float escaped onto element.style");

  const imageLink = sb.window.__test.makeImageLink();
  assert.ok(imageLink, "image link must render");
  assert.ok(imageLink.classList.contains("gloss-image-link"),
    "image link must carry class gloss-image-link (popup.js:866)");
  assert.ok(!imageLink.classList.contains("gloss-sc-a"),
    "image link must NOT carry gloss-sc-a");

  const rules = parseRules(cssSource);

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

  // ---- TODO-1022: non-<a> span/div quote coverage ------------------------
  const quoteSpan = sb.window.__test.renderSc({
    tag: "span",
    style: { position: "absolute", float: "right" },
    content: "Q",
  });
  assert.strictEqual(quoteSpan.tagName, "SPAN", "quote node is a <span>");
  assert.ok(quoteSpan.classList.contains("gloss-sc-span"),
    "quote span must carry class gloss-sc-span (popup.js:1353)");
  assert.strictEqual(quoteSpan.style.position, "absolute",
    "reproduction: dict inline position escaped onto the span");
  assert.strictEqual(quoteSpan.style.float, "right",
    "reproduction: dict inline float escaped onto the span");

  const quoteDiv = sb.window.__test.renderSc({
    tag: "div",
    style: { position: "fixed", float: "left" },
    content: "x",
  });
  assert.ok(quoteDiv.classList.contains("gloss-sc-div"),
    "quote div must carry class gloss-sc-div");

  const spanDivRules = rules.filter(
    (r) => /span\[class\*="gloss-sc-"\]/.test(r.selector)
      && /float:\s*none\s*!important/.test(r.body));
  assert.strictEqual(spanDivRules.length, 1,
    "exactly one popup.css rule must neutralize span/div gloss-sc-* float/position");
  const spanDivFix = spanDivRules[0];
  const sdNorm = spanDivFix.body.replace(/\s+/g, "");
  assert.ok(/float:none!important/.test(sdNorm),
    "span/div fix must neutralize float to none !important");
  assert.ok(/position:static!important/.test(sdNorm),
    "span/div fix must neutralize position to static !important");
  assert.ok(/:not\(\.gloss-image-link\)/.test(spanDivFix.selector),
    "SCOPE: span/div fix selector must exclude .gloss-image-link via :not()");

  assert.ok(selectorListMatches(spanDivFix.selector, quoteSpan),
    "TODO-1022: span/div rule must match the gloss-sc-span quote");
  assert.ok(selectorListMatches(spanDivFix.selector, quoteDiv),
    "TODO-1022: span/div rule must match the gloss-sc-div quote");

  assert.ok(!selectorListMatches(spanDivFix.selector, imageLink),
    "REVERSE GUARD: span/div rule must NOT match the gloss-image-link element");

  const rubyRoot = sb.window.__test.renderSc({
    tag: "ruby",
    style: { position: "absolute", float: "right" },
    content: [
      { tag: "rt", style: { position: "absolute", float: "right" }, content: "a" },
    ],
  });
  assert.ok(rubyRoot.classList.contains("gloss-sc-ruby"),
    "ruby node must carry class gloss-sc-ruby");
  assert.ok(!selectorListMatches(spanDivFix.selector, rubyRoot),
    "REVERSE GUARD: span/div rule must NOT match the <ruby> element");
  const rtNode = findChildByClass(rubyRoot, "gloss-sc-rt");
  assert.ok(rtNode, "ruby must contain an rt child");
  assert.ok(!selectorListMatches(spanDivFix.selector, rtNode),
    "REVERSE GUARD: span/div rule must NOT match the <rt> element");

  console.log("popup_glossary_link_scope_test.js: all assertions passed");
})();
