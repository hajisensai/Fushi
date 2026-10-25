//! 时间轴导出（设计 §6.4「可导出为原格式或 TTML」）：
//! - **TTML**（AMLL 方言，规范交换格式）：声部、逐音节 span、ruby、和声、翻译、罗马音全保留，
//!   用本模块的 [super::ttml::parse] 读回无损（见往返测试）；
//! - **LRC**：行级 `[mm:ss.xx]`，词级以上用增强 LRC（A2 `<mm:ss.xx>`）；翻译写成同时间戳的
//!   下一行（本模块 LRC 解析器读回成翻译）。和声 / 声部 / ruby 在 LRC 里没有位置，丢弃。
//!
//! 其它原格式（ASS / KRC / QRC …）的「导出原格式」= 原始字节（`music_lyrics.raw`），
//! 编辑过的歌词只能导出成 LRC / TTML。

use super::model::*;

fn esc(s: &str) -> String {
    s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;")
}

fn ttml_time(ms: i64) -> String {
    let ms = ms.max(0);
    let h = ms / 3_600_000;
    let m = ms / 60_000 % 60;
    let s = ms / 1000 % 60;
    let f = ms % 1000;
    if h > 0 {
        format!("{h}:{m:02}:{s:02}.{f:03}")
    } else {
        format!("{m:02}:{s:02}.{f:03}")
    }
}

fn lrc_time(ms: i64) -> String {
    let ms = ms.max(0);
    let m = ms / 60_000;
    let s = ms / 1000 % 60;
    let cs = ms % 1000 / 10;
    format!("{m:02}:{s:02}.{cs:02}")
}

