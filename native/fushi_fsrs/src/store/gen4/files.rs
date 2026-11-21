//! 新代的文件名、换代锁与打开模式（设计 §6.1 D8 / D10；规划 §1.4）。还没有调用方：C 入口
//! （`ffsrs_store_open_mode`、返回码 `STORE_NOT_MIGRATED` / `STORE_MIGRATING`）等 `store/ffi.rs` 的命令元数据线合入后另加。
//!
//! 一个 profile 目录里：
//!
//! - [LEGACY_FILE] `srs.db`：协议 3 的库。迁移提交后原位封存（`store::schema::seal_legacy`），保留副本到期后换成墓碑库。
//! - [GEN4_TEMP] `srs4.db-migrating`：迁移中的新代库。提交点 = 改名成 [GEN4_FILE]。
//! - [GEN4_FILE] `srs4.db`：新代库。它在 = 库是完整的（迁移已经提交；全新安装也一样：库在 [GEN4_CREATING] 建好、
//!   落盘之后才改名到位，所以这个名字上永远不会出现建到一半的库）。**它在不等于「旁边的 `srs.db` 已经迁进来了」**：
//!   迁移来的新代库在 `srs_meta` 里带 [MIGRATED_FROM_KEY]（迁移来源那份协议 3 库的身份，`store::seal::legacy_identity`；
//!   设计 §6.1 第 7 步的「已核对」标记），在临时文件里写好、随改名一起提交（[record_migrated_from]）；全新安装建的
//!   没有这一行。
//! - [GEN4_CREATING] `srs4.db-creating`：全新安装时在锁里建空库用的临时名。只有拿着锁的进程碰它；崩溃留下的直接
//!   删掉重建（它不是迁移，没有要接着做的东西）。
//! - [GEN_LOCK_FILE] `srs.gen.lock`：换代锁（[GenLock]）。迁移全程持有；锁文件本身只建不删（删了别的进程可能锁在
//!   一个已经脱离目录的文件上）。
//!
//! 打开模式（[OpenMode]）：
//!
//! - **Primary**（主进程，唯一的写者，D10）：有新代库就打开——先核对这个名字上是建好的新代库（非空、魔数、schema
//!   号），不是就报错、什么都不动（不看 `srs.db`、不建表）；是才处理旁边的 `srs.db`（下文）、建缺的表。没有新代库时，有旧库或迁移临时文件 =
//!   [OpenError::NotMigrated]（迁移由调用方另跑，G7-2），换代锁被别人拿着 = [OpenError::Migrating]，两样都没有（全新
//!   安装）就在锁里建一个空的新代库。
//!
//!   有新代库、换代锁没人拿、而 `srs.db` 还是协议 3 的库（没封存），看新代库记的迁移来源：
//!
//!   - 来源就是这份 `srs.db`（身份相同，日志水位 [MIGRATED_LOG_KEY] 也相同——中断之后旧版本没往里写过）：迁移提交
//!     之后、封存落盘之前断过电或崩过。在锁里补做封存
//!     （`store::schema::seal_legacy`，幂等），不然旧版本会把它当正常库打开写入，那些写入永远进不了新代。
//!   - 没有来源（全新安装建的新代库）、来源是另一份库、或来源是它但中断之后又被写过：这份 `srs.db` 没迁移过（协议 3 的版本在同一个目录里跑过、
//!     备份还原放回来的……）。**不封、不改它**，报 [OpenError::LegacyNotMigrated]——封了等于把没进新代的数据标成
//!     「已迁入」，两个版本都读不到。并入还是提示由调用方定（G7-2）。
//!
//!   锁被别人拿着时不看：正在迁移的那个进程自己会封。
//! - **Secondary**（查词弹窗等辅助进程，只读）：不建库、不迁移、不建表；没有新代库就按锁的状态报
//!   [OpenError::Migrating] / [OpenError::NotMigrated]。打开的连接 `query_only`，写不进去。

use std::fs::{File, OpenOptions};
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
/// 迁移的前提补完（`prepare.rs`，G7-2b）用的旧库副本：补完只写它，[LEGACY_FILE] 在提交点之前一个字节不写（协议 3 的
/// 旧版本随时还能打开原件）。迁移结束（不论结论）删掉；崩溃留下的由下一次迁移或 Primary 打开删掉。
pub const PREPARE_COPY: &str = "srs.db-gen4-prepare";
/// 新代库 `srs_meta` 里的迁移来源标记：值 = 迁移来源那份协议 3 库的身份（`store::seal::legacy_identity`；原件没有
/// 身份时是 [NO_IDENTITY]，见 [source_mark]）。只有迁移提交出来的新代库有；全新安装建的没有。
pub const MIGRATED_FROM_KEY: &str = "migrated_from";
/// 新代库 `srs_meta` 里迁移来源的日志水位（`store::seal::legacy_log_mark`；原件没有身份时是全部内容的摘要，见
/// [source_mark]），与 [MIGRATED_FROM_KEY] 同时写、同时有。
/// 补封（[finish_seal]）时身份与水位都得对上：改名之后、封存之前进程被杀，旧版本趁写锁释放往 `srs.db` 写了东西的，
/// 水位就对不上，不封（那几笔写入没进新代）。
pub const MIGRATED_LOG_KEY: &str = "migrated_log";

