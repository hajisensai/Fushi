//! 独立复习库并进共享复习库（`collection_merge.rs`，组合阶段 5）经 C ABI 的测试：同一个库里 A（被并入的独立库）、
//! B（共享库）各自导入同一份内容（同 guid 的笔记、同一张卡），各自改字段、各自复习。
//!
//! - 预览：共有笔记数、只在 A 的笔记数、冲突（字段内容不同 / 笔记类型不同），两边的值与名字；
//! - 默认保留共享库：并集里 A 的值较新也写回 B 的值；选了 A 的写回 A 的值（B 的较新也一样）；笔记类型冲突写回选定的类型；
//! - 复习日志两边全部保留，只在 A 的笔记进了 B，A 的集合没了、B 的日志里一条 from = A 的集合的 `Join`；
//! - 墓碑：并入后 `collection_merges` 列出、`collection_merge_done` 删掉；
//! - 拒绝：坏的选择值、选了两边都没有的笔记——整笔回滚，A 的集合原样；A 在本机没有集合 = `merged: false`；
//! - 新语句的执行计划。

use serde_json::{Value, json};

use crate::gen4_ids::rules;
use crate::store::ffi::{SrsCoreHandle, ffsrs_store_close};
use crate::store::gen4::cmd::dispatch_tests::{T1, call, g4req, open};
use crate::store::gen4::derive::{Index, Ref};
use crate::store::gen4::files::OpenMode;
use crate::store::gen4::kernel::G4Core;
use crate::store::sync2::config::default_deck_id;
use crate::store::sync2::tests::tempdir;
use crate::sync2::id::Key;
use crate::sync2::op::EntKind;

/// 共享库（`into`）。
const B: &str = "0193a1b2-0000-7000-8000-00000000b0b0";
/// 被并入的独立库（`from`）。
const A: &str = "0193a1b2-0000-7000-8000-00000000a0a0";

const NT_NUM: i64 = 7001;
const NT2_NUM: i64 = 7002;
const GUID: &str = "shared-guid";
const A_ONLY_GUID: &str = "a-only-guid";

struct Ids {
    nt: String,
    field: String,
    tmpl: String,
    nt2: String,
    field2: String,
    note: String,
    card: String,
    a_only: String,
}

fn ids() -> Ids {
    let nt = rules::note_type(rules::CANONICAL, NT_NUM);
    let nt2 = rules::note_type(rules::CANONICAL, NT2_NUM);
    let tmpl = rules::template(&nt, 1);
    let note = rules::note(rules::CANONICAL, GUID);
    Ids {
        field: rules::field(&nt, 1).text(),
        field2: rules::field(&nt2, 1).text(),
        tmpl: tmpl.text(),
        card: rules::card(&note, &tmpl, 0).text(),
        note: note.text(),
        a_only: rules::note(rules::CANONICAL, A_ONLY_GUID).text(),
        nt: nt.text(),
        nt2: nt2.text(),
    }
}

fn try_run(
    h: *mut SrsCoreHandle,
    profile: &str,
    op: &str,
    now: i64,
    extra: Value,
    items: &[Value],
) -> Result<Value, String> {
    let mut r = g4req(op, now, extra);
    r["profile"] = json!(profile);
    let items = (!items.is_empty()).then_some(items);
    call(h, &r, items)
        .map(|(v, _)| v)
        .map_err(|(rc, e)| format!("{rc} {e}"))
}

fn run(
    h: *mut SrsCoreHandle,
    profile: &str,
    op: &str,
    now: i64,
    extra: Value,
    items: &[Value],
) -> Value {
    try_run(h, profile, op, now, extra, items).unwrap_or_else(|e| panic!("{op}: {e}"))
}

fn ready(h: *mut SrsCoreHandle, profile: &str) {
    run(h, profile, "identity", T1, json!({}), &[]);
    let caches = json!({"defaultDeck": default_deck_id(profile)});
    run(
        h,
        profile,
        "cache_config_set",
        T1,
        json!({"caches": caches}),
        &[],
    );
}

