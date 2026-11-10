// 字幕遮布（subtitle-mask.js）：几何纯函数（内容区含 letterbox、比例↔像素、夹取、编辑手势）、
// 设置读写，以及视频页运行时在假 DOM 里的摆放 / 编辑落盘 / 入口契约。
const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const M = require('./subtitle-mask.js');

const near = (a, b, eps = 1e-6) => assert.ok(Math.abs(a - b) <= eps, `${a} ≉ ${b}`);
function nearRect(a, b, eps = 1e-6) {
  for (const k of ['left', 'top', 'width', 'height']) near(a[k], b[k], eps);
}

// ── 设置 ──

test('normalize：缺省 = 底部居中默认值；坏值逐项回落、矩形四项任一坏就整块回默认', () => {
  assert.deepStrictEqual(M.normalize(null), Object.assign({}, M.DEFAULTS));
  assert.deepStrictEqual(M.DEFAULTS, {
    enabled: false, appearance: 'blur', blur: 16, opacity: 90, left: 0.15, top: 0.82, width: 0.7, height: 0.12,
  });
  const bad = M.normalize({ enabled: 'yes', appearance: 'neon', blur: 'x', opacity: NaN, left: 0.3, top: null, width: 0.2, height: 0.1 });
  assert.strictEqual(bad.enabled, false, '只有显式 true 才算开');
  assert.strictEqual(bad.appearance, 'blur');
  assert.strictEqual(bad.blur, M.DEFAULTS.blur);
  assert.strictEqual(bad.opacity, M.DEFAULTS.opacity);
  nearRect(bad, M.DEFAULTS, 0);
  // 强度夹到滑杆上下限，取整。
  const big = M.normalize({ appearance: 'solid', blur: 999, opacity: 3.6 });
  assert.strictEqual(big.appearance, 'solid');
  assert.strictEqual(big.blur, M.LIMITS.blur[1]);
  assert.strictEqual(big.opacity, M.LIMITS.opacity[0]);
});

test('clampRect：宽高夹到 [最小, 1]，左上角夹到整块仍在画面里；比例存 4 位小数', () => {
  nearRect(M.clampRect({ left: 0.9, top: 0.95, width: 0.5, height: 0.2 }), { left: 0.5, top: 0.8, width: 0.5, height: 0.2 });
  nearRect(M.clampRect({ left: -1, top: -1, width: 3, height: 3 }), { left: 0, top: 0, width: 1, height: 1 });
  const tiny = M.clampRect({ left: 0.5, top: 0.5, width: 0, height: -1 });
  assert.strictEqual(tiny.width, M.MIN_WIDTH);
  assert.strictEqual(tiny.height, M.MIN_HEIGHT);
  assert.strictEqual(M.clampRect({ left: 0.1 + 0.05, top: 0.1, width: 0.2, height: 0.1 }).left, 0.15);
});

test('writeOf：整份等于默认就删键，否则写规整后的整份；resetRect 只动矩形', () => {
  assert.deepStrictEqual(M.writeOf(null), { remove: 'subtitleMask', value: M.normalize(null) });
  const on = M.writeOf({ enabled: true });
  assert.strictEqual(on.set, 'subtitleMask');
  assert.strictEqual(on.value.enabled, true);
  const moved = { enabled: true, appearance: 'solid', opacity: 50, left: 0, top: 0, width: 0.3, height: 0.3 };
  const reset = M.resetRect(moved);
  assert.strictEqual(reset.enabled, true);
  assert.strictEqual(reset.appearance, 'solid');
  assert.strictEqual(reset.opacity, 50);
  nearRect(reset, M.DEFAULTS, 0);
  assert.ok(M.isDefault(M.resetRect({ left: 0.4 })), '只改过位置的设置重置后回到默认 → 删键');
});

// ── 几何 ──

