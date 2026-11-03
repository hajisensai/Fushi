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
    // 两张投影表的 `json` 升级前后逐字节相同（v18 起读的是生成列）。
    let digest = || {
        use sha2::{Digest, Sha256};
        let c = rusqlite::Connection::open(&path).unwrap();
        crate::store::ids::register(&c).unwrap();
        crate::store::slim::register(&c).unwrap();
        ["srs_review_logs", "srs_field_edits"].map(|t| {
            let mut h = Sha256::new();
            let mut s = c.prepare(&format!("SELECT json FROM {t} ORDER BY rowid")).unwrap();
            let mut rows = s.query([]).unwrap();
            let mut n = 0;
            while let Some(r) = rows.next().unwrap() {
                h.update(r.get_ref(0).unwrap().as_str().unwrap().as_bytes());
                h.update([0]);
                n += 1;
            }
            (n, h.finalize().iter().map(|b| format!("{b:02x}")).collect::<String>())
        })
    };
    let t = std::time::Instant::now();
    let before = digest();
    println!("FOOTPRINT read all projection json before in {} ms", t.elapsed().as_millis());
    let t = std::time::Instant::now();
    let core = SrsCore::open(Path::new(&path)).unwrap();
    drop(core);
    println!("FOOTPRINT upgraded {path} in {} ms", t.elapsed().as_millis());
    let t = std::time::Instant::now();
    assert_eq!(digest(), before, "projection json changed by the upgrade");
    println!("FOOTPRINT read all projection json after in {} ms", t.elapsed().as_millis());
    // 拼回本身的开销：同样扫一遍、只读存储列。
    let c = rusqlite::Connection::open(&path).unwrap();
    let t = std::time::Instant::now();
    let mut n = 0usize;
    for table in ["srs_review_logs", "srs_field_edits"] {
        let mut s = c.prepare(&format!("SELECT jslim FROM {table} ORDER BY rowid")).unwrap();
        let mut rows = s.query([]).unwrap();
        while let Some(r) = rows.next().unwrap() {
            n += r.get_ref(0).unwrap().as_str().unwrap().len();
        }
    }
    println!("FOOTPRINT read all stored jslim in {} ms ({n} bytes)", t.elapsed().as_millis());
    println!("FOOTPRINT json digests {before:?}");
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

/// 全部操作载荷经 [super::load_op] 读回（按主键序）。
fn all_payloads(d: &Device) -> Vec<Vec<u8>> {
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
}

/// 退回 v15 的载荷形态：快照原文拼回载荷、引用两列清空、快照表清空。
fn inline_snapshots(w: &rusqlite::Connection) {
    let ops: Vec<(Vec<u8>, i64, Vec<u8>, Option<String>, Option<i64>, i64)> = w
        .prepare("SELECT device, seq, payload, sc, sc_at, pz FROM sync2_ops")
        .unwrap()
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?, r.get(5)?)))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap();
    for (dv, s, p, sc, at, pz) in ops {
        let p = super::snapshots::unpack_payload(w, p, sc, at, pz).unwrap();
        w.execute("UPDATE sync2_ops SET payload = ?3, sc = NULL, sc_at = NULL, pz = 0 WHERE device = ?1 AND seq = ?2", rusqlite::params![dv, s, p])
            .unwrap();
    }
    w.execute_batch("DELETE FROM sync2_snapshots;").unwrap();
}

