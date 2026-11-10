//! 本机手动排程命令 `sched`（sched_local.rs）：显式意图写出的日志与旧路径（Dart 组好日志、内核按结果形状反推意图）
//! 落出同样的投影、同样的意图、同样的缓存行；撤销只认最后一条有效日志；HLC 按 Dart 时钟的规则推进。

use serde_json::{Value, json};

use super::tests::{Bucket, DAY, Device, P, deck_entity, edit, log_json, review};

const T0: i64 = 1_700_000_000_000;
const NT: &str = "0193a1b2-0000-7000-8000-00000000c0a1";
const NOTES: [&str; 3] = [
    "0193a1b2-0000-7000-8000-00000000c0b1",
    "0193a1b2-0000-7000-8000-00000000c0b2",
    "0193a1b2-0000-7000-8000-00000000c0b3",
];
const WRITER: &str = "dev#1";

fn caches(deck: &str) -> Value {
    json!({"defaultDeck": deck})
}

/// 经 FFI 分发器发一条命令（与生产同一条路径：改投影的命令在同一次调用里刷新缓存）。
fn dispatch(d: &Device, req: Value, blob: Option<String>) -> Value {
    let mut blobs: Vec<Vec<u8>> = blob.into_iter().map(String::into_bytes).collect();
    let mut files = Vec::new();
    crate::store::ffi::sync2_dispatch(&d.core, &req, &mut blobs, &mut files).unwrap()
}

/// 旧路径：Dart 组好的事件交给 `apply`（日志的笔记按缓存行给）。
fn apply(d: &Device, deck: &str, now: i64, events: Vec<Value>) -> Value {
    let input: Vec<Value> = events
        .into_iter()
        .map(|e| {
            let note = e["x"]["card"].as_str().and_then(|c| note_of(d, c));
            json!({"e": e, "note": note})
        })
        .collect();
    dispatch(
        d,
        json!({"op": "apply", "profile": P, "now": now, "caches": caches(deck)}),
        Some(Value::Array(input).to_string()),
    )
}

/// 新路径：显式意图命令。
fn sched(d: &Device, deck: &str, at: i64, hlc: &str, items: Value) -> Value {
    dispatch(
        d,
        json!({
            "op": "sched", "profile": P, "now": at, "caches": caches(deck),
            "at": at, "ts": "anchored", "utcOff": 0, "rollover": 4, "hlc": hlc, "items": items,
        }),
        None,
    )
}

fn note_of(d: &Device, card: &str) -> Option<String> {
    d.rows(&format!(
        "SELECT srs_idt(note_id) AS n FROM srs_cards_cache WHERE id = srs_id('{card}')"
    ))
    .get(1)
    .map(|r| r[0].clone())
}

/// 三条笔记各一张卡；前两张学过（毕业进复习队列），第三张是新卡。返回 (设备, 默认牌组, 卡 ID 按笔记顺序)。
fn library(tag: &str) -> (Device, String, Vec<String>) {
    let d = Device::new(tag);
    let deck = super::config::default_deck_id(P);
    let mut events = vec![
        deck_entity(&deck),
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
    ];
    for (i, n) in NOTES.iter().enumerate() {
        events.push(json!({"t": "entity", "x": {"id": n, "p": P, "k": "note", "d": {"createdAt": 1, "guid": n, "noteTypeId": NT}}}));
        events.push(edit("note", n, "f/fa", json!(format!("word{i}"))));
    }
    apply(&d, &deck, T0, events);
    let cards: Vec<String> = NOTES
        .iter()
        .map(|n| {
            d.rows(&format!(
                "SELECT srs_idt(id) AS id FROM srs_cards_cache WHERE note_id = srs_id('{n}')"
            ))[1][0]
                .clone()
        })
        .collect();
    for (k, c) in cards.iter().take(2).enumerate() {
        apply(
            &d,
            &deck,
            T0 + 1,
            vec![
                review(&format!("r{k}a"), c, T0 + 1, 3, "learn"),
                review(&format!("r{k}b"), c, T0 + 600_001, 3, "learn"),
                review(&format!("r{k}c"), c, T0 + 3 * DAY, 3, "review"),
            ],
        );
    }
    (d, deck, cards)
}

