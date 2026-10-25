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
use crate::sync2::codec::Reader;
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

/// 本设备的切段点：还没切的本机操作按上限切成新段（切点一旦定下就不变，各位置拿到的是同样的段）。
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
        let mut ops = Vec::new();
        for seq in last_cut + 1..=top {
            ops.push(load_op(conn, &local.profile, &OpId { device: local.device, seq })?.ok_or("missing local op")?);
        }
        for (a, b) in segment::split_ranges(&ops) {
            conn.execute(
                "INSERT OR IGNORE INTO sync2_segments (profile_uid, device, first, last) VALUES (?1, ?2, ?3, ?4)",
                params![local.profile, local.device.0.to_vec(), ops[a].id.seq as i64, ops[b - 1].id.seq as i64],
            )
            .map_err(sql)?;
        }
    }
    conn.prepare_cached("SELECT first, last FROM sync2_segments WHERE profile_uid = ?1 AND device = ?2 ORDER BY first")
        .map_err(sql)?
        .query_map(params![local.profile, local.device.0.to_vec()], |r| Ok((r.get::<_, i64>(0)? as u64, r.get::<_, i64>(1)? as u64)))
        .map_err(sql)?
        .collect::<Result<_, _>>()
        .map_err(sql)
}

/// 小段合并（设计 §7.1）：本机连续的小段（每段少于 [COMPACT_SMALL_OPS] 条）攒到 [COMPACT_MIN_RUN] 个以上，就按
/// 段上限重新切成大段——同一 seq 区间、同样的操作、重新签名，名字随之变化。网盘上的文件数因此不随同步次数线性涨。
///
/// 各位置上已经有旧小段的：合并后的大段登记成「要重传」（[sync2_rewrites]），旧小段登记成「待删」
/// （[sync2_obsolete]）；待删的旧文件在新 head 写出、且所有活跃设备的 ack 都越过它之后才删（`sync2_head` 返回），
/// 归档位置由 Dart 侧跳过删除。还没传过的位置直接拿合并后的段。
const COMPACT_SMALL_OPS: u64 = 200;
const COMPACT_MIN_RUN: usize = 16;

