//! 投影 JSON 去掉与列重复的键（srs.db v18，2026-10-31 磁盘占用）。
//!
//! 日志投影 `srs_review_logs` 与修改记录投影 `srs_field_edits` 的 `json` 是事件的规范 JSON（serde 的 BTreeMap 键序、紧凑），
//! 其中好几个键（ID、profile、卡 / 实体、种类、时刻……）与同一行的列逐字相同，约占 JSON 的一半。现在磁盘上只存
//! `jslim`：
//!
//! - 去掉「值与列逐字节相同」的那些键，前面加 [SLIM] 标记；列有值而原文没有的键（导入锚点没有 `rtype` / `dur` 之类）
//!   记在标记与 `{` 之间（`~rtype,dur{…}`），拼回时不补；
//! - 写入时先拼回一次，与原文逐字节相同才存瘦的，否则原样存原文（非规范的旧行、键缺失 / 不等的行）——无损。
//!   原文自己就以 [SLIM] 开头（不是 JSON 的外来文本）时存成 `~` + 原文（`~~…`）：瘦形态的「原文没有的键」只是键名，
//!   不会以 `~` 开头，两种形态不会混。
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

/// 列值在 JSON 里的文本接到 [out] 末尾（字符串转义同 serde_json；ID 列的 BLOB 先解码）。NULL / 浮点 / 别的类型不参与，
/// 返回 false。一行的各列写进同一个缓冲（每行每列都走这里，不逐列分配）。
fn write_frag(out: &mut String, v: ValueRef<'_>) -> bool {
    match v {
        ValueRef::Integer(i) => {
            use std::fmt::Write;
            write!(out, "{i}").expect("string");
            true
        }
        ValueRef::Text(t) => {
            write_quoted(out, &String::from_utf8_lossy(t));
            true
        }
        // 编码的 ID：十六进制与连字符不用转义。
        ValueRef::Blob(b) => match <&[u8; 16]>::try_from(b) {
            Ok(b) => {
                out.push('"');
                super::ids::unpack_into(b, out);
                out.push('"');
                true
            }
            Err(_) => false,
        },
        _ => false,
    }
}

/// JSON 字符串字面量（逐字节同 serde_json）：没有要转义的字符就直接加引号。
fn write_quoted(out: &mut String, s: &str) {
    if s.bytes().all(|c| c >= 0x20 && c != b'"' && c != b'\\') {
        out.push('"');
        out.push_str(s);
        out.push('"');
    } else {
        out.push_str(&serde_json::to_string(s).expect("string"));
    }
}

