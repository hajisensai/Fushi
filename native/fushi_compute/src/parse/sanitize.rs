//! `ffc_parse_sanitize_*`：阅读器章节 HTML / 书内 CSS 的下发前清洗链。
//!
//! 原实现是 `fushi/lib/src/reader/reader_resource_sanitizer.dart`（Dart 正则 +
//! `replaceAllMapped`），在首屏、翻章、每次样式变更时于 UI isolate 上跑。这里是它的**唯一**
//! 运行时实现，输出与旧实现逐字节一致（用旧实现对全部真书章节 / CSS 冻结的哈希向量验过，
//! 见 `fushi/test/reader/reader_resource_sanitizer_native_test.dart` 的摘要用例）。
//!
//! ## 整条链一次过界
//! [sanitize_chapter] 按 `steps` 依次跑（顺序固定，与旧 `_buildSanitizedChapterHtmlBytes` 一致）：
//! 1. UTF-8 宽松解码（= Dart `utf8.decode(allowMalformed: true)`，非法序列按
//!    WHATWG「最大子段」规则各换一个 U+FFFD，开头的一个 BOM 去掉——Dart 解码器就是这样）；
//! 2. [STEP_XHTML] 自闭合非 void 元素展开成成对标签（BUG-079 / BUG-737）；
//! 3. [STEP_STRIP_IMAGE_LOADING] 去掉正文 `<img>` 的 `loading` 属性（插图一律 eager）；
//! 4. [STEP_BODY_IMAGES] 合并前导插图插到 `<body …>` 之后（TODO-1174）；
//! 5. [STEP_READER_HEAD] 阅读器 head 注入（`<head>` 后 / `</head>` 前）。
//!
//! ## 与 Dart 正则的等价性
//! 旧正则都是**非 unicode 模式**（按 UTF-16 码元匹配）。这里按 UTF-8 字节扫描，等价的理由：
//! - 所有决定匹配边界的字符（`<` `>` `/` `"` `'` `=` `:` `;` `{` `}` 与 ASCII 字母数字）都是
//!   ASCII，在两种编码里都是单个单元，且 UTF-8 多字节序列的每个字节都 ≥ 0x80，不会被误认成它们；
//!   取反字符类（`[^>"']` 等）吃掉一个非 ASCII 字符的全部码元 ⇔ 吃掉它的全部字节。
//! - `caseSensitive: false` 在非 unicode 模式下按 ES Canonicalize：非 ASCII 字符永远不会折叠到
//!   ASCII（`ſ`/`ı`/`K` 不匹配 `s`/`i`/`k`），所以只需 ASCII 大小写不敏感比较。
//! - `\b` 的单词字符在非 unicode 模式下只有 `[A-Za-z0-9_]`。
//! - `\s` 是 JS 空白集合（[js_space_len]），`String.trim()` 是 Dart 空白集合（多一个 U+0085，
//!   [is_dart_trim_space]）；多行 `^` 的行终止符是 `\n` `\r` U+2028 U+2029。这些都是 BMP 单码元，
//!   按码点判与按码元判一致。
//! - `replaceAllMapped` 的推进规则：匹配成功（含替换结果等于原文的 void 元素 / 跳过的 `<img>`）后
//!   从匹配末尾继续找，失败才前进一个位置。下面每个扫描器都照此推进。
//!
//! 各正则的回溯分析写在对应函数上。

use std::borrow::Cow;

use crate::{guard, hand_over_bytes, status};

/// 自闭合非 void 元素展开成成对标签（旧 `sanitizeXhtml`）。
pub const STEP_XHTML: u32 = 1;
/// 去掉正文 `<img>` 的 `loading` 属性（[strip_image_loading]）。
pub const STEP_STRIP_IMAGE_LOADING: u32 = 2;
/// 合并前导插图插到 `<body>` 后（旧 `injectImagesAfterBodyOpen`；插图串为空时是空操作）。
pub const STEP_BODY_IMAGES: u32 = 4;
/// 阅读器 head 注入（旧 `injectReaderHead`）。
pub const STEP_READER_HEAD: u32 = 8;
const ALL_STEPS: u32 =
    STEP_XHTML | STEP_STRIP_IMAGE_LOADING | STEP_BODY_IMAGES | STEP_READER_HEAD;
/// 输入是 Dart `String` 编出来的 UTF-8（已解码过的文本，不是磁盘字节）：开头的 U+FEFF 是正文
/// 的一部分，不当 BOM 去掉。只给单步 String 入口用；生产路径的磁盘字节不置这一位。
pub const INPUT_IS_TEXT: u32 = 0x100;
const ALL_FLAGS: u32 = ALL_STEPS | INPUT_IS_TEXT;

