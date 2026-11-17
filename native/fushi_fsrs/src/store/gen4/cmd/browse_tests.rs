//! 浏览读命令（`browse.rs`）的测试。
//!
//! - **对拍**：同一个协议 3 的库（`tests.rs` 的 `library`）一侧在协议 3 的缓存表上跑同一份会话实现（`store::browse`
//!   的 [P3] 读法，缓存按新代同一份配置在 SAVEPOINT 里重建），另一侧灌进新代跑 [Browse]；同一串命令（全部排序列 ×
//!   卡片 / 笔记模式 × 一组查询、取行、行 id、批量目标、计数、出处分组、AnkiConnect 查找 / 标签 / 查重）逐条比回包
//!   （ID 归一成规范 ID、去掉进程内的结果代号）与列式文件的字节。
//!   库比 `tests.rs` 的多一条只有隐藏卡的笔记（[browse_library]）；查询里有带评分的 `rated:`。
//! - **别名类**（只有新代有）：`tests_class.rs` 的两份带盐笔记场景，请求里给成员 ID / 成员号与给规范 ID 结果相同；
//!   以 ID 为键的表（牌组名、牌组模型、查重首字段）按成员键也落到规范键上，几个键时取舍确定。
//! - **失效**：写入（逐条维护的收尾）之后同一个会话按代号增量重读，结果与新建的会话相同、不整份重建——含隐藏卡出现 /
//!   消失、迟到的盐把一条已物化的笔记并进别的类（别名挪动）；整层重建、写事务里读过又回滚、记录被截都对。
//! - **代价**：实际执行的语句（trace 抓的，不是抄的 SQL）逐条 EXPLAIN；一次增量重读的虚拟机步数不随集合变大、没有
//!   全表扫描步。

use std::cell::RefCell;
use std::collections::{HashMap, HashSet};

use rusqlite::Connection;
use serde_json::{Value, json};

use super::Files;
use super::browse::{Browse, G4, REFRESH_CAP, canon_req};
use super::tests::{N1, N2, N3, Pair, T0, card, library, note, on_p3};
use super::tests_class::{ANKI_NT, DECK, Twin, base_ops, land, set, twin, u};
use crate::gen4::op::tests::id;
use crate::gen4_ids::rules::{self, CANONICAL};
use crate::store::browse::{P3, Sessions, Source};
use crate::store::gen4::derive::Index;
use crate::store::gen4::derive::tests::{native, op, with};
use crate::store::gen4::truth::Truth;
use crate::store::queue::Dirty;
use crate::store::schema::anki_numeric_id as num;
use crate::store::sync2::config::default_deck_id;
use crate::store::sync2::tests::{DAY, P};
use crate::sync2::id::Id;
use crate::sync2::op::EntKind;

const NOW: i64 = T0 + 3 * DAY;

/// `tests_class.rs` 场景之外的第三个盐（别名挪动的测试里迟到）。
const U3: &str = "0192f0aa-0000-7000-8000-00000000000c";

/// 浏览查询的上下文（Dart `srsBrowseContext` 的形状），合进 [extra]。
fn ctx(types: Value, deck: &str, extra: Value) -> Value {
    let mut req = json!({
        "owner": "page:test",
        "now": NOW,
        "utcOff": 0,
        "rollover": 4,
        "types": types,
        "decks": {deck: ["Default", false]},
        "fallback": ["Default", false],
        "models": [["fsrs6", []]],
        "deckModels": {deck: 0},
        "fallbackModel": 0,
    });
    for (k, v) in extra.as_object().unwrap() {
        req[k] = v.clone();
    }
    req
}

fn library_types() -> Value {
    json!([{"id": "NT", "name": "Basic", "fields": [["fa", "Expression"], ["fb", "Meaning"]],
            "tpls": [["t1", "A", 0], ["t2", "B", 1]]},
           {"id": "NT2", "name": "Word", "fields": [["fx", "Word"], ["fy", "Extra"]],
            "tpls": [["u1", "X", 0]]}])
}

/// 只有一张卡、卡的模板判空（隐藏）的那条笔记：笔记活着，卡不显示。
const N6: &str = "0193a1b2-0000-7000-8000-0000000000a6";

/// 对拍的库：`tests.rs` 的 [library] 再加一个笔记类型 NT2（唯一的模板只引用第二个字段）与它的一条只填了第一个字段
/// 的笔记 [N6]——那张卡渲染为空、缓存行 `hidden = 1`，让对拍碰到隐藏卡（会话、按笔记找牌组都不该看见它）。
fn browse_library() -> crate::store::sync2::tests::Device {
    use crate::store::sync2::tests::edit;
    let d = library();
    d.apply(
        T0 + 2 * DAY,
        vec![
            json!({"t": "entity", "x": {"id": "NT2", "p": P, "k": "notetype", "d": {"createdAt": 2, "ntKind": "standard"}}}),
            edit("notetype", "NT2", "fieldDef/fx", json!({"name": "Word", "ord": 0})),
            edit("notetype", "NT2", "fieldDef/fy", json!({"name": "Extra", "ord": 1})),
            edit(
                "notetype",
                "NT2",
                "tmplDef/u1",
                json!({"name": "X", "ord": 0, "front": "{{Extra}}"}),
            ),
            note(N6, "NT2", 50),
            edit("note", N6, "f/fx", json!("鯨")),
        ],
    );
    d
}

type Run<'a> = dyn FnMut(&str, Value) -> (Value, Files) + 'a;

/// 回包里去掉进程内的结果代号。
fn strip(mut v: Value) -> Value {
    if let Some(o) = v.as_object_mut() {
        o.remove("gen");
    }
    v
}

