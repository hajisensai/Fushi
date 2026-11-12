//! 归属核对（ownership.rs）：一份 srs.db 里放两个 profile，点名 A 的本机写命令给出 B 的实体 ID 时什么都不落
//! ——不追加操作、不动 B 的任何一行、A 名下也不多出指向 B 的行；自己的 ID、哪里都没有的 ID 照常。

use serde_json::{Value, json};

use super::tests::{DAY, Device, P};

/// 第二个 profile（同一份库）。
const Q: &str = "0193a1b2-0000-7000-8000-00000000cafe";
const T0: i64 = 1_700_000_000_000;

/// 一个 profile 的一小份库：默认牌组、一个笔记类型、一条笔记、它的一张卡（学过两次）。
struct Side {
    profile: &'static str,
    deck: String,
    note_type: String,
    note: String,
    card: String,
}

fn dispatch(d: &Device, req: Value, blob: Option<String>) -> Value {
    let mut blobs: Vec<Vec<u8>> = blob.into_iter().map(String::into_bytes).collect();
    let mut files = Vec::new();
    crate::store::ffi::sync2_dispatch(&d.core, &req, &mut blobs, &mut files).unwrap()
}

fn entity(profile: &str, kind: &str, id: &str, d: Value) -> Value {
    json!({"t": "entity", "x": {"id": id, "p": profile, "k": kind, "d": d}})
}

fn edit(profile: &str, kind: &str, entity: &str, key: &str, v: Value) -> Value {
    json!({"t": "edit", "x": {
        "id": "ignored", "p": profile, "k": kind, "e": entity, "f": key, "w": "dart", "s": 1,
        "ctx": {"vv": {}}, "v": v, "hlc": "0:0:dart", "ts": "anchored"
    }})
}

fn review(profile: &str, id: &str, card: &str, at: i64, rtype: &str) -> Value {
    json!({"t": "log", "x": {
        "id": id, "p": profile, "card": card, "kind": "review", "rating": 3, "hlc": format!("{at}:0:dart"), "at": at,
        "ts": "anchored", "origin": "fushi", "rtype": rtype, "utcOff": 0, "rollover": 4, "fv": 1,
        "res": {"queue": "new", "ivl": 0, "step": 0, "reps": 0, "lapses": 0, "scheduler": "fushi"}
    }})
}

/// 点名 [profile] 的 `apply`（日志的笔记按缓存行给，与生产同）。
fn apply(d: &Device, profile: &str, now: i64, events: Vec<Value>) -> Value {
    let deck = super::config::default_deck_id(profile);
    let input: Vec<Value> = events
        .into_iter()
        .map(|e| {
            let note = e["x"]["card"].as_str().and_then(|c| {
                d.rows(&format!(
                    "SELECT srs_idt(note_id) AS n FROM srs_cards_cache WHERE id = srs_id('{c}')"
                ))
                .get(1)
                .map(|r| r[0].clone())
            });
            json!({"e": e, "note": note})
        })
        .collect();
    dispatch(
        d,
        json!({"op": "apply", "profile": profile, "now": now, "caches": {"defaultDeck": deck}}),
        Some(Value::Array(input).to_string()),
    )
}

/// 点名 [profile] 的 `sched`。
fn sched(d: &Device, profile: &str, at: i64, items: Value) -> Value {
    let deck = super::config::default_deck_id(profile);
    dispatch(
        d,
        json!({
            "op": "sched", "profile": profile, "now": at, "caches": {"defaultDeck": deck},
            "at": at, "ts": "anchored", "utcOff": 0, "rollover": 4, "hlc": format!("{at}:0:dev#1"),
            "items": items,
        }),
        None,
    )
}

fn seed(d: &Device, profile: &'static str, tail: &str) -> Side {
    let deck = super::config::default_deck_id(profile);
    let note_type = format!("0193a1b2-0000-7000-8000-000000000{tail}a1");
    let note = format!("0193a1b2-0000-7000-8000-000000000{tail}b1");
    let r = apply(
        d,
        profile,
        T0,
        vec![
            entity(
                profile,
                "deck",
                &deck,
                json!({"createdAt": 1, "builtin": "default"}),
            ),
            edit(profile, "deck", &deck, "name", json!("Default")),
            entity(
                profile,
                "notetype",
                &note_type,
                json!({"createdAt": 1, "ntKind": "standard"}),
            ),
            edit(
                profile,
                "notetype",
                &note_type,
                "fieldDef/fa",
                json!({"name": "Front", "ord": 0}),
            ),
            edit(
                profile,
                "notetype",
                &note_type,
                "tmplDef/t1",
                json!({"name": "C", "ord": 0, "front": "{{Front}}"}),
            ),
            entity(
                profile,
                "note",
                &note,
                json!({"createdAt": 1, "guid": note, "noteTypeId": note_type}),
            ),
            edit(profile, "note", &note, "f/fa", json!("word")),
            edit(profile, "note", &note, "tags", json!(["mine"])),
        ],
    );
    assert_eq!(r["foreign"], json!([]), "own ids are never refused: {r}");
    let card = d.rows(&format!(
        "SELECT srs_idt(id) AS id FROM srs_cards_cache WHERE note_id = srs_id('{note}')"
    ))[1][0]
        .clone();
    let r = apply(
        d,
        profile,
        T0 + 1,
        vec![
            review(profile, &format!("{tail}-r1"), &card, T0 + 1, "learn"),
            review(profile, &format!("{tail}-r2"), &card, T0 + 600_001, "learn"),
            review(
                profile,
                &format!("{tail}-r3"),
                &card,
                T0 + 3 * DAY,
                "review",
            ),
        ],
    );
    assert_eq!(r["foreign"], json!([]), "{r}");
    Side {
        profile,
        deck,
        note_type,
        note,
        card,
    }
}

