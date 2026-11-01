//! Drift 执行器事务外查询用的只读连接池（[super::SrsCore::snapshot_select]）。
//!
//! 以前 Drift 的事务外查询只有一条读连接、外加 Dart 侧整条 Drift 连接是一个顺序队列：同步里一条几秒的长读
//! （全量冲突扫描、媒体对账）跑着时，打开卡片 / 牌组设置的毫秒级短读排在它后面等满全程。WAL 下只读连接互不
//! 阻塞，这里按需开到 [ReadPool::cap] 条，同时在途的查询各占一条，用完放回。
//!
//! - 上限（[read_concurrency]）：按本机核数算，`clamp(核数 / 2, READERS_MIN, READERS_MAX)`，只在这里算一次；
//!   Dart 侧查询道的 worker 数从打开的库上读它（`ffsrs_store_read_concurrency`），不另写常量。
//! - 按需开：第一条在打开库时开（打开失败当场报出），常驻到关库；其余在并发真的出现时才开。
//! - 空闲回收：除第一条外，放回后空闲超过 [IDLE_TTL] 的连接在下一次借 / 还时关掉（不起后台线程、不轮询）。
//!   借出时取最近放回的那条（后进先出），所以稀疏的查询总落在同几条上，多出来的会老化。之后一直没有任何借还
//!   时，最近一次并发高峰开出来的连接会留着（至多 cap − 1 条多余）：每条放回时页缓存已收到 8 MB 以内
//!   （`trim_idle_cache`），mmap 只占虚拟地址，代价是这几 MB 与几个文件句柄，下一次任何查询就把它们收掉。
//! - 到上限：调用方在条件变量上等一条被放回（Dart 侧发查询的 worker 数不超过上限，正常不会等）。
//! - 关闭（[ReadPool::close]）：标记已关闭、丢掉空闲的连接，再等在途的查询把手上那条放回（放回时直接关掉）。
//!   返回时池子开过的连接一条不剩；之后取连接一律报「已关闭」。
//! - 每条连接每条语句自成一个读事务（语句跑完 rusqlite 即复位，不留跨调用的读事务）：开读事务时取最新的
//!   WAL 尾，所以调用方等到写返回后再发的查询一定看得见它。不同连接上并行的两条查询各自看各自开始时刻的
//!   已提交数据——与以前单条读连接上前后两条语句之间可能隔着一次提交是同一种保证（从来没有跨语句快照）。

use std::ops::Deref;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

use rusqlite::Connection;

use super::CLOSED;

// 上下界的实测依据（真实库 2.9 GB，16 逻辑核 Windows x64，[tests::real_db_parallel_long_reads]；表见
// docs/specs/2026-10-23-srs-rust-store.md §7.4）：同步冲突扫描这种长读并行时互相拖慢——单条 1.6–1.8 s，
// 2 条并行每条慢 15–35%、总吞吐 1.5–1.7 倍；4 条每条约 2 倍慢、吞吐约 2 倍；8 条每条约 3 倍慢、吞吐只再多 25–35%，
// 另一条连接上的点查最坏从亚毫秒涨到 30–120 ms。每条连接执行长读时页缓存实测用满 64 MB（`cache_size`）。

/// 上限的下界：一条长读之外至少还有一条给短读（2 条并行时长读只慢 15–35%）。
pub const READERS_MIN: usize = 2;
/// 上限的上界。桌面 4：再往上每条长读慢到 3 倍、吞吐几乎不涨、点查最坏上百毫秒。手机 3：每条长读的页缓存
/// 用满 64 MB，3 条同时跑是约 200 MB 的瞬时占用，再多在小内存机型上有被系统杀的风险（手机上未实测并行吞吐）。
#[cfg(not(any(target_os = "android", target_os = "ios")))]
pub const READERS_MAX: usize = 4;
#[cfg(any(target_os = "android", target_os = "ios"))]
pub const READERS_MAX: usize = 3;

