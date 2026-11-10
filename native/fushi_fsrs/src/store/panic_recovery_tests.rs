//! 一次命令 panic 之后库的状态（BUG-4284）：FFI 把 panic 接成 -100，库要回到一致状态、锁照常可用；panic 留下的
//! 半截事务绝不能被之后的命令提交。

use std::ffi::{CStr, c_char};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::ptr::{null, null_mut};

use rusqlite::types::Value;
use serde_json::json;

use super::ffi::{
    SrsCoreHandle, ffsrs_store_close, ffsrs_store_exec, ffsrs_store_open, ffsrs_store_sync2,
};
use super::kernel_reads_tests::open;
use super::sync2::{in_savepoint, test_panic};
use super::{DRIFT_TX_ABORTED, SrsCore, rows};

fn insert(id: &str) -> String {
    format!(
        "INSERT INTO srs_unknown_events (id, profile_uid, json) VALUES (srs_id('{id}'), 'p', '{{}}')"
    )
}

fn has(core: &SrsCore, id: &str) -> bool {
    let page = core
        .exec(
            "SELECT COUNT(*) FROM srs_unknown_events WHERE id = srs_id(?1)",
            &[Value::Text(id.into())],
            true,
        )
        .unwrap();
    let (_, rows) = rows::decode(&page).unwrap();
    rows[1][0] == Value::Integer(1)
}

/// 持着写锁 panic（命令跑到一半），由 [catch_unwind] 接住——与 FFI 入口（store/ffi.rs `run`）同一形态。
fn panic_holding_writer(core: &SrsCore, body: impl FnOnce(&rusqlite::Connection)) {
    let r = catch_unwind(AssertUnwindSafe(|| {
        let w = core.writer().unwrap();
        body(&w);
        panic!("test: injected panic while holding the writer");
    }));
    assert!(r.is_err());
}

fn ffi_err(err: *mut c_char) -> String {
    if err.is_null() {
        return String::new();
    }
    let s = unsafe { CStr::from_ptr(err) }
        .to_string_lossy()
        .into_owned();
    crate::ffsrs_free_string(err);
    s
}

fn ffi_exec(h: *const SrsCoreHandle, sql: &str) -> (i32, String) {
    let (mut out, mut out_len, mut err) = (null_mut(), 0usize, null_mut());
    let params = rows::encode(0, &[vec![]]);
    let rc = ffsrs_store_exec(
        h,
        sql.as_ptr(),
        sql.len(),
        params.as_ptr(),
        params.len(),
        0,
        &mut out,
        &mut out_len,
        &mut err,
    );
    if !out.is_null() {
        crate::ffsrs_free_bytes(out, out_len);
    }
    (rc, ffi_err(err))
}

