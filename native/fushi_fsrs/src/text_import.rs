//! 复习卡的文本导入（CSV / TSV / TXT，对齐 Anki「导入 → 文本文件」）：解析在这里，写库在 Dart
//! （packages/fushi_engine/lib/srs/text/srs_text_import.dart，走与新建笔记相同的事件路径）。
//!
//! 经 `ffsrs_call` 的 `text_import_parse` 调用，一次调用读完整个文件、回全部（或前 `limit` 条）记录，
//! 不逐行跨 FFI。口径照 Anki rslib `import_export/text/csv`：
//!
//! - 文件头：开头连续的 `#键:值` 行（Anki 文本导出写的那些），认 `separator` / `html` / `tags` / `columns` /
//!   `notetype` / `deck` / `notetype column` / `deck column` / `tags column` / `guid column` / `if matches` /
//!   `match scope`，键不分大小写；不认识的 `#` 行当注释。第一行也可以是不带 `#` 的 `tags:…`（旧版导出）。
//! - 分隔符：调用方指定 > 文件头 > 猜（文件头之后前 8 KiB 里依次找 Tab、`|`、`;`、`:`、`,`、空格，第一个出现的
//!   就是；都没有按空格）。
//! - 记录：引号只在字段开头起作用，引号内 `""` 是一个引号、可以跨行；`#` 开头的行是注释，空行跳过；每行列数
//!   可以不同。
//! - HTML：调用方指定 > 文件头 > 任一字段像 HTML 就当 HTML。不当 HTML 时字段转义 `&` `<` `>`、换行变 `<br>`
//!   （Anki 同样处理），回给调用方的已经是要写进笔记的形式。
//! - 列号（`… column`）是 1 起的，原样回给调用方。

use serde_json::{Value, json};

/// 猜分隔符的候选顺序（Anki `Delimiter::iter()`，与它的 proto 枚举同序）。
const GUESS_ORDER: [char; 6] = ['\t', '|', ';', ':', ',', ' '];

/// 猜分隔符只看文件头之后这么多字节（Anki 同值）。
const GUESS_WINDOW: usize = 8 * 1024;

/// 文件头里的分隔符名（Anki `Delimiter::name()`）。
fn named_delimiter(value: &str) -> Option<char> {
    let normed = value.trim_end_matches(['\r', '\n']);
    match normed.trim().to_ascii_lowercase().as_str() {
        "comma" => return Some(','),
        "semicolon" => return Some(';'),
        "tab" => return Some('\t'),
        "space" => return Some(' '),
        "pipe" => return Some('|'),
        "colon" => return Some(':'),
        _ => {}
    }
    let mut chars = normed.chars();
    match (chars.next(), chars.next()) {
        (Some(c), None) if GUESS_ORDER.contains(&c) => Some(c),
        _ => None,
    }
}

/// 解析选项（`text_import_parse` 请求）。
#[derive(Debug, Default, Clone)]
pub struct ParseOptions {
    /// 指定分隔符（单个字符）；None = 按文件头或猜。
    pub delimiter: Option<char>,
    /// 指定字段是不是 HTML；None = 按文件头或猜。
    pub html: Option<bool>,
    /// 只回前这么多条记录（预览）；None = 全部。`total` 总是全部的条数。
    pub limit: Option<usize>,
}

/// 文件头（`#键:值`）。
#[derive(Debug, Default, Clone, PartialEq)]
pub struct Header {
    pub delimiter: Option<char>,
    pub html: Option<bool>,
    pub tags: Vec<String>,
    /// `#columns:` 的原文（分隔符定下来之后才切）。
    pub columns_raw: Option<String>,
    pub notetype: Option<String>,
    pub deck: Option<String>,
    pub notetype_column: Option<usize>,
    pub deck_column: Option<usize>,
    pub tags_column: Option<usize>,
    pub guid_column: Option<usize>,
    /// `update` / `preserve` / `duplicate`。
    pub if_matches: Option<&'static str>,
    /// `notetype` / `notetypeDeck`。
    pub match_scope: Option<&'static str>,
}

