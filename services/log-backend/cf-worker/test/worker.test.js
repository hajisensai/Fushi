import { describe, expect, it } from 'vitest';
import worker, {
  buildLogContent,
  checkBasicAuth,
  configMissing,
  escapeHtml,
  genLogId,
  linkBase,
  parseLogId,
  randCode,
  renderList,
  renderLog,
  routePath,
  sanitizePlatform,
  timingSafeEqual,
  validLogID,
} from '../src/worker.js';

function fakeD1(initial = {}) {
  const rows = new Map(Object.entries(initial)); // id -> content
  function prepare(sql) {
    let args = [];
    const stmt = {
      bind(...a) {
        args = a;
        return stmt;
      },
      async run() {
        if (/^INSERT/i.test(sql)) {
          rows.set(args[0], args[1]);
        } else if (/^DELETE/i.test(sql)) {
          const retain = args[0];
          const keep = new Set(
            [...rows.keys()].sort().reverse().slice(0, retain),
          );
          for (const k of [...rows.keys()]) if (!keep.has(k)) rows.delete(k);
        }
        return { success: true };
      },
      async first() {
        // SELECT content FROM logs WHERE id = ?1
        return rows.has(args[0]) ? { content: rows.get(args[0]) } : null;
      },
      async all() {
        // SELECT id FROM logs ORDER BY id DESC
        const ids = [...rows.keys()].sort().reverse();
        return { results: ids.map((id) => ({ id })) };
      },
    };
    return stmt;
  }
  return { prepare, _rows: rows };
}

