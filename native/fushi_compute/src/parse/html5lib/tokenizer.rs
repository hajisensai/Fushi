//! `src/html_input_stream.dart`（字符串输入路径）+ `src/tokenizer.dart`。
//!
//! Dart 版按 UTF-16 码元存流、但 `char()` 一次取一个完整代理对，所有判定（`isLetter`、
//! `charsUntil` 的停止集、实体 trie 查找）都只看 ASCII，所以这里按 Unicode 标量逐个
//! 处理与之等价（输入来自 Rust `&str`，不存在孤立代理）。解析错误 token 对树没有影响，
//! 不入队。

use std::cell::RefCell;
use std::collections::VecDeque;
use std::rc::Rc;

use super::dom::{AttrKey, AttrMap, Attrs, Ns};
use super::entities::ENTITIES;
use super::{ParseFailure, Res};

pub struct StartTag {
    pub name: String,
    pub data: Attrs,
    pub self_closing: bool,
    pub self_closing_acknowledged: bool,
    /// 树构建时才填（外来内容）；`None` = 默认命名空间（HTML）。
    pub namespace: Option<Ns>,
}

impl StartTag {
    pub fn new(name: &str) -> StartTag {
        StartTag::with_data(name, Rc::new(RefCell::new(AttrMap::default())))
    }

    pub fn with_data(name: &str, data: Attrs) -> StartTag {
        StartTag {
            name: name.to_string(),
            data,
            self_closing: false,
            self_closing_acknowledged: false,
            namespace: None,
        }
    }
}

pub struct Doctype {
    pub name: String,
    pub public_id: Option<String>,
    pub system_id: Option<String>,
    pub correct: bool,
}

pub enum Token {
    Characters(String),
    SpaceCharacters(String),
    StartTag(StartTag),
    EndTag(String),
    Comment(String),
    Doctype(Doctype),
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum State {
    Data,
    EntityData,
    Rcdata,
    CharacterReferenceInRcdata,
    Rawtext,
    ScriptData,
    Plaintext,
    TagOpen,
    CloseTagOpen,
    TagName,
    RcdataLessThanSign,
    RcdataEndTagOpen,
    RcdataEndTagName,
    RawtextLessThanSign,
    RawtextEndTagOpen,
    RawtextEndTagName,
    ScriptDataLessThanSign,
    ScriptDataEndTagOpen,
    ScriptDataEndTagName,
    ScriptDataEscapeStart,
    ScriptDataEscapeStartDash,
    ScriptDataEscaped,
    ScriptDataEscapedDash,
    ScriptDataEscapedDashDash,
    ScriptDataEscapedLessThanSign,
    ScriptDataEscapedEndTagOpen,
    ScriptDataEscapedEndTagName,
    ScriptDataDoubleEscapeStart,
    ScriptDataDoubleEscaped,
    ScriptDataDoubleEscapedDash,
    ScriptDataDoubleEscapedDashDash,
    ScriptDataDoubleEscapedLessThanSign,
    ScriptDataDoubleEscapeEnd,
    BeforeAttributeName,
    AttributeName,
    AfterAttributeName,
    BeforeAttributeValue,
    AttributeValueDoubleQuoted,
    AttributeValueSingleQuoted,
    AttributeValueUnQuoted,
    AfterAttributeValue,
    SelfClosingStartTag,
    BogusComment,
    MarkupDeclarationOpen,
    CommentStart,
    CommentStartDash,
    Comment,
    CommentEndDash,
    CommentEnd,
    CommentEndBang,
    Doctype,
    BeforeDoctypeName,
    DoctypeName,
    AfterDoctypeName,
    AfterDoctypePublicKeyword,
    BeforeDoctypePublicIdentifier,
    DoctypePublicIdentifierDoubleQuoted,
    DoctypePublicIdentifierSingleQuoted,
    AfterDoctypePublicIdentifier,
    BetweenDoctypePublicAndSystemIdentifiers,
    AfterDoctypeSystemKeyword,
    BeforeDoctypeSystemIdentifier,
    DoctypeSystemIdentifierDoubleQuoted,
    DoctypeSystemIdentifierSingleQuoted,
    AfterDoctypeSystemIdentifier,
    BogusDoctype,
    CdataSection,
}

/// `currentToken`。发出后仍保留（`_tokenIsAppropriate` 读的是它）。
enum Current {
    None,
    Tag {
        name: String,
        end: bool,
        self_closing: bool,
    },
    Comment(String),
    Doctype(Doctype),
}

/// constants.dart `isWhitespace`（只看首码元）。
fn is_ws(c: Option<char>) -> bool {
    matches!(c, Some('\t' | '\n' | '\x0C' | '\r' | ' '))
}

fn is_space_char(c: char) -> bool {
    matches!(c, '\t' | '\n' | '\x0C' | '\r' | ' ')
}

fn is_letter(c: Option<char>) -> bool {
    matches!(c, Some('a'..='z' | 'A'..='Z'))
}

fn is_digit(c: Option<char>) -> bool {
    matches!(c, Some('0'..='9'))
}

fn is_hex_digit(c: Option<char>) -> bool {
    matches!(c, Some('0'..='9' | 'A'..='F' | 'a'..='f'))
}

/// `String.toAsciiLowerCase()`。
pub fn ascii_lower(s: &str) -> String {
    s.to_ascii_lowercase()
}

/// constants.dart `replacementCharacters`。
fn replacement_character(v: i64) -> Option<char> {
    Some(match v {
        0x00 => '\u{FFFD}',
        0x0d => '\u{000D}',
        0x80 => '\u{20AC}',
        0x81 => '\u{0081}',
        0x82 => '\u{201A}',
        0x83 => '\u{0192}',
        0x84 => '\u{201E}',
        0x85 => '\u{2026}',
        0x86 => '\u{2020}',
        0x87 => '\u{2021}',
        0x88 => '\u{02C6}',
        0x89 => '\u{2030}',
        0x8A => '\u{0160}',
        0x8B => '\u{2039}',
        0x8C => '\u{0152}',
        0x8D => '\u{008D}',
        0x8E => '\u{017D}',
        0x8F => '\u{008F}',
        0x90 => '\u{0090}',
        0x91 => '\u{2018}',
        0x92 => '\u{2019}',
        0x93 => '\u{201C}',
        0x94 => '\u{201D}',
        0x95 => '\u{2022}',
        0x96 => '\u{2013}',
        0x97 => '\u{2014}',
        0x98 => '\u{02DC}',
        0x99 => '\u{2122}',
        0x9A => '\u{0161}',
        0x9B => '\u{203A}',
        0x9C => '\u{0153}',
        0x9D => '\u{009D}',
        0x9E => '\u{017E}',
        0x9F => '\u{0178}',
        _ => return None,
    })
}

fn entity_value(name: &str) -> Option<&'static str> {
    ENTITIES
        .binary_search_by(|(k, _)| (*k).cmp(name))
        .ok()
        .map(|i| ENTITIES[i].1)
}