/// 换代锁：`srs.gen.lock` 上的跨进程独占文件锁（Unix / Android 直接调 `flock`，避免 Rust 标准库
/// `File::try_lock` 在 Android 上返回 `try_lock() not supported`；Windows 用 `File::try_lock` / `LockFileEx`）。
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
        match try_lock_exclusive(&file) {
            Ok(true) => Ok(Some(GenLock { _file: file })),
            Ok(false) => Ok(None),
            Err(e) => Err(format!("gen4 lock: lock {}: {e}", path.display())),
        }
    }
}

/// 非阻塞独占锁：拿到 = `Ok(true)`，已被别的句柄持有 = `Ok(false)`。
#[cfg(unix)]
fn try_lock_exclusive(file: &File) -> std::io::Result<bool> {
    use std::io::ErrorKind;
    use std::os::fd::AsRawFd;

    let fd = file.as_raw_fd();
    loop {
        // SAFETY: fd 来自有效打开的 File 句柄，本调用期间未被关闭；flock 仅操作内核文件锁。
        if unsafe { libc::flock(fd, libc::LOCK_EX | libc::LOCK_NB) } == 0 {
            return Ok(true);
        }
        let err = std::io::Error::last_os_error();
        match err.kind() {
            ErrorKind::Interrupted => continue,
            ErrorKind::WouldBlock => return Ok(false),
            _ => return Err(err),
        }
    }
}

/// 非阻塞独占锁：拿到 = `Ok(true)`，已被别的句柄持有 = `Ok(false)`。
#[cfg(not(unix))]
fn try_lock_exclusive(file: &File) -> std::io::Result<bool> {
    use std::fs::TryLockError;

    match file.try_lock() {
        Ok(()) => Ok(true),
        Err(TryLockError::WouldBlock) => Ok(false),
        Err(TryLockError::Error(e)) => Err(e),
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

/// 打不开新代库的原因。前三种是代际状态（C 入口将来映射成返回码，前两种是 `STORE_NOT_MIGRATED` /
/// `STORE_MIGRATING`），其余是错误。
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum OpenError {
    /// 还没有新代库（有旧库要迁移，或辅助进程比主进程先到）。
    NotMigrated,
    /// 另一个进程正拿着换代锁（迁移进行中）。
    Migrating,
    /// 新代库在，旁边还有一份没封存、也不是它迁移来源的协议 3 库（文件头「打开模式」）。那份库原样没动。
    LegacyNotMigrated,
    /// 别的错误（不是新代库、比本版本新、IO……）。
    Failed(String),
}

impl std::fmt::Display for OpenError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            OpenError::NotMigrated => f.write_str("gen4 store: not migrated yet"),
            OpenError::Migrating => f.write_str("gen4 store: migration in progress"),
            OpenError::LegacyNotMigrated => f.write_str(
                "gen4 store: an unmigrated protocol 3 library sits next to the generation 4 library",
            ),
            OpenError::Failed(e) => f.write_str(e),
        }
    }
}

impl From<String> for OpenError {
    fn from(e: String) -> Self {
        OpenError::Failed(e)
    }
}

/// [open_gen4] 打开的结果。
#[derive(Debug)]
pub struct Opened {
    /// 新代库的连接：已经配好（WAL、页缓存）；Primary 的已经建齐表。
    pub conn: Connection,
    /// 保留副本 `srs.db` 在、但不是 SQLite 文件（打开 / 读它报 `SQLITE_NOTADB`）。旧版本同样拒绝打开它，所以不挡新代库，
    /// 但用户的保留副本已经没法用了：这个状态向上报，由 G7-5 的状态枚举呈现。只有 Primary 拿到换代锁、检查过
    /// `srs.db` 时才可能置位；Secondary 与锁被别人拿着时不看它，恒为 `false`。
    pub retained_copy_unreadable: bool,
}

