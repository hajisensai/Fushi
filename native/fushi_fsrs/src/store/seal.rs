//! 协议 3 `srs.db` 的封存与墓碑库（设计 §6.1 第 7 步，D6 / D7；规划 §1.4）。冻结侧：只认协议 3 的库，不碰新代文件。
//!
//! - **封存**（[seal_legacy]）：迁移提交（`srs4.db` 改名到位）之后，在**原位**把旧库 `srs_meta.schema` 改成
//!   [SEALED_SCHEMA]，同一事务记下 `sealed_into`（新代文件名）与 `sealed_from`（封存前的 schema，灾难恢复时改回去用）。
//!   不改名：v3.3.0 以可创建方式打开 `srs.db`，改了名旧版本会建一个空库照常跑；留在原位、schema 比它大，它就拒绝
//!   打开（`schema::migrate` 的「newer than this build」）。封存后的 `srs.db` 就是保留副本。
//! - **墓碑库**（[write_tombstone]）：保留副本到期或被用户删掉时，原路径换成一个只有 `srs_meta`（`schema` =
//!   [SEALED_SCHEMA]、`tombstone` = 1）的小库，让旧版本照样拒绝而不是建空库。先写临时文件、落盘，再原子 rename 覆盖：
//!   任何时刻原路径上要么是旧的封存库、要么是完整的墓碑库。
//!
//! 39999 小于新代号段（`gen4::schema::GEN_FLOOR`），新代的 `check_kind` 把它当成「封存的协议 3 库」拒掉，不会认作
//! 可以建表的新代库。

use std::fs::{self, OpenOptions};
use std::path::{Component, Path, PathBuf};

use rusqlite::{Connection, OpenFlags, OptionalExtension, Transaction, TransactionBehavior};

use super::schema::SCHEMA_VERSION;

/// 封存值：比协议 3 任何一版都大（旧内核拒绝打开），又小于新代号段（新代不认）。
pub const SEALED_SCHEMA: i64 = 39_999;

/// 墓碑库写到原路径旁边的这个临时名，落盘后 rename 覆盖。
const TOMBSTONE_TMP_SUFFIX: &str = ".tombstone-tmp";

fn e<E: std::fmt::Display>(err: E) -> String {
    format!("srs.db seal: {err}")
}

fn meta(c: &Connection, key: &str) -> Result<Option<String>, String> {
    c.query_row("SELECT value FROM srs_meta WHERE key = ?1", [key], |r| {
        r.get(0)
    })
    .optional()
    .map_err(e)
}

/// 原位封存一份协议 3 的库：一个事务里把 `schema` 改成 [SEALED_SCHEMA]，记 `sealed_into` = [into]、`sealed_from` = 原
/// schema。只改 `srs_meta` 这三行，别的页不动。
///
/// 要求：库是这一版或更老的协议 3 的（`schema` 在 1..=[SCHEMA_VERSION]；G7-2b：迁移的前提补完在副本上升级，原件保持
/// 写它的那个版本的 schema，例如 v3.3.0 的 26，封存的就是它，`sealed_from` 记原号），连接不在事务里。已经封存过、`sealed_into` 相同 = 什么也
/// 不写（提交点之后中断、下次启动重做时幂等：`gen4::files::open_gen4` 的 Primary 打开发现 `srs4.db` 记着的迁移来源
/// 就是这份还没封存的 `srs.db` 就重做）；封存进了别的文件、或 schema 是别的值都报错、不改。
///
/// 这里不核对「[into] 是不是从这份库迁移来的」：那是调用方的事（[legacy_identity] 与新代库里的迁移来源标记对上
/// 才能调）。
///
/// 封存这一笔**返回前已经落盘**：提交时临时把连接切到 `synchronous = FULL`（WAL 下 = 提交时 fsync WAL），返回前
/// 改回原值。协议 3 内核的连接平时是 `NORMAL`，WAL + NORMAL 的提交不 fsync，断电可能丢掉最后几笔——改名
/// （提交点）已经落盘而封存丢了，旧版本就会把没封存的 `srs.db` 当正常库打开写入。
pub fn seal_legacy(conn: &Connection, into: &str) -> Result<(), String> {
    if into.is_empty() {
        return Err(e("empty target name"));
    }
    if !conn.is_autocommit() {
        return Err(e("called inside a transaction"));
    }
    let was: i64 = conn
        .query_row("PRAGMA synchronous", [], |r| r.get(0))
        .map_err(e)?;
    conn.execute_batch("PRAGMA synchronous = FULL;")
        .map_err(e)?;
    let r = seal_in_tx(conn, into);
    let restored = conn
        .execute_batch(&format!("PRAGMA synchronous = {was};"))
        .map_err(e);
    r.and(restored)
}

fn seal_in_tx(conn: &Connection, into: &str) -> Result<(), String> {
    let tx = Transaction::new_unchecked(conn, TransactionBehavior::Immediate).map_err(e)?;
    if seal_rows(&tx, into)? {
        tx.commit().map_err(e)?;
    }
    Ok(())
}

