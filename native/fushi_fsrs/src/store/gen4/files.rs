//! 新代的文件名、换代锁与打开模式（设计 §6.1 D8 / D10；规划 §1.4）。还没有调用方：C 入口
//! （`ffsrs_store_open_mode`、返回码 `STORE_NOT_MIGRATED` / `STORE_MIGRATING`）等 `store/ffi.rs` 的命令元数据线合入后另加。
//!
//! 一个 profile 目录里：
//!
//! - [LEGACY_FILE] `srs.db`：协议 3 的库。迁移提交后原位封存（`store::schema::seal_legacy`），保留副本到期后换成墓碑库。
//! - [GEN4_TEMP] `srs4.db-migrating`：迁移中的新代库。提交点 = 改名成 [GEN4_FILE]。
//! - [GEN4_FILE] `srs4.db`：新代库。它在 = 迁移已经提交（全新安装也一样：库在 [GEN4_CREATING] 建好、落盘之后才改名
//!   到位，所以这个名字上永远不会出现建到一半的库）。
//! - [GEN4_CREATING] `srs4.db-creating`：全新安装时在锁里建空库用的临时名。只有拿着锁的进程碰它；崩溃留下的直接
//!   删掉重建（它不是迁移，没有要接着做的东西）。
//! - [GEN_LOCK_FILE] `srs.gen.lock`：换代锁（[GenLock]）。迁移全程持有；锁文件本身只建不删（删了别的进程可能锁在
//!   一个已经脱离目录的文件上）。
//!
//! 打开模式（[OpenMode]）：
//!
//! - **Primary**（主进程，唯一的写者，D10）：有新代库就打开（建缺的表）；没有新代库时，有旧库或迁移临时文件 =
//!   [OpenError::NotMigrated]（迁移由调用方另跑，G7-2），换代锁被别人拿着 = [OpenError::Migrating]，两样都没有（全新
//!   安装）就在锁里建一个空的新代库。
//!
//!   有新代库、换代锁没人拿、而 `srs.db` 还是协议 3 的库（没封存）：迁移提交之后、封存落盘之前断过电或崩过。打开前
//!   在锁里补做封存（`store::schema::seal_legacy`，幂等），不然旧版本会把它当正常库打开写入，那些写入永远进不了
//!   新代。锁被别人拿着时不补：正在迁移的那个进程自己会封。
//! - **Secondary**（查词弹窗等辅助进程，只读）：不建库、不迁移、不建表；没有新代库就按锁的状态报
//!   [OpenError::Migrating] / [OpenError::NotMigrated]。打开的连接 `query_only`，写不进去。

use std::fs::{File, OpenOptions, TryLockError};
use std::path::Path;

use rusqlite::{Connection, OpenFlags, OptionalExtension};

use super::schema;
use crate::store::seal;

/// 新代库文件名。
pub const GEN4_FILE: &str = "srs4.db";
/// 迁移中的新代库文件名。
pub const GEN4_TEMP: &str = "srs4.db-migrating";
/// 换代锁文件名。
pub const GEN_LOCK_FILE: &str = "srs.gen.lock";
/// 全新安装时建空库的临时文件名。
pub const GEN4_CREATING: &str = "srs4.db-creating";
/// 协议 3 的库文件名（冻结）。
pub const LEGACY_FILE: &str = "srs.db";

/// 换代锁：`srs.gen.lock` 上的跨进程独占文件锁（`File::try_lock`：Unix 上是 `flock`，Windows 上是 `LockFileEx`）。
/// 句柄在就持有，drop 即释放；进程死掉时由操作系统释放。同一进程里另开一个句柄也拿不到。
#[derive(Debug)]
pub struct GenLock {
    _file: File,
}

impl GenLock {
    /// 试着拿锁，不等：拿到 = `Some`，别人拿着 = `None`（迁移进行中）。目录不存在、锁文件建不出来等报错。
    pub fn try_acquire(dir: &Path) -> Result<Option<GenLock>, String> {
        let path = dir.join(GEN_LOCK_FILE);
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(&path)
            .map_err(|e| format!("gen4 lock: open {}: {e}", path.display()))?;
        match file.try_lock() {
            Ok(()) => Ok(Some(GenLock { _file: file })),
            Err(TryLockError::WouldBlock) => Ok(None),
            Err(TryLockError::Error(e)) => Err(format!("gen4 lock: lock {}: {e}", path.display())),
        }
    }
}

