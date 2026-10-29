//! 段协议在 srs.db 上的一侧（设计 §6.1、§6.2、§7.3、§7.4）：发件（切段、打包、head）、收件（看 head 定要拉
//! 哪些段、校验、因果投递、投影、重放）、身份分叉（换身份、重签发）。
//!
//! 传输本身（列目录 / 读写文件）在 Dart（fushi_engine 的存储位置适配层），这里只吃字节、吐字节：
//! 一轮同步个位数次 FFI（发件、写 head、看 head、收段）。

use std::collections::{BTreeMap, BTreeSet};
use std::sync::Arc;

use rusqlite::{params, Connection, OptionalExtension};
use serde_json::{json, Value};

use super::{applied_vv, in_savepoint, insert_op, load_op, project, replay_touched, sql, Local, Touched};
use crate::store::SrsCore;
use crate::sync2::codec::{Reader, ZstdWindow};
use crate::sync2::id::Id;
use crate::sync2::keys::CollectionKey;
use crate::sync2::op::{Body, Op};
use crate::sync2::segment::{self, chain_next, Chain, Head, CHAIN_ZERO};
use crate::sync2::vv::{OpId, Vv};

fn chain_at(conn: &Connection, profile: &str, device: &Id, seq: u64) -> Result<Option<Chain>, String> {
    if seq == 0 {
        return Ok(Some(CHAIN_ZERO));
    }
    conn.prepare_cached("SELECT chain FROM sync2_ops WHERE profile_uid = ?1 AND device = ?2 AND seq = ?3")
        .map_err(sql)?
        .query_row(params![profile, device.0.to_vec(), seq as i64], |r| r.get::<_, Vec<u8>>(0))
        .optional()
        .map_err(sql)?
        .map(|b| b.try_into().map_err(|_| "bad chain".to_string()))
        .transpose()
}

//// 本机 seq 闭区间 [first, last] 的操作逐条喂进切段器（不把整段攒在内存里）。
fn split_seq_range(conn: &Connection, local: &Local, first: u64, last: u64) -> Result<Vec<(u64, u64, u64)>, String> {
    let mut s = segment::Splitter::new();
    for seq in first..=last {
        s.push(load_op(conn, &local.profile, &OpId { device: local.device, seq })?.ok_or("missing local op")?);
    }
    Ok(s.finish())
}

/// 本机的切段点 `(first, last, 压缩后体积估计；0 = 未知)`，按 seq 升序。
fn segments_of(conn: &Connection, local: &Local) -> Result<Vec<(u64, u64, u64)>, String> {
    conn.prepare_cached("SELECT first, last, bytes FROM sync2_segments WHERE profile_uid = ?1 AND device = ?2 ORDER BY first")
        .map_err(sql)?
        .query_map(params![local.profile, local.device.0.to_vec()], |r| {
            Ok((r.get::<_, i64>(0)? as u64, r.get::<_, i64>(1)? as u64, r.get::<_, i64>(2)? as u64))
        })
        .map_err(sql)?
        .collect::<Result<_, _>>()
        .map_err(sql)
}

/// 本设备的切段点：还没切的本机操作按体积目标切成新段（切点一旦定下就不变，各位置拿到的是同样的段）。
fn cut_segments(conn: &Connection, local: &Local) -> Result<Vec<(u64, u64)>, String> {
    let last_cut: u64 = conn
        .query_row(
            "SELECT COALESCE(MAX(last), 0) FROM sync2_segments WHERE profile_uid = ?1 AND device = ?2",
            params![local.profile, local.device.0.to_vec()],
            |r| r.get::<_, i64>(0),
        )
        .map_err(sql)? as u64;
    let top = local.next_seq - 1;
    if top > last_cut {
        for (a, b, bytes) in split_seq_range(conn, local, last_cut + 1, top)? {
            conn.execute(
                "INSERT OR IGNORE INTO sync2_segments (profile_uid, device, first, last, bytes) VALUES (?1, ?2, ?3, ?4, ?5)",
                params![local.profile, local.device.0.to_vec(), a as i64, b as i64, bytes as i64],
            )
            .map_err(sql)?;
        }
    }
    Ok(segments_of(conn, local)?.into_iter().map(|(a, b, _)| (a, b)).collect())
}

/// 分层合并（设计 §7.1）：每轮同步切出的小段按体积分层（[COMPACT_BASE] 起每 [COMPACT_FANOUT] 倍一层），同层相邻
/// 攒够 [COMPACT_FANOUT] 个就合成一个更高层的段——像二进制进位，本机的段数始终是「满段 + 每层不到几个」，每条
/// 操作一生只被重写对数次。满段（≥ 目标一半）不再动。新设备 / 落后很多的设备因此只拉十几个文件，而不是上千个。
///
/// 合并 = 同一 seq 区间、同样的操作按体积目标重新切、重新签名，名字随之变化。各位置上已经有旧段的：合并后的段
/// 登记成「要重传」（[sync2_rewrites]），旧段登记成「待删」（[sync2_obsolete]）；待删的旧文件在新 head 写出、且
/// 所有活跃设备的 ack 都越过它之后才删（`sync2_head` 返回），归档位置由 Dart 侧跳过删除。还没传过的位置直接拿
/// 合并后的段。升级前切的老段体积未知（0），先补算再分层。
const COMPACT_FANOUT: usize = 4;
const COMPACT_BASE: u64 = 16 * 1024;
const COMPACT_FULL: u64 = segment::SEGMENT_TARGET_BYTES / 2;

fn compact_tier(bytes: u64) -> u32 {
    let mut t = 0;
    let mut floor = COMPACT_BASE;
    while bytes >= floor {
        t += 1;
        floor = floor.saturating_mul(COMPACT_FANOUT as u64);
    }
    t
}

/// 一组相邻的段（seq 首尾相接）与它们的体积之和。
pub(super) struct CompactGroup {
    pub(super) segs: Vec<(u64, u64)>,
    bytes: u64,
}

/// 只看体积定出要合并的组（每组 ≥ 2 个相邻段），不读操作。
pub(super) fn compaction_plan(segs: &[(u64, u64, u64)]) -> Vec<CompactGroup> {
    fn flush(stack: &mut Vec<CompactGroup>, merges: &mut Vec<CompactGroup>) {
        merges.extend(stack.drain(..).filter(|g| g.segs.len() > 1));
    }
    let mut merges = Vec::new();
    let mut stack: Vec<CompactGroup> = Vec::new();
    for &(a, b, bytes) in segs {
        if bytes >= COMPACT_FULL {
            flush(&mut stack, &mut merges);
            continue;
        }
        stack.push(CompactGroup { segs: vec![(a, b)], bytes });
        while stack.len() >= COMPACT_FANOUT {
            let n = stack.len();
            let t = compact_tier(stack[n - 1].bytes);
            if !stack[n - COMPACT_FANOUT..].iter().all(|g| compact_tier(g.bytes) == t) {
                break;
            }
            let mut merged = CompactGroup { segs: Vec::new(), bytes: 0 };
            for g in stack.drain(n - COMPACT_FANOUT..) {
                merged.segs.extend(g.segs);
                merged.bytes += g.bytes;
            }
            if merged.bytes >= COMPACT_FULL {
                merges.push(merged);
                flush(&mut stack, &mut merges);
                break;
            }
            stack.push(merged);
        }
    }
    flush(&mut stack, &mut merges);
    merges
}

fn compact_segments(conn: &Connection, local: &Local) -> Result<(), String> {
    let mut segs = segments_of(conn, local)?;
    // 升级前切的老段：补算体积（一次性；之后的段切的时候就记下了）。
    for s in segs.iter_mut().filter(|s| s.2 == 0) {
        let est: u64 = split_seq_range(conn, local, s.0, s.1)?.iter().map(|x| x.2).sum();
        s.2 = est.max(1);
        conn.execute(
            "UPDATE sync2_segments SET bytes = ?4 WHERE profile_uid = ?1 AND device = ?2 AND first = ?3",
            params![local.profile, local.device.0.to_vec(), s.0 as i64, s.2 as i64],
        )
        .map_err(sql)?;
    }
    let locations: Vec<(String, u64)> = conn
        .prepare_cached("SELECT location, uploaded FROM sync2_locations WHERE profile_uid = ?1")
        .map_err(sql)?
        .query_map([&local.profile], |r| Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)? as u64)))
        .map_err(sql)?
        .collect::<Result<_, _>>()
        .map_err(sql)?;
    for group in compaction_plan(&segs) {
        let (first, last) = (group.segs[0].0, group.segs[group.segs.len() - 1].1);
        let merged = split_seq_range(conn, local, first, last)?;
        if merged.len() >= group.segs.len() {
            continue;
        }
        for (a, b) in &group.segs {
            let tag = segment::chain_tag(&chain_at(conn, &local.profile, &local.device, *b)?.ok_or("missing chain")?);
            let name = format!("devices/{}/{}", local.device.text(), segment::segment_file_name(*a, *b, &tag));
            for (loc, uploaded) in &locations {
                if *uploaded >= *b {
                    conn.prepare_cached(
                        "INSERT OR IGNORE INTO sync2_obsolete (profile_uid, location, name, last) VALUES (?1, ?2, ?3, ?4)",
                    )
                    .map_err(sql)?
                    .execute(params![local.profile, loc, name, *b as i64])
                    .map_err(sql)?;
                }
            }
        }
        conn.execute(
            "DELETE FROM sync2_segments WHERE profile_uid = ?1 AND device = ?2 AND first >= ?3 AND last <= ?4",
            params![local.profile, local.device.0.to_vec(), first as i64, last as i64],
        )
        .map_err(sql)?;
        for (a, b, bytes) in &merged {
            conn.execute(
                "INSERT INTO sync2_segments (profile_uid, device, first, last, bytes) VALUES (?1, ?2, ?3, ?4, ?5)",
                params![local.profile, local.device.0.to_vec(), *a as i64, *b as i64, *bytes as i64],
            )
            .map_err(sql)?;
            for (loc, uploaded) in &locations {
                if *uploaded >= *a {
                    conn.prepare_cached("INSERT OR IGNORE INTO sync2_rewrites (profile_uid, location, first) VALUES (?1, ?2, ?3)")
                        .map_err(sql)?
                        .execute(params![local.profile, loc, *a as i64])
                        .map_err(sql)?;
                }
            }
        }
    }
    Ok(())
}

/// [location] 上可以删的旧小段：新 head 已写出（调用方在写 head 之后取），且所有活跃的其它设备（没冻结、
/// 不是本机）在 head 里 ack 本机的进度都越过了它。取出即从待删表里移除。
fn take_obsolete(conn: &Connection, local: &Local, location: &str) -> Result<Vec<String>, String> {
    let mut floor = u64::MAX;
    let mut stmt = conn
        .prepare_cached("SELECT ack FROM sync2_devices WHERE profile_uid = ?1 AND device != ?2 AND frozen = 0")
        .map_err(sql)?;
    let mut q = stmt.query(params![local.profile, local.device.0.to_vec()]).map_err(sql)?;
    while let Some(r) = q.next().map_err(sql)? {
        let acked = match r.get::<_, Option<Vec<u8>>>(0).map_err(sql)? {
            Some(b) => Vv::read(&mut Reader::new(&b)).map(|v| v.get(&local.device)).unwrap_or(0),
            None => 0,
        };
        floor = floor.min(acked);
    }
    let names: Vec<String> = conn
        .prepare_cached("SELECT name FROM sync2_obsolete WHERE profile_uid = ?1 AND location = ?2 AND last <= ?3")
        .map_err(sql)?
        .query_map(params![local.profile, location, floor.min(i64::MAX as u64) as i64], |r| r.get(0))
        .map_err(sql)?
        .collect::<Result<_, _>>()
        .map_err(sql)?;
    conn.execute(
        "DELETE FROM sync2_obsolete WHERE profile_uid = ?1 AND location = ?2 AND last <= ?3",
        params![local.profile, location, floor.min(i64::MAX as u64) as i64],
    )
    .map_err(sql)?;
    Ok(names)
}

fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

/// 状态摘要（设计 §4.5）：派生状态按 ID 首字节分 16 桶，桶内按 ID 排序后 BLAKE3，再对 16 个桶哈希求根。
/// 输入只取各设备逐位相同的东西（投影行 JSON 由操作确定性生成，日志的 `res` 是确定性重放的结果）。
pub(crate) fn digest(conn: &Connection, profile: &str) -> Result<String, String> {
    let mut buckets: Vec<blake3::Hasher> = (0..16).map(|_| blake3::Hasher::new()).collect();
    for (sql_text, tag) in [
        ("SELECT id, kind || payload_json FROM srs_entities WHERE profile_uid = ?1 ORDER BY id", b'e'),
        ("SELECT id, json FROM srs_field_edits WHERE profile_uid = ?1 ORDER BY id", b'f'),
        ("SELECT id, json FROM srs_review_logs WHERE profile_uid = ?1 ORDER BY id", b'l'),
    ] {
        let mut stmt = conn.prepare(sql_text).map_err(sql)?;
        let mut q = stmt.query([profile]).map_err(sql)?;
        while let Some(r) = q.next().map_err(sql)? {
            let id: String = r.get(0).map_err(sql)?;
            let body: String = r.get(1).map_err(sql)?;
            let b = id.as_bytes().first().map_or(0, |c| (*c as usize) % 16);
            let h = &mut buckets[b];
            h.update(&[tag]);
            h.update(&(id.len() as u64).to_le_bytes());
            h.update(id.as_bytes());
            h.update(&(body.len() as u64).to_le_bytes());
            h.update(body.as_bytes());
        }
    }
    let mut root = blake3::Hasher::new();
    for h in buckets {
        root.update(h.finalize().as_bytes());
    }
    Ok(root.finalize().to_hex().to_string())
}

/// 校验一份 head 的设备公钥：认识的设备必须是同一把钥匙（防注入，设计 §9）；第一次见到的设备记下
/// （信任首次使用；界面的设备管理可以把它标为不可信 = 冻结）。返回 false = 拒绝这份 head。
fn trust_head(conn: &Connection, profile: &str, h: &Head) -> Result<bool, String> {
    let known: Option<(Option<Vec<u8>>, i64)> = conn
        .prepare_cached("SELECT public, frozen FROM sync2_devices WHERE profile_uid = ?1 AND device = ?2")
        .map_err(sql)?
        .query_row(params![profile, h.device.0.to_vec()], |r| Ok((r.get(0)?, r.get(1)?)))
        .optional()
        .map_err(sql)?;
    match known {
        Some((Some(p), _)) if p != h.public.to_vec() => Ok(false),
        Some((None, _)) => {
            conn.execute(
                "UPDATE sync2_devices SET public = ?3 WHERE profile_uid = ?1 AND device = ?2",
                params![profile, h.device.0.to_vec(), h.public.to_vec()],
            )
            .map_err(sql)?;
            Ok(true)
        }
        Some(_) => Ok(true),
        None => {
            conn.execute(
                "INSERT INTO sync2_devices (profile_uid, device, public, applied) VALUES (?1, ?2, ?3, 0)",
                params![profile, h.device.0.to_vec(), h.public.to_vec()],
            )
            .map_err(sql)?;
            Ok(true)
        }
    }
}

fn record_head(conn: &Connection, profile: &str, h: &Head) -> Result<(), String> {
    conn.execute(
        "UPDATE sync2_devices SET head_gen = ?3, head_seq = ?4, head_at = ?5, ack = ?6, digest = ?7, name = ?8 \
         WHERE profile_uid = ?1 AND device = ?2 AND head_gen <= ?3",
        params![profile, h.device.0.to_vec(), h.gen as i64, h.seq as i64, h.at_ms, h.ack.encode(), h.digest, h.name],
    )
    .map_err(sql)?;
    Ok(())
}

/// 一条等着投递的远端操作：本轮刚收的（已解码），或在缓冲表里的（内存里只有链值，轮到它才从表里读出解码）。
struct Held {
    op: Option<Op>,
    chain: Chain,
    /// 已在 `sync2_pending` 里：投递 / 丢弃时要删那一行；没在的投递不了才写进去。
    stored: bool,
}

/// 一条操作在投递队列里占的内存估计（与切段 / 收段分块同口径）。
fn held_bytes(op: &Op) -> usize {
    op.payload.len() + 24
}

impl Held {
    fn op(&mut self, c: &Connection, profile: &str, device: &Id, seq: u64) -> Result<&Op, String> {
        if self.op.is_none() {
            let raw: Vec<u8> = c
                .prepare_cached("SELECT op FROM sync2_pending WHERE profile_uid = ?1 AND device = ?2 AND seq = ?3")
                .map_err(sql)?
                .query_row(params![profile, device.0.to_vec(), seq as i64], |r| r.get(0))
                .map_err(sql)?;
            self.op = Some(Op::read(&mut Reader::new(&raw)).map_err(|e| e.to_string())?);
        }
        Ok(self.op.as_ref().expect("decoded"))
    }
}

/// 投递队列里没进缓冲表的操作（本轮刚收、还投不上）在内存里最多攒这么多字节，超了就写进缓冲表、内存里只留链值。
/// 新设备先收到某台设备、它依赖的另一台设备的段还没到（或在同一批后面）时，等着的操作可以是整个积压。
#[cfg(not(test))]
const DELIVERY_HELD_BYTES: usize = 16 * 1024 * 1024;
/// 测试里压到很小：全部端到端用例都会反复走「写进缓冲表、轮到时再读出」这条路，结果必须与全在内存里一样。
#[cfg(test)]
const DELIVERY_HELD_BYTES: usize = 2 * 1024;

fn mark_fork(c: &Connection, profile: &str, device: &Id) -> Result<(), String> {
    c.prepare_cached("UPDATE sync2_devices SET warning = 'fork' WHERE profile_uid = ?1 AND device = ?2")
        .map_err(sql)?
        .execute(params![profile, device.0.to_vec()])
        .map_err(sql)?;
    Ok(())
}

fn unstore(c: &Connection, profile: &str, device: &Id, seq: u64) -> Result<(), String> {
    c.prepare_cached("DELETE FROM sync2_pending WHERE profile_uid = ?1 AND device = ?2 AND seq = ?3")
        .map_err(sql)?
        .execute(params![profile, device.0.to_vec(), seq as i64])
        .map_err(sql)?;
    Ok(())
}

/// 因果投递：缓冲表里留着的 + 本轮刚收的远端操作（`(操作, 链值)`，任意顺序、可重复），按设备排成队，能接上的
/// （seq = applied + 1、链接得上、依赖都已应用）就应用，直到哪个队首都动不了。投递不了的写进缓冲等下一轮。
///
/// 在内存里按设备排队：每一遍只看各设备的队首，整体是 O(操作数 + 遍数 × 设备数)。（逐遍重扫整张缓冲表在
/// 新设备追赶两台互相同步过上千次的设备时是平方级的。）
///
/// 一次收段调用里只开一个：缓冲表只读一次，每投一段就 [Delivery::push] + [Delivery::drain]，投上的操作当场
/// 释放，[Delivery::finish] 最后一次写设备进度、把没投上的写进缓冲。所以收段的内存是「锁外预处理留下的操作
/// （有上限 [PREPARED_RAW_BUDGET]）+ 等依赖的操作」，不随一批的解压后体积增长；结果与整批一起投相同（等价于
/// 每批只收一段，Dart 侧本来就按任意段边界切批）。
struct Delivery {
    vv: Vv,
    queues: BTreeMap<Id, BTreeMap<u64, Held>>,
    chains: BTreeMap<Id, Chain>,
    /// 本次调用里判定分叉的设备：它这一支后面再来的操作也不收（与整批投递时 `q.clear()` 一并清掉相同）。
    forked: BTreeSet<Id>,
    applied: usize,
    /// 队列里已解码操作的内存估计（[held_bytes] 之和）。
    held: usize,
}

impl Delivery {
    /// 缓冲表只读 (设备, seq, 链值)：操作正文轮到它投递时才按主键读出（[Held::op]），缓冲表再大也不整张进内存。
    fn load(c: &Connection, profile: &str) -> Result<Delivery, String> {
        let vv = applied_vv(c, profile)?;
        let mut queues: BTreeMap<Id, BTreeMap<u64, Held>> = BTreeMap::new();
        let mut stmt = c.prepare_cached("SELECT device, seq, chain FROM sync2_pending WHERE profile_uid = ?1").map_err(sql)?;
        let mut q = stmt.query([profile]).map_err(sql)?;
        while let Some(r) = q.next().map_err(sql)? {
            let device = Id(r.get::<_, Vec<u8>>(0).map_err(sql)?.try_into().map_err(|_| "bad device")?);
            let seq = r.get::<_, i64>(1).map_err(sql)? as u64;
            let chain: Chain = r.get::<_, Vec<u8>>(2).map_err(sql)?.try_into().map_err(|_| "bad chain")?;
            queues.entry(device).or_default().insert(seq, Held { op: None, chain, stored: true });
        }
        Ok(Delivery { vv, queues, chains: BTreeMap::new(), forked: BTreeSet::new(), applied: 0, held: 0 })
    }

    fn push(&mut self, incoming: impl IntoIterator<Item = (Op, Chain)>) {
        for (op, chain) in incoming {
            if self.forked.contains(&op.id.device) {
                continue;
            }
            // 缓冲表里已有同一 (设备, seq) 的以它为准（与原先 INSERT OR IGNORE 一样）。
            if let std::collections::btree_map::Entry::Vacant(v) =
                self.queues.entry(op.id.device).or_default().entry(op.id.seq)
            {
                self.held += held_bytes(&op);
                v.insert(Held { op: Some(op), chain, stored: false });
            }
        }
    }

    /// 投完能投的；还在等的操作超过 [DELIVERY_HELD_BYTES] 就写进缓冲表、内存里只留链值。
    fn drain(&mut self, c: &Connection, profile: &str, now: i64, t: &mut Touched) -> Result<(), String> {
        self.deliver_ready(c, profile, now, t)?;
        if self.held > DELIVERY_HELD_BYTES {
            self.spill(c, profile)?;
        }
        Ok(())
    }

    fn spill(&mut self, c: &Connection, profile: &str) -> Result<(), String> {
        for (device, q) in self.queues.iter_mut() {
            for (seq, held) in q.iter_mut() {
                let Some(op) = held.op.take() else { continue };
                if !held.stored {
                    store_pending(c, profile, device, *seq, &op, &held.chain)?;
                    held.stored = true;
                }
            }
        }
        self.held = 0;
        Ok(())
    }

