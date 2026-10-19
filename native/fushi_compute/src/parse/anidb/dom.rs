//! 单部 anime XML（AniDB HTTP API `request=anime`）的 DOM 解析：原
//! `anidb_video_metadata_provider.dart` 的 DOCTYPE/ENTITY 预检 + `XmlDocument.parse`。
//!
//! 产出一份紧凑的只读元素树（元素 / 属性 / 文本池），Dart 侧包成轻量视图，取值逻辑
//! （`getElement` / `findElements` / `innerText` / `getAttribute`）仍在 Dart，语义照
//! `package:xml` 的 DOM。解析语义 = `parseEvents(validateNesting: true,
//! validateDocument: true)` + `XmlNodeDecoder`，失败时报出与原实现同类的异常信息
//! （种类、码元位置、标签名；petitparser 的失败文案只求接近）。
//!
//! 输出（小端）：
//! ```text
//! u32 element_count, u32 attr_count, u32 text_units, u32 string_units
//! element_count × [parent(u32::MAX = 无), name_off, name_len, attr_start, attr_count,
//!                  text_start, text_end]                         （u32 × 7）
//! attr_count × [name_off, name_len, value_off, value_len]        （u32 × 4）
//! text_units × u16    文本池：全部文本 / CDATA 按文档顺序拼接，元素的 innerText 是其中一段
//! string_units × u16  名字与属性值
//! ```

use super::xml::{decode_entities, parse_event, Event, Step};
use crate::parse::title_score::is_regex_whitespace;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum DomError {
    /// 预检命中 `<!DOCTYPE` / `<!ENTITY`。
    Forbidden,
    Parser {
        message: String,
        position: usize,
    },
    TagMismatch {
        expected: Vec<u16>,
        actual: Vec<u16>,
        position: usize,
    },
    TagUnexpected {
        actual: Vec<u16>,
        position: usize,
    },
    TagMissing {
        expected: Vec<u16>,
        position: usize,
    },
}

impl DomError {
    pub fn kind(&self) -> u32 {
        match self {
            DomError::Forbidden => 1,
            DomError::Parser { .. } => 2,
            DomError::TagMismatch { .. } => 3,
            DomError::TagUnexpected { .. } => 4,
            DomError::TagMissing { .. } => 5,
        }
    }
}

/// `RegExp(r'<!\s*(?:DOCTYPE|ENTITY)\b', caseSensitive: false).hasMatch(xml)`。
pub fn has_forbidden_declaration(buf: &[u16]) -> bool {
    let is_word = |u: u16| matches!(u, 0x30..=0x39 | 0x41..=0x5A | 0x61..=0x7A | 0x5F);
    let keyword_at = |pos: usize, kw: &str| -> bool {
        let bytes = kw.as_bytes();
        if pos + bytes.len() > buf.len() {
            return false;
        }
        for (i, &b) in bytes.iter().enumerate() {
            let u = buf[pos + i];
            // 非 unicode 模式的忽略大小写：只有 ASCII 字母互相折叠。
            let folded = if (0x61..=0x7A).contains(&u) {
                u - 0x20
            } else {
                u
            };
            if folded != u16::from(b) {
                return false;
            }
        }
        let after = pos + bytes.len();
        after >= buf.len() || !is_word(buf[after])
    };
    let mut i = 0;
    while i + 1 < buf.len() {
        if buf[i] == 0x3C && buf[i + 1] == 0x21 {
            let mut j = i + 2;
            while j < buf.len() && is_regex_whitespace(buf[j]) {
                j += 1;
            }
            if keyword_at(j, "DOCTYPE") || keyword_at(j, "ENTITY") {
                return true;
            }
        }
        i += 1;
    }
    false
}

struct Element {
    parent: u32,
    name: (u32, u32),
    attrs: (u32, u32),
    text: (u32, u32),
}

