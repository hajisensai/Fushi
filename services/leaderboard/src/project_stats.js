// 项目数据：GitHub 仓库与官网 fushi.moe 的每日快照（表结构见 migrations/0018_project_stats.sql），
// 开发者处理台 /dev/project 读它渲染。
//
// 取数（refreshProjectStats，定时任务每 30 分钟调一次，按下面的间隔节流；处理台「立即刷新」强制取）：
//   - GitHub（每 GITHUB_EVERY_MS）：GITHUB_REPOS 里每个仓库的 star / fork / 关注 / 开放 issue+PR，
//     以及 App Release（tag 以 v + 数字开头；vendor-libmpv、flutter-engine-*、模型包等内部构件不算）的
//     资产下载累计与近期各平台明细。配了 GITHUB_TOKEN（只读即可）时另取 GitHub 近 14 天访问 / clone
//     （traffic API 要求对仓库有 push 权限的 token）。不配 token 也能跑，但 Worker 出口是 Cloudflare 共享 IP，
//     未认证限流按 IP 算、会随机 403——失败只记错误、保留上次成功的行，页面照常显示旧值和失败原因。
//   - 官网（每 SITE_EVERY_MS）：Cloudflare GraphQL Analytics 的 httpRequests1dGroups（zone 级每日汇总）。
//     需要 CF_ANALYTICS_TOKEN（API token，权限 Zone · Analytics · Read）与 CF_ZONE_ID；不配就不取，页面给配置说明。
//     zone 级数字含同 zone 的 rank.fushi.moe（App 心跳 / 排行榜接口）与 /releases 安装包下载：页面浏览只数
//     HTML 响应，基本就是官网与处理台的页面；独立访客按 IP 去重，会混进发心跳的 App。
//
// 写入：每仓库当天一行覆盖写 + 每次刷新几行 project_meta；官网每次回补最近 SITE_BACKFILL_DAYS 天（首次
// SITE_FIRST_DAYS 天），Cloudflare 当天的数字是累计中的，次日再取一次才完整。

import { utcDateKey } from './util.js';

const HOUR_MS = 3600 * 1000;
const DAY_MS = 24 * HOUR_MS;

export const PROJECT_LIMITS = {
  /** GitHub 刷新间隔。未认证每 IP 60 次 / 小时，一次刷新每仓库 2–4 次请求。 */
  githubEveryMs: 3 * HOUR_MS,
  /** 官网刷新间隔。 */
  siteEveryMs: 6 * HOUR_MS,
  /** 外部 API 单次超时（跨洲 TLS 冷启动要留余量）。 */
  timeoutMs: 8000,
  /** Release 列表最多翻几页（每页 100）。 */
  releasePages: 3,
  /** 页面列出的近期 Release 数。 */
  recentReleases: 12,
  /** 官网每次回补天数（Cloudflare 当天数字未完结）。 */
  siteBackfillDays: 3,
  /** 首次取官网时回补的天数。 */
  siteFirstDays: 30,
  /** 趋势表显示天数。 */
  trendDays: 30,
  /** 国家分布显示前几个。 */
  topCountries: 20,
};

export const DEFAULT_GITHUB_REPOS = ['hajisensai/Fushi', 'hajisensai/fushi-subtitles', 'hajisensai/fushi-server'];

const REPO_RE = /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/;
const APP_TAG_RE = /^v\d/;

/** 要取的仓库：GITHUB_REPOS（逗号分隔 owner/name）或默认列表。 */
export function githubRepos(env) {
  const raw = (env.GITHUB_REPOS || '').split(',').map((s) => s.trim()).filter(Boolean);
  const list = raw.length ? raw : DEFAULT_GITHUB_REPOS;
  return list.filter((r) => REPO_RE.test(r));
}

/** Release 资产名 → 平台；校验文件 / 清单返回 null（不算下载）。 */
export function assetPlatform(name) {
  const n = name.toLowerCase();
  if (/\.(sha256|sha512|sig|asc|json|txt|md)$/.test(n)) return null;
  if (n.endsWith('.apk') || n.endsWith('.aab')) return 'android';
  if (n.endsWith('.ipa')) return 'ios';
  if (n.endsWith('.dmg') || n.includes('macos') || n.includes('darwin')) return 'macos';
  if (n.endsWith('.exe') || n.endsWith('.msix') || n.includes('windows')) return 'windows';
  if (n.includes('linux') || /\.(appimage|deb|rpm|flatpak)$/.test(n)) return 'linux';
  return 'other';
}

