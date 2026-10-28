//! 笔记 / 卡片缓存行的纯计算部分（原 Dart `SrsDbStore._planNote` / `_mediaRefsOf` 与它们用到的
//! `srsNormalizeTerm`、`ankiStripHtml`、`clozeOrdinalsIn`、`templateIdsToNames` + `isAnkiCardEmpty`、
//! `srsMediaRefsIn`、`srsStyleRefsIn`）。读库、写库与刷新调度在 store/caches.rs。
//!
//! 逐条对齐删除前的 Dart 实现（Dart 正则是 JS 非 unicode 模式：`\s` 是 JS 空白、`\b` 与大小写折叠只认
//! ASCII；字符串下标是 UTF-16 码元）。固定向量 tests/fixtures/cache_text_vectors.json 由删除前的 Dart 实现
//! 生成，见文件末尾的测试。唯一有意的偏差：媒体引用的百分号解码得到非法 UTF-8 时 Dart 抛 FormatException
//! （整次缓存刷新失败），这里按「不是合法编码」原样保留。

use std::sync::OnceLock;

use regex::Regex;

use crate::ordering::cmp_utf16;
use crate::style_dedup::script_blocks;

// ---------------------------------------------------------------- 字符类

/// JS 正则 `\s`（Dart `RegExp` 的 `\s`）：不含 U+0085，含 U+FEFF。
pub(crate) fn is_js_space(c: char) -> bool {
    matches!(
        c,
        '\t' | '\n'
            | '\u{0B}'
            | '\u{0C}'
            | '\r'
            | ' '
            | '\u{A0}'
            | '\u{1680}'
            | '\u{2000}'..='\u{200A}'
            | '\u{2028}'
            | '\u{2029}'
            | '\u{202F}'
            | '\u{205F}'
            | '\u{3000}'
            | '\u{FEFF}'
    )
}

/// Dart `String.trim` 的空白：Unicode White_Space 加 BOM。
fn is_dart_trim_space(c: char) -> bool {
    c.is_whitespace() || c == '\u{FEFF}'
}

fn dart_trim(s: &str) -> &str {
    s.trim_matches(is_dart_trim_space)
}

fn dart_trim_left(s: &str) -> &str {
    s.trim_start_matches(is_dart_trim_space)
}

fn dart_trim_right(s: &str) -> &str {
    s.trim_end_matches(is_dart_trim_space)
}

/// ASCII 单词字符（JS 非 unicode 模式的 `\b` / `\w`）。
fn is_word(c: Option<char>) -> bool {
    c.is_some_and(|c| c.is_ascii_alphanumeric() || c == '_')
}

/// `s[at..]` 是否以 ASCII 模式 [pat] 开头（只做 ASCII 大小写折叠）；是则返回终点。
fn match_ascii_ci(s: &str, at: usize, pat: &str) -> Option<usize> {
    let b = s.as_bytes().get(at..at + pat.len())?;
    b.eq_ignore_ascii_case(pat.as_bytes()).then_some(at + pat.len())
}

fn utf16_len(s: &str) -> usize {
    s.chars().map(char::len_utf16).sum()
}

/// Dart `substring(0, n)`（n 按 UTF-16 码元）落库后的形态：截在代理对中间的孤立高位代理编码成 UTF-8
/// 时变成 U+FFFD。
fn truncate_utf16(s: &str, n: usize) -> String {
    if utf16_len(s) <= n {
        return s.to_owned();
    }
    let mut out = String::new();
    let mut units = 0;
    for c in s.chars() {
        let l = c.len_utf16();
        if units + l > n {
            if units < n {
                out.push('\u{FFFD}');
            }
            break;
        }
        out.push(c);
        units += l;
    }
    out
}

// ---------------------------------------------------------------- termKey / readingKey

/// Dart `String.toLowerCase`（VM 逐码点的简单映射：一对多的只有 U+0130，映射成 `i`）。
fn dart_lower(c: char, out: &mut String) {
    let mut it = c.to_lowercase();
    match (it.next(), it.next()) {
        (Some(a), None) => out.push(a),
        (Some(a), Some(_)) => out.push(a),
        _ => out.push(c),
    }
}

