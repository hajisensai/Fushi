//! 弹弹play JSON：复刻 Dart VM `jsonDecode`（Dart SDK 3.47.6
//! `lib/_internal/vm/lib/convert_patch.dart` 的 `_JsonStringParser`，整份输入是一个 chunk）。
//!
//! 状态机、错误位置与错误文案都与 SDK 源码一一对应（`fail(position, message)`），
//! 所以 Dart 侧能抛出与旧实现相同的 `FormatException(message, source, offset)`。
//! 值语义：
//! - 没有 `.` / `e` 且在 int64 内的数是 int；否则 double。`-0` 是 int 0，`-0.0` 是 -0.0。
//! - double 一般正确舍入；但**指数位数值超过 400** 时按 SDK 的捷径直接给 ±0.0 / ±Infinity
//!   （尾数为 0 或指数为负给 0），不看尾数大小——照抄。
//! - 对象重复键：位置取首次出现、值取最后一次（`_populateUnsafe` 逐对 `_set`）。
//! - 字符串：`\u` 转义按单个码元写入（孤立代理照收），未转义的 U+0000–U+001F 是错误。
//!
//! 值存在一个扁平 arena 里（不递归建树 / 析构），深层嵌套不会爆原生栈。

use super::danmaku_dart::{push_ascii, units_eq_ascii, write_double, write_int};

/// 与 Dart `fail()` 的文案一一对应（数值即 FFI 里的错误码）。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u32)]
pub enum JsonErrorKind {
    UnexpectedCharacter = 1,
    UnexpectedEndOfInput = 2,
    UnterminatedString = 3,
    ControlCharacterInString = 4,
    MissingExpectedDigit = 5,
    InvalidUnicodeEscape = 6,
    UnrecognizedStringEscape = 7,
    UnterminatedNumberLiteral = 8,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct JsonError {
    pub kind: JsonErrorKind,
    pub offset: usize,
}

/// 字符串：输入里的一段（无转义）或 [JsonDoc::pool] 里的一段（有转义）。
#[derive(Clone, Copy, Debug)]
pub struct StrRef {
    pub pooled: bool,
    pub start: u32,
    pub len: u32,
}

#[derive(Clone, Copy, Debug)]
pub enum Node {
    Null,
    Bool(bool),
    Int(i64),
    Double(f64),
    Str(StrRef),
    /// `list_items[start..start + len]`。
    List {
        start: u32,
        len: u32,
    },
    /// `map_entries[start..start + len]`（已去重）。
    Map {
        start: u32,
        len: u32,
    },
}

pub struct JsonDoc<'a> {
    input: &'a [u16],
    pool: Vec<u16>,
    nodes: Vec<Node>,
    list_items: Vec<u32>,
    map_entries: Vec<(StrRef, u32)>,
    root: u32,
}

impl<'a> JsonDoc<'a> {
    pub fn root(&self) -> Node {
        self.nodes[self.root as usize]
    }

    /// 带转义字符串的拼接池（[StrRef::pooled] 指向这里）。
    pub fn pool_units(&self) -> &[u16] {
        &self.pool
    }

    pub fn node(&self, id: u32) -> Node {
        self.nodes[id as usize]
    }

    pub fn str_units(&self, r: StrRef) -> &[u16] {
        str_slice(self.input, &self.pool, r)
    }

    pub fn list(&self, start: u32, len: u32) -> &[u32] {
        &self.list_items[start as usize..(start + len) as usize]
    }

    /// `map[key]`：没有该键返回 `None`（JSON null 是 `Some(Node::Null)`）。
    pub fn map_get(&self, start: u32, len: u32, key: &[u8]) -> Option<Node> {
        self.map_entries[start as usize..(start + len) as usize]
            .iter()
            .find(|(k, _)| units_eq_ascii(self.str_units(*k), key))
            .map(|&(_, v)| self.nodes[v as usize])
    }

