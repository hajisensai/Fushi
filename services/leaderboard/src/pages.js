// 只读网页：分享链接的落地页（设计 §5「网页版」）。
//
//   GET /u/:id                 用户卡片 + 最近读完的 30 部（visibility=friends 只显示卡片）
//   GET /w/:id                 作品：封面、标题、作者、读者数、最近读者
//   GET /rank?metric&window    前 50（默认 book / month，全局榜）
//
// 数据一律取自 views.js 的读取函数、以匿名观看者身份（与 /v1 匿名读同一套可见性规则），
// 本文件不写 SQL。页面自包含：内联 CSS、没有任何脚本（CSP 里 script-src 为 none）。
// 所有用户内容（昵称、标题、作者）与属性值都经 esc() 转义；图片地址只放行本站 /img/
// 与封面白名单主机的 https，其余一律不出图。

import { HttpError } from './util.js';
import { acceptCoverUrl } from './shelf.js';
import { METRICS, WINDOWS, leaderboard, userCard, userShelf, workPage } from './views.js';

const PAGE_ID = '([A-Za-z0-9_-]{1,32})';
const USER_RE = new RegExp(`^/u/${PAGE_ID}$`);
const WORK_RE = new RegExp(`^/w/${PAGE_ID}$`);
export const SHELF_ON_PAGE = 30;
export const RANK_ON_PAGE = 50;
export const READERS_ON_PAGE = 50;

const KIND_LABEL = { book: '书', manga: '漫画', video: '视频', game: '游戏', chars: '字数' };
const WINDOW_LABEL = { week: '本周', month: '本月', all: '总榜' };

const CSP = [
  "default-src 'none'",
  "img-src 'self' https:",
  "style-src 'unsafe-inline'",
  "base-uri 'none'",
  "form-action 'none'",
  "frame-ancestors 'none'",
].join('; ');

/**
 * HTML 转义（文本与双引号属性值通用）。
 * @param {unknown} v
 * @returns {string}
 */
export function esc(v) {
  return String(v ?? '').replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);
}

/**
 * 页面可用的图片地址：本站 /img/ 相对路径或白名单 https；其余返回 null（不出图）。
 * @param {string | null | undefined} url
 * @returns {string | null}
 */
export function safeImage(url) {
  if (typeof url !== 'string') return null;
  if (/^\/img\/[A-Za-z0-9_./-]+$/.test(url) && !url.includes('..')) return url;
  return acceptCoverUrl(url);
}

/**
 * @param {number} n
 * @returns {string}
 */
function num(n) {
  return String(Math.trunc(Number(n) || 0)).replace(/\B(?=(\d{3})+(?!\d))/g, ',');
}

/**
 * @param {{nickname: string, discriminator: number}} a
 * @returns {string}
 */
function handle(a) {
  return `${esc(a.nickname)}<span class="disc">#${String(a.discriminator).padStart(4, '0')}</span>`;
}

/**
 * @param {{avatar: string | null, nickname: string}} a
 * @param {string} cls
 * @returns {string}
 */
function avatar(a, cls) {
  const src = safeImage(a.avatar);
  if (!src) return `<span class="${cls} avatar-empty" aria-hidden="true">${esc([...a.nickname][0] || '?')}</span>`;
  return `<img class="${cls}" src="${esc(src)}" alt="" loading="lazy">`;
}

/**
 * @param {{cover: string | null, nsfw: boolean, title: string}} w
 * @param {string} cls
 * @returns {string}
 */
function cover(w, cls) {
  const src = safeImage(w.cover);
  const blur = w.nsfw ? ' nsfw' : '';
  if (!src) return `<span class="${cls} cover-empty${blur}" aria-hidden="true"></span>`;
  return `<span class="${cls}${blur}"><img src="${esc(src)}" alt="" loading="lazy"></span>`;
}

/**
 * 整页骨架。
 * @param {{title: string, body: string, open?: string}} p  title 未转义；body 已是安全 HTML；open 为 fushi:// 链接
 * @returns {string}
 */
function layout({ title, body, open }) {
  const openLink = open ? `<a class="open" href="${esc(open)}">在 Fushi 中打开</a>` : '';
  return `<!doctype html>
<html lang="zh">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light dark">
<meta name="referrer" content="no-referrer">
<title>${esc(title)} · Fushi</title>
<style>${STYLE}</style>
</head>
<body>
<header><a class="brand" href="/rank">Fushi</a>${openLink}</header>
<main>
${body}
</main>
</body>
</html>`;
}

