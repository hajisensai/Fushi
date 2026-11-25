//! 读命令的新代实现与协议 3 逐命令对拍（规划 §2.1 G7-4）：同一个协议 3 的库，协议 3 一侧跑 `store/reads.rs` 的原查询
//! （[crate::store::reads]），新代一侧把库灌进新代（`parity.rs` 的 `imported`：重建两遍相同、换到达方式逐条维护
//! 相同、与协议 3 投影对拍无差异）再跑 `cmd`。两侧结果按同一份规则归一（ID → 规范 ID，修改 / 日志行里的 ID 同样归一）后
//! 按多重集比——协议 3 大多数查询没有 `ORDER BY`；新代的顺序契约另测。
//!
//! 协议 3 一侧的缓存表先按同一份缓存配置在 SAVEPOINT 里重建、读完回滚（同 `parity.rs` `protocol_3_caches`：协议 3 自己
//! 欠着的收尾先做完）。
//!
//! 修改行的比法：(实体, 键, 写入者, seq, 值, `m`, HLC)。不比 `ctx`：协议 3 存的是作者写时的完整上下文，新代只回答「见没
//! 见过别的活着的写入」（`derive.rs` `edit_lines_as`，寄存器判据只用到这些），两者对判据等价（缓存层对拍钉住）。

use std::cell::RefCell;
use std::collections::BTreeSet;

use rusqlite::Connection;
use serde_json::{Value, json};

use super::history::history;
use super::views::entity_views;
use super::{Files, reads, snapshot};
use crate::store::gen4::cache::CFG_KEY;
use crate::store::gen4::derive::{Index, Ref};
use crate::store::gen4::parity::imported;
use crate::store::gen4::truth::Truth;
use crate::store::reads as p3_reads;
use crate::store::sync2::canonical;
use crate::store::sync2::config::default_deck_id;
use crate::store::sync2::tests::{Bucket, DAY, Device, P, deck_entity, edit, review};
use crate::sync2::id::Key;
use crate::sync2::op::EntKind;

pub(super) const T0: i64 = 1_700_000_000_000;
pub(super) const N1: &str = "0193a1b2-0000-7000-8000-0000000000a1";
pub(super) const N2: &str = "0193a1b2-0000-7000-8000-0000000000a2";
pub(super) const N3: &str = "0193a1b2-0000-7000-8000-0000000000a3";
pub(super) const N4: &str = "0193a1b2-0000-7000-8000-0000000000a4";
pub(super) const ANKI_AT: i64 = T0 - 1000;

// ---------------------------------------------------------------------- 列式表

/// 结果里的一格（`FCL1` 解码后统一成文本，空 = `∅`）。
pub(super) fn decode(b: &[u8]) -> (Vec<String>, Vec<Vec<String>>) {
    assert_eq!(&b[0..4], b"FCL1");
    let u32_at = |at: usize| u32::from_le_bytes(b[at..at + 4].try_into().unwrap()) as usize;
    let pad = |x: usize| (x + 7) & !7;
    let (rows, cols) = (u32_at(4), u32_at(8));
    let mut at = 16;
    let mut names = Vec::new();
    let mut data: Vec<Vec<String>> = vec![Vec::new(); rows];
    for _ in 0..cols {
        let n = u32_at(at);
        names.push(String::from_utf8(b[at + 4..at + 4 + n].to_vec()).unwrap());
        at = pad(at + 4 + n);
        let kind = u32_at(at);
        at += 8;
        let valid: Option<Vec<bool>> = if matches!(kind, 3 | 4 | 6) {
            let v = b[at..at + rows].iter().map(|x| *x != 0).collect();
            at = pad(at + rows);
            Some(v)
        } else {
            None
        };
        let has = |r: usize| valid.as_ref().is_none_or(|v| v[r]);
        match kind {
            1 | 3 => {
                for (r, row) in data.iter_mut().enumerate() {
                    let v = i64::from_le_bytes(b[at + r * 8..at + r * 8 + 8].try_into().unwrap());
                    row.push(if has(r) { v.to_string() } else { "∅".into() });
                }
                at += rows * 8;
            }
            2 | 4 => {
                for (r, row) in data.iter_mut().enumerate() {
                    let v = f64::from_le_bytes(b[at + r * 8..at + r * 8 + 8].try_into().unwrap());
                    row.push(if has(r) {
                        format!("{v:.6}")
                    } else {
                        "∅".into()
                    });
                }
                at += rows * 8;
            }
            _ => {
                let total = u64::from_le_bytes(b[at..at + 8].try_into().unwrap()) as usize;
                at += 8;
                let offs: Vec<usize> = (0..=rows).map(|r| u32_at(at + r * 4)).collect();
                at = pad(at + (rows + 1) * 4);
                for (r, row) in data.iter_mut().enumerate() {
                    let t = String::from_utf8(b[at + offs[r]..at + offs[r + 1]].to_vec()).unwrap();
                    row.push(if has(r) { t } else { "∅".into() });
                }
                at = pad(at + total);
            }
        }
    }
    (names, data)
}

// ---------------------------------------------------------------------- 场景

pub(super) fn fresh(name: &str) -> Device {
    let d = Device::new(name);
    d.core.sync2_identity(P, T0).unwrap();
    d.core.sync2_migrate(P, T0, None).unwrap();
    d
}

pub(super) fn note(id: &str, nt: &str, created: i64) -> Value {
    json!({"t": "entity", "x": {"id": id, "p": P, "k": "note", "d": {"createdAt": created, "guid": id, "noteTypeId": nt}}})
}

fn anki_review(id: &str, card: &str, at: i64) -> Value {
    json!({"t": "log", "x": {
        "id": id, "p": P, "card": card, "kind": "review", "rating": 3, "hlc": format!("{at}:0:anki"),
        "at": at, "ts": "wall", "origin": "anki", "ankiId": at, "rtype": "review", "dur": 5000, "utcOff": 0,
        "rollover": 4, "alg": "anki",
        "res": {"queue": "review", "ivl": 3, "step": 0, "reps": 1, "lapses": 0, "scheduler": "fushi", "dueDay": 1}
    }})
}

pub(super) fn card(note: &str, template: &str) -> String {
    crate::registers::card_id(note, template, 0).unwrap()
}

/// 一个够全的协议 3 库：两台设备、牌组 / 笔记类型（字段、模板、词条字段）、四条笔记（字段带样式块与链接、标签、
/// 删除）、并发改同一个字段（冲突）、评分与撤销、Anki 导入的复习、继承历史的后继卡。返回 a（两边同步完）。
pub(super) fn library() -> Device {
    library_pair().0
}

