//! Dart 核心库语义的逐位复刻（Dart SDK 3.47.6 VM 实现，见各函数注释里的出处）。
//!
//! 弹幕解析原本是 Dart 代码，结果靠这些原语的确切语义决定（哪些字符串能解析成数、
//! 怎么取整、怎么转字符串、什么算空白）。这里每个函数都对着 SDK 源码与本机实测写成，
//! 改动前先读对应的 SDK 源码，并跑 `packages/fushi_compute/test/danmaku_*_test.dart`
//! 的冻结向量。所有字符串都是 UTF-16 码元（Dart `String` 的原生表示）。

/// Dart `String.trim()` / `double.parse` / `int.parse` 共用的空白集合
/// （`string_patch.dart` `_isTwoByteWhitespace`：Unicode White_Space + BOM）。
/// 与 petitparser `whitespace()`（`WhitespaceCharPredicate`）逐码元相同。
#[inline]
pub fn is_whitespace(unit: u16) -> bool {
    matches!(
        unit,
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

/// Dart `String.trim()`。
pub fn trim(s: &[u16]) -> &[u16] {
    let mut start = 0;
    let mut end = s.len();
    while start < end && is_whitespace(s[start]) {
        start += 1;
    }
    while end > start && is_whitespace(s[end - 1]) {
        end -= 1;
    }
    &s[start..end]
}

/// `x.toInt()` / `x.round()` 遇到 NaN / ±Infinity 时 Dart 抛的
/// `UnsupportedError('Infinity or NaN toInt')`。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct NonFinite;

/// Dart `double.toInt()`：向零截断，超出 int64 的有限值饱和（本机实测 `1e300.toInt()`
/// = 9223372036854775807），非有限抛异常。
#[inline]
pub fn to_int(x: f64) -> Result<i64, NonFinite> {
    if x.is_finite() {
        Ok(x as i64)
    } else {
        Err(NonFinite)
    }
}

/// Dart `double.round()`：四舍五入远离零（`-2.5` → `-3`），饱和与非有限规则同 [to_int]。
#[inline]
pub fn round(x: f64) -> Result<i64, NonFinite> {
    if x.is_finite() {
        Ok(x.round() as i64)
    } else {
        Err(NonFinite)
    }
}

/// Dart `int.tryParse(source, radix: radix)`（`integers_patch.dart` `_parse` /
/// `_parseRadix`；`radix` 为 `None` 即不传 radix）。
///
/// - 先按 [is_whitespace] 去掉首尾空白；可带一个 `+` / `-`。
/// - 不传 radix 时：`0x` / `0X` 前缀按十六进制，正数允许到 `u64::MAX` 并按二补码回绕
///   （`0xFFFFFFFFFFFFFFFF` → -1）；显式 radix 不认 `0x`。
/// - 超出 int64 返回 `None`（溢出与非法字符同为 `None`，tryParse 不区分）。
pub fn int_try_parse(source: &[u16], radix: Option<u32>) -> Option<i64> {
    let s = trim(source);
    if s.is_empty() {
        return None;
    }
    let mut i = 0;
    let mut negative = false;
    if s[0] == b'+' as u16 || s[0] == b'-' as u16 {
        negative = s[0] == b'-' as u16;
        i = 1;
        if i == s.len() {
            return None;
        }
    }
    let radix = match radix {
        Some(r) => r,
        None => {
            if s[i] == b'0' as u16 {
                i += 1;
                if i == s.len() {
                    return Some(0);
                }
                if (s[i] | 0x20) == b'x' as u16 {
                    i += 1;
                    if i == s.len() {
                        return None;
                    }
                    return parse_radix(&s[i..], 16, negative, !negative);
                }
            }
            10
        }
    };
    parse_radix(&s[i..], radix, negative, false)
}

fn digit_value(unit: u16, radix: u32) -> Option<u32> {
    let d = match unit {
        0x30..=0x39 => u32::from(unit - 0x30),
        0x41..=0x5A => u32::from(unit - 0x41) + 10,
        0x61..=0x7A => u32::from(unit - 0x61) + 10,
        _ => return None,
    };
    if d < radix {
        Some(d)
    } else {
        None
    }
}

fn parse_radix(digits: &[u16], radix: u32, negative: bool, allow_u64: bool) -> Option<i64> {
    let mut start = 0;
    while start < digits.len() && digits[start] == b'0' as u16 {
        start += 1;
    }
    if start == digits.len() {
        return Some(0);
    }
    let mut value: u128 = 0;
    for &unit in &digits[start..] {
        let d = digit_value(unit, radix)?;
        value = value * u128::from(radix) + u128::from(d);
        if value > u128::from(u64::MAX) {
            return None;
        }
    }
    if negative {
        if value > 1u128 << 63 {
            return None;
        }
        Some((value as u64).wrapping_neg() as i64)
    } else if value <= i64::MAX as u128 {
        Some(value as i64)
    } else if allow_u64 {
        Some(value as u64 as i64)
    } else {
        None
    }
}

/// Dart `double.tryParse(source)`（`double_patch.dart` `_parse`：去首尾空白后先走
/// `_tryParseDouble` 快路径，失败再走原生 double-conversion）。本机实测接受集合：
///
/// `[+-]?Infinity`、`[+-]?NaN`、`[+-]?(数字+ ('.' 数字*)? | '.' 数字+)([eE][+-]?数字+)?`；
/// 不认十六进制、`inf` / `nan` 小写、下划线、全角 / 阿拉伯数字。
///
/// 数值：快路径（尾数 < 2^53、10 的幂 ≤ 22，一次乘除）与原生路径都是正确舍入，
/// 与 Rust `f64::from_str` 的正确舍入一致，所以合法串交给它算值。
pub fn double_try_parse(source: &[u16]) -> Option<f64> {
    let s = trim(source);
    if s.is_empty() {
        return None;
    }
    let mut i = 0;
    let mut negative = false;
    if s[0] == b'+' as u16 || s[0] == b'-' as u16 {
        negative = s[0] == b'-' as u16;
        i = 1;
    }
    let rest = &s[i..];
    if units_eq_ascii(rest, b"Infinity") {
        return Some(if negative {
            f64::NEG_INFINITY
        } else {
            f64::INFINITY
        });
    }
    if units_eq_ascii(rest, b"NaN") {
        return Some(f64::NAN);
    }
    let is_digit = |u: u16| (0x30..=0x39).contains(&u);
    let mut j = 0;
    let int_start = j;
    while j < rest.len() && is_digit(rest[j]) {
        j += 1;
    }
    let int_digits = &rest[int_start..j];
    let mut frac_digits: &[u16] = &[];
    if j < rest.len() && rest[j] == b'.' as u16 {
        j += 1;
        let frac_start = j;
        while j < rest.len() && is_digit(rest[j]) {
            j += 1;
        }
        frac_digits = &rest[frac_start..j];
    }
    if int_digits.is_empty() && frac_digits.is_empty() {
        return None;
    }
    let mut exp_negative = false;
    let mut exp_digits: &[u16] = &[];
    if j < rest.len() && (rest[j] | 0x20) == b'e' as u16 {
        j += 1;
        if j < rest.len() && (rest[j] == b'+' as u16 || rest[j] == b'-' as u16) {
            exp_negative = rest[j] == b'-' as u16;
            j += 1;
        }
        let exp_start = j;
        while j < rest.len() && is_digit(rest[j]) {
            j += 1;
        }
        exp_digits = &rest[exp_start..j];
        if exp_digits.is_empty() {
            return None;
        }
    }
    if j != rest.len() {
        return None;
    }
    let mut text = String::with_capacity(rest.len() + 8);
    if negative {
        text.push('-');
    }
    push_ascii_digits(&mut text, int_digits);
    text.push('.');
    push_ascii_digits(&mut text, frac_digits);
    if !exp_digits.is_empty() {
        text.push('e');
        if exp_negative {
            text.push('-');
        }
        push_ascii_digits(&mut text, exp_digits);
    }
    text.parse::<f64>().ok()
}

fn push_ascii_digits(out: &mut String, digits: &[u16]) {
    if digits.is_empty() {
        out.push('0');
    }
    for &d in digits {
        out.push(d as u8 as char);
    }
}

/// UTF-16 片段是否逐码元等于 ASCII 串。
#[inline]
pub fn units_eq_ascii(units: &[u16], ascii: &[u8]) -> bool {
    units.len() == ascii.len() && units.iter().zip(ascii).all(|(&u, &a)| u == u16::from(a))
}

/// `s.toLowerCase() == keyword`（keyword 为小写 ASCII）。
///
/// Dart VM 的 `toLowerCase` 逐字符映射；本机穷举 0..=0x10FFFF 实测只有 `A`–`Z`、
/// U+0130 `İ`（→ `i`，单码元）与 U+212A 开尔文符号（→ `k`）会小写成 ASCII，
/// 其余非 ASCII 字符的小写结果都不是 ASCII，不可能等于关键字。
pub fn lower_eq_ascii_keyword(s: &[u16], keyword: &[u8]) -> bool {
    s.len() == keyword.len()
        && s.iter().zip(keyword).all(|(&u, &k)| {
            let lowered = match u {
                0x41..=0x5A => u + 0x20,
                0x0130 => b'i' as u16,
                0x212A => b'k' as u16,
                other => other,
            };
            lowered == u16::from(k)
        })
}

/// Dart `int.toString()`。
pub fn write_int(value: i64, out: &mut Vec<u16>) {
    out.extend(value.to_string().bytes().map(u16::from));
}

/// Dart `double.toString()`（VM `DoubleToCString`：double-conversion `ToShortest`，
/// `decimal_in_shortest_low = -6`、`high = 21`，`EMIT_POSITIVE_EXPONENT_SIGN |
/// EMIT_TRAILING_DECIMAL_POINT | EMIT_TRAILING_ZERO_AFTER_POINT`）。
///
/// 最短往返位数取自 Rust `{:e}`（同为「最短且最接近」的唯一位串），版式按上述规则重排：
/// `1.0`、`100000000000000000000.0`、`1e+21`、`0.000001`、`1e-7`、`-0.0`、`Infinity`。
pub fn write_double(value: f64, out: &mut Vec<u16>) {
    if value.is_nan() {
        push_ascii(out, "NaN");
        return;
    }
    if value.is_infinite() {
        push_ascii(out, if value < 0.0 { "-Infinity" } else { "Infinity" });
        return;
    }
    if value == 0.0 {
        push_ascii(
            out,
            if value.is_sign_negative() {
                "-0.0"
            } else {
                "0.0"
            },
        );
        return;
    }
    let sci = format!("{:e}", value.abs());
    let (mantissa, exponent) = sci.split_once('e').expect("{:e} always has an exponent");
    let exponent: i32 = exponent.parse().expect("{:e} exponent is an integer");
    let digits: Vec<u8> = mantissa.bytes().filter(|b| b.is_ascii_digit()).collect();
    if value < 0.0 {
        out.push(b'-' as u16);
    }
    let n = digits.len() as i32;
    let push_digits = |out: &mut Vec<u16>, ds: &[u8]| out.extend(ds.iter().map(|&d| u16::from(d)));
    if (-6..21).contains(&exponent) {
        let decimal_point = exponent + 1;
        if decimal_point <= 0 {
            push_ascii(out, "0.");
            for _ in 0..(-decimal_point) {
                out.push(b'0' as u16);
            }
            push_digits(out, &digits);
        } else if decimal_point >= n {
            push_digits(out, &digits);
            for _ in 0..(decimal_point - n) {
                out.push(b'0' as u16);
            }
            push_ascii(out, ".0");
        } else {
            let split = decimal_point as usize;
            push_digits(out, &digits[..split]);
            out.push(b'.' as u16);
            push_digits(out, &digits[split..]);
        }
    } else {
        push_digits(out, &digits[..1]);
        if digits.len() > 1 {
            out.push(b'.' as u16);
            push_digits(out, &digits[1..]);
        }
        out.push(b'e' as u16);
        if exponent >= 0 {
            out.push(b'+' as u16);
        }
        write_int(i64::from(exponent), out);
    }
}

pub fn push_ascii(out: &mut Vec<u16>, s: &str) {
    out.extend(s.bytes().map(u16::from));
}

#[cfg(test)]
mod tests {
    use super::*;

    fn u(s: &str) -> Vec<u16> {
        s.encode_utf16().collect()
    }

    fn dstr(x: f64) -> String {
        let mut out = Vec::new();
        write_double(x, &mut out);
        String::from_utf16(&out).unwrap()
    }

    #[test]
    fn double_to_string_matches_dart_probe() {
        // 期望值全部来自本机 Dart 3.47.6 实测（D:\hibiki-tmp\danmaku-agent\oracle\bin\probe.dart）。
        let cases: &[(f64, &str)] = &[
            (1.0, "1.0"),
            (100.0, "100.0"),
            (1e20, "100000000000000000000.0"),
            (1e21, "1e+21"),
            (1.5e21, "1.5e+21"),
            (1e-6, "0.000001"),
            (1e-7, "1e-7"),
            (1.5e-7, "1.5e-7"),
            (0.1, "0.1"),
            (123.456, "123.456"),
            (-0.0, "-0.0"),
            (0.0, "0.0"),
            (f64::INFINITY, "Infinity"),
            (f64::NEG_INFINITY, "-Infinity"),
            (5e-324, "5e-324"),
            (1.7976931348623157e308, "1.7976931348623157e+308"),
            (123456789012345680000.0, "123456789012345680000.0"),
            (1.2345678901234568e21, "1.2345678901234568e+21"),
            (0.000001234, "0.000001234"),
            (0.0000001234, "1.234e-7"),
            (2.0e-6, "0.000002"),
            (9.999999999999999e20, "999999999999999900000.0"),
            (-1.5e-7, "-1.5e-7"),
            (-1e21, "-1e+21"),
            (1e22, "1e+22"),
            (1.2345678901234568e29, "1.2345678901234568e+29"),
        ];
        for &(x, want) in cases {
            assert_eq!(dstr(x), want, "{x:e}");
        }
    }

    #[test]
    fn double_try_parse_matches_dart_probe() {
        let ok: &[(&str, f64)] = &[
            ("1", 1.0),
            (" 1 ", 1.0),
            ("+1", 1.0),
            (".5", 0.5),
            ("5.", 5.0),
            ("1.e5", 1e5),
            ("+.5", 0.5),
            ("1E05", 1e5),
            ("1e+05", 1e5),
            ("1e0000000000000000000005", 1e5),
            ("1e400", f64::INFINITY),
            ("1e99999999999999999999", f64::INFINITY),
            ("+Infinity", f64::INFINITY),
            ("-Infinity ", f64::NEG_INFINITY),
            ("\u{a0}1\u{a0}", 1.0),
            ("\u{feff}1", 1.0),
            ("1\u{85}", 1.0),
            ("9007199254740993", 9007199254740992.0),
        ];
        for &(s, want) in ok {
            assert_eq!(double_try_parse(&u(s)), Some(want), "{s:?}");
        }
        assert!(double_try_parse(&u("-0")).unwrap().is_sign_negative());
        assert!(double_try_parse(&u("+NaN")).unwrap().is_nan());
        assert!(double_try_parse(&u("-NaN")).unwrap().is_nan());
        for s in [
            "",
            " ",
            "1e",
            "1e+",
            "e5",
            "0x10",
            "infinity",
            "nan",
            "inf",
            "1_0",
            "1.5f",
            "١",
            "１",
            "1.2.3",
            "--1",
            "+-1",
            "-",
            "+",
            ".",
            ".e5",
            "1e5.5",
            "1 2",
            "Infinityx",
            "- 1",
            "1e 5",
            "1e+-5",
            "+.",
            "-.e1",
            "1e1e1",
            "1,5",
        ] {
            assert_eq!(double_try_parse(&u(s)), None, "{s:?}");
        }
    }

    #[test]
    fn int_try_parse_matches_dart_probe() {
        let cases: &[(&str, Option<u32>, Option<i64>)] = &[
            (" 1 ", None, Some(1)),
            ("-0", None, Some(0)),
            ("0x10", None, Some(16)),
            ("0X1f", None, Some(31)),
            ("-0x10", None, Some(-16)),
            ("+0x10", None, Some(16)),
            ("0x", None, None),
            ("00x10", None, None),
            ("0x-1", None, None),
            ("1.0", None, None),
            ("9223372036854775807", None, Some(i64::MAX)),
            ("9223372036854775808", None, None),
            ("-9223372036854775808", None, Some(i64::MIN)),
            ("-9223372036854775809", None, None),
            ("0x8000000000000000", None, Some(i64::MIN)),
            ("0xFFFFFFFFFFFFFFFF", None, Some(-1)),
            ("0x10000000000000000", None, None),
            ("-0x8000000000000000", None, Some(i64::MIN)),
            ("-0x8000000000000001", None, None),
            ("-0xFFFFFFFFFFFFFFFF", None, None),
            ("0x000000000000000000FFFFFFFFFFFFFFFF", None, Some(-1)),
            ("\u{a0}1", None, Some(1)),
            ("1\u{feff}", None, Some(1)),
            ("１", None, None),
            ("+-1", None, None),
            (" 41 ", Some(16), Some(65)),
            ("-41", Some(16), Some(-65)),
            ("0x41", Some(16), None),
            ("FFFFFFFFFFFFFFFF", Some(16), None),
            ("7FFFFFFFFFFFFFFF", Some(16), Some(i64::MAX)),
            ("0x41", Some(10), None),
            ("99999999999999999999", Some(10), None),
        ];
        for &(s, radix, want) in cases {
            assert_eq!(int_try_parse(&u(s), radix), want, "{s:?} radix {radix:?}");
        }
    }

    #[test]
    fn rounding_and_lowercase() {
        assert_eq!(round(2.5), Ok(3));
        assert_eq!(round(-2.5), Ok(-3));
        assert_eq!(round(0.49999999999999994), Ok(0));
        assert_eq!(round(1e300), Ok(i64::MAX));
        assert_eq!(round(-1e300), Ok(i64::MIN));
        assert_eq!(round(f64::NAN), Err(NonFinite));
        assert_eq!(to_int(-1.5), Ok(-1));
        assert_eq!(to_int(f64::INFINITY), Err(NonFinite));
        assert!(lower_eq_ascii_keyword(&u("R\u{130}GHT"), b"right"));
        assert!(lower_eq_ascii_keyword(&u("ToP"), b"top"));
        assert!(!lower_eq_ascii_keyword(&u("\u{17f}croll"), b"scroll"));
        assert_eq!(trim(&u("\u{feff} a \u{3000}")), &u("a")[..]);
    }
}