test('contentRect：contain 的 letterbox / pillarbox 不算画面', () => {
  // 4:3 片源放进 16:9 盒子：左右各 160px 黑边。
  nearRect(M.contentRect({ left: 0, top: 0, width: 1280, height: 720 }, { width: 1440, height: 1080 }, 'contain'),
    { left: 160, top: 0, width: 960, height: 720 });
  // 2.39:1 宽银幕放进 16:9 盒子：上下黑边。
  const c = M.contentRect({ left: 10, top: 20, width: 1600, height: 900 }, { width: 1920, height: 804 }, '');
  near(c.width, 1600);
  near(c.height, 1600 * 804 / 1920);
  near(c.top, 20 + (900 - c.height) / 2);
  near(c.left, 10);
});

test('contentRect：fill / cover / none / scale-down / object-position；固有尺寸未知回落整盒', () => {
  const box = { left: 0, top: 0, width: 800, height: 600 };
  nearRect(M.contentRect(box, { width: 1920, height: 1080 }, 'fill'), box);
  // cover：16:9 放进 4:3，按高撑满，左右探出盒子。
  const cover = M.contentRect(box, { width: 1920, height: 1080 }, 'cover');
  near(cover.height, 600);
  near(cover.width, 600 * 16 / 9);
  near(cover.left, (800 - cover.width) / 2);
  nearRect(M.contentRect(box, { width: 400, height: 300 }, 'none'), { left: 200, top: 150, width: 400, height: 300 });
  nearRect(M.contentRect(box, { width: 400, height: 300 }, 'scale-down'), { left: 200, top: 150, width: 400, height: 300 });
  nearRect(M.contentRect(box, { width: 1600, height: 900 }, 'scale-down'), M.contentRect(box, { width: 1600, height: 900 }, 'contain'));
  // object-position：左上贴边。
  nearRect(M.contentRect(box, { width: 1600, height: 900 }, 'contain', 'left top'), { left: 0, top: 0, width: 800, height: 450 });
  nearRect(M.contentRect(box, { width: 1600, height: 900 }, 'contain', 'top right'), { left: 0, top: 0, width: 800, height: 450 });
  nearRect(M.contentRect(box, { width: 1600, height: 900 }, 'contain', '50% 100%'), { left: 0, top: 150, width: 800, height: 450 });
  nearRect(M.contentRect(box, { width: 0, height: 0 }, 'contain'), box);
  nearRect(M.contentRect(box, null), box);
});

test('toPixels ↔ fromPixels 互逆；窗口 / 全屏改变后同一比例落在画面同一相对位置', () => {
  const rect = { left: 0.15, top: 0.82, width: 0.7, height: 0.12 };
  const small = M.contentRect({ left: 0, top: 0, width: 1280, height: 720 }, { width: 1440, height: 1080 });
  const px = M.toPixels(rect, small);
  nearRect(px, { left: 160 + 0.15 * 960, top: 0.82 * 720, width: 0.7 * 960, height: 0.12 * 720 });
  nearRect(M.fromPixels(px, small), rect);
  // 进全屏（1920×1080 屏）后同一份比例：仍是画面内容区（不含黑边）的同一处。
  const full = M.contentRect({ left: 0, top: 0, width: 1920, height: 1080 }, { width: 1440, height: 1080 });
  const fpx = M.toPixels(rect, full);
  near((fpx.left - full.left) / full.width, 0.15);
  near((fpx.top - full.top) / full.height, 0.82);
  assert.ok(fpx.left >= full.left && fpx.left + fpx.width <= full.left + full.width, '不压进左右黑边');
  // 越界像素夹回画面。
  nearRect(M.fromPixels({ left: -100, top: 700, width: 5000, height: 100 }, small), { left: 0, top: 1 - 100 / 720, width: 1, height: 100 / 720 }, 1e-4);
  assert.strictEqual(M.fromPixels({ left: 0, top: 0, width: 1, height: 1 }, { left: 0, top: 0, width: 0, height: 10 }), null);
});

test('clipTo：cover 时探出视频盒的那截不画', () => {
  nearRect(M.clipTo({ left: -50, top: 10, width: 200, height: 50 }, { left: 0, top: 0, width: 100, height: 40 }),
    { left: 0, top: 10, width: 100, height: 30 });
  assert.strictEqual(M.clipTo({ left: 200, top: 0, width: 10, height: 10 }, { left: 0, top: 0, width: 100, height: 100 }).width, 0);
});

