//! 新代命令层的库句柄（规划 §2.2 S1，交接说明「S1 接线设计」）：C ABI 的库句柄（`store/ffi.rs` 的句柄表）里放的就是它。
//! 一个 [G4Core] = 一个 profile 目录里打开的新代库 `srs4.db`（`files.rs` 的打开模式），外加命令层持有的状态：
//!
//! - **连接**：Primary 一条写连接（[G4Core::writer]，互斥锁 = 写锁，唯一的写者，D10）+ 只读连接池（[G4Core::reader]）。
//!   Secondary（查词弹窗等辅助进程）没有写连接，写命令报 [READ_ONLY]。读命令不排在写锁后面（协议 3 BUG-4298 的同一个
//!   口径）；WAL 下读连接只看已提交的数据。
//!   内存映射与页缓存按协议 3 的同一份预算（`store/mod.rs` [MmapRole] / `tune_for_daily_use`）：写连接映射、读连接按
//!   平台（32 位不映射），页缓存 64 MB、写连接的上限随可用内存下调（`store/mem_budget.rs`），命令结束放回连接时超出
//!   8 MB 的页还掉（`trim_idle_cache`，批量写入期间写连接留着）。`schema::open` 的保守值只留给迁移用的连接（设计 §6.5）。
//! - **常驻会话**：浏览会话表 [Browse]（一个打开的库文件一份，在它自己的锁里；会话按缓存层代号自己失效，`cmd/browse.rs`
//!   文件头）、出卡会话 [G4Core::study]（`store/queue.rs` 的 `StudyHub`，一个打开的库文件一份、按集合号分；Primary 的写连接
//!   上装着给它记账的临时触发器，`cmd/study.rs` 文件头）、统计原料缓存（[StatsEntry]，按集合 + 统计指纹 + 写入代数 + 缓存层代号命中，未命中调
//!   `cmd/stats.rs` `snapshot_of`）。
//! - **写入代数** [G4Core::writes]：每条写命令提交之后 +1。统计原料缓存按它判「本进程的写连接上改没改过原料」；别的进程
//!   （只有 Primary 写）的写入由缓存层代号 `cache_gen` 兜住。
//! - **刷新计数**（[G4Core::refresh]，`refresh.rs`）：按 profile、按类别的进程内计数，Dart 的刷新键（牌组树、角标、统计、
//!   RWKV 分数表）据此判「这类缓存还能不能用」；写命令提交之后由分发器推进。
//! - **批量写入深度**（`bulk_cache`）：最外层调高写连接的 `wal_autocheckpoint`、结束时另开连接并回 WAL（协议 3
//!   `SrsCore::bulk_begin` 同一个口径）。
//!
//! 关库（[G4Core::close]）：先置取消令牌（[G4Core::cancel]，`cancel.rs`：在途命令在下一个批次边界 / 几十微秒内的语句
//! 进度回调里退出、事务整笔回滚），再关读连接池（等借出的放回），再关写连接（最后关的连接把 WAL 并回主文件）。之后经它
//! 的命令一律报 `CLOSED`（与协议 3 同文，Dart 按它认「已关闭」）。
//!
//! `ffsrs_store_snapshot` 已接（G11-4，[G4Core::snapshot_into]）。逐卡重放与训练集的 C 入口已接（S1b，`dispatch.rs` 末尾
//! 「C 直出入口」一节）。
//!
//! 迁移（`gen4_migrate_status` / `gen4_migrate_profiles` / `gen4_migrate_run` / `gen4_migrate_cancel`）是不针对已打开库的
//! 全局命令（[global]）：
//! 没迁移的目录根本打不开新代库，迁移入口不能挂在库句柄上。

use std::collections::{BTreeMap, BTreeSet};
use std::ops::Deref;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Condvar, Mutex, MutexGuard};

use rusqlite::types::Value as Sv;
use rusqlite::{Connection, OpenFlags};
use serde_json::{Value, json};

use super::cancel::Cancel;
use super::cmd::browse::Browse;
use super::dryrun::Stop;
use super::files::{self, OpenError, OpenMode};
use super::migrate;
use super::schema::{self, sql};
use super::truth::Truth;
use crate::store::stats::Snapshot;
use crate::store::{CLOSED, MmapRole};

/// Secondary 打开的库上发写命令。
pub const READ_ONLY: &str =
    "gen4 store: opened read-only (secondary); write commands go to the primary process";

/// 「尚未接线」错误的前缀（交接说明「S1 接线设计」的未接线臂清单）。
pub const UNWIRED: &str = "gen4: not wired yet";

/// 「新代不需要、入口已删」错误的前缀。
pub const REMOVED: &str = "gen4: removed";

/// 一条命令 / C 入口还没有新代实现：明确报错（不 panic、不回落到协议 3）。[owner] = 归哪个模块接。
pub fn unwired(what: &str, owner: &str) -> String {
    format!("{UNWIRED}: `{what}` belongs to {owner}")
}

/// 一条命令在新代里不需要、入口已删：明确报错，调用方不该再发（[why] 写原因）。
pub fn removed(what: &str, why: &str) -> String {
    format!("{REMOVED}: `{what}` ({why})")
}

/// 进程里还没释放的 [G4Core] 个数（含已从句柄表摘掉、在途调用还握着 `Arc` 的）：内存诊断用。
static LIVE: AtomicUsize = AtomicUsize::new(0);

pub fn live_cores() -> usize {
    LIVE.load(Ordering::Relaxed)
}

struct Live;

impl Live {
    fn new() -> Live {
        LIVE.fetch_add(1, Ordering::Relaxed);
        Live
    }
}

impl Drop for Live {
    fn drop(&mut self) {
        LIVE.fetch_sub(1, Ordering::Relaxed);
    }
}

// ---------------------------------------------------------------------- 只读连接池

