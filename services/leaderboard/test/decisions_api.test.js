// 拍板台个人密钥与 JSON API（迁移 0024；src/decisions_api.js、/dev/keys、scripts/decisions.mjs 的 HTTP 模式）。
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import worker from '../src/worker.js';
import { BASE, call, makeEnv, registerUser } from './harness.js';
import { hex, sha256 } from '../src/util.js';
import { DECISION_KEY_LIMITS, DECISION_KEY_RE } from '../src/decisions_api.js';
import { addSql, httpBackend, main, pickBackend } from '../scripts/decisions.mjs';

const NOW = Date.UTC(2026, 10, 21, 12);
const DAY = 24 * 3600 * 1000;
const basic = { Authorization: `Basic ${btoa('admin:pw')}` };

let seq = 0;
async function devSession(env, nickname = 'dev') {
  const dev = await registerUser(env, nickname, { now: NOW });
  expect((await call(env, 'POST', `/admin/api/accounts/${dev.id}/role`, { headers: basic, body: { role: 'dev' }, now: NOW })).status).toBe(200);
  seq += 1;
  const token = `ktok${seq}`.padEnd(43, 'x');
  env.DB.raw.prepare('INSERT INTO dev_sessions (token_hash, account_id, expires_at) VALUES (?, ?, ?)')
    .run(hex(await sha256(new TextEncoder().encode(token))), dev.id, NOW + DAY);
  return { dev, cookie: `fushi_dev=${token}` };
}

