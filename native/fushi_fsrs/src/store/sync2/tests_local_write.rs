//! 本机写命令（store/ffi.rs `LOCAL_WRITE_OPS`，收掉 Dart 写路径第 2 步）：命令本体、缓存行与随命令交来的本机状态行
//! （`localState`）在同一次持写锁、同一个 SAVEPOINT 里落下；中途出错三者一起回滚；外层开着 Drift 事务时嵌进那笔事务。

use serde_json::{Value, json};

use super::tests::{Device, P, deck_entity, edit};

const T0: i64 = 1_700_000_000_000;
const NT: &str = "0193a1b2-0000-7000-8000-00000000d0a1";
const NOTE: &str = "0193a1b2-0000-7000-8000-00000000d0b1";

fn caches(deck: &str) -> Value {
    json!({"defaultDeck": deck})
}

fn dispatch(d: &Device, req: Value, blob: Option<String>) -> Result<Value, String> {
    let mut blobs: Vec<Vec<u8>> = blob.into_iter().map(String::into_bytes).collect();
    let mut files = Vec::new();
    crate::store::ffi::sync2_dispatch(&d.core, &req, &mut blobs, &mut files)
}

/// 一个笔记类型 + 一条笔记（生成一张卡）的 `apply` 输入。
fn note_events(deck: &str) -> String {
    let events = vec![
        deck_entity(deck),
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
            json!({"name": "C", "ord": 0, "front": "{{Front}}"}),
        ),
        json!({"t": "entity", "x": {"id": NOTE, "p": P, "k": "note", "d": {"createdAt": 1, "guid": NOTE, "noteTypeId": NT}}}),
        edit("note", NOTE, "f/fa", json!("word")),
    ];
    Value::Array(
        events
            .into_iter()
            .map(|e| json!({"e": e, "note": null}))
            .collect(),
    )
    .to_string()
}

fn count(d: &Device, sql: &str) -> i64 {
    d.rows(sql)[1][0].parse().unwrap()
}

fn local_state(d: &Device) -> Option<Value> {
    d.rows(&format!(
        "SELECT json FROM srs_local_state WHERE profile_uid = srs_id('{P}')"
    ))
    .get(1)
    .map(|r| serde_json::from_str(&r[0]).unwrap())
}

/// 命令本体（操作日志 + 投影）、缓存行、本机状态行。
fn footprint(d: &Device) -> (i64, i64, i64, Option<Value>) {
    (
        count(d, "SELECT COUNT(*) AS n FROM sync2_ops"),
        count(d, "SELECT COUNT(*) AS n FROM srs_entities"),
        count(d, "SELECT COUNT(*) AS n FROM srs_notes_cache"),
        local_state(d),
    )
}

#[test]
fn apply_with_local_state_lands_command_caches_and_local_state_together() {
    let d = Device::new("lw-apply");
    let deck = super::config::default_deck_id(P);
    let state = json!({"revision": 5, "epoch": "e1", "hlc": "1:0:w"});
    let r = dispatch(
        &d,
        json!({"op": "apply", "profile": P, "now": T0, "caches": caches(&deck), "localState": state.to_string()}),
        Some(note_events(&deck)),
    )
    .unwrap();
    let landed = r["marks"]["landed"].as_i64().unwrap();
    let changed = r["changed"].as_array().unwrap().len() as i64;
    assert!(landed > 0, "{r}");
    let expected = 5 + landed + changed;
    assert_eq!(r["localRevision"], json!(expected), "{r}");
    let (ops, entities, notes, row) = footprint(&d);
    assert!(ops > 0 && entities > 0, "command body landed");
    assert_eq!(notes, 1, "note cache row refreshed in the same command");
    let row = row.expect("local state row written");
    assert_eq!(row["revision"], json!(expected));
    assert_eq!(row["epoch"], json!("e1"));
    assert_eq!(row["hlc"], json!("1:0:w"), "apply keeps Dart's hlc");
    // 回包照旧带缓存写入清单。
    assert!(!r["cache"]["notes"].as_array().unwrap().is_empty(), "{r}");
}

#[test]
fn a_failing_step_rolls_back_command_caches_and_local_state_together() {
    let d = Device::new("lw-fail");
    let deck = super::config::default_deck_id(P);
    let before = footprint(&d);
    // 本机状态行不是 JSON 对象：命令本体与缓存刷新都做完之后、写本机状态行时出错。
    let err = dispatch(
        &d,
        json!({"op": "apply", "profile": P, "now": T0, "caches": caches(&deck), "localState": "[1]"}),
        Some(note_events(&deck)),
    )
    .unwrap_err();
    assert!(err.contains("JSON object"), "{err}");
    assert_eq!(footprint(&d), before, "nothing of the failed command lands");
    // 写连接没有挂着半截事务：同一条命令照常能做。
    dispatch(
        &d,
        json!({"op": "apply", "profile": P, "now": T0, "caches": caches(&deck), "localState": json!({"revision": 0}).to_string()}),
        Some(note_events(&deck)),
    )
    .unwrap();
    assert_eq!(footprint(&d).2, 1);
}

