// 开发者反馈处理台（网页，fushi.moe 上的 /dev）。
//
//   GET  /dev                     未登录 → 邮箱登录；已登录 → 反馈列表（?status=active|<状态>|all&cursor）
//   POST /dev/code   {email}      发登录验证码（与 App 新设备登录同一套 purpose=login 验证码）
//   POST /dev/login  {email,code} 验码 → 账户 role 必须是 dev → 写会话 Cookie
//   POST /dev/logout
//   GET  /dev/f/:id               详情：正文、设备信息、截图、日志、时间线、修复 commit 与各通道发布版本（只读）、处理表单
//   GET  /dev/f/:id/a/:slot       附件（日志 ?view=text 解压成文本；视频 v0 支持 Range，?download=1 下载）
//   POST /dev/f/:id  {status,reply}
//   GET  /dev/project             项目数据：GitHub star / fork / Release 下载与官网访问量的每日快照（project_stats.js）
//   POST /dev/project/refresh     立即重新取一遍外部数据（不等定时任务的节流间隔）
//   GET  /dev/stats               安装统计：日活 / 周活 / 月活、近 30 天每日活跃与新增、平台 / 通道 / 版本分布（installs.js）
//
// 安全：页面无脚本（CSP script-src 为 none）；会话 Cookie HttpOnly + Secure + SameSite=Strict，
// 只发往 /dev；所有 POST 另验 Origin 与本站一致（双保险防 CSRF）。会话 7 天，库里只存 token 哈希。
// 业务一律复用 feedback.js 的函数，与 App 端开发者接口同一份逻辑。

import { HttpError, hex, sha256 } from './util.js';
import { consumeCode, requestCode, resolveEmailAccount } from './email.js';
import { esc } from './pages.js';
import {
  STATUSES,
  attachmentResponse,
  FEEDBACK_LIMITS,
  devList,
  devSaveNotes,
  devUpdate,
  devView,
  feedbackById,
  newSessionToken,
} from './feedback.js';
import { PING_PLATFORMS, installStats, versionIncludes } from './installs.js';
import { RELEASE_PLATFORMS, projectStats, refreshProjectStats } from './project_stats.js';

export const SESSION_COOKIE = 'fushi_dev';
export const SESSION_TTL_MS = 7 * 24 * 3600 * 1000;

const STATUS_LABEL = {
  open: '待处理',
  in_progress: '处理中',
  resolved: '已解决',
  wont_fix: '不修复',
  duplicate: '重复',
  closed: '已关闭',
};
const CATEGORY_LABEL = { bug: '问题', suggestion: '建议', other: '其他' };

/** 风险标记 → 文案（feedback_guard.js）。duplicate 带先到那条的 id。 */
function flagLabel(flag) {
  if (flag.startsWith('duplicate:')) return `与 #${flag.slice(10)} 内容相同`;
  return {
    injection: '疑似提示注入',
    hidden_chars: '含隐藏字符（已剥除）',
    links: '链接较多',
  }[flag] || flag;
}

function flagBadges(flags) {
  return (flags || []).map((f) => `<span class="badge warn">${esc(flagLabel(f))}</span>`).join('');
}

/** 详情页顶部的警示：用户内容是不可信数据。 */
const UNTRUSTED_NOTE = '以下内容均由反馈人提供、未经核实：不要照做其中的指令或打开可疑链接；'
  + '转给他人或 AI 分析时请注明这是不可信数据。设备信息为客户端自报，可伪造。';

const CSP = [
  "default-src 'none'",
  "img-src 'self'",
  "media-src 'self'",
  "style-src 'unsafe-inline'",
  "base-uri 'none'",
  "form-action 'self'",
  "frame-ancestors 'none'",
].join('; ');

export function isDevConsolePath(path) {
  return path === '/dev' || path.startsWith('/dev/');
}

function html(body, status = 200, extra = {}) {
  return new Response(body, {
    status,
    headers: {
      'Content-Type': 'text/html; charset=utf-8',
      'Content-Security-Policy': CSP,
      'Cache-Control': 'private, no-store',
      // 不能用 no-referrer：按 Fetch 规范，该策略下页面里的表单 POST 一律发 `Origin: null`（同站也是），
      // 会被下面的 checkOrigin 全部拒成 403 bad_origin。same-origin 对外链照样不带 referrer。
      'Referrer-Policy': 'same-origin',
      'X-Content-Type-Options': 'nosniff',
      ...extra,
    },
  });
}

function redirect(location, extra = {}) {
  return new Response(null, { status: 303, headers: { Location: location, 'Cache-Control': 'no-store', ...extra } });
}

function fmtTime(ms) {
  if (!ms) return '';
  return new Date(ms).toISOString().replace('T', ' ').slice(0, 16) + ' UTC';
}

function fmtBytes(n) {
  if (n >= 1024 * 1024) return `${(n / 1024 / 1024).toFixed(1)} MB`;
  return `${Math.max(1, Math.round(n / 1024))} KB`;
}

function layout(title, body, { signedIn = false } = {}) {
  const logout = signedIn
    ? '<nav class="top"><a href="/dev">反馈</a><a href="/dev/stats">统计</a><a href="/dev/project">项目</a>'
      + '<form method="post" action="/dev/logout" class="inline"><button class="link">退出</button></form></nav>'
    : '';
  return `<!doctype html>
<html lang="zh">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light dark">
<meta name="robots" content="noindex">
<title>${esc(title)} · Fushi 反馈处理台</title>
<style>${STYLE}</style>
</head>
<body>
<header><a class="brand" href="/dev">Fushi 反馈处理台</a>${logout}</header>
<main>
${body}
</main>
</body>
</html>`;
}

