//! AniDB 每日标题包：流式解析（`_parseTitleCatalogSource` / `_TitleCatalogBuilder`）、
//! 记录表与搜索索引（`_AniDbTitleSearchIndex`）。Dart 侧（anidb_title_catalog.dart）只剩
//! 解压、读盘、缓存策略与把结果包成 Dart 对象。
//!
//! 流式语义按 `XmlEventDecoder(validateNesting: true)` 一块一块地复刻：每次 [StreamParser::feed]
//! 对应 Dart 那边的一块（gzip 解压器吐出的块，原样转发过来）——先整块 UTF-8 解码，再把这块里
//! 能解析的事件全部解析并做嵌套校验，最后才按序交给 [Builder]。所以「同一块里先有构建器
//! 报错的事件、后有错位闭合标签」时报的是后者，与原实现一致。
//!
//! 唯一刻意的差异：原实现在块尾把未遇到 `<` 的文本先吐成一个事件，实体（`&amp;`）若恰好
//! 被块边界切开就解不出来（结果依赖 zlib 的输出块大小）；这里等到 `<` 才吐文本，实体
//! 总是完整解码。

use std::collections::{HashMap, HashSet};

use super::dart_sort::dart_sort;
use super::xml::{
    dart_int_try_parse, decode_entities, eq_ascii, local_name, name_prefix, parse_event, Event,
    RawAttr, Step,
};
use crate::parse::title_score::{
    dart_double_compare, dart_to_lower, dart_trim, normalize, push_rune, runes, tokens_of_runes,
    PreparedQuery,
};

pub const MAX_ANIME_RECORDS: usize = 100_000;
pub const MAX_TITLES_PER_ANIME: usize = 256;
pub const MAX_TITLE_LENGTH: usize = 2048;
const MAX_PREFIX_ENTRIES: usize = 8192;
const MAX_FUZZY_CANDIDATES: usize = 20_000;

/// 失败种类（数值与 Dart 侧 `AniDbCatalogNativeError.kind` 一致）。
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum CatalogError {
    ForbiddenDeclaration,
    UnexpectedRoot,
    TooManyRecords,
    TooManyTitles,
    /// `XmlException.toString()` 风格的说明。
    InvalidXml(String),
    /// UTF-8 解码失败（`FormatException.toString()` 风格的说明）。
    InvalidData(String),
    NoUsableRecords,
}

impl CatalogError {
    pub fn kind(&self) -> u32 {
        match self {
            CatalogError::ForbiddenDeclaration => 1,
            CatalogError::UnexpectedRoot => 2,
            CatalogError::TooManyRecords => 3,
            CatalogError::TooManyTitles => 4,
            CatalogError::InvalidXml(_) => 5,
            CatalogError::InvalidData(_) => 6,
            CatalogError::NoUsableRecords => 7,
        }
    }

    pub fn detail(&self) -> &str {
        match self {
            CatalogError::InvalidXml(s) | CatalogError::InvalidData(s) => s,
            _ => "",
        }
    }
}

fn utf16_string(units: &[u16]) -> String {
    String::from_utf16_lossy(units)
}

#[derive(Clone, Debug)]
pub struct Title {
    pub value: Vec<u16>,
    pub kind: Vec<u16>,
    pub language: Vec<u16>,
    pub normalized: Vec<u16>,
}

#[derive(Clone, Debug)]
pub struct Record {
    pub anime_id: i64,
    pub titles: Vec<Title>,
}

/// 构建中的一个标题：value / type / language。
type RawTitle = (Vec<u16>, Vec<u16>, Vec<u16>);

/// 收拢事件的构建器（原 `_TitleCatalogBuilder`）。
#[derive(Default)]
pub struct Builder {
    titles_by_anime: HashMap<i64, Vec<RawTitle>>,
    open: Vec<Vec<u16>>,
    root_seen: bool,
    record_count: usize,
    current: Option<i64>,
    current_title_count: usize,
    in_title: bool,
    title_type: Vec<u16>,
    title_language: Vec<u16>,
    title_text: Vec<u16>,
}

fn attribute<'a>(buf: &'a [u16], attrs: &'a [RawAttr], name: &str) -> Option<&'a RawAttr> {
    attrs
        .iter()
        .find(|attr| eq_ascii(&buf[attr.name.0..attr.name.1], name))
}

fn attr_value(buf: &[u16], attr: &RawAttr) -> Vec<u16> {
    decode_entities(&buf[attr.value.0..attr.value.1])
}

impl Builder {
    pub fn accept(
        &mut self,
        buf: &[u16],
        attrs: &[RawAttr],
        event: &Event,
    ) -> Result<(), CatalogError> {
        match event {
            Event::Doctype => Err(CatalogError::ForbiddenDeclaration),
            Event::Start {
                name,
                attrs: (a, b),
                self_closing,
            } => self.start(
                buf,
                &attrs[*a..*b],
                local_name(&buf[name.0..name.1]).to_vec(),
                *self_closing,
            ),
            Event::End(name) => {
                let local = local_name(&buf[name.0..name.1]).to_vec();
                self.end(&local);
                Ok(())
            }
            Event::Text(span) => {
                if self.in_title {
                    let decoded = decode_entities(&buf[span.0..span.1]);
                    self.title_text.extend_from_slice(&decoded);
                }
                Ok(())
            }
            Event::CData(span) => {
                if self.in_title {
                    self.title_text.extend_from_slice(&buf[span.0..span.1]);
                }
                Ok(())
            }
            _ => Ok(()),
        }
    }

