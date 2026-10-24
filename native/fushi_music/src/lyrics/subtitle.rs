//! 行级字幕格式当歌词：SRT、WebVTT（含 cue 内时间戳 → 词级、`<v>` 声部、`<ruby>`）、SAMI。
//!
//! 多行 cue：第一行是正文，其后各行当翻译（双语歌词字幕的常见形态）。

use super::markup::{strip_tags, tokenize, unescape, Tok};
use super::model::*;
use super::time::clock;

fn parse_arrow(line: &str) -> Option<(i64, i64)> {
    let (a, b) = line.split_once("-->")?;
    let start = clock(a)?;
    // VTT 的 cue 设置跟在终点后面（`00:04.000 align:start`）。
    let end_tok = b.split_whitespace().next()?;
    Some((start, clock(end_tok)?))
}

pub fn looks_like_srt(text: &str) -> bool {
    text.lines().take(50).any(|l| {
        l.contains("-->") && parse_arrow(l).is_some()
    })
}

/// 去掉 SRT 里的 ASS 风格覆盖块 `{\an8}`。
fn strip_braces(s: &str) -> String {
    let mut out = String::new();
    let mut depth = 0;
    for c in s.chars() {
        match c {
            '{' => depth += 1,
            '}' if depth > 0 => depth -= 1,
            _ if depth == 0 => out.push(c),
            _ => {}
        }
    }
    out
}

pub fn parse_srt(text: &str, duration_ms: Option<i64>) -> Timeline {
    let mut t = Timeline::new("srt", TimingQuality::Line);
    for block in text.split("\n\n") {
        let mut lines = block.lines().map(str::trim).filter(|l| !l.is_empty());
        let mut timing = None;
        for l in lines.by_ref() {
            if let Some(tm) = parse_arrow(l) {
                timing = Some(tm);
                break;
            }
        }
        let Some((start, end)) = timing else { continue };
        let body: Vec<String> = lines
            .map(|l| strip_braces(&strip_tags(l)).trim().to_owned())
            .filter(|l| !l.is_empty())
            .collect();
        push_multiline(&mut t, start, end, &body);
    }
    t.finalize(duration_ms);
    t
}

fn push_multiline(t: &mut Timeline, start: i64, end: i64, body: &[String]) {
    let Some(first) = body.first() else { return };
    let mut line = Line::whole(first.as_str(), start, end);
    for extra in &body[1..] {
        line.add_translation("und", extra);
    }
    t.lines.push(line);
}

pub fn parse_vtt(text: &str, duration_ms: Option<i64>) -> Timeline {
    let mut t = Timeline::new("vtt", TimingQuality::Line);
    let mut quality = TimingQuality::Line;
    for block in text.split("\n\n") {
        let mut lines = block.lines().peekable();
        let first = lines.peek().map(|l| l.trim()).unwrap_or("");
        if first.starts_with("WEBVTT") || first.starts_with("NOTE") || first == "STYLE" || first == "REGION" {
            continue;
        }
        let mut timing = None;
        for l in lines.by_ref() {
            if let Some(tm) = parse_arrow(l) {
                timing = Some(tm);
                break;
            }
        }
        let Some((start, end)) = timing else { continue };
        let payload: Vec<&str> = lines.map(str::trim).filter(|l| !l.is_empty()).collect();
        let Some(main) = payload.first() else { continue };
        let (mut line, voice, timed) = vtt_payload(main, start, end);
        if timed {
            quality = TimingQuality::Word;
        }
        if let Some(v) = voice {
            line.agent = Some(t.agent_index(&v, AgentKind::Person));
            if let Some(a) = t.agents.last_mut().filter(|a| a.id == v) {
                a.name = v.clone();
            }
        }
        for extra in &payload[1..] {
            line.add_translation("und", strip_tags(extra).trim());
        }
        if line.syllables.iter().any(|s| !s.text.trim().is_empty()) {
            t.lines.push(line);
        }
    }
    t.timing_quality = quality;
    t.finalize(duration_ms);
    t
}

