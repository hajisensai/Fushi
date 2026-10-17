// 作品封面按人数投票（迁移 0012；替换门槛与确认票见迁移 0014）。
//
// 规则：
//   - 候选 = 一部作品的一张封面（R2 缩略图或白名单图床 URL）；一账户对一作品一票，改投即移票。
//   - 作品封面 = 票数最多的候选；平票取 reached_at 最早的（票数最近一次涨到当前值的时刻，即
//     「最早达到该票数」；掉票不改 reached_at），再平取 id 小的（先提交的）。
//     没有任何候选有票时作品封面保持原样（存量封面、旧客户端的先到先得结果都不动）。
//   - **替换门槛**：作品已有封面（含迁移 0012 回填的存量封面）时，挑战者候选要取代它必须同时满足：
//     ① 确认票 ≥ COVER_REPLACE_MIN_CONFIRMED 个不同（未隐藏、且**注册早于该候选创建**）账户；
//     ② 候选创建满 COVER_REPLACE_COOLDOWN_MS；③ 比现封面强：现封面自己的确认票也 ≥ 门槛时比总票数
//     （严格多于，平票现封面留任）；现封面确认票不足门槛时比确认票（挑战者确认票严格多于现封面确认票）。
//     为什么比确认票：现封面若是伪造图抢到的首张，旧客户端按哈希投的未确认票会被它收割、把总票数
//     撑高（「入场票收割」），正版靠确认票永远追不上；只有现封面本身已有足够确认票时，总票数才可信。
//     为什么注册时间要早于候选：否则攻击者可以先建候选、再现注册小号来凑确认票。
//     为什么：dHash 只是感知哈希，知道公开的正版封面就能「老实地」造出服务端哈希距离很近、显示却是
//     另一张图的 JPEG（审查实测），服务端解码只挡得住低级伪造。一个人拿伪造图抢先建候选，之后持正版
//     封面的用户按哈希投票都会投到他的图上——票是被「收割」来的。门槛只数确认票，收割不到；冷却期给
//     管理员 / 正版持有者留出发现和反制（投回正版、清封面、隐藏账户）的时间。
//   - **确认票**（cover_votes.confirmed = 1）：投票者手里确实有这张图。三种来源：
//       上传字节建出该候选的人（他传的就是这张图）；URL 票（URL 相等即同一张图）；
//       新客户端按哈希命中后**在本机**下载候选缩略图、与本地封面做强比对（32×32 灰度的 NCC +
//       去掉 9×8 粗格后的细节 NCC，fushi_engine leaderboard/cover_compare.dart）通过后提交的
//       {hash, confirm: cid}。比对放在投票者设备上：CPU 在用户端，而且只有他有正版原图。
//     **防护边界**：confirm 是客户端自报的，服务端验证不了比对真的发生过。所以门槛的实质是
//     「3 个注册早于候选的账户 + 24 小时公示期 + 管理员可见的不符计数」；本机强比对防的是诚实客户端被
//     收割去给伪造图投票，不防一人多号（多号各自 confirm 即可）。
//     比对不通过 → {hash, mismatch: cid}：记进 cover_mismatches（管理端信号，见 GET
//     /admin/api/works/:id/covers），撤掉他投给该候选的票，之后按哈希查找时对他跳过这个候选
//     （于是他会命中下一个候选或上传自己的图，另立候选）。不符记录不影响排名、不阻止替换——
//     否则几个小号刷「不符」就能把正版钉死在现封面上。
//   - **旧客户端**（只会 {hash} 投票、不会比对）的票 confirmed = NULL：照常计入 votes——决定首张封面、
//     现封面留任、候选之间排序都和以前一样——但不计入替换门槛。所以旧客户端用户的行为不变，只是他们
//     不能单独把已有封面换掉。
//   - 作品**没有封面**时首张不受门槛约束，照旧立即生效（否则冷门作品永远没有封面）。例外：管理员
//     刚清过封面（works.cover_cleared_at 在 COVER_CLEAR_GUARD_MS 内）的作品按「已有封面、现封面 0 票」
//     处理，首张也要过门槛——清封面多半是因为有人在抢，不能让攻击者在清掉的瞬间再抢回首张。
//   - 冷却到期而没有新票时，由定时任务 settlePendingCovers（*/30）分批重新物化；期间有任何投票，
//     投票事务本身就会重新物化。
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

