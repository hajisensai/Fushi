// 项目数据（迁移 0018；src/project_stats.js、/dev/project）：GitHub 与官网的每日快照、节流、失败兜底、页面。
import { describe, expect, it } from 'vitest';
import { BASE, call, makeEnv, registerUser } from './harness.js';
import {
  PROJECT_LIMITS,
  assetPlatform,
  githubRepos,
  projectStats,
  refreshProjectStats,
  summarizeReleases,
} from '../src/project_stats.js';
import { hex, sha256 } from '../src/util.js';
import { lineChart } from '../src/devconsole.js';

const NOW = Date.UTC(2026, 9, 21, 12);
const DAY = 24 * 3600 * 1000;
const HOUR = 3600 * 1000;
const basic = { Authorization: `Basic ${btoa('admin:pw')}` };
const REPO = 'hajisensai/Fushi';

const RELEASES = [
  {
    tag_name: 'v3.0.0', prerelease: false, draft: false, published_at: '2026-10-10T00:00:00Z',
    assets: [
      { name: 'fushi-3.0.0-arm64-v8a.apk', download_count: 100 },
      { name: 'fushi-3.0.0-windows-setup.exe', download_count: 50 },
      { name: 'fushi-3.0.0-macos-arm64.dmg', download_count: 5 },
      { name: 'fushi-3.0.0-ios.ipa', download_count: 2 },
      { name: 'SHA256SUMS.txt', download_count: 999 },
    ],
  },
  { tag_name: 'v2.9.1-beta.1', prerelease: true, draft: false, published_at: '2026-09-01T00:00:00Z', assets: [{ name: 'a.apk', download_count: 7 }] },
  { tag_name: 'vendor-libmpv', prerelease: true, draft: false, published_at: '2026-10-11T00:00:00Z', assets: [{ name: 'mpv.7z', download_count: 19000 }] },
  { tag_name: 'v9.9.9', prerelease: false, draft: true, published_at: null, assets: [{ name: 'x.apk', download_count: 1 }] },
];

/** 假上游：按 URL 回包，记下每次请求。stars 可变，用来模拟增长。 */
function fakeUpstream({ stars = 491, failGithub = false, graphql = null, starHistory = null } = {}) {
  const calls = [];
  // starHistory：/stargazers/history 的回包（按周数组，或 202 时的非数组）；null = 该接口 404（不影响其余数字）。
  const state = { stars, failGithub, graphql, starHistory };
  const f = async (url, init = {}) => {
    calls.push({ url, init });
    const u = new URL(url);
    if (u.host === 'api.github.com') {
      if (state.failGithub) return new Response('rate limited', { status: 403 });
      if (/^\/repos\/[^/]+\/[^/]+$/.test(u.pathname)) {
        return Response.json({ stargazers_count: state.stars, forks_count: 30, subscribers_count: 4, open_issues_count: 33 });
      }
      if (u.pathname.endsWith('/releases')) return Response.json(u.searchParams.get('page') === '1' ? RELEASES : []);
      if (u.pathname.endsWith('/stargazers/history') && state.starHistory) {
        return Response.json(state.starHistory, { status: Array.isArray(state.starHistory) ? 200 : 202 });
      }
      if (u.pathname.endsWith('/traffic/views')) {
        return Response.json({ count: 40, uniques: 12, views: [{ timestamp: '2026-10-20T00:00:00Z', count: 40, uniques: 12 }] });
      }
      if (u.pathname.endsWith('/traffic/clones')) {
        return Response.json({ count: 6, uniques: 3, clones: [{ timestamp: '2026-10-20T00:00:00Z', count: 6, uniques: 3 }] });
      }
    }
    if (u.host === 'api.cloudflare.com') {
      return Response.json(state.graphql ?? { data: { viewer: { zones: [{ httpRequests1dGroups: [] }] } }, errors: null });
    }
    return new Response('not found', { status: 404 });
  };
  return { f, calls, state };
}

function siteGroup(date, pageViews) {
  return {
    dimensions: { date },
    sum: { requests: pageViews * 10, pageViews, bytes: 5 * 1024 ** 3, countryMap: [{ clientCountryName: 'JP', requests: 70 }, { clientCountryName: 'CN', requests: 30 }] },
    uniq: { uniques: Math.round(pageViews / 2) },
  };
}

function rows(env, sql) {
  return env.DB.raw.prepare(sql).all();
}

