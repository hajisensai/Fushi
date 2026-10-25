//! VTT / SAMI 正文共用的轻量标签切分（不是完整 HTML 解析器：歌词字幕里只有少量内联标签）。

#[derive(Debug, Clone, PartialEq)]
pub enum Tok {
    Text(String),
    /// `<name attrs>`：name 小写；`/name` 为闭合标签。
    Tag { name: String, attrs: String },
}

pub fn tokenize(s: &str) -> Vec<Tok> {
    let mut out = Vec::new();
    let mut text = String::new();
    let mut rest = s;
    while let Some(lt) = rest.find('<') {
        text.push_str(&rest[..lt]);
        let after = &rest[lt + 1..];
        match after.find('>') {
            Some(gt) => {
                if !text.is_empty() {
                    out.push(Tok::Text(unescape(&std::mem::take(&mut text))));
                }
                let inner = after[..gt].trim();
                let (name, attrs) = match inner.find(|c: char| c.is_whitespace() || c == '.') {
                    Some(i) => (&inner[..i], inner[i..].trim()),
                    None => (inner, ""),
                };
                out.push(Tok::Tag {
                    name: name.to_ascii_lowercase(),
                    attrs: attrs.to_owned(),
                });
                rest = &after[gt + 1..];
            }
            None => {
                text.push('<');
                rest = after;
            }
        }
    }
    text.push_str(rest);
    if !text.is_empty() {
        out.push(Tok::Text(unescape(&text)));
    }
    out
}

/// 常见实体（含数字实体）。
pub fn unescape(s: &str) -> String {
    if !s.contains('&') {
        return s.to_owned();
    }
    let mut out = String::with_capacity(s.len());
    let mut rest = s;
    while let Some(i) = rest.find('&') {
        out.push_str(&rest[..i]);
        let after = &rest[i + 1..];
        let Some(semi) = after.find(';').filter(|&p| p <= 10) else {
            out.push('&');
            rest = after;
            continue;
        };
        let ent = &after[..semi];
        let rep = match ent.to_ascii_lowercase().as_str() {
            "amp" => Some('&'),
            "lt" => Some('<'),
            "gt" => Some('>'),
            "quot" => Some('"'),
            "apos" => Some('\''),
            "nbsp" => Some('\u{a0}'),
            "lrm" | "rlm" | "zwj" | "zwnj" => Some('\u{0}'),
            e if e.starts_with("#x") => u32::from_str_radix(&e[2..], 16).ok().and_then(char::from_u32),
            e if e.starts_with('#') => e[1..].parse().ok().and_then(char::from_u32),
            _ => None,
        };
        match rep {
            Some('\u{0}') => {}
            Some(c) => out.push(c),
            None => {
                out.push('&');
                out.push_str(ent);
                out.push(';');
            }
        }
        rest = &after[semi + 1..];
    }
    out.push_str(rest);
    out
}

/// 去掉所有标签只留文本。
pub fn strip_tags(s: &str) -> String {
    tokenize(s)
        .into_iter()
        .filter_map(|t| match t {
            Tok::Text(s) => Some(s),
            Tok::Tag { .. } => None,
        })
        .collect()
}
