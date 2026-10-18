//! `ffc_parse_title_*`：视频刮削标题归一化、分词与相似度（原 Dart
//! `TitleNormalizer`，packages/fushi_engine/lib/media/video/scraper/title_normalizer.dart；
//! Dart 那边只剩经 FFI 调过来的外壳，**算法只有这一份**）。
//!
//! 结果必须与原 Dart 实现逐位一致（相似度是 `f64` 位模式一致），所以这里刻意按 Dart
//! 的语义复刻，而不是按 Rust 习惯：
//! - 字符串一律是 UTF-16 码元（Dart `String` 的原生表示）；「码点」按 Dart `String.runes`
//!   解码——合法代理对合成一个码点，孤立代理按码元值本身算一个码点。
//! - 长度比较（Levenshtein 的分母、`_isFuzzyCandidate` 的长度比）用 UTF-16 码元数，
//!   编辑距离与分词用码点——原实现就是这么混用的，照抄。
//! - 小写、`\s`、`trim()` 的字符集与分词的「字母/数字」判定来自生成表
//!   （`tool/gen_title_tables.dart` 从 Dart 运行时逐码点冻结）。
//! - 编辑距离用 Myers / Hyyrö 位并行算法（码点数 ≤ 64 时）——与经典 DP 的距离值严格
//!   相等（测试里随机对拍），只是快。

use std::sync::OnceLock;

use crate::{guard, hand_over_bytes, status};

// 生成文件按生成器原样入库（`--check` 逐字比对），不让 rustfmt 重排。
#[rustfmt::skip]
mod title_tables;

use super::dart_lower::dart_lower_code_point;
use title_tables::{DECORATION, TRAD_TO_SIMP, WORD_RANGES, WS_REGEX, WS_TRIM};

const F_DECORATION: u8 = 1;
const F_WS_REGEX: u8 = 2;
const F_WS_TRIM: u8 = 4;
const F_WORD: u8 = 8;

struct BmpTables {
    /// 繁→简（恒等映射为默认）。
    simplify: Box<[u16]>,
    flags: Box<[u8]>,
}

fn bmp() -> &'static BmpTables {
    static TABLES: OnceLock<BmpTables> = OnceLock::new();
    TABLES.get_or_init(|| {
        // 堆上建表（Dart isolate 线程的栈不保证放得下 256 KiB 的数组临时量）。
        let mut simplify: Vec<u16> = (0..0x10000u32).map(|u| u as u16).collect();
        for &(from, to) in TRAD_TO_SIMP.iter() {
            simplify[from as usize] = to;
        }
        let mut flags: Vec<u8> = vec![0u8; 0x10000];
        for &u in DECORATION.iter() {
            flags[u as usize] |= F_DECORATION;
        }
        for &u in WS_REGEX.iter() {
            flags[u as usize] |= F_WS_REGEX;
        }
        for &u in WS_TRIM.iter() {
            flags[u as usize] |= F_WS_TRIM;
        }
        for &(start, end) in WORD_RANGES.iter() {
            if start > 0xFFFF {
                break;
            }
            for cp in start..=end.min(0xFFFF) {
                flags[cp as usize] |= F_WORD;
            }
        }
        BmpTables {
            simplify: simplify.into_boxed_slice(),
            flags: flags.into_boxed_slice(),
        }
    })
}

fn search_ranges(ranges: &[(u32, u32)], cp: u32) -> bool {
    ranges
        .binary_search_by(|&(start, end)| {
            if end < cp {
                std::cmp::Ordering::Less
            } else if start > cp {
                std::cmp::Ordering::Greater
            } else {
                std::cmp::Ordering::Equal
            }
        })
        .is_ok()
}

/// Dart `String.toLowerCase` 对单个码点的结果（crate 共用的冻结表，1:1、上下文无关）。
#[inline]
pub fn dart_lower(cp: u32) -> u32 {
    dart_lower_code_point(cp)
}

/// Dart `trim()` 的空白（码元）。
pub fn is_trim_whitespace(unit: u16) -> bool {
    bmp().flags[unit as usize] & F_WS_TRIM != 0
}

/// 非 unicode 模式正则 `\s`（码元）。
pub fn is_regex_whitespace(unit: u16) -> bool {
    bmp().flags[unit as usize] & F_WS_REGEX != 0
}