let devSeq = 0;
async function devCall(env, method, path, opts = {}) {
  const dev = await registerUser(env, 'dev', { now: NOW });
  expect((await call(env, 'POST', `/admin/api/accounts/${dev.id}/role`, { headers: basic, body: { role: 'dev' }, now: NOW })).status).toBe(200);
  devSeq += 1;
  const token = `ptok${devSeq}`.padEnd(43, 'x');
  env.DB.raw.prepare('INSERT INTO dev_sessions (token_hash, account_id, expires_at) VALUES (?, ?, ?)')
    .run(hex(await sha256(new TextEncoder().encode(token))), dev.id, NOW + DAY);
  return call(env, method, path, { ...opts, headers: { Cookie: `fushi_dev=${token}`, ...(opts.headers || {}) }, now: opts.now ?? NOW });
}

describe('Release 汇总', () => {
  it('资产名按平台归类，校验文件不算', () => {
    expect(assetPlatform('fushi-3.0.0-arm64-v8a.apk')).toBe('android');
    expect(assetPlatform('fushi-3.0.0-windows-setup.exe')).toBe('windows');
    expect(assetPlatform('fushi-3.0.0-macos-arm64.zip')).toBe('macos');
    expect(assetPlatform('fushi-3.0.0-ios.ipa')).toBe('ios');
    expect(assetPlatform('fushi-server-linux-x64.tar.gz')).toBe('linux');
    expect(assetPlatform('latest.json')).toBeNull();
    expect(assetPlatform('foo.sha256')).toBeNull();
    expect(assetPlatform('weights.onnx')).toBe('other');
  });

  it('只算 v 开头、非草稿的 App Release，近期按发布时间倒序', () => {
    const s = summarizeReleases(RELEASES);
    expect(s.downloads).toBe(100 + 50 + 5 + 2 + 7);
    expect(s.recent.map((r) => r.tag)).toEqual(['v3.0.0', 'v2.9.1-beta.1']);
    expect(s.recent[0]).toMatchObject({ total: 157, prerelease: false, platforms: { android: 100, windows: 50, macos: 5, ios: 2, linux: 0, other: 0 } });
  });

  it('GITHUB_REPOS 覆盖默认列表，形状不对的丢掉', () => {
    expect(githubRepos({})).toContain(REPO);
    expect(githubRepos({ GITHUB_REPOS: ' a/b , bad, c/d.e ' })).toEqual(['a/b', 'c/d.e']);
  });
});

