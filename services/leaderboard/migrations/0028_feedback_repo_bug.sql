-- 仓库 BUG 同步进反馈（2026-11-27；src/feedback_repo_bugs.js，CI tool/bug_feedback_sync.mjs）。
--
-- docs/bugs/BUG-NNNN*.md 里「① 未修复」的条目由 develop 的 push CI 按 BUG 号幂等地建成一条反馈：
--   repo_bug       BUG 号（整数）；NULL = 普通用户反馈。同一个号最多一条（部分唯一索引）
--   repo_bug_hash  上次同步进来的「标题 + 正文」SHA-256（CI 脚本算），没变就不再写
-- 这类反馈没有反馈人（account_id NULL，ticket 是丢弃的随机串），只在开发者处理台 / 开发者视图里出现。
--
-- 纯增量、可空：旧 Worker 在线时先执行也安全（旧代码不读不写这两列）。
ALTER TABLE feedback ADD COLUMN repo_bug INTEGER;
ALTER TABLE feedback ADD COLUMN repo_bug_hash TEXT;
CREATE UNIQUE INDEX IF NOT EXISTS idx_feedback_repo_bug ON feedback (repo_bug) WHERE repo_bug IS NOT NULL;