/// 一行 VTT 正文 → (行, 声部, 是否带 cue 内时间戳)。
fn vtt_payload(s: &str, start: i64, end: i64) -> (Line, Option<String>, bool) {
    let mut line = Line { start_ms: start, end_ms: end, ..Line::default() };
    let mut voice = None;
    let mut timed = false;
    let mut seg_start = start;
    let mut in_rt = false;
    let mut ruby_base = String::new();
    let mut ruby_text = String::new();
    let mut in_ruby = false;
    for tok in tokenize(s) {
        match tok {
            Tok::Text(txt) => {
                if in_rt {
                    ruby_text.push_str(&txt);
                } else if in_ruby {
                    ruby_base.push_str(&txt);
                } else {
                    push_text(&mut line, &txt, seg_start);
                }
            }
            Tok::Tag { name, attrs } => {
                let full = format!("{name}{attrs}");
                if let Some(ms) = clock(&full).filter(|_| name.contains(':')) {
                    timed = true;
                    seg_start = ms;
                    continue;
                }
                match name.as_str() {
                    "v" => voice = Some(attrs.trim().to_owned()).filter(|v| !v.is_empty()),
                    "ruby" => {
                        in_ruby = true;
                        ruby_base.clear();
                        ruby_text.clear();
                    }
                    "rt" => in_rt = true,
                    "/rt" => in_rt = false,
                    "/ruby" => {
                        in_ruby = false;
                        if !ruby_base.is_empty() {
                            let mut syl = Syllable::new(std::mem::take(&mut ruby_base), seg_start, 0);
                            let r = std::mem::take(&mut ruby_text);
                            syl.ruby = (!r.trim().is_empty()).then(|| r.trim().to_owned());
                            line.syllables.push(syl);
                        }
                    }
                    _ => {}
                }
            }
        }
    }
    if !timed {
        // 没有时间戳：整行一个音节，但保留 ruby 段（按字数平分）。
        for s in &mut line.syllables {
            s.start_ms = start;
        }
    }
    spread_shared_starts(&mut line);
    (line, voice, timed)
}

fn push_text(line: &mut Line, txt: &str, start: i64) {
    if txt.is_empty() {
        return;
    }
    // 同一段（同起点、无 ruby）的文本并到上一个音节。
    if let Some(last) = line.syllables.last_mut() {
        if last.start_ms == start && last.ruby.is_none() {
            last.text.push_str(txt);
            return;
        }
    }
    line.syllables.push(Syllable::new(txt, start, 0));
}

pub fn looks_like_sami(text: &str) -> bool {
    let head: String = text.chars().take(4096).collect::<String>().to_ascii_lowercase();
    head.contains("<sami") || head.contains("<sync")
}

/// SAMI：`<SYNC Start=ms>` 之间的 `<P Class=XX>` 段。第一个出现的 class 是正文，其余
/// class 当翻译（语言取 STYLE 里 `.CLASS { lang: xx }`，没有就用 class 名）。
pub fn parse_sami(text: &str, duration_ms: Option<i64>) -> Timeline {
    let lower = text.to_ascii_lowercase();
    let langs = sami_class_langs(text);
    let mut syncs: Vec<(i64, usize, usize)> = Vec::new();
    let mut search = 0;
    while let Some(p) = lower[search..].find("<sync") {
        let at = search + p;
        let Some(close) = lower[at..].find('>') else { break };
        let tag = &lower[at..at + close];
        let start = attr_value(tag, "start").and_then(|v| v.parse::<i64>().ok());
        let body_start = at + close + 1;
        let body_end = lower[body_start..]
            .find("<sync")
            .map(|q| body_start + q)
            .or_else(|| lower[body_start..].find("</body").map(|q| body_start + q))
            .unwrap_or(text.len());
        if let Some(st) = start {
            syncs.push((st, body_start, body_end));
        }
        search = body_start;
    }
    let mut primary: Option<String> = None;
    let mut t = Timeline::new("sami", TimingQuality::Line);
    for (i, &(start, b0, b1)) in syncs.iter().enumerate() {
        let end = syncs.get(i + 1).map(|s| s.0).unwrap_or(0);
        let body = &text[b0..b1];
        let mut line: Option<Line> = None;
        for (class, content) in sami_paragraphs(body) {
            let txt = unescape(&strip_tags(&content.replace("<br>", "\n").replace("<BR>", "\n")))
                .replace('\u{a0}', " ");
            let txt = txt.trim();
            if txt.is_empty() {
                continue;
            }
            let primary_class = primary.get_or_insert_with(|| class.clone()).clone();
            if class == primary_class && line.is_none() {
                let mut l = Line::whole(txt, start, end);
                if let Some((first, rest)) = txt.split_once('\n') {
                    l = Line::whole(first.trim(), start, end);
                    l.add_translation("und", rest);
                }
                line = Some(l);
            } else if let Some(l) = line.as_mut() {
                let lang = langs
                    .iter()
                    .find(|(c, _)| *c == class)
                    .map(|(_, l)| l.clone())
                    .unwrap_or_else(|| class.clone());
                l.add_translation(&lang, txt);
            }
        }
        if let Some(l) = line {
            t.lines.push(l);
        }
    }
    t.finalize(duration_ms);
    t
}

fn attr_value(tag: &str, key: &str) -> Option<String> {
    let i = tag.find(key)?;
    let rest = tag[i + key.len()..].trim_start().strip_prefix('=')?.trim_start();
    let v: String = if let Some(r) = rest.strip_prefix('"') {
        r.chars().take_while(|&c| c != '"').collect()
    } else {
        rest.chars().take_while(|c| !c.is_whitespace() && *c != '>').collect()
    };
    Some(v)
}

