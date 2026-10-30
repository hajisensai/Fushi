//! 审查 S-7：摘要按卡 ID 分桶、由触发器随写入增量维护。对拍「增量 = 全量扫描」，并验证能定位到不一致的桶。

use serde_json::{json, Value};

use super::digest;
use super::tests::{deck_entity, edit, review, Bucket, Device, P};

const T0: i64 = 1_700_000_000_000;
const DAY: i64 = 86_400_000;

fn incremental(d: &Device) -> String {
    digest::root(&d.core.reader().unwrap(), P).unwrap()
}

fn scanned(d: &Device) -> String {
    digest::root_by_scan(&d.core.reader().unwrap(), P).unwrap()
}

fn buckets(d: &Device) -> Vec<(i64, String)> {
    let v = d.core.sync2_digest_buckets(P).unwrap();
    v["buckets"].as_array().unwrap().iter().map(|b| (b[0].as_i64().unwrap(), b[1].as_str().unwrap().to_owned())).collect()
}

/// 写入 / 收取 / 重放 / 改字段 / 清除之后，桶表维护出的根始终等于从三张投影表从头算的根；两台设备收齐后根相同。
#[test]
fn incremental_digest_matches_a_full_scan_through_apply_ingest_replay_and_purge() {
    let deck = super::config::default_deck_id(P);
    let a = Device::new("dg-a");
    let b = Device::new("dg-b");
    let mut home = Bucket::default();
    a.apply(T0, vec![deck_entity(&deck), edit("note", "N1", "f/x", json!("x")), edit("note", "N2", "f/x", json!("y"))]);
    assert_eq!(incremental(&a), scanned(&a));
    a.apply(T0 + 10, vec![review("a1", "C1", T0 + 10, 3, "learn"), review("a2", "C2", T0 + 20, 1, "learn")]);
    a.sync(&mut home, "loc", T0 + 10);
    b.sync(&mut home, "loc", T0 + 10);
    // 交错的复习：收取时要插进中间并重放，触发器得跟上每一次 res 改写。
    b.apply(T0 + 15, vec![review("b1", "C1", T0 + 15, 2, "learn"), edit("note", "N1", "f/x", json!("x2"))]);
    a.apply(T0 + DAY, vec![review("a3", "C1", T0 + DAY, 3, "review")]);
    for now in [T0 + DAY + 1, T0 + DAY + 2] {
        a.sync(&mut home, "loc", now);
        b.sync(&mut home, "loc", now);
    }
    a.core.sync2_purge(P, "note", "N2", T0 + DAY + 3).unwrap();
    for now in [T0 + DAY + 4, T0 + DAY + 5] {
        a.sync(&mut home, "loc", now);
        b.sync(&mut home, "loc", now);
    }
    for d in [&a, &b] {
        assert_eq!(incremental(d), scanned(d), "incremental root drifted from the scan");
    }
    assert_eq!(incremental(&a), incremental(&b), "converged devices share a root");
    assert_eq!(buckets(&a), buckets(&b));
    let st: Value = a.core.sync2_digest(P).unwrap();
    assert_eq!(st["digest"], json!(incremental(&a)));
}

/// 两台设备只在一张卡上不一致：根不同，逐桶对比后恰好一个桶不同，就是那张卡 ID 所在的桶。
#[test]
fn diverged_devices_locate_the_differing_bucket() {
    let a = Device::new("dl-a");
    let b = Device::new("dl-b");
    let mut home = Bucket::default();
    let events: Vec<Value> = (0..200).map(|i| review(&format!("r{i}"), &format!("C{i}"), T0 + i, 3, "learn")).collect();
    a.apply(T0, events);
    a.sync(&mut home, "loc", T0 + 1000);
    b.sync(&mut home, "loc", T0 + 1000);
    assert_eq!(incremental(&a), incremental(&b));
    // 只在 b 本地把一行改坏（模拟静默分歧，不经同步）。
    b.core.writer().unwrap().execute("UPDATE srs_review_logs SET json = json_set(json, '$.rating', 1) WHERE id = 'r77'", []).unwrap();
    assert_ne!(incremental(&a), incremental(&b));
    assert_eq!(incremental(&b), scanned(&b), "the UPDATE trigger kept the bucket current");
    let (ba, bb) = (buckets(&a), buckets(&b));
    let differ: Vec<i64> = ba.iter().zip(bb.iter()).filter(|(x, y)| x != y).map(|(x, _)| x.0).collect();
    assert_eq!(ba.len(), bb.len());
    assert_eq!(differ, vec![digest::bucket_of("r77")]);
}

