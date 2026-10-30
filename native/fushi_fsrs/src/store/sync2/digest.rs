//! 状态摘要（设计 §4.5「按卡 ID 分桶的 Merkle 摘要」；2026-10-29 审查 S-7）。
//!
//! 以前摘要是全库扫描：三张投影表按 ID 排序逐行 BLAKE3（100 万条复习桌面约 3.5 s、手机更久），只比根哈希、不一致也
//! 定位不到。现在：
//! - 每行的哈希 `H(tag, id, body)`（与旧摘要同一个输入：实体 `kind || payload_json`、修改记录 `json`、日志 `json`，
//!   都是各设备逐位相同的确定性投影）落进 [BUCKETS] 个桶之一（`blake3(id)` 前两字节），桶值是桶内各行哈希按 4 个
//!   u64 分量的**回绕加法和**——与行的顺序无关、可增可减；
//! - 三张表上的触发器在每次 INSERT / UPDATE / DELETE 时增减对应桶（`sync2_digest_buckets`），所以维护是 O(变更)，
//!   任何写入路径（投影、重放写回、清除、换身份撤出、Drift 直写）都不会漏；
//! - 根 = `blake3(域分隔 || 全部桶值按桶号顺序)`，读 4096 行算完；两台设备根不同时比桶表（`sync2_digest_buckets`
//!   命令）就知道是哪个桶、哪些 ID 范围不一致。
//!
//! 与旧格式不能比：摘要串里版本向量的部分带 `2:` 前缀（`<根>@2:<vv>`）。老版本设备只在 `vv` 部分逐字相同时才比根，
//! 所以它们不会把新格式误报成「确定性 bug」；新设备也只比两边都是新格式的摘要。

use rusqlite::functions::FunctionFlags;
use rusqlite::{params, Connection};

use super::sql;

/// 桶数（2^12）。100 万行时一桶约 250 行：定位到的范围足够小，根也只要读 4096 行。
pub const BUCKETS: usize = 4096;

/// 摘要串里版本向量部分的格式前缀（见文件头）。
pub const VV_PREFIX: &str = "2:";

/// 一个桶的值：4 个 u64 分量的回绕加法和（小端存成 32 字节）。
type Sum = [u64; 4];

fn sum_of(b: &[u8]) -> Sum {
    let mut s = [0u64; 4];
    for (i, lane) in s.iter_mut().enumerate() {
        if let Some(chunk) = b.get(i * 8..i * 8 + 8) {
            *lane = u64::from_le_bytes(chunk.try_into().expect("8 bytes"));
        }
    }
    s
}

fn bytes_of(s: &Sum) -> Vec<u8> {
    s.iter().flat_map(|x| x.to_le_bytes()).collect()
}

/// 一行的哈希（与旧摘要的逐行输入同形：tag、长度前缀的 ID 与正文）。
pub fn row_hash(tag: u8, id: &str, body: &str) -> Sum {
    let mut h = blake3::Hasher::new();
    h.update(&[tag]);
    h.update(&(id.len() as u64).to_le_bytes());
    h.update(id.as_bytes());
    h.update(&(body.len() as u64).to_le_bytes());
    h.update(body.as_bytes());
    sum_of(h.finalize().as_bytes())
}

/// ID 所在的桶。
pub fn bucket_of(id: &str) -> i64 {
    let h = blake3::hash(id.as_bytes());
    (u16::from_le_bytes([h.as_bytes()[0], h.as_bytes()[1]]) as usize % BUCKETS) as i64
}

/// 触发器用的 SQL 函数（每条连接打开时注册；写连接上没有它们，三张投影表的写入会报错——这是故意的：宁可报错也不能
/// 让摘要静默漏记）。
pub fn register(conn: &Connection) -> rusqlite::Result<()> {
    let flags = FunctionFlags::SQLITE_UTF8 | FunctionFlags::SQLITE_DETERMINISTIC | FunctionFlags::SQLITE_INNOCUOUS;
    conn.create_scalar_function("sync2_dg_bucket", 1, flags, |ctx| {
        let id: String = ctx.get(0)?;
        Ok(bucket_of(&id))
    })?;
    conn.create_scalar_function("sync2_dg_row", 3, flags, |ctx| {
        let tag: String = ctx.get(0)?;
        let id: String = ctx.get(1)?;
        let body: Option<String> = ctx.get(2)?;
        Ok(bytes_of(&row_hash(tag.as_bytes().first().copied().unwrap_or(0), &id, body.as_deref().unwrap_or(""))))
    })?;
    // 日志行按快照引用展开后的原文（snapshots.rs）：第二个参数是触发器子查询取到的快照原文（没有引用 = NULL）。
    conn.create_scalar_function("sync2_dg_log", 2, flags, |ctx| {
        let json: Option<String> = ctx.get(0)?;
        let body: Option<String> = ctx.get(1)?;
        Ok(json.map(|j| super::snapshots::expand_with(&j, body.as_deref())))
    })?;
    for (name, sign) in [("sync2_dg_add", false), ("sync2_dg_sub", true)] {
        conn.create_scalar_function(name, 2, flags, move |ctx| {
            let a: Vec<u8> = ctx.get(0)?;
            let b: Vec<u8> = ctx.get(1)?;
            let (a, b) = (sum_of(&a), sum_of(&b));
            let mut out = [0u64; 4];
            for i in 0..4 {
                out[i] = if sign { a[i].wrapping_sub(b[i]) } else { a[i].wrapping_add(b[i]) };
            }
            Ok(bytes_of(&out))
        })?;
    }
    Ok(())
}

