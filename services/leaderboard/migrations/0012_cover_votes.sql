-- 作品封面按人数投票（2026-10-16，src/cover_votes.js）。
--
-- 之前：works.cover_key / cover_url 先到先得，第一个人传的封面永远是这部作品的封面，
-- 别人本地更正了刮削也换不掉。现在：同一作品不同账户提交的封面是「候选」，一账户对一作品
-- 一票，作品封面 = 票数最多的候选；works.cover_key / cover_url 仍是物化结果（读路径不变）。
--
-- cover_candidates：一部作品的一张候选封面。三种来源：
--   - 上传的缩略图：phash = 服务端从上传字节算的 64 位 dHash（16 位小写 hex，src/cover_hash.js；
--     客户端上报的哈希只用来核对、从不入库），cover_key = R2 key；
--     服务端按汉明距离 ≤ COVER_HASH_MAX_DISTANCE 把相近的图归为同一候选，同一候选只存一份 R2 图；
--   - 白名单图床 URL（书架上报带的 coverUrl / 投票接口带的 url）：cover_url，无 phash，按 URL 相等归并；
--   - 本迁移回填的存量封面：phash 为 NULL，不参与哈希归并。
--   votes：未隐藏账户的票数（增量维护；管理操作精确重算）。
--   reached_at：票数最近一次上涨的时刻。平票时取 reached_at 最早的（「最早达到该票数」），
--     再平取 id 小的（先提交的）。掉票不改 reached_at。
--   没有任何投票行、且不是作品当前封面的候选随即删除，R2 对象一并删除并归还配额。
CREATE TABLE IF NOT EXISTS cover_candidates (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  work_id    TEXT NOT NULL,
  phash      TEXT,
  cover_key  TEXT,
  cover_url  TEXT,
  votes      INTEGER NOT NULL DEFAULT 0,
  reached_at INTEGER NOT NULL,
  created_at INTEGER NOT NULL,
  CHECK ((cover_key IS NULL) != (cover_url IS NULL))
);
CREATE INDEX IF NOT EXISTS idx_cover_candidates_work ON cover_candidates (work_id);
CREATE UNIQUE INDEX IF NOT EXISTS idx_cover_candidates_url ON cover_candidates (work_id, cover_url)
  WHERE cover_url IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS idx_cover_candidates_key ON cover_candidates (cover_key)
  WHERE cover_key IS NOT NULL;

-- 一账户对一作品一票；改投即改 candidate_id（移票）。只有书架上有该作品的账户能投，
-- 作品从其书架消失（下架 / 删号 / 拆分迁走）时票随之删除。
CREATE TABLE IF NOT EXISTS cover_votes (
  work_id      TEXT NOT NULL,
  account_id   TEXT NOT NULL,
  candidate_id INTEGER NOT NULL,
  voted_at     INTEGER NOT NULL,
  PRIMARY KEY (work_id, account_id)
);
CREATE INDEX IF NOT EXISTS idx_cover_votes_account ON cover_votes (account_id);
CREATE INDEX IF NOT EXISTS idx_cover_votes_candidate ON cover_votes (candidate_id);

-- 回填：存量封面成为零票候选（不知道当初是谁传的，不记票）。在有人投票之前作品封面不变；
-- 一旦别的候选得票，零票的存量候选随即被替换并清理。cover_key / cover_url 都有的作品
-- （管理合并的历史产物）两个各建一个候选，免得 R2 对象失去引用后无人回收。
INSERT INTO cover_candidates (work_id, cover_key, votes, reached_at, created_at)
SELECT id, cover_key, 0, created_at, created_at FROM works
WHERE cover_key IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM cover_candidates c WHERE c.cover_key = works.cover_key);
INSERT INTO cover_candidates (work_id, cover_url, votes, reached_at, created_at)
SELECT id, cover_url, 0, created_at, created_at FROM works
WHERE cover_url IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM cover_candidates c WHERE c.work_id = works.id AND c.cover_url = works.cover_url);
