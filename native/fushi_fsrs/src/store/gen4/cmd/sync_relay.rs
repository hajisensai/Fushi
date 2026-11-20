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
//! - 只有本机同步着 **≥ 2 个活跃位置**才存：一个位置的设备没有可转发的目标。活跃 = 新代里写过 head（`loc_state.last_ok`）
//!   且离最近一次成功不超过 30 天（[ACTIVE_WINDOW_MS]，协议 3 同口径）；不活跃的位置不算目标，prune 也不再等它。
//! - 只存作者受信（`trust` 没有行）、不是本机（当前或旧身份）的原生段。
//! - 每次确认转发（[relay_ack]）与读到 head（`plan` 调 [prune]）之后，删掉**每个**位置都已有的段：那个位置上作者的
//!   head 已覆盖到段尾、head 引用了它，或本机已转发过去。
//! - **彻底清除**（设计 §3.2「清除后原文不在本机」，交接 §26 C3 / §33 / §39）：作者签过的段改不出空洞，本机把一条别的
//!   设备的操作落成空洞时，由本机**重切**（`gen4/recut.rs` 的 `FRX4`：带作者的原签名，被挖掉的操作换成剔除项——作者签名
//!   覆盖的那部分 + 清掉它的 Purge，本机签名）代替原文转发——
//!   - 缓存里覆盖它的那份在同一个事务里原地换成重切件（`Truth::relay_purged`；那一份在这个 seq 上本来就没有内容——作者
//!     自己重切过——就不动）；已经转发到各位置上的同名 `rly-` 改成待删，[relay_outbox] 把它当缺的、用重切件同名重写
//!     （重写确认后回到在用，不再删）。
//!   - 缓存里没有这一段（从没留、或已删）而别的位置缺它：[relay_outbox] 从本机日志重切（`Truth::recut_from_log`：用收段时
//!     记下的作者签名版本与清除时记下的剔除记录），[wanted_for_relay] 不再为它去拉原文；收到的段若在本机已清除的 seq 上
//!     还带着完整内容，[keep] 不留。
//!   这样只经本机拿数据的位置照样收得到这位作者其余的操作，进而收得到本机此后依赖它们的操作；被清除的内容不经本机
//!   离开。读者拿作者签名验每一条留下的操作与每个剔除项，剔除项还要对上它点名的、读者自己认的 Purge（`receive.rs`），
//!   另外只收本机信任的重切者签的件。本机没记下这一段的作者签名版本、或缺某条的剔除记录（例如从备份还原的库）时重切
//!   不出来，这一段退回「不转发」（`incomplete`），等作者自己重切。
//!
//! # 重切材料的回收（第六波）
//!
//! 重切材料（`relay_auth` 作者签名版本、`relay_stubs` 剔除记录，`sync_state.rs`）只在本机替作者**重切**一段时用，
//! 而重切只发生在两处：[relay_outbox] 按记下的作者**最新** head 的段清单（`h.segs`）补位置缺的段，与
//! `Truth::relay_purged` 把转发缓存（`relay_segs`）里的件原地换成重切件。哪个位置缺什么都只从最新 head 的清单算
//! （`present_at` 只用来跳过已有的），所以「哪些位置还需要」的判据落在区间上——作者 [device] 的一个区间
//! `[first, last]` 还需要材料，当且仅当：
//!
//! 1. 本机还没记下它的 head（不知道它会列哪些区间，全留；不受信 / 待确认的作者 [note_head] 不记，所以也全留，确认
//!    之后照样能转发）；或
//! 2. 记下的最新 head 列着这个区间（链尾标签不论：作者清除之后同区间重切只换标签）；或
//! 3. 转发缓存里还存着这个区间的件（原地重切要它）。
//!
//! 不满足的（作者重切 / 合并之后旧区间、缓存里的件也已删掉）就是哪个位置都不会再要的：作者 head 只进不退，旧
//! 区间不会再出现在它的清单里。剔除记录跟着**还需要的区间**走（不是跟着本机已存的版本走）：seq 落在某个还需要的
//! 区间里就留，只有那个区间本机存着作者签名版本、且这个 seq 在它作者签的空洞里时才不算（重切时作者空洞原样照搬，
//! 用不着剔除记录）。还需要、但本机还没收到作者签名版本的区间（作者刚合并 / 重切，[note_head] 在收段之前就记下了
//! 新 head）整段留：版本随后到时要靠这些剔除记录拼本机清除过的格；本机自己清除时写下的剔除记录删了就再也生不
//! 出来。记下的 head 换成更新的一份（[note_head]）、或 [prune]
//! 删掉了缓存里的件时回收（[reclaim_material]）；只按这位作者的主键前缀 / 区间删，不扫别的作者。
//! 判据不看位置数：只同步一个位置时 [relay_outbox] 不转发，但之后加了第二个位置要转发的仍是最新清单里的区间。
//!
//! 本机在同步着 ≥ 2 个位置之前就收过的段当时没留原文：`plan` 读到作者 head 时把「本机早有、没留原文、别的位置缺」的
//! 段再要一次（[wanted_for_relay]），收段时按本机已有跳过、只留原文，下一轮就能转发。转发时缺的段本机还凑不齐原文的
//! 作者这一轮整台跳过（回包 `incomplete`），不发半截。

