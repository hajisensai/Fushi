//! 段协议在 srs.db 上的一侧（设计 §6.1、§6.2、§7.3、§7.4）：发件（切段、打包、head）、收件（看 head 定要拉
//! 哪些段、校验、因果投递、投影、重放）、身份分叉（换身份、重签发）。
//!
//! 传输本身（列目录 / 读写文件）在 Dart（fushi_engine 的存储位置适配层），这里只吃字节、吐字节：
//! 一轮同步个位数次 FFI（发件、写 head、看 head、收段）。

use std::collections::{BTreeMap, BTreeSet, VecDeque};
use std::sync::Arc;

use rusqlite::{params, Connection, OptionalExtension};
use serde_json::{json, Value};

use super::{applied_vv, in_savepoint, insert_op, load_op, observe_remote, project, replay_cards, replay_touched, sql, Local, Touched};
use crate::store::SrsCore;
use crate::sync2::codec::{Reader, ZstdWindow};
use crate::sync2::hlc::{Hlc, MAX_AHEAD_MS};
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

/// 旧小段在第一份不再引用它的 head 之后，本机再写出多少代 head 才删（审查 S-5）。
///
/// 读者只认 head 列出的段（设计 §6.1 读取纪律），而 Dart 每轮写完 head 就删本机 `gen < 当前 - 2` 的旧 head
/// （srs_sync2_round.dart 第 4 步）。旧小段被合并后第一份不再引用它的 head 代号记为 `since_gen`：引用它的只有更早的
/// head（`gen < since_gen`），它们在当前代号到 `since_gen + 2` 时全部被删。所以从那一刻起位置上再没有任何 head 引用
/// 这些段，删它们不会让读者从「head 列出的段」里少拿到任何东西。
pub(crate) const OBSOLETE_KEEP_GENS: u64 = 2;

/// 旧小段在第一份不再引用它的 head 写出之后至少再留多久（审查 S-5）：给已经读到旧 head、正在下载它引用的段的读者，
/// 以及列目录最终一致（Google Drive 可能几分钟里仍列出已删的旧 head）留余量。读者真的扑空也不丢数据：那台设备这一轮
/// 跳过（§6.1：head 指向的段暂时读不到 → 下一轮再来），下一轮读到的新 head 引用的是合并后的段，同样的操作、同样的链值。
pub(crate) const OBSOLETE_GRACE_MS: i64 = 24 * 60 * 60 * 1000;

/// [location] 上可以删的旧小段（调用方在写出代号 [gen] 的 head 之后取）。以前要等所有没冻结的其它设备在 head 里 ack
/// 越过它，而对端重装 / 换身份 / 长期休眠时它的 ack 永远不动（只有本机换身份才冻结旧身份）→ `devices/<本机>/` 只增
/// 不减，每轮列目录越来越慢。删除安全只取决于「还有没有 head 引用它」，与别的设备应用到哪无关（它们缺的操作在合并
/// 后的段里，同一 seq 区间），所以改为按代号与时间删（[OBSOLETE_KEEP_GENS] / [OBSOLETE_GRACE_MS]）。
///
/// 两段式（集成审查【中】）：这里只给清单、**不**从待删表移除。以前取出即删记录，而 Dart 之后才上传 head、最后才删
/// 文件——head 上传或删除中途抛错，这批旧段就永远没人再删。现在记录留到 Dart 删成功后发 `obsolete_ack`
/// （[SrsCore::sync2_obsolete_ack]）才移除；没 ack 的下一轮照样再给（删除对已不在的文件幂等）。
fn stamp_obsolete(conn: &Connection, local: &Local, location: &str, gen: u64, now: i64) -> Result<(), String> {
    conn.prepare_cached(
        "UPDATE sync2_obsolete SET since_gen = ?3, since_at = ?4 WHERE profile_uid = ?1 AND location = ?2 AND since_gen IS NULL",
    )
    .map_err(sql)?
    .execute(params![local.profile, location, gen as i64, now])
    .map_err(sql)?;
    Ok(())
}

/// [location] 上此刻该删、还没确认删掉的文件：过了代号与宽限期的旧小段（[gen] = 本机在这个位置上最新的 head 代号），
/// 加上转发清理（relay.rs `sync2_relay_ack`）留下的被取代的旧转发件 / 旧转发 head。只读，不改表。
pub(crate) fn pending_deletes(conn: &Connection, profile: &str, location: &str, gen: u64, now: i64) -> Result<Vec<String>, String> {
    let mut names: Vec<String> = conn
        .prepare_cached(
            "SELECT name FROM sync2_obsolete WHERE profile_uid = ?1 AND location = ?2 AND since_gen + ?3 <= ?4 AND since_at + ?5 <= ?6 \
             UNION SELECT path FROM sync2_relay_gone WHERE profile_uid = ?1 AND location = ?2 ORDER BY 1",
        )
        .map_err(sql)?
        .query_map(params![profile, location, OBSOLETE_KEEP_GENS as i64, gen as i64, OBSOLETE_GRACE_MS, now], |r| r.get(0))
        .map_err(sql)?
        .collect::<Result<_, _>>()
        .map_err(sql)?;
    names.dedup();
    Ok(names)
}

fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
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

/// 一台设备的 head 是否已记下（[record_head] 这一次是空操作）。
fn head_recorded(c: &Connection, profile: &str, h: &Head) -> Result<bool, String> {
    let gen: Option<i64> = c
        .prepare_cached("SELECT head_gen FROM sync2_devices WHERE profile_uid = ?1 AND device = ?2")
        .map_err(sql)?
        .query_row(params![profile, h.device.0.to_vec()], |r| r.get(0))
        .optional()
        .map_err(sql)?;
    Ok(gen.is_some_and(|g| g as u64 >= h.gen))
}

/// 这台设备在 `seq` 闭区间 [a, b] 的操作是否全在因果缓冲里（按主键区间数，不把整台设备的缓冲读进内存，审查 S-6）。
fn pending_covers(c: &Connection, profile: &str, device: &Id, a: u64, b: u64) -> Result<bool, String> {
    let n: i64 = c
        .prepare_cached("SELECT COUNT(*) FROM sync2_pending WHERE profile_uid = ?1 AND device = ?2 AND seq BETWEEN ?3 AND ?4")
        .map_err(sql)?
        .query_row(params![profile, device.0.to_vec(), a as i64, b as i64], |r| r.get(0))
        .map_err(sql)?;
    Ok(n as u64 == b - a + 1)
}

/// 收段会话里找到、还没换身份的本机分叉点（审查 S-12）：`<本机身份>:<seq>`。收尾换身份时删；身份变了就作废。
fn fork_key(profile: &str) -> String {
    format!("sync2_fork_at/{profile}")
}

pub(crate) fn recorded_fork(c: &Connection, profile: &str, device: &Id) -> Result<Option<u64>, String> {
    let v: Option<String> =
        c.query_row("SELECT value FROM srs_meta WHERE key = ?1", [fork_key(profile)], |r| r.get(0)).optional().map_err(sql)?;
    Ok(v.and_then(|v| {
        let (d, k) = v.split_once(':')?;
        (d == device.text()).then(|| k.parse().ok()).flatten()
    }))
}

fn record_fork(c: &Connection, profile: &str, device: &Id, k: u64) -> Result<(), String> {
    c.execute(
        "INSERT INTO srs_meta (key, value) VALUES (?1, ?2) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        params![fork_key(profile), format!("{}:{k}", device.text())],
    )
    .map_err(sql)?;
    Ok(())
}