/// 同一串命令（模块文件头「对拍」）；每条的 (op, 回包, 文件)。
fn script(run: &mut Run<'_>, deck: &str) -> Vec<(String, Value, Files)> {
    let mut out: Vec<(String, Value, Files)> = Vec::new();
    let mut push = |op: &str, v: Value, f: Files| out.push((op.to_owned(), strip(v), f));
    let q = |extra: Value| ctx(library_types(), deck, extra);
    let nodes = [
        Value::Null,
        json!({"t": "text", "v": "猫"}),
        json!({"t": "field", "f": "Meaning", "v": "*dog*"}),
        json!({"t": "tag", "v": "a"}),
        json!({"t": "state", "v": "new"}),
        json!({"t": "rated", "d": 3650}),
        // 带评分：库里有评 3 的、也有评 1 的复习（同一张卡两种都有，别的卡只有 3）。
        json!({"t": "rated", "d": 3650, "e": 1}),
        json!({"t": "rated", "d": 3650, "e": 3}),
        json!({"t": "dupe"}),
        json!({"t": "emptyfield"}),
        json!({"t": "src", "v": "none"}),
        json!({"t": "edited", "v": 3650}),
        json!({"t": "prop", "p": "reps", "op": "ge", "v": 1.0, "iv": 1}),
        json!({"t": "deck", "v": "Default"}),
        json!({"t": "has", "v": "image"}),
        json!({"t": "or", "c": [{"t": "nid", "v": [num(N1)]}, {"t": "not", "c": {"t": "tag", "v": "b"}}]}),
    ];
    let columns = [
        "created",
        "sortField",
        "field",
        "due",
        "modified",
        "interval",
        "difficulty",
        "retention",
        "reps",
        "lapses",
        "deck",
        "noteType",
        "source",
    ];
    let mut errors = 0;
    let mut errs: Vec<String> = Vec::new();
    for (i, node) in nodes.iter().enumerate() {
        for mode in ["cards", "notes"] {
            for col in columns {
                let asc = i % 2 == 0;
                let (v, f) = run(
                    "browse_query",
                    q(json!({"node": node, "mode": mode,
                             "sort": {"col": col, "asc": asc, "field": "Meaning"}})),
                );
                let gen = v["gen"].clone();
                let failed = v.get("error").is_some();
                if failed {
                    errs.push(format!("{node} {v}"));
                }
                push("browse_query", v, f);
                if failed {
                    errors += 1;
                    continue;
                }
                let (v, f) = run("browse_rows", json!({"owner": "page:test", "gen": gen}));
                push("browse_rows", v, f);
            }
        }
    }
    assert_eq!(
        errors,
        0,
        "every query of the script evaluates: {:?}",
        &errs[..1]
    );
    // 最后一条查询（全部、按出处排）之外再来一条：全部卡、按创建时刻。
    let (v, _) = run(
        "browse_query",
        q(json!({"mode": "cards", "sort": {"col": "created", "asc": true}})),
    );
    let gen = v["gen"].clone();
    let (ids, f) = run("browse_ids", json!({"gen": gen, "from": 1}));
    push("browse_ids", ids.clone(), f);
    let mut find: Vec<Value> = ids["ids"].as_array().unwrap().clone();
    find.push(json!("nope"));
    let (v, f) = run("browse_ids", json!({"gen": gen, "find": find}));
    push("browse_ids", v, f);
    let (v, f) = run(
        "browse_targets",
        json!({"gen": gen, "ids": ids["ids"].as_array().unwrap()[..2]}),
    );
    push("browse_targets", v, f);
    let (v, f) = run("browse_sources", json!({"gen": gen}));
    push("browse_sources", v, f);
    let (v, f) = run(
        "browse_counts",
        q(json!({"nodes": nodes.iter().cloned().chain([Value::Bool(false)]).collect::<Vec<_>>()})),
    );
    push("browse_counts", v, f);
    let (v, f) = run("browse_counts", q(json!({"mode": "notes", "nodes": nodes})));
    push("browse_counts", v, f);
    // 同一条查询、会话没变：直接给回上次的结果。
    let mut again = q(json!({"mode": "cards", "sort": {"col": "created", "asc": true}}));
    again["since"] = gen.clone();
    let (v, f) = run("browse_query", again);
    assert_eq!(v["same"], json!(true), "{v}");
    push("browse_query", v, f);
    for (mode, uuids) in [("notes", false), ("cards", true)] {
        let (v, f) = run(
            "anki_find",
            q(
                json!({"owner": "ankiconnect", "mode": mode, "uuids": uuids, "node": {"t": "text", "v": "猫"}}),
            ),
        );
        push("anki_find", v, f);
    }
    let (v, f) = run("anki_tags", json!({"owner": "ankiconnect"}));
    push("anki_tags", v, f);
    let norm = crate::search::dupe_norm;
    let (v, f) = run(
        "anki_dupes",
        json!({"first": {"NT": "fa", "NT2": "fx"}, "cands": [
            {"norm": norm("猫"), "type": "NT", "all": false, "decks": null},
            {"norm": norm("猫"), "type": "X", "all": false, "decks": null},
            {"norm": norm("猫"), "type": "X", "all": true, "decks": [deck]},
            {"norm": norm("犬"), "type": "NT", "all": false, "decks": ["elsewhere"]},
            {"norm": norm("鳥"), "type": "NT", "all": false, "decks": null},
            // N6 只有一张隐藏卡：不限牌组时算重复，限在它那张卡的牌组里不算（隐藏卡不给笔记带来牌组）。
            {"norm": norm("鯨"), "type": "NT2", "all": false, "decks": null},
            {"norm": norm("鯨"), "type": "NT2", "all": false, "decks": [deck]},
        ]}),
    );
    push("anki_dupes", v, f);
    let (v, f) = run("browse_stats", json!({}));
    push("browse_stats", v, f);
    let (v, f) = run("browse_close", json!({"owner": "page:test"}));
    push("browse_close", v, f);
    let (v, f) = run("browse_close", json!({"owner": "ankiconnect"}));
    push("browse_close", v, f);
    let (v, f) = run("browse_stats", json!({}));
    push("browse_stats", v, f);
    out
}

/// 协议 3 一侧的一条命令：会话表与 `SrsCore::browse` 同一个分发（`Sessions::run`），读法是 [P3]；它的「待重读」在
/// 这里恒为空（一串命令之间不写库）。
fn p3_run(c: &Connection, s: &mut Sessions, op: &str, req: Value) -> (Value, Files) {
    let mut files = Files::new();
    let src = P3 { c, profile: P };
    let owner = req.get("owner").and_then(Value::as_str);
    let v = match op {
        "browse_close" => s.close(P, owner),
        "browse_stats" => s.stats(P),
        "anki_dupes" => crate::store::browse::dupes(&src, &req).unwrap(),
        _ => s
            .run(P, op, &req, &mut files, &src, &mut |_| {
                Ok((Dirty::default(), 0))
            })
            .unwrap(),
    };
    (v, files)
}

/// 协议 3 的回包里每个字符串换成它的规范 ID（不是 ID 的字符串原样）。
fn canon_json(p: &Pair<'_>, v: &Value) -> Value {
    match v {
        Value::String(s) => Value::String(p.canon(s)),
        Value::Array(a) => Value::Array(a.iter().map(|x| canon_json(p, x)).collect()),
        Value::Object(o) => Value::Object(
            o.iter()
                .map(|(k, x)| (p.canon(k), canon_json(p, x)))
                .collect(),
        ),
        x => x.clone(),
    }
}

