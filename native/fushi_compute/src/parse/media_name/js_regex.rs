//! 最小回溯正则引擎：逐 UTF-16 码元复现 Dart `RegExp`（= ECMAScript 非 unicode 模式）
//! 在本域用到的那部分语法与语义。
//!
//! 为什么不用 `regex` crate：媒体名解析的原正则大量用了先行断言 `(?=…)`（`regex` 不支持），
//! 而且 `regex` 按 Unicode 标量值工作、`\s` / `\d` 默认是 Unicode 集合、不区分大小写走
//! Unicode 简单折叠——与 Dart 的「逐码元、`\s` 为 JS 空白集合、`\d` 只有 ASCII、
//! `caseSensitive: false` 走 JS Canonicalize」在边界输入上不一致。原生实现必须与旧 Dart
//! 结果**完全一致**，所以这里把用到的子集原样实现成回溯匹配（与 irregexp 同一套优先级）：
//!
//! - 字面量、`.`、字符类（区间 / 取反 / `\d \D \s \S \w \W` 及类内转义）；
//! - 分组 `( )` / `(?: )`、选择 `|`、先行断言 `(?= )` / `(?! )`（原子，与 JS 一致）；
//! - 量词 `? * + {n} {n,} {n,m}` 及惰性后缀 `?`；空迭代按 JS RepeatMatcher 规则终止；
//! - 锚点 `^ $`（`multi_line` 时按 JS 行终止符 `\n \r U+2028 U+2029`）、`\b \B`。
//!
//! 大小写不敏感：JS 非 unicode 模式的 Canonicalize 把**非 ASCII 字符永不折叠到 ASCII**，
//! 本域所有不区分大小写的正则里非 ASCII 字符都没有大小写（`×` `完` `第` 破折号等），
//! 所以等价于「只折叠 ASCII 字母」。[JsRegex::new] 在编译时断言这一前提，越界的模式直接 panic
//! （模式是本库内的常量，单测覆盖每一条）。
//!
//! 不支持的语法（反向引用、命名组、unicode 转义、后行断言）编译时 panic。

/// 一段 UTF-16 文本里的一次匹配：整体区间 + 各捕获组区间。
#[derive(Clone, Debug)]
pub struct Match {
    pub start: usize,
    pub end: usize,
    groups: Vec<Option<(usize, usize)>>,
}

impl Match {
    /// 第 [index] 组（0 = 整体）的区间；未参与匹配为 None。
    pub fn group(&self, index: usize) -> Option<(usize, usize)> {
        if index == 0 {
            return Some((self.start, self.end));
        }
        self.groups.get(index - 1).copied().flatten()
    }

    /// 第 [index] 组的文本（未参与匹配为 None）。
    pub fn text<'a>(&self, text: &'a [u16], index: usize) -> Option<&'a [u16]> {
        self.group(index).map(|(s, e)| &text[s..e])
    }
}

#[derive(Clone, Debug)]
enum Node {
    Unit(u16),
    Class {
        ranges: Vec<(u16, u16)>,
        negated: bool,
    },
    Any,
    Start,
    End,
    WordBoundary(bool),
    Group {
        cap: Option<usize>,
        alts: Vec<Vec<Node>>,
    },
    Look {
        negated: bool,
        alts: Vec<Vec<Node>>,
    },
    Repeat {
        node: Box<Node>,
        min: u32,
        max: u32,
        greedy: bool,
    },
}

/// 编译好的正则。
#[derive(Debug)]
pub struct JsRegex {
    alts: Vec<Vec<Node>>,
    caps: usize,
    ignore_case: bool,
    multi_line: bool,
    /// 起点预筛（只是跳过「不可能起匹配」的位置，不改变匹配结果）。
    first: First,
}

/// 匹配起点的必要条件：任一选择支要么以 `^` 开头（只能在输入开头 / 多行时行首起），
/// 要么首个码元落在 `units` 里。分析不出时为 [First::Any]。
#[derive(Debug, Clone)]
enum First {
    Any,
    Set {
        at_line_start: bool,
        units: Vec<(u16, u16)>,
    },
}

