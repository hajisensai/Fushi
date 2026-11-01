// 网页视频收藏（反馈 KGC1ifR1a3，content script 隔离世界，manifest bundle 里排在 subtitle-panel.js
// 之后、video-shortcuts.js / player-controls.js 之前）。
//
// 看任意视频站（YouTube / niconico / Netflix / 通用 <video>）时，把**当前字幕句**（文本 + 时间点）
// 或**视频本身**收藏进 Fushi App 的收藏夹——与 App 内收藏是同一份数据：消息经 background.js 转发到
// App 的 POST /api/extension/video-favorite，写的是 App 的收藏句存储；App 收藏夹里标明来源网站，
// 并能跳回原网页的时间点。
//
// 三个入口共用本模块的执行端，不各写一份：
//  · 播放器内 Fushi 菜单（player-controls.js）：「收藏当前句」「收藏这个视频」两项；
//  · 快捷键（video-shortcuts.js 的 favorite-cue，默认 Ctrl+Shift+F）→ subtitle-panel.js 的
//    fushiSubtitleShortcut('favorite-cue') → 这里的 toggleCurrentCue；
//  · 字幕侧边栏（side-panel.js）：每行 ☆/★ + 顶栏「收藏这个视频」，经 tab 消息 fushiVideoFavorite*。
// 已收藏状态以 App 回包为准（本地只缓存「这个页面地址」那一份），换视频（地址变了）即重新拉取。
//
// 身份规范化（去 t= 等时间参数、youtu.be → watch?v=）只在 App 侧做一次（单一真相源）；
// 这里只把 location.href 原样交出去，判「是不是这一句」用 App 回来的 {text,startMs}。
(function (root, factory) {
  var api = factory();
  try { if (typeof module !== 'undefined' && module.exports) module.exports = api; } catch (_) { /* no-op */ }
  if (root) root.FUSHI_VIDEO_FAVORITE = api;
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  // ────────────────────────────── 纯函数区（node 可测） ──────────────────────────────

  // 一句字幕的身份：起点毫秒（取整）+ 去首尾空白的文本。与 App 侧匹配口径一致
  // （FavoriteSentenceRepository：text + bookKey + normCharOffset）。
  function cueKey(text, startMs) {
    var ms = typeof startMs === 'number' && isFinite(startMs) ? Math.round(startMs) : '';
    return ms + '|' + String(text == null ? '' : text).trim();
  }

  function isWebUrl(href) {
    return /^https?:\/\//i.test(String(href || ''));
  }

  // 切换消息（background.js 'videoFavorite'）。kind = 'sentence' | 'video'；cue = {text,startMs,endMs}。
  // 句子收藏没有句子文本 → null（调用方提示「现在没有字幕」，不发请求）。
  function toggleMessage(kind, href, title, cue) {
    if (!isWebUrl(href)) return null;
    var msg = { type: 'videoFavorite', op: 'toggle', kind: kind === 'video' ? 'video' : 'sentence', url: String(href), title: String(title || '') };
    if (msg.kind === 'sentence') {
      var text = cue && cue.text != null ? String(cue.text).trim() : '';
      if (!text) return null;
      msg.text = text;
      if (typeof cue.startMs === 'number' && isFinite(cue.startMs)) msg.startMs = Math.round(cue.startMs);
      if (typeof cue.endMs === 'number' && isFinite(cue.endMs)) msg.endMs = Math.round(cue.endMs);
    }
    return msg;
  }

  function stateMessage(href) {
    if (!isWebUrl(href)) return null;
    return { type: 'videoFavorite', op: 'state', url: String(href) };
  }

  // background 回包 → {ok, status, favorite, video, keys:{cueKey:true}}。坏回包一律 ok:false。
  function parseResponse(resp) {
    var out = { ok: false, status: resp && typeof resp.status === 'number' ? resp.status : 0, favorite: null, video: false, keys: Object.create(null) };
    var data = resp && resp.ok ? resp.data : null;
    if (!data || typeof data.video !== 'boolean' || !Array.isArray(data.sentences)) return out;
    out.ok = true;
    out.video = data.video;
    if (typeof data.favorite === 'boolean') out.favorite = data.favorite;
    for (var i = 0; i < data.sentences.length; i++) {
      var s = data.sentences[i];
      if (s && typeof s.text === 'string') out.keys[cueKey(s.text, s.startMs)] = true;
    }
    return out;
  }

  // 切换后的提示文案键（toast）。失败分「旧 App 没这个端点（404）」与「连不上」两种出路。
  function toastKey(kind, parsed) {
    if (!parsed || !parsed.ok) return parsed && parsed.status === 404 ? 'favorite_failed_old_app' : 'favorite_failed';
    if (kind === 'video') return parsed.favorite ? 'vfav_video_added' : 'vfav_video_removed';
    return parsed.favorite ? 'vfav_line_added' : 'vfav_line_removed';
  }

  var api = {
    cueKey: cueKey,
    toggleMessage: toggleMessage,
    stateMessage: stateMessage,
    parseResponse: parseResponse,
    toastKey: toastKey,
  };

  // ────────────────────────────── 浏览器运行时 ──────────────────────────────
  if (typeof window === 'undefined' || typeof document === 'undefined') return api;
  if (typeof location !== 'undefined' && location && location.protocol === 'chrome-extension:') return api;

  function tr(key, params) {
    return typeof window.fushiT === 'function' ? window.fushiT(key, params) : key;
  }
  function toast(text) {
    try { if (typeof window.fushiToast === 'function') window.fushiToast(text); } catch (_) { /* no-op */ }
  }

  // 拉取失败（App 没开 / 旧 App 404）后的退避：同一地址 30 秒内不再自动拉，免得视频页每 2 秒
  // 打一次连不上的请求。用户主动点收藏不受退避限制。
  var RETRY_AFTER_MS = 30000;
  var st = { href: '', loaded: false, video: false, keys: Object.create(null), rev: 0, inflight: null, failedAt: 0 };
  var listeners = [];

  function notify() {
    st.rev++;
    for (var i = 0; i < listeners.length; i++) {
      try { listeners[i](snapshot()); } catch (_) { /* no-op */ }
    }
  }

  function adopt(href, parsed) {
    if (href !== st.href) return;
    if (!parsed.ok) { st.failedAt = Date.now(); return; }
    st.failedAt = 0;
    st.loaded = true;
    st.video = parsed.video;
    st.keys = parsed.keys;
    notify();
  }

  function send(msg) {
    return new Promise(function (resolve) {
      try {
        var p = chrome.runtime.sendMessage(msg, function (resp) {
          // 读一次 lastError，免得「无接收端」被 Chrome 记成未处理错误。
          try { void chrome.runtime.lastError; } catch (_) { /* no-op */ }
          resolve(resp || null);
        });
        if (p && typeof p.then === 'function') p.then(function (r) { if (r) resolve(r); }, function () { resolve(null); });
      } catch (_) {
        resolve(null);
      }
    });
  }

  // 当前页面地址的收藏状态。地址变了（SPA 换集 / 换视频）先清空再拉。
  function refresh(force) {
    var href = String(location.href || '');
    if (href !== st.href) {
      st.href = href;
      st.loaded = false;
      st.video = false;
      st.keys = Object.create(null);
      st.failedAt = 0;
      notify();
      force = true;
    }
    if (!force && (st.loaded || st.inflight)) return st.inflight || Promise.resolve(snapshot());
    var msg = stateMessage(href);
    if (!msg) return Promise.resolve(snapshot());
    var p = send(msg).then(function (resp) {
      if (st.inflight === p) st.inflight = null;
      adopt(href, parseResponse(resp));
      return snapshot();
    });
    st.inflight = p;
    return p;
  }

  function snapshot() {
    var keys = [];
    for (var k in st.keys) keys.push(k);
    return { href: st.href, loaded: st.loaded, video: st.video, keys: keys, rev: st.rev };
  }

  function isCueFavorited(cue) {
    if (!cue) return false;
    if (String(location.href || '') !== st.href) refresh(true);
    return !!st.keys[cueKey(cue.text, cue.startMs)];
  }

  function pageTitle() {
    try { return String(document.title || ''); } catch (_) { return ''; }
  }

  // 切换收藏。回 Promise<bool|null>：切换后的状态；null = 没收藏上（已 toast 说明原因）。
  function toggle(kind, cue) {
    var href = String(location.href || '');
    var msg = toggleMessage(kind, href, pageTitle(), cue);
    if (!msg) {
      toast(tr(kind === 'video' ? 'favorite_failed' : 'vfav_no_line'));
      return Promise.resolve(null);
    }
    if (href !== st.href) refresh(true);
    return send(msg).then(function (resp) {
      var parsed = parseResponse(resp);
      var key = toastKey(kind, parsed);
      toast((parsed.ok ? '' : '✗ ') + tr(key));
      if (!parsed.ok) return null;
      adopt(href, parsed);
      return parsed.favorite;
    });
  }

  function currentCue() {
    try {
      return typeof window.fushiSubtitleCurrentCue === 'function' ? window.fushiSubtitleCurrentCue() : null;
    } catch (_) {
      return null;
    }
  }

  // 快捷键 / 菜单「收藏当前句」：同步回「接管了没有」（快捷键据此 preventDefault），结果异步 toast。
  function toggleCurrentCue() {
    var cue = currentCue();
    if (!cue) {
      toast(tr('vfav_no_line'));
      return false;
    }
    toggle('sentence', cue);
    return true;
  }

  window.fushiVideoFavorite = {
    refresh: refresh,
    snapshot: snapshot,
    isCueFavorited: isCueFavorited,
    isVideoFavorited: function () { return st.href === String(location.href || '') && st.video; },
    currentCue: currentCue,
    toggleCue: function (cue) { return toggle('sentence', cue); },
    toggleCurrentCue: toggleCurrentCue,
    toggleVideo: function () { return toggle('video', null); },
    onChange: function (fn) { if (typeof fn === 'function') listeners.push(fn); },
  };

  // 字幕侧边栏（扩展页，不在本页面世界里）经 tab 消息调同一份执行端。
  try {
    chrome.runtime.onMessage.addListener(function (msg, _sender, sendResponse) {
      if (!msg || typeof msg.type !== 'string' || msg.type.indexOf('fushiVideoFavorite') !== 0) return false;
      var done = function () { sendResponse({ ok: true, favorites: snapshot() }); };
      if (msg.type === 'fushiVideoFavoriteState') {
        refresh(msg.force === true).then(done, done);
        return true;
      }
      if (msg.type === 'fushiVideoFavoriteToggleCue') {
        toggle('sentence', msg.cue || null).then(done, done);
        return true;
      }
      if (msg.type === 'fushiVideoFavoriteToggleVideo') {
        toggle('video', null).then(done, done);
        return true;
      }
      return false;
    });
  } catch (_) { /* no-op */ }

  // 地址变化（SPA 换视频）后懒拉：有 <video> 的页面才问 App，不给普通网页添请求。
  setInterval(function () {
    var same = String(location.href || '') === st.href;
    if (same && (st.loaded || (st.failedAt && Date.now() - st.failedAt < RETRY_AFTER_MS))) return;
    if (!document.querySelector('video')) return;
    refresh(false);
  }, 2000);

  return api;
});
