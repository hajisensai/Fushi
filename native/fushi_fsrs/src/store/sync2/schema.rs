//! 同步 v2 的表（srs.db schema v5，设计 §3、计划 P3）。
//!
//! - `sync2_ops`：唯一事实表。每个 profile 一个集合，`(profile, device, seq)` 主键；载荷原字节、
//!   链值（[crate::sync2::segment::chain_next]）、因果上下文（`sync2_deps` 里去重存的版本向量）。
//! - `srs_entities` / `srs_field_edits` / `srs_review_logs` / `srs_unknown_events` 从此是 ops 的**投影**
//!   （读侧不变），由 store/sync2 在同一事务里维护；`srs_review_logs.json` 的 `res` 是重放结果。
//! - 其余是同步元数据：本机身份、每台设备的进度与公钥、因果投递缓冲、本机切段点、每个存储位置的
//!   上传进度、日志的重放意图、旧修改记录的因果闭包。

pub const V5: &str = r#"
CREATE TABLE IF NOT EXISTS sync2_self (
  profile_uid TEXT NOT NULL PRIMARY KEY,
  collection BLOB NOT NULL,
  device BLOB NOT NULL,
  key_seed BLOB NOT NULL,
  next_seq INTEGER NOT NULL,
  chain BLOB NOT NULL,
  hlc_wall INTEGER NOT NULL DEFAULT 0,
  hlc_logical INTEGER NOT NULL DEFAULT 0,
  head_gen INTEGER NOT NULL DEFAULT 0,
  migrated_at INTEGER NULL,
  name TEXT NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS sync2_deps (
  id INTEGER PRIMARY KEY,
  vv BLOB NOT NULL UNIQUE
);
CREATE TABLE IF NOT EXISTS sync2_ops (
  profile_uid TEXT NOT NULL,
  device BLOB NOT NULL,
  seq INTEGER NOT NULL,
  wall INTEGER NOT NULL,
  logical INTEGER NOT NULL,
  deps INTEGER NOT NULL,
  kind INTEGER NOT NULL,
  schema INTEGER NOT NULL,
  payload BLOB NOT NULL,
  purged INTEGER NOT NULL DEFAULT 0,
  chain BLOB NOT NULL,
  received_at INTEGER NOT NULL,
  PRIMARY KEY (profile_uid, device, seq)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS sync2_devices (
  profile_uid TEXT NOT NULL,
  device BLOB NOT NULL,
  public BLOB NULL,
  applied INTEGER NOT NULL DEFAULT 0,
  chain BLOB NULL,
  head_gen INTEGER NOT NULL DEFAULT 0,
  head_seq INTEGER NOT NULL DEFAULT 0,
  head_at INTEGER NULL,
  ack BLOB NULL,
  digest TEXT NULL,
  name TEXT NOT NULL DEFAULT '',
  frozen INTEGER NOT NULL DEFAULT 0,
  warning TEXT NULL,
  PRIMARY KEY (profile_uid, device)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS sync2_pending (
  profile_uid TEXT NOT NULL,
  device BLOB NOT NULL,
  seq INTEGER NOT NULL,
  op BLOB NOT NULL,
  chain BLOB NOT NULL,
  PRIMARY KEY (profile_uid, device, seq)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS sync2_segments (
  profile_uid TEXT NOT NULL,
  device BLOB NOT NULL,
  first INTEGER NOT NULL,
  last INTEGER NOT NULL,
  PRIMARY KEY (profile_uid, device, first)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS sync2_locations (
  profile_uid TEXT NOT NULL,
  location TEXT NOT NULL,
  uploaded INTEGER NOT NULL DEFAULT 0,
  head_gen INTEGER NOT NULL DEFAULT 0,
  last_ok INTEGER NULL,
  PRIMARY KEY (profile_uid, location)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS sync2_log_meta (
  log_id TEXT NOT NULL PRIMARY KEY,
  profile_uid TEXT NOT NULL,
  card_id TEXT NOT NULL,
  note_id TEXT NULL,
  intent INTEGER NOT NULL,
  arg INTEGER NULL,
  device BLOB NOT NULL,
  seq INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_sync2_log_meta_note ON sync2_log_meta (note_id);
CREATE TABLE IF NOT EXISTS sync2_edit_ops (
  edit_id TEXT NOT NULL PRIMARY KEY,
  profile_uid TEXT NOT NULL,
  device BLOB NOT NULL,
  seq INTEGER NOT NULL
);
-- sync2_card_deck：冻结，不再读写（重放按日志自己的配置快照算，改配置不再按牌组找卡重放）。
CREATE TABLE IF NOT EXISTS sync2_card_deck (
  card_id TEXT NOT NULL PRIMARY KEY,
  profile_uid TEXT NOT NULL,
  deck_id TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_sync2_card_deck ON sync2_card_deck (profile_uid, deck_id);
CREATE TABLE IF NOT EXISTS sync2_ent_ops (
  profile_uid TEXT NOT NULL,
  kind TEXT NOT NULL,
  entity TEXT NOT NULL,
  device BLOB NOT NULL,
  seq INTEGER NOT NULL,
  what TEXT NOT NULL,
  PRIMARY KEY (profile_uid, kind, entity, device, seq)
) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS idx_sync2_ent_ops_what ON sync2_ent_ops (profile_uid, kind, entity, what);
CREATE TABLE IF NOT EXISTS sync2_tag_adds (
  profile_uid TEXT NOT NULL,
  note TEXT NOT NULL,
  tag TEXT NOT NULL,
  device BLOB NOT NULL,
  seq INTEGER NOT NULL,
  wall INTEGER NOT NULL,
  logical INTEGER NOT NULL,
  PRIMARY KEY (profile_uid, note, tag, device, seq)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS sync2_tag_order (
  profile_uid TEXT NOT NULL,
  note TEXT NOT NULL,
  tags TEXT NOT NULL,
  wall INTEGER NOT NULL,
  logical INTEGER NOT NULL,
  device BLOB NOT NULL,
  PRIMARY KEY (profile_uid, note)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS sync2_held (
  profile_uid TEXT NOT NULL,
  device BLOB NOT NULL,
  seq INTEGER NOT NULL,
  kind TEXT NOT NULL,
  entity TEXT NOT NULL,
  PRIMARY KEY (profile_uid, device, seq)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS sync2_conflicts (
  id TEXT NOT NULL PRIMARY KEY,
  profile_uid TEXT NOT NULL,
  kind TEXT NOT NULL,
  entity_kind TEXT NOT NULL,
  entity TEXT NOT NULL,
  device BLOB NOT NULL,
  seq INTEGER NOT NULL,
  other_count INTEGER NOT NULL,
  at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS sync2_purged (
  profile_uid TEXT NOT NULL,
  kind TEXT NOT NULL,
  entity TEXT NOT NULL,
  PRIMARY KEY (profile_uid, kind, entity)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS sync2_obsolete (
  profile_uid TEXT NOT NULL,
  location TEXT NOT NULL,
  name TEXT NOT NULL,
  last INTEGER NOT NULL,
  PRIMARY KEY (profile_uid, location, name)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS sync2_rewrites (
  profile_uid TEXT NOT NULL,
  location TEXT NOT NULL,
  first INTEGER NOT NULL,
  PRIMARY KEY (profile_uid, location, first)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS sync2_checkpoints (
  profile_uid TEXT NOT NULL,
  device BLOB NOT NULL,
  seq INTEGER NOT NULL,
  wall INTEGER NOT NULL,
  name TEXT NOT NULL,
  reason TEXT NOT NULL,
  PRIMARY KEY (profile_uid, device, seq)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS sync2_media (
  profile_uid TEXT NOT NULL,
  name TEXT NOT NULL,
  sha256 BLOB NOT NULL,
  size INTEGER NOT NULL,
  wall INTEGER NOT NULL,
  logical INTEGER NOT NULL,
  device BLOB NOT NULL,
  PRIMARY KEY (profile_uid, name)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS sync2_legacy (
  profile_uid TEXT NOT NULL,
  device BLOB NOT NULL,
  upto INTEGER NOT NULL,
  ctx TEXT NOT NULL,
  PRIMARY KEY (profile_uid, device)
) WITHOUT ROWID;
"#;

/// V6：本机切段点的压缩后体积估计（字节；0 = 未知，升级前切的老段）。
pub const V6: &str = "ALTER TABLE sync2_segments ADD COLUMN bytes INTEGER NOT NULL DEFAULT 0;";

/// V7：`MediaAt` 操作的投影（设计 §6.4）——各存储位置的媒体目录里有什么，以及谁对哪个位置做过完整列举。
/// 媒体对账读它代替列目录。每个（位置, 名字）按 HLC 大者胜。
pub const V7: &str = r#"
CREATE TABLE IF NOT EXISTS sync2_media_at (
  profile_uid TEXT NOT NULL,
  location TEXT NOT NULL,
  name TEXT NOT NULL,
  present INTEGER NOT NULL,
  wall INTEGER NOT NULL,
  logical INTEGER NOT NULL,
  device BLOB NOT NULL,
  PRIMARY KEY (profile_uid, location, name)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS sync2_media_seeded (
  profile_uid TEXT NOT NULL,
  location TEXT NOT NULL,
  wall INTEGER NOT NULL,
  PRIMARY KEY (profile_uid, location)
) WITHOUT ROWID;
"#;

/// V10：「因果优先、并发才比 HLC」寄存器的反链（store/sync2/mvr.rs）：媒体名 → 内容绑定（`m`）、各位置媒体在 / 不在
/// （`a`）、笔记标签顺序（`t`）。只存（寄存器, 设备, seq），HLC 与上下文按主键从 `sync2_ops` 取。建表后由
/// [super::mvr::rebuild] 从日志重建这三个投影（升级前按纯 HLC 算的值在慢钟 / 超前时钟下与新规则不同，各设备必须
/// 从同一批操作推出同一结果）。
pub const V10: &str = r#"
CREATE TABLE IF NOT EXISTS sync2_mvr (
  profile_uid TEXT NOT NULL,
  reg TEXT NOT NULL,
  device BLOB NOT NULL,
  seq INTEGER NOT NULL,
  PRIMARY KEY (profile_uid, reg, device, seq)
) WITHOUT ROWID;
"#;