/// 打开 [dir] 里的新代库（见文件头的打开模式）。
pub fn open_gen4(dir: &Path, mode: OpenMode) -> Result<Opened, OpenError> {
    let path = dir.join(GEN4_FILE);
    if path.exists() {
        return match mode {
            OpenMode::Primary => {
                // 先确认这个名字上是一份建好的新代库（非空、魔数与 schema 号对），再碰旁边的 `srs.db`、再建缺的表：
                // 「它在 = 已提交」是这里的前提，零字节 / 协议 3 / 别的文件顶着这个名字时什么都不改（不封存、不建表），
                // 不然会封掉真正的数据、换上一个空库。
                let ready = open_ready(&path)?;
                let mut retained_copy_unreadable = false;
                if let Some(lock) = GenLock::try_acquire(dir)? {
                    retained_copy_unreadable = finish_seal(dir, &ready)? == Retained::Unreadable;
                    // 保留副本到期自动删（`retained.rs`，D32）：没做成不挡开库，原因记进库里给设置页 / ctl 看。
                    if !retained_copy_unreadable {
                        if let Err(e) = super::retained::sweep(dir, &ready, super::dryrun::now_ms())
                        {
                            super::retained::note_error(&ready, &e).map_err(OpenError::Failed)?;
                        }
                    }
                    // 迁移在提交点之后崩溃留下的前提补完副本：迁移已经提交，它没有用了。
                    seal::remove_sqlite_files(&dir.join(PREPARE_COPY))
                        .map_err(OpenError::Failed)?;
                    drop(lock);
                }
                ready.close().map_err(|(_, e)| schema::sql(e))?;
                Ok(Opened {
                    conn: schema::open(&path)?,
                    retained_copy_unreadable,
                })
            }
            OpenMode::Secondary => Ok(Opened {
                conn: open_secondary(&path)?,
                retained_copy_unreadable: false,
            }),
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
    Ok(Opened {
        conn,
        retained_copy_unreadable: false,
    })
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
        seal::rename_durable(&tmp, &dir.join(GEN4_FILE))
    })();
    if r.is_err() {
        let _ = seal::remove_sqlite_files(&tmp);
    }
    r
}

/// [MIGRATED_FROM_KEY] 在迁移来源没有协议 3 身份时的值。
pub const NO_IDENTITY: &str = "-";

/// 一份协议 3 库作为迁移来源的指纹：(身份, 水位)。有身份 = (`seal::legacy_identity`, `seal::legacy_log_mark`)。
/// 没有身份（从没启用过协议 3、或只在投影表里有数据：前提补完在副本里才给它建身份，原件没有）= ([NO_IDENTITY],
/// 除 `srs_meta` 以外全部表的内容摘要，[content_digest])——封存只改 `srs_meta`，所以封存前后指纹相同；别的任何写入
/// 都会改它。只读。
pub(crate) fn source_mark(legacy: &Connection) -> Result<(String, String), String> {
    if let Some(identity) = seal::legacy_identity(legacy)? {
        let log = seal::legacy_log_mark(legacy)?
            .ok_or_else(|| "gen4 store: a protocol 3 identity without a log mark".to_owned())?;
        return Ok((identity, log));
    }
    Ok((NO_IDENTITY.to_owned(), content_digest(legacy)?))
}

#[cfg(test)]
thread_local! {
    /// 测试：本线程算过几次 [content_digest]（「只算一次并记下结论」的测试按它数）。
    pub(crate) static DIGESTS: std::cell::Cell<u32> = const { std::cell::Cell::new(0) };
}