/// 打开模式。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum OpenMode {
    /// 主进程：唯一的写者，可以建库（迁移由调用方另跑）。
    Primary,
    /// 辅助进程：只读，不建库、不迁移。
    Secondary,
}

/// 打不开新代库的原因。前两种是代际状态（C 入口将来映射成 `STORE_NOT_MIGRATED` / `STORE_MIGRATING`），其余是错误。
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum OpenError {
    /// 还没有新代库（有旧库要迁移，或辅助进程比主进程先到）。
    NotMigrated,
    /// 另一个进程正拿着换代锁（迁移进行中）。
    Migrating,
    /// 别的错误（不是新代库、比本版本新、IO……）。
    Failed(String),
}

impl std::fmt::Display for OpenError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            OpenError::NotMigrated => f.write_str("gen4 store: not migrated yet"),
            OpenError::Migrating => f.write_str("gen4 store: migration in progress"),
            OpenError::Failed(e) => f.write_str(e),
        }
    }
}

impl From<String> for OpenError {
    fn from(e: String) -> Self {
        OpenError::Failed(e)
    }
}

/// 打开 [dir] 里的新代库（见文件头的打开模式）。返回的连接已经配好（WAL、页缓存）；Primary 的已经建齐表。
pub fn open_gen4(dir: &Path, mode: OpenMode) -> Result<Connection, OpenError> {
    let path = dir.join(GEN4_FILE);
    if path.exists() {
        return match mode {
            OpenMode::Primary => {
                if let Some(lock) = GenLock::try_acquire(dir)? {
                    finish_seal(dir)?;
                    drop(lock);
                }
                Ok(schema::open(&path)?)
            }
            OpenMode::Secondary => Ok(open_secondary(&path)?),
        };
    }
    let Some(lock) = GenLock::try_acquire(dir)? else {
        return Err(OpenError::Migrating);
    };
    // 拿锁之后再看一次：刚才那一下和拿锁之间别的进程可能刚提交完迁移。
    if path.exists() {
        drop(lock);
        return open_gen4(dir, mode);
    }
    if mode == OpenMode::Secondary || dir.join(LEGACY_FILE).exists() || dir.join(GEN4_TEMP).exists()
    {
        return Err(OpenError::NotMigrated);
    }
    // 全新安装：在锁里另起一个名字建好、落盘，再改名到位（文件头「它在 = 已提交」）。
    create_fresh(dir)?;
    let conn = schema::open(&path)?;
    drop(lock);
    Ok(conn)
}

/// 在 [GEN4_CREATING] 建一个空的新代库，关掉（最后一个连接关闭时 WAL 检查点进主文件、`-wal` 删掉）、落盘，再
/// rename 成 [GEN4_FILE]。调用方拿着换代锁。
fn create_fresh(dir: &Path) -> Result<(), String> {
    let tmp = dir.join(GEN4_CREATING);
    // 上一次建到一半崩溃留下的：整个重建。
    seal::remove_sqlite_files(&tmp)?;
    let r = (|| {
        let conn = schema::open(&tmp)?;
        conn.close().map_err(|(_, e)| schema::sql(e))?;
        if seal::with_suffix(&tmp, "-wal").exists() {
            return Err("gen4 store: the new library's WAL was not checkpointed".to_owned());
        }
        OpenOptions::new()
            .write(true)
            .open(&tmp)
            .and_then(|f| f.sync_all())
            .map_err(|e| format!("gen4 store: sync {}: {e}", tmp.display()))?;
        std::fs::rename(&tmp, dir.join(GEN4_FILE))
            .map_err(|e| format!("gen4 store: rename {}: {e}", tmp.display()))?;
        seal::sync_dir(dir)
    })();
    if r.is_err() {
        let _ = seal::remove_sqlite_files(&tmp);
    }
    r
}