pub fn parse_dom(buf: &[u16]) -> Result<Vec<u8>, DomError> {
    if has_forbidden_declaration(buf) {
        return Err(DomError::Forbidden);
    }
    let mut elements: Vec<Element> = Vec::new();
    let mut attr_spans: Vec<[u32; 4]> = Vec::new();
    let mut text: Vec<u16> = Vec::new();
    let mut strings: Vec<u16> = Vec::new();
    let mut open: Vec<u32> = Vec::new();
    let (mut has_decl, mut has_doctype, mut has_root) = (false, false, false);
    let mut raw_attrs = Vec::new();
    let mut pos = 0;
    let intern = |strings: &mut Vec<u16>, units: &[u16]| -> (u32, u32) {
        let span = (strings.len() as u32, units.len() as u32);
        strings.extend_from_slice(units);
        span
    };
    let name_of = |strings: &Vec<u16>, e: &Element| -> Vec<u16> {
        strings[e.name.0 as usize..(e.name.0 + e.name.1) as usize].to_vec()
    };
    while pos < buf.len() {
        raw_attrs.clear();
        let (event, end) = match parse_event(buf, pos, true, &mut raw_attrs) {
            Step::Event(event, end) => (event, end),
            Step::NeedMore => unreachable!("eof mode never asks for more"),
            Step::Fail(fail) => {
                return Err(DomError::Parser {
                    message: fail.msg.to_string(),
                    position: fail.pos,
                })
            }
        };
        let start = pos;
        // XmlAnnotator.validateDocument（只看根层事件）。
        if open.is_empty() {
            let parser = |message: &str| DomError::Parser {
                message: message.to_string(),
                position: start,
            };
            match &event {
                Event::Declaration => {
                    if has_decl {
                        return Err(parser("Expected at most one XML declaration"));
                    } else if has_doctype || has_root {
                        return Err(parser("Unexpected XML declaration"));
                    }
                    has_decl = true;
                }
                Event::Doctype => {
                    if has_doctype {
                        return Err(parser("Expected at most one doctype declaration"));
                    } else if has_root {
                        return Err(parser("Unexpected doctype declaration"));
                    }
                    has_doctype = true;
                }
                Event::Start { .. } => {
                    if has_root {
                        return Err(parser("Unexpected root element"));
                    }
                    has_root = true;
                }
                _ => {}
            }
        }
        match &event {
            Event::Start {
                name,
                attrs: (a, b),
                self_closing,
            } => {
                let name = intern(&mut strings, &buf[name.0..name.1]);
                let attr_start = attr_spans.len() as u32;
                for attr in &raw_attrs[*a..*b] {
                    let n = intern(&mut strings, &buf[attr.name.0..attr.name.1]);
                    let v = intern(
                        &mut strings,
                        &decode_entities(&buf[attr.value.0..attr.value.1]),
                    );
                    attr_spans.push([n.0, n.1, v.0, v.1]);
                }
                let index = elements.len() as u32;
                let text_start = text.len() as u32;
                elements.push(Element {
                    parent: open.last().copied().unwrap_or(u32::MAX),
                    name,
                    attrs: (attr_start, (*b - *a) as u32),
                    text: (text_start, text_start),
                });
                if !*self_closing {
                    open.push(index);
                }
            }
            Event::End(name) => {
                let actual = buf[name.0..name.1].to_vec();
                match open.last() {
                    None => {
                        return Err(DomError::TagUnexpected {
                            actual,
                            position: start,
                        })
                    }
                    Some(&top) => {
                        let expected = name_of(&strings, &elements[top as usize]);
                        if expected != actual {
                            return Err(DomError::TagMismatch {
                                expected,
                                actual,
                                position: start,
                            });
                        }
                        elements[top as usize].text.1 = text.len() as u32;
                        open.pop();
                    }
                }
            }
            Event::Text(span) => text.extend_from_slice(&decode_entities(&buf[span.0..span.1])),
            Event::CData(span) => text.extend_from_slice(&buf[span.0..span.1]),
            _ => {}
        }
        pos = end;
    }
    if let Some(&top) = open.last() {
        return Err(DomError::TagMissing {
            expected: name_of(&strings, &elements[top as usize]),
            position: buf.len(),
        });
    }
    if !has_root {
        return Err(DomError::Parser {
            message: "Expected a single root element".to_string(),
            position: buf.len(),
        });
    }
    let mut out: Vec<u8> = Vec::with_capacity(
        16 + elements.len() * 28 + attr_spans.len() * 16 + (text.len() + strings.len()) * 2,
    );
    let put = |out: &mut Vec<u8>, v: u32| out.extend_from_slice(&v.to_le_bytes());
    put(&mut out, elements.len() as u32);
    put(&mut out, attr_spans.len() as u32);
    put(&mut out, text.len() as u32);
    put(&mut out, strings.len() as u32);
    for e in &elements {
        for v in [
            e.parent, e.name.0, e.name.1, e.attrs.0, e.attrs.1, e.text.0, e.text.1,
        ] {
            put(&mut out, v);
        }
    }
    for a in &attr_spans {
        for &v in a {
            put(&mut out, v);
        }
    }
    for &u in text.iter().chain(strings.iter()) {
        out.extend_from_slice(&u.to_le_bytes());
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn u(s: &str) -> Vec<u16> {
        s.encode_utf16().collect()
    }

    #[test]
    fn forbidden_precheck() {
        assert!(has_forbidden_declaration(&u("<!DOCTYPE x>")));
        assert!(has_forbidden_declaration(&u("<! \n doctype x>")));
        assert!(has_forbidden_declaration(&u("<!ENTITY")));
        assert!(!has_forbidden_declaration(&u("<!DOCTYPEX>")));
        assert!(!has_forbidden_declaration(&u("<!-- doctype -->")));
    }

    #[test]
    fn tree_and_errors() {
        let ok = parse_dom(&u(
            "<?xml version=\"1.0\"?><anime id=\"1\"><a>x<b>y</b></a><c/></anime>",
        ))
        .unwrap();
        let word = |i: usize| u32::from_le_bytes(ok[i * 4..i * 4 + 4].try_into().unwrap());
        assert_eq!(word(0), 4);
        assert_eq!(word(1), 1);
        assert_eq!(word(2), 2);
        assert!(matches!(
            parse_dom(&u("<a></b>")),
            Err(DomError::TagMismatch { position: 3, .. })
        ));
        assert!(matches!(
            parse_dom(&u("</b>")),
            Err(DomError::TagUnexpected { .. })
        ));
        assert!(matches!(
            parse_dom(&u("<a>")),
            Err(DomError::TagMissing { position: 3, .. })
        ));
        assert!(matches!(
            parse_dom(&u("<a/><b/>")),
            Err(DomError::Parser { position: 4, .. })
        ));
        assert!(matches!(
            parse_dom(&u("text")),
            Err(DomError::Parser { position: 4, .. })
        ));
        assert!(matches!(
            parse_dom(&u("<a/><?xml?>")),
            Err(DomError::Parser { .. })
        ));
    }
}
