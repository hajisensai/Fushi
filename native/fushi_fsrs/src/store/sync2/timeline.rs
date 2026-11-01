//! 时间线（设计 §10.2）：操作日志永久保留，「备份」就是别删历史。
//!
//! 恢复到某个时刻 = 取那一刻的操作截面（[Cut]：每台设备 HLC 墙钟 ≤ 时刻的连续前缀，加上墙钟在后、但按自带的
//! 原始时刻算在前的迁移 / 并入记录）→ 对此后改过的每个寄存器 / 标签集合 / 实体，算出那一刻的值与现值求差 → 追加一批**补偿操作**
//! （字段改回、复活被删的、删除之后新建的、配置改回；可选：撤回此后的复习）。补偿操作照常同步，不覆盖任何
//! 设备；恢复之前先打还原点，所以恢复本身也能再恢复回去。

use std::collections::{BTreeMap, BTreeSet, HashSet};

use rusqlite::{params, Connection, OptionalExtension};
use serde_json::{json, Value};

use super::{canonical, edit_row, in_savepoint, load_op, sql, Local};
use crate::store::SrsCore;
use crate::sync2::id::{Id, Key};
use crate::sync2::op::{self as op, Body, EditBody, EntKind, LogBody, Intent};
use crate::sync2::vv::{OpId, Vv};

/// 恢复的目标：一个时刻，或一个还原点（打还原点那台设备当时已应用的全部操作 + 它自己到还原点为止的前缀）。
///
/// 还原点不能按它自己的墙钟截断：打还原点与随后的批量删除常落在同一毫秒，按 `wall <= t` 会把删除也算进
/// 「那一刻」，恢复什么都不做。按还原点操作的因果（deps + 自己的 seq）截断才是「它之前」。
pub enum RestoreTarget {
    At(i64),
    Checkpoint(OpId),
}

/// 恢复目标在操作日志上的截面：哪些操作算「那一刻之前」。
///
/// 一条操作的墙钟是它**进这本日志**的时刻。本机写的操作这就是它发生的时刻；但迁移进来的旧修改记录 / 旧日志
/// （v1 → v2 迁移，设计 §11 第 5 条）、并入的已盖戳备份事件，墙钟是迁移 / 并入那一刻，内容本身早就有了——
/// 旧修改记录带着旧 HLC（`LegacyStamp.hlc`，物理时刻在冒号前），日志带着发生时刻（`LogBody.at`）。只按墙钟截，
/// 选到迁移之前的时刻会把迁移来的全部历史当成「之后才有的」：实体全被删、字段全被清（用户库实测 15250 个实体）。
///
/// 所以「那一刻之前」按每条操作的**生效时刻** = min(墙钟, 自带的原始时刻) 判断：
/// - 本机写的修改 / 身份记录：只有墙钟。
/// - 带 `LegacyStamp` 的修改：旧 HLC 的物理时刻。旧 HLC 是旧协议给这条修改盖的时刻，旧版本的「谁覆盖谁」也是按它排的，
///   是迁移能拿到的唯一可信时刻。
/// - 日志：发生时刻 `at`（「撤回此后的复习」按复习发生在不在那一刻之后算，迁移来的旧复习因此不会被当成新复习撤回）。
/// - 迁移来的身份记录没有自己的原始时刻（`srs_entities.created_at` 对导入的 Anki 内容是 Anki 里的创建时刻，早于进这个
///   集合）：不单独判，实体「那一刻在不在」由 [plan] 看它的身份记录**或任一条内容修改**在不在截面里——内容在，实体就在。
///
/// 取 min 而不是只取原始时刻：一条操作不可能晚于它进日志的时刻（时钟偏差的旧 HLC 不会把已有的内容推到未来）。于是墙钟
/// ≤ 时刻的操作一定在截面里（就是原来的版本向量前缀），只需对墙钟在后的修改 / 日志看原始时刻。
/// 还原点目标按因果截（见 [RestoreTarget]），迁移操作在还原点之前就都在它的依赖里，不需要原始时刻。
pub(crate) struct Cut {
    vv: Vv,
    /// 墙钟在那一刻之后、原始时刻在那一刻之前（含）的操作。
    stamped_before: HashSet<OpId>,
}

