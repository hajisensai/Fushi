//! Bilibili 弹幕 XML：复刻 `package:xml` 6.6.1（petitparser 7.0.2）的
//! `XmlDocument.parse(xml).findAllElements('d')` → `getAttribute('p')` / `innerText`。
//!
//! 不是通用 XML 解析器，而是那套 PEG 文法与校验的逐条翻译，只保留弹幕需要的产物：
//! - 事件文法（`xml_events/parser.dart`）：按 文本 / 开始标签 / 结束标签 / 注释 / CDATA /
//!   XML 声明 / 处理指令 / DOCTYPE 的顺序尝试，第一个成功的胜出（PEG，不回溯进已成功的
//!   子项）；全部失败即整份失败。所有字符判断都在 UTF-16 码元上做，名字字符按码点
//!   （代理对合成，孤立代理按码元值本身判断，与 petitparser `unicode: true` 一致）。
//! - 校验（`XmlAnnotator` 的 `validateNesting` / `validateDocument`，以及节点解码时
//!   元素子节点类型检查）：根层最多一个 XML 声明且必须在任何声明 / DOCTYPE / 根元素之前、
//!   最多一个 DOCTYPE 且在根元素之前、恰好一个根元素；结束标签名逐码元等于最近的开始标签；
//!   元素内出现 XML 声明或 DOCTYPE 失败（元素子节点类型不含这两种）；文档末尾仍有未闭合
//!   元素失败。根层文本（含 BOM、任意非空白）是合法的。
//! - 不做换行规范化、不校验字符合法性（控制字符照常是文本），实体只认 `&amp; &apos; &gt;
//!   &lt; &quot;` 与 `&#…;` / `&#x…;`（`XmlDefaultEntityMapping.xml()`），认不出的原样保留。
//! - `findAllElements('d')`：先序遍历，限定名逐码元等于 `d`（`x:d` 不算）；
//!   `getAttribute('p')`：第一个限定名等于 `p` 的属性；`innerText`：所有后代文本与 CDATA
//!   按文档顺序拼接（注释 / 处理指令不算），所以嵌套的 `<d>` 外层包含内层文本。

use super::danmaku_dart::int_try_parse;

/// 一个 `<d>` 元素：首个 `p` 属性的已解码值（无该属性为 `None`），`innerText` 在
/// [XmlDanmakuDoc::text] 里的区间。
pub struct XmlDanmakuElement {
    pub p: Option<Vec<u16>>,
    pub text_start: usize,
    pub text_end: usize,
}

pub struct XmlDanmakuDoc {
    /// 文档顺序（先序）的 `<d>` 元素。
    pub elements: Vec<XmlDanmakuElement>,
    /// 处在至少一个 `<d>` 内部的全部文本 / CDATA 内容，按文档顺序拼接。
    pub text: Vec<u16>,
}

const LT: u16 = b'<' as u16;
const GT: u16 = b'>' as u16;

struct Cursor<'a> {
    s: &'a [u16],
}

#[inline]
fn is_space(u: u16) -> bool {
    // petitparser `WhitespaceCharPredicate`（逐码元，不合成代理对）。
    super::danmaku_dart::is_whitespace(u)
}

#[inline]
fn is_name_start(cp: u32) -> bool {
    // XmlToken.nameStartChars
    matches!(cp,
        0x3A | 0x41..=0x5A | 0x5F | 0x61..=0x7A
        | 0xC0..=0xD6 | 0xD8..=0xF6 | 0xF8..=0x2FF | 0x370..=0x37D | 0x37F..=0x1FFF
        | 0x200C..=0x200D | 0x2070..=0x218F | 0x2C00..=0x2FEF | 0x3001..=0xD7FF
        | 0xF900..=0xFDCF | 0xFDF0..=0xFFFD | 0x10000..=0xEFFFF)
}

