// 真 popup.js 的 node 宿主：vm + 极简假 DOM。
//
// **抽出来是因为它被复制了五份**：每份 ~95 行逐字相同（只有注释不同），Sonar 的
// `new_duplicated_lines_density` 门（限 3）会因此直接判红。`.sonarcloud.properties`
// 里写明排除只给「改不了的上游」和「被守卫强制的镜像」用——本仓自己的测试代码不在
// 其列，加排除等于违反已写下的政策，所以收敛成共享模块。
//
// 注意 `vm.runInContext` 会被 Sonar 报 javascript:S1523（CRITICAL）。那是这套宿主的
// 固有代价（既有文件上同样 OPEN），只能在 SonarCloud 上标 safe，改代码消不掉。

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const popupPath = path.resolve(__dirname, '../../assets/popup/popup.js');
const source = fs.readFileSync(popupPath, 'utf8');

function makeElement(tag) {
  return {
    tagName: (tag || 'div').toUpperCase(),
    className: '',
    id: '',
    textContent: '',
    title: '',
    innerHTML: '',
    nodeType: 1,
    style: {},
    dataset: {},
    children: [],
    childNodes: [],
    attributes: {},
    classList: {
      _set: new Set(),
      add(name) { this._set.add(name); },
      remove(name) { this._set.delete(name); },
      contains(name) { return this._set.has(name); },
    },
    appendChild(child) { this.children.push(child); this.childNodes.push(child); return child; },
    append(...nodes) { this.children.push(...nodes); this.childNodes.push(...nodes); },
    listeners: {},
    setAttribute(k, v) { this.attributes[k] = v; },
    getAttribute(k) { return k in this.attributes ? this.attributes[k] : null; },
    removeAttribute(k) { delete this.attributes[k]; },
    // 记下监听器，测试可用 dispatch(el, 'click') 真跑交互。
    addEventListener(type, fn) { (this.listeners[type] = this.listeners[type] || []).push(fn); },
    querySelectorAll() { return []; },
    querySelector() { return null; },
    closest() { return null; },
  };
}

function makeTextNode(text) {
  return { nodeType: 3, textContent: String(text), children: [], childNodes: [] };
}

function makeSandbox() {
  const documentObj = {
    documentElement: { style: {}, classList: makeElement().classList },
    head: { appendChild() {} },
    body: makeElement('body'),
    getElementById() { return null; },
    querySelector() { return null; },
    querySelectorAll() { return []; },
    createElement(tag) { return makeElement(tag); },
    createTextNode(text) { return makeTextNode(text); },
    addEventListener() {},
    removeEventListener() {},
  };

  const windowObj = {
    audioSources: [],
    needsAudio: false,
    lookupEntries: [],
    dictionaryStyles: {},
    // 官网 demo 与「关掉去重」的用户就是这一档；每个 case 各自覆写。
    deduplicatePitchAccents: false,
    flutter_inappwebview: { callHandler() { return Promise.resolve(false); } },
    getSelection() { return { toString() { return ''; } }; },
  };
  documentObj.defaultView = windowObj;

  const sandbox = {
    Node: { TEXT_NODE: 3, ELEMENT_NODE: 1 },
    Date, Math, URL, JSON, RegExp, Set, Map, Object, Array, console,
    performance: { now() { return 0; } },
    setTimeout, clearTimeout,
    DOMParser: class { parseFromString() { return { body: makeElement('body'), querySelectorAll() { return []; } }; } },
    document: documentObj,
    window: windowObj,
    getComputedStyle() { return {}; },
  };
  sandbox.globalThis = sandbox;
  return sandbox;
}

// `beforeRun(sandbox)`：popup.js 执行前改装沙盒（换掉 document 监听记录器、预置
// 注入全局等），用于断言「脚本加载那一刻」的挂载行为。
function loadPopup(beforeRun) {
  const sandbox = makeSandbox();
  if (beforeRun) beforeRun(sandbox);
  vm.createContext(sandbox);
  const exported = source + `
    ;window.__test = {
      createPitchSection: createPitchSection,
    };
  `;
  vm.runInContext(exported, sandbox, { filename: 'popup.js' });
  return sandbox;
}

function dispatch(node, type) {
  (node.listeners[type] || []).forEach(fn => fn({ type, target: node }));
}

// 深度优先收集所有 className == cls 的元素节点。
function collectByClass(node, cls, acc) {
  acc = acc || [];
  if (!node) return acc;
  if (node.nodeType !== 3 && node.className === cls) acc.push(node);
  const kids = node.children || node.childNodes || [];
  for (const k of kids) collectByClass(k, cls, acc);
  return acc;
}

function collectText(node) {
  if (!node) return '';
  let out = node.nodeType === 3 ? (node.textContent || '') : '';
  if (typeof node.textContent === 'string' && node.nodeType !== 3 &&
      (!node.children || node.children.length === 0)) {
    out += node.textContent;
  }
  const kids = node.children || node.childNodes || [];
  for (const k of kids) out += collectText(k);
  return out;
}

module.exports = {
  loadPopup: loadPopup,
  collectByClass: collectByClass,
  collectText: collectText,
  dispatch: dispatch,
};
