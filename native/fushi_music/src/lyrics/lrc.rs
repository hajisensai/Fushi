//! LRC 全家：行级 LRC、增强 LRC（A2，行内 `<mm:ss.xx>` 词级）、ESLyric 逐字 LRC（行内
//! `[mm:ss.xx]`）。
//!
//! - 一行可带多个时间戳（`[00:01.00][00:20.00]副歌`）→ 展开成多行；
//! - `[offset:+500]` 烘进时间（正 = 歌词提前，与 LRC 惯例一致）；
//! - 只有时间戳没有正文的行是「间奏」：给上一行当终点，不成行；
//! - 同一时间戳的第二行起视为上一行的翻译（网易云 / QQ 导出的「原文 + 译文」合并 LRC）；
//! - 词级时间是绝对时间；行首多时间戳又带词级时间时，按与第一个行首时间戳的差平移。

use super::model::*;
use super::time::lrc_stamp;

/// 正文里的行内时间戳风格。
#[derive(Clone, Copy, PartialEq, Eq)]
enum Inline {
    Angle,
    Square,
}

struct Entry {
    start: i64,
    /// None = 间奏标记（只有时间戳）。
    line: Option<Line>,
    /// 同一时间戳是否可以当翻译（行级行才合并）。
    line_level: bool,
}

/// 文本里像 LRC 的行占比（嗅探用）：以 `[mm:ss` 开头的行数。
pub fn looks_like_lrc(text: &str) -> bool {
    text.lines().take(200).any(|l| {
        let l = l.trim_start();
        l.strip_prefix('[')
            .and_then(|r| r.find(']').map(|e| &r[..e]))
            .is_some_and(|inner| lrc_stamp(inner).is_some())
    })
}

pub fn parse(text: &str, duration_ms: Option<i64>) -> Timeline {
    let mut offset = 0i64;
    let mut title = None;
    let mut artist = None;
    let mut entries: Vec<Entry> = Vec::new();
    let mut quality = TimingQuality::Line;

    for raw in text.lines() {
        let mut rest = raw.trim();
        let mut stamps: Vec<i64> = Vec::new();
        while let Some(r) = rest.strip_prefix('[') {
            let Some(end) = r.find(']') else { break };
            let inner = &r[..end];
            if let Some(ms) = lrc_stamp(inner) {
                stamps.push(ms);
            } else if let Some((k, v)) = inner.split_once(':') {
                let key = k.trim().to_ascii_lowercase();
                if !key.chars().all(|c| c.is_ascii_alphabetic()) || key.is_empty() {
                    break;
                }
                let v = v.trim();
                match key.as_str() {
                    "offset" => offset = v.trim_start_matches('+').parse().unwrap_or(0),
                    "ti" if !v.is_empty() => title = Some(v.to_owned()),
                    "ar" if !v.is_empty() => artist = Some(v.to_owned()),
                    _ => {}
                }
            } else {
                break;
            }
            rest = &r[end + 1..];
        }
        if stamps.is_empty() {
            continue;
        }
        let (syllables, inline) = split_inline(rest);
        let text_empty = syllables.iter().all(|(t, _)| t.trim().is_empty());
        let first = stamps[0];
        for &stamp in &stamps {
            if text_empty {
                entries.push(Entry { start: stamp, line: None, line_level: true });
                continue;
            }
            let shift = stamp - first;
            let mut line = Line { start_ms: stamp, ..Line::default() };
            match inline {
                None => {
                    line.syllables.push(Syllable::new(rest.trim(), stamp, 0));
                }
                Some(kind) => {
                    quality = quality.max(match kind {
                        Inline::Angle => TimingQuality::Word,
                        Inline::Square => TimingQuality::Syllable,
                    });
                    build_inline_syllables(&mut line, &syllables, stamp, shift);
                }
            }
            entries.push(Entry { start: stamp, line: Some(line), line_level: inline.is_none() });
        }
    }

    // 按起点稳定排序后：同一时间戳的行级行折成翻译；间奏标记给前一行当终点。
    entries.sort_by_key(|e| e.start);
    let mut t = Timeline::new("lrc", quality);
    t.meta.title = title;
    t.meta.artist = artist;
    let mut lines: Vec<Line> = Vec::new();
    let mut last_start: Option<i64> = None;
    for e in entries {
        let start = e.start - offset;
        match e.line {
            None => {
                if let Some(prev) = lines.last_mut() {
                    if prev.end_ms <= prev.start_ms && start > prev.start_ms {
                        prev.end_ms = start;
                    }
                }
            }
            Some(mut line) => {
                if last_start == Some(e.start) && e.line_level {
                    if let Some(prev) = lines.last_mut() {
                        let txt = line.text();
                        if txt.trim() != prev.text().trim() {
                            prev.add_translation("und", &txt);
                        }
                        continue;
                    }
                }
                shift_line(&mut line, -offset);
                if let Some(prev) = lines.last_mut() {
                    if prev.end_ms <= prev.start_ms && line.start_ms > prev.start_ms {
                        prev.end_ms = line.start_ms;
                    }
                }
                last_start = Some(e.start);
                lines.push(line);
            }
        }
    }
    t.lines = lines;
    t.finalize(duration_ms);
    t
}

