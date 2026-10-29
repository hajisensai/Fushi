//! SRS 事件库：Rust 独占的 `srs.db`（docs/specs/2026-10-23-srs-rust-store.md）。
//!
//! 一条写连接 + 两条读连接，各在一把 Mutex 里：写命令 = 写连接上的一个事务（这把锁就是 SRS 的
//! 写锁），读命令走读连接上的 WAL 快照，不被长写挡住；Drift 执行器在事务外的查询走它自己的那条读连接
//! （[SrsCore::select]），不与 Rust 的读命令（备份 `VACUUM INTO`、投影扫描）互相排队。对象可以从任意
//! 线程 / isolate 调用。
//!
//! 关闭（[SrsCore::close]）与在途调用互斥：它先后拿读、写两把锁再丢掉连接，所以会等别的线程手上
//! 的命令跑完；之后的命令（含另开只读会话 [SrsCore::read_session]）一律报「已关闭」。还没结束的只读
//! 会话一并失效：在途的那次读跑完后连接随即关掉，之后经它的调用同样报「已关闭」——close 返回时
//! 本对象打开过的 srs.db 连接一条不剩（Windows 下关库后文件可删可改名）。C ABI 的句柄是
//! 句柄表里的编号、调用期间握一份 `Arc`（见 [ffi]），结构体在最后一份引用放掉时释放。
//!
//! 只打开 `srs.db`、它的备份快照副本或自己生成的临时文件；绝不打开主库 `fushi.db`（同一进程里
//! Drift 那份 SQLite 与这里自带的一份同开一个文件，会在 POSIX 平台上互相清掉文件锁）。

pub(crate) mod caches;
pub mod ffi;
pub mod rows;
mod profile_data;
mod projections;
pub mod schema;
pub mod sync2;

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::ops::{Deref, DerefMut};
use std::sync::{Arc, Mutex, MutexGuard, Weak};
use std::time::Duration;

use rusqlite::types::Value;
use rusqlite::{Connection, OpenFlags};

const LEGACY_KEY: &str = "legacy_import";

/// 已关闭的库上任何命令的错误文本（Dart 侧按它认「已关闭」）。
pub(crate) const CLOSED: &str = "srs store is closed";

pub struct SrsCore {
    // 字段按声明顺序析构：只读连接先关，写连接最后关。最后一个关闭的连接负责把 WAL 并回主文件
    // 并删掉 -wal；只读连接做不了，让它最后关会把整段 WAL 留在磁盘上（拷库 / 换库时丢数据）。
    // `None` = 已关闭（[SrsCore::close]）。
    reader: Mutex<Option<Connection>>,
    /// Drift 执行器事务外查询专用的读连接（[SrsCore::select]）。
    drift_reader: Mutex<Option<Connection>>,
    writer: Mutex<Option<Connection>>,
    /// Drift 在写连接上开着事务（它用 BEGIN / SAVEPOINT 语句经 [SrsCore::exec] 开关）。每条经 [SrsCore::exec] /
    /// [SrsCore::exec_batch] 跑完的语句之后按写连接的 autocommit 状态更新；只有这两个入口能让事务跨命令留着
    /// （Rust 自己的写命令在一次调用里提交或回滚），所以写锁空闲时它与写连接的状态一致。开着时 Drift 的查询与
    /// 只读命令都留在写连接上（看得见事务里未提交的行），否则走读连接的 WAL 快照。
    drift_tx: AtomicBool,
    /// 旧库搬迁的事务开着（写连接上挂着一个 BEGIN）：别的写命令一律拒绝。
    legacy_open: AtomicBool,
    /// 库文件路径（[SrsCore::read_session] 另开只读连接用）。
    path: PathBuf,
    /// 开过的只读会话（弱引用）：[SrsCore::close] 逐个关掉还没结束的。只在持读锁时登记，close 先拿
    /// 读锁，所以不会漏掉一个正在开的会话。
    sessions: Mutex<Vec<Weak<ReadSession>>>,
    /// 正在进行的分批收段会话（[SrsCore::sync2_ingest_begin]）；None = 没有。
    ingest_session: Mutex<Option<sync2::transport::IngestSession>>,
    /// 有写入在等写锁，正在投的收段那一片尽快收（[SrsCore::sync2_ingest_yield]）。
    ingest_yield: AtomicBool,
    /// 测试钩子：收段预处理拿完公钥、开始解码之前调用（测预处理不持写锁）。
    #[cfg(test)]
    #[allow(clippy::type_complexity)]
    pub(crate) ingest_prepare_hook: Mutex<Option<Box<dyn Fn() + Send>>>,
}

/// 一条独立的只读连接 + 一个读事务（[SrsCore::read_session]）：整段读取看到开会话那一刻的快照，
/// 不占 [SrsCore] 自己的读 / 写连接。[ReadSession::close]（或析构）回滚并关闭；所属的库关闭时也一并
/// 关闭（[SrsCore::close]），之后的查询报「已关闭」。可以跨线程共享：连接在一把锁里，关闭会等在途查询跑完。
pub struct ReadSession {
    // `None` = 已关闭。
    conn: Mutex<Option<Connection>>,
}

/// 打开着的一条连接（[SrsCore::reader] / [SrsCore::writer]），持有它就持有那把锁。
pub(crate) struct Conn<'a>(MutexGuard<'a, Option<Connection>>);

impl<'a> Conn<'a> {
    fn of(guard: MutexGuard<'a, Option<Connection>>) -> Result<Self, String> {
        if guard.is_none() {
            return Err(CLOSED.to_string());
        }
        Ok(Self(guard))
    }
}

/// 命令之间一条连接留着的页缓存上限。一条命令里照样能用满 `cache_size`（64 MB：收段后的缓存刷新这类大写事务
/// 靠它不反复换页，压到 8 MB 实测端到端慢约 20%）；命令结束（守卫放锁）时还超过这个数，就把能丢的页还掉，
/// 大命令跑完不常驻几十 MB。
const IDLE_CACHE_BYTES: i32 = 8 * 1024 * 1024;

impl Drop for Conn<'_> {
    fn drop(&mut self) {
        let Some(c) = self.0.as_ref() else { return };
        let (mut used, mut high) = (0, 0);
        // SAFETY: 句柄属于这条仍持着锁的连接，只读一项统计。
        let rc = unsafe {
            rusqlite::ffi::sqlite3_db_status(c.handle(), rusqlite::ffi::SQLITE_DBSTATUS_CACHE_USED, &mut used, &mut high, 0)
        };
        if rc == rusqlite::ffi::SQLITE_OK && used > IDLE_CACHE_BYTES {
            let _ = c.release_memory();
        }
    }
}

impl Deref for Conn<'_> {
    type Target = Connection;

    fn deref(&self) -> &Connection {
        self.0.as_ref().expect("Conn::of checked the connection is open")
    }
}

impl DerefMut for Conn<'_> {
    fn deref_mut(&mut self) -> &mut Connection {
        self.0.as_mut().expect("Conn::of checked the connection is open")
    }
}

impl ReadSession {
    /// 在会话的读事务里跑一条只读语句；结果编码同 [SrsCore::debug_query]（首行是列名）。
    pub fn query(&self, sql: &str, params: &[Value]) -> Result<Vec<u8>, String> {
        let conn = Conn::of(self.conn.lock().map_err(|_| "srs read session poisoned".to_string())?)?;
        query_rows(&conn, sql, params)
    }

    /// 在会话的连接上跑 [f]（持会话自己的锁：关库会等它跑完）；会话已关闭报「已关闭」。
    pub(crate) fn with<T>(&self, f: impl FnOnce(&Connection) -> Result<T, String>) -> Result<T, String> {
        let conn = Conn::of(self.conn.lock().map_err(|_| "srs read session poisoned".to_string())?)?;
        f(&conn)
    }

    /// 回滚读事务并关闭连接（幂等）。会等别的线程上在途的查询跑完；之后的查询报「已关闭」。
    pub fn close(&self) {
        let conn = self.conn.lock().unwrap_or_else(|e| e.into_inner()).take();
        drop(conn);
    }
}

