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
use std::path::{Path, PathBuf};

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
/// 要求：库是这一版协议 3 的（`schema` = [SCHEMA_VERSION]），连接不在事务里。已经封存过、`sealed_into` 相同 = 什么也
/// 不写（提交点之后中断、下次启动重做时幂等：`gen4::files::open_gen4` 的 Primary 打开发现 `srs4.db` 在、`srs.db`
/// 还是协议 3 的就重做）；封存进了别的文件、或 schema 是别的值都报错、不改。
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
    let current = meta(&tx, "schema")?;
    match current.as_deref().map(str::parse::<i64>) {
        Some(Ok(v)) if v == SCHEMA_VERSION => {
            for (key, value) in [
                ("schema", SEALED_SCHEMA.to_string()),
                ("sealed_into", into.to_owned()),
                ("sealed_from", v.to_string()),
            ] {
                tx.execute(
                    "INSERT INTO srs_meta (key, value) VALUES (?1, ?2) \
                     ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                    [key, value.as_str()],
                )
                .map_err(e)?;
            }
            tx.commit().map_err(e)
        }
        Some(Ok(v)) if v == SEALED_SCHEMA => {
            let was = meta(&tx, "sealed_into")?;
            if was.as_deref() == Some(into) {
                Ok(())
            } else {
                Err(e(format!("already sealed into {was:?}, not {into}")))
            }
        }
        other => Err(e(format!(
            "cannot seal a library at schema {other:?} (this build seals {SCHEMA_VERSION})"
        ))),
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

#[cfg(not(unix))]
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

/// 在 [path]（保留副本 `srs.db`）放墓碑库：写临时文件 → 落盘 → 旧库的 WAL 检查点进主文件并截断 → rename 覆盖。
/// 原路径不存在时直接放墓碑。出错时临时文件删掉、原路径原样不动。
///
/// 前提（调用方保证）：持有换代锁（`gen4::files::GenLock`），并且**本机没有任何进程开着旧库**——自己的连接已经
/// 全部关掉，协议 3 的内核也不在跑。别的连接正在事务里会被查出来报「in use」，但空闲的连接查不出来（见
/// `drain_wal`）：Unix 上覆盖之后它写的东西会丢。
pub fn write_tombstone(path: &Path) -> Result<(), String> {
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
        fs::rename(&tmp, path)
            .map_err(|err| e(format!("rename onto {}: {err}", path.display())))?;
        if let Some(dir) = path.parent() {
            sync_dir(dir)?;
        }
        Ok(())
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

    /// 封存时连接临时切到 `synchronous = FULL`（提交即 fsync），不管成败都改回调用方原来的设置。
    #[test]
    fn sealing_restores_the_callers_sync_setting() {
        let dir = tempdir::new("seal-sync");
        let path = legacy_db(&dir.0);
        let c = Connection::open(&path).unwrap();
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

    #[test]
    fn sealing_refuses_other_schemas() {
        let c = Connection::open_in_memory().unwrap();
        c.execute_batch(
            "CREATE TABLE srs_meta (key TEXT NOT NULL PRIMARY KEY, value TEXT NOT NULL);
             INSERT INTO srs_meta VALUES ('schema', '28');",
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
    }

    #[test]
    fn a_tombstone_replaces_the_retained_copy_and_is_refused() {
        let dir = tempdir::new("tomb");
        let path = legacy_db(&dir.0);
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
