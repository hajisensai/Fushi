-- 反馈密钥（2026-11-26，src/feedback_api.js；处理台 /dev/keys）：开发者与反馈协查（triage）给自己的 AI 代理签发，
-- 代理带 `Authorization: Bearer ffk_…` 调 /v1/agent/feedback/**：只读反馈 + 写内部批改，不能回复反馈人 / 改状态，
-- 也碰不到拍板台（拍板台密钥是另一张表 decision_api_keys，两种互不通用）。
--
--   feedback_api_keys  一把密钥。表结构与 decision_api_keys 相同（src/api_keys.js 共用存取）：库里只存 token 的 SHA-256，
--                      明文只在签发时显示一次；revoked_at 非空 = 已吊销；账户角色不再是 dev / triage 后密钥同样失效
--                      （鉴权时核对 role）。
--
-- 纯新表，旧 Worker 不读它；写入量极小（人工签发 / 吊销 + 最多每 10 分钟一次的 last_used_at）。
CREATE TABLE feedback_api_keys (
  id TEXT PRIMARY KEY,
  account_id TEXT NOT NULL,
  token_hash TEXT NOT NULL UNIQUE,
  hint TEXT NOT NULL,
  label TEXT,
  created_at INTEGER NOT NULL,
  last_used_at INTEGER,
  revoked_at INTEGER
);

CREATE INDEX feedback_api_keys_account ON feedback_api_keys (account_id, created_at);
