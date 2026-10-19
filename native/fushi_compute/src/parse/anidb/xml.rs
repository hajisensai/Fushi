//! `package:xml` 6.6 事件语法（`XmlEventParser`）的逐位复刻，作用在 UTF-16 码元上。
//!
//! 只服务 AniDB 两条解析链路（标题包流式事件 / 单部 anime XML 的 DOM），所以照抄的是
//! 那个包的**行为**（包括它的宽松之处），而不是 XML 规范：
//! - 文本是到下一个 `<` 为止的任意字符；属性值不做空白规范化；换行不做规范化。
//! - 实体解码 = `XmlDefaultEntityMapping.xml()`：五个命名实体 + 十 / 十六进制字符引用
//!   （值域 0..=0x10FFFF，含孤立代理），解不出的 `&` 原样保留；找 `;` 的规则见 [decode_entities]。
//! - 名字字符按码点（`pattern(..., unicode: true)`），空白按码元（petitparser `whitespace()`，
//!   与 Dart `trim()` 同集合）。
//! - 失败只在「这一处所有备选都不成立」时发生；失败信息按 petitparser 的 farthest 规则挑，
//!   文案尽量贴近，但不保证与 petitparser 一字不差（只用于异常的 cause 文本）。

use crate::parse::title_score::{is_trim_whitespace, push_rune};

/// 解析失败：位置（码元下标）+ 文案。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Fail {
    pub pos: usize,
    pub msg: &'static str,
}

/// petitparser `selectFarthest`：位置相同取后者。
fn farthest(a: Fail, b: Fail) -> Fail {
    if a.pos <= b.pos {
        b
    } else {
        a
    }
}

type R<T> = Result<T, Fail>;

/// 半开区间 `[start, end)`（码元下标）。
pub type Span = (usize, usize);

#[derive(Clone, Copy, Debug)]
pub struct RawAttr {
    pub name: Span,
    /// 引号内的原始值（未解码）。
    pub value: Span,
}

#[derive(Clone, Debug)]
pub enum Event {
    /// 原始文本（未解码）。
    Text(Span),
    Start {
        name: Span,
        /// `attrs` 向量里的区间。
        attrs: (usize, usize),
        self_closing: bool,
    },
    End(Span),
    Comment,
    CData(Span),
    Declaration,
    Processing,
    Doctype,
}

fn at(buf: &[u16], pos: usize, lit: &str) -> bool {
    let bytes = lit.as_bytes();
    if pos + bytes.len() > buf.len() {
        return false;
    }
    bytes
        .iter()
        .enumerate()
        .all(|(i, &b)| buf[pos + i] == u16::from(b))
}

fn expect(buf: &[u16], pos: usize, lit: &str, msg: &'static str) -> R<usize> {
    if at(buf, pos, lit) {
        Ok(pos + lit.len())
    } else {
        Err(Fail { pos, msg })
    }
}

/// 第一次出现 [lit] 的位置（从 [from] 起）。
fn find(buf: &[u16], from: usize, lit: &str) -> Option<usize> {
    let n = lit.len();
    if n == 0 || buf.len() < n {
        return None;
    }
    let first = u16::from(lit.as_bytes()[0]);
    let mut i = from;
    while i + n <= buf.len() {
        if buf[i] == first && at(buf, i, lit) {
            return Some(i);
        }
        i += 1;
    }
    None
}

fn find_unit(buf: &[u16], from: usize, unit: u16) -> Option<usize> {
    buf.get(from..)?
        .iter()
        .position(|&u| u == unit)
        .map(|i| from + i)
}

/// 在 [pos] 处读一个码点（`unicode: true` 的 pattern 语义）。
fn code_point_at(buf: &[u16], pos: usize) -> Option<(u32, usize)> {
    let unit = u32::from(*buf.get(pos)?);
    if (0xD800..=0xDBFF).contains(&unit) && pos + 1 < buf.len() {
        let low = u32::from(buf[pos + 1]);
        if (0xDC00..=0xDFFF).contains(&low) {
            return Some((0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00), 2));
        }
    }
    Some((unit, 1))
}

fn is_name_start(cp: u32) -> bool {
    matches!(cp,
        0x3A | 0x41..=0x5A | 0x5F | 0x61..=0x7A
        | 0xC0..=0xD6 | 0xD8..=0xF6 | 0xF8..=0x2FF
        | 0x370..=0x37D | 0x37F..=0x1FFF | 0x200C..=0x200D
        | 0x2070..=0x218F | 0x2C00..=0x2FEF | 0x3001..=0xD7FF
        | 0xF900..=0xFDCF | 0xFDF0..=0xFFFD | 0x10000..=0xEFFFF)
}

