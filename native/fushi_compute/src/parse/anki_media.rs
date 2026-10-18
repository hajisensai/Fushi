//! `ffc_parse_anki_*`：Anki 媒体去重的「笔记字段里出现了哪些媒体文件名」扫描。
//!
//! 口径来自原 Dart `MediaNameMatcher`（packages/fushi_anki/lib/src/anki_media_dedup.dart，
//! 已删除，回归向量见 packages/fushi_compute/test/anki_media_test.dart）：与 Anki 的
//! `findNotes "<文件名>"` 对齐——**大小写不敏感的朴素子串**，不判文件名边界。
//!
//! 做法（与旧实现逐步一致，含命中顺序）：
//! - 名字与正文都按 Dart `toLowerCase` 逐码点折叠（[dart_lower_table]，见生成脚本文件头），
//!   在 UTF-16 码元下标上工作；
//! - 有扩展名的名字按「最后一个 `.` 起的后缀」分组，记下各组出现过的长度（插入序）；扫正文时
//!   对每个后缀（插入序）找出全部出现处（允许重叠，升序），按每个长度回切子串查「折叠名 →
//!   原名下标」表；
//! - 没有 `.` 的名字逐个朴素子串查（插入序）；
//! - 命中按首次出现去重。原名下标交回 Dart，由调用方映射回字符串（同名重复的名字在 Dart 的
//!   `Set<String>` 里自然合并，顺序与旧实现相同）。
//!
//! 批量接口：一次调用扫一批「组」（一组 = 一条笔记的全部字段，命中取并集），输出定长 u32
//! 记录，避免逐字段 FFI 往返。

use std::sync::OnceLock;

use crate::{guard, hand_over_bytes, status};

mod dart_lower_table;

use dart_lower_table::DART_LOWER_PAIRS;

/// BMP 直查表（128 KiB，首次使用时展开）；BMP 外走二分。
fn bmp_lower_table() -> &'static [u16; 0x10000] {
    static TABLE: OnceLock<Box<[u16; 0x10000]>> = OnceLock::new();
    TABLE.get_or_init(|| {
        let mut table = Box::new([0u16; 0x10000]);
        for (cp, slot) in table.iter_mut().enumerate() {
            *slot = cp as u16;
        }
        for &(cp, lower) in DART_LOWER_PAIRS.iter() {
            if cp > 0xFFFF {
                break;
            }
            table[cp as usize] = lower as u16;
        }
        table
    })
}

/// 码点按 Dart `toLowerCase` 折叠（孤立代理码元原样）。
pub fn dart_lower_code_point(cp: u32) -> u32 {
    if cp <= 0xFFFF {
        return u32::from(bmp_lower_table()[cp as usize]);
    }
    match DART_LOWER_PAIRS.binary_search_by_key(&cp, |&(from, _)| from) {
        Ok(index) => DART_LOWER_PAIRS[index].1,
        Err(_) => cp,
    }
}

/// 把 UTF-16 码元按 Dart `String.toLowerCase` 折叠进 [out]（先清空）。长度不变：表保证
/// BMP 内外不交叉。代理对按码点折叠，孤立代理原样。
pub fn dart_lower_utf16_into(units: &[u16], out: &mut Vec<u16>) {
    out.clear();
    out.reserve(units.len());
    // 快路径（媒体名几乎全是 ASCII，笔记正文几乎没有代理对）：整段先判一遍，命中就整段
    // 无分支地映射——逐码元判代理再 push 的慢路径在 900 万码元上要 50 ms 以上。
    if units.iter().all(|&u| u < 0x80) {
        // Dart 对 ASCII 只折 A–Z（与表一致，见 ascii_fast_path_matches_table）。
        out.extend(
            units
                .iter()
                .map(|&u| u | (u16::from(u.wrapping_sub(b'A' as u16) < 26) << 5)),
        );
        return;
    }
    let table = bmp_lower_table();
    if !units.iter().any(|&u| (0xD800..=0xDFFF).contains(&u)) {
        out.extend(units.iter().map(|&u| table[u as usize]));
        return;
    }
    let len = units.len();
    let mut i = 0;
    while i < len {
        let unit = units[i];
        if (0xD800..=0xDBFF).contains(&unit) && i + 1 < len {
            let low = units[i + 1];
            if (0xDC00..=0xDFFF).contains(&low) {
                let cp = 0x10000 + ((u32::from(unit) - 0xD800) << 10) + (u32::from(low) - 0xDC00);
                let lower = dart_lower_code_point(cp) - 0x10000;
                out.push(0xD800 + (lower >> 10) as u16);
                out.push(0xDC00 + (lower & 0x3FF) as u16);
                i += 2;
                continue;
            }
        }
        if (0xD800..=0xDFFF).contains(&unit) {
            out.push(unit);
        } else {
            out.push(table[unit as usize]);
        }
        i += 1;
    }
}

