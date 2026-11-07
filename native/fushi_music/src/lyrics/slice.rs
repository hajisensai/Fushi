//! 时间轴切片：整文件一次转写出的字幕按 CUE 曲目区间 `[start, end)` 截取并平移成曲内时间
//! （音乐库「生成日语字幕」：CUE 整轨多曲共用一个音频文件，只转写一次）。
//!
//! 口径：与区间有交集的行都留下，跨边界的行截断到区间内（不做语义修补）；音节同样按交集
//! 保留并截断，截完没有音节的行丢掉。时间一律减去 `start`。`end = None` 取到结尾。
//! 不补任何字段（尤其不补 ruby：严禁自动注音）。

use super::model::{Line, Syllable, Timeline};

fn overlaps(s: i64, e: i64, start: i64, end: Option<i64>) -> bool {
    // 零长（s == e）的行 / 音节按「起点落在区间内」判。
    let after_start = if e > s { e > start } else { s >= start };
    let before_end = match end {
        Some(end) => s < end,
        None => true,
    };
    after_start && before_end
}

fn clamp(v: i64, start: i64, end: Option<i64>) -> i64 {
    let v = v.max(start);
    let v = match end {
        Some(end) => v.min(end),
        None => v,
    };
    v - start
}

fn slice_syllable(s: &Syllable, start: i64, end: Option<i64>) -> Option<Syllable> {
    if !overlaps(s.start_ms, s.end_ms, start, end) {
        return None;
    }
    Some(Syllable {
        start_ms: clamp(s.start_ms, start, end),
        end_ms: clamp(s.end_ms, start, end),
        ..s.clone()
    })
}

fn slice_line(l: &Line, start: i64, end: Option<i64>) -> Option<Line> {
    if !overlaps(l.start_ms, l.end_ms, start, end) {
        return None;
    }
    let syllables: Vec<Syllable> = l
        .syllables
        .iter()
        .filter_map(|s| slice_syllable(s, start, end))
        .collect();
    if syllables.is_empty() {
        return None;
    }
    Some(Line {
        start_ms: clamp(l.start_ms, start, end),
        end_ms: clamp(l.end_ms, start, end),
        syllables,
        ..l.clone()
    })
}

/// 见模块注释。`end <= start` 得到空时间轴（元数据照留）。
pub fn slice(t: &Timeline, start_ms: i64, end_ms: Option<i64>) -> Timeline {
    let start = start_ms.max(0);
    let lines = match end_ms {
        Some(end) if end <= start => Vec::new(),
        _ => t
            .lines
            .iter()
            .filter_map(|l| slice_line(l, start, end_ms))
            .collect(),
    };
    Timeline {
        meta: t.meta.clone(),
        agents: t.agents.clone(),
        lines,
        timing_quality: t.timing_quality,
    }
}