impl Cut {
    pub(crate) fn contains(&self, id: &OpId) -> bool {
        self.vv.contains(id) || self.stamped_before.contains(id)
    }
}

/// 旧 HLC 文本（`physical:counter:writer`）的物理时刻。
fn hlc_physical(hlc: &str) -> Option<i64> {
    hlc.split(':').next()?.parse().ok()
}

/// 按时刻 [t] 的截面：墙钟前缀 + 墙钟在后但原始时刻 ≤ [t] 的修改 / 日志。整张操作表只顺序扫一遍（墙钟没有索引，
/// 版本向量前缀与原始时刻同一次扫出来），载荷只对墙钟在后的修改 / 日志读。
fn cut_at(conn: &Connection, profile: &str, t: i64) -> Result<Cut, String> {
    let mut vv = Vv::new();
    let mut stamped_before = HashSet::new();
    let mut stmt = conn
        .prepare(
            "SELECT device, seq, wall, kind, CASE WHEN wall > ?2 AND purged = 0 AND kind IN (?3, ?4) THEN payload END, sc, sc_at              FROM sync2_ops WHERE profile_uid = srs_id(?1)",
        )
        .map_err(sql)?;
    let mut rows = stmt.query(params![profile, t, i64::from(op::KIND_EDIT), i64::from(op::KIND_LOG)]).map_err(sql)?;
    while let Some(r) = rows.next().map_err(sql)? {
        let d: Vec<u8> = r.get(0).map_err(sql)?;
        let id = OpId { device: Id(d.try_into().map_err(|_| "bad device".to_string())?), seq: r.get::<_, i64>(1).map_err(sql)? as u64 };
        if r.get::<_, i64>(2).map_err(sql)? <= t {
            // 墙钟在设备内单调：≤ t 的是前缀，取最大 seq。
            if id.seq > vv.get(&id.device) {
                vv.set(id.device, id.seq);
            }
            continue;
        }
        let Some(payload) = r.get::<_, Option<Vec<u8>>>(4).map_err(sql)? else { continue };
        let kind = r.get::<_, i64>(3).map_err(sql)? as u16;
        let original = if kind == op::KIND_EDIT {
            match Body::decode(kind, &payload) {
                Ok(Body::Edit(EditBody { legacy: Some(l), .. })) => hlc_physical(&l.hlc),
                _ => None,
            }
        } else {
            let payload = super::snapshots::unpack_payload(conn, payload, r.get(5).map_err(sql)?, r.get(6).map_err(sql)?)?;
            match Body::decode(kind, &payload) {
                Ok(Body::Log(l)) => Some(l.at),
                _ => None,
            }
        };
        if original.is_some_and(|o| o <= t) {
            stamped_before.insert(id);
        }
    }
    Ok(Cut { vv, stamped_before })
}