#[test]
fn checkpoint_and_purge_persist_local_state_by_the_projection() {
    let d = Device::new("lw-append");
    let deck = super::config::default_deck_id(P);
    dispatch(
        &d,
        json!({"op": "apply", "profile": P, "now": T0, "caches": caches(&deck)}),
        Some(note_events(&deck)),
    )
    .unwrap();
    assert_eq!(local_state(&d), None, "no localState → no local state row");
    let r = dispatch(
        &d,
        json!({"op": "checkpoint", "profile": P, "now": T0 + 1, "caches": caches(&deck),
               "name": "m", "reason": "manual", "localState": json!({"revision": 10}).to_string()}),
        None,
    )
    .unwrap();
    let rev =
        10 + r["marks"]["landed"].as_i64().unwrap() + r["changed"].as_array().unwrap().len() as i64;
    assert_eq!(r["localRevision"], json!(rev));
    assert_eq!(local_state(&d).unwrap()["revision"], json!(rev));

    // 清除：投影变化（删除 + 清除）与本机状态行同一笔；失败时笔记仍在、本机状态行不动。
    let bad = dispatch(
        &d,
        json!({"op": "purge", "profile": P, "now": T0 + 2, "caches": caches(&deck),
               "kind": "note", "entity": NOTE, "localState": "not json"}),
        None,
    );
    assert!(bad.is_err());
    assert_eq!(
        count(
            &d,
            &format!("SELECT COUNT(*) AS n FROM srs_entities WHERE id = srs_id('{NOTE}')")
        ),
        1
    );
    assert_eq!(local_state(&d).unwrap()["revision"], json!(rev));
    let r = dispatch(
        &d,
        json!({"op": "purge", "profile": P, "now": T0 + 2, "caches": caches(&deck),
               "kind": "note", "entity": NOTE, "localState": json!({"revision": rev}).to_string()}),
        None,
    )
    .unwrap();
    let changed = r["changed"].as_array().unwrap().len() as i64;
    let rev2 = rev + r["marks"]["landed"].as_i64().unwrap() + changed;
    assert!(rev2 > rev, "{r}");
    assert_eq!(local_state(&d).unwrap()["revision"], json!(rev2));
}

#[test]
fn sched_writes_the_advanced_hlc_into_local_state() {
    let d = Device::new("lw-sched");
    let deck = super::config::default_deck_id(P);
    dispatch(
        &d,
        json!({"op": "apply", "profile": P, "now": T0, "caches": caches(&deck)}),
        Some(note_events(&deck)),
    )
    .unwrap();
    let card = d.rows(&format!(
        "SELECT srs_idt(id) AS id FROM srs_cards_cache WHERE note_id = srs_id('{NOTE}')"
    ))[1][0]
        .clone();
    let hlc = format!("{}:3:dev#1", T0 + 10);
    let r = dispatch(
        &d,
        json!({
            "op": "sched", "profile": P, "now": T0 + 5, "caches": caches(&deck),
            "at": T0 + 5, "ts": "anchored", "utcOff": 0, "rollover": 4, "hlc": hlc,
            "items": [{"a": "setDue", "card": card, "due": 20_000}],
            "localState": json!({"revision": 1, "hlc": hlc}).to_string(),
        }),
        None,
    )
    .unwrap();
    // 可信时刻早于时钟：同一物理时刻上计数 +1。
    let advanced = format!("{}:4:dev#1", T0 + 10);
    assert_eq!(r["hlc"], json!(advanced), "{r}");
    let row = local_state(&d).unwrap();
    assert_eq!(row["hlc"], json!(advanced));
    assert_eq!(row["revision"], r["localRevision"]);
}

#[test]
fn local_write_joins_an_open_drift_transaction() {
    let d = Device::new("lw-drift");
    let deck = super::config::default_deck_id(P);
    let before = footprint(&d);
    d.core.exec("BEGIN", &[], true).unwrap();
    dispatch(
        &d,
        json!({"op": "apply", "profile": P, "now": T0, "caches": caches(&deck), "localState": json!({"revision": 0}).to_string()}),
        Some(note_events(&deck)),
    )
    .unwrap();
    d.core.exec("ROLLBACK", &[], true).unwrap();
    assert_eq!(
        footprint(&d),
        before,
        "the outer Drift transaction's rollback takes the command, caches and local state with it"
    );
}
