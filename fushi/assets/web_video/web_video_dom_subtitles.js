// Fushi 内置网页播放器 · 窗口宿主档（4K）的页面内字幕层。
//
// 窗口宿主档下 WebView2 是真 HWND 子窗口，Flutter 画不到它上面，所以字幕叠层直接注入页面 DOM：
// 从 providers store（window.fushiEpisodeCues，与浏览器扩展同一份）取 Dart 选定的轨，按 <video>
// 当前时间渲染当前 cue，逐字形（grapheme）包 <span>，点击 / 悬停把「句子 + 字形下标 + 字形视口
// 矩形 + 视口屏幕位置」经 callHandler('fushiWebVideo', {type:'lookup'}) 交给 Dart：分词仍在 Dart
// （subtitleLookupTerm），查词卡走独立顶层窗口。本脚本不查词、不动站点 DOM 其它部分。
//
// 纯逻辑（graphemes / cueAt / buildPayload）挂在 __fushiDomSubs._pure 供 node 测试。
(function () {
  if (window.__fushiDomSubs) return;
  var HANDLER = 'fushiWebVideo';
  var EL_ID = 'fushi-dom-subtitle';
  var st = {
    key: null, cues: [], enabled: false, el: null, line: null, cue: null,
    hoverAuto: false, lastX: -1, lastY: -1, lastHoverIndex: -1,
    fontFamily: '', fontPx: 0, delayMs: 0, timer: null,
  };

  function graphemes(text) {
    var s = String(text == null ? '' : text);
    try {
      if (typeof Intl !== 'undefined' && Intl.Segmenter) {
        var seg = new Intl.Segmenter(undefined, { granularity: 'grapheme' });
        var out = [];
        var it = seg.segment(s)[Symbol.iterator]();
        for (var r = it.next(); !r.done; r = it.next()) out.push(r.value.segment);
        return out;
      }
    } catch (_) {}
    return Array.from(s);
  }

  // cues 按 startMs 升序（providers 保证）；取覆盖 ms 的那条（最后一条 startMs <= ms 且 endMs > ms）。
  function cueAt(cues, ms) {
    if (!cues || !cues.length) return null;
    var lo = 0, hi = cues.length - 1, idx = -1;
    while (lo <= hi) {
      var mid = (lo + hi) >> 1;
      if (cues[mid].startMs <= ms) { idx = mid; lo = mid + 1; } else { hi = mid - 1; }
    }
    if (idx < 0) return null;
    var c = cues[idx];
    return c.endMs > ms ? c : null;
  }

  function buildPayload(kind, cue, index, rect, screenX, screenY, dpr) {
    return {
      type: 'lookup', kind: kind, sentence: String(cue.text || ''), index: index,
      cueStart: cue.startMs, cueEnd: cue.endMs,
      rect: { x: rect.left, y: rect.top, w: rect.width, h: rect.height },
      screenX: screenX, screenY: screenY, dpr: dpr,
    };
  }

  function post(payload) {
    try {
      if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
        window.flutter_inappwebview.callHandler(HANDLER, payload);
      }
    } catch (_) {}
  }

  function videoTimeMs() {
    var v = document.querySelector('video');
    return v && isFinite(v.currentTime) ? Math.round(v.currentTime * 1000) : 0;
  }

  function parentForOverlay() {
    return document.fullscreenElement || document.body || document.documentElement;
  }

  function applyStyle() {
    if (!st.line) return;
    var s = st.line.style;
    if (st.fontFamily) s.fontFamily = st.fontFamily;
    s.fontSize = (st.fontPx > 0 ? st.fontPx : 34) + 'px';
  }

  function spanAt(target) {
    var t = target;
    while (t && t !== st.line) {
      if (t.dataset && t.dataset.fushiG != null) return t;
      t = t.parentNode;
    }
    return null;
  }

  function onClick(e) {
    var span = st.cue && spanAt(e.target);
    if (!span) return;
    e.stopPropagation();
    if (e.preventDefault) e.preventDefault();
    post(buildPayload('click', st.cue, +span.dataset.fushiG, span.getBoundingClientRect(),
      window.screenX, window.screenY, window.devicePixelRatio || 1));
  }

  function onMove(e) {
    if (!st.hoverAuto || !st.cue) return;
    if (Math.abs(e.clientX - st.lastX) < 4 && Math.abs(e.clientY - st.lastY) < 4) return;
    st.lastX = e.clientX; st.lastY = e.clientY;
    var span = spanAt(e.target);
    if (!span) return;
    var index = +span.dataset.fushiG;
    if (index === st.lastHoverIndex) return;
    st.lastHoverIndex = index;
    post(buildPayload('hover', st.cue, index, span.getBoundingClientRect(),
      window.screenX, window.screenY, window.devicePixelRatio || 1));
  }

  function ensureEl() {
    if (!st.el) {
      var el = document.createElement('div');
      el.id = EL_ID;
      var es = el.style;
      es.position = 'fixed'; es.left = '0'; es.right = '0'; es.bottom = '7%';
      es.textAlign = 'center'; es.zIndex = '2147483647'; es.pointerEvents = 'none';
      var line = document.createElement('span');
      var ls = line.style;
      ls.display = 'inline-block'; ls.pointerEvents = 'auto'; ls.cursor = 'pointer';
      ls.color = '#fff'; ls.background = 'rgba(0,0,0,.55)'; ls.padding = '4px 12px';
      ls.borderRadius = '6px'; ls.lineHeight = '1.35'; ls.whiteSpace = 'pre-wrap';
      ls.textShadow = '0 0 4px #000'; ls.maxWidth = '80vw';
      line.addEventListener('click', onClick, true);
      line.addEventListener('mousemove', onMove);
      line.addEventListener('mouseleave', function () { st.lastHoverIndex = -1; st.lastX = -1; st.lastY = -1; });
      el.appendChild(line);
      st.el = el; st.line = line;
      applyStyle();
    }
    var parent = parentForOverlay();
    if (parent && st.el.parentNode !== parent) parent.appendChild(st.el);
    return st.el;
  }

  function render(cue) {
    if (cue === st.cue) return;
    st.cue = cue;
    st.lastHoverIndex = -1;
    if (!cue) {
      if (st.el && st.el.parentNode) st.el.parentNode.removeChild(st.el);
      return;
    }
    ensureEl();
    while (st.line.firstChild) st.line.removeChild(st.line.firstChild);
    var gs = graphemes(cue.text);
    for (var i = 0; i < gs.length; i++) {
      var span = document.createElement('span');
      span.dataset.fushiG = String(i);
      span.textContent = gs[i];
      st.line.appendChild(span);
    }
  }

  function tick() {
    if (!st.enabled) return;
    render(cueAt(st.cues, videoTimeMs() + st.delayMs));
  }

  function readTrack() {
    var store = window.fushiEpisodeCues || {};
    var v = st.key ? store[st.key] : null;
    st.cues = Array.isArray(v) ? v : (v && Array.isArray(v.cues) ? v.cues : []);
    st.cue = undefined; // 强制重绘（同一 cue 对象在换轨后也可能变）
    tick();
  }

  function setEnabled(on) {
    st.enabled = !!on;
    if (st.enabled && !st.timer) st.timer = setInterval(tick, 100);
    if (!st.enabled) {
      if (st.timer) { clearInterval(st.timer); st.timer = null; }
      render(null);
    }
    return st.enabled;
  }

  try {
    document.addEventListener('fullscreenchange', function () { if (st.el && st.cue) ensureEl(); });
  } catch (_) {}

  window.__fushiDomSubs = {
    setTrack: function (key) { st.key = key || null; readTrack(); return st.cues.length; },
    refresh: function () { readTrack(); return st.cues.length; },
    setEnabled: setEnabled,
    setHoverAuto: function (on) { st.hoverAuto = !!on; return st.hoverAuto; },
    setStyle: function (opts) {
      opts = opts || {};
      if (typeof opts.fontFamily === 'string') st.fontFamily = opts.fontFamily;
      if (typeof opts.fontPx === 'number') st.fontPx = opts.fontPx;
      applyStyle();
      return true;
    },
    setDelay: function (ms) { st.delayMs = +ms || 0; return st.delayMs; },
    current: function () { return st.cue ? { startMs: st.cue.startMs, endMs: st.cue.endMs, text: st.cue.text } : null; },
    _pure: { graphemes: graphemes, cueAt: cueAt, buildPayload: buildPayload },
    _st: st,
  };
})();