/// [library] 的两台设备与它们同步用的桶（两边都同步完）。
pub(super) fn library_pair() -> (Device, Device, Bucket) {
    let deck = default_deck_id(P);
    let (a, b) = (fresh("g4ra"), fresh("g4rb"));
    let mut bucket = Bucket::default();
    let fdef = |name: &str, ord: i64| json!({"name": name, "ord": ord});
    let tdef =
        |name: &str, ord: i64, front: &str| json!({"name": name, "ord": ord, "front": front});
    a.apply(
        T0,
        vec![
            deck_entity(&deck),
            json!({"t": "entity", "x": {"id": "NT", "p": P, "k": "notetype", "d": {"createdAt": 1, "ntKind": "standard"}}}),
            edit("notetype", "NT", "fieldDef/fa", fdef("Expression", 0)),
            edit("notetype", "NT", "fieldDef/fb", fdef("Meaning", 1)),
            edit("notetype", "NT", "tmplDef/t1", tdef("A", 0, "{{Expression}}")),
            edit("notetype", "NT", "tmplDef/t2", tdef("B", 1, "{{Meaning}}")),
            edit("notetype", "NT", "termField", json!("fa")),
            note(N1, "NT", 10),
            edit("note", N1, "f/fa", json!("猫")),
            edit("note", N1, "f/fb", json!("cat <style>.x{}</style>")),
            edit("note", N1, "tags", json!(["b", "a"])),
            note(N2, "NT", 20),
            edit("note", N2, "f/fa", json!("猫")),
            edit("note", N2, "f/fb", json!("<img src=\"neko.png\"> https://Example.com/x")),
            note(N3, "NT", 30),
            edit("note", N3, "f/fa", json!("犬")),
            note(N4, "NT", 40),
            edit("note", N4, "f/fa", json!("鳥")),
        ],
    );
    let (c1, c2) = (card(N1, "t1"), card(N1, "t2"));
    a.apply(T0 + 10, vec![review("r1", &c1, T0 + 10, 3, "learn")]);
    a.apply(T0 + DAY, vec![review("r2", &c1, T0 + DAY, 1, "review")]);
    a.apply(
        T0 + DAY + 10,
        vec![edit("card", &c2, &format!("historyFrom/{c1}"), json!(true))],
    );
    a.apply(
        T0 + DAY + 20,
        vec![edit("note", N4, "deleted", json!(T0 + DAY + 20))],
    );
    a.apply(
        T0 + DAY + 30,
        vec![anki_review("a1", &card(N3, "t1"), ANKI_AT)],
    );
    a.sync(&mut bucket, "loc", T0 + DAY + 40);
    b.sync(&mut bucket, "loc", T0 + DAY + 40);
    // 两台设备并发改同一个字段：冲突（两条都活着）。
    a.apply(
        T0 + DAY + 50,
        vec![edit("note", N3, "f/fb", json!("dog A"))],
    );
    b.apply(
        T0 + DAY + 51,
        vec![edit("note", N3, "f/fb", json!("dog B"))],
    );
    b.apply(
        T0 + DAY + 52,
        vec![review("r3", &card(N2, "t1"), T0 + DAY + 52, 3, "learn")],
    );
    for _ in 0..2 {
        a.sync(&mut bucket, "loc", T0 + DAY + 60);
        b.sync(&mut bucket, "loc", T0 + DAY + 60);
    }
    (a, b, bucket)
}

/// 协议 3 一侧：在 SAVEPOINT 里先做完欠着的收尾、按新代同一份配置重建缓存，跑 [f]，整个回滚。
pub(super) fn on_p3<T>(src: &Connection, cfg: &str, f: impl FnOnce(&Connection) -> T) -> T {
    let cfg =
        crate::store::caches::CacheConfig::parse(&serde_json::from_str(cfg).unwrap()).unwrap();
    src.execute_batch("SAVEPOINT g4reads").unwrap();
    crate::store::sync2::transport::replay_pending(
        src,
        P,
        &mut crate::store::sync2::transport::CommitBudget::unlimited(),
    )
    .unwrap();
    crate::store::caches::rebuild(src, P, &cfg).unwrap();
    let out = f(src);
    src.execute_batch("ROLLBACK TO g4reads; RELEASE g4reads")
        .unwrap();
    out
}

/// 一列怎么归一。
#[derive(Clone, Copy)]
pub(super) enum Norm {
    Plain,
    Id,
    /// 身份记录的数据（规范 JSON）。
    Payload,
    /// 修改行 JSON。
    Edit,
    /// 日志行 JSON。
    Log,
    /// 不比（协议 3 是本机收到的时刻 / 落库序号，有意不同，模块文件头）。
    Skip,
}

pub(super) struct Pair<'d> {
    pub(super) d: &'d Device,
    pub(super) g4: Connection,
    pub(super) col: i64,
    pub(super) cfg: String,
}

