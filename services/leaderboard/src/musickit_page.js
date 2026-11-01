// MusicKit JS 托管页（Apple Music 集成方案 §3.6 / P3「网页桥」，docs/specs/2026-10-31-apple-music-musickit.md）。
//
//   GET /musickit/            → 页面壳（无内联脚本）
//   GET /musickit/bridge.js   → 桥接脚本：window.fushiMusicKit（同源取 /v1/musickit/token → MusicKit.configure）
//
// 为什么要托管：MusicKit JS 的 authorize()（Apple ID 登录）只认 https 页面，file:// / 自定义 scheme 不行；
// Windows（WebView2）与 Android（WebView）的隐藏 WebView 加载这一页，由 Dart 经 evaluateJavascript 调桥、
// 经宿主消息通道收事件。整曲 DRM 由浏览器 CDM 解，Fushi 不碰音频数据。
//
// 安全：与 /dev 同源。/dev 的会话 cookie 是 HttpOnly + Path=/dev + SameSite=Strict，页面脚本读不到；
// CSP 只放行本站与 Apple 域名的脚本 / 连接，不允许内联脚本、不允许被嵌入。

/** MusicKit JS v3 官方 CDN。 */
export const MUSICKIT_JS_URL = 'https://js-cdn.music.apple.com/musickit/v3/musickit.js';

/** 页面 CSP（导出供测试钉住）。 */
export const MUSICKIT_PAGE_CSP = [
  "default-src 'none'",
  "script-src 'self' https://js-cdn.music.apple.com",
  "connect-src 'self' https://*.apple.com https://*.itunes.apple.com https://*.mzstatic.com",
  "media-src 'self' blob: https:",
  "img-src 'self' data: blob: https:",
  "style-src 'unsafe-inline' https://js-cdn.music.apple.com",
  "font-src https://js-cdn.music.apple.com",
  "worker-src 'self' blob:",
  "frame-src https://*.apple.com",
  "base-uri 'none'",
  "form-action 'none'",
  "frame-ancestors 'none'",
].join('; ');

