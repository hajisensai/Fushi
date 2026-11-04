// canvas 渲染的网页阅读器（BookWalker 等）抓图取词的行为守卫。
//
// 根因：这类阅读器把正文画进 <canvas>，页面里没有文本节点；content.js 的取词只认
// caretRangeFromPoint 命中的文本节点（fushiSelection.getCharacterAtPoint），在 canvas 上恒为
// null → `if (!hit) return;`，Shift 悬停 / 点按查词整页无反应。
//
// 这里钉住：
//   1) 几何：指针下的阅读器 canvas（穿过透明点击层）、可见部分裁剪、视口 → 位图 / 截图坐标；
//   2) 截取：首选 canvas 位图；被跨源污染（toDataURL 抛 SecurityError）或读回全透明时改走
//      background 的 captureVisibleTab 截图再裁；
//   3) 命中：截图像素字框 → 视口命中、从命中字起取词、例句 = 整块文字；
//   4) 一页只识别一次（缓存），翻页类输入作废缓存；识别失败不留缓存；只认最后一次指针；
//   5) 接线：content.js 在取不到文本节点时真的走抓图取词，查词消息带上 OCR 的词，
//      制卡例句是 OCR 的整块文字。
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const ocr = require('./canvas-ocr.js');

// ── 替身 ──────────────────────────────────────────────────────────────────────

function fakeCanvasEl(rect, bitmap, opts) {
  const o = opts || {};
  return {
    tagName: 'CANVAS',
    id: o.id || '',
    width: bitmap.width,
    height: bitmap.height,
    getBoundingClientRect: () => ({
      left: rect.left, top: rect.top, width: rect.width, height: rect.height,
      right: rect.left + rect.width, bottom: rect.top + rect.height,
    }),
  };
}

// document 替身：elementsFromPoint 回 [stack]；createElement('canvas') 回可画的临时 canvas。
// tainted=true 让 toDataURL 抛 SecurityError；alpha 控制 getImageData 读回的透明度。
function fakeDoc(stack, opts) {
  const o = opts || {};
  const temps = [];
  return {
    temps,
    elementsFromPoint: () => stack,
    createElement(tag) {
      assert.strictEqual(tag, 'canvas');
      const draws = [];
      const tmp = {
        width: 0,
        height: 0,
        draws,
        getContext: () => ({
          drawImage: (...args) => draws.push(args),
          getImageData: () => ({ data: [0, 0, 0, o.alpha === undefined ? 255 : o.alpha] }),
        }),
        toDataURL: () => {
          if (o.tainted && !draws.some((d) => d[0] && d[0].isScreenshot)) {
            const e = new Error('Tainted canvases may not be exported.');
            e.name = 'SecurityError';
            throw e;
          }
          return 'data:image/png;base64,' + (draws.some((d) => d[0] && d[0].isScreenshot) ? 'U0hPVA==' : 'Q0FOVkFT');
        },
      };
      temps.push(tmp);
      return tmp;
    },
  };
}

// OCR 结果：截图 800×600 像素，一块横排「吾輩は猫である」，每字 40×40，从 (100,100) 起；
// 第 5 个字之后断开（下标跳号），模拟识别器漏框。
function ocrBlocks() {
  const chars = [];
  for (let i = 0; i < 7; i++) {
    if (i === 5) continue;
    chars.push({ i, x: 100 + i * 40, y: 100, w: 40, h: 40 });
  }
  return [{ text: '吾輩は猫である', chars }];
}

// ── 1) 几何 ───────────────────────────────────────────────────────────────────

test('指针下的阅读器 canvas：穿过透明点击层取第一块够大的 canvas，小 canvas / 扩展自己的不算', () => {
  const overlay = { tagName: 'DIV' };
  const icon = fakeCanvasEl({ left: 0, top: 0, width: 32, height: 32 }, { width: 32, height: 32 });
  const own = fakeCanvasEl({ left: 0, top: 0, width: 900, height: 900 }, { width: 900, height: 900 }, { id: 'fushi-x' });
  const page = fakeCanvasEl({ left: 0, top: 0, width: 800, height: 600 }, { width: 1600, height: 1200 });
  assert.strictEqual(ocr.fushiCanvasOcrTargetAt(fakeDoc([overlay, icon, own, page]), 10, 10), page);
  assert.strictEqual(ocr.fushiCanvasOcrTargetAt(fakeDoc([overlay, icon]), 10, 10), null);
});