fn compact_segments(conn: &Connection, local: &Local) -> Result<(), String> {
    let segs: Vec<(u64, u64)> = conn
        .prepare_cached("SELECT first, last FROM sync2_segments WHERE profile_uid = ?1 AND device = ?2 ORDER BY first")
        .map_err(sql)?
        .query_map(params![local.profile, local.device.0.to_vec()], |r| Ok((r.get::<_, i64>(0)? as u64, r.get::<_, i64>(1)? as u64)))
        .map_err(sql)?
        .collect::<Result<_, _>>()
        .map_err(sql)?;
    // 连续的小段成一组（中间夹着大段就断开）。
    let mut runs: Vec<Vec<(u64, u64)>> = Vec::new();
    let mut cur: Vec<(u64, u64)> = Vec::new();
    for s in segs {
        if s.1 - s.0 + 1 < COMPACT_SMALL_OPS {
            cur.push(s);
        } else if !cur.is_empty() {
            runs.push(std::mem::take(&mut cur));
        }
    }
    if !cur.is_empty() {
        runs.push(cur);
    }
    let locations: Vec<(String, u64)> = conn
        .prepare_cached("SELECT location, uploaded FROM sync2_locations WHERE profile_uid = ?1")
        .map_err(sql)?
        .query_map([&local.profile], |r| Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)? as u64)))
        .map_err(sql)?
        .collect::<Result<_, _>>()
        .map_err(sql)?;
    for run in runs.into_iter().filter(|r| r.len() >= COMPACT_MIN_RUN) {
        let (first, last) = (run[0].0, run[run.len() - 1].1);
        let mut ops = Vec::with_capacity((last - first + 1) as usize);
        for seq in first..=last {
            ops.push(load_op(conn, &local.profile, &OpId { device: local.device, seq })?.ok_or("missing local op")?);
        }
        let merged: Vec<(u64, u64)> = segment::split_ranges(&ops)
            .into_iter()
            .map(|(a, b)| (ops[a].id.seq, ops[b - 1].id.seq))
            .collect();
        if merged.len() >= run.len() {
            continue;
        }
        for (a, b) in &run {
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
        for (a, b) in &merged {
            conn.execute(
                "INSERT INTO sync2_segments (profile_uid, device, first, last) VALUES (?1, ?2, ?3, ?4)",
                params![local.profile, local.device.0.to_vec(), *a as i64, *b as i64],
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

/// 应用一条已校验、因果已满足的远端操作。
fn apply_remote(conn: &Connection, profile: &str, op: &Op, chain: &Chain, now: i64, t: &mut Touched) -> Result<(), String> {
    insert_op(conn, profile, op, chain, now)?;
    conn.execute(
        "UPDATE sync2_devices SET applied = ?3, chain = ?4 WHERE profile_uid = ?1 AND device = ?2",
        params![profile, op.id.device.0.to_vec(), op.id.seq as i64, chain.to_vec()],
    )
    .map_err(sql)?;
    project(conn, profile, op, now, true, t)
}

/// 本机身份分叉（设计 §7.3）：换新身份，把旧身份 seq > [keep] 的本机操作撤出投影、以新身份重签发
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

/// 因果投递：反复扫缓冲，能接上的（seq = applied + 1、链接得上、依赖都已应用）就应用。返回应用条数。
fn deliver(c: &Connection, profile: &str, now: i64, t: &mut Touched) -> Result<usize, String> {
    let mut applied_n = 0usize;
    loop {
        let mut progress = false;
        let vv = applied_vv(c, profile)?;
        let rows: Vec<(Vec<u8>, i64, Vec<u8>, Vec<u8>)> = c
            .prepare_cached("SELECT device, seq, op, chain FROM sync2_pending WHERE profile_uid = ?1 ORDER BY device, seq")
            .map_err(sql)?
            .query_map([profile], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)))
            .map_err(sql)?
            .collect::<Result<_, _>>()
            .map_err(sql)?;
        let mut vv = vv;
        for (dev, seq, opb, chb) in rows {
            let device = Id(dev.clone().try_into().map_err(|_| "bad device")?);
            let seq = seq as u64;
            let have = vv.get(&device);
            if seq <= have {
                // 已有：同一 seq 链值不同 = 那台设备的身份分叉了（它自己会换身份重签发）。
                if chain_at(c, profile, &device, seq)?.map(|x| x.to_vec()) != Some(chb.clone()) {
                    c.execute(
                        "UPDATE sync2_devices SET warning = 'fork' WHERE profile_uid = ?1 AND device = ?2",
                        params![profile, dev],
                    )
                    .map_err(sql)?;
                }
                c.execute(
                    "DELETE FROM sync2_pending WHERE profile_uid = ?1 AND device = ?2 AND seq = ?3",
                    params![profile, dev, seq as i64],
                )
                .map_err(sql)?;
                continue;
            }
            if seq != have + 1 {
                continue;
            }
            let op = Op::read(&mut Reader::new(&opb)).map_err(|e| e.to_string())?;
            let chain: Chain = chb.clone().try_into().map_err(|_| "bad chain")?;
            let prev = chain_at(c, profile, &device, seq - 1)?.unwrap_or(CHAIN_ZERO);
            if chain_next(&prev, &op) != chain {
                // 接不上本机已有的前缀：那台设备分叉过，这一支不收。
                c.execute(
                    "UPDATE sync2_devices SET warning = 'fork' WHERE profile_uid = ?1 AND device = ?2",
                    params![profile, dev],
                )
                .map_err(sql)?;
                c.execute(
                    "DELETE FROM sync2_pending WHERE profile_uid = ?1 AND device = ?2 AND seq >= ?3",
                    params![profile, dev, seq as i64],
                )
                .map_err(sql)?;
                continue;
            }
            if !op.deps.le(&vv) {
                continue;
            }
            apply_remote(c, profile, &op, &chain, now, t)?;
            c.execute(
                "DELETE FROM sync2_pending WHERE profile_uid = ?1 AND device = ?2 AND seq = ?3",
                params![profile, dev, seq as i64],
            )
            .map_err(sql)?;
            vv.set(device, seq);
            applied_n += 1;
            progress = true;
        }
        if !progress {
            break;
        }
    }
    Ok(applied_n)
}

impl SrsCore {
    /// 发件：本设备还没上传到 [location] 的段（文件相对路径 → 字节）。段切点在第一次发件时定下，
    /// 各位置拿到同样的段；[key] = 该位置开了加密时的集合密钥。返回 `(段, 发到的最大 seq)`。
    pub fn sync2_outbox(&self, profile: &str, location: &str, key: Option<[u8; 32]>) -> Result<(Vec<(String, Vec<u8>)>, u64), String> {
        let w = self.writer()?;
        in_savepoint(&w, |c| {
            let local = Local::load(c, profile)?.ok_or("sync2 not initialised for this profile")?;
            cut_segments(c, &local)?;
            compact_segments(c, &local)?;
            let cuts = cut_segments(c, &local)?;
            let uploaded: u64 = c
                .query_row(
                    "SELECT uploaded FROM sync2_locations WHERE profile_uid = ?1 AND location = ?2",
                    params![profile, location],
                    |r| r.get::<_, i64>(0),
                )
                .optional()
                .map_err(sql)?
                .unwrap_or(0) as u64;
            let ck = key.map(CollectionKey);
            let mut out = Vec::new();
            let mut top = uploaded;
            // 清除（§10.5）改写过的本机段：已经传过也要重传（同名覆盖；链值不变，名字不变）。
            let rewrites: BTreeSet<u64> = c
                .prepare_cached("SELECT first FROM sync2_rewrites WHERE profile_uid = ?1 AND location = ?2")
                .map_err(sql)?
                .query_map(params![profile, location], |r| Ok(r.get::<_, i64>(0)? as u64))
                .map_err(sql)?
                .collect::<Result<_, _>>()
                .map_err(sql)?;
            for (first, last) in cuts {
                if last <= uploaded && !rewrites.contains(&first) {
                    continue;
                }
                let mut ops = Vec::with_capacity((last - first + 1) as usize);
                for seq in first..=last {
                    ops.push(load_op(c, profile, &OpId { device: local.device, seq })?.ok_or("missing local op")?);
                }
                let prev = chain_at(c, profile, &local.device, first - 1)?.ok_or("missing chain")?;
                let (h, bytes) = segment::pack(local.collection, &ops, prev, &local.key, ck.as_ref())?;
                out.push((format!("devices/{}/{}", local.device.text(), h.file_name()), bytes));
                top = top.max(last);
            }
            Ok((out, top))
        })
    }

    /// 写 head（段都传完之后）：[upto] = 已传到该位置的最大 seq。返回 `(相对路径, 字节, gen)`。
    pub fn sync2_head(&self, profile: &str, location: &str, upto: u64, now: i64) -> Result<(String, Vec<u8>, u64, Vec<String>), String> {
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
            local.head_gen += 1;
            let digest: Option<String> = c
                .query_row("SELECT value FROM srs_meta WHERE key = ?1", [format!("sync2_digest/{profile}")], |r| r.get(0))
                .optional()
                .map_err(sql)?;
            let head = Head {
                gen: local.head_gen,
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
            let bytes = head.encode(&local.key);
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
            Ok((format!("devices/{}/{}", local.device.text(), head.file_name()), bytes, head.gen, obsolete))
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
    /// `{"events":[落进投影的事件], "dominated":[..], "replayed":[..], "applied":n, "pending":n, "errors":[..], "fork":bool}`。
    pub fn sync2_ingest(&self, profile: &str, segments: &[Vec<u8>], key: Option<[u8; 32]>, now: i64) -> Result<String, String> {
        let w = self.writer()?;
        in_savepoint(&w, |c| {
            let local = Local::load(c, profile)?.ok_or("sync2 not initialised for this profile")?;
            let ck = key.map(CollectionKey);
            let mut t = Touched::default();
            let mut errors = Vec::new();
            let mut fork_at: Option<u64> = None;
            for bytes in segments {
                let header = match segment::peek_header(bytes) {
                    Ok(h) => h,
                    Err(e) => {
                        errors.push(e.to_string());
                        continue;
                    }
                };
                if header.collection != local.collection {
                    continue;
                }
                let public: Option<Vec<u8>> = c
                    .query_row(
                        "SELECT public FROM sync2_devices WHERE profile_uid = ?1 AND device = ?2",
                        params![profile, header.device.0.to_vec()],
                        |r| r.get(0),
                    )
                    .optional()
                    .map_err(sql)?
                    .flatten();
                // 自己身份的段：同一把钥匙签的（数据目录被复制）才可能是本机身份的另一个安装，只拿来比链找分叉点。
                let public: [u8; 32] = if header.device == local.device {
                    local.key.public()
                } else {
                    match public.and_then(|p| <[u8; 32]>::try_from(p).ok()) {
                        Some(p) => p,
                        None => {
                            errors.push(format!("segment from unknown device {}", header.device.text()));
                            continue;
                        }
                    }
                };
                let seg = match segment::open(bytes, &public, ck.as_ref()) {
                    Ok(s) => s,
                    Err(e) => {
                        errors.push(format!("{}: {e}", header.device.text()));
                        continue;
                    }
                };
                if header.device == local.device {
                    // 同一身份、签名也对（同一把钥匙 = 数据目录被复制）：逐条比链，第一处不同之前是共同前缀。
                    let mut chain = seg.header.prev_chain;
                    for op in &seg.ops {
                        chain = chain_next(&chain, op);
                        let ours = chain_at(c, profile, &local.device, op.id.seq)?;
                        if ours != Some(chain) {
                            let k = op.id.seq - 1;
                            fork_at = Some(fork_at.map_or(k, |f| f.min(k)));
                            break;
                        }
                    }
                    continue;
                }
                let mut chain = seg.header.prev_chain;
                for op in &seg.ops {
                    chain = chain_next(&chain, op);
                    c.prepare_cached(
                        "INSERT OR IGNORE INTO sync2_pending (profile_uid, device, seq, op, chain) VALUES (?1, ?2, ?3, ?4, ?5)",
                    )
                    .map_err(sql)?
                    .execute(params![profile, op.id.device.0.to_vec(), op.id.seq as i64, op.encode(), chain.to_vec()])
                    .map_err(sql)?;
                }
            }
            let applied_n = deliver(c, profile, now, &mut t)?;
            let fork = fork_at.is_some();
            if let Some(k) = fork_at {
                rotate(c, profile, k, now, &mut t)?;
            }
            let replayed = replay_touched(c, profile, &t)?;
            let pending: i64 = c
                .query_row("SELECT COUNT(*) FROM sync2_pending WHERE profile_uid = ?1", [profile], |r| r.get(0))
                .map_err(sql)?;
            Ok(json!({
                "events": t.events,
                "dominated": t.dominated,
                "replayed": replayed,
                "applied": applied_n,
                "pending": pending,
                "errors": errors,
                "fork": fork,
                "diagnostics": t.diagnostics,
                "changed": t.entities_changed.iter().map(|(k, e)| json!([k, e])).collect::<Vec<_>>(),
                "purged": t.purged.iter().map(|(k, e)| json!([k, e])).collect::<Vec<_>>(),
            })
            .to_string())
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
        let w = self.writer()?;
        in_savepoint(&w, |c| {
            let d = digest(c, profile)?;
            let vv = applied_vv(c, profile)?;
            let tagged = format!("{}@{}", d, vv.hash_hex());
            c.execute(
                "INSERT INTO srs_meta (key, value) VALUES (?1, ?2) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                params![format!("sync2_digest/{profile}"), tagged],
            )
            .map_err(sql)?;
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

impl SrsCore {
    /// 手动导出：全部操作（含已清除内容的骨架）+ 各设备公钥。
    pub fn sync2_export(&self, profile: &str) -> Result<Vec<u8>, String> {
        let w = self.writer()?;
        in_savepoint(&w, |c| {
            let local = Local::load(c, profile)?.ok_or("sync2 not initialised for this profile")?;
            let mut out = crate::sync2::codec::Writer::new();
            out.raw(EXPORT_MAGIC);
            out.u8(1);
            local.collection.write(&mut out);
            let devices: Vec<(Vec<u8>, Option<Vec<u8>>, i64)> = c
                .prepare("SELECT device, public, applied FROM sync2_devices WHERE profile_uid = ?1 ORDER BY device")
                .map_err(sql)?
                .query_map([profile], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
                .map_err(sql)?
                .collect::<Result<_, _>>()
                .map_err(sql)?;
            out.uv(devices.len() as u64);
            for (dev, public, applied) in devices {
                let device = Id(dev.clone().try_into().map_err(|_| "bad device")?);
                device.write(&mut out);
                out.bytes(&public.unwrap_or_default());
                out.uv(applied as u64);
                for seq in 1..=applied as u64 {
                    let op = load_op(c, profile, &OpId { device, seq })?.ok_or("missing op in export")?;
                    out.bytes(&op.encode());
                }
            }
            Ok(ruzstd::encoding::compress_to_vec(&out.into_vec()[..], ruzstd::encoding::CompressionLevel::Fastest))
        })
    }

    /// 导入 `.fushisrs`：操作并入（不覆盖）。包里有本机身份的操作时先换身份（§7.3：包可能来自本设备
    /// 更早的自己或它的克隆），共同前缀之后的本机操作以新身份重签发。返回与 ingest 同形的结果。
    pub fn sync2_import(&self, profile: &str, bytes: &[u8], now: i64) -> Result<String, String> {
        let plain = crate::zstd_decompress(bytes)?;
        let mut r = Reader::new(&plain);
        if r.raw(8).map_err(|e| e.to_string())? != EXPORT_MAGIC {
            return Err("not a .fushisrs file".into());
        }
        if r.u8().map_err(|e| e.to_string())? != 1 {
            return Err("unsupported .fushisrs version".into());
        }
        let collection = Id::read(&mut r).map_err(|e| e.to_string())?;
        let n = r.uv().map_err(|e| e.to_string())?;
        let mut runs: Vec<(Id, Vec<u8>, Vec<Op>)> = Vec::new();
        for _ in 0..n {
            let device = Id::read(&mut r).map_err(|e| e.to_string())?;
            let public = r.bytes().map_err(|e| e.to_string())?.to_vec();
            let count = r.uv().map_err(|e| e.to_string())?;
            let mut ops = Vec::new();
            for seq in 1..=count {
                let op = Op::read(&mut Reader::new(r.bytes().map_err(|e| e.to_string())?)).map_err(|e| e.to_string())?;
                if op.id.device != device || op.id.seq != seq {
                    return Err("corrupt .fushisrs (op order)".into());
                }
                ops.push(op);
            }
            runs.push((device, public, ops));
        }
        let w = self.writer()?;
        in_savepoint(&w, |c| {
            let local = match Local::load(c, profile)? {
                Some(l) => l,
                None => Local::create(c, profile, now)?,
            };
            if collection != local.collection {
                return Err("this .fushisrs belongs to another profile".into());
            }
            let mut t = Touched::default();
            // 本机身份：找共同前缀，有分歧或包里更长就换身份。
            if let Some((_, _, ops)) = runs.iter().find(|(d, _, _)| *d == local.device) {
                let mut chain = CHAIN_ZERO;
                let mut k = 0u64;
                for op in ops {
                    chain = chain_next(&chain, op);
                    if chain_at(c, profile, &local.device, op.id.seq)? == Some(chain) {
                        k = op.id.seq;
                    } else {
                        break;
                    }
                }
                // 包是本机更早的前缀（全部对得上）不用换；有分歧或包里更长（另一个安装接着写过）才换。
                if k < ops.len() as u64 {
                    rotate(c, profile, k, now, &mut t)?;
                }
            }
            for (device, public, ops) in &runs {
                c.execute(
                    "INSERT INTO sync2_devices (profile_uid, device, public, applied) VALUES (?1, ?2, ?3, 0) \
                     ON CONFLICT(profile_uid, device) DO UPDATE SET public = COALESCE(sync2_devices.public, excluded.public)",
                    params![profile, device.0.to_vec(), if public.is_empty() { None } else { Some(public.clone()) }],
                )
                .map_err(sql)?;
                let mut chain = CHAIN_ZERO;
                for op in ops {
                    chain = chain_next(&chain, op);
                    c.prepare_cached(
                        "INSERT OR IGNORE INTO sync2_pending (profile_uid, device, seq, op, chain) VALUES (?1, ?2, ?3, ?4, ?5)",
                    )
                    .map_err(sql)?
                    .execute(params![profile, device.0.to_vec(), op.id.seq as i64, op.encode(), chain.to_vec()])
                    .map_err(sql)?;
                }
            }
            let applied = deliver(c, profile, now, &mut t)?;
            let replayed = replay_touched(c, profile, &t)?;
            let pending: i64 = c
                .query_row("SELECT COUNT(*) FROM sync2_pending WHERE profile_uid = ?1", [profile], |r| r.get(0))
                .map_err(sql)?;
            Ok(json!({
                "events": t.events,
                "dominated": t.dominated,
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
