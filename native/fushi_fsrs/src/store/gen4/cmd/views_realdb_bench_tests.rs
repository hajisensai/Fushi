//! 真库上的批量读耗时（BUG-5566：复习历史捐赠页首次统计慢）：`read entities / edits / logs` 与 `entity_views`
//! 一次读一整个集合的笔记 / 卡要多久。默认不跑；跑法（[REALDB_ENV] 指向一份**副本**的 `srs4.db`，测试再拷一份到它
//! 旁边的工作目录里打开，原文件不动）：
//!
//! ```text
//! FUSHI_G4_REALDB=<副本>/srs4.db cargo test --profile quick --lib views_realdb_bench -- --ignored --nocapture
//! ```
//!
//! 分段耗时加 `RUSTFLAGS="--cfg srs_probe"`（`store/prof.rs`），每条命令后打印各段累计。

use std::time::{Instant, SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

use super::dispatch_tests::{call, open};
use crate::store::ffi::ffsrs_store_close;
use crate::store::gen4::derive::Ref;

const REALDB_ENV: &str = "FUSHI_G4_REALDB";

fn ms(t: Instant) -> f64 {
    t.elapsed().as_secs_f64() * 1000.0
}

#[test]
#[ignore = "benchmark on a copy of a real library: set FUSHI_G4_REALDB"]
fn views_realdb_bench_bulk_reads() {
    let Ok(src) = std::env::var(REALDB_ENV) else {
        eprintln!("[realdb] {REALDB_ENV} not set: skipped");
        return;
    };
    let src = std::path::PathBuf::from(src);
    let work = src
        .parent()
        .unwrap()
        .join(format!("views-{}", std::process::id()));
    std::fs::create_dir_all(&work).unwrap();
    std::fs::copy(&src, work.join("srs4.db")).unwrap();
    let wal = src.with_extension("db-wal");
    if wal.exists() {
        std::fs::copy(&wal, work.join("srs4.db-wal")).unwrap();
    }
    let (profile, notes, cards): (String, Vec<String>, Vec<String>) = {
        let c = rusqlite::Connection::open(work.join("srs4.db")).unwrap();
        let (profile, col): (String, i64) = c
            .query_row(
                "SELECT c.profile_uid, c.col FROM collections c \
                 ORDER BY (SELECT COUNT(*) FROM cards WHERE col = c.col) DESC LIMIT 1",
                [],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .unwrap();
        let ids = |q: &str| -> Vec<String> {
            let mut st = c.prepare(q).unwrap();
            st.query_map([col], |r| Ok(r.get::<_, Ref>(0)?.text()))
                .unwrap()
                .map(|x| x.unwrap())
                .collect()
        };
        (
            profile,
            // 与 Dart 侧基准（捐赠预览）同一批：可见卡与它们的笔记。
            ids("SELECT note_id FROM cards WHERE col = ?1 AND hidden = 0 GROUP BY note_id"),
            ids("SELECT id FROM cards WHERE col = ?1 AND hidden = 0"),
        )
    };
    eprintln!(
        "[realdb] profile {profile}: {} notes, {} cards",
        notes.len(),
        cards.len()
    );
    let h = open(&work, 0).unwrap_or_else(|(rc, e)| panic!("{rc} {e}"));
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64;
    let run = |label: &str, extra: Value| {
        let mut req = json!({"profile": profile, "now": now});
        for (k, v) in extra.as_object().cloned().unwrap() {
            req[k.as_str()] = v;
        }
        crate::store::prof::dump();
        let t = Instant::now();
        let (v, files) = call(h, &req, None).unwrap_or_else(|(rc, e)| panic!("{label}: {rc} {e}"));
        let took = ms(t);
        let bytes: usize = files.iter().map(|(_, b)| b.len()).sum();
        eprintln!(
            "[realdb] {label}: {took:.1} ms (reply JSON {} bytes, file bytes {bytes})",
            v.to_string().len()
        );
        crate::store::prof::dump();
    };
    let cap = 4096;
    let n = &notes[..notes.len().min(cap)];
    let k = &cards[..cards.len().min(cap)];
    // Dart 侧（SrsDbStore.notes / histories）按块发：笔记每块 500 条、卡每块 200 张。一块一条命令。
    let chunked = |label: &str, ids: &[String], size: usize, mk: &dyn Fn(&[String]) -> Value| {
        crate::store::prof::dump();
        let t = Instant::now();
        for c in ids.chunks(size) {
            let mut req = mk(c);
            req["profile"] = json!(profile);
            req["now"] = json!(now);
            call(h, &req, None).unwrap_or_else(|(rc, e)| panic!("{label}: {rc} {e}"));
        }
        eprintln!("[realdb] {label} in chunks of {size}: {:.1} ms", ms(t));
        crate::store::prof::dump();
    };
    for round in 0..2 {
        eprintln!("[realdb] --- round {round}");
        chunked(
            "read edits(notes)",
            n,
            500,
            &|c| json!({"op": "read", "q": "edits", "kind": "note", "ids": c}),
        );
        chunked(
            "read logs(cards)",
            k,
            200,
            &|c| json!({"op": "read", "q": "logs", "cards": c}),
        );
        run(
            "read entities(notes)",
            json!({"op": "read", "q": "entities", "kind": "note", "ids": n}),
        );
        run(
            "read edits(notes)",
            json!({"op": "read", "q": "edits", "kind": "note", "ids": n}),
        );
        run(
            "entity_views(notes)",
            json!({"op": "entity_views", "kind": "note", "ids": n}),
        );
        run(
            "read entities(cards)",
            json!({"op": "read", "q": "entities", "kind": "card", "ids": k}),
        );
        run(
            "read edits(cards)",
            json!({"op": "read", "q": "edits", "kind": "card", "ids": k}),
        );
        run(
            "read logs(cards)",
            json!({"op": "read", "q": "logs", "cards": k}),
        );
        run(
            "entity_views(cards)",
            json!({"op": "entity_views", "kind": "card", "ids": k}),
        );
    }
    ffsrs_store_close(h);
    let _ = std::fs::remove_dir_all(&work);
}
