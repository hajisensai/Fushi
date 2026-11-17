//! G7-4e 小命令（`center.rs`、`profile.rs`、`writes_local.rs` 的 `status` 设备行状态）的测试。
//!
//! **对拍**：同一个协议 3 的库（`tests.rs` 的 `library` / `library_pair`）灌进新代（`Pair::new`），同一个请求分别问协议 3
//! 的原命令（`SrsCore::sync2_conflicts` / `sync2_checkpoints` / `sync2_undo_check` / `binding_get` /
//! `profile_footprint`）与新代实现，结果逐键比。**别名类**：`tests_class.rs` 的双盐场景（同一条笔记两份带盐 ID），只有
//! 新代才有。**代价**：集合大 40 倍，各条语句交出的行数不变。

use std::cell::Cell;

use serde_json::{Value, json};

use super::center::{checkpoints, conflicts, undo_check};
use super::profile::{binding_get, profile_footprint};
use super::tests::{N1, N2, Pair, T0, library, library_pair};
use super::writes_local::status;
use super::{tests_class, writes};
use crate::gen4::op::tests::id;
use crate::gen4::op::{Body4, Edit4};
use crate::store::gen4::derive::Index;
use crate::store::gen4::derive::tests::{assert_rebuild_is_identity, native, op, with};
use crate::store::gen4::schema::{opk, sql};
use crate::store::gen4::truth::{BindStage, Peer, Truth};
use crate::store::sync2::tests::{DAY, P, edit};
use crate::sync2::codec::Writer;
use crate::sync2::id::{Id, Key};
use crate::sync2::op::EntKind;
use crate::sync2::vv::OpId;

const T1: i64 = T0 + 3 * DAY;
const ME: [u8; 16] = [0xe4; 16];

// ---------------------------------------------------------------------- 对拍

/// `conflicts`：`library_pair` 的两台设备，一台删 N1、另一台并发改它（删除被扣住）。两侧逐键相同；列出的 ID 交给新代的
/// `resolve` 找得到（同一个公式）。
#[test]
fn conflicts_match_protocol_3() {
    let (a, b, mut bucket) = library_pair();
    assert_eq!(a.core.sync2_conflicts(P).unwrap(), json!([]));
    a.apply(T1 + 1, vec![edit("note", N1, "deleted", json!(T1 + 1))]);
    b.apply(T1 + 2, vec![edit("note", N1, "f/fa", json!("並行"))]);
    for _ in 0..2 {
        a.sync(&mut bucket, "loc", T1 + 3);
        b.sync(&mut bucket, "loc", T1 + 3);
    }
    let p3 = a.core.sync2_conflicts(P).unwrap();
    assert!(!p3.as_array().unwrap().is_empty(), "{p3}");
    let p = Pair::new(&a);
    let t = Truth::new(&p.g4);
    let g4 = conflicts(&t, p.col).unwrap();
    assert_eq!(g4, p3);
    assert!(t.conn().is_autocommit());
    // 新代的 `resolve` 认这个 ID。
    t.tx(|t| t.create_self(p.col, &Id(ME), &[9; 32], None, T0))
        .unwrap();
    let cid = g4[0]["id"].as_str().unwrap();
    writes::resolve(
        &t,
        p.col,
        &json!({"now": T1 + 4, "conflict": cid, "delete": false}),
    )
    .unwrap();
    assert_eq!(conflicts(&t, p.col).unwrap(), json!([]));
}

/// `checkpoints`：协议 3 写的两个还原点（灌进新代成了承袭日志里的操作）两侧逐键相同；没有还原点时都是空表。
#[test]
fn checkpoints_match_protocol_3() {
    let a = library();
    {
        let p = Pair::new(&a);
        assert_eq!(a.core.sync2_checkpoints(P).unwrap(), json!([]));
        assert_eq!(checkpoints(&Truth::new(&p.g4), p.col).unwrap(), json!([]));
    }
    for (i, name) in ["before import", "manual"].into_iter().enumerate() {
        a.core
            .sync2_append(
                P,
                T1 + i as i64,
                crate::store::sync2::checkpoint_bodies(name, "manual"),
            )
            .unwrap();
    }
    let p3 = a.core.sync2_checkpoints(P).unwrap();
    assert_eq!(p3.as_array().unwrap().len(), 2, "{p3}");
    let p = Pair::new(&a);
    assert_eq!(checkpoints(&Truth::new(&p.g4), p.col).unwrap(), p3);
}

/// 新代单侧：换代之后新写的还原点（原生日志）出现在列表里、排最前；迁移照搬的本机表 `checkpoints` 里的行并进来，同一个
/// (设备, seq) 只出一次、以真相层为准。
#[test]
fn checkpoints_take_new_ones_and_the_carried_table() {
    let a = library();
    a.core
        .sync2_append(P, T1, crate::store::sync2::checkpoint_bodies("old", "r"))
        .unwrap();
    let p = Pair::new(&a);
    let t = Truth::new(&p.g4);
    let col = p.col;
    let before = checkpoints(&t, col).unwrap();
    let old = before[0].clone();
    t.tx(|t| t.create_self(col, &Id(ME), &[9; 32], None, T0))
        .unwrap();
    writes::checkpoint(
        &t,
        col,
        &json!({"now": T1 + DAY, "name": "new", "reason": "manual"}),
    )
    .unwrap();
    // 迁移照搬的行：一条只在表里的（设备 0x77），一条与真相层同号、内容不同（真相层为准）。
    let carried = |device: &[u8], seq: i64, wall: i64, name: &str| {
        t.conn()
            .execute(
                "INSERT INTO checkpoints (col, device, seq, wall, name, reason) VALUES (?1, ?2, ?3, ?4, ?5, 'carried')",
                rusqlite::params![col, device, seq, wall, name],
            )
            .unwrap();
    };
    carried(&[0x77; 16], 3, T0, "carried");
    let old_dev = Id::parse(old["device"].as_str().unwrap()).unwrap();
    carried(&old_dev.0, old["seq"].as_i64().unwrap(), 1, "stale copy");
    let v = checkpoints(&t, col).unwrap();
    let names: Vec<&str> = v
        .as_array()
        .unwrap()
        .iter()
        .map(|x| x["name"].as_str().unwrap())
        .collect();
    assert_eq!(names, ["new", "old", "carried"], "{v}");
    assert_eq!(v[0]["device"], json!(Id(ME).text()));
    assert_eq!(v[0]["at"].as_i64().unwrap() >= T1 + DAY, true, "{v}");
    assert_eq!(v[1], old);
    assert_eq!(v[2]["device"], json!(Id([0x77; 16]).text()));
}