/// `srsNormalizeTerm`（packages/fushi_srs/lib/src/term_status.dart）：去 `<[^>]*>`、去 `\[[^\]]*\]`、
/// `&nbsp;` → 空格、去 `\s+`、全角 ASCII → 半角、小写。
pub fn normalize_term(raw: &str) -> String {
    let no_tags = remove_delimited(raw, '<', '>');
    let no_ruby = remove_delimited(&no_tags, '[', ']');
    let spaced = no_ruby.replace("&nbsp;", " ");
    let mut out = String::with_capacity(spaced.len());
    for c in spaced.chars() {
        if is_js_space(c) {
            continue;
        }
        let c = match c as u32 {
            0xFF01..=0xFF5E => char::from_u32(c as u32 - 0xFEE0).expect("ascii"),
            _ => c,
        };
        dart_lower(c, &mut out);
    }
    out
}

/// `replaceAll(RegExp('<open>[^<close>]*<close>'), '')`：每个开字符到它之后第一个闭字符整段删掉；后面
/// 再没有闭字符的开字符原样保留（之后的开字符也凑不成）。
fn remove_delimited(s: &str, open: char, close: char) -> String {
    let mut out = String::with_capacity(s.len());
    let mut rest = s;
    while let Some(p) = rest.find(open) {
        match rest[p + open.len_utf8()..].find(close) {
            Some(q) => {
                out.push_str(&rest[..p]);
                rest = &rest[p + open.len_utf8() + q + close.len_utf8()..];
            }
            None => break,
        }
    }
    out.push_str(rest);
    out
}

// ---------------------------------------------------------------- sortField（ankiStripHtml）

/// `(?si)(<!--.*?-->)|(<style.*?>.*?</style>)|(<script.*?>.*?</script>)|(<.*?>)` 的 `replaceAll(…, '')`
/// （Dart `ankiStripHtmlPreservingEntities`）。扫描同 search.rs `strip_tags`，但大小写只做 ASCII 折叠
/// （JS 非 unicode 模式里 `ſ` 不等于 `s`）。
fn strip_tags(html: &str) -> String {
    let bytes = html.as_bytes();
    let mut out = String::with_capacity(html.len());
    let mut last = 0;
    let mut from = 0;
    while let Some(rel) = bytes[from..].iter().position(|&b| b == b'<') {
        let p = from + rel;
        match tag_end(html, p) {
            Some(e) => {
                out.push_str(&html[last..p]);
                last = e;
                from = e;
            }
            None => break,
        }
    }
    out.push_str(&html[last..]);
    out
}

fn tag_end(html: &str, p: usize) -> Option<usize> {
    let bytes = html.as_bytes();
    let gt = |from: usize| bytes[from..].iter().position(|&b| b == b'>').map(|i| from + i);
    let first_gt = gt(p + 1)?;
    if html[p..].starts_with("<!--") {
        if let Some(i) = html[p + 4..].find("-->") {
            return Some(p + 4 + i + 3);
        }
    }
    for (open, close) in [("style", "/style>"), ("script", "/script>")] {
        if let Some(name_end) = match_ascii_ci(html, p + 1, open) {
            if let Some(g) = gt(name_end) {
                let mut at = g + 1;
                while let Some(rel) = bytes[at..].iter().position(|&b| b == b'<') {
                    let q = at + rel;
                    if let Some(e) = match_ascii_ci(html, q + 1, close) {
                        return Some(e);
                    }
                    at = q + 1;
                }
            }
        }
    }
    Some(first_gt + 1)
}

fn named_entity(name: &str) -> Option<&'static str> {
    Some(match name {
        "amp" => "&",
        "lt" => "<",
        "gt" => ">",
        "quot" => "\"",
        "apos" => "'",
        "nbsp" | "ensp" | "emsp" | "thinsp" => " ",
        "ndash" => "\u{2013}",
        "mdash" => "\u{2014}",
        "hellip" => "\u{2026}",
        "lsquo" => "\u{2018}",
        "rsquo" => "\u{2019}",
        "ldquo" => "\u{201C}",
        "rdquo" => "\u{201D}",
        "middot" => "\u{B7}",
        "times" => "\u{D7}",
        "divide" => "\u{F7}",
        "copy" => "\u{A9}",
        "reg" => "\u{AE}",
        "deg" => "\u{B0}",
        "laquo" => "\u{AB}",
        "raquo" => "\u{BB}",
        "shy" => "\u{AD}",
        "zwj" => "\u{200D}",
        "zwnj" => "\u{200C}",
        _ => return None,
    })
}

fn entity_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"&(#[0-9]+|#[xX][0-9a-fA-F]+|[A-Za-z]+);").expect("regex"))
}

