//! `ffc_parse_fribb_*`：Fribb `anime-list-full.json` → 按 AniDB 条目归并的跨站身份条目。
//!
//! 原 Dart 实现是 `jsonDecode` 整表（十几 MB、近四万行，后台 isolate 里也要数百毫秒）+
//! `_AnimeIdentityCatalog.fromRows`（packages/fushi_engine/lib/media/video/metadata/
//! anime_identity_mapping.dart）。这里一遍扫描 UTF-8 字节、只为行对象里用得到的 8 个键
//! 建值，其余值只做语法校验，归并规则逐条照搬：
//!
//! - JSON 语法与 Dart `jsonDecode` 一致（RFC 8259 严格：空白只认 `\t \n \r` 空格、无 BOM、
//!   无前导零、字符串内禁裸控制字符、`\u` 孤立代理照收）；对象重复键**后者生效**；
//!   整数字面量（无小数点 / 指数）落在 int64 内才是 int，否则是 double（不算 id）。
//! - `_positiveId` / `_firstPositiveId` / `_nonNegativeInt` / `_intOf`：int 直接用；字符串
//!   按 Dart `trim` + `int.tryParse`（VM 语义，见 [dart_int_try_parse]）。
//! - 同一 anidb_id 多行：`mal_id` 并集（插入序去重），其余字段首个合法值生效；
//!   `themoviedb_id.tv` 优先，没有才取 `.movie` 并记电影命名空间。实测 Fribb 全表（39304 行）
//!   `themoviedb_id` **恒为对象**：`{"tv": 209867}`（7092 行）或 `{"movie": [128]}`（1363 行，
//!   movie 侧的值还是数组，取第一个合法正整数），从不出现裸数字；`tvdb_id` 才是 TVDB 键
//!   （`thetvdb_id` 零命中）。按裸数字 / 错键名解析会让 tmdbId 与 tvdbId 恒为 null，多季对齐与
//!   TMDB id 接力全部静默失效。
//! - 条目按 anidb_id **首次出现**的顺序输出（= Dart `Map` 插入序，下游索引与紧凑
//!   交叉引用的 JSON 键序都依赖它）。
//!
//! 输出是定长 i64 记录 + mal id 池 + UTF-16 池（布局见 [encode]），由 Dart 重建三张索引
//! ——条目对象要交回调用方（`AnimeIdentityEntry`），留在 Rust 里按需查询省不掉这一步，
//! 反而要多管一份跨 isolate 的原生句柄生命周期。

use std::collections::HashMap;

use super::media_name::dart_str::{dart_int_try_parse, trim};
use crate::{guard, hand_over_bytes, status};

/// 解析失败的种类（Dart 侧据此抛与旧实现同类型的异常）。
#[derive(Debug, PartialEq, Eq)]
pub enum FribbError {
    /// 不是合法 JSON；`offset` 是出错的字节位置。
    InvalidJson { offset: usize },
    /// 合法 JSON 但顶层不是数组。
    NotAList,
}

/// 用得到的 JSON 值（只在深度预算内建树；更深的容器记为 [J::Other]）。
#[derive(Debug, Clone)]
enum J {
    Int(i64),
    Str(Vec<u16>),
    Arr(Vec<J>),
    Obj(Vec<(Vec<u16>, J)>),
    /// null / bool / double / 超出预算的容器：参与不了任何 id 判定。
    Other,
}

impl J {
    /// Dart `container is Map ? container[key] : null`（重复键后者生效）。
    fn field(&self, key: &[u16]) -> Option<&J> {
        match self {
            J::Obj(entries) => entries.iter().rev().find(|(k, _)| k == key).map(|(_, v)| v),
            _ => None,
        }
    }
}

fn int_of(value: Option<&J>) -> Option<i64> {
    match value? {
        J::Int(v) => Some(*v),
        J::Str(s) => dart_int_try_parse(trim(s)),
        _ => None,
    }
}