    fn start(
        &mut self,
        buf: &[u16],
        attrs: &[RawAttr],
        name: Vec<u16>,
        self_closing: bool,
    ) -> Result<(), CatalogError> {
        if !self.root_seen {
            self.root_seen = true;
            if !eq_ascii(&name, "animetitles") {
                return Err(CatalogError::UnexpectedRoot);
            }
        } else if self.open.len() == 1 && eq_ascii(&name, "anime") {
            self.record_count += 1;
            if self.record_count > MAX_ANIME_RECORDS {
                return Err(CatalogError::TooManyRecords);
            }
            let aid = attribute(buf, attrs, "aid")
                .map(|attr| attr_value(buf, attr))
                .and_then(|value| dart_int_try_parse(&value, None));
            self.current = match aid {
                Some(id) if id > 0 => {
                    self.titles_by_anime.entry(id).or_default();
                    Some(id)
                }
                _ => None,
            };
            self.current_title_count = 0;
        } else if self.open.len() == 2
            && eq_ascii(&self.open[1], "anime")
            && eq_ascii(&name, "title")
            && self.current.is_some()
        {
            self.current_title_count += 1;
            if self.current_title_count > MAX_TITLES_PER_ANIME {
                return Err(CatalogError::TooManyTitles);
            }
            self.in_title = true;
            let kind = attribute(buf, attrs, "type")
                .map(|attr| attr_value(buf, attr))
                .unwrap_or_default();
            self.title_type = dart_to_lower(dart_trim(&kind));
            self.title_language = xml_language(buf, attrs);
            self.title_text.clear();
        }
        let local = name.clone();
        self.open.push(name);
        if self_closing {
            self.end(&local);
        }
        Ok(())
    }

    fn end(&mut self, name: &[u16]) {
        if self.in_title && eq_ascii(name, "title") && self.open.len() == 3 {
            self.finish_title();
        } else if eq_ascii(name, "anime") && self.open.len() == 2 {
            self.current = None;
        }
        self.open.pop();
    }

    fn finish_title(&mut self) {
        self.in_title = false;
        let value = dart_trim(&self.title_text).to_vec();
        self.title_text.clear();
        let Some(id) = self.current else {
            return;
        };
        if value.is_empty() || value.len() > MAX_TITLE_LENGTH {
            return;
        }
        if self.title_type.is_empty() || self.title_language.is_empty() {
            return;
        }
        let titles = self.titles_by_anime.entry(id).or_default();
        let duplicate = titles
            .iter()
            .any(|(v, t, l)| *v == value && *t == self.title_type && *l == self.title_language);
        if !duplicate {
            titles.push((value, self.title_type.clone(), self.title_language.clone()));
        }
    }

    pub fn finish(self) -> Result<Vec<Record>, CatalogError> {
        let mut ids: Vec<i64> = self.titles_by_anime.keys().copied().collect();
        ids.sort_unstable();
        let mut map = self.titles_by_anime;
        let mut records = Vec::new();
        for id in ids {
            let titles = map.remove(&id).unwrap_or_default();
            if titles.is_empty() {
                continue;
            }
            records.push(Record {
                anime_id: id,
                titles: titles
                    .into_iter()
                    .map(|(value, kind, language)| Title {
                        normalized: normalize(&value),
                        value,
                        kind,
                        language,
                    })
                    .collect(),
            });
        }
        if records.is_empty() {
            return Err(CatalogError::NoUsableRecords);
        }
        Ok(records)
    }
}

/// `localName == 'lang' && namespacePrefix == 'xml'` 的第一个属性，`trim()` 后。
fn xml_language(buf: &[u16], attrs: &[RawAttr]) -> Vec<u16> {
    for attr in attrs {
        let name = &buf[attr.name.0..attr.name.1];
        if eq_ascii(local_name(name), "lang")
            && name_prefix(name).is_some_and(|p| eq_ascii(p, "xml"))
        {
            return dart_trim(&attr_value(buf, attr)).to_vec();
        }
    }
    Vec::new()
}

/// 块式 UTF-8 → UTF-16 → XML 事件 → [Builder]。
#[derive(Default)]
pub struct StreamParser {
    buf: Vec<u16>,
    pos: usize,
    utf8_pending: Vec<u8>,
    started: bool,
    nesting: Vec<Vec<u16>>,
    attrs: Vec<RawAttr>,
    builder: Builder,
    failed: bool,
}