/// [sql] 是不是能放到读连接上跑的查询：第一个关键字（跳过空白与注释）是 SELECT / WITH / VALUES。
/// 是否真的只读另由 SQLite 判（[SrsCore::select]）；这里先排除 PRAGMA 与事务控制语句——SQLite 把 BEGIN /
/// SAVEPOINT 也判为只读，放到读连接上会在那条连接上开一个不会结束的事务。
fn snapshot_query(sql: &str) -> bool {
    let mut rest = sql;
    loop {
        rest = rest.trim_start();
        if let Some(r) = rest.strip_prefix("--") {
            rest = r.find('\n').map_or("", |i| &r[i + 1..]);
        } else if let Some(r) = rest.strip_prefix("/*") {
            rest = r.find("*/").map_or("", |i| &r[i + 2..]);
        } else {
            break;
        }
    }
    let word: String = rest.chars().take_while(|c| c.is_ascii_alphabetic()).collect();
    ["SELECT", "WITH", "VALUES"].iter().any(|k| word.eq_ignore_ascii_case(k))
}

/// 一条只读语句的结果页：首行列名，其后每行一组值（rows.rs 编码）。写语句一律拒绝。
fn query_rows(conn: &Connection, sql: &str, params: &[Value]) -> Result<Vec<u8>, String> {
    let mut stmt = conn.prepare(sql).map_err(|e| e.to_string())?;
    if !stmt.readonly() {
        return Err("only read-only statements are allowed here".into());
    }
    let names: Vec<Value> = stmt
        .column_names()
        .iter()
        .map(|n| Value::Text((*n).to_string()))
        .collect();
    let n = names.len();
    let mut out: Vec<Vec<Value>> = vec![names];
    let mut q = stmt
        .query(rusqlite::params_from_iter(params.iter()))
        .map_err(|e| e.to_string())?;
    while let Some(row) = q.next().map_err(|e| e.to_string())? {
        let mut vals = Vec::with_capacity(n);
        for i in 0..n {
            vals.push(row.get::<_, Value>(i).map_err(|e| e.to_string())?);
        }
        out.push(vals);
    }
    Ok(rows::encode(n, &out))
}

fn configure(conn: &Connection) -> Result<(), String> {
    conn.busy_timeout(Duration::from_millis(5000))
        .map_err(|e| e.to_string())?;
    // mmap + 64 MB 页缓存：缓存刷新 / 历史这类一次读几万行日志的命令，默认 2 MB 页缓存下每页一次
    // 系统调用（3000 笔记 / 6.6 万条日志实测读取 320–400 ms → 158 ms）。mmap 只占虚拟地址，
    // 上限 256 MB；WAL 模式下 SQLite 照常处理。
    conn.execute_batch(
        "PRAGMA synchronous = NORMAL; PRAGMA foreign_keys = OFF; \
         PRAGMA mmap_size = 268435456; PRAGMA cache_size = -65536;",
    )
    .map_err(|e| e.to_string())
}

impl SrsCore {
    /// 打开（不存在就建）。建表 / 升级在写连接上一个事务里做完才开读连接。
    pub fn open(path: &Path) -> Result<Self, String> {
        let mut writer = Connection::open_with_flags(
            path,
            OpenFlags::SQLITE_OPEN_READ_WRITE
                | OpenFlags::SQLITE_OPEN_CREATE
                | OpenFlags::SQLITE_OPEN_NO_MUTEX,
        )
        .map_err(|e| format!("open {}: {e}", path.display()))?;
        configure(&writer)?;
        let mode: String = writer
            .query_row("PRAGMA journal_mode = WAL", [], |r| r.get(0))
            .map_err(|e| e.to_string())?;
        if !mode.eq_ignore_ascii_case("wal") {
            return Err(format!("srs.db journal_mode is {mode}, expected wal"));
        }
        schema::migrate(&mut writer)?;
        let reader = Connection::open_with_flags(
            path,
            OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
        )
        .map_err(|e| format!("open reader {}: {e}", path.display()))?;
        configure(&reader)?;
        let drift_reader = Connection::open_with_flags(
            path,
            OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
        )
        .map_err(|e| format!("open drift reader {}: {e}", path.display()))?;
        configure(&drift_reader)?;
        Ok(Self {
            writer: Mutex::new(Some(writer)),
            reader: Mutex::new(Some(reader)),
            drift_reader: Mutex::new(Some(drift_reader)),
            drift_tx: AtomicBool::new(false),
            legacy_open: AtomicBool::new(false),
            path: path.to_path_buf(),
            sessions: Mutex::new(Vec::new()),
            ingest_session: Mutex::new(None),
            ingest_yield: AtomicBool::new(false),
            #[cfg(test)]
            ingest_prepare_hook: Mutex::new(None),
        })
    }