impl<'d> Pair<'d> {
    pub(super) fn new(d: &'d Device) -> Pair<'d> {
        let (g4, diff) = imported(d);
        assert!(diff.is_empty(), "{diff:?}");
        let t = Truth::new(&g4);
        let col = t.binding_of(P).unwrap().unwrap().col;
        let cfg = t.derive_cfg(col, CFG_KEY).unwrap().unwrap();
        Pair { d, g4, col, cfg }
    }

    pub(super) fn ix<T>(&self, f: impl FnOnce(&mut Index<'_, '_>) -> T) -> T {
        let t = Truth::new(&self.g4);
        let mut ix = Index::new(&t, self.col);
        f(&mut ix)
    }

    pub(super) fn canon(&self, s: &str) -> String {
        if s == "∅" {
            return s.to_owned();
        }
        self.ix(|ix| ix.canonical(&Ref::of(&Key::of(s))).unwrap().text())
    }

    pub(super) fn norm(&self, n: Norm, s: &str) -> String {
        match n {
            Norm::Plain => s.to_owned(),
            Norm::Skip => String::new(),
            Norm::Id => self.canon(s),
            Norm::Payload => self.ix(|ix| {
                canonical(
                    &ix.canonical_json(&serde_json::from_str(s).unwrap())
                        .unwrap(),
                )
            }),
            Norm::Edit => self.ix(|ix| {
                let v: Value = serde_json::from_str(s).unwrap();
                let f = ix.canonical_key(v["f"].as_str().unwrap()).unwrap();
                let val = ix.canonical_value(&f, &v["v"]).unwrap();
                let e = ix
                    .canonical(&Ref::of(&Key::of(v["e"].as_str().unwrap())))
                    .unwrap()
                    .text();
                canonical(&json!([
                    v["p"],
                    v["k"],
                    e,
                    f,
                    v["w"],
                    v["s"],
                    val,
                    v.get("m"),
                    v["hlc"]
                ]))
            }),
            Norm::Log => self.ix(|ix| {
                let v: Value = serde_json::from_str(s).unwrap();
                canonical(&ix.canonical_json(&v).unwrap())
            }),
        }
    }

    pub(super) fn p3(&self, req: Value) -> (Value, Files) {
        let w = self.d.core.writer().unwrap();
        on_p3(&w, &self.cfg, |c| {
            let mut files = Files::new();
            let v = p3_reads::run(c, P, &req, &mut files).unwrap();
            (v, files)
        })
    }

    fn p3_lib(&self, req: Value) -> (Value, Files) {
        let w = self.d.core.writer().unwrap();
        on_p3(&w, &self.cfg, |c| {
            let mut files = Files::new();
            let v = p3_reads::run_lib(c, &req, &mut files).unwrap();
            (v, files)
        })
    }

    pub(super) fn g4(&self, req: Value) -> (Value, Files) {
        let t = Truth::new(&self.g4);
        let mut files = Files::new();
        let v = reads::run(&t, self.col, &req, &mut files).unwrap();
        assert!(self.g4.is_autocommit(), "a read leaves no transaction open");
        (v, files)
    }

    fn g4_lib(&self, req: Value) -> (Value, Files) {
        let t = Truth::new(&self.g4);
        let mut files = Files::new();
        let v = reads::run_lib(&t, &req, &mut files).unwrap();
        (v, files)
    }

    /// 一张表归一成行的多重集（列按 [norms]，列名两侧必须相同）。
    pub(super) fn rows(&self, files: &Files, name: &str, norms: &[Norm]) -> Vec<Vec<String>> {
        let (_, bytes) = files.iter().find(|(n, _)| n == name).unwrap();
        let (cols, data) = decode(bytes);
        assert_eq!(cols.len(), norms.len(), "{cols:?}");
        let mut out: Vec<Vec<String>> = data
            .into_iter()
            .map(|r| r.iter().zip(norms).map(|(c, n)| self.norm(*n, c)).collect())
            .collect();
        out.sort();
        out
    }

    pub(super) fn names(files: &Files, name: &str) -> Vec<String> {
        let (_, bytes) = files.iter().find(|(n, _)| n == name).unwrap();
        decode(bytes).0
    }

    /// 一条 `read` 两侧对拍：JSON 回包相同，每张表的列名相同、归一后的行相同。返回新代一侧的行（未归一）。
    pub(super) fn same(&self, req: Value, tables: &[(&str, &[Norm])]) -> Vec<Vec<String>> {
        let (pv, pf) = self.p3(req.clone());
        let (gv, gf) = self.g4(req.clone());
        assert_eq!(pv, gv, "{req}");
        let mut first = Vec::new();
        for (i, (name, norms)) in tables.iter().enumerate() {
            assert_eq!(
                Self::names(&pf, name),
                Self::names(&gf, name),
                "{req} {name}"
            );
            let (p, g) = (self.rows(&pf, name, norms), self.rows(&gf, name, norms));
            if p != g {
                let only = |a: &[Vec<String>], b: &[Vec<String>]| -> Vec<Vec<String>> {
                    a.iter().filter(|r| !b.contains(r)).cloned().collect()
                };
                panic!(
                    "{req} {name}: {} vs {} rows
 only protocol 3: {:?}
 only gen4: {:?}",
                    p.len(),
                    g.len(),
                    only(&p, &g),
                    only(&g, &p)
                );
            }
            if i == 0 {
                first = decode(&gf.iter().find(|(n, _)| n == name).unwrap().1).1;
            }
        }
        first
    }
}

use Norm::{Edit, Id, Log, Payload, Plain, Skip};

// ---------------------------------------------------------------------- 对拍

#[test]
fn identity_records_and_counts_match_protocol_3() {
    let lib = library();
    let p = Pair::new(&lib);
    let ent: &[Norm] = &[Id, Plain, Payload];
    p.same(json!({"q": "entities"}), &[("t", ent)]);
    p.same(json!({"q": "entities", "kind": "note"}), &[("t", ent)]);
    p.same(json!({"q": "entities", "kind": "nonsense"}), &[("t", ent)]);
    p.same(
        json!({"q": "entities", "ids": [N1, N3, "missing"], "ordered": true}),
        &[("t", ent)],
    );
    p.same(
        json!({"q": "entities", "kind": "deck", "bare": true}),
        &[("t", &[Id])],
    );
    for req in [
        json!({"q": "entity_count"}),
        json!({"q": "entity_count", "kind": "note"}),
        json!({"q": "entity_count", "kind": "note", "limit": 2}),
        json!({"q": "pending_notes"}),
    ] {
        p.same(req, &[]);
    }
    let rows = p.same(json!({"q": "entities"}), &[("t", ent)]);
    assert!(rows.len() >= 6, "{rows:?}");
    // 只有内置实体的库：没有用户数据；有笔记的库：有。
    let deck = default_deck_id(P);
    p.same(json!({"q": "has_user_data", "builtins": [deck]}), &[]);
    let (v, _) = p.g4(json!({"q": "has_user_data", "builtins": [deck]}));
    assert_eq!(v, json!({"any": true}));
    let empty = fresh("g4rempty");
    empty.apply(T0, vec![deck_entity(&deck)]);
    let e = Pair::new(&empty);
    e.same(json!({"q": "has_user_data", "builtins": [deck]}), &[]);
    let (v, _) = e.g4(json!({"q": "has_user_data", "builtins": [deck]}));
    assert_eq!(v, json!({"any": false}));
}

#[test]
fn edits_conflicts_and_field_scans_match_protocol_3() {
    let lib = library();
    let p = Pair::new(&lib);
    let ed: &[Norm] = &[Id, Edit, Skip];
    p.same(
        json!({"q": "edits", "kind": "note", "ids": [N1, N2, N3, N4]}),
        &[("t", ed)],
    );
    p.same(
        json!({"q": "edits", "kind": "note", "ids": [N3], "key": "f/fb"}),
        &[("t", ed)],
    );
    p.same(
        json!({"q": "edits", "kind": "note", "ids": [N1, N2], "prefix": "f/"}),
        &[("t", ed)],
    );
    p.same(
        json!({"q": "edits", "kind": "notetype", "ids": ["NT"]}),
        &[("t", ed)],
    );
    p.same(json!({"q": "successors"}), &[("t", &[Id, Plain])]);
    let conflict: &[Norm] = &[Plain, Id, Plain, Edit, Skip];
    let rows = p.same(
        json!({"q": "conflict_edits", "rules": [{"kind": "note", "drop": []}]}),
        &[("t", conflict)],
    );
    assert_eq!(rows.len(), 2, "the concurrent f/fb writes on N3: {rows:?}");
    p.same(
        json!({"q": "conflict_edits", "rules": [{"kind": "note", "keep": ["f/fa"]}]}),
        &[("t", conflict)],
    );
    p.same(
        json!({"q": "conflict_edits", "rules": [{"kind": "note", "drop": []}], "kind": "note", "id": N3}),
        &[("t", conflict)],
    );
    p.same(
        json!({"q": "conflict_edits", "rules": [{"kind": "note", "drop": []}], "kind": "note", "id": N1}),
        &[("t", conflict)],
    );
    let rows = p.same(
        json!({"q": "source_note_candidates", "needle": "example.com"}),
        &[("t", &[Id])],
    );
    assert_eq!(
        rows,
        vec![vec![N2.to_owned()]],
        "ASCII case-insensitive like LIKE"
    );
    p.same(
        json!({"q": "lapis_backfill", "pairs": [["f/fa", "f/fb"]], "to": "NT"}),
        &[("t", &[Id])],
    );
    p.same(
        json!({"q": "lapis_backfill", "pairs": [["f/fa", "f/fb"]], "notes": [N1, N4]}),
        &[("t", &[Id])],
    );
    // 样式块：游标只当游标用（新代是操作主键），比 (修改记录 ID, 行)。
    let rows = p.same(
        json!({"q": "style_candidates", "after": 0, "limit": 100}),
        &[("t", &[Skip, Id, Edit])],
    );
    assert_eq!(rows.len(), 1);
    let rid: i64 = rows[0][0].parse().unwrap();
    let (_, f) = p.g4(json!({"q": "style_candidates", "after": rid, "limit": 100}));
    assert!(
        decode(&f[0].1).1.is_empty(),
        "the cursor moves past the hit"
    );
    let (_, f) = p.g4(json!({"q": "style_candidates", "after": 0, "limit": 0}));
    assert!(decode(&f[0].1).1.is_empty(), "limit 0 gives nothing");
}

#[test]
fn logs_stats_and_server_times_match_protocol_3() {
    let lib = library();
    let p = Pair::new(&lib);
    let (c1, c2) = (card(N1, "t1"), card(N1, "t2"));
    p.same(
        json!({"q": "logs", "cards": [c1, c2, card(N3, "t1"), card(N2, "t1")]}),
        // oid：新代的别名归一前排序 ID（BUG-5455），协议 3 没有别名、恒为空。
        &[("t", &[Id, Id, Log, Skip, Skip])],
    );
    p.same(
        json!({"q": "anki_logs_at", "at": [ANKI_AT, 5]}),
        &[("t", &[Id, Plain, Plain, Plain, Plain, Id, Plain])],
    );
    p.same(
        json!({"q": "native_logs_near", "at": [T0 + 10, T0 + DAY + 52], "win": 100}),
        &[("t", &[Id, Log])],
    );
    p.same(
        json!({"q": "today_reviews", "from": T0, "to": T0 + 2 * DAY}),
        &[],
    );
    p.same(
        json!({"q": "review_grid", "resetMs": 4 * 3_600_000}),
        &[("t", &[Plain, Plain, Plain, Plain])],
    );
    // 服务器时刻：只有承袭来的事件有（这个库全是协议 3 上原生写的，新代一侧为空）；两侧比「新代给出的都对」。
    let (_, gf) = p.g4(json!({"q": "server_times"}));
    let (_, pf) = p.p3(json!({"q": "server_times"}));
    let g = p.rows(&gf, "t", &[Id, Plain]);
    let pr = p.rows(&pf, "t", &[Id, Plain]);
    assert!(g.iter().all(|r| pr.contains(r)), "{g:?} ⊄ {pr:?}");
}

/// `reviewed_decks`（每日上限单位的存量牌组判据）：两侧相同；从 Anki 导入的复习（日志 ID 是 UUIDv5）不算，本机作答
/// （UUIDv7）算——新导入的 Anki 历史不该让牌组收到「以前按卡片数计」的提醒（拍板台 left3551）。
#[test]
fn reviewed_decks_skip_anki_imports_and_match_protocol_3() {
    let deck = default_deck_id(P);
    let d = fresh("g4rd");
    d.apply(
        T0,
        vec![
            deck_entity(&deck),
            json!({"t": "entity", "x": {"id": "NT", "p": P, "k": "notetype", "d": {"createdAt": 1, "ntKind": "standard"}}}),
            edit("notetype", "NT", "fieldDef/fa", json!({"name": "Expression", "ord": 0})),
            edit("notetype", "NT", "tmplDef/t1", json!({"name": "A", "ord": 0, "front": "{{Expression}}"})),
            note(N1, "NT", 10),
            edit("note", N1, "f/fa", json!("猫")),
            note(N2, "NT", 20),
            edit("note", N2, "f/fa", json!("犬")),
        ],
    );
    let anki_log = "0193a1b2-0000-5000-8000-0000000000f1";
    let native_log = "0193a1b2-0000-7000-8000-0000000000f2";
    d.apply(
        T0 + 5,
        vec![anki_review(anki_log, &card(N2, "t1"), ANKI_AT)],
    );
    d.apply(
        T0 + 10,
        vec![review(native_log, &card(N1, "t1"), T0 + 10, 3, "learn")],
    );
    let p = Pair::new(&d);
    let decks = |before: i64| {
        let req = json!({"q": "reviewed_decks", "before": before});
        p.same(req.clone(), &[]);
        p.g4(req).0["decks"].clone()
    };
    assert_eq!(decks(T0), json!([]), "只有 Anki 导入的复习在这之前");
    assert_eq!(decks(T0 + DAY), json!([p.canon(&deck)]), "本机作答算");
}

#[test]
fn cache_backed_queries_match_protocol_3() {
    let lib = library();
    let p = Pair::new(&lib);
    let card_cols: Vec<Norm> = crate::store::bulk::CARD_COLUMNS
        .iter()
        .map(|(n, _)| match *n {
            "id" | "note_id" | "template_id" | "deck_id" | "last_log_id" => Id,
            _ => Plain,
        })
        .collect();
    p.same(json!({"q": "cards"}), &[("t", &card_cols)]);
    p.same(
        json!({"q": "cards", "notes": [N1], "ordered": true}),
        &[("t", &card_cols)],
    );
    p.same(
        json!({"q": "cards", "visibleOnly": true, "queue": "new", "studyableOn": 19_700}),
        &[("t", &card_cols)],
    );
    p.same(
        json!({"q": "cards", "ids": [card(N1, "t1")], "fields": ["id", "reps", "last_log_id"]}),
        &[("t", &[Id, Plain, Id])],
    );
    p.same(
        json!({"q": "cards", "decks": [default_deck_id(P)], "templates": ["t2"], "fields": ["id"]}),
        &[("t", &[Id])],
    );
    let note_cols: &[Norm] = &[
        Id, Id, Plain, Plain, Id, Plain, Plain, Plain, Plain, Plain, Plain, Skip, Plain,
    ];
    p.same(json!({"q": "notes"}), &[("t", note_cols)]);
    p.same(
        json!({"q": "notes", "typeId": "NT", "alive": true, "order": "created_desc"}),
        &[("t", note_cols)],
    );
    p.same(
        json!({"q": "notes", "ids": [N2, N4], "fields": ["id", "deleted_at"]}),
        &[("t", &[Id, Plain])],
    );
    p.same(json!({"q": "note_type_counts"}), &[("t", &[Id, Plain])]);
    for req in [
        json!({"q": "media_refs"}),
        json!({"q": "media_refs", "deletedAfter": T0}),
        json!({"q": "media_refs", "deletedBefore": T0 + 2 * DAY}),
    ] {
        p.same(req, &[("t", &[Plain])]);
    }
    let rows = p.same(
        json!({"q": "term_status", "terms": ["猫", "鳥", "犬"]}),
        &[("t", &[Plain, Plain, Id, Id, Plain, Plain, Id, Plain, Plain])],
    );
    assert!(rows.len() >= 4, "{rows:?}");
    let rows = p.same(
        json!({"q": "dup_groups"}),
        &[("t", &[Id, Id, Plain, Plain, Plain, Plain, Plain])],
    );
    assert_eq!(rows.len(), 2, "N1 and N2 share 猫: {rows:?}");
    // `notes` 的分页：新代平局按 ID，结果是协议 3 的一种合法顺序；这里只比取到的集合。
    let (_, gf) = p.g4(
        json!({"q": "notes", "order": "created_asc", "limit": 2, "offset": 1, "fields": ["id"]}),
    );
    assert_eq!(
        decode(&gf[0].1).1,
        vec![vec![N2.to_owned()], vec![N3.to_owned()]]
    );
}

#[test]
fn whole_event_reads_match_protocol_3() {
    let lib = library();
    let p = Pair::new(&lib);
    p.same(
        json!({"q": "events", "ordered": true}),
        &[
            ("entities", &[Id, Plain, Payload]),
            ("edits", &[Edit]),
            ("logs", &[Log]),
            ("unknown", &[Plain]),
        ],
    );
    p.same(
        json!({"q": "events", "parts": ["logs"]}),
        &[("logs", &[Log])],
    );
    let (_, gf) = p.g4(json!({"q": "events", "parts": ["logs"]}));
    assert_eq!(gf.len(), 1, "parts limits the tables");
    // 事件 ID：身份记录、日志、修改记录（活着的）、不存在的。
    let edit_id = crate::registers::edit_id("dart", 1);
    let live_edit = {
        let (_, f) = p.p3(json!({"q": "style_candidates", "after": 0, "limit": 1}));
        decode(&f[0].1).1[0][1].clone()
    };
    // 比集合：协议 3 按来源表 UNION ALL，一个 ID 在投影表与操作表各命中一次就出两行；新代每个 ID 一行（读者只当集合用）。
    for ops in [false, true] {
        let req = json!({"q": "events_present", "ids": [N1, "r1", "a1", live_edit, edit_id, "nope", N1], "ops": ops});
        let (_, pf) = p.p3(req.clone());
        let (_, gf) = p.g4(req.clone());
        let mut want = p.rows(&pf, "t", &[Id]);
        want.dedup();
        let got = p.rows(&gf, "t", &[Id]);
        assert_eq!(want, got, "{req}");
        assert!(got.len() >= 4, "{req}: {got:?}");
    }
    for q in ["user_note_count", "profile_merges", "entity_owners"] {
        let req = json!({"q": q});
        let (pv, pf) = p.p3_lib(req.clone());
        let (gv, gf) = p.g4_lib(req);
        assert_eq!(pv, gv, "{q}");
        if !pf.is_empty() {
            assert_eq!(decode(&pf[0].1), decode(&gf[0].1), "{q}");
        }
    }
}

#[test]
fn unknown_queries_and_bad_parameters_fail_without_leaving_a_transaction() {
    let lib = library();
    let p = Pair::new(&lib);
    let t = Truth::new(&p.g4);
    for req in [
        json!({"q": "nonsense"}),
        json!({}),
        json!({"q": "edits", "kind": "note"}),
        json!({"q": "edits", "kind": "bogus", "ids": []}),
        json!({"q": "edits", "kind": "note", "ids": [N1], "prefix": ""}),
        json!({"q": "cards", "ids": "not-an-array"}),
        json!({"q": "cards", "ids": [1]}),
        json!({"q": "cards", "fields": ["nope"]}),
        json!({"q": "notes", "order": "sideways"}),
        json!({"q": "media_refs", "deletedBefore": 1, "deletedAfter": 2}),
        json!({"q": "conflict_edits", "rules": [{"kind": "note"}]}),
        json!({"q": "conflict_edits", "rules": [], "kind": "note"}),
    ] {
        let mut files = Files::new();
        assert!(reads::run(&t, p.col, &req, &mut files).is_err(), "{req}");
        assert!(p.g4.is_autocommit(), "{req} left a transaction open");
    }
    let mut files = Files::new();
    assert!(reads::run_lib(&t, &json!({"q": "nonsense"}), &mut files).is_err());
    // 没绑定的集合号是调用方的 bug。
    assert!(reads::run(&t, 999, &json!({"q": "pending_notes"}), &mut files).is_err());
}

// ---------------------------------------------------------------------- 顺序契约

/// 一个 ID 文本在 SQLite `ORDER BY id`（存储形）里的位置：TEXT 在 BLOB 前，各自按字节。
fn sql_key(s: &str) -> (u8, Vec<u8>) {
    match Key::of(s) {
        Key::Text(t) => (0, t.into_bytes()),
        Key::Uuid(id) => (1, id.0.to_vec()),
    }
}

#[test]
fn results_come_in_a_content_only_order() {
    let lib = library();
    let p = Pair::new(&lib);
    // 卡、笔记、实体：按 ID 的 SQLite 序（TEXT 在 BLOB 前）——与重放次数、到达顺序无关。
    let ids = |req: Value| -> Vec<String> {
        let (_, f) = p.g4(req);
        decode(&f[0].1)
            .1
            .into_iter()
            .map(|r| r[0].clone())
            .collect()
    };
    for req in [
        json!({"q": "entities", "bare": true}),
        json!({"q": "cards", "fields": ["id"]}),
        json!({"q": "notes", "fields": ["id"]}),
    ] {
        let got = ids(req.clone());
        let mut sorted = got.clone();
        sorted.sort_by_key(|s| sql_key(s));
        assert_eq!(got, sorted, "{req}");
        assert!(got.len() >= 4, "{req}: {got:?}");
    }
    let ents = ids(json!({"q": "entities", "bare": true}));
    assert!(
        matches!(Key::of(&ents[0]), Key::Text(_)),
        "TEXT sorts before BLOB: {ents:?}"
    );
    // 同一条命令跑两遍逐字节相同。
    for req in [
        json!({"q": "edits", "kind": "note", "ids": [N3, N1]}),
        json!({"q": "events"}),
        json!({"q": "conflict_edits", "rules": [{"kind": "note", "drop": []}]}),
    ] {
        assert_eq!(p.g4(req.clone()).1, p.g4(req).1);
    }
    // 修改：实体按 ID 序、同一实体按 (键, JSON)。
    let (_, f) = p.g4(json!({"q": "edits", "kind": "note", "ids": [N3, N1]}));
    let rows = decode(&f[0].1).1;
    let keys: Vec<(String, String)> = rows
        .iter()
        .map(|r| {
            let v: Value = serde_json::from_str(&r[1]).unwrap();
            (r[0].clone(), v["f"].as_str().unwrap().to_owned())
        })
        .collect();
    let mut sorted = keys.clone();
    sorted.sort_by_key(|(e, f)| (sql_key(e), f.clone()));
    assert_eq!(keys, sorted);
    assert_eq!(keys.first().map(|k| k.0.as_str()), Some(N1));
}

// ---------------------------------------------------------------------- 读快照

/// 一条命令一个读快照：命令跑到一半另一个连接提交了写入，这条命令读到的仍是开始时的样子；下一条命令看得到新数据
/// （开头 `Truth::reset`，不拿上一次的缓存）。
#[test]
fn one_command_reads_one_snapshot_and_the_next_sees_new_commits() {
    let d = library();
    let (mem, diff) = imported(&d);
    assert!(diff.is_empty(), "{diff:?}");
    let dir = crate::store::sync2::tests::tempdir::new("g4rsnap");
    let path = dir.0.join("srs4.db");
    mem.execute("VACUUM INTO ?1", [path.to_str().unwrap()])
        .unwrap();
    let reader = crate::store::gen4::schema::open(&path).unwrap();
    let writer = crate::store::gen4::schema::open(&path).unwrap();
    let t = Truth::new(&reader);
    let col = t.binding_of(P).unwrap().unwrap().col;
    let count = |t: &Truth<'_>| -> i64 {
        let mut files = Files::new();
        reads::run(
            t,
            col,
            &json!({"q": "entity_count", "kind": "note"}),
            &mut files,
        )
        .unwrap()["n"]
            .as_i64()
            .unwrap()
    };
    let before = count(&t);
    let (a, b) = snapshot(&t, |t| {
        let a = count(t);
        writer
            .execute(
                "DELETE FROM ent_ix WHERE col = ?1 AND kind = ?2",
                [col, EntKind::Note as i64],
            )
            .unwrap();
        Ok((a, count(t)))
    })
    .unwrap();
    assert_eq!((a, b), (before, before), "inside one snapshot");
    assert!(reader.is_autocommit());
    assert_eq!(count(&t), 0, "the next command sees the commit");
    // 调用方自己开的事务：沿用它，不另开、不提交。
    reader.execute_batch("BEGIN").unwrap();
    assert_eq!(count(&t), 0);
    assert!(
        !reader.is_autocommit(),
        "the caller's transaction is left to the caller"
    );
    reader.execute_batch("ROLLBACK").unwrap();
}

