//! TTML（Apple Music / AMLL 方言），本模块的**规范交换格式**（导出见 [super::export]）。
//!
//! 认的结构：
//! - `<head><metadata><ttm:agent type="person|group|other" xml:id="v1"><ttm:name>..` 声部；
//! - `<p begin end ttm:agent itunes:key>`：一行；`<span begin end>` 逐字 / 逐音节，span
//!   之间的空白并进前一个音节；
//! - `<span ttm:role="x-bg">` 和声（成为紧跟主行的 `Background` 行，继承声部）；
//! - `<span ttm:role="x-translation" xml:lang>` 翻译、`x-roman` 罗马音；
//! - Apple 新方言：head 里 `iTunesMetadata/translations/translation/text[for=key]`、
//!   `transliterations/...` 按 `itunes:key` 挂到行上；
//! - TTML2 ruby：`<span tts:ruby="container"><span tts:ruby="base">漢</span><span tts:ruby="text">かん</span>`。
//!
//! 时间按绝对时间读（AMLL / Apple 产物里 `div` / `p` / `span` 都写绝对时间）。

use quick_xml::events::Event;
use quick_xml::{Reader, XmlVersion};

use super::markup::unescape;
use super::model::*;
use super::time::ttml as ttml_time;

#[derive(Debug, Default)]
pub struct El {
    pub name: String,
    pub attrs: Vec<(String, String)>,
    pub children: Vec<Node>,
}

#[derive(Debug)]
pub enum Node {
    El(El),
    Text(String),
}

impl El {
    /// 按本地名取属性（`ttm:agent` / `agent` 都认）。
    pub fn attr(&self, local: &str) -> Option<&str> {
        self.attrs.iter().find_map(|(k, v)| {
            let kl = k.rsplit(':').next().unwrap_or(k);
            (kl == local).then_some(v.as_str())
        })
    }
    pub fn elements(&self) -> impl Iterator<Item = &El> {
        self.children.iter().filter_map(|n| match n {
            Node::El(e) => Some(e),
            Node::Text(_) => None,
        })
    }
    pub fn text(&self) -> String {
        let mut s = String::new();
        collect_text(self, &mut s);
        s
    }
    fn find_all<'a>(&'a self, name: &str, out: &mut Vec<&'a El>) {
        for c in self.elements() {
            if c.name == name {
                out.push(c);
            }
            c.find_all(name, out);
        }
    }
}

fn collect_text(e: &El, out: &mut String) {
    for c in &e.children {
        match c {
            Node::Text(t) => out.push_str(t),
            Node::El(el) => collect_text(el, out),
        }
    }
}

fn local(name: &str) -> String {
    name.rsplit(':').next().unwrap_or(name).to_owned()
}

/// 解析成简易 DOM（根元素）。不是良构 XML 时返回 None。
pub fn parse_dom(text: &str) -> Option<El> {
    let mut reader = Reader::from_str(text);
    reader.config_mut().trim_text(false);
    let mut stack: Vec<El> = vec![El::default()];
    loop {
        match reader.read_event().ok()? {
            Event::Start(e) => {
                stack.push(start_el(&e));
            }
            Event::Empty(e) => {
                let el = start_el(&e);
                stack.last_mut()?.children.push(Node::El(el));
            }
            Event::End(_) => {
                let el = stack.pop()?;
                stack.last_mut()?.children.push(Node::El(el));
            }
            Event::Text(t) => push_text(stack.last_mut()?, &t.xml10_content()),
            Event::CData(t) => {
                let s = t.into_inner().into_owned();
                push_text(stack.last_mut()?, &s);
            }
            Event::GeneralRef(r) => {
                let name = r.into_inner();
                push_text(stack.last_mut()?, &unescape(&format!("&{name};")));
            }
            Event::Eof => break,
            _ => {}
        }
    }
    let root = stack.pop()?;
    if !stack.is_empty() {
        return None;
    }
    root.children.into_iter().find_map(|n| match n {
        Node::El(e) => Some(e),
        Node::Text(_) => None,
    })
}

