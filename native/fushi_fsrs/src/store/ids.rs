//! ID 列的存储编码（srs.db v17，2026-10-30 磁盘占用）。
//!
//! profile、实体、卡片、笔记、日志、修改记录的 ID 几乎都是规范小写带连字符的 UUID 文本（36 字节）。存储层把这种值存成
//! 16 字节 BLOB，其它值（旧库里的非 UUID ID、`sync2:tags:…` 这类合成写者）原样存 TEXT——编码无损：16 字节 BLOB
//! 解码回小写带连字符文本，别的值不动。
//!
//! - 列声明类型是 [DECLTYPE]（含 TEXT → TEXT 亲和：不会把 BLOB 或数字样的文本乱转）。Dart 经 SQL 桥读到的结果列
//!   按声明类型解码（store/mod.rs），Dart 的读法不变。
//! - 写入、比较时在 SQL 里写 `srs_id(?)`；读出来用 [col] / [text]（或 SQL 里写 `srs_idt(col)`）。
//!   漏编码的绑定是静默查不到：测试构建里 [audit] 盯住每条语句的扩展 SQL，绑了 UUID 形状的文本参数就报错。
//! - 排序：UUID 的 BLOB 字节序与它的小写十六进制文本字典序一致；非 UUID 的文本 ID 与 BLOB 混排时 SQLite 把 TEXT
//!   排在 BLOB 前面——确定性路径都按 ID 精确匹配或按 (device, seq) 排，不依赖混排顺序。

use rusqlite::Connection;
use rusqlite::functions::FunctionFlags;
use rusqlite::types::{FromSql, FromSqlError, FromSqlResult, Value, ValueRef};

/// ID 列的声明类型。
pub(crate) const DECLTYPE: &str = "UUIDTEXT";

fn hex(b: u8) -> Option<u8> {
    match b {
        b'0'..=b'9' => Some(b - b'0'),
        b'a'..=b'f' => Some(b - b'a' + 10),
        _ => None,
    }
}

/// 规范小写带连字符 UUID 文本 → 16 字节；别的文本 None。
pub(crate) fn pack(s: &str) -> Option<[u8; 16]> {
    let b = s.as_bytes();
    if b.len() != 36 || b[8] != b'-' || b[13] != b'-' || b[18] != b'-' || b[23] != b'-' {
        return None;
    }
    let mut out = [0u8; 16];
    let mut k = 0;
    let mut i = 0;
    while i < 36 {
        if i == 8 || i == 13 || i == 18 || i == 23 {
            i += 1;
            continue;
        }
        out[k] = (hex(b[i])? << 4) | hex(b[i + 1])?;
        k += 1;
        i += 2;
    }
    Some(out)
}

/// 16 字节 → 小写带连字符文本。
pub(crate) fn unpack(b: &[u8; 16]) -> String {
    let mut s = String::with_capacity(36);
    unpack_into(b, &mut s);
    s
}

/// [unpack] 接到 [s] 末尾（不另分配）。
pub(crate) fn unpack_into(b: &[u8; 16], s: &mut String) {
    const H: &[u8; 16] = b"0123456789abcdef";
    for (i, x) in b.iter().enumerate() {
        if i == 4 || i == 6 || i == 8 || i == 10 {
            s.push('-');
        }
        s.push(H[(x >> 4) as usize] as char);
        s.push(H[(x & 15) as usize] as char);
    }
}

/// 存储值 → ID 文本（16 字节 BLOB 解码；TEXT 原样；别的类型 None）。
pub(crate) fn text(v: ValueRef<'_>) -> Option<String> {
    match v {
        ValueRef::Blob(b) if b.len() == 16 => Some(unpack(b.try_into().expect("16 bytes"))),
        ValueRef::Text(t) => Some(String::from_utf8_lossy(t).into_owned()),
        _ => None,
    }
}

/// 读出一个 ID。
#[derive(Clone, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub(crate) struct Id(pub String);

impl FromSql for Id {
    fn column_result(v: ValueRef<'_>) -> FromSqlResult<Self> {
        text(v).map(Id).ok_or(FromSqlError::InvalidType)
    }
}