/// 解析结果。
#[derive(Debug, Clone, PartialEq)]
pub struct Parsed {
    pub header: Header,
    pub delimiter: char,
    pub html: bool,
    pub columns: Vec<String>,
    /// 最宽一行的列数（与 `#columns:` 的列数取大）。
    pub column_count: usize,
    pub total: usize,
    pub rows: Vec<Vec<String>>,
}

fn column_number(value: &str) -> Option<usize> {
    value.trim().parse::<usize>().ok().filter(|n| *n > 0)
}

/// 处理一行文件头；返回 false = 不是 `#` 行，文件头到此为止。
fn header_line(line: &str, first: bool, h: &mut Header) -> bool {
    let body = match line.strip_prefix('#') {
        Some(rest) => rest,
        None if first => match line.strip_prefix("tags:") {
            Some(tags) => {
                h.tags = tags.split_whitespace().map(str::to_owned).collect();
                return true;
            }
            None => return false,
        },
        None => return false,
    };
    let Some((key, value)) = body.split_once(':') else {
        return true;
    };
    let value = value.trim_end_matches(['\r', '\n']);
    let trimmed = value.trim();
    match key.trim().to_ascii_lowercase().as_str() {
        "separator" => {
            if let Some(d) = named_delimiter(value) {
                h.delimiter = Some(d);
            }
        }
        "html" => match trimmed.to_ascii_lowercase().as_str() {
            "true" => h.html = Some(true),
            "false" => h.html = Some(false),
            _ => {}
        },
        "tags" => h.tags = value.split_whitespace().map(str::to_owned).collect(),
        "columns" => h.columns_raw = Some(value.to_owned()),
        "notetype" if !trimmed.is_empty() => h.notetype = Some(trimmed.to_owned()),
        "deck" if !trimmed.is_empty() => h.deck = Some(trimmed.to_owned()),
        "notetype column" => h.notetype_column = column_number(trimmed),
        "deck column" => h.deck_column = column_number(trimmed),
        "tags column" => h.tags_column = column_number(trimmed),
        "guid column" => h.guid_column = column_number(trimmed),
        "if matches" => {
            h.if_matches = match trimmed.to_ascii_lowercase().as_str() {
                "update current" => Some("update"),
                "keep current" => Some("preserve"),
                "keep both" => Some("duplicate"),
                _ => h.if_matches,
            }
        }
        "match scope" => {
            h.match_scope = match trimmed.to_ascii_lowercase().as_str() {
                "notetype" => Some("notetype"),
                "notetype + deck" => Some("notetypeDeck"),
                _ => h.match_scope,
            }
        }
        _ => {}
    }
    true
}

/// 读文件头，返回 (文件头, 正文起点的字节偏移)。
pub fn read_header(text: &str) -> (Header, usize) {
    let mut h = Header::default();
    let mut at = 0;
    let mut first = true;
    while at < text.len() {
        let end = text[at..].find('\n').map_or(text.len(), |i| at + i + 1);
        if !header_line(&text[at..end], first, &mut h) {
            break;
        }
        first = false;
        at = end;
    }
    (h, at)
}

fn guess_delimiter(body: &str) -> char {
    let mut end = body.len().min(GUESS_WINDOW);
    while !body.is_char_boundary(end) {
        end -= 1;
    }
    let window = &body[..end];
    GUESS_ORDER
        .into_iter()
        .find(|d| window.contains(*d))
        .unwrap_or(' ')
}