fn push_text(el: &mut El, s: &str) {
    if s.is_empty() {
        return;
    }
    if let Some(Node::Text(prev)) = el.children.last_mut() {
        prev.push_str(s);
    } else {
        el.children.push(Node::Text(s.to_owned()));
    }
}

fn start_el(e: &quick_xml::events::BytesStart<'_>) -> El {
    let mut el = El { name: local(e.name().as_ref()), ..El::default() };
    for a in e.attributes().flatten() {
        let k = a.key.as_ref().to_owned();
        let v = a
            .normalized_value(XmlVersion::Explicit1_0)
            .map(|c| c.into_owned())
            .unwrap_or_else(|_| a.value.clone().into_owned());
        el.attrs.push((k, v));
    }
    el
}

pub fn looks_like_ttml(text: &str) -> bool {
    let head: String = text.chars().take(2048).collect();
    head.contains("<tt ") || head.contains("<tt>") || head.contains(":tt ")
}

#[derive(Default)]
struct Build {
    syllables: Vec<Syllable>,
    bg: Vec<Syllable>,
    translations: Vec<(String, String)>,
    roman: Option<String>,
    timed: bool,
}

pub fn parse(text: &str, duration_ms: Option<i64>) -> Option<Timeline> {
    let root = parse_dom(text)?;
    if root.name != "tt" {
        return None;
    }
    let mut t = Timeline::new("ttml", TimingQuality::Line);
    t.meta.language = root.attr("lang").map(str::to_owned);

    let mut agents = Vec::new();
    root.find_all("agent", &mut agents);
    for a in agents {
        let Some(id) = a.attr("id") else { continue };
        let kind = match a.attr("type") {
            Some("group") => AgentKind::Group,
            Some("other") => AgentKind::Other,
            _ => AgentKind::Person,
        };
        let idx = t.agent_index(id, kind);
        t.agents[idx].kind = kind;
        let mut names = Vec::new();
        a.find_all("name", &mut names);
        if let Some(n) = names.first() {
            t.agents[idx].name = n.text().trim().to_owned();
        }
    }

    // Apple 方言：head 里按 key 的翻译 / 音译。
    let mut keyed_tr: Vec<(String, String, String)> = Vec::new(); // (key, lang, text)
    let mut keyed_roman: Vec<(String, String)> = Vec::new();
    for (container, is_roman) in [("translation", false), ("transliteration", true)] {
        let mut nodes = Vec::new();
        root.find_all(container, &mut nodes);
        for n in nodes {
            let lang = n.attr("lang").unwrap_or("und").to_owned();
            for tx in n.elements().filter(|e| e.name == "text") {
                let Some(key) = tx.attr("for") else { continue };
                let txt = tx.text().trim().to_owned();
                if is_roman {
                    keyed_roman.push((key.to_owned(), txt));
                } else {
                    keyed_tr.push((key.to_owned(), lang.clone(), txt));
                }
            }
        }
    }

    let mut body = Vec::new();
    root.find_all("body", &mut body);
    let Some(body) = body.first() else { return Some(t) };
    let mut ps = Vec::new();
    body.find_all("p", &mut ps);
    let mut any_timed = false;
    for p in ps {
        let start = p.attr("begin").and_then(ttml_time).unwrap_or(0);
        let end = p.attr("end").and_then(ttml_time).unwrap_or(0);
        let mut b = Build::default();
        walk(p, start, end, false, &mut b);
        any_timed |= b.timed;
        let agent = p.attr("agent").map(|id| t.agent_index(id, AgentKind::Person));
        let mut line = Line {
            start_ms: start,
            end_ms: end,
            agent,
            syllables: trim_syllables(b.syllables),
            translations: Vec::new(),
            romanization: b.roman,
            ..Line::default()
        };
        for (lang, txt) in b.translations {
            line.add_translation(&lang, &txt);
        }
        if let Some(key) = p.attr("key") {
            for (k, lang, txt) in &keyed_tr {
                if k == key {
                    line.add_translation(lang, txt);
                }
            }
            if line.romanization.is_none() {
                line.romanization = keyed_roman.iter().find(|(k, _)| k == key).map(|(_, r)| r.clone());
            }
        }
        if line.syllables.is_empty() && b.bg.is_empty() {
            continue;
        }
        let bg = trim_syllables(b.bg);
        t.lines.push(line);
        if !bg.is_empty() {
            let bs = bg.iter().map(|s| s.start_ms).min().unwrap_or(start);
            let be = bg.iter().map(|s| s.end_ms).max().unwrap_or(end);
            t.lines.push(Line {
                start_ms: bs,
                end_ms: be,
                agent,
                role: Role::Background,
                syllables: bg,
                ..Line::default()
            });
        }
    }
    t.timing_quality = match root.attr("timing") {
        // 本模块导出时写的粒度（Apple 也写 None / Line / Word）。
        Some("None") => TimingQuality::Unsynced,
        Some("Line") => TimingQuality::Line,
        Some("Word") if any_timed => TimingQuality::Word,
        _ if any_timed => TimingQuality::Syllable,
        _ => TimingQuality::Line,
    };
    t.finalize(duration_ms);
    Some(t)
}

