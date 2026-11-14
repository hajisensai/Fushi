//! 结构性改动的意图命令 `change`（change.rs）：还原点 + 一批修改记录 + 把笔记连同换完类型后的可见卡移到一个牌组，
//! 一条命令、一笔；写出的修改记录与以前的三条命令（`checkpoint`、`apply`、读缓存行后再 `apply`）逐条相同；任何一段
//! 出错整笔回滚。

use std::collections::BTreeMap;

use serde_json::{Value, json};

use super::tests::{Device, P, deck_entity, edit};

pub(super) const T0: i64 = 1_700_000_000_000;
pub(super) const NT_A: &str = "0193a1b2-0000-7000-8000-00000000c9a1";
const NT_B: &str = "0193a1b2-0000-7000-8000-00000000c9a2";
pub(super) const LANG: &str = "0193a1b2-0000-7000-8000-00000000c9c1";
const TARGET: &str = "0193a1b2-0000-7000-8000-00000000c9c2";
pub(super) const NOTES: [&str; 2] = [
    "0193a1b2-0000-7000-8000-00000000c9b1",
    "0193a1b2-0000-7000-8000-00000000c9b2",
];

pub(super) fn default_deck() -> String {
    super::config::default_deck_id(P)
}

pub(super) fn try_dispatch(d: &Device, req: Value, blob: Option<String>) -> Result<Value, String> {
    let mut blobs: Vec<Vec<u8>> = blob.into_iter().map(String::into_bytes).collect();
    let mut files = Vec::new();
    crate::store::ffi::sync2_dispatch(&d.core, &req, &mut blobs, &mut files)
}

pub(super) fn dispatch(d: &Device, req: Value, blob: Option<String>) -> Value {
    try_dispatch(d, req, blob).unwrap()
}

/// 宿主发的一条修改记录草稿（Dart `_applyInput`）。
pub(super) fn draft(kind: &str, entity: &str, key: &str, v: Value) -> Value {
    json!({
        "e": {"t": "edit", "x": {"p": P, "k": kind, "e": entity, "f": key, "v": v, "ts": "anchored"}},
        "note": null, "clk": "t",
    })
}

fn apply_items(d: &Device, now: i64, items: Vec<Value>) -> Value {
    dispatch(
        d,
        json!({
            "op": "apply", "profile": P, "now": now, "caches": {"defaultDeck": default_deck()},
            "legacyDevice": "dev", "tickNow": now,
        }),
        Some(Value::Array(items).to_string()),
    )
}

fn apply(d: &Device, now: i64, events: Vec<Value>) -> Value {
    apply_items(
        d,
        now,
        events
            .into_iter()
            .map(|e| json!({"e": e, "note": null}))
            .collect(),
    )
}

fn note_type(id: &str, field: &str, templates: &[&str]) -> Vec<Value> {
    let mut out = vec![
        json!({"t": "entity", "x": {"id": id, "p": P, "k": "notetype", "d": {"createdAt": 1, "ntKind": "standard"}}}),
        edit(
            "notetype",
            id,
            &format!("fieldDef/{field}"),
            json!({"name": "Front", "ord": 0}),
        ),
    ];
    for (i, t) in templates.iter().enumerate() {
        out.push(edit(
            "notetype",
            id,
            &format!("tmplDef/{t}"),
            json!({"name": t, "ord": i, "front": format!("{{{{Front}}}}{i}")}),
        ));
    }
    out
}

fn deck(id: &str, name: &str) -> Vec<Value> {
    vec![
        json!({"t": "entity", "x": {"id": id, "p": P, "k": "deck", "d": {"createdAt": 1}}}),
        edit("deck", id, "name", json!(name)),
    ]
}

/// 默认牌组、`Lang`、`Target`；类型 A（字段 fa、模板 t1）与 B（字段 fb、模板 u1 / u2）；两条 A 类型的笔记在 `Lang`。
pub(super) fn library(tag: &str) -> Device {
    let d = Device::new(tag);
    let mut events = vec![deck_entity(&default_deck())];
    events.extend(note_type(NT_A, "fa", &["t1"]));
    events.extend(note_type(NT_B, "fb", &["u1", "u2"]));
    events.extend(deck(LANG, "Lang"));
    events.extend(deck(TARGET, "Target"));
    for (i, n) in NOTES.iter().enumerate() {
        events.push(json!({"t": "entity", "x": {"id": n, "p": P, "k": "note", "d": {"createdAt": 1, "guid": n, "noteTypeId": NT_A}}}));
        events.push(edit("note", n, "f/fa", json!(format!("word{i}"))));
        events.push(edit("note", n, "deck", json!(LANG)));
    }
    apply(&d, T0, events);
    assert_eq!(visible_cards(&d).len(), 2, "one card per note");
    d
}