const STYLE = `
:root{--bg:#f7f6f3;--fg:#1d1c1a;--muted:#6b6862;--card:#fff;--line:#e4e1db;--accent:#b4532a}
@media (prefers-color-scheme:dark){:root{--bg:#161514;--fg:#ecebe8;--muted:#a19d96;--card:#201f1d;--line:#34322f;--accent:#e58a5f}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.5 system-ui,-apple-system,"Segoe UI","Noto Sans CJK SC","PingFang SC",sans-serif}
a{color:inherit}
header,main{max-width:720px;margin:0 auto;padding:12px 16px}
header{display:flex;align-items:center;justify-content:space-between;border-bottom:1px solid var(--line)}
.brand{font-weight:700;font-size:18px;text-decoration:none;letter-spacing:.02em}
.open{background:var(--accent);color:#fff;text-decoration:none;padding:6px 12px;border-radius:999px;font-size:14px}
h1{font-size:22px;margin:0;word-break:break-word}
h2{font-size:16px;margin:24px 0 8px}
.muted,.disc{color:var(--muted)}
.disc{font-weight:400;font-size:.8em;margin-left:2px}
.card{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:16px;display:flex;gap:16px;align-items:center;margin-top:16px}
.avatar,.avatar-sm{border-radius:50%;object-fit:cover;flex:none;background:var(--line);display:inline-flex;align-items:center;justify-content:center;color:var(--muted);font-weight:700}
.avatar{width:72px;height:72px;font-size:28px}
.avatar-sm{width:32px;height:32px;font-size:14px}
.stats{display:grid;grid-template-columns:repeat(auto-fit,minmax(100px,1fr));gap:8px;margin-top:12px}
.stat{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:8px 10px}
.stat b{display:block;font-size:18px}
.stat small{color:var(--muted)}
ul.list{list-style:none;margin:0;padding:0}
ul.list li{display:flex;gap:12px;align-items:center;padding:10px 0;border-bottom:1px solid var(--line)}
.grow{flex:1;min-width:0}
.title{font-weight:600;overflow-wrap:anywhere}
.cover,.cover-lg{flex:none;overflow:hidden;border-radius:6px;background:var(--line);display:block}
.cover{width:48px;height:68px}
.cover-lg{width:120px;height:170px}
.cover img,.cover-lg img{width:100%;height:100%;object-fit:cover;display:block}
.nsfw img{filter:blur(14px);transform:scale(1.1)}
.rank{width:2.5em;text-align:right;font-weight:700;color:var(--muted);flex:none}
.value{font-weight:700;flex:none}
nav.tabs{display:flex;flex-wrap:wrap;gap:6px;margin:12px 0}
nav.tabs a{text-decoration:none;padding:4px 10px;border:1px solid var(--line);border-radius:999px;font-size:14px}
nav.tabs a.on{background:var(--fg);color:var(--bg);border-color:var(--fg)}
.private{margin-top:16px;padding:24px;text-align:center;border:1px dashed var(--line);border-radius:12px;color:var(--muted)}
.error{padding:48px 0;text-align:center}
`;

/**
 * @param {string} html
 * @param {number} [status]
 * @returns {Response}
 */
function htmlResponse(html, status = 200) {
  return new Response(html, {
    status,
    headers: {
      'Content-Type': 'text/html; charset=utf-8',
      'Content-Security-Policy': CSP,
      'X-Content-Type-Options': 'nosniff',
      'Referrer-Policy': 'no-referrer',
    },
  });
}

/**
 * @param {number} status
 * @returns {Response}
 */
function errorPage(status) {
  const msg = status === 404 ? '找不到这个页面' : status === 400 ? '链接参数不正确' : '出错了，请稍后再试';
  return htmlResponse(layout({ title: String(status), body: `<p class="error">${esc(msg)}</p>` }), status);
}

/**
 * 读接口用的 URL（views.js 的读取函数从 searchParams 取分页/筛选）。
 * @param {Record<string, string>} q
 * @returns {URL}
 */
function queryUrl(q) {
  return new URL(`https://page.invalid/?${new URLSearchParams(q)}`);
}

/**
 * @param {any} env
 * @param {string} id
 * @param {number} now
 * @returns {Promise<string>}
 */
async function userPage(env, id, now) {
  const card = await userCard(env, id, null, now);
  const a = card.account;
  const stats = METRICS.map((m) => {
    const s = card.stats[m];
    const rank = s.rank ? `第 ${num(s.rank)} 名` : '未上榜';
    return `<div class="stat"><small>${esc(KIND_LABEL[m])}</small><b>${num(s.value)}</b><small>${esc(rank)}</small></div>`;
  }).join('');
  let shelf = '<p class="private">仅好友可见</p>';
  if (card.shelfVisible) {
    const res = await userShelf(env, id, queryUrl({ status: 'finished', limit: String(SHELF_ON_PAGE) }), null);
    shelf = res.rows.length === 0 ? '<p class="muted">还没有读完的作品</p>' : `<ul class="list">${res.rows.map(shelfRow).join('')}</ul>`;
  }
  const body = `<section class="card">${avatar(a, 'avatar')}<div class="grow"><h1>${handle(a)}</h1>
<div class="muted">注册于 ${esc(dateOf(card.createdAt))}${card.firstRecordDate ? ` · 首条记录 ${esc(card.firstRecordDate)}` : ''}</div></div></section>
<div class="stats">${stats}</div>
<h2>最近读完</h2>
${shelf}`;
  return layout({ title: `${a.nickname}#${String(a.discriminator).padStart(4, '0')}`, body, open: `fushi://leaderboard/user/${a.id}` });
}