#[cfg(test)]
fn quote(s: &str) -> String {
    let mut out = String::new();
    write_quoted(&mut out, s);
    out
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
pub(crate) fn expand<F: AsRef<str>>(stored: &str, keys: &[&str], frags: &[Option<F>]) -> String {
    let Some(rest) = stored.strip_prefix(SLIM) else { return stored.to_owned() };
    if rest.starts_with(SLIM) {
        // 转义存的原文（[pack]）。
        return rest.to_owned();
    }
    let Some(brace) = rest.find('{') else { return rest.to_owned() };
    let (absent, slim) = rest.split_at(brace);
    let Some(have) = members(slim) else { return slim.to_owned() };
    let mut add: Vec<(&str, &str)> = keys
        .iter()
        .zip(frags)
        .filter_map(|(k, f)| f.as_ref().map(|f| (*k, f.as_ref())))
        .filter(|(k, _)| !have.iter().any(|(h, _)| h == k) && !absent.split(',').any(|a| a == *k))
        .collect();
    add.sort_by(|a, b| a.0.cmp(b.0));
    let mut out = String::with_capacity(slim.len() + add.iter().map(|(k, f)| k.len() + f.len() + 4).sum::<usize>());
    out.push('{');
    let mut first = true;
    let mut sep = |out: &mut String| {
        if !first {
            out.push(',');
        }
        first = false;
    };
    let member = |out: &mut String, k: &str, f: &str| {
        out.push('"');
        out.push_str(k);
        out.push_str("\":");
        out.push_str(f);
    };
    let mut a = add.into_iter().peekable();
    for (k, m) in have {
        while let Some((ak, af)) = a.next_if(|(ak, _)| *ak < k) {
            sep(&mut out);
            member(&mut out, ak, af);
        }
        sep(&mut out);
        out.push_str(m);
    }
    for (ak, af) in a {
        sep(&mut out);
        member(&mut out, ak, af);
    }
    out.push('}');
    out
}

/// 原文 → 存储值：去掉与列逐字节相同的键；拼回与原文不同（非规范 / 不一致）就存原文。
pub(crate) fn pack<F: AsRef<str>>(full: &str, keys: &[&str], frags: &[Option<F>]) -> String {
    if full.starts_with(SLIM) {
        // 原文本身以标记开头：原样存会被读成瘦形态拼坏，转义一层（[expand] 去掉）。
        let mut out = String::with_capacity(full.len() + 1);
        out.push(SLIM);
        out.push_str(full);
        return out;
    }
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
        let same = keys.iter().zip(frags).any(|(kk, f)| *kk == k && f.as_ref().map(AsRef::as_ref).is_some_and(|f| m.len() == k.len() + 3 + f.len() && m.ends_with(f)));
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
            let mut buf = String::with_capacity(160);
            let spans: Vec<Option<(usize, usize)>> = (1..=keys.len())
                .map(|i| {
                    let start = buf.len();
                    write_frag(&mut buf, ctx.get_raw(i)).then(|| (start, buf.len()))
                })
                .collect();
            let frags: Vec<Option<&str>> = spans.iter().map(|x| x.map(|(a, b)| &buf[a..b])).collect();
            Ok(Some(if unpack { expand(s, &keys, &frags) } else { pack(s, &keys, &frags) }))
        })?;
    }
    Ok(())
}

/// 热路径读修改记录不经生成列 `json`（逐行拼回再整段解析）：读存储的 `jslim` 与这些列，`registers` 解析瘦 JSON 后
/// 从列补去掉的键。SELECT 里写在别名 `f` 的表上，[edit_row] 从第 [at] 列起取。
pub(crate) const EDIT_READ: &str = "f.jslim, f.id, f.profile_uid, f.entity_kind, f.entity_id, f.field_key, f.writer_id, f.seq";

/// 日志同 [EDIT_READ]（别名 `l`），[log_row] 从第 [at] 列起取。
pub(crate) const LOG_READ: &str =
    "l.jslim, l.id, l.profile_uid, l.card_id, l.kind, l.rating, l.occurred_at, l.review_type, l.origin, l.duration_ms";

/// 一列在拼回里的取值：整数 / 文本（ID 的 BLOB 已解码）/ 不参与（NULL 等，与 [write_frag] 同一判据）。
enum Col {
    Int(i64),
    Str(String),
    None,
    /// 拼回会写成别的样子（浮点、长度不对的 BLOB……）：不按类型读，整条拼回原文。
    Odd,
}

fn col(v: ValueRef<'_>) -> Col {
    match v {
        ValueRef::Integer(i) => Col::Int(i),
        ValueRef::Null => Col::None,
        ValueRef::Text(_) | ValueRef::Blob(_) => super::ids::text(v).map_or(Col::Odd, Col::Str),
        ValueRef::Real(_) => Col::Odd,
    }
}

/// 一行的存储值与 [n] 个列（从第 [at] 列起）；有列不是读者预期的类型时直接拼回原文（返回的列是 None）。
fn read_row<T>(
    r: &rusqlite::Row<'_>,
    at: usize,
    n: usize,
    keys: &[&str],
    typed: impl FnOnce(&mut Vec<Col>) -> Option<T>,
) -> rusqlite::Result<(String, Option<T>)> {
    let stored: String = r.get(at)?;
    if !stored.starts_with(SLIM) {
        return Ok((stored, None));
    }
    if stored[SLIM.len_utf8()..].starts_with(SLIM) {
        // 转义存的原文（[pack]）：去掉一层标记就是原文。
        return Ok((stored[SLIM.len_utf8()..].to_owned(), None));
    }
    let mut cols: Vec<Col> = (1..=n).map(|i| r.get_ref(at + i).map(col)).collect::<rusqlite::Result<_>>()?;
    if let Some(t) = typed(&mut cols) {
        return Ok((stored, Some(t)));
    }
    let mut buf = String::new();
    let spans: Vec<Option<(usize, usize)>> = (1..=n)
        .map(|i| {
            let start = buf.len();
            write_frag(&mut buf, r.get_ref(at + i).expect("column")).then(|| (start, buf.len()))
        })
        .collect();
    let frags: Vec<Option<&str>> = spans.iter().map(|x| x.map(|(a, b)| &buf[a..b])).collect();
    Ok((expand(&stored, keys, &frags), None))
}

