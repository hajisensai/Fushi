//! 合并重复笔记的意图命令 `merge_notes`（设计 §5.4；Dart `SrsDuplicateNotes.mergeNotes`）：还原点 + 前身链接 + 补空
//! 字段 / 并标签 + 删除被吸收的笔记，**一条命令、一笔**。
//!
//! 以前这是 Dart 在独占区里读两边的笔记与卡、再发的 3 + N 条命令（`checkpoint`、前身链接的 `apply`、保留笔记的
//! `apply`、每条被吸收笔记各一条 `apply`）：中途失败留下半并的笔记。现在读与写都在内核的写锁里，任何一步出错整笔
//! 回滚。写出的修改记录与那几条命令逐条相同、同序（各批写的是互不相干的 (实体, 键)，「值没变不写」按合并前的状态判
//! 结果相同）；旧版时钟每条走一步。

use std::collections::{HashMap, HashSet};

use rusqlite::{Connection, params};
use serde_json::{Value, json};

use super::change::merge_results;
use super::{LegacyApply, append_on, apply_local_on, checkpoint_bodies, config, sql};
use crate::card_cache::is_js_space;
use crate::registers;
use crate::store::caches;

/// Dart `SrsFieldKeys.cardHistoryFromPrefix` / `noteTags` / `deleted`。
const HISTORY_FROM: &str = "historyFrom/";
const KEY_TAGS: &str = "tags";
const KEY_DELETED: &str = "deleted";

/// Dart `String.trim().isEmpty`：`trim` 去掉的空白是 JS `\s` 那一组再加 U+0085。
fn dart_blank(s: &str) -> bool {
    s.chars().all(|c| is_js_space(c) || c == '\u{85}')
}

/// 测试注入：请求带 `failAfter: "apply"` 时在全部写完之后报错（验证整笔回滚；生产调用方不带）。
fn fail_after(req: &Value, stage: &str) -> Result<(), String> {
    if req["failAfter"].as_str() == Some(stage) {
        return Err(format!("merge_notes: injected failure after {stage}"));
    }
    Ok(())
}

