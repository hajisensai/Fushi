//! srs.db 磁盘占用（2026-10-30）：配置快照按内容去重、冗余索引去掉之后的回归，与真实大库的升级量体积工具。

use std::path::Path;

use serde_json::{json, Value};

use super::tests::{deck_entity, edit, review, Bucket, Device, DAY, P};
use crate::store::SrsCore;

const T0: i64 = 1_700_000_000_000;

/// 真实大库升级到当前版本（不计入常规测试）：`FUSHI_SRS_FOOTPRINT_DB=<库副本> cargo test footprint_upgrade_file -- --ignored`。
/// 打开即迁移；打印迁移耗时。量体积在外面做（VACUUM 后看文件大小 / dbstat）。
#[test]
#[ignore]
fn footprint_upgrade_file() {
    let Ok(path) = std::env::var("FUSHI_SRS_FOOTPRINT_DB") else { return };
    let t = std::time::Instant::now();
    let core = SrsCore::open(Path::new(&path)).unwrap();
    drop(core);
    println!("FOOTPRINT upgraded {path} in {} ms", t.elapsed().as_millis());
}

fn count(d: &Device, q: &str) -> i64 {
    d.rows(q)[1][0].parse().unwrap()
}

/// 本机作答的每条日志都带「作答那一刻的生效配置」（设计 §4.6），一份约几百字节、几乎总是同一份：操作日志与日志投影
/// 都只存它在 `sync2_snapshots` 里的编号，读出来与原文逐字相同（重放、摘要、发出去的段都看原文）。
#[test]
fn config_snapshots_are_stored_once() {
    let deck = super::config::default_deck_id(P);
    let a = Device::new("fp-a");
    let b = Device::new("fp-b");
    let mut bucket = Bucket::default();
    a.apply(T0, vec![deck_entity(&deck), edit("deck", &deck, "retention", json!(0.8))]);
    for i in 0..40 {
        a.apply(T0 + 10 + i * DAY, vec![review(&format!("r{i}"), &format!("C{}", i % 7), T0 + 10 + i * DAY, 3, "learn")]);
    }
    a.apply(T0 + 50 * DAY, vec![edit("deck", &deck, "retention", json!(0.9))]);
    a.apply(T0 + 51 * DAY, vec![review("late", "C0", T0 + 51 * DAY, 3, "review")]);
    assert_eq!(count(&a, "SELECT COUNT(*) FROM sync2_snapshots"), 2, "two distinct configs, stored once each");
    println!("FOOTPRINT snapshot body bytes: {:?}", a.rows("SELECT length(body) FROM sync2_snapshots"));
    // 投影里存编号，读出来是原文。
    let raw = a.rows("SELECT json FROM srs_review_logs WHERE id = 'r3'")[1][0].clone();
    let stored: Value = serde_json::from_str(&raw).unwrap();
    assert!(stored["sc"].as_str().is_some_and(|h| h.len() == 32), "{raw}");
    let full = super::tests::log_json(&a, "r3");
    assert_eq!(full["sc"]["ret"], json!(0.8), "{full}");
    assert_eq!(super::tests::log_json(&a, "late")["sc"]["ret"], json!(0.9));
    // 操作日志里也只存编号（载荷去掉了快照原文）。
    let inline = count(&a, "SELECT COUNT(*) FROM sync2_ops WHERE kind = 3 AND sc IS NULL");
    assert_eq!(inline, 0, "every stamped log op stores its snapshot by reference");
    // 发出去的段里是原文：另一台设备收齐后投影逐行相同，摘要一致。
    a.sync(&mut bucket, "loc", T0 + 52 * DAY);
    b.sync(&mut bucket, "loc", T0 + 52 * DAY);
    assert_eq!(super::tests::projection(&a), super::tests::projection(&b));
    assert_eq!(super::tests::log_json(&b, "r3"), full);
    assert_eq!(count(&b, "SELECT COUNT(*) FROM sync2_snapshots"), 2);
    let da = a.core.sync2_digest(P).unwrap();
    let db = b.core.sync2_digest(P).unwrap();
    assert_eq!(da, db);
}