/// Dart `String.trim()`。
pub fn dart_trim(units: &[u16]) -> &[u16] {
    let mut start = 0;
    let mut end = units.len();
    while start < end && is_trim_whitespace(units[start]) {
        start += 1;
    }
    while end > start && is_trim_whitespace(units[end - 1]) {
        end -= 1;
    }
    &units[start..end]
}

/// Dart `String.toLowerCase()`（逐码点；输入输出都是 UTF-16）。
pub fn dart_to_lower(units: &[u16]) -> Vec<u16> {
    let mut out = Vec::with_capacity(units.len());
    for_each_rune(units, |cp| push_rune(&mut out, dart_lower(cp)));
    out
}

/// 按 Dart `String.runes` 解码：合法代理对合成一个码点，孤立代理原样。
#[inline]
pub fn for_each_rune(units: &[u16], mut f: impl FnMut(u32)) {
    let len = units.len();
    let mut i = 0;
    while i < len {
        let unit = units[i] as u32;
        if (0xD800..=0xDBFF).contains(&unit) && i + 1 < len {
            let low = units[i + 1] as u32;
            if (0xDC00..=0xDFFF).contains(&low) {
                f(0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00));
                i += 2;
                continue;
            }
        }
        f(unit);
        i += 1;
    }
}

pub fn runes(units: &[u16]) -> Vec<u32> {
    let mut out = Vec::with_capacity(units.len());
    for_each_rune(units, |cp| out.push(cp));
    out
}

/// `String.fromCharCode(cp)` 追加到 UTF-16 缓冲（孤立代理值写成单个码元）。
#[inline]
pub fn push_rune(out: &mut Vec<u16>, cp: u32) {
    if cp >= 0x10000 {
        let v = cp - 0x10000;
        out.push((0xD800 + (v >> 10)) as u16);
        out.push((0xDC00 + (v & 0x3FF)) as u16);
    } else {
        out.push(cp as u16);
    }
}

/// 原 `TitleNormalizer.normalize`：全角→半角 → 繁→简 → 去装饰符号（替换为空格）
/// → 小写 → `\s+` 折叠为一个空格 → `trim()`。
pub fn normalize(units: &[u16]) -> Vec<u16> {
    let tables = bmp();
    let mut mapped: Vec<u16> = Vec::with_capacity(units.len());
    for_each_rune(units, |rune| {
        let r = if rune == 0x3000 {
            0x20
        } else if (0xFF01..=0xFF5E).contains(&rune) {
            rune - 0xFEE0
        } else {
            rune
        };
        let ch = if r <= 0xFFFF {
            u32::from(tables.simplify[r as usize])
        } else {
            r
        };
        // `simplified.length == 1 && _kDecorationChars.contains(...)`：只有单码元才查。
        let decorated = ch <= 0xFFFF && tables.flags[ch as usize] & F_DECORATION != 0;
        let out = if decorated { 0x20 } else { ch };
        push_rune(&mut mapped, dart_lower(out));
    });
    // replaceAll(RegExp(r'\s+'), ' ')
    let mut collapsed: Vec<u16> = Vec::with_capacity(mapped.len());
    let mut in_ws = false;
    for &unit in &mapped {
        if tables.flags[unit as usize] & F_WS_REGEX != 0 {
            if !in_ws {
                collapsed.push(0x20);
                in_ws = true;
            }
        } else {
            collapsed.push(unit);
            in_ws = false;
        }
    }
    dart_trim(&collapsed).to_vec()
}

/// 汉字 + 平/片假名：无空格分界，按 2-gram 切。
#[inline]
pub fn is_cjk(rune: u32) -> bool {
    (0x4E00..=0x9FFF).contains(&rune)
        || (0x3400..=0x4DBF).contains(&rune)
        || (0xF900..=0xFAFF).contains(&rune)
        || (0x3040..=0x309F).contains(&rune)
        || (0x30A0..=0x30FF).contains(&rune)
}

/// 原 `_isWordChar`（含 CJK）。
#[inline]
pub fn is_word_char(rune: u32) -> bool {
    if rune <= 0xFFFF {
        return bmp().flags[rune as usize] & F_WORD != 0;
    }
    search_ranges(&WORD_RANGES, rune)
}

