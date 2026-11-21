//! 冲突中心与时间线的只读命令（G7-4e）：`conflicts`、`checkpoints`、`undo_check`。**还没接分发器**：协议 3 的
//! `sync2_conflicts`（`store/sync2/mod.rs`）、`sync2_checkpoints`（`store/sync2/timeline.rs`）、`sync2_undo_check`
//! （`store/sync2/undo_check.rs`）原地不动，分发器在整批推送里一次切到这里（规划 §2.2 S1）。
//!
//! # 形状（与协议 3 逐键相同）
//!
//! - `conflicts` → 数组，每项 `{"id", "kind": "delete_edit|delete_review|delete_move", "entityKind", "entity", "by",
//!   "others", "at"}`，按 (`at`, `id`) 升序（协议 3 `ORDER BY at, id`）。
//! - `checkpoints` → 数组，每项 `{"at", "name", "reason", "device", "seq"}`，按 (`at`, `seq`) 降序（协议 3
//!   `ORDER BY wall DESC, seq DESC`）。
//! - `undo_check` → `{"r": [{"ok": bool, "cur": <现值>}]}`，与请求的 `items` 同序。
//!
//! # 数据从哪来
//!
//! - **冲突**：新代的冲突就是派生表 `hold_ix`（`weigh.rs` [Index::holds]：被并发改动扣住的删除，三类并发各一个计数）。
//!   协议 3 每个 (删除, 类别) 一行；这里同样每个计数非零的类别出一项，冲突 ID 用写命令 `resolve` 找冲突的同一个公式
//!   （`writes.rs` [conflict_id]），所以这里列出的 ID 交给 `resolve` 一定找得到。`at` = 那条删除的 HLC 墙钟（协议 3
//!   存的 `d.hlc.wall`）；`others` = 那一类的并发操作数。
//! - **还原点**：真相层里种类为 `Checkpoint` 的操作（原生日志与承袭日志都在 `ops` 里），走部分索引 `ops_checkpoint`
//!   （`schema.rs`，只收种类 6 的行）按设备的主键区间读；再并上迁移时照搬的本机表 `checkpoints`（`carry.rs`：协议 3
//!   `sync2_checkpoints` 的行），同一个 (设备, seq) 只出一次、以真相层为准。只读本机表会漏掉换代之后新写 / 新收的还原点。
//! - **撤销校验**：判据只有一份（`registers::undo_verdict`）。「那次写入」按 dot（设备, seq）从真相层取
//!   （[Truth::key_of] → [body_of]），现存记录是这个别名类在这个规范键上活着的修改行（[super::edit_rows]，笔记的 `tags`
//!   是同一份合成行）。「唯一活着的那条因果上见没见过那次写入」不读行里的 `ctx`（不带旧戳的写入的投影上下文只覆盖别的
//!   要输出的行，`derive.rs` `edit_lines_as`），按那条写入的依赖与旧闭包从真相层答（[Index::class_write_sees]）。
//!
//! # 与协议 3 的差别（都是按类 D24 带来的）
//!
//! - 冲突的 `entity`、撤销校验里的实体 / 键 / 值都是规范形：请求里给别名类里任何成员的号都行（先归一）。
//! - 撤销校验的 dot 写入者按 `alias_writer_ix` 归回（与类判定里活着的行同一个名字），值按规范值比。
//!
//! # 代价
//!
//! `conflicts` 只走 `hold_ix` 的主键前缀（行数 = 扣住的删除数），每条点读一次操作头。`checkpoints` 每台设备一次部分索引
//! 区间扫，行数 = 还原点数，与日志长短无关（测试 `checkpoints_read_only_checkpoint_rows`）。`undo_check` 每项读一个类的
//! 寄存器（`reg_ix` 主键前缀）与一次按主键的操作点读。

use std::collections::BTreeMap;

use rusqlite::params;
use serde_json::{Value, json};

use super::writes::conflict_id;
use super::{edit_rows, profile_of, ref_of, snapshot};
use crate::gen4::op::{Body4, KIND_CHECKPOINT};
use crate::registers::{StoredEdit, UndoTarget, register_value, undo_verdict};
use crate::store::gen4::derive::{Index, Ref, body_of};
use crate::store::gen4::schema::{k_range, k_seq, sql};
use crate::store::gen4::truth::Truth;
use crate::sync2::id::Id;
use crate::sync2::op::EntKind;
use crate::sync2::vv::OpId;

// ---------------------------------------------------------------------- conflicts

