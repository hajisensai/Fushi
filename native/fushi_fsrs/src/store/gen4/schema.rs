//! 新代库文件的表（设计 §2.1、§2.2）。新代是**另一个文件**：这里不碰协议 3 的 `srs.db`，也不认它的任何一张表。
//!
//! 三类表：
//!
//! - **真相**：`ops` / `op_alias` / `op_voids`（每台设备一条从 1 起连续的日志，一个 seq 恰好落在三张表之一）、
//!   它们引用的内部化表 `op_deps` / `writers` / `snapshots`、原生日志的链值 `log_marks`、还没接上前缀的 `op_pending`、
//!   分叉的另一支 `op_forks`。本机不可再生。
//! - **派生**：索引与缓存。全部能从真相与本机状态重建（`derive.rs`）。索引：`ent_ix` / `reg_ix` / `log_ix`（带 `log_id`
//!   索引）/ `closure_ix`；语义层（`weigh.rs`）：`tag_ix`（标签 OR-Set 与顺序提示）、`media_ix`（媒体名 → 内容）、
//!   `purge_ix`（彻底清除）、`ent_ops`（实体 → 碰过它、别的索引里查不到的操作）、`hold_ix`（被并发改动扣住的删除）。
//!   别名与笔记 / 卡片缓存是后续 PR。
//! - **本机状态**：`collections`（profile ↔ 集合的绑定，设计 §5.1）、`devs`（设备 ↔ 小整数下标；`kind` 空 = 只被别的操作
//!   点过名、还没见过它的日志，0 = 原生日志，1 = 承袭日志；`src` = 承袭日志的来源集合；`tail` = 原生日志末尾的链值）、
//!   `trust`（还没信任的设备：`state` 1 = 待确认，2 = 已拒绝；没有行 = 可信。纯本机，不同步，协议 3 的 `sync2_trust`）。
//!   `derive_cfg`（派生层的输入里只有宿主知道的那部分，按名字存文本：内置笔记类型表、缓存配置；`truth.rs`）。
//!
//! 各列的取值见 `truth.rs`（落库规则）与 `pack.rs`（操作体的存储编码）。`writers.name` 存的是名字的紧凑字节形
//! （`gen4::name`：一个文本只有一种字节形，所以按字节唯一就是按名字唯一）。
//!
//! 操作的主键是一个整数 `k = dev << 40 | seq`（[opk]）：`dev` 是 `devs` 的下标，全库唯一、自带所属集合，所以按操作
//! 寻址的表不再另存集合号；rowid 表的点读与顺序扫都是一次 B 树下降，行里不重复存键。
//!
//! `srs_meta(key, value)` 与文本形式的 `schema` 照旧（设计 §6.1 末）：协议 3 的内核把它读成整数、比自己大就拒绝打开，
//! 所以新代文件即使被旧版本当成它的库打开，也只会报错、不会被从头建表。

use std::path::Path;

use rusqlite::Connection;

/// 新代库的 schema 号。只要求远大于协议 3 的任何一个 schema 号（最后一个是 29）；万位是代，低位是这一代里的存储版本。
pub const SCHEMA: i64 = 40_002;

const SEQ_BITS: u32 = 40;
const SEQ_MASK: i64 = (1 << SEQ_BITS) - 1;
const DEV_MAX: i64 = 1 << 22;

/// `(设备下标, seq)` → 操作的主键。
pub(crate) fn opk(dev: i64, seq: u64) -> Result<i64, String> {
    if dev <= 0 || dev >= DEV_MAX || seq == 0 || seq > SEQ_MASK as u64 {
        return Err(format!("gen4 store: op key out of range ({dev}, {seq})"));
    }
    Ok((dev << SEQ_BITS) | seq as i64)
}

pub(crate) fn k_dev(k: i64) -> i64 {
    k >> SEQ_BITS
}

pub(crate) fn k_seq(k: i64) -> u64 {
    (k & SEQ_MASK) as u64
}

