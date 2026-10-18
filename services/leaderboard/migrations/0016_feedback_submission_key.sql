-- 反馈提交幂等（2026-10-17，BUG-3489 审查；src/feedback.js createFeedback）。
--
-- 客户端为每一次提交生成随机幂等键 submissionKey，重试复用同一个；这里只存它的 SHA-256
-- （带域分隔前缀，与 ticket 哈希不可互换）。同键再来一次 → 原样回同一张回执，不新建反馈。
-- 唯一索引兜住同键并发：后到的 INSERT 撞约束后改按重放返回。
--
-- 纯增量、可空：旧 Worker 仍在线时先执行也安全（旧代码的 INSERT 不提这一列，落 NULL；部分索引
-- 不收 NULL）。先跑迁移、再部署新 Worker。
ALTER TABLE feedback ADD COLUMN submission_hash TEXT;
CREATE UNIQUE INDEX IF NOT EXISTS idx_feedback_submission ON feedback (submission_hash) WHERE submission_hash IS NOT NULL;
