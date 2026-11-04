// canvas 渲染的网页阅读器（BookWalker 等）抓图取词。隔离世界，站点无关。
//
// 为什么需要它：这类阅读器把正文画进 `<canvas>`，页面里没有文本节点，
// `fushiSelection.getCharacterAtPoint`（caretRangeFromPoint）在 canvas 上只会返回 null——
// Shift 悬停 / 点按查词因此整页无反应。这里在「取不到文本节点、指针下却是一块大 canvas」时：
//   1. 截取 canvas 在视口内可见的那部分像素：
//      · 首选 `drawImage(canvas) → toDataURL`，读的是 canvas 自己的位图，不受遮挡层影响；
//      · canvas 被跨源图片污染（toDataURL 抛 SecurityError），或是读回全透明的 WebGL 画布
//        （preserveDrawingBuffer=false）时，改由 background 的 `tabs.captureVisibleTab` 截可视区，
//        再按 canvas 的视口矩形裁剪；
//   2. 截图交给 app（`ocrImage` → `POST /api/ocr/image`），用漫画 / 视频暂停帧同一套 OCR 识别，
//      回每个字在截图里的位置；
//   3. 命中指针下那个字，从它起取词交给既有查词弹窗，整块文字作例句。
//
// 一页只识别一次：结果按 canvas + 视口几何缓存，翻页类输入（点击、按键、滚轮、滚动、缩放）
// 一律作废缓存，下一次悬停重新截图识别。只认最后一次指针位置：识别在途时连发的悬停只留最后一次。

// 识别图长边上限（像素）。超过等比缩小：OCR 的精度够用，请求体也不至于几十 MB。
var FUSHI_CANVAS_OCR_MAX_LONG_EDGE = 2048;
// canvas 在视口里的可见部分至少这么大（CSS px）才当阅读器正文；小 canvas 多是图标 / 图表 / 验证码。
var FUSHI_CANVAS_OCR_MIN_SIDE = 120;
// 命中字时，字框向外放宽的比例（字间缝隙里的指针也算命中相邻的字）。
var FUSHI_CANVAS_OCR_HIT_SLOP = 0.15;

// 指针下的阅读器 canvas：elementsFromPoint 自顶向下第一块够大的 canvas（阅读器常在 canvas
// 上盖一层透明的点击层，elementFromPoint 只会拿到那一层）。扩展自己的界面不算。
function fushiCanvasOcrTargetAt(doc, x, y) {
  if (!doc || typeof doc.elementsFromPoint !== 'function') return null;
  let stack;
  try { stack = doc.elementsFromPoint(x, y) || []; } catch (_) { return null; }
  for (const el of stack) {
    if (!el || String(el.tagName || '').toUpperCase() !== 'CANVAS') continue;
    if (el.id && String(el.id).indexOf('fushi-') === 0) continue;
    let r;
    try { r = el.getBoundingClientRect(); } catch (_) { continue; }
    if (r && r.width >= FUSHI_CANVAS_OCR_MIN_SIDE && r.height >= FUSHI_CANVAS_OCR_MIN_SIDE) return el;
  }
  return null;
}

// canvas 视口矩形 ∩ 视口 → 要截的视口矩形（CSS px，取整到像素网格）；可见部分太小返回 null。
function fushiCanvasOcrCaptureRect(canvasRect, viewportWidth, viewportHeight) {
  if (!canvasRect) return null;
  const left = Math.max(0, Math.floor(canvasRect.left));
  const top = Math.max(0, Math.floor(canvasRect.top));
  const right = Math.min(viewportWidth, Math.ceil(canvasRect.left + canvasRect.width));
  const bottom = Math.min(viewportHeight, Math.ceil(canvasRect.top + canvasRect.height));
  const width = right - left;
  const height = bottom - top;
  if (!(width >= FUSHI_CANVAS_OCR_MIN_SIDE) || !(height >= FUSHI_CANVAS_OCR_MIN_SIDE)) return null;
  return { left, top, width, height };
}

// 视口矩形 → canvas 位图坐标（canvas.width/height 与 CSS 尺寸之比，即 devicePixelRatio 等缩放）。
function fushiCanvasOcrSourceRect(captureRect, canvasRect, bitmapWidth, bitmapHeight) {
  const sx = bitmapWidth / canvasRect.width;
  const sy = bitmapHeight / canvasRect.height;
  const x = Math.max(0, (captureRect.left - canvasRect.left) * sx);
  const y = Math.max(0, (captureRect.top - canvasRect.top) * sy);
  return {
    x,
    y,
    width: Math.min(bitmapWidth - x, captureRect.width * sx),
    height: Math.min(bitmapHeight - y, captureRect.height * sy),
  };
}

