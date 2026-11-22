-- 拍板台个人密钥（2026-11-21，src/decisions_api.js；处理台 /dev/keys，CLI scripts/decisions.mjs 的 HTTP 模式）：
-- 每个开发者在处理台给自己签发密钥，代理带 `Authorization: Bearer fdk_…` 调 /v1/decisions/**，
-- 只能读写拍板台，不需要 Cloudflare 凭据。
--
--   decision_api_keys  一把密钥。库里只存 token 的 SHA-256；明文只在签发时显示一次。
--                      revoked_at 非空 = 已吊销；账户被撤开发者（role ≠ dev）后密钥同样失效（鉴权时核对 role）。
--
-- 纯新表，旧 Worker 不读它；写入量极小（人工签发 / 吊销 + 最多每 10 分钟一次的 last_used_at）。
CREATE TABLE decision_api_keys (
  id TEXT PRIMARY KEY,
  account_id TEXT NOT NULL,
  token_hash TEXT NOT NULL UNIQUE,
  hint TEXT NOT NULL,
  label TEXT,
  created_at INTEGER NOT NULL,
  last_used_at INTEGER,
  revoked_at INTEGER
);

CREATE INDEX decision_api_keys_account ON decision_api_keys (account_id, created_at);
