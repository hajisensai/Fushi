//! 读命令按类（D24）的逻辑：新代单侧断言（协议 3 没有别名类，对拍装置 `tests.rs` 的库只有单成员的类）。
//!
//! 场景：同一条笔记（guid `g`）在两个盐下各一份——笔记类型、字段、模板、笔记、卡、同一次 Anki 复习的导入日志都各有
//! 一份带盐 ID，规范 ID 是不带盐的同一套；两台设备互不相见地各改一份的同一字段（类里冲突、按原值各自没有冲突）；
//! 一条被并发改动扣住删除的笔记（待裁决）；一条 `LegacyUnknown`；同一个文件里绑着的第二个集合。另有几个只验
//! `has_user_data` 口径与读命令代价的小场景。

use std::collections::BTreeSet;

use serde_json::{Value, json};

use super::Files;
use super::history::history;
use super::reads;
use super::tests::decode;
use crate::gen4::op::tests::{id, native_edit};
use crate::gen4::op::{Body4, Edit4, Log4};
use crate::gen4_ids::rules::{self, CANONICAL};
use crate::store::gen4::cache::CFG_KEY;
use crate::store::gen4::derive::Index;
use crate::store::gen4::derive::tests::{assert_rebuild_is_identity, heritage, native, op, with};
use crate::store::gen4::truth::{TRUST_PENDING, Truth};
use crate::sync2::id::{Id, Key};
use crate::sync2::op::{EntKind, Intent};

const U1: &str = "0192f0aa-0000-7000-8000-00000000000a";
const U2: &str = "0192f0aa-0000-7000-8000-00000000000b";
const ANKI_NT: i64 = 1_700_000_000_001;
const ANKI_REVLOG: i64 = 1_650_000_000_123;
const DECK: u8 = 0x0d;
/// 待裁决的那条笔记。
const HELD: u8 = 0x4e;
const P2: &str = "0193a1b2-0000-7000-8000-0000000000f2";
const ST: i64 = 1_650_000_009_000;

fn entity(kind: EntKind, key: Key, data: Value) -> Body4 {
    Body4::Entity {
        kind,
        id: key,
        data: data.to_string(),
    }
}

fn set(kind: EntKind, entity: Key, key: &str, value: Value) -> Body4 {
    Body4::Edit(Edit4 {
        kind,
        entity,
        key: key.to_owned(),
        value: value.to_string(),
        ..native_edit()
    })
}

fn u(i: Id) -> Key {
    Key::Uuid(i)
}

/// 两份带盐的笔记，连同它们规范的那一套。
struct Twin {
    nt: [Id; 2],
    field: [Id; 2],
    tmpl: [Id; 2],
    note: [Id; 2],
    card: [Id; 2],
    log: [Id; 2],
    c_field: Id,
    c_note: Id,
    c_card: Id,
    c_log: Id,
}

fn twin() -> Twin {
    let nt = [
        rules::note_type(Some(U1), ANKI_NT),
        rules::note_type(Some(U2), ANKI_NT),
    ];
    let field = [rules::field(&nt[0], 0), rules::field(&nt[1], 0)];
    let tmpl = [rules::template(&nt[0], 0), rules::template(&nt[1], 0)];
    let note = [rules::note(Some(U1), "g"), rules::note(Some(U2), "g")];
    let card = [
        rules::card(&note[0], &tmpl[0], 0),
        rules::card(&note[1], &tmpl[1], 0),
    ];
    let c_nt = rules::note_type(CANONICAL, ANKI_NT);
    let c_note = rules::note(CANONICAL, "g");
    let c_card = rules::card(&c_note, &rules::template(&c_nt, 0), 0);
    Twin {
        log: [
            rules::imported_revlog(&card[0], ANKI_REVLOG),
            rules::imported_revlog(&card[1], ANKI_REVLOG),
        ],
        nt,
        field,
        tmpl,
        note,
        card,
        c_field: rules::field(&c_nt, 0),
        c_note,
        c_card,
        c_log: rules::imported_revlog(&c_card, ANKI_REVLOG),
    }
}

