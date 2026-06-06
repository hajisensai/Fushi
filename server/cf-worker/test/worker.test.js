import { describe, expect, it } from 'vitest';
import worker, {
  buildLogContent,
  checkBasicAuth,
  configMissing,
  escapeHtml,
  genLogId,
  randCode,
  sanitizePlatform,
  timingSafeEqual,
  validLogID,
} from '../src/worker.js';

function fakeKV(initial = {}) {
  const m = new Map(Object.entries(initial));
  return {
    async put(k, v) {
      m.set(k, v);
    },
    async get(k) {
      return m.has(k) ? m.get(k) : null;
    },
    async list() {
      return {
        keys: [...m.keys()].map((name) => ({ name })),
        list_complete: true,
        cursor: undefined,
      };
    },
    _map: m,
  };
}

function fullEnv(over = {}) {
  return {
    UPLOAD_TOKEN: 'good-token',
    BASIC_USER: 'admin',
    BASIC_PASS: 'secret-pass',
    LOGS: fakeKV(),
    ...over,
  };
}

function uploadReq(token, body) {
  const headers = { 'Content-Type': 'application/json' };
  if (token != null) headers['X-Upload-Token'] = token;
  return new Request('https://logs.example.com/api/logs', {
    method: 'POST',
    headers,
    body,
  });
}

function basicHeader(user, pass) {
  return 'Basic ' + btoa(`${user}:${pass}`);
}

describe('pure helpers', () => {
  it('validLogID 白名单', () => {
    expect(validLogID('20260606-123456-android-ab12cd.txt')).toBe(true);
    expect(validLogID('../../etc/passwd')).toBe(false);
    expect(validLogID('evil.txt')).toBe(false);
    expect(validLogID('20260606-123456-android-ab12cd.txt.bak')).toBe(false);
  });
  it('sanitizePlatform 只留 a-z 截 16', () => {
    expect(sanitizePlatform('../../etc')).toBe('etc');
    expect(sanitizePlatform('Android')).toBe('android');
    expect(sanitizePlatform('')).toBe('unknown');
    expect(sanitizePlatform('z'.repeat(100)).length).toBe(16);
  });
  it('genLogId 形状匹配白名单', () => {
    const id = genLogId(new Date(Date.UTC(2026, 5, 6, 12, 34, 56)), 'android', 'ab12cd');
    expect(id).toBe('20260606-123456-android-ab12cd.txt');
    expect(validLogID(id)).toBe(true);
  });
  it('randCode 定长且字母表内', () => {
    const c = randCode(6, (b) => b.fill(0));
    expect(c).toBe('aaaaaa');
    expect(randCode(6).length).toBe(6);
  });
  it('escapeHtml 转义', () => {
    expect(escapeHtml('<script>')).toBe('&lt;script&gt;');
  });
  it('buildLogContent 去换行注入 + 保留正文', () => {
    const c = buildLogContent({ kind: 'a\nb', platform: 'android', log: 'line1\nline2' });
    expect(c).toContain('# kind: a b'); // 头部换行被替换
    expect(c).toContain('line1\nline2'); // 正文换行保留
  });
  it('timingSafeEqual', () => {
    expect(timingSafeEqual('abc', 'abc')).toBe(true);
    expect(timingSafeEqual('abc', 'abd')).toBe(false);
    expect(timingSafeEqual('abc', 'ab')).toBe(false);
    expect(timingSafeEqual('', '')).toBe(true);
  });
  it('checkBasicAuth', () => {
    expect(checkBasicAuth(basicHeader('admin', 'secret-pass'), 'admin', 'secret-pass')).toBe(true);
    expect(checkBasicAuth(basicHeader('admin', 'nope'), 'admin', 'secret-pass')).toBe(false);
    expect(checkBasicAuth(null, 'admin', 'secret-pass')).toBe(false);
    expect(checkBasicAuth('Bearer x', 'admin', 'secret-pass')).toBe(false);
  });
  it('configMissing 抓空 secret', () => {
    expect(configMissing({ UPLOAD_TOKEN: 'a', BASIC_USER: 'b', BASIC_PASS: 'c' })).toEqual([]);
    expect(configMissing({}).length).toBe(3);
  });
});

