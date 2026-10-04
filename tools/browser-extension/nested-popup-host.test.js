const { test } = require('node:test');
const assert = require('node:assert/strict');
const FUSHI_T = require('./scripts/i18n-fixture.js').makeFushiT(); // 文案走 i18n：壳里装 zh-CN 字典
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const source = fs.readFileSync(path.join(__dirname, 'nested-popup-host.js'), 'utf8');
const origin = 'chrome-extension://test-extension';
const flush = () => new Promise(resolve => setImmediate(resolve));

function harness(handler = () => null) {
  const frames = [], lookups = [], listeners = {}, calls = [];
  class MockMessageChannel {
    constructor() {
      const makePort = () => ({
        closed: false, onmessage: null, start() {},
        close() { this.closed = true; },
        postMessage(data) {
          if (!this.closed && !this.peer.closed) this.peer.onmessage?.({ data });
        },
      });
      this.port1 = makePort(); this.port2 = makePort();
      this.port1.peer = this.port2; this.port2.peer = this.port1;
    }
  }
  let focusCount = 0, renderCount = 0, resumeCount = 0;
  const root = {
    scrollTop: 312, innerHTML: 'unchanged parent dictionary',
    getBoundingClientRect: () => ({ left: 40, top: 60 }),
    focus: () => focusCount++,
  };
  const window = {
    fushiT: FUSHI_T,
    innerWidth: 1280, innerHeight: 900,
    CSS: { supports: () => true },
    addEventListener: (name, callback) => { listeners[name] = callback; },
    fushiIsEntryQueued: () => false,
    renderPopup: () => renderCount++,
    flutter_inappwebview: {
      callHandler: (name, ...args) => { calls.push({ name, args }); return handler(name, ...args); },
    },
  };
  // 可控计时器：子层「尾批在途先不显示、最多等 REVEAL_WAIT_MS」的兜底显示。
  const timers = [];
  const setTimeoutFake = (fn, ms) => { const t = { fn, ms, cleared: false }; timers.push(t); return t; };
  const clearTimeoutFake = t => { if (t) t.cleared = true; };
  const runTimers = () => { for (const t of timers.splice(0)) if (!t.cleared) t.fn(); };
  const context = vm.createContext({
    setTimeout: setTimeoutFake, clearTimeout: clearTimeoutFake,
    window, URL, Promise, console, MessageChannel: MockMessageChannel,
    chrome: { runtime: {
      id: 'test-extension',
      getURL: file => origin + '/' + file,
      sendMessage: (message, callback) => lookups.push({ message, callback }),
    } },
    document: {
      createElement: tag => {
        if (tag === 'div') {
          // 外框：定位 / 玻璃 / 显隐都在这一层，iframe 是它唯一的孩子。
          return {
            style: {}, attrs: {}, child: null, removed: false,
            setAttribute(k, v) { this.attrs[k] = v; },
            appendChild(child) { this.child = child; child.box = this; },
            remove() { this.removed = true; if (this.child) this.child.removed = true; },
            getBoundingClientRect: () => ({ left: 100, top: 120 }),
          };
        }
        assert.equal(tag, 'iframe');
        const frame = {
          style: {}, messages: [], windowMessages: [], removed: false,
          attrs: {}, setAttribute(k, v) { this.attrs[k] = v; },
          remove() { this.removed = true; },
          focus() { focusCount++; },
          getBoundingClientRect: () => ({ left: 100, top: 120 }),
        };
        frame.contentWindow = { postMessage: (message, targetOrigin, ports) => {
          assert.equal(targetOrigin, origin, 'use the actual extension origin');
          frame.windowMessages.push(message);
          assert.equal(message.type, 'connect', 'public channel transfers only the port');
          assert.equal(ports.length, 1);
          frame.port = ports[0];
          frame.port.onmessage = event => frame.messages.push(event.data);
        } };
        return frame;
      },
      body: { appendChild: box => { assert.ok(box.child, 'body 下挂的是外框，iframe 在框内'); frames.push(box.child); } },
    },
    fushiHost: root,
    fushiPendingCueWindow: { cue: 'root sentence' },
    fushiSentenceCtx: { prev: 2, next: 1 },
    FUSHI_CTX_I18N: {},
    fushiResolvePopupBox: () => ({ width: 500, maxHeight: 500, zoom: 1 }),
    fushiComputePlacement: () => ({ left: 100, top: 120, maxHeight: 500 }),
    fushiCurrentCueLocation: () => ({ index: 0 }),
    fushiShowConnectionFailure() {},
    fushiResumeVideo: () => resumeCount++,
  });
  vm.runInContext(source, context, { filename: 'nested-popup-host.js' });
  const replyLookup = (index, expression = '子', ready = true) => {
    const before = frames.length;
    lookups[index].callback({
      ok: true, data: { popupJson: JSON.stringify([{ expression }]), theme: {} },
    });
    if (ready && frames.length > before) event(frames.at(-1), { type: 'ready' });
  };
  const event = (frame, message, overrides = {}) => listeners.message({
    data: { __fushiPopupFrame: true, ...message },
    source: frame.contentWindow, origin, ...overrides,
  });
  const portEvent = (frame, message) => frame.port.postMessage({ __fushiPopupFrame: true, ...message });
  const call = (frame, name, args = [], id = 1) => portEvent(frame, { type: 'call', name, args, id });
  const live = () => frames.filter(frame => !frame.removed);
  return { context, root, window, frames, lookups, calls, live, event, portEvent, call, replyLookup, runTimers, timers,
    api: window.fushiNestedPopups,
    counts: () => ({ focusCount, renderCount, resumeCount }) };
}

