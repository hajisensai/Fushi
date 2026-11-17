//! 实体归属闸（`writes_owner.rs`，BUG-4836）：经 C ABI 在一个库里开两个 profile（两个集合）。并入场景的端到端在 Dart
//! `packages/fushi_engine/test/srs/srs_profile_ownership_merge_test.dart`。

use std::path::Path;

use rusqlite::{Connection, OpenFlags};
use serde_json::{Value, json};

use super::{OURS_SQL, THEIRS_SQL};
use crate::store::ffi::{SrsCoreHandle, ffsrs_store_close};
use crate::store::gen4::cmd::dispatch_tests::{T1, call, g4req, open};
use crate::store::gen4::cmd::tests::{N1, N2, N3, N4};
use crate::store::gen4::files::GEN4_FILE;
use crate::store::gen4::schema::{k_range, open_in_memory};
use crate::store::sync2::config::default_deck_id;
use crate::store::sync2::tests::tempdir;

/// 本库里的另一个 profile（集合 B）。
const B: &str = "0193a1b2-0000-7000-8000-00000000b0b0";
/// 调用方（集合 A）。
const A: &str = "0193a1b2-0000-7000-8000-00000000a0a0";

fn req(profile: &str, op: &str, extra: Value) -> Value {
    let mut r = g4req(op, T1, extra);
    r["profile"] = json!(profile);
    r
}

fn run(h: *mut SrsCoreHandle, profile: &str, op: &str, extra: Value, items: &[Value]) -> Value {
    let r = req(profile, op, extra);
    let items = (!items.is_empty()).then_some(items);
    call(h, &r, items)
        .unwrap_or_else(|(rc, e)| panic!("{op}: {rc} {e}"))
        .0
}

fn ready(h: *mut SrsCoreHandle, profile: &str) {
    run(h, profile, "identity", json!({}), &[]);
    let caches = json!({"defaultDeck": default_deck_id(profile)});
    run(
        h,
        profile,
        "cache_config_set",
        json!({"caches": caches}),
        &[],
    );
}

fn note(profile: &str, id: &str) -> Value {
    json!({"e": {"t": "entity", "x": {"id": id, "p": profile, "k": "note", "d": {"createdAt": 1, "guid": id, "noteTypeId": N4}}}})
}

fn field(profile: &str, id: &str, v: Value) -> Value {
    json!({"e": {"t": "edit", "x": {"id": "ignored", "p": profile, "k": "note", "e": id, "f": "f/fa", "w": "dart", "s": 1, "ctx": {"vv": {}}, "v": v, "hlc": "0:0:dart", "ts": "anchored"}}, "note": id})
}

fn tags(profile: &str, id: &str, v: Value) -> Value {
    let mut f = field(profile, id, v);
    f["e"]["x"]["f"] = json!("tags");
    f
}

/// [profile] 的集合里一共几条操作（全部设备的主键区间）。
fn ops_of(dir: &Path, profile: &str) -> i64 {
    let c =
        Connection::open_with_flags(dir.join(GEN4_FILE), OpenFlags::SQLITE_OPEN_READ_ONLY).unwrap();
    let devs: Vec<i64> = c
        .prepare(
            "SELECT d.dev FROM devs d JOIN collections c ON c.col = d.col WHERE c.profile_uid = ?1",
        )
        .unwrap()
        .query_map([profile], |r| r.get(0))
        .unwrap()
        .map(Result::unwrap)
        .collect();
    devs.iter()
        .map(|&d| {
            let (lo, hi) = k_range(d);
            c.query_row(
                "SELECT COUNT(*) FROM ops WHERE k BETWEEN ?1 AND ?2",
                [lo, hi],
                |r| r.get::<_, i64>(0),
            )
            .unwrap()
        })
        .sum()
}

