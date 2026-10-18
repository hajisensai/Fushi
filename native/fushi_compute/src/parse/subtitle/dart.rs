//! Dart 运行时语义的逐位复刻（UTF-16 码元串上）。字幕解析原本是 Dart 实现，结果要与之逐位
//! 一致，所以凡是 Dart 核心库 / 正则引擎里会影响结果的细节都在这里按 Dart VM 实测行为实现：
//!
//! - [is_dart_ws]：`String.trim()` 的空白集合（含 U+0085、U+FEFF）；[is_js_ws]：正则 `\s`
//!   （JS 语义，不含 U+0085）。
//! - [int_try_parse]：`int.tryParse`（先按 Dart 空白 trim，`+`/`-`，无 radix 时接受 `0x`
//!   十六进制且正数按 64 位回绕，十进制越界为 null）。
//! - [double_try_parse]：`double.tryParse`（trim、`NaN` / `+NaN` / `-NaN` 的确切位模式、
//!   `Infinity`，十进制文法逐字符校验后按正确舍入转换）。NaN 的位模式随 CPU，见 [dart_nan]。
//! - [parse_int_digits]：正则已保证形如 `-?\d+` 的 `int.parse`，越界抛 `FormatException`
//!   （消息与 VM 一致）。
//! - [round_to_int]：`double.round()`（NaN/Inf 抛 `UnsupportedError`，有限值饱和到 int64）。
//! - [split_str]：`String.split(String)`（空串得到 `[""]`）。
//! - [to_lower]：`String.toLowerCase()`（逐码点映射表，由生成器从 Dart SDK 导出）。

use super::tables::LOWERCASE_MAP;

/// Dart 侧要按原类型重新抛出的异常（旧实现会从解析函数里抛出的那几种）。
#[derive(Clone, Debug, PartialEq)]
pub enum DartError {
    /// `FormatException(message, source)`。
    Format {
        message: &'static str,
        source: Vec<u16>,
    },
    /// `UnsupportedError(message)`。
    Unsupported(&'static str),
    /// `RangeError.range(value, start, end, name)`。
    Range {
        value: i64,
        start: i64,
        end: i64,
        name: &'static str,
    },
}

pub type DResult<T> = Result<T, DartError>;

pub const fn u(c: char) -> u16 {
    c as u16
}

/// `String.trim()` 认的空白（Dart VM `_isWhitespace`）。
#[inline]
pub fn is_dart_ws(c: u16) -> bool {
    matches!(
        c,
        0x09..=0x0D
            | 0x20
            | 0x85
            | 0xA0
            | 0x1680
            | 0x2000..=0x200A
            | 0x2028
            | 0x2029
            | 0x202F
            | 0x205F
            | 0x3000
            | 0xFEFF
    )
}

/// 正则 `\s`（JS / irregexp 语义，不含 U+0085）。
#[inline]
pub fn is_js_ws(c: u16) -> bool {
    c != 0x85 && is_dart_ws(c)
}

/// 正则 `.`（非 dotAll）不匹配的行终止符。
#[inline]
pub fn is_line_terminator(c: u16) -> bool {
    matches!(c, 0x0A | 0x0D | 0x2028 | 0x2029)
}

#[inline]
pub fn is_digit(c: u16) -> bool {
    (0x30..=0x39).contains(&c)
}

#[inline]
pub fn is_hex(c: u16) -> bool {
    is_digit(c) || (0x41..=0x46).contains(&c) || (0x61..=0x66).contains(&c)
}

/// 正则 `\w` / `\b` 的单词字符（非 unicode 模式：ASCII）。
#[inline]
pub fn is_word(c: u16) -> bool {
    is_digit(c) || (0x41..=0x5A).contains(&c) || (0x61..=0x7A).contains(&c) || c == 0x5F
}

pub fn trim(s: &[u16]) -> &[u16] {
    trim_right(trim_left(s))
}

pub fn trim_left(s: &[u16]) -> &[u16] {
    let mut start = 0;
    while start < s.len() && is_dart_ws(s[start]) {
        start += 1;
    }
    &s[start..]
}

pub fn trim_right(s: &[u16]) -> &[u16] {
    let mut end = s.len();
    while end > 0 && is_dart_ws(s[end - 1]) {
        end -= 1;
    }
    &s[..end]
}

/// `s == lit`（lit 为 ASCII）。
#[inline]
pub fn eq_ascii(s: &[u16], lit: &[u8]) -> bool {
    s.len() == lit.len() && s.iter().zip(lit).all(|(&a, &b)| a == b as u16)
}

/// `s.startsWith(lit)`（lit 为 ASCII）。
#[inline]
pub fn starts_with_ascii(s: &[u16], lit: &[u8]) -> bool {
    s.len() >= lit.len() && eq_ascii(&s[..lit.len()], lit)
}

/// 从 [at] 起是否是 [lit]。
#[inline]
pub fn has_ascii_at(s: &[u16], at: usize, lit: &[u8]) -> bool {
    at <= s.len() && starts_with_ascii(&s[at..], lit)
}

#[inline]
pub fn ends_with_ascii(s: &[u16], lit: &[u8]) -> bool {
    s.len() >= lit.len() && eq_ascii(&s[s.len() - lit.len()..], lit)
}

/// `s.indexOf(String.fromCharCode(unit), from)`。
#[inline]
pub fn index_of_unit(s: &[u16], unit: u16, from: usize) -> Option<usize> {
    if from >= s.len() {
        return None;
    }
    s[from..].iter().position(|&c| c == unit).map(|p| p + from)
}

/// `s.indexOf(pat, from)`（pat 为 ASCII、非空）。
pub fn index_of_ascii(s: &[u16], pat: &[u8], from: usize) -> Option<usize> {
    if pat.is_empty() || s.len() < pat.len() {
        return None;
    }
    let first = pat[0] as u16;
    let last_start = s.len() - pat.len();
    let mut i = from;
    while i <= last_start {
        if s[i] == first && eq_ascii(&s[i..i + pat.len()], pat) {
            return Some(i);
        }
        i += 1;
    }
    None
}

#[inline]
pub fn contains_ascii(s: &[u16], pat: &[u8]) -> bool {
    index_of_ascii(s, pat, 0).is_some()
}

/// `s.split(pat)`（pat 为非空 ASCII 串）。空串得到 `[""]`（pattern 不匹配空串时）。
pub fn split_str<'a>(s: &'a [u16], pat: &[u8]) -> Vec<&'a [u16]> {
    let mut out = Vec::new();
    let mut start = 0;
    let mut from = 0;
    while let Some(at) = index_of_ascii(s, pat, from) {
        out.push(&s[start..at]);
        start = at + pat.len();
        from = start;
    }
    out.push(&s[start..]);
    out
}