impl First {
    fn union(self, other: First) -> First {
        match (self, other) {
            (
                First::Set {
                    at_line_start: a,
                    units: mut ua,
                },
                First::Set {
                    at_line_start: b,
                    units: ub,
                },
            ) => {
                ua.extend(ub);
                First::Set {
                    at_line_start: a || b,
                    units: ua,
                }
            }
            _ => First::Any,
        }
    }
}

fn first_of_alts(alts: &[Vec<Node>], ignore_case: bool) -> First {
    let mut acc = First::Set {
        at_line_start: false,
        units: Vec::new(),
    };
    for alt in alts {
        acc = acc.union(first_of_seq(alt, ignore_case));
        if matches!(acc, First::Any) {
            break;
        }
    }
    acc
}

fn first_of_seq(seq: &[Node], ignore_case: bool) -> First {
    let Some(node) = seq.first() else {
        return First::Any; // 空选择支：任意位置都能匹配空串
    };
    let with_case = |ranges: &[(u16, u16)]| -> Vec<(u16, u16)> {
        let mut out = ranges.to_vec();
        if ignore_case {
            for &(lo, hi) in ranges {
                for u in lo.max(0x41)..=hi.min(0x7A) {
                    if let Some(o) = swap_ascii_case(u) {
                        out.push((o, o));
                    }
                }
            }
        }
        out
    };
    match node {
        Node::Unit(u) => First::Set {
            at_line_start: false,
            units: with_case(&[(*u, *u)]),
        },
        Node::Class {
            ranges,
            negated: false,
        } => First::Set {
            at_line_start: false,
            units: with_case(ranges),
        },
        Node::Start => First::Set {
            at_line_start: true,
            units: Vec::new(),
        },
        Node::Group { alts, .. } => {
            // 组内每个选择支都必须非空起头；能匹配空串的组分析不出（保守 Any）。
            first_of_alts(alts, ignore_case)
        }
        Node::Repeat { node, min, .. } if *min > 0 => {
            first_of_seq(std::slice::from_ref(node.as_ref()), ignore_case)
        }
        _ => First::Any,
    }
}

const INF: u32 = u32::MAX;

/// JS `\s`：WhiteSpace ∪ LineTerminator（ES5.1 §15.10.2.12）。实测与 Dart 一致。
pub const JS_SPACE: &[(u16, u16)] = &[
    (0x09, 0x0D),
    (0x20, 0x20),
    (0xA0, 0xA0),
    (0x1680, 0x1680),
    (0x2000, 0x200A),
    (0x2028, 0x2029),
    (0x202F, 0x202F),
    (0x205F, 0x205F),
    (0x3000, 0x3000),
    (0xFEFF, 0xFEFF),
];
const JS_DIGIT: &[(u16, u16)] = &[(0x30, 0x39)];
const JS_WORD: &[(u16, u16)] = &[(0x30, 0x39), (0x41, 0x5A), (0x5F, 0x5F), (0x61, 0x7A)];

/// JS 行终止符（`^` / `$` 多行模式与 `.` 用）。
pub fn is_line_terminator(unit: u16) -> bool {
    matches!(unit, 0x0A | 0x0D | 0x2028 | 0x2029)
}

/// JS `\s`。
pub fn is_js_space(unit: u16) -> bool {
    in_ranges(JS_SPACE, unit)
}

fn in_ranges(ranges: &[(u16, u16)], unit: u16) -> bool {
    ranges.iter().any(|&(lo, hi)| lo <= unit && unit <= hi)
}

fn complement(ranges: &[(u16, u16)]) -> Vec<(u16, u16)> {
    let mut sorted = ranges.to_vec();
    sorted.sort();
    let mut out = Vec::new();
    let mut next: u32 = 0;
    for (lo, hi) in sorted {
        if (lo as u32) > next {
            out.push((next as u16, lo - 1));
        }
        next = next.max(hi as u32 + 1);
    }
    if next <= 0xFFFF {
        out.push((next as u16, 0xFFFF));
    }
    out
}