/// head 注入时 `</head>` 出现在 `<head…>` 结束之前：旧实现在这里 `substring` 抛 RangeError，
/// 调用方（资源拦截）把它当失败处理。原样保留这个失败，不另行「修正」。
#[derive(Debug, PartialEq, Eq)]
pub struct HeadOrderError;

/// HTML5 void 元素（只有它们的 `/>` 在 text/html 里合法）。
const VOID_ELEMENTS: [&[u8]; 15] = [
    b"area", b"base", b"br", b"col", b"embed", b"hr", b"img", b"input", b"keygen", b"link",
    b"meta", b"param", b"source", b"track", b"wbr",
];

#[inline]
fn is_word(b: u8) -> bool {
    b.is_ascii_alphanumeric() || b == b'_'
}

/// `s[i..]` 是否以 ASCII [lit]（小写）开头，ASCII 大小写不敏感。
#[inline]
fn starts_with_ci(s: &[u8], i: usize, lit: &[u8]) -> bool {
    s.len() >= i + lit.len() && s[i..i + lit.len()].eq_ignore_ascii_case(lit)
}

/// 位置 [i] 处的字符若属 JS `\s`，返回其 UTF-8 字节数，否则 0。
///
/// JS `\s` = `[\t\n\v\f\r    -     　﻿]`。
fn js_space_len(s: &[u8], i: usize) -> usize {
    let at = |k: usize| s.get(i + k).copied();
    match s.get(i) {
        Some(0x09..=0x0D) | Some(b' ') => 1,
        Some(0xC2) if at(1) == Some(0xA0) => 2,
        Some(0xE1) if at(1) == Some(0x9A) && at(2) == Some(0x80) => 3,
        Some(0xE2) => match (at(1), at(2)) {
            (Some(0x80), Some(0x80..=0x8A)) => 3,
            (Some(0x80), Some(0xA8 | 0xA9 | 0xAF)) => 3,
            (Some(0x81), Some(0x9F)) => 3,
            _ => 0,
        },
        Some(0xE3) if at(1) == Some(0x80) && at(2) == Some(0x80) => 3,
        Some(0xEF) if at(1) == Some(0xBB) && at(2) == Some(0xBF) => 3,
        _ => 0,
    }
}

/// 跳过从 [i] 起的连续 JS 空白，返回第一个非空白位置。
fn skip_js_space(s: &[u8], mut i: usize) -> usize {
    loop {
        let n = js_space_len(s, i);
        if n == 0 {
            return i;
        }
        i += n;
    }
}

/// Dart `String.trim()` 的空白集合：9–13、0x20、0x85、0xA0、0x1680、0x2000–0x200A、
/// 0x2028、0x2029、0x202F、0x205F、0x3000、0xFEFF。
fn is_dart_trim_space(c: char) -> bool {
    matches!(
        c as u32,
        0x09..=0x0D
            | 0x20
            | 0x85
            | 0xA0
            | 0x1680
            | 0x2000..=0x200A
            | 0x2028
            | 0x2029
            | 0x202F
            | 0x205F
            | 0x3000
            | 0xFEFF
    )
}

fn dart_trim(bytes: &[u8]) -> &[u8] {
    // 切点都在 ASCII 上，输入是合法 UTF-8。
    match std::str::from_utf8(bytes) {
        Ok(s) => s.trim_matches(is_dart_trim_space).as_bytes(),
        Err(_) => bytes,
    }
}

/// Dart `utf8.decode(bytes, allowMalformed: true)`：去掉开头**一个** UTF-8 BOM（Dart 的
/// `Utf8Decoder` 会跳过它，实测），其余非法序列按 WHATWG 最大子段规则各换一个 U+FFFD——与
/// `String::from_utf8_lossy` 相同（用全部真书 + 模糊用例对拍过）。
fn decode_lossy(input: &[u8], flags: u32) -> Cow<'_, str> {
    if flags & INPUT_IS_TEXT != 0 {
        return String::from_utf8_lossy(input);
    }
    String::from_utf8_lossy(input.strip_prefix(b"\xEF\xBB\xBF").unwrap_or(input))
}

/// 某一步改了内容就取出新缓冲区（借用随调用结束，便于原地替换）。
fn changed(step: Cow<'_, [u8]>) -> Option<Vec<u8>> {
    match step {
        Cow::Owned(v) => Some(v),
        Cow::Borrowed(_) => None,
    }
}

#[inline]
fn find_byte(s: &[u8], from: usize, b: u8) -> Option<usize> {
    s.get(from..)?.iter().position(|&x| x == b).map(|p| p + from)
}

/// 跳过一个属性 token：`"…"` / `'…'` 整段，或一个非 `>`、非引号的单元。
/// `>` 或未闭合引号返回 None。
#[inline]
fn attr_token_end(s: &[u8], q: usize) -> Option<usize> {
    match s[q] {
        b'"' => find_byte(s, q + 1, b'"').map(|e| e + 1),
        b'\'' => find_byte(s, q + 1, b'\'').map(|e| e + 1),
        b'>' => None,
        _ => Some(q + 1),
    }
}