#[inline]
fn is_name_char(cp: u32) -> bool {
    // XmlToken.nameChars = nameStartChars + `-.0-9` + U+B7 + U+300–36F + U+203F–2040
    is_name_start(cp)
        || matches!(cp, 0x2D | 0x2E | 0x30..=0x39 | 0xB7 | 0x300..=0x36F | 0x203F..=0x2040)
}

impl<'a> Cursor<'a> {
    #[inline]
    fn at(&self, p: usize, unit: u16) -> bool {
        p < self.s.len() && self.s[p] == unit
    }

    #[inline]
    fn lit(&self, p: usize, ascii: &[u8]) -> Option<usize> {
        let end = p.checked_add(ascii.len())?;
        if end <= self.s.len() && super::danmaku_dart::units_eq_ascii(&self.s[p..end], ascii) {
            Some(end)
        } else {
            None
        }
    }

    /// 从 [from] 起第一次出现 ASCII 串 [pat] 的位置。
    fn find(&self, from: usize, pat: &[u8]) -> Option<usize> {
        let s = self.s;
        let first = u16::from(pat[0]);
        let mut i = from;
        while i + pat.len() <= s.len() {
            if s[i] == first && super::danmaku_dart::units_eq_ascii(&s[i..i + pat.len()], pat) {
                return Some(i);
            }
            i += 1;
        }
        None
    }

    fn find_unit(&self, from: usize, unit: u16) -> Option<usize> {
        self.s[from.min(self.s.len())..]
            .iter()
            .position(|&u| u == unit)
            .map(|i| i + from)
    }

    /// 码点（unicode 模式）：返回 (码点, 下一位置)。
    #[inline]
    fn code_point(&self, p: usize) -> Option<(u32, usize)> {
        let s = self.s;
        if p >= s.len() {
            return None;
        }
        let unit = u32::from(s[p]);
        if (unit & 0xFC00) == 0xD800 && p + 1 < s.len() {
            let next = u32::from(s[p + 1]);
            if (next & 0xFC00) == 0xDC00 {
                return Some((0x10000 + ((unit & 0x3FF) << 10) + (next & 0x3FF), p + 2));
            }
        }
        Some((unit, p + 1))
    }

    /// `nameToken`：nameStartChar nameChar*。
    fn name(&self, p: usize) -> Option<usize> {
        let (cp, mut q) = self.code_point(p)?;
        if !is_name_start(cp) {
            return None;
        }
        while let Some((cp, next)) = self.code_point(q) {
            if !is_name_char(cp) {
                break;
            }
            q = next;
        }
        Some(q)
    }

    /// `whitespace().plusString()`。
    fn space(&self, p: usize) -> Option<usize> {
        let q = self.space_optional(p);
        if q > p {
            Some(q)
        } else {
            None
        }
    }

    /// `whitespace().starString()`。
    fn space_optional(&self, mut p: usize) -> usize {
        while p < self.s.len() && is_space(self.s[p]) {
            p += 1;
        }
        p
    }

    /// `attributeValue`：双引号 / 单引号（到下一个同种引号，未闭合失败）/ 不带引号的名字。
    /// 返回 (值起点, 值终点, 结束位置)。
    fn attribute_value(&self, p: usize) -> Option<(usize, usize, usize)> {
        for quote in [b'"' as u16, b'\'' as u16] {
            if self.at(p, quote) {
                return match self.find_unit(p + 1, quote) {
                    Some(close) => Some((p + 1, close, close + 1)),
                    None => None,
                };
            }
        }
        let end = self.name(p)?;
        Some((p, end, end))
    }

    /// `attribute`：space nameToken (spaceOptional '=' spaceOptional attributeValue)?
    /// 返回 (名字区间, 值区间, 结束位置)；无赋值时值为空区间。
    fn attribute(&self, p: usize) -> Option<((usize, usize), (usize, usize), usize)> {
        let name_start = self.space(p)?;
        let name_end = self.name(name_start)?;
        let a = self.space_optional(name_end);
        if self.at(a, b'=' as u16) {
            let b = self.space_optional(a + 1);
            if let Some((vs, ve, end)) = self.attribute_value(b) {
                return Some(((name_start, name_end), (vs, ve), end));
            }
        }
        Some(((name_start, name_end), (name_end, name_end), name_end))
    }

