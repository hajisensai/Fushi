//! 投影 JSON 去掉与列重复的键（srs.db v18，2026-10-31 磁盘占用）。
//!
//! 日志投影 `srs_review_logs` 与修改记录投影 `srs_field_edits` 的 `json` 是事件的规范 JSON（serde 的 BTreeMap 键序、紧凑），
//! 其中好几个键（ID、profile、卡 / 实体、种类、时刻……）与同一行的列逐字相同，约占 JSON 的一半。现在磁盘上只存
//! `jslim`：
//!
//! - 去掉「值与列逐字节相同」的那些键，前面加 [SLIM] 标记；列有值而原文没有的键（导入锚点没有 `rtype` / `dur` 之类）
//!   记在标记与 `{` 之间（`~rtype,dur{…}`），拼回时不补；
//! - 写入时先拼回一次，与原文逐字节相同才存瘦的，否则原样存原文（非规范的旧行、键缺失 / 不等的行）——无损。
//!
//! `json` 成了 VIRTUAL 生成列 `srs_log_json(jslim, 列…)` / `srs_edit_json(…)`：Rust、Dart、摘要触发器读到的仍是逐字节
//! 相同的原文，读法不变。拼回只按顶层成员做字节拼接（不经 serde 解析 / 序列化）。写入方写 `jslim`，值用
//! `srs_log_pack(json, 列…)` / `srs_edit_pack(…)` 或 [pack] 算。
//!
//! 生成列要求每条打开库的连接都注册了这几个函数（[register]，store/mod.rs `configure`）；裸 SQLite 读不了 `json`。

use rusqlite::functions::FunctionFlags;
use rusqlite::types::ValueRef;
use rusqlite::Connection;

/// 瘦 JSON 的标记（JSON 文本不会以它开头）。
const SLIM: char = '~';

/// 日志：JSON 键 → 列（与生成列表达式、[LOG_ARGS] 同序）。
pub(crate) const LOG_KEYS: [(&str, &str); 9] = [
    ("id", "id"),
    ("p", "profile_uid"),
    ("card", "card_id"),
    ("kind", "kind"),
    ("rating", "rating"),
    ("at", "occurred_at"),
    ("rtype", "review_type"),
    ("origin", "origin"),
    ("dur", "duration_ms"),
];

/// 修改记录：JSON 键 → 列。
pub(crate) const EDIT_KEYS: [(&str, &str); 7] = [
    ("id", "id"),
    ("p", "profile_uid"),
    ("k", "entity_kind"),
    ("e", "entity_id"),
    ("f", "field_key"),
    ("w", "writer_id"),
    ("s", "seq"),
];

/// 列值 → 它在 JSON 里的文本（字符串转义同 serde_json；ID 列的 BLOB 先解码）。NULL / 浮点 / 别的类型不参与。
fn frag(v: ValueRef<'_>) -> Option<String> {
    match v {
        ValueRef::Integer(i) => Some(i.to_string()),
        ValueRef::Text(_) | ValueRef::Blob(_) => super::ids::text(v).map(|s| serde_json::to_string(&s).expect("string")),
        _ => None,
    }
}

/// 顶层对象的成员：(键原文（不含引号）, 成员全文 `"k":v`)。不是紧凑的对象就 None。
fn members(s: &str) -> Option<Vec<(&str, &str)>> {
    let b = s.as_bytes();
    if b.first() != Some(&b'{') || b.last() != Some(&b'}') {
        return None;
    }
    let mut out = Vec::new();
    let mut i = 1;
    if b.len() == 2 {
        return Some(out);
    }
    loop {
        let start = i;
        if b.get(i) != Some(&b'"') {
            return None;
        }
        i += 1;
        while *b.get(i)? != b'"' {
            if b[i] == b'\\' {
                i += 1;
            }
            i += 1;
        }
        let key = &s[start + 1..i];
        i += 1;
        if b.get(i) != Some(&b':') {
            return None;
        }
        i += 1;
        // 值：到深度 0 的 ',' 或结尾的 '}'。
        let mut depth = 0i32;
        let mut in_str = false;
        loop {
            let c = *b.get(i)?;
            if in_str {
                if c == b'\\' {
                    i += 1;
                } else if c == b'"' {
                    in_str = false;
                }
            } else {
                match c {
                    b'"' => in_str = true,
                    b'{' | b'[' => depth += 1,
                    b'}' | b']' if depth > 0 => depth -= 1,
                    b',' | b'}' if depth == 0 => break,
                    _ => {}
                }
            }
            i += 1;
        }
        out.push((key, &s[start..i]));
        if b[i] == b'}' {
            return (i == b.len() - 1).then_some(out);
        }
        i += 1;
    }
}

