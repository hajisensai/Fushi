//! 时间线（设计 §10.2）：操作日志永久保留，「备份」就是别删历史。
//!
//! 恢复到某个时刻 = 取那一刻的版本向量（每台设备 HLC 墙钟 ≤ 时刻的连续前缀；HLC 在设备内单调，所以是
//! 前缀）→ 对此后改过的每个寄存器 / 标签集合 / 实体，算出那一刻的值与现值求差 → 追加一批**补偿操作**
//! （字段改回、复活被删的、删除之后新建的、配置改回；可选：撤回此后的复习）。补偿操作照常同步，不覆盖任何
//! 设备；恢复之前先打还原点，所以恢复本身也能再恢复回去。

use std::collections::{BTreeMap, BTreeSet};

use rusqlite::{params, Connection};
use serde_json::{json, Value};

use super::{canonical, edit_row, in_savepoint, load_op, sql, Local};
use crate::store::SrsCore;
use crate::sync2::id::{Id, Key};
use crate::sync2::op::{Body, EditBody, EntKind, LogBody, Intent};
use crate::sync2::vv::{OpId, Vv};

/// 某一时刻的版本向量：每台设备 HLC 墙钟 ≤ [t] 的最大 seq。
pub(crate) fn vv_at(conn: &Connection, profile: &str, t: i64) -> Result<Vv, String> {
    let mut vv = Vv::new();
    let mut stmt = conn
        .prepare("SELECT device, MAX(seq) FROM sync2_ops WHERE profile_uid = srs_id(?1) AND wall <= ?2 GROUP BY device")
        .map_err(sql)?;
    let rows = stmt.query_map(params![profile, t], |r| Ok((r.get::<_, Vec<u8>>(0)?, r.get::<_, i64>(1)?))).map_err(sql)?;
    for r in rows {
        let (d, s) = r.map_err(sql)?;
        vv.set(Id(d.try_into().map_err(|_| "bad device".to_string())?), s as u64);
    }
    Ok(vv)
}

/// 恢复的目标：一个时刻，或一个还原点（打还原点那台设备当时已应用的全部操作 + 它自己到还原点为止的前缀）。
///
/// 还原点不能按它自己的墙钟截断：打还原点与随后的批量删除常落在同一毫秒，按 `wall <= t` 会把删除也算进
/// 「那一刻」，恢复什么都不做。按还原点操作的因果（deps + 自己的 seq）截断才是「它之前」。
pub enum RestoreTarget {
    At(i64),
    Checkpoint(OpId),
}

fn target_vv(conn: &Connection, profile: &str, target: &RestoreTarget) -> Result<Vv, String> {
    match target {
        RestoreTarget::At(t) => vv_at(conn, profile, *t),
        RestoreTarget::Checkpoint(id) => {
            let op = load_op(conn, profile, id)?.ok_or("checkpoint not found")?;
            let mut vv: Vv = (*op.deps).clone();
            vv.set(id.device, id.seq);
            Ok(vv)
        }
    }
}

#[derive(Default, Debug)]
pub(crate) struct Plan {
    pub bodies: Vec<Body>,
    pub fields: usize,
    pub revived: usize,
    pub removed: usize,
    pub tags: usize,
    pub reviews: usize,
}