use std::collections::{BTreeMap, BTreeSet};

use rusqlite::{OptionalExtension, params};
use serde_json::{Value, json};

use super::Files;
use super::sync::{meta_get, meta_set};
use super::sync_oldroot::former_identities;
use crate::gen4::head::Head4;
use crate::gen4::location::{V4File, device_path, parse_v4_path, relay_head_name};
use crate::gen4::recut::{MAGIC as RECUT_MAGIC, open_recut4_items, peek_recut4, rewrap_recut4};
use crate::gen4::relay::{open_relay4_items, peek_relay4, wrap_relay4};
use crate::gen4::segment::NativeItem;
use crate::store::gen4::schema::sql;
use crate::store::gen4::sync_state::RecutParts;
use crate::store::gen4::truth::Truth;
use crate::sync2::id::Id;
use crate::sync2::keys::CollectionKey;
use crate::sync2::segment::{chain_tag, relay_file_name, segment_file_name};

/// 一批转发的字节预算（与发件同值，`cmd/sync.rs` `OUTBOX_BATCH_BYTES`）。
pub const RELAY_BATCH_BYTES: u64 = super::sync::OUTBOX_BATCH_BYTES;

/// 多久没成功同步过的位置不再算转发目标（协议 3 `relay.rs` 同值同口径：换过密钥 / 被移除的位置留下的旧进度行，
/// 不让它们永远「缺」）。
pub(crate) const ACTIVE_WINDOW_MS: i64 = 30 * 24 * 60 * 60 * 1000;

/// 本机记着的位置与各自上次成功的时刻（`loc_state` 主键前缀）。活跃与否在 [active_locations] 里按 [ACTIVE_WINDOW_MS] 筛。
pub(crate) const LOC_KEYS_SQL: &str =
    "SELECT loc_key, last_ok FROM loc_state WHERE col = ?1 ORDER BY loc_key";

/// 存一份可转发的段（`relay_segs` 的唯一约束：同一作者同一区间同一链尾只存一份）。
pub(crate) const RELAY_PUT_SQL: &str = "INSERT OR IGNORE INTO relay_segs (col, device, first, last, tag, piece) \
     VALUES (?1, ?2, ?3, ?4, ?5, ?6)";

/// 同一段存着的是重切件（`FRX4`）时换成作者签的那份（唯一约束的自动索引，等值点查）。
pub(crate) const RELAY_AUTHOR_OVER_RECUT_SQL: &str = "UPDATE relay_segs SET piece = ?6 \
     WHERE col = ?1 AND device = ?2 AND first = ?3 AND last = ?4 AND tag = ?5 AND substr(piece, 1, 4) = X'46525834'";

/// 取一份可转发的段（唯一约束的自动索引，等值点查）。
pub(crate) const RELAY_GET_SQL: &str = "SELECT piece FROM relay_segs \
     WHERE col = ?1 AND device = ?2 AND first = ?3 AND last = ?4 AND tag = ?5";

/// 有没有存着这一份可转发段（只判存在，不读 `piece` 大字段；唯一约束的自动索引，等值点查）。
pub(crate) const RELAY_HAS_SQL: &str = "SELECT 1 FROM relay_segs      WHERE col = ?1 AND device = ?2 AND first = ?3 AND last = ?4 AND tag = ?5 LIMIT 1";

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

