//! 重切件的停放（第六波）：一个位置上的重切中继件（`FRX4`，`gen4/recut.rs`）收不了、而且原因是「等一件本机还没有的
//! 事」时，读者记下它在等什么，之后只在等的那件事发生时才再拉这一件——不是每轮都拉、也不是按时间退避。
//!
//! # 等什么
//!
//! 收段（`receive.rs`）对重切件给两种「之后可能收得了」的延后：
//!
//! - [Defer::PurgePending]：件里一个要落的剔除项点名的 Purge 本机还没有（没落库、也不在等待缓冲里）。记下那条 Purge
//!   的 `(设备, seq)`；它到了（落库或进了等待缓冲，[purge_here]）再拉。
//! - [Defer::UntrustedUploader]：重切者、或点名的 Purge 的作者本机不信任（待确认 / 已拒绝）。记下那台设备与它当时的
//!   信任状态；状态变了（确认、拒绝、改判）再拉——拒绝之后再拉一次得到同样的延后，按新状态重新停放。
//!
//! 别的延后（作者 / 重切者的公钥还没读到、解不开）与这里无关，照旧每轮再试。
//!
//! # 存在哪、什么时候清
//!
//! `relay_park`（[crate::store::gen4::schema::SYNC]）：按 (集合, 位置, 作者, 文件名) 一行；`last` = 这一件区间的末尾，
//! `wait` / `wait_seq` = 等的 Purge（`wait_seq` > 0）或等信任变化的设备（`wait_seq` = 0），`trust` = 停放时那台设备的
//! 信任状态（0 = 可信）。
//!
//! - `plan` 只对**被转发来的** head（`rhd-`，段从转发件 `rly-` 来）查停放（[still_parked]）：作者自己在这个位置写的
//!   head 列的段是作者的原件（`seg-`），不依赖任何 Purge，不受停放影响。
//! - 本机这位作者的日志末尾到了停放件的末尾（别处收到了同一段）、作者的 head 不再列这个文件（作者重切 / 合并了）、
//!   忘掉位置（`location_forget`）都删；放行时删。
//!
//! # 用户看得到什么
//!
//! 停着的件让这个位置对本机不完整：同步页设备表里**等的那台设备**一行带 `relayBlocked`（[blocked]，`writes_local.rs`
//! `status`）——等 Purge = 让那台设备同步一次这个位置；待确认 / 已拒绝 = 在这台设备上确认（或保持拒绝，此时这个位置
//! 上经它转来的这部分本机收不了，作者自己同步到这个位置就好）。那台设备在本机还没有日志时也补一行，好让用户确认它。

use rusqlite::{OptionalExtension, params};

use crate::gen4::recut::peek_recut4;
use crate::gen4::segment::NativeHeader;
use crate::store::gen4::receive::Defer;
use crate::store::gen4::schema::sql;
use crate::store::gen4::truth::Truth;
use crate::sync2::id::Id;
use crate::sync2::segment::{chain_tag, segment_file_name};
use crate::sync2::vv::OpId;

/// 停放一件（同一件再停换成新的等待）。
pub(crate) const PARK_PUT_SQL: &str = "INSERT OR REPLACE INTO relay_park \
     (col, loc_key, device, name, last, wait, wait_seq, trust) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)";

/// 一件停放的等待（主键点查）。
pub(crate) const PARK_GET_SQL: &str = "SELECT wait, wait_seq, trust FROM relay_park \
     WHERE col = ?1 AND loc_key = ?2 AND device = ?3 AND name = ?4";

/// 放行一件（主键）。
pub(crate) const PARK_DROP_SQL: &str =
    "DELETE FROM relay_park WHERE col = ?1 AND loc_key = ?2 AND device = ?3 AND name = ?4";

/// 作者日志末尾已经到了的停放件（别处收到了同一段）。
pub(crate) const PARK_SWEEP_SQL: &str =
    "DELETE FROM relay_park WHERE col = ?1 AND device = ?2 AND last <= ?3";

/// 一个位置上一位作者的停放件（主键前缀）。
pub(crate) const PARK_NAMES_SQL: &str =
    "SELECT name FROM relay_park WHERE col = ?1 AND loc_key = ?2 AND device = ?3";

/// 一个集合的全部停放（同步页）。
pub(crate) const PARK_ALL_SQL: &str = "SELECT loc_key, device, wait, wait_seq FROM relay_park \
     WHERE col = ?1 ORDER BY wait, loc_key, device, wait_seq > 0";

fn id_of(b: &[u8]) -> Result<Id, String> {
    Ok(Id(b.try_into().map_err(|_| {
        "gen4 store: bad device id in relay_park".to_owned()
    })?))
}

/// 重切件 [bytes] 在位置 [loc] 上因 [why] 延后：是「等一件事」的那两种就停放，返回是否停放了。
pub(crate) fn park(
    t: &Truth<'_>,
    col: i64,
    loc: &str,
    bytes: &[u8],
    why: &Defer,
) -> Result<bool, String> {
    let (wait, wait_seq) = match why {
        Defer::PurgePending(p) => (p.device, p.seq),
        Defer::UntrustedUploader(d) => (*d, 0),
        _ => return Ok(false),
    };
    let Ok(peeked) = peek_recut4(bytes) else {
        return Ok(false);
    };
    let h: &NativeHeader = &peeked.header;
    let name = segment_file_name(h.first, h.last, &chain_tag(&h.last_chain));
    let trust = if wait_seq == 0 {
        t.trust_of(col, &wait)?.unwrap_or(0)
    } else {
        0
    };
    let (last, wait_seq) = (
        i64::try_from(h.last).map_err(|_| "gen4 store: seq out of range")?,
        i64::try_from(wait_seq).map_err(|_| "gen4 store: seq out of range")?,
    );
    t.write(|| {
        t.conn()
            .prepare_cached(PARK_PUT_SQL)
            .map_err(sql)?
            .execute(params![
                col,
                loc,
                &h.device.0[..],
                name,
                last,
                &wait.0[..],
                wait_seq,
                trust
            ])
            .map_err(sql)?;
        Ok(true)
    })
}