/// 切片哈希（只用于本模块的开放寻址表；查表键很短，按 4 个码元一组乘法混合）。
fn hash_units(units: &[u16]) -> u64 {
    const K: u64 = 0x9E37_79B9_7F4A_7C15;
    let mut h = (units.len() as u64).wrapping_mul(K);
    let mut chunks = units.chunks_exact(4);
    for c in &mut chunks {
        let w = u64::from(c[0])
            | (u64::from(c[1]) << 16)
            | (u64::from(c[2]) << 32)
            | (u64::from(c[3]) << 48);
        h = (h ^ w).wrapping_mul(K).rotate_left(29);
    }
    let mut w = 0u64;
    for (i, &u) in chunks.remainder().iter().enumerate() {
        w |= u64::from(u) << (16 * i);
    }
    h = (h ^ w).wrapping_mul(K);
    h ^= h >> 29;
    h = h.wrapping_mul(K);
    h ^ (h >> 32)
}

/// 开放寻址（线性探测）的「切片 → 编号」表：键本身存在调用方的连续缓冲区里
/// （`spans[id]` 是它在 `arena` 里的区间），表里只放编号，建表不为每个键单独分配。
///
/// 槽位 = `(哈希高 32 位 << 32) | (编号 + 1)`，0 = 空：探测时先比槽里的哈希片段，不同就不去
/// 碰 `spans` / `arena`（22 万键时那两处是随机访存，建表耗时主要花在这类缓存缺失上）。
struct SliceTable {
    slots: Vec<u64>,
    spans: Vec<(usize, usize)>,
}

impl SliceTable {
    fn with_capacity(keys: usize) -> Self {
        let slots = (keys.max(8) * 2).next_power_of_two();
        SliceTable {
            slots: vec![0; slots],
            spans: Vec::with_capacity(keys),
        }
    }

    fn len(&self) -> usize {
        self.spans.len()
    }

    #[inline]
    fn tag(hash: u64) -> u64 {
        hash & 0xFFFF_FFFF_0000_0000
    }

    fn find(&self, arena: &[u16], key: &[u16], hash: u64) -> Option<u32> {
        let mask = self.slots.len() - 1;
        let tag = Self::tag(hash);
        let mut at = hash as usize & mask;
        loop {
            let slot = self.slots[at];
            if slot == 0 {
                return None;
            }
            if slot & 0xFFFF_FFFF_0000_0000 == tag {
                let id = (slot as u32 - 1) as usize;
                let (start, len) = self.spans[id];
                if arena[start..start + len] == *key {
                    return Some(id as u32);
                }
            }
            at = (at + 1) & mask;
        }
    }

    /// 插入一个确定不在表里的键（区间指向 `arena`），返回新编号。
    fn insert_new(&mut self, arena: &[u16], span: (usize, usize), hash: u64) -> u32 {
        if (self.spans.len() + 1) * 2 > self.slots.len() {
            self.grow(arena);
        }
        let id = self.spans.len() as u32;
        self.spans.push(span);
        self.place(id, hash);
        id
    }

    fn place(&mut self, id: u32, hash: u64) {
        let mask = self.slots.len() - 1;
        let mut at = hash as usize & mask;
        while self.slots[at] != 0 {
            at = (at + 1) & mask;
        }
        self.slots[at] = Self::tag(hash) | u64::from(id + 1);
    }

