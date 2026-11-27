//! `entity_views` 经分发器（G10-2：线上形状见 `cmd/views.rs` 文件头）的端到端测试，一律经 C ABI 的同一个入口
//! （`ffsrs_store_open_mode` / `ffsrs_store_sync2`）。
//!
//! - **对拍**：协议 3 没有这条命令，对拍的是「同一个库、同一个读快照口径」的本机读命令——视图里的身份记录、修改记录、
//!   日志与 `read` 的 `entities` / `edits` / `logs` 逐字相同，ID 是规范 ID，`tag` 是视图字节的 blake3 前 16 字节。
//! - **别名类**：按任何一份成员点名都是同一份视图（规范 ID），同一个类只出一份。
//! - **拒绝**：种类不认识、`ids` 不合形、超过单次上限、没有绑定的 profile 一律报错，不回空结果。
//! - **查询计划**：缓存行点查按主键。

use rusqlite::{Connection, OpenFlags};
use serde_json::{Value, json};

use super::dispatch_tests::{T1, call, g4req, migrated, open};
use super::identity::LOOKUP_MAX;
use super::tests::{N1, N2, N4, card, decode};
use super::tests_class;
use crate::gen4::op::tests::id;
use crate::store::ffi::{SrsCoreHandle, ffsrs_store_close};
use crate::store::gen4::files::{GEN4_FILE, OpenMode};
use crate::store::gen4::kernel::G4Core;
use crate::store::sync2::canonical;
use crate::store::sync2::tests::{P, tempdir};

/// `entity_views` 一条命令的回包（[req] 是整条请求）：JSON 是空对象，视图在唯一一个文件 `t` 的列式表里，交回
/// (规范 ID, tag, 视图 JSON 文本)，按表里的顺序。
pub(super) fn entity_view_rows(
    h: *mut SrsCoreHandle,
    req: &Value,
) -> Vec<(String, String, String)> {
    let (v, files) = call(h, req, None).unwrap_or_else(|(rc, e)| panic!("entity_views: {rc} {e}"));
    assert_eq!(v, json!({}), "the views travel in the table, not the JSON");
    assert_eq!(files.len(), 1);
    assert_eq!(files[0].0, super::views::VIEWS_TABLE);
    let (cols, rows) = decode(&files[0].1);
    assert_eq!(cols, ["id", "tag", "v"]);
    rows.into_iter()
        .map(|mut r| {
            let v = r.pop().unwrap();
            let tag = r.pop().unwrap();
            (r.pop().unwrap(), tag, v)
        })
        .collect()
}

/// `entity_views` 的回包：(规范 ID, tag, 视图)。
fn views(h: *mut SrsCoreHandle, kind: &str, ids: &[&str]) -> Vec<(String, String, Value)> {
    entity_view_rows(
        h,
        &g4req("entity_views", T1, json!({"kind": kind, "ids": ids})),
    )
    .into_iter()
    .map(|(id, tag, text)| {
        let parsed: Value = serde_json::from_str(&text).unwrap();
        assert_eq!(text, canonical(&parsed), "v is the canonical JSON text");
        let want = super::hex(&blake3::hash(text.as_bytes()).as_bytes()[..16]);
        assert_eq!(tag, want, "tag = blake3(v)[..16]");
        assert_eq!(json!(id), parsed["id"]);
        (id, tag, parsed)
    })
    .collect()
}

/// `read` 的一张列式表（第一个文件）解码后的行。
fn read_rows(h: *mut SrsCoreHandle, q: Value) -> Vec<Vec<String>> {
    let (_, files) = call(h, &g4req("read", T1, q), None).unwrap();
    decode(&files[0].1).1
}

/// `read` 的 `[行 JSON, 服务器时刻 | null]`，同视图里的 `edits` / `logs`。
fn json_and_time(json: &str, st: &str) -> Value {
    json!([
        json,
        if st == "∅" {
            Value::Null
        } else {
            json!(st.parse::<i64>().unwrap())
        }
    ])
}

