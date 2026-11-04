//! 存量重复流收敛（BUG-4005）。
//!
//! 同一份旧协议数据曾被两台设备各自包成了操作（v2 迁移那时还没有「已有操作就只补标记」的判断）：两条流里有几十万条
//! 内容相同的日志 / 身份记录 / 旧修改记录，各设备都存两份、新设备首次同步也要拉两份，修改记录在投影里并存两行。
//!
//! **作者**（持副本的设备 = 两份里设备 ID 较大的那台）逐条核对自己的旧操作与 ID 较小的设备里的同一事实，发
//! [Body::Dedup]（「我的 seq s 是 (d, t) 的副本」），然后把自己的这些操作换成副本骨架（op.rs `Op::duplicate`）、同名
//! 重写已经传过的段（`sync2_rewrites.restamp = 2`，归档位置不重写：transport.rs `sync2_outbox`）。
//!
//! 核对（[verify]）：
//! - 身份记录、日志（带旧 HLC）：载荷逐字节相同。不带旧 HLC 的日志投影行含作者的 HLC，不算副本。
//! - 旧修改记录：除旧写入者以外全同（种类、实体、字段键、值、旧 seq、服务器时刻、旧 HLC 的时刻部分），旧上下文把
//!   本机写入者改名成对方写入者后与对方的相同、本机上下文里本来没有对方写入者，HLC 的写入者部分同样对得上改名。
//!   写入者相同的就是逐字节相同的那种。
//! - 改了名的那些还要过寄存器检查（[step_check]）：同一寄存器（种类, 实体, 字段键）里有这个写入者的、没配上对的
//!   旧修改记录（宿主库实测：合并时 ID 重映射过的 5712 条，内容不同）就整寄存器不收——副本行的上下文按本机写入者
//!   覆盖了它，原件按对方写入者，删掉副本行会让它重新冒出来。
//!
//! **读者**（含作者自己）应用 [apply]：副本对应的修改记录行（行 ID 与原件不同时）删掉、`sync2_edit_ops` 指向原件或
//! 删掉；副本在删除扣留索引（`sync2_ent_ops`）里的行删掉、受影响的实体重判扣留；`sync2_log_meta` 指向原件；本地载荷
//! 换成副本骨架。收到副本骨架的新设备（[super::project_body] 的 `Body::Duplicate`）只记旧戳进闭包，不投影、不进索引——
//! 与老设备应用 [Body::Dedup] 之后的状态相同：投影 = 去掉副本之后的那批操作的投影（副本与原件支配同一批行，见上面的
//! 寄存器检查），扣留只看原件，旧修改记录闭包（`sync2_legacy`）照旧含副本的旧戳。
//!
//! 作业按阶段分批推进（每次调用一个事务，被杀后从游标续做）：
//! [PHASE_INDEX] 给 ID 较小的设备的候选操作建内容键 → [PHASE_MATCH] 本机候选逐条找原件并核对 → [PHASE_CHECK] 寄存器
//! 检查 → [PHASE_EMIT] 按 [op::DEDUP_MAX_PAIRS] 一条发 → 收尾排一次文件整理（store/compact.rs，打开时做）。

use std::collections::BTreeSet;

use rusqlite::{params, Connection, OptionalExtension};
use serde_json::{json, Value};

use crate::sync2::codec::Writer;
use crate::sync2::dvv::Dvv;
use crate::sync2::id::Id;
use crate::sync2::op::{self, Body, EditBody, EntKind, LegacyStamp, Op};
use crate::sync2::vv::OpId;

use super::{edit_row_id, load_op, semantics, snapshots, sql, Touched};

pub(crate) const PHASE_INDEX: i64 = 0;
pub(crate) const PHASE_MATCH: i64 = 1;
pub(crate) const PHASE_CHECK: i64 = 2;
pub(crate) const PHASE_EMIT: i64 = 3;

/// 一次调用最多处理多少条操作（建键 / 核对 / 检查各自计）。
pub(crate) const STEP_OPS: usize = 20_000;

