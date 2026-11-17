//! 转发（G8-7b；设计 §4.4、§6.3「对端之间做反熵」，协议 3 `store/sync2/relay.rs` 的新代对应物）。
//!
//! 拓扑不是全连通时（手机只经互联连台式机、台式机与笔记本走网盘），每台设备只发本机身份的段会让笔记本永远拿不到手机
//! 的操作，而台式机此后每条操作的依赖都点着手机的 seq，笔记本的等待缓冲无界堆积。所以每台设备把**本机收到过、而某个
//! 位置缺**的别的设备的段与 head 搬过去：
//!
//! - 段：收段（`cmd/sync.rs` [super::sync::ingest]）时把作者签过的原生段（或别人转发来的中继件）重新包成**不封装**的
//!   中继件 `FRL4`（[wrap_relay4]，签名覆盖明文哈希，D16 A）存进 `relay_segs`；发到目标位置时再按目标位置的钥匙封装。
//!   读者照样拿作者公钥验签、拿签名担保的链验每一项——转发者伪造不了，也不需要源位置的钥匙。位置上的文件名
//!   `rly-<first>-<last>-<tag>.bin`，放在作者目录。
//! - head：`plan` 读到的别的设备的 head（作者自写的 `head-`，或别人转发来的 `rhd-`）按代号只进不退记进 `srs_meta`
//!   （`gen4_rhead/<col>/<设备>`，原文）。目标位置缺的段都已确认写上之后才转发这份 head（`rhd-<gen>-<tag>.json`：独立前缀，
//!   转发者永不覆盖作者在那个位置自写的 `head-`；被转发的 head 也不当位置证据，设计 §4.4）。读者的 `plan` 拿它认作者公钥、
//!   定要拉的段（Dart 拉 `seg-` 不在就拉同名 `rly-`）。
//!
//! # 什么时候存、存多久
//!
//! - 只有本机同步着 **≥ 2 个位置**（`loc_state` 的行数）才存：一个位置的设备没有可转发的目标。
//! - 只存作者受信（`trust` 没有行）、不是本机（当前或旧身份）的原生段。
//! - 每次确认转发（[relay_ack]）与读到 head（`plan` 调 [prune]）之后，删掉**每个**位置都已有的段：那个位置上作者的
//!   head 已覆盖到段尾、head 引用了它，或本机已转发过去。
//!
//! 已知边界（交接说明 G8-7b 一节）：本机在同步着 ≥ 2 个位置之前就收过的段没有原文可转发（协议 3 会让 `plan` 为转发补拉，
//! 新代不补）——这台设备的 head 在目标位置缺的段本机凑不齐时整台跳过（回包 `incomplete`），作者自己或别的持有原文的设备
//! 转发；作者之后的新段照常转发。

use std::collections::{BTreeMap, BTreeSet};

use rusqlite::{OptionalExtension, params};
use serde_json::{Value, json};

use super::Files;
use super::sync::{meta_get, meta_set};
use super::sync_oldroot::former_identities;
use crate::gen4::head::Head4;
use crate::gen4::location::{V4File, device_path, parse_v4_path, relay_head_name};
use crate::gen4::relay::{peek_relay4, wrap_relay4};
use crate::store::gen4::schema::sql;
use crate::store::gen4::truth::Truth;
use crate::sync2::id::Id;
use crate::sync2::keys::CollectionKey;
use crate::sync2::segment::{chain_tag, relay_file_name, segment_file_name};

/// 一批转发的字节预算（与发件同值，`cmd/sync.rs` `OUTBOX_BATCH_BYTES`）。
pub const RELAY_BATCH_BYTES: u64 = super::sync::OUTBOX_BATCH_BYTES;

/// 本机同步着的位置数（`loc_state` 主键前缀）。
pub(crate) const LOC_COUNT_SQL: &str = "SELECT COUNT(*) FROM loc_state WHERE col = ?1";

/// 本机同步着的位置（`loc_state` 主键前缀）。
pub(crate) const LOC_KEYS_SQL: &str =
    "SELECT loc_key FROM loc_state WHERE col = ?1 ORDER BY loc_key";