/// 除 `srs_meta` 与 SQLite 内部表以外全部表的内容摘要（blake3，小写十六进制）：表名有序，每表的行按「每行一个
/// blake3、逐位相加」合起来（与行序、规划器选的扫描方式无关）。只读存储列（生成列不算：不用注册 SQL 函数），一行
/// 一行流过、不整表进内存。只给没有身份的迁移来源用（[source_mark]），在提交与补封时各算一次。
fn content_digest(conn: &Connection) -> Result<String, String> {
    #[cfg(test)]
    DIGESTS.with(|n| n.set(n.get() + 1));
    let tables: Vec<String> = conn
        .prepare(
            "SELECT name FROM sqlite_schema WHERE type = 'table' AND substr(name, 1, 7) <> 'sqlite_' \
             AND name <> 'srs_meta' ORDER BY name",
        )
        .map_err(schema::sql)?
        .query_map([], |r| r.get(0))
        .map_err(schema::sql)?
        .collect::<Result<_, _>>()
        .map_err(schema::sql)?;
    let mut h = blake3::Hasher::new();
    for table in tables {
        let cols: Vec<String> = conn
            .prepare("SELECT name FROM pragma_table_xinfo(?1) WHERE hidden = 0 ORDER BY cid")
            .map_err(schema::sql)?
            .query_map([&table], |r| r.get(0))
            .map_err(schema::sql)?
            .collect::<Result<_, _>>()
            .map_err(schema::sql)?;
        let quote = |n: &str| format!("\"{}\"", n.replace('"', "\"\""));
        let list = cols.iter().map(|c| quote(c)).collect::<Vec<_>>().join(", ");
        let mut stmt = conn
            .prepare(&format!("SELECT {list} FROM {}", quote(&table)))
            .map_err(schema::sql)?;
        let n = stmt.column_count();
        let mut sum = [0u64; 4];
        let mut count = 0u64;
        let mut rows = stmt.query([]).map_err(schema::sql)?;
        while let Some(r) = rows.next().map_err(schema::sql)? {
            let mut rh = blake3::Hasher::new();
            for i in 0..n {
                match r.get_ref(i).map_err(schema::sql)? {
                    rusqlite::types::ValueRef::Null => {
                        rh.update(b"n");
                    }
                    rusqlite::types::ValueRef::Integer(v) => {
                        rh.update(b"i");
                        rh.update(&v.to_le_bytes());
                    }
                    rusqlite::types::ValueRef::Real(v) => {
                        rh.update(b"r");
                        rh.update(&v.to_le_bytes());
                    }
                    rusqlite::types::ValueRef::Text(b) => {
                        rh.update(b"t");
                        rh.update(&(b.len() as u64).to_le_bytes());
                        rh.update(b);
                    }
                    rusqlite::types::ValueRef::Blob(b) => {
                        rh.update(b"b");
                        rh.update(&(b.len() as u64).to_le_bytes());
                        rh.update(b);
                    }
                }
            }
            let d = rh.finalize();
            for (k, chunk) in d.as_bytes().chunks_exact(8).enumerate() {
                let mut word = [0u8; 8];
                word.copy_from_slice(chunk);
                sum[k] = sum[k].wrapping_add(u64::from_le_bytes(word));
            }
            count += 1;
        }
        h.update(&(table.len() as u64).to_le_bytes());
        h.update(table.as_bytes());
        h.update(&count.to_le_bytes());
        for v in sum {
            h.update(&v.to_le_bytes());
        }
    }
    Ok(h.finalize().to_hex().to_string())
}

/// 把迁移来源记进新代库：[new] = 迁移中的新代库（[GEN4_TEMP]，改名之前），[legacy] = 迁移来源那份协议 3 库**原件**
/// 的连接（只读它；前提补完写的是副本 [PREPARE_COPY]，补封时拿来核对的是原件）。记两行：身份（[MIGRATED_FROM_KEY]）
/// 与水位（[MIGRATED_LOG_KEY]），即 [source_mark]。
pub fn record_migrated_from(new: &Connection, legacy: &Connection) -> Result<(), String> {
    let (source, log) = source_mark(legacy)?;
    for (key, value) in [(MIGRATED_FROM_KEY, source), (MIGRATED_LOG_KEY, log)] {
        new.execute(
            "INSERT INTO srs_meta (key, value) VALUES (?1, ?2) \
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            [key, value.as_str()],
        )
        .map_err(schema::sql)?;
    }
    Ok(())
}

/// 新代库 [new] 记的迁移来源是不是 [legacy] 这份协议 3 库、而且是它现在这个样子：身份（[MIGRATED_FROM_KEY]）与
/// 水位（[MIGRATED_LOG_KEY]）都记着、都与 [legacy] 现在的 [source_mark] 相同。没记来源（全新安装）= 不是。
pub(crate) fn migrated_from_is(new: &Connection, legacy: &Connection) -> Result<bool, String> {
    let meta = |key: &str| -> Result<Option<String>, String> {
        new.query_row("SELECT value FROM srs_meta WHERE key = ?1", [key], |r| {
            r.get(0)
        })
        .optional()
        .map_err(schema::sql)
    };
    let (Some(source), Some(log)) = (meta(MIGRATED_FROM_KEY)?, meta(MIGRATED_LOG_KEY)?) else {
        return Ok(false);
    };
    // 先比身份（一次点读）：一边有身份、一边没有就不是，不必算整库摘要（[source_mark] 没有身份时要扫全部表）。
    let identity = seal::legacy_identity(legacy)?;
    if identity.is_some() != (source != NO_IDENTITY) {
        return Ok(false);
    }
    Ok(source_mark(legacy)? == (source, log))
}

/// 新代库 `srs_meta` 里记的结论：旁边那份 `srs.db` 在某个文件状态下**不是**迁移来源（值 = 当时的 [file_state]）。
/// 没有身份的迁移来源要算整库摘要才判得出（[content_digest]），而一份更老 schema、没封存、又不是迁移来源的 `srs.db`
/// 会一直留在旁边（[finish_seal] 不动它）：不记下结论的话，每次 Primary 打开都把整个旧库扫一遍（G7-2b 复核遗留）。
/// 文件一变（长度或修改时刻，含 `-wal`）就重判。
pub const RETAINED_UNRELATED_KEY: &str = "retained_unrelated";