/// 读连接池：借出时没有空闲的就新开一条（不设上限：读命令不排队），放回时空闲的超过 [Readers::cap] 就关掉多的。
struct Readers {
    path: PathBuf,
    cap: usize,
    /// 库句柄的取消令牌（[G4Core] `cancel`）：每条读连接装它的进度回调，置位之后借不出。
    cancel: Cancel,
    st: Mutex<Pool>,
    returned: Condvar,
}

#[derive(Default)]
struct Pool {
    idle: Vec<Connection>,
    out: usize,
    closed: bool,
}

impl Readers {
    fn lock(&self) -> MutexGuard<'_, Pool> {
        // 锁里只有 Vec 的进出与计数，不跑用户代码：毒化了表也完好。
        self.st.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn open_one(&self) -> Result<Connection, String> {
        #[cfg_attr(not(feature = "id_audit"), allow(unused_mut))]
        let mut c = files::open_secondary(&self.path)?;
        c.busy_timeout(schema::BUSY_TIMEOUT).map_err(sql)?;
        crate::store::tune_for_daily_use(&c, MmapRole::Secondary)?;
        #[cfg(feature = "id_audit")]
        super::id_audit::install(&mut c);
        self.cancel.watch(&c);
        Ok(c)
    }

    fn borrow(&self) -> Result<Reader<'_>, String> {
        self.cancel.check()?;
        let idle = {
            let mut st = self.lock();
            if st.closed {
                return Err(CLOSED.to_owned());
            }
            st.out += 1;
            st.idle.pop()
        };
        let conn = match idle {
            Some(c) => c,
            None => match self.open_one() {
                Ok(c) => c,
                Err(e) => {
                    self.put_back(None);
                    return Err(e);
                }
            },
        };
        Ok(Reader {
            pool: self,
            conn: Some(conn),
        })
    }

    /// 放回（[conn] = None：借出失败）。库已关、空闲的够多、或连接停在事务里（命令 panic 跳过了提交 / 回滚）就关掉它。
    fn put_back(&self, conn: Option<Connection>) {
        let mut st = self.lock();
        st.out = st.out.saturating_sub(1);
        if let Some(c) = conn {
            if !st.closed && st.idle.len() < self.cap && c.is_autocommit() {
                st.idle.push(c);
            }
        }
        if st.closed && st.out == 0 {
            self.returned.notify_all();
        }
    }

    /// 关池：之后借不出；等借出的全部放回，空闲的关掉。
    fn close(&self) {
        let mut st = self.lock();
        st.closed = true;
        st.idle.clear();
        while st.out > 0 {
            st = self.returned.wait(st).unwrap_or_else(|e| e.into_inner());
        }
    }

    /// 眼下开着的连接数（空闲 + 借出）。
    fn live(&self) -> usize {
        let st = self.lock();
        st.idle.len() + st.out
    }
}

/// 借出的读连接（析构时放回；放回前页缓存超出命令之间的上限就还掉，`crate::store::trim_idle_cache`）。
pub struct Reader<'a> {
    pool: &'a Readers,
    conn: Option<Connection>,
}

impl Deref for Reader<'_> {
    type Target = Connection;
    fn deref(&self) -> &Connection {
        self.conn.as_ref().expect("reader is held until drop")
    }
}

impl Drop for Reader<'_> {
    fn drop(&mut self) {
        if let Some(c) = self.conn.as_ref() {
            crate::store::trim_idle_cache(c);
        }
        self.pool.put_back(self.conn.take());
    }
}

/// 拿着写锁的写连接。析构（放锁）时页缓存超出命令之间的上限就还掉（`crate::store::trim_idle_cache`），批量写入期间
/// 留着（[G4Core] `bulk_holds_cache`）。
pub struct Writer<'a> {
    guard: MutexGuard<'a, Option<Connection>>,
    study: &'a crate::store::queue::StudyHub,
    hold: &'a AtomicBool,
}

impl Drop for Writer<'_> {
    /// 写锁放下之前：写连接回到了自动提交（事务已提交或回滚完）就把出卡会话的「未提交」待重读挪成已提交（协议 3 写锁
    /// 守卫同一个口径，`store/queue.rs` 文件头「事务边界」）；批量写入之外收回空闲页缓存。
    fn drop(&mut self) {
        if let Some(c) = self.guard.as_ref() {
            if c.is_autocommit() {
                self.study.settle();
            }
            if !self.hold.load(Ordering::Relaxed) {
                crate::store::trim_idle_cache(c);
            }
        }
    }
}

impl Deref for Writer<'_> {
    type Target = Connection;
    fn deref(&self) -> &Connection {
        self.guard.as_ref().expect("checked when taken")
    }
}

// ---------------------------------------------------------------------- 统计原料缓存 / 批量写入

/// 统计原料缓存的一份：哪个集合、统计指纹（请求的 `key`，Dart `statsFingerprint`）、读它时的写入代数与缓存层代号。
pub(super) struct StatsEntry {
    pub(super) col: i64,
    pub(super) key: String,
    pub(super) writes: u64,
    pub(super) mark: (i64, i64),
    pub(super) snap: Arc<Snapshot>,
}

#[derive(Default)]
struct Bulk {
    depth: u32,
    restore: i64,
}

// ---------------------------------------------------------------------- 库句柄

