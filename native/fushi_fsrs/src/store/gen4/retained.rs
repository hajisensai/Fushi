//! 保留副本的到期与删除（设计 §9 第 3 项定案 D6 / D32；规划 §6 K2 合并条件）。
//!
//! 保留副本 = 迁移后**原位封存**的协议 3 `srs.db`（`store::seal`）。它给「退回旧版本」留后路，也一直留着迁移前的原文
//! ——新代里彻底清除过的内容在它里面还在，直到它被删掉。删 = 原路径换成墓碑库（`seal::write_tombstone`：旧版本照样
//! 拒绝打开，不会建一个空库照常跑）。
//!
//! # 什么时候到期（[due_at]）
//!
//! - 新代**第一次同步成功**（某个位置上 `head` 走完，`cmd/sync.rs` [note_first_sync]）之后 [AFTER_FIRST_SYNC_MS]（14 天）。
//! - 从没同步成功过（没有同步位置、或位置一直没跑通）：**迁移提交**之后 [WITHOUT_SYNC_MS]（30 天，设计「从不同步的保留
//!   30 天」）。迁移提交的时刻在提交前写进新代库（[MIGRATED_AT_KEY]，`migrate.rs` 的提交步骤）。
//! - 两个时刻都没有（这一版之前的开发构建迁出来的库）：不自动删，只能手动删。
//!
//! 第一次同步成功记在 [FIRST_SYNC_KEY]，只写一次；没有这一行、但 `loc_state.last_ok` 有值的（这一版之前同步过的库）
//! 取其中最早的一个当作它。
//!
//! # 删除（[delete] 与开库时的 [sweep]）
//!
//! 都在换代锁里做，先核对：
//!
//! 1. 新代库 `srs4.db` 能正常打开：`files::open_ready`（魔数、schema 号、建好的表）+ `PRAGMA quick_check` = `ok`。核对
//!    不过不删——新代库坏了的时候保留副本是唯一完好的数据。
//! 2. `srs.db` 是封存进旁边这份新代库的保留副本（`seal::write_tombstone` 自己的 `check_tombstone_target`）：没封存的协议 3
//!    库、不是 SQLite 的文件、封存目标不在了的都拒绝。
//!
//! 删除是不可逆的：没有任何命令能把墓碑换回原来的库。手动删（全局命令 `gen4_retained_delete`）由调用方（app 设置、ctl、
//! 服务端 admin）先取得用户确认；到期自动删在 Primary 打开新代库时（`files::open_gen4`）。自动删出错不挡开库：原因记进
//! [ERROR_KEY]（全局命令 `gen4_retained_state` 的 `error`），成功后删掉它。

use std::path::Path;

use rusqlite::{Connection, OpenFlags, OptionalExtension};
use serde_json::{Value, json};

use super::files::{self, GEN4_FILE, GenLock, LEGACY_FILE};
use super::schema::sql;
use crate::store::seal::{self, SEALED_SCHEMA};

/// 新代库 `srs_meta`：迁移提交的时刻（毫秒）。迁移在提交前写进临时文件，随改名一起提交；全新安装的库没有。
pub const MIGRATED_AT_KEY: &str = "gen4_migrated_at_ms";

/// 新代库 `srs_meta`：新代第一次同步成功的时刻（毫秒），只写一次。
pub const FIRST_SYNC_KEY: &str = "gen4_first_sync_ok_ms";

/// 新代库 `srs_meta`：上一次到期自动删没做成的原因。只在保留副本还在（[CopyState::Sealed]）时有意义：[state] 只在那时
/// 报它；副本没了（删成了，手动或自动）之后它就是陈旧的，下一次 Primary 开库（[sweep]）删掉。手动删（[delete]）不碰
/// 新代库的写锁：删成没删成只看墓碑换没换上，不会因为同步正占着写锁而把「已删」误报成失败。
pub const ERROR_KEY: &str = "gen4_retained_error";

const DAY_MS: i64 = 86_400_000;