/// 经 C ABI：一条写命令（`backfill_tag_sources`，在写连接的 SAVEPOINT 里跑）在提交前 panic → -100；之后的写命令照常
/// 成功，不是永久报「srs writer poisoned」。
#[test]
fn after_a_panicking_command_through_the_c_abi_writes_still_work() {
    let dir = std::env::temp_dir().join(format!("ffsrs_panic_ffi_{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("srs.db");
    let _ = std::fs::remove_file(&path);
    let _ = std::fs::remove_file(dir.join("srs.db-wal"));
    let p = path.to_str().unwrap();
    let (mut h, mut err) = (null_mut(), null_mut());
    assert_eq!(
        ffsrs_store_open(p.as_ptr(), p.len(), &mut h, &mut err),
        0,
        "{}",
        ffi_err(err)
    );

    test_panic::arm(test_panic::BEFORE_RELEASE);
    let req = json!({"profile": "p", "op": "backfill_tag_sources"}).to_string();
    let (mut out, mut out_len, mut err) = (null_mut(), 0usize, null_mut());
    let rc = ffsrs_store_sync2(
        h,
        req.as_ptr(),
        req.len(),
        null(),
        0,
        &mut out,
        &mut out_len,
        &mut err,
    );
    assert_eq!(rc, super::ffi::STORE_PANIC, "{}", ffi_err(err));
    let _ = ffi_err(err);
    assert!(!test_panic::armed(), "the injected panic fired");

    for id in ["after1", "after2"] {
        let (rc, e) = ffi_exec(h, &insert(id));
        assert_eq!(rc, 0, "write after the panic failed: {e}");
    }
    let (rc, e) = ffi_exec(h, "BEGIN TRANSACTION");
    assert_eq!(rc, 0, "{e}");
    let (rc, e) = ffi_exec(h, "COMMIT TRANSACTION");
    assert_eq!(rc, 0, "{e}");
    ffsrs_store_close(h);
}

/// Rust 写命令自己开的事务里写了一半就 panic：恢复把它整笔回滚，之后的命令照常提交自己的写入，半截写入不会被
/// 它们捎带着提交（关库重开后也不在）。
#[test]
fn a_half_written_command_is_rolled_back_not_committed_by_later_ones() {
    let core = open("panic_half_written");
    panic_holding_writer(&core, |w| {
        in_savepoint(w, |c| {
            c.execute_batch(&insert("half")).unwrap();
            test_panic::arm(test_panic::BEFORE_RELEASE);
            Ok(())
        })
        .unwrap();
    });
    core.exec(&insert("later"), &[], false).unwrap();
    assert!(!core.in_transaction().unwrap());
    assert!(has(&core, "later"));
    assert!(!has(&core, "half"));
    let path = core.path.clone();
    core.close();
    drop(core);
    let core = SrsCore::open(&path).unwrap();
    assert!(has(&core, "later"));
    assert!(
        !has(&core, "half"),
        "the panicked command's write was committed"
    );
}

/// Drift 事务开着时一条嵌在里面的 Rust 写命令 panic：整笔 Drift 事务回滚，之后那笔事务的语句（含 COMMIT）一律
/// 拒绝、Rust 写命令也拒绝，直到 Drift 发来 ROLLBACK；回滚之后一切照常。事务里的写入一条都不落库。
#[test]
fn a_panic_inside_a_drift_transaction_aborts_it_until_drift_rolls_back() {
    let core = open("panic_in_drift_tx");
    core.exec("BEGIN TRANSACTION", &[], false).unwrap();
    core.exec(&insert("drift_a"), &[], false).unwrap();
    panic_holding_writer(&core, |w| {
        in_savepoint(w, |c| {
            c.execute_batch(&insert("rust_b"))
                .map_err(|e| e.to_string())
        })
        .unwrap();
    });
    // 那笔事务后续的语句：既不在 autocommit 下逐条提交，也不能把事务提交上去。
    assert_eq!(
        core.exec(&insert("drift_c"), &[], false).err().as_deref(),
        Some(DRIFT_TX_ABORTED)
    );
    assert_eq!(
        core.exec_batch(&[insert("drift_c").as_str()], &[(0, vec![])])
            .err()
            .as_deref(),
        Some(DRIFT_TX_ABORTED)
    );
    assert_eq!(
        core.select("SELECT 1", &[]).err().as_deref(),
        Some(DRIFT_TX_ABORTED)
    );
    assert_eq!(
        core.exec("ROLLBACK TO s1", &[], false).err().as_deref(),
        Some(DRIFT_TX_ABORTED)
    );
    assert_eq!(
        core.exec("COMMIT TRANSACTION", &[], false).err().as_deref(),
        Some(DRIFT_TX_ABORTED)
    );
    assert_eq!(core.writer().err().as_deref(), Some(DRIFT_TX_ABORTED));
    // 事务外的只读命令照常（读已提交的数据：那笔事务的行已被回滚）。
    assert_eq!(
        core.read_visible_tx(|c, uncommitted| {
            let n: i64 = c
                .query_row("SELECT COUNT(*) FROM srs_unknown_events", [], |r| r.get(0))
                .map_err(|e| e.to_string())?;
            Ok((n, uncommitted))
        }),
        Ok((0, false))
    );
    core.exec("ROLLBACK TRANSACTION", &[], false).unwrap();
    assert!(!core.in_transaction().unwrap());
    core.exec(&insert("after"), &[], false).unwrap();
    for id in ["drift_a", "rust_b", "drift_c"] {
        assert!(!has(&core, id), "{id} reached the database");
    }
    assert!(has(&core, "after"));
    // 再开一笔事务照常提交。
    core.exec("BEGIN TRANSACTION", &[], false).unwrap();
    core.exec(&insert("next_tx"), &[], false).unwrap();
    core.exec("COMMIT TRANSACTION", &[], false).unwrap();
    assert!(has(&core, "next_tx"));
}

/// Drift 发 BEGIN 的那条语句本身 panic：Drift 收到的是「开事务失败」，不会再发 ROLLBACK——恢复只回滚、不进「待
/// 回滚」状态，之后的语句照常。
#[test]
fn a_panic_on_the_statement_that_opens_a_drift_transaction_does_not_wedge_the_store() {
    let core = open("panic_on_begin");
    test_panic::arm(test_panic::AFTER_EXEC);
    let r = catch_unwind(AssertUnwindSafe(|| {
        core.exec("BEGIN TRANSACTION", &[], false)
    }));
    assert!(r.is_err());
    core.exec(&insert("after"), &[], false).unwrap();
    assert!(!core.in_transaction().unwrap());
    assert!(has(&core, "after"));
}

/// 旧库搬迁事务开着时 panic：搬迁事务回滚并结束；之后 commit 报「未开始」，abort 照常成功，库里没有标记。
#[test]
fn a_panic_during_the_legacy_import_ends_it_without_committing() {
    let dir = std::env::temp_dir().join(format!("ffsrs_panic_legacy_{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let p = dir.join("srs.db");
    let _ = std::fs::remove_file(&p);
    let _ = std::fs::remove_file(dir.join("srs.db-wal"));
    let core = SrsCore::open(&p).unwrap();
    core.legacy_begin().unwrap();
    panic_holding_writer(&core, |w| {
        w.execute_batch(&insert("legacy_row")).unwrap();
    });
    assert_eq!(
        core.legacy_commit().err().as_deref(),
        Some("legacy import not started")
    );
    core.legacy_abort().unwrap();
    assert!(!core.legacy_imported().unwrap());
    assert!(!core.in_transaction().unwrap());
    assert!(!has(&core, "legacy_row"));
}

/// 旧库搬迁事务开着时 panic、Dart 还没来得及 legacy_abort：Drift 的写语句不该一直被「搬迁进行中」挡住——取写锁
/// 的恢复已经结束了搬迁。
#[test]
fn after_a_panic_during_the_legacy_import_drift_writes_are_not_refused() {
    let dir = std::env::temp_dir().join(format!("ffsrs_panic_legacy_exec_{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let p = dir.join("srs.db");
    let _ = std::fs::remove_file(&p);
    let _ = std::fs::remove_file(dir.join("srs.db-wal"));
    let core = SrsCore::open(&p).unwrap();
    core.legacy_begin().unwrap();
    panic_holding_writer(&core, |w| {
        w.execute_batch(&insert("legacy_row")).unwrap();
    });
    core.exec(&insert("after"), &[], false).unwrap();
    assert!(!core.in_transaction().unwrap());
    assert!(has(&core, "after"));
    assert!(!has(&core, "legacy_row"));
    assert!(!core.legacy_imported().unwrap());
}

/// 读命令在读快照里 panic（`BEGIN` 之后没走到 `ROLLBACK`）：那条读连接不能带着旧快照回到池里——之后的读看得见
/// 新提交的行，也不报「srs reader poisoned」。
#[test]
fn a_panicking_read_does_not_leave_a_stale_snapshot_behind() {
    let core = open("panic_in_read");
    core.exec(&insert("before"), &[], false).unwrap();
    let r = catch_unwind(AssertUnwindSafe(|| {
        core.read_visible::<()>(|c| {
            assert!(
                c.query_row("SELECT COUNT(*) FROM srs_unknown_events", [], |r| r
                    .get::<_, i64>(0))
                    .unwrap()
                    == 1
            );
            panic!("test: injected panic inside a read snapshot");
        })
    }));
    assert!(r.is_err());
    core.exec(&insert("after"), &[], false).unwrap();
    let n: i64 = core
        .read_visible(|c| {
            c.query_row("SELECT COUNT(*) FROM srs_unknown_events", [], |r| r.get(0))
                .map_err(|e| e.to_string())
        })
        .unwrap();
    assert_eq!(n, 2, "a read after the panic saw a stale snapshot");
    // 直接取读连接的路径（同步、媒体、快照）同一口径。
    let r = catch_unwind(AssertUnwindSafe(|| {
        let r = core.reader().unwrap();
        r.execute_batch("BEGIN; SELECT COUNT(*) FROM srs_unknown_events;")
            .unwrap();
        panic!("test: injected panic on the reader");
    }));
    assert!(r.is_err());
    core.exec(&insert("after2"), &[], false).unwrap();
    let r = core.reader().unwrap();
    assert!(r.is_autocommit());
    let n: i64 = r
        .query_row("SELECT COUNT(*) FROM srs_unknown_events", [], |r| r.get(0))
        .unwrap();
    assert_eq!(n, 3);
}

/// 收段阶段的锁被 panic 毒化：阶段回到「没有会话」（同投递出错时作废会话），之后照常可用，不永久报
/// 「ingest session poisoned」。
#[test]
fn a_panic_holding_the_ingest_phase_ends_the_ingest_session() {
    let core = open("panic_in_ingest");
    let r = catch_unwind(AssertUnwindSafe(|| {
        let mut g = core.ingest_phase().unwrap();
        core.set_ingest_phase(
            &mut g,
            super::sync2::transport::IngestPhase::Draining("p".into()),
        );
        panic!("test: injected panic during ingest");
    }));
    assert!(r.is_err());
    let g = core.ingest_phase().unwrap();
    assert!(matches!(*g, super::sync2::transport::IngestPhase::Idle));
    assert!(
        !core
            .ingest_holds_cache
            .load(std::sync::atomic::Ordering::Relaxed)
    );
}

/// 复习队列 / 浏览会话的内存缓存在建 / 重读到一半时 panic：缓存整份丢掉、下次整份重建（同重建出错时丢会话），
/// 不在半截状态上继续增量。
#[test]
fn a_panic_while_building_the_study_queue_drops_the_cached_session() {
    let core = open("panic_in_queue");
    let req = json!({"now": 1_700_000_000_000_i64, "utcOff": 0, "rollover": 4});
    core.study("p", &req).unwrap();
    let builds = || {
        core.study_hub
            .builds
            .load(std::sync::atomic::Ordering::SeqCst)
    };
    let before = builds();
    core.study("p", &req).unwrap();
    assert_eq!(builds(), before, "a second study reuses the session");
    let r = catch_unwind(AssertUnwindSafe(|| core.study_hub.panic_holding_sessions()));
    assert!(r.is_err());
    core.study("p", &req).unwrap();
    assert_eq!(
        builds(),
        before + 1,
        "the half-updated session was not rebuilt"
    );
}
