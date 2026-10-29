//! 段 / head 转发（设计 §6.3「对端之间做反熵」；2026-10-29 审查 S-1）。
//!
//! 以前每台设备只往位置上发**本机身份**的段。拓扑不是全连通时就永久卡住：手机只经互联连台式机、台式机与笔记本
//! 走网盘，笔记本永远拿不到手机的段；而台式机此后的每条操作的上下文（`deps` = 台式机已应用的整个版本向量）都含
//! 手机的 seq，笔记本因果投递不了，在 `sync2_pending` 里无界堆积。
//!
//! 现在每台设备把**本机持有、而某个位置缺**的别的设备的段与 head 原样搬过去：
//! - head 是作者签名的明文 JSON，与位置无关，原文照写（同名同内容，作者自己也写这个位置也不冲突）；
//! - 段的签名覆盖的是「段头 || 段体（可能是那个位置的密文）」，转发者没法换密钥重签，所以搬的是作者签名的原文
//!   连同（原段体是密文时）解开的明文压缩体，装成转发件（segment.rs `RELAY_MAGIC`），放在 `rly-` 前缀的同名文件里；
//!   目标位置加密时转发件整个用目标位置的密钥封装。读者照样用作者公钥验签、用签名担保的哈希链验操作——转发者
//!   伪造不了任何东西，也不需要源位置的密钥。
//!
//! 记账（都在本机库里）：
//! - `sync2_relay_heads`：每台别的设备见过的最新 head（任何位置上的），转发就发它；
//! - `sync2_location_heads`：每个位置上一轮看到的各设备 head（序号与段名），判断那个位置缺什么；
//! - `sync2_relay_segs`：收段时顺手留下的原段，**只留还有位置缺的**，转发完就删；
//! - `sync2_relay_out`：本机转发到各位置的文件，免得重传、也用来清理被新 head 取代的旧转发件。
//!
//! 一个位置缺的段本机还没有原文时（它们早就应用过、当时没留），看那个设备最新 head 的位置的 `plan` 会把它们列进
//! 要拉的段（只为转发，不重复应用），下一轮就能转发。

use std::collections::{BTreeMap, BTreeSet};

use rusqlite::{params, Connection, OptionalExtension};
use serde_json::{json, Value};

use super::{in_savepoint, sql, Local};
use crate::store::SrsCore;
use crate::sync2::id::Id;
use crate::sync2::keys::CollectionKey;
use crate::sync2::segment::{self, Head, SegmentHeader};

/// 多久没成功同步过的位置不再算转发目标（换过密钥 / 被移除的位置留下的旧进度行，不让它们永远「缺」）。
const ACTIVE_WINDOW_MS: i64 = 30 * 24 * 60 * 60 * 1000;

fn names_of(h: &Head) -> String {
    serde_json::to_string(&h.segment_files()).unwrap_or_else(|_| "[]".to_owned())
}

fn parse_names(s: &str) -> BTreeSet<String> {
    serde_json::from_str::<Vec<String>>(s).unwrap_or_default().into_iter().collect()
}

fn id_of(b: Vec<u8>) -> Result<Id, String> {
    Ok(Id(b.try_into().map_err(|_| "bad id blob".to_string())?))
}

/// 转发目标：本机同步的全部位置里最近 [ACTIVE_WINDOW_MS] 内成功过的（还没成功过的也算）。
fn active_locations(c: &Connection, profile: &str) -> Result<Vec<String>, String> {
    let rows: Vec<(String, Option<i64>)> = c
        .prepare_cached("SELECT location, last_ok FROM sync2_locations WHERE profile_uid = ?1")
        .map_err(sql)?
        .query_map([profile], |r| Ok((r.get(0)?, r.get(1)?)))
        .map_err(sql)?
        .collect::<Result<_, _>>()
        .map_err(sql)?;
    let newest = rows.iter().filter_map(|r| r.1).max().unwrap_or(0);
    Ok(rows.into_iter().filter(|(_, ok)| ok.is_none_or(|t| t >= newest - ACTIVE_WINDOW_MS)).map(|(l, _)| l).collect())
}