test('可见部分裁剪：canvas 超出视口的部分不截；可见部分太小就不当正文', () => {
  assert.deepStrictEqual(
    ocr.fushiCanvasOcrCaptureRect({ left: -100, top: 50.4, width: 1400, height: 2000 }, 1200, 800),
    { left: 0, top: 50, width: 1200, height: 750 });
  assert.strictEqual(
    ocr.fushiCanvasOcrCaptureRect({ left: 1150, top: 0, width: 400, height: 400 }, 1200, 800), null);
});

test('视口矩形 → canvas 位图坐标按位图 / CSS 尺寸之比换算（高 dpr 画布）', () => {
  const src = ocr.fushiCanvasOcrSourceRect(
    { left: 100, top: 0, width: 400, height: 300 },
    { left: 50, top: -100, width: 800, height: 600 }, 1600, 1200);
  assert.deepStrictEqual(src, { x: 100, y: 200, width: 800, height: 600 });
});

test('输出尺寸只缩不放，长边不超过上限', () => {
  assert.deepStrictEqual(ocr.fushiCanvasOcrOutputSize(800, 600, 2048), { width: 800, height: 600 });
  assert.deepStrictEqual(ocr.fushiCanvasOcrOutputSize(4096, 1024, 2048), { width: 2048, height: 512 });
});

// ── 2) 截取 ───────────────────────────────────────────────────────────────────

test('首选读 canvas 位图；被跨源污染（SecurityError）或读回全透明时回 null 交给截屏路', () => {
  const rect = { left: 0, top: 0, width: 800, height: 600 };
  const cap = { left: 0, top: 0, width: 800, height: 600 };
  const canvas = fakeCanvasEl(rect, { width: 800, height: 600 });
  const ok = ocr.fushiCanvasOcrReadCanvas(fakeDoc([]), canvas, cap, rect);
  assert.deepStrictEqual(ok, { image: 'Q0FOVkFT', width: 800, height: 600 });
  assert.strictEqual(ocr.fushiCanvasOcrReadCanvas(fakeDoc([], { tainted: true }), canvas, cap, rect), null);
  assert.strictEqual(ocr.fushiCanvasOcrReadCanvas(fakeDoc([], { alpha: 0 }), canvas, cap, rect), null,
    'WebGL 画布读回全透明：不能把一张空图送去识别');
});

test('截屏路按实际截图宽度量缩放（含 dpr），只裁 canvas 的视口矩形', async () => {
  const doc = fakeDoc([]);
  const shot = { isScreenshot: true, naturalWidth: 2400, naturalHeight: 1600 };
  const out = await ocr.fushiCanvasOcrCropScreenshot(
    doc, 'data:image/png;base64,AAAA', { left: 100, top: 50, width: 600, height: 400 }, 1200,
    async () => shot);
  assert.deepStrictEqual(out, { image: 'U0hPVA==', width: 1200, height: 800 });
  const d = doc.temps[0].draws[0];
  assert.strictEqual(d[0], shot);
  assert.deepStrictEqual(d.slice(1), [200, 100, 1200, 800, 0, 0, 1200, 800]);
});

// ── 3) 命中 ───────────────────────────────────────────────────────────────────

