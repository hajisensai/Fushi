//! 本机写命令（store/ffi.rs `LOCAL_WRITE_OPS`，收掉 Dart 写路径第 2 步）：命令本体、缓存行与随命令交来的本机状态行
//! 在同一次持写锁、同一个 SAVEPOINT 里落下；中途出错三者一起回滚；外层开着 Drift 事务时嵌进那笔事务。

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

/// 直接写下本机状态行（模拟库里已有的行）。
fn seed_local_state(d: &Device, row: Value) {
    d.core
        .exec(
            "INSERT OR REPLACE INTO srs_local_state (profile_uid, json) VALUES (srs_id(?1), ?2)",
            &[
                rusqlite::types::Value::Text(P.into()),
                rusqlite::types::Value::Text(row.to_string()),
            ],
            false,
        )
        .unwrap();
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
    // 库里已有的行：修订号从它起算，纪元原样。
    seed_local_state(&d, json!({"revision": 5, "epoch": "e1"}));
    let r = dispatch(
        &d,
        json!({"op": "apply", "profile": P, "now": T0, "caches": caches(&deck), "legacyDevice": "dev",
               "anchor": {"o": 3, "b": "boot", "s": 10, "t": 20}}),
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
    assert_eq!(r["localEpoch"], json!("e1"), "{r}");
    assert_eq!(
        row["anchor"],
        json!({"o": 3, "b": "boot", "s": 10, "t": 20})
    );
    // 旧版时钟 / 写入者由命令本体写进同一行（没推进过 = 零点）。
    assert_eq!(row["hlc"], json!("0:0:dev#1"));
    assert_eq!(row["writerId"], json!("dev#1"));
    // 回包照旧带缓存写入清单。
    assert!(!r["cache"]["notes"].as_array().unwrap().is_empty(), "{r}");
}

#[test]
fn a_failing_step_rolls_back_command_caches_and_local_state_together() {
    let d = Device::new("lw-fail");
    let deck = super::config::default_deck_id(P);
    let before = footprint(&d);
    // 命令本体与缓存刷新都做完之后、写本机状态行时出错。
    super::tests::break_local_state(&d.core);
    let err = dispatch(
        &d,
        json!({"op": "apply", "profile": P, "now": T0, "caches": caches(&deck), "legacyDevice": "dev"}),
        Some(note_events(&deck)),
    )
    .unwrap_err();
    super::tests::mend_local_state(&d.core);
    assert!(err.contains("local state row refused"), "{err}");
    assert_eq!(footprint(&d), before, "nothing of the failed command lands");
    // 校时状态形态不对：在动库之前就拒绝。
    let err = dispatch(
        &d,
        json!({"op": "apply", "profile": P, "now": T0, "caches": caches(&deck), "legacyDevice": "dev", "anchor": {"o": "x"}}),
        Some(note_events(&deck)),
    )
    .unwrap_err();
    assert!(err.contains("bad anchor"), "{err}");
    assert_eq!(footprint(&d), before);
    // 写连接没有挂着半截事务：同一条命令照常能做。
    dispatch(
        &d,
        json!({"op": "apply", "profile": P, "now": T0, "caches": caches(&deck), "legacyDevice": "dev"}),
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
        json!({"op": "apply", "profile": P, "now": T0, "caches": caches(&deck), "legacyDevice": "dev"}),
        Some(note_events(&deck)),
    )
    .unwrap();
    // 第一条命令建行：缓存版本、纪元、旧版时钟 / 写入者、按这次投影推进的修订号。
    let row = local_state(&d).unwrap();
    assert_eq!(
        row["cacheRev"],
        json!(crate::store::cache_rev::CACHE_REVISION)
    );
    assert_eq!(row["hlc"], json!("0:0:dev#1"));
    assert_eq!(row["writerId"], json!("dev#1"));
    assert!(row["epoch"].is_string(), "{row}");
    let rev0 = row["revision"].as_i64().unwrap();
    assert!(rev0 > 0, "{row}");
    let r = dispatch(
        &d,
        json!({"op": "checkpoint", "profile": P, "now": T0 + 1, "caches": caches(&deck),
               "name": "m", "reason": "manual"}),
        None,
    )
    .unwrap();
    let rev = rev0
        + r["marks"]["landed"].as_i64().unwrap()
        + r["changed"].as_array().unwrap().len() as i64;
    assert_eq!(r["localRevision"], json!(rev));
    assert_eq!(local_state(&d).unwrap()["revision"], json!(rev));

    // 清除：投影变化（删除 + 清除）与本机状态行同一笔；失败时笔记仍在、本机状态行不动。
    super::tests::break_local_state(&d.core);
    let bad = dispatch(
        &d,
        json!({"op": "purge", "profile": P, "now": T0 + 2, "caches": caches(&deck),
               "kind": "note", "entity": NOTE}),
        None,
    );
    super::tests::mend_local_state(&d.core);
    assert!(bad.unwrap_err().contains("local state row refused"));
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
               "kind": "note", "entity": NOTE}),
        None,
    )
    .unwrap();
    let changed = r["changed"].as_array().unwrap().len() as i64;
    let rev2 = rev + r["marks"]["landed"].as_i64().unwrap() + changed;
    assert!(rev2 > rev, "{r}");
    assert_eq!(local_state(&d).unwrap()["revision"], json!(rev2));
}

