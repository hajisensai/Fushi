// TODO-860 / BUG-435 behavior test: dictionary structured-content TEXT links
// (<a class="gloss-sc-a">) must stay in the inline flow, NOT escape sideways
// via the dictionary inline style (float / position:absolute|fixed) that
// popup.js:setStructuredContentElementStyle lands on element.style with no
// whitelist.
//
// The fix is a pure CSS rule in popup.css:
//   .structured-content a.gloss-sc-a { float:none!important; position:static!important; display:inline; }
//
// This harness EXECUTES the real popup.js renderStructuredContent against a
// minimal fake DOM, then matches the actual popup.css rule against the rendered
// elements. It asserts:
//   1. a structured-content <a> gets class gloss-sc-a and DOES carry the
//      escaping inline style (float/position) from the dictionary node -- i.e.
//      the bug condition is real and reproduced;
//   2. the popup.css a.gloss-sc-a rule MATCHES that text link and neutralizes
//      float (none) + position (static);
//   3. (REVERSE GUARD) an image link <a class="gloss-image-link"> produced by
//      the real createDefinitionImage is NOT matched by that rule -- image links
//      keep their legitimate position/float (TODO-859/350).
// Reverting either the CSS rule or its scope turns this red.
//
// Run: node hibiki/test/pages/popup_glossary_link_scope_test.js
// (also driven from popup_glossary_link_scope_test.dart inside flutter test.)

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
    _attrs: {},
    classList: {
      _set: new Set(),
      add(name) { this._set.add(name); },
      remove(name) { this._set.delete(name); },
      contains(name) { return this._set.has(name); },
    },
    appendChild(child) { this.children.push(child); return child; },
    append(...nodes) { this.children.push(...nodes); },
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
    // Host-injected globals (not part of popup.js): stub so the real
    // createDefinitionImage runs end-to-end and yields a real gloss-image-link.
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

function rightmostCompoundMatches(selector, el) {
  const parts = selector.trim().split(/\s+/);
  const compound = parts[parts.length - 1];
  const tagMatch = compound.match(/^[a-z][a-z0-9]*/i);
  const tag = tagMatch ? tagMatch[0] : null;
  const classes = (compound.match(/\.[A-Za-z0-9_-]+/g) || []).map((c) => c.slice(1));
  if (tag && el.tagName.toLowerCase() !== tag.toLowerCase()) return false;
  for (const c of classes) {
    if (!el.classList.contains(c)) return false;
  }
  return true;
}

(function run() {
  const sb = loadPopup();

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
  const fixRules = rules.filter((r) => /a\.gloss-sc-a\b/.test(r.selector));
  assert.strictEqual(fixRules.length, 1,
    "exactly one popup.css rule must target a.gloss-sc-a");
  const fix = fixRules[0];
  assert.ok(!/gloss-image-link/.test(fix.selector),
    "SCOPE: fix selector must NOT mention gloss-image-link");

  const norm = fix.body.replace(/\s+/g, "");
  assert.ok(/float:none!important/.test(norm),
    "fix must neutralize float to none !important");
  assert.ok(/position:static!important/.test(norm),
    "fix must neutralize position to static !important");

  assert.ok(rightmostCompoundMatches(fix.selector, textLink),
    "fix rule must match the gloss-sc-a text link");
  assert.ok(!rightmostCompoundMatches(fix.selector, imageLink),
    "REVERSE GUARD: fix rule must NOT match the gloss-image-link image link");

  console.log("popup_glossary_link_scope_test.js: all assertions passed");
})();