    fn grow(&mut self, arena: &[u16]) {
        self.slots = vec![0; self.slots.len() * 2];
        for id in 0..self.spans.len() {
            let (start, len) = self.spans[id];
            self.place(id as u32, hash_units(&arena[start..start + len]));
        }
    }
}

/// 一组媒体文件名的匹配器（对应旧 `MediaNameMatcher` 的构造）。
///
/// 布局按「少分配」设计：不同的折叠名首尾相接放在一块 `arena` 里，查表只存编号；每个折叠名
/// 对应的原名下标是 CSR（`key_names[key_starts[k]..key_starts[k + 1]]`，插入序）。22 万个
/// 名字的建表只做几次大块分配，释放也只有几块（逐键 `Box` + `Vec` 的旧布局建表比 Dart 慢一倍）。
pub struct MediaNameMatcher {
    name_count: usize,
    arena: Vec<u16>,
    /// 折叠名 → 键编号（键编号 = 首次出现序）。
    keys: SliceTable,
    key_starts: Vec<u32>,
    key_names: Vec<u32>,
    /// （折叠后缀，含 `.`；出现过的长度，插入序去重）按首次出现排序。
    suffixes: Vec<(Box<[u16]>, Vec<usize>)>,
    /// 没有扩展名的折叠名（键编号），插入序。
    unanchored: Vec<u32>,
}

const DOT: u16 = b'.' as u16;
const NO_KEY: u32 = u32::MAX;

impl MediaNameMatcher {
    /// [names] 是原名的 UTF-16 码元（下标即交回调用方的名字下标）。
    pub fn new(names: &[&[u16]]) -> Self {
        let hint = names.len();
        // 折叠不改长度：不同名字的总码元数不超过全部名字的总码元数，一次预留到位。
        let mut arena: Vec<u16> = Vec::with_capacity(names.iter().map(|n| n.len()).sum());
        let mut keys = SliceTable::with_capacity(hint);
        let mut name_key: Vec<u32> = Vec::with_capacity(hint);
        let mut suffixes: Vec<(Box<[u16]>, Vec<usize>)> = Vec::new();
        // 后缀的查表键也在 `arena` 里（就是首个带它的键的尾段）；`seen_lengths[s]` 是长度位图。
        let mut suffix_table = SliceTable::with_capacity(8);
        let mut seen_lengths: Vec<Vec<u64>> = Vec::new();
        let mut unanchored: Vec<u32> = Vec::new();
        let mut lower = Vec::new();
        for &name in names {
            dart_lower_utf16_into(name, &mut lower);
            if lower.is_empty() {
                name_key.push(NO_KEY);
                continue;
            }
            let hash = hash_units(&lower);
            if let Some(id) = keys.find(&arena, &lower, hash) {
                // 同一折叠名再出现：后缀与长度都已记过，只多一个原名下标。
                name_key.push(id);
                continue;
            }
            let start = arena.len();
            arena.extend_from_slice(&lower);
            let id = keys.insert_new(&arena, (start, lower.len()), hash);
            name_key.push(id);
            match lower.iter().rposition(|&u| u == DOT) {
                None => unanchored.push(id),
                Some(dot) => {
                    let suffix = &lower[dot..];
                    let suffix_hash = hash_units(suffix);
                    let slot = match suffix_table.find(&arena, suffix, suffix_hash) {
                        Some(slot) => slot as usize,
                        None => {
                            suffix_table.insert_new(
                                &arena,
                                (start + dot, suffix.len()),
                                suffix_hash,
                            );
                            suffixes.push((suffix.into(), Vec::new()));
                            seen_lengths.push(Vec::new());
                            suffixes.len() - 1
                        }
                    };
                    let length = lower.len();
                    let bits = &mut seen_lengths[slot];
                    let word = length / 64;
                    if bits.len() <= word {
                        bits.resize(word + 1, 0);
                    }
                    let mask = 1u64 << (length % 64);
                    if bits[word] & mask == 0 {
                        bits[word] |= mask;
                        suffixes[slot].1.push(length);
                    }
                }
            }
        }
        // CSR：每个键的原名下标，按名字下标升序（= 插入序）。
        let key_count = keys.len();
        let mut key_starts = vec![0u32; key_count + 1];
        for &id in name_key.iter() {
            if id != NO_KEY {
                key_starts[id as usize + 1] += 1;
            }
        }
        for k in 0..key_count {
            key_starts[k + 1] += key_starts[k];
        }
        let mut fill: Vec<u32> = key_starts[..key_count].to_vec();
        let mut key_names = vec![0u32; key_starts[key_count] as usize];
        for (index, &id) in name_key.iter().enumerate() {
            if id != NO_KEY {
                let at = &mut fill[id as usize];
                key_names[*at as usize] = index as u32;
                *at += 1;
            }
        }
        MediaNameMatcher {
            name_count: name_key.len(),
            arena,
            keys,
            key_starts,
            key_names,
            suffixes,
            unanchored,
        }
    }