// ---------------------------------------------------------------------- 计划

thread_local! {
    static TRACED: RefCell<Vec<String>> = const { RefCell::new(Vec::new()) };
}

/// 热路径（按 ID / 词条 / 时刻取）的语句计划里没有整集合扫描：跑真命令、截下实际执行的语句（参数已展开）逐条
/// `EXPLAIN QUERY PLAN`。
#[test]
#[allow(deprecated)]
fn keyed_reads_never_walk_the_whole_collection() {
    let d = library();
    let (mut g4, _) = imported(&d);
    let col = Truth::new(&g4).binding_of(P).unwrap().unwrap().col;
    g4.trace(Some(|sql: &str| {
        TRACED.with(|t| t.borrow_mut().push(sql.to_owned()));
    }));
    let c1 = card(N1, "t1");
    for req in [
        json!({"q": "term_status", "terms": ["猫"]}),
        json!({"q": "notes", "typeId": "NT", "alive": true}),
        json!({"q": "notes", "ids": [N1]}),
        json!({"q": "cards", "notes": [N1]}),
        json!({"q": "cards", "ids": [c1]}),
        json!({"q": "cards", "decks": [default_deck_id(P)]}),
        json!({"q": "cards", "templates": ["t1"]}),
        json!({"q": "cards", "decks": [default_deck_id(P)], "templates": ["t1"], "visibleOnly": true}),
        json!({"q": "cards", "notes": [N1], "decks": [default_deck_id(P)]}),
        json!({"q": "pending_notes"}),
        json!({"q": "edits", "kind": "note", "ids": [N1]}),
        json!({"q": "logs", "cards": [c1]}),
        json!({"q": "entities", "ids": [N1]}),
        json!({"q": "anki_logs_at", "at": [ANKI_AT]}),
        json!({"q": "native_logs_near", "at": [T0], "win": 10}),
        json!({"q": "successors"}),
        json!({"q": "today_reviews", "from": T0, "to": T0 + DAY}),
        // 按种类数到 `limit` 就停：走 `ent_kind (col, kind, id)`，不沿主键把别的种类的身份记录也走一遍。
        json!({"q": "entity_count", "kind": "note", "limit": 1}),
    ] {
        TRACED.with(|t| t.borrow_mut().clear());
        {
            let t = Truth::new(&g4);
            let mut files = Files::new();
            reads::run(&t, col, &req, &mut files).unwrap();
        }
        let stmts: BTreeSet<String> = TRACED.with(|t| t.borrow().iter().cloned().collect());
        let mut bad = Vec::new();
        for q in stmts {
            let up = q.trim_start().to_ascii_uppercase();
            if !up.starts_with("SELECT") && !up.starts_with("WITH") {
                continue;
            }
            let mut stmt = g4.prepare(&format!("EXPLAIN QUERY PLAN {q}")).unwrap();
            let mut rows = stmt.raw_query();
            while let Some(r) = rows.next().unwrap() {
                let step: String = r.get(3).unwrap();
                let whole = step.starts_with("SCAN ")
                    && !step.contains("CONSTANT")
                    && !step.contains("json_each")
                    && !step.starts_with("SCAN t ")
                    && step != "SCAN t";
                // 部分索引（`notes_pending`）只含待决的行，按 `col` 查就是按键查；`closure_ix` / `alias_writer_ix` 一台设备 / 一个
                // 写入者一行（量级 = 设备数），整集合读一次是标签 OR-Set 判定的固定开销，不随实体数长。
                let partial = step.contains("notes_pending")
                    || step.starts_with("SEARCH closure_ix ")
                    || step.starts_with("SEARCH alias_writer_ix ");
                if whole || !partial && step.starts_with("SEARCH ") && step.ends_with("(col=?)") {
                    bad.push(format!("{q}\n    {step}"));
                }
            }
        }
        assert!(bad.is_empty(), "{req}:\n{}", bad.join("\n"));
    }
    g4.trace(None);
}

