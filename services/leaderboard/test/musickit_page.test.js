import vm from 'node:vm';
import { describe, expect, it } from 'vitest';
import { call, makeEnv } from './harness.js';
import { MUSICKIT_JS_URL, MUSICKIT_PAGE_CSP } from '../src/musickit_page.js';

/** 在最小 window/document 替身里跑 bridge.js，配一个假 MusicKit。 */
function runBridge(source, { tokenStatus = 200 } = {}) {
  const posted = [];
  const listeners = {};
  const mediaSession = { metadata: { title: 'x' }, handlers: {}, setActionHandler(a, h) { this.handlers[a] = h; } };
  const calls = [];
  const instance = {
    isAuthorized: false,
    storefrontId: 'jp',
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
      this.nowPlayingItem = { id: q.song, isPreview: false };
    },
    async seekToTime(s) { calls.push(['seek', s]); this.currentPlaybackTime = s; },
    async play() { calls.push(['play']); this.playbackState = 2; (listeners.playbackStateDidChange || []).forEach((f) => f()); },
    pause() { this.playbackState = 3; },
    stop() { this.playbackState = 0; },
  };
  const window = {
    MusicKit: {
      Events: { playbackStateDidChange: 'playbackStateDidChange', mediaPlaybackError: 'mediaPlaybackError' },
      async configure(opts) { calls.push(['configure', opts]); return instance; },
    },
    flutter_inappwebview: { callHandler: (name, msg) => posted.push([name, msg]) },
    dispatchEvent() {},
  };
  const sandbox = {
    window,
    navigator: { mediaSession },
    location: { search: '' },
    document: { addEventListener() {}, getElementById() { return null; } },
    CustomEvent: class { constructor(type, init) { this.type = type; this.detail = init?.detail; } },
    URLSearchParams,
    setTimeout,
    clearTimeout,
    fetch: async (url, init) => {
      calls.push(['fetch', url, init]);
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
    expect(csp).toContain("frame-ancestors 'none'");
    expect(csp).not.toContain("'unsafe-inline' 'self'");
    expect(csp).toMatch(/script-src 'self' https:\/\/js-cdn\.music\.apple\.com(;|$)/);
    const html = String(r.data);
    expect(html).toContain(`src="${MUSICKIT_JS_URL}"`);
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
    expect(b.calls.find((c) => c[0] === 'configure')[1].developerToken).toBe('dev-token');
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

  it('bridge.js：token 端点不可用时 init 回 {ok:false}，之后可重试', async () => {
    const env = makeEnv();
    const src = String((await call(env, 'GET', '/musickit/bridge.js')).data);
    const b = runBridge(src, { tokenStatus: 503 });
    const r = await b.k.init();
    expect(r.ok).toBe(false);
    expect(r.error.message).toBe('token_http_503');
    expect(b.calls.filter((c) => c[0] === 'fetch').length).toBe(1);
    await b.k.init();
    expect(b.calls.filter((c) => c[0] === 'fetch').length).toBe(2);
  });
});
