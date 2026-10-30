//! 投影里有专门语义的几类操作（设计 §3.3、§5.3、§10.5）：
//!
//! - **标签 OR-Set（加胜）**：标签不再是整列表的多值寄存器。`TagAdd` 记一个添加点，`TagRemove` 只抹掉移除者
//!   见过的添加点；一边加、一边并发删同一标签 → 保留。投影成每条笔记一行合成的 `tags` 修改记录（读侧照旧
//!   读 `tags` 寄存器）。迁移进来的旧 `tags` 记录按「添加列表里的每个标签」并入。
//! - **破坏性并发进冲突中心**：删除（`deleted` 写成时刻）与因果上并发的编辑 / 标签 / 复习 / 移入该牌组
//!   共存时，不自动判输赢：这条删除先**扣住**（不进投影，实体保持可见、可复习），生成冲突项；用户选
//!   「删除」或「保留」= 追加一条因果覆盖双方的新写入，冲突自然消失、各设备结论一致。
//! - **彻底清除**：`Purge{entity}` 让每台设备把本机日志里该实体的内容载荷换成哈希（骨架与链不变），删掉
//!   投影里的内容，并重写自己写过的、含这些操作的段。之后再到的同实体内容操作里，**没见过这条清除的**
//!   （与清除并发、或写在清除之前迟到的）一到就清除；**因果上在清除之后的**（作者已经见过清除，例如用户
//!   清除后又把同一份 apkg 导回来——笔记 ID 由来源 guid 派生，必然是同一个 ID）是新内容，照常落投影。
//!   判据只看因果（`op.saw(purge)`），各设备收到同一批操作结论一致；清除可以再来一次，覆盖它见过的复活。

use std::collections::BTreeSet;

use rusqlite::{params, Connection, OptionalExtension};
use serde_json::{json, Value};

use super::{canonical, edit_row, load_op, sql, Touched};
use crate::sync2::id::Id;
use crate::sync2::op::{Body, EditBody, EntKind, Op};
use crate::sync2::vv::OpId;

// ---------------------------------------------------------------- 实体 → 操作索引

/// 记一条操作碰过哪个实体（冲突判定、清除都按它找）。`what` = 字段键，或 `#tag` / `#log` / `#move`。
pub(crate) fn index(conn: &Connection, profile: &str, kind: &str, entity: &str, op: &OpId, what: &str) -> Result<(), String> {
    conn.prepare_cached(
        "INSERT OR IGNORE INTO sync2_ent_ops (profile_uid, kind, entity, device, seq, what) VALUES (srs_id(?1), ?2, srs_id(?3), ?4, ?5, ?6)",
    )
    .map_err(sql)?
    .execute(params![profile, kind, entity, op.device.0.to_vec(), op.seq as i64, what])
    .map_err(sql)?;
    Ok(())
}

pub(crate) fn ops_of(conn: &Connection, profile: &str, kind: &str, entity: &str) -> Result<Vec<(OpId, String)>, String> {
    let mut stmt = conn
        .prepare_cached("SELECT device, seq, what FROM sync2_ent_ops WHERE profile_uid = srs_id(?1) AND kind = ?2 AND entity = srs_id(?3)")
        .map_err(sql)?;
    let rows = stmt
        .query_map(params![profile, kind, entity], |r| Ok((r.get::<_, Vec<u8>>(0)?, r.get::<_, i64>(1)?, r.get::<_, String>(2)?)))
        .map_err(sql)?;
    let mut out = Vec::new();
    for r in rows {
        let (d, s, w) = r.map_err(sql)?;
        let device = Id(d.try_into().map_err(|_| "bad device".to_string())?);
        out.push((OpId { device, seq: s as u64 }, w));
    }
    Ok(out)
}

// ---------------------------------------------------------------- 标签 OR-Set

