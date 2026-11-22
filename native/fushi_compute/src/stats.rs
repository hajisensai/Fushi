//! 学习统计事实面的派生（`ffc_stats_*`，Dart 侧 `packages/fushi_compute/lib/src/stats/`，
//! 唯一调用方 `packages/fushi_engine/lib/stats/stat_facts.dart` 的 `loadStatFacts`）。
//!
//! 迁自 Dart（BUG-4960）：`loadStatFacts` 把 legacy 四表 + 段 + 游玩会话逐行构造成 `StatFact`、
//! `deriveStudySessions` 归并会话、统计中心总览再按日求和——大库在 UI isolate 上 90～250 ms。
//! 现在库读取在后台 isolate，读出的原始行一次打包交给这里，派生全在 Rust，只回一份快照：
//!
//! - **日面 / 小时面**（`StatFacts.daily` / `hourly`）：顺序、字段与旧 Dart 逐条相同；
//! - **会话流**（`StatFacts.sessions`）：段按同 (deviceId, mediaKind, mediaKey) 相邻 ≤ gap 归并，
//!   游戏以 `galgame_sessions` 行为骨架吸收区间相交的字数段；两处排序照搬 Dart `List.sort`
//!   （不稳定，并列元素的去向必须一致，见 [crate::dart::sort]）；
//! - **按日合计**（总览的范围图 / 所选范围卡 / 学习日历 / 阅读速度）：全日面与阅读域日面各一份，
//!   按 dateKey 首次出现的顺序；
//! - **活动流**（`StatFacts.activityRows`，BUG-5184）：legacy 活动行 ∪ 非零段 ∪ 游玩会话骨架，按时刻
//!   倒序（照搬 `List.sort`）截到上限。只回来源 + 下标，行对象由调用方按原样复用 / 合成。
//!
//! 字符串全程是 UTF-16 码元（Dart `String` 的内部表示）：比较 = `String.compareTo`，
//! 不经 UTF-8 往返。
//!
//! ## 输入（调用方打包）
//!
//! 三块缓冲：`ints`（`i64` 流）、`ends`（每个字符串在 `text` 里的结束偏移，`u32`）、
//! `text`（全部字符串的 UTF-16 码元首尾相接）。整数与字符串各按下列顺序依次读出：
//!
//! ```text
//! ints: [版本=2, gap 毫秒, 活动流条数上限]
//! 每张表先一个行数 n（ints），再 n 行；行内字段 S = 字符串、I = 整数，按列出顺序：
//!  1 epubs            S title, S bookKey, S format
//!  2 reading          S title, S dateKey | I ms, I chars, I pages, I lastModified
//!  3 watch            S bookUid(无=''), S title, S dateKey | I ms, I chars, I lastModified
//!  4 readingHourly    S format, S dateKey | I hour, I ms
//!  5 videoHourly      S dateKey | I hour, I ms
//!  6 gameTitles       S gameId, S title          （已移除游戏的会话快照名）
//!  7 gameDaily        S gameId, S dateKey | I seconds
//!  8 gameActivity     S mediaKey(无=''), S title, S dateKey | I chars(无=0), I timestampMs
//!  9 segments         S uid, S deviceId, S mediaKind, S mediaKey, S title, S format, S dateKey
//!                     | I startAt, I endAt, I hour, I durationMs, I chars, I pages
//! 10 reviews          I day(自 1970-01-01 的天数), I hour, I ms, I last
//! 11 gameSessions     S gameId | I id, I startMs, I endMs, I durationSeconds
//! 12 gameNames        S gameId, S name           （会话标题：库内显示名优先）
//! 13 legacyActivity   I timestampMs              （legacy 活动行，只需排序键；行对象留在调用方）
//! ```
//!
//! ## 输出（[crate::hand_over_bytes]，调用方 `ffc_free_bytes`）
//!
//! `[nInts u64][nEnds u64][nText u64]`，随后 `ints`（i64）、`ends`（u32）、`text`（u16），
//! 各段按自身宽度对齐（24 字节头之后 ints 天然 8 对齐，ends 在 ints 之后 4 对齐，text 在其后 2 对齐）。
//! `text` / `ends` 是去重后的字符串表，`ints` 里的字符串一律是表下标：
//!
//! ```text
//! daily:   n, 每行 kind, key, title, format, dateKey, hour, ms, chars, pages, lastActive
//! hourly:  n, 每行先一个 daily 下标（≥0 = 与日面那一行是同一条事实）或 -1 + 一整行（同上）
//! sessions:n, 每行 kind, key, title, format, deviceId, startAt, endAt, durationMs, chars, pages,
//!          gameSessionId(无 = -1, 有则后跟 id), uid 个数 m, m 个 uid
//! dayTotals / bookDayTotals: 各 n, 每行 dateKey, chars, ms
//! activity: n, 每行 来源(0 = legacy 活动行 / 1 = 段 / 2 = 游玩会话骨架), 该来源表里的下标
//! ```