/// 把旧版时钟拨到 [hlc]（本机状态行里的键，store/legacy_clock.rs）。
fn set_clock(d: &Device, hlc: &str) {
    d.core
        .exec(
            "INSERT OR IGNORE INTO srs_local_state (profile_uid, json) VALUES (srs_id(?1), '{}')",
            &[rusqlite::types::Value::Text(P.into())],
            false,
        )
        .unwrap();
    d.core
        .exec(
            "UPDATE srs_local_state SET json = json_set(json, '$.hlc', ?2) WHERE profile_uid = srs_id(?1)",
            &[
                rusqlite::types::Value::Text(P.into()),
                rusqlite::types::Value::Text(hlc.into()),
            ],
            false,
        )
        .unwrap();
}

#[test]
fn sched_advances_the_legacy_clock_in_local_state() {
    let d = Device::new("lw-sched");
    let deck = super::config::default_deck_id(P);
    dispatch(
        &d,
        json!({"op": "apply", "profile": P, "now": T0, "caches": caches(&deck), "legacyDevice": "dev"}),
        Some(note_events(&deck)),
    )
    .unwrap();
    let card = d.rows(&format!(
        "SELECT srs_idt(id) AS id FROM srs_cards_cache WHERE note_id = srs_id('{NOTE}')"
    ))[1][0]
        .clone();
    set_clock(&d, &format!("{}:3:dev#1", T0 + 10));
    let sched = |extra: Value| {
        let mut req = json!({
            "op": "sched", "profile": P, "now": T0 + 5, "caches": caches(&deck),
            "at": T0 + 5, "ts": "anchored", "utcOff": 0, "rollover": 4,
            "items": [{"a": "setDue", "card": card, "due": 20_000}],
        });
        for (k, v) in extra.as_object().unwrap() {
            req[k] = v.clone();
        }
        dispatch(&d, req, None)
    };
    // 宿主的设备 ID 必带。
    let err = sched(json!({})).unwrap_err();
    assert!(err.contains("legacyDevice"), "{err}");
    let r = sched(json!({"legacyDevice": "dev"})).unwrap();
    // 可信时刻早于时钟：同一物理时刻上计数 +1；日志的 HLC 就是这一步的值。
    let advanced = format!("{}:4:dev#1", T0 + 10);
    assert_eq!(r["logs"][0]["hlc"], json!(advanced), "{r}");
    assert_eq!(r.get("hlc"), None, "the clock is no longer handed back");
    let row = local_state(&d).unwrap();
    assert_eq!(row["hlc"], json!(advanced));
    assert_eq!(row["writerId"], json!("dev#1"));
    assert_eq!(row["revision"], r["localRevision"]);
}

