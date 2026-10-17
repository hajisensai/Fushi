-- 反馈「修复 → 打包 → 发布」追踪（2026-10-13）：状态挂在修复 commit 上，不挂在某次 CI run 上
-- （develop 的发布 run 会被后来的 run 取消，但后来的 run 一定包含该 commit）。
--   fix_sha    修复 commit（40 位小写 hex）；NULL = 未标记修复
--   fix_scope  'app'（要新 App 才生效）| 'none'（不需要更新 App，例如只改服务端）
--   fix_at     标记修复的时刻（毫秒）
--   fixed_in   哪个通道 / 平台的哪个版本已包含修复（发布 workflow 回填，只记最早的那个版本）：
--              {"<channel>": {"<platform>": {"version": "<build-name>", "at": <ms>}}}
--              channel ∈ debug | beta | stable；platform ∈ android | windows | macos | ios | linux
-- 写入口：POST /v1/ci/feedback/fixed、/v1/ci/feedback/released（feedback.js），
-- 手动兜底 scripts/feedback.mjs fixed。重新标记修复会把 fixed_in 重置为 '{}'。
-- 回填 fixed_in 不是开发者回复：released 只写 fixed_in，不动 dev_reply_at / updated_at。
-- 编号 0009：0007 / 0008 已被反馈视频附件（has_video、media_usage.video_bytes）占用；本迁移只加
-- fix_* / fixed_in 列与 idx_feedback_fix 部分索引，与它们不重名。
ALTER TABLE feedback ADD COLUMN fix_sha TEXT;
ALTER TABLE feedback ADD COLUMN fix_scope TEXT;
ALTER TABLE feedback ADD COLUMN fix_at INTEGER;
ALTER TABLE feedback ADD COLUMN fixed_in TEXT NOT NULL DEFAULT '{}';
-- GET /v1/ci/feedback/pending：只扫 180 天内标记过「需要新 App」修复的行。
CREATE INDEX IF NOT EXISTS idx_feedback_fix ON feedback (fix_at) WHERE fix_sha IS NOT NULL AND fix_scope = 'app';
