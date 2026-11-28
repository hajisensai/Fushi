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
use super::tests::decode;
use crate::store::ffi::ffsrs_store_close;
use crate::store::gen4::derive::Ref;

const REALDB_ENV: &str = "FUSHI_G4_REALDB";

fn ms(t: Instant) -> f64 {
    t.elapsed().as_secs_f64() * 1000.0
}

/// 宿主以前的笔记物化（Dart `srsMaterializeNotes`）：payload + `read edits` 的 (行, 服务器时刻) 送进 `materialize` 的
/// `note` 组。
fn host_materialized(payload: &str, edits: &[(String, String)]) -> Value {
    let header = format!(r#"[{{"t":"note","n":{},"rec":{payload}}}]"#, edits.len());
    let (mut text, mut offs, mut servers) = (String::new(), vec![0u32], Vec::new());
    for (j, st) in edits {
        text.push_str(j);
        offs.push(text.len() as u32);
        servers.push(if st == "∅" {
            crate::history::NONE_I64
        } else {
            st.parse().unwrap()
        });
    }
    let out =
        crate::registers::materialize(header.as_bytes(), text.as_bytes(), &offs, &servers).unwrap();
    let mut out: Vec<Value> = serde_json::from_slice(&out).unwrap();
    out.remove(0)
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
    // `read note_views` 与它替掉的宿主路径（`read entities` + `read edits` + `ffsrs_materialize`）在整份真库上逐条相同；
    // 整批卡一起重放的 `read logs` 与逐卡一条命令的逐行相同（BUG-5572）。
    let table = |req: Value, file: &str| -> Vec<Vec<String>> {
        let mut req = req;
        req["profile"] = json!(profile);
        req["now"] = json!(now);
        let (_, files) = call(h, &req, None).unwrap_or_else(|(rc, e)| panic!("{rc} {e}"));
        let f = files.iter().find(|(n, _)| n == file).expect(file);
        decode(&f.1).1
    };
    let t = Instant::now();
    for c in n.chunks(500) {
        let views = table(json!({"op": "read", "q": "note_views", "ids": c}), "t");
        let rows = table(json!({"op": "read", "q": "note_views", "ids": c}), "e");
        let fields = table(json!({"op": "read", "q": "note_views", "ids": c}), "f");
        let mut f_at = 0usize;
        let ents = table(json!({"op": "read", "q": "entities", "ids": c}), "t");
        let edits = table(
            json!({"op": "read", "q": "edits", "kind": "note", "ids": c}),
            "t",
        );
        assert_eq!(views.len(), ents.len());
        let (mut at, mut want_at) = (0usize, 0usize);
        for (v, e) in views.iter().zip(&ents) {
            assert_eq!(v[0], e[0]);
            let n: usize = v[2].parse().unwrap();
            let mine: Vec<(String, String)> = rows[at..at + n]
                .iter()
                .map(|r| (r[0].clone(), r[1].clone()))
                .collect();
            at += n;
            let want: Vec<(String, String)> = edits[want_at..]
                .iter()
                .take_while(|r| r[0] == v[0])
                .map(|r| (r[1].clone(), r[2].clone()))
                .collect();
            want_at += want.len();
            assert_eq!(mine, want, "{}: rows", v[0]);
            let nf: usize = v[3].parse().unwrap();
            let mut got: Value = serde_json::from_str(&v[1]).unwrap();
            got["v"]["f"] = json!(
                fields[f_at..f_at + nf]
                    .iter()
                    .map(|f| json!([f[0], f[1]]))
                    .collect::<Vec<_>>()
            );
            f_at += nf;
            assert_eq!(got, host_materialized(&e[2], &mine), "{}: view", v[0]);
        }
    }
    eprintln!(
        "[realdb] note_views == host materialize for {} notes ({:.1} ms)",
        n.len(),
        ms(t)
    );
    let t = Instant::now();
    let mut batched = Vec::new();
    for c in k.chunks(200) {
        batched.extend(table(json!({"op": "read", "q": "logs", "cards": c}), "t"));
    }
    let mut single = Vec::new();
    for c in k.chunks(200) {
        let mut c: Vec<&String> = c.iter().collect();
        c.sort_by(|a, b| {
            super::sql_order(&super::ref_of(a)).cmp(&super::sql_order(&super::ref_of(b)))
        });
        for card in c {
            single.extend(table(
                json!({"op": "read", "q": "logs", "cards": [card]}),
                "t",
            ));
        }
    }
    assert_eq!(batched.len(), single.len());
    assert!(batched == single, "batched logs = one card at a time");
    eprintln!(
        "[realdb] read logs batched == per card: {} rows ({:.1} ms)",
        single.len(),
        ms(t)
    );
    for round in 0..2 {
        eprintln!("[realdb] --- round {round}");
        chunked(
            "read note_views(notes)",
            n,
            500,
            &|c| json!({"op": "read", "q": "note_views", "ids": c}),
        );
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