/// 升级（v12 迁移）从现有三张表全量重建桶表：清空后重建，结果等于扫描；迁移重跑幂等。
#[test]
fn migration_rebuild_reproduces_the_scan_and_is_idempotent() {
    let a = Device::new("dm-a");
    a.apply(T0, vec![edit("note", "N1", "f/x", json!("x")), review("r1", "C1", T0, 3, "learn")]);
    let before = incremental(&a);
    {
        let w = a.core.writer().unwrap();
        w.execute("DELETE FROM sync2_digest_buckets", []).unwrap();
        super::schema::migrate_v12(&w).unwrap();
        super::schema::migrate_v12(&w).unwrap();
    }
    assert_eq!(incremental(&a), before);
    assert_eq!(incremental(&a), scanned(&a));
}

/// 旧格式（`<hex>@<vvhex>`，旧设备写的）与新格式（`<hex>@2:<vvhex>`）的版本向量对不上 → 不比摘要，不误报不一致。
#[test]
fn digest_vv_tag_is_versioned_so_old_format_digests_are_never_compared() {
    let a = Device::new("dv-a");
    a.apply(T0, vec![review("r1", "C1", T0, 3, "learn")]);
    let st: Value = a.core.sync2_digest(P).unwrap();
    let stored = &a.rows(&format!("SELECT value FROM srs_meta WHERE key = 'sync2_digest/{P}'"))[1][0];
    let (d, vv) = stored.split_once('@').unwrap();
    assert_eq!(d, st["digest"].as_str().unwrap());
    assert_eq!(vv, format!("{}{}", digest::VV_PREFIX, st["vv"].as_str().unwrap()));
}

/// 三张被摘要的投影表。
const DIGESTED: [&str; 3] = ["srs_entities", "srs_field_edits", "srs_review_logs"];

/// 桶表里的行数和等于三张投影表的实际行数（根对上之外，`n` 也不许漂）。
fn assert_counts_match(d: &Device) {
    let n: i64 = d.rows(&format!("SELECT COALESCE(SUM(n), 0) FROM sync2_digest_buckets WHERE profile_uid = '{P}'"))[1][0].parse().unwrap();
    let mut rows = 0i64;
    for t in DIGESTED {
        rows += d.rows(&format!("SELECT COUNT(*) FROM {t} WHERE profile_uid = '{P}'"))[1][0].parse::<i64>().unwrap();
    }
    assert_eq!(n, rows, "bucket row counts drifted from the tables");
}

/// 集成审查【高】：标签行（`refresh_tags_row`）曾用 REPLACE 改写，REPLACE 删旧行不触发 DELETE 触发器，同一笔记
/// 第二次改标签起桶只加不减。覆盖：本地多次改标签、一批里多次改同一笔记的标签由对端批量收、两边并发改标签。
#[test]
fn repeated_tag_edits_and_batched_ingest_keep_the_incremental_digest_exact() {
    let a = Device::new("dt-a");
    let b = Device::new("dt-b");
    let mut home = Bucket::default();
    let tag = |note: &str, v: Value| edit("note", note, "tags", v);
    a.apply(T0, vec![edit("note", "N1", "f/x", json!("x")), tag("N1", json!(["a"]))]);
    for (i, t) in [json!(["a", "b"]), json!(["b"]), json!(["b", "c", "d"]), json!([])].into_iter().enumerate() {
        a.apply(T0 + 1 + i as i64, vec![tag("N1", t)]);
        assert_eq!(incremental(&a), scanned(&a), "local tag edit #{i}");
        assert_counts_match(&a);
    }
    a.apply(T0 + 10, vec![tag("N2", json!(["p"])), tag("N2", json!(["p", "q"])), tag("N1", json!(["z"])), tag("N2", json!(["q"]))]);
    a.sync(&mut home, "loc", T0 + 20);
    b.sync(&mut home, "loc", T0 + 20);
    assert_eq!(incremental(&b), scanned(&b), "batched ingest of repeated tag edits");
    assert_counts_match(&b);
    a.apply(T0 + 30, vec![tag("N1", json!(["z", "from-a"]))]);
    b.apply(T0 + 31, vec![tag("N1", json!(["z", "from-b"])), tag("N2", json!([]))]);
    for now in [T0 + 40, T0 + 41] {
        a.sync(&mut home, "loc", now);
        b.sync(&mut home, "loc", now);
    }
    for d in [&a, &b] {
        assert_eq!(incremental(d), scanned(d), "incremental root drifted after tag rewrites");
        assert_counts_match(d);
    }
    assert_eq!(incremental(&a), incremental(&b));
    // 运行时这一侧：建表语句里也不许有列 / 表级的 `ON CONFLICT REPLACE`（那会让普通 INSERT 也走隐式删除）。
    for t in DIGESTED {
        // v17 起日志 / 修改记录是视图，存储表另名（projrows.rs）。
        let t = super::projrows::ALL.into_iter().find(|p| p.view == t).map_or(t, |p| p.table);
        let ddl = a.rows(&format!("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = '{t}'"))[1][0].to_uppercase();
        assert!(!ddl.contains("REPLACE"), "{t}: {ddl}");
    }
}

