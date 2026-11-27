//! 实体归属闸的并入端到端（第六波 BUG-5005 收口，`writes_owner.rs` 文件头「身份记录：内容寻址的归属」）：同一个库里 A、B
//! 两个集合，A 拿 B 的实体 ID 下手（每种实体一条：笔记、卡、牌组、笔记类型、字段、模板），之后把 A 的集合并进另一台
//! 设备上的 B（`export` → 另一个库 `import` 确认 → `joined`）：B 的每个实体视图（`entity_views`：定义、活着的修改、
//! 标签、日志、缓存行）与并入前逐字相同。合法场景（两个集合各自建了同一份内容、内置实体、牌组备选 ID、迁移库的带盐
//! 别名类）照常写，并入后合成一份。

use std::path::Path;

use serde_json::{Value, json};

use super::{A, B, ops_of, ready, run};
use crate::gen4::op::tests::id;
use crate::gen4_ids::rules;
use crate::store::ffi::{SrsCoreHandle, ffsrs_store_close};
use crate::store::gen4::cmd::dispatch_tests::{T1, open};
use crate::store::gen4::cmd::tests_class;
use crate::store::gen4::cmd::views_tests::entity_view_rows;
use crate::store::gen4::files::OpenMode;
use crate::store::gen4::kernel::G4Core;
use crate::store::sync2::config::default_deck_id;
use crate::store::sync2::tests::{P, tempdir};
use crate::sync2::id::Id;

/// B 的笔记类型的 Anki 编号（ID 由它派生，`rules::note_type`）。
const NT_NUM: i64 = 7001;
const NOTE_GUID: &str = "b-guid";
const DECK_NAME: &str = "B 牌组";

/// B 的实体（规范 ID）。
struct Ids {
    nt: String,
    field: String,
    tmpl: String,
    deck: String,
    note: String,
    card: String,
}

