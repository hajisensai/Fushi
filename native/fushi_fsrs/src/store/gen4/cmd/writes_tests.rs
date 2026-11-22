//! 写命令新代实现的对拍与不变量测试（G7-3b）。
//!
//! **对拍**：同一个协议 3 的库（`tests.rs` 的 `library`，两台设备、冲突、复习、继承、Anki 导入都有）灌进新代
//! （`Pair::new`：重建两遍相同、逐条维护与重建相同、与协议 3 投影无差异），新代一侧再建本机身份。然后**同一串命令**
//! 分别打到协议 3（`store/ffi.rs` 的分发器，原命令）与新代（`cmd/writes*.rs`），再用 G7-4 的读命令（`cmd/reads.rs`）
//! 与协议 3 的原查询逐表比：身份记录、活着的修改、笔记 / 卡片缓存、日志。
//!
//! 两侧作者不同（协议 3 是它自己的设备、新代是新身份），新写入的修改行的写入者 / seq / HLC / 修改记录 ID 必然不同：
//! 修改行按 (实体, 键, 值, `m`) 比，日志行去掉 `hlc`（协议 3 存的是事件里的旧 HLC，新代是操作自己的）。`sched` 的日志
//! ID 由 `Id::new_v7` 随机生成，那一组再去掉日志 ID 与卡的 `last_log_id`。其余列逐列相同。

use rusqlite::Connection;
use serde_json::{Value, json};

use super::tests::{
    ANKI_AT, N1, N2, N3, N4, Norm, Pair, T0, card, decode, library, library_pair, note,
};
use super::writes::{self, Session, write};
use super::{writes_intent, writes_local, writes_restore};
use crate::gen4_ids::rules::{self, CANONICAL};
use crate::store::gen4::derive::Ref;
use crate::store::gen4::derive::tests::{assert_rebuild_is_identity, dump};
use crate::store::gen4::truth::{TRUST_PENDING, Truth};
use crate::store::sync2::canonical;
use crate::store::sync2::config::default_deck_id;
use crate::store::sync2::tests::{DAY, Device, P, edit, review};
use crate::sync2::id::{Id, Key};
use crate::sync2::op::Body;

const N5: &str = "0193a1b2-0000-7000-8000-0000000000a5";
const LANG: &str = "0193a1b2-0000-7000-8000-0000000000d1";
const JP: &str = "0193a1b2-0000-7000-8000-0000000000d2";
const ME: [u8; 16] = [0xe4; 16];
const T1: i64 = T0 + 3 * DAY;

/// 宿主发的修改记录草稿（Dart `_applyInput`）。协议 3 一侧要 `clk`（旧版时钟），新代不看。
fn draft(kind: &str, entity: &str, key: &str, v: Value) -> Value {
    json!({
        "e": {"t": "edit", "x": {"p": P, "k": kind, "e": entity, "f": key, "v": v, "ts": "anchored"}},
        "note": null, "clk": "t",
    })
}

fn chg(mut it: Value) -> Value {
    it["chg"] = json!(true);
    it
}

fn deck_events(id: &str, name: &str, parent: Option<&str>) -> Vec<Value> {
    let mut out = vec![
        json!({"t": "entity", "x": {"id": id, "p": P, "k": "deck", "d": {"createdAt": 1}}}),
        edit("deck", id, "name", json!(name)),
    ];
    if let Some(p) = parent {
        out.push(edit("deck", id, "parent", json!(p)));
    }
    out
}

/// `library` 再加两个牌组（`Lang`、`Lang::JP`），N1 / N3 首选 `Lang`、N2 首选 `JP`。
fn decked() -> Device {
    let a = library();
    let mut ev = deck_events(LANG, "Lang", None);
    ev.extend(deck_events(JP, "JP", Some(LANG)));
    ev.push(edit("note", N1, "deck", json!(LANG)));
    ev.push(edit("note", N3, "deck", json!(LANG)));
    ev.push(edit("note", N2, "deck", json!(JP)));
    a.apply(T0 + 2 * DAY, ev);
    a
}

/// 一对：协议 3 的设备与灌出来的新代库（新代一侧建好本机身份）。
struct W<'d> {
    p: Pair<'d>,
}

impl<'d> W<'d> {
    fn new(d: &'d Device) -> W<'d> {
        let p = Pair::new(d);
        let t = Truth::new(&p.g4);
        assert_eq!(
            t.tx(|t| t.create_self(p.col, &Id(ME), &[9; 32], None, T0)),
            Ok(true)
        );
        // 协议 3 的命令读的是它自己的缓存表（卡、笔记）：按新代同一份配置先把欠着的收尾做完、缓存整份重建（提交）。
        // 读侧（`Pair::p3`）每次还会在 SAVEPOINT 里再重建一遍，结果相同。
        {
            let w = d.core.writer().unwrap();
            crate::store::sync2::transport::replay_pending(
                &w,
                P,
                &mut crate::store::sync2::transport::CommitBudget::unlimited(),
            )
            .unwrap();
            let cfg =
                crate::store::caches::CacheConfig::parse(&serde_json::from_str(&p.cfg).unwrap())
                    .unwrap();
            crate::store::caches::rebuild(&w, P, &cfg).unwrap();
        }
        W { p }
    }

    fn t(&self) -> Truth<'_> {
        Truth::new(&self.p.g4)
    }

    /// 协议 3 一侧：经分发器发原命令。
    fn p3(&self, op: &str, now: i64, extra: Value, items: Option<&[Value]>) -> Value {
        self.p3_try(op, now, extra, items)
            .unwrap_or_else(|e| panic!("protocol 3 {op}: {e}"))
    }

    /// [W::p3]，报错原样返回。
    fn p3_try(
        &self,
        op: &str,
        now: i64,
        extra: Value,
        items: Option<&[Value]>,
    ) -> Result<Value, String> {
        let mut req = json!({
            "op": op, "profile": P, "now": now,
            "caches": serde_json::from_str::<Value>(&self.p.cfg).unwrap(),
            "legacyDevice": "dev", "tickNow": now,
        });
        for (k, v) in extra.as_object().cloned().unwrap_or_default() {
            req[k.as_str()] = v;
        }
        let mut blobs: Vec<Vec<u8>> = items
            .map(|i| Value::Array(i.to_vec()).to_string().into_bytes())
            .into_iter()
            .collect();
        let mut files = Vec::new();
        crate::store::legacy3::sync2_dispatch(&self.p.d.core, &req, &mut blobs, &mut files)
    }

    fn req(now: i64, extra: Value) -> Value {
        let mut req = json!({"now": now});
        for (k, v) in extra.as_object().cloned().unwrap_or_default() {
            req[k.as_str()] = v;
        }
        req
    }

    /// 本机身份日志里有几条操作。
    fn mine(&self) -> u64 {
        self.t().last_of(self.p.col, &Id(ME)).unwrap()
    }

    // ------------------------------------------------------------ 比

    fn edit_norm(&self, s: &str) -> String {
        self.p.ix(|ix| {
            let v: Value = serde_json::from_str(s).unwrap();
            let f = ix.canonical_key(v["f"].as_str().unwrap()).unwrap();
            let val = ix.canonical_value(&f, &v["v"]).unwrap();
            let e = ix
                .canonical(&Ref::of(&Key::of(v["e"].as_str().unwrap())))
                .unwrap()
                .text();
            canonical(&json!([v["k"], e, f, val, v.get("m")]))
        })
    }

    fn log_norm(&self, s: &str, ids: bool) -> String {
        self.p.ix(|ix| {
            let mut v: Value = serde_json::from_str(s).unwrap();
            let m = v.as_object_mut().unwrap();
            m.remove("hlc");
            m.remove("p");
            if !ids {
                // 随机生成的日志 ID：自己的与撤销指向的（撤的是本侧刚写的那条）。
                m.remove("id");
                m.remove("revokes");
            }
            canonical(&ix.canonical_json(&v).unwrap())
        })
    }

    /// 一张表两侧逐行（多重集）比；[f] 把一行归一。
    fn table(&self, req: Value, f: &dyn Fn(&[String]) -> Vec<String>) {
        let (_, pf) = self.p.p3(req.clone());
        let (_, gf) = self.p.g4(req.clone());
        let (pc, pd) = decode(&pf[0].1);
        let (gc, gd) = decode(&gf[0].1);
        assert_eq!(pc, gc, "{req}");
        let mut p: Vec<Vec<String>> = pd.iter().map(|r| f(r)).collect();
        let mut g: Vec<Vec<String>> = gd.iter().map(|r| f(r)).collect();
        p.sort();
        g.sort();
        if p != g {
            let only = |a: &[Vec<String>], b: &[Vec<String>]| -> Vec<Vec<String>> {
                a.iter().filter(|r| !b.contains(r)).cloned().collect()
            };
            panic!(
                "{req}: {} vs {} rows\n only protocol 3: {:?}\n only gen4: {:?}",
                p.len(),
                g.len(),
                only(&p, &g),
                only(&g, &p)
            );
        }
    }

    /// 两侧此刻的状态逐表相同（模块文件头）。[generated] = 有随机生成的日志 ID（`sched`）。
    fn same_state(&self, notes: &[&str], cards: &[String], generated: bool) {
        self.p.same(
            json!({"q": "entities"}),
            &[("t", &[Norm::Id, Norm::Plain, Norm::Payload])],
        );
        for kind in ["note", "card", "deck", "notetype"] {
            let ids: Vec<String> = match kind {
                "note" => notes.iter().map(|s| (*s).to_owned()).collect(),
                "card" => cards.to_vec(),
                "deck" => vec![LANG.into(), JP.into(), default_deck_id(P)],
                _ => vec!["NT".into()],
            };
            self.table(json!({"q": "edits", "kind": kind, "ids": ids}), &|r| {
                vec![self.edit_norm(&r[1])]
            });
        }
        let card_cols: Vec<(&str, Norm)> = crate::store::bulk::CARD_COLUMNS
            .iter()
            .map(|(n, _)| {
                (
                    *n,
                    match *n {
                        "last_log_id" if generated => Norm::Skip,
                        "id" | "note_id" | "template_id" | "deck_id" | "last_log_id" => Norm::Id,
                        _ => Norm::Plain,
                    },
                )
            })
            .collect();
        self.table(json!({"q": "cards"}), &|r| {
            r.iter()
                .zip(&card_cols)
                .map(|(c, (_, n))| self.p.norm(*n, c))
                .collect()
        });
        let note_cols = [
            Norm::Id,
            Norm::Id,
            Norm::Plain,
            Norm::Plain,
            Norm::Id,
            Norm::Plain,
            Norm::Plain,
            Norm::Plain,
            Norm::Plain,
            Norm::Plain,
            Norm::Plain,
            Norm::Skip,
            Norm::Plain,
        ];
        self.table(json!({"q": "notes"}), &|r| {
            r.iter()
                .zip(&note_cols)
                .map(|(c, n)| self.p.norm(*n, c))
                .collect()
        });
        self.table(json!({"q": "logs", "cards": cards}), &|r| {
            vec![
                if generated {
                    String::new()
                } else {
                    self.p.norm(Norm::Id, &r[0])
                },
                self.p.norm(Norm::Id, &r[1]),
                self.log_norm(&r[2], !generated),
            ]
        });
        let t = self.t();
        assert_rebuild_is_identity(&t, self.p.col);
    }
}