// ---------------------------------------------------------------------- entity_views

#[test]
fn entity_views_carry_what_the_reads_give_and_one_class_once() {
    let lib = library();
    let p = Pair::new(&lib);
    let t = Truth::new(&p.g4);
    let c1 = card(N1, "t1");
    let views = entity_views(
        &t,
        p.col,
        EntKind::Note,
        &[
            N1.to_owned(),
            "missing".to_owned(),
            N1.to_owned(),
            N4.to_owned(),
        ],
    )
    .unwrap();
    assert_eq!(
        views.iter().map(|v| v.id.as_str()).collect::<Vec<_>>(),
        vec![N1, N4],
        "missing entities drop out, a class shows up once, in request order"
    );
    let v: Value = serde_json::from_str(&views[0].json).unwrap();
    assert_eq!(views[0].json, canonical(&v), "the view is canonical JSON");
    assert_eq!(v["k"], "note");
    assert_eq!(v["d"]["noteTypeId"], "NT");
    assert_eq!(v["tags"], json!(["b", "a"]));
    assert_eq!(v["row"]["id"], N1);
    assert_eq!(v["row"]["tags_json"], "[\"b\",\"a\"]");
    // edits 与 `read` 的 `edits` 逐字相同。
    let (_, f) = p.g4(json!({"q": "edits", "kind": "note", "ids": [N1]}));
    let want: Vec<Value> = decode(&f[0].1)
        .1
        .into_iter()
        .map(|r| {
            json!([
                r[1],
                if r[2] == "∅" {
                    Value::Null
                } else {
                    json!(r[2].parse::<i64>().unwrap())
                }
            ])
        })
        .collect();
    assert_eq!(v["edits"], Value::Array(want));
    // 卡：日志与 `read` 的 `logs` 逐字相同。
    let cv = entity_views(&t, p.col, EntKind::Card, std::slice::from_ref(&c1)).unwrap();
    let cv: Value = serde_json::from_str(&cv[0].json).unwrap();
    let (_, f) = p.g4(json!({"q": "logs", "cards": [c1]}));
    let logs: Vec<String> = decode(&f[0].1)
        .1
        .into_iter()
        .map(|r| r[2].clone())
        .collect();
    assert_eq!(
        cv["logs"]
            .as_array()
            .unwrap()
            .iter()
            .map(|l| l[0].as_str().unwrap().to_owned())
            .collect::<Vec<_>>(),
        logs
    );
    assert_eq!(cv["row"]["note_id"], N1);
    assert!(cv.get("tags").is_none());
    // 删除的笔记照样有视图（行里带删除时刻）。
    let d: Value = serde_json::from_str(&views[1].json).unwrap();
    assert!(d["row"]["deleted_at"].is_i64());
}