/// 存一份可转发的段（`relay_segs` 的唯一约束：同一作者同一区间同一链尾只存一份）。
pub(crate) const RELAY_PUT_SQL: &str = "INSERT OR IGNORE INTO relay_segs (col, device, first, last, tag, piece) \
     VALUES (?1, ?2, ?3, ?4, ?5, ?6)";

/// 取一份可转发的段（唯一约束的自动索引，等值点查）。
pub(crate) const RELAY_GET_SQL: &str = "SELECT piece FROM relay_segs \
     WHERE col = ?1 AND device = ?2 AND first = ?3 AND last = ?4 AND tag = ?5";

/// 一台作者存着的可转发段（唯一约束的自动索引，前缀区间）。
pub(crate) const RELAY_LIST_SQL: &str =
    "SELECT id, first, last, tag FROM relay_segs WHERE col = ?1 AND device = ?2";

/// 按行号删一份可转发段。
pub(crate) const RELAY_DROP_SQL: &str = "DELETE FROM relay_segs WHERE id = ?1";

/// 记下的被转发 head 的键区间（`srs_meta` 主键区间）。
pub(crate) const RHEAD_RANGE_SQL: &str =
    "SELECT key, value FROM srs_meta WHERE key >= ?1 AND key < ?2 ORDER BY key";

fn rhead_key(col: i64, device: &Id) -> String {
    format!("gen4_rhead/{col}/{}", device.text())
}

fn rhead_range(col: i64) -> (String, String) {
    (format!("gen4_rhead/{col}/"), format!("gen4_rhead/{col}0"))
}

fn str_req<'a>(req: &'a Value, k: &str) -> Result<&'a str, String> {
    req.get(k)
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .ok_or_else(|| format!("relay: missing {k}"))
}

fn location_count(t: &Truth<'_>, col: i64) -> Result<i64, String> {
    t.conn()
        .prepare_cached(LOC_COUNT_SQL)
        .map_err(sql)?
        .query_row([col], |r| r.get(0))
        .map_err(sql)
}

fn locations(t: &Truth<'_>, col: i64) -> Result<Vec<String>, String> {
    let mut stmt = t.conn().prepare_cached(LOC_KEYS_SQL).map_err(sql)?;
    let rows = stmt.query_map([col], |r| r.get(0)).map_err(sql)?;
    rows.collect::<rusqlite::Result<_>>().map_err(sql)
}

/// 这台设备的段 / head 可以由本机转发：不是本机（当前或旧身份）、受信。
fn relayable(t: &Truth<'_>, col: i64, device: &Id) -> Result<bool, String> {
    if t.self_identity(col)?.is_some_and(|s| s.device == *device) {
        return Ok(false);
    }
    if former_identities(t, col)?.contains(device) {
        return Ok(false);
    }
    Ok(t.trust_of(col, device)?.is_none())
}

/// 记下的这台设备最新的 head（[note_head]）。
fn stored_head(t: &Truth<'_>, col: i64, device: &Id) -> Result<Option<Head4>, String> {
    Ok(meta_get(t, &rhead_key(col, device))?.and_then(|s| Head4::decode(s.as_bytes()).ok()))
}

/// `plan` 读到一份验过的别的设备的 head：代号比记下的大就换（只进不退）。原文是规范 JSON（`Head4::decode` 只认规范
/// 形），按文本存。
pub(crate) fn note_head(t: &Truth<'_>, col: i64, h: &Head4, bytes: &[u8]) -> Result<(), String> {
    if !relayable(t, col, &h.device)? {
        return Ok(());
    }
    if stored_head(t, col, &h.device)?.is_some_and(|old| old.gen >= h.gen) {
        return Ok(());
    }
    let Ok(text) = std::str::from_utf8(bytes) else {
        return Ok(());
    };
    meta_set(t, &rhead_key(col, &h.device), text)
}