fn all_cards() -> Vec<String> {
    let mut out = Vec::new();
    for n in [N1, N2, N3, N4, N5] {
        for t in ["t1", "t2"] {
            out.push(card(n, t));
        }
    }
    out
}

// ---------------------------------------------------------------------- 对拍

/// `apply`：新笔记、字段、整列表标签（拆成 OR-Set）、`chg`（一条没变不落、一条落）、带 `answer` 意图的复习（盖配置
/// 快照）。回包的 `landed` 两侧相同，状态逐表相同。
#[test]
fn apply_matches_protocol_3() {
    let lib = library();
    let w = W::new(&lib);
    let items = vec![
        json!({"e": note(N5, "NT", 50), "note": null}),
        draft("note", N5, "f/fa", json!("魚")),
        draft("note", N1, "tags", json!(["a", "c", "c"])),
        chg(draft("note", N1, "f/fa", json!("猫"))),
        chg(draft("note", N3, "f/fa", json!("犬2"))),
        json!({"e": review("r9", &card(N1, "t1"), T1, 3, "review"), "note": N1, "intent": "answer"}),
    ];
    let pv = w.p3("apply", T1, json!({}), Some(&items));
    let gv = writes::apply(&w.t(), w.p.col, &W::req(T1, json!({})), &items).unwrap();
    assert_eq!(pv["landed"], gv["landed"], "{pv}\n{gv}");
    assert_eq!(gv["landed"], json!([true, true, true, false, true, true]));
    assert_eq!(gv["foreign"], json!([]));
    // 写入者是新代的本机身份；`edits` 记的就是它的 dot。
    let edits = gv["edits"].as_array().unwrap();
    assert!(!edits.is_empty());
    assert!(edits.iter().all(|e| e[3] == json!(Id(ME).text())), "{gv}");
    assert_eq!(gv["nextSeq"], json!(w.mine() + 1));
    w.same_state(&[N1, N2, N3, N4, N5], &all_cards(), false);
    // 第二批：同一条笔记的标签再改回去，`chg` 比的是上一批写下的值。
    let items = vec![
        draft("note", N1, "tags", json!(["b", "a"])),
        chg(draft("note", N3, "f/fa", json!("犬2"))),
        chg(draft("note", N3, "f/fa", json!("犬3"))),
        chg(draft("note", N3, "f/fa", json!("犬3"))),
    ];
    let pv = w.p3("apply", T1 + 1, json!({}), Some(&items));
    let gv = writes::apply(&w.t(), w.p.col, &W::req(T1 + 1, json!({})), &items).unwrap();
    assert_eq!(pv["landed"], gv["landed"]);
    assert_eq!(gv["landed"], json!([true, false, true, false]));
    w.same_state(&[N1, N2, N3, N4, N5], &all_cards(), false);
}

/// `import_drafts`：`init` 项碰到已有修改的键不落；`existed` 两侧相同。
#[test]
fn import_drafts_matches_protocol_3() {
    let lib = library();
    let w = W::new(&lib);
    let init = |it: Value| {
        let mut it = it;
        it["init"] = json!(true);
        it
    };
    let items = vec![
        json!({"e": note(N1, "NT", 10), "note": null}),
        json!({"e": note(N5, "NT", 50), "note": null}),
        init(draft("note", N1, "f/fa", json!("源里的旧值"))),
        init(draft("note", N1, "f/zz", json!("新字段"))),
        init(draft("note", N5, "f/fa", json!("魚"))),
    ];
    let pv = w.p3("import_drafts", T1, json!({}), Some(&items));
    let gv = writes::import_drafts(&w.t(), w.p.col, &W::req(T1, json!({})), &items).unwrap();
    assert_eq!(pv["existed"], gv["existed"]);
    assert_eq!(gv["existed"], json!([N1]));
    assert_eq!(pv["landed"], gv["landed"]);
    w.same_state(&[N1, N2, N3, N4, N5], &all_cards(), false);
    // `chg` 项不收。
    let e = writes::import_drafts(
        &w.t(),
        w.p.col,
        &W::req(T1, json!({})),
        &[chg(draft("note", N1, "f/fa", json!("x")))],
    )
    .unwrap_err();
    assert!(e.contains("chg"), "{e}");
}

/// C8：`.apkg` 导入按 Dart 的顺序发草稿（笔记身份 → 字段 → 标签 → 卡片修改）。`apply_in` 在身份记录与标签项处收尾，
/// 于是一条笔记的卡片修改总与下一条笔记的身份记录落进同一次收尾、而不与它自己的笔记同批。别名表不能因此每条笔记
/// 整表重算一次（那是 O(库大小)，整次导入 O(n²)）：建笔记类型那一批之后，每批整表重算 0 次，与库里已有多少笔记无关。
#[test]
fn importing_in_the_dart_order_never_recomputes_the_whole_alias_table() {
    let lib = library();
    let w = W::new(&lib);
    let anki_nt: i64 = 1_700_000_000_777;
    let nt = rules::note_type(CANONICAL, anki_nt);
    let fld = rules::field(&nt, 0);
    let tpl = rules::template(&nt, 0);
    let first = vec![
        json!({"e": {"t": "entity", "x": {"id": nt.text(), "p": P, "k": "notetype",
            "d": {"createdAt": 1, "ankiNum": anki_nt, "ntKind": "standard"}}}, "note": null}),
        draft(
            "notetype",
            &nt.text(),
            &format!("fieldDef/{}", fld.text()),
            json!({"name": "Front", "ord": 0, "ankiNum": 0}),
        ),
        draft(
            "notetype",
            &nt.text(),
            &format!("tmplDef/{}", tpl.text()),
            json!({"name": "Card 1", "ord": 0, "ankiNum": 0, "front": "{{Front}}"}),
        ),
    ];
    writes::import_drafts(&w.t(), w.p.col, &W::req(T1, json!({})), &first).unwrap();
    let mut n: i64 = 0;
    for batch in 0..4 {
        let mut items = Vec::new();
        for _ in 0..15 {
            n += 1;
            let guid = format!("c8-{n}");
            let x = rules::note(CANONICAL, &guid);
            let xc = rules::card(&x, &tpl, 0).text();
            let x = x.text();
            items.push(
                json!({"e": {"t": "entity", "x": {"id": x, "p": P, "k": "note",
                "d": {"createdAt": n, "guid": guid, "noteTypeId": nt.text()}}}, "note": null}),
            );
            items.push(draft(
                "note",
                &x,
                &format!("f/{}", fld.text()),
                json!(format!("語{n}")),
            ));
            items.push(draft("note", &x, "tags", json!(["c8"])));
            items.push(draft("card", &xc, "deck", json!(LANG)));
            items.push(draft("card", &xc, "suspended", json!(true)));
        }
        let v =
            writes::import_drafts(&w.t(), w.p.col, &W::req(T1 + batch, json!({})), &items).unwrap();
        assert_eq!(
            v["settled"]["aliasRebuilds"],
            json!(0),
            "batch {batch}: {}",
            v["settled"]
        );
    }
    assert_rebuild_is_identity(&w.t(), w.p.col);
}

/// `purge` 与 `checkpoint`：状态相同；清除的实体进 `purged`。
#[test]
fn purge_and_checkpoint_match_protocol_3() {
    let lib = library();
    let w = W::new(&lib);
    let req = json!({"kind": "note", "entities": [N2, N4]});
    w.p3("purge", T1, req.clone(), None);
    let gv = writes::purge(&w.t(), w.p.col, &W::req(T1, req)).unwrap();
    let purged = gv["purged"].as_array().unwrap();
    assert_eq!(purged.len(), 2, "{gv}");
    let req = json!({"name": "before", "reason": "manual"});
    w.p3("checkpoint", T1 + 1, req.clone(), None);
    writes::checkpoint(&w.t(), w.p.col, &W::req(T1 + 1, req)).unwrap();
    w.same_state(&[N1, N2, N3, N4], &all_cards(), false);
    let e = writes::purge(
        &w.t(),
        w.p.col,
        &W::req(T1, json!({"kind": "note", "entities": []})),
    )
    .unwrap_err();
    assert!(e.contains("missing entities"), "{e}");
}

/// `resolve`：删除与并发的修改冲突（扣住的删除），两侧按同一个冲突 ID 找到同一个实体，「恢复」与「删除」两种裁决后
/// 状态相同；不存在的冲突报错、什么都不写。
#[test]
fn resolve_matches_protocol_3() {
    for delete in [false, true] {
        // `library` 的两台设备（已同步完）：a 删 N1、b 并发改 N1。
        let (a, b, mut bucket) = library_pair();
        a.apply(T1 + 1, vec![edit("note", N1, "deleted", json!(T1 + 1))]);
        b.apply(T1 + 2, vec![edit("note", N1, "f/fa", json!("並行"))]);
        for _ in 0..2 {
            a.sync(&mut bucket, "loc", T1 + 3);
            b.sync(&mut bucket, "loc", T1 + 3);
        }
        let conflicts = a.core.sync2_conflicts(P).unwrap();
        let id = conflicts
            .as_array()
            .and_then(|c| c.first())
            .and_then(|c| c["id"].as_str())
            .unwrap_or_else(|| panic!("no conflict: {conflicts}"))
            .to_owned();
        let w = W::new(&a);
        let req = json!({"conflict": id, "delete": delete});
        let before = w.mine();
        let e = writes::resolve(
            &w.t(),
            w.p.col,
            &W::req(T1 + 4, json!({"conflict": "nope"})),
        )
        .unwrap_err();
        assert!(e.contains("no such conflict"), "{e}");
        assert_eq!(w.mine(), before);
        w.p3("resolve", T1 + 4, req.clone(), None);
        writes::resolve(&w.t(), w.p.col, &W::req(T1 + 4, req)).unwrap();
        assert_eq!(w.mine(), before + 1);
        w.same_state(&[N1, N2, N3, N4], &all_cards(), false);
    }
}

/// `note_fields_if`：`note` 模式整条笔记拒绝、`field` 模式逐项；被拒的笔记两侧相同，状态相同。
#[test]
fn note_fields_if_matches_protocol_3() {
    let lib = library();
    let w = W::new(&lib);
    let it = |n: &str, f: &str, x: &str, v: &str| json!({"n": n, "f": f, "x": x, "v": v});
    for (mode, items) in [
        (
            "note",
            vec![
                it(N1, "fa", "猫", "ねこ"),
                it(N1, "fb", "wrong", "x"),
                it(N3, "fa", "犬", "いぬ"),
                it(N4, "fa", "鳥", "とり"),
                it("0193a1b2-0000-7000-8000-0000000000ff", "fa", "", "x"),
            ],
        ),
        (
            "field",
            vec![
                it(N1, "fa", "猫", "ねこ"),
                it(N1, "fb", "wrong", "x"),
                it(N3, "fa", "いぬ", "犬"),
                it(N3, "fa", "いぬ", "犬犬"),
            ],
        ),
    ] {
        let extra = json!({"mode": mode, "ts": "anchored"});
        let pv = w.p3("note_fields_if", T1, extra.clone(), Some(&items));
        let gv =
            writes_intent::note_fields_if(&w.t(), w.p.col, &W::req(T1, extra), &items).unwrap();
        assert_eq!(pv["rejected"], gv["rejected"], "{mode}");
        w.same_state(&[N1, N2, N3, N4], &all_cards(), false);
    }
}