/// tag 跟着视图走：缓存配置变了（语义摘要 `dg_ix` 不变）视图里的行变了，tag 必变；什么都没变 tag 不变。
#[test]
fn a_view_tag_moves_with_the_view_not_with_the_digest() {
    let lib = library();
    let p = Pair::new(&lib);
    let t = Truth::new(&p.g4);
    let c1 = card(N1, "t1");
    let tag =
        || entity_views(&t, p.col, EntKind::Card, std::slice::from_ref(&c1)).unwrap()[0].clone();
    let before = tag();
    assert_eq!(before, tag(), "stable when nothing changed");
    assert_eq!(before.tag.len(), 32);
    let digest = |t: &Truth<'_>| -> Vec<Vec<u8>> {
        t.conn()
            .prepare("SELECT sum FROM dg_ix ORDER BY ekind, ent")
            .unwrap()
            .query_map([], |r| r.get(0))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap()
    };
    let dg = digest(&t);
    // 换一个默认牌组：没指定牌组的卡，卡行的 deck 列变了，操作没变。
    let cfg = json!({"defaultDeck": "0193a1b2-0000-7000-8000-0000000000d9"}).to_string();
    t.tx(|t| {
        t.set_derive_cfg(p.col, CFG_KEY, Some(&cfg))?;
        Index::new(t, p.col).rebuild_caches().map(|_| ())
    })
    .unwrap();
    assert_eq!(
        dg,
        digest(&t),
        "the semantic digest does not see host config"
    );
    let after = tag();
    assert_ne!(before.json, after.json);
    assert_ne!(before.tag, after.tag);
}

// ---------------------------------------------------------------------- 修改历史

