-- 拍板台附件公开分享链接（2026-11-24，src/decisions.js；处理台附件旁「分享 / 撤销分享」，
-- CLI scripts/decisions.mjs share / unshare）：
-- 开发者给某个附件签发一个只读公开链接 GET /share/f/<token>，不登录也能看；撤销后链接立刻 404。
--
--   decision_file_shares  一条分享。按 (decision_id, file_key) 定位附件（file_key = files 列里条目的 R2 key，
--                         带随机前缀、不会复用），附件被删 / 事项被换掉附件后链接自然失效。
--                         token 存明文：链接本身就是要给出去的东西，处理台随时要能再复制；它只授权读这一个附件。
--                         created_by = 签发的开发者；账户被撤开发者（role ≠ dev）后他签的链接同样失效。
--                         revoked_at 非空 = 已撤销。同一附件同时最多一条未撤销的（部分唯一索引）。
--
-- 纯新表，旧 Worker 不读它；写入量极小（人工分享 / 撤销）。
CREATE TABLE decision_file_shares (
  token TEXT PRIMARY KEY,
  decision_id TEXT NOT NULL,
  file_key TEXT NOT NULL,
  created_by TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  revoked_at INTEGER
);

CREATE UNIQUE INDEX decision_file_shares_active ON decision_file_shares (decision_id, file_key) WHERE revoked_at IS NULL;