/// `change`：还原点 + 修改（`chg`）+ 移牌组段（看换完之后的可见卡）。
#[test]
fn change_with_move_matches_protocol_3() {
    let lib = decked();
    let w = W::new(&lib);
    let items = vec![
        chg(draft("note", N1, "f/fa", json!("猫"))),
        draft("note", N3, "f/fb", json!("dog C")),
    ];
    let extra = json!({
        "checkpoint": {"name": "change", "reason": "change_notetype"},
        "move": {"deck": JP, "notes": [N1, N3, N1]},
        "ts": "anchored",
    });
    let pv = w.p3("change", T1, extra.clone(), Some(&items));
    let gv = writes_intent::change(&w.t(), w.p.col, &W::req(T1, extra), &items).unwrap();
    assert_eq!(pv["landed"], gv["landed"], "{pv}\n{gv}");
    w.same_state(&[N1, N2, N3, N4], &all_cards(), false);
}

/// 复核 minor-5：`change` 的 `chg` 整列表 `tags` 项按协议 3 的合成 `tags` 行判「没变」——值与此刻标签逐值相同的项筛掉
/// （不进 `landed`，全筛掉回包是 `{}`），带重复的、从没碰过标签的笔记的照留。修复之前新代对 `tags` 恒判「变了」，
/// `landed` 比协议 3 多一项、下标错位。
#[test]
fn change_drops_unchanged_tag_lists_like_protocol_3() {
    let lib = library();
    let w = W::new(&lib);
    let run = |now: i64, items: Vec<Value>| -> Value {
        let pv = w.p3("change", now, json!({"ts": "anchored"}), Some(&items));
        let gv = writes_intent::change(
            &w.t(),
            w.p.col,
            &W::req(now, json!({"ts": "anchored"})),
            &items,
        )
        .unwrap();
        assert_eq!(pv.get("landed"), gv.get("landed"), "{pv}\n{gv}");
        gv
    };
    // 只有一项、值没变：两侧都筛空。
    let gv = run(T1, vec![chg(draft("note", N1, "tags", json!(["b", "a"])))]);
    assert!(gv.get("landed").is_none(), "{gv}");
    // 混着：没变的筛掉，带重复的（逐值不同）与没碰过标签的笔记的留下，字段照落。
    let gv = run(
        T1 + 1,
        vec![
            chg(draft("note", N1, "tags", json!(["b", "a"]))),
            chg(draft("note", N1, "tags", json!(["b", "a", "a"]))),
            chg(draft("note", N3, "tags", json!([]))),
            draft("note", N3, "f/fb", json!("dog C")),
        ],
    );
    assert_eq!(gv["landed"], json!([false, false, true]), "{gv}");
    w.same_state(&[N1, N2, N3, N4], &all_cards(), false);
}

/// `merge_notes`：前身链接、补空字段、并标签、删被吸收的。
#[test]
fn merge_notes_matches_protocol_3() {
    let lib = library();
    let w = W::new(&lib);
    let extra = json!({"keep": N3, "absorb": [N1, N3, N2], "deletedAt": T1, "ts": "anchored"});
    let pv = w.p3("merge_notes", T1, extra.clone(), None);
    let gv = writes_intent::merge_notes(&w.t(), w.p.col, &W::req(T1, extra)).unwrap();
    assert_eq!(pv["linked"], gv["linked"]);
    assert_eq!(pv["unmatched"], gv["unmatched"]);
    w.same_state(&[N1, N2, N3, N4], &all_cards(), false);
    // 不存在的笔记：报错、什么都不写。
    let before = w.mine();
    let e = writes_intent::merge_notes(
        &w.t(),
        w.p.col,
        &W::req(T1 + 1, json!({"keep": N3, "absorb": ["0193a1b2-0000-7000-8000-0000000000ff"], "deletedAt": T1})),
    )
    .unwrap_err();
    assert!(e.contains("not found"), "{e}");
    assert_eq!(w.mine(), before);
}

/// `deck_delete`：plan → 分步（limit 1）直到 done（只移卡 / 连笔记一起删）；走完之后状态相同。
#[test]
fn deck_delete_matches_protocol_3() {
    for delete_cards in [false, true] {
        let lib = decked();
        let w = W::new(&lib);
        let plan = json!({"deck": LANG, "deleteCards": delete_cards, "plan": true});
        let pv = w.p3("deck_delete", T1, plan.clone(), None);
        let gv = writes_intent::deck_delete(&w.t(), w.p.col, &W::req(T1, plan)).unwrap();
        assert_eq!(pv["total"], gv["total"], "{pv}\n{gv}");
        assert_eq!(pv["done"], gv["done"]);
        // 两侧各自走到 done（游标不同：协议 3 按缓存 rowid，新代按 ID）。
        let base = json!({"deck": LANG, "deleteCards": delete_cards, "limit": 1, "deletedAt": T1 + 1, "ts": "anchored"});
        let (mut token, mut p_counts) = (Value::Null, Vec::new());
        for _ in 0..64 {
            let mut r = base.clone();
            r["token"] = token;
            let v = w.p3("deck_delete", T1 + 1, r, None);
            p_counts.push(v["count"].clone());
            token = v["token"].clone();
            if v["done"] == json!(true) {
                break;
            }
        }
        let (mut token, mut g_counts) = (Value::Null, Vec::new());
        for _ in 0..64 {
            let mut r = base.clone();
            r["token"] = token;
            let v = writes_intent::deck_delete(&w.t(), w.p.col, &W::req(T1 + 1, r)).unwrap();
            g_counts.push(v["count"].clone());
            token = v["token"].clone();
            if v["done"] == json!(true) {
                break;
            }
        }
        assert!(token.is_object());
        // N1 的两张卡是前身 / 后继（`historyFrom`），后继卡的牌组跟着前身卡走（`config::card_deck_with` 的血统规则）。
        // 协议 3 按 rowid 先移了前身，后继随之离开子树、不再单写；新代按 ID 先遇到后继，但「前身先于后继」
        // （`writes_intent.rs` `Mover`）先把前身移掉、后继不单写——真相逐表相同，卡的修改行也比（复核 minor-4：
        // 修复之前新代给后继多写一条卡级牌组，这里卡的修改行比不过）。新代的计数把提前移的前身算进去：每步计数加起来 =
        // plan 的 total；协议 3 少的就是跟着走、没被游标碰到的那张后继。
        w.same_state(&[N1, N2, N3, N4], &all_cards(), false);
        let sum = |c: &[Value]| c.iter().filter_map(Value::as_i64).sum::<i64>();
        assert_eq!(
            sum(&g_counts),
            gv["total"].as_i64().unwrap(),
            "{g_counts:?}"
        );
        assert_eq!(
            sum(&p_counts) + 1,
            sum(&g_counts),
            "{p_counts:?} vs {g_counts:?}"
        );
        let e = writes_intent::deck_delete(
            &w.t(),
            w.p.col,
            &W::req(T1 + 2, json!({"deck": default_deck_id(P), "plan": true})),
        )
        .unwrap_err();
        assert!(e.contains("default deck"), "{e}");
    }
}

/// `sched`：重置 / 改期 / 撤销（只撤最后一条生效的）/ 按牌组重排。日志 ID 随机，比状态时去掉。
#[test]
fn sched_matches_protocol_3() {
    let lib = decked();
    let w = W::new(&lib);
    let c1 = card(N1, "t1");
    let c3 = card(N3, "t1");
    let base = json!({"at": T1, "utcOff": 0, "rollover": 4, "ts": "anchored"});
    let run = |items: Value| -> (Value, Value) {
        let mut extra = base.clone();
        extra["items"] = items;
        let pv = w.p3("sched", T1, extra.clone(), None);
        let gv = writes_intent::sched(&w.t(), w.p.col, &W::req(T1, extra)).unwrap();
        assert_eq!(pv["blocked"], gv["blocked"], "{pv}\n{gv}");
        assert_eq!(
            pv["logs"].as_array().map(Vec::len),
            gv["logs"].as_array().map(Vec::len)
        );
        (pv, gv)
    };
    run(json!([{"a": "setDue", "card": c1, "due": 19_800}]));
    w.same_state(&[N1, N2, N3, N4], &all_cards(), true);
    run(json!([{"a": "reset", "card": c3, "skipNew": true}, {"a": "reset", "card": c1}]));
    w.same_state(&[N1, N2, N3, N4], &all_cards(), true);
    // 撤销：r1 不是最后一条生效的 → blocked；各侧撤自己写的那条重置。
    let (pv, gv) = run(json!([{"a": "undo", "card": c1, "log": "r1"}]));
    assert_eq!(gv["blocked"], json!(1), "{gv}");
    let last = |v: &Value| v["logs"].as_array().map_or(0, Vec::len);
    assert_eq!(last(&pv), 0);
    run(json!([{"a": "rescheduleDeck", "deck": LANG}]));
    w.same_state(&[N1, N2, N3, N4], &all_cards(), true);
}

/// `sched` 的撤销：撤自己刚写的那条（两侧各自的日志 ID），之后状态相同。
#[test]
fn sched_undo_of_its_own_log_matches_protocol_3() {
    let lib = decked();
    let w = W::new(&lib);
    let c1 = card(N1, "t1");
    let base = json!({"at": T1, "utcOff": 0, "rollover": 4, "ts": "anchored"});
    let with = |items: Value| {
        let mut e = base.clone();
        e["items"] = items;
        e
    };
    let pv = w.p3("sched", T1, with(json!([{"a": "reset", "card": c1}])), None);
    let gv = writes_intent::sched(
        &w.t(),
        w.p.col,
        &W::req(T1, with(json!([{"a": "reset", "card": c1}]))),
    )
    .unwrap();
    let pid = pv["logs"][0]["id"].as_str().unwrap().to_owned();
    let gid = gv["logs"][0]["id"].as_str().unwrap().to_owned();
    let pu = w.p3(
        "sched",
        T1 + 1,
        with(json!([{"a": "undo", "card": c1, "log": pid}])),
        None,
    );
    let gu = writes_intent::sched(
        &w.t(),
        w.p.col,
        &W::req(T1 + 1, with(json!([{"a": "undo", "card": c1, "log": gid}]))),
    )
    .unwrap();
    assert_eq!(pu["blocked"], json!(0));
    assert_eq!(gu["blocked"], json!(0), "{gu}");
    w.same_state(&[N1, N2, N3, N4], &all_cards(), true);
}

// ---------------------------------------------------------------------- 形状