fn ascii_fold(unit: u16) -> u16 {
    if (b'a' as u16..=b'z' as u16).contains(&unit) {
        unit - 32
    } else {
        unit
    }
}

fn swap_ascii_case(unit: u16) -> Option<u16> {
    match unit {
        0x41..=0x5A => Some(unit + 32),
        0x61..=0x7A => Some(unit - 32),
        _ => None,
    }
}

fn is_word(unit: u16) -> bool {
    in_ranges(JS_WORD, unit)
}

/// 非 ASCII 且有大小写变体的字符（不区分大小写的模式里不允许出现，见模块注释）。
fn has_non_ascii_case(unit: u16) -> bool {
    if unit < 0x80 {
        return false;
    }
    match char::from_u32(unit as u32) {
        Some(c) => {
            c.to_uppercase().ne(std::iter::once(c)) || c.to_lowercase().ne(std::iter::once(c))
        }
        None => false,
    }
}

struct Parser<'a> {
    src: &'a [u16],
    pos: usize,
    caps: usize,
}

impl<'a> Parser<'a> {
    fn peek(&self) -> Option<u16> {
        self.src.get(self.pos).copied()
    }

    fn eat(&mut self, unit: u8) -> bool {
        if self.peek() == Some(unit as u16) {
            self.pos += 1;
            true
        } else {
            false
        }
    }

    fn parse_alts(&mut self) -> Vec<Vec<Node>> {
        let mut alts = vec![self.parse_seq()];
        while self.eat(b'|') {
            alts.push(self.parse_seq());
        }
        alts
    }

    fn parse_seq(&mut self) -> Vec<Node> {
        let mut seq = Vec::new();
        while let Some(unit) = self.peek() {
            if unit == b'|' as u16 || unit == b')' as u16 {
                break;
            }
            let atom = self.parse_atom();
            let atom = self.parse_quantifier(atom);
            seq.push(atom);
        }
        seq
    }

    fn parse_quantifier(&mut self, atom: Node) -> Node {
        let (min, max) = match self.peek() {
            Some(0x3F) => {
                self.pos += 1;
                (0, 1)
            }
            Some(0x2A) => {
                self.pos += 1;
                (0, INF)
            }
            Some(0x2B) => {
                self.pos += 1;
                (1, INF)
            }
            Some(0x7B) => match self.try_braces() {
                Some(range) => range,
                None => return atom,
            },
            _ => return atom,
        };
        assert!(
            !matches!(
                atom,
                Node::Start | Node::End | Node::WordBoundary(_) | Node::Look { .. }
            ),
            "quantified assertion is not supported"
        );
        let greedy = !self.eat(b'?');
        Node::Repeat {
            node: Box::new(atom),
            min,
            max,
            greedy,
        }
    }

    fn try_braces(&mut self) -> Option<(u32, u32)> {
        let save = self.pos;
        self.pos += 1;
        let min = self.number();
        let Some(min) = min else {
            self.pos = save;
            return None;
        };
        let max = if self.eat(b',') {
            if self.peek() == Some(b'}' as u16) {
                INF
            } else {
                match self.number() {
                    Some(n) => n,
                    None => {
                        self.pos = save;
                        return None;
                    }
                }
            }
        } else {
            min
        };
        if !self.eat(b'}') {
            self.pos = save;
            return None;
        }
        Some((min, max))
    }

    fn number(&mut self) -> Option<u32> {
        let start = self.pos;
        let mut value: u32 = 0;
        while let Some(unit) = self.peek() {
            if (0x30..=0x39).contains(&unit) {
                value = value * 10 + (unit - 0x30) as u32;
                self.pos += 1;
            } else {
                break;
            }
        }
        (self.pos > start).then_some(value)
    }

