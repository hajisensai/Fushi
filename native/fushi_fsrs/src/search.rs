//! Anki 搜索的逐卡求值与 AnkiConnect 查重的首字段规范形（Dart 侧只剩解析器）。
//!
//! - 语法树由 Dart 解析器（`packages/fushi_srs/lib/src/search/search_parser.dart`）产出，
//!   序列化成 JSON（见 [`Node`]）交给这里编译、求值；一次调用对整批卡给出命中位图。
//! - 整批卡的文本（字段名 / 值、标签、笔记类型名、牌组名、模板名）在 [`Corpus`] 里只装一次，
//!   跨多次搜索复用；拼接后的字段文本、去 HTML 后的字段值按需惰性算一次后缓存。
//! - 卡片的数值属性（状态、id、日序号、间隔……）按列传入（[`IntColumn`] / [`FloatColumn`]），
//!   查询用到哪列才需要设置哪列。
//! - 正则一律用 `regex` crate：与 Anki 桌面版（rslib）是同一个引擎，`re:` 的语义以它为准。

use std::cell::OnceCell;
use std::collections::{HashMap, HashSet};

use regex::{Regex, RegexBuilder};
use serde::Deserialize;

/// 整数列（与 Dart `SrsSearchCorpus` 的列号一致）。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum IntColumn {
    /// 位：1 new / 2 learn / 4 review / 8 due / 16 suspended / 32 buried。
    State = 0,
    NoteId = 1,
    CardId = 2,
    AddedDay = 3,
    EditedDay = 4,
    Today = 5,
    Flag = 6,
    Ordinal = 7,
    Interval = 8,
    /// 没有到期日（新卡）为 `i64::MIN`。
    Due = 9,
    Reps = 10,
    Lapses = 11,
}

pub const INT_COLUMNS: usize = 12;

/// 小数列；没有记忆状态为 NaN。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FloatColumn {
    Stability = 0,
    Difficulty = 1,
}

pub const FLOAT_COLUMNS: usize = 2;

pub const DUE_NONE: i64 = i64::MIN;

const STATE_NEW: i64 = 1;
const STATE_LEARN: i64 = 2;
const STATE_REVIEW: i64 = 4;
const STATE_DUE: i64 = 8;
const STATE_SUSPENDED: i64 = 16;
const STATE_BURIED: i64 = 32;

/// 一批卡（连同所属笔记）的搜索语料。不是线程安全的：一个句柄同一时刻只在一个线程上用
/// （Dart 侧一个 isolate 持有一个句柄）。
pub struct Corpus {
    text: String,
    str_off: Vec<u32>,
    note_type: Vec<u32>,
    note_field_off: Vec<u32>,
    field_name: Vec<u32>,
    field_value: Vec<u32>,
    note_tag_off: Vec<u32>,
    tag: Vec<u32>,
    card_note: Vec<u32>,
    card_deck: Vec<u32>,
    card_tpl: Vec<u32>,
    ints: [Option<Vec<i64>>; INT_COLUMNS],
    floats: [Option<Vec<f64>>; FLOAT_COLUMNS],
    joined: Vec<OnceCell<String>>,
    tags_joined: Vec<OnceCell<String>>,
    stripped: Vec<OnceCell<String>>,
}

/// 搜索失败：`syntax` = 查询本身不合法（如正则写错），`internal` = 调用方给的数据不对。
#[derive(Debug, PartialEq)]
pub struct SearchError {
    pub kind: &'static str,
    pub reason: String,
    pub at: String,
}

impl SearchError {
    fn internal(reason: impl Into<String>) -> Self {
        SearchError {
            kind: "internal",
            reason: reason.into(),
            at: String::new(),
        }
    }
}

