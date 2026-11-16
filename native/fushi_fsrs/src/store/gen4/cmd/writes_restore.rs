//! 时间线恢复 `restore` 的新代实现（G7-3b；协议 3 `store/sync2/timeline.rs` `restore_on`，设计 §10.2「时间线恢复不变」）。
//!
//! 恢复到某个时刻 / 某个还原点 = 取那一刻的操作**截面**（[Cut]）→ 对此后改过的每个寄存器 / 标签集合 / 实体，算出那一刻
//! 的值与现值求差 → 先打一个还原点（`before restore to …`，恢复本身也能再恢复回去），再追加一批**补偿操作**（字段
//! 改回、复活被删的、删除之后新建的；可选：撤回此后的复习）。补偿操作经 [Session::land] → `Native::write` 落本机日志，
//! 照常同步，不覆盖任何设备。整条命令一个事务（[write]）：算与写在同一个事务里，补偿操作针对的就是写入时的状态。
//!
//! # 截面（与协议 3 `Cut` 同一个口径）
//!
//! - 还原点目标：还原点那条操作的依赖 + 它作者到它为止的前缀（按因果截，不按墙钟：打还原点与随后的批量删除常落在同一
//!   毫秒）。还原点不在本集合的日志里 = 报错 `checkpoint not found`。
//! - 时刻目标 `at`：每台设备墙钟 ≤ `at` 的操作（墙钟在设备内单调，取最大 seq 当前缀），再加上墙钟在后、但**自带的原始
//!   时刻** ≤ `at` 的：承袭修改的旧 HLC 物理时刻、日志的发生时刻 `at`（迁移 / 并入进来的旧内容墙钟是迁移那一刻，内容
//!   本身早就有了）。空洞（已清除操作的壳）没有时刻，不进前缀的计算；它的内容早已不在任何寄存器里，进不进截面不影响。
//!
//! 截面按操作主键判（`k` = 设备下标 + seq，`schema.rs` `opk`），派生索引（`reg_ix` / `tag_ix` / `ent_ix` / `log_ix`）
//! 上的每一行直接按主键问，不回读操作。
//!
//! # 按别名类（D24、§5.2）
//!
//! 协议 3 按原值实体算；新代的读侧按别名类读（`class.rs`），写入按规范 ID（[Session::land] 归一）。所以这里也按类：
//! 「此后碰过的」按 (种类, 规范实体, 规范键) 成组；「那一刻的值」= 类内全部成员在截面里的写入按类重判
//! （[Index::class_value_in]，与读侧同一份判定），现值 = [Index::class_value]；标签同理（[Index::class_tags_in] /
//! [Index::class_tags]）；「之后才建的」要类里每个成员都是之后才建的。没有别名的集合里类就是实体本身，与协议 3 逐条
//! 相同（对拍测试 `restore_matches_protocol_3_*`）。
//!
//! # 补偿规则（逐条照协议 3 `plan`）
//!
//! - 之后才建的笔记 / 牌组 / 笔记类型（身份记录与内容都在截面之外，且不是内置的）：写 `deleted = now`。它此后的别的
//!   改动不再单独还原。
//! - 此后碰过的寄存器：那一刻的值与现值不同（[registers::same_value]）就写回那一刻的值。那一刻没有任何生效写入时写
//!   null；卡片的 `deck` / `suspended` / … 例外：写回那一刻从血统（`historyFrom`）继承到的值（自己记一条 null 会挡住
//!   继承），血统里也没有才写 null。
//! - 此后碰过的标签集合：那一刻有、现在没有的加回，现在有、那一刻没有的删掉（`TagAdd` / `TagRemove`）。
//! - `retract: true`：此后的作答（`kind = review` 且有评分的日志）各追加一条撤销日志（`undo`，`revokes` 指向它），按
//!   (日志 ID, 卡, 笔记) 排序；日志 ID 由 `Id::new_v7(now)` 生成（同协议 3）。
//!
//! 回包：[write] 的统一项（`changed` / `edits` / `replayed` / `nextSeq` / `settled` …）。协议 3 回的是 `append_on` 的
//! 投影变化，新代对应物就是统一项。

use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};

use rusqlite::params;
use rusqlite::types::ValueRef;
use serde_json::{Value, json};