describe('refreshProjectStats：GitHub', () => {
  it('写当天一行 + Release 明细；没 token 不取 traffic、不带 Authorization', async () => {
    const up = fakeUpstream();
    const env = makeEnv({ PROJECT_FETCH: up.f, GITHUB_REPOS: REPO });
    await refreshProjectStats(env, NOW);
    expect(rows(env, 'SELECT day, repo, stars, forks, watchers, open_issues, downloads FROM repo_daily')).toEqual([
      { day: '2026-10-21', repo: REPO, stars: 491, forks: 30, watchers: 4, open_issues: 33, downloads: 164 },
    ]);
    expect(up.calls.some((c) => c.url.includes('/traffic/'))).toBe(false);
    expect(up.calls.every((c) => !c.init.headers?.Authorization)).toBe(true);
    expect(up.calls.every((c) => c.init.headers?.['User-Agent'])).toBe(true);
    const st = await projectStats(env, NOW);
    expect(st.repos[0].releases[0].tag).toBe('v3.0.0');
    expect(st.githubStatus).toMatchObject({ okAt: NOW, error: null });
    expect(st.site.configured).toBe(false);
  });

  it('节流：间隔内不再打上游；force 照打；同一天覆盖写', async () => {
    const up = fakeUpstream();
    const env = makeEnv({ PROJECT_FETCH: up.f, GITHUB_REPOS: REPO });
    await refreshProjectStats(env, NOW);
    const n = up.calls.length;
    await refreshProjectStats(env, NOW + PROJECT_LIMITS.githubEveryMs - 1);
    expect(up.calls.length).toBe(n);
    up.state.stars = 500;
    await refreshProjectStats(env, NOW + HOUR, { force: true });
    expect(up.calls.length).toBe(2 * n);
    expect(rows(env, 'SELECT stars FROM repo_daily')).toEqual([{ stars: 500 }]);
    await refreshProjectStats(env, NOW + PROJECT_LIMITS.githubEveryMs + HOUR);
    expect(up.calls.length).toBe(3 * n);
  });

  it('上游 403：保留上次的行与成功时刻，只记错误；失败也算一次尝试（不每 30 分钟重打）', async () => {
    const up = fakeUpstream();
    const env = makeEnv({ PROJECT_FETCH: up.f, GITHUB_REPOS: REPO });
    await refreshProjectStats(env, NOW);
    up.state.failGithub = true;
    const later = NOW + PROJECT_LIMITS.githubEveryMs;
    await refreshProjectStats(env, later);
    const st = await projectStats(env, later);
    expect(st.githubStatus.okAt).toBe(NOW);
    expect(st.githubStatus.error).toContain('HTTP 403');
    expect(st.repos[0].latest.stars).toBe(491);
    const n = up.calls.length;
    await refreshProjectStats(env, later + HOUR);
    expect(up.calls.length).toBe(n);
  });

  it('网络错误也只记状态，不抛', async () => {
    const env = makeEnv({
      GITHUB_REPOS: REPO,
      PROJECT_FETCH: async () => {
        throw new TypeError('fetch failed');
      },
    });
    await refreshProjectStats(env, NOW);
    expect((await projectStats(env, NOW)).githubStatus).toMatchObject({ okAt: null, error: expect.stringContaining('network error') });
  });

  it('有 token 时带 Authorization 并取 traffic', async () => {
    const up = fakeUpstream();
    const env = makeEnv({ PROJECT_FETCH: up.f, GITHUB_REPOS: REPO, GITHUB_TOKEN: 'ghp_test' });
    await refreshProjectStats(env, NOW);
    expect(up.calls.every((c) => c.init.headers?.Authorization === 'Bearer ghp_test')).toBe(true);
    expect((await projectStats(env, NOW)).repos[0].traffic.views.count).toBe(40);
  });

  it('star 走势从 /stargazers/history 回补：一次请求，按周展开到天，倒推每一天', async () => {
    const week = (y, m, d, days) => ({ week: Date.UTC(y, m - 1, d) / 1000, total: days.reduce((a, b) => a + b, 0), days });
    // GitHub 按周日起算、新的在前；08-02 那周在 30 天窗口（09-22 起）之外，不计入。
    const up = fakeUpstream({
      stars: 250,
      starHistory: [
        week(2026, 10, 18, [0, 0, 50, 10, 0, 0, 0]),
        week(2026, 10, 4, [0, 40, 0, 0, 0, 0, 0]),
        week(2026, 8, 2, [150, 0, 0, 0, 0, 0, 0]),
      ],
    });
    const env = makeEnv({ PROJECT_FETCH: up.f, GITHUB_REPOS: REPO });
    await refreshProjectStats(env, NOW);
    const star = up.calls.filter((c) => c.url.includes('/stargazers'));
    // 不碰只对管理员开放的 /stargazers 列表。
    expect(star.map((c) => new URL(c.url).pathname)).toEqual([`/repos/${REPO}/stargazers/history`]);
    const t = (await projectStats(env, NOW)).repos[0].starTrend;
    expect(t).toHaveLength(PROJECT_LIMITS.trendDays);
    expect(t[0]).toEqual({ day: '2026-09-22', stars: 150 });
    expect(t.find((d) => d.day === '2026-10-04').stars).toBe(150);
    expect(t.find((d) => d.day === '2026-10-05').stars).toBe(190);
    expect(t.find((d) => d.day === '2026-10-19').stars).toBe(190);
    expect(t.at(-2)).toEqual({ day: '2026-10-20', stars: 240 });
    expect(t.at(-1)).toEqual({ day: '2026-10-21', stars: 250 });
  });

  it('GitHub 统计还没算好（202 + 非数组）：不写历史，退回每日快照，也不算取数失败', async () => {
    const up = fakeUpstream({ starHistory: {} });
    const env = makeEnv({ PROJECT_FETCH: up.f, GITHUB_REPOS: REPO });
    await refreshProjectStats(env, NOW);
    const st = await projectStats(env, NOW);
    expect(st.githubStatus.error).toBeNull();
    expect(st.repos[0].starTrend).toEqual([{ day: '2026-10-21', stars: 491 }]);
  });

  it('stargazers 取不到不影响其余数字', async () => {
    const up = fakeUpstream(); // stargazers 404
    const env = makeEnv({ PROJECT_FETCH: up.f, GITHUB_REPOS: REPO });
    await refreshProjectStats(env, NOW);
    const st = await projectStats(env, NOW);
    expect(st.githubStatus.error).toBeNull();
    expect(st.repos[0].starTrend).toEqual([{ day: '2026-10-21', stars: 491 }]);
  });

  it('star 增量与每日趋势取自历史行', async () => {
    const env = makeEnv({ GITHUB_REPOS: REPO });
    const ins = env.DB.raw.prepare(`INSERT INTO repo_daily (day, repo, stars, forks, watchers, open_issues, downloads, fetched_at)
      VALUES (?, ?, ?, 0, 0, 0, ?, 0)`);
    ins.run('2026-09-10', REPO, 300, 1000); // 30 天前之前
    ins.run('2026-10-14', REPO, 450, 1800); // 恰好 7 天前
    ins.run('2026-10-20', REPO, 480, 2000);
    ins.run('2026-10-21', REPO, 491, 2100);
    const r = (await projectStats(env, NOW)).repos[0];
    expect(r).toMatchObject({ stars7: 41, stars30: 191, downloads7: 300 });
    expect(r.trend.map((d) => [d.day, d.starsDelta, d.downloadsDelta])).toEqual([
      ['2026-10-21', 11, 100],
      ['2026-10-20', 30, 200],
      ['2026-10-14', 150, 800],
    ]);
  });
});

