//! 配置快照按内容去重（srs.db schema v16，2026-10-30 磁盘占用）。
//!
//! 本机作答的每条派生日志都带「作答那一刻的生效排程配置」`sc`（设计 §4.6，[super::stamp_config]），一份几百字节，
//! 而一个用户的配置只有几份。以前它在每条日志上存两遍原文：操作日志 `sync2_ops.payload` 一遍、日志投影
//! `srs_review_logs.json` 一遍。操作日志那一份现在只在 `sync2_snapshots` 存一次（键 = 原文的 BLAKE3 前 16 字节 hex）：
//!
//! - 载荷是作者签名的线格式字节，必须原样还原（段、链、`.fushisrs` 导出都用它）。存的时候把载荷里 `"sc":<原文>`
//!   的原文那一段字节剪掉，记下 (哈希 `sc`, 位置 `sc_at`)；读的时候在同一位置拼回去。逐字节可逆，与载荷怎么编码
//!   无关；找不到（外来的非规范 JSON 等）就原样存。只有 [super::insert_op] / [super::load_op] 碰它；按种类直读
//!   载荷的地方（迁移闭包、时间线）只读修改 / 实体操作，从不被剪。`sync2_ops` 只有内核读，Dart 从不碰。
//! - 日志投影 `srs_review_logs.json` **不**按引用存：它是 Dart 侧直接读的契约（导出、备份快照、主库备份跨库拷表、
//!   profile 合并、旧库迁移都把这一列原样搬到别的库里），引用搬过去就悬空。摘要也按投影原文算，不受影响。
//!
//! 快照行从不删除（只增，几份）。

use rusqlite::{params, Connection, OptionalExtension};
use serde_json::Value;

use super::{canonical, sql};
use crate::sync2::op::{self, Body};
use crate::sync2::replay::SNAPSHOT_KEY;

/// v16：快照表与操作日志的两列引用。
pub const V16: &str = "CREATE TABLE IF NOT EXISTS sync2_snapshots (hash TEXT NOT NULL PRIMARY KEY, body TEXT NOT NULL) WITHOUT ROWID;";

/// 比引用（32 字符 + 引号）还短的原文不值得去重。
const MIN_BODY: usize = 64;

fn hash_of(body: &str) -> String {
    blake3::hash(body.as_bytes()).as_bytes()[..16].iter().map(|b| format!("{b:02x}")).collect()
}

/// 存一份快照原文，返回它的哈希（已有就不写）。
pub(crate) fn intern(c: &Connection, body: &str) -> Result<String, String> {
    let h = hash_of(body);
    c.prepare_cached("INSERT OR IGNORE INTO sync2_snapshots (hash, body) VALUES (?1, ?2)")
        .map_err(sql)?
        .execute(params![h, body])
        .map_err(sql)?;
    Ok(h)
}

fn body_of(c: &Connection, hash: &str) -> Result<Option<String>, String> {
    c.prepare_cached("SELECT body FROM sync2_snapshots WHERE hash = ?1")
        .map_err(sql)?
        .query_row([hash], |r| r.get(0))
        .optional()
        .map_err(sql)
}

// ---------------------------------------------------------------- 操作日志载荷

/// 存进 `sync2_ops` 的形态：(载荷, `sc`, `sc_at`)。只有带快照原文的日志操作会被剪。
pub(crate) fn pack_payload(c: &Connection, kind: u16, payload: &[u8]) -> Result<(Vec<u8>, Option<String>, Option<i64>), String> {
    let unchanged = || Ok((payload.to_vec(), None, None));
    if kind != op::KIND_LOG || !contains(payload, b"\"sc\":{") {
        return unchanged();
    }
    let Ok(Body::Log(l)) = Body::decode(kind, payload) else { return unchanged() };
    let Some(sc) = serde_json::from_str::<Value>(&l.extra).ok().and_then(|v| v.get(SNAPSHOT_KEY).filter(|x| x.is_object()).cloned()) else {
        return unchanged();
    };
    let body = canonical(&sc);
    if body.len() < MIN_BODY {
        return unchanged();
    }
    let needle = format!("\"{SNAPSHOT_KEY}\":{body}");
    let Some(pos) = find(payload, needle.as_bytes()) else { return unchanged() };
    let at = pos + needle.len() - body.len();
    let mut out = Vec::with_capacity(payload.len() - body.len());
    out.extend_from_slice(&payload[..at]);
    out.extend_from_slice(&payload[at + body.len()..]);
    Ok((out, Some(intern(c, &body)?), Some(at as i64)))
}

/// [pack_payload] 的逆：在 `sc_at` 处拼回快照原文。
pub(crate) fn unpack_payload(c: &Connection, stored: Vec<u8>, sc: Option<String>, at: Option<i64>) -> Result<Vec<u8>, String> {
    let (Some(h), Some(at)) = (sc, at) else { return Ok(stored) };
    let body = body_of(c, &h)?.ok_or_else(|| format!("config snapshot {h} missing"))?;
    let at = usize::try_from(at).ok().filter(|&a| a <= stored.len()).ok_or("bad snapshot offset")?;
    let mut out = Vec::with_capacity(stored.len() + body.len());
    out.extend_from_slice(&stored[..at]);
    out.extend_from_slice(body.as_bytes());
    out.extend_from_slice(&stored[at..]);
    Ok(out)
}

fn find(hay: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.is_empty() || hay.len() < needle.len() {
        return None;
    }
    hay.windows(needle.len()).position(|w| w == needle)
}

fn contains(hay: &[u8], needle: &[u8]) -> bool {
    find(hay, needle).is_some()
}

// ---------------------------------------------------------------- v16 升级