fn is_name_char(cp: u32) -> bool {
    is_name_start(cp)
        || matches!(cp, 0x2D | 0x2E | 0x30..=0x39 | 0xB7 | 0x300..=0x36F | 0x203F..=0x2040)
}

fn name_token(buf: &[u16], pos: usize) -> R<usize> {
    match code_point_at(buf, pos) {
        Some((cp, width)) if is_name_start(cp) => {
            let mut p = pos + width;
            while let Some((cp, width)) = code_point_at(buf, p) {
                if !is_name_char(cp) {
                    break;
                }
                p += width;
            }
            Ok(p)
        }
        _ => Err(Fail {
            pos,
            msg: "name expected",
        }),
    }
}

fn space_optional(buf: &[u16], mut pos: usize) -> usize {
    while pos < buf.len() && is_trim_whitespace(buf[pos]) {
        pos += 1;
    }
    pos
}

fn space(buf: &[u16], pos: usize) -> R<usize> {
    let end = space_optional(buf, pos);
    if end == pos {
        Err(Fail {
            pos,
            msg: "whitespace expected",
        })
    } else {
        Ok(end)
    }
}

/// `attributeValue`：双引号 | 单引号 | 不带引号的名字。返回（值区间, 结束位置）。
fn attribute_value(buf: &[u16], pos: usize) -> R<(Span, usize)> {
    let quoted = |quote: u16, lit: &'static str| -> R<(Span, usize)> {
        let start = expect(
            buf,
            pos,
            lit,
            if quote == 0x22 {
                "'\"' expected"
            } else {
                "\"'\" expected"
            },
        )?;
        let end = find_unit(buf, start, quote).unwrap_or(buf.len());
        let close = expect(
            buf,
            end,
            lit,
            if quote == 0x22 {
                "'\"' expected"
            } else {
                "\"'\" expected"
            },
        )?;
        Ok(((start, end), close))
    };
    let double = quoted(0x22, "\"");
    if double.is_ok() {
        return double;
    }
    let single = quoted(0x27, "'");
    if single.is_ok() {
        return single;
    }
    match name_token(buf, pos) {
        Ok(end) => Ok(((pos, end), end)),
        // toChoiceParser 默认 selectLast。
        Err(fail) => Err(fail),
    }
}

/// `attributes`：`(space name (spaceOptional '=' spaceOptional value)?)*`。
fn attributes(buf: &[u16], mut pos: usize, out: &mut Vec<RawAttr>) -> usize {
    loop {
        let Ok(name_start) = space(buf, pos) else {
            return pos;
        };
        let Ok(name_end) = name_token(buf, name_start) else {
            return pos;
        };
        let assignment = (|| -> R<(Span, usize)> {
            let p = space_optional(buf, name_end);
            let p = expect(buf, p, "=", "\"=\" expected")?;
            let p = space_optional(buf, p);
            attribute_value(buf, p)
        })();
        match assignment {
            Ok((value, end)) => {
                out.push(RawAttr {
                    name: (name_start, name_end),
                    value,
                });
                pos = end;
            }
            Err(_) => {
                out.push(RawAttr {
                    name: (name_start, name_end),
                    value: (name_end, name_end),
                });
                pos = name_end;
            }
        }
    }
}

fn start_element(buf: &[u16], pos: usize, attrs: &mut Vec<RawAttr>) -> R<(Event, usize)> {
    let p = expect(buf, pos, "<", "\"<\" expected")?;
    let name_end = name_token(buf, p)?;
    let first_attr = attrs.len();
    let p = attributes(buf, name_end, attrs);
    let p = space_optional(buf, p);
    let (self_closing, end) = if at(buf, p, ">") {
        (false, p + 1)
    } else if at(buf, p, "/>") {
        (true, p + 2)
    } else {
        attrs.truncate(first_attr);
        // selectFirst：报 `>` 的失败。
        return Err(Fail {
            pos: p,
            msg: "\">\" expected",
        });
    };
    Ok((
        Event::Start {
            name: (p_name_start(pos), name_end),
            attrs: (first_attr, attrs.len()),
            self_closing,
        },
        end,
    ))
}

#[inline]
fn p_name_start(tag_start: usize) -> usize {
    tag_start + 1
}