/// 求补偿操作。
pub(crate) fn plan(conn: &Connection, profile: &str, target: &Vv, retract_reviews: bool, now: i64) -> Result<Plan, String> {
    let mut p = Plan::default();
    // 此后被碰过的（实体, 键）。
    let mut touched: BTreeMap<(String, String), BTreeSet<String>> = BTreeMap::new();
    let mut later_logs: Vec<OpId> = Vec::new();
    {
        let mut stmt = conn.prepare("SELECT kind, srs_idt(entity) AS entity, device, seq, what FROM sync2_ent_ops WHERE profile_uid = srs_id(?1)").map_err(sql)?;
        let rows = stmt
            .query_map([profile], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?, r.get::<_, Vec<u8>>(2)?, r.get::<_, i64>(3)?, r.get::<_, String>(4)?)))
            .map_err(sql)?;
        for r in rows {
            let (k, e, d, s, w) = r.map_err(sql)?;
            let id = OpId { device: Id(d.try_into().map_err(|_| "bad device".to_string())?), seq: s as u64 };
            if target.contains(&id) {
                continue;
            }
            if w == "#log" {
                if k == "card" {
                    later_logs.push(id);
                }
                continue;
            }
            if w == "#move" {
                continue;
            }
            // 迁移进来的整列表 `tags` 与 OR-Set 的标签操作是同一个集合。
            let w = if k == "note" && w == "tags" { "#tag".to_owned() } else { w };
            touched.entry((k, e)).or_default().insert(w);
        }
    }
    // 此后才有的实体（身份记录在 target 之外）：恢复 = 删除它。
    let mut created_after: BTreeSet<(String, String)> = BTreeSet::new();
    {
        let mut stmt = conn
            .prepare("SELECT device, seq, payload, purged FROM sync2_ops WHERE profile_uid = srs_id(?1) AND kind = ?2")
            .map_err(sql)?;
        let rows = stmt
            .query_map(params![profile, i64::from(crate::sync2::op::KIND_ENTITY)], |r| {
                Ok((r.get::<_, Vec<u8>>(0)?, r.get::<_, i64>(1)?, r.get::<_, Vec<u8>>(2)?, r.get::<_, i64>(3)?))
            })
            .map_err(sql)?;
        let mut before: BTreeSet<(String, String)> = BTreeSet::new();
        let mut after: BTreeSet<(String, String)> = BTreeSet::new();
        for r in rows {
            let (d, s, payload, purged) = r.map_err(sql)?;
            if purged != 0 {
                continue;
            }
            let id = OpId { device: Id(d.try_into().map_err(|_| "bad device".to_string())?), seq: s as u64 };
            if let Ok(Body::Entity { kind, id: eid, .. }) = Body::decode(crate::sync2::op::KIND_ENTITY, &payload) {
                let key = (kind.wire().to_owned(), eid.text());
                if target.contains(&id) {
                    before.insert(key);
                } else {
                    after.insert(key);
                }
            }
        }
        for k in after {
            if !before.contains(&k) && matches!(k.0.as_str(), "note" | "deck" | "notetype") {
                created_after.insert(k);
            }
        }
    }
    for (kind, entity) in &created_after {
        let k = EntKind::parse(kind).ok_or("bad kind")?;
        p.bodies.push(edit_body(k, entity, "deleted", json!(now)));
        p.removed += 1;
    }
    for ((kind, entity), keys) in &touched {
        if created_after.contains(&(kind.clone(), entity.clone())) {
            continue;
        }
        let Some(k) = EntKind::parse(kind) else { continue };
        for key in keys {
            if key == "#tag" {
                let then = tags_at(conn, profile, entity, target)?;
                let now_tags = super::semantics::current_tags(conn, profile, entity)?;
                for t in then.iter().filter(|x| !now_tags.contains(x)) {
                    p.bodies.push(Body::TagAdd { note: Key::of(entity), tag: t.clone() });
                    p.tags += 1;
                }
                for t in now_tags.iter().filter(|x| !then.contains(x)) {
                    p.bodies.push(Body::TagRemove { note: Key::of(entity), tag: t.clone() });
                    p.tags += 1;
                }
                continue;
            }
            let then = value_at(conn, profile, k, entity, key, Some(target))?;
            let cur = value_at(conn, profile, k, entity, key, None)?;
            if !crate::registers::same_value(&then, &cur) {
                if key == "deleted" {
                    if cur.is_i64() && then.is_null() {
                        p.revived += 1;
                    } else if then.is_i64() {
                        p.removed += 1;
                    }
                } else {
                    p.fields += 1;
                }
                p.bodies.push(edit_body(k, entity, key, then));
            }
        }
    }
    if retract_reviews {
        let mut undo: Vec<(String, String, Option<Key>)> = Vec::new();
        for id in later_logs {
            let Some(op) = load_op(conn, profile, &id)? else { continue };
            if let Ok(Body::Log(l)) = op.body() {
                if l.kind == "review" && l.rating.is_some() {
                    undo.push((l.id.text(), l.card.text(), l.note.clone()));
                }
            }
        }
        undo.sort();
        for (log, card, note) in undo {
            p.bodies.push(Body::Log(LogBody {
                id: Key::Uuid(Id::new_v7(now.max(0) as u64)),
                card: Key::of(&card),
                note,
                kind: "undo".into(),
                rating: None,
                revokes: Some(Key::of(&log)),
                at: now,
                ts: 0,
                origin: "fushi".into(),
                rtype: "manual".into(),
                dur: 0,
                params: None,
                alg: None,
                utc_off: 0,
                rollover: 4,
                anki_id: None,
                fv: 1,
                intent: Intent::Absolute,
                res: None,
                extra: "{\"restoreOf\":\"timeline\"}".into(),
                legacy_hlc: None,
                legacy_server_time: None,
            }));
            p.reviews += 1;
        }
    }
    Ok(p)
}

fn edit_body(kind: EntKind, entity: &str, key: &str, v: Value) -> Body {
    Body::Edit(EditBody { kind, entity: Key::of(entity), key: key.into(), value: canonical(&v), machine: false, ts: 0, legacy: None })
}