/// 第一次同步成功之后保留多久。
pub const AFTER_FIRST_SYNC_MS: i64 = 14 * DAY_MS;

/// 从没同步成功过时，迁移提交之后保留多久。
pub const WITHOUT_SYNC_MS: i64 = 30 * DAY_MS;

fn meta_get(conn: &Connection, key: &str) -> Result<Option<String>, String> {
    conn.prepare_cached("SELECT value FROM srs_meta WHERE key = ?1")
        .map_err(sql)?
        .query_row([key], |r| r.get(0))
        .optional()
        .map_err(sql)
}

fn meta_ms(conn: &Connection, key: &str) -> Result<Option<i64>, String> {
    Ok(meta_get(conn, key)?.and_then(|v| v.parse::<i64>().ok()))
}

/// 迁移提交步骤里调（[conn] 是还没改名的新代库）：记下迁移提交的时刻。
pub(crate) fn record_migrated_at(conn: &Connection, now_ms: i64) -> Result<(), String> {
    conn.execute(
        "INSERT INTO srs_meta (key, value) VALUES (?1, ?2) \
         ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        [MIGRATED_AT_KEY, now_ms.to_string().as_str()],
    )
    .map_err(sql)?;
    Ok(())
}

/// 同步一轮在某个位置上成功（`cmd/sync.rs` `head`，在它的写事务里）：第一次成功的时刻只记一次。
pub(crate) fn note_first_sync(conn: &Connection, now_ms: i64) -> Result<(), String> {
    conn.prepare_cached("INSERT OR IGNORE INTO srs_meta (key, value) VALUES (?1, ?2)")
        .map_err(sql)?
        .execute([FIRST_SYNC_KEY, now_ms.to_string().as_str()])
        .map_err(sql)?;
    Ok(())
}

/// 第一次同步成功的时刻：[FIRST_SYNC_KEY]；没有就取 `loc_state.last_ok` 里最早的（这一版之前同步过的库）。
fn first_sync(conn: &Connection) -> Result<Option<i64>, String> {
    if let Some(at) = meta_ms(conn, FIRST_SYNC_KEY)? {
        return Ok(Some(at));
    }
    conn.query_row(
        "SELECT MIN(last_ok) FROM loc_state WHERE last_ok IS NOT NULL",
        [],
        |r| r.get::<_, Option<i64>>(0),
    )
    .map_err(sql)
}

/// 保留副本的到期时刻（文件头「什么时候到期」）；不会自动到期 = None。
pub(crate) fn due_at(conn: &Connection) -> Result<Option<i64>, String> {
    if let Some(at) = first_sync(conn)? {
        return Ok(Some(at.saturating_add(AFTER_FIRST_SYNC_MS)));
    }
    Ok(meta_ms(conn, MIGRATED_AT_KEY)?.map(|at| at.saturating_add(WITHOUT_SYNC_MS)))
}

/// 目录里 `srs.db` 的样子。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CopyState {
    /// 没有这个文件。
    Absent,
    /// 已经是墓碑库（删过了）。
    Tombstone,
    /// 封存的保留副本，`bytes` = 主文件 + `-wal` 的大小。
    Sealed { bytes: u64 },
    /// 在，但不是 SQLite 文件（打开 / 读它报 `SQLITE_NOTADB`，与 `files::finish_seal` 的 `Retained::Unreadable` 同一判据）：
    /// 保留副本已经坏了，退回旧版本这条路没了（旧版本同样拒绝打开它）。新代库不受影响；不认作保留副本、不删，只报给
    /// 设置页 / ctl 提示用户（BUG-5079）。
    Unreadable,
    /// 别的（没封存的协议 3 库、不是 SQLite 的文件、读不了……）：不是这里管的保留副本。
    Other,
}

impl CopyState {
    fn wire(self) -> &'static str {
        match self {
            CopyState::Absent => "absent",
            CopyState::Tombstone => "tombstone",
            CopyState::Sealed { .. } => "sealed",
            CopyState::Unreadable => "unreadable",
            CopyState::Other => "other",
        }
    }
}