    fn deliver_ready(&mut self, c: &Connection, profile: &str, now: i64, t: &mut Touched) -> Result<(), String> {
        let Delivery { vv, queues, chains, applied, forked, held: mem } = self;
        let mut dropped: Vec<Id> = Vec::new();
        loop {
            let mut progress = false;
            for (device, q) in queues.iter_mut() {
                while let Some(mut entry) = q.first_entry() {
                    let seq = *entry.key();
                    let have = vv.get(device);
                    if seq <= have {
                        // 已有：同一 seq 链值不同 = 那台设备的身份分叉了（它自己会换身份重签发）。
                        let held = entry.remove();
                        *mem -= held.op.as_ref().map_or(0, held_bytes);
                        if chain_at(c, profile, device, seq)? != Some(held.chain) {
                            mark_fork(c, profile, device)?;
                        }
                        if held.stored {
                            unstore(c, profile, device, seq)?;
                        }
                        continue;
                    }
                    if seq != have + 1 {
                        break;
                    }
                    let prev = match chains.get(device) {
                        Some(p) => *p,
                        None => chain_at(c, profile, device, seq - 1)?.unwrap_or(CHAIN_ZERO),
                    };
                    let held = entry.get_mut();
                    let chain = held.chain;
                    if held.op.is_none() {
                        *mem += held_bytes(held.op(c, profile, device, seq)?);
                    }
                    let op = held.op.as_ref().expect("loaded");
                    if chain_next(&prev, op) != chain {
                        // 接不上本机已有的前缀：那台设备分叉过，这一支不收。
                        mark_fork(c, profile, device)?;
                        c.execute(
                            "DELETE FROM sync2_pending WHERE profile_uid = ?1 AND device = ?2 AND seq >= ?3",
                            params![profile, device.0.to_vec(), seq as i64],
                        )
                        .map_err(sql)?;
                        *mem -= q.values().filter_map(|h| h.op.as_ref()).map(held_bytes).sum::<usize>();
                        q.clear();
                        dropped.push(*device);
                        break;
                    }
                    if !op.deps.le(&vv) {
                        break;
                    }
                    insert_op(c, profile, op, &chain, now)?;
                    project(c, profile, op, now, true, t)?;
                    if held.stored {
                        unstore(c, profile, device, seq)?;
                    }
                    *mem -= held_bytes(op);
                    entry.remove();
                    vv.set(*device, seq);
                    chains.insert(*device, chain);
                    *applied += 1;
                    progress = true;
                }
            }
            if !progress {
                break;
            }
        }
        forked.extend(dropped);
        Ok(())
    }

    /// 设备进度一次写；没投上的写进缓冲。返回应用条数。
    fn finish(self, c: &Connection, profile: &str) -> Result<usize, String> {
        for (device, chain) in &self.chains {
            c.prepare_cached("UPDATE sync2_devices SET applied = ?3, chain = ?4 WHERE profile_uid = ?1 AND device = ?2")
                .map_err(sql)?
                .execute(params![profile, device.0.to_vec(), self.vv.get(device) as i64, chain.to_vec()])
                .map_err(sql)?;
        }
        for (device, q) in &self.queues {
            for (seq, held) in q.iter().filter(|(_, h)| !h.stored) {
                let op = held.op.as_ref().ok_or("unstored pending op without body")?;
                store_pending(c, profile, device, *seq, op, &held.chain)?;
            }
        }
        Ok(self.applied)
    }
}

fn store_pending(c: &Connection, profile: &str, device: &Id, seq: u64, op: &Op, chain: &Chain) -> Result<(), String> {
    c.prepare_cached("INSERT OR IGNORE INTO sync2_pending (profile_uid, device, seq, op, chain) VALUES (?1, ?2, ?3, ?4, ?5)")
        .map_err(sql)?
        .execute(params![profile, device.0.to_vec(), seq as i64, op.encode(), chain.to_vec()])
        .map_err(sql)?;
    Ok(())
}

/// 分批收段会话（[SrsCore::sync2_ingest_begin]）：开会话时的本机身份、跨批累积的分叉点，以及锁外预处理好、
/// 等投递的那一批（[SrsCore::sync2_ingest_prepare] 放进来，[SrsCore::sync2_ingest_commit] 取走）。
pub(crate) struct IngestSession {
    profile: String,
    device: Id,
    fork_at: Option<u64>,
    prepared: Option<PreparedIngest<'static>>,
}

impl IngestSession {
    /// 这个会话收的是不是 [profile] 的段（删 profile 时作废它，store/profile_data.rs）。
    pub(crate) fn belongs_to(&self, profile: &str) -> bool {
        self.profile == profile
    }
}

/// 一批段在锁外预处理时保留的已解码操作上限（解压后字节，按 [held_bytes] 同一口径估）。超出的段照样验签、
/// 重算链，只是不留操作，投递时在锁内重开再流式解一遍。一批的字节预算按压缩后体积算，正文重复度高时解开能大
/// 两个数量级；有了这条，预处理的内存峰值与收段原先一样不随一批的解压后体积增长。
const PREPARED_RAW_BUDGET: u64 = 2 * segment::SEGMENT_MAX_RAW_BYTES;

/// 一个段在锁外预处理的结论。
enum Outcome {
    /// 预处理时这台设备没有登记公钥。
    Unknown,
    /// 验签 / 解密 / 链校验没过：报错原文（带设备前缀）。
    Bad(String),
    /// 链已对上的全部操作与各自的链值，按 seq 升序。
    Ops(Vec<(Op, Chain)>),
    /// 校验已过、操作没留（超大旧段或超出 [PREPARED_RAW_BUDGET]）：投递时重开流式解。
    Deferred,
}

struct PreparedSegment {
    header: segment::SegmentHeader,
    /// 在 [PreparedIngest::segments] 里的下标。
    index: usize,
    /// 预处理时用的公钥（本机身份的段是本机公钥）；None = 没登记。投递时在锁内与当时的对照，变了就按当时的重验。
    public: Option<[u8; 32]>,
    outcome: Outcome,
}

/// 锁外预处理好的一批段（[prepare_ingest] → [PreparedIngest::verify] → 锁内 [deliver_prepared]）：解压、解密、
/// 验签、重算链这些纯 CPU 的活都在这里做完，锁内只剩比链、因果投递、落库与重放。
pub(crate) struct PreparedIngest<'a> {
    profile: String,
    /// 预处理时的本机身份；锁内对不上（身份换过）就按当时的身份整批重做。
    device: Id,
    local_public: [u8; 32],
    collection: Id,
    key: Option<[u8; 32]>,
    /// 一次收完时借调用方的；会话里留到投递，是自己的一份。
    segments: std::borrow::Cow<'a, [Vec<u8>]>,
    /// 段头都读不出的报错（按输入顺序，排在各段的报错之前，与逐段处理时相同）。
    peek_errors: Vec<String>,
    /// 本集合的段，按（设备, 起始 seq）排好。
    items: Vec<PreparedSegment>,
}

/// 预处理的读库部分：读段头、排序、查各设备公钥（[c] 用读连接即可，查完就放）。
fn prepare_ingest<'a>(
    c: &Connection,
    profile: &str,
    local: &Local,
    segments: std::borrow::Cow<'a, [Vec<u8>]>,
    key: Option<[u8; 32]>,
) -> Result<PreparedIngest<'a>, String> {
    let mut peek_errors = Vec::new();
    let mut items: Vec<PreparedSegment> = Vec::with_capacity(segments.len());
    for (index, bytes) in segments.iter().enumerate() {
        match segment::peek_header(bytes) {
            Ok(h) if h.collection == local.collection => {
                items.push(PreparedSegment { header: h, index, public: None, outcome: Outcome::Unknown })
            }
            Ok(_) => {}
            Err(e) => peek_errors.push(e.to_string()),
        }
    }
    // 稳定排序：同一（设备, 起始 seq）的重复段保持输入顺序，与原先逐段处理相同。
    items.sort_by_key(|s| (s.header.device, s.header.first));
    let local_public = local.key.public();
    for item in &mut items {
        item.public = if item.header.device == local.device {
            Some(local_public)
        } else {
            device_public(c, profile, &item.header.device)?
        };
    }
    Ok(PreparedIngest {
        profile: profile.to_owned(),
        device: local.device,
        local_public,
        collection: local.collection,
        key,
        segments,
        peek_errors,
        items,
    })
}

/// 一台设备登记的公钥（没登记 / 格式不对 = None）。
fn device_public(c: &Connection, profile: &str, device: &Id) -> Result<Option<[u8; 32]>, String> {
    let public: Option<Vec<u8>> = c
        .query_row(
            "SELECT public FROM sync2_devices WHERE profile_uid = ?1 AND device = ?2",
            params![profile, device.0.to_vec()],
            |r| r.get(0),
        )
        .optional()
        .map_err(sql)?
        .flatten();
    Ok(public.and_then(|p| <[u8; 32]>::try_from(p).ok()))
}

/// 验一段：签名 → 解密 → 解压 → 解码 → 重算链。[budget] 是还能留的已解码字节，留下的从里面扣。
fn verify_segment(bytes: &[u8], header: &segment::SegmentHeader, public: Option<[u8; 32]>, key: Option<&CollectionKey>, budget: &mut u64) -> Outcome {
    let Some(public) = public else {
        return Outcome::Unknown;
    };
    let bad = |e: segment::SegmentError| Outcome::Bad(format!("{}: {e}", header.device.text()));
    let seg = match segment::open_verified(bytes, &public, key) {
        Ok(s) => s,
        Err(e) => return bad(e),
    };
    // 整段校验（签名已过，这里重算链）；超大旧段校验时不留操作，投递时再流式解一遍。
    let ops = match seg.verify() {
        Ok(segment::Verified::Whole(ops)) => ops,
        Ok(segment::Verified::Stream(_)) => return Outcome::Deferred,
        Err(e) => return bad(e),
    };
    let raw: u64 = ops.as_slice().iter().map(|op| held_bytes(op) as u64).sum();
    if raw > *budget {
        return Outcome::Deferred;
    }
    *budget -= raw;
    let mut chain = seg.header.prev_chain;
    Outcome::Ops(
        ops.map(|op| {
            chain = chain_next(&chain, &op);
            (op, chain)
        })
        .collect(),
    )
}

impl PreparedIngest<'_> {
    /// 预处理的纯计算部分（不碰库、不持任何锁）：逐段验签、解密、解压、重算链。
    fn verify(&mut self) {
        let ck = self.key.map(CollectionKey);
        let mut budget = PREPARED_RAW_BUDGET;
        for item in &mut self.items {
            item.outcome = verify_segment(&self.segments[item.index], &item.header, item.public, ck.as_ref(), &mut budget);
        }
    }
}

/// 预处理 + 投递一次做完（[c] 已持写锁）：只给身份在预处理之后变了的整批重做用。
#[allow(clippy::too_many_arguments)]
fn ingest_under_lock(
    c: &Connection,
    profile: &str,
    local: &Local,
    segments: std::borrow::Cow<'_, [Vec<u8>]>,
    key: Option<[u8; 32]>,
    now: i64,
    t: &mut Touched,
    errors: &mut Vec<String>,
    fork_at: &mut Option<u64>,
) -> Result<usize, String> {
    let mut p = prepare_ingest(c, profile, local, segments, key)?;
    p.verify();
    deliver_prepared(c, profile, local, p, now, t, errors, fork_at)
}

