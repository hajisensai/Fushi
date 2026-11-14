//! 条件写笔记字段的意图命令 `note_fields_if`（note_fields_if.rs）：比对现值与写入在一笔里；落计划按整条笔记拒绝、
//! 撤销逐项拒绝；写出的修改记录与以前 Dart 比对后发的那条 `apply` 相同。

use serde_json::{Value, json};

use super::tests::{Device, P, deck_entity, edit};

const T0: i64 = 1_700_000_000_000;
const NT: &str = "0193a1b2-0000-7000-8000-00000000d0a1";
const N1: &str = "0193a1b2-0000-7000-8000-00000000d0b1";
const N2: &str = "0193a1b2-0000-7000-8000-00000000d0b2";
const N3: &str = "0193a1b2-0000-7000-8000-00000000d0b3";
const GONE: &str = "0193a1b2-0000-7000-8000-00000000d0bf";

fn default_deck() -> String {
    super::config::default_deck_id(P)
}

fn try_dispatch(d: &Device, req: Value, blob: Option<String>) -> Result<Value, String> {
    let mut blobs: Vec<Vec<u8>> = blob.into_iter().map(String::into_bytes).collect();
    let mut files = Vec::new();
    crate::store::ffi::sync2_dispatch(&d.core, &req, &mut blobs, &mut files)
}

fn apply(d: &Device, now: i64, events: Vec<Value>) -> Value {
    let items: Vec<Value> = events
        .into_iter()
        .map(|e| json!({"e": e, "note": null}))
        .collect();
    try_dispatch(
        d,
        json!({
            "op": "apply", "profile": P, "now": now, "caches": {"defaultDeck": default_deck()},
            "legacyDevice": "dev", "tickNow": now,
        }),
        Some(Value::Array(items).to_string()),
    )
    .unwrap()
}

/// 一个两字段的笔记类型；N1（a = "one", b = "x"）、N2（a = "two"）、N3（a = "three"，已删除）。
fn library(tag: &str) -> Device {
    let d = Device::new(tag);
    let mut events = vec![
        deck_entity(&default_deck()),
        json!({"t": "entity", "x": {"id": NT, "p": P, "k": "notetype", "d": {"createdAt": 1, "ntKind": "standard"}}}),
        edit("notetype", NT, "fieldDef/a", json!({"name": "A", "ord": 0})),
        edit("notetype", NT, "fieldDef/b", json!({"name": "B", "ord": 1})),
        edit(
            "notetype",
            NT,
            "tmplDef/t1",
            json!({"name": "t1", "ord": 0, "front": "{{A}}"}),
        ),
    ];
    for (n, a) in [(N1, "one"), (N2, "two"), (N3, "three")] {
        events.push(json!({"t": "entity", "x": {"id": n, "p": P, "k": "note", "d": {"createdAt": 1, "guid": n, "noteTypeId": NT}}}));
        events.push(edit("note", n, "f/a", json!(a)));
    }
    events.push(edit("note", N1, "f/b", json!("x")));
    events.push(edit("note", N3, "deleted", json!(T0)));
    apply(&d, T0, events);
    d
}

fn item(note: &str, field: &str, expect: &str, value: &str) -> Value {
    json!({"n": note, "f": field, "x": expect, "v": value})
}

fn request(mode: &str, at: i64) -> Value {
    json!({
        "op": "note_fields_if", "profile": P, "now": at, "caches": {"defaultDeck": default_deck()},
        "legacyDevice": "dev", "tickNow": at, "ts": "anchored", "mode": mode,
    })
}

fn run(d: &Device, mode: &str, at: i64, items: Vec<Value>) -> Value {
    try_dispatch(d, request(mode, at), Some(Value::Array(items).to_string())).unwrap()
}

fn ops(d: &Device) -> i64 {
    d.rows("SELECT COUNT(*) AS n FROM sync2_ops")[1][0]
        .parse()
        .unwrap()
}

/// 笔记字段现值（笔记缓存没有字段正文：读生效的修改记录）。
fn field(d: &Device, note: &str, key: &str) -> Option<String> {
    d.rows(&format!(
        "SELECT json FROM srs_field_edits WHERE entity_id = srs_id('{note}') AND field_key = '{key}' \
         ORDER BY rowid DESC LIMIT 1"
    ))
    .get(1)
    .map(|r| {
        let j: Value = serde_json::from_str(&r[0]).unwrap();
        j["v"].as_str().unwrap().to_owned()
    })
}

fn local_state(d: &Device) -> Value {
    serde_json::from_str(
        &d.rows(&format!(
            "SELECT json FROM srs_local_state WHERE profile_uid = srs_id('{P}')"
        ))[1][0],
    )
    .unwrap()
}

#[test]
fn a_plan_is_written_per_note_all_or_nothing() {
    let d = library("nfi-note");
    let before = ops(&d);
    let revision = local_state(&d)["revision"].as_i64().unwrap();
    let r = run(
        &d,
        "note",
        T0 + 10,
        vec![
            // N1：两项都对得上 → 都写。
            item(N1, "a", "one", "ONE"),
            item(N1, "b", "x", "X"),
            // N2：第二项对不上（字段 b 现在是空串）→ 整条不写，连对得上的 a 也不写。
            item(N2, "a", "two", "TWO"),
            item(N2, "b", "stale", "B"),
            // 已删除、不存在：拒绝。
            item(N3, "a", "three", "THREE"),
            item(GONE, "a", "", "x"),
        ],
    );
    assert_eq!(r["rejected"], json!([N2, N3, GONE]), "{r}");
    assert_eq!(ops(&d) - before, 2, "two edits of N1");
    assert_eq!(r["marks"]["landed"], json!(2), "{r}");
    assert_eq!(r["localRevision"].as_i64().unwrap() - revision, 2, "{r}");
    assert_eq!(field(&d, N1, "f/a").as_deref(), Some("ONE"));
    assert_eq!(field(&d, N1, "f/b").as_deref(), Some("X"));
    assert_eq!(field(&d, N2, "f/a").as_deref(), Some("two"));
    assert_eq!(field(&d, N3, "f/a").as_deref(), Some("three"));
    // 旧版时钟：两条修改记录各走一步。
    assert_eq!(
        local_state(&d)["hlc"],
        json!(format!("{}:1:dev#1", T0 + 10))
    );
}