/// 行里第 [i] 列的 ID。
pub(crate) fn col(r: &rusqlite::Row<'_>, i: usize) -> rusqlite::Result<String> {
    r.get::<_, Id>(i).map(|x| x.0)
}

/// 给 Dart 的结果里哪几列是 ID 列（声明类型 [DECLTYPE]；表达式列没有声明类型，SQL 里自己套 `srs_idt`）。
pub(crate) fn id_columns(stmt: &rusqlite::Statement<'_>) -> Vec<bool> {
    stmt.columns()
        .iter()
        .map(|c| c.decl_type() == Some(DECLTYPE))
        .collect()
}

/// 结果第 [i] 列的值交给 Dart 前：ID 列的 16 字节 BLOB 还原成 ID 文本（Dart 看到的格式与 v17 之前相同）。
pub(crate) fn outward(id_cols: &[bool], i: usize, v: ValueRef<'_>) -> Option<String> {
    match v {
        ValueRef::Blob(b) if b.len() == 16 && id_cols[i] => {
            Some(unpack(b.try_into().expect("16 bytes")))
        }
        #[cfg(feature = "id_audit")]
        ValueRef::Blob(b) if b.len() == 16 => {
            audit::HITS
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .push(format!("ID blob returned to Dart in column {i}"));
            None
        }
        _ => None,
    }
}

/// `srs_id(x)`：ID 文本 → 存储值（BLOB / NULL 原样）；`srs_idt(x)`：存储值 → ID 文本。SQL 里拼 ID、Dart 原生 SQL
/// 绑定 ID、从 JSON 里取出 ID 再和列比较时用。确定性、无副作用（SQLite 把常量参数的调用提到循环外）。
pub(crate) fn register(conn: &Connection) -> rusqlite::Result<()> {
    let flags = FunctionFlags::SQLITE_UTF8
        | FunctionFlags::SQLITE_DETERMINISTIC
        | FunctionFlags::SQLITE_INNOCUOUS;
    conn.create_scalar_function("srs_id", 1, flags, |ctx| {
        Ok(match ctx.get_raw(0) {
            ValueRef::Text(t) => match std::str::from_utf8(t).ok().and_then(pack) {
                Some(b) => Value::Blob(b.to_vec()),
                None => Value::Text(String::from_utf8_lossy(t).into_owned()),
            },
            v => Value::from(v),
        })
    })?;
    conn.create_scalar_function("srs_idt", 1, flags, |ctx| {
        Ok(match ctx.get_raw(0) {
            ValueRef::Blob(b) if b.len() == 16 => {
                Value::Text(unpack(b.try_into().expect("16 bytes")))
            }
            v => Value::from(v),
        })
    })?;
    Ok(())
}

/// 测试构建：每条语句跑之前看扩展 SQL，有**没套 `srs_id(…)`** 的 UUID 形状文本（`'xxxxxxxx-xxxx-…'`，绑定参数
/// 展开后的样子）就记下来——ID 列存的是 BLOB，这样的绑定查不到也写错形状。整条语句一个 `srs_id(` 都没有时，任何
/// 这样的字面量都算；有 `srs_id(` 时（以前这种整条放行），逐个字面量看它和哪一列比较：拿去和 ID 列（[COLUMNS]
/// 里的列名）比较（`列 = '…'` / `列 IN ('…'` 等）的仍然算漏写——同一条语句里别的参数套了 `srs_id(?)` 不替它担保；
/// 认不出比较对象的（写进文本列、函数参数）照旧放行。只有 [allowed] 里的语句例外（比较 JSON 里的值、元数据表、
/// 显式标了 `-- ids:text` 的）。
#[cfg(any(test, feature = "id_audit"))]
pub(crate) mod audit {
    use std::sync::Mutex;

    pub(crate) static HITS: Mutex<Vec<String>> = Mutex::new(Vec::new());