/// `undo_check`：拿协议 3 修改历史里每条 dot（含被覆盖的旧写入）各问一次，再加只按值的、dot 不存在的、dot 指向别的
/// 实体的、旧载荷没有 dot 也没有值的，两侧逐项相同，且「能撤」「不能撤」都出现过。
#[test]
fn undo_check_matches_protocol_3() {
    let a = library();
    // N1 的字段先改再改：第一次写入已被覆盖（不能撤），第二次能撤；再一次改回第一次的值（按值能撤）。
    a.apply(T1, vec![edit("note", N1, "f/fa", json!("x1"))]);
    a.apply(T1 + 1, vec![edit("note", N1, "f/fa", json!("x2"))]);
    // N2 倒序撤两步：y1、y2，再写回 y1（撤 y2）——问 y1 那次写入的 dot（已被支配、值又回来了）。
    a.apply(T1 + 2, vec![edit("note", N2, "f/fa", json!("y1"))]);
    a.apply(T1 + 3, vec![edit("note", N2, "f/fa", json!("y2"))]);
    a.apply(T1 + 4, vec![edit("note", N2, "f/fa", json!("y1"))]);
    let mut items: Vec<Value> = Vec::new();
    for (kind, entity) in [("note", N1), ("note", N2)] {
        let h = a.core.sync2_history(P, kind, entity).unwrap();
        for e in h.as_array().unwrap() {
            let Some(key) = e["key"].as_str().filter(|k| *k != "tags") else {
                continue;
            };
            items.push(json!({"k": kind, "e": entity, "f": key, "w": e["device"], "s": e["seq"]}));
            items.push(json!({"k": kind, "e": entity, "f": key, "v": e["value"]}));
        }
    }
    let some = items[0].clone();
    items.push(json!({"k": "note", "e": N1, "f": "f/fa", "w": some["w"], "s": 99_999}));
    items.push(json!({"k": "note", "e": N2, "f": "f/fa", "w": some["w"], "s": some["s"]}));
    items.push(json!({"k": "note", "e": N1, "f": "f/fa"}));
    items.push(json!({"k": "note", "e": N1, "f": "f/nothing", "v": "x"}));
    let req = json!({ "items": items });
    let p3 = a.core.sync2_undo_check(P, &req).unwrap();
    let p = Pair::new(&a);
    let t = Truth::new(&p.g4);
    let g4 = undo_check(&t, p.col, &req).unwrap();
    assert_eq!(g4, p3);
    let oks: Vec<bool> = g4["r"]
        .as_array()
        .unwrap()
        .iter()
        .map(|r| r["ok"].as_bool().unwrap())
        .collect();
    assert!(oks.contains(&true) && oks.contains(&false), "{g4}");
    assert!(t.conn().is_autocommit());
    // 坏请求照协议 3 报错。
    assert!(undo_check(&t, p.col, &json!({})).is_err());
    assert!(
        undo_check(
            &t,
            p.col,
            &json!({"items": [{"k": "bad", "e": N1, "f": "x"}]})
        )
        .is_err()
    );
}

/// `binding_get`：没有记录时两侧都是 null；同样写成 settled 之后两侧逐键相同。
#[test]
fn binding_get_matches_protocol_3() {
    let a = library();
    let p = Pair::new(&a);
    let t = Truth::new(&p.g4);
    assert_eq!(
        binding_get(&t, p.col).unwrap(),
        a.core.binding_get(P).unwrap()
    );
    a.core.binding_set(P, "provisional", "join", 7).unwrap();
    t.tx(|t| t.settle_binding(p.col, BindStage::Provisional, "join", 7))
        .unwrap();
    assert_eq!(
        binding_get(&t, p.col).unwrap(),
        a.core.binding_get(P).unwrap()
    );
    a.core.binding_set(P, "settled", "pick", 9).unwrap();
    t.tx(|t| t.settle_binding(p.col, BindStage::Settled, "pick", 9))
        .unwrap();
    let g = binding_get(&t, p.col).unwrap();
    assert_eq!(g, a.core.binding_get(P).unwrap());
    assert_eq!(
        g,
        json!({"binding": {"state": "settled", "via": "pick", "at": 9}})
    );
}