/// 布局数组（u32）：`[n_str, n_notes, n_fields, n_tags, n_cards,
/// str_off(n_str+1), note_type(n_notes), note_field_off(n_notes+1), field_name(n_fields),
/// field_value(n_fields), note_tag_off(n_notes+1), tag(n_tags), card_note(n_cards),
/// card_deck(n_cards), card_tpl(n_cards)]`。`text` 是全部字符串的 UTF-8 拼接，
/// 第 i 个串 = `text[str_off[i]..str_off[i+1]]`。
impl Corpus {
    pub fn new(text: &[u8], layout: &[u32]) -> Result<Corpus, String> {
        let text = std::str::from_utf8(text).map_err(|e| format!("text is not UTF-8: {e}"))?;
        let mut pos = 0usize;
        let mut take = |n: usize| -> Result<Vec<u32>, String> {
            let end = pos.checked_add(n).ok_or("layout overflow")?;
            let slice = layout.get(pos..end).ok_or("layout too short")?;
            pos = end;
            Ok(slice.to_vec())
        };
        let header = take(5)?;
        let (n_str, n_notes, n_fields, n_tags, n_cards) = (
            header[0] as usize,
            header[1] as usize,
            header[2] as usize,
            header[3] as usize,
            header[4] as usize,
        );
        let str_off = take(n_str + 1)?;
        let note_type = take(n_notes)?;
        let note_field_off = take(n_notes + 1)?;
        let field_name = take(n_fields)?;
        let field_value = take(n_fields)?;
        let note_tag_off = take(n_notes + 1)?;
        let tag = take(n_tags)?;
        let card_note = take(n_cards)?;
        let card_deck = take(n_cards)?;
        let card_tpl = take(n_cards)?;
        if pos != layout.len() {
            return Err("layout has trailing data".into());
        }
        if str_off[0] != 0 || str_off[n_str] as usize != text.len() {
            return Err("string offsets do not cover the text".into());
        }
        for w in str_off.windows(2) {
            if w[0] > w[1] || !text.is_char_boundary(w[1] as usize) {
                return Err("bad string offset".into());
            }
        }
        let str_ok = |ids: &[u32]| ids.iter().all(|&i| (i as usize) < n_str);
        let monotone = |offs: &[u32], total: usize| {
            offs[0] == 0
                && offs[offs.len() - 1] as usize == total
                && offs.windows(2).all(|w| w[0] <= w[1])
        };
        if !str_ok(&note_type)
            || !str_ok(&field_name)
            || !str_ok(&field_value)
            || !str_ok(&tag)
            || !str_ok(&card_deck)
            || !str_ok(&card_tpl)
        {
            return Err("string id out of range".into());
        }
        if !monotone(&note_field_off, n_fields) || !monotone(&note_tag_off, n_tags) {
            return Err("bad note offsets".into());
        }
        if card_note.iter().any(|&n| n as usize >= n_notes) {
            return Err("card note index out of range".into());
        }
        Ok(Corpus {
            text: text.to_owned(),
            str_off,
            note_type,
            note_field_off,
            field_name,
            field_value,
            note_tag_off,
            tag,
            card_note,
            card_deck,
            card_tpl,
            ints: Default::default(),
            floats: Default::default(),
            joined: (0..n_notes).map(|_| OnceCell::new()).collect(),
            tags_joined: (0..n_notes).map(|_| OnceCell::new()).collect(),
            stripped: (0..n_fields).map(|_| OnceCell::new()).collect(),
        })
    }

    pub fn card_count(&self) -> usize {
        self.card_note.len()
    }

    pub fn set_ints(&mut self, col: usize, data: &[i64]) -> Result<(), String> {
        if col >= INT_COLUMNS || data.len() != self.card_count() {
            return Err("bad int column".into());
        }
        self.ints[col] = Some(data.to_vec());
        Ok(())
    }

    pub fn set_floats(&mut self, col: usize, data: &[f64]) -> Result<(), String> {
        if col >= FLOAT_COLUMNS || data.len() != self.card_count() {
            return Err("bad float column".into());
        }
        self.floats[col] = Some(data.to_vec());
        Ok(())
    }

    fn s(&self, id: u32) -> &str {
        let i = id as usize;
        &self.text[self.str_off[i] as usize..self.str_off[i + 1] as usize]
    }

    fn fields(&self, note: usize) -> std::ops::Range<usize> {
        self.note_field_off[note] as usize..self.note_field_off[note + 1] as usize
    }

    /// 全部字段原文用 0x1f 连接（rslib 的 `n.flds`）。
    fn joined(&self, note: usize) -> &str {
        self.joined[note].get_or_init(|| {
            let mut out = String::new();
            for (k, f) in self.fields(note).enumerate() {
                if k > 0 {
                    out.push('\x1f');
                }
                out.push_str(self.s(self.field_value[f]));
            }
            out
        })
    }

    /// `" a b c "`：标签以空格连接、两端各补一个空格。
    fn tags_joined(&self, note: usize) -> &str {
        self.tags_joined[note].get_or_init(|| {
            let mut out = String::from(" ");
            let range = self.note_tag_off[note] as usize..self.note_tag_off[note + 1] as usize;
            for (k, t) in range.enumerate() {
                if k > 0 {
                    out.push(' ');
                }
                out.push_str(self.s(self.tag[t]));
            }
            out.push(' ');
            out
        })
    }

    fn tag_count(&self, note: usize) -> usize {
        (self.note_tag_off[note + 1] - self.note_tag_off[note]) as usize
    }

