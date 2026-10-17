// 作品封面按人数投票（迁移 0012）。
//
// 规则：
//   - 候选 = 一部作品的一张封面（R2 缩略图或白名单图床 URL）；一账户对一作品一票，改投即移票。
//   - 作品封面 = 票数最多的候选；平票取 reached_at 最早的（票数最近一次涨到当前值的时刻，即
//     「最早达到该票数」；掉票不改 reached_at），再平取 id 小的（先提交的）。
//     没有任何候选有票时作品封面保持原样（存量封面、旧客户端的先到先得结果都不动）。
//   - 票数只数未隐藏账户（增量维护；隐藏 / 恢复、管理合并拆分时精确重算）。
//   - 缩略图候选按 64 位 dHash 归并：汉明距离 ≤ COVER_HASH_MAX_DISTANCE 视为同一张图，后到的只投票、
//     不再存 R2。候选的哈希**一律由服务端从上传字节算**（cover_hash.js），客户端上报的哈希只用来核对，
//     否则谁都能拿任意图片冒充正版封面的哈希、劫持该候选的全部票。URL 候选按 URL 相等归并（服务端不下载图床图片，算不了哈希）。
//   - 没有任何投票行、且不是作品当前封面的候选立即删除，R2 对象一并删除并归还配额。
//
// 账户的票从哪来：
//   - 书架上报（shelf.js）：条目带白名单 coverUrl → 投给该 URL 候选——但只在本账户还没投票或
//     原票就是 URL 票时；缩略图票只由下面的投票接口改，上报不会把它冲掉。条目不再带 coverUrl
//     而原票是 URL 票 → 撤票。作品从书架消失 → 撤票。
//   - POST /v1/works/:id/cover/vote {hash | url}：按哈希命中已有候选就只投票；没命中回
//     409 cover_bytes_required，客户端再 PUT /v1/works/:id/cover?h=<hash> 带图片字节。
//   - PUT /v1/works/:id/cover 不带 h（旧客户端）：作品已有封面 → 409 cover_exists（与旧版一致，
//     旧客户端照旧丢弃）；没有 → 存为候选（带服务端哈希）并记上传者一票。

import { HttpError } from './util.js';

/** dHash 汉明距离阈值：≤ 10（64 位里差 10 位以内）视为同一张图。同图不同 JPEG 质量 / 尺寸通常 ≤ 4。 */
export const COVER_HASH_MAX_DISTANCE = 10;

export const COVER_HASH_RE = /^[0-9a-f]{16}$/;

/** 规范化客户端带来的哈希（大小写不敏感）；不合法返回 null。客户端哈希只用于查找 / 核对，从不入库。 */
export function normalizeCoverHash(raw) {
  if (typeof raw !== 'string') return null;
  const h = raw.toLowerCase();
  return COVER_HASH_RE.test(h) ? h : null;
}

function popcount32(x) {
  let v = x >>> 0;
  v -= (v >>> 1) & 0x55555555;
  v = (v & 0x33333333) + ((v >>> 2) & 0x33333333);
  return (((v + (v >>> 4)) & 0x0f0f0f0f) * 0x01010101) >>> 24;
}

/** 两个 16 位 hex 哈希的汉明距离。 */
export function hammingHex(a, b) {
  return (
    popcount32(parseInt(a.slice(0, 8), 16) ^ parseInt(b.slice(0, 8), 16)) +
    popcount32(parseInt(a.slice(8), 16) ^ parseInt(b.slice(8), 16))
  );
}

/**
 * 在候选里找与 hash 最近的一个（距离 ≤ 阈值）；同距离取票多的、再取 id 小的。没有返回 null。
 * @param {{id: number, phash: string | null, votes: number}[]} candidates
 */
export function nearestCandidate(candidates, hash) {
  let best = null;
  let bestD = Infinity;
  for (const c of candidates) {
    if (!c.phash) continue;
    const d = hammingHex(c.phash, hash);
    if (d > COVER_HASH_MAX_DISTANCE) continue;
    if (d < bestD || (d === bestD && (c.votes > best.votes || (c.votes === best.votes && c.id < best.id)))) {
      best = c;
      bestD = d;
    }
  }
  return best;
}

const J = (p) => `json_extract(value, '$.${p}')`;

/**
 * 本账户在这些作品上的现有投票（workIds = null 取全部）：Map<workId, {candidateId, url}>。
 * url 非空 = URL 票。
 */
export async function accountVotes(db, accountId, workIds) {
  const res = workIds === null
    ? await db.prepare(
      `SELECT v.work_id, v.candidate_id, c.cover_url FROM cover_votes v
       LEFT JOIN cover_candidates c ON c.id = v.candidate_id WHERE v.account_id = ?1`,
    ).bind(accountId).all()
    : await db.prepare(
      `SELECT v.work_id, v.candidate_id, c.cover_url FROM cover_votes v
       LEFT JOIN cover_candidates c ON c.id = v.candidate_id
       WHERE v.account_id = ?1 AND v.work_id IN (SELECT value FROM json_each(?2))`,
    ).bind(accountId, JSON.stringify(workIds)).all();
  return new Map(res.results.map((r) => [r.work_id, { candidateId: r.candidate_id, url: r.cover_url }]));
}