#[test]
fn entity_views_through_the_c_abi_match_the_local_reads() {
    let m = migrated();
    let h = m.h;
    // 笔记：缺的跳过、重复的只出一份、按请求顺序。
    let notes = views(h, "note", &[N2, "missing", N1, N2, N4]);
    assert_eq!(
        notes.iter().map(|(i, _, _)| i.as_str()).collect::<Vec<_>>(),
        vec![N2, N1, N4]
    );
    for (eid, _, v) in &notes {
        assert_eq!(v["k"], "note");
        let ent = read_rows(h, json!({"q": "entities", "ids": [eid]}));
        assert_eq!(ent.len(), 1, "{eid}");
        assert_eq!(ent[0][0], *eid);
        assert_eq!(
            canonical(&v["d"]),
            ent[0][2],
            "d = read entities payload_json"
        );
        let edits: Vec<Value> = read_rows(h, json!({"q": "edits", "kind": "note", "ids": [eid]}))
            .into_iter()
            .map(|r| json_and_time(&r[1], &r[2]))
            .collect();
        assert_eq!(v["edits"], Value::Array(edits), "{eid}: edits = read edits");
        assert_eq!(v["row"]["id"], json!(eid), "{eid}: the cache row is there");
    }
    // 卡：日志与 `read` 的 `logs` 逐字相同。
    let c1 = card(N1, "t1");
    let cards = views(h, "card", &[&c1]);
    assert_eq!(cards.len(), 1);
    let logs: Vec<String> = read_rows(h, json!({"q": "logs", "cards": [c1]}))
        .into_iter()
        .map(|r| r[2].clone())
        .collect();
    assert_eq!(
        cards[0].2["logs"]
            .as_array()
            .unwrap()
            .iter()
            .map(|l| l[0].as_str().unwrap().to_owned())
            .collect::<Vec<_>>(),
        logs
    );
    assert_eq!(cards[0].2["row"]["note_id"], json!(N1));
    // 牌组 / 笔记类型：全部身份记录都有视图，d 与 `entities` 相同。
    for kind in ["deck", "notetype"] {
        let ent = read_rows(h, json!({"q": "entities", "kind": kind}));
        assert!(!ent.is_empty(), "{kind}");
        let ids: Vec<&str> = ent.iter().map(|r| r[0].as_str()).collect();
        let got = views(h, kind, &ids);
        assert_eq!(got.len(), ent.len(), "{kind}");
        for ((gid, _, v), r) in got.iter().zip(&ent) {
            assert_eq!(gid, &r[0]);
            assert_eq!(canonical(&v["d"]), r[2]);
            assert_eq!(v["k"], kind);
        }
    }
    // 同一份库再问一次：什么都没变，tag 不变。
    assert_eq!(views(h, "note", &[N1]), notes[1..2].to_vec());
}

/// 双盐场景（`tests_class.rs` 的 [tests_class::land]）：按任何一份成员点名都是整个类的那一份视图，ID 是规范 ID。
#[test]
fn entity_views_answer_an_alias_class_once_under_its_canonical_id() {
    let dir = tempdir::new("g102views");
    let w = {
        let c = G4Core::open(&dir.0, OpenMode::Primary).unwrap();
        let col = c.write(|t| t.bind(P, &id(0xc0), "dir")).unwrap();
        let w = c.write(|t| Ok(tests_class::land(t, col))).unwrap();
        c.close();
        w
    };
    let h = open(&dir.0, 0).unwrap();
    let canon = views(h, "note", &[&w.c_note.text()]);
    assert_eq!(canon.len(), 1);
    assert_eq!(canon[0].0, w.c_note.text());
    for member in &w.note {
        assert_eq!(views(h, "note", &[&member.text()]), canon, "{member:?}");
    }
    assert_eq!(
        views(h, "note", &[&w.note[0].text(), &w.note[1].text()]),
        canon,
        "one class, one view"
    );
    // 类里两份成员的修改都在（按类判定活着的写入）。
    assert!(!canon[0].2["edits"].as_array().unwrap().is_empty());
    let card = views(h, "card", &[&w.card[1].text()]);
    assert_eq!(card.len(), 1);
    assert_eq!(card[0].0, w.c_card.text());
    assert_eq!(views(h, "card", &[&w.card[0].text()]), card);
    ffsrs_store_close(h);
}

#[test]
fn entity_views_refuse_malformed_requests() {
    let m = migrated();
    let err = |extra: Value| -> String {
        let (rc, e) = call(m.h, &g4req("entity_views", T1, extra), None).unwrap_err();
        assert_ne!(rc, 0);
        e
    };
    assert!(err(json!({"kind": "nope", "ids": [N1]})).contains("unknown kind"));
    assert!(err(json!({"ids": [N1]})).contains("missing kind"));
    assert!(err(json!({"kind": "note"})).contains("ids must be an array"));
    assert!(err(json!({"kind": "note", "ids": [1]})).contains("ids must be strings"));
    let many: Vec<String> = (0..=LOOKUP_MAX).map(|i| format!("x{i}")).collect();
    assert!(err(json!({"kind": "note", "ids": many})).contains("at most"));
    // 没有绑定的 profile：明确报错，不回空结果。
    let mut req = g4req("entity_views", T1, json!({"kind": "note", "ids": [N1]}));
    req["profile"] = json!("0193a1b2-0000-7000-8000-00000000ffff");
    let (_, e) = call(m.h, &req, None).unwrap_err();
    assert!(e.contains("has no collection"), "{e}");
}

/// 缓存行的点查（实现里执行的同一份语句常量）按主键走。
#[test]
fn entity_view_cache_rows_use_their_primary_keys() {
    use super::views::{CARD_ROW_SQL, NOTE_ROW_SQL};
    let m = migrated();
    let c = Connection::open_with_flags(
        m.dir.0.join(GEN4_FILE),
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .unwrap();
    for (q, table) in [(NOTE_ROW_SQL, "notes"), (CARD_ROW_SQL, "cards")] {
        let plan: Vec<String> = c
            .prepare(&format!("EXPLAIN QUERY PLAN {q}"))
            .unwrap()
            .raw_query()
            .mapped(|r| r.get::<_, String>(3))
            .collect::<Result<_, _>>()
            .unwrap();
        assert_eq!(
            plan,
            [format!("SEARCH {table} USING PRIMARY KEY (col=? AND id=?)")],
            "{q}"
        );
    }
}
