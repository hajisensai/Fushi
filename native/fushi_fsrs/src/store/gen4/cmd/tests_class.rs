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

pub(super) const U1: &str = "0192f0aa-0000-7000-8000-00000000000a";
pub(super) const U2: &str = "0192f0aa-0000-7000-8000-00000000000b";
pub(super) const ANKI_NT: i64 = 1_700_000_000_001;
const ANKI_REVLOG: i64 = 1_650_000_000_123;
pub(super) const DECK: u8 = 0x0d;
/// 待裁决的那条笔记。
const HELD: u8 = 0x4e;
const P2: &str = "0193a1b2-0000-7000-8000-0000000000f2";
const ST: i64 = 1_650_000_009_000;

pub(super) fn entity(kind: EntKind, key: Key, data: Value) -> Body4 {
    Body4::Entity {
        kind,
        id: key,
        data: data.to_string(),
    }
}

pub(super) fn set(kind: EntKind, entity: Key, key: &str, value: Value) -> Body4 {
    Body4::Edit(Edit4 {
        kind,
        entity,
        key: key.to_owned(),
        value: value.to_string(),
        ..native_edit()
    })
}

pub(super) fn u(i: Id) -> Key {
    Key::Uuid(i)
}

/// 两份带盐的笔记，连同它们规范的那一套。
pub(in crate::store::gen4) struct Twin {
    pub(super) nt: [Id; 2],
    pub(super) field: [Id; 2],
    pub(super) tmpl: [Id; 2],
    pub(super) note: [Id; 2],
    pub(in crate::store::gen4) card: [Id; 2],
    pub(super) log: [Id; 2],
    pub(super) c_field: Id,
    pub(super) c_note: Id,
    pub(in crate::store::gen4) c_card: Id,
    pub(super) c_log: Id,
}

