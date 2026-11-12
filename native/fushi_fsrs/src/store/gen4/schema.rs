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
//!   盐与别名（`alias.rs`）：`salt_ix`（带盐的操作）、`alias_ix`（出现过的 ID → 规范 ID）、`alias_writer_ix`（改了名的
//!   旧写入者 → 最初的写入者）；语义摘要（`digest.rs`）：`dg_ix`（每个实体一行）、`dg_dirty`（等重算的实体，静止时为空；
//!   由 `reg_ix` / `tag_ix` / `log_ix` / `ent_ix` / `media_ix` 上的触发器记）。
//!   缓存层（`cache.rs`）：`notes` / `cards`（出卡、浏览读的缓存，列同协议 3 的两张缓存表）、`stats`（有效复习投影）。
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
pub const SCHEMA: i64 = 40_004;

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
CREATE TABLE IF NOT EXISTS salt_ix (
  col INTEGER NOT NULL,
  k INTEGER NOT NULL,
  salt TEXT NOT NULL,
  PRIMARY KEY (col, k, salt)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS alias_ix (
  col INTEGER NOT NULL,
  id BLOB NOT NULL,
  canon BLOB NOT NULL,
  how INTEGER NOT NULL,
  PRIMARY KEY (col, id)
) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS alias_canon ON alias_ix (col, canon, id) WHERE canon != id;
CREATE TABLE IF NOT EXISTS alias_writer_ix (
  col INTEGER NOT NULL,
  name TEXT NOT NULL,
  origin TEXT NOT NULL,
  PRIMARY KEY (col, name)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS dg_ix (
  col INTEGER NOT NULL,
  ekind INTEGER NOT NULL,
  ent NOT NULL,
  sum BLOB NOT NULL,
  n INTEGER NOT NULL,
  PRIMARY KEY (col, ekind, ent)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS dg_dirty (
  col INTEGER NOT NULL,
  ekind INTEGER NOT NULL,
  ent NOT NULL,
  PRIMARY KEY (col, ekind, ent)
) WITHOUT ROWID;
";

/// 派生表的名字（每张都有 `col` 列）。
pub(crate) const DERIVED_TABLES: [&str; 17] = [
    "ent_ix",
    "reg_ix",
    "log_ix",
    "closure_ix",
    "tag_ix",
    "media_ix",
    "purge_ix",
    "ent_ops",
    "hold_ix",
    "salt_ix",
    "alias_ix",
    "alias_writer_ix",
    "dg_ix",
    "dg_dirty",
    "notes",
    "cards",
    "stats",
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

/// 查询规划器的统计：**手写、随 schema 走，不跑 `ANALYZE`**。
///
/// 派生表的键都以 `col` 打头，而一个文件里通常只有一个集合。没有统计时 SQLite 默认「索引第一列相等 ≈ 只剩 10 行」，
/// 于是 `WHERE col = ? AND id = ?` 这样的查询宁可沿主键把整个集合扫一遍，也不走 `(col, id, k)` 的二级索引——样本库
/// （35 万条日志）上这样查一次 80 ms：按日志 ID 重选代表每条日志一次，重建语义摘要每张卡一次（19 分钟）。这里把
/// 「`col` 不区分行、其余各列大致区分到多少」告诉它。`sqlite_stat1.stat` 的格式：行数，再是按索引前 1、2、… 列相等时
/// 平均剩下的行数；`WITHOUT ROWID` 表的主键那一行 `idx` = 表名。量级取样本库，数字只表达形状、不随数据更新：计划因此
/// 是 schema 的函数，不因某台设备数据多少而变（`tests::lookups_with_a_key_never_walk_the_whole_collection` 钉住）。
/// 对这个文件跑 `ANALYZE` / `PRAGMA optimize` 会把它们换成随数据变的统计——下次打开时 [install] 会写回来。
const PLANNER_STATS: [(&str, &str, &str); 20] = [
    ("alias_ix", "alias_canon", "1000000 1000000 2 1"),
    ("alias_ix", "alias_ix", "1000000 1000000 1"),
    ("cards", "cards", "100000 100000 1"),
    ("cards", "cards_note", "100000 100000 2"),
    ("dg_ix", "dg_ix", "200000 200000 40000 1"),
    ("ent_ix", "ent_ix", "50000 50000 1 1"),
    ("ent_ops", "ent_ops", "1000000 1000000 500000 20 20 1"),
    ("log_ix", "log_at", "1000000 1000000 2"),
    ("log_ix", "log_id", "1000000 1000000 1 1"),
    ("log_ix", "log_ix", "1000000 1000000 20 1 1"),
    ("media_ix", "media_ix", "100000 100000 1 1"),
    ("notes", "notes", "50000 50000 1"),
    ("notes", "notes_type", "50000 50000 1000"),
    ("reg_ix", "reg_card_key", "50000 50000 3"),
    ("reg_ix", "reg_ix", "1000000 1000000 250000 13 1 1"),
    ("reg_ix", "reg_set_aside", "1000 1000 500 1"),
    ("stats", "stats", "1000000 1000000 2 1"),
    ("stats", "stats_card", "1000000 1000000 20"),
    ("tag_ix", "tag_ix", "300000 300000 7 4 2 1"),
    ("tag_ix", "tag_set_aside", "1000 1000 500 1"),
];

/// 把 [PLANNER_STATS] 装进 `sqlite_stat1`（已经一样就不写）。
fn planner_stats(conn: &Connection) -> Result<(), String> {
    let exists: bool = conn
        .prepare("SELECT 1 FROM sqlite_schema WHERE type = 'table' AND name = 'sqlite_stat1'")
        .map_err(sql)?
        .exists([])
        .map_err(sql)?;
    let have: Vec<(String, String, String)> = if exists {
        let mut stmt = conn
            .prepare("SELECT tbl, COALESCE(idx, ''), stat FROM sqlite_stat1 ORDER BY tbl, idx")
            .map_err(sql)?;
        let rows = stmt
            .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
            .map_err(sql)?;
        rows.collect::<Result<_, _>>().map_err(sql)?
    } else {
        Vec::new()
    };
    if have
        .iter()
        .map(|(t, i, s)| (t.as_str(), i.as_str(), s.as_str()))
        .eq(PLANNER_STATS.iter().copied())
    {
        return Ok(());
    }
    // `ANALYZE <一张小表>` 只是为了让 SQLite 建出 `sqlite_stat1`（不能直接 CREATE）；`ANALYZE sqlite_schema` 让本连接
    // 重读统计。
    conn.execute_batch("ANALYZE srs_meta; DELETE FROM sqlite_stat1;")
        .map_err(sql)?;
    for (tbl, idx, stat) in PLANNER_STATS {
        conn.execute(
            "INSERT INTO sqlite_stat1 (tbl, idx, stat) VALUES (?1, ?2, ?3)",
            [tbl, idx, stat],
        )
        .map_err(sql)?;
    }
    conn.execute_batch("ANALYZE sqlite_schema;").map_err(sql)
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
    super::digest::set_triggers(conn, true)?;
    conn.execute_batch(super::cache::DDL).map_err(sql)?;
    planner_stats(conn)?;
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

#[cfg(test)]
mod tests {
    use super::*;

    /// 源码里一个字符串字面量的内容（处理行尾续行与常见转义）；[at] 指向开头的引号。返回 (内容, 结束引号之后的位置)。
    fn literal(src: &[u8], at: usize) -> (String, usize) {
        let mut out = Vec::new();
        let mut i = at + 1;
        while src[i] != b'"' {
            if src[i] == b'\\' {
                i += 1;
                match src[i] {
                    b'\n' | b'\r' => {
                        while src[i].is_ascii_whitespace() {
                            i += 1;
                        }
                        continue;
                    }
                    b'n' => out.push(b'\n'),
                    c => out.push(c),
                }
            } else {
                out.push(src[i]);
            }
            i += 1;
        }
        (String::from_utf8(out).unwrap(), i + 1)
    }

    /// 一个文件（测试模块之前的部分）里的全部 SQL 语句字面量。
    fn statements(src: &str) -> Vec<String> {
        let src = src.split("#[cfg(test)]").next().unwrap().as_bytes();
        let mut out = Vec::new();
        let mut i = 0;
        while i < src.len() {
            if src[i] != b'"' {
                i += 1;
                continue;
            }
            let (text, next) = literal(src, i);
            i = next;
            let verb = ["SELECT ", "DELETE ", "UPDATE "]
                .iter()
                .any(|v| text.starts_with(v));
            // 带 `{` 的是 format! 的模板（表名待填），不是完整语句。
            if verb && !text.contains('{') {
                out.push(text);
            }
        }
        out
    }

    /// 派生层的每条语句：只要它除了 `col = ?` 之外还给了别的相等条件，计划里就不能有「只按 `col` 找」的一步——
    /// 那是把整个集合走一遍（[PLANNER_STATS] 说的那个坑）。计划只取决于 schema 与手写的统计，空库上看就够。
    #[test]
    fn lookups_with_a_key_never_walk_the_whole_collection() {
        // 本来就是对整个集合做的（多出来的相等条件是 `state` / `kind` / 键名这类过滤，不是定位）。
        const WHOLE: [&str; 7] = [
            "SELECT DISTINCT ekind, ent FROM reg_ix WHERE col = ?1 AND key = ?2",
            "SELECT k FROM reg_ix WHERE col = ?1 AND state = ?2 UNION SELECT k FROM tag_ix WHERE col = ?1 AND state = ?2",
            "SELECT k FROM reg_ix WHERE col = ?1 AND state = ?2 UNION SELECT k FROM purge_ix WHERE col = ?1 AND state = ?2",
            "SELECT name, k FROM media_ix WHERE col = ?1 AND state = ?2 ORDER BY name",
            "SELECT id, kind, k FROM ent_ix WHERE col = ?1 AND typeof(id) = 'blob' ORDER BY id, k",
            "SELECT ekind, ent, key, k FROM reg_ix WHERE col = ?1 AND state != ?2 AND typeof(ent) = 'blob' ORDER BY ekind, ent, key, k",
            // 整份物化：本来就要列出集合里全部活着的笔记。
            "SELECT id FROM ent_ix WHERE col = ?1 AND kind = ?2 AND win = 1",
        ];
        let conn = open_in_memory().unwrap();
        let mut seen = 0;
        let mut bad = Vec::new();
        for src in [
            include_str!("derive.rs"),
            include_str!("weigh.rs"),
            include_str!("alias.rs"),
            include_str!("digest.rs"),
            include_str!("cache.rs"),
        ] {
            for q in statements(src) {
                seen += 1;
                let keyed = q.matches("= ?").count() > q.matches("col = ?").count();
                if !keyed || WHOLE.contains(&q.as_str()) {
                    continue;
                }
                let mut stmt = conn
                    .prepare(&format!("EXPLAIN QUERY PLAN {q}"))
                    .unwrap_or_else(|e| panic!("{q}: {e}"));
                let mut rows = stmt.raw_query();
                while let Some(r) = rows.next().unwrap() {
                    let step: String = r.get(3).unwrap();
                    if step.starts_with("SCAN ") && !step.contains("CONSTANT")
                        || step.starts_with("SEARCH ") && step.ends_with("(col=?)")
                    {
                        bad.push(format!("{q}\n    {step}"));
                    }
                }
            }
        }
        assert!(seen > 60, "only {seen} statements found");
        assert!(bad.is_empty(), "{}", bad.join("\n"));
    }

    #[test]
    fn the_planner_statistics_are_installed_once_and_restored() {
        let conn = open_in_memory().unwrap();
        let read = |conn: &Connection| -> Vec<(String, String)> {
            conn.prepare("SELECT idx, stat FROM sqlite_stat1 ORDER BY tbl, idx")
                .unwrap()
                .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))
                .unwrap()
                .collect::<Result<_, _>>()
                .unwrap()
        };
        let want: Vec<(String, String)> = PLANNER_STATS
            .iter()
            .map(|(_, i, s)| ((*i).to_owned(), (*s).to_owned()))
            .collect();
        assert_eq!(read(&conn), want);
        // 每个名字都真有那张表 / 那个索引。
        for (tbl, idx, _) in PLANNER_STATS {
            let n: i64 = conn
                .query_row(
                    "SELECT COUNT(*) FROM sqlite_schema WHERE tbl_name = ?1 AND name = ?2",
                    [tbl, idx],
                    |r| r.get(0),
                )
                .unwrap();
            assert_eq!(n, 1, "{tbl}.{idx}");
        }
        // 有人跑了 ANALYZE：下次建表时写回来。
        conn.execute_batch("ANALYZE;").unwrap();
        assert_ne!(read(&conn), want);
        in_tx(&conn, install).unwrap();
        assert_eq!(read(&conn), want);
    }
}
