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
-- 原有的 idx_sync2_ent_ops_what (profile_uid, kind, entity, what) 在 v16 去掉（store/schema.rs `V16_DROP`）。
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
-- 段 / head 转发（store/sync2/relay.rs）：各设备见过的最新 head 原文（作者签名，原样可搬）与它引用的段名。
CREATE TABLE IF NOT EXISTS sync2_relay_heads (
  profile_uid TEXT NOT NULL,
  device BLOB NOT NULL,
  gen INTEGER NOT NULL,
  seq INTEGER NOT NULL,
  segments TEXT NOT NULL,
  bytes BLOB NOT NULL,
  PRIMARY KEY (profile_uid, device)
) WITHOUT ROWID;
-- 别的设备的原段（作者签名的原文；原段体是密文时另存明文压缩体），只留还有位置缺它的。
CREATE TABLE IF NOT EXISTS sync2_relay_segs (
  profile_uid TEXT NOT NULL,
  device BLOB NOT NULL,
  name TEXT NOT NULL,
  orig BLOB NOT NULL,
  plain BLOB NULL,
  PRIMARY KEY (profile_uid, device, name)
) WITHOUT ROWID;
-- 每个位置上各设备最新的 head（上一轮看 head 时见到的）：哪个位置缺谁的哪些段。
CREATE TABLE IF NOT EXISTS sync2_location_heads (
  profile_uid TEXT NOT NULL,
  location TEXT NOT NULL,
  device BLOB NOT NULL,
  gen INTEGER NOT NULL,
  seq INTEGER NOT NULL,
  segments TEXT NOT NULL,
  PRIMARY KEY (profile_uid, location, device)
) WITHOUT ROWID;
-- 本机转发到各位置的文件（段名，或 head 文件名）与当时转发的 head 代号（0 = 段已传、head 还没写）。
CREATE TABLE IF NOT EXISTS sync2_relay_out (
  profile_uid TEXT NOT NULL,
  location TEXT NOT NULL,
  device BLOB NOT NULL,
  name TEXT NOT NULL,
  gen INTEGER NOT NULL,
  PRIMARY KEY (profile_uid, location, device, name)
) WITHOUT ROWID;
-- 本机媒体文件的内容（store/sync2/media.rs，只在本机、不进日志）：(size, mtime) 没变就不重算 sha256；`synced` = 本机上次与
-- 绑定对齐时这个文件的内容（区分「本机改了文件」与「别的设备把这个名字绑到了别的内容」）。
CREATE TABLE IF NOT EXISTS sync2_media_local (
  profile_uid TEXT NOT NULL,
  name TEXT NOT NULL,
  size INTEGER NOT NULL,
  mtime INTEGER NOT NULL,
  sha256 BLOB NOT NULL,
  synced BLOB NULL,
  PRIMARY KEY (profile_uid, name)
) WITHOUT ROWID;
"#;

/// V12（审查 S-4）：收段时受影响、还没重放的卡。分批收段会话的每一片只把受影响的卡记进来（同一事务），收尾
/// （[super::transport] `sync2_ingest_finish`）按片重放一次再删；崩溃 / 中途收手后表还在，下一次收尾接着重放。
pub const V12_REPLAY: &str = r#"
CREATE TABLE IF NOT EXISTS sync2_replay_pending (
  profile_uid TEXT NOT NULL,
  card_id TEXT NOT NULL,
  PRIMARY KEY (profile_uid, card_id)
) WITHOUT ROWID;
"#;

/// V14（集成审查【中】）：转发清理两段式（relay.rs `sync2_relay_ack`）。被新转发 head 取代的旧转发件 / 旧转发 head
/// 从 `sync2_relay_out` 挪到这里等删，Dart 删成功后发 `obsolete_ack` 才移除；删除中途失败的下一轮照样再删。
pub const V14_RELAY_GONE: &str = r#"
CREATE TABLE IF NOT EXISTS sync2_relay_gone (
  profile_uid TEXT NOT NULL,
  location TEXT NOT NULL,
  path TEXT NOT NULL,
  PRIMARY KEY (profile_uid, location, path)
) WITHOUT ROWID;
"#;

/// 表 [table] 有没有列 [column]（ALTER 不带 IF NOT EXISTS，靠它让迁移可重放）。
fn has_column(c: &rusqlite::Connection, table: &str, column: &str) -> Result<bool, String> {
    c.query_row(&format!("SELECT COUNT(*) FROM pragma_table_info('{table}') WHERE name = ?1"), [column], |r| r.get::<_, i64>(0))
        .map(|n| n > 0)
        .map_err(|e| e.to_string())
}

/// 升到 V12：每一步都按「已经做过就跳过」写，重放结果相同。
pub fn migrate_v12(c: &rusqlite::Connection) -> Result<(), String> {
    c.execute_batch(V12_REPLAY).map_err(|e| e.to_string())?;
    // S-5：旧小段的删除改按「第一份不再引用它的 head 的代号 / 写出时刻」判（transport.rs `take_obsolete`），不再等别的
    // 设备 ack。升级前已登记的行两列为空，下一次写 head 时按那一刻补上（从那时起算宽限期）。
    for col in ["since_gen", "since_at"] {
        if !has_column(c, "sync2_obsolete", col)? {
            c.execute_batch(&format!("ALTER TABLE sync2_obsolete ADD COLUMN {col} INTEGER NULL;")).map_err(|e| e.to_string())?;
        }
    }
    // S-7：摘要改按卡 ID 分桶、触发器增量维护（digest.rs）。建表 + 触发器后从三张投影表全量重建一次（升级时唯一一次
    // 全表扫描；重建是表内容的确定性函数，重放这一步结果相同）。
    super::digest::install(c)?;
    super::digest::rebuild(c)?;
    Ok(())
}