/// 收一批预处理好的段（不换身份，[c] 已持写锁）：远端操作投递进投影 / 缓冲，返回应用条数；本机身份的段只比链，
/// 把分叉点（第一处不同的前一个 seq）取最小累积进 [fork_at]。结果与在锁内从头逐段处理逐字节相同：预处理之后
/// 本机身份变了就整批按当时的身份重做；某台设备的公钥变了（含新登记 / 不再登记）就按当时的公钥重验那一段。
///
/// 逐段投（[Delivery]），同时在内存里的只有预处理留下的操作与等依赖的操作。
#[allow(clippy::too_many_arguments)]
fn deliver_prepared(
    c: &Connection,
    profile: &str,
    local: &Local,
    prepared: PreparedIngest<'_>,
    now: i64,
    t: &mut Touched,
    errors: &mut Vec<String>,
    fork_at: &mut Option<u64>,
) -> Result<usize, String> {
    if prepared.profile != profile
        || prepared.device != local.device
        || prepared.local_public != local.key.public()
        || prepared.collection != local.collection
    {
        return ingest_under_lock(c, profile, local, prepared.segments, prepared.key, now, t, errors, fork_at);
    }
    let PreparedIngest { key, segments, peek_errors, items, .. } = prepared;
    let ck = key.map(CollectionKey);
    errors.extend(peek_errors);
    let mut delivery = Delivery::load(c, profile)?;
    for item in items {
        let header = item.header;
        let bytes = &segments[item.index];
        let public = if header.device == local.device { Some(local.key.public()) } else { device_public(c, profile, &header.device)? };
        let outcome = if public == item.public {
            item.outcome
        } else {
            verify_segment(bytes, &header, public, ck.as_ref(), &mut { u64::MAX })
        };
        let public = match outcome {
            Outcome::Unknown => {
                errors.push(format!("segment from unknown device {}", header.device.text()));
                continue;
            }
            Outcome::Bad(e) => {
                errors.push(e);
                continue;
            }
            Outcome::Ops(_) | Outcome::Deferred => public.ok_or("verified segment without a public key")?,
        };
        let stream_err = |e: segment::SegmentError| format!("{}: {e}", header.device.text());
        // 留下的操作，或（Deferred）重开流式解：签名、链在预处理里都已对上，这一遍与校验那一遍逐字节相同。
        let reopened;
        let mut ops: Box<dyn Iterator<Item = Result<(Op, Chain), String>> + '_> = match outcome {
            Outcome::Ops(ops) => Box::new(ops.into_iter().map(Ok)),
            _ => {
                reopened = segment::open_verified(bytes, &public, ck.as_ref()).map_err(stream_err)?;
                let mut chain = header.prev_chain;
                Box::new(reopened.ops().map_err(stream_err)?.map(move |op| {
                    let op = op.map_err(stream_err)?;
                    chain = chain_next(&chain, &op);
                    Ok((op, chain))
                }))
            }
        };
        if header.device == local.device {
            // 同一身份、签名也对（同一把钥匙 = 数据目录被复制）：逐条比链，第一处不同之前是共同前缀。
            for r in ops.by_ref() {
                let (op, chain) = r?;
                let ours = chain_at(c, profile, &local.device, op.id.seq)?;
                if ours != Some(chain) {
                    let k = op.id.seq - 1;
                    *fork_at = Some(fork_at.map_or(k, |f| f.min(k)));
                    break;
                }
            }
            continue;
        }
        // 按块投：一块投完（投上的当场释放）再取下一块，超大旧段也只占一块的内存。块边界与段边界一样任意，
        // 结果等价于逐段投递（Dart 本来就按任意段边界切批）。
        let mut chunk: Vec<(Op, Chain)> = Vec::new();
        let mut chunk_raw = 0usize;
        for r in ops {
            let (op, chain) = r?;
            chunk_raw += op.payload.len() + 24;
            chunk.push((op, chain));
            if chunk.len() >= DELIVERY_CHUNK_OPS || chunk_raw >= DELIVERY_CHUNK_RAW {
                delivery.push(std::mem::take(&mut chunk));
                chunk_raw = 0;
                delivery.drain(c, profile, now, t)?;
            }
        }
        delivery.push(chunk);
        delivery.drain(c, profile, now, t)?;
    }
    delivery.finish(c, profile)
}

/// 收段时一次投递的块（条数 / 解压后字节，先到者为准）：新切的段本来就不超过 [segment::SEGMENT_MAX_RAW_BYTES]，
/// 这两条只在读旧版本切出的超大段时起作用。
const DELIVERY_CHUNK_OPS: usize = 16_384;
const DELIVERY_CHUNK_RAW: usize = 4 * 1024 * 1024;

/// 收段命令的返回（重放受影响的卡、数缓冲）。
fn ingest_result(c: &Connection, profile: &str, t: Touched, applied: usize, errors: Vec<String>, fork: bool) -> Result<String, String> {
    let replayed = replay_touched(c, &t)?;
    let pending: i64 = c
        .query_row("SELECT COUNT(*) FROM sync2_pending WHERE profile_uid = ?1", [profile], |r| r.get(0))
        .map_err(sql)?;
    Ok(json!({
        "marks": t.marks.to_json(),
        "replayed": replayed,
        "applied": applied,
        "pending": pending,
        "errors": errors,
        "fork": fork,
        "diagnostics": t.diagnostics,
        "changed": t.entities_changed.iter().map(|(k, e)| json!([k, e])).collect::<Vec<_>>(),
        "purged": t.purged.iter().map(|(k, e)| json!([k, e])).collect::<Vec<_>>(),
    })
    .to_string())
}

// 本机身份分叉（设计 §7.3）：换新身份，把旧身份 seq > [keep] 的本机操作撤出投影、以新身份重签发
/// （内容不变），旧身份冻结在 [keep]（之后它的远端操作按普通设备收）。
pub(crate) fn rotate(conn: &Connection, profile: &str, keep: u64, now: i64, t: &mut Touched) -> Result<(), String> {
    let old = Local::load(conn, profile)?.ok_or("no sync2 identity")?;
    let top = old.next_seq - 1;
    let mut moved: Vec<Op> = Vec::new();
    for seq in keep + 1..=top {
        if let Some(op) = load_op(conn, profile, &OpId { device: old.device, seq })? {
            moved.push(op);
        }
    }
    // 撤出：ops 行、切段点、修改记录投影（日志与身份记录按内容 ID 去重，重签发后照旧在）。
    conn.execute(
        "DELETE FROM sync2_ops WHERE profile_uid = ?1 AND device = ?2 AND seq > ?3",
        params![profile, old.device.0.to_vec(), keep as i64],
    )
    .map_err(sql)?;
    conn.execute(
        "DELETE FROM sync2_segments WHERE profile_uid = ?1 AND device = ?2 AND last > ?3",
        params![profile, old.device.0.to_vec(), keep as i64],
    )
    .map_err(sql)?;
    let old_text = old.device.text();
    conn.execute(
        "DELETE FROM srs_field_edits WHERE profile_uid = ?1 AND writer_id = ?2 AND seq > ?3",
        params![profile, old_text, keep as i64],
    )
    .map_err(sql)?;
    conn.execute(
        "DELETE FROM sync2_edit_ops WHERE profile_uid = ?1 AND device = ?2 AND seq > ?3",
        params![profile, old.device.0.to_vec(), keep as i64],
    )
    .map_err(sql)?;
    conn.execute(
        "UPDATE sync2_devices SET applied = ?3, chain = ?4, frozen = 1 WHERE profile_uid = ?1 AND device = ?2",
        params![profile, old.device.0.to_vec(), keep as i64, chain_at(conn, profile, &old.device, keep)?.unwrap_or(CHAIN_ZERO).to_vec()],
    )
    .map_err(sql)?;
    // 各位置的上传进度记的是本机身份的 seq：新身份从 1 开始，进度归零（否则新段会被当成已传过）。
    conn.execute("UPDATE sync2_locations SET uploaded = 0 WHERE profile_uid = ?1", [profile]).map_err(sql)?;
    let migrated = old.migrated;
    let mut fresh = Local::create(conn, profile, now)?;
    fresh.clock.last = old.clock.last;
    if migrated {
        conn.execute("UPDATE sync2_self SET migrated_at = ?2 WHERE profile_uid = ?1", params![profile, now]).map_err(sql)?;
        fresh.migrated = true;
    }
    let mut applied = applied_vv(conn, profile)?;
    for op in moved {
        // 因果上下文：原来见过的其它设备照旧；旧身份 ≤ keep 的部分保留；旧身份 > keep 的前驱已重签发成新身份
        // 的更早 seq（新 op 的本设备分量隐含覆盖）。
        let mut deps = (*op.deps).clone();
        deps.set(old.device, (op.id.seq - 1).min(keep));
        for (d, s) in &applied.0 {
            if *d != fresh.device && *d != old.device && deps.get(d) > *s {
                deps.set(*d, *s);
            }
        }
        let seq = fresh.next_seq;
        let re = Op {
            id: OpId { device: fresh.device, seq },
            hlc: fresh.clock.tick(op.hlc.wall.max(now)),
            deps: Arc::new(deps),
            kind: op.kind,
            schema: op.schema,
            payload: op.payload.clone(),
            purged: op.purged,
        };
        let chain = chain_next(&fresh.chain, &re);
        insert_op(conn, profile, &re, &chain, now)?;
        fresh.chain = chain;
        fresh.next_seq += 1;
        applied.set(fresh.device, seq);
        // 日志的元数据挂到新 OpId 上。
        if let Ok(Body::Log(l)) = re.body() {
            conn.execute(
                "UPDATE sync2_log_meta SET device = ?2, seq = ?3 WHERE log_id = ?1",
                params![l.id.text(), fresh.device.0.to_vec(), seq as i64],
            )
            .map_err(sql)?;
        }
        project(conn, profile, &re, now, true, t)?;
    }
    fresh.save(conn)?;
    Ok(())
}

/// [SrsCore::sync2_head_if_changed] 的结果。
pub enum HeadWrite {
    /// 写了新 head：`(相对路径, 字节, 代号, 可删的旧小段)`。
    Written { path: String, bytes: Vec<u8>, gen: u64, obsolete: Vec<String> },
    /// 内容与上次写出的相同、还没到期：没写，[path] 是上次写出的那个 head。
    Unchanged { path: String },
}

/// 一批发件的字节预算（按段打包后的体积估计累计；一批至少一段，所以单段超预算时自成一批）。
///
/// 取值理由：与收段的 Dart 侧 `kSrsSync2IngestBudgetBytes` 同口径（8 MiB）。以前一次把 `uploaded` 之后的
/// **全部**段打包返回：积压几十万条操作时内核、FFI 拷贝与 Dart 各持一份整份积压，上传中途断一次下一轮整份
/// 重来（反馈 XDV7Mzc2gw / kB2ltk0u9F / U37Aku3oeL：同一台小米 43 万条操作反复补传、日志里有 OOM）。按批产出
/// 后，发件全过程的峰值只与本常量（+ 一段的解码操作）有关、与积压总量无关；单段上限 4 MiB
/// （[segment::SEGMENT_TARGET_BYTES]），所以一批至少两段满段。
pub const OUTBOX_BATCH_BYTES: u64 = 8 * 1024 * 1024;

/// 一批发件的段数上限：小段（老版本切的 64 KB 段、合并前的尾段、清除改写的重传）体积小但每个都是一次 PUT，
/// 只按字节限的话一批可能是上千个文件、一次中断要重传上千个请求。64 段与收段一批的在途数同量级，水位每
/// 64 个请求至少前进一次。
pub const OUTBOX_BATCH_SEGMENTS: usize = 64;

