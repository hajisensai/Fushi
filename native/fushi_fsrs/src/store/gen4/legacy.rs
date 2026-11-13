//! 旧代读入器（设计 §3.1、§6.1）：从协议 3 的 srs.db **只读**地取出操作日志，逐条喂给转译 T（`crate::gen4::translate`）。
//!
//! - 已应用的操作（`sync2_ops`）经现有的 [load_op] 读：它把本机另存的配置快照拼回、把本地压缩解开，给出的载荷就是
//!   那台设备当初成链、签名的那份字节（设计 §3.1：T 的输入必须是这一份）。这里**逐条重算链**并与库里存的链值比，
//!   对不上就报错——「喂给 T 的是原字节」靠这一步在运行时保证，不靠相信库。
//! - 待投递的操作（`sync2_pending`：收到了、但因果上还投不了的别人的操作）同样读出来转译，并标成 [Placement::Pending]
//!   ——它们过界后仍然是待投递的（设计 §3.1 末）。它们的链值是收段时按段里声明的前一环算的，还没和本机的前缀核对过
//!   （协议 3 在投递时才核对）；所以待投递的槽可以与已应用的同号槽链指纹不同，那是分叉的一支，照常交出去。
//!   与已应用的同号、链值也相同的待投递行是残留（投递过了还没删），跳过。
//! - 只读：不建表、不写任何行。连接由调用方开，上面要注册过 `srs_id` / `srs_idt`（`store::ids::register`）。
//!
//! 开始之前先过 [preflight]：设计 §6.1 要求「旧事件 → 操作的迁移、去重作业、收段通道」都在旧代码上做完再换代。
//! 没做完的库里有一部分数据还不在操作日志里，读入器看不见它们——那是丢数据，必须在这里拦下。

use std::collections::BTreeMap;

use rusqlite::{Connection, OptionalExtension, params};

use crate::gen4::heritage::{HeritageSlot, SlotBody};
use crate::gen4::op::Body4;
use crate::gen4::translate::{RawReason, raw_reason, translate};
use crate::store::sync2::load_op;
use crate::sync2::codec::Reader;
use crate::sync2::id::Id;
use crate::sync2::op::{self as v3, Op};
use crate::sync2::segment::{CHAIN_ZERO, Chain, chain_next};
use crate::sync2::vv::OpId;

fn sql(e: rusqlite::Error) -> String {
    format!("legacy reader: {e}")
}

fn id_of(b: &[u8]) -> Result<Id, String> {
    b.try_into()
        .map(Id)
        .map_err(|_| "legacy reader: bad device id blob".to_owned())
}

fn chain_of(b: Vec<u8>) -> Result<Chain, String> {
    b.try_into()
        .map_err(|_| "legacy reader: bad chain blob".to_owned())
}

fn table_exists(conn: &Connection, name: &str) -> Result<bool, String> {
    conn.prepare_cached("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?1")
        .map_err(sql)?
        .exists([name])
        .map_err(sql)
}

/// 库里有协议 3 身份或操作的 profile（uid 文本，升序）。
pub fn profiles(conn: &Connection) -> Result<Vec<String>, String> {
    conn.prepare(
        "SELECT srs_idt(profile_uid) FROM sync2_self \
         UNION SELECT srs_idt(profile_uid) FROM sync2_ops \
         UNION SELECT srs_idt(profile_uid) FROM sync2_pending ORDER BY 1",
    )
    .map_err(sql)?
    .query_map([], |r| r.get::<_, String>(0))
    .map_err(sql)?
    .collect::<Result<_, _>>()
    .map_err(sql)
}

/// 换代前必须在旧代码上做完的事里，这个 profile 还没做完的（空 = 可以读）。每项是给人看的一句话。
///
/// 没启用协议 3 的 profile（没有 `sync2_self` 行）也算没做完：它的数据只在旧投影表里，还没包成操作。
pub fn preflight(conn: &Connection, profile: &str) -> Result<Vec<String>, String> {
    let mut out = Vec::new();
    let migrated: Option<Option<i64>> = conn
        .prepare_cached("SELECT migrated_at FROM sync2_self WHERE profile_uid = srs_id(?1)")
        .map_err(sql)?
        .query_row([profile], |r| r.get(0))
        .optional()
        .map_err(sql)?;
    match migrated {
        None => out.push("profile has no protocol 3 identity (sync2_self)".to_owned()),
        Some(None) => out.push("legacy rows are not migrated into the op log yet".to_owned()),
        Some(Some(_)) => {}
    }
    for (table, what) in [
        (
            "sync2_migrate_queue",
            "legacy rows are still queued for migration",
        ),
        (
            "sync2_dedup",
            "a duplicate-stream convergence job is still running",
        ),
        ("sync2_boot", "a new-device ingest channel is still open"),
    ] {
        if !table_exists(conn, table)? {
            continue;
        }
        let busy = conn
            .prepare_cached(&format!(
                "SELECT 1 FROM {table} WHERE profile_uid = srs_id(?1)"
            ))
            .map_err(sql)?
            .exists([profile])
            .map_err(sql)?;
        if busy {
            out.push(what.to_owned());
        }
    }
    Ok(out)
}

/// 迁移时写进新身份原生日志的那条 `Salts` 的盐（设计 §5.1、§6.1 第 7 步）：这个 profile 的 uid，并上本机已退役的
/// profile uid（`srs_meta.srs_retired_profile_uids`，旧并入留下的）。升序、无重复。退役列表解不开当没有。
pub fn salts(conn: &Connection, profile: &str) -> Result<Vec<String>, String> {
    let mut out: std::collections::BTreeSet<String> =
        std::collections::BTreeSet::from([profile.to_owned()]);
    let retired: Option<String> = conn
        .prepare_cached("SELECT value FROM srs_meta WHERE key = 'srs_retired_profile_uids'")
        .map_err(sql)?
        .query_row([], |r| r.get(0))
        .optional()
        .map_err(sql)?;
    if let Some(list) = retired.and_then(|s| serde_json::from_str::<Vec<String>>(&s).ok()) {
        out.extend(list);
    }
    Ok(out.into_iter().collect())
}