/// 收段时调：本机同步着 ≥ 2 个位置、作者可转发时，把这个已收下的原生段 / 中继件重新包成不封装的中继件存下。
/// 返回是否存了新的一份。[key] = 它所在位置的钥匙。
pub(crate) fn keep(
    t: &Truth<'_>,
    col: i64,
    bytes: &[u8],
    key: Option<&CollectionKey>,
) -> Result<bool, String> {
    if location_count(t, col)? < 2 {
        return Ok(false);
    }
    let header = if bytes.starts_with(crate::gen4::relay::MAGIC) {
        match peek_relay4(bytes) {
            Ok(p) => p.header,
            Err(_) => return Ok(false),
        }
    } else {
        match crate::gen4::segment::peek_native_header(bytes) {
            Ok(h) => h,
            Err(_) => return Ok(false),
        }
    };
    if !relayable(t, col, &header.device)? {
        return Ok(false);
    }
    let Some(public) = t.device_key(col, &header.device)? else {
        return Ok(false);
    };
    // 收段时已整段验过；这里再包一次（验签 + 链）只是 wrap 的约定，失败就不存（不影响收段本身）。
    let Ok(piece) = wrap_relay4(bytes, &public, key, None) else {
        return Ok(false);
    };
    let tag = chain_tag(&header.last_chain);
    t.write(|| {
        let n = t
            .conn()
            .prepare_cached(RELAY_PUT_SQL)
            .map_err(sql)?
            .execute(params![
                col,
                &header.device.0[..],
                i64::try_from(header.first).map_err(|_| "relay: seq out of range")?,
                i64::try_from(header.last).map_err(|_| "relay: seq out of range")?,
                tag,
                piece
            ])
            .map_err(sql)?;
        Ok(n > 0)
    })
}

/// 位置 [loc] 上作者 [device] 已有的段文件名（`seg-…` 形）：那里作者 head 引用的 + 本机转发过去的。与那份 head 的 seq。
fn present_at(
    t: &Truth<'_>,
    col: i64,
    loc: &str,
    device: &Id,
    sent: &BTreeSet<String>,
) -> Result<(u64, BTreeSet<String>), String> {
    let (seq, mut names) = match t.loc_head(col, loc, device)? {
        Some(h) => (h.seq, h.segs.into_iter().collect::<BTreeSet<_>>()),
        None => (0, BTreeSet::new()),
    };
    for n in sent {
        if let Some(rest) = n.strip_prefix("rly-") {
            names.insert(format!("seg-{rest}"));
        }
    }
    Ok((seq, names))
}

fn sent_names(t: &Truth<'_>, col: i64, loc: &str, device: &Id) -> Result<BTreeSet<String>, String> {
    Ok(t.relay_out(col, loc)?
        .into_iter()
        .filter(|r| r.device == *device && !r.gone)
        .map(|r| r.name)
        .collect())
}

fn piece_of(
    t: &Truth<'_>,
    col: i64,
    device: &Id,
    (first, last, tag): (u64, u64, &str),
) -> Result<Option<Vec<u8>>, String> {
    t.conn()
        .prepare_cached(RELAY_GET_SQL)
        .map_err(sql)?
        .query_row(
            params![
                col,
                &device.0[..],
                i64::try_from(first).map_err(|_| "relay: seq out of range")?,
                i64::try_from(last).map_err(|_| "relay: seq out of range")?,
                tag
            ],
            |r| r.get(0),
        )
        .optional()
        .map_err(sql)
}

/// 记下的全部被转发 head（设备 → head），解不开的跳过。
fn stored_heads(t: &Truth<'_>, col: i64) -> Result<BTreeMap<Id, Head4>, String> {
    let (lo, hi) = rhead_range(col);
    let rows: Vec<String> = {
        let mut stmt = t.conn().prepare_cached(RHEAD_RANGE_SQL).map_err(sql)?;
        let rows = stmt
            .query_map(params![lo, hi], |r| r.get::<_, String>(1))
            .map_err(sql)?;
        rows.collect::<rusqlite::Result<_>>().map_err(sql)?
    };
    Ok(rows
        .into_iter()
        .filter_map(|s| Head4::decode(s.as_bytes()).ok())
        .map(|h| (h.device, h))
        .collect())
}