/// `conflicts`：集合 [col] 里待用户裁决的删除冲突（模块文件头）。一个读快照。
pub fn conflicts(t: &Truth<'_>, col: i64) -> Result<Value, String> {
    snapshot(t, |t| {
        let ix = Index::new(t, col);
        let mut out: Vec<(i64, String, Value)> = Vec::new();
        for h in ix.holds()? {
            let at = t
                .head_by_key(h.k)?
                .ok_or_else(|| format!("gen4 conflicts: held op {:?} has no head", h.op))?
                .wall;
            let entity = ix.canonical(&h.entity)?.text();
            for (n, kind) in [
                (h.edits, "delete_edit"),
                (h.reviews, "delete_review"),
                (h.moves, "delete_move"),
            ] {
                if n == 0 {
                    continue;
                }
                let id = conflict_id(&h.op, kind);
                let row = json!({
                    "id": id,
                    "kind": kind,
                    "entityKind": h.kind.wire(),
                    "entity": entity,
                    "by": h.op.device.text(),
                    "others": n,
                    "at": at,
                });
                out.push((at, id, row));
            }
        }
        out.sort_by(|a, b| (a.0, &a.1).cmp(&(b.0, &b.1)));
        Ok(Value::Array(out.into_iter().map(|x| x.2).collect()))
    })
}

// ---------------------------------------------------------------------- checkpoints

/// 一个还原点：墙钟、名字、原因。
type Checkpoint = (i64, String, String);

/// `checkpoints`：集合 [col] 的还原点列表，新的在前（模块文件头）。一个读快照。
pub fn checkpoints(t: &Truth<'_>, col: i64) -> Result<Value, String> {
    snapshot(t, |t| {
        // (设备, seq) → 还原点。先放迁移照搬的本机表，再用真相层的盖掉。
        let mut by: BTreeMap<([u8; 16], u64), Checkpoint> = BTreeMap::new();
        {
            let mut stmt = t
                .conn()
                .prepare_cached(
                    "SELECT device, seq, wall, name, reason FROM checkpoints WHERE col = ?1",
                )
                .map_err(sql)?;
            let rows = stmt
                .query_map([col], |r| {
                    Ok((
                        r.get::<_, Vec<u8>>(0)?,
                        r.get::<_, i64>(1)?,
                        r.get::<_, i64>(2)?,
                        r.get::<_, String>(3)?,
                        r.get::<_, String>(4)?,
                    ))
                })
                .map_err(sql)?;
            for row in rows {
                let (device, seq, wall, name, reason) = row.map_err(sql)?;
                let Ok(device) = <[u8; 16]>::try_from(device.as_slice()) else {
                    continue;
                };
                by.insert((device, seq.max(0) as u64), (wall, name, reason));
            }
        }
        // 种类 6 的操作：部分索引 `ops_checkpoint`（只有还原点的行），按设备的主键区间。
        let q = format!(
            "SELECT k FROM ops INDEXED BY ops_checkpoint WHERE kind = {KIND_CHECKPOINT} AND k BETWEEN ?1 AND ?2"
        );
        for d in t.devices(col)? {
            let (lo, hi) = k_range(d.dev);
            let ks: Vec<i64> = t
                .conn()
                .prepare_cached(&q)
                .map_err(sql)?
                .query_map(params![lo, hi], |r| r.get(0))
                .map_err(sql)?
                .collect::<Result<_, _>>()
                .map_err(sql)?;
            for k in ks {
                let (Some(e), Some(h)) = (t.entry_by_key(k)?, t.head_by_key(k)?) else {
                    continue;
                };
                if let Some(Body4::Checkpoint { name, reason }) = body_of(&e) {
                    by.insert((d.id.0, k_seq(k)), (h.wall, name, reason));
                }
            }
        }
        let mut rows: Vec<(([u8; 16], u64), Checkpoint)> = by.into_iter().collect();
        rows.sort_by(|a, b| (b.1.0, b.0.1).cmp(&(a.1.0, a.0.1)));
        Ok(Value::Array(
            rows.into_iter()
                .map(|((device, seq), (wall, name, reason))| {
                    json!({
                        "at": wall,
                        "name": name,
                        "reason": reason,
                        "device": Id(device).text(),
                        "seq": seq,
                    })
                })
                .collect(),
        ))
    })
}

// ---------------------------------------------------------------------- undo_check

