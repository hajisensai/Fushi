import { describe, expect, it } from 'vitest';
import { JPEG, call, entry, makeEnv, registerUser } from './harness.js';
import { esc, safeImage } from '../src/pages.js';

const NOW = Date.UTC(2026, 8, 30, 12);
const done = (date) => ({ finishedAt: Date.parse(`${date}T10:00:00Z`), finishedDate: date });
const basic = { Authorization: `Basic ${btoa('admin:pw')}` };

async function upload(env, u, entries, daily = []) {
  const r = await call(env, 'POST', '/v1/shelf', { key: u.key, account: u.id, body: { reset: true, put: entries, daily }, now: NOW });
  if (r.status !== 200) throw new Error(JSON.stringify(r.data));
  return r.data.works;
}

async function page(env, path, opts = {}) {
  const r = await call(env, 'GET', path, { now: NOW, ...opts });
  return { status: r.status, html: typeof r.data === 'string' ? r.data : JSON.stringify(r.data), res: r.res };
}

/** 页面里不得出现任何脚本入口。 */
function expectNoScript(html) {
  expect(html).not.toMatch(/<script/i);
  expect(html).not.toMatch(/\son[a-z]+\s*=/i);
  expect(html).not.toMatch(/javascript:/i);
}

describe('转义与图片地址', () => {
  it('esc 转义五个 HTML 特殊字符', () => {
    expect(esc(`<a href="x" title='y'>&</a>`)).toBe('&#60;a href=&#34;x&#34; title=&#39;y&#39;&#62;&#38;&#60;/a&#62;');
    expect(esc(null)).toBe('');
  });

  it('safeImage 只放行本站 /img/ 与封面白名单 https', () => {
    expect(safeImage('/img/a/abc-1.jpg')).toBe('/img/a/abc-1.jpg');
    expect(safeImage('https://image.tmdb.org/t/p/w200/x.jpg')).toBe('https://image.tmdb.org/t/p/w200/x.jpg');
    expect(safeImage('https://evil.example/x.jpg')).toBeNull();
    expect(safeImage('http://image.tmdb.org/x.jpg')).toBeNull();
    expect(safeImage('javascript:alert(1)')).toBeNull();
    expect(safeImage('/img/../admin')).toBeNull();
    expect(safeImage('/img/a" onerror="x')).toBeNull();
    expect(safeImage('//evil.example/x.jpg')).toBeNull();
    expect(safeImage(null)).toBeNull();
  });
});