    /// `attributes`（attribute*）：返回结束位置与首个名为 `p` 的属性值区间。
    fn attributes(&self, mut p: usize) -> (usize, Option<(usize, usize)>) {
        let mut first_p = None;
        while let Some(((ns, ne), value, end)) = self.attribute(p) {
            if first_p.is_none() && ne - ns == 1 && self.s[ns] == b'p' as u16 {
                first_p = Some(value);
            }
            p = end;
        }
        (p, first_p)
    }
}

/// 一次事件。
enum Event {
    Text(usize, usize),
    Start {
        name: (usize, usize),
        p_attr: Option<(usize, usize)>,
        self_closing: bool,
    },
    End(usize, usize),
    Cdata(usize, usize),
    Declaration,
    Doctype,
    /// 注释与处理指令：不产生文本，也不参与根层校验。
    Other,
}

impl Cursor<'_> {
    fn start_element(&self, p: usize) -> Option<(Event, usize)> {
        if !self.at(p, LT) {
            return None;
        }
        let name_end = self.name(p + 1)?;
        let (after_attrs, p_attr) = self.attributes(name_end);
        let q = self.space_optional(after_attrs);
        let (self_closing, end) = if self.at(q, GT) {
            (false, q + 1)
        } else if let Some(end) = self.lit(q, b"/>") {
            (true, end)
        } else {
            return None;
        };
        Some((
            Event::Start {
                name: (p + 1, name_end),
                p_attr,
                self_closing,
            },
            end,
        ))
    }

    fn end_element(&self, p: usize) -> Option<(Event, usize)> {
        let name_start = self.lit(p, b"</")?;
        let name_end = self.name(name_start)?;
        let q = self.space_optional(name_end);
        if !self.at(q, GT) {
            return None;
        }
        Some((Event::End(name_start, name_end), q + 1))
    }

    fn comment(&self, p: usize) -> Option<usize> {
        let body = self.lit(p, b"<!--")?;
        self.find(body, b"-->").map(|close| close + 3)
    }

    fn cdata(&self, p: usize) -> Option<(Event, usize)> {
        let body = self.lit(p, b"<![CDATA[")?;
        let close = self.find(body, b"]]>")?;
        Some((Event::Cdata(body, close), close + 3))
    }

    fn declaration(&self, p: usize) -> Option<usize> {
        let after = self.lit(p, b"<?xml")?;
        let (after_attrs, _) = self.attributes(after);
        let q = self.space_optional(after_attrs);
        self.lit(q, b"?>")
    }

    /// `processing`：'<?' nameToken (space any*?'?>')? '?>'。
    fn processing(&self, p: usize) -> Option<usize> {
        let after = self.lit(p, b"<?")?;
        let name_end = self.name(after)?;
        let mut q = name_end;
        if let Some(text_start) = self.space(name_end) {
            if let Some(close) = self.find(text_start, b"?>") {
                q = close;
            }
        }
        self.lit(q, b"?>")
    }

    /// `doctype`：'<!DOCTYPE' space name (space externalId)? spaceOptional intSubset?
    /// spaceOptional '>'。
    fn doctype(&self, p: usize) -> Option<usize> {
        let after = self.lit(p, b"<!DOCTYPE")?;
        let name_start = self.space(after)?;
        let mut q = self.name(name_start)?;
        if let Some(id_start) = self.space(q) {
            if let Some(end) = self.external_id(id_start) {
                q = end;
            }
        }
        q = self.space_optional(q);
        if let Some(end) = self.int_subset(q) {
            q = end;
        }
        q = self.space_optional(q);
        if self.at(q, GT) {
            Some(q + 1)
        } else {
            None
        }
    }

    fn external_id(&self, p: usize) -> Option<usize> {
        if let Some(after) = self.lit(p, b"SYSTEM") {
            let v = self.space(after)?;
            return self.attribute_value(v).map(|(_, _, end)| end);
        }
        let after = self.lit(p, b"PUBLIC")?;
        let v1 = self.space(after)?;
        let (_, _, e1) = self.attribute_value(v1)?;
        let v2 = self.space(e1)?;
        self.attribute_value(v2).map(|(_, _, end)| end)
    }

    /// '[' (decl | processing | comment | reference | any)*? ']'（limit 先于每一项检查）。
    fn int_subset(&self, p: usize) -> Option<usize> {
        if !self.at(p, b'[' as u16) {
            return None;
        }
        let mut q = p + 1;
        loop {
            if self.at(q, b']' as u16) {
                return Some(q + 1);
            }
            q = self.int_subset_item(q)?;
        }
    }

    fn int_subset_item(&self, p: usize) -> Option<usize> {
        for keyword in [
            &b"<!ELEMENT"[..],
            &b"<!ATTLIST"[..],
            &b"<!ENTITY"[..],
            &b"<!NOTATION"[..],
        ] {
            if let Some(end) = self.markup_decl(p, keyword) {
                return Some(end);
            }
        }
        if let Some(end) = self.processing(p) {
            return Some(end);
        }
        if let Some(end) = self.comment(p) {
            return Some(end);
        }
        if let Some(end) = self.reference(p) {
            return Some(end);
        }
        if p < self.s.len() {
            Some(p + 1)
        } else {
            None
        }
    }

    /// keyword (nameToken | attributeValue | any)*? '>'。
    fn markup_decl(&self, p: usize, keyword: &[u8]) -> Option<usize> {
        let mut q = self.lit(p, keyword)?;
        loop {
            if self.at(q, GT) {
                return Some(q + 1);
            }
            if let Some(end) = self.name(q) {
                q = end;
            } else if let Some((_, _, end)) = self.attribute_value(q) {
                q = end;
            } else if q < self.s.len() {
                q += 1;
            } else {
                return None;
            }
        }
    }

    fn reference(&self, p: usize) -> Option<usize> {
        if !self.at(p, b'%' as u16) {
            return None;
        }
        let end = self.name(p + 1)?;
        if self.at(end, b';' as u16) {
            Some(end + 1)
        } else {
            None
        }
    }

    /// `event` 选择：返回事件与结束位置；全部失败为 `None`。
    fn event(&self, p: usize) -> Option<(Event, usize)> {
        if self.s[p] != LT {
            let end = self.find_unit(p, LT).unwrap_or(self.s.len());
            return Some((Event::Text(p, end), end));
        }
        if let Some(found) = self.start_element(p) {
            return Some(found);
        }
        if let Some(found) = self.end_element(p) {
            return Some(found);
        }
        if let Some(end) = self.comment(p) {
            return Some((Event::Other, end));
        }
        if let Some(found) = self.cdata(p) {
            return Some(found);
        }
        if let Some(end) = self.declaration(p) {
            return Some((Event::Declaration, end));
        }
        if let Some(end) = self.processing(p) {
            return Some((Event::Other, end));
        }
        if let Some(end) = self.doctype(p) {
            return Some((Event::Doctype, end));
        }
        None
    }
}