    fn stripped(&self, field: usize) -> &str {
        self.stripped[field].get_or_init(|| strip_html(self.s(self.field_value[field])))
    }

    fn int_col(&self, col: IntColumn) -> Result<&[i64], SearchError> {
        self.ints[col as usize]
            .as_deref()
            .ok_or_else(|| SearchError::internal(format!("column {col:?} not set")))
    }

    fn float_col(&self, col: FloatColumn) -> Result<&[f64], SearchError> {
        self.floats[col as usize]
            .as_deref()
            .ok_or_else(|| SearchError::internal(format!("column {col:?} not set")))
    }

    /// 对整批卡求值：`out[i]` = 第 i 张卡是否命中（1 / 0）；返回命中数。
    pub fn search(&self, query: &str, out: &mut [u8]) -> Result<usize, SearchError> {
        if out.len() != self.card_count() {
            return Err(SearchError::internal("output length != card count"));
        }
        let node: Node = serde_json::from_str(query)
            .map_err(|e| SearchError::internal(format!("bad query json: {e}")))?;
        let compiled = compile(&node)?;
        let all: Vec<u32> = (0..self.card_count() as u32).collect();
        let hits = self.eval(&compiled, all)?;
        out.fill(0);
        for &i in &hits {
            out[i as usize] = 1;
        }
        Ok(hits.len())
    }

    /// 求值 [node]，只看 [cand]（升序的卡片下标），返回其中命中的（仍升序）。
    fn eval(&self, node: &Compiled, cand: Vec<u32>) -> Result<Vec<u32>, SearchError> {
        if cand.is_empty() {
            return Ok(cand);
        }
        Ok(match node {
            Compiled::All => cand,
            Compiled::And(children) => {
                let mut cur = cand;
                for c in children {
                    cur = self.eval(c, cur)?;
                    if cur.is_empty() {
                        break;
                    }
                }
                cur
            }
            Compiled::Or(children) => {
                let mut hit = vec![false; self.card_count()];
                let mut rest = cand.clone();
                for c in children {
                    if rest.is_empty() {
                        break;
                    }
                    let h = self.eval(c, rest.clone())?;
                    for &i in &h {
                        hit[i as usize] = true;
                    }
                    rest.retain(|&i| !hit[i as usize]);
                }
                cand.into_iter().filter(|&i| hit[i as usize]).collect()
            }
            Compiled::Not(child) => {
                let h = self.eval(child, cand.clone())?;
                let mut hit = vec![false; self.card_count()];
                for &i in &h {
                    hit[i as usize] = true;
                }
                cand.into_iter().filter(|&i| !hit[i as usize]).collect()
            }
            Compiled::Text(re) => self.by_note(cand, |n| re.is_match(self.joined(n))),
            Compiled::Regex(re) => self.by_note(cand, |n| re.is_match(self.joined(n))),
            Compiled::Field { name, value } => {
                let mut names = StrMemo::new(name);
                self.by_note(cand, |n| {
                    self.fields(n).any(|f| {
                        names.matches(self, self.field_name[f])
                            && (value.is_match(self.stripped(f))
                                || value.is_match(self.s(self.field_value[f])))
                    })
                })
            }
            Compiled::FieldRegex { name, value } => {
                let mut names = StrMemo::new(name);
                self.by_note(cand, |n| {
                    self.fields(n).any(|f| {
                        names.matches(self, self.field_name[f])
                            && value.is_match(self.s(self.field_value[f]))
                    })
                })
            }
            Compiled::Deck(None) => cand,
            Compiled::Deck(Some(re)) => {
                let mut memo = StrMemo::new(re);
                cand.into_iter()
                    .filter(|&i| memo.matches(self, self.card_deck[i as usize]))
                    .collect()
            }
            Compiled::NoteType(re) => {
                let mut memo = StrMemo::new(re);
                cand.into_iter()
                    .filter(|&i| {
                        memo.matches(self, self.note_type[self.card_note[i as usize] as usize])
                    })
                    .collect()
            }
            Compiled::TagNone => self.by_note(cand, |n| self.tag_count(n) == 0),
            Compiled::Never => Vec::new(),
            Compiled::Tag(re) => self.by_note(cand, |n| re.is_match(self.tags_joined(n))),
            Compiled::State(bit) => {
                let col = self.int_col(IntColumn::State)?;
                cand.into_iter()
                    .filter(|&i| col[i as usize] & bit != 0)
                    .collect()
            }
            Compiled::IntEq(column, v) => {
                let col = self.int_col(*column)?;
                cand.into_iter()
                    .filter(|&i| col[i as usize] == *v)
                    .collect()
            }
            Compiled::CardName(re) => {
                let mut memo = StrMemo::new(re);
                cand.into_iter()
                    .filter(|&i| memo.matches(self, self.card_tpl[i as usize]))
                    .collect()
            }
            Compiled::WithinDays(column, days) => {
                let col = self.int_col(*column)?;
                let today = self.int_col(IntColumn::Today)?;
                cand.into_iter()
                    .filter(|&i| col[i as usize] > today[i as usize] - days)
                    .collect()
            }
            Compiled::IntProp(column, cmp, v) => {
                let col = self.int_col(*column)?;
                cand.into_iter()
                    .filter(|&i| {
                        let a = col[i as usize];
                        !(*column == IntColumn::Due && a == DUE_NONE) && cmp.ints(a, *v)
                    })
                    .collect()
            }
            Compiled::FloatProp(prop, cmp, v) => {
                let col = self.float_col(*prop)?;
                cand.into_iter()
                    .filter(|&i| {
                        let raw = col[i as usize];
                        if raw.is_nan() {
                            return false;
                        }
                        // Anki 把难度显示成 0–100%：prop:d 比的是 (d - 1) / 9。
                        let a = if *prop == FloatColumn::Difficulty {
                            (raw - 1.0) / 9.0
                        } else {
                            raw
                        };
                        cmp.floats(a, *v)
                    })
                    .collect()
            }
            Compiled::IdIn(column, ids) => {
                let col = self.int_col(*column)?;
                cand.into_iter()
                    .filter(|&i| ids.contains(&col[i as usize]))
                    .collect()
            }
        })
    }