/// 去掉行首行尾的纯空白音节、修剪首尾音节的空白。
fn trim_syllables(mut v: Vec<Syllable>) -> Vec<Syllable> {
    while v.first().is_some_and(|s| s.text.trim().is_empty()) {
        v.remove(0);
    }
    while v.last().is_some_and(|s| s.text.trim().is_empty()) {
        v.pop();
    }
    if let Some(f) = v.first_mut() {
        f.text = f.text.trim_start().to_owned();
    }
    if let Some(l) = v.last_mut() {
        l.text = l.text.trim_end().to_owned();
    }
    v
}

fn walk(el: &El, inh_start: i64, inh_end: i64, in_bg: bool, b: &mut Build) {
    for c in &el.children {
        match c {
            Node::Text(txt) => {
                let target = if in_bg { &mut b.bg } else { &mut b.syllables };
                if txt.trim().is_empty() {
                    // span 之间的空白 = 词间隔，并进前一个音节。
                    if let Some(last) = target.last_mut() {
                        if !last.text.ends_with(char::is_whitespace) {
                            last.text.push(' ');
                        }
                    }
                } else {
                    let collapsed = collapse_ws(txt);
                    if let Some(last) = target.last_mut().filter(|l| l.start_ms == inh_start && l.ruby.is_none()) {
                        last.text.push_str(&collapsed);
                    } else {
                        target.push(Syllable::new(collapsed, inh_start, inh_end));
                    }
                }
            }
            Node::El(e) if e.name == "span" => {
                let role = e.attr("role");
                match role {
                    Some("x-translation") => {
                        b.translations.push((e.attr("lang").unwrap_or("und").to_owned(), e.text().trim().to_owned()));
                        continue;
                    }
                    Some("x-roman") | Some("x-romanization") => {
                        let r = e.text().trim().to_owned();
                        if !r.is_empty() && !in_bg {
                            b.roman = Some(r);
                        }
                        continue;
                    }
                    _ => {}
                }
                let s = e.attr("begin").and_then(ttml_time);
                let en = e.attr("end").and_then(ttml_time);
                let (st, et) = (s.unwrap_or(inh_start), en.unwrap_or(inh_end));
                if s.is_some() {
                    b.timed = true;
                }
                let bg = in_bg || role == Some("x-bg");
                if e.attr("ruby") == Some("container") {
                    let base: String = e.elements().filter(|c| c.attr("ruby") == Some("base")).map(El::text).collect();
                    let rt: String = e.elements().filter(|c| c.attr("ruby") == Some("text")).map(El::text).collect();
                    let base_el = e.elements().find(|c| c.attr("ruby") == Some("base"));
                    let bs = base_el.and_then(|x| x.attr("begin")).and_then(ttml_time).unwrap_or(st);
                    let be = base_el.and_then(|x| x.attr("end")).and_then(ttml_time).unwrap_or(et);
                    if base_el.and_then(|x| x.attr("begin")).is_some() {
                        b.timed = true;
                    }
                    let mut syl = Syllable::new(base, bs, be);
                    syl.ruby = (!rt.trim().is_empty()).then(|| rt.trim().to_owned());
                    if bg { b.bg.push(syl) } else { b.syllables.push(syl) }
                    continue;
                }
                let has_timed_child = e.elements().any(|c| c.attr("begin").is_some() || c.attr("ruby").is_some() || c.attr("role").is_some());
                if s.is_some() && !has_timed_child {
                    let mut syl = Syllable::new(collapse_ws(&e.text()), st, et);
                    syl.fill = Fill::Sweep;
                    if bg { b.bg.push(syl) } else { b.syllables.push(syl) }
                } else {
                    walk(e, st, et, bg, b);
                }
            }
            Node::El(e) if e.name == "br" => {
                let target = if in_bg { &mut b.bg } else { &mut b.syllables };
                if let Some(last) = target.last_mut() {
                    last.text.push(' ');
                }
            }
            Node::El(e) => walk(e, inh_start, inh_end, in_bg, b),
        }
    }
}

