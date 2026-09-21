// player-controls.js 行为守卫：播放器控制栏里的 Fushi 字幕按钮 + 菜单。
//
// 这个模块的价值全在「不另立一套状态」上，所以测试的重心不是「点了会不会有反应」，而是
//   ① 覆盖层总开关的写法与工具栏弹窗**同一份语义**（交叉比对真实的 action-popup 实现，
//      不是比对一份抄来的期望值——那样两边一起错就一起绿）；
//   ② 隐藏字幕**不自己写盘**（那份状态归 content.js 独占）；
//   ③ 外观改动等于默认时**删键**而不是写等值对象；
//   ④ 外观控件的上下限取自 fushiSubtitleStyle，不在本文件里硬编码。
// 文案走 i18n：壳里装 zh-CN 字典，与仓库既有测试同口径。
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const FUSHI_T = require('./scripts/i18n-fixture.js').makeFushiT();
const SRC = fs.readFileSync(path.join(__dirname, 'player-controls.js'), 'utf8');
const MANIFEST = require('./manifest.json');
const { fushiOverlayToggleWrite } = require('./vendor/action-popup.js');

// 纯函数面：node 里 window/document 都没有，模块自己在 DOM 段之前 return，require 即可拿到 API。
globalThis.fushiT = FUSHI_T;
const PC = require('./player-controls.js');

// ── 手搓 DOM（无 jsdom，与仓库其余测试同一路数） ────────────────────────────────
function makeEl(tag) {
  const el = {
    tagName: String(tag || 'div').toUpperCase(),
    id: '',
    className: '',
    children: [],
    parentNode: null,
    handlers: {},
    attrs: {},
    dataset: {},
    hidden: false,
    title: '',
    type: '',
    value: '',
    offsetWidth: 288,
    offsetHeight: 300,
    style: {},
    setAttribute(name, value) {
      this.attrs[name] = String(value);
      if (name === 'id') this.id = String(value);
    },
    getAttribute(name) { return Object.prototype.hasOwnProperty.call(this.attrs, name) ? this.attrs[name] : null; },
    removeAttribute(name) { delete this.attrs[name]; },
    addEventListener(type, fn) { (this.handlers[type] = this.handlers[type] || []).push(fn); },
    appendChild(child) { child.parentNode = this; this.children.push(child); return child; },
    insertBefore(child, before) {
      // 真 DOM 的语义是「移动」：已在树上的同一节点先被摘下来再插回去。壳里必须
      // 照做，否则「每秒重插同一个节点」这类 bug 在测试里只会表现成节点变多，
      // 或者干脆看不出来。
      const had = this.children.indexOf(child);
      if (had >= 0) this.children.splice(had, 1);
      child.parentNode = this;
      const at = before ? this.children.indexOf(before) : -1;
      if (at < 0) this.children.push(child); else this.children.splice(at, 0, child);
      child.insertCount = (child.insertCount || 0) + 1;
      return child;
    },
    removeChild(child) {
      this.children = this.children.filter((it) => it !== child);
      child.parentNode = null;
    },
    contains(node) {
      if (node === this) return true;
      return (this.children || []).some((c) => c.contains && c.contains(node));
    },
    closest(sel) {
      let cur = this;
      while (cur) {
        if (cur.matches && cur.matches(sel)) return cur;
        cur = cur.parentNode;
      }
      return null;
    },
    matches(sel) {
      const classes = String(this.className || '').split(/\s+/).filter(Boolean);
      return String(sel).split(',').map((s) => s.trim()).some((s) => {
        if (s.startsWith('.')) return classes.includes(s.slice(1));
        if (s.startsWith('[')) {
          const m = /^\[([^=\]]+)="([^"]*)"\]$/.exec(s);
          return !!m && this.attrs[m[1]] === m[2];
        }
        return this.tagName === s.toUpperCase();
      });
    },
    querySelector(sel) { return queryIn(this, sel); },
    getBoundingClientRect() {
      return this.rect || { left: 0, right: 0, top: 0, bottom: 0, width: 0, height: 0 };
    },
    click() { for (const fn of this.handlers.click || []) fn({ stopPropagation() {}, preventDefault() {} }); },
  };
  el.classList = {
    add(name) { if (!el.className.split(/\s+/).includes(name)) el.className = (el.className + ' ' + name).trim(); },
    remove(name) { el.className = el.className.split(/\s+/).filter((c) => c && c !== name).join(' '); },
    contains(name) { return el.className.split(/\s+/).includes(name); },
    toggle(name, on) { if (on) el.classList.add(name); else el.classList.remove(name); },
  };
  // insertBefore(node, parent.firstChild) 是「插到最前」的标准写法，壳里得有这个属性，
  // 否则 before 恒为 undefined、一律追加到末尾，测试会把真实的插入位置测成假的。
  Object.defineProperty(el, 'firstChild', {
    get() { return el.children.length ? el.children[0] : null; },
    configurable: true,
  });
  Object.defineProperty(el, 'nextSibling', {
    get() {
      const sibs = (el.parentNode && el.parentNode.children) || [];
      const at = sibs.indexOf(el);
      return at >= 0 && at + 1 < sibs.length ? sibs[at + 1] : null;
    },
    configurable: true,
  });
  // textContent = '' 是模块清空重绘的手段，必须真的把子节点扔掉。
  Object.defineProperty(el, 'textContent', {
    get() { return el._text || ''; },
    set(v) { el._text = String(v); el.children = []; },
    configurable: true,
  });
  return el;
}