/// `entitiesTrieRoot` 里有没有以 [prefix] 为路径的节点（trie 恰是实体名的前缀闭包）。
fn has_entity_prefix(prefix: &str) -> bool {
    let i = ENTITIES.partition_point(|(k, _)| *k < prefix);
    i < ENTITIES.len() && ENTITIES[i].0.starts_with(prefix)
}

fn join(stack: &[Option<char>]) -> String {
    stack.iter().flatten().collect()
}

pub struct Tokenizer {
    chars: Vec<char>,
    offset: usize,
    pub state: State,
    queue: VecDeque<Token>,
    current: Current,
    buffer: String,
    /// `_attributes`：（名, 值）；名在离开属性名状态时才定（未定为 `None`）。
    attributes: Option<Vec<(Option<String>, String)>>,
    attribute_name: String,
    attribute_value: String,
    /// 本轮 `moveNext` 期间的「当前节点不在 HTML 命名空间」（CDATA 段的前提）。
    cdata_allowed: bool,
}

impl Tokenizer {
    /// `HtmlInputStream(String)` + `reset()`：CR → LF，CRLF 折成 LF。
    pub fn new(input: &str) -> Tokenizer {
        let mut chars = Vec::with_capacity(input.len());
        let mut skip_newline = false;
        for mut c in input.chars() {
            if skip_newline {
                skip_newline = false;
                if c == '\n' {
                    continue;
                }
            }
            if c == '\r' {
                skip_newline = true;
                c = '\n';
            }
            chars.push(c);
        }
        Tokenizer {
            chars,
            offset: 0,
            state: State::Data,
            queue: VecDeque::new(),
            current: Current::None,
            buffer: String::new(),
            attributes: None,
            attribute_name: String::new(),
            attribute_value: String::new(),
            cdata_allowed: false,
        }
    }

    // ---- HtmlInputStream ----

    fn char(&mut self) -> Option<char> {
        let c = self.chars.get(self.offset).copied();
        if c.is_some() {
            self.offset += 1;
        }
        c
    }

    fn unget(&mut self, c: Option<char>) {
        if c.is_some() {
            self.offset -= 1;
        }
    }

    /// `charsUntil*`：跳过（并返回）[stop] 为假的那段字符。
    fn chars_until(&mut self, stop: impl Fn(char) -> bool) -> String {
        let start = self.offset;
        while let Some(&c) = self.chars.get(self.offset) {
            if stop(c) {
                break;
            }
            self.offset += 1;
        }
        self.chars[start..self.offset].iter().collect()
    }

    // ---- HtmlTokenizer ----

    /// `moveNext()`；`None` = 到 EOF。
    pub fn next_token(&mut self, cdata_allowed: bool) -> Res<Option<Token>> {
        self.cdata_allowed = cdata_allowed;
        while self.queue.is_empty() {
            if !self.step()? {
                return Ok(None);
            }
        }
        Ok(self.queue.pop_front())
    }

    fn add(&mut self, t: Token) {
        self.queue.push_back(t);
    }

    fn chars_token(&mut self, s: String) {
        self.add(Token::Characters(s));
    }

    fn mark_attribute_end(&mut self) {
        let v = self.attribute_value.clone();
        if let Some(last) = self.attributes.as_mut().and_then(|a| a.last_mut()) {
            last.1 = v;
        }
    }

    fn add_attribute(&mut self, name: &str) {
        let attrs = self.attributes.get_or_insert_with(Vec::new);
        self.attribute_name.clear();
        self.attribute_name.push_str(name);
        self.attribute_value.clear();
        attrs.push((None, String::new()));
    }

    fn tag_name_mut(&mut self) -> &mut String {
        match &mut self.current {
            Current::Tag { name, .. } => name,
            _ => unreachable!("currentTagToken is not a tag"),
        }
    }

    fn token_is_appropriate(&self) -> bool {
        match &self.current {
            Current::Tag { name, .. } => name.to_lowercase() == self.buffer.to_lowercase(),
            _ => false,
        }
    }

    fn consume_number_entity(&mut self, is_hex: bool) -> Res<String> {
        let radix: u32 = if is_hex { 16 } else { 10 };
        let mut value: i64 = 0;
        let mut overflow = false;
        let mut c = self.char();
        loop {
            let ok = if is_hex { is_hex_digit(c) } else { is_digit(c) };
            if !ok {
                break;
            }
            let d = i64::from(c.and_then(|ch| ch.to_digit(radix)).unwrap_or(0));
            match value
                .checked_mul(i64::from(radix))
                .and_then(|v| v.checked_add(d))
            {
                Some(v) => value = v,
                None => overflow = true,
            }
            c = self.char();
        }
        if overflow {
            // `int.parse` 超出 64 位抛 FormatException，整个 parse() 随之失败。
            return Err(ParseFailure(
                "FormatException: numeric character reference overflow",
            ));
        }
        let out = if let Some(ch) = replacement_character(value) {
            ch.to_string()
        } else if (0xD800..=0xDFFF).contains(&value) || value > 0x10FFFF {
            '\u{FFFD}'.to_string()
        } else {
            char::from_u32(value as u32)
                .unwrap_or('\u{FFFD}')
                .to_string()
        };
        if c != Some(';') {
            self.unget(c);
        }
        Ok(out)
    }