fn collapse_ws(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut prev_ws = false;
    for c in s.chars() {
        if c.is_whitespace() {
            if !prev_ws {
                out.push(' ');
            }
            prev_ws = true;
        } else {
            out.push(c);
            prev_ws = false;
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    const AMLL: &str = r#"<tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata" xmlns:tts="http://www.w3.org/ns/ttml#styling" xml:lang="ja"><head><metadata><ttm:agent type="person" xml:id="v1"><ttm:name type="full">A</ttm:name></ttm:agent><ttm:agent type="person" xml:id="v2"/></metadata></head><body><div><p begin="00:01.000" end="00:03.000" ttm:agent="v1"><span begin="00:01.000" end="00:01.500">Hel</span><span begin="00:01.500" end="00:02.000">lo</span> <span begin="00:02.000" end="00:03.000">world</span><span ttm:role="x-bg"><span begin="00:02.500" end="00:03.200">(ah)</span></span><span ttm:role="x-translation" xml:lang="zh-CN">你好世界</span><span ttm:role="x-roman">harou</span></p><p begin="00:04.000" end="00:05.000" ttm:agent="v2"><span tts:ruby="container" begin="00:04.000" end="00:05.000"><span tts:ruby="base">漢字</span><span tts:ruby="text">かんじ</span></span> &amp; more</p></div></body></tt>"#;

    #[test]
    fn amll_dialect() {
        let t = parse(AMLL, None).unwrap();
        assert_eq!(t.timing_quality, TimingQuality::Syllable);
        assert_eq!(t.meta.language.as_deref(), Some("ja"));
        assert_eq!(t.agents.len(), 2);
        assert_eq!(t.agents[0].name, "A");
        assert_eq!(t.lines.len(), 3);
        let l0 = &t.lines[0];
        assert_eq!(l0.text(), "Hello world");
        assert_eq!(l0.syllables[1].text, "lo ");
        assert_eq!(l0.translations, vec![("zh-CN".to_string(), "你好世界".to_string())]);
        assert_eq!(l0.romanization.as_deref(), Some("harou"));
        let bg = &t.lines[1];
        assert_eq!(bg.role, Role::Background);
        assert_eq!(bg.text(), "(ah)");
        assert_eq!(bg.agent, l0.agent);
        let l2 = &t.lines[2];
        assert_eq!(t.agents[l2.agent.unwrap()].id, "v2");
        assert_eq!(l2.syllables[0].ruby.as_deref(), Some("かんじ"));
        assert_eq!(l2.text(), "漢字 & more");
    }

    #[test]
    fn apple_head_translations_by_key() {
        let x = r#"<tt xmlns="http://www.w3.org/ns/ttml" xmlns:itunes="http://music.apple.com/lyric-ttml-internal"><head><metadata><iTunesMetadata xmlns="http://music.apple.com/lyric-ttml-internal"><translations><translation xml:lang="en"><text for="L1">Hi</text></translation></translations></iTunesMetadata></metadata></head><body><div><p begin="1.0" end="2.0" itunes:key="L1">やあ</p></div></body></tt>"#;
        let t = parse(x, None).unwrap();
        assert_eq!(t.timing_quality, TimingQuality::Line);
        assert_eq!(t.lines[0].text(), "やあ");
        assert_eq!(t.lines[0].translations, vec![("en".to_string(), "Hi".to_string())]);
    }
}
