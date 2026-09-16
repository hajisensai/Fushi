// BUG-2536 行为测试（node 真执行 audiobook_bridge.dart 里的高亮 / 图片暂停 JS）。
//
// 场景：有声书从上一章连续读到新章，新章第一句之前有插图（章扉画 / 合并进宿主顶部
// 的单图片章）。新文档里 __fushiPrevHighlight 为空，旧实现 __fushiImageBetween(null, el)
// 直接判无图 → 章首图既不触发 onImageDetected（图片等待）也不揭防剧透遮罩。
// 修法：Dart 在音频跨章落地后的第一次真实高亮传 fromChapterStart=true，JS 把
// document.body 当作上一句锚点，body→el 区间就是文档开头到第一句之间。
//
// 用一个极简 fake DOM 提供 compareDocumentPosition / contains / querySelectorAll，
// 从 Dart 源码里切出 _highlightFn 与 _sentenceAudioFn 两段 JS 原样执行。
'use strict';

const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

// ── fake DOM ────────────────────────────────────────────────────────────────

const POSITION = {
  DOCUMENT_POSITION_PRECEDING: 2,
  DOCUMENT_POSITION_FOLLOWING: 4,
  DOCUMENT_POSITION_CONTAINS: 8,
  DOCUMENT_POSITION_CONTAINED_BY: 16,
};

class FakeClassList {
  constructor(classes) { this._set = new Set(classes); }
  contains(c) { return this._set.has(c); }
  add(c) { this._set.add(c); }
  remove(c) { this._set.delete(c); }
}

class FakeElement {
  constructor(tag, opts) {
    opts = opts || {};
    this.nodeType = 1;
    this.tagName = tag.toUpperCase();
    this.id = opts.id || '';
    this.classList = new FakeClassList(opts.classes || []);
    this._attrs = Object.assign({}, opts.attrs || {});
    this.children = [];
    this.parentElement = null;
    this._order = -1;
  }
  append(...kids) {
    for (const k of kids) { k.parentElement = this; this.children.push(k); }
    return this;
  }
  getAttribute(name) {
    return Object.prototype.hasOwnProperty.call(this._attrs, name)
        ? this._attrs[name] : null;
  }
  setAttribute(name, value) { this._attrs[name] = String(value); }
  _isAncestorOf(other) {
    for (let p = other.parentElement; p; p = p.parentElement) {
      if (p === this) return true;
    }
    return false;
  }
  compareDocumentPosition(other) {
    if (other === this) return 0;
    if (this._isAncestorOf(other)) {
      return POSITION.DOCUMENT_POSITION_CONTAINED_BY |
             POSITION.DOCUMENT_POSITION_FOLLOWING;
    }
    if (other._isAncestorOf(this)) {
      return POSITION.DOCUMENT_POSITION_CONTAINS |
             POSITION.DOCUMENT_POSITION_PRECEDING;
    }
    return other._order > this._order
        ? POSITION.DOCUMENT_POSITION_FOLLOWING
        : POSITION.DOCUMENT_POSITION_PRECEDING;
  }
  scrollIntoView() {}
}

class FakeDocument {
  constructor(body) {
    this.body = body;
    this._all = [];
    const walk = (n) => {
      n._order = this._all.length;
      this._all.push(n);
      for (const c of n.children) walk(c);
    };
    walk(body);
  }
  contains(n) { return this._all.indexOf(n) >= 0; }
  _matches(n, sel) {
    sel = sel.trim();
    if (sel.startsWith('.')) return n.classList.contains(sel.slice(1));
    if (sel.startsWith('#')) return n.id === sel.slice(1);
    return n.tagName === sel.toUpperCase();
  }
  querySelectorAll(selector) {
    const parts = selector.split(',');
    return this._all.filter((n) => parts.some((p) => this._matches(n, p)));
  }
  querySelector(selector) {
    return this.querySelectorAll(selector)[0] || null;
  }
}

// ── 从 Dart 源码切出 JS ──────────────────────────────────────────────────────

const bridgePath = path.join(
    __dirname, '..', '..', '..', 'lib', 'src', 'media', 'audiobook',
    'audiobook_bridge.dart');
const dart = fs.readFileSync(bridgePath, 'utf8');