/// 空闲连接的保留时长：重开一条连接实测约 2 ms（冷文件缓存时连第一条点查约 26 ms），而留着一条空闲连接的代价是
/// 至多 8 MB 页缓存加文件句柄。一分钟盖住一阵并发查询（打开设置页、一轮同步的对账读）之内的复用，不让一阵查询
/// 反复开关；与 Dart 查询道 worker 的空闲回收（`kSrsQueryWorkerIdleTtl`）同长。
pub const IDLE_TTL: Duration = Duration::from_secs(60);

/// [cores] 个逻辑核时的上限。
pub fn read_concurrency_for(cores: usize) -> usize {
    (cores / 2).clamp(READERS_MIN, READERS_MAX)
}

/// 本机的上限（[read_concurrency_for] 本机逻辑核数；取不到核数按 1 核算）。
pub fn read_concurrency() -> usize {
    read_concurrency_for(std::thread::available_parallelism().map_or(1, |n| n.get()))
}

/// 打开一条只读连接（配置好 PRAGMA / SQL 函数）。
pub(crate) type Opener = fn(&Path) -> Result<Connection, String>;

/// 时钟（测试注入，不等真实时间）。
pub(crate) type Clock = Arc<dyn Fn() -> Instant + Send + Sync>;

pub(crate) struct ReadPool {
    path: PathBuf,
    cap: usize,
    ttl: Duration,
    open: Opener,
    clock: Clock,
    state: Mutex<State>,
    returned: Condvar,
}

struct Idle {
    conn: Connection,
    /// 放回的时刻。
    since: Instant,
    /// 打开库时开的那条：不回收。
    pinned: bool,
}

struct State {
    /// 空闲连接，最近放回的在尾。
    idle: Vec<Idle>,
    /// 开着的连接数（空闲 + 借出）。
    live: usize,
    closed: bool,
}

impl State {
    /// 摘下空闲超过 [ttl] 的非常驻连接（调用方在锁外关掉它们）。
    fn reap(&mut self, now: Instant, ttl: Duration) -> Vec<Connection> {
        let mut out = Vec::new();
        let mut i = 0;
        while i < self.idle.len() {
            let e = &self.idle[i];
            if !e.pinned && now.saturating_duration_since(e.since) >= ttl {
                out.push(self.idle.remove(i).conn);
                self.live -= 1;
            } else {
                i += 1;
            }
        }
        out
    }
}

/// 借出的一条连接；析构时放回（池子已关闭就关掉）。
pub(crate) struct Pooled<'a> {
    pool: &'a ReadPool,
    conn: Option<Connection>,
    pinned: bool,
}

impl ReadPool {
    /// 建池并先开一条常驻连接（打开失败当场报错）。
    pub(crate) fn new(path: &Path, cap: usize, open: Opener) -> Result<Self, String> {
        Self::with_clock(path, cap, IDLE_TTL, open, Arc::new(Instant::now))
    }

    pub(crate) fn with_clock(path: &Path, cap: usize, ttl: Duration, open: Opener, clock: Clock) -> Result<Self, String> {
        let first = open(path)?;
        let since = clock();
        Ok(Self {
            path: path.to_path_buf(),
            cap: cap.max(1),
            ttl,
            open,
            clock,
            state: Mutex::new(State { idle: vec![Idle { conn: first, since, pinned: true }], live: 1, closed: false }),
            returned: Condvar::new(),
        })
    }

    /// 连接数上限。
    pub(crate) fn cap(&self) -> usize {
        self.cap
    }