use std::collections::{HashMap, HashSet};

use crate::{dart, guard, hand_over_bytes, status};

/// 输入格式版本（打包端写在 ints[0]）。
const INPUT_VERSION: i64 = 2;

type Str<'a> = &'a [u16];

fn utf16(s: &str) -> Vec<u16> {
    s.encode_utf16().collect()
}

/// 解析失败（越界 / 版本不符）。
#[derive(Debug)]
struct BadInput;

/// 顺序读取整数流与字符串流。
struct Reader<'a> {
    ints: &'a [i64],
    ip: usize,
    ends: &'a [u32],
    sp: usize,
    text: &'a [u16],
}

impl<'a> Reader<'a> {
    fn int(&mut self) -> Result<i64, BadInput> {
        let v = *self.ints.get(self.ip).ok_or(BadInput)?;
        self.ip += 1;
        Ok(v)
    }

    fn count(&mut self) -> Result<usize, BadInput> {
        let n = self.int()?;
        if n < 0 {
            return Err(BadInput);
        }
        Ok(n as usize)
    }

    fn str(&mut self) -> Result<Str<'a>, BadInput> {
        let end = *self.ends.get(self.sp).ok_or(BadInput)? as usize;
        let start = if self.sp == 0 {
            0
        } else {
            self.ends[self.sp - 1] as usize
        };
        self.sp += 1;
        if start > end || end > self.text.len() {
            return Err(BadInput);
        }
        Ok(&self.text[start..end])
    }
}

/// 一条事实（字段同 Dart `StatFact`）。
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Fact<'a> {
    pub kind: Str<'a>,
    pub key: Str<'a>,
    pub title: Str<'a>,
    pub format: Str<'a>,
    pub date_key: Str<'a>,
    pub hour: i64,
    pub ms: i64,
    pub chars: i64,
    pub pages: i64,
    pub last_active: i64,
}

/// 一段（`study_segments` 行里派生要用的列）。
#[derive(Clone, Copy, Debug)]
pub struct Segment<'a> {
    pub uid: Str<'a>,
    pub device_id: Str<'a>,
    pub kind: Str<'a>,
    pub key: Str<'a>,
    pub title: Str<'a>,
    pub format: Str<'a>,
    pub date_key: Str<'a>,
    pub start_at: i64,
    pub end_at: i64,
    pub hour: i64,
    pub duration_ms: i64,
    pub chars: i64,
    pub pages: i64,
}

impl Segment<'_> {
    /// 写零的段（用户删过）：不进事实面、不进会话流（与 Dart `segmentsAsActivityRows` 同一判据）。
    fn is_zero(&self) -> bool {
        self.duration_ms <= 0 && self.chars <= 0 && self.pages <= 0
    }
}

/// 一条游玩会话骨架（`galgame_sessions`）。
#[derive(Clone, Copy, Debug)]
pub struct GameSession<'a> {
    pub game_id: Str<'a>,
    pub id: i64,
    pub start_ms: i64,
    pub end_ms: i64,
    pub duration_seconds: i64,
}

/// 一次学习会话（字段同 Dart `StudySession`）。
#[derive(Clone, Debug, PartialEq)]
pub struct Session<'a> {
    pub kind: Str<'a>,
    pub key: Str<'a>,
    pub title: Str<'a>,
    pub format: Str<'a>,
    pub device_id: Str<'a>,
    pub start_at: i64,
    pub end_at: i64,
    pub duration_ms: i64,
    pub chars: i64,
    pub pages: i64,
    pub uids: Vec<Str<'a>>,
    pub game_session_id: Option<i64>,
}