/// 拼回：瘦 JSON 的成员与列的成员按键的字节序归并（列的键在瘦 JSON 里已有、或记为原文没有时不插）。不是瘦 JSON
/// 原样返回。
pub(crate) fn expand(stored: &str, keys: &[&str], frags: &[Option<String>]) -> String {
    let Some(rest) = stored.strip_prefix(SLIM) else { return stored.to_owned() };
    let Some(brace) = rest.find('{') else { return rest.to_owned() };
    let (absent, slim) = rest.split_at(brace);
    let Some(have) = members(slim) else { return slim.to_owned() };
    let mut add: Vec<(&str, &str)> = keys
        .iter()
        .zip(frags)
        .filter_map(|(k, f)| f.as_deref().map(|f| (*k, f)))
        .filter(|(k, _)| !have.iter().any(|(h, _)| h == k) && !absent.split(',').any(|a| a == *k))
        .collect();
    add.sort_by(|a, b| a.0.cmp(b.0));
    let mut out = String::with_capacity(slim.len() + add.iter().map(|(k, f)| k.len() + f.len() + 4).sum::<usize>());
    out.push('{');
    let mut first = true;
    let mut push = |out: &mut String, m: &str| {
        if !first {
            out.push(',');
        }
        first = false;
        out.push_str(m);
    };
    let mut a = add.into_iter().peekable();
    for (k, m) in have {
        while let Some((ak, af)) = a.next_if(|(ak, _)| *ak < k) {
            push(&mut out, &format!("\"{ak}\":{af}"));
        }
        push(&mut out, m);
    }
    for (ak, af) in a {
        push(&mut out, &format!("\"{ak}\":{af}"));
    }
    out.push('}');
    out
}

/// 原文 → 存储值：去掉与列逐字节相同的键；拼回与原文不同（非规范 / 不一致）就存原文。
pub(crate) fn pack(full: &str, keys: &[&str], frags: &[Option<String>]) -> String {
    let Some(have) = members(full) else { return full.to_owned() };
    let mut slim = String::with_capacity(full.len());
    slim.push(SLIM);
    let absent: Vec<&str> = keys
        .iter()
        .zip(frags)
        .filter(|(k, f)| f.is_some() && !have.iter().any(|(h, _)| h == *k))
        .map(|(k, _)| *k)
        .collect();
    slim.push_str(&absent.join(","));
    slim.push('{');
    let mut first = true;
    let mut dropped = false;
    for (k, m) in have {
        let same = keys.iter().zip(frags).any(|(kk, f)| *kk == k && f.as_deref().is_some_and(|f| m.len() == k.len() + 3 + f.len() && m.ends_with(f)));
        if same {
            dropped = true;
            continue;
        }
        if !first {
            slim.push(',');
        }
        first = false;
        slim.push_str(m);
    }
    slim.push('}');
    if dropped && expand(&slim, keys, frags) == full {
        slim
    } else {
        full.to_owned()
    }
}

fn keys_of<const N: usize>(t: &[(&'static str, &'static str); N]) -> [&'static str; N] {
    t.map(|(k, _)| k)
}

/// `srs_log_json(jslim, 列…)` / `srs_log_pack(json, 列…)` 与修改记录的两个同形函数。确定性（生成列要求）。
pub(crate) fn register(conn: &Connection) -> rusqlite::Result<()> {
    let flags = FunctionFlags::SQLITE_UTF8 | FunctionFlags::SQLITE_DETERMINISTIC | FunctionFlags::SQLITE_INNOCUOUS;
    for (name, keys, unpack) in [
        ("srs_log_json", &keys_of(&LOG_KEYS)[..], true),
        ("srs_log_pack", &keys_of(&LOG_KEYS)[..], false),
        ("srs_edit_json", &keys_of(&EDIT_KEYS)[..], true),
        ("srs_edit_pack", &keys_of(&EDIT_KEYS)[..], false),
    ] {
        let keys: Vec<&'static str> = keys.to_vec();
        conn.create_scalar_function(name, keys.len() as i32 + 1, flags, move |ctx| {
            let s = match ctx.get_raw(0) {
                ValueRef::Text(t) => std::str::from_utf8(t).map_err(|e| rusqlite::Error::UserFunctionError(e.into()))?,
                ValueRef::Null => return Ok(None),
                _ => return Err(rusqlite::Error::UserFunctionError("json must be text".into())),
            };
            let frags: Vec<Option<String>> = (1..=keys.len()).map(|i| frag(ctx.get_raw(i))).collect();
            Ok(Some(if unpack { expand(s, &keys, &frags) } else { pack(s, &keys, &frags) }))
        })?;
    }
    Ok(())
}