fn file_len(path: &Path) -> u64 {
    std::fs::metadata(path).map_or(0, |m| m.len())
}

/// 看一眼 [dir] 里的 `srs.db`：只读打开、只读 `srs_meta` 两行。不能读写打开：那会在旁边建出 `-wal` / `-shm`，改掉它的
/// 文件状态（`files::RETAINED_UNRELATED_KEY` 按文件状态记「不是迁移来源」，变了就要重算整库摘要）。不是 SQLite 文件 =
/// [CopyState::Unreadable]；别的打不开 / 读不了一律算 [CopyState::Other]：都不认作保留副本，不删。
pub fn inspect(dir: &Path) -> CopyState {
    let path = dir.join(LEGACY_FILE);
    if !path.exists() {
        return CopyState::Absent;
    }
    let not_a_db =
        |e: &rusqlite::Error| e.sqlite_error_code() == Some(rusqlite::ErrorCode::NotADatabase);
    let c = match Connection::open_with_flags(
        &path,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    ) {
        Ok(c) => c,
        Err(e) if not_a_db(&e) => return CopyState::Unreadable,
        Err(_) => return CopyState::Other,
    };
    let read = |key: &str| -> Result<Option<String>, rusqlite::Error> {
        c.query_row("SELECT value FROM srs_meta WHERE key = ?1", [key], |r| {
            r.get(0)
        })
        .optional()
    };
    let (schema, tombstone) = match (read("schema"), read("tombstone")) {
        (Err(e), _) | (_, Err(e)) if not_a_db(&e) => return CopyState::Unreadable,
        (schema, tombstone) => (schema.ok().flatten(), tombstone.ok().flatten()),
    };
    drop(c);
    if schema.as_deref() != Some(SEALED_SCHEMA.to_string().as_str()) {
        return CopyState::Other;
    }
    if tombstone.as_deref() == Some("1") {
        return CopyState::Tombstone;
    }
    CopyState::Sealed {
        bytes: file_len(&path) + file_len(&seal::with_suffix(&path, "-wal")),
    }
}

/// 新代库能正常打开：建好的新代库（调用方已经 `files::open_ready`）+ `PRAGMA quick_check` = `ok`。
fn verify_gen4(conn: &Connection) -> Result<(), String> {
    let mut stmt = conn.prepare("PRAGMA quick_check").map_err(sql)?;
    let lines: Vec<String> = stmt
        .query_map([], |r| r.get(0))
        .map_err(sql)?
        .collect::<Result<_, _>>()
        .map_err(sql)?;
    if lines.len() == 1 && lines[0] == "ok" {
        Ok(())
    } else {
        Err(format!(
            "gen4 retained copy: srs4.db failed its integrity check ({}), keeping srs.db",
            lines.join("; ")
        ))
    }
}

/// 全局命令 `gen4_retained_state {dir, now}` → `{copy, bytes, migratedAtMs, firstSyncAtMs, dueAtMs, due, error}`：
/// `copy` 是 [CopyState] 的线上名；时刻没有 = null；`due` = 保留副本在、到期了（下次开库自动删）；`error` = 上一次自动删
/// 没做成的原因。没有新代库时只报 `copy`（其余 null / false）；副本不在了时 `error` 恒为 null（[ERROR_KEY]）。只读：读两个文件里的几行。
pub fn state(dir: &Path, now_ms: i64) -> Result<Value, String> {
    let copy = inspect(dir);
    let bytes = match copy {
        CopyState::Sealed { bytes } => bytes,
        _ => 0,
    };
    let path = dir.join(GEN4_FILE);
    let (migrated, first, due_at, error) = if path.exists() {
        let c = files::open_secondary(&path)?;
        (
            meta_ms(&c, MIGRATED_AT_KEY)?,
            first_sync(&c)?,
            due_at(&c)?,
            meta_get(&c, ERROR_KEY)?,
        )
    } else {
        (None, None, None, None)
    };
    let sealed = matches!(copy, CopyState::Sealed { .. });
    let error = error.filter(|_| sealed);
    Ok(json!({
        "copy": copy.wire(),
        "bytes": bytes,
        "migratedAtMs": migrated,
        "firstSyncAtMs": first,
        "dueAtMs": due_at,
        "due": sealed && due_at.is_some_and(|d| now_ms >= d),
        "error": error,
    }))
}