/// 某寄存器在 [target]（None = 现在）时的生效值：把那时已有的写入按落库规则重新落一遍、取胜者。
fn value_at(conn: &Connection, profile: &str, kind: EntKind, entity: &str, key: &str, target: Option<&Vv>) -> Result<Value, String> {
    let mut rows: Vec<String> = Vec::new();
    let mut stmt = conn
        .prepare_cached("SELECT device, seq FROM sync2_ent_ops WHERE profile_uid = srs_id(?1) AND kind = ?2 AND entity = srs_id(?3) AND what = ?4 ORDER BY device, seq")
        .map_err(sql)?;
    let ids: Vec<(Vec<u8>, i64)> = stmt
        .query_map(params![profile, kind.wire(), entity, key], |r| Ok((r.get(0)?, r.get(1)?)))
        .map_err(sql)?
        .collect::<Result<_, _>>()
        .map_err(sql)?;
    for (d, s) in ids {
        let id = OpId { device: Id(d.try_into().map_err(|_| "bad device".to_string())?), seq: s as u64 };
        if target.is_some_and(|t| !t.contains(&id)) {
            continue;
        }
        let Some(op) = load_op(conn, profile, &id)? else { continue };
        if let Ok(Body::Edit(e)) = op.body() {
            rows.push(canonical(&edit_row(conn, profile, &op, &e)?.1));
        }
    }
    let items: Vec<(&str, Option<i64>)> = rows.iter().map(|r| (r.as_str(), None)).collect();
    // 依次落（全部当「到达」），留下没被支配的，再按读路径取胜者。
    let (landed, deleted) = crate::registers::land_stored(&items, 0)?;
    let mut live: BTreeSet<usize> = BTreeSet::new();
    for (i, ok) in landed.iter().enumerate() {
        if *ok {
            for d in &deleted[i] {
                live.remove(d);
            }
            live.insert(i);
        }
    }
    let live_rows: Vec<(&str, Option<i64>)> = live.iter().map(|&i| (rows[i].as_str(), None)).collect();
    crate::registers::register_value(&live_rows, key)
}

/// 某笔记在 [target] 时的标签（OR-Set 按那时已有的添加 / 观察删除重算）。
fn tags_at(conn: &Connection, profile: &str, note: &str, target: &Vv) -> Result<Vec<String>, String> {
    let mut stmt = conn
        .prepare_cached("SELECT device, seq FROM sync2_ent_ops WHERE profile_uid = srs_id(?1) AND kind = 'note' AND entity = srs_id(?2) AND what IN ('#tag', 'tags')")
        .map_err(sql)?;
    let ids: Vec<(Vec<u8>, i64)> = stmt
        .query_map(params![profile, note], |r| Ok((r.get(0)?, r.get(1)?)))
        .map_err(sql)?
        .collect::<Result<_, _>>()
        .map_err(sql)?;
    let mut ops = Vec::new();
    for (d, s) in ids {
        let id = OpId { device: Id(d.try_into().map_err(|_| "bad device".to_string())?), seq: s as u64 };
        if target.contains(&id) {
            if let Some(op) = load_op(conn, profile, &id)? {
                ops.push(op);
            }
        }
    }
    ops.sort_by_key(|o| (o.hlc.wall, o.hlc.logical, o.id.device, o.id.seq));
    let mut adds: Vec<(String, OpId)> = Vec::new();
    for op in &ops {
        match op.body() {
            Ok(Body::TagAdd { tag, .. }) => adds.push((tag, op.id)),
            Ok(Body::Edit(e)) if e.key == "tags" => {
                if let Ok(Value::Array(xs)) = serde_json::from_str::<Value>(&e.value) {
                    for x in xs.iter().filter_map(Value::as_str) {
                        adds.push((x.to_owned(), op.id));
                    }
                }
            }
            _ => {}
        }
    }
    for op in &ops {
        if let Ok(Body::TagRemove { tag, .. }) = op.body() {
            adds.retain(|(t, a)| !(t == &tag && op.saw(a)));
        }
    }
    let mut out: Vec<String> = Vec::new();
    for (t, _) in adds {
        if !out.contains(&t) {
            out.push(t);
        }
    }
    Ok(out)
}

impl SrsCore {
    /// 预览恢复到 [to]：会改回多少字段、复活 / 删除多少实体、改多少标签、撤回多少次复习。只读（[plan] 只算补偿
    /// 操作、不落库）：走读连接的快照（[SrsCore::read_visible]）。
    pub fn sync2_plan_restore(&self, profile: &str, to: &RestoreTarget, retract_reviews: bool, now: i64) -> Result<Value, String> {
        self.read_visible(|c| {
            let target = target_vv(c, profile, to)?;
            let p = plan(c, profile, &target, retract_reviews, now)?;
            Ok(json!({"fields": p.fields, "revived": p.revived, "removed": p.removed, "tags": p.tags, "reviews": p.reviews}))
        })
    }