fn decode_utf8_chunk(
    pending: &mut Vec<u8>,
    bytes: &[u8],
    out: &mut Vec<u16>,
) -> Result<(), CatalogError> {
    let mut data: Vec<u8>;
    let input: &[u8] = if pending.is_empty() {
        bytes
    } else {
        data = std::mem::take(pending);
        data.extend_from_slice(bytes);
        &data
    };
    let (valid, rest) = match std::str::from_utf8(input) {
        Ok(s) => (s, &[][..]),
        Err(e) => {
            if e.error_len().is_some() {
                let carried = input.len() - bytes.len();
                return Err(CatalogError::InvalidData(utf8_error_message(input, carried)));
            }
            let (head, tail) = input.split_at(e.valid_up_to());
            // SAFETY: valid_up_to 之前是合法 UTF-8。
            (unsafe { std::str::from_utf8_unchecked(head) }, tail)
        }
    };
    out.extend(valid.encode_utf16());
    *pending = rest.to_vec();
    Ok(())
}

/// 第一个非法 UTF-8 序列按 Dart 分块解码器（`dart:convert` 的 `_Utf8Decoder`）的文案报：
/// 种类与检出位置（相对**当前块**，上一块留下的半截序列不算偏移）都照它。
fn utf8_error_message(input: &[u8], carried: usize) -> String {
    let at = |index: usize, message: &str| {
        format!(
            "FormatException: {message} (at offset {})",
            index.saturating_sub(carried)
        )
    };
    let mut i = 0;
    while i < input.len() {
        let b = input[i];
        let (need, lo, hi, low_msg, high_msg) = match b {
            0x00..=0x7F => {
                i += 1;
                continue;
            }
            0x80..=0xBF => return at(i, "Unexpected extension byte"),
            0xC2..=0xDF => (1, 0x80, 0xBF, "", ""),
            0xE0 => (2, 0xA0, 0xBF, "Overlong encoding", ""),
            0xED => (2, 0x80, 0x9F, "", "Encoded surrogate"),
            0xE1..=0xEF => (2, 0x80, 0xBF, "", ""),
            0xF0 => (3, 0x90, 0xBF, "Overlong encoding", ""),
            0xF1..=0xF3 => (3, 0x80, 0xBF, "", ""),
            0xF4 => (3, 0x80, 0x8F, "", "Out of unicode range"),
            _ => return at(i, "Invalid UTF-8 byte"),
        };
        for k in 1..=need {
            let Some(&c) = input.get(i + k) else {
                return "FormatException: Unfinished UTF-8 octet sequence".to_string();
            };
            if !(0x80..=0xBF).contains(&c) {
                return at(i + k, "Missing extension byte");
            }
            if k == 1 && c < lo {
                return at(i + k, low_msg);
            }
            if k == 1 && c > hi {
                return at(i + k, high_msg);
            }
        }
        i += need + 1;
    }
    "FormatException: Invalid UTF-8 byte".to_string()
}

impl StreamParser {
    pub fn new() -> Self {
        Self::default()
    }

    fn check_nesting(&mut self, event: &Event) -> Result<(), CatalogError> {
        match event {
            Event::Start {
                name,
                self_closing: false,
                ..
            } => self.nesting.push(self.buf[name.0..name.1].to_vec()),
            Event::End(name) => {
                let actual = self.buf[name.0..name.1].to_vec();
                let Some(expected) = self.nesting.last() else {
                    return Err(CatalogError::InvalidXml(format!(
                        "XmlTagException: Unexpected </{}>",
                        utf16_string(&actual)
                    )));
                };
                if *expected != actual {
                    return Err(CatalogError::InvalidXml(format!(
                        "XmlTagException: Expected </{}>, but found </{}>",
                        utf16_string(expected),
                        utf16_string(&actual)
                    )));
                }
                self.nesting.pop();
            }
            _ => {}
        }
        Ok(())
    }

    /// 解析当前缓冲里能解析的事件（先全部做嵌套校验，再按序交给构建器）。
    fn pump(&mut self, eof: bool) -> Result<(), CatalogError> {
        let mut events: Vec<Event> = Vec::new();
        self.attrs.clear();
        let mut pos = self.pos;
        while pos < self.buf.len() {
            match parse_event(&self.buf, pos, eof, &mut self.attrs) {
                Step::Event(event, end) => {
                    self.check_nesting(&event)?;
                    events.push(event);
                    pos = end;
                }
                Step::NeedMore | Step::Fail(_) => break,
            }
        }
        let buf = std::mem::take(&mut self.buf);
        let attrs = std::mem::take(&mut self.attrs);
        let mut result = Ok(());
        for event in &events {
            if let Err(e) = self.builder.accept(&buf, &attrs, event) {
                result = Err(e);
                break;
            }
        }
        self.buf = buf;
        self.attrs = attrs;
        result?;
        self.pos = pos;
        if self.pos > 0 && self.pos * 2 >= self.buf.len() {
            self.buf.drain(..self.pos);
            self.pos = 0;
        }
        Ok(())
    }

    pub fn feed(&mut self, bytes: &[u8]) -> Result<(), CatalogError> {
        if self.failed {
            return Err(CatalogError::InvalidXml("parser already failed".into()));
        }
        let result = self.feed_inner(bytes);
        self.failed = result.is_err();
        result
    }

    fn feed_inner(&mut self, bytes: &[u8]) -> Result<(), CatalogError> {
        if bytes.is_empty() {
            return Ok(());
        }
        let before = self.buf.len();
        decode_utf8_chunk(&mut self.utf8_pending, bytes, &mut self.buf)?;
        if !self.started && self.buf.len() > before {
            self.started = true;
            // Dart 的 UTF-8 解码器丢掉流首的一个 BOM。
            if self.buf[before] == 0xFEFF {
                self.buf.remove(before);
            }
        }
        self.pump(false)
    }

