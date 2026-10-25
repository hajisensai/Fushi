//! 各格式的时间码解析（一律返回毫秒）。

/// 小数部分转毫秒：1 位 = 1/10 秒、2 位 = 1/100、3 位及以上取前三位。
fn frac_ms(f: &str) -> Option<i64> {
    if f.is_empty() {
        return Some(0);
    }
    if !f.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    let mut digits: String = f.chars().take(3).collect();
    while digits.len() < 3 {
        digits.push('0');
    }
    digits.parse().ok()
}

/// LRC 时间戳正文（不含方括号）：`mm:ss.xx` / `mm:ss.xxx` / `mm:ss:xx` / `mm:ss` /
/// `hh:mm:ss.xx`。分钟可以超过 59。
pub fn lrc_stamp(s: &str) -> Option<i64> {
    let s = s.trim();
    let parts: Vec<&str> = s.split(':').collect();
    let num = |p: &str| -> Option<i64> {
        (!p.is_empty() && p.bytes().all(|b| b.is_ascii_digit())).then(|| p.parse().ok())?
    };
    match parts.len() {
        2 => {
            let m = num(parts[0])?;
            let (sec, frac) = split_frac(parts[1]);
            Some(m * 60_000 + num(sec)? * 1000 + frac_ms(frac)?)
        }
        3 => {
            // `mm:ss:xx`（第三段是百分秒）或 `hh:mm:ss.xx`。
            if parts[2].contains('.') {
                let h = num(parts[0])?;
                let m = num(parts[1])?;
                let (sec, frac) = split_frac(parts[2]);
                Some(h * 3_600_000 + m * 60_000 + num(sec)? * 1000 + frac_ms(frac)?)
            } else {
                let m = num(parts[0])?;
                let sec = num(parts[1])?;
                Some(m * 60_000 + sec * 1000 + frac_ms(parts[2])?)
            }
        }
        _ => None,
    }
}

fn split_frac(s: &str) -> (&str, &str) {
    match s.find(['.', ',']) {
        Some(i) => (&s[..i], &s[i + 1..]),
        None => (s, ""),
    }
}

/// SRT / VTT / SAMI 风格的时钟时间：`hh:mm:ss,mmm` / `hh:mm:ss.mmm` / `mm:ss.mmm`。
pub fn clock(s: &str) -> Option<i64> {
    let s = s.trim();
    let parts: Vec<&str> = s.split(':').collect();
    let num = |p: &str| -> Option<i64> {
        let p = p.trim();
        (!p.is_empty() && p.bytes().all(|b| b.is_ascii_digit())).then(|| p.parse().ok())?
    };
    let (h, m, rest) = match parts.len() {
        3 => (num(parts[0])?, num(parts[1])?, parts[2]),
        2 => (0, num(parts[0])?, parts[1]),
        1 => (0, 0, parts[0]),
        _ => return None,
    };
    let (sec, frac) = split_frac(rest);
    Some(h * 3_600_000 + m * 60_000 + num(sec)? * 1000 + frac_ms(frac)?)
}

/// TTML 时间表达式：clock-time（`00:01:02.345`、`01:02.345`、`1.5`）或 offset-time
/// （`1.5s` / `1500ms` / `2m` / `1h`）。帧（`f`）与 tick（`t`）不支持。
pub fn ttml(s: &str) -> Option<i64> {
    let s = s.trim();
    if s.is_empty() {
        return None;
    }
    let num_part = |suffix: &str| -> Option<f64> { s.strip_suffix(suffix)?.trim().parse::<f64>().ok() };
    if let Some(v) = num_part("ms") {
        return Some(v.round() as i64);
    }
    if let Some(v) = num_part("s") {
        return Some((v * 1000.0).round() as i64);
    }
    if let Some(v) = num_part("m") {
        return Some((v * 60_000.0).round() as i64);
    }
    if let Some(v) = num_part("h") {
        return Some((v * 3_600_000.0).round() as i64);
    }
    if s.contains(':') {
        return clock(s);
    }
    s.parse::<f64>().ok().map(|v| (v * 1000.0).round() as i64)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lrc_variants() {
        assert_eq!(lrc_stamp("01:02.34"), Some(62_340));
        assert_eq!(lrc_stamp("01:02.345"), Some(62_345));
        assert_eq!(lrc_stamp("01:02.3"), Some(62_300));
        assert_eq!(lrc_stamp("01:02:34"), Some(62_340));
        assert_eq!(lrc_stamp("01:02"), Some(62_000));
        assert_eq!(lrc_stamp("120:00.00"), Some(7_200_000));
        assert_eq!(lrc_stamp("ti:abc"), None);
        assert_eq!(lrc_stamp("offset:+500"), None);
    }

    #[test]
    fn clock_and_ttml() {
        assert_eq!(clock("00:01:02,345"), Some(62_345));
        assert_eq!(clock("01:02.345"), Some(62_345));
        assert_eq!(ttml("1.5s"), Some(1500));
        assert_eq!(ttml("250ms"), Some(250));
        assert_eq!(ttml("00:00:01.250"), Some(1250));
        assert_eq!(ttml("12.5"), Some(12_500));
    }
}