    /// 笔记级谓词：同一条笔记只算一次。
    fn by_note(&self, cand: Vec<u32>, mut pred: impl FnMut(usize) -> bool) -> Vec<u32> {
        let mut memo: HashMap<u32, bool> = HashMap::new();
        cand.into_iter()
            .filter(|&i| {
                let n = self.card_note[i as usize];
                *memo.entry(n).or_insert_with(|| pred(n as usize))
            })
            .collect()
    }
}

/// 按字符串 id 记忆化的匹配（牌组名 / 模板名 / 字段名，重复极多）。
struct StrMemo<'r> {
    re: &'r Regex,
    memo: HashMap<u32, bool>,
}

impl<'r> StrMemo<'r> {
    fn new(re: &'r Regex) -> Self {
        StrMemo {
            re,
            memo: HashMap::new(),
        }
    }

    fn matches(&mut self, corpus: &Corpus, id: u32) -> bool {
        let re = self.re;
        *self
            .memo
            .entry(id)
            .or_insert_with(|| re.is_match(corpus.s(id)))
    }
}

// ------------------------------------------------------------------ 语法树

/// Dart `SrsSearchNode` 的 JSON 形状（`t` 区分种类）。叶子里的文本保留 Anki 的通配转义。
#[derive(Deserialize, Debug)]
#[serde(tag = "t", rename_all = "lowercase")]
pub enum Node {
    All,
    And {
        c: Vec<Node>,
    },
    Or {
        c: Vec<Node>,
    },
    Not {
        c: Box<Node>,
    },
    Text {
        v: String,
    },
    Field {
        f: String,
        v: String,
    },
    Deck {
        v: String,
    },
    Note {
        v: String,
    },
    Tag {
        v: String,
    },
    State {
        v: String,
    },
    Re {
        v: String,
        at: String,
    },
    Fre {
        f: String,
        v: String,
        at: String,
    },
    Flag {
        v: i64,
    },
    Cardord {
        v: i64,
    },
    Cardname {
        v: String,
    },
    Edited {
        v: i64,
    },
    Added {
        v: i64,
    },
    Prop {
        p: String,
        op: String,
        v: f64,
        #[serde(default)]
        iv: Option<i64>,
    },
    Nid {
        v: Vec<i64>,
    },
    Cid {
        v: Vec<i64>,
    },
}

#[derive(Clone, Copy, Debug)]
enum Cmp {
    Eq,
    Ne,
    Lt,
    Le,
    Gt,
    Ge,
}

impl Cmp {
    fn parse(s: &str) -> Result<Cmp, SearchError> {
        Ok(match s {
            "eq" => Cmp::Eq,
            "ne" => Cmp::Ne,
            "lt" => Cmp::Lt,
            "le" => Cmp::Le,
            "gt" => Cmp::Gt,
            "ge" => Cmp::Ge,
            _ => return Err(SearchError::internal(format!("bad compare {s}"))),
        })
    }