/// [SrsCore::sync2_outbox] 的一批。
pub struct OutboxBatch {
    /// 段文件（相对路径 → 字节），按 seq 升序。
    pub files: Vec<(String, Vec<u8>)>,
    /// 与 [files] 一一对应的 `(first, last)`：上传成功后原样交回 [SrsCore::sync2_outbox_ack]。
    pub segments: Vec<(u64, u64)>,
    /// 这一批确认后的水位（发到的最大 seq；没有新段时就是当前水位）。
    pub upto: u64,
    /// 预算到了、后面还有要发的段：确认这一批后再取下一批。
    pub more: bool,
}

/// [location] 上已确认上传到的水位：本机 seq ≤ 它的段都已在该位置上（head 写出时、或每批确认时前进）。
fn uploaded_of(c: &Connection, profile: &str, location: &str) -> Result<u64, String> {
    Ok(c.query_row(
        "SELECT uploaded FROM sync2_locations WHERE profile_uid = ?1 AND location = ?2",
        params![profile, location],
        |r| r.get::<_, i64>(0),
    )
    .optional()
    .map_err(sql)?
    .unwrap_or(0) as u64)
}

impl SrsCore {
    /// 发件（分批）：本设备还没上传到 [location] 的段，从已确认水位之后按 seq 升序，凑够 [max_bytes] 字节或
    /// [max_segments] 段就停（一批至少一段）。段切点在第一次发件时定下，各位置拿到同样的段；[key] = 该位置
    /// 开了加密时的集合密钥。调用方上传完这一批后调 [Self::sync2_outbox_ack] 持久化水位，`more` 为真就再取下一批：
    /// 中途断网 / 被杀只丢在途这一批，下一轮从水位接着发，不整份重来。分批对读者透明——读者只看 head，head
    /// 仍在全部段传完后才写（§6.1）。
    pub fn sync2_outbox(
        &self,
        profile: &str,
        location: &str,
        key: Option<[u8; 32]>,
        max_bytes: u64,
        max_segments: usize,
    ) -> Result<OutboxBatch, String> {
        let w = self.writer()?;
        in_savepoint(&w, |c| {
            let local = Local::load(c, profile)?.ok_or("sync2 not initialised for this profile")?;
            cut_segments(c, &local)?;
            compact_segments(c, &local)?;
            cut_segments(c, &local)?;
            let cuts = segments_of(c, &local)?;
            let uploaded = uploaded_of(c, profile, location)?;
            let ck = key.map(CollectionKey);
            let mut batch = OutboxBatch { files: Vec::new(), segments: Vec::new(), upto: uploaded, more: false };
            let mut bytes_total: u64 = 0;
            // 清除（§10.5）改写过的本机段：已经传过也要重传（同名覆盖；链值不变，名字不变）。
            let rewrites: BTreeSet<u64> = c
                .prepare_cached("SELECT first FROM sync2_rewrites WHERE profile_uid = ?1 AND location = ?2")
                .map_err(sql)?
                .query_map(params![profile, location], |r| Ok(r.get::<_, i64>(0)? as u64))
                .map_err(sql)?
                .collect::<Result<_, _>>()
                .map_err(sql)?;
            for (first, last, estimate) in cuts {
                if last <= uploaded && !rewrites.contains(&first) {
                    continue;
                }
                if !batch.files.is_empty() {
                    // 体积未知（0，不该出现：合并前已补算）按满段算，宁可这一批少带一段。
                    let est = if estimate == 0 { segment::SEGMENT_TARGET_BYTES } else { estimate };
                    if batch.files.len() >= max_segments || bytes_total.saturating_add(est) > max_bytes {
                        batch.more = true;
                        break;
                    }
                }
                let mut ops = Vec::with_capacity((last - first + 1) as usize);
                for seq in first..=last {
                    ops.push(load_op(c, profile, &OpId { device: local.device, seq })?.ok_or("missing local op")?);
                }
                let prev = chain_at(c, profile, &local.device, first - 1)?.ok_or("missing chain")?;
                let (h, bytes) = segment::pack(local.collection, &ops, prev, &local.key, ck.as_ref())?;
                drop(ops);
                bytes_total += bytes.len() as u64;
                batch.files.push((format!("devices/{}/{}", local.device.text(), h.file_name()), bytes));
                batch.segments.push((first, last));
                batch.upto = batch.upto.max(last);
            }
            Ok(batch)
        })
    }

    /// 确认一批发件已经全部写到 [location]：[segments] = 那一批的 `(first, last)`。清掉这些段的重传登记，并把
    /// 水位推进到「水位之后首尾相接、全部已确认」的最后一段（水位的含义不变：seq ≤ 它的本机段都在该位置上）。
    /// 返回 `(这一批的段是否仍是当前切法, 新水位)`；前者为假 = 发件与确认之间段被合并改切过（只会是别的位置的
    /// 发件并发跑了合并），没对上的段不算数、下一批照当前切法重发。
    pub fn sync2_outbox_ack(&self, profile: &str, location: &str, segments: &[(u64, u64)]) -> Result<(bool, u64), String> {
        let w = self.writer()?;
        in_savepoint(&w, |c| {
            let local = Local::load(c, profile)?.ok_or("sync2 not initialised for this profile")?;
            let current = segments_of(c, &local)?;
            let live: BTreeSet<(u64, u64)> = current.iter().map(|&(a, b, _)| (a, b)).collect();
            let acked: BTreeSet<(u64, u64)> = segments.iter().copied().filter(|s| live.contains(s)).collect();
            for (first, _) in &acked {
                c.prepare_cached("DELETE FROM sync2_rewrites WHERE profile_uid = ?1 AND location = ?2 AND first = ?3")
                    .map_err(sql)?
                    .execute(params![profile, location, *first as i64])
                    .map_err(sql)?;
            }
            let uploaded = uploaded_of(c, profile, location)?;
            let mut mark = uploaded;
            for &(a, b, _) in current.iter().filter(|s| s.1 > uploaded) {
                if !acked.contains(&(a, b)) {
                    break;
                }
                mark = b;
            }
            if mark > uploaded {
                c.execute(
                    "INSERT INTO sync2_locations (profile_uid, location, uploaded) VALUES (?1, ?2, ?3) \
                     ON CONFLICT(profile_uid, location) DO UPDATE SET uploaded = MAX(uploaded, excluded.uploaded)",
                    params![profile, location, mark as i64],
                )
                .map_err(sql)?;
            }
            Ok((acked.len() == segments.len(), mark))
        })
    }

    /// 写 head（段都传完之后）：[upto] = 已传到该位置的最大 seq。返回 `(相对路径, 字节, gen)`。
    pub fn sync2_head(&self, profile: &str, location: &str, upto: u64, now: i64) -> Result<(String, Vec<u8>, u64, Vec<String>), String> {
        match self.sync2_head_if_changed(profile, location, upto, now, None)? {
            HeadWrite::Written { path, bytes, gen, obsolete } => Ok((path, bytes, gen, obsolete)),
            HeadWrite::Unchanged { .. } => Err("sync2_head: unexpected unchanged".to_owned()),
        }
    }

    /// 同 [sync2_head]，但 [skip_unchanged_ms] 给了时：这个位置上一次写出的 head 内容（[Head::content_sig]：
    /// 发布的段、ack、摘要、名字）与现在相同、且写出不到这么久，就**不写**，返回上次那个 head 的路径。
    ///
    /// 每写一次 head 都会唤醒连着同一位置的全部设备（互联 host 的 `/api/srs/changes` 按 head 写入推进令牌，
    /// 写 head 的设备自己也连着它）：一轮什么都没变也写，每台设备就被自己 / 彼此的空 head 无限唤醒（反馈：iPhone
    /// 连着 Windows host 时复习同步一轮接一轮不停）。没变就不写，空转在下一轮停下。到了期限照写一次：别的设备
    /// 显示的「最后在线」（`seenAt`）与校时靠它刷新。上次写出的 head 文件此刻还在不在位置上由调用方核对，不在就
    /// 不带 [skip_unchanged_ms] 再调一次（上一轮写 head 之前断网 / 被别的设备清掉）。
    pub fn sync2_head_if_changed(
        &self,
        profile: &str,
        location: &str,
        upto: u64,
        now: i64,
        skip_unchanged_ms: Option<i64>,
    ) -> Result<HeadWrite, String> {
        let w = self.writer()?;
        in_savepoint(&w, |c| {
            let mut local = Local::load(c, profile)?.ok_or("sync2 not initialised for this profile")?;
            let mut cuts: Vec<(u64, u64, String)> = Vec::new();
            for (a, b) in cut_segments(c, &local)?.into_iter().filter(|(_, b)| *b <= upto) {
                let tag = segment::chain_tag(&chain_at(c, profile, &local.device, b)?.ok_or("missing chain")?);
                cuts.push((a, b, tag));
            }
            let seq = cuts.last().map_or(0, |x| x.1);
            let chain = chain_at(c, profile, &local.device, seq)?.ok_or("missing chain")?;
            let mut ack = applied_vv(c, profile)?;
            ack.set(local.device, 0);
            let digest: Option<String> = c
                .query_row("SELECT value FROM srs_meta WHERE key = ?1", [format!("sync2_digest/{profile}")], |r| r.get(0))
                .optional()
                .map_err(sql)?;
            let mut head = Head {
                gen: local.head_gen + 1,
                protocol: segment::PROTOCOL,
                min_reader: segment::MIN_READER,
                collection: local.collection,
                device: local.device,
                public: local.key.public(),
                seq,
                chain,
                segments: cuts,
                ack,
                digest: digest.unwrap_or_default(),
                at_ms: now,
                name: local.name.clone(),
            };
            let sig = head.content_sig();
            let sig_key = format!("sync2_head_sig/{profile}/{location}");
            // 清除改写过的段还等着这次 head 收账（下面删 sync2_rewrites）：照写，否则发件每轮都重传它们。
            let rewrites_pending: bool = c
                .query_row(
                    "SELECT EXISTS(SELECT 1 FROM sync2_rewrites WHERE profile_uid = ?1 AND location = ?2 AND first <= ?3)",
                    params![profile, location, seq as i64],
                    |r| r.get(0),
                )
                .map_err(sql)?;
            if let (Some(max_age), false) = (skip_unchanged_ms, rewrites_pending) {
                let last: Option<String> = c
                    .query_row("SELECT value FROM srs_meta WHERE key = ?1", [&sig_key], |r| r.get(0))
                    .optional()
                    .map_err(sql)?;
                // 值形如 `<内容签名>|<写出时刻>|<head 路径>`。
                if let Some(last) = last {
                    let mut parts = last.splitn(3, '|');
                    if let (Some(s), Some(at), Some(path)) = (parts.next(), parts.next(), parts.next()) {
                        let fresh = at.parse::<i64>().map_or(false, |at| now >= at && now - at < max_age);
                        if s == sig && fresh {
                            return Ok(HeadWrite::Unchanged { path: path.to_owned() });
                        }
                    }
                }
            }
            local.head_gen += 1;
            head.gen = local.head_gen;
            let bytes = head.encode(&local.key);
            let path = format!("devices/{}/{}", local.device.text(), head.file_name());
            c.execute(
                "INSERT INTO srs_meta (key, value) VALUES (?1, ?2) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                params![sig_key, format!("{sig}|{now}|{path}")],
            )
            .map_err(sql)?;
            local.save(c)?;
            c.execute(
                "DELETE FROM sync2_rewrites WHERE profile_uid = ?1 AND location = ?2 AND first <= ?3",
                params![profile, location, seq as i64],
            )
            .map_err(sql)?;
            c.execute(
                "INSERT INTO sync2_locations (profile_uid, location, uploaded, head_gen, last_ok) VALUES (?1, ?2, ?3, ?4, ?5) \
                 ON CONFLICT(profile_uid, location) DO UPDATE SET uploaded = MAX(uploaded, excluded.uploaded), \
                 head_gen = excluded.head_gen, last_ok = excluded.last_ok",
                params![profile, location, seq as i64, head.gen as i64, now],
            )
            .map_err(sql)?;
            // 新 head 已经不再引用合并掉的旧小段：可以删的（全部活跃设备都 ack 过了）一并交给 Dart 删。
            let obsolete = take_obsolete(c, &local, location)?;
            Ok(HeadWrite::Written { path, bytes, gen: head.gen, obsolete })
        })
    }

