import vm from 'node:vm';
import { describe, expect, it, vi } from 'vitest';
import { call, makeEnv } from './harness.js';
import { MUSICKIT_JS_URL, MUSICKIT_PAGE_CSP } from '../src/musickit_page.js';

/** 在最小 window/document 替身里跑 bridge.js，配一个假 MusicKit。 */
function runBridge(source, { tokenStatus = 200, fetchImpl = null, configureImpl = null } = {}) {
  const posted = [];
  const listeners = {};
  const mediaSession = { metadata: { title: 'x' }, handlers: {}, setActionHandler(a, h) { this.handlers[a] = h; } };
  const calls = [];
  const instance = {
    isAuthorized: false,
    storefrontId: 'us',
    playbackState: 0,
    currentPlaybackTime: 0,
    currentPlaybackDuration: 0,
    nowPlayingItem: null,
    volume: 1,
    addEventListener(name, fn) { (listeners[name] ||= []).push(fn); },
    async authorize() { calls.push(['authorize']); this.isAuthorized = true; },
    async unauthorize() { this.isAuthorized = false; },
    async setQueue(q) {
      calls.push(['setQueue', q]);
      if (q.song === 'bad') throw Object.assign(new Error('CONTENT_UNAVAILABLE'), { name: 'MKError' });
      if (q.station) {
        this.nowPlayingItem = {
          id: 'i.1', type: 'song', title: 'S1', artistName: 'A1', albumName: 'AL1',
          playbackDuration: 180000, playParams: { id: 'i.1', kind: 'song', catalogId: '111' },
          attributes: { artwork: { url: 'https://x/{w}x{h}bb.jpg' } },
        };
      } else {
        this.nowPlayingItem = { id: q.song };
      }
      (listeners.nowPlayingItemDidChange || []).forEach((f) => f());
    },
    async skipToNextItem() {
      calls.push(['skipToNextItem']);
      this.nowPlayingItem = { id: 'ra.live', type: 'stations', title: 'Live Show', playParams: { id: 'ra.live', kind: 'radioStation' } };
      (listeners.nowPlayingItemDidChange || []).forEach((f) => f());
    },
    async seekToTime(s) { calls.push(['seek', s]); this.currentPlaybackTime = s; },
    async play() { calls.push(['play']); this.playbackState = 2; (listeners.playbackStateDidChange || []).forEach((f) => f()); },
    pause() { this.playbackState = 3; },
    stop() { this.playbackState = 0; },
  };
  const window = {
    MusicKit: {
      Events: { playbackStateDidChange: 'playbackStateDidChange', mediaPlaybackError: 'mediaPlaybackError', nowPlayingItemDidChange: 'nowPlayingItemDidChange' },
      async configure(opts) {
        calls.push(['configure', opts]);
        if (configureImpl) return configureImpl(opts);
        if (opts.storefrontId) instance.storefrontId = opts.storefrontId;
        return instance;
      },
    },
    flutter_inappwebview: { callHandler: (name, msg) => posted.push([name, msg]) },
    dispatchEvent() {},
  };
  const sandbox = {
    window,
    navigator: { mediaSession },
    location: { search: '' },
    document: { addEventListener() {}, getElementById() { return null; }, documentElement: { classList: { add() {} } } },
    CustomEvent: class { constructor(type, init) { this.type = type; this.detail = init?.detail; } },
    URLSearchParams,
    setTimeout,
    clearTimeout,
    AbortController,
    fetch: async (url, init) => {
      calls.push(['fetch', url, init]);
      if (fetchImpl) return fetchImpl(url, init);
      return { ok: tokenStatus === 200, status: tokenStatus, json: async () => ({ token: 'dev-token', expiresAt: 1 }) };
    },
    Promise,
    Object,
    Error,
    JSON,
    Math,
    Number,
    String,
    Date,
  };
  vm.runInNewContext(source, sandbox);
  return { k: window.fushiMusicKit, posted, calls, mediaSession, instance };
}