/**
 * @param {number} ms
 * @returns {string}
 */
function dateOf(ms) {
  return new Date(ms).toISOString().slice(0, 10);
}

/**
 * @param {{work: any, finishedDate: string | null, readers: number}} r
 * @returns {string}
 */
function shelfRow(r) {
  const w = r.work;
  return `<li>${cover(w, 'cover')}<div class="grow"><a class="title" href="/w/${esc(w.id)}">${esc(w.title)}</a>
<div class="muted">${w.author ? `${esc(w.author)} · ` : ''}${esc(KIND_LABEL[w.kind] || w.kind)}</div>
<div class="muted">${r.finishedDate ? `${esc(r.finishedDate)} 读完` : '读完日期未知'} · ${num(r.readers)} 人读过</div></div></li>`;
}

/**
 * @param {any} env
 * @param {string} id
 * @returns {Promise<string>}
 */
async function workPageHtml(env, id) {
  const res = await workPage(env, id, queryUrl({ limit: String(READERS_ON_PAGE) }), null);
  const w = res.work;
  const readers = res.rows.map((r) => `<li>${avatar(r.account, 'avatar-sm')}<a class="grow title" href="/u/${esc(r.account.id)}">${handle(r.account)}</a>
<span class="muted">${r.finishedDate ? esc(r.finishedDate) : ''}</span></li>`).join('');
  const body = `<section class="card">${cover(w, 'cover-lg')}<div class="grow"><h1>${esc(w.title)}</h1>
${w.author ? `<div class="muted">${esc(w.author)}</div>` : ''}
<div class="muted">${esc(KIND_LABEL[w.kind] || w.kind)}</div>
<div class="stat" style="margin-top:12px;display:inline-block"><b>${num(res.readers)}</b><small>人读过</small></div></div></section>
<h2>最近读者</h2>
${readers ? `<ul class="list">${readers}</ul>` : '<p class="muted">还没有公开的读者</p>'}`;
  return layout({ title: w.title, body, open: `fushi://leaderboard/work/${w.id}` });
}

/**
 * @param {any} env
 * @param {URL} url
 * @param {number} now
 * @returns {Promise<string>}
 */
async function rankPage(env, url, now) {
  const metric = url.searchParams.get('metric') ?? 'book';
  const window = url.searchParams.get('window') ?? 'month';
  const res = await leaderboard(env, queryUrl({ metric, window, scope: 'global', limit: String(RANK_ON_PAGE) }), null, now);
  const tab = (m, w, label, on) => `<a class="${on ? 'on' : ''}" href="/rank?metric=${esc(m)}&amp;window=${esc(w)}">${esc(label)}</a>`;
  const metrics = METRICS.map((m) => tab(m, res.window, KIND_LABEL[m], m === res.metric)).join('');
  const windows = WINDOWS.map((w) => tab(res.metric, w, WINDOW_LABEL[w], w === res.window)).join('');
  const rows = res.rows.map((r) => `<li><span class="rank">${num(r.rank)}</span>${avatar(r.account, 'avatar-sm')}
<a class="grow title" href="/u/${esc(r.account.id)}">${handle(r.account)}</a><span class="value">${num(r.value)}</span></li>`).join('');
  const label = `${WINDOW_LABEL[res.window]}${KIND_LABEL[res.metric]}榜`;
  const body = `<h1 style="margin-top:16px">${esc(label)}</h1>
<nav class="tabs">${metrics}</nav><nav class="tabs">${windows}</nav>
${rows ? `<ul class="list">${rows}</ul>` : '<p class="muted">这个时段还没有人上榜</p>'}`;
  return layout({ title: label, body });
}

/**
 * 是否只读网页路径（worker.js 据此在鉴权前分流：网页一律匿名 + 走边缘缓存）。
 * @param {string} path
 * @returns {boolean}
 */
export function isPagePath(path) {
  return path === '/rank' || USER_RE.test(path) || WORK_RE.test(path);
}

/**
 * 渲染一个只读网页；读取层的 HttpError 转成同状态码的 HTML 错误页（不返回 JSON）。
 * @param {any} env
 * @param {URL} url
 * @param {number} now
 * @returns {Promise<Response>}
 */
export async function renderPage(env, url, now) {
  const path = url.pathname;
  let m;
  try {
    if (path === '/rank') return htmlResponse(await rankPage(env, url, now));
    if ((m = USER_RE.exec(path))) return htmlResponse(await userPage(env, m[1], now));
    if ((m = WORK_RE.exec(path))) return htmlResponse(await workPageHtml(env, m[1]));
    return errorPage(404);
  } catch (e) {
    if (e instanceof HttpError) return errorPage(e.status);
    throw e;
  }
}
