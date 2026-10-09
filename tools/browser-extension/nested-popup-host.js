// Each child has its own popup realm, like the App's per-layer WebView. Parents
// are never re-rendered, and callbacks are owned by the exact layer that sent them.
(function () {
  'use strict';
  function tr(key, params) {
    return (typeof window.fushiT === 'function') ? window.fushiT(key, params) : key;
  }
  const layers = [];
  const requests = new Map();
  let sequence = 0;
  const frameUrl = chrome.runtime.getURL('nested-popup.html');
  const frameOrigin = 'chrome-extension://' + chrome.runtime.id;
  function send(layer, message) {
    if (layer.port && layers.includes(layer)) layer.port.postMessage({ __fushiPopupFrame: true, ...message });
  }
  function updateParents() {
    window.__hasChildPopup = layers.length > 0;
    layers.forEach((layer, index) => send(layer, { type: 'hasChild', value: index < layers.length - 1 }));
  }
  function dismissAfter(parent) {
    const keep = parent ? layers.indexOf(parent) + 1 : 0;
    if (parent && !keep) return;
    for (const layer of layers.splice(keep)) {
      requests.delete(layer);
      if (layer.revealTimer) { clearTimeout(layer.revealTimer); layer.revealTimer = null; }
      if (layer.port) {
        layer.port.onmessage = null;
        layer.port.close();
      }
      layer.box.remove();
    }
    requests.delete(parent);
    updateOccluders(null);
    updateParents();
  }
  function withContext(layer, callback) {
    const cue = fushiPendingCueWindow, draft = fushiSentenceCtx;
    fushiPendingCueWindow = layer.cue;
    fushiSentenceCtx = layer.draft;
    try { return callback(); }
    finally {
      layer.draft = fushiSentenceCtx;
      fushiPendingCueWindow = cue;
      fushiSentenceCtx = draft;
    }
  }
  // 子层外观与第一层（#hibiki-popup-host 的 :host([data-fushi-glass])）同一套参数：同圆角
  // （app 下发的 --fushi-radius-card）、同玻璃（blur 20px + saturate 1.4、黑/白 8% 描边）、
  // 同投影（0 10px 32px 22% 黑）、同填充（nested-popup.js 挂 .fushi-glass，走 content.css 第一层
  // 那两条亮 0.72 / 暗 0.62）。每一层都与第一层外观一致，不随层深变化（用户 2026-10-05 拍板）。
  // 玻璃的模糊**全部由本脚本写在外框的行内样式里**，不再靠 manifest 注入的页面级 content.css
  // （旧做法：iframe.fushi-nested-layer[data-fushi-glass] 规则）。manifest content_scripts 的
  // JS / CSS 在扩展加载时读进内存，此后磁盘上的扩展目录被 app 覆盖更新、扩展没重载时，标签页里
  // 跑的仍是旧脚本 + 旧 CSS；而 iframe 内容（nested-popup.html / .js）与第一层 shadow 里 fetch
  // 的 content.css 是 web_accessible_resources，每次都从磁盘现读——于是新内容（半透明填充）配
  // 旧页面 CSS（没有模糊规则），子层成了「半透明却不模糊」，网页字幕和父层文字清清楚楚透出来
  // （2026-10-04 录屏）。现在模糊与填充由同一份宿主脚本经 glassBackdrop 握手一起决定。
  // color-scheme 两侧对齐：iframe 元素与 iframe 根的 color-scheme 不一致时 Chrome 会给
  // iframe 画一层不透明画布底（白 / 黑），玻璃永远透不出来。
  // 外观风格（theme.js extensionStyle）：M3E 下子层与第一层一样是实色卡，不上玻璃。
  function fushiNestedStyle() {
    const t = window.fushiTheme;
    return t && t.style === 'glass' ? 'glass' : 'm3e';
  }
  function fushiNestedGlass(theme) {
    if (fushiNestedStyle() !== 'glass') return false;
    return !(theme && theme['--fushi-glass'] === '0');
  }
  // 与第一层 content.css 的 @supports / prefers-reduced-transparency 回落同一判据。
  function fushiNestedBackdropUsable() {
    try {
      const css = window.CSS;
      const supported = !!(css && typeof css.supports === 'function' &&
        (css.supports('backdrop-filter', 'blur(1px)') || css.supports('-webkit-backdrop-filter', 'blur(1px)')));
      if (!supported) return false;
      return !(window.matchMedia && window.matchMedia('(prefers-reduced-transparency: reduce)').matches);
    } catch (_) { return false; }
  }
  function fushiNestedGlassStyle(scheme) {
    return '-webkit-backdrop-filter:blur(20px) saturate(1.4);backdrop-filter:blur(20px) saturate(1.4);' +
      'outline:1px solid ' + (scheme === 'dark' ? 'rgba(255,255,255,0.08)' : 'rgba(0,0,0,0.08)') + ';' +
      'outline-offset:-1px;';
  }
  function fushiNestedScheme(theme) {
    const cs = theme && theme['--fushi-color-scheme'];
    const s = typeof fushiResolveTheme === 'function' ? fushiResolveTheme(cs) : cs;
    return s === 'dark' ? 'dark' : 'light';
  }
  // M3E 子层外观：与 content.css :host([data-style="m3e"]) 的圆角 / 投影逐字相同。
  const FUSHI_M3E_LAYER_RADIUS = '20px';
  const FUSHI_M3E_LAYER_SHADOW = '0 2px 4px rgba(0,0,0,0.18),0 8px 24px 4px rgba(0,0,0,0.16)';
  function fushiNestedLayerSkin(theme) {
    const scheme = 'color-scheme:' + fushiNestedScheme(theme) + ';';
    if (fushiNestedStyle() === 'm3e') {
      return scheme + '--fushi-radius-card:' + FUSHI_M3E_LAYER_RADIUS + ';border-radius:' + FUSHI_M3E_LAYER_RADIUS + ';' +
        'box-shadow:' + FUSHI_M3E_LAYER_SHADOW + ';';
    }
    const radius = (theme && typeof theme['--fushi-radius-card'] === 'string' && theme['--fushi-radius-card']) || '10px';
    // 与 content.css :host([data-fushi-glass]) 的 box-shadow 逐字相同。
    return scheme +
      '--fushi-radius-card:' + radius + ';border-radius:' + radius + ';' +
      'box-shadow:0 10px 32px rgba(0,0,0,0.22);';
  }
  // 选边与第一层同一套规则（content.js fushiApplyPlacement，BUG-2773）：popup.js 双发
  // popupRendered——首发只有首词条高度、尾批建完再发终高。旧实现每发都重新选边：首发矮、
  // 判「词下方放得下」先显示在下方，终高一到放不下又翻到词上方，用户看到子层先在底部冒出
  // 一小条、约半秒后整块跳到顶上（2026-10-04 录屏）。现在尾批在途（stillRendering）时按
  // 本层最终可能长到的高度（theme 上限）选边；子层一显示就锁边，此后长高只在同侧夹高。
  function place(layer, reportedHeight, stillRendering) {
    const viewport = { width: window.innerWidth, height: window.innerHeight };
    const box = fushiResolvePopupBox(layer.data.theme || {}, viewport);
    layer.data.popupZoom = box.zoom;
    const width = Math.min(box.width * box.zoom, Math.max(64, window.innerWidth - 16));
    const cap = Math.min(box.maxHeight * box.zoom, window.innerHeight * 0.8);
    const height = Math.min(Number(reportedHeight) || box.maxHeight, cap);
    let side = layer.side;
    if (!side) {
      const planHeight = stillRendering === true && cap > height ? cap : height;
      side = fushiComputePlacement(layer.anchor, { width, height: planHeight }, viewport).side;
    }
    const pos = fushiComputePlacement(layer.anchor, { width, height }, viewport, side);
    layer.placedSide = pos.side || side || null;
    Object.assign(layer.box.style, {
      left: pos.left + 'px', top: pos.top + 'px', width: width + 'px',
      height: Math.min(height, pos.maxHeight || height) + 'px',
    });
    // 已显示的层长高 / 夹高：下层的洞随外框的 height/top 过渡同步跟过去。
    if (layer.revealed) updateOccluders(null);
  }
  // 「玻璃叠玻璃」修正：把每一层被**更上层玻璃查词卡**盖住的区域从它身上整块挖掉。
  // backdrop-filter 采样的是元素背后已经画好的一切；子层压在父层上时采到的是父层那块
  // 已经磨砂 + 0.72 填充的面板，结果是 0.72 + 0.28 × 父层 ≈ 再白一档（用户 2026-10-05 YouTube
  // 截图：第一层空白处 (221,229,226)，压在第一层上的第二层 (236,242,241)；第二层压在深色页面
  // 上那一截是 (187,191,191) = 0.72 × 251 + 0.28 × 15，填充本身与第一层逐字相同）。
  // 挖掉之后上层模糊采到的就是网页本身——每一层同一背景、同一参数、同一观感；被盖住的那块
  // 下层本来就看不见。与 app 内 PopupOccluderClip（dictionary_popup_layer.dart）同一修法。
  // 用 mask 而不是 clip-path：多个洞彼此重叠时 clip-path 的 evenodd / nonzero 会把重叠处
  // 填回来；mask 先把洞并起来（add）再从整块里减掉（subtract）。mask-clip:no-clip + 外扩的
  // 整块底图保住本层投影（默认 border-box 会把框外投影一并裁掉）。Chrome 的 mask 同时裁本层
  // 自己的 backdrop-filter（CfT 153 实测）。
  const OCCLUDER_PAD = 96;
  const holeImages = new Map();
  const masked = new Set();
  function holeImage(radius) {
    const r = Math.max(0, Math.round(radius * 100) / 100);
    if (!holeImages.has(r)) {
      // 无固有尺寸的 SVG：按 mask-size 铺满，rx 以 px 计、不随洞的尺寸拉伸。
      const svg = "<svg xmlns='http://www.w3.org/2000/svg'><rect width='100%' height='100%' rx='" + r + "'/></svg>";
      holeImages.set(r, 'url("data:image/svg+xml,' + encodeURIComponent(svg) + '")');
    }
    return holeImages.get(r);
  }
  function px(value) {
    const n = Number.parseFloat(value);
    return Number.isFinite(n) ? n : NaN;
  }
  // 子层外框的**落点**（place 写下的终值），不取 getBoundingClientRect：入场 transform 与
  // 高度过渡进行中读到的是中间值。
  function layerRect(layer) {
    const s = layer.box.style || {};
    const r = { x: px(s.left), y: px(s.top), w: px(s.width), h: px(s.height) };
    return [r.x, r.y, r.w, r.h].every(Number.isFinite) && r.w > 0 && r.h > 0 ? r : null;
  }
  // 被挖的那一层：子层外框用落点；第一层 shadow host 用它的边框盒与自身 zoom
  // （content.js 给 host 设了 CSS zoom，mask 的长度按 host 自己的未缩放坐标计）。
  function lowerFrame(element) {
    const owner = layers.find(layer => layer.box === element);
    if (owner) {
      const r = layerRect(owner);
      return r && { ...r, zoom: 1 };
    }
    if (!element || typeof element.getBoundingClientRect !== 'function') return null;
    const b = element.getBoundingClientRect();
    let zoom = 1;
    try {
      const z = px(element.style && element.style.zoom);
      if (z > 0) zoom = z;
    } catch (_) { /* 保持 1 */ }
    const r = { x: b.left, y: b.top, w: b.width, h: b.height, zoom };
    return [r.x, r.y, r.w, r.h].every(Number.isFinite) && r.w > 0 && r.h > 0 ? r : null;
  }
  function overlaps(a, b) {
    return a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h;
  }
  function radiusOf(layer) {
    const r = px(layer.box.style && layer.box.style.borderRadius);
    return Number.isFinite(r) ? r : 10;
  }
  function maskGeometry(frame, holes) {
    const z = frame.zoom;
    const local = holes.map(h => ({ x: (h.x - frame.x) / z, y: (h.y - frame.y) / z, w: h.w / z, h: h.h / z }));
    const base = { pos: -OCCLUDER_PAD + 'px ' + -OCCLUDER_PAD + 'px',
      size: 'calc(100% + ' + 2 * OCCLUDER_PAD + 'px) calc(100% + ' + 2 * OCCLUDER_PAD + 'px)' };
    return {
      position: [base.pos, ...local.map(h => h.x + 'px ' + h.y + 'px')].join(', '),
      size: [base.size, ...local.map(h => h.w + 'px ' + h.h + 'px')].join(', '),
    };
  }
  function clearMask(element) {
    masked.delete(element);
    const s = element && element.style;
    if (!s) return;
    for (const k of ['maskImage', 'maskPosition', 'maskSize', 'maskRepeat', 'maskComposite', 'maskClip', 'maskOrigin',
      'webkitMaskImage', 'webkitMaskPosition', 'webkitMaskSize', 'webkitMaskRepeat', 'webkitMaskComposite', 'webkitMaskClip', 'webkitMaskOrigin']) {
      if (k in s) s[k] = '';
    }
  }
  // starts：本次入场层的起始几何（与 playEnter 的 transform 起点一致），洞从那里随外框一起长到终点。
  // 返回值：本次有被挖的层的那些上层（入场层据此判「压在别的层上」）。
  function updateOccluders(starts) {
    const occluding = new Set();
    const lowers = [fushiHost, ...layers.map(layer => layer.box)];
    const keep = new Set();
    lowers.forEach((element, index) => {
      if (!element || !element.style) return;
      const frame = lowerFrame(element);
      if (!frame) return;
      const above = layers.slice(index).filter(layer => layer.revealed && layer.data.glassBackdrop === true);
      const hits = above.map(layer => ({ layer, rect: layerRect(layer) }))
        .filter(hit => hit.rect && overlaps(hit.rect, frame));
      if (!hits.length) return;
      hits.forEach(hit => occluding.add(hit.layer));
      keep.add(element);
      const s = element.style;
      const images = ['linear-gradient(#000 0 0)', ...hits.map(hit => holeImage(radiusOf(hit.layer) / frame.zoom))].join(', ');
      const to = maskGeometry(frame, hits.map(hit => hit.rect));
      const from = maskGeometry(frame, hits.map(hit =>
        (starts && starts.get(hit.layer)) || hit.layer.holeRect || hit.rect));
      const composite = ['subtract', ...hits.map(() => 'add')].join(', ');
      s.maskImage = images; s.maskPosition = to.position; s.maskSize = to.size;
      s.maskRepeat = 'no-repeat'; s.maskComposite = composite; s.maskClip = 'no-clip'; s.maskOrigin = 'border-box';
      masked.add(element);
      if ((from.position !== to.position || from.size !== to.size) && typeof element.animate === 'function' && !prefersReducedMotion()) {
        try {
          element.animate([
            { maskPosition: from.position, maskSize: from.size },
            { maskPosition: to.position, maskSize: to.size },
          ], { duration: RESIZE_MS, easing: 'cubic-bezier(0.2, 0, 0, 1)' });
        } catch (_) { /* 不支持就直接落终值 */ }
      }
    });
    for (const layer of layers) {
      const r = layerRect(layer);
      if (layer.revealed && r) layer.holeRect = r;
    }
    for (const element of [...masked]) if (!keep.has(element)) clearMask(element);
    return occluding;
  }
  // 入场 transform 起点（translateY(±6px) scale(0.97)，原点在贴词那条边的中点）对应的外框几何。
  function enterStartRect(layer, side) {
    const r = layerRect(layer);
    if (!r) return null;
    const above = side === 'above';
    const ox = r.x + r.w / 2, oy = above ? r.y + r.h : r.y;
    return { x: ox + (r.x - ox) * 0.97, y: oy + (r.y - oy) * 0.97 + (above ? 6 : -6), w: r.w * 0.97, h: r.h * 0.97 };
  }
  // 入场：落点算好、内容首帧已渲染之后才显示，再做一段短促的 opacity + 轻微位移/缩放（从靠近
  // 被查词的一侧长出来）。只动 opacity / transform，不碰尺寸与位置，合成器线程完成；
  // 动画只加在带 backdrop-filter 的外框自身（不在它的任何祖先上：祖先 opacity<1 / transform
  // 会成为 Backdrop Root，模糊只采样到它为止），不设 will-change，结束后不留任何合成层属性。
  // 系统要求减少动态效果时直接出现。
  const ENTER_MS = 180;
  function prefersReducedMotion() {
    try {
      return !!(window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches);
    } catch (_) { return false; }
  }
  // fade=false：本层压在别的层上（下层已挖洞）。淡入期间洞里会直接露出未模糊的网页，
  // 只做 transform（洞随 updateOccluders 的起点几何同步长到终点）。
  function playEnter(box, side, fade) {
    if (typeof box.animate !== 'function' || prefersReducedMotion()) return;
    const above = side === 'above';
    // 缩放原点落在贴词的那条边上：像从被查词处长出来，而不是从中心或左上角。
    box.style.transformOrigin = above ? '50% 100%' : '50% 0%';
    try {
      box.animate([
        { ...(fade === false ? {} : { opacity: 0 }), transform: 'translateY(' + (above ? 6 : -6) + 'px) scale(0.97)' },
        { ...(fade === false ? {} : { opacity: 1 }), transform: 'none' },
      ], {
        duration: ENTER_MS,
        easing: 'cubic-bezier(0.2, 0, 0, 1)',
      });
    } catch (_) { /* WAAPI 不可用：直接显示 */ }
  }
  // 尾批在途时最多等这么久再显示（首词条已渲染、终高未到）。典型尾批在一两帧到几百毫秒内
  // 建完；超过这个时间先显示，避免慢词典把子层卡成「点了没反应」。
  const REVEAL_WAIT_MS = 260;
  const RESIZE_MS = 180;
  function reveal(layer) {
    if (layer.revealed || !layers.includes(layer)) return;
    if (layer.revealTimer) { clearTimeout(layer.revealTimer); layer.revealTimer = null; }
    layer.revealed = true;
    layer.side = layer.placedSide; // 显示即锁边（BUG-2773 同款）
    layer.box.style.visibility = 'visible';
    const start = enterStartRect(layer, layer.side);
    const occluding = updateOccluders(start ? new Map([[layer, start]]) : null);
    playEnter(layer.box, layer.side, !occluding.has(layer));
    // 显示之后的长高 / 夹高走短过渡（落词上方时底边贴词、长高改的是 top，一并过渡）。
    // 显示前的落点不过渡：入场时外框已在终点。
    if (!prefersReducedMotion()) {
      // 先把「本次落点」提交成已计算样式再装过渡：否则终高与过渡在同一次样式计算里生效，
      // 外框会从隐藏期间的首词条高度一路过渡到终高（CfT 实测 187→360px 拉长 170ms）。
      void layer.box.offsetHeight;
      layer.box.style.transition = 'height ' + RESIZE_MS + 'ms cubic-bezier(0.2, 0, 0, 1), top ' +
        RESIZE_MS + 'ms cubic-bezier(0.2, 0, 0, 1)';
    }
  }
  function open(query, anchor, parent, highlight) {
    const term = typeof query === 'string' ? query.trim() : '';
    if (!term || !fushiHost || (parent && !layers.includes(parent))) return;
    dismissAfter(parent);
    const owner = fushiHost;
    const request = ++sequence;
    requests.set(parent, request);
    const cue = parent ? parent.cue : fushiPendingCueWindow;
    chrome.runtime.sendMessage({ type: 'lookup', term }, function (response) {
      if (requests.get(parent) !== request || fushiHost !== owner || (parent && !layers.includes(parent))) return;
      if (chrome.runtime.lastError || !response || !response.ok || !response.data || typeof response.data.popupJson !== 'string') {
        fushiShowConnectionFailure(response);
        return;
      }
      const frame = document.createElement('iframe');
      const matchLength = response.data.result && response.data.result.bestLength;
      if (highlight && Number.isInteger(matchLength) && matchLength > 0) {
        if (parent) send(parent, { type: 'highlight', length: matchLength });
        else if (window.fushiSelection && typeof window.fushiSelection.highlightSelection === 'function') {
          window.fushiSelection.highlightSelection(matchLength);
        }
      }
      frame.title = tr('nested_lookup_title', { term: term });
      frame.setAttribute('allow', 'autoplay');
      const scheme = fushiNestedScheme(response.data.theme);
      // iframe 只负责承载内容：铺满外框、透明底，与 iframe 根同一 color-scheme。
      frame.style.cssText = 'display:block;width:100%;height:100%;border:0;margin:0;background:transparent;' +
        'color-scheme:' + scheme + ';';
      // 外框（定位 / 圆角裁切 / 投影 / 玻璃模糊 / 入场动画都在这一层）：与第一层 #hibiki-popup-host
      // 同级挂在 body（全屏时 fullscreenElement）下，不嵌进第一层，祖先链上没有 Backdrop Root。
      const box = document.createElement('div');
      box.className = 'fushi-nested-layer';
      const glass = fushiNestedGlass(response.data.theme) && fushiNestedBackdropUsable();
      box.style.cssText = 'position:fixed;z-index:2147483647;visibility:hidden;overflow:hidden;' +
        fushiNestedLayerSkin(response.data.theme) +
        (glass ? fushiNestedGlassStyle(scheme) : '');
      if (glass) box.setAttribute('data-fushi-glass', scheme);
      box.appendChild(frame);
      const fallback = (parent ? parent.box : owner).getBoundingClientRect();
      let rect = anchor && Number.isFinite(anchor.x) && Number.isFinite(anchor.y)
        ? { x: anchor.x, y: anchor.y, height: Number(anchor.height) || 18 }
        : { x: fallback.left + 24, y: fallback.top + 24, height: 18 };
      if (parent && anchor) rect = { x: fallback.left + rect.x, y: fallback.top + rect.y, height: rect.height };
      const layer = { frame, box, data: { ...response.data }, anchor: rect, cue, draft: { prev: 0, next: 0 } };
      // 告诉 iframe 内容「外框确实在模糊」：只有收到它，nested-popup.js 才把填充换成半透明
      // 玻璃。宿主没在模糊（墨水屏 / 减少透明度 / 内核不支持 / 旧版宿主脚本）时内容保持不透明，
      // 绝不出现「半透明却不模糊」——那会让背后的网页和父层文字清清楚楚地透出来（2026-10-04 录屏）。
      layer.data.glassBackdrop = glass;
      layer.data.i18nCtx = window.i18nCtx || FUSHI_CTX_I18N;
      layer.data.sentenceContextPreviewEnabled = withContext(layer, () => !!fushiCurrentCueLocation());
      let entries = [];
      try { entries = JSON.parse(layer.data.popupJson); } catch (_) { return; }
      layer.data.queuedExpressions = entries.filter(entry => withContext(layer, () => window.fushiIsEntryQueued(entry))).map(entry => entry.expression);
      layers.push(layer);
      frame.src = frameUrl;
      (document.fullscreenElement || document.body).appendChild(box);
      place(layer);
      updateParents();
    });
  }
  const allowed = new Set(['mineEntry', 'duplicateCheck', 'resolveWordAudio', 'listWordAudioSources', 'openLink', 'openInAnki',
    'setSentenceContext', 'clearSentenceDraft', 'sentenceContextPreview']);
  function receive(layer, message) {
    if (!layers.includes(layer) || !message || message.__fushiPopupFrame !== true) return;
    if (message.type === 'close') {
      const index = layers.indexOf(layer);
      dismissAfter(index > 0 ? layers[index - 1] : null);
      (layers.length ? layers[layers.length - 1].frame : fushiHost)?.focus();
      return;
    }
    if (message.type !== 'call') return;
    const args = Array.isArray(message.args) ? message.args : [];
    let result = null;
    if (message.name === 'onLinkClick' || message.name === 'textSelected') open(args[0], args[1], layer, message.name === 'textSelected');
    else if (message.name === 'tapOutside') dismissAfter(layer);
    else if (message.name === 'popupRendered') {
      // args[3]：nested-popup.js 附上的「尾批仍在途」（popup.js _renderInProgress）。
      const stillRendering = args[3] === true;
      place(layer, args[0], stillRendering);
      // 2026-10-04 22:56 录屏：首发只有首词条（两三行）时就显示，子层先以一条矮条入场、
      // 约半秒后尾批建完又「啪」地一下长到全高。尾批在途时先不显示，等终高那一发再入场；
      // 尾批迟迟不来（大词典慢）时最多等 REVEAL_WAIT_MS 就先显示，此后长高走高度过渡。
      if (layer.revealed) {
        // 已显示：高度变化由外框的 height/top 过渡接住（reveal 里装上），不再跳。
      } else if (stillRendering) {
        if (!layer.revealTimer) layer.revealTimer = setTimeout(() => reveal(layer), REVEAL_WAIT_MS);
      } else {
        reveal(layer);
      }
    } else if (message.name === 'openSentenceContextModal') {
      const oldCue = fushiPendingCueWindow, oldDraft = fushiSentenceCtx;
      fushiPendingCueWindow = layer.cue;
      fushiSentenceCtx = layer.draft;
      window.fushiOpenSentenceContextModal({ ...(args[0] || {}),
        onClose: function () {
          layer.draft = fushiSentenceCtx;
          fushiPendingCueWindow = oldCue;
          fushiSentenceCtx = oldDraft;
        },
        onConfirm: function (entryIndex) { if (layers.includes(layer)) send(layer, { type: 'mine', entryIndex }); },
      });
    } else if (allowed.has(message.name)) {
      result = withContext(layer, () => window.flutter_inappwebview.callHandler(message.name, ...args));
    }
    Promise.resolve(result).then(value => {
      if (layers.includes(layer)) send(layer, { type: 'reply', id: message.id, result: value });
    }, error => {
      if (layers.includes(layer)) send(layer, { type: 'reply', id: message.id, error: String(error) });
    });
  }
  // The public window channel only bootstraps a capability. All commands and
  // replies use the private port, so the website cannot forge popup actions.
  window.addEventListener('message', function (event) {
    const message = event.data;
    if (!message || message.__fushiPopupFrame !== true || message.type !== 'ready' || event.origin !== frameOrigin) return;
    const layer = layers.find(item => item.frame.contentWindow === event.source);
    if (!layer || layer.port) return;
    const channel = new MessageChannel();
    layer.port = channel.port1;
    layer.port.onmessage = event => receive(layer, event.data);
    layer.port.start();
    layer.frame.contentWindow.postMessage(
      { __fushiPopupFrame: true, type: 'connect' }, frameOrigin, [channel.port2]);
    send(layer, { type: 'render', data: layer.data });
    send(layer, { type: 'hasChild', value: layers.indexOf(layer) < layers.length - 1 });
  });
  window.fushiNestedPopups = {
    open: (query, anchor, highlight) => open(query, anchor, null, highlight),
    dismissChildren: () => dismissAfter(null),
    clear: () => { requests.clear(); dismissAfter(null); },
    // 有子层在场：子层是独立 iframe，指针进去后顶层文档收不到事件，content.js 的悬停离开判定据此不关栈。
    active: () => layers.length > 0,
    pop: () => {
      if (!layers.length) return false;
      dismissAfter(layers.length > 1 ? layers[layers.length - 2] : null);
      (layers.length ? layers[layers.length - 1].frame : fushiHost)?.focus();
      return true;
    },
  };
})();
