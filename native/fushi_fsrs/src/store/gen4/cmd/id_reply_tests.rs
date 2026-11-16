//! G9-7 ID 口径：Dart 向内核要的根上 ID（`ids`，`gen4_ids/derive.rs`）就是读命令回的规范 ID；写命令回包带落下的规范
//! 实体 ID（`entityWrites`）；按实体出行的读（`entities` / `edits`）给请求里是别名成员的 ID 回一张「请求 → 规范」表
//! （`canon`）。全新库与迁移来的库（存量实体是协议 3 按 uid 加盐派生的）两种来源都走一遍，全部经 C ABI。

use serde_json::{Value, json};

use super::dispatch_tests::{T1, call, g4, g4req, migrated, open};
use super::tests::decode;
use super::tests_class;
use crate::gen4::op::tests::id;
use crate::gen4_ids::derive::derive;
use crate::store::ffi::{SrsCoreHandle, ffsrs_store_close};
use crate::store::gen4::files::OpenMode;
use crate::store::gen4::kernel::G4Core;
use crate::store::sync2::config::default_deck_id;
use crate::store::sync2::tests::{P, tempdir};

/// Dart `SrsKernelIds(P)` 问到的一个根上 ID。
fn ask(item: Value) -> String {
    let v = derive(&json!({"profile": P, "items": [item]})).unwrap();
    v[0].as_str().unwrap().to_owned()
}

fn entity(kind: &str, id: &str) -> Value {
    json!({"e": {"t": "entity", "x": {"id": id, "p": P, "k": kind, "d": {"createdAt": 0}}}, "note": null})
}

fn edit(kind: &str, id: &str, key: &str, v: Value) -> Value {
    json!({
        "e": {"t": "edit", "x": {"p": P, "k": kind, "e": id, "f": key, "v": v, "ts": "anchored"}},
        "note": null,
    })
}

/// 一条单表读：(JSON 回包, 列名, 行)。
fn read(h: *mut SrsCoreHandle, req: Value) -> (Value, Vec<String>, Vec<Vec<String>>) {
    let (v, f) =
        call(h, &g4req("read", T1, req), None).unwrap_or_else(|(rc, e)| panic!("{rc} {e}"));
    let (cols, rows) = decode(&f.iter().find(|(n, _)| n == "t").unwrap().1);
    (v, cols, rows)
}

fn deck_ids(h: *mut SrsCoreHandle) -> Vec<String> {
    let (_, _, rows) = read(h, json!({"q": "entities", "kind": "deck", "bare": true}));
    rows.into_iter().map(|r| r[0].clone()).collect()
}

/// 全新库：`ids` 答的牌组 / 默认牌组 ID 写进去，读回来就是它（没有别名、`canon` 表为空），回包 `entityWrites` 也是它。
#[test]
fn a_fresh_library_reads_back_the_ids_it_was_asked() {
    let dir = tempdir::new("g97fresh");
    let h = open(&dir.0, 0).unwrap();
    g4(h, "identity", T1, json!({}));
    let default = ask(json!(["default_deck"]));
    let deck = ask(json!(["deck", "Lang"]));
    let items = vec![
        entity("deck", &default),
        edit("deck", &default, "name", json!("Default")),
        entity("deck", &deck),
        edit("deck", &deck, "name", json!("Lang")),
    ];
    let (v, _) = call(h, &g4req("apply", T1, json!({})), Some(&items)).unwrap();
    assert_eq!(
        v["entityWrites"],
        json!([[0, "deck", default], [2, "deck", deck]]),
        "{v}"
    );
    let mut want = vec![default.clone(), deck.clone()];
    want.sort();
    let mut got = deck_ids(h);
    got.sort();
    assert_eq!(got, want);
    let (j, _, rows) = read(h, json!({"q": "edits", "kind": "deck", "ids": [deck]}));
    assert!(j.get("canon").is_none(), "{j}");
    assert!(rows.iter().all(|r| r[0] == deck) && !rows.is_empty());
    let canon = g4(h, "canonical_ids", T1, json!({"ids": [default, deck]}));
    assert_eq!(canon["ids"], json!([default, deck]));
    ffsrs_store_close(h);
}