/// `profile_footprint`：笔记、卡、复习条数两侧相同（含删过的笔记），`rows` 都不是 0；一个绑了却没写过东西的集合与
/// 协议 3 一个没有数据的 profile 一样全 0。
#[test]
fn profile_footprint_matches_protocol_3() {
    let a = library();
    a.apply(T1, vec![edit("note", N2, "deleted", json!(T1))]);
    let p = Pair::new(&a);
    // 协议 3 的规模数它自己的缓存表：按新代同一份配置先把缓存整份建好（提交；`writes_tests.rs` 的 `W::new` 同一步）。
    {
        let w = a.core.writer().unwrap();
        crate::store::sync2::transport::replay_pending(
            &w,
            P,
            &mut crate::store::sync2::transport::CommitBudget::unlimited(),
        )
        .unwrap();
        let cfg = crate::store::caches::CacheConfig::parse(&serde_json::from_str(&p.cfg).unwrap())
            .unwrap();
        crate::store::caches::rebuild(&w, P, &cfg).unwrap();
    }
    let p3 = a.core.profile_footprint(P).unwrap();
    let t = Truth::new(&p.g4);
    let g4 = profile_footprint(&t, p.col).unwrap();
    for k in ["notes", "cards", "reviews"] {
        assert_eq!(g4[k], p3[k], "{k}: {g4} vs {p3}");
    }
    assert!(p3["notes"].as_i64().unwrap() > 0, "{p3}");
    assert!(g4["rows"].as_i64().unwrap() > 0, "{g4}");
    let empty = t
        .tx(|t| t.bind("other-profile", &Id([0x31; 16]), "dir-x"))
        .unwrap();
    assert_eq!(
        profile_footprint(&t, empty).unwrap(),
        a.core.profile_footprint("other-profile").unwrap()
    );
    assert_eq!(
        profile_footprint(&t, empty).unwrap(),
        json!({"notes": 0, "cards": 0, "reviews": 0, "rows": 0})
    );
}

// ---------------------------------------------------------------------- 别名类（只有新代）

/// 双盐场景：两份带盐的同一条笔记被两台设备互不相见地各改一次——按类是冲突。撤销校验点名任何一份成员、用带盐的键都
/// 先归一，按类判：有并发候选，不能撤；现值是类的胜者。
#[test]
fn undo_check_judges_the_whole_alias_class() {
    with(|t, col| {
        let w = tests_class::land(t, col);
        let ask = |e: &Id, f: &Id, dev: u8| -> Value {
            undo_check(
                t,
                col,
                &json!({"items": [{"k": "note", "e": e.text(), "f": format!("f/{}", f.text()),
                    "w": id(dev).text(), "s": 1}]}),
            )
            .unwrap()["r"][0]
                .clone()
        };
        let by_member = ask(&w.note[1], &w.field[1], 0xb2);
        let by_canon = ask(&w.c_note, &w.c_field, 0xb2);
        assert_eq!(by_member, by_canon);
        assert_eq!(by_member["ok"], json!(false), "{by_member}");
        assert!(["A", "B"].contains(&by_member["cur"].as_str().unwrap()));
        // 写入的另一份（0xb1 写在第一份成员上）也一样：类里两条都活着。
        assert_eq!(ask(&w.note[0], &w.field[0], 0xb1)["ok"], json!(false));
    });
}

/// 类里只剩一条活着的修改（0xb3 见过 0xb1 / 0xb2 两份之后写在第二份成员上）：用写入那份成员的号、另一份成员的号、
/// 规范号点名同一个 dot，都能撤、现值相同。请求里的实体不先归一时，dot 那次写入（归一后是规范号）与请求对不上，会被
/// 误判成「不能撤」——上面的双盐并发场景期望的本来就是不能撤，钉不住这一步。
#[test]
fn undo_check_by_any_member_finds_a_lone_write() {
    with(|t, col| {
        let w = tests_class::land(t, col);
        let seen = [tests_class::base_seen(&w), (0xb1, 1), (0xb2, 1)];
        let body = Body4::Edit(Edit4 {
            kind: EntKind::Note,
            entity: Key::Uuid(w.note[1]),
            key: format!("f/{}", w.field[1].text()),
            value: "\"C\"".into(),
            ..crate::gen4::op::tests::native_edit()
        });
        t.tx(|t| {
            let mut ix = Index::new(t, col);
            native(t, &mut ix, col, &op(0xb3, 1, 500, &seen, &body));
            ix.settle().map(|_| ())
        })
        .unwrap();
        for (e, f) in [
            (w.note[1], w.field[1]),
            (w.note[0], w.field[0]),
            (w.c_note, w.c_field),
            (w.note[0], w.c_field),
        ] {
            let r = undo_check(
                t,
                col,
                &json!({"items": [{"k": "note", "e": e.text(), "f": format!("f/{}", f.text()),
                    "w": id(0xb3).text(), "s": 1}]}),
            )
            .unwrap();
            assert_eq!(
                r,
                json!({"r": [{"ok": true, "cur": "C"}]}),
                "{} / {}",
                e.text(),
                f.text()
            );
        }
    });
}

// ---------------------------------------------------------------------- 倒序撤销（C6）

/// 新代本机写入（`writes::apply`）的一条修改：(设备, seq)。
fn wrote(t: &Truth<'_>, col: i64, now: i64, key: &str, v: Value) -> (String, i64) {
    let it = json!({
        "e": {"t": "edit", "x": {"p": P, "k": "note", "e": N1, "f": key, "v": v, "ts": "anchored"}},
        "note": null, "clk": "t",
    });
    let gv = writes::apply(t, col, &json!({ "now": now }), &[it]).unwrap();
    let e = &gv["edits"][0];
    (e[3].as_str().unwrap().to_owned(), e[4].as_i64().unwrap())
}

fn ask_n1(t: &Truth<'_>, col: i64, key: &str, dot: &(String, i64)) -> Value {
    undo_check(
        t,
        col,
        &json!({"items": [{"k": "note", "e": N1, "f": key, "w": dot.0, "s": dot.1}]}),
    )
    .unwrap()["r"][0]
        .clone()
}

