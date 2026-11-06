//! Anki 包导入形状的本机写入基准（默认不跑）：`SRS_BENCH_CARDS` 张卡（缺省 9000）× 每张 `SRS_BENCH_LOGS`
//! 条 Anki 来源复习（缺省 37）+ 一条导入锚点，按 Dart 导入的节奏每 1000 条一次 `apply`。
//! `SRS_BENCH_AUTOCKPT=<页>`：写连接的 `wal_autocheckpoint`（0 = 不并回，量每条事件写进 WAL 的字节）；
//! `SRS_BENCH_NODIGEST=1`：去掉日志表的摘要触发器（量它占多少）。
//! `cargo test --release --lib import_apply_bench -- --ignored --nocapture`

use std::time::Instant;

use serde_json::{Value, json};

use super::tests::{DAY, Device, P};

fn env(k: &str, d: i64) -> i64 {
    std::env::var(k)
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(d)
}

fn anki_review(id: &str, card: &str, at: i64, reps: i64) -> Value {
    json!({"t": "log", "x": {
        "id": id, "p": P, "card": card, "kind": "review", "rating": 3, "hlc": format!("{at}:0:anki"), "at": at,
        "ts": "wall", "origin": "anki", "rtype": "review", "dur": 4200, "alg": "anki", "utcOff": 480, "rollover": 4,
        "fv": 1, "ankiId": at,
        "res": {"queue": "review", "dueDay": 19000 + reps * 3, "ivl": 3, "step": 0, "reps": reps, "lapses": 0,
                "scheduler": "anki", "ease": 2500, "lastReviewedAt": at}
    }})
}

fn anchor(id: &str, card: &str, at: i64) -> Value {
    json!({"t": "log", "x": {
        "id": id, "p": P, "card": card, "kind": "importAnchor", "hlc": format!("{at}:0:anchor"), "at": at,
        "ts": "wall", "origin": "anki", "rtype": "manual", "utcOff": 480, "rollover": 4, "fv": 1,
        "res": {"queue": "review", "dueDay": 19200, "ivl": 30, "step": 0, "reps": 37, "lapses": 0, "scheduler": "anki", "ease": 2500}
    }})
}

#[test]
#[ignore]
fn import_apply_bench() {
    let cards = env("SRS_BENCH_CARDS", 9000);
    let per = env("SRS_BENCH_LOGS", 37);
    let a = Device::new("import-bench");
    let deck = super::config::default_deck_id(P);
    a.apply(
        0,
        vec![
            super::tests::deck_entity(&deck),
            super::tests::edit("deck", &deck, "name", json!("Default")),
        ],
    );
    if let Ok(pages) = std::env::var("SRS_BENCH_AUTOCKPT") {
        a.core
            .exec(&format!("PRAGMA wal_autocheckpoint = {pages}"), &[], true)
            .unwrap();
    }
    // 写连接页缓存：`SRS_BENCH_CACHE_KIB=<n>` 钉死上限（缺省按可用内存自适应，store/mem_budget.rs）；
    // `SRS_BENCH_HOLD=1` 按 Dart `bulkWrites` 那样批间留着页缓存（缺省每批结束收回到 8 MB）。
    if let Ok(kib) = std::env::var("SRS_BENCH_CACHE_KIB") {
        a.core
            .exec(&format!("PRAGMA cache_size = -{kib}"), &[], true)
            .unwrap();
    }
    a.core
        .set_bulk_holds_cache(std::env::var("SRS_BENCH_HOLD").is_ok());
    if std::env::var("SRS_BENCH_NODIGEST").is_ok() {
        a.core
            .exec("DROP TRIGGER sync2_dg_srs_review_logs_ins", &[], false)
            .unwrap();
    }
    let wal = a._dir.0.join("srs.db-wal");
    let t0: i64 = 1_600_000_000_000;
    let mut batch: Vec<Value> = Vec::with_capacity(1000);
    let mut n = 0usize;
    let mut calls = 0usize;
    let mut ffi_ms = 0f64;
    let mut flush = |batch: &mut Vec<Value>, now: i64, ffi_ms: &mut f64, calls: &mut usize| {
        if batch.is_empty() {
            return;
        }
        let s = Value::Array(std::mem::take(batch)).to_string();
        let t = Instant::now();
        a.core.sync2_apply_local(P, now, &s).unwrap();
        *ffi_ms += t.elapsed().as_secs_f64() * 1000.0;
        *calls += 1;
    };
    let started = Instant::now();
    for c in 0..cards {
        let card = format!("0193a1b2-0000-7000-8000-{c:012x}");
        let note = format!("0193a1b2-0000-7000-9000-{c:012x}");
        for r in 0..per {
            let at = t0 + r * 3 * DAY + c;
            batch.push(json!({"e": anki_review(&format!("0193a1b2-0000-7000-a000-{:012x}", c * 1000 + r), &card, at, r + 1), "note": note}));
            n += 1;
            if batch.len() >= 1000 {
                flush(&mut batch, t0 + 400 * DAY, &mut ffi_ms, &mut calls);
            }
        }
        batch.push(json!({"e": anchor(&format!("0193a1b2-0000-7000-b000-{c:012x}"), &card, t0 + per * 3 * DAY + c), "note": note}));
        n += 1;
        if batch.len() >= 1000 {
            flush(&mut batch, t0 + 400 * DAY, &mut ffi_ms, &mut calls);
        }
    }
    flush(&mut batch, t0 + 400 * DAY, &mut ffi_ms, &mut calls);
    let total = started.elapsed().as_secs_f64() * 1000.0;
    let wal_bytes = std::fs::metadata(&wal).map(|m| m.len()).unwrap_or(0);
    let db_bytes = std::fs::metadata(a._dir.0.join("srs.db"))
        .map(|m| m.len())
        .unwrap_or(0);
    println!(
        "import_apply_bench wal={}MB ({} B/event) db={}MB",
        wal_bytes >> 20,
        wal_bytes / n as u64,
        db_bytes >> 20
    );
    println!(
        "import_apply_bench events={n} calls={calls} apply={ffi_ms:.0}ms total={total:.0}ms per_event={:.1}us",
        ffi_ms * 1000.0 / n as f64
    );
}