/// `status` 的形状与协议 3 相同（规划 §2.1：`sync2_status` 形状不变）：顶层键、设备行与位置行的键集合。
#[test]
fn status_keeps_the_protocol_3_shape() {
    let lib = library();
    let w = W::new(&lib);
    let keys = |v: &Value| -> Vec<String> {
        let mut k: Vec<String> = v.as_object().unwrap().keys().cloned().collect();
        k.sort();
        k
    };
    let p = lib.core.sync2_status(P).unwrap();
    let g = writes_local::status(&w.t(), w.p.col).unwrap();
    assert_eq!(keys(&p), keys(&g), "{p}\n{g}");
    let base = [
        "applied",
        "behind",
        "device",
        "digestMismatch",
        "frozen",
        "name",
        "seenAt",
        "self",
        "warning",
    ];
    for row in g["devices"].as_array().unwrap() {
        for k in base {
            assert!(row.get(k).is_some(), "{k} missing in {row}");
        }
    }
    for row in p["devices"].as_array().unwrap() {
        for k in base {
            assert!(row.get(k).is_some(), "protocol 3 lost {k}");
        }
    }
    let selfs = g["devices"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|r| r["self"] == json!(true))
        .count();
    assert_eq!(selfs, 1, "{g}");
    assert_eq!(g["device"], json!(Id(ME).text()));
    assert_eq!(g["nextSeq"], json!(1));
    assert_eq!(keys(&p["selfInfo"]), keys(&g["selfInfo"]));
    // 没有本机身份：`enabled: false`（协议 3 同）。
    let conn = crate::store::gen4::schema::open_in_memory().unwrap();
    let t = Truth::new(&conn);
    let col = crate::store::gen4::truth::tests::bound(&t);
    assert_eq!(
        writes_local::status(&t, col).unwrap(),
        json!({"enabled": false})
    );
}

/// `device_hint`：空串 / 同值不写（`changed: false`），新值写进去、`status` 的设备行带上；`device_info` 合并并给视图。
#[test]
fn device_hint_and_info_keep_their_shapes() {
    let lib = library();
    let w = W::new(&lib);
    let dev = w.t().devices(w.p.col).unwrap()[0].id;
    let hint =
        |h: &str| writes_local::device_hint(&w.t(), &json!({"device": dev.text(), "hint": h}));
    assert_eq!(hint("  "), Ok(json!({"changed": false})));
    assert_eq!(hint(" 客厅\u{7}的电脑 "), Ok(json!({"changed": true})));
    assert_eq!(hint("客厅的电脑"), Ok(json!({"changed": false})));
    let p = lib
        .core
        .sync2_device_hint(&dev.text(), "客厅的电脑")
        .unwrap();
    assert_eq!(p, json!({"changed": true}));
    let g = writes_local::status(&w.t(), w.p.col).unwrap();
    let row = g["devices"]
        .as_array()
        .unwrap()
        .iter()
        .find(|r| r["device"] == json!(dev.text()))
        .unwrap();
    assert_eq!(row["hint"], json!("客厅的电脑"));
    let v = writes_local::device_info(&w.t(), w.p.col, &json!({"model": "Pixel", "app": "3.4"}))
        .unwrap();
    let pv = lib
        .core
        .sync2_device_info(P, &json!({"model": "Pixel", "app": "3.4"}), T1)
        .unwrap();
    let keys = |v: &Value| -> Vec<String> {
        let mut k: Vec<String> = v.as_object().unwrap().keys().cloned().collect();
        k.sort();
        k
    };
    assert_eq!(keys(&pv), keys(&v));
    assert_eq!(v["name"], json!("Pixel"));
    assert_eq!(v["changed"], json!(true));
    let v = writes_local::device_info(&w.t(), w.p.col, &json!({"nick": "我的"})).unwrap();
    assert_eq!(
        (v["name"].clone(), v["model"].clone()),
        (json!("我的"), json!("Pixel"))
    );
    let v = writes_local::device_info(&w.t(), w.p.col, &json!({"nick": "我的"})).unwrap();
    assert_eq!(v["changed"], json!(false));
    let g = writes_local::status(&w.t(), w.p.col).unwrap();
    assert_eq!(g["selfInfo"]["name"], json!("我的"));
}

/// `trust`：本机身份不能改；把一台设备设成待确认后它的删除被扣住，信任之后放行（`released` 计数），拒绝 = 0。
#[test]
fn trust_releases_held_deletes() {
    let lib = library();
    let w = W::new(&lib);
    let t = w.t();
    let col = w.p.col;
    let e = writes_local::trust(&t, col, &json!({"now": T1, "device": Id(ME).text()})).unwrap_err();
    assert!(e.contains("always trusted"), "{e}");
    // 库里那条删除 N4 的作者设成待确认：删除被扣住，N4 回到可见。
    let author = t
        .devices(col)
        .unwrap()
        .into_iter()
        .find(|d| d.id != Id(ME) && d.last > 0)
        .unwrap()
        .id;
    t.tx(|t| {
        t.set_trust(col, &author, Some(TRUST_PENDING), T1)?;
        let mut ix = crate::store::gen4::derive::Index::new(t, col);
        ix.trust_changed();
        ix.settle().map(|_| ())
    })
    .unwrap();
    let held = {
        let ix = crate::store::gen4::derive::Index::new(&t, col);
        ix.distrusted().unwrap().len()
    };
    let rejected = writes_local::trust(
        &t,
        col,
        &json!({"now": T1, "device": author.text(), "trust": false}),
    )
    .unwrap();
    assert_eq!(rejected["released"], json!(0));
    assert_eq!(rejected["trusted"], json!(false));
    let trusted =
        writes_local::trust(&t, col, &json!({"now": T1, "device": author.text()})).unwrap();
    assert_eq!(trusted["released"], json!(held), "{trusted}");
    assert_eq!(t.trust_of(col, &author), Ok(None));
    // 信任之后设备行不再带信任项；`state` 是同步状态，每行都有。
    let rows = writes_local::status(&t, col).unwrap()["devices"].clone();
    for r in rows.as_array().unwrap() {
        assert!(r.get("trust").is_none(), "{r}");
        assert!(r.get("state").is_some(), "{r}");
    }
    assert_rebuild_is_identity(&t, col);
}

/// 一台设备设成待确认（两侧各自的信任表），扣住它的删除。
fn make_pending(w: &W<'_>, device: &Id) {
    let col = w.p.col;
    w.t()
        .tx(|t| {
            t.set_trust(col, device, Some(TRUST_PENDING), T1)?;
            let mut ix = crate::store::gen4::derive::Index::new(t, col);
            ix.trust_changed();
            ix.settle().map(|_| ())
        })
        .unwrap();
    w.p.d
        .core
        .writer()
        .unwrap()
        .execute(
            "INSERT INTO sync2_trust (profile_uid, device, state, since) VALUES (srs_id(?1), ?2, 1, ?3)",
            rusqlite::params![P, device.0.to_vec(), T1],
        )
        .unwrap();
}

/// 协议 3 一侧的本机设备（新代一侧它只是一台对端）。
fn p3_self(w: &W<'_>) -> Id {
    Id::parse(
        w.p.d.core.sync2_status(P).unwrap()["device"]
            .as_str()
            .unwrap(),
    )
    .unwrap()
}

/// 两侧都是对端、写过日志的那台设备（`library` 的另一台）。
fn author_of(w: &W<'_>) -> Id {
    let mine = p3_self(w);
    w.t()
        .devices(w.p.col)
        .unwrap()
        .into_iter()
        .filter(|d| d.id != Id(ME) && d.id != mine && d.last > 0)
        .max_by_key(|d| d.last)
        .unwrap()
        .id
}

/// 复核 major-1：拒绝一台**已经可信**的设备、或一台**从没见过**的设备，两侧都报同一句错、什么都不写（协议 3
/// `trust.rs` `reject` 改到 0 行就报错）。修复之前新代照写一条拒绝：可信作者已生效的删除被回溯扣住（已删的实体
/// 重新可见），没见过的设备预先记成拒绝。
#[test]
fn rejecting_a_trusted_or_unknown_device_is_refused_like_protocol_3() {
    let lib = library();
    let w = W::new(&lib);
    let col = w.p.col;
    let author = author_of(&w);
    for device in [author, Id([7; 16])] {
        let before = fingerprint(&w);
        let pe = w
            .p3_try(
                "trust",
                T1,
                json!({"device": device.text(), "trust": false}),
                None,
            )
            .unwrap_err();
        let ge = writes_local::trust(
            &w.t(),
            col,
            &json!({"now": T1, "device": device.text(), "trust": false}),
        )
        .unwrap_err();
        assert_eq!(pe, "trust: device is already trusted");
        assert_eq!(ge, pe);
        assert_eq!(fingerprint(&w), before);
        assert_eq!(w.t().trust_of(col, &device), Ok(None));
    }
    w.same_state(&[N1, N2, N3, N4], &all_cards(), false);
    // 待确认的设备照常能拒绝，再拒一次也不报错（协议 3 同：行在就算改到）。
    make_pending(&w, &author);
    for _ in 0..2 {
        let v = writes_local::trust(
            &w.t(),
            col,
            &json!({"now": T1, "device": author.text(), "trust": false}),
        )
        .unwrap();
        assert_eq!(v["trusted"], json!(false));
    }
    assert_eq!(
        w.t().trust_of(col, &author),
        Ok(Some(crate::store::gen4::truth::TRUST_REJECTED))
    );
}

/// 复核 major-2：`status` 的设备行与协议 3 逐行同形——`state` 只放同步状态（`SrsDeviceState` 认得的值），信任单独放
/// `trust` / `trustSince` / `heldDeletes` / `heldPurges`，`gap` / `blocking` / `protocol` 都在；Dart
/// `SrsDeviceView.fromStatus` 读的每个键在新代行里都有（可缺省的扩展键除外）。
#[test]
fn status_device_rows_match_protocol_3_key_for_key() {
    let lib = library();
    let w = W::new(&lib);
    let col = w.p.col;
    let author = author_of(&w);
    make_pending(&w, &author);
    let p = lib.core.sync2_status(P).unwrap();
    let g = writes_local::status(&w.t(), col).unwrap();
    let row = |v: &Value, d: &Id| -> Value {
        v["devices"]
            .as_array()
            .unwrap()
            .iter()
            .find(|r| r["device"] == json!(d.text()))
            .cloned()
            .unwrap_or_else(|| panic!("no row for {} in {v}", d.text()))
    };
    // 扩展键（`model` / `app` / `platform` / `protocol` / `hint` / `retiredAt` / `rules`）按有没有数据出现（对端的
    // `protocol` 来自它自报的扩展，灌库不带 `peers.ext`），不比；其余逐个相同。
    let optional = [
        "model",
        "app",
        "platform",
        "protocol",
        "hint",
        "retiredAt",
        "rules",
    ];
    let keys = |r: &Value| -> Vec<String> {
        let mut k: Vec<String> = r
            .as_object()
            .unwrap()
            .keys()
            .filter(|k| !optional.contains(&k.as_str()))
            .cloned()
            .collect();
        k.sort();
        k
    };
    let pa = row(&p, &author);
    let ga = row(&g, &author);
    assert_eq!(keys(&pa), keys(&ga), "{pa} vs {ga}");
    assert_eq!(ga["trust"], json!("pending"));
    assert_eq!(ga["trustSince"], json!(T1));
    assert_eq!(ga["state"], json!("ok"));
    // 扣着的条数：库里的删除（N4）是协议 3 本机写的，新代一侧它是对端——只在新代把它设成待确认，按作者分开计数。
    let deleter = p3_self(&w);
    w.t()
        .tx(|t| {
            t.set_trust(col, &deleter, Some(TRUST_PENDING), T1 + 5)?;
            let mut ix = crate::store::gen4::derive::Index::new(t, col);
            ix.trust_changed();
            ix.settle().map(|_| ())
        })
        .unwrap();
    let held = crate::store::gen4::derive::Index::new(&w.t(), col)
        .distrusted()
        .unwrap()
        .into_iter()
        .filter(|o| o.device == deleter)
        .count() as i64;
    let g = writes_local::status(&w.t(), col).unwrap();
    let gd = row(&g, &deleter);
    assert!(gd["heldDeletes"].as_i64().unwrap() >= 1, "{gd}");
    assert_eq!(gd["trustSince"], json!(T1 + 5));
    assert_eq!(
        gd["heldDeletes"].as_i64().unwrap() + gd["heldPurges"].as_i64().unwrap(),
        held
    );
    // 本机行：两侧各自的本机。
    let selfrow = |v: &Value| -> Value {
        v["devices"]
            .as_array()
            .unwrap()
            .iter()
            .find(|r| r["self"] == json!(true))
            .cloned()
            .unwrap()
    };
    let (ps, gs) = (selfrow(&p), selfrow(&g));
    assert_eq!(keys(&ps), keys(&gs), "{ps} vs {gs}");
    assert_eq!(gs["state"], json!("ok"));
    assert_eq!(gs["protocol"], json!(crate::gen4::PROTOCOL));
    // Dart `SrsDeviceView.fromStatus` 必读的键；`state` 是 `SrsDeviceState.parse` 认得的值。
    let dart = [
        "device",
        "self",
        "name",
        "seenAt",
        "behind",
        "gap",
        "blocking",
        "state",
        "digestMismatch",
        "warning",
    ];
    for r in g["devices"].as_array().unwrap() {
        for k in dart {
            assert!(r.get(k).is_some(), "{k} missing in {r}");
        }
        assert!(
            ["ok", "behind", "missing", "upgrade", "retired"]
                .contains(&r["state"].as_str().unwrap()),
            "{r}"
        );
    }
    for k in ["trust", "trustSince", "heldDeletes", "heldPurges"] {
        assert!(ga.get(k).is_some(), "{k} missing in {ga}");
    }
}

