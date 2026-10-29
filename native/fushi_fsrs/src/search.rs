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
use std::sync::Arc;

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
///
/// 结构（名字、标签、牌组、模板、字段排布）建语料时一次给齐；**字段值按需上传**
/// （[`Corpus::needs`] 说出一条查询要哪些字段名的值，调用方用 [`Corpus::set_values`] 补上），
/// 只碰状态 / 牌组 / 标签的查询完全不用传字段文本，`字段名:值` 只传那一列。
pub struct Corpus {
    /// 名字类小字符串（笔记类型名、字段名、标签、牌组名、模板名）的拼接，Dart 侧去重过。
    text: String,
    str_off: Vec<u32>,
    note_type: Vec<u32>,
    /// 第 i 条笔记的字段 = `note_field_off[i]..note_field_off[i+1]`（由字段排布推出）。
    note_field_off: Vec<u32>,
    /// 每个字段的字段名（字符串 id）。
    field_name: Vec<u32>,
    /// 每个字段的别名（字符串 id；[`NO_ALIAS`] = 没有）。`字段名:值` 按名字或别名命中——内置 Fushi 卡片
    /// 改过名的字段用它认旧名（`Expression:食べる` 仍查到 `Term` 字段），别名表由调用方按笔记类型给出。
    field_alias: Vec<u32>,
    note_tag_off: Vec<u32>,
    tag: Vec<u32>,
    card_note: Vec<u32>,
    card_deck: Vec<u32>,
    card_tpl: Vec<u32>,
    /// 出现过的字段名（去重）。建语料后不再变，与 FFI 句柄共享：需求分析不进语料锁。
    field_names: Arc<FieldNames>,
    /// 字段值：分批上传的文本块与每个字段在块里的位置（`chunk == MISSING` = 还没传）。
    chunks: Vec<String>,
    /// 每块还被多少个字段引用；降到 0（全被后来的上传覆盖）就释放那块文本。
    chunk_refs: Vec<u32>,
    value_loc: Vec<ValueLoc>,
    ints: [Option<Vec<i64>>; INT_COLUMNS],
    floats: [Option<Vec<f64>>; FLOAT_COLUMNS],
    joined: Vec<OnceCell<String>>,
    tags_joined: Vec<OnceCell<String>>,
    stripped: Vec<OnceCell<String>>,
}

#[derive(Clone, Copy)]
struct ValueLoc {
    chunk: u32,
    start: u32,
    end: u32,
}

const MISSING: u32 = u32::MAX;

/// 布局里「这个字段没有别名」。
pub const NO_ALIAS: u32 = u32::MAX;

/// 一条查询要的字段值：全部（未限定字段的文本 / `re:`）或若干字段名（字符串 id）。
#[derive(Debug, PartialEq)]
pub enum Needs {
    All,
    Names(Vec<u32>),
}

/// 语料里出现过的字段名（字符串 id 升序去重，连同名字文本）。只由建语料时的结构决定，之后任何
/// 上传都不改它，所以只读、可跨线程共享：[`FieldNames::needs`] 不碰字段值与惰性缓存，FFI 侧
/// 不必为它去抢后台求值持着的语料锁。
pub struct FieldNames {
    ids: Vec<u32>,
    names: Vec<String>,
    /// 与 [ids] 对齐：这个字段名在各排布里带的别名（去重）。
    aliases: Vec<Vec<String>>,
}

impl FieldNames {
    /// 名字被 [res] 中任一正则命中的字段名 id（升序）。
    fn matching(&self, res: &[&Regex]) -> Vec<u32> {
        self.ids
            .iter()
            .zip(self.names.iter().zip(&self.aliases))
            .filter(|(_, (name, aliases))| {
                res.iter()
                    .any(|re| re.is_match(name) || aliases.iter().any(|a| re.is_match(a)))
            })
            .map(|(&id, _)| id)
            .collect()
    }

    /// 一条查询求值要的字段值（不看已经上传了哪些）。查询本身不合法时报错（与 [`Corpus::search`]
    /// 同一个错误）。
    pub fn needs(&self, query: &str) -> Result<Needs, SearchError> {
        Ok(self.needs_of(&Corpus::parse(query)?))
    }