/// 更改笔记类型的那批修改记录（Dart 基于改动前的状态算好的）。
fn change_items() -> Vec<Value> {
    let mut out = Vec::new();
    for (i, n) in NOTES.iter().enumerate() {
        out.push(draft("note", n, "noteType", json!(NT_B)));
        out.push(draft("note", n, "f/fb", json!(format!("word{i}"))));
    }
    out
}

fn change_request(at: i64, with_move: bool) -> Value {
    let mut req = json!({
        "op": "change", "profile": P, "now": at, "caches": {"defaultDeck": default_deck()},
        "legacyDevice": "dev", "tickNow": at, "ts": "anchored",
        "checkpoint": {"name": "B", "reason": "note_type"},
    });
    if with_move {
        req["move"] = json!({"deck": TARGET, "notes": NOTES});
    }
    req
}

/// 可见卡 → 牌组。
fn visible_cards(d: &Device) -> BTreeMap<String, String> {
    d.rows(
        "SELECT srs_idt(id) AS id, srs_idt(deck_id) AS deck FROM srs_cards_cache WHERE hidden = 0",
    )
    .iter()
    .skip(1)
    .map(|r| (r[0].clone(), r[1].clone()))
    .collect()
}

/// 笔记 → 当前类型。
fn note_types(d: &Device) -> BTreeMap<String, String> {
    d.rows("SELECT srs_idt(id) AS id, srs_idt(note_type_id) AS nt FROM srs_notes_cache")
        .iter()
        .skip(1)
        .map(|r| (r[0].clone(), r[1].clone()))
        .collect()
}

pub(super) fn ops(d: &Device) -> String {
    d.rows("SELECT COUNT(*) AS n FROM sync2_ops")[1][0].clone()
}

/// 落库的修改记录（去掉类型 / 牌组定义那些铺垫），按写入顺序：`(类别, 实体, 键, 值)`。
pub(super) fn written_edits(d: &Device) -> Vec<(String, String, String, Value)> {
    d.rows(
        "SELECT entity_kind, srs_idt(entity_id) AS e, json FROM srs_field_edits \
         WHERE entity_kind IN ('note', 'card') ORDER BY rowid",
    )
    .iter()
    .skip(1)
    .map(|r| {
        let j: Value = serde_json::from_str(&r[2]).unwrap();
        (
            r[0].clone(),
            r[1].clone(),
            j["f"].as_str().unwrap().to_owned(),
            j["v"].clone(),
        )
    })
    .collect()
}

pub(super) fn local_state(d: &Device) -> Value {
    serde_json::from_str(
        &d.rows(&format!(
            "SELECT json FROM srs_local_state WHERE profile_uid = srs_id('{P}')"
        ))[1][0],
    )
    .unwrap()
}