    pub(crate) fn writer(&self) -> Result<Conn<'_>, String> {
        Conn::of(self.writer.lock().map_err(|_| "srs writer poisoned".to_string())?)
    }

    pub(crate) fn reader(&self) -> Result<Conn<'_>, String> {
        Conn::of(self.reader.lock().map_err(|_| "srs reader poisoned".to_string())?)
    }

    fn drift_reader(&self) -> Result<Conn<'_>, String> {
        Conn::of(self.drift_reader.lock().map_err(|_| "srs drift reader poisoned".to_string())?)
    }

    /// 写连接上是否挂着跨命令的事务（Drift 的事务或旧库搬迁）：挂着时只读命令也必须在写连接上读，
    /// 才看得见那笔事务里未提交的行。
    fn writer_tx_open(&self) -> bool {
        self.drift_tx.load(Ordering::SeqCst) || self.legacy_open.load(Ordering::SeqCst)
    }

    /// 只读命令的连接选择：写连接上挂着事务（[SrsCore::writer_tx_open]）时在写连接的 SAVEPOINT 里读（嵌在那笔
    /// 事务里，看得见未提交的行，结束时 RELEASE 不改动任何东西）；否则在读连接上的一个读事务里读（整段同一份
    /// 已提交快照，不排写锁）。读连接是只读打开的：[f] 里混进写语句会直接报错，不会悄悄写到别处。
    pub(crate) fn read_visible<T>(&self, f: impl FnOnce(&Connection) -> Result<T, String>) -> Result<T, String> {
        if self.writer_tx_open() {
            let w = self.writer()?;
            return sync2::in_savepoint(&w, f);
        }
        let r = self.reader()?;
        r.execute_batch("BEGIN").map_err(|e| e.to_string())?;
        let out = f(&r);
        r.execute_batch("ROLLBACK").map_err(|e| e.to_string())?;
        out
    }

    /// 关闭全部连接（幂等）：读连接、还没结束的只读会话、写连接。每一条都先拿它的锁再丢，所以会等
    /// 其它线程上在途的命令 / 会话查询跑完，关闭返回时库文件已没有打开的句柄（覆盖恢复要删换
    /// srs.db）。写连接最后关：最后关的连接负责把 WAL 并回主文件并删掉 -wal。之后的命令与会话查询
    /// 一律报「已关闭」。
    pub fn close(&self) {
        // 先关读连接：此后 read_session 报已关闭，下面拿到的会话清单就是全部。
        let reader = self.reader.lock().unwrap_or_else(|e| e.into_inner()).take();
        drop(reader);
        let drift_reader = self.drift_reader.lock().unwrap_or_else(|e| e.into_inner()).take();
        drop(drift_reader);
        let sessions = std::mem::take(&mut *self.sessions.lock().unwrap_or_else(|e| e.into_inner()));
        for s in sessions.iter().filter_map(Weak::upgrade) {
            s.close();
        }
        let writer = self.writer.lock().unwrap_or_else(|e| e.into_inner()).take();
        drop(writer);
    }

    fn meta(conn: &Connection, key: &str) -> Result<Option<String>, String> {
        match conn.query_row("SELECT value FROM srs_meta WHERE key = ?1", [key], |r| r.get(0)) {
            Ok(v) => Ok(Some(v)),
            Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
            Err(e) => Err(e.to_string()),
        }
    }

    fn set_meta(conn: &Connection, key: &str, value: &str) -> Result<(), String> {
        conn.execute(
            "INSERT INTO srs_meta (key, value) VALUES (?1, ?2) \
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            [key, value],
        )
        .map(|_| ())
        .map_err(|e| e.to_string())
    }

    // ------------------------------------------------------------ 旧库搬迁（§3）

    /// 旧主库里的 SRS 数据是否已搬进来（或确认没有要搬的）。
    pub fn legacy_imported(&self) -> Result<bool, String> {
        let w = self.writer()?;
        Ok(Self::meta(&w, LEGACY_KEY)?.is_some())
    }

    /// 开搬迁事务：清空 9 张表（未写标记的库里不该有东西；上一次搬到一半崩溃时 SQLite 已回滚）。
    pub fn legacy_begin(&self) -> Result<(), String> {
        let w = self.writer()?;
        if Self::meta(&w, LEGACY_KEY)?.is_some() {
            return Err("legacy store already imported".into());
        }
        if self.legacy_open.swap(true, Ordering::SeqCst) {
            return Err("legacy import already in progress".into());
        }
        let mut sql = String::from("BEGIN IMMEDIATE;");
        for t in schema::TABLES {
            sql.push_str(&format!("DELETE FROM {};", t.name));
        }
        if let Err(e) = w.execute_batch(&sql) {
            let _ = w.execute_batch("ROLLBACK");
            self.legacy_open.store(false, Ordering::SeqCst);
            return Err(e.to_string());
        }
        Ok(())
    }

    /// 写一页旧表行（列序 = [schema::TABLES] 里该表的列序）。
    pub fn legacy_page(&self, table: &str, page: &[u8]) -> Result<usize, String> {
        if !self.legacy_open.load(Ordering::SeqCst) {
            return Err("legacy import not started".into());
        }
        let t = schema::table(table).ok_or_else(|| format!("unknown srs table {table}"))?;
        let (n_cols, rows) = rows::decode(page)?;
        if n_cols != t.columns.len() && !rows.is_empty() {
            return Err(format!(
                "{table}: page has {n_cols} columns, expected {}",
                t.columns.len()
            ));
        }
        let w = self.writer()?;
        let marks = vec!["?"; t.columns.len()].join(", ");
        let sql = format!(
            "INSERT INTO {} ({}) VALUES ({marks})",
            t.name,
            t.columns.join(", ")
        );
        let mut stmt = w.prepare_cached(&sql).map_err(|e| e.to_string())?;
        for row in &rows {
            stmt.execute(rusqlite::params_from_iter(row.iter()))
                .map_err(|e| format!("{table}: {e}"))?;
        }
        Ok(rows.len())
    }

    /// 写标记并提交。
    pub fn legacy_commit(&self) -> Result<(), String> {
        if !self.legacy_open.load(Ordering::SeqCst) {
            return Err("legacy import not started".into());
        }
        let w = self.writer()?;
        let result = Self::set_meta(&w, LEGACY_KEY, "1").and_then(|_| {
            w.execute_batch("COMMIT").map_err(|e| e.to_string())
        });
        if result.is_err() {
            let _ = w.execute_batch("ROLLBACK");
        }
        self.legacy_open.store(false, Ordering::SeqCst);
        result
    }

    pub fn legacy_abort(&self) -> Result<(), String> {
        if !self.legacy_open.swap(false, Ordering::SeqCst) {
            return Ok(());
        }
        let w = self.writer()?;
        w.execute_batch("ROLLBACK").map_err(|e| e.to_string())
    }

    /// 主库里本来就没有 SRS 表（新装）：直接写标记。
    pub fn legacy_mark_none(&self) -> Result<(), String> {
        let w = self.writer()?;
        Self::set_meta(&w, LEGACY_KEY, "0")
    }

    // ------------------------------------------------------------ 备份快照

    /// `VACUUM INTO` 一份一致快照（读连接上做：不挡写）。`strip_device_local` 时在快照里清空
    /// 6 张设备本地表（本机状态、发件箱元信息、留存批次、三张缓存），与通用备份的规则一致；
    /// 同步 v2 的本机身份（`sync2_self`、切段点、各位置进度、因果缓冲）也剥掉：从备份恢复出来的库是
    /// 一台新设备，打开时生成新身份，旧身份按普通远端设备续收（设计 §7.3 的预防）。
    pub fn snapshot_into(&self, target: &Path, strip_device_local: bool) -> Result<(), String> {
        if target.exists() {
            return Err(format!("{} already exists", target.display()));
        }
        let target_str = target
            .to_str()
            .ok_or_else(|| "snapshot path is not UTF-8".to_string())?;
        {
            let r = self.reader()?;
            r.execute("VACUUM INTO ?1", [target_str])
                .map_err(|e| e.to_string())?;
        }
        if strip_device_local {
            let snap = Connection::open(target).map_err(|e| e.to_string())?;
            snap.execute_batch(
                // srs_event_local 不删：它的 server_time 是迁移来的旧修改记录 / 外来带戳事件的排序键（S），
                // 删了恢复出来的设备会按另一种顺序解寄存器、与其它设备分叉。发件箱列早已无人读写。
                "BEGIN; UPDATE srs_event_local SET outbox_seq = NULL; DELETE FROM srs_local_state; \
                 DELETE FROM srs_sent_batches; DELETE FROM srs_notes_cache; \
                 DELETE FROM srs_cards_cache; DELETE FROM srs_stat_reviews; \
                 DELETE FROM srs_meta WHERE key = 'legacy_import'; \
                 DELETE FROM sync2_self; DELETE FROM sync2_pending; DELETE FROM sync2_segments; \
                 DELETE FROM sync2_locations; DELETE FROM sync2_rewrites; DELETE FROM sync2_obsolete; \
                 DELETE FROM srs_meta WHERE key LIKE 'sync2_digest/%'; \
                 COMMIT; VACUUM;",
            )
            .map_err(|e| e.to_string())?;
        }
        Ok(())
    }

    // ------------------------------------------------------------ Drift 执行器（§5 过渡层）

    /// 在写连接上执行一条语句（Drift `QueryDelegate` 的写语句与 `runCustom` 的后端；事务由 Drift 用 BEGIN /
    /// COMMIT / SAVEPOINT 语句经这里开关，同一条连接上的 Rust 命令看得见事务里未提交的行）。跑完按写连接的
    /// autocommit 状态记下 Drift 事务是否开着（[SrsCore::select] 据此选连接）。
    ///
    /// 返回页：查询 = 首行列名 + 结果行；其它 = 一行 `[变更行数, last_insert_rowid]`。
    pub fn exec(&self, sql: &str, params: &[Value], select: bool) -> Result<Vec<u8>, String> {
        if self.legacy_open.load(Ordering::SeqCst) {
            return Err("legacy import in progress".into());
        }
        let w = self.writer()?;
        let out = Self::exec_on(&w, sql, params, select);
        self.drift_tx.store(!w.is_autocommit(), Ordering::SeqCst);
        out
    }

    /// Drift 的查询（`QueryDelegate.runSelect`）：Drift 事务开着（[SrsCore::writer_tx_open]）时在写连接上跑，
    /// 看得见那笔事务里未提交的行；否则只读查询走 Drift 专用读连接的 WAL 快照，不排写锁（Rust 的长写命令、
    /// 收段投递进行中照样能读），读到的是此刻已提交的数据。
    ///
    /// 写后立即读成立：Drift 的写语句（autocommit）与 COMMIT 都在 [SrsCore::exec] 返回前提交完；读连接每条语句
    /// 自成一个读事务（语句跑完即复位，不留跨调用的读事务），开读事务时取最新的 WAL 尾，所以 Dart 等到写返回后
    /// 再发的查询一定看得见它。Rust 写命令同理（返回前提交）。
    ///
    /// 走读连接的只有以 SELECT / WITH / VALUES 开头且 SQLite 判为只读的语句：`… RETURNING` 这类写语句、PRAGMA
    /// （读的是写连接自己的设置，如 `wal_autocheckpoint`）、事务控制语句（SQLite 把 BEGIN 也判为只读）一律留在
    /// 写连接上。返回页同 [SrsCore::exec] 的查询。
    pub fn select(&self, sql: &str, params: &[Value]) -> Result<Vec<u8>, String> {
        if self.legacy_open.load(Ordering::SeqCst) {
            return Err("legacy import in progress".into());
        }
        if !self.writer_tx_open() && snapshot_query(sql) {
            let r = self.drift_reader()?;
            let readonly = r.prepare_cached(sql).map_err(|e| format!("{e} in {sql}"))?.readonly();
            if readonly {
                return Self::exec_on(&r, sql, params, true);
            }
        }
        self.exec(sql, params, true)
    }

    fn exec_on(conn: &Connection, sql: &str, params: &[Value], select: bool) -> Result<Vec<u8>, String> {
        let mut stmt = conn.prepare_cached(sql).map_err(|e| format!("{e} in {sql}"))?;
        if !select {
            let changes = stmt
                .execute(rusqlite::params_from_iter(params.iter()))
                .map_err(|e| format!("{e} in {sql}"))?;
            return Ok(rows::encode(
                2,
                &[vec![
                    Value::Integer(changes as i64),
                    Value::Integer(conn.last_insert_rowid()),
                ]],
            ));
        }
        let n = stmt.column_count();
        let names: Vec<Value> = stmt
            .column_names()
            .iter()
            .map(|c| Value::Text((*c).to_string()))
            .collect();
        let mut out = Vec::with_capacity(4096);
        out.extend_from_slice(&0u32.to_le_bytes());
        out.extend_from_slice(&(n as u32).to_le_bytes());
        for v in &names {
            rows::push_value(&mut out, v.into());
        }
        let mut count: u32 = 1;
        let mut q = stmt
            .query(rusqlite::params_from_iter(params.iter()))
            .map_err(|e| format!("{e} in {sql}"))?;
        while let Some(row) = q.next().map_err(|e| e.to_string())? {
            for i in 0..n {
                rows::push_value(&mut out, row.get_ref(i).map_err(|e| e.to_string())?);
            }
            count += 1;
        }
        out[0..4].copy_from_slice(&count.to_le_bytes());
        Ok(out)
    }

    /// Drift 的批量语句：`statements[i]` 配若干组参数，按给定顺序执行（调用方已在事务里）。
    pub fn exec_batch(&self, statements: &[&str], applications: &[(usize, Vec<Value>)]) -> Result<(), String> {
        if self.legacy_open.load(Ordering::SeqCst) {
            return Err("legacy import in progress".into());
        }
        let w = self.writer()?;
        let run = || -> Result<(), String> {
            for (index, args) in applications {
                let sql = statements
                    .get(*index)
                    .ok_or_else(|| format!("batch statement index {index} out of range"))?;
                let mut stmt = w.prepare_cached(sql).map_err(|e| format!("{e} in {sql}"))?;
                stmt.execute(rusqlite::params_from_iter(args.iter()))
                    .map_err(|e| format!("{e} in {sql}"))?;
            }
            Ok(())
        };
        let out = run();
        self.drift_tx.store(!w.is_autocommit(), Ordering::SeqCst);
        out
    }

    /// 写连接当前是否在事务里（Drift 打开时校验、测试用）。
    pub fn in_transaction(&self) -> Result<bool, String> {
        Ok(!self.writer()?.is_autocommit())
    }

    // ------------------------------------------------------------ 直读命令

    /// 卡片历史的当前状态，直接从写连接读日志（看得见 Drift 事务里未提交的行）：
    /// `groups[g]` 是第 g 份历史的血统（自己 + 全部前身的卡 ID）。输出布局同
    /// `history::encode_states`。日志原文与服务器时刻一条 JOIN 取出，不跨 isolate、不回 Dart。
    pub fn history_states(&self, groups: &[Vec<String>]) -> Result<Vec<u8>, String> {
        let logs = self.writer_logs(groups)?;
        let empty: Vec<(String, Option<i64>)> = Vec::new();
        let mut states = Vec::with_capacity(groups.len());
        for g in groups {
            let mut jsons: Vec<&str> = Vec::new();
            let mut servers: Vec<Option<i64>> = Vec::new();
            for c in g {
                for (j, s) in logs.get(c).unwrap_or(&empty) {
                    jsons.push(j);
                    servers.push(*s);
                }
            }
            states.push(crate::history::state_from_json(&jsons, &servers)?);
        }
        Ok(crate::history::encode_states(&states))
    }

    /// 有效复习投影（`srs_stat_reviews` 的行），同样直读写连接：`groups[g]` 是第 g 个归属组（归属卡在前，
    /// 再列出归它的前身卡），日志合在一起按 [crate::history::stats_from_json] 投影。归属由 Dart 按血统与
    /// 可见性定（`SrsDbStore._refreshStatProjection`）。
    ///
    /// 输出是一页行（`rows::encode`，9 列）：归属组下标, logId, occurredAt, utcOffsetMin, rating|NULL,
    /// kind, durationMs, prevDueDay|NULL, maturityDelta。
    pub fn stat_projection(&self, groups: &[Vec<String>]) -> Result<Vec<u8>, String> {
        let logs = self.writer_logs(groups)?;
        let empty: Vec<(String, Option<i64>)> = Vec::new();
        let mut out: Vec<Vec<Value>> = Vec::new();
        let opt = |v: Option<i64>| v.map_or(Value::Null, Value::Integer);
        for (gi, g) in groups.iter().enumerate() {
            let mut jsons: Vec<&str> = Vec::new();
            let mut servers: Vec<Option<i64>> = Vec::new();
            for c in g {
                for (j, s) in logs.get(c).unwrap_or(&empty) {
                    jsons.push(j);
                    servers.push(*s);
                }
            }
            for r in crate::history::stats_from_json(&jsons, &servers)? {
                out.push(vec![
                    Value::Integer(gi as i64),
                    Value::Text(r.log_id),
                    Value::Integer(r.occurred_at),
                    Value::Integer(r.utc_off),
                    opt(r.rating),
                    Value::Integer(r.kind),
                    Value::Integer(r.dur),
                    opt(r.prev_due_day),
                    Value::Integer(r.maturity_delta),
                ]);
            }
        }
        Ok(rows::encode(9, &out))
    }

    /// 这些组里全部卡的日志原文 + 服务器时刻（写连接，一条 JOIN 按块取）。
    fn writer_logs(
        &self,
        groups: &[Vec<String>],
    ) -> Result<std::collections::HashMap<String, Vec<(String, Option<i64>)>>, String> {
        let w = self.writer()?;
        logs_of(&w, groups)
    }

    // ------------------------------------------------------------ 测试 / 诊断

    /// 在读连接上跑一条只读 SQL，结果按 [rows] 编码；第一行是列名（文本）。只给测试与诊断用：
    /// 产品代码一律走粗粒度命令。
    pub fn debug_query(&self, sql: &str, params: &[Value]) -> Result<Vec<u8>, String> {
        query_rows(&*self.reader()?, sql, params)
    }

    /// 一次性全库扫描（状态摘要）用的只读连接：页缓存只有 2 MB、调用方用完即关，扫描读过的页不会留在读连接的
    /// 64 MB 页缓存里（那份缓存留给反复读同一批行的历史类命令）。顺序扫描靠 mmap 与操作系统的文件缓存，小页缓存
    /// 不慢。
    ///
    /// 与 [SrsCore::read_session] 一样登记成只读会话：只在开连接、登记的那一下拿读连接的锁（与 [SrsCore::close]
    /// 互斥，库已关闭就报「已关闭」），扫描本身不占读连接——摘要扫 100 万次复习要几秒，以前整段攥着读锁，
    /// 同一时刻走读连接的命令（同步状态、冲突、历史……）全被挡住。关库时会话随 [SrsCore::close] 一起关掉
    /// （等在途的扫描跑完），close 返回时照样一条连接不剩。
    pub(crate) fn scan_session(&self) -> Result<Arc<ReadSession>, String> {
        let _open = self.reader()?;
        let conn = Connection::open_with_flags(&self.path, OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX)
            .map_err(|e| format!("open scan connection {}: {e}", self.path.display()))?;
        configure(&conn)?;
        conn.execute_batch("PRAGMA cache_size = -2048;").map_err(|e| e.to_string())?;
        self.register_session(conn)
    }

    /// 另开一条只读连接、开读事务并先读一次（快照在第一次读时才定下）：返回时快照已定，之后本库的
    /// 新写入都不在里面。备份读快照用（后台 isolate 里分页读二三十秒，不占读 / 写连接）。
    ///
    /// 开会话期间持读连接的锁：与 [SrsCore::close]（先拿读锁）互斥，库已关闭就报「已关闭」，不会按路径
    /// 把关库后可能已被删换的库文件重新打开。会话开好之后与本对象无关，关库不结束它。
    pub fn read_session(&self) -> Result<Arc<ReadSession>, String> {
        let _open = self.reader()?;
        let conn = Connection::open_with_flags(
            &self.path,
            OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
        )
        .map_err(|e| format!("open read session {}: {e}", self.path.display()))?;
        configure(&conn)?;
        conn.execute_batch("BEGIN").map_err(|e| e.to_string())?;
        conn.query_row("SELECT COUNT(*) FROM sqlite_master", [], |r| r.get::<_, i64>(0))
            .map_err(|e| e.to_string())?;
        self.register_session(conn)
    }

    /// 把 [conn] 包成只读会话并登记（[SrsCore::close] 逐个关掉）。调用方持读连接的锁。
    fn register_session(&self, conn: Connection) -> Result<Arc<ReadSession>, String> {
        let session = Arc::new(ReadSession { conn: Mutex::new(Some(conn)) });
        let mut sessions = self.sessions.lock().map_err(|_| "srs sessions poisoned".to_string())?;
        sessions.retain(|w| w.strong_count() > 0);
        sessions.push(Arc::downgrade(&session));
        Ok(session)
    }

    /// 把 WAL 并回主库（PASSIVE），在一条单独开的连接上做：不占写连接，并回期间本机作答照常写入（SQLite 的
    /// checkpoint 锁与写锁互不相干，PASSIVE 也不等读者）。大批写入暂停自动 checkpoint 之后收尾用（Dart
    /// `SrsDbStore.bulkWrites`）：在写连接上并回几十 MB 的 WAL 要几百毫秒，那期间所有写入都排在它后面。
    /// 这条连接登记成会话，库关闭时等它做完再关。返回 `{busy, log, checkpointed}`（`PRAGMA wal_checkpoint` 的三列）。
    pub fn wal_checkpoint(&self) -> Result<serde_json::Value, String> {
        let session = {
            let _open = self.reader()?;
            let conn = Connection::open_with_flags(
                &self.path,
                OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_NO_MUTEX,
            )
            .map_err(|e| format!("open checkpoint connection {}: {e}", self.path.display()))?;
            conn.busy_timeout(Duration::from_millis(5000)).map_err(|e| e.to_string())?;
            let session = Arc::new(ReadSession { conn: Mutex::new(Some(conn)) });
            let mut sessions = self.sessions.lock().map_err(|_| "srs sessions poisoned".to_string())?;
            sessions.retain(|w| w.strong_count() > 0);
            sessions.push(Arc::downgrade(&session));
            session
        };
        let out = {
            let guard = session.conn.lock().map_err(|_| "srs checkpoint connection poisoned".to_string())?;
            let conn = guard.as_ref().ok_or(CLOSED)?;
            conn.query_row("PRAGMA wal_checkpoint(PASSIVE)", [], |r| {
                Ok((r.get::<_, i64>(0)?, r.get::<_, i64>(1)?, r.get::<_, i64>(2)?))
            })
            .map_err(|e| e.to_string())
        };
        session.close();
        let (busy, log, checkpointed) = out?;
        Ok(serde_json::json!({"busy": busy != 0, "log": log, "checkpointed": checkpointed}))
    }
}