fn entity(profile: &str, kind: &str, id: &str, d: Value) -> Value {
    json!({"e": {"t": "entity", "x": {"id": id, "p": profile, "k": kind, "d": d}}})
}

fn edit(profile: &str, kind: &str, id: &str, key: &str, v: Value) -> Value {
    let note = if kind == "note" {
        json!(id)
    } else {
        Value::Null
    };
    json!({"e": {"t": "edit", "x": {"id": "ignored", "p": profile, "k": kind, "e": id, "f": key, "w": "dart", "s": 1, "ctx": {"vv": {}}, "v": v, "hlc": "0:0:dart", "ts": "anchored"}}, "note": note})
}

fn note_type(profile: &str, id: &str, num: i64, field: &str, tmpl: Option<&str>) -> Vec<Value> {
    let mut out = vec![
        entity(
            profile,
            "notetype",
            id,
            json!({"ankiNum": num, "ntKind": "standard", "createdAt": 1}),
        ),
        edit(
            profile,
            "notetype",
            id,
            "name",
            json!(format!("类型 {num}")),
        ),
        edit(
            profile,
            "notetype",
            id,
            &format!("fieldDef/{field}"),
            json!({"name": format!("Expression {num}"), "ord": 0}),
        ),
    ];
    if let Some(t) = tmpl {
        out.push(edit(
            profile,
            "notetype",
            id,
            &format!("tmplDef/{t}"),
            json!({"name": "Card 1", "ord": 0, "front": format!("{{{{fld:{field}}}}}"), "back": ""}),
        ));
    }
    out
}

/// [profile] 导入同一份内容：笔记类型 + 共有笔记（字段值 [value]）。
fn content(profile: &str, i: &Ids, value: &str) -> Vec<Value> {
    let mut out = note_type(profile, &i.nt, NT_NUM, &i.field, Some(&i.tmpl));
    out.push(entity(
        profile,
        "note",
        &i.note,
        json!({"guid": GUID, "noteTypeId": i.nt, "createdAt": 5}),
    ));
    out.push(edit(
        profile,
        "note",
        &i.note,
        &format!("f/{}", i.field),
        json!(value),
    ));
    out
}

fn review(profile: &str, id: &str, card: &str, note: &str, at: i64) -> Value {
    json!({"e": {"t": "log", "x": {
        "id": id, "p": profile, "card": card, "kind": "review", "rating": 3, "hlc": format!("{at}:0:dart"), "at": at,
        "ts": "anchored", "origin": "fushi", "rtype": "learn", "utcOff": 0, "rollover": 4, "fv": 1,
        "res": {"queue": "new", "ivl": 0, "step": 0, "reps": 0, "lapses": 0, "scheduler": "fushi"}
    }}, "note": note})
}

/// 同一个库里的 B（共享库）与 A（独立库），各自导入同一份内容、各自复习一次同一张卡；A 还有一条只在它那里的笔记。
/// [b_value] / [a_value] 是两边的字段值，[a_later]：A 的改动比 B 的晚（否则 B 的晚）。
struct Lib {
    dir: tempdir::Dir,
    h: *mut SrsCoreHandle,
    i: Ids,
}

