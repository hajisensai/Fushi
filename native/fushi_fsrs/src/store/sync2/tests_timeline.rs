//! 时间线恢复按「那一刻的状态」还原每类寄存器（BUG：恢复后笔记类型模板变空）。

use serde_json::{json, Value};

use super::super::tests::{deck_entity, edit, Device, P};
use super::{value_at, vv_at, RestoreTarget};
use crate::sync2::op::EntKind;

const T0: i64 = 1_700_000_000_000;

fn entity(kind: &str, id: &str, d: Value) -> Value {
    json!({"t": "entity", "x": {"id": id, "p": P, "k": kind, "d": d}})
}

/// 某实体现在落库的全部修改记录（json 列）。
fn stored(d: &Device, kind: &str, id: &str) -> Vec<String> {
    d.rows(&format!("SELECT json FROM srs_field_edits WHERE entity_kind = '{kind}' AND entity_id = srs_id('{id}')"))
        .into_iter()
        .skip(1)
        .map(|r| r[0].clone())
        .collect()
}

fn note_type_view(d: &Device, id: &str, payload: &Value, builtin: &Value) -> Value {
    let rows = stored(d, "notetype", id);
    let es: Vec<crate::registers::StoredEdit<'_>> = rows.iter().map(|r| (r.as_str(), None, None)).collect();
    crate::registers::note_type_view_of(payload, &es, builtin).unwrap()
}

fn note_fields(d: &Device, id: &str) -> Value {
    let rows = stored(d, "note", id);
    let es: Vec<crate::registers::StoredEdit<'_>> = rows.iter().map(|r| (r.as_str(), None, None)).collect();
    let v = crate::registers::note_view_of(&json!({"createdAt": 1, "guid": id, "noteTypeId": "NT"}), &es).unwrap();
    v["f"].clone()
}

/// 视图里的模板 / 字段数组（键名以 registers.rs `note_type_view` 为准，找第一个是数组且元素带 `front` / `ord` 的）。
fn list<'v>(v: &'v Value, has: &str) -> &'v Vec<Value> {
    v.as_object()
        .unwrap()
        .values()
        .filter_map(Value::as_array)
        .find(|a| a.first().is_some_and(|x| x.get(has).is_some()) && (has != "ord" || a.first().is_some_and(|x| x.get("front").is_none())))
        .unwrap_or_else(|| panic!("no list with {has} in {v}"))
}

fn templates(v: &Value) -> Vec<(String, String, String, String)> {
    list(v, "front")
        .iter()
        .map(|t| {
            let s = |k: &str| t[k].as_str().unwrap_or_default().to_owned();
            (s("id"), s("name"), s("front"), s("back"))
        })
        .collect()
}

fn fields(v: &Value) -> Vec<(String, String)> {
    list(v, "ord")
        .iter()
        .map(|f| (f["id"].as_str().unwrap_or_default().to_owned(), f["name"].as_str().unwrap_or_default().to_owned()))
        .collect()
}

fn restore(d: &Device, t: i64, now: i64) {
    d.core.sync2_restore(P, &RestoreTarget::At(t), false, now).unwrap();
}

/// 用户现场：内置笔记类型（没有身份记录、模板 / CSS 跟随代码）在还原点之后才被改过模板与 CSS。修复前「那一刻
/// 没有记录」被写成 null：CSS 的 null 恰好回落到代码默认值（看着恢复了），模板的 null 却被当成一份全空的定义盖住
/// 内置模板——编辑页正面 / 背面都空、预览报「正面为空」。
#[test]
fn restore_returns_an_edited_builtin_template_to_the_code_default() {
    let a = Device::new("tl-builtin");
    let builtin = json!({
        "name": "Lapis",
        "css": ".card { color: black }",
        "fields": [{"id": "f1", "name": "Expression", "ord": 0}],
        "templates": [{"id": "t1", "name": "Card 1", "ord": 0, "front": "{{fld:f1}}", "back": "{{FrontSide}}<hr>"}],
        "termFieldId": "f1",
    });
    let payload = json!({"builtin": "lapis", "ntKind": "standard"});
    a.apply(T0, vec![entity("note", "N1", json!({"createdAt": 1, "guid": "N1", "noteTypeId": "NT"}))]);
    let before = note_type_view(&a, "NT", &payload, &builtin);
    let t1 = T0 + 500;
    a.apply(
        T0 + 1000,
        vec![
            edit("notetype", "NT", "tmplDef/t1", json!({"name": "Card 1", "ord": 0, "front": "custom front", "back": "custom back"})),
            edit("notetype", "NT", "css", json!(".card { color: red }")),
            edit("notetype", "NT", "fieldDef/f1", json!({"name": "Word", "ord": 0})),
        ],
    );
    assert_eq!(templates(&note_type_view(&a, "NT", &payload, &builtin))[0].2, "custom front");
    restore(&a, t1, T0 + 2000);
    let after = note_type_view(&a, "NT", &payload, &builtin);
    assert_eq!(templates(&after), templates(&before), "{after}");
    assert_eq!(templates(&after)[0].2, "{{fld:f1}}");
    assert_eq!(fields(&after), fields(&before), "{after}");
    assert_eq!(after, before);
}

