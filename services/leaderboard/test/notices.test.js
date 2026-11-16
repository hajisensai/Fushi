// 服务端公告（迁移 0022；src/notices.js、POST /v1/notices、/admin/api/notices/**、/dev/notices）。
import { describe, expect, it } from 'vitest';
import { call, makeEnv, nextIp, registerUser } from './harness.js';
import { hex, sha256 } from '../src/util.js';
import { NOTICE_LIMITS, normalizeNoticeQuery, normalizeRule, noticeOf, ruleMatches } from '../src/notices.js';

const NOW = Date.UTC(2026, 10, 17, 12);
const DAY = 24 * 3600 * 1000;
const basic = { Authorization: `Basic ${btoa('admin:pw')}` };

const D1 = 'a'.repeat(64);
const D2 = 'b'.repeat(64);
const D3 = 'c'.repeat(64);

function ask(env, body = {}, opts = {}) {
  return call(env, 'POST', '/v1/notices', {
    body: { v: '2.12.0', p: 'android', c: 'stable', l: 'en-US', id: 'app.example.one', h: [D1], k: [D1], ...body },
    headers: { 'CF-Connecting-IP': opts.ip ?? nextIp() },
    now: opts.now ?? NOW,
    cf: opts.cf,
  });
}

function admin(env, method, path, body) {
  return call(env, method, `/admin/api/notices${path}`, { headers: basic, body, now: NOW });
}

async function addRule(env, rule) {
  const r = await admin(env, 'POST', '/rules', { level: 'banner', title_zh: '中文标题', body_zh: '中文正文', ...rule });
  expect(r.status).toBe(201);
  return r.data.id;
}

