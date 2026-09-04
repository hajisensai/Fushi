// BUG-2122 behavior test: 同一个音调型被多本词典各渲染成一行。
//
// 用户报告（官网首页 demo 弹窗，查「ギター」）：音高区连出五行一模一样的
// `￣ギター [1]`，来源分别是五本音调词典。Yomitan 在 getGroupedPronunciations 里
// 把相同发音合并成一条、后面挂全部来源标签；popup.js 之前是一本词典一行。
//
// 本测试 EXECUTES 真实的 popup.js（vm + 极简假 DOM），驱动真实的
// `createPitchSection`，然后走产出的元素树数点 `.pitch-group` 行数与
// `.pitch-dict-label` 药丸。把 mergeIdenticalPitchGroups 或它的调用点撤掉，
// case 1 立刻变红。
//
// 覆盖：
//   1. 五本词典同为 [1]（去重关闭）→ 只剩 1 行，5 枚来源药丸，按首次出现顺序。
//   2. 音调型不同（[1] vs [0]）→ 不合并，仍是 2 行。
//   3. 位置部分重叠（[1,0] vs [1]）→ 判据是 payload 全等，故意不合并，仍是 2 行。
//   4. 去重打开 + 五本同为 [1] → 与改动前一致：1 行 1 枚药丸（默认外观零变化）。
//   5. 两本纯 IPA 词典给出完全相同的 transcriptions（去重打开）→ 合并成 1 行 2 枚药丸。
//
// Run: node fushi/test/pages/popup_pitch_merge_identical_test.js
// (also driven from popup_pitch_merge_identical_test.dart so it executes inside
//  `flutter test`).

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
    setAttribute(k, v) { this.attributes[k] = v; },
    removeAttribute(k) { delete this.attributes[k]; },
    addEventListener() {},
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

function loadPopup() {
  const sandbox = makeSandbox();
  vm.createContext(sandbox);
  const exported = source + `
    ;window.__test = {
      createPitchSection: createPitchSection,
    };
  `;
  vm.runInContext(exported, sandbox, { filename: 'popup.js' });
  return sandbox;
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

function labelNames(section) {
  return collectByClass(section, 'pitch-dict-label').map(n => n.textContent);
}

function pitchGroupCount(section) {
  return collectByClass(section, 'pitch-group').length;
}

const FIVE_SAME = ['词典14', '词典13', '词典15', '词典16', '词典17'].map(
  name => ({ dictionary: name, pitchPositions: [1], patterns: [], transcriptions: [] }));

(function run() {
  // Case 1: 用户报告的原样输入 —— 五本词典同为 [1]，去重关闭。
  {
    const sb = loadPopup();
    sb.window.deduplicatePitchAccents = false;
    const section = sb.window.__test.createPitchSection(FIVE_SAME, 'ギター');
    assert.ok(section, 'five identical pitch dicts must still render a pitch section');
    assert.strictEqual(pitchGroupCount(section), 1,
      'five dictionaries agreeing on [1] must collapse into ONE .pitch-group row; got '
        + pitchGroupCount(section));
    assert.deepStrictEqual(labelNames(section),
      ['词典14', '词典13', '词典15', '词典16', '词典17'],
      'the merged row must carry every source label, in first-appearance order');
    const text = collectText(section);
    const occurrences = text.split('[1]').length - 1;
    assert.strictEqual(occurrences, 1,
      'the accent [1] must be drawn exactly once after merging; got ' + occurrences
        + ' in ' + JSON.stringify(text));
  }

  // Case 2: 音调型不同 —— 绝不合并。
  {
    const sb = loadPopup();
    sb.window.deduplicatePitchAccents = false;
    const section = sb.window.__test.createPitchSection([
      { dictionary: 'A', pitchPositions: [1], patterns: [], transcriptions: [] },
      { dictionary: 'B', pitchPositions: [0], patterns: [], transcriptions: [] },
    ], 'ねこ');
    assert.strictEqual(pitchGroupCount(section), 2,
      'dictionaries disagreeing on the accent must stay on separate rows');
    assert.deepStrictEqual(labelNames(section), ['A', 'B']);
  }

  // Case 3: 位置部分重叠 —— 判据是 payload 全等，故意不合并（宁可少合）。
  {
    const sb = loadPopup();
    sb.window.deduplicatePitchAccents = false;
    const section = sb.window.__test.createPitchSection([
      { dictionary: 'A', pitchPositions: [1, 0], patterns: [], transcriptions: [] },
      { dictionary: 'B', pitchPositions: [1], patterns: [], transcriptions: [] },
    ], 'ねこ');
    assert.strictEqual(pitchGroupCount(section), 2,
      'partially overlapping position sets must NOT be merged (payload equality is the rule)');
  }

  // Case 4: 去重打开（app 默认）—— 行为与改动前逐字一致：1 行 1 枚药丸。
  {
    const sb = loadPopup();
    sb.window.deduplicatePitchAccents = true;
    const section = sb.window.__test.createPitchSection(FIVE_SAME, 'ギター');
    assert.strictEqual(pitchGroupCount(section), 1,
      'dedup ON must still yield exactly one row');
    assert.deepStrictEqual(labelNames(section), ['词典14'],
      'dedup ON keeps only the first dictionary — the default look must not change');
  }

  // Case 5: 两本纯 IPA 词典给出完全相同的 transcriptions → 合并。
  {
    const sb = loadPopup();
    sb.window.deduplicatePitchAccents = true;
    const section = sb.window.__test.createPitchSection([
      { dictionary: 'IPA-1', pitchPositions: [], patterns: [], transcriptions: ['neꜜko'] },
      { dictionary: 'IPA-2', pitchPositions: [], patterns: [], transcriptions: ['neꜜko'] },
    ], 'ねこ');
    assert.strictEqual(pitchGroupCount(section), 1,
      'two IPA dicts with identical transcriptions must merge into one row');
    assert.deepStrictEqual(labelNames(section), ['IPA-1', 'IPA-2']);
    const text = collectText(section);
    assert.strictEqual(text.split('[neꜜko]').length - 1, 1,
      'the shared transcription must be printed once; got ' + JSON.stringify(text));
  }

  console.log('popup_pitch_merge_identical_test.js: all assertions passed');
})();