export const RELEASE_PLATFORMS = ['android', 'windows', 'macos', 'ios', 'linux', 'other'];

/** GitHub releases 列表 → {downloads, recent:[{tag, prerelease, publishedAt, total, platforms}]}（只算 App Release）。 */
export function summarizeReleases(releases) {
  let downloads = 0;
  const recent = [];
  for (const r of releases) {
    if (r.draft || !APP_TAG_RE.test(r.tag_name || '')) continue;
    const platforms = Object.fromEntries(RELEASE_PLATFORMS.map((p) => [p, 0]));
    let total = 0;
    for (const a of r.assets || []) {
      const p = assetPlatform(a.name || '');
      if (!p) continue;
      const n = Number(a.download_count) || 0;
      platforms[p] += n;
      total += n;
    }
    downloads += total;
    recent.push({ tag: r.tag_name, prerelease: !!r.prerelease, publishedAt: r.published_at || null, total, platforms });
  }
  recent.sort((a, b) => (b.publishedAt || '').localeCompare(a.publishedAt || ''));
  return { downloads, recent: recent.slice(0, PROJECT_LIMITS.recentReleases) };
}

class FetchError extends Error {}

async function getJson(env, url, init = {}) {
  const f = env.PROJECT_FETCH || fetch;
  let res;
  try {
    res = await f(url, { ...init, signal: AbortSignal.timeout(PROJECT_LIMITS.timeoutMs) });
  } catch (e) {
    throw new FetchError(`${new URL(url).host}: ${e && e.name === 'TimeoutError' ? 'timeout' : 'network error'}`);
  }
  if (!res.ok) throw new FetchError(`${new URL(url).pathname}: HTTP ${res.status}`);
  return res.json();
}

function githubHeaders(env) {
  const h = {
    Accept: 'application/vnd.github+json',
    'User-Agent': 'fushi-leaderboard',
    'X-GitHub-Api-Version': '2022-11-28',
  };
  if (env.GITHUB_TOKEN) h.Authorization = `Bearer ${env.GITHUB_TOKEN}`;
  return h;
}

async function fetchRepo(env, repo) {
  const headers = githubHeaders(env);
  const base = `https://api.github.com/repos/${repo}`;
  const info = await getJson(env, base, { headers });
  const releases = [];
  for (let page = 1; page <= PROJECT_LIMITS.releasePages; page += 1) {
    const batch = await getJson(env, `${base}/releases?per_page=100&page=${page}`, { headers });
    releases.push(...batch);
    if (batch.length < 100) break;
  }
  let traffic = null;
  if (env.GITHUB_TOKEN) {
    // traffic 需要 push 权限；只读 token 拿不到就算了，不影响其余数字。
    try {
      const [views, clones] = await Promise.all([
        getJson(env, `${base}/traffic/views`, { headers }),
        getJson(env, `${base}/traffic/clones`, { headers }),
      ]);
      traffic = { views, clones };
    } catch (e) {
      if (!(e instanceof FetchError)) throw e;
    }
  }
  return { info, releases: summarizeReleases(releases), traffic };
}

async function readMeta(env, key) {
  const row = await env.DB.prepare('SELECT value, at FROM project_meta WHERE key = ?1').bind(key).first();
  return row ? { ...JSON.parse(row.value), at: row.at } : null;
}

function metaStmt(env, key, value, now) {
  return env.DB.prepare('INSERT INTO project_meta (key, value, at) VALUES (?1, ?2, ?3)'
    + ' ON CONFLICT (key) DO UPDATE SET value = excluded.value, at = excluded.at')
    .bind(key, JSON.stringify(value), now);
}

/** 本次是否到期：上次尝试（成功或失败）之后过了 everyMs。失败也算一次尝试，免得每 30 分钟重打一个坏掉的上游。 */
function due(status, everyMs, now) {
  return !status || now - status.at >= everyMs;
}