/// 修改历史与协议 3 `sync2_history` 对拍（按多重集；键、值里的 ID 归一）：字段修改（含被并发覆盖的）、标签操作、
/// 后继卡的继承链接。时间新的在前。
#[test]
fn history_matches_protocol_3() {
    let d = library();
    let p = Pair::new(&d);
    let t = Truth::new(&p.g4);
    let norm = |v: &Value| -> Vec<String> {
        let mut out: Vec<String> = v
            .as_array()
            .unwrap()
            .iter()
            .map(|e| {
                let mut e = e.clone();
                let key = p.ix(|ix| ix.canonical_key(e["key"].as_str().unwrap()).unwrap());
                if let Some(val) = e.get("value").cloned() {
                    e["value"] = p.ix(|ix| ix.canonical_value(&key, &val).unwrap());
                }
                e["key"] = json!(key);
                canonical(&e)
            })
            .collect();
        out.sort();
        out
    };
    let mut checked = 0;
    for (kind, ent) in [
        (EntKind::Note, N1.to_owned()),
        (EntKind::Note, N3.to_owned()),
        (EntKind::Note, N4.to_owned()),
        (EntKind::NoteType, "NT".to_owned()),
        (EntKind::Card, card(N1, "t2")),
        (EntKind::Deck, default_deck_id(P)),
        (EntKind::Note, "missing".to_owned()),
    ] {
        let old = d.core.sync2_history(P, kind.wire(), &ent).unwrap();
        let new = history(&t, p.col, kind, &ent).unwrap();
        assert_eq!(norm(&old), norm(&new), "{} {ent}", kind.wire());
        // 新的在前。
        let at: Vec<i64> = new
            .as_array()
            .unwrap()
            .iter()
            .map(|e| e["at"].as_i64().unwrap())
            .collect();
        assert!(at.windows(2).all(|w| w[0] >= w[1]), "{at:?}");
        checked += new.as_array().unwrap().len();
    }
    assert!(checked >= 10, "{checked}");
    assert!(p.g4.is_autocommit());
}

/// 清除之后（派生层标了已清除、还没落成空洞）：报 `purged`、不报内容，同协议 3；落成空洞之后不再出现（模块文件头）。
#[test]
fn purged_writes_show_as_purged_until_they_become_holes() {
    let d = library();
    d.core.sync2_purge(P, "note", N3, T0 + 3 * DAY).unwrap();
    let p = Pair::new(&d);
    let t = Truth::new(&p.g4);
    let new = history(&t, p.col, EntKind::Note, N3).unwrap();
    let purged: Vec<&Value> = new
        .as_array()
        .unwrap()
        .iter()
        .filter(|e| e["purged"] == json!(true))
        .collect();
    let old = d.core.sync2_history(P, "note", N3).unwrap();
    let old_purged = old
        .as_array()
        .unwrap()
        .iter()
        .filter(|e| e["purged"] == json!(true))
        .count();
    assert!(
        new.as_array()
            .unwrap()
            .iter()
            .all(|e| e.get("value").is_none() || e["key"] == "deleted"),
        "no content after a purge: {new}"
    );
    // 协议 3 的骨架在灌入时不过界（空洞）：新代报的已清除项不多于协议 3。
    assert!(purged.len() <= old_purged, "{purged:?} vs {old_purged}");
}

// ---------------------------------------------------------------------- 统计

/// 两份 JSON 相同：字符串按 ID 归一后相等，数按 1e-9 的相对误差（卡片上的浮点和按行序累加，新代按卡 ID 排，协议 3
/// 的行序随查询计划：同一组数换个顺序相加只差末位，模块 `stats` 文件头）。
pub(super) fn close(p: &Pair<'_>, a: &Value, b: &Value, at: &str) {
    match (a, b) {
        (Value::String(x), Value::String(y)) => {
            assert_eq!(p.canon(x), p.canon(y), "{at}");
        }
        (Value::Number(x), Value::Number(y)) => {
            if let (Some(x), Some(y)) = (x.as_i64(), y.as_i64()) {
                assert_eq!(x, y, "{at}");
            } else {
                let (x, y) = (x.as_f64().unwrap(), y.as_f64().unwrap());
                assert!(
                    (x - y).abs() <= 1e-9 * x.abs().max(y.abs()).max(1.0),
                    "{at}: {x} vs {y}"
                );
            }
        }
        (Value::Array(x), Value::Array(y)) => {
            assert_eq!(x.len(), y.len(), "{at}: {a} vs {b}");
            for (i, (x, y)) in x.iter().zip(y).enumerate() {
                close(p, x, y, &format!("{at}[{i}]"));
            }
        }
        (Value::Object(x), Value::Object(y)) => {
            let kx: BTreeSet<String> = x.keys().map(|k| p.canon(k)).collect();
            let ky: BTreeSet<String> = y.keys().map(|k| p.canon(k)).collect();
            assert_eq!(kx, ky, "{at}");
            for (k, v) in x {
                let w = y
                    .iter()
                    .find(|(k2, _)| p.canon(k2) == p.canon(k))
                    .map(|(_, w)| w)
                    .unwrap();
                close(p, v, w, &format!("{at}.{k}"));
            }
        }
        _ => assert_eq!(a, b, "{at}"),
    }
}

type StatsFn = fn(&crate::store::stats::Snapshot, &Value) -> Result<Value, String>;

/// 协议 3 一侧的统计：同一份缓存配置重建缓存表之后读原料，再走同一份聚合。
fn p3_stats(p: &Pair<'_>, f: StatsFn, req: &Value) -> Value {
    let w = p.d.core.writer().unwrap();
    on_p3(&w, &p.cfg, |c| {
        let snap = crate::store::stats::Snapshot::load(c, P).unwrap();
        f(&snap, req).unwrap()
    })
}

/// 统计三条命令与协议 3 对拍：不同范围、牌组子集、可提取度模型、RWKV 回忆率；另验回包不空（场景真有卡与复习）。
#[test]
fn stats_match_protocol_3() {
    use super::stats::{stats_recall, stats_report, stats_rows};
    use crate::store::stats::{recall_of, report_of, rows_of};
    let d = library();
    let p = Pair::new(&d);
    let t = Truth::new(&p.g4);
    let deck = default_deck_id(P);
    let c1 = card(N1, "t1");
    let mut base = json!({
        "key": "k", "now": T0 + 3 * DAY, "utcOff": 0, "rollover": 4,
        "models": [["fsrs6"]], "fallbackModel": 0, "fallbackDesired": 0.85,
    });
    base["deckModels"] = json!({ deck.as_str(): 0 });
    base["desired"] = json!({ deck.as_str(): 0.9 });
    let with = |extra: Value| -> Value {
        let mut r = base.clone();
        for (k, v) in extra.as_object().unwrap() {
            r[k] = v.clone();
        }
        r
    };
    let reqs = [
        with(json!({"range": "all"})),
        with(json!({"range": "month", "decks": [deck.clone()]})),
        with(json!({"range": "year", "decks": ["no-such-deck"]})),
        with(json!({"windows": {"w": [null, 0], "v": [7, 0]}, "future": 40})),
        with(json!({"recallDecks": [deck.clone()], "recall": {"ids": [c1.clone()], "r": [0.42]}})),
        // 同一个 ID 出现两次：协议 3 `stats::Ctx` 后者盖前者，新代 `canon_req` 照同一个读法。
        with(
            json!({"recallDecks": [deck.clone()], "recall": {"ids": [c1.clone(), c1.clone()], "r": [0.42, 0.17]}}),
        ),
        // 将来时刻的 R 跟着同位置的 ID 走（同一个 ID 两次照样后者盖前者）。
        with(json!({"recallDecks": [deck.clone()], "recall": {
            "ids": [c1.clone(), c1.clone()],
            "r": [0.95, 0.93],
            "ahead": [[0.9, 0.85], [0.8, 0.7], [0.6, 0.5]],
        }})),
        json!({"now": T0 + DAY, "utcOff": 540, "rollover": 0}),
    ];
    let sorted = |v: &Value, k: &str| -> Value {
        let mut xs = v[k].as_array().unwrap().clone();
        xs.sort_by_key(|x| {
            (
                p.canon(x[0].as_str().unwrap_or("")),
                x.get(1).cloned().unwrap_or(Value::Null).to_string(),
            )
        });
        Value::Array(xs)
    };
    for req in &reqs {
        let old = p3_stats(&p, report_of, req);
        close(
            &p,
            &old,
            &stats_report(&t, p.col, req).unwrap(),
            &format!("report {req}"),
        );
        // 回忆率候选按卡片行序（调用方按卡 ID 对回去，顺序没有语义）：排过再比。
        let old = p3_stats(&p, recall_of, req);
        let new = stats_recall(&t, p.col, req).unwrap();
        close(
            &p,
            &sorted(&old, "cards"),
            &sorted(&new, "cards"),
            &format!("recall {req}"),
        );
        let (old, new) = (
            p3_stats(&p, rows_of, req),
            stats_rows(&t, p.col, req).unwrap(),
        );
        // 逐卡 / 逐条的行：按 ID 排过再比（协议 3 的行序随查询计划）。
        for k in ["cards", "reviews", "maturity"] {
            close(
                &p,
                &sorted(&old, k),
                &sorted(&new, k),
                &format!("rows.{k} {req}"),
            );
        }
        for k in ["today", "sources", "retrievabilityAvailable"] {
            close(&p, &old[k], &new[k], &format!("rows.{k} {req}"));
        }
        assert!(p.g4.is_autocommit());
    }
    let rows = stats_rows(&t, p.col, &reqs[0]).unwrap();
    assert!(rows["cards"].as_array().unwrap().len() >= 4, "{rows}");
    assert!(rows["reviews"].as_array().unwrap().len() >= 3, "{rows}");
    let recall = stats_recall(&t, p.col, &reqs[4]).unwrap();
    assert!(!recall["cards"].as_array().unwrap().is_empty(), "{recall}");
    // 缺了日界是调用方的 bug：报错，不留事务。
    assert!(stats_report(&t, p.col, &json!({"now": T0})).is_err());
    assert!(p.g4.is_autocommit());
}