// 源尺寸 → 输出尺寸：只缩不放，长边不超过 maxLongEdge。
function fushiCanvasOcrOutputSize(width, height, maxLongEdge) {
  const long = Math.max(width, height);
  const scale = long > maxLongEdge ? maxLongEdge / long : 1;
  return {
    width: Math.max(1, Math.round(width * scale)),
    height: Math.max(1, Math.round(height * scale)),
  };
}

// 读回的像素是否整块全透明（WebGL 画布在 preserveDrawingBuffer=false 时 drawImage 得到的就是它）。
// 只看 alpha：深色 / 黑底页面是正常内容，不能当失败。
function fushiCanvasOcrAllTransparent(ctx, width, height) {
  if (!ctx || typeof ctx.getImageData !== 'function') return false;
  const grid = 8;
  for (let gy = 0; gy < grid; gy++) {
    for (let gx = 0; gx < grid; gx++) {
      const x = Math.min(width - 1, Math.floor((gx + 0.5) * width / grid));
      const y = Math.min(height - 1, Math.floor((gy + 0.5) * height / grid));
      const d = ctx.getImageData(x, y, 1, 1).data;
      if (d[3] !== 0) return false;
    }
  }
  return true;
}

// data URL → 裸 base64（请求体只带 base64；server 也认带前缀的，但没必要多传）。
function fushiCanvasOcrBase64(dataUrl) {
  const s = String(dataUrl || '');
  const comma = s.indexOf(',');
  return comma >= 0 ? s.slice(comma + 1) : s;
}

// 首选路：直接读 canvas 位图。污染（SecurityError）/ 全透明回 null，交给截屏路。
function fushiCanvasOcrReadCanvas(doc, canvas, captureRect, canvasRect) {
  const bw = Number(canvas.width) || 0;
  const bh = Number(canvas.height) || 0;
  if (!(bw > 0 && bh > 0)) return null;
  const src = fushiCanvasOcrSourceRect(captureRect, canvasRect, bw, bh);
  if (!(src.width > 0 && src.height > 0)) return null;
  const out = fushiCanvasOcrOutputSize(src.width, src.height, FUSHI_CANVAS_OCR_MAX_LONG_EDGE);
  try {
    const tmp = doc.createElement('canvas');
    tmp.width = out.width;
    tmp.height = out.height;
    const ctx = tmp.getContext('2d');
    if (!ctx) return null;
    ctx.drawImage(canvas, src.x, src.y, src.width, src.height, 0, 0, out.width, out.height);
    if (fushiCanvasOcrAllTransparent(ctx, out.width, out.height)) return null;
    const dataUrl = tmp.toDataURL('image/png');
    if (typeof dataUrl !== 'string' || dataUrl.indexOf('data:image/') !== 0) return null;
    return { image: fushiCanvasOcrBase64(dataUrl), width: out.width, height: out.height };
  } catch (_) {
    // SecurityError：canvas 画过跨源图片，位图读不出来。
    return null;
  }
}

// 截屏路：整页可视区截图（data URL，设备像素）→ 按视口矩形裁剪 + 降采样。
// [loadImage] 把 data URL 解成可 drawImage 的图（测试注入）。
async function fushiCanvasOcrCropScreenshot(doc, dataUrl, captureRect, viewportWidth, loadImage) {
  const img = await loadImage(dataUrl);
  const natural = Number(img.naturalWidth || img.width) || 0;
  if (!(natural > 0 && viewportWidth > 0)) return null;
  // 截图像素 / CSS px：含 devicePixelRatio 与页面缩放，按实际截图宽度量，不猜 dpr。
  const scale = natural / viewportWidth;
  const sw = captureRect.width * scale;
  const sh = captureRect.height * scale;
  const out = fushiCanvasOcrOutputSize(sw, sh, FUSHI_CANVAS_OCR_MAX_LONG_EDGE);
  const tmp = doc.createElement('canvas');
  tmp.width = out.width;
  tmp.height = out.height;
  const ctx = tmp.getContext('2d');
  if (!ctx) return null;
  ctx.drawImage(img, captureRect.left * scale, captureRect.top * scale, sw, sh, 0, 0, out.width, out.height);
  const cropped = tmp.toDataURL('image/png');
  return { image: fushiCanvasOcrBase64(cropped), width: out.width, height: out.height };
}