/// 原 `TitleNormalizer.tokens`：每个 token 是码点序列，按出现顺序（可重复）。
pub fn tokens_of_runes(runes: &[u32], mut emit: impl FnMut(&[u32])) {
    let n = runes.len();
    let mut i = 0;
    while i < n {
        let r = runes[i];
        if is_cjk(r) {
            let mut j = i;
            while j < n && is_cjk(runes[j]) {
                j += 1;
            }
            if j - i == 1 {
                emit(&runes[i..i + 1]);
            } else {
                for k in i..j - 1 {
                    emit(&runes[k..k + 2]);
                }
            }
            i = j;
        } else if is_word_char(r) {
            let mut j = i;
            while j < n && is_word_char(runes[j]) && !is_cjk(runes[j]) {
                j += 1;
            }
            emit(&runes[i..j]);
            i = j;
        } else {
            i += 1;
        }
    }
}

/// token 集（去重、有序），用于 Dice 系数。
pub fn token_set(runes: &[u32]) -> Vec<Vec<u32>> {
    let mut set: Vec<Vec<u32>> = Vec::new();
    tokens_of_runes(runes, |token| set.push(token.to_vec()));
    set.sort_unstable();
    set.dedup();
    set
}

fn sorted_intersection_len<T: Ord>(a: &[T], b: &[T]) -> usize {
    let (mut i, mut j, mut count) = (0, 0, 0);
    while i < a.len() && j < b.len() {
        match a[i].cmp(&b[j]) {
            std::cmp::Ordering::Less => i += 1,
            std::cmp::Ordering::Greater => j += 1,
            std::cmp::Ordering::Equal => {
                count += 1;
                i += 1;
                j += 1;
            }
        }
    }
    count
}

/// Dart `math.max(double, double)`（含 ±0 与 NaN 的处理）。
#[inline]
pub fn dart_max(a: f64, b: f64) -> f64 {
    if a > b {
        return a;
    }
    if a < b {
        return b;
    }
    if a == 0.0 && b == 0.0 {
        return if a.is_sign_negative() { b } else { a };
    }
    if b.is_nan() {
        return b;
    }
    a
}

/// Dart `double.compareTo`。
#[inline]
pub fn dart_double_compare(a: f64, b: f64) -> i32 {
    if a < b {
        return -1;
    }
    if a > b {
        return 1;
    }
    if a == b {
        if a == 0.0 {
            let an = a.is_sign_negative();
            let bn = b.is_sign_negative();
            if an == bn {
                return 0;
            }
            return if an { -1 } else { 1 };
        }
        return 0;
    }
    if a.is_nan() {
        return if b.is_nan() { 0 } else { 1 };
    }
    -1
}

/// 经典两行滚动 Levenshtein（码点）。
pub fn levenshtein_dp(a: &[u32], b: &[u32]) -> usize {
    if a.is_empty() {
        return b.len();
    }
    if b.is_empty() {
        return a.len();
    }
    let mut prev: Vec<usize> = (0..=b.len()).collect();
    let mut curr: Vec<usize> = vec![0; b.len() + 1];
    for i in 1..=a.len() {
        curr[0] = i;
        for j in 1..=b.len() {
            let cost = usize::from(a[i - 1] != b[j - 1]);
            curr[j] = (curr[j - 1] + 1).min(prev[j] + 1).min(prev[j - 1] + cost);
        }
        std::mem::swap(&mut prev, &mut curr);
    }
    prev[b.len()]
}

/// Myers 位并行编辑距离的模式串预处理（码点数 1..=64）。
pub struct MyersPattern {
    len: usize,
    ascii: [u64; 128],
    other: Vec<(u32, u64)>,
}

impl MyersPattern {
    pub fn new(pattern: &[u32]) -> Option<Self> {
        if pattern.is_empty() || pattern.len() > 64 {
            return None;
        }
        let mut ascii = [0u64; 128];
        let mut other: Vec<(u32, u64)> = Vec::new();
        for (i, &cp) in pattern.iter().enumerate() {
            let bit = 1u64 << i;
            if cp < 128 {
                ascii[cp as usize] |= bit;
            } else {
                match other.binary_search_by(|&(c, _)| c.cmp(&cp)) {
                    Ok(index) => other[index].1 |= bit,
                    Err(index) => other.insert(index, (cp, bit)),
                }
            }
        }
        Some(Self {
            len: pattern.len(),
            ascii,
            other,
        })
    }