/// 全局命令 `gen4_retained_delete {dir}` → `{deleted, freedBytes}` 或 `{deleted: false, reason}`：现在就删保留副本
/// （不看到期；用户在 app 设置 / ctl / 服务端 admin 确认过）。`reason`：`absent`（没有 / 已经是墓碑 / 不是保留副本，
/// 什么都不动）、`unreadable`（在，但不是 SQLite 文件：[CopyState::Unreadable]，什么都不动）、`migrating`（换代锁被别人
/// 拿着）。核对不过（文件头「删除」）报错，什么都不动。
pub fn delete(dir: &Path) -> Result<Value, String> {
    let Some(lock) = GenLock::try_acquire(dir)? else {
        return Ok(json!({"deleted": false, "reason": "migrating"}));
    };
    let bytes = match inspect(dir) {
        CopyState::Sealed { bytes } => bytes,
        other => {
            drop(lock);
            let reason = if other == CopyState::Unreadable {
                "unreadable"
            } else {
                "absent"
            };
            return Ok(json!({"deleted": false, "reason": reason}));
        }
    };
    let path = dir.join(GEN4_FILE);
    if !path.exists() {
        return Err(
            "gen4 retained copy: there is no srs4.db next to it, keeping srs.db".to_owned(),
        );
    }
    // 只读核对：不拿新代库的写锁（[ERROR_KEY] 留给下一次开库清）。
    let conn = files::open_ready(&path)?;
    let verified = verify_gen4(&conn);
    conn.close().map_err(|(_, e)| sql(e))?;
    verified?;
    seal::write_tombstone(&dir.join(LEGACY_FILE))?;
    drop(lock);
    Ok(json!({"deleted": true, "freedBytes": bytes}))
}

/// 删掉 [ERROR_KEY]（在的话）。
fn clear_error(conn: &Connection) -> Result<(), String> {
    if meta_get(conn, ERROR_KEY)?.is_some() {
        conn.execute("DELETE FROM srs_meta WHERE key = ?1", [ERROR_KEY])
            .map_err(sql)?;
    }
    Ok(())
}

/// 开库时的到期自动删（`files::open_gen4` 的 Primary，持着换代锁，[ready] = 刚核对过的新代库读写连接）：保留副本在、
/// 到期了 = 核对新代库、换墓碑。没到期 = 什么都不做。没有保留副本 = 清掉陈旧的 [ERROR_KEY]。返回 `Err` = 没做成的
/// 原因（调用方记进 [ERROR_KEY]，不挡开库）。
pub(crate) fn sweep(dir: &Path, ready: &Connection, now_ms: i64) -> Result<(), String> {
    if !matches!(inspect(dir), CopyState::Sealed { .. }) {
        return clear_error(ready);
    }
    match due_at(ready)? {
        Some(at) if now_ms >= at => {}
        _ => return Ok(()),
    }
    verify_gen4(ready)?;
    seal::write_tombstone(&dir.join(LEGACY_FILE))?;
    clear_error(ready)
}

/// [sweep] 没做成：原因记进 [ERROR_KEY]（记不下 = 库写不了，开库也会失败，报回去）。
pub(crate) fn note_error(ready: &Connection, error: &str) -> Result<(), String> {
    ready
        .execute(
            "INSERT INTO srs_meta (key, value) VALUES (?1, ?2) \
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            [ERROR_KEY, error],
        )
        .map_err(sql)?;
    Ok(())
}

#[cfg(test)]
#[path = "retained_tests.rs"]
mod tests;
