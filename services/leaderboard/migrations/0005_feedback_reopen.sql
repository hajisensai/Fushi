-- 反馈人「问题没解决，重新提交」：新反馈指向原反馈（docs/specs/2026-10-08-feedback.md「重新提交」）。
--   parent_id  原反馈 id；只能凭原反馈的 ticket 写入，且原反馈须已结案
ALTER TABLE feedback ADD COLUMN parent_id TEXT;
CREATE INDEX IF NOT EXISTS idx_feedback_parent ON feedback (parent_id, created_at, id) WHERE parent_id IS NOT NULL;