// ---------------------------------------------------------------------------
// STEP_XHTML
// ---------------------------------------------------------------------------

/// 旧正则 `<([a-zA-Z][a-zA-Z0-9:-]*)\b((?:"[^"]*"|'[^']*'|[^>"'])*?)\s*/\s*>`（不分大小写）
/// 在 `<` 位置 [p] 的匹配：返回 (标签名末尾, 属性末尾, 匹配末尾)。
///
/// 回溯分析：标签名贪婪，失败时逐个缩短，每个长度先要过 `\b`——所以从最长往短试、第一个
/// 后续能匹配上的长度就是正则的结果（下面的循环原样照做）。属性是**惰性**循环：每个位置先试
/// 收尾 `\s*/\s*>`（`/` 不是空白，`\s*` 回溯无用，故等价于「跳空白、`/`、跳空白、`>`」），
/// 不成再吃一个 token；token 三选一由首字符唯一决定（引号只能走引号分支，且 `"[^"]*"` 只有一种
/// 吃法），因此整个属性扫描没有可回溯的分叉，遇 `>` 或未闭合引号即失败。
fn match_self_closing(s: &[u8], p: usize) -> Option<(usize, usize, usize)> {
    let len = s.len();
    if p + 1 >= len || !s[p + 1].is_ascii_alphabetic() {
        return None;
    }
    let mut name_end = p + 2;
    while name_end < len
        && (s[name_end].is_ascii_alphanumeric() || s[name_end] == b':' || s[name_end] == b'-')
    {
        name_end += 1;
    }
    let mut e = name_end;
    while e >= p + 2 {
        let before = is_word(s[e - 1]);
        let after = e < len && is_word(s[e]);
        if before != after {
            if let Some((attrs_end, end)) = scan_lazy_attrs(s, e) {
                return Some((e, attrs_end, end));
            }
        }
        e -= 1;
    }
    None
}

/// 惰性属性循环 + 收尾 `\s*/\s*>`，返回 (属性末尾, 匹配末尾)。
fn scan_lazy_attrs(s: &[u8], start: usize) -> Option<(usize, usize)> {
    let len = s.len();
    let mut q = start;
    loop {
        let j = skip_js_space(s, q);
        if j < len && s[j] == b'/' {
            let k = skip_js_space(s, j + 1);
            if k < len && s[k] == b'>' {
                return Some((q, k + 1));
            }
        }
        if q >= len {
            return None;
        }
        q = attr_token_end(s, q)?;
    }
}

/// 旧 `sanitizeXhtml`：自闭合非 void 元素 `<tag …/>` → `<tag …></tag>`。
pub fn sanitize_xhtml(s: &[u8]) -> Cow<'_, [u8]> {
    let len = s.len();
    let mut out: Option<Vec<u8>> = None;
    let mut copied = 0;
    let mut i = 0;
    while let Some(p) = find_byte(s, i, b'<') {
        match match_self_closing(s, p) {
            Some((name_end, attrs_end, end)) => {
                let tag = &s[p + 1..name_end];
                let is_void = VOID_ELEMENTS.iter().any(|v| tag.eq_ignore_ascii_case(v));
                if !is_void {
                    let buf = out.get_or_insert_with(|| Vec::with_capacity(len + 256));
                    buf.extend_from_slice(&s[copied..p]);
                    buf.push(b'<');
                    buf.extend_from_slice(tag);
                    buf.extend_from_slice(&s[name_end..attrs_end]);
                    buf.extend_from_slice(b"></");
                    buf.extend_from_slice(tag);
                    buf.push(b'>');
                    copied = end;
                }
                i = end;
            }
            None => i = p + 1,
        }
    }
    finish(s, out, copied)
}

fn finish(s: &[u8], out: Option<Vec<u8>>, copied: usize) -> Cow<'_, [u8]> {
    match out {
        Some(mut buf) => {
            buf.extend_from_slice(&s[copied..]);
            Cow::Owned(buf)
        }
        None => Cow::Borrowed(s),
    }
}

// ---------------------------------------------------------------------------
// STEP_STRIP_IMAGE_LOADING
// ---------------------------------------------------------------------------

