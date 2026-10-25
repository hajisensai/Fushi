//! 统一歌词时间轴 `LyricTimeline`（设计 §5.2）。所有格式解析后都落成这一个模型；
//! 行级歌词也是：每行一个「整行音节」，`timing_quality = Line`。

/// 音节擦色语义（ASS `\k` / `\kf` / `\ko`）。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Fill {
    /// `\k`：到点整字瞬间变色。
    Instant,
    /// `\kf` / `\K`：从左到右羽化擦色（逐字歌词的默认语义）。
    #[default]
    Sweep,
    /// `\ko`：只描边。
    Outline,
}

impl Fill {
    pub fn to_u8(self) -> u8 {
        match self {
            Fill::Instant => 0,
            Fill::Sweep => 1,
            Fill::Outline => 2,
        }
    }

    pub fn from_u8(v: u8) -> Self {
        match v {
            0 => Fill::Instant,
            2 => Fill::Outline,
            _ => Fill::Sweep,
        }
    }
}

/// 行角色：主唱 / `x-bg` 和声（背景人声）。和声行紧跟在它所属的主行后面。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Role {
    #[default]
    Main,
    Background,
}

/// 时间粒度。`Unsynced` = 没有任何时间（纯文本 / USLT 非 LRC），只做静态显示。
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Default)]
pub enum TimingQuality {
    Unsynced,
    #[default]
    Line,
    Word,
    Syllable,
    /// 源文件带音高（UltraStar / MIDI）；音高本身不进模型（设计 §5.1）。
    SyllablePitch,
}

impl TimingQuality {
    pub fn to_u8(self) -> u8 {
        match self {
            TimingQuality::Unsynced => 0,
            TimingQuality::Line => 1,
            TimingQuality::Word => 2,
            TimingQuality::Syllable => 3,
            TimingQuality::SyllablePitch => 4,
        }
    }

    pub fn from_u8(v: u8) -> Self {
        match v {
            0 => TimingQuality::Unsynced,
            2 => TimingQuality::Word,
            3 => TimingQuality::Syllable,
            4 => TimingQuality::SyllablePitch,
            _ => TimingQuality::Line,
        }
    }