    pub fn name_count(&self) -> usize {
        self.name_count
    }

    fn key_of(&self, lowered: &[u16]) -> Option<u32> {
        self.keys.find(&self.arena, lowered, hash_units(lowered))
    }

    fn names_of(&self, key: u32) -> &[u32] {
        let k = key as usize;
        &self.key_names[self.key_starts[k] as usize..self.key_starts[k + 1] as usize]
    }

    fn key_units(&self, key: u32) -> &[u16] {
        let (start, len) = self.keys.spans[key as usize];
        &self.arena[start..start + len]
    }
}

/// 扫描时的复用暂存区。
pub struct Scan<'m> {
    matcher: &'m MediaNameMatcher,
    lower: Vec<u16>,
    dots: Vec<usize>,
    /// 每个名字下标最后一次被记入的组号 + 1（组内去重）。
    stamp: Vec<u32>,
    group: u32,
}

impl<'m> Scan<'m> {
    pub fn new(matcher: &'m MediaNameMatcher) -> Self {
        Scan {
            matcher,
            lower: Vec::new(),
            dots: Vec::new(),
            stamp: vec![0; matcher.name_count],
            group: 0,
        }
    }

    /// 开始新的一组（命中去重的范围）。
    pub fn begin_group(&mut self) {
        self.group += 1;
    }

    fn hit(stamp: &mut [u32], group: u32, indices: &[u32], out: &mut Vec<u32>) {
        for &index in indices {
            let slot = &mut stamp[index as usize];
            if *slot != group {
                *slot = group;
                out.push(index);
            }
        }
    }

    /// 把 [text] 里出现的名字下标按旧实现的顺序追加进 [out]（本组内去重）。
    pub fn names_in(&mut self, text: &[u16], out: &mut Vec<u32>) {
        if text.is_empty() {
            return;
        }
        let matcher = self.matcher;
        let group = self.group;
        dart_lower_utf16_into(text, &mut self.lower);
        let lower = &self.lower;
        self.dots.clear();
        self.dots.extend(
            lower
                .iter()
                .enumerate()
                .filter(|(_, &u)| u == DOT)
                .map(|(i, _)| i),
        );
        for (suffix, lengths) in matcher.suffixes.iter() {
            // 后缀都以 `.` 开头：出现处必落在某个 `.` 上，按升序过一遍 = 旧实现的
            // `indexOf(suffix, at + 1)` 循环（允许重叠）。
            for &at in self.dots.iter() {
                let end = at + suffix.len();
                if end > lower.len() || lower[at..end] != **suffix {
                    continue;
                }
                for &length in lengths.iter() {
                    if length > end {
                        continue;
                    }
                    if let Some(key) = matcher.key_of(&lower[end - length..end]) {
                        Self::hit(&mut self.stamp, group, matcher.names_of(key), out);
                    }
                }
            }
        }
        for &key in matcher.unanchored.iter() {
            if contains(lower, matcher.key_units(key)) {
                Self::hit(&mut self.stamp, group, matcher.names_of(key), out);
            }
        }
    }
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
    (0..=last_start).any(|i| haystack[i] == first && haystack[i..i + needle.len()] == *needle)
}