/// 旧正则 `<img\b((?:"[^"]*"|'[^']*'|[^>"'])*)>`（不分大小写）在 [p] 的匹配：
/// 返回 (属性起点, 属性末尾 = `>` 位置)。
///
/// 回溯分析：属性是贪婪循环，token 无分叉（同上）；循环停下只有两种原因——遇到 `>`（随即匹配
/// 成功）或未闭合引号。后者回溯只能把已吃的 token 吐回，而吐回后的位置都是某个 token 的起点，
/// token 起点不可能是 `>`，所以必然失败。
fn match_img(s: &[u8], p: usize) -> Option<(usize, usize)> {
    let len = s.len();
    if !starts_with_ci(s, p + 1, b"img") {
        return None;
    }
    let a = p + 4;
    if a < len && is_word(s[a]) {
        return None; // `\b`：`g` 是单词字符，后面必须是非单词字符或串尾
    }
    let mut q = a;
    while q < len {
        if s[q] == b'>' {
            return Some((a, q));
        }
        q = attr_token_end(s, q)?;
    }
    None
}

/// 属性串（`match_img` 的组 1，引号都已闭合）里去掉落在引号外的
/// `\s+loading\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>"']+)`（不分大小写）。对应正则
/// `("[^"]*"|'[^']*')|(\s+loading…)` 的 replaceAllMapped：引号串整段先被第一组吃掉原样保留，
/// 属性值里的 `loading=` 字样不会被误删。没有改动时返回 None。
///
/// 回溯分析：`\s+` 贪婪，之后必须是字母 `l`（非空白），回溯无用；同一段空白里更靠后的起点
/// 后面是同一个串，也同样失败，所以一段空白只试一次。`=` 两侧的 `\s*` 同理；值三个分支由首字符
/// 唯一决定。
fn strip_loading_attrs(attrs: &[u8]) -> Option<Vec<u8>> {
    let len = attrs.len();
    let mut out: Option<Vec<u8>> = None;
    let mut copied = 0;
    let mut i = 0;
    while i < len {
        match attrs[i] {
            q @ (b'"' | b'\'') => {
                i = find_byte(attrs, i + 1, q).map_or(i + 1, |e| e + 1);
                continue;
            }
            _ => {}
        }
        if js_space_len(attrs, i) == 0 {
            i += 1;
            continue;
        }
        let name = skip_js_space(attrs, i);
        let mut removed_end = None;
        if starts_with_ci(attrs, name, b"loading") {
            let eq = skip_js_space(attrs, name + 7);
            if attrs.get(eq) == Some(&b'=') {
                let v = skip_js_space(attrs, eq + 1);
                removed_end = match attrs.get(v) {
                    Some(&q @ (b'"' | b'\'')) => find_byte(attrs, v + 1, q).map(|e| e + 1),
                    Some(_) => {
                        let mut e = v;
                        while e < len
                            && js_space_len(attrs, e) == 0
                            && !matches!(attrs[e], b'>' | b'"' | b'\'')
                        {
                            e += 1;
                        }
                        (e > v).then_some(e)
                    }
                    None => None,
                };
            }
        }
        match removed_end {
            Some(end) => {
                let buf = out.get_or_insert_with(|| Vec::with_capacity(len));
                buf.extend_from_slice(&attrs[copied..i]);
                copied = end;
                i = end;
            }
            None => i = name,
        }
    }
    let mut buf = out?;
    buf.extend_from_slice(&attrs[copied..]);
    Some(buf)
}

/// 正文 `<img>` 去掉 `loading` 属性（连原书自带的 `loading="lazy"` 一起），全部插图按浏览器
/// 默认（eager）加载。分页 / 连续 / VN 的章节几何（maxScroll、章首章末落点、跨章判定、VN
/// 屏切分）都要靠每张图的真实尺寸：懒图在离视口远的分页列 / 脱离文档的 VN 源树里永不加载、
/// 保持 0 尺寸，章节被算短，插图还没看完就被判到章末跨章（BUG-3533 志乃と恋）。标签名的
/// 大小写原样保留。
pub fn strip_image_loading(s: &[u8]) -> Cow<'_, [u8]> {
    let len = s.len();
    let mut out: Option<Vec<u8>> = None;
    let mut copied = 0;
    let mut i = 0;
    while let Some(p) = find_byte(s, i, b'<') {
        match match_img(s, p) {
            Some((a, close)) => {
                if let Some(stripped) = strip_loading_attrs(&s[a..close]) {
                    let buf = out.get_or_insert_with(|| Vec::with_capacity(len));
                    buf.extend_from_slice(&s[copied..a]);
                    buf.extend_from_slice(&stripped);
                    buf.push(b'>');
                    copied = close + 1;
                }
                i = close + 1;
            }
            None => i = p + 1,
        }
    }
    finish(s, out, copied)
}

// ---------------------------------------------------------------------------
// STEP_BODY_IMAGES / STEP_READER_HEAD
// ---------------------------------------------------------------------------

/// 旧 `<name[^>]*>`（不分大小写，无 `\b`）的 firstMatch 末尾。第一个 `<name` 之后没有 `>` 时，
/// 更靠后的 `<name` 也不会有，所以只看第一个。
fn first_open_tag_end(s: &[u8], name: &[u8]) -> Option<usize> {
    let mut i = 0;
    while let Some(p) = find_byte(s, i, b'<') {
        if starts_with_ci(s, p + 1, name) {
            return find_byte(s, p + 1 + name.len(), b'>').map(|q| q + 1);
        }
        i = p + 1;
    }
    None
}