    fn needs_of(&self, compiled: &Compiled) -> Needs {
        let mut name_res: Vec<&Regex> = Vec::new();
        if collect_needs(compiled, &mut name_res) {
            return Needs::All;
        }
        Needs::Names(self.matching(&name_res))
    }
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

/// 去 HTML 一次至少分给一个线程的字段数（少于它不开线程）。
const PARALLEL_STRIP_MIN: usize = 512;

/// 布局数组（u32）：`[n_str, n_schemas, n_schema_names, n_notes, n_tags, n_cards,
/// str_off(n_str+1), schema_off(n_schemas+1), schema_names(n_schema_names),
/// schema_alias(n_schema_names), note_type(n_notes),
/// note_schema(n_notes), note_tag_off(n_notes+1), tag(n_tags), card_note(n_cards),
/// card_deck(n_cards), card_tpl(n_cards)]`。`text` 是全部名字类字符串的 UTF-8 拼接，
/// 第 i 个串 = `text[str_off[i]..str_off[i+1]]`。字段排布（schema）= 一串字段名 id，
/// 同一笔记类型的笔记共用一份；笔记的字段按排布顺序编号。`schema_alias` 与 `schema_names` 逐项对齐：
/// 该字段的别名字符串 id，没有为 [`NO_ALIAS`]。
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
        let header = take(6)?;
        let (n_str, n_schemas, n_schema_names, n_notes, n_tags, n_cards) = (
            header[0] as usize,
            header[1] as usize,
            header[2] as usize,
            header[3] as usize,
            header[4] as usize,
            header[5] as usize,
        );
        let str_off = take(n_str + 1)?;
        let schema_off = take(n_schemas + 1)?;
        let schema_names = take(n_schema_names)?;
        let schema_alias = take(n_schema_names)?;
        let note_type = take(n_notes)?;
        let note_schema = take(n_notes)?;
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
            || !str_ok(&schema_names)
            || !schema_alias.iter().all(|&a| a == NO_ALIAS || (a as usize) < n_str)
            || !str_ok(&tag)
            || !str_ok(&card_deck)
            || !str_ok(&card_tpl)
        {
            return Err("string id out of range".into());
        }
        if !monotone(&schema_off, n_schema_names) || !monotone(&note_tag_off, n_tags) {
            return Err("bad offsets".into());
        }
        if note_schema.iter().any(|&s| s as usize >= n_schemas) {
            return Err("note schema index out of range".into());
        }
        if card_note.iter().any(|&n| n as usize >= n_notes) {
            return Err("card note index out of range".into());
        }
        let mut note_field_off = Vec::with_capacity(n_notes + 1);
        let mut field_name = Vec::new();
        let mut field_alias = Vec::new();
        note_field_off.push(0u32);
        for &s in &note_schema {
            let range = schema_off[s as usize] as usize..schema_off[s as usize + 1] as usize;
            field_name.extend_from_slice(&schema_names[range.clone()]);
            field_alias.extend_from_slice(&schema_alias[range]);
            note_field_off.push(u32::try_from(field_name.len()).map_err(|_| "too many fields")?);
        }
        let mut name_ids: Vec<u32> = schema_names.clone();
        name_ids.sort_unstable();
        name_ids.dedup();
        let str_of = |i: u32| text[str_off[i as usize] as usize..str_off[i as usize + 1] as usize].to_owned();
        let mut aliases: Vec<Vec<String>> = vec![Vec::new(); name_ids.len()];
        for (&n, &a) in schema_names.iter().zip(&schema_alias) {
            if a == NO_ALIAS {
                continue;
            }
            let k = name_ids.binary_search(&n).map_err(|_| "schema name missing")?;
            let alias = str_of(a);
            if !aliases[k].contains(&alias) {
                aliases[k].push(alias);
            }
        }
        let field_names = Arc::new(FieldNames {
            names: name_ids.iter().map(|&i| str_of(i)).collect(),
            ids: name_ids,
            aliases,
        });
        let n_fields = field_name.len();
        Ok(Corpus {
            text: text.to_owned(),
            str_off,
            note_type,
            note_field_off,
            field_name,
            field_alias,
            note_tag_off,
            tag,
            card_note,
            card_deck,
            card_tpl,
            field_names,
            chunks: Vec::new(),
            chunk_refs: Vec::new(),
            value_loc: vec![
                ValueLoc {
                    chunk: MISSING,
                    start: 0,
                    end: 0
                };
                n_fields
            ],
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

    pub fn field_count(&self) -> usize {
        self.field_name.len()
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

    /// 上传一批字段值：第 k 个值 = `text[spans[2k]..spans[2k+1]]`，属于字段 `fields[k]`
    /// （值之间可以有间隙）。已有值的字段被覆盖、缓存作废。
    ///
    /// 同一条笔记的字段若按顺序紧挨着、中间各隔一个 0x1f 字节，拼接文本（`n.flds`）直接取这段
    /// 切片，不再另拷一份。
    pub fn set_values(&mut self, fields: &[u32], text: &[u8], spans: &[u32]) -> Result<(), String> {
        let text = std::str::from_utf8(text).map_err(|e| format!("values are not UTF-8: {e}"))?;
        self.attach(text.to_owned(), fields, spans)
    }

    /// [Corpus::set_values]，文本已是校验过的 `String`（所有权转给语料，不再拷贝）。
    pub fn attach(&mut self, text: String, fields: &[u32], spans: &[u32]) -> Result<(), String> {
        if spans.len() != fields.len() * 2 {
            return Err("spans length != 2 * fields".into());
        }
        for (k, &f) in fields.iter().enumerate() {
            let (a, b) = (spans[2 * k] as usize, spans[2 * k + 1] as usize);
            if f as usize >= self.field_count()
                || a > b
                || b > text.len()
                || !text.is_char_boundary(a)
                || !text.is_char_boundary(b)
            {
                return Err("bad field value".into());
            }
        }
        let chunk = u32::try_from(self.chunks.len()).map_err(|_| "too many chunks")?;
        self.chunks.push(text);
        self.chunk_refs.push(0);
        for (k, &f) in fields.iter().enumerate() {
            let f = f as usize;
            let old = self.value_loc[f];
            self.chunk_refs[chunk as usize] += 1;
            if old.chunk != MISSING {
                let refs = &mut self.chunk_refs[old.chunk as usize];
                *refs -= 1;
                if *refs == 0 {
                    self.chunks[old.chunk as usize] = String::new();
                }
            }
            self.value_loc[f] = ValueLoc {
                chunk,
                start: spans[2 * k],
                end: spans[2 * k + 1],
            };
            if old.chunk != MISSING {
                self.stripped[f] = OnceCell::new();
            }
        }
        // 覆盖了字段值：拼接缓存全部作废（极少发生：Dart 侧只在补传全部字段时覆盖）。
        for cell in &mut self.joined {
            cell.take();
        }
        Ok(())
    }

    fn s(&self, id: u32) -> &str {
        let i = id as usize;
        &self.text[self.str_off[i] as usize..self.str_off[i + 1] as usize]
    }

    fn fields(&self, note: usize) -> std::ops::Range<usize> {
        self.note_field_off[note] as usize..self.note_field_off[note + 1] as usize
    }

    /// 字段原文。调用方（[`Corpus::search`]）先核对过需要的值都已上传。
    fn value(&self, field: usize) -> &str {
        let loc = self.value_loc[field];
        &self.chunks[loc.chunk as usize][loc.start as usize..loc.end as usize]
    }

    /// 全部字段原文用 0x1f 连接（rslib 的 `n.flds`）。
    fn joined(&self, note: usize) -> &str {
        let range = self.fields(note);
        if range.is_empty() {
            return "";
        }
        if let Some(slice) = self.contiguous_joined(range.clone()) {
            return slice;
        }
        self.joined[note].get_or_init(|| {
            let mut out = String::new();
            for (k, f) in range.enumerate() {
                if k > 0 {
                    out.push('\x1f');
                }
                out.push_str(self.value(f));
            }
            out
        })
    }

    fn contiguous_joined(&self, range: std::ops::Range<usize>) -> Option<&str> {
        let first = self.value_loc[range.start];
        let chunk = self.chunks.get(first.chunk as usize)?;
        let bytes = chunk.as_bytes();
        let mut end = first.end;
        for f in range.start + 1..range.end {
            let loc = self.value_loc[f];
            if loc.chunk != first.chunk
                || loc.start != end + 1
                || bytes.get(end as usize) != Some(&0x1f)
            {
                return None;
            }
            end = loc.end;
        }
        Some(&chunk[first.start as usize..end as usize])
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
        self.stripped[field].get_or_init(|| strip_html(self.value(field)))
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

    fn parse(query: &str) -> Result<Compiled, SearchError> {
        let node: Node = serde_json::from_str(query)
            .map_err(|e| SearchError::internal(format!("bad query json: {e}")))?;
        compile(&node)
    }

    /// 一条查询求值要的字段值（[`FieldNames::needs`]）。
    pub fn needs(&self, query: &str) -> Result<Needs, SearchError> {
        self.field_names.needs(query)
    }

    /// 本语料的字段名表（只读，可以拿出去在语料锁外做需求分析）。
    pub fn field_names(&self) -> Arc<FieldNames> {
        Arc::clone(&self.field_names)
    }

    /// 字段 [f] 的名字或别名命中 [names]。
    fn field_name_matches(&self, names: &mut StrMemo<'_>, f: usize) -> bool {
        names.matches(self, self.field_name[f])
            || (self.field_alias[f] != NO_ALIAS && names.matches(self, self.field_alias[f]))
    }

    /// 字段名属于 [names] 的字段（全部字段时 [names] 为 None）。
    fn needed_fields(&self, names: Option<&[u32]>) -> Vec<usize> {
        (0..self.field_count())
            .filter(|&f| names.map_or(true, |ns| ns.binary_search(&self.field_name[f]).is_ok()))
            .collect()
    }

    /// 对整批卡求值：`out[i]` = 第 i 张卡是否命中（1 / 0）；返回命中数。
    pub fn search(&self, query: &str, out: &mut [u8]) -> Result<usize, SearchError> {
        if out.len() != self.card_count() {
            return Err(SearchError::internal("output length != card count"));
        }
        let compiled = Self::parse(query)?;
        let fields = match self.field_names.needs_of(&compiled) {
            Needs::All => self.needed_fields(None),
            Needs::Names(mut names) => {
                names.sort_unstable();
                self.needed_fields(Some(&names))
            }
        };
        if fields.iter().any(|&f| self.value_loc[f].chunk == MISSING) {
            return Err(SearchError::internal("field values not uploaded"));
        }
        self.prestrip(&compiled);
        let all: Vec<u32> = (0..self.card_count() as u32).collect();
        let hits = self.eval(&compiled, all)?;
        out.fill(0);
        for &i in &hits {
            out[i as usize] = 1;
        }
        Ok(hits.len())
    }

    /// `字段名:值` 要比较去 HTML 后的值：把命中字段名、还没算过的字段并行剥好（结果与逐个惰性算
    /// 相同，只是提前、分到多个线程上）。
    fn prestrip(&self, compiled: &Compiled) {
        let mut name_res: Vec<&Regex> = Vec::new();
        collect_stripped_names(compiled, &mut name_res);
        if name_res.is_empty() {
            return;
        }
        let names = self.field_names.matching(&name_res);
        let todo: Vec<usize> = self
            .needed_fields(Some(&names))
            .into_iter()
            .filter(|&f| self.stripped[f].get().is_none())
            .collect();
        let threads = std::thread::available_parallelism()
            .map(|n| n.get())
            .unwrap_or(1)
            .min(todo.len() / PARALLEL_STRIP_MIN)
            .min(16);
        if threads < 2 {
            return; // 量小：留给求值时惰性剥。
        }
        let per = todo.len().div_ceil(threads);
        // Corpus 自己不是 Sync（惰性缓存用 OnceCell）：线程里只借只读的文本块与位置。
        let (chunks, locs) = (&self.chunks, &self.value_loc);
        let value = move |f: usize| {
            let loc = locs[f];
            &chunks[loc.chunk as usize][loc.start as usize..loc.end as usize]
        };
        let results: Vec<Vec<String>> = std::thread::scope(|scope| {
            let handles: Vec<_> = todo
                .chunks(per)
                .map(|part| {
                    scope.spawn(move || {
                        part.iter()
                            .map(|&f| strip_html(value(f)))
                            .collect::<Vec<String>>()
                    })
                })
                .collect();
            handles.into_iter().map(|h| h.join().unwrap()).collect()
        });
        for (part, stripped) in todo.chunks(per).zip(results) {
            for (&f, s) in part.iter().zip(stripped) {
                let _ = self.stripped[f].set(s);
            }
        }
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
                        self.field_name_matches(&mut names, f)
                            && (value.is_match(self.stripped(f)) || value.is_match(self.value(f)))
                    })
                })
            }
            Compiled::FieldRegex { name, value } => {
                let mut names = StrMemo::new(name);
                self.by_note(cand, |n| {
                    self.fields(n)
                        .any(|f| self.field_name_matches(&mut names, f) && value.is_match(self.value(f)))
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

/// 收集要字段值的叶子：返回 true = 要全部字段（未限定字段的文本 / `re:`），否则把限定字段的
/// 字段名正则放进 [names]。
fn collect_needs<'c>(node: &'c Compiled, names: &mut Vec<&'c Regex>) -> bool {
    match node {
        Compiled::And(c) | Compiled::Or(c) => {
            let mut all = false;
            for child in c {
                all |= collect_needs(child, names);
            }
            all
        }
        Compiled::Not(c) => collect_needs(c, names),
        Compiled::Text(_) | Compiled::Regex(_) => true,
        Compiled::Field { name, .. } | Compiled::FieldRegex { name, .. } => {
            names.push(name);
            false
        }
        _ => false,
    }
}

/// `字段名:值`（比较去 HTML 后的值）的字段名正则。
fn collect_stripped_names<'c>(node: &'c Compiled, names: &mut Vec<&'c Regex>) {
    match node {
        Compiled::And(c) | Compiled::Or(c) => c.iter().for_each(|child| collect_stripped_names(child, names)),
        Compiled::Not(c) => collect_stripped_names(c, names),
        Compiled::Field { name, .. } => names.push(name),
        _ => {}
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

/// 整值匹配的通配：`^…$`。开头 / 结尾的 `*` 译成 `.*`，在 dotall 下 `^.*` 与 `.*$` 不改变是否匹配，
/// 去掉后引擎不必把每个值从头扫到尾，能直接按子串搜索（`*词*` 是浏览页 / 统计页最常见的形状）。
fn anchored_glob(text: &str) -> Result<Regex, SearchError> {
    let body = glob_to_re(text, ".");
    let mut body = body.as_str();
    let lead = text.starts_with('*');
    if lead {
        body = &body[2..];
    }
    let trail = ends_with_wildcard(text) && body.ends_with(".*");
    if trail {
        body = &body[..body.len() - 2];
    }
    glob_re(&format!(
        "{}{body}{}",
        if lead { "" } else { "^" },
        if trail { "" } else { "$" }
    ))
}

/// 通配串是否以未转义的 `*` 结尾（前面连续的反斜杠是偶数个）。
fn ends_with_wildcard(text: &str) -> bool {
    let Some(rest) = text.strip_suffix('*') else {
        return false;
    };
    rest.bytes().rev().take_while(|&b| b == b'\\').count() % 2 == 0
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
    static ENTITY: Regex = Regex::new(r"&(#[0-9]+|#[xX][0-9a-fA-F]+|[A-Za-z]+);").unwrap();
}

/// rslib text.rs `strip_html` 那条正则
/// `(?si)(<!--.*?-->)|(<style.*?>.*?</style>)|(<script.*?>.*?</script>)|(<.*?>)` 的
/// `replace_all(…, "")`，手写成线性扫描（逐位一致，对照见测试 `strip_scanner_matches_regex`）：
/// 在每个 `<` 处按分支顺序试——注释到其后第一个 `-->`；`<style`（不区分大小写）到其后第一个 `>`，
/// 再到其后第一个 `</style>`（没有就整个分支不成立）；`<script` 同理；否则到其后第一个 `>`。
/// 都不成立的 `<` 原样保留。
fn strip_tags(html: &str) -> String {
    let bytes = html.as_bytes();
    let mut out = String::with_capacity(html.len());
    let mut last = 0;
    let mut from = 0;
    while from < bytes.len() {
        let Some(rel) = find_byte(&bytes[from..], b'<') else {
            break;
        };
        let p = from + rel;
        match tag_end(html, p) {
            Some(e) => {
                out.push_str(&html[last..p]);
                last = e;
                from = e;
            }
            // 这个 `<` 之后没有 `>`：后面任何 `<` 也凑不成标签。
            None => break,
        }
    }
    out.push_str(&html[last..]);
    out
}

fn find_byte(bytes: &[u8], b: u8) -> Option<usize> {
    bytes.iter().position(|&x| x == b)
}

/// 从 `p`（一个 `<`）起能被删掉的区间终点；`None` = `p` 之后没有 `>`（什么分支都不成立）。
fn tag_end(html: &str, p: usize) -> Option<usize> {
    let bytes = html.as_bytes();
    let gt = |from: usize| find_byte(&bytes[from..], b'>').map(|i| from + i);
    let first_gt = gt(p + 1)?;
    if html[p..].starts_with("<!--") {
        if let Some(i) = html[p + 4..].find("-->") {
            return Some(p + 4 + i + 3);
        }
    }
    for (open, close) in [("style", "/style>"), ("script", "/script>")] {
        if let Some(name_end) = match_ci(html, p + 1, open) {
            if let Some(g) = gt(name_end) {
                if let Some(e) = find_ci(html, g + 1, close) {
                    return Some(e);
                }
            }
        }
    }
    Some(first_gt + 1)
}

/// regex 的 `(?i)` 用 Unicode 简单大小写折叠：ASCII 字母大小写互通，`s` 还认 `ſ`（U+017F）。
/// 模式只有 ASCII 小写字母与标点。
fn ci_char_eq(pat: u8, c: char) -> bool {
    if c.is_ascii() {
        c.to_ascii_lowercase() == pat as char
    } else {
        pat == b's' && c == '\u{17F}'
    }
}

/// `html[at..]` 是否以 `pat` 开头（不区分大小写，见 [ci_char_eq]）；是则返回匹配终点。
fn match_ci(html: &str, at: usize, pat: &str) -> Option<usize> {
    let rest = html.get(at..)?;
    let mut end = 0;
    let mut chars = rest.chars();
    for &pb in pat.as_bytes() {
        let c = chars.next()?;
        if !ci_char_eq(pb, c) {
            return None;
        }
        end += c.len_utf8();
    }
    Some(at + end)
}

/// `html[from..]` 里第一个 `<` + 不区分大小写的 `pat` 的终点。
fn find_ci(html: &str, from: usize, pat: &str) -> Option<usize> {
    let bytes = html.as_bytes();
    let mut at = from;
    while at < bytes.len() {
        let p = at + find_byte(&bytes[at..], b'<')?;
        if let Some(e) = match_ci(html, p + 1, pat) {
            return Some(e);
        }
        at = p + 1;
    }
    None
}

/// 去掉 HTML 标签并解码实体（数字实体与常用命名实体；`&nbsp;` / `&#160;` 解成空格）。
pub fn strip_html(html: &str) -> String {
    let stripped = strip_tags(html);
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
pub(crate) fn is_dart_trim_space(c: char) -> bool {
    c.is_whitespace() || c == '\u{FEFF}'
}

/// AnkiConnect 查重比较用的首字段规范形：先按样式去重规范形，再去 HTML，再 trim。
pub fn dupe_norm(field: &str) -> String {
    // 样式去重规范形（style_dedup.rs，与字段寄存器同一份）：引用行在之后的去 HTML 里整个被删掉，
    // 这里只放一个最短的占位标签（不算 SHA-1）。
    strip_html(&crate::style_dedup::dedup_styles_with(field, &|_| "<link>".to_owned()))
        .trim_matches(is_dart_trim_space)
        .to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 测试语料：每条笔记一个字段排布；[joined_layout] 为 true 时按 Dart 补传全部字段的形状上传
    /// （同一笔记的字段紧挨着、隔 0x1f），否则每个字段值单独一块（走拼接缓存）。
    fn corpus_with(
        notes: &[(&str, &[(&str, &str)], &[&str])],
        cards: &[(usize, &str, &str)],
        joined_layout: bool,
    ) -> Corpus {
        let mut strs: Vec<String> = Vec::new();
        let id = |s: &str, strs: &mut Vec<String>| -> u32 {
            strs.push(s.to_owned());
            (strs.len() - 1) as u32
        };
        let (mut nt, mut ns, mut so, mut sn, mut sa, mut nto, mut tags) =
            (vec![], vec![], vec![0u32], vec![], vec![], vec![0u32], vec![]);
        for (k, (ty, fields, ts)) in notes.iter().enumerate() {
            nt.push(id(ty, &mut strs));
            // 测试里 `名字|别名` 表示带别名的字段。
            for (n, _) in fields.iter() {
                let (name, alias) = n.split_once('|').map_or((*n, None), |(a, b)| (a, Some(b)));
                sn.push(id(name, &mut strs));
                sa.push(alias.map_or(NO_ALIAS, |a| id(a, &mut strs)));
            }
            so.push(sn.len() as u32);
            ns.push(k as u32);
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
            sn.len() as u32,
            notes.len() as u32,
            tags.len() as u32,
            cards.len() as u32,
        ];
        for part in [&off, &so, &sn, &sa, &nt, &ns, &nto, &tags, &cn, &cd, &ct] {
            layout.extend_from_slice(part);
        }
        let mut c = Corpus::new(text.as_bytes(), &layout).unwrap();
        let mut f = 0u32;
        let (mut vals, mut fids, mut spans) = (String::new(), vec![], vec![]);
        for (_, fields, _) in notes {
            for (k, (_, v)) in fields.iter().enumerate() {
                if joined_layout {
                    if k > 0 {
                        vals.push('');
                    }
                    spans.push(vals.len() as u32);
                    vals.push_str(v);
                    spans.push(vals.len() as u32);
                    fids.push(f);
                } else {
                    c.set_values(&[f], v.as_bytes(), &[0, v.len() as u32]).unwrap();
                }
                f += 1;
            }
        }
        if joined_layout {
            c.set_values(&fids, vals.as_bytes(), &spans).unwrap();
        }
        c
    }

    fn corpus(notes: &[(&str, &[(&str, &str)], &[&str])], cards: &[(usize, &str, &str)]) -> Corpus {
        corpus_with(notes, cards, false)
    }

    fn hits(c: &Corpus, q: serde_json::Value) -> Vec<u8> {
        let mut out = vec![0u8; c.card_count()];
        c.search(&q.to_string(), &mut out).unwrap();
        out
    }

    #[test]
    fn text_field_deck_tag() {
        for joined_layout in [false, true] {
            text_field_deck_tag_with(joined_layout);
        }
    }

    /// 字段别名：内置 Fushi 卡片的 `Term` 字段带别名 `Expression`，`Expression:食べる`（Yomitan 查重的
    /// findNotes 形状）照样命中；没带别名的笔记类型（自建 `Term` 字段）不受影响；需求分析把别名算进去。
    #[test]
    fn field_alias_matches_the_legacy_name() {
        use serde_json::json;
        for joined_layout in [false, true] {
            let c = corpus_with(
                &[
                    ("Fushi Card", &[("Term|Expression", "<b>食べる</b>"), ("Media|Picture", "x")], &[]),
                    ("Lapis", &[("Expression", "食べる"), ("Picture", "")], &[]),
                    ("Mine", &[("Term", "食べる")], &[]),
                ],
                &[(0, "D", "C"), (1, "D", "C"), (2, "D", "C")],
                joined_layout,
            );
            assert_eq!(hits(&c, json!({"t":"field","f":"Expression","v":"食べる"})), [1, 1, 0]);
            assert_eq!(hits(&c, json!({"t":"field","f":"expr*","v":"食べる"})), [1, 1, 0]);
            assert_eq!(hits(&c, json!({"t":"field","f":"Term","v":"食べる"})), [1, 0, 1]);
            assert_eq!(hits(&c, json!({"t":"fre","f":"expression","v":"べ","at":"x"})), [1, 1, 0]);
            assert_eq!(hits(&c, json!({"t":"field","f":"Picture","v":"x"})), [1, 0, 0]);
            // 需求：`Expression:` 要 Expression 列和带别名的 Term 列的值。
            let q = json!({"t":"field","f":"Expression","v":"食べる"}).to_string();
            let Needs::Names(ids) = c.needs(&q).unwrap() else { panic!("expected names") };
            let names: Vec<&str> = ids.iter().map(|&i| c.s(i)).collect();
            assert!(names.contains(&"Expression") && names.contains(&"Term"), "{names:?}");
        }
    }

    fn text_field_deck_tag_with(joined_layout: bool) {
        let c = corpus_with(
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
            joined_layout,
        );
        use serde_json::json;
        // 未限定字段的文本按 0x1f 连接：不跨字段拼出 "るto"。
        assert_eq!(hits(&c, json!({"t":"text","v":"るto"})), [0, 0, 0]);
        assert_eq!(hits(&c, json!({"t":"re","v":"る</b>\x1fto","at":"re:x"})), [1, 1, 0]);
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
    fn values_on_demand() {
        use serde_json::json;
        let notes: &[(&str, &[(&str, &str)], &[&str])] = &[
            ("Lapis", &[("Expression", "食べる"), ("Glossary", "<i>to eat</i>")], &["n5"]),
            ("Basic", &[("Front", "x"), ("Back", "y")], &[]),
        ];
        let cards = &[(0, "D", "T"), (1, "D", "T")];
        let full = corpus(notes, cards);
        // 名字类的结构不用字段值。
        let mut layout_only = full_layout_only(notes, cards);
        let mut out = vec![0u8; 2];
        let q = |v: serde_json::Value| v.to_string();
        assert_eq!(layout_only.needs(&q(json!({"t":"deck","v":"d"}))).unwrap(), Needs::Names(vec![]));
        assert_eq!(layout_only.search(&q(json!({"t":"tag","v":"n5"})), &mut out).unwrap(), 1);
        assert_eq!(layout_only.needs(&q(json!({"t":"text","v":"x"}))).unwrap(), Needs::All);
        assert_eq!(
            layout_only.needs(&q(json!({"t":"re","v":"(","at":"re:("}))).unwrap_err().kind,
            "syntax"
        );
        let Needs::Names(names) = layout_only
            .needs(&q(json!({"t":"and","c":[{"t":"field","f":"gloss*","v":"*eat*"},{"t":"not","c":{"t":"fre","f":"front","v":"x","at":"a"}}]})))
            .unwrap()
        else {
            panic!("expected names");
        };
        let named: Vec<&str> = names.iter().map(|&i| layout_only.s(i)).collect();
        assert_eq!(named.len(), 2);
        assert!(named.contains(&"Glossary") && named.contains(&"Front"));
        let gq = q(json!({"t":"field","f":"glossary","v":"to eat"}));
        assert_eq!(layout_only.search(&gq, &mut out).unwrap_err().kind, "internal");
        // 只传 Glossary 一列（字段 1）就能求值，结果与全量语料一致。
        layout_only.set_values(&[1], b"<i>to eat</i>", &[0, 13]).unwrap();
        assert_eq!(layout_only.search(&gq, &mut out).unwrap(), 1);
        assert_eq!(hits(&layout_only, json!({"t":"field","f":"glossary","v":"to eat"})), hits(&full, json!({"t":"field","f":"glossary","v":"to eat"})));
        assert!(layout_only.set_values(&[9], b"x", &[0, 1]).is_err());
        assert!(layout_only.set_values(&[0], "語".as_bytes(), &[0, 1]).is_err());
    }

    fn full_layout_only(notes: &[(&str, &[(&str, &str)], &[&str])], cards: &[(usize, &str, &str)]) -> Corpus {
        let full = corpus(notes, cards);
        Corpus {
            chunks: Vec::new(),
            chunk_refs: Vec::new(),
            value_loc: vec![
                ValueLoc {
                    chunk: MISSING,
                    start: 0,
                    end: 0
                };
                full.field_count()
            ],
            ..full
        }
    }

    #[test]
    fn parallel_prestrip_matches_lazy() {
        use serde_json::json;
        let values: Vec<String> = (0..3000)
            .map(|i| format!("<style>.x{{}}</style><b>w{i}</b> &amp; {}", if i % 7 == 0 { "eat" } else { "run" }))
            .collect();
        let fields: Vec<Vec<(&str, &str)>> = values.iter().map(|v| vec![("G", v.as_str())]).collect();
        let notes: Vec<(&str, &[(&str, &str)], &[&str])> =
            fields.iter().map(|f| ("T", f.as_slice(), &[][..])).collect();
        let cards: Vec<(usize, &str, &str)> = (0..notes.len()).map(|i| (i, "D", "C")).collect();
        let c = corpus(&notes, &cards);
        let got = hits(&c, json!({"t":"field","f":"g","v":"w* & eat"}));
        let want: Vec<u8> = (0..3000).map(|i| u8::from(i % 7 == 0)).collect();
        assert_eq!(got, want);
        assert!(c.stripped.iter().all(|s| s.get().is_some()));
    }

    /// 原来的正则实现，只作对照。
    fn strip_tags_regex(html: &str) -> String {
        let re = Regex::new(concat!(
            "(?si)",
            r"(<!--.*?-->)|(<style.*?>.*?</style>)|(<script.*?>.*?</script>)",
            r"|(<.*?>)",
        ))
        .unwrap();
        re.replace_all(html, "").into_owned()
    }

    #[test]
    fn strip_scanner_matches_regex() {
        let atoms = [
            "<", ">", "!", "-", "--", "<!--", "-->", "style", "STYLE", "\u{17F}tyle", "Style", "script",
            "SCR\u{130}PT", "scr\u{131}pt", "</style>", "</STYLE>", "</\u{17F}tyle>", "</script>",
            "</script >", "<style>", "<script>", "<style", "<script", "</", "a", " ", "\n", "語",
            "\u{212A}", "&amp;", "<b>", "</b>", "x>", "<<", ">>",
        ];
        let mut seed: u64 = 0x9E37_79B9_7F4A_7C15;
        let mut next = || {
            seed ^= seed << 13;
            seed ^= seed >> 7;
            seed ^= seed << 17;
            seed
        };
        let re = Regex::new(concat!(
            "(?si)",
            r"(<!--.*?-->)|(<style.*?>.*?</style>)|(<script.*?>.*?</script>)",
            r"|(<.*?>)",
        ))
        .unwrap();
        for _ in 0..300_000 {
            let len = (next() % 24) as usize;
            let s: String = (0..len).map(|_| atoms[(next() % atoms.len() as u64) as usize]).collect();
            assert_eq!(strip_tags(&s), re.replace_all(&s, "").into_owned(), "{s:?}");
        }
        assert_eq!(strip_tags_regex("<b>x</b>"), "x");
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
    fn anchored_glob_drops_only_equivalent_anchors() {
        let full = |t: &str| glob_re(&format!("^{}$", glob_to_re(t, "."))).unwrap();
        let globs = [
            "*", "**", "*a*", "a*", "*a", "a", r"*a\*", r"*a\\*", r"\*", r"\\*", r"*a\\\*", "*_*",
            "_*", "*a*b*", r"*\\", "", "*to eat*", "x_y*",
        ];
        let values = [
            "", "a", "ba", "ab", "bab", "a*", r"a\", r"\", "*", "x\ny", "a\nb", "xzy1", "to eat",
            "TO EAT\n", "b\na\nb", "a*b", r"ba\*",
        ];
        for g in globs {
            let fast = anchored_glob(g).unwrap();
            let slow = full(g);
            for v in values {
                assert_eq!(fast.is_match(v), slow.is_match(v), "glob {g:?} value {v:?}");
            }
        }
    }

    #[test]
    fn glob() {
        assert_eq!(glob_to_re(r"a*b_c\*\_\\\:", "."), r"a.*b.c\*_\\\\:");
        assert_eq!(glob_to_re("x\\", "."), r"x\\");
    }
}