    #[inline]
    fn peq(&self, cp: u32) -> u64 {
        if cp < 128 {
            return self.ascii[cp as usize];
        }
        match self.other.binary_search_by(|&(c, _)| c.cmp(&cp)) {
            Ok(index) => self.other[index].1,
            Err(_) => 0,
        }
    }

    /// 与 [levenshtein_dp]（模式串, text）严格相等。
    pub fn distance(&self, text: &[u32]) -> usize {
        let m = self.len;
        if text.is_empty() {
            return m;
        }
        let high = 1u64 << (m - 1);
        let mut pv: u64 = !0;
        let mut mv: u64 = 0;
        let mut score = m;
        for &cp in text {
            let eq = self.peq(cp);
            let xv = eq | mv;
            let xh = ((eq & pv).wrapping_add(pv) ^ pv) | eq;
            let mut ph = mv | !(xh | pv);
            let mut mh = pv & xh;
            if ph & high != 0 {
                score += 1;
            } else if mh & high != 0 {
                score -= 1;
            }
            ph = (ph << 1) | 1;
            mh <<= 1;
            pv = mh | !(xv | ph);
            mv = ph & xv;
        }
        score
    }
}

/// 两段码点的编辑距离（能用位并行就用）。
pub fn levenshtein(a: &[u32], b: &[u32]) -> usize {
    if a.is_empty() {
        return b.len();
    }
    if b.is_empty() {
        return a.len();
    }
    let (pattern, text) = if a.len() <= b.len() { (a, b) } else { (b, a) };
    match MyersPattern::new(pattern) {
        Some(p) => p.distance(text),
        None => levenshtein_dp(a, b),
    }
}

/// Dice 与 Levenshtein 合成的最终分数（原 `similarityNormalized` 的尾段）。
#[inline]
pub fn combine_score(
    inter: usize,
    la: usize,
    lb: usize,
    dist: usize,
    units_a: usize,
    units_b: usize,
) -> f64 {
    let mut dice = 0.0f64;
    if la > 0 && lb > 0 {
        dice = 2.0 * (inter as f64) / ((la + lb) as f64);
    }
    let max_len = units_a.max(units_b);
    let lev = if max_len == 0 {
        1.0
    } else {
        1.0 - (dist as f64) / (max_len as f64)
    };
    dart_max(dice, dart_max(lev, 0.0))
}

/// 原 `TitleNormalizer.similarityNormalized`：两个参数都必须是 [normalize] 的输出。
pub fn similarity_normalized(na: &[u16], nb: &[u16]) -> f64 {
    if na.is_empty() || nb.is_empty() {
        return if na == nb { 1.0 } else { 0.0 };
    }
    if na == nb {
        return 1.0;
    }
    let ra = runes(na);
    let rb = runes(nb);
    let ta = token_set(&ra);
    let tb = token_set(&rb);
    let inter = if ta.is_empty() || tb.is_empty() {
        0
    } else {
        sorted_intersection_len(&ta, &tb)
    };
    let dist = levenshtein(&ra, &rb);
    combine_score(inter, ta.len(), tb.len(), dist, na.len(), nb.len())
}

/// 原 `TitleNormalizer.similarity`。
pub fn similarity(a: &[u16], b: &[u16]) -> f64 {
    similarity_normalized(&normalize(a), &normalize(b))
}

/// 一批候选对同一查询的打分：查询的码点 / token 集 / 位并行模式只算一次。
pub struct PreparedQuery {
    units: Vec<u16>,
    runes: Vec<u32>,
    tokens: Vec<Vec<u32>>,
    myers: Option<MyersPattern>,
}

impl PreparedQuery {
    pub fn new(normalized: &[u16]) -> Self {
        let runes = runes(normalized);
        let tokens = token_set(&runes);
        let myers = MyersPattern::new(&runes);
        Self {
            units: normalized.to_vec(),
            runes,
            tokens,
            myers,
        }
    }

    pub fn units(&self) -> &[u16] {
        &self.units
    }

    pub fn runes(&self) -> &[u32] {
        &self.runes
    }

    /// 距离：查询能做位并行模式就用它，否则退回通用路径（结果相同）。
    pub fn distance(&self, candidate_runes: &[u32]) -> usize {
        if self.runes.is_empty() || candidate_runes.is_empty() {
            return self.runes.len().max(candidate_runes.len());
        }
        match &self.myers {
            Some(p) => p.distance(candidate_runes),
            None => levenshtein(&self.runes, candidate_runes),
        }
    }