fn lib(tag: &str, a_later: bool) -> Lib {
    let dir = tempdir::new(tag);
    let h = open(&dir.0, 0).unwrap();
    ready(h, B);
    ready(h, A);
    let i = ids();
    let (tb, ta) = if a_later {
        (T1, T1 + 60_000)
    } else {
        (T1 + 60_000, T1)
    };
    let v = run(h, B, "apply", tb, json!({}), &content(B, &i, "鳥"));
    assert_eq!(v["foreign"], json!([]), "{v}");
    let mut a = content(A, &i, "鯨");
    a.push(entity(
        A,
        "note",
        &i.a_only,
        json!({"guid": A_ONLY_GUID, "noteTypeId": i.nt, "createdAt": 6}),
    ));
    a.push(edit(
        A,
        "note",
        &i.a_only,
        &format!("f/{}", i.field),
        json!("猫"),
    ));
    let v = run(h, A, "apply", ta, json!({}), &a);
    assert_eq!(v["foreign"], json!([]), "{v}");
    run(
        h,
        B,
        "apply",
        tb + 1,
        json!({}),
        &[review(
            B,
            "0193a1b2-0000-7000-8000-0000000001b1",
            &i.card,
            &i.note,
            tb,
        )],
    );
    run(
        h,
        A,
        "apply",
        ta + 1,
        json!({}),
        &[review(
            A,
            "0193a1b2-0000-7000-8000-0000000001a1",
            &i.card,
            &i.note,
            ta,
        )],
    );
    Lib { dir, h, i }
}

fn merge_req(resolutions: Value) -> Value {
    json!({"from": A, "into": B, "resolutions": resolutions})
}

fn preview(l: &Lib) -> Value {
    run(
        l.h,
        B,
        "collection_merge_preview",
        T1,
        json!({"from": A, "into": B}),
        &[],
    )
}

fn merge(l: &Lib, resolutions: Value) -> Value {
    run(
        l.h,
        B,
        "collection_merge",
        T1 + 120_000,
        merge_req(resolutions),
        &[],
    )
}

/// 关掉句柄，按 B 的集合读笔记 [note] 的寄存器 [key]（类读，规范 JSON 文本）。
fn value_after(l: Lib, note: &str, key: &str) -> Option<String> {
    ffsrs_store_close(l.h);
    let c = G4Core::open(&l.dir.0, OpenMode::Primary).unwrap();
    let v = c
        .read(|t| {
            let col = t.binding_of(B)?.unwrap().col;
            Index::new(t, col).class_value(EntKind::Note, &Ref::of(&Key::of(note)), key)
        })
        .unwrap();
    c.close();
    drop(l.dir);
    v
}

fn reviews(h: *mut SrsCoreHandle, profile: &str) -> i64 {
    run(h, profile, "profile_footprint", T1, json!({}), &[])["reviews"]
        .as_i64()
        .unwrap()
}

#[test]
fn preview_lists_the_notes_whose_content_differs() {
    let l = lib("cm-preview", true);
    let v = preview(&l);
    assert_eq!(v["bound"], json!(true), "{v}");
    assert_eq!(v["shared"], json!(1), "{v}");
    assert_eq!(v["added"], json!(1), "{v}");
    assert_eq!(v["from"]["reviews"], json!(1), "{v}");
    let cs = v["conflicts"].as_array().unwrap();
    assert_eq!(cs.len(), 1, "{v}");
    let c = &cs[0];
    assert_eq!(c["note"], json!(l.i.note));
    assert_eq!(c["guid"], json!(GUID));
    assert_eq!(c["typeDiffers"], json!(false));
    assert_eq!(c["deletedDiffers"], json!(false));
    assert_eq!(c["newer"], json!("from"), "{c}");
    assert_eq!(c["into"]["typeName"], json!(format!("类型 {NT_NUM}")));
    assert_eq!(
        c["fields"],
        json!([{"field": l.i.field, "name": format!("Expression {NT_NUM}"), "into": "鳥", "from": "鯨"}])
    );
    ffsrs_store_close(l.h);
}