/// 一台旧设备在这个库里的日志范围。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct LegacyDevice {
    pub device: Id,
    /// 已应用的最大 seq（`sync2_ops` 是从 1 起的连续前缀；0 = 一条都没有）。
    pub applied: u64,
    /// 待投递的条数（含与已应用同号的残留行）。
    pub pending: u64,
}

/// 这个 profile 的日志里出现过的旧设备（按设备 ID 升序）。
pub fn devices(conn: &Connection, profile: &str) -> Result<Vec<LegacyDevice>, String> {
    let mut by: BTreeMap<Id, LegacyDevice> = BTreeMap::new();
    for (table, applied) in [("sync2_ops", true), ("sync2_pending", false)] {
        let mut stmt = conn
            .prepare(&format!(
                "SELECT device, MAX(seq), COUNT(*) FROM {table} WHERE profile_uid = srs_id(?1) GROUP BY device"
            ))
            .map_err(sql)?;
        let mut rows = stmt.query([profile]).map_err(sql)?;
        while let Some(r) = rows.next().map_err(sql)? {
            let device = id_of(&r.get::<_, Vec<u8>>(0).map_err(sql)?)?;
            let max: i64 = r.get(1).map_err(sql)?;
            let n: i64 = r.get(2).map_err(sql)?;
            let e = by.entry(device).or_insert(LegacyDevice {
                device,
                applied: 0,
                pending: 0,
            });
            if applied {
                e.applied = max as u64;
            } else {
                e.pending = n as u64;
            }
        }
    }
    Ok(by.into_values().collect())
}

/// 这个 profile 还没信任的设备（协议 3 的 `sync2_trust`，纯本机状态）：(设备, 状态, 第一次见到的时刻)，按设备 ID 升序。
pub fn untrusted(conn: &Connection, profile: &str) -> Result<Vec<(Id, i64, i64)>, String> {
    if !table_exists(conn, "sync2_trust")? {
        return Ok(Vec::new());
    }
    let mut stmt = conn
        .prepare(
            "SELECT device, state, since FROM sync2_trust WHERE profile_uid = srs_id(?1) ORDER BY device",
        )
        .map_err(sql)?;
    let mut rows = stmt.query([profile]).map_err(sql)?;
    let mut out = Vec::new();
    while let Some(r) = rows.next().map_err(sql)? {
        out.push((
            id_of(&r.get::<_, Vec<u8>>(0).map_err(sql)?)?,
            r.get(1).map_err(sql)?,
            r.get(2).map_err(sql)?,
        ));
    }
    Ok(out)
}

/// 一条旧操作在旧库里的位置。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Placement {
    /// 已应用（`sync2_ops`）。
    Applied,
    /// 待投递（`sync2_pending`）：过界后仍然待投递。
    Pending,
}

/// 逐条读一台旧设备的日志：先已应用的（seq 升序、从 1 起连续、逐条验链），再待投递的（seq 升序）。
/// [f] 拿到操作、它处的原链值与位置。
pub fn for_each_op(
    conn: &Connection,
    profile: &str,
    device: &Id,
    mut f: impl FnMut(&Op, &Chain, Placement) -> Result<(), String>,
) -> Result<(), String> {
    let dev = device.0.to_vec();
    let mut chain = CHAIN_ZERO;
    let mut next = 1u64;
    {
        let mut stmt = conn
            .prepare("SELECT seq, chain FROM sync2_ops WHERE profile_uid = srs_id(?1) AND device = ?2 ORDER BY seq")
            .map_err(sql)?;
        let mut rows = stmt.query(params![profile, dev]).map_err(sql)?;
        while let Some(r) = rows.next().map_err(sql)? {
            let seq = r.get::<_, i64>(0).map_err(sql)? as u64;
            let stored = chain_of(r.get(1).map_err(sql)?)?;
            if seq != next {
                return Err(format!(
                    "legacy reader: {device} log is not a contiguous prefix (seq {seq} after {})",
                    next - 1
                ));
            }
            let id = OpId {
                device: *device,
                seq,
            };
            let op = load_op(conn, profile, &id)?
                .ok_or_else(|| format!("legacy reader: {device}:{seq} vanished mid-read"))?;
            v3::check_skeleton(op.purged, &op.payload)
                .map_err(|e| format!("legacy reader: {device}:{seq} {e}"))?;
            chain = chain_next(&chain, &op);
            if chain != stored {
                return Err(format!(
                    "legacy reader: {device}:{seq} does not hash to its stored chain"
                ));
            }
            f(&op, &chain, Placement::Applied)?;
            next += 1;
        }
    }
    let mut stmt = conn
        .prepare("SELECT seq, op, chain FROM sync2_pending WHERE profile_uid = srs_id(?1) AND device = ?2 ORDER BY seq")
        .map_err(sql)?;
    let mut rows = stmt.query(params![profile, dev]).map_err(sql)?;
    while let Some(r) = rows.next().map_err(sql)? {
        let seq = r.get::<_, i64>(0).map_err(sql)? as u64;
        let raw: Vec<u8> = r.get(1).map_err(sql)?;
        let stated = chain_of(r.get(2).map_err(sql)?)?;
        let mut rd = Reader::new(&raw);
        let op =
            Op::read(&mut rd).map_err(|e| format!("legacy reader: pending {device}:{seq} {e}"))?;
        if !rd.is_empty() || op.id.device != *device || op.id.seq != seq {
            return Err(format!(
                "legacy reader: pending {device}:{seq} does not match its row"
            ));
        }
        if seq < next {
            // 与已应用的同号：链值相同 = 投递过了还没删的残留，跳过；不同 = 分叉的一支，照常交出去。
            let applied: Vec<u8> = conn
                .prepare_cached("SELECT chain FROM sync2_ops WHERE profile_uid = srs_id(?1) AND device = ?2 AND seq = ?3")
                .map_err(sql)?
                .query_row(params![profile, dev, seq as i64], |r| r.get(0))
                .map_err(sql)?;
            if applied[..] == stated[..] {
                continue;
            }
        }
        f(&op, &stated, Placement::Pending)?;
    }
    Ok(())
}