/// `s.split(String.fromCharCode(unit))`（同上，空串 → `[""]`）。
pub fn split_unit(s: &[u16], unit: u16) -> Vec<&[u16]> {
    s.split(|&c| c == unit).collect()
}

/// `s.split(RegExp(r'\s+')).where((t) => t.isNotEmpty)`：全部极大非 `\s` 段。
pub fn ws_tokens(s: &[u16]) -> Vec<&[u16]> {
    s.split(|&c| is_js_ws(c))
        .filter(|t| !t.is_empty())
        .collect()
}

/// 单个码点的 Dart `toLowerCase()`。
#[inline]
pub fn lower_cp(cp: u32) -> u32 {
    if cp < 0x80 {
        return if (0x41..=0x5A).contains(&cp) {
            cp + 32
        } else {
            cp
        };
    }
    match LOWERCASE_MAP.binary_search_by_key(&cp, |&(from, _)| from) {
        Ok(i) => LOWERCASE_MAP[i].1,
        Err(_) => cp,
    }
}

/// `String.toLowerCase()`：逐码点映射（合法代理对合成后查表，孤立代理原样）。生成器断言过
/// 映射不改变 UTF-16 长度，所以下标与原串一一对应。
pub fn to_lower(s: &[u16]) -> Vec<u16> {
    let mut out = Vec::with_capacity(s.len());
    let mut i = 0;
    while i < s.len() {
        let c = s[i];
        if (0xD800..=0xDBFF).contains(&c)
            && i + 1 < s.len()
            && (0xDC00..=0xDFFF).contains(&s[i + 1])
        {
            let cp = 0x10000 + (((c as u32) - 0xD800) << 10) + ((s[i + 1] as u32) - 0xDC00);
            let lc = lower_cp(cp);
            if lc >= 0x10000 {
                let v = lc - 0x10000;
                out.push(0xD800 + (v >> 10) as u16);
                out.push(0xDC00 + (v & 0x3FF) as u16);
            } else {
                out.push(lc as u16);
            }
            i += 2;
            continue;
        }
        if (0xD800..=0xDFFF).contains(&c) {
            out.push(c);
        } else {
            out.push(lower_cp(c as u32) as u16);
        }
        i += 1;
    }
    out
}