/// 新代原生写入上倒序撤销：两步（one → two → 撤 two 写回 one，再问 one 那次写入）与三步（a → b → c，撤 c 写回 b、
/// 问 b；撤 b 写回 a、问 a）都能撤。中间穿插别的键上的修改（跨键）不影响。撤完之后又被改成别的值：不能撤（只放宽到
/// 「唯一活着、值相同、因果见过」，不按值放行）。
///
/// 被问的那次写入早已被支配，不在投影行里：投影行的 `ctx` 只覆盖别的要输出的行，拿它判「见没见过」会把第二步判成
/// 不能撤（C6）。
#[test]
fn undo_check_reverse_steps_on_native_writes() {
    let a = library();
    let p = Pair::new(&a);
    let t = Truth::new(&p.g4);
    let col = p.col;
    t.tx(|t| t.create_self(col, &Id(ME), &[9; 32], None, T0))
        .unwrap();
    // 两步。
    let one = wrote(&t, col, T1, "f/fa", json!("one"));
    let two = wrote(&t, col, T1 + 1, "f/fa", json!("two"));
    assert_eq!(ask_n1(&t, col, "f/fa", &one)["ok"], json!(false));
    assert_eq!(
        ask_n1(&t, col, "f/fa", &two),
        json!({"ok": true, "cur": "two"})
    );
    wrote(&t, col, T1 + 2, "f/fb", json!("other key"));
    wrote(&t, col, T1 + 3, "f/fa", json!("one"));
    assert_eq!(
        ask_n1(&t, col, "f/fa", &one),
        json!({"ok": true, "cur": "one"})
    );
    // 撤完又被改成别的值：不能撤。
    wrote(&t, col, T1 + 4, "f/fa", json!("three"));
    assert_eq!(
        ask_n1(&t, col, "f/fa", &one),
        json!({"ok": false, "cur": "three"})
    );
    // 三步（另一个键）。
    let a1 = wrote(&t, col, T1 + 5, "f/fb", json!("a"));
    let b1 = wrote(&t, col, T1 + 6, "f/fb", json!("b"));
    wrote(&t, col, T1 + 7, "f/fb", json!("c"));
    wrote(&t, col, T1 + 8, "f/fa", json!("cross"));
    wrote(&t, col, T1 + 9, "f/fb", json!("b"));
    assert_eq!(
        ask_n1(&t, col, "f/fb", &b1),
        json!({"ok": true, "cur": "b"})
    );
    assert_eq!(ask_n1(&t, col, "f/fb", &a1)["ok"], json!(false));
    wrote(&t, col, T1 + 10, "f/fb", json!("a"));
    assert_eq!(
        ask_n1(&t, col, "f/fb", &a1),
        json!({"ok": true, "cur": "a"})
    );
    assert!(t.conn().is_autocommit());
}

/// 别名类上倒序撤销，且跨设备：0xb3 在第二份成员上写 C、在第一份成员上写 D、再按规范号写回 C——用任何成员的号、规范号
/// 点名 0xb3:1 都能撤。0xb4 没见过 0xb3:3 就也写了 C（并发，两条活着）：不能撤。0xb5 见过两者再写 C（唯一活着、经 0xb3:3
/// 传递见过 0xb3:1）：能撤；再被 0xb5 改成 E：不能撤。
///
/// 「见没见过」从真相层答（`Index::write_sees`）：0xb4:1 见过 0xb3:1、0xb3:2，没见过 0xb3:3。
#[test]
fn undo_check_reverse_steps_across_an_alias_class() {
    with(|t, col| {
        let w = tests_class::land(t, col);
        let base = tests_class::base_seen(&w);
        let put = |dev: u8, seq: u64, seen: &[(u8, u64)], e: Id, f: Id, v: &str| {
            let body = Body4::Edit(Edit4 {
                kind: EntKind::Note,
                entity: Key::Uuid(e),
                key: format!("f/{}", f.text()),
                value: json!(v).to_string(),
                ..crate::gen4::op::tests::native_edit()
            });
            t.tx(|t| {
                let mut ix = Index::new(t, col);
                native(
                    t,
                    &mut ix,
                    col,
                    &op(dev, seq, 500 + seq as i64, seen, &body),
                );
                ix.settle().map(|_| ())
            })
            .unwrap();
        };
        let ask = |e: &Id, f: &Id, dev: u8, s: i64| -> Value {
            undo_check(
                t,
                col,
                &json!({"items": [{"k": "note", "e": e.text(), "f": format!("f/{}", f.text()),
                    "w": id(dev).text(), "s": s}]}),
            )
            .unwrap()["r"][0]
                .clone()
        };
        let all = [
            (w.note[1], w.field[1]),
            (w.note[0], w.field[0]),
            (w.c_note, w.c_field),
            (w.note[0], w.c_field),
        ];
        let seen = [base, (0xb1, 1), (0xb2, 1)];
        put(0xb3, 1, &seen, w.note[1], w.field[1], "C");
        put(0xb3, 2, &seen, w.note[0], w.field[0], "D");
        for (e, f) in all {
            assert_eq!(ask(&e, &f, 0xb3, 1)["ok"], json!(false));
        }
        put(0xb3, 3, &seen, w.c_note, w.c_field, "C");
        for (e, f) in all {
            assert_eq!(
                ask(&e, &f, 0xb3, 1),
                json!({"ok": true, "cur": "C"}),
                "{} / {}",
                e.text(),
                f.text()
            );
        }
        // 并发的同值写入：两条活着，不能撤。
        put(
            0xb4,
            1,
            &[base, (0xb1, 1), (0xb2, 1), (0xb3, 2)],
            w.note[0],
            w.field[0],
            "C",
        );
        for (e, f) in all {
            assert_eq!(ask(&e, &f, 0xb3, 1)["ok"], json!(false));
            assert_eq!(ask(&e, &f, 0xb3, 3)["ok"], json!(false));
        }
        // 真相层的判据本身：0xb4:1 见过 0xb3:1 / 0xb3:2，没见过 0xb3:3；见过它自己之前的全部（这里没有）。
        let k = t
            .key_of(
                col,
                &OpId {
                    device: id(0xb4),
                    seq: 1,
                },
            )
            .unwrap()
            .unwrap();
        let mut ix = Index::new(t, col);
        let b3 = id(0xb3).text();
        assert!(ix.write_sees(k, &b3, 1, None).unwrap());
        assert!(ix.write_sees(k, &b3, 2, None).unwrap());
        assert!(!ix.write_sees(k, &b3, 3, None).unwrap());
        // 见过两者之后写 C：唯一活着、传递见过 0xb3:1。
        let after = [base, (0xb1, 1), (0xb2, 1), (0xb3, 3), (0xb4, 1)];
        put(0xb5, 1, &after, w.note[1], w.field[1], "C");
        for (e, f) in all {
            assert_eq!(ask(&e, &f, 0xb3, 1), json!({"ok": true, "cur": "C"}));
        }
        put(0xb5, 2, &after, w.c_note, w.c_field, "E");
        for (e, f) in all {
            assert_eq!(ask(&e, &f, 0xb3, 1), json!({"ok": false, "cur": "E"}));
        }
        assert_rebuild_is_identity(t, col);
    });
}