    /// Dart `value.toString()`（`Map` → `{k: v, …}`，`List` → `[a, b]`，字符串不加引号），
    /// 追加到 [out]。显式栈，不递归。
    pub fn write_dart_string(&self, node: Node, out: &mut Vec<u16>) {
        enum Work {
            Node(Node),
            Str(StrRef),
            Lit(&'static str),
        }
        let mut stack = vec![Work::Node(node)];
        while let Some(work) = stack.pop() {
            match work {
                Work::Lit(s) => push_ascii(out, s),
                Work::Str(r) => out.extend_from_slice(self.str_units(r)),
                Work::Node(n) => match n {
                    Node::Null => push_ascii(out, "null"),
                    Node::Bool(b) => push_ascii(out, if b { "true" } else { "false" }),
                    Node::Int(i) => write_int(i, out),
                    Node::Double(d) => write_double(d, out),
                    Node::Str(r) => out.extend_from_slice(self.str_units(r)),
                    Node::List { start, len } => {
                        out.push(b'[' as u16);
                        stack.push(Work::Lit("]"));
                        let items = self.list(start, len);
                        for (i, &id) in items.iter().enumerate().rev() {
                            stack.push(Work::Node(self.nodes[id as usize]));
                            if i > 0 {
                                stack.push(Work::Lit(", "));
                            }
                        }
                    }
                    Node::Map { start, len } => {
                        out.push(b'{' as u16);
                        stack.push(Work::Lit("}"));
                        let entries = &self.map_entries[start as usize..(start + len) as usize];
                        for (i, &(k, v)) in entries.iter().enumerate().rev() {
                            stack.push(Work::Node(self.nodes[v as usize]));
                            stack.push(Work::Lit(": "));
                            stack.push(Work::Str(k));
                            if i > 0 {
                                stack.push(Work::Lit(", "));
                            }
                        }
                    }
                },
            }
        }
    }
}

// 状态常量（与 SDK 同名同值）。
const INSIDE_ARRAY: u8 = 1;
const INSIDE_OBJECT: u8 = 2;
const AFTER_COLON: u8 = 3;
const ALLOW_STRING_MASK: u8 = 8;
const ALLOW_VALUE_MASK: u8 = 4;
const STRING_ONLY: u8 = 4;
const NO_VALUES: u8 = 12;
const NON_EMPTY: u8 = 16;
const STATE_INITIAL: u8 = 0;
const STATE_END: u8 = NON_EMPTY | NO_VALUES;
const STATE_ARRAY_EMPTY: u8 = INSIDE_ARRAY;
const STATE_ARRAY_VALUE: u8 = INSIDE_ARRAY | NON_EMPTY | NO_VALUES;
const STATE_ARRAY_COMMA: u8 = INSIDE_ARRAY | NON_EMPTY;
const STATE_OBJECT_EMPTY: u8 = INSIDE_OBJECT | STRING_ONLY;
const STATE_OBJECT_KEY: u8 = INSIDE_OBJECT | NON_EMPTY | NO_VALUES;
const STATE_OBJECT_COLON: u8 = AFTER_COLON | NON_EMPTY;
const STATE_OBJECT_VALUE: u8 = AFTER_COLON | NON_EMPTY | NO_VALUES;
const STATE_OBJECT_COMMA: u8 = INSIDE_OBJECT | NON_EMPTY | STRING_ONLY;
const VALUE_READ_BITS: u8 = NON_EMPTY | NO_VALUES;

const QUOTE: u16 = 0x22;
const BACKSLASH: u16 = 0x5C;
const SPACE: u16 = 0x20;
const MINUS: u32 = 0x2D;
const DECIMAL_POINT: u32 = 0x2E;
const CHAR_E_LOWER: u32 = 0x65;

const POWERS_OF_TEN: [f64; 23] = [
    1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11, 1e12, 1e13, 1e14, 1e15, 1e16,
    1e17, 1e18, 1e19, 1e20, 1e21, 1e22,
];

/// 输入在 chunk 末尾停在半个记号里（SDK 的 partial state）。
#[derive(Clone, Copy, PartialEq, Eq)]
enum Partial {
    None,
    String,
    Keyword,
    /// 数字停在可以收尾的状态（`NUM_ZERO` / `NUM_DIGIT` / `NUM_DOT_DIGIT` / `NUM_E_DIGIT`）。
    NumberComplete,
    /// 数字停在不能收尾的状态（`NUM_SIGN` / `NUM_DOT` / `NUM_E` / `NUM_E_SIGN`）。
    NumberIncomplete,
}

struct Parser<'a> {
    s: &'a [u16],
    pool: Vec<u16>,
    nodes: Vec<Node>,
    list_items: Vec<u32>,
    map_entries: Vec<(StrRef, u32)>,
    /// 打开中的容器已读到的子值（对象按 键, 值 交替）。
    scratch: Vec<u32>,
    marks: Vec<usize>,
    states: Vec<u8>,
    value: u32,
    partial: Partial,
    /// 正在 [pool] 里拼的字符串起点。
    string_start: usize,
}