/// 普通笔记类型：还原点之后新加的模板 / 字段 / 字段说明在恢复后消失（而不是留下一份没有名字、没有正文的空定义），
/// 之前就有的改回那一刻的内容；笔记之后才填的字段同样消失。
#[test]
fn restore_drops_map_entries_added_after_the_moment() {
    let a = Device::new("tl-map");
    let tpl = |front: &str| json!({"name": "表", "ord": 0, "front": front, "back": "B"});
    a.apply(
        T0,
        vec![
            entity("notetype", "NT", json!({"createdAt": 1, "ntKind": "standard"})),
            edit("notetype", "NT", "name", json!("Mine")),
            edit("notetype", "NT", "fieldDef/f1", json!({"name": "Word", "ord": 0})),
            edit("notetype", "NT", "tmplDef/t1", tpl("{{fld:f1}}")),
            edit("notetype", "NT", "css", json!("old css")),
            entity("note", "N1", json!({"createdAt": 1, "guid": "N1", "noteTypeId": "NT"})),
            edit("note", "N1", "f/f1", json!("孤児院")),
        ],
    );
    let payload = json!({"createdAt": 1, "ntKind": "standard"});
    let before = note_type_view(&a, "NT", &payload, &Value::Null);
    let note_before = note_fields(&a, "N1");
    let t1 = T0 + 500;
    a.apply(
        T0 + 1000,
        vec![
            edit("notetype", "NT", "tmplDef/t1", tpl("changed")),
            edit("notetype", "NT", "tmplDef/t2", json!({"name": "裏", "ord": 1, "front": "x", "back": "y"})),
            edit("notetype", "NT", "fieldDef/f2", json!({"name": "Meaning", "ord": 1})),
            edit("notetype", "NT", "fieldDesc/f1", json!("what goes here")),
            edit("notetype", "NT", "css", json!("new css")),
            edit("note", "N1", "f/f2", json!("meaning")),
        ],
    );
    restore(&a, t1, T0 + 2000);
    let after = note_type_view(&a, "NT", &payload, &Value::Null);
    assert_eq!(templates(&after), templates(&before), "{after}");
    assert_eq!(fields(&after), fields(&before), "{after}");
    assert_eq!(after, before);
    assert_eq!(note_fields(&a, "N1"), note_before);
}

/// 卡片标志按血统继承：新卡（更改笔记类型生成）那一刻没有自己的「挂起」记录、继承前身的挂起；之后取消挂起，
/// 恢复要回到「挂起」——写回继承值，而不是写 null（自己的 null 会挡住继承，结果是没挂起）。
#[test]
fn restore_of_a_card_flag_first_set_later_returns_the_inherited_value() {
    let a = Device::new("tl-card");
    a.apply(T0, vec![edit("card", "C1", "suspended", json!(true)), edit("card", "C2", "historyFrom/C1", json!(true))]);
    let t1 = T0 + 500;
    a.apply(T0 + 1000, vec![edit("card", "C2", "suspended", json!(false)), edit("card", "C2", "flag", json!(3))]);
    restore(&a, t1, T0 + 2000);
    let w = a.core.writer().unwrap();
    assert_eq!(value_at(&w, P, EntKind::Card, "C2", "suspended", None).unwrap(), Some(json!(true)));
    // 血统里也没有的键：写回 null（= 未设）。
    assert_eq!(value_at(&w, P, EntKind::Card, "C2", "flag", None).unwrap(), Some(Value::Null));
}