fn take_str(c: &mut Col) -> Option<String> {
    match std::mem::replace(c, Col::None) {
        Col::Str(s) => Some(s),
        _ => None,
    }
}

fn int(c: &Col) -> Option<i64> {
    match c {
        Col::Int(i) => Some(*i),
        _ => None,
    }
}

/// [EDIT_READ] 那 8 列 → (存储值, 列)；列为 None 时存储值已是原文。
pub(crate) fn edit_row(r: &rusqlite::Row<'_>, at: usize) -> rusqlite::Result<(String, Option<crate::registers::EditCols>)> {
    read_row(r, at, 7, &keys_of(&EDIT_KEYS), |c| {
        Some(crate::registers::EditCols {
            id: take_str(&mut c[0])?,
            k: take_str(&mut c[2])?,
            e: take_str(&mut c[3])?,
            f: take_str(&mut c[4])?,
            w: take_str(&mut c[5])?,
            s: int(&c[6])?,
        })
    })
}

/// [LOG_READ] 那 10 列 → (存储值, 列)；列为 None 时存储值已是原文。
pub(crate) fn log_row(r: &rusqlite::Row<'_>, at: usize) -> rusqlite::Result<(String, Option<crate::history::LogCols>)> {
    read_row(r, at, 9, &keys_of(&LOG_KEYS), |c| {
        if !matches!(c[1], Col::Str(_)) || !matches!(c[2], Col::Str(_)) || !matches!(c[4], Col::Int(_) | Col::None) {
            return None;
        }
        Some(crate::history::LogCols {
            id: take_str(&mut c[0])?,
            kind: take_str(&mut c[3])?,
            rating: int(&c[4]),
            at: int(&c[5])?,
            rtype: take_str(&mut c[6])?,
            origin: take_str(&mut c[7])?,
            dur: int(&c[8])?,
        })
    })
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

    /// 热路径读者从「瘦存 + 列」解析（registers `EditCols`），与解析拼回的原文得到同一个寄存器值；原文缺的键
    /// （这里的 `id`）不从列补。
    #[test]
    fn registers_read_slim_edits_with_their_columns() {
        use crate::registers::{register_value, EditCols};
        let keys = keys_of(&EDIT_KEYS);
        let cols = EditCols { id: "e1".into(), k: "deck".into(), e: "D\"1".into(), f: "retention".into(), w: "w1".into(), s: 7 };
        let s = |x: &str| Some(serde_json::to_string(x).unwrap());
        let frags = vec![s(&cols.id), s("p"), s(&cols.k), s(&cols.e), s(&cols.f), s(&cols.w), Some("7".into())];
        let full = r#"{"e":"D\"1","f":"retention","hlc":"1700000000000:0:w1","k":"deck","p":"p","s":7,"ts":"anchored","v":0.85,"w":"w1"}"#;
        let slim = pack(full, &keys, &frags);
        assert_eq!(slim, r#"~id{"hlc":"1700000000000:0:w1","ts":"anchored","v":0.85}"#);
        assert_eq!(expand(&slim, &keys, &frags), full);
        let a = register_value(&[(full, None, None)], "retention").unwrap();
        let b = register_value(&[(slim.as_str(), None, Some(&cols))], "retention").unwrap();
        assert_eq!(a, b);
        assert_eq!(b, serde_json::json!(0.85));
        // 瘦存却没给列：报错，不当成缺键的原文。
        assert!(register_value(&[(slim.as_str(), None, None)], "retention").is_err());
    }

    /// PR #2663 新增的牌组寄存器（`newPlan` 新卡计划、`rwkvQueue` 里的 `ignoreLimit`）走同一条瘦存路径：逐字节拼回，
    /// 寄存器值与从原文读的相同（原文不带 `id`，同上一条：内容派生 ID 的校验不在这里）；经 SQL（`srs_edit_pack` 写 / `json` 生成列读）同样无损，物化视图带出 `npl`。
    #[test]
    fn new_deck_registers_round_trip_through_slim_edits() {
        use crate::registers::{deck_view_of, register_value, EditCols};
        let keys = keys_of(&EDIT_KEYS);
        let s = |x: &str| Some(serde_json::to_string(x).unwrap());
        let p = "0193a1b2-0000-7000-8000-00000000beef";
        let deck = "0193a1b2-0000-7000-8000-0000000000d1";
        let cases = [
            ("e1", "newPlan", r#"{"auto":false,"boost":30,"budget":120}"#),
            ("e2", "rwkvQueue", r#"{"ignoreLimit":true,"minReviews":0,"refreshEvery":1,"repeatReviews":5,"repeatSeconds":30}"#),
        ];
        let c = Connection::open_in_memory().unwrap();
        register(&c).unwrap();
        c.execute_batch("CREATE TABLE t (jslim TEXT, id TEXT, p TEXT, k TEXT, e TEXT, f TEXT, w TEXT, s INTEGER);").unwrap();
        let mut fulls: Vec<String> = Vec::new();
        for (i, (id, f, v)) in cases.iter().enumerate() {
            let seq = 10 + i as i64;
            let full = format!(r#"{{"e":"{deck}","f":"{f}","hlc":"1700000000000:{i}:w1","k":"deck","p":"{p}","s":{seq},"ts":"anchored","v":{v},"w":"w1"}}"#);
            let cols = EditCols { id: (*id).into(), k: "deck".into(), e: deck.into(), f: (*f).into(), w: "w1".into(), s: seq };
            let frags = vec![s(id), s(p), s("deck"), s(deck), s(f), s("w1"), Some(seq.to_string())];
            let slim = pack(&full, &keys, &frags);
            assert!(slim.starts_with("~id{") && slim.contains(&format!(r#""v":{v}"#)), "{slim}");
            assert_eq!(expand(&slim, &keys, &frags), full);
            let want: serde_json::Value = serde_json::from_str(v).unwrap();
            assert_eq!(register_value(&[(full.as_str(), None, None)], f).unwrap(), want);
            assert_eq!(register_value(&[(slim.as_str(), None, Some(&cols))], f).unwrap(), want);
            c.execute(
                "INSERT INTO t SELECT srs_edit_pack(?1, ?2, ?3, 'deck', ?4, ?5, 'w1', ?6), ?2, ?3, 'deck', ?4, ?5, 'w1', ?6",
                rusqlite::params![full, id, p, deck, f, seq],
            )
            .unwrap();
            fulls.push(full);
        }
        let via_sql: Vec<String> = c
            .prepare("SELECT srs_edit_json(jslim, id, p, k, e, f, w, s) FROM t ORDER BY s")
            .unwrap()
            .query_map([], |r| r.get(0))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        assert_eq!(via_sql, fulls);
        let stored: Vec<crate::registers::StoredEdit<'_>> = fulls.iter().map(|j| (j.as_str(), None, None)).collect();
        let view = deck_view_of(&serde_json::json!({}), &stored).unwrap();
        assert_eq!(view["npl"], serde_json::json!({"auto": false, "boost": 30, "budget": 120}));
        assert_eq!(view["rw"]["ignoreLimit"], serde_json::Value::Bool(true));
    }

    /// 日志同理：历史状态与统计投影从「瘦存 + 列」算，与从原文算相同。
    #[test]
    fn history_reads_slim_logs_with_their_columns() {
        use crate::history::{state_from_json, state_from_stored, stats_from_json, stats_from_stored, LogCols};
        let keys = keys_of(&LOG_KEYS);
        let s = |x: &str| Some(serde_json::to_string(x).unwrap());
        let day = 86_400_000i64;
        let mk = |id: &str, at: i64, rating: i64, res: &str| {
            let full = format!(
                r#"{{"at":{at},"card":"c1","dur":1500,"hlc":"{at}:0:w","id":"{id}","kind":"review","p":"p","rating":{rating},"res":{res},"rtype":"review","utcOff":540}}"#
            );
            let cols = LogCols { id: id.into(), kind: "review".into(), rating: Some(rating), at, rtype: "review".into(), origin: "local".into(), dur: 1500 };
            let frags = vec![s(id), s("p"), s("c1"), s("review"), Some(rating.to_string()), Some(at.to_string()), s("review"), s("local"), Some("1500".into())];
            let slim = pack(&full, &keys, &frags);
            assert!(slim.starts_with("~origin{"), "{slim}");
            assert_eq!(expand(&slim, &keys, &frags), full);
            (full, slim, cols)
        };
        let logs = [
            mk("a", day, 3, r#"{"queue":"review","ivl":5,"dueDay":105}"#),
            mk("b", 2 * day, 1, r#"{"queue":"review","ivl":30,"dueDay":130}"#),
        ];
        let full: Vec<&str> = logs.iter().map(|l| l.0.as_str()).collect();
        let stored: Vec<crate::history::StoredLog<'_>> = logs.iter().map(|l| (l.1.as_str(), None, Some(&l.2))).collect();
        assert_eq!(state_from_json(&full, &[None, None]).unwrap(), state_from_stored(&stored).unwrap());
        assert_eq!(stats_from_json(&full, &[None, None]).unwrap(), stats_from_stored(&stored).unwrap());
        assert!(state_from_stored(&[(logs[0].1.as_str(), None, None)]).is_err());
    }

    #[test]
    fn quoting_matches_serde_json() {
        for s in ["", "abc", "a\"b", "a\\b", "tab\there", "\u{1}", "例文", "\u{7f}", "0193a1b2-0000-7000-8000-00000000beef"] {
            assert_eq!(quote(s), serde_json::to_string(s).unwrap(), "{s:?}");
        }
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

    /// 回归：以标记 `~` 开头的非 JSON 原文以前原样存，读回时被当成瘦形态拼坏。现在转义存，经 SQL 生成列与热路径
    /// 读者（[read_row]）都逐字节读回原文。
    #[test]
    fn text_starting_with_the_marker_round_trips() {
        let keys = keys_of(&LOG_KEYS);
        let frags = log_frags("a1", "C", 5);
        for full in ["~", "~~", "~x", "~{\"at\":5}", "~p,kind{\"x\":1}", "~~p{}"] {
            let stored = pack(full, &keys, &frags);
            assert_eq!(expand(&stored, &keys, &frags), full, "{full} -> {stored}");
        }
        let c = Connection::open_in_memory().unwrap();
        register(&c).unwrap();
        c.execute_batch(
            "CREATE TABLE t (jslim TEXT, id TEXT, p TEXT, card TEXT, kind TEXT, rating INTEGER, at INTEGER, rtype TEXT, origin TEXT, dur INTEGER);",
        )
        .unwrap();
        for full in ["~", "~x{\"at\":5}", "~p,kind{\"x\":1}"] {
            c.execute("DELETE FROM t", []).unwrap();
            c.execute(
                "INSERT INTO t SELECT srs_log_pack(?1, 'a1', 'p', 'C', 'review', 3, 5, 'review', 'fushi', 0), 'a1', 'p', 'C', 'review', 3, 5, 'review', 'fushi', 0",
                [full],
            )
            .unwrap();
            let via_sql: String = c
                .query_row("SELECT srs_log_json(jslim, id, p, card, kind, rating, at, rtype, origin, dur) FROM t", [], |r| r.get(0))
                .unwrap();
            assert_eq!(via_sql, full);
            let (hot, cols) = c
                .query_row("SELECT jslim AS l_jslim, id, p, card, kind, rating, at, rtype, origin, dur FROM t", [], |r| log_row(r, 0))
                .unwrap();
            assert!(cols.is_none());
            assert_eq!(hot, full);
        }
    }
}