/// 按日合计的一行。
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct DayTotal<'a> {
    pub date_key: Str<'a>,
    pub chars: i64,
    pub ms: i64,
}

/// 日面里的事实来源：hourly 里与日面共用的行记 daily 下标。
enum HourlyEntry<'a> {
    Shared(usize),
    Own(Fact<'a>),
}

/// 派生用的常量字符串（媒体域值、空串、复习身份）。
pub struct Consts {
    pub book: Vec<u16>,
    pub video: Vec<u16>,
    pub game: Vec<u16>,
    pub review: Vec<u16>,
    pub review_key: Vec<u16>,
    pub empty: Vec<u16>,
}

impl Consts {
    pub fn new() -> Self {
        Self {
            // ActivityMediaKind.dbValue（fushi_core）与 kStatMediaReview / kStatReviewMediaKey。
            book: utf16("book"),
            video: utf16("video"),
            game: utf16("game"),
            review: utf16("review"),
            review_key: utf16("srs"),
            empty: Vec::new(),
        }
    }
}

impl Default for Consts {
    fn default() -> Self {
        Self::new()
    }
}

/// 复习格子的统计日 key：`statCalendarDayKeyOf(DateTime.utc(1970).add(Duration(days: day)))`
/// ——年不补零、月日补两位（与 Dart 逐字节同形）。
pub fn calendar_day_key(day: i64) -> String {
    // Howard Hinnant 的 civil_from_days。
    let z = day + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };
    format!("{y}-{m:02}-{d:02}")
}

