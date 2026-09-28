-- Fushi 排行榜 / 公开书架 D1 schema（设计见 docs/specs/2026-09-28-leaderboard-accounts.md）。
-- 部署：wrangler d1 migrations apply fushi-leaderboard --remote
--
-- 成本模型（Cloudflare D1 按读/写行数计量）：任何请求的读写行数都必须有界、与总用户数无关。
-- 所以榜单不现场扫描，而是读定时生成的快照（rank_snapshots / popular_snapshots）；
-- 计数一律增量维护（accounts.shelf_count、works.readers、stat_days、account_totals）；
-- 上传是增量协议（每批 ≤ 500 条）。全局日预算见 budgets。

-- 账户：经邮箱验证码注册。id = 注册时那把设备钥匙的 key_id，同时是好友码。
-- 邮箱只存 HMAC（email_hash），不存明文（见 src/email.js）。
CREATE TABLE IF NOT EXISTS accounts (
  id             TEXT PRIMARY KEY,
  email_hash     TEXT NOT NULL UNIQUE,
  nickname       TEXT NOT NULL,
  discriminator  INTEGER NOT NULL,       -- 0..9999，与 nickname 组合唯一
  avatar_key     TEXT,                   -- R2 key；NULL = 无头像
  visibility     TEXT NOT NULL DEFAULT 'public' CHECK (visibility IN ('public', 'friends')),
  hidden         INTEGER NOT NULL DEFAULT 0,  -- 管理员隐藏：不进任何榜、主页 404
  shelf_count    INTEGER NOT NULL DEFAULT 0,  -- 书架行数（增量维护，上限检查与客户端对账用）
  shelf_rev      INTEGER NOT NULL DEFAULT 0,  -- 书架版本（乐观锁）：每次改动本账户书架 / 计数的事务都 CAS 递增
  upload_key     TEXT,                        -- 唯一的「上传设备」钥匙 id；多设备共用账户时只有它能上报书架
  created_at     INTEGER NOT NULL,
  UNIQUE (nickname, discriminator)
);