    /// 输入结束：UTF-8 截断 → 残留文本 → 解析不了的残片 → 未闭合标签，按原实现的顺序报。
    pub fn close(&mut self) -> Result<(), CatalogError> {
        if self.failed {
            return Err(CatalogError::InvalidXml("parser already failed".into()));
        }
        let result = self.close_inner();
        self.failed = result.is_err();
        result
    }

    fn close_inner(&mut self) -> Result<(), CatalogError> {
        if !self.utf8_pending.is_empty() {
            return Err(CatalogError::InvalidData(
                "FormatException: Unfinished UTF-8 octet sequence".to_string(),
            ));
        }
        self.pump(true)?;
        if self.pos < self.buf.len() {
            let mut scratch = Vec::new();
            let message = match parse_event(&self.buf, self.pos, true, &mut scratch) {
                Step::Fail(fail) => fail.msg,
                _ => "Unable to parse XML",
            };
            return Err(CatalogError::InvalidXml(format!(
                "XmlParserException: {message}"
            )));
        }
        if let Some(open) = self.nesting.last() {
            return Err(CatalogError::InvalidXml(format!(
                "XmlTagException: Missing </{}>",
                utf16_string(open)
            )));
        }
        Ok(())
    }

    pub fn finish(self) -> Result<Catalog, CatalogError> {
        Ok(Catalog::new(self.builder.finish()?))
    }
}

/// 匹配种类（数值即 Dart `AniDbTitleMatchKind.index`）。
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum MatchKind {
    Exact = 0,
    Prefix = 1,
    Similar = 2,
}

#[derive(Clone, Copy, Debug)]
pub struct SearchResult {
    pub record: u32,
    pub title: u32,
    pub kind: MatchKind,
    pub similarity: f64,
}

struct Entry {
    record: u32,
    title: u32,
    norm: (u32, u32),
    runes: (u32, u32),
    tokens: (u32, u32),
    first_rune: u32,
}

/// 每个标题在 [RecordTable::titles] 里占的 `u32` 个数：value 偏移 / 长度、normalized 偏移 /
/// 长度、type 与 language 在 [RecordTable::strings] 里的下标。
pub const TITLE_WORDS: usize = 6;

/// 扁平记录表：全部记录的标题按记录顺序（anime id 升序）连续存放，字符串是 `units` 里的
/// UTF-16 区间；type / language 去重进 `strings`（真实包里只有几十种）。normalized 与
/// value 相同时两者指向同一区间。
///
/// 这是目录里唯一一份记录数据：搜索索引按 `titles` 的区间读 normalized；Dart 侧经
/// `ffc_parse_anidb_catalog_record_table` 拿到这几个数组的指针，直接在原生内存上建
/// 零拷贝视图、按 id 二分取记录，取记录不再逐次跨 FFI。
#[derive(Default)]
pub struct RecordTable {
    /// 各记录的 anime id（升序、无重复）。
    pub ids: Vec<i64>,
    /// 记录 `i` 的标题是全局下标 `title_start[i]..title_start[i + 1]`（长度 `ids.len() + 1`）。
    pub title_start: Vec<u32>,
    /// 每个标题 [TITLE_WORDS] 个 `u32`。
    pub titles: Vec<u32>,
    pub units: Vec<u16>,
    pub strings: Vec<Vec<u16>>,
}

impl RecordTable {
    fn from_records(records: Vec<Record>) -> Self {
        let mut table = RecordTable::default();
        let mut interned: HashMap<Vec<u16>, u32> = HashMap::new();
        let mut intern = |strings: &mut Vec<Vec<u16>>, s: Vec<u16>| -> u32 {
            let next = strings.len() as u32;
            *interned.entry(s).or_insert_with_key(|k| {
                strings.push(k.clone());
                next
            })
        };
        table.ids.reserve(records.len());
        table.title_start.reserve(records.len() + 1);
        for record in records {
            table.ids.push(record.anime_id);
            table
                .title_start
                .push((table.titles.len() / TITLE_WORDS) as u32);
            for title in record.titles {
                let value = (table.units.len() as u32, title.value.len() as u32);
                table.units.extend_from_slice(&title.value);
                let norm = if title.normalized == title.value {
                    value
                } else {
                    let span = (table.units.len() as u32, title.normalized.len() as u32);
                    table.units.extend_from_slice(&title.normalized);
                    span
                };
                let kind = intern(&mut table.strings, title.kind);
                let language = intern(&mut table.strings, title.language);
                table
                    .titles
                    .extend_from_slice(&[value.0, value.1, norm.0, norm.1, kind, language]);
            }
        }
        table
            .title_start
            .push((table.titles.len() / TITLE_WORDS) as u32);
        table
    }

    pub fn len(&self) -> usize {
        self.ids.len()
    }

    pub fn is_empty(&self) -> bool {
        self.ids.is_empty()
    }