test('nested lookup preserves parent DOM, scroll and pause, revealing child only when rendered', () => {
  const h = harness();
  h.api.open('子', { x: 80, y: 100 });
  assert.equal(h.live().length, 0);
  h.replyLookup(0);
  const child = h.frames[0];
  assert.equal(h.root.innerHTML, 'unchanged parent dictionary');
  assert.equal(h.root.scrollTop, 312);
  assert.equal(h.counts().renderCount, 0);
  assert.match(child.box.style.cssText, /visibility:hidden/);
  h.event(child, { type: 'ready' });
  assert.equal(child.messages.filter(message => message.type === 'render').length, 1);
  h.call(child, 'popupRendered', [240]);
  assert.equal(child.box.style.visibility, 'visible');
  assert.equal(h.counts().resumeCount, 0);
});

test('two children keep ancestry; parent tapOutside removes only descendants', () => {
  const h = harness();
  h.api.open('子'); h.replyLookup(0);
  const child = h.frames[0];
  h.call(child, 'textSelected', ['孫', { x: 10, y: 20 }]); h.replyLookup(1);
  assert.equal(h.live().length, 2);
  assert.equal(h.window.__hasChildPopup, true);
  assert.equal(child.messages.filter(message => message.type === 'hasChild').at(-1).value, true);
  h.call(child, 'tapOutside');
  assert.deepEqual(h.live(), [child]);
  assert.equal(child.messages.filter(message => message.type === 'hasChild').at(-1).value, false);
  h.call(child, 'tapOutside');
  assert.deepEqual(h.live(), [child]);
  assert.equal(h.counts().resumeCount, 0);
});

test('Escape pop and explicit child close return one level without resuming the video', () => {
  const h = harness();
  h.api.open('子'); h.replyLookup(0);
  h.call(h.frames[0], 'onLinkClick', ['孫']); h.replyLookup(1);
  assert.equal(h.api.pop(), true);
  assert.deepEqual(h.live(), [h.frames[0]]);
  h.portEvent(h.frames[0], { type: 'close' });
  assert.equal(h.live().length, 0);
  assert.equal(h.window.__hasChildPopup, false);
  assert.equal(h.api.pop(), false);
  assert.equal(h.counts().focusCount, 2);
  assert.equal(h.counts().resumeCount, 0);
});