/// 全部浏览命令与协议 3 对拍（模块文件头「对拍」）。
#[test]
fn browse_commands_match_protocol_3() {
    let d = browse_library();
    let p = Pair::new(&d);
    let deck = default_deck_id(P);
    let w = d.core.writer().unwrap();
    let p3 = on_p3(&w, &p.cfg, |c| {
        let mut s = Sessions::default();
        script(&mut |op, req| p3_run(c, &mut s, op, req), &deck)
    });
    let t = Truth::new(&p.g4);
    let mut b = Browse::new();
    let g4 = script(
        &mut |op, req| {
            let mut files = Files::new();
            let v = b.run(&t, p.col, op, &req, &mut files).unwrap();
            assert!(
                p.g4.is_autocommit(),
                "a browse command leaves no transaction open"
            );
            (v, files)
        },
        &deck,
    );
    assert_eq!(p3.len(), g4.len());
    let mut rows = 0;
    for (i, ((op, pv, pf), (gop, gv, gf))) in p3.iter().zip(&g4).enumerate() {
        assert_eq!(op, gop);
        assert_eq!(&canon_json(&p, pv), gv, "#{i} {op}");
        assert_eq!(pf, gf, "#{i} {op}: files");
        if op == "browse_rows" {
            rows += gv["s"].as_array().unwrap().len();
        }
    }
    assert!(rows > 300, "the script reads real rows ({rows})");
    // 有命中的查询、有出处之外的分组、有查重命中：对拍不是在比一堆空结果。
    let dupes = &g4.iter().find(|(op, ..)| op == "anki_dupes").unwrap().1;
    assert_eq!(
        dupes["dup"],
        json!([true, false, true, false, false, true, false])
    );
    let tags = &g4.iter().find(|(op, ..)| op == "anki_tags").unwrap().1;
    assert_eq!(tags["tags"], json!(["a", "b"]));
    // 评分筛选真的分得开：计数里「评过分的」比「评 1 的」多（评 1 的只有一张卡），对拍才卡得住评分条件。
    let counts = &g4.iter().find(|(op, ..)| op == "browse_counts").unwrap().1;
    let n = |i: usize| counts["counts"][i].as_i64().unwrap();
    assert!(n(6) >= 1 && n(6) < n(5) && n(7) >= 1, "{counts}");
    // 隐藏卡不在任何一个回包里。
    let hidden = card(N6, "u1");
    for (op, v, _) in &g4 {
        assert!(
            !v.to_string().contains(&hidden),
            "{op}: the hidden card shows up: {v}"
        );
    }
}

// ---------------------------------------------------------------------- 别名类（只有新代有）

fn twin_types(w: &Twin, which: Option<usize>) -> Value {
    let c_nt = rules::note_type(CANONICAL, ANKI_NT);
    let (nt, field, tmpl) = match which {
        Some(i) => (w.nt[i], w.field[i], w.tmpl[i]),
        None => (c_nt, w.c_field, rules::template(&c_nt, 0)),
    };
    json!([{"id": nt.text(), "name": "Twin", "fields": [[field.text(), "E"]],
            "tpls": [[tmpl.text(), "A", 0]]}])
}

fn run_raw(b: &mut Browse, t: &Truth<'_>, col: i64, op: &str, req: Value) -> Value {
    let mut files = Files::new();
    b.run(t, col, op, &req, &mut files).unwrap()
}

fn run(b: &mut Browse, t: &Truth<'_>, col: i64, op: &str, req: Value) -> (Value, Files) {
    let mut files = Files::new();
    let v = b.run(t, col, op, &req, &mut files).unwrap();
    (strip(v), files)
}

/// 请求里给别名类成员（带盐的笔记类型 / 字段 / 模板、带盐牌组、成员卡 ID、成员的数字号）与给规范 ID 结果相同；回包里
/// 只有规范 ID，两份带盐副本是一行。
#[test]
fn member_ids_in_requests_resolve_to_the_canonical_rows() {
    with(|t, col| {
        let w = land(t, col);
        let deck = id(DECK).text();
        let mut b = Browse::new();
        let query = |b: &mut Browse, which: Option<usize>| {
            let mut req = ctx(twin_types(&w, which), &deck, json!({}));
            req["sort"] = json!({"col": "field", "asc": true, "field": "E"});
            run_raw(b, t, col, "browse_query", req)
        };
        let canon = query(&mut b, None);
        let g = json!({"gen": canon["gen"]});
        let (rows, _) = run(&mut b, t, col, "browse_rows", g.clone());
        let c_card = w.c_card.text();
        let c_note = w.c_note.text();
        let s = rows["s"].as_array().unwrap().clone();
        assert!(
            s.iter()
                .any(|r| r[0] == json!(c_card) && r[1] == json!(c_note)),
            "{s:?}"
        );
        assert!(
            !s.iter()
                .any(|r| r[1] == json!(w.note[0].text()) || r[1] == json!(w.note[1].text())),
            "{s:?}"
        );
        for which in [Some(0), Some(1)] {
            let v = query(&mut b, which);
            assert_eq!(strip(v), strip(canon.clone()), "{which:?}");
        }
        // 成员卡 ID 找到规范卡所在的行；批量目标按成员 ID 给出规范 ID。
        let (at, _) = run(
            &mut b,
            t,
            col,
            "browse_ids",
            json!({"gen": g["gen"], "find": [w.card[0].text(), c_card, w.card[1].text()]}),
        );
        let at = at["at"].as_array().unwrap().clone();
        assert!(at[0].as_i64().unwrap() >= 0, "{at:?}");
        assert_eq!(at[0], at[1]);
        assert_eq!(at[1], at[2]);
        let (tg, _) = run(
            &mut b,
            t,
            col,
            "browse_targets",
            json!({"gen": g["gen"], "ids": [w.card[1].text()]}),
        );
        assert_eq!(tg["cards"], json!([c_card]));
        assert_eq!(tg["notes"], json!([c_note]));
        // 牌组表里成员键与规范键都在：取规范键自己的（名字决定 `deck:` 命中与否）。
        let mut req = ctx(
            twin_types(&w, None),
            &deck,
            json!({"node": {"t": "deck", "v": "Canon"}}),
        );
        req["decks"] = json!({deck.clone(): ["Canon", false]});
        let (v, _) = run(&mut b, t, col, "browse_query", req.clone());
        assert!(v["count"].as_u64().unwrap() > 0, "{v}");
        // AnkiConnect：成员的数字号（换代前客户端记下的）照样找得到规范笔记 / 卡。
        for (leaf, n) in [
            ("nid", num(&w.note[1].text())),
            ("cid", num(&w.card[0].text())),
        ] {
            let (v, files) = run(
                &mut b,
                t,
                col,
                "anki_find",
                ctx(
                    twin_types(&w, None),
                    &deck,
                    json!({"mode": "cards", "uuids": true, "node": {"t": leaf, "v": [n]}}),
                ),
            );
            assert_eq!(v["cards"], json!([c_card]), "{leaf}");
            let ids: Vec<i64> = files[0]
                .1
                .chunks(8)
                .map(|x| i64::from_le_bytes(x.try_into().unwrap()))
                .collect();
            assert_eq!(ids, vec![num(&c_card)], "{leaf}");
        }
        // 查重：成员笔记类型 ID 与规范的一样认（两份带盐副本各自的值并成一条规范笔记，首字段取类里判出的那个值）。
        let norm = crate::search::dupe_norm;
        let dupes = |b: &mut Browse, nt: String, field: String| {
            run(
                b,
                t,
                col,
                "anki_dupes",
                json!({"first": {nt.clone(): field}, "cands": [
                    {"norm": norm("A"), "type": nt, "all": false, "decks": [deck.clone()]},
                    {"norm": norm("B"), "type": nt, "all": false, "decks": [deck.clone()]},
                    {"norm": norm("B"), "type": nt, "all": false, "decks": ["elsewhere"]},
                ]}),
            )
            .0
        };
        let c_nt = rules::note_type(CANONICAL, ANKI_NT);
        let want = dupes(&mut b, c_nt.text(), w.c_field.text());
        assert_eq!(
            want["dup"]
                .as_array()
                .unwrap()
                .iter()
                .filter(|x| **x == json!(true))
                .count(),
            1,
            "{want}"
        );
        for which in [0usize, 1] {
            let v = dupes(&mut b, w.nt[which].text(), w.field[which].text());
            assert_eq!(v, want, "{which}");
        }
    });
}