/// 整库里带归属的投影与缓存行，外加操作条数——被拒绝的写入之后这份东西一字不变。
fn state(d: &Device) -> Vec<Vec<String>> {
    let mut out = d.rows("SELECT COUNT(*) AS ops FROM sync2_ops");
    for q in [
        "SELECT srs_idt(id) AS id, srs_idt(profile_uid) AS p, payload_json FROM srs_entities ORDER BY 1",
        "SELECT srs_idt(id) AS id, srs_idt(profile_uid) AS p, json FROM srs_field_edits ORDER BY 1",
        "SELECT srs_idt(id) AS id, srs_idt(profile_uid) AS p, json FROM srs_review_logs ORDER BY 1",
        "SELECT srs_idt(id) AS id, srs_idt(profile_uid) AS p, srs_idt(note_type_id) AS nt, srs_idt(deck_id) AS deck, \
         deleted_at, sort_field, tags_json FROM srs_notes_cache ORDER BY 1",
        "SELECT srs_idt(id) AS id, srs_idt(profile_uid) AS p, srs_idt(note_id) AS note, srs_idt(deck_id) AS deck, \
         suspended, buried_until_day, flag, hidden, queue, due_day, reps, lapses, \
         srs_idt(last_log_id) AS last FROM srs_cards_cache ORDER BY 1",
    ] {
        out.extend(d.rows(q));
    }
    out
}

fn two_profiles(tag: &str) -> (Device, Side, Side) {
    let d = Device::new(tag);
    let a = seed(&d, P, "a");
    let b = seed(&d, Q, "b");
    (d, a, b)
}

/// `apply`：身份记录、修改记录（笔记 / 卡片 / 牌组 / 笔记类型 / profile）、标签、复习日志——指向 B 的每一项都在
/// 回包的 `foreign` 里、都没落；同一批里自己的那一项照常落。
#[test]
fn apply_refuses_events_that_target_another_profiles_entities() {
    let (d, a, b) = two_profiles("own-apply");
    let before = state(&d);
    let events = vec![
        // 0..=3：别人的笔记——删、改字段、改标签、重发身份记录。
        edit(a.profile, "note", &b.note, "deleted", json!(true)),
        edit(a.profile, "note", &b.note, "f/fa", json!("hijacked")),
        edit(a.profile, "note", &b.note, "tags", json!(["theirs"])),
        entity(
            a.profile,
            "note",
            &b.note,
            json!({"createdAt": 9, "guid": "g", "noteTypeId": a.note_type}),
        ),
        // 4..=5：别人的卡——搁置、作答。
        edit(a.profile, "card", &b.card, "suspended", json!(true)),
        review(a.profile, "x-r1", &b.card, T0 + 4 * DAY, "review"),
        // 6..=8：别人的牌组、笔记类型、profile 实体。
        edit(a.profile, "deck", &b.deck, "name", json!("Renamed")),
        edit(
            a.profile,
            "notetype",
            &b.note_type,
            "tmplDef/t1",
            json!({"name": "C", "ord": 0, "front": "pwned"}),
        ),
        edit(a.profile, "profile", b.profile, "rollover", json!(9)),
    ];
    let n = events.len();
    let r = apply(&d, a.profile, T0 + 4 * DAY, events);
    assert_eq!(r["foreign"], json!((0..n).collect::<Vec<usize>>()), "{r}");
    assert_eq!(r["landed"], json!(vec![false; n]), "{r}");
    assert_eq!(state(&d), before, "nothing moved, nothing appended");

    // 同一批里夹着自己的一项：别人的不落，自己的照常落。
    let r = apply(
        &d,
        a.profile,
        T0 + 4 * DAY,
        vec![
            edit(a.profile, "note", &b.note, "f/fa", json!("hijacked")),
            edit(a.profile, "note", &a.note, "f/fa", json!("mine now")),
        ],
    );
    assert_eq!(r["foreign"], json!([0]), "{r}");
    assert_eq!(r["landed"], json!([false, true]), "{r}");
    let after = state(&d);
    let moved: Vec<&Vec<String>> = after.iter().filter(|row| !before.contains(row)).collect();
    assert!(
        moved.iter().all(|row| !row.contains(&b.profile.to_owned())),
        "only A's rows moved: {moved:?}"
    );
    assert!(
        after
            .iter()
            .any(|row| row.iter().any(|v| v.contains("mine now"))),
        "A's own edit landed"
    );
    assert!(
        !after
            .iter()
            .any(|row| row.iter().any(|v| v.contains("hijacked"))),
        "B's field untouched"
    );
}