/// 迁移来的库：默认牌组是协议 3 按 uid 加盐的 ID。`ids` 答的（规范）默认牌组与内核归一的结果相同；拿它再写一遍
/// 身份记录不另建牌组（只有一个默认牌组类）；拿带盐的旧 ID 写，回包报的是规范 ID；按旧 ID 读，`canon` 表把它对回去。
#[test]
fn a_migrated_library_folds_the_salted_builtins_into_the_ids_it_answers() {
    let m = migrated();
    let salted = default_deck_id(P);
    let default = ask(json!(["default_deck"]));
    assert_ne!(salted, default);
    let canon = g4(m.h, "canonical_ids", T1, json!({"ids": [salted]}));
    assert_eq!(
        canon["ids"],
        json!([default]),
        "the salted default deck folds into the answer"
    );
    let before = deck_ids(m.h);
    assert!(before.contains(&default), "{before:?}");
    assert!(!before.contains(&salted), "{before:?}");

    let items = vec![
        entity("deck", &default),
        entity("deck", &salted),
        edit("deck", &salted, "collapsed", json!(true)),
    ];
    let (v, _) = call(m.h, &g4req("apply", T1, json!({})), Some(&items)).unwrap();
    assert_eq!(
        v["entityWrites"],
        json!([[0, "deck", default], [1, "deck", default]]),
        "{v}"
    );
    assert_eq!(
        v["landed"][0],
        json!(false),
        "the default deck already exists: {v}"
    );
    assert_eq!(v["edits"][0][1], json!(default), "{v}");
    assert_eq!(v["edits"][0][6], json!(2), "{v}");
    assert_eq!(deck_ids(m.h), before, "no second default deck");

    // 按带盐的旧 ID 读：行是规范 ID，`canon` 把请求对回去；规范 ID 本身不进表。
    let (j, _, rows) = read(
        m.h,
        json!({"q": "edits", "kind": "deck", "ids": [salted, default]}),
    );
    assert_eq!(j["canon"], json!({salted.clone(): default}), "{j}");
    assert!(!rows.is_empty() && rows.iter().all(|r| r[0] == default));
    let (j, cols, rows) = read(m.h, json!({"q": "entities", "ids": [salted]}));
    assert_eq!(j["canon"], json!({salted.clone(): default}), "{j}");
    let id_at = cols.iter().position(|c| c == "id").unwrap();
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0][id_at], default);
}

/// 别名类里的非规范成员（两个盐的同一条笔记）：身份记录按输入下标报规范 ID；`entities` / `edits` 按成员读回 `canon`。
#[test]
fn members_of_an_alias_class_report_and_read_back_canonically() {
    let dir = tempdir::new("g97alias");
    let w = {
        let c = G4Core::open(&dir.0, OpenMode::Primary).unwrap();
        let col = c.write(|t| t.bind(P, &id(0xc0), "dir")).unwrap();
        let w = c.write(|t| Ok(tests_class::land(t, col))).unwrap();
        c.write(|t| t.create_self(col, &id(0xee), &[9; 32], None, T1))
            .unwrap();
        c.close();
        w
    };
    let h = open(&dir.0, 0).unwrap();
    let (member, other, canon) = (w.note[1].text(), w.note[0].text(), w.c_note.text());
    let items = vec![
        edit(
            "note",
            &member,
            &format!("f/{}", w.field[1].text()),
            json!("g97"),
        ),
        entity("note", &member),
    ];
    let (v, _) = call(h, &g4req("apply", T1, json!({})), Some(&items))
        .unwrap_or_else(|(rc, e)| panic!("{rc} {e}"));
    assert_eq!(v["entityWrites"], json!([[1, "note", canon]]), "{v}");
    let (j, _, rows) = read(
        h,
        json!({"q": "edits", "kind": "note", "ids": [member, other, "not-an-entity"]}),
    );
    assert_eq!(
        j["canon"],
        json!({member.clone(): canon, other.clone(): canon}),
        "{j}"
    );
    assert!(!rows.is_empty() && rows.iter().all(|r| r[0] == canon));
    let (j, _, rows) = read(h, json!({"q": "entities", "ids": [member, canon]}));
    assert_eq!(j["canon"], json!({member.clone(): canon}), "{j}");
    assert_eq!(rows.len(), 1, "one class, one row");
    ffsrs_store_close(h);
}
