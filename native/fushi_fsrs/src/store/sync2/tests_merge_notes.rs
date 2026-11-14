//! 合并重复笔记的意图命令 `merge_notes`（merge_notes.rs）：还原点 + 前身链接 + 补空字段 / 并标签 + 删除被吸收的
//! 笔记，一条命令、一笔；写出的修改记录与以前的那几条命令逐条相同；任何一步出错整笔回滚。

use std::collections::BTreeMap;

use serde_json::{Value, json};

use super::tests::{Device, P, deck_entity, edit};

const T0: i64 = 1_700_000_000_000;
const NT: &str = "0193a1b2-0000-7000-8000-00000000e0a1";
const NT_OTHER: &str = "0193a1b2-0000-7000-8000-00000000e0a2";
const KEEP: &str = "0193a1b2-0000-7000-8000-00000000e0b1";
const DUP1: &str = "0193a1b2-0000-7000-8000-00000000e0b2";
const DUP2: &str = "0193a1b2-0000-7000-8000-00000000e0b3";
const OTHER: &str = "0193a1b2-0000-7000-8000-00000000e0b4";
const GONE: &str = "0193a1b2-0000-7000-8000-00000000e0bf";

fn default_deck() -> String {
    super::config::default_deck_id(P)
}

fn try_dispatch(d: &Device, req: Value, blob: Option<String>) -> Result<Value, String> {
    let mut blobs: Vec<Vec<u8>> = blob.into_iter().map(String::into_bytes).collect();
    let mut files = Vec::new();
    crate::store::ffi::sync2_dispatch(&d.core, &req, &mut blobs, &mut files)
}