/// 笔记现在的标签：存活的添加点按标签取最早一个（HLC 序）；顺序先按最近一次顺序提示（[tag_order]），不在
/// 提示里的按最早添加时刻。
pub(crate) fn current_tags(conn: &Connection, profile: &str, note: &str) -> Result<Vec<String>, String> {
    let mut stmt = conn
        .prepare_cached("SELECT tag, wall, logical, device FROM sync2_tag_adds WHERE profile_uid = srs_id(?1) AND note = srs_id(?2)")
        .map_err(sql)?;
    let rows: Vec<(String, i64, i64, Vec<u8>)> = stmt
        .query_map(params![profile, note], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)))
        .map_err(sql)?
        .collect::<Result<_, _>>()
        .map_err(sql)?;
    let mut first: std::collections::BTreeMap<String, (i64, i64, Vec<u8>)> = std::collections::BTreeMap::new();
    for (tag, w, l, d) in rows {
        let k = (w, l, d);
        match first.get(&tag) {
            Some(old) if *old <= k => {}
            _ => {
                first.insert(tag, k);
            }
        }
    }
    let hint: Vec<String> = conn
        .prepare_cached("SELECT tags FROM sync2_tag_order WHERE profile_uid = srs_id(?1) AND note = srs_id(?2)")
        .map_err(sql)?
        .query_row(params![profile, note], |r| r.get::<_, String>(0))
        .optional()
        .map_err(sql)?
        .and_then(|t| serde_json::from_str(&t).ok())
        .unwrap_or_default();
    let mut out: Vec<String> = hint.into_iter().filter(|t| first.contains_key(t)).collect();
    let mut rest: Vec<(&(i64, i64, Vec<u8>), &String)> =
        first.iter().filter(|(t, _)| !out.contains(t)).map(|(t, k)| (k, t)).collect();
    rest.sort();
    out.extend(rest.into_iter().map(|(_, t)| t.clone()));
    out.dedup();
    Ok(out)
}

/// 顺序提示：因果优先，真并发才 HLC 大者胜（store/sync2/mvr.rs）。
pub(crate) fn tag_order(conn: &Connection, profile: &str, note: &str, tags: &[String], op: &Op) -> Result<(), String> {
    let win = super::mvr::write(conn, profile, &super::mvr::reg("t", &[note]), op)?;
    let tags = if win.id == op.id { Some(tags.to_vec()) } else { None };
    land_tag_order(conn, profile, note, &win, tags).map(|_| ())
}

/// 一条操作带的整列表标签（`TagOrder`，或迁移进来的 `tags` 整列表修改记录）。
fn tags_of_op(op: &Op) -> Option<Vec<String>> {
    match op.body().ok()? {
        crate::sync2::op::Body::TagOrder { tags, .. } => Some(tags),
        crate::sync2::op::Body::Edit(e) if e.key == "tags" => match serde_json::from_str::<serde_json::Value>(&e.value).ok()? {
            serde_json::Value::Array(xs) => Some(xs.iter().filter_map(serde_json::Value::as_str).map(str::to_owned).collect()),
            _ => None,
        },
        _ => None,
    }
}