/// `XmlDefaultEntityMapping.xml().decode(raw)`，结果追加到 [out]。
pub fn decode_entities(raw: &[u16], out: &mut Vec<u16>) {
    let amp = b'&' as u16;
    let semi = b';' as u16;
    let Some(mut start) = raw.iter().position(|&u| u == amp) else {
        out.extend_from_slice(raw);
        return;
    };
    out.extend_from_slice(&raw[..start]);
    // `indexOf(';', start + 1)` 的缓存：start 单调递增，上次结果仍在 start 之后就复用，
    // 免得一长串没有 ';' 的 '&' 每次都扫到末尾。
    let mut next_semi: Option<usize> = None;
    let mut semi_scanned_from = usize::MAX;
    loop {
        let from = start + 1;
        let index = match next_semi {
            Some(i) if i >= from && semi_scanned_from <= from => Some(i),
            None if semi_scanned_from <= from => None,
            _ => {
                semi_scanned_from = from;
                next_semi = raw[from.min(raw.len())..]
                    .iter()
                    .position(|&u| u == semi)
                    .map(|i| i + from);
                next_semi
            }
        };
        match index {
            Some(index) if start + 1 < index => {
                if decode_entity(&raw[start + 1..index], out) {
                    start = index + 1;
                } else {
                    out.push(amp);
                    start += 1;
                }
            }
            _ => {
                out.push(amp);
                start += 1;
            }
        }
        match raw[start..].iter().position(|&u| u == amp) {
            None => {
                out.extend_from_slice(&raw[start..]);
                return;
            }
            Some(offset) => {
                out.extend_from_slice(&raw[start..start + offset]);
                start += offset;
            }
        }
    }
}

