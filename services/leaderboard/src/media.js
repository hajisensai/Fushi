// 头像 / 作品封面缩略图：客户端先缩好再传（头像 ≤384px、封面 ≤300px JPEG）。头像只验魔数与大小；
// 封面还要解码算 dHash（cover_hash.js），候选按服务端哈希归并。
// R2 key 带时间戳版本号（a/<account>-<ts>.jpg），出图可设 immutable 长缓存，换图即换 key。

import { HttpError, randomId } from './util.js';
import { deleteMedia, reserveMediaBytes, spend } from './budget.js';
import { acceptCoverUrl, casBatch, casStatements } from './shelf.js';
import {
  COVER_HASH_MAX_DISTANCE,
  accountVotes,
  hammingHex,
  nearestCandidate,
  releasedCoverKeys,
  requireOneOf,
  settleStatements,
  voteStatements,
} from './cover_votes.js';
import { verifiedCoverHash } from './cover_hash.js';

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
  if (cur && target.url !== undefined && cur.url === target.url) return [];
  if (cur && target.cid !== undefined && cur.candidateId === target.cid) {
    if (!target.confirmed || cur.confirmed) return [];
    // 已投这个候选、现在补上确认：只改 confirmed，不动票数与 reached_at（不改平票次序），再物化。
    const works = JSON.stringify([workId]);
    const results = await casBatch(env.DB, [
      ...casStatements(env.DB, account.id, acc.shelf_rev),
      env.DB.prepare('UPDATE cover_votes SET confirmed = 1 WHERE work_id = ?1 AND account_id = ?2 AND candidate_id = ?3')
        .bind(workId, account.id, target.cid),
      ...settleStatements(env.DB, works, now),
    ]);
    return releasedCoverKeys(results);
  }
  const op = {
    w: workId,
    from: cur ? cur.candidateId : null,
    cid: target.cid ?? null,
    key: target.key ?? null,
    url: target.url ?? null,
    confirmed: target.confirmed ? 1 : 0,
  };
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

/** 给客户端比对用的候选描述：id + 缩略图地址（/img/<key>，公开、边缘缓存）。 */
function candidateRef(c) {
  return { id: c.id, image: `/img/${c.cover_key}` };
}

/** 本账户在 workId 上的现票（{candidateId, url, confirmed}），没有为 null。 */
async function currentVote(env, account, workId) {
  return (await accountVotes(env.DB, account.id, [workId])).get(workId) ?? null;
}

/** 哈希命中的候选（跳过本账户标过不符的）；返回给客户端的「待比对」响应，没命中抛 409。 */
async function checkResponse(env, account, workId, hash) {
  const match = await matchHash(env, workId, hash, account.id);
  if (!match) throw new HttpError(409, 'cover_bytes_required');
  const cur = await currentVote(env, account, workId);
  return {
    voted: false,
    candidate: candidateRef(match),
    confirmed: !!(cur && cur.candidateId === match.id && cur.confirmed),
  };
}

/**
 * POST /v1/works/:id/cover/vote：不带图片字节的投票（请求体见 cover_votes.js requireOneOf）。
 *   - {url}：白名单图床，候选按 URL 相等归并，确认票。
 *   - {hash}（旧客户端）：命中（汉明距离 ≤ 阈值）已有候选就投给它，未确认票；没命中 409
 *     cover_bytes_required（客户端随后 PUT 图片字节）。
 *   - {hash, check}：只返回命中的候选 {candidate: {id, image}, confirmed}，不投票；没命中 409。
 *   - {hash, confirm: cid}：本机比对通过，投确认票。cid 必须是本作品的缩略图候选、与 hash 在阈值内、
 *     且本账户没标过不符。
 *   - {hash, mismatch: cid}：本机比对不通过。记不符、撤掉投给 cid 的票，再按 check 返回下一个候选
 *     （或 409 cover_bytes_required）。
 */
export async function voteWorkCover(env, account, workId, body, now) {
  const { hash, url, check, confirm, mismatch } = requireOneOf(body);
  await requireOnShelf(env, account, workId);
  if (url !== null) {
    const accepted = acceptCoverUrl(url);
    if (!accepted) throw new HttpError(400, 'bad_cover_url');
    await deleteMedia(env, await castVote(env, account, workId, { url: accepted, confirmed: true }, now));
    return { voted: true, cover: await votedCover(env, account, workId), confirmed: true };
  }
  if (check) return checkResponse(env, account, workId, hash);
  if (mismatch !== null) {
    await recordMismatch(env, account, workId, mismatch, now);
    return checkResponse(env, account, workId, hash);
  }
  let target;
  if (confirm !== null) {
    const c = await env.DB.prepare(
      `SELECT id, phash FROM cover_candidates WHERE id = ?1 AND work_id = ?2 AND phash IS NOT NULL
         AND NOT EXISTS (SELECT 1 FROM cover_mismatches m WHERE m.candidate_id = ?1 AND m.account_id = ?3)`,
    ).bind(confirm, workId, account.id).first();
    if (!c) throw new HttpError(409, 'cover_candidate_gone');
    if (hammingHex(c.phash, hash) > COVER_HASH_MAX_DISTANCE) throw new HttpError(400, 'cover_hash_mismatch');
    target = { cid: c.id, confirmed: true };
  } else {
    const match = await matchHash(env, workId, hash, account.id);
    if (!match) throw new HttpError(409, 'cover_bytes_required');
    target = { cid: match.id, confirmed: false };
  }
  await deleteMedia(env, await castVote(env, account, workId, target, now));
  const cur = await currentVote(env, account, workId);
  return { voted: true, cover: await votedCover(env, account, workId), confirmed: !!(cur && cur.confirmed) };
}

