//! 关库取消在途命令（`cancel.rs`，拍板台 review-merge-1124-leftovers 第 5 条）：在途的写命令被打断 / 在批次边界停下
//! 时整笔回滚、不提交半截，关库不等它跑完。语句「确实在跑」用 SQL 函数 `probe()` 第一次被调时的屏障确定（不靠睡）。

use std::path::Path;
use std::sync::{Arc, Barrier, Once};
use std::time::{Duration, Instant};

use rusqlite::functions::FunctionFlags;
use rusqlite::{Connection, OpenFlags};

use crate::store::CLOSED;
use crate::store::gen4::files::{GEN4_FILE, OpenMode};
use crate::store::gen4::kernel::G4Core;
use crate::store::gen4::schema::sql;
use crate::store::sync2::tests::tempdir;

const PROBE_KEY: &str = "cancel_tests_probe";

/// 库里还有没有 [PROBE_KEY] 那一行（关库之后另开一条只读连接看，看到的是已提交的全部）。
fn probe_committed(dir: &Path) -> bool {
    let c =
        Connection::open_with_flags(dir.join(GEN4_FILE), OpenFlags::SQLITE_OPEN_READ_ONLY).unwrap();
    c.query_row(
        "SELECT count(*) FROM srs_meta WHERE key = ?1",
        [PROBE_KEY],
        |r| r.get::<_, i64>(0),
    )
    .unwrap()
        > 0
}

fn insert_probe(conn: &Connection) -> Result<(), String> {
    conn.execute(
        "INSERT INTO srs_meta (key, value) VALUES (?1, '1')",
        [PROBE_KEY],
    )
    .map(|_| ())
    .map_err(sql)
}

/// 写命令里先落一行，再跑一条要跑好几分钟的语句；它在跑的时候关库：语句被进度回调打断，事务整笔回滚（先落的那一行
/// 也不在），关库在它退出之后就返回，不等它跑完。
#[test]
fn closing_interrupts_a_long_write_and_rolls_it_back() {
    let dir = tempdir::new("g4cancel-long");
    let core = Arc::new(G4Core::open(&dir.0, OpenMode::Primary).unwrap());
    let running = Arc::new(Barrier::new(2));
    let started = Instant::now();
    let worker = {
        let (core, running) = (Arc::clone(&core), Arc::clone(&running));
        std::thread::spawn(move || {
            core.write(|t| {
                insert_probe(t.conn())?;
                let once = Once::new();
                t.conn()
                    .create_scalar_function("probe", 1, FunctionFlags::SQLITE_UTF8, move |ctx| {
                        once.call_once(|| {
                            running.wait();
                        });
                        ctx.get::<i64>(0)
                    })
                    .map_err(sql)?;
                t.conn()
                    .query_row(
                        "WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM n \
                         WHERE x < 100000000000) SELECT count(*) FROM n WHERE probe(x) > 0",
                        [],
                        |r| r.get::<_, i64>(0),
                    )
                    .map_err(sql)?;
                Ok(())
            })
        })
    };
    running.wait();
    core.close();
    let out = worker.join().unwrap();
    assert!(out.is_err(), "an interrupted write must fail: {out:?}");
    assert!(core.is_cancelled());
    assert!(
        started.elapsed() < Duration::from_secs(30),
        "closing must not wait for the statement to run to the end: {:?}",
        started.elapsed()
    );
    assert_eq!(core.writer().err().as_deref(), Some(CLOSED));
    drop(core);
    assert!(
        !probe_committed(&dir.0),
        "the interrupted write rolled back"
    );
}

/// 写命令在两条语句之间被取消（没有长语句可打断）：真相层写入的守卫（批次边界）报 `CLOSED`；就算命令自己吞掉了错误、
/// 照常返回，提交之前的那次检查也让整笔回滚、报 `CLOSED`，不提交半截。之后借不到读 / 写连接。
#[test]
fn a_write_cancelled_between_statements_is_not_committed() {
    let dir = tempdir::new("g4cancel-between");
    let core = Arc::new(G4Core::open(&dir.0, OpenMode::Primary).unwrap());
    let entered = Arc::new(Barrier::new(2));
    let resumed = Arc::new(Barrier::new(2));
    let worker = {
        let (core, entered, resumed) = (
            Arc::clone(&core),
            Arc::clone(&entered),
            Arc::clone(&resumed),
        );
        std::thread::spawn(move || {
            let mut guarded = Ok(());
            let out = core.write(|t| {
                insert_probe(t.conn())?;
                entered.wait();
                resumed.wait();
                guarded = t.write(|| Ok(()));
                Ok(())
            });
            (out, guarded)
        })
    };
    entered.wait();
    core.cancel();
    resumed.wait();
    let (out, guarded) = worker.join().unwrap();
    assert_eq!(guarded, Err(CLOSED.to_owned()), "the truth-write guard");
    assert_eq!(out, Err(CLOSED.to_owned()), "the pre-commit check");
    assert_eq!(core.reader().err().as_deref(), Some(CLOSED));
    assert_eq!(core.writer().err().as_deref(), Some(CLOSED));
    core.close();
    drop(core);
    assert!(
        !probe_committed(&dir.0),
        "nothing of the cancelled write landed"
    );
}

/// 没有取消时同一条写命令照常提交（上面两条的对照：回滚是取消造成的，不是写法本身落不下）。
#[test]
fn an_uncancelled_write_commits() {
    let dir = tempdir::new("g4cancel-control");
    let core = G4Core::open(&dir.0, OpenMode::Primary).unwrap();
    core.write(|t| insert_probe(t.conn())).unwrap();
    assert!(!core.is_cancelled());
    core.close();
    drop(core);
    assert!(probe_committed(&dir.0));
}