/// 一台设备的转发源 head：`(代号, 序号, 段名)`。
fn relay_head(c: &Connection, profile: &str, device: &Id) -> Result<Option<(u64, u64, BTreeSet<String>)>, String> {
    Ok(c
        .prepare_cached("SELECT gen, seq, segments FROM sync2_relay_heads WHERE profile_uid = ?1 AND device = ?2")
        .map_err(sql)?
        .query_row(params![profile, device.0.to_vec()], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, i64>(1)?, r.get::<_, String>(2)?)))
        .optional()
        .map_err(sql)?
        .map(|(g, s, n)| (g as u64, s as u64, parse_names(&n))))
}

/// [location] 上 [device] 已有的段（上一轮看到的 head 引用的 + 本机转发上去的）与那份 head 的序号。
fn present_at(c: &Connection, profile: &str, location: &str, device: &Id) -> Result<(u64, BTreeSet<String>), String> {
    let (seq, mut names) = c
        .prepare_cached("SELECT seq, segments FROM sync2_location_heads WHERE profile_uid = ?1 AND location = ?2 AND device = ?3")
        .map_err(sql)?
        .query_row(params![profile, location, device.0.to_vec()], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?)))
        .optional()
        .map_err(sql)?
        .map_or((0, BTreeSet::new()), |(s, n)| (s as u64, parse_names(&n)));
    let out: Vec<String> = c
        .prepare_cached("SELECT name FROM sync2_relay_out WHERE profile_uid = ?1 AND location = ?2 AND device = ?3")
        .map_err(sql)?
        .query_map(params![profile, location, device.0.to_vec()], |r| r.get(0))
        .map_err(sql)?
        .collect::<Result<_, _>>()
        .map_err(sql)?;
    names.extend(out);
    Ok((seq, names))
}

/// 还有没有位置缺 [device] 的段 [name]（它在转发源 head 里，而某个活跃位置上那台设备的 head 落后、也没有这个段）。
fn needed(c: &Connection, profile: &str, locations: &[String], device: &Id, name: &str) -> Result<bool, String> {
    let Some((_, seq, names)) = relay_head(c, profile, device)? else { return Ok(false) };
    if !names.contains(name) {
        return Ok(false);
    }
    for l in locations {
        let (have, present) = present_at(c, profile, l, device)?;
        if have < seq && !present.contains(name) {
            return Ok(true);
        }
    }
    Ok(false)
}

/// 本机自己（含冻结的旧身份）与被标为不可信的设备不转发。
fn relayable(c: &Connection, profile: &str, local: &Local, device: &Id) -> Result<bool, String> {
    if *device == local.device {
        return Ok(false);
    }
    let frozen: Option<i64> = c
        .prepare_cached("SELECT frozen FROM sync2_devices WHERE profile_uid = ?1 AND device = ?2")
        .map_err(sql)?
        .query_row(params![profile, device.0.to_vec()], |r| r.get(0))
        .optional()
        .map_err(sql)?;
    Ok(frozen == Some(0))
}

