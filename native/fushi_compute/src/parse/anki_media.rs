//! `ffc_parse_anki_*`：Anki 媒体去重的「笔记字段里出现了哪些媒体文件名」扫描。
//!
//! 口径来自原 Dart `MediaNameMatcher`（packages/fushi_anki/lib/src/anki_media_dedup.dart，
//! 已删除，回归向量见 packages/fushi_compute/test/anki_media_test.dart）：与 Anki 的
//! `findNotes "<文件名>"` 对齐——**大小写不敏感的朴素子串**，不判文件名边界。
//!
//! 做法（与旧实现逐步一致，含命中顺序）：
//! - 名字与正文都按 Dart `toLowerCase` 逐码点折叠（全 crate 共用的 [super::dart_lower]），
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

use std::collections::HashMap;
use std::hash::{BuildHasherDefault, Hasher};

use crate::{guard, hand_over_bytes, status};

use super::dart_lower::dart_lower_utf16_into;

/// FNV-1a over u16（查表键很短，SipHash 的抗碰撞开销不值）。
#[derive(Default)]
struct Fnv(u64);

impl Hasher for Fnv {
    fn finish(&self) -> u64 {
        self.0
    }

    fn write(&mut self, bytes: &[u8]) {
        let mut hash = if self.0 == 0 {
            0xcbf29ce484222325
        } else {
            self.0
        };
        for &b in bytes {
            hash ^= u64::from(b);
            hash = hash.wrapping_mul(0x100000001b3);
        }
        self.0 = hash;
    }
}

type FnvMap<K, V> = HashMap<K, V, BuildHasherDefault<Fnv>>;

/// 一组媒体文件名的匹配器（对应旧 `MediaNameMatcher` 的构造）。
pub struct MediaNameMatcher {
    name_count: usize,
    /// 折叠名 → 原名下标（插入序）。
    by_lower: FnvMap<Box<[u16]>, Vec<u32>>,
    /// （折叠后缀，含 `.`；出现过的长度，插入序去重）按首次出现排序。
    suffixes: Vec<(Box<[u16]>, Vec<usize>)>,
    /// 没有扩展名的折叠名，插入序去重。
    unanchored: Vec<Box<[u16]>>,
}

const DOT: u16 = b'.' as u16;

impl MediaNameMatcher {
    /// [names] 是原名的 UTF-16 码元（下标即交回调用方的名字下标）。
    pub fn new<'a>(names: impl IntoIterator<Item = &'a [u16]>) -> Self {
        let mut matcher = MediaNameMatcher {
            name_count: 0,
            by_lower: FnvMap::default(),
            suffixes: Vec::new(),
            unanchored: Vec::new(),
        };
        let mut suffix_slot: FnvMap<Box<[u16]>, usize> = FnvMap::default();
        let mut lower = Vec::new();
        for (index, name) in names.into_iter().enumerate() {
            matcher.name_count = index + 1;
            dart_lower_utf16_into(name, &mut lower);
            if lower.is_empty() {
                continue;
            }
            let key: Box<[u16]> = lower.as_slice().into();
            let fresh = !matcher.by_lower.contains_key(&key);
            matcher
                .by_lower
                .entry(key.clone())
                .or_default()
                .push(index as u32);
            match lower.iter().rposition(|&u| u == DOT) {
                None => {
                    if fresh {
                        matcher.unanchored.push(key);
                    }
                }
                Some(dot) => {
                    let suffix: Box<[u16]> = lower[dot..].into();
                    let slot = match suffix_slot.get(&suffix) {
                        Some(&slot) => slot,
                        None => {
                            matcher.suffixes.push((suffix.clone(), Vec::new()));
                            suffix_slot.insert(suffix, matcher.suffixes.len() - 1);
                            matcher.suffixes.len() - 1
                        }
                    };
                    let lengths = &mut matcher.suffixes[slot].1;
                    if !lengths.contains(&lower.len()) {
                        lengths.push(lower.len());
                    }
                }
            }
        }
        matcher
    }

    pub fn name_count(&self) -> usize {
        self.name_count
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

    fn hit(&mut self, indices: &[u32], out: &mut Vec<u32>) {
        for &index in indices {
            let slot = &mut self.stamp[index as usize];
            if *slot != self.group {
                *slot = self.group;
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
        let mut lower = std::mem::take(&mut self.lower);
        dart_lower_utf16_into(text, &mut lower);
        self.dots.clear();
        self.dots.extend(
            lower
                .iter()
                .enumerate()
                .filter(|(_, &u)| u == DOT)
                .map(|(i, _)| i),
        );
        let dots = std::mem::take(&mut self.dots);
        for (suffix, lengths) in matcher.suffixes.iter() {
            // 后缀都以 `.` 开头：出现处必落在某个 `.` 上，按升序过一遍 = 旧实现的
            // `indexOf(suffix, at + 1)` 循环（允许重叠）。
            for &at in dots.iter() {
                let end = at + suffix.len();
                if end > lower.len() || lower[at..end] != **suffix {
                    continue;
                }
                for &length in lengths.iter() {
                    if length > end {
                        continue;
                    }
                    if let Some(indices) = matcher.by_lower.get(&lower[end - length..end]) {
                        self.hit(indices, out);
                    }
                }
            }
        }
        for name in matcher.unanchored.iter() {
            if contains(&lower, name) {
                let indices = &matcher.by_lower[name];
                self.hit(indices, out);
            }
        }
        self.dots = dots;
        self.lower = lower;
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
        *out = Box::into_raw(Box::new(MediaNameMatcher::new(names)));
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
        let matcher = MediaNameMatcher::new(encoded.iter().map(|v| v.as_slice()));
        let mut scan = Scan::new(&matcher);
        scan.begin_group();
        let mut out = Vec::new();
        scan.names_in(&u(text), &mut out);
        out.iter().map(|&i| names[i as usize].to_string()).collect()
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