/// v15 → v16 升级：存量的内联快照（操作载荷与日志投影）改成引用，读回来逐字相同；摘要不变；升级可重放（标回 15
/// 再开一次结果相同）；之后发出去的段与升级前逐字节相同。
#[test]
fn v16_upgrade_moves_inline_snapshots_out_without_changing_anything_observable() {
    let deck = super::config::default_deck_id(P);
    let a = Device::new("fp-up");
    a.apply(T0, vec![deck_entity(&deck), edit("deck", &deck, "retention", json!(0.85))]);
    for i in 0..12 {
        a.apply(T0 + 10 + i * DAY, vec![review(&format!("u{i}"), &format!("C{}", i % 3), T0 + 10 + i * DAY, 1 + i % 4, "review")]);
    }
    let digest = a.digest();
    let full: Vec<Value> = (0..12).map(|i| super::tests::log_json(&a, &format!("u{i}"))).collect();
    let payloads = |d: &Device| -> Vec<Vec<u8>> {
        let w = d.core.writer().unwrap();
        let ids: Vec<(Vec<u8>, i64)> = w
            .prepare("SELECT device, seq FROM sync2_ops ORDER BY device, seq")
            .unwrap()
            .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        ids.into_iter()
            .map(|(dv, s)| {
                let id = crate::sync2::vv::OpId { device: crate::sync2::id::Id(dv.try_into().unwrap()), seq: s as u64 };
                super::load_op(&w, P, &id).unwrap().unwrap().payload.to_vec()
            })
            .collect()
    };
    let before = payloads(&a);
    // 退回 v15 的存储形态：载荷与投影都内联原文，快照表清空，标 15。
    {
        let w = a.core.writer().unwrap();
        let rows: Vec<(String, String)> = w
            .prepare("SELECT id, json FROM srs_review_logs")
            .unwrap()
            .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        for (id, j) in rows {
            let j = super::snapshots::expand_text(&w, j).unwrap();
            w.execute("UPDATE srs_review_logs SET json = ?2 WHERE id = ?1", rusqlite::params![id, j]).unwrap();
        }
        let ops: Vec<(Vec<u8>, i64, Vec<u8>, Option<String>, Option<i64>)> = w
            .prepare("SELECT device, seq, payload, sc, sc_at FROM sync2_ops")
            .unwrap()
            .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?)))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        for (dv, s, p, sc, at) in ops {
            let p = super::snapshots::unpack_payload(&w, p, sc, at).unwrap();
            w.execute(
                "UPDATE sync2_ops SET payload = ?3, sc = NULL, sc_at = NULL WHERE device = ?1 AND seq = ?2",
                rusqlite::params![dv, s, p],
            )
            .unwrap();
        }
        w.execute_batch(
            "DELETE FROM sync2_snapshots; \
             CREATE INDEX idx_sync2_ent_ops_what ON sync2_ent_ops (profile_uid, kind, entity, what); \
             UPDATE srs_meta SET value = '15' WHERE key = 'schema';",
        )
        .unwrap();
    }
    assert_eq!(count(&a, "SELECT COUNT(*) FROM sync2_ops WHERE sc IS NOT NULL"), 0);
    assert_eq!(a.digest(), digest, "the inline form hashes the same");
    let path = a._dir.0.join("srs.db");
    for round in 0..2 {
        let b = Device { core: SrsCore::open(&path).unwrap(), _dir: super::tests::tempdir::new("fp-up-unused") };
        assert_eq!(count(&b, "SELECT COUNT(*) FROM sync2_snapshots"), 1, "round {round}");
        assert_eq!(count(&b, "SELECT COUNT(*) FROM sync2_ops WHERE kind = 3 AND sc IS NULL"), 0, "round {round}");
        assert_eq!(count(&b, "SELECT COUNT(*) FROM srs_review_logs WHERE instr(json, '\"sc\":{') > 0"), 0, "round {round}");
        assert_eq!(count(&b, "SELECT COUNT(*) FROM sqlite_master WHERE name = 'idx_sync2_ent_ops_what'"), 0);
        let got: Vec<Value> = (0..12).map(|i| super::tests::log_json(&b, &format!("u{i}"))).collect();
        assert_eq!(got, full, "round {round}");
        assert_eq!(payloads(&b), before, "op payloads read back byte for byte (round {round})");
        assert_eq!(b.digest(), digest, "round {round}");
        assert_eq!(b.core.sync2_digest(P).unwrap()["digest"], a.core.sync2_digest(P).unwrap()["digest"]);
        drop(b);
        // 中途被杀 / 重放：标回 15 再开一次，结果相同。
        a.core.writer().unwrap().execute_batch("UPDATE srs_meta SET value = '15' WHERE key = 'schema';").unwrap();
    }
}

