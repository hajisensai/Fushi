//! `LyricTimeline` 的紧凑二进制（小端）。Dart 侧 `packages/fushi_music/lib/src/lyric_timeline.dart`
//! 逐字段对应（双向：Dart 也写，用于用户编辑后回存 `timeline_cache`）。
//!
//! ```text
//! timeline := "FMLT" | u32 version (= TIMELINE_WIRE_VERSION)
//!           | str source | str format | i64 offsetMs | opt_str language
//!           | u8 timingQuality | u8 flags(bit0 isUserEdited, bit1 hasEffects)
//!           | opt_str title | opt_str artist
//!           | u32 agentCount | (str id | str name | u8 kind)*agentCount
//!           | u32 lineCount | line*lineCount
//! line     := i64 startMs | i64 endMs | i32 agent(-1 = 无) | u8 role(0 主 / 1 和声)
//!           | u32 syllableCount | (str text | i64 startMs | i64 endMs | u8 fill | opt_str ruby)*
//!           | u32 translationCount | (str lang | str text)*
//!           | opt_str romanization | opt_str style
//! str      := u32 byteLen | utf8
//! opt_str  := u32 byteLen（0xFFFFFFFF = null）| utf8
//! ```
//!
//! 时间一律 i64 毫秒（与扫描批次同口径）。整首一次跨 FFI，渲染层逐帧不再回 Rust。

use super::model::*;

/// 线格式版本。改字段必须升它，并同步 Dart 解码器与 [super::PARSER_VERSION]。
pub const TIMELINE_WIRE_VERSION: u32 = 1;
pub const MAGIC: &[u8; 4] = b"FMLT";

pub struct Writer {
    pub buf: Vec<u8>,
}

impl Writer {
    pub fn new() -> Self {
        Writer { buf: Vec::with_capacity(4096) }
    }
    pub fn u8(&mut self, v: u8) {
        self.buf.push(v);
    }
    pub fn u32(&mut self, v: u32) {
        self.buf.extend_from_slice(&v.to_le_bytes());
    }
    pub fn i32(&mut self, v: i32) {
        self.buf.extend_from_slice(&v.to_le_bytes());
    }
    pub fn i64(&mut self, v: i64) {
        self.buf.extend_from_slice(&v.to_le_bytes());
    }
    pub fn str(&mut self, s: &str) {
        self.u32(s.len() as u32);
        self.buf.extend_from_slice(s.as_bytes());
    }
    pub fn opt_str(&mut self, s: Option<&str>) {
        match s {
            Some(s) => self.str(s),
            None => self.u32(u32::MAX),
        }
    }
}

impl Default for Writer {
    fn default() -> Self {
        Self::new()
    }
}

pub struct Reader<'a> {
    data: &'a [u8],
    pos: usize,
}

impl<'a> Reader<'a> {
    pub fn new(data: &'a [u8]) -> Self {
        Reader { data, pos: 0 }
    }
    fn take(&mut self, n: usize) -> Option<&'a [u8]> {
        let end = self.pos.checked_add(n)?;
        let s = self.data.get(self.pos..end)?;
        self.pos = end;
        Some(s)
    }
    pub fn u8(&mut self) -> Option<u8> {
        self.take(1).map(|b| b[0])
    }
    pub fn u32(&mut self) -> Option<u32> {
        self.take(4).map(|b| u32::from_le_bytes(b.try_into().unwrap()))
    }
    pub fn i32(&mut self) -> Option<i32> {
        self.take(4).map(|b| i32::from_le_bytes(b.try_into().unwrap()))
    }
    pub fn i64(&mut self) -> Option<i64> {
        self.take(8).map(|b| i64::from_le_bytes(b.try_into().unwrap()))
    }
    pub fn str(&mut self) -> Option<String> {
        let n = self.u32()? as usize;
        let b = self.take(n)?;
        String::from_utf8(b.to_vec()).ok()
    }
    pub fn opt_str(&mut self) -> Option<Option<String>> {
        let n = self.u32()?;
        if n == u32::MAX {
            return Some(None);
        }
        let b = self.take(n as usize)?;
        Some(Some(String::from_utf8(b.to_vec()).ok()?))
    }
    pub fn at_end(&self) -> bool {
        self.pos == self.data.len()
    }
}