type Step = Result<usize, JsonError>;

impl<'a> Parser<'a> {
    fn fail<T>(&self, position: usize, kind: Option<JsonErrorKind>) -> Result<T, JsonError> {
        let kind = kind.unwrap_or(if position == self.s.len() {
            JsonErrorKind::UnexpectedEndOfInput
        } else {
            JsonErrorKind::UnexpectedCharacter
        });
        Err(JsonError {
            kind,
            offset: position,
        })
    }

    fn push_value(&mut self, node: Node) {
        self.nodes.push(node);
        self.value = (self.nodes.len() - 1) as u32;
    }

    fn parse(&mut self) -> Result<(), JsonError> {
        let s = self.s;
        let length = s.len();
        let mut state = STATE_INITIAL;
        let mut position = 0usize;
        'outer: while position < length {
            let mut ch;
            loop {
                ch = s[position];
                if ch > 0xFF || !matches!(ch, 0x20 | 0x0D | 0x0A | 0x09) {
                    break;
                }
                position += 1;
                if position >= length {
                    break 'outer;
                }
            }
            match ch {
                0x22 => {
                    if state & ALLOW_STRING_MASK != 0 {
                        return self.fail(position, None);
                    }
                    state |= VALUE_READ_BITS;
                    position = self.parse_string(position + 1)?;
                }
                0x5B => {
                    if state & ALLOW_VALUE_MASK != 0 {
                        return self.fail(position, None);
                    }
                    self.marks.push(self.scratch.len());
                    self.states.push(state);
                    state = STATE_ARRAY_EMPTY;
                    position += 1;
                }
                0x7B => {
                    if state & ALLOW_VALUE_MASK != 0 {
                        return self.fail(position, None);
                    }
                    self.marks.push(self.scratch.len());
                    self.states.push(state);
                    state = STATE_OBJECT_EMPTY;
                    position += 1;
                }
                0x6E => {
                    if state & ALLOW_VALUE_MASK != 0 {
                        return self.fail(position, None);
                    }
                    state |= VALUE_READ_BITS;
                    position = self.parse_keyword(position, b"null", Node::Null)?;
                }
                0x66 => {
                    if state & ALLOW_VALUE_MASK != 0 {
                        return self.fail(position, None);
                    }
                    state |= VALUE_READ_BITS;
                    position = self.parse_keyword(position, b"false", Node::Bool(false))?;
                }
                0x74 => {
                    if state & ALLOW_VALUE_MASK != 0 {
                        return self.fail(position, None);
                    }
                    state |= VALUE_READ_BITS;
                    position = self.parse_keyword(position, b"true", Node::Bool(true))?;
                }
                0x3A => {
                    if state != STATE_OBJECT_KEY {
                        return self.fail(position, None);
                    }
                    self.scratch.push(self.value);
                    state = STATE_OBJECT_COLON;
                    position += 1;
                }
                0x2C => {
                    if state == STATE_OBJECT_VALUE {
                        self.scratch.push(self.value);
                        state = STATE_OBJECT_COMMA;
                        position += 1;
                    } else if state == STATE_ARRAY_VALUE {
                        self.scratch.push(self.value);
                        state = STATE_ARRAY_COMMA;
                        position += 1;
                    } else {
                        return self.fail(position, None);
                    }
                }
                0x5D => {
                    if state == STATE_ARRAY_EMPTY {
                        self.end_array();
                    } else if state == STATE_ARRAY_VALUE {
                        self.scratch.push(self.value);
                        self.end_array();
                    } else {
                        return self.fail(position, None);
                    }
                    state = self.states.pop().expect("array state pushed") | VALUE_READ_BITS;
                    position += 1;
                }
                0x7D => {
                    if state == STATE_OBJECT_EMPTY {
                        self.end_object();
                    } else if state == STATE_OBJECT_VALUE {
                        self.scratch.push(self.value);
                        self.end_object();
                    } else {
                        return self.fail(position, None);
                    }
                    state = self.states.pop().expect("object state pushed") | VALUE_READ_BITS;
                    position += 1;
                }
                _ => {
                    if state & ALLOW_VALUE_MASK != 0 {
                        return self.fail(position, None);
                    }
                    state |= VALUE_READ_BITS;
                    position = self.parse_number(ch, position)?;
                }
            }
        }
        // close()
        match self.partial {
            Partial::None => {}
            Partial::String => return self.fail(length, Some(JsonErrorKind::UnterminatedString)),
            Partial::Keyword => return self.fail(length, None),
            Partial::NumberIncomplete => {
                return self.fail(length, Some(JsonErrorKind::UnterminatedNumberLiteral))
            }
            // 能收尾的数字只可能是顶层标量（在容器里随后必然因缺括号失败）；它的值不影响
            // 弹幕结果（根不是对象即形状错误），这里放一个占位 int。
            Partial::NumberComplete => self.push_value(Node::Int(0)),
        }
        if state != STATE_END {
            return self.fail(length, None);
        }
        Ok(())
    }

    fn end_array(&mut self) {
        let mark = self.marks.pop().expect("array mark pushed");
        let start = self.list_items.len() as u32;
        let len = (self.scratch.len() - mark) as u32;
        self.list_items.extend(self.scratch.drain(mark..));
        self.push_value(Node::List { start, len });
    }

    fn end_object(&mut self) {
        let mark = self.marks.pop().expect("object mark pushed");
        let start = self.map_entries.len();
        let out = dedupe_pairs(&self.scratch[mark..], &self.nodes, self.s, &self.pool);
        let len = out.len() as u32;
        self.map_entries.extend(out);
        self.scratch.truncate(mark);
        self.push_value(Node::Map {
            start: start as u32,
            len,
        });
    }

    fn parse_keyword(&mut self, position: usize, word: &[u8], node: Node) -> Step {
        let s = self.s;
        let length = s.len();
        if length < position + word.len() {
            // parseKeywordPrefix
            let start = position;
            let mut p = position + 1;
            let mut count = 1;
            while p < length {
                if s[p] != u16::from(word[count]) {
                    return self.fail(start, None);
                }
                count += 1;
                p += 1;
            }
            self.partial = Partial::Keyword;
            return Ok(length);
        }
        for (i, &w) in word.iter().enumerate().skip(1) {
            if s[position + i] != u16::from(w) {
                return self.fail(position, None);
            }
        }
        self.push_value(node);
        Ok(position + word.len())
    }

    #[inline]
    fn is_simple_string_end(ch: u16) -> bool {
        ch < SPACE || ch == QUOTE || ch == BACKSLASH
    }

    fn parse_string(&mut self, position: usize) -> Step {
        let s = self.s;
        let end = s.len();
        let start = position;
        let mut position = position;
        if position < end {
            let mut ch: u16;
            loop {
                ch = s[position];
                position += 1;
                if ch <= 0xFF && Self::is_simple_string_end(ch) {
                    break;
                }
                if position >= end {
                    break;
                }
            }
            if ch == QUOTE {
                let slice_end = position - 1;
                self.push_value(Node::Str(StrRef {
                    pooled: false,
                    start: start as u32,
                    len: (slice_end - start) as u32,
                }));
                return Ok(slice_end + 1);
            }
            if ch == BACKSLASH {
                let slice_end = position - 1;
                self.string_start = self.pool.len();
                self.pool.extend_from_slice(&s[start..slice_end]);
                return self.parse_string_to_buffer(slice_end);
            }
            if ch < SPACE {
                return self.fail(position - 1, Some(JsonErrorKind::ControlCharacterInString));
            }
        }
        self.partial = Partial::String;
        Ok(end)
    }

    fn parse_string_to_buffer(&mut self, position: usize) -> Step {
        let s = self.s;
        let end = s.len();
        let mut position = position;
        let mut start = position;
        loop {
            if position == end {
                if position > start {
                    self.pool.extend_from_slice(&s[start..position]);
                }
                self.partial = Partial::String;
                return Ok(end);
            }
            let mut ch;
            loop {
                ch = s[position];
                position += 1;
                if ch <= 0xFF && Self::is_simple_string_end(ch) {
                    break;
                }
                if position >= end {
                    break;
                }
            }
            if ch < SPACE {
                return self.fail(position - 1, None);
            }
            if ch == QUOTE {
                let quote_position = position - 1;
                if quote_position > start {
                    self.pool.extend_from_slice(&s[start..quote_position]);
                }
                let string_start = self.string_start;
                self.push_value(Node::Str(StrRef {
                    pooled: true,
                    start: string_start as u32,
                    len: (self.pool.len() - string_start) as u32,
                }));
                return Ok(position);
            }
            if ch != BACKSLASH {
                continue;
            }
            if position - 1 > start {
                self.pool.extend_from_slice(&s[start..position - 1]);
            }
            if position == end {
                self.partial = Partial::String;
                return Ok(end);
            }
            position = self.parse_string_escape(position)?;
            if position == end {
                return Ok(position);
            }
            start = position;
        }
    }

    fn parse_string_escape(&mut self, position: usize) -> Step {
        let s = self.s;
        let length = s.len();
        let mut position = position;
        let mut ch = s[position];
        position += 1;
        match ch {
            0x62 => ch = 0x08,
            0x66 => ch = 0x0C,
            0x6E => ch = 0x0A,
            0x72 => ch = 0x0D,
            0x74 => ch = 0x09,
            0x2F | 0x5C | 0x22 => {}
            0x75 => {
                let hex_start = position - 1;
                let mut value: u32 = 0;
                for _ in 0..4 {
                    if position == length {
                        self.partial = Partial::String;
                        return Ok(length);
                    }
                    let c = u32::from(s[position]);
                    position += 1;
                    let digit = c ^ 0x30;
                    value *= 16;
                    if digit <= 9 {
                        value += digit;
                    } else {
                        let digit = ((c | 0x20) as i64) - 0x61;
                        if !(0..=5).contains(&digit) {
                            return self.fail(hex_start, Some(JsonErrorKind::InvalidUnicodeEscape));
                        }
                        value += digit as u32 + 10;
                    }
                }
                ch = value as u16;
            }
            _ => {
                if ch < SPACE {
                    return self.fail(position, Some(JsonErrorKind::ControlCharacterInString));
                }
                return self.fail(position, Some(JsonErrorKind::UnrecognizedStringEscape));
            }
        }
        self.pool.push(ch);
        if position == length {
            self.partial = Partial::String;
            return Ok(length);
        }
        Ok(position)
    }

    fn number_partial(&mut self, complete: bool) -> Step {
        self.partial = if complete {
            Partial::NumberComplete
        } else {
            Partial::NumberIncomplete
        };
        Ok(self.s.len())
    }

    fn parse_number(&mut self, first: u16, position: usize) -> Step {
        let s = self.s;
        let length = s.len();
        let start = position;
        let mut position = position;
        let mut ch = u32::from(first);
        let mut int_value: i64 = 0;
        let mut double_value: f64 = 0.0;
        let mut sign: i64 = 1;
        let mut is_double = false;
        if ch == MINUS {
            sign = -1;
            position += 1;
            if position == length {
                return self.number_partial(false); // NUM_SIGN
            }
            ch = u32::from(s[position]);
        }
        let mut digit = ch ^ 0x30;
        if digit > 9 {
            return if sign < 0 {
                self.fail(position, Some(JsonErrorKind::MissingExpectedDigit))
            } else {
                self.fail(position, None)
            };
        }
        if digit == 0 {
            position += 1;
            if position == length {
                return self.number_partial(true); // NUM_ZERO
            }
            ch = u32::from(s[position]);
            digit = ch ^ 0x30;
            if digit <= 9 {
                return self.fail(position, None);
            }
        } else {
            let mut digit_count = 0u32;
            loop {
                if digit_count >= 18 {
                    let mut high_digit = i64::from(digit >> 3);
                    if sign < 0 {
                        high_digit &= i64::from(digit);
                    }
                    if digit_count == 19 || int_value.wrapping_sub(high_digit) < -922337203685477580
                    {
                        is_double = true;
                        double_value = 9223372036854775808.0;
                    }
                }
                int_value = int_value.wrapping_mul(10).wrapping_sub(i64::from(digit));
                digit_count = digit_count.saturating_add(1);
                position += 1;
                if position == length {
                    return self.number_partial(true); // NUM_DIGIT
                }
                ch = u32::from(s[position]);
                digit = ch ^ 0x30;
                if digit > 9 {
                    break;
                }
            }
        }
        if ch == DECIMAL_POINT {
            if !is_double {
                is_double = true;
                double_value = if int_value == 0 {
                    0.0
                } else {
                    -(int_value as f64)
                };
            }
            int_value = 0;
            position += 1;
            if position == length {
                return self.number_partial(false); // NUM_DOT
            }
            ch = u32::from(s[position]);
            digit = ch ^ 0x30;
            if digit > 9 {
                return self.fail(position, None);
            }
            loop {
                double_value = 10.0 * double_value + f64::from(digit);
                int_value = int_value.wrapping_sub(1);
                position += 1;
                if position == length {
                    return self.number_partial(true); // NUM_DOT_DIGIT
                }
                ch = u32::from(s[position]);
                digit = ch ^ 0x30;
                if digit > 9 {
                    break;
                }
            }
        }
        if (ch | 0x20) == CHAR_E_LOWER {
            if !is_double {
                is_double = true;
                double_value = if int_value == 0 {
                    0.0
                } else {
                    -(int_value as f64)
                };
                int_value = 0;
            }
            position += 1;
            if position == length {
                return self.number_partial(false); // NUM_E
            }
            ch = u32::from(s[position]);
            let mut exp_sign: i64 = 1;
            let mut exponent: i64 = 0;
            if ((ch + 1) | 2) == 0x2E {
                exp_sign = 0x2C - i64::from(ch);
                position += 1;
                if position == length {
                    return self.number_partial(false); // NUM_E_SIGN
                }
                ch = u32::from(s[position]);
            }
            digit = ch ^ 0x30;
            if digit > 9 {
                return self.fail(position, Some(JsonErrorKind::MissingExpectedDigit));
            }
            let mut exponent_overflow = false;
            loop {
                exponent = exponent.wrapping_mul(10).wrapping_add(i64::from(digit));
                if exponent > 400 {
                    exponent_overflow = true;
                }
                position += 1;
                if position == length {
                    return self.number_partial(true); // NUM_E_DIGIT
                }
                ch = u32::from(s[position]);
                digit = ch ^ 0x30;
                if digit > 9 {
                    break;
                }
            }
            if exponent_overflow {
                let value = if double_value == 0.0 || exp_sign < 0 {
                    if sign < 0 {
                        -0.0
                    } else {
                        0.0
                    }
                } else if sign < 0 {
                    f64::NEG_INFINITY
                } else {
                    f64::INFINITY
                };
                self.push_value(Node::Double(value));
                return Ok(position);
            }
            int_value = int_value.wrapping_add(exp_sign.wrapping_mul(exponent));
        }
        if !is_double {
            let bit_flag: i64 = -(sign + 1) >> 1;
            self.push_value(Node::Int((int_value ^ bit_flag).wrapping_sub(bit_flag)));
            return Ok(position);
        }
        const MAX_EXACT_DOUBLE: f64 = 9007199254740992.0;
        if double_value < MAX_EXACT_DOUBLE {
            let exponent = int_value;
            let signed_mantissa = double_value * sign as f64;
            if exponent >= -22 {
                if exponent < 0 {
                    self.push_value(Node::Double(
                        signed_mantissa / POWERS_OF_TEN[(-exponent) as usize],
                    ));
                    return Ok(position);
                }
                if exponent == 0 {
                    self.push_value(Node::Double(signed_mantissa));
                    return Ok(position);
                }
                if exponent <= 22 {
                    self.push_value(Node::Double(
                        signed_mantissa * POWERS_OF_TEN[exponent as usize],
                    ));
                    return Ok(position);
                }
            }
        }
        // double.parse(source.substring(start, position))：JSON 数字文法是 Rust 浮点文法的
        // 子集，二者都正确舍入。
        let text: String = s[start..position]
            .iter()
            .map(|&u| u as u8 as char)
            .collect();
        let value = text
            .parse::<f64>()
            .expect("JSON number literal is a valid float");
        self.push_value(Node::Double(value));
        Ok(position)
    }
}

