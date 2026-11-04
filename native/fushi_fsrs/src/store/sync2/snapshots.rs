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

// ---------------------------------------------------------------- 载荷压缩（srs.db v21）

/// `sync2_ops.pz`：存的字节原样（剪过快照之后的载荷）。
pub(crate) const PZ_RAW: i64 = 0;
/// `sync2_ops.pz`：存的是 `[原长 u32 小端][zstd 帧]`。
pub(crate) const PZ_ZSTD: i64 = 1;
/// 比这短的不压（帧头 + 长度前缀就吃掉收益）。
const PZ_MIN: usize = 128;
/// zstd 档位：操作日志只有内核读、读得少（取操作、旧闭包、时间线），写得多（新设备一次几十万条），取快档。
const PZ_LEVEL: i32 = 1;

thread_local! {
    /// 压缩 / 解压上下文按线程复用：每条新建一个上下文要分配几百 KB 的表，比压缩本身还慢。
    static ZC: std::cell::RefCell<Option<zstd::bulk::Compressor<'static>>> = const { std::cell::RefCell::new(None) };
    static ZD: std::cell::RefCell<Option<zstd::bulk::Decompressor<'static>>> = const { std::cell::RefCell::new(None) };
}

/// 压缩存储字节：省不下八分之一就原样存。返回 (字节, `pz`)。
fn compress(stored: Vec<u8>) -> Result<(Vec<u8>, i64), String> {
    if stored.len() < PZ_MIN || stored.len() > u32::MAX as usize {
        return Ok((stored, PZ_RAW));
    }
    let z = ZC.with(|cell| -> Result<Vec<u8>, String> {
        let mut cell = cell.borrow_mut();
        if cell.is_none() {
            *cell = Some(zstd::bulk::Compressor::new(PZ_LEVEL).map_err(|e| e.to_string())?);
        }
        cell.as_mut().expect("compressor").compress(&stored).map_err(|e| e.to_string())
    })?;
    if (z.len() + 4) * 8 > stored.len() * 7 {
        return Ok((stored, PZ_RAW));
    }
    let mut out = Vec::with_capacity(z.len() + 4);
    out.extend_from_slice(&(stored.len() as u32).to_le_bytes());
    out.extend_from_slice(&z);
    Ok((out, PZ_ZSTD))
}

fn decompress(stored: Vec<u8>, pz: i64) -> Result<Vec<u8>, String> {
    match pz {
        PZ_RAW => Ok(stored),
        PZ_ZSTD => {
            let n = stored.get(..4).ok_or("compressed payload without its length")?;
            let n = u32::from_le_bytes(n.try_into().expect("4 bytes")) as usize;
            let out = ZD.with(|cell| -> Result<Vec<u8>, String> {
                let mut cell = cell.borrow_mut();
                if cell.is_none() {
                    *cell = Some(zstd::bulk::Decompressor::new().map_err(|e| e.to_string())?);
                }
                cell.as_mut().expect("decompressor").decompress(&stored[4..], n).map_err(|e| format!("bad compressed payload: {e}"))
            })?;
            if out.len() != n {
                return Err("compressed payload length mismatch".to_owned());
            }
            Ok(out)
        }
        other => Err(format!("unknown payload encoding {other}")),
    }
}

/// 存进 `sync2_ops` 的形态：剪掉快照原文（[strip_snapshot]）再压缩。
pub(crate) struct Packed {
    pub bytes: Vec<u8>,
    pub sc: Option<String>,
    pub sc_at: Option<i64>,
    pub pz: i64,
}

pub(crate) fn pack_payload(c: &Connection, kind: u16, payload: &[u8]) -> Result<Packed, String> {
    let (stored, sc, sc_at) = strip_snapshot(c, kind, payload)?;
    let (bytes, pz) = compress(stored)?;
    Ok(Packed { bytes, sc, sc_at, pz })
}

/// [pack_payload] 的逆：解压，再在 `sc_at` 处拼回快照原文。读 `sync2_ops.payload` 的地方一律经它。
pub(crate) fn unpack_payload(c: &Connection, stored: Vec<u8>, sc: Option<String>, at: Option<i64>, pz: i64) -> Result<Vec<u8>, String> {
    splice_snapshot(c, decompress(stored, pz)?, sc, at)
}

