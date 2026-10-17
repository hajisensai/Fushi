-- 反馈回复的 APNs 推送令牌（2026-10-13，src/feedback_push.js）。
--
-- 反馈人凭本条 ticket 登记 / 注销 iOS 设备令牌；开发者回复或改状态后服务端给这些令牌发
-- 一条通用文案的推送（不带回复正文）。一条反馈最多 PUSH_LIMITS.tokensPerFeedback 个令牌，
-- 主键按令牌 SHA-256 去重；反馈结案（开发者结案 / 反馈人标记完成）或 APNs 回 410 /
-- BadDeviceToken 时删掉。
--   token：发送要用原文（APNs 只认原令牌），只出现在发往 Apple 的请求路径里，任何接口都不回传。
--   lang：通知文案语言（客户端登记时报的界面语言，归一成 zh / zh-Hant / ja / ko / en）。
--
-- 编号说明：原名 0008_feedback_push_tokens.sql，与同期合入的 0008_media_video_pool.sql 撞号，
-- 改到 0010（接在 0009_feedback_release.sql 后面）。本迁移只建表 / 建索引且全部 IF NOT EXISTS，
-- 已经按旧名应用过的库再按新名应用一次是空操作。
CREATE TABLE IF NOT EXISTS feedback_push_tokens (
  feedback_id TEXT NOT NULL,
  token_hash  TEXT NOT NULL,
  token       TEXT NOT NULL,
  lang        TEXT NOT NULL DEFAULT 'en',
  created_at  INTEGER NOT NULL,
  updated_at  INTEGER NOT NULL,
  PRIMARY KEY (feedback_id, token_hash)
);
-- APNs 报令牌失效时按令牌清掉它在所有反馈下的登记。
CREATE INDEX IF NOT EXISTS idx_feedback_push_tokens_hash ON feedback_push_tokens (token_hash);