    fn ints(self, a: i64, v: i64) -> bool {
        match self {
            Cmp::Eq => a == v,
            Cmp::Ne => a != v,
            Cmp::Lt => a < v,
            Cmp::Le => a <= v,
            Cmp::Gt => a > v,
            Cmp::Ge => a >= v,
        }
    }

    /// 小数属性用 1e-9 容差判等（避免 0.1 + 0.2 之类的浮点误差）。
    fn floats(self, a: f64, v: f64) -> bool {
        let eq = (a - v).abs() < 1e-9;
        match self {
            Cmp::Eq => eq,
            Cmp::Ne => !eq,
            Cmp::Lt => !eq && a < v,
            Cmp::Le => eq || a < v,
            Cmp::Gt => !eq && a > v,
            Cmp::Ge => eq || a > v,
        }
    }
}

enum Compiled {
    All,
    Never,
    And(Vec<Compiled>),
    Or(Vec<Compiled>),
    Not(Box<Compiled>),
    Text(Regex),
    Regex(Regex),
    Field { name: Regex, value: Regex },
    FieldRegex { name: Regex, value: Regex },
    Deck(Option<Regex>),
    NoteType(Regex),
    TagNone,
    Tag(Regex),
    State(i64),
    IntEq(IntColumn, i64),
    CardName(Regex),
    WithinDays(IntColumn, i64),
    IntProp(IntColumn, Cmp, i64),
    FloatProp(FloatColumn, Cmp, f64),
    IdIn(IntColumn, HashSet<i64>),
}

fn glob_re(source: &str) -> Result<Regex, SearchError> {
    RegexBuilder::new(source)
        .case_insensitive(true)
        .dot_matches_new_line(true)
        .build()
        // 通配串只会转义出合法正则，编不过只可能是超过 regex 的大小上限：算查询本身的问题。
        .map_err(|e| SearchError {
            kind: "syntax",
            reason: format!("search text too large: {e}"),
            at: String::new(),
        })
}

fn anchored_glob(text: &str) -> Result<Regex, SearchError> {
    glob_re(&format!("^{}$", glob_to_re(text, ".")))
}

/// `re:` 的正则：与 rslib 一样在用户写的正则前加 `(?i)`（开头写 `(?-i)` 即改回区分大小写）。
fn user_re(source: &str, at: &str) -> Result<Regex, SearchError> {
    Regex::new(&format!("(?i){source}")).map_err(|e| SearchError {
        kind: "syntax",
        reason: format!("invalid regular expression: {e}"),
        at: at.to_owned(),
    })
}

fn compile(node: &Node) -> Result<Compiled, SearchError> {
    Ok(match node {
        Node::All => Compiled::All,
        Node::And { c } => Compiled::And(c.iter().map(compile).collect::<Result<_, _>>()?),
        Node::Or { c } => Compiled::Or(c.iter().map(compile).collect::<Result<_, _>>()?),
        Node::Not { c } => Compiled::Not(Box::new(compile(c)?)),
        // rslib：`n.flds like '%text%'`——字段原文用 0x1f 连起来做包含匹配。
        Node::Text { v } => Compiled::Text(glob_re(&glob_to_re(v, "."))?),
        Node::Field { f, v } => Compiled::Field {
            name: anchored_glob(f)?,
            value: anchored_glob(v)?,
        },
        Node::Deck { v } if v == "*" => Compiled::Deck(None),
        Node::Deck { v } => {
            Compiled::Deck(Some(glob_re(&format!("^{}(?:$|::)", glob_to_re(v, ".")))?))
        }
        Node::Note { v } => Compiled::NoteType(anchored_glob(v)?),
        Node::Tag { v } if v == "none" => Compiled::TagNone,
        Node::Tag { v } if v == "*" => Compiled::All,
        Node::Tag { v } if v.contains(' ') => Compiled::Never,
        // 标签通配 `_` / `*` 只匹配非空白（rslib 同）。
        Node::Tag { v } => Compiled::Tag(glob_re(&format!(" {}(?:::| )", glob_to_re(v, r"\S")))?),
        Node::State { v } => Compiled::State(match v.as_str() {
            "new" => STATE_NEW,
            "learn" => STATE_LEARN,
            "review" => STATE_REVIEW,
            "due" => STATE_DUE,
            "suspended" => STATE_SUSPENDED,
            "buried" => STATE_BURIED,
            _ => return Err(SearchError::internal(format!("bad state {v}"))),
        }),
        // rslib：未限定字段的 `re:` 对 `n.flds`（0x1f 连接）求值。
        Node::Re { v, at } => Compiled::Regex(user_re(v, at)?),
        Node::Fre { f, v, at } => Compiled::FieldRegex {
            name: anchored_glob(f)?,
            value: user_re(v, at)?,
        },
        Node::Flag { v } => Compiled::IntEq(IntColumn::Flag, *v),
        Node::Cardord { v } => Compiled::IntEq(IntColumn::Ordinal, *v),
        Node::Cardname { v } => Compiled::CardName(anchored_glob(v)?),
        Node::Edited { v } => Compiled::WithinDays(IntColumn::EditedDay, *v),
        Node::Added { v } => Compiled::WithinDays(IntColumn::AddedDay, *v),
        Node::Prop { p, op, v, iv } => {
            let cmp = Cmp::parse(op)?;
            let int_col = match p.as_str() {
                "ivl" => Some(IntColumn::Interval),
                "due" => Some(IntColumn::Due),
                "reps" => Some(IntColumn::Reps),
                "lapses" => Some(IntColumn::Lapses),
                _ => None,
            };
            match (int_col, p.as_str()) {
                (Some(col), _) => {
                    let value = iv.ok_or_else(|| SearchError::internal("int prop without iv"))?;
                    Compiled::IntProp(col, cmp, value)
                }
                (None, "s") => Compiled::FloatProp(FloatColumn::Stability, cmp, *v),
                (None, "d") => Compiled::FloatProp(FloatColumn::Difficulty, cmp, *v),
                _ => return Err(SearchError::internal(format!("bad prop {p}"))),
            }
        }
        Node::Nid { v } => Compiled::IdIn(IntColumn::NoteId, v.iter().copied().collect()),
        Node::Cid { v } => Compiled::IdIn(IntColumn::CardId, v.iter().copied().collect()),
    })
}