fn shift_line(line: &mut Line, delta: i64) {
    if delta == 0 {
        return;
    }
    line.start_ms += delta;
    if line.end_ms > 0 {
        line.end_ms += delta;
    }
    for s in &mut line.syllables {
        s.start_ms += delta;
        if s.end_ms > 0 {
            s.end_ms += delta;
        }
    }
}

/// 拆正文里的行内时间戳：返回 (文本, 该段起点) 序列与风格。没有行内时间戳返回 (\[], None)。
/// 第一个时间戳之前的文本起点记 -1（= 用行首时间戳）；末尾空文本段是最后一个词的终点。
fn split_inline(body: &str) -> (Vec<(String, i64)>, Option<Inline>) {
    let mut out: Vec<(String, i64)> = Vec::new();
    let mut kind: Option<Inline> = None;
    let mut cur = String::new();
    let mut cur_start = -1i64;
    let mut i = 0usize;
    let b = body.as_bytes();
    while i < b.len() {
        let c = b[i];
        let close = match c {
            b'<' => Some(('>', Inline::Angle)),
            b'[' => Some((']', Inline::Square)),
            _ => None,
        };
        if let Some((close, k)) = close {
            if kind.is_none() || kind == Some(k) {
                if let Some(rel) = body[i + 1..].find(close) {
                    if let Some(ms) = lrc_stamp(&body[i + 1..i + 1 + rel]) {
                        kind = Some(k);
                        if !cur.is_empty() || cur_start >= 0 {
                            out.push((std::mem::take(&mut cur), cur_start));
                        }
                        cur_start = ms;
                        i += rel + 2;
                        continue;
                    }
                }
            }
        }
        let ch = body[i..].chars().next().unwrap();
        cur.push(ch);
        i += ch.len_utf8();
    }
    if kind.is_none() {
        return (vec![(body.to_owned(), -1)], None);
    }
    out.push((cur, cur_start));
    (out, kind)
}

fn build_inline_syllables(line: &mut Line, segs: &[(String, i64)], line_start: i64, shift: i64) {
    let n = segs.len();
    for (i, (text, start)) in segs.iter().enumerate() {
        let start = if *start < 0 { line_start } else { start + shift };
        let next = segs.get(i + 1).map(|(_, s)| s + shift);
        if text.is_empty() {
            // 末尾的终点时间戳。
            if i + 1 == n {
                if let Some(last) = line.syllables.last_mut() {
                    last.end_ms = start;
                }
                line.end_ms = start;
            }
            continue;
        }
        let mut syl = Syllable::new(text.clone(), start, next.unwrap_or(0));
        syl.fill = Fill::Sweep;
        line.syllables.push(syl);
    }
    if let Some(first) = line.syllables.first() {
        line.start_ms = line.start_ms.min(first.start_ms);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn line_level_with_repeat_stamps_offset_and_translation() {
        let t = parse(
            "[ti:Song]\n[offset:+500]\n[00:01.00][00:05.00]Hello\n[00:01.00]你好\n[00:03.00]\n[00:07.00]End",
            Some(10_000),
        );
        assert_eq!(t.timing_quality, TimingQuality::Line);
        assert_eq!(t.meta.title.as_deref(), Some("Song"));
        let texts: Vec<_> = t.lines.iter().map(|l| (l.text(), l.start_ms, l.end_ms)).collect();
        assert_eq!(
            texts,
            vec![
                ("Hello".to_string(), 500, 2500),
                ("Hello".to_string(), 4500, 6500),
                ("End".to_string(), 6500, 10_000),
            ]
        );
        assert_eq!(t.lines[0].translations, vec![("und".to_string(), "你好".to_string())]);
    }

    #[test]
    fn enhanced_a2_word_level() {
        let t = parse("[00:01.00]<00:01.00>Hel<00:01.50>lo <00:02.00>world<00:03.00>", None);
        assert_eq!(t.timing_quality, TimingQuality::Word);
        let s: Vec<_> = t.lines[0].syllables.iter().map(|s| (s.text.as_str(), s.start_ms, s.end_ms)).collect();
        assert_eq!(s, vec![("Hel", 1000, 1500), ("lo ", 1500, 2000), ("world", 2000, 3000)]);
        assert_eq!(t.lines[0].end_ms, 3000);
    }

    #[test]
    fn eslyric_square_inline() {
        let t = parse("[00:10.00]夜[00:10.40]に[00:10.80]駆[00:11.20]け[00:11.50]る[00:12.00]", None);
        assert_eq!(t.timing_quality, TimingQuality::Syllable);
        assert_eq!(t.lines[0].text(), "夜に駆ける");
        assert_eq!(t.lines[0].syllables.len(), 5);
        assert_eq!(t.lines[0].syllables[4].end_ms, 12_000);
    }
}
