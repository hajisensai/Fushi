//! ASS / SSA 卡拉 OK 字幕的**结构化**（设计 §6.3 的结构化一路；原样渲染交给 libass，P3）。
//!
//! - `\k` = 瞬间变色（[Fill::Instant]）、`\K` / `\kf` = 擦色（[Fill::Sweep]）、`\ko` = 描边
//!   （[Fill::Outline]）、`\kt` = 把下一个音节的起点设成「行首 + 参数」；参数单位都是厘秒；
//! - 注音写法 `{\k20}漢|かん`，`#|…` / `#` 续写上一个音节的注音并延长它；
//! - templater 产物：有 `Effect=karaoke` 的行（通常是被注释掉的原始卡拉 OK 行）时只取它们，
//!   `fx` 特效行不进结构化时间轴；出现 `\t` `\move` `\clip` / fx 行 / template 行时置
//!   `has_effects`，界面据此推荐原样渲染；
//! - 多样式同时出现（汉字 / 罗马字 / 译文三层）：卡拉 OK 行最多的样式是正文，其它样式里
//!   起点相差 ≤ 300 ms 的行挂成罗马音（几乎全 ASCII 时）或翻译，对不上的保持独立行。

use super::model::*;
use super::time::clock;

const MERGE_WINDOW_MS: i64 = 300;
const EFFECT_TAGS: &[&str] = &["\\t(", "\\move(", "\\clip(", "\\iclip("];

pub fn looks_like_ass(text: &str) -> bool {
    let head: String = text.chars().take(4096).collect();
    head.contains("[Script Info]") || head.contains("[Events]") || head.contains("Dialogue:")
}

struct Event {
    comment: bool,
    start: i64,
    end: i64,
    style: String,
    effect: String,
    text: String,
}

fn events(text: &str) -> Vec<Event> {
    let mut fmt: Vec<String> = ["layer", "start", "end", "style", "name", "marginl", "marginr", "marginv", "effect", "text"]
        .iter()
        .map(|s| s.to_string())
        .collect();
    let mut in_events = false;
    let mut out = Vec::new();
    for raw in text.lines() {
        let l = raw.trim_start();
        if l.starts_with('[') {
            in_events = l.eq_ignore_ascii_case("[events]");
            continue;
        }
        if !in_events {
            continue;
        }
        if let Some(f) = l.strip_prefix("Format:") {
            fmt = f.split(',').map(|s| s.trim().to_ascii_lowercase()).collect();
            continue;
        }
        let (comment, body) = if let Some(b) = l.strip_prefix("Dialogue:") {
            (false, b)
        } else if let Some(b) = l.strip_prefix("Comment:") {
            (true, b)
        } else {
            continue;
        };
        let parts: Vec<&str> = body.splitn(fmt.len(), ',').collect();
        let get = |name: &str| -> &str {
            fmt.iter().position(|f| f == name).and_then(|i| parts.get(i)).map(|s| s.trim()).unwrap_or("")
        };
        let text_idx = fmt.iter().position(|f| f == "text").unwrap_or(fmt.len() - 1);
        let (Some(start), Some(end)) = (clock(get("start")), clock(get("end"))) else { continue };
        out.push(Event {
            comment,
            start,
            end,
            style: get("style").to_owned(),
            effect: get("effect").to_owned(),
            text: parts.get(text_idx).map(|s| s.to_string()).unwrap_or_default(),
        });
    }
    out
}

