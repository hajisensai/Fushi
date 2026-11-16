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

const T0: i64 = 1_700_000_000_000;
const N1: &str = "0193a1b2-0000-7000-8000-0000000000a1";
const N2: &str = "0193a1b2-0000-7000-8000-0000000000a2";
const N3: &str = "0193a1b2-0000-7000-8000-0000000000a3";
const N4: &str = "0193a1b2-0000-7000-8000-0000000000a4";
const ANKI_AT: i64 = T0 - 1000;

// ---------------------------------------------------------------------- 列式表

/// 结果里的一格（`FCL1` 解码后统一成文本，空 = `∅`）。
fn decode(b: &[u8]) -> (Vec<String>, Vec<Vec<String>>) {
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

fn fresh(name: &str) -> Device {
    let d = Device::new(name);
    d.core.sync2_identity(P, T0).unwrap();
    d.core.sync2_migrate(P, T0, None).unwrap();
    d
}

fn note(id: &str, nt: &str, created: i64) -> Value {
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

fn card(note: &str, template: &str) -> String {
    crate::registers::card_id(note, template, 0).unwrap()
}

// ---------------------------------------------------------------------- 迁移来的旧数据

/// 迁移前的旧笔记（身份记录、整列表 `tags` 与字段的旧修改记录、一条旧复习，都带服务器时刻）。
const N5: &str = "0193a1b2-0000-7000-8000-0000000000a5";
const L5: &str = "0193a1b2-0000-7000-8000-0000000000b5";
const LEGACY_AT: i64 = T0 - 5000;
const ST_EDIT: i64 = T0 - 4000;
const ST_TAGS: i64 = T0 - 3500;
const ST_LOG: i64 = T0 - 3000;

/// N5 的旧整列表 `tags` 修改记录 ID（迁移后协议 3 用合成行替掉它，`refresh_tags_row`）。
fn legacy_tags_edit() -> String {
    crate::registers::edit_id("old", 1)
}

fn legacy_field_edit() -> String {
    crate::registers::edit_id("old", 2)
}

/// 笔记 [note] 合成 `tags` 行的修改记录 ID（协议 3 `semantics::tags_writer`）。
fn tags_row_id(note: &str) -> String {
    crate::registers::edit_id(&crate::store::sync2::semantics::tags_writer(note), 1)
}

/// 迁移前往旧库里写 N5 的旧数据（形状同 `store/sync2/tests.rs` 的 `legacy_library`）。
fn legacy_rows(d: &Device) {
    let w = d.core.writer().unwrap();
    w.execute(
        "INSERT INTO srs_entities (id, profile_uid, kind, payload_json, created_at) \
         VALUES (srs_id(?1), srs_id(?2), 'note', json_object('createdAt', 45, 'guid', ?1, 'noteTypeId', 'NT'), 45)",
        rusqlite::params![N5, P],
    )
    .unwrap();
    for (id, s, f, v) in [
        (legacy_tags_edit(), 1, "tags", json!(["legacy", "old"])),
        (legacy_field_edit(), 2, "f/fa", json!("蛙")),
    ] {
        let j = json!({"ctx": {"vv": {}}, "e": N5, "f": f, "hlc": format!("{}:0:old", LEGACY_AT + s), "id": id,
                       "k": "note", "p": P, "s": s, "ts": "wall", "v": v, "w": "old"})
        .to_string();
        w.execute(
            "INSERT INTO srs_field_edits (id, profile_uid, entity_kind, entity_id, field_key, writer_id, seq, jslim) \
             VALUES (srs_id(?1), srs_id(?2), 'note', srs_id(?3), ?4, 'old', ?5, ?6)",
            rusqlite::params![id, P, N5, f, s, j],
        )
        .unwrap();
    }
    let log = json!({
        "id": L5, "p": P, "card": card(N5, "t1"), "kind": "review", "rating": 3, "hlc": format!("{LEGACY_AT}:0:old"),
        "at": LEGACY_AT, "ts": "anchored", "origin": "fushi", "rtype": "learn", "utcOff": 0, "rollover": 4, "fv": 1,
        "res": {"queue": "learning", "ivl": 0, "step": 1, "reps": 1, "lapses": 0, "scheduler": "fushi"}
    })
    .to_string();
    w.execute(
        "INSERT INTO srs_review_logs (id, profile_uid, card_id, kind, rating, occurred_at, review_type, origin, jslim) \
         VALUES (srs_id(?1), srs_id(?2), srs_id(?3), 'review', 3, ?4, 'learn', 'fushi', ?5)",
        rusqlite::params![L5, P, card(N5, "t1"), LEGACY_AT, log],
    )
    .unwrap();
    for (id, st) in [
        (legacy_field_edit(), ST_EDIT),
        (legacy_tags_edit(), ST_TAGS),
        (L5.to_owned(), ST_LOG),
    ] {
        w.execute(
            "INSERT INTO srs_event_local (event_id, profile_uid, outbox_seq, server_time, received_at) \
             VALUES (srs_id(?1), srs_id(?2), NULL, ?3, ?3)",
            rusqlite::params![id, P, st],
        )
        .unwrap();
    }
}

// ---------------------------------------------------------------------- 别名类

/// 别名类用的笔记类型：规范规则下的 ID（`ankiNum` 验得上），模板 ID 由它派生（卡因此也按类派生）。
const ALIAS_NT_NUM: i64 = 7001;
const ALIAS_GUID: &str = "g4r-alias-guid";

fn alias_nt() -> String {
    crate::gen4_ids::rules::note_type(crate::gen4_ids::rules::CANONICAL, ALIAS_NT_NUM).text()
}

fn alias_tmpl() -> String {
    let nt = crate::sync2::id::Id::parse(&alias_nt()).unwrap();
    crate::gen4_ids::rules::template(&nt, 0).text()
}

/// 同一个 guid 在两个盐下的笔记 ID：带盐的（盐 = profile uid，[Pair::new] 照迁移写进 `Salts`）有身份记录；规范的只由
/// 另一台设备按规范 ID 写的修改与日志引用（同 `alias.rs` 测试「另一台设备按规范 ID 写」）。两者是一个别名类，规范 ID
/// 是后者。规范成员不另建身份记录：协议 3 里那会是两条笔记、两行缓存，新代按类只有一行，协议 3 不再是基准。
fn alias_salted() -> String {
    crate::gen4_ids::rules::note(Some(P), ALIAS_GUID).text()
}

fn alias_canon() -> String {
    crate::gen4_ids::rules::note(crate::gen4_ids::rules::CANONICAL, ALIAS_GUID).text()
}

/// 两份同一条 Anki revlog（导入到两张同类的卡上：ID 由卡派生，同一个日志类）。
const ALIAS_REVLOG: i64 = 4242;
const ALIAS_AT: i64 = T0 - 2000;

fn alias_log(card: &str) -> (String, Value) {
    let c = crate::sync2::id::Id::parse(card).unwrap();
    let id = crate::gen4_ids::rules::imported_revlog(&c, ALIAS_REVLOG).text();
    let mut ev = anki_review(&id, card, ALIAS_AT);
    ev["x"]["ankiId"] = json!(ALIAS_REVLOG);
    (id, ev)
}

/// 一个够全的协议 3 库：两台设备、牌组 / 笔记类型（字段、模板、词条字段）、四条笔记（字段带样式块与链接、标签、
/// 删除）、并发改同一个字段（冲突）、评分与撤销、Anki 导入的复习、继承历史的后继卡；迁移来的旧笔记 N5（整列表
/// `tags` 旧修改、带服务器时刻的旧修改与旧复习）；`#tag` 增删（N2）；一个两成员的别名类（带盐 / 规范的同一 guid
/// 笔记，各自带修改、同一条 Anki 复习的两份副本，带盐的那条上有并发冲突）。返回 a（两边同步完）。
fn library() -> Device {
    let deck = default_deck_id(P);
    let a = Device::new("g4ra");
    legacy_rows(&a);
    a.core.sync2_identity(P, T0).unwrap();
    while a.core.sync2_migrate(P, T0, None).unwrap()["done"] != json!(true) {}
    let b = fresh("g4rb");
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
    // `#tag` 增删：先加 x，再换成 y（加 y、观察删 x）。
    a.apply(T0 + DAY + 31, vec![edit("note", N2, "tags", json!(["x"]))]);
    a.apply(T0 + DAY + 32, vec![edit("note", N2, "tags", json!(["y"]))]);
    // 别名类的带盐成员（a 上）：身份记录、字段、卡上的 Anki 复习。
    let (nt, tmpl, salted) = (alias_nt(), alias_tmpl(), alias_salted());
    a.apply(
        T0 + DAY + 33,
        vec![
            json!({"t": "entity", "x": {"id": nt, "p": P, "k": "notetype", "d": {"createdAt": 2, "ntKind": "standard", "ankiNum": ALIAS_NT_NUM}}}),
            edit("notetype", &nt, "fieldDef/fa", fdef("Expression", 0)),
            edit(
                "notetype",
                &nt,
                &format!("tmplDef/{tmpl}"),
                json!({"name": "A", "ord": 0, "front": "{{Expression}}", "ankiNum": 0}),
            ),
            json!({"t": "entity", "x": {"id": salted, "p": P, "k": "note", "d": {"createdAt": 50, "guid": ALIAS_GUID, "noteTypeId": nt}}}),
            edit("note", &salted, "f/fa", json!("鴨")),
            alias_log(&card(&salted, &tmpl)).1,
        ],
    );
    a.sync(&mut bucket, "loc", T0 + DAY + 40);
    b.sync(&mut bucket, "loc", T0 + DAY + 40);
    // 别名类的规范成员（b 上按规范 ID 写）：它自己的字段、同一条 Anki 复习的另一份。
    let canon = alias_canon();
    b.apply(
        T0 + DAY + 45,
        vec![
            edit("note", &canon, "f/fb", json!("duck")),
            alias_log(&card(&canon, &tmpl)).1,
        ],
    );
    // 带盐成员上两台设备并发改同一个字段：类里的冲突。
    a.apply(
        T0 + DAY + 50,
        vec![edit("note", &salted, "f/fc", json!("mallard A"))],
    );
    b.apply(
        T0 + DAY + 51,
        vec![edit("note", &salted, "f/fc", json!("mallard B"))],
    );
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
    a
}

/// 协议 3 一侧：在 SAVEPOINT 里先做完欠着的收尾、按新代同一份配置重建缓存，跑 [f]，整个回滚。
fn on_p3<T>(src: &Connection, cfg: &str, f: impl FnOnce(&Connection) -> T) -> T {
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

/// 换代时写进集合的那条 `Salts`（设计 §5.1、§6.1 第 7 步：盐 = profile uid 并上已退役的 uid，`legacy::salts`）：
/// 由一台迁移设备写进它的原生日志，再整体重建（同 `derive.rs` 样本测试的做法；灌入 `import_legacy` 自己不写盐）。
/// 有了盐，带盐的 ID 才验得上、别名类才有多个成员。写完与协议 3 再对拍一遍（按规范 ID，`compare.rs`）。
fn salted(d: &Device, t: &Truth<'_>, col: i64) {
    use crate::gen4::op::{Body4, Op4};
    use crate::sync2::hlc::Hlc;
    use crate::sync2::id::Id;
    use crate::sync2::vv::OpId;
    let src = d.core.writer().unwrap();
    let salts = crate::store::gen4::legacy::salts(&src, P).unwrap();
    let migrator = Id([0x6d; 16]);
    t.tx(|t| {
        let op = Op4::of(
            OpId {
                device: migrator,
                seq: 1,
            },
            Hlc {
                wall: T0,
                logical: 0,
                device: migrator,
            },
            std::sync::Arc::new(t.applied(col)?),
            &Body4::salts(salts.iter().cloned()).map_err(|e| format!("{e:?}"))?,
        );
        t.append_native(col, &op)?;
        Index::new(t, col).rebuild_all().map(|_| ())
    })
    .unwrap();
    let diff = crate::store::gen4::parity::against_protocol_3(&src, P, t, col);
    assert!(diff.is_empty(), "after the salts: {diff:?}");
}

/// 一列怎么归一。
#[derive(Clone, Copy)]
enum Norm {
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

struct Pair<'d> {
    d: &'d Device,
    g4: Connection,
    col: i64,
    cfg: String,
}

impl<'d> Pair<'d> {
    fn new(d: &'d Device) -> Pair<'d> {
        let (g4, diff) = imported(d);
        assert!(diff.is_empty(), "{diff:?}");
        let t = Truth::new(&g4);
        let col = t.binding_of(P).unwrap().unwrap().col;
        salted(d, &t, col);
        let cfg = t.derive_cfg(col, CFG_KEY).unwrap().unwrap();
        Pair { d, g4, col, cfg }
    }

    fn ix<T>(&self, f: impl FnOnce(&mut Index<'_, '_>) -> T) -> T {
        let t = Truth::new(&self.g4);
        let mut ix = Index::new(&t, self.col);
        f(&mut ix)
    }

    fn canon(&self, s: &str) -> String {
        if s == "∅" {
            return s.to_owned();
        }
        self.ix(|ix| ix.canonical(&Ref::of(&Key::of(s))).unwrap().text())
    }

    fn norm(&self, n: Norm, s: &str) -> String {
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

    fn p3(&self, req: Value) -> (Value, Files) {
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

    fn g4(&self, req: Value) -> (Value, Files) {
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
    fn rows(&self, files: &Files, name: &str, norms: &[Norm]) -> Vec<Vec<String>> {
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

    fn names(files: &Files, name: &str) -> Vec<String> {
        let (_, bytes) = files.iter().find(|(n, _)| n == name).unwrap();
        decode(bytes).0
    }

    /// 一条 `read` 两侧对拍：JSON 回包相同，每张表的列名相同、归一后的行相同。返回新代一侧的行（未归一）。
    ///
    /// 一个别名类只出一份（D24）：协议 3 里同一个类的几份（同一条 Anki 复习导入到两张同类卡上的两份副本）归一后是
    /// 相同的几行，按一行比；新代一侧归一后不许有重复行。
    fn same(&self, req: Value, tables: &[(&str, &[Norm])]) -> Vec<Vec<String>> {
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
            let (mut p, g) = (self.rows(&pf, name, norms), self.rows(&gf, name, norms));
            p.dedup();
            let mut once = g.clone();
            once.dedup();
            assert_eq!(once, g, "{req} {name}: gen4 gives a class more than once");
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

/// 夹具守卫：对拍库里真有多成员的别名类、承袭来的服务器时刻与 `#tag` 操作——没有它们，按类归并、代表选取、标签
/// OR-Set 这些分支在对拍里只走平凡路径，坏了也照样全绿。
#[test]
fn the_library_has_alias_classes_inherited_server_times_and_tag_ops() {
    let lib = library();
    let p = Pair::new(&lib);
    let count = |sql: &str| -> i64 { p.g4.query_row(sql, [p.col], |r| r.get(0)).unwrap() };
    assert!(
        count("SELECT COUNT(*) FROM alias_ix WHERE col = ?1 AND canon != id") > 0,
        "the library has multi-member alias classes"
    );
    assert_eq!(p.canon(&alias_salted()), alias_canon());
    let (sc, cc) = (
        card(&alias_salted(), &alias_tmpl()),
        card(&alias_canon(), &alias_tmpl()),
    );
    assert_eq!(p.canon(&sc), cc, "cards follow their note's class");
    assert_eq!(
        p.canon(&alias_log(&sc).0),
        alias_log(&cc).0,
        "the two revlog copies are one log class"
    );
    assert!(count("SELECT COUNT(*) FROM tag_ix WHERE col = ?1") > 0);
    let (_, gf) = p.g4(json!({"q": "server_times"}));
    assert!(
        p.rows(&gf, "t", &[Id, Plain]).len() >= 2,
        "inherited server times"
    );
}

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
    // 别名类：按非规范成员（带盐的那条，协议 3 里有身份记录）要，出规范 ID 的一份；按规范 ID 要是同一份。
    let rows = p.same(
        json!({"q": "entities", "ids": [alias_salted(), N1], "ordered": true}),
        &[("t", ent)],
    );
    assert!(rows.iter().any(|r| r[0] == alias_canon()), "{rows:?}");
    assert_eq!(rows.len(), 2, "{rows:?}");
    assert_eq!(
        p.g4(json!({"q": "entities", "ids": [alias_salted()]})).1,
        p.g4(json!({"q": "entities", "ids": [alias_canon(), alias_salted()]}))
            .1,
        "any member of a class asks for the same record"
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
    // 别名类：新代按类出两个成员的写入（协议 3 里是两个实体，两个都要才是同一份）；只按任一成员要也是这一份。
    let (salted, canon) = (alias_salted(), alias_canon());
    let rows = p.same(
        json!({"q": "edits", "kind": "note", "ids": [salted, canon, N1]}),
        &[("t", ed)],
    );
    let class: Vec<&Vec<String>> = rows.iter().filter(|r| r[0] == canon).collect();
    assert_eq!(
        class.len(),
        4,
        "f/fa, f/fb and the two f/fc of the class: {rows:?}"
    );
    for member in [&salted, &canon] {
        assert_eq!(
            p.g4(json!({"q": "edits", "kind": "note", "ids": [member]}))
                .1,
            p.g4(json!({"q": "edits", "kind": "note", "ids": [canon, salted]}))
                .1,
            "{member}"
        );
    }
    p.same(
        json!({"q": "edits", "kind": "note", "ids": [salted], "key": "f/fc"}),
        &[("t", ed)],
    );
    p.same(json!({"q": "successors"}), &[("t", &[Id, Plain])]);
    let conflict: &[Norm] = &[Plain, Id, Plain, Edit, Skip];
    let rows = p.same(
        json!({"q": "conflict_edits", "rules": [{"kind": "note", "drop": []}]}),
        &[("t", conflict)],
    );
    assert_eq!(
        rows.len(),
        4,
        "the concurrent f/fb writes on N3 and f/fc on the alias class: {rows:?}"
    );
    assert_eq!(rows.iter().filter(|r| r[1] == canon).count(), 2, "{rows:?}");
    let rows = p.same(
        json!({"q": "conflict_edits", "rules": [{"kind": "note", "drop": []}], "kind": "note", "id": salted}),
        &[("t", conflict)],
    );
    assert_eq!(rows.len(), 2, "asked by the salted member: {rows:?}");
    assert_eq!(
        p.g4(json!({"q": "conflict_edits", "rules": [{"kind": "note", "drop": []}], "kind": "note", "id": canon})).1,
        p.g4(json!({"q": "conflict_edits", "rules": [{"kind": "note", "drop": []}], "kind": "note", "id": salted})).1,
    );
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
        &[("t", &[Id, Id, Log, Skip])],
    );
    p.same(
        json!({"q": "anki_logs_at", "at": [ANKI_AT, 5]}),
        &[("t", &[Id, Plain, Plain, Plain, Plain, Id, Plain])],
    );
    // 别名类：同一条 Anki 复习的两份副本是一个日志类，出一份（代表）；按带盐的卡要与按规范的卡要相同。
    let (sc, cc) = (
        card(&alias_salted(), &alias_tmpl()),
        card(&alias_canon(), &alias_tmpl()),
    );
    // 协议 3 里规范成员那份副本的卡没有缓存行（协议 3 不知道它与带盐的卡是一类，规范成员没有身份记录），笔记列是空的；
    // 新代一个日志类出一份，就是协议 3 里认得卡的那一份。
    {
        let req = json!({"q": "anki_logs_at", "at": [ALIAS_AT]});
        let norms: &[Norm] = &[Id, Plain, Plain, Plain, Plain, Id, Plain];
        let (pf, gf) = (p.p3(req.clone()).1, p.g4(req.clone()).1);
        let (pr, gr) = (p.rows(&pf, "t", norms), p.rows(&gf, "t", norms));
        assert_eq!(pr.len(), 2, "{pr:?}");
        assert_eq!(gr.len(), 1, "two copies, one log class: {gr:?}");
        assert!(pr.contains(&gr[0]), "{gr:?} ⊄ {pr:?}");
        assert_eq!(gr[0][5], alias_canon(), "{gr:?}");
    }
    let rows = p.same(
        json!({"q": "logs", "cards": [sc, cc]}),
        &[("t", &[Id, Id, Log, Skip])],
    );
    assert_eq!(rows.len(), 1, "{rows:?}");
    p.same(
        json!({"q": "logs", "cards": [sc]}),
        &[("t", &[Id, Id, Log, Skip])],
    );
    assert_eq!(
        p.g4(json!({"q": "logs", "cards": [sc]})).1,
        p.g4(json!({"q": "logs", "cards": [cc]})).1
    );
    p.same(
        json!({"q": "logs", "cards": [card(N5, "t1")]}),
        &[("t", &[Id, Id, Log, Skip])],
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
    // 服务器时刻：只有承袭来的事件有（N5 迁移来的旧修改——含整列表 `tags` 那条，它在新代是标签操作——与旧复习）。
    let st: &[Norm] = &[Id, Plain];
    let rows = p.same(json!({"q": "server_times"}), &[("t", st)]);
    assert_eq!(
        rows,
        vec![
            vec![legacy_field_edit(), ST_EDIT.to_string()],
            vec![legacy_tags_edit(), ST_TAGS.to_string()],
            vec![L5.to_owned(), ST_LOG.to_string()]
        ]
        .into_iter()
        .map(|mut r| {
            r[0] = p.canon(&r[0]);
            r
        })
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect::<Vec<_>>(),
    );
    p.same(
        json!({"q": "server_times", "ids": [L5, legacy_tags_edit(), alias_log(&sc).0, "nope"]}),
        &[("t", st)],
    );
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
    // 别名类：按带盐成员要，出规范 ID 的那一行（笔记、卡）；按规范 ID 要相同。
    let salted = alias_salted();
    let rows = p.same(json!({"q": "notes", "ids": [salted]}), &[("t", note_cols)]);
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0][0], alias_canon());
    let sc = card(&salted, &alias_tmpl());
    let rows = p.same(
        json!({"q": "cards", "notes": [salted], "ordered": true}),
        &[("t", &card_cols)],
    );
    assert_eq!(rows.len(), 1);
    p.same(json!({"q": "cards", "ids": [sc]}), &[("t", &card_cols)]);
    assert_eq!(
        p.g4(json!({"q": "cards", "ids": [sc]})).1,
        p.g4(json!({"q": "cards", "notes": [alias_canon()]})).1
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
        json!({"q": "term_status", "terms": ["猫", "鳥", "犬", "鴨", "蛙"]}),
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
    // 合成 `tags` 行（`events` / `edits` 出的那一行）、迁移来的整列表 `tags` 旧修改（投影里被合成行替掉，只在操作里）、
    // 别名类的非规范成员与日志副本。
    let sc = card(&alias_salted(), &alias_tmpl());
    let cc = card(&alias_canon(), &alias_tmpl());
    let synthetic = [tags_row_id(N1), tags_row_id(N2), tags_row_id(N5)];
    let ids = json!([
        N1,
        "r1",
        "a1",
        live_edit,
        edit_id,
        "nope",
        N1,
        alias_salted(),
        alias_log(&sc).0,
        alias_log(&cc).0,
        synthetic[0],
        synthetic[1],
        synthetic[2],
        legacy_tags_edit(),
        legacy_field_edit(),
        L5
    ]);
    // 比集合：协议 3 按来源表 UNION ALL，一个 ID 在投影表与操作表各命中一次就出两行；新代每个 ID 一行（读者只当集合用）。
    for ops in [false, true] {
        let req = json!({"q": "events_present", "ids": ids, "ops": ops});
        let (_, pf) = p.p3(req.clone());
        let (_, gf) = p.g4(req.clone());
        let mut want = p.rows(&pf, "t", &[Id]);
        want.dedup();
        // 同一个类的两个成员（两份日志副本）各问一次：各出一行，归一后相同。
        let mut got = p.rows(&gf, "t", &[Id]);
        got.dedup();
        assert_eq!(want, got, "{req}");
        assert!(got.len() >= 4, "{req}: {got:?}");
        let raw: Vec<String> = decode(&gf[0].1)
            .1
            .into_iter()
            .map(|r| r[0].clone())
            .collect();
        for s in &synthetic {
            assert!(
                raw.contains(s),
                "ops {ops}: the synthetic tags row {s} is present: {raw:?}"
            );
        }
        assert_eq!(
            raw.contains(&legacy_tags_edit()),
            ops,
            "the legacy whole-list tags edit is only an op, not a projected row: {raw:?}"
        );
    }
    // 新代自己导出的每个修改记录 ID（行里的 `id`，没写的按 `edit_id(w, s)`），用 events_present 查都在。
    let (_, ev) = p.g4(json!({"q": "events", "parts": ["edits"]}));
    let exported: Vec<String> = decode(&ev[0].1)
        .1
        .into_iter()
        .map(|r| {
            let v: Value = serde_json::from_str(&r[0]).unwrap();
            v["id"].as_str().map_or_else(
                || crate::registers::edit_id(v["w"].as_str().unwrap(), v["s"].as_i64().unwrap()),
                str::to_owned,
            )
        })
        .collect();
    assert!(exported.iter().any(|id| synthetic.contains(id)));
    let (_, gf) = p.g4(json!({"q": "events_present", "ids": exported}));
    assert_eq!(decode(&gf[0].1).1.len(), exported.len());
    // 规范成员（协议 3 里没有身份记录）按类也算在。
    let (_, gf) = p.g4(json!({"q": "events_present", "ids": [alias_canon()]}));
    assert_eq!(decode(&gf[0].1).1, vec![vec![alias_canon()]]);
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
        json!({"q": "pending_notes"}),
        json!({"q": "edits", "kind": "note", "ids": [N1]}),
        json!({"q": "logs", "cards": [c1]}),
        json!({"q": "entities", "ids": [N1]}),
        json!({"q": "anki_logs_at", "at": [ANKI_AT]}),
        json!({"q": "native_logs_near", "at": [T0], "win": 10}),
        json!({"q": "successors"}),
        json!({"q": "today_reviews", "from": T0, "to": T0 + DAY}),
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
    // 别名类：两个不同成员（带盐的、规范的）只出一份，ID 是规范 ID，修改是两个成员的并。
    let (salted, canon) = (alias_salted(), alias_canon());
    let views = entity_views(&t, p.col, EntKind::Note, &[salted.clone(), canon.clone()]).unwrap();
    assert_eq!(
        views.iter().map(|v| v.id.as_str()).collect::<Vec<_>>(),
        vec![canon.as_str()],
        "two members of one class: one view"
    );
    assert_eq!(
        views,
        entity_views(&t, p.col, EntKind::Note, std::slice::from_ref(&canon)).unwrap()
    );
    let v: Value = serde_json::from_str(&views[0].json).unwrap();
    let keys: BTreeSet<String> = v["edits"]
        .as_array()
        .unwrap()
        .iter()
        .map(|e| {
            serde_json::from_str::<Value>(e[0].as_str().unwrap()).unwrap()["f"]
                .as_str()
                .unwrap()
                .to_owned()
        })
        .collect();
    assert_eq!(
        keys,
        ["f/fa", "f/fb", "f/fc"].map(str::to_owned).into(),
        "the edits of both members"
    );
    assert_eq!(v["row"]["id"], json!(canon));
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
        (EntKind::Note, N5.to_owned()),
        (EntKind::Note, alias_salted()),
        (EntKind::Note, alias_canon()),
    ] {
        // 别名类的历史是成员历史的并（协议 3 里每个成员是一个实体，各查一遍）。
        let members: Vec<String> = if p.canon(&ent) == alias_canon() {
            vec![alias_salted(), alias_canon()]
        } else {
            vec![ent.clone()]
        };
        let mut old: Vec<Value> = Vec::new();
        for m in &members {
            let h = d.core.sync2_history(P, kind.wire(), m).unwrap();
            old.extend(h.as_array().unwrap().iter().cloned());
        }
        let old = Value::Array(old);
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