describe('refreshProjectStats：官网', () => {
  const cfg = { CF_ANALYTICS_TOKEN: 'cf_test', CF_ZONE_ID: 'zone1', GITHUB_REPOS: REPO };

  it('没配置不打 Cloudflare', async () => {
    const up = fakeUpstream();
    await refreshProjectStats(makeEnv({ PROJECT_FETCH: up.f, GITHUB_REPOS: REPO }), NOW);
    expect(up.calls.some((c) => c.url.includes('cloudflare'))).toBe(false);
  });

  it('首次回补 30 天、之后只补最近几天；按日覆盖写，汇总近 30 天与国家', async () => {
    const up = fakeUpstream({
      graphql: { data: { viewer: { zones: [{ httpRequests1dGroups: [siteGroup('2026-10-20', 4000), siteGroup('2026-10-21', 100)] }] } } },
    });
    const env = makeEnv({ PROJECT_FETCH: up.f, ...cfg });
    await refreshProjectStats(env, NOW);
    const q = JSON.parse(up.calls.find((c) => c.url.includes('graphql')).init.body);
    expect(q.variables).toEqual({ zone: 'zone1', since: '2026-09-22', until: '2026-10-21' });
    expect(up.calls.find((c) => c.url.includes('graphql')).init.headers.Authorization).toBe('Bearer cf_test');

    up.state.graphql = { data: { viewer: { zones: [{ httpRequests1dGroups: [siteGroup('2026-10-21', 900)] }] } } };
    const later = NOW + PROJECT_LIMITS.siteEveryMs;
    await refreshProjectStats(env, later);
    const q2 = JSON.parse(up.calls.filter((c) => c.url.includes('graphql')).at(-1).init.body);
    expect(q2.variables.since).toBe('2026-10-19');
    expect(rows(env, 'SELECT day, page_views FROM site_daily ORDER BY day')).toEqual([
      { day: '2026-10-20', page_views: 4000 },
      { day: '2026-10-21', page_views: 900 },
    ]);
    const s = (await projectStats(env, later)).site;
    expect(s.totals.pageViews).toBe(4900);
    expect(s.yesterday.page_views).toBe(4000);
    expect(s.countries).toEqual([{ key: 'JP', n: 140 }, { key: 'CN', n: 60 }]);
  });

  it('GraphQL 报错记进状态，不写行', async () => {
    const up = fakeUpstream({ graphql: { data: null, errors: [{ message: 'Rate limiter budget depleted' }] } });
    const env = makeEnv({ PROJECT_FETCH: up.f, ...cfg });
    await refreshProjectStats(env, NOW);
    const s = (await projectStats(env, NOW)).site;
    expect(s.status).toMatchObject({ okAt: null, error: 'graphql: Rate limiter budget depleted' });
    expect(s.days).toEqual([]);
  });
});