/// `decodeEntity`：认出则写入 [out] 并返回 true。
fn decode_entity(entity: &[u16], out: &mut Vec<u16>) -> bool {
    use super::danmaku_dart::units_eq_ascii;
    if entity.len() > 1 && entity[0] == b'#' as u16 {
        let value = if entity.len() > 2 && (entity[1] == b'x' as u16 || entity[1] == b'X' as u16) {
            int_try_parse(&entity[2..], Some(16))
        } else {
            int_try_parse(&entity[1..], Some(10))
        };
        return match value {
            Some(v) if (0..=0x10FFFF).contains(&v) => {
                // String.fromCharCode：BMP（含孤立代理）一个码元，其余拆代理对。
                let v = v as u32;
                if v <= 0xFFFF {
                    out.push(v as u16);
                } else {
                    let c = v - 0x10000;
                    out.push(0xD800 | (c >> 10) as u16);
                    out.push(0xDC00 | (c & 0x3FF) as u16);
                }
                true
            }
            _ => false,
        };
    }
    let mapped = if units_eq_ascii(entity, b"amp") {
        b'&'
    } else if units_eq_ascii(entity, b"apos") {
        b'\''
    } else if units_eq_ascii(entity, b"gt") {
        b'>'
    } else if units_eq_ascii(entity, b"lt") {
        b'<'
    } else if units_eq_ascii(entity, b"quot") {
        b'"'
    } else {
        return false;
    };
    out.push(u16::from(mapped));
    true
}