/// 解析后的全部输入。
struct Input<'a> {
    gap_ms: i64,
    epubs: Vec<(Str<'a>, Str<'a>, Str<'a>)>,
    reading: Vec<(Str<'a>, Str<'a>, [i64; 4])>,
    watch: Vec<(Str<'a>, Str<'a>, Str<'a>, [i64; 3])>,
    reading_hourly: Vec<(Str<'a>, Str<'a>, [i64; 2])>,
    video_hourly: Vec<(Str<'a>, [i64; 2])>,
    game_titles: Vec<(Str<'a>, Str<'a>)>,
    game_daily: Vec<(Str<'a>, Str<'a>, i64)>,
    game_activity: Vec<(Str<'a>, Str<'a>, Str<'a>, [i64; 2])>,
    segments: Vec<Segment<'a>>,
    reviews: Vec<[i64; 4]>,
    game_sessions: Vec<GameSession<'a>>,
    game_names: Vec<(Str<'a>, Str<'a>)>,
    activity_limit: i64,
    legacy_activity_ts: Vec<i64>,
}

fn parse<'a>(r: &mut Reader<'a>) -> Result<Input<'a>, BadInput> {
    if r.int()? != INPUT_VERSION {
        return Err(BadInput);
    }
    let gap_ms = r.int()?;
    let activity_limit = r.int()?;
    let mut input = Input {
        gap_ms,
        epubs: Vec::new(),
        reading: Vec::new(),
        watch: Vec::new(),
        reading_hourly: Vec::new(),
        video_hourly: Vec::new(),
        game_titles: Vec::new(),
        game_daily: Vec::new(),
        game_activity: Vec::new(),
        segments: Vec::new(),
        reviews: Vec::new(),
        game_sessions: Vec::new(),
        game_names: Vec::new(),
        activity_limit,
        legacy_activity_ts: Vec::new(),
    };
    for _ in 0..r.count()? {
        input.epubs.push((r.str()?, r.str()?, r.str()?));
    }
    for _ in 0..r.count()? {
        let (t, d) = (r.str()?, r.str()?);
        input
            .reading
            .push((t, d, [r.int()?, r.int()?, r.int()?, r.int()?]));
    }
    for _ in 0..r.count()? {
        let (u, t, d) = (r.str()?, r.str()?, r.str()?);
        input.watch.push((u, t, d, [r.int()?, r.int()?, r.int()?]));
    }
    for _ in 0..r.count()? {
        let (f, d) = (r.str()?, r.str()?);
        input.reading_hourly.push((f, d, [r.int()?, r.int()?]));
    }
    for _ in 0..r.count()? {
        let d = r.str()?;
        input.video_hourly.push((d, [r.int()?, r.int()?]));
    }
    for _ in 0..r.count()? {
        input.game_titles.push((r.str()?, r.str()?));
    }
    for _ in 0..r.count()? {
        let (g, d) = (r.str()?, r.str()?);
        input.game_daily.push((g, d, r.int()?));
    }
    for _ in 0..r.count()? {
        let (k, t, d) = (r.str()?, r.str()?, r.str()?);
        input.game_activity.push((k, t, d, [r.int()?, r.int()?]));
    }
    for _ in 0..r.count()? {
        let (uid, device_id, kind, key, title, format, date_key) = (
            r.str()?,
            r.str()?,
            r.str()?,
            r.str()?,
            r.str()?,
            r.str()?,
            r.str()?,
        );
        input.segments.push(Segment {
            uid,
            device_id,
            kind,
            key,
            title,
            format,
            date_key,
            start_at: r.int()?,
            end_at: r.int()?,
            hour: r.int()?,
            duration_ms: r.int()?,
            chars: r.int()?,
            pages: r.int()?,
        });
    }
    for _ in 0..r.count()? {
        input.reviews.push([r.int()?, r.int()?, r.int()?, r.int()?]);
    }
    for _ in 0..r.count()? {
        let game_id = r.str()?;
        input.game_sessions.push(GameSession {
            game_id,
            id: r.int()?,
            start_ms: r.int()?,
            end_ms: r.int()?,
            duration_seconds: r.int()?,
        });
    }
    for _ in 0..r.count()? {
        input.game_names.push((r.str()?, r.str()?));
    }
    for _ in 0..r.count()? {
        input.legacy_activity_ts.push(r.int()?);
    }
    if r.ip != r.ints.len() || r.sp != r.ends.len() {
        return Err(BadInput);
    }
    Ok(input)
}

/// 日面 + 小时面（旧 `loadStatFacts` 的构造顺序逐条照搬）。
fn derive_facts<'a>(
    input: &Input<'a>,
    c: &'a Consts,
    review_keys: &'a [Vec<u16>],
) -> (Vec<Fact<'a>>, Vec<HourlyEntry<'a>>) {
    // BUG-2216：库里恰好一本叫这个名字才反查（同名 ≥2 本不贴给任意一本）。
    let mut by_title: HashMap<Str<'a>, (usize, usize)> = HashMap::new();
    for (i, &(title, _, _)) in input.epubs.iter().enumerate() {
        by_title
            .entry(title)
            .and_modify(|e| e.0 += 1)
            .or_insert((1, i));
    }
    let unique_book = |title: Str<'a>| -> Option<(Str<'a>, Str<'a>)> {
        match by_title.get(title) {
            Some(&(1, i)) => Some((input.epubs[i].1, input.epubs[i].2)),
            _ => None,
        }
    };
    let empty: Str<'a> = &c.empty;
    let mut daily: Vec<Fact<'a>> = Vec::new();
    let mut hourly: Vec<HourlyEntry<'a>> = Vec::new();

    // legacy 日行：阅读按 title 反查补身份与 format；视频 v39 起自带 bookUid。
    for &(title, date_key, [ms, chars, pages, last]) in &input.reading {
        let (key, format) = unique_book(title).unwrap_or((empty, empty));
        daily.push(Fact {
            kind: &c.book,
            key,
            title,
            format,
            date_key,
            hour: -1,
            ms,
            chars,
            pages,
            last_active: last,
        });
    }
    for &(uid, title, date_key, [ms, chars, last]) in &input.watch {
        daily.push(Fact {
            kind: &c.video,
            key: uid,
            title,
            format: empty,
            date_key,
            hour: -1,
            ms,
            chars,
            pages: 0,
            last_active: last,
        });
    }
    // legacy 小时行（无身份、无 title）。
    for &(format, date_key, [hour, ms]) in &input.reading_hourly {
        hourly.push(HourlyEntry::Own(Fact {
            kind: &c.book,
            key: empty,
            title: empty,
            format,
            date_key,
            hour,
            ms,
            chars: 0,
            pages: 0,
            last_active: 0,
        }));
    }
    for &(date_key, [hour, ms]) in &input.video_hourly {
        hourly.push(HourlyEntry::Own(Fact {
            kind: &c.video,
            key: empty,
            title: empty,
            format: empty,
            date_key,
            hour,
            ms,
            chars: 0,
            pages: 0,
            last_active: 0,
        }));
    }
    // 游戏时长真相源 galgame_sessions：按 (game, day) 进日面；title 只带已移除游戏的快照名。
    let titles: HashMap<Str<'a>, Str<'a>> = input.game_titles.iter().copied().collect();
    for &(game_id, date_key, seconds) in &input.game_daily {
        daily.push(Fact {
            kind: &c.game,
            key: game_id,
            title: titles.get(game_id).copied().unwrap_or(empty),
            format: empty,
            date_key,
            hour: -1,
            ms: seconds.wrapping_mul(1000),
            chars: 0,
            pages: 0,
            last_active: 0,
        });
    }
    // legacy 游戏活动行：只取 hook 字数（时长真相源是 galgame_sessions，取了就双计）。
    for &(key, title, date_key, [chars, ts]) in &input.game_activity {
        if chars <= 0 {
            continue;
        }
        daily.push(Fact {
            kind: &c.game,
            key,
            title,
            format: empty,
            date_key,
            hour: -1,
            ms: 0,
            chars,
            pages: 0,
            last_active: ts,
        });
    }
    // v92 段：两面各一份；写零的段不进。
    for s in &input.segments {
        if s.is_zero() {
            continue;
        }
        hourly.push(HourlyEntry::Shared(daily.len()));
        daily.push(Fact {
            kind: s.kind,
            key: s.key,
            title: s.title,
            format: s.format,
            date_key: s.date_key,
            hour: s.hour,
            ms: s.duration_ms,
            chars: s.chars,
            pages: s.pages,
            last_active: s.end_at,
        });
    }
    // SRS 复习：一条 (统计日, 小时) 一行，两面各一份；时长 0 的格子不出。
    for (i, &[_, hour, ms, last]) in input.reviews.iter().enumerate() {
        if ms <= 0 {
            continue;
        }
        hourly.push(HourlyEntry::Shared(daily.len()));
        daily.push(Fact {
            kind: &c.review,
            key: &c.review_key,
            title: empty,
            format: empty,
            date_key: &review_keys[i],
            hour,
            ms,
            chars: 0,
            pages: 0,
            last_active: last,
        });
    }
    (daily, hourly)
}