/// [seal_legacy] 的写：核对 schema、写那三行。返回写没写（已经封进 [into] = 不写）。调用方在写事务里。
fn seal_rows(c: &Connection, into: &str) -> Result<bool, String> {
    let current = meta(c, "schema")?;
    match current.as_deref().map(str::parse::<i64>) {
        Some(Ok(v)) if (1..=SCHEMA_VERSION).contains(&v) => {
            for (key, value) in [
                ("schema", SEALED_SCHEMA.to_string()),
                ("sealed_into", into.to_owned()),
                ("sealed_from", v.to_string()),
            ] {
                c.execute(
                    "INSERT INTO srs_meta (key, value) VALUES (?1, ?2) \
                     ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                    [key, value.as_str()],
                )
                .map_err(e)?;
            }
            Ok(true)
        }
        Some(Ok(v)) if v == SEALED_SCHEMA => {
            let was = meta(c, "sealed_into")?;
            if was.as_deref() == Some(into) {
                Ok(false)
            } else {
                Err(e(format!("already sealed into {was:?}, not {into}")))
            }
        }
        other => Err(e(format!(
            "cannot seal a library at schema {other:?} (this build seals 1..={SCHEMA_VERSION})"
        ))),
    }
}

/// 同 [seal_legacy]，给**已经拿着这份库写事务**的调用方（迁移 `gen4::migrate`：从取锁到封存一直持着旧库的写锁，
/// 提交点与封存之间插不进别的写入）。只写那三行、不提交——调用方随后 `COMMIT`，落盘口径由调用方的连接定（迁移的
/// 持锁连接开着 `synchronous = FULL`）。连接不在事务里报错。返回写没写。
pub fn seal_legacy_locked(conn: &Connection, into: &str) -> Result<bool, String> {
    if into.is_empty() {
        return Err(e("empty target name"));
    }
    if conn.is_autocommit() {
        return Err(e("the caller must hold the write transaction"));
    }
    seal_rows(conn, into)
}

/// 一份协议 3 库的身份：`sync2_self` 里各 profile 的设备 ID（建库后各自随机生成的 UUIDv7），小写十六进制、排序后
/// 用逗号连起来。只读，不写这份库。没有 `sync2_self` 表、或一行也没有（没启用过协议 3 的库，`gen4::legacy` 的
/// `preflight` 也不让它迁移）= `None`：这样的库没有可以拿来核对的身份。
///
/// 用途：迁移把它记进新代库的 `srs_meta`（`gen4::files::MIGRATED_FROM_KEY`），随改名一起提交；之后补做封存时拿
/// 旁边那份 `srs.db` 的身份去对，对不上就不是迁移来源，不封。
pub fn legacy_identity(conn: &Connection) -> Result<Option<String>, String> {
    let has_self: bool = conn
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM sqlite_schema WHERE type = 'table' AND name = 'sync2_self')",
            [],
            |r| r.get(0),
        )
        .map_err(e)?;
    if !has_self {
        return Ok(None);
    }
    let devices: Vec<String> = conn
        .prepare("SELECT lower(hex(device)) FROM sync2_self ORDER BY device")
        .map_err(e)?
        .query_map([], |r| r.get(0))
        .map_err(e)?
        .collect::<Result<_, _>>()
        .map_err(e)?;
    Ok((!devices.is_empty()).then(|| devices.join(",")))
}

/// 一份协议 3 库操作日志的水位（blake3 摘要，小写十六进制）：每个 profile 的本机身份行（设备、`next_seq`、链值）+
/// `sync2_ops` / `sync2_pending` 按 (profile, 设备) 的条数、最大 seq、清除过的条数。只读。没有身份
/// （[legacy_identity] 为 `None`）= `None`。
///
/// 用途：迁移把它与 [legacy_identity] 一起记进新代库（`gen4::files::MIGRATED_LOG_KEY`）。提交点（改名）之后、封存之前
/// 进程被杀，写锁跟着释放：这时若退回不认识 `srs4.db` 的旧版本往 `srs.db` 写了东西，身份不变、水位变了，补封
/// （`gen4::files::finish_seal`）据此拒绝——那几笔写入没进新代，封了就丢了。本机写、收到的别的设备的写都走这几张表，
/// 卡片与复习记录的任何改动都会挪动水位；纯本机状态（信任、位置记忆……）的改动不在这里，那个窗口里改了只是没带过去，
/// 不丢卡片与复习记录。
pub fn legacy_log_mark(conn: &Connection) -> Result<Option<String>, String> {
    if legacy_identity(conn)?.is_none() {
        return Ok(None);
    }
    let mut h = blake3::Hasher::new();
    let mut feed = |sql: &str, tag: &[u8]| -> Result<(), String> {
        h.update(tag);
        let mut stmt = conn.prepare(sql).map_err(e)?;
        let n = stmt.column_count();
        let mut rows = stmt.query([]).map_err(e)?;
        while let Some(r) = rows.next().map_err(e)? {
            for i in 0..n {
                match r.get_ref(i).map_err(e)? {
                    rusqlite::types::ValueRef::Null => {
                        h.update(b"n");
                    }
                    rusqlite::types::ValueRef::Integer(v) => {
                        h.update(b"i");
                        h.update(&v.to_le_bytes());
                    }
                    rusqlite::types::ValueRef::Real(v) => {
                        h.update(b"r");
                        h.update(&v.to_le_bytes());
                    }
                    rusqlite::types::ValueRef::Text(b) | rusqlite::types::ValueRef::Blob(b) => {
                        h.update(b"b");
                        h.update(&(b.len() as u64).to_le_bytes());
                        h.update(b);
                    }
                }
            }
        }
        Ok(())
    };
    feed(
        "SELECT profile_uid, device, next_seq, chain FROM sync2_self ORDER BY profile_uid, device",
        b"self\n",
    )?;
    for table in ["sync2_ops", "sync2_pending"] {
        let has: bool = conn
            .query_row(
                "SELECT EXISTS(SELECT 1 FROM sqlite_schema WHERE type = 'table' AND name = ?1)",
                [table],
                |r| r.get(0),
            )
            .map_err(e)?;
        if !has {
            continue;
        }
        let purged = if table == "sync2_ops" {
            "SUM(purged)"
        } else {
            "0"
        };
        feed(
            &format!(
                "SELECT profile_uid, device, COUNT(*), MAX(seq), {purged} FROM {table} \
                 GROUP BY profile_uid, device ORDER BY profile_uid, device"
            ),
            format!("{table}\n").as_bytes(),
        )?;
    }
    Ok(Some(h.finalize().to_hex().to_string()))
}