function walk(root, fn) {
  if (fn(root)) return root;
  for (const c of root.children || []) {
    const hit = walk(c, fn);
    if (hit) return hit;
  }
  return null;
}

function queryIn(root, sel) {
  return walk(root, (el) => el !== root && el.matches && el.matches(sel));
}

// 被测模块跑在 vm realm 里，它造的对象原型来自那个 realm，deepStrictEqual 会因此判不等。
// 比较前统一搬回本 realm，只比键值。
function plain(o) { return Object.assign({}, o); }

function findAll(root, pred, out = []) {
  if (pred(root)) out.push(root);
  for (const c of root.children || []) findAll(c, pred, out);
  return out;
}

const STYLE_STUB = {
  KEY: 'subtitleStyle',
  DEFAULTS: { fontScale: 100, lineHeight: 145, textAlign: 'center', shadow: 'soft', textColor: '', backgroundColor: '', backgroundOpacity: 72 },
  LIMITS: { fontScale: [50, 300], lineHeight: [100, 250], backgroundOpacity: [0, 100] },
  DEFAULT_TEXT_COLOR: '#f7f8f2',
  DEFAULT_BACKGROUND_COLOR: '#0c0f0d',
  normalize(v) {
    const c = Object.assign({}, this.DEFAULTS, v || {});
    for (const k of Object.keys(this.LIMITS)) {
      const [lo, hi] = this.LIMITS[k];
      c[k] = Math.min(hi, Math.max(lo, Number(c[k])));
    }
    return c;
  },
  isDefault(v) {
    const n = this.normalize(v);
    return Object.keys(this.DEFAULTS).every((k) => n[k] === this.DEFAULTS[k]);
  },
};