/// 会话流（旧 Dart `deriveStudySessions` 的逐步复刻），按结束时刻倒序。
pub fn derive_sessions<'a>(
    segments: &[Segment<'a>],
    game_sessions: &[GameSession<'a>],
    game_names: &HashMap<Str<'a>, Str<'a>>,
    gap_ms: i64,
    c: &'a Consts,
) -> Vec<Session<'a>> {
    let mut out: Vec<Session<'a>> = Vec::new();
    let mut absorbed: HashSet<Str<'a>> = HashSet::new();
    let empty: Str<'a> = &c.empty;
    let game: Str<'a> = &c.game;

    // 1) 游戏骨架：一行一会话，吸收区间相交的同游戏非零段（按段原顺序）。
    let mut game_segments: HashMap<Str<'a>, Vec<usize>> = HashMap::new();
    for (i, s) in segments.iter().enumerate() {
        if s.kind == game && !s.is_zero() {
            game_segments.entry(s.key).or_default().push(i);
        }
    }
    for g in game_sessions {
        let hits: Vec<&Segment<'a>> = game_segments
            .get(g.game_id)
            .map(|v| {
                v.iter()
                    .map(|&i| &segments[i])
                    .filter(|s| s.start_at < g.end_ms && s.end_at > g.start_ms)
                    .collect()
            })
            .unwrap_or_default();
        let mut chars: i64 = 0;
        for s in &hits {
            chars = chars.wrapping_add(s.chars);
            absorbed.insert(s.uid);
        }
        out.push(Session {
            kind: game,
            key: g.game_id,
            title: game_names
                .get(g.game_id)
                .copied()
                .unwrap_or_else(|| hits.first().map_or(empty, |s| s.title)),
            format: empty,
            device_id: hits.first().map_or(empty, |s| s.device_id),
            start_at: g.start_ms,
            end_at: g.end_ms,
            duration_ms: g.duration_seconds.wrapping_mul(1000),
            chars,
            pages: 0,
            uids: hits.iter().map(|s| s.uid).collect(),
            game_session_id: Some(g.id),
        });
    }

    // 2) 其余段：骨架窗口之外的游戏段不做会话（没有骨架行，做出来是 0 分钟的孤儿会话）。
    let window_start: Option<i64> = game_sessions.iter().map(|g| g.start_ms).min();
    let mut rest: Vec<usize> = (0..segments.len())
        .filter(|&i| {
            let s = &segments[i];
            !s.is_zero()
                && !absorbed.contains(s.uid)
                && !(window_start.is_some_and(|w| s.kind == game && s.start_at < w))
        })
        .collect();
    dart::sort(&mut rest, &mut |a: usize, b: usize| {
        let (x, y) = (&segments[a], &segments[b]);
        let c = x
            .device_id
            .cmp(y.device_id)
            .then_with(|| x.kind.cmp(y.kind))
            .then_with(|| x.key.cmp(y.key));
        match c {
            std::cmp::Ordering::Equal => dart::compare_i64(x.start_at, y.start_at),
            o => o as i32,
        }
    });
    let mut run: Option<Session<'a>> = None;
    for &i in &rest {
        let s = &segments[i];
        if let Some(r) = run.as_mut() {
            if r.device_id == s.device_id
                && r.kind == s.kind
                && r.key == s.key
                && s.start_at.wrapping_sub(r.end_at) <= gap_ms
            {
                add_to_run(r, s);
                continue;
            }
        }
        if let Some(done) = run.take() {
            out.push(done);
        }
        let mut first = Session {
            kind: s.kind,
            key: s.key,
            title: empty,
            format: s.format,
            device_id: s.device_id,
            start_at: s.start_at,
            end_at: s.end_at,
            duration_ms: 0,
            chars: 0,
            pages: 0,
            uids: Vec::new(),
            game_session_id: None,
        };
        add_to_run(&mut first, s);
        run = Some(first);
    }
    if let Some(done) = run {
        out.push(done);
    }

    let mut order: Vec<usize> = (0..out.len()).collect();
    dart::sort(&mut order, &mut |a: usize, b: usize| {
        dart::compare_i64(out[b].end_at, out[a].end_at)
    });
    let mut slots: Vec<Option<Session<'a>>> = out.into_iter().map(Some).collect();
    order
        .into_iter()
        .map(|i| slots[i].take().expect("each index once"))
        .collect()
}