/**
 * 替换已有封面需要的最少确认票（不同的未隐藏账户）。3：一个人加一两个顺手的小号不够，而「大家都
 * 觉得封面错了」的作品通常不止三个人在架。改它要同步迁移 0014 的部分索引（WHERE votes >= 3），
 * test/cover_guard.test.js 会核对两者一致。
 */
export const COVER_REPLACE_MIN_CONFIRMED = 3;
/** 新候选创建满这么久才能替换已有封面（公示期，给反制留时间）。 */
export const COVER_REPLACE_COOLDOWN_MS = 24 * 60 * 60 * 1000;
/** 管理员清封面后这段时间内，首张封面也要过替换门槛。 */
export const COVER_CLEAR_GUARD_MS = 30 * 24 * 60 * 60 * 1000;
/**
 * 定时重算只看创建时刻落在 (now − 冷却 − 回看, now − 冷却] 的候选（走部分索引）。冷却期内凑够票的
 * 候选在到期后的第一轮就会处理；回看 7 天只为容忍定时任务停摆。更老的待生效候选靠下一次投票重算。
 */
export const COVER_PENDING_LOOKBACK_MS = 7 * 24 * 60 * 60 * 1000;
/** 每轮定时重算最多处理的作品数（免费档 CPU / D1 写入预算）。 */
export const COVER_PENDING_BATCH = 50;

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
 * 本账户在这些作品上的现有投票（workIds = null 取全部）：Map<workId, {candidateId, url, confirmed}>。
 * url 非空 = URL 票；confirmed = 确认票（见文件头）。
 */
export async function accountVotes(db, accountId, workIds) {
  const res = workIds === null
    ? await db.prepare(
      `SELECT v.work_id, v.candidate_id, v.confirmed, c.cover_url FROM cover_votes v
       LEFT JOIN cover_candidates c ON c.id = v.candidate_id WHERE v.account_id = ?1`,
    ).bind(accountId).all()
    : await db.prepare(
      `SELECT v.work_id, v.candidate_id, v.confirmed, c.cover_url FROM cover_votes v
       LEFT JOIN cover_candidates c ON c.id = v.candidate_id
       WHERE v.account_id = ?1 AND v.work_id IN (SELECT value FROM json_each(?2))`,
    ).bind(accountId, JSON.stringify(workIds)).all();
  return new Map(res.results.map((r) => [
    r.work_id, { candidateId: r.candidate_id, url: r.cover_url, confirmed: r.confirmed === 1 },
  ]));
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
 * ops: [{w, from, cid, key, url, confirmed?}]——目标候选按 cid / cover_key / (work, url) 之一定位，
 * 三者全空 = 撤票。确认票：key（上传者）与 url 目标恒为确认票；cid 目标按 op.confirmed（按哈希
 * 投、未比对的是未确认票）。URL 目标不存在时先建零票候选。counted = 账户未隐藏（隐藏账户的票照记、不计数）。
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
      `INSERT INTO cover_votes (work_id, account_id, candidate_id, voted_at, confirmed)
       SELECT ${J('w')}, ?2, (${target}), ?3,
         CASE WHEN ${J('key')} IS NOT NULL OR ${J('url')} IS NOT NULL OR ${J('confirmed')} = 1 THEN 1 END
       FROM json_each(?1)
       WHERE (${target}) IS NOT NULL
       ON CONFLICT (work_id, account_id) DO UPDATE SET
         candidate_id = excluded.candidate_id, voted_at = excluded.voted_at, confirmed = excluded.confirmed`,
    ).bind(opsJson, accountId, now),
  );
  if (counted) {
    stmts.push(db.prepare(
      `UPDATE cover_candidates SET votes = votes + 1, reached_at = ?2
       WHERE id IN (SELECT (${target}) FROM json_each(?1))`,
    ).bind(opsJson, now));
  }
  stmts.push(...settleStatements(db, works, now));
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