fn end_element(buf: &[u16], pos: usize) -> R<(Event, usize)> {
    let p = expect(buf, pos, "</", "\"</\" expected")?;
    let name_end = name_token(buf, p)?;
    let q = space_optional(buf, name_end);
    let end = expect(buf, q, ">", "\">\" expected")?;
    Ok((Event::End((p, name_end)), end))
}

fn lazy_until(buf: &[u16], from: usize, close: &str, msg: &'static str) -> R<(usize, usize)> {
    match find(buf, from, close) {
        Some(index) => Ok((index, index + close.len())),
        None => Err(Fail {
            pos: buf.len(),
            msg,
        }),
    }
}

fn comment(buf: &[u16], pos: usize) -> R<(Event, usize)> {
    let p = expect(buf, pos, "<!--", "\"<!--\" expected")?;
    let (_, end) = lazy_until(buf, p, "-->", "\"-->\" expected")?;
    Ok((Event::Comment, end))
}

fn cdata(buf: &[u16], pos: usize) -> R<(Event, usize)> {
    let p = expect(buf, pos, "<![CDATA[", "\"<![CDATA[\" expected")?;
    let (index, end) = lazy_until(buf, p, "]]>", "\"]]>\" expected")?;
    Ok((Event::CData((p, index)), end))
}

fn declaration(buf: &[u16], pos: usize, scratch: &mut Vec<RawAttr>) -> R<(Event, usize)> {
    let p = expect(buf, pos, "<?xml", "\"<?xml\" expected")?;
    let mark = scratch.len();
    let p = attributes(buf, p, scratch);
    scratch.truncate(mark);
    let p = space_optional(buf, p);
    let end = expect(buf, p, "?>", "\"?>\" expected")?;
    Ok((Event::Declaration, end))
}

fn processing_at(buf: &[u16], pos: usize) -> R<usize> {
    let p = expect(buf, pos, "<?", "\"<?\" expected")?;
    let name_end = name_token(buf, p)?;
    let after = match space(buf, name_end) {
        Ok(s) => match find(buf, s, "?>") {
            Some(index) => index,
            None => name_end,
        },
        Err(_) => name_end,
    };
    expect(buf, after, "?>", "\"?>\" expected")
}

fn processing(buf: &[u16], pos: usize) -> R<(Event, usize)> {
    processing_at(buf, pos).map(|end| (Event::Processing, end))
}

fn comment_at(buf: &[u16], pos: usize) -> R<usize> {
    comment(buf, pos).map(|(_, end)| end)
}

/// `doctypeElementDecl` 等：`<!KEYWORD (name | attributeValue | any)*lazy('>') '>'`。
fn doctype_decl(buf: &[u16], pos: usize, keyword: &str) -> R<usize> {
    let mut p = expect(buf, pos, keyword, "declaration expected")?;
    loop {
        if at(buf, p, ">") {
            return Ok(p + 1);
        }
        if p >= buf.len() {
            return Err(Fail {
                pos: p,
                msg: "\">\" expected",
            });
        }
        if let Ok(end) = name_token(buf, p) {
            p = end;
        } else if let Ok((_, end)) = attribute_value(buf, p) {
            p = end;
        } else {
            p += 1;
        }
    }
}

fn doctype_int_subset(buf: &[u16], pos: usize) -> R<usize> {
    let mut p = expect(buf, pos, "[", "\"[\" expected")?;
    loop {
        if at(buf, p, "]") {
            return Ok(p + 1);
        }
        if p >= buf.len() {
            return Err(Fail {
                pos: p,
                msg: "\"]\" expected",
            });
        }
        let step = doctype_decl(buf, p, "<!ELEMENT")
            .or_else(|_| doctype_decl(buf, p, "<!ATTLIST"))
            .or_else(|_| doctype_decl(buf, p, "<!ENTITY"))
            .or_else(|_| doctype_decl(buf, p, "<!NOTATION"))
            .or_else(|_| processing_at(buf, p))
            .or_else(|_| comment_at(buf, p))
            .or_else(|_| {
                // doctypeReference: '%' name ';'
                let q = expect(buf, p, "%", "\"%\" expected")?;
                let q = name_token(buf, q)?;
                expect(buf, q, ";", "\";\" expected")
            });
        p = step.unwrap_or(p + 1);
    }
}

