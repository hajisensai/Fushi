//! 实体归属闸（`writes_owner.rs`，BUG-4907）：经 C ABI 在一个库里开两个 profile（两个集合）。并入场景的端到端在 Dart
//! `packages/fushi_engine/test/srs/srs_profile_ownership_merge_test.dart`。

use std::path::Path;

use rusqlite::{Connection, OpenFlags};
use serde_json::{Value, json};

use super::{OURS_SQL, THEIRS_SQL};
use crate::gen4_ids::rules;
use crate::store::ffi::{SrsCoreHandle, ffsrs_store_close};
use crate::store::gen4::cmd::dispatch_tests::{T1, call, g4req, migrated, open};
use crate::store::gen4::cmd::tests::{N1, N3, N4, card};
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
    note_with(profile, id, id)
}

fn note_with(profile: &str, id: &str, guid: &str) -> Value {
    json!({"e": {"t": "entity", "x": {"id": id, "p": profile, "k": "note", "d": {"createdAt": 1, "guid": guid, "noteTypeId": N4}}}})
}

/// 由内容（guid）按规范规则派生的笔记 ID（导入 / 挖词历史这类 guid 来自内容的笔记）。
fn derived(guid: &str) -> String {
    rules::note(rules::CANONICAL, guid).text()
}