/// 三张投影表：(表, tag)；正文表达式见 [body_expr]。
const TABLES: [(&str, &str); 3] = [("srs_entities", "e"), ("srs_field_edits", "f"), ("srs_review_logs", "l")];

/// 触发器里一行的正文表达式（[side] = `NEW.` / `OLD.`）：实体 `kind || payload_json`、修改记录 `json`、日志 `json`
/// 按配置快照引用展开后的原文（v16，snapshots.rs）——与引用前逐字相同，所以存储形态改了摘要不变。
fn body_expr(table: &str, side: &str) -> String {
    match table {
        "srs_entities" => format!("{side}kind || {side}payload_json"),
        "srs_review_logs" => format!("sync2_dg_log({side}json, {})", super::snapshots::body_sql(side)),
        _ => format!("{side}json"),
    }
}

/// 全量扫描时的 (正文列, 快照原文列)：与 [body_expr] 同一个输入，展开在 Rust 里做（升级阶梯上的连接不一定注册了
/// 触发器用的 SQL 函数）。
fn scan_cols(table: &str) -> String {
    match table {
        "srs_entities" => "kind || payload_json, NULL".to_owned(),
        "srs_review_logs" => format!("json, {}", super::snapshots::body_sql("")),
        _ => "json, NULL".to_owned(),
    }
}

fn scan_text(r: &rusqlite::Row<'_>, at: usize) -> rusqlite::Result<String> {
    let text: Option<String> = r.get(at)?;
    let body: Option<String> = r.get(at + 1)?;
    let text = text.unwrap_or_default();
    Ok(match body {
        Some(b) => super::snapshots::expand_with(&text, Some(&b)),
        None => text,
    })
}

/// 桶表与触发器（schema V12）。可重放：先删同名触发器再建。
pub fn install(c: &Connection) -> Result<(), String> {
    // 日志行的正文表达式查快照表（[body_expr]）：升级阶梯上 v12 / v14 就装触发器、全量重建，那时还没到 v16。
    c.execute_batch(super::snapshots::V16).map_err(sql)?;
    c.execute_batch(
        "CREATE TABLE IF NOT EXISTS sync2_digest_buckets (
           profile_uid TEXT NOT NULL,
           bucket INTEGER NOT NULL,
           sum BLOB NOT NULL,
           n INTEGER NOT NULL,
           PRIMARY KEY (profile_uid, bucket)
         ) WITHOUT ROWID;",
    )
    .map_err(sql)?;
    for (table, tag) in TABLES {
        let new = body_expr(table, "NEW.");
        let old = body_expr(table, "OLD.");
        // WHEN 比存储原值（不经 SQL 函数：建触发器时就要解析 WHEN，升级阶梯上的连接不一定注册了函数）。只是快照引用 /
        // 内联两种存法互换时也会进来，删旧加新的哈希相同，桶不变。
        let changed = if table == "srs_entities" {
            "(OLD.kind || OLD.payload_json) IS NOT (NEW.kind || NEW.payload_json)"
        } else {
            "OLD.json IS NOT NEW.json"
        };
        let add = |side: &str, expr: &str| {
            format!(
                "INSERT INTO sync2_digest_buckets (profile_uid, bucket, sum, n) \
                 VALUES ({side}.profile_uid, sync2_dg_bucket({side}.id), sync2_dg_row('{tag}', {side}.id, {expr}), 1) \
                 ON CONFLICT(profile_uid, bucket) DO UPDATE SET sum = sync2_dg_add(sum, excluded.sum), n = n + 1;"
            )
        };
        let sub = |side: &str, expr: &str| {
            format!(
                "INSERT INTO sync2_digest_buckets (profile_uid, bucket, sum, n) \
                 VALUES ({side}.profile_uid, sync2_dg_bucket({side}.id), sync2_dg_sub(zeroblob(32), sync2_dg_row('{tag}', {side}.id, {expr})), -1) \
                 ON CONFLICT(profile_uid, bucket) DO UPDATE SET sum = sync2_dg_add(sum, excluded.sum), n = n - 1;"
            )
        };
        c.execute_batch(&format!(
            "DROP TRIGGER IF EXISTS sync2_dg_{table}_ins; DROP TRIGGER IF EXISTS sync2_dg_{table}_del; \
             DROP TRIGGER IF EXISTS sync2_dg_{table}_upd;
             CREATE TRIGGER sync2_dg_{table}_ins AFTER INSERT ON {table} BEGIN {ins} END;
             CREATE TRIGGER sync2_dg_{table}_del AFTER DELETE ON {table} BEGIN {del} END;
             CREATE TRIGGER sync2_dg_{table}_upd AFTER UPDATE ON {table} \
               WHEN OLD.id IS NOT NEW.id OR OLD.profile_uid IS NOT NEW.profile_uid OR {changed} \
               BEGIN {del} {ins} END;",
            ins = add("NEW", &new),
            del = sub("OLD", &old),
        ))
        .map_err(sql)?;
    }
    Ok(())
}