const STYLE = `
:root{--bg:#f7f6f3;--fg:#1d1c1a;--muted:#6b6862;--card:#fff;--line:#e4e1db;--accent:#b4532a;--ok:#2f7d4f;--c2:#3b6fb0}
@media (prefers-color-scheme:dark){:root{--bg:#161514;--fg:#ecebe8;--muted:#a19d96;--card:#201f1d;--line:#34322f;--accent:#e58a5f;--ok:#6cc08f;--c2:#7eaee6}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.5 system-ui,-apple-system,"Segoe UI","Noto Sans CJK SC","PingFang SC",sans-serif}
a{color:inherit}
header,main{max-width:900px;margin:0 auto;padding:12px 16px}
header{display:flex;align-items:center;justify-content:space-between;border-bottom:1px solid var(--line)}
.brand{font-weight:700;font-size:17px;text-decoration:none}
h1{font-size:20px;margin:8px 0;word-break:break-word}
h2{font-size:15px;margin:20px 0 8px}
.muted{color:var(--muted)}
.card{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:14px;margin:12px 0}
.tabs{display:flex;flex-wrap:wrap;gap:6px;margin:12px 0}
.tabs a{padding:4px 10px;border:1px solid var(--line);border-radius:999px;text-decoration:none;font-size:14px}
.tabs a.on{background:var(--accent);border-color:var(--accent);color:#fff}
.search{display:flex;gap:6px;align-items:center;margin:0 0 12px}
.search input[type=search]{flex:1;min-width:0;padding:6px 10px;border:1px solid var(--line);border-radius:8px;font:inherit;background:transparent;color:inherit}
.row{display:flex;flex-wrap:wrap;gap:4px 10px;align-items:baseline;padding:10px 0;border-bottom:1px solid var(--line);text-decoration:none}
.row .sum{flex-basis:100%;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-size:13px}
.row:last-child{border-bottom:0}
.row .t{flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.badge{font-size:12px;padding:1px 8px;border-radius:999px;border:1px solid var(--line);white-space:nowrap}
.badge.s-open,.badge.new{border-color:var(--accent);color:var(--accent)}
.badge.s-resolved{border-color:var(--ok);color:var(--ok)}
.badge.warn{border-color:#c98a00;color:#c98a00}
.badge.ok{border-color:var(--ok);color:var(--ok)}
.badge.insider{background:#d0216e;border-color:#d0216e;color:#fff;font-weight:700}
.row.insider{background:rgba(208,33,110,.08);border-left:4px solid #d0216e;padding-left:8px}
.card.ai{border-left:3px solid var(--ok)}
.note{border-left:3px solid #c98a00;padding:6px 10px;margin:12px 0;font-size:14px}
pre,.body{white-space:pre-wrap;word-break:break-word;margin:0}
table{border-collapse:collapse;width:100%;font-size:13px}
td{border-top:1px solid var(--line);padding:4px 6px;vertical-align:top;word-break:break-all}
td:first-child{color:var(--muted);width:30%}
.shots{display:flex;flex-wrap:wrap;gap:8px}
.shots img{max-width:260px;max-height:420px;border:1px solid var(--line);border-radius:8px}
video{display:block;width:100%;max-height:520px;border-radius:8px;background:#000}
.msg{border-left:3px solid var(--line);padding:4px 10px;margin:8px 0}
.msg.dev{border-color:var(--accent)}
label{display:block;margin:8px 0 4px;font-size:14px}
input,select,textarea{width:100%;font:inherit;padding:8px;border:1px solid var(--line);border-radius:8px;background:var(--card);color:var(--fg)}
textarea{min-height:110px}
button{font:inherit;margin-top:10px;padding:8px 16px;border:0;border-radius:8px;background:var(--accent);color:#fff;cursor:pointer}
button.link{background:none;color:var(--muted);padding:0;margin:0;text-decoration:underline}
.inline{display:inline}
nav.top{display:flex;gap:14px;align-items:baseline}
.kpis{display:grid;grid-template-columns:repeat(auto-fit,minmax(120px,1fr));gap:8px}
.kpi{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:10px 14px}
.kpi b{display:block;font-size:24px;font-variant-numeric:tabular-nums}
.grid td{text-align:right;font-variant-numeric:tabular-nums}
.grid td:first-child{text-align:left}
.grid th{text-align:right;font-weight:600;color:var(--muted);padding:4px 6px}
.grid th:first-child{text-align:left}
.bar{display:inline-block;height:8px;border-radius:4px;background:var(--accent);vertical-align:middle;margin-right:6px}
.err{color:var(--accent)}
.up{color:var(--ok)}
.title{display:flex;align-items:center;justify-content:space-between;gap:12px}
button.small{margin:0;padding:4px 12px;font-size:14px}
details.card summary{cursor:pointer;color:var(--muted);font-size:14px}
details.card[open] summary{margin-bottom:8px}
.foot{font-size:12px;margin-top:24px}
h2 .more{font-weight:400;font-size:13px;color:var(--muted);margin-left:8px}
.scroll{overflow-x:auto}
.scroll td,.scroll th{white-space:nowrap;word-break:normal}
.scroll td:first-child{width:auto}
.chart{margin:4px 0 18px}
.chart:last-child{margin-bottom:4px}
.chart figcaption{display:flex;flex-wrap:wrap;align-items:baseline;gap:2px 14px;font-size:13px;color:var(--muted)}
.chart figcaption>b{color:var(--fg);font-size:14px;margin-right:auto}
.chart figcaption span b{color:var(--fg);font-variant-numeric:tabular-nums}
.chart i{display:inline-block;width:12px;height:3px;border-radius:2px;vertical-align:middle;margin-right:5px}
.plot{display:grid;grid-template-columns:auto 1fr;column-gap:8px;margin-top:8px}
.yax{display:flex;flex-direction:column;justify-content:space-between;height:150px;font-size:11px;line-height:1;color:var(--muted);text-align:right;font-variant-numeric:tabular-nums}
.xax{display:flex;justify-content:space-between;font-size:11px;color:var(--muted);margin-top:4px}
svg.line{display:block;width:100%;height:150px;overflow:visible}
svg.line polyline{fill:none;stroke-width:2;stroke-linejoin:round;vector-effect:non-scaling-stroke}
svg.line line.g{stroke:var(--line);stroke-width:1;vector-effect:non-scaling-stroke}
svg.line rect.hit{fill:transparent}
svg.line rect.hit:hover{fill:var(--line);opacity:.6}
.l0{stroke:var(--accent);background:var(--accent)}
.l1{stroke:var(--c2);background:var(--c2)}
`;

function readCookie(request, name) {
  const raw = request.headers.get('Cookie') || '';
  for (const part of raw.split(';')) {
    const i = part.indexOf('=');
    if (i > 0 && part.slice(0, i).trim() === name) return part.slice(i + 1).trim();
  }
  return null;
}

async function tokenHash(token) {
  return hex(await sha256(new TextEncoder().encode(token)));
}

/** 当前会话的开发者账户；没有 / 过期 / 已不是开发者 → null。 */
export async function sessionAccount(env, request, now) {
  const token = readCookie(request, SESSION_COOKIE);
  if (!token || !/^[A-Za-z0-9_-]{20,64}$/.test(token)) return null;
  const row = await env.DB.prepare(
    `SELECT a.* FROM dev_sessions s JOIN accounts a ON a.id = s.account_id
     WHERE s.token_hash = ?1 AND s.expires_at > ?2`,
  ).bind(await tokenHash(token), now).first();
  return row && row.role === 'dev' ? row : null;
}

function sessionCookie(token, maxAgeSec) {
  return `${SESSION_COOKIE}=${token}; Path=/dev; HttpOnly; Secure; SameSite=Strict; Max-Age=${maxAgeSec}`;
}

/** 所有 POST：Origin 必须是本站（浏览器提交表单都会带）。 */
// CSRF 防线：同站表单 POST 必须带本站 Origin。依赖 html() 的 Referrer-Policy 不是 no-referrer（见那里）。
function checkOrigin(request, url) {
  const origin = request.headers.get('Origin');
  if (!origin || origin !== url.origin) throw new HttpError(403, 'bad_origin');
}