/// 排一次作业（已有的不动）。v24 升级给每个已启用 v2 的 profile 排一次；之后收到「本机已有的日志又来了一份、
/// 而本机那份是本机自己的操作」也排（[super::project_log]）。
pub(crate) fn enqueue(c: &Connection, profile: &str) -> Result<(), String> {
    c.prepare_cached("INSERT OR IGNORE INTO sync2_dedup (profile_uid, phase, cur_dev, cur_seq) VALUES (srs_id(?1), 0, x'', 0)")
        .map_err(sql)?
        .execute([profile])
        .map_err(sql)?;
    Ok(())
}

/// 内容键：同一事实在两条流里得到同一个键（[verify] 再逐条核对）。不是候选的返回 None。
fn content_key(kind: u16, payload: &[u8]) -> Option<[u8; 16]> {
    let mut w = Writer::new();
    match Body::decode(kind, payload).ok()? {
        Body::Entity { .. } => {
            w.u8(1);
            w.bytes(payload);
        }
        Body::Log(l) if l.legacy_hlc.is_some() => {
            w.u8(3);
            w.bytes(payload);
        }
        Body::Edit(EditBody { kind, entity, key, value, machine, ts, legacy: Some(l) }) => {
            if super::is_synthetic_writer(&l.writer) {
                return None;
            }
            w.u8(2);
            w.u8(kind as u8);
            entity.write(&mut w);
            w.str(&key);
            w.str(&value);
            w.u8(u8::from(machine) | (ts << 1));
            w.iv(l.seq);
            w.opt_iv(l.server_time);
            w.str(hlc_split(&l.hlc).0);
        }
        _ => return None,
    }
    let h = blake3::hash(&w.into_vec());
    Some(h.as_bytes()[..16].try_into().expect("16"))
}

/// 旧 HLC 文本 `物理:计数:写入者` → (`物理:计数`, 写入者)。
fn hlc_split(h: &str) -> (&str, &str) {
    h.rsplit_once(':').unwrap_or((h, ""))
}

/// 旧上下文（去掉合成写入者，与投影行同一口径：mod.rs `strip_synthetic_ctx`）。
fn legacy_ctx(l: &LegacyStamp) -> Dvv {
    let mut d = Dvv::parse(&l.ctx_json);
    d.drop_writers(crate::registers::SYNTHETIC_WRITER_PREFIX);
    d
}

/// 核对本机操作 [mine] 是不是 [twin] 的副本。是 → `Some(改了名的本机写入者)`（逐字节相同的为 `Some(None)`）。
pub(crate) fn verify(mine: &Op, twin: &Op) -> Option<Option<String>> {
    if mine.kind != twin.kind || mine.purged || twin.purged {
        return None;
    }
    if mine.kind != op::KIND_EDIT {
        return (mine.payload == twin.payload && content_key(mine.kind, &mine.payload).is_some()).then_some(None);
    }
    let (Ok(Body::Edit(a)), Ok(Body::Edit(b))) = (mine.body(), twin.body()) else { return None };
    let (Some(la), Some(lb)) = (&a.legacy, &b.legacy) else { return None };
    if (a.kind, &a.entity, &a.key, &a.value, a.machine, a.ts) != (b.kind, &b.entity, &b.key, &b.value, b.machine, b.ts)
        || la.seq != lb.seq
        || la.server_time != lb.server_time
        || super::is_synthetic_writer(&la.writer)
        || super::is_synthetic_writer(&lb.writer)
    {
        return None;
    }
    let ((pa, wa), (pb, wb)) = (hlc_split(&la.hlc), hlc_split(&lb.hlc));
    if pa != pb {
        return None;
    }
    let (ca, cb) = (legacy_ctx(la), legacy_ctx(lb));
    if la.writer == lb.writer {
        return (ca == cb && wa == wb).then_some(None);
    }
    if ca.vv.contains_key(&lb.writer) || ca.cloud.contains_key(&lb.writer) {
        return None;
    }
    let mut renamed = ca;
    if let Some(n) = renamed.vv.remove(&la.writer) {
        renamed.vv.insert(lb.writer.clone(), n);
    }
    if let Some(s) = renamed.cloud.remove(&la.writer) {
        renamed.cloud.insert(lb.writer.clone(), s);
    }
    let hlc_ok = wa == wb || (wa == la.writer && wb == lb.writer);
    (renamed == cb && hlc_ok).then(|| Some(la.writer.clone()))
}