/// 读 `offsets[0..=count]` 描述的第 [i] 段（越界 / 非单调返回 None）。
fn segment<'a>(units: &'a [u16], offsets: &[u64], i: usize) -> Option<&'a [u16]> {
    let start = usize::try_from(offsets[i]).ok()?;
    let end = usize::try_from(offsets[i + 1]).ok()?;
    if start > end || end > units.len() {
        return None;
    }
    Some(&units[start..end])
}

unsafe fn slice_or_empty<'a, T>(ptr: *const T, len: usize) -> &'a [T] {
    if len == 0 {
        &[]
    } else {
        std::slice::from_raw_parts(ptr, len)
    }
}

/// 建匹配器。名字 `i` = `units[offsets[i]..offsets[i + 1]]`（UTF-16 码元）；`offsets` 有
/// `count + 1` 项。成功写 `*out` 并返回 OK；用 [ffc_parse_anki_matcher_free] 释放。
///
/// # Safety
/// `units` 可读 `units_len` 个 u16（`units_len == 0` 时可空）；`offsets` 可读 `count + 1`
/// 个 u64；`out` 可写。
#[no_mangle]
pub unsafe extern "C" fn ffc_parse_anki_matcher_new(
    units: *const u16,
    units_len: usize,
    offsets: *const u64,
    count: usize,
    out: *mut *mut MediaNameMatcher,
) -> i32 {
    if out.is_null() || offsets.is_null() || (units_len > 0 && units.is_null()) {
        return status::NULL_ARGUMENT;
    }
    if count >= u32::MAX as usize {
        return status::INVALID_ARGUMENT;
    }
    guard(|| {
        let units = slice_or_empty(units, units_len);
        let offsets = std::slice::from_raw_parts(offsets, count + 1);
        let mut names = Vec::with_capacity(count);
        for i in 0..count {
            match segment(units, offsets, i) {
                Some(name) => names.push(name),
                None => return status::INVALID_ARGUMENT,
            }
        }
        *out = Box::into_raw(Box::new(MediaNameMatcher::new(&names)));
        status::OK
    })
}

/// 释放 [ffc_parse_anki_matcher_new] 建的匹配器（空指针无操作）。
///
/// # Safety
/// `matcher` 必须来自 [ffc_parse_anki_matcher_new] 且只释放一次。
#[no_mangle]
pub unsafe extern "C" fn ffc_parse_anki_matcher_free(matcher: *mut MediaNameMatcher) {
    if !matcher.is_null() {
        drop(Box::from_raw(matcher));
    }
}

/// 批量扫描：正文 `j` = `units[text_offsets[j]..text_offsets[j + 1]]`（`text_count + 1` 项），
/// 组 `g` = 正文 `group_offsets[g]..group_offsets[g + 1]`（`group_count + 1` 项，单调、
/// 末项 = `text_count`）。组内各正文的命中取并集（首次出现序）。
///
/// 输出（Rust 分配，[crate::ffc_free_bytes] 释放）是小端 u32 序列：先 `group_count + 1` 个
/// 组起点（下标指向其后的命中区，末项 = 命中总数），再是命中的名字下标。
///
/// # Safety
/// 各指针按上面的长度可读（长度为 0 的可空）；`out_ptr` / `out_len` 可写。
#[no_mangle]
pub unsafe extern "C" fn ffc_parse_anki_names_in(
    matcher: *const MediaNameMatcher,
    units: *const u16,
    units_len: usize,
    text_offsets: *const u64,
    text_count: usize,
    group_offsets: *const u64,
    group_count: usize,
    out_ptr: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    if matcher.is_null()
        || text_offsets.is_null()
        || group_offsets.is_null()
        || out_ptr.is_null()
        || out_len.is_null()
        || (units_len > 0 && units.is_null())
    {
        return status::NULL_ARGUMENT;
    }
    guard(|| {
        let matcher = &*matcher;
        let units = slice_or_empty(units, units_len);
        let text_offsets = std::slice::from_raw_parts(text_offsets, text_count + 1);
        let group_offsets = std::slice::from_raw_parts(group_offsets, group_count + 1);
        if group_offsets[group_count] != text_count as u64 {
            return status::INVALID_ARGUMENT;
        }
        let mut scan = Scan::new(matcher);
        let mut starts: Vec<u32> = Vec::with_capacity(group_count + 1);
        let mut hits: Vec<u32> = Vec::new();
        for g in 0..group_count {
            let (Ok(first), Ok(last)) = (
                usize::try_from(group_offsets[g]),
                usize::try_from(group_offsets[g + 1]),
            ) else {
                return status::INVALID_ARGUMENT;
            };
            if first > last || last > text_count {
                return status::INVALID_ARGUMENT;
            }
            starts.push(hits.len() as u32);
            scan.begin_group();
            for j in first..last {
                match segment(units, text_offsets, j) {
                    Some(text) => scan.names_in(text, &mut hits),
                    None => return status::INVALID_ARGUMENT,
                }
            }
        }
        starts.push(hits.len() as u32);
        let mut bytes = Vec::with_capacity((starts.len() + hits.len()) * 4);
        for value in starts.iter().chain(hits.iter()) {
            bytes.extend_from_slice(&value.to_le_bytes());
        }
        hand_over_bytes(bytes, out_ptr, out_len);
        status::OK
    })
}