// ---------------------------------------------------------------------- 原子性、拒写

/// 状态指纹：本机身份日志末尾、`self_.hlc`、派生表的全部行。
fn fingerprint(w: &W<'_>) -> (u64, String, Vec<String>) {
    let t = w.t();
    let me = t.self_identity(w.p.col).unwrap().unwrap();
    (
        w.mine(),
        crate::store::gen4::truth::hlc_text(&me.hlc),
        dump(&w.p.g4, w.p.col),
    )
}

/// 批量写的原子性：一批里任何一项出错（坏意图、`stamped`、不认识的事件、意图命令的注入失败），整笔回滚——日志、
/// `self_.hlc`、派生表一个字节不变；会话照常可用。
#[test]
fn a_failing_item_rolls_the_whole_batch_back() {
    let lib = decked();
    let w = W::new(&lib);
    let before = fingerprint(&w);
    let good = draft("note", N1, "f/fa", json!("写到一半"));
    let bad_items = [
        json!({"e": review("rx", &card(N1, "t1"), T1, 3, "review"), "note": N1, "intent": "nonsense"}),
        json!({"e": edit("note", N1, "f/fa", json!("x")), "stamped": true}),
        json!({"e": {"t": "media", "x": {}}}),
        chg(json!({"e": review("ry", &card(N1, "t1"), T1, 3, "review")})),
    ];
    for bad in bad_items {
        let e = writes::apply(
            &w.t(),
            w.p.col,
            &W::req(T1, json!({})),
            &[good.clone(), bad.clone()],
        )
        .unwrap_err();
        assert!(!e.is_empty());
        assert_eq!(fingerprint(&w), before, "{bad}");
    }
    let e = writes::apply(
        &w.t(),
        w.p.col,
        &W::req(T1, json!({"stamps": true})),
        &[good.clone()],
    )
    .unwrap_err();
    assert!(e.contains("stamps"), "{e}");
    assert_eq!(fingerprint(&w), before);
    // 意图命令写完之后注入失败：已写的整笔回滚。
    let it = json!({"n": N1, "f": "fa", "x": "猫", "v": "ねこ"});
    let e = writes_intent::note_fields_if(
        &w.t(),
        w.p.col,
        &W::req(T1, json!({"mode": "field", "failAfter": "apply"})),
        &[it],
    )
    .unwrap_err();
    assert!(e.contains("injected"), "{e}");
    assert_eq!(fingerprint(&w), before);
    for stage in ["apply", "move"] {
        let e = writes_intent::change(
            &w.t(),
            w.p.col,
            &W::req(
                T1,
                json!({"checkpoint": {"name": "c", "reason": "r"}, "move": {"deck": JP, "notes": [N1]}, "failAfter": stage}),
            ),
            &[draft("note", N1, "f/fb", json!("x"))],
        )
        .unwrap_err();
        assert!(e.contains("injected"), "{e}");
        assert_eq!(fingerprint(&w), before, "{stage}");
    }
    let e = writes_intent::merge_notes(
        &w.t(),
        w.p.col,
        &W::req(
            T1,
            json!({"keep": N3, "absorb": [N1], "deletedAt": T1, "failAfter": "apply"}),
        ),
    )
    .unwrap_err();
    assert!(e.contains("injected"), "{e}");
    assert_eq!(fingerprint(&w), before);
    // 回滚之后照常写，seq 接着最后一次提交。
    let v = writes::apply(&w.t(), w.p.col, &W::req(T1, json!({})), &[good]).unwrap();
    assert_eq!(v["nextSeq"], json!(before.0 + 2));
}

/// 条件写：`expectLast` 不成立 = `stale`、什么都不写；成立才落。比的是规范 ID。
#[test]
fn expect_last_guards_the_write() {
    let lib = library();
    let w = W::new(&lib);
    let c1 = card(N1, "t1");
    let (_, gf) =
        w.p.g4(json!({"q": "cards", "ids": [c1], "fields": ["id", "last_log_id"]}));
    let last = decode(&gf[0].1).1[0][1].clone();
    let before = fingerprint(&w);
    let item = json!({"e": review("r10", &c1, T1, 3, "review"), "note": N1, "intent": "answer"});
    for stale in [json!("r1"), Value::Null] {
        let v = writes::apply(
            &w.t(),
            w.p.col,
            &W::req(T1, json!({"expectLast": {"card": c1, "log": stale}})),
            &[item.clone()],
        )
        .unwrap();
        assert_eq!(v, json!({"stale": true}));
        assert_eq!(fingerprint(&w), before);
    }
    let v = writes::apply(
        &w.t(),
        w.p.col,
        &W::req(T1, json!({"expectLast": {"card": c1, "log": last}})),
        &[item],
    )
    .unwrap();
    assert_eq!(v["landed"], json!([true]));
    assert_eq!(w.mine(), before.0 + 1);
}

/// 身份被换后拒写：命令中途本机身份被换掉（G8-6 `rotate_identity`），下一条写入报错、整笔回滚（连换身份一起）；
/// 换身份提交之后的新命令用新身份写。
#[test]
fn a_rotated_identity_refuses_the_rest_of_the_command() {
    let lib = library();
    let w = W::new(&lib);
    let col = w.p.col;
    writes::checkpoint(
        &w.t(),
        col,
        &W::req(T1, json!({"name": "a", "reason": "r"})),
    )
    .unwrap();
    let before = fingerprint(&w);
    let t = w.t();
    let e = write(&t, col, |s: &mut Session<'_, '_>| {
        s.land(
            Body::Checkpoint {
                name: "b".into(),
                reason: "r".into(),
            },
            T1 + 1,
        )?;
        s.t.rotate_identity(col, 1, T1 + 1)?;
        s.land(
            Body::Checkpoint {
                name: "c".into(),
                reason: "r".into(),
            },
            T1 + 2,
        )?;
        Ok(json!({}))
    })
    .unwrap_err();
    assert!(e.contains("identity changed"), "{e}");
    assert_eq!(fingerprint(&w), before);
    assert_eq!(t.self_identity(col).unwrap().unwrap().device, Id(ME));
    let fresh = t.tx(|t| t.rotate_identity(col, 1, T1 + 3)).unwrap();
    let v = writes::checkpoint(
        &t,
        col,
        &W::req(T1 + 4, json!({"name": "d", "reason": "r"})),
    )
    .unwrap();
    assert_eq!(
        v["nextSeq"].as_u64(),
        Some(t.last_of(col, &fresh).unwrap() + 1)
    );
    assert!(t.last_of(col, &fresh).unwrap() >= 1);
}

/// 没有本机身份的集合：写命令报错，不偷偷建身份。
#[test]
fn a_collection_without_identity_is_refused() {
    let conn: Connection = crate::store::gen4::schema::open_in_memory().unwrap();
    let t = Truth::new(&conn);
    let col = crate::store::gen4::truth::tests::bound(&t);
    let e =
        writes::checkpoint(&t, col, &json!({"now": T1, "name": "a", "reason": "r"})).unwrap_err();
    assert!(e.contains("no local identity"), "{e}");
    assert_eq!(t.self_identity(col), Ok(None));
}

/// 新代日志不带旧 HLC：事件里的 `hlc` 丢掉，操作的 HLC 就是排序键（`native_allowed` 不会拒）；`digest_heal` 重建
/// 之后派生表与重建前相同；`dedup` 不写。
#[test]
fn logs_drop_the_legacy_hlc_and_heal_rebuilds_the_same_rows() {
    let lib = library();
    let w = W::new(&lib);
    let col = w.p.col;
    let item = json!({"e": review("r11", &card(N2, "t1"), T1, 3, "review"), "note": N2});
    writes::apply(&w.t(), col, &W::req(T1, json!({})), &[item]).unwrap();
    let t = w.t();
    let me = t.self_identity(col).unwrap().unwrap();
    let op = t
        .entry(
            col,
            &crate::sync2::vv::OpId {
                device: Id(ME),
                seq: 1,
            },
        )
        .unwrap()
        .unwrap();
    let body = op.op().unwrap().body().unwrap();
    let crate::gen4::op::Body4::Log(l) = body else {
        panic!("not a log: {body:?}")
    };
    assert_eq!((l.hlc.is_none(), l.server_time.is_none()), (true, true));
    assert!(
        l.extra.contains("\"sc\""),
        "config snapshot stamped: {}",
        l.extra
    );
    assert_eq!(me.hlc, op.op().unwrap().hlc);
    let rows = dump(&w.p.g4, col);
    let v = writes_local::digest_heal(&t, col, &json!({"now": T1})).unwrap();
    assert_eq!(v["healed"], json!(1));
    assert_eq!(dump(&w.p.g4, col), rows);
    let before = fingerprint(&w);
    assert_eq!(writes_local::dedup(&t, col), Ok(json!({"done": true})));
    assert_eq!(fingerprint(&w), before);
}

// ---------------------------------------------------------------------- 崩溃