fn str_slice<'b>(input: &'b [u16], pool: &'b [u16], r: StrRef) -> &'b [u16] {
    let src = if r.pooled { pool } else { input };
    &src[r.start as usize..(r.start + r.len) as usize]
}

/// 对象的 (键节点, 值节点) 序列 → 去重后的条目：位置取首次出现、值取最后一次。
fn dedupe_pairs(pairs: &[u32], nodes: &[Node], input: &[u16], pool: &[u16]) -> Vec<(StrRef, u32)> {
    let key_of = |id: u32| match nodes[id as usize] {
        Node::Str(r) => r,
        _ => unreachable!("object keys are strings"),
    };
    let pair_count = pairs.len() / 2;
    let mut out: Vec<(StrRef, u32)> = Vec::with_capacity(pair_count);
    if pair_count <= 16 {
        for pair in pairs.chunks_exact(2) {
            let key = key_of(pair[0]);
            let units = str_slice(input, pool, key);
            match out
                .iter_mut()
                .find(|(k, _)| str_slice(input, pool, *k) == units)
            {
                Some(existing) => existing.1 = pair[1],
                None => out.push((key, pair[1])),
            }
        }
    } else {
        let mut index: std::collections::HashMap<&[u16], usize> =
            std::collections::HashMap::with_capacity(pair_count);
        for pair in pairs.chunks_exact(2) {
            let key = key_of(pair[0]);
            let units = str_slice(input, pool, key);
            match index.get(units) {
                Some(&i) => out[i].1 = pair[1],
                None => {
                    index.insert(units, out.len());
                    out.push((key, pair[1]));
                }
            }
        }
    }
    out
}