function sliceDartTripleQuoted(constName) {
  const marker = `static const String ${constName} = '''`;
  const start = dart.indexOf(marker);
  assert.ok(start >= 0, `找不到 ${constName}`);
  const bodyStart = start + marker.length;
  const end = dart.indexOf("''';", bodyStart);
  assert.ok(end > bodyStart, `${constName} 没有闭合`);
  const js = dart.slice(bodyStart, end);
  assert.ok(!/\$\{?/.test(js), `${constName} 含 Dart 插值，无法原样执行`);
  return js;
}

const highlightFn = sliceDartTripleQuoted('_highlightFn');
const sentenceAudioFn = sliceDartTripleQuoted('_sentenceAudioFn');

// ── 环境搭建 ────────────────────────────────────────────────────────────────

function makeEnv(body, opts) {
  opts = opts || {};
  const document = new FakeDocument(body);
  const calls = { handlers: [], revealed: [], marked: [], highlighted: [] };
  const sandbox = {
    document,
    Node: POSITION,
    console,
    flutter_inappwebview: {
      callHandler(name, arg) { calls.handlers.push([name, arg]); },
    },
    fushiReader: {
      // 不提供 scrollToRange（那要 document.createRange），走 revealElement 分支。
      revealElement(el) { calls.revealed.push(el); },
      cueWrappers: opts.cueWrappers || new Map(),
      highlightSentenceAudioCue(key, reveal) {
        calls.highlighted.push([key, reveal]);
      },
    },
  };
  if (opts.blurImages !== false) {
    sandbox.__fushiImageRevealKey = (m) => m.id || null;
    sandbox.__fushiMarkImageRevealed = (key) => calls.marked.push(key);
  }
  sandbox.window = sandbox;
  const ctx = vm.createContext(sandbox);
  vm.runInContext(highlightFn, ctx);
  vm.runInContext(sentenceAudioFn, ctx);
  return { ctx, sandbox, calls, document };
}

function detected(calls) {
  return calls.handlers.filter((h) => h[0] === 'onImageDetected').length;
}
function revealedKeys(calls) {
  return calls.handlers.filter((h) => h[0] === 'onImageRevealed')
      .map((h) => h[1]);
}

/// body > [img#cover.block-img.blurred, h1 > img#gaiji.gaiji, p#s1, img#mid.blurred, p#s2]
function chapterWithCover() {
  const cover = new FakeElement('img', {
    id: 'cover', classes: ['block-img', 'blurred'], attrs: { loading: 'lazy' },
  });
  const gaiji = new FakeElement('img', { id: 'gaiji', classes: ['gaiji'] });
  const h1 = new FakeElement('h1').append(gaiji);
  const s1 = new FakeElement('p', { id: 's1' });
  const mid = new FakeElement('img', { id: 'mid', classes: ['block-img', 'blurred'] });
  const s2 = new FakeElement('p', { id: 's2' });
  const body = new FakeElement('body').append(cover, h1, s1, mid, s2);
  return { body, cover, gaiji, h1, s1, mid, s2 };
}

// ── 断言 ────────────────────────────────────────────────────────────────────

// 1. 章首插图：fromChapterStart=true → 触发图片等待 + 揭遮罩 + 视口落到插图。
{
  const d = chapterWithCover();
  const env = makeEnv(d.body);
  const ret = env.sandbox.__fushiImagePauseAdvance(d.s1, true, true, true);
  assert.strictEqual(ret, true, '跨过章首图且 reveal 时应返回 true（已 reveal 图片）');
  assert.strictEqual(detected(env.calls), 1, '章首图须触发一次 onImageDetected');
  assert.deepStrictEqual(env.calls.revealed, [d.cover], '视口须落到章首插图');
  assert.ok(!d.cover.classList.contains('blurred'), '章首图的 blurred 遮罩须去掉');
  assert.deepStrictEqual(revealedKeys(env.calls), ['cover'], '须回传 onImageRevealed 持久化');
  assert.deepStrictEqual(env.calls.marked, ['cover'], '须登记进已揭活集');
  assert.strictEqual(d.cover.getAttribute('loading'), 'eager', '懒图须强制 eager 才看得见');
  assert.ok(d.mid.classList.contains('blurred'), '第一句之后的图不能被提前揭开');
  assert.strictEqual(env.sandbox.__fushiPrevHighlight, d.s1, '锚点须推进到第一句');
}

// 2. 非音频跨章到达（手动跳章 / 位置恢复）：锚点为空且不带标记 → 与旧行为一致，不动章首图。
{
  const d = chapterWithCover();
  const env = makeEnv(d.body);
  const ret = env.sandbox.__fushiImagePauseAdvance(d.s1, true, true, false);
  assert.strictEqual(ret, false);
  assert.strictEqual(detected(env.calls), 0, '手动到达不触发章首图暂停');
  assert.ok(d.cover.classList.contains('blurred'), '手动到达不揭章首图遮罩（没被音频读到）');
}

// 2b. 锚点被显式归零（resetImagePauseAnchor）后带标记到达：同样以 body 为锚。
{
  const d = chapterWithCover();
  const env = makeEnv(d.body);
  env.sandbox.__fushiResetPrevHighlight();
  assert.strictEqual(env.sandbox.__fushiPrevHighlight, null);
  const ret = env.sandbox.__fushiImagePauseAdvance(d.s1, true, true, true);
  assert.strictEqual(ret, true);
  assert.strictEqual(detected(env.calls), 1);
}

// 3. 章名里的 gaiji 外字不是插图：只有 gaiji 时不触发图片等待。
{
  const gaiji = new FakeElement('img', { id: 'g', classes: ['gaiji'] });
  const h1 = new FakeElement('h1').append(gaiji);
  const s1 = new FakeElement('p', { id: 's1' });
  const body = new FakeElement('body').append(h1, s1);
  const env = makeEnv(body);
  const ret = env.sandbox.__fushiImagePauseAdvance(s1, true, true, true);
  assert.strictEqual(ret, false, 'gaiji 不算插图');
  assert.strictEqual(detected(env.calls), 0, '章名里的外字不得触发图片等待');
  assert.deepStrictEqual(env.calls.revealed, [], '不得把视口滚到外字上');
}

// 4. 章内正常推进不受影响：s1 → s2 跨过 mid。
{
  const d = chapterWithCover();
  const env = makeEnv(d.body);
  env.sandbox.__fushiImagePauseAdvance(d.s1, true, true, true);
  const before = detected(env.calls);
  const ret = env.sandbox.__fushiImagePauseAdvance(d.s2, true, true, false);
  assert.strictEqual(ret, true);
  assert.strictEqual(detected(env.calls), before + 1, 's1→s2 须检测到 mid');
  assert.strictEqual(env.calls.revealed[env.calls.revealed.length - 1], d.mid);
  assert.ok(!d.mid.classList.contains('blurred'));
}

// 5. 图片等待关闭（pauseEnabled=false）：仍回传 onImageDetected（Dart 侧 no-op）、
//    仍揭遮罩（揭遮罩与图片等待解耦），但不把视口滚到图、返回 false。
{
  const d = chapterWithCover();
  const env = makeEnv(d.body);
  const ret = env.sandbox.__fushiImagePauseAdvance(d.s1, true, false, true);
  assert.strictEqual(ret, false);
  assert.strictEqual(detected(env.calls), 1);
  assert.deepStrictEqual(env.calls.revealed, [], 'pauseEnabled=false 不滚图');
  assert.ok(!d.cover.classList.contains('blurred'), '揭遮罩独立于图片等待开关');
}

// 6. sasayaki 高亮路径把 fromChapterStart 透传到共享 helper。
{
  const d = chapterWithCover();
  const env = makeEnv(d.body, { cueWrappers: new Map([['k1', [d.s1]]]) });
  const ok = env.sandbox.__fushiHighlightSentenceAudioCueById('k1', true, true, true);
  assert.strictEqual(ok, true);
  assert.strictEqual(detected(env.calls), 1, 'sasayaki 路径须透传 fromChapterStart');
  assert.deepStrictEqual(env.calls.highlighted, [['k1', false]],
      '已 reveal 到插图时 reader 只高亮不自动滚');
}

// 7. selector 高亮路径（SRT 合成书）同样透传。
{
  const d = chapterWithCover();
  const env = makeEnv(d.body);
  env.sandbox.__fushiHighlight('#s1', true, true, true);
  assert.strictEqual(detected(env.calls), 1, 'selector 路径须透传 fromChapterStart');
  assert.ok(d.s1.classList.contains('fushi-active'));
}

// 8. 图片防剧透关闭（无 __fushiImageRevealKey）：暂停照常、揭遮罩 no-op 不报错。
{
  const d = chapterWithCover();
  const env = makeEnv(d.body, { blurImages: false });
  const ret = env.sandbox.__fushiImagePauseAdvance(d.s1, true, true, true);
  assert.strictEqual(ret, true);
  assert.strictEqual(detected(env.calls), 1);
  assert.deepStrictEqual(revealedKeys(env.calls), []);
}

console.log('all assertions passed');