// 字素切分：与 app 侧 `characters` 同一口径（OCR 结果的 `i` 是字素下标）。
function fushiCanvasOcrGraphemes(text) {
  const s = String(text || '');
  try {
    if (typeof Intl !== 'undefined' && typeof Intl.Segmenter === 'function') {
      const seg = new Intl.Segmenter(undefined, { granularity: 'grapheme' });
      return Array.from(seg.segment(s), (p) => p.segment);
    }
  } catch (_) { /* 无 Segmenter：退回码点 */ }
  return Array.from(s);
}

// 截图像素矩形 → 视口矩形。
function fushiCanvasOcrToViewport(box, frame) {
  const sx = frame.captureRect.width / frame.width;
  const sy = frame.captureRect.height / frame.height;
  return {
    left: frame.captureRect.left + box.x * sx,
    top: frame.captureRect.top + box.y * sy,
    width: box.w * sx,
    height: box.h * sy,
  };
}

// 视口点 → 命中的字：{ block, charPos }，没命中 null。字框放宽 FUSHI_CANVAS_OCR_HIT_SLOP；
// 多个放宽框都含这个点时取中心最近的。
function fushiCanvasOcrCharAt(frame, x, y) {
  if (!frame || !Array.isArray(frame.blocks) || !(frame.width > 0) || !(frame.height > 0)) return null;
  const cap = frame.captureRect;
  if (x < cap.left || y < cap.top || x > cap.left + cap.width || y > cap.top + cap.height) return null;
  const ix = (x - cap.left) * frame.width / cap.width;
  const iy = (y - cap.top) * frame.height / cap.height;
  let best = null;
  let bestDist = Infinity;
  for (const block of frame.blocks) {
    const chars = Array.isArray(block.chars) ? block.chars : [];
    for (let p = 0; p < chars.length; p++) {
      const c = chars[p];
      const px = c.w * FUSHI_CANVAS_OCR_HIT_SLOP;
      const py = c.h * FUSHI_CANVAS_OCR_HIT_SLOP;
      if (ix < c.x - px || ix > c.x + c.w + px || iy < c.y - py || iy > c.y + c.h + py) continue;
      const dx = ix - (c.x + c.w / 2);
      const dy = iy - (c.y + c.h / 2);
      const dist = dx * dx + dy * dy;
      if (dist < bestDist) { bestDist = dist; best = { block, charPos: p }; }
    }
  }
  return best;
}

// 命中的字 → 查词参数：term 从该字起取 maxLen 个字素；sentence 为整块文字；rects 是从该字起
// 连续字素（下标逐一递增）的视口框，供高亮前 n 个字；anchorRect 是命中字的视口框。
function fushiCanvasOcrLookupOf(frame, hit, maxLen) {
  const block = hit.block;
  const chars = block.chars;
  const start = chars[hit.charPos];
  const graphemes = fushiCanvasOcrGraphemes(block.text);
  const term = graphemes.slice(start.i, start.i + maxLen).join('');
  const rects = [];
  let expect = start.i;
  for (let p = hit.charPos; p < chars.length && rects.length < maxLen; p++) {
    if (chars[p].i !== expect) break;
    rects.push(fushiCanvasOcrToViewport(chars[p], frame));
    expect++;
  }
  const a = rects[0];
  return {
    term,
    sentence: String(block.text || '').trim(),
    rects,
    anchorRect: a ? { x: a.left, y: a.top, width: a.width, height: a.height } : null,
  };
}

// 缓存键：同一块 canvas、同一视口几何、同一位图尺寸 = 同一页画面（翻页另由输入事件作废）。
function fushiCanvasOcrKey(captureRect, canvas) {
  return [captureRect.left, captureRect.top, captureRect.width, captureRect.height,
    Number(canvas.width) || 0, Number(canvas.height) || 0].join(',');
}