/// Anki 通配文本 → 正则源码（rslib text.rs `to_custom_re`）：`*` → `<wildcard>*`、
/// `_` → `<wildcard>`、`\*` / `\\` 为字面量、`\_` 为字面量下划线，其余字符全部转义。
pub fn glob_to_re(text: &str, wildcard: &str) -> String {
    let mut out = String::with_capacity(text.len() + 8);
    let mut chars = text.chars().peekable();
    let mut buf = [0u8; 4];
    while let Some(c) = chars.next() {
        if c == '\\' {
            if let Some(next) = chars.next() {
                match next {
                    '\\' => out.push_str(r"\\"),
                    '*' => out.push_str(r"\*"),
                    '_' => out.push('_'),
                    _ => {
                        out.push_str(r"\\");
                        out.push_str(&regex::escape(next.encode_utf8(&mut buf)));
                    }
                }
                continue;
            }
        }
        match c {
            '*' => {
                out.push_str(wildcard);
                out.push('*');
            }
            '_' => out.push_str(wildcard),
            _ => out.push_str(&regex::escape(c.encode_utf8(&mut buf))),
        }
    }
    out
}

// ------------------------------------------------------------------ 去 HTML

thread_local! {
    // rslib text.rs `strip_html` 的同一条正则（`(?si)`）。
    static HTML: Regex = Regex::new(concat!(
        "(?si)",
        r"(<!--.*?-->)|(<style.*?>.*?</style>)|(<script.*?>.*?</script>)",
        r"|(<.*?>)",
    ))
    .unwrap();
    static ENTITY: Regex = Regex::new(r"&(#[0-9]+|#[xX][0-9a-fA-F]+|[A-Za-z]+);").unwrap();
}

/// 去掉 HTML 标签并解码实体（数字实体与常用命名实体；`&nbsp;` / `&#160;` 解成空格）。
pub fn strip_html(html: &str) -> String {
    let stripped = HTML.with(|re| re.replace_all(html, "").into_owned());
    if !stripped.contains('&') {
        return stripped;
    }
    ENTITY.with(|re| {
        re.replace_all(&stripped, |caps: &regex::Captures| {
            let whole = caps.get(0).unwrap().as_str();
            let body = caps.get(1).unwrap().as_str();
            if let Some(num) = body.strip_prefix('#') {
                let parsed = match num.strip_prefix(['x', 'X']) {
                    Some(hex) => u64::from_str_radix(hex, 16).ok(),
                    None => num.parse::<u64>().ok(),
                };
                return match parsed {
                    Some(code) if code <= 0x10FFFF => {
                        if code == 0xA0 {
                            " ".to_string()
                        } else {
                            // 代理区码点不是 Unicode 标量值：记成 U+FFFD（Dart 侧原本得到孤立代理，
                            // 转 UTF-8 时同样变成 U+FFFD）。
                            char::from_u32(code as u32)
                                .unwrap_or('\u{FFFD}')
                                .to_string()
                        }
                    }
                    _ => whole.to_string(),
                };
            }
            match body {
                "amp" => "&",
                "lt" => "<",
                "gt" => ">",
                "quot" => "\"",
                "apos" => "'",
                "nbsp" => " ",
                _ => whole,
            }
            .to_string()
        })
        .into_owned()
    })
}

