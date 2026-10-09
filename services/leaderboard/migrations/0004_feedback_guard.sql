-- 反馈防投毒（docs/specs/2026-10-08-feedback.md「防投毒」）。
--   flags         风险标记 JSON 数组：hidden_chars / injection / links / duplicate:<id>
--   content_hash  hex(sha256(规范化标题 + 正文))：跨来源的同内容灌水打 duplicate 标记
--   origin        服务端自己记录的来源（国家 / UA / 是否签名），与客户端自报的 meta 分开展示
--   message_count 反馈人追加说明的累计条数（单条反馈的消息总数上限）
ALTER TABLE feedback ADD COLUMN flags TEXT NOT NULL DEFAULT '[]';
ALTER TABLE feedback ADD COLUMN content_hash TEXT;
ALTER TABLE feedback ADD COLUMN origin TEXT NOT NULL DEFAULT '{}';
ALTER TABLE feedback ADD COLUMN message_count INTEGER NOT NULL DEFAULT 0;
CREATE INDEX IF NOT EXISTS idx_feedback_content ON feedback (content_hash, created_at) WHERE content_hash IS NOT NULL;