/// 以 ID 为键的表（`decks` / `deckModels` / 查重的 `first`）：只给成员键也落到规范键上；同一个类给了几个键时规范键
/// 自己的优先，否则成员里 SQLite 序最小的——与键的先后无关（[canon_keyed](super::canon_keyed)，`stats.rs` 同一份）。
#[test]
fn keyed_tables_resolve_member_keys_to_the_canonical_key() {
    with(|t, col| {
        let w = land(t, col);
        let deck = id(DECK).text();
        // 两份带盐的同名牌组（规范 ID 是不带盐的那个），规范卡挪进去（写在成员卡上）。
        let lang = |s| rules::deck(s, "Lang");
        let (d1, d2, dc) = (
            lang(Some(super::tests_class::U1)),
            lang(Some(super::tests_class::U2)),
            lang(CANONICAL),
        );
        write(
            t,
            col,
            0xd1,
            1,
            1000,
            &[
                set(EntKind::Deck, u(d1), "name", json!("Lang")),
                set(EntKind::Deck, u(d2), "name", json!("Lang")),
                set(EntKind::Card, u(w.card[0]), "deck", json!(d1.text())),
            ],
        );
        let (lo, hi) = {
            let (a, b) = (super::ref_of(&d1.text()), super::ref_of(&d2.text()));
            if super::sql_order(&a) < super::sql_order(&b) {
                (d1, d2)
            } else {
                (d2, d1)
            }
        };
        let hits = |decks: Value| -> u64 {
            let mut req = ctx(
                twin_types(&w, None),
                &deck,
                json!({"node": {"t": "deck", "v": "Lang"}}),
            );
            req["decks"] = decks;
            let v = run_raw(&mut Browse::new(), t, col, "browse_query", req);
            v["count"].as_u64().unwrap_or_else(|| panic!("{v}"))
        };
        let named = |pairs: &[(&Id, &str)]| -> Value {
            let mut m = serde_json::Map::new();
            for (k, name) in pairs {
                m.insert(k.text(), json!([name, false]));
            }
            Value::Object(m)
        };
        assert_eq!(
            hits(named(&[(&dc, "Lang")])),
            1,
            "the card sits in the canonical deck"
        );
        assert_eq!(hits(named(&[(&d1, "Lang")])), 1, "a member key alone");
        assert_eq!(
            hits(named(&[(&d2, "Lang")])),
            1,
            "the other member key alone"
        );
        assert_eq!(
            hits(named(&[(&d1, "Lang"), (&dc, "Other")])),
            0,
            "own key wins"
        );
        assert_eq!(
            hits(named(&[(&dc, "Lang"), (&d2, "Other")])),
            1,
            "own key wins"
        );
        assert_eq!(
            hits(named(&[(&hi, "Other"), (&lo, "Lang")])),
            1,
            "lowest member"
        );
        assert_eq!(
            hits(named(&[(&lo, "Other"), (&hi, "Lang")])),
            0,
            "lowest member"
        );
        // `deckModels` 同一个取舍；查重的 `first`（笔记类型 → 首字段）键按它取、值再归一。
        let src = G4::new(t, col);
        let canon = |req: Value| canon_req(&src, "anki_dupes", &req).unwrap();
        let mut m = serde_json::Map::new();
        m.insert(hi.text(), json!(1));
        m.insert(lo.text(), json!(2));
        assert_eq!(
            canon(json!({"deckModels": m.clone()}))["deckModels"],
            json!({dc.text(): 2})
        );
        m.insert(dc.text(), json!(3));
        assert_eq!(
            canon(json!({"deckModels": m}))["deckModels"],
            json!({dc.text(): 3})
        );
        let c_nt = rules::note_type(CANONICAL, ANKI_NT);
        let first = canon(json!({"first": {
            w.nt[0].text(): w.field[0].text(),
            w.nt[1].text(): w.field[1].text(),
        }}));
        assert_eq!(first["first"], json!({c_nt.text(): w.c_field.text()}));
        let first = canon(json!({"first": {w.nt[1].text(): "x", c_nt.text(): w.field[0].text()}}));
        assert_eq!(first["first"], json!({c_nt.text(): w.c_field.text()}));
    });
}

