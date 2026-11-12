//! 删牌组的意图命令 `deck_delete`（deck_delete.rs）：先数、再分步删笔记 / 移卡、最后一步收尾并给子树写删除标记；
//! 步与步之间插进来的写入（放进子树的卡、新建的子牌组）在收尾时一并处理；旧版时钟每条写入走一步。

use std::collections::{BTreeMap, BTreeSet};

use serde_json::{Value, json};

use super::tests::{Device, P, deck_entity, edit};

const T0: i64 = 1_700_000_000_000;
const NT: &str = "0193a1b2-0000-7000-8000-00000000d0a1";
const LANG: &str = "0193a1b2-0000-7000-8000-00000000d0c1";
const JP: &str = "0193a1b2-0000-7000-8000-00000000d0c2";
const NOTES: [&str; 3] = [
    "0193a1b2-0000-7000-8000-00000000d0b1",
    "0193a1b2-0000-7000-8000-00000000d0b2",
    "0193a1b2-0000-7000-8000-00000000d0b3",
];

fn default_deck() -> String {
    super::config::default_deck_id(P)
}

fn try_dispatch(d: &Device, req: Value, blob: Option<String>) -> Result<Value, String> {
    let mut blobs: Vec<Vec<u8>> = blob.into_iter().map(String::into_bytes).collect();
    let mut files = Vec::new();
    crate::store::ffi::sync2_dispatch(&d.core, &req, &mut blobs, &mut files)
}

fn dispatch(d: &Device, req: Value, blob: Option<String>) -> Value {
    try_dispatch(d, req, blob).unwrap()
}

fn apply(d: &Device, now: i64, events: Vec<Value>) -> Value {
    let input: Vec<Value> = events
        .into_iter()
        .map(|e| json!({"e": e, "note": null}))
        .collect();
    dispatch(
        d,
        json!({
            "op": "apply", "profile": P, "now": now, "caches": {"defaultDeck": default_deck()},
            "legacyDevice": "dev",
        }),
        Some(Value::Array(input).to_string()),
    )
}

fn deck(id: &str, name: &str, parent: Option<&str>) -> Vec<Value> {
    let mut out = vec![
        json!({"t": "entity", "x": {"id": id, "p": P, "k": "deck", "d": {"createdAt": 1}}}),
        edit("deck", id, "name", json!(name)),
    ];
    if let Some(p) = parent {
        out.push(edit("deck", id, "parent", json!(p)));
    }
    out
}

/// 卡 ID：`(笔记下标, 模板)` → ID。
fn cards(d: &Device) -> BTreeMap<(usize, String), String> {
    let mut out = BTreeMap::new();
    for (i, n) in NOTES.iter().enumerate() {
        for r in d
            .rows(&format!(
                "SELECT srs_idt(id) AS id, srs_idt(template_id) AS t FROM srs_cards_cache \
                 WHERE note_id = srs_id('{n}')"
            ))
            .iter()
            .skip(1)
        {
            out.insert((i, r[1].clone()), r[0].clone());
        }
    }
    out
}

/// 缓存里各卡的牌组。
fn card_decks(d: &Device) -> BTreeMap<String, String> {
    d.rows("SELECT srs_idt(id) AS id, srs_idt(deck_id) AS deck FROM srs_cards_cache")
        .iter()
        .skip(1)
        .map(|r| (r[0].clone(), r[1].clone()))
        .collect()
}