-- 设备钥匙：一个账户可绑多台设备（新设备用邮箱验证码登录时绑定，上限 10）。
-- key_id = base64url(sha256(spki))[0..16]，即请求头 X-Fushi-Account。
CREATE TABLE IF NOT EXISTS device_keys (
  key_id     TEXT PRIMARY KEY,
  account_id TEXT NOT NULL,
  pubkey     TEXT NOT NULL,                -- base64url(SPKI DER)，ECDSA P-256
  created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_device_keys_account ON device_keys (account_id);

-- 待验证的邮箱验证码（只存 HMAC；10 分钟过期；最多 5 次尝试）。
CREATE TABLE IF NOT EXISTS email_codes (
  email_hash TEXT NOT NULL,
  purpose    TEXT NOT NULL CHECK (purpose IN ('register', 'login')),
  code_hash  TEXT NOT NULL,
  expires_at INTEGER NOT NULL,
  attempts   INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (email_hash, purpose)
);
CREATE INDEX IF NOT EXISTS idx_email_codes_expires ON email_codes (expires_at);

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
  readers    INTEGER NOT NULL DEFAULT 0, -- 读完它的未隐藏账户数（增量维护，不现场 COUNT）
  created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_works_readers ON works (readers DESC);

-- 作品别名：一个作品可有多个跨用户匹配键（bgm:/isbn:/vndb:/tmdb:/anidb:/src:/t:）。
-- ref 统一存成 '<kind>|<键>'：同一个键在不同 kind 下永远是不同作品（书与漫画同名不串）。
CREATE TABLE IF NOT EXISTS work_aliases (
  ref     TEXT PRIMARY KEY,
  work_id TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_work_aliases_work ON work_aliases (work_id);

-- 公开书架（增量上报）。finished_date = 客户端本地日 'YYYY-MM-DD'；finished_at = 0 表示读完但日期未知。
CREATE TABLE IF NOT EXISTS shelf (
  account_id    TEXT NOT NULL,
  work_id       TEXT NOT NULL,
  kind          TEXT NOT NULL,           -- 冗余自 works.kind：按类筛选的书架分页要走索引
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
-- 索引与游标分页的排序逐列对齐（ORDER BY 不许出现临时 B 树）；每个索引都按行计写入，只留必要的。
CREATE INDEX IF NOT EXISTS idx_shelf_work ON shelf (work_id, finished_at DESC, account_id DESC);
CREATE INDEX IF NOT EXISTS idx_shelf_account_finished ON shelf (account_id, finished_at DESC, work_id DESC);
CREATE INDEX IF NOT EXISTS idx_shelf_account_kind ON shelf (account_id, kind, finished_at DESC, work_id DESC);

-- 乐观锁守卫：从不存行。CAS 语句在版本不符时向它插 NULL，NOT NULL 约束让整个 batch 回滚。
CREATE TABLE IF NOT EXISTS cas_guard (
  ok INTEGER NOT NULL
);

-- 每账户每天的计分：各类读完数（已按每日 30 部上限截断）+ 当天字数。周/月榜只扫这张表的窗口段。
CREATE TABLE IF NOT EXISTS stat_days (
  account_id TEXT NOT NULL,
  date_key   TEXT NOT NULL,
  book       INTEGER NOT NULL DEFAULT 0,
  manga      INTEGER NOT NULL DEFAULT 0,
  video      INTEGER NOT NULL DEFAULT 0,
  game       INTEGER NOT NULL DEFAULT 0,
  chars      INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (account_id, date_key)
);

-- 每账户总计（总榜与用户卡片）：stat_days 之和 + 日期未知的读完（各计 1）。
CREATE TABLE IF NOT EXISTS account_totals (
  account_id TEXT PRIMARY KEY,
  book       INTEGER NOT NULL DEFAULT 0,
  manga      INTEGER NOT NULL DEFAULT 0,
  video      INTEGER NOT NULL DEFAULT 0,
  game       INTEGER NOT NULL DEFAULT 0,
  chars      INTEGER NOT NULL DEFAULT 0
);

-- 每账户每周期计分（周 'w:<周一>'、月 'm:<YYYY-MM>'）：由 stat_days 按受影响周期增量重算。
-- 周/月榜快照只读当期这一段，读量 = 当期活跃账户数，不扫历史。
CREATE TABLE IF NOT EXISTS account_periods (
  period     TEXT NOT NULL,
  account_id TEXT NOT NULL,
  book       INTEGER NOT NULL DEFAULT 0,
  manga      INTEGER NOT NULL DEFAULT 0,
  video      INTEGER NOT NULL DEFAULT 0,
  game       INTEGER NOT NULL DEFAULT 0,
  chars      INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (period, account_id)
);

-- 每作品每周期读完人数（未隐藏账户、有日期的读完）：增量维护，周/月人气榜直接按索引取前 N。
CREATE TABLE IF NOT EXISTS work_periods (
  period  TEXT NOT NULL,
  work_id TEXT NOT NULL,
  kind    TEXT NOT NULL,
  n       INTEGER NOT NULL,
  PRIMARY KEY (period, work_id)
);
CREATE INDEX IF NOT EXISTS idx_work_periods_top ON work_periods (period, n DESC);
CREATE INDEX IF NOT EXISTS idx_work_periods_kind_top ON work_periods (period, kind, n DESC);

-- 榜单快照（定时任务生成）。data = JSON [[account_id, value, rank], ...]，按名次排好；
-- 按 chunk 分块存（每块 ≤ SNAPSHOT_CHUNK 条），不受 D1 单行 2MB 限制。
CREATE TABLE IF NOT EXISTS rank_snapshots (
  win         TEXT NOT NULL,
  metric      TEXT NOT NULL,
  chunk       INTEGER NOT NULL,
  from_key    TEXT,
  computed_at INTEGER NOT NULL,
  data        TEXT NOT NULL,
  PRIMARY KEY (win, metric, chunk)
);

-- 作品人气快照。kind = 'all' 或具体 kind；data = JSON [[work_id, readers, rank], ...]（前 100）。
CREATE TABLE IF NOT EXISTS popular_snapshots (
  win         TEXT NOT NULL,
  kind        TEXT NOT NULL,
  from_key    TEXT,
  computed_at INTEGER NOT NULL,
  data        TEXT NOT NULL,
  PRIMARY KEY (win, kind)
);

-- 全局日预算（防 Cloudflare 超额计费的熔断器）。kind：write_rows / media / register。
CREATE TABLE IF NOT EXISTS budgets (
  day  TEXT NOT NULL,
  kind TEXT NOT NULL,
  used INTEGER NOT NULL,
  PRIMARY KEY (day, kind)
);

-- R2 已用字节（单行）。超过 MEDIA_QUOTA_BYTES 拒收新图片，保证存储不越过免费额度。
CREATE TABLE IF NOT EXISTS media_usage (
  id    INTEGER PRIMARY KEY CHECK (id = 1),
  bytes INTEGER NOT NULL
);
INSERT OR IGNORE INTO media_usage (id, bytes) VALUES (1, 0);

-- 好友（有序对 a<b，requester 记发起方；见 src/social.js）。
-- created_at：pending = 申请时刻，accepted = 成为好友的时刻。
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
CREATE INDEX IF NOT EXISTS idx_blocks_blocked ON blocks (blocked_id);

CREATE TABLE IF NOT EXISTS reports (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  reporter    TEXT NOT NULL,
  target_kind TEXT NOT NULL CHECK (target_kind IN ('account', 'work')),
  target_id   TEXT NOT NULL,
  reason      TEXT NOT NULL DEFAULT '',
  created_at  INTEGER NOT NULL,
  resolved    INTEGER NOT NULL DEFAULT 0
);
-- 同一举报人对同一目标只有一条未处理举报（重复举报只刷新理由）；处理后可再次举报。
CREATE UNIQUE INDEX IF NOT EXISTS idx_reports_open
  ON reports (reporter, target_kind, target_id) WHERE resolved = 0;

-- 写请求防重放：同一签名只能用一次。签名本身只在 ±5 分钟内有效，所以只需保留
-- 最近 10 分钟的记录（scheduled 清理）。不用「时刻严格递增」是因为客户端并发写
-- （封面并行上传、改资料与传头像同时）会乱序到达，时钟回拨后也会整段被拒。
CREATE TABLE IF NOT EXISTS used_sigs (
  account_id TEXT NOT NULL,
  sig        TEXT NOT NULL,
  time       INTEGER NOT NULL,
  PRIMARY KEY (account_id, sig)
);
CREATE INDEX IF NOT EXISTS idx_used_sigs_time ON used_sigs (time);

-- 固定窗口限流计数（注册按 IP、上传按账户）。
CREATE TABLE IF NOT EXISTS rate_limits (
  bucket       TEXT NOT NULL,
  window_start INTEGER NOT NULL,
  count        INTEGER NOT NULL,
  PRIMARY KEY (bucket, window_start)
);