    pub fn title_count(&self) -> usize {
        self.titles.len() / TITLE_WORDS
    }

    fn word(&self, title: usize, k: usize) -> usize {
        self.titles[title * TITLE_WORDS + k] as usize
    }

    fn span(&self, title: usize, k: usize) -> &[u16] {
        let offset = self.word(title, k);
        &self.units[offset..offset + self.word(title, k + 1)]
    }

    /// 全局标题下标 `title` 的 value。
    pub fn value(&self, title: usize) -> &[u16] {
        self.span(title, 0)
    }

    pub fn normalized(&self, title: usize) -> &[u16] {
        self.span(title, 2)
    }

    pub fn kind(&self, title: usize) -> &[u16] {
        &self.strings[self.word(title, 4)]
    }

    pub fn language(&self, title: usize) -> &[u16] {
        &self.strings[self.word(title, 5)]
    }

    /// 记录 `record` 的全局标题下标区间。
    pub fn titles_of(&self, record: usize) -> std::ops::Range<usize> {
        self.title_start[record] as usize..self.title_start[record + 1] as usize
    }

    /// 记录 `record` 还原成拥有所有权的 [Record]（测试与诊断用）。
    pub fn record(&self, record: usize) -> Record {
        Record {
            anime_id: self.ids[record],
            titles: self
                .titles_of(record)
                .map(|t| Title {
                    value: self.value(t).to_vec(),
                    kind: self.kind(t).to_vec(),
                    language: self.language(t).to_vec(),
                    normalized: self.normalized(t).to_vec(),
                })
                .collect(),
        }
    }
}

/// 标题目录 + 搜索索引。构建后不可变（`&self` 搜索、无内部可变性），可跨线程只读共享。
pub struct Catalog {
    table: RecordTable,
    entries: Vec<Entry>,
    rune_pool: Vec<u32>,
    token_pool: Vec<u32>,
    token_ids: HashMap<Vec<u32>, u32>,
    sorted: Vec<u32>,
    by_first_rune: HashMap<u32, Vec<u32>>,
    by_gram: HashMap<u64, Vec<u32>>,
    /// 按全局标题下标。
    type_priority: Vec<u8>,
}

fn title_type_priority(kind: &[u16]) -> u8 {
    if eq_ascii(kind, "main") {
        0
    } else if eq_ascii(kind, "official") {
        1
    } else if eq_ascii(kind, "syn") || eq_ascii(kind, "synonym") {
        2
    } else if eq_ascii(kind, "short") {
        3
    } else {
        4
    }
}

/// 原 `_normalizedGrams`：去掉 U+0020 后的 3-gram（不足 3 个码点取整串），超过 48 个时
/// 等距抽样并补上最后一个。按出现顺序去重。
pub fn normalized_grams(normalized_runes: &[u32]) -> Vec<u64> {
    let runes: Vec<u32> = normalized_runes
        .iter()
        .copied()
        .filter(|&r| r != 0x20)
        .collect();
    if runes.is_empty() {
        return Vec::new();
    }
    let width = runes.len().min(3);
    let count = runes.len() - width + 1;
    let stride = if count <= 48 { 1 } else { count.div_ceil(48) };
    let key = |offset: usize| -> u64 {
        let mut k: u64 = 0;
        for i in 0..3 {
            k <<= 21;
            if i < width {
                k |= u64::from(runes[offset + i]) + 1;
            }
        }
        k
    };
    let mut out: Vec<u64> = Vec::new();
    let mut push = |k: u64| {
        if !out.contains(&k) {
            out.push(k);
        }
    };
    let mut offset = 0;
    while offset < count {
        push(key(offset));
        offset += stride;
    }
    if !(count - 1).is_multiple_of(stride) {
        push(key(count - 1));
    }
    out
}

fn contains(haystack: &[u16], needle: &[u16]) -> bool {
    if needle.is_empty() {
        return true;
    }
    if needle.len() > haystack.len() {
        return false;
    }
    let first = needle[0];
    let last_start = haystack.len() - needle.len();
    let mut i = 0;
    while i <= last_start {
        if haystack[i] == first && haystack[i..i + needle.len()] == *needle {
            return true;
        }
        i += 1;
    }
    false
}

impl Catalog {
    pub fn new(records: Vec<Record>) -> Self {
        let mut catalog = Catalog {
            table: RecordTable::from_records(records),
            entries: Vec::new(),
            rune_pool: Vec::new(),
            token_pool: Vec::new(),
            token_ids: HashMap::new(),
            sorted: Vec::new(),
            by_first_rune: HashMap::new(),
            by_gram: HashMap::new(),
            type_priority: Vec::new(),
        };
        catalog.build_index();
        catalog
    }

