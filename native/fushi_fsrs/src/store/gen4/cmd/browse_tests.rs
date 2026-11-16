//! 浏览读命令（`browse.rs`）的测试。
//!
//! - **对拍**：同一个协议 3 的库（`tests.rs` 的 `library`）一侧在协议 3 的缓存表上跑同一份会话实现（`store::browse`
//!   的 [P3] 读法，缓存按新代同一份配置在 SAVEPOINT 里重建），另一侧灌进新代跑 [Browse]；同一串命令（全部排序列 ×
//!   卡片 / 笔记模式 × 一组查询、取行、行 id、批量目标、计数、出处分组、AnkiConnect 查找 / 标签 / 查重）逐条比回包
//!   （ID 归一成规范 ID、去掉进程内的结果代号）与列式文件的字节。
//! - **别名类**（只有新代有）：`tests_class.rs` 的两份带盐笔记场景，请求里给成员 ID / 成员号与给规范 ID 结果相同。
//! - **失效**：写入（逐条维护的收尾）之后同一个会话按代号增量重读，结果与新建的会话相同、不整份重建；整层重建、写事务里
//!   读过又回滚都对。
//! - **代价**：EXPLAIN 与一次增量重读交出的行数。

use std::cell::Cell;
use std::collections::HashSet;

use rusqlite::Connection;
use serde_json::{Value, json};

