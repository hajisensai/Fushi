-- 封面替换门槛 + 确认票（2026-10-17，src/cover_votes.js 文件头「替换门槛」「确认票」）。
--
-- 纯增量，可以在旧 Worker 在线时先跑：旧代码不读新列 / 新表、不依赖新索引。
--
-- cover_votes.confirmed：1 = 确认票（上传者 / URL 票 / 新客户端本机强比对通过），NULL = 未确认
--   （旧客户端按哈希投的票）。替换已有封面的门槛只数确认票。
ALTER TABLE cover_votes ADD COLUMN confirmed INTEGER;
-- 存量 URL 票本来就是「URL 相等 = 同一张图」，直接记为确认票。存量缩略图票分不清是上传者还是按
-- 哈希命中的，一律留作未确认（新客户端升级后会对已投的作品补一次本机比对并确认）。
UPDATE cover_votes SET confirmed = 1
WHERE candidate_id IN (SELECT id FROM cover_candidates WHERE cover_url IS NOT NULL);

-- works.cover_cleared_at：管理员最近一次清封面的时刻（毫秒）。COVER_CLEAR_GUARD_MS 内首张封面
--   也要过替换门槛，免得攻击者在清掉的瞬间再抢首张。
ALTER TABLE works ADD COLUMN cover_cleared_at INTEGER;

-- 不符记录：新客户端本机比对认定某候选不是它手里那张图。不计票、不影响排名；之后按哈希查找时对
-- 该账户跳过这个候选；处理台据此看哪些候选被多人判不符。候选清理时随之删除。
CREATE TABLE IF NOT EXISTS cover_mismatches (
  work_id      TEXT NOT NULL,
  candidate_id INTEGER NOT NULL,
  account_id   TEXT NOT NULL,
  at           INTEGER NOT NULL,
  PRIMARY KEY (candidate_id, account_id)
);
CREATE INDEX IF NOT EXISTS idx_cover_mismatches_work ON cover_mismatches (work_id);
CREATE INDEX IF NOT EXISTS idx_cover_mismatches_account ON cover_mismatches (account_id);

-- 定时任务找「冷却期刚到期、票数已达标」的候选（settlePendingCovers）：按创建时刻取窗口，只索引
-- 总票数达标的候选。WHERE 里的 3 必须等于 COVER_REPLACE_MIN_CONFIRMED（查询里同样写成字面量，
-- SQLite 才会用这个部分索引；test/cover_guard.test.js 核对两者一致）。
CREATE INDEX IF NOT EXISTS idx_cover_candidates_pending ON cover_candidates (created_at) WHERE votes >= 3;