/// 从三张表全量重建桶表（升级时一次；之后由触发器维护）。
pub fn rebuild(c: &Connection) -> Result<(), String> {
    c.execute("DELETE FROM sync2_digest_buckets", []).map_err(sql)?;
    let mut acc: std::collections::BTreeMap<(String, i64), (Sum, i64)> = std::collections::BTreeMap::new();
    for (table, tag) in TABLES {
        let cols = scan_cols(table);
        let mut stmt = c.prepare(&format!("SELECT profile_uid, id, {cols} FROM {table}")).map_err(sql)?;
        let mut q = stmt.query([]).map_err(sql)?;
        while let Some(r) = q.next().map_err(sql)? {
            let profile: String = r.get(0).map_err(sql)?;
            let id: String = r.get(1).map_err(sql)?;
            let text = scan_text(r, 2).map_err(sql)?;
            let h = row_hash(tag.as_bytes()[0], &id, &text);
            let e = acc.entry((profile, bucket_of(&id))).or_insert(([0; 4], 0));
            for i in 0..4 {
                e.0[i] = e.0[i].wrapping_add(h[i]);
            }
            e.1 += 1;
        }
    }
    let mut ins = c
        .prepare("INSERT INTO sync2_digest_buckets (profile_uid, bucket, sum, n) VALUES (?1, ?2, ?3, ?4)")
        .map_err(sql)?;
    for ((profile, bucket), (s, n)) in acc {
        ins.execute(params![profile, bucket, bytes_of(&s), n]).map_err(sql)?;
    }
    Ok(())
}

/// 各桶的值（只列非空桶）：`(桶号, 值 hex, 行数)`。
pub fn buckets(c: &Connection, profile: &str) -> Result<Vec<(i64, String, i64)>, String> {
    c.prepare_cached("SELECT bucket, sum, n FROM sync2_digest_buckets WHERE profile_uid = ?1 AND n != 0 ORDER BY bucket")
        .map_err(sql)?
        .query_map([profile], |r| {
            let b: Vec<u8> = r.get(1)?;
            Ok((r.get(0)?, b.iter().map(|x| format!("{x:02x}")).collect(), r.get(2)?))
        })
        .map_err(sql)?
        .collect::<Result<_, _>>()
        .map_err(sql)
}

/// 根：全部桶值按桶号顺序（空桶 = 0）接起来 BLAKE3。
pub fn root(c: &Connection, profile: &str) -> Result<String, String> {
    let mut all = vec![[0u64; 4]; BUCKETS];
    let mut stmt = c.prepare_cached("SELECT bucket, sum FROM sync2_digest_buckets WHERE profile_uid = ?1").map_err(sql)?;
    let mut q = stmt.query([profile]).map_err(sql)?;
    while let Some(r) = q.next().map_err(sql)? {
        let b: i64 = r.get(0).map_err(sql)?;
        let s: Vec<u8> = r.get(1).map_err(sql)?;
        if let Some(slot) = all.get_mut(b as usize) {
            *slot = sum_of(&s);
        }
    }
    let mut h = blake3::Hasher::new();
    h.update(b"fushi-srs-digest-v2");
    for s in &all {
        h.update(&bytes_of(s));
    }
    Ok(h.finalize().to_hex().to_string())
}

/// 全量扫描算同一个根（不读桶表）：测试对拍「增量维护 = 从头算」。
#[cfg(test)]
pub fn root_by_scan(c: &Connection, profile: &str) -> Result<String, String> {
    let mut all = vec![[0u64; 4]; BUCKETS];
    for (table, tag) in TABLES {
        let cols = scan_cols(table);
        let mut stmt = c.prepare(&format!("SELECT id, {cols} FROM {table} WHERE profile_uid = ?1")).map_err(sql)?;
        let mut q = stmt.query([profile]).map_err(sql)?;
        while let Some(r) = q.next().map_err(sql)? {
            let id: String = r.get(0).map_err(sql)?;
            let text = scan_text(r, 1).map_err(sql)?;
            let h = row_hash(tag.as_bytes()[0], &id, &text);
            let slot = &mut all[bucket_of(&id) as usize];
            for i in 0..4 {
                slot[i] = slot[i].wrapping_add(h[i]);
            }
        }
    }
    let mut h = blake3::Hasher::new();
    h.update(b"fushi-srs-digest-v2");
    for s in &all {
        h.update(&bytes_of(s));
    }
    Ok(h.finalize().to_hex().to_string())
}