fn ids() -> Ids {
    let nt = rules::note_type(rules::CANONICAL, NT_NUM);
    let field = rules::field(&nt, 1);
    let tmpl = rules::template(&nt, 1);
    let note = rules::note(rules::CANONICAL, NOTE_GUID);
    Ids {
        nt: nt.text(),
        field: field.text(),
        tmpl: tmpl.text(),
        deck: rules::deck(rules::CANONICAL, DECK_NAME).text(),
        card: rules::card(&note, &tmpl, 0).text(),
        note: note.text(),
    }
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

fn nt_record(profile: &str, id: &str, num: i64, kind: &str, created: i64) -> Value {
    entity(
        profile,
        "notetype",
        id,
        json!({"ankiNum": num, "ntKind": kind, "createdAt": created}),
    )
}

fn note_record(profile: &str, id: &str, guid: &str, nt: &str, created: i64) -> Value {
    entity(
        profile,
        "note",
        id,
        json!({"guid": guid, "noteTypeId": nt, "createdAt": created}),
    )
}

/// [profile] 建出 B 那一套内容（笔记类型 + 字段 + 模板、牌组、笔记 + 字段值 + 标签 + 牌组）：B 自己建，或 A 独立建同一份
/// （合法场景，`created` 不同：`createdAt` 不算结构）。
fn content(profile: &str, i: &Ids, created: i64, value: &str) -> Vec<Value> {
    vec![
        nt_record(profile, &i.nt, NT_NUM, "standard", created),
        edit(profile, "notetype", &i.nt, "name", json!("B 类型")),
        edit(
            profile,
            "notetype",
            &i.nt,
            &format!("fieldDef/{}", i.field),
            json!({"name": "Expression", "ord": 0}),
        ),
        edit(
            profile,
            "notetype",
            &i.nt,
            &format!("tmplDef/{}", i.tmpl),
            json!({"name": "Card 1", "ord": 0, "front": format!("{{{{fld:{}}}}}", i.field), "back": ""}),
        ),
        entity(profile, "deck", &i.deck, json!({"createdAt": 0})),
        edit(profile, "deck", &i.deck, "name", json!(DECK_NAME)),
        note_record(profile, &i.note, NOTE_GUID, &i.nt, created),
        edit(
            profile,
            "note",
            &i.note,
            &format!("f/{}", i.field),
            json!(value),
        ),
        edit(profile, "note", &i.note, "deck", json!(i.deck)),
        edit(profile, "note", &i.note, "tags", json!(["b"])),
    ]
}

/// 同一个库里的 A、B；B 建好了它的内容（[content]），A 是空的集合。
struct Lib {
    dir: tempdir::Dir,
    h: *mut SrsCoreHandle,
    i: Ids,
}

fn lib(tag: &str) -> Lib {
    let dir = tempdir::new(tag);
    let h = open(&dir.0, 0).unwrap();
    ready(h, B);
    ready(h, A);
    let i = ids();
    let v = run(h, B, "apply", json!({}), &content(B, &i, 10, "鳥"));
    assert_eq!(v["foreign"], json!([]), "{v}");
    Lib { dir, h, i }
}

/// [items] 以 A 的身份写：一项都不落、全进 `foreign`，A 的日志一条不多。
fn refused(l: &Lib, items: &[Value]) {
    let before = ops_of(&l.dir.0, A);
    let v = run(l.h, A, "apply", json!({}), items);
    let all: Vec<usize> = (0..items.len()).collect();
    assert_eq!(v["foreign"], json!(all), "{v}");
    assert_eq!(v["landed"], json!(vec![false; items.len()]), "{v}");
    assert_eq!(
        ops_of(&l.dir.0, A),
        before,
        "A 的日志里不能有指向 B 的实体的操作"
    );
}

fn export(h: *mut SrsCoreHandle, profile: &str, dir: &Path) -> (Value, String) {
    let path = dir.join(format!("ops-{}.bin", Id::random().text()));
    let path = path.to_str().unwrap().to_owned();
    let v = run(h, profile, "export", json!({"path": path}), &[]);
    (v, path)
}

fn import(h: *mut SrsCoreHandle, profile: &str, exp: &(Value, String)) -> Value {
    let (v, path) = exp;
    let manifest = json!({"collection": v["collection"], "dir": v["dir"], "salts": v["salts"], "peers": v["peers"]});
    run(
        h,
        profile,
        "import",
        json!({"path": path, "manifest": manifest, "confirmed": true}),
        &[],
    )
}

/// [profile] 的集合里 [kind] 种实体 [ids] 的视图（`entity_views` 的 `v` 文本，按请求顺序）。
fn views(h: *mut SrsCoreHandle, profile: &str, kind: &str, ids: &[&str]) -> Vec<String> {
    let req =
        json!({"op": "entity_views", "profile": profile, "now": T1, "kind": kind, "ids": ids});
    entity_view_rows(h, &req)
        .into_iter()
        .map(|(_, _, v)| v)
        .collect()
}

/// B 的四种实体的视图（字段、模板在笔记类型的视图里）。
fn b_views(h: *mut SrsCoreHandle, i: &Ids) -> Vec<Vec<String>> {
    vec![
        views(h, B, "note", &[&i.note]),
        views(h, B, "card", &[&i.card]),
        views(h, B, "deck", &[&i.deck]),
        views(h, B, "notetype", &[&i.nt]),
    ]
}

/// 另一台设备上的 B：先拿到 B 的全部数据（[l] 里 B 的导出导进一个空库，`bound`），再确认并入 A 的集合（`joined`）。
/// 返回 (并入前的视图, 并入后的视图, 另一个库)。
fn merge(
    l: &Lib,
) -> (
    Vec<Vec<String>>,
    Vec<Vec<String>>,
    tempdir::Dir,
    *mut SrsCoreHandle,
) {
    let work = tempdir::new("g9-owner-merge-work");
    let remote = tempdir::new("g9-owner-merge-remote");
    let h2 = open(&remote.0, 0).unwrap();
    let got = import(h2, B, &export(l.h, B, &work.0));
    assert_eq!(got["outcome"], json!("bound"), "{got}");
    // 缓存层（卡片行）按这台设备的配置物化，视图里带上笔记 / 卡的缓存行。
    let caches = json!({"defaultDeck": default_deck_id(B)});
    run(h2, B, "cache_config_set", json!({"caches": caches}), &[]);
    let before = b_views(h2, &l.i);
    assert!(
        before.iter().all(|v| v.len() == 1),
        "B 的四个实体都在：{before:?}"
    );
    let got = import(h2, B, &export(l.h, A, &work.0));
    assert_eq!(got["outcome"], json!("joined"), "{got}");
    let after = b_views(h2, &l.i);
    drop(work);
    (before, after, remote, h2)
}

/// 下手之后并入：B 的实体一个都没变。
fn merged_unchanged(l: Lib) {
    let (before, after, _remote, h2) = merge(&l);
    assert_eq!(after, before, "A 的写不能在并入后改到 B 的实体");
    ffsrs_store_close(h2);
    ffsrs_store_close(l.h);
}

/// 笔记：伪造一条用 B 的真实 guid（ID 能自证）、只换了笔记类型的身份记录（残余二），带同批修改；单发修改；单发标签。
/// `createdAt: 1` 让这条记录的规范 JSON 比 B 的小——漏过闸的话并入时它会顶掉 B 的定义。
#[test]
fn a_note_of_another_collection_stays_after_the_merge() {
    let l = lib("g9-merge-note");
    let i = &l.i;
    let other = rules::note_type(rules::CANONICAL, 9009).text();
    refused(
        &l,
        &[
            note_record(A, &i.note, NOTE_GUID, &other, 1),
            edit(
                A,
                "note",
                &i.note,
                &format!("f/{}", i.field),
                json!("被 A 改"),
            ),
        ],
    );
    refused(&l, &[edit(A, "note", &i.note, "tags", json!(["串了"]))]);
    refused(
        &l,
        &[edit(
            A,
            "note",
            &i.note,
            "deck",
            json!(rules::builtin_default_deck(rules::CANONICAL).text()),
        )],
    );
    merged_unchanged(l);
}

/// 卡：卡片身份记录（没有合法来源）+ 同批旗标；单发暂停；`sched` 重置。
#[test]
fn a_card_of_another_collection_stays_after_the_merge() {
    let l = lib("g9-merge-card");
    let i = &l.i;
    refused(
        &l,
        &[
            entity(A, "card", &i.card, json!({"createdAt": 1})),
            edit(A, "card", &i.card, "flag", json!(3)),
        ],
    );
    refused(&l, &[edit(A, "card", &i.card, "suspended", json!(true))]);
    let before = ops_of(&l.dir.0, A);
    let extra = json!({"at": T1, "utcOff": 0, "rollover": 4, "ts": "anchored", "items": [{"a": "reset", "card": i.card}]});
    let v = run(l.h, A, "sched", extra, &[]);
    assert_eq!(v["logs"], json!([]), "{v}");
    assert_eq!(ops_of(&l.dir.0, A), before);
    merged_unchanged(l);
}

/// 牌组（残余一）：身份记录 + 同批改名（名字对不上 ID，自证不了）——以前牌组身份记录不判、进同批要建的实体，替改名作保；
/// 单发身份记录（没有名字）；单发改名。
#[test]
fn a_deck_of_another_collection_stays_after_the_merge() {
    let l = lib("g9-merge-deck");
    let i = &l.i;
    refused(
        &l,
        &[
            entity(A, "deck", &i.deck, json!({"createdAt": 0})),
            edit(A, "deck", &i.deck, "name", json!("被 A 改")),
        ],
    );
    refused(&l, &[entity(A, "deck", &i.deck, json!({"createdAt": 0}))]);
    refused(&l, &[edit(A, "deck", &i.deck, "name", json!("被 A 改"))]);
    // 冒充内置默认牌组：`builtin` 只认规范常量。
    refused(
        &l,
        &[entity(A, "deck", &i.deck, json!({"builtin": "default"}))],
    );
    merged_unchanged(l);
}

/// 笔记类型（残余一 + 二）：Anki 编号对不上 ID 的记录 + 同批改名；编号对得上、种类换成 cloze 的记录（与 B 的定义冲突，
/// `createdAt: 1` 让它的规范 JSON 更小）+ 同批改名；单发改名。
#[test]
fn a_note_type_of_another_collection_stays_after_the_merge() {
    let l = lib("g9-merge-nt");
    let i = &l.i;
    refused(
        &l,
        &[
            nt_record(A, &i.nt, 9009, "standard", 1),
            edit(A, "notetype", &i.nt, "name", json!("被 A 改")),
        ],
    );
    refused(
        &l,
        &[
            nt_record(A, &i.nt, NT_NUM, "cloze", 1),
            edit(A, "notetype", &i.nt, "name", json!("被 A 改")),
        ],
    );
    refused(&l, &[edit(A, "notetype", &i.nt, "name", json!("被 A 改"))]);
    // B 的存量笔记类型（随机 ID，不按 Anki 编号派生）：A 抄一份内容逐字相同的记录也自证不了。
    let legacy = "0193a1b2-0000-7000-8000-00000000c7c7";
    let v = run(
        l.h,
        B,
        "apply",
        json!({}),
        &[nt_record(B, legacy, 4242, "standard", 3)],
    );
    assert_eq!(v["foreign"], json!([]), "{v}");
    refused(
        &l,
        &[
            nt_record(A, legacy, 4242, "standard", 3),
            edit(A, "notetype", legacy, "name", json!("被 A 改")),
        ],
    );
    merged_unchanged(l);
}

/// 字段：笔记类型上的 `fieldDef/` 修改（跟着笔记类型的归属走）——单发、带冲突的笔记类型记录同批发。
#[test]
fn a_field_of_another_collection_stays_after_the_merge() {
    let l = lib("g9-merge-field");
    let i = &l.i;
    let key = format!("fieldDef/{}", i.field);
    let renamed = json!({"name": "被 A 改", "ord": 0});
    refused(&l, &[edit(A, "notetype", &i.nt, &key, renamed.clone())]);
    refused(
        &l,
        &[
            nt_record(A, &i.nt, NT_NUM, "cloze", 1),
            edit(A, "notetype", &i.nt, &key, renamed),
        ],
    );
    merged_unchanged(l);
}

/// 模板：笔记类型上的 `tmplDef/` 修改——单发、带自证不了的笔记类型记录同批发。
#[test]
fn a_template_of_another_collection_stays_after_the_merge() {
    let l = lib("g9-merge-tmpl");
    let i = &l.i;
    let key = format!("tmplDef/{}", i.tmpl);
    let changed = json!({"name": "被 A 改", "ord": 0, "front": "A", "back": ""});
    refused(&l, &[edit(A, "notetype", &i.nt, &key, changed.clone())]);
    refused(
        &l,
        &[
            nt_record(A, &i.nt, 9009, "standard", 1),
            edit(A, "notetype", &i.nt, &key, changed),
        ],
    );
    merged_unchanged(l);
}

/// 合法场景：A 独立建了同一份内容（同一个 Anki 编号与种类的笔记类型、同名牌组、同一个 guid 与笔记类型的笔记；`createdAt`
/// 不同）、内置默认牌组与内置笔记类型、重发自己已有的定义：全部照写。并入后合成一份：每个实体一个视图，两边写的值都在
/// 历史里（并集）。
#[test]
fn the_same_content_built_by_two_collections_merges_into_one() {
    let l = lib("g9-merge-same");
    let i = &l.i;
    let v = run(l.h, A, "apply", json!({}), &content(A, i, 11, "川"));
    assert_eq!(v["foreign"], json!([]), "{v}");
    let n = v["landed"].as_array().unwrap().len();
    assert_eq!(v["landed"], json!(vec![true; n]), "{v}");
    // 重发自己已有的定义：照写（不算「落了」）。
    let v = run(
        l.h,
        A,
        "apply",
        json!({}),
        &[note_record(A, &i.note, NOTE_GUID, &i.nt, 11)],
    );
    assert_eq!(v["foreign"], json!([]), "{v}");
    // 内置实体在每个集合里是同一个常量。
    let builtin_nt_num = rules::builtin_note_type_anki_num("fushi_card");
    let builtin_nt = rules::note_type(rules::CANONICAL, builtin_nt_num).text();
    let default_deck = rules::builtin_default_deck(rules::CANONICAL).text();
    let builtins = |p: &str| {
        vec![
            entity(p, "deck", &default_deck, json!({"builtin": "default"})),
            entity(
                p,
                "notetype",
                &builtin_nt,
                json!({"ankiNum": builtin_nt_num, "ntKind": "standard", "builtin": "fushi_card"}),
            ),
        ]
    };
    let v = run(l.h, B, "apply", json!({}), &builtins(B));
    assert_eq!(v["foreign"], json!([]), "{v}");
    let v = run(l.h, A, "apply", json!({}), &builtins(A));
    assert_eq!(v["foreign"], json!([]), "{v}");
    assert_eq!(v["landed"], json!([true, true]), "{v}");

    let (_before, after, _remote, h2) = merge(&l);
    assert!(after.iter().all(|v| v.len() == 1), "合成一份：{after:?}");
    let hist = run(
        h2,
        B,
        "history",
        json!({"kind": "note", "entity": i.note}),
        &[],
    );
    let values: Vec<String> = hist
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|e| e.get("value").map(Value::to_string))
        .collect();
    assert!(
        values.contains(&"\"鳥\"".to_owned()) && values.contains(&"\"川\"".to_owned()),
        "两边的写都在：{values:?}"
    );
    ffsrs_store_close(h2);
    ffsrs_store_close(l.h);
}