/// 浏览的修改行（[Source::edits]，`edited:` 与按修改时间排都读它）含笔记的合成 `tags` 行：只加一个标签（OR-Set 操作，
/// 不进寄存器）也把笔记的最后改动时刻推到那条标签操作；只要字段键时不带它；`tags` 不当字段原文（C7）。
#[test]
fn browse_edits_count_the_last_tag_op_as_a_modification() {
    with(|t, col| {
        let w = land(t, col);
        let note = w.c_note.text();
        let field = format!("f/{}", w.c_field.text());
        let modified = |keys: &[String]| -> (Vec<(String, String)>, Option<i64>) {
            let src = G4::new(t, col);
            let mut out = None;
            src.edits(Some(std::slice::from_ref(&note)), keys, &mut |id, rows| {
                assert_eq!(id, note);
                out = Some(crate::registers::note_browse_values(rows)?);
                Ok(())
            })
            .unwrap();
            out.expect("the note has edits")
        };
        let (values, before) = modified(&[]);
        let before = before.expect("field edits");
        assert!(before < 900, "{before}");
        write(
            t,
            col,
            0xd7,
            1,
            900,
            &[crate::gen4::op::Body4::TagAdd {
                note: u(w.note[1]),
                tag: "zz".into(),
            }],
        );
        let (after_values, after) = modified(&[]);
        assert_eq!(after, Some(900));
        assert_eq!(after_values, values, "tags is not a field value");
        assert!(after_values.iter().all(|(k, _)| k != "tags"));
        // 只要字段键：没有 `tags` 行，最后改动时刻还是字段的。
        assert_eq!(modified(std::slice::from_ref(&field)).1, Some(before));
        // 键里点名了 `tags`：带它（只要字段键时省掉的那一行，点名时不能省）。
        assert_eq!(modified(&[field.clone(), "tags".to_owned()]).1, Some(900));
        assert_eq!(modified(&["tags".to_owned()]).1, Some(900));
    });
}

// ---------------------------------------------------------------------- 失效

/// 一批原生写入（一个事务、逐条维护后收尾）。
fn write(
    t: &Truth<'_>,
    col: i64,
    dev: u8,
    seq0: u64,
    wall: i64,
    bodies: &[crate::gen4::op::Body4],
) {
    // 见过 `land` 的全部写入（定义、两份并发的字段改动、删除与迟到的改动）。
    let base = base_ops(&twin()).len() as u64;
    let seen = [(0xa1, base), (0xb1, 1), (0xb2, 1), (0xc1, 1), (0xc2, 1)];
    t.tx(|t| {
        let mut ix = Index::new(t, col);
        for (i, b) in bodies.iter().enumerate() {
            native(
                t,
                &mut ix,
                col,
                &op(dev, seq0 + i as u64, wall + i as i64, &seen, b),
            );
        }
        ix.settle()?;
        Ok(())
    })
    .unwrap();
}

/// 全部可比的结果：每种排序 × 两种模式的行（字符串 + 整数 + 小数）、计数、标签、出处分组。
fn snapshot_of(b: &mut Browse, t: &Truth<'_>, col: i64, types: &Value, deck: &str) -> Vec<Value> {
    let mut out = Vec::new();
    for mode in ["cards", "notes"] {
        for sort in ["created", "field", "modified", "due", "reps"] {
            let mut req = ctx(types.clone(), deck, json!({"mode": mode}));
            req["sort"] = json!({"col": sort, "asc": true, "field": "E"});
            let v = run_raw(b, t, col, "browse_query", req);
            let g = json!({"gen": v["gen"]});
            out.push(strip(v));
            let (v, files) = run(b, t, col, "browse_rows", g.clone());
            out.push(v);
            out.push(json!(files));
            let (v, _) = run(b, t, col, "browse_sources", g);
            out.push(v);
        }
    }
    let (v, _) = run(
        b,
        t,
        col,
        "browse_counts",
        ctx(
            types.clone(),
            deck,
            json!({"nodes": [null, {"t": "text", "v": "A"}, {"t": "dupe"}, {"t": "rated", "d": 3650}]}),
        ),
    );
    out.push(v);
    let (v, _) = run(b, t, col, "anki_tags", json!({}));
    out.push(v);
    out
}

fn stats(b: &mut Browse, t: &Truth<'_>, col: i64) -> Value {
    run(b, t, col, "browse_stats", json!({})).0
}

/// [n] 条新笔记（规范笔记类型，各一个字段值），设备 0xd1 从 [seq0] 起。
fn many_notes(n: u64, seq0: u64) -> Vec<crate::gen4::op::Body4> {
    let nt = rules::note_type(CANONICAL, ANKI_NT);
    let field = rules::field(&nt, 0);
    let mut out = Vec::new();
    for i in 0..n {
        let mut b = [0x77u8; 16];
        b[8..].copy_from_slice(&(seq0 + i).to_be_bytes());
        out.push(super::tests_class::entity(
            EntKind::Note,
            u(Id(b)),
            json!({"createdAt": 10 + i as i64, "guid": format!("m{}", seq0 + i), "noteTypeId": nt.text()}),
        ));
        out.push(set(
            EntKind::Note,
            u(Id(b)),
            &format!("f/{}", field.text()),
            json!(format!("w{}", seq0 + i)),
        ));
    }
    out
}