/// 子进程那一半：在一条写命令里写了几条操作，不提交就退出（等于写到一半被杀）。
#[test]
fn writes_child_process_half() {
    let Ok(path) = std::env::var("FUSHI_G4_WRITES_CHILD_DB") else {
        return;
    };
    let conn = crate::store::gen4::schema::open(std::path::Path::new(&path)).unwrap();
    let col: i64 = conn
        .query_row("SELECT col FROM self_", [], |r| r.get(0))
        .unwrap();
    let t = Truth::new(&conn);
    let _ = write(&t, col, |s| {
        for i in 0..3 {
            s.land(
                Body::Checkpoint {
                    name: format!("crash-{i}"),
                    reason: "r".into(),
                },
                T1 + i,
            )?;
        }
        println!("G4_WRITES_CHILD landed, exiting without commit");
        std::process::exit(0);
    });
}

/// 崩溃：另一个进程写到一半退出。重开之后日志停在最后一次提交、派生表与重建相同，接着写 seq 连续。
#[test]
fn a_crash_mid_command_commits_nothing() {
    let dir = crate::store::sync2::tests::tempdir::new("gen4-writes-crash");
    let path = dir.0.join("srs4.db");
    let col = {
        let conn = crate::store::gen4::schema::open(&path).unwrap();
        let t = Truth::new(&conn);
        let col = crate::store::gen4::native::tests::ready(&t);
        writes::checkpoint(&t, col, &json!({"now": T1, "name": "a", "reason": "r"})).unwrap();
        col
    };
    let out = std::process::Command::new(std::env::current_exe().unwrap())
        .args([
            "--exact",
            "store::gen4::cmd::writes_tests::writes_child_process_half",
            "--nocapture",
            "--test-threads=1",
        ])
        .env("FUSHI_G4_WRITES_CHILD_DB", &path)
        .output()
        .unwrap();
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(out.status.success(), "{stdout}");
    assert!(stdout.contains("G4_WRITES_CHILD landed"), "{stdout}");
    let conn = crate::store::gen4::schema::open(&path).unwrap();
    let t = Truth::new(&conn);
    let me = crate::store::gen4::native::tests::me();
    assert_eq!(t.last_of(col, &me), Ok(1));
    assert_rebuild_is_identity(&t, col);
    let v =
        writes::checkpoint(&t, col, &json!({"now": T1 + 9, "name": "b", "reason": "r"})).unwrap();
    assert_eq!(v["nextSeq"], json!(3));
    assert_eq!(t.audit(col), Ok(2));
}

// ---------------------------------------------------------------------- restore（复核 major-3）

/// 两侧的预览（协议 3 `sync2_plan_restore`、新代 `writes_restore::plan_restore`）相同。
fn same_plan(w: &W<'_>, p3: &crate::store::sync2::timeline::RestoreTarget, g4: &Value, now: i64) {
    let pv = w.p.d.core.sync2_plan_restore(P, p3, true, now).unwrap();
    let mut req = g4.clone();
    req["now"] = json!(now);
    req["retract"] = json!(true);
    let gv = writes_restore::plan_restore(&w.t(), w.p.col, &req).unwrap();
    assert_eq!(pv, gv, "plan");
}

/// `restore` 到还原点：打还原点之后新建笔记、改字段、删笔记、改标签、作答、移卡，再恢复到还原点（连作答一起撤回）。
/// 两侧各打各的还原点（作者不同、因果相同），恢复之后状态逐表相同；预览的计数两侧相同、且不为空。
#[test]
fn restore_matches_protocol_3_to_a_checkpoint() {
    let lib = decked();
    let w = W::new(&lib);
    // 打还原点之前：前身卡 N1/t1 有卡级牌组，后继卡 N1/t2 没有（跟着前身走）。之后给后继单写一条，恢复时它那一刻没有
    // 自己的记录，要写回血统继承到的值（不是 null，null 会挡住继承）。
    let pre = vec![draft("card", &card(N1, "t1"), "deck", json!(LANG))];
    w.p3("apply", T1 - 1, json!({}), Some(&pre));
    writes::apply(&w.t(), w.p.col, &W::req(T1 - 1, json!({})), &pre).unwrap();
    let cp = json!({"name": "cp", "reason": "manual"});
    w.p3("checkpoint", T1, cp.clone(), None);
    writes::checkpoint(&w.t(), w.p.col, &W::req(T1, cp)).unwrap();
    let p_cp = w.p.d.core.sync2_checkpoints(P).unwrap()[0].clone();
    let p_id = crate::sync2::vv::OpId {
        device: Id::parse(p_cp["device"].as_str().unwrap()).unwrap(),
        seq: p_cp["seq"].as_u64().unwrap(),
    };
    let g_id = json!({"device": Id(ME).text(), "seq": w.mine()});
    let items = vec![
        json!({"e": note(N5, "NT", 50), "note": null}),
        draft("note", N5, "f/fa", json!("魚")),
        draft("note", N1, "f/fa", json!("猫2")),
        draft("note", N2, "deleted", json!(T1 + 1)),
        draft("note", N1, "tags", json!(["z", "a"])),
        draft("card", &card(N3, "t1"), "deck", json!(JP)),
        draft("card", &card(N1, "t2"), "deck", json!(JP)),
        json!({"e": review("r9", &card(N1, "t1"), T1 + 1, 3, "review"), "note": N1, "intent": "answer"}),
    ];
    w.p3("apply", T1 + 1, json!({}), Some(&items));
    writes::apply(&w.t(), w.p.col, &W::req(T1 + 1, json!({})), &items).unwrap();
    let cards = all_cards();
    w.same_state(&[N1, N2, N3, N4, N5], &cards, false);
    let p_target = crate::store::sync2::timeline::RestoreTarget::Checkpoint(p_id);
    let g_target = json!({"checkpoint": g_id});
    same_plan(&w, &p_target, &g_target, T1 + 2);
    let plan = writes_restore::plan_restore(
        &w.t(),
        w.p.col,
        &json!({"now": T1 + 2, "checkpoint": g_id, "retract": true}),
    )
    .unwrap();
    assert_eq!(plan["revived"], json!(1), "{plan}");
    assert_eq!(plan["removed"], json!(1), "{plan}");
    assert_eq!(plan["reviews"], json!(1), "{plan}");
    assert!(plan["fields"].as_i64().unwrap() >= 2, "{plan}");
    assert_eq!(plan["tags"], json!(2), "{plan}");
    w.p3(
        "restore",
        T1 + 2,
        json!({"checkpoint": p_cp.clone(), "retract": true}),
        None,
    );
    let gv = writes_restore::restore(
        &w.t(),
        w.p.col,
        &W::req(T1 + 2, json!({"checkpoint": g_id, "retract": true})),
    )
    .unwrap();
    assert!(!gv["changed"].as_array().unwrap().is_empty(), "{gv}");
    w.same_state(&[N1, N2, N3, N4, N5], &cards, true);
    // 再预览同一个目标：字段、标签、复活都已还原；之后才建的 N5 照协议 3 仍算一条（「之后才建的」不看它现在删没删），
    // 两侧相同。
    same_plan(&w, &p_target, &g_target, T1 + 3);
    let plan = writes_restore::plan_restore(
        &w.t(),
        w.p.col,
        &json!({"now": T1 + 3, "checkpoint": g_id, "retract": false}),
    )
    .unwrap();
    assert_eq!(
        plan,
        json!({"fields": 0, "revived": 0, "removed": 1, "tags": 0, "reviews": 0})
    );
}

/// `restore` 到时刻：落在 `library` 历史中间（继承链之后、删 N4 之前、冲突与 r3 之前；Anki 导入的复习墙钟在后但
/// 发生时刻在前，算「那一刻之前」不撤回）。两侧逐表相同，预览相同。
#[test]
fn restore_matches_protocol_3_to_a_time() {
    let lib = library();
    let w = W::new(&lib);
    let at = T0 + DAY + 15;
    same_plan(
        &w,
        &crate::store::sync2::timeline::RestoreTarget::At(at),
        &json!({"at": at}),
        T1,
    );
    w.p3("restore", T1, json!({"at": at, "retract": true}), None);
    writes_restore::restore(
        &w.t(),
        w.p.col,
        &W::req(T1, json!({"at": at, "retract": true})),
    )
    .unwrap();
    w.same_state(&[N1, N2, N3, N4], &all_cards(), true);
    // N4 复活，N3 的冲突字段回到没有值。
    let g =
        w.p.ix(|ix| {
            ix.class_value(
                crate::sync2::op::EntKind::Note,
                &Ref::of(&Key::of(N4)),
                "deleted",
            )
        })
        .unwrap();
    assert_eq!(g.as_deref(), Some("null"));
}

/// BUG-5190：恢复到「后继卡自己还没记标志」的那一刻，写回血统继承到的值。同一层两张前身都记了 `flag`：继承的是生效
/// 写入最新的那张，不是卡 ID 序在前的那张（与缓存层 `registers::cards_group` 同一规则，`registers::later`）。挑 ID 序
/// 在前的那张先写，旧规则会取到它。两侧（协议 3 的测试参照、新代）的预览与恢复后的状态相同。
#[test]
fn restore_writes_back_the_flag_of_the_latest_written_predecessor_of_a_layer() {
    let lib = library();
    let (mut lo, mut hi) = (card(N2, "t2"), card(N3, "t2"));
    if crate::ordering::cmp_utf16(&hi, &lo).is_lt() {
        std::mem::swap(&mut lo, &mut hi);
    }
    let tail = card(N2, "t1");
    let t = T0 + 2 * DAY;
    lib.apply(t, vec![edit("card", &lo, "flag", json!(1))]);
    lib.apply(t + 10, vec![edit("card", &hi, "flag", json!(2))]);
    lib.apply(
        t + 20,
        vec![
            edit("card", &tail, &format!("historyFrom/{lo}"), json!(true)),
            edit("card", &tail, &format!("historyFrom/{hi}"), json!(true)),
        ],
    );
    lib.apply(t + 30, vec![edit("card", &tail, "flag", json!(3))]);
    let w = W::new(&lib);
    let at = t + 25;
    same_plan(
        &w,
        &crate::store::sync2::timeline::RestoreTarget::At(at),
        &json!({"at": at}),
        T1,
    );
    w.p3("restore", T1, json!({"at": at, "retract": true}), None);
    writes_restore::restore(
        &w.t(),
        w.p.col,
        &W::req(T1, json!({"at": at, "retract": true})),
    )
    .unwrap();
    w.same_state(&[N1, N2, N3, N4], &all_cards(), true);
    let g =
        w.p.ix(|ix| {
            ix.class_value(
                crate::sync2::op::EntKind::Card,
                &Ref::of(&Key::of(&tail)),
                "flag",
            )
        })
        .unwrap();
    assert_eq!(g.as_deref(), Some("2"));
}

/// `restore` 的原子性与拒写：注入失败 / 还原点不存在 = 整笔回滚（还原点、补偿操作、`self_.hlc`、派生表一个不留）。
#[test]
fn a_failing_restore_writes_nothing() {
    let lib = library();
    let w = W::new(&lib);
    let before = fingerprint(&w);
    let e = writes_restore::restore(
        &w.t(),
        w.p.col,
        &W::req(
            T1,
            json!({"at": T0 + DAY + 15, "retract": true, "failAfter": "restore"}),
        ),
    )
    .unwrap_err();
    assert!(e.contains("injected failure"), "{e}");
    assert_eq!(fingerprint(&w), before);
    let e = writes_restore::restore(
        &w.t(),
        w.p.col,
        &W::req(
            T1,
            json!({"checkpoint": {"device": Id([7; 16]).text(), "seq": 1}}),
        ),
    )
    .unwrap_err();
    assert_eq!(e, "checkpoint not found");
    assert_eq!(fingerprint(&w), before);
    let e = writes_restore::restore(&w.t(), w.p.col, &W::req(T1, json!({}))).unwrap_err();
    assert!(e.contains("missing at"), "{e}");
    assert_eq!(fingerprint(&w), before);
}