fn doctype_external_id(buf: &[u16], pos: usize) -> R<usize> {
    if let Ok(p) = expect(buf, pos, "SYSTEM", "\"SYSTEM\" expected") {
        let p = space(buf, p)?;
        return attribute_value(buf, p).map(|(_, end)| end);
    }
    let p = expect(buf, pos, "PUBLIC", "\"PUBLIC\" expected")?;
    let p = space(buf, p)?;
    let (_, p) = attribute_value(buf, p)?;
    let p = space(buf, p)?;
    attribute_value(buf, p).map(|(_, end)| end)
}

fn doctype(buf: &[u16], pos: usize) -> R<(Event, usize)> {
    let p = expect(buf, pos, "<!DOCTYPE", "\"<!DOCTYPE\" expected")?;
    let p = space(buf, p)?;
    let mut p = name_token(buf, p)?;
    if let Ok(s) = space(buf, p) {
        if let Ok(end) = doctype_external_id(buf, s) {
            p = end;
        }
    }
    p = space_optional(buf, p);
    if let Ok(end) = doctype_int_subset(buf, p) {
        p = end;
    }
    p = space_optional(buf, p);
    let end = expect(buf, p, ">", "\">\" expected")?;
    Ok((Event::Doctype, end))
}

/// 解析结果。
pub enum Step {
    Event(Event, usize),
    /// 文本延伸到缓冲尾、还没看到 `<`：流式模式下等更多数据。
    NeedMore,
    Fail(Fail),
}

/// 在 [pos] 解析一个事件（`XmlEventParser.event` 的有序选择）。[eof] 只影响「文本延伸到
/// 缓冲尾」的判定：流式模式下要等下一块，把同一段文本合成一个事件（实体不会被块边界切开）。
pub fn parse_event(buf: &[u16], pos: usize, eof: bool, attrs: &mut Vec<RawAttr>) -> Step {
    // characterData：到下一个 '<'，至少 1 个码元。
    let text_fail = match find_unit(buf, pos, 0x3C) {
        Some(index) if index > pos => return Step::Event(Event::Text((pos, index)), index),
        Some(_) => Fail {
            pos,
            msg: "Unable to parse character data.",
        },
        None => {
            if pos < buf.len() {
                if !eof {
                    return Step::NeedMore;
                }
                return Step::Event(Event::Text((pos, buf.len())), buf.len());
            }
            Fail {
                pos,
                msg: "Unable to parse character data.",
            }
        }
    };
    let mut fail = text_fail;
    macro_rules! attempt {
        ($e:expr) => {
            match $e {
                Ok((event, end)) => return Step::Event(event, end),
                Err(f) => fail = farthest(fail, f),
            }
        };
    }
    attempt!(start_element(buf, pos, attrs));
    attempt!(end_element(buf, pos));
    attempt!(comment(buf, pos));
    attempt!(cdata(buf, pos));
    attempt!(declaration(buf, pos, attrs));
    attempt!(processing(buf, pos));
    attempt!(doctype(buf, pos));
    Step::Fail(fail)
}

/// `XmlEntityMapping.decode` + `XmlDefaultEntityMapping.xml().decodeEntity`。
pub fn decode_entities(input: &[u16]) -> Vec<u16> {
    const AMP: u16 = 0x26;
    const SEMI: u16 = 0x3B;
    let Some(mut start) = input.iter().position(|&u| u == AMP) else {
        return input.to_vec();
    };
    let mut out: Vec<u16> = Vec::with_capacity(input.len());
    out.extend_from_slice(&input[..start]);
    loop {
        let index = input[start + 1..]
            .iter()
            .position(|&u| u == SEMI)
            .map(|i| start + 1 + i);
        match index {
            Some(index) if start + 1 < index => match decode_entity(&input[start + 1..index]) {
                Some(value) => {
                    push_rune(&mut out, value);
                    start = index + 1;
                }
                None => {
                    out.push(AMP);
                    start += 1;
                }
            },
            _ => {
                out.push(AMP);
                start += 1;
            }
        }
        match input[start..].iter().position(|&u| u == AMP) {
            None => {
                out.extend_from_slice(&input[start..]);
                break;
            }
            Some(offset) => {
                out.extend_from_slice(&input[start..start + offset]);
                start += offset;
            }
        }
    }
    out
}