fn profile_edit(profile: &str, entity: &str, v: Value) -> Value {
    json!({"e": {"t": "edit", "x": {"id": "ignored", "p": profile, "k": "profile", "e": entity, "f": "dayRolloverHour", "w": "dart", "s": 1, "ctx": {"vv": {}}, "v": v, "hlc": "0:0:dart", "ts": "anchored"}}, "note": null})
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
    let shared = derived("shared-guid");
    let v = run(
        h,
        B,
        "apply",
        json!({}),
        &[
            note(B, N1),
            field(B, N1, json!("鳥")),
            note_with(B, &shared, "shared-guid"),
        ],
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

    // 两边都有的 ID（由内容派生：两个集合各自导入了同一份内容）：A 在同一批里先写修改、后建实体——是 A 自己的。
    let v = run(
        h,
        A,
        "apply",
        json!({}),
        &[
            field(A, &shared, json!("川")),
            note_with(A, &shared, "shared-guid"),
        ],
    );
    assert_eq!(v["landed"], json!([true, true]), "{v}");
    assert_eq!(v["foreign"], json!([]), "{v}");
    // A 已经有了这条笔记：之后单独改它照常写。
    let v = run(h, A, "apply", json!({}), &[field(A, &shared, json!("山"))]);
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

/// 身份记录也过闸（复核实测：以前 A 写一条 B 的笔记的身份记录就落了，并入后按「规范 JSON 最小者胜」换掉 B 的笔记类型与
/// guid）：ID 不由自己内容派生的、别的集合有的笔记身份记录不写，同批对它的修改也不再借它作保。由内容派生的照常写。
#[test]
fn another_collections_identity_records_are_not_written() {
    let dir = tempdir::new("g9-owner-ent");
    let h = open(&dir.0, 0).unwrap();
    ready(h, B);
    ready(h, A);
    run(
        h,
        B,
        "apply",
        json!({}),
        &[note(B, N1), field(B, N1, json!("鳥"))],
    );

    let before = ops_of(&dir.0, A);
    // 伪造的记录（guid 对不上 ID）、单发：不写。
    let v = run(h, A, "apply", json!({}), &[note_with(A, N1, "stolen")]);
    assert_eq!(v["landed"], json!([false]), "{v}");
    assert_eq!(v["foreign"], json!([0]), "{v}");
    // 身份记录 + 同批修改 + 标签：一项都不写（身份记录没过闸，不进同批要建的实体）。
    let v = run(
        h,
        A,
        "apply",
        json!({}),
        &[
            note(A, N1),
            field(A, N1, json!("被 A 改")),
            tags(A, N1, json!(["串了"])),
        ],
    );
    assert_eq!(v["landed"], json!([false, false, false]), "{v}");
    assert_eq!(v["foreign"], json!([0, 1, 2]), "{v}");
    // 导入路径同一个闸。
    let v = run(
        h,
        A,
        "import_drafts",
        json!({}),
        &[note_with(A, N1, "stolen")],
    );
    assert_eq!(v["foreign"], json!([0]), "{v}");
    assert_eq!(
        ops_of(&dir.0, A),
        before,
        "A 的日志里没有 B 的笔记的身份记录"
    );

    // 哪里都没有的随机 ID 照常建。
    let v = run(h, A, "apply", json!({}), &[note(A, N3)]);
    assert_eq!(v["landed"], json!([true]), "{v}");
    assert_eq!(v["foreign"], json!([]), "{v}");
    ffsrs_store_close(h);
}

/// profile 设置实体（没有 `ent_ix` 痕迹）：A 拿 B 的 uid 改设置不写；A 自己的 uid、规范的 profile 设置实体、哪里都没有的
/// uid 照常写。
#[test]
fn another_collections_profile_settings_are_not_written() {
    let dir = tempdir::new("g9-owner-prof");
    let h = open(&dir.0, 0).unwrap();
    ready(h, B);
    ready(h, A);
    run(h, B, "apply", json!({}), &[profile_edit(B, B, json!(5))]);

    let before = ops_of(&dir.0, A);
    let v = run(h, A, "apply", json!({}), &[profile_edit(A, B, json!(9))]);
    assert_eq!(v["landed"], json!([false]), "{v}");
    assert_eq!(v["foreign"], json!([0]), "{v}");
    assert_eq!(ops_of(&dir.0, A), before, "A 的日志里没有 B 的设置");

    let canonical = rules::profile_entity().text();
    let nowhere = "0193a1b2-0000-7000-8000-00000000dead";
    let v = run(
        h,
        A,
        "apply",
        json!({}),
        &[
            profile_edit(A, A, json!(6)),
            profile_edit(A, &canonical, json!(7)),
            profile_edit(A, nowhere, json!(8)),
        ],
    );
    assert_eq!(v["foreign"], json!([]), "{v}");
    assert_eq!(v["landed"], json!([true, true, true]), "{v}");
    ffsrs_store_close(h);
}

/// `sched`（重置 / 改期 / 撤销）对别的集合的卡：按「没有这张卡」跳过，A 的日志不增、撤销计入 `blocked`。对照：同样的
/// 动作对一张哪里都没有的卡在 A 里照写（A 这边看两张卡一样陌生，差别只在闸）。
#[test]
fn sched_skips_another_collections_cards() {
    let m = migrated();
    ready(m.h, A);
    let theirs = card(N1, "t1");
    let nowhere = card(N3, "nowhere");
    let sched = |items: Value| -> Value {
        let extra = json!({"at": T1, "utcOff": 0, "rollover": 4, "ts": "anchored", "items": items});
        run(m.h, A, "sched", extra, &[])
    };
    let before = ops_of(&m.dir.0, A);
    let v = sched(json!([
            {"a": "reset", "card": theirs},
            {"a": "setDue", "card": theirs, "due": 19_800},
            {"a": "undo", "card": theirs, "log": "r2"},
    ]));
    assert_eq!(v["logs"], json!([]), "{v}");
    assert_eq!(v["blocked"], json!(1), "{v}");
    assert_eq!(ops_of(&m.dir.0, A), before, "A 的日志里没有 B 的卡的排程");

    let v = sched(json!([{"a": "setDue", "card": nowhere, "due": 19_800}]));
    assert_eq!(v["logs"].as_array().map(Vec::len), Some(1), "{v}");
    assert!(ops_of(&m.dir.0, A) > before, "对照：陌生的卡照写");
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

/// `import_drafts` 先筛掉「键上已有活着的修改」的初值项再过闸：被拒的项在回包 `foreign` 里按**筛掉之前**的调用方
/// 输入下标报（Dart 导入路径按它认出被拒的笔记、记进导入报告，BUG-4907 复核：以前报的是筛掉之后的位置，对不上草稿）。
/// 被拒的这一条是合法导入撞上的：B 已有同一个 guid 的笔记（不同笔记类型），A 导入同一个 guid 却落到另一个笔记类型
/// （`.apkg` 不合并笔记模板时的副本、文本导入用户选的类型）。
#[test]
fn import_drafts_reports_foreign_at_the_callers_input_index() {
    let dir = tempdir::new("g9-owner-import-drafts");
    let h = open(&dir.0, 0).unwrap();
    ready(h, B);
    ready(h, A);
    let shared = derived("shared-guid");
    let v = run(
        h,
        B,
        "apply",
        json!({}),
        &[note_with(B, &shared, "shared-guid")],
    );
    assert_eq!(v["foreign"], json!([]), "{v}");
    let own = derived("a-guid");
    let v = run(
        h,
        A,
        "apply",
        json!({}),
        &[note_with(A, &own, "a-guid"), field(A, &own, json!("a"))],
    );
    assert_eq!(v["foreign"], json!([]), "{v}");
    let mut init = field(A, &own, json!("初值"));
    init["init"] = json!(true);
    let mut other_type = note_with(A, &shared, "shared-guid");
    other_type["e"]["x"]["d"]["noteTypeId"] =
        json!(rules::note_type(rules::CANONICAL, 424_242).text());
    let before = ops_of(&dir.0, A);
    let v = run(h, A, "import_drafts", json!({}), &[init, other_type]);
    assert_eq!(v["foreign"], json!([1]), "{v}");
    assert_eq!(
        ops_of(&dir.0, A),
        before,
        "初值项筛掉、身份记录被拒：A 一条不写"
    );
    ffsrs_store_close(h);
}

/// 卡片修改 [key] = [v]，带 / 不带它的笔记（输入项的 `note`）。
fn card_edit(profile: &str, card: &str, note: Option<&str>, key: &str, v: Value) -> Value {
    json!({"e": {"t": "edit", "x": {"id": "ignored", "p": profile, "k": "card", "e": card, "f": key, "w": "dart", "s": 1, "ctx": {"vv": {}}, "v": v, "hlc": "0:0:dart", "ts": "anchored"}}, "note": note})
}

/// 带笔记的卡片修改跟着笔记过闸（第六波 BUG-4907 复核）：同批身份记录被拒的那条笔记（同 guid、B 已有、A 落到另一个
/// 笔记类型），它的卡片修改——卡 ID 由 A 的副本类型派生、哪里都没有——一并不写，回包 `foreign` 报它们的下标。合法场景
/// 照常：笔记是同批要建的、是本集合已有的、哪里都没有的，或修改不带笔记（「哪里都没有的 ID 照常写」不变）。`apply` 同一个闸。
#[test]
fn card_edits_carrying_a_rejected_note_are_not_written() {
    let dir = tempdir::new("g9-owner-card-note");
    let h = open(&dir.0, 0).unwrap();
    ready(h, B);
    ready(h, A);
    let shared = derived("shared-guid");
    run(
        h,
        B,
        "apply",
        json!({}),
        &[note_with(B, &shared, "shared-guid")],
    );
    let own = derived("a-own");
    let v = run(h, A, "apply", json!({}), &[note_with(A, &own, "a-own")]);
    assert_eq!(v["foreign"], json!([]), "{v}");

    let mut other_type = note_with(A, &shared, "shared-guid");
    other_type["e"]["x"]["d"]["noteTypeId"] =
        json!(rules::note_type(rules::CANONICAL, 424_242).text());
    let dup_card = card(&shared, "dup-tmpl");
    let fresh = derived("a-fresh");
    let before = ops_of(&dir.0, A);
    let v = run(
        h,
        A,
        "import_drafts",
        json!({}),
        &[
            other_type,
            card_edit(A, &dup_card, Some(&shared), "newPos", json!(7)),
            card_edit(A, &dup_card, Some(&shared), "suspended", json!(true)),
            // 合法：同批要建的笔记的卡。
            note_with(A, &fresh, "a-fresh"),
            card_edit(A, &card(&fresh, "t"), Some(&fresh), "newPos", json!(8)),
            // 合法：本集合已有的笔记的卡；哪里都没有的笔记的卡；不带笔记的、哪里都没有的卡。
            card_edit(A, &card(&own, "t"), Some(&own), "newPos", json!(9)),
            card_edit(A, &card(N3, "t"), Some(N3), "newPos", json!(10)),
            card_edit(A, &card(N4, "t"), None, "newPos", json!(11)),
        ],
    );
    assert_eq!(v["foreign"], json!([0, 1, 2]), "{v}");
    assert_eq!(
        ops_of(&dir.0, A) - before,
        5,
        "被拒笔记与它的两条卡片修改一条不写，合法的五条照写"
    );
    // `apply` 同一个闸：单发一条带被拒笔记的卡片修改，不写；同一张卡不带笔记照旧写（只加严、不改不带笔记的口径）。
    let v = run(
        h,
        A,
        "apply",
        json!({}),
        &[
            card_edit(A, &dup_card, Some(&shared), "newPos", json!(12)),
            card_edit(A, &dup_card, None, "newPos", json!(13)),
        ],
    );
    assert_eq!(v["landed"], json!([false, true]), "{v}");
    assert_eq!(v["foreign"], json!([0]), "{v}");
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

#[path = "writes_owner_merge_tests.rs"]
mod merge;