/// 生成列的表达式。
fn json_expr(table: &str) -> Option<String> {
    let (f, keys): (&str, &[(&str, &str)]) = match table {
        "srs_review_logs" => ("srs_log_json", &LOG_KEYS),
        "srs_field_edits" => ("srs_edit_json", &EDIT_KEYS),
        _ => return None,
    };
    Some(format!("{f}(jslim, {})", keys.iter().map(|(_, c)| *c).collect::<Vec<_>>().join(", ")))
}

/// 写入 `jslim` 的表达式：[col] 是原文所在的 SQL 表达式，其余列按 [cols] 给出（同 [LOG_KEYS] / [EDIT_KEYS] 序）。
pub(crate) fn pack_expr(table: &str, json: &str, cols: &[&str]) -> String {
    let f = if table == "srs_review_logs" { "srs_log_pack" } else { "srs_edit_pack" };
    format!("{f}({json}, {})", cols.join(", "))
}

/// 按列清单逐列插入（旧库搬运，`legacy_page`）时 `json` 那一列的写法：`(插入的列名, 值表达式)`。[place] 是第 i 列
/// （0 起）的占位写法。不是这两张表的 `json` 就 None。键对应的列不在清单里就原样存原文（同样合法）。
pub(crate) fn insert_column(table: &str, columns: &[&str], i: usize, place: impl Fn(usize) -> String) -> Option<(&'static str, String)> {
    let keys: &[(&str, &str)] = match table {
        "srs_review_logs" => &LOG_KEYS,
        "srs_field_edits" => &EDIT_KEYS,
        _ => return None,
    };
    if columns[i] != "json" {
        return None;
    }
    let args: Option<Vec<String>> = keys.iter().map(|(_, c)| columns.iter().position(|x| x == c).map(&place)).collect();
    Some(("jslim", match args {
        Some(a) => pack_expr(table, &place(i), &a.iter().map(String::as_str).collect::<Vec<_>>()),
        None => place(i),
    }))
}

