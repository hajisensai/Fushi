-- Fushi 排行榜 / 公开书架 D1 schema（设计见 docs/specs/2026-09-28-leaderboard-accounts.md）。
-- 部署：wrangler d1 migrations apply fushi-leaderboard --remote

-- 账户 = 设备公钥。id = base64url(sha256(spki))[0..16]，同时是好友码。
CREATE TABLE IF NOT EXISTS accounts (
  id             TEXT PRIMARY KEY,
  pubkey         TEXT NOT NULL UNIQUE,   -- base64url(SPKI DER)，ECDSA P-256
  nickname       TEXT NOT NULL,
  discriminator  INTEGER NOT NULL,       -- 0..9999，与 nickname 组合唯一
  avatar_key     TEXT,                   -- R2 key；NULL = 无头像
  visibility     TEXT NOT NULL DEFAULT 'public' CHECK (visibility IN ('public', 'friends')),
  hidden         INTEGER NOT NULL DEFAULT 0,  -- 管理员隐藏：不进任何榜、主页 404
  last_seen_time INTEGER NOT NULL DEFAULT 0,  -- 已接受的最大签名时刻（ms），防重放
  created_at     INTEGER NOT NULL,
  UNIQUE (nickname, discriminator)
);

-- 跨用户作品。展示字段由 shelf 上报众数回写（见 shelf.js recomputeWorkMeta）。
CREATE TABLE IF NOT EXISTS works (
  id         TEXT PRIMARY KEY,
  kind       TEXT NOT NULL CHECK (kind IN ('book', 'manga', 'video', 'game')),
  title      TEXT NOT NULL,
  author     TEXT NOT NULL DEFAULT '',
  cover_url  TEXT,                       -- 白名单主机的远端封面
  cover_key  TEXT,                       -- R2 上传缩略图
  nsfw       INTEGER NOT NULL DEFAULT 0, -- 1 = 封面模糊展示
  locked     INTEGER NOT NULL DEFAULT 0, -- 1 = 管理员改过标题/作者，不再按众数回写
  created_at INTEGER NOT NULL
);

-- 作品别名：一个作品可有多个跨用户匹配键（bgm:/isbn:/vndb:/tmdb:/anidb:/src:/t:）。
-- ref 统一存成 '<kind>|<键>'：同一个键在不同 kind 下永远是不同作品（书与漫画同名不串）。
CREATE TABLE IF NOT EXISTS work_aliases (
  ref     TEXT PRIMARY KEY,
  work_id TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_work_aliases_work ON work_aliases (work_id);

-- 公开书架。整份上报、整份替换。finished_date = 客户端本地日 'YYYY-MM-DD'，切周/月窗用。
CREATE TABLE IF NOT EXISTS shelf (
  account_id    TEXT NOT NULL,
  work_id       TEXT NOT NULL,
  refs          TEXT NOT NULL,           -- 该用户上报的全部匹配键（JSON 数组，已带 kind| 前缀）；管理员拆分作品时据此重新归属
  title         TEXT NOT NULL,           -- 该用户上报的标题（作品众数的输入）
  author        TEXT NOT NULL DEFAULT '',
  finished_at   INTEGER,                 -- ms；NULL = 在读
  finished_date TEXT,
  chars         INTEGER NOT NULL DEFAULT 0,
  ms            INTEGER NOT NULL DEFAULT 0,
  updated_at    INTEGER NOT NULL,
  PRIMARY KEY (account_id, work_id)
);
CREATE INDEX IF NOT EXISTS idx_shelf_work ON shelf (work_id, finished_at);
CREATE INDEX IF NOT EXISTS idx_shelf_account_finished ON shelf (account_id, finished_at DESC);
CREATE INDEX IF NOT EXISTS idx_shelf_finished_date ON shelf (finished_date);

-- 按天字数（字数榜周/月切窗）。
CREATE TABLE IF NOT EXISTS daily_chars (
  account_id TEXT NOT NULL,
  date_key   TEXT NOT NULL,
  chars      INTEGER NOT NULL,
  PRIMARY KEY (account_id, date_key)
);
CREATE INDEX IF NOT EXISTS idx_daily_chars_date ON daily_chars (date_key);

-- 好友（P5 使用；有序对 a<b，requester 记发起方）。
CREATE TABLE IF NOT EXISTS friends (
  a          TEXT NOT NULL,
  b          TEXT NOT NULL,
  requester  TEXT NOT NULL,
  state      TEXT NOT NULL CHECK (state IN ('pending', 'accepted')),
  created_at INTEGER NOT NULL,
  PRIMARY KEY (a, b)
);
CREATE INDEX IF NOT EXISTS idx_friends_b ON friends (b);

CREATE TABLE IF NOT EXISTS blocks (
  account_id TEXT NOT NULL,
  blocked_id TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  PRIMARY KEY (account_id, blocked_id)
);

CREATE TABLE IF NOT EXISTS reports (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  reporter    TEXT NOT NULL,
  target_kind TEXT NOT NULL CHECK (target_kind IN ('account', 'work')),
  target_id   TEXT NOT NULL,
  reason      TEXT NOT NULL DEFAULT '',
  created_at  INTEGER NOT NULL,
  resolved    INTEGER NOT NULL DEFAULT 0
);

-- 固定窗口限流计数（注册按 IP、上传按账户）。
CREATE TABLE IF NOT EXISTS rate_limits (
  bucket       TEXT NOT NULL,
  window_start INTEGER NOT NULL,
  count        INTEGER NOT NULL,
  PRIMARY KEY (bucket, window_start)
);