/// 快照表与 `sync2_ops` 的两列引用（可重放；没有 `sync2_ops` 的库什么也不做）。读操作的代码（[super::load_op]）
/// 要这两列，所以升级阶梯在 v16 之前的步骤里读操作（v10 的寄存器重建等）之前就得先补上——见 store/schema.rs。
pub(crate) fn ensure_columns(c: &Connection) -> Result<(), String> {
    let has_ops = c.query_row("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'sync2_ops'", [], |_| Ok(())).is_ok();
    if !has_ops {
        return Ok(());
    }
    c.execute_batch(V16).map_err(sql)?;
    for (col, ty) in [("sc", "TEXT"), ("sc_at", "INTEGER")] {
        let has: i64 = c
            .query_row("SELECT COUNT(*) FROM pragma_table_info('sync2_ops') WHERE name = ?1", [col], |r| r.get(0))
            .map_err(sql)?;
        if has == 0 {
            c.execute_batch(&format!("ALTER TABLE sync2_ops ADD COLUMN {col} {ty} NULL;")).map_err(sql)?;
        }
    }
    Ok(())
}

/// 一页读多少行（[migrate]）：内存里同时只有一页的载荷。
const MIGRATE_PAGE: usize = 512;

/// 存量行改成引用形态（升级一次；可重放：已是引用的行不再动）。
pub(crate) fn migrate(c: &Connection) -> Result<(), String> {
    migrate_paged(c, MIGRATE_PAGE).map(|_| ())
}

/// [migrate] 的实现：在调用方的事务里按主键 `(profile_uid, device, seq)` 键集分页读、逐页改，同一时刻内存里只有
/// 一页（≤ [page] 行）的载荷——以前把全部日志载荷一次读进内存，几十万条作答的大库升级时内存随库线性涨。键集游标
/// 用存储的原值（ID 列此时可能已是 v17 的 BLOB）比较，不经编码函数；改不了的行（找不到原文）`sc` 仍为 NULL，靠游标
/// 前进不会重读。返回 (页数, 单页最多行数)。
pub(crate) fn migrate_paged(c: &Connection, page: usize) -> Result<(usize, usize), String> {
    use rusqlite::types::Value as Sql;
    ensure_columns(c)?;
    let has_ops = c.query_row("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'sync2_ops'", [], |_| Ok(())).is_ok();
    if !has_ops {
        return Ok((0, 0));
    }
    let page = page.max(1);
    let kind = i64::from(op::KIND_LOG);
    let mut first = c
        .prepare(
            "SELECT profile_uid, device, seq, payload FROM sync2_ops \
             WHERE kind = ?1 AND sc IS NULL AND purged = 0 \
             ORDER BY profile_uid, device, seq LIMIT ?2",
        )
        .map_err(sql)?;
    let mut next = c
        .prepare(
            "SELECT profile_uid, device, seq, payload FROM sync2_ops \
             WHERE kind = ?1 AND sc IS NULL AND purged = 0 AND (profile_uid, device, seq) > (?3, ?4, ?5) \
             ORDER BY profile_uid, device, seq LIMIT ?2",
        )
        .map_err(sql)?;
    let mut up = c
        .prepare("UPDATE sync2_ops SET payload = ?4, sc = ?5, sc_at = ?6 WHERE profile_uid = ?1 AND device = ?2 AND seq = ?3")
        .map_err(sql)?;
    let row = |r: &rusqlite::Row<'_>| -> rusqlite::Result<(Sql, Sql, i64, Vec<u8>)> { Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)) };
    let mut cursor: Option<(Sql, Sql, i64)> = None;
    let (mut pages, mut widest) = (0usize, 0usize);
    loop {
        let rows: Vec<(Sql, Sql, i64, Vec<u8>)> = match &cursor {
            None => first.query_map(params![kind, page as i64], row),
            Some((p, d, s)) => next.query_map(params![kind, page as i64, p, d, s], row),
        }
        .map_err(sql)?
        .collect::<Result<_, _>>()
        .map_err(sql)?;
        if rows.is_empty() {
            break;
        }
        pages += 1;
        widest = widest.max(rows.len());
        let full = rows.len() == page;
        for (profile, device, seq, payload) in rows {
            if contains(&payload, b"\"sc\":{") {
                let (stored, sc, at) = pack_payload(c, op::KIND_LOG, &payload)?;
                if sc.is_some() {
                    up.execute(params![profile, device, seq, stored, sc, at]).map_err(sql)?;
                }
            }
            cursor = Some((profile, device, seq));
        }
        if !full {
            break;
        }
    }
    Ok((pages, widest))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn payload_packing_round_trips_byte_for_byte() {
        let c = Connection::open_in_memory().unwrap();
        c.execute_batch(V16).unwrap();
        let sc = serde_json::json!({"alg": "fsrs", "learn": [60000, 600000], "relearn": [600000], "ret": 0.9, "max": 36500, "fuzz": true});
        let body = canonical(&sc);
        let raw = [b"\x01\x02prefix\"sc\":".as_slice(), body.as_bytes(), b"}tail\x00".as_slice()].concat();
        // 不是日志操作 / 解码不了：原样。
        assert_eq!(pack_payload(&c, op::KIND_EDIT, &raw).unwrap(), (raw.clone(), None, None));
        assert_eq!(pack_payload(&c, op::KIND_LOG, &raw).unwrap(), (raw.clone(), None, None));
        let at = raw.len() - body.len() - 6;
        let stored = [&raw[..at], &raw[at + body.len()..]].concat();
        let h = intern(&c, &body).unwrap();
        assert_eq!(unpack_payload(&c, stored, Some(h), Some(at as i64)).unwrap(), raw);
    }
}
