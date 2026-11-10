//! 内核只读命令（[SrsCore::read_visible] 一族：`study`、`stats_bundle`、浏览、AnkiConnect……）之间的并发。

use std::sync::mpsc;
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::SrsCore;

/// 临时目录里的一个新库（同名测试重跑先删旧文件）。
pub(super) fn open(name: &str) -> SrsCore {
    let dir = std::env::temp_dir().join(format!("ffsrs_kreads_{name}_{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let p = dir.join("srs.db");
    let _ = std::fs::remove_file(&p);
    let _ = std::fs::remove_file(dir.join("srs.db-wal"));
    let core = SrsCore::open(&p).unwrap();
    core.legacy_mark_none().unwrap();
    core
}

/// 真实库上量「一条全库 `stats_bundle` 在跑时，交互道的 `study` 要等多久」（手动跑，只在库副本上）：
/// `FUSHI_SRS_REAL_DB=<srs.db 副本> cargo test --release --lib kernel_reads_tests::real_db_study_during_stats_bundle -- --ignored --nocapture`
#[test]
#[ignore]
fn real_db_study_during_stats_bundle() {
    let path = std::path::PathBuf::from(
        std::env::var("FUSHI_SRS_REAL_DB").expect("set FUSHI_SRS_REAL_DB"),
    );
    let core = std::sync::Arc::new(SrsCore::open(&path).unwrap());
    let profile: String = core
        .read_visible(|c| {
            c.query_row(
                "SELECT srs_idt(profile_uid) FROM srs_cards_cache GROUP BY profile_uid \
                 ORDER BY COUNT(*) DESC LIMIT 1",
                [],
                |r| r.get(0),
            )
            .map_err(|e| e.to_string())
        })
        .unwrap();
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64;
    let req = json!({"now": now, "utcOff": 0, "rollover": 4, "pick": true});
    let bundle = |core: &SrsCore| -> Duration {
        let t = Instant::now();
        let mut files = Vec::new();
        core.read_visible(|c| super::bulk::stats_bundle(c, &profile, &mut files))
            .unwrap();
        t.elapsed()
    };
    let study = |core: &SrsCore| -> Duration {
        let t = Instant::now();
        core.study(&profile, &req).unwrap();
        t.elapsed()
    };
    eprintln!("BENCH first stats_bundle = {:?}", bundle(&core));
    eprintln!("BENCH first study (builds the queue) = {:?}", study(&core));
    let mut alone: Vec<Duration> = (0..20).map(|_| study(&core)).collect();
    alone.sort();
    eprintln!(
        "BENCH study alone: median {:?}, max {:?}",
        alone[alone.len() / 2],
        alone[alone.len() - 1]
    );
    let mut long = Vec::new();
    for _ in 0..5 {
        long.push(bundle(&core));
    }
    long.sort();
    eprintln!(
        "BENCH stats_bundle alone: median {:?}",
        long[long.len() / 2]
    );
    let mut waits = Vec::new();
    for _ in 0..5 {
        let (tx, rx) = mpsc::channel();
        let c2 = core.clone();
        let p2 = profile.clone();
        let h = std::thread::spawn(move || {
            let t = Instant::now();
            let mut files = Vec::new();
            c2.read_visible(|c| {
                tx.send(()).unwrap();
                super::bulk::stats_bundle(c, &p2, &mut files)
            })
            .unwrap();
            t.elapsed()
        });
        rx.recv().unwrap();
        let w = study(&core);
        let b = h.join().unwrap();
        eprintln!("BENCH study while stats_bundle runs = {w:?} (stats_bundle {b:?})");
        waits.push(w);
    }
    waits.sort();
    eprintln!(
        "BENCH study during stats_bundle: median {:?}, max {:?}",
        waits[waits.len() / 2],
        waits[waits.len() - 1]
    );
}

/// 一条内核只读命令还没跑完（这里用一个停在读快照里的 [SrsCore::read_visible] 模拟全库 `stats_bundle`），另一条
/// 只读命令（`study`）不等它：读命令各借一条读连接，不在同一把锁上排队。
#[test]
fn a_running_kernel_read_does_not_hold_up_study() {
    let core = std::sync::Arc::new(open("study_not_held_up"));
    let (started_tx, started_rx) = mpsc::channel();
    let (release_tx, release_rx) = mpsc::channel::<()>();
    let long = {
        let core = core.clone();
        std::thread::spawn(move || {
            core.read_visible(|c| {
                c.query_row("SELECT COUNT(*) FROM srs_cards_cache", [], |r| {
                    r.get::<_, i64>(0)
                })
                .map_err(|e| e.to_string())?;
                started_tx.send(()).unwrap();
                release_rx.recv().unwrap();
                Ok(())
            })
            .unwrap();
        })
    };
    started_rx.recv().unwrap();
    let (done_tx, done_rx) = mpsc::channel();
    let quick = {
        let core = core.clone();
        std::thread::spawn(move || {
            let req: Value = json!({"now": 1_700_000_000_000_i64, "utcOff": 0, "rollover": 4});
            done_tx.send(core.study("p", &req).map(|_| ())).unwrap();
        })
    };
    let got = done_rx.recv_timeout(Duration::from_secs(10));
    release_tx.send(()).unwrap();
    long.join().unwrap();
    quick.join().unwrap();
    assert_eq!(
        got.expect("study waited for the other read command to finish"),
        Ok(())
    );
}