/// 回归：v16 升级以前把全部日志载荷一次读进内存（大库升级内存随库线性涨）。现在在同一事务里按主键键集分页读、
/// 逐页改：几千条日志按小页走完，每页不超过页大小，结果与改之前逐字节相同。
#[test]
fn v16_upgrade_reads_the_log_in_bounded_pages() {
    let deck = super::config::default_deck_id(P);
    let a = Device::new("fp-pages");
    a.apply(T0, vec![deck_entity(&deck), edit("deck", &deck, "retention", json!(0.85))]);
    let n: i64 = 3000;
    for chunk in 0..(n / 500) {
        a.apply(
            T0 + 10 + chunk * DAY,
            (0..500)
                .map(|i| {
                    let k = chunk * 500 + i;
                    review(&format!("b{k}"), &format!("C{}", k % 97), T0 + 10 + chunk * DAY + i, 1 + (k % 4), "review")
                })
                .collect(),
        );
    }
    let digest = a.digest();
    let before = all_payloads(&a);
    let logs = count(&a, "SELECT COUNT(*) FROM sync2_ops WHERE kind = 3");
    assert!(logs >= n, "{logs} log ops");
    {
        let w = a.core.writer().unwrap();
        inline_snapshots(&w);
        let tx = w.unchecked_transaction().unwrap();
        let (pages, widest) = super::snapshots::migrate_paged(&tx, 64).unwrap();
        tx.commit().unwrap();
        assert!(widest <= 64, "a page held {widest} rows");
        assert!(pages as i64 >= logs / 64, "{pages} pages for {logs} log ops");
    }
    assert_eq!(count(&a, "SELECT COUNT(*) FROM sync2_ops WHERE kind = 3 AND sc IS NULL"), 0);
    assert_eq!(count(&a, "SELECT COUNT(*) FROM sync2_snapshots"), 1);
    assert_eq!(all_payloads(&a), before, "op payloads read back byte for byte");
    assert_eq!(a.digest(), digest);
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
        let ops: Vec<(Vec<u8>, i64, Vec<u8>, Option<String>, Option<i64>, i64)> = w
            .prepare("SELECT device, seq, payload, sc, sc_at, pz FROM sync2_ops")
            .unwrap()
            .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?, r.get(5)?)))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        for (dv, s, p, sc, at, pz) in ops {
            let p = super::snapshots::unpack_payload(&w, p, sc, at, pz).unwrap();
            w.execute(
                "UPDATE sync2_ops SET payload = ?3, sc = NULL, sc_at = NULL, pz = 0 WHERE device = ?1 AND seq = ?2",
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
        let ops: Vec<(Vec<u8>, i64, Vec<u8>, Option<String>, Option<i64>, i64)> = w
            .prepare("SELECT device, seq, payload, sc, sc_at, pz FROM sync2_ops")
            .unwrap()
            .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?, r.get(5)?)))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        for (dv, s, p, sc, at, pz) in ops {
            let p = super::snapshots::unpack_payload(&w, p, sc, at, pz).unwrap();
            w.execute("UPDATE sync2_ops SET payload = ?3, sc = NULL, sc_at = NULL, pz = 0 WHERE device = ?1 AND seq = ?2", rusqlite::params![dv, s, p])
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

/// 从 v16 之前的版本直接升上来：v10 起的步骤就在读操作（寄存器重建），那时 `sync2_ops` 还没有 v16 的快照引用两列
/// ——读操作的代码要它们，升级阶梯得先补上（真实大库 v9 → v16 曾在这里失败）。升级后打开时整理了文件（空闲页清零）。
#[test]
fn upgrading_from_before_v16_adds_the_snapshot_columns_before_reading_ops() {
    let a = busy_device("fp-old");
    let before = super::tests::projection(&a);
    let digest = a.digest();
    let path = a._dir.0.join("srs.db");
    rusqlite::Connection::open(&path)
        .unwrap()
        .execute_batch("ALTER TABLE sync2_ops DROP COLUMN sc; ALTER TABLE sync2_ops DROP COLUMN sc_at; UPDATE srs_meta SET value = '9' WHERE key = 'schema';")
        .unwrap();
    let b = Device { core: SrsCore::open(&path).unwrap(), _dir: super::tests::tempdir::new("fp-old-unused") };
    assert_eq!(super::tests::projection(&b), before);
    assert_eq!(b.digest(), digest);
    assert_eq!(count(&b, "SELECT COUNT(*) FROM srs_meta WHERE key = 'compact_pending'"), 0, "compacted on open");
    assert_eq!(count(&b, "PRAGMA freelist_count"), 0);
}

/// 升级前空间不够：开事务之前就报 [crate::store::schema::UPGRADE_NO_SPACE]（带需要 / 可用字节），库一个字节不动
/// （版本号、投影、摘要都还是升级前的）；空间够了再打开照常升级。
#[test]
fn upgrade_refuses_to_start_without_disk_space() {
    let a = busy_device("fp-nospace");
    let before = super::tests::projection(&a);
    let digest = a.digest();
    let path = a._dir.0.join("srs.db");
    rusqlite::Connection::open(&path).unwrap().execute_batch("UPDATE srs_meta SET value = '15' WHERE key = 'schema';").unwrap();
    let bytes = std::fs::read(&path).unwrap();
    let err = match SrsCore::open_with_free_space(&path, |_| Some(1024)) {
        Err(e) => e,
        Ok(_) => panic!("upgrade started without disk space"),
    };
    assert!(err.starts_with(crate::store::schema::UPGRADE_NO_SPACE), "{err}");
    let detail: Value = serde_json::from_str(&err[crate::store::schema::UPGRADE_NO_SPACE.len()..]).unwrap();
    assert_eq!(detail["free"], json!(1024));
    assert!(detail["need"].as_u64().unwrap() > 1024);
    assert_eq!(detail["from"], json!(15));
    assert_eq!(std::fs::read(&path).unwrap(), bytes, "main file untouched");
    assert_eq!(count(&a, "SELECT value FROM srs_meta WHERE key = 'schema'"), 15);
    // 不用升级的库（已是当前版本）不受空间守卫影响。
    rusqlite::Connection::open(&path)
        .unwrap()
        .execute_batch(&format!("UPDATE srs_meta SET value = '{}' WHERE key = 'schema';", crate::store::schema::SCHEMA_VERSION))
        .unwrap();
    drop(SrsCore::open_with_free_space(&path, |_| Some(1024)).unwrap());
    rusqlite::Connection::open(&path).unwrap().execute_batch("UPDATE srs_meta SET value = '15' WHERE key = 'schema';").unwrap();
    let b = Device { core: SrsCore::open_with_free_space(&path, |_| Some(u64::MAX)).unwrap(), _dir: super::tests::tempdir::new("fp-nospace-unused") };
    assert_eq!(count(&b, "SELECT value FROM srs_meta WHERE key = 'schema'"), crate::store::schema::SCHEMA_VERSION);
    assert_eq!(super::tests::projection(&b), before);
    assert_eq!(b.digest(), digest);
}

/// 空间不够就不整理：记下原因、标记留着、库照常可用；空间够了下次打开再整理。
#[test]
fn compaction_waits_for_disk_space() {
    let a = busy_device("fp-disk");
    let w = a.core.writer().unwrap();
    w.execute_batch("INSERT INTO srs_meta (key, value) VALUES ('compact_pending', '16');").unwrap();
    assert!(!crate::store::compact::run(&w, &a._dir.0, Some(1024), 7));
    let last: String = w.query_row("SELECT value FROM srs_meta WHERE key = 'compact_last'", [], |r| r.get(0)).unwrap();
    assert!(last.contains("\"reason\":\"disk\""), "{last}");
    assert!(w.query_row("SELECT 1 FROM srs_meta WHERE key = 'compact_pending'", [], |_| Ok(())).is_ok());
    assert!(crate::store::compact::run(&w, &a._dir.0, Some(u64::MAX), 8));
    assert!(w.query_row("SELECT 1 FROM srs_meta WHERE key = 'compact_pending'", [], |_| Ok(())).is_err());
    assert!(crate::store::compact::free_bytes(&a._dir.0.join("srs.db")).is_some_and(|f| f > 0));
}

/// v20 → v21 升级：v20 的 `sync2_ops` 没有 `pz` 列、载荷全是原样。重新打开后补上 `pz`、已有行一律 `pz = 0`
/// 不重写；投影、摘要、逐条载荷（[super::load_op]）、时间线（恢复预览 / 实体历史）都与升级前相同。之后新写的
/// 操作才压（`pz = 1`），原样与压缩混存的日志照样完整同步给第三台新设备。
#[test]
fn v21_upgrade_adds_pz_and_reads_the_old_raw_rows_unchanged() {
    use super::timeline::RestoreTarget;
    let a = busy_device("fp-v20");
    let before = super::tests::projection(&a);
    let digest = a.digest();
    let payloads = all_payloads(&a);
    let restore = |d: &Device| d.core.sync2_plan_restore(P, &RestoreTarget::At(T0 + 5 * DAY), true, T0 + 20 * DAY).unwrap();
    let history = |d: &Device| d.core.sync2_history(P, "note", "N1").unwrap();
    let preview = restore(&a);
    let hist = history(&a);
    // 退回 v20 的存储形态：压缩过的行解回原样，删掉 `pz` 列，标 20。
    {
        let w = a.core.writer().unwrap();
        let zipped: Vec<(Vec<u8>, i64, Vec<u8>)> = w
            .prepare("SELECT device, seq, payload FROM sync2_ops WHERE pz = 1")
            .unwrap()
            .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        for (dv, s, p) in zipped {
            let n = u32::from_le_bytes(p[..4].try_into().unwrap()) as usize;
            let raw = zstd::bulk::decompress(&p[4..], n).unwrap();
            w.execute("UPDATE sync2_ops SET payload = ?3, pz = 0 WHERE device = ?1 AND seq = ?2", rusqlite::params![dv, s, raw]).unwrap();
        }
        w.execute_batch("ALTER TABLE sync2_ops DROP COLUMN pz; UPDATE srs_meta SET value = '20' WHERE key = 'schema';").unwrap();
    }
    let path = a._dir.0.join("srs.db");
    let dir = a._dir;
    drop(a.core);
    {
        let c = rusqlite::Connection::open(&path).unwrap();
        let n: i64 = c.query_row("SELECT COUNT(*) FROM pragma_table_info('sync2_ops') WHERE name = 'pz'", [], |r| r.get(0)).unwrap();
        assert_eq!(n, 0, "the v20 form has no pz column");
    }
    let b = Device { core: SrsCore::open(&path).unwrap(), _dir: dir };
    assert_eq!(count(&b, "SELECT value FROM srs_meta WHERE key = 'schema'"), crate::store::schema::SCHEMA_VERSION);
    assert_eq!(count(&b, "SELECT COUNT(*) FROM pragma_table_info('sync2_ops') WHERE name = 'pz'"), 1, "pz column added");
    assert_eq!(count(&b, "SELECT COUNT(*) FROM sync2_ops WHERE pz != 0"), 0, "existing rows stay raw (not rewritten)");
    assert_eq!(super::tests::projection(&b), before);
    assert_eq!(b.digest(), digest);
    assert_eq!(all_payloads(&b), payloads, "old raw rows read back byte for byte");
    assert_eq!(restore(&b), preview, "timeline restore preview reads the old rows");
    assert_eq!(history(&b), hist, "entity history reads the old rows");

    // 之后写的操作才压：日志里原样与压缩混存。
    let deck = super::config::default_deck_id(P);
    for i in 0..30 {
        let at = T0 + 30 * DAY + i * DAY;
        b.apply(at, vec![review(&format!("n{i}"), &format!("C{}", i % 3), at, 1 + i % 4, "review")]);
        b.apply(at + 1, vec![edit("note", "N1", &format!("f/n{i}"), json!(format!("field value {i} {}", "x".repeat(200))))]);
    }
    b.apply(T0 + 70 * DAY, vec![edit("deck", &deck, "retention", json!(0.9))]);
    let raw_rows = count(&b, "SELECT COUNT(*) FROM sync2_ops WHERE pz = 0");
    let zipped_rows = count(&b, "SELECT COUNT(*) FROM sync2_ops WHERE pz = 1");
    assert!(raw_rows >= payloads.len() as i64, "{raw_rows} raw rows");
    assert!(zipped_rows > 0, "new ops are compressed");
    // 混存的日志完整同步给第三台新设备。
    let mut bucket = Bucket::default();
    b.sync(&mut bucket, "loc", T0 + 71 * DAY);
    let c = Device::new("fp-v21-c");
    c.sync(&mut bucket, "loc", T0 + 71 * DAY);
    assert_eq!(super::tests::projection(&c), super::tests::projection(&b));
    assert_eq!(c.digest(), b.digest());
    assert_eq!(all_payloads(&c), all_payloads(&b), "every op (raw and compressed) reached the new device intact");
    assert_eq!(history(&c), history(&b));
}