/// 写入之后同一个会话按代号增量重读：改字段 / 标签、加笔记、删笔记、加复习都与新建的会话结果相同，而且不整份重建
/// （`sessions` 不变、字段列不重装）。
#[test]
fn writes_refresh_the_live_session_by_generation() {
    with(|t, col| {
        let w = land(t, col);
        let deck = id(DECK).text();
        let types = twin_types(&w, None);
        let mut b = Browse::new();
        snapshot_of(&mut b, t, col, &types, &deck);
        assert_eq!(stats(&mut b, t, col)["sessions"], json!(1));
        let field = format!("f/{}", w.c_field.text());
        let field0 = format!("f/{}", w.field[0].text());
        let c_nt = rules::note_type(CANONICAL, ANKI_NT);
        let blank = Id([0x78u8; 16]);
        let blank_card = rules::card(&blank, &rules::template(&c_nt, 0), 0);
        let late = rules::note(Some(U3), "g");
        let steps: Vec<Vec<crate::gen4::op::Body4>> = vec![
            vec![set(EntKind::Note, u(w.c_note), &field, json!("Z changed"))],
            vec![set(EntKind::Note, u(w.note[0]), "tags", json!(["x", "y"]))],
            many_notes(3, 1),
            vec![set(
                EntKind::Note,
                u(Id({
                    let mut b = [0x77u8; 16];
                    b[8..].copy_from_slice(&2u64.to_be_bytes());
                    b
                })),
                "deleted",
                json!(T0),
            )],
            vec![set(EntKind::Card, u(w.c_card), "suspended", json!(true))],
            // 字段没填的笔记：唯一的卡渲染为空、隐藏（会话里有笔记、没有卡）；再填上字段，卡出现。
            vec![super::tests_class::entity(
                EntKind::Note,
                u(blank),
                json!({"createdAt": 7, "guid": "blank", "noteTypeId": c_nt.text()}),
            )],
            vec![set(
                EntKind::Note,
                u(blank),
                &format!("f/{}", rules::field(&c_nt, 0).text()),
                json!("filled"),
            )],
            // 别名挪动（只有新代有）：带一个还不是盐的盐 U3 的同一条笔记（guid `g`）先按它自己的 ID 物化成一行；
            // 之后迟到的盐 U3 把它并进规范笔记 `c_note` 的类——缓存层删掉旧 ID 的行（不整层重建：挪动的 ID 远少于
            // `MOVES_IN_PLACE`），会话也得丢掉那一行。
            vec![
                super::tests_class::entity(
                    EntKind::Note,
                    u(late),
                    json!({"createdAt": 1, "guid": "g", "noteTypeId": w.nt[0].text()}),
                ),
                set(EntKind::Note, u(late), &field0, json!("C")),
            ],
            vec![crate::gen4::op::Body4::salts([U3]).unwrap()],
        ];
        let mut seq = 1;
        for (i, bodies) in steps.iter().enumerate() {
            write(t, col, 0xd1, seq, 1000 + 10 * i as i64, bodies);
            seq += bodies.len() as u64;
            let live = snapshot_of(&mut b, t, col, &types, &deck);
            let fresh = snapshot_of(&mut Browse::new(), t, col, &types, &deck);
            assert_eq!(live, fresh, "step {i}");
            assert_eq!(stats(&mut b, t, col)["sessions"], json!(1), "step {i}");
            let text = json!(live).to_string();
            let has = |r: &Id| text.contains(&r.text());
            match i {
                5 => {
                    // 缓存层里真有这张隐藏卡的行，会话不显示它。
                    let hidden: i64 = t
                        .conn()
                        .query_row(
                            "SELECT hidden FROM cards WHERE col = ?1 AND id = ?2",
                            rusqlite::params![col, blank_card.0.to_vec()],
                            |r| r.get(0),
                        )
                        .unwrap();
                    assert_eq!(hidden, 1);
                    assert!(!has(&blank_card), "a blank note's card is hidden");
                }
                6 => assert!(has(&blank_card), "the card shows once the field is filled"),
                7 => assert!(has(&late), "the late-salted note is its own row first"),
                8 => assert!(
                    !has(&late) && has(&w.c_note),
                    "then it joins c_note's class"
                ),
                _ => {}
            }
        }
        // 缓存层整层重建（配置变了之类）：下限抬过会话的代号，整份重建一次，结果照旧。
        t.tx(|t| Index::new(t, col).rebuild_caches().map(|_| ()))
            .unwrap();
        let live = snapshot_of(&mut b, t, col, &types, &deck);
        assert_eq!(stats(&mut b, t, col)["sessions"], json!(2));
        assert_eq!(live, snapshot_of(&mut Browse::new(), t, col, &types, &deck));
    });
}

/// 落下多少由会话自己算：一直跟着的会话经过累计远超 [REFRESH_CAP] 条笔记的几批写入也从不整份重建；一次落下超过
/// 上限的会话整份重建一次；两者结果都与新建的相同。
#[test]
fn only_a_session_that_falls_behind_rebuilds() {
    with(|t, col| {
        let w = land(t, col);
        let deck = id(DECK).text();
        let types = twin_types(&w, None);
        let cmd = |b: &mut Browse| -> Value {
            run(
                b,
                t,
                col,
                "browse_query",
                ctx(
                    types.clone(),
                    &deck,
                    json!({"node": {"t": "text", "v": "w"}}),
                ),
            )
            .0
        };
        let (mut keep, mut lag) = (Browse::new(), Browse::new());
        cmd(&mut keep);
        cmd(&mut lag);
        let batch = REFRESH_CAP as u64 / 2 + 1;
        for i in 0..3u64 {
            let seq = 1 + 2 * batch * i;
            write(
                t,
                col,
                0xd1,
                seq,
                1000 + seq as i64,
                &many_notes(batch, 1 + batch * i),
            );
            cmd(&mut keep);
        }
        let fresh = cmd(&mut Browse::new());
        assert_eq!(cmd(&mut keep), fresh);
        assert_eq!(stats(&mut keep, t, col)["sessions"], json!(1), "kept up");
        assert_eq!(cmd(&mut lag), fresh);
        assert_eq!(stats(&mut lag, t, col)["sessions"], json!(2), "fell behind");
    });
}

/// 变更记录攒过 [LOG_KEEP] 行：从代号旧的一头删到剩一半、下限抬到删掉的最大代号。对上的代号在被删的那段里的会话
/// 整份重建（否则会漏掉被删记录里的改动），代号比它新的会话照常增量；记录行数与 `logged` 一致。
#[test]
fn a_truncated_change_log_rebuilds_only_the_sessions_it_left_behind() {
    use crate::store::gen4::cache::LOG_KEEP;
    with(|t, col| {
        let w = land(t, col);
        let deck = id(DECK).text();
        let types = twin_types(&w, None);
        let mut old = Browse::new();
        snapshot_of(&mut old, t, col, &types, &deck);
        // 老会话之后的一条真改动，记录会被截掉。
        let field = format!("f/{}", w.c_field.text());
        write(
            t,
            col,
            0xd1,
            1,
            1000,
            &[set(EntKind::Note, u(w.c_note), &field, json!("early"))],
        );
        // 一大段历史（每个代号一条不存在的笔记，读者按 id 重读时自然没有行），再开一个对上最新代号的会话。
        let n = LOG_KEEP + 1;
        t.conn()
            .execute(
                "INSERT INTO cache_log (col, gen, note) \
                 WITH RECURSIVE s(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM s WHERE i < ?2) \
                 SELECT ?1, (SELECT gen FROM cache_gen WHERE col = ?1) + i, 'x' || i FROM s",
                rusqlite::params![col, n],
            )
            .unwrap();
        t.conn()
            .execute(
                "UPDATE cache_gen SET gen = gen + ?2, logged = logged + ?2 WHERE col = ?1",
                rusqlite::params![col, n],
            )
            .unwrap();
        let mut new = Browse::new();
        snapshot_of(&mut new, t, col, &types, &deck);
        write(t, col, 0xd2, 1, 2000, &many_notes(1, 90));
        let (rows, logged, floor, gen): (i64, i64, i64, i64) = t
            .conn()
            .query_row(
                "SELECT (SELECT COUNT(*) FROM cache_log WHERE col = ?1), logged, floor, gen \
                 FROM cache_gen WHERE col = ?1",
                [col],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
            )
            .unwrap();
        assert_eq!(rows, logged);
        assert!(rows <= LOG_KEEP / 2 + 1, "{rows}");
        assert!(floor > 1 && floor < gen, "floor {floor}, gen {gen}");
        let fresh = snapshot_of(&mut Browse::new(), t, col, &types, &deck);
        assert_eq!(snapshot_of(&mut new, t, col, &types, &deck), fresh);
        assert_eq!(
            stats(&mut new, t, col)["sessions"],
            json!(1),
            "newer than the cut"
        );
        assert_eq!(snapshot_of(&mut old, t, col, &types, &deck), fresh);
        assert_eq!(stats(&mut old, t, col)["sessions"], json!(2), "left behind");
    });
}

