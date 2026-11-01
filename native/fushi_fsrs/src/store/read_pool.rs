//! Drift 执行器事务外查询用的只读连接池（[super::SrsCore::snapshot_select]）。
//!
//! 以前 Drift 的事务外查询只有一条读连接、外加 Dart 侧整条 Drift 连接是一个顺序队列：同步里一条几秒的长读
//! （全量冲突扫描、媒体对账）跑着时，打开卡片 / 牌组设置的毫秒级短读排在它后面等满全程。WAL 下只读连接互不
//! 阻塞，这里按需开到 [ReadPool::cap] 条，同时在途的查询各占一条，用完放回。
//!
//! - 按需开：第一条在打开库时开（打开失败当场报出）；其余在并发真的出现时才开，开出来的常驻到关库。
//! - 到上限：调用方在条件变量上等一条被放回（Dart 侧发查询的 worker 数不超过上限，正常不会等）。
//! - 关闭（[ReadPool::close]）：标记已关闭、丢掉空闲的连接，再等在途的查询把手上那条放回（放回时直接关掉）。
//!   返回时池子开过的连接一条不剩；之后取连接一律报「已关闭」。
//! - 每条连接每条语句自成一个读事务（语句跑完 rusqlite 即复位，不留跨调用的读事务）：开读事务时取最新的
//!   WAL 尾，所以调用方等到写返回后再发的查询一定看得见它。不同连接上并行的两条查询各自看各自开始时刻的
//!   已提交数据——与以前单条读连接上前后两条语句之间可能隔着一次提交是同一种保证（从来没有跨语句快照）。

use std::ops::Deref;
use std::path::{Path, PathBuf};
use std::sync::{Condvar, Mutex};

use rusqlite::Connection;

use super::CLOSED;

/// 打开一条只读连接（配置好 PRAGMA / SQL 函数）。
pub(crate) type Opener = fn(&Path) -> Result<Connection, String>;

pub(crate) struct ReadPool {
    path: PathBuf,
    cap: usize,
    open: Opener,
    state: Mutex<State>,
    returned: Condvar,
}

struct State {
    idle: Vec<Connection>,
    /// 开着的连接数（空闲 + 借出）。
    live: usize,
    closed: bool,
}

/// 借出的一条连接；析构时放回（池子已关闭就关掉）。
pub(crate) struct Pooled<'a> {
    pool: &'a ReadPool,
    conn: Option<Connection>,
}

impl ReadPool {
    /// 建池并先开一条连接（打开失败当场报错）。
    pub(crate) fn new(path: &Path, cap: usize, open: Opener) -> Result<Self, String> {
        let first = open(path)?;
        Ok(Self {
            path: path.to_path_buf(),
            cap: cap.max(1),
            open,
            state: Mutex::new(State { idle: vec![first], live: 1, closed: false }),
            returned: Condvar::new(),
        })
    }

    fn state(&self) -> std::sync::MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// 借一条连接：有空闲的就用，没有且没到上限就新开，到上限等一条放回。
    pub(crate) fn get(&self) -> Result<Pooled<'_>, String> {
        let mut st = self.state();
        loop {
            if st.closed {
                return Err(CLOSED.to_string());
            }
            if let Some(conn) = st.idle.pop() {
                return Ok(Pooled { pool: self, conn: Some(conn) });
            }
            if st.live < self.cap {
                st.live += 1;
                drop(st);
                // 开连接不持池锁：别的线程照常借还。
                return match (self.open)(&self.path) {
                    Ok(conn) => Ok(Pooled { pool: self, conn: Some(conn) }),
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

    /// 开着的连接数（空闲 + 借出；测试看上限与关闭回收）。
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
            st.idle.push(conn);
            drop(st);
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

    use super::super::{rows, SrsCore, CLOSED, DRIFT_READERS, NOT_SNAPSHOT};

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

    /// 连接数封顶：借满 [DRIFT_READERS] 条后再借要等一条放回，不会多开。
    #[test]
    fn pool_is_capped_and_waits_for_a_returned_connection() {
        let core = Arc::new(open("cap"));
        let held: Vec<_> = (0..DRIFT_READERS).map(|_| core.drift_readers.get().unwrap()).collect();
        assert_eq!(core.drift_readers.live(), DRIFT_READERS);
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
        assert_eq!(core.drift_readers.live(), DRIFT_READERS);
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
}