    /// DB `music_lyrics.timing_quality` 的取值。
    pub fn db_name(self) -> &'static str {
        match self {
            TimingQuality::Unsynced => "unsynced",
            TimingQuality::Line => "line",
            TimingQuality::Word => "word",
            TimingQuality::Syllable => "syllable",
            TimingQuality::SyllablePitch => "syllable_pitch",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum AgentKind {
    #[default]
    Person,
    /// 合唱 / 组合（渲染居中）。
    Group,
    Other,
}

impl AgentKind {
    pub fn to_u8(self) -> u8 {
        match self {
            AgentKind::Person => 0,
            AgentKind::Group => 1,
            AgentKind::Other => 2,
        }
    }

    pub fn from_u8(v: u8) -> Self {
        match v {
            1 => AgentKind::Group,
            2 => AgentKind::Other,
            _ => AgentKind::Person,
        }
    }
}

/// 对唱声部（TTML `ttm:agent`、UltraStar `P1`/`P2`、LYS 左 / 右、VTT `<v>`）。
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Agent {
    pub id: String,
    pub name: String,
    pub kind: AgentKind,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Syllable {
    pub text: String,
    pub start_ms: i64,
    pub end_ms: i64,
    pub fill: Fill,
    pub ruby: Option<String>,
}

impl Syllable {
    pub fn new(text: impl Into<String>, start_ms: i64, end_ms: i64) -> Self {
        Syllable {
            text: text.into(),
            start_ms,
            end_ms,
            fill: Fill::Sweep,
            ruby: None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Line {
    pub start_ms: i64,
    pub end_ms: i64,
    /// [Timeline::agents] 下标。
    pub agent: Option<usize>,
    pub role: Role,
    pub syllables: Vec<Syllable>,
    /// (语言标签, 译文)。语言未知用 `und`。
    pub translations: Vec<(String, String)>,
    pub romanization: Option<String>,
    /// 来自 ASS 时的样式名（原样渲染用的样式指针）。
    pub style: Option<String>,
}

impl Line {
    /// 整行文本（音节拼接）。
    pub fn text(&self) -> String {
        self.syllables.iter().map(|s| s.text.as_str()).collect()
    }

    /// 只有一个「整行音节」的行。
    pub fn whole(text: impl Into<String>, start_ms: i64, end_ms: i64) -> Self {
        Line {
            start_ms,
            end_ms,
            syllables: vec![Syllable::new(text, start_ms, end_ms)],
            ..Line::default()
        }
    }

    pub fn add_translation(&mut self, lang: &str, text: &str) {
        let text = text.trim();
        if text.is_empty() {
            return;
        }
        let lang = if lang.trim().is_empty() { "und" } else { lang.trim() };
        if let Some(slot) = self.translations.iter_mut().find(|(l, _)| l == lang) {
            if slot.1.is_empty() {
                slot.1 = text.to_owned();
            } else {
                slot.1.push('\n');
                slot.1.push_str(text);
            }
        } else {
            self.translations.push((lang.to_owned(), text.to_owned()));
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Meta {
    /// 来源（`sidecar` / `embedded` / `provider:lrclib` / `user` …），由调用方填。
    pub source: String,
    /// 原格式（`lrc` / `ttml` / `ass` / `krc` …）。
    pub format: String,
    /// 整首偏移（毫秒，正 = 歌词提前）。解析时文件自带的 `[offset:]` 已烘进时间，这里是
    /// 用户微调值，由调用方填。
    pub offset_ms: i64,
    pub language: Option<String>,
    pub is_user_edited: bool,
    /// ASS 里检测到 `\t` `\move` `\clip` 等特效 / templater 产物：推荐原样渲染（§6.3）。
    pub has_effects: bool,
    pub title: Option<String>,
    pub artist: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Timeline {
    pub meta: Meta,
    pub agents: Vec<Agent>,
    pub lines: Vec<Line>,
    pub timing_quality: TimingQuality,
}

/// 行缺终点时的兜底长度：没有下一行、也不知道曲长时，最后一行持续这么久。
pub const FALLBACK_LAST_LINE_MS: i64 = 5_000;

impl Timeline {
    pub fn new(format: &str, quality: TimingQuality) -> Self {
        Timeline {
            meta: Meta {
                format: format.to_owned(),
                ..Meta::default()
            },
            timing_quality: quality,
            ..Timeline::default()
        }
    }

    /// 按 id 取声部下标，没有就新建。
    pub fn agent_index(&mut self, id: &str, kind: AgentKind) -> usize {
        if let Some(i) = self.agents.iter().position(|a| a.id == id) {
            return i;
        }
        self.agents.push(Agent {
            id: id.to_owned(),
            name: String::new(),
            kind,
        });
        self.agents.len() - 1
    }

    /// 解析完的统一收尾：
    /// - 去掉全空行；音节时间夹进单调递增；
    /// - 行缺终点（`end <= start`）的补成下一主行起点 → 曲长 → +[FALLBACK_LAST_LINE_MS]；
    /// - 行起止收拢成音节的包络；
    /// - 按起点稳定排序（和声行跟着它的主行走：排序键用主行起点）。
    pub fn finalize(&mut self, duration_ms: Option<i64>) {
        self.lines.retain(|l| {
            !l.syllables.iter().all(|s| s.text.trim().is_empty())
        });
        if self.timing_quality == TimingQuality::Unsynced {
            for l in &mut self.lines {
                l.start_ms = 0;
                l.end_ms = 0;
                for s in &mut l.syllables {
                    s.start_ms = 0;
                    s.end_ms = 0;
                }
            }
            return;
        }
        // 排序：和声行挂在前一主行下，用组号保持相对位置。
        let mut keyed: Vec<(i64, usize, Line)> = Vec::with_capacity(self.lines.len());
        let mut group_start = 0i64;
        for (i, l) in std::mem::take(&mut self.lines).into_iter().enumerate() {
            if l.role == Role::Main || i == 0 {
                group_start = l.start_ms.max(0);
            }
            keyed.push((group_start, i, l));
        }
        keyed.sort_by(|a, b| a.0.cmp(&b.0).then(a.1.cmp(&b.1)));
        self.lines = keyed.into_iter().map(|(_, _, l)| l).collect();

        let n = self.lines.len();
        let main_starts: Vec<Option<i64>> = (0..n)
            .map(|i| {
                self.lines[i + 1..]
                    .iter()
                    .find(|l| l.role == Role::Main && l.start_ms > self.lines[i].start_ms)
                    .map(|l| l.start_ms)
            })
            .collect();
        for (i, line) in self.lines.iter_mut().enumerate() {
            line.start_ms = line.start_ms.max(0);
            if line.end_ms <= line.start_ms {
                let last_syl_end = line
                    .syllables
                    .iter()
                    .map(|s| s.end_ms)
                    .max()
                    .filter(|&e| e > line.start_ms);
                line.end_ms = last_syl_end
                    .or(main_starts[i])
                    .or(duration_ms.filter(|&d| d > line.start_ms))
                    .unwrap_or(line.start_ms + FALLBACK_LAST_LINE_MS);
            }
            normalize_syllables(line);
        }
    }
}

/// 同一起点的相邻音节（VTT ruby 段、UltraStar 同拍）按字数平分它们共享的时段
/// （到下一个不同起点 / 行终点为止）。需在 [Timeline::finalize] 之前、行终点已知时调用。
pub fn spread_shared_starts(line: &mut Line) {
    let n = line.syllables.len();
    let mut i = 0;
    while i < n {
        let start = line.syllables[i].start_ms;
        let mut j = i + 1;
        while j < n && line.syllables[j].start_ms == start {
            j += 1;
        }
        if j - i > 1 {
            let end = if j < n { line.syllables[j].start_ms } else { line.end_ms };
            if end > start {
                let weights: Vec<i64> = line.syllables[i..j]
                    .iter()
                    .map(|s| s.text.chars().count().max(1) as i64)
                    .collect();
                let total: i64 = weights.iter().sum();
                let mut acc = 0i64;
                for (k, w) in weights.iter().enumerate() {
                    let s = &mut line.syllables[i + k];
                    s.start_ms = start + (end - start) * acc / total;
                    acc += w;
                    s.end_ms = start + (end - start) * acc / total;
                }
            }
        }
        i = j;
    }
}

/// 音节时间夹进行内且单调；缺终点的音节取下一音节起点 / 行终点。行起止收拢成包络。
fn normalize_syllables(line: &mut Line) {
    let n = line.syllables.len();
    if n == 0 {
        return;
    }
    let line_start = line.start_ms;
    let line_end = line.end_ms;
    let mut cursor = line_start.min(line.syllables[0].start_ms.max(0));
    for i in 0..n {
        let next_start = if i + 1 < n {
            Some(line.syllables[i + 1].start_ms)
        } else {
            None
        };
        let s = &mut line.syllables[i];
        if s.start_ms < cursor {
            s.start_ms = cursor;
        }
        if s.end_ms <= s.start_ms {
            s.end_ms = next_start
                .filter(|&ns| ns > s.start_ms)
                .unwrap_or(line_end.max(s.start_ms));
        }
        cursor = s.start_ms;
    }
    let first = line.syllables.first().map(|s| s.start_ms).unwrap_or(line_start);
    let last = line.syllables.iter().map(|s| s.end_ms).max().unwrap_or(line_end);
    line.start_ms = line_start.min(first);
    line.end_ms = line_end.max(last);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finalize_fills_line_ends_from_next_line_then_duration() {
        let mut t = Timeline::new("lrc", TimingQuality::Line);
        t.lines.push(Line::whole("b", 2000, 0));
        t.lines.push(Line::whole("a", 1000, 0));
        t.lines.push(Line::whole("  ", 1500, 0));
        t.finalize(Some(9000));
        assert_eq!(t.lines.len(), 2);
        assert_eq!((t.lines[0].start_ms, t.lines[0].end_ms), (1000, 2000));
        assert_eq!((t.lines[1].start_ms, t.lines[1].end_ms), (2000, 9000));
        assert_eq!(t.lines[0].syllables[0].end_ms, 2000);
    }

    #[test]
    fn background_line_stays_after_its_main_line() {
        let mut t = Timeline::new("ttml", TimingQuality::Syllable);
        let mut bg = Line::whole("(ah)", 900, 1500);
        bg.role = Role::Background;
        t.lines.push(Line::whole("main", 1000, 2000));
        t.lines.push(bg);
        t.lines.push(Line::whole("next", 1950, 3000));
        t.finalize(None);
        assert_eq!(t.lines[0].text(), "main");
        assert_eq!(t.lines[1].role, Role::Background);
        assert_eq!(t.lines[2].text(), "next");
    }
}