/// 合法场景：牌组备选 ID（Dart `deckIdForNew`：全名的规范 ID 已被本集合别的牌组占着时取第 n 个备选）。B 有「日本語」的
/// 第 1 个备选；A 的「日本語」规范 ID 被 A 自己改了名的牌组占着，新建的「日本語」也落在第 1 个备选上——能自证，照写。
/// 对照：A 那边规范 ID 没被占时，同一条备选 ID 的记录自证不了。
#[test]
fn deck_alternates_are_derived_from_the_collections_own_decks() {
    let l = lib("g9-merge-alt");
    let path = "日本語";
    let base = rules::deck(rules::CANONICAL, path).text();
    let alt = rules::deck_alternate(rules::CANONICAL, path, 1).text();
    let deck = |p: &str, id: &str, name: &str| {
        vec![
            entity(p, "deck", id, json!({"createdAt": 0})),
            edit(p, "deck", id, "name", json!(name)),
        ]
    };
    let v = run(l.h, B, "apply", json!({}), &deck(B, &alt, path));
    assert_eq!(v["foreign"], json!([]), "{v}");
    // A 的规范 ID 还空着：备选 ID 自证不了。
    refused(&l, &deck(A, &alt, path));
    // A 先有了规范 ID 的牌组（改名成别的），再建「日本語」：落在第 1 个备选上。
    let v = run(l.h, A, "apply", json!({}), &deck(A, &base, "改过名"));
    assert_eq!(v["foreign"], json!([]), "{v}");
    let v = run(l.h, A, "apply", json!({}), &deck(A, &alt, path));
    assert_eq!(v["foreign"], json!([]), "{v}");
    assert_eq!(v["landed"], json!([true, true]), "{v}");
    ffsrs_store_close(l.h);
}