/// Dart `_decodeEntities`：数字实体与常用命名实体，不认得的原样保留；`&#160;` 解成普通空格。代理区码点在
/// Dart 里是孤立代理，落库成 U+FFFD。
fn decode_entities(text: &str) -> String {
    if !text.contains('&') {
        return text.to_owned();
    }
    entity_re()
        .replace_all(text, |caps: &regex::Captures<'_>| {
            let whole = caps.get(0).expect("match").as_str();
            let body = caps.get(1).expect("group").as_str();
            if let Some(num) = body.strip_prefix('#') {
                let parsed = match num.strip_prefix(['x', 'X']) {
                    Some(hex) => u64::from_str_radix(hex, 16).ok(),
                    None => num.parse::<u64>().ok(),
                };
                return match parsed {
                    Some(0xA0) => " ".to_owned(),
                    Some(code) if code <= 0x10FFFF => char::from_u32(code as u32).unwrap_or('\u{FFFD}').to_string(),
                    _ => whole.to_owned(),
                };
            }
            named_entity(body).unwrap_or(whole).to_owned()
        })
        .into_owned()
}

/// 笔记缓存的 `sort_field`：首字段 `ankiStripHtml(..).trim()`，最多 200 个 UTF-16 码元。
pub fn sort_field(first_field: &str) -> String {
    let stripped = decode_entities(&strip_tags(first_field));
    truncate_utf16(dart_trim(&stripped), 200)
}

// ---------------------------------------------------------------- cloze 序号（rslib cloze.rs）

enum ClozeTok {
    Open(Vec<u32>),
    Text,
    Close,
}

/// `{{c1,2::` 开头：成功返回 (排好序的序号, 消耗字节数)。
fn open_cloze(text: &str, at: usize) -> Option<(Vec<u32>, usize)> {
    if !text[at..].starts_with("{{c") {
        return None;
    }
    let bytes = text.as_bytes();
    let mut i = at + 3;
    while i < bytes.len() && (bytes[i].is_ascii_digit() || bytes[i] == b',') {
        i += 1;
    }
    let mut set: Vec<u32> = Vec::new();
    for part in text[at + 3..i].split(',') {
        if let Ok(n) = part.parse::<u64>() {
            if n <= 0xFFFF && !set.contains(&(n as u32)) {
                set.push(n as u32);
            }
        }
    }
    if set.is_empty() || !text[i..].starts_with("::") {
        return None;
    }
    set.sort_unstable();
    Some((set, i + 2 - at))
}

/// MathJax 状态：表达式内的 `}}` 只能关掉在同一表达式里打开的 cloze。
#[derive(Default)]
struct MathJax {
    current: Option<(&'static str, u32)>,
    next_id: u32,
    regions: Vec<Option<u32>>,
}

impl MathJax {
    fn region(&self) -> Option<u32> {
        self.current.map(|c| c.1)
    }

    fn can_close(&self) -> bool {
        match self.region() {
            None => true,
            Some(r) => self.regions.last() == Some(&Some(r)),
        }
    }