pub(crate) fn target_cut(conn: &Connection, profile: &str, target: &RestoreTarget) -> Result<Cut, String> {
    match target {
        RestoreTarget::At(t) => cut_at(conn, profile, *t),
        RestoreTarget::Checkpoint(id) => {
            let op = load_op(conn, profile, id)?.ok_or("checkpoint not found")?;
            let mut vv: Vv = (*op.deps).clone();
            vv.set(id.device, id.seq);
            Ok(Cut { vv, stamped_before: HashSet::new() })
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
pub(crate) fn plan(conn: &Connection, profile: &str, target: &Cut, retract_reviews: bool, now: i64) -> Result<Plan, String> {
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
    // 此后才有的实体（身份记录与内容都在截面之外）：恢复 = 删除它。迁移来的实体身份记录的墙钟是迁移时刻，
    // 它那一刻在不在看内容（[Cut] 的说明）。
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
            if !before.contains(&k) && matches!(k.0.as_str(), "note" | "deck" | "notetype") && !has_content_in(conn, profile, &k.0, &k.1, target)? {
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
            let then = restored_value(conn, profile, k, entity, key, target)?;
            let cur = value_at(conn, profile, k, entity, key, None)?.unwrap_or(Value::Null);
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

/// 实体在 [target] 里有没有任何内容（字段修改、标签操作；不算日志 / 移卡索引 / 清除）。
fn has_content_in(conn: &Connection, profile: &str, kind: &str, entity: &str, target: &Cut) -> Result<bool, String> {
    Ok(super::semantics::ops_of(conn, profile, kind, entity)?
        .iter()
        .any(|(id, w)| !matches!(w.as_str(), "#log" | "#move" | "#purge") && target.contains(id)))
}

fn edit_body(kind: EntKind, entity: &str, key: &str, v: Value) -> Body {
    Body::Edit(EditBody { kind, entity: Key::of(entity), key: key.into(), value: canonical(&v), machine: false, ts: 0, legacy: None })
}

/// 恢复要写回的值：[target] 那一刻这个寄存器的生效值。
///
/// 那一刻**没有任何生效记录**时（键是之后才第一次写的），要还原的是「没有记录」，不是某个值：
/// - 卡片标志（`deck` / `suspended` / `buried` / `flag` / `newPos`）没有自己的记录时按血统继承前身的（registers.rs
///   `cards_group`），而自己记一条 null 会**挡住**继承（`buried = null` 是「取消埋卡」的显式写法）——所以写回那一刻
///   从血统继承到的值；血统里也没有就写 null。
/// - 其余寄存器写 null：读路径把「生效值为 null」与「没有记录」视为同一状态（registers.rs `Entity::is_set`），
///   带子键的映射（笔记类型 `fieldDef/` `tmplDef/` `fieldDesc/`、笔记 `f/`）里这一项消失，内置笔记类型回到跟随代码的默认值。
fn restored_value(conn: &Connection, profile: &str, kind: EntKind, entity: &str, key: &str, target: &Cut) -> Result<Value, String> {
    if let Some(v) = value_at(conn, profile, kind, entity, key, Some(target))? {
        return Ok(v);
    }
    if kind == EntKind::Card && !key.starts_with(HISTORY_FROM) {
        if let Some(v) = card_inherited_at(conn, profile, entity, key, target)? {
            return Ok(v);
        }
    }
    Ok(Value::Null)
}

const HISTORY_FROM: &str = "historyFrom/";

/// [card] 在 [target] 时从血统继承到的 [key]：与 registers.rs `cards_group` 同一规则——血统按广度优先（自己在前，
/// 前身按 ID 排，防环，最多 256 张），第一张对这个键有生效记录的前身的值。只在 [card] 自己那时没有记录时调用。
fn card_inherited_at(conn: &Connection, profile: &str, card: &str, key: &str, target: &Cut) -> Result<Option<Value>, String> {
    let mut seen: Vec<String> = vec![card.to_owned()];
    let mut queue: std::collections::VecDeque<String> = std::collections::VecDeque::from([card.to_owned()]);
    let mut visited = 0usize;
    while let Some(id) = queue.pop_front() {
        if visited >= 256 {
            break;
        }
        visited += 1;
        if id != card {
            if let Some(v) = value_at(conn, profile, EntKind::Card, &id, key, Some(target))? {
                return Ok(Some(v));
            }
        }
        let mut keys: Vec<String> = super::semantics::ops_of(conn, profile, "card", &id)?
            .into_iter()
            .filter_map(|(_, w)| w.starts_with(HISTORY_FROM).then_some(w))
            .collect();
        keys.sort();
        keys.dedup();
        let mut preds: Vec<String> = Vec::new();
        for k in keys {
            if value_at(conn, profile, EntKind::Card, &id, &k, Some(target))? == Some(Value::Bool(true)) {
                preds.push(k[HISTORY_FROM.len()..].to_owned());
            }
        }
        preds.sort_by(|a, b| crate::ordering::cmp_utf16(a, b));
        for p in preds {
            if !seen.contains(&p) {
                seen.push(p.clone());
                queue.push_back(p);
            }
        }
    }
    Ok(None)
}

/// 某寄存器在 [target]（None = 现在）时的生效值；那时没有任何生效记录 = None（与「记录了 null」区分，见 [restored_value]）。
///
/// 现在的值直接读投影（`srs_field_edits` 就是读路径看到的寄存器）。那一刻的值把截面里的写入按落库规则重新落一遍、取胜者；
/// 每条写入的落库行优先取投影里那一行（按 [edit_row] 的 ID 规则查 `srs_field_edits`，就是落库时它算出的那一行），已被
/// 支配删掉的才现算——[edit_row] 对本机写入要求旧记录因果闭包，某台设备只覆盖了另一台迁移操作的一部分时要逐条扫那台
/// 设备的迁移操作（用户库实测一条 1.7 秒），不能每个寄存器都重算一遍。
fn value_at(conn: &Connection, profile: &str, kind: EntKind, entity: &str, key: &str, target: Option<&Cut>) -> Result<Option<Value>, String> {
    let Some(target) = target else {
        let rows: Vec<String> = conn
            .prepare_cached(
                "SELECT json FROM srs_field_edits WHERE profile_uid = srs_id(?1) AND entity_kind = ?2 AND entity_id = srs_id(?3) AND field_key = ?4",
            )
            .map_err(sql)?
            .query_map(params![profile, kind.wire(), entity, key], |r| r.get(0))
            .map_err(sql)?
            .collect::<Result<_, _>>()
            .map_err(sql)?;
        if rows.is_empty() {
            return Ok(None);
        }
        let items: Vec<crate::registers::StoredEdit<'_>> = rows.iter().map(|r| (r.as_str(), None, None)).collect();
        return crate::registers::register_value(&items, key).map(Some);
    };
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
        if !target.contains(&id) {
            continue;
        }
        let Some(op) = load_op(conn, profile, &id)? else { continue };
        let Ok(Body::Edit(e)) = op.body() else { continue };
        // 落库行的 ID 与 [edit_row] 同一规则（旧记录用旧写入者 / 旧 seq，本机写入用设备 / seq）。
        let eid = match &e.legacy {
            Some(l) => crate::registers::edit_id(&l.writer, l.seq),
            None => crate::registers::edit_id(&op.id.device.text(), op.id.seq as i64),
        };
        let projected: Option<String> = conn
            .prepare_cached("SELECT json FROM srs_field_edits WHERE id = srs_id(?1)")
            .map_err(sql)?
            .query_row([&eid], |r| r.get(0))
            .optional()
            .map_err(sql)?;
        match projected {
            Some(json) => rows.push(json),
            None => rows.push(canonical(&edit_row(conn, profile, &op, &e)?.1)),
        }
    }
    let items: Vec<crate::registers::StoredEdit<'_>> = rows.iter().map(|r| (r.as_str(), None, None)).collect();
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
    if live.is_empty() {
        return Ok(None);
    }
    let live_rows: Vec<crate::registers::StoredEdit<'_>> = live.iter().map(|&i| (rows[i].as_str(), None, None)).collect();
    crate::registers::register_value(&live_rows, key).map(Some)
}

/// 某笔记在 [target] 时的标签（OR-Set 按那时已有的添加 / 观察删除重算）。
fn tags_at(conn: &Connection, profile: &str, note: &str, target: &Cut) -> Result<Vec<String>, String> {
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
            let target = target_cut(c, profile, to)?;
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
                let target = target_cut(c, profile, to)?;
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

#[cfg(test)]
#[path = "tests_timeline.rs"]
mod tests;