/// 同一次 Anki 复习落在卡 [card] 上的导入日志 [lid]（[st] = 承袭来的服务器时刻）。
fn anki_log(lid: Id, card: Id, st: Option<i64>) -> Body4 {
    Body4::Log(Log4 {
        id: u(lid),
        card: u(card),
        note: None,
        kind: "review".into(),
        rating: Some(3),
        revokes: None,
        at: ANKI_REVLOG,
        ts: 2,
        origin: "anki".into(),
        rtype: "review".into(),
        dur: 5000,
        params: None,
        alg: Some("anki".into()),
        utc_off: 0,
        rollover: 4,
        anki_id: Some(ANKI_REVLOG),
        fv: 1,
        intent: Intent::Absolute,
        res: Some(
            json!({"queue": "review", "ivl": 3, "step": 0, "reps": 1, "lapses": 0, "scheduler": "fushi",
                   "dueDay": 1})
            .to_string(),
        ),
        extra: "{}".into(),
        hlc: None,
        server_time: st,
    })
}

/// 设备 0xa1 写的身份与定义。
fn base_ops(w: &Twin) -> Vec<Body4> {
    let mut out = vec![
        Body4::salts([U1, U2]).unwrap(),
        entity(
            EntKind::Deck,
            u(id(DECK)),
            json!({"createdAt": 1, "builtin": "default"}),
        ),
    ];
    for i in 0..2 {
        out.push(entity(
            EntKind::NoteType,
            u(w.nt[i]),
            json!({"createdAt": 1, "ntKind": "standard", "ankiNum": ANKI_NT}),
        ));
        out.push(set(
            EntKind::NoteType,
            u(w.nt[i]),
            &format!("fieldDef/{}", w.field[i].text()),
            json!({"ankiNum": 0, "name": "E", "ord": 0}),
        ));
        out.push(set(
            EntKind::NoteType,
            u(w.nt[i]),
            &format!("tmplDef/{}", w.tmpl[i].text()),
            json!({"ankiNum": 0, "name": "A", "ord": 0, "front": "{{E}}"}),
        ));
        out.push(entity(
            EntKind::Note,
            u(w.note[i]),
            json!({"createdAt": 1, "guid": "g", "noteTypeId": w.nt[i].text()}),
        ));
    }
    // 同一次 Anki 复习的第二份（落在第二份带盐的卡上）；第一份是承袭来的（[land]）。
    out.push(anki_log(w.log[1], w.card[1], None));
    // 待裁决的笔记。
    out.push(entity(
        EntKind::Note,
        u(id(HELD)),
        json!({"createdAt": 2, "guid": "h", "noteTypeId": w.nt[0].text()}),
    ));
    out.push(Body4::LegacyUnknown {
        json: json!({"t": "future", "x": {"id": "u-1", "p": "x"}}).to_string(),
    });
    out
}

/// 灌进集合 [col]：0xa1 的定义，再 0xb1 / 0xb2 互不相见地各改一份的同一字段，0xc1 删待裁决的笔记、0xc2 没见过这条删除
/// 就改它的字段（删除被扣住）。返回场景。
fn land(t: &Truth<'_>, col: i64) -> Twin {
    let w = twin();
    let cfg = json!({"defaultDeck": id(DECK).text()}).to_string();
    t.tx(|t| {
        t.set_derive_cfg(col, CFG_KEY, Some(&cfg))?;
        let mut ix = Index::new(t, col);
        // 同一次 Anki 复习的第一份：承袭来的（带服务器时刻；设备号小，是这条日志的代表）。
        heritage(
            t,
            &mut ix,
            col,
            op(0x11, 1, 90, &[], &anki_log(w.log[0], w.card[0], Some(ST))),
        );
        let base = base_ops(&w);
        let last = base.len() as u64;
        for (i, b) in base.iter().enumerate() {
            native(
                t,
                &mut ix,
                col,
                &op(0xa1, i as u64 + 1, 100 + i as i64, &[], b),
            );
        }
        let seen = [(0xa1, last)];
        let field = |i: usize| format!("f/{}", w.field[i].text());
        let a = set(EntKind::Note, u(w.note[0]), &field(0), json!("A"));
        let b = set(EntKind::Note, u(w.note[1]), &field(1), json!("B"));
        native(t, &mut ix, col, &op(0xb1, 1, 300, &seen, &a));
        native(t, &mut ix, col, &op(0xb2, 1, 301, &seen, &b));
        let del = set(EntKind::Note, u(id(HELD)), "deleted", json!(400));
        let late = set(EntKind::Note, u(id(HELD)), &field(0), json!("late"));
        native(t, &mut ix, col, &op(0xc1, 1, 400, &seen, &del));
        native(t, &mut ix, col, &op(0xc2, 1, 401, &seen, &late));
        ix.settle()?;
        Ok(())
    })
    .unwrap();
    w
}