#[test]
fn merging_keeps_the_shared_value_by_default_and_keeps_every_review() {
    let l = lib("cm-default", true);
    let info_a = run(l.h, A, "identity", T1, json!({}), &[]);
    assert_eq!((reviews(l.h, A), reviews(l.h, B)), (1, 1));
    let v = merge(&l, json!({}));
    assert_eq!(v["merged"], json!(true), "{v}");
    assert_eq!(v["outcome"], json!("joined"), "{v}");
    assert_eq!(v["conflicts"], json!(1), "{v}");
    assert_eq!(v["keptFrom"], json!(0), "{v}");
    // A 的值较新：并集里它胜，默认保留共享库要写回 B 的值。
    assert_eq!(v["rewritten"], json!(1), "{v}");
    assert_eq!(v["bindingChanged"]["profile"], json!(B), "{v}");
    assert_eq!(reviews(l.h, B), 2, "两边的复习日志都在");
    let fp = run(l.h, B, "profile_footprint", T1, json!({}), &[]);
    assert_eq!(fp["notes"], json!(2), "只在 A 的笔记进了 B：{fp}");
    let info = run(l.h, B, "collection_info", T1, json!({}), &[]);
    let joins = info["joins"].as_array().unwrap();
    assert_eq!(joins.len(), 1, "{info}");
    assert_eq!(joins[0]["from"], info_a["collection"], "{info}");
    assert_eq!(
        run(l.h, B, "profile_uids", T1, json!({}), &[])["uids"],
        json!([B]),
        "A 的集合没了"
    );
    // 墓碑：并入后列出，收尾删掉。
    let m = run(l.h, B, "collection_merges", T1, json!({}), &[]);
    assert_eq!(m["merges"].as_array().unwrap().len(), 1, "{m}");
    assert_eq!(m["merges"][0]["from"], json!(A), "{m}");
    assert_eq!(m["merges"][0]["into"], json!(B), "{m}");
    assert_eq!(m["merges"][0]["collection"], info_a["collection"], "{m}");
    let d = run(l.h, B, "collection_merge_done", T1, json!({"from": A}), &[]);
    assert_eq!(d["cleared"], json!(1), "{d}");
    let m = run(l.h, B, "collection_merges", T1, json!({}), &[]);
    assert_eq!(m["merges"], json!([]), "{m}");
    let field = format!("f/{}", l.i.field);
    let note = l.i.note.clone();
    assert_eq!(value_after(l, &note, &field).as_deref(), Some("\"鳥\""));
}

/// 内核并完、app 还没恢复继承（墓碑在）时，经被并入库的 uid 打开（`identity`）明确失败、不会悄悄给它另建一个空集合
/// （否则之后在上面制的卡收尾时成了看不见的孤儿）；收尾删了墓碑之后照常能建。
#[test]
fn an_unfinished_merge_refuses_to_recreate_the_merged_library() {
    let l = lib("cm-tombstone", false);
    let v = merge(&l, json!({}));
    assert_eq!(v["merged"], json!(true), "{v}");
    let e = try_run(l.h, A, "identity", T1 + 10, json!({}), &[]).unwrap_err();
    assert!(e.contains("was merged into") && e.contains(B), "{e}");
    assert_eq!(
        run(l.h, B, "profile_uids", T1, json!({}), &[])["uids"],
        json!([B]),
        "被拒的 identity 什么都没建"
    );
    run(l.h, B, "collection_merge_done", T1, json!({"from": A}), &[]);
    let info = run(l.h, A, "identity", T1 + 20, json!({}), &[]);
    assert!(info["collection"].is_string(), "{info}");
}

#[test]
fn choosing_the_merged_library_writes_its_value_back() {
    // B 的值较新：并集里 B 胜，选了 A 要写回 A 的值。
    let l = lib("cm-from", false);
    let note = l.i.note.clone();
    let v = merge(&l, json!({ note.clone(): "from" }));
    assert_eq!(v["keptFrom"], json!(1), "{v}");
    assert_eq!(v["rewritten"], json!(1), "{v}");
    let field = format!("f/{}", l.i.field);
    assert_eq!(value_after(l, &note, &field).as_deref(), Some("\"鯨\""));
}

