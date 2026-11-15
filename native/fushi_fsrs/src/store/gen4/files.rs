//! 新代的文件名、换代锁与打开模式（设计 §6.1 D8 / D10；规划 §1.4）。还没有调用方：C 入口
//! （`ffsrs_store_open_mode`、返回码 `STORE_NOT_MIGRATED` / `STORE_MIGRATING`）等 `store/ffi.rs` 的命令元数据线合入后另加。
//!
//! 一个 profile 目录里：
//!
//! - [LEGACY_FILE] `srs.db`：协议 3 的库。迁移提交后原位封存（`store::schema::seal_legacy`），保留副本到期后换成墓碑库。
//! - [GEN4_TEMP] `srs4.db-migrating`：迁移中的新代库。提交点 = 改名成 [GEN4_FILE]。
//! - [GEN4_FILE] `srs4.db`：新代库。它在 = 迁移已经提交。
//! - [GEN_LOCK_FILE] `srs.gen.lock`：换代锁（[GenLock]）。迁移全程持有；锁文件本身只建不删（删了别的进程可能锁在
//!   一个已经脱离目录的文件上）。
//!
//! 打开模式（[OpenMode]）：
//!
//! - **Primary**（主进程，唯一的写者，D10）：有新代库就打开（建缺的表）；没有新代库时，有旧库或迁移临时文件 =
//!   [OpenError::NotMigrated]（迁移由调用方另跑，G7-2），换代锁被别人拿着 = [OpenError::Migrating]，两样都没有（全新
//!   安装）就在锁里建一个空的新代库。
//! - **Secondary**（查词弹窗等辅助进程，只读）：不建库、不迁移、不建表；没有新代库就按锁的状态报
//!   [OpenError::Migrating] / [OpenError::NotMigrated]。打开的连接 `query_only`，写不进去。

use std::fs::{File, OpenOptions, TryLockError};
use std::path::Path;

use rusqlite::{Connection, OpenFlags};

use super::schema;

/// 新代库文件名。
pub const GEN4_FILE: &str = "srs4.db";
/// 迁移中的新代库文件名。
pub const GEN4_TEMP: &str = "srs4.db-migrating";
/// 换代锁文件名。
pub const GEN_LOCK_FILE: &str = "srs.gen.lock";
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
            OpenMode::Primary => Ok(schema::open(&path)?),
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
    // 全新安装：在锁里建空库（建表在一个事务里；半路崩溃留下的空文件下次照样当新文件建）。
    let conn = schema::open(&path)?;
    drop(lock);
    Ok(conn)
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
}