const PAGE_HTML = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>Fushi MusicKit</title>
<style>
  body { font: 14px/1.5 system-ui, sans-serif; margin: 16px; color: #222; background: #fff; }
  @media (prefers-color-scheme: dark) { body { color: #ddd; background: #111; } }
  #debug { display: none; gap: 8px; flex-wrap: wrap; align-items: center; }
  #debug input { width: 14em; }
  #log { white-space: pre-wrap; font: 12px/1.4 ui-monospace, monospace; max-height: 60vh; overflow: auto; }
  /* MusicKit 出错时会自己弹页面内对话框（实测：自动播放被拦时弹「play() failed …」并盖住整页）；
     隐藏 WebView 里没人能点，错误一律走桥接事件。?debug=1 时由 bridge.js 加 class 放出来。 */
  html:not(.fushi-debug) #musickit-dialog, html:not(.fushi-debug) #musickit-dialog-scrim { display: none !important; }
</style>
</head>
<body>
<p>Fushi · Apple Music bridge</p>
<div id="debug">
  <button id="d-init">init</button>
  <button id="d-auth">authorize</button>
  <button id="d-unauth">unauthorize</button>
  <input id="d-song" placeholder="catalog song id">
  <button id="d-play">play</button>
  <button id="d-pause">pause</button>
  <button id="d-resume">resume</button>
  <button id="d-stop">stop</button>
  <button id="d-state">state</button>
</div>
<div id="log"></div>
<script src="${MUSICKIT_JS_URL}" data-web-components async></script>
<script src="/musickit/bridge.js"></script>
</body>
</html>
`;

// 桥接脚本。Dart 侧只依赖 window.fushiMusicKit 的方法签名与事件形状（type 字段），改动须同步 app 侧。
const BRIDGE_JS = `'use strict';
(() => {
  const VERSION = 1;
  /** @type {any} */
  let music = null;
  let configuring = null;

  // ---- 发事件给宿主：InAppWebView（callHandler）/ WebView2（chrome.webview）/ 普通浏览器（CustomEvent） ----
  function emit(type, detail) {
    const msg = Object.assign({ type, v: VERSION, at: Date.now() }, detail || {});
    try {
      const iaw = window.flutter_inappwebview;
      if (iaw && typeof iaw.callHandler === 'function') iaw.callHandler('fushiMusicKit', msg);
    } catch (_) {}
    try {
      const wv = window.chrome && window.chrome.webview;
      if (wv && typeof wv.postMessage === 'function') wv.postMessage(msg);
    } catch (_) {}
    window.dispatchEvent(new CustomEvent('fushi-musickit', { detail: msg }));
    debugLog(msg);
  }

  function errInfo(e) {
    if (!e) return { name: 'Error', message: 'unknown' };
    return { name: String(e.name || e.errorCode || 'Error'), message: String(e.message || e.description || e) };
  }

  function waitForMusicKit() {
    if (window.MusicKit) return Promise.resolve();
    return new Promise((resolve, reject) => {
      const t = setTimeout(() => reject(new Error('musickit_js_load_timeout')), 20000);
      document.addEventListener('musickitloaded', () => { clearTimeout(t); resolve(); }, { once: true });
    });
  }

  async function fetchToken() {
    const r = await fetch('/v1/musickit/token', { cache: 'no-store', credentials: 'omit' });
    if (!r.ok) throw new Error('token_http_' + r.status);
    const j = await r.json();
    if (!j || typeof j.token !== 'string') throw new Error('token_bad_response');
    return j.token;
  }

  // 系统媒体会话（SMTC / Android MediaSession）由 app 自己的会话负责：把网页的 mediaSession 清空，
  // 免得系统里出现第二个「正在播放」条目（方案 §3.4，P0 实测项）。
  function muteMediaSession() {
    const ms = navigator.mediaSession;
    if (!ms) return;
    try { ms.metadata = null; } catch (_) {}
    for (const a of ['play', 'pause', 'stop', 'seekbackward', 'seekforward', 'seekto', 'previoustrack', 'nexttrack']) {
      try { ms.setActionHandler(a, null); } catch (_) {}
    }
  }

  function snapshot() {
    if (!music) return { configured: false };
    const item = music.nowPlayingItem;
    return {
      configured: true,
      authorized: !!music.isAuthorized,
      storefront: music.storefrontId || null,
      state: music.playbackState,
      positionMs: Math.round((music.currentPlaybackTime || 0) * 1000),
      durationMs: Math.round((music.currentPlaybackDuration || 0) * 1000),
      songId: item ? String(item.id) : null,
    };
  }

  function wire(m) {
    const E = window.MusicKit.Events || {};
    const on = (name, fn) => { if (name) m.addEventListener(name, fn); };
    on(E.playbackStateDidChange || 'playbackStateDidChange', () => { muteMediaSession(); emit('state', snapshot()); });
    on(E.playbackTimeDidChange || 'playbackTimeDidChange', () => emit('time', snapshot()));
    on(E.nowPlayingItemDidChange || 'nowPlayingItemDidChange', () => { muteMediaSession(); emit('item', snapshot()); });
    on(E.authorizationStatusDidChange || 'authorizationStatusDidChange', () => emit('auth', snapshot()));
    on(E.mediaPlaybackError || 'mediaPlaybackError', (e) => emit('error', errInfo(e)));
  }

  // storefront 不指定（2026-11-01 实测）：未登录时给 MusicKit JS 指定 jp（configure 传 storefrontId 或事后赋值）
  // 都会让 setQueue 报 CONTENT_EQUIVALENT，不指定（默认 us）则正常；catalog id 全球通用，试听照放。
  // 登录后 MusicKit 用 Apple ID 账户的地区。曲目元数据由 Dart 侧按设置的 storefront 取，不经这里。
  async function init() {
    if (music) return snapshot();
    if (!configuring) {
      configuring = (async () => {
        await waitForMusicKit();
        const developerToken = await fetchToken();
        const m = await window.MusicKit.configure({ developerToken, app: { name: 'Fushi', build: String(VERSION) } });
        wire(m);
        music = m;
        muteMediaSession();
        return snapshot();
      })().catch((e) => { configuring = null; throw e; });
    }
    return configuring;
  }

  function need() {
    if (!music) throw new Error('not_configured');
    return music;
  }

  /** 统一包一层：成功 {ok:true, ...}，失败 {ok:false, error}（Dart 侧 evaluateJavascript 拿得到 JSON）。 */
  function api(fn) {
    return async (...args) => {
      try {
        const r = await fn(...args);
        return Object.assign({ ok: true }, r || {});
      } catch (e) {
        const error = errInfo(e);
        emit('error', error);
        return { ok: false, error };
      }
    };
  }

  window.fushiMusicKit = Object.freeze({
    version: VERSION,
    init: api(init),
    authorize: api(async () => { await init(); await need().authorize(); return snapshot(); }),
    unauthorize: api(async () => { await init(); await need().unauthorize(); return snapshot(); }),
    // 单曲队列：Fushi 自己的队列是唯一真相，这里一次只放一首（方案 §3.3）。
    play: api(async (songId, startMs) => {
      await init();
      const m = need();
      await m.setQueue({ song: String(songId), startPlaying: false });
      if (startMs > 0) await m.seekToTime(startMs / 1000);
      await m.play();
      return snapshot();
    }),
    pause: api(async () => { need().pause(); return snapshot(); }),
    resume: api(async () => { await need().play(); return snapshot(); }),
    stop: api(async () => { need().stop(); return snapshot(); }),
    seek: api(async (ms) => { await need().seekToTime(ms / 1000); return snapshot(); }),
    setVolume: api(async (v) => { need().volume = Math.max(0, Math.min(1, Number(v) || 0)); return snapshot(); }),
    state: api(async () => snapshot()),
  });

  // ---- ?debug=1：手动调试面板（P0 实测用；正常加载时不显示） ----
  const debug = new URLSearchParams(location.search).get('debug') === '1';
  function debugLog(msg) {
    if (!debug || msg.type === 'time') return;
    const el = document.getElementById('log');
    if (el) el.textContent = JSON.stringify(msg) + '\\n' + el.textContent;
  }
  if (debug) {
    document.documentElement.classList.add('fushi-debug');
    document.addEventListener('DOMContentLoaded', () => {
      document.getElementById('debug').style.display = 'flex';
      const k = window.fushiMusicKit;
      const bind = (id, fn) => document.getElementById(id).addEventListener('click', async () => debugLog({ type: 'result', id, r: await fn() }));
      bind('d-init', () => k.init());
      bind('d-auth', () => k.authorize());
      bind('d-unauth', () => k.unauthorize());
      bind('d-play', () => k.play(document.getElementById('d-song').value.trim(), 0));
      bind('d-pause', () => k.pause());
      bind('d-resume', () => k.resume());
      bind('d-stop', () => k.stop());
      bind('d-state', () => k.state());
    });
  }
  emit('ready', {});
})();
`;

/**
 * 是否 MusicKit 托管页路径。
 * @param {string} path
 * @returns {boolean}
 */
export function isMusicKitPagePath(path) {
  return path === '/musickit' || path === '/musickit/' || path === '/musickit/bridge.js';
}

/**
 * @param {string} path
 * @returns {Response}
 */
export function renderMusicKitPage(path) {
  if (path === '/musickit') {
    return new Response(null, { status: 301, headers: { Location: '/musickit/' } });
  }
  const common = {
    'X-Content-Type-Options': 'nosniff',
    'Referrer-Policy': 'no-referrer',
    // 桥接脚本与 app 版本强相关：不让边缘 / WebView 长期缓存旧版。
    'Cache-Control': 'no-cache',
  };
  if (path === '/musickit/bridge.js') {
    return new Response(BRIDGE_JS, {
      headers: { ...common, 'Content-Type': 'text/javascript; charset=utf-8' },
    });
  }
  return new Response(PAGE_HTML, {
    headers: {
      ...common,
      'Content-Type': 'text/html; charset=utf-8',
      'Content-Security-Policy': MUSICKIT_PAGE_CSP,
    },
  });
}
