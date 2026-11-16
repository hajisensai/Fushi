//! 一个实体的修改历史（协议 3 `sync2_history` 的新代版，设计 §2.3「修改历史 / 时间线」读 `ops`）：碰过它的全部字段
//! 修改与标签操作，**含**被覆盖、被因果支配的；新的在前。结果的形与协议 3 相同（一项一个 JSON 对象）：
//!
//! - 修改：`{key, value, writer, device, seq, at, machine}`——带旧戳的报旧写入者与旧 HLC 的物理时刻，否则报设备与墙钟；
//! - 标签：`{key: "tags", tagAdded | tagRemoved, writer, device, seq, at}`；整列表写入（迁移来的 `tags` 修改）按修改报；
//! - 已清除（派生层标了 [S_PURGED]、还没落成空洞）的：`{key, purged: true, writer, device, seq, at}`，不报内容。
//!
//! 与协议 3 的差别（都是有意的）：
//!
//! - **按别名类**：[entity] 可以是类里任何一个成员的号，历史是全部成员的并（D24）；`key` 与 `value` 里嵌的 ID 是规范形
//!   （`writer` 照旧报原名：历史是「谁写的」，不归回）。
//! - **已清除、已落成空洞的写入不出现**：空洞没有键、没有作者（设计 §3.5「已清除操作的壳」不过界）。协议 3 留着骨架，
//!   报一条 `purged`。还没落成空洞的照协议 3 报 `purged`。
//! - 排序：(时刻, HLC 逻辑计数) 降序，平局再按 (设备, seq) 降序（协议 3 平局保持读出顺序）。

use std::collections::BTreeMap;

use rusqlite::params;
use serde_json::{Value, json};

use super::{ref_of, snapshot};
use crate::gen4::name::read_edit_key;
use crate::gen4::op::Body4;
use crate::store::gen4::derive::{Index, body_of};
use crate::store::gen4::schema::sql;
use crate::store::gen4::truth::Truth;
use crate::store::gen4::weigh::S_PURGED;
use crate::sync2::codec::Reader;
use crate::sync2::op::EntKind;

/// 一条历史在排序里的位置：(时刻, 逻辑计数, 设备, seq)。
type Pos = (i64, i64, [u8; 16], u64);

/// 集合 [col] 里实体 ([kind], [entity]) 的修改历史（模块文件头）。在一个读快照里（[snapshot]）。
pub fn history(t: &Truth<'_>, col: i64, kind: EntKind, entity: &str) -> Result<Value, String> {
    snapshot(t, |t| {
        let ix = Index::new(t, col);
        let members = ix.members(&ref_of(entity))?;
        // 主键 → 这条操作在这个实体上的身份（修改键 / 标签）与是否已清除。同一条操作只报一次。
        let mut ops: BTreeMap<i64, (Option<String>, bool)> = BTreeMap::new();
        for m in &members {
            let rows: Vec<(i64, Vec<u8>, i64)> = t
                .conn()
                .prepare_cached(
                    "SELECT k, key, state FROM reg_ix WHERE col = ?1 AND ekind = ?2 AND ent = ?3",
                )
                .map_err(sql)?
                .query_map(params![col, kind as i64, m], |r| {
                    Ok((r.get(0)?, r.get(1)?, r.get(2)?))
                })
                .map_err(sql)?
                .collect::<Result<_, _>>()
                .map_err(sql)?;
            for (k, key, state) in rows {
                let key = read_edit_key(&mut Reader::new(&key))
                    .map_err(|e| format!("gen4 history: bad register key: {e}"))?;
                ops.insert(k, (Some(key), state == S_PURGED));
            }
            if kind == EntKind::Note {
                let rows: Vec<(i64, i64)> = t
                    .conn()
                    .prepare_cached(
                        "SELECT k, MIN(state) FROM tag_ix WHERE col = ?1 AND note = ?2 GROUP BY k",
                    )
                    .map_err(sql)?
                    .query_map(params![col, m], |r| Ok((r.get(0)?, r.get(1)?)))
                    .map_err(sql)?
                    .collect::<Result<_, _>>()
                    .map_err(sql)?;
                for (k, state) in rows {
                    ops.entry(k).or_insert((None, state == S_PURGED));
                }
            }
        }
        let mut out: Vec<(Pos, Value)> = Vec::new();
        for (k, (key, purged)) in ops {
            if let Some(item) = entry(t, &ix, k, key.as_deref(), purged)? {
                out.push(item);
            }
        }
        out.sort_by_key(|x| std::cmp::Reverse(x.0));
        Ok(Value::Array(out.into_iter().map(|x| x.1).collect()))
    })
}

/// 一条操作的历史项（不是修改 / 标签增删的 = None）。[key] = 它在寄存器里的修改键（标签操作没有）。
fn entry(
    t: &Truth<'_>,
    ix: &Index<'_, '_>,
    k: i64,
    key: Option<&str>,
    purged: bool,
) -> Result<Option<(Pos, Value)>, String> {
    let Some(h) = t.head_by_key(k)? else {
        return Ok(None);
    };
    let device = h.id.device.text();
    let seq = h.id.seq;
    let pos = |at: i64| -> Pos { (at, h.logical, h.id.device.0, seq) };
    if purged {
        let key = match key {
            Some(k) => ix.canonical_key(k)?,
            None => "tags".to_owned(),
        };
        return Ok(Some((
            pos(h.wall),
            json!({"key": key, "purged": true, "writer": device, "device": device, "seq": seq, "at": h.wall}),
        )));
    }
    let Some(e) = t.entry_by_key(k)? else {
        return Ok(None);
    };
    Ok(match body_of(&e) {
        Some(Body4::Edit(ed)) => {
            let (writer, at) = match &ed.stamp {
                Some(s) => (
                    s.writer.clone(),
                    crate::history::parse_hlc(&s.hlc.text()).map_or(h.wall, |p| p.0),
                ),
                None => (device.clone(), h.wall),
            };
            let key = ix.canonical_key(&ed.key)?;
            let value = serde_json::from_str::<Value>(&ed.value).unwrap_or(Value::Null);
            let value = ix.canonical_value(&key, &value)?;
            Some((
                pos(at),
                json!({
                    "key": key,
                    "value": value,
                    "writer": writer,
                    "device": device,
                    "seq": seq,
                    "at": at,
                    "machine": ed.machine,
                }),
            ))
        }
        Some(Body4::TagAdd { tag, .. }) => Some((
            pos(h.wall),
            json!({"key": "tags", "tagAdded": tag, "writer": device, "device": device, "seq": seq, "at": h.wall}),
        )),
        Some(Body4::TagRemove { tag, .. }) => Some((
            pos(h.wall),
            json!({"key": "tags", "tagRemoved": tag, "writer": device, "device": device, "seq": seq, "at": h.wall}),
        )),
        _ => None,
    })
}