/// 一行文本 → (音节, 是否带 `\k` 系列)。
fn karaoke_syllables(text: &str, start: i64, end: i64) -> (Vec<Syllable>, bool) {
    let mut out: Vec<Syllable> = Vec::new();
    let mut has_k = false;
    let mut cursor = start;
    // 当前音节：(起点, 时长, fill)
    let mut pending: Option<(i64, i64, Fill)> = None;
    let mut buf = String::new();
    let mut kt_next: Option<i64> = None;

    let flush = |out: &mut Vec<Syllable>, buf: &mut String, pending: &mut Option<(i64, i64, Fill)>| {
        let txt = std::mem::take(buf);
        let (s, d, fill) = pending.take().unwrap_or((start, 0, Fill::Sweep));
        push_syllable(out, &txt, s, s + d, fill);
    };

    let mut rest = text;
    while !rest.is_empty() {
        if let Some(r) = rest.strip_prefix('{') {
            let Some(close) = r.find('}') else {
                buf.push_str(rest);
                break;
            };
            let block = &r[..close];
            for tag in block.split('\\').skip(1) {
                let (kind, val) = if let Some(v) = tag.strip_prefix("kf") {
                    (Some(Fill::Sweep), v)
                } else if let Some(v) = tag.strip_prefix("ko") {
                    (Some(Fill::Outline), v)
                } else if let Some(v) = tag.strip_prefix("kt") {
                    if let Ok(cs) = v.trim().parse::<i64>() {
                        kt_next = Some(start + cs * 10);
                    }
                    (None, "")
                } else if let Some(v) = tag.strip_prefix('K') {
                    (Some(Fill::Sweep), v)
                } else if let Some(v) = tag.strip_prefix('k') {
                    (Some(Fill::Instant), v)
                } else {
                    (None, "")
                };
                if let Some(fill) = kind {
                    let Ok(cs) = val.trim().parse::<i64>() else { continue };
                    has_k = true;
                    if pending.is_some() || !buf.is_empty() {
                        flush(&mut out, &mut buf, &mut pending);
                    }
                    if let Some(kt) = kt_next.take() {
                        cursor = kt;
                    }
                    pending = Some((cursor, cs * 10, fill));
                    cursor += cs * 10;
                }
            }
            rest = &r[close + 1..];
            continue;
        }
        if let Some(r) = rest.strip_prefix("\\N").or_else(|| rest.strip_prefix("\\n")) {
            buf.push(' ');
            rest = r;
            continue;
        }
        if let Some(r) = rest.strip_prefix("\\h") {
            buf.push(' ');
            rest = r;
            continue;
        }
        let ch = rest.chars().next().unwrap();
        buf.push(ch);
        rest = &rest[ch.len_utf8()..];
    }
    if pending.is_some() || !buf.is_empty() {
        flush(&mut out, &mut buf, &mut pending);
    }
    if !has_k {
        let text: String = out.iter().map(|s| s.text.as_str()).collect();
        return (vec![Syllable::new(text.trim(), start, end)], false);
    }
    (out, true)
}

fn push_syllable(out: &mut Vec<Syllable>, txt: &str, s: i64, e: i64, fill: Fill) {
    // `#` / `#|かな`：续写上一个音节。
    if let Some(cont) = txt.strip_prefix('#') {
        if let Some(prev) = out.last_mut() {
            prev.end_ms = prev.end_ms.max(e);
            if let Some(r) = cont.strip_prefix('|') {
                let r = r.trim();
                if !r.is_empty() {
                    prev.ruby.get_or_insert_with(String::new).push_str(r);
                }
            }
            return;
        }
    }
    let mut syl = Syllable::new(txt, s, e);
    syl.fill = fill;
    if let Some((base, ruby)) = txt.split_once('|') {
        syl.text = base.to_owned();
        let r = ruby.trim();
        syl.ruby = (!r.is_empty()).then(|| r.to_owned());
    }
    if syl.text.is_empty() && syl.ruby.is_none() {
        // 空音节（`{\k50}` 停顿）：时间已计入 cursor，不成音节。
        return;
    }
    out.push(syl);
}