use super::super::derive::{Index, Ref, body_of};
use super::super::schema::{k_dev, k_seq, sql};
use super::super::truth::Truth;
use super::writes::{Session, fail_after, key_of, now_of, write};
use crate::gen4::name::read_edit_key;
use crate::gen4::op::Body4;
use crate::registers;
use crate::store::sync2::canonical;
use crate::sync2::codec::Reader;
use crate::sync2::id::{Id, Key};
use crate::sync2::op::{Body, EditBody, EntKind, Intent, LogBody};
use crate::sync2::vv::OpId;

/// 恢复目标（协议 3 `RestoreTarget`）。
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Target {
    /// 一个时刻（毫秒）。
    At(i64),
    /// 一个还原点（打还原点那条操作的操作号）。
    Checkpoint(OpId),
}

impl Target {
    /// 请求里的目标（协议 3 `store/ffi.rs` `restore_target` 同一组键）：`checkpoint: {device, seq}` 优先，否则 `at`。
    pub fn of(req: &Value) -> Result<Target, String> {
        Ok(match req.get("checkpoint") {
            Some(cp) if cp.is_object() => Target::Checkpoint(OpId {
                device: Id::parse(cp["device"].as_str().ok_or("checkpoint.device")?)
                    .ok_or("bad checkpoint device")?,
                seq: cp["seq"].as_u64().ok_or("checkpoint.seq")?,
            }),
            _ => Target::At(
                req.get("at")
                    .and_then(Value::as_i64)
                    .ok_or("restore: missing at")?,
            ),
        })
    }

    /// 打在恢复之前的那个还原点的名字（协议 3 同文）。
    fn label(&self) -> String {
        match self {
            Target::At(t) => format!("before restore to {t}"),
            Target::Checkpoint(id) => format!("before restore to {}:{}", id.device.text(), id.seq),
        }
    }
}

/// 恢复目标在日志上的截面（模块文件头「截面」）：按操作主键判。
#[derive(Debug, Default)]
pub(super) struct Cut {
    /// 设备下标 → 截面里它的前缀（seq ≤ 这个的都在）。
    upto: HashMap<i64, u64>,
    /// 墙钟在后、原始时刻在前（含）的操作主键。
    stamped_before: HashSet<i64>,
}

impl Cut {
    pub(super) fn contains(&self, k: i64) -> bool {
        self.upto.get(&k_dev(k)).is_some_and(|&s| k_seq(k) <= s) || self.stamped_before.contains(&k)
    }

    /// [target] 的截面。
    pub(super) fn of(t: &Truth<'_>, col: i64, target: &Target) -> Result<Cut, String> {
        let devs = t.devices(col)?;
        match target {
            Target::Checkpoint(id) => {
                let k = t
                    .key_of(col, id)?
                    .filter(|_| {
                        t.entry(col, id)
                            .ok()
                            .flatten()
                            .is_some_and(|e| e.is_whole())
                    })
                    .ok_or("checkpoint not found")?;
                let head = t.head_by_key(k)?.ok_or("checkpoint not found")?;
                let mut cut = Cut::default();
                for d in &devs {
                    let mut s = head.deps.get(&d.id);
                    if d.id == id.device {
                        s = s.max(id.seq);
                    }
                    if s > 0 {
                        cut.upto.insert(d.dev, s);
                    }
                }
                Ok(cut)
            }
            Target::At(at) => Cut::at(t, &devs, *at),
        }
    }