/**
 * 纯函数：书架上报后本账户的投票变化。
 * @param rows     resolveUpload().rows（coverUrl 已过白名单，null = 没带或不合法）
 * @param gone     从书架消失的作品
 * @param current  accountVotes() 的结果
 * @returns {{ops: object[], finalVote: Map<string, 'url'|'hash'|null>}}
 *   ops：给 voteStatements 的变化；finalVote：每个 put 作品处理后本账户的票型。
 */
export function shelfVoteOps(rows, gone, current) {
  const ops = [];
  const finalVote = new Map();
  for (const r of rows) {
    const cur = current.get(r.workId);
    const curKind = cur ? (cur.url ? 'url' : 'hash') : null;
    if (r.coverUrl && curKind !== 'hash') {
      if (cur && cur.url === r.coverUrl) {
        finalVote.set(r.workId, 'url');
        continue;
      }
      ops.push({ w: r.workId, from: cur ? cur.candidateId : null, cid: null, key: null, url: r.coverUrl });
      finalVote.set(r.workId, 'url');
    } else if (!r.coverUrl && curKind === 'url') {
      ops.push({ w: r.workId, from: cur.candidateId, cid: null, key: null, url: null });
      finalVote.set(r.workId, null);
    } else {
      finalVote.set(r.workId, curKind);
    }
  }
  for (const w of gone) {
    const cur = current.get(w);
    if (cur) ops.push({ w, from: cur.candidateId, cid: null, key: null, url: null });
  }
  return { ops, finalVote };
}

/**
 * 应用本账户的投票变化（放进调用方的事务；调用方负责账户级 CAS，保证 from 就是现票）。
 * ops: [{w, from, cid, key, url}]——目标候选按 cid / cover_key / (work, url) 之一定位，
 * 三者全空 = 撤票。URL 目标不存在时先建零票候选。counted = 账户未隐藏（隐藏账户的票照记、不计数）。
 * 末尾附物化与清理语句（清理 RETURNING cover_key，见 releasedCoverKeys）。
 */
export function voteStatements(db, accountId, ops, now, counted) {
  if (ops.length === 0) return [];
  const opsJson = JSON.stringify(ops);
  const works = JSON.stringify([...new Set(ops.map((o) => o.w))]);
  const target = `SELECT c.id FROM cover_candidates c WHERE c.work_id = ${J('w')} AND (
      c.id = ${J('cid')} OR (${J('key')} IS NOT NULL AND c.cover_key = ${J('key')})
      OR (${J('url')} IS NOT NULL AND c.cover_url = ${J('url')}))`;
  const stmts = [
    db.prepare(
      `INSERT OR IGNORE INTO cover_candidates (work_id, cover_url, votes, reached_at, created_at)
       SELECT ${J('w')}, ${J('url')}, 0, ?2, ?2 FROM json_each(?1) WHERE ${J('url')} IS NOT NULL`,
    ).bind(opsJson, now),
    // 指定的目标候选（cid / key）必须还在：并发清理删掉了就整批回滚（409 conflict，客户端下次重试）。
    db.prepare(
      `INSERT INTO cas_guard (ok) SELECT NULL FROM json_each(?1)
       WHERE (${J('cid')} IS NOT NULL OR ${J('key')} IS NOT NULL) AND NOT EXISTS (${target})`,
    ).bind(opsJson),
  ];
  if (counted) {
    stmts.push(db.prepare(
      `UPDATE cover_candidates SET votes = MAX(0, votes - 1)
       WHERE id IN (SELECT ${J('from')} FROM json_each(?1) WHERE ${J('from')} IS NOT NULL)`,
    ).bind(opsJson));
  }
  stmts.push(
    db.prepare(
      `DELETE FROM cover_votes WHERE account_id = ?2 AND work_id IN (
         SELECT ${J('w')} FROM json_each(?1)
         WHERE ${J('cid')} IS NULL AND ${J('key')} IS NULL AND ${J('url')} IS NULL)`,
    ).bind(opsJson, accountId),
    db.prepare(
      `INSERT INTO cover_votes (work_id, account_id, candidate_id, voted_at)
       SELECT ${J('w')}, ?2, (${target}), ?3 FROM json_each(?1)
       WHERE (${target}) IS NOT NULL
       ON CONFLICT (work_id, account_id) DO UPDATE SET
         candidate_id = excluded.candidate_id, voted_at = excluded.voted_at`,
    ).bind(opsJson, accountId, now),
  );
  if (counted) {
    stmts.push(db.prepare(
      `UPDATE cover_candidates SET votes = votes + 1, reached_at = ?2
       WHERE id IN (SELECT (${target}) FROM json_each(?1))`,
    ).bind(opsJson, now));
  }
  stmts.push(...settleStatements(db, works));
  return stmts;
}

