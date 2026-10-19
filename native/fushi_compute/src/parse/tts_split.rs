//! `ffc_parse_tts_*`：TTS 朗读 / 制作有声书的整章切句。
//!
//! 原 Dart 实现（fushi/lib/src/media/audiobook/tts/tts_book_plan.dart 的 `splitTtsText`）
//! 逐码点建一个记录对象、逐原子 `substring` 再查标点表，整书一遍要分配几百万个小对象。
//! 这里一次调用处理一章：输入是章节纯文本的 UTF-16 码元、ruby 区间 + 读音池、块边界 /
//! 场景分隔，输出是每句一条定长记录 + 含 ruby 句的合成文本 UTF-16 池。
//!
//! 语义与旧 Dart 实现逐句逐字段一致（删 Dart 前用 41 本日文书 + 1 本英文书全章节对拍过）：
//! - 原子：一个码点（合法代理对合成一个，孤立代理单独一个）或一整个 ruby 底本；
//! - ruby 过滤：按输入顺序，与上一个**收下的** ruby 重叠、越界、空区间、读音全空白、
//!   读音长于 `max_length / 2`（UTF-16 码元）的跳过；
//! - 句界：句末标点 / 引号收尾之后，只再吞收尾括号与句末标点；块边界 / 场景分隔是硬句界；
//!   单句合成文本（UTF-16 码元）不超过 `max_length`，超长先退到最近的软切点；
//! - 句首尾的空白原子剪掉；空白的判定与 Dart `String.trim` 相同（见 [is_dart_whitespace]）；
//! - 标点判定沿用旧实现的 `String.contains`：原子原文是常量串的**子串**即算（多字 ruby
//!   底本也照此判定）。

use crate::{guard, status};

/// `。！？!?…\n`
const SENTENCE_ENDERS: &[u16] = &[0x3002, 0xFF01, 0xFF1F, 0x21, 0x3F, 0x2026, 0x0A];
/// `」』”’）)]】〉》»`
const CLOSERS: &[u16] = &[
    0x300D, 0x300F, 0x201D, 0x2019, 0xFF09, 0x29, 0x5D, 0x3011, 0x3009, 0x300B, 0xBB,
];
/// `」』`：台词引号收尾也是句界。
const QUOTE_ENDERS: &[u16] = &[0x300D, 0x300F];
/// `、，,；;：:`：超长句的软切点。
const SOFT_BREAKS: &[u16] = &[0x3001, 0xFF0C, 0x2C, 0xFF1B, 0x3B, 0xFF1A, 0x3A];

/// 不设硬句界时的哨兵（与 Dart 侧 `1 << 40` 相同）。
const NO_BREAK: i64 = 1 << 40;

/// Dart `String.trim` 剪掉的码元（Unicode White_Space + BOM），全部在 BMP。
pub fn is_dart_whitespace(unit: u16) -> bool {
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

/// `units.trim().isEmpty`（Dart 语义）。
fn is_blank(units: &[u16]) -> bool {
    units.iter().all(|&u| is_dart_whitespace(u))
}

/// Dart `hay.contains(needle)`（needle 非空）。
fn contains_sub(hay: &[u16], needle: &[u16]) -> bool {
    needle.len() <= hay.len() && hay.windows(needle.len()).any(|w| w == needle)
}

/// 一处 ruby：底本区间（任意整数，过滤时校验）与读音。
#[derive(Clone, Copy, Debug)]
pub struct TtsRuby<'a> {
    pub start: i64,
    pub end: i64,
    pub reading: &'a [u16],
}

/// 一句：原文区间 `[start, end)`；`spoken` 是合成文本在池里的区间，`None` 表示与原文相同
/// （句内没有 ruby）。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TtsSegment {
    pub start: u32,
    pub end: u32,
    pub spoken: Option<(u32, u32)>,
}

const NO_RUBY: u32 = u32::MAX;

struct Atom {
    start: u32,
    end: u32,
    /// 收下的 ruby 下标；码点原子为 [NO_RUBY]。
    ruby: u32,
    spoken_len: i64,
    blank: bool,
    ender: bool,
    closer: bool,
    quote: bool,
    soft: bool,
}

