//! `ffc_parse_*`：解析 / 计数类内核。
//!
//! 目前只有学习统计「字数」口径（Dart 侧 `countStudyChars` / `StudyCharCounter`，
//! packages/fushi_engine/lib/stats/study_char_count.dart）。这是 EPUB 导入、开书补算、
//! 插图索引、目录锚点偏移等整条链路里最重的一段：原 Dart 实现逐码点
//! `String.fromCharCode` + 三次 Unicode 属性正则，十几万字的一本书要数百毫秒到数秒，
//! 比 `package:html` 建 DOM 本身还慢一个量级。
//!
//! 口径：逐码点查 [study_char_table]（由 `tool/gen_study_char_table.dart` 从规则生成，
//! **运行时只有这一份实现**）。四类见 [StudyCharClass]。
//!
//! 输入是 UTF-16 码元（Dart `String` 的原生表示，免一次 UTF-8 编码），解码规则与 Dart
//! `String.runes` 一致：合法代理对合成一个码点，孤立代理按其码元值本身查表（落第 0 类）。

use std::sync::OnceLock;

use crate::{guard, status};

pub mod epub;
pub mod html5lib;
pub mod sanitize;
mod study_char_table;

use study_char_table::STUDY_CHAR_RANGES;

/// 码点的字数分类（值与 Dart 侧 `StudyCharClass` 一致）。
#[repr(u8)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum StudyCharClass {
    /// 断词且不计：标点 / 括号 / 空白 / 符号 / 未分配。
    Breaker = 0,
    /// 透明：组合记号、ZWNJ / ZWJ、词内撇号——不计数也不断词。
    Transparent = 1,
    /// 每码点计 1：汉字 / 假名 / 谚文等不用空格分词的文字。
    PerCodePoint = 2,
    /// 连续串计 1：拉丁 / 西里尔等用空格分词的字母数字。
    Word = 3,
}

/// BMP 直查表（64 KiB，首次使用时由区间表展开）；BMP 外走二分。
fn bmp_table() -> &'static [u8; 0x10000] {
    static TABLE: OnceLock<Box<[u8; 0x10000]>> = OnceLock::new();
    TABLE.get_or_init(|| {
        let mut table = Box::new([0u8; 0x10000]);
        for &(start, end, class) in STUDY_CHAR_RANGES.iter() {
            if start > 0xFFFF {
                break;
            }
            for cp in start..=end.min(0xFFFF) {
                table[cp as usize] = class;
            }
        }
        table
    })
}

fn class_byte(cp: u32) -> u8 {
    if cp <= 0xFFFF {
        return bmp_table()[cp as usize];
    }
    match STUDY_CHAR_RANGES.binary_search_by(|&(start, end, _)| {
        if end < cp {
            std::cmp::Ordering::Less
        } else if start > cp {
            std::cmp::Ordering::Greater
        } else {
            std::cmp::Ordering::Equal
        }
    }) {
        Ok(index) => STUDY_CHAR_RANGES[index].2,
        Err(_) => 0,
    }
}

/// 码点 [cp] 的分类；超出 Unicode 范围按第 0 类。
pub fn study_char_class(cp: u32) -> StudyCharClass {
    match class_byte(cp) {
        1 => StudyCharClass::Transparent,
        2 => StudyCharClass::PerCodePoint,
        3 => StudyCharClass::Word,
        _ => StudyCharClass::Breaker,
    }
}

/// 可续算的计数状态（与 Dart `StudyCharCounter` 同语义）：`count` 是已收尾的单位数，
/// `in_word` 表示末尾有一个尚未收尾的连续词串（读数时按 1 计）。
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct StudyCharState {
    pub count: u64,
    pub in_word: bool,
}

impl StudyCharState {
    /// 目前为止的单位数（未收尾的词串按 1 计）。
    pub fn total(&self) -> u64 {
        self.count + u64::from(self.in_word)
    }

    fn push(&mut self, cp: u32) {
        match class_byte(cp) {
            1 => {}
            2 => {
                if self.in_word {
                    self.count += 1;
                    self.in_word = false;
                }
                self.count += 1;
            }
            3 => self.in_word = true,
            _ => {
                if self.in_word {
                    self.count += 1;
                    self.in_word = false;
                }
            }
        }
    }

    /// 接着已加入的文本继续数 [units]（UTF-16，解码规则见模块注释）。
    pub fn add_utf16(&mut self, units: &[u16]) {
        let mut i = 0;
        let len = units.len();
        while i < len {
            let unit = units[i] as u32;
            if (0xD800..=0xDBFF).contains(&unit) && i + 1 < len {
                let low = units[i + 1] as u32;
                if (0xDC00..=0xDFFF).contains(&low) {
                    self.push(0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00));
                    i += 2;
                    continue;
                }
            }
            self.push(unit);
            i += 1;
        }
    }
}