fn positive_id(value: Option<&J>) -> Option<i64> {
    int_of(value).filter(|&v| v > 0)
}

fn first_positive_id(value: Option<&J>) -> Option<i64> {
    match value {
        Some(J::Arr(items)) => items.iter().find_map(|item| positive_id(Some(item))),
        other => positive_id(other),
    }
}

fn non_negative_int(value: Option<&J>) -> Option<i64> {
    int_of(value).filter(|&v| v >= 0)
}

/// 一个 AniDB 条目（字段同 Dart `AnimeIdentityEntry`）。
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct Entry {
    pub anidb_id: i64,
    pub mal_ids: Vec<i64>,
    pub anilist_id: Option<i64>,
    pub tvdb_id: Option<i64>,
    pub tmdb_id: Option<i64>,
    pub tmdb_season: Option<i64>,
    pub tmdb_episode_offset: Option<i64>,
    pub tvdb_season: Option<i64>,
    pub tvdb_episode_offset: Option<i64>,
    pub kind: Option<Vec<u16>>,
    pub tmdb_is_movie_namespace: bool,
}

struct Parser<'a> {
    b: &'a [u8],
    pos: usize,
}

type R<T> = Result<T, usize>;

/// 行对象里要建值的键。
const ROW_KEYS: [&str; 8] = [
    "anidb_id",
    "mal_id",
    "anilist_id",
    "tvdb_id",
    "themoviedb_id",
    "season",
    "episode_offset",
    "type",
];

impl<'a> Parser<'a> {
    fn ws(&mut self) {
        while let Some(&c) = self.b.get(self.pos) {
            if matches!(c, b' ' | b'\t' | b'\n' | b'\r') {
                self.pos += 1;
            } else {
                break;
            }
        }
    }

    fn peek(&self) -> Option<u8> {
        self.b.get(self.pos).copied()
    }

    fn expect(&mut self, c: u8) -> R<()> {
        if self.peek() == Some(c) {
            self.pos += 1;
            Ok(())
        } else {
            Err(self.pos)
        }
    }

    fn literal(&mut self, word: &[u8]) -> R<()> {
        if self.b[self.pos..].starts_with(word) {
            self.pos += word.len();
            Ok(())
        } else {
            Err(self.pos)
        }
    }

    /// 数字；返回 int（落在 int64 内的整数字面量）或 None（double）。
    fn number(&mut self) -> R<Option<i64>> {
        let start = self.pos;
        if self.peek() == Some(b'-') {
            self.pos += 1;
        }
        match self.peek() {
            Some(b'0') => self.pos += 1,
            Some(b'1'..=b'9') => {
                while matches!(self.peek(), Some(b'0'..=b'9')) {
                    self.pos += 1;
                }
            }
            _ => return Err(self.pos),
        }
        let int_end = self.pos;
        let mut is_int = true;
        if self.peek() == Some(b'.') {
            self.pos += 1;
            if !matches!(self.peek(), Some(b'0'..=b'9')) {
                return Err(self.pos);
            }
            while matches!(self.peek(), Some(b'0'..=b'9')) {
                self.pos += 1;
            }
            is_int = false;
        }
        if matches!(self.peek(), Some(b'e' | b'E')) {
            self.pos += 1;
            if matches!(self.peek(), Some(b'+' | b'-')) {
                self.pos += 1;
            }
            if !matches!(self.peek(), Some(b'0'..=b'9')) {
                return Err(self.pos);
            }
            while matches!(self.peek(), Some(b'0'..=b'9')) {
                self.pos += 1;
            }
            is_int = false;
        }
        if !is_int {
            return Ok(None);
        }
        let text = &self.b[start..int_end];
        let (negative, digits) = match text.first() {
            Some(b'-') => (true, &text[1..]),
            _ => (false, text),
        };
        let mut value: i128 = 0;
        for &d in digits {
            value = value * 10 + (d - b'0') as i128;
            if value > (i64::MAX as i128) + 1 {
                return Ok(None);
            }
        }
        let v = if negative { -value } else { value };
        Ok((v >= i64::MIN as i128 && v <= i64::MAX as i128).then_some(v as i64))
    }

