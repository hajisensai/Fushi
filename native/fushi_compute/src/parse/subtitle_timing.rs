//! `ffc_parse_subtiming_*`：从字幕原文扫出时间跨度（Dart `summarizeSubtitleTiming`，
//! packages/fushi_engine/lib/media/video/subtitle/subtitle_timing_check.dart）。
//!
//! 规则只有这一份：srt / vtt 的 `起 --> 止` 先扫，一条都没有再扫 ass/ssa 的
//! `Dialogue:` 行。两条正则原样交给 [js_regex]（逐码元复现 Dart `RegExp`，含多行 `^`
//! 的 JS 行终止符集合），`_parseClock` 逐条照搬（`split` / `int.tryParse` / `padRight`）。
//!
//! 原实现开头的 `content.trim().isEmpty` 短路与「一条都没扫到」同结果（两条正则都要求
//! 数字），这里不单列。

use std::sync::OnceLock;

use super::media_name::dart_str::dart_int_try_parse;
use super::media_name::js_regex::JsRegex;
use crate::{guard, status};

/// 扫描结果（同 Dart `SubtitleTimingSummary`）：`cue_count == 0` 时另两项为 0。
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct TimingSummary {
    pub cue_count: i64,
    pub first_start_ms: i64,
    pub last_end_ms: i64,
}

struct Patterns {
    arrow: JsRegex,
    ass_dialogue: JsRegex,
}

fn patterns() -> &'static Patterns {
    static P: OnceLock<Patterns> = OnceLock::new();
    P.get_or_init(|| Patterns {
        arrow: JsRegex::cs(concat!(
            r"(\d{1,3}:[0-5]?\d:[0-5]?\d[.,]\d{1,3}|[0-5]?\d:[0-5]?\d[.,]\d{1,3})",
            r"\s*-->\s*",
            r"(\d{1,3}:[0-5]?\d:[0-5]?\d[.,]\d{1,3}|[0-5]?\d:[0-5]?\d[.,]\d{1,3})",
        )),
        ass_dialogue: JsRegex::new(
            concat!(
                r"^\s*Dialogue\s*:[^,]*,\s*",
                r"(\d{1,3}:[0-5]?\d:[0-5]?\d[.,]\d{1,3})\s*,\s*",
                r"(\d{1,3}:[0-5]?\d:[0-5]?\d[.,]\d{1,3})\s*,",
            ),
            false,
            true,
        ),
    })
}

/// Dart `_parseClock`：`[HH:]MM:SS[.,]mmm` → 毫秒；小数位不足 3 位右补零。
fn parse_clock(raw: &[u16]) -> Option<i64> {
    let head: Vec<&[u16]> = raw.split(|&u| u == 0x2E || u == 0x2C).collect();
    if head.len() != 2 {
        return None;
    }
    let parts: Vec<&[u16]> = head[0].split(|&u| u == 0x3A).collect();
    if parts.len() < 2 || parts.len() > 3 {
        return None;
    }
    let nums: Option<Vec<i64>> = parts.iter().map(|p| dart_int_try_parse(p)).collect();
    let nums = nums?;
    let (hours, minutes, seconds) = if parts.len() == 3 {
        (nums[0], nums[1], nums[2])
    } else {
        (0, nums[0], nums[1])
    };
    let mut fraction_raw: Vec<u16> = head[1].to_vec();
    while fraction_raw.len() < 3 {
        fraction_raw.push(0x30);
    }
    fraction_raw.truncate(3);
    let fraction = dart_int_try_parse(&fraction_raw)?;
    Some(((hours * 60 + minutes) * 60 + seconds) * 1000 + fraction)
}

/// Dart `summarizeSubtitleTiming`（输入 UTF-16）。
pub fn summarize(content: &[u16]) -> TimingSummary {
    let p = patterns();
    let mut count: i64 = 0;
    let mut first: Option<i64> = None;
    let mut last: i64 = 0;
    for re in [&p.arrow, &p.ass_dialogue] {
        for m in re.all_matches(content) {
            let start = parse_clock(m.text(content, 1).expect("group 1"));
            let end = parse_clock(m.text(content, 2).expect("group 2"));
            if let (Some(start), Some(end)) = (start, end) {
                count += 1;
                if first.is_none_or(|f| start < f) {
                    first = Some(start);
                }
                if end > last {
                    last = end;
                }
            }
        }
        if count > 0 {
            break;
        }
    }
    if count == 0 {
        return TimingSummary::default();
    }
    TimingSummary {
        cue_count: count,
        first_start_ms: first.unwrap_or(0),
        last_end_ms: last,
    }
}

/// 扫 `units[0..len]`，写 `out[0..3] = [cueCount, firstStartMs, lastEndMs]`。
///
/// # Safety
/// `len > 0` 时 `units` 指向 `len` 个可读 u16；`out` 指向 3 个可写 i64。
#[no_mangle]
pub unsafe extern "C" fn ffc_parse_subtiming_summarize(
    units: *const u16,
    len: usize,
    out: *mut i64,
) -> i32 {
    if out.is_null() || (len > 0 && units.is_null()) {
        return status::NULL_ARGUMENT;
    }
    guard(|| {
        let content: &[u16] = if len == 0 {
            &[]
        } else {
            std::slice::from_raw_parts(units, len)
        };
        let s = summarize(content);
        let out = std::slice::from_raw_parts_mut(out, 3);
        out[0] = s.cue_count;
        out[1] = s.first_start_ms;
        out[2] = s.last_end_ms;
        status::OK
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sum(s: &str) -> (i64, i64, i64) {
        let units: Vec<u16> = s.encode_utf16().collect();
        let r = summarize(&units);
        (r.cue_count, r.first_start_ms, r.last_end_ms)
    }

    #[test]
    fn srt_vtt_ass() {
        assert_eq!(
            sum("1\n00:00:01,000 --> 00:00:02,500\nhi\n\n2\n00:01:00,000 --> 00:01:03,000\n"),
            (2, 1000, 63000)
        );
        assert_eq!(
            sum("WEBVTT\n\n01:02.345 --> 01:05.678\nx"),
            (1, 62345, 65678)
        );
        assert_eq!(
            sum("[Events]\nDialogue: 0,0:01:02.34,0:01:05.67,Default,,0,0,0,,x\n  Dialogue :1, 0:00:01.5 ,0:00:02.00 ,y"),
            (2, 1500, 65670)
        );
        assert_eq!(sum("   \n"), (0, 0, 0));
        // 1234:56:01,000：第 0 位起配不上，第 1 位起按 234 小时配上（与 Dart 回溯一致）。
        assert_eq!(
            sum("1234:56:01,000 --> 0:00:00,000"),
            (1, (234 * 3600 + 56 * 60 + 1) * 1000, 0)
        );
    }
}