/// 切一章。`breaks` 是块边界与场景分隔的并集（无序、可重复）。`max_length < 8` 由调用方拒绝。
/// 合成文本池追加到 [pool]。
pub fn split_tts_text(
    text: &[u16],
    rubies: &[TtsRuby<'_>],
    breaks: &[i64],
    max_length: i64,
    pool: &mut Vec<u16>,
) -> Vec<TtsSegment> {
    let len = text.len();
    let mut accepted: Vec<TtsRuby<'_>> = Vec::new();
    let mut ruby_at: Vec<u32> = vec![NO_RUBY; len];
    let mut last_end: i64 = 0;
    for ruby in rubies {
        if ruby.start < last_end
            || ruby.start < 0
            || ruby.end > len as i64
            || ruby.end <= ruby.start
            || is_blank(ruby.reading)
            || ruby.reading.len() as i64 > max_length / 2
        {
            continue;
        }
        ruby_at[ruby.start as usize] = accepted.len() as u32;
        accepted.push(*ruby);
        last_end = ruby.end;
    }

    let mut atoms: Vec<Atom> = Vec::with_capacity(len);
    let mut cursor = 0usize;
    while cursor < len {
        let r = ruby_at[cursor];
        let (end, spoken): (usize, &[u16]) = if r != NO_RUBY {
            let ruby = &accepted[r as usize];
            (ruby.end as usize, ruby.reading)
        } else {
            let unit = text[cursor];
            let pair = (0xD800..=0xDBFF).contains(&unit)
                && cursor + 1 < len
                && (text[cursor + 1] & 0xFC00) == 0xDC00;
            let end = cursor + if pair { 2 } else { 1 };
            (end, &text[cursor..end])
        };
        let original = &text[cursor..end];
        atoms.push(Atom {
            start: cursor as u32,
            end: end as u32,
            ruby: r,
            spoken_len: spoken.len() as i64,
            blank: is_blank(spoken),
            ender: contains_sub(SENTENCE_ENDERS, original),
            closer: contains_sub(CLOSERS, original),
            quote: contains_sub(QUOTE_ENDERS, original),
            soft: contains_sub(SOFT_BREAKS, original),
        });
        cursor = end;
    }

    let mut result: Vec<TtsSegment> = Vec::new();
    let mut emit = |mut from: usize, mut to: usize, pool: &mut Vec<u16>| {
        while from < to && atoms[from].blank {
            from += 1;
        }
        while to > from && atoms[to - 1].blank {
            to -= 1;
        }
        if to <= from {
            return;
        }
        let start = atoms[from].start;
        let end = atoms[to - 1].end;
        let spoken = if atoms[from..to].iter().any(|a| a.ruby != NO_RUBY) {
            let offset = pool.len() as u32;
            for atom in &atoms[from..to] {
                if atom.ruby != NO_RUBY {
                    pool.extend_from_slice(accepted[atom.ruby as usize].reading);
                } else {
                    pool.extend_from_slice(&text[atom.start as usize..atom.end as usize]);
                }
            }
            Some((offset, pool.len() as u32 - offset))
        } else {
            None
        };
        result.push(TtsSegment { start, end, spoken });
    };

    let mut hard: Vec<i64> = breaks.to_vec();
    hard.sort_unstable();
    hard.dedup();
    let mut hb = 0usize;

    let n = atoms.len();
    let mut first = 0usize;
    while first < n {
        let mut i = first;
        let mut spoken: i64 = 0;
        let mut last_soft: i64 = -1;
        let mut ended = false;
        let mut hard_stop = false;
        while hb < hard.len() && hard[hb] <= i64::from(atoms[first].start) {
            hb += 1;
        }
        let next_break = if hb < hard.len() { hard[hb] } else { NO_BREAK };
        while i < n {
            let atom = &atoms[i];
            if i > first && i64::from(atom.start) >= next_break {
                hard_stop = true;
                break;
            }
            if ended && !atom.closer && !atom.ender {
                break;
            }
            if spoken + atom.spoken_len > max_length {
                break;
            }
            spoken += atom.spoken_len;
            i += 1;
            if atom.ender || atom.quote {
                ended = true;
            }
            if atom.soft {
                last_soft = i as i64;
            }
        }
        if i == first {
            i = first + 1;
        }
        let overflowed = !ended && !hard_stop && i < n;
        let cut = if overflowed && last_soft > first as i64 {
            last_soft as usize
        } else {
            i
        };
        emit(first, cut, pool);
        first = cut;
    }
    result
}

/// 整章切句。
///
/// 输入：
/// - `text[0..text_len]`：章节纯文本 UTF-16；
/// - `rubies[0..ruby_count * 4]`：每处 ruby 4 个 `i64`——底本 start、end、读音在
///   `readings` 里的 offset、length（读音区间必须落在 `readings[0..readings_len]` 内）；
/// - `breaks[0..break_count]`：块边界与场景分隔（无序、可重复）；
/// - `max_length`：单句合成文本上限（UTF-16 码元，≥ 8）。
///
/// 输出（调用方分配）：
/// - `out_records[0..record_capacity * 4]`：每句 4 个 `i32`——原文 start、end、合成文本在
///   `out_pool` 里的 offset、length（length 为 -1 表示合成文本与原文相同、池里没有）；
/// - `out_pool[0..pool_capacity]`：含 ruby 的句子的合成文本；
/// - `*out_count` / `*out_pool_len`：实际句数 / 池长。容量不够时返回
///   [status::BUFFER_TOO_SMALL]，两者写所需大小（`record_capacity >= text_len` 且
///   `pool_capacity >= text_len + readings_len` 时一定够）。
///
/// # Safety
/// 各指针在对应长度 > 0 时必须指向那么多个可读 / 可写元素；`out_count` / `out_pool_len`
/// 必须非空可写。
#[no_mangle]
pub unsafe extern "C" fn ffc_parse_tts_split_utf16(
    text: *const u16,
    text_len: usize,
    rubies: *const i64,
    ruby_count: usize,
    readings: *const u16,
    readings_len: usize,
    breaks: *const i64,
    break_count: usize,
    max_length: i64,
    out_records: *mut i32,
    record_capacity: usize,
    out_pool: *mut u16,
    pool_capacity: usize,
    out_count: *mut usize,
    out_pool_len: *mut usize,
) -> i32 {
    if out_count.is_null()
        || out_pool_len.is_null()
        || (text_len > 0 && text.is_null())
        || (ruby_count > 0 && rubies.is_null())
        || (readings_len > 0 && readings.is_null())
        || (break_count > 0 && breaks.is_null())
        || (record_capacity > 0 && out_records.is_null())
        || (pool_capacity > 0 && out_pool.is_null())
    {
        return status::NULL_ARGUMENT;
    }
    if max_length < 8 || text_len > i32::MAX as usize {
        return status::INVALID_ARGUMENT;
    }
    guard(|| {
        let text: &[u16] = slice_or_empty(text, text_len);
        let readings: &[u16] = slice_or_empty(readings, readings_len);
        let raw_rubies: &[i64] = slice_or_empty(rubies, ruby_count * 4);
        let breaks: &[i64] = slice_or_empty(breaks, break_count);
        let mut parsed: Vec<TtsRuby<'_>> = Vec::with_capacity(ruby_count);
        for chunk in raw_rubies.chunks_exact(4) {
            let (offset, length) = (chunk[2], chunk[3]);
            if offset < 0 || length < 0 || offset + length > readings.len() as i64 {
                return status::INVALID_ARGUMENT;
            }
            parsed.push(TtsRuby {
                start: chunk[0],
                end: chunk[1],
                reading: &readings[offset as usize..(offset + length) as usize],
            });
        }
        let mut pool: Vec<u16> = Vec::new();
        let segments = split_tts_text(text, &parsed, breaks, max_length, &mut pool);
        *out_count = segments.len();
        *out_pool_len = pool.len();
        if segments.len() > record_capacity || pool.len() > pool_capacity {
            return status::BUFFER_TOO_SMALL;
        }
        let records = slice_mut_or_empty(out_records, segments.len() * 4);
        for (k, seg) in segments.iter().enumerate() {
            let (offset, length) = match seg.spoken {
                Some((o, l)) => (o as i32, l as i32),
                None => (0, -1),
            };
            records[k * 4] = seg.start as i32;
            records[k * 4 + 1] = seg.end as i32;
            records[k * 4 + 2] = offset;
            records[k * 4 + 3] = length;
        }
        slice_mut_or_empty(out_pool, pool.len()).copy_from_slice(&pool);
        status::OK
    })
}

unsafe fn slice_or_empty<'a, T>(ptr: *const T, len: usize) -> &'a [T] {
    if len == 0 {
        &[]
    } else {
        std::slice::from_raw_parts(ptr, len)
    }
}

unsafe fn slice_mut_or_empty<'a, T>(ptr: *mut T, len: usize) -> &'a mut [T] {
    if len == 0 {
        &mut []
    } else {
        std::slice::from_raw_parts_mut(ptr, len)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn u(s: &str) -> Vec<u16> {
        s.encode_utf16().collect()
    }

    struct Seg {
        text: String,
        spoken: String,
        start: u32,
        end: u32,
    }

    fn split(text: &str, rubies: &[(i64, i64, &str)], breaks: &[i64], max: i64) -> Vec<Seg> {
        let units = u(text);
        let readings: Vec<Vec<u16>> = rubies.iter().map(|r| u(r.2)).collect();
        let rubies: Vec<TtsRuby<'_>> = rubies
            .iter()
            .zip(readings.iter())
            .map(|(r, reading)| TtsRuby {
                start: r.0,
                end: r.1,
                reading,
            })
            .collect();
        let mut pool = Vec::new();
        split_tts_text(&units, &rubies, breaks, max, &mut pool)
            .into_iter()
            .map(|s| {
                let original = &units[s.start as usize..s.end as usize];
                let spoken = match s.spoken {
                    Some((o, l)) => &pool[o as usize..(o + l) as usize],
                    None => original,
                };
                Seg {
                    text: String::from_utf16_lossy(original),
                    spoken: String::from_utf16_lossy(spoken),
                    start: s.start,
                    end: s.end,
                }
            })
            .collect()
    }

    fn texts(segs: &[Seg]) -> Vec<&str> {
        segs.iter().map(|s| s.text.as_str()).collect()
    }

    #[test]
    fn constants_match_dart_literals() {
        assert_eq!(SENTENCE_ENDERS, u("。！？!?…\n").as_slice());
        assert_eq!(CLOSERS, u("」』”’）)]】〉》»").as_slice());
        assert_eq!(QUOTE_ENDERS, u("」』").as_slice());
        assert_eq!(SOFT_BREAKS, u("、，,；;：:").as_slice());
    }

    #[test]
    fn sentence_enders_and_closers() {
        let segs = split("「おはよう。」と言った。次の文！", &[], &[], 120);
        assert_eq!(texts(&segs), ["「おはよう。」", "と言った。", "次の文！"]);
        let segs = split("ないわー」「うるせ、お前だろーが。", &[], &[], 120);
        assert_eq!(texts(&segs), ["ないわー」", "「うるせ、お前だろーが。"]);
    }

    #[test]
    fn ruby_reading_is_spoken() {
        let segs = split("漢字を読む。", &[(0, 2, "かんじ")], &[], 120);
        assert_eq!(segs.len(), 1);
        assert_eq!(segs[0].text, "漢字を読む。");
        assert_eq!(segs[0].spoken, "かんじを読む。");
        assert_eq!((segs[0].start, segs[0].end), (0, 6));
    }

    #[test]
    fn soft_break_then_hard_limit() {
        let text = format!("{}、{}。", "あ".repeat(10), "い".repeat(10));
        let segs = split(&text, &[], &[], 15);
        assert_eq!(segs[0].text, format!("{}、", "あ".repeat(10)));
        assert_eq!(
            segs.iter().map(|s| s.text.as_str()).collect::<String>(),
            text
        );
    }

    #[test]
    fn hard_breaks_and_blank_trimming() {
        let segs = split("見出し 本文。", &[], &[3, 3], 120);
        assert_eq!(texts(&segs), ["見出し", "本文。"]);
        assert_eq!(segs[1].start, 4);
        assert!(split("   \u{3000}\n", &[], &[], 120).is_empty());
        assert!(split("", &[], &[], 120).is_empty());
    }

    #[test]
    fn surrogates() {
        let segs = split("𠮷野家。", &[], &[], 8);
        assert_eq!(texts(&segs), ["𠮷野家。"]);
        let units = [0xD800u16, b'a' as u16, 0xDC00];
        let mut pool = Vec::new();
        let segs = split_tts_text(&units, &[], &[], 8, &mut pool);
        assert_eq!(
            segs,
            [TtsSegment {
                start: 0,
                end: 3,
                spoken: None
            }]
        );
    }

    #[test]
    fn ffi_buffer_too_small_reports_sizes() {
        let text = u("あ。い。う。");
        let mut count = 0usize;
        let mut pool_len = 0usize;
        let rc = unsafe {
            ffc_parse_tts_split_utf16(
                text.as_ptr(),
                text.len(),
                std::ptr::null(),
                0,
                std::ptr::null(),
                0,
                std::ptr::null(),
                0,
                120,
                std::ptr::null_mut(),
                0,
                std::ptr::null_mut(),
                0,
                &mut count,
                &mut pool_len,
            )
        };
        assert_eq!(rc, status::BUFFER_TOO_SMALL);
        assert_eq!((count, pool_len), (3, 0));
        let mut records = vec![0i32; 12];
        let rc = unsafe {
            ffc_parse_tts_split_utf16(
                text.as_ptr(),
                text.len(),
                std::ptr::null(),
                0,
                std::ptr::null(),
                0,
                std::ptr::null(),
                0,
                120,
                records.as_mut_ptr(),
                3,
                std::ptr::null_mut(),
                0,
                &mut count,
                &mut pool_len,
            )
        };
        assert_eq!(rc, status::OK);
        assert_eq!(records, [0, 2, 0, -1, 2, 4, 0, -1, 4, 6, 0, -1]);
        let rc = unsafe {
            ffc_parse_tts_split_utf16(
                text.as_ptr(),
                text.len(),
                std::ptr::null(),
                0,
                std::ptr::null(),
                0,
                std::ptr::null(),
                0,
                7,
                records.as_mut_ptr(),
                3,
                std::ptr::null_mut(),
                0,
                &mut count,
                &mut pool_len,
            )
        };
        assert_eq!(rc, status::INVALID_ARGUMENT);
    }
}