    /// 参数本来就是 ID 文本的 SQL 函数：拿列值的文本形式去和 JSON 比对、把 JSON 压成 jslim / 还原（store/slim.rs
    /// `register`）。字面量在它们的参数里（任意深度）不算漏写。
    const TEXT_ID_FNS: [&str; 4] = [
        "srs_log_pack",
        "srs_edit_pack",
        "srs_log_json",
        "srs_edit_json",
    ];

    /// [head]（字面量前面的 SQL）以「列 比较符」结尾时的列名（去掉 `表.` 前缀）；认不出为 None。
    fn compared_column(head: &str) -> Option<&str> {
        let mut h = head.trim_end();
        let upper = h.to_ascii_uppercase();
        let in_len = if upper.ends_with(" IN (") {
            5
        } else if upper.ends_with(" IN(") {
            4
        } else {
            0
        };
        if in_len > 0 {
            h = h[..h.len() - in_len].trim_end();
            if h.to_ascii_uppercase().ends_with(" NOT") {
                h = h[..h.len() - 4].trim_end();
            }
        } else if let Some(op) = ["==", "!=", "<>", "="].iter().find(|op| h.ends_with(**op)) {
            h = h[..h.len() - op.len()].trim_end();
        } else if upper.ends_with(" IS") {
            h = h[..h.len() - 3].trim_end();
        } else {
            return None;
        }
        let name = trailing_ident(h);
        (!name.is_empty()).then_some(name)
    }

    /// [s] 末尾那段标识符（ASCII 字母数字与 `_`）。按字符边界切：前面可能是中文等多字节字符（测试数据、笔记内容）。
    fn trailing_ident(s: &str) -> &str {
        let start = s
            .char_indices()
            .rev()
            .find(|&(_, c)| !(c.is_ascii_alphanumeric() || c == '_'))
            .map_or(0, |(k, c)| k + c.len_utf8());
        &s[start..]
    }

    fn is_id_column(name: &str) -> bool {
        super::COLUMNS
            .iter()
            .any(|(_, cols)| cols.iter().any(|c| c.eq_ignore_ascii_case(name)))
    }

    /// [sql]（绑定参数展开后的扩展 SQL）里有没有漏套 `srs_id(` 的 UUID 文本字面量（规则见模块说明）。`srs_id(` 的
    /// 直接参数、[TEXT_ID_FNS] 的参数（任意深度）不算。
    fn quoted_uuid(sql: &str) -> bool {
        let has_wrap = sql.to_ascii_lowercase().contains("srs_id(");
        let b = sql.as_bytes();
        // 每一层开着的括号：是不是 [TEXT_ID_FNS] 的调用。
        let mut calls: Vec<bool> = Vec::new();
        let mut i = 0;
        while i < b.len() {
            match b[i] {
                b'\'' => {
                    let start = i + 1;
                    let mut j = start;
                    loop {
                        if j >= b.len() {
                            return false;
                        }
                        if b[j] == b'\'' {
                            if j + 1 < b.len() && b[j + 1] == b'\'' {
                                j += 2;
                                continue;
                            }
                            break;
                        }
                        j += 1;
                    }
                    let lit = &sql[start..j];
                    if lit.len() == 36 && super::pack(lit).is_some() {
                        let head = &sql[..i];
                        let tail = head.trim_end().as_bytes();
                        let wrapped = tail.len() >= 7
                            && tail[tail.len() - 7..].eq_ignore_ascii_case(b"srs_id(");
                        let bare = !wrapped && !calls.iter().any(|&c| c);
                        if bare && (!has_wrap || compared_column(head).is_some_and(is_id_column)) {
                            return true;
                        }
                    }
                    i = j + 1;
                }
                b'(' => {
                    let name = trailing_ident(sql[..i].trim_end());
                    calls.push(TEXT_ID_FNS.iter().any(|f| name.eq_ignore_ascii_case(f)));
                    i += 1;
                }
                b')' => {
                    calls.pop();
                    i += 1;
                }
                _ => i += 1,
            }
        }
        false
    }

    fn allowed(sql: &str) -> bool {
        sql.contains("json_extract") || sql.contains("srs_meta") || sql.contains("-- ids:text")
    }

