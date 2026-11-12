//! 条件写笔记字段的意图命令 `note_fields_if`（批量改字段的落计划 / 撤销）：比对现值 + 写，**一条命令、一笔**。
//!
//! 以前比对在 Dart：落计划在独占区里读一遍笔记视图、逐项比 `before`，再发一条 `apply`；撤销连独占区都没有（读与写
//! 之间可被别的写入插进来）。现在现值由内核在写锁里物化（[caches::note_infos]，与 Dart `SrsDbStore.notes` 同一份
//! 寄存器视图），比对与写入之间没有别的写入。
//!
//! 输入（blob，JSON 数组）每项 `{"n": 笔记 ID, "f": 字段 ID, "x": 期望的现值, "v": 要写的值}`。两种模式：
//! - `"note"`（落计划）：笔记不存在 / 已删除 / 它名下任一项现值 ≠ `x` → 整条笔记拒绝、一项都不写（同一笔记的几个字段
//!   要么一起写、要么都不写——不把卡型开关写成半套）；
//! - `"field"`（撤销）：笔记不存在 / 已删除 → 它的项都不写；否则逐项，现值 ≠ `x` 的那一项不写（笔记计入拒绝），其余
//!   照写。
//!
//! 通过的项拼成 `apply` 的输入（实体按首次出现的顺序、同一实体内字段按首次出现的顺序、同一字段后者为准——Dart
//! `editFieldsBatch` 的分组），值没变的跳过（[registers::write_is_noop]），旧版时钟每条走一步。

use std::collections::{HashMap, HashSet};

use rusqlite::Connection;
use serde_json::{Value, json};

use super::{LegacyApply, apply_local_on, config};
use crate::registers;
use crate::store::caches;

/// 测试注入：请求带 `failAfter: "apply"` 时在写完之后报错（验证整笔回滚；生产调用方不带）。
fn fail_after(req: &Value, stage: &str) -> Result<(), String> {
    if req["failAfter"].as_str() == Some(stage) {
        return Err(format!("note_fields_if: injected failure after {stage}"));
    }
    Ok(())
}

/// 输入的一项。
struct Item<'a> {
    note: &'a str,
    field: &'a str,
    expect: &'a str,
    value: &'a Value,
}

fn parse<'a>(items: &'a [Value]) -> Result<Vec<Item<'a>>, String> {
    items
        .iter()
        .map(|it| {
            Ok(Item {
                note: it["n"].as_str().ok_or("note_fields_if: missing n")?,
                field: it["f"].as_str().ok_or("note_fields_if: missing f")?,
                expect: it["x"].as_str().ok_or("note_fields_if: missing x")?,
                value: it.get("v").ok_or("note_fields_if: missing v")?,
            })
        })
        .collect()
}

/// `note_fields_if` 的本体（见文件头）：在调用方的写连接、调用方开的 SAVEPOINT 里做。[req]：
/// `{"mode": "note"|"field", "legacyDevice", "tickNow", "ts"?}`。回包与 `apply` 同形，另带 `rejected`：被拒的笔记
/// （去重、按首次出现的顺序）。
pub(crate) fn note_fields_if_on(
    c: &Connection,
    profile: &str,
    now: i64,
    req: &Value,
    items: &[Value],
) -> Result<Value, String> {
    let whole_note = match req["mode"].as_str() {
        Some("note") => true,
        Some("field") => false,
        other => return Err(format!("note_fields_if: bad mode {other:?}")),
    };
    let items = parse(items)?;
    // 笔记按首次出现的顺序去重。
    let mut seen: HashSet<&str> = HashSet::new();
    let notes: Vec<String> = items
        .iter()
        .filter(|it| seen.insert(it.note))
        .map(|it| it.note.to_owned())
        .collect();
    // 别的 profile 的笔记按「没有这条笔记」算（ownership.rs）：进 `rejected`，与不存在 / 已删除的笔记同一个回答。
    let mut owners = super::ownership::Seen::new();
    let mut views: HashMap<String, caches::NoteInfo> = HashMap::new();
    for chunk in notes.chunks(500) {
        for n in caches::note_infos(c, chunk)? {
            if super::ownership::foreign_seen(
                c,
                profile,
                crate::sync2::op::EntKind::Note,
                &n.id,
                &mut owners,
            )? {
                continue;
            }
            views.insert(n.id.clone(), n);
        }
    }
    let live = |id: &str| views.get(id).filter(|n| n.deleted_at.is_none());
    let mut rejected: Vec<&str> = Vec::new();
    let mut rejected_set: HashSet<&str> = HashSet::new();
    let mut reject = |id| {
        if rejected_set.insert(id) {
            rejected.push(id);
        }
    };
    // 逐项的去留（`field` 模式）；`note` 模式下面再按整条笔记筛。
    let mut pass: Vec<bool> = Vec::with_capacity(items.len());
    for it in &items {
        let ok = live(it.note).is_some_and(|n| n.field(it.field) == it.expect);
        if !ok {
            reject(it.note);
        }
        pass.push(ok);
    }
    drop(reject);
    // 要写的：(笔记, [(字段, 值)])，分组规则见文件头。
    let mut writes: Vec<(&str, Vec<(&str, &Value)>)> = Vec::new();
    let mut at: HashMap<&str, usize> = HashMap::new();
    for (it, ok) in items.iter().zip(&pass) {
        if whole_note && rejected_set.contains(it.note) || !*ok {
            continue;
        }
        let i = *at.entry(it.note).or_insert_with(|| {
            writes.push((it.note, Vec::new()));
            writes.len() - 1
        });
        match writes[i].1.iter_mut().find(|(f, _)| *f == it.field) {
            Some(slot) => slot.1 = it.value,
            None => writes[i].1.push((it.field, it.value)),
        }
    }
    let ts = req["ts"].as_str().unwrap_or("wall");
    let written: Vec<String> = writes.iter().map(|(n, _)| (*n).to_owned()).collect();
    let edits = config::edits_of(c, "note", &written)?;
    let none = Vec::new();
    let mut input: Vec<Value> = Vec::new();
    for (note, fields) in &writes {
        let stored = config::stored(edits.get(*note).unwrap_or(&none));
        for (field, value) in fields {
            let key = format!("f/{field}");
            if registers::write_is_noop(&stored, &key, value)? {
                continue;
            }
            input.push(json!({
                "e": {"t": "edit", "x": {"p": profile, "k": "note", "e": note, "f": key, "v": value, "ts": ts}},
                "note": Value::Null,
                "clk": "t",
            }));
        }
    }
    let mut v = if input.is_empty() {
        json!({})
    } else {
        let legacy = LegacyApply {
            device: req["legacyDevice"]
                .as_str()
                .ok_or("note_fields_if: missing legacyDevice")?,
            recv_now: None,
            tick_now: req["tickNow"].as_i64(),
            stamps: false,
        };
        apply_local_on(c, profile, now, &input, Some(&legacy))?
    };
    fail_after(req, "apply")?;
    v["rejected"] = json!(rejected);
    Ok(v)
}