/**
 * 表单体上限按字段字数算：urlencoded 下一个汉字是 9 字节（%XX×3）、emoji 等 4 字节字符是 12 字节，
 * 按最坏的 12 算。按 32 KB 一刀切时
 * 4000 字上限的回复框写到 ~3600 个汉字就 413。`chars` = 本表单最长文本字段的字数上限。
 */
function formLimit(chars) {
  return chars * 12 + 1024;
}

async function readForm(request, maxBytes = 32 * 1024) {
  const declared = Number(request.headers.get('Content-Length') || '0');
  if (declared > maxBytes) throw new HttpError(413, 'body_too_large');
  const text = await request.text();
  if (text.length > maxBytes) throw new HttpError(413, 'body_too_large');
  return new URLSearchParams(text);
}

function loginPage({ email = '', step = 'email', error = '' } = {}) {
  const err = error ? `<p class="err">${esc(error)}</p>` : '';
  const form = step === 'email'
    ? `<form method="post" action="/dev/code">
<label for="email">开发者账户邮箱</label>
<input id="email" name="email" type="email" autocomplete="email" required value="${esc(email)}">
<button>发送验证码</button>
</form>`
    : `<form method="post" action="/dev/login">
<input type="hidden" name="email" value="${esc(email)}">
<p class="muted">如果该邮箱是已注册的 Fushi 账户，验证码已发出（10 分钟内有效）。</p>
<label for="code">验证码</label>
<input id="code" name="code" inputmode="numeric" pattern="\\d{6}" autocomplete="one-time-code" required>
<button>登录</button>
</form>`;
  return html(layout('登录', `<h1>登录</h1>
<div class="card">
${err}
${form}
<p class="muted">只有被管理员设为开发者的 Fushi 账户能进入处理台。</p>
</div>`));
}

const TABS = [['active', '未结案'], ...STATUSES.map((s) => [s, STATUS_LABEL[s]]), ['flagged', '可疑'], ['all', '全部']];

/**
 * 开发者账户提的反馈：醒目徽标（自己提的写「我提的」，其他开发者写昵称）。外部用户提的返回空串。
 * @param {{id: string, nickname: string} | null} reporter
 * @param {{id: string}} viewer 当前登录的开发者
 * @returns {string}
 */
export function devReporterBadge(reporter, viewer) {
  if (!reporter) return '';
  const label = reporter.id === viewer.id ? '★ 我提的' : `★ 开发者 ${reporter.nickname}`;
  return `<span class="badge insider">${esc(label)}</span>`;
}