function load(options = {}) {
  const body = makeEl('body');
  const video = makeEl('video');
  video.rect = { left: 0, right: 1280, top: 0, bottom: 720, width: 1280, height: 720 };
  video.clientWidth = 1280;
  video.clientHeight = 720;
  video.duration = 600;

  // 站点播放器：<div class="html5-video-player"><video><div class="ytp-right-controls"><button/></div></div>
  const player = makeEl('div');
  player.className = 'html5-video-player';
  const rightControls = makeEl('div');
  rightControls.className = 'ytp-right-controls';
  const siteButton = makeEl('button');
  siteButton.className = 'ytp-settings-button';
  rightControls.appendChild(siteButton);
  player.appendChild(video);
  player.appendChild(rightControls);
  if (options.site !== 'none') body.appendChild(player);

  const sets = [];
  const removes = [];
  const sent = [];
  const shortcuts = [];
  let hideToggles = 0;
  const storageListeners = [];
  const docListeners = {};
  let timer = null;

  const windowObject = {
    fushiT: FUSHI_T,
    fushiSubtitleStyle: STYLE_STUB,
    fushiEpisodeCues: options.store || {},
    fushiVideoKey() { return 'yt:abc'; },
    fushiSubtitleShortcut(action) { shortcuts.push(action); return true; },
    fushiToggleSubtitleHiding() { hideToggles += 1; return true; },
    innerWidth: 1280,
    innerHeight: 720,
    addEventListener() {},
  };
  const documentObject = {
    body,
    fullscreenElement: null,
    documentElement: body,
    addEventListener(type, fn) { (docListeners[type] = docListeners[type] || []).push(fn); },
    createElement: makeEl,
    querySelector(sel) {
      if (sel === 'video') return options.noVideo ? null : video;
      return queryIn(body, sel);
    },
  };
  const sandbox = {
    window: windowObject,
    document: documentObject,
    location: { hostname: options.hostname || 'www.youtube.com' },
    setInterval(fn) { timer = fn; return 1; },
    clearInterval() {},
    setTimeout(fn) { fn(); return 1; },
    clearTimeout() {},
    chrome: {
      runtime: {
        getURL(p) { return 'chrome-extension://x/' + p; },
        sendMessage(m) { sent.push(m); },
      },
      storage: {
        local: {
          get(_keys, cb) { cb(options.stored || {}); },
          set(obj) { sets.push(obj); },
          remove(key) { removes.push(key); },
        },
        onChanged: { addListener(fn) { storageListeners.push(fn); } },
      },
    },
  };
  sandbox.self = sandbox;
  vm.runInNewContext(SRC, sandbox, { filename: 'player-controls.js' });

  const api = sandbox.FUSHI_PLAYER_CONTROLS;
  function button() { return walk(body, (el) => el.id === 'fushi-player-btn'); }
  function menu() { return walk(body, (el) => el.id === 'fushi-player-controls'); }
  function rowFor(id) {
    const m = menu();
    return m ? walk(m, (el) => el.dataset && el.dataset.item === id) : null;
  }
  function changed(obj) {
    const changes = {};
    for (const k of Object.keys(obj)) changes[k] = { newValue: obj[k] };
    for (const fn of storageListeners) fn(changes, 'local');
  }
  return {
    api, body, video, rightControls, sets, removes, sent, shortcuts, menu, button, rowFor, changed,
    doc: documentObject,
    hideToggles: () => hideToggles,
    tick: () => timer && timer(),
    fire(type, ev) { for (const fn of docListeners[type] || []) fn(ev); },
  };
}

// ── 纯函数 ────────────────────────────────────────────────────────────────────

test('siteOf：只认 YouTube / Netflix，其余走通用路径（不被相似域名骗到）', () => {
  assert.strictEqual(PC.siteOf('www.youtube.com'), 'youtube');
  assert.strictEqual(PC.siteOf('m.youtube.com'), 'youtube');
  assert.strictEqual(PC.siteOf('youtu.be'), 'youtube');
  assert.strictEqual(PC.siteOf('www.netflix.com'), 'netflix');
  assert.strictEqual(PC.siteOf('NETFLIX.COM'), 'netflix');
  // 后缀拼接型假域名：notyoutube.com / netflix.com.evil.example 都不是站点本身。
  assert.strictEqual(PC.siteOf('notyoutube.com'), '');
  assert.strictEqual(PC.siteOf('netflix.com.evil.example'), '');
  assert.strictEqual(PC.siteOf('example.com'), '');
  assert.strictEqual(PC.siteOf(''), '');
});

test('覆盖层总开关：与工具栏弹窗是同一份语义（交叉比对真实实现，不是抄来的期望值）', () => {
  for (const currentlyOn of [true, false]) {
    assert.deepStrictEqual(
      PC.overlayToggleWrite(currentlyOn),
      fushiOverlayToggleWrite(currentlyOn),
      '播放器菜单与工具栏弹窗必须写出完全相同的键值，否则同一个开关在两处语义分岔',
    );
  }
  // 关→开要顺带打开能力总门，否则从没开过侧边栏的用户单开覆盖层等于什么都不发生。
  assert.strictEqual(PC.overlayToggleWrite(false).netflixSubtitlePanel, true);
  // 开→关只翻自己，不把总门一起关掉（用户可能还在用侧边栏列表）。
  assert.deepStrictEqual(PC.overlayToggleWrite(true), { subtitleOverlayEnabled: false });
});