/// `relay_outbox {profile, location, key?, maxBytes?}`（读快照）：位置 [location] 缺的别的设备的段（装成中继件，按
/// [key] 封装）与段都已到位的 head（`rhd-`），凑够 `maxBytes` 就停（一批至少一个文件）。文件在 [files]（路径相对
/// `v4/`）。回包 `{files: [路径], more, incomplete: [设备]}`：`more` = 还有没给的（含段确认之后才能给的 head），Dart
/// 写完这一批、[relay_ack] 之后再要下一批；`incomplete` = 位置缺的段本机凑不齐原文、这一轮跳过的作者。
pub fn relay_outbox(
    t: &Truth<'_>,
    col: i64,
    req: &Value,
    key: Option<&CollectionKey>,
    files: &mut Files,
) -> Result<Value, String> {
    let loc = str_req(req, "location")?;
    let budget = req
        .get("maxBytes")
        .and_then(Value::as_u64)
        .unwrap_or(RELAY_BATCH_BYTES)
        .max(1);
    let mut paths: Vec<String> = Vec::new();
    let mut incomplete: Vec<String> = Vec::new();
    let mut more = false;
    let mut total: u64 = 0;
    if location_count(t, col)? < 2 {
        return Ok(json!({"files": paths, "more": false, "incomplete": incomplete}));
    }
    'devices: for (device, h) in stored_heads(t, col)? {
        if !relayable(t, col, &device)? {
            continue;
        }
        let sent = sent_names(t, col, loc, &device)?;
        let (have, present) = present_at(t, col, loc, &device, &sent)?;
        let rhd = relay_head_name(&h);
        if have >= h.seq || sent.contains(&rhd) {
            continue;
        }
        let mut parts: Vec<(String, Vec<u8>)> = Vec::new();
        for (a, b, tag) in &h.segs {
            let name = segment_file_name(*a, *b, tag);
            if present.contains(&name) {
                continue;
            }
            match piece_of(t, col, &device, (*a, *b, tag))? {
                Some(p) => parts.push((name, p)),
                None => {
                    incomplete.push(device.text());
                    continue 'devices;
                }
            }
        }
        if parts.is_empty() {
            // 段都在了：给 head。
            let text = meta_get(t, &rhead_key(col, &device))?.unwrap_or_default();
            if !paths.is_empty() && total.saturating_add(text.len() as u64) > budget {
                more = true;
                break;
            }
            total += text.len() as u64;
            let path = device_path(&device, &rhd);
            files.push((path.clone(), text.into_bytes()));
            paths.push(path);
            continue;
        }
        for (name, piece) in parts {
            if !paths.is_empty() && total.saturating_add(piece.len() as u64) > budget {
                more = true;
                break 'devices;
            }
            let bytes = wrap_relay4(&piece, &h.public, None, key)
                .map_err(|e| format!("relay: stored piece of {device} unreadable: {e:?}"))?;
            total += bytes.len() as u64;
            let path = device_path(&device, &relay_file_name(&name));
            files.push((path.clone(), bytes));
            paths.push(path);
        }
        // 段确认之后下一批给 head。
        more = true;
    }
    Ok(json!({"files": paths, "more": more, "incomplete": incomplete}))
}