/// 本机作答的规模基准（不计入常规测试）：`cargo test footprint_answered_reviews -- --ignored --nocapture`。
/// 训练过参数的牌组（FSRS-6，21 个参数）下作答 N 次，比较「快照按引用存」与退回内联存法两份库 VACUUM 后的体积。
#[test]
#[ignore]
fn footprint_answered_reviews() {
    let n: i64 = std::env::var("FUSHI_SRS_FOOTPRINT_REVIEWS").ok().and_then(|v| v.parse().ok()).unwrap_or(30_000);
    let deck = super::config::default_deck_id(P);
    let a = Device::new("fp-bench");
    let params: Vec<f64> = (0..21).map(|i| 0.1 + f64::from(i) * 0.731_234_5).collect();
    a.apply(T0, vec![deck_entity(&deck), edit("deck", &deck, "alg", json!("fsrs6")), edit("deck", &deck, "f6", json!({"params": params}))]);
    let t = std::time::Instant::now();
    let mut i = 0;
    while i < n {
        let batch: Vec<Value> = (i..(i + 500).min(n))
            .map(|k| review(&format!("b{k}"), &format!("C{}", k % 3000), T0 + 10 + k * 60_000, 1 + k % 4, "review"))
            .collect();
        a.apply(T0 + 10 + i * 60_000, batch);
        i += 500;
    }
    let body: Vec<Vec<String>> = a.rows("SELECT length(body) FROM sync2_snapshots");
    let size = |tag: &str| -> u64 {
        let out = a._dir.0.join(format!("{tag}.db"));
        a.core.writer().unwrap().execute("VACUUM INTO ?1", [out.to_string_lossy()]).unwrap();
        std::fs::metadata(&out).unwrap().len()
    };
    let packed = size("packed");
    // 退回内联存法（v15 的形态）。
    {
        let w = a.core.writer().unwrap();
        let rows: Vec<(String, String)> = w
            .prepare("SELECT id, json FROM srs_review_logs")
            .unwrap()
            .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        for (id, j) in rows {
            let j = super::snapshots::expand_text(&w, j).unwrap();
            w.execute("UPDATE srs_review_logs SET json = ?2 WHERE id = ?1", rusqlite::params![id, j]).unwrap();
        }
        let ops: Vec<(Vec<u8>, i64, Vec<u8>, Option<String>, Option<i64>)> = w
            .prepare("SELECT device, seq, payload, sc, sc_at FROM sync2_ops")
            .unwrap()
            .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?)))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        for (dv, s, p, sc, at) in ops {
            let p = super::snapshots::unpack_payload(&w, p, sc, at).unwrap();
            w.execute("UPDATE sync2_ops SET payload = ?3, sc = NULL, sc_at = NULL WHERE device = ?1 AND seq = ?2", rusqlite::params![dv, s, p])
                .unwrap();
        }
    }
    let inline = size("inline");
    println!(
        "FOOTPRINT {n} answered reviews in {} ms; snapshot bytes {body:?}; inline {inline} B, by reference {packed} B ({:.2}x), {} B saved per review",
        t.elapsed().as_millis(),
        inline as f64 / packed as f64,
        (inline - packed) / n as u64
    );
}