// ---------------------------------------------------------------------- 列式批量读与数字 id

/// `card_columns` / `anki_resolve` / `anki_notes_info` 与协议 3 `store/bulk.rs` 对拍（这个库没有带盐的 ID，两侧的数字
/// id 相同）。`card_columns` 按行的多重集比；`anki_notes_info` 每条笔记的可见卡按卡 ID 排过再比（协议 3 依计划）。
#[test]
fn columns_and_numeric_ids_match_protocol_3() {
    use super::columns::{anki_notes_info, anki_resolve, card_columns};
    use crate::store::bulk;
    let d = library();
    let p = Pair::new(&d);
    let t = Truth::new(&p.g4);
    let w = d.core.writer().unwrap();
    let all = || (0..23).map(|_| Id).collect::<Vec<Norm>>();
    for req in [
        json!({}),
        json!({"visibleOnly": true}),
        json!({"fields": ["id", "note_id", "queue", "reps", "stability", "last_log_id"]}),
    ] {
        let old = on_p3(&w, &p.cfg, |c| bulk::card_columns(c, P, &req).unwrap());
        let new = card_columns(&t, p.col, &req).unwrap();
        let n = decode(&new).0.len();
        let norms: Vec<Norm> = all().into_iter().take(n).collect();
        let (of, nf) = (
            vec![("t".to_owned(), old)],
            vec![("t".to_owned(), new.clone())],
        );
        assert_eq!(Pair::names(&of, "t"), Pair::names(&nf, "t"), "{req}");
        assert_eq!(p.rows(&of, "t", &norms), p.rows(&nf, "t", &norms), "{req}");
        assert!(!decode(&new).1.is_empty());
        // 按卡 ID 排（顺序契约）。
        let ids: Vec<(u8, Vec<u8>)> = decode(&new).1.iter().map(|r| sql_key(&r[0])).collect();
        assert!(ids.windows(2).all(|x| x[0] < x[1]), "{req}");
    }
    assert!(card_columns(&t, p.col, &json!({"fields": ["nope"]})).is_err());
    let num = crate::store::schema::anki_numeric_id;
    let (c1, c2) = (card(N1, "t1"), card(N1, "t2"));
    let req = json!({
        "notes": [num(N1), num(N4), 5, num(N2), "x", num(N1)],
        "cards": [num(&c1), num(&c2), num(N1)],
    });
    let old = on_p3(&w, &p.cfg, |c| bulk::anki_resolve(c, P, &req).unwrap());
    let new = anki_resolve(&t, p.col, &req).unwrap();
    close(&p, &old, &new, "anki_resolve");
    assert_eq!(new["notes"][0], json!(N1));
    assert_eq!(new["cards"][1], json!(c2));
    assert_eq!(new["notes"][2], Value::Null);
    let req = json!({"notes": [num(N1), num(N2), num(N3), num(N4), 7, num(N1)]});
    let sort_cards = |mut v: Value| -> Value {
        for n in v["notes"].as_array_mut().unwrap() {
            if let Some(cs) = n.get_mut("c").and_then(Value::as_array_mut) {
                cs.sort_by_key(|c| p.canon(c[1].as_str().unwrap()));
            }
            // 字段：协议 3 按修改记录的落库序，新代按规范键序（调用方按字段 ID 建表，顺序没有语义）。
            if let Some(fs) = n.get_mut("f").and_then(Value::as_array_mut) {
                fs.sort_by_key(|f| p.canon(f[0].as_str().unwrap()));
            }
        }
        v
    };
    let old = on_p3(&w, &p.cfg, |c| bulk::anki_notes_info(c, P, &req).unwrap());
    let new = anki_notes_info(&t, p.col, &req).unwrap();
    close(
        &p,
        &sort_cards(old),
        &sort_cards(new.clone()),
        "anki_notes_info",
    );
    // N1 有内容、有两张可见卡；N4 已删除 = null。
    assert_eq!(new["notes"][0]["c"].as_array().unwrap().len(), 2, "{new}");
    assert!(!new["notes"][0]["f"].as_array().unwrap().is_empty());
    assert_eq!(new["notes"][3], Value::Null);
    assert!(p.g4.is_autocommit());
}

/// `lineages` 与协议 3 `caches::lineage_ids` 对拍：后继卡带出前身、没有前身的卡只有自己、不存在的卡只有自己、空输入。
#[test]
fn lineages_match_protocol_3() {
    use super::lineage::lineages;
    let d = library();
    let p = Pair::new(&d);
    let t = Truth::new(&p.g4);
    let w = d.core.writer().unwrap();
    let (c1, c2) = (card(N1, "t1"), card(N1, "t2"));
    let cards = vec![c2.clone(), c1.clone(), "missing".to_owned(), c2.clone()];
    let old = on_p3(&w, &p.cfg, |c| {
        crate::store::caches::lineage_ids(c, &cards).unwrap()
    });
    let new = lineages(&t, p.col, &cards).unwrap();
    let canon = |v: &Vec<Vec<String>>| -> Vec<Vec<String>> {
        v.iter()
            .map(|l| l.iter().map(|x| p.canon(x)).collect())
            .collect()
    };
    assert_eq!(canon(&old), canon(&new));
    assert_eq!(new[0], [c2.clone(), c1.clone()]);
    assert_eq!(new[1], [c1]);
    assert!(lineages(&t, p.col, &[]).unwrap().is_empty());
    assert!(p.g4.is_autocommit());
}