async function refreshGithub(env, now, prev) {
  const day = utcDateKey(now);
  const stmts = [];
  const errors = [];
  for (const repo of githubRepos(env)) {
    let got;
    try {
      got = await fetchRepo(env, repo);
    } catch (e) {
      if (!(e instanceof FetchError)) throw e;
      errors.push(`${repo} ${e.message}`);
      continue;
    }
    const { info, releases, traffic } = got;
    stmts.push(env.DB.prepare(`INSERT INTO repo_daily (day, repo, stars, forks, watchers, open_issues, downloads, fetched_at)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
      ON CONFLICT (day, repo) DO UPDATE SET stars = excluded.stars, forks = excluded.forks, watchers = excluded.watchers,
        open_issues = excluded.open_issues, downloads = excluded.downloads, fetched_at = excluded.fetched_at`)
      .bind(day, repo, info.stargazers_count | 0, info.forks_count | 0, info.subscribers_count | 0,
        info.open_issues_count | 0, releases.downloads, now));
    stmts.push(metaStmt(env, `releases:${repo}`, { recent: releases.recent }, now));
    if (traffic) stmts.push(metaStmt(env, `traffic:${repo}`, traffic, now));
  }
  const ok = errors.length === 0 ? now : (prev?.okAt ?? null);
  stmts.push(metaStmt(env, 'status:github', { okAt: ok, error: errors.join('; ') || null }, now));
  await env.DB.batch(stmts);
}

const SITE_QUERY = `query($zone: String!, $since: Date!, $until: Date!) {
  viewer { zones(filter: {zoneTag: $zone}) {
    httpRequests1dGroups(limit: 100, filter: {date_geq: $since, date_leq: $until}, orderBy: [date_ASC]) {
      dimensions { date }
      sum { requests pageViews bytes countryMap { clientCountryName requests } }
      uniq { uniques }
    }
  } }
}`;