describe('/dev/project', () => {
  it('需要开发者会话；显示 star、Release 下载、未配置提示', async () => {
    const up = fakeUpstream();
    const env = makeEnv({ PROJECT_FETCH: up.f, GITHUB_REPOS: REPO });
    expect((await call(env, 'GET', '/dev/project', { now: NOW })).status).toBe(303);
    await refreshProjectStats(env, NOW);
    const page = await devCall(env, 'GET', '/dev/project');
    expect(page.status).toBe(200);
    expect(page.data).toContain('项目数据');
    expect(page.data).toContain('<b>491</b>');
    expect(page.data).toContain('v3.0.0');
    expect(page.data).toContain('CF_ANALYTICS_TOKEN');
    // App 用户放最上面；下载只有今天一条快照时说明从哪天开始记录，而不是只说「不够画图」。
    expect(page.data.indexOf('App 用户')).toBeLessThan(page.data.indexOf(REPO));
    expect(page.data).toContain('30 日活跃');
    expect(page.data).toContain('从 10-21 开始每天记录');
    // 配置类说明不上页面（README 里有），页面只放数据。
    expect(page.data).not.toContain('GITHUB_TOKEN');
    expect(page.data).not.toContain('<script');
  });

  it('官网与 traffic 有数据时渲染表格与折线', async () => {
    const up = fakeUpstream({
      graphql: { data: { viewer: { zones: [{ httpRequests1dGroups: [
        siteGroup('2026-10-19', 3000), siteGroup('2026-10-20', 4848), siteGroup('2026-10-21', 10)] }] } } },
    });
    const env = makeEnv({ PROJECT_FETCH: up.f, GITHUB_REPOS: REPO, GITHUB_TOKEN: 't', CF_ANALYTICS_TOKEN: 'c', CF_ZONE_ID: 'z' });
    await refreshProjectStats(env, NOW);
    const page = await devCall(env, 'GET', '/dev/project');
    expect(page.data).toContain('4,848');
    // 官网图只画已完结的 10-19、10-20；当天（10-21，10 次）不进图。
    expect(page.data).toContain('<title>2026-10-20 · 浏览 4,848');
    expect(page.data).not.toContain('<title>2026-10-21 · 浏览');
    expect(page.data).toContain('<polyline');
    expect(page.data).toContain('GitHub 访问（近 14 天）');
    expect(page.data).toContain('日本');
  });

  it('折线图：缺数据断线而不是画成 0；每天一个悬停提示；y 轴从 0 起', () => {
    const svg = lineChart('每日下载', ['2026-10-01', '2026-10-02', '2026-10-03', '2026-10-04'],
      [{ label: '下载', values: [5, null, 30, 40] }]);
    // 只剩 10-03→10-04 一段（10-01 单点成不了线），且没有被拉到 y=98（0）的点。
    expect(svg.match(/<polyline/g)).toHaveLength(1);
    expect(svg).toContain('points="66.67,26.00 100.00,2.00"');
    expect(svg.match(/<title>/g)).toHaveLength(4);
    expect(svg).toContain('<title>2026-10-02 · 下载 —</title>');
    expect(svg).toContain('<span>40</span><span>20</span><span>0</span>');
    expect(svg).toContain('<span>10-01</span><span>10-04</span>');
    expect(lineChart('Star', ['2026-10-01'], [{ label: 'Star', values: [3] }])).toContain('数据还不够画图');
  });

  it('折线图 y 轴取整刻度，顶部不留大片空白；累计量不从 0 起', () => {
    const axis = (values, opts) => lineChart('t', ['2026-10-01', '2026-10-02'], [{ label: 'a', values }], opts)
      .match(/<div class="yax">(.*?)<\/div>/)[1].replace(/<\/?span>/g, ' ').trim().split(/\s+/);
    expect(axis([0, 2333])).toEqual(['3,000', '1,500', '0']);
    expect(axis([0, 1248])).toEqual(['1,600', '800', '0']);
    expect(axis([0, 7])).toEqual(['8', '4', '0']);
    expect(axis([826, 987], { zero: false })).toEqual(['1,000', '900', '800']);
    expect(axis([5, 5])).toEqual(['6', '3', '0']);
  });

  it('立即刷新：忽略节流重新取，回到页面', async () => {
    const up = fakeUpstream();
    const env = makeEnv({ PROJECT_FETCH: up.f, GITHUB_REPOS: REPO });
    await refreshProjectStats(env, NOW);
    up.state.stars = 777;
    const r = await devCall(env, 'POST', '/dev/project/refresh', { headers: { Origin: BASE } });
    expect(r.status).toBe(303);
    expect(r.res.headers.get('Location')).toBe('/dev/project');
    expect(rows(env, 'SELECT stars FROM repo_daily')).toEqual([{ stars: 777 }]);
  });
});
