//! Dart `String.toLowerCase()` 的唯一复刻（全 crate 共用：Anki 媒体扫描、字幕、标题打分 /
//! AniDB 目录、媒体文件名、弹幕、EPUB、html5lib）。
//!
//! 口径是 [table] 里**按 Dart SDK 逐码点冻结**的映射（生成器 `tool/gen_dart_lower_table.dart`，
//! 纪律见其文件头）：Dart VM 的 `toLowerCase` 是逐码点的简单映射，不看上下文（词尾 Σ 照样折成
//! σ），每个码点折成恰好一个码点、BMP 内外不交叉，所以 UTF-16 长度与下标都不变；孤立代理码元原样。
//!
//! **不要用 Rust 的 `char::to_lowercase` / `str::to_lowercase` 代替**：它是完整映射（U+0130 →
//! `i` + U+0307，词尾 σ → ς），Unicode 版本也比 Dart VM 的表新——冻结表里原样保留、而 Rust 会
//! 折叠的码点有 465 个（切罗基文、格鲁吉亚 Mtavruli、拉丁扩展-D 新增字母等，见
//! `rust_std_differs_only_where_dart_keeps_the_code_point` 测试）。

use std::sync::OnceLock;

// 生成文件按生成器原样入库（`--check` 逐字比对），不让 rustfmt 重排。
#[rustfmt::skip]
mod table;

use table::DART_LOWER_PAIRS;

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

/// 码点按 Dart `toLowerCase` 折叠（代理码元原样）。
#[inline]
pub fn dart_lower_code_point(cp: u32) -> u32 {
    if cp < 0x80 {
        return if (0x41..=0x5A).contains(&cp) {
            cp + 0x20
        } else {
            cp
        };
    }
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
    let table = bmp_lower_table();
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

/// `String.toLowerCase()`（UTF-16 进、UTF-16 出，长度不变）。
pub fn dart_lower_utf16(units: &[u16]) -> Vec<u16> {
    let mut out = Vec::new();
    dart_lower_utf16_into(units, &mut out);
    out
}

/// `String.toLowerCase()`，输入输出为 Rust `str`（合法 UTF-8 不含孤立代理，按码点查表）。
pub fn dart_lower_str(s: &str) -> String {
    if s.is_ascii() {
        return s.to_ascii_lowercase();
    }
    s.chars()
        .map(|c| {
            // 表的码点都是合法标量值（生成器断言不跨 BMP、代理码元不入表）。
            char::from_u32(dart_lower_code_point(c as u32)).unwrap_or(c)
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn u(s: &str) -> Vec<u16> {
        s.encode_utf16().collect()
    }

    #[test]
    fn table_matches_generator_digest() {
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
        assert_eq!(hash, table::DART_LOWER_TABLE_FNV1A);
    }

    #[test]
    fn dart_lowercase_is_simple_and_context_free() {
        assert_eq!(
            String::from_utf16(&dart_lower_utf16(&u("ΣΑΣ İ ẞ ǅ \u{212A} \u{10400}"))).unwrap(),
            "σασ i ß ǆ k \u{10428}"
        );
        assert_eq!(
            dart_lower_utf16(&[0x41, 0xD801, 0x42, 0xDC00]),
            vec![0x61, 0xD801, 0x62, 0xDC00]
        );
        assert_eq!(dart_lower_str("ΣΑΣ İMG ẞ \u{10400}"), "σασ img ß \u{10428}");
        assert_eq!(dart_lower_str("SCRIPT"), "script");
    }

    /// 只有 `A`–`Z`、U+0130 与 U+212A 折成 ASCII（弹幕 `lower_eq_ascii_keyword` 依赖这一点）。
    #[test]
    fn only_three_sources_lower_into_ascii() {
        let into_ascii: Vec<u32> = (0x80..0x110000u32)
            .filter(|&cp| dart_lower_code_point(cp) < 0x80)
            .collect();
        assert_eq!(into_ascii, vec![0x130, 0x212A]);
    }

    /// 冻结表与 Rust 标准库（单码点结果、U+0130 按 Dart 取 `i`）的差异只有一种：Dart 原样保留、
    /// Rust 折成另一个非 ASCII 字母。条数随 Rust 的 Unicode 版本变，这里只钉形态与当前工具链下的下限。
    #[test]
    fn rust_std_differs_only_where_dart_keeps_the_code_point() {
        let mut differ = 0;
        for cp in 0..0x110000u32 {
            let Some(c) = char::from_u32(cp) else {
                continue;
            };
            let rust = if c == '\u{130}' {
                'i'
            } else {
                let mut lower = c.to_lowercase();
                match (lower.next(), lower.next()) {
                    (Some(single), None) => single,
                    _ => c,
                }
            };
            let dart = dart_lower_code_point(cp);
            if dart != rust as u32 {
                assert_eq!(dart, cp, "U+{cp:04X}: Dart folds differently from Rust");
                assert!(cp >= 0x80 && (rust as u32) >= 0x80, "U+{cp:04X}");
                assert!(c.is_alphabetic() && rust.is_alphabetic(), "U+{cp:04X}");
                differ += 1;
            }
        }
        assert!(differ >= 465, "{differ}");
    }
}