    /// 与 `similarity_normalized(self.units, candidate)` 严格相等。
    pub fn similarity(&self, candidate: &[u16]) -> f64 {
        let na = &self.units;
        if na.is_empty() || candidate.is_empty() {
            return if na.as_slice() == candidate { 1.0 } else { 0.0 };
        }
        if na.as_slice() == candidate {
            return 1.0;
        }
        let rb = runes(candidate);
        let tb = token_set(&rb);
        let inter = if self.tokens.is_empty() || tb.is_empty() {
            0
        } else {
            sorted_intersection_len(&self.tokens, &tb)
        };
        let dist = self.distance(&rb);
        combine_score(
            inter,
            self.tokens.len(),
            tb.len(),
            dist,
            na.len(),
            candidate.len(),
        )
    }

    /// 已预先算好候选码点与 token 交集时的打分（AniDB 索引用）。
    pub fn similarity_with(
        &self,
        candidate: &[u16],
        candidate_runes: &[u32],
        inter: usize,
        candidate_tokens: usize,
    ) -> f64 {
        let na = &self.units;
        if na.is_empty() || candidate.is_empty() {
            return if na.as_slice() == candidate { 1.0 } else { 0.0 };
        }
        if na.as_slice() == candidate {
            return 1.0;
        }
        let inter = if self.tokens.is_empty() || candidate_tokens == 0 {
            0
        } else {
            inter
        };
        let dist = self.distance(candidate_runes);
        combine_score(
            inter,
            self.tokens.len(),
            candidate_tokens,
            dist,
            na.len(),
            candidate.len(),
        )
    }

    pub fn tokens(&self) -> &[Vec<u32>] {
        &self.tokens
    }

    /// 与 `similarity_normalized(self.units, candidate.units)` 严格相等。
    pub fn similarity_prepared(&self, candidate: &PreparedText) -> f64 {
        let na = &self.units;
        let nb = &candidate.units;
        if na.is_empty() || nb.is_empty() {
            return if na == nb { 1.0 } else { 0.0 };
        }
        if na == nb {
            return 1.0;
        }
        let inter = if self.tokens.is_empty() || candidate.tokens.is_empty() {
            0
        } else {
            sorted_intersection_len(&self.tokens, &candidate.tokens)
        };
        let dist = self.distance(&candidate.runes);
        combine_score(
            inter,
            self.tokens.len(),
            candidate.tokens.len(),
            dist,
            na.len(),
            nb.len(),
        )
    }
}

/// 预先解码好的候选（矩阵打分时每个候选只解码 / 分词一次）。
pub struct PreparedText {
    units: Vec<u16>,
    runes: Vec<u32>,
    tokens: Vec<Vec<u32>>,
}

impl PreparedText {
    pub fn new(normalized: &[u16]) -> Self {
        let runes = runes(normalized);
        let tokens = token_set(&runes);
        Self {
            units: normalized.to_vec(),
            runes,
            tokens,
        }
    }
}

/// `offsets`（`count + 1` 项，单调不减）切出的 `count` 段。
///
/// # Safety
/// `offsets` 有 `count + 1` 项；`units` 至少 `offsets[count]` 项。
unsafe fn segments<'a>(
    units: *const u16,
    offsets: *const u32,
    count: usize,
) -> Option<Vec<&'a [u16]>> {
    if count == 0 {
        return Some(Vec::new());
    }
    if offsets.is_null() {
        return None;
    }
    let offsets = std::slice::from_raw_parts(offsets, count + 1);
    let all = units_arg(units, offsets[count] as usize)?;
    let mut out = Vec::with_capacity(count);
    for i in 0..count {
        let (a, b) = (offsets[i] as usize, offsets[i + 1] as usize);
        if a > b || b > all.len() {
            return None;
        }
        out.push(&all[a..b]);
    }
    Some(out)
}

/// 批量归一化：第 `i` 个输入是 `units[offsets[i]..offsets[i + 1]]`；输出字符串列表
/// （见 [encode_string_list]，与输入同序），用 `ffc_free_bytes` 释放。
///
/// # Safety
/// 见 [segments]；输出指针非空可写。
#[no_mangle]
pub unsafe extern "C" fn ffc_parse_title_normalize_batch(
    units: *const u16,
    offsets: *const u32,
    count: usize,
    out_ptr: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    if out_ptr.is_null() || out_len.is_null() {
        return status::NULL_ARGUMENT;
    }
    guard(|| {
        let Some(inputs) = segments(units, offsets, count) else {
            return status::INVALID_ARGUMENT;
        };
        let items: Vec<Vec<u16>> = inputs.iter().map(|s| normalize(s)).collect();
        hand_over_bytes(encode_string_list(&items), out_ptr, out_len);
        status::OK
    })
}