/// 「见没见过」这道判据接进裁决之后真的起作用：唯一活着、值与那次写入相同，但它的作者没见过那次写入——不能撤（协议 3
/// 同一情形按行上下文也判不能撤），不只按值放行。0xf1:1 写 V；0xf2:1 见过它、写 W；0xf3:1 只见过 0xf2:1（依赖里没有
/// 0xf1）、写回 V：0xf1:1 被 0xf2:1 盖掉、0xf2:1 被 0xf3:1 盖掉，活着的只有 0xf3:1。问 0xf1:1 不能撤、问 0xf3:1 能撤；
/// 0xf4:1 见过 0xf1:1 与 0xf3:1 再写 V：唯一活着、见过 0xf1:1，能撤。
///
/// 原生写入按因果顺序投递时这种依赖（见过 0xf2:1 却没见过它见过的 0xf1:1）造不出来，判据在新代是保险；这里直接喂操作
/// （同步来的对端操作不可信），钉住它没被放宽。
#[test]
fn undo_check_refuses_a_lone_same_value_write_that_never_saw_ours() {
    with(|t, col| {
        let w = tests_class::land(t, col);
        let base = tests_class::base_seen(&w);
        let put = |dev: u8, seen: &[(u8, u64)], v: &str| {
            let body = Body4::Edit(Edit4 {
                kind: EntKind::Note,
                entity: Key::Uuid(w.note[0]),
                key: format!("f/{}", w.field[0].text()),
                value: json!(v).to_string(),
                ..crate::gen4::op::tests::native_edit()
            });
            t.tx(|t| {
                let mut ix = Index::new(t, col);
                native(t, &mut ix, col, &op(dev, 1, 600 + dev as i64, seen, &body));
                ix.settle().map(|_| ())
            })
            .unwrap();
        };
        let ask = |dev: u8| -> Value {
            undo_check(
                t,
                col,
                &json!({"items": [{"k": "note", "e": w.note[0].text(),
                    "f": format!("f/{}", w.field[0].text()), "w": id(dev).text(), "s": 1}]}),
            )
            .unwrap()["r"][0]
                .clone()
        };
        let pre = [base, (0xb1, 1), (0xb2, 1)];
        put(0xf1, &pre, "V");
        put(0xf2, &[base, (0xb1, 1), (0xb2, 1), (0xf1, 1)], "W");
        put(0xf3, &[base, (0xb1, 1), (0xb2, 1), (0xf2, 1)], "V");
        assert_eq!(ask(0xf1), json!({"ok": false, "cur": "V"}));
        assert_eq!(ask(0xf3), json!({"ok": true, "cur": "V"}));
        put(
            0xf4,
            &[base, (0xb1, 1), (0xb2, 1), (0xf1, 1), (0xf3, 1)],
            "V",
        );
        assert_eq!(ask(0xf1), json!({"ok": true, "cur": "V"}));
        assert_rebuild_is_identity(t, col);
    });
}

/// 被扣住的删除落在带盐成员上（0xd1 只见过定义就删了第二份成员；0xb1 / 0xb2 各在一份成员上改过字段，都与它并发）：
/// `conflicts` 的 `entity` 是规范号、`others` 数全类成员上的并发修改（两条，不只是删除落的那份成员上的一条）；用列出来的
/// ID 交给 `resolve` 找得到这条冲突，裁决（按规范号写）之后它从列表里消失、另一条待裁决的笔记还在。每一步逐条维护与
/// 重建相同。
#[test]
fn conflicts_name_a_salted_member_by_its_class() {
    with(|t, col| {
        let w = tests_class::land(t, col);
        let seen = [tests_class::base_seen(&w)];
        let del = Body4::Edit(Edit4 {
            kind: EntKind::Note,
            entity: Key::Uuid(w.note[1]),
            key: "deleted".into(),
            value: "600".into(),
            ..crate::gen4::op::tests::native_edit()
        });
        t.tx(|t| {
            let mut ix = Index::new(t, col);
            native(t, &mut ix, col, &op(0xd1, 1, 600, &seen, &del));
            ix.settle().map(|_| ())
        })
        .unwrap();
        assert_rebuild_is_identity(t, col);
        let v = conflicts(t, col).unwrap();
        let ours = |v: &Value| -> Option<Value> {
            v.as_array()
                .unwrap()
                .iter()
                .find(|r| r["by"] == json!(id(0xd1).text()))
                .cloned()
        };
        let row = ours(&v).unwrap_or_else(|| panic!("{v}"));
        assert_eq!(row["entity"], json!(w.c_note.text()), "{v}");
        assert_eq!(row["entityKind"], json!("note"));
        assert_eq!(row["kind"], json!("delete_edit"));
        assert_eq!(row["at"], json!(600));
        assert_eq!(row["others"], json!(2), "{v}");
        assert_eq!(v.as_array().unwrap().len(), 2, "{v}");
        t.tx(|t| t.create_self(col, &Id(ME), &[9; 32], None, T0))
            .unwrap();
        writes::resolve(
            t,
            col,
            &json!({"now": T1, "conflict": row["id"], "delete": false}),
        )
        .unwrap();
        let v = conflicts(t, col).unwrap();
        assert_eq!(ours(&v), None, "{v}");
        let rows = v.as_array().unwrap();
        assert_eq!(rows.len(), 1, "{v}");
        assert_eq!(rows[0]["by"], json!(id(0xc1).text()));
        assert_rebuild_is_identity(t, col);
        // 同一条冲突不能再裁一次（它已经不在扣住的删除里）。
        let again = writes::resolve(
            t,
            col,
            &json!({"now": T1 + 1, "conflict": row["id"], "delete": false}),
        );
        assert!(again.unwrap_err().contains("no such conflict"));
    });
}