    fn consume(&mut self, text: &str, at: usize) -> Option<usize> {
        match self.current {
            None => {
                for (open, close) in [("\\(", "\\)"), ("\\[", "\\]")] {
                    if text[at..].starts_with(open) && text[at + open.len()..].contains(close) {
                        self.current = Some((close, self.next_id));
                        self.next_id += 1;
                        return Some(open.len());
                    }
                }
                None
            }
            Some((close, _)) => {
                if text[at..].starts_with(close) {
                    self.current = None;
                    Some(close.len())
                } else {
                    None
                }
            }
        }
    }
}

fn cloze_tokens(text: &str) -> Vec<ClozeTok> {
    let mut out = Vec::new();
    let mut st = MathJax::default();
    let mut pos = 0;
    while pos < text.len() {
        if let Some((ords, n)) = open_cloze(text, pos) {
            st.regions.push(st.region());
            out.push(ClozeTok::Open(ords));
            pos += n;
            continue;
        }
        if st.can_close() && text[pos..].starts_with("}}") {
            st.regions.pop();
            out.push(ClozeTok::Close);
            pos += 2;
            continue;
        }
        let mut i = pos;
        while i < text.len() {
            if open_cloze(text, i).is_some() || (st.can_close() && text[i..].starts_with("}}")) {
                break;
            }
            match st.consume(text, i) {
                Some(n) => i += n,
                None => i += text[i..].chars().next().map_or(1, char::len_utf8),
            }
        }
        out.push(ClozeTok::Text);
        pos = i;
    }
    out
}

/// `clozeOrdinalsIn`：文本里出现的全部 cloze 序号（`c0` 不算；`{{c1,2::x}}` 计 1、2；含嵌套；未闭合的、
/// 第 10 层以下被丢弃的不算），按 Dart `Set` 的插入顺序。
pub fn cloze_ordinals(text: &str) -> Vec<u32> {
    // 每个闭合的 cloze 记成 (序号, 子 cloze)；只有挂到输出树上的才算。
    struct Node {
        ords: Vec<u32>,
        kids: Vec<Node>,
    }
    let mut open: Vec<Node> = Vec::new();
    let mut output: Vec<Node> = Vec::new();
    for tok in cloze_tokens(text) {
        match tok {
            ClozeTok::Open(ords) => {
                if open.len() < 10 {
                    open.push(Node { ords, kids: Vec::new() });
                }
            }
            ClozeTok::Text => {}
            ClozeTok::Close => {
                if let Some(c) = open.pop() {
                    match open.last_mut() {
                        Some(parent) => parent.kids.push(c),
                        None => output.push(c),
                    }
                }
            }
        }
    }
    fn walk(nodes: &[Node], out: &mut Vec<u32>) {
        for n in nodes {
            for &o in &n.ords {
                if o != 0 && !out.contains(&o) {
                    out.push(o);
                }
            }
            walk(&n.kids, out);
        }
    }
    let mut out = Vec::new();
    walk(&output, &mut out);
    out
}

// ---------------------------------------------------------------- 模板（rslib template.rs）

#[derive(Clone, Copy, PartialEq, Eq)]
enum TokKind {
    Text,
    Comment,
    Replacement,
    Open,
    OpenNegated,
    Close,
    Prelude,
}

/// 一个词元（下标都是字节，落在 ASCII 定界符或 trim 边界上，与 Dart 的 UTF-16 下标一一对应）。
struct Tok<'t> {
    kind: TokKind,
    raw: String,
    inner: &'t str,
    start_tag: &'static str,
    end_tag: &'static str,
    key_start: usize,
    key_end: usize,
}

impl Tok<'_> {
    fn plain(kind: TokKind, raw: &str) -> Tok<'static> {
        Tok { kind, raw: raw.to_owned(), inner: "", start_tag: "", end_tag: "", key_start: 0, key_end: 0 }
    }

    fn replacement_start(&self) -> usize {
        self.inner.len() - leading_trimmed(self.inner).len()
    }

    fn body(&self) -> &str {
        let start = if self.kind == TokKind::Replacement { self.replacement_start() } else { self.key_start };
        &self.inner[start..self.key_end]
    }
}

/// 去掉开头的 `{` 再去开头空白。
fn leading_trimmed(inner: &str) -> &str {
    dart_trim_left(inner.trim_start_matches('{'))
}

const COMMENT_START: &str = "<!--";
const COMMENT_END: &str = "-->";
const ALT_DIRECTIVE: &str = "{{=<% %>=}}";

fn tokenize(template: &str) -> Vec<Tok<'_>> {
    let mut out = Vec::new();
    let mut text = template;
    let (mut start_tag, mut end_tag) = ("{{", "}}");
    let trimmed = dart_trim_left(template);
    if trimmed.starts_with(ALT_DIRECTIVE) {
        let mut rest = trimmed;
        while let Some(r) = rest.strip_prefix(ALT_DIRECTIVE) {
            rest = r;
        }
        out.push(Tok::plain(TokKind::Prelude, &template[..template.len() - rest.len()]));
        text = rest;
        start_tag = "<%";
        end_tag = "%>";
    }
    let mut text_start = 0;
    let mut i = 0;
    let flush = |out: &mut Vec<Tok<'_>>, from: usize, to: usize| {
        if to > from {
            out.push(Tok::plain(TokKind::Text, &text[from..to]));
        }
    };
    while i < text.len() {
        if text[i..].starts_with(start_tag) {
            if let Some(rel) = text[i + start_tag.len()..].find(end_tag) {
                let close = i + start_tag.len() + rel;
                flush(&mut out, text_start, i);
                out.push(classify(&text[i + start_tag.len()..close], start_tag, end_tag));
                i = close + end_tag.len();
                text_start = i;
                continue;
            }
        }
        if text[i..].starts_with(COMMENT_START) {
            if let Some(rel) = text[i + COMMENT_START.len()..].find(COMMENT_END) {
                let close = i + COMMENT_START.len() + rel;
                flush(&mut out, text_start, i);
                let end = close + COMMENT_END.len();
                out.push(Tok {
                    kind: TokKind::Comment,
                    raw: text[i..end].to_owned(),
                    inner: &text[i + COMMENT_START.len()..close],
                    start_tag: "",
                    end_tag: "",
                    key_start: 0,
                    key_end: 0,
                });
                i = end;
                text_start = i;
                continue;
            }
        }
        i += text[i..].chars().next().map_or(1, char::len_utf8);
    }
    flush(&mut out, text_start, text.len());
    out
}