/// 把 `units[0..len]` 按 Dart `toLowerCase` 原地折叠（长度不变）。供绑定的口径自检用。
///
/// # Safety
/// `len > 0` 时 `units` 可读写 `len` 个 u16。
#[no_mangle]
pub unsafe extern "C" fn ffc_parse_anki_lower_utf16(units: *mut u16, len: usize) -> i32 {
    if len > 0 && units.is_null() {
        return status::NULL_ARGUMENT;
    }
    guard(|| {
        if len == 0 {
            return status::OK;
        }
        let slice = std::slice::from_raw_parts_mut(units, len);
        let mut lower = Vec::new();
        dart_lower_utf16_into(slice, &mut lower);
        slice.copy_from_slice(&lower);
        status::OK
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn u(s: &str) -> Vec<u16> {
        s.encode_utf16().collect()
    }

    fn names_in(names: &[&str], text: &str) -> Vec<String> {
        let encoded: Vec<Vec<u16>> = names.iter().map(|n| u(n)).collect();
        let slices: Vec<&[u16]> = encoded.iter().map(|v| v.as_slice()).collect();
        let matcher = MediaNameMatcher::new(&slices);
        let mut scan = Scan::new(&matcher);
        scan.begin_group();
        let mut out = Vec::new();
        scan.names_in(&u(text), &mut out);
        out.iter().map(|&i| names[i as usize].to_string()).collect()
    }

    #[test]
    fn lower_table_matches_generator_digest() {
        let mut hash: u32 = 0x811c9dc5;
        for cp in 0..0x110000u32 {
            let lower = if (0xD800..=0xDFFF).contains(&cp) {
                cp
            } else {
                dart_lower_code_point(cp)
            };
            for b in lower.to_le_bytes() {
                hash ^= u32::from(b);
                hash = hash.wrapping_mul(0x01000193);
            }
        }
        assert_eq!(hash, dart_lower_table::DART_LOWER_TABLE_FNV1A);
    }

    #[test]
    fn dart_lowercase_is_simple_and_context_free() {
        let mut out = Vec::new();
        dart_lower_utf16_into(&u("ΣΑΣ İ ẞ ǅ \u{10400}"), &mut out);
        assert_eq!(String::from_utf16(&out).unwrap(), "σασ i ß ǆ \u{10428}");
        dart_lower_utf16_into(&[0x41, 0xD801, 0x42, 0xDC00], &mut out);
        assert_eq!(out, vec![0x61, 0xD801, 0x62, 0xDC00]);
    }

    #[test]
    fn ascii_fast_path_matches_table() {
        let table = bmp_lower_table();
        let ascii: Vec<u16> = (0u16..0x80).collect();
        let mut out = Vec::new();
        dart_lower_utf16_into(&ascii, &mut out);
        let expected: Vec<u16> = ascii.iter().map(|&u| table[u as usize]).collect();
        assert_eq!(out, expected);
        // 整个 BMP（不含代理）走表快路径，混入一个代理对走慢路径：逐码元结果相同。
        let bmp: Vec<u16> = (0u16..=0xFFFF)
            .filter(|u| !(0xD800..=0xDFFF).contains(u))
            .collect();
        dart_lower_utf16_into(&bmp, &mut out);
        let fast = out.clone();
        let mut mixed = bmp.clone();
        mixed.extend([0xD801, 0xDC00]);
        dart_lower_utf16_into(&mixed, &mut out);
        assert_eq!(&out[..bmp.len()], fast.as_slice());
        assert_eq!(&out[bmp.len()..], &[0xD801, 0xDC28]);
        let expected: Vec<u16> = bmp.iter().map(|&u| table[u as usize]).collect();
        assert_eq!(fast, expected);
    }

    #[test]
    fn matches_like_the_old_dart_matcher() {
        assert_eq!(
            names_in(&["a.mp3", "Pic.PNG"], "[sound:A.MP3] <img src=\"pic.png\">"),
            vec!["a.mp3", "Pic.PNG"]
        );
        assert_eq!(names_in(&["a.mp3"], "[sound:ba.mp3x]"), vec!["a.mp3"]);
        assert!(names_in(&["a.mp3", "Pic.PNG"], "a.mp4 pic.pn").is_empty());
        assert_eq!(
            names_in(
                &["Dup.jpg", "dup.jpg", "noext", "a.b.mp3"],
                "DUP.JPG a.b.mp3 xx NOEXT"
            ),
            vec!["Dup.jpg", "dup.jpg", "a.b.mp3", "noext"]
        );
        assert!(names_in(&["a.mp3"], "").is_empty());
        assert!(names_in(&[""], "anything").is_empty());
    }

    #[test]
    fn ffi_batch_layout() {
        let names = ["a.mp3", "b.jpg"];
        let mut units = Vec::new();
        let mut offsets = vec![0u64];
        for n in names {
            units.extend(u(n));
            offsets.push(units.len() as u64);
        }
        let mut matcher = std::ptr::null_mut();
        let rc = unsafe {
            ffc_parse_anki_matcher_new(
                units.as_ptr(),
                units.len(),
                offsets.as_ptr(),
                2,
                &mut matcher,
            )
        };
        assert_eq!(rc, status::OK);
        let texts = ["x b.jpg", "a.mp3", "", "B.JPG b.jpg"];
        let mut tu = Vec::new();
        let mut to = vec![0u64];
        for t in texts {
            tu.extend(u(t));
            to.push(tu.len() as u64);
        }
        let groups = [0u64, 2, 3, 4];
        let mut ptr = std::ptr::null_mut();
        let mut len = 0usize;
        let rc = unsafe {
            ffc_parse_anki_names_in(
                matcher,
                tu.as_ptr(),
                tu.len(),
                to.as_ptr(),
                4,
                groups.as_ptr(),
                3,
                &mut ptr,
                &mut len,
            )
        };
        assert_eq!(rc, status::OK);
        let bytes = unsafe { std::slice::from_raw_parts(ptr, len) };
        let words: Vec<u32> = bytes
            .chunks_exact(4)
            .map(|c| u32::from_le_bytes([c[0], c[1], c[2], c[3]]))
            .collect();
        assert_eq!(words, vec![0, 2, 2, 3, 1, 0, 1]);
        crate::ffc_free_bytes(ptr, len);
        let bad = [0u64, 5];
        let rc = unsafe {
            ffc_parse_anki_names_in(
                matcher,
                tu.as_ptr(),
                tu.len(),
                to.as_ptr(),
                4,
                bad.as_ptr(),
                1,
                &mut ptr,
                &mut len,
            )
        };
        assert_eq!(rc, status::INVALID_ARGUMENT);
        unsafe { ffc_parse_anki_matcher_free(matcher) };
    }
}
