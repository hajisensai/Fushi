// Fushi 排行榜 / 公开书架 Worker（设计：docs/specs/2026-09-28-leaderboard-accounts.md）。
//
// 绑定：DB（D1 fushi-leaderboard）、MEDIA（R2 fushi-leaderboard-media）。
// secrets：ADMIN_USER / ADMIN_PASS；可选 vars：BANNED_WORDS。
//
// API（JSON；签名见 auth.js）：
//   POST   /v1/email/code               {email, purpose, lang?} 发邮箱验证码（email.js；永远 202）
//   POST   /v1/register                 {pubkey, nickname, email, code} 注册（验证码；幂等）
//   POST   /v1/login                    {pubkey, email, code}   新设备登录（绑定本机钥匙）
//   GET    /v1/me                        [签名]                  自己的账户
//   PATCH  /v1/me                        [签名] {nickname?, visibility?}
//   DELETE /v1/me                        [签名]                  删除账户与全部数据
//   PUT    /v1/me/avatar                 [签名] 图片字节
//   DELETE /v1/me/avatar                 [签名]
//   POST   /v1/shelf                     [签名] {reset?, put, remove, daily} 增量上报书架（shelf.js）
//   PUT    /v1/works/:id/cover           [签名] 图片字节          缺封面的作品补缩略图
//   GET    /v1/rank?metric&window&scope&limit&offset   [可选签名]
//   GET    /v1/works/popular?window&kind&limit&offset
//   GET    /v1/works/:id?limit&offset                   [可选签名]
//   GET    /v1/users/:id                                [可选签名]  用户卡片
//   GET    /v1/users/:id/shelf?status&kind&limit&offset [可选签名]
//   GET    /v1/friends                   [签名]                  好友 / 收到 / 发出的申请（social.js）
//   POST   /v1/friends/:id               [签名]                  申请或接受
//   DELETE /v1/friends/:id               [签名]                  删好友 / 撤回 / 拒绝
//   GET    /v1/blocks                    [签名]
//   POST   /v1/blocks/:id                [签名]                  屏蔽（同时删好友关系）
//   DELETE /v1/blocks/:id                [签名]
//   POST   /v1/reports                   [签名] {targetKind, targetId, reason}
//   GET    /img/<key>                                    R2 出图
//
// 只读网页（HTML，匿名 + 边缘缓存；pages.js）：GET /u/:id、/w/:id、/rank?metric&window
//
// 成本控制（防 Cloudflare 超额计费）：读接口读快照 + 边缘缓存 + READ_LIMITER 按 IP 限流；
// 写接口增量、按账户限流、扣全局日预算（budget.js）；定时任务每 30 分钟刷新快照。

import { HttpError, errorResponse, json, parseJsonBytes, readBodyBytes } from './util.js';
import { SIG_WINDOW_MS, authenticate } from './auth.js';
import { LIMITS, hit, purgeRateLimits } from './ratelimit.js';
import { MAX_SHELF_BODY, applyShelfDelta, normalizeUpload } from './shelf.js';
import { deleteMedia, purgeBudgets, spend } from './budget.js';
import { refreshSnapshots } from './snapshots.js';
import { AVATAR_MAX_BYTES, COVER_MAX_BYTES, clearAvatar, serveImage, setAvatar, setWorkCover } from './media.js';
import { deleteAccount, login, register, selfView, updateProfile } from './account.js';
import { purgeEmailCodes, requestCode } from './email.js';
import { leaderboard, popularWorks, userCard, userShelf, workPage } from './views.js';
import { handleAdmin } from './admin.js';
import { listBlocks, listFriends, matchSocialWrite } from './social.js';
import { isPagePath, renderPage } from './pages.js';

const HOUR = 3600 * 1000;
const JSON_BODY_MAX = 16 * 1024;
/** 小写操作（资料 / 好友 / 屏蔽 / 举报）按估算行数扣全局写入预算（含索引与防重放、限流记录）。 */
const SMALL_WRITE_ROWS = 8;
const ID = '([A-Za-z0-9_-]{1,32})';

function configMissing(env) {
  return !env.DB || !env.MEDIA;
}

/**
 * 限流用的客户端键。IPv6 按 /64 聚合：一台机器通常就有整个 /64，逐地址计数等于没限。
 */
export function clientIp(request) {
  const ip = request.headers.get('CF-Connecting-IP') || 'unknown';
  if (!ip.includes(':')) return ip;
  const full = ip.includes('::')
    ? (() => {
      const [head, tail] = ip.split('::');
      const h = head ? head.split(':') : [];
      const t = tail ? tail.split(':') : [];
      return [...h, ...Array(8 - h.length - t.length).fill('0'), ...t];
    })()
    : ip.split(':');
  return `${full.slice(0, 4).map((x) => x.toLowerCase().replace(/^0+(?=.)/, '')).join(':')}::/64`;
}