test('root dismissal cancels pending lookup and cannot recreate a closed popup', () => {
  const h = harness();
  h.api.open('子');
  h.api.clear();
  h.context.fushiHost = null;
  h.replyLookup(0);
  assert.equal(h.frames.length, 0);
});

test('latest concurrent lookup wins, including new lookup from an ancestor', () => {
  const h = harness();
  h.api.open('古い'); h.api.open('新しい');
  h.replyLookup(1, '新しい'); h.replyLookup(0, '古い');
  assert.equal(h.frames.length, 1);
  assert.match(h.frames[0].title, /新しい/);
  h.call(h.frames[0], 'textSelected', ['子']);
  h.api.open('別の親の子');
  h.replyLookup(2); h.replyLookup(3);
  assert.equal(h.live().length, 1);
  assert.match(h.live()[0].title, /別の親の子/);
});

test('frame bridge checks both origin and exact live frame source', () => {
  const h = harness();
  h.api.open('子'); h.replyLookup(0, '子', false);
  const child = h.frames[0], before = child.messages.length;
  h.event(child, { type: 'ready' }, { origin: 'https://hostile.example' });
  h.event(child, { type: 'ready' }, { source: {} });
  assert.equal(child.messages.length, before);
  assert.equal(child.port, undefined);
  h.event(child, { type: 'ready' });
  h.event(child, { type: 'call', name: 'mineEntry', args: [{ expression: 'forged' }], id: 99 });
  h.event(child, { type: 'close' });
  assert.equal(h.live().length, 1, 'public close must not dismiss a layer');
  assert.equal(h.calls.length, 0, 'public calls cannot execute mining');
  h.call(child, 'unregisteredBridge', ['ignored']);
  assert.equal(h.calls.length, 0);
  const connectedCount = child.messages.length;
  h.api.clear();
  assert.equal(child.port.peer.closed, true, 'retired host port is closed');
  h.event(child, { type: 'ready' });
  h.call(child, 'mineEntry', [{ expression: 'retired' }]);
  assert.equal(h.calls.length, 0);
  assert.equal(child.messages.length, connectedCount);
});

test('asynchronous bridge replies are not delivered to a closed frame or its replacement', async () => {
  let resolve;
  const h = harness(() => new Promise(done => { resolve = done; }));
  h.api.open('子'); h.replyLookup(0);
  const child = h.frames[0];
  h.call(child, 'mineEntry', [{ expression: '子' }], 42);
  assert.equal(h.calls.length, 1);
  h.api.clear();
  h.api.open('次'); h.replyLookup(1);
  resolve({ queued: true });
  await flush();
  for (const frame of h.frames) {
    assert.equal(frame.messages.some(message => message.type === 'reply' && message.id === 42), false);
  }
  assert.equal(h.counts().resumeCount, 0);
});

// 2026-10-04 录屏：子层首发 popupRendered 只有首词条高度 → 判词下方放得下、先在底部冒一小条，
// 尾批建完终高一到又整块跳到词上方。尾批在途时按 theme 上限选边、显示即锁边。
test('nested layer picks its side by the final height and locks it once revealed', () => {
  const h = harness();
  const plans = [];
  // 词下方只放得下 300px：矮于 300 落下方，否则落上方。
  h.context.fushiComputePlacement = (anchor, size, viewport, side) => {
    plans.push({ height: size.height, side: side || null });
    const s = side || (size.height <= 300 ? 'below' : 'above');
    return { left: 10, top: s === 'below' ? 600 : 100, maxHeight: null, side: s };
  };
  h.api.open('子', { x: 80, y: 560 }); h.replyLookup(0);
  const child = h.frames[0];
  const animations = [];
  child.box.animate = (keyframes, options) => { animations.push({ keyframes, options }); return {}; };
  // 首发：首词条 120px，尾批仍在途——先不显示（不再以一条矮条入场再「啪」地长高）。
  h.call(child, 'popupRendered', [120, 1, 900, true]);
  assert.equal(child.box.style.visibility, undefined, '尾批在途时先不显示');
  assert.equal(child.box.style.top, '100px', '按最终可能的高度选边：直接落上方，不先落下方');
  assert.equal(animations.length, 0);
  // 终高到：显示、播一次入场。
  h.call(child, 'popupRendered', [480, 1, 900, false], 2);
  assert.equal(child.box.style.visibility, 'visible');
  assert.equal(animations.length, 1, '显示时播一次入场动画');
  assert.equal(child.box.style.transformOrigin, '50% 100%', '落上方时从贴词的底边长出');
  assert.equal(child.box.style.top, '100px');
  assert.equal(plans.at(-1).side, 'above', '显示后复算锁在已选一侧');
  assert.match(child.box.style.transition, /height 180ms/, '显示后的长高 / 夹高走过渡');
  // 计时器兜底在终高已到后不得二次显示 / 重播。
  h.runTimers();
  assert.equal(animations.length, 1);
  // 之后的复报（masonry 重排）只重算落点，不重播。
  h.call(child, 'popupRendered', [500, 1, 900, false], 3);
  assert.equal(plans.at(-1).side, 'above');
  assert.equal(animations.length, 1);
});

