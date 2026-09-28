// 头像 / 作品封面缩略图：客户端先缩好再传（头像 128px、封面 ≤300px），服务端只验魔数与大小。
// R2 key 带时间戳版本号（a/<account>-<ts>.jpg），出图可设 immutable 长缓存，换图即换 key。

import { HttpError, randomId } from './util.js';
import { deleteMedia, reserveMediaBytes, spend } from './budget.js';

/**
 * 对象 key：<前缀>/<属主>-<随机>-<时刻>.<ext>。随机段不能省——同一毫秒两人抢传同一作品
 * 封面时 key 会相同，竞态输家「删掉自己的对象」会把赢家的删掉。
 */
function objectKey(prefix, owner, now, ext) {
  return `${prefix}/${owner}-${randomId(8)}-${now}.${ext}`;
}

// 客户端上传前已缩好（头像 128px、封面 ≤ 300px JPEG，一般 10–40KB）；上限留余量但不给存大图的机会。
export const AVATAR_MAX_BYTES = 64 * 1024;
export const COVER_MAX_BYTES = 96 * 1024;

/** 按魔数判图片类型；不认识返回 null。 */
export function sniffImage(bytes) {
  const b = bytes;
  if (b.length >= 3 && b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff) return { ext: 'jpg', type: 'image/jpeg' };
  if (b.length >= 8 && b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4e && b[3] === 0x47) {
    return { ext: 'png', type: 'image/png' };
  }
  if (
    b.length >= 12 &&
    String.fromCharCode(b[0], b[1], b[2], b[3]) === 'RIFF' &&
    String.fromCharCode(b[8], b[9], b[10], b[11]) === 'WEBP'
  ) {
    return { ext: 'webp', type: 'image/webp' };
  }
  return null;
}

export function requireImage(bytes) {
  const kind = sniffImage(bytes);
  if (!kind) throw new HttpError(415, 'not_an_image');
  return kind;
}

/** 扣全局媒体预算、预占 R2 配额后写入（任一超限都在写 R2 之前拒绝）。 */
export async function putImage(env, key, bytes, kind, now) {
  await spend(env, 'media', 1, now);
  await reserveMediaBytes(env, bytes.length);
  await env.MEDIA.put(key, bytes, { httpMetadata: { contentType: kind.type } });
}

export async function setAvatar(env, account, bytes, now) {
  const kind = requireImage(bytes);
  const key = objectKey('a', account.id, now, kind.ext);
  await putImage(env, key, bytes, kind, now);
  await env.DB.prepare('UPDATE accounts SET avatar_key = ?2 WHERE id = ?1').bind(account.id, key).run();
  await deleteMedia(env, account.avatar_key);
  return key;
}

export async function clearAvatar(env, account) {
  await env.DB.prepare('UPDATE accounts SET avatar_key = NULL WHERE id = ?1').bind(account.id).run();
  await deleteMedia(env, account.avatar_key);
}

/**
 * 作品封面：只有书架上有这部作品的人能传，且作品还没有任何封面（先到先得）。
 * 用条件 UPDATE 抢占，竞态下只有一个请求写入 key，输家删掉自己的对象。
 */
export async function setWorkCover(env, account, workId, bytes, now) {
  const kind = requireImage(bytes);
  const owns = await env.DB.prepare('SELECT 1 AS ok FROM shelf WHERE account_id = ?1 AND work_id = ?2')
    .bind(account.id, workId).first();
  if (!owns) throw new HttpError(403, 'not_on_shelf');
  const taken = await env.DB.prepare('SELECT 1 AS t FROM works WHERE id = ?1 AND (cover_key IS NOT NULL OR cover_url IS NOT NULL)')
    .bind(workId).first();
  if (taken) throw new HttpError(409, 'cover_exists'); // 先查一次，免得白扣预算、白写 R2
  const key = objectKey('c', workId, now, kind.ext);
  await putImage(env, key, bytes, kind, now);
  const res = await env.DB.prepare(
    'UPDATE works SET cover_key = ?2 WHERE id = ?1 AND cover_key IS NULL AND cover_url IS NULL',
  ).bind(workId, key).run();
  if (res.meta.changes !== 1) {
    await deleteMedia(env, key);
    throw new HttpError(409, 'cover_exists');
  }
  return key;
}

/**
 * 出图。key 带版本号、内容永不变，所以先查边缘缓存：命中就不碰 R2（省 B 类操作），
 * 未命中取一次 R2 后写回缓存。
 */
export async function serveImage(env, key, cacheKey, ctx) {
  if (!/^[ac]\/[A-Za-z0-9_-]+-\d+\.(jpg|png|webp)$/.test(key)) throw new HttpError(404, 'not_found');
  const cache = typeof caches !== 'undefined' ? caches.default : null;
  if (cache && cacheKey) {
    const hit = await cache.match(cacheKey);
    if (hit) return hit;
  }
  const obj = await env.MEDIA.get(key);
  if (!obj) throw new HttpError(404, 'not_found');
  const res = new Response(obj.body, {
    headers: {
      'Content-Type': (obj.httpMetadata && obj.httpMetadata.contentType) || 'application/octet-stream',
      'Cache-Control': 'public, max-age=31536000, immutable',
      'X-Content-Type-Options': 'nosniff',
    },
  });
  if (cache && cacheKey) {
    const put = cache.put(cacheKey, res.clone());
    if (ctx && ctx.waitUntil) ctx.waitUntil(put);
    else await put;
  }
  return res;
}
