//! 投影里有专门语义的几类操作（设计 §3.3、§5.3、§10.5）：
//!
//! - **标签 OR-Set（加胜）**：标签不再是整列表的多值寄存器。`TagAdd` 记一个添加点，`TagRemove` 只抹掉移除者
//!   见过的添加点；一边加、一边并发删同一标签 → 保留。投影成每条笔记一行合成的 `tags` 修改记录（读侧照旧
//!   读 `tags` 寄存器）。迁移进来的旧 `tags` 记录按「添加列表里的每个标签」并入。
//! - **破坏性并发进冲突中心**：删除（`deleted` 写成时刻）与因果上并发的编辑 / 标签 / 复习 / 移入该牌组
//!   共存时，不自动判输赢：这条删除先**扣住**（不进投影，实体保持可见、可复习），生成冲突项；用户选
//!   「删除」或「保留」= 追加一条因果覆盖双方的新写入，冲突自然消失、各设备结论一致。
//! - **彻底清除**：`Purge{entity}` 让每台设备把本机日志里该实体的内容载荷换成哈希（骨架与链不变），删掉
//!   投影里的内容，并重写自己写过的、含这些操作的段。之后再到的同实体内容操作一到就清除。

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
        "INSERT OR IGNORE INTO sync2_ent_ops (profile_uid, kind, entity, device, seq, what) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
    )
    .map_err(sql)?
    .execute(params![profile, kind, entity, op.device.0.to_vec(), op.seq as i64, what])
    .map_err(sql)?;
    Ok(())
}