fn clear_fork(c: &Connection, profile: &str) -> Result<(), String> {
    c.execute("DELETE FROM srs_meta WHERE key = ?1", [fork_key(profile)]).map_err(sql)?;
    Ok(())
}

/// 本机身份分叉时要拉的本机身份的段（审查 S-12）：head 里的段按 seq 升序，前面与本机链值相同的是共同前缀（链值是
/// 哈希链，一旦分开就不会再相同，可以二分）。只拉第一处不同的前一段起（段名里的链值只有 4 字节，多拉一段让收段时
/// 逐条比完整链值兜住标签碰撞）。
fn own_fork_files(c: &Connection, profile: &str, local: &Local, h: &Head) -> Result<Vec<String>, String> {
    let same = |i: usize| -> Result<bool, String> {
        let (_, b, tag) = &h.segments[i];
        Ok(chain_at(c, profile, &local.device, *b)?.is_some_and(|ours| segment::chain_tag(&ours) == *tag))
    };
    let (mut lo, mut hi) = (0usize, h.segments.len());
    while lo < hi {
        let mid = (lo + hi) / 2;
        if same(mid)? {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    let from = lo.saturating_sub(1);
    Ok(h.segments[from..]
        .iter()
        .map(|(a, b, t)| format!("devices/{}/{}", h.device.text(), segment::segment_file_name(*a, *b, t)))
        .collect())
}

/// 看 head（[SrsCore::sync2_plan_at]）。[write] 为假时 [c] 是读连接：要记东西就返回 None（调用方进写锁重来）。
fn plan(c: &Connection, profile: &str, heads: &[Vec<u8>], location: Option<&str>, write: bool) -> Result<Option<Value>, String> {
    let local = Local::load(c, profile)?.ok_or("sync2 not initialised for this profile")?;
    let mut fetch = Vec::new();
    let mut rejected = Vec::new();
    let mut fork = false;
    let mut best: BTreeMap<Id, (Head, &[u8])> = BTreeMap::new();
    for bytes in heads {
        let Ok(h) = Head::decode(bytes) else { continue };
        if h.collection != local.collection {
            continue;
        }
        if best.get(&h.device).is_none_or(|b| b.0.gen < h.gen) {
            best.insert(h.device, (h, bytes.as_slice()));
        }
    }
    let known_fork = recorded_fork(c, profile, &local.device)?;
    let mut trusted: Vec<(&Head, &[u8])> = Vec::new();
    for (h, bytes) in best.values() {
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
                // 分叉点已在之前（被打断的）收段会话里找到：不再拉，收尾直接换身份（S-12）。
                if known_fork.is_none() {
                    let files = own_fork_files(c, profile, &local, h)?;
                    fetch.push(json!({"device": h.device.text(), "files": files, "own": true}));
                }
            }
            continue;
        }
        if write {
            if !trust_head(c, profile, h)? {
                rejected.push(h.device.text());
                continue;
            }
            record_head(c, profile, h)?;
        } else {
            match device_public(c, profile, &h.device)? {
                Some(p) if p != h.public => {
                    rejected.push(h.device.text());
                    continue;
                }
                Some(_) if head_recorded(c, profile, h)? => {}
                // 第一次见的设备 / 更新的 head：要记，进写锁。
                _ => return Ok(None),
            }
        }
        trusted.push((h, *bytes));
        let applied: u64 = c
            .query_row(
                "SELECT applied FROM sync2_devices WHERE profile_uid = ?1 AND device = ?2",
                params![profile, h.device.0.to_vec()],
                |r| r.get::<_, i64>(0),
            )
            .map_err(sql)? as u64;
        let mut files: Vec<String> = Vec::new();
        for (a, b, t) in &h.segments {
            if *b > applied && !pending_covers(c, profile, &h.device, (*a).max(applied + 1), *b)? {
                files.push(format!("devices/{}/{}", h.device.text(), segment::segment_file_name(*a, *b, t)));
            }
        }
        if !files.is_empty() {
            fetch.push(json!({"device": h.device.text(), "files": files, "own": false}));
        }
    }
    // 只为转发要拉的（已应用过、当时没留原文的段）：并进同一设备的拉取清单。
    let relay = if write {
        super::relay::note_heads(c, profile, &local, location, &trusted)?
    } else if super::relay::heads_noted(c, profile, &local, location, &trusted)? {
        if location.is_some() {
            super::relay::relay_fetch(c, profile, &local, &trusted)?
        } else {
            BTreeMap::new()
        }
    } else {
        return Ok(None);
    };
    for (device, names) in relay {
        let dir = format!("devices/{}", device.text());
        let extra: Vec<String> = names.into_iter().map(|n| format!("{dir}/{n}")).collect();
        match fetch.iter_mut().find(|f| f["device"] == json!(device.text()) && f["own"] == json!(false)) {
            Some(f) => {
                let files = f["files"].as_array_mut().ok_or("plan: files")?;
                for p in extra {
                    if !files.contains(&json!(p)) {
                        files.push(json!(p));
                    }
                }
            }
            None => fetch.push(json!({"device": device.text(), "files": extra, "own": false})),
        }
    }
    // 上一次收段会话没收尾（被打断）留下的待重放卡 / 已找到的分叉点：这一轮没段可拉也要开会话收个尾（S-4 / S-12）。
    let finish = replay_is_pending(c, profile)? || (fork && known_fork.is_some());
    Ok(Some(json!({"fetch": fetch, "fork": fork, "rejected": rejected, "finishPending": finish})))
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
    /// 这次应用的远端操作里不超前的最大 HLC（[Delivery::finish] 推进本机时钟，设计 §3.2）。
    seen: Option<Hlc>,
    /// 这次应用的远端操作里时钟超前（wall 超出本机墙钟 [MAX_AHEAD_MS]）的作者：打标告警。
    ahead: BTreeSet<Id>,
    /// 载入时的 [DELIVERY_EPOCH]：收段会话跨片复用这份队列，别处投递过（代号变了）就重新载入。
    epoch: u64,
}

/// 收段会话之外的投递（一次收完、导入、换身份）每做一次加一：会话里跨片留着的 [Delivery] 据此知道缓冲表 / 设备
/// 进度被别处改过、要重新载入（审查 S-6）。全进程一个计数（多个库共用只会让会话多载入一次，不影响结果）。
static DELIVERY_EPOCH: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

fn bump_delivery_epoch() {
    DELIVERY_EPOCH.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
}

impl Delivery {
    /// 队列里（缓冲表 + 本轮刚收、还投不上的）等着的操作条数 = 这一片收尾后缓冲表的行数（不再每片 COUNT(*)）。
    fn pending(&self) -> i64 {
        self.queues.values().map(|q| q.len() as i64).sum()
    }

    /// 收段会话的下一片接着用上一片的队列（审查 S-6：以前每片整表读一遍缓冲表）。别处投递过就重新载入；设备进度
    /// 每片从表里重读（只有设备数那么多行），本机写入推进的本机分量也就跟上了。
    fn resume(cached: Option<Delivery>, c: &Connection, profile: &str) -> Result<Delivery, String> {
        match cached {
            Some(mut d) if d.epoch == DELIVERY_EPOCH.load(std::sync::atomic::Ordering::SeqCst) => {
                d.vv = applied_vv(c, profile)?;
                Ok(d)
            }
            _ => Delivery::load(c, profile),
        }
    }

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
        Ok(Delivery {
            vv,
            queues,
            chains: BTreeMap::new(),
            forked: BTreeSet::new(),
            applied: 0,
            held: 0,
            seen: None,
            ahead: BTreeSet::new(),
            epoch: DELIVERY_EPOCH.load(std::sync::atomic::Ordering::SeqCst),
        })
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