test('menuModel：总开关关掉时从属项置灰，隐藏字幕不受影响', () => {
  const on = PC.menuModel({ overlayOn: true });
  assert.deepStrictEqual(
    on.map((i) => i.id),
    ['overlay', 'replaceNative', 'allTracks', 'background', 'hidden', 'list', 'offset', 'style', 'settings'],
  );
  assert.ok(on.every((i) => !i.disabled));

  const off = PC.menuModel({ overlayOn: false });
  const byId = Object.fromEntries(off.map((i) => [i.id, i]));
  for (const id of ['replaceNative', 'allTracks', 'background']) {
    assert.strictEqual(byId[id].disabled, true, id + ' 只在覆盖层出画时有意义');
  }
  // 隐藏字幕藏的是站点原生字幕，与我们的覆盖层开关无关，任何时候都可用。
  assert.ok(!byId.hidden.disabled);
  assert.ok(!byId.overlay.disabled);
});

test('menuModel：只有「开着却什么都不画」那一种状态才给提示，其余一律不出现', () => {
  const base = { overlayOn: true, hasTrack: true, externalTrack: false, replaceNative: false, allTracks: false, hidden: false };
  const ids = (s) => PC.menuModel(s).map((i) => i.id);
  assert.ok(ids(base).includes('hint'), '站点自带轨 + 未替代 + 未全轨叠加 = 覆盖层确实不出画');
  // 任一条件不成立，提示都是错的（说了用户看不到的事）。
  assert.ok(!ids(Object.assign({}, base, { overlayOn: false })).includes('hint'));
  assert.ok(!ids(Object.assign({}, base, { hasTrack: false })).includes('hint'));
  assert.ok(!ids(Object.assign({}, base, { externalTrack: true })).includes('hint'), '外挂轨无条件出画');
  assert.ok(!ids(Object.assign({}, base, { replaceNative: true })).includes('hint'));
  assert.ok(!ids(Object.assign({}, base, { allTracks: true })).includes('hint'));
  assert.ok(!ids(Object.assign({}, base, { hidden: true })).includes('hint'), '用户主动藏了字幕就不该被劝开');
});

test('placeMenu：默认压在按钮上方右对齐；上方不够翻到下方；两边都不够仍夹在视口内', () => {
  const btn = { left: 1100, right: 1160, top: 600, bottom: 640 };
  const size = { width: 288, height: 300 };
  const view = { width: 1280, height: 720 };
  const above = PC.placeMenu(btn, size, view);
  assert.strictEqual(above.left, 1160 - 288, '右缘对齐按钮右缘');
  assert.strictEqual(above.top, 600 - 8 - 300, '底边压在按钮上方 8px');

  // 按钮贴顶：上方放不下，下方放得下 → 翻到下方。
  const high = PC.placeMenu({ left: 1100, right: 1160, top: 10, bottom: 50 }, size, view);
  assert.strictEqual(high.top, 58);

  // 视口比菜单还矮：两边都放不下，不得滑出画面。
  const tiny = PC.placeMenu({ left: 100, right: 160, top: 10, bottom: 50 }, size, { width: 320, height: 200 });
  assert.ok(tiny.top >= 8 && tiny.left >= 8);
  assert.ok(tiny.left + size.width <= 320 + 288, '左缘被夹住（窄视口下允许右侧溢出，但不许整块跑掉）');

  // 按钮贴左缘时菜单不能算出负数左边距。
  const leftEdge = PC.placeMenu({ left: 0, right: 40, top: 600, bottom: 640 }, size, view);
  assert.strictEqual(leftEdge.left, 8);
});

test('stylePatchWrite：等于默认就删键，不写一份等值对象；越界值经 normalize 夹住', () => {
  const def = PC.stylePatchWrite({ fontScale: 140 }, { fontScale: 100 }, STYLE_STUB);
  assert.strictEqual(def.remove, 'subtitleStyle');
  assert.ok(!def.set);

  const set = PC.stylePatchWrite(null, { fontScale: 140 }, STYLE_STUB);
  assert.strictEqual(set.set, 'subtitleStyle');
  assert.strictEqual(set.value.fontScale, 140);

  const clamped = PC.stylePatchWrite(null, { fontScale: 9999 }, STYLE_STUB);
  assert.strictEqual(clamped.value.fontScale, 300);
});