fn classify<'t>(inner: &'t str, start_tag: &'static str, end_tag: &'static str) -> Tok<'t> {
    let raw = format!("{start_tag}{inner}{end_tag}");
    let trimmed_left = leading_trimmed(inner);
    let start = dart_trim_right(trimmed_left);
    let start_offset = inner.len() - trimmed_left.len();
    let start_end = start_offset + start.len();
    let replacement = |raw: String| {
        let key_start = match start.rfind(':') {
            Some(colon) => start_offset + colon + 1,
            None => start_offset,
        };
        Tok { kind: TokKind::Replacement, raw, inner, start_tag, end_tag, key_start, key_end: start_end }
    };
    if utf16_len(start) < 2 {
        return replacement(raw);
    }
    let kind = match start.as_bytes()[0] {
        b'#' => TokKind::Open,
        b'/' => TokKind::Close,
        b'^' => TokKind::OpenNegated,
        _ => return replacement(raw),
    };
    let stripped = dart_trim_left(&start[1..]);
    Tok { kind, raw, inner, start_tag, end_tag, key_start: start_end - stripped.len(), key_end: start_end }
}

/// `templateIdsToNames`：`{{…fld:<id>}}` / `{{#fld:<id>}}` 换成字段名；表里没有的 id 原样保留。
fn ids_to_names(template: &str, id_to_name: &dyn Fn(&str) -> Option<String>) -> String {
    const PREFIX: &str = "fld:";
    let mut out = String::with_capacity(template.len());
    for tok in tokenize(template) {
        if matches!(tok.kind, TokKind::Text | TokKind::Comment | TokKind::Prelude) {
            out.push_str(&tok.raw);
            continue;
        }
        let mut key_start = tok.key_start;
        if tok.kind == TokKind::Replacement {
            let before = &tok.inner[..key_start];
            if before.ends_with(PREFIX) && before.len() - PREFIX.len() >= tok.replacement_start() {
                key_start -= PREFIX.len();
            }
        }
        let key = &tok.inner[key_start..tok.key_end];
        let replaced = key.strip_prefix(PREFIX).and_then(id_to_name);
        match replaced {
            None => out.push_str(&tok.raw),
            Some(name) => {
                out.push_str(tok.start_tag);
                out.push_str(&tok.inner[..key_start]);
                out.push_str(&name);
                out.push_str(&tok.inner[tok.key_end..]);
                out.push_str(tok.end_tag);
            }
        }
    }
    out
}

enum Node {
    /// 文本 / 注释：判空时跳过。
    Inert,
    Replacement(String),
    Conditional { key: String, negated: bool, children: Vec<Node> },
}