/// 看 head 时（[heads] = 这一轮这个位置上各设备最新的、已验签可信的 head 与原文）：更新转发源 head；给了
/// [location] 就把这个位置上的 head 记成「它此刻有什么」。返回只为转发要额外拉的段（按设备分组的段名）。
pub(crate) fn note_heads(
    c: &Connection,
    profile: &str,
    local: &Local,
    location: Option<&str>,
    heads: &[(&Head, &[u8])],
) -> Result<BTreeMap<Id, Vec<String>>, String> {
    for (h, bytes) in heads {
        if h.device == local.device {
            continue;
        }
        let changed = c
            .prepare_cached(
                "INSERT INTO sync2_relay_heads (profile_uid, device, gen, seq, segments, bytes) VALUES (?1, ?2, ?3, ?4, ?5, ?6) \
                 ON CONFLICT(profile_uid, device) DO UPDATE SET gen = excluded.gen, seq = excluded.seq, \
                 segments = excluded.segments, bytes = excluded.bytes WHERE excluded.gen > sync2_relay_heads.gen",
            )
            .map_err(sql)?
            .execute(params![profile, h.device.0.to_vec(), h.gen as i64, h.seq as i64, names_of(h), bytes])
            .map_err(sql)?;
        if changed > 0 {
            prune(c, profile, &h.device)?;
        }
    }
    let Some(location) = location else { return Ok(BTreeMap::new()) };
    // 这个位置此刻有什么以这一轮看到的为准（被外部清掉的 head 不再算在）。本机转发上去的 head 已经看不到了（被删 /
    // 列目录还没跟上）：这个位置上本机的转发记账作废，缺的下次重传。
    let seen: BTreeMap<Id, u64> = heads.iter().filter(|(h, _)| h.device != local.device).map(|(h, _)| (h.device, h.gen)).collect();
    let relayed: Vec<(Vec<u8>, i64)> = c
        .prepare_cached(
            "SELECT device, MAX(gen) FROM sync2_relay_out WHERE profile_uid = ?1 AND location = ?2 AND name LIKE 'head-%' GROUP BY device",
        )
        .map_err(sql)?
        .query_map(params![profile, location], |r| Ok((r.get(0)?, r.get(1)?)))
        .map_err(sql)?
        .collect::<Result<_, _>>()
        .map_err(sql)?;
    for (d, g) in relayed {
        let device = id_of(d)?;
        if seen.get(&device).copied().unwrap_or(0) < g as u64 {
            c.execute(
                "DELETE FROM sync2_relay_out WHERE profile_uid = ?1 AND location = ?2 AND device = ?3",
                params![profile, location, device.0.to_vec()],
            )
            .map_err(sql)?;
        }
    }
    c.execute("DELETE FROM sync2_location_heads WHERE profile_uid = ?1 AND location = ?2", params![profile, location]).map_err(sql)?;
    for (h, _) in heads.iter().filter(|(h, _)| h.device != local.device) {
        c.prepare_cached(
            "INSERT OR REPLACE INTO sync2_location_heads (profile_uid, location, device, gen, seq, segments) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
        )
        .map_err(sql)?
        .execute(params![profile, location, h.device.0.to_vec(), h.gen as i64, h.seq as i64, names_of(h)])
        .map_err(sql)?;
    }
    relay_fetch(c, profile, local, heads)
}

/// [note_heads] 这一次什么都不会改（各设备的转发源 head 不比这些旧、这个位置上记的 head 与这一轮看到的相同、本机转发
/// 上去的 head 都还看得到）：`plan` 的只读快路径据此不拿写锁（审查 S-8）。
pub(crate) fn heads_noted(c: &Connection, profile: &str, local: &Local, location: Option<&str>, heads: &[(&Head, &[u8])]) -> Result<bool, String> {
    for (h, _) in heads.iter().filter(|(h, _)| h.device != local.device) {
        if relay_head(c, profile, &h.device)?.is_none_or(|(g, _, _)| g < h.gen) {
            return Ok(false);
        }
    }
    let Some(location) = location else { return Ok(true) };
    let seen: BTreeMap<Id, u64> = heads.iter().filter(|(h, _)| h.device != local.device).map(|(h, _)| (h.device, h.gen)).collect();
    let relayed: Vec<(Vec<u8>, i64)> = c
        .prepare_cached(
            "SELECT device, MAX(gen) FROM sync2_relay_out WHERE profile_uid = ?1 AND location = ?2 AND name LIKE 'head-%' GROUP BY device",
        )
        .map_err(sql)?
        .query_map(params![profile, location], |r| Ok((r.get(0)?, r.get(1)?)))
        .map_err(sql)?
        .collect::<Result<_, _>>()
        .map_err(sql)?;
    for (d, g) in relayed {
        if seen.get(&id_of(d)?).copied().unwrap_or(0) < g as u64 {
            return Ok(false);
        }
    }
    let have: BTreeMap<Vec<u8>, (i64, i64, String)> = c
        .prepare_cached("SELECT device, gen, seq, segments FROM sync2_location_heads WHERE profile_uid = ?1 AND location = ?2")
        .map_err(sql)?
        .query_map(params![profile, location], |r| Ok((r.get::<_, Vec<u8>>(0)?, (r.get(1)?, r.get(2)?, r.get(3)?))))
        .map_err(sql)?
        .collect::<Result<_, _>>()
        .map_err(sql)?;
    let want: BTreeMap<Vec<u8>, (i64, i64, String)> = heads
        .iter()
        .filter(|(h, _)| h.device != local.device)
        .map(|(h, _)| (h.device.0.to_vec(), (h.gen as i64, h.seq as i64, names_of(h))))
        .collect();
    Ok(have == want)
}