async function listPage(env, url, dev) {
  const status = url.searchParams.get('status') || 'active';
  const q = (url.searchParams.get('q') || '').trim();
  const res = await devList(env, {
    status: status === 'all' ? null : status,
    cursor: url.searchParams.get('cursor'),
    limit: 50,
    q,
  });
  const qs = q ? `&amp;q=${encodeURIComponent(q)}` : '';
  const tabs = TABS.map(([k, label]) => `<a href="/dev?status=${k}${qs}"${k === status ? ' class="on"' : ''}>${esc(label)}</a>`).join('');
  const searchForm = `<form method="get" action="/dev" class="search">
<input type="hidden" name="status" value="${esc(status)}">
<input type="search" name="q" value="${esc(q)}" maxlength="100" placeholder="编号 / 标题 / 正文">
<button>搜索</button>${q ? ` <a href="/dev?status=${esc(status)}">清除</a>` : ''}
</form>`;
  const rows = res.items.map((f) => `<a class="row${f.devReporter ? ' insider' : ''}" href="/dev/f/${esc(f.id)}">
${devReporterBadge(f.devReporter, dev)}
<span class="badge s-${esc(f.status)}">${esc(STATUS_LABEL[f.status] || f.status)}</span>
<span class="badge">${esc(CATEGORY_LABEL[f.category] || f.category)}</span>
<span class="muted">#${esc(f.id)}</span>
${f.parentId ? `<span class="badge">重新提交自 #${esc(f.parentId)}</span>` : ''}
<span class="t">${esc(f.title)}</span>
${f.awaitingDev ? '<span class="badge new">新消息</span>' : ''}
${f.hasDevNote ? '<span class="badge ok">已批改</span>' : ''}
${f.fix ? `<span class="badge ok">修复 ${esc(f.fix.sha.slice(0, 7))}</span>` : ''}
${flagBadges(f.flags)}
<span class="muted">${esc(fmtTime(f.updatedAt))}</span>
${f.aiSummary ? `<span class="sum muted">AI：${esc(f.aiSummary)}</span>` : ''}
</a>`).join('');
  const more = res.next
    ? `<p><a href="/dev?status=${esc(status)}${qs}&amp;cursor=${encodeURIComponent(res.next)}">下一页</a></p>`
    : '';
  return html(layout('反馈', `<h1>反馈</h1>
<p class="muted">${esc(dev.nickname)}，你好。</p>
<nav class="tabs">${tabs}</nav>
${searchForm}
<div class="card">${rows || `<p class="muted">${q ? '没有匹配的反馈。' : '没有反馈。'}</p>`}</div>
${more}`, { signedIn: true }));
}

const CHANNEL_LABEL = { debug: '调试版', beta: '测试版', stable: '正式版' };

/** Intl.DisplayNames 的中文名；运行时不支持或码不认识 → null（调用方退回原码）。 */
function displayName(type, code) {
  try {
    const name = new Intl.DisplayNames(['zh-CN'], { type, fallback: 'none' }).of(code);
    return name && name !== code ? name : null;
  } catch {
    return null;
  }
}

/** 两位国家 / 地区码 → 「中文名（码）」；T1 / XX 是 Cloudflare 的特殊值；null = 0017 之前或没有 cf。 */
export function countryLabel(code) {
  if (code === null || code === undefined) return '未记录';
  if (code === 'T1') return 'Tor 出口（T1）';
  if (code === 'XX') return '无法判断（XX）';
  const name = displayName('region', code);
  return name ? `${name}（${code}）` : code;
}

/** 界面语言标签 → 「中文名（标签）」；null = 旧客户端没上报。 */
export function localeLabel(tag) {
  if (tag === null || tag === undefined) return '未上报（旧客户端）';
  const name = displayName('language', tag);
  return name ? `${name}（${tag}）` : tag;
}

const PLATFORM_LABEL = { android: 'Android', windows: 'Windows', macos: 'macOS', linux: 'Linux' };
const NOT_REPORTED = '未上报';

/** Android API 级别 → 系统版本号（只列 minSdk 24 起）。 */
const ANDROID_API_RELEASE = {
  24: '7.0', 25: '7.1', 26: '8.0', 27: '8.1', 28: '9', 29: '10', 30: '11', 31: '12', 32: '12L',
  33: '13', 34: '14', 35: '15', 36: '16',
};

/** 心跳 osVersion（按平台的大版本记号）→ 可读名。 */
export function osVersionLabel(platform, v) {
  if (v === null || v === undefined) return `${PLATFORM_LABEL[platform] || platform} · ${NOT_REPORTED}`;
  if (platform === 'android') {
    const release = ANDROID_API_RELEASE[v];
    return release ? `Android ${release}（API ${v}）` : `Android API ${v}`;
  }
  return `${PLATFORM_LABEL[platform] || platform} ${v}`;
}

const SOURCE_LABEL = {
  play: 'Google Play',
  fdroid: 'F-Droid 系客户端',
  obtainium: 'Obtainium',
  self_update: 'App 内更新',
  manual: '手动安装 APK（文件管理器 / 浏览器）',
  adb: 'adb / 开发安装',
  installer: '安装包',
  portable: '便携 / 解压版',
  direct: '直接下载',
  source: '源码构建',
};

/** 安装来源类别 → 「平台 · 中文说明」。 */
export function sourceLabel(platform, v) {
  const p = PLATFORM_LABEL[platform] || platform;
  if (v === null || v === undefined) return `${p} · ${NOT_REPORTED}`;
  return `${p} · ${SOURCE_LABEL[v] || v}`;
}

/** 架构 → 「平台 · 架构」。 */
export function archLabel(platform, v) {
  return `${PLATFORM_LABEL[platform] || platform} · ${v ?? NOT_REPORTED}`;
}

/** 按平台分组的分布行 → distTable 的 {key, n}（key 已是展示文案）。 */
function byPlatform(rows, label) {
  return rows.map((r) => ({ key: label(r.platform, r.value), n: r.n }));
}

const pctText = (n, d) => (d ? `${((n * 100) / d).toFixed(1)}%` : '—');

/** 留存表：新增日 × 次日 / 第 7–13 天 / 第 30–59 天。 */
function retentionTable(rows) {
  if (!rows.length) return '<p class="muted">还没有数据。</p>';
  const cell = (r, k) => (r[k] === null ? '<td class="muted">—</td>' : `<td>${pctText(r[k], r.n)} <span class="muted">${r[k]}</span></td>`);
  const mature = (k) => rows.filter((r) => r[k] !== null && !r.seeded);
  const avg = (k) => {
    const m = mature(k);
    const n = m.reduce((a, r) => a + r.n, 0);
    return n ? `<td><b>${pctText(m.reduce((a, r) => a + r[k], 0), n)}</b></td>` : '<td class="muted">—</td>';
  };
  return `<table class="grid"><tr><th>新增日（UTC）</th><th>新增</th><th>次日</th><th>第 7–13 天</th><th>第 30–59 天</th></tr>
<tr><td>合计（已完整的窗口，不含起始日）</td><td></td>${avg('d1')}${avg('d7')}${avg('d30')}</tr>
${rows.map((r) => `<tr><td>${esc(r.day)}${r.seeded ? ' <span class="muted">起始日，含存量安装</span>' : ''}</td><td>${r.n}</td>`
    + `${cell(r, 'd1')}${cell(r, 'd7')}${cell(r, 'd30')}</tr>`).join('')}</table>`;
}

const TRACK_LABEL = { '': '正式', beta: '测试', debug: '调试' };

/** 版本升级进度：该版本在同轨道 7 日活跃里的覆盖率。 */
function adoptionTable(rows) {
  if (!rows.length) return '<p class="muted">还没有数据。</p>';
  return `<table class="grid"><tr><th>版本</th><th>轨道</th><th>首次出现</th><th>已装到该版本或更新</th><th>正好在该版本</th></tr>
${rows.map((r) => `<tr><td>${esc(r.version)}</td><td>${esc(r.track === null ? '?' : TRACK_LABEL[r.track] ?? r.track)}</td>`
    + `<td>${esc(r.firstDay)}</td><td>${pctText(r.reached, r.peers)} <span class="muted">${r.reached}/${r.peers}</span></td>`
    + `<td>${pctText(r.exact, r.peers)} <span class="muted">${r.exact}</span></td></tr>`).join('')}</table>`;
}

/** 分国家日活趋势：日期 × 前几个国家 + 其它。 */
function countryTrendTable(trend) {
  if (!trend.days.length) return '<p class="muted">还没有数据。</p>';
  const head = trend.countries.map((c) => `<th>${esc(c === null ? '未记录' : c)}</th>`).join('');
  return `<table class="grid"><tr><th>日期（UTC）</th>${head}<th>其它</th></tr>
${trend.days.map((d) => `<tr><td>${esc(d.day)}</td>${d.counts.map((n) => `<td>${n}</td>`).join('')}<td class="muted">${d.other}</td></tr>`).join('')}</table>`;
}

/** 修复追踪（只读）：修复 commit + 各通道 / 平台最早包含它的版本。未标记修复 → 空串。 */
function fixSection(fix) {
  if (!fix) return '';
  const scope = fix.scope === 'none' ? '无需更新 App' : '需要新 App';
  const rows = Object.entries(fix.releases || {}).flatMap(([ch, per]) => Object.entries(per)
    .map(([pf, r]) => `<tr><td>${esc(CHANNEL_LABEL[ch] || ch)} · ${esc(pf)}</td><td>${esc(r.version)} <span class="muted">${esc(fmtTime(r.at))}</span></td></tr>`))
    .join('');
  const releases = rows
    ? `<table>${rows}</table>`
    : `<p class="muted">${fix.scope === 'none' ? '不需要发布。' : '还没有发布包含这个修复。'}</p>`;
  return `<h2>修复</h2>
<div class="card"><p>commit <code>${esc(fix.sha)}</code> · ${esc(scope)} · ${esc(fmtTime(fix.at))}</p>${releases}</div>`;
}

/** 一组「键 → 安装数」的分布表，带按占比的小条。 */
function distTable(rows, label = (k) => k) {
  const total = rows.reduce((a, r) => a + r.n, 0);
  if (!total) return '<p class="muted">还没有数据。</p>';
  return `<table class="grid">${rows.map((r) => {
    const pct = (r.n * 100) / total;
    return `<tr><td>${esc(label(r.key))}</td><td><span class="bar" style="width:${Math.max(2, Math.round(pct))}px"></span>${r.n}`
      + ` <span class="muted">${pct.toFixed(1)}%</span></td></tr>`;
  }).join('')}</table>`;
}

async function statsPage(env, now) {
  const st = await installStats(env, now);
  const kpi = (label, n) => `<div class="kpi"><span class="muted">${esc(label)}</span><b>${n}</b></div>`;
  const head = `<tr><th>日期（UTC）</th><th>活跃</th><th>新增</th>${PING_PLATFORMS.map((p) => `<th>${esc(p)}</th>`).join('')}`
    + '<th class="muted">未验证</th></tr>';
  const daily = st.daily.map((d) => `<tr><td>${esc(d.day)}</td><td>${d.n}</td><td>${d.fresh}</td>`
    + `${PING_PLATFORMS.map((p) => `<td>${d.platforms[p]}</td>`).join('')}<td class="muted">${d.unverified}</td></tr>`).join('');
  const u = st.unverified;
  return html(layout('统计', `<h1>安装统计</h1>
<p class="muted">来自 App 每天一次的匿名心跳（Android / Windows / macOS / Linux；iOS 看 App Store Connect）。
按安装 id 去重，关了统计的安装不计；日期按 UTC。分布取近 30 天活跃安装各自最近一次上报的值。
数字只算<b>已验证</b>安装（出示了安装证明：签名 + 工作量证明）；未验证的（旧版客户端或自报伪造）另列。</p>
<div class="kpis">${kpi('今日活跃', st.dau)}${kpi('7 日活跃', st.wau)}${kpi('30 日活跃', st.mau)}${kpi('累计安装（保留期内）', st.total)}</div>
<p class="muted">未验证：今日 ${u.dau} · 7 日 ${u.wau} · 30 日 ${u.mau} · 累计 ${u.total}</p>
<h2>近 30 天</h2>
<div class="card">${daily ? `<table class="grid">${head}${daily}</table>` : '<p class="muted">还没有心跳。</p>'}</div>
<h2>平台</h2><div class="card">${distTable(st.platforms)}</div>
<h2>通道</h2><div class="card">${distTable(st.channels, (k) => CHANNEL_LABEL[k] || k)}</div>
<h2>版本（前 20）</h2><div class="card">${distTable(st.versions)}</div>
<h2>国家 / 地区</h2>
<p class="muted">Cloudflare 按心跳连接 IP 判出的国家 / 地区（只存两位码，不存 IP）；走代理 / VPN 的安装记到出口所在地。</p>
<div class="card">${distTable(st.countries, countryLabel)}</div>
<h2>界面语言</h2><div class="card">${distTable(st.locales, localeLabel)}</div>
<h2>分国家日活趋势</h2><div class="card">${countryTrendTable(st.countryTrend)}</div>
<h2>留存</h2>
<p class="muted">按首次心跳日分组：之后那段时间里任何一天有心跳即算留存。窗口还没走完的格子显示「—」。
心跳只在 App 打开时发，留存反映的是「还在打开」，不是「还装着」。</p>
<div class="card">${retentionTable(st.retention)}</div>
<h2>版本升级进度</h2>
<p class="muted">分母是同一发布轨道（正式 / 测试 / 调试）近 7 日活跃的已验证安装；「已装到该版本或更新」按与修复追踪相同的版本判据。</p>
<div class="card">${adoptionTable(st.adoption)}</div>
<h2>CPU 架构</h2><div class="card">${distTable(byPlatform(st.archs, archLabel))}</div>
<h2>系统版本</h2><div class="card">${distTable(byPlatform(st.osVersions, osVersionLabel))}</div>
<h2>安装来源</h2><div class="card">${distTable(byPlatform(st.sources, sourceLabel))}</div>`, { signedIn: true }));
}

const fmtInt = (n) => (n === null || n === undefined ? '—' : Number(n).toLocaleString('en-US'));

/** 带符号的增量；null → —。 */
function fmtDelta(n) {
  if (n === null || n === undefined) return '<span class="muted">—</span>';
  return n > 0 ? `<span class="up">+${fmtInt(n)}</span>` : fmtInt(n);
}

function fmtVolume(n) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  let v = n;
  let i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i += 1;
  }
  return `${v.toFixed(i >= 3 ? 1 : 0)} ${units[i]}`;
}

/** 外部数据源只在出错时占一行；正常时什么都不显示。 */
function sourceError(name, status) {
  if (!status?.error) return '';
  return `<p class="err">${esc(name)} 最近一次取数失败（${esc(fmtTime(status.at))}）：${esc(status.error)}</p>`;
}

/**
 * 按天的折线图（内联 SVG，无脚本）。days 升序；series = [{label, values}]，values 与 days 对齐，null = 缺数据（断线）。
 * zero = y 轴从 0 起（每日计数）；否则从最小值起（累计量）。悬停某天显示当天各线数值。
 */
export function lineChart(title, days, series, { zero = true, empty = '数据还不够画图（至少要两天）。' } = {}) {
  const all = series.flatMap((s) => s.values).filter((v) => v !== null && v !== undefined);
  const latest = series.map((s, k) => {
    const v = fmtInt([...s.values].reverse().find((x) => x !== null && x !== undefined) ?? null);
    // 只有一条线时标题就是图例，只留最新值。
    return series.length === 1 ? `<span><b>${v}</b></span>` : `<span><i class="l${k}"></i>${esc(s.label)} <b>${v}</b></span>`;
  }).join('');
  const head = `<figcaption><b>${esc(title)}</b>${latest}</figcaption>`;
  if (days.length < 2 || !all.length) return `<figure class="chart">${head}<p class="muted">${esc(empty)}</p></figure>`;
  // 两格刻度，格宽取 {1, 1.5, 2, 2.5, 3, 4, 5, 6, 8} × 10ⁿ 里够用的最小整数，轴上标整数、顶部不留大片空白。
  const rawLo = zero ? Math.min(0, ...all) : Math.min(...all);
  const want = Math.max(1, (Math.max(...all) - rawLo) / 2);
  const mag = 10 ** Math.floor(Math.log10(want));
  const tick = [1, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10].map((m) => m * mag).find((t) => t >= want && Number.isInteger(t));
  const lo = Math.floor(rawLo / tick) * tick;
  const hi = Math.max(lo + 2 * tick, Math.ceil(Math.max(...all) / tick) * tick);
  const x = (i) => ((i * 100) / (days.length - 1)).toFixed(2);
  const y = (v) => (98 - ((v - lo) * 96) / (hi - lo)).toFixed(2);
  const lines = series.map((s, k) => {
    // 遇到 null 断开成几段，不把缺数据画成 0。
    const segs = [[]];
    s.values.forEach((v, i) => {
      if (v === null || v === undefined) segs.push([]);
      else segs.at(-1).push(`${x(i)},${y(v)}`);
    });
    return segs.filter((p) => p.length > 1).map((p) => `<polyline class="l${k}" points="${p.join(' ')}"/>`).join('');
  }).join('');
  const step = 100 / (days.length - 1);
  const hits = days.map((d, i) => `<rect class="hit" x="${(i * step - step / 2).toFixed(2)}" y="0" width="${step.toFixed(2)}" height="100">`
    + `<title>${esc(d)}${series.map((s) => ` · ${esc(s.label)} ${fmtInt(s.values[i] ?? null)}`).join('')}</title></rect>`).join('');
  const grid = [2, 50, 98].map((g) => `<line class="g" x1="0" x2="100" y1="${g}" y2="${g}"/>`).join('');
  return `<figure class="chart">${head}
<div class="plot"><div class="yax"><span>${fmtInt(hi)}</span><span>${fmtInt(Math.round((hi + lo) / 2))}</span><span>${fmtInt(lo)}</span></div>
<svg class="line" viewBox="0 0 100 100" preserveAspectRatio="none" role="img" aria-label="${esc(title)}">${grid}${lines}${hits}</svg>
<span></span><div class="xax"><span>${esc(days[0].slice(5))}</span><span>${esc(days.at(-1).slice(5))}</span></div></div></figure>`;
}

const RELEASE_PLATFORM_LABEL = {
  android: 'Android', windows: 'Windows', macos: 'macOS', ios: 'iOS', linux: 'Linux', other: '其它',
};

function repoSection(r, today) {
  const l = r.latest;
  if (!l) return `<h2>${esc(r.repo)}</h2><div class="card"><p class="muted">还没有数据。</p></div>`;
  const kpi = (label, n, extra = '') => `<div class="kpi"><span class="muted">${esc(label)}</span><b>${fmtInt(n)}</b>${extra}</div>`;
  const kpis = `<div class="kpis">${kpi('Star', l.stars, `<span class="muted">7 天 ${fmtDelta(r.stars7)}</span>`)}`
    + `${kpi('App 下载（累计）', l.downloads, `<span class="muted">7 天 ${fmtDelta(r.downloads7)}</span>`)}`
    + `${kpi('Fork', l.forks)}${kpi('开放 Issue + PR', l.open_issues)}</div>`;
  const trend = [...r.trend].reverse();
  // 当天的快照还会再涨，每日下载只画到昨天，免得末尾凭空掉一截。
  const done = trend.filter((d) => d.day < today);
  // GitHub 只给累计下载数，每日下载只能从每天的快照相减，历史补不回来。
  const since = trend.length ? `从 ${trend[0].day.slice(5)} 开始每天记录，攒满两天后出图。` : undefined;
  const charts = `${lineChart('Star', r.starTrend.map((d) => d.day), [{ label: 'Star', values: r.starTrend.map((d) => d.stars) }], { zero: false })}`
    + `${lineChart('每日下载', done.map((d) => d.day), [{ label: '下载', values: done.map((d) => d.downloadsDelta) }], { empty: since })}`;
  const used = RELEASE_PLATFORMS.filter((p) => r.releases.some((x) => x.platforms[p] > 0));
  const releases = r.releases.length
    ? `<div class="scroll"><table class="grid"><tr><th>版本</th><th>发布（UTC）</th><th>合计</th>${used.map((p) => `<th>${esc(RELEASE_PLATFORM_LABEL[p])}</th>`).join('')}</tr>
${r.releases.map((x) => `<tr><td>${esc(x.tag)}${x.prerelease ? ' <span class="muted">预发布</span>' : ''}</td>`
    + `<td>${esc((x.publishedAt || '').slice(0, 10))}</td><td>${fmtInt(x.total)}</td>`
    + `${used.map((p) => `<td>${fmtInt(x.platforms[p])}</td>`).join('')}</tr>`).join('')}</table></div>`
    : '<p class="muted">没有 App Release。</p>';
  let traffic = '';
  if (r.traffic) {
    const clones = new Map((r.traffic.clones?.clones || []).map((c) => [c.timestamp.slice(0, 10), c.count]));
    const views = r.traffic.views?.views || [];
    const days = views.map((v) => v.timestamp.slice(0, 10));
    traffic = lineChart('GitHub 访问（近 14 天）', days, [
      { label: '浏览', values: views.map((v) => v.count) },
      { label: 'clone', values: days.map((d) => clones.get(d) ?? 0) },
    ]);
  }
  return `<h2><a href="https://github.com/${esc(r.repo)}">${esc(r.repo)}</a></h2>
${kpis}
<div class="card">${charts}${traffic}</div>
<details class="card"><summary>近期 App Release 下载</summary>${releases}</details>`;
}

async function projectPage(env, now) {
  const st = await projectStats(env, now);
  const today = new Date(now).toISOString().slice(0, 10);
  const kpi = (label, v) => `<div class="kpi"><span class="muted">${esc(label)}</span><b>${v}</b></div>`;
  // App 用户：与 /dev/stats 同口径（只数已验证安装），这里只放总数和每日走势。
  const users = await installStats(env, now);
  const ud = [...users.daily].reverse().filter((d) => d.day < today);
  const usersSection = `<h2>App 用户 <a class="more" href="/dev/stats">详细统计 →</a></h2>
<div class="kpis">${kpi('今日活跃', fmtInt(users.dau))}${kpi('7 日活跃', fmtInt(users.wau))}`
    + `${kpi('30 日活跃', fmtInt(users.mau))}${kpi('累计安装', fmtInt(users.total))}</div>
<div class="card">${lineChart('每日活跃 / 新增', ud.map((d) => d.day), [
      { label: '活跃', values: ud.map((d) => d.n) },
      { label: '新增', values: ud.map((d) => d.fresh) },
    ])}</div>`;
  const s = st.site;
  let site = '<p class="muted">官网访问量未配置（CF_ANALYTICS_TOKEN / CF_ZONE_ID）。</p>';
  if (s.configured) {
    const days = [...s.days].reverse().filter((d) => d.day < today);
    site = `${sourceError('官网', s.status)}
<div class="kpis">${kpi('昨日浏览', fmtInt(s.yesterday?.page_views ?? null))}${kpi('昨日访客', fmtInt(s.yesterday?.visitors ?? null))}`
      + `${kpi('近 30 天浏览', fmtInt(s.totals.pageViews))}${kpi('近 30 天流量', esc(fmtVolume(s.totals.bytes)))}</div>
<div class="card">${lineChart('官网每日访问', days.map((d) => d.day), [
        { label: '浏览', values: days.map((d) => d.pageViews) },
        { label: '访客', values: days.map((d) => d.visitors) },
      ])}</div>
${s.countries.length ? `<details class="card"><summary>请求来源国家 / 地区（近 30 天）</summary>${distTable(s.countries, countryLabel)}</details>` : ''}`;
  }
  return html(layout('项目', `<div class="title"><h1>项目数据</h1>
<form method="post" action="/dev/project/refresh" class="inline"><button class="small">刷新</button></form></div>
${usersSection}
${sourceError('GitHub', st.githubStatus)}
${st.repos.map((r) => repoSection(r, today)).join('')}
<h2>官网 fushi.moe</h2>
${site}
<p class="muted foot">日期按 UTC，当天未完结的不画进每日图。下载只算 App Release 安装包；官网数字含同 zone 的 rank.fushi.moe。</p>`, { signedIn: true }));
}

/** 修复是否已装到报告人那台（按该安装最近一次心跳的通道 / 平台 / 版本）。没有可比的发布 → 空串。 */
function fixOnInstall(fix, install) {
  if (!fix || fix.scope === 'none' || !install) return '';
  const release = (fix.releases[install.channel] || {})[install.platform];
  if (!release) return `<p class="muted">报告人在${esc(CHANNEL_LABEL[install.channel] || install.channel)} · ${esc(install.platform)}，该通道还没有包含修复的发布。</p>`;
  const has = versionIncludes(install.version, release.version);
  const verdict = has === true ? '<span class="badge ok">已装上修复</span>'
    : has === false ? '<span class="badge warn">还没升级到修复版本</span>'
      : '<span class="badge">无法判断</span>';
  return `<p>${verdict} 报告人当前 ${esc(install.version)}，修复版本 ${esc(release.version)}</p>`;
}

/** 反馈详情的「安装」一节：最近心跳、版本轨迹、同一安装的其它反馈。反馈没带 installId → 空串。 */
function installSection(trail, fix) {
  if (!trail) return '';
  const i = trail.install;
  const summary = i
    ? `<table>
<tr><td>当前版本</td><td>${esc(i.version)}</td></tr>
<tr><td>平台 / 通道</td><td>${esc(i.platform)} · ${esc(CHANNEL_LABEL[i.channel] || i.channel)}</td></tr>
<tr><td>地区 / 界面语言</td><td>${esc(countryLabel(i.country))} · ${esc(localeLabel(i.locale))}</td></tr>
<tr><td>系统 / 架构 / 来源</td><td>${esc(osVersionLabel(i.platform, i.osVersion))} · ${esc(i.arch ?? NOT_REPORTED)} · ${esc(sourceLabel(i.platform, i.source))}</td></tr>
<tr><td>首次心跳</td><td>${esc(fmtTime(i.firstSeen))}</td></tr>
<tr><td>最近心跳</td><td>${esc(fmtTime(i.lastSeen))}</td></tr>
</table>${fixOnInstall(fix, i)}`
    : '<p class="muted">这个安装没有心跳记录（关了统计，或已超出保留期）。</p>';
  const versions = trail.versions.length
    ? `<h2>版本轨迹</h2><div class="card"><table>${trail.versions.map((v) => `<tr><td>${esc(v.version)}</td>`
      + `<td>${esc(v.firstDay)}${v.lastDay !== v.firstDay ? ` → ${esc(v.lastDay)}` : ''}</td></tr>`).join('')}</table></div>`
    : '';
  const related = trail.related.length
    ? `<h2>同一安装的其它反馈</h2><div class="card">${trail.related.map((r) => `<a class="row" href="/dev/f/${esc(r.id)}">
<span class="badge s-${esc(r.status)}">${esc(STATUS_LABEL[r.status] || r.status)}</span>
<span class="muted">#${esc(r.id)}</span><span class="t">${esc(r.title)}</span>
<span class="muted">${esc(fmtTime(r.createdAt))}</span></a>`).join('')}</div>`
    : '';
  const badge = trail.verified
    ? '<span class="badge ok">已验证</span> <span class="muted">（提交时出示了该安装的签名与工作量证明）</span>'
    : '<span class="badge warn">未验证</span> <span class="muted">（安装 id 为客户端自报，可伪造）</span>';
  if (trail.claimsVerifiedInstall) {
    return `<h2>安装</h2>
<div class="card"><p>${badge}</p><p class="muted"><code>${esc(trail.installId)}</code></p>
<p class="muted">这个 id 属于一个已验证安装，但这条反馈没有出示它的证明，不展示该安装的轨迹与其它反馈。</p></div>`;
  }
  return `<h2>安装</h2>
<div class="card"><p>${badge}</p><p class="muted"><code>${esc(trail.installId)}</code></p>${summary}</div>${versions}${related}`;
}

async function detailPage(env, id, dev) {
  const f = await devView(env, await feedbackById(env, id));
  const meta = Object.entries(f.meta || {})
    .map(([k, v]) => `<tr><td>${esc(k)}</td><td>${esc(v)}</td></tr>`).join('');
  const o = f.origin || {};
  const origin = [
    ['国家 / 地区', o.country || '未知'],
    ['ASN', o.asn ?? '未知'],
    ['User-Agent', o.ua || ''],
    ['带账户签名', o.signed ? '是' : '否'],
  ].map(([k, v]) => `<tr><td>${esc(k)}</td><td>${esc(v)}</td></tr>`).join('');
  const shots = f.attachments.filter((a) => a.kind === 'screenshot')
    .map((a) => `<a href="/dev/f/${esc(f.id)}/a/${esc(a.slot)}"><img src="/dev/f/${esc(f.id)}/a/${esc(a.slot)}" alt="截图 ${esc(a.slot)}"></a>`)
    .join('');
  const video = f.attachments.find((a) => a.kind === 'video');
  const videoBlock = video
    ? `<h2>视频</h2><div class="card"><video controls preload="metadata" src="/dev/f/${esc(f.id)}/a/${esc(video.slot)}"></video>
<p><a href="/dev/f/${esc(f.id)}/a/${esc(video.slot)}?download=1">下载视频（${esc(fmtBytes(video.bytes))}）</a></p></div>`
    : '';
  const log = f.attachments.find((a) => a.kind === 'log');
  const logLinks = log
    ? `<p><a href="/dev/f/${esc(f.id)}/a/log?view=text">查看日志</a> · <a href="/dev/f/${esc(f.id)}/a/log">下载 .gz</a> <span class="muted">(${esc(fmtBytes(log.bytes))})</span></p>`
    : '<p class="muted">未附日志。</p>';
  const timeline = f.messages.map((m) => {
    const who = m.author === 'dev' ? `开发者 ${esc(m.nickname || '')}` : '反馈人';
    // 反馈人在 App 里点「标记为已完成」（POST /v1/feedback/:id/close）。
    const st = m.author === 'user' && m.status === 'closed'
      ? ' · 反馈人标记完成'
      : m.status ? ` · 状态 → ${esc(STATUS_LABEL[m.status] || m.status)}` : '';
    const body = m.body ? `<div class="body">${esc(m.body)}</div>` : '';
    return `<div class="msg ${m.author}"><div class="muted">${who} · ${esc(fmtTime(m.createdAt))}${st}</div>${body}</div>`;
  }).join('');
  const options = STATUSES.map((s) => `<option value="${s}"${s === f.status ? ' selected' : ''}>${esc(STATUS_LABEL[s])}</option>`).join('');
  const reporter = f.reporter
    ? `${esc(f.reporter.nickname)}#${String(f.reporter.discriminator).padStart(4, '0')}`
    : '匿名';
  return html(layout(f.title, `<p><a href="/dev">← 返回列表</a></p>
<h1>${esc(f.title)}</h1>
${f.reporter && f.reporter.isDev ? `<p>${devReporterBadge(f.reporter, dev)}</p>` : ''}
<p class="muted"><span class="badge s-${esc(f.status)}">${esc(STATUS_LABEL[f.status] || f.status)}</span>
${esc(CATEGORY_LABEL[f.category] || f.category)} · #${esc(f.id)} · ${esc(fmtTime(f.createdAt))} · ${reporter}
${f.contact ? ` · 联系方式：${esc(f.contact)}` : ''}</p>
${f.parentId ? `<p>重新提交自 <a href="/dev/f/${esc(f.parentId)}">#${esc(f.parentId)}</a></p>` : ''}
${f.reopenedAs && f.reopenedAs.length ? `<p>已被重新提交为 ${f.reopenedAs.map((x) => `<a href="/dev/f/${esc(x)}">#${esc(x)}</a>`).join('、')}</p>` : ''}
${f.flags && f.flags.length ? `<p>${flagBadges(f.flags)}</p>` : ''}
<p class="note">${esc(UNTRUSTED_NOTE)}</p>
${fixSection(f.fix)}
<h2>AI 总结 <span class="muted">（仅开发者可见；据未核实的反馈内容生成）</span></h2>
<div class="card ai">${f.aiSummary
    ? `<div class="body">${esc(f.aiSummary)}</div><p class="muted">生成于 ${esc(fmtTime(f.aiSummaryAt))}</p>`
    : '<p class="muted">还没有 AI 总结。</p>'}</div>
<h2>开发者批改 <span class="muted">（仅开发者可见，反馈人看不到）</span></h2>
<form method="post" action="/dev/f/${esc(f.id)}/note" class="card">
<textarea id="devNote" name="devNote" maxlength="${FEEDBACK_LIMITS.devNoteMax}" aria-label="开发者批改">${esc(f.devNote || '')}</textarea>
${f.devNoteAt ? `<p class="muted">上次保存 ${esc(fmtTime(f.devNoteAt))}</p>` : ''}
<button>保存批改</button>
</form>
<h2>反馈原文</h2>
<div class="card"><div class="body">${esc(f.body)}</div></div>
${shots ? `<h2>截图</h2><div class="shots">${shots}</div>` : ''}
${videoBlock}
<h2>日志</h2>${logLinks}
<h2>服务端记录</h2><div class="card"><table>${origin}</table></div>
${meta ? `<h2>设备信息（客户端自报）</h2><div class="card"><table>${meta}</table></div>` : ''}
${installSection(f.install, f.fix)}
<h2>处理记录</h2>
<div class="card">${timeline || '<p class="muted">还没有记录。</p>'}</div>
<h2>处理</h2>
<form method="post" action="/dev/f/${esc(f.id)}" class="card">
<label for="status">状态</label>
<select id="status" name="status">${options}</select>
<label for="reply">回复反馈人（会显示在对方 App 里）</label>
<textarea id="reply" name="reply" maxlength="4000"></textarea>
<button>保存</button>
</form>`, { signedIn: true }));
}

/** /dev 下的全部请求。 */
export async function routeDevConsole(request, env, url, now, ctx, ip) {
  const path = url.pathname;
  const method = request.method;
  let m;

  if (method === 'POST') checkOrigin(request, url);

  if (method === 'POST' && path === '/dev/code') {
    const form = await readForm(request);
    const email = form.get('email') || '';
    try {
      await requestCode(env, ip, { email, purpose: 'login', lang: 'zh' }, now, ctx);
    } catch (e) {
      if (e instanceof HttpError) return loginPage({ email, error: `发送失败：${e.code}` });
      throw e;
    }
    return loginPage({ email, step: 'code' });
  }
  if (method === 'POST' && path === '/dev/login') {
    const form = await readForm(request);
    const email = form.get('email') || '';
    let ids;
    try {
      ids = await consumeCode(env, email, 'login', form.get('code') || '', now);
    } catch (e) {
      if (e instanceof HttpError) return loginPage({ email, step: 'code', error: `验证失败：${e.code}` });
      throw e;
    }
    const acc = await resolveEmailAccount(env, ids, now);
    if (!acc || acc.role !== 'dev') return loginPage({ email, error: '该账户不是开发者账户。' });
    const token = newSessionToken();
    await env.DB.prepare('INSERT INTO dev_sessions (token_hash, account_id, expires_at) VALUES (?1, ?2, ?3)')
      .bind(await tokenHash(token), acc.id, now + SESSION_TTL_MS).run();
    return redirect('/dev', { 'Set-Cookie': sessionCookie(token, Math.floor(SESSION_TTL_MS / 1000)) });
  }
  if (method === 'POST' && path === '/dev/logout') {
    const token = readCookie(request, SESSION_COOKIE);
    if (token) await env.DB.prepare('DELETE FROM dev_sessions WHERE token_hash = ?1').bind(await tokenHash(token)).run();
    return redirect('/dev', { 'Set-Cookie': sessionCookie('', 0) });
  }

  const dev = await sessionAccount(env, request, now);
  if (!dev) {
    if (method === 'GET' && path === '/dev') return loginPage();
    if (method === 'GET') return redirect('/dev');
    throw new HttpError(401, 'dev_session_required');
  }

  if (method === 'GET' && path === '/dev') return listPage(env, url, dev);
  if (method === 'GET' && path === '/dev/stats') return statsPage(env, now);
  if (method === 'GET' && path === '/dev/project') return projectPage(env, now);
  if (method === 'POST' && path === '/dev/project/refresh') {
    await refreshProjectStats(env, now, { force: true });
    return redirect('/dev/project');
  }
  if (method === 'GET' && (m = /^\/dev\/f\/([A-Za-z0-9_-]{8,16})$/.exec(path))) return detailPage(env, m[1], dev);
  if (method === 'GET' && (m = /^\/dev\/f\/([A-Za-z0-9_-]{8,16})\/a\/(log|s[0-2]|v0)$/.exec(path))) {
    return attachmentResponse(env, await feedbackById(env, m[1]), m[2], url.searchParams.get('view') === 'text', {
      range: request.headers.get('Range'),
      download: url.searchParams.get('download') === '1',
    });
  }
  if (method === 'POST' && (m = /^\/dev\/f\/([A-Za-z0-9_-]{8,16})$/.exec(path))) {
    const form = await readForm(request, formLimit(FEEDBACK_LIMITS.replyMax));
    const row = await feedbackById(env, m[1]);
    const status = form.get('status');
    const reply = form.get('reply') || '';
    // 表单总会带上当前状态：状态没变也没写回复时什么都不做，直接回详情。
    if (status === row.status && !reply.trim()) return redirect(`/dev/f/${row.id}`);
    await devUpdate(env, dev, row, { status, reply }, now, ctx);
    return redirect(`/dev/f/${row.id}`);
  }
  if (method === 'POST' && (m = /^\/dev\/f\/([A-Za-z0-9_-]{8,16})\/note$/.exec(path))) {
    const form = await readForm(request, formLimit(FEEDBACK_LIMITS.devNoteMax));
    const row = await feedbackById(env, m[1]);
    // 只收批改；AI 总结由 scripts/feedback.mjs 回写，网页不给改。
    await devSaveNotes(env, row, { devNote: form.get('devNote') || '' }, now);
    return redirect(`/dev/f/${row.id}`);
  }
  throw new HttpError(404, 'not_found');
}

/** 清掉过期会话（scheduled）。 */
export async function purgeDevSessions(env, now) {
  await env.DB.prepare('DELETE FROM dev_sessions WHERE expires_at < ?1').bind(now).run();
}