    /// 字符串（已在 `"` 上）。[keep] 时返回 UTF-16，否则只校验。
    fn string(&mut self, keep: bool) -> R<Option<Vec<u16>>> {
        self.expect(b'"')?;
        let mut out: Vec<u16> = Vec::new();
        loop {
            let start = self.pos;
            // 快速跳过普通字节。
            while let Some(&c) = self.b.get(self.pos) {
                if c == b'"' || c == b'\\' || c < 0x20 {
                    break;
                }
                self.pos += 1;
            }
            if keep && self.pos > start {
                // 输入来自 Dart utf8.encode，保证是合法 UTF-8。
                let chunk = std::str::from_utf8(&self.b[start..self.pos]).map_err(|_| start)?;
                out.extend(chunk.encode_utf16());
            }
            match self.peek() {
                None => return Err(self.pos),
                Some(b'"') => {
                    self.pos += 1;
                    return Ok(keep.then_some(out));
                }
                Some(b'\\') => {
                    self.pos += 1;
                    let Some(e) = self.peek() else {
                        return Err(self.pos);
                    };
                    self.pos += 1;
                    let unit: u16 = match e {
                        b'"' => 0x22,
                        b'\\' => 0x5C,
                        b'/' => 0x2F,
                        b'b' => 0x08,
                        b'f' => 0x0C,
                        b'n' => 0x0A,
                        b'r' => 0x0D,
                        b't' => 0x09,
                        b'u' => {
                            let mut v: u16 = 0;
                            for _ in 0..4 {
                                let Some(h) = self.peek() else {
                                    return Err(self.pos);
                                };
                                let d = match h {
                                    b'0'..=b'9' => h - b'0',
                                    b'a'..=b'f' => h - b'a' + 10,
                                    b'A'..=b'F' => h - b'A' + 10,
                                    _ => return Err(self.pos),
                                };
                                v = (v << 4) | d as u16;
                                self.pos += 1;
                            }
                            v
                        }
                        _ => return Err(self.pos - 1),
                    };
                    if keep {
                        out.push(unit);
                    }
                }
                Some(_) => return Err(self.pos), // 裸控制字符
            }
        }
    }

    /// 只校验、不建值地跳过一个值（显式栈，不怕深嵌套）。
    fn skip_value(&mut self) -> R<()> {
        // 栈元素：b'[' / b'{'。
        let mut stack: Vec<u8> = Vec::new();
        loop {
            self.ws();
            // 读一个值的开头。
            match self.peek() {
                Some(b'[') => {
                    self.pos += 1;
                    self.ws();
                    if self.peek() == Some(b']') {
                        self.pos += 1;
                    } else {
                        stack.push(b'[');
                        continue;
                    }
                }
                Some(b'{') => {
                    self.pos += 1;
                    self.ws();
                    if self.peek() == Some(b'}') {
                        self.pos += 1;
                    } else {
                        stack.push(b'{');
                        self.string(false)?;
                        self.ws();
                        self.expect(b':')?;
                        continue;
                    }
                }
                _ => self.scalar()?,
            }
            // 值结束：处理外层的分隔符 / 闭合。
            loop {
                let Some(&top) = stack.last() else {
                    return Ok(());
                };
                self.ws();
                match self.peek() {
                    Some(b',') => {
                        self.pos += 1;
                        if top == b'{' {
                            self.ws();
                            self.string(false)?;
                            self.ws();
                            self.expect(b':')?;
                        }
                        break;
                    }
                    Some(b']') if top == b'[' => {
                        self.pos += 1;
                        stack.pop();
                    }
                    Some(b'}') if top == b'{' => {
                        self.pos += 1;
                        stack.pop();
                    }
                    _ => return Err(self.pos),
                }
            }
        }
    }