test('applyDrag：整块平移撞边即停；四边四角缩放对边钉住、不小于最小值、不出画面', () => {
  const s = { left: 0.2, top: 0.6, width: 0.5, height: 0.2 };
  nearRect(M.applyDrag(s, 'move', 0.1, -0.1), { left: 0.3, top: 0.5, width: 0.5, height: 0.2 });
  nearRect(M.applyDrag(s, 'move', 9, 9), { left: 0.5, top: 0.8, width: 0.5, height: 0.2 });
  nearRect(M.applyDrag(s, 'e', 0.1, 0.5), { left: 0.2, top: 0.6, width: 0.6, height: 0.2 });
  nearRect(M.applyDrag(s, 'w', -0.1, 0), { left: 0.1, top: 0.6, width: 0.6, height: 0.2 });
  nearRect(M.applyDrag(s, 'n', 0, -0.2), { left: 0.2, top: 0.4, width: 0.5, height: 0.4 });
  nearRect(M.applyDrag(s, 'se', 1, 1), { left: 0.2, top: 0.6, width: 0.8, height: 0.4 });
  nearRect(M.applyDrag(s, 'nw', -1, -1), { left: 0, top: 0, width: 0.7, height: 0.8 });
  // 缩到比最小还小：停在最小值，对边不动。
  const min = M.applyDrag(s, 'w', 0.9, 0);
  near(min.width, M.MIN_WIDTH);
  near(min.left + min.width, 0.7);
  const minH = M.applyDrag(s, 's', 0, -0.9);
  near(minH.height, M.MIN_HEIGHT);
  near(minH.top, 0.6);
  nearRect(M.applyDrag(s, 'move', NaN, undefined), s);
});

test('videoQualifies / barPlacement', () => {
  assert.ok(M.videoQualifies({ width: 640, height: 360 }));
  assert.ok(!M.videoQualifies({ width: 180, height: 100 }), '悬停预览不铺遮布');
  assert.strictEqual(M.barPlacement({ top: 300, height: 50 }, 720, 40), 'above');
  assert.strictEqual(M.barPlacement({ top: 10, height: 50 }, 720, 40), 'below');
  assert.strictEqual(M.barPlacement({ top: 10, height: 700 }, 720, 40), 'inside');
});

// ── 运行时（假 DOM） ──

function fakeEl(tag) {
  const attrs = {};
  const props = {};
  const listeners = {};
  const el = {
    tagName: String(tag).toUpperCase(), id: '', className: '', textContent: '', type: '',
    parentNode: null, children: [], offsetHeight: 40,
    attrs, props, listeners,
    style: {
      setProperty(k, v) { props[k] = v; },
      getPropertyValue(k) { return props[k] || ''; },
      removeProperty(k) { delete props[k]; },
    },
    setAttribute(k, v) { attrs[k] = String(v); },
    getAttribute(k) { return Object.prototype.hasOwnProperty.call(attrs, k) ? attrs[k] : null; },
    removeAttribute(k) { delete attrs[k]; },
    hasAttribute(k) { return Object.prototype.hasOwnProperty.call(attrs, k); },
    appendChild(c) {
      if (c.parentNode) c.parentNode.removeChild(c);
      c.parentNode = el; el.children.push(c); return c;
    },
    removeChild(c) { el.children = el.children.filter((x) => x !== c); c.parentNode = null; return c; },
    addEventListener(t, f) { (listeners[t] = listeners[t] || []).push(f); },
    removeEventListener(t, f) { listeners[t] = (listeners[t] || []).filter((x) => x !== f); },
    setPointerCapture() {},
  };
  return el;
}

function fire(target, type, ev) {
  for (const f of (target.listeners[type] || []).slice()) f(ev);
}