/// 把 [from] 改名成 [to]（覆盖），**返回时改名已经落盘**：Unix 上改名后对所在目录 fsync；Windows 上用
/// `MoveFileExW(MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)`（不带 WRITE_THROUGH 的 `std::fs::rename`
/// 返回时目录项可能还在缓存里，断电后之后落盘的写入——迁移的封存——可能先于这次改名生效）。
///
/// 错误时改名可能已经做了（Unix 上 fsync 失败）：调用方以 [to] 在不在判断。
pub(crate) fn rename_durable(from: &Path, to: &Path) -> Result<(), String> {
    #[cfg(windows)]
    {
        use std::os::windows::ffi::OsStrExt;
        const MOVEFILE_REPLACE_EXISTING: u32 = 0x1;
        const MOVEFILE_WRITE_THROUGH: u32 = 0x8;
        #[link(name = "kernel32")]
        extern "system" {
            fn MoveFileExW(existing: *const u16, new: *const u16, flags: u32) -> i32;
        }
        let wide = |p: &Path| -> Vec<u16> {
            p.as_os_str()
                .encode_wide()
                .chain(std::iter::once(0))
                .collect()
        };
        let (a, b) = (wide(from), wide(to));
        // SAFETY: 两个参数都是以 0 结尾、在调用期间存活的 UTF-16 缓冲区。
        let ok = unsafe {
            MoveFileExW(
                a.as_ptr(),
                b.as_ptr(),
                MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
            )
        };
        if ok == 0 {
            return Err(e(format!(
                "rename {} -> {}: {}",
                from.display(),
                to.display(),
                std::io::Error::last_os_error()
            )));
        }
        Ok(())
    }
    #[cfg(not(windows))]
    {
        fs::rename(from, to).map_err(|err| {
            e(format!(
                "rename {} -> {}: {err}",
                from.display(),
                to.display()
            ))
        })?;
        match to.parent() {
            Some(dir) => sync_dir(dir),
            None => Ok(()),
        }
    }
}

pub(crate) fn with_suffix(path: &Path, suffix: &str) -> PathBuf {
    let mut s = path.as_os_str().to_owned();
    s.push(suffix);
    PathBuf::from(s)
}

fn remove_if_exists(path: &Path) -> Result<(), String> {
    match fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(err) => Err(e(format!("remove {}: {err}", path.display()))),
    }
}

pub(crate) fn remove_sqlite_files(path: &Path) -> Result<(), String> {
    remove_if_exists(path)?;
    for s in ["-wal", "-shm", "-journal"] {
        remove_if_exists(&with_suffix(path, s))?;
    }
    Ok(())
}