/// 合法场景：子牌组的 ID 按「父牌组全名::名字」派生（Dart `deckIdForNew`）。B 有「父」与「父::子」；A 独立建同样的两层：
/// 子牌组的记录与同批的名字、父牌组（A 牌组树里的「父」）重算得出，照写。对照：父牌组不对（重算成别的全名）就自证不了。
#[test]
fn a_child_deck_is_derived_from_its_parents_full_name() {
    let l = lib("g9-merge-child");
    let parent = rules::deck(rules::CANONICAL, "父").text();
    let child = rules::deck(rules::CANONICAL, "父::子").text();
    let deck = |p: &str, id: &str, name: &str, up: Option<&str>| {
        let mut v = vec![
            entity(p, "deck", id, json!({"createdAt": 0})),
            edit(p, "deck", id, "name", json!(name)),
        ];
        if let Some(up) = up {
            v.push(edit(p, "deck", id, "parent", json!(up)));
        }
        v
    };
    let v = run(l.h, B, "apply", json!({}), &deck(B, &parent, "父", None));
    assert_eq!(v["foreign"], json!([]), "{v}");
    let v = run(
        l.h,
        B,
        "apply",
        json!({}),
        &deck(B, &child, "子", Some(&parent)),
    );
    assert_eq!(v["foreign"], json!([]), "{v}");
    // A 还没有「父」：子牌组按「子」或 B 的牌组 ID 当父牌组都重算不出「父::子」。
    refused(&l, &deck(A, &child, "子", Some(&parent)));
    let v = run(l.h, A, "apply", json!({}), &deck(A, &parent, "父", None));
    assert_eq!(v["foreign"], json!([]), "{v}");
    let v = run(
        l.h,
        A,
        "apply",
        json!({}),
        &deck(A, &child, "子", Some(&parent)),
    );
    assert_eq!(v["foreign"], json!([]), "{v}");
    assert_eq!(v["landed"], json!([true, true, true]), "{v}");
    ffsrs_store_close(l.h);
}