/// `int.tryParse(source)`（radix 缺省）。
pub fn int_try_parse(source: &[u16]) -> Option<i64> {
    let s = trim(source);
    let mut i = 0;
    let mut negative = false;
    if i < s.len() && (s[i] == u('+') || s[i] == u('-')) {
        negative = s[i] == u('-');
        i += 1;
    }
    if i >= s.len() {
        return None;
    }
    if i + 1 < s.len() && s[i] == u('0') && (s[i + 1] == u('x') || s[i + 1] == u('X')) {
        let digits = &s[i + 2..];
        if digits.is_empty() || !digits.iter().all(|&c| is_hex(c)) {
            return None;
        }
        let mut value: u128 = 0;
        for &c in digits {
            value = value * 16 + hex_value(c) as u128;
            if value > u64::MAX as u128 {
                return None;
            }
        }
        return if negative {
            if value > 1u128 << 63 {
                None
            } else {
                Some((value as u64 as i64).wrapping_neg())
            }
        } else {
            Some(value as u64 as i64)
        };
    }
    let digits = &s[i..];
    if !digits.iter().all(|&c| is_digit(c)) {
        return None;
    }
    let mut value: u128 = 0;
    for &c in digits {
        value = value * 10 + (c - 0x30) as u128;
        if value > 1u128 << 63 {
            return None;
        }
    }
    if negative {
        Some((value as u64 as i64).wrapping_neg())
    } else if value > i64::MAX as u128 {
        None
    } else {
        Some(value as i64)
    }
}

#[inline]
pub fn hex_value(c: u16) -> u32 {
    match c {
        0x30..=0x39 => (c - 0x30) as u32,
        0x41..=0x46 => (c - 0x41 + 10) as u32,
        _ => (c - 0x61 + 10) as u32,
    }
}

/// `int.parse(hex, radix: 16)`，hex 已由正则保证为 1..8 位十六进制。
pub fn parse_hex_u32(hex: &[u16]) -> i64 {
    hex.iter()
        .fold(0i64, |acc, &c| acc * 16 + hex_value(c) as i64)
}

/// `int.parse(s)`，s 已由正则保证形如 `-?\d+`。越界时抛与 VM 同文的 `FormatException`。
pub fn parse_int_digits(s: &[u16]) -> DResult<i64> {
    let (negative, digits) = if !s.is_empty() && s[0] == u('-') {
        (true, &s[1..])
    } else {
        (false, s)
    };
    let mut value: u128 = 0;
    for &c in digits {
        value = value * 10 + (c - 0x30) as u128;
        if value > 1u128 << 64 {
            break;
        }
    }
    if negative {
        if value > 1u128 << 63 {
            return Err(DartError::Format {
                message: "Negative input exceeds the limit of integer",
                source: s.to_vec(),
            });
        }
        Ok((value as u64 as i64).wrapping_neg())
    } else {
        if value > i64::MAX as u128 {
            return Err(DartError::Format {
                message: "Positive input exceeds the limit of integer",
                source: s.to_vec(),
            });
        }
        Ok(value as i64)
    }
}

/// `double.parse(s)`，s 已由正则保证形如 `-?\d+(?:\.\d+)?`（正确舍入，同 VM）。
pub fn parse_decimal(s: &[u16]) -> f64 {
    let ascii: String = s.iter().map(|&c| c as u8 as char).collect();
    ascii.parse::<f64>().expect("regex-validated decimal")
}

/// Dart `double.nan` / `double.tryParse("NaN")` 的值：**位模式随 CPU 而不同**，等于硬件
/// 「生成的」NaN（`0.0 / 0.0`）——x64 是 0xFFF8000000000000，arm64 是 0x7FF8000000000000
/// （2026-10-18 在 Windows x64 JIT 与 Mac arm64 JIT/AOT 上实测）。所以这里在运行时做一次
/// 真除法，而不是写死常量（`black_box` 阻止常量折叠，折叠出来的是 Rust 的 0x7FF8...）。
pub fn dart_nan() -> f64 {
    let z = std::hint::black_box(0.0f64);
    z / z
}