/// 旧 `</head\s*>`（不分大小写）的 firstMatch 起点。
fn first_head_close_start(s: &[u8]) -> Option<usize> {
    let mut i = 0;
    while let Some(p) = find_byte(s, i, b'<') {
        if s.get(p + 1) == Some(&b'/') && starts_with_ci(s, p + 2, b"head") {
            let k = skip_js_space(s, p + 6);
            if s.get(k) == Some(&b'>') {
                return Some(p);
            }
        }
        i = p + 1;
    }
    None
}

/// 旧 `injectImagesAfterBodyOpen`：插图串前后各加一个换行，插到 `<body…>` 后；没有就整体前置。
pub fn inject_images_after_body_open<'a>(s: &'a [u8], images: &[u8]) -> Cow<'a, [u8]> {
    if images.is_empty() {
        return Cow::Borrowed(s);
    }
    let at = first_open_tag_end(s, b"body").unwrap_or(0);
    let mut out = Vec::with_capacity(s.len() + images.len() + 2);
    out.extend_from_slice(&s[..at]);
    out.push(b'\n');
    out.extend_from_slice(images);
    out.push(b'\n');
    out.extend_from_slice(&s[at..]);
    Cow::Owned(out)
}

/// 旧 `injectReaderHead`。
pub fn inject_reader_head(
    s: &[u8],
    head_start: &[u8],
    head_end: &[u8],
) -> Result<Vec<u8>, HeadOrderError> {
    let open = first_open_tag_end(s, b"head");
    let close = first_head_close_start(s);
    let mut out = Vec::with_capacity(s.len() + head_start.len() + head_end.len() + 3);
    match (open, close) {
        (Some(open), Some(close)) => {
            if close < open {
                return Err(HeadOrderError);
            }
            out.extend_from_slice(&s[..open]);
            out.push(b'\n');
            out.extend_from_slice(head_start);
            out.extend_from_slice(&s[open..close]);
            out.push(b'\n');
            out.extend_from_slice(head_end);
            out.push(b'\n');
            out.extend_from_slice(&s[close..]);
        }
        (Some(open), None) => {
            out.extend_from_slice(&s[..open]);
            out.push(b'\n');
            out.extend_from_slice(head_start);
            out.push(b'\n');
            out.extend_from_slice(head_end);
            out.extend_from_slice(&s[open..]);
        }
        (None, _) => {
            out.extend_from_slice(head_start);
            out.push(b'\n');
            out.extend_from_slice(head_end);
            out.push(b'\n');
            out.extend_from_slice(s);
        }
    }
    Ok(out)
}

/// 整条章节链（见模块注释）。[input] 是磁盘上的原始字节（置 [INPUT_IS_TEXT] 时是已解码文本）；
/// 其余串已是 UTF-8。
pub fn sanitize_chapter(
    input: &[u8],
    steps: u32,
    images: &[u8],
    head_start: &[u8],
    head_end: &[u8],
) -> Result<Vec<u8>, HeadOrderError> {
    let decoded = decode_lossy(input, steps);
    let mut html: Cow<'_, [u8]> = Cow::Borrowed(decoded.as_bytes());
    if steps & STEP_XHTML != 0 {
        if let Some(v) = changed(sanitize_xhtml(&html)) {
            html = Cow::Owned(v);
        }
    }
    if steps & STEP_STRIP_IMAGE_LOADING != 0 {
        if let Some(v) = changed(strip_image_loading(&html)) {
            html = Cow::Owned(v);
        }
    }
    if steps & STEP_BODY_IMAGES != 0 {
        if let Some(v) = changed(inject_images_after_body_open(&html, images)) {
            html = Cow::Owned(v);
        }
    }
    if steps & STEP_READER_HEAD != 0 {
        return inject_reader_head(&html, head_start, head_end);
    }
    Ok(html.into_owned())
}

// ---------------------------------------------------------------------------
// CSS
// ---------------------------------------------------------------------------

/// 位置 [p] 是否是多行 `^`：串首，或前一字符是 `\n` `\r` U+2028 U+2029。
fn is_line_start(s: &[u8], p: usize) -> bool {
    p == 0
        || matches!(s[p - 1], b'\n' | b'\r')
        || (p >= 3 && s[p - 3] == 0xE2 && s[p - 2] == 0x80 && matches!(s[p - 1], 0xA8 | 0xA9))
}