test('styleControls：上下限全部取自 fushiSubtitleStyle，本模块不另存一份', () => {
  const controls = PC.styleControls(STYLE_STUB);
  const byId = Object.fromEntries(controls.map((c) => [c.id, c]));
  assert.deepStrictEqual([byId.fontScale.min, byId.fontScale.max], STYLE_STUB.LIMITS.fontScale);
  assert.deepStrictEqual([byId.lineHeight.min, byId.lineHeight.max], STYLE_STUB.LIMITS.lineHeight);
  assert.deepStrictEqual([byId.backgroundOpacity.min, byId.backgroundOpacity.max], STYLE_STUB.LIMITS.backgroundOpacity);
  // 变异实测：把 LIMITS 改窄，控件必须跟着变窄（否则说明值是硬编码的）。
  const narrowed = PC.styleControls(Object.assign({}, STYLE_STUB, { LIMITS: { fontScale: [80, 120] } }));
  assert.deepStrictEqual([narrowed[0].min, narrowed[0].max], [80, 120]);
  assert.deepStrictEqual(PC.styleControls(null), []);
});

test('videoQualifies：挡掉首页悬停预览（太小）与卡片预告片（太短），直播放行', () => {
  assert.ok(PC.videoQualifies({ clientWidth: 1280, clientHeight: 720, duration: 600 }));
  assert.ok(!PC.videoQualifies({ clientWidth: 160, clientHeight: 90, duration: 600 }));
  assert.ok(!PC.videoQualifies({ clientWidth: 1280, clientHeight: 720, duration: 12 }));
  assert.ok(PC.videoQualifies({ clientWidth: 1280, clientHeight: 720, duration: NaN }), '直播/未知时长放行');
  assert.ok(!PC.videoQualifies(null));
});

// ── DOM 行为 ──────────────────────────────────────────────────────────────────

test('YouTube：按钮插在右控件组最前，不覆盖站点自己的按钮', () => {
  const t = load({ hostname: 'www.youtube.com' });
  const btn = t.button();
  assert.ok(btn, '控制栏里应该出现 Fushi 按钮');
  assert.strictEqual(btn.parentNode, t.rightControls);
  assert.strictEqual(t.rightControls.children[0], btn, '插在最前，与站点字幕按钮相邻');
  assert.strictEqual(t.rightControls.children.length, 2, '站点原有按钮一个都不能少');
  assert.ok(!btn.classList.contains('is-floating'));
});

test('通用站点：没有已知控制栏时退回浮动按钮，视频不合格则一个节点都不挂', () => {
  const t = load({ hostname: 'example.com', site: 'none' });
  const btn = t.button();
  assert.ok(btn && btn.classList.contains('is-floating'));
  assert.strictEqual(btn.parentNode, t.body);

  const none = load({ hostname: 'example.com', site: 'none', noVideo: true });
  assert.strictEqual(none.button(), null);
});

test('总开关关掉（playerControls=false）：视频页一个节点都不挂', () => {
  const t = load({ stored: { playerControls: false } });
  assert.strictEqual(t.button(), null);
  assert.strictEqual(t.menu(), null);
});

test('点按钮开菜单：菜单挂在 body 而不是控制栏里（控制栏 overflow 会把它裁掉）', () => {
  const t = load();
  t.button().click();
  const menu = t.menu();
  assert.ok(menu, '菜单应该出现');
  assert.strictEqual(menu.parentNode, t.body);
  assert.strictEqual(menu.dataset.open, '1');
  assert.strictEqual(t.button().getAttribute('aria-expanded'), 'true');
  // 再点一次关掉。
  t.button().click();
  assert.strictEqual(t.menu().dataset.open, '');
});

test('菜单里翻「Fushi 字幕」：写的键与工具栏弹窗逐字相同', () => {
  const t = load({ stored: { subtitleOverlayEnabled: true } });
  t.button().click();
  t.rowFor('overlay').click();
  assert.deepStrictEqual(plain(t.sets.pop()), fushiOverlayToggleWrite(true));

  const off = load({ stored: { subtitleOverlayEnabled: false } });
  off.button().click();
  off.rowFor('overlay').click();
  assert.deepStrictEqual(plain(off.sets.pop()), fushiOverlayToggleWrite(false));
});