test('视口点命中字（截图像素 → 视口按截取矩形缩放），从命中字起取词、例句为整块', () => {
  // 截图 800×600 画在视口 (200,100) 起的 400×300 上：视口 1px = 截图 2px。
  const frame = { captureRect: { left: 200, top: 100, width: 400, height: 300 }, width: 800, height: 600, blocks: ocrBlocks() };
  // 「猫」(i=3) 的截图框 x∈[220,260], y∈[100,140] → 视口 x∈[310,330], y∈[150,170]。
  const hit = ocr.fushiCanvasOcrCharAt(frame, 320, 160);
  assert.ok(hit);
  assert.strictEqual(hit.block.chars[hit.charPos].i, 3);
  const lookup = ocr.fushiCanvasOcrLookupOf(frame, hit, 12);
  assert.strictEqual(lookup.term, '猫である');
  assert.strictEqual(lookup.sentence, '吾輩は猫である');
  // 高亮框只取下标连续的字：i=5 漏框，停在 i=4。
  assert.strictEqual(lookup.rects.length, 2);
  assert.deepStrictEqual(lookup.rects[0], { left: 310, top: 150, width: 20, height: 20 });
  assert.deepStrictEqual(lookup.anchorRect, { x: 310, y: 150, width: 20, height: 20 });
  assert.strictEqual(ocr.fushiCanvasOcrCharAt(frame, 590, 390), null, '空白处不命中');
  assert.strictEqual(ocr.fushiCanvasOcrCharAt(frame, 100, 100), null, '截取矩形外不命中');
});

test('取词上限按字素计', () => {
  const frame = { captureRect: { left: 0, top: 0, width: 800, height: 600 }, width: 800, height: 600, blocks: ocrBlocks() };
  const hit = ocr.fushiCanvasOcrCharAt(frame, 120, 120);
  assert.strictEqual(ocr.fushiCanvasOcrLookupOf(frame, hit, 3).term, '吾輩は');
});

// ── 4) 会话：缓存 / 作废 / 失败不留 / 只认最后一次 ─────────────────────────────

function session(opts) {
  const o = opts || {};
  const page = fakeCanvasEl({ left: 0, top: 0, width: 800, height: 600 }, { width: 800, height: 600 });
  const doc = fakeDoc([page], o);
  const sent = [];
  let before = 0;
  const replies = o.replies || {};
  const s = ocr.fushiCreateCanvasOcrSession({
    doc,
    win: { innerWidth: 1200, innerHeight: 800 },
    sendMessage: async (msg) => {
      sent.push(msg);
      if (msg.type === 'canvasOcrCapture') return replies.capture || { ok: true, dataUrl: 'data:image/png;base64,AAAA' };
      if (msg.type === 'ocrImage') {
        return typeof replies.ocr === 'function' ? replies.ocr() : (replies.ocr ||
          { ok: true, data: { width: 800, height: 600, blocks: ocrBlocks() } });
      }
      return null;
    },
    loadImage: async () => ({ isScreenshot: true, naturalWidth: 1200, naturalHeight: 800 }),
    beforeScreenshot: async () => { before++; },
  });
  return { s, sent, page, before: () => before };
}

test('一页只识别一次：同一画面上换字直接命中缓存；翻页类输入作废后重新截图识别', async () => {
  const { s, sent, page } = session();
  const a = await s.lookupAt(120, 120, 12);
  assert.strictEqual(a.status, 'hit');
  assert.strictEqual(a.canvas, page);
  assert.strictEqual(a.lookup.term, '吾輩は猫である');
  assert.deepStrictEqual(sent.map((m) => m.type), ['ocrImage']);
  assert.strictEqual(sent[0].image, 'Q0FOVkFT', '位图可读时直接送 canvas 像素，不截屏');
  const b = await s.lookupAt(240, 120, 12);
  assert.strictEqual(b.lookup.term, '猫である');
  assert.strictEqual(sent.length, 1, '同一画面不得重复识别');
  s.invalidate();
  await s.lookupAt(240, 120, 12);
  assert.strictEqual(sent.length, 2, '翻页后必须重新识别，否则查到的是上一页的字');
});

test('canvas 被跨源污染：改走 captureVisibleTab 截图（截前先收起扩展自己的弹窗）', async () => {
  const { s, sent, before } = session({ tainted: true });
  const r = await s.lookupAt(120, 120, 12);
  assert.strictEqual(r.status, 'hit');
  assert.deepStrictEqual(sent.map((m) => m.type), ['canvasOcrCapture', 'ocrImage']);
  assert.strictEqual(sent[1].image, 'U0hPVA==');
  assert.strictEqual(before(), 1);
});