fn add_to_run<'a>(r: &mut Session<'a>, s: &Segment<'a>) {
    if s.end_at > r.end_at {
        r.end_at = s.end_at;
    }
    r.duration_ms = r.duration_ms.wrapping_add(s.duration_ms);
    r.chars = r.chars.wrapping_add(s.chars);
    r.pages = r.pages.wrapping_add(s.pages);
    r.uids.push(s.uid);
    // 最新一段的 title 快照最接近当前显示名。
    if !s.title.is_empty() {
        r.title = s.title;
    }
}

/// 活动流一行的来源（输出里的来源码即判别值）。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ActivitySource {
    /// legacy `activity_events` 行（调用方原样复用）。
    Legacy(usize),
    /// 段合成的读 / 看 / 玩事件。
    Segment(usize),
    /// 游玩会话骨架合成的「游玩」事件。
    Game(usize),
}

/// 活动流（旧 Dart `StatFacts.activityRows` 的逐步复刻）：legacy 行 ∪ 非零段（按段顺序）∪
/// 游玩会话（按骨架顺序）拼接后按时刻倒序（`List.sort`，并列去向一致），截到 [limit] 条。
pub fn derive_activity(
    legacy_ts: &[i64],
    segments: &[Segment<'_>],
    game_sessions: &[GameSession<'_>],
    limit: i64,
) -> Vec<ActivitySource> {
    let mut all: Vec<(ActivitySource, i64)> = Vec::with_capacity(legacy_ts.len());
    all.extend(
        legacy_ts
            .iter()
            .enumerate()
            .map(|(i, &t)| (ActivitySource::Legacy(i), t)),
    );
    all.extend(
        segments
            .iter()
            .enumerate()
            .filter(|(_, s)| !s.is_zero())
            .map(|(i, s)| (ActivitySource::Segment(i), s.end_at)),
    );
    all.extend(
        game_sessions
            .iter()
            .enumerate()
            .map(|(i, g)| (ActivitySource::Game(i), g.end_ms)),
    );
    let limit = limit.max(0) as usize;
    if limit == 0 {
        // `all.length <= 0 ? all : all.sublist(0, 0)`：恒为空，不必排序。
        return Vec::new();
    }
    let mut order: Vec<usize> = (0..all.len()).collect();
    dart::sort(&mut order, &mut |a: usize, b: usize| {
        dart::compare_i64(all[b].1, all[a].1)
    });
    order.truncate(limit);
    order.into_iter().map(|i| all[i].0).collect()
}

/// 按 dateKey 求和（首次出现顺序），[only] 非空时只算该域。
pub fn day_totals<'a>(daily: &[Fact<'a>], only: Option<Str<'_>>) -> Vec<DayTotal<'a>> {
    let mut index: HashMap<Str<'a>, usize> = HashMap::new();
    let mut out: Vec<DayTotal<'a>> = Vec::new();
    for f in daily {
        if only.is_some_and(|k| f.kind != k) {
            continue;
        }
        let i = *index.entry(f.date_key).or_insert_with(|| {
            out.push(DayTotal {
                date_key: f.date_key,
                chars: 0,
                ms: 0,
            });
            out.len() - 1
        });
        out[i].chars = out[i].chars.wrapping_add(f.chars);
        out[i].ms = out[i].ms.wrapping_add(f.ms);
    }
    out
}

/// 输出端：去重字符串表 + 整数流。
struct Writer<'a> {
    ints: Vec<i64>,
    index: HashMap<Str<'a>, i64>,
    strings: Vec<Str<'a>>,
}