test('slow tail batch: the layer is revealed after a bounded wait and later growth is transitioned', () => {
  const h = harness();
  h.api.open('子', { x: 80, y: 100 }); h.replyLookup(0);
  const child = h.frames[0];
  const animations = [];
  child.box.animate = () => { animations.push(1); return {}; };
  h.call(child, 'popupRendered', [120, 1, 900, true]);
  h.call(child, 'popupRendered', [130, 1, 900, true], 2);
  assert.equal(h.timers.filter(t => !t.cleared).length, 1, '在途重复首发只挂一个兜底计时器');
  assert.equal(h.timers[0].ms, 260);
  assert.equal(child.box.style.visibility, undefined);
  h.runTimers();
  assert.equal(child.box.style.visibility, 'visible', '尾批迟迟不来：最多等一下就先显示');
  assert.equal(animations.length, 1);
  assert.match(child.box.style.transition, /height 180ms/);
  h.call(child, 'popupRendered', [480, 1, 900, false], 3);
  assert.equal(animations.length, 1, '终高晚到只走高度过渡，不重播入场');
});

test('closing a layer before its tail batch arrives cancels the pending reveal', () => {
  const h = harness();
  h.api.open('子'); h.replyLookup(0);
  const child = h.frames[0];
  h.call(child, 'popupRendered', [120, 1, 900, true]);
  h.api.clear();
  assert.equal(h.timers[0].cleared, true);
});

test('nested layer whose first render is final keeps the measured side', () => {
  const h = harness();
  h.context.fushiComputePlacement = (anchor, size, viewport, side) => {
    const s = side || (size.height <= 300 ? 'below' : 'above');
    return { left: 10, top: s === 'below' ? 600 : 100, maxHeight: null, side: s };
  };
  h.api.open('子', { x: 80, y: 560 }); h.replyLookup(0);
  const child = h.frames[0];
  h.call(child, 'popupRendered', [120, 1, 900, false]);
  assert.equal(child.box.style.top, '600px', '只有一条词条（不在途）时按实测高度落词下方');
});