/// `double.tryParse(source)`。
pub fn double_try_parse(source: &[u16]) -> Option<f64> {
    let s = trim(source);
    if s.is_empty() {
        return None;
    }
    let (sign, body) = match s[0] {
        0x2B => (1i8, &s[1..]),
        0x2D => (-1i8, &s[1..]),
        _ => (0i8, s),
    };
    if eq_ascii(body, b"NaN") {
        // VM 实测：`NaN` / `-NaN` 得到 `double.nan`（见 [dart_nan]，随 CPU），`+NaN` 在
        // x64 与 arm64 上都是 0x7FF8...。
        return Some(if sign == 1 {
            f64::from_bits(0x7FF8_0000_0000_0000)
        } else {
            dart_nan()
        });
    }
    if eq_ascii(body, b"Infinity") {
        return Some(if sign < 0 {
            f64::NEG_INFINITY
        } else {
            f64::INFINITY
        });
    }
    // [+-]? (\d+ (\.\d*)? | \.\d+) ([eE][+-]?\d+)?
    let mut i = 0;
    let int_digits = count_while(body, 0, is_digit);
    i += int_digits;
    let mut frac_digits = 0;
    if i < body.len() && body[i] == u('.') {
        i += 1;
        frac_digits = count_while(body, i, is_digit);
        i += frac_digits;
    }
    if int_digits == 0 && frac_digits == 0 {
        return None;
    }
    if i < body.len() && (body[i] == u('e') || body[i] == u('E')) {
        i += 1;
        if i < body.len() && (body[i] == u('+') || body[i] == u('-')) {
            i += 1;
        }
        let exp_digits = count_while(body, i, is_digit);
        if exp_digits == 0 {
            return None;
        }
        i += exp_digits;
    }
    if i != body.len() {
        return None;
    }
    let mut ascii = String::with_capacity(s.len() + 2);
    if sign < 0 {
        ascii.push('-');
    }
    if int_digits == 0 {
        ascii.push('0');
    }
    for &c in body {
        ascii.push(c as u8 as char);
    }
    ascii.parse::<f64>().ok()
}

#[inline]
pub fn count_while(s: &[u16], from: usize, pred: impl Fn(u16) -> bool) -> usize {
    let mut n = 0;
    while from + n < s.len() && pred(s[from + n]) {
        n += 1;
    }
    n
}

/// `double.round()`：NaN / ±Inf 抛 `UnsupportedError`；有限值四舍五入（远离零）后饱和到 int64。
pub fn round_to_int(v: f64) -> DResult<i64> {
    if !v.is_finite() {
        return Err(DartError::Unsupported("Infinity or NaN toInt"));
    }
    Ok(v.round() as i64)
}

/// Dart `1 << shift`（shift >= 0）：移位量 >= 64 结果为 0，63 得到 int64 最小值。
#[inline]
pub fn dart_shl1(shift: i64) -> i64 {
    if shift >= 64 {
        0
    } else {
        1i64.wrapping_shl(shift as u32)
    }
}