/// 守卫：源码里不许对三张被摘要的投影表写 REPLACE（`INSERT OR REPLACE … INTO` / `REPLACE INTO`）。触发器维护的
/// 桶表只在 INSERT / UPDATE / DELETE 触发器里增减；REPLACE 的隐式删除在没开 recursive_triggers 时（本库不开）不触发
/// DELETE 触发器，桶会静默漂移。改写一律用 `INSERT … ON CONFLICT(id) DO UPDATE`。扫 Rust 内核与 Dart 引擎两侧。
#[test]
fn no_replace_writes_on_digested_tables_anywhere_in_the_sources() {
    let base = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
    let mut stack: Vec<std::path::PathBuf> =
        [base.join("src"), base.join("../../packages/fushi_engine/lib"), base.join("../../packages/fushi_srs/lib")]
            .into_iter()
            .filter(|p| p.exists())
            .collect();
    assert!(stack.iter().any(|p| p.ends_with("src")), "crate sources must be scanned");
    let (mut offenders, mut scanned_files) = (Vec::new(), 0usize);
    while let Some(dir) = stack.pop() {
        for entry in std::fs::read_dir(&dir).unwrap() {
            let path = entry.unwrap().path();
            if path.is_dir() {
                stack.push(path);
                continue;
            }
            if !matches!(path.extension().and_then(|e| e.to_str()), Some("rs" | "dart")) {
                continue;
            }
            scanned_files += 1;
            // 续行反斜杠与字符串拼接的引号去掉、空白压成单空格、统一大写，再找「REPLACE INTO <表>」。
            let text = std::fs::read_to_string(&path).unwrap().replace(['\\', '"', '\''], " ");
            let flat = text.split_whitespace().collect::<Vec<_>>().join(" ").to_uppercase();
            for t in DIGESTED {
                let needle = format!("{} INTO {}", "REPLACE", t.to_uppercase());
                if flat.contains(&needle) {
                    offenders.push(format!("{}: {needle}", path.display()));
                }
            }
        }
    }
    assert!(scanned_files > 50, "scanned only {scanned_files} files");
    assert!(offenders.is_empty(), "REPLACE writes on digested tables: {offenders:?}");
}

/// v14 迁移：桶表被（旧的 REPLACE 写法）弄坏后，`current < 14` 那一步从三张表全量重建，结果等于扫描；重放幂等。
#[test]
fn v14_migration_rebuilds_drifted_buckets_idempotently() {
    let a = Device::new("d14-a");
    a.apply(T0, vec![edit("note", "N1", "tags", json!(["a"])), review("r1", "C1", T0, 3, "learn")]);
    a.apply(T0 + 1, vec![edit("note", "N1", "tags", json!(["a", "b"]))]);
    let good = incremental(&a);
    let mut w = a.core.writer().unwrap();
    // 旧写法留下的漂移：一个桶多记一行、值也对不上。
    w.execute("UPDATE sync2_digest_buckets SET n = n + 1, sum = zeroblob(32) WHERE bucket = (SELECT MIN(bucket) FROM sync2_digest_buckets)", [])
        .unwrap();
    for _ in 0..2 {
        w.execute("UPDATE srs_meta SET value = '13' WHERE key = 'schema'", []).unwrap();
        crate::store::schema::migrate(&mut w).unwrap();
    }
    drop(w);
    assert_eq!(incremental(&a), good);
    assert_eq!(incremental(&a), scanned(&a));
    assert_counts_match(&a);
}