    /// 标量（数字 / 字符串 / 字面量），不建值。
    fn scalar(&mut self) -> R<()> {
        match self.peek() {
            Some(b'"') => self.string(false).map(|_| ()),
            Some(b't') => self.literal(b"true"),
            Some(b'f') => self.literal(b"false"),
            Some(b'n') => self.literal(b"null"),
            Some(b'-' | b'0'..=b'9') => self.number().map(|_| ()),
            _ => Err(self.pos),
        }
    }

    /// 建值（[depth] 层以内的容器建树，更深的只校验）。
    fn value(&mut self, depth: u32) -> R<J> {
        self.ws();
        match self.peek() {
            Some(b'"') => Ok(J::Str(self.string(true)?.unwrap_or_default())),
            Some(b'-' | b'0'..=b'9') => Ok(self.number()?.map_or(J::Other, J::Int)),
            Some(b'[') if depth > 0 => {
                self.pos += 1;
                let mut items = Vec::new();
                self.ws();
                if self.peek() == Some(b']') {
                    self.pos += 1;
                    return Ok(J::Arr(items));
                }
                loop {
                    items.push(self.value(depth - 1)?);
                    self.ws();
                    match self.peek() {
                        Some(b',') => self.pos += 1,
                        Some(b']') => {
                            self.pos += 1;
                            return Ok(J::Arr(items));
                        }
                        _ => return Err(self.pos),
                    }
                }
            }
            Some(b'{') if depth > 0 => {
                self.pos += 1;
                let mut entries = Vec::new();
                self.ws();
                if self.peek() == Some(b'}') {
                    self.pos += 1;
                    return Ok(J::Obj(entries));
                }
                loop {
                    self.ws();
                    let key = self.string(true)?.unwrap_or_default();
                    self.ws();
                    self.expect(b':')?;
                    let v = self.value(depth - 1)?;
                    entries.push((key, v));
                    self.ws();
                    match self.peek() {
                        Some(b',') => self.pos += 1,
                        Some(b'}') => {
                            self.pos += 1;
                            return Ok(J::Obj(entries));
                        }
                        _ => return Err(self.pos),
                    }
                }
            }
            Some(b'[' | b'{') => {
                self.skip_value()?;
                Ok(J::Other)
            }
            _ => {
                self.scalar()?;
                Ok(J::Other)
            }
        }
    }

    /// 顶层数组的一行：对象只为 [ROW_KEYS] 建值（其余只校验）；非对象整体跳过。
    /// 行对象的键：在 [keys] 里的下标。键里没有转义时直接比 UTF-8 字节（ROW_KEYS 全是
    /// ASCII，UTF-16 相等 ⇔ 字节相等），有转义才解码成 UTF-16 再比。
    fn row_key(&mut self, keys: &[Vec<u16>]) -> R<Option<usize>> {
        let start = self.pos;
        self.string(false)?;
        let raw = &self.b[start + 1..self.pos - 1];
        if !raw.contains(&b'\\') {
            return Ok(ROW_KEYS.iter().position(|k| k.as_bytes() == raw));
        }
        let end = self.pos;
        self.pos = start;
        let key = self.string(true)?.unwrap_or_default();
        debug_assert_eq!(self.pos, end);
        Ok(keys.iter().position(|k| *k == key))
    }