async function refreshSite(env, now, prev) {
  const until = utcDateKey(now);
  const first = !prev || prev.okAt == null;
  const since = utcDateKey(now - ((first ? PROJECT_LIMITS.siteFirstDays : PROJECT_LIMITS.siteBackfillDays) - 1) * DAY_MS);
  let groups;
  try {
    const body = await getJson(env, 'https://api.cloudflare.com/client/v4/graphql', {
      method: 'POST',
      headers: { Authorization: `Bearer ${env.CF_ANALYTICS_TOKEN}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ query: SITE_QUERY, variables: { zone: env.CF_ZONE_ID, since, until } }),
    });
    if (body.errors && body.errors.length) throw new FetchError(`graphql: ${String(body.errors[0].message).slice(0, 200)}`);
    groups = body.data?.viewer?.zones?.[0]?.httpRequests1dGroups;
    if (!Array.isArray(groups)) throw new FetchError('graphql: zone not found');
  } catch (e) {
    if (!(e instanceof FetchError)) throw e;
    await metaStmt(env, 'status:site', { okAt: prev?.okAt ?? null, error: e.message }, now).run();
    return;
  }
  const stmts = groups.map((g) => {
    const countries = {};
    for (const c of g.sum.countryMap || []) countries[c.clientCountryName] = c.requests | 0;
    return env.DB.prepare(`INSERT INTO site_daily (day, requests, page_views, visitors, bytes, countries, fetched_at)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
      ON CONFLICT (day) DO UPDATE SET requests = excluded.requests, page_views = excluded.page_views,
        visitors = excluded.visitors, bytes = excluded.bytes, countries = excluded.countries, fetched_at = excluded.fetched_at`)
      .bind(g.dimensions.date, g.sum.requests | 0, g.sum.pageViews | 0, g.uniq.uniques | 0,
        Number(g.sum.bytes) || 0, JSON.stringify(countries), now);
  });
  stmts.push(metaStmt(env, 'status:site', { okAt: now, error: null }, now));
  await env.DB.batch(stmts);
}

/** 是否配置了官网分析。 */
export function siteConfigured(env) {
  return !!(env.CF_ANALYTICS_TOKEN && env.CF_ZONE_ID);
}

/**
 * 取一遍外部数据（定时任务 / 处理台「立即刷新」）。force = 忽略节流间隔。
 * 外部失败只记进 status:*，不抛；D1 错误照常抛。
 */
export async function refreshProjectStats(env, now, { force = false } = {}) {
  const gh = await readMeta(env, 'status:github');
  if (force || due(gh, PROJECT_LIMITS.githubEveryMs, now)) await refreshGithub(env, now, gh);
  if (siteConfigured(env)) {
    const site = await readMeta(env, 'status:site');
    if (force || due(site, PROJECT_LIMITS.siteEveryMs, now)) await refreshSite(env, now, site);
  }
}

/** 第 n 天前（UTC 日）的同仓库行里最晚的一行：算「近 n 天新增」。 */
function deltaFrom(rows, today, days) {
  const cutoff = utcDateKey(Date.parse(`${today}T00:00:00Z`) - days * DAY_MS);
  const base = rows.filter((r) => r.day <= cutoff).at(-1);
  return base || null;
}

/** /dev/project 的数据。 */
export async function projectStats(env, now) {
  const today = utcDateKey(now);
  const since = utcDateKey(now - (PROJECT_LIMITS.trendDays + 31) * DAY_MS);
  const repos = [];
  for (const repo of githubRepos(env)) {
    const rows = (await env.DB.prepare(`SELECT day, stars, forks, watchers, open_issues, downloads, fetched_at
      FROM repo_daily WHERE repo = ?1 AND day >= ?2 ORDER BY day`).bind(repo, since).all()).results;
    const latest = rows.at(-1) || null;
    const delta = (days, k) => {
      const base = deltaFrom(rows, today, days);
      return latest && base ? latest[k] - base[k] : null;
    };
    const trendCut = utcDateKey(now - (PROJECT_LIMITS.trendDays - 1) * DAY_MS);
    const trend = [];
    for (let i = 0; i < rows.length; i += 1) {
      if (rows[i].day < trendCut) continue;
      const prev = i > 0 ? rows[i - 1] : null;
      trend.push({
        day: rows[i].day,
        stars: rows[i].stars,
        starsDelta: prev ? rows[i].stars - prev.stars : null,
        downloads: rows[i].downloads,
        downloadsDelta: prev && prev.downloads != null && rows[i].downloads != null ? rows[i].downloads - prev.downloads : null,
      });
    }
    repos.push({
      repo,
      latest,
      stars7: delta(7, 'stars'),
      stars30: delta(30, 'stars'),
      downloads7: delta(7, 'downloads'),
      trend: trend.reverse(),
      releases: (await readMeta(env, `releases:${repo}`))?.recent || [],
      traffic: await readMeta(env, `traffic:${repo}`),
    });
  }
  const siteRows = (await env.DB.prepare(`SELECT day, requests, page_views, visitors, bytes, countries
    FROM site_daily WHERE day >= ?1 ORDER BY day DESC`)
    .bind(utcDateKey(now - (PROJECT_LIMITS.trendDays - 1) * DAY_MS)).all()).results;
  const totals = { requests: 0, pageViews: 0, bytes: 0 };
  const countryTotals = {};
  for (const r of siteRows) {
    totals.requests += r.requests;
    totals.pageViews += r.page_views;
    totals.bytes += r.bytes;
    for (const [k, v] of Object.entries(JSON.parse(r.countries || '{}'))) countryTotals[k] = (countryTotals[k] || 0) + v;
  }
  const countries = Object.entries(countryTotals)
    .sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))
    .slice(0, PROJECT_LIMITS.topCountries)
    .map(([key, n]) => ({ key, n }));
  return {
    repos,
    githubStatus: await readMeta(env, 'status:github'),
    githubToken: !!env.GITHUB_TOKEN,
    site: {
      configured: siteConfigured(env),
      status: await readMeta(env, 'status:site'),
      days: siteRows.map((r) => ({ day: r.day, requests: r.requests, pageViews: r.page_views, visitors: r.visitors, bytes: r.bytes })),
      totals,
      yesterday: siteRows.find((r) => r.day === utcDateKey(now - DAY_MS)) || null,
      countries,
    },
  };
}
