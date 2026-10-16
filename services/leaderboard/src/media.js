// 头像 / 作品封面缩略图：客户端先缩好再传（头像 ≤384px、封面 ≤300px），服务端只验魔数与大小。
// R2 key 带时间戳版本号（a/<account>-<ts>.jpg），出图可设 immutable 长缓存，换图即换 key。

import { HttpError, randomId } from './util.js';
import { deleteMedia, reserveMediaBytes, spend } from './budget.js';
import { acceptCoverUrl, casBatch, casStatements } from './shelf.js';
import {
  accountVotes,
  nearestCandidate,
  normalizeCoverHash,
  releasedCoverKeys,
  requireOneOf,
  voteStatements,
} from './cover_votes.js';

/**
 * 对象 key：<前缀>/<属主>-<随机>-<时刻>.<ext>。随机段不能省——同一毫秒两人抢传同一作品
 * 封面时 key 会相同，竞态输家「删掉自己的对象」会把赢家的删掉。
 */
function objectKey(prefix, owner, now, ext) {
  return `${prefix}/${owner}-${randomId(8)}-${now}.${ext}`;
}

// 客户端上传前已缩好（头像 ≤384px 且按本上限逐级降质量、封面 ≤ 300px JPEG，一般 10–60KB）；上限留余量但不给存大图的机会。
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

/** 只有书架上有这部作品的人能投票 / 传封面。 */
async function requireOnShelf(env, account, workId) {
  const owns = await env.DB.prepare('SELECT 1 AS ok FROM shelf WHERE account_id = ?1 AND work_id = ?2')
    .bind(account.id, workId).first();
  if (!owns) throw new HttpError(403, 'not_on_shelf');
}

/**
 * 把本账户对 workId 的票投给 target（{cid} 已有候选 / {key} 本请求刚建的候选 / {url} URL 候选）。
 * pre = 同一事务里先执行的语句（新建候选）。账户级 CAS：与本账户的书架上报交错时整批回滚
 * （409 conflict）。返回清理出的 R2 key（调用方删）。
 */
async function castVote(env, account, workId, target, now, pre = []) {
  const acc = await env.DB.prepare('SELECT shelf_rev, hidden FROM accounts WHERE id = ?1').bind(account.id).first();
  if (!acc) throw new HttpError(401, 'unknown_account');
  const cur = (await accountVotes(env.DB, account.id, [workId])).get(workId);
  if (cur && target.cid !== undefined && cur.candidateId === target.cid) return [];
  if (cur && target.url !== undefined && cur.url === target.url) return [];
  const op = { w: workId, from: cur ? cur.candidateId : null, cid: target.cid ?? null, key: target.key ?? null, url: target.url ?? null };
  const results = await casBatch(env.DB, [
    ...casStatements(env.DB, account.id, acc.shelf_rev),
    ...pre,
    ...voteStatements(env.DB, account.id, [op], now, acc.hidden === 0),
  ]);
  return releasedCoverKeys(results);
}

/** 本账户在 workId 上当前所投候选的展示地址（/img/<key> 或图床 URL）。 */
async function votedCover(env, account, workId) {
  const row = await env.DB.prepare(
    `SELECT c.cover_key, c.cover_url FROM cover_votes v JOIN cover_candidates c ON c.id = v.candidate_id
     WHERE v.work_id = ?1 AND v.account_id = ?2`,
  ).bind(workId, account.id).first();
  if (!row) return null;
  return row.cover_url || `/img/${row.cover_key}`;
}

/**
 * POST /v1/works/:id/cover/vote {hash} | {url}：不带图片字节的投票。
 * hash 命中（汉明距离 ≤ 阈值）已有候选就投给它；没命中抛 409 cover_bytes_required
 * （客户端随后 PUT 图片字节）。url 必须是白名单图床，候选按 URL 相等归并。
 */
export async function voteWorkCover(env, account, workId, body, now) {
  const { hash, url } = requireOneOf(body);
  await requireOnShelf(env, account, workId);
  let target;
  if (url !== null) {
    const accepted = acceptCoverUrl(url);
    if (!accepted) throw new HttpError(400, 'bad_cover_url');
    target = { url: accepted };
  } else {
    const match = await matchHash(env, workId, hash);
    if (!match) throw new HttpError(409, 'cover_bytes_required');
    target = { cid: match.id };
  }
  await deleteMedia(env, await castVote(env, account, workId, target, now));
  return { voted: true, cover: await votedCover(env, account, workId) };
}

async function matchHash(env, workId, hash) {
  const rows = await env.DB.prepare(
    'SELECT id, phash, votes FROM cover_candidates WHERE work_id = ?1 AND phash IS NOT NULL',
  ).bind(workId).all();
  return nearestCandidate(rows.results, hash);
}

/**
 * PUT /v1/works/:id/cover[?h=<dHash>]：上传封面缩略图。
 *   - 带 h（新客户端）：命中已有候选只投票、不存图；没命中则存 R2、建候选并投票。
 *   - 不带 h（旧客户端）：作品已有封面 → 409 cover_exists（与旧版先到先得一致，免得不带哈希、
 *     无法归并的上传无限占用 R2）；没有 → 存为无哈希候选并记上传者一票。
 * 返回本账户所投候选的展示地址。
 */
export async function setWorkCover(env, account, workId, bytes, now, rawHash = null) {
  const kind = requireImage(bytes);
  await requireOnShelf(env, account, workId);
  const hash = rawHash === null ? null : normalizeCoverHash(rawHash);
  if (rawHash !== null && !hash) throw new HttpError(400, 'bad_cover_hash');
  if (hash) {
    const match = await matchHash(env, workId, hash);
    if (match) {
      await deleteMedia(env, await castVote(env, account, workId, { cid: match.id }, now));
      return votedCover(env, account, workId);
    }
  } else {
    const taken = await env.DB.prepare(
      'SELECT 1 AS t FROM works WHERE id = ?1 AND (cover_key IS NOT NULL OR cover_url IS NOT NULL)',
    ).bind(workId).first();
    if (taken) throw new HttpError(409, 'cover_exists'); // 先查一次，免得白扣预算、白写 R2
  }
  const key = objectKey('c', workId, now, kind.ext);
  await putImage(env, key, bytes, kind, now);
  let released;
  try {
    // 建候选与投票同一个事务：零票的新候选不会在中间被别的请求的清理删掉。
    released = await castVote(env, account, workId, { key }, now, [
      env.DB.prepare(
        `INSERT INTO cover_candidates (work_id, phash, cover_key, votes, reached_at, created_at)
         VALUES (?1, ?2, ?3, 0, ?4, ?4)`,
      ).bind(workId, hash, key, now),
    ]);
  } catch (e) {
    // 没投上（并发冲突等）：事务已回滚，候选行不存在，只撤掉对象。
    await deleteMedia(env, key);
    throw e;
  }
  await deleteMedia(env, released);
  return votedCover(env, account, workId);
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