fn decode_entity(entity: &[u16]) -> Option<u32> {
    let eq = |s: &str| entity.len() == s.len() && at(entity, 0, s);
    if entity.len() > 1 && entity[0] == u16::from(b'#') {
        let value =
            if entity.len() > 2 && (entity[1] == u16::from(b'x') || entity[1] == u16::from(b'X')) {
                dart_int_try_parse(&entity[2..], Some(16))
            } else {
                dart_int_try_parse(&entity[1..], Some(10))
            }?;
        if !(0..=0x10FFFF).contains(&value) {
            return None;
        }
        return Some(value as u32);
    }
    if eq("amp") {
        Some(0x26)
    } else if eq("apos") {
        Some(0x27)
    } else if eq("gt") {
        Some(0x3E)
    } else if eq("lt") {
        Some(0x3C)
    } else if eq("quot") {
        Some(0x22)
    } else {
        None
    }
}

/// Dart VM `int.tryParse(source, radix: radix)`（radix 只支持 `None` / 10 / 16）：
/// 先去掉 `trim()` 空白；可带一个 `+` / `-`；`radix == None` 时 `0x` / `0X` 前缀走十六进制
/// （正数可到 u64 上限并按 64 位回绕，与 VM 一致）；只认 ASCII 数字；越出 i64 返回 `None`。
pub fn dart_int_try_parse(source: &[u16], radix: Option<u32>) -> Option<i64> {
    let mut start = 0;
    let mut end = source.len();
    while start < end && is_trim_whitespace(source[start]) {
        start += 1;
    }
    while end > start && is_trim_whitespace(source[end - 1]) {
        end -= 1;
    }
    if start == end {
        return None;
    }
    let mut negative = false;
    let first = source[start];
    if first == u16::from(b'+') || first == u16::from(b'-') {
        negative = first == u16::from(b'-');
        start += 1;
        if start == end {
            return None;
        }
    }
    let mut base = radix.unwrap_or(10);
    let mut allow_u64 = false;
    if radix.is_none() && source[start] == u16::from(b'0') {
        start += 1;
        if start == end {
            return Some(0);
        }
        if source[start] | 0x20 == u16::from(b'x') {
            start += 1;
            if start == end {
                return None;
            }
            base = 16;
            allow_u64 = !negative;
        }
    }
    let mut magnitude: u128 = 0;
    for &unit in &source[start..end] {
        let digit = match unit {
            0x30..=0x39 => u32::from(unit - 0x30),
            0x41..=0x5A if base > 10 => u32::from(unit - 0x41) + 10,
            0x61..=0x7A if base > 10 => u32::from(unit - 0x61) + 10,
            _ => return None,
        };
        if digit >= base {
            return None;
        }
        magnitude = magnitude * u128::from(base) + u128::from(digit);
        if magnitude > u128::from(u64::MAX) {
            return None;
        }
    }
    if negative {
        if magnitude > (1u128 << 63) {
            return None;
        }
        return Some((magnitude as i128).wrapping_neg() as i64);
    }
    if magnitude <= i64::MAX as u128 {
        return Some(magnitude as i64);
    }
    if allow_u64 {
        return Some(magnitude as u64 as i64);
    }
    None
}

/// 限定名的本地名：`indexOf(':') > 0` 时取其后，否则整个名字（`XmlNamed.localName`）。
pub fn local_name(name: &[u16]) -> &[u16] {
    match name.iter().position(|&u| u == 0x3A) {
        Some(index) if index > 0 => &name[index + 1..],
        _ => name,
    }
}

/// 限定名的前缀（`XmlNamed.namespacePrefix`）。
pub fn name_prefix(name: &[u16]) -> Option<&[u16]> {
    match name.iter().position(|&u| u == 0x3A) {
        Some(index) if index > 0 => Some(&name[..index]),
        _ => None,
    }
}