    /// 有漏编码的绑定就失败（测试里关库时调；只取走本进程到此为止记下的那些）。
    pub(crate) fn check() {
        let hits = std::mem::take(&mut *HITS.lock().unwrap_or_else(|e| e.into_inner()));
        if !hits.is_empty() && !std::thread::panicking() {
            panic!(
                "ID bound as text ({}):
{}",
                hits.len(),
                hits.iter().take(5).cloned().collect::<Vec<_>>().join(
                    "
---
"
                )
            );
        }
    }

    /// ID 列里不许有文本形式的 UUID（经 SQL 从别处搬来、没过 `srs_id` 的值）：有就记下来。
    pub(crate) fn check_stored(c: &rusqlite::Connection) {
        let found = stored_text(c);
        HITS.lock().unwrap_or_else(|e| e.into_inner()).extend(found);
    }

    pub(crate) fn stored_text(c: &rusqlite::Connection) -> Vec<String> {
        let mut out = Vec::new();
        for (table, cols) in super::COLUMNS {
            for col in *cols {
                let q = format!(
                    "SELECT srs_idt({col}) FROM {table} WHERE typeof({col}) = 'text' AND typeof(srs_id({col})) = 'blob' LIMIT 1"
                );
                if let Ok(v) = c.query_row(&q, [], |r| r.get::<_, String>(0)) {
                    out.push(format!("{table}.{col} stores text UUID {v}"));
                }
            }
        }
        out
    }

    pub(crate) fn quoted(sql: &str) -> bool {
        quoted_uuid(sql) && !allowed(sql)
    }

    #[allow(deprecated)]
    pub(crate) fn install(conn: &mut rusqlite::Connection) {
        conn.trace(Some(|sql: &str| {
            if quoted_uuid(sql) && !allowed(sql) {
                HITS.lock().unwrap().push(sql.to_owned());
            }
        }));
    }

    /// Dart 经桥跑的一条语句之后：这期间记下的绑定 / 存储问题转成错误返回（`id_audit` 构建的库）。
    #[cfg(feature = "id_audit")]
    pub(crate) fn take(c: &rusqlite::Connection, sql: &str) -> Result<(), String> {
        if c.is_autocommit() && !sql.trim_start().to_ascii_uppercase().starts_with("SELECT") {
            check_stored(c);
        }
        let hits = std::mem::take(&mut *HITS.lock().unwrap_or_else(|e| e.into_inner()));
        if hits.is_empty() {
            return Ok(());
        }
        Err(format!("id audit: {}", hits.join("\n---\n")))
    }