/// 新代库已经在：`srs.db` 若还是协议 3 的库就补做封存（文件头「打开模式」）。已封存 / 墓碑 / 别的版本的协议 3
/// 库都不动。读不了它（被别的进程写锁住、不是 SQLite 文件……）报错：不能在旧版本还可能写它的状态下照常打开。
fn finish_seal(dir: &Path) -> Result<(), String> {
    let legacy = dir.join(LEGACY_FILE);
    if !legacy.exists() {
        return Ok(());
    }
    let fail = |e: String| format!("gen4 store: retained {}: {e}", legacy.display());
    let conn = Connection::open_with_flags(
        &legacy,
        OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .map_err(|e| fail(e.to_string()))?;
    let has_meta: bool = conn
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM sqlite_schema WHERE type = 'table' AND name = 'srs_meta')",
            [],
            |r| r.get(0),
        )
        .map_err(|e| fail(e.to_string()))?;
    if !has_meta {
        return Ok(());
    }
    let current: Option<String> = conn
        .query_row("SELECT value FROM srs_meta WHERE key = 'schema'", [], |r| {
            r.get(0)
        })
        .optional()
        .map_err(|e| fail(e.to_string()))?;
    if current.as_deref() == Some(crate::store::schema::SCHEMA_VERSION.to_string().as_str()) {
        crate::store::schema::seal_legacy(&conn, GEN4_FILE).map_err(fail)?;
    }
    conn.close().map_err(|(_, e)| fail(e.to_string()))
}