/// 不封装的中继件 / 重切件 [piece]（作者 [header]，作者公钥 [author]，重切件的重切者公钥 [recutter]）在本机已清除
/// （空洞）的 seq 上带着操作的完整内容。本机这段没有空洞 = 否，不解段。
fn carries_voided(
    t: &Truth<'_>,
    col: i64,
    header: &crate::gen4::segment::NativeHeader,
    piece: &[u8],
    author: &[u8; 32],
    recutter: Option<&[u8; 32]>,
) -> Result<bool, String> {
    let voids = t.voids_within(col, &header.device, header.first, header.last)?;
    if voids.is_empty() {
        return Ok(false);
    }
    let items = match recutter {
        Some(r) => open_recut4_items(piece, author, r, None).map(|(_, items)| items),
        None => open_relay4_items(piece, author, None).map(|(_, items)| items),
    }
    .map_err(|e| format!("relay: kept piece unreadable: {e:?}"))?;
    let mut seq = header.first;
    for item in &items {
        if matches!(item, NativeItem::Op(_)) && voids.iter().any(|(a, b)| (*a..=*b).contains(&seq))
        {
            return Ok(true);
        }
        seq += item.span();
    }
    Ok(false)
}

fn str_req<'a>(req: &'a Value, k: &str) -> Result<&'a str, String> {
    req.get(k)
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .ok_or_else(|| format!("relay: missing {k}"))
}

fn location_count(t: &Truth<'_>, col: i64) -> Result<usize, String> {
    Ok(locations(t, col)?.len())
}

/// 转发目标：本机在新代里成功同步过（`last_ok` 由 `head` 记，`cmd/sync.rs`）、且离最近一次成功不超过
/// [ACTIVE_WINDOW_MS] 的位置。
///
/// 与协议 3 的差别：协议 3 把「还没成功过」（`last_ok` 为空）也算活跃；新代的 `loc_state` 有两类空行——迁移
/// （`carry.rs`）把协议 3 见过的每个加密位置都灌进来、`plan` 第一次读到一个位置也先建行——它们都不能证明那个位置
/// 还在用，算进来就会让只用过一个位置的设备永远「同步着 ≥ 2 个位置」：收到的每个段都另存一份原文、死位置永远缺、
/// prune 永远删不掉，还为它把全部历史再拉一遍。新加的位置在第一轮写完 head 之后就进来，晚一轮开始转发。
fn locations(t: &Truth<'_>, col: i64) -> Result<Vec<String>, String> {
    let rows: Vec<(String, Option<i64>)> = {
        let mut stmt = t.conn().prepare_cached(LOC_KEYS_SQL).map_err(sql)?;
        let rows = stmt
            .query_map([col], |r| Ok((r.get(0)?, r.get(1)?)))
            .map_err(sql)?;
        rows.collect::<rusqlite::Result<_>>().map_err(sql)?
    };
    let Some(newest) = rows.iter().filter_map(|r| r.1).max() else {
        return Ok(Vec::new());
    };
    Ok(rows
        .into_iter()
        .filter(|(_, ok)| ok.is_some_and(|t| t >= newest.saturating_sub(ACTIVE_WINDOW_MS)))
        .map(|(l, _)| l)
        .collect())
}

/// 这台设备的段 / head 可以由本机转发：不是本机（当前或旧身份）、受信。
fn relayable(t: &Truth<'_>, col: i64, device: &Id) -> Result<bool, String> {
    relayable_among(t, col, device, &former_identities(t, col)?)
}