pub struct G4Core {
    dir: PathBuf,
    path: PathBuf,
    mode: OpenMode,
    // 字段按声明顺序析构：读连接池先关，写连接最后关（最后关的连接把 WAL 并回主文件）。
    readers: Readers,
    writer: Mutex<Option<Connection>>,
    /// 浏览会话表（`cmd/browse.rs`）：一个打开的库文件一份。
    pub(super) browse: Mutex<Browse>,
    /// 出卡常驻会话（`cmd/study.rs`，会话本体 `store/queue.rs`）：一个打开的库文件一份，按集合号分；Primary 的写连接上
    /// 装着给它记账的临时触发器（`cmd::study::install_touch`）。
    pub(super) study: Arc<crate::store::queue::StudyHub>,
    /// 统计原料缓存（最近一份）。
    pub(super) stats: Mutex<Option<StatsEntry>>,
    /// 写入代数：每条写命令提交之后 +1（模块文件头）。
    pub(super) writes: AtomicU64,
    bulk: Mutex<Bulk>,
    /// 进程内刷新计数（`refresh.rs`，S1c）：按 profile、按类别，写命令提交之后推进，`refresh_keys` 只读它。
    pub(super) refresh: Mutex<super::refresh::Refresh>,
    /// 彻底清除的字节层收尾被读者挡住了（`scrub.rs`）：之后的写命令提交之后不等地再试。出错不置位（原因记在库里，
    /// 下一次打开 / 下一次清除再试）。
    scrub_pending: AtomicBool,
    /// 连接内存预算（协议 3 同一份，`store/mod.rs` `tune_for_daily_use`）：写连接页缓存上限按可用内存自适应的状态
    /// （`store/mem_budget.rs`），与批量写入期间写连接放回时留着页缓存（[G4Core] `bulk` 深度的无锁镜像：写连接守卫
    /// 析构时不能去拿那把锁，只由 [G4Core::bulk] 与深度一起写）。
    writer_cache: Mutex<crate::store::mem_budget::WriterCache>,
    bulk_holds_cache: AtomicBool,
    /// 各集合解析好的缓存配置（`cache.rs` [super::cache::CfgMemo]），经 [G4Core::truth] 交给每条命令的 [Truth]。
    cfg_memo: Arc<super::cache::CfgMemo>,
    /// 在途命令的取消令牌（`cancel.rs`）：关库时置位（[G4Core::cancel]），与读连接池共用同一个开关。
    cancel: Cancel,
    _live: Live,
}

/// Primary 开库时补建闭包检查点没做成的原因（`srs_meta`；补成了删掉）。只作诊断记录：开库不因它失败，下一次写命令的收尾照样补建。
pub(crate) const CLOSURE_BACKFILL_ERROR_KEY: &str = "gen4_closure_backfill_error";

/// Primary 开库时补建检查点之前建的闭包行（[super::derive::closure_steps_missing] 先问一句，有才开写事务）：每个
/// 集合一次 [Index::backfill_closure_steps](super::derive::Index::backfill_closure_steps)，同一个事务。返回补了几台。
fn backfill_closure_steps(
    conn: &Connection,
    cfg_memo: &Arc<super::cache::CfgMemo>,
) -> Result<u64, String> {
    if !super::derive::closure_steps_missing(conn)? {
        return Ok(0);
    }
    let t = Truth::with_cfg_memo(conn, cfg_memo.clone());
    t.tx_immediate(|t| {
        let cols: Vec<i64> = {
            let mut stmt = t
                .conn()
                .prepare_cached(super::dispatch::COLLECTIONS_SQL)
                .map_err(sql)?;
            let rows = stmt.query_map([], |r| r.get(0)).map_err(sql)?;
            rows.collect::<Result<_, _>>().map_err(sql)?
        };
        let mut n = 0;
        for col in cols {
            n += super::derive::Index::new(t, col).backfill_closure_steps()?;
        }
        Ok(n)
    })
}