fn ids(r: &Value) -> Vec<String> {
    r["logs"]
        .as_array()
        .unwrap()
        .iter()
        .map(|l| l["id"].as_str().unwrap().to_owned())
        .collect()
}

/// 旧形态：Dart 组好的日志事件（无配置快照，结果只是提示）。
fn legacy_event(log: &Value) -> Value {
    let mut x = log.clone();
    x.as_object_mut().unwrap().remove("sc");
    json!({"t": "log", "x": x})
}

fn review_logs(d: &Device) -> Vec<Vec<String>> {
    d.rows("SELECT srs_idt(id) AS id, json FROM srs_review_logs ORDER BY id")
}

fn intents(d: &Device) -> Vec<Vec<String>> {
    d.rows("SELECT srs_idt(log_id) AS id, intent, arg FROM sync2_log_meta ORDER BY 1")
}

fn cache_rows(d: &Device) -> Vec<Vec<String>> {
    d.rows(
        "SELECT srs_idt(id) AS id, queue, due_day, scheduled_days, reps, lapses, stability, difficulty, \
         last_reviewed_at, srs_idt(last_log_id) AS last FROM srs_cards_cache ORDER BY 1",
    )
}

/// 同一批操作：新路径（显式意图命令）与旧路径（Dart 组好日志、按结果形状反推意图）落出的日志行、意图、缓存行
/// 逐位相同；旧路径给的结果提示错了也不作数（重放按意图重算）。收到新路径操作的设备重放出同样的投影。
#[test]
fn explicit_intents_match_the_legacy_inferred_path() {
    let (b, deck, cards) = library("sched-new");
    let (a, _, cards_a) = library("sched-old");
    assert_eq!(cards, cards_a);
    let at = T0 + 10 * DAY;
    let today = crate::projection::Day {
        utc_offset_min: 0,
        rollover_hour: 4,
    }
    .index(at);

    // 新路径：立即重排整组 → 改到期 → 忘记（新卡跳过）→ 撤销刚才的忘记。
    let hlc0 = format!("{}:0:{WRITER}", T0 + 5 * DAY);
    let r1 = sched(
        &b,
        &deck,
        at,
        &hlc0,
        json!([{"a": "rescheduleDeck", "deck": deck}]),
    );
    assert_eq!(
        r1["logs"].as_array().unwrap().len(),
        2,
        "only the two review cards: {r1}"
    );
    let h1 = r1["hlc"].as_str().unwrap().to_owned();
    assert_eq!(h1, format!("{at}:1:{WRITER}"));
    let r2 = sched(
        &b,
        &deck,
        at,
        &h1,
        json!([{"a": "setDue", "card": cards[1], "due": today + 7}]),
    );
    let r3 = sched(
        &b,
        &deck,
        at,
        r2["hlc"].as_str().unwrap(),
        json!([
            {"a": "reset", "card": cards[0], "skipNew": true},
            {"a": "reset", "card": cards[2], "skipNew": true},
        ]),
    );
    assert_eq!(r3["logs"].as_array().unwrap().len(), 1, "new card skipped");
    let reset = ids(&r3)[0].clone();
    let r4 = sched(
        &b,
        &deck,
        at,
        r3["hlc"].as_str().unwrap(),
        json!([
            {"a": "undo", "card": cards[0], "log": reset},
            {"a": "undo", "card": cards[1], "log": "r1a"},
        ]),
    );
    assert_eq!(
        r4["blocked"],
        json!(1),
        "only the last effective log can be undone"
    );
    assert_eq!(r4["logs"].as_array().unwrap().len(), 1);
    assert_eq!(r4["logs"][0]["revokes"], json!(reset));
    assert_eq!(
        log_json(&b, &ids(&r2)[0])["res"]["dueDay"],
        json!(today + 7)
    );

    // 旧路径：同样的日志（同 ID / HLC / 时刻）由 Dart 组好交给 apply；立即重排的结果提示故意写错。
    for r in [&r1, &r2, &r3, &r4] {
        let events: Vec<Value> = r["logs"]
            .as_array()
            .unwrap()
            .iter()
            .map(|l| {
                let mut e = legacy_event(l);
                if l["kind"] == json!("reschedule") {
                    e["x"]["res"]["dueDay"] = json!(today + 1000);
                }
                e
            })
            .collect();
        apply(&a, &deck, at, events);
    }

    // 修改记录的 dot 带各自的设备 ID，只比日志行（含重放写回的结果与配置快照）、意图与缓存行。
    assert_eq!(review_logs(&a), review_logs(&b));
    assert_eq!(intents(&a), intents(&b));
    assert_eq!(cache_rows(&a), cache_rows(&b));
    let codes: Vec<(String, String)> = intents(&b)
        .into_iter()
        .skip(1)
        .map(|r| (r[1].clone(), r[2].clone()))
        .collect();
    assert!(
        codes.contains(&("4".into(), "NULL".into())),
        "reschedule intent: {codes:?}"
    );
    assert!(
        codes.contains(&("2".into(), (today + 7).to_string())),
        "setDue intent: {codes:?}"
    );
    assert!(
        codes.contains(&("3".into(), "NULL".into())),
        "reset intent: {codes:?}"
    );

    // 收到这些操作的设备按操作里的意图重放，日志行逐位相同。
    let mut bucket = Bucket::default();
    b.sync(&mut bucket, "loc", at);
    let c = Device::new("sched-recv");
    c.sync(&mut bucket, "loc", at);
    assert_eq!(review_logs(&c), review_logs(&b));
}