/// `apply` 的旧版时钟指令（`clk`）：整批的收（`r`）先于任何走一步（`t`）；`t` 的日志拿到这一步的值作 HLC；`stamps`
/// 交回每项落库用的戳。
#[test]
fn apply_drives_the_legacy_clock_by_item() {
    let d = Device::new("lw-clk");
    let deck = super::config::default_deck_id(P);
    let apply = |now: i64, extra: Value, items: Value| {
        let mut req = json!({"op": "apply", "profile": P, "now": now, "caches": caches(&deck), "legacyDevice": "dev"});
        for (k, v) in extra.as_object().unwrap() {
            req[k] = v.clone();
        }
        dispatch(&d, req, Some(items.to_string()))
    };
    // 不带 `clk` 的一批：时钟不动，但行里写下零点与写入者。
    apply(
        T0,
        json!({}),
        serde_json::from_str(&note_events(&deck)).unwrap(),
    )
    .unwrap();
    assert_eq!(local_state(&d).unwrap()["hlc"], json!("0:0:dev#1"));
    let card = d.rows(&format!(
        "SELECT srs_idt(id) AS id FROM srs_cards_cache WHERE note_id = srs_id('{NOTE}')"
    ))[1][0]
        .clone();
    let log = |id: &str, hlc: Option<&str>| {
        let mut x = json!({
            "id": id, "p": P, "card": card, "kind": "review", "rating": 3, "at": T0 + 50,
            "ts": "anchored", "origin": "fushi", "rtype": "learn", "utcOff": 0, "rollover": 4, "fv": 1,
            "res": {"queue": "new", "ivl": 0, "step": 0, "reps": 0, "lapses": 0, "scheduler": "fushi"}
        });
        if let Some(h) = hlc {
            x["hlc"] = json!(h);
        }
        json!({"t": "log", "x": x})
    };
    const L1: &str = "0193a1b2-0000-7000-8000-00000000d0c1";
    const L2: &str = "0193a1b2-0000-7000-8000-00000000d0c2";
    const L3: &str = "0193a1b2-0000-7000-8000-00000000d0c3";
    // 一批里：本机新写的日志（t）、本机新写的修改记录（t）、带来源 HLC 的日志（r，远在容差之外 → 钳到
    // recvNow + 10 分钟）。收先做：两步都落在被推高的物理时间上。
    let bound = T0 + 100 + crate::store::legacy_clock::TOLERANCE_MS;
    let r = apply(
        T0 + 100,
        json!({"recvNow": T0 + 100, "tickNow": T0 + 60, "stamps": true}),
        json!([
            {"e": log(L1, None), "note": NOTE, "intent": "answer", "clk": "t"},
            {"e": edit("note", NOTE, "f/fa", json!("changed")), "note": null, "clk": "t"},
            {"e": log(L2, Some(&format!("{}:7:anki", T0 + 86_400_000))), "note": NOTE, "clk": "r"},
            {"e": deck_entity(&deck), "note": null},
        ]),
    )
    .unwrap();
    let stamps = r["stamps"].as_array().expect("stamps");
    assert_eq!(stamps.len(), 4, "{r}");
    assert_eq!(stamps[0], json!(format!("{bound}:1:dev#1")));
    assert_eq!(stamps[2], json!(format!("{}:7:anki", T0 + 86_400_000)));
    assert_eq!(stamps[3], Value::Null);
    // 修改记录的戳 = 落库的投影行（dot 是本机 v2 设备身份分配的，不是旧版写入者）。
    let me = d.core.sync2_identity(P, T0).unwrap()["device"]
        .as_str()
        .unwrap()
        .to_owned();
    assert_eq!(stamps[1]["w"], json!(me), "{r}");
    assert_eq!(stamps[1]["v"], json!("changed"));
    let stored: Value = serde_json::from_str(
        &d.rows(&format!(
            "SELECT json FROM srs_field_edits WHERE id = srs_id('{}')",
            stamps[1]["id"].as_str().unwrap()
        ))[1][0],
    )
    .unwrap();
    assert_eq!(stamps[1], stored);
    assert_eq!(
        super::tests::log_json(&d, L1)["hlc"],
        json!(format!("{bound}:1:dev#1"))
    );
    assert_eq!(
        local_state(&d).unwrap()["hlc"],
        json!(format!("{bound}:2:dev#1")),
        "one step per `t` item, edits included"
    );

    // 契约错误明确失败，时钟随命令回滚。
    let before = local_state(&d);
    for (extra, items, want) in [
        (
            json!({}),
            json!([{"e": log(L3, None), "note": NOTE, "clk": "t"}]),
            "missing tickNow",
        ),
        (
            json!({"tickNow": T0}),
            json!([{"e": log(L3, Some("1:0:x")), "note": NOTE, "clk": "r"}]),
            "missing recvNow",
        ),
        (
            json!({"tickNow": T0}),
            json!([{"e": log(L3, None), "note": NOTE, "clk": "x"}]),
            "unknown clk",
        ),
        (
            json!({"tickNow": T0}),
            json!([{"e": log(L3, Some("1:0:x")), "note": NOTE, "clk": "t", "stamped": true}]),
            "stamped",
        ),
        (
            json!({"tickNow": T0 + 9_000_000}),
            json!([
                {"e": edit("note", NOTE, "f/fa", json!("again")), "note": null, "clk": "t"},
                {"e": log(L3, None), "note": NOTE, "clk": "x"},
            ]),
            "unknown clk",
        ),
    ] {
        let err = apply(T0 + 200, extra, items).unwrap_err();
        assert!(err.contains(want), "{err}");
        assert_eq!(local_state(&d), before, "{want}");
    }
    let missing = dispatch(
        &d,
        json!({"op": "apply", "profile": P, "now": T0, "caches": caches(&deck)}),
        Some("[]".into()),
    )
    .unwrap_err();
    assert!(missing.contains("legacyDevice"), "{missing}");
}