// 用户截图：第一层是玻璃，第二层起是白色实底 + 写死 10px 圆角——子层没走同一套材质。
test('every nested layer looks exactly like the first layer (same glass, outline and shadow at every depth)', () => {
  const h = harness();
  h.api.open('子');
  h.lookups[0].callback({ ok: true, data: { popupJson: JSON.stringify([{ expression: '子' }]),
    theme: { '--fushi-radius-card': '14px', '--fushi-color-scheme': 'dark' } } });
  const child = h.frames[0];
  assert.equal(child.box.className, 'fushi-nested-layer');
  assert.equal(child.box.attrs['data-fushi-glass'], 'dark');
  assert.match(child.box.style.cssText, /border-radius:14px/);
  assert.match(child.style.cssText, /color-scheme:dark/, 'iframe 元素与 iframe 根的 color-scheme 必须一致，否则 Chrome 垫不透明画布底');
  assert.match(child.style.cssText, /background:transparent/);
  // 模糊写在外框行内样式里，不依赖 manifest 注入、可能是旧版缓存的页面级 content.css。
  assert.match(child.box.style.cssText, /backdrop-filter:blur\(20px\) saturate\(1\.4\)/);
  assert.match(child.box.style.cssText, /overflow:hidden/, '外框裁切圆角');
  h.event(child, { type: 'ready' });
  const render = child.messages.find(message => message.type === 'render');
  assert.equal(render.data.glassBackdrop, true, '握手：告诉内容外框正在模糊，内容才换半透明填充');
  h.call(child, 'textSelected', ['孫', { x: 10, y: 20 }]);
  h.lookups[1].callback({ ok: true, data: { popupJson: JSON.stringify([{ expression: '孫' }]),
    theme: { '--fushi-radius-card': '14px', '--fushi-color-scheme': 'dark' } } });
  const grandchild = h.frames[1];
  assert.equal(grandchild.box.attrs['data-fushi-glass'], 'dark');
  assert.match(grandchild.box.style.cssText, /border-radius:14px/);
  // 每一层外观都与第一层一致（用户 2026-10-05 拍板）：投影 / 模糊 / 描边逐字取第一层
  // content.css :host([data-fushi-glass]) 的值，不随层深变化。
  const contentCss = fs.readFileSync(path.join(__dirname, 'vendor', 'content.css'), 'utf8');
  const hostRule = /:host\(\[data-fushi-glass\]\)\s*\{([^}]*)\}/.exec(contentCss)[1];
  const firstShadow = /box-shadow:\s*([^;]+);/.exec(hostRule)[1].replace(/,\s*/g, ',');
  const firstBlur = /(?<!-)backdrop-filter:\s*([^;]+);/.exec(hostRule)[1];
  for (const layer of [child, grandchild]) {
    assert.ok(layer.box.style.cssText.includes('box-shadow:' + firstShadow + ';'), '投影与第一层相同');
    assert.ok(layer.box.style.cssText.includes('backdrop-filter:' + firstBlur + ';'), '模糊与第一层相同');
    assert.match(layer.box.style.cssText, /outline:1px solid rgba\(255,255,255,0\.08\)/, '描边与第一层暗色相同');
  }
  const skin = (frame) => frame.box.style.cssText.replace(/(top|left|width|height|visibility|transform|opacity|transition)[^;]*;/g, '');
  assert.equal(skin(grandchild), skin(child), '孙层外观参数与子层逐字相同');
  // 墨水屏（--fushi-glass: '0'）保持不透明。
  h.event(grandchild, { type: 'ready' });
  h.call(grandchild, 'textSelected', ['曾', { x: 10, y: 20 }]);
  h.lookups[2].callback({ ok: true, data: { popupJson: JSON.stringify([{ expression: '曾' }]),
    theme: { '--fushi-glass': '0' } } });
  assert.equal(h.frames[2].box.attrs['data-fushi-glass'], undefined);
  assert.doesNotMatch(h.frames[2].box.style.cssText, /backdrop-filter/);
  h.event(h.frames[2], { type: 'ready' });
  assert.equal(h.frames[2].messages.find(message => message.type === 'render').data.glassBackdrop, false);
});

test('without usable backdrop-filter the layer stays opaque instead of translucent-without-blur', () => {
  const h = harness();
  h.window.CSS = { supports: () => false };
  h.api.open('子'); h.replyLookup(0);
  const child = h.frames[0];
  assert.doesNotMatch(child.box.style.cssText, /backdrop-filter/);
  assert.equal(child.messages.find(message => message.type === 'render').data.glassBackdrop, false);
});