/// 修改记录所在的寄存器（种类, 实体, 字段键）的键。
fn register_key(e: &EditBody) -> Vec<u8> {
    let mut w = Writer::new();
    w.u8(e.kind as u8);
    e.entity.write(&mut w);
    w.str(&e.key);
    blake3::hash(&w.into_vec()).as_bytes()[..16].to_vec()
}

/// 一条操作的旧修改记录戳（原文或副本骨架都认）。
fn legacy_of(o: &Op) -> Option<LegacyStamp> {
    match o.body().ok()? {
        Body::Edit(e) => e.legacy,
        Body::Duplicate { legacy, .. } => legacy,
        _ => None,
    }
}

/// 应用一条 [Body::Dedup]（作者 [author] 的 [pairs]）。读者与作者同一个函数；已应用过的（本地已是骨架）跳过，可重放。
pub(crate) fn apply(c: &Connection, profile: &str, author: &Id, own: &Id, pairs: &[(u64, OpId)], now: i64, t: &mut Touched) -> Result<(), String> {
    for (seq, twin) in pairs {
        let id = OpId { device: *author, seq: *seq };
        let Some(o) = load_op(c, profile, &id)? else { continue };
        if o.purged {
            continue;
        }
        let mut touched: Vec<(&'static str, String)> = Vec::new();
        match o.body().map_err(|e| e.to_string())? {
            Body::Edit(e) => {
                let ent = e.entity.text();
                touched.push((e.kind.wire(), ent.clone()));
                if e.kind == EntKind::Card && e.key == "deck" {
                    if let Ok(Value::String(d)) = serde_json::from_str::<Value>(&e.value) {
                        touched.push(("deck", d));
                    }
                }
                let eid = edit_row_id(&o, &e);
                let twin_eid = load_op(c, profile, twin)?.and_then(|x| legacy_of(&x)).map(|l| crate::registers::edit_id(&l.writer, l.seq));
                if twin_eid.as_deref() == Some(eid.as_str()) {
                    // 逐字节相同：行是同一行，只把行 → 操作的映射交给原件。
                    c.prepare_cached("UPDATE sync2_edit_ops SET device = ?3, seq = ?4 WHERE edit_id = srs_id(?1) AND device = ?2 AND seq = ?5")
                        .map_err(sql)?
                        .execute(params![eid, author.0.to_vec(), twin.device.0.to_vec(), twin.seq as i64, *seq as i64])
                        .map_err(sql)?;
                } else {
                    // 改了名的副本：它自己那一行（并存的第二行）删掉。原件那一行由原件落（已落或之后落）。
                    if c.prepare_cached("DELETE FROM srs_field_edits WHERE id = srs_id(?1)").map_err(sql)?.execute([&eid]).map_err(sql)? > 0 {
                        t.dominated.push(eid.clone());
                        t.marks.edit(e.kind, &ent, &e.key);
                    }
                    c.prepare_cached("DELETE FROM sync2_edit_ops WHERE edit_id = srs_id(?1) AND device = ?2 AND seq = ?3")
                        .map_err(sql)?
                        .execute(params![eid, author.0.to_vec(), *seq as i64])
                        .map_err(sql)?;
                }
            }
            Body::Log(l) => {
                touched.push(("card", l.card.text()));
                if let Some(n) = &l.note {
                    touched.push(("note", n.text()));
                }
                c.prepare_cached("UPDATE sync2_log_meta SET device = ?3, seq = ?4 WHERE log_id = srs_id(?1) AND device = ?2 AND seq = ?5")
                    .map_err(sql)?
                    .execute(params![l.id.text(), author.0.to_vec(), twin.device.0.to_vec(), twin.seq as i64, *seq as i64])
                    .map_err(sql)?;
            }
            _ => {}
        }
        for (kind, ent) in &touched {
            c.prepare_cached("DELETE FROM sync2_ent_ops WHERE profile_uid = srs_id(?1) AND kind = ?2 AND entity = srs_id(?3) AND device = ?4 AND seq = ?5")
                .map_err(sql)?
                .execute(params![profile, kind, ent, author.0.to_vec(), *seq as i64])
                .map_err(sql)?;
        }
        let dup = o.duplicate(*twin).map_err(|e| e.to_string())?;
        c.prepare_cached("UPDATE sync2_ops SET payload = ?4, purged = 1, sc = NULL, sc_at = NULL, pz = 0 WHERE profile_uid = srs_id(?1) AND device = ?2 AND seq = ?3")
            .map_err(sql)?
            .execute(params![profile, author.0.to_vec(), *seq as i64, &dup.payload[..]])
            .map_err(sql)?;
        if author == own {
            // 同名改写（`restamp = 2` = 副本收敛）：已经传过的段按同一切法重传；归档位置不重写（transport.rs `sync2_outbox`）。
            c.prepare_cached(
                "INSERT OR IGNORE INTO sync2_rewrites (profile_uid, location, first, restamp) \
                 SELECT l.profile_uid, l.location, s.first, 2 FROM sync2_locations l \
                 JOIN sync2_segments s ON s.profile_uid = l.profile_uid AND s.device = ?2 AND s.first <= ?3 AND s.last >= ?3 \
                 WHERE l.profile_uid = srs_id(?1)",
            )
            .map_err(sql)?
            .execute(params![profile, author.0.to_vec(), *seq as i64])
            .map_err(sql)?;
        }
        for (kind, ent) in &touched {
            semantics::evaluate_holds(c, profile, kind, ent, now, t)?;
        }
    }
    Ok(())
}

/// 作业状态：(阶段, 游标设备, 游标 seq)。
fn job(c: &Connection, profile: &str) -> Result<Option<(i64, Vec<u8>, i64)>, String> {
    c.prepare_cached("SELECT phase, cur_dev, cur_seq FROM sync2_dedup WHERE profile_uid = srs_id(?1)")
        .map_err(sql)?
        .query_row([profile], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
        .optional()
        .map_err(sql)
}

fn set_job(c: &Connection, profile: &str, phase: i64, dev: &[u8], seq: i64) -> Result<(), String> {
    c.prepare_cached("UPDATE sync2_dedup SET phase = ?2, cur_dev = ?3, cur_seq = ?4 WHERE profile_uid = srs_id(?1)")
        .map_err(sql)?
        .execute(params![profile, phase, dev, seq])
        .map_err(sql)?;
    Ok(())
}

type Row = (Vec<u8>, i64, u16, Vec<u8>);

/// 从 (dev, seq) 之后按 (设备, seq) 读一批候选种类的操作原文。[filter] 是附加的 SQL 条件。
fn scan(c: &Connection, profile: &str, filter: &str, dev: &[u8], seq: i64, kinds: &str, me: &Id) -> Result<Vec<Row>, String> {
    let q = format!(
        "SELECT device, seq, kind, payload, sc, sc_at, pz FROM sync2_ops WHERE profile_uid = srs_id(?1) AND kind IN ({kinds}) AND purged = 0 \
         AND {filter} AND (device, seq) > (?2, ?3) ORDER BY device, seq LIMIT ?5"
    );
    let raw: Vec<(Vec<u8>, i64, i64, Vec<u8>, Option<String>, Option<i64>, i64)> = c
        .prepare_cached(&q)
        .map_err(sql)?
        .query_map(params![profile, dev, seq, me.0.to_vec(), STEP_OPS as i64], |r| {
            Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?, r.get(5)?, r.get(6)?))
        })
        .map_err(sql)?
        .collect::<Result<_, _>>()
        .map_err(sql)?;
    let mut out = Vec::with_capacity(raw.len());
    for (d, s, k, p, sc, at, pz) in raw {
        out.push((d, s, k as u16, snapshots::unpack_payload(c, p, sc, at, pz)?));
    }
    Ok(out)
}