describe('POST /v1/notices', () => {
  it('returns an empty list with the long ttl when no rule exists', async () => {
    const env = makeEnv();
    const r = await ask(env);
    expect(r.status).toBe(200);
    expect(r.data).toEqual({ notices: [], ttl: NOTICE_LIMITS.ttlEmpty });
    expect(r.res.headers.get('Cache-Control')).toBe('no-store');
  });

  it('matches h rules against both digest lists, with the short ttl', async () => {
    const env = makeEnv();
    const id = await addRule(env, { kind: 'h', value: D2.toUpperCase(), title_en: 'T', body_en: 'B', url: 'https://example.com/x' });
    expect((await ask(env)).data.notices).toEqual([]);
    const viaH = await ask(env, { h: [D2], k: [] });
    expect(viaH.data).toEqual({
      notices: [{ id: `r${id}`, level: 'banner', title: 'T', body: 'B', url: 'https://example.com/x' }],
      ttl: NOTICE_LIMITS.ttlMatched,
    });
    expect((await ask(env, { h: [D1], k: [D2] })).data.notices).toHaveLength(1);
    // 摘要大小写不敏感（请求端也规范成小写）。
    expect((await ask(env, { h: [D2.toUpperCase()], k: [] })).data.notices).toHaveLength(1);
  });

  it('matches id rules and respects the platform filter', async () => {
    const env = makeEnv();
    await addRule(env, { kind: 'id', value: 'app.example.two', platform: 'android' });
    expect((await ask(env)).data.notices).toEqual([]);
    expect((await ask(env, { id: 'app.example.two' })).data.notices).toHaveLength(1);
    expect((await ask(env, { id: 'app.example.two', p: 'windows' })).data.notices).toEqual([]);
  });

  it('h_unlisted matches only when no digest is registered and at least one is present', async () => {
    const env = makeEnv();
    await addRule(env, { kind: 'h_unlisted' });
    expect((await admin(env, 'POST', '/known', { h: D1, label: 'main' })).status).toBe(200);
    expect((await ask(env, { h: [D1], k: [D1] })).data.notices).toEqual([]);
    expect((await ask(env, { h: [D2], k: [D1] })).data.notices).toEqual([]);
    expect((await ask(env, { h: [D2], k: [D3] })).data.notices).toHaveLength(1);
    expect((await ask(env, { h: [], k: [D3] })).data.notices).toHaveLength(1);
    expect((await ask(env, { h: [], k: [] })).data.notices).toEqual([]);
    expect((await ask(env, { h: undefined, k: undefined, p: 'linux', id: null })).data.notices).toEqual([]);
  });

  it('hk_disjoint matches only when both lists are present and share nothing', async () => {
    const env = makeEnv();
    await addRule(env, { kind: 'hk_disjoint' });
    expect((await ask(env, { h: [D1], k: [D1] })).data.notices).toEqual([]);
    expect((await ask(env, { h: [D1, D2], k: [D2] })).data.notices).toEqual([]);
    expect((await ask(env, { h: [D1], k: [] })).data.notices).toEqual([]);
    expect((await ask(env, { h: [D1], k: [D2] })).data.notices).toHaveLength(1);
  });

  it('returns every matching enabled rule, most severe first', async () => {
    const env = makeEnv();
    const banner = await addRule(env, { kind: 'all', level: 'banner' });
    const block = await addRule(env, { kind: 'h', value: D1, level: 'block' });
    const dialog = await addRule(env, { kind: 'id', value: 'app.example.one', level: 'dialog' });
    const off = await addRule(env, { kind: 'all', level: 'block', enabled: false });
    const r = await ask(env);
    expect(r.data.notices.map((n) => n.id)).toEqual([`r${block}`, `r${dialog}`, `r${banner}`]);
    expect(r.data.notices.map((n) => n.id)).not.toContain(`r${off}`);
    expect((await admin(env, 'POST', `/rules/${block}/disable`)).status).toBe(200);
    expect((await ask(env)).data.notices.map((n) => n.id)).toEqual([`r${dialog}`, `r${banner}`]);
  });

  it('picks text by locale and falls back to zh when en is empty', async () => {
    const env = makeEnv();
    await addRule(env, { kind: 'all', title_en: 'Hello', body_en: 'World' });
    expect((await ask(env, { l: 'zh-CN' })).data.notices[0]).toMatchObject({ title: '中文标题', body: '中文正文' });
    expect((await ask(env, { l: 'zh_TW' })).data.notices[0]).toMatchObject({ title: '中文标题' });
    expect((await ask(env, { l: 'ja' })).data.notices[0]).toMatchObject({ title: 'Hello', body: 'World', url: null });
    expect((await ask(env, { l: null })).data.notices[0]).toMatchObject({ title: 'Hello' });

    const zhOnly = makeEnv();
    await addRule(zhOnly, { kind: 'all' });
    expect((await ask(zhOnly, { l: 'en-US' })).data.notices[0]).toMatchObject({ title: '中文标题', body: '中文正文' });
  });

  it('noticeOf picks one language pair', () => {
    const rule = { id: 3, level: 'dialog', title_zh: '标', body_zh: '文', title_en: null, body_en: 'only body', url: null };
    expect(noticeOf(rule, 'en')).toEqual({ id: 'r3', level: 'dialog', title: '', body: 'only body', url: null });
    expect(noticeOf(rule, 'zh-Hans-CN')).toMatchObject({ title: '标', body: '文' });
  });

  it('rejects malformed input', async () => {
    const env = makeEnv();
    const bad = async (body, code) => {
      const r = await ask(env, body);
      expect(r.status).toBe(400);
      expect(r.data.error).toBe(code);
    };
    await bad({ v: '' }, 'bad_v');
    await bad({ v: 'x'.repeat(65) }, 'bad_v');
    await bad({ p: 'ios' }, 'bad_p');
    await bad({ c: 'has space' }, 'bad_c');
    await bad({ l: 'not a locale!' }, 'bad_l');
    await bad({ id: 'noDots' }, 'bad_id');
    await bad({ id: 5 }, 'bad_id');
    await bad({ h: 'abc' }, 'bad_h');
    await bad({ h: ['zz'] }, 'bad_h');
    await bad({ k: Array(NOTICE_LIMITS.maxDigests + 1).fill(D1) }, 'bad_k');
    expect((await call(env, 'POST', '/v1/notices', { body: [1], now: NOW })).status).toBe(400);
    const big = new TextEncoder().encode(JSON.stringify({ v: '1', p: 'android', pad: 'x'.repeat(NOTICE_LIMITS.maxBodyBytes) }));
    expect((await call(env, 'POST', '/v1/notices', { body: big, now: NOW })).status).toBe(413);
    // 不认识的字段忽略。
    expect((await ask(env, { extra: { a: 1 } })).status).toBe(200);
  });

  it('normalizeNoticeQuery dedupes and lowercases digests', () => {
    const q = normalizeNoticeQuery({ v: '1.0', p: 'windows', h: [D1, D1.toUpperCase()], k: null });
    expect(q).toEqual({ v: '1.0', p: 'windows', c: null, l: null, id: null, h: [D1], k: [] });
  });

  it('upserts sightings without storing the client address', async () => {
    const env = makeEnv();
    await ask(env, { h: [D1], k: [D2] }, { cf: { country: 'CN' }, ip: '203.0.113.9' });
    await ask(env, { h: [D1], k: [D2] }, { cf: { country: 'CN' }, ip: '203.0.113.10' });
    await ask(env, { h: [], k: [], id: null, p: 'windows' });
    await ask(env, { h: [D1], k: [D2] }, { cf: { country: 'CN' }, now: NOW + DAY });
    const rows = env.DB.raw.prepare('SELECT * FROM notice_seen ORDER BY day, p').all();
    expect(rows).toEqual([
      { day: '2026-11-17', id: 'app.example.one', h: D1, hk_disjoint: 1, v: '2.12.0', p: 'android', country: 'CN', n: 2 },
      { day: '2026-11-17', id: '', h: '', hk_disjoint: 0, v: '2.12.0', p: 'windows', country: '', n: 1 },
      { day: '2026-11-18', id: 'app.example.one', h: D1, hk_disjoint: 1, v: '2.12.0', p: 'android', country: 'CN', n: 1 },
    ].map((r) => ({ ...r })));
    const dump = JSON.stringify(env.DB.raw.prepare('SELECT * FROM notice_seen').all());
    expect(dump).not.toContain('203.0.113');

    // k 打头的摘要在 h 为空时记为首个摘要。
    await ask(env, { h: [], k: [D3] });
    expect(env.DB.raw.prepare('SELECT COUNT(*) AS n FROM notice_seen WHERE h = ?').get(D3).n).toBe(1);
  });

  it('stops counting but keeps answering once the daily budget is used up', async () => {
    const env = makeEnv({ BUDGET_NOTICES: '2' });
    await addRule(env, { kind: 'all' });
    for (let i = 0; i < 4; i += 1) expect((await ask(env)).data.notices).toHaveLength(1);
    expect(env.DB.raw.prepare('SELECT SUM(n) AS n FROM notice_seen').get().n).toBe(2);
    expect(env.DB.raw.prepare("SELECT used FROM budgets WHERE kind = 'notices'").get().used).toBe(2);
  });

  it('purges sightings past retention in the scheduled job', async () => {
    const env = makeEnv();
    await ask(env, {}, { now: NOW - (NOTICE_LIMITS.retentionDays + 2) * DAY });
    await ask(env);
    const { default: worker } = await import('../src/worker.js');
    const realNow = Date.now;
    Date.now = () => NOW;
    try {
      await worker.scheduled({}, env);
    } finally {
      Date.now = realNow;
    }
    expect(env.DB.raw.prepare('SELECT day FROM notice_seen').all().map((r) => r.day)).toEqual(['2026-11-17']);
  });
});