/// 一个 SYNC 体里的 (class 小写, 原文) 段。没有 `<P>` 时整段当 class ""。
fn sami_paragraphs(body: &str) -> Vec<(String, String)> {
    let lower = body.to_ascii_lowercase();
    let mut out = Vec::new();
    let mut idx = 0;
    let mut found = false;
    while let Some(p) = lower[idx..].find("<p") {
        let at = idx + p;
        // 只认 `<p>` / `<p ` 开头，避免 `<param>`。
        let next = lower.as_bytes().get(at + 2).copied().unwrap_or(b'>');
        if next != b'>' && !next.is_ascii_whitespace() {
            idx = at + 2;
            continue;
        }
        let Some(close) = lower[at..].find('>') else { break };
        let class = attr_value(&lower[at..at + close], "class").unwrap_or_default();
        let c0 = at + close + 1;
        let c1 = lower[c0..]
            .find("<p")
            .map(|q| c0 + q)
            .unwrap_or(body.len());
        let content = body[c0..c1].replace("</P>", "").replace("</p>", "");
        out.push((class, content));
        found = true;
        idx = c0;
    }
    if !found {
        out.push((String::new(), body.to_owned()));
    }
    out
}

fn sami_class_langs(text: &str) -> Vec<(String, String)> {
    let lower = text.to_ascii_lowercase();
    let Some(s0) = lower.find("<style") else { return Vec::new() };
    let s1 = lower[s0..].find("</style").map(|e| s0 + e).unwrap_or(lower.len());
    let style = &lower[s0..s1];
    let mut out = Vec::new();
    let mut rest = style;
    while let Some(dot) = rest.find('.') {
        let after = &rest[dot + 1..];
        let Some(open) = after.find('{') else { break };
        let Some(close) = after[open..].find('}') else { break };
        let class = after[..open].trim().to_owned();
        let body = &after[open + 1..open + close];
        if let Some(lp) = body.find("lang") {
            let v: String = body[lp + 4..]
                .trim_start()
                .trim_start_matches(':')
                .trim()
                .chars()
                .take_while(|&c| c != ';' && c != '}')
                .collect();
            if !class.is_empty() && !class.contains(char::is_whitespace) {
                out.push((class, v.trim().to_owned()));
            }
        }
        rest = &after[open + close..];
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn srt_two_lines_become_translation() {
        let t = parse_srt("1\n00:00:01,000 --> 00:00:03,500\n<i>Hello</i>\n你好\n\n2\n00:00:04,000 --> 00:00:05,000\n{\\an8}Bye\n", None);
        assert_eq!(t.lines.len(), 2);
        assert_eq!(t.lines[0].text(), "Hello");
        assert_eq!(t.lines[0].translations[0].1, "你好");
        assert_eq!((t.lines[1].start_ms, t.lines[1].end_ms), (4000, 5000));
        assert_eq!(t.lines[1].text(), "Bye");
    }

    #[test]
    fn vtt_cue_timestamps_voice_and_ruby() {
        let t = parse_vtt(
            "WEBVTT\n\nNOTE x\n\n00:01.000 --> 00:03.000\n<v Alice>Hel<00:01.500>lo <00:02.000><ruby>世<rt>せ</rt></ruby>界\n",
            None,
        );
        assert_eq!(t.timing_quality, TimingQuality::Word);
        let l = &t.lines[0];
        assert_eq!(t.agents[l.agent.unwrap()].id, "Alice");
        let s: Vec<_> = l.syllables.iter().map(|s| (s.text.as_str(), s.start_ms, s.ruby.as_deref())).collect();
        assert_eq!(s, vec![("Hel", 1000, None), ("lo ", 1500, None), ("世", 2000, Some("せ")), ("界", 2500, None)]);
    }

    #[test]
    fn sami_classes() {
        let t = parse_sami(
            "<SAMI><HEAD><STYLE>.JPCC { lang: ja-JP; } .ENCC { lang: en-US; }</STYLE></HEAD><BODY>\
             <SYNC Start=1000><P Class=JPCC>こんにちは<P Class=ENCC>Hello\
             <SYNC Start=3000><P Class=JPCC>&nbsp;\
             <SYNC Start=4000><P Class=JPCC>さよなら</BODY></SAMI>",
            Some(6000),
        );
        assert_eq!(t.lines.len(), 2);
        assert_eq!((t.lines[0].start_ms, t.lines[0].end_ms), (1000, 3000));
        assert_eq!(t.lines[0].translations, vec![("en-us".to_string(), "Hello".to_string())]);
        assert_eq!(t.lines[1].end_ms, 6000);
    }
}