/// 把 [path] 的 WAL 全部检查点进主文件并截断，关掉连接后 `-wal` / `-shm` 不留（有就删）。
///
/// 只挡得住**正在事务里**的别的连接（检查点被读 / 写事务挡住，或关掉后 WAL 还有内容 = 报「in use」）。只是开着、
/// 没有事务的空闲连接挡不住：TRUNCATE 照样成功。Windows 上 SQLite 打开文件不带 `FILE_SHARE_DELETE`，之后的删除 /
/// rename 会失败、报错；Unix 上会删掉它还映射着的 `-wal` / `-shm`、rename 换掉它的 inode，它之后写的东西静默丢失。
/// 所以「没有别的连接」是调用方的前提（[write_tombstone]），这里的检测只是兜底。
fn drain_wal(path: &Path) -> Result<(), String> {
    {
        let c = Connection::open_with_flags(
            path,
            OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_NO_MUTEX,
        )
        .map_err(e)?;
        let (busy, _, _): (i64, i64, i64) = c
            .query_row("PRAGMA wal_checkpoint(TRUNCATE)", [], |r| {
                Ok((r.get(0)?, r.get(1)?, r.get(2)?))
            })
            .map_err(e)?;
        if busy != 0 {
            return Err(e(format!("{} is in use", path.display())));
        }
        c.close().map_err(|(_, err)| e(err))?;
    }
    let wal = with_suffix(path, "-wal");
    if fs::metadata(&wal).map(|m| m.len()).unwrap_or(0) > 0 {
        return Err(e(format!("{} is in use", path.display())));
    }
    remove_if_exists(&wal)?;
    remove_if_exists(&with_suffix(path, "-shm"))
}

#[cfg(unix)]
pub(crate) fn sync_dir(dir: &Path) -> Result<(), String> {
    fs::File::open(dir)
        .and_then(|f| f.sync_all())
        .map_err(|err| e(format!("sync {}: {err}", dir.display())))
}

#[cfg(not(any(unix, windows)))]
pub(crate) fn sync_dir(_dir: &Path) -> Result<(), String> {
    Ok(())
}

/// 墓碑库的内容：只有 `srs_meta`。写成 WAL 模式——旧内核打开时第一件事是 `journal_mode = WAL`，文件本来就是 WAL
/// 它就不必改文件头。
fn build_tombstone(tmp: &Path) -> Result<(), String> {
    let c = Connection::open(tmp).map_err(e)?;
    let mode: String = c
        .query_row("PRAGMA journal_mode = WAL", [], |r| r.get(0))
        .map_err(e)?;
    if !mode.eq_ignore_ascii_case("wal") {
        return Err(e(format!("tombstone journal_mode is {mode}")));
    }
    c.execute_batch(&format!(
        "BEGIN;
         CREATE TABLE srs_meta (key TEXT NOT NULL PRIMARY KEY, value TEXT NOT NULL);
         INSERT INTO srs_meta (key, value) VALUES ('schema', '{SEALED_SCHEMA}'), ('tombstone', '1');
         COMMIT;"
    ))
    .map_err(e)?;
    // 最后一个连接关闭时 SQLite 做完检查点、删掉 -wal / -shm：之后整个库只在主文件里。
    c.close().map_err(|(_, err)| e(err))?;
    if with_suffix(tmp, "-wal").exists() {
        return Err(e("tombstone WAL was not checkpointed"));
    }
    OpenOptions::new()
        .write(true)
        .open(tmp)
        .and_then(|f| f.sync_all())
        .map_err(|err| e(format!("sync {}: {err}", tmp.display())))
}