/// A 拿 B 的实体 ID 写字段、整列表标签、清除：一条都不写进 A 的日志，回包 `foreign` 交回下标、`landed` 为 false。
/// 合法的「同一个 ID 两边都有」（不加盐的 ID，两个集合各自导入了同一份内容，同批先写修改、后建实体）与「哪里都没有的
/// ID」（同批先后到、给还没生成的卡写血统）照常写。
#[test]
fn another_collections_entities_are_not_written() {
    let dir = tempdir::new("g9-owner");
    let h = open(&dir.0, 0).unwrap();
    ready(h, B);
    ready(h, A);
    let v = run(
        h,
        B,
        "apply",
        json!({}),
        &[note(B, N1), field(B, N1, json!("鳥")), note(B, N2)],
    );
    assert_eq!(v["landed"], json!([true, true, true]), "{v}");

    let before = ops_of(&dir.0, A);
    let v = run(
        h,
        A,
        "apply",
        json!({}),
        &[field(A, N1, json!("被 A 改")), tags(A, N1, json!(["串了"]))],
    );
    assert_eq!(v["landed"], json!([false, false]), "{v}");
    assert_eq!(v["foreign"], json!([0, 1]), "{v}");
    let v = run(
        h,
        A,
        "purge",
        json!({"kind": "note", "entities": [N1]}),
        &[],
    );
    assert_eq!(v["foreign"], json!([0]), "{v}");
    assert_eq!(
        ops_of(&dir.0, A),
        before,
        "A 的日志里没有指向 B 的实体的操作"
    );

    // 两边都有的 ID：A 在同一批里先写修改、后建实体——是 A 自己的。
    let v = run(
        h,
        A,
        "apply",
        json!({}),
        &[field(A, N2, json!("川")), note(A, N2)],
    );
    assert_eq!(v["landed"], json!([true, true]), "{v}");
    assert_eq!(v["foreign"], json!([]), "{v}");
    // A 已经有了这条笔记：之后单独改它照常写。
    let v = run(h, A, "apply", json!({}), &[field(A, N2, json!("山"))]);
    assert_eq!(v["landed"], json!([true]), "{v}");
    // 哪里都没有的 ID：照常写（悬空，但不是别人的）。
    let v = run(h, A, "apply", json!({}), &[field(A, N3, json!("海"))]);
    assert_eq!(v["landed"], json!([true]), "{v}");
    assert_eq!(v["foreign"], json!([]), "{v}");
    // B 自己写自己的照常。
    let v = run(h, B, "apply", json!({}), &[field(B, N1, json!("鶏"))]);
    assert_eq!(v["landed"], json!([true]), "{v}");
    ffsrs_store_close(h);
}

/// 库里只有一个集合：不查别的集合（一条 `collections` 查询就放行），悬空写照常。
#[test]
fn a_single_collection_library_writes_dangling_ops_as_before() {
    let dir = tempdir::new("g9-owner-single");
    let h = open(&dir.0, 0).unwrap();
    ready(h, A);
    let v = run(h, A, "apply", json!({}), &[field(A, N1, json!("鳥"))]);
    assert_eq!(v["landed"], json!([true]), "{v}");
    assert_eq!(v["foreign"], json!([]), "{v}");
    ffsrs_store_close(h);
}

/// [THEIRS_SQL] / [OURS_SQL] 都走索引（前者靠 SCHEMA 40023 的 `ent_id` / `alias_canon_any` / `cards_id`）。
/// `OTHERS_SQL` 不在这里：`collections` 一个 profile 一行，整表就几行。
#[test]
fn owner_statements_use_an_index() {
    let c = open_in_memory().unwrap();
    for q in [THEIRS_SQL, OURS_SQL] {
        let mut stmt = c.prepare(&format!("EXPLAIN QUERY PLAN {q}")).unwrap();
        let mut rows = stmt.raw_query();
        let mut plan = Vec::new();
        while let Some(r) = rows.next().unwrap() {
            plan.push(r.get::<_, String>(3).unwrap());
        }
        assert!(!plan.is_empty(), "{q}");
        assert!(
            plan.iter()
                .all(|l| !l.starts_with("SCAN") || l == "SCAN CONSTANT ROW"),
            "{q}: {plan:?}"
        );
    }
}