const CANDIDATE_KINDS: &str = "1, 2, 3";

/// 建键：ID 比本机小的设备的候选操作，按 (设备, seq) 升序，同键取第一条（= 设备最小、seq 最小的那份）。
fn step_index(c: &Connection, profile: &str, me: &Id, dev: &[u8], seq: i64) -> Result<(), String> {
    let rows = scan(c, profile, "device < ?4", dev, seq, CANDIDATE_KINDS, me)?;
    for (d, s, k, p) in &rows {
        let Some(h) = content_key(*k, p) else { continue };
        c.prepare_cached("INSERT OR IGNORE INTO sync2_dedup_keys (profile_uid, h, device, seq) VALUES (srs_id(?1), ?2, ?3, ?4)")
            .map_err(sql)?
            .execute(params![profile, &h[..], d, s])
            .map_err(sql)?;
    }
    match rows.last() {
        Some((d, s, _, _)) if rows.len() == STEP_OPS => set_job(c, profile, PHASE_INDEX, d, *s),
        _ => set_job(c, profile, PHASE_MATCH, &[], 0),
    }
}

/// 核对：本机的候选操作逐条找原件。
fn step_match(c: &Connection, profile: &str, me: &Id, dev: &[u8], seq: i64) -> Result<(), String> {
    let rows = scan(c, profile, "device = ?4", dev, seq, CANDIDATE_KINDS, me)?;
    for (_, s, k, p) in &rows {
        let Some(h) = content_key(*k, p) else { continue };
        let found: Option<(Vec<u8>, i64)> = c
            .prepare_cached("SELECT device, seq FROM sync2_dedup_keys WHERE profile_uid = srs_id(?1) AND h = ?2")
            .map_err(sql)?
            .query_row(params![profile, &h[..]], |r| Ok((r.get(0)?, r.get(1)?)))
            .optional()
            .map_err(sql)?;
        let Some((td, ts)) = found else { continue };
        let twin_id = OpId { device: Id(td.as_slice().try_into().map_err(|_| "bad device")?), seq: ts as u64 };
        let (Some(mine), Some(twin)) = (load_op(c, profile, &OpId { device: *me, seq: *s as u64 })?, load_op(c, profile, &twin_id)?) else { continue };
        let Some(renamed) = verify(&mine, &twin) else { continue };
        let reg = match (&renamed, mine.body()) {
            (Some(_), Ok(Body::Edit(e))) => Some(register_key(&e)),
            _ => None,
        };
        c.prepare_cached("INSERT OR REPLACE INTO sync2_dedup_pairs (profile_uid, seq, device, tseq, writer, reg) VALUES (srs_id(?1), ?2, ?3, ?4, ?5, ?6)")
            .map_err(sql)?
            .execute(params![profile, s, td, ts, renamed, reg])
            .map_err(sql)?;
    }
    match rows.last() {
        Some((d, s, _, _)) if rows.len() == STEP_OPS => set_job(c, profile, PHASE_MATCH, d, *s),
        _ => set_job(c, profile, PHASE_CHECK, &[], 0),
    }
}