function createRuntime(stored = {}) {
  const src = fs.readFileSync(path.join(__dirname, 'subtitle-mask.js'), 'utf8');
  const html = fakeEl('html');
  const video = Object.assign(fakeEl('video'), {
    videoWidth: 1440, videoHeight: 1080, offsetWidth: 1280, offsetHeight: 720,
    getBoundingClientRect: () => ({ left: 0, top: 0, width: 1280, height: 720, right: 1280, bottom: 720 }),
  });
  const placed = [];
  const store = Object.assign({}, stored);
  const writes = [];
  const toasts = [];
  let changed = null;
  const winListeners = {};
  const docListeners = {};
  const win = {
    innerWidth: 1280, innerHeight: 720,
    fushiMainVideo: () => video,
    fushiVideoAnchor: {
      host: () => html,
      placeAt(el, x, y) {
        if (el.parentNode !== html) html.appendChild(el);
        placed.push({ x, y });
        el.style.setProperty('left', x + 'px');
        el.style.setProperty('top', y + 'px');
        return { origin: { x: 0, y: 0, sx: 1, sy: 1 }, mode: 'fixed' };
      },
      watch: () => () => {},
    },
    getComputedStyle: () => ({ objectFit: 'contain', objectPosition: '50% 50%' }),
    fushiToast: (t) => toasts.push(t),
    fushiT: (k) => k,
    addEventListener(t, f) { (winListeners[t] = winListeners[t] || []).push(f); },
    removeEventListener(t, f) { winListeners[t] = (winListeners[t] || []).filter((x) => x !== f); },
  };
  const doc = {
    documentElement: html, fullscreenElement: null,
    createElement: fakeEl,
    querySelector: (s) => (s === 'video' ? video : null),
    addEventListener(t, f) { (docListeners[t] = docListeners[t] || []).push(f); },
  };
  const chrome = {
    storage: {
      local: {
        get(key, cb) { const o = {}; o[key] = store[key]; cb(o); },
        set(patch) {
          writes.push({ set: patch });
          const changes = {};
          for (const k in patch) { changes[k] = { newValue: patch[k] }; store[k] = patch[k]; }
          if (changed) changed(changes, 'local');
        },
        remove(key) {
          writes.push({ remove: key });
          delete store[key];
          if (changed) changed({ [key]: { newValue: undefined } }, 'local');
        },
      },
      onChanged: { addListener(f) { changed = f; } },
    },
  };
  win.window = win;
  win.self = win;
  const context = Object.assign(win, {
    document: doc, chrome, location: { protocol: 'https:' },
    setInterval: () => 0, requestAnimationFrame: () => 0, console,
  });
  vm.createContext(context);
  vm.runInContext(src, context);
  const el = () => html.children.find((c) => c.id === 'fushi-subtitle-mask') || null;
  return {
    win, html, video, placed, store, writes, toasts, el,
    pointer(type, target, x, y) {
      const ev = { type, target, pointerId: 1, button: 0, clientX: x, clientY: y, stopPropagation() {}, preventDefault() {} };
      if (type === 'pointerdown') fire(target === el() ? target : el(), 'pointerdown', ev);
      else for (const f of (winListeners[type] || []).slice()) f(ev);
    },
    key(k) {
      const ev = { key: k, stopPropagation() {}, preventDefault() {} };
      for (const f of (winListeners.keydown || []).slice()) f(ev);
    },
    fullscreen() { for (const f of docListeners.fullscreenchange || []) f(); },
  };
}

test('运行时：默认关着不挂节点；开了按画面内容区（扣 pillarbox）摆放并写像素宽高', () => {
  const off = createRuntime();
  assert.strictEqual(off.el(), null);
  const rt = createRuntime({ subtitleMask: { enabled: true } });
  const el = rt.el();
  assert.ok(el, '开着且有正片 → 挂进视频锚定的挂载点');
  // 4:3 片源在 1280×720 盒里：内容区 x∈[160,1120]。默认矩形 0.15/0.82/0.7/0.12。
  const last = rt.placed[rt.placed.length - 1];
  near(last.x, 160 + 0.15 * 960);
  near(last.y, 0.82 * 720);
  assert.strictEqual(el.props.width, 0.7 * 960 + 'px');
  near(parseFloat(el.props.height), 0.12 * 720);
  assert.strictEqual(el.attrs['data-appearance'], 'blur');
  assert.strictEqual(el.props['--fushi-mask-blur'], '16px');
  assert.ok(!('data-editing' in el.attrs), '平时不在编辑态（CSS 据此 pointer-events:none）');
});