impl<'a> Writer<'a> {
    fn s(&mut self, v: Str<'a>) {
        let next = self.strings.len() as i64;
        let id = *self.index.entry(v).or_insert_with(|| {
            self.strings.push(v);
            next
        });
        self.ints.push(id);
    }

    fn i(&mut self, v: i64) {
        self.ints.push(v);
    }

    fn fact(&mut self, f: &Fact<'a>) {
        self.s(f.kind);
        self.s(f.key);
        self.s(f.title);
        self.s(f.format);
        self.s(f.date_key);
        self.i(f.hour);
        self.i(f.ms);
        self.i(f.chars);
        self.i(f.pages);
        self.i(f.last_active);
    }

    fn totals(&mut self, totals: &[DayTotal<'a>]) {
        self.i(totals.len() as i64);
        for t in totals {
            self.s(t.date_key);
            self.i(t.chars);
            self.i(t.ms);
        }
    }

    fn finish(self) -> Result<Vec<u8>, BadInput> {
        let mut ends: Vec<u32> = Vec::with_capacity(self.strings.len());
        let mut text_len: usize = 0;
        for s in &self.strings {
            text_len += s.len();
            ends.push(u32::try_from(text_len).map_err(|_| BadInput)?);
        }
        let mut out: Vec<u8> =
            Vec::with_capacity(24 + self.ints.len() * 8 + ends.len() * 4 + text_len * 2);
        out.extend_from_slice(&(self.ints.len() as u64).to_le_bytes());
        out.extend_from_slice(&(ends.len() as u64).to_le_bytes());
        out.extend_from_slice(&(text_len as u64).to_le_bytes());
        for v in &self.ints {
            out.extend_from_slice(&v.to_le_bytes());
        }
        for v in &ends {
            out.extend_from_slice(&v.to_le_bytes());
        }
        for s in &self.strings {
            for u in s.iter() {
                out.extend_from_slice(&u.to_le_bytes());
            }
        }
        Ok(out)
    }
}

/// 整份派生：解析输入 → 日面 / 小时面 / 会话流 / 两份按日合计 → 编码快照。
fn derive(ints: &[i64], ends: &[u32], text: &[u16]) -> Result<Vec<u8>, BadInput> {
    let mut reader = Reader {
        ints,
        ip: 0,
        ends,
        sp: 0,
        text,
    };
    let input = parse(&mut reader)?;
    let c = Consts::new();
    let review_keys: Vec<Vec<u16>> = input
        .reviews
        .iter()
        .map(|&[day, ..]| utf16(&calendar_day_key(day)))
        .collect();
    let (daily, hourly) = derive_facts(&input, &c, &review_keys);
    let names: HashMap<Str<'_>, Str<'_>> = input.game_names.iter().copied().collect();
    let sessions = derive_sessions(
        &input.segments,
        &input.game_sessions,
        &names,
        input.gap_ms,
        &c,
    );
    let all_days = day_totals(&daily, None);
    let book_days = day_totals(&daily, Some(c.book.as_slice()));
    let activity = derive_activity(
        &input.legacy_activity_ts,
        &input.segments,
        &input.game_sessions,
        input.activity_limit,
    );

    let mut w = Writer {
        ints: Vec::new(),
        index: HashMap::new(),
        strings: Vec::new(),
    };
    w.i(daily.len() as i64);
    for f in &daily {
        w.fact(f);
    }
    w.i(hourly.len() as i64);
    for h in &hourly {
        match h {
            HourlyEntry::Shared(i) => w.i(*i as i64),
            HourlyEntry::Own(f) => {
                w.i(-1);
                w.fact(f);
            }
        }
    }
    w.i(sessions.len() as i64);
    for s in &sessions {
        w.s(s.kind);
        w.s(s.key);
        w.s(s.title);
        w.s(s.format);
        w.s(s.device_id);
        w.i(s.start_at);
        w.i(s.end_at);
        w.i(s.duration_ms);
        w.i(s.chars);
        w.i(s.pages);
        match s.game_session_id {
            Some(id) => {
                w.i(1);
                w.i(id);
            }
            None => w.i(-1),
        }
        w.i(s.uids.len() as i64);
        for u in &s.uids {
            w.s(u);
        }
    }
    w.totals(&all_days);
    w.totals(&book_days);
    w.i(activity.len() as i64);
    for a in &activity {
        let (tag, i) = match *a {
            ActivitySource::Legacy(i) => (0, i),
            ActivitySource::Segment(i) => (1, i),
            ActivitySource::Game(i) => (2, i),
        };
        w.i(tag);
        w.i(i as i64);
    }
    w.finish()
}

/// 学习统计事实面的整份派生（见模块文档的输入 / 输出格式）。
///
/// 返回 0 成功（`*out_ptr` / `*out_len` 交给调用方，用 `ffc_free_bytes` 释放）；
/// 必需指针为空 -1；输入格式不符（版本、越界、多余数据）-3；panic -100。
///
/// # Safety
/// `ints` / `ends` / `text` 各指向至少 `n_*` 个元素（长度为 0 时可为任意非空指针）；
/// `out_ptr` / `out_len` 可写。
#[no_mangle]
pub unsafe extern "C" fn ffc_stats_derive(
    ints: *const i64,
    n_ints: usize,
    ends: *const u32,
    n_ends: usize,
    text: *const u16,
    n_text: usize,
    out_ptr: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    if ints.is_null() || ends.is_null() || text.is_null() || out_ptr.is_null() || out_len.is_null()
    {
        return status::NULL_ARGUMENT;
    }
    guard(|| {
        let ints = std::slice::from_raw_parts(ints, n_ints);
        let ends = std::slice::from_raw_parts(ends, n_ends);
        let text = std::slice::from_raw_parts(text, n_text);
        match derive(ints, ends, text) {
            Ok(bytes) => {
                hand_over_bytes(bytes, out_ptr, out_len);
                status::OK
            }
            Err(BadInput) => status::BAD_INPUT,
        }
    })
}

#[cfg(test)]
mod tests;