    /// 恢复到 [to]（先打还原点，再追加补偿操作）。返回与 `sync2_apply_local` 同形的投影变化。
    pub fn sync2_restore(&self, profile: &str, to: &RestoreTarget, retract_reviews: bool, now: i64) -> Result<Value, String> {
        let bodies = {
            let w = self.writer()?;
            in_savepoint(&w, |c| {
                Local::load(c, profile)?.ok_or("sync2 not initialised for this profile")?;
                let target = target_vv(c, profile, to)?;
                Ok(plan(c, profile, &target, retract_reviews, now)?.bodies)
            })?
        };
        let label = match to {
            RestoreTarget::At(t) => format!("before restore to {t}"),
            RestoreTarget::Checkpoint(id) => format!("before restore to {}:{}", id.device.text(), id.seq),
        };
        let mut all = vec![Body::Checkpoint { name: label, reason: "restore".into() }];
        all.extend(bodies);
        self.sync2_append(profile, now, all)
    }

    /// 还原点列表（新的在前）。
    pub fn sync2_checkpoints(&self, profile: &str) -> Result<Value, String> {
        let r = self.reader()?;
        let mut stmt = r
            .prepare("SELECT wall, name, reason, device, seq FROM sync2_checkpoints WHERE profile_uid = srs_id(?1) ORDER BY wall DESC, seq DESC")
            .map_err(sql)?;
        let rows = stmt
            .query_map([profile], |x| {
                let device = <[u8; 16]>::try_from(x.get::<_, Vec<u8>>(3)?).map(|a| Id(a).text()).unwrap_or_default();
                Ok(json!({
                    "at": x.get::<_, i64>(0)?,
                    "name": x.get::<_, String>(1)?,
                    "reason": x.get::<_, String>(2)?,
                    "device": device,
                    "seq": x.get::<_, i64>(4)?,
                }))
            })
            .map_err(sql)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(sql)?;
        Ok(Value::Array(rows))
    }
}

impl SrsCore {
    /// 一个实体的修改历史（设计 §10.2：每张卡、每个字段的修改历史——谁、哪台设备、何时）：碰过它的全部字段修改与
    /// 标签操作，**含**被覆盖、被因果支配而早已不在投影里的；新的在前。迁移来的旧记录按旧写入者 / 旧 HLC 报。
    /// 被彻底清除的实体只剩骨架：报 `purged`，不报内容。
    pub fn sync2_history(&self, profile: &str, kind: &str, entity: &str) -> Result<Value, String> {
        let r = self.reader()?;
        let mut out: Vec<(i64, u32, Value)> = Vec::new();
        for (id, what) in super::semantics::ops_of(&r, profile, kind, entity)? {
            if what == "#log" || what == "#move" {
                continue;
            }
            let Some(op) = load_op(&r, profile, &id)? else { continue };
            let device = id.device.text();
            let (wall, logical) = (op.hlc.wall, op.hlc.logical);
            let entry = match op.body().map_err(|e| e.to_string())? {
                Body::Edit(e) => {
                    let (writer, at) = match &e.legacy {
                        Some(l) => (
                            l.writer.clone(),
                            l.hlc.split(':').next().and_then(|x| x.parse::<i64>().ok()).unwrap_or(wall),
                        ),
                        None => (device.clone(), wall),
                    };
                    json!({
                        "key": e.key,
                        "value": serde_json::from_str::<Value>(&e.value).unwrap_or(Value::Null),
                        "writer": writer,
                        "device": device,
                        "seq": id.seq,
                        "at": at,
                        "machine": e.machine,
                    })
                }
                Body::TagAdd { tag, .. } => json!({"key": "tags", "tagAdded": tag, "writer": device, "device": device, "seq": id.seq, "at": wall}),
                Body::TagRemove { tag, .. } => {
                    json!({"key": "tags", "tagRemoved": tag, "writer": device, "device": device, "seq": id.seq, "at": wall})
                }
                Body::Purged => json!({"key": what, "purged": true, "writer": device, "device": device, "seq": id.seq, "at": wall}),
                _ => continue,
            };
            let at = entry["at"].as_i64().unwrap_or(wall);
            out.push((at, logical, entry));
        }
        out.sort_by(|a, b| b.0.cmp(&a.0).then(b.1.cmp(&a.1)));
        Ok(Value::Array(out.into_iter().map(|x| x.2).collect()))
    }
}