impl G4Core {
    /// 打开 [dir] 里的新代库（`files::open_gen4` 的打开模式；没迁移 / 迁移中 / 旁边有没迁移的旧库照它报）。
    pub fn open(dir: &Path, mode: OpenMode) -> Result<G4Core, OpenError> {
        #[cfg_attr(not(feature = "id_audit"), allow(unused_mut))]
        let mut opened = files::open_gen4(dir, mode)?;
        // 审计版的库（`id_audit`）：每条连接都装语句审计（`id_audit.rs`），读连接在 [Readers::open_one] 里装。
        #[cfg(feature = "id_audit")]
        super::id_audit::install(&mut opened.conn);
        let path = dir.join(files::GEN4_FILE);
        let cancel = Cancel::new();
        let readers = Readers {
            path: path.clone(),
            cap: crate::store::read_pool::read_concurrency().max(1),
            cancel: cancel.clone(),
            st: Mutex::new(Pool::default()),
            returned: Condvar::new(),
        };
        let mut scrub_due = false;
        let cfg_memo: Arc<super::cache::CfgMemo> = Arc::default();
        let study = Arc::new(crate::store::queue::StudyHub::default());
        let writer = match mode {
            OpenMode::Primary => {
                opened
                    .conn
                    .busy_timeout(schema::BUSY_TIMEOUT)
                    .map_err(sql)?;
                // 日常连接的内存映射与页缓存（`schema::open` 给的是迁移用的保守值，设计 §6.5）。
                crate::store::tune_for_daily_use(&opened.conn, MmapRole::Primary)?;
                // 开一条读连接放进池里：读得了才算打开成功（也让诊断计数里有连接）。
                let first = readers.open_one()?;
                readers.lock().idle.push(first);
                // 上次清除提交之后没来得及收尾（进程被杀、检查点被挡、出过错）：现在做（`scrub.rs`）。被读者挡住 = 之后
                // 的写命令不等地再试；出错 = 原因已由 `scrub` 记进库（`ERROR_KEY`，读命令 `scrub_state` 报给 UI），
                // 不逐条写命令重试，下一次打开或下一次清除再试。打开本身不因收尾没做成而失败。
                if super::scrub::due(&opened.conn)? {
                    scrub_due = matches!(
                        super::scrub::scrub(&opened.conn, super::scrub::Wait::Yes, None),
                        Ok(false)
                    );
                }
                // 已删的换代前预演留在库旁的工作目录（G7-6，`migrate.rs` [super::migrate::LEFTOVER_REHEARSAL_DIR]）：Primary
                // 是这个目录唯一的写者，幂等删掉。删不掉（文件被别的进程占着、权限）不挡开库：那只是一份过时的副本，与
                // 用户的卡片无关，因它打不开库才是让用户出问题；下一次 Primary 打开或迁移再删。
                let _ = super::migrate::remove_leftover_rehearsal(dir);
                // 检查点之前建的旧闭包行（`derive.rs` `CLOSURE_STEP`：检查点上线前迁移的库）补上检查点，否则在第一次写命令
                // 的收尾补建之前，每次排队都要把承袭设备的旧戳从头解一遍（真库 1.7 s）。只补闭包行、整份闭包不变：不推进
                // 写入代数、不碰缓存层，装学习会话触发器之前做（它只记卡 / 日志 / 卡的寄存器，本来也看不见）。补不成（出错、
                // 整份闭包与日志对不上）整笔回滚、不挡开库：下一次写命令的收尾照样补建；没补成的原因记进
                // [CLOSURE_BACKFILL_ERROR_KEY]（与 `scrub` / `retained` 同一做法，记不下 = 库写不了，报回去），补成了删掉。
                match backfill_closure_steps(&opened.conn, &cfg_memo) {
                    Ok(_) => opened
                        .conn
                        .execute(
                            "DELETE FROM srs_meta WHERE key = ?1",
                            [CLOSURE_BACKFILL_ERROR_KEY],
                        )
                        .map_err(sql)?,
                    Err(e) => opened
                        .conn
                        .execute(
                            "INSERT INTO srs_meta (key, value) VALUES (?1, ?2)                              ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                            [CLOSURE_BACKFILL_ERROR_KEY, e.as_str()],
                        )
                        .map_err(sql)?,
                };
                super::cmd::study::install_touch(&study, &opened.conn)?;
                cancel.watch(&opened.conn);
                Some(opened.conn)
            }
            // Secondary 不写（辅助进程可能在只读沙箱里）：缺检查点的闭包行照旧从头并，等 Primary 打开或写命令收尾补建。
            OpenMode::Secondary => {
                opened
                    .conn
                    .busy_timeout(schema::BUSY_TIMEOUT)
                    .map_err(sql)?;
                crate::store::tune_for_daily_use(&opened.conn, MmapRole::Secondary)?;
                cancel.watch(&opened.conn);
                readers.lock().idle.push(opened.conn);
                None
            }
        };
        Ok(G4Core {
            dir: dir.to_owned(),
            path,
            mode,
            readers,
            writer: Mutex::new(writer),
            browse: Mutex::new(Browse::new()),
            study,
            stats: Mutex::new(None),
            writes: AtomicU64::new(0),
            bulk: Mutex::new(Bulk::default()),
            refresh: Mutex::new(super::refresh::Refresh::new()),
            scrub_pending: AtomicBool::new(scrub_due),
            writer_cache: Mutex::new(crate::store::mem_budget::WriterCache::new()),
            bulk_holds_cache: AtomicBool::new(false),
            cfg_memo,
            cancel,
            _live: Live::new(),
        })
    }

    pub fn dir(&self) -> &Path {
        &self.dir
    }

    pub fn mode(&self) -> OpenMode {
        self.mode
    }