/// `undo_check`（编辑类撤销的校验，协议 3 `undo_check.rs`）。[req]：`{"items": [{"k", "e", "f", "w"?, "s"?, "v"?}]}`
/// ——`w` / `s` 是那次写入的 dot（设备 ID 文本、序号；写命令回包的 `edits`），`v` 是那次写下的值（没有 dot 的旧载荷
/// 按值比）。回包 `{"r": [{"ok", "cur"}]}`，与输入同序。只读，一个读快照。
pub fn undo_check(t: &Truth<'_>, col: i64, req: &Value) -> Result<Value, String> {
    let items = req["items"].as_array().ok_or("undo_check: missing items")?;
    snapshot(t, |t| {
        let profile = profile_of(t, col)?;
        let mut ix = Index::new(t, col);
        let writers = ix.writer_aliases()?;
        let mut out = Vec::with_capacity(items.len());
        for it in items {
            let (ok, cur) = check_item(t, &mut ix, col, &profile, &writers, it)?;
            out.push(json!({"ok": ok, "cur": cur}));
        }
        Ok(json!({ "r": out }))
    })
}

/// 一项的裁决：(能不能撤, 现值)。
fn check_item(
    t: &Truth<'_>,
    ix: &mut Index<'_, '_>,
    col: i64,
    profile: &str,
    writers: &crate::store::gen4::class::WriterAliases,
    it: &Value,
) -> Result<(bool, Value), String> {
    let kind = it["k"]
        .as_str()
        .and_then(EntKind::parse)
        .ok_or("undo_check: bad k")?;
    let entity = it["e"].as_str().ok_or("undo_check: missing e")?;
    let key = it["f"].as_str().ok_or("undo_check: missing f")?;
    let canon = ix.canonical(&ref_of(entity))?;
    let ckey = ix.canonical_key(key)?;
    // 这个类在这个规范键上活着的修改行（行 JSON 已是规范形）。
    let rows: Vec<(String, Option<i64>)> = edit_rows(t, ix, kind, &canon, profile)?
        .into_iter()
        .filter(|(f, _, _)| *f == ckey)
        .map(|(_, json, st)| (json, st))
        .collect();
    let items: Vec<StoredEdit<'_>> = rows.iter().map(|(j, s)| (j.as_str(), *s, None)).collect();
    // 那次写入：按 dot 从真相层取（活着的行里可能早已没有它）。
    let ours: Option<(String, i64, Value)> = match (it["w"].as_str(), it["s"].as_i64()) {
        (Some(w), Some(s)) if s > 0 => {
            let device = Id::parse(w).ok_or_else(|| format!("bad device id {w}"))?;
            let op = OpId {
                device,
                seq: s as u64,
            };
            let body = match t.key_of(col, &op)? {
                Some(k) => t.entry_by_key(k)?.as_ref().and_then(body_of),
                None => None,
            };
            match body {
                // 不带旧戳的修改（协议 3 `legacy.is_none()`），且就是这个类的这个键。
                Some(Body4::Edit(e))
                    if e.stamp.is_none()
                        && e.kind == kind
                        && ix.canonical(&Ref::of(&e.entity))? == canon
                        && ix.canonical_key(&e.key)? == ckey =>
                {
                    let v = serde_json::from_str::<Value>(&e.value).unwrap_or(Value::Null);
                    let v = ix.canonical_value(&ckey, &v)?;
                    let w = writers.get(w).cloned().unwrap_or_else(|| w.to_owned());
                    Some((w, s, v))
                }
                // 不在日志里（备份恢复回到它之前、已落成空洞）或不是这一处的修改：没有事实可依，不撤。
                _ => return Ok((false, register_value(&items, &ckey)?)),
            }
        }
        _ => None,
    };
    let target = ours.as_ref().map(|(w, s, v)| UndoTarget {
        writer: w,
        seq: *s,
        value: v,
    });
    let after = match it.get("v") {
        Some(v) => Some(ix.canonical_value(&ckey, v)?),
        None => None,
    };
    // 「唯一活着的那条见没见过那次写入」问真相层（[Index::class_write_sees]）：投影行的 ctx 只覆盖别的要输出的行，
    // 被支配的旧写入（倒序撤到第二步时的那次写入）不在里面。
    undo_verdict(
        &items,
        &ckey,
        target.as_ref(),
        after.as_ref(),
        &mut |x, o| {
            ix.class_write_sees(
                kind,
                &canon,
                &ckey,
                writers,
                (x.writer, x.seq),
                (o.writer, o.seq),
            )
        },
    )
}