/// v18：两张投影表的 `json` 改成生成列、原文搬进 `jslim`（瘦存）。整表重建（保留 rowid、索引、触发器）；已改过的表
/// 什么也不做——可重放。
pub(crate) fn migrate(c: &Connection) -> Result<(), String> {
    let e = |x: rusqlite::Error| x.to_string();
    c.execute_batch("PRAGMA legacy_alter_table = ON;").map_err(e)?;
    for (table, keys) in [("srs_review_logs", &LOG_KEYS[..]), ("srs_field_edits", &EDIT_KEYS[..])] {
        let Some(sql) = c
            .query_row("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?1", [table], |r| r.get::<_, String>(0))
            .ok()
        else {
            continue;
        };
        let has_slim: i64 = c
            .query_row(&format!("SELECT COUNT(*) FROM pragma_table_xinfo('{table}') WHERE name = 'jslim'"), [], |r| r.get(0))
            .map_err(e)?;
        if has_slim > 0 {
            continue;
        }
        let names: Vec<String> = {
            let mut s = c.prepare(&format!("SELECT name FROM pragma_table_info('{table}') ORDER BY cid")).map_err(e)?;
            let rows = s.query_map([], |r| r.get::<_, String>(0)).map_err(e)?;
            rows.collect::<Result<_, _>>().map_err(e)?
        };
        // 建表语句可能是 Rust 的分行写法，也可能是 Drift 的一行带引号写法。
        let decl = regex::Regex::new(r#"(?m)(^\s*|[(,]\s*)"?json"?\s+TEXT\s+NOT\s+NULL"#).expect("regex");
        if !decl.is_match(&sql) {
            return Err(format!("{table}: unexpected json column in {sql}"));
        }
        let expr = json_expr(table).expect("table");
        let tmp = format!("{table}__v18");
        let create = decl
            .replace(&sql, format!("${{1}}jslim TEXT NOT NULL, json TEXT GENERATED ALWAYS AS ({expr}) VIRTUAL").as_str())
            .replacen(table, &tmp, 1);
        let cols: Vec<&str> = keys.iter().map(|(_, c)| *c).collect();
        let others: Vec<&str> = names.iter().map(String::as_str).filter(|n| *n != "json").collect();
        let ins = format!("rowid, {}, jslim", others.join(", "));
        let sel = format!("rowid, {}, {}", others.join(", "), pack_expr(table, "json", &cols));
        let extras: Vec<String> = {
            let mut s = c
                .prepare("SELECT sql FROM sqlite_master WHERE tbl_name = ?1 AND type IN ('index', 'trigger') AND sql IS NOT NULL")
                .map_err(e)?;
            let rows = s.query_map([table], |r| r.get::<_, String>(0)).map_err(e)?;
            rows.collect::<Result<_, _>>().map_err(e)?
        };
        c.execute_batch(&format!(
            "DROP TABLE IF EXISTS {tmp}; {create}; INSERT INTO {tmp} ({ins}) SELECT {sel} FROM {table}; \
             DROP TABLE {table}; ALTER TABLE {tmp} RENAME TO {table};"
        ))
        .map_err(|x| format!("{table}: {x}"))?;
        for x in extras {
            c.execute_batch(&x).map_err(|y| format!("{table}: {y} in {x}"))?;
        }
    }
    c.execute_batch("PRAGMA legacy_alter_table = OFF;").map_err(e)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn log_frags(id: &str, card: &str, at: i64) -> Vec<Option<String>> {
        let s = |x: &str| Some(serde_json::to_string(x).unwrap());
        vec![s(id), s("0193a1b2-0000-7000-8000-00000000beef"), s(card), s("review"), Some("3".into()), Some(at.to_string()), s("review"), s("fushi"), Some("0".into())]
    }

    #[test]
    fn packs_canonical_json_and_expands_byte_for_byte() {
        let keys = keys_of(&LOG_KEYS);
        let full = r#"{"at":1700000000000,"card":"C\"1","dur":0,"fv":1,"hlc":"1:0:dart","id":"a1","kind":"review","origin":"fushi","p":"0193a1b2-0000-7000-8000-00000000beef","rating":3,"res":{"ivl":0,"q":[1,{"x":"}"}]},"rtype":"review","ts":"anchored","utcOff":0}"#;
        let frags = log_frags("a1", "C\"1", 1_700_000_000_000);
        let slim = pack(full, &keys, &frags);
        assert!(slim.starts_with('~') && slim.len() < full.len() / 2 + 60, "{slim}");
        assert_eq!(slim, r#"~{"fv":1,"hlc":"1:0:dart","res":{"ivl":0,"q":[1,{"x":"}"}]},"ts":"anchored","utcOff":0}"#);
        assert_eq!(expand(&slim, &keys, &frags), full);
    }

    #[test]
    fn column_wise_inserts_pack_from_the_same_row() {
        let cols = ["id", "profile_uid", "entity_kind", "entity_id", "field_key", "writer_id", "seq", "json"];
        let place = |i: usize| format!("?{}", i + 1);
        assert_eq!(insert_column("srs_field_edits", &cols, 0, place), None);
        assert_eq!(
            insert_column("srs_field_edits", &cols, 7, place),
            Some(("jslim", "srs_edit_pack(?8, ?1, ?2, ?3, ?4, ?5, ?6, ?7)".to_owned()))
        );
        assert_eq!(insert_column("srs_field_edits", &cols[1..], 6, place), Some(("jslim", "?7".to_owned())));
        assert_eq!(insert_column("srs_unknown_events", &["id", "json"], 1, place), None);
    }

    #[test]
    fn keeps_the_original_when_it_cannot_be_rebuilt_exactly() {
        let keys = keys_of(&LOG_KEYS);
        let frags = log_frags("a1", "C", 5);
        // 键与列不等、列有值而 JSON 没有这个键（瘦存并记下缺的键）、非紧凑 / 非规范键序、不是对象：都逐字节拼回。
        assert_eq!(pack(r#"{"at":5,"card":"C","id":"a1","x":1}"#, &keys, &frags), r#"~p,kind,rating,rtype,origin,dur{"x":1}"#);
        for full in [
            r#"{"at":6,"card":"C","id":"a1"}"#,
            r#"{"at":5,"card":"C","id":"a1"}"#,
            r#"{"at":5,"card":"C","id":"a1","x":1}"#,
            r#"{ "at":5}"#,
            r#"{"id":"a1","at":5}"#,
            "[1,2]",
            "{}",
        ] {
            let stored = pack(full, &keys, &frags);
            assert_eq!(expand(&stored, &keys, &frags), full, "{full} -> {stored}");
        }
        assert_eq!(pack(r#"{"id":"a1","at":5}"#, &keys, &frags), r#"{"id":"a1","at":5}"#);
    }
}