/// 寄存器检查：改了名的写入者在同一寄存器里还有没配上对的旧修改记录（任一设备），这个寄存器的配对全不收。
fn step_check(c: &Connection, profile: &str, me: &Id, dev: &[u8], seq: i64) -> Result<(), String> {
    let writers: BTreeSet<String> = c
        .prepare_cached("SELECT DISTINCT writer FROM sync2_dedup_pairs WHERE profile_uid = srs_id(?1) AND writer IS NOT NULL")
        .map_err(sql)?
        .query_map([profile], |r| r.get(0))
        .map_err(sql)?
        .collect::<Result<_, _>>()
        .map_err(sql)?;
    let rows = if writers.is_empty() { Vec::new() } else { scan(c, profile, "?4 = ?4", dev, seq, "2", me)? };
    for (d, s, k, p) in &rows {
        let Ok(Body::Edit(e)) = Body::decode(*k, p) else { continue };
        let Some(l) = &e.legacy else { continue };
        if !writers.contains(&l.writer) {
            continue;
        }
        if d.as_slice() == me.0 {
            let paired: bool = c
                .prepare_cached("SELECT 1 FROM sync2_dedup_pairs WHERE profile_uid = srs_id(?1) AND seq = ?2 AND writer IS NOT NULL")
                .map_err(sql)?
                .exists(params![profile, s])
                .map_err(sql)?;
            if paired {
                continue;
            }
        }
        c.prepare_cached("INSERT OR IGNORE INTO sync2_dedup_regs (profile_uid, reg) VALUES (srs_id(?1), ?2)")
            .map_err(sql)?
            .execute(params![profile, register_key(&e)])
            .map_err(sql)?;
    }
    match rows.last() {
        Some((d, s, _, _)) if rows.len() == STEP_OPS => set_job(c, profile, PHASE_CHECK, d, *s),
        _ => {
            c.prepare_cached(
                "DELETE FROM sync2_dedup_pairs WHERE profile_uid = srs_id(?1) AND reg IN (SELECT reg FROM sync2_dedup_regs WHERE profile_uid = srs_id(?1))",
            )
            .map_err(sql)?
            .execute([profile])
            .map_err(sql)?;
            set_job(c, profile, PHASE_EMIT, &[], 0)
        }
    }
}