/**
 * 按现有投票行精确重算这些作品全部候选的票数（管理操作、隐藏 / 恢复账户用；读量 = 这些作品的票数）。
 * 票数涨了的候选 reached_at 记为 now。
 */
export function recountStatement(db, worksJson, now) {
  return db.prepare(
    `UPDATE cover_candidates SET
       reached_at = CASE WHEN n.cnt > cover_candidates.votes THEN ?2 ELSE cover_candidates.reached_at END,
       votes = n.cnt
     FROM (SELECT c.id AS id, (SELECT COUNT(*) FROM cover_votes v JOIN accounts a ON a.id = v.account_id AND a.hidden = 0
                               WHERE v.candidate_id = c.id) AS cnt
           FROM cover_candidates c WHERE c.work_id IN (SELECT value FROM json_each(?1))) AS n
     WHERE cover_candidates.id = n.id AND n.cnt != cover_candidates.votes`,
  ).bind(worksJson, now);
}

/** 物化：把胜出候选写回 works.cover_key / cover_url（没有候选有票的作品不动）。 */
export function materializeStatement(db, worksJson) {
  return db.prepare(
    `UPDATE works SET cover_key = win.cover_key, cover_url = win.cover_url
     FROM (SELECT c.work_id, c.cover_key, c.cover_url FROM cover_candidates c
           WHERE c.work_id IN (SELECT value FROM json_each(?1)) AND c.votes > 0
             AND c.id = (SELECT c2.id FROM cover_candidates c2 WHERE c2.work_id = c.work_id AND c2.votes > 0
                         ORDER BY c2.votes DESC, c2.reached_at ASC, c2.id ASC LIMIT 1)) AS win
     WHERE works.id = win.work_id
       AND (works.cover_key IS NOT win.cover_key OR works.cover_url IS NOT win.cover_url)`,
  ).bind(worksJson);
}

/** 清理：没有任何投票行、也不是作品当前封面的候选。RETURNING cover_key（调用方删 R2）。 */
export function cleanupStatement(db, worksJson) {
  return db.prepare(
    `DELETE FROM cover_candidates
     WHERE work_id IN (SELECT value FROM json_each(?1))
       AND NOT EXISTS (SELECT 1 FROM cover_votes v WHERE v.candidate_id = cover_candidates.id)
       AND NOT EXISTS (SELECT 1 FROM works w WHERE w.id = cover_candidates.work_id
                       AND (w.cover_key = cover_candidates.cover_key OR w.cover_url = cover_candidates.cover_url))
     RETURNING cover_key`,
  ).bind(worksJson);
}

/** 物化 + 清理（清理在最后一条）。 */
export function settleStatements(db, worksJson) {
  return [materializeStatement(db, worksJson), cleanupStatement(db, worksJson)];
}

/** 从 batch 结果里收集清理语句 RETURNING 的 R2 key（结果行里带 cover_key 列的语句都算）。 */
export function releasedCoverKeys(results) {
  const keys = new Set();
  for (const r of results || []) {
    for (const row of (r && r.results) || []) {
      if (row && Object.hasOwn(row, 'cover_key') && row.cover_key) keys.add(row.cover_key);
    }
  }
  return [...keys];
}

/**
 * 作品被删除（孤儿清理）时一并删掉其投票与候选；候选语句 RETURNING cover_key。
 * 判据与 orphanPurgeStatements 一致：作品已无人在架。
 */
export function orphanCoverStatements(db, idsJson) {
  return [
    db.prepare(
      `DELETE FROM cover_votes WHERE work_id IN (SELECT value FROM json_each(?1))
         AND NOT EXISTS (SELECT 1 FROM shelf s WHERE s.work_id = cover_votes.work_id)`,
    ).bind(idsJson),
    db.prepare(
      `DELETE FROM cover_candidates WHERE work_id IN (SELECT value FROM json_each(?1))
         AND NOT EXISTS (SELECT 1 FROM shelf s WHERE s.work_id = cover_candidates.work_id)
       RETURNING cover_key`,
    ).bind(idsJson),
  ];
}

/** 本账户对一部作品的票型：'url' | 'hash' | null。 */
export function voteKind(vote) {
  return vote ? (vote.url ? 'url' : 'hash') : null;
}

export function requireOneOf(body) {
  const hash = body && body.hash !== undefined ? normalizeCoverHash(body.hash) : null;
  const url = body && body.url !== undefined ? body.url : null;
  if (body && body.hash !== undefined && !hash) throw new HttpError(400, 'bad_cover_hash');
  if ((hash === null) === (url === null)) throw new HttpError(400, 'bad_cover_vote');
  return { hash, url };
}