/// [path] 与它的 `-wal` 的 (长度, 修改时刻纳秒)：判「从上次判过之后有没有被动过」。拿不到的项记 0。
fn file_state(path: &Path) -> String {
    let one = |p: &Path| match std::fs::metadata(p) {
        Ok(m) => {
            let at = m
                .modified()
                .ok()
                .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                .map_or(0, |d| d.as_nanos());
            format!("{}@{at}", m.len())
        }
        Err(_) => "0@0".to_owned(),
    };
    format!("{}|{}", one(path), one(&seal::with_suffix(path, "-wal")))
}

/// [finish_seal] 用：[legacy]（`srs.db` 的路径，只读连接 [ro]）是不是 [new] 记的迁移来源。同一个文件状态之前已经判过
/// 「不是」（[RETAINED_UNRELATED_KEY]）就直接答不是；这次判出「不是」就记下（[new] 是读写连接）。
fn source_is(new: &Connection, ro: &Connection, legacy: &Path) -> Result<bool, String> {
    let state = file_state(legacy);
    let known: Option<String> = new
        .query_row(
            "SELECT value FROM srs_meta WHERE key = ?1",
            [RETAINED_UNRELATED_KEY],
            |r| r.get(0),
        )
        .optional()
        .map_err(schema::sql)?;
    if known.as_deref() == Some(state.as_str()) {
        return Ok(false);
    }
    let same = migrated_from_is(new, ro)?;
    if !same {
        new.execute(
            "INSERT INTO srs_meta (key, value) VALUES (?1, ?2) \
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            [RETAINED_UNRELATED_KEY, state.as_str()],
        )
        .map_err(schema::sql)?;
    }
    Ok(same)
}

/// [conn] 若是一份没封存的协议 3 库（`srs_meta.schema` 在 1..=协议 3 的当前号），它的 schema 号；已封存 / 墓碑 /
/// 比这一版新 / 不是协议 3 的库 = None。
fn unsealed_legacy_schema(conn: &Connection) -> rusqlite::Result<Option<i64>> {
    let has_meta: bool = conn.query_row(
        "SELECT EXISTS(SELECT 1 FROM sqlite_schema WHERE type = 'table' AND name = 'srs_meta')",
        [],
        |r| r.get(0),
    )?;
    if !has_meta {
        return Ok(None);
    }
    let current: Option<String> = conn
        .query_row("SELECT value FROM srs_meta WHERE key = 'schema'", [], |r| {
            r.get(0)
        })
        .optional()?;
    Ok(current
        .and_then(|v| v.parse::<i64>().ok())
        .filter(|v| (1..=crate::store::schema::SCHEMA_VERSION).contains(v)))
}

/// 新代库 [new] 已经在：`srs.db` 若是没封存的协议 3 库，按 [new] 记的迁移来源处理（文件头「打开模式」）——来源就是
/// 它 = 补做封存；不是 = [OpenError::LegacyNotMigrated]，不动它。已封存 / 墓碑 / 比这一版新的库都不动。比这一版协议 3
/// 旧的库（G7-2b：前提补完在副本里升级，原件保持旧 schema）只在它就是迁移来源时补封；不是就不动（与以前一样：这一版
/// 不认它，也不拿它当「没迁移的库」拦）。
/// 判断阶段只读打开 `srs.db`，确定要封了才以读写方式打开。调用方拿着换代锁（[open_gen4] 的 Primary；迁移在提交点之后
/// 中断、重跑时由 `migrate.rs` 调）。
///
/// 读不了它分两种：不是 SQLite 文件（`SQLITE_NOTADB`）= [Retained::Unreadable]，不挡新代库——旧版本同样拒绝打开它，
/// 不会往里写；别的错误（损坏、被别的进程锁住、IO……）报错：不能在旧版本还可能写它的状态下照常打开。
pub(crate) fn finish_seal(dir: &Path, new: &Connection) -> Result<Retained, OpenError> {
    let legacy = dir.join(LEGACY_FILE);
    if !legacy.exists() {
        return Ok(Retained::Settled);
    }
    let fail =
        |e: String| OpenError::Failed(format!("gen4 store: retained {}: {e}", legacy.display()));
    let not_a_db =
        |e: &rusqlite::Error| e.sqlite_error_code() == Some(rusqlite::ErrorCode::NotADatabase);
    let open = |flags: OpenFlags| {
        Connection::open_with_flags(&legacy, flags | OpenFlags::SQLITE_OPEN_NO_MUTEX)
    };
    let ro = match open(OpenFlags::SQLITE_OPEN_READ_ONLY) {
        Ok(c) => c,
        Err(e) if not_a_db(&e) => return Ok(Retained::Unreadable),
        Err(e) => return Err(fail(e.to_string())),
    };
    let current = match unsealed_legacy_schema(&ro) {
        Ok(Some(v)) => v,
        Ok(None) => return Ok(Retained::Settled),
        Err(e) if not_a_db(&e) => return Ok(Retained::Unreadable),
        Err(e) => return Err(fail(e.to_string())),
    };
    if !source_is(new, &ro, &legacy).map_err(fail)? {
        return if current == crate::store::schema::SCHEMA_VERSION {
            Err(OpenError::LegacyNotMigrated)
        } else {
            Ok(Retained::Settled)
        };
    }
    ro.close().map_err(|(_, e)| fail(e.to_string()))?;
    let rw = open(OpenFlags::SQLITE_OPEN_READ_WRITE).map_err(|e| fail(e.to_string()))?;
    crate::store::schema::seal_legacy(&rw, GEN4_FILE).map_err(fail)?;
    rw.close().map_err(|(_, e)| fail(e.to_string()))?;
    Ok(Retained::Settled)
}

