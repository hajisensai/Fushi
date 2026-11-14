//! `chg` 项（changing.rs）：值没变的修改记录草稿由内核在命令的那一笔里筛掉；以及成批的 `purge`。

use serde_json::{Value, json};

use super::tests::{Device, P};
use super::tests_change::{
    LANG, NOTES, T0, default_deck, dispatch, draft, library, local_state, ops, try_dispatch,
    written_edits,
};

/// 一条标了 `chg` 的修改记录草稿。
fn chg(kind: &str, entity: &str, key: &str, v: Value) -> Value {
    let mut it = draft(kind, entity, key, v);
    it["chg"] = json!(true);
    it
}

fn apply_request(now: i64) -> Value {
    json!({
        "op": "apply", "profile": P, "now": now, "caches": {"defaultDeck": default_deck()},
        "legacyDevice": "dev", "tickNow": now, "stamps": true,
    })
}

fn apply(d: &Device, now: i64, items: Vec<Value>) -> Value {
    dispatch(d, apply_request(now), Some(Value::Array(items).to_string()))
}

fn op_count(d: &Device) -> i64 {
    ops(d).parse().unwrap()
}

/// 笔记 `f/fa` 的生效值（笔记缓存行里的字段）。
fn front(d: &Device, note: &str) -> String {
    let rows = d.rows(&format!(
        "SELECT json FROM srs_field_edits WHERE entity_id = srs_id('{note}') AND field_key = 'f/fa' \
         ORDER BY rowid DESC LIMIT 1"
    ));
    let j: Value = serde_json::from_str(&rows[1][0]).unwrap();
    j["v"].as_str().unwrap().to_owned()
}

#[test]
fn unchanged_values_are_dropped_and_the_reply_keeps_the_input_shape() {
    let d = library("chg-mixed");
    let before = op_count(&d);
    let r = apply(
        &d,
        T0 + 10,
        vec![
            chg("note", NOTES[0], "f/fa", json!("word0")),
            chg("note", NOTES[0], "f/extra", json!("new")),
            chg("note", NOTES[0], "deck", json!(LANG)),
            chg("note", NOTES[1], "f/fa", json!("changed")),
        ],
    );
    assert_eq!(op_count(&d) - before, 2, "{r}");
    assert_eq!(r["marks"]["landed"], json!(2), "{r}");
    assert_eq!(r["landed"], json!([false, true, false, true]), "{r}");
    let stamps = r["stamps"].as_array().unwrap();
    assert_eq!(stamps.len(), 4, "{r}");
    assert!(stamps[0].is_null() && stamps[2].is_null(), "{r}");
    assert_eq!(stamps[1]["f"], json!("f/extra"), "{r}");
    assert_eq!(stamps[3]["v"], json!("changed"), "{r}");
    assert_eq!(front(&d, NOTES[1]), "changed");
    // 没标 `chg` 的同值草稿照旧落（标记是逐项的）。
    let r = apply(
        &d,
        T0 + 20,
        vec![draft("note", NOTES[0], "f/fa", json!("word0"))],
    );
    assert_eq!(r["marks"]["landed"], json!(1), "{r}");
    assert_eq!(r["landed"], json!([true]), "{r}");
}

#[test]
fn a_batch_of_nothing_but_unchanged_values_lands_nothing() {
    let d = library("chg-none");
    let ops_before = op_count(&d);
    let edits_before = written_edits(&d);
    let state_before = local_state(&d);
    let r = apply(
        &d,
        T0 + 10,
        vec![
            chg("note", NOTES[0], "f/fa", json!("word0")),
            chg("note", NOTES[1], "deck", json!(LANG)),
        ],
    );
    assert_eq!(op_count(&d), ops_before, "{r}");
    assert_eq!(written_edits(&d), edits_before);
    assert_eq!(r["landed"], json!([false, false]), "{r}");
    assert_eq!(r["stamps"], json!([null, null]), "{r}");
    // 旧版时钟没走、修订号没动（本机状态行照常由分发器写下，内容不变）。
    let state = local_state(&d);
    assert_eq!(state["hlc"], state_before["hlc"]);
    assert_eq!(state["revision"], state_before["revision"]);
    assert_eq!(r["localRevision"], state_before["revision"], "{r}");
}