/// 这些组里全部卡的日志原文 + 服务器时刻（[conn] 上一条 JOIN 按块取；写连接看得见 Drift 事务里未提交的行）。
pub(crate) fn logs_of(
    conn: &rusqlite::Connection,
    groups: &[Vec<String>],
) -> Result<std::collections::HashMap<String, Vec<(String, Option<i64>)>>, String> {
    let mut wanted: Vec<&str> = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for g in groups {
        for c in g {
            if seen.insert(c.as_str()) {
                wanted.push(c.as_str());
            }
        }
    }
    let mut logs: std::collections::HashMap<String, Vec<(String, Option<i64>)>> =
        std::collections::HashMap::with_capacity(wanted.len());
    for chunk in wanted.chunks(500) {
        let marks = vec!["?"; chunk.len()].join(", ");
        let sql = format!(
            "SELECT l.card_id, l.json, e.server_time FROM srs_review_logs l                  LEFT JOIN srs_event_local e ON e.event_id = l.id WHERE l.card_id IN ({marks})"
        );
        let mut stmt = conn.prepare_cached(&sql).map_err(|e| e.to_string())?;
        let mut q = stmt
            .query(rusqlite::params_from_iter(chunk.iter()))
            .map_err(|e| e.to_string())?;
        while let Some(row) = q.next().map_err(|e| e.to_string())? {
            let card: String = row.get(0).map_err(|e| e.to_string())?;
            let json: String = row.get(1).map_err(|e| e.to_string())?;
            let st: Option<i64> = row.get(2).map_err(|e| e.to_string())?;
            logs.entry(card).or_default().push((json, st));
        }
    }
    Ok(logs)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp(name: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "ffsrs_store_{}_{}_{}",
            name,
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        dir.join("srs.db")
    }

    fn count(core: &SrsCore, table: &str) -> i64 {
        core.reader()
            .unwrap()
            .query_row(&format!("SELECT COUNT(*) FROM {table}"), [], |r| r.get(0))
            .unwrap()
    }

    /// 全库扫描（状态摘要）跑在登记过的扫描会话上：扫描进行中读连接照样可用（以前整段攥着读锁，走读连接的
    /// 命令全被挡几秒）；关库等在途扫描跑完、把会话一并关掉，之后经它的调用报已关闭，库文件可删。
    #[test]
    fn scan_session_leaves_the_reader_free_and_closes_with_the_store() {
        use std::sync::{Arc, Barrier};
        use std::time::{Duration, Instant};

        let p = temp("scan_session");
        let core = Arc::new(SrsCore::open(&p).unwrap());
        let scan = core.scan_session().unwrap();
        let entered = Arc::new(Barrier::new(2));
        let worker = {
            let scan = Arc::clone(&scan);
            let entered = Arc::clone(&entered);
            std::thread::spawn(move || {
                scan.with(|c| {
                    entered.wait();
                    std::thread::sleep(Duration::from_millis(300));
                    c.query_row("SELECT COUNT(*) FROM sqlite_master", [], |r| r.get::<_, i64>(0)).map_err(|e| e.to_string())
                })
            })
        };
        entered.wait();
        // 扫描在途：读连接不被它占着。
        assert!(core.reader.try_lock().is_ok(), "scan must not hold the reader lock");
        assert!(count(&core, "srs_meta") >= 0);
        let t0 = Instant::now();
        core.close();
        assert!(t0.elapsed() >= Duration::from_millis(200), "close did not wait for the in-flight scan");
        assert!(worker.join().unwrap().is_ok());
        assert_eq!(scan.with(|_| Ok(())), Err(CLOSED.to_string()));
        std::fs::remove_file(&p).unwrap();
        std::fs::remove_dir_all(p.parent().unwrap()).unwrap();
    }

    /// 关闭与在途调用互斥：另一线程正拿着读连接时 close 等它跑完；之后的命令报已关闭，文件可删。
    /// （回归：拥有者关库时后台 isolate 的命令还在跑，原来直接 free 结构体 → use-after-free。）
    #[test]
    fn close_waits_for_in_flight_calls_and_rejects_later_ones() {
        use std::sync::{Arc, Barrier};
        use std::time::Instant;

        let p = temp("close_inflight");
        let core = Arc::new(SrsCore::open(&p).unwrap());
        let started = Arc::new(Barrier::new(2));
        let worker = {
            let core = Arc::clone(&core);
            let started = Arc::clone(&started);
            std::thread::spawn(move || {
                let conn = core.reader().unwrap();
                started.wait();
                std::thread::sleep(Duration::from_millis(300));
                conn.query_row("SELECT COUNT(*) FROM sqlite_master", [], |r| r.get::<_, i64>(0))
                    .unwrap()
            })
        };
        started.wait();
        let t0 = Instant::now();
        core.close();
        assert!(
            t0.elapsed() >= Duration::from_millis(200),
            "close returned while another thread was still using the reader"
        );
        assert!(worker.join().unwrap() > 0);
        assert_eq!(core.reader().err().as_deref(), Some("srs store is closed"));
        assert_eq!(core.writer().err().as_deref(), Some("srs store is closed"));
        assert!(core.debug_query("SELECT 1", &[]).is_err());
        core.close();
        std::fs::remove_dir_all(p.parent().unwrap()).unwrap();
        // 关库后另开只读会话同样报已关闭，不按路径把（已删掉的）库文件重新打开。
        assert_eq!(core.read_session().err().as_deref(), Some(CLOSED));
        assert!(!p.exists(), "read_session reopened srs.db after close");
    }

    /// 关库让还没结束的只读会话失效：在途的会话查询跑完 close 才返回，之后会话查询报已关闭，
    /// close 返回时库文件已无打开的连接（Windows 下可删 / 改名）。
    #[test]
    fn close_ends_open_read_sessions_and_releases_the_file() {
        use std::sync::Barrier;
        use std::time::Instant;

        let p = temp("close_sessions");
        let core = Arc::new(SrsCore::open(&p).unwrap());
        let idle = core.read_session().unwrap();
        let busy = core.read_session().unwrap();
        let started = Arc::new(Barrier::new(2));
        let worker = {
            let (busy, started) = (Arc::clone(&busy), Arc::clone(&started));
            std::thread::spawn(move || {
                // 拿着会话的锁做一次慢读，close 必须等它。
                let guard = busy.conn.lock().unwrap();
                started.wait();
                std::thread::sleep(Duration::from_millis(300));
                guard
                    .as_ref()
                    .unwrap()
                    .query_row("SELECT COUNT(*) FROM sqlite_master", [], |r| r.get::<_, i64>(0))
                    .unwrap()
            })
        };
        started.wait();
        let t0 = Instant::now();
        core.close();
        assert!(
            t0.elapsed() >= Duration::from_millis(200),
            "close returned while a read session query was still running"
        );
        assert!(worker.join().unwrap() > 0);
        for s in [&idle, &busy] {
            assert_eq!(s.query("SELECT 1", &[]).err().as_deref(), Some(CLOSED));
        }
        // 会话对象还活着，但连接都没了：库文件能改名、能删。
        let moved = p.with_file_name("srs.moved.db");
        std::fs::rename(&p, &moved).unwrap();
        std::fs::remove_file(&moved).unwrap();
        idle.close();
        drop((idle, busy));
        std::fs::remove_dir_all(p.parent().unwrap()).unwrap();
    }

    #[test]
    fn open_creates_schema_and_is_idempotent() {
        let p = temp("open");
        {
            let core = SrsCore::open(&p).unwrap();
            assert!(!core.legacy_imported().unwrap());
            for t in schema::TABLES {
                assert_eq!(count(&core, t.name), 0);
            }
        }
        let core = SrsCore::open(&p).unwrap();
        let idx: i64 = core
            .reader()
            .unwrap()
            .query_row(
                "SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name LIKE 'idx_srs_%'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(idx, 14);
    }

    #[test]
    fn schema_v1_database_upgrades_to_v2_indexes() {
        let p = temp("schema_v1");
        {
            let core = SrsCore::open(&p).unwrap();
            core.writer()
                .unwrap()
                .execute_batch(
                    "DROP INDEX idx_srs_field_edits_profile_register; DROP INDEX idx_srs_notes_cache_type; \
                     DROP INDEX idx_srs_notes_cache_pending; UPDATE srs_meta SET value = '1' WHERE key = 'schema';",
                )
                .unwrap();
        }
        let core = SrsCore::open(&p).unwrap();
        let r = core.reader().unwrap();
        let n: i64 = r
            .query_row(
                "SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name IN \
                 ('idx_srs_field_edits_profile_register','idx_srs_notes_cache_type','idx_srs_notes_cache_pending')",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(n, 3);
        let v: String = r
            .query_row("SELECT value FROM srs_meta WHERE key = 'schema'", [], |row| row.get(0))
            .unwrap();
        assert_eq!(v, schema::SCHEMA_VERSION.to_string());
    }

    #[test]
    fn legacy_import_roundtrip_and_rollback() {
        let p = temp("legacy");
        let core = SrsCore::open(&p).unwrap();
        let page = rows::encode(
            3,
            &[
                vec![Value::Text("e1".into()), Value::Text("p".into()), Value::Text("{}".into())],
                vec![Value::Text("e2".into()), Value::Text("p".into()), Value::Text("{\"a\":1}".into())],
            ],
        );
        core.legacy_begin().unwrap();
        assert_eq!(core.legacy_page("srs_unknown_events", &page).unwrap(), 2);
        core.legacy_abort().unwrap();
        assert_eq!(count(&core, "srs_unknown_events"), 0);
        assert!(!core.legacy_imported().unwrap());

        core.legacy_begin().unwrap();
        core.legacy_page("srs_unknown_events", &page).unwrap();
        assert!(core.legacy_page("srs_nope", &page).is_err());
        let bad_cols = rows::encode(2, &[vec![Value::Text("x".into()), Value::Null]]);
        assert!(core.legacy_page("srs_unknown_events", &bad_cols).is_err());
        core.legacy_commit().unwrap();
        assert!(core.legacy_imported().unwrap());
        assert_eq!(count(&core, "srs_unknown_events"), 2);
        assert!(core.legacy_begin().is_err());
    }

    #[test]
    fn snapshot_strips_device_local_tables() {
        let p = temp("snap");
        let core = SrsCore::open(&p).unwrap();
        core.legacy_begin().unwrap();
        core.legacy_page(
            "srs_local_state",
            &rows::encode(2, &[vec![Value::Text("p".into()), Value::Text("{}".into())]]),
        )
        .unwrap();
        core.legacy_page(
            "srs_unknown_events",
            &rows::encode(
                3,
                &[vec![Value::Text("e".into()), Value::Text("p".into()), Value::Text("{}".into())]],
            ),
        )
        .unwrap();
        core.legacy_commit().unwrap();
        let snap = p.with_file_name("snap.db");
        core.snapshot_into(&snap, true).unwrap();
        let s = SrsCore::open(&snap).unwrap();
        assert_eq!(count(&s, "srs_local_state"), 0);
        assert_eq!(count(&s, "srs_unknown_events"), 1);
        assert!(!s.legacy_imported().unwrap());
    }

    #[test]
    fn read_session_reads_one_snapshot_and_rejects_writes() {
        let p = temp("session");
        let core = SrsCore::open(&p).unwrap();
        core.legacy_mark_none().unwrap();
        let ins = |id: &str| {
            core.writer()
                .unwrap()
                .execute(
                    "INSERT INTO srs_unknown_events (id, profile_uid, json) VALUES (?1, 'p', '{}')",
                    [id],
                )
                .unwrap();
        };
        ins("e1");
        let s = core.read_session().unwrap();
        ins("e2");
        let count = |s: &ReadSession| {
            let (_, rows) =
                rows::decode(&s.query("SELECT COUNT(*) AS c FROM srs_unknown_events", &[]).unwrap()).unwrap();
            rows[1][0].clone()
        };
        assert_eq!(count(&s), Value::Integer(1), "会话开始之后的写入不在快照里");
        assert!(s.query("DELETE FROM srs_unknown_events", &[]).is_err());
        drop(s);
        assert_eq!(count(&core.read_session().unwrap()), Value::Integer(2));
    }

    #[test]
    fn debug_query_rejects_writes_and_encodes_header() {
        let p = temp("dbg");
        let core = SrsCore::open(&p).unwrap();
        assert!(core.debug_query("DELETE FROM srs_meta", &[]).is_err());
        let out = core
            .debug_query("SELECT key, value FROM srs_meta WHERE key = ?1", &[Value::Text("schema".into())])
            .unwrap();
        let (cols, rows) = rows::decode(&out).unwrap();
        assert_eq!(cols, 2);
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0][0], Value::Text("key".into()));
        assert_eq!(rows[1][1], Value::Text(schema::SCHEMA_VERSION.to_string()));
    }
}