/** 现封面候选的票数（没有现封面 / 现封面没有候选时为 0）。w = works 别名。 */
const CURRENT_VOTES = `COALESCE((SELECT MAX(cc.votes) FROM cover_candidates cc WHERE cc.work_id = w.id
  AND (cc.cover_key = w.cover_key OR cc.cover_url = w.cover_url)), 0)`;

/**
 * 候选 alias 的确认票数：未隐藏、注册早于该候选创建的账户投的确认票（走 idx_cover_votes_candidate，
 * 读量 = 该候选的票数）。accounts.created_at 与 cover_candidates.created_at 都是毫秒时刻。
 */
export function confirmedVotesOf(alias) {
  return `(SELECT COUNT(*) FROM cover_votes cv JOIN accounts ca ON ca.id = cv.account_id AND ca.hidden = 0
  WHERE cv.candidate_id = ${alias}.id AND cv.confirmed = 1 AND ca.created_at < ${alias}.created_at)`;
}

/** 候选 c 的确认票数。 */
export const CONFIRMED_VOTES = confirmedVotesOf('c');

/** 现封面候选的确认票数（没有现封面 / 现封面没有候选时为 0）。 */
const CURRENT_CONFIRMED = `COALESCE((SELECT MAX(${confirmedVotesOf('cc')}) FROM cover_candidates cc WHERE cc.work_id = w.id
  AND (cc.cover_key = w.cover_key OR cc.cover_url = w.cover_url)), 0)`;

/** c 是作品 w 的现封面候选。 */
const IS_CURRENT = '(c.cover_key = w.cover_key OR c.cover_url = w.cover_url)';
/**
 * 同一判据的排序键（现封面 1、其余 0）。SQLite 的关联标量子查询里 ORDER BY 引用不到外层的 w
 * （报 no such column），所以按 c.work_id 回查 works，不碰外层别名。
 */
const IS_CURRENT_SORT = `CASE WHEN EXISTS (SELECT 1 FROM works ww WHERE ww.id = c.work_id
  AND (ww.cover_key = c.cover_key OR ww.cover_url = c.cover_url)) THEN 1 ELSE 0 END`;

/**
 * 挑战者 c 是否有资格替换作品 w 的封面（文件头「替换门槛」①②③）。?2 = now − 冷却。
 * votes >= 门槛 是确认票 >= 门槛的必要条件，写在前面让多数候选不必去数确认票。
 */
const REPLACE_ELIGIBLE = `c.votes >= ${COVER_REPLACE_MIN_CONFIRMED} AND c.created_at <= ?2
  AND ${CONFIRMED_VOTES} >= ${COVER_REPLACE_MIN_CONFIRMED}
  AND CASE WHEN ${CURRENT_CONFIRMED} >= ${COVER_REPLACE_MIN_CONFIRMED} THEN c.votes > ${CURRENT_VOTES}
           ELSE ${CONFIRMED_VOTES} > ${CURRENT_CONFIRMED} END`;

/**
 * 物化：把胜出候选写回 works.cover_key / cover_url（规则见文件头）。每部作品在
 * 「现封面候选 ∪ 有资格的挑战者」里取第一个：有资格的挑战者排在现封面前面（比确认票时挑战者的总票数
 * 可能少于被收割撑高的现封面），挑战者之间按 票数↓、reached_at↑、id↑；只剩现封面即不变。
 * 有资格 = 有票且（作品无封面且不在清除保护期，或 REPLACE_ELIGIBLE）。没有任何候选有资格时作品不动。
 */