    /// 时刻截面：墙钟前缀 + 墙钟在后、原始时刻 ≤ [at] 的修改 / 日志。每台设备的操作表与副本记录表各顺序扫一遍，只有
    /// 墙钟在后的修改 / 日志才解开载荷。
    fn at(t: &Truth<'_>, devs: &[super::super::truth::DevInfo], at: i64) -> Result<Cut, String> {
        let conn = t.conn();
        let mut cut = Cut::default();
        for d in devs {
            let (lo, hi) = super::super::schema::k_range(d.dev);
            let mut upto = 0u64;
            let mut later: Vec<i64> = Vec::new();
            {
                let mut stmt = conn
                    .prepare_cached("SELECT k, wall, kind FROM ops WHERE k BETWEEN ?1 AND ?2")
                    .map_err(sql)?;
                let rows = stmt
                    .query_map(params![lo, hi], |r| {
                        Ok((
                            r.get::<_, i64>(0)?,
                            r.get::<_, i64>(1)?,
                            r.get::<_, i64>(2)?,
                        ))
                    })
                    .map_err(sql)?;
                for row in rows {
                    let (k, wall, kind) = row.map_err(sql)?;
                    if wall <= at {
                        upto = upto.max(k_seq(k));
                    } else if kind == i64::from(crate::gen4::op::KIND_EDIT)
                        || kind == i64::from(crate::gen4::op::KIND_LOG)
                    {
                        later.push(k);
                    }
                }
            }
            {
                let mut stmt = conn
                    .prepare_cached(
                        "SELECT k FROM op_alias WHERE k BETWEEN ?1 AND ?2 AND wall <= ?3",
                    )
                    .map_err(sql)?;
                let rows = stmt
                    .query_map(params![lo, hi, at], |r| r.get::<_, i64>(0))
                    .map_err(sql)?;
                for row in rows {
                    upto = upto.max(k_seq(row.map_err(sql)?));
                }
            }
            if upto > 0 {
                cut.upto.insert(d.dev, upto);
            }
            for k in later {
                if k_seq(k) <= upto {
                    continue;
                }
                let Some(e) = t.entry_by_key(k)? else {
                    continue;
                };
                let original = match body_of(&e) {
                    Some(Body4::Edit(ed)) => ed.stamp.as_ref().and_then(|s| {
                        crate::history::parse_hlc(&s.hlc.text())
                            .ok()
                            .map(|(p, _, _)| p)
                    }),
                    Some(Body4::Log(l)) => Some(l.at),
                    _ => None,
                };
                if original.is_some_and(|o| o <= at) {
                    cut.stamped_before.insert(k);
                }
            }
        }
        Ok(cut)
    }
}

/// 补偿操作与计数（协议 3 `Plan`）。
#[derive(Debug, Default)]
pub(super) struct Plan {
    pub(super) bodies: Vec<Body>,
    pub(super) fields: usize,
    pub(super) revived: usize,
    pub(super) removed: usize,
    pub(super) tags: usize,
    pub(super) reviews: usize,
}

/// 标签集合在「此后碰过的键」里的记号（协议 3 同名）。
const TAG_KEY: &str = "#tag";
const HISTORY_FROM: &str = "historyFrom/";
/// 「之后才建的」只看这几种（协议 3 同）。
const CREATED_KINDS: [EntKind; 3] = [EntKind::Note, EntKind::Deck, EntKind::NoteType];

fn ent_kind(k: i64) -> Result<EntKind, String> {
    EntKind::ALL
        .get(k as usize)
        .copied()
        .ok_or_else(|| format!("restore: bad entity kind {k}"))
}

fn key_text(b: &[u8]) -> Result<String, String> {
    read_edit_key(&mut Reader::new(b)).map_err(|e| format!("restore: bad register key: {e}"))
}

fn edit_body(kind: EntKind, entity: &Ref, key: &str, v: &Value) -> Body {
    Body::Edit(EditBody {
        kind,
        entity: key_of(entity),
        key: key.into(),
        value: canonical(v),
        machine: false,
        ts: 0,
        legacy: None,
    })
}

fn parsed(v: Option<String>) -> Value {
    v.and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or(Value::Null)
}