/// 写过删除标记的牌组。
fn deleted_decks(d: &Device) -> BTreeSet<String> {
    d.rows("SELECT srs_idt(entity_id) AS e, json FROM srs_field_edits WHERE entity_kind = 'deck'")
        .iter()
        .skip(1)
        .filter(|r| {
            let j: Value = serde_json::from_str(&r[1]).unwrap();
            j["f"] == "deleted" && j["v"].is_i64()
        })
        .map(|r| r[0].clone())
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

/// 默认牌组、`Lang`、`Lang::JP`；三条笔记各两张卡（模板 t1 在 Lang、t2 在 JP），第三条笔记的 t2 卡在默认牌组。
fn library(tag: &str) -> (Device, BTreeMap<(usize, String), String>) {
    let d = Device::new(tag);
    let mut events = vec![
        deck_entity(&default_deck()),
        json!({"t": "entity", "x": {"id": NT, "p": P, "k": "notetype", "d": {"createdAt": 1, "ntKind": "standard"}}}),
        edit(
            "notetype",
            NT,
            "fieldDef/fa",
            json!({"name": "Front", "ord": 0}),
        ),
        edit(
            "notetype",
            NT,
            "tmplDef/t1",
            json!({"name": "A", "ord": 0, "front": "{{Front}}"}),
        ),
        edit(
            "notetype",
            NT,
            "tmplDef/t2",
            json!({"name": "B", "ord": 1, "front": "{{Front}}!"}),
        ),
    ];
    events.extend(deck(LANG, "Lang", None));
    events.extend(deck(JP, "JP", Some(LANG)));
    for (i, n) in NOTES.iter().enumerate() {
        events.push(json!({"t": "entity", "x": {"id": n, "p": P, "k": "note", "d": {"createdAt": 1, "guid": n, "noteTypeId": NT}}}));
        events.push(edit("note", n, "f/fa", json!(format!("word{i}"))));
        events.push(edit("note", n, "deck", json!(LANG)));
    }
    apply(&d, T0, events);
    let ids = cards(&d);
    assert_eq!(ids.len(), 6, "two cards per note: {ids:?}");
    let t2 = |i: usize| ids[&(i, "t2".to_owned())].clone();
    apply(
        &d,
        T0 + 1,
        vec![
            edit("card", &t2(0), "deck", json!(JP)),
            edit("card", &t2(1), "deck", json!(JP)),
            edit("card", &t2(2), "deck", json!(default_deck())),
        ],
    );
    (d, ids)
}

fn request(deck: &str, delete_cards: bool, at: i64) -> Value {
    json!({
        "op": "deck_delete", "profile": P, "now": at, "caches": {"defaultDeck": default_deck()},
        "deck": deck, "deleteCards": delete_cards, "localState": "{}",
    })
}

fn plan(d: &Device, deck: &str, delete_cards: bool, at: i64) -> Value {
    let mut req = request(deck, delete_cards, at);
    req["plan"] = json!(true);
    dispatch(d, req, None)
}

/// 一步；[token] 是上一步交回的。
fn step(d: &Device, deck: &str, delete_cards: bool, at: i64, limit: i64, token: &Value) -> Value {
    let mut req = request(deck, delete_cards, at);
    req["limit"] = json!(limit);
    req["token"] = token.clone();
    req["deletedAt"] = json!(T0 + 5);
    req["tickNow"] = json!(at);
    req["ts"] = json!("anchored");
    req["legacyDevice"] = json!("dev");
    dispatch(d, req, None)
}

/// 发步直到做完：返回 (步数, 各步 `count` 之和, 删掉的笔记)。
fn run(
    d: &Device,
    deck: &str,
    delete_cards: bool,
    at: i64,
    limit: i64,
) -> (usize, i64, Vec<String>) {
    let (mut steps, mut count, mut notes) = (0, 0, Vec::new());
    let mut token = Value::Null;
    loop {
        let r = step(d, deck, delete_cards, at, limit, &token);
        steps += 1;
        count += r["count"].as_i64().unwrap();
        notes.extend(
            r["notes"]
                .as_array()
                .unwrap()
                .iter()
                .map(|n| n.as_str().unwrap().to_owned()),
        );
        assert!(
            r["localRevision"].is_i64(),
            "local state row lands with the step: {r}"
        );
        if r["done"] == json!(true) {
            return (steps, count, notes);
        }
        token = r["token"].clone();
        assert!(steps < 50, "deck_delete does not finish");
    }
}

#[test]
fn moving_mode_moves_the_subtree_cards_and_tombstones_every_deck() {
    let (d, _) = library("dd-move");
    let ops_before = d.rows("SELECT COUNT(*) AS n FROM sync2_ops")[1][0].clone();
    let p = plan(&d, LANG, false, T0 + 10);
    assert_eq!(p["total"], json!(5), "{p}");
    assert_eq!(p["done"], json!(false));
    assert_eq!(
        d.rows("SELECT COUNT(*) AS n FROM sync2_ops")[1][0],
        ops_before,
        "no checkpoint without notes to delete"
    );
    // 每步两个：2 + 2 + 1（卡取完的那一步接着收尾）。
    let (steps, count, notes) = run(&d, LANG, false, T0 + 10, 2);
    assert_eq!((steps, count), (3, 5));
    assert!(notes.is_empty());
    let dd = default_deck();
    assert!(
        card_decks(&d).values().all(|deck| *deck == dd),
        "every card left the deleted subtree: {:?}",
        card_decks(&d)
    );
    assert_eq!(
        deleted_decks(&d),
        BTreeSet::from([LANG.to_owned(), JP.to_owned()])
    );
    assert!(
        d.rows("SELECT COUNT(*) AS n FROM srs_notes_cache WHERE deleted_at IS NOT NULL")[1][0]
            == "0"
    );
    // 旧版时钟：五张卡 + 两个牌组，每条走一步（同一时刻：计数器 0..6）。
    assert_eq!(
        local_state(&d)["hlc"],
        json!(format!("{}:6:dev#1", T0 + 10))
    );
    // 再删一次：牌组已不在，什么都不写。
    let ops = d.rows("SELECT COUNT(*) AS n FROM sync2_ops")[1][0].clone();
    let p = plan(&d, LANG, false, T0 + 20);
    assert_eq!(
        (p["total"].clone(), p["done"].clone()),
        (json!(0), json!(true))
    );
    let r = step(&d, LANG, false, T0 + 20, 2, &Value::Null);
    assert_eq!(r["done"], json!(true));
    assert_eq!(d.rows("SELECT COUNT(*) AS n FROM sync2_ops")[1][0], ops);
}

#[test]
fn delete_cards_mode_deletes_only_notes_whose_cards_all_sit_in_the_subtree() {
    let (d, _) = library("dd-cards");
    let p = plan(&d, LANG, true, T0 + 10);
    // 两条笔记（第三条有卡在默认牌组）+ 五张卡。
    assert_eq!(p["total"], json!(7), "{p}");
    let cps = dispatch(&d, json!({"op": "checkpoints", "profile": P}), None).to_string();
    assert!(
        cps.contains("bulk_delete") && cps.contains("\"Lang\""),
        "the plan step drops a checkpoint named after the deck: {cps}"
    );
    // 每步三个：2 条笔记 + 1 张卡、3 张卡、1 张卡 + 收尾。
    let (steps, count, notes) = run(&d, LANG, true, T0 + 10, 3);
    assert_eq!((steps, count), (3, 7));
    assert_eq!(
        notes.iter().cloned().collect::<BTreeSet<_>>(),
        BTreeSet::from([NOTES[0].to_owned(), NOTES[1].to_owned()])
    );
    let deleted: BTreeMap<String, String> = d
        .rows("SELECT srs_idt(id) AS id, COALESCE(deleted_at, 0) AS at FROM srs_notes_cache")
        .iter()
        .skip(1)
        .map(|r| (r[0].clone(), r[1].clone()))
        .collect();
    let at = (T0 + 5).to_string();
    assert_eq!(deleted[NOTES[0]], at);
    assert_eq!(deleted[NOTES[1]], at);
    assert_eq!(deleted[NOTES[2]], "0", "a note with a card elsewhere stays");
    let dd = default_deck();
    assert!(card_decks(&d).values().all(|deck| *deck == dd));
    assert_eq!(
        deleted_decks(&d),
        BTreeSet::from([LANG.to_owned(), JP.to_owned()])
    );
}

#[test]
fn writes_landing_between_steps_are_swept_up_by_the_last_step() {
    let (d, ids) = library("dd-late");
    const LATE: &str = "0193a1b2-0000-7000-8000-00000000d0c3";
    let p = plan(&d, JP, false, T0 + 10);
    assert_eq!(p["total"], json!(2), "{p}");
    let r = step(&d, JP, false, T0 + 10, 1, &Value::Null);
    assert_eq!(
        (r["count"].clone(), r["done"].clone()),
        (json!(1), json!(false))
    );
    // 两步之间：建一个子牌组并放进一张卡（rowid 在游标之后），再把一张游标已经走过的卡挪进被删的牌组。
    let mut events = deck(LATE, "Late", Some(JP));
    events.push(edit(
        "card",
        &ids[&(2, "t1".to_owned())],
        "deck",
        json!(LATE),
    ));
    events.push(edit("card", &ids[&(0, "t1".to_owned())], "deck", json!(JP)));
    apply(&d, T0 + 11, events);
    let mut token = r["token"].clone();
    for _ in 0..10 {
        let r = step(&d, JP, false, T0 + 12, 1, &token);
        token = r["token"].clone();
        if r["done"] == json!(true) {
            break;
        }
    }
    let decks = card_decks(&d);
    assert!(
        decks.values().all(|deck| deck != JP && deck != LATE),
        "nothing is left under the deleted decks: {decks:?}"
    );
    // 移到被删牌组的父牌组。
    for key in [(0, "t1"), (0, "t2"), (1, "t2"), (2, "t1")] {
        assert_eq!(decks[&ids[&(key.0, key.1.to_owned())]], LANG, "{key:?}");
    }
    assert_eq!(
        deleted_decks(&d),
        BTreeSet::from([JP.to_owned(), LATE.to_owned()])
    );
}

#[test]
fn the_default_deck_is_refused_and_an_unknown_deck_is_a_no_op() {
    let (d, _) = library("dd-refuse");
    let mut req = request(&default_deck(), false, T0 + 10);
    req["plan"] = json!(true);
    let err = try_dispatch(&d, req, None).unwrap_err();
    assert!(err.contains("default deck"), "{err}");
    let p = plan(&d, "0193a1b2-0000-7000-8000-00000000dead", true, T0 + 10);
    assert_eq!(
        (p["total"].clone(), p["done"].clone()),
        (json!(0), json!(true))
    );
    assert!(deleted_decks(&d).is_empty());
}