/// [relayable]，旧身份由调用方取一次（逐台设备循环时不重复查）。
fn relayable_among(
    t: &Truth<'_>,
    col: i64,
    device: &Id,
    formers: &BTreeSet<Id>,
) -> Result<bool, String> {
    if t.self_identity(col)?.is_some_and(|s| s.device == *device) {
        return Ok(false);
    }
    if formers.contains(device) {
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
    meta_set(t, &rhead_key(col, &h.device), text)?;
    // 清单变了：旧区间的重切材料可能已经哪个位置都用不着了（文件头「重切材料的回收」）。
    reclaim_material(t, col, &h.device, Some(h))?;
    Ok(())
}

/// 回收作者 [device] 哪个位置都不会再要的重切材料（文件头「重切材料的回收」的判据）。[head] = 记下的最新 head（None =
/// 还没记过，全留）。返回删掉的 (作者签名版本数, 剔除记录数)。
pub(crate) fn reclaim_material(
    t: &Truth<'_>,
    col: i64,
    device: &Id,
    head: Option<&Head4>,
) -> Result<(u64, u64), String> {
    let Some(h) = head else {
        return Ok((0, 0));
    };
    let mut needed: BTreeSet<(u64, u64)> = h.segs.iter().map(|(a, b, _)| (*a, *b)).collect();
    for (_, first, last, _) in relay_rows(t, col, device)? {
        needed.insert((first as u64, last as u64));
    }
    let mut dropped_versions = 0u64;
    // 还需要的区间各自的作者签名版本（本机已存的）；其余版本删掉。
    let mut voids_of: BTreeMap<(u64, u64), Vec<(u64, u64)>> = BTreeMap::new();
    for v in t.author_versions_of(col, device)? {
        let range = (v.header.first, v.header.last);
        if !needed.contains(&range) {
            t.drop_author_version(col, device, range.0, range.1)?;
            dropped_versions += 1;
            continue;
        }
        voids_of.insert(range, v.voids.iter().map(|(s, c, _)| (*s, *c)).collect());
    }
    // 剔除记录要留的 seq 区间：每个还需要的区间，本机有它的版本就去掉作者签的空洞，没有就整段。
    let mut covered: Vec<(u64, u64)> = Vec::new();
    for &(first, last) in &needed {
        let Some(voids) = voids_of.get(&(first, last)) else {
            covered.push((first, last));
            continue;
        };
        let mut at = first;
        for &(start, count) in voids {
            if start > at {
                covered.push((at, start - 1));
            }
            at = at.max(start.saturating_add(count));
        }
        if at <= last {
            covered.push((at, last));
        }
    }
    let dropped_stubs = t.keep_stubs_within(col, device, &covered)?;
    Ok((dropped_versions, dropped_stubs))
}

/// 作者 [device] 存着的可转发段（行号、first、last、tag；唯一约束的自动索引，前缀区间）。
fn relay_rows(
    t: &Truth<'_>,
    col: i64,
    device: &Id,
) -> Result<Vec<(i64, i64, i64, String)>, String> {
    let mut stmt = t.conn().prepare_cached(RELAY_LIST_SQL).map_err(sql)?;
    let rows = stmt
        .query_map(params![col, &device.0[..]], |r| {
            Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?))
        })
        .map_err(sql)?;
    rows.collect::<rusqlite::Result<_>>().map_err(sql)
}