describe('ruleMatches', () => {
  const q = { p: 'android', id: 'a.b', h: [D1], k: [D2] };
  it('covers every kind', () => {
    expect(ruleMatches({ kind: 'h', value: D2 }, q, new Set())).toBe(true);
    expect(ruleMatches({ kind: 'id', value: 'a.b' }, q, new Set())).toBe(true);
    expect(ruleMatches({ kind: 'h_unlisted' }, q, new Set([D2]))).toBe(false);
    expect(ruleMatches({ kind: 'h_unlisted' }, q, new Set())).toBe(true);
    expect(ruleMatches({ kind: 'hk_disjoint' }, q, new Set())).toBe(true);
    expect(ruleMatches({ kind: 'all', platform: 'macos' }, q, new Set())).toBe(false);
    expect(ruleMatches({ kind: 'nope' }, q, new Set())).toBe(false);
  });
});

describe('/admin/api/notices', () => {
  it('requires admin auth', async () => {
    const env = makeEnv();
    for (const [method, path, body] of [
      ['GET', '/rules'], ['POST', '/rules', { kind: 'all', level: 'banner', title_zh: 'x' }],
      ['GET', '/known'], ['POST', '/known', { h: D1 }], ['GET', '/seen'],
    ]) {
      const r = await call(env, method, `/admin/api/notices${path}`, { body, now: NOW });
      expect(r.status).toBe(401);
    }
    const wrong = await call(env, 'GET', '/admin/api/notices/rules', { headers: { Authorization: `Basic ${btoa('admin:no')}` }, now: NOW });
    expect(wrong.status).toBe(401);
    expect(env.DB.raw.prepare('SELECT COUNT(*) AS n FROM notice_rules').get().n).toBe(0);
  });

  it('creates, lists, updates, disables and deletes rules', async () => {
    const env = makeEnv();
    const id = await addRule(env, { kind: 'id', value: 'a.b' });
    let list = (await admin(env, 'GET', '/rules')).data.rows;
    expect(list).toHaveLength(1);
    expect(list[0]).toMatchObject({ id, kind: 'id', value: 'a.b', level: 'banner', enabled: 1, created_at: NOW });
    expect((await admin(env, 'POST', `/rules/${id}`, { level: 'dialog', title_en: 'E' })).status).toBe(200);
    list = (await admin(env, 'GET', '/rules')).data.rows;
    expect(list[0]).toMatchObject({ kind: 'id', value: 'a.b', level: 'dialog', title_en: 'E', title_zh: '中文标题' });
    expect((await admin(env, 'POST', `/rules/${id}`, { enabled: false })).status).toBe(200);
    expect((await admin(env, 'GET', '/rules')).data.rows[0].enabled).toBe(0);
    expect((await admin(env, 'POST', `/rules/${id}/delete`)).status).toBe(200);
    expect((await admin(env, 'GET', '/rules')).data.rows).toEqual([]);
    expect((await admin(env, 'POST', `/rules/${id}/disable`)).status).toBe(404);
    expect((await admin(env, 'POST', '/rules/999', { level: 'block' })).status).toBe(404);
  });

  it('validates rules', () => {
    const ok = { kind: 'all', level: 'banner', title_zh: 'x' };
    expect(normalizeRule(ok)).toMatchObject({ kind: 'all', value: null, platform: null, enabled: 1 });
    expect(normalizeRule({ ...ok, kind: 'all', value: 'ignored' }).value).toBeNull();
    const code = (body) => {
      try {
        normalizeRule(body);
        return null;
      } catch (e) {
        return e.code;
      }
    };
    expect(code({ ...ok, kind: 'x' })).toBe('bad_kind');
    expect(code({ ...ok, kind: 'h', value: 'short' })).toBe('bad_value');
    expect(code({ ...ok, kind: 'id', value: '' })).toBe('bad_value');
    expect(code({ ...ok, platform: 'ios' })).toBe('bad_platform');
    expect(code({ ...ok, level: 'loud' })).toBe('bad_level');
    expect(code({ ...ok, url: 'http://insecure.example' })).toBe('bad_url');
    expect(code({ ...ok, url: 'javascript:alert(1)' })).toBe('bad_url');
    expect(code({ ...ok, title_zh: null })).toBe('empty_text');
    expect(code({ ...ok, title_zh: 'x'.repeat(NOTICE_LIMITS.titleMax + 1) })).toBe('bad_title_zh');
    expect(code({ ...ok, enabled: 'yes' })).toBe('bad_enabled');
  });

  it('maintains the registered digest list', async () => {
    const env = makeEnv();
    expect((await admin(env, 'POST', '/known', { h: D1.toUpperCase(), label: 'one' })).status).toBe(200);
    expect((await admin(env, 'POST', '/known', { h: D1, label: 'renamed' })).status).toBe(200);
    expect((await admin(env, 'POST', '/known', { h: 'nothex' })).status).toBe(400);
    expect((await admin(env, 'GET', '/known')).data.rows).toEqual([{ h: D1, label: 'renamed', created_at: NOW }]);
    expect((await admin(env, 'POST', `/known/${D1}/remove`)).status).toBe(200);
    expect((await admin(env, 'POST', `/known/${D1}/remove`)).status).toBe(404);
  });

  it('summarises sightings across days, most frequent first', async () => {
    const env = makeEnv();
    await admin(env, 'POST', '/known', { h: D2, label: 'second' });
    await ask(env, { h: [D2], k: [D2] }, { now: NOW - DAY });
    await ask(env, { h: [D2], k: [D2] });
    await ask(env, { h: [D2], k: [D2] });
    await ask(env, { h: [D1], k: [D1] });
    await ask(env, {}, { now: NOW - 40 * DAY });
    const r = await call(env, 'GET', '/admin/api/notices/seen?days=7', { headers: basic, now: NOW });
    expect(r.status).toBe(200);
    expect(r.data.days).toBe(7);
    expect(r.data.rows).toEqual([
      { id: 'app.example.one', h: D2, hkDisjoint: 0, v: '2.12.0', p: 'android', country: '', n: 3,
        firstDay: '2026-11-16', lastDay: '2026-11-17', label: 'second' },
      { id: 'app.example.one', h: D1, hkDisjoint: 0, v: '2.12.0', p: 'android', country: '', n: 1,
        firstDay: '2026-11-17', lastDay: '2026-11-17', label: null },
    ]);
    const all = await call(env, 'GET', '/admin/api/notices/seen?days=999&limit=1', { headers: basic, now: NOW });
    expect(all.data.days).toBe(NOTICE_LIMITS.seenDaysMax);
    expect(all.data.rows).toHaveLength(1);
  });
});