/// 这个位置上就是某设备最新的 head：别的位置缺、本机又没留原文的段，从这里拉（只为转发）。只读。
pub(crate) fn relay_fetch(c: &Connection, profile: &str, local: &Local, heads: &[(&Head, &[u8])]) -> Result<BTreeMap<Id, Vec<String>>, String> {
    let locations = active_locations(c, profile)?;
    let mut fetch: BTreeMap<Id, Vec<String>> = BTreeMap::new();
    for (h, _) in heads {
        if !relayable(c, profile, local, &h.device)? {
            continue;
        }
        if relay_head(c, profile, &h.device)?.is_none_or(|(g, _, _)| g != h.gen) {
            continue;
        }
        for name in h.segment_files() {
            if held(c, profile, &h.device, &name)? || !needed(c, profile, &locations, &h.device, &name)? {
                continue;
            }
            fetch.entry(h.device).or_default().push(name);
        }
    }
    Ok(fetch)
}

fn held(c: &Connection, profile: &str, device: &Id, name: &str) -> Result<bool, String> {
    Ok(c
        .prepare_cached("SELECT 1 FROM sync2_relay_segs WHERE profile_uid = ?1 AND device = ?2 AND name = ?3")
        .map_err(sql)?
        .query_row(params![profile, device.0.to_vec(), name], |_| Ok(()))
        .optional()
        .map_err(sql)?
        .is_some())
}

/// 收段时（[bytes] 已验过签名与链）：别的设备的段若还有位置缺它，留下原文（[key] = 它所在位置的密钥，用来解出
/// 密文原段的明文压缩体）。
pub(crate) fn keep(c: &Connection, profile: &str, local: &Local, header: &SegmentHeader, bytes: &[u8], key: Option<&CollectionKey>) -> Result<(), String> {
    if !relayable(c, profile, local, &header.device)? {
        return Ok(());
    }
    let name = header.file_name();
    if held(c, profile, &header.device, &name)? || !needed(c, profile, &active_locations(c, profile)?, &header.device, &name)? {
        return Ok(());
    }
    let (orig, plain) = segment::relay_parts(bytes, key).map_err(|e| e.to_string())?;
    c.prepare_cached("INSERT OR IGNORE INTO sync2_relay_segs (profile_uid, device, name, orig, plain) VALUES (?1, ?2, ?3, ?4, ?5)")
        .map_err(sql)?
        .execute(params![profile, header.device.0.to_vec(), name, orig, plain])
        .map_err(sql)?;
    Ok(())
}

/// 删掉 [device] 不再有位置需要的原段。
fn prune(c: &Connection, profile: &str, device: &Id) -> Result<(), String> {
    let names: Vec<String> = c
        .prepare_cached("SELECT name FROM sync2_relay_segs WHERE profile_uid = ?1 AND device = ?2")
        .map_err(sql)?
        .query_map(params![profile, device.0.to_vec()], |r| r.get(0))
        .map_err(sql)?
        .collect::<Result<_, _>>()
        .map_err(sql)?;
    let locations = active_locations(c, profile)?;
    for n in names {
        if !needed(c, profile, &locations, device, &n)? {
            c.prepare_cached("DELETE FROM sync2_relay_segs WHERE profile_uid = ?1 AND device = ?2 AND name = ?3")
                .map_err(sql)?
                .execute(params![profile, device.0.to_vec(), n])
                .map_err(sql)?;
        }
    }
    Ok(())
}

