//! 歌词文本解码：与 `packages/fushi_audio/lib/src/parsers/text_file_io.dart` 同一套判据、同一顺序
//! （回归向量 `tests/fixtures/lyrics/text_decode_vectors.txt` 由那份 Dart 实现生成）：
//!
//! 1. BOM：UTF-32LE / UTF-32BE 先于 UTF-16（`FF FE 00 00` 是 `FF FE` 的超集前缀）→ UTF-8 BOM
//!    （**严格**，字节不是 UTF-8 时不就地糊成 U+FFFD，继续往下判）→ UTF-16LE / BE；
//! 2. 无 BOM UTF-16 启发式：前 4096 字节里某一奇偶位 `0x00` 占比 > 30% 且另一位 < 5%；
//! 3. 严格 UTF-8；
//! 4. 传统多字节：Dart 侧这一步交给平台插件（桌面端缺失，降级成宽松 UTF-8）；Rust 侧用
//!    encoding_rs 按 Shift_JIS → GBK → Big5 取第一个零错误解码（与 `cue.rs` 同序）；
//! 5. 宽松 UTF-8 兜底。永远返回字符串、开头的 U+FEFF 剥掉。

use encoding_rs::{BIG5, GBK, SHIFT_JIS};

const HEURISTIC_SAMPLE_BYTES: usize = 4096;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UnicodeEncoding {
    Utf8Bom,
    Utf16LeBom,
    Utf16BeBom,
    Utf32LeBom,
    Utf32BeBom,
    Utf16LeBomless,
    Utf16BeBomless,
}

impl UnicodeEncoding {
    fn bom_len(self) -> usize {
        match self {
            UnicodeEncoding::Utf8Bom => 3,
            UnicodeEncoding::Utf16LeBom | UnicodeEncoding::Utf16BeBom => 2,
            UnicodeEncoding::Utf32LeBom | UnicodeEncoding::Utf32BeBom => 4,
            UnicodeEncoding::Utf16LeBomless | UnicodeEncoding::Utf16BeBomless => 0,
        }
    }
}

pub fn detect_bom(b: &[u8]) -> Option<UnicodeEncoding> {
    if b.len() >= 4 {
        if b[..4] == [0xFF, 0xFE, 0x00, 0x00] {
            return Some(UnicodeEncoding::Utf32LeBom);
        }
        if b[..4] == [0x00, 0x00, 0xFE, 0xFF] {
            return Some(UnicodeEncoding::Utf32BeBom);
        }
    }
    if b.len() >= 3 && b[..3] == [0xEF, 0xBB, 0xBF] {
        return Some(UnicodeEncoding::Utf8Bom);
    }
    if b.len() >= 2 {
        if b[..2] == [0xFF, 0xFE] {
            return Some(UnicodeEncoding::Utf16LeBom);
        }
        if b[..2] == [0xFE, 0xFF] {
            return Some(UnicodeEncoding::Utf16BeBom);
        }
    }
    None
}

pub fn detect_bomless_utf16(b: &[u8]) -> Option<UnicodeEncoding> {
    let limit = b.len().min(HEURISTIC_SAMPLE_BYTES);
    if limit < 4 || b.len() % 2 == 1 {
        return None;
    }
    let pairs = limit / 2;
    let (mut even, mut odd) = (0usize, 0usize);
    for i in (0..pairs * 2).step_by(2) {
        if b[i] == 0 {
            even += 1;
        }
        if b[i + 1] == 0 {
            odd += 1;
        }
    }
    let er = even as f64 / pairs as f64;
    let or = odd as f64 / pairs as f64;
    if or > 0.30 && er < 0.05 {
        return Some(UnicodeEncoding::Utf16LeBomless);
    }
    if er > 0.30 && or < 0.05 {
        return Some(UnicodeEncoding::Utf16BeBomless);
    }
    None
}