    fn consume_entity(&mut self, allowed_char: Option<char>, from_attribute: bool) -> Res<()> {
        let mut output = String::from("&");
        let first = self.char();
        let mut stack: Vec<Option<char>> = vec![first];
        if is_ws(first)
            || first == Some('<')
            || first == Some('&')
            || first.is_none()
            || (allowed_char.is_some() && allowed_char == first)
        {
            self.unget(first);
        } else if first == Some('#') {
            let mut hex = false;
            let c = self.char();
            stack.push(c);
            if c == Some('x') || c == Some('X') {
                hex = true;
                stack.push(self.char());
            }
            let last = *stack.last().unwrap();
            if (hex && is_hex_digit(last)) || (!hex && is_digit(last)) {
                self.unget(last);
                output = self.consume_number_entity(hex)?;
            } else {
                let l = stack.pop().unwrap();
                self.unget(l);
                output = format!("&{}", join(&stack));
            }
        } else {
            let mut path = String::new();
            path.extend(first);
            let mut node = has_entity_prefix(&path);
            while node && stack.last().unwrap().is_some() {
                let c = self.char();
                stack.push(c);
                match c {
                    Some(ch) => {
                        path.push(ch);
                        node = has_entity_prefix(&path);
                    }
                    None => node = false,
                }
            }
            let mut entity: Option<(usize, &'static str, String)> = None;
            let mut len = stack.len() - 1;
            while len > 1 {
                let candidate = join(&stack[..len]);
                if let Some(v) = entity_value(&candidate) {
                    entity = Some((len, v, candidate));
                    break;
                }
                len -= 1;
            }
            match entity {
                Some((entity_len, value, name)) => {
                    let last_char = name.chars().last();
                    let next = stack[entity_len];
                    if last_char != Some(';')
                        && from_attribute
                        && (matches!(next, Some(c) if c.is_ascii_alphanumeric())
                            || next == Some('='))
                    {
                        let l = stack.pop().unwrap();
                        self.unget(l);
                        output = format!("&{}", join(&stack));
                    } else {
                        let l = stack.pop().unwrap();
                        self.unget(l);
                        output = format!("{value}{}", join(&stack[entity_len.min(stack.len())..]));
                    }
                }
                None => {
                    let l = stack.pop().unwrap();
                    self.unget(l);
                    output = format!("&{}", join(&stack));
                }
            }
        }
        if from_attribute {
            self.attribute_value.push_str(&output);
        } else if is_ws(output.chars().next()) {
            self.add(Token::SpaceCharacters(output));
        } else {
            self.add(Token::Characters(output));
        }
        Ok(())
    }

    fn emit_current_token(&mut self) {
        let current = std::mem::replace(&mut self.current, Current::None);
        match current {
            Current::Tag {
                name,
                end,
                self_closing,
            } => {
                let name = ascii_lower(&name);
                let attributes = self.attributes.take();
                if end {
                    self.add(Token::EndTag(name.clone()));
                } else {
                    let mut data = AttrMap::default();
                    for (n, v) in attributes.into_iter().flatten() {
                        // 名字总在离开属性名状态时写入；防御性地按 Dart 的 `attr.name!` 处理。
                        let n = n.unwrap_or_default();
                        data.put_if_absent(AttrKey::Plain(n), v);
                    }
                    self.add(Token::StartTag(StartTag {
                        name: name.clone(),
                        data: Rc::new(RefCell::new(data)),
                        self_closing,
                        self_closing_acknowledged: false,
                        namespace: None,
                    }));
                }
                self.current = Current::Tag {
                    name,
                    end,
                    self_closing,
                };
            }
            other => {
                // 只有标签走 emitCurrentToken。
                self.current = other;
            }
        }
        self.state = State::Data;
    }

    /// 把当前注释 / doctype token 入队（`_addToken(currentToken!)`），currentToken 保留类型。
    fn emit_current_string_like(&mut self) {
        match &mut self.current {
            Current::Comment(s) => {
                let s = std::mem::take(s);
                self.add(Token::Comment(s));
            }
            Current::Doctype(d) => {
                let d = Doctype {
                    name: std::mem::take(&mut d.name),
                    public_id: d.public_id.take(),
                    system_id: d.system_id.take(),
                    correct: d.correct,
                };
                self.add(Token::Doctype(d));
            }
            _ => {}
        }
    }

    fn comment_add(&mut self, s: &str) {
        if let Current::Comment(c) = &mut self.current {
            c.push_str(s);
        }
    }

    fn doctype(&mut self) -> &mut Doctype {
        match &mut self.current {
            Current::Doctype(d) => d,
            _ => unreachable!("currentDoctypeToken is not a doctype"),
        }
    }

    fn step(&mut self) -> Res<bool> {
        use State as S;
        match self.state {
            S::Data => {
                let data = self.char();
                match data {
                    Some('&') => self.state = S::EntityData,
                    Some('<') => self.state = S::TagOpen,
                    Some('\0') => self.chars_token("\0".to_string()),
                    None => return Ok(false),
                    Some(c) if is_space_char(c) => {
                        let rest = self.chars_until(|c| !is_space_char(c));
                        self.add(Token::SpaceCharacters(format!("{c}{rest}")));
                    }
                    Some(c) => {
                        let rest = self.chars_until(|c| c == '&' || c == '<' || c == '\0');
                        self.chars_token(format!("{c}{rest}"));
                    }
                }
            }
            S::EntityData => {
                self.consume_entity(None, false)?;
                self.state = S::Data;
            }
            S::Rcdata => {
                let data = self.char();
                match data {
                    Some('&') => self.state = S::CharacterReferenceInRcdata,
                    Some('<') => self.state = S::RcdataLessThanSign,
                    None => return Ok(false),
                    Some('\0') => self.chars_token("\u{FFFD}".to_string()),
                    Some(c) if is_space_char(c) => {
                        let rest = self.chars_until(|c| !is_space_char(c));
                        self.add(Token::SpaceCharacters(format!("{c}{rest}")));
                    }
                    Some(c) => {
                        let rest = self.chars_until(|c| c == '&' || c == '<');
                        self.chars_token(format!("{c}{rest}"));
                    }
                }
            }
            S::CharacterReferenceInRcdata => {
                self.consume_entity(None, false)?;
                self.state = S::Rcdata;
            }
            S::Rawtext | S::ScriptData => {
                let back = self.state;
                let data = self.char();
                match data {
                    Some('<') => {
                        self.state = if back == S::Rawtext {
                            S::RawtextLessThanSign
                        } else {
                            S::ScriptDataLessThanSign
                        }
                    }
                    Some('\0') => self.chars_token("\u{FFFD}".to_string()),
                    None => return Ok(false),
                    Some(c) => {
                        let rest = self.chars_until(|c| c == '<' || c == '\0');
                        self.chars_token(format!("{c}{rest}"));
                    }
                }
            }
            S::Plaintext => {
                let data = self.char();
                match data {
                    None => return Ok(false),
                    Some('\0') => self.chars_token("\u{FFFD}".to_string()),
                    Some(c) => {
                        let rest = self.chars_until(|c| c == '\0');
                        self.chars_token(format!("{c}{rest}"));
                    }
                }
            }
            S::TagOpen => {
                let data = self.char();
                match data {
                    Some('!') => self.state = S::MarkupDeclarationOpen,
                    Some('/') => self.state = S::CloseTagOpen,
                    Some(c) if is_letter(data) => {
                        self.current = Current::Tag {
                            name: c.to_string(),
                            end: false,
                            self_closing: false,
                        };
                        self.state = S::TagName;
                    }
                    Some('>') => {
                        self.chars_token("<>".to_string());
                        self.state = S::Data;
                    }
                    Some('?') => {
                        self.unget(data);
                        self.state = S::BogusComment;
                    }
                    _ => {
                        self.chars_token("<".to_string());
                        self.unget(data);
                        self.state = S::Data;
                    }
                }
            }
            S::CloseTagOpen => {
                let data = self.char();
                match data {
                    Some(c) if is_letter(data) => {
                        self.current = Current::Tag {
                            name: c.to_string(),
                            end: true,
                            self_closing: false,
                        };
                        self.state = S::TagName;
                    }
                    Some('>') => self.state = S::Data,
                    None => {
                        self.chars_token("</".to_string());
                        self.state = S::Data;
                    }
                    _ => {
                        self.unget(data);
                        self.state = S::BogusComment;
                    }
                }
            }
            S::TagName => {
                let data = self.char();
                match data {
                    _ if is_ws(data) => self.state = S::BeforeAttributeName,
                    Some('>') => self.emit_current_token(),
                    None => self.state = S::Data,
                    Some('/') => self.state = S::SelfClosingStartTag,
                    Some('\0') => self.tag_name_mut().push('\u{FFFD}'),
                    Some(c) => self.tag_name_mut().push(c),
                }
            }
            S::RcdataLessThanSign | S::RawtextLessThanSign => {
                let (end_open, back) = if self.state == S::RcdataLessThanSign {
                    (S::RcdataEndTagOpen, S::Rcdata)
                } else {
                    (S::RawtextEndTagOpen, S::Rawtext)
                };
                let data = self.char();
                if data == Some('/') {
                    self.buffer.clear();
                    self.state = end_open;
                } else {
                    self.chars_token("<".to_string());
                    self.unget(data);
                    self.state = back;
                }
            }
            S::RcdataEndTagOpen | S::RawtextEndTagOpen | S::ScriptDataEndTagOpen => {
                let (name_state, back) = match self.state {
                    S::RcdataEndTagOpen => (S::RcdataEndTagName, S::Rcdata),
                    S::RawtextEndTagOpen => (S::RawtextEndTagName, S::Rawtext),
                    _ => (S::ScriptDataEndTagName, S::ScriptData),
                };
                let data = self.char();
                if let (true, Some(c)) = (is_letter(data), data) {
                    self.buffer.push(c);
                    self.state = name_state;
                } else {
                    self.chars_token("</".to_string());
                    self.unget(data);
                    self.state = back;
                }
            }
            S::RcdataEndTagName
            | S::RawtextEndTagName
            | S::ScriptDataEndTagName
            | S::ScriptDataEscapedEndTagName => {
                let back = match self.state {
                    S::RcdataEndTagName => S::Rcdata,
                    S::RawtextEndTagName => S::Rawtext,
                    S::ScriptDataEndTagName => S::ScriptData,
                    _ => S::ScriptDataEscaped,
                };
                let appropriate = self.token_is_appropriate();
                let data = self.char();
                if is_ws(data) && appropriate {
                    self.current = Current::Tag {
                        name: self.buffer.clone(),
                        end: true,
                        self_closing: false,
                    };
                    self.state = S::BeforeAttributeName;
                } else if data == Some('/') && appropriate {
                    self.current = Current::Tag {
                        name: self.buffer.clone(),
                        end: true,
                        self_closing: false,
                    };
                    self.state = S::SelfClosingStartTag;
                } else if data == Some('>') && appropriate {
                    self.current = Current::Tag {
                        name: self.buffer.clone(),
                        end: true,
                        self_closing: false,
                    };
                    self.emit_current_token();
                    self.state = S::Data;
                } else if let (true, Some(c)) = (is_letter(data), data) {
                    self.buffer.push(c);
                } else {
                    let s = format!("</{}", self.buffer);
                    self.chars_token(s);
                    self.unget(data);
                    self.state = back;
                }
            }
            S::ScriptDataLessThanSign => {
                let data = self.char();
                if data == Some('/') {
                    self.buffer.clear();
                    self.state = S::ScriptDataEndTagOpen;
                } else if data == Some('!') {
                    self.chars_token("<!".to_string());
                    self.state = S::ScriptDataEscapeStart;
                } else {
                    self.chars_token("<".to_string());
                    self.unget(data);
                    self.state = S::ScriptData;
                }
            }
            S::ScriptDataEscapeStart | S::ScriptDataEscapeStartDash => {
                let next = if self.state == S::ScriptDataEscapeStart {
                    S::ScriptDataEscapeStartDash
                } else {
                    S::ScriptDataEscapedDashDash
                };
                let data = self.char();
                if data == Some('-') {
                    self.chars_token("-".to_string());
                    self.state = next;
                } else {
                    self.unget(data);
                    self.state = S::ScriptData;
                }
            }
            S::ScriptDataEscaped => {
                let data = self.char();
                match data {
                    Some('-') => {
                        self.chars_token("-".to_string());
                        self.state = S::ScriptDataEscapedDash;
                    }
                    Some('<') => self.state = S::ScriptDataEscapedLessThanSign,
                    Some('\0') => self.chars_token("\u{FFFD}".to_string()),
                    None => self.state = S::Data,
                    Some(c) => {
                        let rest = self.chars_until(|c| c == '<' || c == '-' || c == '\0');
                        self.chars_token(format!("{c}{rest}"));
                    }
                }
            }
            S::ScriptDataEscapedDash => {
                let data = self.char();
                match data {
                    Some('-') => {
                        self.chars_token("-".to_string());
                        self.state = S::ScriptDataEscapedDashDash;
                    }
                    Some('<') => self.state = S::ScriptDataEscapedLessThanSign,
                    Some('\0') => {
                        self.chars_token("\u{FFFD}".to_string());
                        self.state = S::ScriptDataEscaped;
                    }
                    None => self.state = S::Data,
                    Some(c) => {
                        self.chars_token(c.to_string());
                        self.state = S::ScriptDataEscaped;
                    }
                }
            }
            S::ScriptDataEscapedDashDash => {
                let data = self.char();
                match data {
                    Some('-') => self.chars_token("-".to_string()),
                    Some('<') => self.state = S::ScriptDataEscapedLessThanSign,
                    Some('>') => {
                        self.chars_token(">".to_string());
                        self.state = S::ScriptData;
                    }
                    Some('\0') => {
                        self.chars_token("\u{FFFD}".to_string());
                        self.state = S::ScriptDataEscaped;
                    }
                    None => self.state = S::Data,
                    Some(c) => {
                        self.chars_token(c.to_string());
                        self.state = S::ScriptDataEscaped;
                    }
                }
            }
            S::ScriptDataEscapedLessThanSign => {
                let data = self.char();
                if data == Some('/') {
                    self.buffer.clear();
                    self.state = S::ScriptDataEscapedEndTagOpen;
                } else if let (true, Some(c)) = (is_letter(data), data) {
                    self.chars_token(format!("<{c}"));
                    self.buffer.clear();
                    self.buffer.push(c);
                    self.state = S::ScriptDataDoubleEscapeStart;
                } else {
                    self.chars_token("<".to_string());
                    self.unget(data);
                    self.state = S::ScriptDataEscaped;
                }
            }
            S::ScriptDataEscapedEndTagOpen => {
                let data = self.char();
                if let (true, Some(c)) = (is_letter(data), data) {
                    self.buffer.clear();
                    self.buffer.push(c);
                    self.state = S::ScriptDataEscapedEndTagName;
                } else {
                    self.chars_token("</".to_string());
                    self.unget(data);
                    self.state = S::ScriptDataEscaped;
                }
            }
            S::ScriptDataDoubleEscapeStart | S::ScriptDataDoubleEscapeEnd => {
                let (if_script, otherwise) = if self.state == S::ScriptDataDoubleEscapeStart {
                    (S::ScriptDataDoubleEscaped, S::ScriptDataEscaped)
                } else {
                    (S::ScriptDataEscaped, S::ScriptDataDoubleEscaped)
                };
                let data = self.char();
                match data {
                    Some(c) if is_ws(data) || c == '/' || c == '>' => {
                        self.chars_token(c.to_string());
                        self.state = if self.buffer.to_lowercase() == "script" {
                            if_script
                        } else {
                            otherwise
                        };
                    }
                    Some(c) if is_letter(data) => {
                        self.chars_token(c.to_string());
                        self.buffer.push(c);
                    }
                    _ => {
                        self.unget(data);
                        self.state = if self.state == S::ScriptDataDoubleEscapeStart {
                            S::ScriptDataEscaped
                        } else {
                            S::ScriptDataDoubleEscaped
                        };
                    }
                }
            }
            S::ScriptDataDoubleEscaped => {
                let data = self.char();
                match data {
                    Some('-') => {
                        self.chars_token("-".to_string());
                        self.state = S::ScriptDataDoubleEscapedDash;
                    }
                    Some('<') => {
                        self.chars_token("<".to_string());
                        self.state = S::ScriptDataDoubleEscapedLessThanSign;
                    }
                    Some('\0') => self.chars_token("\u{FFFD}".to_string()),
                    None => self.state = S::Data,
                    Some(c) => self.chars_token(c.to_string()),
                }
            }
            S::ScriptDataDoubleEscapedDash => {
                let data = self.char();
                match data {
                    Some('-') => {
                        self.chars_token("-".to_string());
                        self.state = S::ScriptDataDoubleEscapedDashDash;
                    }
                    Some('<') => {
                        self.chars_token("<".to_string());
                        self.state = S::ScriptDataDoubleEscapedLessThanSign;
                    }
                    Some('\0') => {
                        self.chars_token("\u{FFFD}".to_string());
                        self.state = S::ScriptDataDoubleEscaped;
                    }
                    None => self.state = S::Data,
                    Some(c) => {
                        self.chars_token(c.to_string());
                        self.state = S::ScriptDataDoubleEscaped;
                    }
                }
            }
            S::ScriptDataDoubleEscapedDashDash => {
                let data = self.char();
                match data {
                    Some('-') => self.chars_token("-".to_string()),
                    Some('<') => {
                        self.chars_token("<".to_string());
                        self.state = S::ScriptDataDoubleEscapedLessThanSign;
                    }
                    Some('>') => {
                        self.chars_token(">".to_string());
                        self.state = S::ScriptData;
                    }
                    Some('\0') => {
                        self.chars_token("\u{FFFD}".to_string());
                        self.state = S::ScriptDataDoubleEscaped;
                    }
                    None => self.state = S::Data,
                    Some(c) => {
                        self.chars_token(c.to_string());
                        self.state = S::ScriptDataDoubleEscaped;
                    }
                }
            }
            S::ScriptDataDoubleEscapedLessThanSign => {
                let data = self.char();
                if data == Some('/') {
                    self.chars_token("/".to_string());
                    self.buffer.clear();
                    self.state = S::ScriptDataDoubleEscapeEnd;
                } else {
                    self.unget(data);
                    self.state = S::ScriptDataDoubleEscaped;
                }
            }
            S::BeforeAttributeName => {
                let data = self.char();
                match data {
                    _ if is_ws(data) => {
                        self.chars_until(|c| !is_space_char(c));
                    }
                    Some(c) if is_letter(data) => {
                        self.add_attribute(&c.to_string());
                        self.state = S::AttributeName;
                    }
                    Some('>') => self.emit_current_token(),
                    Some('/') => self.state = S::SelfClosingStartTag,
                    None => self.state = S::Data,
                    Some(c @ ('\'' | '"' | '=' | '<')) => {
                        self.add_attribute(&c.to_string());
                        self.state = S::AttributeName;
                    }
                    Some('\0') => {
                        self.add_attribute("\u{FFFD}");
                        self.state = S::AttributeName;
                    }
                    Some(c) => {
                        self.add_attribute(&c.to_string());
                        self.state = S::AttributeName;
                    }
                }
            }
            S::AttributeName => {
                let data = self.char();
                let mut leaving = true;
                let mut emit = false;
                match data {
                    Some('=') => self.state = S::BeforeAttributeValue,
                    Some(c) if is_letter(data) => {
                        self.attribute_name.push(c);
                        let rest = self.chars_until(|c| !c.is_ascii_alphabetic());
                        self.attribute_name.push_str(&rest);
                        leaving = false;
                    }
                    Some('>') => emit = true,
                    _ if is_ws(data) => self.state = S::AfterAttributeName,
                    Some('/') => self.state = S::SelfClosingStartTag,
                    Some('\0') => {
                        self.attribute_name.push('\u{FFFD}');
                        leaving = false;
                    }
                    None => self.state = S::Data,
                    Some(c) => {
                        self.attribute_name.push(c);
                        leaving = false;
                    }
                }
                if leaving {
                    self.mark_attribute_end();
                    let name = ascii_lower(&self.attribute_name);
                    if let Some(last) = self.attributes.as_mut().and_then(|a| a.last_mut()) {
                        last.0 = Some(name);
                    }
                    if emit {
                        self.emit_current_token();
                    }
                }
            }
            S::AfterAttributeName => {
                let data = self.char();
                match data {
                    _ if is_ws(data) => {
                        self.chars_until(|c| !is_space_char(c));
                    }
                    Some('=') => self.state = S::BeforeAttributeValue,
                    Some('>') => self.emit_current_token(),
                    Some(c) if is_letter(data) => {
                        self.add_attribute(&c.to_string());
                        self.state = S::AttributeName;
                    }
                    Some('/') => self.state = S::SelfClosingStartTag,
                    Some('\0') => {
                        self.add_attribute("\u{FFFD}");
                        self.state = S::AttributeName;
                    }
                    None => self.state = S::Data,
                    Some(c) => {
                        self.add_attribute(&c.to_string());
                        self.state = S::AttributeName;
                    }
                }
            }
            S::BeforeAttributeValue => {
                let data = self.char();
                match data {
                    _ if is_ws(data) => {
                        self.chars_until(|c| !is_space_char(c));
                    }
                    Some('"') => self.state = S::AttributeValueDoubleQuoted,
                    Some('&') => {
                        self.state = S::AttributeValueUnQuoted;
                        self.unget(data);
                    }
                    Some('\'') => self.state = S::AttributeValueSingleQuoted,
                    Some('>') => self.emit_current_token(),
                    Some('\0') => {
                        self.attribute_value.push('\u{FFFD}');
                        self.state = S::AttributeValueUnQuoted;
                    }
                    None => self.state = S::Data,
                    Some(c) => {
                        self.attribute_value.push(c);
                        self.state = S::AttributeValueUnQuoted;
                    }
                }
            }
            S::AttributeValueDoubleQuoted | S::AttributeValueSingleQuoted => {
                let quote = if self.state == S::AttributeValueDoubleQuoted {
                    '"'
                } else {
                    '\''
                };
                let data = self.char();
                match data {
                    Some(c) if c == quote => {
                        self.mark_attribute_end();
                        self.state = S::AfterAttributeValue;
                    }
                    Some('&') => self.consume_entity(Some(quote), true)?,
                    Some('\0') => self.attribute_value.push('\u{FFFD}'),
                    None => {
                        self.mark_attribute_end();
                        self.state = S::Data;
                    }
                    Some(c) => {
                        self.attribute_value.push(c);
                        let rest = self.chars_until(|c| c == quote || c == '&');
                        self.attribute_value.push_str(&rest);
                    }
                }
            }
            S::AttributeValueUnQuoted => {
                let data = self.char();
                match data {
                    _ if is_ws(data) => {
                        self.mark_attribute_end();
                        self.state = S::BeforeAttributeName;
                    }
                    Some('&') => self.consume_entity(Some('>'), true)?,
                    Some('>') => {
                        self.mark_attribute_end();
                        self.emit_current_token();
                    }
                    None => {
                        self.mark_attribute_end();
                        self.state = S::Data;
                    }
                    Some(c @ ('"' | '\'' | '=' | '<' | '`')) => self.attribute_value.push(c),
                    Some('\0') => self.attribute_value.push('\u{FFFD}'),
                    Some(c) => {
                        self.attribute_value.push(c);
                        let rest = self.chars_until(|c| {
                            matches!(c, '&' | '>' | '"' | '\'' | '=' | '<' | '`')
                                || is_space_char(c)
                        });
                        self.attribute_value.push_str(&rest);
                    }
                }
            }
            S::AfterAttributeValue => {
                let data = self.char();
                match data {
                    _ if is_ws(data) => self.state = S::BeforeAttributeName,
                    Some('>') => self.emit_current_token(),
                    Some('/') => self.state = S::SelfClosingStartTag,
                    None => {
                        self.unget(data);
                        self.state = S::Data;
                    }
                    _ => {
                        self.unget(data);
                        self.state = S::BeforeAttributeName;
                    }
                }
            }
            S::SelfClosingStartTag => {
                let data = self.char();
                match data {
                    Some('>') => {
                        if let Current::Tag { self_closing, .. } = &mut self.current {
                            *self_closing = true;
                        }
                        self.emit_current_token();
                    }
                    None => {
                        self.unget(data);
                        self.state = S::Data;
                    }
                    _ => {
                        self.unget(data);
                        self.state = S::BeforeAttributeName;
                    }
                }
            }
            S::BogusComment => {
                let data = self.chars_until(|c| c == '>').replace('\0', "\u{FFFD}");
                self.add(Token::Comment(data));
                self.char();
                self.state = S::Data;
            }
            S::MarkupDeclarationOpen => {
                let mut stack: Vec<Option<char>> = vec![self.char()];
                let last = stack[0];
                if last == Some('-') {
                    let c = self.char();
                    stack.push(c);
                    if c == Some('-') {
                        self.current = Current::Comment(String::new());
                        self.state = S::CommentStart;
                        return Ok(true);
                    }
                } else if last == Some('d') || last == Some('D') {
                    let mut matched = true;
                    for expected in ["oO", "cC", "tT", "yY", "pP", "eE"] {
                        let c = self.char();
                        stack.push(c);
                        match c {
                            Some(ch) if expected.contains(ch) => {}
                            _ => {
                                matched = false;
                                break;
                            }
                        }
                    }
                    if matched {
                        self.current = Current::Doctype(Doctype {
                            name: String::new(),
                            public_id: None,
                            system_id: None,
                            correct: true,
                        });
                        self.state = S::Doctype;
                        return Ok(true);
                    }
                } else if last == Some('[') && self.cdata_allowed {
                    let mut matched = true;
                    for expected in ['C', 'D', 'A', 'T', 'A', '['] {
                        let c = self.char();
                        stack.push(c);
                        if c != Some(expected) {
                            matched = false;
                            break;
                        }
                    }
                    if matched {
                        self.state = S::CdataSection;
                        return Ok(true);
                    }
                }
                while let Some(c) = stack.pop() {
                    self.unget(c);
                }
                self.state = S::BogusComment;
            }
            S::CommentStart => {
                let data = self.char();
                match data {
                    Some('-') => self.state = S::CommentStartDash,
                    Some('\0') => self.comment_add("\u{FFFD}"),
                    Some('>') | None => {
                        self.emit_current_string_like();
                        self.state = S::Data;
                    }
                    Some(c) => {
                        self.comment_add(&c.to_string());
                        self.state = S::Comment;
                    }
                }
            }
            S::CommentStartDash => {
                let data = self.char();
                match data {
                    Some('-') => self.state = S::CommentEnd,
                    Some('\0') => self.comment_add("-\u{FFFD}"),
                    Some('>') | None => {
                        self.emit_current_string_like();
                        self.state = S::Data;
                    }
                    Some(c) => {
                        self.comment_add("-");
                        self.comment_add(&c.to_string());
                        self.state = S::Comment;
                    }
                }
            }
            S::Comment => {
                let data = self.char();
                match data {
                    Some('-') => self.state = S::CommentEndDash,
                    Some('\0') => self.comment_add("\u{FFFD}"),
                    None => {
                        self.emit_current_string_like();
                        self.state = S::Data;
                    }
                    Some(c) => {
                        self.comment_add(&c.to_string());
                        let rest = self.chars_until(|c| c == '-' || c == '\0');
                        self.comment_add(&rest);
                    }
                }
            }
            S::CommentEndDash => {
                let data = self.char();
                match data {
                    Some('-') => self.state = S::CommentEnd,
                    Some('\0') => {
                        self.comment_add("-\u{FFFD}");
                        self.state = S::Comment;
                    }
                    None => {
                        self.emit_current_string_like();
                        self.state = S::Data;
                    }
                    Some(c) => {
                        self.comment_add("-");
                        self.comment_add(&c.to_string());
                        self.state = S::Comment;
                    }
                }
            }
            S::CommentEnd => {
                let data = self.char();
                match data {
                    Some('>') => {
                        self.emit_current_string_like();
                        self.state = S::Data;
                    }
                    Some('\0') => {
                        self.comment_add("--\u{FFFD}");
                        self.state = S::Comment;
                    }
                    Some('!') => self.state = S::CommentEndBang,
                    Some('-') => self.comment_add("-"),
                    None => {
                        self.emit_current_string_like();
                        self.state = S::Data;
                    }
                    Some(c) => {
                        self.comment_add("--");
                        self.comment_add(&c.to_string());
                        self.state = S::Comment;
                    }
                }
            }
            S::CommentEndBang => {
                let data = self.char();
                match data {
                    Some('>') => {
                        self.emit_current_string_like();
                        self.state = S::Data;
                    }
                    Some('-') => {
                        self.comment_add("--!");
                        self.state = S::CommentEndDash;
                    }
                    Some('\0') => {
                        self.comment_add("--!\u{FFFD}");
                        self.state = S::Comment;
                    }
                    None => {
                        self.emit_current_string_like();
                        self.state = S::Data;
                    }
                    Some(c) => {
                        self.comment_add("--!");
                        self.comment_add(&c.to_string());
                        self.state = S::Comment;
                    }
                }
            }
            S::Doctype => {
                let data = self.char();
                if is_ws(data) {
                    self.state = S::BeforeDoctypeName;
                } else if data.is_none() {
                    self.doctype().correct = false;
                    self.emit_current_string_like();
                    self.state = S::Data;
                } else {
                    self.unget(data);
                    self.state = S::BeforeDoctypeName;
                }
            }
            S::BeforeDoctypeName => {
                let data = self.char();
                match data {
                    _ if is_ws(data) => {}
                    Some('>') | None => {
                        self.doctype().correct = false;
                        self.emit_current_string_like();
                        self.state = S::Data;
                    }
                    Some('\0') => {
                        self.doctype().name = "\u{FFFD}".to_string();
                        self.state = S::DoctypeName;
                    }
                    Some(c) => {
                        self.doctype().name = c.to_string();
                        self.state = S::DoctypeName;
                    }
                }
            }
            S::DoctypeName => {
                let data = self.char();
                match data {
                    _ if is_ws(data) => {
                        let d = self.doctype();
                        d.name = ascii_lower(&d.name);
                        self.state = S::AfterDoctypeName;
                    }
                    Some('>') => {
                        let d = self.doctype();
                        d.name = ascii_lower(&d.name);
                        self.emit_current_string_like();
                        self.state = S::Data;
                    }
                    Some('\0') => {
                        self.doctype().name.push('\u{FFFD}');
                        self.state = S::DoctypeName;
                    }
                    None => {
                        let d = self.doctype();
                        d.correct = false;
                        d.name = ascii_lower(&d.name);
                        self.emit_current_string_like();
                        self.state = S::Data;
                    }
                    Some(c) => self.doctype().name.push(c),
                }
            }
            S::AfterDoctypeName => {
                let mut data = self.char();
                if is_ws(data) {
                    return Ok(true);
                } else if data == Some('>') {
                    self.emit_current_string_like();
                    self.state = S::Data;
                } else if data.is_none() {
                    self.doctype().correct = false;
                    self.unget(data);
                    self.emit_current_string_like();
                    self.state = S::Data;
                } else {
                    let keyword: Option<(&[&str], State)> = match data {
                        Some('p' | 'P') => Some((
                            &["uU", "bB", "lL", "iI", "cC"],
                            S::AfterDoctypePublicKeyword,
                        )),
                        Some('s' | 'S') => Some((
                            &["yY", "sS", "tT", "eE", "mM"],
                            S::AfterDoctypeSystemKeyword,
                        )),
                        _ => None,
                    };
                    if let Some((expected, next)) = keyword {
                        let mut matched = true;
                        for e in expected {
                            data = self.char();
                            match data {
                                Some(ch) if e.contains(ch) => {}
                                _ => {
                                    matched = false;
                                    break;
                                }
                            }
                        }
                        if matched {
                            self.state = next;
                            return Ok(true);
                        }
                    }
                    self.unget(data);
                    self.doctype().correct = false;
                    self.state = S::BogusDoctype;
                }
            }
            S::AfterDoctypePublicKeyword | S::AfterDoctypeSystemKeyword => {
                let next = if self.state == S::AfterDoctypePublicKeyword {
                    S::BeforeDoctypePublicIdentifier
                } else {
                    S::BeforeDoctypeSystemIdentifier
                };
                let data = self.char();
                match data {
                    _ if is_ws(data) => self.state = next,
                    Some('\'' | '"') => {
                        self.unget(data);
                        self.state = next;
                    }
                    None => {
                        self.doctype().correct = false;
                        self.emit_current_string_like();
                        self.state = S::Data;
                    }
                    _ => {
                        self.unget(data);
                        self.state = next;
                    }
                }
            }
            S::BeforeDoctypePublicIdentifier | S::BeforeDoctypeSystemIdentifier => {
                let public = self.state == S::BeforeDoctypePublicIdentifier;
                let data = self.char();
                match data {
                    _ if is_ws(data) => {}
                    Some(q @ ('"' | '\'')) => {
                        let d = self.doctype();
                        if public {
                            d.public_id = Some(String::new());
                        } else {
                            d.system_id = Some(String::new());
                        }
                        self.state = match (public, q) {
                            (true, '"') => S::DoctypePublicIdentifierDoubleQuoted,
                            (true, _) => S::DoctypePublicIdentifierSingleQuoted,
                            (false, '"') => S::DoctypeSystemIdentifierDoubleQuoted,
                            (false, _) => S::DoctypeSystemIdentifierSingleQuoted,
                        };
                    }
                    Some('>') | None => {
                        self.doctype().correct = false;
                        self.emit_current_string_like();
                        self.state = S::Data;
                    }
                    _ => {
                        self.doctype().correct = false;
                        self.state = S::BogusDoctype;
                    }
                }
            }
            S::DoctypePublicIdentifierDoubleQuoted
            | S::DoctypePublicIdentifierSingleQuoted
            | S::DoctypeSystemIdentifierDoubleQuoted
            | S::DoctypeSystemIdentifierSingleQuoted => {
                let (public, quote) = match self.state {
                    S::DoctypePublicIdentifierDoubleQuoted => (true, '"'),
                    S::DoctypePublicIdentifierSingleQuoted => (true, '\''),
                    S::DoctypeSystemIdentifierDoubleQuoted => (false, '"'),
                    _ => (false, '\''),
                };
                let data = self.char();
                match data {
                    Some(c) if c == quote => {
                        self.state = if public {
                            S::AfterDoctypePublicIdentifier
                        } else {
                            S::AfterDoctypeSystemIdentifier
                        };
                    }
                    Some('>') | None => {
                        self.doctype().correct = false;
                        self.emit_current_string_like();
                        self.state = S::Data;
                    }
                    Some(c) => {
                        let c = if c == '\0' { '\u{FFFD}' } else { c };
                        let d = self.doctype();
                        let id = if public {
                            &mut d.public_id
                        } else {
                            &mut d.system_id
                        };
                        id.get_or_insert_with(String::new).push(c);
                    }
                }
            }
            S::AfterDoctypePublicIdentifier | S::BetweenDoctypePublicAndSystemIdentifiers => {
                let after = self.state == S::AfterDoctypePublicIdentifier;
                let data = self.char();
                match data {
                    _ if is_ws(data) => {
                        if after {
                            self.state = S::BetweenDoctypePublicAndSystemIdentifiers;
                        }
                    }
                    Some('>') => {
                        self.emit_current_string_like();
                        self.state = S::Data;
                    }
                    Some(q @ ('"' | '\'')) => {
                        self.doctype().system_id = Some(String::new());
                        self.state = if q == '"' {
                            S::DoctypeSystemIdentifierDoubleQuoted
                        } else {
                            S::DoctypeSystemIdentifierSingleQuoted
                        };
                    }
                    None => {
                        self.doctype().correct = false;
                        self.emit_current_string_like();
                        self.state = S::Data;
                    }
                    _ => {
                        self.doctype().correct = false;
                        self.state = S::BogusDoctype;
                    }
                }
            }
            S::AfterDoctypeSystemIdentifier => {
                let data = self.char();
                match data {
                    _ if is_ws(data) => {}
                    Some('>') => {
                        self.emit_current_string_like();
                        self.state = S::Data;
                    }
                    None => {
                        self.doctype().correct = false;
                        self.emit_current_string_like();
                        self.state = S::Data;
                    }
                    _ => self.state = S::BogusDoctype,
                }
            }
            S::BogusDoctype => {
                let data = self.char();
                if data == Some('>') {
                    self.emit_current_string_like();
                    self.state = S::Data;
                } else if data.is_none() {
                    self.unget(data);
                    self.emit_current_string_like();
                    self.state = S::Data;
                }
            }
            S::CdataSection => {
                let mut data: Vec<char> = Vec::new();
                let mut matched_end = 0;
                while let Some(mut ch) = self.char() {
                    if ch == '\0' {
                        ch = '\u{FFFD}';
                    }
                    data.push(ch);
                    if ch == ']' && matched_end < 2 {
                        matched_end += 1;
                    } else if ch == '>' && matched_end == 2 {
                        data.truncate(data.len() - 3);
                        break;
                    } else {
                        matched_end = 0;
                    }
                }
                if !data.is_empty() {
                    self.chars_token(data.into_iter().collect());
                }
                self.state = S::Data;
            }
        }
        Ok(true)
    }
}