    /// 投完能投的（预算用完就停在这里，[budget] 记下截停）；还在等的操作超过 [DELIVERY_HELD_BYTES] 就写进
    /// 缓冲表、内存里只留链值。
    fn drain(&mut self, c: &Connection, profile: &str, now: i64, t: &mut Touched, budget: &mut CommitBudget<'_>) -> Result<(), String> {
        self.deliver_ready(c, profile, now, t, budget)?;
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

    fn deliver_ready(&mut self, c: &Connection, profile: &str, now: i64, t: &mut Touched, budget: &mut CommitBudget<'_>) -> Result<(), String> {
        let Delivery { vv, queues, chains, applied, forked, held: mem, seen, ahead, .. } = self;
        let mut dropped: Vec<Id> = Vec::new();
        'all: loop {
            let mut progress = false;
            for (device, q) in queues.iter_mut() {
                while let Some(mut entry) = q.first_entry() {
                    let seq = *entry.key();
                    let have = vv.get(device);
                    if seq <= have {
                        if !budget.take() {
                            break 'all;
                        }
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
                    if !budget.take() {
                        break 'all;
                    }
                    insert_op(c, profile, op, &chain, now)?;
                    project(c, profile, op, now, true, t)?;
                    if op.hlc.wall.saturating_sub(now) > MAX_AHEAD_MS {
                        ahead.insert(*device);
                    } else if seen.is_none_or(|s| op.hlc > s) {
                        *seen = Some(op.hlc);
                    }
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

    /// 设备进度一次写；没投上的写进缓冲；按应用了的远端操作推进并持久化本机 HLC。返回应用条数。
    fn finish(mut self, c: &Connection, profile: &str, now: i64) -> Result<usize, String> {
        let n = self.checkpoint(c, profile, now)?;
        bump_delivery_epoch();
        Ok(n)
    }

    /// 一片收尾（[finish] 的落库部分，队列留着给下一片）：设备进度、没投上的写进缓冲、本机 HLC。返回这一片应用的
    /// 条数并清零；之后队列里每一条都已在缓冲表里（`stored`）。
    fn checkpoint(&mut self, c: &Connection, profile: &str, now: i64) -> Result<usize, String> {
        observe_remote(c, profile, self.seen.take(), &std::mem::take(&mut self.ahead), now)?;
        for (device, chain) in std::mem::take(&mut self.chains) {
            c.prepare_cached("UPDATE sync2_devices SET applied = ?3, chain = ?4 WHERE profile_uid = ?1 AND device = ?2")
                .map_err(sql)?
                .execute(params![profile, device.0.to_vec(), self.vv.get(&device) as i64, chain.to_vec()])
                .map_err(sql)?;
        }
        for (device, q) in self.queues.iter_mut() {
            for (seq, held) in q.iter_mut().filter(|(_, h)| !h.stored) {
                let op = held.op.as_ref().ok_or("unstored pending op without body")?;
                store_pending(c, profile, device, *seq, op, &held.chain)?;
                held.stored = true;
            }
        }
        Ok(std::mem::take(&mut self.applied))
    }
}

fn store_pending(c: &Connection, profile: &str, device: &Id, seq: u64, op: &Op, chain: &Chain) -> Result<(), String> {
    c.prepare_cached("INSERT OR IGNORE INTO sync2_pending (profile_uid, device, seq, op, chain) VALUES (?1, ?2, ?3, ?4, ?5)")
        .map_err(sql)?
        .execute(params![profile, device.0.to_vec(), seq as i64, op.encode(), chain.to_vec()])
        .map_err(sql)?;
    Ok(())
}

/// 一次 [SrsCore::sync2_ingest_commit] 在写锁里最多做多少（一片）：处理的操作条数、时间上限，以及「有别的写入在
/// 排队就让出」（[SrsCore::sync2_ingest_yield]），先到者为准；先做满 [COMMIT_SLICE_MIN_OPS] 条才看后两者，每片
/// 都有进展。用完就停在操作边界，剩下的留在会话里由下一次 commit 接着投，两次之间 Dart 放开写锁，排队的作答先写。
///
/// 一片的锁内耗时（投递、投影、重放、缓存刷新、事务提交）都与片内操作数成正比。没人等锁时片长到时间上限，
/// 提交次数少（片越短，同一批随机键索引页被反复写进 WAL 的次数越多）；有人排队就当场收片，排队者只等这一片
/// 已投部分的收尾。
pub struct CommitBudget<'a> {
    left: usize,
    deadline: Option<std::time::Instant>,
    /// 置位 = 有别的写入在等写锁，这一片尽快收。
    yield_to: Option<&'a std::sync::atomic::AtomicBool>,
    floor: usize,
    /// 这一片被预算截停过（还有没处理完的）。
    stopped: bool,
}

/// 一片投递的时间上限（写锁里投递 + 投影部分；同一片的缓存刷新与事务提交大约再占它的一半）。只在没人等锁时
/// 用满；它也是让出请求最晚的响应时间的来源（收片时要刷新、提交的就是已投的这部分）。
const COMMIT_SLICE: std::time::Duration = std::time::Duration::from_millis(150);
/// 一片至少处理的操作数（之后才看时间与让出请求）。
const COMMIT_SLICE_MIN_OPS: usize = 64;

impl<'a> CommitBudget<'a> {
    /// 不切片：一次做完（一次收完的 [SrsCore::sync2_ingest]、[SrsCore::sync2_ingest_batch]、导入）。
    pub fn unlimited() -> CommitBudget<'static> {
        CommitBudget { left: usize::MAX, deadline: None, yield_to: None, floor: 0, stopped: false }
    }

    /// 一片：最长 [COMMIT_SLICE]，[yield_to] 置位就提前收。
    pub fn slice(yield_to: &'a std::sync::atomic::AtomicBool) -> CommitBudget<'a> {
        CommitBudget::slice_within(yield_to, COMMIT_SLICE)
    }

    /// 一片，时间上限另给（测试用：给得很长，切点就只来自让出请求）。
    pub fn slice_within(yield_to: &'a std::sync::atomic::AtomicBool, max: std::time::Duration) -> CommitBudget<'a> {
        CommitBudget {
            left: usize::MAX,
            deadline: Some(std::time::Instant::now() + max),
            yield_to: Some(yield_to),
            floor: COMMIT_SLICE_MIN_OPS,
            stopped: false,
        }
    }

    /// 按条数切的一片（测试用：切点确定）。
    pub fn ops(n: usize) -> CommitBudget<'static> {
        CommitBudget { left: n.max(1), deadline: None, yield_to: None, floor: 0, stopped: false }
    }

    /// 再处理一条；预算用完返回 false 并记下截停。
    fn take(&mut self) -> bool {
        if self.stopped {
            return false;
        }
        let over = self.floor == 0
            && (self.deadline.is_some_and(|d| std::time::Instant::now() >= d)
                || self.yield_to.is_some_and(|y| y.load(std::sync::atomic::Ordering::Relaxed)));
        if self.left == 0 || over {
            self.stopped = true;
            return false;
        }
        self.left -= 1;
        self.floor = self.floor.saturating_sub(1);
        true
    }
}

/// 分批收段会话（[SrsCore::sync2_ingest_begin]）：开会话时的本机身份、跨批累积的分叉点，以及锁外预处理好、
/// 等投递的那一批（[SrsCore::sync2_ingest_prepare] 放进来，[SrsCore::sync2_ingest_commit] 一片一片投完才取走）。
pub(crate) struct IngestSession {
    profile: String,
    device: Id,
    fork_at: Option<u64>,
    prepared: Option<PreparedIngest<'static>>,
    /// 上一片留下的投递队列（[Delivery::resume]）。
    delivery: Option<Delivery>,
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
#[cfg(not(test))]
const PREPARED_RAW_BUDGET: u64 = 2 * segment::SEGMENT_MAX_RAW_BYTES;
/// 测试里压到很小：端到端用例的后几段都走「投递时重开流式解」（含切片截在段中间、下一片跳过已处理前缀），
/// 结果必须与留在内存里一样。
#[cfg(test)]
const PREPARED_RAW_BUDGET: u64 = 4 * 1024;

/// 一个段在锁外预处理的结论。
enum Outcome {
    /// 预处理时这台设备没有登记公钥。
    Unknown,
    /// 验签 / 解密 / 链校验没过：报错原文（带设备前缀）。
    Bad(String),
    /// 链已对上的、还没投递的操作与各自的链值，按 seq 升序（投递从队首取走）。
    Ops(VecDeque<(Op, Chain)>),
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
    /// 已经投递 / 比过链的前缀条数（被切片截在段中间时，下一片从这里接着；重验或重开流式解时跳过它们）。
    consumed: usize,
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
    /// 下一个要投递的段（[items] 下标）；之前的都已投完。
    next: usize,
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
                items.push(PreparedSegment { header: h, index, public: None, outcome: Outcome::Unknown, consumed: 0 })
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
        next: 0,
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

/// 预处理之后本机身份（公钥 / 集合）变了：还没投完的段（从 [PreparedIngest::next] 起，截在中间的那段整段重来——
/// 已投的操作再来一遍只比链、不重复应用）按当时的身份在锁内重新预处理（[c] 已持写锁）。
fn reprepare_under_lock(c: &Connection, profile: &str, local: &Local, p: &mut PreparedIngest<'_>) -> Result<(), String> {
    let rest: Vec<Vec<u8>> = p.items[p.next..].iter().map(|s| p.segments[s.index].clone()).collect();
    let mut fresh = prepare_ingest(c, profile, local, std::borrow::Cow::Owned(rest), p.key)?;
    fresh.verify();
    // 段头读不出的报错与段无关，还没报的照旧排在最前。
    fresh.peek_errors.splice(0..0, std::mem::take(&mut p.peek_errors));
    *p = fresh;
    Ok(())
}

/// 投递预处理好的一批段（不换身份，[c] 已持写锁），最多做到 [budget] 用完：远端操作投递进投影 / 缓冲，本机身份
/// 的段只比链，把分叉点（第一处不同的前一个 seq）取最小累积进 [fork_at]。返回（应用条数, 是否投完）；没投完时
/// 进度留在 [prepared] 里（下一个段、段内已处理的条数），下一次接着调。
///
/// 结果与在锁内从头一次处理完逐字节相同：切点落在任意操作边界，等价于 Dart 在那里切批（每片的设备进度与没投上
/// 的操作都在 [Delivery::finish] 里落库，下一片重新 [Delivery::load]）；预处理之后本机身份变了就按当时的身份重做
/// 还没投完的段；某台设备的公钥变了（含新登记 / 不再登记）就按当时的公钥重验那一段、跳过已处理的前缀。
///
/// 逐段投（[Delivery]），同时在内存里的只有预处理留下的操作与等依赖的操作。
#[allow(clippy::too_many_arguments)]
fn deliver_prepared(
    c: &Connection,
    profile: &str,
    local: &Local,
    prepared: &mut PreparedIngest<'_>,
    budget: &mut CommitBudget<'_>,
    now: i64,
    t: &mut Touched,
    errors: &mut Vec<String>,
    fork_at: &mut Option<u64>,
    cached: &mut Option<Delivery>,
) -> Result<(usize, bool, i64), String> {
    if prepared.profile != profile
        || prepared.device != local.device
        || prepared.local_public != local.key.public()
        || prepared.collection != local.collection
    {
        reprepare_under_lock(c, profile, local, prepared)?;
    }
    errors.append(&mut prepared.peek_errors);
    let ck = prepared.key.map(CollectionKey);
    let PreparedIngest { segments, items, next, .. } = prepared;
    let mut delivery = Delivery::resume(cached.take(), c, profile)?;
    // 上一片被截停时可能还有已经接得上的操作（在缓冲表里），先投它们。
    delivery.drain(c, profile, now, t, budget)?;
    while *next < items.len() && !budget.stopped {
        let item = &mut items[*next];
        let header = item.header.clone();
        let bytes = &segments[item.index];
        let public = if header.device == local.device { Some(local.key.public()) } else { device_public(c, profile, &header.device)? };
        if public != item.public {
            // 重验得到整段，已处理的前缀在下面跳过。
            item.outcome = verify_segment(bytes, &header, public, ck.as_ref(), &mut { u64::MAX });
            if let Outcome::Ops(q) = &mut item.outcome {
                q.drain(..item.consumed.min(q.len()));
            }
            item.public = public;
        }
        let public = match &item.outcome {
            Outcome::Unknown => {
                errors.push(format!("segment from unknown device {}", header.device.text()));
                *next += 1;
                continue;
            }
            Outcome::Bad(e) => {
                errors.push(e.clone());
                *next += 1;
                continue;
            }
            Outcome::Ops(_) | Outcome::Deferred => public.ok_or("verified segment without a public key")?,
        };
        if header.device != local.device && item.consumed == 0 {
            // 签名与链都已验过：还有位置缺这台设备的这个段就留下原文，之后原样转发过去（relay.rs）。
            super::relay::keep(c, profile, local, &header, bytes, ck.as_ref())?;
        }
        let stream_err = |e: segment::SegmentError| format!("{}: {e}", header.device.text());
        let mut consumed = item.consumed;
        let mut exhausted = false;
        {
            // 留下的操作（从队首取走），或（Deferred）重开流式解、跳过已处理的前缀：签名、链在预处理里都已对上，
            // 这一遍与校验那一遍逐字节相同。
            let reopened;
            let mut ops: Box<dyn Iterator<Item = Result<(Op, Chain), String>> + '_> = match &mut item.outcome {
                Outcome::Ops(q) => Box::new(std::iter::from_fn(move || q.pop_front().map(Ok))),
                _ => {
                    reopened = segment::open_verified(bytes, &public, ck.as_ref()).map_err(stream_err)?;
                    let mut chain = header.prev_chain;
                    Box::new(
                        reopened
                            .ops()
                            .map_err(stream_err)?
                            .map(move |op| {
                                let op = op.map_err(stream_err)?;
                                chain = chain_next(&chain, &op);
                                Ok((op, chain))
                            })
                            .skip(consumed),
                    )
                }
            };
            if header.device == local.device {
                // 同一身份、签名也对（同一把钥匙 = 数据目录被复制）：逐条比链，第一处不同之前是共同前缀。
                loop {
                    if !budget.take() {
                        break;
                    }
                    let Some(r) = ops.next() else {
                        exhausted = true;
                        break;
                    };
                    consumed += 1;
                    let (op, chain) = r?;
                    let ours = chain_at(c, profile, &local.device, op.id.seq)?;
                    if ours != Some(chain) {
                        let k = op.id.seq - 1;
                        *fork_at = Some(fork_at.map_or(k, |f| f.min(k)));
                        exhausted = true;
                        break;
                    }
                }
            } else {
                // 按小块投：一块投完（投上的当场释放）再取下一块，超大旧段也只占一块的内存；预算用完就不再取，
                // 已取进队列没投上的由 [Delivery::finish] 写进缓冲表。
                let mut chunk: Vec<(Op, Chain)> = Vec::new();
                let mut chunk_raw = 0usize;
                while !budget.stopped {
                    let Some(r) = ops.next() else {
                        exhausted = true;
                        break;
                    };
                    consumed += 1;
                    let (op, chain) = r?;
                    chunk_raw += op.payload.len() + 24;
                    chunk.push((op, chain));
                    if chunk.len() >= INGEST_CHUNK_OPS || chunk_raw >= DELIVERY_CHUNK_RAW {
                        delivery.push(std::mem::take(&mut chunk));
                        chunk_raw = 0;
                        delivery.drain(c, profile, now, t, budget)?;
                    }
                }
                delivery.push(chunk);
                delivery.drain(c, profile, now, t, budget)?;
            }
        }
        if exhausted {
            item.outcome = Outcome::Deferred;
            *next += 1;
        } else {
            item.consumed = consumed;
        }
    }
    let done = *next == items.len() && !budget.stopped;
    let applied = delivery.checkpoint(c, profile, now)?;
    let pending = delivery.pending();
    *cached = Some(delivery);
    Ok((applied, done, pending))
}

/// 一次投递的块（条数 / 解压后字节，先到者为准）：新切的段本来就不超过 [segment::SEGMENT_MAX_RAW_BYTES]，
/// 这两条只在读旧版本切出的超大段 / 导入文件时起作用。
const DELIVERY_CHUNK_OPS: usize = 16_384;
const DELIVERY_CHUNK_RAW: usize = 4 * 1024 * 1024;
/// 收段按片投递时的块：块小，片被截停时已取进队列、没投上、要写进缓冲表的操作就少。
const INGEST_CHUNK_OPS: usize = 64;

/// 收段命令的返回。[replayed] = 这一次重放改写了日志的卡（一次收完时当场重放；分批会话里各片只记进待重放集合，
/// 收尾才重放，见 [defer_replay]）。[more]：还要再调一次（这一批被切片截停 / 待重放集合没放完）。
#[allow(clippy::too_many_arguments)]
fn ingest_result(
    c: &Connection,
    profile: &str,
    t: Touched,
    replayed: BTreeSet<String>,
    applied: usize,
    errors: Vec<String>,
    fork: bool,
    more: bool,
    pending: Option<i64>,
) -> Result<String, String> {
    let pending: i64 = match pending {
        Some(n) => n,
        None => c
            .query_row("SELECT COUNT(*) FROM sync2_pending WHERE profile_uid = ?1", [profile], |r| r.get(0))
            .map_err(sql)?,
    };
    Ok(json!({
        "marks": t.marks.to_json(),
        "replayed": replayed,
        "applied": applied,
        "pending": pending,
        "errors": errors,
        "fork": fork,
        "more": more,
        "diagnostics": t.diagnostics,
        "changed": t.entities_changed.iter().map(|(k, e)| json!([k, e])).collect::<Vec<_>>(),
        "purged": t.purged.iter().map(|(k, e)| json!([k, e])).collect::<Vec<_>>(),
    })
    .to_string())
}

/// 收段的一步在同一笔事务里写下 Dart 的本机状态行（`srs_local_state`，集成审查【中高】）。[local_state] 是 Dart 调用
/// 那一刻内存里的本机状态（`_saveLocal` 写的同一份 JSON）；这一步只会改变其中的修订号 `revision`（Dart
/// `_absorbProjection`：每条落库的事件、每个变化的实体各 +1），这里按 [result] 的 `marks.landed` 与 `changed` 条数
/// 同样推进后写下，并把写下的值放进结果的 `localRevision`（Dart 以它为准，内存与库里的一致）。[local_state] 为 None
/// （测试、旧调用方）就不写，结果原样返回。
fn persist_local_state(c: &Connection, profile: &str, local_state: Option<&str>, result: String) -> Result<String, String> {
    let Some(local) = local_state else { return Ok(result) };
    let mut r: Value = serde_json::from_str(&result).map_err(|e| e.to_string())?;
    let mut state: Value = serde_json::from_str(local).map_err(|e| format!("sync2 ingest: bad localState: {e}"))?;
    let landed = r["marks"]["landed"].as_i64().unwrap_or(0);
    let changed = r["changed"].as_array().map_or(0, |a| a.len() as i64);
    let revision = state.get("revision").and_then(Value::as_i64).unwrap_or(0) + landed + changed;
    state
        .as_object_mut()
        .ok_or("sync2 ingest: localState must be a JSON object")?
        .insert("revision".to_owned(), json!(revision));
    c.prepare_cached(
        "INSERT INTO srs_local_state (profile_uid, json) VALUES (?1, ?2) ON CONFLICT(profile_uid) DO UPDATE SET json = excluded.json",
    )
    .map_err(sql)?
    .execute(params![profile, state.to_string()])
    .map_err(sql)?;
    r["localRevision"] = json!(revision);
    Ok(r.to_string())
}

/// 把这一片受影响的卡记进待重放集合（审查 S-4）：与投递同一事务，崩溃 / 中途收手后还在。
///
/// 以前每一片（[COMMIT_SLICE]）收尾都当场重放受影响的卡，而重放是整条血统从初始状态重算：新设备追赶时同一张卡
/// 在几百片里各被重放一遍（每遍的日志还越来越多），近平方级（100 万次复习收齐 199 s，全量重放只要 29 s）。
/// 现在每张卡在一次收段会话里只在收尾重放一遍。片与片之间投影行里是作者算的结果（远端日志自带）：追赶单台设备时
/// 它就等于重放结果，只有真并发交错的卡在收尾前短暂显示作者结果。
pub(crate) fn defer_replay(c: &Connection, profile: &str, cards: &BTreeSet<String>) -> Result<(), String> {
    let mut stmt = c
        .prepare_cached("INSERT OR IGNORE INTO sync2_replay_pending (profile_uid, card_id) VALUES (?1, ?2)")
        .map_err(sql)?;
    for card in cards {
        stmt.execute(params![profile, card]).map_err(sql)?;
    }
    Ok(())
}

/// 一次从待重放集合取多少张卡。
const REPLAY_PENDING_CHUNK: usize = 512;

/// 重放待重放集合里的卡，做到 [budget] 用完（每张卡算一份）。返回（日志被改写的卡, 是否还有没放的）。重放是
/// 全部日志的纯函数，所以与当场逐片重放的结果逐字节相同（tests_replay_pending.rs 对拍）。
pub(crate) fn replay_pending(c: &Connection, profile: &str, budget: &mut CommitBudget<'_>) -> Result<(BTreeSet<String>, bool), String> {
    let mut changed = BTreeSet::new();
    loop {
        let ids: Vec<String> = c
            .prepare_cached("SELECT card_id FROM sync2_replay_pending WHERE profile_uid = ?1 ORDER BY card_id LIMIT ?2")
            .map_err(sql)?
            .query_map(params![profile, REPLAY_PENDING_CHUNK as i64], |r| r.get(0))
            .map_err(sql)?
            .collect::<Result<_, _>>()
            .map_err(sql)?;
        if ids.is_empty() {
            return Ok((changed, false));
        }
        let mut take: BTreeSet<String> = BTreeSet::new();
        for id in ids {
            if !budget.take() {
                break;
            }
            take.insert(id);
        }
        if take.is_empty() {
            return Ok((changed, true));
        }
        changed.extend(replay_cards(c, &take)?);
        let mut del = c.prepare_cached("DELETE FROM sync2_replay_pending WHERE profile_uid = ?1 AND card_id = ?2").map_err(sql)?;
        for id in &take {
            del.execute(params![profile, id]).map_err(sql)?;
        }
        if budget.stopped {
            return Ok((changed, replay_is_pending(c, profile)?));
        }
    }
}

/// 待重放集合非空（收段会话没收尾就被打断过）。
pub(crate) fn replay_is_pending(c: &Connection, profile: &str) -> Result<bool, String> {
    c.query_row("SELECT EXISTS(SELECT 1 FROM sync2_replay_pending WHERE profile_uid = ?1)", [profile], |r| r.get(0)).map_err(sql)
}

// 本机身份分叉（设计 §7.3）：换新身份，把旧身份 seq > [keep] 的本机操作撤出投影、以新身份重签发
/// （内容不变），旧身份冻结在 [keep]（之后它的远端操作按普通设备收）。
pub(crate) fn rotate(conn: &Connection, profile: &str, keep: u64, now: i64, t: &mut Touched) -> Result<(), String> {
    let old = Local::load(conn, profile)?.ok_or("no sync2 identity")?;
    clear_fork(conn, profile)?;
    bump_delivery_epoch();
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
    // 寄存器反链里撤出的写入（重签发时按新 OpId 重新并入）。
    conn.execute(
        "DELETE FROM sync2_mvr WHERE profile_uid = ?1 AND device = ?2 AND seq > ?3",
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

/// head 里只有 ack（本机应用到哪）/ 状态摘要变了时最多推迟多久才写（审查 S-8）。以前每收一批别人的操作，ack 一变
/// 就写 head → 唤醒对端 → 对端收了本机的 head、它的 ack 变了又写 head 回唤醒，复习时两台设备互相空转。ack 只用于显示
/// 对端进度；10 分钟与摘要的重算间隔（Dart `kSrsSync2DigestInterval`）相同。
pub const ACK_ONLY_HEAD_MS: i64 = 10 * 60 * 1000;

/// [SrsCore::sync2_head_if_changed] 的结果。
pub enum HeadWrite {
    /// 写了新 head：`(相对路径, 字节, 代号, 可删的旧小段)`。
    Written { path: String, bytes: Vec<u8>, gen: u64, obsolete: Vec<String> },
    /// 内容与上次写出的相同、还没到期：没写，[path] 是上次写出的那个 head；[obsolete] 是此刻仍待删的文件（上一轮
    /// 删到一半失败、还没 `obsolete_ack` 的那些照样给出）。
    Unchanged { path: String, obsolete: Vec<String> },
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
            // 不算 ack / 摘要的内容签名：只有它们变了（收到别人的操作、摘要重算）不急着写（审查 S-8）。
            let core_sig = {
                let mut h = head.clone();
                h.ack = Vv::default();
                h.digest = String::new();
                h.content_sig()
            };
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
                // 值形如 `<内容签名>|<写出时刻>|<head 路径>|<不含 ack / 摘要的签名>`（老版本写的没有第 4 段）。
                if let Some(last) = last {
                    let mut parts = last.splitn(4, '|');
                    if let (Some(s), Some(at), Some(path)) = (parts.next(), parts.next(), parts.next()) {
                        let core = parts.next();
                        let age = at.parse::<i64>().ok().filter(|at| now >= *at).map(|at| now - at);
                        let fresh = age.is_some_and(|a| a < max_age);
                        // 只有 ack / 摘要变了：等到 [ACK_ONLY_HEAD_MS] 再写（期间新段照样触发写 head）。别的设备只拿 ack
                        // 显示进度，旧段删除也不再等 ack（S-5）。
                        let ack_only_fresh = core == Some(core_sig.as_str()) && age.is_some_and(|a| a < ACK_ONLY_HEAD_MS.min(max_age));
                        if (s == sig && fresh) || ack_only_fresh {
                            let gen: i64 = c
                                .query_row(
                                    "SELECT head_gen FROM sync2_locations WHERE profile_uid = ?1 AND location = ?2",
                                    params![profile, location],
                                    |r| r.get(0),
                                )
                                .optional()
                                .map_err(sql)?
                                .unwrap_or(0);
                            let obsolete = pending_deletes(c, profile, location, gen.max(0) as u64, now)?;
                            return Ok(HeadWrite::Unchanged { path: path.to_owned(), obsolete });
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
                params![sig_key, format!("{sig}|{now}|{path}|{core_sig}")],
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
            // 新 head 已经不再引用合并掉的旧小段：已经没有任何留着的 head 引用、且过了宽限期的一并交给 Dart 删（S-5）。
            // 只给清单，删成功后 Dart 发 `obsolete_ack` 才移除记录（两段式，见 [stamp_obsolete]）。
            stamp_obsolete(c, &local, location, head.gen, now)?;
            let obsolete = pending_deletes(c, profile, location, head.gen, now)?;
            Ok(HeadWrite::Written { path, bytes, gen: head.gen, obsolete })
        })
    }

    /// 确认 [location] 上这些文件（`sync2_head` / `sync2_relay_ack` 给的待删清单里的相对路径）已经删掉（或在归档
    /// 位置上按策略不删）：从待删记录里移除。没被确认的下一轮照样再给。返回移除的记录数。
    pub fn sync2_obsolete_ack(&self, profile: &str, location: &str, deleted: &[String]) -> Result<usize, String> {
        let w = self.writer()?;
        in_savepoint(&w, |c| {
            let mut n = 0;
            for path in deleted {
                n += c
                    .prepare_cached("DELETE FROM sync2_obsolete WHERE profile_uid = ?1 AND location = ?2 AND name = ?3")
                    .map_err(sql)?
                    .execute(params![profile, location, path])
                    .map_err(sql)?;
                n += c
                    .prepare_cached("DELETE FROM sync2_relay_gone WHERE profile_uid = ?1 AND location = ?2 AND path = ?3")
                    .map_err(sql)?
                    .execute(params![profile, location, path])
                    .map_err(sql)?;
            }
            Ok(n)
        })
    }

    /// 看 head：[heads] 是位置上各设备最新的 head 文件字节。返回要拉的段
    /// `{"fetch":[{"device","files":[相对路径]}], "fork": bool, "rejected":[设备], "devices":[...] }`。
    pub fn sync2_plan(&self, profile: &str, heads: &[Vec<u8>]) -> Result<Value, String> {
        self.sync2_plan_at(profile, heads, None)
    }

    /// 同 [Self::sync2_plan]，[location] 给出时（这些 head 所在位置的进度身份，与发件同一个）还记下这个位置上有
    /// 谁的哪些段：别的位置缺、只在这里有最新 head 的设备的段也列进要拉的（只为转发，relay.rs）。
    pub fn sync2_plan_at(&self, profile: &str, heads: &[Vec<u8>], location: Option<&str>) -> Result<Value, String> {
        // 先在读连接上算（审查 S-8）：空轮（head 都没变）什么都不用记，不拿写锁；要记新设备 / 新 head 才进写连接重算。
        if let Some(v) = self.sync2_plan_read_only(profile, heads, location)? {
            return Ok(v);
        }
        let w = self.writer()?;
        in_savepoint(&w, |c| Ok(plan(c, profile, heads, location, true)?.expect("writable plan always answers")))
    }

    /// [Self::sync2_plan_at] 的只读一半：只在读连接（已提交快照）上算；要往库里记东西（第一次见的设备、更新的 head、
    /// 这个位置上的 head 变了）时返回 None，调用方进写锁再调 [Self::sync2_plan_at]。
    pub fn sync2_plan_read_only(&self, profile: &str, heads: &[Vec<u8>], location: Option<&str>) -> Result<Option<Value>, String> {
        let r = self.reader()?;
        plan(&r, profile, heads, location, false)
    }

    /// 收段：每项是一个段文件的字节（任意顺序、可重复）。校验（签名 / 链 / 解密）、按设备连续前缀 + 因果
    /// 满足才应用；不满足的进缓冲等下一轮。返回
    /// `{"marks":{..见 [super::Marks::to_json]}, "replayed":[..], "applied":n, "pending":n, "errors":[..], "fork":bool}`。
    ///
    /// 一次收完；同一轮要分几批收（字节预算）时用 [SrsCore::sync2_ingest_begin] / [SrsCore::sync2_ingest_batch] /
    /// [SrsCore::sync2_ingest_finish]，分叉判定与换身份和把全部批次拼成一次调用这里相同。解码与验签在写锁外
    /// （[SrsCore::sync2_ingest_prepare]），写锁里只投递。
    pub fn sync2_ingest(&self, profile: &str, segments: &[Vec<u8>], key: Option<[u8; 32]>, now: i64) -> Result<String, String> {
        let mut prepared = self.prepare_unlocked(profile, std::borrow::Cow::Borrowed(segments), key)?;
        let w = self.writer()?;
        in_savepoint(&w, |c| {
            let local = Local::load(c, profile)?.ok_or("sync2 not initialised for this profile")?;
            let mut t = Touched::default();
            let mut errors = Vec::new();
            let mut fork_at: Option<u64> = None;
            let (applied_n, _, _) = deliver_prepared(
                c,
                profile,
                &local,
                &mut prepared,
                &mut CommitBudget::unlimited(),
                now,
                &mut t,
                &mut errors,
                &mut fork_at,
                &mut None,
            )?;
            bump_delivery_epoch();
            if let Some(k) = fork_at {
                rotate(c, profile, k, now, &mut t)?;
            }
            let replayed = replay_touched(c, &t)?;
            ingest_result(c, profile, t, replayed, applied_n, errors, fork_at.is_some(), false, None)
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
        // 之前被打断的会话已经找到的分叉点接着用（审查 S-12：plan 不再让 Dart 重下本机身份的段）。
        let fork_at = recorded_fork(&w, profile, &local.device)?;
        *self.ingest_session.lock().map_err(|_| "ingest session poisoned")? =
            Some(IngestSession { profile: profile.to_owned(), device: local.device, fork_at, prepared: None, delivery: None });
        Ok(json!({}))
    }

    /// 会话里收一批（[SrsCore::sync2_ingest_prepare] + 不切片的 [SrsCore::sync2_ingest_commit] 连着做）。
    pub fn sync2_ingest_batch(&self, profile: &str, segments: Vec<Vec<u8>>, key: Option<[u8; 32]>, now: i64) -> Result<String, String> {
        self.sync2_ingest_prepare(profile, segments, key)?;
        self.sync2_ingest_commit(profile, now, CommitBudget::unlimited())
    }

    /// 会话里预处理一批：不持写锁（也不长持读锁）地解压、解密、验签、重算链，结果留在会话里等
    /// [SrsCore::sync2_ingest_commit]（覆盖上一批没投递的）。手机上一批要一两秒，这期间本机作答照常写入。
    /// 出错作废会话（与 [SrsCore::sync2_ingest_commit] 出错相同）。
    ///
    /// [segments] 按所有权交进来、由会话持有到投递（不复制，审查 S-9）。
    pub fn sync2_ingest_prepare(&self, profile: &str, segments: Vec<Vec<u8>>, key: Option<[u8; 32]>) -> Result<Value, String> {
        let device = self.session_device(profile)?;
        let prepared = self.prepare_unlocked(profile, std::borrow::Cow::Owned(segments), key);
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

    /// 会话里投递预处理好的那一批，最多做到 [budget] 用完（一片）：远端设备的操作照常投递并提交；本机身份的段
    /// 只比链、把分叉点累积进会话，不换身份（返回的 `fork` 恒为 false，换身份见 [SrsCore::sync2_ingest_finish]）。
    /// 写锁里只剩比链、因果投递、落库、重放；预处理之后某台设备的公钥变了，那一段按当时的公钥在锁内重验。
    /// 返回 `more` 为真 = 这一片被截停，剩下的留在会话里，再调一次接着投（两次之间别的写入可以插进来）。
    /// 会话期间本机身份变了（别处换过身份）就作废会话并报错：之后的本机段已不能按同一身份比链。
    pub fn sync2_ingest_commit(&self, profile: &str, now: i64, budget: CommitBudget<'_>) -> Result<String, String> {
        self.sync2_ingest_commit_persisting(profile, now, budget, None)
    }

    /// 同 [Self::sync2_ingest_commit]；给了 [local_state]（Dart 本机状态行 `srs_local_state.json` 的此刻内容）就在投递
    /// 的**同一笔事务**里把它写下（修订号按这一片落库的变化推进，见 [persist_local_state]）。收段不再套 Drift 事务
    /// （集成审查【中高】）：这一片由内核自己提交，提交成功才推进会话内存（`prepared` / `delivery`），所以不会有
    /// 「内层 SAVEPOINT 释放、会话已推进，外层事务却回滚」的不一致；本机状态行也随同一次提交落盘或一起不落。
    pub fn sync2_ingest_commit_persisting(
        &self,
        profile: &str,
        now: i64,
        budget: CommitBudget<'_>,
        local_state: Option<&str>,
    ) -> Result<String, String> {
        let out = self.ingest_commit_slice(profile, now, budget, local_state);
        // 这一片收了：让出请求是冲着它来的（之后才到的最多让下一片早收）。
        self.ingest_yield.store(false, std::sync::atomic::Ordering::Relaxed);
        out
    }

    /// 有别的写入在等写锁：正在投的那一片（[SrsCore::sync2_ingest_commit]）尽快收。不拿任何连接锁，从等锁的
    /// 那一侧（Dart 的写入排队）直接调。
    pub fn sync2_ingest_yield(&self) {
        self.ingest_yield.store(true, std::sync::atomic::Ordering::Relaxed);
    }

    /// 让出请求的标志（[CommitBudget::slice] 读它）。
    pub(crate) fn ingest_yield_flag(&self) -> &std::sync::atomic::AtomicBool {
        &self.ingest_yield
    }

    fn ingest_commit_slice(&self, profile: &str, now: i64, mut budget: CommitBudget<'_>, local_state: Option<&str>) -> Result<String, String> {
        let w = self.writer()?;
        let mut guard = self.ingest_session.lock().map_err(|_| "ingest session poisoned")?;
        let (device, prior, mut prepared, mut cached) = match guard.as_mut() {
            Some(s) if s.profile == profile => match s.prepared.take() {
                Some(p) => (s.device, s.fork_at, p, s.delivery.take()),
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
            let (applied_n, done, pending) = deliver_prepared(
                c,
                profile,
                &local,
                &mut prepared,
                &mut budget,
                now,
                &mut t,
                &mut errors,
                &mut fork_at,
                &mut cached,
            )?;
            defer_replay(c, profile, &t.cards)?;
            if let Some(k) = fork_at.filter(|k| prior != Some(*k)) {
                record_fork(c, profile, &local.device, k)?;
            }
            #[cfg(test)]
            if let Some(hook) = self.ingest_commit_hook.lock().map_err(|_| "hook poisoned")?.as_ref() {
                hook(self);
            }
            let r = ingest_result(c, profile, t, BTreeSet::new(), applied_n, errors, false, !done, Some(pending))?;
            let r = persist_local_state(c, profile, local_state, r)?;
            Ok((r, fork_at, done))
        });
        match out {
            Ok((r, fork_at, done)) => {
                if let Some(s) = guard.as_mut() {
                    s.fork_at = fork_at;
                    s.delivery = cached;
                    if !done {
                        s.prepared = Some(prepared);
                    }
                }
                Ok(r)
            }
            Err(e) => {
                *guard = None;
                Err(e)
            }
        }
    }

    /// 收尾：会话里累积出分叉点就换身份（与一次收完时同一个分叉点、同样在全部投递之后），再把各片记下的待重放
    /// 卡一次重放完（审查 S-4）。返回与 [SrsCore::sync2_ingest] 同形（`applied` 为 0：操作都在各批里投递过了）。
    /// 会话期间本机身份变了：不换。
    pub fn sync2_ingest_finish(&self, profile: &str, now: i64) -> Result<String, String> {
        self.sync2_ingest_finish_within(profile, now, CommitBudget::unlimited())
    }

    /// 同 [Self::sync2_ingest_finish]，重放按 [budget] 切片：返回 `more` 为真 = 待重放集合还没放完，调用方放开
    /// 写锁后用 [Self::sync2_replay_pending] 接着放（会话已在这一次收掉）。
    pub fn sync2_ingest_finish_within(&self, profile: &str, now: i64, budget: CommitBudget<'_>) -> Result<String, String> {
        self.sync2_ingest_finish_persisting(profile, now, budget, None)
    }

    /// 同 [Self::sync2_ingest_finish_within]，[local_state] 同 [Self::sync2_ingest_commit_persisting]。
    pub fn sync2_ingest_finish_persisting(
        &self,
        profile: &str,
        now: i64,
        mut budget: CommitBudget<'_>,
        local_state: Option<&str>,
    ) -> Result<String, String> {
        let w = self.writer()?;
        let session = {
            let mut guard = self.ingest_session.lock().map_err(|_| "ingest session poisoned")?;
            match guard.take() {
                Some(s) if s.profile == profile => s,
                _ => return Err("sync2 ingest: no ingest session for this profile".to_owned()),
            }
        };
        let out = in_savepoint(&w, |c| {
            let local = Local::load(c, profile)?.ok_or("sync2 not initialised for this profile")?;
            let mut t = Touched::default();
            let fork_at = session.fork_at.filter(|_| local.device == session.device);
            if let Some(k) = fork_at {
                rotate(c, profile, k, now, &mut t)?;
            }
            clear_fork(c, profile)?;
            defer_replay(c, profile, &t.cards)?;
            let (replayed, more) = replay_pending(c, profile, &mut budget)?;
            let r = ingest_result(c, profile, t, replayed, 0, Vec::new(), fork_at.is_some(), more, None)?;
            persist_local_state(c, profile, local_state, r)
        });
        self.ingest_yield.store(false, std::sync::atomic::Ordering::Relaxed);
        out
    }

    /// 接着重放待重放集合（[Self::sync2_ingest_finish_within] 返回 `more`，或上一次会话没收尾就被打断）：做到
    /// [budget] 用完。返回与收段同形，`more` 为真就再调。
    pub fn sync2_replay_pending(&self, profile: &str, budget: CommitBudget<'_>) -> Result<String, String> {
        self.sync2_replay_pending_persisting(profile, budget, None)
    }

    /// 同 [Self::sync2_replay_pending]，[local_state] 同 [Self::sync2_ingest_commit_persisting]。
    pub fn sync2_replay_pending_persisting(&self, profile: &str, mut budget: CommitBudget<'_>, local_state: Option<&str>) -> Result<String, String> {
        let w = self.writer()?;
        let out = in_savepoint(&w, |c| {
            let (replayed, more) = replay_pending(c, profile, &mut budget)?;
            let r = ingest_result(c, profile, Touched::default(), replayed, 0, Vec::new(), false, more, None)?;
            persist_local_state(c, profile, local_state, r)
        });
        self.ingest_yield.store(false, std::sync::atomic::Ordering::Relaxed);
        out
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

    /// 摘要的各桶（只列非空桶，读连接）：`{"vv": .., "buckets": [[桶号, 值, 行数], ..]}`。两台设备根不同时对比它，
    /// 不一致的桶 = 不一致的 ID 范围（[super::digest::bucket_of]）。
    pub fn sync2_digest_buckets(&self, profile: &str) -> Result<Value, String> {
        let r = self.reader()?;
        r.execute_batch("BEGIN").map_err(sql)?;
        let out = (|| Ok::<_, String>((super::digest::buckets(&r, profile)?, applied_vv(&r, profile)?)))();
        r.execute_batch("COMMIT").map_err(sql)?;
        let (b, vv) = out?;
        Ok(json!({
            "vv": format!("{}{}", super::digest::VV_PREFIX, vv.hash_hex()),
            "buckets": b.into_iter().map(|(k, v, n)| json!([k, v, n])).collect::<Vec<_>>(),
        }))
    }

    /// 算并记下状态摘要（设计 §4.5；写 head 时带上）。返回 `{"digest", "vv"}`。
    pub fn sync2_digest(&self, profile: &str) -> Result<Value, String> {
        self.sync2_digest_due(profile, 0, None)
    }

    /// 算并记下状态摘要（写进 head，§4.5）。桶表由触发器增量维护（digest.rs），这里只读 4096 个桶求根；给了
    /// [min_interval_ms]：版本向量没变、或离上次算不到这个间隔，就不算（返回 `{"skipped": true}`；摘要变化只在
    /// head 里推迟发布，见 transport.rs `ACK_ONLY_HEAD_MS`）。
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
            let tag = format!("{}{}", super::digest::VV_PREFIX, vv.hash_hex());
            let same_vv = prev.as_deref().and_then(|p| p.split_once('@')).is_some_and(|(_, v)| v == tag);
            if same_vv || now - last_at < interval {
                return Ok(json!({"skipped": true}));
            }
        }
        // 桶表由触发器随每次写入维护（digest.rs，审查 S-7）：根只读 4096 行，不再全库扫描。读连接上一个读事务里取，
        // 根与版本向量出自同一快照。
        let (d, vv) = {
            let r = self.reader()?;
            r.execute_batch("BEGIN").map_err(sql)?;
            let out = (|| Ok::<_, String>((super::digest::root(&r, profile)?, applied_vv(&r, profile)?)))();
            r.execute_batch("COMMIT").map_err(sql)?;
            out?
        };
        let w = self.writer()?;
        in_savepoint(&w, |c| {
            let value = format!("{d}@{}{}", super::digest::VV_PREFIX, vv.hash_hex());
            for (k, v) in [(&key, value), (&at_key, now.to_string())] {
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
                            delivery.drain(c, profile, now, &mut t, &mut CommitBudget::unlimited())?;
                        }
                    }
                }
            }
            delivery.push(chunk);
            delivery.drain(c, profile, now, &mut t, &mut CommitBudget::unlimited())?;
            let applied = delivery.finish(c, profile, now)?;
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