/// 墓碑能不能盖在 [path] 上：它必须是一份封存过的协议 3 库（`schema` = [SEALED_SCHEMA]），并且要么已经是墓碑
/// （`tombstone` = 1），要么 `sealed_into` 指向的新代文件就在同一个目录里——数据确实已经在那边。没封存的协议 3 库、
/// 空库、不是 SQLite 的文件、封存目标不在了的库都拒绝：盖上去就把还没进新代的数据删了。以读写、不创建的方式打开
/// （WAL 库只读打开会因为没有 `-shm` 失败），只读它。
fn check_tombstone_target(path: &Path) -> Result<(), String> {
    let refuse = |why: String| e(format!("refusing to replace {}: {why}", path.display()));
    let c = Connection::open_with_flags(
        path,
        OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .map_err(|err| refuse(err.to_string()))?;
    let r = (|| {
        let has_meta: bool = c
            .query_row(
                "SELECT EXISTS(SELECT 1 FROM sqlite_schema WHERE type = 'table' AND name = 'srs_meta')",
                [],
                |r| r.get(0),
            )
            .map_err(|err| refuse(err.to_string()))?;
        if !has_meta {
            return Err(refuse(
                "not a sealed protocol 3 library (no srs_meta)".to_owned(),
            ));
        }
        let schema = meta(&c, "schema")?;
        if schema.as_deref() != Some(SEALED_SCHEMA.to_string().as_str()) {
            return Err(refuse(format!(
                "not a sealed protocol 3 library (schema {schema:?})"
            )));
        }
        if meta(&c, "tombstone")?.as_deref() == Some("1") {
            return Ok(());
        }
        let into = meta(&c, "sealed_into")?.unwrap_or_default();
        let mut parts = Path::new(&into).components();
        let plain = matches!(
            (parts.next(), parts.next()),
            (Some(Component::Normal(_)), None)
        );
        let dir = path.parent().unwrap_or(Path::new(""));
        if !plain || !dir.join(&into).is_file() {
            return Err(refuse(format!(
                "sealed into {into:?}, which is not a file next to it"
            )));
        }
        Ok(())
    })();
    let closed = c.close().map_err(|(_, err)| refuse(err.to_string()));
    r.and(closed)
}

/// 在 [path]（保留副本 `srs.db`）放墓碑库：核对覆盖目标（[check_tombstone_target]）→ 写临时文件 → 落盘 → 旧库的
/// WAL 检查点进主文件并截断 → rename 覆盖。原路径不存在时直接放墓碑。出错时临时文件删掉、原路径原样不动。
///
/// 前提（调用方保证）：持有换代锁（`gen4::files::GenLock`），并且**本机没有任何进程开着旧库**——自己的连接已经
/// 全部关掉，协议 3 的内核也不在跑。别的连接正在事务里会被查出来报「in use」，但空闲的连接查不出来（见
/// `drain_wal`）：Unix 上覆盖之后它写的东西会丢。
pub fn write_tombstone(path: &Path) -> Result<(), String> {
    if path.exists() {
        check_tombstone_target(path)?;
    }
    let tmp = with_suffix(path, TOMBSTONE_TMP_SUFFIX);
    // 上一次中途崩溃留下的临时文件：不完整也没关系，整个重写。
    remove_sqlite_files(&tmp)?;
    let r = (|| {
        build_tombstone(&tmp)?;
        if path.exists() {
            // 旧库的 WAL 里可能还有没检查点的页（包括封存那一笔）：先全部落进主文件、WAL 截成空，rename 之后原路径
            // 旁边就不会留着一份属于旧库的 WAL 被套到墓碑上。
            drain_wal(path)?;
        }
        rename_durable(&tmp, path)
    })();
    if r.is_err() {
        let _ = remove_sqlite_files(&tmp);
    }
    r
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::SrsCore;
    use crate::store::sync2::tests::tempdir;

    /// SQLite 文件头里旧版本拒绝时也会改的两处计数字段（24–27 文件改动计数、92–95 version-valid-for；设计 §6.1 末
    /// 「已知例外」）。比页内容时把它们抹掉。
    fn masked(bytes: &[u8]) -> Vec<u8> {
        let mut b = bytes.to_vec();
        b[24..28].fill(0);
        b[92..96].fill(0);
        b
    }

    fn meta_rows(path: &Path) -> Vec<(String, String)> {
        let c = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_WRITE).unwrap();
        let rows = c
            .prepare("SELECT key, value FROM srs_meta ORDER BY key")
            .unwrap()
            .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        rows
    }

    /// 一份新建的协议 3 库（v29，带几行 `srs_meta`），关掉内核，WAL 全部落盘。
    fn legacy_db(dir: &Path) -> PathBuf {
        let path = dir.join("srs.db");
        drop(SrsCore::open(&path).unwrap());
        drain_wal(&path).unwrap();
        path
    }

    fn assert_refused_without_change(path: &Path) {
        let before = fs::read(path).unwrap();
        let meta_before = meta_rows(path);
        let err = SrsCore::open(path).err().expect("protocol 3 must refuse");
        assert!(err.contains("is newer than this build"), "{err}");
        // 旧内核关库时把它留下的 WAL 检查点回主文件；之后再比（拒绝时它只写过文件头的计数字段）。
        let _ = drain_wal(path);
        let after = fs::read(path).unwrap();
        assert_eq!(before.len(), after.len());
        assert!(masked(&before) == masked(&after), "page content changed");
        assert_eq!(meta_rows(path), meta_before);
    }

    #[test]
    fn a_sealed_library_is_refused_by_protocol_3_and_its_pages_stay() {
        let dir = tempdir::new("seal");
        let path = legacy_db(&dir.0);
        let c = Connection::open(&path).unwrap();
        // 一行业务数据：封存不能碰它。
        c.execute(
            "INSERT INTO srs_meta (key, value) VALUES ('probe', 'kept')",
            [],
        )
        .unwrap();
        seal_legacy(&c, "srs4.db").unwrap();
        // 重做是幂等的；换一个目标、或在事务里调都拒绝。
        seal_legacy(&c, "srs4.db").unwrap();
        assert!(
            seal_legacy(&c, "other.db")
                .unwrap_err()
                .contains("already sealed")
        );
        c.execute_batch("BEGIN").unwrap();
        assert!(
            seal_legacy(&c, "srs4.db")
                .unwrap_err()
                .contains("inside a transaction")
        );
        c.execute_batch("ROLLBACK").unwrap();
        drop(c);
        drain_wal(&path).unwrap();
        let rows = meta_rows(&path);
        let get = |k: &str| {
            rows.iter()
                .find(|(key, _)| key == k)
                .map(|(_, v)| v.as_str())
        };
        assert_eq!(get("schema"), Some("39999"));
        assert_eq!(get("sealed_into"), Some("srs4.db"));
        assert_eq!(
            get("sealed_from"),
            Some(SCHEMA_VERSION.to_string().as_str())
        );
        assert_eq!(get("probe"), Some("kept"));
        assert_refused_without_change(&path);
        // 新代的打开也不认它。
        let err = crate::store::gen4::schema::open(&path).unwrap_err();
        assert!(err.contains("sealed protocol 3 library"), "{err}");
        assert_refused_without_change(&path);
    }

    /// 设计 §6.3「回退到旧版本」的另一个方向：有人把新代库 `srs4.db` 拷成 `srs.db`（或回退后的旧版本在别处读到
    /// 一份新代文件）。协议 3 的内核读到 `schema` 比自己大就拒绝，页内容一个字节不改，新代照常能打开它。
    #[test]
    fn a_generation_4_library_copied_under_the_old_name_is_refused_by_protocol_3() {
        let dir = tempdir::new("seal-g4-as-old");
        let gen4 = dir.0.join("srs4.db");
        let c = crate::store::gen4::schema::open(&gen4).unwrap();
        c.execute(
            "INSERT INTO srs_meta (key, value) VALUES ('probe', 'kept')",
            [],
        )
        .unwrap();
        drop(c);
        drain_wal(&gen4).unwrap();
        let path = dir.0.join("srs.db");
        fs::copy(&gen4, &path).unwrap();
        assert_refused_without_change(&path);
        assert!(meta_rows(&path).contains(&(
            "schema".to_owned(),
            crate::store::gen4::schema::SCHEMA.to_string()
        )));
        drop(crate::store::gen4::schema::open(&path).unwrap());
    }

    thread_local! {
        static TRACED: std::cell::RefCell<Vec<String>> = const { std::cell::RefCell::new(Vec::new()) };
    }

    fn record_sql(ev: rusqlite::trace::TraceEvent<'_>) {
        if let rusqlite::trace::TraceEvent::Stmt(_, sql) = ev {
            TRACED.with(|t| {
                t.borrow_mut()
                    .push(sql.trim().trim_end_matches(';').to_owned())
            });
        }
    }

    /// 封存时连接临时切到 `synchronous = FULL`（提交即 fsync），封存那一笔在 FULL 下提交；不管成败都改回调用方
    /// 原来的设置。
    #[test]
    fn sealing_restores_the_callers_sync_setting() {
        let dir = tempdir::new("seal-sync");
        let path = legacy_db(&dir.0);
        let c = Connection::open(&path).unwrap();
        c.execute_batch("PRAGMA synchronous = NORMAL;").unwrap();
        TRACED.with(|t| t.borrow_mut().clear());
        let stmt = rusqlite::trace::TraceEventCodes::SQLITE_TRACE_STMT;
        c.trace_v2(stmt, Some(record_sql));
        seal_legacy(&c, "srs4.db").unwrap();
        c.trace_v2(stmt, None);
        let traced = TRACED.with(|t| t.take());
        let at = |want: &str| {
            traced
                .iter()
                .position(|s| s.eq_ignore_ascii_case(want))
                .unwrap_or_else(|| panic!("{want} not executed: {traced:?}"))
        };
        let full = at("PRAGMA synchronous = FULL");
        let commit = at("COMMIT");
        let back = at("PRAGMA synchronous = 1");
        assert!(full < commit && commit < back, "{traced:?}");
        assert!(
            traced[full + 1..commit]
                .iter()
                .all(|s| !s.to_ascii_uppercase().starts_with("PRAGMA SYNCHRONOUS"))
                && traced[full + 1..commit]
                    .iter()
                    .any(|s| s.contains("srs_meta")),
            "{traced:?}"
        );
        let sync = |c: &Connection| -> i64 {
            c.query_row("PRAGMA synchronous", [], |r| r.get(0)).unwrap()
        };
        c.execute_batch("PRAGMA synchronous = NORMAL;").unwrap();
        seal_legacy(&c, "srs4.db").unwrap();
        assert_eq!(sync(&c), 1, "NORMAL restored");
        assert!(meta_rows(&path).contains(&("schema".to_owned(), "39999".to_owned())));
        // 出错的路径也改回原值。
        c.execute_batch("PRAGMA synchronous = OFF;").unwrap();
        assert!(seal_legacy(&c, "other.db").is_err());
        assert_eq!(sync(&c), 0);
    }

    /// 墓碑只盖在封存过、数据确实已经在新代文件里的库上：没封存的 v29 库、空库（零字节 / 有文件头没表）、不是
    /// SQLite 的文件、封存目标不在同一个目录里的库都拒绝，原文件逐字节不变、临时文件不留。
    #[test]
    fn a_tombstone_never_replaces_something_that_is_not_a_finished_retained_copy() {
        let dir = tempdir::new("tomb-target");
        let refused = |path: &Path| {
            let before = fs::read(path).unwrap();
            let err = write_tombstone(path).unwrap_err();
            assert!(err.contains("refusing to replace"), "{err}");
            assert_eq!(fs::read(path).unwrap(), before);
            assert!(!with_suffix(path, TOMBSTONE_TMP_SUFFIX).exists());
            assert!(!with_suffix(path, "-wal").exists());
        };
        // 没封存的 v29 库。
        let v29 = legacy_db(&dir.0);
        refused(&v29);
        assert!(SrsCore::open(&v29).is_ok());
        // 零字节；有文件头、一张表也没有。
        let empty = dir.0.join("empty.db");
        fs::write(&empty, b"").unwrap();
        refused(&empty);
        let no_tables = dir.0.join("no-tables.db");
        Connection::open(&no_tables)
            .unwrap()
            .execute_batch("PRAGMA user_version = 7;")
            .unwrap();
        assert!(fs::metadata(&no_tables).unwrap().len() > 0);
        refused(&no_tables);
        // 不是 SQLite 的文件。
        let junk = dir.0.join("junk.db");
        fs::write(&junk, b"not a database at all. ".repeat(100)).unwrap();
        refused(&junk);
        // 封存了，但封存目标不在旁边 / 不是同目录里的文件名。
        let c = Connection::open(&v29).unwrap();
        seal_legacy(&c, "srs4.db").unwrap();
        drop(c);
        drain_wal(&v29).unwrap();
        refused(&v29);
        let elsewhere = tempdir::new("tomb-target-elsewhere");
        fs::write(elsewhere.0.join("srs4.db"), b"").unwrap();
        let far = elsewhere.0.join("srs4.db").to_string_lossy().into_owned();
        Connection::open(&v29)
            .unwrap()
            .execute(
                "UPDATE srs_meta SET value = ?1 WHERE key = 'sealed_into'",
                [&far],
            )
            .unwrap();
        drain_wal(&v29).unwrap();
        refused(&v29);
        // 目标放回同目录：可以盖了。
        Connection::open(&v29)
            .unwrap()
            .execute(
                "UPDATE srs_meta SET value = 'srs4.db' WHERE key = 'sealed_into'",
                [],
            )
            .unwrap();
        drain_wal(&v29).unwrap();
        fs::write(dir.0.join("srs4.db"), b"").unwrap();
        write_tombstone(&v29).unwrap();
        assert!(meta_rows(&v29).contains(&("tombstone".to_owned(), "1".to_owned())));
    }

    /// 身份 = 各 profile 的设备 ID：没启用过协议 3 的库没有身份；两份各自建的库身份不同；读它不改库。
    #[test]
    fn the_identity_is_the_device_ids_and_absent_without_protocol_3() {
        const P: &str = crate::store::sync2::tests::P;
        let dir = tempdir::new("seal-identity");
        let path = legacy_db(&dir.0);
        let ro =
            |p: &Path| Connection::open_with_flags(p, OpenFlags::SQLITE_OPEN_READ_ONLY).unwrap();
        assert_eq!(legacy_identity(&ro(&path)), Ok(None));
        assert_eq!(
            legacy_identity(&Connection::open_in_memory().unwrap()),
            Ok(None)
        );
        let core = SrsCore::open(&path).unwrap();
        let device = core.sync2_identity(P, 1).unwrap()["device"]
            .as_str()
            .unwrap()
            .replace('-', "");
        drop(core);
        drain_wal(&path).unwrap();
        let before = fs::read(&path).unwrap();
        assert_eq!(legacy_identity(&ro(&path)), Ok(Some(device.clone())));
        assert_eq!(fs::read(&path).unwrap(), before);
        let other = tempdir::new("seal-identity-other");
        let other_path = other.0.join("srs.db");
        let core = SrsCore::open(&other_path).unwrap();
        core.sync2_identity(P, 1).unwrap();
        drop(core);
        let theirs = legacy_identity(&ro(&other_path)).unwrap().unwrap();
        assert_ne!(theirs, device);
    }

    /// 日志水位：没有身份 = None；只读；本机写一笔就变；封存（只改 `srs_meta`）不动它。
    #[test]
    fn the_log_mark_moves_with_every_write_but_not_with_the_seal() {
        const P: &str = crate::store::sync2::tests::P;
        let dir = tempdir::new("seal-logmark");
        let path = legacy_db(&dir.0);
        let ro =
            |p: &Path| Connection::open_with_flags(p, OpenFlags::SQLITE_OPEN_READ_ONLY).unwrap();
        assert_eq!(legacy_log_mark(&ro(&path)), Ok(None));
        let core = SrsCore::open(&path).unwrap();
        core.sync2_identity(P, 1).unwrap();
        drop(core);
        drain_wal(&path).unwrap();
        let before = fs::read(&path).unwrap();
        let m0 = legacy_log_mark(&ro(&path)).unwrap().unwrap();
        assert_eq!(fs::read(&path).unwrap(), before);
        let core = SrsCore::open(&path).unwrap();
        let input = serde_json::json!([{
            "e": crate::store::sync2::tests::deck_entity("0193a1b2-0000-7000-8000-00000000d001"),
            "note": "N1"
        }]);
        core.sync2_apply_local(P, 2, &input.to_string()).unwrap();
        drop(core);
        let m1 = legacy_log_mark(&ro(&path)).unwrap().unwrap();
        assert_ne!(m0, m1);
        let rw = Connection::open(&path).unwrap();
        seal_legacy(&rw, "srs4.db").unwrap();
        drop(rw);
        assert_eq!(legacy_log_mark(&ro(&path)).unwrap().unwrap(), m1);
    }

    /// 落盘改名：覆盖已有的目标；源不在时报错、目标原样。
    #[test]
    fn a_durable_rename_replaces_the_target_and_fails_cleanly() {
        let dir = tempdir::new("seal-rename");
        let (a, b) = (dir.0.join("a"), dir.0.join("b"));
        fs::write(&a, b"new").unwrap();
        fs::write(&b, b"old").unwrap();
        rename_durable(&a, &b).unwrap();
        assert!(!a.exists());
        assert_eq!(fs::read(&b).unwrap(), b"new");
        assert!(rename_durable(&a, &b).is_err());
        assert_eq!(fs::read(&b).unwrap(), b"new");
    }

    #[test]
    fn sealing_refuses_other_schemas() {
        let c = Connection::open_in_memory().unwrap();
        c.execute_batch(
            "CREATE TABLE srs_meta (key TEXT NOT NULL PRIMARY KEY, value TEXT NOT NULL);
             INSERT INTO srs_meta VALUES ('schema', '0');",
        )
        .unwrap();
        assert!(
            seal_legacy(&c, "srs4.db")
                .unwrap_err()
                .contains("cannot seal")
        );
        c.execute("UPDATE srs_meta SET value = '40006'", [])
            .unwrap();
        assert!(
            seal_legacy(&c, "srs4.db")
                .unwrap_err()
                .contains("cannot seal")
        );
        assert!(seal_legacy(&c, "").unwrap_err().contains("empty target"));
        // 比这一版旧的协议 3 库（v3.3.0 的 26）照封，记下原号。
        c.execute("UPDATE srs_meta SET value = '26' WHERE key = 'schema'", [])
            .unwrap();
        seal_legacy(&c, "srs4.db").unwrap();
        assert_eq!(
            meta(&c, "schema").unwrap().as_deref(),
            Some(SEALED_SCHEMA.to_string().as_str())
        );
        assert_eq!(meta(&c, "sealed_from").unwrap().as_deref(), Some("26"));
    }

    #[test]
    fn a_tombstone_replaces_the_retained_copy_and_is_refused() {
        let dir = tempdir::new("tomb");
        let path = legacy_db(&dir.0);
        fs::write(dir.0.join("srs4.db"), b"").unwrap();
        let c = Connection::open(&path).unwrap();
        seal_legacy(&c, "srs4.db").unwrap();
        drop(c);
        // 上一次中途崩溃留下的半截临时文件。
        let tmp = with_suffix(&path, TOMBSTONE_TMP_SUFFIX);
        fs::write(&tmp, b"half a tombstone").unwrap();
        write_tombstone(&path).unwrap();
        assert!(!tmp.exists());
        assert!(!with_suffix(&path, "-wal").exists());
        assert_eq!(
            meta_rows(&path),
            vec![
                ("schema".to_owned(), "39999".to_owned()),
                ("tombstone".to_owned(), "1".to_owned())
            ]
        );
        // 整个库只有 srs_meta 一张表，文件很小。
        let tables: i64 = Connection::open(&path)
            .unwrap()
            .query_row("SELECT COUNT(*) FROM sqlite_schema", [], |r| r.get(0))
            .unwrap();
        assert_eq!(tables, 2); // 表 + 它的主键索引
        assert!(fs::metadata(&path).unwrap().len() <= 3 * 4096);
        assert_refused_without_change(&path);
        let err = crate::store::gen4::schema::open(&path).unwrap_err();
        assert!(err.contains("sealed protocol 3 library"), "{err}");
        // 再放一次（保留副本已经是墓碑）也行；原路径不存在时直接放。
        write_tombstone(&path).unwrap();
        let fresh = dir.0.join("nothing-here.db");
        write_tombstone(&fresh).unwrap();
        assert_refused_without_change(&fresh);
    }

    /// 旧库还被别人开着（读事务挡住检查点）：不覆盖，原路径上还是完整的封存库，临时文件不留。
    #[test]
    fn a_tombstone_over_a_library_in_use_changes_nothing() {
        let dir = tempdir::new("tomb-busy");
        let path = legacy_db(&dir.0);
        fs::write(dir.0.join("srs4.db"), b"").unwrap();
        let c = Connection::open(&path).unwrap();
        seal_legacy(&c, "srs4.db").unwrap();
        let before_meta = meta_rows(&path);
        let reader = Connection::open(&path).unwrap();
        reader.execute_batch("BEGIN").unwrap();
        let _: i64 = reader
            .query_row("SELECT COUNT(*) FROM srs_meta", [], |r| r.get(0))
            .unwrap();
        let err = write_tombstone(&path).unwrap_err();
        assert!(err.contains("in use"), "{err}");
        assert!(!with_suffix(&path, TOMBSTONE_TMP_SUFFIX).exists());
        reader.execute_batch("ROLLBACK").unwrap();
        drop(reader);
        drop(c);
        assert_eq!(meta_rows(&path), before_meta);
        // 别人放手之后就能放墓碑。
        write_tombstone(&path).unwrap();
        assert_eq!(meta_rows(&path).len(), 2);
    }
}