/// 一条笔记的卡片缓存行（含隐藏卡，按 rowid；Dart `cardsOfNotes`）：(卡 ID, 模板 ID, cloze 序号)。
fn cards_of(c: &Connection, note: &str) -> Result<Vec<(String, String, i64)>, String> {
    c.prepare_cached(
        "SELECT srs_idt(id), srs_idt(template_id), cloze_ord FROM srs_cards_cache \
         WHERE note_id = srs_id(?1) ORDER BY rowid",
    )
    .map_err(sql)?
    .query_map(params![note], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
    .map_err(sql)?
    .collect::<Result<Vec<_>, _>>()
    .map_err(sql)
}

/// `merge_notes` 的本体（见文件头）：在调用方的写连接、调用方开的 SAVEPOINT 里做。[req]：
/// `{"keep", "absorb": [...], "deletedAt", "legacyDevice", "tickNow", "ts"?}`。回包与 `apply` 同形，另带
/// `linked`（挂成前身的卡数）与 `unmatched`（保留笔记没有对应模板的卡数）。`absorb` 去掉 `keep` 自己之后为空 = 什么都
/// 不做。笔记不存在、笔记类型不同 = 报错，什么都不写。
pub(crate) fn merge_notes_on(
    c: &Connection,
    profile: &str,
    now: i64,
    req: &Value,
) -> Result<Value, String> {
    let keep_id = req["keep"].as_str().ok_or("merge_notes: missing keep")?;
    let mut seen: HashSet<&str> = HashSet::new();
    let absorb: Vec<&str> = req["absorb"]
        .as_array()
        .ok_or("merge_notes: missing absorb")?
        .iter()
        .filter_map(Value::as_str)
        .filter(|id| *id != keep_id && seen.insert(*id))
        .collect();
    if absorb.is_empty() {
        return Ok(json!({"linked": 0, "unmatched": 0}));
    }
    let ids: Vec<String> = std::iter::once(keep_id)
        .chain(absorb.iter().copied())
        .map(str::to_owned)
        .collect();
    let mut views: HashMap<String, caches::NoteInfo> = HashMap::new();
    for chunk in ids.chunks(500) {
        for n in caches::note_infos(c, chunk)? {
            views.insert(n.id.clone(), n);
        }
    }
    let view = |id: &str| {
        views
            .get(id)
            .ok_or_else(|| format!("merge_notes: note {id} not found"))
    };
    let keep = view(keep_id)?;
    for id in &absorb {
        if view(id)?.note_type != keep.note_type {
            return Err("merge_notes: notes of different note types cannot be merged".into());
        }
    }
    let deleted_at = req["deletedAt"]
        .as_i64()
        .ok_or("merge_notes: missing deletedAt")?;
    let ts = req["ts"].as_str().unwrap_or("wall");

    // 还原点：名字 = 保留笔记的第一个字段（没有字段就用它的 ID）。
    let name = keep.fields.first().map_or(keep_id, |(_, v)| v.as_str());
    let mut v = append_on(c, profile, now, &checkpoint_bodies(name, "merge_notes"))?;

    // 候选写入 (类别, 实体, 键, 值)，按以前那几条命令的顺序。
    let mut wanted: Vec<(&str, String, String, Value)> = Vec::new();
    let mut keep_cards: HashMap<(String, i64), String> = HashMap::new();
    for (id, template, ord) in cards_of(c, keep_id)? {
        keep_cards.insert((template, ord), id);
    }
    let (mut linked, mut unmatched) = (0i64, 0i64);
    let mut filled: Vec<(&str, &str)> = Vec::new();
    let mut tags: Vec<&str> = Vec::new();
    for t in &keep.tags {
        if !tags.contains(&t.as_str()) {
            tags.push(t);
        }
    }
    let own_tags = tags.len();
    for id in &absorb {
        let n = view(id)?;
        for (card, template, ord) in cards_of(c, id)? {
            match keep_cards.get(&(template, ord)) {
                Some(target) => {
                    wanted.push((
                        "card",
                        target.clone(),
                        format!("{HISTORY_FROM}{card}"),
                        json!(true),
                    ));
                    linked += 1;
                }
                None => unmatched += 1,
            }
        }
        for (k, val) in &n.fields {
            if dart_blank(keep.field(k))
                && !dart_blank(val)
                && !filled.iter().any(|(fk, _)| fk == k)
            {
                filled.push((k, val));
            }
        }
        for t in &n.tags {
            if !tags.contains(&t.as_str()) {
                tags.push(t);
            }
        }
    }
    for (k, val) in &filled {
        wanted.push(("note", keep_id.to_owned(), format!("f/{k}"), json!(val)));
    }
    // 有新标签才写（以前 Dart 比的是「去重后的个数 ≠ 保留笔记的标签个数」：保留笔记自带重复标签时会误判）。
    if tags.len() != own_tags {
        wanted.push(("note", keep_id.to_owned(), KEY_TAGS.to_owned(), json!(tags)));
    }
    for id in &absorb {
        wanted.push((
            "note",
            (*id).to_owned(),
            KEY_DELETED.to_owned(),
            json!(deleted_at),
        ));
    }

    // 值没变的不写（Dart `_changing`）：按类别一次读齐这些实体的修改记录。
    let mut edits: HashMap<&str, HashMap<String, Vec<(String, Option<i64>)>>> = HashMap::new();
    for kind in ["card", "note"] {
        let mut seen: HashSet<&str> = HashSet::new();
        let of_kind: Vec<String> = wanted
            .iter()
            .filter(|w| w.0 == kind && seen.insert(w.1.as_str()))
            .map(|w| w.1.clone())
            .collect();
        edits.insert(kind, config::edits_of(c, kind, &of_kind)?);
    }
    let none = Vec::new();
    let mut items: Vec<Value> = Vec::new();
    for (kind, entity, key, value) in &wanted {
        let stored = config::stored(edits[kind].get(entity).unwrap_or(&none));
        if registers::write_is_noop(&stored, key, value)? {
            continue;
        }
        items.push(json!({
            "e": {"t": "edit", "x": {"p": profile, "k": kind, "e": entity, "f": key, "v": value, "ts": ts}},
            "note": Value::Null,
            "clk": "t",
        }));
    }
    if !items.is_empty() {
        let legacy = LegacyApply {
            device: req["legacyDevice"]
                .as_str()
                .ok_or("merge_notes: missing legacyDevice")?,
            recv_now: None,
            tick_now: req["tickNow"].as_i64(),
            stamps: false,
        };
        merge_results(
            &mut v,
            apply_local_on(c, profile, now, &items, Some(&legacy))?,
        );
    }
    fail_after(req, "apply")?;
    v["linked"] = json!(linked);
    v["unmatched"] = json!(unmatched);
    Ok(v)
}