// 抓图取词会话（每个页面一个）。deps：
//   doc / win：document / window；
//   sendMessage(msg) → Promise<resp>：发给 background（chrome.runtime.sendMessage 的 Promise 包装）；
//   loadImage(dataUrl) → Promise<img>；
//   beforeScreenshot() → Promise：截屏路之前收起扩展自己的弹窗 / 高亮（否则会被截进图里）。
function fushiCreateCanvasOcrSession(deps) {
  let cache = null; // { canvas, key, promise }
  let seq = 0;

  function invalidate() { cache = null; }

  async function captureAndRecognize(canvas, captureRect, canvasRect) {
    let shot = fushiCanvasOcrReadCanvas(deps.doc, canvas, captureRect, canvasRect);
    if (!shot) {
      if (typeof deps.beforeScreenshot === 'function') await deps.beforeScreenshot();
      const cap = await deps.sendMessage({ type: 'canvasOcrCapture' });
      if (!cap || cap.ok !== true || typeof cap.dataUrl !== 'string') {
        return { error: 'capture', detail: cap && cap.error || null };
      }
      shot = await fushiCanvasOcrCropScreenshot(
        deps.doc, cap.dataUrl, captureRect, deps.win.innerWidth, deps.loadImage);
      if (!shot) return { error: 'capture' };
    }
    const resp = await deps.sendMessage({ type: 'ocrImage', image: shot.image });
    if (!resp || resp.ok !== true || !resp.data) return { error: 'request', resp: resp || null };
    const data = resp.data;
    if (data.error) return { error: String(data.error) };
    return {
      frame: {
        captureRect,
        width: Number(data.width) || shot.width,
        height: Number(data.height) || shot.height,
        blocks: Array.isArray(data.blocks) ? data.blocks : [],
      },
    };
  }

  // 指针 (x, y) 下若是阅读器 canvas：识别（或复用缓存）并命中字。
  // 回 Promise<{ status: 'none' | 'stale' | 'miss' | 'error' | 'hit', ... }>：
  //   none = 指针下不是阅读器 canvas（调用方照旧无事可做）；stale = 有更新的指针位置，本次作废；
  //   miss = 识别了但指针下没有字；error = 识别失败（{ error, resp? }）；hit = { canvas, lookup }。
  async function lookupAt(x, y, maxLen) {
    const canvas = fushiCanvasOcrTargetAt(deps.doc, x, y);
    if (!canvas) return { status: 'none' };
    const mySeq = ++seq;
    let canvasRect;
    try { canvasRect = canvas.getBoundingClientRect(); } catch (_) { return { status: 'none' }; }
    const captureRect = fushiCanvasOcrCaptureRect(canvasRect, deps.win.innerWidth, deps.win.innerHeight);
    if (!captureRect) return { status: 'none' };
    const key = fushiCanvasOcrKey(captureRect, canvas);
    if (!cache || cache.canvas !== canvas || cache.key !== key) {
      const entry = { canvas, key, promise: null };
      entry.promise = captureAndRecognize(canvas, captureRect, canvasRect).catch((e) => ({
        error: 'exception', detail: String(e && e.message || e),
      }));
      cache = entry;
      // 失败的结果不留：下一次悬停重新识别（引擎装好 / app 回到前台后不必刷新页面）。
      entry.promise.then((r) => { if (r && r.error && cache === entry) cache = null; });
    }
    const result = await cache.promise;
    if (mySeq !== seq) return { status: 'stale' };
    if (result.error) return { status: 'error', error: result.error, resp: result.resp || null };
    const hit = fushiCanvasOcrCharAt(result.frame, x, y);
    if (!hit) return { status: 'miss' };
    return { status: 'hit', canvas, lookup: fushiCanvasOcrLookupOf(result.frame, hit, maxLen) };
  }

  return { lookupAt, invalidate };
}

if (typeof module !== 'undefined' && module.exports) {
  module.exports = {
    FUSHI_CANVAS_OCR_MAX_LONG_EDGE,
    FUSHI_CANVAS_OCR_MIN_SIDE,
    fushiCanvasOcrTargetAt,
    fushiCanvasOcrCaptureRect,
    fushiCanvasOcrSourceRect,
    fushiCanvasOcrOutputSize,
    fushiCanvasOcrAllTransparent,
    fushiCanvasOcrReadCanvas,
    fushiCanvasOcrCropScreenshot,
    fushiCanvasOcrGraphemes,
    fushiCanvasOcrCharAt,
    fushiCanvasOcrLookupOf,
    fushiCreateCanvasOcrSession,
  };
}