/// 从 [from] 起下一个行终止符之后的位置（即下一个 `^` 候选）。
fn next_line_start(s: &[u8], from: usize) -> Option<usize> {
    let mut k = from;
    while k < s.len() {
        match s[k] {
            b'\n' | b'\r' => return Some(k + 1),
            0xE2 if s.get(k + 1) == Some(&0x80) && matches!(s.get(k + 2), Some(0xA8 | 0xA9)) => {
                return Some(k + 3)
            }
            _ => k += 1,
        }
    }
    None
}

/// 旧正则 `^([ \t]*)-epub-([^:;{}\r\n]+)[ \t]*:[ \t]*([^;{}\r\n]*)[ \t]*;`（multiLine）在行首
/// [p] 的匹配：返回 (缩进末尾, 属性名区间, 属性值区间, 匹配末尾)。
///
/// 回溯分析：属性名类排除 `:`，贪婪吃到第一个 `:;{}\r\n`；那里必须是 `:`（其后的 `[ \t]*`
/// 已被名字吃光，取空）。缩短名字只会让下一字符变成名字里的非 `:` 字符，或只吐回尾部空格/制表
/// 后再撞上同一个停止符，结果不变，所以捕获就是贪婪的最大段（含尾部空白，后面再 trim）。值同理：
/// `:` 后 `[ \t]*` 贪婪吃掉前导空格/制表，值吃到第一个 `;{}\r\n`，那里必须是 `;`。
#[allow(clippy::type_complexity)]
fn match_epub_property(
    s: &[u8],
    p: usize,
) -> Option<(usize, (usize, usize), (usize, usize), usize)> {
    let len = s.len();
    let mut j = p;
    while j < len && matches!(s[j], b' ' | b'\t') {
        j += 1;
    }
    let indent_end = j;
    if !s[j..].starts_with(b"-epub-") {
        return None;
    }
    j += 6;
    let mut k = j;
    while k < len && !matches!(s[k], b':' | b';' | b'{' | b'}' | b'\r' | b'\n') {
        k += 1;
    }
    if k == j || s.get(k) != Some(&b':') {
        return None;
    }
    let prop = (j, k);
    k += 1;
    while k < len && matches!(s[k], b' ' | b'\t') {
        k += 1;
    }
    let v = k;
    while k < len && !matches!(s[k], b';' | b'{' | b'}' | b'\r' | b'\n') {
        k += 1;
    }
    if s.get(k) != Some(&b';') {
        return None;
    }
    Some((indent_end, prop, (v, k), k + 1))
}

/// 旧 `sanitizeCss`：`-epub-*` 前缀属性换成标准 / `-webkit-` 写法（`writing-mode` 删掉，由阅读器
/// 统一控制）。
pub fn sanitize_css_text(s: &[u8]) -> Cow<'_, [u8]> {
    let mut out: Option<Vec<u8>> = None;
    let mut copied = 0;
    let mut p = 0;
    while p < s.len() {
        if is_line_start(s, p) {
            if let Some((indent_end, (ps, pe), (vs, ve), end)) = match_epub_property(s, p) {
                let indent = &s[p..indent_end];
                let property = dart_trim(&s[ps..pe]);
                let value = dart_trim(&s[vs..ve]);
                let buf = out.get_or_insert_with(|| Vec::with_capacity(s.len() + 256));
                buf.extend_from_slice(&s[copied..p]);
                let decl = |buf: &mut Vec<u8>, prefix: &[u8], name: &[u8], value: &[u8]| {
                    buf.extend_from_slice(indent);
                    buf.extend_from_slice(prefix);
                    buf.extend_from_slice(name);
                    buf.extend_from_slice(b": ");
                    buf.extend_from_slice(value);
                    buf.push(b';');
                };
                match property {
                    b"writing-mode" => {}
                    b"line-break" | b"word-break" | b"hyphens" | b"text-emphasis-style"
                    | b"text-emphasis-color" => {
                        decl(buf, b"-webkit-", property, value);
                        buf.push(b'\n');
                        decl(buf, b"", property, value);
                    }
                    b"text-combine" => {
                        decl(buf, b"", b"-webkit-text-combine", value);
                        buf.push(b'\n');
                        decl(buf, b"", b"text-combine-upright", b"all");
                    }
                    _ => decl(buf, b"", property, value),
                }
                copied = end;
                p = end;
                continue;
            }
        }
        match next_line_start(s, p) {
            Some(next) => p = next,
            None => break,
        }
    }
    finish(s, out, copied)
}

/// 书内 CSS 整条链：宽松解码 + [sanitize_css_text]。[flags] 只认 [INPUT_IS_TEXT]。
pub fn sanitize_css(input: &[u8], flags: u32) -> Vec<u8> {
    let decoded = decode_lossy(input, flags);
    sanitize_css_text(decoded.as_bytes()).into_owned()
}

// ---------------------------------------------------------------------------
// C ABI
// ---------------------------------------------------------------------------