fn decode_utf16(b: &[u8], little: bool) -> String {
    let units: Vec<u16> = b
        .chunks_exact(2)
        .map(|c| {
            if little {
                u16::from_le_bytes([c[0], c[1]])
            } else {
                u16::from_be_bytes([c[0], c[1]])
            }
        })
        .collect();
    // Dart `String.fromCharCodes` 原样透传孤立代理；Rust String 存不了，换成 U+FFFD。
    String::from_utf16_lossy(&units)
}

fn decode_utf32(b: &[u8], little: bool) -> String {
    b.chunks_exact(4)
        .map(|c| {
            let v = if little {
                u32::from_le_bytes([c[0], c[1], c[2], c[3]])
            } else {
                u32::from_be_bytes([c[0], c[1], c[2], c[3]])
            };
            char::from_u32(v).unwrap_or('\u{FFFD}')
        })
        .collect()
}

/// Dart `decodeUnicodeText` 的同口径实现：不是 Unicode 家族时返回 None。
pub fn decode_unicode(b: &[u8]) -> Option<String> {
    let detected = detect_bom(b).or_else(|| detect_bomless_utf16(b));
    match detected {
        Some(enc) => {
            let body = &b[enc.bom_len()..];
            match enc {
                UnicodeEncoding::Utf8Bom => std::str::from_utf8(body).ok().map(str::to_owned),
                UnicodeEncoding::Utf16LeBom | UnicodeEncoding::Utf16LeBomless => {
                    Some(decode_utf16(body, true))
                }
                UnicodeEncoding::Utf16BeBom | UnicodeEncoding::Utf16BeBomless => {
                    Some(decode_utf16(body, false))
                }
                UnicodeEncoding::Utf32LeBom => Some(decode_utf32(body, true)),
                UnicodeEncoding::Utf32BeBom => Some(decode_utf32(body, false)),
            }
        }
        None => std::str::from_utf8(b).ok().map(str::to_owned),
    }
}

/// 永远返回字符串的解码（见模块文档的五级顺序）。
pub fn decode_text(b: &[u8]) -> String {
    if let Some(s) = decode_unicode(b) {
        return strip_bom(s);
    }
    for enc in [SHIFT_JIS, GBK, BIG5] {
        let (text, had_errors) = enc.decode_without_bom_handling(b);
        if !had_errors {
            return strip_bom(text.into_owned());
        }
    }
    strip_bom(String::from_utf8_lossy(b).into_owned())
}

fn strip_bom(s: String) -> String {
    match s.strip_prefix('\u{FEFF}') {
        Some(rest) => rest.to_owned(),
        None => s,
    }
}

/// 统一换行：CRLF / CR → LF。
pub fn normalize_newlines(s: &str) -> String {
    s.replace("\r\n", "\n").replace('\r', "\n")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn utf32le_wins_over_utf16le() {
        let b = [0xFF, 0xFE, 0, 0, b'A', 0, 0, 0];
        assert_eq!(decode_text(&b), "A");
    }

    #[test]
    fn bomless_utf16le() {
        let b: Vec<u8> = "[00:01.00]hi".encode_utf16().flat_map(|u| u.to_le_bytes()).collect();
        assert_eq!(decode_text(&b), "[00:01.00]hi");
    }

    #[test]
    fn shift_jis_fallback() {
        let (b, _, _) = SHIFT_JIS.encode("[00:01.00]夜に駆ける");
        assert_eq!(decode_text(&b), "[00:01.00]夜に駆ける");
    }

    #[test]
    fn utf8_bom_with_invalid_body_is_not_strict_utf8() {
        // BOM 宣称 UTF-8、正文却是 Shift_JIS：不就地糊成 U+FFFD。
        let (sj, _, _) = SHIFT_JIS.encode("歌詞");
        let mut b = vec![0xEF, 0xBB, 0xBF];
        b.extend_from_slice(&sj);
        assert_eq!(decode_unicode(&b), None);
    }
}