/// 别名迟到：两份带盐成员的盐（Salts 操作）在删除与并发修改之后才到。盐到之前两份成员各是一个类，删除落的那份上没有
/// 并发的操作、不扣住；盐到之后并成一个类，另一份上的并发修改把它扣住。逐条维护与重建相同，与「盐先到」的那条到达
/// 顺序结果相同。
#[test]
fn a_late_alias_holds_the_delete_by_its_class_and_rebuilds_the_same() {
    let run = |salts_first: bool| -> Value {
        with(|t, col| {
            let w = tests_class::twin();
            let base = tests_class::base_ops(&w);
            assert!(matches!(base[0], Body4::Salts { .. }));
            let last = base.len() as u64 - 1;
            let seen = [(0xa1, last)];
            let field = format!("f/{}", w.field[1].text());
            let del = tests_class::set(
                EntKind::Note,
                tests_class::u(w.note[0]),
                "deleted",
                json!(500),
            );
            let edit =
                tests_class::set(EntKind::Note, tests_class::u(w.note[1]), &field, json!("B"));
            let salts = |t: &Truth<'_>| {
                t.tx(|t| {
                    let mut ix = Index::new(t, col);
                    native(t, &mut ix, col, &op(0xe1, 1, 50, &[], &base[0]));
                    ix.settle().map(|_| ())
                })
                .unwrap();
            };
            if salts_first {
                salts(t);
            }
            t.tx(|t| {
                let mut ix = Index::new(t, col);
                for (i, b) in base[1..].iter().enumerate() {
                    native(
                        t,
                        &mut ix,
                        col,
                        &op(0xa1, i as u64 + 1, 100 + i as i64, &[], b),
                    );
                }
                native(t, &mut ix, col, &op(0xd1, 1, 500, &seen, &del));
                native(t, &mut ix, col, &op(0xb2, 1, 501, &seen, &edit));
                ix.settle().map(|_| ())
            })
            .unwrap();
            assert_rebuild_is_identity(t, col);
            if !salts_first {
                assert_eq!(conflicts(t, col).unwrap(), json!([]));
                salts(t);
                assert_rebuild_is_identity(t, col);
            }
            let v = conflicts(t, col).unwrap();
            let rows = v.as_array().unwrap();
            assert_eq!(rows.len(), 1, "{v}");
            assert_eq!(rows[0]["by"], json!(id(0xd1).text()));
            assert_eq!(rows[0]["entity"], json!(w.c_note.text()));
            assert_eq!(rows[0]["others"], json!(1));
            v
        })
    };
    assert_eq!(run(false), run(true));
}

/// 双盐场景、盐分两批到：[early] 的盐先到，0xa1 的定义、0xf1 的 [filler] 对两份带盐的填充笔记（每份盐一条，盐到齐时
/// 一起换规范 ID）、0xd1 删第一份成员、0xb2 并发改第二份，再到 [late] 的盐。[late] 不空时验盐到之前没有冲突（两份
/// 成员还不在一个类里）。每一步逐条维护与重建相同。返回最后的 `conflicts`。
fn late_salts_conflicts(early: &[&str], late: &[&str], filler: usize) -> Value {
    with(|t, col| {
        let w = tests_class::twin();
        let base = tests_class::base_ops(&w);
        assert!(matches!(base[0], Body4::Salts { .. }));
        let last = base.len() as u64 - 1;
        let seen = [(0xa1, last)];
        let field = format!("f/{}", w.field[1].text());
        let del = tests_class::set(
            EntKind::Note,
            tests_class::u(w.note[0]),
            "deleted",
            json!(500),
        );
        let edit = tests_class::set(EntKind::Note, tests_class::u(w.note[1]), &field, json!("B"));
        let salts = |t: &Truth<'_>, dev: u8, s: &[&str]| {
            t.tx(|t| {
                let mut ix = Index::new(t, col);
                let body = Body4::salts(s.iter().copied()).unwrap();
                native(t, &mut ix, col, &op(dev, 1, 50, &[], &body));
                ix.settle().map(|_| ())
            })
            .unwrap();
        };
        if !early.is_empty() {
            salts(t, 0xe1, early);
        }
        t.tx(|t| {
            let mut ix = Index::new(t, col);
            for (i, b) in base[1..].iter().enumerate() {
                native(
                    t,
                    &mut ix,
                    col,
                    &op(0xa1, i as u64 + 1, 100 + i as i64, &[], b),
                );
            }
            let mut seq = 0;
            for i in 0..filler {
                let guid = format!("fill-{i}");
                for (s, nt) in [(tests_class::U1, w.nt[0]), (tests_class::U2, w.nt[1])] {
                    seq += 1;
                    let body = tests_class::entity(
                        EntKind::Note,
                        tests_class::u(crate::gen4_ids::rules::note(Some(s), &guid)),
                        json!({"createdAt": 1, "guid": guid, "noteTypeId": nt.text()}),
                    );
                    native(t, &mut ix, col, &op(0xf1, seq, 200, &seen, &body));
                }
            }
            native(t, &mut ix, col, &op(0xd1, 1, 500, &seen, &del));
            native(t, &mut ix, col, &op(0xb2, 1, 501, &seen, &edit));
            ix.settle().map(|_| ())
        })
        .unwrap();
        assert_rebuild_is_identity(t, col);
        if !late.is_empty() {
            assert_eq!(conflicts(t, col).unwrap(), json!([]));
            salts(t, 0xe2, late);
            assert_rebuild_is_identity(t, col);
        }
        let v = conflicts(t, col).unwrap();
        let rows = v.as_array().unwrap();
        assert_eq!(rows.len(), 1, "{v}");
        assert_eq!(rows[0]["by"], json!(id(0xd1).text()));
        assert_eq!(rows[0]["entity"], json!(w.c_note.text()));
        assert_eq!(rows[0]["others"], json!(1));
        v
    })
}