test('app 没有可用的 OCR 引擎：报 error 且不留缓存，下一次悬停重新请求', async () => {
  let calls = 0;
  const { s, sent } = session({ replies: { ocr: () => (++calls === 1
    ? { ok: true, data: { error: 'noEngine', blocks: [] } }
    : { ok: true, data: { width: 800, height: 600, blocks: ocrBlocks() } }) } });
  const r = await s.lookupAt(120, 120, 12);
  assert.deepStrictEqual({ status: r.status, error: r.error }, { status: 'error', error: 'noEngine' });
  const r2 = await s.lookupAt(120, 120, 12);
  assert.strictEqual(r2.status, 'hit', '装好引擎后不刷新页面也该能查');
  assert.strictEqual(sent.filter((m) => m.type === 'ocrImage').length, 2);
});

test('连接失败 / 截图失败如实回 error', async () => {
  const conn = session({ replies: { ocr: { ok: false, connection: { state: 'off' } } } });
  const r = await conn.s.lookupAt(120, 120, 12);
  assert.strictEqual(r.status, 'error');
  assert.strictEqual(r.error, 'request');
  assert.deepStrictEqual(r.resp, { ok: false, connection: { state: 'off' } });
  const cap = session({ tainted: true, replies: { capture: { ok: false, error: 'tab-not-visible' } } });
  assert.strictEqual((await cap.s.lookupAt(120, 120, 12)).error, 'capture');
});

test('识别在途时连发的悬停只认最后一次', async () => {
  const { s } = session();
  const first = s.lookupAt(120, 120, 12);
  const last = s.lookupAt(240, 120, 12);
  assert.strictEqual((await first).status, 'stale');
  assert.strictEqual((await last).lookup.term, '猫である');
});

test('指针下不是阅读器 canvas：none，不发任何消息', async () => {
  const sent = [];
  const s = ocr.fushiCreateCanvasOcrSession({
    doc: fakeDoc([{ tagName: 'DIV' }]),
    win: { innerWidth: 1200, innerHeight: 800 },
    sendMessage: async (m) => { sent.push(m); return null; },
    loadImage: async () => null,
  });
  assert.strictEqual((await s.lookupAt(10, 10, 12)).status, 'none');
  assert.strictEqual(sent.length, 0);
});

// ── 5) content.js 接线 ────────────────────────────────────────────────────────