/// 在调用方的写事务里读（看得见没提交的改动），之后回滚：会话不推进代号、把读过的笔记记成可疑，下一条命令改回库里
/// 的样子；回滚之后同一个代号又被别的内容提交也不会漏。
#[test]
fn a_read_inside_a_rolled_back_write_does_not_stick() {
    with(|t, col| {
        let w = land(t, col);
        let deck = id(DECK).text();
        let types = twin_types(&w, None);
        let mut b = Browse::new();
        let before = snapshot_of(&mut b, t, col, &types, &deck);
        let field = format!("f/{}", w.c_field.text());
        let r: Result<(), String> = t.tx(|t| {
            let mut ix = Index::new(t, col);
            let e = set(EntKind::Note, u(w.c_note), &field, json!("uncommitted"));
            let base = base_ops(&twin()).len() as u64;
            native(t, &mut ix, col, &op(0xd1, 1, 2000, &[(0xa1, base)], &e));
            ix.settle()?;
            let inside = snapshot_of(&mut b, t, col, &types, &deck);
            assert_ne!(
                inside, before,
                "the write is visible inside its transaction"
            );
            Err("roll back".to_owned())
        });
        assert!(r.is_err());
        assert_eq!(snapshot_of(&mut b, t, col, &types, &deck), before);
        // 同一个代号再提交一条别的改动（另一条笔记）：会话照样看到。
        write(t, col, 0xd2, 1, 3000, &many_notes(1, 40));
        let live = snapshot_of(&mut b, t, col, &types, &deck);
        assert_eq!(live, snapshot_of(&mut Browse::new(), t, col, &types, &deck));
        assert_ne!(live, before);
        assert_eq!(stats(&mut b, t, col)["sessions"], json!(1));
    });
}

// ---------------------------------------------------------------------- 代价

/// 一条实际执行过的语句：SQL 原文、绑定参数展开后的 SQL、这一次执行的虚拟机步数与全表扫描步数
/// （`sqlite3_stmt_status` 的 `VM_STEP` / `FULLSCAN_STEP`，在语句开始与结束之间的差）。
#[derive(Debug, Clone)]
pub(super) struct Ran {
    pub(super) sql: String,
    expanded: String,
    pub(super) steps: i64,
    pub(super) fullscan: i64,
}

thread_local! {
    static RAN: RefCell<Vec<Ran>> = const { RefCell::new(Vec::new()) };
    /// 正在跑的语句（按 SQL 原文）开始时的两个计数（计数随缓存的语句累计，只看差）。
    static STARTED: RefCell<HashMap<String, (i64, i64)>> = RefCell::new(HashMap::new());
}

/// [f] 里连接上实际执行的每条语句（`SQLITE_TRACE_STMT` / `SQLITE_TRACE_PROFILE`）——测的是代码真正 prepare 的
/// SQL，不是测试里抄的一份。`dispatch_tests.rs` 也用（按卡认集合的语句数）。
pub(super) fn profile(t: &Truth<'_>, f: impl FnOnce()) -> Vec<Ran> {
    use rusqlite::StatementStatus::{FullscanStep, VmStep};
    use rusqlite::trace::{TraceEvent, TraceEventCodes};
    fn on(e: TraceEvent<'_>) {
        match e {
            // 以 `--` 开头的是触发器子程序的开始，不是语句开始。
            TraceEvent::Stmt(s, text) if !text.starts_with("--") => {
                let at = (
                    s.get_status(VmStep) as i64,
                    s.get_status(FullscanStep) as i64,
                );
                STARTED.with(|m| m.borrow_mut().insert(s.sql().into_owned(), at));
            }
            TraceEvent::Profile(s, _) => {
                let sql = s.sql().into_owned();
                let (v0, f0) = STARTED
                    .with(|m| m.borrow_mut().remove(&sql))
                    .unwrap_or((0, 0));
                let ran = Ran {
                    expanded: s.expanded_sql().unwrap_or_else(|| sql.clone()),
                    steps: s.get_status(VmStep) as i64 - v0,
                    fullscan: s.get_status(FullscanStep) as i64 - f0,
                    sql,
                };
                RAN.with(|r| r.borrow_mut().push(ran));
            }
            _ => {}
        }
    }
    RAN.with(|r| r.borrow_mut().clear());
    STARTED.with(|m| m.borrow_mut().clear());
    t.conn().trace_v2(
        TraceEventCodes::SQLITE_TRACE_STMT | TraceEventCodes::SQLITE_TRACE_PROFILE,
        Some(on),
    );
    f();
    t.conn().trace_v2(TraceEventCodes::empty(), None);
    RAN.with(|r| std::mem::take(&mut *r.borrow_mut()))
}

/// 一集合 [n] 条笔记、会话装好全部字段之后：没有写入时一条命令、改了一条笔记之后一条命令各自的 (虚拟机步数, 全表
/// 扫描步数)。
fn refresh_cost(n: u64) -> ((i64, i64), (i64, i64)) {
    with(|t, col| {
        let w = land(t, col);
        write(t, col, 0xd1, 1, 1000, &many_notes(n, 1));
        let deck = id(DECK).text();
        let types = twin_types(&w, None);
        let mut b = Browse::new();
        // 装好全部字段（全文检索要它们），之后增量重读也要重读写过的笔记的字段。归回的写入者表整条命令读一次，
        // 不是每条笔记读一次。
        let load = profile(t, || {
            run(
                &mut b,
                t,
                col,
                "browse_query",
                ctx(
                    types.clone(),
                    &deck,
                    json!({"node": {"t": "text", "v": "w1"}}),
                ),
            );
        });
        let writers = load
            .iter()
            .filter(|r| r.sql.contains("FROM alias_writer_ix"))
            .count();
        assert!(writers <= 2, "{writers} writer-table reads for {n} notes");
        let cmd = |b: &mut Browse| {
            run(
                b,
                t,
                col,
                "browse_counts",
                ctx(
                    types.clone(),
                    &deck,
                    json!({"nodes": [{"t": "tag", "v": "nope"}]}),
                ),
            );
        };
        let sum = |ran: &[Ran]| {
            (
                ran.iter().map(|r| r.steps).sum::<i64>(),
                ran.iter().map(|r| r.fullscan).sum::<i64>(),
            )
        };
        let idle = sum(&profile(t, || cmd(&mut b)));
        let field = format!("f/{}", w.c_field.text());
        write(
            t,
            col,
            0xd2,
            1,
            5000,
            &[set(EntKind::Note, u(w.c_note), &field, json!("q"))],
        );
        let ran = profile(t, || cmd(&mut b));
        let fulls: Vec<&Ran> = ran.iter().filter(|r| r.fullscan > 0).collect();
        assert!(fulls.is_empty(), "no full scans in a refresh: {fulls:#?}");
        assert_eq!(stats(&mut b, t, col)["sessions"], json!(1));
        (idle, sum(&ran))
    })
}