function fullEnv(over = {}) {
  return {
    UPLOAD_TOKEN: 'good-token',
    BASIC_USER: 'admin',
    BASIC_PASS: 'secret-pass',
    DB: fakeD1(),
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
  it('parseLogId 拆出时间/平台/rand，非法返回 null', () => {
    expect(parseLogId('20260606-123456-android-ab12cd.txt')).toEqual({
      date: '2026-06-06',
      time: '12:34:56',
      platform: 'android',
      rand: 'ab12cd',
    });
    expect(parseLogId('evil.txt')).toBe(null);
    expect(parseLogId('../../etc/passwd')).toBe(null);
  });
  it('linkBase：无前缀空串，有前缀补斜杠', () => {
    expect(linkBase(undefined)).toBe('');
    expect(linkBase('')).toBe('');
    expect(linkBase('ec70')).toBe('/ec70');
    expect(linkBase('/ec70')).toBe('/ec70');
  });
  it('renderList：链接带前缀 + 空状态 + HTML 转义', () => {
    const html = renderList(['20260606-123456-android-ab12cd.txt'], '/ec70');
    expect(html).toContain('href="/ec70/log/20260606-123456-android-ab12cd.txt"');
    expect(html).toContain('android'); // 平台徽章
    expect(html).toContain('ab12cd'); // rand 作链接文字
    expect(renderList([], '/ec70')).toContain('还没有日志');
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
  it('configMissing 抓空 secret + 缺 DB binding', () => {
    expect(
      configMissing({ UPLOAD_TOKEN: 'a', BASIC_USER: 'b', BASIC_PASS: 'c', DB: {} }),
    ).toEqual([]);
    expect(configMissing({}).length).toBe(4); // 3 secret + DB
    expect(configMissing({ UPLOAD_TOKEN: 'a', BASIC_USER: 'b', BASIC_PASS: 'c' })).toEqual(['DB']);
  });
});

describe('fetch routes', () => {
  it('上传 happy path → 200 + id + 落 DB', async () => {
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
    expect(env.DB._rows.get(json.id)).toContain('hello');
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

  it('上传超大但无 Content-Length（流式 body）→ 读后字节复核仍 413', async () => {
    // 用流式 body 让 Content-Length 缺失，绕过头预检，触发 read 后的字节复核分支。
    const env = fullEnv();
    const big = new TextEncoder().encode('x'.repeat(600 * 1024));
    const stream = new ReadableStream({
      start(c) {
        c.enqueue(big);
        c.close();
      },
    });
    const req = new Request('https://logs.example.com/api/logs', {
      method: 'POST',
      headers: { 'X-Upload-Token': 'good-token' },
      body: stream,
      duplex: 'half',
    });
    const res = await worker.fetch(req, env);
    expect(res.status).toBe(413);
  });

  it('缺 secret → fail-closed 500', async () => {
    const res = await worker.fetch(uploadReq('', '{"log":"x"}'), { DB: fakeD1() });
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
    const env = fullEnv({ DB: fakeD1({ '20260606-123456-android-ab12cd.txt': 'x' }) });
    const req = new Request('https://logs.example.com/', {
      headers: { Authorization: basicHeader('admin', 'secret-pass') },
    });
    const res = await worker.fetch(req, env);
    expect(res.status).toBe(200);
    expect(res.headers.get('Content-Type')).toContain('text/html');
    expect(await res.text()).toContain('20260606-123456-android-ab12cd.txt');
  });

  it('看单条 → 深色 HTML，正文转义 + nosniff + no-store + CSP 拦脚本（XSS 惰化）', async () => {
    const env = fullEnv({
      DB: fakeD1({ '20260606-123456-android-ab12cd.txt': '<script>alert(1)</script>' }),
    });
    const req = new Request(
      'https://logs.example.com/log/20260606-123456-android-ab12cd.txt',
      { headers: { Authorization: basicHeader('admin', 'secret-pass') } },
    );
    const res = await worker.fetch(req, env);
    expect(res.status).toBe(200);
    expect(res.headers.get('Content-Type')).toContain('text/html');
    expect(res.headers.get('X-Content-Type-Options')).toBe('nosniff');
    expect(res.headers.get('Cache-Control')).toBe('no-store');
    const csp = res.headers.get('Content-Security-Policy');
    expect(csp).toContain("style-src 'unsafe-inline'");
    expect(csp).not.toContain('script-src'); // default-src 'none' 拦死脚本
    const html = await res.text();
    expect(html).toContain('&lt;script&gt;alert(1)&lt;/script&gt;'); // 转义后当文本
    expect(html).not.toContain('<script>alert(1)</script>'); // 绝不原样注入 → 不执行
  });

  it('renderLog：正文转义 + 返回链接带前缀', () => {
    const html = renderLog('a<b>&"c', '20260606-123456-android-ab12cd.txt', '/ec70');
    expect(html).toContain('a&lt;b&gt;&amp;&quot;c'); // 正文转义
    expect(html).toContain('href="/ec70/"'); // 返回列表带前缀
  });

  it('看单条路径穿越/非法 id → 404，不读 DB', async () => {
    const env = fullEnv({ DB: fakeD1({ '20260606-123456-android-ab12cd.txt': 'real' }) });
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

  it('上传后立刻可在列表看到（强一致）', async () => {
    const env = fullEnv();
    const body = JSON.stringify({ kind: 'error', platform: 'android', log: 'fresh' });
    const up = await worker.fetch(uploadReq('good-token', body), env);
    const { id } = await up.json();
    const list = await worker.fetch(
      new Request('https://logs.example.com/', {
        headers: { Authorization: basicHeader('admin', 'secret-pass') },
      }),
      env,
    );
    expect(await list.text()).toContain(id);
  });

  it('RETAIN 清理只留最近 N 条', async () => {
    const env = fullEnv({
      DB: fakeD1({
        '20260101-000001-android-aaaaaa.txt': '1',
        '20260101-000002-android-bbbbbb.txt': '2',
        '20260101-000003-android-cccccc.txt': '3',
      }),
      RETAIN: '2',
    });
    const body = JSON.stringify({ kind: 'error', platform: 'android', log: 'newest' });
    await worker.fetch(uploadReq('good-token', body), env);
    // 4 条插入后保留最近 2 条
    expect(env.DB._rows.size).toBe(2);
  });

  it('RETAIN 非法值（非数字）→ 回落默认 2000，不误删', async () => {
    const env = fullEnv({
      DB: fakeD1({
        '20260101-000001-android-aaaaaa.txt': '1',
        '20260101-000002-android-bbbbbb.txt': '2',
        '20260101-000003-android-cccccc.txt': '3',
      }),
      RETAIN: 'not-a-number',
    });
    const body = JSON.stringify({ kind: 'error', platform: 'android', log: 'newest' });
    await worker.fetch(uploadReq('good-token', body), env);
    // 回落 2000 → 全留（4 条），证明没误回落成 0/小数致清空
    expect(env.DB._rows.size).toBe(4);
  });
});

describe('随机密钥路径前缀 ROUTE_PREFIX', () => {
  it('routePath：未配前缀按原路径', () => {
    expect(routePath('/api/logs', undefined)).toBe('/api/logs');
    expect(routePath('/', '')).toBe('/');
  });
  it('routePath：配了前缀只放行前缀下，其余 null', () => {
    expect(routePath('/s3cr3t', 's3cr3t')).toBe('/');
    expect(routePath('/s3cr3t/', 's3cr3t')).toBe('/');
    expect(routePath('/s3cr3t/api/logs', 's3cr3t')).toBe('/api/logs');
    expect(routePath('/s3cr3t/log/x.txt', 's3cr3t')).toBe('/log/x.txt');
    expect(routePath('/', 's3cr3t')).toBe(null); // 裸根
    expect(routePath('/api/logs', 's3cr3t')).toBe(null); // 无前缀直访
    expect(routePath('/wrong/api/logs', 's3cr3t')).toBe(null);
    expect(routePath('/s3cr3tXX', 's3cr3t')).toBe(null); // 前缀须完整边界
  });

  it('裸域名 / 无前缀直访 → 404（不暴露服务存在）', async () => {
    const env = fullEnv({ ROUTE_PREFIX: 's3cr3t' });
    const auth = { Authorization: basicHeader('admin', 'secret-pass') };
    for (const p of [
      'https://logs.example.com/',
      'https://logs.example.com/api/logs',
      'https://logs.example.com/log/20260606-123456-android-ab12cd.txt',
      'https://logs.example.com/wrong/',
    ]) {
      const res = await worker.fetch(new Request(p, { headers: auth }), env);
      expect(res.status).toBe(404);
    }
  });

  it('正确前缀下：上传 + 带密码看列表都正常', async () => {
    const env = fullEnv({ ROUTE_PREFIX: 's3cr3t' });
    const up = await worker.fetch(
      new Request('https://logs.example.com/s3cr3t/api/logs', {
        method: 'POST',
        headers: { 'X-Upload-Token': 'good-token', 'Content-Type': 'application/json' },
        body: JSON.stringify({ kind: 'error', platform: 'android', log: 'prefixed' }),
      }),
      env,
    );
    expect(up.status).toBe(200);
    const { id } = await up.json();
    const list = await worker.fetch(
      new Request('https://logs.example.com/s3cr3t/', {
        headers: { Authorization: basicHeader('admin', 'secret-pass') },
      }),
      env,
    );
    expect(list.status).toBe(200);
    const listHtml = await list.text();
    expect(listHtml).toContain(id);
    // BUG 修复：列表链接必须带前缀，否则点开丢前缀 → 404。
    expect(listHtml).toContain(`href="/s3cr3t/log/${id}"`);
    // 列表页 CSP 放开 style-src 以渲染内联样式，但仍不放开 script-src。
    const csp = list.headers.get('Content-Security-Policy');
    expect(csp).toContain("style-src 'unsafe-inline'");
    expect(csp).not.toContain('script-src');
  });
});