    /// 看 head：[heads] 是位置上各设备最新的 head 文件字节。返回要拉的段
    /// `{"fetch":[{"device","files":[相对路径]}], "fork": bool, "rejected":[设备], "devices":[...] }`。
    pub fn sync2_plan(&self, profile: &str, heads: &[Vec<u8>]) -> Result<Value, String> {
        let w = self.writer()?;
        in_savepoint(&w, |c| {
            let local = Local::load(c, profile)?.ok_or("sync2 not initialised for this profile")?;
            let mut fetch = Vec::new();
            let mut rejected = Vec::new();
            let mut fork = false;
            let mut best: BTreeMap<Id, Head> = BTreeMap::new();
            for bytes in heads {
                let Ok(h) = Head::decode(bytes) else { continue };
                if h.collection != local.collection {
                    continue;
                }
                if best.get(&h.device).is_none_or(|b| b.gen < h.gen) {
                    best.insert(h.device, h);
                }
            }
            for h in best.values() {
                if h.device == local.device {
                    // 自己的身份：远端比本机多，或同一 seq 上链值不同 = 有另一个安装在用同一个身份。
                    let ours = chain_at(c, profile, &local.device, h.seq)?;
                    if h.public != local.key.public() {
                        // 别的钥匙冒用本机身份：不是分叉，是注入，拒收。
                        rejected.push(h.device.text());
                        continue;
                    }
                    if h.seq > local.next_seq - 1 || ours != Some(h.chain) {
                        fork = true;
                        let files = h.segment_files().into_iter().map(|f| format!("devices/{}/{f}", h.device.text())).collect::<Vec<_>>();
                        fetch.push(json!({"device": h.device.text(), "files": files, "own": true}));
                    }
                    continue;
                }
                if !trust_head(c, profile, h)? {
                    rejected.push(h.device.text());
                    continue;
                }
                record_head(c, profile, h)?;
                let applied: u64 = c
                    .query_row(
                        "SELECT applied FROM sync2_devices WHERE profile_uid = ?1 AND device = ?2",
                        params![profile, h.device.0.to_vec()],
                        |r| r.get::<_, i64>(0),
                    )
                    .map_err(sql)? as u64;
                let pending: BTreeSet<u64> = c
                    .prepare_cached("SELECT seq FROM sync2_pending WHERE profile_uid = ?1 AND device = ?2")
                    .map_err(sql)?
                    .query_map(params![profile, h.device.0.to_vec()], |r| Ok(r.get::<_, i64>(0)? as u64))
                    .map_err(sql)?
                    .collect::<Result<_, _>>()
                    .map_err(sql)?;
                let files: Vec<String> = h
                    .segments
                    .iter()
                    .filter(|(a, b, _)| *b > applied && !(*a..=*b).all(|s| pending.contains(&s)))
                    .map(|(a, b, t)| format!("devices/{}/{}", h.device.text(), segment::segment_file_name(*a, *b, t)))
                    .collect();
                if !files.is_empty() {
                    fetch.push(json!({"device": h.device.text(), "files": files, "own": false}));
                }
            }
            Ok(json!({"fetch": fetch, "fork": fork, "rejected": rejected}))
        })
    }

    /// 收段：每项是一个段文件的字节（任意顺序、可重复）。校验（签名 / 链 / 解密）、按设备连续前缀 + 因果
    /// 满足才应用；不满足的进缓冲等下一轮。返回
    /// `{"marks":{..见 [super::Marks::to_json]}, "replayed":[..], "applied":n, "pending":n, "errors":[..], "fork":bool}`。
    ///
    /// 一次收完；同一轮要分几批收（字节预算）时用 [SrsCore::sync2_ingest_begin] / [SrsCore::sync2_ingest_batch] /
    /// [SrsCore::sync2_ingest_finish]，分叉判定与换身份和把全部批次拼成一次调用这里相同。解码与验签在写锁外
    /// （[SrsCore::sync2_ingest_prepare]），写锁里只投递。
    pub fn sync2_ingest(&self, profile: &str, segments: &[Vec<u8>], key: Option<[u8; 32]>, now: i64) -> Result<String, String> {
        let prepared = self.prepare_unlocked(profile, std::borrow::Cow::Borrowed(segments), key)?;
        let w = self.writer()?;
        in_savepoint(&w, |c| {
            let local = Local::load(c, profile)?.ok_or("sync2 not initialised for this profile")?;
            let mut t = Touched::default();
            let mut errors = Vec::new();
            let mut fork_at: Option<u64> = None;
            let applied_n = deliver_prepared(c, profile, &local, prepared, now, &mut t, &mut errors, &mut fork_at)?;
            if let Some(k) = fork_at {
                rotate(c, profile, k, now, &mut t)?;
            }
            ingest_result(c, profile, t, applied_n, errors, fork_at.is_some())
        })
    }