/// 收段时调：本机同步着 ≥ 2 个位置、作者可转发时，把这个已收下的原生段 / 中继件重新包成不封装的中继件（重切件照原样
/// 去掉位置的封装）存下。返回是否存了新的一份。[key] = 它所在位置的钥匙。同一段已存着重切件、这回收到的是作者签的
/// 那份（作者自己重切了）就换成作者签的：读者不必信任本机这个重切者。
pub(crate) fn keep(
    t: &Truth<'_>,
    col: i64,
    bytes: &[u8],
    key: Option<&CollectionKey>,
) -> Result<bool, String> {
    if location_count(t, col)? < 2 {
        return Ok(false);
    }
    let recut = bytes.starts_with(RECUT_MAGIC);
    let peeked = if recut {
        peek_recut4(bytes).map(|p| (p.header, Some(p.recutter)))
    } else if bytes.starts_with(crate::gen4::relay::MAGIC) {
        peek_relay4(bytes).map(|p| (p.header, None))
    } else {
        crate::gen4::segment::peek_native_header(bytes).map(|h| (h, None))
    };
    let Ok((header, recutter)) = peeked else {
        return Ok(false);
    };
    if !relayable(t, col, &header.device)? {
        return Ok(false);
    }
    let Some(author) = public_of(t, col, &header.device)? else {
        return Ok(false);
    };
    let recutter_public = match recutter {
        Some(r) => match public_of(t, col, &r)? {
            Some(p) => Some(p),
            None => return Ok(false),
        },
        None => None,
    };
    // 收段时已整段验过；这里再包一次（验签 + 链）只是包的约定，失败就不存（不影响收段本身）。
    let wrapped = match &recutter_public {
        Some(r) => rewrap_recut4(bytes, &author, r, key, None),
        None => wrap_relay4(bytes, &author, key, None),
    };
    let Ok(piece) = wrapped else {
        return Ok(false);
    };
    // 本机已经清除了这段里的操作，而这一份还带着它们的完整内容（作者 / 重切者清除之前的那份）：不留。缺它的位置由
    // [relay_outbox] 从本机日志重切。
    if carries_voided(t, col, &header, &piece, &author, recutter_public.as_ref())? {
        return Ok(false);
    }
    let tag = chain_tag(&header.last_chain);
    let first = i64::try_from(header.first).map_err(|_| "relay: seq out of range")?;
    let last = i64::try_from(header.last).map_err(|_| "relay: seq out of range")?;
    t.write(|| {
        let n = t
            .conn()
            .prepare_cached(RELAY_PUT_SQL)
            .map_err(sql)?
            .execute(params![col, &header.device.0[..], first, last, tag, piece])
            .map_err(sql)?;
        if n > 0 || recut {
            return Ok(n > 0);
        }
        let n = t
            .conn()
            .prepare_cached(RELAY_AUTHOR_OVER_RECUT_SQL)
            .map_err(sql)?
            .execute(params![col, &header.device.0[..], first, last, tag, piece])
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
    Ok(t.relay_out_of(col, loc, device)?
        .into_iter()
        .filter(|r| !r.gone)
        .map(|r| r.name)
        .collect())
}

fn has_piece(
    t: &Truth<'_>,
    col: i64,
    device: &Id,
    (first, last, tag): (u64, u64, &str),
) -> Result<bool, String> {
    t.conn()
        .prepare_cached(RELAY_HAS_SQL)
        .map_err(sql)?
        .query_row(
            params![
                col,
                &device.0[..],
                i64::try_from(first).map_err(|_| "relay: seq out of range")?,
                i64::try_from(last).map_err(|_| "relay: seq out of range")?,
                tag
            ],
            |_| Ok(()),
        )
        .optional()
        .map(|o| o.is_some())
        .map_err(sql)
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

/// 本机认得的设备公钥（本机自己也算）。
fn public_of(t: &Truth<'_>, col: i64, device: &Id) -> Result<Option<[u8; 32]>, String> {
    Ok(match t.self_identity(col)? {
        Some(me) if me.device == *device => Some(me.public()),
        _ => t.device_key(col, device)?,
    })
}

/// [relay_outbox] 要发的一段。
enum Part {
    /// 转发缓存里存着的（不封装的中继件，或重切件）。
    Kept(Vec<u8>),
    /// 从本机日志重切出来、还没签的（`Truth::recut_from_log`）。
    Cut(RecutParts),
}

impl Part {
    /// 预算按的大小（重切的按条目估：落盘前要压缩，取上界）。
    fn len(&self) -> u64 {
        match self {
            Part::Kept(p) => p.len() as u64,
            Part::Cut(parts) => {
                parts
                    .items
                    .iter()
                    .map(|i| match i {
                        crate::gen4::recut::RecutItem::Op(op) => op.payload.len() as u64 + 48,
                        crate::gen4::recut::RecutItem::Void { .. } => 40,
                        crate::gen4::recut::RecutItem::Stub(_) => 120,
                    })
                    .sum::<u64>()
                    + 200
            }
        }
    }

    /// 按目标位置的钥匙 [key] 包成位置上的文件字节。
    fn wrap(
        self,
        t: &Truth<'_>,
        col: i64,
        device: &Id,
        author: &[u8; 32],
        key: Option<&CollectionKey>,
    ) -> Result<Vec<u8>, String> {
        let unreadable = |e| format!("relay: stored piece of {device} unreadable: {e:?}");
        match self {
            Part::Kept(p) if p.starts_with(RECUT_MAGIC) => {
                let r = peek_recut4(&p).map_err(unreadable)?.recutter;
                let public = public_of(t, col, &r)?
                    .ok_or_else(|| format!("relay: stored recut of {device} by unknown {r}"))?;
                rewrap_recut4(&p, author, &public, None, key).map_err(unreadable)
            }
            Part::Kept(p) => wrap_relay4(&p, author, None, key).map_err(unreadable),
            Part::Cut(parts) => t
                .sign_recut(col, &parts, key)?
                .ok_or_else(|| format!("relay: cannot sign a recut of {device}")),
        }
    }
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
    let formers = former_identities(t, col)?;
    'devices: for (device, h) in stored_heads(t, col)? {
        if !relayable_among(t, col, &device, &formers)? {
            continue;
        }
        let sent = sent_names(t, col, loc, &device)?;
        let (have, present) = present_at(t, col, loc, &device, &sent)?;
        let rhd = relay_head_name(&h);
        if have >= h.seq {
            continue;
        }
        // 段逐个看（head 已经转发过也看）：本机清除时把转发过去的同名件改成了待删，它们要用重切件重写。
        let mut parts: Vec<(String, Part)> = Vec::new();
        for (a, b, tag) in &h.segs {
            let name = segment_file_name(*a, *b, tag);
            if present.contains(&name) {
                continue;
            }
            if let Some(p) = piece_of(t, col, &device, (*a, *b, tag))? {
                parts.push((name, Part::Kept(p)));
                continue;
            }
            // 本机没留这一段，但清除过其中的操作：从本机日志重切（原文不经本机离开，见文件头）。
            match t.recut_from_log(col, &device, (*a, *b, tag))? {
                Some(cut) => parts.push((name, Part::Cut(cut))),
                None => {
                    incomplete.push(device.text());
                    continue 'devices;
                }
            }
        }
        if parts.is_empty() {
            if sent.contains(&rhd) {
                continue;
            }
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
        for (name, part) in parts {
            if !paths.is_empty() && total.saturating_add(part.len()) > budget {
                more = true;
                break 'devices;
            }
            let bytes = part.wrap(t, col, &device, &h.public, key)?;
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
                for r in t.relay_out_of(col, loc, &device)? {
                    if !r.gone && wanted.contains(&r.name) {
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

/// `plan` 调：head [h]（读自位置 [loc]）引用的、本机日志里早就有（区间末尾 ≤ [last]）、却没留原文而别的位置缺的段
/// 名。本机先前只同步着一个位置时收的段不留原文；有了第二个位置之后要转发它们，就让这一轮再拉一次——收段时按本机已有
/// 跳过（不落库），只经 [keep] 留下原文（协议 3 `plan` 的「只为转发而拉」同一口径）。本机只同步着一个位置、作者不可
/// 转发时为空。
pub(crate) fn wanted_for_relay(
    t: &Truth<'_>,
    col: i64,
    loc: &str,
    h: &Head4,
    last: u64,
) -> Result<Vec<String>, String> {
    if location_count(t, col)? < 2 || !relayable(t, col, &h.device)? {
        return Ok(Vec::new());
    }
    let mut others: Vec<(u64, BTreeSet<String>)> = Vec::new();
    for l in locations(t, col)? {
        if l == loc {
            continue;
        }
        let sent = sent_names(t, col, &l, &h.device)?;
        others.push(present_at(t, col, &l, &h.device, &sent)?);
    }
    let mut out = Vec::new();
    for (a, b, tag) in &h.segs {
        if *b > last {
            continue;
        }
        let name = segment_file_name(*a, *b, tag);
        let lacking = others
            .iter()
            .any(|(seq, names)| *seq < *b && !names.contains(&name));
        // 本机清除过其中操作的段不为转发去拉原文：[relay_outbox] 从本机日志重切（拉回来的原文 [keep] 也不留）。
        if lacking
            && !has_piece(t, col, &h.device, (*a, *b, tag))?
            && t.voids_within(col, &h.device, *a, *b)?.is_empty()
        {
            out.push(name);
        }
    }
    Ok(out)
}

/// 删掉作者 [device] 的、每个位置都已有的可转发段：那个位置上作者的 head 覆盖到了段尾或引用了它，或本机已转发过去。
/// 本机只剩 < 2 个位置时全部删（没有转发目标）。返回删了几份。
pub(crate) fn prune(t: &Truth<'_>, col: i64, device: &Id) -> Result<u64, String> {
    let rows = relay_rows(t, col, device)?;
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
    if dropped > 0 {
        // 缓存里的件删了：只为原地重切它而留的材料也可以回收了（文件头「重切材料的回收」第 3 条）。
        reclaim_material(t, col, device, stored_head(t, col, device)?.as_ref())?;
    }
    Ok(dropped)
}