export function materializeStatement(db, worksJson, now) {
  return db.prepare(
    `UPDATE works SET cover_key = win.cover_key, cover_url = win.cover_url
     FROM (SELECT w.id AS work_id, (
             SELECT c.id FROM cover_candidates c
             WHERE c.work_id = w.id AND (
               ${IS_CURRENT}
               OR (c.votes > 0 AND (
                 (w.cover_key IS NULL AND w.cover_url IS NULL
                   AND (w.cover_cleared_at IS NULL OR w.cover_cleared_at <= ?3))
                 OR (${REPLACE_ELIGIBLE}))))
             ORDER BY ${IS_CURRENT_SORT}, c.votes DESC, c.reached_at ASC, c.id ASC
             LIMIT 1) AS cid
           FROM works w WHERE w.id IN (SELECT value FROM json_each(?1))) AS pick
     JOIN cover_candidates win ON win.id = pick.cid
     WHERE works.id = pick.work_id
       AND (works.cover_key IS NOT win.cover_key OR works.cover_url IS NOT win.cover_url)`,
  ).bind(worksJson, now - COVER_REPLACE_COOLDOWN_MS, now - COVER_CLEAR_GUARD_MS);
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

/** 候选被清理后，指向它的不符记录随之删除（只看这些作品）。 */
export function mismatchCleanupStatement(db, worksJson) {
  return db.prepare(
    `DELETE FROM cover_mismatches WHERE work_id IN (SELECT value FROM json_each(?1))
       AND NOT EXISTS (SELECT 1 FROM cover_candidates c WHERE c.id = cover_mismatches.candidate_id)`,
  ).bind(worksJson);
}

/** 物化 + 清理（候选清理 RETURNING cover_key，见 releasedCoverKeys）+ 不符记录清理。 */
export function settleStatements(db, worksJson, now) {
  return [materializeStatement(db, worksJson, now), cleanupStatement(db, worksJson), mismatchCleanupStatement(db, worksJson)];
}

/**
 * 冷却期内已凑够票、到期后没有新票的挑战者所在的作品（走迁移 0014 的部分索引，读量 = 窗口内
 * 总票数达标的候选数），最多 limit 部。只挑真能替换的（REPLACE_ELIGIBLE），免得达标却输给现封面的
 * 候选每轮都被重算。
 */
export async function pendingCoverWorks(db, now, limit = COVER_PENDING_BATCH) {
  const rows = await db.prepare(
    `SELECT DISTINCT c.work_id AS work_id FROM cover_candidates c JOIN works w ON w.id = c.work_id
     WHERE c.votes >= ${COVER_REPLACE_MIN_CONFIRMED} AND c.created_at > ?1 AND c.created_at <= ?2
       AND COALESCE(c.cover_key = w.cover_key, 0) = 0 AND COALESCE(c.cover_url = w.cover_url, 0) = 0
       AND ${REPLACE_ELIGIBLE}
     LIMIT ?3`,
  ).bind(now - COVER_REPLACE_COOLDOWN_MS - COVER_PENDING_LOOKBACK_MS, now - COVER_REPLACE_COOLDOWN_MS, limit).all();
  return rows.results.map((r) => r.work_id);
}

/**
 * 定时任务：重新物化冷却到期的待生效候选（见 pendingCoverWorks）。返回 {works, released}
 * （released = 被清理候选的 R2 key，调用方删）。物化幂等：与并发投票交错无害，各自在自己的事务里
 * 按当时的票数重算。
 */
export async function settlePendingCovers(db, now, limit = COVER_PENDING_BATCH) {
  const works = await pendingCoverWorks(db, now, limit);
  if (works.length === 0) return { works, released: [] };
  const results = await db.batch(settleStatements(db, JSON.stringify(works), now));
  return { works, released: releasedCoverKeys(results) };
}

/**
 * 管理端：一部作品的全部候选及状态。status：
 *   current（现封面）/ eligible（有资格替换，下一次物化就会生效）/ cooldown（票够了、冷却未满）/
 *   needs_votes（确认票不足或票数不多于现封面）/ first（作品无封面且不在清除保护期，有票即生效）。
 */
export async function workCoverCandidates(db, workId, now) {
  const work = await db.prepare('SELECT id, cover_key, cover_url, cover_cleared_at FROM works WHERE id = ?1')
    .bind(workId).first();
  if (!work) return null;
  const rows = await db.prepare(
    `SELECT c.id, c.phash, c.cover_key, c.cover_url, c.votes, c.reached_at, c.created_at,
       ${CONFIRMED_VOTES} AS confirmed,
       (SELECT COUNT(*) FROM cover_mismatches m WHERE m.candidate_id = c.id) AS mismatches
     FROM cover_candidates c WHERE c.work_id = ?1 ORDER BY c.votes DESC, c.reached_at ASC, c.id ASC`,
  ).bind(workId).all();
  const isCurrent = (c) => (c.cover_key !== null && c.cover_key === work.cover_key)
    || (c.cover_url !== null && c.cover_url === work.cover_url);
  const current = rows.results.find(isCurrent);
  const currentVotes = current ? current.votes : 0;
  const currentConfirmed = current ? current.confirmed : 0;
  const beatsCurrent = (c) => (currentConfirmed >= COVER_REPLACE_MIN_CONFIRMED
    ? c.votes > currentVotes : c.confirmed > currentConfirmed);
  const empty = work.cover_key === null && work.cover_url === null;
  const guarded = work.cover_cleared_at !== null && work.cover_cleared_at > now - COVER_CLEAR_GUARD_MS;
  const candidates = rows.results.map((c) => {
    let status;
    if (isCurrent(c)) status = 'current';
    else if (empty && !guarded) status = 'first';
    else if (c.confirmed < COVER_REPLACE_MIN_CONFIRMED || !beatsCurrent(c)) status = 'needs_votes';
    else if (c.created_at > now - COVER_REPLACE_COOLDOWN_MS) status = 'cooldown';
    else status = 'eligible';
    return {
      id: c.id,
      cover: c.cover_url || `/img/${c.cover_key}`,
      phash: c.phash,
      votes: c.votes,
      confirmed: c.confirmed,
      mismatches: c.mismatches,
      createdAt: c.created_at,
      eligibleAt: status === 'cooldown' ? c.created_at + COVER_REPLACE_COOLDOWN_MS : null,
      status,
    };
  });
  return { workId, clearedAt: work.cover_cleared_at, guardUntil: guarded ? work.cover_cleared_at + COVER_CLEAR_GUARD_MS : null, candidates };
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
      `DELETE FROM cover_mismatches WHERE work_id IN (SELECT value FROM json_each(?1))
         AND NOT EXISTS (SELECT 1 FROM shelf s WHERE s.work_id = cover_mismatches.work_id)`,
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

/**
 * 解析投票请求体：{hash} | {url}，hash 票可再带一个动作（至多一个）：
 *   check: true   只查哈希命中哪个候选（不投票），新客户端拿去在本机比对；
 *   confirm: cid  本机比对通过，投确认票给 cid；
 *   mismatch: cid 本机比对不通过，记不符、撤掉投给 cid 的票，再查下一个候选。
 */
export function requireOneOf(body) {
  const hash = body && body.hash !== undefined ? normalizeCoverHash(body.hash) : null;
  const url = body && body.url !== undefined ? body.url : null;
  if (body && body.hash !== undefined && !hash) throw new HttpError(400, 'bad_cover_hash');
  if ((hash === null) === (url === null)) throw new HttpError(400, 'bad_cover_vote');
  const cid = (v) => {
    if (v === undefined) return null;
    if (!Number.isSafeInteger(v) || v <= 0) throw new HttpError(400, 'bad_cover_vote');
    return v;
  };
  const check = body.check === true;
  const confirm = cid(body.confirm);
  const mismatch = cid(body.mismatch);
  if ((check ? 1 : 0) + (confirm !== null ? 1 : 0) + (mismatch !== null ? 1 : 0) > 1) {
    throw new HttpError(400, 'bad_cover_vote');
  }
  if (url !== null && (check || confirm !== null || mismatch !== null)) throw new HttpError(400, 'bad_cover_vote');
  return { hash, url, check, confirm, mismatch };
}