/// `sync2_tag_order` 落到寄存器的当前值 [win]（[tags] = 它带的标签，没给就从日志读）；与投影已有的相同就不写。
/// 返回是否改了投影。
pub(crate) fn land_tag_order(conn: &Connection, profile: &str, note: &str, win: &super::mvr::Write, tags: Option<Vec<String>>) -> Result<bool, String> {
    let cur: Option<(i64, i64, Vec<u8>)> = conn
        .prepare_cached("SELECT wall, logical, device FROM sync2_tag_order WHERE profile_uid = srs_id(?1) AND note = srs_id(?2)")
        .map_err(sql)?
        .query_row(params![profile, note], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
        .optional()
        .map_err(sql)?;
    if cur.as_ref().is_some_and(|(w, l, d)| (*w, *l, d.as_slice()) == (win.wall, win.logical, &win.id.device.0[..])) {
        return Ok(false);
    }
    let tags = match tags {
        Some(t) => t,
        None => match super::load_op(conn, profile, &win.id)?.as_ref().and_then(tags_of_op) {
            Some(t) => t,
            None => return Ok(false),
        },
    };
    conn.prepare_cached(
        "INSERT OR REPLACE INTO sync2_tag_order (profile_uid, note, tags, wall, logical, device) VALUES (srs_id(?1), srs_id(?2), ?3, ?4, ?5, ?6)",
    )
    .map_err(sql)?
    .execute(params![profile, note, serde_json::to_string(&tags).map_err(|e| e.to_string())?, win.wall, win.logical, win.id.device.0.to_vec()])
    .map_err(sql)?;
    Ok(true)
}

/// 这条笔记最近一次标签操作的 HLC（合成行的 `hlc`：笔记的「修改时间」按它算）。
fn last_tag_hlc(conn: &Connection, profile: &str, note: &str) -> Result<String, String> {
    let row: Option<(i64, i64, Vec<u8>)> = conn
        .prepare_cached(
            "SELECT o.wall, o.logical, o.device FROM sync2_ent_ops e JOIN sync2_ops o \
             ON o.profile_uid = e.profile_uid AND o.device = e.device AND o.seq = e.seq \
             WHERE e.profile_uid = srs_id(?1) AND e.kind = 'note' AND e.entity = srs_id(?2) AND e.what IN ('#tag', 'tags') \
             ORDER BY o.wall DESC, o.logical DESC, o.device DESC LIMIT 1",
        )
        .map_err(sql)?
        .query_row(params![profile, note], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
        .optional()
        .map_err(sql)?;
    Ok(match row {
        Some((w, l, d)) => {
            let dev = <[u8; 16]>::try_from(d).map(|a| Id(a).text()).unwrap_or_default();
            format!("{w}:{l}:{dev}")
        }
        None => "0:0:sync2".to_owned(),
    })
}

pub(crate) fn tag_add(conn: &Connection, profile: &str, note: &str, tag: &str, op: &Op) -> Result<(), String> {
    conn.prepare_cached(
        "INSERT OR IGNORE INTO sync2_tag_adds (profile_uid, note, tag, device, seq, wall, logical) VALUES (srs_id(?1), srs_id(?2), ?3, ?4, ?5, ?6, ?7)",
    )
    .map_err(sql)?
    .execute(params![profile, note, tag, op.id.device.0.to_vec(), op.id.seq as i64, op.hlc.wall, i64::from(op.hlc.logical)])
    .map_err(sql)?;
    Ok(())
}

/// 观察删除：只抹掉 [op] 的作者见过的添加点（并发的添加保留 = 加胜）。
pub(crate) fn tag_remove(conn: &Connection, profile: &str, note: &str, tag: &str, op: &Op) -> Result<(), String> {
    let adds: Vec<(Vec<u8>, i64)> = conn
        .prepare_cached("SELECT device, seq FROM sync2_tag_adds WHERE profile_uid = srs_id(?1) AND note = srs_id(?2) AND tag = ?3")
        .map_err(sql)?
        .query_map(params![profile, note, tag], |r| Ok((r.get(0)?, r.get(1)?)))
        .map_err(sql)?
        .collect::<Result<_, _>>()
        .map_err(sql)?;
    for (d, s) in adds {
        let device = Id(d.clone().try_into().map_err(|_| "bad device".to_string())?);
        if op.saw(&OpId { device, seq: s as u64 }) {
            conn.prepare_cached("DELETE FROM sync2_tag_adds WHERE profile_uid = srs_id(?1) AND note = srs_id(?2) AND tag = ?3 AND device = ?4 AND seq = ?5")
                .map_err(sql)?
                .execute(params![profile, note, tag, d, s])
                .map_err(sql)?;
        }
    }
    Ok(())
}

/// 合成的 `tags` 修改记录的写入者名（每条笔记一个，seq 恒为 1）。前缀让寄存器内核认出它是没有因果 dot 的
/// 合成行、不拿它判「与删除并发」（registers.rs [crate::registers::SYNTHETIC_WRITER_PREFIX]）。
pub(crate) fn tags_writer(note: &str) -> String {
    format!("{}tags:{note}", crate::registers::SYNTHETIC_WRITER_PREFIX)
}

/// 把笔记的 OR-Set 值投影成唯一一行 `tags` 修改记录（替换掉这条笔记上其它的 `tags` 行）。
pub(crate) fn refresh_tags_row(conn: &Connection, profile: &str, note: &str, t: &mut Touched) -> Result<(), String> {
    let tags = current_tags(conn, profile, note)?;
    let writer = tags_writer(note);
    let id = crate::registers::edit_id(&writer, 1);
    let row = json!({
        "id": id, "p": profile, "k": "note", "e": note, "f": "tags", "w": writer, "s": 1,
        "ctx": {"vv": {}}, "v": tags, "hlc": last_tag_hlc(conn, profile, note)?, "ts": "wall",
    });
    let text = canonical(&row);
    let old: Option<String> = conn
        .prepare_cached("SELECT json FROM srs_field_edits WHERE id = srs_id(?1)")
        .map_err(sql)?
        .query_row([&id], |r| r.get(0))
        .optional()
        .map_err(sql)?;
    let others: Vec<String> = conn
        .prepare_cached("SELECT srs_idt(id) AS id FROM srs_field_edits WHERE entity_kind = 'note' AND entity_id = srs_id(?1) AND field_key = 'tags' AND id != srs_id(?2)")
        .map_err(sql)?
        .query_map(params![note, id], |r| r.get(0))
        .map_err(sql)?
        .collect::<Result<_, _>>()
        .map_err(sql)?;
    if old.as_deref() == Some(text.as_str()) && others.is_empty() {
        return Ok(());
    }
    for o in &others {
        conn.prepare_cached("DELETE FROM srs_field_edits WHERE id = srs_id(?1)").map_err(sql)?.execute([o]).map_err(sql)?;
        t.dominated.push(o.clone());
    }
    conn.prepare_cached(
        // 不能写 `INSERT OR REPLACE`：REPLACE 删旧行时（没开 recursive_triggers）不触发 DELETE 触发器，摘要桶
        // （digest.rs）只加不减，同一笔记第二次改标签起桶哈希与行数就永久错了。UPSERT 走 UPDATE 触发器（先减后加）。
        "INSERT INTO srs_field_edits (id, profile_uid, entity_kind, entity_id, field_key, writer_id, seq, json) \
         VALUES (srs_id(?1), srs_id(?2), 'note', srs_id(?3), 'tags', srs_id(?4), 1, ?5) \
         ON CONFLICT(id) DO UPDATE SET profile_uid = excluded.profile_uid, entity_kind = excluded.entity_kind, \
         entity_id = excluded.entity_id, field_key = excluded.field_key, writer_id = excluded.writer_id, \
         seq = excluded.seq, json = excluded.json",
    )
    .map_err(sql)?
    .execute(params![id, profile, note, writer, text])
    .map_err(sql)?;
    t.marks.edit(crate::sync2::op::EntKind::Note, note, "tags");
    Ok(())
}

// ---------------------------------------------------------------- 破坏性并发（冲突中心）

/// 两条操作因果上并发（谁也没见过谁）。迁移进来的旧记录不参与（旧协议的规则照旧：寄存器内核自己判）。
fn concurrent(a: &Op, b: &Op) -> bool {
    !a.saw(&b.id) && !b.saw(&a.id)
}

fn is_delete(op: &Op) -> Option<EditBody> {
    match op.body() {
        Ok(Body::Edit(e)) if e.key == "deleted" && e.legacy.is_none() => {
            let v: Value = serde_json::from_str(&e.value).unwrap_or(Value::Null);
            v.is_i64().then_some(e)
        }
        _ => None,
    }
}

fn conflict_kind(what: &str, entity_kind: &str) -> &'static str {
    match what {
        "#log" => "delete_review",
        "#move" => "delete_move",
        "#tag" => "delete_edit",
        _ if entity_kind == "deck" => "delete_edit",
        _ => "delete_edit",
    }
}

/// 重新判定一个实体上的删除该不该扣住（每次有碰它的操作落进来都调）。
pub(crate) fn evaluate_holds(conn: &Connection, profile: &str, kind: &str, entity: &str, now: i64, t: &mut Touched) -> Result<(), String> {
    // 每条碰到实体的写入都会走这里；绝大多数实体从没被删过。先走 (实体, 键) 索引问一句「有没有删除」，
    // 没有就返回——否则每条写入都要把这个实体的全部操作读一遍，同一实体上的操作越多越慢（平方级）。
    let any_delete: bool = conn
        .prepare_cached("SELECT 1 FROM sync2_ent_ops WHERE profile_uid = srs_id(?1) AND kind = ?2 AND entity = srs_id(?3) AND what = 'deleted' LIMIT 1")
        .map_err(sql)?
        .exists(params![profile, kind, entity])
        .map_err(sql)?;
    if !any_delete {
        return Ok(());
    }
    let all = ops_of(conn, profile, kind, entity)?;
    let deleted_ops: Vec<OpId> = all.iter().filter(|(_, w)| w == "deleted").map(|(o, _)| *o).collect();
    if deleted_ops.is_empty() {
        return Ok(());
    }
    let mut writes: Vec<Op> = Vec::new();
    for id in &deleted_ops {
        if let Some(op) = load_op(conn, profile, id)? {
            writes.push(op);
        }
    }
    let others: Vec<(Op, String)> = {
        let mut v = Vec::new();
        for (id, w) in all.iter().filter(|(_, w)| w != "deleted") {
            if let Some(op) = load_op(conn, profile, id)? {
                // 迁移进来的旧修改记录不参与（没有 v2 因果上下文）。
                if let Ok(Body::Edit(EditBody { legacy: Some(_), .. })) = op.body() {
                    continue;
                }
                v.push((op, w.clone()));
            }
        }
        v
    };
    for d in &writes {
        let Some(body) = is_delete(d) else { continue };
        // 被同一寄存器上更晚的写入（恢复 / 再删）因果覆盖了：不是冲突（解决之后就是这样）。
        let dominated = writes.iter().any(|w| w.id != d.id && w.saw(&d.id));
        let conflicting: Vec<&(Op, String)> = if dominated { Vec::new() } else { others.iter().filter(|(x, _)| concurrent(d, x)).collect() };
        let held: bool = conn
            .prepare_cached("SELECT 1 FROM sync2_held WHERE profile_uid = srs_id(?1) AND device = ?2 AND seq = ?3")
            .map_err(sql)?
            .exists(params![profile, d.id.device.0.to_vec(), d.id.seq as i64])
            .map_err(sql)?;
        if !conflicting.is_empty() {
            let (eid, _) = edit_row(conn, profile, d, &body)?;
            if conn.prepare_cached("DELETE FROM srs_field_edits WHERE id = srs_id(?1)").map_err(sql)?.execute([&eid]).map_err(sql)? > 0 {
                t.dominated.push(eid);
            }
            conn.prepare_cached(
                "INSERT OR REPLACE INTO sync2_held (profile_uid, device, seq, kind, entity) VALUES (srs_id(?1), ?2, ?3, ?4, srs_id(?5))",
            )
            .map_err(sql)?
            .execute(params![profile, d.id.device.0.to_vec(), d.id.seq as i64, kind, entity])
            .map_err(sql)?;
            let mut kinds: BTreeSet<&str> = BTreeSet::new();
            for (_, w) in &conflicting {
                kinds.insert(conflict_kind(w, kind));
            }
            for k in kinds {
                let count = conflicting.iter().filter(|(_, w)| conflict_kind(w, kind) == k).count();
                let cid = blake3::hash(format!("{}:{}:{k}", d.id.device.text(), d.id.seq).as_bytes()).to_hex()[..32].to_owned();
                conn.prepare_cached(
                    "INSERT OR REPLACE INTO sync2_conflicts (id, profile_uid, kind, entity_kind, entity, device, seq, other_count, at) \
                     VALUES (?1, srs_id(?2), ?3, ?4, srs_id(?5), ?6, ?7, ?8, ?9)",
                )
                .map_err(sql)?
                .execute(params![cid, profile, k, kind, entity, d.id.device.0.to_vec(), d.id.seq as i64, count as i64, d.hlc.wall])
                .map_err(sql)?;
            }
            if !held {
                t.entities_changed.insert((kind.to_owned(), entity.to_owned()));
            }
        } else if held {
            conn.prepare_cached("DELETE FROM sync2_held WHERE profile_uid = srs_id(?1) AND device = ?2 AND seq = ?3")
                .map_err(sql)?
                .execute(params![profile, d.id.device.0.to_vec(), d.id.seq as i64])
                .map_err(sql)?;
            conn.prepare_cached("DELETE FROM sync2_conflicts WHERE profile_uid = srs_id(?1) AND device = ?2 AND seq = ?3")
                .map_err(sql)?
                .execute(params![profile, d.id.device.0.to_vec(), d.id.seq as i64])
                .map_err(sql)?;
            if !dominated {
                // 冲突不在了（并发的那一方被撤回等）：这条删除照常落进投影。
                super::land_edit(conn, profile, d, &body, None, now, t)?;
            }
            t.entities_changed.insert((kind.to_owned(), entity.to_owned()));
        }
    }
    Ok(())
}

/// 这条删除现在要不要扣住（落投影之前问）。
pub(crate) fn should_hold(conn: &Connection, profile: &str, kind: &str, entity: &str, d: &Op) -> Result<bool, String> {
    if is_delete(d).is_none() {
        return Ok(false);
    }
    for (id, w) in ops_of(conn, profile, kind, entity)? {
        let Some(x) = load_op(conn, profile, &id)? else { continue };
        if x.id == d.id {
            continue;
        }
        if w == "deleted" {
            if x.saw(&d.id) {
                return Ok(false);
            }
            continue;
        }
        if let Ok(Body::Edit(EditBody { legacy: Some(_), .. })) = x.body() {
            continue;
        }
        if concurrent(d, &x) {
            return Ok(true);
        }
    }
    Ok(false)
}

// ---------------------------------------------------------------- 彻底清除

fn is_purged(conn: &Connection, profile: &str, kind: &str, entity: &str) -> Result<bool, String> {
    conn.prepare_cached("SELECT 1 FROM sync2_purged WHERE profile_uid = srs_id(?1) AND kind = ?2 AND entity = srs_id(?3)")
        .map_err(sql)?
        .exists(params![profile, kind, entity])
        .map_err(sql)
}

/// 碰过这个实体的 `Purge` 操作（索引里 `what = '#purge'`）。
///
/// 这个索引是后加的：之前执行过的清除只在 `sync2_purged` 里留了「已清除」、不知道是哪条操作。遇到这种
/// （有清除标记、索引里却没有清除操作）就把日志里全部 `Purge` 操作补进索引一次（同一事务里；清除操作很少，
/// 补完之后不再走这条路）。补完仍找不到（日志被截断等）→ 返回 `None`：调用方按旧语义整体视为已清除。
fn purges_of(conn: &Connection, profile: &str, kind: &str, entity: &str) -> Result<Option<Vec<OpId>>, String> {
    if !is_purged(conn, profile, kind, entity)? {
        return Ok(Some(Vec::new()));
    }
    let find = |conn: &Connection| -> Result<Vec<OpId>, String> {
        Ok(ops_of(conn, profile, kind, entity)?.into_iter().filter(|(_, w)| w == "#purge").map(|(o, _)| o).collect())
    };
    let found = find(conn)?;
    if !found.is_empty() {
        return Ok(Some(found));
    }
    backfill_purge_index(conn, profile)?;
    let found = find(conn)?;
    Ok(if found.is_empty() { None } else { Some(found) })
}

/// 把日志里的 `Purge` 操作补进实体 → 操作索引（见 [purges_of]）。可重放（INSERT OR IGNORE）。
fn backfill_purge_index(conn: &Connection, profile: &str) -> Result<(), String> {
    let ids: Vec<(Vec<u8>, i64)> = conn
        .prepare_cached("SELECT device, seq FROM sync2_ops WHERE profile_uid = srs_id(?1) AND kind = ?2 AND purged = 0")
        .map_err(sql)?
        .query_map(params![profile, i64::from(crate::sync2::op::KIND_PURGE)], |r| Ok((r.get(0)?, r.get(1)?)))
        .map_err(sql)?
        .collect::<Result<_, _>>()
        .map_err(sql)?;
    for (d, s) in ids {
        let id = OpId { device: Id(d.try_into().map_err(|_| "bad device".to_string())?), seq: s as u64 };
        let Some(op) = load_op(conn, profile, &id)? else { continue };
        if let Ok(Body::Purge { kind, entity }) = op.body() {
            index(conn, profile, kind.wire(), &entity.text(), &id, "#purge")?;
        }
    }
    Ok(())
}

/// 这条刚到的内容操作要不要当场清除：实体被清除过，且这条操作**没见过**其中某一次清除（与清除并发 /
/// 在清除之前写的迟到操作）。见过全部清除的操作是清除之后的新内容（复活），照常落投影。
pub(crate) fn purged_for(conn: &Connection, profile: &str, kind: &str, entity: &str, op: &Op) -> Result<bool, String> {
    Ok(match purges_of(conn, profile, kind, entity)? {
        None => true,
        Some(ps) => ps.iter().any(|p| !op.saw(p)),
    })
}

/// 把一条操作的载荷换成哈希（本机日志里）；是本设备写的就记下要重写的段。
pub(crate) fn purge_op(conn: &Connection, profile: &str, id: &OpId, own: Option<&Id>) -> Result<(), String> {
    let Some(op) = load_op(conn, profile, id)? else { return Ok(()) };
    if op.purged {
        return Ok(());
    }
    let skel = op.purge();
    conn.prepare_cached(
        "UPDATE sync2_ops SET payload = ?4, purged = 1, sc = NULL, sc_at = NULL WHERE profile_uid = srs_id(?1) AND device = ?2 AND seq = ?3",
    )
        .map_err(sql)?
        .execute(params![profile, id.device.0.to_vec(), id.seq as i64, &skel.payload[..]])
        .map_err(sql)?;
    if own == Some(&id.device) {
        conn.prepare_cached(
            "INSERT OR IGNORE INTO sync2_rewrites (profile_uid, location, first) \
             SELECT l.profile_uid, l.location, s.first FROM sync2_locations l \
             JOIN sync2_segments s ON s.profile_uid = l.profile_uid AND s.device = ?2 AND s.first <= ?3 AND s.last >= ?3 \
             WHERE l.profile_uid = srs_id(?1)",
        )
        .map_err(sql)?
        .execute(params![profile, id.device.0.to_vec(), id.seq as i64])
        .map_err(sql)?;
    }
    Ok(())
}

/// 执行一条 `Purge{kind, entity}`：内容操作换成骨架、投影里的内容删掉（`deleted` 寄存器保留）。
///
/// 只清这条清除**没见过**之后的操作：因果上在它之后的操作（作者见过它，见 [purged_for]）不动——
/// 因果投递下它们本不会早于清除到达，这里按同一判据写，重放顺序怎样都得同一个结果。
pub(crate) fn purge_entity(conn: &Connection, profile: &str, kind: EntKind, entity: &str, purge: &Op, own: &Id, t: &mut Touched) -> Result<(), String> {
    conn.prepare_cached("INSERT OR IGNORE INTO sync2_purged (profile_uid, kind, entity) VALUES (srs_id(?1), ?2, srs_id(?3))")
        .map_err(sql)?
        .execute(params![profile, kind.wire(), entity])
        .map_err(sql)?;
    index(conn, profile, kind.wire(), entity, &purge.id, "#purge")?;
    // 清除之后的操作（复活）：它们的投影行与标签添加点留着。
    let mut after: BTreeSet<(Vec<u8>, i64)> = BTreeSet::new();
    for (id, w) in ops_of(conn, profile, kind.wire(), entity)? {
        if w == "deleted" || w == "#log" || w == "#purge" || id == purge.id {
            continue;
        }
        if let Some(x) = load_op(conn, profile, &id)? {
            if x.saw(&purge.id) {
                after.insert((id.device.0.to_vec(), id.seq as i64));
                continue;
            }
        }
        purge_op(conn, profile, &id, Some(own))?;
    }
    // 投影行：对应的操作（sync2_edit_ops）在清除之后的留下；其余（含没有操作映射的合成标签行）删掉。
    let gone: Vec<(String, Option<Vec<u8>>, Option<i64>)> = conn
        .prepare_cached(
            "SELECT srs_idt(f.id) AS id, m.device, m.seq FROM srs_field_edits f LEFT JOIN sync2_edit_ops m ON m.edit_id = f.id \
             WHERE f.entity_kind = ?1 AND f.entity_id = srs_id(?2) AND f.field_key != 'deleted'",
        )
        .map_err(sql)?
        .query_map(params![kind.wire(), entity], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
        .map_err(sql)?
        .collect::<Result<_, _>>()
        .map_err(sql)?;
    for (id, d, s) in gone {
        if let (Some(d), Some(s)) = (d, s) {
            if after.contains(&(d, s)) {
                continue;
            }
        }
        conn.prepare_cached("DELETE FROM srs_field_edits WHERE id = srs_id(?1)").map_err(sql)?.execute([&id]).map_err(sql)?;
        t.dominated.push(id);
    }
    if kind == EntKind::Note {
        let adds: Vec<(Vec<u8>, i64)> = conn
            .prepare_cached("SELECT DISTINCT device, seq FROM sync2_tag_adds WHERE profile_uid = srs_id(?1) AND note = srs_id(?2)")
            .map_err(sql)?
            .query_map(params![profile, entity], |r| Ok((r.get(0)?, r.get(1)?)))
            .map_err(sql)?
            .collect::<Result<_, _>>()
            .map_err(sql)?;
        let mut kept = false;
        for (d, s) in adds {
            if after.contains(&(d.clone(), s)) {
                kept = true;
                continue;
            }
            conn.prepare_cached("DELETE FROM sync2_tag_adds WHERE profile_uid = srs_id(?1) AND note = srs_id(?2) AND device = ?3 AND seq = ?4")
                .map_err(sql)?
                .execute(params![profile, entity, d, s])
                .map_err(sql)?;
        }
        if kept {
            refresh_tags_row(conn, profile, entity, t)?;
        }
    }
    t.entities_changed.insert((kind.wire().to_owned(), entity.to_owned()));
    t.purged.insert((kind.wire().to_owned(), entity.to_owned()));
    Ok(())
}