describe('fetch routes', () => {
  it('上传 happy path → 200 + id + 落 KV', async () => {
    const env = fullEnv();
    const body = JSON.stringify({
      kind: 'error',
      app_version: '1.0+1',
      platform: 'android',
      device: 'Pixel',
      ts: '2026-06-06T00:00:00Z',
      log: 'hello',
    });
    const res = await worker.fetch(uploadReq('good-token', body), env);
    expect(res.status).toBe(200);
    const json = await res.json();
    expect(validLogID(json.id)).toBe(true);
    expect(await env.LOGS.get(json.id)).toContain('hello');
  });

  it('上传错 token → 401', async () => {
    const res = await worker.fetch(uploadReq('bad', '{"log":"x"}'), fullEnv());
    expect(res.status).toBe(401);
  });

  it('上传超大（Content-Length）→ 413', async () => {
    const env = fullEnv();
    const req = new Request('https://logs.example.com/api/logs', {
      method: 'POST',
      headers: { 'X-Upload-Token': 'good-token', 'Content-Length': String(600 * 1024) },
      body: '{"log":"x"}',
    });
    const res = await worker.fetch(req, env);
    expect(res.status).toBe(413);
  });

  it('缺 secret → fail-closed 500', async () => {
    const res = await worker.fetch(uploadReq('', '{"log":"x"}'), { LOGS: fakeKV() });
    expect(res.status).toBe(500);
  });

  it('非 POST 上传 → 405', async () => {
    const req = new Request('https://logs.example.com/api/logs', { method: 'GET' });
    const res = await worker.fetch(req, fullEnv());
    expect(res.status).toBe(405);
  });

  it('查看列表需 Basic Auth', async () => {
    const res = await worker.fetch(new Request('https://logs.example.com/'), fullEnv());
    expect(res.status).toBe(401);
    expect(res.headers.get('WWW-Authenticate')).toContain('Basic');
  });

  it('查看列表错密码 → 401', async () => {
    const req = new Request('https://logs.example.com/', {
      headers: { Authorization: basicHeader('admin', 'nope') },
    });
    expect((await worker.fetch(req, fullEnv())).status).toBe(401);
  });

  it('列表展示已上传 id（且 HTML 转义）', async () => {
    const env = fullEnv({ LOGS: fakeKV({ '20260606-123456-android-ab12cd.txt': 'x' }) });
    const req = new Request('https://logs.example.com/', {
      headers: { Authorization: basicHeader('admin', 'secret-pass') },
    });
    const res = await worker.fetch(req, env);
    expect(res.status).toBe(200);
    expect(res.headers.get('Content-Type')).toContain('text/html');
    expect(await res.text()).toContain('20260606-123456-android-ab12cd.txt');
  });

  it('看单条 → text/plain 原样 + nosniff + no-store（XSS 惰化）', async () => {
    const env = fullEnv({
      LOGS: fakeKV({ '20260606-123456-android-ab12cd.txt': '<script>alert(1)</script>' }),
    });
    const req = new Request(
      'https://logs.example.com/log/20260606-123456-android-ab12cd.txt',
      { headers: { Authorization: basicHeader('admin', 'secret-pass') } },
    );
    const res = await worker.fetch(req, env);
    expect(res.status).toBe(200);
    expect(res.headers.get('Content-Type')).toContain('text/plain');
    expect(res.headers.get('Content-Type')).not.toContain('html');
    expect(res.headers.get('X-Content-Type-Options')).toBe('nosniff');
    expect(res.headers.get('Cache-Control')).toBe('no-store');
    expect(await res.text()).toBe('<script>alert(1)</script>'); // 原样，未执行
  });

  it('看单条路径穿越/非法 id → 404，不读 KV', async () => {
    const env = fullEnv({ LOGS: fakeKV({ '20260606-123456-android-ab12cd.txt': 'real' }) });
    const auth = { Authorization: basicHeader('admin', 'secret-pass') };
    for (const p of [
      'https://logs.example.com/log/..%2f..%2fetc%2fpasswd',
      'https://logs.example.com/log/evil.txt',
      'https://logs.example.com/log/20260606-123456-android-ab12cd.txt.bak',
    ]) {
      const res = await worker.fetch(new Request(p, { headers: auth }), env);
      expect(res.status).toBe(404);
    }
  });
});