    pub(crate) fn installed(mut conn: rusqlite::Connection) -> rusqlite::Connection {
        install(&mut conn);
        conn
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 两道测试期检查自己会响：存了文本 UUID 的列、绑了文本 UUID 的语句都能被认出来。
    #[test]
    fn the_audits_catch_text_uuids() {
        let c = Connection::open_in_memory().unwrap();
        register(&c).unwrap();
        let u = "01928c3e-0000-7000-8000-0000000a5e01";
        c.execute_batch(
            "CREATE TABLE srs_local_state (profile_uid UUIDTEXT NOT NULL, json TEXT NOT NULL)",
        )
        .unwrap();
        c.execute("INSERT INTO srs_local_state VALUES (srs_id(?1), '{}')", [u])
            .unwrap();
        assert!(audit::stored_text(&c).is_empty());
        c.execute("INSERT INTO srs_local_state VALUES (?1, '{}')", [u])
            .unwrap();
        assert_eq!(
            audit::stored_text(&c),
            vec![format!("srs_local_state.profile_uid stores text UUID {u}")]
        );
        assert!(audit::quoted(&format!(
            "SELECT 1 FROM t WHERE profile_uid = '{u}'"
        )));
        assert!(!audit::quoted(&format!(
            "SELECT 1 FROM t WHERE profile_uid = srs_id('{u}')"
        )));
        assert!(!audit::quoted(&format!(
            "SELECT 1 FROM t WHERE profile_uid = SRS_ID( '{u}') AND id IN (srs_id('{u}'))"
        )));
        // 同一条语句里别的参数套了 srs_id 不替漏写的那个担保（以前整条语句见到 `srs_id(` 就放行）。
        assert!(audit::quoted(&format!(
            "SELECT 1 FROM t WHERE profile_uid = srs_id('{u}') AND card_id = '{u}'"
        )));
        assert!(audit::quoted(&format!(
            "SELECT 1 FROM t WHERE t.card_id IN ('{u}') AND note_id = srs_id('{u}')"
        )));
        assert!(audit::quoted(&format!("INSERT INTO t VALUES ('{u}', 1)")));
        // 括号 / 比较符前紧挨多字节字符时按字符边界切（以前切进「：」中间 panic）。
        assert!(audit::quoted(&format!(
            "SELECT 1 /* 注：(说明) */ FROM t WHERE card_id = '{u}'"
        )));
        assert!(!audit::quoted(&format!(
            "SELECT srs_id('{u}') FROM t WHERE 卡= '{u}'"
        )));
        // 有 srs_id 的语句里写进文本列的 UUID（如笔记的 guid）不是漏写；写进 ID 列的由存储检查（[audit::stored_text]）抓。
        assert!(!audit::quoted(&format!(
            "INSERT INTO t (id, guid) VALUES (srs_id('{u}'), '{u}')"
        )));
        assert!(!audit::quoted(&format!(
            "UPDATE t SET guid = '{u}' WHERE id = srs_id('{u}')"
        )));
        // 拿列值文本和 JSON 比对的函数（store/slim.rs）的参数本来就是 ID 文本。
        assert!(!audit::quoted(&format!(
            "INSERT INTO t VALUES (srs_id('{u}'), srs_edit_pack('{{\"id\":\"{u}\"}}', '{u}', 'x''y', '{u}'))"
        )));
        assert!(audit::quoted(&format!(
            "SELECT srs_log_pack('{{}}', '{u}') FROM t WHERE id = '{u}' AND p = srs_id('{u}')"
        )));
        assert!(!audit::quoted(
            "SELECT 1 FROM t WHERE profile_uid = x'01928c3e000070008000000000a5e01'"
        ));
    }

    #[test]
    fn round_trips_uuids_and_leaves_other_text_alone() {
        for s in [
            "01928c3e-0000-7000-8000-0000000a5e01",
            "ffffffff-ffff-ffff-ffff-ffffffffffff",
            "00000000-0000-0000-0000-000000000000",
        ] {
            assert_eq!(unpack(&pack(s).unwrap()), s);
        }
        for s in [
            "",
            "deck-default",
            "01928C3E-0000-7000-8000-0000000A5E01",
            "01928c3e00007000800000000a5e01aa",
            "sync2:tags:x",
            "01928c3e-0000-7000-8000-0000000a5e0g",
        ] {
            assert!(pack(s).is_none(), "{s}");
        }
        // 字节序 = 文本字典序。
        let mut a = [
            "9f000000-0000-0000-0000-000000000000",
            "0a000000-0000-0000-0000-000000000001",
            "0a000000-0000-0000-0000-000000000000",
        ];
        let mut b: Vec<[u8; 16]> = a.iter().map(|s| pack(s).unwrap()).collect();
        a.sort();
        b.sort();
        assert_eq!(a.to_vec(), b.iter().map(unpack).collect::<Vec<_>>());
    }
}

/// 存 ID 的列（表 → 列）。同一个域（profile、实体）在所有表里一律同一编码，联表比较才成立。
pub(crate) const COLUMNS: &[(&str, &[&str])] = &[
    (
        "srs_cards_cache",
        &[
            "id",
            "profile_uid",
            "note_id",
            "template_id",
            "deck_id",
            "last_log_id",
        ],
    ),
    ("srs_entities", &["id", "profile_uid"]),
    ("srs_event_local", &["event_id", "profile_uid"]),
    (
        "srs_field_edits",
        &["id", "profile_uid", "entity_id", "writer_id"],
    ),
    ("srs_local_state", &["profile_uid"]),
    (
        "srs_notes_cache",
        &["id", "profile_uid", "note_type_id", "deck_id"],
    ),
    ("srs_review_logs", &["id", "profile_uid", "card_id"]),
    ("srs_sent_batches", &["profile_uid", "writer_id"]),
    ("srs_stat_reviews", &["log_id", "profile_uid", "card_id"]),
    ("srs_unknown_events", &["id", "profile_uid"]),
    ("sync2_boot", &["profile_uid"]),
    ("sync2_boot_complex", &["profile_uid", "entity"]),
    ("sync2_boot_moves", &["profile_uid", "deck", "card"]),
    ("sync2_boot_order", &["profile_uid"]),
    ("sync2_boot_rows", &["profile_uid"]),
    ("sync2_cache_pending", &["profile_uid", "entity_id"]),
    ("sync2_dedup", &["profile_uid"]),
    ("sync2_dedup_keys", &["profile_uid"]),
    ("sync2_dedup_pairs", &["profile_uid"]),
    ("sync2_dedup_regs", &["profile_uid"]),
    ("sync2_card_deck", &["card_id", "profile_uid", "deck_id"]),
    ("sync2_checkpoints", &["profile_uid"]),
    ("sync2_conflicts", &["id", "profile_uid", "entity"]),
    ("sync2_devices", &["profile_uid"]),
    ("sync2_digest_buckets", &["profile_uid"]),
    ("sync2_edit_ops", &["edit_id", "profile_uid"]),
    ("sync2_ent_ops", &["profile_uid", "entity"]),
    ("sync2_held", &["profile_uid", "entity"]),
    ("sync2_legacy", &["profile_uid"]),
    ("sync2_location_heads", &["profile_uid"]),
    ("sync2_locations", &["profile_uid"]),
    (
        "sync2_log_meta",
        &["log_id", "profile_uid", "card_id", "note_id"],
    ),
    ("sync2_media", &["profile_uid"]),
    ("sync2_media_at", &["profile_uid"]),
    ("sync2_media_local", &["profile_uid"]),
    ("sync2_media_seeded", &["profile_uid"]),
    ("sync2_migrate_queue", &["profile_uid"]),
    ("sync2_mvr", &["profile_uid"]),
    ("sync2_obsolete", &["profile_uid"]),
    ("sync2_ops", &["profile_uid"]),
    ("sync2_pending", &["profile_uid"]),
    ("sync2_purged", &["profile_uid", "entity"]),
    ("sync2_relay_gone", &["profile_uid"]),
    ("sync2_relay_heads", &["profile_uid"]),
    ("sync2_relay_out", &["profile_uid"]),
    ("sync2_relay_segs", &["profile_uid"]),
    ("sync2_replay_pending", &["profile_uid", "card_id"]),
    ("sync2_rewrites", &["profile_uid"]),
    ("sync2_segments", &["profile_uid"]),
    ("sync2_self", &["profile_uid"]),
    ("sync2_tag_adds", &["profile_uid", "note"]),
    ("sync2_tag_order", &["profile_uid", "note"]),
    ("sync2_trust", &["profile_uid"]),
    ("sync2_trust_held", &["profile_uid", "entity"]),
];

fn sql_err(e: rusqlite::Error) -> String {
    e.to_string()
}

/// 把 [COLUMNS] 里已存在的表重建成 ID 列声明为 [DECLTYPE]、值经 `srs_id` 编码（v17）。已经是新形状的表只再编码一遍
/// 残留的文本 UUID（可重放）；表上的索引与触发器原样重建。升级阶梯在开头（之后的旧步骤用新代码读写）和结尾（中途
/// 建出来的表）各调一次。
pub(crate) fn migrate(c: &Connection) -> Result<(), String> {
    let decl =
        regex::Regex::new(r#"(?i)^(\s*"?)([A-Za-z_][A-Za-z0-9_]*)("?\s+)TEXT\b"#).expect("regex");
    c.execute_batch("PRAGMA legacy_alter_table = ON;")
        .map_err(sql_err)?;
    for (table, cols) in COLUMNS {
        let Some(sql) = c
            .query_row(
                "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?1",
                [table],
                |r| r.get::<_, String>(0),
            )
            .ok()
        else {
            continue;
        };
        let shaped: Vec<(String, String)> = {
            let mut s = c
                .prepare(&format!(
                    "SELECT name, type FROM pragma_table_info('{table}')"
                ))
                .map_err(sql_err)?;
            let rows = s
                .query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))
                .map_err(sql_err)?;
            rows.collect::<Result<_, _>>().map_err(sql_err)?
        };
        let present: Vec<&str> = cols
            .iter()
            .copied()
            .filter(|c| shaped.iter().any(|(n, _)| n == c))
            .collect();
        if present.is_empty() {
            continue;
        }
        let reshaped = present.iter().all(|c| {
            shaped
                .iter()
                .any(|(n, t)| n == c && t.eq_ignore_ascii_case(DECLTYPE))
        });
        if reshaped {
            for col in &present {
                c.execute(
                    &format!(
                        "UPDATE {table} SET {col} = srs_id({col}) WHERE typeof({col}) = 'text'"
                    ),
                    [],
                )
                .map_err(sql_err)?;
            }
            continue;
        }
        // 建表语句按顶层逗号切开，逐个列定义改类型。
        let open = sql.find('(').ok_or("no column list")?;
        let close = sql.rfind(')').ok_or("no column list")?;
        let (head, body, tail) = (&sql[..open + 1], &sql[open + 1..close], &sql[close..]);
        let mut parts: Vec<String> = Vec::new();
        let (mut depth, mut start) = (0i32, 0usize);
        for (i, ch) in body.char_indices() {
            match ch {
                '(' => depth += 1,
                ')' => depth -= 1,
                ',' if depth == 0 => {
                    parts.push(body[start..i].to_owned());
                    start = i + 1;
                }
                _ => {}
            }
        }
        parts.push(body[start..].to_owned());
        let parts: Vec<String> = parts
            .into_iter()
            .map(|p| match decl.captures(&p) {
                Some(m) if present.iter().any(|c| c.eq_ignore_ascii_case(&m[2])) => decl
                    .replace(&p, format!("${{1}}${{2}}${{3}}{DECLTYPE}").as_str())
                    .into_owned(),
                _ => p,
            })
            .collect();
        let tmp = format!("{table}__v17");
        let create = format!("{}{}{}", head, parts.join(","), tail);
        let create = create.replacen(table, &tmp, 1);
        let rowid = !tail.to_ascii_uppercase().contains("WITHOUT ROWID");
        let names: Vec<&str> = shaped.iter().map(|(n, _)| n.as_str()).collect();
        let select: Vec<String> = names
            .iter()
            .map(|n| {
                if present.contains(n) {
                    format!("srs_id({n})")
                } else {
                    (*n).to_owned()
                }
            })
            .collect();
        let (ins_cols, sel_cols) = if rowid {
            (
                format!("rowid, {}", names.join(", ")),
                format!("rowid, {}", select.join(", ")),
            )
        } else {
            (names.join(", "), select.join(", "))
        };
        let extras: Vec<String> = {
            let mut s = c
                .prepare("SELECT sql FROM sqlite_master WHERE tbl_name = ?1 AND type IN ('index', 'trigger') AND sql IS NOT NULL")
                .map_err(sql_err)?;
            let rows = s
                .query_map([table], |r| r.get::<_, String>(0))
                .map_err(sql_err)?;
            rows.collect::<Result<_, _>>().map_err(sql_err)?
        };
        c.execute_batch(&format!(
            "DROP TABLE IF EXISTS {tmp}; {create}; INSERT INTO {tmp} ({ins_cols}) SELECT {sel_cols} FROM {table}; \
             DROP TABLE {table}; ALTER TABLE {tmp} RENAME TO {table};"
        ))
        .map_err(|e| format!("{table}: {e}"))?;
        for x in extras {
            c.execute_batch(&x)
                .map_err(|e| format!("{table}: {e} in {x}"))?;
        }
    }
    c.execute_batch("PRAGMA legacy_alter_table = OFF;")
        .map_err(sql_err)?;
    Ok(())
}