    /// 写连接（拿写锁）。一次命令持着写锁 panic 之后（锁被毒化），连接上可能还挂着它开的事务：整笔回滚再交出（协议 3
    /// `SrsCore::writer` 的恢复口径，BUG-4297）——下一条命令的写入不能落进那笔半截事务。
    pub fn writer(&self) -> Result<Writer<'_>, String> {
        self.cancel.check()?;
        let guard = crate::store::lock_recovering(&self.writer, |w| {
            if let Some(c) = w.as_ref() {
                if !c.is_autocommit() {
                    c.execute_batch("ROLLBACK").map_err(|e| {
                        format!("gen4 store: roll back a transaction left open by a panic: {e}")
                    })?;
                }
            }
            Ok(())
        })?;
        if guard.is_none() {
            return Err(match self.mode {
                OpenMode::Secondary => READ_ONLY.to_owned(),
                OpenMode::Primary => CLOSED.to_owned(),
            });
        }
        let w = Writer {
            guard,
            study: &self.study,
            hold: &self.bulk_holds_cache,
        };
        crate::store::retune_writer_cache(&self.writer_cache, &w);
        Ok(w)
    }

    /// [conn] 上一条命令的 [Truth]：带上本库的缓存配置记忆（[G4Core] `cfg_memo`）。命令层开 [Truth] 一律经它。
    pub(super) fn truth<'c>(&self, conn: &'c Connection) -> Truth<'c> {
        Truth::with_cfg_memo(conn, self.cfg_memo.clone()).with_cancel(self.cancel.clone())
    }

    /// 借一条读连接。
    pub fn reader(&self) -> Result<Reader<'_>, String> {
        self.readers.borrow()
    }

    /// 在读连接上跑 [f]（一条读命令；`cmd` 的读命令自己开读快照）。
    pub(super) fn read<T>(
        &self,
        f: impl FnOnce(&Truth<'_>) -> Result<T, String>,
    ) -> Result<T, String> {
        let r = self.reader()?;
        let t = self.truth(&r);
        f(&t)
    }

    /// 一条写命令：写锁里、一个一开始就拿写锁的事务（`Truth::tx_immediate`）里跑 [f]，提交之后写入代数 +1。[f] 报错
    /// 整笔回滚。
    pub(super) fn write<T>(
        &self,
        f: impl FnOnce(&Truth<'_>) -> Result<T, String>,
    ) -> Result<T, String> {
        let out = self.write_tx(f);
        if out.is_ok() {
            self.writes.fetch_add(1, Ordering::SeqCst);
        }
        out
    }

    /// 只改本机状态行的写命令（媒体回收的待回收集合）：与 [G4Core::write] 同一把写锁、同一种事务，但**不推进写入代数**。
    /// 写入代数是统计原料缓存判「原料改没改」的键（模块文件头），本机状态行不是原料，推进它只会让下一次统计白白重算一遍
    /// （后台回收按游标分批循环，每批都会推进）。[f] 不得动真相与派生层：动了，统计会命中旧原料。
    pub(super) fn write_local<T>(
        &self,
        f: impl FnOnce(&Truth<'_>) -> Result<T, String>,
    ) -> Result<T, String> {
        self.write_tx(f)
    }

    /// [G4Core::write] / [G4Core::write_local] 共用：写锁里、一开始就拿写锁的事务里跑 [f]，报错整笔回滚。
    fn write_tx<T>(&self, f: impl FnOnce(&Truth<'_>) -> Result<T, String>) -> Result<T, String> {
        let w = self.writer()?;
        let t = self.truth(&w);
        let v = t.tx_immediate(|t| {
            let v = f(t)?;
            // 提交之前再看一次取消令牌（`cancel.rs`「提交之前」）：关库开始之后不提交半截命令，整笔回滚、报 `CLOSED`。
            self.cancel.check()?;
            // 测试注入：提交之前 panic（panic_recovery_tests.rs，同协议 3 `in_savepoint` 的注入点）。
            #[cfg(test)]
            crate::store::sync2::test_panic::hit(crate::store::sync2::test_panic::BEFORE_RELEASE);
            Ok(v)
        })?;
        // 提交了落空洞的写（或之前被读者挡住）：字节层收尾（`scrub.rs`「没做成怎么办」），在事务外、还拿着写锁。命令
        // 本身已经提交，收尾没做成不改它的结果，「欠一次收尾」记在库里。刚落了空洞的按忙等等读者；之前被挡、这次顺手
        // 再试的不等。被挡 = 之后的写命令再试；出错 = 原因已由 `scrub` 记进库（读命令 `scrub_state`），不逐条写命令
        // 重试（每条都重做一次注定失败的整库整理），下一次打开或下一次清除再试。
        let voided = t.take_voided();
        if voided || self.scrub_pending.load(Ordering::SeqCst) {
            let wait = if voided {
                super::scrub::Wait::Yes
            } else {
                super::scrub::Wait::No
            };
            let blocked = matches!(super::scrub::scrub(&w, wait, Some(&self.cancel)), Ok(false));
            self.scrub_pending.store(blocked, Ordering::SeqCst);
        }
        Ok(v)
    }

    /// 关闭（幂等）：先取消在途命令（[G4Core::cancel]），再关读连接池（等借出的放回）→ 写连接。之后的命令报 `CLOSED`。
    /// 等的只是在途命令退出（下一个批次边界 / 语句进度回调，`cancel.rs`），不是等它们跑完。
    pub fn close(&self) {
        self.cancel();
        self.readers.close();
        let w = self.writer.lock().unwrap_or_else(|e| e.into_inner()).take();
        drop(w);
    }

    /// 取消在途命令（幂等，任意线程，不等任何东西；`cancel.rs`）：之后借不到连接、真相层写不进、写命令不提交，正在跑
    /// 的语句在下一次进度回调里以 `SQLITE_INTERRUPT` 退出，写事务整笔回滚。只在关库时调（`ffi.rs`
    /// `ffsrs_store_close_begin` / [G4Core::close]）：令牌不复位。
    pub fn cancel(&self) {
        self.cancel.cancel();
    }

    /// 已经取消（关库开始了）：在途命令此后报出的错误一律按 `CLOSED` 交出去（`ffi.rs` `run_core`）。
    pub fn is_cancelled(&self) -> bool {
        self.cancel.is_cancelled()
    }

    /// 查询道的并发上限（Dart 查询道的 worker 数取它）。
    pub fn read_concurrency(&self) -> usize {
        self.readers.cap
    }

    /// 读连接池眼下开着的连接数（内存诊断）。
    pub fn pooled_readers(&self) -> usize {
        self.readers.live()
    }

    /// 库文件与 `-wal` 的字节数（拿不到记 0）。
    pub fn file_sizes(&self) -> (u64, u64) {
        let len = |p: &Path| std::fs::metadata(p).map_or(0, |m| m.len());
        (
            len(&self.path),
            len(&crate::store::seal::with_suffix(&self.path, "-wal")),
        )
    }

    /// 写连接是否在事务里（测试用）。
    pub fn in_transaction(&self) -> Result<bool, String> {
        Ok(!self.writer()?.is_autocommit())
    }

    /// 只读调试查询（测试 / 诊断）：结果按 `rows.rs` 编码，第一行是列名。只认只读语句。
    pub fn debug_query(&self, sql_text: &str, params: &[Sv]) -> Result<Vec<u8>, String> {
        crate::store::query_rows(&*self.reader()?, sql_text, params)
    }

    /// 测试专用的原始通道（协议 3 `SrsCore::exec_raw` 同一个契约：写连接、跑完必须回到自动提交）。
    #[cfg(any(test, feature = "raw_sql"))]
    pub fn exec_raw(&self, sql_text: &str, params: &[Sv], select: bool) -> Result<Vec<u8>, String> {
        let w = self.writer()?;
        let out = crate::store::SrsCore::exec_on(&w, sql_text, params, select);
        if !w.is_autocommit() {
            w.execute_batch("ROLLBACK")
                .map_err(|e| format!("srs: raw exec: roll back a transaction left open: {e}"))?;
            return Err(format!(
                "srs: raw exec must not leave a transaction open on the write connection: {sql_text}"
            ));
        }
        self.writes.fetch_add(1, Ordering::SeqCst);
        // 审计版：这条语句与它写下的东西（不是 SELECT 时扫 ID 列）有没有拿 UUID 文本当 ID（`id_audit.rs`）。
        #[cfg(feature = "id_audit")]
        super::id_audit::take((!select).then_some(&*w))?;
        out
    }

    /// [G4Core::exec_raw] 的批量版：整批在一个 SAVEPOINT 里，任何一条出错整批回滚。
    #[cfg(any(test, feature = "raw_sql"))]
    pub fn exec_batch_raw(
        &self,
        statements: &[&str],
        applications: &[(usize, Vec<Sv>)],
    ) -> Result<(), String> {
        let w = self.writer()?;
        schema::in_tx(&w, |c| {
            for (index, args) in applications {
                let s = statements
                    .get(*index)
                    .ok_or_else(|| format!("batch statement index {index} out of range"))?;
                let mut stmt = c.prepare_cached(s).map_err(|e| format!("{e} in {s}"))?;
                stmt.execute(rusqlite::params_from_iter(args.iter()))
                    .map_err(|e| format!("{e} in {s}"))?;
            }
            Ok(())
        })?;
        self.writes.fetch_add(1, Ordering::SeqCst);
        #[cfg(feature = "id_audit")]
        super::id_audit::take(Some(&*w))?;
        Ok(())
    }

    /// 把 WAL 并回主库（PASSIVE），在一条另开的连接上做：不占写连接（协议 3 `SrsCore::wal_checkpoint` 同口径）。库已
    /// 关就报 `CLOSED`，不按路径把库重新打开。回包 `{busy, log, checkpointed}`。
    ///
    /// Secondary 报 [READ_ONLY]、不开连接：辅助进程按设计只读（可能在没有写权限的沙箱里），并回 WAL 是写库的主进程的事
    /// （协议 3 没有 Secondary，它的句柄一律是读写的）。
    pub fn wal_checkpoint(&self) -> Result<Value, String> {
        if matches!(self.mode, OpenMode::Secondary) {
            return Err(READ_ONLY.to_owned());
        }
        // 借着一条读连接开旁路连接：与 [G4Core::close]（先关读连接池、等借出的放回）互斥。
        let _hold = self.reader()?;
        let conn = Connection::open_with_flags(
            &self.path,
            OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_NO_MUTEX,
        )
        .map_err(|e| format!("gen4 store: open checkpoint connection: {e}"))?;
        self.cancel.watch(&conn);
        conn.busy_timeout(schema::BUSY_TIMEOUT).map_err(sql)?;
        let (busy, log, checkpointed): (i64, i64, i64) = conn
            .query_row("PRAGMA wal_checkpoint(PASSIVE)", [], |r| {
                Ok((r.get(0)?, r.get(1)?, r.get(2)?))
            })
            .map_err(sql)?;
        drop(conn);
        Ok(json!({"busy": busy != 0, "log": log, "checkpointed": checkpointed}))
    }

    /// 批量写入开始 / 结束（`bulk_cache {on}`）：按库计嵌套深度；最外层调高 / 恢复写连接的 `wal_autocheckpoint`，结束时
    /// 先另开连接并回 WAL 再恢复（协议 3 `bulk_begin` / `bulk_end` 同口径）。没有配对的开始就结束报错、深度不动。
    pub fn bulk(&self, on: bool) -> Result<u32, String> {
        let mut b = self.bulk.lock().unwrap_or_else(|e| e.into_inner());
        if on {
            if b.depth == 0 {
                let w = self.writer()?;
                let restore: i64 = w
                    .query_row("PRAGMA wal_autocheckpoint", [], |r| r.get(0))
                    .map_err(sql)?;
                w.execute_batch(&format!(
                    "PRAGMA wal_autocheckpoint = {}",
                    crate::store::BULK_WAL_AUTOCHECKPOINT_PAGES
                ))
                .map_err(sql)?;
                b.restore = restore;
                self.bulk_holds_cache.store(true, Ordering::Relaxed);
            }
            b.depth += 1;
            return Ok(b.depth);
        }
        if b.depth == 0 {
            return Err("bulk_cache: off without a matching on".into());
        }
        b.depth -= 1;
        if b.depth > 0 {
            return Ok(b.depth);
        }
        let merged = self.wal_checkpoint();
        // 先清标志：恢复阈值这一次放回写连接就把留着的页缓存收回（协议 3 `bulk_end` 同序）。
        self.bulk_holds_cache.store(false, Ordering::Relaxed);
        let restored = self.writer().and_then(|w| {
            w.execute_batch(&format!("PRAGMA wal_autocheckpoint = {}", b.restore))
                .map_err(sql)
        });
        merged?;
        restored?;
        Ok(0)
    }

    /// 整库一致快照（`ffsrs_store_snapshot`，G11-4）：把 `srs4.db` `VACUUM INTO` 到 [target]（必须不存在），得到一份
    /// 可以原样当新代库打开的文件（魔数、schema 号、全部真相 / 派生 / 本机状态，含本机签名钥匙）。
    ///
    /// - **用途**：服务端整机备份（`server_backup.dart` 第 2 版，同一台设备原样回来，身份与同步进度都要在）。app 的整包
    ///   备份**不**用它，用按集合导出的 `FSRS4EXP` 流（`export`，交接说明 G11-4 一节）：快照带着本机签名钥匙，还原到
    ///   另一台设备上就是两台设备共用一个身份（必然分叉）。
    /// - **一致**：`VACUUM INTO` 在一条只读连接的一个读事务里读源库，看到的是开始那一刻已提交的全部（WAL 里已提交的帧
    ///   也算）；写连接照常写（WAL 下读不挡写），只是快照期间 WAL 检查点追不过这个读事务。
    /// - **不剥本机表**（[strip_device_local] 为真报错）：新代的备份不需要剥了本机身份的快照（上一条），不给一个半定义
    ///   的模式。
    /// - Secondary（辅助进程）不可用：快照是主进程的事（备份 / 服务端），辅助进程可能在没有写权限的沙箱里。
    /// - 写之前按「有效数据 + 余量」查目标卷的空闲空间，不够报 `SNAPSHOT_NO_SPACE`（一个字节不写）；写完开一遍核对它是
    ///   建好的新代库（`schema::check_ready`），不是就删掉报错。中途出错删掉半截目标。
    pub fn snapshot_into(&self, target: &Path, strip_device_local: bool) -> Result<(), String> {
        self.snapshot_into_with_free_space(
            target,
            strip_device_local,
            crate::store::compact::free_bytes,
        )
    }

    /// [G4Core::snapshot_into]，目标卷的空闲空间由 [free] 给（测试注入）。
    pub(crate) fn snapshot_into_with_free_space(
        &self,
        target: &Path,
        strip_device_local: bool,
        free: impl Fn(&Path) -> Option<u64>,
    ) -> Result<(), String> {
        if matches!(self.mode, OpenMode::Secondary) {
            return Err(READ_ONLY.to_owned());
        }
        if strip_device_local {
            return Err(SNAPSHOT_NO_STRIP.to_owned());
        }
        if target.exists() {
            return Err(format!(
                "gen4 snapshot: {} already exists",
                target.display()
            ));
        }
        let target_str = target
            .to_str()
            .ok_or_else(|| "gen4 snapshot: path is not UTF-8".to_owned())?;
        // 借一条读连接撑住「库开着」（与 [G4Core::close] 互斥，同 [G4Core::wal_checkpoint]），快照本身开一条单独的只读
        // 连接：池里的读连接是 `query_only`，那个开关也管 `VACUUM`。
        let _hold = self.reader()?;
        let conn = Connection::open_with_flags(
            &self.path,
            OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
        )
        .map_err(|e| format!("gen4 snapshot: open a snapshot connection: {e}"))?;
        // 整库 `VACUUM INTO` 可能很久：关库时被打断（`cancel.rs`），半截目标照下面的出错路径删掉。
        self.cancel.watch(&conn);
        conn.busy_timeout(schema::BUSY_TIMEOUT).map_err(sql)?;
        let pragma = |name: &str| -> Result<u64, String> {
            conn.query_row(&format!("PRAGMA {name}"), [], |row| row.get::<_, i64>(0))
                .map(|v| v.max(0) as u64)
                .map_err(sql)
        };
        let live =
            pragma("page_size")? * pragma("page_count")?.saturating_sub(pragma("freelist_count")?);
        let need = live.saturating_add(crate::store::compact::MARGIN);
        if let Some(free) = free(target).filter(|&f| f < need) {
            return Err(format!(
                "{}{}",
                crate::store::SNAPSHOT_NO_SPACE,
                json!({"need": need, "free": free})
            ));
        }
        let written = (|| -> Result<(), String> {
            conn.execute("VACUUM INTO ?1", [target_str])
                .map_err(|e| format!("gen4 snapshot: {e}"))?;
            drop(conn);
            let check = files::open_ready(target)
                .map_err(|e| format!("gen4 snapshot: the snapshot does not open: {e}"))?;
            check.close().map_err(|(_, e)| sql(e))?;
            Ok(())
        })();
        if written.is_err() {
            let _ = crate::store::seal::remove_sqlite_files(target);
        }
        written
    }
}

/// [G4Core::snapshot_into] 收到 `strip_device_local` 时的错误（文档在那里）。
pub const SNAPSHOT_NO_STRIP: &str = "gen4 snapshot: stripping device-local state is not supported; \
     app backups carry per-collection export streams (`export`), not library snapshots";

// ---------------------------------------------------------------------- 全局命令：迁移

/// 一次进行中的迁移：叫停开关与进度。
struct Run {
    stop: Stop,
    progress: Mutex<(migrate::Step, u64, u64)>,
}

/// 本进程里进行中的迁移（目录 → 那一次）。
static RUNS: Mutex<BTreeMap<PathBuf, Arc<Run>>> = Mutex::new(BTreeMap::new());

/// 取消早于开跑到达的 (目录, runId)（Dart 两条命令并发发出时取消可能先到）：开跑时看到就直接叫停。
static CANCELLED_EARLY: Mutex<BTreeSet<(PathBuf, String)>> = Mutex::new(BTreeSet::new());

fn runs() -> MutexGuard<'static, BTreeMap<PathBuf, Arc<Run>>> {
    RUNS.lock().unwrap_or_else(|e| e.into_inner())
}

fn cancelled_early() -> MutexGuard<'static, BTreeSet<(PathBuf, String)>> {
    CANCELLED_EARLY.lock().unwrap_or_else(|e| e.into_inner())
}

/// [RUNS] 里一个目录的登记：析构时摘掉（迁移正常返回、报错、panic 都一样——`ffsrs_call` 接住 panic 之后，留在表里的项会让
/// 本进程对这个目录的迁移一直回 `blocked`），连同这个目录在 [CANCELLED_EARLY] 里剩下的项（给了 runId、却始终没有对应的
/// 那一次开跑的取消）。
struct Registration {
    dir: PathBuf,
}

impl Registration {
    /// 登记 [dir] 的这一次运行；本进程里这个目录已经在跑 = None。
    fn new(dir: &Path, run: &Arc<Run>) -> Option<Registration> {
        let mut all = runs();
        if all.contains_key(dir) {
            return None;
        }
        all.insert(dir.to_owned(), Arc::clone(run));
        Some(Registration {
            dir: dir.to_owned(),
        })
    }
}

impl Drop for Registration {
    fn drop(&mut self) {
        runs().remove(&self.dir);
        cancelled_early().retain(|(d, _)| d != &self.dir);
    }
}

/// 测试用：本进程里 [dir] 有没有登记中的运行、提前到达的取消还剩几条。
#[cfg(test)]
pub(crate) fn run_registry_of(dir: &Path) -> (bool, usize) {
    (
        runs().contains_key(dir),
        cancelled_early().iter().filter(|(d, _)| d == dir).count(),
    )
}

/// 测试用：登记 [dir] 的一次运行，在登记期间跑 [f]（[f] panic 时登记照样摘掉）。已经在跑 = None。
#[cfg(test)]
pub(crate) fn with_registered_run<T>(dir: &Path, f: impl FnOnce() -> T) -> Option<T> {
    let run = Arc::new(Run {
        stop: Stop::new(),
        progress: Mutex::new((migrate::Step::Space, 0, 1)),
    });
    let _reg = Registration::new(dir, &run)?;
    Some(f())
}

fn dir_of(req: &Value) -> Result<PathBuf, String> {
    req.get("dir")
        .and_then(Value::as_str)
        .map(PathBuf::from)
        .ok_or_else(|| "gen4 migrate: missing dir".to_owned())
}

/// 全局命令（不需要库句柄，`lib.rs` 的 JSON 入口转进来）：
///
/// - `gen4_migrate_status {dir}` → `{state, failure, running}`：`state` 是 `migrate::GenState` 的线上名；`failure` =
///   上次迁移没完成的原因 `{reason: fail|incomplete|error|interrupted, reportPath?}`（`migrate::Failure::json`，只有
///   `migrationFailed` 有，其余 = null）；`running` = 本进程里这个目录正在跑的迁移的进度 `{step, done, total}`（没有 =
///   null）。只看文件与锁、读旧库的一行 schema 与身份、目录里那份小报告，Dart 在 UI isolate 上轮询它。
/// - `gen4_migrate_profiles {dir}` → `{profiles}`：旧库里全部有数据的 profile uid（`legacy::all_profiles`，含主库
///   profile 表里没有的孤儿 uid；`gen4_migrate_run` 的 `caches` 要每个都有）。要读旧库的几张大表（按 profile 跳着取），
///   调用方在后台 isolate 调（G7-2b）。没有旧库 = 报错。
/// - `gen4_migrate_run {dir, caches: {profile: 缓存配置}, now, batch?, runId?}` → `migrate::Outcome::json`
///   （`{verdict, ...}`）。几十秒到几分钟，调用方在后台 isolate 调。同一目录在本进程里已经在跑 = `blocked`。
/// - `gen4_migrate_cancel {dir, runId?}` → `{cancelled}`：叫停（提交点之前有效）；带 `runId` 时早于开跑到达也不丢。
/// - `gen4_retained_state {dir, now}` / `gen4_retained_delete {dir}`：保留副本（封存的 `srs.db`）的到期状态与立即删除
///   （`retained.rs`，D32）。删除不可逆，调用方先取得用户确认。
pub fn global(op: &str, req: &Value) -> Result<Value, String> {
    match op {
        "gen4_migrate_status" => {
            let dir = dir_of(req)?;
            let running = runs().get(&dir).map(|r| {
                let (step, done, total) = *r.progress.lock().unwrap_or_else(|e| e.into_inner());
                json!({"step": step.wire(), "done": done, "total": total})
            });
            let mut out = migrate::status(&dir)?.json(&dir);
            out["running"] = running.unwrap_or(Value::Null);
            Ok(out)
        }
        "gen4_migrate_profiles" => {
            let dir = dir_of(req)?;
            Ok(json!({"profiles": migrate::legacy_profiles(&dir)?}))
        }
        "gen4_migrate_run" => run_migration(req),
        "gen4_migrate_cancel" => {
            let dir = dir_of(req)?;
            let run = runs().get(&dir).cloned();
            match run {
                Some(r) => {
                    r.stop.stop();
                    Ok(json!({"cancelled": true}))
                }
                None => {
                    if let Some(id) = req.get("runId").and_then(Value::as_str) {
                        cancelled_early().insert((dir, id.to_owned()));
                    }
                    Ok(json!({"cancelled": false}))
                }
            }
        }
        "gen4_retained_state" => {
            let dir = dir_of(req)?;
            let now = req
                .get("now")
                .and_then(Value::as_i64)
                .ok_or("gen4 retained: missing now")?;
            super::retained::state(&dir, now)
        }
        "gen4_retained_delete" => super::retained::delete(&dir_of(req)?),
        other => Err(format!("gen4: unknown global op {other}")),
    }
}

fn run_migration(req: &Value) -> Result<Value, String> {
    let dir = dir_of(req)?;
    let now = req
        .get("now")
        .and_then(Value::as_i64)
        .ok_or("gen4 migrate: missing now")?;
    let batch = req
        .get("batch")
        .and_then(Value::as_u64)
        .unwrap_or(migrate::DEFAULT_BATCH)
        .max(1);
    // 每个 profile 的缓存配置：对象（或已经是 JSON 文本）。先按旧内核同一份解析核对，坏了在这里报，不进迁移。
    let mut caches: BTreeMap<String, String> = BTreeMap::new();
    for (profile, v) in req
        .get("caches")
        .and_then(Value::as_object)
        .ok_or("gen4 migrate: missing caches")?
    {
        let v = match v {
            Value::String(text) => serde_json::from_str::<Value>(text)
                .map_err(|e| format!("gen4 migrate: bad caches for {profile}: {e}"))?,
            other => other.clone(),
        };
        crate::store::caches::CacheConfig::parse(&v)?;
        caches.insert(profile.clone(), crate::store::sync2::canonical(&v));
    }
    let run = Arc::new(Run {
        stop: Stop::new(),
        progress: Mutex::new((migrate::Step::Space, 0, 1)),
    });
    // 登记随 `_reg` 析构摘掉（返回、报错、panic 都一样）。
    let Some(_reg) = Registration::new(&dir, &run) else {
        return Ok(migrate::Outcome::Blocked {
            code: migrate::BlockCode::Migrating,
            reason: migrate::BLOCKED_MIGRATING.to_owned(),
        }
        .json());
    };
    if let Some(id) = req.get("runId").and_then(Value::as_str) {
        if cancelled_early().remove(&(dir.clone(), id.to_owned())) {
            run.stop.stop();
        }
    }
    let out = migrate::run(
        &dir,
        migrate::Options {
            caches: &caches,
            batch,
            now_ms: now,
            stop: &run.stop,
            progress: &mut |step, done, total| {
                *run.progress.lock().unwrap_or_else(|e| e.into_inner()) = (step, done, total);
            },
            new_device: &migrate::random_device,
        },
    );
    Ok(out?.json())
}