/// [SrsCore::sync2_relay_outbox] 的一批。
pub struct RelayBatch {
    /// 要写到位置上的文件（相对路径 → 字节）：转发件，或段都已到位的设备的 head 原文。
    pub files: Vec<(String, Vec<u8>)>,
    /// 预算到了、还有没给的：确认这一批后再取。
    pub more: bool,
}

/// 从相对路径 `devices/<设备>/<文件>` 解出设备与文件名。
fn split_path(path: &str) -> Option<(Id, &str)> {
    let mut it = path.splitn(3, '/');
    (it.next()? == "devices").then_some(())?;
    let d = Id::parse(it.next()?)?;
    Some((d, it.next()?))
}

impl SrsCore {
    /// 转发发件（每轮自己的段与 head 写完之后）：[location] 缺的别的设备的段（装成转发件，[key] = 该位置的密钥）
    /// 与段都已到位的 head 原文，凑够 [max_bytes] 就停（一批至少一个文件）。head 只在它引用的段都已确认传上
    /// （[SrsCore::sync2_relay_ack]）之后才给，读者永远看到的是一致前缀。
    pub fn sync2_relay_outbox(&self, profile: &str, location: &str, key: Option<[u8; 32]>, max_bytes: u64) -> Result<RelayBatch, String> {
        let w = self.writer()?;
        in_savepoint(&w, |c| {
            let local = Local::load(c, profile)?.ok_or("sync2 not initialised for this profile")?;
            let ck = key.map(CollectionKey);
            let devices: Vec<(Vec<u8>, i64, i64, String, Vec<u8>)> = c
                .prepare_cached("SELECT device, gen, seq, segments, bytes FROM sync2_relay_heads WHERE profile_uid = ?1")
                .map_err(sql)?
                .query_map([profile], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?)))
                .map_err(sql)?
                .collect::<Result<_, _>>()
                .map_err(sql)?;
            let mut batch = RelayBatch { files: Vec::new(), more: false };
            let mut total: u64 = 0;
            'devices: for (d, _gen, seq, names, head_bytes) in devices {
                let device = id_of(d)?;
                if !relayable(c, profile, &local, &device)? {
                    continue;
                }
                let (have, present) = present_at(c, profile, location, &device)?;
                if have >= seq as u64 {
                    continue;
                }
                let wanted = parse_names(&names);
                let missing: Vec<&String> = wanted.iter().filter(|n| !present.contains(*n)).collect();
                // 缺的段本机得全都有原文，否则这台设备这一轮不转发（缺的由持有最新 head 的位置的 plan 补拉）。
                let mut parts = Vec::with_capacity(missing.len());
                for n in &missing {
                    let row: Option<(Vec<u8>, Option<Vec<u8>>)> = c
                        .prepare_cached("SELECT orig, plain FROM sync2_relay_segs WHERE profile_uid = ?1 AND device = ?2 AND name = ?3")
                        .map_err(sql)?
                        .query_row(params![profile, device.0.to_vec(), n], |r| Ok((r.get(0)?, r.get(1)?)))
                        .optional()
                        .map_err(sql)?;
                    match row {
                        Some(p) => parts.push((n.to_string(), p)),
                        None => continue 'devices,
                    }
                }
                let dir = format!("devices/{}", device.text());
                if parts.is_empty() {
                    let head = Head::decode(&head_bytes)?;
                    batch.files.push((format!("{dir}/{}", head.file_name()), head_bytes.clone()));
                    continue;
                }
                for (n, (orig, plain)) in parts {
                    if !batch.files.is_empty() && total.saturating_add(orig.len() as u64) > max_bytes {
                        batch.more = true;
                        break 'devices;
                    }
                    let bytes = segment::relay_pack(&orig, plain.as_deref(), ck.as_ref())?;
                    total += bytes.len() as u64;
                    batch.files.push((format!("{dir}/{}", segment::relay_file_name(&n)), bytes));
                }
                batch.more = true;
            }
            Ok(batch)
        })
    }

    /// 确认一批转发已经写到 [location]（[paths] = 那一批的相对路径）。返回 `{"delete": [相对路径]}`：被新转发的 head
    /// 取代的、本机之前转发到这个位置的旧 head 与旧转发件（归档位置由调用方跳过删除）。
    pub fn sync2_relay_ack(&self, profile: &str, location: &str, paths: &[String]) -> Result<Value, String> {
        let w = self.writer()?;
        in_savepoint(&w, |c| {
            let mut delete = Vec::new();
            for path in paths {
                let Some((device, file)) = split_path(path) else { continue };
                if let Some(rest) = file.strip_prefix("rly-") {
                    c.prepare_cached(
                        "INSERT OR IGNORE INTO sync2_relay_out (profile_uid, location, device, name, gen) VALUES (?1, ?2, ?3, ?4, 0)",
                    )
                    .map_err(sql)?
                    .execute(params![profile, location, device.0.to_vec(), format!("seg-{rest}")])
                    .map_err(sql)?;
                    continue;
                }
                let Some(gen) = segment::parse_head_file_name(file) else { continue };
                let Some(row) = c
                    .prepare_cached("SELECT gen, seq, segments FROM sync2_relay_heads WHERE profile_uid = ?1 AND device = ?2")
                    .map_err(sql)?
                    .query_row(params![profile, device.0.to_vec()], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, i64>(1)?, r.get::<_, String>(2)?)))
                    .optional()
                    .map_err(sql)?
                else {
                    continue;
                };
                if row.0 as u64 != gen {
                    continue;
                }
                let names = parse_names(&row.2);
                // 这个位置现在有这份 head 了（下一轮看 head 时以看到的为准）。
                c.prepare_cached(
                    "INSERT OR REPLACE INTO sync2_location_heads (profile_uid, location, device, gen, seq, segments) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                )
                .map_err(sql)?
                .execute(params![profile, location, device.0.to_vec(), row.0, row.1, row.2])
                .map_err(sql)?;
                // 本机之前转发的：旧 head 全删；上一份转发 head 之前就传上去、新 head 不再引用的旧转发件删（晚一代删：
                // 正读着上一份 head 的读者不至于扑空）。刚传的转发件记到这份 head 名下。
                let old: Vec<(String, i64)> = c
                    .prepare_cached("SELECT name, gen FROM sync2_relay_out WHERE profile_uid = ?1 AND location = ?2 AND device = ?3")
                    .map_err(sql)?
                    .query_map(params![profile, location, device.0.to_vec()], |r| Ok((r.get(0)?, r.get(1)?)))
                    .map_err(sql)?
                    .collect::<Result<_, _>>()
                    .map_err(sql)?;
                let prev_head = old.iter().filter(|(n, _)| n.starts_with("head-")).map(|(_, g)| *g).max().unwrap_or(0);
                let dir = format!("devices/{}", device.text());
                for (n, g) in &old {
                    let gone = if n.starts_with("head-") {
                        (*g as u64) < gen
                    } else {
                        !names.contains(n) && *g != 0 && *g < prev_head
                    };
                    if gone {
                        delete.push(format!("{dir}/{}", if n.starts_with("head-") { n.clone() } else { segment::relay_file_name(n) }));
                        c.prepare_cached("DELETE FROM sync2_relay_out WHERE profile_uid = ?1 AND location = ?2 AND device = ?3 AND name = ?4")
                            .map_err(sql)?
                            .execute(params![profile, location, device.0.to_vec(), n])
                            .map_err(sql)?;
                    }
                }
                c.prepare_cached("UPDATE sync2_relay_out SET gen = ?4 WHERE profile_uid = ?1 AND location = ?2 AND device = ?3 AND gen = 0")
                    .map_err(sql)?
                    .execute(params![profile, location, device.0.to_vec(), gen as i64])
                    .map_err(sql)?;
                c.prepare_cached(
                    "INSERT OR REPLACE INTO sync2_relay_out (profile_uid, location, device, name, gen) VALUES (?1, ?2, ?3, ?4, ?5)",
                )
                .map_err(sql)?
                .execute(params![profile, location, device.0.to_vec(), file, gen as i64])
                .map_err(sql)?;
                prune(c, profile, &device)?;
            }
            Ok(json!({"delete": delete}))
        })
    }
}