    fn parse_atom(&mut self) -> Node {
        let unit = self.peek().expect("atom");
        self.pos += 1;
        match unit {
            0x5E => Node::Start,
            0x24 => Node::End,
            0x2E => Node::Any,
            0x28 => {
                let node = if self.eat(b'?') {
                    if self.eat(b':') {
                        Node::Group {
                            cap: None,
                            alts: self.parse_alts(),
                        }
                    } else if self.eat(b'=') {
                        Node::Look {
                            negated: false,
                            alts: self.parse_alts(),
                        }
                    } else if self.eat(b'!') {
                        Node::Look {
                            negated: true,
                            alts: self.parse_alts(),
                        }
                    } else {
                        panic!("unsupported group syntax");
                    }
                } else {
                    let cap = self.caps;
                    self.caps += 1;
                    Node::Group {
                        cap: Some(cap),
                        alts: self.parse_alts(),
                    }
                };
                assert!(self.eat(b')'), "unclosed group");
                node
            }
            0x5B => self.parse_class(),
            0x5C => self.parse_escape(false),
            0x2A | 0x2B | 0x3F => panic!("nothing to repeat"),
            _ => Node::Unit(unit),
        }
    }

    /// `\` 之后（已吃掉反斜杠）。[in_class] 时 `\b` 是退格。
    fn parse_escape(&mut self, in_class: bool) -> Node {
        let unit = self.peek().expect("escape");
        self.pos += 1;
        let c = char::from_u32(unit as u32).unwrap_or('\0');
        match c {
            'd' => Node::Class {
                ranges: JS_DIGIT.to_vec(),
                negated: false,
            },
            'D' => Node::Class {
                ranges: JS_DIGIT.to_vec(),
                negated: true,
            },
            's' => Node::Class {
                ranges: JS_SPACE.to_vec(),
                negated: false,
            },
            'S' => Node::Class {
                ranges: JS_SPACE.to_vec(),
                negated: true,
            },
            'w' => Node::Class {
                ranges: JS_WORD.to_vec(),
                negated: false,
            },
            'W' => Node::Class {
                ranges: JS_WORD.to_vec(),
                negated: true,
            },
            'b' if in_class => Node::Unit(0x08),
            'b' => Node::WordBoundary(true),
            'B' => Node::WordBoundary(false),
            'n' => Node::Unit(0x0A),
            'r' => Node::Unit(0x0D),
            't' => Node::Unit(0x09),
            'f' => Node::Unit(0x0C),
            'v' => Node::Unit(0x0B),
            '0'..='9' | 'u' | 'x' | 'c' | 'k' | 'p' | 'P' => panic!("unsupported escape \\{c}"),
            _ if c.is_ascii_alphanumeric() => panic!("unsupported escape \\{c}"),
            _ => Node::Unit(unit),
        }
    }

    fn parse_class(&mut self) -> Node {
        let negated = self.eat(b'^');
        let mut ranges: Vec<(u16, u16)> = Vec::new();
        loop {
            let unit = self.peek().expect("unclosed class");
            if unit == b']' as u16 {
                self.pos += 1;
                break;
            }
            let lo = self.class_atom();
            // 区间：`a-b`，`-` 在末尾 / 紧跟 `]` 时是字面量。
            if self.peek() == Some(b'-' as u16)
                && self.src.get(self.pos + 1).copied() != Some(b']' as u16)
                && self.src.get(self.pos + 1).is_some()
            {
                if let ClassAtom::Unit(lo_unit) = lo {
                    let save = self.pos;
                    self.pos += 1;
                    match self.class_atom() {
                        ClassAtom::Unit(hi_unit) => {
                            assert!(lo_unit <= hi_unit, "class range out of order");
                            ranges.push((lo_unit, hi_unit));
                            continue;
                        }
                        ClassAtom::Set(_) => {
                            self.pos = save;
                        }
                    }
                }
            }
            match lo {
                ClassAtom::Unit(u) => ranges.push((u, u)),
                ClassAtom::Set(set) => ranges.extend(set),
            }
        }
        Node::Class { ranges, negated }
    }