unsafe fn slice_or_empty<'a>(ptr: *const u8, len: usize) -> Option<&'a [u8]> {
    if len == 0 {
        Some(&[])
    } else if ptr.is_null() {
        None
    } else {
        Some(std::slice::from_raw_parts(ptr, len))
    }
}

/// 章节 HTML 整条链。`steps` 是 `STEP_*`（及 [INPUT_IS_TEXT]）位或；输出由本库分配，调用方用 `ffc_free_bytes` 释放。
/// 返回 `BAD_INPUT` 表示 `</head>` 出现在 `<head…>` 结束之前（旧实现在此抛 RangeError）。
///
/// # Safety
/// 各 `(ptr, len)` 在 `len > 0` 时指向可读字节；`out_ptr` / `out_len` 非空可写。
#[no_mangle]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn ffc_parse_sanitize_chapter(
    input: *const u8,
    input_len: usize,
    steps: u32,
    images: *const u8,
    images_len: usize,
    head_start: *const u8,
    head_start_len: usize,
    head_end: *const u8,
    head_end_len: usize,
    out_ptr: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    if out_ptr.is_null() || out_len.is_null() {
        return status::NULL_ARGUMENT;
    }
    let (Some(input), Some(images), Some(head_start), Some(head_end)) = (
        slice_or_empty(input, input_len),
        slice_or_empty(images, images_len),
        slice_or_empty(head_start, head_start_len),
        slice_or_empty(head_end, head_end_len),
    ) else {
        return status::NULL_ARGUMENT;
    };
    if steps & !ALL_FLAGS != 0 {
        return status::INVALID_ARGUMENT;
    }
    guard(|| match sanitize_chapter(input, steps, images, head_start, head_end) {
        Ok(bytes) => {
            hand_over_bytes(bytes, out_ptr, out_len);
            status::OK
        }
        Err(HeadOrderError) => status::BAD_INPUT,
    })
}