    fn row(&mut self, keys: &[Vec<u16>]) -> R<Option<Vec<(usize, J)>>> {
        self.ws();
        if self.peek() != Some(b'{') {
            self.skip_value()?;
            return Ok(None);
        }
        self.pos += 1;
        let mut fields: Vec<(usize, J)> = Vec::new();
        self.ws();
        if self.peek() == Some(b'}') {
            self.pos += 1;
            return Ok(Some(fields));
        }
        loop {
            self.ws();
            let index = self.row_key(keys)?;
            self.ws();
            self.expect(b':')?;
            match index {
                // 行内最深要看到 `themoviedb_id.movie[i]`：值本身 + 2 层容器。
                Some(index) => {
                    let v = self.value(3)?;
                    fields.push((index, v));
                }
                None => self.skip_value()?,
            }
            self.ws();
            match self.peek() {
                Some(b',') => self.pos += 1,
                Some(b'}') => {
                    self.pos += 1;
                    return Ok(Some(fields));
                }
                _ => return Err(self.pos),
            }
        }
    }
}

/// 解析整表并归并（纯函数）。
pub fn parse_entries(bytes: &[u8]) -> Result<Vec<Entry>, FribbError> {
    let keys: Vec<Vec<u16>> = ROW_KEYS
        .iter()
        .map(|k| k.encode_utf16().collect())
        .collect();
    let mut p = Parser { b: bytes, pos: 0 };
    let invalid = |offset: usize| FribbError::InvalidJson { offset };
    p.ws();
    let mut rows: Vec<Vec<(usize, J)>> = Vec::new();
    if p.peek() != Some(b'[') {
        // 合法 JSON 但不是数组 → NotAList；不合法 → InvalidJson。
        p.skip_value().map_err(invalid)?;
        p.ws();
        if p.pos != bytes.len() {
            return Err(invalid(p.pos));
        }
        return Err(FribbError::NotAList);
    }
    p.pos += 1;
    p.ws();
    if p.peek() == Some(b']') {
        p.pos += 1;
    } else {
        loop {
            if let Some(fields) = p.row(&keys).map_err(invalid)? {
                rows.push(fields);
            }
            p.ws();
            match p.peek() {
                Some(b',') => p.pos += 1,
                Some(b']') => {
                    p.pos += 1;
                    break;
                }
                _ => return Err(invalid(p.pos)),
            }
        }
    }
    p.ws();
    if p.pos != bytes.len() {
        return Err(invalid(p.pos));
    }
    Ok(merge(rows))
}

fn merge(rows: Vec<Vec<(usize, J)>>) -> Vec<Entry> {
    let (tv, movie, tmdb_key, tvdb_key) = (utf16("tv"), utf16("movie"), utf16("tmdb"), utf16("tvdb"));
    let mut order: Vec<Entry> = Vec::new();
    let mut index: HashMap<i64, usize> = HashMap::new();
    for fields in rows {
        // 重复键后者生效。
        let get = |key: usize| fields.iter().rev().find(|(k, _)| *k == key).map(|(_, v)| v);
        let Some(aid) = positive_id(get(0)) else {
            continue;
        };
        let slot = *index.entry(aid).or_insert_with(|| {
            order.push(Entry {
                anidb_id: aid,
                ..Entry::default()
            });
            order.len() - 1
        });
        let e = &mut order[slot];
        if let Some(mal) = positive_id(get(1)) {
            if !e.mal_ids.contains(&mal) {
                e.mal_ids.push(mal);
            }
        }
        e.anilist_id = e.anilist_id.or_else(|| positive_id(get(2)));
        e.tvdb_id = e.tvdb_id.or_else(|| positive_id(get(3)));
        let tmdb = get(4);
        if e.tmdb_id.is_none() {
            e.tmdb_id = first_positive_id(tmdb.and_then(|t| t.field(&tv)));
        }
        let tmdb_movie = first_positive_id(tmdb.and_then(|t| t.field(&movie)));
        if e.tmdb_id.is_none() && tmdb_movie.is_some() {
            e.tmdb_id = tmdb_movie;
            e.tmdb_is_movie_namespace = true;
        }
        let season = get(5);
        let offset = get(6);
        fn sub<'j>(c: Option<&'j J>, k: &[u16]) -> Option<&'j J> {
            c.and_then(|c| c.field(k))
        }
        e.tmdb_season = e
            .tmdb_season
            .or_else(|| non_negative_int(sub(season, &tmdb_key)));
        e.tvdb_season = e
            .tvdb_season
            .or_else(|| non_negative_int(sub(season, &tvdb_key)));
        e.tmdb_episode_offset = e
            .tmdb_episode_offset
            .or_else(|| non_negative_int(sub(offset, &tmdb_key)));
        e.tvdb_episode_offset = e
            .tvdb_episode_offset
            .or_else(|| non_negative_int(sub(offset, &tvdb_key)));
        if let Some(J::Str(kind)) = get(7) {
            let trimmed = trim(kind);
            if !trimmed.is_empty() && e.kind.is_none() {
                e.kind = Some(trimmed.to_vec());
            }
        }
    }
    order
}