#[test]
fn a_revert_is_decided_per_field() {
    let d = library("nfi-field");
    let before = ops(&d);
    let r = run(
        &d,
        "field",
        T0 + 10,
        vec![
            // N1：a 对得上写回，b 之后又被改过（对不上）不动；笔记计入拒绝。
            item(N1, "a", "one", "zero"),
            item(N1, "b", "not-x", "y"),
            item(N2, "a", "two", "zwei"),
            item(N3, "a", "three", "drei"),
        ],
    );
    assert_eq!(r["rejected"], json!([N1, N3]), "{r}");
    assert_eq!(ops(&d) - before, 2);
    assert_eq!(field(&d, N1, "f/a").as_deref(), Some("zero"));
    assert_eq!(field(&d, N1, "f/b").as_deref(), Some("x"));
    assert_eq!(field(&d, N2, "f/a").as_deref(), Some("zwei"));
    assert_eq!(field(&d, N3, "f/a").as_deref(), Some("three"));
}

#[test]
fn a_missing_field_reads_as_empty_and_unchanged_values_are_not_written() {
    let d = library("nfi-noop");
    let before = (ops(&d), local_state(&d));
    // N2 没有字段 b：现值按空串比。写的值与现值相同（a = "two"）不产生记录；b 从没写过，写空串也要落一条。
    let r = run(
        &d,
        "note",
        T0 + 10,
        vec![item(N2, "a", "two", "two"), item(N2, "b", "", "")],
    );
    assert_eq!(r["rejected"], json!([]), "{r}");
    assert_eq!(ops(&d) - before.0, 1);
    assert_eq!(field(&d, N2, "f/b").as_deref(), Some(""));
    // 全部被拒：什么都不写，旧版时钟不动。
    let state = local_state(&d);
    let now = ops(&d);
    let r = run(&d, "note", T0 + 20, vec![item(N2, "a", "nope", "x")]);
    assert_eq!(r["rejected"], json!([N2]), "{r}");
    assert_eq!(ops(&d), now);
    assert_eq!(local_state(&d)["hlc"], state["hlc"]);
    // 没有东西落库：修订号不动（回包照样带库里的当前值）。
    assert_eq!(r["localRevision"], state["revision"], "{r}");
}

#[test]
fn the_edits_match_the_apply_it_replaces() {
    let one = library("nfi-eq-one");
    run(
        &one,
        "note",
        T0 + 10,
        vec![
            item(N1, "a", "one", "ONE"),
            item(N2, "a", "two", "TWO"),
            // 同一字段给了两次：后者为准、位置按首次出现（Dart `editFieldsBatch` 的分组）。
            item(N1, "b", "x", "first"),
            item(N1, "b", "x", "second"),
        ],
    );
    let two = library("nfi-eq-two");
    let draft = |n: &str, key: &str, v: &str| {
        json!({
            "e": {"t": "edit", "x": {"p": P, "k": "note", "e": n, "f": key, "v": v, "ts": "anchored"}},
            "note": null, "clk": "t",
        })
    };
    try_dispatch(
        &two,
        json!({
            "op": "apply", "profile": P, "now": T0 + 10, "caches": {"defaultDeck": default_deck()},
            "legacyDevice": "dev", "tickNow": T0 + 10,
        }),
        Some(
            json!([
                draft(N1, "f/a", "ONE"),
                draft(N1, "f/b", "second"),
                draft(N2, "f/a", "TWO")
            ])
            .to_string(),
        ),
    )
    .unwrap();
    let edits = |d: &Device| {
        d.rows(
            "SELECT srs_idt(entity_id) AS e, json FROM srs_field_edits WHERE entity_kind = 'note' \
             ORDER BY rowid",
        )
        .iter()
        .skip(1)
        .map(|r| {
            let j: Value = serde_json::from_str(&r[1]).unwrap();
            (r[0].clone(), j["f"].clone(), j["v"].clone())
        })
        .collect::<Vec<_>>()
    };
    assert_eq!(edits(&one), edits(&two));
    assert_eq!(local_state(&one)["hlc"], local_state(&two)["hlc"]);
}

#[test]
fn a_failure_after_the_write_rolls_everything_back() {
    let d = library("nfi-fail");
    let before = (ops(&d), local_state(&d));
    let mut req = request("note", T0 + 10);
    req["failAfter"] = json!("apply");
    let err = try_dispatch(
        &d,
        req,
        Some(json!([item(N1, "a", "one", "ONE")]).to_string()),
    )
    .unwrap_err();
    assert!(err.contains("injected failure"), "{err}");
    assert_eq!(ops(&d), before.0);
    assert_eq!(local_state(&d), before.1);
    assert_eq!(field(&d, N1, "f/a").as_deref(), Some("one"));
    assert!(try_dispatch(&d, request("bogus", T0 + 11), Some("[]".to_owned())).is_err());
}
