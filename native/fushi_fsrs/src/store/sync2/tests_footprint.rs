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

/// 本机作答的每条日志都带「作答那一刻的生效配置」（设计 §4.6），一份约几百字节、几乎总是同一份：操作日志只存它在
/// `sync2_snapshots` 里的编号，读出来与原文逐字节相同（发出去的段、重签发都看原文）；投影保持原文（Dart 读的契约）。
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
    // 投影是原文。
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

/// v15 → v16 升级：操作载荷里存量的内联快照改成引用，读回来逐字节相同；投影与摘要不变；升级可重放（标回 15
/// 再开一次结果相同）。
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
    // 退回 v15 的存储形态：载荷内联原文，快照表清空，标 15。
    {
        let w = a.core.writer().unwrap();
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
/// 训练过参数的牌组（FSRS-7，34 个参数）下作答 N 次，比较「操作日志快照按引用存」与退回内联存法两份库 VACUUM 后的体积。
#[test]
#[ignore]
fn footprint_answered_reviews() {
    let n: i64 = std::env::var("FUSHI_SRS_FOOTPRINT_REVIEWS").ok().and_then(|v| v.parse().ok()).unwrap_or(30_000);
    let deck = super::config::default_deck_id(P);
    let a = Device::new("fp-bench");
    let params: Vec<f64> = (0..34).map(|i| 0.1 + f64::from(i) * 0.731_234_5).collect();
    a.apply(T0, vec![deck_entity(&deck), edit("deck", &deck, "fsrs7Params", json!({"params": params}))]);
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

/// 一台设备：牌组配置、两张卡的复习（含重放改写）、笔记字段与标签（合成行）。
fn busy_device(tag: &str) -> Device {
    let deck = super::config::default_deck_id(P);
    let a = Device::new(tag);
    a.apply(T0, vec![deck_entity(&deck), edit("deck", &deck, "retention", json!(0.85))]);
    for i in 0..10 {
        let at = T0 + 10 + i * DAY;
        a.apply(at, vec![review(&format!("p{i}"), &format!("C{}", i % 2), at, 1 + i % 4, "review")]);
        a.apply(at + 1, vec![edit("note", "N1", &format!("f/{i}"), json!(format!("v{i}"))), edit("note", "N1", "tags", json!([format!("t{i}")]))]);
    }
    a
}

/// 退回 v16 的存储形态：日志 / 修改记录是带原文 `json` 列的普通表，摘要触发器挂在它们上，标 16。
fn demote_to_v16(d: &Device) {
    let w = d.core.writer().unwrap();
    w.execute_batch(
        "CREATE TEMP TABLE l AS SELECT rowid AS r, id, profile_uid, card_id, kind, rating, occurred_at, review_type, origin, duration_ms, json FROM srs_review_logs;
         CREATE TEMP TABLE f AS SELECT rowid AS r, id, profile_uid, entity_kind, entity_id, field_key, writer_id, seq, json FROM srs_field_edits;
         DROP VIEW srs_review_logs; DROP VIEW srs_field_edits; DROP TABLE srs_review_log_rows; DROP TABLE srs_field_edit_rows;
         CREATE TABLE srs_field_edits (id TEXT NOT NULL, profile_uid TEXT NOT NULL, entity_kind TEXT NOT NULL, entity_id TEXT NOT NULL,
           field_key TEXT NOT NULL, writer_id TEXT NOT NULL, seq INTEGER NOT NULL, json TEXT NOT NULL, PRIMARY KEY (id));
         CREATE TABLE srs_review_logs (id TEXT NOT NULL, profile_uid TEXT NOT NULL, card_id TEXT NOT NULL, kind TEXT NOT NULL,
           rating INTEGER NULL, occurred_at INTEGER NOT NULL, review_type TEXT NOT NULL, origin TEXT NOT NULL,
           duration_ms INTEGER NOT NULL DEFAULT 0, json TEXT NOT NULL, PRIMARY KEY (id));
         INSERT INTO srs_review_logs (rowid, id, profile_uid, card_id, kind, rating, occurred_at, review_type, origin, duration_ms, json)
           SELECT r, id, profile_uid, card_id, kind, rating, occurred_at, review_type, origin, duration_ms, json FROM temp.l;
         INSERT INTO srs_field_edits (rowid, id, profile_uid, entity_kind, entity_id, field_key, writer_id, seq, json)
           SELECT r, id, profile_uid, entity_kind, entity_id, field_key, writer_id, seq, json FROM temp.f;
         DROP TABLE temp.l; DROP TABLE temp.f;
         CREATE INDEX idx_srs_review_logs_card ON srs_review_logs (card_id);
         CREATE INDEX idx_srs_review_logs_profile_kind_time ON srs_review_logs
           (profile_uid, kind, occurred_at, card_id, review_type);
         CREATE INDEX idx_srs_field_edits_entity ON srs_field_edits (entity_kind, entity_id);
         UPDATE srs_meta SET value = '16' WHERE key = 'schema';
         DELETE FROM srs_meta WHERE key = 'compact_pending';",
    )
    .unwrap();
    super::digest::install(&w).unwrap();
}

/// v16 → v17：日志 / 修改记录换成「存储表 + 同名视图」，推得出的行只存操作指针（重放改过的 `res`、并了旧闭包的
/// `ctx` 记成覆盖键，合成的标签行存原文）。经视图读到的每一行逐字相同、rowid 相同；摘要不变；之后的同步与重放照常；
/// 升级可重放；打开时整理了文件（空闲页清零）。
#[test]
fn v17_stores_projection_rows_by_op_without_changing_anything_observable() {
    let a = busy_device("fp17");
    let rows = |d: &Device| -> Vec<Vec<String>> {
        let mut out = d.rows("SELECT rowid, id, card_id, json FROM srs_review_logs ORDER BY rowid");
        out.extend(d.rows("SELECT rowid, id, entity_id, json FROM srs_field_edits ORDER BY rowid"));
        out
    };
    let before = rows(&a);
    let digest = a.digest();
    demote_to_v16(&a);
    assert_eq!(rows(&a), before, "the demoted v16 tables hold the same text");
    assert_eq!(a.digest(), digest);
    let path = a._dir.0.join("srs.db");
    for round in 0..2 {
        let b = Device { core: SrsCore::open(&path).unwrap(), _dir: super::tests::tempdir::new("fp17-unused") };
        assert_eq!(rows(&b), before, "round {round}");
        assert_eq!(b.digest(), digest, "round {round}");
        assert_eq!(count(&b, "SELECT COUNT(*) FROM sqlite_master WHERE type = 'view' AND name IN ('srs_review_logs', 'srs_field_edits')"), 2);
        let logs = count(&b, "SELECT COUNT(*) FROM srs_review_log_rows");
        assert_eq!(count(&b, "SELECT COUNT(*) FROM srs_review_log_rows WHERE op_dev IS NOT NULL"), logs, "every log row is derivable");
        let by_op = count(&b, "SELECT COUNT(*) FROM srs_field_edit_rows WHERE op_dev IS NOT NULL");
        let synthetic = count(&b, "SELECT COUNT(*) FROM srs_field_edit_rows WHERE field_key = 'tags'");
        assert_eq!(by_op + synthetic, count(&b, "SELECT COUNT(*) FROM srs_field_edit_rows"), "only the synthesised tag rows keep their text");
        assert_eq!(count(&b, "SELECT COUNT(*) FROM srs_meta WHERE key = 'compact_pending'"), 0, "compacted on open");
        assert_eq!(count(&b, "PRAGMA freelist_count"), 0);
        drop(b);
        a.core.writer().unwrap().execute_batch("UPDATE srs_meta SET value = '16' WHERE key = 'schema';").unwrap();
    }
    // 升级之后照常写：再复习、再改字段，另一台设备同步收齐后投影逐行相同、摘要一致。
    let a = Device { core: SrsCore::open(&path).unwrap(), _dir: super::tests::tempdir::new("fp17-unused2") };
    let b = Device::new("fp17-b");
    let mut bucket = Bucket::default();
    a.apply(T0 + 20 * DAY, vec![review("late", "C0", T0 + 20 * DAY, 3, "review"), edit("note", "N1", "f/0", json!("again"))]);
    a.sync(&mut bucket, "loc", T0 + 21 * DAY);
    b.sync(&mut bucket, "loc", T0 + 21 * DAY);
    assert_eq!(super::tests::projection(&a), super::tests::projection(&b));
    assert_eq!(a.core.sync2_digest(P).unwrap()["digest"], b.core.sync2_digest(P).unwrap()["digest"]);
}

/// 从 v16 之前的版本直接升上来：v10 起的步骤就在读操作（寄存器重建），那时 `sync2_ops` 还没有 v16 的快照引用两列
/// ——读操作的代码要它们，升级阶梯得先补上（真实大库 v9 → v16 曾在这里失败）。
#[test]
fn upgrading_from_before_v16_adds_the_snapshot_columns_before_reading_ops() {
    let a = busy_device("fp-old");
    let before = super::tests::projection(&a);
    demote_to_v16(&a);
    let path = a._dir.0.join("srs.db");
    // 裸连接：设备自己的写连接上挂着指向 v17 存储表的 TEMP 触发器，退回旧形状后改表会重新解析它们。
    rusqlite::Connection::open(&path)
        .unwrap()
        .execute_batch("ALTER TABLE sync2_ops DROP COLUMN sc; ALTER TABLE sync2_ops DROP COLUMN sc_at; UPDATE srs_meta SET value = '9' WHERE key = 'schema';")
        .unwrap();
    let b = Device { core: SrsCore::open(&path).unwrap(), _dir: super::tests::tempdir::new("fp-old-unused") };
    assert_eq!(super::tests::projection(&b), before);
}

/// 空间不够就不整理：记下原因、标记留着、库照常可用；空间够了下次打开再整理。
#[test]
fn compaction_waits_for_disk_space() {
    let a = busy_device("fp-disk");
    let w = a.core.writer().unwrap();
    w.execute_batch("INSERT INTO srs_meta (key, value) VALUES ('compact_pending', '17');").unwrap();
    assert!(!crate::store::compact::run(&w, &a._dir.0, Some(1024), 7));
    let last: String = w.query_row("SELECT value FROM srs_meta WHERE key = 'compact_last'", [], |r| r.get(0)).unwrap();
    assert!(last.contains("\"reason\":\"disk\""), "{last}");
    assert!(w.query_row("SELECT 1 FROM srs_meta WHERE key = 'compact_pending'", [], |_| Ok(())).is_ok());
    assert!(crate::store::compact::run(&w, &a._dir.0, Some(u64::MAX), 8));
    assert!(w.query_row("SELECT 1 FROM srs_meta WHERE key = 'compact_pending'", [], |_| Ok(())).is_err());
    assert!(crate::store::compact::free_bytes(&a._dir.0.join("srs.db")).is_some_and(|f| f > 0));
}