/// 严格解析（rslib `parse_inner`）：段不配对是语法错误。
fn parse_strict(tokens: &[Tok<'_>]) -> Result<Vec<Node>, String> {
    fn inner(tokens: &[Tok<'_>], index: &mut usize, open: Option<&str>) -> Result<Vec<Node>, String> {
        let mut nodes = Vec::new();
        while *index < tokens.len() {
            let tok = &tokens[*index];
            *index += 1;
            match tok.kind {
                TokKind::Prelude => {}
                TokKind::Text | TokKind::Comment => nodes.push(Node::Inert),
                TokKind::Replacement => {
                    let key = tok.body().rsplit(':').next().unwrap_or("").to_owned();
                    nodes.push(Node::Replacement(key));
                }
                TokKind::Open | TokKind::OpenNegated => {
                    let key = tok.body().to_owned();
                    let children = inner(tokens, index, Some(&key))?;
                    nodes.push(Node::Conditional { key, negated: tok.kind == TokKind::OpenNegated, children });
                }
                TokKind::Close => {
                    let key = tok.body();
                    return match open {
                        Some(o) if o == key => Ok(nodes),
                        Some(o) => Err(format!("Found {{{{/{key}}}}}, but expected {{{{/{o}}}}}")),
                        None => Err(format!("Found {{{{/{key}}}}}, but missing open tag")),
                    };
                }
            }
        }
        match open {
            Some(o) => Err(format!("Missing {{{{/{o}}}}}")),
            None => Ok(nodes),
        }
    }
    let mut index = 0;
    inner(tokens, &mut index, None)
}

/// rslib `field_is_empty`：只含 ASCII 空白与空 `<br>` / `<div>`（`^(?:[\t\n\x0B\f\r ]|</?(?:br|div) ?/?>)*$`，
/// 不区分大小写）。
fn field_is_empty(text: &str) -> bool {
    let b = text.as_bytes();
    let mut i = 0;
    while i < b.len() {
        match b[i] {
            b'\t' | b'\n' | 0x0B | 0x0C | b'\r' | b' ' => i += 1,
            b'<' => {
                let mut j = i + 1;
                if b.get(j) == Some(&b'/') {
                    j += 1;
                }
                j = match match_ascii_ci(text, j, "br").or_else(|| match_ascii_ci(text, j, "div")) {
                    Some(e) => e,
                    None => return false,
                };
                if b.get(j) == Some(&b' ') {
                    j += 1;
                }
                if b.get(j) == Some(&b'/') {
                    j += 1;
                }
                if b.get(j) != Some(&b'>') {
                    return false;
                }
                i = j + 1;
            }
            _ => return false,
        }
    }
    true
}

/// rslib `template_is_empty`（`check_negated = true`）。
fn template_is_empty(non_empty: &dyn Fn(&str) -> bool, nodes: &[Node]) -> bool {
    for n in nodes {
        match n {
            Node::Inert => {}
            Node::Replacement(key) => {
                if non_empty(key) {
                    return false;
                }
            }
            Node::Conditional { key, negated, children } => {
                let has = non_empty(key);
                if has == *negated {
                    continue;
                }
                if !template_is_empty(non_empty, children) {
                    return false;
                }
            }
        }
    }
    true
}

/// 非 cloze 卡正面是否为空（`isAnkiCardEmpty(questionTemplate: templateIdsToNames(front, idToName),
/// noteFields: byName, cardOrd: ord, isCloze: false)`，特殊字段取缺省值）。模板语法错误 = `Err`
/// （Dart 侧 catch 成「不空」）。[fields] 是按名字的字段表（Dart `Map` 语义：同名后者覆盖）。
pub fn card_front_is_empty(
    front: &str,
    id_to_name: &dyn Fn(&str) -> Option<String>,
    fields: &[(String, String)],
    ord: i64,
) -> Result<bool, String> {
    let question = ids_to_names(front, id_to_name);
    let nodes = parse_strict(&tokenize(&question))?;
    let cn = format!("c{}", ord + 1);
    let value_of = |name: &str| -> Option<&str> {
        fields.iter().rev().find(|(n, _)| n == name).map(|(_, v)| v.as_str())
    };
    // 特殊字段（`ankiFieldMapWithSpecials`，缺省值）：笔记里没有同名字段时才补。
    let special = |name: &str| -> Option<&'static str> {
        Some(match name {
            "Tags" | "Type" | "Card" | "CardID" => "",
            "Subdeck" | "Deck" => "(Deck)",
            "CardFlag" => "flag0",
            _ if name == cn => "1",
            _ => return None,
        })
    };
    let non_empty = |key: &str| -> bool {
        match value_of(key).or_else(|| special(key)) {
            Some(v) => !field_is_empty(v),
            None => false,
        }
    };
    Ok(template_is_empty(&non_empty, &nodes))
}

// ---------------------------------------------------------------- 媒体引用

/// `<\b(?:img|audio|video|object|source|iframe)\b[^>]+\b(?:src|data)\b=(?:"([^"]+?)"|'([^']+?)'|([^ >]+?))(?=\s|>)`
/// （`caseSensitive: false`，JS 回溯语义）的全部匹配的值。`[^>]+` 是贪婪的：同一标签里取最靠后的那个
/// 能接上值的 `src` / `data`。
fn html_media_values(html: &str) -> Vec<&str> {
    const TAGS: [&str; 6] = ["img", "audio", "video", "object", "source", "iframe"];
    let b = html.as_bytes();
    let char_at = |i: usize| html.get(i..).and_then(|s| s.chars().next());
    let char_before = |i: usize| html.get(..i).and_then(|s| s.chars().next_back());
    let mut out = Vec::new();
    let mut from = 0;
    while let Some(rel) = b[from..].iter().position(|&x| x == b'<') {
        let p = from + rel;
        from = p + 1;
        let Some(q) = TAGS.iter().find_map(|t| match_ascii_ci(html, p + 1, t)) else { continue };
        if is_word(char_at(q)) {
            continue;
        }
        // `[^>]+` 的最远终点：q 之后第一个 `>`（或串尾）。
        let r = b[q..].iter().position(|&x| x == b'>').map_or(b.len(), |i| q + i);
        // 从最远处往回试每个 `src` / `data` 起点 s（q < s ≤ r，且落在字符边界上）。
        let mut found: Option<(usize, usize, usize)> = None;
        let mut s = r;
        while s > q {
            if html.is_char_boundary(s) && !is_word(char_before(s)) {
                for name in ["src", "data"] {
                    let Some(ne) = match_ascii_ci(html, s, name) else { continue };
                    if is_word(char_at(ne)) || b.get(ne) != Some(&b'=') {
                        continue;
                    }
                    if let Some((vs, ve, end)) = media_value(html, ne + 1) {
                        found = Some((vs, ve, end));
                        break;
                    }
                }
                if found.is_some() {
                    break;
                }
            }
            s -= 1;
        }
        if let Some((vs, ve, end)) = found {
            out.push(&html[vs..ve]);
            from = end;
        }
    }
    out
}

/// `=` 之后（[v]）的值：三种写法按顺序试，带 `(?=\s|>)` 前瞻。返回 (值起点, 值终点, 匹配终点)。
fn media_value(html: &str, v: usize) -> Option<(usize, usize, usize)> {
    let b = html.as_bytes();
    let lookahead = |i: usize| html.get(i..).and_then(|s| s.chars().next()).is_some_and(|c| is_js_space(c) || c == '>');
    for quote in [b'"', b'\''] {
        if b.get(v) == Some(&quote) {
            if let Some(rel) = b[v + 1..].iter().position(|&x| x == quote) {
                let close = v + 1 + rel;
                if close > v + 1 && lookahead(close + 1) {
                    return Some((v + 1, close, close + 1));
                }
            }
        }
    }
    // `([^ >]+?)` 懒惰：第一个后面紧跟 `\s` / `>` 的位置（值里不能有空格与 `>`）。
    let mut i = v;
    while let Some(c) = html.get(i..).and_then(|s| s.chars().next()) {
        if c == ' ' || c == '>' {
            return None;
        }
        i += c.len_utf8();
        if lookahead(i) {
            return Some((v, i, i));
        }
    }
    None
}

fn is_remote(name: &str) -> bool {
    name.contains("://") || name.starts_with("data:")
}

/// Dart `Uri.decodeFull`：有非 ASCII 字符 / 百分号残缺 / 不是十六进制 = `ArgumentError`（调用方原样保留）。
fn uri_decode_full(s: &str) -> Option<String> {
    if !s.bytes().any(|b| b == b'%') && s.is_ascii() {
        return Some(s.to_owned());
    }
    let b = s.as_bytes();
    let mut bytes = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        let c = b[i];
        if c > 127 {
            return None;
        }
        if c == b'%' {
            if i + 3 > b.len() {
                return None;
            }
            let hex = |x: u8| -> Option<u8> { (x as char).to_digit(16).map(|d| d as u8) };
            bytes.push(hex(b[i + 1])? * 16 + hex(b[i + 2])?);
            i += 3;
        } else {
            bytes.push(c);
            i += 1;
        }
    }
    String::from_utf8(bytes).ok()
}

