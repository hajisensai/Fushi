-- 用户反馈与开发者处理台（设计见 docs/specs/2026-10-08-feedback.md）。
--
-- 反馈不要求账户：提交时服务端发一张一次性展示的「回执」（ticket），只存它的 SHA-256；
-- App 本地保存 id + ticket，凭它看进度、追加回复、补传附件。带签名提交时另记 account_id，
-- 开发者能看到反馈人昵称。附件（截图 / 压缩日志）进 R2，与头像 / 封面共用 8 GiB 配额。

-- 账户角色：'dev' = 开发者，可在 App 与网页处理台查看、处理反馈。只有管理员能改
-- （POST /admin/api/accounts/:id/role）。
ALTER TABLE accounts ADD COLUMN role TEXT NOT NULL DEFAULT 'user';

CREATE TABLE IF NOT EXISTS feedback (
  id             TEXT PRIMARY KEY,
  ticket_hash    TEXT NOT NULL,             -- hex(sha256(ticket))
  account_id     TEXT,                      -- 带签名提交时的账户；匿名 NULL
  category       TEXT NOT NULL CHECK (category IN ('bug', 'suggestion', 'other')),
  title          TEXT NOT NULL,
  body           TEXT NOT NULL,
  contact        TEXT NOT NULL DEFAULT '',  -- 用户自愿留的联系方式（只有开发者看得到）
  status         TEXT NOT NULL DEFAULT 'open'
                 CHECK (status IN ('open', 'in_progress', 'resolved', 'wont_fix', 'duplicate', 'closed')),
  meta           TEXT NOT NULL DEFAULT '{}', -- 设备 / 版本信息（JSON，客户端上报，≤ 4KB）
  attachments    TEXT NOT NULL DEFAULT '[]', -- [{slot, kind, key, bytes, type}]，见 feedback.js
  created_at     INTEGER NOT NULL,
  updated_at     INTEGER NOT NULL,          -- 任何变化（状态 / 回复 / 附件）都刷新
  dev_reply_at   INTEGER,                   -- 开发者最近一次回复或改状态（客户端「有新进展」红点）
  user_reply_at  INTEGER                    -- 反馈人最近一次追加回复（处理台「有新消息」）
);
CREATE INDEX IF NOT EXISTS idx_feedback_updated ON feedback (updated_at DESC, id DESC);
CREATE INDEX IF NOT EXISTS idx_feedback_status ON feedback (status, updated_at DESC, id DESC);
-- 删账户时断开关联用（只索引有账户的行）。
CREATE INDEX IF NOT EXISTS idx_feedback_account ON feedback (account_id) WHERE account_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS feedback_messages (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  feedback_id TEXT NOT NULL,
  author      TEXT NOT NULL CHECK (author IN ('user', 'dev')),
  account_id  TEXT,                         -- 开发者回复时的账户（展示昵称）
  body        TEXT NOT NULL DEFAULT '',
  status      TEXT,                         -- 开发者改状态时记下新状态（时间线展示）；NULL = 纯回复
  created_at  INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_feedback_messages_feedback ON feedback_messages (feedback_id, id);

-- 网页处理台登录会话（HttpOnly Cookie；只存 token 的 SHA-256）。
CREATE TABLE IF NOT EXISTS dev_sessions (
  token_hash TEXT PRIMARY KEY,
  account_id TEXT NOT NULL,
  expires_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_dev_sessions_expires ON dev_sessions (expires_at);