pub fn encode(t: &Timeline) -> Vec<u8> {
    let mut w = Writer::new();
    w.buf.extend_from_slice(MAGIC);
    w.u32(TIMELINE_WIRE_VERSION);
    w.str(&t.meta.source);
    w.str(&t.meta.format);
    w.i64(t.meta.offset_ms);
    w.opt_str(t.meta.language.as_deref());
    w.u8(t.timing_quality.to_u8());
    w.u8((t.meta.is_user_edited as u8) | ((t.meta.has_effects as u8) << 1));
    w.opt_str(t.meta.title.as_deref());
    w.opt_str(t.meta.artist.as_deref());
    w.u32(t.agents.len() as u32);
    for a in &t.agents {
        w.str(&a.id);
        w.str(&a.name);
        w.u8(a.kind.to_u8());
    }
    w.u32(t.lines.len() as u32);
    for l in &t.lines {
        w.i64(l.start_ms);
        w.i64(l.end_ms);
        w.i32(l.agent.map(|a| a as i32).unwrap_or(-1));
        w.u8(match l.role {
            Role::Main => 0,
            Role::Background => 1,
        });
        w.u32(l.syllables.len() as u32);
        for s in &l.syllables {
            w.str(&s.text);
            w.i64(s.start_ms);
            w.i64(s.end_ms);
            w.u8(s.fill.to_u8());
            w.opt_str(s.ruby.as_deref());
        }
        w.u32(l.translations.len() as u32);
        for (lang, text) in &l.translations {
            w.str(lang);
            w.str(text);
        }
        w.opt_str(l.romanization.as_deref());
        w.opt_str(l.style.as_deref());
    }
    w.buf
}

pub fn decode(data: &[u8]) -> Option<Timeline> {
    let mut r = Reader::new(data);
    if r.take(4)? != MAGIC {
        return None;
    }
    if r.u32()? != TIMELINE_WIRE_VERSION {
        return None;
    }
    let mut t = Timeline::default();
    t.meta.source = r.str()?;
    t.meta.format = r.str()?;
    t.meta.offset_ms = r.i64()?;
    t.meta.language = r.opt_str()?;
    t.timing_quality = TimingQuality::from_u8(r.u8()?);
    let flags = r.u8()?;
    t.meta.is_user_edited = flags & 1 != 0;
    t.meta.has_effects = flags & 2 != 0;
    t.meta.title = r.opt_str()?;
    t.meta.artist = r.opt_str()?;
    let agents = r.u32()? as usize;
    for _ in 0..agents {
        let id = r.str()?;
        let name = r.str()?;
        let kind = AgentKind::from_u8(r.u8()?);
        t.agents.push(Agent { id, name, kind });
    }
    let lines = r.u32()? as usize;
    for _ in 0..lines {
        let start_ms = r.i64()?;
        let end_ms = r.i64()?;
        let agent = r.i32()?;
        let role = if r.u8()? == 1 { Role::Background } else { Role::Main };
        let mut line = Line {
            start_ms,
            end_ms,
            agent: (agent >= 0 && (agent as usize) < t.agents.len()).then_some(agent as usize),
            role,
            ..Line::default()
        };
        let syl = r.u32()? as usize;
        for _ in 0..syl {
            let text = r.str()?;
            let start_ms = r.i64()?;
            let end_ms = r.i64()?;
            let fill = Fill::from_u8(r.u8()?);
            let ruby = r.opt_str()?;
            line.syllables.push(Syllable { text, start_ms, end_ms, fill, ruby });
        }
        let tr = r.u32()? as usize;
        for _ in 0..tr {
            let lang = r.str()?;
            let text = r.str()?;
            line.translations.push((lang, text));
        }
        line.romanization = r.opt_str()?;
        line.style = r.opt_str()?;
        t.lines.push(line);
    }
    r.at_end().then_some(t)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips() {
        let mut t = Timeline::new("ttml", TimingQuality::Syllable);
        t.meta.source = "sidecar".into();
        t.meta.language = Some("ja".into());
        t.meta.has_effects = true;
        let a = t.agent_index("v1", AgentKind::Person);
        let mut l = Line::whole("漢字", 10, 20);
        l.agent = Some(a);
        l.syllables[0].ruby = Some("かんじ".into());
        l.syllables[0].fill = Fill::Outline;
        l.add_translation("zh", "汉字");
        l.romanization = Some("kanji".into());
        t.lines.push(l);
        let bytes = encode(&t);
        assert_eq!(decode(&bytes), Some(t));
        assert_eq!(decode(&bytes[..bytes.len() - 1]), None);
    }
}
