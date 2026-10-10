// 开发者反馈处理台（网页，fushi.moe 上的 /dev）。
//
//   GET  /dev                     未登录 → 邮箱登录；已登录 → 反馈列表（?status=active|<状态>|all&cursor）
//   POST /dev/code   {email}      发登录验证码（与 App 新设备登录同一套 purpose=login 验证码）
//   POST /dev/login  {email,code} 验码 → 账户 role 必须是 dev → 写会话 Cookie
//   POST /dev/logout
//   GET  /dev/f/:id               详情：正文、设备信息、截图、日志、时间线、处理表单
//   GET  /dev/f/:id/a/:slot       附件（日志 ?view=text 解压成文本）
//   POST /dev/f/:id  {status,reply}
//
// 安全：页面无脚本（CSP script-src 为 none）；会话 Cookie HttpOnly + Secure + SameSite=Strict，
// 只发往 /dev；所有 POST 另验 Origin 与本站一致（双保险防 CSRF）。会话 7 天，库里只存 token 哈希。
// 业务一律复用 feedback.js 的函数，与 App 端开发者接口同一份逻辑。

import { HttpError, hex, sha256 } from './util.js';
import { consumeCode, requestCode } from './email.js';
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
    ? '<form method="post" action="/dev/logout" class="inline"><button class="link">退出</button></form>'
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
:root{--bg:#f7f6f3;--fg:#1d1c1a;--muted:#6b6862;--card:#fff;--line:#e4e1db;--accent:#b4532a;--ok:#2f7d4f}
@media (prefers-color-scheme:dark){:root{--bg:#161514;--fg:#ecebe8;--muted:#a19d96;--card:#201f1d;--line:#34322f;--accent:#e58a5f;--ok:#6cc08f}}
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
.card.ai{border-left:3px solid var(--ok)}
.note{border-left:3px solid #c98a00;padding:6px 10px;margin:12px 0;font-size:14px}
pre,.body{white-space:pre-wrap;word-break:break-word;margin:0}
table{border-collapse:collapse;width:100%;font-size:13px}
td{border-top:1px solid var(--line);padding:4px 6px;vertical-align:top;word-break:break-all}
td:first-child{color:var(--muted);width:30%}
.shots{display:flex;flex-wrap:wrap;gap:8px}
.shots img{max-width:260px;max-height:420px;border:1px solid var(--line);border-radius:8px}
.msg{border-left:3px solid var(--line);padding:4px 10px;margin:8px 0}
.msg.dev{border-color:var(--accent)}
label{display:block;margin:8px 0 4px;font-size:14px}
input,select,textarea{width:100%;font:inherit;padding:8px;border:1px solid var(--line);border-radius:8px;background:var(--card);color:var(--fg)}
textarea{min-height:110px}
button{font:inherit;margin-top:10px;padding:8px 16px;border:0;border-radius:8px;background:var(--accent);color:#fff;cursor:pointer}
button.link{background:none;color:var(--muted);padding:0;margin:0;text-decoration:underline}
.inline{display:inline}
.err{color:var(--accent)}
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
 * 表单体上限按字段字数算：urlencoded 下一个汉字是 9 字节（%XX×3），按 32 KB 一刀切时
 * 4000 字上限的回复框写到 ~3600 个汉字就 413。`chars` = 本表单最长文本字段的字数上限。
 */
function formLimit(chars) {
  return chars * 9 + 1024;
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
  const rows = res.items.map((f) => `<a class="row" href="/dev/f/${esc(f.id)}">
<span class="badge s-${esc(f.status)}">${esc(STATUS_LABEL[f.status] || f.status)}</span>
<span class="badge">${esc(CATEGORY_LABEL[f.category] || f.category)}</span>
<span class="muted">#${esc(f.id)}</span>
${f.parentId ? `<span class="badge">重新提交自 #${esc(f.parentId)}</span>` : ''}
<span class="t">${esc(f.title)}</span>
${f.awaitingDev ? '<span class="badge new">新消息</span>' : ''}
${f.hasDevNote ? '<span class="badge ok">已批改</span>' : ''}
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

async function detailPage(env, id) {
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
<p class="muted"><span class="badge s-${esc(f.status)}">${esc(STATUS_LABEL[f.status] || f.status)}</span>
${esc(CATEGORY_LABEL[f.category] || f.category)} · #${esc(f.id)} · ${esc(fmtTime(f.createdAt))} · ${reporter}
${f.contact ? ` · 联系方式：${esc(f.contact)}` : ''}</p>
${f.parentId ? `<p>重新提交自 <a href="/dev/f/${esc(f.parentId)}">#${esc(f.parentId)}</a></p>` : ''}
${f.reopenedAs && f.reopenedAs.length ? `<p>已被重新提交为 ${f.reopenedAs.map((x) => `<a href="/dev/f/${esc(x)}">#${esc(x)}</a>`).join('、')}</p>` : ''}
${f.flags && f.flags.length ? `<p>${flagBadges(f.flags)}</p>` : ''}
<p class="note">${esc(UNTRUSTED_NOTE)}</p>
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
<h2>日志</h2>${logLinks}
<h2>服务端记录</h2><div class="card"><table>${origin}</table></div>
${meta ? `<h2>设备信息（客户端自报）</h2><div class="card"><table>${meta}</table></div>` : ''}
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
    let hash;
    try {
      hash = await consumeCode(env, email, 'login', form.get('code') || '', now);
    } catch (e) {
      if (e instanceof HttpError) return loginPage({ email, step: 'code', error: `验证失败：${e.code}` });
      throw e;
    }
    const acc = await env.DB.prepare('SELECT id, role FROM accounts WHERE email_hash = ?1').bind(hash).first();
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
  if (method === 'GET' && (m = /^\/dev\/f\/([A-Za-z0-9_-]{8,16})$/.exec(path))) return detailPage(env, m[1]);
  if (method === 'GET' && (m = /^\/dev\/f\/([A-Za-z0-9_-]{8,16})\/a\/(log|s[0-2])$/.exec(path))) {
    return attachmentResponse(env, await feedbackById(env, m[1]), m[2], url.searchParams.get('view') === 'text');
  }
  if (method === 'POST' && (m = /^\/dev\/f\/([A-Za-z0-9_-]{8,16})$/.exec(path))) {
    const form = await readForm(request, formLimit(FEEDBACK_LIMITS.replyMax));
    const row = await feedbackById(env, m[1]);
    const status = form.get('status');
    const reply = form.get('reply') || '';
    // 表单总会带上当前状态：状态没变也没写回复时什么都不做，直接回详情。
    if (status === row.status && !reply.trim()) return redirect(`/dev/f/${row.id}`);
    await devUpdate(env, dev, row, { status, reply }, now);
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