fn read(t: &Truth<'_>, col: i64, req: Value) -> (Value, Vec<Vec<String>>) {
    let mut files = Files::new();
    let v = reads::run(t, col, &req, &mut files).unwrap();
    assert!(t.conn().is_autocommit());
    let rows = files.first().map_or_else(Vec::new, |(_, b)| decode(b).1);
    (v, rows)
}

fn col_of(rows: &[Vec<String>], i: usize) -> Vec<String> {
    rows.iter().map(|r| r[i].clone()).collect()
}

/// 修改历史的 (键, 值) 多重集（时间、作者不比）。
fn history_pairs(t: &Truth<'_>, col: i64, entity: &str) -> Vec<String> {
    let v = history(t, col, EntKind::Note, entity).unwrap();
    let mut out: Vec<String> = v
        .as_array()
        .unwrap()
        .iter()
        .map(|e| {
            format!(
                "{}={}",
                e["key"],
                e.get("value").cloned().unwrap_or(Value::Null)
            )
        })
        .collect();
    out.sort();
    out
}

#[test]
fn conflicts_across_alias_members_are_found_through_the_alias_branch() {
    with(|t, col| {
        let w = land(t, col);
        // 按原值，两份各自只有一条写入（胜者，不是冲突）：只有按类才看得出冲突。
        let raw: i64 = t
            .conn()
            .query_row(
                "SELECT COUNT(*) FROM reg_ix WHERE col = ?1 AND state = 3",
                [col],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(raw, 0, "no raw conflict");
        let rules = json!([{"kind": "note", "drop": []}]);
        let (_, rows) = read(t, col, json!({"q": "conflict_edits", "rules": rules}));
        let c_key = format!("f/{}", w.c_field.text());
        assert_eq!(rows.len(), 2, "{rows:?}");
        for r in &rows {
            assert_eq!(
                (r[0].as_str(), r[1].as_str(), r[2].as_str()),
                ("note", w.c_note.text().as_str(), c_key.as_str())
            );
        }
        let vals: BTreeSet<String> = rows
            .iter()
            .map(|r| serde_json::from_str::<Value>(&r[3]).unwrap()["v"].to_string())
            .collect();
        assert_eq!(
            vals,
            BTreeSet::from(["\"A\"".to_owned(), "\"B\"".to_owned()])
        );
        // 点名一份成员也一样（先归一）。
        let (_, one) = read(
            t,
            col,
            json!({"q": "conflict_edits", "rules": rules, "kind": "note", "id": w.note[1].text()}),
        );
        assert_eq!(one, rows);
        assert_rebuild_is_identity(t, col);
    });
}

#[test]
fn logs_by_time_give_one_representative_per_class() {
    with(|t, col| {
        let w = land(t, col);
        let raw: i64 = t
            .conn()
            .query_row(
                "SELECT COUNT(*) FROM log_ix WHERE col = ?1 AND at = ?2",
                rusqlite::params![col, ANKI_REVLOG],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(raw, 2, "two copies under two raw IDs");
        let (_, rows) = read(t, col, json!({"q": "anki_logs_at", "at": [ANKI_REVLOG]}));
        assert_eq!(rows.len(), 1, "{rows:?}");
        assert_eq!(rows[0][0], w.c_card.text());
        assert_eq!(rows[0][5], w.c_note.text(), "the canonical card has a row");
        // 卡的日志：问哪一份卡都是同一个规范日志 ID 的一条。
        for card in [w.card[0], w.card[1], w.c_card] {
            let (_, logs) = read(t, col, json!({"q": "logs", "cards": [card.text()]}));
            assert_eq!(col_of(&logs, 0), [w.c_log.text()], "{}", card.text());
            assert_eq!(col_of(&logs, 1), [w.c_card.text()]);
        }
    });
}

#[test]
fn events_present_finds_a_class_by_any_member_and_echoes_the_asked_id() {
    with(|t, col| {
        let w = land(t, col);
        // 规范笔记 / 规范日志 ID 从没出现在操作里，按类认得出；成员也认得出；回包是请求里的那个 ID。
        let asked = [
            w.c_note.text(),
            w.note[1].text(),
            w.c_log.text(),
            w.log[1].text(),
            "missing".to_owned(),
        ];
        let (_, rows) = read(t, col, json!({"q": "events_present", "ids": asked}));
        assert_eq!(col_of(&rows, 0), asked[..4].to_vec());
        // LegacyUnknown 按 `x.id`。
        let (_, rows) = read(t, col, json!({"q": "events_present", "ids": ["u-1"]}));
        assert_eq!(col_of(&rows, 0), ["u-1"]);
    });
}

#[test]
fn history_of_any_member_is_the_history_of_the_whole_class() {
    with(|t, col| {
        let w = land(t, col);
        let all = history_pairs(t, col, &w.c_note.text());
        assert_eq!(all, history_pairs(t, col, &w.note[0].text()));
        assert_eq!(all, history_pairs(t, col, &w.note[1].text()));
        // 两份成员上的写入都在：被另一份的写入并发的那两条字段修改。
        let c_key = format!("f/{}", w.c_field.text());
        let fields: Vec<&String> = all.iter().filter(|p| p.contains(&c_key)).collect();
        assert_eq!(fields.len(), 2, "{all:?}");
    });
}

#[test]
fn counts_count_a_class_once() {
    with(|t, col| {
        let _w = land(t, col);
        // 牌组 1 + 笔记类型类 1 + 笔记类 1 + 待裁决笔记 1。
        let (v, _) = read(t, col, json!({"q": "entity_count"}));
        assert_eq!(v["n"], 4);
        let (v, _) = read(t, col, json!({"q": "entity_count", "kind": "note"}));
        assert_eq!(v["n"], 2);
        let (v, _) = read(t, col, json!({"q": "entity_count", "limit": 3}));
        assert_eq!(v["n"], 3);
        let (v, _) = read(t, col, json!({"q": "entity_count", "limit": 0}));
        assert_eq!(v["n"], 0);
        let (v, _) = read(t, col, json!({"q": "entity_count", "limit": -1}));
        assert_eq!(v["n"], 4, "a negative LIMIT is no limit (protocol 3 SQL)");
        let mut files = Files::new();
        let v = reads::run_lib(t, &json!({"q": "user_note_count"}), &mut files).unwrap();
        assert_eq!(v["n"], 2, "two salted copies are one note");
        // 待裁决：扣住的删除。
        let (v, _) = read(t, col, json!({"q": "pending_notes"}));
        assert_eq!(v["n"], 1);
        let held: i64 = t
            .conn()
            .query_row(
                "SELECT COUNT(*) FROM reg_ix WHERE col = ?1 AND state = -2",
                [col],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(held, 1);
    });
}

#[test]
fn ids_of_another_collection_read_as_nothing() {
    with(|t, col| {
        let w = land(t, col);
        let col2 = t.tx(|t| t.bind(P2, &id(0xc9), "dir2")).unwrap();
        assert_ne!(col, col2);
        let ids = json!([w.c_note.text(), w.note[0].text()]);
        let (_, rows) = read(t, col2, json!({"q": "entities", "ids": ids}));
        assert!(rows.is_empty());
        let (_, rows) = read(t, col2, json!({"q": "edits", "kind": "note", "ids": ids}));
        assert!(rows.is_empty());
        let (_, rows) = read(t, col2, json!({"q": "logs", "cards": [w.c_card.text()]}));
        assert!(rows.is_empty());
        let (_, rows) = read(t, col2, json!({"q": "cards", "notes": ids}));
        assert!(rows.is_empty());
        let (_, rows) = read(
            t,
            col2,
            json!({"q": "server_times", "ids": [w.log[0].text()]}),
        );
        assert!(rows.is_empty());
        let (_, rows) = read(t, col2, json!({"q": "events_present", "ids": ids}));
        assert!(rows.is_empty());
        let (v, _) = read(t, col2, json!({"q": "entity_count"}));
        assert_eq!(v["n"], 0);
        let (v, _) = read(t, col2, json!({"q": "has_user_data", "builtins": []}));
        assert_eq!(v["any"], false);
        // 第一个集合不受第二个影响。
        let (_, rows) = read(t, col, json!({"q": "entities", "ids": ids}));
        assert_eq!(col_of(&rows, 0), [w.c_note.text()]);
    });
}

/// `server_times` 回包的 ID：给了 `ids` 就回请求里的那个（成员、规范 ID 各问各回）；不给就是规范日志 ID。
#[test]
fn server_times_answer_in_the_ids_that_were_asked() {
    with(|t, col| {
        let w = land(t, col);
        let (_, all) = read(t, col, json!({"q": "server_times"}));
        assert_eq!(all, [vec![w.c_log.text(), ST.to_string()]]);
        let asked = [w.log[1].text(), w.c_log.text(), w.log[0].text()];
        let (_, rows) = read(t, col, json!({"q": "server_times", "ids": asked}));
        let mut want: Vec<Vec<String>> = asked
            .iter()
            .map(|a| vec![a.clone(), ST.to_string()])
            .collect();
        want.sort();
        assert_eq!(rows, want);
        // 大写的 UUID 文本是另一个文本 ID（同协议 3 的 `srs_id`：只有小写带连字符的才存成 16 字节）。
        let (_, rows) = read(
            t,
            col,
            json!({"q": "server_times", "ids": [w.log[1].text().to_uppercase()]}),
        );
        assert_eq!(rows.len(), 0, "an upper-case UUID is a different text ID");
    });
}

/// `edits` 的 `key` / `prefix` 先归一：请求给成员形的键也命中规范键的行。
#[test]
fn edit_keys_and_prefixes_are_canonicalized_before_matching() {
    with(|t, col| {
        let w = land(t, col);
        let c_key = format!("f/{}", w.c_field.text());
        for k in [w.field[0], w.field[1], w.c_field] {
            let key = format!("f/{}", k.text());
            for (name, extra) in [("key", json!(key)), ("prefix", json!(key))] {
                let mut req = json!({"q": "edits", "kind": "note", "ids": [w.note[1].text()]});
                req[name] = extra;
                let (_, rows) = read(t, col, req);
                assert_eq!(rows.len(), 2, "{name} {key}");
                for r in &rows {
                    let j: Value = serde_json::from_str(&r[1]).unwrap();
                    assert_eq!(j["f"], c_key.as_str());
                    assert_eq!(r[0], w.c_note.text());
                }
            }
        }
        let (_, rows) = read(
            t,
            col,
            json!({"q": "edits", "kind": "note", "ids": [w.note[0].text()], "prefix": "f/"}),
        );
        assert_eq!(rows.len(), 2);
    });
}

// ---------------------------------------------------------------------- 统计

/// 统计请求里按 ID 给的东西先归一：数组去重成规范 ID；表的键归一，同一个类的几个成员都给了值时规范 ID 自己的优先，
/// 否则取 ID 序最小的成员的（与键的先后无关）。
#[test]
fn stats_requests_are_canonicalized_and_members_resolve_deterministically() {
    use super::stats::canon_req;
    with(|t, col| {
        let w = land(t, col);
        let ix = Index::new(t, col);
        let (n0, n1, c) = (w.note[0].text(), w.note[1].text(), w.c_note.text());
        let mut desired = serde_json::Map::new();
        desired.insert(n0.clone(), json!(0.8));
        desired.insert(c.clone(), json!(0.7));
        desired.insert(n1.clone(), json!(0.6));
        let req = json!({
            "now": 1, "desired": desired, "deckModels": {n1.as_str(): 2, n0.as_str(): 1},
            "decks": [n0, n1, c, "x"], "recallDecks": [n1], "recall": {"ids": [w.card[1].text()], "r": [0.3]},
        });
        let got = canon_req(&ix, &req).unwrap();
        assert_eq!(got["desired"], json!({c.as_str(): 0.7}));
        let first = if n0 < n1 { 1 } else { 2 };
        assert_eq!(got["deckModels"], json!({c.as_str(): first}));
        assert_eq!(got["decks"], json!([c, "x"]));
        assert_eq!(got["recallDecks"], json!([c]));
        assert_eq!(got["recall"]["ids"], json!([w.c_card.text()]));
        assert_eq!(got["now"], 1);
    });
}

/// 按类物化的卡在统计里只有一张（规范卡）；请求按成员卡给 RWKV 回忆率也落到它身上。
#[test]
fn stats_see_one_canonical_card_and_take_member_ids_in_the_request() {
    use super::stats::{stats_recall, stats_report, stats_rows};
    with(|t, col| {
        let w = land(t, col);
        let deck = id(DECK).text();
        let req = json!({
            "now": ANKI_REVLOG + 86_400_000, "utcOff": 0, "rollover": 4,
            "recallDecks": [deck], "recall": {"ids": [w.card[1].text()], "r": [0.3]},
        });
        let rows = stats_rows(t, col, &req).unwrap();
        let cards: Vec<&Value> = rows["cards"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|c| c[1] == json!(w.c_note.text()))
            .collect();
        assert_eq!(cards.len(), 1, "{rows}");
        assert_eq!(cards[0][0], json!(w.c_card.text()));
        assert_eq!(
            cards[0][12],
            json!(0.3),
            "R from the member id: {}",
            cards[0]
        );
        assert_eq!(cards[0][17], json!(true));
        // 同一次 Anki 复习的两份只算一条有效复习。
        let reviews: Vec<&Value> = rows["reviews"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|r| r[1] == json!(ANKI_REVLOG))
            .collect();
        assert_eq!(reviews.len(), 1, "{rows}");
        let recall = stats_recall(t, col, &req).unwrap();
        assert_eq!(recall["cards"][0][0], json!(w.c_card.text()), "{recall}");
        let report = stats_report(
            t,
            col,
            &json!({"now": 1, "utcOff": 0, "rollover": 4, "decks": [deck]}),
        );
        assert!(report.is_ok());
        assert!(t.conn().is_autocommit());
    });
}

// ---------------------------------------------------------------------- has_user_data 的口径

/// 只有内置牌组 → 没有；不可信设备删它 → 有（有意比协议 3 保守，`has_user_data` 注释）；清除掉的写入不算。
#[test]
fn has_user_data_counts_held_and_distrusted_but_not_purged() {
    with(|t, col| {
        let deck = id(DECK);
        let builtins = json!({"q": "has_user_data", "builtins": [deck.text()]});
        let any = |t: &Truth<'_>| read(t, col, builtins.clone()).0["any"].clone();
        t.tx(|t| {
            let mut ix = Index::new(t, col);
            let e = entity(
                EntKind::Deck,
                u(deck),
                json!({"createdAt": 1, "builtin": "default"}),
            );
            native(t, &mut ix, col, &op(0xa1, 1, 100, &[], &e));
            ix.settle()?;
            Ok(())
        })
        .unwrap();
        assert_eq!(any(t), false, "only the builtin deck");
        // 牌组改名，再被（可信的）清除：改名成了已清除，清除本身不是用户数据。
        t.tx(|t| {
            let mut ix = Index::new(t, col);
            let name = set(EntKind::Deck, u(deck), "name", json!("x"));
            native(t, &mut ix, col, &op(0xa1, 2, 101, &[], &name));
            ix.settle()?;
            Ok(())
        })
        .unwrap();
        assert_eq!(any(t), true, "a rename is user data");
        t.tx(|t| {
            let mut ix = Index::new(t, col);
            let purge = Body4::Purge {
                kind: EntKind::Deck,
                entity: u(deck),
            };
            native(t, &mut ix, col, &op(0xa1, 3, 102, &[], &purge));
            ix.settle()?;
            Ok(())
        })
        .unwrap();
        let purged: i64 = t
            .conn()
            .query_row(
                "SELECT COUNT(*) FROM reg_ix WHERE col = ?1 AND state = -1",
                [col],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(purged, 1);
        assert_eq!(any(t), false, "purged writes are not user data");
        // 不可信设备删内置牌组：扣在 S_DISTRUSTED，算「有」。
        t.tx(|t| {
            t.set_trust(col, &id(0xd1), Some(TRUST_PENDING), 7)?;
            let mut ix = Index::new(t, col);
            ix.trust_changed();
            let del = set(EntKind::Deck, u(deck), "deleted", json!(500));
            native(t, &mut ix, col, &op(0xd1, 1, 500, &[(0xa1, 3)], &del));
            ix.settle()?;
            Ok(())
        })
        .unwrap();
        let distrusted: i64 = t
            .conn()
            .query_row(
                "SELECT COUNT(*) FROM reg_ix WHERE col = ?1 AND state = -3",
                [col],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(distrusted, 1);
        assert_eq!(any(t), true, "a distrusted delete is kept as user data");
        assert_rebuild_is_identity(t, col);
    });
}

#[test]
fn has_user_data_sees_salted_copies_of_builtins_as_builtins() {
    with(|t, col| {
        let w = land(t, col);
        // 内置牌组 + 两份笔记类型（带盐、规范化后同一个）+ 笔记类 + 待裁决笔记全列成「内置」→ 剩下的是修改、日志。
        let builtins = json!([
            id(DECK).text(),
            w.nt[0].text(),
            w.c_note.text(),
            id(HELD).text()
        ]);
        let (v, _) = read(t, col, json!({"q": "has_user_data", "builtins": builtins}));
        assert_eq!(v["any"], true, "edits and logs remain");
        let (v, _) = read(
            t,
            col,
            json!({"q": "has_user_data", "builtins": [id(DECK).text()]}),
        );
        assert_eq!(v["any"], true);
    });
}

// ---------------------------------------------------------------------- 代价

thread_local! {
    static ROWS: std::cell::Cell<u64> = const { std::cell::Cell::new(0) };
}

/// 一条读命令里各条语句一共交出多少行（`SQLITE_TRACE_ROW`：语句每交出一行回调一次——流式读到一半停下的语句只算
/// 读过的那几行）。
fn rows_stepped(t: &Truth<'_>, col: i64, req: &Value) -> u64 {
    use rusqlite::trace::{TraceEvent, TraceEventCodes};
    fn count(e: TraceEvent<'_>) {
        if let TraceEvent::Row(_) = e {
            ROWS.with(|r| r.set(r.get() + 1));
        }
    }
    ROWS.with(|r| r.set(0));
    t.conn()
        .trace_v2(TraceEventCodes::SQLITE_TRACE_ROW, Some(count));
    let mut files = Files::new();
    reads::run(t, col, req, &mut files).unwrap();
    t.conn().trace_v2(TraceEventCodes::empty(), None);
    ROWS.with(|r| r.get())
}

/// [n] 条笔记（各自一条身份记录）。
fn notes(t: &Truth<'_>, col: i64, n: u64) {
    t.tx(|t| {
        let mut ix = Index::new(t, col);
        let nt = rules::note_type(CANONICAL, ANKI_NT);
        for i in 0..n {
            let mut b = [0x55u8; 16];
            b[8..].copy_from_slice(&i.to_be_bytes());
            let e = entity(
                EntKind::Note,
                u(Id(b)),
                json!({"createdAt": i, "guid": format!("n{i}"), "noteTypeId": nt.text()}),
            );
            native(t, &mut ix, col, &op(0xa1, i + 1, 100 + i as i64, &[], &e));
        }
        ix.settle()?;
        Ok(())
    })
    .unwrap();
}

/// `entity_count {limit}` 与 `has_user_data` 在碰到答案时就停：集合大 40 倍，各条语句交出的行数不变（协议 3 是
/// `LIMIT` / `EXISTS`）。以前把整个集合的身份记录读完再数。
#[test]
fn limited_counts_and_has_user_data_stop_at_the_answer() {
    let measure = |n: u64| -> (u64, u64, u64) {
        with(|t, col| {
            notes(t, col, n);
            (
                rows_stepped(t, col, &json!({"q": "entity_count", "limit": 1})),
                rows_stepped(
                    t,
                    col,
                    &json!({"q": "entity_count", "kind": "note", "limit": 2}),
                ),
                rows_stepped(t, col, &json!({"q": "has_user_data", "builtins": []})),
            )
        })
    };
    let small = measure(25);
    let big = measure(1000);
    for (s, b, what) in [
        (small.0, big.0, "entity_count limit 1"),
        (small.1, big.1, "entity_count kind limit 2"),
        (small.2, big.2, "has_user_data"),
    ] {
        assert!(b <= s + 2, "{what}: {s} rows on 25 notes, {b} on 1000");
    }
    // 不限数时就是要数完：反过来证明上面量得出差别。
    let full = |n: u64| {
        with(|t, col| {
            notes(t, col, n);
            rows_stepped(t, col, &json!({"q": "entity_count"}))
        })
    };
    let (fs, fb) = (full(25), full(1000));
    assert!(
        fb > fs * 10,
        "an unlimited count walks everything: {fs} vs {fb}"
    );
}
