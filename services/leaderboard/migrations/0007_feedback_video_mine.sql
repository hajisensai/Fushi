-- 反馈视频附件 + 跨设备看自己的工单（docs/specs/2026-10-08-feedback.md「视频附件」「我的反馈」）。
--
-- ⚠️ 先迁移再部署：新代码的视频上传 / 到期清理写 has_video、「我的反馈」按新索引读；
-- 没迁移就部署时 PUT .../attachments/v0、GET /v1/feedback/mine 与定时清理会 500。
-- 迁移只加列和索引，先迁移、旧代码照跑不受影响。
--
--   has_video  1 = attachments 里有视频条目（槽位 v0，≤ 50 MB）。视频比截图大两个数量级，
--              到期清理要按「创建 30 天 / 结案 7 天」先到者单独清；这一列配部分索引，
--              定时任务只读带视频的行（有界读），不扫整张反馈表。
ALTER TABLE feedback ADD COLUMN has_video INTEGER NOT NULL DEFAULT 0;
CREATE INDEX IF NOT EXISTS idx_feedback_video ON feedback (created_at) WHERE has_video = 1;

-- GET /v1/feedback/mine：签名账户按创建时间倒序翻自己的反馈（游标 `<created_at>:<id>`），
-- 每页只读 limit+1 行、不建临时 B 树。只索引有账户的行（匿名提交 account_id 为 NULL）。
CREATE INDEX IF NOT EXISTS idx_feedback_account_created
  ON feedback (account_id, created_at DESC, id DESC) WHERE account_id IS NOT NULL;