/// 相似度矩阵：`out[q * candidate_count + c] = similarityNormalized(query[q], candidate[c])`
/// （两侧都已归一化；切分方式同 [ffc_parse_title_normalize_batch]）。
///
/// # Safety
/// 见 [segments]；`out` 有 `query_count * candidate_count` 项可写。
#[no_mangle]
pub unsafe extern "C" fn ffc_parse_title_similarity_normalized_matrix(
    query_units: *const u16,
    query_offsets: *const u32,
    query_count: usize,
    candidate_units: *const u16,
    candidate_offsets: *const u32,
    candidate_count: usize,
    out: *mut f64,
) -> i32 {
    let total = query_count.saturating_mul(candidate_count);
    if total == 0 {
        return status::OK;
    }
    if out.is_null() {
        return status::NULL_ARGUMENT;
    }
    guard(|| {
        let (Some(queries), Some(candidates)) = (
            segments(query_units, query_offsets, query_count),
            segments(candidate_units, candidate_offsets, candidate_count),
        ) else {
            return status::INVALID_ARGUMENT;
        };
        let out = std::slice::from_raw_parts_mut(out, total);
        let prepared: Vec<PreparedText> = candidates.iter().map(|c| PreparedText::new(c)).collect();
        for (qi, query) in queries.iter().enumerate() {
            let q = PreparedQuery::new(query);
            for (ci, candidate) in prepared.iter().enumerate() {
                out[qi * candidate_count + ci] = q.similarity_prepared(candidate);
            }
        }
        status::OK
    })
}

/// UTF-16 字符串列表的输出编码（与 Dart `decodeFfcStringList` 一致）：
/// `u32 count`、`count` 个 `u32` 码元长度、之后所有字符串的码元依次拼接（小端）。
pub fn encode_string_list(items: &[Vec<u16>]) -> Vec<u8> {
    let total: usize = items.iter().map(Vec::len).sum();
    let mut out = Vec::with_capacity(4 + 4 * items.len() + 2 * total);
    out.extend_from_slice(&(items.len() as u32).to_le_bytes());
    for item in items {
        out.extend_from_slice(&(item.len() as u32).to_le_bytes());
    }
    for item in items {
        for &unit in item {
            out.extend_from_slice(&unit.to_le_bytes());
        }
    }
    out
}

/// # Safety
/// `len > 0` 时 `ptr` 指向 `len` 个可读 `u16`。
pub(crate) unsafe fn units_arg<'a>(ptr: *const u16, len: usize) -> Option<&'a [u16]> {
    if len == 0 {
        return Some(&[]);
    }
    if ptr.is_null() {
        return None;
    }
    Some(std::slice::from_raw_parts(ptr, len))
}

/// 归一化 `units[0..len]`，写进调用方缓冲 `out[0..out_cap]`，`*out_len` 写实际码元数。
/// 缓冲不够时返回 [status::BUFFER_TOO_SMALL]，`*out_len` 写所需长度（不写 `out`）。
///
/// # Safety
/// 指针按长度可读 / 可写；`out_len` 非空。
#[no_mangle]
pub unsafe extern "C" fn ffc_parse_title_normalize(
    units: *const u16,
    len: usize,
    out: *mut u16,
    out_cap: usize,
    out_len: *mut usize,
) -> i32 {
    if out_len.is_null() {
        return status::NULL_ARGUMENT;
    }
    let Some(input) = units_arg(units, len) else {
        return status::NULL_ARGUMENT;
    };
    guard(|| {
        let normalized = normalize(input);
        *out_len = normalized.len();
        if normalized.len() > out_cap {
            return status::BUFFER_TOO_SMALL;
        }
        if !normalized.is_empty() {
            if out.is_null() {
                return status::NULL_ARGUMENT;
            }
            std::ptr::copy_nonoverlapping(normalized.as_ptr(), out, normalized.len());
        }
        status::OK
    })
}