/// 一段 UTF-16 文本的学习单位数（纯函数）。
pub fn count_study_chars_utf16(units: &[u16]) -> u64 {
    let mut state = StudyCharState::default();
    state.add_utf16(units);
    state.total()
}

/// 码点分类（0..=3，见 [StudyCharClass]）。纯查表，不会失败。
#[no_mangle]
pub extern "C" fn ffc_parse_study_char_class(cp: u32) -> u8 {
    class_byte(cp)
}

/// 续算计数：从 `*count` / `*in_word`（0 或 1）出发数 `units[0..len]`，写回新状态。
/// `len == 0` 时 `units` 可为空。
///
/// # Safety
/// `count` / `in_word` 必须非空可读写；`len > 0` 时 `units` 指向 `len` 个可读 `u16`。
#[no_mangle]
pub unsafe extern "C" fn ffc_parse_study_chars_utf16(
    units: *const u16,
    len: usize,
    count: *mut u64,
    in_word: *mut u8,
) -> i32 {
    if count.is_null() || in_word.is_null() || (len > 0 && units.is_null()) {
        return status::NULL_ARGUMENT;
    }
    guard(|| {
        let slice: &[u16] = if len == 0 {
            &[]
        } else {
            std::slice::from_raw_parts(units, len)
        };
        let mut state = StudyCharState {
            count: *count,
            in_word: *in_word != 0,
        };
        state.add_utf16(slice);
        *count = state.count;
        *in_word = u8::from(state.in_word);
        status::OK
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn count(s: &str) -> u64 {
        let units: Vec<u16> = s.encode_utf16().collect();
        count_study_chars_utf16(&units)
    }

    #[test]
    fn table_is_sorted_and_disjoint() {
        let mut previous_end: Option<u32> = None;
        for &(start, end, class) in STUDY_CHAR_RANGES.iter() {
            assert!(start <= end);
            assert!((1..=3).contains(&class));
            if let Some(prev) = previous_end {
                assert!(start > prev, "overlap at {start:#X}");
            }
            previous_end = Some(end);
        }
        assert!(previous_end.unwrap() <= 0x10FFFF);
    }

    #[test]
    fn table_matches_generator_digest() {
        let mut hash: u32 = 0x811c9dc5;
        for cp in 0..0x110000u32 {
            hash ^= u32::from(class_byte(cp));
            hash = hash.wrapping_mul(0x01000193);
        }
        assert_eq!(hash, study_char_table::STUDY_CHAR_TABLE_FNV1A);
    }

    #[test]
    fn caliber_samples() {
        // 与 Dart 侧 study_char_count_test 同口径的代表样本。
        assert_eq!(count(""), 0);
        assert_eq!(count("「こんにちは」"), 5);
        assert_eq!(count("I don't know"), 3);
        assert_eq!(count("café"), 1);
        assert_eq!(count("rock 'n' roll"), 3);
        assert_eq!(count("〇一二"), 3);
        assert_eq!(count("ラーメン々"), 5);
        assert_eq!(count("abc漢字def"), 4);
        assert_eq!(count("𠮷野家"), 3); // 补充平面汉字是一个码点
        assert_eq!(count("１２３ＡＢＣ"), 1);
    }

    #[test]
    fn lone_surrogates_break_words() {
        let units = [b'a' as u16, 0xD800, b'b' as u16, 0xDC00, b'c' as u16];
        assert_eq!(count_study_chars_utf16(&units), 3);
    }

    #[test]
    fn resumable_state_matches_concatenation() {
        let mut state = StudyCharState::default();
        for part in ["ab", "cd", " ", "漢", "e"] {
            let units: Vec<u16> = part.encode_utf16().collect();
            state.add_utf16(&units);
        }
        assert_eq!(state.total(), count("abcd 漢e"));
        assert_eq!(state.total(), 3);
    }

    #[test]
    fn ffi_entry_points() {
        let units: Vec<u16> = "ab 漢".encode_utf16().collect();
        let mut c = 0u64;
        let mut w = 0u8;
        let rc = unsafe { ffc_parse_study_chars_utf16(units.as_ptr(), units.len(), &mut c, &mut w) };
        assert_eq!(rc, status::OK);
        assert_eq!((c, w), (2, 0));
        let rc = unsafe { ffc_parse_study_chars_utf16(std::ptr::null(), 0, &mut c, &mut w) };
        assert_eq!(rc, status::OK);
        let rc = unsafe {
            ffc_parse_study_chars_utf16(std::ptr::null(), 3, &mut c, &mut w)
        };
        assert_eq!(rc, status::NULL_ARGUMENT);
        assert_eq!(ffc_parse_study_char_class('漢' as u32), 2);
        assert_eq!(ffc_parse_study_char_class(0x110000), 0);
    }
}