/// [finish_seal] 看到的保留副本。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Retained {
    /// 没有、已封存 / 墓碑 / 别的版本 / 不是协议 3 的库、或刚补封完：没有要做的。
    Settled,
    /// 在，但不是 SQLite 文件（[Opened::retained_copy_unreadable]）。
    Unreadable,
}

/// 以读写、不创建的方式打开 [path]，要求它已经是一份建好的新代库（`schema::check_ready`）。不改它：不设 PRAGMA、
/// 不建表。
pub(crate) fn open_ready(path: &Path) -> Result<Connection, String> {
    let conn = Connection::open_with_flags(
        path,
        OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .map_err(schema::sql)?;
    schema::check_ready(&conn)?;
    Ok(conn)
}

/// 只读连接：[open_ready] + 核对 WAL + `query_only`。Secondary 的打开与命令层（`core.rs`）的读连接共用。
pub(crate) fn open_secondary(path: &Path) -> Result<Connection, String> {
    let conn = open_ready(path)?;
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
        let conn = open_gen4(&dir.0, OpenMode::Primary).unwrap().conn;
        let app: i32 = conn
            .query_row("PRAGMA application_id", [], |r| r.get(0))
            .unwrap();
        assert_eq!(app, schema::APPLICATION_ID);
        assert!(GenLock::try_acquire(&dir.0).unwrap().is_some());
        drop(conn);
        // 辅助进程现在能开，但写不进去；主进程再开照常。
        let ro = open_gen4(&dir.0, OpenMode::Secondary).unwrap().conn;
        let n: i64 = ro
            .query_row("SELECT COUNT(*) FROM collections", [], |r| r.get(0))
            .unwrap();
        assert_eq!(n, 0);
        let e = ro
            .execute("INSERT INTO srs_meta (key, value) VALUES ('x', 'y')", [])
            .unwrap_err();
        assert!(e.to_string().contains("readonly"), "{e}");
        let rw = open_gen4(&dir.0, OpenMode::Primary).unwrap().conn;
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

    /// 一份 v29 的协议 3 库（直接写 `srs_meta`，不经内核）。
    fn v29_at(path: &Path) {
        let c = Connection::open(path).unwrap();
        c.execute_batch(
            "CREATE TABLE srs_meta (key TEXT NOT NULL PRIMARY KEY, value TEXT NOT NULL);
             INSERT INTO srs_meta VALUES ('schema', '29');",
        )
        .unwrap();
    }

    fn schema_at(path: &Path) -> String {
        Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY)
            .unwrap()
            .query_row("SELECT value FROM srs_meta WHERE key = 'schema'", [], |r| {
                r.get(0)
            })
            .unwrap()
    }

    /// `srs4.db` 这个名字上不是建好的新代库（零字节、协议 3 的库）：Primary 报错，先于碰 `srs.db`、先于建表——
    /// `srs.db` 不被封存，零字节的 `srs4.db` 不被建成空库。旁边有没有 `srs.db` 都一样。
    #[test]
    fn primary_refuses_a_bad_generation_4_file_before_touching_anything() {
        // (a) 零字节 srs4.db + v29 的 srs.db。
        let dir = tempdir::new("open-bad-empty");
        let gen4 = dir.0.join(GEN4_FILE);
        let legacy = dir.0.join(LEGACY_FILE);
        std::fs::write(&gen4, b"").unwrap();
        v29_at(&legacy);
        let legacy_before = std::fs::read(&legacy).unwrap();
        match open_gen4(&dir.0, OpenMode::Primary).unwrap_err() {
            OpenError::Failed(e) => assert!(e.contains("empty"), "{e}"),
            other => panic!("{other:?}"),
        }
        assert_eq!(schema_at(&legacy), "29");
        assert_eq!(std::fs::read(&legacy).unwrap(), legacy_before);
        assert_eq!(std::fs::metadata(&gen4).unwrap().len(), 0);
        // (b) srs4.db 是 v29 的库 + v29 的 srs.db。
        let dir = tempdir::new("open-bad-v3");
        let gen4 = dir.0.join(GEN4_FILE);
        let legacy = dir.0.join(LEGACY_FILE);
        v29_at(&gen4);
        v29_at(&legacy);
        let e = open_gen4(&dir.0, OpenMode::Primary)
            .unwrap_err()
            .to_string();
        assert!(e.contains("protocol 3"), "{e}");
        assert_eq!(schema_at(&legacy), "29");
        assert_eq!(schema_at(&gen4), "29");
        // (c) 没有 srs.db，零字节 srs4.db。
        let dir = tempdir::new("open-bad-empty-alone");
        let gen4 = dir.0.join(GEN4_FILE);
        std::fs::write(&gen4, b"").unwrap();
        match open_gen4(&dir.0, OpenMode::Primary).unwrap_err() {
            OpenError::Failed(e) => assert!(e.contains("empty"), "{e}"),
            other => panic!("{other:?}"),
        }
        assert_eq!(std::fs::metadata(&gen4).unwrap().len(), 0);
        assert!(!dir.0.join(LEGACY_FILE).exists());
    }

    /// 保留副本 `srs.db` 不是 SQLite 文件：Primary 照常打开新代库、不动它、在结果里报出来；正常的保留副本不报。
    #[test]
    fn an_unreadable_retained_copy_is_reported_and_does_not_block() {
        let dir = tempdir::new("open-notadb");
        let legacy = dir.0.join(LEGACY_FILE);
        let fresh = open_gen4(&dir.0, OpenMode::Primary).unwrap();
        assert!(!fresh.retained_copy_unreadable);
        drop(fresh);
        let junk: Vec<u8> = b"this is not an sqlite file. ".repeat(200);
        std::fs::write(&legacy, &junk).unwrap();
        let opened = open_gen4(&dir.0, OpenMode::Primary).unwrap();
        assert!(opened.retained_copy_unreadable);
        opened
            .conn
            .execute("INSERT INTO srs_meta (key, value) VALUES ('x', 'y')", [])
            .unwrap();
        drop(opened);
        assert_eq!(std::fs::read(&legacy).unwrap(), junk);
        assert!(!seal::with_suffix(&legacy, "-wal").exists());
        // 锁在别人手里时不看它；Secondary 也不看。
        let lock = GenLock::try_acquire(&dir.0).unwrap().unwrap();
        assert!(
            !open_gen4(&dir.0, OpenMode::Primary)
                .unwrap()
                .retained_copy_unreadable
        );
        drop(lock);
        assert!(
            !open_gen4(&dir.0, OpenMode::Secondary)
                .unwrap()
                .retained_copy_unreadable
        );
        // 换成一份已封存的协议 3 库：不再报。
        std::fs::remove_file(&legacy).unwrap();
        v29_at(&legacy);
        Connection::open(&legacy)
            .unwrap()
            .execute_batch("UPDATE srs_meta SET value = '39999' WHERE key = 'schema';")
            .unwrap();
        assert!(
            !open_gen4(&dir.0, OpenMode::Primary)
                .unwrap()
                .retained_copy_unreadable
        );
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
        let ro = open_gen4(&dir.0, OpenMode::Secondary).unwrap().conn;
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

    const P: &str = crate::store::sync2::tests::P;

    /// 一份启用了协议 3（有身份）的 `srs.db`，内核已经关掉。
    fn legacy_with_identity(dir: &Path) {
        let core = crate::store::SrsCore::open(&dir.join(LEGACY_FILE)).unwrap();
        core.sync2_identity(P, 1).unwrap();
    }

    /// 迁移的提交点：在 [GEN4_TEMP] 建好新代库、记下来源 [source_dir] 里那份 `srs.db`，关掉后改名成 [GEN4_FILE]。
    /// 不封存旧库（= 提交之后、封存落盘之前中断的状态）。
    fn commit_migration(dir: &Path, source_dir: &Path) {
        let tmp = dir.join(GEN4_TEMP);
        let conn = schema::open(&tmp).unwrap();
        let source = Connection::open_with_flags(
            source_dir.join(LEGACY_FILE),
            OpenFlags::SQLITE_OPEN_READ_ONLY,
        )
        .unwrap();
        record_migrated_from(&conn, &source).unwrap();
        drop(source);
        conn.close().unwrap();
        assert!(!seal::with_suffix(&tmp, "-wal").exists());
        std::fs::rename(&tmp, dir.join(GEN4_FILE)).unwrap();
    }

    /// 全新安装建的新代库（没有迁移来源）旁边后来出现一份协议 3 的 `srs.db`（协议 3 的版本在同一个目录里跑过）：
    /// Primary 不封它、报「旁边有没迁移的协议 3 库」，`srs.db` 逐字节不变、协议 3 的内核照常能开。有没有身份都一样。
    #[test]
    fn a_fresh_install_never_seals_a_protocol_3_library_that_shows_up_later() {
        let dir = tempdir::new("open-unmigrated");
        let legacy = dir.0.join(LEGACY_FILE);
        let v3 = crate::store::schema::SCHEMA_VERSION.to_string();
        drop(open_gen4(&dir.0, OpenMode::Primary).unwrap());
        drop(crate::store::SrsCore::open(&legacy).unwrap());
        for with_identity in [false, true] {
            if with_identity {
                legacy_with_identity(&dir.0);
            }
            let before = std::fs::read(&legacy).unwrap();
            assert_eq!(
                open_gen4(&dir.0, OpenMode::Primary).unwrap_err(),
                OpenError::LegacyNotMigrated,
                "identity: {with_identity}"
            );
            assert_eq!(std::fs::read(&legacy).unwrap(), before);
            assert_eq!(legacy_schema(&dir.0), v3);
            // 只读的辅助进程照常；锁在别人手里（那个进程自己负责）时 Primary 不判断。
            drop(open_gen4(&dir.0, OpenMode::Secondary).unwrap());
            let lock = GenLock::try_acquire(&dir.0).unwrap().unwrap();
            drop(open_gen4(&dir.0, OpenMode::Primary).unwrap());
            drop(lock);
            assert_eq!(legacy_schema(&dir.0), v3);
            drop(crate::store::SrsCore::open(&legacy).unwrap());
        }
        // 没有来源标记的新代库没被写上标记。
        let n: i64 = open_gen4(&dir.0, OpenMode::Secondary)
            .unwrap()
            .conn
            .query_row(
                "SELECT COUNT(*) FROM srs_meta WHERE key = ?1",
                [MIGRATED_FROM_KEY],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(n, 0);
    }

    /// 新代库是从**另一份**协议 3 库迁移来的（来源标记与旁边这份 `srs.db` 的身份对不上）：不封、报同一个状态、
    /// `srs.db` 逐字节不变。
    #[test]
    fn a_library_migrated_from_elsewhere_does_not_seal_the_one_next_to_it() {
        let dir = tempdir::new("open-foreign");
        let elsewhere = tempdir::new("open-foreign-source");
        legacy_with_identity(&elsewhere.0);
        commit_migration(&dir.0, &elsewhere.0);
        legacy_with_identity(&dir.0);
        let legacy = dir.0.join(LEGACY_FILE);
        let before = std::fs::read(&legacy).unwrap();
        assert_eq!(
            open_gen4(&dir.0, OpenMode::Primary).unwrap_err(),
            OpenError::LegacyNotMigrated
        );
        assert_eq!(std::fs::read(&legacy).unwrap(), before);
        assert_eq!(
            legacy_schema(&dir.0),
            crate::store::schema::SCHEMA_VERSION.to_string()
        );
    }

    /// 来源没有身份的库（G7-2b：前提补完在副本里才给它建身份，原件没有）记内容摘要（[NO_IDENTITY]）：封存前后对得上
    /// （封存只改 `srs_meta`），别的任何写入之后对不上。
    #[test]
    fn a_source_without_an_identity_is_recorded_by_content() {
        let dir = tempdir::new("open-no-identity");
        drop(crate::store::SrsCore::open(&dir.0.join(LEGACY_FILE)).unwrap());
        let source = Connection::open(dir.0.join(LEGACY_FILE)).unwrap();
        let conn = schema::open_in_memory().unwrap();
        record_migrated_from(&conn, &source).unwrap();
        let from: String = conn
            .query_row(
                "SELECT value FROM srs_meta WHERE key = ?1",
                [MIGRATED_FROM_KEY],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(from, NO_IDENTITY);
        assert_eq!(migrated_from_is(&conn, &source), Ok(true));
        crate::store::schema::seal_legacy(&source, GEN4_FILE).unwrap();
        assert_eq!(migrated_from_is(&conn, &source), Ok(true));
        source
            .execute(
                "INSERT INTO sync2_trust (profile_uid, device, state, since) VALUES ('p', x'00', 1, 0)",
                [],
            )
            .unwrap();
        assert_eq!(migrated_from_is(&conn, &source), Ok(false));
    }

    /// 迁移提交了、封存那一笔没落盘（`srs4.db` 在、记的来源就是旁边这份还没封存的 `srs.db`）：Primary 打开时在锁里
    /// 补封；锁被别人拿着（迁移进程还在提交点与封存之间）时不补；Secondary 从不写它。
    #[test]
    fn primary_finishes_a_lost_seal_before_opening() {
        let dir = tempdir::new("open-reseal");
        legacy_with_identity(&dir.0);
        commit_migration(&dir.0, &dir.0);
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
        let sealed_into: String = Connection::open(dir.0.join(LEGACY_FILE))
            .unwrap()
            .query_row(
                "SELECT value FROM srs_meta WHERE key = 'sealed_into'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(sealed_into, GEN4_FILE);
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