use super::Files;
use super::browse::{Browse, G4, canon_req};
use super::tests::{N1, N2, N3, Pair, T0, library, on_p3};
use super::tests_class::{ANKI_NT, DECK, Twin, base_ops, land, set, twin, u};
use crate::gen4::op::tests::id;
use crate::gen4_ids::rules::{self, CANONICAL};
use crate::store::browse::{P3, Sessions};
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
            "tpls": [["t1", "A", 0], ["t2", "B", 1]]}])
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
        json!({"first": {"NT": "fa"}, "cands": [
            {"norm": norm("猫"), "type": "NT", "all": false, "decks": null},
            {"norm": norm("猫"), "type": "X", "all": false, "decks": null},
            {"norm": norm("猫"), "type": "X", "all": true, "decks": [deck]},
            {"norm": norm("犬"), "type": "NT", "all": false, "decks": ["elsewhere"]},
            {"norm": norm("鳥"), "type": "NT", "all": false, "decks": null},
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
    let d = library();
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
    assert_eq!(dupes["dup"], json!([true, false, true, false, false]));
    let tags = &g4.iter().find(|(op, ..)| op == "anki_tags").unwrap().1;
    assert_eq!(tags["tags"], json!(["a", "b"]));
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
        ];
        let mut seq = 1;
        for (i, bodies) in steps.iter().enumerate() {
            write(t, col, 0xd1, seq, 1000 + 10 * i as i64, bodies);
            seq += bodies.len() as u64;
            let live = snapshot_of(&mut b, t, col, &types, &deck);
            let fresh = snapshot_of(&mut Browse::new(), t, col, &types, &deck);
            assert_eq!(live, fresh, "step {i}");
            assert_eq!(stats(&mut b, t, col)["sessions"], json!(1), "step {i}");
        }
        // 缓存层整层重建（配置变了之类）：下限抬过会话的代号，整份重建一次，结果照旧。
        t.tx(|t| Index::new(t, col).rebuild_caches().map(|_| ()))
            .unwrap();
        let live = snapshot_of(&mut b, t, col, &types, &deck);
        assert_eq!(stats(&mut b, t, col)["sessions"], json!(2));
        assert_eq!(live, snapshot_of(&mut Browse::new(), t, col, &types, &deck));
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

thread_local! {
    static ROWS: Cell<u64> = const { Cell::new(0) };
}

/// [f] 里各条语句一共交出多少行（`SQLITE_TRACE_ROW`）。
fn rows_stepped(t: &Truth<'_>, f: impl FnOnce()) -> u64 {
    use rusqlite::trace::{TraceEvent, TraceEventCodes};
    fn count(e: TraceEvent<'_>) {
        if let TraceEvent::Row(_) = e {
            ROWS.with(|r| r.set(r.get() + 1));
        }
    }
    ROWS.with(|r| r.set(0));
    t.conn()
        .trace_v2(TraceEventCodes::SQLITE_TRACE_ROW, Some(count));
    f();
    t.conn().trace_v2(TraceEventCodes::empty(), None);
    ROWS.with(|r| r.get())
}

/// 增量重读只碰写过的那条笔记：集合里 300 条笔记，写一条之后下一条命令交出的行数是常数级（代号、变更记录、那条笔记的
/// 行与卡、它的修改行），不随集合变大；没有写入时只读代号一行。
#[test]
fn an_incremental_refresh_reads_only_the_touched_notes() {
    with(|t, col| {
        let w = land(t, col);
        write(t, col, 0xd1, 1, 1000, &many_notes(300, 1));
        let deck = id(DECK).text();
        let types = twin_types(&w, None);
        let mut b = Browse::new();
        // 装好全部字段（全文检索要它们），之后增量重读也要重读写过的笔记的字段。
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
        let ids = |b: &mut Browse| {
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
        // 没有写入：代号一行，加请求归一（笔记类型 / 字段 / 模板 / 牌组各查一次别名表）的常数行。
        let idle = rows_stepped(t, || ids(&mut b));
        assert!(idle <= 8, "no write: {idle} rows");
        let field = format!("f/{}", w.c_field.text());
        write(
            t,
            col,
            0xd2,
            1,
            5000,
            &[set(EntKind::Note, u(w.c_note), &field, json!("q"))],
        );
        let after = rows_stepped(t, || ids(&mut b));
        assert!(
            after <= idle + 30,
            "one touched note: {after} rows (idle {idle})"
        );
        assert_eq!(stats(&mut b, t, col)["sessions"], json!(1));
    });
}

/// 新代读法的每条按键读的语句都走索引（不扫整个集合）；整份建会话的两条是一次顺序扫。
#[test]
fn keyed_browse_reads_use_the_indexes() {
    with(|t, col| {
        land(t, col);
        let src = G4::new(t, col);
        let plan = |q: &str, args: &[&dyn rusqlite::ToSql]| -> Vec<String> {
            t.conn()
                .prepare(&format!("EXPLAIN QUERY PLAN {q}"))
                .unwrap()
                .query_map(args, |r| r.get::<_, String>(3))
                .unwrap()
                .collect::<Result<_, _>>()
                .unwrap()
        };
        let ids = "(SELECT CASE value ->> 0 WHEN 1 THEN unhex(value ->> 1) ELSE value ->> 1 END AS v FROM json_each(?2))";
        let list = r#"[[0, "x"]]"#;
        for (q, want) in [
            (
                format!(
                    "SELECT id FROM notes WHERE col = ?1 AND id IN {ids} AND deleted_at IS NULL"
                ),
                "PRIMARY KEY",
            ),
            (
                format!("SELECT id FROM cards WHERE col = ?1 AND id IN {ids} AND hidden = 0"),
                "PRIMARY KEY",
            ),
            (
                format!("SELECT id FROM cards WHERE col = ?1 AND note_id IN {ids}"),
                "cards_note",
            ),
            (
                format!(
                    "SELECT note_id, deck_id FROM cards WHERE col = ?1 AND note_id IN {ids} AND hidden = 0"
                ),
                "cards_note",
            ),
            (
                "SELECT id, note_type_id, dupe_norm FROM notes WHERE col = ?1 \
                 AND dupe_norm IN (SELECT value FROM json_each(?2)) AND deleted_at IS NULL"
                    .to_owned(),
                "notes_dupe",
            ),
            (
                "SELECT DISTINCT note FROM cache_log WHERE col = ?1 AND gen > ?2".to_owned(),
                "PRIMARY KEY",
            ),
        ] {
            let p = plan(&q, &[&col, &list]);
            assert!(
                p.iter().any(|s| s.contains(want))
                    && !p.iter().any(|s| s.starts_with("SCAN notes")
                        || s.starts_with("SCAN cards")
                        || s.starts_with("SCAN cache_log")),
                "{q}: {p:?}"
            );
        }
        let p = plan(
            "SELECT card FROM stats WHERE col = ?1 AND at >= ?2 AND rating IS NOT NULL",
            &[&col, &0i64],
        );
        assert!(
            p.iter()
                .any(|s| s.contains("SEARCH stats") && s.contains("at>?")),
            "{p:?}"
        );
        drop(src);
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