/// `sched`：别人的卡按「没有这张卡」跳过——不写日志；撤销计入撤不了的条数。自己的卡照常。
#[test]
fn sched_skips_another_profiles_cards() {
    let (d, a, b) = two_profiles("own-sched");
    let before = state(&d);
    let at = T0 + 10 * DAY;
    let r = sched(
        &d,
        a.profile,
        at,
        json!([
            {"a": "reset", "card": b.card, "skipNew": false},
            {"a": "setDue", "card": b.card, "due": 20_000},
            {"a": "undo", "card": b.card, "log": "b-r3"},
            {"a": "rescheduleDeck", "deck": b.deck},
        ]),
    );
    assert_eq!(r["logs"], json!([]), "{r}");
    assert_eq!(r["blocked"], json!(1), "{r}");
    assert_eq!(state(&d), before);

    let r = sched(
        &d,
        a.profile,
        at,
        json!([{"a": "reset", "card": a.card, "skipNew": false}]),
    );
    assert_eq!(r["logs"].as_array().unwrap().len(), 1, "own card: {r}");
}

/// 彻底清除（`purge`，经 [super::SrsCore::sync2_append]）与评分预览：别人的 ID 与不存在的 ID 同一个结果。
#[test]
fn purge_and_preview_treat_another_profiles_ids_as_absent() {
    let (d, a, b) = two_profiles("own-purge");
    let before = state(&d);
    for (kind, id) in [
        ("note", &b.note),
        ("card", &b.card),
        ("deck", &b.deck),
        ("notetype", &b.note_type),
    ] {
        dispatch(
            &d,
            json!({"op": "purge", "profile": a.profile, "now": T0 + 5 * DAY, "kind": kind, "entity": id,
                   "caches": {"defaultDeck": a.deck}}),
            None,
        );
        assert_eq!(state(&d), before, "purge {kind}");
    }

    let preview = |card: &str| -> Value {
        dispatch(
            &d,
            json!({"op": "preview", "profile": a.profile, "card": card, "now": T0 + 5 * DAY,
                   "utcOff": 0, "rollover": 4}),
            None,
        )
    };
    // 与不存在的卡同形：没有笔记、没有牌组、没有历史（新卡状态、无记忆）。评分计划里的间隔抖动按卡 ID 取种子，
    // 所以只比不随 ID 变的部分。
    let nowhere = preview("0193a1b2-0000-7000-8000-0000000dead1");
    let theirs = preview(&b.card);
    for k in ["note", "deck", "current", "memoryBefore"] {
        assert_eq!(theirs[k], nowhere[k], "{k}: {theirs}");
    }
    assert_eq!(theirs["note"], Value::Null, "{theirs}");
    assert_eq!(theirs["current"]["reps"], json!(0), "{theirs}");
    let own = preview(&a.card);
    assert_ne!(own["note"], Value::Null, "own card");
    assert_eq!(own["current"]["reps"], json!(3), "own card: {own}");
}

/// 哪里都没有的 ID 不拒绝：给还没有身份记录的实体写修改记录照旧落（换笔记类型时给还没生成的卡写血统）；落了以后
/// 它归写它的 profile，另一个 profile 再写同一个 ID 就被拒绝。
#[test]
fn unowned_ids_still_land_and_then_belong_to_their_writer() {
    let (d, a, b) = two_profiles("own-free");
    let free = "0193a1b2-0000-7000-8000-0000000f4ee1";
    let r = apply(
        &d,
        a.profile,
        T0 + DAY,
        vec![edit(a.profile, "card", free, "lineage", json!("x"))],
    );
    assert_eq!(r["foreign"], json!([]), "{r}");
    assert_eq!(r["landed"], json!([true]), "{r}");

    let before = state(&d);
    let r = apply(
        &d,
        b.profile,
        T0 + 2 * DAY,
        vec![
            edit(b.profile, "card", free, "suspended", json!(true)),
            review(b.profile, "y-r1", free, T0 + 2 * DAY, "learn"),
        ],
    );
    assert_eq!(r["foreign"], json!([0, 1]), "{r}");
    assert_eq!(state(&d), before);
}