fn open_secondary(path: &Path) -> Result<Connection, String> {
    let conn = Connection::open_with_flags(
        path,
        OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .map_err(schema::sql)?;
    schema::check_ready(&conn)?;
    let mode: String = conn
        .query_row("PRAGMA journal_mode", [], |r| r.get(0))
        .map_err(schema::sql)?;
    if !mode.eq_ignore_ascii_case("wal") {
        return Err(format!("gen4 store: journal_mode is {mode}, expected wal"));
    }
    conn.execute_batch("PRAGMA query_only = 1; PRAGMA cache_size = -16384;")
        .map_err(schema::sql)?;
    Ok(conn)
}

#[cfg(test)]
mod tests {
    use std::io::{BufRead, BufReader, Write};
    use std::process::{Command, Stdio};

    use super::*;
    use crate::store::sync2::tests::tempdir;

    fn listing(dir: &Path) -> Vec<String> {
        let mut v: Vec<String> = std::fs::read_dir(dir)
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        v.sort();
        v
    }

    #[test]
    fn the_lock_excludes_a_second_handle_until_released() {
        let dir = tempdir::new("genlock");
        let a = GenLock::try_acquire(&dir.0).unwrap().expect("first");
        assert!(GenLock::try_acquire(&dir.0).unwrap().is_none());
        drop(a);
        let b = GenLock::try_acquire(&dir.0)
            .unwrap()
            .expect("after release");
        drop(b);
        assert!(dir.0.join(GEN_LOCK_FILE).exists());
        assert!(GenLock::try_acquire(&dir.0.join("missing")).is_err());
    }

    /// 子进程那一半：环境变量给了目录才动作。拿锁、报一行、等父进程关掉 stdin 再退出（退出即释放）。
    #[test]
    fn genlock_child_process_half() {
        let Ok(dir) = std::env::var("FUSHI_GENLOCK_CHILD_DIR") else {
            return;
        };
        let lock = GenLock::try_acquire(Path::new(&dir)).unwrap();
        println!(
            "GENLOCK_CHILD {}",
            if lock.is_some() { "held" } else { "busy" }
        );
        std::io::stdout().flush().unwrap();
        let mut sink = String::new();
        let _ = std::io::stdin().read_line(&mut sink);
        drop(lock);
    }

    /// 跨进程：子进程拿着锁时本进程拿不到、Primary / Secondary 都报迁移中；子进程退出后能拿到。
    #[test]
    fn the_lock_excludes_another_process() {
        let dir = tempdir::new("genlock-proc");
        std::fs::write(dir.0.join(LEGACY_FILE), b"").unwrap();
        let mut child = Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "store::gen4::files::tests::genlock_child_process_half",
                "--nocapture",
                "--test-threads=1",
            ])
            .env("FUSHI_GENLOCK_CHILD_DIR", &dir.0)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        let mut out = BufReader::new(child.stdout.take().unwrap());
        let mut state = String::new();
        let mut line = String::new();
        while out.read_line(&mut line).unwrap() > 0 {
            // libtest 把「test 名字 ... 」打在同一行前面：按标记找，不按行首。
            if let Some(at) = line.find("GENLOCK_CHILD ") {
                state = line[at + "GENLOCK_CHILD ".len()..].trim().to_owned();
                break;
            }
            line.clear();
        }
        assert_eq!(state, "held");
        assert!(GenLock::try_acquire(&dir.0).unwrap().is_none());
        assert_eq!(
            open_gen4(&dir.0, OpenMode::Primary).unwrap_err(),
            OpenError::Migrating
        );
        assert_eq!(
            open_gen4(&dir.0, OpenMode::Secondary).unwrap_err(),
            OpenError::Migrating
        );
        drop(child.stdin.take());
        let mut rest = String::new();
        let _ = std::io::Read::read_to_string(&mut out, &mut rest);
        assert!(child.wait().unwrap().success(), "{rest}");
        assert!(GenLock::try_acquire(&dir.0).unwrap().is_some());
    }

    #[test]
    fn secondary_never_creates_and_refuses_until_there_is_a_generation_4_library() {
        let dir = tempdir::new("open-secondary");
        // 空目录：辅助进程不建库（只会建出锁文件：要试锁才分得清「迁移中」与「还没迁移」）。
        assert_eq!(
            open_gen4(&dir.0, OpenMode::Secondary).unwrap_err(),
            OpenError::NotMigrated
        );
        assert!(!dir.0.join(GEN4_FILE).exists());
        // 有旧库、有迁移临时文件：一样。
        std::fs::write(dir.0.join(LEGACY_FILE), b"").unwrap();
        std::fs::write(dir.0.join(GEN4_TEMP), b"").unwrap();
        assert_eq!(
            open_gen4(&dir.0, OpenMode::Secondary).unwrap_err(),
            OpenError::NotMigrated
        );
        let before = listing(&dir.0);
        // 迁移中（锁在别人手里）。
        let lock = GenLock::try_acquire(&dir.0).unwrap().unwrap();
        assert_eq!(
            open_gen4(&dir.0, OpenMode::Secondary).unwrap_err(),
            OpenError::Migrating
        );
        drop(lock);
        assert_eq!(listing(&dir.0), before);
        // 一个空的 srs4.db（不是建好的库）：辅助进程不替它建表。
        std::fs::write(dir.0.join(GEN4_FILE), b"").unwrap();
        let e = open_gen4(&dir.0, OpenMode::Secondary).unwrap_err();
        assert!(e.to_string().contains("empty"), "{e}");
        assert_eq!(std::fs::metadata(dir.0.join(GEN4_FILE)).unwrap().len(), 0);
    }

    #[test]
    fn primary_reports_the_generation_state_and_creates_only_on_a_fresh_install() {
        let dir = tempdir::new("open-primary");
        std::fs::write(dir.0.join(LEGACY_FILE), b"").unwrap();
        assert_eq!(
            open_gen4(&dir.0, OpenMode::Primary).unwrap_err(),
            OpenError::NotMigrated
        );
        std::fs::remove_file(dir.0.join(LEGACY_FILE)).unwrap();
        std::fs::write(dir.0.join(GEN4_TEMP), b"").unwrap();
        assert_eq!(
            open_gen4(&dir.0, OpenMode::Primary).unwrap_err(),
            OpenError::NotMigrated
        );
        assert!(!dir.0.join(GEN4_FILE).exists());
        std::fs::remove_file(dir.0.join(GEN4_TEMP)).unwrap();
        // 全新安装：建库，锁已经放掉。
        let conn = open_gen4(&dir.0, OpenMode::Primary).unwrap();
        let app: i32 = conn
            .query_row("PRAGMA application_id", [], |r| r.get(0))
            .unwrap();
        assert_eq!(app, schema::APPLICATION_ID);
        assert!(GenLock::try_acquire(&dir.0).unwrap().is_some());
        drop(conn);
        // 辅助进程现在能开，但写不进去；主进程再开照常。
        let ro = open_gen4(&dir.0, OpenMode::Secondary).unwrap();
        let n: i64 = ro
            .query_row("SELECT COUNT(*) FROM collections", [], |r| r.get(0))
            .unwrap();
        assert_eq!(n, 0);
        let e = ro
            .execute("INSERT INTO srs_meta (key, value) VALUES ('x', 'y')", [])
            .unwrap_err();
        assert!(e.to_string().contains("readonly"), "{e}");
        let rw = open_gen4(&dir.0, OpenMode::Primary).unwrap();
        rw.execute("INSERT INTO srs_meta (key, value) VALUES ('x', 'y')", [])
            .unwrap();
    }

    /// 新代库被当成别的东西：协议 3 的库拷成 srs4.db，两种模式都拒绝、不改它。
    #[test]
    fn a_protocol_3_library_under_the_new_name_is_refused() {
        let dir = tempdir::new("open-wrong-kind");
        let path = dir.0.join(GEN4_FILE);
        {
            let c = Connection::open(&path).unwrap();
            c.execute_batch(
                "CREATE TABLE srs_meta (key TEXT NOT NULL PRIMARY KEY, value TEXT NOT NULL);
                 INSERT INTO srs_meta VALUES ('schema', '29');",
            )
            .unwrap();
        }
        let before = std::fs::read(&path).unwrap();
        for mode in [OpenMode::Primary, OpenMode::Secondary] {
            let e = open_gen4(&dir.0, mode).unwrap_err().to_string();
            assert!(e.contains("protocol 3 library"), "{mode:?}: {e}");
        }
        assert_eq!(std::fs::read(&path).unwrap(), before);
    }

    /// 全新安装经临时名建好再改名：完了目录里只有新代库与锁文件；上一次建到一半留下的临时文件被重建掉。
    #[test]
    fn a_fresh_install_appears_under_the_final_name_only_when_complete() {
        let dir = tempdir::new("open-fresh");
        std::fs::write(dir.0.join(GEN4_CREATING), b"half a library").unwrap();
        std::fs::write(seal::with_suffix(&dir.0.join(GEN4_CREATING), "-wal"), b"x").unwrap();
        let conn = open_gen4(&dir.0, OpenMode::Primary).unwrap();
        drop(conn);
        assert_eq!(
            listing(&dir.0),
            vec![GEN_LOCK_FILE.to_owned(), GEN4_FILE.to_owned()]
        );
        let ro = open_gen4(&dir.0, OpenMode::Secondary).unwrap();
        let v: String = ro
            .query_row("SELECT value FROM srs_meta WHERE key = 'schema'", [], |r| {
                r.get(0)
            })
            .unwrap();
        assert_eq!(v, schema::SCHEMA.to_string());
    }

    fn legacy_schema(dir: &Path) -> String {
        Connection::open(dir.join(LEGACY_FILE))
            .unwrap()
            .query_row("SELECT value FROM srs_meta WHERE key = 'schema'", [], |r| {
                r.get(0)
            })
            .unwrap()
    }

    /// 迁移提交了、封存那一笔没落盘（`srs4.db` 在、`srs.db` 还是协议 3 的）：Primary 打开时在锁里补封；锁被别人拿着
    /// （迁移进程还在提交点与封存之间）时不补；Secondary 从不写它。
    #[test]
    fn primary_finishes_a_lost_seal_before_opening() {
        let dir = tempdir::new("open-reseal");
        drop(open_gen4(&dir.0, OpenMode::Primary).unwrap());
        drop(crate::store::SrsCore::open(&dir.0.join(LEGACY_FILE)).unwrap());
        let v3 = crate::store::schema::SCHEMA_VERSION.to_string();
        assert_eq!(legacy_schema(&dir.0), v3);
        drop(open_gen4(&dir.0, OpenMode::Secondary).unwrap());
        assert_eq!(legacy_schema(&dir.0), v3);
        let lock = GenLock::try_acquire(&dir.0).unwrap().unwrap();
        drop(open_gen4(&dir.0, OpenMode::Primary).unwrap());
        assert_eq!(legacy_schema(&dir.0), v3);
        drop(lock);
        drop(open_gen4(&dir.0, OpenMode::Primary).unwrap());
        assert_eq!(
            legacy_schema(&dir.0),
            crate::store::schema::SEALED_SCHEMA.to_string()
        );
        let err = crate::store::SrsCore::open(&dir.0.join(LEGACY_FILE))
            .err()
            .expect("protocol 3 must refuse");
        assert!(err.contains("is newer than this build"), "{err}");
        // 已封存 / 墓碑：再开什么也不改。
        drop(open_gen4(&dir.0, OpenMode::Primary).unwrap());
        crate::store::schema::write_tombstone(&dir.0.join(LEGACY_FILE)).unwrap();
        drop(open_gen4(&dir.0, OpenMode::Primary).unwrap());
        assert_eq!(
            legacy_schema(&dir.0),
            crate::store::schema::SEALED_SCHEMA.to_string()
        );
    }
}