// ------------------------------------------------------------------ 查重规范形

/// Dart `String.trim` 的空白：Unicode White_Space 加 BOM（U+FEFF）。
fn is_dart_trim_space(c: char) -> bool {
    c.is_whitespace() || c == '\u{FEFF}'
}

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

/// `<script\b[\s\S]*?</script\s*>`（不区分 ASCII 大小写）的全部匹配区间。
fn script_blocks(text: &str) -> Vec<(usize, usize)> {
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

/// 释义样式去重（Dart `srsDedupStyles`）里「换成引用行」的那一步：够大的无属性 `<style>` 块
/// 换成一个标签。引用行在之后的去 HTML 里整个被删掉，内容与 Dart 的规范引用行等价，所以这里只放
/// 一个最短的占位标签。
fn dedup_styles_for_norm(html: &str) -> String {
    const OPEN: &str = "<style>";
    const CLOSE: &str = "</style>";
    if !html.contains(OPEN) {
        return html.to_owned();
    }
    let chunk_dedup = |chunk: &str, out: &mut String| {
        let mut i = 0;
        loop {
            let Some(rel) = chunk[i..].find(OPEN) else {
                break;
            };
            let start = i + rel;
            let body_start = start + OPEN.len();
            let Some(rel_end) = chunk[body_start..].find(CLOSE) else {
                break;
            };
            let end = body_start + rel_end;
            let css = &chunk[body_start..end];
            if css.encode_utf16().count() < 512 || css.contains(OPEN) {
                out.push_str(&chunk[i..body_start]);
                i = body_start;
                continue;
            }
            out.push_str(&chunk[i..start]);
            out.push_str("<link>");
            i = end + CLOSE.len();
        }
        out.push_str(&chunk[i..]);
    };
    let mut out = String::with_capacity(html.len());
    let mut last = 0;
    for (s, e) in script_blocks(html) {
        chunk_dedup(&html[last..s], &mut out);
        out.push_str(&html[s..e]);
        last = e;
    }
    chunk_dedup(&html[last..], &mut out);
    out
}

/// AnkiConnect 查重比较用的首字段规范形：先按样式去重规范形，再去 HTML，再 trim。
pub fn dupe_norm(field: &str) -> String {
    strip_html(&dedup_styles_for_norm(field))
        .trim_matches(is_dart_trim_space)
        .to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn corpus(notes: &[(&str, &[(&str, &str)], &[&str])], cards: &[(usize, &str, &str)]) -> Corpus {
        let mut strs: Vec<String> = Vec::new();
        let id = |s: &str, strs: &mut Vec<String>| -> u32 {
            strs.push(s.to_owned());
            (strs.len() - 1) as u32
        };
        let (mut nt, mut nfo, mut fname, mut fval, mut nto, mut tags) =
            (vec![], vec![0u32], vec![], vec![], vec![0u32], vec![]);
        for (ty, fields, ts) in notes {
            nt.push(id(ty, &mut strs));
            for (n, v) in fields.iter() {
                fname.push(id(n, &mut strs));
                fval.push(id(v, &mut strs));
            }
            nfo.push(fname.len() as u32);
            for t in ts.iter() {
                tags.push(id(t, &mut strs));
            }
            nto.push(tags.len() as u32);
        }
        let (mut cn, mut cd, mut ct) = (vec![], vec![], vec![]);
        for (n, d, t) in cards {
            cn.push(*n as u32);
            cd.push(id(d, &mut strs));
            ct.push(id(t, &mut strs));
        }
        let mut text = String::new();
        let mut off = vec![0u32];
        for s in &strs {
            text.push_str(s);
            off.push(text.len() as u32);
        }
        let mut layout = vec![
            strs.len() as u32,
            notes.len() as u32,
            fname.len() as u32,
            tags.len() as u32,
            cards.len() as u32,
        ];
        for part in [&off, &nt, &nfo, &fname, &fval, &nto, &tags, &cn, &cd, &ct] {
            layout.extend_from_slice(part);
        }
        Corpus::new(text.as_bytes(), &layout).unwrap()
    }

    fn hits(c: &Corpus, q: serde_json::Value) -> Vec<u8> {
        let mut out = vec![0u8; c.card_count()];
        c.search(&q.to_string(), &mut out).unwrap();
        out
    }

    #[test]
    fn text_field_deck_tag() {
        let c = corpus(
            &[
                (
                    "Lapis",
                    &[("Expression", "<b>食べる</b>"), ("Meaning", "to eat")],
                    &["n5", "verb::ichidan"],
                ),
                ("Basic", &[("Front", "Straße"), ("Back", "")], &[]),
            ],
            &[
                (0, "Japanese::Mining", "Card 1"),
                (0, "Japanese", "Card 2"),
                (1, "Default", "Card 1"),
            ],
        );
        use serde_json::json;
        assert_eq!(hits(&c, json!({"t":"text","v":"食べ"})), [1, 1, 0]);
        assert_eq!(hits(&c, json!({"t":"text","v":"STRASSE"})), [0, 0, 0]);
        assert_eq!(hits(&c, json!({"t":"text","v":"STRAẞE"})), [0, 0, 1]);
        assert_eq!(
            hits(&c, json!({"t":"field","f":"expr*","v":"食べる"})),
            [1, 1, 0]
        );
        assert_eq!(hits(&c, json!({"t":"deck","v":"japanese"})), [1, 1, 0]);
        assert_eq!(hits(&c, json!({"t":"deck","v":"japanese::m*"})), [1, 0, 0]);
        assert_eq!(hits(&c, json!({"t":"tag","v":"verb"})), [1, 1, 0]);
        assert_eq!(hits(&c, json!({"t":"tag","v":"none"})), [0, 0, 1]);
        assert_eq!(hits(&c, json!({"t":"cardname","v":"card 2"})), [0, 1, 0]);
        assert_eq!(
            hits(
                &c,
                json!({"t":"or","c":[{"t":"note","v":"basic"},{"t":"not","c":{"t":"deck","v":"japanese::mining"}}]})
            ),
            [0, 1, 1]
        );
        assert_eq!(
            hits(&c, json!({"t":"re","v":"(?-i)straße","at":"re:x"})),
            [0, 0, 0]
        );
        assert_eq!(
            hits(&c, json!({"t":"re","v":"\\w+る","at":"re:x"})),
            [1, 1, 0]
        );
    }

    #[test]
    fn columns_and_errors() {
        let mut c = corpus(
            &[("B", &[("F", "x")], &[])],
            &[(0, "D", "T"), (0, "D", "T")],
        );
        use serde_json::json;
        let q = json!({"t":"prop","p":"due","op":"le","v":0.0,"iv":0}).to_string();
        let mut out = vec![0u8; 2];
        assert_eq!(c.search(&q, &mut out).unwrap_err().kind, "internal");
        c.set_ints(IntColumn::Due as usize, &[DUE_NONE, -3])
            .unwrap();
        assert_eq!(
            hits(&c, json!({"t":"prop","p":"due","op":"le","v":0.0,"iv":0})),
            [0, 1]
        );
        c.set_floats(FloatColumn::Difficulty as usize, &[f64::NAN, 10.0])
            .unwrap();
        assert_eq!(
            hits(&c, json!({"t":"prop","p":"d","op":"eq","v":1.0})),
            [0, 1]
        );
        let err = c
            .search(
                &json!({"t":"re","v":"(?=a)","at":"re:(?=a)"}).to_string(),
                &mut out,
            )
            .unwrap_err();
        assert_eq!((err.kind, err.at.as_str()), ("syntax", "re:(?=a)"));
        assert!(c.set_ints(0, &[1]).is_err());
    }

    #[test]
    fn strip_and_norm() {
        assert_eq!(
            strip_html("a<b>b</b><!-- c --><STYLE x>d</style>&amp;&#x41;&#160;&nbsp;&zz;"),
            "ab&A  &zz;"
        );
        assert_eq!(strip_html("&#55296;&#1114112;"), "\u{FFFD}&#1114112;");
        let css = "x".repeat(600);
        let field = format!(" <style>{css}</STYLE>tail</style> 語 \u{FEFF}");
        // 样式去重只认小写 `</style>`：整块换掉，`tail` 不会漏出来。
        assert_eq!(dupe_norm(&field), "語");
        // 去 HTML 的正则不区分大小写，停在 `</STYLE>`，`tail` 留下（Anki 同）。
        assert_eq!(strip_html(&field), " tail 語 \u{FEFF}");
        assert_eq!(
            dupe_norm(&format!("<script><style>{css}</style></script >語")),
            "語"
        );
    }

    #[test]
    fn glob() {
        assert_eq!(glob_to_re(r"a*b_c\*\_\\\:", "."), r"a.*b.c\*_\\\\:");
        assert_eq!(glob_to_re("x\\", "."), r"x\\");
    }
}