/// 解析整份文档；语法或校验失败返回 `None`（对应 Dart 侧抛异常、旧实现返回空表）。
pub fn parse_danmaku_xml(s: &[u16]) -> Option<XmlDanmakuDoc> {
    let cursor = Cursor { s };
    let mut elements: Vec<XmlDanmakuElement> = Vec::new();
    let mut text: Vec<u16> = Vec::new();
    // 打开中的元素：(名字区间, 若是 <d> 则为 elements 下标)。
    let mut open: Vec<((usize, usize), Option<usize>)> = Vec::new();
    let mut open_d = 0usize;
    let mut has_declaration = false;
    let mut has_doctype = false;
    let mut has_root = false;
    let mut p = 0;
    while p < s.len() {
        let (event, end) = cursor.event(p)?;
        let at_root = open.is_empty();
        match event {
            Event::Text(a, b) => {
                if open_d > 0 {
                    decode_entities(&s[a..b], &mut text);
                }
            }
            Event::Cdata(a, b) => {
                if open_d > 0 {
                    text.extend_from_slice(&s[a..b]);
                }
            }
            Event::Declaration => {
                if !at_root || has_declaration || has_doctype || has_root {
                    return None;
                }
                has_declaration = true;
            }
            Event::Doctype => {
                if !at_root || has_doctype || has_root {
                    return None;
                }
                has_doctype = true;
            }
            Event::Start {
                name,
                p_attr,
                self_closing,
            } => {
                if at_root {
                    if has_root {
                        return None;
                    }
                    has_root = true;
                }
                let is_d = name.1 - name.0 == 1 && s[name.0] == b'd' as u16;
                let d_index = if is_d {
                    let p_value = p_attr.map(|(vs, ve)| {
                        let mut value = Vec::with_capacity(ve - vs);
                        decode_entities(&s[vs..ve], &mut value);
                        value
                    });
                    elements.push(XmlDanmakuElement {
                        p: p_value,
                        text_start: text.len(),
                        text_end: text.len(),
                    });
                    Some(elements.len() - 1)
                } else {
                    None
                };
                if !self_closing {
                    if d_index.is_some() {
                        open_d += 1;
                    }
                    open.push((name, d_index));
                }
            }
            Event::End(a, b) => {
                let ((oa, ob), d_index) = *open.last()?;
                if s[oa..ob] != s[a..b] {
                    return None;
                }
                open.pop();
                if let Some(index) = d_index {
                    elements[index].text_end = text.len();
                    open_d -= 1;
                }
            }
            Event::Other => {}
        }
        p = end;
    }
    if !open.is_empty() || !has_root {
        return None;
    }
    Some(XmlDanmakuDoc { elements, text })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn u(s: &str) -> Vec<u16> {
        s.encode_utf16().collect()
    }

    fn texts(xml: &str) -> Option<Vec<(Option<String>, String)>> {
        let doc = parse_danmaku_xml(&u(xml))?;
        Some(
            doc.elements
                .iter()
                .map(|e| {
                    (
                        e.p.as_ref().map(|p| String::from_utf16(p).unwrap()),
                        String::from_utf16(&doc.text[e.text_start..e.text_end]).unwrap(),
                    )
                })
                .collect(),
        )
    }

    #[test]
    fn basic_and_nested() {
        let got =
            texts("<i><d p=\"1,1,25,255\">a &amp; b</d><d p='x'>o<d>in</d>ut</d></i>").unwrap();
        assert_eq!(
            got,
            vec![
                (Some("1,1,25,255".into()), "a & b".into()),
                (Some("x".into()), "oinut".into()),
                (None, "in".into()),
            ]
        );
    }

    #[test]
    fn validation_failures() {
        assert!(texts("").is_none());
        assert!(texts("text only").is_none());
        assert!(texts("<i><d>x</i>").is_none());
        assert!(texts("<i/><j/>").is_none());
        assert!(texts("<i><?xml version='1.0'?></i>").is_none());
        assert!(texts("<i/><?xml version='1.0'?>").is_none());
        assert!(texts("<i>a < b</i>").is_none());
        assert!(texts("<i>").is_none());
        assert!(texts("</i>").is_none());
    }

    #[test]
    fn accepted_oddities() {
        assert!(texts("\u{feff}<?xml version=\"1.0\"?><i/>").is_some());
        assert!(texts("<!--c--><?xml version=\"1.0\"?><i/>").is_some());
        assert!(texts("lead<i/>trail").is_some());
        assert!(texts("<!DOCTYPE i [ <!ENTITY a \"]>\"> ]><i/>").is_some());
        assert_eq!(
            texts("<i><d p=a>x<![CDATA[&amp;<]]><!--no--><?pi z?>&#x41;&#65;&bogus;&#x110000;</d></i>")
                .unwrap(),
            vec![(Some("a".into()), "x&amp;<AA&bogus;&#x110000;".into())]
        );
    }

    #[test]
    fn entity_decoding_edge_cases() {
        let decode = |s: &str| {
            let mut out = Vec::new();
            decode_entities(&u(s), &mut out);
            String::from_utf16_lossy(&out)
        };
        assert_eq!(decode("&a &amp;"), "&a &");
        assert_eq!(decode("&;&&lt;"), "&;&<");
        // 数字实体走 int.tryParse：首尾空白与 '+' 都被接受，负数不认。
        assert_eq!(decode("&# 65;&#+65;&#x 41;&#-65;"), "AAA&#-65;");
        assert_eq!(decode("&&&"), "&&&");
        assert_eq!(decode("tail&amp"), "tail&amp");
    }
}