/// ASCII 文本 → UTF-16。
pub fn ascii16(s: &str) -> Vec<u16> {
    s.encode_utf16().collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn w(s: &str) -> Vec<u16> {
        s.encode_utf16().collect()
    }

    #[test]
    fn int_try_parse_matches_vm_probe() {
        let cases: &[(&str, Option<i64>)] = &[
            ("1", Some(1)),
            (" 1", Some(1)),
            ("+1", Some(1)),
            ("-0", Some(0)),
            ("0x1F", Some(31)),
            ("0X1f", Some(31)),
            ("-0x10", Some(-16)),
            ("+0x10", Some(16)),
            ("1_0", None),
            ("", None),
            (" ", None),
            ("\u{85}1", Some(1)),
            ("\u{feff}1", Some(1)),
            ("9223372036854775807", Some(i64::MAX)),
            ("9223372036854775808", None),
            ("-9223372036854775808", Some(i64::MIN)),
            ("-9223372036854775809", None),
            ("0x8000000000000000", Some(i64::MIN)),
            ("0xFFFFFFFFFFFFFFFF", Some(-1)),
            ("0x10000000000000000", None),
            ("-0xFFFFFFFFFFFFFFFF", None),
            ("-0x8000000000000000", Some(i64::MIN)),
            ("-0x7FFFFFFFFFFFFFFF", Some(-i64::MAX)),
            ("0x00000000000000000001", Some(1)),
            ("１", None),
            ("00012", Some(12)),
            ("+", None),
            ("-", None),
            ("+-1", None),
            ("1.0", None),
            ("0x", None),
            ("- 1", None),
            ("0000000000000000000000009", Some(9)),
        ];
        for (s, want) in cases {
            assert_eq!(int_try_parse(&w(s)), *want, "{s:?}");
        }
    }

    #[test]
    fn double_try_parse_matches_vm_probe() {
        let cases: &[(&str, Option<f64>)] = &[
            ("1", Some(1.0)),
            (" 1", Some(1.0)),
            ("+1", Some(1.0)),
            ("0x1F", None),
            ("1e3", Some(1000.0)),
            ("1e", None),
            (".5", Some(0.5)),
            ("5.", Some(5.0)),
            (".", None),
            ("+.5", Some(0.5)),
            ("-.5e-3", Some(-0.0005)),
            ("nan", None),
            ("Infinity", Some(f64::INFINITY)),
            ("-Infinity", Some(f64::NEG_INFINITY)),
            ("infinity", None),
            ("1e400", Some(f64::INFINITY)),
            ("1e-400", Some(0.0)),
            ("\u{85}1", Some(1.0)),
            ("1_0", None),
            ("", None),
            ("1.5f", None),
            ("00.1", Some(0.1)),
            ("1.e3", Some(1000.0)),
            ("1..2", None),
            ("1 2", None),
            ("e5", None),
        ];
        for (s, want) in cases {
            let got = double_try_parse(&w(s));
            assert_eq!(got.map(f64::to_bits), want.map(f64::to_bits), "{s:?}");
        }
        assert_eq!(
            double_try_parse(&w("-0")).unwrap().to_bits(),
            (-0.0f64).to_bits()
        );
        let nan_bits = if cfg!(target_arch = "aarch64") {
            0x7FF8_0000_0000_0000
        } else {
            0xFFF8_0000_0000_0000
        };
        assert_eq!(dart_nan().to_bits(), nan_bits);
        assert_eq!(double_try_parse(&w("NaN")).unwrap().to_bits(), nan_bits);
        assert_eq!(double_try_parse(&w("-NaN")).unwrap().to_bits(), nan_bits);
        assert_eq!(
            double_try_parse(&w("+NaN")).unwrap().to_bits(),
            0x7FF8_0000_0000_0000
        );
    }

    #[test]
    fn round_and_shift() {
        assert_eq!(round_to_int(1e300), Ok(i64::MAX));
        assert_eq!(round_to_int(-1e300), Ok(i64::MIN));
        assert_eq!(round_to_int(2.5), Ok(3));
        assert_eq!(round_to_int(-2.5), Ok(-3));
        assert_eq!(round_to_int(0.49999999999999994), Ok(0));
        assert!(round_to_int(f64::NAN).is_err());
        assert_eq!(dart_shl1(63), i64::MIN);
        assert_eq!(dart_shl1(64), 0);
        assert_eq!(dart_shl1(100), 0);
        assert_eq!(dart_shl1(62), 1 << 62);
    }

    #[test]
    fn split_and_lower() {
        assert_eq!(split_str(&[], b"-->"), vec![&[] as &[u16]]);
        assert_eq!(split_unit(&[], u(',')).len(), 1);
        assert_eq!(split_str(&w("a-->-->b"), b"-->").len(), 3);
        assert_eq!(split_unit(&w(",a,"), u(',')).len(), 3);
        assert_eq!(to_lower(&w("ΑΣ İ\u{212A}")), w("ασ ik"));
        assert_eq!(to_lower(&w("\u{10400}")), w("\u{10428}"));
        assert_eq!(to_lower(&[0xD801, 0x41]), vec![0xD801, 0x61]);
    }

    #[test]
    fn parse_int_overflow_is_format_exception() {
        assert_eq!(parse_int_digits(&w("9223372036854775807")), Ok(i64::MAX));
        assert_eq!(parse_int_digits(&w("-9223372036854775808")), Ok(i64::MIN));
        assert!(matches!(
            parse_int_digits(&w("9223372036854775808")),
            Err(DartError::Format {
                message: "Positive input exceeds the limit of integer",
                ..
            })
        ));
        assert!(matches!(
            parse_int_digits(&w(&format!("-{}", "9".repeat(40)))),
            Err(DartError::Format {
                message: "Negative input exceeds the limit of integer",
                ..
            })
        ));
    }
}
