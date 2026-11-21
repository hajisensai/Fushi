//! 真库上的出卡耗时（`study_bench_tests.rs` 的真数据版）。默认不跑；跑法（[REALDB_ENV] 指向一份**副本**的 `srs4.db`，
//! 测试再拷一份到它旁边的工作目录里打开，原文件不动）：
//!
//! ```text
//! FUSHI_G4_REALDB=<副本>/srs4.db cargo test --profile quick --lib study_realdb_bench -- --ignored --nocapture
//! ```

use std::time::{Instant, SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

use super::dispatch_tests::{call, open};
use crate::store::ffi::ffsrs_store_close;
use crate::store::gen4::derive::Ref;

const REALDB_ENV: &str = "FUSHI_G4_REALDB";
const ANSWERS: usize = 30;

fn ms(t: Instant) -> f64 {
    t.elapsed().as_secs_f64() * 1000.0
}

#[test]
#[ignore = "benchmark on a copy of a real library: set FUSHI_G4_REALDB"]
fn study_realdb_bench_answer_and_study() {
    let Ok(src) = std::env::var(REALDB_ENV) else {
        eprintln!("[realdb] {REALDB_ENV} not set: skipped");
        return;
    };
    let src = std::path::PathBuf::from(src);
    let work = src
        .parent()
        .unwrap()
        .join(format!("work-{}", std::process::id()));
    std::fs::create_dir_all(&work).unwrap();
    std::fs::copy(&src, work.join("srs4.db")).unwrap();
    let (profile, col, deck, new_cards): (String, i64, String, Vec<(String, String)>) = {
        let c = rusqlite::Connection::open(work.join("srs4.db")).unwrap();
        let (profile, col): (String, i64) = c
            .query_row(
                "SELECT c.profile_uid, c.col FROM collections c \
                 ORDER BY (SELECT COUNT(*) FROM cards WHERE col = c.col) DESC LIMIT 1",
                [],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .unwrap();
        let deck: Ref = c
            .query_row(
                "SELECT deck_id FROM cards WHERE col = ?1 AND hidden = 0 \
                 GROUP BY deck_id ORDER BY COUNT(*) DESC LIMIT 1",
                [col],
                |r| r.get(0),
            )
            .unwrap();
        let mut st = c
            .prepare(
                "SELECT id, note_id FROM cards WHERE col = ?1 AND queue = 'new' AND hidden = 0 \
                 AND suspended = 0 LIMIT ?2",
            )
            .unwrap();
        let cards = st
            .query_map(rusqlite::params![col, ANSWERS as i64], |r| {
                Ok((r.get::<_, Ref>(0)?.text(), r.get::<_, Ref>(1)?.text()))
            })
            .unwrap()
            .map(|x| x.unwrap())
            .collect();
        let n: i64 = c
            .query_row("SELECT COUNT(*) FROM cards WHERE col = ?1", [col], |r| {
                r.get(0)
            })
            .unwrap();
        let logs: i64 = c
            .query_row("SELECT COUNT(*) FROM log_ix WHERE col = ?1", [col], |r| {
                r.get(0)
            })
            .unwrap();
        eprintln!("[realdb] col {col}: {n} cards, {logs} log_ix rows");
        (profile, col, deck.text(), cards)
    };
    let _ = col;
    let h = open(&work, 0).unwrap_or_else(|(rc, e)| panic!("{rc} {e}"));
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64;
    let req = |op: &str, now: i64, extra: Value| -> Value {
        let mut r = json!({"op": op, "profile": profile, "now": now});
        for (k, v) in extra.as_object().cloned().unwrap_or_default() {
            r[k.as_str()] = v;
        }
        r
    };
    let sreq =
        |now: i64| json!({"now": now, "utcOff": 480, "rollover": 4, "deck": deck, "pick": true});
    for i in 0..3 {
        let t = Instant::now();
        let (v, _) = call(h, &req("study", now, sreq(now)), None).unwrap();
        eprintln!(
            "[realdb] study #{} (no writes in between): {:.1} ms (counts: {} decks)",
            i + 1,
            ms(t),
            v["counts"].as_object().map_or(0, |m| m.len())
        );
    }
    let mut times = Vec::new();
    for (k, (card, note)) in new_cards.iter().enumerate() {
        let at = now + 1_000 + k as i64 * 10_000;
        let items = vec![json!({"e": {"t": "log", "x": {
            "id": format!("bench-{k}"), "p": profile, "card": card, "kind": "review", "rating": 3,
            "hlc": format!("{at}:0:dart"), "at": at, "ts": "anchored", "origin": "fushi", "rtype": "learn",
            "utcOff": 480, "rollover": 4, "fv": 1,
            "res": {"queue": "new", "ivl": 0, "step": 0, "reps": 0, "lapses": 0, "scheduler": "fushi"}
        }}, "note": note, "intent": "answer"})];
        let t = Instant::now();
        let (v, _) = call(
            h,
            &req("apply", at, json!({"study": sreq(at + 1)})),
            Some(&items),
        )
        .unwrap();
        times.push(ms(t));
        assert!(v["study"]["counts"].is_object(), "{v}");
    }
    for (i, t) in times.iter().enumerate() {
        if i < 3 || (i + 1) % 10 == 0 {
            eprintln!("[realdb] answer+study #{:>2}: {t:.1} ms", i + 1);
        }
    }
    if !times.is_empty() {
        eprintln!(
            "[realdb] answer+study avg over {}: {:.1} ms",
            times.len(),
            times.iter().sum::<f64>() / times.len() as f64
        );
    }
    let last = now + 1_000 + new_cards.len() as i64 * 10_000;
    let t = Instant::now();
    call(h, &req("study", last, sreq(last)), None).unwrap();
    eprintln!("[realdb] study after the answers: {:.1} ms", ms(t));
    ffsrs_store_close(h);
    let _ = std::fs::remove_dir_all(&work);
}

/// 真库的打开耗时（Primary 开库时补建检查点之前建的闭包行，`kernel.rs` `backfill_closure_steps`）与打开后第一次单独
/// 排队；再关掉重开一次（已补过，只剩一句存在性查询）对照。跑法同上。
#[test]
#[ignore = "benchmark on a copy of a real library: set FUSHI_G4_REALDB"]
fn study_realdb_bench_open_backfill() {
    let Ok(src) = std::env::var(REALDB_ENV) else {
        eprintln!("[realdb] {REALDB_ENV} not set: skipped");
        return;
    };
    let src = std::path::PathBuf::from(src);
    let work = src
        .parent()
        .unwrap()
        .join(format!("open-{}", std::process::id()));
    std::fs::create_dir_all(&work).unwrap();
    std::fs::copy(&src, work.join("srs4.db")).unwrap();
    let (profile, deck): (String, String) = {
        let c = rusqlite::Connection::open(work.join("srs4.db")).unwrap();
        let missing: i64 = c
            .query_row(
                "SELECT COUNT(*) FROM closure_ix WHERE upto >= 1024 AND json_type(ctx, '$.at') IS NULL",
                [],
                |r| r.get(0),
            )
            .unwrap();
        eprintln!("[realdb] closure rows without checkpoints: {missing}");
        let (profile, col): (String, i64) = c
            .query_row(
                "SELECT c.profile_uid, c.col FROM collections c \
                 ORDER BY (SELECT COUNT(*) FROM cards WHERE col = c.col) DESC LIMIT 1",
                [],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .unwrap();
        let deck: Ref = c
            .query_row(
                "SELECT deck_id FROM cards WHERE col = ?1 AND hidden = 0 \
                 GROUP BY deck_id ORDER BY COUNT(*) DESC LIMIT 1",
                [col],
                |r| r.get(0),
            )
            .unwrap();
        (profile, deck.text())
    };
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64;
    let req = json!({"op": "study", "profile": profile,
        "now": now, "utcOff": 480, "rollover": 4, "deck": deck, "pick": true});
    for round in ["first open (backfills)", "reopen"] {
        let t = Instant::now();
        let h = open(&work, 0).unwrap_or_else(|(rc, e)| panic!("{rc} {e}"));
        eprintln!("[realdb] {round}: open {:.1} ms", ms(t));
        for i in 0..2 {
            let t = Instant::now();
            call(h, &req, None).unwrap();
            eprintln!("[realdb] {round}: study #{} {:.1} ms", i + 1, ms(t));
        }
        ffsrs_store_close(h);
    }
    let _ = std::fs::remove_dir_all(&work);
}