fn apply_items(d: &Device, now: i64, items: Vec<Value>) -> Value {
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

fn draft(kind: &str, entity: &str, key: &str, v: Value) -> Value {
    json!({
        "e": {"t": "edit", "x": {"p": P, "k": kind, "e": entity, "f": key, "v": v, "ts": "anchored"}},
        "note": null, "clk": "t",
    })
}

fn note_type(id: &str) -> Vec<Value> {
    vec![
        json!({"t": "entity", "x": {"id": id, "p": P, "k": "notetype", "d": {"createdAt": 1, "ntKind": "standard"}}}),
        edit("notetype", id, "fieldDef/a", json!({"name": "A", "ord": 0})),
        edit("notetype", id, "fieldDef/b", json!({"name": "B", "ord": 1})),
        edit("notetype", id, "fieldDef/c", json!({"name": "C", "ord": 2})),
        edit(
            "notetype",
            id,
            "tmplDef/t1",
            json!({"name": "t1", "ord": 0, "front": "{{A}}"}),
        ),
        edit(
            "notetype",
            id,
            "tmplDef/t2",
            json!({"name": "t2", "ord": 1, "front": "{{A}}!"}),
        ),
    ]
}

fn note(id: &str, nt: &str, fields: &[(&str, &str)], tags: &[&str]) -> Vec<Value> {
    let mut out = vec![
        json!({"t": "entity", "x": {"id": id, "p": P, "k": "note", "d": {"createdAt": 1, "guid": id, "noteTypeId": nt}}}),
    ];
    for (k, v) in fields {
        out.push(edit("note", id, &format!("f/{k}"), json!(v)));
    }
    if !tags.is_empty() {
        out.push(edit("note", id, "tags", json!(tags)));
    }
    out
}

/// 保留笔记（a = "word"，b 只有空白，标签 x）；两条同类型的重复（各带 b / c 的值与别的标签）；一条别的类型的。
fn library(tag: &str) -> Device {
    let d = Device::new(tag);
    let mut events = vec![deck_entity(&default_deck())];
    events.extend(note_type(NT));
    events.extend(note_type(NT_OTHER));
    events.extend(note(KEEP, NT, &[("a", "word"), ("b", " \u{feff}")], &["x"]));
    events.extend(note(
        DUP1,
        NT,
        &[("a", "word"), ("b", "meaning one"), ("c", "  ")],
        &["y", "x"],
    ));
    events.extend(note(
        DUP2,
        NT,
        &[("a", "word"), ("b", "meaning two"), ("c", "extra")],
        &["z"],
    ));
    events.extend(note(OTHER, NT_OTHER, &[("a", "word")], &[]));
    let items = events
        .into_iter()
        .map(|e| json!({"e": e, "note": null}))
        .collect();
    apply_items(&d, T0, items);
    d
}

fn request(at: i64, absorb: &[&str]) -> Value {
    json!({
        "op": "merge_notes", "profile": P, "now": at, "caches": {"defaultDeck": default_deck()},
        "legacyDevice": "dev", "tickNow": at, "ts": "anchored",
        "keep": KEEP, "absorb": absorb, "deletedAt": at,
    })
}

fn ops(d: &Device) -> i64 {
    d.rows("SELECT COUNT(*) AS n FROM sync2_ops")[1][0]
        .parse()
        .unwrap()
}

/// 一条笔记的卡：模板 → 卡 ID（缓存行）。
fn cards(d: &Device, note: &str) -> BTreeMap<String, String> {
    d.rows(&format!(
        "SELECT srs_idt(template_id) AS t, srs_idt(id) AS id FROM srs_cards_cache \
         WHERE note_id = srs_id('{note}') ORDER BY rowid"
    ))
    .iter()
    .skip(1)
    .map(|r| (r[0].clone(), r[1].clone()))
    .collect()
}

/// 笔记 / 卡的修改记录，按写入顺序：`(类别, 实体, 键, 值)`。
fn written_edits(d: &Device) -> Vec<(String, String, String, Value)> {
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

/// 笔记缓存：ID → (删除时刻, 标签)。
fn notes(d: &Device) -> BTreeMap<String, (String, String)> {
    d.rows("SELECT srs_idt(id) AS id, deleted_at, tags_json FROM srs_notes_cache")
        .iter()
        .skip(1)
        .map(|r| (r[0].clone(), (r[1].clone(), r[2].clone())))
        .collect()
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
fn one_command_links_fills_tags_and_deletes() {
    let d = library("mrg-one");
    let before = ops(&d);
    let (keep_cards, dup1_cards, dup2_cards) = (cards(&d, KEEP), cards(&d, DUP1), cards(&d, DUP2));
    assert_eq!(keep_cards.len(), 2);
    // `absorb` 里的保留笔记自己与重复项都不算。
    let r = try_dispatch(&d, request(T0 + 10, &[DUP1, KEEP, DUP2, DUP1]), None).unwrap();
    assert_eq!(
        (&r["linked"], &r["unmatched"]),
        (&json!(4), &json!(0)),
        "{r}"
    );
    assert!(r["localRevision"].is_i64(), "{r}");
    let cps = try_dispatch(&d, json!({"op": "checkpoints", "profile": P}), None)
        .unwrap()
        .to_string();
    assert!(
        cps.contains("merge_notes") && cps.contains("\"word\""),
        "checkpoint named after the kept note's first field: {cps}"
    );
    let edits = written_edits(&d);
    for (t, target) in &keep_cards {
        for from in [&dup1_cards[t], &dup2_cards[t]] {
            assert!(
                edits.contains(&(
                    "card".into(),
                    target.clone(),
                    format!("historyFrom/{from}"),
                    json!(true)
                )),
                "{from} -> {target}"
            );
        }
    }
    // b（只有空白）取第一条有值的；c（保留笔记没有）跳过只有空白的那条、取下一条的。
    assert!(edits.contains(&(
        "note".into(),
        KEEP.into(),
        "f/b".into(),
        json!("meaning one")
    )));
    assert!(edits.contains(&("note".into(), KEEP.into(), "f/c".into(), json!("extra"))));
    let n = notes(&d);
    assert_eq!(n[KEEP].1, r#"["x","y","z"]"#);
    assert_eq!(n[KEEP].0, "NULL");
    assert_eq!(n[DUP1].0, (T0 + 10).to_string());
    assert_eq!(n[DUP2].0, (T0 + 10).to_string());
    // 写了东西（逐条内容与以前那几条命令相同：见 the_edits_match_the_commands_it_replaces）。
    assert!(ops(&d) > before);
    // 再并一次：被吸收的已经删了、链接与字段都在，只多一个还原点。
    let again = ops(&d);
    try_dispatch(&d, request(T0 + 10, &[DUP1, DUP2]), None).unwrap();
    assert_eq!(ops(&d) - again, 1);
}

#[test]
fn the_edits_match_the_commands_it_replaces() {
    let one = library("mrg-eq-one");
    try_dispatch(&one, request(T0 + 10, &[DUP1, DUP2]), None).unwrap();

    // 以前：还原点、前身链接、保留笔记的字段与标签、逐条删除（Dart `mergeNotes`）。
    let old = library("mrg-eq-old");
    try_dispatch(
        &old,
        json!({
            "op": "checkpoint", "profile": P, "now": T0 + 10, "caches": {"defaultDeck": default_deck()},
            "name": "word", "reason": "merge_notes",
        }),
        None,
    )
    .unwrap();
    let keep_cards = cards(&old, KEEP);
    let mut links = Vec::new();
    for dup in [DUP1, DUP2] {
        for (t, from) in cards(&old, dup) {
            links.push(draft(
                "card",
                &keep_cards[&t],
                &format!("historyFrom/{from}"),
                json!(true),
            ));
        }
    }
    apply_items(&old, T0 + 10, links);
    apply_items(
        &old,
        T0 + 10,
        vec![
            draft("note", KEEP, "f/b", json!("meaning one")),
            draft("note", KEEP, "f/c", json!("extra")),
            draft("note", KEEP, "tags", json!(["x", "y", "z"])),
        ],
    );
    for dup in [DUP1, DUP2] {
        apply_items(
            &old,
            T0 + 10,
            vec![draft("note", dup, "deleted", json!(T0 + 10))],
        );
    }

    assert_eq!(written_edits(&one), written_edits(&old));
    assert_eq!(notes(&one), notes(&old));
    assert_eq!(local_state(&one)["hlc"], local_state(&old)["hlc"]);
    assert_eq!(ops(&one), ops(&old));
}

#[test]
fn bad_input_and_failures_write_nothing() {
    let d = library("mrg-fail");
    let before = (ops(&d), local_state(&d), written_edits(&d));
    let unchanged = |what: &str| {
        assert_eq!(ops(&d), before.0, "{what}");
        assert_eq!(local_state(&d), before.1, "{what}");
        assert_eq!(written_edits(&d), before.2, "{what}");
    };
    let err = try_dispatch(&d, request(T0 + 10, &[DUP1, OTHER]), None).unwrap_err();
    assert!(err.contains("different note types"), "{err}");
    unchanged("different types");
    let err = try_dispatch(&d, request(T0 + 10, &[GONE]), None).unwrap_err();
    assert!(err.contains(&format!("note {GONE} not found")), "{err}");
    unchanged("missing note");
    let mut req = request(T0 + 10, &[DUP1, DUP2]);
    req["failAfter"] = json!("apply");
    let err = try_dispatch(&d, req, None).unwrap_err();
    assert!(err.contains("injected failure"), "{err}");
    unchanged("injected failure");
    // 没有要并的：不打还原点。
    let r = try_dispatch(&d, request(T0 + 10, &[KEEP]), None).unwrap();
    assert_eq!((&r["linked"], &r["unmatched"]), (&json!(0), &json!(0)));
    assert_eq!(ops(&d), before.0);
    // 原样重试成功。
    try_dispatch(&d, request(T0 + 11, &[DUP1, DUP2]), None).unwrap();
    assert_eq!(notes(&d)[DUP1].0, (T0 + 11).to_string());
}