describe('MusicKit 托管页', () => {
  it('/musickit/ 是带严格 CSP、无内联脚本的页面；/musickit 301 到带斜杠', async () => {
    const env = makeEnv();
    const r = await call(env, 'GET', '/musickit/');
    expect(r.status).toBe(200);
    expect(r.res.headers.get('Content-Type')).toContain('text/html');
    const csp = r.res.headers.get('Content-Security-Policy');
    expect(csp).toBe(MUSICKIT_PAGE_CSP);
    // Apple 授权弹窗按 referrer 认 opener；no-referrer 会让登录 token 回不来（FK0EFFDLIS）。
    expect(r.res.headers.get('Referrer-Policy')).toBe('strict-origin');
    expect(csp).toContain("frame-ancestors 'none'");
    expect(csp).not.toContain("'unsafe-inline' 'self'");
    expect(csp).toMatch(/script-src 'self' https:\/\/js-cdn\.music\.apple\.com(;|$)/);
    const html = String(r.data);
    expect(html).toContain(`src="${MUSICKIT_JS_URL}"`);
    // MusicKit 自带对话框在非调试模式下隐藏（隐藏 WebView 里没人能点）。
    expect(html).toContain('html:not(.fushi-debug) #musickit-dialog-scrim');
    // 所有 <script> 都带 src（CSP 不放行内联脚本）。
    for (const tag of html.match(/<script\b[^>]*>/g)) expect(tag).toMatch(/\bsrc="/);

    const redirect = await call(env, 'GET', '/musickit');
    expect(redirect.status).toBe(301);
    expect(redirect.res.headers.get('Location')).toBe('/musickit/');
  });

  it('bridge.js：同源取 token → configure，单曲播放、错误包装成 {ok:false}、事件发给宿主、清空 mediaSession', async () => {
    const env = makeEnv();
    const r = await call(env, 'GET', '/musickit/bridge.js');
    expect(r.status).toBe(200);
    expect(r.res.headers.get('Content-Type')).toContain('text/javascript');
    expect(r.res.headers.get('Cache-Control')).toBe('no-cache');

    const b = runBridge(String(r.data));
    expect(b.posted[0][0]).toBe('fushiMusicKit');
    expect(b.posted[0][1].type).toBe('ready');

    expect(await b.k.state()).toEqual({ ok: true, configured: false });
    const played = await b.k.play('1513425337', 5000);
    expect(played.ok).toBe(true);
    expect(played.songId).toBe('1513425337');
    expect(played.positionMs).toBe(5000);
    const fetchCall = b.calls.find((c) => c[0] === 'fetch');
    expect(fetchCall[1]).toBe('/v1/musickit/token');
    expect(fetchCall[2].credentials).toBe('omit');
    const config = b.calls.find((c) => c[0] === 'configure')[1];
    expect(config.developerToken).toBe('dev-token');
    // 不指定 storefront：未登录时指定 jp 会让 setQueue 报 CONTENT_EQUIVALENT（真 MusicKit JS 实测）。
    expect(config).not.toHaveProperty('storefrontId');
    expect(played).not.toHaveProperty('isPreview');
    expect(b.calls.find((c) => c[0] === 'setQueue')[1]).toEqual({ song: '1513425337', startPlaying: false });
    expect(b.posted.some(([, m]) => m.type === 'state' && m.state === 2)).toBe(true);
    expect(b.mediaSession.metadata).toBe(null);
    expect(b.mediaSession.handlers.nexttrack).toBe(null);

    const failed = await b.k.play('bad', 0);
    expect(failed.ok).toBe(false);
    expect(failed.error).toEqual({ name: 'MKError', message: 'CONTENT_UNAVAILABLE' });
    expect(b.posted.some(([, m]) => m.type === 'error')).toBe(true);

    expect((await b.k.authorize()).authorized).toBe(true);
    // 只 configure 一次。
    expect(b.calls.filter((c) => c[0] === 'configure').length).toBe(1);
  });

  it('bridge.js：电台交给 MusicKit 自管队列、换歌发 nowPlaying、skipToNext 走 skipToNextItem', async () => {
    const env = makeEnv();
    const src = String((await call(env, 'GET', '/musickit/bridge.js')).data);
    const b = runBridge(src);
    const r = await b.k.playStation('ra.978194965', false);
    expect(r.ok).toBe(true);
    expect(b.calls.find((c) => c[0] === 'setQueue')[1]).toEqual({ station: 'ra.978194965', startPlaying: false });
    // autoplay === false：只排好不出声。
    expect(b.calls.some((c) => c[0] === 'play')).toBe(false);
    expect(r.nowPlaying).toEqual({
      songId: '111', title: 'S1', artist: 'A1', album: 'AL1',
      artworkUrl: 'https://x/{w}x{h}bb.jpg', durationMs: 180000,
    });
    const np = b.posted.filter(([, m]) => m.type === 'nowPlaying').map(([, m]) => m);
    expect(np).toHaveLength(1);
    expect(np[0].songId).toBe('111');

    expect((await b.k.skipToNext()).ok).toBe(true);
    expect(b.calls.some((c) => c[0] === 'skipToNextItem')).toBe(true);
    const live = b.posted.filter(([, m]) => m.type === 'nowPlaying').map(([, m]) => m).at(-1);
    // 直播节目：没有 songId / 时长，只有标题。
    expect(live.songId).toBe(null);
    expect(live.durationMs).toBe(null);
    expect(live.title).toBe('Live Show');

    await b.k.playStation('ra.1', true);
    expect(b.calls.some((c) => c[0] === 'play')).toBe(true);
  });

  it('bridge.js：token 端点不可用时 init 回 {ok:false}，之后可重试', async () => {
    const env = makeEnv();
    const src = String((await call(env, 'GET', '/musickit/bridge.js')).data);
    const b = runBridge(src, { tokenStatus: 503 });
    const r = await b.k.init();
    expect(r.ok).toBe(false);
    expect(r.error.message).toBe('token_http_503');
    expect(r.error.stage).toBe('token');
    expect(b.k.initStage()).toBe('token');
    expect(b.calls.filter((c) => c[0] === 'fetch').length).toBe(1);
    await b.k.init();
    expect(b.calls.filter((c) => c[0] === 'fetch').length).toBe(2);
  });

  // D69n21etZ1：连不上本服务时 init 失败要如实落在 token 段（Dart 据此报「连不上 Fushi 服务器」），
  // 而不是挂到 Dart 侧总超时、被当成 DRM 无响应。
  it('bridge.js：token 请求网络失败 → {ok:false, stage:"token"}，不进 configure', async () => {
    const env = makeEnv();
    const src = String((await call(env, 'GET', '/musickit/bridge.js')).data);
    const b = runBridge(src, { fetchImpl: async () => { throw new TypeError('Failed to fetch'); } });
    const r = await b.k.init();
    expect(r.ok).toBe(false);
    expect(r.error.stage).toBe('token');
    expect(r.error.message).toBe('token_network: Failed to fetch');
    expect(b.calls.some((c) => c[0] === 'configure')).toBe(false);
  });

  it('bridge.js：token 请求挂住被 abort → token_timeout；fetch 带了 signal', async () => {
    const env = makeEnv();
    const src = String((await call(env, 'GET', '/musickit/bridge.js')).data);
    vi.useFakeTimers();
    try {
      const b = runBridge(src, {
        fetchImpl: (_url, init) => new Promise((_resolve, reject) => {
          init.signal.addEventListener('abort', () => reject(new Error('aborted')));
        }),
      });
      const pending = b.k.init();
      await vi.advanceTimersByTimeAsync(15000);
      const r = await pending;
      expect(r.ok).toBe(false);
      expect(r.error.stage).toBe('token');
      expect(r.error.message).toBe('token_timeout');
    } finally {
      vi.useRealTimers();
    }
  });

  it('bridge.js：configure 挂住时 initStage 停在 configure（Dart 超时才报 DRM）', async () => {
    const env = makeEnv();
    const src = String((await call(env, 'GET', '/musickit/bridge.js')).data);
    const b = runBridge(src, { configureImpl: () => new Promise(() => {}) });
    expect(b.k.initStage()).toBe('idle');
    void b.k.init();
    await new Promise((r) => setTimeout(r, 0));
    expect(b.k.initStage()).toBe('configure');
  });

  it('bridge.js：configure 抛错 → stage:"configure"；成功后 initStage 为 ready', async () => {
    const env = makeEnv();
    const src = String((await call(env, 'GET', '/musickit/bridge.js')).data);
    const bad = runBridge(src, { configureImpl: async () => { throw Object.freeze({ name: 'MKError', message: 'DRM_UNSUPPORTED' }); } });
    const r = await bad.k.init();
    expect(r.ok).toBe(false);
    expect(r.error).toMatchObject({ name: 'MKError', message: 'DRM_UNSUPPORTED', stage: 'configure' });
    const good = runBridge(src);
    expect((await good.k.init()).ok).toBe(true);
    expect(good.k.initStage()).toBe('ready');
  });
});