    fn class_atom(&mut self) -> ClassAtom {
        let unit = self.peek().expect("class atom");
        self.pos += 1;
        if unit != b'\\' as u16 {
            return ClassAtom::Unit(unit);
        }
        match self.parse_escape(true) {
            Node::Unit(u) => ClassAtom::Unit(u),
            Node::Class {
                ranges,
                negated: false,
            } => ClassAtom::Set(ranges),
            Node::Class {
                ranges,
                negated: true,
            } => ClassAtom::Set(complement(&ranges)),
            _ => panic!("unsupported escape in class"),
        }
    }
}

enum ClassAtom {
    Unit(u16),
    Set(Vec<(u16, u16)>),
}

fn check_ignore_case(node: &Node) {
    match node {
        Node::Unit(u) => assert!(
            !has_non_ascii_case(*u),
            "non-ASCII cased literal in ignore-case regex"
        ),
        Node::Class { ranges, .. } => {
            for &(lo, hi) in ranges {
                // 只检查非 ASCII 段；\S \D \W 的补集是宽区间，里面本来就有大小写字符——
                // 取反集合在不区分大小写下的 JS 语义另算，这里直接不允许。
                if hi >= 0x80 && (hi - lo) < 0x400 {
                    for u in lo.max(0x80)..=hi {
                        assert!(
                            !has_non_ascii_case(u),
                            "non-ASCII cased class member in ignore-case regex"
                        );
                    }
                } else if hi >= 0x80 {
                    panic!("wide non-ASCII class in ignore-case regex");
                }
            }
        }
        Node::Group { alts, .. } | Node::Look { alts, .. } => {
            alts.iter().flatten().for_each(check_ignore_case)
        }
        Node::Repeat { node, .. } => check_ignore_case(node),
        _ => {}
    }
}

struct Ctx<'t> {
    text: &'t [u16],
    ignore_case: bool,
    multi_line: bool,
}

type Caps = Vec<Option<(usize, usize)>>;
type Cont<'k> = &'k mut dyn FnMut(usize, &mut Caps) -> bool;

impl JsRegex {
    /// 编译 [pattern]（Rust 字符串里写与 Dart 源码相同的模式）。语法越界时 panic。
    pub fn new(pattern: &str, ignore_case: bool, multi_line: bool) -> JsRegex {
        let src: Vec<u16> = pattern.encode_utf16().collect();
        let mut parser = Parser {
            src: &src,
            pos: 0,
            caps: 0,
        };
        let alts = parser.parse_alts();
        assert!(parser.pos == src.len(), "unbalanced ')' in {pattern}");
        if ignore_case {
            alts.iter().flatten().for_each(check_ignore_case);
        }
        let first = first_of_alts(&alts, ignore_case);
        JsRegex {
            alts,
            caps: parser.caps,
            ignore_case,
            multi_line,
            first,
        }
    }

    /// 简写：区分大小写、单行。
    pub fn cs(pattern: &str) -> JsRegex {
        JsRegex::new(pattern, false, false)
    }

    /// 简写：不区分大小写、单行。
    pub fn ci(pattern: &str) -> JsRegex {
        JsRegex::new(pattern, true, false)
    }

    /// 从 [from] 起的首个匹配（Dart `firstMatch` / `allMatches` 的单步）。
    pub fn find_at(&self, text: &[u16], from: usize) -> Option<Match> {
        let ctx = Ctx {
            text,
            ignore_case: self.ignore_case,
            multi_line: self.multi_line,
        };
        let mut caps: Caps = vec![None; self.caps];
        for start in from..=text.len() {
            if let First::Set {
                at_line_start,
                units,
            } = &self.first
            {
                let line_start = start == 0
                    || (self.multi_line && is_line_terminator(text[start - 1]));
                let unit_ok = start < text.len() && in_ranges(units, text[start]);
                if !(unit_ok || (*at_line_start && line_start)) {
                    continue;
                }
            }
            let mut end = usize::MAX;
            let mut result_caps: Caps = Vec::new();
            caps.iter_mut().for_each(|c| *c = None);
            let matched = match_alts(&ctx, &self.alts, None, start, &mut caps, &mut |p, c| {
                end = p;
                result_caps = c.clone();
                true
            });
            if matched {
                return Some(Match {
                    start,
                    end,
                    groups: result_caps,
                });
            }
        }
        None
    }