    fn state(&self) -> std::sync::MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// 借一条连接：先回收超时的空闲连接；有空闲的就用最近放回的那条，没有且没到上限就新开，到上限等一条放回。
    pub(crate) fn get(&self) -> Result<Pooled<'_>, String> {
        let mut st = self.state();
        let expired = st.reap((self.clock)(), self.ttl);
        loop {
            if st.closed {
                drop(st);
                drop(expired);
                return Err(CLOSED.to_string());
            }
            if let Some(e) = st.idle.pop() {
                drop(st);
                drop(expired);
                return Ok(Pooled { pool: self, conn: Some(e.conn), pinned: e.pinned });
            }
            if st.live < self.cap {
                st.live += 1;
                drop(st);
                drop(expired);
                // 开连接不持池锁：别的线程照常借还。
                return match (self.open)(&self.path) {
                    Ok(conn) => Ok(Pooled { pool: self, conn: Some(conn), pinned: false }),
                    Err(e) => {
                        let mut st = self.state();
                        st.live -= 1;
                        drop(st);
                        self.returned.notify_all();
                        Err(e)
                    }
                };
            }
            st = self.returned.wait(st).unwrap_or_else(|e| e.into_inner());
        }
    }

    /// 关闭（幂等）：丢掉空闲连接，等借出的全部放回（放回即关）。
    pub(crate) fn close(&self) {
        let mut st = self.state();
        st.closed = true;
        let idle = std::mem::take(&mut st.idle);
        st.live -= idle.len();
        drop(st);
        drop(idle);
        let mut st = self.state();
        while st.live > 0 {
            st = self.returned.wait(st).unwrap_or_else(|e| e.into_inner());
        }
    }

    /// 开着的连接数（空闲 + 借出；测试看上限、回收与关闭）。
    #[cfg(test)]
    pub(crate) fn live(&self) -> usize {
        self.state().live
    }
}

impl Deref for Pooled<'_> {
    type Target = Connection;

    fn deref(&self) -> &Connection {
        self.conn.as_ref().expect("pooled connection is held until drop")
    }
}

impl Drop for Pooled<'_> {
    fn drop(&mut self) {
        let Some(conn) = self.conn.take() else { return };
        super::trim_idle_cache(&conn);
        let mut st = self.pool.state();
        if st.closed {
            st.live -= 1;
            drop(st);
            drop(conn);
        } else {
            let now = (self.pool.clock)();
            let expired = st.reap(now, self.pool.ttl);
            st.idle.push(Idle { conn, since: now, pinned: self.pinned });
            drop(st);
            drop(expired);
        }
        self.pool.returned.notify_all();
    }
}

#[cfg(test)]
mod tests {
    use std::sync::mpsc;
    use std::sync::Arc;
    use std::time::Duration;

    use rusqlite::types::Value;

    use std::time::Instant;

    use rusqlite::Connection;

    use super::super::{rows, SrsCore, CLOSED, NOT_SNAPSHOT};