#[cfg(test)]
mod exec_tests {
    use super::*;

    #[test]
    fn exec_select_insert_and_transactions() {
        let dir = std::env::temp_dir().join(format!("ffsrs_exec_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let p = dir.join("srs.db");
        let _ = std::fs::remove_file(&p);
        let core = SrsCore::open(&p).unwrap();
        core.legacy_mark_none().unwrap();
        core.exec("BEGIN", &[], false).unwrap();
        assert!(core.in_transaction().unwrap());
        let r = core
            .exec(
                "INSERT INTO srs_unknown_events (id, profile_uid, json) VALUES (?1, ?2, ?3)",
                &[Value::Text("a".into()), Value::Text("p".into()), Value::Text("{}".into())],
                false,
            )
            .unwrap();
        let (_, rows) = rows::decode(&r).unwrap();
        assert_eq!(rows[0][0], Value::Integer(1));
        // 同一条连接，事务里看得见。
        let s = core.exec("SELECT id FROM srs_unknown_events", &[], true).unwrap();
        let (cols, rows) = rows::decode(&s).unwrap();
        assert_eq!(cols, 1);
        assert_eq!(rows.len(), 2);
        core.exec("ROLLBACK", &[], false).unwrap();
        assert!(!core.in_transaction().unwrap());
        core.exec_batch(
            &["INSERT INTO srs_unknown_events (id, profile_uid, json) VALUES (?, 'p', '{}')"],
            &[(0, vec![Value::Text("b".into())]), (0, vec![Value::Text("c".into())])],
        )
        .unwrap();
        let s = core.exec("SELECT COUNT(*) FROM srs_unknown_events", &[], true).unwrap();
        let (_, rows) = rows::decode(&s).unwrap();
        assert_eq!(rows[1][0], Value::Integer(2));
        assert!(core.exec("SELECT nope", &[], true).is_err());
    }
}

#[cfg(test)]
mod read_routing_tests {
    use super::*;
    use std::sync::mpsc;
    use std::time::Duration;

    fn open(name: &str) -> SrsCore {
        let dir = std::env::temp_dir().join(format!("ffsrs_route_{name}_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let p = dir.join("srs.db");
        let _ = std::fs::remove_file(&p);
        let _ = std::fs::remove_file(dir.join("srs.db-wal"));
        let core = SrsCore::open(&p).unwrap();
        core.legacy_mark_none().unwrap();
        core
    }

    fn insert(core: &SrsCore, id: &str) {
        core.exec(
            "INSERT INTO srs_unknown_events (id, profile_uid, json) VALUES (?1, 'p', '{}')",
            &[Value::Text(id.into())],
            false,
        )
        .unwrap();
    }

    fn scalar(page: &[u8]) -> Value {
        let (_, rows) = rows::decode(page).unwrap();
        rows[1][0].clone()
    }

    fn count(core: &SrsCore) -> Value {
        scalar(&core.select("SELECT COUNT(*) FROM srs_unknown_events", &[]).unwrap())
    }

    /// `last_insert_rowid()` 是每条连接自己的：写连接上刚插过行就非 0，读连接上恒为 0。用它看查询落在哪条连接上。
    fn on_writer(core: &SrsCore) -> bool {
        scalar(&core.select("SELECT last_insert_rowid()", &[]).unwrap()) != Value::Integer(0)
    }

    #[test]
    fn snapshot_query_admits_only_plain_queries() {
        for q in ["SELECT 1", "  select 1", "WITH x AS (SELECT 1) SELECT * FROM x", "VALUES (1)", "-- c\nSELECT 1", "/* c */ SELECT 1"] {
            assert!(snapshot_query(q), "{q}");
        }
        for q in ["BEGIN", "BEGIN TRANSACTION", "SAVEPOINT s1", "COMMIT", "ROLLBACK", "PRAGMA wal_autocheckpoint", "INSERT INTO t VALUES (1)", "", "-- only a comment"] {
            assert!(!snapshot_query(q), "{q}");
        }
    }

    /// Drift 事务外：查询走读连接的已提交快照——写后立即读得到；一笔 Rust 写命令攥着写锁、事务还没提交时，
    /// 查询不排队（在写锁释放前就返回）也读不到那笔未提交的行；那笔提交后立刻读得到。
    #[test]
    fn select_outside_a_drift_transaction_reads_the_committed_snapshot_without_the_write_lock() {
        let core = Arc::new(open("outside"));
        insert(&core, "a");
        // 写后立即读（read-your-writes）：autocommit 写在 exec 返回前已提交，读连接新开的读事务看得见。
        assert_eq!(count(&core), Value::Integer(1));
        assert!(!on_writer(&core), "out-of-transaction query ran on the writer");
        // 另一条线程攥着写锁、开着一笔没提交的写事务（Rust 写命令的形态：in_savepoint 在 autocommit 连接上自成事务）。
        let (held_tx, held_rx) = mpsc::channel::<()>();
        let (release_tx, release_rx) = mpsc::channel::<()>();
        let writer = {
            let core = Arc::clone(&core);
            std::thread::spawn(move || {
                let w = core.writer().unwrap();
                in_savepoint_for_test(&w, || {
                    w.execute("INSERT INTO srs_unknown_events (id, profile_uid, json) VALUES ('dirty', 'p', '{}')", [])
                        .unwrap();
                    held_tx.send(()).unwrap();
                    release_rx.recv().unwrap();
                });
            })
        };
        held_rx.recv().unwrap();
        let (done_tx, done_rx) = mpsc::channel::<Value>();
        let reader = {
            let core = Arc::clone(&core);
            std::thread::spawn(move || done_tx.send(count(&core)).unwrap())
        };
        // 写锁仍被攥着：查询必须自己返回（不等写锁），且看不到未提交的行。
        let seen = done_rx.recv_timeout(Duration::from_secs(5)).expect("query waited for the write lock");
        assert_eq!(seen, Value::Integer(1), "read an uncommitted row");
        reader.join().unwrap();
        release_tx.send(()).unwrap();
        writer.join().unwrap();
        // 那笔提交了：下一条查询立刻看得见。
        assert_eq!(count(&core), Value::Integer(2));
    }

    fn in_savepoint_for_test(conn: &Connection, body: impl FnOnce()) {
        conn.execute_batch("SAVEPOINT t").unwrap();
        body();
        conn.execute_batch("RELEASE t").unwrap();
    }

    /// Drift 事务内（BEGIN 经 runCustom = exec(select) 开）：查询留在写连接上，同事务读得到刚写的未提交行；
    /// 同一时刻读连接上的只读命令只看已提交的；回滚后查询回到读连接，未提交的行消失。嵌套 SAVEPOINT 同样。
    #[test]
    fn select_inside_a_drift_transaction_sees_its_uncommitted_rows() {
        let core = open("inside");
        insert(&core, "a");
        core.exec("BEGIN TRANSACTION", &[], true).unwrap();
        insert(&core, "b");
        assert_eq!(count(&core), Value::Integer(2), "transaction did not see its own write");
        assert!(on_writer(&core), "in-transaction query left the writer");
        // 事务外的读（读连接上的 Rust 只读命令 / 诊断查询）不读脏数据。
        assert_eq!(scalar(&core.debug_query("SELECT COUNT(*) FROM srs_unknown_events", &[]).unwrap()), Value::Integer(1));
        assert_eq!(core.read_visible(|c| c.query_row("SELECT COUNT(*) FROM srs_unknown_events", [], |r| r.get::<_, i64>(0)).map_err(|e| e.to_string())).unwrap(), 2,
            "a read-only command inside the Drift transaction must read on the writer");
        core.exec("SAVEPOINT s1", &[], true).unwrap();
        insert(&core, "c");
        assert_eq!(count(&core), Value::Integer(3));
        core.exec("ROLLBACK TO s1", &[], true).unwrap();
        core.exec("RELEASE s1", &[], true).unwrap();
        assert_eq!(count(&core), Value::Integer(2));
        core.exec("ROLLBACK TRANSACTION", &[], true).unwrap();
        assert!(!core.in_transaction().unwrap());
        assert_eq!(count(&core), Value::Integer(1));
        assert!(!on_writer(&core));
        core.exec("BEGIN TRANSACTION", &[], true).unwrap();
        insert(&core, "d");
        core.exec("COMMIT TRANSACTION", &[], true).unwrap();
        assert_eq!(count(&core), Value::Integer(2), "committed Drift transaction not visible to the next query");
        assert!(!on_writer(&core));
        // 批量语句里出错、事务没了：路由跟着写连接的真实状态走。
        core.exec("BEGIN TRANSACTION", &[], true).unwrap();
        assert!(core.exec_batch(&["COMMIT", "INSERT INTO nope VALUES (1)"], &[(0, vec![]), (1, vec![])]).is_err());
        assert!(!core.in_transaction().unwrap());
        assert!(!on_writer(&core));
    }

    /// 留在写连接上的「查询」：PRAGMA 读写连接自己的设置；`… RETURNING` 是写语句。
    #[test]
    fn pragmas_and_returning_stay_on_the_writer() {
        let core = open("pragma");
        core.exec("PRAGMA wal_autocheckpoint = 0", &[], true).unwrap();
        assert_eq!(scalar(&core.select("PRAGMA wal_autocheckpoint", &[]).unwrap()), Value::Integer(0));
        core.exec("PRAGMA wal_autocheckpoint = 1000", &[], true).unwrap();
        let page = core
            .select("INSERT INTO srs_unknown_events (id, profile_uid, json) VALUES ('r', 'p', '{}') RETURNING id", &[])
            .unwrap();
        assert_eq!(scalar(&page), Value::Text("r".into()));
        assert_eq!(count(&core), Value::Integer(1));
    }
}

#[cfg(test)]
mod direct_tests {
    use super::*;

    #[test]
    fn history_states_reads_uncommitted_logs_on_the_writer() {
        let dir = std::env::temp_dir().join(format!("ffsrs_hist_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let p = dir.join("srs.db");
        let _ = std::fs::remove_file(&p);
        let core = SrsCore::open(&p).unwrap();
        core.legacy_mark_none().unwrap();
        // 没有日志：新卡状态。
        let empty = core.history_states(&[vec!["c1".into()]]).unwrap();
        let expect_new = crate::history::encode_states(&[
            crate::history::state_from_json(&[], &[]).unwrap(),
        ]);
        assert_eq!(empty, expect_new);
        core.exec("BEGIN", &[], false).unwrap();
        core.exec(
            "INSERT INTO srs_review_logs (id, profile_uid, card_id, kind, rating, occurred_at, \
             review_type, origin, duration_ms, json) VALUES ('x', 'p', 'c1', 'k', NULL, 0, 'r', 'o', 0, 'not json')",
            &[],
            false,
        )
        .unwrap();
        // 事务里新插的那行（坏 JSON）被读到了 → 解析报错。
        assert!(core.history_states(&[vec!["c1".into()]]).is_err());
        core.exec("ROLLBACK", &[], false).unwrap();
        assert_eq!(core.history_states(&[vec!["c1".into()]]).unwrap(), expect_new);
    }

    fn log(id: &str, card: &str, ms: i64, rtype: &str, rating: i64, res: &str) -> String {
        format!(
            r#"{{"id":"{id}","p":"p","card":"{card}","kind":"review","hlc":"{ms}:0:w","at":{ms},"rtype":"{rtype}","rating":{rating},"dur":1500,"utcOff":540,"res":{res}}}"#
        )
    }

    #[test]
    fn stat_projection_classifies_on_the_merged_history_of_the_owner_group() {
        let dir = std::env::temp_dir().join(format!("ffsrs_stat_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let p = dir.join("srs.db");
        let _ = std::fs::remove_file(&p);
        let core = SrsCore::open(&p).unwrap();
        core.legacy_mark_none().unwrap();
        let day = 86_400_000;
        let mature = r#"{"queue":"review","ivl":30,"dueDay":100}"#;
        let a = log("a", "old", day, "learn", 3, mature);
        let b = log("b", "c1", 2 * day, "review", 3, r#"{"queue":"review","ivl":5,"dueDay":105}"#);
        let c = log("c", "c1", 3 * day, "review", 1, mature);
        let undo = r#"{"id":"u","p":"p","card":"c1","kind":"undo","hlc":"260000000:0:w","at":260000000,"revokes":"c"}"#;
        for (id, card, json) in [("a", "old", a.as_str()), ("b", "c1", b.as_str()), ("c", "c1", c.as_str()), ("u", "c1", undo)] {
            core.exec(
                "INSERT INTO srs_review_logs (id, profile_uid, card_id, kind, rating, occurred_at, \
                 review_type, origin, duration_ms, json) VALUES (?1, 'p', ?2, 'k', NULL, 0, 'r', 'o', 0, ?3)",
                &[Value::Text(id.into()), Value::Text(card.into()), Value::Text(json.into())],
                false,
            )
            .unwrap();
        }
        let page = core.stat_projection(&[vec!["c1".into(), "old".into()]]).unwrap();
        let (cols, rows) = rows::decode(&page).unwrap();
        assert_eq!(cols, 9);
        let row = |id: &str, at: i64, rating: i64, kind: i64, prev: Value, delta: i64| {
            vec![
                Value::Integer(0),
                Value::Text(id.into()),
                Value::Integer(at),
                Value::Integer(540),
                Value::Integer(rating),
                Value::Integer(kind),
                Value::Integer(1500),
                prev,
                Value::Integer(delta),
            ]
        };
        assert_eq!(
            rows,
            vec![
                // 前身卡的学习：新卡，学完即成熟。
                row("a", day, 3, 0, Value::Null, 1),
                // 本卡：前序（合并历史里前身那条）已是 30 天间隔 → 成熟复习，带上一条到期日；掉出成熟。
                row("b", 2 * day, 3, 3, Value::Integer(100), -1),
                // 被撤销的那条不在。
            ]
        );
    }
}

#[cfg(test)]
mod close_tests {
    use super::*;

    #[test]
    fn closing_folds_the_wal_back_into_the_main_file() {
        let dir = std::env::temp_dir().join(format!("ffsrs_close_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let p = dir.join("srs.db");
        let _ = std::fs::remove_file(&p);
        {
            let core = SrsCore::open(&p).unwrap();
            core.legacy_mark_none().unwrap();
            core.exec(
                "INSERT INTO srs_unknown_events (id, profile_uid, json) VALUES ('a', 'p', '{}')",
                &[],
                false,
            )
            .unwrap();
        }
        assert!(!p.with_file_name("srs.db-wal").exists(), "WAL left behind after close");
        // 只拷主文件也拿得到数据。
        let copy = dir.join("copy.db");
        std::fs::copy(&p, &copy).unwrap();
        let c = SrsCore::open(&copy).unwrap();
        let n: i64 = c
            .reader()
            .unwrap()
            .query_row("SELECT COUNT(*) FROM srs_unknown_events", [], |r| r.get(0))
            .unwrap();
        assert_eq!(n, 1);
    }
}