test('「隐藏字幕」只转发给 content.js，绝不自己写 subtitleHidden（那份状态归它独占）', () => {
  const t = load();
  t.button().click();
  t.rowFor('hidden').click();
  assert.strictEqual(t.hideToggles(), 1);
  assert.ok(
    !t.sets.some((s) => Object.prototype.hasOwnProperty.call(s, 'subtitleHidden')),
    '两处各写一次会和 content.js 的 toast/style 注入打架',
  );
});

test('置灰的从属开关点不动（覆盖层关着时翻它没有意义）', () => {
  const t = load({ stored: { subtitleOverlayEnabled: false } });
  t.button().click();
  t.rowFor('replaceNative').click();
  assert.deepStrictEqual(t.sets, []);
});

test('时轴偏移 / 字幕列表：复用 subtitle-panel 的执行端，不另起一条链路', () => {
  const t = load();
  t.button().click();
  const seg = t.rowFor('offset');
  const buttons = findAll(seg, (el) => el.dataset && el.dataset.action);
  assert.deepStrictEqual(buttons.map((b) => b.dataset.action), ['offset-minus', 'offset-reset', 'offset-plus']);
  for (const b of buttons) b.click();
  assert.deepStrictEqual(t.shortcuts, ['offset-minus', 'offset-reset', 'offset-plus']);

  t.rowFor('list').click();
  assert.strictEqual(t.shortcuts.pop(), 'toggle-panel');
  assert.strictEqual(t.menu().dataset.open, '', '打开字幕列表后菜单让开');
});

test('「扩展设置」经 background 代开（content script 里没有 openOptionsPage）', () => {
  const t = load();
  t.button().click();
  t.rowFor('settings').click();
  assert.deepStrictEqual(plain(t.sent.pop()), { type: 'openOptions' });
});

test('字幕样式子页：改字号写 subtitleStyle；恢复默认删键', () => {
  const t = load({ stored: { subtitleStyle: { fontScale: 140 } } });
  t.button().click();
  t.rowFor('style').click();
  const menu = t.menu();
  const scale = walk(menu, (el) => el.dataset && el.dataset.field === 'fontScale');
  assert.ok(scale, '样式子页应该有字号控件');
  const input = walk(scale, (el) => el.type === 'range');
  assert.strictEqual(input.value, '140', '回显当前值');
  input.value = '160';
  for (const fn of input.handlers.input || []) fn({ stopPropagation() {} });
  assert.strictEqual(t.sets.pop().subtitleStyle.fontScale, 160);

  // 「恢复默认」删键而不是写一份等值快照。
  const reset = walk(menu, (el) => el.textContent === FUSHI_T('pc_style_reset'));
  reset.click();
  assert.strictEqual(t.removes.pop(), 'subtitleStyle');
});

test('别处改了设置（options 页 / 工具栏）：菜单与按钮跟着变，不需要刷新页面', () => {
  const t = load({ stored: { subtitleOverlayEnabled: true } });
  assert.strictEqual(t.button().dataset.on, '1');
  t.changed({ subtitleOverlayEnabled: false });
  assert.strictEqual(t.button().dataset.on, '');
  t.changed({ playerControls: false });
  assert.strictEqual(t.button(), null, '别处关掉总开关即刻卸载');
});

test('控制栏完好时反复确认不重插按钮（YouTube 的锚点就是按钮自己）', () => {
  // 回归形状：YouTube 的 anchor.before = right.firstChild，按钮插进去后它自己就是
  // firstChild，下一拍 before === btnEl。位置判据若不排除这种情况，每秒都会
  // insertBefore(btnEl, btnEl)——真 DOM 会先摘再插回：站点控制栏每秒挨一次
  // childList 变更、按钮上的焦点每秒被清掉（Tab 过去就用不了）。
  const t = load({ hostname: 'www.youtube.com' });
  const btn = t.button();
  const inserts = btn.insertCount;
  t.tick();
  t.tick();
  assert.strictEqual(btn.insertCount, inserts, '位置没变就一次都不该再插');
  assert.strictEqual(t.rightControls.children[0], btn);
  assert.strictEqual(t.rightControls.children.length, 2, '站点原有按钮一个都不能少');
});