    /// Dart `firstMatch`。
    pub fn first_match(&self, text: &[u16]) -> Option<Match> {
        self.find_at(text, 0)
    }

    /// Dart `hasMatch`。
    pub fn has_match(&self, text: &[u16]) -> bool {
        self.find_at(text, 0).is_some()
    }

    /// Dart `allMatches`：上一个匹配的终点续搜，空匹配时前进一个码元。
    pub fn all_matches(&self, text: &[u16]) -> Vec<Match> {
        let mut out = Vec::new();
        let mut from = 0;
        while from <= text.len() {
            let Some(m) = self.find_at(text, from) else {
                break;
            };
            from = if m.end == m.start { m.end + 1 } else { m.end };
            out.push(m);
        }
        out
    }

    /// Dart `replaceAll(RegExp, String)`（替换串里不含 `$` 语法：Dart 本来也不解析）。
    pub fn replace_all(&self, text: &[u16], replacement: &[u16]) -> Vec<u16> {
        let mut out = Vec::with_capacity(text.len());
        let mut last = 0;
        for m in self.all_matches(text) {
            out.extend_from_slice(&text[last..m.start]);
            out.extend_from_slice(replacement);
            last = m.end;
        }
        out.extend_from_slice(&text[last..]);
        out
    }

    /// Dart `replaceFirst(RegExp, String)`。
    pub fn replace_first(&self, text: &[u16], replacement: &[u16]) -> Vec<u16> {
        match self.first_match(text) {
            None => text.to_vec(),
            Some(m) => {
                let mut out = text[..m.start].to_vec();
                out.extend_from_slice(replacement);
                out.extend_from_slice(&text[m.end..]);
                out
            }
        }
    }

    /// Dart `String.split(RegExp)`，只用于不会匹配空串的模式（断言）。
    pub fn split<'t>(&self, text: &'t [u16]) -> Vec<&'t [u16]> {
        let mut out = Vec::new();
        if text.is_empty() {
            // Dart：空串 split 非空匹配模式得 `[""]`。
            out.push(text);
            return out;
        }
        let mut last = 0;
        for m in self.all_matches(text) {
            assert!(m.end > m.start, "split pattern matched empty string");
            out.push(&text[last..m.start]);
            last = m.end;
        }
        out.push(&text[last..]);
        out
    }
}

fn unit_matches(ctx: &Ctx, node: &Node, unit: u16) -> bool {
    match node {
        Node::Unit(u) => {
            if ctx.ignore_case {
                ascii_fold(*u) == ascii_fold(unit)
            } else {
                *u == unit
            }
        }
        Node::Class { ranges, negated } => {
            let mut hit = in_ranges(ranges, unit);
            if !hit && ctx.ignore_case {
                if let Some(other) = swap_ascii_case(unit) {
                    hit = in_ranges(ranges, other);
                }
            }
            hit != *negated
        }
        Node::Any => !is_line_terminator(unit),
        _ => unreachable!(),
    }
}

fn is_single_unit(node: &Node) -> bool {
    matches!(node, Node::Unit(_) | Node::Class { .. } | Node::Any)
}

fn match_alts(
    ctx: &Ctx,
    alts: &[Vec<Node>],
    cap: Option<usize>,
    pos: usize,
    caps: &mut Caps,
    k: Cont,
) -> bool {
    for alt in alts {
        let matched = match cap {
            None => match_seq(ctx, alt, pos, caps, k),
            Some(index) => match_seq(ctx, alt, pos, caps, &mut |p, c: &mut Caps| {
                let old = c[index];
                c[index] = Some((pos, p));
                if k(p, c) {
                    true
                } else {
                    c[index] = old;
                    false
                }
            }),
        };
        if matched {
            return true;
        }
    }
    false
}

fn match_seq(ctx: &Ctx, seq: &[Node], pos: usize, caps: &mut Caps, k: Cont) -> bool {
    match seq.split_first() {
        None => k(pos, caps),
        Some((first, rest)) => {
            if rest.is_empty() {
                match_node(ctx, first, pos, caps, k)
            } else {
                match_node(ctx, first, pos, caps, &mut |p, c: &mut Caps| {
                    match_seq(ctx, rest, p, c, k)
                })
            }
        }
    }
}