#[test]
fn one_command_changes_the_type_and_moves_the_notes_with_their_new_cards() {
    let d = library("chg-one");
    let before = ops(&d).parse::<i64>().unwrap();
    let revision = local_state(&d)["revision"].as_i64().unwrap();
    let r = dispatch(
        &d,
        change_request(T0 + 10, true),
        Some(Value::Array(change_items()).to_string()),
    );
    assert!(r["localRevision"].is_i64(), "local state row lands: {r}");
    let cps = dispatch(&d, json!({"op": "checkpoints", "profile": P}), None).to_string();
    assert!(
        cps.contains("note_type") && cps.contains("\"B\""),
        "the command drops the checkpoint: {cps}"
    );
    assert!(note_types(&d).values().all(|t| t == NT_B));
    let cards = visible_cards(&d);
    assert_eq!(cards.len(), 4, "two new cards per note: {cards:?}");
    assert!(
        cards.values().all(|deck| deck == TARGET),
        "every visible card moved: {cards:?}"
    );
    // 还原点 1 + 类型 / 字段 4 + 笔记的首选牌组 2 + 新卡 4。
    assert_eq!(ops(&d).parse::<i64>().unwrap() - before, 11);
    // 回包是两段合起来的：十条落进投影的修改记录都算进修订号（还原点不进投影、不计，与单发 `checkpoint` 相同），
    // 第二次刷新写过的卡也在 `cache` 里。
    assert_eq!(r["marks"]["landed"], json!(10), "{r}");
    assert_eq!(r["localRevision"].as_i64().unwrap() - revision, 10, "{r}");
    let cached: Vec<&str> = r["cache"]["cards"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(Value::as_str)
        .collect();
    for id in cards.keys() {
        assert!(
            cached.contains(&id.as_str()),
            "{id} missing from {cached:?}"
        );
    }
    // 旧版时钟：十条修改记录各走一步（同一时刻：计数器 0..9）。
    assert_eq!(
        local_state(&d)["hlc"],
        json!(format!("{}:9:dev#1", T0 + 10))
    );
    // 已经在那里：再发一次只带 `move` 的，什么都不写。
    let now = ops(&d);
    let mut again = change_request(T0 + 20, true);
    again.as_object_mut().unwrap().remove("checkpoint");
    dispatch(&d, again, Some("[]".to_owned()));
    assert_eq!(ops(&d), now);
}

#[test]
fn the_edits_match_the_three_commands_it_replaces() {
    let one = library("chg-eq-one");
    dispatch(
        &one,
        change_request(T0 + 10, true),
        Some(Value::Array(change_items()).to_string()),
    );

    // 以前：还原点、换类型的一批、读回换完类型后的缓存行再移牌组（Dart `_moveNotesToDeck`）。
    let three = library("chg-eq-three");
    dispatch(
        &three,
        json!({
            "op": "checkpoint", "profile": P, "now": T0 + 10, "caches": {"defaultDeck": default_deck()},
            "name": "B", "reason": "note_type",
        }),
        None,
    );
    apply_items(&three, T0 + 10, change_items());
    let mut moves: Vec<Value> = NOTES
        .iter()
        .map(|n| draft("note", n, "deck", json!(TARGET)))
        .collect();
    for n in NOTES {
        for r in three
            .rows(&format!(
                "SELECT srs_idt(id) AS id FROM srs_cards_cache WHERE note_id = srs_id('{n}') \
                 AND hidden = 0 ORDER BY rowid"
            ))
            .iter()
            .skip(1)
        {
            moves.push(draft("card", &r[0], "deck", json!(TARGET)));
        }
    }
    apply_items(&three, T0 + 10, moves);

    assert_eq!(written_edits(&one), written_edits(&three));
    assert_eq!(visible_cards(&one), visible_cards(&three));
    assert_eq!(local_state(&one)["hlc"], local_state(&three)["hlc"]);
}

#[test]
fn a_failure_in_any_stage_rolls_the_whole_command_back() {
    for stage in ["apply", "move"] {
        let d = library(&format!("chg-fail-{stage}"));
        let (before_ops, before_state) = (ops(&d), local_state(&d));
        let mut req = change_request(T0 + 10, true);
        req["failAfter"] = json!(stage);
        let err =
            try_dispatch(&d, req, Some(Value::Array(change_items()).to_string())).unwrap_err();
        assert!(err.contains("injected failure"), "{stage}: {err}");
        // 什么都没落：没有还原点、类型没换、卡没动、本机状态行（修订号、旧版时钟）没变。
        assert_eq!(ops(&d), before_ops, "{stage}");
        assert_eq!(local_state(&d), before_state, "{stage}");
        assert!(note_types(&d).values().all(|t| t == NT_A), "{stage}");
        let cards = visible_cards(&d);
        assert_eq!(cards.len(), 2, "{stage}: {cards:?}");
        assert!(cards.values().all(|deck| deck == LANG), "{stage}");
        // 原样重试成功。
        dispatch(
            &d,
            change_request(T0 + 11, true),
            Some(Value::Array(change_items()).to_string()),
        );
        assert!(visible_cards(&d).values().all(|deck| deck == TARGET));
    }
}

#[test]
fn without_a_move_it_is_a_checkpoint_plus_the_edits() {
    let d = library("chg-plain");
    let before = ops(&d).parse::<i64>().unwrap();
    let r = dispatch(
        &d,
        change_request(T0 + 10, false),
        Some(Value::Array(change_items()).to_string()),
    );
    assert_eq!(ops(&d).parse::<i64>().unwrap() - before, 5);
    // 还原点 1 条操作 + 4 条修改记录；进投影（计进修订号）的只有那 4 条。
    assert_eq!(r["marks"]["landed"], json!(4), "{r}");
    assert!(note_types(&d).values().all(|t| t == NT_B));
    // 新卡按笔记的首选牌组落位，没人移它们。
    let cards = visible_cards(&d);
    assert_eq!(cards.len(), 4);
    assert!(cards.values().all(|deck| deck == LANG), "{cards:?}");
}
