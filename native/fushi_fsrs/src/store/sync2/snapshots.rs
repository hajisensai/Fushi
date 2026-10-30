//! 配置快照按内容去重（srs.db schema v16，2026-10-30 磁盘占用）。
//!
//! 本机作答的每条派生日志都带「作答那一刻的生效排程配置」`sc`（设计 §4.6，[super::stamp_config]），一份几百字节，
//! 而一个用户的配置只有几份。以前它在每条日志上存两遍原文：操作日志 `sync2_ops.payload` 一遍、日志投影
//! `srs_review_logs.json` 一遍——一百万次复习就是约 600 MB 的同一段文字。现在原文只在 `sync2_snapshots` 存一份
//! （键 = 原文的 BLAKE3 前 16 字节 hex），两处都按引用存：
//!
//! - **操作日志**：载荷是作者签名的线格式字节，必须原样还原（段、链、`.fushisrs` 导出都用它）。存的时候把载荷里
//!   `"sc":<原文>` 的原文那一段字节剪掉，记下 (哈希 `sc`, 位置 `sc_at`)；读的时候在同一位置拼回去。逐字节可逆，
//!   与载荷怎么编码无关；找不到（外来的非规范 JSON 等）就原样存。只有 [super::insert_op] / [super::load_op] 与少数
//!   按种类直读载荷的地方碰它。
//! - **日志投影**：`json` 是规范 JSON（键有序、最短形），`sc` 的值换成哈希字符串 `"sc":"<hex>"`。读侧要配置的只有
//!   重放 / 预览（`group_of`）与迁移队列，展开后与原文逐字相同；摘要触发器按展开后的原文算行哈希（[super::digest]），
//!   所以升级前后、新旧版本设备的摘要不变。Dart 侧不解释 `sc`：本库里的日志再当作已盖戳事件并回来时由内核展开
//!   （[expand_extra]）；跨库读（备份合并）由 SQL 展开（`srs_backup_merge.dart`）。
//!
//! 快照行从不删除（只增，几份）：投影行删掉时摘要触发器还要按它算旧行的哈希。

use rusqlite::{params, Connection, OptionalExtension};
use serde_json::Value;

use super::{canonical, sql};
use crate::sync2::op::{self, Body};
use crate::sync2::replay::SNAPSHOT_KEY;

/// v16：快照表与操作日志的两列引用。
pub const V16: &str = "CREATE TABLE IF NOT EXISTS sync2_snapshots (hash TEXT NOT NULL PRIMARY KEY, body TEXT NOT NULL) WITHOUT ROWID;";

/// 比引用（32 字符 + 引号）还短的原文不值得去重。
const MIN_BODY: usize = 64;

/// 投影行里引用的标记（`"sc":"`）：整段 JSON 里没有它就一定没有引用，不必解析。
const REF_MARK: &str = "\"sc\":\"";

fn hash_of(body: &str) -> String {
    blake3::hash(body.as_bytes()).as_bytes()[..16].iter().map(|b| format!("{b:02x}")).collect()
}