fn match_node(ctx: &Ctx, node: &Node, pos: usize, caps: &mut Caps, k: Cont) -> bool {
    let text = ctx.text;
    match node {
        Node::Unit(_) | Node::Class { .. } | Node::Any => {
            pos < text.len() && unit_matches(ctx, node, text[pos]) && k(pos + 1, caps)
        }
        Node::Start => {
            (pos == 0 || (ctx.multi_line && is_line_terminator(text[pos - 1]))) && k(pos, caps)
        }
        Node::End => {
            (pos == text.len() || (ctx.multi_line && is_line_terminator(text[pos]))) && k(pos, caps)
        }
        Node::WordBoundary(want) => {
            let before = pos > 0 && is_word(text[pos - 1]);
            let after = pos < text.len() && is_word(text[pos]);
            ((before != after) == *want) && k(pos, caps)
        }
        Node::Group { cap, alts } => match_alts(ctx, alts, *cap, pos, caps, k),
        Node::Look { negated, alts } => {
            // 断言是原子的：先找子模式的首个匹配，之后不再回溯进去（JS 语义）。
            // 断言内没有捕获组时（本域全部如此）不用存还原点，省一次分配。
            let saved = alts.iter().flatten().any(has_caps).then(|| caps.clone());
            let restore = |caps: &mut Caps| {
                if let Some(saved) = &saved {
                    caps.clone_from(saved);
                }
            };
            let found = match_alts(ctx, alts, None, pos, caps, &mut |_, _| true);
            if *negated {
                restore(caps);
                !found && k(pos, caps)
            } else if found {
                if k(pos, caps) {
                    true
                } else {
                    restore(caps);
                    false
                }
            } else {
                false
            }
        }
        Node::Repeat {
            node,
            min,
            max,
            greedy,
        } => {
            if is_single_unit(node) {
                // 单码元原子：无捕获、无空迭代，先数出最长连续命中再按优先级试续体。
                let mut n: usize = 0;
                let limit = if *max == INF {
                    usize::MAX
                } else {
                    *max as usize
                };
                while n < limit && pos + n < text.len() && unit_matches(ctx, node, text[pos + n]) {
                    n += 1;
                }
                let min = *min as usize;
                if n < min {
                    return false;
                }
                if *greedy {
                    (min..=n).rev().any(|i| k(pos + i, caps))
                } else {
                    (min..=n).any(|i| k(pos + i, caps))
                }
            } else {
                repeat(ctx, node, *min, *max, *greedy, 0, pos, caps, k)
            }
        }
    }
}

// 末尾两支只是顺序相反（贪婪先迭代、惰性先续接），clippy::if_same_then_else 是误报。
#[allow(clippy::too_many_arguments, clippy::if_same_then_else)]
fn repeat(
    ctx: &Ctx,
    node: &Node,
    min: u32,
    max: u32,
    greedy: bool,
    count: u32,
    pos: usize,
    caps: &mut Caps,
    k: Cont,
) -> bool {
    let iterate = |caps: &mut Caps, k: Cont| -> bool {
        if count >= max {
            return false;
        }
        // JS RepeatMatcher：每次迭代前清空原子内的捕获；已满足 min 后的空迭代判失败。
        let saved = has_caps(node).then(|| caps.clone());
        if saved.is_some() {
            clear_caps(node, caps);
        }
        let ok = match_node(ctx, node, pos, caps, &mut |p, c: &mut Caps| {
            if p == pos && count >= min {
                return false;
            }
            repeat(
                ctx,
                node,
                min,
                max,
                greedy,
                count.saturating_add(1),
                p,
                c,
                k,
            )
        });
        if !ok {
            if let Some(saved) = saved {
                *caps = saved;
            }
        }
        ok
    };
    if count < min {
        return iterate(caps, k);
    }
    if greedy {
        iterate(caps, k) || k(pos, caps)
    } else {
        k(pos, caps) || iterate(caps, k)
    }
}