pub fn parse(text: &str, duration_ms: Option<i64>) -> Timeline {
    let evs = events(text);
    let mut t = Timeline::new("ass", TimingQuality::Line);
    let has_karaoke_effect = evs.iter().any(|e| e.effect.eq_ignore_ascii_case("karaoke"));
    t.meta.has_effects = evs.iter().any(|e| {
        let eff = e.effect.to_ascii_lowercase();
        eff == "fx" || eff.starts_with("template") || eff.starts_with("code")
    }) || evs
        .iter()
        .any(|e| !e.comment && EFFECT_TAGS.iter().any(|tag| e.text.contains(tag)));

    struct Built {
        line: Line,
        karaoke: bool,
    }
    let mut built: Vec<Built> = Vec::new();
    for e in &evs {
        let use_it = if has_karaoke_effect {
            e.effect.eq_ignore_ascii_case("karaoke")
        } else {
            !e.comment && !e.effect.eq_ignore_ascii_case("fx")
        };
        if !use_it {
            continue;
        }
        let (syllables, karaoke) = karaoke_syllables(&e.text, e.start, e.end);
        let line = Line {
            start_ms: e.start,
            end_ms: e.end,
            syllables,
            style: Some(e.style.clone()).filter(|s| !s.is_empty()),
            ..Line::default()
        };
        built.push(Built { line, karaoke });
    }
    let any_k = built.iter().any(|b| b.karaoke);
    if any_k {
        t.timing_quality = TimingQuality::Syllable;
    }

    // 正文样式：卡拉 OK 行最多的样式（并列取先出现的）。
    let mut counts: Vec<(String, usize, usize)> = Vec::new(); // (style, k 行数, 首次下标)
    for (i, b) in built.iter().enumerate() {
        let st = b.line.style.clone().unwrap_or_default();
        match counts.iter_mut().find(|c| c.0 == st) {
            Some(c) => c.1 += b.karaoke as usize,
            None => counts.push((st, b.karaoke as usize, i)),
        }
    }
    let primary = counts
        .iter()
        .max_by(|a, b| a.1.cmp(&b.1).then(b.2.cmp(&a.2)))
        .map(|c| c.0.clone())
        .unwrap_or_default();
    let multi_style = counts.len() > 1;

    let (mut main, others): (Vec<Built>, Vec<Built>) = built
        .into_iter()
        .partition(|b| !multi_style || b.line.style.clone().unwrap_or_default() == primary);
    for o in others {
        let txt = o.line.text();
        let txt = txt.trim();
        let hit = main
            .iter_mut()
            .filter(|m| (m.line.start_ms - o.line.start_ms).abs() <= MERGE_WINDOW_MS)
            .min_by_key(|m| (m.line.start_ms - o.line.start_ms).abs());
        match hit {
            Some(m) if !txt.is_empty() => {
                let ascii = txt.chars().filter(|c| c.is_ascii()).count() * 10 >= txt.chars().count() * 9;
                let main_ascii = m.line.text().chars().all(|c| c.is_ascii());
                if ascii && !main_ascii && m.line.romanization.is_none() {
                    m.line.romanization = Some(txt.to_owned());
                } else {
                    m.line.add_translation("und", txt);
                }
            }
            _ => main.push(o),
        }
    }
    t.lines = main.into_iter().map(|b| b.line).collect();
    t.finalize(duration_ms);
    t
}

#[cfg(test)]
mod tests {
    use super::*;

    const ASS: &str = "[Script Info]\nTitle: x\n\n[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n\
Comment: 0,0:00:01.00,0:00:03.00,Kanji,,0,0,0,karaoke,{\\k50}夜|よ{\\kf50}空|ぞら{\\ko30}#|ら{\\k20}に\n\
Dialogue: 0,0:00:01.00,0:00:03.00,Kanji,,0,0,0,fx,{\\pos(10,10)\\t(0,100,\\fscx120)}夜\n\
Comment: 0,0:00:01.05,0:00:03.00,Romaji,,0,0,0,karaoke,{\\k50}yo{\\k50}zo{\\k50}ra\n";

    #[test]
    fn karaoke_lines_ruby_and_effects() {
        let t = parse(ASS, None);
        assert!(t.meta.has_effects);
        assert_eq!(t.timing_quality, TimingQuality::Syllable);
        assert_eq!(t.lines.len(), 1);
        let l = &t.lines[0];
        let s: Vec<_> = l
            .syllables
            .iter()
            .map(|s| (s.text.as_str(), s.start_ms, s.end_ms, s.fill, s.ruby.as_deref()))
            .collect();
        assert_eq!(
            s,
            vec![
                ("夜", 1000, 1500, Fill::Instant, Some("よ")),
                ("空", 1500, 2300, Fill::Sweep, Some("ぞらら")),
                ("に", 2300, 2500, Fill::Instant, None),
            ]
        );
        assert_eq!(l.romanization.as_deref(), Some("yozora"));
    }

    #[test]
    fn plain_dialogue_is_line_level() {
        let t = parse("[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\nDialogue: 0,0:00:01.00,0:00:02.50,Default,,0,0,0,,{\\an8}Hello, world\\Nagain\n", None);
        assert!(!t.meta.has_effects);
        assert_eq!(t.timing_quality, TimingQuality::Line);
        assert_eq!(t.lines[0].text(), "Hello, world again");
        assert_eq!(t.lines[0].end_ms, 2500);
    }

    #[test]
    fn kt_sets_absolute_start() {
        let (s, k) = karaoke_syllables("{\\k10}a{\\kt100\\k10}b", 1000, 3000);
        assert!(k);
        assert_eq!(s[1].start_ms, 2000);
    }
}