function form(env, s, path, fields = {}, { origin = BASE, now = NOW } = {}) {
  return call(env, 'POST', path, {
    headers: { Cookie: s.cookie, Origin: origin, 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new TextEncoder().encode(new URLSearchParams(fields).toString()),
    now,
  });
}

/** 走 /dev/keys 签发一把，从响应页里取出明文。 */
async function issueKey(env, s, label = '') {
  const r = await form(env, s, '/dev/keys', { label });
  expect(r.status).toBe(200);
  const m = /<code>(fdk_[A-Za-z0-9_-]{43})<\/code>/.exec(r.data);
  expect(m).not.toBeNull();
  return m[1];
}

function api(env, key, method, path, { body, now = NOW, headers = {} } = {}) {
  return call(env, method, path, { headers: { ...(key ? { Authorization: `Bearer ${key}` } : {}), ...headers }, body, now });
}

function row(env, id) {
  return env.DB.raw.prepare('SELECT * FROM decisions WHERE id = ?').get(id);
}

const ITEMS = [
  { id: 'pr1', kind: 'pr', title: '缓存取舍', ask: '要不要按集缓存？', rec: 'do' },
  { id: 'fb1', kind: 'feedback', title: '点句子跳播', ask: '三选一', choices: [{ key: 'a', label: '中键' }, { key: 'b', label: '左键' }] },
];

describe('/dev/keys', () => {
  it('需要开发者会话；签发的明文只出现一次，列表只显示末 4 位与备注；库里只存哈希', async () => {
    const env = makeEnv();
    expect((await call(env, 'GET', '/dev/keys', { now: NOW })).status).toBe(303);
    const s = await devSession(env);
    const page = await call(env, 'GET', '/dev/keys', { headers: { Cookie: s.cookie }, now: NOW });
    expect(page.data).toContain('还没有签发过');
    expect(page.data).toContain('<a href="/dev/keys">密钥</a>');
    const key = await issueKey(env, s, '笔记本');
    expect(DECISION_KEY_RE.test(key)).toBe(true);
    const after = await call(env, 'GET', '/dev/keys', { headers: { Cookie: s.cookie }, now: NOW });
    expect(after.data).not.toContain(key);
    expect(after.data).toContain(`fdk_…${key.slice(-4)}`);
    expect(after.data).toContain('笔记本');
    const stored = env.DB.raw.prepare('SELECT * FROM decision_api_keys').get();
    expect(stored.token_hash).toBe(hex(await sha256(new TextEncoder().encode(key))));
    expect(JSON.stringify(stored)).not.toContain(key);
  });

  it('每人最多 5 把未吊销的；吊销后能再签；只能吊销自己的；POST 验 Origin', async () => {
    const env = makeEnv();
    const s = await devSession(env, 'a');
    const other = await devSession(env, 'b');
    for (let i = 0; i < DECISION_KEY_LIMITS.activePerAccount; i += 1) await issueKey(env, s);
    const full = await form(env, s, '/dev/keys', {});
    expect(full.data).toContain('最多 5 把');
    expect(full.data).not.toMatch(/<code>fdk_[A-Za-z0-9_-]{43}<\/code>/);
    const id = env.DB.raw.prepare('SELECT id FROM decision_api_keys WHERE account_id = ? LIMIT 1').get(s.dev.id).id;
    expect((await form(env, other, `/dev/keys/${id}/revoke`)).status).toBe(404);
    expect((await form(env, s, `/dev/keys/${id}/revoke`, {}, { origin: 'https://evil.example' })).status).toBe(403);
    const r = await form(env, s, `/dev/keys/${id}/revoke`);
    expect(r.status).toBe(303);
    expect(r.res.headers.get('Location')).toBe('/dev/keys');
    expect(env.DB.raw.prepare('SELECT revoked_at FROM decision_api_keys WHERE id = ?').get(id).revoked_at).toBe(NOW);
    await issueKey(env, s);
    expect((await form(env, s, '/dev/keys', { label: 'x'.repeat(61) })).data).toContain('备注最多');
  });
});

describe('/v1/decisions 鉴权', () => {
  it('缺密钥 / 格式不对 / 不存在 / 已吊销 / 账户被撤开发者 → 401；last_used_at 节流写入', async () => {
    const env = makeEnv();
    const s = await devSession(env);
    const key = await issueKey(env, s);
    expect((await api(env, null, 'GET', '/v1/decisions')).data.error).toBe('decision_key_required');
    expect((await api(env, 'abc', 'GET', '/v1/decisions')).data.error).toBe('decision_key_required');
    expect((await api(env, `fdk_${'z'.repeat(43)}`, 'GET', '/v1/decisions')).data.error).toBe('bad_decision_key');
    // 会话 Cookie 不能当 API 凭据。
    expect((await call(env, 'GET', '/v1/decisions', { headers: { Cookie: s.cookie }, now: NOW })).status).toBe(401);

    expect((await api(env, key, 'GET', '/v1/decisions')).status).toBe(200);
    const used = () => env.DB.raw.prepare('SELECT last_used_at FROM decision_api_keys').get().last_used_at;
    expect(used()).toBe(NOW);
    await api(env, key, 'GET', '/v1/decisions', { now: NOW + 60 * 1000 });
    expect(used()).toBe(NOW);
    await api(env, key, 'GET', '/v1/decisions', { now: NOW + DECISION_KEY_LIMITS.touchEveryMs });
    expect(used()).toBe(NOW + DECISION_KEY_LIMITS.touchEveryMs);

    expect((await call(env, 'POST', `/admin/api/accounts/${s.dev.id}/role`, { headers: basic, body: { role: 'user' }, now: NOW })).status).toBe(200);
    expect((await api(env, key, 'GET', '/v1/decisions')).data.error).toBe('bad_decision_key');
    expect((await call(env, 'POST', `/admin/api/accounts/${s.dev.id}/role`, { headers: basic, body: { role: 'dev' }, now: NOW })).status).toBe(200);
    expect((await api(env, key, 'GET', '/v1/decisions')).status).toBe(200);

    const id = env.DB.raw.prepare('SELECT id FROM decision_api_keys').get().id;
    // 撤开发者时网页会话已被作废：重新开一个会话再吊销。
    const fresh = 'kfresh'.padEnd(43, 'y');
    env.DB.raw.prepare('INSERT INTO dev_sessions (token_hash, account_id, expires_at) VALUES (?, ?, ?)')
      .run(hex(await sha256(new TextEncoder().encode(fresh))), s.dev.id, NOW + DAY);
    expect((await form(env, { cookie: `fushi_dev=${fresh}` }, `/dev/keys/${id}/revoke`)).status).toBe(303);
    expect((await api(env, key, 'GET', '/v1/decisions')).data.error).toBe('bad_decision_key');
  });
});

describe('/v1/decisions 读写', () => {
  async function setup() {
    const env = makeEnv();
    const s = await devSession(env);
    return { env, s, key: await issueKey(env, s) };
  }

  it('写入：整批校验、同 id 跳过不覆盖、拒收迁移字段；列表与单条带 stage 与留言', async () => {
    const { env, key } = await setup();
    const r = await api(env, key, 'POST', '/v1/decisions', { body: { items: ITEMS } });
    expect(r.data).toEqual({ inserted: ['pr1', 'fb1'], skipped: [] });
    expect(row(env, 'pr1').created_at).toBe(NOW);
    const again = await api(env, key, 'POST', '/v1/decisions', { body: { items: [{ ...ITEMS[0], title: '改了' }] }, now: NOW + 1 });
    expect(again.data).toEqual({ inserted: [], skipped: ['pr1'] });
    expect(row(env, 'pr1').title).toBe('缓存取舍');
    const bad = await api(env, key, 'POST', '/v1/decisions', { body: { items: [{ id: 'ok1', title: 't', ask: 'a' }, { id: 'a b', title: 't', ask: 'a' }] } });
    expect(bad.status).toBe(400);
    expect(bad.data.detail).toMatch(/id/);
    expect(row(env, 'ok1')).toBeUndefined();
    expect((await api(env, key, 'POST', '/v1/decisions', { body: { items: [{ id: 'm1', title: 't', ask: 'a', verdict: 'do' }] } })).data.detail)
      .toMatch(/迁移字段/);
    expect((await api(env, key, 'POST', '/v1/decisions', { body: { items: [] } })).status).toBe(400);

    const list = await api(env, key, 'GET', '/v1/decisions');
    expect(list.data.items.map((x) => [x.id, x.stage])).toEqual([['fb1', 'todo'], ['pr1', 'todo']]);
    expect((await api(env, key, 'GET', '/v1/decisions/pr1')).data.item.notes).toEqual([]);
    expect((await api(env, key, 'GET', '/v1/decisions/nope')).status).toBe(404);
  });

  it('留言记为 Claude 并带签发人；校正决定校验方案、记无署名；结单后不能再校正', async () => {
    const { env, s, key } = await setup();
    env.DB.raw.exec(addSql(ITEMS, NOW - 10).sql);
    expect((await api(env, key, 'POST', '/v1/decisions/pr1/notes', { body: { text: '开始处理（分支 x）' } })).status).toBe(200);
    const note = env.DB.raw.prepare("SELECT * FROM decision_notes WHERE decision_id = 'pr1'").get();
    expect([note.author, note.account_id, note.body]).toEqual(['claude', s.dev.id, '开始处理（分支 x）']);
    expect((await api(env, key, 'POST', '/v1/decisions/pr1/notes', { body: { text: '  ' } })).status).toBe(400);
    expect((await api(env, key, 'POST', '/v1/decisions/nope/notes', { body: { text: 'x' } })).status).toBe(404);

    expect((await api(env, key, 'POST', '/v1/decisions/fb1/verdict', { body: { v: 'choice:z' } })).data.error).toBe('bad_choice');
    expect((await api(env, key, 'POST', '/v1/decisions/fb1/verdict', { body: { v: 'bogus' } })).data.error).toBe('bad_verdict');
    expect((await api(env, key, 'POST', '/v1/decisions/fb1/verdict', { body: { v: 'choice:b' } })).status).toBe(200);
    expect([row(env, 'fb1').verdict, row(env, 'fb1').choice, row(env, 'fb1').verdict_by]).toEqual(['choice', 'b', null]);

    expect((await api(env, key, 'POST', '/v1/decisions/pr1/close', { body: { state: 'done', text: '' } })).status).toBe(400);
    expect((await api(env, key, 'POST', '/v1/decisions/pr1/close', { body: { state: 'weird', text: 'x' } })).data.error).toBe('bad_state');
    expect((await api(env, key, 'POST', '/v1/decisions/pr1/close', { body: { state: 'dropped', text: '不需要了' } })).status).toBe(200);
    expect([row(env, 'pr1').state, row(env, 'pr1').resolution]).toEqual(['dropped', '不需要了']);
    expect((await api(env, key, 'POST', '/v1/decisions/pr1/verdict', { body: { v: 'do' } })).data.error).toBe('decision_closed');
  });

  it('个人密钥只拿拍板台字段：反馈类事项不带关联反馈的标题 / 正文 / 附件，也不带账户 id（HBK-AUDIT-024）', async () => {
    const { env, s, key } = await setup();
    const att = JSON.stringify([{ slot: 's0', kind: 'screenshot', key: 'feedback/secret-shot', bytes: 10 }]);
    env.DB.raw.prepare(`INSERT INTO feedback (id, ticket_hash, category, title, body, attachments, created_at, updated_at)
      VALUES ('fbsec1', 'h', 'bug', '反馈私密标题', '反馈私密正文', ?, ?, ?)`).run(att, NOW - 50, NOW - 50);
    env.DB.raw.exec(addSql([
      { id: 'fbsec1', kind: 'feedback', title: '按 id 关联', ask: '要不要' },
      { id: 'fbsrc1', kind: 'feedback', title: '按 source 关联', ask: '要不要', source: 'fbsec1', original: '代理摘录' },
    ], NOW - 10).sql);
    env.DB.raw.prepare("UPDATE decisions SET verdict = 'do', verdict_by = ?, verdict_at = ? WHERE id = 'fbsrc1'").run(s.dev.id, NOW - 5);
    env.DB.raw.prepare("INSERT INTO decision_notes (decision_id, author, account_id, body, created_at) VALUES ('fbsrc1', 'dev', ?, '开发者留言', ?)")
      .run(s.dev.id, NOW - 4);

    const allowedItem = new Set(['id', 'kind', 'title', 'ask', 'pros', 'cons', 'choices', 'source', 'original', 'rec', 'state',
      'resolution', 'verdict', 'choice', 'verdict_at', 'verdict_nick', 'claude_at', 'files', 'created_at', 'updated_at', 'stage', 'notes']);
    const allowedNote = new Set(['id', 'author', 'nick', 'body', 'created_at']);
    const list = await api(env, key, 'GET', '/v1/decisions');
    const one = await api(env, key, 'GET', '/v1/decisions/fbsrc1');
    const byId = await api(env, key, 'GET', '/v1/decisions/fbsec1');
    for (const r of [list, one, byId]) {
      expect(r.status).toBe(200);
      const text = JSON.stringify(r.data);
      for (const leaked of ['反馈私密标题', '反馈私密正文', 'feedback/secret-shot', s.dev.id]) expect(text).not.toContain(leaked);
      for (const item of r.data.items || [r.data.item]) {
        expect(Object.keys(item).filter((k) => !allowedItem.has(k))).toEqual([]);
        for (const n of item.notes) expect(Object.keys(n).filter((k) => !allowedNote.has(k))).toEqual([]);
      }
    }
    // 拍板台本身的字段照常带：代理摘录、决定、开发者昵称、留言、stage。
    expect(one.data.item).toMatchObject({ id: 'fbsrc1', source: 'fbsec1', original: '代理摘录', verdict: 'do', verdict_nick: 'dev', stage: 'exec' });
    expect(one.data.item.notes.map((n) => [n.author, n.nick, n.body])).toEqual([['dev', 'dev', '开发者留言']]);
    expect(byId.data.item.original).toBeNull();
  });

  it('附件：上传写 R2 并追加（不标开发者上传）、取回、删除；校验格式 / 数量 / 结单', async () => {
    const { env, key } = await setup();
    env.DB.raw.exec(addSql(ITEMS, NOW - 10).sql);
    const up = (name, text, id = 'pr1') => call(env, 'POST', `/v1/decisions/${id}/files?name=${encodeURIComponent(name)}`, {
      headers: { Authorization: `Bearer ${key}`, 'Content-Type': 'application/octet-stream' },
      body: new TextEncoder().encode(text),
      now: NOW,
    });
    const r = await up('设计 A.html', '<p>A</p>');
    expect(r.status).toBe(200);
    const files = JSON.parse(row(env, 'pr1').files);
    expect(files).toHaveLength(1);
    expect(files[0].by).toBeUndefined();
    expect(files[0].key.startsWith('decisions/pr1/')).toBe(true);
    expect(new TextDecoder().decode(env.MEDIA.store.get(files[0].key).bytes)).toBe('<p>A</p>');
    const got = await api(env, key, 'GET', '/v1/decisions/pr1/files/0');
    expect(got.data).toBe('<p>A</p>');
    expect(got.res.headers.get('Content-Security-Policy')).toContain('sandbox');

    expect((await up('x.exe', 'x')).data.error).toBe('bad_file_type');
    expect((await up('a.png', '')).data.error).toBe('no_file');
    expect((await up('a.png', 'x', 'nope')).status).toBe(404);
    for (let i = 1; i < 10; i += 1) expect((await up(`${i}.txt`, 'x')).status).toBe(200);
    expect((await up('11.txt', 'x')).data.error).toBe('too_many_files');

    const del = await api(env, key, 'DELETE', '/v1/decisions/pr1/files/0');
    expect(del.data.removed).toBe('设计 A.html');
    expect(env.MEDIA.store.has(files[0].key)).toBe(false);
    expect(JSON.parse(row(env, 'pr1').files)).toHaveLength(9);
    expect((await api(env, key, 'DELETE', '/v1/decisions/pr1/files/9')).status).toBe(404);

    await api(env, key, 'POST', '/v1/decisions/pr1/close', { body: { state: 'done', text: '做完' } });
    expect((await up('late.png', 'x')).data.error).toBe('decision_closed');
  });
});

describe('scripts/decisions.mjs HTTP 模式', () => {
  it('选后端：有密钥走 HTTP，--wrangler / --local / 没密钥走 wrangler', () => {
    expect(pickBackend({}, { FUSHI_DECISIONS_TOKEN: ' fdk_x ' }).mode).toBe('http');
    expect(pickBackend({ wrangler: true }, { FUSHI_DECISIONS_TOKEN: 'fdk_x' }).mode).toBe('wrangler');
    expect(pickBackend({ local: true }, { FUSHI_DECISIONS_TOKEN: 'fdk_x' }).mode).toBe('wrangler');
    expect(pickBackend({}, {}).mode).toBe('wrangler');
  });

  it('CLI 全套命令经 HTTP 打到 Worker：add / list / show / note / verdict / attach / files / detach / close', async () => {
    const env = makeEnv();
    const s = await devSession(env);
    const key = await issueKey(env, s);
    const fetchImpl = (url, init) => worker.fetch(new Request(url, init), env);
    const backend = httpBackend({ token: key, base: `${BASE}/`, fetchImpl });
    const dir = mkdtempSync(join(tmpdir(), 'decisions-http-'));
    const out = [];
    const run = (...argv) => main(argv, (l) => out.push(l), { backend });

    writeFileSync(join(dir, 'items.json'), JSON.stringify(ITEMS));
    await run('add', '--json', join(dir, 'items.json'));
    expect(out.pop()).toBe('写入 2 条');
    await run('add', '--json', join(dir, 'items.json'));
    expect(out.pop()).toBe('写入 0 条；已存在跳过：pr1 fb1');

    await run('verdict', 'fb1', 'choice:a');
    await run('list');
    expect(out.join('\n')).toContain('#fb1 [exec · 选 a]');
    out.length = 0;
    await run('note', 'fb1', '--text', '开始处理');
    await run('show', 'fb1');
    expect(out.pop()).toContain('· Claude');

    writeFileSync(join(dir, 'mock.html'), '<p>mock</p>');
    writeFileSync(join(dir, 'bad.exe'), 'x');
    await expect(run('attach', 'pr1', join(dir, 'bad.exe'))).rejects.toThrow(/不支持的格式/);
    await run('attach', 'pr1', join(dir, 'mock.html'));
    expect(out.pop()).toBe('#pr1 已附 1 个文件：mock.html');
    await run('files', 'pr1', '--out', join(dir, 'dl'));
    expect(readFileSync(out.pop(), 'utf8')).toBe('<p>mock</p>');
    await run('detach', 'pr1', '0');
    expect(out.pop()).toBe('#pr1 已删附件：mock.html');
    await run('close', 'pr1', '--text', '做完了');
    expect(row(env, 'pr1').state).toBe('done');

    const revoked = httpBackend({ token: `fdk_${'q'.repeat(43)}`, base: BASE, fetchImpl });
    await expect(main(['list'], () => {}, { backend: revoked })).rejects.toThrow(/HTTP 401 bad_decision_key.*\/dev\/keys/);
  });
});

describe('附件公开分享：API 与 CLI', () => {
  it('share / unshare 经 HTTP 打到 Worker；签发人记为密钥所属开发者；无密钥 401；wrangler 模式拒绝', async () => {
    const env = makeEnv();
    const s = await devSession(env);
    const key = await issueKey(env, s);
    env.DB.raw.exec(addSql([ITEMS[0]], NOW - 10).sql);
    const fetchImpl = (url, init) => worker.fetch(new Request(url, init), env);
    const backend = httpBackend({ token: key, base: BASE, fetchImpl });
    const dir = mkdtempSync(join(tmpdir(), 'decisions-share-'));
    const out = [];
    const run = (...argv) => main(argv, (l) => out.push(l), { backend });
    writeFileSync(join(dir, 'mock.html'), '<p>mock</p>');
    await run('attach', 'pr1', join(dir, 'mock.html'));

    expect((await api(env, null, 'POST', '/v1/decisions/pr1/files/0/share')).status).toBe(401);
    await run('share', 'pr1', '0');
    const line = out.pop();
    const m = /^#pr1 第 0 个附件已分享：(https?:\/\/\S+\/share\/f\/[A-Za-z0-9_-]{32})$/.exec(line);
    expect(m).not.toBeNull();
    const path = new URL(m[1]).pathname;
    expect(env.DB.raw.prepare('SELECT created_by FROM decision_file_shares').get().created_by).toBe(s.dev.id);
    await run('share', 'pr1', '0');
    expect(out.pop()).toBe(`#pr1 第 0 个附件已有分享链接：${m[1]}`);
    const got = await call(env, 'GET', path, { now: NOW });
    expect(got.data).toBe('<p>mock</p>');
    await expect(run('share', 'pr1', '5')).rejects.toThrow(/HTTP 404/);

    await run('unshare', 'pr1', '0');
    expect(out.pop()).toBe('#pr1 已撤销 mock.html 的分享链接');
    expect((await call(env, 'GET', path, { now: NOW })).status).toBe(404);
    await run('unshare', 'pr1', '0');
    expect(out.pop()).toBe('#pr1 mock.html 没有分享链接');

    const wr = pickBackend({ wrangler: true }, { FUSHI_DECISIONS_TOKEN: key });
    await expect(main(['share', 'pr1', '0'], () => {}, { backend: wr })).rejects.toThrow(/HTTP 模式/);
  });
});