fn unescape(s: &str) -> String {
    let out = s
        .replace("&amp;", "&")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&lt;", "<")
        .replace("&gt;", ">");
    uri_decode_full(&out).unwrap_or(out)
}

/// `srsMediaRefsIn`（includeStatic = false）。
fn media_refs_in(html: &str, out: &mut Vec<String>) {
    if !html.contains('<') && !html.contains("[sound:") {
        return;
    }
    for raw in html_media_values(html) {
        if !raw.is_empty() && !is_remote(raw) {
            out.push(unescape(raw));
        }
    }
    // `\[sound:([^\]]+)\]`
    let mut from = 0;
    while let Some(rel) = html[from..].find("[sound:") {
        let p = from + rel;
        let v = p + "[sound:".len();
        match html[v..].find(']') {
            Some(0) => from = p + 1,
            Some(n) => {
                let raw = &html[v..v + n];
                if !is_remote(raw) {
                    out.push(unescape(raw));
                }
                from = v + n + 1;
            }
            None => break,
        }
    }
}

fn style_link_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r#"<link rel="stylesheet" href="(_fushi_style_[0-9a-f]{40}\.css)">"#).expect("regex"))
}

/// `srsStyleRefsIn`：`<script>` 之外引用的共享样式文件名。
fn style_refs_in(html: &str, out: &mut Vec<String>) {
    if !html.contains("_fushi_style_") {
        return;
    }
    let mut chunk = |c: &str| {
        for m in style_link_re().captures_iter(c) {
            out.push(m[1].to_owned());
        }
    };
    let mut last = 0;
    for (s, e) in script_blocks(html) {
        chunk(&html[last..s]);
        last = e;
    }
    chunk(&html[last..]);
}