const ROOT = __dirname;
function loadContentWorld(opts) {
  const o = opts || {};
  const sent = [];
  const docListeners = Object.create(null);
  const page = fakeCanvasEl({ left: 0, top: 0, width: 800, height: 600 }, { width: 800, height: 600 });
  const doc = fakeDoc([{ tagName: 'DIV' }, page], o);
  const selection = {
    getCharacterAtPoint: () => null, // canvas 上没有文本节点
    selectFromPosition: () => '',
    getSelectionRect: () => null,
    highlightSelection: () => null,
    clearSelection() {},
    getSentence: () => { throw new Error('canvas 上不该去 DOM 取句'); },
  };
  const sandbox = {
    console: { log() {}, warn() {}, error() {} },
    setTimeout: () => 0,
    clearTimeout() {},
    setInterval: () => 0,
    clearInterval() {},
    requestAnimationFrame: (fn) => { fn(); return 0; },
    URL,
    Intl,
    Node: { TEXT_NODE: 3, ELEMENT_NODE: 1 },
    performance: { now: () => 1000, timeOrigin: 1700000000000 },
    location: { hostname: 'viewer.bookwalker.jp', href: 'https://viewer.bookwalker.jp/x', pathname: '/x', origin: 'https://viewer.bookwalker.jp', search: '' },
  };
  sandbox.document = {
    documentElement: { dataset: {}, setAttribute() {} },
    head: { appendChild() {} },
    body: { appendChild() {}, style: {} },
    title: 'BookWalker',
    fullscreenElement: null,
    addEventListener: (t, fn) => { (docListeners[t] = docListeners[t] || []).push(fn); },
    getElementById: () => null,
    querySelector: () => null,
    querySelectorAll: () => [],
    elementsFromPoint: doc.elementsFromPoint,
    createElement: (tag) => (tag === 'canvas' ? doc.createElement('canvas') : {
      style: {}, dataset: {}, classList: { add() {}, remove() {}, toggle() {} },
      addEventListener() {}, removeEventListener() {}, appendChild() {}, setAttribute() {},
      remove() {}, contains: () => false,
    }),
  };
  sandbox.chrome = {
    runtime: {
      id: 'test-ext-id',
      lastError: null,
      onMessage: { addListener() {} },
      sendMessage: (msg, cb) => {
        if (!msg || msg.type !== 'dictMediaConfig') sent.push(msg);
        let reply = { ok: true, data: { result: 'success' } };
        if (msg && msg.type === 'ocrImage') reply = { ok: true, data: { width: 800, height: 600, blocks: ocrBlocks() } };
        if (msg && msg.type === 'canvasOcrCapture') reply = { ok: true, dataUrl: 'data:image/png;base64,AAAA' };
        // 查词回失败：只断言发出去的内容，不跑弹窗渲染（失败回执让在途闸放行下一次悬停）。
        if (msg && msg.type === 'lookup') reply = { ok: false, error: 'not-rendered-in-test' };
        if (typeof cb === 'function') cb(reply);
        return Promise.resolve(reply);
      },
    },
    storage: {
      local: { get: (_k, cb) => { if (typeof cb === 'function') cb({}); return Promise.resolve({}); }, set: async () => {} },
      onChanged: { addListener() {} },
    },
  };
  sandbox.Image = class {
    set src(_v) { this.isScreenshot = true; this.naturalWidth = 1200; this.naturalHeight = 800; this.onload(); }
  };
  sandbox.window = {
    addEventListener() {},
    postMessage() {},
    innerWidth: 1200,
    innerHeight: 800,
    matchMedia: () => ({ matches: false }),
    fushiSelection: selection,
  };
  sandbox.window.window = sandbox.window;
  vm.createContext(sandbox);
  for (const f of ['bridge-shim.js', 'subtitle-adapters.js', 'popup-size.js', 'vendor/dict-media.js',
    'subtitle-providers.js', 'canvas-ocr.js', 'content.js']) {
    vm.runInContext(fs.readFileSync(path.join(ROOT, f), 'utf8'), sandbox, { filename: f });
  }
  return {
    sent,
    windowObj: sandbox.window,
    hover: (x, y) => {
      for (const fn of docListeners.mousemove || []) fn({ shiftKey: true, clientX: x, clientY: y, buttons: 0 });
    },
  };
}

async function settle() {
  for (let i = 0; i < 20; i++) await new Promise((r) => setImmediate(r));
}

test('接线：canvas 正文上 Shift 悬停 → 抓图识别 → 查词消息带 OCR 的词，制卡例句是 OCR 整块文字', async () => {
  const w = loadContentWorld();
  w.hover(240, 120); // 「猫」
  await settle();
  const types = w.sent.map((m) => m && m.type);
  assert.ok(types.includes('ocrImage'), 'canvas 上取不到文本节点时没有走抓图取词：' + types.join(','));
  const lookups = w.sent.filter((m) => m && m.type === 'lookup');
  assert.strictEqual(lookups.length, 1);
  assert.strictEqual(lookups[0].term, '猫である');
  assert.strictEqual(w.windowObj.fushiMineContext().pageSentence, '吾輩は猫である',
    '制卡例句应是 OCR 识别出的整块文字');
});

test('接线：同一画面上换字只识别一次；跨源污染的 canvas 走截图路', async () => {
  const w = loadContentWorld({ tainted: true });
  w.hover(240, 120);
  await settle();
  w.hover(120, 120);
  await settle();
  const types = w.sent.map((m) => m && m.type);
  assert.deepStrictEqual(types.filter((t) => t === 'canvasOcrCapture' || t === 'ocrImage'),
    ['canvasOcrCapture', 'ocrImage']);
  assert.deepStrictEqual(w.sent.filter((m) => m && m.type === 'lookup').map((m) => m.term),
    ['猫である', '吾輩は猫である']);
});