    fn build_index(&mut self) {
        let mut token_ids: HashMap<Vec<u32>, u32> = HashMap::new();
        let table = &self.table;
        self.type_priority = (0..table.title_count())
            .map(|t| title_type_priority(table.kind(t)))
            .collect();
        for ri in 0..table.len() {
            for (ti, t) in table.titles_of(ri).enumerate() {
                let normalized = table.normalized(t);
                if normalized.is_empty() {
                    continue;
                }
                let id = self.entries.len() as u32;
                let norm = (table.word(t, 2) as u32, normalized.len() as u32);
                let rs = runes(normalized);
                let runes_span = (self.rune_pool.len() as u32, rs.len() as u32);
                self.rune_pool.extend_from_slice(&rs);
                let mut ids: Vec<u32> = Vec::new();
                tokens_of_runes(&rs, |token| {
                    let next = token_ids.len() as u32;
                    ids.push(*token_ids.entry(token.to_vec()).or_insert(next));
                });
                ids.sort_unstable();
                ids.dedup();
                let tokens = (self.token_pool.len() as u32, ids.len() as u32);
                self.token_pool.extend_from_slice(&ids);
                self.entries.push(Entry {
                    record: ri as u32,
                    title: ti as u32,
                    norm,
                    runes: runes_span,
                    tokens,
                    first_rune: rs[0],
                });
                self.by_first_rune.entry(rs[0]).or_default().push(id);
                for gram in normalized_grams(&rs) {
                    self.by_gram.entry(gram).or_default().push(id);
                }
            }
        }
        self.token_ids = token_ids;
        let mut sorted: Vec<u32> = (0..self.entries.len() as u32).collect();
        {
            let entries = &self.entries;
            let units = &self.table.units;
            let ids = &self.table.ids;
            let norm = |e: u32| {
                let (o, l) = entries[e as usize].norm;
                &units[o as usize..(o + l) as usize]
            };
            dart_sort(
                &mut sorted,
                &mut |a: u32, b: u32| match norm(a).cmp(norm(b)) {
                    std::cmp::Ordering::Less => -1,
                    std::cmp::Ordering::Greater => 1,
                    std::cmp::Ordering::Equal => {
                        let ia = ids[entries[a as usize].record as usize];
                        let ib = ids[entries[b as usize].record as usize];
                        ia.cmp(&ib) as i32
                    }
                },
            );
        }
        self.sorted = sorted;
    }

    pub fn table(&self) -> &RecordTable {
        &self.table
    }

    /// `anime_id` 的记录（测试与诊断用；Dart 侧直接读 [RecordTable]）。
    pub fn find(&self, anime_id: i64) -> Option<Record> {
        self.table
            .ids
            .binary_search(&anime_id)
            .ok()
            .map(|i| self.table.record(i))
    }

    fn norm(&self, e: u32) -> &[u16] {
        let (o, l) = self.entries[e as usize].norm;
        &self.table.units[o as usize..(o + l) as usize]
    }

    fn global_title(&self, r: &SearchResult) -> usize {
        self.table.title_start[r.record as usize] as usize + r.title as usize
    }

    fn entry_runes(&self, e: u32) -> &[u32] {
        let (o, l) = self.entries[e as usize].runes;
        &self.rune_pool[o as usize..(o + l) as usize]
    }

    fn entry_tokens(&self, e: u32) -> &[u32] {
        let (o, l) = self.entries[e as usize].tokens;
        &self.token_pool[o as usize..(o + l) as usize]
    }

    fn lower_bound(&self, query: &[u16]) -> usize {
        let (mut low, mut high) = (0usize, self.sorted.len());
        while low < high {
            let middle = low + ((high - low) >> 1);
            if self.norm(self.sorted[middle]) < query {
                low = middle + 1;
            } else {
                high = middle;
            }
        }
        low
    }

    /// 原 `_AniDbTitleSearchIndex.search`（[query] 必须已归一化且非空）。
    pub fn search(&self, query: &[u16], limit: usize) -> Vec<SearchResult> {
        if limit == 0 || query.is_empty() {
            return Vec::new();
        }
        let prepared = PreparedQuery::new(query);
        let lb = self.lower_bound(query);
        let mut precise: Vec<u32> = Vec::new();
        let mut seen: HashSet<u32> = HashSet::new();
        // `_exact[query]`：按建索引顺序（= 条目编号升序）。
        let mut exact: Vec<u32> = Vec::new();
        let mut i = lb;
        while i < self.sorted.len() && self.norm(self.sorted[i]) == query {
            exact.push(self.sorted[i]);
            i += 1;
        }
        exact.sort_unstable();
        for e in exact {
            if seen.insert(e) {
                precise.push(e);
            }
        }
        let mut cursor = lb;
        let mut visited = 0;
        while cursor < self.sorted.len() && visited < MAX_PREFIX_ENTRIES {
            let e = self.sorted[cursor];
            cursor += 1;
            if !self.norm(e).starts_with(query) {
                break;
            }
            if seen.insert(e) {
                precise.push(e);
            }
            visited += 1;
        }
        if !precise.is_empty() {
            return self.rank(&precise, &prepared, limit, 0.0, |catalog, e| {
                if catalog.norm(e) == query {
                    MatchKind::Exact
                } else {
                    MatchKind::Prefix
                }
            });
        }

        let mut hits: Vec<u32> = vec![0; self.entries.len()];
        let mut order: Vec<u32> = Vec::new();
        for gram in normalized_grams(prepared.runes()) {
            if let Some(list) = self.by_gram.get(&gram) {
                for &e in list {
                    let h = &mut hits[e as usize];
                    if *h == 0 {
                        order.push(e);
                    }
                    *h += 1;
                }
            }
        }
        let candidates: Vec<u32> = if order.is_empty() {
            self.by_first_rune
                .get(&prepared.runes()[0])
                .cloned()
                .unwrap_or_default()
        } else {
            dart_sort(&mut order, &mut |a: u32, b: u32| {
                hits[b as usize].cmp(&hits[a as usize]) as i32
            });
            order
        };
        let query_tokens: Vec<Vec<u16>> = prepared
            .tokens()
            .iter()
            .map(|token| {
                let mut units = Vec::with_capacity(token.len());
                for &cp in token {
                    push_rune(&mut units, cp);
                }
                units
            })
            .collect();
        let query_first = prepared.runes()[0];
        let filtered: Vec<u32> = candidates
            .iter()
            .take(MAX_FUZZY_CANDIDATES)
            .copied()
            .filter(|&e| self.is_fuzzy_candidate(query, &query_tokens, query_first, e))
            .collect();
        self.rank(&filtered, &prepared, limit, 0.2, |_, _| MatchKind::Similar)
    }