pub(super) fn twin() -> Twin {
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
pub(super) fn base_ops(w: &Twin) -> Vec<Body4> {
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

/// [land] 里 0xa1 写完身份与定义之后的那个点 (设备, 最后一个 seq)：在场景上续写、要「见过全部定义」的操作拿它当依赖。
pub(super) fn base_seen(w: &Twin) -> (u8, u64) {
    (0xa1, base_ops(w).len() as u64)
}

/// 灌进集合 [col]：0xa1 的定义，再 0xb1 / 0xb2 互不相见地各改一份的同一字段，0xc1 删待裁决的笔记、0xc2 没见过这条删除
/// 就改它的字段（删除被扣住）。返回场景。`center_tests.rs` 的别名类场景也用它。
pub(in crate::store::gen4) fn land(t: &Truth<'_>, col: i64) -> Twin {
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

/// 同一个实体上两个原值键（键里嵌的字段 ID 一个带盐、一个规范）归一成同一个规范键：按原值各是一个寄存器、各自只有
/// 胜者，类里也只有这一个成员有行——候选靠「嵌 ID 的键归一后撞在一起」找到（`Reads::merged_key_candidates`）。
/// 同值的并发写入（两台设备各写同一个所属牌组）不交回。
#[test]
fn conflicts_from_two_raw_keys_of_one_entity_are_found_and_same_value_writes_are_not() {
    with(|t, col| {
        let w = twin();
        let cfg = json!({"defaultDeck": id(DECK).text()}).to_string();
        t.tx(|t| {
            t.set_derive_cfg(col, CFG_KEY, Some(&cfg))?;
            let mut ix = Index::new(t, col);
            let base = base_ops(&w);
            for (i, b) in base.iter().enumerate() {
                native(
                    t,
                    &mut ix,
                    col,
                    &op(0xa1, i as u64 + 1, 100 + i as i64, &[], b),
                );
            }
            let seen = [base_seen(&w)];
            let salted = set(
                EntKind::Note,
                u(w.note[0]),
                &format!("f/{}", w.field[0].text()),
                json!("A"),
            );
            let canon = set(
                EntKind::Note,
                u(w.note[0]),
                &format!("f/{}", w.c_field.text()),
                json!("B"),
            );
            native(t, &mut ix, col, &op(0xb1, 1, 300, &seen, &salted));
            native(t, &mut ix, col, &op(0xb2, 1, 301, &seen, &canon));
            let deck = set(EntKind::Note, u(w.note[0]), "deck", json!(id(DECK).text()));
            native(t, &mut ix, col, &op(0xb1, 2, 302, &seen, &deck));
            native(t, &mut ix, col, &op(0xb2, 2, 303, &seen, &deck));
            ix.settle()?;
            Ok(())
        })
        .unwrap();
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
        let (_, one) = read(
            t,
            col,
            json!({"q": "conflict_edits", "rules": rules, "kind": "note", "id": w.note[0].text()}),
        );
        assert_eq!(one, rows);
        // 只追踪所属牌组：两条同值的写入都活着，但不是冲突。
        let deck_only = json!([{"kind": "note", "keep": ["deck"]}]);
        let (_, rows) = read(t, col, json!({"q": "conflict_edits", "rules": deck_only}));
        assert!(rows.is_empty(), "{rows:?}");
        let (_, edits) = read(
            t,
            col,
            json!({"q": "edits", "kind": "note", "ids": [w.note[0].text()], "key": "deck"}),
        );
        assert_eq!(edits.len(), 2, "both same-value writes are live: {edits:?}");
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
            // BUG-5476：`oid` 交回代表的原值日志 ID（规范 ID 从没出现在操作里），Dart 按它排序、选副本。
            let oid = &logs[0][4];
            assert!(
                w.log.iter().any(|l| l.text() == *oid),
                "oid {oid} is a raw member"
            );
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

/// 血统按类读前身链接：X 的链接写的是成员卡 card0、card1（同一个类）上写着前身 Y——X 的血统是 X、规范卡、Y；问成员
/// 卡与问规范卡相同。
#[test]
fn lineages_follow_links_written_on_any_member() {
    use super::lineage::lineages;
    with(|t, col| {
        let w = land(t, col);
        let (x, y) = (Id::new_v7(1_700_000_000_001), Id::new_v7(1_700_000_000_002));
        t.tx(|t| {
            let mut ix = Index::new(t, col);
            let to_member = set(
                EntKind::Card,
                u(x),
                &format!("historyFrom/{}", w.card[0].text()),
                json!(true),
            );
            let from_member = set(
                EntKind::Card,
                u(w.card[1]),
                &format!("historyFrom/{}", y.text()),
                json!(true),
            );
            native(t, &mut ix, col, &op(0xe1, 1, 600, &[], &to_member));
            native(t, &mut ix, col, &op(0xe1, 2, 601, &[], &from_member));
            ix.settle()?;
            Ok(())
        })
        .unwrap();
        let (cx, cc, cy) = (x.text(), w.c_card.text(), y.text());
        let got = lineages(
            t,
            col,
            &[cx.clone(), w.card[0].text(), cc.clone(), w.card[1].text()],
        )
        .unwrap();
        assert_eq!(got[0], [cx, cc.clone(), cy.clone()]);
        for l in &got[1..] {
            assert_eq!(l, &[cc.clone(), cy.clone()]);
        }
        assert!(t.conn().is_autocommit());
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
        assert_eq!(got["recall"]["r"], json!([0.3]));
        assert_eq!(got["now"], 1);
        // `recall.ids` / `recall.r` 撞键与上面的表同一条规则（`canon_keyed`）：规范卡自己给了取它的，否则取成员里 ID
        // 序最小的那张的；与请求里的先后无关，两个数组仍等长。
        let (k0, k1, kc) = (w.card[0].text(), w.card[1].text(), w.c_card.text());
        let recall = |ids: Value, r: Value| -> Value {
            canon_req(&ix, &json!({"recall": {"ids": ids, "r": r}})).unwrap()["recall"].clone()
        };
        let own = json!({"ids": [kc], "r": [0.5]});
        assert_eq!(recall(json!([k1, kc, k0]), json!([0.3, 0.5, 0.1])), own);
        assert_eq!(recall(json!([k0, kc, k1]), json!([0.1, 0.5, 0.3])), own);
        let low = if k0 < k1 { 0.1 } else { 0.3 };
        let members = json!({"ids": [kc], "r": [low]});
        assert_eq!(recall(json!([k1, k0]), json!([0.3, 0.1])), members);
        assert_eq!(recall(json!([k0, k1]), json!([0.1, 0.3])), members);
        // 同一个原值 ID 出现两次：先按协议 3 `stats::Ctx` 的读法后者盖前者，再按类归一。
        assert_eq!(
            recall(json!([k0, k0]), json!([0.1, 0.9])),
            json!({"ids": [kc], "r": [0.9]})
        );
        let low = if k0 < k1 { 0.9 } else { 0.3 };
        assert_eq!(
            recall(json!([k0, k1, k0]), json!([0.1, 0.3, 0.9])),
            json!({"ids": [kc], "r": [low]})
        );
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

// ---------------------------------------------------------------------- 数字 id

/// 数字 id：规范 ID 的号、别名类成员（换代前带盐的原值 ID）的号都查得到规范 ID；从没在操作里出现过的卡（待裁决的
/// 笔记配带盐模板的那张，协议 3 里有号）的号也查得到；不在这个集合里的号、成员号对应的规范 ID 不在这张表里（笔记的号
/// 拿去查卡）都是 null。`notesInfo` 按成员号也给出按类判定的内容。
#[test]
fn numeric_ids_of_alias_members_resolve_to_the_canonical_row() {
    use super::columns::{anki_notes_info, anki_resolve, card_columns};
    use crate::store::schema::anki_numeric_id as num;
    with(|t, col| {
        let w = land(t, col);
        let (n0, n1, c) = (w.note[0].text(), w.note[1].text(), w.c_note.text());
        let (k0, kc) = (w.card[0].text(), w.c_card.text());
        // 待裁决的笔记（ID 不带盐、类里只有它自己）配带盐的模板：协议 3 的卡 ID，从没在操作里出现过。
        let held = id(HELD);
        let unseen = rules::card(&held, &w.tmpl[0], 0).text();
        let c_tmpl = rules::template(&rules::note_type(CANONICAL, ANKI_NT), 0);
        let held_card = rules::card(&held, &c_tmpl, 0).text();
        let req = json!({
            "notes": [num(&c), num(&n0), num(&n1), num("nope"), num(&kc)],
            "cards": [num(&kc), num(&k0), num(&n0), num(&unseen)],
        });
        let v = anki_resolve(t, col, &req).unwrap();
        assert_eq!(
            v,
            json!({"notes": [c, c, c, null, null], "cards": [kc, kc, null, held_card]})
        );
        let v = anki_notes_info(t, col, &json!({"notes": [num(&n1), num(&c), 3]})).unwrap();
        let notes = v["notes"].as_array().unwrap();
        assert_eq!(notes[0], notes[1]);
        assert_eq!(notes[2], Value::Null);
        assert_eq!(notes[0]["id"], json!(c));
        assert_eq!(
            notes[0]["nt"],
            json!(rules::note_type(CANONICAL, ANKI_NT).text())
        );
        let c_key = w.c_field.text();
        let fields = notes[0]["f"].as_array().unwrap();
        assert!(
            fields.iter().all(|f| f[0] == json!(c_key)),
            "fields carry the canonical field id: {fields:?}"
        );
        assert_eq!(
            notes[0]["c"],
            json!([[
                num(&kc),
                rules::template(&rules::note_type(CANONICAL, ANKI_NT), 0).text(),
                0
            ]])
        );
        // 别的集合里同样的号查不到。
        let col2 = t.tx(|t| t.bind(P2, &id(0xc9), "dir2")).unwrap();
        let v = anki_resolve(t, col2, &req).unwrap();
        assert_eq!(
            v,
            json!({"notes": [null, null, null, null, null], "cards": [null, null, null, null]})
        );
        let cols = card_columns(t, col, &json!({"fields": ["id", "note_id", "anki_id"]}));
        assert!(
            cols.is_err(),
            "anki_id is not a card_columns column (protocol 3 neither)"
        );
        let (_, rows) = (
            (),
            decode(&card_columns(t, col, &json!({"fields": ["id", "note_id"]})).unwrap()).1,
        );
        assert!(rows.iter().any(|r| r == &vec![kc.clone(), c.clone()]));
        assert!(t.conn().is_autocommit());
    });
}

/// 随机 ID 的笔记（规范 ID 就是它协议 3 的 ID）类里另有成员（旧并入的兜底副本）时，它配带盐模板的那张从没出现过的
/// 卡照样查得到号：配卡公式的笔记一边带上规范 ID 自己（`cache.rs` 文件头「表」），不只取出现过的成员。逐条维护与
/// 重建相同。
#[test]
fn a_random_note_with_a_fallback_member_keeps_its_unseen_card_number() {
    use super::columns::anki_resolve;
    use crate::store::schema::anki_numeric_id as num;
    with(|t, col| {
        let w = land(t, col);
        let held = id(HELD);
        let copy = rules::merge_fallback(U1, &held.text());
        t.tx(|t| {
            let mut ix = Index::new(t, col);
            let body = entity(
                EntKind::Note,
                u(copy),
                json!({"createdAt": 3, "guid": "h", "noteTypeId": w.nt[0].text()}),
            );
            native(t, &mut ix, col, &op(0xa3, 1, 500, &[base_seen(&w)], &body));
            ix.settle()?;
            assert_eq!(
                ix.canonical(&crate::store::gen4::derive::Ref::Uuid(copy.0))?,
                crate::store::gen4::derive::Ref::Uuid(held.0)
            );
            Ok(())
        })
        .unwrap();
        assert_rebuild_is_identity(t, col);
        let unseen = rules::card(&held, &w.tmpl[0], 0).text();
        let c_tmpl = rules::template(&rules::note_type(CANONICAL, ANKI_NT), 0);
        let held_card = rules::card(&held, &c_tmpl, 0).text();
        let req = json!({"notes": [num(&copy.text())], "cards": [num(&unseen)]});
        assert_eq!(
            anki_resolve(t, col, &req).unwrap(),
            json!({"notes": [held.text()], "cards": [held_card]})
        );
    });
}

/// 按号查是索引点查（`notes_anki` / `cards_anki`），不扫整张缓存表；查不到时成员的号是 `anki_members` 的主键点查、
/// 再点查一次缓存行——不扫别名表、不逐行算号。截下 `anki_resolve` 真正执行的语句（参数已展开）逐条 `EXPLAIN`。
#[test]
#[allow(deprecated)]
fn numeric_id_lookups_use_the_anki_indexes() {
    use super::columns::anki_resolve;
    use crate::store::schema::anki_numeric_id as num;
    thread_local! {
        static TRACED: std::cell::RefCell<Vec<String>> = const { std::cell::RefCell::new(Vec::new()) };
    }
    let conn = crate::store::gen4::schema::open_in_memory().unwrap();
    let t = Truth::new(&conn);
    let col = crate::store::gen4::truth::tests::bound(&t);
    let w = land(&t, col);
    drop(t);
    let mut conn = conn;
    conn.trace(Some(|sql: &str| {
        TRACED.with(|t| t.borrow_mut().push(sql.to_owned()));
    }));
    let unseen = rules::card(&id(HELD), &w.tmpl[0], 0).text();
    let req = json!({
        "notes": [num(&w.c_note.text()), num(&w.note[0].text()), num("nope")],
        "cards": [num(&w.c_card.text()), num(&w.card[1].text()), num(&unseen), num("nope")],
    });
    {
        let t = Truth::new(&conn);
        let v = anki_resolve(&t, col, &req).unwrap();
        assert!(v["cards"][2].is_string(), "{v}");
    }
    conn.trace(None);
    let stmts: BTreeSet<String> = TRACED.with(|t| t.borrow().iter().cloned().collect());
    let mut members = 0;
    let mut bad = Vec::new();
    for q in &stmts {
        if !q.trim_start().to_ascii_uppercase().starts_with("SELECT") {
            continue;
        }
        members += usize::from(q.contains("anki_members"));
        let plan: Vec<String> = conn
            .prepare(&format!("EXPLAIN QUERY PLAN {q}"))
            .unwrap()
            .query_map([], |r| r.get::<_, String>(3))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        for step in plan {
            if step.starts_with("SCAN ")
                || step.contains("alias_ix")
                || step.starts_with("SEARCH ") && step.ends_with("(col=?)")
            {
                bad.push(format!("{q}\n    {step}"));
            }
        }
    }
    assert!(members > 0, "the member lookup never ran: {stmts:?}");
    assert!(bad.is_empty(), "{}", bad.join("\n"));
}

/// `entity_count {kind?, limit}` / `has_user_data` 逐行走的那条语句（`reads.rs` `each_class`）：给了种类走 `ent_kind`、
/// 不给走主键，两种都按 `id` 交出、不排序（能数到 `limit` 就停）。
#[test]
fn class_walks_stream_in_id_order_by_kind_or_by_key() {
    with(|t, _| {
        for (q, args, index) in [
            (
                "SELECT DISTINCT id FROM ent_ix WHERE col = ?1 AND win = 1 AND kind = ?2 ORDER BY id",
                vec![1i64, 2],
                "ent_kind",
            ),
            (
                "SELECT DISTINCT id FROM ent_ix WHERE col = ?1 AND win = 1 ORDER BY id",
                vec![1i64],
                "PRIMARY KEY",
            ),
        ] {
            let plan: Vec<String> = t
                .conn()
                .prepare(&format!("EXPLAIN QUERY PLAN {q}"))
                .unwrap()
                .query_map(rusqlite::params_from_iter(args), |r| r.get::<_, String>(3))
                .unwrap()
                .collect::<Result<_, _>>()
                .unwrap();
            assert!(plan.iter().any(|s| s.contains(index)), "{q}: {plan:?}");
            assert!(
                !plan.iter().any(|s| s.contains("TEMP B-TREE")),
                "{q}: {plan:?}"
            );
        }
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

// ---------------------------------------------------------------------- 出卡

/// 出卡（`cmd/study.rs`）按类：同一次 Anki 复习的两份带盐导入在计数上下文里只算一条（最近 30 天、今天已复习的卡与
/// 作答数），落在规范卡上；请求里按成员卡给的排除与 RWKV 候选都落到规范卡上，候选同一张规范卡只留一份。
#[test]
fn study_counts_a_log_class_once_and_takes_member_ids_in_the_request() {
    use super::study::log_state;
    let study = |t: &Truth<'_>, col: i64, req: &Value| {
        super::study::study(t, &crate::store::queue::StudyHub::default(), col, req, None)
    };
    use crate::projection::Day;
    with(|t, col| {
        let w = land(t, col);
        let deck = id(DECK).text();
        let c = w.c_card.text();
        let now = ANKI_REVLOG + 60_000;
        let day = Day {
            utc_offset_min: 0,
            rollover_hour: 4,
        };
        let mut ix = Index::new(t, col);
        let s = log_state(t, &mut ix, col, day, day.index(now)).unwrap();
        assert_eq!(s.last30().iter().sum::<i64>(), 1, "{s:?}");
        assert_eq!(
            s.reviewed_cards().cloned().collect::<Vec<_>>(),
            vec![c.clone()]
        );
        assert_eq!(s.review_answers(&c), 1);
        assert_eq!(s.answers().count(), 1);

        let base = json!({"now": now, "utcOff": 0, "rollover": 4, "deck": deck, "pick": true});
        let plain = study(t, col, &base).unwrap();
        assert!(t.conn().is_autocommit());
        let keys: Vec<&String> = plain["counts"].as_object().unwrap().keys().collect();
        assert_eq!(keys, vec![&deck], "{plain}");
        assert_eq!(
            plain["next"],
            json!(c),
            "the due review comes first: {plain}"
        );

        for member in [&w.card[0], &w.card[1]] {
            let mut req = base.clone();
            req["exclude"] = json!([member.text()]);
            let v = study(t, col, &req).unwrap();
            assert_ne!(
                v["next"],
                json!(c),
                "excluded by member {}: {v}",
                member.text()
            );
            assert_ne!(
                v["after"],
                json!(c),
                "excluded by member {}: {v}",
                member.text()
            );
        }

        let mut req = base.clone();
        req["rwkv"] = json!({
            "decks": {deck.as_str(): [0.9, 0, 0, 0]},
            "cands": [[w.card[0].text(), deck, null, 0.1], [w.card[1].text(), deck, null, 0.2]],
        });
        let v = study(t, col, &req).unwrap();
        assert_eq!(v["eligible"], json!([c]), "{v}");
        assert_eq!(v["next"], json!(c), "{v}");
    });
}

/// 别名类里今天的学习步日志：同一次 Anki 学习的两份带盐导入（各落在一份带盐的卡上），计数上下文里只算一条、
/// 「今天已引入新卡」落在规范卡上（`res` 取按血统重放写回的那份，按规范日志 ID 对上）。
#[test]
fn study_introduces_a_salted_learn_step_once_on_the_canonical_card() {
    use super::ref_of;
    use super::study::log_state;
    use crate::projection::Day;
    with(|t, col| {
        let w = land(t, col);
        let at = ANKI_REVLOG - 60_000;
        let lid = [
            rules::imported_revlog(&w.card[0], at),
            rules::imported_revlog(&w.card[1], at),
        ];
        t.tx(|t| {
            let mut ix = Index::new(t, col);
            for i in 0..2 {
                let mut b = anki_log(lid[i], w.card[i], None);
                if let Body4::Log(l) = &mut b {
                    l.at = at;
                    l.anki_id = Some(at);
                    l.rtype = "learn".into();
                    l.res = Some(
                        json!({"queue": "learning", "ivl": 0, "step": 1, "reps": 1, "lapses": 0,
                               "scheduler": "fushi", "dueAt": at + 600_000})
                        .to_string(),
                    );
                }
                native(
                    t,
                    &mut ix,
                    col,
                    &op(0xd1 + i as u8, 1, 500 + i as i64, &[], &b),
                );
            }
            ix.settle()?;
            Ok(())
        })
        .unwrap();
        let c = w.c_card.text();
        let day = Day {
            utc_offset_min: 0,
            rollover_hour: 4,
        };
        let mut ix = Index::new(t, col);
        // 计数取 `res` 时按规范日志 ID 去重放结果里找：两份成员日志归到的那个规范 ID 必须就在规范卡的重放结果里
        // （对不上就会退回操作里的原值，重放写回的 `res` 白算）。
        let canon_log = ix.canon(&ref_of(&lid[1].text())).unwrap();
        assert_eq!(canon_log, ix.canon(&ref_of(&lid[0].text())).unwrap());
        let replayed_ids: Vec<String> = ix
            .replayed_card_logs(&ref_of(&w.card[1].text()))
            .unwrap()
            .iter()
            .map(|x| {
                serde_json::from_str::<Value>(&x.json).unwrap()["id"]
                    .as_str()
                    .unwrap()
                    .to_owned()
            })
            .collect();
        assert!(
            replayed_ids.contains(&canon_log.text()),
            "{} not in {replayed_ids:?}",
            canon_log.text()
        );
        let s = log_state(t, &mut ix, col, day, day.index(ANKI_REVLOG + 60_000)).unwrap();
        assert_eq!(
            s.introduced_cards().cloned().collect::<Vec<_>>(),
            vec![c.clone()],
            "{s:?}"
        );
        // 学习步一条 + 复习一条：两份带盐的各只算一次。
        assert_eq!(s.answers().count(), 2, "{s:?}");
        assert_eq!(s.last30().iter().sum::<i64>(), 2, "{s:?}");
        assert!(s.answers().all(|(x, _)| *x == c), "{s:?}");
    });
}

// ---------------------------------------------------------------------- 逐卡重放与训练集、评分预览（G7-4f）

/// 逐卡重放与训练集（`cmd/training.rs`）按类：任何成员卡给的历史都是规范卡的历史，同一次 Anki 复习的两份带盐导入只出一次
/// （日志 ID 是规范的），一份历史里给了同一个类的几个成员只算一次；RWKV 指纹按日志操作数（两份都数），尾巴只出代表。
#[test]
fn training_reads_see_a_log_class_once_through_any_member() {
    use super::training::{
        history_states, rwkv_cards, rwkv_log_tail, rwkv_replay, stat_projection,
    };
    use crate::projection::Day;
    use crate::store::projections::RwkvRange;
    with(|t, col| {
        let w = land(t, col);
        let c = w.c_card.text();
        let (m0, m1) = (w.card[0].text(), w.card[1].text());
        let one = |g: Vec<String>| history_states(t, col, &[g]).unwrap();
        let canon = one(vec![c.clone()]);
        assert_eq!(one(vec![m0.clone()]), canon);
        assert_eq!(one(vec![m1.clone()]), canon);
        assert_eq!(one(vec![m0.clone(), m1.clone(), c.clone()]), canon);
        // 不是空状态：规范卡上有那一次复习。
        assert_ne!(canon, one(vec!["missing".to_owned()]));

        let (_, rows) = crate::store::rows::decode(
            &stat_projection(t, col, &[vec![m0.clone(), m1.clone()]]).unwrap(),
        )
        .unwrap();
        assert_eq!(rows.len(), 1, "{rows:?}");
        assert_eq!(rows[0][1], rusqlite::types::Value::Text(w.c_log.text()));

        let day = Day {
            utc_offset_min: 0,
            rollover_hour: 4,
        };
        let word = |b: &[u8], k: usize| i64::from_le_bytes(b[8 * k..8 * k + 8].try_into().unwrap());
        let cards = rwkv_cards(t, col, &[vec![m1.clone()]], &[1, 2, 3, 4], &day).unwrap();
        assert_eq!(
            (word(&cards, 0), word(&cards, 1)),
            (1, 1),
            "one group, one kept rating"
        );
        assert!(String::from_utf8_lossy(&cards).contains(&w.c_log.text()));

        let replay = rwkv_replay(
            t,
            col,
            &[vec![m0.clone()]],
            &[1, 2, 3, 4],
            &day,
            0,
            RwkvRange::default(),
        )
        .unwrap();
        // [count, maxRowId, lastAt, n_rows, n_strays, …]：两份导入日志都是落库的操作，行只有一条，没有漏掉的卡。
        assert_eq!(word(&replay, 0), 2);
        assert_eq!((word(&replay, 3), word(&replay, 4)), (1, 0));

        let tail = rwkv_log_tail(t, col, 0, true, false).unwrap();
        assert_eq!((word(&tail, 0), word(&tail, 2), word(&tail, 3)), (2, 2, 1));
        let s = String::from_utf8_lossy(&tail);
        assert!(s.contains(&w.c_log.text()) && s.contains(&c), "{s}");
        assert!(
            !s.contains(&w.log[0].text()) && !s.contains(&w.log[1].text()),
            "{s}"
        );
        assert!(t.conn().is_autocommit());
    });
}

/// RWKV 尾巴只给**代表**出行（`cache.rs` `log_class_rep`：类里操作号最小的那份）：同一次 Anki 复习的两份带盐导入，承袭来的
/// 那份（设备 0x11，操作号小）先落库、是代表；本机写的那份（0xa1）后落库。`since` 卡在两份之间时增量尾巴里只有后落库的
/// 那份：它不是代表，不出行（指纹照数它）。代表规则改成「取操作号最大的」或「每份都算」都会多出一行。
#[test]
fn the_log_tail_names_a_class_only_through_its_smallest_op() {
    use super::training::rwkv_log_tail;
    use crate::store::gen4::derive::Ref;
    with(|t, col| {
        let w = land(t, col);
        let seq = |lid: Id| -> i64 {
            t.conn()
                .query_row(
                    "SELECT s.n FROM log_seq s JOIN log_ix l ON l.col = s.col AND l.card = s.card AND l.k = s.k \
                     WHERE s.col = ?1 AND l.id = ?2",
                    rusqlite::params![col, Ref::of(&u(lid))],
                    |r| r.get(0),
                )
                .unwrap()
        };
        let (rep, other) = (seq(w.log[0]), seq(w.log[1]));
        assert!(
            rep < other,
            "the heritage copy lands first: {rep} / {other}"
        );
        let word = |b: &[u8], k: usize| i64::from_le_bytes(b[8 * k..8 * k + 8].try_into().unwrap());
        // [count, maxN, newRows, tailRows]
        let only_other = rwkv_log_tail(t, col, rep, true, true).unwrap();
        assert_eq!(
            (
                word(&only_other, 0),
                word(&only_other, 1),
                word(&only_other, 2),
                word(&only_other, 3)
            ),
            (1, other, 1, 0),
            "the later copy is counted but is not the representative"
        );
        // 两份都在尾巴里：只出一行（代表那份，ID 是规范的）。
        let both = rwkv_log_tail(t, col, rep - 1, true, true).unwrap();
        assert_eq!((word(&both, 2), word(&both, 3)), (2, 1));
        assert!(String::from_utf8_lossy(&both).contains(&w.c_log.text()));
        assert!(t.conn().is_autocommit());
    });
}

/// 评分预览（`cmd/preview.rs`）按类：用任何成员卡问都是规范卡的预览（重放那一次复习、笔记与牌组是规范 ID）；按成员给的
/// 笔记先归一。
#[test]
fn preview_of_any_member_is_the_preview_of_the_canonical_card() {
    use super::preview::preview;
    with(|t, col| {
        let w = land(t, col);
        let now = ANKI_REVLOG + 2 * 86_400_000;
        let canon = preview(t, col, &w.c_card.text(), None, now, 0, 4).unwrap();
        assert_eq!(canon["note"], json!(w.c_note.text()), "{canon}");
        assert_eq!(canon["deck"], json!(id(DECK).text()), "{canon}");
        assert_eq!(canon["current"]["reps"], json!(1), "{canon}");
        for m in [&w.card[0], &w.card[1]] {
            assert_eq!(preview(t, col, &m.text(), None, now, 0, 4).unwrap(), canon);
        }
        for n in [&w.note[0], &w.note[1]] {
            assert_eq!(
                preview(t, col, &w.card[0].text(), Some(&n.text()), now, 0, 4).unwrap(),
                canon
            );
        }
        assert!(t.conn().is_autocommit());
    });
}

/// 真库基准（手动跑，默认忽略）：`FUSHI_G4_BENCH_DB` 指向一份新代库的**副本**（会被 `schema::open` 装触发器 / 统计，
/// 不要指向在用的库），量 `conflict_edits`（牌组列表冲突角标同一份规则：flag + setting 两类）与寄存器内核裁决的
/// 耗时、行数，再与「修前」口径对拍裁决后的冲突集合：修前 = 旧候选（有 `R_LIVE` 写入的实体 ∪ 别名表里有别名的
/// 实体）× 每个寄存器都按类重判（[Index::class_lines_by] 不走捷径）× 一个键上活着两条以上就交回。
/// `FUSHI_G4_BENCH_LIMIT` = 修前只跑前 N 个候选（对拍限在这些实体上）；`FUSHI_G4_BENCH_SKIP_OLD` = 不跑修前。
///
/// ```text
/// FUSHI_G4_BENCH_DB=<副本> cargo test --profile quick --lib real_db_conflict_edits_bench -- --ignored --nocapture
/// ```
#[test]
#[ignore = "needs FUSHI_G4_BENCH_DB (a copy of a real gen4 library)"]
fn real_db_conflict_edits_bench() {
    use std::collections::BTreeMap;
    use std::time::Instant;

    use crate::registers::registers_report;
    use crate::store::gen4::class::Pick;
    use crate::store::gen4::derive::Ref;
    use crate::store::gen4::schema;

    let path = std::env::var("FUSHI_G4_BENCH_DB").expect("FUSHI_G4_BENCH_DB");
    let limit: Option<usize> = std::env::var("FUSHI_G4_BENCH_LIMIT")
        .ok()
        .map(|s| s.parse().unwrap());
    let skip_old = std::env::var("FUSHI_G4_BENCH_SKIP_OLD").is_ok();
    let conn = schema::open(std::path::Path::new(&path)).unwrap();
    let t = Truth::new(&conn);
    let col: i64 = conn
        .query_row("SELECT MIN(col) FROM collections", [], |r| r.get(0))
        .unwrap();
    // Dart `srsFieldClassRules({flag, setting})`。
    let rules = json!([
        {"kind": "profile", "drop": []},
        {"kind": "deck", "drop": ["collapsed", "position", "extendLimits"]},
        {"kind": "notetype", "keep": ["name", "termField", "freqField"]},
        {"kind": "note", "keep": ["deck", "noteType"]},
        {"kind": "card", "drop": ["newPos"]},
    ]);
    // 一组 (k, i, f, j) 行 → 寄存器内核对每个寄存器的裁决：`k/i/f` → (活着的, 冲突, 可见败者)，按记录 ID。
    type Verdicts = BTreeMap<String, (String, bool, String)>;
    let judge = |rows: &[(String, String, String, String)]| -> Verdicts {
        let mut by: BTreeMap<String, Vec<&str>> = BTreeMap::new();
        for (k, i, f, j) in rows {
            by.entry(format!("{k}/{i}/{f}")).or_default().push(j);
        }
        let mut out = Verdicts::new();
        for (reg, js) in by {
            let stored: Vec<crate::registers::StoredEdit<'_>> =
                js.iter().map(|j| (*j, None, None)).collect();
            let rep = registers_report(&stored).unwrap();
            let r = &rep["regs"][0];
            out.insert(
                reg,
                (r[1].to_string(), r[2].as_bool().unwrap(), r[3].to_string()),
            );
        }
        out
    };

    // 修后：读命令本身。
    let mut read_ms = Vec::new();
    let mut rows = Vec::new();
    for _ in 0..3 {
        let started = Instant::now();
        rows = read(&t, col, json!({"q": "conflict_edits", "rules": rules})).1;
        read_ms.push(started.elapsed().as_millis());
    }
    let bytes: usize = rows.iter().flatten().map(String::len).sum();
    let new_rows: Vec<(String, String, String, String)> = rows
        .iter()
        .map(|r| (r[0].clone(), r[1].clone(), r[2].clone(), r[3].clone()))
        .collect();
    let started = Instant::now();
    let new_verdicts = judge(&new_rows);
    let judge_ms = started.elapsed().as_millis();
    println!(
        "NEW conflict_edits: {read_ms:?} ms (cold, warm, warm), {} rows, {bytes} bytes, {} registers; kernel judge {judge_ms} ms; visible conflicts {}",
        new_rows.len(),
        new_verdicts.len(),
        new_verdicts.values().filter(|v| v.2 != "[]").count()
    );
    for (reg, v) in &new_verdicts {
        println!("  NEW register {reg} {v:?}");
    }
    if skip_old {
        return;
    }

    // 修前口径。
    let mut ix = Index::new(&t, col);
    let parsed = reads::Rules::parse(&ix, &rules).unwrap();
    let started = Instant::now();
    let mut cands: BTreeSet<(i64, Ref)> = BTreeSet::new();
    for q in [
        "SELECT DISTINCT ekind, ent FROM reg_ix WHERE col = ?1 AND state = 1",
        "SELECT DISTINCT r.ekind, a.id FROM alias_ix a CROSS JOIN reg_ix r \
         ON r.col = a.col AND r.ent = a.id WHERE a.col = ?1 AND a.canon != a.id",
    ] {
        let mut stmt = conn.prepare(q).unwrap();
        let got: Vec<(i64, Ref)> = stmt
            .query_map([col], |r| Ok((r.get(0)?, r.get(1)?)))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        for (k, e) in got {
            cands.insert((k, ix.canonical(&e).unwrap()));
        }
    }
    let total = cands.len();
    let cand_ms = started.elapsed().as_millis();
    ix.pass_writers = Some(std::rc::Rc::new(ix.writer_aliases().unwrap()));
    ix.pass_rules_begin().unwrap();
    let mut old_rows: Vec<(String, String, String, String)> = Vec::new();
    let mut covered: BTreeSet<String> = BTreeSet::new();
    let started = Instant::now();
    for (n, (k, c)) in cands.into_iter().enumerate() {
        if limit.is_some_and(|l| n >= l) {
            break;
        }
        let kind = EntKind::ALL.into_iter().find(|x| *x as i64 == k).unwrap();
        covered.insert(format!("{}/{}", kind.wire(), c.text()));
        let (lines, _) = ix.class_lines_by(kind, &c, &Pick::All, false).unwrap();
        let mut by: BTreeMap<String, Vec<String>> = BTreeMap::new();
        for (f, j, _) in lines {
            if kind == EntKind::Note && f == "tags" {
                continue;
            }
            by.entry(f).or_default().push(j);
        }
        for (f, js) in by {
            if js.len() < 2 || !parsed.tracks(kind, &f) {
                continue;
            }
            for j in js {
                old_rows.push((kind.wire().to_owned(), c.text(), f.clone(), j));
            }
        }
    }
    let old_ms = started.elapsed().as_millis();
    let old_verdicts = judge(&old_rows);
    let old_bytes: usize = old_rows
        .iter()
        .map(|r| r.0.len() + r.1.len() + r.2.len() + r.3.len())
        .sum();
    println!(
        "OLD (all class-judged, old candidates {total}, ran {}): candidates {cand_ms} ms + lines {old_ms} ms, {} rows, {old_bytes} bytes, {} registers; conflicted {}, visible conflicts {}",
        covered.len(),
        old_rows.len(),
        old_verdicts.len(),
        old_verdicts.values().filter(|v| v.1).count(),
        old_verdicts.values().filter(|v| v.2 != "[]").count()
    );
    // 对拍：限在修前跑过的实体上。修后交回的寄存器是修前的子集、裁决逐个相同；修前判出冲突（含全是机器产出、
    // 没有可见败者的）的寄存器修后一个不少。
    let in_scope = |reg: &String| covered.iter().any(|e| reg.starts_with(&format!("{e}/")));
    let new_scoped: Verdicts = new_verdicts
        .iter()
        .filter(|(r, _)| in_scope(r))
        .map(|(a, b)| (a.clone(), b.clone()))
        .collect();
    for (reg, v) in &new_scoped {
        assert_eq!(old_verdicts.get(reg), Some(v), "{reg}");
    }
    let conflicted = |v: &Verdicts| -> Verdicts {
        v.iter()
            .filter(|(_, x)| x.1)
            .map(|(a, b)| (a.clone(), b.clone()))
            .collect()
    };
    assert_eq!(
        conflicted(&new_scoped),
        conflicted(&old_verdicts),
        "conflicted registers differ"
    );
    println!(
        "MATCH: {} conflicted registers ({} with visible losers) identical; {} new registers all identical to old",
        conflicted(&old_verdicts).len(),
        old_verdicts.values().filter(|v| v.2 != "[]").count(),
        new_scoped.len()
    );
}