/// 书内 CSS 整条链。`flags` 只认 [INPUT_IS_TEXT]；输出由本库分配，调用方用 `ffc_free_bytes`
/// 释放。
///
/// # Safety
/// `len > 0` 时 `input` 指向 `len` 个可读字节；`out_ptr` / `out_len` 非空可写。
#[no_mangle]
pub unsafe extern "C" fn ffc_parse_sanitize_css(
    input: *const u8,
    input_len: usize,
    flags: u32,
    out_ptr: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    if out_ptr.is_null() || out_len.is_null() {
        return status::NULL_ARGUMENT;
    }
    let Some(input) = slice_or_empty(input, input_len) else {
        return status::NULL_ARGUMENT;
    };
    if flags & !INPUT_IS_TEXT != 0 {
        return status::INVALID_ARGUMENT;
    }
    guard(|| {
        hand_over_bytes(sanitize_css(input, flags), out_ptr, out_len);
        status::OK
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    const ALL: u32 = ALL_STEPS;

    fn x(s: &str) -> String {
        String::from_utf8(sanitize_xhtml(s.as_bytes()).into_owned()).unwrap()
    }
    fn strip(s: &str) -> String {
        String::from_utf8(strip_image_loading(s.as_bytes()).into_owned()).unwrap()
    }
    fn css(s: &str) -> String {
        String::from_utf8(sanitize_css(s.as_bytes(), 0)).unwrap()
    }

    #[test]
    fn self_closing_non_void_expands() {
        assert_eq!(x("<a id=\"t\"/>"), "<a id=\"t\"></a>");
        assert_eq!(x("<Script src=\"a.js\" />"), "<Script src=\"a.js\"></Script>");
        assert_eq!(x("<br/><IMG src=a />"), "<br/><IMG src=a />");
        assert_eq!(x("<a href=\"a/>b\"/>"), "<a href=\"a/>b\"></a>");
        assert_eq!(x("<a title=\"open/>"), "<a title=\"open/>");
        // 名字以 `-` 结尾时 `\b` 回退到更短的名字。
        assert_eq!(x("<a- />"), "<a-></a>");
        assert_eq!(x("<ab_c/>"), "<ab_c/>");
        // 全角空格属于 JS `\s`。
        assert_eq!(x("<p\u{3000}/\u{3000}>"), "<p></p>");
        // void 匹配吞掉的范围不再扫描。
        assert_eq!(x("<br title=\"<a/>\"/>"), "<br title=\"<a/>\"/>");
    }

    #[test]
    fn image_loading_stripped() {
        assert_eq!(
            strip("<body><img loading=\"lazy\" src=\"a.png\" alt=\"a\"/></body>"),
            "<body><img src=\"a.png\" alt=\"a\"/></body>"
        );
        assert_eq!(
            strip("<IMG src='a.png' LOADING='lazy' class='x'/>"),
            "<IMG src='a.png' class='x'/>"
        );
        assert_eq!(strip("<img src=\"a.png\" loading=lazy>"), "<img src=\"a.png\">");
        assert_eq!(strip("<img src=a\u{3000}loading = eager>"), "<img src=a>");
        // 引号内的 loading= 字样与 `>` 不误伤；没有前导空白 / 不是独立属性名的不动。
        for kept in [
            "<img alt=\"x loading=lazy>\" src=\"a.png\"/>",
            "<img src=a.png/>",
            "<img xloading=1 data-loading=2>",
            "<img loading>",
            "<image href=\"b.png\" loading=\"lazy\"/>",
            "<iframe loading=\"lazy\"></iframe>",
            "<imgx loading=lazy>",
            "<img alt=\"a",
        ] {
            assert_eq!(strip(kept), kept);
        }
        assert_eq!(
            strip("<img loading=\"lazy\" src=\"a.png\"/><img src=\"b.png\" loading=\"eager\"/>"),
            "<img src=\"a.png\"/><img src=\"b.png\"/>"
        );
    }

    #[test]
    fn css_rewrites() {
        assert_eq!(css("-epub-writing-mode: vertical-rl;"), "");
        assert_eq!(
            css("  -epub-hyphens : auto ;"),
            "  -webkit-hyphens: auto;\n  hyphens: auto;"
        );
        assert_eq!(
            css("-epub-text-combine: horizontal;"),
            "-webkit-text-combine: horizontal;\ntext-combine-upright: all;"
        );
        assert_eq!(css("-epub-a:b;-epub-c:d;"), "a: b;-epub-c:d;");
        assert_eq!(css("x\u{2028}-epub-a:b;"), "x\u{2028}a: b;");
        // Dart trim 认 U+0085，JS `\s` 不认。
        assert_eq!(css("-epub-\u{85}hyphens\u{85}:x;"), "-webkit-hyphens: x;\nhyphens: x;");
    }

    #[test]
    fn head_and_body_injection() {
        let out = sanitize_chapter(b"<html><head></head><body><p/></body></html>", ALL, b"IMG", b"S", b"E")
            .unwrap();
        assert_eq!(
            String::from_utf8(out).unwrap(),
            "<html><head>\nS\nE\n</head><body>\nIMG\n<p></p></body></html>"
        );
        assert_eq!(sanitize_chapter(b"<head </head>", ALL, b"", b"S", b"E"), Err(HeadOrderError));
        let out = sanitize_chapter(b"x", ALL, b"", b"S", b"E").unwrap();
        assert_eq!(out, b"S\nE\nx");
    }

    #[test]
    fn lossy_decode_matches_whatwg() {
        let out = sanitize_chapter(&[0xE3, 0x81, b'<', 0xFF], 0, b"", b"", b"").unwrap();
        assert_eq!(String::from_utf8(out).unwrap(), "\u{FFFD}<\u{FFFD}");
        let out = sanitize_chapter(&[0xEF, 0xBB, 0xBF, b'a'], 0, b"", b"", b"").unwrap();
        assert_eq!(out, b"a");
        let out = sanitize_chapter(&[0xEF, 0xBB, 0xBF, b'a'], INPUT_IS_TEXT, b"", b"", b"").unwrap();
        assert_eq!(out, [0xEF, 0xBB, 0xBF, b'a']);
    }

    #[test]
    fn ffi_entry_points() {
        let mut ptr: *mut u8 = std::ptr::null_mut();
        let mut len = 0usize;
        let input = b"<a/>";
        let rc = unsafe {
            ffc_parse_sanitize_chapter(
                input.as_ptr(), input.len(), STEP_XHTML, std::ptr::null(), 0,
                std::ptr::null(), 0, std::ptr::null(), 0, &mut ptr, &mut len,
            )
        };
        assert_eq!(rc, status::OK);
        assert_eq!(unsafe { std::slice::from_raw_parts(ptr, len) }, b"<a></a>");
        crate::ffc_free_bytes(ptr, len);
        let rc = unsafe {
            ffc_parse_sanitize_chapter(
                input.as_ptr(), input.len(), 16, std::ptr::null(), 0,
                std::ptr::null(), 0, std::ptr::null(), 0, &mut ptr, &mut len,
            )
        };
        assert_eq!(rc, status::INVALID_ARGUMENT);
        let rc = unsafe {
            ffc_parse_sanitize_chapter(
                std::ptr::null(), 3, 0, std::ptr::null(), 0,
                std::ptr::null(), 0, std::ptr::null(), 0, &mut ptr, &mut len,
            )
        };
        assert_eq!(rc, status::NULL_ARGUMENT);
        let rc = unsafe { ffc_parse_sanitize_css(std::ptr::null(), 0, 0, &mut ptr, &mut len) };
        assert_eq!(rc, status::OK);
        assert_eq!(len, 0);
        crate::ffc_free_bytes(ptr, len);
    }
}