/**
 * Workers Rate Limiting binding（不占 D1）。读接口用 READ_LIMITER；未鉴权的写入口（发码 / 注册 / 登录）
 * 先过 AUTH_LIMITER，通过了才碰 D1——否则换地址的请求每次都会在 D1 里新建一行限流计数，写入无上界。
 */
async function bindingLimit(limiter, request) {
  if (!limiter) return;
  const { success } = await limiter.limit({ key: clientIp(request) });
  if (!success) throw new HttpError(429, 'rate_limited');
}

/** 各读接口认的查询参数；缓存键与计算都只用这些（加无关参数绕不过边缘缓存）。 */
const READ_PARAMS = ['metric', 'window', 'scope', 'kind', 'status', 'limit', 'offset', 'cursor'];

export function canonicalReadUrl(url) {
  const out = new URL(url.origin + url.pathname);
  for (const k of READ_PARAMS) {
    const v = url.searchParams.get(k);
    if (v !== null) out.searchParams.set(k, v);
  }
  return out;
}

const READ_CACHE_SECONDS = 60;

/** 只属于签名者本人的读接口：必须签名，结果随人变，从不进边缘缓存。 */
const SELF_READS = {
  '/v1/me': async (_env, viewer) => selfView(viewer),
  '/v1/friends': listFriends,
  '/v1/blocks': listBlocks,
};

async function cachedRead(key, ctx, compute) {
  const cache = typeof caches !== 'undefined' ? caches.default : null;
  if (!cache) return compute();
  const hitRes = await cache.match(key);
  if (hitRes) return hitRes;
  const res = await compute();
  if (res.status === 200) {
    const stored = new Response(res.body, res);
    stored.headers.set('Cache-Control', `public, max-age=${READ_CACHE_SECONDS}`);
    const copy = stored.clone();
    const put = cache.put(key, copy);
    if (ctx && ctx.waitUntil) ctx.waitUntil(put);
    else await put;
    return stored;
  }
  return res;
}

async function readRoute(env, url, viewer, now) {
  const path = url.pathname;
  let m;
  if (path === '/v1/rank') return json(await leaderboard(env, url, viewer, now));
  if (path === '/v1/works/popular') return json(await popularWorks(env, url, now));
  if ((m = new RegExp(`^/v1/works/${ID}$`).exec(path))) return json(await workPage(env, m[1], url, viewer));
  if ((m = new RegExp(`^/v1/users/${ID}$`).exec(path))) return json(await userCard(env, m[1], viewer, now));
  if ((m = new RegExp(`^/v1/users/${ID}/shelf$`).exec(path))) return json(await userShelf(env, m[1], url, viewer));
  throw new HttpError(404, 'not_found');
}