/// 转译一遍的统计（验收与体积估算用）。
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Stats {
    /// 读到的旧操作（已应用 + 待投递，不含跳过的残留）。
    pub ops: u64,
    /// 其中待投递的。
    pub pending: u64,
    /// 槽的种类。
    pub slot_ops: u64,
    pub slot_raw3: u64,
    pub slot_alias: u64,
    pub slot_void: u64,
    /// 空洞里来自 MediaAt（种类 12）的；其余来自彻底清除的骨架。
    pub void_media_at: u64,
    /// 原样件的原因。
    pub raw: BTreeMap<RawReason, u64>,
    /// 旧操作按种类（含骨架）。
    pub kinds: BTreeMap<u16, u64>,
    /// 转出的操作按种类。
    pub op_kinds: BTreeMap<u16, u64>,
    /// 紧凑旧戳的个数与规范编码字节（操作里的 + 副本记录里的）。
    pub stamps: u64,
    pub stamp_bytes: u64,
    /// 旧载荷字节（骨架按骨架的字节算）与转出的槽的规范编码字节。
    pub legacy_payload_bytes: u64,
    pub slot_bytes: u64,
}

impl Stats {
    /// 协议 3 会应用、却没能转成操作的原样件条数。真实库里应当是 0。
    pub fn raw_applied_by_protocol_3(&self) -> u64 {
        self.raw
            .iter()
            .filter(|(r, _)| r.applied_by_protocol_3())
            .map(|(_, n)| n)
            .sum()
    }

    fn note(&mut self, op: &Op, slot: &HeritageSlot, placement: Placement) {
        self.ops += 1;
        if placement == Placement::Pending {
            self.pending += 1;
        }
        *self.kinds.entry(op.kind).or_default() += 1;
        self.legacy_payload_bytes += op.payload.len() as u64;
        self.slot_bytes += slot.encode().len() as u64;
        let stamp = match &slot.body {
            SlotBody::Op(o) => {
                self.slot_ops += 1;
                *self.op_kinds.entry(o.kind).or_default() += 1;
                match o.body() {
                    Ok(Body4::Edit(e)) => e.stamp,
                    _ => None,
                }
            }
            SlotBody::Raw3(_) => {
                self.slot_raw3 += 1;
                if let Some(r) = raw_reason(op) {
                    *self.raw.entry(r).or_default() += 1;
                }
                None
            }
            SlotBody::Alias(a) => {
                self.slot_alias += 1;
                a.stamp.clone()
            }
            SlotBody::Void => {
                self.slot_void += 1;
                if op.kind == v3::KIND_MEDIA_AT {
                    self.void_media_at += 1;
                }
                None
            }
        };
        if let Some(s) = stamp {
            self.stamps += 1;
            self.stamp_bytes += s.encode().len() as u64;
        }
    }
}

/// 读一台旧设备的日志并逐条转译。[f] 拿到槽与它的位置；统计累加进 [stats]。
pub fn translate_device(
    conn: &Connection,
    profile: &str,
    device: &Id,
    stats: &mut Stats,
    mut f: impl FnMut(HeritageSlot, Placement) -> Result<(), String>,
) -> Result<(), String> {
    for_each_op(conn, profile, device, |op, chain, placement| {
        let slot = translate(op, chain)
            .map_err(|m| format!("legacy reader: {}:{} {m}", op.id.device, op.id.seq))?;
        stats.note(op, &slot, placement);
        f(slot, placement)
    })
}

#[cfg(test)]
pub(crate) mod tests {
    use std::collections::{BTreeMap, BTreeSet};

    use rusqlite::params;
    use serde_json::{Value, json};

    use super::*;
    use crate::gen4::heritage::{HeritageMeta, open_heritage, pack_heritage};
    use crate::gen4::translate::{SlotSet, T_VERSION, dedup_slot};
    use crate::store::sync2::tests::{
        Bucket, DAY, Device, P, deck_entity, edit, legacy_library, review,
    };
    use crate::sync2::keys::DeviceKey;

    pub(crate) const T0: i64 = 1_700_000_000_000;

    /// 旧事件 → 操作的迁移做完（新库里没有旧事件，一步就完；[preflight] 要求它做完）。
    pub(crate) fn migrate(d: &Device) {
        while d.core.sync2_migrate(P, T0, None).unwrap()["done"] != json!(true) {}
    }

    pub(crate) fn device() -> Device {
        let d = Device::new("g4");
        migrate(&d);
        d
    }

    pub(crate) fn device_id(d: &Device) -> Id {
        Id::parse(
            d.core.sync2_identity(P, T0).unwrap()["device"]
                .as_str()
                .unwrap(),
        )
        .unwrap()
    }

    fn count(d: &Device, sql: &str) -> i64 {
        d.rows(sql)[1][0].parse().unwrap()
    }

