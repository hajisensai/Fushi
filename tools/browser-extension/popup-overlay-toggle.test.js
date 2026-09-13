// popup 页脚「Fushi 字幕」开关的行为守卫（真加载 vendor/action-popup.js 跑断言）。
//
// 它翻的是 chrome.storage.local.subtitleOverlayEnabled——subtitle-panel.js 自绘覆盖层的总开关
// （外挂轨 / 替代原生 / 全轨覆盖层都经它出画），与 options 页「在视频上显示外挂字幕」同键。
// 回归形状：
//  ① 初始渲染没按 storage 真值画（缺省=开、显式 false=关）→ 用户看到的开关与视频页相反；
//  ② 点击只写 subtitleOverlayEnabled 不带 netflixSubtitlePanel → 从没开过侧边栏的用户点「开」
//     什么都不发生（覆盖层受总门门控，st.enabled=false 直接 teardownAll）；
//  ③ 点击顺手 window.close() → 用户看不到状态翻过去，以为没点上再点一次，又翻回去了。
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

function permissive() {
  return new Proxy(function () {}, {
    get(_t, key) {
      if (key === 'then' || key === Symbol.toPrimitive) return undefined;
      if (key === 'addListener' || key === 'removeListener') return function () {};
      return permissive();
    },
    apply() { return Promise.resolve({}); },
  });
}

function makeEl() {
  return {
    id: '', textContent: '', hidden: false, disabled: false, value: '', title: '',
    dataset: {}, attrs: {}, style: { setProperty() {}, removeProperty() {} }, children: [],
    handlers: {},
    classList: { add() {}, remove() {}, toggle() {} },
    addEventListener(type, fn) { (this.handlers[type] = this.handlers[type] || []).push(fn); },
    appendChild(child) { this.children.push(child); return child; },
    removeChild() {},
    setAttribute(k, v) { this.attrs[k] = v; }, getAttribute(k) { return this.attrs[k] || null; },
    removeAttribute(k) { delete this.attrs[k]; },
    scrollIntoView() {}, focus() {},
  };
}

// stored = chrome.storage.local 的初始内容；返回可操作句柄。
function loadPopup(stored) {
  const els = new Map();
  const sets = [];
  let closed = 0;
  let onChanged = null;
  const chromeMock = new Proxy({}, {
    get(_t, key) {
      if (key === 'storage') {
        return {
          local: {
            get(keys, cb) {
              const want = Array.isArray(keys) ? keys : [keys];
              const out = {};
              for (const k of want) if (k in stored) out[k] = stored[k];
              if (cb) cb(out);
              return Promise.resolve(out);
            },
            set(obj, cb) {
              // 沙盒里造的对象原型与宿主不同，deepStrictEqual 会判原型不等；存 JSON 快照。
              sets.push(JSON.parse(JSON.stringify(obj)));
              Object.assign(stored, obj);
              if (cb) cb();
              return Promise.resolve();
            },
          },
          onChanged: { addListener(fn) { onChanged = fn; } },
        };
      }
      if (key === 'tabs') {
        return {
          query(_q, cb) { cb([{ id: 7, url: 'https://www.youtube.com/watch?v=x', windowId: 3 }]); },
          update() {}, create() {},
        };
      }
      if (key === 'runtime') {
        return {
          sendMessage(_msg, cb) { if (cb) cb(undefined); },
          openOptionsPage() {}, lastError: undefined,
          getManifest() { return { version: '0.1.0' }; },
        };
      }
      return permissive();
    },
  });
  const sandbox = {
    document: {
      getElementById(id) {
        if (!els.has(id)) { const el = makeEl(); el.id = id; els.set(id, el); }
        return els.get(id);
      },
      createElement: makeEl,
      addEventListener() {},
      querySelector() { return null; },
      querySelectorAll() { return []; },
    },
    chrome: chromeMock,
    window: { close() { closed += 1; }, addEventListener() {} },
    setTimeout, clearTimeout, setInterval: () => 1, clearInterval,
    console, URL, Number, Promise, Date,
  };
  sandbox.self = sandbox;
  vm.runInNewContext(fs.readFileSync(path.join(__dirname, 'vendor', 'action-popup.js'), 'utf8'),
      sandbox, { filename: 'action-popup.js' });
  return {
    sets,
    closedCount() { return closed; },
    button() { return els.get('hp-overlay-toggle'); },
    stateEl() { return els.get('hp-overlay-toggle-state'); },
    click() {
      const btn = els.get('hp-overlay-toggle');
      assert.ok(btn && btn.handlers.click && btn.handlers.click.length,
          'popup 必须给「Fushi 字幕」按钮挂 click');
      for (const fn of btn.handlers.click) fn({});
    },
    // 模拟别处（options 页 / 视频页快捷键）改了同一个键：storage.onChanged 推回来。
    externalChange(value) {
      assert.ok(onChanged, 'popup 必须监听 storage.onChanged');
      onChanged({ subtitleOverlayEnabled: { newValue: value } }, 'local');
    },
  };
}