/// 无条件重置（单卡入口）照写新卡；同一批里后面的项看得见前面写的日志（撤销同批刚写的改期）；HLC 落后于时刻时
/// 从时刻起算、计数归零。
#[test]
fn single_card_reset_and_in_batch_visibility() {
    let (d, deck, cards) = library("sched-batch");
    let at = T0 + 10 * DAY;
    let r = sched(
        &d,
        &deck,
        at,
        &format!("{}:9:{WRITER}", at + 5),
        json!([{"a": "reset", "card": cards[2]}]),
    );
    assert_eq!(r["logs"].as_array().unwrap().len(), 1);
    assert_eq!(
        r["hlc"],
        json!(format!("{}:10:{WRITER}", at + 5)),
        "clock ahead of now keeps counting"
    );
    let first = ids(&r)[0].clone();
    let r = sched(
        &d,
        &deck,
        at + DAY,
        &format!("{}:10:{WRITER}", at + 5),
        json!([
            {"a": "undo", "card": cards[2], "log": first},
            {"a": "setDue", "card": cards[0], "due": 1},
        ]),
    );
    assert_eq!(r["blocked"], json!(0));
    assert_eq!(r["hlc"], json!(format!("{}:1:{WRITER}", at + DAY)));
    let set = ids(&r)[1].clone();
    let r = sched(
        &d,
        &deck,
        at + DAY,
        r["hlc"].as_str().unwrap(),
        json!([{"a": "undo", "card": cards[0], "log": set}, {"a": "undo", "card": cards[0], "log": set}]),
    );
    assert_eq!(
        r["blocked"],
        json!(1),
        "the second undo sees the first in the same batch"
    );
    let none = sched(
        &d,
        &deck,
        at + DAY,
        "0:0:w",
        json!([{"a": "reset", "card": cards[2], "skipNew": true}]),
    );
    assert_eq!(none["logs"], json!([]));
    assert_eq!(none["hlc"], Value::Null, "nothing written, clock untouched");
}