describe('/u/:id', () => {
  it('卡片 + 读完数/名次/字数 + 最近读完（封面、标题、作者、日期、读者数）', async () => {
    const env = makeEnv();
    const a = await registerUser(env, 'alice', { now: NOW });
    const b = await registerUser(env, 'bob', { now: NOW });
    await upload(env, a, [
      entry('book', ['t:novel|'], 'Novel & Co', { ...done('2026-09-29'), author: 'Writer', coverUrl: 'https://image.tmdb.org/t/p/w200/c.jpg' }),
      entry('manga', ['t:comic|'], 'Comic', done('2026-09-20')),
      entry('book', ['t:reading|'], 'Still Reading'),
    ], [{ date: '2026-09-29', chars: 12345 }]);
    await upload(env, b, [entry('book', ['t:novel|'], 'Novel & Co', { ...done('2026-09-28'), author: 'Writer' })]);
    await call(env, 'PUT', '/v1/me/avatar', { key: a.key, account: a.id, body: JPEG, now: NOW });

    const r = await page(env, `/u/${a.id}`);
    expect(r.status).toBe(200);
    expect(r.res.headers.get('Content-Type')).toBe('text/html; charset=utf-8');
    // default-src 'none' 且没放开 script-src：即便转义漏了，脚本也跑不起来。
    expect(r.res.headers.get('Content-Security-Policy')).toContain("default-src 'none'");
    expect(r.res.headers.get('Content-Security-Policy')).not.toContain('script-src');
    expect(r.html).toContain('<meta name="viewport"');
    expect(r.html).toContain('prefers-color-scheme:dark');
    expect(r.html).toContain('max-width:720px');
    expect(r.html).toContain(`href="fushi://leaderboard/user/${a.id}"`);
    expect(r.html).toContain('在 Fushi 中打开');
    expect(r.html).toContain(`alice<span class="disc">#${String(a.discriminator).padStart(4, '0')}</span>`);
    expect(r.html).toMatch(/<img class="avatar" src="\/img\/a\/[^"]+"/);
    expect(r.html).toContain('12,345'); // 字数
    expect(r.html).toContain('第 1 名');
    expect(r.html).toContain('Novel &#38; Co'); // 标题转义
    expect(r.html).toContain('Writer');
    expect(r.html).toContain('2026-09-29 读完');
    expect(r.html).toContain('2 人读过');
    expect(r.html).toContain('src="https://image.tmdb.org/t/p/w200/c.jpg"');
    expect(r.html).toContain('Comic');
    expect(r.html).not.toContain('Still Reading'); // 在读不算最近读完
    expect(r.html.indexOf('Novel')).toBeLessThan(r.html.indexOf('Comic')); // 读完时间倒序
    expectNoScript(r.html);
  });

  it('最近读完只列 30 部', async () => {
    const env = makeEnv();
    const a = await registerUser(env, 'alice', { now: NOW });
    const many = Array.from({ length: 35 }, (_, i) => entry('book', [`t:w${i}|`], `Work-${i}-end`, done(`2026-08-${String(i % 28 + 1).padStart(2, '0')}`)));
    await upload(env, a, many);
    const r = await page(env, `/u/${a.id}`);
    expect(r.html.match(/Work-\d+-end/g)).toHaveLength(30);
  });

  it('<script> 昵称与标题 / 作者全部被转义', async () => {
    const env = makeEnv();
    const a = await registerUser(env, '<script>x</script>', { now: NOW });
    await upload(env, a, [entry('book', ['t:evil|'], '<img src=x onerror=alert(1)>', { ...done('2026-09-29'), author: '"><script>y</script>' })]);
    const r = await page(env, `/u/${a.id}`);
    expect(r.status).toBe(200);
    expect(r.html).toContain('&#60;script&#62;x&#60;/script&#62;');
    expect(r.html).toContain('&#60;img src=x onerror=alert(1)&#62;');
    expect(r.html).toContain('&#34;&#62;&#60;script&#62;y&#60;/script&#62;');
    expect(r.html).not.toContain('<script');
    expect(r.html).not.toContain('<img src=x');
    // <title> 里同样转义。
    expect(r.html).toMatch(/<title>&#60;script&#62;x&#60;\/script&#62;#\d{4} · Fushi<\/title>/);
    const rank = await page(env, '/rank?window=all');
    expect(rank.html).toContain('&#60;script&#62;x&#60;/script&#62;');
    expect(rank.html).not.toContain('<script');
    const w = await page(env, `/w/${env.DB.raw.prepare('SELECT id FROM works').get().id}`);
    expect(w.html).toContain('&#60;script&#62;x&#60;/script&#62;');
    expect(w.html).not.toContain('<script');
    expect(w.html).not.toContain('<img src=x');
  });

  it('visibility=friends：只显示卡片，书架处「仅好友可见」；签名观看者也按匿名渲染', async () => {
    const env = makeEnv();
    const a = await registerUser(env, 'alice', { now: NOW });
    const b = await registerUser(env, 'bob', { now: NOW });
    await upload(env, a, [entry('book', ['t:secret|'], 'Secret Book', done('2026-09-29'))]);
    await call(env, 'PATCH', '/v1/me', { key: a.key, account: a.id, body: { visibility: 'friends' }, now: NOW });
    const [x, y] = [a.id, b.id].sort();
    env.DB.raw.prepare("INSERT INTO friends (a, b, requester, state, created_at) VALUES (?1, ?2, ?1, 'accepted', 0)").run(x, y);

    const r = await page(env, `/u/${a.id}`);
    expect(r.status).toBe(200);
    expect(r.html).toContain('仅好友可见');
    expect(r.html).toContain('alice');
    expect(r.html).not.toContain('Secret Book');
    // 好友带签名来看网页：网页不认签名，结果与匿名相同（边缘缓存的是同一份）。
    const signed = await page(env, `/u/${a.id}`, { key: b.key, account: b.id });
    expect(signed.html).not.toContain('Secret Book');
  });

  it('被隐藏 / 不存在 → 404 HTML（不是 JSON）', async () => {
    const env = makeEnv();
    const a = await registerUser(env, 'alice', { now: NOW });
    await call(env, 'POST', `/admin/api/accounts/${a.id}`, { headers: basic, body: { hidden: true }, now: NOW });
    for (const path of [`/u/${a.id}`, '/u/doesNotExist0000', '/w/doesNotExist0000']) {
      const r = await page(env, path);
      expect([path, r.status]).toEqual([path, 404]);
      expect(r.res.headers.get('Content-Type')).toBe('text/html; charset=utf-8');
      expect(r.html).toContain('<!doctype html>');
    }
  });
});

describe('/w/:id', () => {
  it('封面、标题、作者、读者数、最近读者（只列公开读者，人数计全体）', async () => {
    const env = makeEnv();
    const a = await registerUser(env, 'alice', { now: NOW });
    const b = await registerUser(env, 'bob', { now: NOW });
    const c = await registerUser(env, 'carol', { now: NOW });
    const [w] = await upload(env, a, [entry('book', ['t:novel|'], 'Novel', { ...done('2026-09-20'), author: 'Writer', coverUrl: 'https://lain.bgm.tv/pic/cover/l/x.jpg' })]);
    await upload(env, b, [entry('book', ['t:novel|'], 'Novel', { ...done('2026-09-25'), author: 'Writer' })]);
    await upload(env, c, [entry('book', ['t:novel|'], 'Novel', { ...done('2026-09-26'), author: 'Writer' })]);
    await call(env, 'PATCH', '/v1/me', { key: c.key, account: c.id, body: { visibility: 'friends' }, now: NOW });

    const r = await page(env, `/w/${w.workId}`);
    expect(r.status).toBe(200);
    expect(r.html).toContain(`href="fushi://leaderboard/work/${w.workId}"`);
    expect(r.html).toContain('<h1>Novel</h1>');
    expect(r.html).toContain('Writer');
    expect(r.html).toContain('src="https://lain.bgm.tv/pic/cover/l/x.jpg"');
    expect(r.html).toMatch(/<b>3<\/b><small>人读过/);
    expect(r.html).toContain(`href="/u/${b.id}"`);
    expect(r.html).toContain(`href="/u/${a.id}"`);
    expect(r.html).not.toContain(`href="/u/${c.id}"`);
    expect(r.html.indexOf(b.id)).toBeLessThan(r.html.indexOf(a.id)); // 最近读完的在前
    expectNoScript(r.html);
  });

  it('nsfw 作品封面用 CSS blur', async () => {
    const env = makeEnv();
    const a = await registerUser(env, 'alice', { now: NOW });
    const [w] = await upload(env, a, [entry('game', ['vndb:v9'], 'R18', { ...done('2026-09-20'), coverUrl: 'https://t.vndb.org/cv/1/1.jpg' })]);
    await call(env, 'POST', `/admin/api/works/${w.workId}`, { headers: basic, body: { nsfw: true }, now: NOW });
    const r = await page(env, `/w/${w.workId}`);
    expect(r.html).toContain('<span class="cover-lg nsfw"><img src="https://t.vndb.org/cv/1/1.jpg"');
    expect(r.html).toMatch(/\.nsfw img\{filter:blur\(\d+px\)/);
    const u = await page(env, `/u/${a.id}`);
    expect(u.html).toContain('<span class="cover nsfw">');
  });

  it('库里若混进非白名单封面地址，页面不出图', async () => {
    const env = makeEnv();
    const a = await registerUser(env, 'alice', { now: NOW });
    const [w] = await upload(env, a, [entry('book', ['t:x|'], 'X', done('2026-09-20'))]);
    env.DB.raw.prepare('UPDATE works SET cover_url = ?1 WHERE id = ?2').run('https://evil.example/"><b>x', w.workId);
    const r = await page(env, `/w/${w.workId}`);
    expect(r.html).not.toContain('evil.example');
    expect(r.html).toContain('cover-empty');
  });
});

describe('/rank', () => {
  it('默认 book / month，前 50；有指标 / 窗口切换链接', async () => {
    const env = makeEnv();
    const users = [];
    for (let i = 0; i < 52; i++) users.push(await registerUser(env, `u${i}`, { now: NOW }));
    for (const [i, u] of users.entries()) {
      await upload(env, u, Array.from({ length: (i % 3) + 1 }, (_, k) => entry('book', [`t:${i}-${k}|`], `b${i}-${k}`, done('2026-09-20'))));
    }
    const old = await registerUser(env, 'lastyear', { now: NOW });
    await upload(env, old, [entry('book', ['t:old|'], 'old', done('2025-01-01'))]);

    const r = await page(env, '/rank');
    expect(r.status).toBe(200);
    expect(r.html).toContain('本月书榜');
    expect(r.html.match(/<span class="rank">/g)).toHaveLength(50);
    expect(r.html).not.toContain('lastyear'); // 窗口外
    expect(r.html).toContain('<a class="on" href="/rank?metric=book&amp;window=month">');
    expect(r.html).toContain('href="/rank?metric=chars&amp;window=month"');
    expect(r.html).toContain('href="/rank?metric=book&amp;window=all"');
    expectNoScript(r.html);

    const all = await page(env, '/rank?metric=book&window=all');
    expect(all.html).toContain('总榜书榜');
    expect(all.html).toContain('<a class="on" href="/rank?metric=book&amp;window=all">');
  });

  it('非法 metric / window → 400 HTML', async () => {
    const env = makeEnv();
    const r = await page(env, '/rank?metric=<x>');
    expect(r.status).toBe(400);
    expect(r.res.headers.get('Content-Type')).toBe('text/html; charset=utf-8');
    expect(r.html).not.toContain('<x>');
    expect((await page(env, '/rank?window=year')).status).toBe(400);
  });
});
