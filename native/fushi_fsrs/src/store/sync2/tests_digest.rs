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