describe('/dev/notices', () => {
  it('renders rules and sightings for a dev session and redirects otherwise', async () => {
    const env = makeEnv();
    await addRule(env, { kind: 'h', value: D1, title_zh: '<b>标题</b>' });
    await ask(env);
    expect((await call(env, 'GET', '/dev/notices', { now: NOW })).status).toBe(303);
    const dev = await registerUser(env, 'dev', { now: NOW });
    await call(env, 'POST', `/admin/api/accounts/${dev.id}/role`, { headers: basic, body: { role: 'dev' }, now: NOW });
    const token = 'ntok'.padEnd(43, 'x');
    env.DB.raw.prepare('INSERT INTO dev_sessions (token_hash, account_id, expires_at) VALUES (?, ?, ?)')
      .run(hex(await sha256(new TextEncoder().encode(token))), dev.id, NOW + DAY);
    const page = await call(env, 'GET', '/dev/notices', { headers: { Cookie: `fushi_dev=${token}` }, now: NOW });
    expect(page.status).toBe(200);
    expect(page.data).toContain('&#60;b&#62;标题&#60;/b&#62;');
    expect(page.data).not.toContain('<b>标题');
    expect(page.data).toContain('app.example.one');
    expect(page.data).toContain(D1.slice(0, 12));
  });
});
