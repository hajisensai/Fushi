// Fushi 排行榜 / 公开书架 Worker（设计：docs/specs/2026-09-28-leaderboard-accounts.md）。
//
// 绑定：DB（D1 fushi-leaderboard）、MEDIA（R2 fushi-leaderboard-media）。
// secrets：ADMIN_USER / ADMIN_PASS；可选 vars：BANNED_WORDS。
//
// API（JSON；签名见 auth.js）：
//   POST   /v1/register                 {pubkey, nickname}      注册（幂等）
//   GET    /v1/me                        [签名]                  自己的账户
//   PATCH  /v1/me                        [签名] {nickname?, visibility?}
//   DELETE /v1/me                        [签名]                  删除账户与全部数据
//   PUT    /v1/me/avatar                 [签名] 图片字节
//   DELETE /v1/me/avatar                 [签名]
//   POST   /v1/shelf                     [签名] {entries, daily} 整份替换书架
//   PUT    /v1/works/:id/cover           [签名] 图片字节          缺封面的作品补缩略图
//   GET    /v1/rank?metric&window&scope&limit&offset   [可选签名]
//   GET    /v1/works/popular?window&kind&limit&offset
//   GET    /v1/works/:id?limit&offset                   [可选签名]
//   GET    /v1/users/:id                                [可选签名]  用户卡片
//   GET    /v1/users/:id/shelf?status&kind&limit&offset [可选签名]
//   GET    /img/<key>                                    R2 出图

import { HttpError, errorResponse, json, parseJsonBytes, readBodyBytes } from './util.js';
import { SIG_WINDOW_MS, authenticate } from './auth.js';
import { LIMITS, hit, purgeRateLimits } from './ratelimit.js';
import { MAX_SHELF_BODY, normalizeUpload, replaceShelf } from './shelf.js';
import { AVATAR_MAX_BYTES, COVER_MAX_BYTES, clearAvatar, serveImage, setAvatar, setWorkCover } from './media.js';
import { deleteAccount, register, selfView, updateProfile } from './account.js';
import { leaderboard, popularWorks, userCard, userShelf, workPage } from './views.js';
import { handleAdmin } from './admin.js';

const HOUR = 3600 * 1000;
const JSON_BODY_MAX = 16 * 1024;
const ID = '([A-Za-z0-9_-]{1,32})';

function configMissing(env) {
  return !env.DB || !env.MEDIA;
}

function clientIp(request) {
  return request.headers.get('CF-Connecting-IP') || 'unknown';
}

/** 读接口按 IP 限流：部署了 CF Rate Limiting binding（READ_LIMITER）才生效。 */
async function readLimit(env, request) {
  if (!env.READ_LIMITER) return;
  const { success } = await env.READ_LIMITER.limit({ key: clientIp(request) });
  if (!success) throw new HttpError(429, 'rate_limited');
}

const READ_CACHE_SECONDS = 60;

async function cachedRead(request, ctx, compute) {
  const cache = typeof caches !== 'undefined' ? caches.default : null;
  if (!cache) return compute();
  const hitRes = await cache.match(request.url);
  if (hitRes) return hitRes;
  const res = await compute();
  if (res.status === 200) {
    const stored = new Response(res.body, res);
    stored.headers.set('Cache-Control', `public, max-age=${READ_CACHE_SECONDS}`);
    const copy = stored.clone();
    const put = cache.put(request.url, copy);
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
  if (method === 'GET' && path.startsWith('/img/')) return serveImage(env, path.slice(5));

  if (path.startsWith('/admin/api/')) {
    const bytes = method === 'POST' ? await readBodyBytes(request, JSON_BODY_MAX) : new Uint8Array();
    const body = bytes.length ? parseJsonBytes(bytes) : {};
    return handleAdmin(env, request, path, body, now);
  }

  if (method === 'POST' && path === '/v1/register') {
    await hit(env, `register:${clientIp(request)}`, HOUR, LIMITS.registerPerIpHour, now);
    const bytes = await readBodyBytes(request, JSON_BODY_MAX);
    const res = await register(env, request, parseJsonBytes(bytes), bytes, now);
    return json(res.account, res.created ? 201 : 200);
  }

  // ---- 读接口：签名可选（带了就按观看者身份套好友/屏蔽规则） ----
  if (method === 'GET') {
    await readLimit(env, request);
    const viewer = await authenticate(request, env, new Uint8Array(), now, { optional: true });
    if (path === '/v1/me') {
      if (!viewer) throw new HttpError(401, 'auth_required');
      return json(selfView(viewer));
    }
    // 匿名读是同一份公开数据：边缘缓存一分钟，挡住反复刷榜单造成的全表扫描。
    // 带签名的请求结果随观看者变（好友 / 屏蔽 / 我的名次），不缓存。
    return viewer ? readRoute(env, url, viewer, now) : cachedRead(request, ctx, () => readRoute(env, url, null, now));
  }

  // ---- 写接口：一律签名 + 防重放 ----
  if (method === 'POST' && path === '/v1/shelf') {
    const bytes = await readBodyBytes(request, MAX_SHELF_BODY);
    const account = await authenticate(request, env, bytes, now, { mutating: true });
    await hit(env, `shelf:${account.id}`, HOUR, LIMITS.shelfUploadPerHour, now);
    const upload = normalizeUpload(parseJsonBytes(bytes), now);
    return json({ works: await replaceShelf(env, account.id, upload, now) });
  }
  if (path === '/v1/me/avatar' && (method === 'PUT' || method === 'DELETE')) {
    const bytes = await readBodyBytes(request, AVATAR_MAX_BYTES);
    const account = await authenticate(request, env, bytes, now, { mutating: true });
    if (method === 'DELETE') {
      await clearAvatar(env, account);
      return json({ avatar: null });
    }
    await hit(env, `media:${account.id}`, HOUR, LIMITS.mediaUploadPerHour, now);
    return json({ avatar: `/img/${await setAvatar(env, account, bytes, now)}` });
  }
  if (method === 'PUT' && (m = new RegExp(`^/v1/works/${ID}/cover$`).exec(path))) {
    const bytes = await readBodyBytes(request, COVER_MAX_BYTES);
    const account = await authenticate(request, env, bytes, now, { mutating: true });
    await hit(env, `media:${account.id}`, HOUR, LIMITS.mediaUploadPerHour, now);
    return json({ cover: `/img/${await setWorkCover(env, account, m[1], bytes, now)}` });
  }
  if (path === '/v1/me' && (method === 'PATCH' || method === 'DELETE')) {
    const bytes = await readBodyBytes(request, JSON_BODY_MAX);
    const account = await authenticate(request, env, bytes, now, { mutating: true });
    if (method === 'DELETE') {
      await deleteAccount(env, account);
      return new Response(null, { status: 204 });
    }
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
    await purgeRateLimits(env, now - 2 * 24 * HOUR, now - 2 * SIG_WINDOW_MS);
  },
};

export { route };