    /// 收段的锁外一半：读连接上取本机身份与各设备公钥（查完就放），再不持任何锁地验签、解密、解压、重算链。
    fn prepare_unlocked<'a>(
        &self,
        profile: &str,
        segments: std::borrow::Cow<'a, [Vec<u8>]>,
        key: Option<[u8; 32]>,
    ) -> Result<PreparedIngest<'a>, String> {
        let mut prepared = {
            let r = self.reader()?;
            let local = Local::load(&r, profile)?.ok_or("sync2 not initialised for this profile")?;
            prepare_ingest(&r, profile, &local, segments, key)?
        };
        #[cfg(test)]
        if let Some(hook) = self.ingest_prepare_hook.lock().map_err(|_| "hook poisoned")?.as_ref() {
            hook();
        }
        prepared.verify();
        Ok(prepared)
    }

    /// 开一个分批收段会话（覆盖掉上一轮没收尾的）。之后每批 [SrsCore::sync2_ingest_batch]（或拆开的
    /// [SrsCore::sync2_ingest_prepare] + [SrsCore::sync2_ingest_commit]），最后 [SrsCore::sync2_ingest_finish]。
    ///
    /// 为什么要会话：本机身份的段（数据目录被复制、另一个安装在用同一身份）只用来比链找分叉点，分叉点是**全部**
    /// 这类段里第一处不同的最小值；换身份（[rotate]）又要在**全部**远端操作都投递之后做（重签发的因果上下文按
    /// 那时已应用的版本向量截断）。两者都要看全一轮，所以分叉点跨批累积在这里（状态归内核），换身份推到收尾。
    pub fn sync2_ingest_begin(&self, profile: &str) -> Result<Value, String> {
        let w = self.writer()?;
        let local = Local::load(&w, profile)?.ok_or("sync2 not initialised for this profile")?;
        *self.ingest_session.lock().map_err(|_| "ingest session poisoned")? =
            Some(IngestSession { profile: profile.to_owned(), device: local.device, fork_at: None, prepared: None });
        Ok(json!({}))
    }

    /// 会话里收一批（[SrsCore::sync2_ingest_prepare] + [SrsCore::sync2_ingest_commit] 连着做）。
    pub fn sync2_ingest_batch(&self, profile: &str, segments: &[Vec<u8>], key: Option<[u8; 32]>, now: i64) -> Result<String, String> {
        self.sync2_ingest_prepare(profile, segments, key)?;
        self.sync2_ingest_commit(profile, now)
    }

    /// 会话里预处理一批：不持写锁（也不长持读锁）地解压、解密、验签、重算链，结果留在会话里等
    /// [SrsCore::sync2_ingest_commit]（覆盖上一批没投递的）。手机上一批要一两秒，这期间本机作答照常写入。
    /// 出错作废会话（与 [SrsCore::sync2_ingest_commit] 出错相同）。
    pub fn sync2_ingest_prepare(&self, profile: &str, segments: &[Vec<u8>], key: Option<[u8; 32]>) -> Result<Value, String> {
        let device = self.session_device(profile)?;
        let prepared = self.prepare_unlocked(profile, std::borrow::Cow::Owned(segments.to_vec()), key);
        let mut guard = self.ingest_session.lock().map_err(|_| "ingest session poisoned")?;
        // 预处理期间会话被换过（重开 / 删 profile）：这一批不属于现在的会话。
        if !guard.as_ref().is_some_and(|s| s.profile == profile && s.device == device) {
            return Err("sync2 ingest: no ingest session for this profile".to_owned());
        }
        match prepared {
            Ok(p) => {
                if let Some(s) = guard.as_mut() {
                    s.prepared = Some(p);
                }
                Ok(json!({}))
            }
            Err(e) => {
                *guard = None;
                Err(e)
            }
        }
    }

    /// 当前收段会话的本机身份（没有 [profile] 的会话报错）。
    fn session_device(&self, profile: &str) -> Result<Id, String> {
        match self.ingest_session.lock().map_err(|_| "ingest session poisoned")?.as_ref() {
            Some(s) if s.profile == profile => Ok(s.device),
            _ => Err("sync2 ingest: no ingest session for this profile".to_owned()),
        }
    }

    /// 会话里投递预处理好的那一批：远端设备的操作照常投递并提交；本机身份的段只比链、把分叉点累积进会话，不换身份
    /// （返回的 `fork` 恒为 false，换身份见 [SrsCore::sync2_ingest_finish]）。写锁里只剩比链、因果投递、落库、
    /// 重放；预处理之后某台设备的公钥变了，那一段按当时的公钥在锁内重验。会话期间本机身份变了（别处换过身份）
    /// 就作废会话并报错：之后的本机段已不能按同一身份比链。
    pub fn sync2_ingest_commit(&self, profile: &str, now: i64) -> Result<String, String> {
        let w = self.writer()?;
        let mut guard = self.ingest_session.lock().map_err(|_| "ingest session poisoned")?;
        let (device, prior, prepared) = match guard.as_mut() {
            Some(s) if s.profile == profile => match s.prepared.take() {
                Some(p) => (s.device, s.fork_at, p),
                None => return Err("sync2 ingest: no prepared batch to commit".to_owned()),
            },
            _ => return Err("sync2 ingest: no ingest session for this profile".to_owned()),
        };
        let out = in_savepoint(&w, |c| {
            let local = Local::load(c, profile)?.ok_or("sync2 not initialised for this profile")?;
            if local.device != device {
                return Err("sync2 ingest: local identity changed during the ingest session".to_owned());
            }
            let mut t = Touched::default();
            let mut errors = Vec::new();
            let mut fork_at = prior;
            let applied_n = deliver_prepared(c, profile, &local, prepared, now, &mut t, &mut errors, &mut fork_at)?;
            let r = ingest_result(c, profile, t, applied_n, errors, false)?;
            Ok((r, fork_at))
        });
        match out {
            Ok((r, fork_at)) => {
                if let Some(s) = guard.as_mut() {
                    s.fork_at = fork_at;
                }
                Ok(r)
            }
            Err(e) => {
                *guard = None;
                Err(e)
            }
        }
    }

    /// 收尾：会话里累积出分叉点就换身份（与一次收完时同一个分叉点、同样在全部投递之后）。返回与
    /// [SrsCore::sync2_ingest] 同形（`applied` 为 0：操作都在各批里投递过了）。会话期间本机身份变了：不换。
    pub fn sync2_ingest_finish(&self, profile: &str, now: i64) -> Result<String, String> {
        let w = self.writer()?;
        let session = {
            let mut guard = self.ingest_session.lock().map_err(|_| "ingest session poisoned")?;
            match guard.take() {
                Some(s) if s.profile == profile => s,
                _ => return Err("sync2 ingest: no ingest session for this profile".to_owned()),
            }
        };
        in_savepoint(&w, |c| {
            let local = Local::load(c, profile)?.ok_or("sync2 not initialised for this profile")?;
            let mut t = Touched::default();
            let fork_at = session.fork_at.filter(|_| local.device == session.device);
            if let Some(k) = fork_at {
                rotate(c, profile, k, now, &mut t)?;
            }
            ingest_result(c, profile, t, 0, Vec::new(), fork_at.is_some())
        })
    }

    /// 主动换身份（导入 `.fushisrs` / 从手动导出恢复 / 拷数据目录后，设计 §7.3 预防）：本机现有操作都保留在
    /// 旧身份下（冻结），之后用新身份写。
    pub fn sync2_rotate(&self, profile: &str, now: i64) -> Result<Value, String> {
        let w = self.writer()?;
        in_savepoint(&w, |c| {
            let l = Local::load(c, profile)?.ok_or("sync2 not initialised for this profile")?;
            let mut t = Touched::default();
            rotate(c, profile, l.next_seq - 1, now, &mut t)?;
            let n = Local::load(c, profile)?.ok_or("rotate failed")?;
            Ok(json!({"device": n.device.text(), "previous": l.device.text()}))
        })
    }

    /// 算并记下状态摘要（设计 §4.5；写 head 时带上）。返回 `{"digest", "vv"}`。
    pub fn sync2_digest(&self, profile: &str) -> Result<Value, String> {
        self.sync2_digest_due(profile, 0, None)
    }

    /// 算并记下状态摘要（写进 head，§4.5）。摘要是全库扫描（100 万次复习约数秒），所以：
    /// - 给了 [min_interval_ms]：版本向量没变、或离上次算不到这个间隔，就不算（返回 `{"skipped": true}`）；
    /// - 在一条**专用的扫描连接**（[SrsCore::scan_connection]，小页缓存、算完即关）的一个读事务里算（WAL 快照：
    ///   摘要与版本向量出自同一时刻；不占写锁，复习照常写）。一次性顺序扫描用不上页缓存，放在读连接上会把它
    ///   的 64 MB 页缓存填满、并一直占到关库。
    pub fn sync2_digest_due(&self, profile: &str, now: i64, min_interval_ms: Option<i64>) -> Result<Value, String> {
        let key = format!("sync2_digest/{profile}");
        let at_key = format!("sync2_digest_at/{profile}");
        if let Some(interval) = min_interval_ms {
            let r = self.reader()?;
            let vv = applied_vv(&r, profile)?;
            let prev: Option<String> =
                r.query_row("SELECT value FROM srs_meta WHERE key = ?1", [&key], |x| x.get(0)).optional().map_err(sql)?;
            let last_at: i64 = r
                .query_row("SELECT value FROM srs_meta WHERE key = ?1", [&at_key], |x| x.get::<_, String>(0))
                .optional()
                .map_err(sql)?
                .and_then(|v| v.parse().ok())
                .unwrap_or(0);
            let same_vv = prev.as_deref().and_then(|p| p.split_once('@')).is_some_and(|(_, v)| v == vv.hash_hex());
            if same_vv || now - last_at < interval {
                return Ok(json!({"skipped": true}));
            }
        }
        let (d, vv) = {
            let (_open, r) = self.scan_connection()?;
            r.execute_batch("BEGIN").map_err(sql)?;
            let out = (|| Ok::<_, String>((digest(&r, profile)?, applied_vv(&r, profile)?)))();
            r.execute_batch("COMMIT").map_err(sql)?;
            out?
        };
        let w = self.writer()?;
        in_savepoint(&w, |c| {
            for (k, v) in [(&key, format!("{}@{}", d, vv.hash_hex())), (&at_key, now.to_string())] {
                c.execute(
                    "INSERT INTO srs_meta (key, value) VALUES (?1, ?2) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                    params![k, v],
                )
                .map_err(sql)?;
            }
            Ok(json!({"digest": d, "vv": vv.hash_hex()}))
        })
    }

    /// 同步状态（设计 §10.6）：本机身份、每台设备的进度 / 落后条数 / 最后见到 / 摘要是否一致、缓冲条数。
    pub fn sync2_status(&self, profile: &str) -> Result<Value, String> {
        let r = self.reader()?;
        let local = Local::load(&r, profile)?;
        let Some(local) = local else { return Ok(json!({"enabled": false})) };
        let mine: Option<String> = r
            .query_row("SELECT value FROM srs_meta WHERE key = ?1", [format!("sync2_digest/{profile}")], |x| x.get(0))
            .optional()
            .map_err(sql)?;
        let mut devices = Vec::new();
        let mut stmt = r
            .prepare(
                "SELECT device, applied, head_seq, head_at, digest, name, frozen, warning FROM sync2_devices WHERE profile_uid = ?1",
            )
            .map_err(sql)?;
        let mut q = stmt.query([profile]).map_err(sql)?;
        while let Some(x) = q.next().map_err(sql)? {
            let dev: Vec<u8> = x.get(0).map_err(sql)?;
            let applied: i64 = x.get(1).map_err(sql)?;
            let head_seq: i64 = x.get(2).map_err(sql)?;
            let digest: Option<String> = x.get(4).map_err(sql)?;
            let same_vv_mismatch = match (&digest, &mine) {
                (Some(a), Some(b)) => {
                    let (da, va) = a.split_once('@').unwrap_or((a, ""));
                    let (db, vb) = b.split_once('@').unwrap_or((b, ""));
                    !va.is_empty() && va == vb && da != db
                }
                _ => false,
            };
            devices.push(json!({
                "device": hex_id(&dev),
                "self": dev == local.device.0.to_vec(),
                "applied": applied,
                "behind": (head_seq - applied).max(0),
                "seenAt": x.get::<_, Option<i64>>(3).map_err(sql)?,
                "name": x.get::<_, String>(5).map_err(sql)?,
                "frozen": x.get::<_, i64>(6).map_err(sql)? != 0,
                "warning": x.get::<_, Option<String>>(7).map_err(sql)?,
                "digestMismatch": same_vv_mismatch,
            }));
        }
        let pending: i64 = r
            .query_row("SELECT COUNT(*) FROM sync2_pending WHERE profile_uid = ?1", [profile], |x| x.get(0))
            .map_err(sql)?;
        let ops: i64 = r
            .query_row("SELECT COUNT(*) FROM sync2_ops WHERE profile_uid = ?1", [profile], |x| x.get(0))
            .map_err(sql)?;
        let locations: Vec<Value> = r
            .prepare("SELECT location, uploaded, head_gen, last_ok FROM sync2_locations WHERE profile_uid = ?1")
            .map_err(sql)?
            .query_map([profile], |x| {
                Ok(json!({"location": x.get::<_, String>(0)?, "uploaded": x.get::<_, i64>(1)?, "headGen": x.get::<_, i64>(2)?, "lastOk": x.get::<_, Option<i64>>(3)?}))
            })
            .map_err(sql)?
            .collect::<Result<_, _>>()
            .map_err(sql)?;
        Ok(json!({
            "enabled": true,
            "device": local.device.text(),
            "nextSeq": local.next_seq,
            "migrated": local.migrated,
            "ops": ops,
            "pending": pending,
            "unpublished": (local.next_seq - 1) as i64 - locations.iter().filter_map(|l| l["uploaded"].as_i64()).min().unwrap_or(0),
            "devices": devices,
            "locations": locations,
        }))
    }
}

fn hex_id(b: &[u8]) -> String {
    <[u8; 16]>::try_from(b).map(|a| Id(a).text()).unwrap_or_else(|_| hex(b))
}

/// `.fushisrs`（设计 §10.4）：一个集合的全部操作（每台设备从 seq 1 起的完整前缀 + 每条的链值）与各设备公钥，
/// zstd 压缩。媒体由 Dart 侧另打进同一个包。
const EXPORT_MAGIC: &[u8; 8] = b"FSRS2EXP";

/// 导出的明文按需生成：zstd 压缩器每读一块，就从库里按 seq 读出、编码下一批操作。明文不整份攒在内存里，
/// 内存是一个压缩块 + 一条操作。读库出错时记下、对压缩器报流结束，调用方压缩完再检查 [Self::error]。
struct ExportSource<'c> {
    c: &'c Connection,
    profile: &'c str,
    /// 还没开始的设备：`(设备, 公钥, 已应用到的 seq)`。
    devices: std::vec::IntoIter<(Id, Vec<u8>, u64)>,
    /// 正在导出的设备与下一条 seq、最后一条 seq。
    cur: Option<(Id, u64, u64)>,
    buf: Vec<u8>,
    pos: usize,
    error: Option<String>,
}

impl ExportSource<'_> {
    /// 补下一段明文；导完了返回 false。
    fn refill(&mut self) -> Result<bool, String> {
        self.buf.clear();
        self.pos = 0;
        let mut w = crate::sync2::codec::Writer { buf: std::mem::take(&mut self.buf) };
        loop {
            if let Some((device, next, top)) = self.cur.as_mut() {
                if *next <= *top {
                    let op = load_op(self.c, self.profile, &OpId { device: *device, seq: *next })?.ok_or("missing op in export")?;
                    w.bytes(&op.encode());
                    *next += 1;
                    break;
                }
                self.cur = None;
            }
            match self.devices.next() {
                Some((device, public, applied)) => {
                    device.write(&mut w);
                    w.bytes(&public);
                    w.uv(applied);
                    self.cur = Some((device, 1, applied));
                    if applied == 0 {
                        break;
                    }
                }
                None => break,
            }
        }
        self.buf = w.into_vec();
        Ok(!self.buf.is_empty())
    }
}

impl std::io::Read for ExportSource<'_> {
    fn read(&mut self, out: &mut [u8]) -> std::io::Result<usize> {
        if self.error.is_some() {
            return Ok(0);
        }
        while self.pos == self.buf.len() {
            match self.refill() {
                Ok(true) => {}
                Ok(false) => return Ok(0),
                Err(e) => {
                    self.error = Some(e);
                    return Ok(0);
                }
            }
        }
        let n = out.len().min(self.buf.len() - self.pos);
        out[..n].copy_from_slice(&self.buf[self.pos..self.pos + n]);
        self.pos += n;
        Ok(n)
    }
}