/// 按 [delimiter] 切记录（见模块说明）。`#` 开头的行与空行不算记录。
pub fn split_records(body: &str, delimiter: char) -> Vec<Vec<String>> {
    let mut out: Vec<Vec<String>> = Vec::new();
    let mut chars = body.chars().peekable();
    let mut record: Vec<String> = Vec::new();
    let mut field = String::new();
    let mut at_record_start = true;
    let mut at_field_start = true;
    let mut quoted = false;
    // 当前记录里出现过内容（分隔符或任何字符）：只有换行的空行不算记录。
    let mut touched = false;
    let finish_record =
        |record: &mut Vec<String>, field: &mut String, out: &mut Vec<Vec<String>>| {
            record.push(std::mem::take(field));
            out.push(std::mem::take(record));
        };
    while let Some(c) = chars.next() {
        if quoted {
            if c == '"' {
                if chars.peek() == Some(&'"') {
                    chars.next();
                    field.push('"');
                } else {
                    quoted = false;
                }
            } else {
                field.push(c);
            }
            continue;
        }
        if at_record_start && c == '#' {
            // 注释行：跳到行尾。
            for n in chars.by_ref() {
                if n == '\n' {
                    break;
                }
            }
            continue;
        }
        at_record_start = false;
        match c {
            '\r' if chars.peek() == Some(&'\n') => {}
            '\n' | '\r' => {
                if touched {
                    finish_record(&mut record, &mut field, &mut out);
                } else {
                    record.clear();
                    field.clear();
                }
                touched = false;
                at_record_start = true;
                at_field_start = true;
            }
            '"' if at_field_start => {
                quoted = true;
                touched = true;
                at_field_start = false;
            }
            d if d == delimiter => {
                record.push(std::mem::take(&mut field));
                touched = true;
                at_field_start = true;
            }
            other => {
                field.push(other);
                touched = true;
                at_field_start = false;
            }
        }
    }
    if touched {
        finish_record(&mut record, &mut field, &mut out);
    }
    out
}

/// 字段像不像 HTML（Anki `is_html`：有标签或实体）。
pub fn looks_like_html(s: &str) -> bool {
    let b = s.as_bytes();
    let mut i = 0;
    while i < b.len() {
        match b[i] {
            b'<' => {
                let mut j = i + 1;
                if b.get(j) == Some(&b'/') {
                    j += 1;
                }
                if b.get(j).is_some_and(u8::is_ascii_alphabetic) {
                    let mut k = j + 1;
                    while k < b.len() && b[k] != b'<' && b[k] != b'>' {
                        k += 1;
                    }
                    if b.get(k) == Some(&b'>') {
                        return true;
                    }
                }
            }
            b'&' => {
                let mut j = i + 1;
                if b.get(j) == Some(&b'#') {
                    j += 1;
                    if b.get(j).is_some_and(|c| *c == b'x' || *c == b'X') {
                        j += 1;
                    }
                }
                let start = j;
                while j < b.len() && b[j].is_ascii_alphanumeric() {
                    j += 1;
                }
                if j > start && b.get(j) == Some(&b';') {
                    return true;
                }
            }
            _ => {}
        }
        i += 1;
    }
    false
}

/// 纯文本字段 → 笔记里的 HTML：转义 `&` `<` `>`，换行变 `<br>`。
pub fn text_to_html(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut chars = s.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '\r' => {
                if chars.peek() == Some(&'\n') {
                    chars.next();
                }
                out.push_str("<br>");
            }
            '\n' => out.push_str("<br>"),
            other => out.push(other),
        }
    }
    out
}

/// 解析整段文本（已是 UTF-8；BOM 在这里去掉）。
pub fn parse(text: &str, opts: &ParseOptions) -> Parsed {
    let text = text.strip_prefix('\u{FEFF}').unwrap_or(text);
    let (header, body_at) = read_header(text);
    let body = &text[body_at..];
    let delimiter = opts
        .delimiter
        .or(header.delimiter)
        .unwrap_or_else(|| guess_delimiter(body));
    let mut rows = split_records(body, delimiter);
    let columns: Vec<String> = header
        .columns_raw
        .as_deref()
        .and_then(|raw| split_records(raw, delimiter).into_iter().next())
        .unwrap_or_default();
    let html = opts
        .html
        .or(header.html)
        .unwrap_or_else(|| rows.iter().flatten().any(|f| looks_like_html(f)));
    let column_count = rows
        .iter()
        .map(Vec::len)
        .max()
        .unwrap_or(0)
        .max(columns.len());
    let total = rows.len();
    if let Some(limit) = opts.limit {
        rows.truncate(limit);
    }
    if !html {
        for row in &mut rows {
            for f in row.iter_mut() {
                *f = text_to_html(f);
            }
        }
    }
    Parsed {
        header,
        delimiter,
        html,
        columns,
        column_count,
        total,
        rows,
    }
}

