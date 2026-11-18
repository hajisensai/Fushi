//! 列式批量读与 AnkiConnect 数字 id 的新代实现：`card_columns` / `anki_resolve` / `anki_notes_info`（协议 3
//! `store/bulk.rs`）。数据从缓存层的 `cards` / `notes` 与索引层来（设计 §2.3「出卡、浏览」「一条笔记的字段正文」）。
//!
//! # 与协议 3 的差别
//!
//! - **ID**：行里、回包里都是规范 ID（缓存层按规范 ID 物化）。
//! - **数字 id**（D24「数字句柄」）：对外给的是**规范 ID 的号**（`hash53("anki-id/" + 规范 ID)`，缓存行的 `anki_id`
//!   列，按 `notes_anki` / `cards_anki` 索引点查）。按号查找时也认**别名类里成员的号**——换代前 AnkiConnect 客户端记下的
//!   是带盐的原值 ID 的号，换代后照样查得到（[resolve]：按号查不到缓存行时，按号点查缓存层的成员反查表
//!   `anki_members`——别名类里出现过的成员，加上从没在任何操作里出现过的带盐卡：从没复习、没改过的卡在协议 3 里有
//!   缓存行与号，新代的别名表里没有那个带盐 ID，反查表由笔记 × 模板的成员按卡的公式算出来，`cache.rs` 文件头「表」）。
//! - **顺序**：`card_columns` 按卡 ID（协议 3 依查询计划）；`anki_notes_info` 每条笔记的可见卡按卡 ID（协议 3 依计划，
//!   Dart 拿到后按模板序自己排），字段按规范修改键（`f/<字段>`）的序——协议 3 是修改记录的落库序；寄存器视图每个字段
//!   只出一项，Dart（`SrsAnkiNoteInfo`）按字段 ID 建表，顺序没有语义。
//!
//! # 代价
//!
//! `card_columns` 一次顺序扫（同协议 3）。按号查：命中缓存行是一次索引点查（同协议 3 v13）；落空时多一次
//! `anki_members` 主键点查与一次缓存行点查，不扫表、不算哈希（号在物化时算好）。`anki_notes_info` 每条笔记按类重判一次
//! 活着的修改（与缓存层物化同一份 `Index::note_info`）。

use std::collections::BTreeMap;

use rusqlite::{OptionalExtension, params};
use serde_json::{Value, json};

use super::{Sel, ref_of, snapshot};
use crate::store::bulk::CARD_COLUMNS;
use crate::store::gen4::derive::{Index, Ref};
use crate::store::gen4::schema::sql;
use crate::store::gen4::truth::Truth;
use crate::sync2::op::EntKind;

/// `card_columns {fields?, visibleOnly?}`：这个集合的卡片缓存行（含隐藏；`visibleOnly` 为真只要可见的）按列交回，列见
/// `bulk::CARD_COLUMNS`（缺省全部）。按卡 ID 排。
pub fn card_columns(t: &Truth<'_>, col: i64, req: &Value) -> Result<Vec<u8>, String> {
    let wanted: Vec<&str> = match req.get("fields").and_then(Value::as_array) {
        Some(xs) => xs.iter().filter_map(Value::as_str).collect(),
        None => CARD_COLUMNS.iter().map(|(n, _)| *n).collect(),
    };
    let mut cols: Vec<(&str, u32)> = Vec::with_capacity(wanted.len());
    for w in &wanted {
        cols.push(
            *CARD_COLUMNS
                .iter()
                .find(|(n, _)| n == w)
                .ok_or_else(|| format!("card_columns: unknown column {w}"))?,
        );
    }
    snapshot(t, |t| {
        let mut q = Sel::of(col);
        q.push(&format!(
            "SELECT {} FROM cards WHERE col = ?1{} ORDER BY id",
            cols.iter().map(|(n, _)| *n).collect::<Vec<_>>().join(", "),
            if req["visibleOnly"] == Value::Bool(true) {
                " AND hidden = 0"
            } else {
                ""
            }
        ));
        q.table(t, &cols)
    })
}

/// 两张有数字 id 的缓存表。
#[derive(Clone, Copy, PartialEq, Eq)]
pub(super) enum Table {
    Notes,
    Cards,
}

impl Table {
    fn by_num(self) -> &'static str {
        match self {
            Table::Notes => "SELECT MIN(id) FROM notes WHERE col = ?1 AND anki_id = ?2",
            Table::Cards => "SELECT MIN(id) FROM cards WHERE col = ?1 AND anki_id = ?2",
        }
    }

    fn has(self) -> &'static str {
        match self {
            Table::Notes => "SELECT 1 FROM notes WHERE col = ?1 AND id = ?2",
            Table::Cards => "SELECT 1 FROM cards WHERE col = ?1 AND id = ?2",
        }
    }

    /// `anki_members.kind`。
    fn kind(self) -> EntKind {
        match self {
            Table::Notes => EntKind::Note,
            Table::Cards => EntKind::Card,
        }
    }
}