#[test]
fn within_a_batch_a_later_item_is_judged_against_the_earlier_one() {
    let d = library("chg-seq");
    // 现值 word0：先改成 B、再改回 word0——两条都落，最后是 word0（按批前的库判会把第二条当成没变而丢掉）。
    let r = apply(
        &d,
        T0 + 10,
        vec![
            chg("note", NOTES[0], "f/fa", json!("B")),
            chg("note", NOTES[0], "f/fa", json!("word0")),
        ],
    );
    assert_eq!(r["landed"], json!([true, true]), "{r}");
    assert_eq!(front(&d, NOTES[0]), "word0");
    // 同一个新值写两遍：只落第一条。
    let r = apply(
        &d,
        T0 + 20,
        vec![
            chg("note", NOTES[0], "f/fa", json!("C")),
            chg("note", NOTES[0], "f/fa", json!("C")),
        ],
    );
    assert_eq!(r["landed"], json!([true, false]), "{r}");
    assert_eq!(front(&d, NOTES[0]), "C");
    // 值没变的第一条被筛掉之后，第二条照样拿它的值比。
    let r = apply(
        &d,
        T0 + 30,
        vec![
            chg("note", NOTES[0], "f/fa", json!("C")),
            chg("note", NOTES[0], "f/fa", json!("D")),
        ],
    );
    assert_eq!(r["landed"], json!([false, true]), "{r}");
    assert_eq!(front(&d, NOTES[0]), "D");
}

#[test]
fn a_new_entity_in_the_same_batch_gets_all_its_edits() {
    let d = library("chg-new");
    const NEW: &str = "0193a1b2-0000-7000-8000-00000000c9b9";
    let r = apply(
        &d,
        T0 + 10,
        vec![
            json!({"e": {"t": "entity", "x": {"id": NEW, "p": P, "k": "note",
                   "d": {"createdAt": 1, "guid": NEW, "noteTypeId": super::tests_change::NT_A}}},
                   "note": null}),
            chg("note", NEW, "f/fa", json!("fresh")),
            chg("note", NEW, "deck", json!(LANG)),
        ],
    );
    assert_eq!(r["landed"], json!([true, true, true]), "{r}");
    // 同一批原样再发：两个键的值都没变，修改记录一条不落（身份记录那一项照旧追加，它不归 `chg` 管）。
    let before = written_edits(&d);
    let r = apply(
        &d,
        T0 + 20,
        vec![
            json!({"e": {"t": "entity", "x": {"id": NEW, "p": P, "k": "note",
                   "d": {"createdAt": 1, "guid": NEW, "noteTypeId": super::tests_change::NT_A}}},
                   "note": null}),
            chg("note", NEW, "f/fa", json!("fresh")),
            chg("note", NEW, "deck", json!(LANG)),
        ],
    );
    assert_eq!(r["landed"][1], json!(false), "{r}");
    assert_eq!(r["landed"][2], json!(false), "{r}");
    assert_eq!(written_edits(&d), before, "{r}");
}

#[test]
fn change_drops_unchanged_values_but_still_writes_the_checkpoint() {
    let d = library("chg-change");
    let before = op_count(&d);
    let hlc = local_state(&d)["hlc"].clone();
    let req = json!({
        "op": "change", "profile": P, "now": T0 + 10, "caches": {"defaultDeck": default_deck()},
        "legacyDevice": "dev", "tickNow": T0 + 10, "ts": "anchored",
        "checkpoint": {"name": "cp", "reason": "note_type"},
    });
    let items = vec![
        chg("note", NOTES[0], "f/fa", json!("word0")),
        chg("note", NOTES[1], "f/fa", json!("word1")),
    ];
    dispatch(&d, req.clone(), Some(Value::Array(items).to_string()));
    assert_eq!(op_count(&d) - before, 1, "only the checkpoint");
    assert_eq!(local_state(&d)["hlc"], hlc, "the legacy clock did not tick");
    // 有一条变了：还原点 + 那一条。
    let items = vec![
        chg("note", NOTES[0], "f/fa", json!("word0")),
        chg("note", NOTES[1], "f/fa", json!("other")),
    ];
    let mut req2 = req.clone();
    req2["now"] = json!(T0 + 20);
    req2["tickNow"] = json!(T0 + 20);
    let r = dispatch(&d, req2, Some(Value::Array(items).to_string()));
    assert_eq!(op_count(&d) - before, 3, "{r}");
    assert_eq!(front(&d, NOTES[1]), "other");
    // 中途失败的注入点仍然生效（筛完一项不剩时也是）。
    let mut failing = req;
    failing["now"] = json!(T0 + 30);
    failing["failAfter"] = json!("apply");
    let err = try_dispatch(
        &d,
        failing,
        Some(Value::Array(vec![chg("note", NOTES[0], "f/fa", json!("word0"))]).to_string()),
    )
    .unwrap_err();
    assert!(err.contains("fail"), "{err}");
    assert_eq!(op_count(&d) - before, 3, "rolled back with its checkpoint");
}