/**
 * 记一条「不符」：本账户本机比对认定 cid 不是他手里那张图。撤掉他投给 cid 的票（同一事务，账户级
 * CAS），之后按哈希查找时对他跳过 cid。cid 不存在 / 不属于本作品时静默忽略（候选可能刚被清理）。
 */
async function recordMismatch(env, account, workId, cid, now) {
  const acc = await env.DB.prepare('SELECT shelf_rev, hidden FROM accounts WHERE id = ?1').bind(account.id).first();
  if (!acc) throw new HttpError(401, 'unknown_account');
  const cur = await currentVote(env, account, workId);
  const ops = cur && cur.candidateId === cid ? [{ w: workId, from: cid, cid: null, key: null, url: null }] : [];
  const results = await casBatch(env.DB, [
    ...casStatements(env.DB, account.id, acc.shelf_rev),
    env.DB.prepare(
      `INSERT OR IGNORE INTO cover_mismatches (work_id, candidate_id, account_id, at)
       SELECT work_id, id, ?3, ?4 FROM cover_candidates WHERE id = ?1 AND work_id = ?2`,
    ).bind(cid, workId, account.id, now),
    ...voteStatements(env.DB, account.id, ops, now, acc.hidden === 0),
  ]);
  await deleteMedia(env, releasedCoverKeys(results));
}

/** 哈希最近的候选（阈值内）；accountId 给出时跳过该账户标过不符的候选。 */
async function matchHash(env, workId, hash, accountId = null) {
  const rows = await env.DB.prepare(
    `SELECT id, phash, votes, cover_key FROM cover_candidates c WHERE work_id = ?1 AND phash IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM cover_mismatches m WHERE m.candidate_id = c.id AND m.account_id = ?2)`,
  ).bind(workId, accountId ?? '').all();
  return nearestCandidate(rows.results, hash);
}

/**
 * PUT /v1/works/:id/cover[?h=<dHash>]：上传封面缩略图（只收 JPEG）。
 * 候选的哈希一律由服务端从字节算（cover_hash.js；客户端上报的哈希不可信，见那里的文件头）。
 *   - 带 h（新客户端）：h 只用来核对——与服务端哈希距离超过阈值 → 400 cover_hash_mismatch。
 *     服务端哈希命中已有候选（跳过本账户标过不符的）只投未确认票、不存图，响应带 candidate 供客户端
 *     本机比对后 confirm / mismatch；没命中则存 R2、建候选并投确认票（他传的就是这张图）。
 *   - 不带 h（旧客户端）：作品已有封面 → 409 cover_exists（与旧版先到先得一致，旧客户端照旧丢弃）；
 *     没有 → 存为候选（同样带服务端哈希，之后的新客户端可以归并到它）并记上传者一票。
 * 返回 {cover: 本账户所投候选的展示地址, confirmed, candidate?}。
 */
export async function setWorkCover(env, account, workId, bytes, now, rawHash = null) {
  const kind = requireImage(bytes);
  await requireOnShelf(env, account, workId); // 先鉴权再解码：不给架外的人白耗 CPU
  if (rawHash === null) {
    const taken = await env.DB.prepare(
      'SELECT 1 AS t FROM works WHERE id = ?1 AND (cover_key IS NOT NULL OR cover_url IS NOT NULL)',
    ).bind(workId).first();
    if (taken) throw new HttpError(409, 'cover_exists'); // 先查一次，免得白解码、白扣预算、白写 R2
  }
  const hash = verifiedCoverHash(bytes, rawHash);
  if (rawHash !== null) {
    const match = await matchHash(env, workId, hash, account.id);
    if (match) {
      await deleteMedia(env, await castVote(env, account, workId, { cid: match.id, confirmed: false }, now));
      const cur = await currentVote(env, account, workId);
      return {
        cover: await votedCover(env, account, workId),
        confirmed: !!(cur && cur.confirmed),
        candidate: candidateRef(match),
      };
    }
  }
  const key = objectKey('c', workId, now, kind.ext);
  await putImage(env, key, bytes, kind, now);
  let released;
  try {
    // 建候选与投票同一个事务：零票的新候选不会在中间被别的请求的清理删掉。
    released = await castVote(env, account, workId, { key, confirmed: true }, now, [
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
  return { cover: await votedCover(env, account, workId), confirmed: true };
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