fn is_ref(s: &str) -> bool {
    s.len() == 32 && s.bytes().all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
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

// ---------------------------------------------------------------- 日志投影

/// 投影行（规范 JSON 的值）里的快照原文换成引用。
pub(crate) fn compact_row(c: &Connection, row: &mut Value) -> Result<(), String> {
    let Some(sc) = row.get(SNAPSHOT_KEY).filter(|x| x.is_object()) else { return Ok(()) };
    let body = canonical(sc);
    if body.len() < MIN_BODY {
        return Ok(());
    }
    row[SNAPSHOT_KEY] = Value::String(intern(c, &body)?);
    Ok(())
}

/// 投影行原文 [json] 的引用形态（`None` = 原样存：没有快照原文，或原文不是规范 JSON——那样展开后不能逐字还原）。
pub(crate) fn compact_text(c: &Connection, json: &str) -> Result<Option<String>, String> {
    if !json.contains("\"sc\":{") {
        return Ok(None);
    }
    let Ok(mut v) = serde_json::from_str::<Value>(json) else { return Ok(None) };
    if canonical(&v) != json {
        return Ok(None);
    }
    compact_row(c, &mut v)?;
    let out = canonical(&v);
    Ok((out != json).then_some(out))
}

/// 投影行展开成原文（没有引用的原样返回；引用的快照不在 = 库坏了，报错）。
pub(crate) fn expand_text(c: &Connection, json: String) -> Result<String, String> {
    if !json.contains(REF_MARK) {
        return Ok(json);
    }
    let Ok(mut v) = serde_json::from_str::<Value>(&json) else { return Ok(json) };
    let Some(h) = v.get(SNAPSHOT_KEY).and_then(Value::as_str).filter(|h| is_ref(h)).map(str::to_owned) else { return Ok(json) };
    let body = body_of(c, &h)?.ok_or_else(|| format!("config snapshot {h} missing"))?;
    v[SNAPSHOT_KEY] = serde_json::from_str(&body).map_err(|e| format!("bad config snapshot {h}: {e}"))?;
    Ok(canonical(&v))
}

/// 摘要触发器的展开（纯函数：快照原文由触发器里的子查询给）。
pub fn expand_with(json: &str, body: Option<&str>) -> String {
    let Some(body) = body else { return json.to_owned() };
    let (Ok(mut v), Ok(b)) = (serde_json::from_str::<Value>(json), serde_json::from_str::<Value>(body)) else { return json.to_owned() };
    if !v.get(SNAPSHOT_KEY).and_then(Value::as_str).is_some_and(is_ref) {
        return json.to_owned();
    }
    v[SNAPSHOT_KEY] = b;
    canonical(&v)
}

/// 触发器 / 全量重建里「这一行引用的快照原文」的 SQL 表达式（[side] = `NEW.` / `OLD.` / 空）。只对带引用标记的行
/// 解析 JSON（别的行可能根本不是 JSON）。
pub fn body_sql(side: &str) -> String {
    format!(
        "CASE WHEN instr({side}json, '{REF_MARK}') > 0 THEN \
         (SELECT body FROM sync2_snapshots WHERE hash = json_extract({side}json, '$.{SNAPSHOT_KEY}')) END"
    )
}

/// 已盖戳事件并回来（Dart 从投影读出的日志）时日志 `extra` 里的引用展开成原文；本库里没有这份快照就原样留着
/// （重放把它当作没有快照，按作者结果照抄）。
pub(crate) fn expand_extra(c: &Connection, extra: &mut String) -> Result<(), String> {
    if !extra.contains(REF_MARK) {
        return Ok(());
    }
    let Ok(Value::Object(mut m)) = serde_json::from_str::<Value>(extra) else { return Ok(()) };
    let Some(h) = m.get(SNAPSHOT_KEY).and_then(Value::as_str).filter(|h| is_ref(h)).map(str::to_owned) else { return Ok(()) };
    let Some(body) = body_of(c, &h)? else { return Ok(()) };
    m.insert(SNAPSHOT_KEY.into(), serde_json::from_str(&body).map_err(|e| format!("bad config snapshot {h}: {e}"))?);
    *extra = canonical(&Value::Object(m));
    Ok(())
}

// ---------------------------------------------------------------- v16 升级

/// 存量行改成引用形态（升级一次；可重放：已是引用的行不再动）。
pub(crate) fn migrate(c: &Connection) -> Result<(), String> {
    c.execute_batch(V16).map_err(sql)?;
    for (col, ty) in [("sc", "TEXT"), ("sc_at", "INTEGER")] {
        let has: i64 = c
            .query_row("SELECT COUNT(*) FROM pragma_table_info('sync2_ops') WHERE name = ?1", [col], |r| r.get(0))
            .map_err(sql)?;
        if has == 0 {
            c.execute_batch(&format!("ALTER TABLE sync2_ops ADD COLUMN {col} {ty} NULL;")).map_err(sql)?;
        }
    }
    // 操作日志：按主键分批读、逐行改（只有带快照原文的日志操作）。
    let ops: Vec<(String, Vec<u8>, i64, Vec<u8>)> = {
        let mut stmt = c
            .prepare("SELECT profile_uid, device, seq, payload FROM sync2_ops WHERE kind = ?1 AND sc IS NULL AND purged = 0")
            .map_err(sql)?;
        let mut q = stmt.query([i64::from(op::KIND_LOG)]).map_err(sql)?;
        let mut out = Vec::new();
        while let Some(r) = q.next().map_err(sql)? {
            let p: Vec<u8> = r.get(3).map_err(sql)?;
            if contains(&p, b"\"sc\":{") {
                out.push((r.get(0).map_err(sql)?, r.get(1).map_err(sql)?, r.get(2).map_err(sql)?, p));
            }
        }
        out
    };
    let mut up = c
        .prepare("UPDATE sync2_ops SET payload = ?4, sc = ?5, sc_at = ?6 WHERE profile_uid = ?1 AND device = ?2 AND seq = ?3")
        .map_err(sql)?;
    for (profile, device, seq, payload) in ops {
        let (stored, sc, at) = pack_payload(c, op::KIND_LOG, &payload)?;
        if sc.is_some() {
            up.execute(params![profile, device, seq, stored, sc, at]).map_err(sql)?;
        }
    }
    // 日志投影（摘要触发器先换成展开后算的版本，见 [super::digest::install]；改写前后展开结果相同，触发器不动桶）。
    let rows: Vec<(i64, String)> = {
        let mut stmt = c.prepare("SELECT rowid, json FROM srs_review_logs WHERE instr(json, '\"sc\":{') > 0").map_err(sql)?;
        let rows = stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?))).map_err(sql)?;
        rows.collect::<Result<_, _>>().map_err(sql)?
    };
    let mut up = c.prepare("UPDATE srs_review_logs SET json = ?2 WHERE rowid = ?1").map_err(sql)?;
    for (rowid, json) in rows {
        if let Some(out) = compact_text(c, &json)? {
            up.execute(params![rowid, out]).map_err(sql)?;
        }
    }
    Ok(())
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

    #[test]
    fn projection_rows_expand_to_the_original_text() {
        let c = Connection::open_in_memory().unwrap();
        c.execute_batch(V16).unwrap();
        let row = serde_json::json!({
            "id": "L", "res": {"queue": "review", "ivl": 3},
            "sc": {"alg": "fsrs", "learn": [60000, 600000], "relearn": [600000], "ret": 0.9, "w": [0.4, 1.18, 3.1, 15.7]},
        });
        let text = canonical(&row);
        let compact = compact_text(&c, &text).unwrap().expect("compacted");
        assert!(compact.len() < text.len() / 2 + 40, "{compact}");
        assert_eq!(expand_text(&c, compact.clone()).unwrap(), text);
        let body: String = c.query_row("SELECT body FROM sync2_snapshots", [], |r| r.get(0)).unwrap();
        assert_eq!(expand_with(&compact, Some(&body)), text);
        // 非规范的原文不动（展开回不到逐字相同）；短快照不去重。
        assert_eq!(compact_text(&c, &format!(" {text}")).unwrap(), None);
        assert_eq!(compact_text(&c, "{\"id\":\"L\",\"sc\":{\"a\":1}}").unwrap(), None);
        // 引用的快照不在：读侧报错，不悄悄当作没有。
        assert!(expand_text(&c, "{\"sc\":\"00000000000000000000000000000000\"}".into()).is_err());
    }
}