pub fn to_ttml(t: &Timeline) -> String {
    let mut o = String::new();
    o.push_str("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
    o.push_str("<tt xmlns=\"http://www.w3.org/ns/ttml\" xmlns:ttm=\"http://www.w3.org/ns/ttml#metadata\" xmlns:tts=\"http://www.w3.org/ns/ttml#styling\" xmlns:itunes=\"http://music.apple.com/lyric-ttml-internal\"");
    // Apple 的 `itunes:timing`（None / Line / Word）；音节级写 `Syllable`，本模块读回时据此还原粒度。
    let timing = match t.timing_quality {
        TimingQuality::Unsynced => "None",
        TimingQuality::Line => "Line",
        TimingQuality::Word => "Word",
        TimingQuality::Syllable | TimingQuality::SyllablePitch => "Syllable",
    };
    o.push_str(&format!(" itunes:timing=\"{timing}\""));
    if let Some(lang) = &t.meta.language {
        o.push_str(&format!(" xml:lang=\"{}\"", esc(lang)));
    }
    o.push_str("><head><metadata>");
    for a in &t.agents {
        let kind = match a.kind {
            AgentKind::Person => "person",
            AgentKind::Group => "group",
            AgentKind::Other => "other",
        };
        o.push_str(&format!("<ttm:agent type=\"{kind}\" xml:id=\"{}\"", esc(&a.id)));
        if a.name.is_empty() {
            o.push_str("/>");
        } else {
            o.push_str(&format!("><ttm:name type=\"full\">{}</ttm:name></ttm:agent>", esc(&a.name)));
        }
    }
    o.push_str("</metadata></head><body><div>");
    let timed = t.timing_quality >= TimingQuality::Word;
    let mut i = 0;
    while i < t.lines.len() {
        let l = &t.lines[i];
        o.push_str(&format!("<p begin=\"{}\" end=\"{}\"", ttml_time(l.start_ms), ttml_time(l.end_ms)));
        if let Some(a) = l.agent.and_then(|a| t.agents.get(a)) {
            o.push_str(&format!(" ttm:agent=\"{}\"", esc(&a.id)));
        }
        o.push('>');
        if l.role == Role::Background {
            o.push_str("<span ttm:role=\"x-bg\">");
            push_syllables(&mut o, l, true);
            o.push_str("</span>");
        } else {
            // 行级歌词被注音切开的音节也要带时间，否则读回后切分点丢失。
            push_syllables(&mut o, l, timed || l.syllables.len() > 1);
        }
        // 紧跟的和声行收进同一个 <p>。
        let mut j = i + 1;
        while l.role == Role::Main && j < t.lines.len() && t.lines[j].role == Role::Background {
            o.push_str("<span ttm:role=\"x-bg\">");
            push_syllables(&mut o, &t.lines[j], true);
            o.push_str("</span>");
            j += 1;
        }
        for (lang, text) in &l.translations {
            o.push_str(&format!("<span ttm:role=\"x-translation\" xml:lang=\"{}\">{}</span>", esc(lang), esc(text)));
        }
        if let Some(r) = &l.romanization {
            o.push_str(&format!("<span ttm:role=\"x-roman\">{}</span>", esc(r)));
        }
        o.push_str("</p>");
        i = j;
    }
    o.push_str("</div></body></tt>\n");
    o
}

fn push_syllables(o: &mut String, l: &Line, timed: bool) {
    for s in &l.syllables {
        let trimmed = s.text.trim_end();
        let trailing = trimmed.len() < s.text.len();
        let leading = s.text.len() - s.text.trim_start().len();
        if leading > 0 {
            o.push(' ');
        }
        let body = trimmed.trim_start();
        let times = if timed {
            format!(" begin=\"{}\" end=\"{}\"", ttml_time(s.start_ms), ttml_time(s.end_ms))
        } else {
            String::new()
        };
        match &s.ruby {
            Some(r) => o.push_str(&format!(
                "<span tts:ruby=\"container\"{times}><span tts:ruby=\"base\">{}</span><span tts:ruby=\"text\">{}</span></span>",
                esc(body),
                esc(r)
            )),
            None if timed => o.push_str(&format!("<span{times}>{}</span>", esc(body))),
            None => o.push_str(&esc(body)),
        }
        if trailing {
            o.push(' ');
        }
    }
}

pub fn to_lrc(t: &Timeline) -> String {
    let mut o = String::new();
    if let Some(ti) = &t.meta.title {
        o.push_str(&format!("[ti:{ti}]\n"));
    }
    if let Some(ar) = &t.meta.artist {
        o.push_str(&format!("[ar:{ar}]\n"));
    }
    let word = t.timing_quality >= TimingQuality::Word;
    let unsynced = t.timing_quality == TimingQuality::Unsynced;
    for l in t.lines.iter().filter(|l| l.role == Role::Main) {
        if unsynced {
            o.push_str(&l.text());
            o.push('\n');
            continue;
        }
        o.push_str(&format!("[{}]", lrc_time(l.start_ms)));
        if word && l.syllables.len() > 1 {
            for s in &l.syllables {
                o.push_str(&format!("<{}>{}", lrc_time(s.start_ms), s.text));
            }
            o.push_str(&format!("<{}>", lrc_time(l.end_ms)));
        } else {
            o.push_str(&l.text());
        }
        o.push('\n');
        for (_, text) in &l.translations {
            for tl in text.lines() {
                o.push_str(&format!("[{}]{}\n", lrc_time(l.start_ms), tl));
            }
        }
    }
    o
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample() -> Timeline {
        let mut t = Timeline::new("ttml", TimingQuality::Syllable);
        t.meta.language = Some("ja".into());
        let v1 = t.agent_index("v1", AgentKind::Person);
        let mut l = Line::default();
        l.start_ms = 1000;
        l.end_ms = 3000;
        l.agent = Some(v1);
        l.syllables = vec![Syllable::new("Hel", 1000, 1500), Syllable::new("lo ", 1500, 2000), Syllable::new("世界", 2000, 3000)];
        l.syllables[2].ruby = Some("せかい".into());
        l.add_translation("zh-CN", "你好 & 世界");
        l.romanization = Some("harou sekai".into());
        t.lines.push(l);
        let mut bg = Line::default();
        bg.start_ms = 2500;
        bg.end_ms = 3200;
        bg.agent = Some(v1);
        bg.role = Role::Background;
        bg.syllables = vec![Syllable::new("(ah)", 2500, 3200)];
        t.lines.push(bg);
        t.finalize(None);
        t
    }

    #[test]
    fn ttml_round_trip_is_lossless() {
        let t = sample();
        let back = super::super::ttml::parse(&to_ttml(&t), None).unwrap();
        assert_eq!(back.lines, t.lines);
        assert_eq!(back.agents, t.agents);
        assert_eq!(back.timing_quality, TimingQuality::Syllable);
    }

    #[test]
    fn lrc_round_trip_keeps_words_and_translation() {
        let t = sample();
        let lrc = to_lrc(&t);
        assert!(lrc.contains("[00:01.00]<00:01.00>Hel<00:01.50>lo <00:02.00>世界<00:03.00>"));
        let back = super::super::lrc::parse(&lrc, None);
        assert_eq!(back.lines.len(), 1);
        assert_eq!(back.lines[0].text(), "Hello 世界");
        assert_eq!(back.lines[0].translations[0].1, "你好 & 世界");
    }
}