/// `relay_ack {profile, location, paths?, deleted?}`：`paths` = [relay_outbox] 那一批已写上的文件；`deleted` = 上一次回包
/// `delete` 里调用方已删掉（或归档位置按策略不删）的文件。记账：中继件按作者当前 head 的代号记进 `relay_out`；head 写上
/// 之后，这个位置上本机转发过的、不被新 head 引用的中继件与旧代号的 `rhd-` 改成待删。之后删掉每个位置都已有的
/// 可转发段（[prune]）。回包 `{delete: [路径相对 v4/]}` = 这个位置上全部待删的转发件（两段式删除：删好了再带
/// `deleted` 报回来才去掉记账）。
pub fn relay_ack(t: &Truth<'_>, col: i64, req: &Value) -> Result<Value, String> {
    let loc = str_req(req, "location")?;
    let list = |k: &str| -> Vec<String> {
        req.get(k)
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(Value::as_str)
            .map(str::to_owned)
            .collect()
    };
    for path in list("deleted") {
        if let Some((device, name)) = split(&path) {
            t.relay_deleted(col, loc, &device, &name)?;
        }
    }
    let heads = stored_heads(t, col)?;
    let mut touched: BTreeSet<Id> = BTreeSet::new();
    for path in list("paths") {
        let Some((device, name)) = split(&path) else {
            continue;
        };
        let Some(h) = heads.get(&device) else {
            continue;
        };
        match parse_v4_path(&path) {
            Some(V4File::Relay { .. }) => {
                t.relay_sent(col, loc, &device, &name, h.gen)?;
            }
            Some(V4File::RelayHead { gen, .. }) if gen == h.gen => {
                t.relay_sent(col, loc, &device, &name, gen)?;
                // 新 head 引用的中继件跟着换到新代号；剩下的（旧代号的 `rhd-`、不再被引用的中继件）待删。
                let wanted: BTreeSet<String> = h
                    .segment_files()
                    .iter()
                    .map(|s| relay_file_name(s))
                    .collect();
                for r in t.relay_out(col, loc)? {
                    if r.device == device && !r.gone && wanted.contains(&r.name) {
                        t.relay_sent(col, loc, &device, &r.name, gen)?;
                    }
                }
                t.relay_supersede(col, loc, &device, gen)?;
            }
            _ => continue,
        }
        touched.insert(device);
    }
    for device in &touched {
        prune(t, col, device)?;
    }
    let delete: Vec<String> = t
        .relay_gone(col, loc)?
        .into_iter()
        .map(|r| device_path(&r.device, &r.name))
        .collect();
    Ok(json!({"delete": delete}))
}

fn split(path: &str) -> Option<(Id, String)> {
    let mut it = path.splitn(3, '/');
    (it.next()? == "devices").then_some(())?;
    let d = Id::parse(it.next()?)?;
    let name = it.next()?;
    (!name.is_empty() && !name.contains('/')).then(|| (d, name.to_owned()))
}

/// 删掉作者 [device] 的、每个位置都已有的可转发段：那个位置上作者的 head 覆盖到了段尾或引用了它，或本机已转发过去。
/// 本机只剩 < 2 个位置时全部删（没有转发目标）。返回删了几份。
pub(crate) fn prune(t: &Truth<'_>, col: i64, device: &Id) -> Result<u64, String> {
    let rows: Vec<(i64, i64, i64, String)> = {
        let mut stmt = t.conn().prepare_cached(RELAY_LIST_SQL).map_err(sql)?;
        let rows = stmt
            .query_map(params![col, &device.0[..]], |r| {
                Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?))
            })
            .map_err(sql)?;
        rows.collect::<rusqlite::Result<_>>().map_err(sql)?
    };
    if rows.is_empty() {
        return Ok(0);
    }
    let locs = locations(t, col)?;
    let mut at: Vec<(u64, BTreeSet<String>)> = Vec::with_capacity(locs.len());
    for l in &locs {
        let sent = sent_names(t, col, l, device)?;
        at.push(present_at(t, col, l, device, &sent)?);
    }
    let mut dropped = 0u64;
    for (id, first, last, tag) in rows {
        let name = segment_file_name(first as u64, last as u64, &tag);
        let everywhere = locs.len() < 2
            || at
                .iter()
                .all(|(seq, names)| *seq >= last as u64 || names.contains(&name));
        if everywhere {
            t.write(|| {
                t.conn()
                    .prepare_cached(RELAY_DROP_SQL)
                    .map_err(sql)?
                    .execute([id])
                    .map_err(sql)
            })?;
            dropped += 1;
        }
    }
    Ok(dropped)
}