#[test]
fn a_note_type_conflict_is_listed_and_the_chosen_type_is_written_back() {
    let l = lib("cm-type", true);
    // A 把共有笔记换成它自己的第二个类型（只在 A 有）。
    let mut items = note_type(A, &l.i.nt2, NT2_NUM, &l.i.field2, None);
    items.push(edit(A, "note", &l.i.note, "noteType", json!(l.i.nt2)));
    items.push(edit(
        A,
        "note",
        &l.i.note,
        &format!("f/{}", l.i.field2),
        json!("新"),
    ));
    let v = run(l.h, A, "apply", T1 + 90_000, json!({}), &items);
    assert_eq!(v["foreign"], json!([]), "{v}");
    let p = preview(&l);
    let c = &p["conflicts"][0];
    assert_eq!(c["typeDiffers"], json!(true), "{p}");
    assert_eq!(c["into"]["type"], json!(l.i.nt), "{p}");
    assert_eq!(c["from"]["type"], json!(l.i.nt2), "{p}");
    assert_eq!(
        c["from"]["typeName"],
        json!(format!("类型 {NT2_NUM}")),
        "{p}"
    );
    merge(&l, json!({}));
    let note = l.i.note.clone();
    let nt = l.i.nt.clone();
    assert_eq!(
        value_after(l, &note, "noteType"),
        Some(json!(nt).to_string()),
        "默认保留共享库的类型"
    );
}

#[test]
fn refusals_roll_everything_back() {
    let l = lib("cm-refuse", true);
    let before = run(l.h, A, "identity", T1, json!({}), &[]);
    for bad in [
        json!({ l.i.note.clone(): "both" }),
        json!({ "0193a1b2-0000-7000-8000-00000000ffff": "from" }),
    ] {
        let e = try_run(
            l.h,
            B,
            "collection_merge",
            T1 + 120_000,
            merge_req(bad.clone()),
            &[],
        );
        assert!(e.is_err(), "{bad}: {e:?}");
    }
    let e = try_run(
        l.h,
        B,
        "collection_merge",
        T1,
        json!({"from": B, "into": B}),
        &[],
    );
    assert!(e.is_err(), "{e:?}");
    assert_eq!(run(l.h, A, "identity", T1, json!({}), &[]), before);
    assert_eq!(reviews(l.h, A), 1);
    assert_eq!(
        run(l.h, B, "collection_merges", T1, json!({}), &[])["merges"],
        json!([])
    );
    ffsrs_store_close(l.h);
}

#[test]
fn a_library_never_opened_on_this_device_has_nothing_to_merge() {
    let dir = tempdir::new("cm-unbound");
    let h = open(&dir.0, 0).unwrap();
    ready(h, B);
    let p = run(
        h,
        B,
        "collection_merge_preview",
        T1,
        json!({"from": A, "into": B}),
        &[],
    );
    assert_eq!(p["bound"], json!(false), "{p}");
    let v = run(
        h,
        B,
        "collection_merge",
        T1,
        json!({"from": A, "into": B}),
        &[],
    );
    assert_eq!(v["merged"], json!(false), "{v}");
    assert_eq!(
        run(h, B, "collection_merges", T1, json!({}), &[])["merges"],
        json!([])
    );
    ffsrs_store_close(h);
}

#[test]
fn collection_merge_statements_use_their_keys() {
    let dir = tempdir::new("cm-plan");
    let h = open(&dir.0, 0).unwrap();
    ready(h, B);
    ffsrs_store_close(h);
    let c = rusqlite::Connection::open(dir.0.join(crate::store::gen4::files::GEN4_FILE)).unwrap();
    for q in [super::MERGED_MARKS_SQL, super::SHARED_NOTES_SQL] {
        let mut stmt = c.prepare(&format!("EXPLAIN QUERY PLAN {q}")).unwrap();
        let mut rows = stmt.raw_query();
        let mut plan = Vec::new();
        while let Some(r) = rows.next().unwrap() {
            plan.push(r.get::<_, String>(3).unwrap());
        }
        assert!(
            plan.iter().all(|l| l.starts_with("SEARCH")),
            "{q}: {plan:?}"
        );
    }
}