fn has_caps(node: &Node) -> bool {
    match node {
        Node::Group { cap, alts } => cap.is_some() || alts.iter().flatten().any(has_caps),
        Node::Look { alts, .. } => alts.iter().flatten().any(has_caps),
        Node::Repeat { node, .. } => has_caps(node),
        _ => false,
    }
}

fn clear_caps(node: &Node, caps: &mut Caps) {
    match node {
        Node::Group { cap, alts } => {
            if let Some(i) = cap {
                caps[*i] = None;
            }
            alts.iter().flatten().for_each(|n| clear_caps(n, caps));
        }
        Node::Look { alts, .. } => alts.iter().flatten().for_each(|n| clear_caps(n, caps)),
        Node::Repeat { node, .. } => clear_caps(node, caps),
        _ => {}
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn u(s: &str) -> Vec<u16> {
        s.encode_utf16().collect()
    }

    fn first(re: &JsRegex, s: &str) -> Option<(usize, usize, Vec<Option<String>>)> {
        let text = u(s);
        re.first_match(&text).map(|m| {
            let groups = (1..=re.caps)
                .map(|i| m.text(&text, i).map(String::from_utf16_lossy))
                .collect();
            (m.start, m.end, groups)
        })
    }

    #[test]
    fn greedy_backtracking_and_groups() {
        let re = JsRegex::cs(r"(\d{1,3}):(\d+)");
        assert_eq!(
            first(&re, "x1234:56"),
            Some((2, 8, vec![Some("234".into()), Some("56".into())]))
        );
        let re = JsRegex::cs(r"^(a|ab)(c|bcd)(d*)$");
        assert_eq!(
            first(&re, "abcd"),
            Some((
                0,
                4,
                vec![Some("a".into()), Some("bcd".into()), Some("".into())]
            ))
        );
    }

    #[test]
    fn lookahead_and_anchors() {
        let re = JsRegex::cs(r"(?:^|[\s._-])[Ss](\d{1,2})(?=$|[\s._-])");
        assert_eq!(first(&re, "Title S2 x").map(|m| m.0), Some(5));
        assert!(first(&re, "Title S2x").is_none());
        let ml = JsRegex::new(r"^X", false, true);
        assert!(ml.has_match(&u("a\u{2028}X")));
        assert!(!JsRegex::cs(r"^X").has_match(&u("a\nX")));
        assert!(!JsRegex::cs(r"a$").has_match(&u("a\n")));
    }

    #[test]
    fn ignore_case_is_ascii_only() {
        let re = JsRegex::ci(r"^(mkv|mp4)$");
        assert!(re.has_match(&u("MKV")));
        // KELVIN SIGN 不折叠到 k（JS 非 unicode Canonicalize）。
        assert!(!re.has_match(&u("m\u{212A}v")));
        assert!(JsRegex::ci(r"^[x×]$").has_match(&u("X")));
    }

    #[test]
    #[should_panic]
    fn ignore_case_rejects_non_ascii_cased_literal() {
        JsRegex::ci("é");
    }

    #[test]
    fn empty_iteration_terminates() {
        let re = JsRegex::cs(r"(?:a?)*b");
        assert_eq!(first(&re, "aab").map(|m| (m.0, m.1)), Some((0, 3)));
        let re = JsRegex::cs(r"(a*)*$");
        assert!(re.has_match(&u("aaa")));
    }

    #[test]
    fn split_and_replace_match_dart() {
        let re = JsRegex::cs(r"[ _.+&,]+");
        let text = u("_a..b_");
        let parts: Vec<String> = re
            .split(&text)
            .into_iter()
            .map(String::from_utf16_lossy)
            .collect();
        assert_eq!(parts, vec!["", "a", "b", ""]);
        let ws = JsRegex::cs(r"\s+");
        assert_eq!(
            String::from_utf16_lossy(&ws.replace_all(&u(" a \u{3000} b"), &u(" "))),
            " a b"
        );
    }
}