fn utf16(s: &str) -> Vec<u16> {
    s.encode_utf16().collect()
}

/// 每条记录的 i64 个数。布局（与 Dart 绑定一致，`-1` = null，所有取值都非负）：
/// `[anidb, anilist, tvdb, tmdb, tmdbSeason, tmdbOffset, tvdbSeason, tvdbOffset, flags,
///   type.off, type.len(-1 = null), mal.off, mal.count]`；`flags` 位 0 = tmdb 电影命名空间。
pub const RECORD_INTS: usize = 13;

/// 输出缓冲区：`[i64 条目数, i64 mal 池长, i64 UTF-16 池长][记录…][mal 池 i64…][UTF-16 池]`。
pub fn encode(entries: &[Entry]) -> Vec<u8> {
    let mut ints: Vec<i64> = Vec::with_capacity(3 + entries.len() * RECORD_INTS);
    let mut mals: Vec<i64> = Vec::new();
    let mut pool: Vec<u16> = Vec::new();
    ints.extend([entries.len() as i64, 0, 0]);
    let opt = |v: Option<i64>| v.unwrap_or(-1);
    for e in entries {
        ints.extend([
            e.anidb_id,
            opt(e.anilist_id),
            opt(e.tvdb_id),
            opt(e.tmdb_id),
            opt(e.tmdb_season),
            opt(e.tmdb_episode_offset),
            opt(e.tvdb_season),
            opt(e.tvdb_episode_offset),
            i64::from(e.tmdb_is_movie_namespace),
        ]);
        match &e.kind {
            None => ints.extend([0, -1]),
            Some(k) => {
                ints.extend([pool.len() as i64, k.len() as i64]);
                pool.extend_from_slice(k);
            }
        }
        ints.extend([mals.len() as i64, e.mal_ids.len() as i64]);
        mals.extend_from_slice(&e.mal_ids);
    }
    ints[1] = mals.len() as i64;
    ints[2] = pool.len() as i64;
    let mut bytes = Vec::with_capacity((ints.len() + mals.len()) * 8 + pool.len() * 2);
    for v in ints.iter().chain(mals.iter()) {
        bytes.extend_from_slice(&v.to_ne_bytes());
    }
    for u in pool {
        bytes.extend_from_slice(&u.to_ne_bytes());
    }
    bytes
}