pub fn eq_ascii(units: &[u16], s: &str) -> bool {
    units.len() == s.len() && at(units, 0, s)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn u(s: &str) -> Vec<u16> {
        s.encode_utf16().collect()
    }

    fn dec(s: &str) -> String {
        String::from_utf16(&decode_entities(&u(s))).unwrap()
    }

    #[test]
    fn entities_follow_package_xml() {
        assert_eq!(dec("a &amp; b"), "a & b");
        assert_eq!(dec("&lt;&gt;&quot;&apos;"), "<>\"'");
        assert_eq!(dec("&#65;&#x42;&#X43;"), "ABC");
        assert_eq!(dec("A & B; C"), "A & B; C");
        assert_eq!(dec("&a&amp;"), "&a&");
        assert_eq!(dec("&#;&#x;&;"), "&#;&#x;&;");
        assert_eq!(dec("&#+65;&# 66;"), "AB");
        assert_eq!(dec("&#-1;&#x110000;"), "&#-1;&#x110000;");
        assert_eq!(dec("&nbsp;"), "&nbsp;");
        assert_eq!(decode_entities(&u("&#xD800;")), vec![0xD800]);
    }

    #[test]
    fn int_parse_matches_dart_vm() {
        let p = |s: &str| dart_int_try_parse(&u(s), None);
        assert_eq!(p("12"), Some(12));
        assert_eq!(p(" 12 "), Some(12));
        assert_eq!(p("+12"), Some(12));
        assert_eq!(p("-12"), Some(-12));
        assert_eq!(p("0x10"), Some(16));
        assert_eq!(p("0X10"), Some(16));
        assert_eq!(p("-0x10"), Some(-16));
        assert_eq!(p("\u{a0}12\u{3000}"), Some(12));
        assert_eq!(p("\u{85}12"), Some(12));
        assert_eq!(p("\u{feff}5"), Some(5));
        assert_eq!(p("1_0"), None);
        assert_eq!(p("99999999999999999999"), None);
        assert_eq!(p("9223372036854775807"), Some(i64::MAX));
        assert_eq!(p("9223372036854775808"), None);
        assert_eq!(p("-9223372036854775808"), Some(i64::MIN));
        assert_eq!(p("0xFFFFFFFFFFFFFFFF"), Some(-1));
        assert_eq!(p("0x1FFFFFFFFFFFFFFFF"), None);
        assert_eq!(p("-0xFFFFFFFFFFFFFFFF"), None);
        assert_eq!(p("-0x8000000000000000"), Some(i64::MIN));
        assert_eq!(p("0x8000000000000000"), Some(i64::MIN));
        assert_eq!(p("0x 10"), None);
        assert_eq!(p("00012"), Some(12));
        assert_eq!(p("0x00000000000000000000010"), Some(16));
        assert_eq!(p("1e3"), None);
        assert_eq!(p("- 12"), None);
        assert_eq!(p("０１"), None);
        assert_eq!(p(""), None);
        assert_eq!(p(" "), None);
        assert_eq!(p("0x"), None);
        assert_eq!(p("+"), None);
        assert_eq!(p("0"), Some(0));
        assert_eq!(dart_int_try_parse(&u("0x10"), Some(16)), None);
        assert_eq!(dart_int_try_parse(&u("ff"), Some(16)), Some(255));
        assert_eq!(dart_int_try_parse(&u("12"), Some(16)), Some(18));
    }

    fn events(s: &str) -> Vec<String> {
        let buf = u(s);
        let mut attrs = Vec::new();
        let mut pos = 0;
        let mut out = Vec::new();
        while pos < buf.len() {
            match parse_event(&buf, pos, true, &mut attrs) {
                Step::Event(e, end) => {
                    out.push(match e {
                        Event::Text(_) => "text".to_string(),
                        Event::Start {
                            self_closing,
                            attrs: (a, b),
                            ..
                        } => {
                            format!("start{}{}", b - a, if self_closing { "/" } else { "" })
                        }
                        Event::End(_) => "end".into(),
                        Event::Comment => "comment".into(),
                        Event::CData(_) => "cdata".into(),
                        Event::Declaration => "decl".into(),
                        Event::Processing => "pi".into(),
                        Event::Doctype => "doctype".into(),
                    });
                    pos = end;
                }
                Step::NeedMore => unreachable!(),
                Step::Fail(f) => {
                    out.push(format!("fail@{}", f.pos));
                    break;
                }
            }
        }
        out
    }

    #[test]
    fn grammar_samples() {
        assert_eq!(
            events("<?xml version=\"1.0\"?><a b='1' c d=e><!--x--><![CDATA[<]]></a>"),
            vec!["decl", "start3", "comment", "cdata", "end"]
        );
        assert_eq!(events("<a/><b />"), vec!["start0/", "start0/"]);
        assert_eq!(events("<?xml-stylesheet href='x'?>"), vec!["pi"]);
        assert_eq!(
            events("<!DOCTYPE a [<!ENTITY x \"]>\">]><a/>"),
            vec!["doctype", "start0/"]
        );
        assert_eq!(
            events("<!DOCTYPE a SYSTEM \"x.dtd\"><a/>"),
            vec!["doctype", "start0/"]
        );
        assert_eq!(events("<a b=\"1\"c=\"2\">"), vec!["fail@8"]);
        assert_eq!(events("<!doctype a>"), vec!["fail@1"]);
        assert_eq!(events("x<1>"), vec!["text", "fail@2"]);
    }
}
