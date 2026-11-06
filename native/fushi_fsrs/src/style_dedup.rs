//! 「释义样式去重」的规范形（Dart `srsDedupStyles`，packages/fushi_srs/lib/src/style_dedup.dart）：
//! 够大（≥ 512 个 UTF-16 码元）的无属性 `<style>`…`</style>` 块换成共享样式引用行，`<script>` 块里的
//! 文字不碰。Rust 侧有两个用处，共用这一份扫描：
//!
//! - 字段寄存器（registers.rs）的「值相同」：内联样式与它的引用行是同一内容（[same_field_text]）；
//! - AnkiConnect 查重的首字段规范形（search.rs `dupe_norm`）：引用行之后整个被去 HTML 删掉，只放占位标签。
//!
//! 写库时真正的去重（换引用 + 落共享样式文件）仍在 Dart（要写媒体文件）；两份由固定向量
//! packages/fushi_srs/test/registers/ 与 style_dedup_test 钉齐。门槛与引用行写法属于持久化格式，冻结。

use std::borrow::Cow;

use sha1::{Digest, Sha1};

const OPEN: &str = "<style>";
const CLOSE: &str = "</style>";

/// 去重门槛（Dart `kSrsStyleDedupMinChars`，冻结）。
const MIN_CHARS: usize = 512;

/// JS 正则 `\s`（Dart `RegExp` 的 `\s`）。
fn is_js_space(c: char) -> bool {
    matches!(
        c,
        '\t' | '\n' | '\u{0B}' | '\u{0C}' | '\r' | ' ' | '\u{A0}' | '\u{1680}' | '\u{2000}'
            ..='\u{200A}'
                | '\u{2028}'
                | '\u{2029}'
                | '\u{202F}'
                | '\u{205F}'
                | '\u{3000}'
                | '\u{FEFF}'
    )
}

fn starts_with_ci(s: &str, at: usize, pat: &str) -> bool {
    s.as_bytes()
        .get(at..at + pat.len())
        .is_some_and(|b| b.eq_ignore_ascii_case(pat.as_bytes()))
}

/// Dart `RegExp(r'<script\b[\s\S]*?</script\s*>', caseSensitive: false).allMatches` 的全部区间：
/// 字母只做 ASCII 大小写折叠、`\b` 是 ASCII 单词边界（与 JS 非 unicode 模式一致）。
pub fn script_blocks(text: &str) -> Vec<(usize, usize)> {
    let bytes = text.as_bytes();
    let mut out = Vec::new();
    let mut from = 0;
    'outer: while let Some(rel) = text[from..].find('<') {
        let start = from + rel;
        from = start + 1;
        if !starts_with_ci(text, start, "<script") {
            continue;
        }
        let after = start + 7;
        if bytes
            .get(after)
            .is_some_and(|b| b.is_ascii_alphanumeric() || *b == b'_')
        {
            continue;
        }
        let mut search = after;
        while let Some(rel) = text[search..].find('<') {
            let close = search + rel;
            search = close + 1;
            if !starts_with_ci(text, close, "</script") {
                continue;
            }
            let mut end = close + 8;
            for c in text[end..].chars() {
                if !is_js_space(c) {
                    break;
                }
                end += c.len_utf8();
            }
            if bytes.get(end) == Some(&b'>') {
                out.push((start, end + 1));
                from = end + 1;
                continue 'outer;
            }
        }
        // 这个开头之后再没有能闭合的 `</script>`，更靠后的开头也不会有。
        break;
    }
    out
}

/// 一段（`<script>` 之外）的去重。
fn dedup_chunk(chunk: &str, link: &dyn Fn(&str) -> String, out: &mut String) {
    if !chunk.contains(OPEN) {
        out.push_str(chunk);
        return;
    }
    let mut i = 0;
    loop {
        let Some(start) = chunk[i..].find(OPEN).map(|p| p + i) else {
            break;
        };
        let body = start + OPEN.len();
        let Some(end) = chunk[body..].find(CLOSE).map(|p| p + body) else {
            break;
        };
        let css = &chunk[body..end];
        // 块里又出现一个 `<style>`（畸形 / 嵌套）：不动它，从下一个开头继续找。
        if css.encode_utf16().count() < MIN_CHARS || css.contains(OPEN) {
            out.push_str(&chunk[i..body]);
            i = body;
            continue;
        }
        out.push_str(&chunk[i..start]);
        out.push_str(&link(css));
        i = end + CLOSE.len();
    }
    out.push_str(&chunk[i..]);
}

/// 把够大的无属性 `<style>` 块换成 [link] 给出的引用（没有可换的原样借出）。
pub fn dedup_styles_with<'h>(html: &'h str, link: &dyn Fn(&str) -> String) -> Cow<'h, str> {
    if !html.contains(OPEN) {
        return Cow::Borrowed(html);
    }
    let mut out = String::with_capacity(html.len());
    let mut last = 0;
    for (s, e) in script_blocks(html) {
        dedup_chunk(&html[last..s], link, &mut out);
        out.push_str(&html[s..e]);
        last = e;
    }
    dedup_chunk(&html[last..], link, &mut out);
    Cow::Owned(out)
}

/// 规范引用行（冻结）：`<link rel="stylesheet" href="_fushi_style_<sha1(css 的 UTF-8)>.css">`。
pub fn style_link(css: &str) -> String {
    let mut h = Sha1::new();
    h.update(css.as_bytes());
    let mut name = String::with_capacity(40);
    for b in h.finalize() {
        name.push_str(&format!("{b:02x}"));
    }
    format!("<link rel=\"stylesheet\" href=\"_fushi_style_{name}.css\">")
}

/// Dart `srsDedupStyles(html).html`。
pub fn dedup_styles(html: &str) -> Cow<'_, str> {
    dedup_styles_with(html, &style_link)
}

/// 两个字段文本按去重规范形是否相同：内联样式与它的引用行视为同一内容。
pub fn same_field_text(a: &str, b: &str) -> bool {
    if a == b {
        return true;
    }
    if !a.contains(OPEN) && !b.contains(OPEN) {
        return false;
    }
    dedup_styles(a) == dedup_styles(b)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn script_scan_follows_js_semantics() {
        assert_eq!(script_blocks("a<SCRIPT x>b</script \n>c"), vec![(1, 23)]);
        // `\b`：<scripts 不是 script 标签。
        assert!(script_blocks("<scripts></script>").is_empty());
        assert!(script_blocks("<script>no end").is_empty());
        assert_eq!(script_blocks("<script></script><script></script>").len(), 2);
    }

    #[test]
    fn style_link_and_inline_are_the_same_text() {
        let css = "x".repeat(600);
        let inline = format!("<style>{css}</style>body");
        let linked = format!("{}body", style_link(&css));
        assert!(same_field_text(&inline, &linked));
        assert!(!same_field_text("a", "b"));
        // 不到门槛的样式不换。
        let small = format!("<style>{}</style>", "x".repeat(511));
        assert_eq!(dedup_styles(&small), small);
    }
}