// ---------------------------------------------------------------------- Anki 来源日志的 HLC（K3，交接 §26 C4）

/// Dart 导入器写的一条 Anki 来源日志（`srs_apkg_import.dart` `_revlogLog` / 锚点）：`hlc` 是 Dart
/// `srsImportedRevlogHlc` / `srsImportAnchorHlc` 给的。协议 3 收下它当 `legacy_hlc`；新代丢掉、在日志投影里按
/// `crate::anki_import_rules` 再派生（`cmd/writes.rs` 文件头「只写协议 4 原生能收的形」）。
fn anki_item(
    id: &str,
    card: &str,
    note: &str,
    kind: &str,
    at: i64,
    rating: Option<i64>,
    ivl: i64,
) -> Value {
    let anchor = kind == "importAnchor";
    let mut x = json!({
        "id": id, "p": P, "card": card, "kind": kind,
        "hlc": format!("{at}:{}:anki", i64::from(anchor)),
        "at": at, "ts": "wall", "origin": "anki", "rtype": if anchor { "manual" } else { "review" },
        "utcOff": 0, "rollover": 4,
        "res": {"queue": "review", "ivl": ivl, "step": 0, "reps": 1, "lapses": 0, "scheduler": "fushi", "dueDay": ivl},
    });
    if !anchor {
        x["ankiId"] = json!(at);
        x["alg"] = json!("anki");
        x["dur"] = json!(5000);
    }
    if let Some(r) = rating {
        x["rating"] = json!(r);
    }
    json!({"e": {"t": "log", "x": x}, "note": note})
}

impl W<'_> {
    /// 发生在 [at] 的统计行条数：(协议 3, 新代)。
    fn stat_rows_at(&self, at: i64) -> (i64, i64) {
        let w = self.p.d.core.writer().unwrap();
        let old = super::tests::on_p3(&w, &self.p.cfg, |c| {
            c.query_row(
                "SELECT COUNT(*) FROM srs_stat_reviews WHERE occurred_at = ?1",
                [at],
                |r| r.get(0),
            )
            .unwrap()
        });
        let new = self
            .p
            .g4
            .query_row(
                "SELECT COUNT(*) FROM stats WHERE col = ?1 AND at = ?2",
                [self.p.col, at],
                |r| r.get(0),
            )
            .unwrap();
        (old, new)
    }

    /// 新代 `read logs` 里 [card] 的日志：(规范日志 ID, `hlc`)。
    fn log_hlcs(&self, card: &str) -> Vec<(String, String)> {
        let (_, f) = self.p.g4(json!({"q": "logs", "cards": [card]}));
        let (_, rows) = decode(&f[0].1);
        rows.iter()
            .map(|r| {
                let v: Value = serde_json::from_str(&r[2]).unwrap();
                (r[0].clone(), v["hlc"].as_str().unwrap().to_owned())
            })
            .collect()
    }

    /// 新代卡片行里最后一条有效日志是 [log]（规范 ID）的卡有几张。
    fn cards_last_at(&self, log: &str) -> i64 {
        self.p
            .g4
            .query_row(
                "SELECT COUNT(*) FROM cards WHERE col = ?1 AND last_log_id = ?2",
                rusqlite::params![self.p.col, Ref::of(&Key::of(&self.p.canon(log)))],
                |r| r.get(0),
            )
            .unwrap()
    }
}

/// 同一条 Anki revlog 落在血统里前身、后继两张卡上（Lapis 换成 Fushi 卡片后重导；Dart 按新卡重算日志 ID，内容相同）：
/// 统计只算一次，卡片状态、日志与协议 3 相同。改前新代按操作 HLC 排、两份副本 HLC 不同不成组：统计 2 行、后继卡的代表
/// 日志变成新导入的那份（C4）。
#[test]
fn an_anki_revlog_on_two_cards_of_a_lineage_counts_once() {
    let lib = library();
    let w = W::new(&lib);
    let (c31, c32) = (card(N3, "t1"), card(N3, "t2"));
    let link = vec![draft(
        "card",
        &c32,
        &format!("historyFrom/{c31}"),
        json!(true),
    )];
    w.p3("apply", T1, json!({}), Some(&link));
    writes::apply(&w.t(), w.p.col, &W::req(T1, json!({})), &link).unwrap();
    // `library` 已经把 a1（ANKI_AT）导入到 c31 上；同一条 revlog 再导入到后继卡 c32。
    assert_eq!(w.stat_rows_at(ANKI_AT), (1, 1));
    let items = vec![anki_item("a1copy", &c32, N3, "review", ANKI_AT, Some(3), 3)];
    w.p3("import_drafts", T1 + 1, json!({}), Some(&items));
    writes::import_drafts(&w.t(), w.p.col, &W::req(T1 + 1, json!({})), &items).unwrap();
    assert_eq!(w.stat_rows_at(ANKI_AT), (1, 1));
    let anki = format!("{ANKI_AT}:0:anki");
    let hlcs = w.log_hlcs(&c32);
    assert!(
        !hlcs.is_empty() && hlcs.iter().all(|(_, h)| *h == anki),
        "{hlcs:?}"
    );
    w.same_state(&[N1, N2, N3, N4], &all_cards(), false);
}

/// 比本机原生复习（r3，T0 + DAY + 52）更早、评分不同的 Anki 复习导入之后不改卡片当前排程：它排在原生复习之前，最后一条
/// 有效日志仍是 r3（与协议 3 相同）。改前新代按导入时刻排，它成了最后一条，把 ivl 拉回 9（C4 的静默排程错误）。
#[test]
fn an_anki_review_older_than_a_native_one_does_not_reschedule_the_card() {
    let lib = library();
    let w = W::new(&lib);
    let c21 = card(N2, "t1");
    assert_eq!(w.cards_last_at("r3"), 1);
    let items = vec![anki_item("a2", &c21, N2, "review", T0 + DAY, Some(1), 9)];
    w.p3("import_drafts", T1, json!({}), Some(&items));
    writes::import_drafts(&w.t(), w.p.col, &W::req(T1, json!({})), &items).unwrap();
    assert_eq!(w.cards_last_at("r3"), 1);
    assert_eq!(w.cards_last_at("a2"), 0);
    w.same_state(&[N1, N2, N3, N4], &all_cards(), false);
}

/// 导入锚点与同一毫秒的 revlog 一起写（输入里锚点在前）：锚点的 HLC 是 `(T, 1, "anki")`、排在 revlog `(T, 0, "anki")`
/// 之后，成为最后一条有效日志（与协议 3 相同）；`apply` 回包的 `logHlcs` 与 `read logs` 的 `hlc` 逐字相同。
#[test]
fn an_import_anchor_sorts_after_the_revlog_of_the_same_millisecond() {
    let lib = library();
    let w = W::new(&lib);
    let c22 = card(N2, "t2");
    let at = T0 + 2 * DAY;
    let items = vec![
        anki_item("x-anchor", &c22, N2, "importAnchor", at, None, 7),
        anki_item("x-rev", &c22, N2, "review", at, Some(3), 3),
    ];
    w.p3("apply", T1, json!({}), Some(&items));
    let gv = writes::apply(
        &w.t(),
        w.p.col,
        &W::req(T1, json!({"logHlcs": true})),
        &items,
    )
    .unwrap();
    let replied: Vec<(String, String)> = gv["logHlcs"]
        .as_array()
        .unwrap()
        .iter()
        .map(|l| {
            (
                l[1].as_str().unwrap().to_owned(),
                l[2].as_str().unwrap().to_owned(),
            )
        })
        .collect();
    assert_eq!(
        replied,
        vec![
            (w.p.canon("x-anchor"), format!("{at}:1:anki")),
            (w.p.canon("x-rev"), format!("{at}:0:anki")),
        ]
    );
    let mut read = w.log_hlcs(&c22);
    read.sort();
    let mut want = replied.clone();
    want.sort();
    assert_eq!(read, want);
    assert_eq!(w.cards_last_at("x-anchor"), 1);
    w.same_state(&[N1, N2, N3, N4], &all_cards(), false);
}

// ---------------------------------------------------------------------- 外来原生日志的排序键（第五波，规划 §6）

/// Dart 回导 Fushi 导出包时恢复的一条外来原生日志（`srs_apkg_import.dart` `_remapExtLog`）：`origin` = fushi，`hlc`
/// 是作者设备的 HLC（新代丢掉），带标记 `foreignLog: true`（`crate::anki_import_rules::FOREIGN_LOG_KEY`）。
fn foreign_item(id: &str, card: &str, note: &str, at: i64, rating: i64, ivl: i64) -> Value {
    json!({"e": {"t": "log", "x": {
        "id": id, "p": P, "card": card, "kind": "review", "rating": rating,
        "hlc": format!("{at}:3:author-device"), "at": at, "ts": "wall", "origin": "fushi",
        "rtype": "review", "dur": 4000, "alg": "fsrs6", "utcOff": 0, "rollover": 4, "foreignLog": true,
        "res": {"queue": "review", "ivl": ivl, "step": 0, "reps": 2, "lapses": 0, "scheduler": "fushi", "dueDay": ivl},
    }}, "note": note})
}

/// 回导的外来原生日志比本机原生复习（r3，T0 + DAY + 52）更早：它按来源数据（发生时刻）排在 r3 之前，最后一条有效日志
/// 仍是 r3（与协议 3 按作者 HLC 排的结果相同），排序键是 `{at}:0:fushi`、与 `logHlcs` 回包逐字相同。改前新代丢了作者
/// HLC、按导入时刻（操作 HLC）排，它成了最后一条，把 ivl 改成 9（交接 §28「没做」第 3 条）。
#[test]
fn a_foreign_native_review_older_than_a_local_one_does_not_reschedule_the_card() {
    let lib = library();
    let w = W::new(&lib);
    let c21 = card(N2, "t1");
    assert_eq!(w.cards_last_at("r3"), 1);
    let at = T0 + DAY;
    let items = vec![foreign_item("f1", &c21, N2, at, 1, 9)];
    w.p3("import_drafts", T1, json!({}), Some(&items));
    writes::import_drafts(&w.t(), w.p.col, &W::req(T1, json!({})), &items).unwrap();
    assert_eq!(w.cards_last_at("r3"), 1);
    assert_eq!(w.cards_last_at("f1"), 0);
    let f1 = w.p.canon("f1");
    let derived = format!("{at}:0:fushi");
    assert!(
        w.log_hlcs(&c21)
            .iter()
            .any(|(id, h)| *id == f1 && *h == derived),
        "{:?}",
        w.log_hlcs(&c21)
    );
    w.same_state(&[N1, N2, N3, N4], &all_cards(), false);
    // `apply` 回包的 `logHlcs` 与 `read logs` 同口径。
    let gv = writes::apply(
        &w.t(),
        w.p.col,
        &W::req(T1 + 1, json!({"logHlcs": true})),
        &[foreign_item("f2", &c21, N2, at + 1, 1, 9)],
    )
    .unwrap();
    assert_eq!(
        gv["logHlcs"],
        json!([[0, w.p.canon("f2"), format!("{}:0:fushi", at + 1)]])
    );
    assert_eq!(w.cards_last_at("r3"), 1);
}