test('运行时：换清晰度（固有尺寸变）经 <video> resize 事件重摆', () => {
  const rt = createRuntime({ subtitleMask: { enabled: true } });
  rt.video.videoWidth = 1920;
  rt.video.videoHeight = 1080;
  fire(rt.video, 'resize', {});
  const last = rt.placed[rt.placed.length - 1];
  near(last.x, 0.15 * 1280, 1e-6);
  assert.strictEqual(rt.el().props.width, 0.7 * 1280 + 'px');
});

test('运行时：编辑模式拖动整块 / 拖角缩放，松手才落盘；重置只回矩形；完成退出编辑', () => {
  const rt = createRuntime({ subtitleMask: { enabled: true } });
  const api = rt.win.fushiSubtitleMask;
  assert.strictEqual(api.edit(), true);
  const el = rt.el();
  assert.ok('data-editing' in el.attrs);
  const before = rt.writes.length;
  rt.pointer('pointerdown', el, 500, 600);
  rt.pointer('pointermove', el, 596, 600); // +96px = 画面宽 960 的 0.1
  assert.strictEqual(rt.writes.length, before, '拖动中不写盘');
  near(rt.placed[rt.placed.length - 1].x, 160 + 0.25 * 960);
  rt.pointer('pointerup', el, 596, 600);
  assert.strictEqual(rt.writes.length, before + 1);
  near(rt.store.subtitleMask.left, 0.25);
  near(rt.store.subtitleMask.width, 0.7);

  const se = el.children.find((c) => c.getAttribute && c.getAttribute('data-dir') === 'se');
  rt.pointer('pointerdown', se, 900, 680);
  rt.pointer('pointermove', se, 900, 716); // +36px = 画面高 720 的 0.05
  rt.pointer('pointerup', se, 900, 716);
  near(rt.store.subtitleMask.height, 0.17);
  near(rt.store.subtitleMask.top, 0.82, 1e-4);

  // 指针取消：丢弃，不落盘。
  const n = rt.writes.length;
  rt.pointer('pointerdown', el, 500, 600);
  rt.pointer('pointermove', el, 100, 100);
  rt.pointer('pointercancel', el, 100, 100);
  assert.strictEqual(rt.writes.length, n);

  api.reset();
  const s = rt.store.subtitleMask;
  assert.strictEqual(s.enabled, true, '重置位置不关遮布');
  nearRect(s, M.DEFAULTS, 0);
  rt.key('Escape');
  assert.ok(!('data-editing' in rt.el().attrs), 'Esc = 完成');
  assert.strictEqual(api.state().editing, false);
});

test('运行时：关着时「调整遮布」先打开再编辑；快捷键切换走 toggle 并提示；全屏切换打断手势不落盘', () => {
  const rt = createRuntime();
  const api = rt.win.fushiSubtitleMask;
  api.edit();
  assert.strictEqual(rt.store.subtitleMask.enabled, true);
  rt.pointer('pointerdown', rt.el(), 500, 600);
  rt.pointer('pointermove', rt.el(), 700, 300);
  const n = rt.writes.length;
  rt.fullscreen();
  rt.pointer('pointerup', rt.el(), 700, 300);
  assert.strictEqual(rt.writes.length, n, '全屏切换丢弃旧坐标系里的手势');
  api.finishEdit();
  assert.strictEqual(api.toggle(), true);
  assert.strictEqual(api.state().enabled, false);
  assert.strictEqual(rt.el(), null, '关掉即摘节点');
  assert.deepStrictEqual(rt.toasts, ['mask_toast_off']);
  // 回到默认整份 → 删键（不留等值快照）。
  assert.deepStrictEqual(rt.writes[rt.writes.length - 1], { remove: 'subtitleMask' });
});

// ── 装配守卫 ──