async function route(request, env, now, ctx) {
  const url = new URL(request.url);
  const path = url.pathname;
  const method = request.method;
  let m;

  if (method === 'GET' && path === '/v1/health') return json({ ok: true });
  if (method === 'GET' && path.startsWith('/img/')) return serveImage(env, path.slice(5), request, ctx);

  if (path.startsWith('/admin/api/')) {
    const bytes = method === 'POST' ? await readBodyBytes(request, JSON_BODY_MAX) : new Uint8Array();
    const body = bytes.length ? parseJsonBytes(bytes) : {};
    return handleAdmin(env, request, path, body, now);
  }

  if (method === 'POST' && (path === '/v1/email/code' || path === '/v1/login' || path === '/v1/register')) {
    await bindingLimit(env.AUTH_LIMITER, request);
  }
  if (method === 'POST' && path === '/v1/email/code') {
    const bytes = await readBodyBytes(request, JSON_BODY_MAX);
    await requestCode(env, clientIp(request), parseJsonBytes(bytes), now, ctx);
    return json({ sent: true }, 202);
  }
  if (method === 'POST' && path === '/v1/login') {
    await hit(env, `login:${clientIp(request)}`, HOUR, LIMITS.registerPerIpHour * 4, now);
    const bytes = await readBodyBytes(request, JSON_BODY_MAX);
    return json(await login(env, request, parseJsonBytes(bytes), bytes, now));
  }
  if (method === 'POST' && path === '/v1/register') {
    await hit(env, `register:${clientIp(request)}`, HOUR, LIMITS.registerPerIpHour, now);
    const bytes = await readBodyBytes(request, JSON_BODY_MAX);
    const res = await register(env, request, parseJsonBytes(bytes), bytes, now);
    return json(res.account, res.created ? 201 : 200);
  }

  // ---- 读接口：签名可选（带了就按观看者身份套好友/屏蔽规则） ----
  if (method === 'GET') {
    await bindingLimit(env.READ_LIMITER, request);
    const canon = canonicalReadUrl(url);
    // 分享落地页：浏览器不签名，一律按匿名观看者渲染（带了签名头也忽略），同样走边缘缓存。
    if (isPagePath(path)) return cachedRead(canon.toString(), ctx, () => renderPage(env, canon, now));
    const viewer = await authenticate(request, env, new Uint8Array(), now, { optional: true });
    const own = Object.hasOwn(SELF_READS, path) ? SELF_READS[path] : null;
    if (own) {
      if (!viewer) throw new HttpError(401, 'auth_required');
      return json(await own(env, viewer));
    }
    // 匿名读是同一份公开数据：边缘缓存一分钟，挡住反复刷榜单造成的全表扫描。
    // 带签名的请求结果随观看者变（好友 / 屏蔽 / 我的名次），不缓存。
    return viewer
      ? readRoute(env, canon, viewer, now)
      : cachedRead(canon.toString(), ctx, () => readRoute(env, canon, null, now));
  }

  // ---- 写接口：一律签名 + 防重放 ----
  if (method === 'POST' && path === '/v1/shelf') {
    const bytes = await readBodyBytes(request, MAX_SHELF_BODY);
    const account = await authenticate(request, env, bytes, now, { mutating: true });
    await hit(env, `shelf:${account.id}`, HOUR, LIMITS.shelfUploadPerHour, now);
    const upload = normalizeUpload(parseJsonBytes(bytes), now);
    const res = await applyShelfDelta(env, account, account.keyId, upload, now);
    await deleteMedia(env, res.coverKeys);
    return json({ works: res.works, shelfCount: res.shelfCount });
  }
  if (path === '/v1/me/avatar' && (method === 'PUT' || method === 'DELETE')) {
    const bytes = await readBodyBytes(request, AVATAR_MAX_BYTES);
    const account = await authenticate(request, env, bytes, now, { mutating: true });
    await hit(env, `media:${account.id}`, HOUR, LIMITS.mediaUploadPerHour, now);
    if (method === 'DELETE') {
      await clearAvatar(env, account);
      return json({ avatar: null });
    }
    return json({ avatar: `/img/${await setAvatar(env, account, bytes, now)}` });
  }
  if (method === 'PUT' && (m = new RegExp(`^/v1/works/${ID}/cover$`).exec(path))) {
    const bytes = await readBodyBytes(request, COVER_MAX_BYTES);
    const account = await authenticate(request, env, bytes, now, { mutating: true });
    await hit(env, `media:${account.id}`, HOUR, LIMITS.mediaUploadPerHour, now);
    return json({ cover: `/img/${await setWorkCover(env, account, m[1], bytes, now)}` });
  }
  const social = matchSocialWrite(method, path);
  if (social) {
    const bytes = await readBodyBytes(request, JSON_BODY_MAX);
    const account = await authenticate(request, env, bytes, now, { mutating: true });
    await hit(env, `social:${account.id}`, HOUR, LIMITS.socialWritePerHour, now);
    await spend(env, 'write_rows', SMALL_WRITE_ROWS, now);
    return social(env, account, bytes, now);
  }
  if (path === '/v1/me' && (method === 'PATCH' || method === 'DELETE')) {
    const bytes = await readBodyBytes(request, JSON_BODY_MAX);
    const account = await authenticate(request, env, bytes, now, { mutating: true });
    if (method === 'DELETE') {
      await deleteAccount(env, account);
      return new Response(null, { status: 204 });
    }
    await hit(env, `social:${account.id}`, HOUR, LIMITS.socialWritePerHour, now);
    await spend(env, 'write_rows', SMALL_WRITE_ROWS, now);
    return json(await updateProfile(env, account, parseJsonBytes(bytes)));
  }
  throw new HttpError(404, 'not_found');
}

export default {
  async fetch(request, env, ctx) {
    if (configMissing(env)) return json({ error: 'not_configured' }, 503);
    try {
      return await route(request, env, Date.now(), ctx);
    } catch (e) {
      return errorResponse(e);
    }
  },
  async scheduled(_event, env) {
    const now = Date.now();
    await refreshSnapshots(env, now);
    await purgeRateLimits(env, now - 2 * 24 * HOUR, now - 2 * SIG_WINDOW_MS);
    await purgeBudgets(env, now);
    await purgeEmailCodes(env, now);
  },
};

export { route };