/// `.fushisrs` 的一项（按出现顺序）：一台设备的抬头，接着是它从 seq 1 起的 `count` 条操作。
enum ExportItem {
    Device { device: Id, public: Vec<u8>, count: u64 },
    Op(Op),
}

/// 流式读 `.fushisrs` 的操作部分（[ZstdWindow]），顺手校验每台设备的操作是从 1 起连续的。
struct ExportReader<'s> {
    window: ZstdWindow<'s>,
    collection: Id,
    devices_left: u64,
    /// 当前设备与下一条应有的 seq、最后一条 seq。
    cur: Option<(Id, u64, u64)>,
}

impl<'s> ExportReader<'s> {
    fn open(bytes: &'s [u8]) -> Result<ExportReader<'s>, String> {
        let mut window = ZstdWindow::new(bytes).map_err(|e| e.to_string())?;
        if window.parse(|r| r.raw(8).map(<[u8]>::to_vec)).map_err(|e| e.to_string())? != EXPORT_MAGIC {
            return Err("not a .fushisrs file".into());
        }
        if window.parse(|r| r.u8()).map_err(|e| e.to_string())? != 1 {
            return Err("unsupported .fushisrs version".into());
        }
        let collection = window.parse(Id::read).map_err(|e| e.to_string())?;
        let devices_left = window.parse(|r| r.uv()).map_err(|e| e.to_string())?;
        Ok(ExportReader { window, collection, devices_left, cur: None })
    }

    fn next_item(&mut self) -> Result<Option<ExportItem>, String> {
        if let Some((device, next, top)) = self.cur.as_mut() {
            if *next <= *top {
                let op = self
                    .window
                    .parse(|r| Op::read(&mut Reader::new(r.bytes()?)))
                    .map_err(|e| e.to_string())?;
                if op.id.device != *device || op.id.seq != *next {
                    return Err("corrupt .fushisrs (op order)".into());
                }
                *next += 1;
                return Ok(Some(ExportItem::Op(op)));
            }
            self.cur = None;
        }
        if self.devices_left == 0 {
            return Ok(None);
        }
        self.devices_left -= 1;
        let (device, public, count) = self
            .window
            .parse(|r| Ok((Id::read(r)?, r.bytes()?.to_vec(), r.uv()?)))
            .map_err(|e| e.to_string())?;
        self.cur = Some((device, 1, count));
        Ok(Some(ExportItem::Device { device, public, count }))
    }
}

impl SrsCore {
    /// 手动导出：全部操作（含已清除内容的骨架）+ 各设备公钥。明文边生成边压缩（[ExportSource]），内存只有
    /// 压缩后的结果与一个块，不再先攒一份整份明文。
    pub fn sync2_export(&self, profile: &str) -> Result<Vec<u8>, String> {
        let w = self.writer()?;
        in_savepoint(&w, |c| {
            let local = Local::load(c, profile)?.ok_or("sync2 not initialised for this profile")?;
            let mut head = crate::sync2::codec::Writer::new();
            head.raw(EXPORT_MAGIC);
            head.u8(1);
            local.collection.write(&mut head);
            let devices: Vec<(Vec<u8>, Option<Vec<u8>>, i64)> = c
                .prepare("SELECT device, public, applied FROM sync2_devices WHERE profile_uid = ?1 ORDER BY device")
                .map_err(sql)?
                .query_map([profile], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
                .map_err(sql)?
                .collect::<Result<_, _>>()
                .map_err(sql)?;
            head.uv(devices.len() as u64);
            let mut list = Vec::with_capacity(devices.len());
            for (dev, public, applied) in devices {
                let device = Id(dev.try_into().map_err(|_| "bad device")?);
                list.push((device, public.unwrap_or_default(), applied as u64));
            }
            let mut source = ExportSource {
                c,
                profile,
                devices: list.into_iter(),
                cur: None,
                buf: head.into_vec(),
                pos: 0,
                error: None,
            };
            let mut out = Vec::new();
            let mut compressor = ruzstd::encoding::FrameCompressor::new(ruzstd::encoding::CompressionLevel::Fastest);
            compressor.set_source(&mut source);
            compressor.set_drain(&mut out);
            compressor.compress();
            drop(compressor);
            match source.error {
                Some(e) => Err(e),
                None => Ok(out),
            }
        })
    }

    /// 导入 `.fushisrs`：操作并入（不覆盖）。包里有本机身份的操作时先换身份（§7.3：包可能来自本设备
    /// 更早的自己或它的克隆），共同前缀之后的本机操作以新身份重签发。返回与 ingest 同形的结果。
    ///
    /// 流式读两遍：第一遍校验整个包（格式、每台设备的 seq 连续）并找本机身份的共同前缀，什么都不改；第二遍
    /// 按块投递（[Delivery]，等依赖的超预算就落缓冲表）。包再大，内存也只有一个读窗口与一块操作——以前是整份
    /// 明文、全部操作、再拷一份待投递三份同时在内存。
    pub fn sync2_import(&self, profile: &str, bytes: &[u8], now: i64) -> Result<String, String> {
        let w = self.writer()?;
        in_savepoint(&w, |c| {
            let local = match Local::load(c, profile)? {
                Some(l) => l,
                None => Local::create(c, profile, now)?,
            };
            let mut reader = ExportReader::open(bytes)?;
            if reader.collection != local.collection {
                return Err("this .fushisrs belongs to another profile".into());
            }
            // 第一遍：校验、收集设备抬头、算本机身份与包的共同前缀 k。
            let mut runs: Vec<(Id, Vec<u8>)> = Vec::new();
            let mut own: Option<(u64, u64, bool, Chain)> = None; // (包里条数, k, 仍然对得上, 链)
            while let Some(item) = reader.next_item()? {
                match item {
                    ExportItem::Device { device, public, count } => {
                        if device == local.device {
                            own = Some((count, 0, true, CHAIN_ZERO));
                        }
                        runs.push((device, public));
                    }
                    ExportItem::Op(op) => {
                        if let Some((_, k, matching, chain)) = own.as_mut().filter(|_| op.id.device == local.device) {
                            if *matching {
                                *chain = chain_next(chain, &op);
                                if chain_at(c, profile, &local.device, op.id.seq)? == Some(*chain) {
                                    *k = op.id.seq;
                                } else {
                                    *matching = false;
                                }
                            }
                        }
                    }
                }
            }
            let mut t = Touched::default();
            // 包是本机更早的前缀（全部对得上）不用换；有分歧或包里更长（另一个安装接着写过）才换。
            if let Some((count, k, _, _)) = own {
                if k < count {
                    rotate(c, profile, k, now, &mut t)?;
                }
            }
            for (device, public) in &runs {
                c.execute(
                    "INSERT INTO sync2_devices (profile_uid, device, public, applied) VALUES (?1, ?2, ?3, 0) \
                     ON CONFLICT(profile_uid, device) DO UPDATE SET public = COALESCE(sync2_devices.public, excluded.public)",
                    params![profile, device.0.to_vec(), if public.is_empty() { None } else { Some(public.clone()) }],
                )
                .map_err(sql)?;
            }
            // 第二遍：按块投递。
            let mut delivery = Delivery::load(c, profile)?;
            let mut reader = ExportReader::open(bytes)?;
            let mut chain = CHAIN_ZERO;
            let mut chunk: Vec<(Op, Chain)> = Vec::new();
            let mut chunk_raw = 0usize;
            while let Some(item) = reader.next_item()? {
                match item {
                    ExportItem::Device { .. } => chain = CHAIN_ZERO,
                    ExportItem::Op(op) => {
                        chain = chain_next(&chain, &op);
                        chunk_raw += held_bytes(&op);
                        chunk.push((op, chain));
                        if chunk.len() >= DELIVERY_CHUNK_OPS || chunk_raw >= DELIVERY_CHUNK_RAW {
                            delivery.push(std::mem::take(&mut chunk));
                            chunk_raw = 0;
                            delivery.drain(c, profile, now, &mut t)?;
                        }
                    }
                }
            }
            delivery.push(chunk);
            delivery.drain(c, profile, now, &mut t)?;
            let applied = delivery.finish(c, profile)?;
            let replayed = replay_touched(c, &t)?;
            let pending: i64 = c
                .query_row("SELECT COUNT(*) FROM sync2_pending WHERE profile_uid = ?1", [profile], |r| r.get(0))
                .map_err(sql)?;
            Ok(json!({
                "marks": t.marks.to_json(),
                "replayed": replayed,
                "applied": applied,
                "pending": pending,
                "errors": [],
                "fork": false,
                "changed": t.entities_changed.iter().map(|(k, e)| json!([k, e])).collect::<Vec<_>>(),
                "purged": t.purged.iter().map(|(k, e)| json!([k, e])).collect::<Vec<_>>(),
            })
            .to_string())
        })
    }
}

#[cfg(test)]
mod compaction_tests {
    use super::*;

    /// 模拟本机几千轮同步：每轮切出一个小段，按 [compaction_plan] 合并（合并后的体积按真实压缩更小估一点）。
    /// 段数始终有界（满段之外每层不到几个），每字节一生被重写的次数是对数级。
    #[test]
    fn tiered_compaction_bounds_file_count_and_rewrites() {
        let mut segs: Vec<(u64, u64, u64)> = Vec::new();
        let (mut appended, mut rewritten, mut seq) = (0u64, 0u64, 0u64);
        let mut max_small = 0usize;
        for round in 0..5000u64 {
            let size = 200 + (round * 7919) % 3000;
            seq += 1 + round % 5;
            let first = segs.last().map_or(1, |s| s.1 + 1);
            segs.push((first, seq, size));
            appended += size;
            for g in compaction_plan(&segs) {
                let (a, b) = (g.segs[0].0, g.segs[g.segs.len() - 1].1);
                rewritten += g.bytes;
                let merged = g.bytes * 9 / 10;
                let i = segs.iter().position(|s| s.0 == a).unwrap();
                let j = segs.iter().position(|s| s.1 == b).unwrap();
                segs.splice(i..=j, [(a, b, merged)]);
            }
            // 首尾相接、覆盖 1..=seq。
            let mut next = 1;
            for s in &segs {
                assert_eq!(s.0, next);
                next = s.1 + 1;
            }
            assert_eq!(next, seq + 1);
            max_small = max_small.max(segs.iter().filter(|s| s.2 < COMPACT_FULL).count());
        }
        // 满段以下共 tiers 层，每层最多攒 FANOUT - 1 个；体积估计按真实压缩缩小后偶有同层多出一两个。
        let tiers = compact_tier(COMPACT_FULL - 1) as usize + 1;
        assert!(max_small <= tiers * (COMPACT_FANOUT - 1) + 2, "{max_small} small segments at worst");
        let amp = rewritten as f64 / appended as f64;
        eprintln!("max small segments {max_small}, write amplification {amp:.2}");
        assert!(amp <= 6.0, "write amplification {amp}");
    }

    #[test]
    fn full_segments_are_never_merged() {
        let segs = vec![(1, 10, COMPACT_FULL), (11, 20, 100), (21, 30, COMPACT_FULL), (31, 31, 100), (32, 32, 100), (33, 33, 100)];
        assert!(compaction_plan(&segs).is_empty());
        let segs = vec![(1, 1, 100), (2, 2, 100), (3, 3, 100), (4, 4, 100)];
        let plan = compaction_plan(&segs);
        assert_eq!(plan.len(), 1);
        assert_eq!(plan[0].segs, vec![(1, 1), (2, 2), (3, 3), (4, 4)]);
    }
}