fn opt_char(req: &Value, key: &str) -> Result<Option<char>, String> {
    match req.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(s)) => {
            let mut it = s.chars();
            match (it.next(), it.next()) {
                (Some(c), None) if c != '"' && c != '\n' && c != '\r' => Ok(Some(c)),
                _ => Err(format!("`{key}` must be a single character")),
            }
        }
        Some(_) => Err(format!("`{key}` must be a string")),
    }
}

/// `text_import_parse`：`{path, delimiter?, html?, limit?}` → 见 [Parsed]。文件按 UTF-8 读（非法字节换成 U+FFFD）。
pub fn dispatch(req: &Value) -> Result<Value, String> {
    let path = req
        .get("path")
        .and_then(Value::as_str)
        .ok_or("missing string field `path`")?;
    let opts = ParseOptions {
        delimiter: opt_char(req, "delimiter")?,
        html: req.get("html").and_then(Value::as_bool),
        limit: req.get("limit").and_then(Value::as_u64).map(|n| n as usize),
    };
    let bytes = std::fs::read(path).map_err(|e| format!("io: {e}"))?;
    let text = String::from_utf8_lossy(&bytes);
    Ok(to_json(&parse(&text, &opts)))
}

pub fn to_json(p: &Parsed) -> Value {
    let h = &p.header;
    json!({
        "delimiter": p.delimiter.to_string(),
        "html": p.html,
        "delimiterFromHeader": h.delimiter.is_some(),
        "htmlFromHeader": h.html.is_some(),
        "columns": p.columns,
        "columnCount": p.column_count,
        "total": p.total,
        "rows": p.rows,
        "tags": h.tags,
        "notetype": h.notetype,
        "deck": h.deck,
        "notetypeColumn": h.notetype_column,
        "deckColumn": h.deck_column,
        "tagsColumn": h.tags_column,
        "guidColumn": h.guid_column,
        "ifMatches": h.if_matches,
        "matchScope": h.match_scope,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn v(xs: &[&str]) -> Vec<String> {
        xs.iter().map(|s| (*s).to_owned()).collect()
    }

    #[test]
    fn anki_export_header_is_honoured() {
        let text = "#separator:tab\n#html:true\n#tags column:3\n#deck:日本語::N3\n#notetype:Basic\n\
                    #columns:Front\tBack\tTags\n猫\t<b>cat</b>\tanimal n5\n犬\tdog\t\n";
        let p = parse(text, &ParseOptions::default());
        assert_eq!(p.delimiter, '\t');
        assert!(p.html);
        assert_eq!(p.columns, v(&["Front", "Back", "Tags"]));
        assert_eq!(p.header.tags_column, Some(3));
        assert_eq!(p.header.deck.as_deref(), Some("日本語::N3"));
        assert_eq!(p.header.notetype.as_deref(), Some("Basic"));
        assert_eq!(
            p.rows,
            vec![v(&["猫", "<b>cat</b>", "animal n5"]), v(&["犬", "dog", ""])]
        );
        assert_eq!(p.column_count, 3);
        assert_eq!(p.total, 2);
    }

    #[test]
    fn separator_names_and_bytes() {
        for (name, d) in [
            ("comma", ','),
            ("Semicolon", ';'),
            ("tab", '\t'),
            ("space", ' '),
            ("pipe", '|'),
            ("colon", ':'),
            (",", ','),
            ("|", '|'),
        ] {
            let (h, _) = read_header(&format!("#separator:{name}\n"));
            assert_eq!(h.delimiter, Some(d), "{name}");
        }
        let (h, _) = read_header("#separator:xx\n");
        assert_eq!(h.delimiter, None);
    }

    #[test]
    fn delimiter_is_guessed_in_anki_order() {
        assert_eq!(parse("a\tb,c\n", &ParseOptions::default()).delimiter, '\t');
        assert_eq!(parse("a;b,c\n", &ParseOptions::default()).delimiter, ';');
        assert_eq!(parse("a,b\n", &ParseOptions::default()).delimiter, ',');
        assert_eq!(parse("ab\n", &ParseOptions::default()).delimiter, ' ');
        // 指定的分隔符优先于文件头与猜测。
        let p = parse(
            "#separator:tab\na;b\tc\n",
            &ParseOptions {
                delimiter: Some(';'),
                ..ParseOptions::default()
            },
        );
        assert_eq!(p.rows, vec![v(&["a", "b\tc"])]);
    }

    #[test]
    fn quoting_comments_blank_lines_and_crlf() {
        let text = "\u{FEFF}\"a,1\",\"say \"\"hi\"\"\"\r\n\r\n# comment, here\r\n\"multi\r\nline\",x\r\nlast,\n";
        let p = parse(
            text,
            &ParseOptions {
                html: Some(true),
                ..ParseOptions::default()
            },
        );
        assert_eq!(p.delimiter, ',');
        assert_eq!(
            p.rows,
            vec![
                v(&["a,1", "say \"hi\""]),
                v(&["multi\r\nline", "x"]),
                v(&["last", ""])
            ]
        );
    }

    #[test]
    fn rows_may_have_different_widths_and_no_trailing_newline() {
        let p = parse("a,b,c\nd\ne,f", &ParseOptions::default());
        assert_eq!(p.rows, vec![v(&["a", "b", "c"]), v(&["d"]), v(&["e", "f"])]);
        assert_eq!(p.column_count, 3);
    }

    #[test]
    fn plain_text_is_escaped_and_newlines_become_br() {
        let p = parse("\"1 < 2 & 3\nnext\",b\n", &ParseOptions::default());
        assert!(!p.html);
        assert_eq!(p.rows, vec![v(&["1 &lt; 2 &amp; 3<br>next", "b"])]);
    }

    #[test]
    fn html_is_detected_from_any_field() {
        assert!(parse("a,<i>b</i>\n", &ParseOptions::default()).html);
        // 实体里的 `;` 会被猜成分隔符（Anki 同样），这里用 Tab 分隔。
        assert!(parse("a\t&nbsp;\n", &ParseOptions::default()).html);
        assert!(!parse("a,1 < 2\n", &ParseOptions::default()).html);
        // 文件头说不是 HTML 就不是，照样转义。
        let p = parse("#html:false\na,<i>b</i>\n", &ParseOptions::default());
        assert!(!p.html);
        assert_eq!(p.rows[0][1], "&lt;i&gt;b&lt;/i&gt;");
    }

    #[test]
    fn legacy_tags_line_and_other_header_keys() {
        let text = "tags:foo bar\n#guid column:1\n#If matches:keep both\n#match scope:notetype + deck\n\
                    #unknown:x\nid1,a\n";
        let p = parse(text, &ParseOptions::default());
        assert_eq!(p.header.tags, v(&["foo", "bar"]));
        assert_eq!(p.header.guid_column, Some(1));
        assert_eq!(p.header.if_matches, Some("duplicate"));
        assert_eq!(p.header.match_scope, Some("notetypeDeck"));
        assert_eq!(p.rows, vec![v(&["id1", "a"])]);
    }

    #[test]
    fn limit_keeps_total() {
        let p = parse(
            "a\nb\nc\n",
            &ParseOptions {
                limit: Some(2),
                ..ParseOptions::default()
            },
        );
        assert_eq!(p.rows.len(), 2);
        assert_eq!(p.total, 3);
    }

    #[test]
    fn dispatch_reads_file_and_rejects_bad_delimiter() {
        let dir = std::env::temp_dir().join(format!("fushi_text_import_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("cards.tsv");
        std::fs::write(&path, "Front\tBack\n").unwrap();
        let out = dispatch(&json!({"path": path.to_str().unwrap(), "limit": 5})).unwrap();
        assert_eq!(out["delimiter"], "\t");
        assert_eq!(out["rows"], json!([["Front", "Back"]]));
        assert_eq!(out["total"], 1);
        assert!(dispatch(&json!({"path": path.to_str().unwrap(), "delimiter": "ab"})).is_err());
        std::fs::remove_dir_all(&dir).ok();
    }
}