/// 发一条 [Body::Dedup]（游标之后的下一批配对）。没有了 → 作业结束、清表、排一次文件整理。
fn step_emit(c: &Connection, profile: &str, seq: i64, now: i64, t: &mut Touched) -> Result<u64, String> {
    let pairs: Vec<(u64, OpId)> = c
        .prepare_cached("SELECT seq, device, tseq FROM sync2_dedup_pairs WHERE profile_uid = srs_id(?1) AND seq > ?2 ORDER BY seq LIMIT ?3")
        .map_err(sql)?
        .query_map(params![profile, seq, op::DEDUP_MAX_PAIRS as i64], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, Vec<u8>>(1)?, r.get::<_, i64>(2)?)))
        .map_err(sql)?
        .map(|x| {
            let (s, d, ts) = x.map_err(sql)?;
            Ok((s as u64, OpId { device: Id(d.as_slice().try_into().map_err(|_| "bad device".to_string())?), seq: ts as u64 }))
        })
        .collect::<Result<_, String>>()?;
    let Some(&(last, _)) = pairs.last() else {
        for table in ["sync2_dedup_keys", "sync2_dedup_pairs", "sync2_dedup_regs", "sync2_dedup"] {
            c.execute(&format!("DELETE FROM {table} WHERE profile_uid = srs_id(?1)"), [profile]).map_err(sql)?;
        }
        c.execute(
            "INSERT INTO srs_meta (key, value) VALUES (?1, 'dedup') ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            [crate::store::compact::PENDING],
        )
        .map_err(sql)?;
        return Ok(0);
    };
    let n = pairs.len() as u64;
    let mut local = super::Local::load(c, profile)?.ok_or("sync2 not initialised for this profile")?;
    let mut applied = super::applied_vv(c, profile)?;
    let o = super::append_local(c, &mut local, &mut applied, &Body::Dedup { pairs }, now)?;
    super::project(c, profile, &o, now, true, t)?;
    local.save(c)?;
    set_job(c, profile, PHASE_EMIT, &[], last as i64)?;
    Ok(n)
}

impl crate::store::SrsCore {
    /// 推进一步重复流收敛作业（一个事务）。返回 `{"done", "phase", "emitted", "marks", "replayed", "changed", "purged"}`；
    /// `done` = 没有作业（或刚做完）。本机还没完成 v2 迁移时不动（迁移完才知道哪些是本机的旧操作）。
    pub fn sync2_dedup(&self, profile: &str, now: i64) -> Result<Value, String> {
        let w = self.writer()?;
        super::in_savepoint(&w, |c| {
            let mut t = Touched::default();
            let Some((phase, dev, seq)) = job(c, profile)? else { return Ok(json!({"done": true})) };
            let Some(local) = super::Local::load(c, profile)? else { return Ok(json!({"done": true})) };
            if !local.migrated {
                return Ok(json!({"done": true, "phase": phase}));
            }
            let me = local.device;
            let mut emitted = 0;
            match phase {
                PHASE_INDEX => step_index(c, profile, &me, &dev, seq)?,
                PHASE_MATCH => step_match(c, profile, &me, &dev, seq)?,
                PHASE_CHECK => step_check(c, profile, &me, &dev, seq)?,
                _ => emitted = step_emit(c, profile, seq, now, &mut t)?,
            }
            let done = job(c, profile)?.is_none();
            let replayed = super::replay_touched(c, &t)?;
            Ok(json!({
                "done": done,
                "phase": phase,
                "emitted": emitted,
                "marks": t.marks.to_json(),
                "replayed": replayed,
                "changed": t.entities_changed.iter().map(|(k, e)| json!([k, e])).collect::<Vec<_>>(),
                "purged": t.purged.iter().map(|(k, e)| json!([k, e])).collect::<Vec<_>>(),
            }))
        })
    }
}