/// 解析 `bytes[0..len]`（UTF-8 的 Fribb 全表）。返回 `OK` 时 `*out_ptr` / `*out_len` 是 [encode]
/// 布局的缓冲区（`ffc_free_bytes` 释放）；`BAD_INPUT` 时 `*out_error_kind` = 1（非法 JSON，
/// `*out_error_offset` 为字节位置）或 2（顶层不是数组）。
///
/// # Safety
/// `len > 0` 时 `bytes` 可读；四个输出指针非空可写。
#[no_mangle]
pub unsafe extern "C" fn ffc_parse_fribb_entries(
    bytes: *const u8,
    len: usize,
    out_ptr: *mut *mut u8,
    out_len: *mut usize,
    out_error_kind: *mut i32,
    out_error_offset: *mut usize,
) -> i32 {
    if out_ptr.is_null()
        || out_len.is_null()
        || out_error_kind.is_null()
        || out_error_offset.is_null()
        || (len > 0 && bytes.is_null())
    {
        return status::NULL_ARGUMENT;
    }
    guard(|| {
        let input: &[u8] = if len == 0 {
            &[]
        } else {
            std::slice::from_raw_parts(bytes, len)
        };
        *out_error_kind = 0;
        *out_error_offset = 0;
        match parse_entries(input) {
            Ok(entries) => {
                hand_over_bytes(encode(&entries), out_ptr, out_len);
                status::OK
            }
            Err(FribbError::InvalidJson { offset }) => {
                *out_error_kind = 1;
                *out_error_offset = offset;
                status::BAD_INPUT
            }
            Err(FribbError::NotAList) => {
                *out_error_kind = 2;
                status::BAD_INPUT
            }
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(s: &str) -> Result<Vec<Entry>, FribbError> {
        parse_entries(s.as_bytes())
    }

    #[test]
    fn merges_rows_like_dart() {
        let rows = r#"[
          {"anidb_id": 10, "mal_id": 5, "themoviedb_id": {"movie": [0, "7"]}, "type": " MOVIE "},
          {"anidb_id": "10", "mal_id": 6, "themoviedb_id": {"tv": 9}, "season": {"tmdb": 0}},
          {"anidb_id": 10, "mal_id": 5, "anidb_id": 11},
          3, [1], {"anidb_id": 1.0}, {"anidb_id": -2}, {"anidb_id": 12, "tvdb_id": 9223372036854775808}
        ]"#;
        let e = parse(rows).unwrap();
        assert_eq!(
            e.iter().map(|e| e.anidb_id).collect::<Vec<_>>(),
            vec![10, 11, 12]
        );
        assert_eq!(e[0].mal_ids, vec![5, 6]);
        assert_eq!(e[0].tmdb_id, Some(7));
        assert!(e[0].tmdb_is_movie_namespace);
        assert_eq!(e[0].tmdb_season, Some(0));
        assert_eq!(e[0].kind, Some(utf16("MOVIE")));
        assert_eq!(e[1].mal_ids, vec![5]);
        assert_eq!(e[2].tvdb_id, None);
    }

    #[test]
    fn rejects_like_dart() {
        assert!(matches!(
            parse("\u{feff}[1]"),
            Err(FribbError::InvalidJson { .. })
        ));
        assert!(matches!(parse("[01]"), Err(FribbError::InvalidJson { .. })));
        assert!(matches!(parse("[1.]"), Err(FribbError::InvalidJson { .. })));
        assert!(matches!(
            parse("[\"a\u{1}\"]"),
            Err(FribbError::InvalidJson { .. })
        ));
        assert!(matches!(
            parse("[1] x"),
            Err(FribbError::InvalidJson { .. })
        ));
        assert!(matches!(
            parse("[1]\u{a0}"),
            Err(FribbError::InvalidJson { .. })
        ));
        assert!(matches!(parse(""), Err(FribbError::InvalidJson { .. })));
        assert_eq!(parse("{\"a\": 1}"), Err(FribbError::NotAList));
        assert_eq!(parse(" 3 "), Err(FribbError::NotAList));
        assert!(parse(" [ ] ").unwrap().is_empty());
        // 深嵌套只校验不建树。
        let deep = format!(
            "[{{\"x\": {}{}}}]",
            "[".repeat(100_000),
            "]".repeat(100_000)
        );
        assert!(parse(&deep).unwrap().is_empty());
    }

    #[test]
    fn lone_surrogate_in_type_survives() {
        let e = parse(r#"[{"anidb_id": 1, "type": "\ud800x"}]"#).unwrap();
        assert_eq!(e[0].kind, Some(vec![0xD800, 0x78]));
    }
}