    /// 一台设备库里的全部槽：已应用的并成集合，待投递的另列。
    pub(crate) fn read_all(d: &Device) -> (SlotSet, Vec<HeritageSlot>, Stats) {
        let w = d.core.writer().unwrap();
        assert_eq!(preflight(&w, P).unwrap(), Vec::<String>::new());
        let mut stats = Stats::default();
        let mut set = SlotSet::new();
        let mut pending = Vec::new();
        for dev in devices(&w, P).unwrap() {
            translate_device(&w, P, &dev.device, &mut stats, |s, p| {
                match p {
                    Placement::Applied => set.insert(s).map_err(|e| e.to_string())?,
                    Placement::Pending => pending.push(s),
                }
                Ok(())
            })
            .unwrap();
        }
        (set, pending, stats)
    }

    fn slot_of(set: &SlotSet, id: OpId) -> HeritageSlot {
        set.iter().find(|s| s.id == id).cloned().unwrap()
    }

    /// 两台设备：牌组配置、带配置快照的复习、笔记字段与标签、媒体。
    pub(crate) fn pair() -> (Device, Device, Bucket) {
        let (a, b) = (device(), device());
        let deck = crate::store::sync2::config::default_deck_id(P);
        let mut bucket = Bucket::default();
        a.apply(
            T0,
            vec![
                deck_entity(&deck),
                edit("deck", &deck, "retention", json!(0.8)),
                edit("note", "N1", "f/x", json!("secret text")),
                edit("note", "N1", "tags", json!(["private", "b"])),
            ],
        );
        a.sync(&mut bucket, "loc", T0);
        b.sync(&mut bucket, "loc", T0);
        a.apply(T0 + 10, vec![review("r1", "C", T0 + 10, 3, "learn")]);
        a.apply(T0 + DAY, vec![review("r2", "C", T0 + DAY, 3, "review")]);
        b.apply(
            T0 + DAY + 1,
            vec![
                edit("note", "N1", "f/y", json!("more secret")),
                review("r3", "C", T0 + DAY + 1, 2, "review"),
            ],
        );
        for _ in 0..2 {
            a.sync(&mut bucket, "loc", T0 + DAY + 2);
            b.sync(&mut bucket, "loc", T0 + DAY + 2);
        }
        (a, b, bucket)
    }

    #[test]
    fn the_reader_feeds_t_the_bytes_the_author_chained() {
        let (a, b, _) = pair();
        let both = BTreeSet::from([device_id(&a), device_id(&b)]);
        let w = a.core.writer().unwrap();
        assert_eq!(profiles(&w).unwrap(), [P]);
        let devs = devices(&w, P).unwrap();
        assert_eq!(devs.iter().map(|d| d.device).collect::<BTreeSet<_>>(), both);
        // 逐条读出来的就是 `load_op` 给的那条，条数与库里相同，链逐条对上（读入器内部验）。
        let mut n = 0;
        for dev in &devs {
            let mut seq = 0;
            for_each_op(&w, P, &dev.device, |op, _, placement| {
                seq += 1;
                n += 1;
                assert_eq!(placement, Placement::Applied);
                assert_eq!(
                    op.id,
                    OpId {
                        device: dev.device,
                        seq
                    }
                );
                assert_eq!(Some(op), load_op(&w, P, &op.id).unwrap().as_ref());
                Ok(())
            })
            .unwrap();
            assert_eq!(seq, dev.applied);
        }
        drop(w);
        assert_eq!(n, count(&a, "SELECT COUNT(*) FROM sync2_ops"));
        // 本机把配置快照剪出去另存、把载荷压缩过的行确实存在（这条测试才测得到「拼回」）。
        assert!(count(&a, "SELECT COUNT(*) FROM sync2_ops WHERE sc IS NOT NULL") > 0);
        // 两台收全了的设备转出来逐槽相同。
        let (sa, pa, stats) = read_all(&a);
        let (sb, pb, _) = read_all(&b);
        assert_eq!(sa, sb);
        assert!(pa.is_empty() && pb.is_empty());
        assert_eq!(stats.ops, n as u64);
        assert_eq!(stats.slot_ops, stats.ops);
        assert_eq!(stats.raw_applied_by_protocol_3(), 0);
        // 带配置快照的日志：转出的操作里快照原文完整。
        let with_sc = sa
            .iter()
            .filter_map(crate::gen4::translate::applied_body)
            .filter(|b| matches!(b, Body4::Log(l) if l.extra.contains("\"sc\":{")))
            .count();
        assert!(with_sc > 0);
    }