/// 解析整份 JSON；失败给出与 Dart `jsonDecode` 相同的错误种类与位置。
pub fn parse_json(input: &[u16]) -> Result<JsonDoc<'_>, JsonError> {
    let mut parser = Parser {
        s: input,
        pool: Vec::new(),
        nodes: Vec::new(),
        list_items: Vec::new(),
        map_entries: Vec::new(),
        scratch: Vec::new(),
        marks: Vec::new(),
        states: Vec::new(),
        value: 0,
        partial: Partial::None,
        string_start: 0,
    };
    parser.parse()?;
    Ok(JsonDoc {
        input,
        pool: parser.pool,
        nodes: parser.nodes,
        list_items: parser.list_items,
        map_entries: parser.map_entries,
        root: parser.value,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn u(s: &str) -> Vec<u16> {
        s.encode_utf16().collect()
    }

    fn render(s: &str) -> Result<String, (JsonErrorKind, usize)> {
        let units = u(s);
        let doc = parse_json(&units).map_err(|e| (e.kind, e.offset))?;
        let mut out = Vec::new();
        doc.write_dart_string(doc.root(), &mut out);
        Ok(String::from_utf16(&out).unwrap())
    }

    #[test]
    fn values_and_to_string() {
        assert_eq!(
            render(r#"{"a": 1, "b": [1, 2.5, "x", null, true, {"c": -0.0}], "e": {}, "f": []}"#),
            Ok("{a: 1, b: [1, 2.5, x, null, true, {c: -0.0}], e: {}, f: []}".into())
        );
        assert_eq!(
            render(r#"[-0, -0.0, 1e400, -1e401, 0.0e999, 1E2]"#),
            Ok("[0, -0.0, Infinity, -Infinity, 0.0, 100.0]".into())
        );
        assert_eq!(
            render(r#"[9223372036854775807, -9223372036854775808, 9223372036854775808]"#),
            Ok("[9223372036854775807, -9223372036854775808, 9223372036854776000.0]".into())
        );
        assert_eq!(
            render(r#"{"k": 1, "j": 2, "k": 3}"#),
            Ok("{k: 3, j: 2}".into())
        );
        assert_eq!(render(r#"["a\u0041\n\"\\\/"]"#), Ok("[aA\n\"\\/]".into()));
    }

    #[test]
    fn errors_match_dart_messages() {
        use JsonErrorKind::*;
        assert_eq!(render(""), Err((UnexpectedEndOfInput, 0)));
        assert_eq!(render("{"), Err((UnexpectedEndOfInput, 1)));
        assert_eq!(render("[1,]"), Err((UnexpectedCharacter, 3)));
        assert_eq!(render("[01]"), Err((UnexpectedCharacter, 2)));
        assert_eq!(render("[-a]"), Err((MissingExpectedDigit, 2)));
        assert_eq!(render("[1.]"), Err((UnexpectedCharacter, 3)));
        assert_eq!(render("[1e]"), Err((MissingExpectedDigit, 3)));
        assert_eq!(render("[\"a"), Err((UnterminatedString, 3)));
        assert_eq!(render("[\"\u{1}\"]"), Err((ControlCharacterInString, 2)));
        assert_eq!(render("[\"\\x\"]"), Err((UnrecognizedStringEscape, 4)));
        assert_eq!(render("[\"\\u12G4\"]"), Err((InvalidUnicodeEscape, 3)));
        assert_eq!(render("[tru"), Err((UnexpectedEndOfInput, 4)));
        assert_eq!(render("[trux]"), Err((UnexpectedCharacter, 1)));
        assert_eq!(render("-"), Err((UnterminatedNumberLiteral, 1)));
        assert_eq!(render("1 2"), Err((UnexpectedCharacter, 2)));
    }
}