test('action-popup.html 真有「Fushi 字幕」开关按钮，且挂在字幕侧边栏按钮之前', () => {
  const html = fs.readFileSync(path.join(__dirname, 'vendor', 'action-popup.html'), 'utf8');
  const toggleAt = html.indexOf('id="hp-overlay-toggle"');
  const panelAt = html.indexOf('id="hp-nf-sublist"');
  assert.ok(toggleAt > 0, 'html 缺 #hp-overlay-toggle');
  assert.ok(html.includes('id="hp-overlay-toggle-state"'), 'html 缺状态文字容器');
  assert.ok(panelAt > toggleAt, '开关应排在「打开字幕侧边栏」之前（页脚第一项）');
});

test('初始渲染按 storage 真值：缺省=开', () => {
  const h = loadPopup({});
  assert.strictEqual(h.button().dataset.on, '1');
  assert.strictEqual(h.button().getAttribute('aria-pressed'), 'true');
  assert.strictEqual(h.stateEl().textContent, '开');
});

test('初始渲染按 storage 真值：显式 false=关', () => {
  const h = loadPopup({ subtitleOverlayEnabled: false });
  assert.strictEqual(h.button().dataset.on, '');
  assert.strictEqual(h.button().getAttribute('aria-pressed'), 'false');
  assert.strictEqual(h.stateEl().textContent, '关');
});

test('关→开：写 subtitleOverlayEnabled:true 并顺带打开总门 netflixSubtitlePanel；popup 不关', () => {
  const h = loadPopup({ subtitleOverlayEnabled: false });
  h.click();
  const last = h.sets[h.sets.length - 1];
  assert.deepStrictEqual(last, { subtitleOverlayEnabled: true, netflixSubtitlePanel: true });
  assert.strictEqual(h.stateEl().textContent, '开', '点击即反馈，不等落盘');
  assert.strictEqual(h.button().dataset.on, '1');
  assert.strictEqual(h.closedCount(), 0, '开关按钮不得关 popup');
});

test('开→关：只写 subtitleOverlayEnabled:false，不动总门；再点一次翻回开', () => {
  const h = loadPopup({ subtitleOverlayEnabled: true, netflixSubtitlePanel: true });
  h.click();
  assert.deepStrictEqual(h.sets[h.sets.length - 1], { subtitleOverlayEnabled: false });
  assert.strictEqual(h.stateEl().textContent, '关');
  h.click();
  assert.deepStrictEqual(h.sets[h.sets.length - 1],
      { subtitleOverlayEnabled: true, netflixSubtitlePanel: true });
  assert.strictEqual(h.stateEl().textContent, '开');
  assert.strictEqual(h.closedCount(), 0);
});

test('别处改了同一个键，popup 开着时跟着翻（options 页 / 视频页）', () => {
  const h = loadPopup({});
  assert.strictEqual(h.stateEl().textContent, '开');
  h.externalChange(false);
  assert.strictEqual(h.stateEl().textContent, '关');
  assert.strictEqual(h.button().dataset.on, '');
  h.externalChange(true);
  assert.strictEqual(h.stateEl().textContent, '开');
});