    fn is_fuzzy_candidate(
        &self,
        query: &[u16],
        query_tokens: &[Vec<u16>],
        query_first: u32,
        e: u32,
    ) -> bool {
        let candidate = self.norm(e);
        let longer = query.len().max(candidate.len());
        let shorter = query.len().min(candidate.len());
        if longer == 0 || (shorter as f64) / (longer as f64) < 0.45 {
            return false;
        }
        if contains(candidate, query) || contains(query, candidate) {
            return true;
        }
        for token in query_tokens {
            if token.len() >= 2 && contains(candidate, token) {
                return true;
            }
        }
        (shorter as f64) / (longer as f64) >= 0.7
            && query_first == self.entries[e as usize].first_rune
    }

    fn score(&self, prepared: &PreparedQuery, query_ids: &[u32], e: u32) -> f64 {
        let candidate_tokens = self.entry_tokens(e);
        let (mut i, mut j, mut inter) = (0, 0, 0);
        while i < query_ids.len() && j < candidate_tokens.len() {
            match query_ids[i].cmp(&candidate_tokens[j]) {
                std::cmp::Ordering::Less => i += 1,
                std::cmp::Ordering::Greater => j += 1,
                std::cmp::Ordering::Equal => {
                    inter += 1;
                    i += 1;
                    j += 1;
                }
            }
        }
        prepared.similarity_with(
            self.norm(e),
            self.entry_runes(e),
            inter,
            candidate_tokens.len(),
        )
    }

    fn compare_within(&self, l: &SearchResult, r: &SearchResult) -> i32 {
        let kind = (l.kind as i32).cmp(&(r.kind as i32)) as i32;
        if kind != 0 {
            return kind;
        }
        let similarity = dart_double_compare(r.similarity, l.similarity);
        if similarity != 0 {
            return similarity;
        }
        let pl = self.type_priority[self.global_title(l)];
        let pr = self.type_priority[self.global_title(r)];
        pl.cmp(&pr) as i32
    }

    fn compare_results(&self, l: &SearchResult, r: &SearchResult) -> std::cmp::Ordering {
        let within = self.compare_within(l, r);
        if within != 0 {
            return within.cmp(&0);
        }
        let ll = self.table.value(self.global_title(l)).len();
        let rl = self.table.value(self.global_title(r)).len();
        ll.cmp(&rl)
            .then_with(|| self.table.ids[l.record as usize].cmp(&self.table.ids[r.record as usize]))
    }