/// 第 1 条（重发本集合已有的定义）：A 的集合经 `.fushisrs` 导入（不过闸的远端操作）带进来一个与 B 同号、自证不了的笔记
/// （库里两个集合各有一份，存量冲突）。A 原样重发自己的那份照写——它什么都不新带；换一个 `createdAt` 的就是新内容，自证
/// 不了，不写。也钉住 `.fushisrs` 导入进有别的集合的库照常落（闸不在导入路径上）。
#[test]
fn re_sending_an_own_definition_is_allowed_where_another_collection_has_the_id() {
    let i = ids();
    let shared = "0193a1b2-0000-7000-8000-0000000051a1";
    // A 在另一个库里（那里只有 A 一个集合）建了同号的笔记，再把整个集合导进来。
    let other = tempdir::new("g9-merge-resend-a");
    let h2 = open(&other.0, 0).unwrap();
    ready(h2, A);
    let mine = note_record(A, shared, "a", &i.nt, 2);
    let v = run(h2, A, "apply", json!({}), std::slice::from_ref(&mine));
    assert_eq!(v["landed"], json!([true]), "{v}");
    let work = tempdir::new("g9-merge-resend-w");
    let exported = export(h2, A, &work.0);
    ffsrs_store_close(h2);
    let fresh = tempdir::new("g9-merge-resend-l");
    let h = open(&fresh.0, 0).unwrap();
    ready(h, B);
    let v = run(
        h,
        B,
        "apply",
        json!({}),
        &[note_record(B, shared, "b", &i.nt, 1)],
    );
    assert_eq!(v["foreign"], json!([]), "{v}");
    let got = import(h, A, &exported);
    assert_eq!(got["outcome"], json!("bound"), "{got}");
    let v = run(h, A, "apply", json!({}), std::slice::from_ref(&mine));
    assert_eq!(v["foreign"], json!([]), "{v}");
    let v = run(
        h,
        A,
        "apply",
        json!({}),
        &[note_record(A, shared, "a", &i.nt, 3)],
    );
    assert_eq!(v["foreign"], json!([0]), "{v}");
    ffsrs_store_close(h);
}

