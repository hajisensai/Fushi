//! Dart `String` 操作在 UTF-16 码元切片上的逐条复现（`trim` 的空白集合、`toLowerCase`、
//! `contains` / `indexOf` / `replaceAll(String)` / `int.parse`）。

/// Dart `String.trim()` 的空白集合（实测 0..0xFFFF 全量枚举；比 JS `\s` 多一个 U+0085）。
pub fn is_dart_trim_space(unit: u16) -> bool {
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

/// Dart `trim()`。
pub fn trim(s: &[u16]) -> &[u16] {
    let mut start = 0;
    let mut end = s.len();
    while start < end && is_dart_trim_space(s[start]) {
        start += 1;
    }
    while end > start && is_dart_trim_space(s[end - 1]) {
        end -= 1;
    }
    &s[start..end]
}

/// Dart `trimRight()`。
pub fn trim_right(s: &[u16]) -> &[u16] {
    let mut end = s.len();
    while end > 0 && is_dart_trim_space(s[end - 1]) {
        end -= 1;
    }
    &s[..end]
}

/// Dart `toLowerCase()`（VM 实现，实测逐码点 1:1、不改长度、无 Final_Sigma 上下文：
/// U+0130 → `i`、U+212A → `k`）。只用于与常量表 / ASCII 正则比较，结果从不进输出。
/// 合法代理对按码点映射；孤立代理原样保留。
pub fn to_lower(s: &[u16]) -> Vec<u16> {
    let mut out = Vec::with_capacity(s.len());
    for decoded in char::decode_utf16(s.iter().copied()) {
        match decoded {
            Ok(c) => {
                let mapped = if c == '\u{130}' {
                    'i'
                } else {
                    let mut lower = c.to_lowercase();
                    match (lower.next(), lower.next()) {
                        (Some(single), None) => single,
                        _ => c,
                    }
                };
                let mut buf = [0u16; 2];
                out.extend_from_slice(mapped.encode_utf16(&mut buf));
            }
            Err(e) => out.push(e.unpaired_surrogate()),
        }
    }
    out
}

/// Dart `contains(String)`（空 needle 恒真）。
pub fn contains(hay: &[u16], needle: &[u16]) -> bool {
    index_of(hay, needle, 0).is_some()
}

/// Dart `indexOf(String, start)`。
pub fn index_of(hay: &[u16], needle: &[u16], start: usize) -> Option<usize> {
    if needle.is_empty() {
        return (start <= hay.len()).then_some(start);
    }
    if needle.len() > hay.len() {
        return None;
    }
    (start..=hay.len() - needle.len()).find(|&i| &hay[i..i + needle.len()] == needle)
}

/// Dart `replaceAll(String from, String to)`（from 非空）。
pub fn replace_all_str(s: &[u16], from: &[u16], to: &[u16]) -> Vec<u16> {
    debug_assert!(!from.is_empty());
    let mut out = Vec::with_capacity(s.len());
    let mut i = 0;
    while i < s.len() {
        if s.len() - i >= from.len() && &s[i..i + from.len()] == from {
            out.extend_from_slice(to);
            i += from.len();
        } else {
            out.push(s[i]);
            i += 1;
        }
    }
    out
}

/// `int.parse` 之于正则已保证是 1 位以上 ASCII 数字的捕获（本域的所有调用点）。
/// 位数都被正则限制在 4 位以内，不会溢出。
pub fn parse_digits(s: &[u16]) -> i64 {
    assert!(
        !s.is_empty() && s.iter().all(|u| (0x30..=0x39).contains(u)),
        "not ASCII digits"
    );
    s.iter().fold(0i64, |acc, u| acc * 10 + (*u - 0x30) as i64)
}

/// Dart `int.tryParse(String)`（VM 语义，实测）：先按 Dart 空白集合 trim；可选 `+`/`-`；
/// 十进制溢出 int64 返回 null；`0x`/`0X` 前缀走十六进制且按 64 位**回绕**
/// （`0xFFFFFFFFFFFFFFFF` = -1），超过 16 位十六进制数字返回 null。
pub fn dart_int_try_parse(raw: &[u16]) -> Option<i64> {
    let s = trim(raw);
    let (negative, digits) = match s.first() {
        Some(0x2B) => (false, &s[1..]),
        Some(0x2D) => (true, &s[1..]),
        _ => (false, s),
    };
    if digits.is_empty() {
        return None;
    }
    if digits.len() > 2 && digits[0] == 0x30 && (digits[1] == 0x78 || digits[1] == 0x58) {
        let hex = &digits[2..];
        let mut value: u64 = 0;
        let mut significant = 0usize;
        for &u in hex {
            let d = match u {
                0x30..=0x39 => u - 0x30,
                0x41..=0x46 => u - 0x41 + 10,
                0x61..=0x66 => u - 0x61 + 10,
                _ => return None,
            } as u64;
            if significant > 0 || d != 0 {
                significant += 1;
            }
            if significant > 16 {
                return None;
            }
            value = (value << 4) | d;
        }
        if negative {
            // 负号 + 十六进制：绝对值不超过 2^63 才有值（`-0xFFFFFFFFFFFFFFFF` 为 null）。
            return (value <= 1u64 << 63).then(|| (value as i64).wrapping_neg());
        }
        return Some(value as i64);
    }
    let mut value: i128 = 0;
    for &u in digits {
        if !(0x30..=0x39).contains(&u) {
            return None;
        }
        value = value * 10 + (u - 0x30) as i128;
        if value > (i64::MAX as i128) + 1 {
            return None;
        }
    }
    let v = if negative { -value } else { value };
    if v > i64::MAX as i128 || v < i64::MIN as i128 {
        return None;
    }
    Some(v as i64)
}

/// `&str` 常量 → UTF-16。
pub fn w(s: &str) -> Vec<u16> {
    s.encode_utf16().collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn try_parse_matches_dart_vm() {
        let p = |s: &str| dart_int_try_parse(&w(s));
        assert_eq!(p(" 12 "), Some(12));
        assert_eq!(p("+5"), Some(5));
        assert_eq!(p("-0"), Some(0));
        assert_eq!(p("0x1F"), Some(31));
        assert_eq!(p("-0x1F"), Some(-31));
        assert_eq!(p("0X1f"), Some(31));
        assert_eq!(p("1_0"), None);
        assert_eq!(p("９"), None);
        assert_eq!(p(""), None);
        assert_eq!(p(" "), None);
        assert_eq!(p("00012"), Some(12));
        assert_eq!(p("9223372036854775807"), Some(i64::MAX));
        assert_eq!(p("9223372036854775808"), None);
        assert_eq!(p("-9223372036854775808"), Some(i64::MIN));
        assert_eq!(p("0xFFFFFFFFFFFFFFFF"), Some(-1));
        assert_eq!(p("0x8000000000000000"), Some(i64::MIN));
        assert_eq!(p("\u{a0}12\u{a0}"), Some(12));
        assert_eq!(p("\u{85}12"), Some(12));
        assert_eq!(p("1e3"), None);
        assert_eq!(p("+"), None);
        assert_eq!(p("-"), None);
        assert_eq!(p("0x"), None);
        assert_eq!(p("0x10000000000000000"), None);
        assert_eq!(p("0x00000000000000000001"), Some(1));
        assert_eq!(p("0x0000000000000000FFFFFFFFFFFFFFFF"), Some(-1));
        assert_eq!(p("- 5"), None);
        assert_eq!(p("0x-1"), None);
        assert_eq!(p("-0x8000000000000000"), Some(i64::MIN));
        assert_eq!(p("-0xFFFFFFFFFFFFFFFF"), None);
        assert_eq!(p("+0x10"), Some(16));
        assert_eq!(p("00x10"), None);
        assert_eq!(p("1 2"), None);
        assert_eq!(p("0x1g"), None);
        assert_eq!(p("-9223372036854775809"), None);
        assert_eq!(p("000000000000000000000000000009"), Some(9));
    }

    #[test]
    fn lower_matches_dart_vm_special_cases() {
        assert_eq!(to_lower(&w("M\u{212A}V\u{130}")), w("mkvi"));
        assert_eq!(to_lower(&w("ΑΣ")), w("ασ"));
        assert_eq!(to_lower(&[0xD800, 0x41]), vec![0xD800, 0x61]);
    }
}