/// 同一份导出包回导两次（第二次的导入时刻不同）：卡片行、日志投影逐行不变。这条是防回归用例、不是「修前红」的：同 ID
/// 日志类的代表取操作号最小的那份（`cache.rs` `log_class_rep`），第二次导入的副本本来就当不了代表，去掉派生它照样绿
/// （第五波复核变异实测）。它钉住的是「重复导入不换代表、不重排」这条现状。
#[test]
fn importing_the_same_foreign_logs_twice_changes_nothing() {
    let lib = library();
    let w = W::new(&lib);
    let c21 = card(N2, "t1");
    // 一条比 r3 早、一条比 r3 晚：晚的那条是最后一条有效日志。
    let items = vec![
        foreign_item("f1", &c21, N2, T0 + DAY, 1, 9),
        foreign_item("f3", &c21, N2, T0 + 2 * DAY, 3, 11),
    ];
    writes::import_drafts(&w.t(), w.p.col, &W::req(T1, json!({})), &items).unwrap();
    assert_eq!(w.cards_last_at("f3"), 1);
    let cards = |w: &W<'_>| -> Vec<String> {
        let mut stmt = w
            .p
            .g4
            .prepare(
                "SELECT hex(id), hex(last_log_id), due_day, scheduled_days, reps, queue FROM cards \
                     WHERE col = ?1 ORDER BY id",
            )
            .unwrap();
        stmt.query_map([w.p.col], |r| {
            Ok(format!(
                "{:?} {:?} {:?} {:?} {:?} {:?}",
                r.get::<_, Option<String>>(0)?,
                r.get::<_, Option<String>>(1)?,
                r.get::<_, Option<i64>>(2)?,
                r.get::<_, Option<i64>>(3)?,
                r.get::<_, Option<i64>>(4)?,
                r.get::<_, Option<String>>(5)?,
            ))
        })
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap()
    };
    let (rows, logs) = (cards(&w), w.log_hlcs(&c21));
    writes::import_drafts(&w.t(), w.p.col, &W::req(T1 + DAY, json!({})), &items).unwrap();
    assert_eq!(cards(&w), rows);
    assert_eq!(w.log_hlcs(&c21), logs);
    assert_eq!(w.cards_last_at("f3"), 1);
}

/// 发生时刻在未来的外来日志（`at` 晚于载着它的导入操作；导入文件不可信，伪造的 fushi-ext 能写任意 `at`）不派生排序键、
/// 回落到导入操作的 HLC：此后本机的原生复习仍排在它之后、决定排程。改前它派生成 `{at}:0:fushi`，本机此后一切复习都排在
/// 它前面，排程钉死在它的结果上（第五波复核）。
#[test]
fn a_foreign_log_from_the_future_does_not_pin_the_schedule() {
    let lib = library();
    let w = W::new(&lib);
    let c21 = card(N2, "t1");
    let future = T1 + 1000 * DAY;
    let gv = writes::import_drafts(
        &w.t(),
        w.p.col,
        &W::req(T1, json!({"logHlcs": true})),
        &[foreign_item("f9", &c21, N2, future, 1, 9)],
    )
    .unwrap();
    let derived = format!("{future}:0:fushi");
    assert!(
        w.log_hlcs(&c21).iter().all(|(_, h)| *h != derived),
        "{:?}",
        w.log_hlcs(&c21)
    );
    // `import_drafts` 不报 `logHlcs`（只有 `apply` 报）：回包这条路径的上界由下面
    // `a_foreign_log_from_the_future_is_not_derived_in_the_log_hlcs_reply` 钉。
    assert!(gv.get("logHlcs").is_none(), "{gv}");
    let mut native = foreign_item("n9", &c21, N2, T1 + DAY, 3, 11);
    native["e"]["x"]
        .as_object_mut()
        .unwrap()
        .remove("foreignLog");
    writes::apply(&w.t(), w.p.col, &W::req(T1 + DAY, json!({})), &[native]).unwrap();
    assert_eq!(w.cards_last_at("n9"), 1);
    assert_eq!(w.cards_last_at("f9"), 0);
}

/// `apply` 回包 `logHlcs` 这条路径（`cmd/writes.rs` 写下后读操作 HLC 再派生）同样守上界：发生时刻在未来的外来日志回的是
/// 载着它的操作 HLC、不是 `{at}:0:fushi`，并与随后 `read logs` 的 `hlc` 逐字相同（第六波；第五波复核只经 `import_drafts`
/// 测了投影，那条入口不报 `logHlcs`，回包的上界没有用例钉住）。
#[test]
fn a_foreign_log_from_the_future_is_not_derived_in_the_log_hlcs_reply() {
    let lib = library();
    let w = W::new(&lib);
    let c21 = card(N2, "t1");
    let future = T1 + 1000 * DAY;
    let gv = writes::apply(
        &w.t(),
        w.p.col,
        &W::req(T1, json!({"logHlcs": true})),
        &[foreign_item("f9", &c21, N2, future, 1, 9)],
    )
    .unwrap();
    let f9 = w.p.canon("f9");
    let replied = gv["logHlcs"].as_array().unwrap();
    assert_eq!(replied.len(), 1, "{gv}");
    assert_eq!(replied[0][1], json!(f9));
    let hlc = replied[0][2].as_str().unwrap().to_owned();
    assert_ne!(hlc, format!("{future}:0:fushi"));
    // 回落到操作 HLC：物理时刻不晚于这批写入的时刻（远早于伪造的发生时刻）。
    let wall: i64 = hlc.split(':').next().unwrap().parse().unwrap();
    assert!(wall < future, "{hlc}");
    let read: Vec<String> = w
        .log_hlcs(&c21)
        .into_iter()
        .filter(|(id, _)| *id == f9)
        .map(|(_, h)| h)
        .collect();
    assert_eq!(read, vec![hlc]);
}

// ---------------------------------------------------------------------- 写回包带修改行（K3，交接 §26 T1 (c)）

/// `editRows: true`：`edits` 里有输入下标的项、`tagWrites` 每项都带上收尾之后的修改行，与随后 `read edits` 的
/// `j` / `st` 逐字相同；同批后面的写入盖掉的那项行是 null、并明确标「被盖掉」（第五波），其余项标 false。不带这个键的
/// 回包形状不变。
#[test]
fn edit_rows_in_the_reply_are_what_read_edits_gives() {
    let lib = library();
    let w = W::new(&lib);
    let items = vec![
        draft("note", N1, "f/fa", json!("鯨")),
        draft("note", N1, "tags", json!(["z", "a"])),
        draft("note", N3, "f/fb", json!("dog C")),
        draft("note", N1, "f/fb", json!("whale 1")),
        draft("note", N1, "f/fb", json!("whale 2")),
    ];
    let gv = writes::apply(
        &w.t(),
        w.p.col,
        &W::req(T1, json!({"editRows": true})),
        &items,
    )
    .unwrap();
    let (_, f) =
        w.p.g4(json!({"q": "edits", "kind": "note", "ids": [N1, N3]}));
    let (_, read) = decode(&f[0].1);
    let read_j = |j: &str| read.iter().find(|r| r[1] == j).cloned();
    let edits = gv["edits"].as_array().unwrap();
    assert_eq!(edits.len(), 4, "{gv}");
    let mut live = 0;
    for e in edits {
        assert_eq!(e.as_array().unwrap().len(), 10, "{e}");
        if e[6] == json!(3) {
            // 被同批第 5 项盖掉：不是活着的行，明确标出来。
            assert_eq!(
                (&e[7], &e[8], &e[9]),
                (&Value::Null, &Value::Null, &json!(true)),
                "{e}"
            );
            continue;
        }
        assert_eq!(e[9], json!(false), "{e}");
        let j = e[7].as_str().unwrap();
        let row = read_j(j).unwrap_or_else(|| panic!("{j} not in read edits {read:?}"));
        let v: Value = serde_json::from_str(j).unwrap();
        assert_eq!((&v["w"], &v["s"]), (&e[3], &e[4]), "{e}");
        assert_eq!(
            row[2],
            e[8].as_i64().map_or("∅".to_owned(), |s| s.to_string())
        );
        live += 1;
    }
    assert_eq!(live, 3);
    let tags = gv["tagWrites"].as_array().unwrap();
    assert_eq!(tags.len(), 1, "{gv}");
    let j = tags[0][4].as_str().unwrap();
    assert_eq!(tags[0][5], json!(false), "{gv}");
    assert!(read_j(j).is_some(), "{j} not in read edits {read:?}");
    assert_eq!(
        serde_json::from_str::<Value>(j).unwrap()["f"],
        json!("tags")
    );
    // 不要修改行：形状照旧。
    let gv = writes::apply(
        &w.t(),
        w.p.col,
        &W::req(T1 + 1, json!({})),
        &[draft("note", N1, "f/fa", json!("鯱"))],
    )
    .unwrap();
    assert_eq!(gv["edits"][0].as_array().unwrap().len(), 7, "{gv}");
}

/// 同一批里同一条笔记整列表写两次标签：前一项明确标「被盖掉」、不给行（合成的 `tags` 行是后一次的结果），后一项带行；
/// 字段写两次同理。改前前一项的标签行是后一次的结果、字段行是 null 却不说明为什么（Dart `_writtenEdits` 抛错）。
#[test]
fn a_later_write_in_the_same_batch_marks_the_earlier_one_superseded() {
    let lib = library();
    let w = W::new(&lib);
    let items = vec![
        draft("note", N1, "tags", json!(["x"])),
        draft("note", N1, "f/fa", json!("一")),
        draft("note", N1, "tags", json!(["y", "x"])),
        draft("note", N1, "f/fa", json!("二")),
    ];
    let gv = writes::apply(
        &w.t(),
        w.p.col,
        &W::req(T1, json!({"editRows": true})),
        &items,
    )
    .unwrap();
    let tags = gv["tagWrites"].as_array().unwrap();
    assert_eq!(tags.len(), 2, "{gv}");
    assert_eq!(
        (&tags[0][0], &tags[0][4], &tags[0][5]),
        (&json!(0), &Value::Null, &json!(true))
    );
    assert_eq!((&tags[1][0], &tags[1][5]), (&json!(2), &json!(false)));
    let last: Value = serde_json::from_str(tags[1][4].as_str().unwrap()).unwrap();
    assert_eq!(last["f"], json!("tags"));
    let edits = gv["edits"].as_array().unwrap();
    let by_input = |i: i64| edits.iter().find(|e| e[6] == json!(i)).unwrap();
    assert_eq!(
        (&by_input(1)[7], &by_input(1)[9]),
        (&Value::Null, &json!(true))
    );
    assert!(by_input(3)[7].is_string(), "{gv}");
    assert_eq!(by_input(3)[9], json!(false));
}
