//! 字素簇切分：逐位复刻 `package:characters`（本仓锁定版本）的前向自动机。
//!
//! 字幕 markup 的 span 下标（`seg.text.characters.length`）与 `\N` 换行下标
//! （`for (ch in plain.characters)`）原本由 package:characters 计算；表由
//! `tool/gen_subtitle_tables.dart` 从该包导出（`low` / `high` / `move`），这里照抄它的
//! `Breaks.nextBreak`（[count]）与 `StringCharacterRange.moveNext`（[for_each]）两套循环——
//! 两者判断断点的掩码不同（前者 `maskFlags`、后者 `maskBreak`），不合并。

use std::sync::OnceLock;

use super::tables::{GRAPHEME_CATEGORY_RANGES, GRAPHEME_MOVE};

const CATEGORY_CONTROL: u8 = 1;
const CATEGORY_OTHER: u8 = 2;
const CATEGORY_EOT: u8 = 18;
const STATE_SOT_NO_BREAK: u16 = 0x0C * 20;
const MASK_BREAK: u16 = 1;
const MASK_FLAGS: u16 = 3;

fn bmp_table() -> &'static [u8; 0x10000] {
    static TABLE: OnceLock<Box<[u8; 0x10000]>> = OnceLock::new();
    TABLE.get_or_init(|| {
        let mut table = Box::new([CATEGORY_OTHER; 0x10000]);
        for &(start, end, cat) in GRAPHEME_CATEGORY_RANGES.iter() {
            if start > 0xFFFF {
                break;
            }
            for cp in start..=end.min(0xFFFF) {
                table[cp as usize] = cat;
            }
        }
        table
    })
}

/// 码点的前向类别（BMP 即 package:characters 的 `low`，补充平面即 `high`）。
pub fn category(cp: u32) -> u8 {
    if cp <= 0xFFFF {
        return bmp_table()[cp as usize];
    }
    match GRAPHEME_CATEGORY_RANGES.binary_search_by(|&(start, end, _)| {
        if end < cp {
            std::cmp::Ordering::Less
        } else if start > cp {
            std::cmp::Ordering::Greater
        } else {
            std::cmp::Ordering::Equal
        }
    }) {
        Ok(i) => GRAPHEME_CATEGORY_RANGES[i].2,
        Err(_) => CATEGORY_OTHER,
    }
}

#[inline]
fn low(unit: u16) -> u8 {
    bmp_table()[unit as usize]
}

#[inline]
fn high(lead: u16, tail: u16) -> u8 {
    category(0x10000 + ((lead as u32) << 10) + tail as u32)
}

#[inline]
fn mv(state: u16, cat: u8) -> u16 {
    GRAPHEME_MOVE[((state & !3) as usize) + cat as usize]
}

/// `s.characters.length`（`StringCharacters.length` → 反复 `Breaks.nextBreak()`）。
pub fn count(s: &[u16]) -> usize {
    if s.is_empty() {
        return 0;
    }
    let end = s.len();
    let mut cursor = 0usize;
    let mut state = STATE_SOT_NO_BREAK;
    let mut n = 0usize;
    loop {
        // Breaks.nextBreak()
        let mut found = false;
        while cursor < end {
            // step()
            let ch = s[cursor];
            cursor += 1;
            let surrogate = ch ^ 0xD800;
            if surrogate > 0x3FF {
                state = mv(state, low(ch));
            } else {
                let cat;
                if cursor < end && (s[cursor] ^ 0xDC00) <= 0x3FF {
                    cat = high(surrogate, s[cursor] ^ 0xDC00);
                    cursor += 1;
                } else {
                    cat = CATEGORY_CONTROL;
                }
                state = mv(state, cat);
            }
            if state & MASK_FLAGS != 0 {
                found = true;
                break;
            }
        }
        if !found {
            state = mv(state, CATEGORY_EOT);
            found = state & MASK_FLAGS != 0;
        }
        if !found {
            return n;
        }
        n += 1;
    }
}

/// `for (final String ch in s.characters)`：按 `StringCharacterRange.moveNext` 依次给出每个
/// 字素的 `[start, end)`（码元下标）。
pub fn for_each(s: &[u16], mut f: impl FnMut(usize, usize)) {
    let len = s.len();
    let mut end = 0usize;
    loop {
        let start = end;
        let mut state = STATE_SOT_NO_BREAK;
        let mut index = end;
        let mut emitted = false;
        while index < len {
            let ch = s[index];
            let surrogate = ch ^ 0xD800;
            let mut cat = CATEGORY_CONTROL;
            let mut next = index + 1;
            if surrogate > 0x3FF {
                cat = low(ch);
            } else if next < len {
                let tail = s[next] ^ 0xDC00;
                if tail <= 0x3FF {
                    next += 1;
                    cat = high(surrogate, tail);
                }
            }
            state = mv(state, cat);
            if state & MASK_BREAK != 0 {
                f(start, index);
                end = index;
                emitted = true;
                break;
            }
            index = next;
        }
        if !emitted {
            if state != STATE_SOT_NO_BREAK {
                f(start, len);
            }
            return;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::super::tables::{GRAPHEME_CATEGORY_FNV1A, GRAPHEME_MOVE_FNV1A};
    use super::*;

    fn fnv(hash: u32, b: u8) -> u32 {
        (hash ^ b as u32).wrapping_mul(0x01000193)
    }

    #[test]
    fn tables_match_generator_digest() {
        let mut h = 0x811c9dc5u32;
        for cp in 0..0x110000u32 {
            h = fnv(h, category(cp));
        }
        assert_eq!(h, GRAPHEME_CATEGORY_FNV1A);
        let mut h = 0x811c9dc5u32;
        for &v in GRAPHEME_MOVE.iter() {
            h = fnv(h, v as u8);
            h = fnv(h, (v >> 8) as u8);
        }
        assert_eq!(h, GRAPHEME_MOVE_FNV1A);
    }

    fn w(s: &str) -> Vec<u16> {
        s.encode_utf16().collect()
    }

    fn pieces(s: &str) -> usize {
        let mut n = 0;
        for_each(&w(s), |_, _| n += 1);
        n
    }

    #[test]
    fn known_clusters() {
        for (s, n) in [
            ("", 0),
            ("a", 1),
            ("\r\n", 1),
            ("e\u{301}", 1),
            ("👨‍👩‍👧", 1),
            ("🇯🇵🇺🇸", 2),
            ("한국어", 3),
            ("\u{1100}\u{1161}\u{11A8}", 1),
            ("क्षि", 1),
            ("a\n b", 4),
        ] {
            assert_eq!(count(&w(s)), n, "{s:?}");
            assert_eq!(pieces(s), n, "{s:?}");
        }
        assert_eq!(count(&[0xD800, 0x61]), 2);
        assert_eq!(count(&[0xDC00]), 1);
    }
}