/// 分词：输出见 [encode_string_list]（按出现顺序，可重复），用 `ffc_free_bytes` 释放。
///
/// # Safety
/// 指针按长度可读；`out_ptr` / `out_len` 非空。
#[no_mangle]
pub unsafe extern "C" fn ffc_parse_title_tokens(
    units: *const u16,
    len: usize,
    out_ptr: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    if out_ptr.is_null() || out_len.is_null() {
        return status::NULL_ARGUMENT;
    }
    let Some(input) = units_arg(units, len) else {
        return status::NULL_ARGUMENT;
    };
    guard(|| {
        let mut items: Vec<Vec<u16>> = Vec::new();
        tokens_of_runes(&runes(input), |token| {
            let mut item = Vec::with_capacity(token.len());
            for &cp in token {
                push_rune(&mut item, cp);
            }
            items.push(item);
        });
        hand_over_bytes(encode_string_list(&items), out_ptr, out_len);
        status::OK
    })
}

/// `similarity(a, b)`（两侧先归一化）。
///
/// # Safety
/// 指针按长度可读；`out` 非空。
#[no_mangle]
pub unsafe extern "C" fn ffc_parse_title_similarity(
    a: *const u16,
    a_len: usize,
    b: *const u16,
    b_len: usize,
    out: *mut f64,
) -> i32 {
    if out.is_null() {
        return status::NULL_ARGUMENT;
    }
    let (Some(a), Some(b)) = (units_arg(a, a_len), units_arg(b, b_len)) else {
        return status::NULL_ARGUMENT;
    };
    guard(|| {
        *out = similarity(a, b);
        status::OK
    })
}

/// `similarityNormalized(a, b)`（两侧都已归一化）。
///
/// # Safety
/// 同 [ffc_parse_title_similarity]。
#[no_mangle]
pub unsafe extern "C" fn ffc_parse_title_similarity_normalized(
    a: *const u16,
    a_len: usize,
    b: *const u16,
    b_len: usize,
    out: *mut f64,
) -> i32 {
    if out.is_null() {
        return status::NULL_ARGUMENT;
    }
    let (Some(a), Some(b)) = (units_arg(a, a_len), units_arg(b, b_len)) else {
        return status::NULL_ARGUMENT;
    };
    guard(|| {
        *out = similarity_normalized(a, b);
        status::OK
    })
}