#[test]
fn chg_is_refused_where_it_has_no_meaning() {
    let d = library("chg-refuse");
    let before = op_count(&d);
    let run = |items: Vec<Value>, op: &str| -> String {
        let mut req = apply_request(T0 + 10);
        req["op"] = json!(op);
        try_dispatch(&d, req, Some(Value::Array(items).to_string())).unwrap_err()
    };
    // 不是修改记录。
    let mut entity = json!({"e": {"t": "entity", "x": {"id": NOTES[0], "p": P, "k": "note",
        "d": {"createdAt": 1, "guid": NOTES[0], "noteTypeId": super::tests_change::NT_A}}}, "note": null});
    entity["chg"] = json!(true);
    assert!(run(vec![entity], "apply").contains("not an edit"));
    // 与「初值」同标。
    let mut both = chg("note", NOTES[0], "f/fa", json!("x"));
    both["init"] = json!(true);
    assert!(run(vec![both], "apply").contains("init / stamped"));
    // 导入的草稿不认它。
    assert!(
        run(
            vec![chg("note", NOTES[0], "f/fa", json!("x"))],
            "import_drafts"
        )
        .contains("chg items are not accepted")
    );
    assert_eq!(op_count(&d), before);
}

#[test]
fn purge_takes_a_batch_of_entities_in_one_command() {
    let purged = |d: &Device| -> Vec<String> {
        d.rows("SELECT srs_idt(entity) AS e FROM sync2_purged ORDER BY 1")
            .iter()
            .skip(1)
            .map(|r| r[0].clone())
            .collect()
    };
    let request = |entities: Value| -> Value {
        json!({"op": "purge", "profile": P, "now": T0 + 10, "caches": {"defaultDeck": default_deck()},
               "kind": "note", "entities": entities})
    };
    // 一条命令清两条。
    let batch = library("purge-batch");
    let before = op_count(&batch);
    let r = dispatch(&batch, request(json!(NOTES)), None);
    assert_eq!(op_count(&batch) - before, 4, "delete + purge per note: {r}");
    assert_eq!(r["purged"].as_array().unwrap().len(), 2, "{r}");
    let mut want: Vec<String> = NOTES.iter().map(|n| (*n).to_owned()).collect();
    want.sort();
    assert_eq!(purged(&batch), want);
    // 逐条发的另一台：落下的修改记录（删除标记）与清除标记相同。
    let single = library("purge-single");
    for n in NOTES {
        dispatch(&single, request(json!([n])), None);
    }
    assert_eq!(purged(&single), want);
    assert_eq!(written_edits(&batch), written_edits(&single));
    let cache = |d: &Device| {
        d.rows("SELECT COUNT(*) AS n FROM srs_cards_cache WHERE hidden = 0")[1][0].clone()
    };
    assert_eq!(cache(&batch), cache(&single));
    // 已清除过的、不存在的 ID 混在一批里：照常追加，不报错（清除标记幂等）。
    let r = dispatch(
        &batch,
        request(json!([NOTES[0], "0193a1b2-0000-7000-8000-00000000c9ff"])),
        None,
    );
    assert_eq!(purged(&batch).len(), 3, "{r}");
    // 空的一批、旧的单实体形态都报错。
    assert!(
        try_dispatch(&batch, request(json!([])), None)
            .unwrap_err()
            .contains("missing entities")
    );
    let mut old = request(json!(null));
    old["entity"] = json!(NOTES[0]);
    assert!(
        try_dispatch(&batch, old, None)
            .unwrap_err()
            .contains("missing entities")
    );
}