pub(crate) fn ops_of(conn: &Connection, profile: &str, kind: &str, entity: &str) -> Result<Vec<(OpId, String)>, String> {
    let mut stmt = conn
        .prepare_cached("SELECT device, seq, what FROM sync2_ent_ops WHERE profile_uid = ?1 AND kind = ?2 AND entity = ?3")
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
        .prepare_cached("SELECT tag, wall, logical, device FROM sync2_tag_adds WHERE profile_uid = ?1 AND note = ?2")
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
        .prepare_cached("SELECT tags FROM sync2_tag_order WHERE profile_uid = ?1 AND note = ?2")
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

/// 顺序提示：HLC 大者胜。
pub(crate) fn tag_order(conn: &Connection, profile: &str, note: &str, tags: &[String], op: &Op) -> Result<(), String> {
    let cur: Option<(i64, i64, Vec<u8>)> = conn
        .prepare_cached("SELECT wall, logical, device FROM sync2_tag_order WHERE profile_uid = ?1 AND note = ?2")
        .map_err(sql)?
        .query_row(params![profile, note], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
        .optional()
        .map_err(sql)?;
    let me = (op.hlc.wall, i64::from(op.hlc.logical), op.id.device.0.to_vec());
    if cur.is_some_and(|c| c >= me) {
        return Ok(());
    }
    conn.prepare_cached(
        "INSERT OR REPLACE INTO sync2_tag_order (profile_uid, note, tags, wall, logical, device) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
    )
    .map_err(sql)?
    .execute(params![profile, note, serde_json::to_string(tags).map_err(|e| e.to_string())?, me.0, me.1, me.2])
    .map_err(sql)?;
    Ok(())
}

/// 这条笔记最近一次标签操作的 HLC（合成行的 `hlc`：笔记的「修改时间」按它算）。
fn last_tag_hlc(conn: &Connection, profile: &str, note: &str) -> Result<String, String> {
    let row: Option<(i64, i64, Vec<u8>)> = conn
        .prepare_cached(
            "SELECT o.wall, o.logical, o.device FROM sync2_ent_ops e JOIN sync2_ops o \
             ON o.profile_uid = e.profile_uid AND o.device = e.device AND o.seq = e.seq \
             WHERE e.profile_uid = ?1 AND e.kind = 'note' AND e.entity = ?2 AND e.what IN ('#tag', 'tags') \
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
        "INSERT OR IGNORE INTO sync2_tag_adds (profile_uid, note, tag, device, seq, wall, logical) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
    )
    .map_err(sql)?
    .execute(params![profile, note, tag, op.id.device.0.to_vec(), op.id.seq as i64, op.hlc.wall, i64::from(op.hlc.logical)])
    .map_err(sql)?;
    Ok(())
}

/// 观察删除：只抹掉 [op] 的作者见过的添加点（并发的添加保留 = 加胜）。
pub(crate) fn tag_remove(conn: &Connection, profile: &str, note: &str, tag: &str, op: &Op) -> Result<(), String> {
    let adds: Vec<(Vec<u8>, i64)> = conn
        .prepare_cached("SELECT device, seq FROM sync2_tag_adds WHERE profile_uid = ?1 AND note = ?2 AND tag = ?3")
        .map_err(sql)?
        .query_map(params![profile, note, tag], |r| Ok((r.get(0)?, r.get(1)?)))
        .map_err(sql)?
        .collect::<Result<_, _>>()
        .map_err(sql)?;
    for (d, s) in adds {
        let device = Id(d.clone().try_into().map_err(|_| "bad device".to_string())?);
        if op.saw(&OpId { device, seq: s as u64 }) {
            conn.prepare_cached("DELETE FROM sync2_tag_adds WHERE profile_uid = ?1 AND note = ?2 AND tag = ?3 AND device = ?4 AND seq = ?5")
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
        .prepare_cached("SELECT json FROM srs_field_edits WHERE id = ?1")
        .map_err(sql)?
        .query_row([&id], |r| r.get(0))
        .optional()
        .map_err(sql)?;
    let others: Vec<String> = conn
        .prepare_cached("SELECT id FROM srs_field_edits WHERE entity_kind = 'note' AND entity_id = ?1 AND field_key = 'tags' AND id != ?2")
        .map_err(sql)?
        .query_map(params![note, id], |r| r.get(0))
        .map_err(sql)?
        .collect::<Result<_, _>>()
        .map_err(sql)?;
    if old.as_deref() == Some(text.as_str()) && others.is_empty() {
        return Ok(());
    }
    for o in &others {
        conn.prepare_cached("DELETE FROM srs_field_edits WHERE id = ?1").map_err(sql)?.execute([o]).map_err(sql)?;
        t.dominated.push(o.clone());
    }
    conn.prepare_cached(
        "INSERT OR REPLACE INTO srs_field_edits (id, profile_uid, entity_kind, entity_id, field_key, writer_id, seq, json) \
         VALUES (?1, ?2, 'note', ?3, 'tags', ?4, 1, ?5)",
    )
    .map_err(sql)?
    .execute(params![id, profile, note, writer, text])
    .map_err(sql)?;
    t.events.push(json!({"t": "edit", "x": row}));
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
        .prepare_cached("SELECT 1 FROM sync2_ent_ops WHERE profile_uid = ?1 AND kind = ?2 AND entity = ?3 AND what = 'deleted' LIMIT 1")
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
            .prepare_cached("SELECT 1 FROM sync2_held WHERE profile_uid = ?1 AND device = ?2 AND seq = ?3")
            .map_err(sql)?
            .exists(params![profile, d.id.device.0.to_vec(), d.id.seq as i64])
            .map_err(sql)?;
        if !conflicting.is_empty() {
            let (eid, _) = edit_row(conn, profile, d, &body)?;
            if conn.prepare_cached("DELETE FROM srs_field_edits WHERE id = ?1").map_err(sql)?.execute([&eid]).map_err(sql)? > 0 {
                t.dominated.push(eid);
            }
            conn.prepare_cached(
                "INSERT OR REPLACE INTO sync2_held (profile_uid, device, seq, kind, entity) VALUES (?1, ?2, ?3, ?4, ?5)",
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
                     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
                )
                .map_err(sql)?
                .execute(params![cid, profile, k, kind, entity, d.id.device.0.to_vec(), d.id.seq as i64, count as i64, d.hlc.wall])
                .map_err(sql)?;
            }
            if !held {
                t.entities_changed.insert((kind.to_owned(), entity.to_owned()));
            }
        } else if held {
            conn.prepare_cached("DELETE FROM sync2_held WHERE profile_uid = ?1 AND device = ?2 AND seq = ?3")
                .map_err(sql)?
                .execute(params![profile, d.id.device.0.to_vec(), d.id.seq as i64])
                .map_err(sql)?;
            conn.prepare_cached("DELETE FROM sync2_conflicts WHERE profile_uid = ?1 AND device = ?2 AND seq = ?3")
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

pub(crate) fn is_purged(conn: &Connection, profile: &str, kind: &str, entity: &str) -> Result<bool, String> {
    conn.prepare_cached("SELECT 1 FROM sync2_purged WHERE profile_uid = ?1 AND kind = ?2 AND entity = ?3")
        .map_err(sql)?
        .exists(params![profile, kind, entity])
        .map_err(sql)
}

/// 把一条操作的载荷换成哈希（本机日志里）；是本设备写的就记下要重写的段。
pub(crate) fn purge_op(conn: &Connection, profile: &str, id: &OpId, own: Option<&Id>) -> Result<(), String> {
    let Some(op) = load_op(conn, profile, id)? else { return Ok(()) };
    if op.purged {
        return Ok(());
    }
    let skel = op.purge();
    conn.prepare_cached("UPDATE sync2_ops SET payload = ?4, purged = 1 WHERE profile_uid = ?1 AND device = ?2 AND seq = ?3")
        .map_err(sql)?
        .execute(params![profile, id.device.0.to_vec(), id.seq as i64, &skel.payload[..]])
        .map_err(sql)?;
    if own == Some(&id.device) {
        conn.prepare_cached(
            "INSERT OR IGNORE INTO sync2_rewrites (profile_uid, location, first) \
             SELECT l.profile_uid, l.location, s.first FROM sync2_locations l \
             JOIN sync2_segments s ON s.profile_uid = l.profile_uid AND s.device = ?2 AND s.first <= ?3 AND s.last >= ?3 \
             WHERE l.profile_uid = ?1",
        )
        .map_err(sql)?
        .execute(params![profile, id.device.0.to_vec(), id.seq as i64])
        .map_err(sql)?;
    }
    Ok(())
}

/// 执行一条 `Purge{kind, entity}`：内容操作换成骨架、投影里的内容删掉（`deleted` 寄存器保留）。
pub(crate) fn purge_entity(conn: &Connection, profile: &str, kind: EntKind, entity: &str, own: &Id, t: &mut Touched) -> Result<(), String> {
    conn.prepare_cached("INSERT OR IGNORE INTO sync2_purged (profile_uid, kind, entity) VALUES (?1, ?2, ?3)")
        .map_err(sql)?
        .execute(params![profile, kind.wire(), entity])
        .map_err(sql)?;
    for (id, w) in ops_of(conn, profile, kind.wire(), entity)? {
        if w == "deleted" || w == "#log" {
            continue;
        }
        purge_op(conn, profile, &id, Some(own))?;
    }
    let gone: Vec<String> = conn
        .prepare_cached("SELECT id FROM srs_field_edits WHERE entity_kind = ?1 AND entity_id = ?2 AND field_key != 'deleted'")
        .map_err(sql)?
        .query_map(params![kind.wire(), entity], |r| r.get(0))
        .map_err(sql)?
        .collect::<Result<_, _>>()
        .map_err(sql)?;
    for id in gone {
        conn.prepare_cached("DELETE FROM srs_field_edits WHERE id = ?1").map_err(sql)?.execute([&id]).map_err(sql)?;
        t.dominated.push(id);
    }
    if kind == EntKind::Note {
        conn.prepare_cached("DELETE FROM sync2_tag_adds WHERE profile_uid = ?1 AND note = ?2")
            .map_err(sql)?
            .execute(params![profile, entity])
            .map_err(sql)?;
    }
    t.entities_changed.insert((kind.wire().to_owned(), entity.to_owned()));
    t.purged.insert((kind.wire().to_owned(), entity.to_owned()));
    Ok(())
}
