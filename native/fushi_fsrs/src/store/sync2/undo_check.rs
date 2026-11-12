//! 编辑类撤销的校验（`undo_check`）：撤销一次字段修改之前，按库里的修改记录判断这个字段键自那次写入以来有没有
//! 被别人动过（同步拉进来的别的设备的修改、本机 AI / 别处又改过）。判据只在这里写一份
//! （[crate::registers::undo_verdict]）：
//!
//! - 那次写入在投影里仍是这个键唯一没被支配的记录 → 可以撤；
//! - 唯一的记录因果上见过那次写入、值与它相同（之后的改动又全部改回了它写下的值，典型是先撤了更晚的一步）→ 可以撤；
//! - 其余（之后被改成别的值、有并发候选、记录被扣住 / 清除、那次写入根本不在操作表里）→ 不撤，交回现值。
//!
//! 只读：裁决交回 Dart，Dart 在同一个写锁独占区（`SrsDbStore.runExclusive`）里只把裁决为「可以撤」的键写回原值，
//! 写回走普通的本机写入路径（`apply`），所以撤销写下的仍是普通修改操作，照常同步、照常重放。读与写之间没有别的写入
//! 能插进来：本机写入、收段投递都排在同一把锁后面。
//!
//! 评分 / 重置 / 改期这类日志的撤销不走这里（`sched` 的 undo，sched_local.rs：只认最后一条有效日志）。

use rusqlite::{Connection, params};
use serde_json::{Value, json};

use super::{load_op, parse_device, sql};
use crate::registers::{UndoTarget, undo_verdict};
use crate::store::SrsCore;
use crate::sync2::op::{Body, EntKind};
use crate::sync2::vv::OpId;

/// 一项的裁决：(能不能撤, 现值)。
fn check_item(conn: &Connection, profile: &str, it: &Value) -> Result<(bool, Value), String> {
    let kind = it["k"]
        .as_str()
        .and_then(EntKind::parse)
        .ok_or("undo_check: bad k")?;
    let entity = it["e"].as_str().ok_or("undo_check: missing e")?;
    let key = it["f"].as_str().ok_or("undo_check: missing f")?;
    // 那次写入的操作：按 dot 从唯一事实表取（投影里那一行可能已被之后的写入支配删掉）。取它落库的值（表示层压缩
    // 过的笔记字段与投影行同形，比值不受内联样式影响）。
    let ours: Option<(String, i64, Value)> = match (it["w"].as_str(), it["s"].as_i64()) {
        (Some(w), Some(s)) if s > 0 => {
            let id = OpId {
                device: parse_device(w)?,
                seq: s as u64,
            };
            let Some(op) = load_op(conn, profile, &id)? else {
                // 不在操作表里（备份恢复回到它之前、换身份重签发）：没有事实可依，不撤。
                return Ok((false, current_value(conn, kind, entity, key)?));
            };
            match op.body().map_err(|e| e.to_string())? {
                Body::Edit(e)
                    if e.legacy.is_none()
                        && e.kind == kind
                        && e.entity.text() == entity
                        && e.key == key =>
                {
                    let v = serde_json::from_str::<Value>(&e.value).unwrap_or(Value::Null);
                    Some((w.to_owned(), s, v))
                }
                _ => return Ok((false, current_value(conn, kind, entity, key)?)),
            }
        }
        _ => None,
    };
    let rows = live_rows(conn, kind, entity, key)?;
    let items: Vec<crate::registers::StoredEdit<'_>> = rows
        .iter()
        .map(|(j, s, c)| (j.as_str(), *s, c.as_ref()))
        .collect();
    let target = ours.as_ref().map(|(w, s, v)| UndoTarget {
        writer: w,
        seq: *s,
        value: v,
    });
    undo_verdict(&items, key, target.as_ref(), it.get("v"))
}

type LiveRow = (String, Option<i64>, Option<crate::registers::EditCols>);

/// 投影里这个字段键现存的修改记录（读法同 mod.rs `land_edit`：`jslim` + 列）。
fn live_rows(
    conn: &Connection,
    kind: EntKind,
    entity: &str,
    key: &str,
) -> Result<Vec<LiveRow>, String> {
    conn.prepare_cached(
        "SELECT l.server_time, f.jslim, f.id, f.profile_uid, f.entity_kind, f.entity_id, f.field_key, f.writer_id, f.seq \
         FROM srs_field_edits f LEFT JOIN srs_event_local l ON l.event_id = f.id \
         WHERE f.entity_kind = ?1 AND f.entity_id = srs_id(?2) AND f.field_key = ?3",
    )
    .map_err(sql)?
    .query_map(params![kind.wire(), entity, key], |r| {
        let (j, cols) = crate::store::slim::edit_row(r, 1)?;
        Ok((j, r.get(0)?, cols))
    })
    .map_err(sql)?
    .collect::<Result<_, _>>()
    .map_err(sql)
}

fn current_value(
    conn: &Connection,
    kind: EntKind,
    entity: &str,
    key: &str,
) -> Result<Value, String> {
    let rows = live_rows(conn, kind, entity, key)?;
    let items: Vec<crate::registers::StoredEdit<'_>> = rows
        .iter()
        .map(|(j, s, c)| (j.as_str(), *s, c.as_ref()))
        .collect();
    crate::registers::register_value(&items, key)
}

impl SrsCore {
    /// 编辑类撤销的校验（文件头）。[req] `{"items":[{"k","e","f","w"?,"s"?,"v"?}]}`：`w`/`s` 是那次写入的 dot
    /// （设备 ID 文本、序号；`apply` 交回的 `edits`），`v` 是那次写下的值（只在没有 dot 的旧载荷上用来按值比）。
    /// 返回 `{"r":[{"ok":bool,"cur":<现值>}]}`，与输入同序。只读。
    pub fn sync2_undo_check(&self, profile: &str, req: &Value) -> Result<Value, String> {
        let items = req["items"].as_array().ok_or("undo_check: missing items")?;
        self.read_visible(|c| {
            let mut out = Vec::with_capacity(items.len());
            for it in items {
                let (ok, cur) = check_item(c, profile, it)?;
                out.push(json!({"ok": ok, "cur": cur}));
            }
            Ok(json!({ "r": out }))
        })
    }
}