// 用户 2026-10-05 YouTube 截图：第二层压在第一层上那块明显更白（(236,242,241) vs 第一层
// (221,229,226)）——子层的 backdrop-filter 采到的是第一层已经磨砂 + 0.72 填充的面板，等效
// 双重填充；填充本身两层逐字相同（第二层压在深色页面上那截 (187,191,191) = 0.72×251 + 0.28×15）。
// 修法：把下层被上层玻璃卡盖住的区域挖掉（mask），上层采到的就是网页本身。
test('glass on glass: every lower layer is cut where an upper glass layer covers it, so each layer samples the page', () => {
  const h = harness();
  const animations = [];
  h.root.style = { zoom: '1.25' };
  h.root.getBoundingClientRect = () => ({ left: 40, top: 60, width: 500, height: 400 });
  h.root.animate = (frames, options) => animations.push({ frames, options });
  h.context.fushiComputePlacement = () => ({ left: 290, top: 160, maxHeight: 500 });
  h.api.open('子', { x: 80, y: 100 }); h.replyLookup(0);
  const child = h.frames[0];
  const enter = [];
  child.box.animate = (frames) => enter.push(frames);
  assert.equal(h.root.style.maskImage, undefined, '子层显示前不挖');
  h.call(child, 'popupRendered', [300]);
  const s = h.root.style;
  // 第一层 host 带 CSS zoom 1.25：mask 长度按 host 自己的未缩放坐标（视口差 / zoom）。
  assert.equal(s.maskPosition, '-96px -96px, 200px 80px');
  assert.equal(s.maskSize, 'calc(100% + 192px) calc(100% + 192px), 400px 240px');
  assert.equal(s.maskComposite, 'subtract, add', '洞先并（add）再从整块里减（subtract），重叠的洞不会互相抵消');
  assert.equal(s.maskClip, 'no-clip', '保住第一层框外投影');
  assert.equal(s.maskRepeat, 'no-repeat');
  assert.match(s.maskImage, /^linear-gradient\(#000 0 0\), url\("data:image\/svg\+xml,/);
  assert.match(decodeURIComponent(s.maskImage), /rx='8'/, '洞是上层圆角（10px / zoom 1.25）');
  // 入场：压在下层上时只做 transform（淡入会让洞里露出未模糊的网页），洞从入场起点同步长到终点。
  assert.equal(enter.length, 1);
  assert.equal('opacity' in enter[0][0], false);
  assert.equal(animations.length, 1);
  assert.notEqual(animations[0].frames[0].maskPosition, s.maskPosition);
  assert.equal(animations[0].frames[1].maskPosition, s.maskPosition);
  assert.equal(animations[0].options.duration, 180, '与外框入场 / 高度过渡同一时长');
  // 孙层：同时盖住第一层与子层 → 两层都挖，第一层上两个洞。
  h.context.fushiComputePlacement = () => ({ left: 300, top: 200, maxHeight: 500 });
  h.call(child, 'textSelected', ['孫', { x: 10, y: 20 }]); h.replyLookup(1);
  const grandchild = h.frames[1];
  h.call(grandchild, 'popupRendered', [200]);
  assert.equal(h.root.style.maskComposite, 'subtract, add, add');
  assert.equal(child.box.style.maskComposite, 'subtract, add');
  assert.equal(child.box.style.maskPosition, '-96px -96px, 10px 40px', '子层外框不带 zoom：按落点直接相减');
  assert.equal(grandchild.box.style.maskImage, undefined, '最上层不挖');
  // 逐层关闭：洞随层一起撤掉，第一层恢复完整。
  h.api.pop();
  assert.equal(child.box.style.maskImage, '');
  assert.equal(h.root.style.maskComposite, 'subtract, add');
  h.api.pop();
  assert.equal(h.root.style.maskImage, '');
  assert.equal(h.root.style.maskPosition, '');
});

test('opaque (non-glass) upper layers never cut the layer below and keep the fade-in entrance', () => {
  const h = harness();
  h.window.CSS = { supports: () => false };
  h.root.style = {};
  h.root.getBoundingClientRect = () => ({ left: 40, top: 60, width: 500, height: 400 });
  h.api.open('子'); h.replyLookup(0);
  const child = h.frames[0];
  const enter = [];
  child.box.animate = (frames) => enter.push(frames);
  h.call(child, 'popupRendered', [300]);
  assert.equal(h.root.style.maskImage, undefined);
  assert.equal(enter[0][0].opacity, 0);
});