    fn rank(
        &self,
        entries: &[u32],
        prepared: &PreparedQuery,
        limit: usize,
        minimum_similarity: f64,
        kind_for: impl Fn(&Catalog, u32) -> MatchKind,
    ) -> Vec<SearchResult> {
        let mut query_ids: Vec<u32> = prepared
            .tokens()
            .iter()
            .filter_map(|t| self.token_ids.get(t).copied())
            .collect();
        query_ids.sort_unstable();
        let mut best: HashMap<u32, SearchResult> = HashMap::new();
        for &e in entries {
            let kind = kind_for(self, e);
            let similarity = if kind == MatchKind::Exact {
                1.0
            } else {
                self.score(prepared, &query_ids, e)
            };
            if similarity < minimum_similarity {
                continue;
            }
            let entry = &self.entries[e as usize];
            let candidate = SearchResult {
                record: entry.record,
                title: entry.title,
                kind,
                similarity,
            };
            let replace = match best.get(&entry.record) {
                Some(existing) => self.compare_within(&candidate, existing) < 0,
                None => true,
            };
            if replace {
                best.insert(entry.record, candidate);
            }
        }
        let mut ranked: Vec<SearchResult> = best.into_values().collect();
        ranked.sort_by(|a, b| self.compare_results(a, b));
        ranked.truncate(limit);
        ranked
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(chunks: &[&str]) -> Result<Catalog, CatalogError> {
        let mut parser = StreamParser::new();
        for chunk in chunks {
            parser.feed(chunk.as_bytes())?;
        }
        parser.close()?;
        parser.finish()
    }

    fn s(units: &[u16]) -> String {
        String::from_utf16(units).unwrap()
    }

    const SAMPLE: &str = r#"<?xml version="1.0" encoding="UTF-8"?>
<animetitles>
  <anime aid="1">
    <title type="main" xml:lang="x-jat">Seikai no Monshou</title>
    <title type="official" xml:lang="en">Crest of the Stars</title>
    <title type="syn" xml:lang="en">Crest &amp; Stars</title>
    <title type="official" xml:lang="en">Crest of the Stars</title>
  </anime>
  <anime aid="0x10"><title type=" MAIN " xml:lang=" ja ">無職転生<![CDATA[ <II> ]]></title></anime>
  <anime aid="-3"><title type="main" xml:lang="en">Ignored</title></anime>
  <anime aid="5"/>
  <anime aid="7"><title type="main" lang="en">No xml lang</title><title/></anime>
</animetitles>"#;

    #[test]
    fn parses_sample_like_dart_builder() {
        let catalog = parse(&[SAMPLE]).unwrap();
        let ids: Vec<i64> = catalog.table().ids.clone();
        assert_eq!(ids, vec![1, 16]);
        let r1 = catalog.find(1).unwrap();
        assert_eq!(r1.titles.len(), 3);
        assert_eq!(s(&r1.titles[2].value), "Crest & Stars");
        let r16 = catalog.find(16).unwrap();
        assert_eq!(s(&r16.titles[0].value), "無職転生 <II>");
        assert_eq!(s(&r16.titles[0].kind), "main");
        assert_eq!(s(&r16.titles[0].language), "ja");
        assert_eq!(s(&r16.titles[0].normalized), "无职转生 ii");
    }

    #[test]
    fn chunking_does_not_change_records() {
        let whole = parse(&[SAMPLE]).unwrap();
        let bytes = SAMPLE.as_bytes();
        for size in [1usize, 2, 3, 7, 64] {
            let mut parser = StreamParser::new();
            for chunk in bytes.chunks(size) {
                parser.feed(chunk).unwrap();
            }
            parser.close().unwrap();
            let catalog = parser.finish().unwrap();
            assert_eq!(catalog.table().len(), whole.table().len());
            for i in 0..whole.table().len() {
                let (a, b) = (catalog.table().record(i), whole.table().record(i));
                assert_eq!(a.anime_id, b.anime_id);
                assert_eq!(a.titles.len(), b.titles.len());
                for (x, y) in a.titles.iter().zip(&b.titles) {
                    assert_eq!(x.value, y.value);
                    assert_eq!(x.kind, y.kind);
                    assert_eq!(x.language, y.language);
                    assert_eq!(x.normalized, y.normalized);
                }
            }
        }
    }

    #[test]
    fn errors() {
        assert_eq!(
            parse(&["<!DOCTYPE a><animetitles/>"]).err(),
            Some(CatalogError::ForbiddenDeclaration)
        );
        assert_eq!(
            parse(&["<root/>"]).err(),
            Some(CatalogError::UnexpectedRoot)
        );
        assert_eq!(
            parse(&["<animetitles><anime aid=\"1\"></animetitles>"]).err(),
            Some(CatalogError::InvalidXml(
                "XmlTagException: Expected </anime>, but found </animetitles>".into()
            ))
        );
        assert_eq!(
            parse(&["<animetitles><anime aid=\"1\">"]).err(),
            Some(CatalogError::InvalidXml(
                "XmlTagException: Missing </anime>".into()
            ))
        );
        assert!(matches!(
            parse(&["<animetitles><anime aid=\"1\""]).err(),
            Some(CatalogError::InvalidXml(m)) if m.starts_with("XmlParserException: ")
        ));
        assert_eq!(
            parse(&["<animetitles/>"]).err(),
            Some(CatalogError::NoUsableRecords)
        );
        assert_eq!(parse(&[""]).err(), Some(CatalogError::NoUsableRecords));
        let mut parser = StreamParser::new();
        assert!(matches!(
            parser.feed(&[0x3C, 0xC0, 0x80]),
            Err(CatalogError::InvalidData(_))
        ));
        let mut parser = StreamParser::new();
        parser.feed(&[0x3C, 0x61, 0xE3, 0x81]).unwrap();
        assert!(matches!(parser.close(), Err(CatalogError::InvalidData(_))));
    }

    #[test]
    fn search_exact_prefix_fuzzy() {
        let catalog = parse(&[SAMPLE]).unwrap();
        let q: Vec<u16> = normalize(&"Crest of the Stars".encode_utf16().collect::<Vec<_>>());
        let r = catalog.search(&q, 15);
        assert_eq!(r.len(), 1);
        assert_eq!(r[0].kind, MatchKind::Exact);
        assert_eq!(r[0].similarity, 1.0);
        let q: Vec<u16> = normalize(&"Crest".encode_utf16().collect::<Vec<_>>());
        let r = catalog.search(&q, 15);
        assert_eq!(r[0].kind, MatchKind::Prefix);
        let q: Vec<u16> = normalize(&"無職転生 2".encode_utf16().collect::<Vec<_>>());
        let r = catalog.search(&q, 15);
        assert_eq!(r.len(), 1);
        assert_eq!(r[0].kind, MatchKind::Similar);
    }
}