/// 写入者：行里存过的 `writerId` 优先；没存过按 `<宿主设备>#<incarnation，缺省 1>` 拼并在第一次写入时存下；行里的
/// `hlc` 写入者与它不同就换成它（Dart 旧 `_rehome`）。`identity` 回包的 `legacyWriter` 是同一个值。
#[test]
fn the_legacy_writer_comes_from_the_row_or_the_host_device() {
    let d = Device::new("lw-writer");
    let deck = super::config::default_deck_id(P);
    let put = |json: &str| {
        d.core
            .exec(
                "DELETE FROM srs_local_state WHERE profile_uid = srs_id(?1)",
                &[rusqlite::types::Value::Text(P.into())],
                false,
            )
            .unwrap();
        d.core
            .exec(
                "INSERT INTO srs_local_state (profile_uid, json) VALUES (srs_id(?1), ?2)",
                &[
                    rusqlite::types::Value::Text(P.into()),
                    rusqlite::types::Value::Text(json.into()),
                ],
                false,
            )
            .unwrap();
    };
    let writer = |device: &str| {
        dispatch(
            &d,
            json!({"op": "identity", "profile": P, "now": T0, "legacyDevice": device}),
            None,
        )
        .unwrap()["legacyWriter"]
            .clone()
    };
    let touch = |device: &str| {
        dispatch(
            &d,
            json!({"op": "apply", "profile": P, "now": T0, "caches": caches(&deck), "legacyDevice": device}),
            Some("[]".into()),
        )
        .unwrap();
        local_state(&d).unwrap()
    };
    // 没有行：按宿主设备拼；不带设备的 `identity` 不回这一项。
    assert_eq!(writer("devA"), json!("devA#1"));
    assert_eq!(
        dispatch(&d, json!({"op": "identity", "profile": P, "now": T0}), None)
            .unwrap()
            .get("legacyWriter"),
        None
    );
    let row = touch("devA");
    assert_eq!(row["writerId"], json!("devA#1"));
    assert_eq!(row["hlc"], json!("0:0:devA#1"));
    assert_eq!(
        row.get("incarnation"),
        None,
        "a new row has none of the frozen keys: {row}"
    );
    assert_eq!(row.get("lastSeq"), None, "{row}");
    // 存过之后宿主设备 ID 变了也不换。
    assert_eq!(writer("devB"), json!("devA#1"));
    assert_eq!(touch("devB")["writerId"], json!("devA#1"));
    // 存量行：旧版 Dart 写下的键原样留着；`hlc` 的写入者换成本机写入者。
    put(
        r#"{"incarnation":3,"lastSeq":41,"applied":{"vv":{"devA#3":41}},"outboxSeq":7,"hlc":"1700000000000:4:someone-else","revision":8}"#,
    );
    assert_eq!(writer("devA"), json!("devA#3"));
    let row = touch("devA");
    assert_eq!(row["writerId"], json!("devA#3"));
    assert_eq!(row["hlc"], json!("1700000000000:4:devA#3"));
    assert_eq!(row["incarnation"], json!(3));
    assert_eq!(row["lastSeq"], json!(41));
    assert_eq!(row["applied"], json!({"vv": {"devA#3": 41}}));
    assert_eq!(row["outboxSeq"], json!(7));
    assert_eq!(row["revision"], json!(8), "an empty apply does not move it");
    // 损坏的时钟：写入明确失败、什么都不落；认写入者不受影响。
    put(r#"{"writerId":"devA#1","hlc":"garbage"}"#);
    assert_eq!(writer("devA"), json!("devA#1"));
    let before = footprint(&d);
    let err = dispatch(
        &d,
        json!({"op": "apply", "profile": P, "now": T0, "caches": caches(&deck), "legacyDevice": "devA"}),
        Some(note_events(&deck)),
    )
    .unwrap_err();
    assert!(err.contains("stored legacy clock"), "{err}");
    assert_eq!(footprint(&d), before);
}

#[test]
fn local_write_joins_an_open_drift_transaction() {
    let d = Device::new("lw-drift");
    let deck = super::config::default_deck_id(P);
    let before = footprint(&d);
    d.core.exec("BEGIN", &[], true).unwrap();
    dispatch(
        &d,
        json!({"op": "apply", "profile": P, "now": T0, "caches": caches(&deck), "legacyDevice": "dev"}),
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

#[test]
fn trust_persists_local_state_in_its_savepoint_and_rolls_back_with_it() {
    let d = Device::new("lw-trust");
    let deck = super::config::default_deck_id(P);
    dispatch(
        &d,
        json!({"op": "apply", "profile": P, "now": T0, "caches": caches(&deck), "legacyDevice": "dev"}),
        Some(note_events(&deck)),
    )
    .unwrap();
    // 从没见过的设备本来就可信：信任一次什么也不放行，修订号不动（回包照样带当前值）。
    let rev = local_state(&d).unwrap()["revision"].clone();
    let other = "0193a1b2-0000-7000-8000-00000000dee1";
    let r = dispatch(
        &d,
        json!({"op": "trust", "profile": P, "now": T0 + 1, "caches": caches(&deck),
               "device": other, "trust": true}),
        None,
    )
    .unwrap();
    assert_eq!(r["released"], json!(0), "{r}");
    assert_eq!(r["localRevision"], rev, "{r}");
    assert_eq!(local_state(&d).unwrap()["revision"], rev);
    // 命令本体出错（信任本机自己）：本机状态行不动。
    let me = d.core.sync2_identity(P, T0).unwrap()["device"]
        .as_str()
        .unwrap()
        .to_owned();
    let err = dispatch(
        &d,
        json!({"op": "trust", "profile": P, "now": T0 + 2, "caches": caches(&deck),
               "device": me, "trust": true}),
        None,
    )
    .unwrap_err();
    assert!(err.contains("always trusted"), "{err}");
    assert_eq!(local_state(&d).unwrap()["revision"], rev);
}

/// `import_drafts`（收掉 Dart 写路径第 8 步）：「初值」项在它的（类别, 实体, 字段键）已有修改记录时不落、旧版时钟不走；
/// 判据是这一批落库之前的库。回包带落库前就已存在的实体。
#[test]
fn import_drafts_drops_authored_initials_and_reports_existing_entities() {
    const NEW: &str = "0193a1b2-0000-7000-8000-00000000d0b2";
    let d = Device::new("lw-import-drafts");
    let deck = super::config::default_deck_id(P);
    dispatch(
        &d,
        json!({
            "op": "apply", "profile": P, "now": T0, "caches": caches(&deck),
            "legacyDevice": "dev",
        }),
        Some(note_events(&deck)),
    )
    .unwrap();
    let draft = |entity: &str, key: &str, v: Value, init: bool| {
        let mut it = json!({
            "e": {"t": "edit", "x": {"p": P, "k": "note", "e": entity, "f": key, "v": v, "ts": "anchored"}},
            "note": null, "clk": "t",
        });
        if init {
            it["init"] = json!(true);
        }
        it
    };
    let entity = |id: &str| {
        json!({
            "e": {"t": "entity", "x": {"id": id, "p": P, "k": "note", "d": {"createdAt": 2, "guid": id, "noteTypeId": NT}}},
            "note": null,
        })
    };
    let input = Value::Array(vec![
        entity(NOTE),
        entity(NEW),
        // 已有记录的键：初值不落。
        draft(NOTE, "f/fa", json!("stale"), true),
        // 同一实体上还没有记录的键：落。
        draft(NOTE, "deck", json!(deck), true),
        // 新实体：同一批里先落的项不算「已有」，两条初值都落。
        draft(NEW, "f/fa", json!("first"), true),
        draft(NEW, "f/fa", json!("second"), true),
        // 不是初值的照常落。
        draft(NOTE, "f/fb", json!("edited"), false),
    ]);
    // 某实体某字段键的生效值（投影里被支配的记录已删，每键至多一条）。
    let value = |entity: &str, key: &str| -> Value {
        let rows = d.rows(&format!(
            "SELECT json FROM srs_field_edits WHERE entity_id = srs_id('{entity}') AND field_key = '{key}'"
        ));
        assert_eq!(rows.len(), 2, "one live edit on {entity} {key}: {rows:?}");
        serde_json::from_str::<Value>(&rows[1][0]).unwrap()["v"].clone()
    };
    assert_eq!(value(NOTE, "f/fa"), json!("word"));
    let r = dispatch(
        &d,
        json!({
            "op": "import_drafts", "profile": P, "now": T0 + 10, "caches": caches(&deck),
            "legacyDevice": "dev", "recvNow": T0 + 10, "tickNow": T0 + 10,
        }),
        Some(input.to_string()),
    )
    .unwrap();
    assert_eq!(r["existed"], json!([NOTE]), "{r}");
    assert!(r["localRevision"].is_i64(), "{r}");
    // 六项进了 `apply`（一条初值被去掉）；新实体与四条修改记录都落下。
    let landed = r["landed"].as_array().unwrap();
    assert_eq!(landed.len(), 6, "{r}");
    assert!(landed[1..].iter().all(|l| *l == json!(true)), "{r}");
    assert_eq!(
        value(NOTE, "f/fa"),
        json!("word"),
        "the stale initial did not land"
    );
    assert_eq!(value(NOTE, "deck"), json!(deck));
    assert_eq!(value(NEW, "f/fa"), json!("second"));
    assert_eq!(value(NOTE, "f/fb"), json!("edited"));
    // 旧版时钟：落下的四条修改记录各走一步（同一时刻：计数器 0..3），去掉的那条不走。
    assert_eq!(
        local_state(&d).unwrap()["hlc"],
        json!(format!("{}:3:dev#1", T0 + 10))
    );
    // `apply` 不看 `init`（本机编辑照常覆盖）。
    let r = dispatch(
        &d,
        json!({
            "op": "apply", "profile": P, "now": T0 + 20, "caches": caches(&deck),
            "legacyDevice": "dev", "tickNow": T0 + 20,
        }),
        Some(Value::Array(vec![draft(NOTE, "f/fa", json!("again"), true)]).to_string()),
    )
    .unwrap();
    assert_eq!(r.get("existed"), None);
    assert_eq!(value(NOTE, "f/fa"), json!("again"));
}

/// `apply` 的前置条件 `expectLast`（远程作答核对基准）：核对与落库在同一笔里；不成立时什么都不做——不落、旧版时钟
/// 不走、不排队、不写本机状态行，回包只有 `stale`。
#[test]
fn apply_checks_expect_last_before_anything_lands() {
    let d = Device::new("lw-expect");
    let deck = super::config::default_deck_id(P);
    dispatch(
        &d,
        json!({"op": "apply", "profile": P, "now": T0, "caches": caches(&deck), "legacyDevice": "dev"}),
        Some(note_events(&deck)),
    )
    .unwrap();
    let card = d.rows(&format!(
        "SELECT srs_idt(id) AS id FROM srs_cards_cache WHERE note_id = srs_id('{NOTE}')"
    ))[1][0]
        .clone();
    let answer = |log: &str, at: i64, expect: Value| {
        let x = json!({
            "id": log, "p": P, "card": card, "kind": "review", "rating": 3, "at": at,
            "ts": "anchored", "origin": "fushi", "rtype": "learn", "utcOff": 0, "rollover": 4, "fv": 1,
            "res": {"queue": "new", "ivl": 0, "step": 0, "reps": 0, "lapses": 0, "scheduler": "fushi"}
        });
        dispatch(
            &d,
            json!({
                "op": "apply", "profile": P, "now": at, "caches": caches(&deck), "legacyDevice": "dev",
                "tickNow": at, "stamps": true, "expectLast": expect,
            }),
            Some(
                json!([{"e": {"t": "log", "x": x}, "note": NOTE, "intent": "answer", "clk": "t"}])
                    .to_string(),
            ),
        )
        .unwrap()
    };
    const L1: &str = "0193a1b2-0000-7000-8000-00000000d0e1";
    const L2: &str = "0193a1b2-0000-7000-8000-00000000d0e2";
    const GONE: &str = "0193a1b2-0000-7000-8000-00000000d0ef";
    // 还没有日志：基准 null 成立。
    let r = answer(L1, T0 + 10, json!({"card": card, "log": null}));
    assert!(r.get("stale").is_none(), "{r}");
    assert_eq!(r["stamps"].as_array().unwrap().len(), 1, "{r}");
    let before = (
        count(&d, "SELECT COUNT(*) AS n FROM sync2_ops"),
        local_state(&d),
    );
    // 出题之后这张卡又被作答过（基准还是 null）、基准是别的日志、卡不存在：都不成立。
    for expect in [
        json!({"card": card, "log": null}),
        json!({"card": card, "log": L2}),
        json!({"card": GONE, "log": null}),
    ] {
        let r = answer(L2, T0 + 20, expect);
        assert_eq!(r, json!({"stale": true}));
        assert_eq!(count(&d, "SELECT COUNT(*) AS n FROM sync2_ops"), before.0);
        assert_eq!(local_state(&d), before.1);
    }
    // 基准是它最后一条日志：成立。
    let r = answer(L2, T0 + 20, json!({"card": card, "log": L1}));
    assert!(r.get("stale").is_none(), "{r}");
    assert_eq!(
        count(&d, "SELECT COUNT(*) AS n FROM sync2_ops"),
        before.0 + 1
    );
}