/// 笔记缓存的 `media_refs`：全部字段值引用的媒体与共享样式文件名，去重、去掉含换行的、按 UTF-16 排序、
/// 换行分隔（Dart `SrsDbStore._mediaRefsOf`）。
pub fn media_refs<'a>(values: impl IntoIterator<Item = &'a str>) -> String {
    let mut refs: Vec<String> = Vec::new();
    for v in values {
        media_refs_in(v, &mut refs);
        style_refs_in(v, &mut refs);
    }
    refs.retain(|r| !r.contains('\n'));
    refs.sort_by(|a, b| cmp_utf16(a, b));
    refs.dedup();
    refs.join("\n")
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;

    #[test]
    fn hand_cases() {
        assert_eq!(normalize_term("<b>Ｈｅｌｌｏ</b> 漢字[かんじ]&nbsp;"), "hello漢字");
        assert_eq!(sort_field("  <style>x</style><i>a&amp;b</i>&hellip; "), "a&b\u{2026}");
        assert_eq!(cloze_ordinals("{{c2::a}} {{c1,3::b::h}} {{c0::z}}"), vec![2, 1, 3]);
        assert_eq!(cloze_ordinals("{{c1::open"), Vec::<u32>::new());
        let names = |id: &str| (id == "x").then(|| "Front".to_owned());
        let f = vec![("Front".to_owned(), "<br>".to_owned())];
        assert_eq!(card_front_is_empty("{{fld:x}}", &names, &f, 0), Ok(true));
        assert_eq!(card_front_is_empty("{{Deck}}", &names, &f, 0), Ok(false));
        assert!(card_front_is_empty("{{#fld:x}}", &names, &f, 0).is_err());
        assert_eq!(
            media_refs(["<img src=\"a%20b.png\"> <IMG SRC=c.jpg>[sound:d.mp3]<img src='http://x/y.png'>"]),
            "a b.png\nc.jpg\nd.mp3"
        );
    }

    /// 删除前的 Dart 实现生成的向量（packages/fushi_engine/test/srs/fixtures/gen_cache_vectors.dart.txt）。
    #[test]
    fn dart_vectors() {
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fixtures/cache_text_vectors.json");
        let root: Value = serde_json::from_str(&std::fs::read_to_string(path).expect("vectors")).expect("json");
        let mut n = 0;
        for v in root["text"].as_array().expect("text") {
            let s = v["s"].as_str().expect("s");
            assert_eq!(normalize_term(s), v["term"].as_str().unwrap(), "term of {s:?}");
            assert_eq!(sort_field(s), v["sort"].as_str().unwrap(), "sort of {s:?}");
            let want: Vec<u32> = v["cloze"].as_array().unwrap().iter().map(|x| x.as_u64().unwrap() as u32).collect();
            assert_eq!(cloze_ordinals(s), want, "cloze of {s:?}");
            // null = Dart 解百分号编码得到非法 UTF-8 时抛异常（文件头的有意偏差）：只要求这里不 panic。
            match v["media"].as_str() {
                Some(want) => assert_eq!(media_refs([s]), want, "media of {s:?}"),
                None => {
                    media_refs([s]);
                }
            }
            n += 1;
        }
        let mut m = 0;
        for v in root["templateEmpty"].as_array().expect("templateEmpty") {
            let front = v["front"].as_str().unwrap();
            let map = v["idToName"].as_object().unwrap();
            let names = |id: &str| map.get(id).and_then(Value::as_str).map(str::to_owned);
            let fields: Vec<(String, String)> = v["fields"]
                .as_object()
                .unwrap()
                .iter()
                .map(|(k, x)| (k.clone(), x.as_str().unwrap().to_owned()))
                .collect();
            let got = card_front_is_empty(front, &names, &fields, v["ord"].as_i64().unwrap()).ok();
            assert_eq!(got, v["empty"].as_bool(), "template {front:?} fields {fields:?}");
            m += 1;
        }
        assert!(n > 100 && m > 50, "vectors too small: {n} / {m}");
    }
}