/// 一个已归一化查询对一批已归一化候选打分：候选 `i` 是
/// `units[offsets[i]..offsets[i + 1]]`（`offsets` 共 `count + 1` 项、单调不减），
/// 结果写 `out[i]`。
///
/// # Safety
/// `query` 按 `query_len` 可读；`offsets` 有 `count + 1` 项，`units` 至少
/// `offsets[count]` 项；`out` 有 `count` 项可写。
#[no_mangle]
pub unsafe extern "C" fn ffc_parse_title_similarity_normalized_batch(
    query: *const u16,
    query_len: usize,
    units: *const u16,
    offsets: *const u32,
    count: usize,
    out: *mut f64,
) -> i32 {
    let Some(query) = units_arg(query, query_len) else {
        return status::NULL_ARGUMENT;
    };
    if count == 0 {
        return status::OK;
    }
    if offsets.is_null() || out.is_null() {
        return status::NULL_ARGUMENT;
    }
    guard(|| {
        let offsets = std::slice::from_raw_parts(offsets, count + 1);
        let total = offsets[count] as usize;
        let Some(all) = units_arg(units, total) else {
            return status::NULL_ARGUMENT;
        };
        for i in 0..count {
            if offsets[i] > offsets[i + 1] {
                return status::INVALID_ARGUMENT;
            }
        }
        let out = std::slice::from_raw_parts_mut(out, count);
        let prepared = PreparedQuery::new(query);
        for i in 0..count {
            let candidate = &all[offsets[i] as usize..offsets[i + 1] as usize];
            out[i] = prepared.similarity(candidate);
        }
        status::OK
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn u(s: &str) -> Vec<u16> {
        s.encode_utf16().collect()
    }

    fn norm(s: &str) -> String {
        String::from_utf16(&normalize(&u(s))).unwrap()
    }

    #[test]
    fn tables_match_generator_digest() {
        fn fnv(mut hash: u32, value: u32) -> u32 {
            for shift in (0..32).step_by(8) {
                hash ^= (value >> shift) & 0xff;
                hash = hash.wrapping_mul(0x01000193);
            }
            hash
        }
        let mut h: u32 = 0x811c9dc5;
        for &(a, b) in TRAD_TO_SIMP.iter() {
            h = fnv(fnv(h, a.into()), b.into());
        }
        for &c in DECORATION.iter() {
            h = fnv(h, c.into());
        }
        for &c in WS_REGEX.iter() {
            h = fnv(h, c.into());
        }
        for &c in WS_TRIM.iter() {
            h = fnv(h, c.into());
        }
        for &(a, b) in WORD_RANGES.iter() {
            h = fnv(fnv(h, a), b);
        }
        assert_eq!(h, title_tables::TITLE_TABLES_FNV1A);
    }

    #[test]
    fn normalize_samples() {
        // 与 fushi/test/media/video/scraper/title_normalizer_test.dart 同口径。
        assert_eq!(norm("ＡＢＣ１２３：Ｒｅ"), "abc123 re");
        assert_eq!(norm("無職転生\u{3000}\u{3000}２"), "无职转生 2");
        assert_eq!(norm("  【推しの子】  第２期 "), "推しの子 第2期");
        assert_eq!(norm(""), "");
        assert_eq!(norm("☆★♪"), "");
        assert_eq!(norm("A～B"), "a b");
        assert_eq!(norm("x\u{85}y"), "x\u{85}y");
        assert_eq!(norm("\u{85}x\u{85}"), "x");
        assert_eq!(norm("İSTANBUL"), "istanbul");
        assert_eq!(norm("ΣΑΣ"), "σασ");
    }

    #[test]
    fn tokens_samples() {
        let t = |s: &str| {
            let mut out: Vec<String> = Vec::new();
            tokens_of_runes(&runes(&u(s)), |tok| {
                out.push(tok.iter().map(|&c| char::from_u32(c).unwrap()).collect())
            });
            out
        };
        assert_eq!(t("无职转生"), vec!["无职", "职转", "转生"]);
        assert_eq!(t("a 生 b"), vec!["a", "生", "b"]);
        assert_eq!(t("re zero ⅱ"), vec!["re", "zero", "ⅱ"]);
        assert_eq!(t("café ÿ"), vec!["café", "ÿ"]);
    }

    #[test]
    fn myers_matches_dp() {
        let mut seed: u64 = 0x9E3779B97F4A7C15;
        let mut next = || {
            seed ^= seed << 13;
            seed ^= seed >> 7;
            seed ^= seed << 17;
            seed
        };
        for _ in 0..20000 {
            let la = (next() % 70) as usize;
            let lb = (next() % 70) as usize;
            let alpha = 1 + (next() % 6) as u32;
            let a: Vec<u32> = (0..la)
                .map(|_| 0x61 + (next() as u32 % alpha) * 997 % 300)
                .collect();
            let b: Vec<u32> = (0..lb)
                .map(|_| 0x61 + (next() as u32 % alpha) * 997 % 300)
                .collect();
            assert_eq!(levenshtein(&a, &b), levenshtein_dp(&a, &b), "{a:?} {b:?}");
            if let Some(p) = MyersPattern::new(&a) {
                assert_eq!(p.distance(&b), levenshtein_dp(&a, &b));
            }
        }
    }

    #[test]
    fn similarity_samples() {
        assert_eq!(similarity(&u("無職転生"), &u("无职转生")), 1.0);
        assert_eq!(similarity(&u(""), &u("")), 1.0);
        assert_eq!(similarity(&u(""), &u("a")), 0.0);
        let s = similarity(&u("Mushoku Tensei"), &u("Mushoku Tensei II"));
        assert!(s > 0.5 && s < 1.0);
        let q = PreparedQuery::new(&normalize(&u("Mushoku Tensei")));
        assert_eq!(
            q.similarity(&normalize(&u("Mushoku Tensei II"))).to_bits(),
            s.to_bits()
        );
    }

    #[test]
    fn dart_number_helpers() {
        assert_eq!(dart_double_compare(-0.0, 0.0), -1);
        assert_eq!(dart_double_compare(0.0, -0.0), 1);
        assert_eq!(dart_double_compare(f64::NAN, 1.0), 1);
        assert!(dart_max(-0.0, 0.0).is_sign_positive());
        assert!(dart_max(0.0, -0.0).is_sign_positive());
    }
}