/// 求补偿操作（模块文件头「补偿规则」）。[ix] 已收尾。
pub(super) fn plan(
    ix: &mut Index<'_, '_>,
    cut: &Cut,
    retract_reviews: bool,
    now: i64,
) -> Result<Plan, String> {
    let col = ix.col;
    let conn = ix.t.conn();
    let mut p = Plan::default();
    // 此后碰过的 (种类, 规范实体) → 规范键（标签集合记成 [TAG_KEY]）。
    let mut touched: BTreeMap<(EntKind, Ref), BTreeSet<String>> = BTreeMap::new();
    {
        let mut stmt = conn
            .prepare_cached("SELECT ekind, ent, key, k FROM reg_ix WHERE col = ?1")
            .map_err(sql)?;
        let mut rows = stmt.query([col]).map_err(sql)?;
        while let Some(r) = rows.next().map_err(sql)? {
            let k: i64 = r.get(3).map_err(sql)?;
            if cut.contains(k) {
                continue;
            }
            let kind = ent_kind(r.get(0).map_err(sql)?)?;
            let ent: Ref = r.get(1).map_err(sql)?;
            let key = match r.get_ref(2).map_err(sql)? {
                ValueRef::Blob(b) => key_text(b)?,
                _ => return Err("restore: bad register key".to_owned()),
            };
            touched
                .entry((kind, ix.canonical(&ent)?))
                .or_default()
                .insert(ix.canonical_key(&key)?);
        }
    }
    {
        let mut stmt = conn
            .prepare_cached("SELECT note, k FROM tag_ix WHERE col = ?1")
            .map_err(sql)?;
        let rows: Vec<(Ref, i64)> = stmt
            .query_map([col], |r| Ok((r.get(0)?, r.get(1)?)))
            .map_err(sql)?
            .collect::<Result<_, _>>()
            .map_err(sql)?;
        for (note, k) in rows {
            if !cut.contains(k) {
                touched
                    .entry((EntKind::Note, ix.canonical(&note)?))
                    .or_default()
                    .insert(TAG_KEY.to_owned());
            }
        }
    }
    let created_after = created_after(ix, cut)?;
    for (kind, entity) in &created_after {
        p.bodies
            .push(edit_body(*kind, entity, "deleted", &json!(now)));
        p.removed += 1;
    }
    for ((kind, entity), keys) in &touched {
        if created_after.contains(&(*kind, entity.clone())) {
            continue;
        }
        for key in keys {
            if key == TAG_KEY {
                let then = ix.class_tags_in(entity, &|k| cut.contains(k))?;
                let cur = ix.class_tags(entity)?;
                for t in then.iter().filter(|x| !cur.contains(x)) {
                    p.bodies.push(Body::TagAdd {
                        note: key_of(entity),
                        tag: t.clone(),
                    });
                    p.tags += 1;
                }
                for t in cur.iter().filter(|x| !then.contains(x)) {
                    p.bodies.push(Body::TagRemove {
                        note: key_of(entity),
                        tag: t.clone(),
                    });
                    p.tags += 1;
                }
                continue;
            }
            let then = restored_value(ix, cut, *kind, entity, key)?;
            let cur = parsed(ix.class_value(*kind, entity, key)?);
            if registers::same_value(&then, &cur) {
                continue;
            }
            if key == "deleted" {
                if cur.is_i64() && then.is_null() {
                    p.revived += 1;
                } else if then.is_i64() {
                    p.removed += 1;
                }
            } else {
                p.fields += 1;
            }
            p.bodies.push(edit_body(*kind, entity, key, &then));
        }
    }
    if retract_reviews {
        retract(ix, cut, now, &mut p)?;
    }
    Ok(p)
}