/// 成员的号 [num] 归到的规范 ID（`anki_members`；一个号撞上几个成员时取规范 ID 的 SQLite 序最小的：主键序的第一行）。
fn member(t: &Truth<'_>, col: i64, table: Table, num: i64) -> Result<Option<Ref>, String> {
    t.conn()
        .prepare_cached(
            "SELECT canon FROM anki_members WHERE col = ?1 AND kind = ?2 AND num = ?3 ORDER BY canon LIMIT 1",
        )
        .map_err(sql)?
        .query_row(params![col, table.kind() as i64, num], |r| r.get(0))
        .optional()
        .map_err(sql)
}

/// 数字 id [num] 在 [table] 里的行（规范 ID）：先按规范 ID 的号点查，查不到再认成员的号（文件头「数字 id」）。
pub(super) fn resolve(
    t: &Truth<'_>,
    col: i64,
    table: Table,
    num: i64,
) -> Result<Option<Ref>, String> {
    let hit: Option<Ref> = t
        .conn()
        .prepare_cached(table.by_num())
        .map_err(sql)?
        .query_row(params![col, num], |r| r.get(0))
        .map_err(sql)?;
    if hit.is_some() {
        return Ok(hit);
    }
    let Some(canon) = member(t, col, table, num)? else {
        return Ok(None);
    };
    let has = t
        .conn()
        .prepare_cached(table.has())
        .map_err(sql)?
        .query_row(params![col, canon], |_| Ok(()))
        .optional()
        .map_err(sql)?
        .is_some();
    Ok(has.then_some(canon))
}

/// `anki_resolve {notes?, cards?}`：AnkiConnect 数字 id → 规范 ID（两组，与请求等长，查不到 = null）。
pub fn anki_resolve(t: &Truth<'_>, col: i64, req: &Value) -> Result<Value, String> {
    snapshot(t, |t| {
        let mut out = serde_json::Map::new();
        for (key, table) in [("notes", Table::Notes), ("cards", Table::Cards)] {
            let Some(xs) = req.get(key).and_then(Value::as_array) else {
                continue;
            };
            let mut ids = Vec::with_capacity(xs.len());
            for x in xs {
                let id = match x.as_i64() {
                    Some(n) => resolve(t, col, table, n)?,
                    None => None,
                };
                ids.push(id.map_or(Value::Null, |r| Value::String(r.text())));
            }
            out.insert(key.to_owned(), Value::Array(ids));
        }
        Ok(Value::Object(out))
    })
}

/// `anki_notes_info {notes}`：AnkiConnect `notesInfo` 要的笔记内容（同协议 3）：与请求等长，每项是 null（查不到 / 已
/// 删除）或 `{id, nt, t, f, c}`——规范笔记 ID、规范笔记类型、标签、字段（`[[规范字段 ID, 值]]`，寄存器视图的原序）、可见卡
/// （`[[卡的数字 id, 规范模板 ID, cloze 序号]]`，按卡 ID）。笔记内容按类判定（`Index::note_info`，与缓存层物化同一份）。
pub fn anki_notes_info(t: &Truth<'_>, col: i64, req: &Value) -> Result<Value, String> {
    snapshot(t, |t| {
        let nums: Vec<Option<i64>> = req
            .get("notes")
            .and_then(Value::as_array)
            .map(|a| a.iter().map(Value::as_i64).collect())
            .unwrap_or_default();
        let mut ix = Index::new(t, col);
        let mut infos: BTreeMap<Ref, Value> = BTreeMap::new();
        let mut out = Vec::with_capacity(nums.len());
        for n in nums {
            let Some(id) = (match n {
                Some(n) => resolve(t, col, Table::Notes, n)?,
                None => None,
            }) else {
                out.push(Value::Null);
                continue;
            };
            if !infos.contains_key(&id) {
                let v = note_json(t, &mut ix, col, &id)?;
                infos.insert(id.clone(), v);
            }
            out.push(infos[&id].clone());
        }
        Ok(json!({"notes": out}))
    })
}

/// 一条规范笔记的 `notesInfo` 项（不是笔记 / 不成形 / 已删除 = null）。
fn note_json(t: &Truth<'_>, ix: &mut Index<'_, '_>, col: i64, id: &Ref) -> Result<Value, String> {
    let Some((_, _, info)) = ix.note_info(id)? else {
        return Ok(Value::Null);
    };
    if info.deleted_at.is_some() {
        return Ok(Value::Null);
    }
    let mut cards: Vec<Value> = Vec::new();
    let mut q = Sel::of(col);
    let p = q.id(id);
    q.push(&format!(
        "SELECT anki_id, template_id, cloze_ord FROM cards WHERE col = ?1 AND note_id = {p} \
         AND hidden = 0 ORDER BY id"
    ));
    q.each(t, |r| {
        let tpl: Ref = r.get(1).map_err(sql)?;
        cards.push(json!([
            r.get::<_, i64>(0).map_err(sql)?,
            tpl.text(),
            r.get::<_, i64>(2).map_err(sql)?
        ]));
        Ok(())
    })?;
    Ok(json!({
        "id": info.id,
        "nt": ix.canonical(&ref_of(&info.note_type))?.text(),
        "t": info.tags,
        "f": info.fields.iter().map(|(k, v)| json!([k, v])).collect::<Vec<_>>(),
        "c": cards,
    }))
}