test('装配：manifest 在 subtitle-panel.js 之后装；页内宿主清单两处同步；设置页先装纯函数再装 options.js', () => {
  const manifest = JSON.parse(fs.readFileSync(path.join(__dirname, 'manifest.json'), 'utf8'));
  const js = manifest.content_scripts[0].js;
  assert.ok(js.indexOf('subtitle-mask.js') > js.indexOf('subtitle-panel.js'));
  assert.ok(js.indexOf('subtitle-mask.js') > js.indexOf('video-target.js'));
  assert.match(fs.readFileSync(path.join(__dirname, 'theme.js'), 'utf8'), /'fushi-subtitle-mask'/);
  assert.match(fs.readFileSync(path.join(__dirname, 'scripts/generate-content-css.mjs'), 'utf8'), /#fushi-subtitle-mask/);
  const html = fs.readFileSync(path.join(__dirname, 'options.html'), 'utf8');
  assert.ok(/<script src="subtitle-mask\.js"><\/script>[\s\S]*<script src="options\.js"><\/script>/.test(html));
  for (const id of ['subtitleMaskEnabled', 'subtitleMaskAppearance', 'subtitleMaskStrength', 'resetSubtitleMaskPosition']) {
    assert.ok(html.includes('id="' + id + '"'), id);
  }
});

test('CSS：遮布在字幕覆盖层之下、平时不拦指针；模糊只在 backdrop-filter @supports 段里', () => {
  const css = fs.readFileSync(path.join(__dirname, 'vendor/content.css'), 'utf8');
  const z = (sel) => Number(new RegExp(sel.replace(/[[\]]/g, '\\$&') + '\\s*\\{[^}]*?z-index:\\s*(\\d+)').exec(css)[1]);
  const overlay = z('#fushi-subtitle-overlay');
  const mask = z('#fushi-subtitle-mask');
  assert.ok(mask < overlay, `遮布 z-index ${mask} 必须低于字幕覆盖层 ${overlay}`);
  assert.ok(z('#fushi-subtitle-mask[data-editing]') > overlay, '编辑时把手不被字幕挡住');
  assert.match(/#fushi-subtitle-mask\s*\{[^}]*\}/.exec(css)[0], /pointer-events:\s*none/);
  const supports = css.indexOf('@supports ((backdrop-filter: blur(1px)) or (-webkit-backdrop-filter: blur(1px)))');
  const blurRule = css.indexOf('#fushi-subtitle-mask[data-appearance="blur"]');
  assert.ok(supports >= 0 && blurRule > supports, '模糊规则在玻璃 @supports 段内');
  assert.match(css, /backdrop-filter:\s*blur\(var\(--fushi-mask-blur/);
});

test('入口：播放器菜单有开关与「调整遮布」；快捷键动作有默认键与设置项；文案中文齐全', () => {
  const PC = require('./player-controls.js');
  const items = PC.menuModel({ overlayOn: false, maskOn: true });
  const mask = items.find((i) => i.id === 'mask');
  assert.strictEqual(mask.on, true);
  assert.ok(!mask.disabled, '遮布与 Fushi 字幕覆盖层无关，不随总开关置灰');
  assert.ok(items.find((i) => i.id === 'maskEdit'));
  const VS = require('./video-shortcuts.js');
  assert.strictEqual(VS.DEFAULT_COMBOS['toggle-subtitle-mask'], 'Shift+KeyB');
  assert.deepStrictEqual(VS.decide({ code: 'KeyB', key: 'B', shift: true }, { enabled: true, hasVideo: true, hasTrack: false }),
    { action: 'toggle-subtitle-mask' }, '不需要字幕轨');
  const opts = fs.readFileSync(path.join(__dirname, 'options.js'), 'utf8');
  assert.match(opts, /videoShortcutToggleSubtitleMask: true,/);
  const zh = JSON.parse(fs.readFileSync(path.join(__dirname, 'locales/zh-CN.json'), 'utf8'));
  assert.strictEqual(zh.opt_subtitleMask_title, '字幕遮布');
  assert.strictEqual(zh.pc_mask_edit, '调整字幕遮布');
  assert.strictEqual(zh.mask_edit_done, '完成');
});