/// 并类时删除落在类里**没变动**的那个成员上：U1 先到（第一份成员已归到规范号、删除在它上面），U2 后到只让第二份成员
/// （带着并发修改）并进来。别名表变了的行里没有删除落的那个成员，重看要按类找，不能只看变了的 ID。结果与盐一起到相同。
#[test]
fn a_late_member_holds_a_delete_on_a_member_that_did_not_move() {
    let together = late_salts_conflicts(&[tests_class::U1, tests_class::U2], &[], 0);
    assert_eq!(
        late_salts_conflicts(&[tests_class::U1], &[tests_class::U2], 0),
        together
    );
}

/// 盐到时别名表大面积变动（几百个带盐 ID 一起换规范 ID，多于 `MOVES_IN_PLACE`）：扣住与重建一样看全部有删除的实体，
/// 结果与小变动、与盐先到都相同。
#[test]
fn a_late_alias_moving_many_ids_still_holds_the_delete() {
    let together = late_salts_conflicts(&[tests_class::U1, tests_class::U2], &[], 0);
    assert_eq!(
        late_salts_conflicts(&[], &[tests_class::U1, tests_class::U2], 200),
        together
    );
    assert_eq!(
        late_salts_conflicts(&[tests_class::U1], &[tests_class::U2], 200),
        together
    );
}

/// 双盐场景里的冲突中心：被并发改动扣住的删除列出来，`by` / `at` 是那条删除的作者与墙钟；`profile_footprint` 把同一次
/// Anki 复习的两份带盐日志算一条。
#[test]
fn conflicts_and_footprint_read_by_class() {
    with(|t, col| {
        tests_class::land(t, col);
        let v = conflicts(t, col).unwrap();
        let rows = v.as_array().unwrap();
        assert_eq!(rows.len(), 1, "{v}");
        assert_eq!(rows[0]["entity"], json!(id(0x4e).text()));
        assert_eq!(rows[0]["entityKind"], json!("note"));
        assert_eq!(rows[0]["kind"], json!("delete_edit"));
        assert_eq!(rows[0]["by"], json!(id(0xc1).text()));
        assert_eq!(rows[0]["at"], json!(400));
        assert_eq!(rows[0]["others"], json!(1));
        let f = profile_footprint(t, col).unwrap();
        assert_eq!(f["reviews"], json!(1), "{f}");
    });
}

// ---------------------------------------------------------------------- status 的设备行状态

fn waiting(t: &Truth<'_>, col: i64, dev: u8, seq: u64, deps: &[(u8, u64)]) {
    let o = op(dev, seq, 900, deps, &note_edit(dev));
    let mut w = Writer::new();
    o.write(&mut w);
    let d = t
        .devices(col)
        .unwrap()
        .into_iter()
        .find(|d| d.id == id(dev))
        .unwrap()
        .dev;
    t.conn()
        .execute(
            "INSERT INTO op_wait (k, prev, chain, span, op) VALUES (?1, zeroblob(32), zeroblob(32), 1, ?2)",
            rusqlite::params![opk(d, seq).unwrap(), w.into_vec()],
        )
        .map_err(sql)
        .unwrap();
}

fn note_edit(dev: u8) -> Body4 {
    Body4::Edit(Edit4 {
        kind: EntKind::Note,
        entity: Key::Uuid(id(0x50)),
        key: format!("f/x{dev}"),
        value: "\"v\"".into(),
        ..crate::gen4::op::tests::native_edit()
    })
}

/// 设备行的 `state` 按协议 3 的判定顺序：自己的日志缺一截 = missing（`gap`）；别人在等它还没到的操作 = missing
/// （`blocking` 记在它头上）；自报协议低于最低读者 = upgrade；其余 ok。本机恒 ok。
#[test]
fn status_rows_report_gaps_blocking_and_upgrades() {
    with(|t, col| {
        t.tx(|t| {
            let mut ix = Index::new(t, col);
            for dev in [0xa1, 0xb1, 0xc1, 0xd1] {
                native(t, &mut ix, col, &op(dev, 1, 100, &[], &note_edit(dev)));
            }
            ix.settle().map(|_| ())
        })
        .unwrap();
        t.tx(|t| t.create_self(col, &Id(ME), &[9; 32], None, T0))
            .unwrap();
        // 0xa1：缺 seq 2，等着的是 seq 4。0xb1：seq 2 接得上，但依赖 0xc1 的 seq 3（本机只有 1）。
        waiting(t, col, 0xa1, 4, &[]);
        waiting(t, col, 0xa1, 5, &[]);
        waiting(t, col, 0xb1, 2, &[(0xc1, 3)]);
        // 0xd1 自报协议 3。
        t.tx(|t| {
            t.set_peer(
                col,
                &Peer {
                    device: id(0xd1),
                    public: [5; 32],
                    name: Some("old".into()),
                    ext: Some(json!({"v": 3}).to_string()),
                    head_gen: None,
                    first_seen: Some(T0),
                },
            )
            .map(|_| ())
        })
        .unwrap();
        let v = status(t, col).unwrap();
        let row = |dev: Id| -> Value {
            v["devices"]
                .as_array()
                .unwrap()
                .iter()
                .find(|r| r["device"] == json!(dev.text()))
                .cloned()
                .unwrap_or_else(|| panic!("no row in {v}"))
        };
        let a1 = row(id(0xa1));
        assert_eq!(
            (a1["gap"].clone(), a1["blocking"].clone()),
            (json!(2), json!(0))
        );
        assert_eq!(a1["state"], json!("missing"));
        let b1 = row(id(0xb1));
        assert_eq!(
            (b1["gap"].clone(), b1["blocking"].clone()),
            (json!(0), json!(0))
        );
        assert_eq!(b1["state"], json!("ok"));
        let c1 = row(id(0xc1));
        assert_eq!(
            (c1["gap"].clone(), c1["blocking"].clone()),
            (json!(0), json!(1))
        );
        assert_eq!(c1["state"], json!("missing"));
        let d1 = row(id(0xd1));
        assert_eq!(d1["protocol"], json!(3));
        assert_eq!(d1["state"], json!("upgrade"));
        let me = row(Id(ME));
        assert_eq!(me["state"], json!("ok"));
        assert_eq!(v["pending"], json!(3));
    });
}