/// 合法场景：迁移来的集合（协议 3 存量：同一份 Anki 内容在两个盐下各有一份，别名层归到规范 ID，`tests_class.rs` 的双盐
/// 场景）与同库的新 profile A。A 独立导入同一份内容（同一个 guid、同一个 Anki 编号的笔记类型，ID 按规范规则派生——迁移
/// 集合里只有别名类的规范 ID 指向它，没有这个原值）照写；换了笔记类型的不写（迁移集合的定义按它自己的别名表归一后比）。
#[test]
fn a_migrated_collections_alias_classes_are_compared_by_their_canonical_definition() {
    let dir = tempdir::new("g9-owner-alias");
    let w = {
        let c = G4Core::open(&dir.0, OpenMode::Primary).unwrap();
        let col = c.write(|t| t.bind(P, &id(0xc0), "0-dir")).unwrap();
        let w = c.write(|t| Ok(tests_class::land(t, col))).unwrap();
        c.close();
        w
    };
    let h = open(&dir.0, 0).unwrap();
    ready(h, A);
    let c_nt = rules::note_type(rules::CANONICAL, tests_class::ANKI_NT).text();
    let other = rules::note_type(rules::CANONICAL, tests_class::ANKI_NT + 1).text();
    let before = ops_of(&dir.0, A);
    let v = run(
        h,
        A,
        "apply",
        json!({}),
        &[note_record(A, &w.c_note.text(), "g", &other, 1)],
    );
    assert_eq!(v["foreign"], json!([0]), "{v}");
    assert_eq!(ops_of(&dir.0, A), before);
    let v = run(
        h,
        A,
        "apply",
        json!({}),
        &[
            nt_record(A, &c_nt, tests_class::ANKI_NT, "standard", 7),
            note_record(A, &w.c_note.text(), "g", &c_nt, 7),
        ],
    );
    assert_eq!(v["foreign"], json!([]), "{v}");
    assert_eq!(v["landed"], json!([true, true]), "{v}");
    ffsrs_store_close(h);
}