test('通用站点全屏到 <video> 上：按钮退回 body，不塞进媒体元素（塞进去永不渲染）', () => {
  const t = load({ hostname: 'example.com', site: 'none' });
  assert.strictEqual(t.button().parentNode, t.body);
  // 很多站点直接 video.requestFullscreen()，此时 fullscreenElement 就是 <video>。
  t.doc.fullscreenElement = t.video;
  t.tick();
  const btn = t.button();
  assert.ok(btn, '全屏下按钮必须还在——这正是最需要它的时候');
  assert.notStrictEqual(btn.parentNode, t.video, '媒体元素的子节点是 fallback 内容');
  assert.strictEqual(btn.parentNode, t.body);
});

test('站点重建控制栏后按钮自己回去（YouTube SPA 导航把它连根端掉）', () => {
  const t = load();
  const btn = t.button();
  t.rightControls.removeChild(btn);
  assert.strictEqual(t.button(), null);
  t.tick();
  assert.ok(t.button(), '一秒一次的确认应该把按钮补回去');
  assert.strictEqual(t.rightControls.children[0], t.button());
});

test('按 Esc 关菜单并吞掉这一击；菜单没开时一律放行给站点', () => {
  const t = load();
  t.button().click();
  let swallowed = 0;
  t.fire('keydown', { key: 'Escape', stopPropagation() { swallowed += 1; } });
  assert.strictEqual(t.menu().dataset.open, '');
  assert.strictEqual(swallowed, 1);
  // 菜单已关：再按 Esc 不得再吞（否则站点的退全屏/关面板会平白失效）。
  t.fire('keydown', { key: 'Escape', stopPropagation() { swallowed += 1; } });
  assert.strictEqual(swallowed, 1);
});

// ── 源码守卫 ──────────────────────────────────────────────────────────────────

test('manifest：player-controls.js 排在 content.js / subtitle-panel.js 之后（它消费两者的全局）', () => {
  const js = MANIFEST.content_scripts[0].js;
  assert.ok(js.includes('player-controls.js'));
  assert.ok(js.indexOf('player-controls.js') > js.indexOf('content.js'));
  assert.ok(js.indexOf('player-controls.js') > js.indexOf('subtitle-panel.js'));
  assert.ok(js.indexOf('player-controls.js') > js.indexOf('subtitle-style.js'));
  // 按钮图标是从宿主页加载的扩展资源，必须可访问，否则真站点上按钮是个破图。
  const war = MANIFEST.web_accessible_resources.flatMap((e) => e.resources);
  assert.ok(war.includes('icon-32.png'));
});

test('两个页内宿主进了主题 token 清单与生成的 content.css（否则菜单在宿主页上没有颜色）', () => {
  const theme = fs.readFileSync(path.join(__dirname, 'theme.js'), 'utf8');
  const gen = fs.readFileSync(path.join(__dirname, 'scripts', 'generate-content-css.mjs'), 'utf8');
  const css = fs.readFileSync(path.join(__dirname, 'vendor', 'content.css'), 'utf8');
  for (const id of ['#fushi-player-btn', '#fushi-player-controls']) {
    assert.ok(theme.includes(id), 'theme.js IN_PAGE_HOSTS 缺 ' + id);
    assert.ok(gen.includes(id), 'generate-content-css.mjs 的清单缺 ' + id);
    assert.ok(css.includes(id), 'content.css 未重新生成？缺 ' + id);
  }
});

test('本模块不自己定义字幕外观的默认值或上下限（真源只有 subtitle-style.js）', () => {
  const body = SRC.replace(/\/\/[^\n]*/g, ''); // 注释里出现这些词不算
  for (const forbidden of ['fontScale: 100', 'lineHeight: 145', 'backgroundOpacity: 72', "shadow: 'soft'"]) {
    assert.ok(!body.includes(forbidden), '外观默认值不得在 player-controls.js 里复制一份：' + forbidden);
  }
});