/// 同类排查的总回归：每类实体 × 每类键（标量 / 对象 / 带子键的映射；之前就有的、之后才有的）恢复后，
/// 每个寄存器的生效值都等于那一刻的（「没有记录」与 null 视为同一状态）。
#[test]
fn restore_brings_every_register_back_to_the_moment() {
    let a = Device::new("tl-all");
    let deck = super::super::config::default_deck_id(P);
    a.apply(
        T0,
        vec![
            deck_entity(&deck),
            edit("deck", &deck, "name", json!("Default")),
            edit("deck", &deck, "limits", json!({"new": 20, "review": 200})),
            edit("deck", &deck, "steps", json!({"learn": [1, 10], "relearn": [10]})),
            edit("deck", &deck, "retention", json!(0.9)),
            entity("notetype", "NT", json!({"createdAt": 1, "ntKind": "standard"})),
            edit("notetype", "NT", "name", json!("Mine")),
            edit("notetype", "NT", "fieldDef/f1", json!({"name": "Word", "ord": 0})),
            edit("notetype", "NT", "tmplDef/t1", json!({"name": "Card 1", "ord": 0, "front": "{{fld:f1}}", "back": "b"})),
            edit("notetype", "NT", "css", json!("css")),
            edit("notetype", "NT", "termField", json!("f1")),
            entity("note", "N1", json!({"createdAt": 1, "guid": "N1", "noteTypeId": "NT"})),
            edit("note", "N1", "f/f1", json!("v1")),
            edit("note", "N1", "tags", json!(["a"])),
            edit("card", "C1", "flag", json!(1)),
        ],
    );
    let t1 = T0 + 500;
    a.apply(
        T0 + 1000,
        vec![
            edit("deck", &deck, "name", json!("Renamed")),
            edit("deck", &deck, "limits", json!({"new": 5, "review": 50})),
            edit("deck", &deck, "maxInterval", json!(30)),
            edit("deck", &deck, "collapsed", json!(true)),
            edit("notetype", "NT", "name", json!("Other")),
            edit("notetype", "NT", "fieldDef/f1", json!({"name": "Term", "ord": 0})),
            edit("notetype", "NT", "fieldDef/f2", json!({"name": "New", "ord": 1})),
            edit("notetype", "NT", "tmplDef/t1", json!({"name": "Card 1", "ord": 0, "front": "", "back": ""})),
            edit("notetype", "NT", "tmplDef/t2", json!({"name": "Card 2", "ord": 1, "front": "x", "back": "y"})),
            edit("notetype", "NT", "css", json!("css2")),
            edit("notetype", "NT", "freqField", json!("f2")),
            edit("note", "N1", "f/f1", json!("v2")),
            edit("note", "N1", "f/f2", json!("added")),
            edit("note", "N1", "deck", json!(deck)),
            edit("note", "N1", "deleted", json!(T0 + 1000)),
            edit("card", "C1", "flag", json!(4)),
            edit("card", "C1", "buried", json!(9)),
        ],
    );
    let regs = a.rows("SELECT DISTINCT kind, srs_idt(entity), what FROM sync2_ent_ops WHERE substr(what, 1, 1) != '#' AND what != 'tags' ORDER BY 1, 2, 3");
    assert!(regs.len() > 20, "{regs:?}");
    let then: Vec<Value> = {
        let w = a.core.writer().unwrap();
        let target = vv_at(&w, P, t1).unwrap();
        regs.iter()
            .skip(1)
            .map(|r| value_at(&w, P, EntKind::parse(&r[0]).unwrap(), &r[1], &r[2], Some(&target)).unwrap().unwrap_or(Value::Null))
            .collect()
    };
    restore(&a, t1, T0 + 2000);
    let w = a.core.writer().unwrap();
    for (r, want) in regs.iter().skip(1).zip(then) {
        let got = value_at(&w, P, EntKind::parse(&r[0]).unwrap(), &r[1], &r[2], None).unwrap().unwrap_or(Value::Null);
        assert!(crate::registers::same_value(&got, &want), "{r:?}: got {got}, want {want}");
    }
    assert_eq!(super::super::semantics::current_tags(&w, P, "N1").unwrap(), vec!["a".to_owned()]);
}