/// 增量重读只碰写过的那条笔记：没有写入时、写了一条之后，一条命令实际执行的步数都不随集合变大（300 条与 1200 条
/// 笔记的集合相同），也没有一步全表扫描。
#[test]
fn an_incremental_refresh_reads_only_the_touched_notes() {
    let (idle_s, touched_s) = refresh_cost(300);
    let (idle_l, touched_l) = refresh_cost(1200);
    assert_eq!(idle_s.1 + touched_s.1 + idle_l.1 + touched_l.1, 0);
    assert_eq!(idle_s.0, idle_l.0, "no write: the same work at any size");
    assert!(touched_s.0 > idle_s.0, "a touched note is re-read");
    // 别名查表（B 树深度）可能随集合多一层：给一点余量，远小于多扫 900 条笔记。
    assert!(
        touched_l.0 <= touched_s.0 + 100,
        "one touched note: {} steps at 1200 notes vs {} at 300",
        touched_l.0,
        touched_s.0
    );
}

/// 浏览命令按键读缓存层的每条语句（实际执行的那几条，按展开后的参数做 EXPLAIN）都走索引：不扫表，也不只按集合号把
/// 整个集合走一遍。整份建会话的那几条（只有集合号一个参数）除外。覆盖到按 ID 读笔记 / 卡、按笔记找卡、变更记录、
/// `rated:` 的时刻范围、查重的规范形。
#[test]
fn keyed_browse_reads_use_the_indexes() {
    with(|t, col| {
        let w = land(t, col);
        write(t, col, 0xd1, 1, 1000, &many_notes(40, 1));
        let deck = id(DECK).text();
        let types = twin_types(&w, None);
        let mut b = Browse::new();
        let q = |b: &mut Browse, node: Value| {
            run(
                b,
                t,
                col,
                "browse_query",
                ctx(types.clone(), &deck, json!({"node": node})),
            );
        };
        q(&mut b, json!({"t": "text", "v": "w1"}));
        let field = format!("f/{}", w.c_field.text());
        write(
            t,
            col,
            0xd2,
            1,
            5000,
            &[set(EntKind::Note, u(w.c_note), &field, json!("q"))],
        );
        let norm = crate::search::dupe_norm;
        let c_nt = rules::note_type(CANONICAL, ANKI_NT);
        let ran = profile(t, || {
            q(&mut b, json!({"t": "rated", "d": 3650, "e": 3}));
            run(
                &mut b,
                t,
                col,
                "anki_dupes",
                json!({"first": {c_nt.text(): w.c_field.text()}, "cands": [
                    {"norm": norm("A"), "type": c_nt.text(), "all": false, "decks": [deck.clone()]},
                ]}),
            );
        });
        let cache = ["notes", "cards", "stats", "cache_log"];
        let mut seen: HashSet<String> = HashSet::new();
        for r in &ran {
            let plan: Vec<String> = t
                .conn()
                .prepare(&format!("EXPLAIN QUERY PLAN {}", r.expanded))
                .unwrap()
                .query_map([], |x| x.get::<_, String>(3))
                .unwrap()
                .collect::<Result<_, _>>()
                .unwrap();
            for line in &plan {
                let mut words = line.split_whitespace();
                let (Some(how), Some(table)) = (words.next(), words.next()) else {
                    continue;
                };
                if !cache.contains(&table) {
                    continue;
                }
                assert_ne!(how, "SCAN", "{}: {plan:?}", r.sql);
                if how == "SEARCH" {
                    assert!(
                        !line.ends_with("(col=?)"),
                        "a whole-collection read: {}: {plan:?}",
                        r.sql
                    );
                    seen.insert(line.clone());
                }
            }
        }
        let has = |table: &str, key: &str| {
            seen.iter()
                .any(|l| l.contains(&format!("SEARCH {table} ")) && l.contains(key))
        };
        assert!(has("cache_log", "gen>?"), "{seen:#?}");
        assert!(has("notes", "id=?"), "{seen:#?}");
        assert!(has("cards", "id=?"), "{seen:#?}");
        assert!(has("cards", "cards_note"), "{seen:#?}");
        assert!(has("stats", "at>?"), "{seen:#?}");
        assert!(has("notes", "notes_dupe"), "{seen:#?}");
    });
}

/// 请求归一（[canon_req]）只动 ID 字段：笔记类型 / 字段 / 模板、牌组键、`instant` / `find` / `ids`，别的原样。
#[test]
fn canon_req_touches_only_id_fields() {
    with(|t, col| {
        let w = land(t, col);
        let src = G4::new(t, col);
        let deck = id(DECK).text();
        let req = ctx(
            twin_types(&w, Some(1)),
            &deck,
            json!({"instant": [w.card[0].text()], "find": [w.note[1].text()], "ids": [w.card[1].text()],
                   "node": {"t": "text", "v": w.note[0].text()}}),
        );
        let v = canon_req(&src, "browse_query", &req).unwrap();
        assert_eq!(v["types"], twin_types(&w, None));
        assert_eq!(v["instant"], json!([w.c_card.text()]));
        assert_eq!(v["find"], json!([w.c_note.text()]));
        assert_eq!(v["ids"], json!([w.c_card.text()]));
        assert_eq!(v["node"], req["node"], "free text is not an ID");
        let seen: HashSet<&str> = [
            "now",
            "utcOff",
            "rollover",
            "fallback",
            "models",
            "fallbackModel",
            "owner",
        ]
        .into_iter()
        .collect();
        for k in seen {
            assert_eq!(v[k], req[k], "{k}");
        }
        let _ = (N2, N3);
    });
}