    fn open(name: &str) -> SrsCore {
        let dir = std::env::temp_dir().join(format!("ffsrs_pool_{name}_{}", std::process::id()));
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
            "INSERT INTO srs_unknown_events (id, profile_uid, json) VALUES (srs_id(?1), 'p', '{}')",
            &[Value::Text(id.into())],
            false,
        )
        .unwrap();
    }

    fn scalar(page: &[u8]) -> Value {
        let (_, rows) = rows::decode(page).unwrap();
        rows[1][0].clone()
    }

    const COUNT: &str = "SELECT COUNT(*) FROM srs_unknown_events";

    /// 一条借出的连接被长读占着（这里直接攥着它）时，另一条线程上的事务外查询照样立刻返回：它借到的是另一条连接。
    /// 以前只有一条 Drift 读连接（一把锁），这条查询要等长读跑完。
    #[test]
    fn a_query_does_not_wait_for_another_in_flight_query() {
        let core = Arc::new(open("overlap"));
        insert(&core, "a");
        let held = core.drift_readers.get().unwrap();
        let (tx, rx) = mpsc::channel::<Value>();
        let t = {
            let core = Arc::clone(&core);
            std::thread::spawn(move || tx.send(scalar(&core.snapshot_select(COUNT, &[]).unwrap())).unwrap())
        };
        let seen = rx.recv_timeout(Duration::from_secs(5)).expect("query waited for the other reader");
        assert_eq!(seen, Value::Integer(1));
        t.join().unwrap();
        drop(held);
        assert_eq!(core.drift_readers.live(), 2, "the second reader stays open for reuse");
    }

    /// 两条真跑着的查询在两条线程上重叠执行：长查询（递归 CTE 数几百万行）开始之后，短查询在它结束之前返回。
    #[test]
    fn a_short_query_finishes_while_a_long_query_is_running() {
        let core = Arc::new(open("long"));
        insert(&core, "a");
        let (started_tx, started_rx) = mpsc::channel::<()>();
        let long = {
            let core = Arc::clone(&core);
            std::thread::spawn(move || {
                started_tx.send(()).unwrap();
                let t = std::time::Instant::now();
                core.snapshot_select(
                    "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 30000000) SELECT SUM(i) FROM n",
                    &[],
                )
                .unwrap();
                t.elapsed()
            })
        };
        started_rx.recv().unwrap();
        std::thread::sleep(Duration::from_millis(50));
        let t = std::time::Instant::now();
        assert_eq!(scalar(&core.snapshot_select(COUNT, &[]).unwrap()), Value::Integer(1));
        let short = t.elapsed();
        assert!(!long.is_finished(), "long query finished before the short one (make it longer)");
        let long = long.join().unwrap();
        assert!(short < long / 4, "short {short:?} vs long {long:?}");
    }

    /// Drift 事务开着（写连接上挂着 BEGIN、写了一行没提交）：事务外查询只看已提交的数据、不碰写连接；
    /// 写连接那一路（mode 2）的查询看得见未提交的行（读己之写）。提交后事务外查询立刻看得见。
    #[test]
    fn outside_queries_see_committed_data_while_a_drift_transaction_is_open() {
        let core = open("tx");
        insert(&core, "a");
        core.exec("BEGIN TRANSACTION", &[], true).unwrap();
        insert(&core, "b");
        assert_eq!(scalar(&core.select(COUNT, &[]).unwrap()), Value::Integer(2), "read-your-writes in the transaction");
        assert_eq!(scalar(&core.snapshot_select(COUNT, &[]).unwrap()), Value::Integer(1), "outside query read dirty data");
        assert_eq!(
            scalar(&core.snapshot_select("SELECT last_insert_rowid()", &[]).unwrap()),
            Value::Integer(0),
            "outside query ran on the writer"
        );
        core.exec("COMMIT TRANSACTION", &[], true).unwrap();
        assert_eq!(scalar(&core.snapshot_select(COUNT, &[]).unwrap()), Value::Integer(2));
    }

    /// 不是只读查询的语句不执行、报 [NOT_SNAPSHOT]（Dart 改发写连接那一路）。
    #[test]
    fn non_queries_are_refused_without_running() {
        let core = open("refuse");
        for sql in [
            "PRAGMA wal_autocheckpoint",
            "BEGIN",
            "INSERT INTO srs_unknown_events (id, profile_uid, json) VALUES ('r', 'p', '{}') RETURNING id",
            "WITH x AS (SELECT 1) INSERT INTO srs_unknown_events (id, profile_uid, json) SELECT 'w', 'p', '{}' FROM x",
        ] {
            assert_eq!(core.snapshot_select(sql, &[]).err().as_deref(), Some(NOT_SNAPSHOT), "{sql}");
        }
        assert_eq!(scalar(&core.select(COUNT, &[]).unwrap()), Value::Integer(0));
        assert!(!core.in_transaction().unwrap());
    }

    /// 连接数封顶：借满上限条后再借要等一条放回，不会多开。
    #[test]
    fn pool_is_capped_and_waits_for_a_returned_connection() {
        let core = Arc::new(open("cap"));
        let cap = core.read_concurrency();
        let held: Vec<_> = (0..cap).map(|_| core.drift_readers.get().unwrap()).collect();
        assert_eq!(core.drift_readers.live(), cap);
        let (tx, rx) = mpsc::channel::<()>();
        let t = {
            let core = Arc::clone(&core);
            std::thread::spawn(move || {
                core.snapshot_select(COUNT, &[]).unwrap();
                tx.send(()).unwrap();
            })
        };
        assert!(rx.recv_timeout(Duration::from_millis(300)).is_err(), "opened a connection past the cap");
        drop(held);
        rx.recv_timeout(Duration::from_secs(5)).expect("waiter not woken by a returned connection");
        t.join().unwrap();
        assert_eq!(core.drift_readers.live(), cap);
    }

    /// 关闭等借出的连接放回再返回；返回时池子开过的连接全关了，之后的查询报「已关闭」。
    #[test]
    fn close_waits_for_borrowed_connections_and_closes_them_all() {
        let core = Arc::new(open("close"));
        let a = core.drift_readers.get().unwrap();
        let b = core.drift_readers.get().unwrap();
        let (closed_tx, closed_rx) = mpsc::channel::<()>();
        let closer = {
            let core = Arc::clone(&core);
            std::thread::spawn(move || {
                core.close();
                closed_tx.send(()).unwrap();
            })
        };
        assert!(closed_rx.recv_timeout(Duration::from_millis(300)).is_err(), "close returned with a borrowed reader");
        drop(a);
        assert!(closed_rx.recv_timeout(Duration::from_millis(300)).is_err());
        drop(b);
        closed_rx.recv_timeout(Duration::from_secs(5)).expect("close never returned");
        closer.join().unwrap();
        assert_eq!(core.drift_readers.live(), 0);
        assert_eq!(core.snapshot_select(COUNT, &[]).err().as_deref(), Some(CLOSED));
        assert_eq!(core.select(COUNT, &[]).err().as_deref(), Some(CLOSED));
    }

    #[test]
    fn concurrency_is_half_the_cores_within_bounds() {
        use super::{read_concurrency, read_concurrency_for, READERS_MAX, READERS_MIN};
        assert_eq!(read_concurrency_for(0), READERS_MIN);
        assert_eq!(read_concurrency_for(1), READERS_MIN);
        assert_eq!(read_concurrency_for(2), READERS_MIN);
        assert_eq!(read_concurrency_for(READERS_MIN * 2), READERS_MIN);
        assert_eq!(read_concurrency_for(READERS_MAX * 2), READERS_MAX);
        assert_eq!(read_concurrency_for(64), READERS_MAX);
        for cores in 0..64 {
            let n = read_concurrency_for(cores);
            assert!((READERS_MIN..=READERS_MAX).contains(&n));
            assert!(n == READERS_MIN || n == READERS_MAX || n == cores / 2);
        }
        let core = open("cap_of_core");
        assert_eq!(core.read_concurrency(), read_concurrency());
    }

    /// 可拨的时钟：测空闲回收不等真实时间。
    fn manual_clock() -> (super::Clock, Arc<std::sync::Mutex<Instant>>) {
        let now = Arc::new(std::sync::Mutex::new(Instant::now()));
        let read = Arc::clone(&now);
        (Arc::new(move || *read.lock().unwrap()), now)
    }

    fn advance(now: &std::sync::Mutex<Instant>, d: Duration) {
        let mut t = now.lock().unwrap();
        *t += d;
    }

    /// 建好表的库 + 一个用可拨时钟的池（上限 4，空闲保留 60 s）。
    fn pool_with_clock(name: &str) -> (SrsCore, super::ReadPool, Arc<std::sync::Mutex<Instant>>) {
        let core = open(name);
        insert(&core, "a");
        let path = std::env::temp_dir().join(format!("ffsrs_pool_{name}_{}", std::process::id())).join("srs.db");
        let (clock, now) = manual_clock();
        let pool = super::ReadPool::with_clock(&path, 4, Duration::from_secs(60), super::super::open_drift_reader, clock).unwrap();
        (core, pool, now)
    }

    fn count_on(c: &Connection) -> i64 {
        c.query_row(COUNT, [], |r| r.get(0)).unwrap()
    }

    /// 空闲满保留时长的连接在下一次借 / 还时关掉；没满的、打开库时开的那条（常驻）不动；借出时取最近放回的那条。
    #[test]
    fn idle_connections_past_the_ttl_are_closed_on_the_next_borrow_or_return() {
        let (_core, pool, now) = pool_with_clock("reap");
        {
            let (a, b, c) = (pool.get().unwrap(), pool.get().unwrap(), pool.get().unwrap());
            assert_eq!(pool.live(), 3);
            drop((a, b, c));
        }
        // 59 s：还没满，一条也不收；借走的是最近放回的那条，还回去时刻刷新。
        advance(&now, Duration::from_secs(59));
        drop(pool.get().unwrap());
        assert_eq!(pool.live(), 3);
        // 61 s：另一条新开的空闲满 60 s，借时收掉；常驻那条与刚刷新的那条留着。
        advance(&now, Duration::from_secs(2));
        let g = pool.get().unwrap();
        assert_eq!(pool.live(), 2);
        assert_eq!(count_on(&g), 1);
        drop(g);
        // 很久以后：只剩常驻那条。
        advance(&now, Duration::from_secs(3600));
        drop(pool.get().unwrap());
        assert_eq!(pool.live(), 1, "the pinned connection opened with the store must stay");
        advance(&now, Duration::from_secs(3600));
        drop(pool.get().unwrap());
        assert_eq!(pool.live(), 1);
    }

    /// 还连接时也回收（不借只还：一条长读跑完放回时，把早就空闲的那几条收掉）。
    #[test]
    fn returning_a_connection_also_reaps_expired_idle_ones() {
        let (_core, pool, now) = pool_with_clock("reap_on_return");
        let (a, b, c) = (pool.get().unwrap(), pool.get().unwrap(), pool.get().unwrap());
        drop(a);
        drop(b);
        assert_eq!(pool.live(), 3);
        advance(&now, Duration::from_secs(120));
        // a 是常驻那条（第一个借出），b 新开、已空闲 120 s：c 放回时收掉 b。
        drop(c);
        assert_eq!(pool.live(), 2);
    }

    /// 回收之后再并发借：按需重新开到上限，查询照常；关闭照样等借出的放回、全部关掉。
    #[test]
    fn reaped_connections_are_reopened_on_demand_and_close_still_cleans_up() {
        let (_core, pool, now) = pool_with_clock("reopen");
        let pool = Arc::new(pool);
        drop((pool.get().unwrap(), pool.get().unwrap(), pool.get().unwrap(), pool.get().unwrap()));
        assert_eq!(pool.live(), 4);
        advance(&now, Duration::from_secs(61));
        drop(pool.get().unwrap());
        assert_eq!(pool.live(), 1);
        let held: Vec<_> = (0..4).map(|_| pool.get().unwrap()).collect();
        assert_eq!(pool.live(), 4);
        for g in &held {
            assert_eq!(count_on(g), 1);
        }
        let (tx, rx) = mpsc::channel::<()>();
        let closer = {
            let pool = Arc::clone(&pool);
            std::thread::spawn(move || {
                pool.close();
                tx.send(()).unwrap();
            })
        };
        assert!(rx.recv_timeout(Duration::from_millis(300)).is_err(), "close returned with borrowed readers");
        drop(held);
        rx.recv_timeout(Duration::from_secs(5)).expect("close never returned");
        closer.join().unwrap();
        assert_eq!(pool.live(), 0);
        assert_eq!(pool.get().err().as_deref(), Some(CLOSED));
    }

    /// 真实库上的并行长读测量（手动跑；定 [super::READERS_MIN] / [super::READERS_MAX] 的依据）：
    /// `FUSHI_SRS_REAL_DB=<srs.db 副本> cargo test --release --lib read_pool::tests::real_db_parallel_long_reads -- --ignored --nocapture`
    /// N 条长读（同步冲突扫描原文 / 笔记缓存整表扫描）各占一条连接同时跑，量总耗时、单条耗时，并在其间每 100 ms
    /// 在另一条连接上做一次按卡 ID 的点查，记最大延迟。只读打开，不写库。
    #[test]
    #[ignore]
    fn real_db_parallel_long_reads() {
        let path = std::path::PathBuf::from(std::env::var("FUSHI_SRS_REAL_DB").expect("set FUSHI_SRS_REAL_DB"));
        let conflicts = "SELECT e.entity_kind AS k, e.entity_id AS i, e.field_key AS f, CAST(e.json AS BLOB) AS j, s.server_time AS st             FROM srs_field_edits e JOIN (SELECT entity_kind AS k, entity_id AS i, field_key AS f FROM srs_field_edits             WHERE profile_uid = (SELECT profile_uid FROM srs_entities WHERE kind = 'deck' LIMIT 1) AND             ((entity_kind = 'profile') OR (entity_kind = 'deck' AND field_key NOT IN ('collapsed', 'position', 'extendLimits'))             OR (entity_kind = 'notetype' AND field_key IN ('name', 'termField', 'freqField'))             OR (entity_kind = 'note' AND field_key IN ('deck', 'noteType')) OR (entity_kind = 'card' AND field_key NOT IN ('newPos')))             GROUP BY entity_kind, entity_id, field_key HAVING COUNT(*) > 1) m             ON e.entity_kind = m.k AND e.entity_id = m.i AND e.field_key = m.f             LEFT JOIN srs_event_local s ON s.event_id = e.id             WHERE e.profile_uid = (SELECT profile_uid FROM srs_entities WHERE kind = 'deck' LIMIT 1)";
        let notes_scan = "SELECT id, note_type_id, media_refs FROM srs_notes_cache";
        fn drain(c: &Connection, sql: &str) -> (usize, Duration) {
            let t = Instant::now();
            let mut stmt = c.prepare_cached(sql).unwrap();
            let n = stmt.column_count();
            let mut rows = stmt.query([]).unwrap();
            let mut count = 0;
            while let Some(r) = rows.next().unwrap() {
                for i in 0..n {
                    let _ = r.get_ref(i).unwrap();
                }
                count += 1;
            }
            (count, t.elapsed())
        }
        let open = || super::super::open_drift_reader(&path).unwrap();
        // 开一条连接 + 第一条点查的代价（空闲回收后重开要付的）。
        let t = Instant::now();
        let probe = open();
        let card: i64 = probe
            .query_row("SELECT rowid FROM srs_cards_cache LIMIT 1 OFFSET 500", [], |r| r.get(0))
            .unwrap_or_default();
        let point = "SELECT * FROM srs_cards_cache WHERE rowid = ?1";
        let first = probe.query_row(point, [card], |_| Ok(())).ok();
        eprintln!("BENCH open+first point read = {:?} (found={})", t.elapsed(), first.is_some());
        let t = Instant::now();
        let _ = open();
        eprintln!("BENCH open (warm) = {:?}", t.elapsed());
        for (label, sql) in [("conflicts", conflicts), ("notes_scan", notes_scan)] {
            // 预热（系统文件缓存）。
            let warm = open();
            let (rows, d) = drain(&warm, sql);
            let (mut used, mut high) = (0, 0);
            // SAFETY: 只读这条连接的一项统计。
            unsafe {
                rusqlite::ffi::sqlite3_db_status(warm.handle(), rusqlite::ffi::SQLITE_DBSTATUS_CACHE_USED, &mut used, &mut high, 0)
            };
            eprintln!("BENCH {label} warmup rows={rows} {d:?} page_cache_used={}KiB", used / 1024);
            for round in 0..2 {
                for n in [1usize, 2, 4, 8] {
                    let conns: Vec<Connection> = (0..n).map(|_| open()).collect();
                    let start = Instant::now();
                    let stop = Arc::new(std::sync::atomic::AtomicBool::new(false));
                    let prober = {
                        let stop = Arc::clone(&stop);
                        let probe = open();
                        std::thread::spawn(move || {
                            let mut worst = Duration::ZERO;
                            let mut samples = 0;
                            while !stop.load(std::sync::atomic::Ordering::SeqCst) {
                                std::thread::sleep(Duration::from_millis(100));
                                let t = Instant::now();
                                let _ = probe.query_row(point, [card], |_| Ok(()));
                                worst = worst.max(t.elapsed());
                                samples += 1;
                            }
                            (worst, samples)
                        })
                    };
                    let handles: Vec<_> = conns
                        .into_iter()
                        .map(|c| {
                            let sql = sql.to_string();
                            std::thread::spawn(move || drain(&c, &sql).1)
                        })
                        .collect();
                    let each: Vec<Duration> = handles.into_iter().map(|h| h.join().unwrap()).collect();
                    let total = start.elapsed();
                    stop.store(true, std::sync::atomic::Ordering::SeqCst);
                    let (worst, samples) = prober.join().unwrap();
                    let max = each.iter().max().unwrap();
                    let min = each.iter().min().unwrap();
                    eprintln!(
                        "BENCH {label} round{round} N={n} total={total:?} per_query=[{min:?}..{max:?}]                          throughput={:.2}/s point_read_worst={worst:?} ({samples} samples)",
                        n as f64 / total.as_secs_f64()
                    );
                }
            }
        }
    }
}