/// 之后才建的笔记 / 牌组 / 笔记类型（规范 ID）：类里每个成员的身份记录都在截面之外、都不是内置的、都没有任何内容
/// （字段修改、标签操作）在截面里。内置实体（任一条身份载荷带非空的 `builtin`）由代码定义、一直在（协议 3 同，审查
/// PR #2775）。
fn created_after(ix: &mut Index<'_, '_>, cut: &Cut) -> Result<BTreeSet<(EntKind, Ref)>, String> {
    let col = ix.col;
    let conn = ix.t.conn();
    // 原值实体 → (种类, 那一刻已在)。
    let mut raw: BTreeMap<Ref, (EntKind, bool)> = BTreeMap::new();
    {
        let mut stmt = conn
            .prepare_cached("SELECT id, kind, k FROM ent_ix WHERE col = ?1")
            .map_err(sql)?;
        let rows: Vec<(Ref, i64, i64)> = stmt
            .query_map([col], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
            .map_err(sql)?
            .collect::<Result<_, _>>()
            .map_err(sql)?;
        for (id, kind, k) in rows {
            let kind = ent_kind(kind)?;
            if !CREATED_KINDS.contains(&kind) {
                continue;
            }
            // 已清除的身份记录（空洞）不算（协议 3 跳过 `purged` 的）。
            let Some(Body4::Entity { data, .. }) = ix.t.entry_by_key(k)?.and_then(|e| body_of(&e))
            else {
                continue;
            };
            let builtin = serde_json::from_str::<Value>(&data)
                .is_ok_and(|d| d.get("builtin").is_some_and(|b| !b.is_null()));
            let e = raw.entry(id).or_insert((kind, false));
            e.1 |= cut.contains(k) || builtin;
        }
    }
    let mut out = BTreeSet::new();
    let mut existed: BTreeSet<(EntKind, Ref)> = BTreeSet::new();
    let mut candidates: BTreeSet<(EntKind, Ref)> = BTreeSet::new();
    for (id, (kind, mut was)) in raw {
        if !was {
            was = has_content_in(ix, cut, kind, &id)?;
        }
        let canon = (kind, ix.canonical(&id)?);
        if was {
            existed.insert(canon);
        } else {
            candidates.insert(canon);
        }
    }
    for c in candidates {
        if !existed.contains(&c) {
            out.insert(c);
        }
    }
    Ok(out)
}

/// 原值实体在截面里有没有内容（字段修改、标签操作；不算日志 / 清除，协议 3 `has_content_in`）。
fn has_content_in(ix: &Index<'_, '_>, cut: &Cut, kind: EntKind, id: &Ref) -> Result<bool, String> {
    let conn = ix.t.conn();
    let ks: Vec<i64> = conn
        .prepare_cached("SELECT k FROM reg_ix WHERE col = ?1 AND ekind = ?2 AND ent = ?3")
        .map_err(sql)?
        .query_map(params![ix.col, kind as i64, id], |r| r.get(0))
        .map_err(sql)?
        .collect::<Result<_, _>>()
        .map_err(sql)?;
    if ks.into_iter().any(|k| cut.contains(k)) {
        return Ok(true);
    }
    if kind != EntKind::Note {
        return Ok(false);
    }
    let ks: Vec<i64> = conn
        .prepare_cached("SELECT k FROM tag_ix WHERE col = ?1 AND note = ?2")
        .map_err(sql)?
        .query_map(params![ix.col, id], |r| r.get(0))
        .map_err(sql)?
        .collect::<Result<_, _>>()
        .map_err(sql)?;
    Ok(ks.into_iter().any(|k| cut.contains(k)))
}

/// 恢复要写回的值：那一刻这个寄存器的生效值；那一刻没有生效写入时，卡片标志写回血统继承到的值，其余写 null（模块
/// 文件头、协议 3 `restored_value`）。
fn restored_value(
    ix: &mut Index<'_, '_>,
    cut: &Cut,
    kind: EntKind,
    entity: &Ref,
    key: &str,
) -> Result<Value, String> {
    if let Some(v) = ix.class_value_in(kind, entity, key, &|k| cut.contains(k))? {
        return Ok(parsed(Some(v)));
    }
    if kind == EntKind::Card && !key.starts_with(HISTORY_FROM) {
        if let Some(v) = card_inherited_at(ix, cut, entity, key)? {
            return Ok(v);
        }
    }
    Ok(Value::Null)
}

/// [card] 那一刻从血统继承到的 [key]（协议 3 `card_inherited_at`，与 `registers.rs` `cards_group` 同一规则）：血统按
/// 广度优先（自己在前，前身按 UTF-16 序，防环，最多 256 张），第一张那一刻对这个键有生效写入的前身的值。
fn card_inherited_at(
    ix: &mut Index<'_, '_>,
    cut: &Cut,
    card: &Ref,
    key: &str,
) -> Result<Option<Value>, String> {
    let mut seen: Vec<Ref> = vec![card.clone()];
    let mut queue: std::collections::VecDeque<Ref> =
        std::collections::VecDeque::from([card.clone()]);
    let mut visited = 0usize;
    while let Some(id) = queue.pop_front() {
        if visited >= 256 {
            break;
        }
        visited += 1;
        if id != *card {
            if let Some(v) = ix.class_value_in(EntKind::Card, &id, key, &|k| cut.contains(k))? {
                return Ok(Some(parsed(Some(v))));
            }
        }
        let mut preds: Vec<String> = Vec::new();
        for k in class_keys(ix, EntKind::Card, &id)? {
            let Some(p) = k.strip_prefix(HISTORY_FROM) else {
                continue;
            };
            let v = ix.class_value_in(EntKind::Card, &id, &k, &|x| cut.contains(x))?;
            if parsed(v) == Value::Bool(true) {
                preds.push(p.to_owned());
            }
        }
        preds.sort_by(|a, b| crate::ordering::cmp_utf16(a, b));
        for p in preds {
            let r = ix.canonical(&Ref::of(&Key::of(&p)))?;
            if !seen.contains(&r) {
                seen.push(r.clone());
                queue.push_back(r);
            }
        }
    }
    Ok(None)
}

/// 一个别名类全部寄存器的规范键。
fn class_keys(ix: &Index<'_, '_>, kind: EntKind, canon: &Ref) -> Result<BTreeSet<String>, String> {
    let mut out = BTreeSet::new();
    for m in ix.members(canon)? {
        let keys: Vec<Vec<u8>> =
            ix.t.conn()
                .prepare_cached(
                    "SELECT DISTINCT key FROM reg_ix WHERE col = ?1 AND ekind = ?2 AND ent = ?3",
                )
                .map_err(sql)?
                .query_map(params![ix.col, kind as i64, m], |r| r.get(0))
                .map_err(sql)?
                .collect::<Result<_, _>>()
                .map_err(sql)?;
        for b in keys {
            out.insert(ix.canonical_key(&key_text(&b)?)?);
        }
    }
    Ok(out)
}

/// 撤回此后的作答（协议 3 `plan` 的 `retract_reviews` 段）：截面之外、`kind = review` 且有评分的日志各一条撤销。
fn retract(ix: &mut Index<'_, '_>, cut: &Cut, now: i64, p: &mut Plan) -> Result<(), String> {
    let ks: Vec<i64> =
        ix.t.conn()
            .prepare_cached("SELECT k FROM log_ix WHERE col = ?1 AND win = 1")
            .map_err(sql)?
            .query_map([ix.col], |r| r.get(0))
            .map_err(sql)?
            .collect::<Result<_, _>>()
            .map_err(sql)?;
    let mut undo: Vec<(String, String, Option<Key>)> = Vec::new();
    for k in ks {
        if cut.contains(k) {
            continue;
        }
        let Some(Body4::Log(l)) = ix.t.entry_by_key(k)?.and_then(|e| body_of(&e)) else {
            continue;
        };
        if l.kind == "review" && l.rating.is_some() {
            undo.push((l.id.text(), l.card.text(), l.note.clone()));
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
    Ok(())
}

/// `restore`（时间线恢复，协议 3 `local_write_body` 的 `restore` 分支 / `timeline.rs` `restore_on`）。[req]：
/// `{"now", "at" | "checkpoint": {"device", "seq"}, "retract"?: bool}`。先打还原点，再落补偿操作，一个事务。
pub fn restore(t: &Truth<'_>, col: i64, req: &Value) -> Result<Value, String> {
    let now = now_of(req)?;
    let target = Target::of(req)?;
    let retract_reviews = req["retract"] == Value::Bool(true);
    write(t, col, |s: &mut Session<'_, '_>| {
        let bodies = {
            let ix = s.settled()?;
            let cut = Cut::of(ix.t, ix.col, &target)?;
            plan(ix, &cut, retract_reviews, now)?.bodies
        };
        s.land(
            Body::Checkpoint {
                name: target.label(),
                reason: "restore".into(),
            },
            now,
        )?;
        for b in bodies {
            s.land(b, now)?;
        }
        fail_after(req, "restore")?;
        Ok(json!({}))
    })
}

/// 预览恢复（协议 3 `sync2_plan_restore`）：会改回多少字段、复活 / 删除多少实体、改多少标签、撤回多少次复习。只读：
/// 在一个读快照里算，不落库。
pub fn plan_restore(t: &Truth<'_>, col: i64, req: &Value) -> Result<Value, String> {
    let now = now_of(req)?;
    let target = Target::of(req)?;
    let retract_reviews = req["retract"] == Value::Bool(true);
    super::snapshot(t, |t| {
        let mut ix = Index::new(t, col);
        let cut = Cut::of(t, col, &target)?;
        let p = plan(&mut ix, &cut, retract_reviews, now)?;
        Ok(json!({
            "fields": p.fields,
            "revived": p.revived,
            "removed": p.removed,
            "tags": p.tags,
            "reviews": p.reviews,
        }))
    })
}