/// 本机有没有 [p] 这条操作（落库，或在等待缓冲里）。
fn purge_here(t: &Truth<'_>, col: i64, p: &OpId) -> Result<bool, String> {
    if t.entry(col, p)?.is_some() {
        return Ok(true);
    }
    let Some(k) = t.key_of(col, p)? else {
        return Ok(false);
    };
    Ok(t.conn()
        .prepare_cached("SELECT 1 FROM op_wait WHERE k = ?1 AND op IS NOT NULL LIMIT 1")
        .map_err(sql)?
        .query_row([k], |_| Ok(()))
        .optional()
        .map_err(sql)?
        .is_some())
}

/// 位置 [loc] 上作者 [device] 的文件 [name] 还停着吗：等的事发生了（Purge 到了 / 信任状态变了）就放行（删停放），
/// 返回 false，`plan` 照常拉；还没发生返回 true，这一轮不拉。
pub(crate) fn still_parked(
    t: &Truth<'_>,
    col: i64,
    loc: &str,
    device: &Id,
    name: &str,
) -> Result<bool, String> {
    let row: Option<(Vec<u8>, i64, i64)> = t
        .conn()
        .prepare_cached(PARK_GET_SQL)
        .map_err(sql)?
        .query_row(params![col, loc, &device.0[..], name], |r| {
            Ok((r.get(0)?, r.get(1)?, r.get(2)?))
        })
        .optional()
        .map_err(sql)?;
    let Some((wait, wait_seq, trust)) = row else {
        return Ok(false);
    };
    let wait = id_of(&wait)?;
    let blocked = if wait_seq > 0 {
        !purge_here(
            t,
            col,
            &OpId {
                device: wait,
                seq: wait_seq as u64,
            },
        )?
    } else {
        t.trust_of(col, &wait)?.unwrap_or(0) == trust
    };
    if !blocked {
        t.write(|| {
            t.conn()
                .prepare_cached(PARK_DROP_SQL)
                .map_err(sql)?
                .execute(params![col, loc, &device.0[..], name])
                .map_err(sql)?;
            Ok(())
        })?;
    }
    Ok(blocked)
}

/// 作者 [device] 在位置 [loc] 上的 head 读到了：日志末尾已到 [last] 的停放件（各位置）与这个位置上 head 不再列的
/// （[listed] = head 列的文件名）删掉。
pub(crate) fn tidy(
    t: &Truth<'_>,
    col: i64,
    loc: &str,
    device: &Id,
    last: u64,
    listed: &std::collections::BTreeSet<String>,
) -> Result<(), String> {
    let names: Vec<String> = {
        let mut stmt = t.conn().prepare_cached(PARK_NAMES_SQL).map_err(sql)?;
        let rows = stmt
            .query_map(params![col, loc, &device.0[..]], |r| r.get(0))
            .map_err(sql)?;
        rows.collect::<rusqlite::Result<_>>().map_err(sql)?
    };
    let gone: Vec<&String> = names.iter().filter(|n| !listed.contains(*n)).collect();
    let last = i64::try_from(last).unwrap_or(i64::MAX);
    t.write(|| {
        t.conn()
            .prepare_cached(PARK_SWEEP_SQL)
            .map_err(sql)?
            .execute(params![col, &device.0[..], last])
            .map_err(sql)?;
        let mut drop = t.conn().prepare_cached(PARK_DROP_SQL).map_err(sql)?;
        for n in gone {
            drop.execute(params![col, loc, &device.0[..], n])
                .map_err(sql)?;
        }
        Ok(())
    })
}

/// 一组停着的件（同步页 `relayBlocked`）：等的设备、位置、作者、原因、件数。
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Blocked {
    pub wait: Id,
    pub loc: String,
    pub author: Id,
    /// `purge`（等 [Blocked::wait] 的一条 Purge 到达）/ `pending`（等确认 [Blocked::wait]）/ `rejected`（[Blocked::wait]
    /// 被拒绝）。
    pub reason: &'static str,
    pub pieces: u64,
}

/// 集合 [col] 现在停着的件，按 (等的设备, 位置, 作者, 原因) 归组。等信任变化而状态已经变了的（下一轮放行）不列。
pub(crate) fn blocked(t: &Truth<'_>, col: i64) -> Result<Vec<Blocked>, String> {
    let rows: Vec<(String, Vec<u8>, Vec<u8>, i64)> = {
        let mut stmt = t.conn().prepare_cached(PARK_ALL_SQL).map_err(sql)?;
        let rows = stmt
            .query_map([col], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)))
            .map_err(sql)?;
        rows.collect::<rusqlite::Result<_>>().map_err(sql)?
    };
    let mut out: Vec<Blocked> = Vec::new();
    for (loc, author, wait, wait_seq) in rows {
        let (author, wait) = (id_of(&author)?, id_of(&wait)?);
        let reason = if wait_seq > 0 {
            "purge"
        } else {
            match t.trust_of(col, &wait)? {
                Some(crate::store::gen4::truth::TRUST_REJECTED) => "rejected",
                Some(_) => "pending",
                None => continue,
            }
        };
        match out.last_mut() {
            Some(b)
                if b.wait == wait && b.loc == loc && b.author == author && b.reason == reason =>
            {
                b.pieces += 1;
            }
            _ => out.push(Blocked {
                wait,
                loc,
                author,
                reason,
                pieces: 1,
            }),
        }
    }
    Ok(out)
}