/// 一台设备的主键区间 `[lo, hi]`。
pub(crate) fn k_range(dev: i64) -> (i64, i64) {
    (dev << SEQ_BITS, (dev << SEQ_BITS) | SEQ_MASK)
}

pub(crate) fn sql<E: std::fmt::Display>(e: E) -> String {
    format!("gen4 store: {e}")
}

const TRUTH: &str = "
CREATE TABLE IF NOT EXISTS collections (
  col INTEGER PRIMARY KEY,
  profile_uid TEXT NOT NULL UNIQUE,
  collection BLOB NOT NULL UNIQUE,
  dir TEXT NOT NULL,
  salts TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS devs (
  dev INTEGER PRIMARY KEY,
  col INTEGER NOT NULL,
  id BLOB NOT NULL,
  kind INTEGER,
  src BLOB,
  tail BLOB,
  UNIQUE (col, id)
);
CREATE TABLE IF NOT EXISTS trust (
  col INTEGER NOT NULL,
  device BLOB NOT NULL,
  state INTEGER NOT NULL,
  since INTEGER NOT NULL,
  PRIMARY KEY (col, device)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS derive_cfg (
  col INTEGER NOT NULL,
  key TEXT NOT NULL,
  value TEXT NOT NULL,
  PRIMARY KEY (col, key)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS ops (
  k INTEGER PRIMARY KEY,
  wall INTEGER NOT NULL,
  logical INTEGER NOT NULL,
  deps INTEGER NOT NULL,
  kind INTEGER NOT NULL,
  fmt INTEGER NOT NULL,
  flags INTEGER NOT NULL,
  body BLOB NOT NULL,
  aux BLOB,
  fp BLOB
);
CREATE TABLE IF NOT EXISTS op_alias (
  k INTEGER PRIMARY KEY,
  kind INTEGER NOT NULL,
  wall INTEGER NOT NULL,
  logical INTEGER NOT NULL,
  of_dev INTEGER NOT NULL,
  of_seq INTEGER NOT NULL,
  flags INTEGER NOT NULL,
  stamp BLOB,
  fp BLOB NOT NULL
);
CREATE TABLE IF NOT EXISTS op_voids (
  k INTEGER PRIMARY KEY,
  n INTEGER NOT NULL,
  flags INTEGER NOT NULL,
  fps BLOB,
  chain BLOB
);
CREATE TABLE IF NOT EXISTS op_deps (id INTEGER PRIMARY KEY, bytes BLOB NOT NULL UNIQUE);
CREATE TABLE IF NOT EXISTS writers (id INTEGER PRIMARY KEY, name BLOB NOT NULL UNIQUE);
CREATE TABLE IF NOT EXISTS snapshots (id INTEGER PRIMARY KEY, body TEXT NOT NULL UNIQUE);
CREATE TABLE IF NOT EXISTS log_marks (
  dev INTEGER NOT NULL,
  seq INTEGER NOT NULL,
  chain BLOB NOT NULL,
  PRIMARY KEY (dev, seq)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS op_pending (
  k INTEGER NOT NULL,
  fp BLOB NOT NULL,
  prev_fp BLOB,
  tv INTEGER NOT NULL,
  slot BLOB NOT NULL,
  PRIMARY KEY (k, fp)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS op_forks (
  k INTEGER NOT NULL,
  fp BLOB NOT NULL,
  tv INTEGER NOT NULL,
  slot BLOB NOT NULL,
  PRIMARY KEY (k, fp)
) WITHOUT ROWID;
";

/// 派生表：全部能由 `derive.rs` 的 `rebuild_all` 从真相重建。列的取值见那里。
const DERIVED: &str = "
CREATE TABLE IF NOT EXISTS ent_ix (
  col INTEGER NOT NULL,
  id NOT NULL,
  k INTEGER NOT NULL,
  kind INTEGER NOT NULL,
  win INTEGER NOT NULL,
  PRIMARY KEY (col, id, k)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS reg_ix (
  col INTEGER NOT NULL,
  ekind INTEGER NOT NULL,
  ent NOT NULL,
  key BLOB NOT NULL,
  k INTEGER NOT NULL,
  state INTEGER NOT NULL,
  PRIMARY KEY (col, ekind, ent, key, k)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS log_ix (
  col INTEGER NOT NULL,
  card NOT NULL,
  at INTEGER NOT NULL,
  k INTEGER NOT NULL,
  id NOT NULL,
  win INTEGER NOT NULL,
  PRIMARY KEY (col, card, at, k)
) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS log_id ON log_ix (col, id, k);
CREATE INDEX IF NOT EXISTS reg_set_aside ON reg_ix (col, state, k) WHERE state < 0;
CREATE TABLE IF NOT EXISTS closure_ix (
  col INTEGER NOT NULL,
  device BLOB NOT NULL,
  upto INTEGER NOT NULL,
  ctx TEXT NOT NULL,
  PRIMARY KEY (col, device)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS tag_ix (
  col INTEGER NOT NULL,
  note NOT NULL,
  k INTEGER NOT NULL,
  what INTEGER NOT NULL,
  tag TEXT NOT NULL,
  state INTEGER NOT NULL,
  PRIMARY KEY (col, note, k, what, tag)
) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS tag_set_aside ON tag_ix (col, state, k) WHERE state < 0;
CREATE TABLE IF NOT EXISTS media_ix (
  col INTEGER NOT NULL,
  name TEXT NOT NULL,
  k INTEGER NOT NULL,
  state INTEGER NOT NULL,
  PRIMARY KEY (col, name, k)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS purge_ix (
  col INTEGER NOT NULL,
  ekind INTEGER NOT NULL,
  ent NOT NULL,
  k INTEGER NOT NULL,
  state INTEGER NOT NULL,
  PRIMARY KEY (col, ekind, ent, k)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS ent_ops (
  col INTEGER NOT NULL,
  ekind INTEGER NOT NULL,
  ent NOT NULL,
  what INTEGER NOT NULL,
  k INTEGER NOT NULL,
  PRIMARY KEY (col, ekind, ent, what, k)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS hold_ix (
  col INTEGER NOT NULL,
  ekind INTEGER NOT NULL,
  ent NOT NULL,
  k INTEGER NOT NULL,
  edits INTEGER NOT NULL,
  reviews INTEGER NOT NULL,
  moves INTEGER NOT NULL,
  PRIMARY KEY (col, ekind, ent, k)
) WITHOUT ROWID;
";

/// 派生表的名字（每张都有 `col` 列）。
pub(crate) const DERIVED_TABLES: [&str; 9] = [
    "ent_ix",
    "reg_ix",
    "log_ix",
    "closure_ix",
    "tag_ix",
    "media_ix",
    "purge_ix",
    "ent_ops",
    "hold_ix",
];

/// 这个文件是不是新代的库：空文件（还没有任何表）或 `schema` 等于 [SCHEMA] 才是。只读。
///
/// 协议 3 的 `srs.db`、更新版本写的新代库、别的 SQLite 文件都在这里拒掉——在动任何 PRAGMA、建任何表之前。
fn check_kind(conn: &Connection) -> Result<(), String> {
    let tables: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM sqlite_schema WHERE type = 'table'",
            [],
            |r| r.get(0),
        )
        .map_err(sql)?;
    if tables == 0 {
        return Ok(());
    }
    let has_meta: bool = conn
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM sqlite_schema WHERE type = 'table' AND name = 'srs_meta')",
            [],
            |r| r.get(0),
        )
        .map_err(sql)?;
    let current: Option<String> = if has_meta {
        conn.query_row("SELECT value FROM srs_meta WHERE key = 'schema'", [], |r| {
            r.get(0)
        })
        .ok()
    } else {
        None
    };
    match current.as_deref().map(str::parse::<i64>) {
        Some(Ok(v)) if v == SCHEMA => Ok(()),
        Some(Ok(v)) if v > SCHEMA => Err(format!(
            "gen4 store: schema {v} is newer than this build ({SCHEMA})"
        )),
        other => Err(format!(
            "gen4 store: not a generation 4 library (schema {other:?})"
        )),
    }
}

/// 建表（可重放）。不是新代库的文件报错、什么都不改。
pub fn install(conn: &Connection) -> Result<(), String> {
    check_kind(conn)?;
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS srs_meta (key TEXT NOT NULL PRIMARY KEY, value TEXT NOT NULL);",
    )
    .map_err(sql)?;
    conn.execute_batch(TRUTH).map_err(sql)?;
    conn.execute_batch(DERIVED).map_err(sql)?;
    conn.execute(
        "INSERT OR REPLACE INTO srs_meta (key, value) VALUES ('schema', ?1)",
        [SCHEMA.to_string()],
    )
    .map_err(sql)?;
    Ok(())
}

/// 打开（不存在就建）新代库文件。不做内存映射（设计 §6.5：迁移用的连接不映射）；页缓存取保守值，接线时由调用方按
/// 现有预算（`store/mem_budget.rs`）再调。
pub fn open(path: &Path) -> Result<Connection, String> {
    let conn = Connection::open(path).map_err(sql)?;
    check_kind(&conn)?;
    configure(&conn)?;
    in_tx(&conn, install)?;
    Ok(conn)
}

/// 内存库（测试）。
pub fn open_in_memory() -> Result<Connection, String> {
    let conn = Connection::open_in_memory().map_err(sql)?;
    in_tx(&conn, install)?;
    Ok(conn)
}

fn configure(conn: &Connection) -> Result<(), String> {
    // 新文件才生效；已有的文件保持它建库时的设置。
    conn.execute_batch("PRAGMA auto_vacuum = INCREMENTAL;")
        .map_err(sql)?;
    let mode: String = conn
        .query_row("PRAGMA journal_mode = WAL", [], |r| r.get(0))
        .map_err(sql)?;
    if !mode.eq_ignore_ascii_case("wal") {
        return Err(format!("gen4 store: journal_mode is {mode}, expected wal"));
    }
    conn.execute_batch("PRAGMA synchronous = NORMAL; PRAGMA cache_size = -16384;")
        .map_err(sql)?;
    Ok(())
}

/// 在一个事务里跑 [f]；出错整笔回滚。
pub fn in_tx<T>(
    conn: &Connection,
    f: impl FnOnce(&Connection) -> Result<T, String>,
) -> Result<T, String> {
    conn.execute_batch("SAVEPOINT gen4").map_err(sql)?;
    match f(conn) {
        Ok(v) => match conn.execute_batch("RELEASE gen4") {
            Ok(()) => Ok(v),
            Err(e) => {
                let _ = conn.execute_batch("ROLLBACK TO gen4; RELEASE gen4");
                Err(sql(e))
            }
        },
        Err(e) => {
            let _ = conn.execute_batch("ROLLBACK TO gen4; RELEASE gen4");
            Err(e)
        }
    }
}

/// 每张表（含它的索引）占的字节，按名字升序。库没编 `dbstat` 时返回空表。
pub fn table_bytes(conn: &Connection) -> Vec<(String, i64)> {
    let Ok(mut stmt) = conn.prepare(
        "SELECT COALESCE(s.tbl_name, d.name), SUM(d.pgsize) FROM dbstat d \
         LEFT JOIN sqlite_schema s ON s.name = d.name GROUP BY 1 ORDER BY 1",
    ) else {
        return Vec::new();
    };
    let rows = stmt.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?)));
    match rows {
        Ok(it) => it.filter_map(Result::ok).collect(),
        Err(_) => Vec::new(),
    }
}