// ---------------------------------------------------------------------- 代价

thread_local! {
    static STEPS: Cell<u64> = const { Cell::new(0) };
}

/// [f] 里一共执行了多少条 SQLite 虚拟机指令（`sqlite3_progress_handler` 每条指令回调一次）。数的是语句实际干的活，
/// 不是交出的结果行：表扫描在 SQL 内部按 WHERE 滤掉的行同样要一条条走指令，所以「按条件过滤的全表扫」也会让它随
/// 集合变大；走索引定位（一次 seek 一条指令，不管 B 树多深）则不变。
fn stepped(t: &Truth<'_>, f: impl FnOnce()) -> u64 {
    use std::os::raw::{c_int, c_void};
    unsafe extern "C" fn tick(_: *mut c_void) -> c_int {
        STEPS.with(|s| s.set(s.get() + 1));
        0
    }
    STEPS.with(|s| s.set(0));
    // SAFETY: 句柄来自这条活着的连接；回调不碰连接，只加线程局部计数，`f` 跑完立刻摘掉。
    unsafe {
        rusqlite::ffi::sqlite3_progress_handler(
            t.conn().handle(),
            1,
            Some(tick),
            std::ptr::null_mut(),
        );
        f();
        rusqlite::ffi::sqlite3_progress_handler(t.conn().handle(), 0, None, std::ptr::null_mut());
    }
    STEPS.with(|s| s.get())
}

/// 双盐场景再加 [n] 条别的笔记修改（设备 0xf1）。
fn grown(t: &Truth<'_>, col: i64, n: u64) {
    t.tx(|t| {
        let mut ix = Index::new(t, col);
        for i in 0..n {
            let mut b = [0x66u8; 16];
            b[8..].copy_from_slice(&i.to_be_bytes());
            let body = Body4::Edit(Edit4 {
                kind: EntKind::Note,
                entity: Key::Uuid(Id(b)),
                key: "f/z".into(),
                value: "\"z\"".into(),
                ..crate::gen4::op::tests::native_edit()
            });
            native(
                t,
                &mut ix,
                col,
                &op(0xf1, i + 1, 2000 + i as i64, &[], &body),
            );
        }
        ix.settle().map(|_| ())
    })
    .unwrap();
}

/// `conflicts`、`checkpoints`、`undo_check` 不随集合大小走：日志大 40 倍，执行的虚拟机指令数不变（还原点走部分索引
/// `ops_checkpoint`、冲突走 `hold_ix`、撤销校验走一个类的寄存器）。数指令而不是交出的行，WHERE 过滤式的扫表也抓得到。
#[test]
fn center_reads_do_not_walk_the_collection() {
    let measure = |n: u64| -> (u64, u64, u64) {
        with(|t, col| {
            let w = tests_class::land(t, col);
            grown(t, col, n);
            let req = json!({"items": [{"k": "note", "e": w.c_note.text(),
                "f": format!("f/{}", w.c_field.text()), "w": id(0xb1).text(), "s": 1}]});
            (
                stepped(t, || {
                    conflicts(t, col).unwrap();
                }),
                stepped(t, || {
                    checkpoints(t, col).unwrap();
                }),
                stepped(t, || {
                    undo_check(t, col, &req).unwrap();
                }),
            )
        })
    };
    let small = measure(25);
    let big = measure(1000);
    for (s, b, what) in [
        (small.0, big.0, "conflicts"),
        (small.1, big.1, "checkpoints"),
        (small.2, big.2, "undo_check"),
    ] {
        assert!(
            b <= s + 2,
            "{what}: {s} VM steps with 25 more ops, {b} with 1000"
        );
    }
}

/// 还原点的查询计划用部分索引 `ops_checkpoint`，不按主键区间扫这台设备的整条日志。
#[test]
fn checkpoints_read_only_checkpoint_rows() {
    with(|t, _| {
        let plan: Vec<String> = t
            .conn()
            .prepare(&format!(
                "EXPLAIN QUERY PLAN SELECT k FROM ops INDEXED BY ops_checkpoint WHERE kind = {} AND k BETWEEN ?1 AND ?2",
                crate::gen4::op::KIND_CHECKPOINT
            ))
            .unwrap()
            .query_map([0i64, 0], |r| r.get::<_, String>(3))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        assert!(
            plan.iter().any(|s| s.contains("ops_checkpoint")),
            "{plan:?}"
        );
        // 不写 INDEXED BY 时规划器自己也选它（统计里它只有 100 行）。
        let free: Vec<String> = t
            .conn()
            .prepare("EXPLAIN QUERY PLAN SELECT k FROM ops WHERE kind = 6 AND k BETWEEN ?1 AND ?2")
            .unwrap()
            .query_map([0i64, 0], |r| r.get::<_, String>(3))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        assert!(
            free.iter().any(|s| s.contains("ops_checkpoint")),
            "{free:?}"
        );
    });
}