/// 剪掉快照原文后的形态：(载荷, `sc`, `sc_at`)。只有带快照原文的日志操作会被剪。
fn strip_snapshot(c: &Connection, kind: u16, payload: &[u8]) -> Result<(Vec<u8>, Option<String>, Option<i64>), String> {
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

/// [strip_snapshot] 的逆：在 `sc_at` 处拼回快照原文。
fn splice_snapshot(c: &Connection, stored: Vec<u8>, sc: Option<String>, at: Option<i64>) -> Result<Vec<u8>, String> {
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
    // `pz`（v21，载荷压缩）同样在这里补：v21 之前的升级步骤读操作时（[super::load_op]）就要它。
    for (col, ty) in [("sc", "TEXT NULL"), ("sc_at", "INTEGER NULL"), ("pz", "INTEGER NOT NULL DEFAULT 0")] {
        let has: i64 = c
            .query_row("SELECT COUNT(*) FROM pragma_table_info('sync2_ops') WHERE name = ?1", [col], |r| r.get(0))
            .map_err(sql)?;
        if has == 0 {
            c.execute_batch(&format!("ALTER TABLE sync2_ops ADD COLUMN {col} {ty};")).map_err(sql)?;
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
             WHERE kind = ?1 AND sc IS NULL AND purged = 0 AND pz = 0 \
             ORDER BY profile_uid, device, seq LIMIT ?2",
        )
        .map_err(sql)?;
    let mut next = c
        .prepare(
            "SELECT profile_uid, device, seq, payload FROM sync2_ops \
             WHERE kind = ?1 AND sc IS NULL AND purged = 0 AND pz = 0 AND (profile_uid, device, seq) > (?3, ?4, ?5) \
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
                let (stored, sc, at) = strip_snapshot(c, op::KIND_LOG, &payload)?;
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
        assert_eq!(strip_snapshot(&c, op::KIND_EDIT, &raw).unwrap(), (raw.clone(), None, None));
        assert_eq!(strip_snapshot(&c, op::KIND_LOG, &raw).unwrap(), (raw.clone(), None, None));
        let at = raw.len() - body.len() - 6;
        let stored = [&raw[..at], &raw[at + body.len()..]].concat();
        let h = intern(&c, &body).unwrap();
        assert_eq!(unpack_payload(&c, stored, Some(h), Some(at as i64), PZ_RAW).unwrap(), raw);
    }

    /// 压缩：够长、压得动的存 `[原长][zstd 帧]`，读回逐字节相同；短的 / 压不动的原样。
    #[test]
    fn payload_compression_round_trips_and_skips_what_does_not_shrink() {
        let c = Connection::open_in_memory().unwrap();
        c.execute_batch(V16).unwrap();
        let text = "<div class=\"gloss\">意味：とても長い説明文が続く。</div>".repeat(40).into_bytes();
        let p = pack_payload(&c, op::KIND_EDIT, &text).unwrap();
        assert_eq!(p.pz, PZ_ZSTD);
        assert!(p.bytes.len() * 4 < text.len(), "{} vs {}", p.bytes.len(), text.len());
        assert_eq!(unpack_payload(&c, p.bytes, p.sc, p.sc_at, p.pz).unwrap(), text);
        let short = b"\x01\x02short".to_vec();
        let p = pack_payload(&c, op::KIND_EDIT, &short).unwrap();
        assert_eq!((p.bytes.clone(), p.pz), (short.clone(), PZ_RAW));
        let mut x = 0x9E37_79B9_7F4A_7C15u64;
        let noise: Vec<u8> = (0..4096)
            .map(|_| {
                x ^= x << 13;
                x ^= x >> 7;
                x ^= x << 17;
                (x >> 32) as u8
            })
            .collect();
        let p = pack_payload(&c, op::KIND_EDIT, &noise).unwrap();
        assert_eq!((p.bytes, p.pz), (noise, PZ_RAW), "incompressible bytes are stored as they are");
        assert!(unpack_payload(&c, vec![1, 2], None, None, PZ_ZSTD).is_err());
        assert!(unpack_payload(&c, vec![], None, None, 7).is_err());
    }
}