    #[test]
    fn a_stored_payload_that_is_not_the_chained_one_is_refused() {
        let (a, _, _) = pair();
        let me = device_id(&a);
        let w = a.core.writer().unwrap();
        // 快照行丢了：拼不回原文，读入器原样报错（不退回用没拼回的字节）。
        w.execute_batch("SAVEPOINT t").unwrap();
        let (seq, sc): (i64, String) = w
            .query_row(
                "SELECT seq, sc FROM sync2_ops WHERE device = ?1 AND sc IS NOT NULL LIMIT 1",
                [me.0.to_vec()],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .unwrap();
        let n = w
            .execute(
                "UPDATE sync2_ops SET sc = ?1 WHERE device = ?2 AND seq = ?3",
                params![format!("{sc}x"), me.0.to_vec(), seq],
            )
            .unwrap();
        assert_eq!(n, 1);
        let err = for_each_op(&w, P, &me, |_, _, _| Ok(())).unwrap_err();
        assert!(err.contains("config snapshot"), "{err}");
        w.execute_batch("ROLLBACK TO t").unwrap();
        // 载荷被换过（链对不上）。
        let other = v3::Body::Checkpoint {
            name: "x".into(),
            reason: "y".into(),
        }
        .encode();
        w.execute("UPDATE sync2_ops SET payload = ?1, pz = 0, sc = NULL, sc_at = NULL WHERE device = ?2 AND seq = 2", params![other, me.0.to_vec()])
            .unwrap();
        let err = for_each_op(&w, P, &me, |_, _, _| Ok(())).unwrap_err();
        assert!(err.contains("does not hash to its stored chain"), "{err}");
        w.execute_batch("ROLLBACK TO t").unwrap();
        // 中间缺一条。
        w.execute(
            "DELETE FROM sync2_ops WHERE device = ?1 AND seq = 2",
            [me.0.to_vec()],
        )
        .unwrap();
        let err = for_each_op(&w, P, &me, |_, _, _| Ok(())).unwrap_err();
        assert!(err.contains("not a contiguous prefix"), "{err}");
        w.execute_batch("ROLLBACK TO t; RELEASE t").unwrap();
        for_each_op(&w, P, &me, |_, _, _| Ok(())).unwrap();
    }

    #[test]
    fn a_device_that_purged_and_one_that_has_not_yet_converge() {
        let (a, b, mut bucket) = pair();
        let (before, _, _) = read_all(&b);
        a.core.sync2_purge(P, "note", "N1", T0 + 2 * DAY).unwrap();
        a.sync(&mut bucket, "loc", T0 + 2 * DAY);
        let (sa, _, stats) = read_all(&a);
        assert!(
            stats.slot_void >= 3,
            "the content ops of N1 are voids: {stats:?}"
        );
        assert_eq!(stats.void_media_at, 0);
        // b 还没收到清除：它手里是完整的。两边各上传一份，并起来 = 已清除的那一份。
        let mut union = before.clone();
        union.merge(&sa).unwrap();
        assert_eq!(union, sa);
        let mut union = sa.clone();
        union.merge(&before).unwrap();
        assert_eq!(union, sa);
        assert!(union.forks().is_empty());
        // b 收到并应用清除之后，自己转出来的也逐槽相同。
        for _ in 0..2 {
            b.sync(&mut bucket, "loc", T0 + 2 * DAY + 1);
            a.sync(&mut bucket, "loc", T0 + 2 * DAY + 1);
        }
        assert_eq!(read_all(&b).0, read_all(&a).0);
    }

    #[test]
    fn a_duplicate_skeleton_in_the_log_becomes_an_alias() {
        let (a, _, _) = pair();
        let me = device_id(&a);
        let (before, _, _) = read_all(&a);
        let twin = OpId {
            device: Id([0xee; 16]),
            seq: 40,
        };
        // 本机的第一条修改。与 store/sync2/dedup.rs `apply` 同样的落库：载荷换成副本骨架、清掉本地压缩与快照引用，链值不动。
        let id = {
            let w = a.core.writer().unwrap();
            let mut first: Option<Op> = None;
            for_each_op(&w, P, &me, |op, _, _| {
                if first.is_none() && op.kind == v3::KIND_EDIT {
                    first = Some(op.clone());
                }
                Ok(())
            })
            .unwrap();
            let op = first.unwrap();
            let dup = op.duplicate(twin).unwrap();
            w.execute(
                "UPDATE sync2_ops SET payload = ?1, purged = 1, sc = NULL, sc_at = NULL, pz = 0 WHERE device = ?2 AND seq = ?3",
                params![&dup.payload[..], me.0.to_vec(), op.id.seq as i64],
            )
            .unwrap();
            op.id
        };
        let (after, _, stats) = read_all(&a);
        assert_eq!(stats.slot_alias, 1);
        let alias = slot_of(&after, id);
        assert_eq!(alias, dedup_slot(&slot_of(&before, id), twin).unwrap());
        // 还没认副本的设备与认了的设备并起来 = 认了的。
        let mut union = before.clone();
        union.merge(&after).unwrap();
        assert_eq!(union, after);
    }

    #[test]
    fn pending_ops_are_translated_and_stay_pending() {
        let (a, b) = (device(), device());
        let mut bucket = Bucket::default();
        for i in 0..6 {
            let at = T0 + i * 600_000;
            a.apply(at, vec![edit("note", "N1", "f/x", json!(format!("a{i}")))]);
            a.sync(&mut bucket, "loc", at);
            b.sync(&mut bucket, "loc", at);
            b.apply(
                at + 1,
                vec![edit("note", "N1", "f/x", json!(format!("b{i}")))],
            );
            b.sync(&mut bucket, "loc", at + 1);
            a.sync(&mut bucket, "loc", at + 1);
        }
        // 新设备只拿到 b 的段：b 的操作依赖 a 的，投不了，进待投递。
        let now = T0 + 9 * DAY;
        let c = device();
        c.core.sync2_identity(P, now).unwrap();
        let heads: Vec<Vec<u8>> = bucket
            .0
            .iter()
            .filter(|(k, _)| k.contains("/head-"))
            .map(|(_, v)| v.clone())
            .collect();
        let plan = c.core.sync2_plan(P, &heads).unwrap();
        let b_dev = device_id(&b);
        let files: Vec<Vec<u8>> = plan["fetch"]
            .as_array()
            .unwrap()
            .iter()
            .flat_map(|f| f["files"].as_array().unwrap().iter())
            .map(|n| n.as_str().unwrap())
            .filter(|n| n.contains(&b_dev.text()))
            .map(|n| bucket.0[n].clone())
            .collect();
        let out: Value =
            serde_json::from_str(&c.core.sync2_ingest(P, &files, None, now).unwrap()).unwrap();
        let waiting = count(&c, "SELECT COUNT(*) FROM sync2_pending");
        assert!(waiting > 0, "{out}");
        let (applied, pending, stats) = read_all(&c);
        assert_eq!(pending.len() as i64, waiting);
        assert_eq!(stats.pending, waiting as u64);
        // 待投递的槽与作者自己库里转出的那一条逐字节相同（链值是收段时按段算的，与作者的相同）。
        let (author, _, _) = read_all(&b);
        for s in &pending {
            assert_eq!(s.id.device, b_dev);
            assert_eq!(s, &slot_of(&author, s.id));
            assert!(applied.iter().all(|x| x.id != s.id));
        }
        // 与已应用的同号的待投递行：链值相同 = 残留，跳过；链值不同 = 分叉的一支，照常交出。
        let me = device_id(&c);
        c.apply(now, vec![edit("note", "N2", "f/x", json!("mine"))]);
        let w = c.core.writer().unwrap();
        let own = load_op(&w, P, &OpId { device: me, seq: 1 })
            .unwrap()
            .unwrap();
        let chain: Vec<u8> = w
            .query_row(
                "SELECT chain FROM sync2_ops WHERE device = ?1 AND seq = 1",
                [me.0.to_vec()],
                |r| r.get(0),
            )
            .unwrap();
        let insert = |chain: &[u8]| {
            w.execute(
                "INSERT OR REPLACE INTO sync2_pending (profile_uid, device, seq, op, chain) VALUES (srs_id(?1), ?2, 1, ?3, ?4)",
                params![P, me.0.to_vec(), own.encode(), chain],
            )
            .unwrap();
        };
        let mine = |w: &Connection| {
            let mut got = Vec::new();
            for_each_op(w, P, &me, |op, c, p| {
                got.push((op.id.seq, c[0], p));
                Ok(())
            })
            .unwrap();
            got
        };
        insert(&chain);
        assert_eq!(mine(&w), [(1, chain[0], Placement::Applied)]);
        let mut forked = chain.clone();
        forked[0] ^= 0xff;
        insert(&forked);
        assert_eq!(
            mine(&w),
            [
                (1, chain[0], Placement::Applied),
                (1, forked[0], Placement::Pending)
            ]
        );
    }

    #[test]
    fn preflight_stops_a_library_that_is_not_fully_on_protocol_3() {
        let d = Device::new("g4-pre");
        legacy_library(&d);
        {
            let w = d.core.writer().unwrap();
            let blockers = preflight(&w, P).unwrap();
            assert_eq!(blockers.len(), 1, "{blockers:?}");
            assert!(blockers[0].contains("no protocol 3 identity"));
        }
        // 身份有了、旧事件还没包成操作。
        d.core.sync2_identity(P, T0).unwrap();
        {
            let w = d.core.writer().unwrap();
            let blockers = preflight(&w, P).unwrap();
            assert!(
                blockers.iter().any(|b| b.contains("not migrated")),
                "{blockers:?}"
            );
        }
        // 迁移做到一半。
        let r = d.core.sync2_migrate(P, T0, Some(2)).unwrap();
        assert_eq!(r["done"], json!(false), "{r}");
        {
            let w = d.core.writer().unwrap();
            let blockers = preflight(&w, P).unwrap();
            assert!(
                blockers.iter().any(|b| b.contains("still queued")),
                "{blockers:?}"
            );
        }
        migrate(&d);
        // 去重作业（若排了）做完。
        for _ in 0..1000 {
            if d.core.sync2_dedup(P, T0).unwrap()["done"] == json!(true) {
                break;
            }
        }
        let w = d.core.writer().unwrap();
        assert_eq!(preflight(&w, P).unwrap(), Vec::<String>::new());
        // 排着去重作业的库不能读。
        w.execute("INSERT OR IGNORE INTO sync2_dedup (profile_uid, phase, cur_dev, cur_seq) VALUES (srs_id(?1), 0, x'', 0)", [P]).unwrap();
        assert!(
            preflight(&w, P)
                .unwrap()
                .iter()
                .any(|b| b.contains("convergence job"))
        );
        // 迁移出来的旧修改带旧戳：转出的操作带紧凑旧戳。
        w.execute("DELETE FROM sync2_dedup", []).unwrap();
        drop(w);
        let (_, _, stats) = read_all(&d);
        assert!(stats.stamps >= 2, "{stats:?}");
        assert_eq!(stats.slot_ops, stats.ops);
    }

    #[test]
    fn a_whole_device_log_packs_into_heritage_segments() {
        let (a, _, _) = pair();
        let signer = DeviceKey::from_seed(&[7; 32]);
        let me = device_id(&a);
        let w = a.core.writer().unwrap();
        for dev in devices(&w, P).unwrap() {
            let mut slots = Vec::new();
            let mut last = [0u8; 32];
            let mut stats = Stats::default();
            for_each_op(&w, P, &dev.device, |op, chain, _| {
                last = *chain;
                slots.push(translate(op, chain).unwrap());
                Ok(())
            })
            .unwrap();
            translate_device(&w, P, &dev.device, &mut stats, |_, _| Ok(())).unwrap();
            let meta = HeritageMeta {
                collection: Id([0xc0; 16]),
                source: crate::store::sync2::collection_of(P),
                device: dev.device,
                uploader: me,
                t_version: T_VERSION,
                prev_chain: CHAIN_ZERO,
                last_chain: last,
            };
            let (header, bytes) = pack_heritage(&meta, &slots, &signer, None).unwrap();
            assert_eq!((header.first, header.last), (1, dev.applied));
            assert_eq!(
                open_heritage(&bytes, &signer.public(), None).unwrap().1,
                slots
            );
            assert_eq!(stats.ops as usize, slots.len());
        }
    }

    // ------------------------------------------------------------ 真实样本（不进默认测试）

    pub(crate) use crate::store::gen4::dryrun::peak_mem_mb;

    pub(crate) fn sample() -> Option<Connection> {
        let path = std::env::var("FUSHI_GEN4_SAMPLE_DB").ok()?;
        let conn =
            Connection::open_with_flags(&path, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY).unwrap();
        crate::store::ids::register(&conn).unwrap();
        Some(conn)
    }

    fn uv_len(mut v: u64) -> u64 {
        let mut n = 1;
        while v >= 0x80 {
            v >>= 7;
            n += 1;
        }
        n
    }

    fn name_len(s: &str) -> u64 {
        let mut w = crate::sync2::codec::Writer::new();
        crate::gen4::name::write_name(&mut w, s);
        w.into_vec().len() as u64
    }

    /// 在真实库的私有拷贝上把全部旧操作转译一遍：计数、紧凑旧戳的体积（两种口径）、逐戳核对、耗时与峰值内存。
    ///
    /// `FUSHI_GEN4_SAMPLE_DB=<srs.db 的私有拷贝> cargo test --release --lib gen4_sample_translate -- --ignored --nocapture`
    #[test]
    #[ignore]
    fn gen4_sample_translate() {
        let Some(conn) = sample() else {
            println!("FUSHI_GEN4_SAMPLE_DB not set");
            return;
        };
        let started = std::time::Instant::now();
        let mut stats = Stats::default();
        let mut names: BTreeMap<String, u64> = BTreeMap::new();
        // 名字换成表下标之后旧戳的字节（下标按 1 字节 / 2 字节 varint 估：按首次出现的次序编号）。
        let mut indexed_bytes = 0u64;
        let (mut legacy_stamp_bytes, mut stamp_mismatch, mut ctx_with_cloud, mut raw_hlc) =
            (0u64, 0u64, 0u64, 0u64);
        let (mut log_hlc, mut log_hlc_raw, mut logs_with_sc) = (0u64, 0u64, 0u64);
        // 体积拆分：副本记录上的旧戳（个数 / 内联字节 / 名字换下标字节）、上下文项数、HLC 两个数与服务器时刻各占的字节。
        let (mut alias_stamps, mut alias_inline, mut alias_indexed) = (0u64, 0u64, 0u64);
        let (mut ctx_entries, mut hlc_num_bytes, mut st_bytes, mut with_st) =
            (0u64, 0u64, 0u64, 0u64);
        let mut per_device = Vec::new();
        for profile in profiles(&conn).unwrap() {
            println!(
                "profile {profile}: preflight {:?}",
                preflight(&conn, &profile).unwrap()
            );
            for dev in devices(&conn, &profile).unwrap() {
                let before = stats.ops;
                for_each_op(&conn, &profile, &dev.device, |op, chain, placement| {
                    let slot = translate(op, chain).map_err(str::to_owned)?;
                    stats.note(op, &slot, placement);
                    // 旧戳逐个核对：写入者 / 序号 / HLC 文本 / 服务器时刻逐字相同；上下文与现有读法给出同一个向量。
                    let legacy = match op.body() {
                        Ok(v3::Body::Edit(e)) => e.legacy,
                        Ok(v3::Body::Duplicate { legacy, .. }) => legacy,
                        Ok(v3::Body::Log(l)) => {
                            if let Some(h) = &l.legacy_hlc {
                                log_hlc += 1;
                                if matches!(
                                    crate::gen4::stamp::StampHlc::of(h),
                                    crate::gen4::stamp::StampHlc::Raw(_)
                                ) {
                                    log_hlc_raw += 1;
                                }
                            }
                            if l.extra.contains("\"sc\":{") {
                                logs_with_sc += 1;
                            }
                            None
                        }
                        _ => None,
                    };
                    let stamp = match &slot.body {
                        SlotBody::Op(o) => match o.body() {
                            Ok(Body4::Edit(e)) => e.stamp,
                            _ => None,
                        },
                        SlotBody::Alias(a) => a.stamp.clone(),
                        _ => None,
                    };
                    match (&legacy, &stamp) {
                        (Some(l), Some(s)) => {
                            let mut want = crate::sync2::dvv::Dvv::parse(&l.ctx_json);
                            want.drop_writers(crate::gen4::stamp::SYNTHETIC_PREFIX);
                            if s.writer != l.writer
                                || s.seq != l.seq
                                || s.hlc.text() != l.hlc
                                || s.server_time != l.server_time
                                || s.ctx.to_dvv() != want
                            {
                                stamp_mismatch += 1;
                            }
                            legacy_stamp_bytes +=
                                (l.writer.len() + l.ctx_json.len() + l.hlc.len() + 12) as u64;
                            let inline = s.encode().len() as u64;
                            let mut name_bytes = 0;
                            let mut refs = 0;
                            let mut seen = |n: &str| {
                                let next = names.len() as u64;
                                let ix = *names.entry(n.to_owned()).or_insert(next);
                                name_bytes += name_len(n);
                                refs += uv_len(ix);
                            };
                            seen(&s.writer);
                            for e in s.ctx.entries() {
                                if !e.cloud.is_empty() {
                                    ctx_with_cloud += 1;
                                }
                                if e.writer != s.writer {
                                    seen(&e.writer);
                                }
                            }
                            match &s.hlc {
                                crate::gen4::stamp::StampHlc::Parsed { writer, .. }
                                    if *writer != s.writer =>
                                {
                                    seen(writer)
                                }
                                crate::gen4::stamp::StampHlc::Raw(_) => raw_hlc += 1,
                                _ => {}
                            }
                            let indexed = inline - name_bytes + refs;
                            indexed_bytes += indexed;
                            if matches!(slot.body, SlotBody::Alias(_)) {
                                alias_stamps += 1;
                                alias_inline += inline;
                                alias_indexed += indexed;
                            }
                            ctx_entries += s.ctx.entries().len() as u64;
                            let zz = |v: i64| uv_len(((v << 1) ^ (v >> 63)) as u64);
                            if let crate::gen4::stamp::StampHlc::Parsed {
                                physical, counter, ..
                            } = &s.hlc
                            {
                                hlc_num_bytes += zz(*physical) + zz(*counter);
                                if let Some(t) = s.server_time {
                                    with_st += 1;
                                    st_bytes += zz(t.wrapping_sub(*physical));
                                }
                            }
                        }
                        (None, None) => {}
                        _ => stamp_mismatch += 1,
                    }
                    Ok(())
                })
                .unwrap();
                per_device.push((dev.device, dev.applied, dev.pending, stats.ops - before));
            }
        }
        let elapsed = started.elapsed();
        let (peak_ws, peak_commit) = peak_mem_mb();
        let names_bytes: u64 = names.keys().map(|n| name_len(n)).sum();
        println!("SAMPLE elapsed_s {:.1}", elapsed.as_secs_f64());
        println!("SAMPLE peak_working_set_mb {peak_ws:.0} peak_commit_mb {peak_commit:.0}");
        println!("SAMPLE ops {} pending {}", stats.ops, stats.pending);
        println!(
            "SAMPLE slots op {} raw3 {} alias {} void {} (media_at {})",
            stats.slot_ops, stats.slot_raw3, stats.slot_alias, stats.slot_void, stats.void_media_at
        );
        println!(
            "SAMPLE raw_reasons {:?} applied_by_protocol_3 {}",
            stats.raw,
            stats.raw_applied_by_protocol_3()
        );
        println!("SAMPLE legacy_kinds {:?}", stats.kinds);
        println!("SAMPLE op_kinds {:?}", stats.op_kinds);
        println!(
            "SAMPLE stamps {} inline_bytes {} indexed_bytes {} names {} names_bytes {} legacy_stamp_bytes {}",
            stats.stamps,
            stats.stamp_bytes,
            indexed_bytes,
            names.len(),
            names_bytes,
            legacy_stamp_bytes
        );
        println!(
            "SAMPLE stamp_mismatch {stamp_mismatch} ctx_entries_with_cloud {ctx_with_cloud} raw_hlc {raw_hlc}"
        );
        println!(
            "SAMPLE stamps_on_aliases {alias_stamps} inline_bytes {alias_inline} indexed_bytes {alias_indexed} ctx_entries {ctx_entries} hlc_number_bytes {hlc_num_bytes} with_server_time {with_st} server_time_bytes {st_bytes}"
        );
        println!("SAMPLE log_hlc {log_hlc} log_hlc_raw {log_hlc_raw} logs_with_sc {logs_with_sc}");
        println!(
            "SAMPLE legacy_payload_bytes {} slot_bytes {}",
            stats.legacy_payload_bytes, stats.slot_bytes
        );
        for (d, applied, pending, n) in &per_device {
            println!("SAMPLE device {d} applied {applied} pending {pending} read {n}");
        }
        for (table, what) in [("sync2_trust_held", "what"), ("sync2_trust", "state")] {
            if table_exists(&conn, table).unwrap() {
                let rows: Vec<(String, i64)> = conn
                    .prepare(&format!(
                        "SELECT CAST({what} AS TEXT), COUNT(*) FROM {table} GROUP BY 1"
                    ))
                    .unwrap()
                    .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))
                    .unwrap()
                    .collect::<Result<_, _>>()
                    .unwrap();
                println!("SAMPLE {table} {rows:?}");
            }
        }
        assert_eq!(stamp_mismatch, 0);
        assert_eq!(stats.raw_applied_by_protocol_3(), 0);
    }

    /// 在真实库的私有拷贝上把每台旧设备的槽切成承袭段、打包、读回：总字节数与往返。
    ///
    /// `FUSHI_GEN4_SAMPLE_DB=<…> cargo test --release --lib gen4_sample_pack -- --ignored --nocapture`
    #[test]
    #[ignore]
    fn gen4_sample_pack() {
        const CHUNK: usize = 20_000;
        let Some(conn) = sample() else {
            println!("FUSHI_GEN4_SAMPLE_DB not set");
            return;
        };
        let started = std::time::Instant::now();
        let signer = DeviceKey::from_seed(&[7; 32]);
        let (mut files, mut bytes_total, mut slots_total) = (0u64, 0u64, 0u64);
        for profile in profiles(&conn).unwrap() {
            let source = crate::store::sync2::collection_of(&profile);
            for dev in devices(&conn, &profile).unwrap() {
                let mut chunk: Vec<HeritageSlot> = Vec::new();
                let mut prev = CHAIN_ZERO;
                let mut last = CHAIN_ZERO;
                let mut flush = |chunk: &mut Vec<HeritageSlot>, prev: &mut Chain, last: &Chain| {
                    if chunk.is_empty() {
                        return;
                    }
                    let meta = HeritageMeta {
                        collection: source,
                        source,
                        device: dev.device,
                        uploader: Id([0xa1; 16]),
                        t_version: T_VERSION,
                        prev_chain: *prev,
                        last_chain: *last,
                    };
                    let (_, bytes) = pack_heritage(&meta, chunk, &signer, None).unwrap();
                    let back = open_heritage(&bytes, &signer.public(), None).unwrap().1;
                    assert_eq!(&back, chunk);
                    files += 1;
                    bytes_total += bytes.len() as u64;
                    slots_total += chunk.len() as u64;
                    chunk.clear();
                    *prev = *last;
                };
                for_each_op(&conn, &profile, &dev.device, |op, chain, placement| {
                    if placement == Placement::Pending {
                        return Ok(());
                    }
                    chunk.push(translate(op, chain).map_err(str::to_owned)?);
                    last = *chain;
                    if chunk.len() == CHUNK {
                        flush(&mut chunk, &mut prev, &last);
                    }
                    Ok(())
                })
                .unwrap();
                flush(&mut chunk, &mut prev, &last);
            }
        }
        let (peak_ws, peak_commit) = peak_mem_mb();
        println!(
            "SAMPLE pack files {files} slots {slots_total} bytes {bytes_total} elapsed_s {:.1} peak_working_set_mb {peak_ws:.0} peak_commit_mb {peak_commit:.0}",
            started.elapsed().as_secs_f64()
        );
    }
}
