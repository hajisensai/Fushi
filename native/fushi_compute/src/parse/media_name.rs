//! `ffc_parse_filename_*`：视频文件名 / 目录名解析（anitomy 式规则引擎）。
//!
//! 原 Dart 实现是 `packages/fushi_engine/lib/media/video/scraper/filename_parser.dart`
//! 的 `FilenameParser`（约 65 个正则）；那边现在只剩 FFI 适配，**规则只有这一份**。
//! 本文件逐条照搬原规则与顺序，正则原样（同一模式串）交给 [js_regex]——它逐码元复现
//! Dart `RegExp` 的语义，所以先行断言、`\s` 集合、大小写折叠都与旧实现一致。
//! 删 Dart 实现前用旧实现冻结了输入 → 输出向量（packages/fushi_compute/test/media_name_test.dart）。
//!
//! 批量接口：一次调用解析一组 UTF-16 字符串（池 + 各自长度），结果用定长 i32 记录 +
//! 一个 UTF-16 池一次交回（布局见 [encode_records]），由 `ffc_free_bytes` 释放。

use std::sync::OnceLock;

use crate::{guard, hand_over_bytes, status};

pub mod dart_str;
pub mod js_regex;

use dart_str::{contains, index_of, parse_digits, replace_all_str, to_lower, trim, trim_right, w};
use js_regex::{JsRegex, Match};

type U16s = Vec<u16>;

/// 一个名字的解析结果（字段语义同 Dart `ParsedMediaName`）。
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ParsedName {
    pub title: U16s,
    pub secondary_title: Option<U16s>,
    pub episode: Option<i64>,
    pub season: Option<i64>,
    pub year: Option<i64>,
    pub title_with_trailing_year: Option<U16s>,
    pub release_group: Option<U16s>,
    pub resolution: Option<U16s>,
    pub is_movie_hint: bool,
}

/// 解析时依赖的外部量：扩展名表（Dart `kVideoExtensions`，小写含点）与「今年」
/// （原实现 `DateTime.now().year`，由调用方给出，保证同一批次口径一致且可测）。
pub struct ParseEnv {
    pub extensions: Vec<U16s>,
    pub current_year: i64,
}

#[derive(Clone, Default)]
struct State {
    episode: Option<i64>,
    season: Option<i64>,
    year: Option<i64>,
    release_group: Option<U16s>,
    resolution: Option<U16s>,
    secondary_title: Option<U16s>,
    is_movie_hint: bool,
    bare_year_taken: bool,
    keep_bare_year: bool,
}

struct Block {
    content: U16s,
    outside_before: U16s,
}

struct Patterns {
    split_path: JsRegex,
    resolution_token: JsRegex,
    checksum: JsRegex,
    year_block: JsRegex,
    plain_episode_block: JsRegex,
    episode_end_block: JsRegex,
    cn_episode_block: JsRegex,
    codec_tokens: Vec<JsRegex>,
    source_token: JsRegex,
    tokenize: JsRegex,
    whitespace: JsRegex,
    season_episode: JsRegex,
    cn_episode: JsRegex,
    cn_episode_suffix: JsRegex,
    ep_token: JsRegex,
    hash_episode: JsRegex,
    dash_episode: JsRegex,
    bare_trailing_episode: JsRegex,
    cn_season: JsRegex,
    ordinal_season: JsRegex,
    word_ordinal_season: JsRegex,
    season_cardinal_word: JsRegex,
    season_episode_block: JsRegex,
    season_word: JsRegex,
    s_token: JsRegex,
    part_season: JsRegex,
    ascii_roman_tail: JsRegex,
    unicode_roman_tail: JsRegex,
    trailing_numeric_season: JsRegex,
    cjk_movie_inline: JsRegex,
    cjk_eiga_token: JsRegex,
    ascii_movie_token: JsRegex,
    gekijouban_token: JsRegex,
    tilde_secondary: JsRegex,
    dash_split: JsRegex,
    colon_split: JsRegex,
    all_digits: JsRegex,
    cleanup_head: JsRegex,
    cleanup_tail: JsRegex,
    trailing_year: JsRegex,
    non_title_digits: JsRegex,
    non_title_device: JsRegex,
    drive_letter: JsRegex,
    // 常量字符串（UTF-16）。
    cjk_lang_marks: Vec<U16s>,
    group_marks: Vec<U16s>,
    lang_tokens: Vec<U16s>,
    cjk_movie_marks: Vec<U16s>,
    generic_dir_names: Vec<U16s>,
}

fn words(list: &[&str]) -> Vec<U16s> {
    list.iter().map(|s| w(s)).collect()
}

fn patterns() -> &'static Patterns {
    static P: OnceLock<Patterns> = OnceLock::new();
    P.get_or_init(|| Patterns {
        split_path: JsRegex::cs(r"[\\/]+"),
        resolution_token: JsRegex::ci(r"^(\d{3,4}[pi]|[248]k|\d{3,4}[x×]\d{3,4})$"),
        checksum: JsRegex::cs(r"^[0-9A-Fa-f]{8}$"),
        year_block: JsRegex::cs(r"^(19|20)\d{2}$"),
        plain_episode_block: JsRegex::cs(r"^\d{1,3}$"),
        episode_end_block: JsRegex::ci(r"^(\d{1,3})\s*(?:END|Fin|完)$"),
        cn_episode_block: JsRegex::cs(r"^第\s*(\d{1,4})\s*[话話集回巻]$"),
        codec_tokens: vec![
            JsRegex::ci(r"^[xh]\.?26[45]$"),
            JsRegex::ci(r"^(hevc|avc|av1|vp9|xvid|divx)$"),
            JsRegex::ci(r"^(aac|flac|opus|ac3|eac3|dts|dtshd|truehd|mp3|ogg|vorbis|pcm)(x\d)?$"),
            JsRegex::ci(r"^\d{1,2}-?bits?$"),
            JsRegex::ci(r"^(hi10p|ma10p|ma444p?|hdr|hdr10|hlg|sdr|yuv420p10(le)?)$"),
            JsRegex::ci(r"^(mkv|mp4|avi|webm|m2ts|wmv|flv|rmvb)$"),
            JsRegex::ci(r"^v\d$"),
        ],
        source_token: JsRegex::ci(concat!(
            r"^(web|webrip|web-dl|webdl|bdrip|bdmv|bd|bluray|blu-ray|dvdrip|dvd|",
            r"remux|hdtv|tvrip|abema|baha|b-global|bglobal|bilibili|cr|crunchyroll|",
            r"sentai|at-x|atx|netflix|nf|amzn|funimation|funi|dsnp|itunes)$",
        )),
        tokenize: JsRegex::cs(r"[ _.+&,]+"),
        whitespace: JsRegex::cs(r"\s+"),
        season_episode: JsRegex::cs(
            r"(?:^|[\s._-])[Ss](\d{1,2})\s*[Ee][Pp]?\.?(\d{1,3})(?:[vV]\d{1,2})?(?=$|[\s._-])",
        ),
        cn_episode: JsRegex::cs(r"第\s*(\d{1,4})\s*[话話集回巻]"),
        cn_episode_suffix: JsRegex::cs(r"(?:^|[\s._-])(\d{1,4})\s*[话話集](?=$|[\s._-])"),
        ep_token: JsRegex::ci(r"(?:^|[\s._-])(?:EP[\s._-]?|E\.?)(\d{1,3})(?=$|[\s._-])"),
        hash_episode: JsRegex::cs(r"#\s*(\d{1,3})"),
        dash_episode: JsRegex::ci(
            r"\s[-‐–—]\s*(\d{1,4})(?:[vV]\d{1,2})?(?:\s*(?:END|Fin|完))?(?=\s|$)",
        ),
        bare_trailing_episode: JsRegex::cs(r"(?:^|\s)(0\d{1,2}|\d{2})\s*$"),
        cn_season: JsRegex::cs(r"第\s*([0-9零一二两三四五六七八九十]{1,3})\s*[季期]"),
        ordinal_season: JsRegex::ci(r"(\d{1,2})\s*(?:st|nd|rd|th)\s*Season"),
        // 英文序数词季名（kg41f2PGdC / BUG-3816 遗留）：`Second Season` / `Season Two`。
        // 只在与 `Season` 直接相连的词组里认——裸 `Second` / `Two` 是标题常见词。
        word_ordinal_season: JsRegex::ci(concat!(
            r"(?:^|[\s._-])(first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth)",
            r"[\s._]+Season(?=$|[\s._-])",
        )),
        season_cardinal_word: JsRegex::ci(concat!(
            r"(?:^|[\s._-])Season[\s._]+(one|two|three|four|five|six|seven|eight|nine|ten)",
            r"(?=$|[\s._-])",
        )),
        season_episode_block: JsRegex::ci(concat!(
            r"^(?:",
            r"第\s*([0-9零一二两三四五六七八九十]{1,3})\s*[季期]",
            r"|(\d{1,2})\s*(?:st|nd|rd|th)(?:\s*Season)?",
            r"|Season[\s._]*(\d{1,2})",
            r"|[Ss](\d{1,2})",
            r")\s*[-‐–—]\s*(\d{1,4})(?:[vV]\d{1,2})?(?:\s*(?:END|Fin|完))?$",
        )),
        season_word: JsRegex::ci(r"Season[\s._]*(\d{1,2})"),
        s_token: JsRegex::cs(r"(?:^|[\s._-])[Ss](\d{1,2})(?=$|[\s._-])"),
        part_season: JsRegex::ci(r"(?:^|[\s._-])Part[\s._]*(\d{1,2})(?=$|[\s._-])"),
        ascii_roman_tail: JsRegex::cs(r"(?:^|[\s._-])(II|III|IV)\s*$"),
        unicode_roman_tail: JsRegex::cs(r"([Ⅱ-Ⅹ])\s*$"),
        trailing_numeric_season: JsRegex::cs(r"(?:^|\s)([2-9])\s*$"),
        cjk_movie_inline: JsRegex::cs(r"剧场版|劇場版|总集篇|總集篇|総集編"),
        cjk_eiga_token: JsRegex::cs(r"(?:^|\s)映画(?=\s|$)"),
        ascii_movie_token: JsRegex::ci(r"(?:^|[\s._-])(?:the\s+)?movie(?=$|[\s._-])"),
        gekijouban_token: JsRegex::ci(r"(?:^|[\s._-])gekijouban(?=$|[\s._-])"),
        tilde_secondary: JsRegex::cs(r"[～〜~]([^～〜~]+)[～〜~]"),
        dash_split: JsRegex::cs(r"\s[-–—]\s+"),
        colon_split: JsRegex::cs(r"[:：]\s+"),
        all_digits: JsRegex::cs(r"^\d+$"),
        cleanup_head: JsRegex::cs(r"^[\s\-_.·～〜~]+"),
        cleanup_tail: JsRegex::cs(r"[\s\-_.·～〜~]+$"),
        trailing_year: JsRegex::cs(r"(?:^|[\s._])((?:19|20)\d{2})\s*$"),
        non_title_digits: JsRegex::cs(r"^[\d\s\-_.:年月日时分秒]+$"),
        non_title_device: JsRegex::ci(concat!(
            r"^(vid|img|mov|dsc|mvi|dji|gopro?|screenrecording|screenrecord|record)",
            r"[\s\-_.]*\d[\d\s\-_.:]*$",
        )),
        drive_letter: JsRegex::cs(r"^[A-Za-z]:$"),
        cjk_lang_marks: words(&[
            "简繁", "简日", "繁日", "简中", "繁中", "简体", "簡体", "简體", "繁体", "繁體", "内封",
            "內封", "内嵌", "內嵌", "外挂", "外掛", "双语", "雙語", "字幕",
        ]),
        group_marks: words(&["组", "組", "社", "队", "隊", "屋", "会", "會"]),
        lang_tokens: words(&[
            "cht", "chs", "gb", "big5", "jpsc", "jptc", "sc", "tc", "jp", "jpn", "chi", "chs&cht",
            "gb&big5",
        ]),
        cjk_movie_marks: words(&["剧场版", "劇場版", "映画", "总集篇", "總集篇", "総集編"]),
        generic_dir_names: words(&[
            "downloads",
            "download",
            "videos",
            "video",
            "movies",
            "movie",
            "films",
            "film",
            "media",
            "temp",
            "tmp",
            "cache",
            "desktop",
            "documents",
            "music",
            "pictures",
            "recordings",
            "anime",
            "animes",
            "动漫",
            "动画",
            "新番",
            "番剧",
            "电影",
            "影片",
            "视频",
            "下载",
            "桌面",
            "文档",
            "新建文件夹",
        ]),
    })
}

fn group_text<'a>(m: &Match, text: &'a [u16], index: usize) -> Option<&'a [u16]> {
    m.text(text, index)
}

/// 英文序数词 / 基数词（1–10，大小写不敏感）→ 数值；只服务于 `Season` 词组规则。
fn english_number_word(word: &[u16]) -> Option<i64> {
    let lower: String = String::from_utf16_lossy(word).to_ascii_lowercase();
    let n = match lower.as_str() {
        "first" | "one" => 1,
        "second" | "two" => 2,
        "third" | "three" => 3,
        "fourth" | "four" => 4,
        "fifth" | "five" => 5,
        "sixth" | "six" => 6,
        "seventh" | "seven" => 7,
        "eighth" | "eight" => 8,
        "ninth" | "nine" => 9,
        "tenth" | "ten" => 10,
        _ => return None,
    };
    Some(n)
}

fn group_int(m: &Match, text: &[u16], index: usize) -> i64 {
    parse_digits(group_text(m, text, index).expect("group participates"))
}

/// Dart `_hasTitleChars`：`[A-Za-z぀-ヿ㐀-鿿豈-﫿]`。
fn has_title_chars(text: &[u16]) -> bool {
    text.iter().any(|&u| {
        matches!(u, 0x41..=0x5A | 0x61..=0x7A | 0x3040..=0x30FF | 0x3400..=0x9FFF | 0xF900..=0xFAFF)
    })
}

fn contains_any(content: &[u16], marks: &[U16s]) -> bool {
    marks.iter().any(|m| contains(content, m))
}

fn non_empty_split<'t>(re: &JsRegex, text: &'t [u16]) -> Vec<&'t [u16]> {
    re.split(text)
        .into_iter()
        .filter(|t| !t.is_empty())
        .collect()
}

fn split_unit(text: &[u16], sep: u16) -> Vec<&[u16]> {
    text.split(|&u| u == sep).collect()
}

/// `text.replaceRange(start, end, ' ')`。
fn replace_range_space(text: &[u16], start: usize, end: usize) -> U16s {
    let mut out = Vec::with_capacity(text.len());
    out.extend_from_slice(&text[..start]);
    out.push(0x20);
    out.extend_from_slice(&text[end..]);
    out
}

/// Dart `_stripExtension`。
fn strip_extension<'a>(name: &'a [u16], env: &ParseEnv) -> &'a [u16] {
    let Some(dot) = name.iter().rposition(|&u| u == 0x2E) else {
        return name;
    };
    if dot == 0 {
        return name;
    }
    let ext = to_lower(&name[dot..]);
    if env.extensions.contains(&ext) {
        &name[..dot]
    } else {
        name
    }
}

fn bracket_closer(unit: u16) -> Option<u16> {
    match unit {
        0x5B => Some(0x5D),     // [ ]
        0x28 => Some(0x29),     // ( )
        0x3010 => Some(0x3011), // 【 】
        0xFF08 => Some(0xFF09), // （ ）
        _ => None,
    }
}

/// Dart `_extractBlocks`。
fn extract_blocks(name: &[u16]) -> (Vec<Block>, U16s) {
    let mut outside: U16s = Vec::with_capacity(name.len());
    let mut blocks = Vec::new();
    let mut i = 0;
    while i < name.len() {
        let ch = name[i];
        if let Some(closer) = bracket_closer(ch) {
            let Some(end) = index_of(name, &[closer], i + 1) else {
                outside.push(ch);
                i += 1;
                continue;
            };
            let content = trim(&name[i + 1..end]);
            if !content.is_empty() {
                blocks.push(Block {
                    content: content.to_vec(),
                    outside_before: outside.clone(),
                });
            }
            outside.push(0x20);
            i = end + 1;
        } else {
            outside.push(ch);
            i += 1;
        }
    }
    (blocks, outside)
}

fn is_noise_token(p: &Patterns, token: &[u16], include_lang: bool) -> bool {
    let t = to_lower(token);
    if include_lang && p.lang_tokens.contains(&t) {
        return true;
    }
    if p.source_token.has_match(&t) {
        return true;
    }
    if p.codec_tokens.iter().any(|re| re.has_match(&t)) {
        return true;
    }
    if t.contains(&0x2D) {
        let parts: Vec<&[u16]> = split_unit(&t, 0x2D)
            .into_iter()
            .filter(|s| !s.is_empty())
            .collect();
        if parts.len() >= 2
            && parts.iter().all(|part| {
                p.source_token.has_match(part)
                    || (include_lang && p.lang_tokens.iter().any(|l| l.as_slice() == *part))
                    || p.codec_tokens.iter().any(|re| re.has_match(part))
            })
        {
            return true;
        }
    }
    false
}

fn is_noise_block(p: &Patterns, content: &[u16], tokens: &[&[u16]]) -> bool {
    if contains(content, &w("新番")) {
        return true;
    }
    if contains_any(content, &p.cjk_lang_marks) && !contains_any(content, &p.group_marks) {
        return true;
    }
    !tokens.is_empty() && tokens.iter().all(|t| is_noise_token(p, t, true))
}

fn is_movie_block(p: &Patterns, content: &[u16], tokens: &[&[u16]]) -> bool {
    if contains_any(content, &p.cjk_movie_marks) {
        return true;
    }
    tokens.iter().any(|t| {
        let lower = to_lower(t);
        lower == w("movie") || lower == w("gekijouban")
    })
}

/// Dart `_parseCnNumeral`。
fn parse_cn_numeral(p: &Patterns, s: &[u16]) -> Option<i64> {
    fn digit(s: &[u16]) -> Option<i64> {
        if s.len() != 1 {
            return None;
        }
        Some(match s[0] {
            0x96F6 => 0, // 零
            0x4E00 => 1, // 一
            0x4E8C => 2, // 二
            0x4E24 => 2, // 两
            0x4E09 => 3, // 三
            0x56DB => 4, // 四
            0x4E94 => 5, // 五
            0x516D => 6, // 六
            0x4E03 => 7, // 七
            0x516B => 8, // 八
            0x4E5D => 9, // 九
            _ => return None,
        })
    }
    if p.all_digits.has_match(s) {
        return dart_str::dart_int_try_parse(s);
    }
    if let Some(ten) = s.iter().position(|&u| u == 0x5341) {
        let tens = if ten == 0 { Some(1) } else { digit(&s[..ten]) };
        let rest = &s[ten + 1..];
        let ones = if rest.is_empty() {
            Some(0)
        } else {
            digit(rest)
        };
        return match (tens, ones) {
            (Some(t), Some(o)) => Some(t * 10 + o),
            _ => None,
        };
    }
    digit(s)
}

fn classify_block(
    p: &Patterns,
    content: &[u16],
    index: usize,
    title_seen: bool,
    st: &mut State,
    title_blocks: &mut Vec<U16s>,
) {
    let tokens = non_empty_split(&p.tokenize, content);
    // ① 分辨率。
    for t in &tokens {
        if p.resolution_token.has_match(t) {
            if st.resolution.is_none() {
                st.resolution = Some(t.to_vec());
            }
            return;
        }
    }
    // ② 校验码。
    if p.checksum.has_match(content) {
        return;
    }
    // ③ 年份。
    if p.year_block.has_match(content) {
        if st.year.is_none() {
            st.year = Some(parse_digits(content));
        }
        return;
    }
    // ④ 块内 `第N话`。
    if let Some(m) = p.cn_episode_block.first_match(content) {
        if st.episode.is_none() {
            st.episode = Some(group_int(&m, content, 1));
        }
        return;
    }
    // ④' 块内「季 + 集」。
    if let Some(m) = p.season_episode_block.first_match(content) {
        if st.season.is_none() {
            st.season = match group_text(&m, content, 1) {
                Some(cn) => parse_cn_numeral(p, cn),
                None => {
                    let digits = group_text(&m, content, 2)
                        .or_else(|| group_text(&m, content, 3))
                        .or_else(|| group_text(&m, content, 4))
                        .expect("season group");
                    Some(parse_digits(digits))
                }
            };
        }
        if st.episode.is_none() {
            st.episode = Some(group_int(&m, content, 5));
        }
        return;
    }
    // ⑤ 纯数字集数。
    if p.plain_episode_block.has_match(content) {
        if title_seen && st.episode.is_none() {
            st.episode = Some(parse_digits(content));
        }
        return;
    }
    if let Some(m) = p.episode_end_block.first_match(content) {
        if title_seen && st.episode.is_none() {
            st.episode = Some(group_int(&m, content, 1));
        }
        return;
    }
    // ⑥ 电影提示。
    if is_movie_block(p, content, &tokens) {
        st.is_movie_hint = true;
        return;
    }
    // ⑦ 噪音。
    if is_noise_block(p, content, &tokens) {
        return;
    }
    // ⑧ 发布组。
    if index == 0 {
        if st.release_group.is_none() {
            st.release_group = Some(content.to_vec());
        }
        return;
    }
    // ⑨ 标题候选。
    title_blocks.push(content.to_vec());
}

/// Dart `_normalizeSeparators`。
fn normalize_separators(p: &Patterns, s: &[u16]) -> U16s {
    let space = [0x20u16];
    let base = replace_all_str(s, &[0x3000], &space);
    let base = p.whitespace.replace_all(&base, &space);
    let base = trim(&base).to_vec();
    let dot_separated = !base.contains(&0x20) && base.iter().filter(|&&u| u == 0x2E).count() >= 2;
    let out = replace_all_str(&base, &[0x5F], &space);
    let out = p.whitespace.replace_all(&out, &space);
    let mut out = trim(&out).to_vec();
    if dot_separated {
        let dotted = replace_all_str(&out, &[0x2E], &space);
        let dotted = p.whitespace.replace_all(&dotted, &space);
        out = trim(&dotted).to_vec();
    }
    out
}

/// Dart `_extractFirst`。
fn extract_first(text: U16s, re: &JsRegex, mut on_match: impl FnMut(&Match, &[u16])) -> U16s {
    match re.first_match(&text) {
        None => text,
        Some(m) => {
            on_match(&m, &text);
            replace_range_space(&text, m.start, m.end)
        }
    }
}

/// Dart `_cutTrailingNoiseTokens`。
fn cut_trailing_noise_tokens(p: &Patterns, text: &[u16], st: &mut State) -> U16s {
    let tokens: Vec<&[u16]> = split_unit(text, 0x20)
        .into_iter()
        .filter(|t| !t.is_empty())
        .collect();
    let cut = tokens
        .iter()
        .position(|t| p.resolution_token.has_match(t) || is_noise_token(p, t, false))
        .unwrap_or(tokens.len());
    if cut == tokens.len() {
        return text.to_vec();
    }
    for t in &tokens[cut..] {
        if p.resolution_token.has_match(t) && st.resolution.is_none() {
            st.resolution = Some(t.to_vec());
        }
    }
    tokens[..cut].join(&0x20)
}

/// Dart `_cleanupTitle`。
fn cleanup_title(p: &Patterns, s: &[u16]) -> U16s {
    let out = p.whitespace.replace_all(s, &[0x20]);
    let out = trim(&out).to_vec();
    let out = p.cleanup_head.replace_first(&out, &[]);
    let out = p.cleanup_tail.replace_first(&out, &[]);
    trim(&out).to_vec()
}

/// Dart `_takeTrailingYear`。
fn take_trailing_year(p: &Patterns, text: U16s, st: &mut State, env: &ParseEnv) -> U16s {
    if st.year.is_some() || st.keep_bare_year {
        return text;
    }
    let Some(m) = p.trailing_year.first_match(&text) else {
        return text;
    };
    if !has_title_chars(&text[..m.start]) {
        return text;
    }
    let year = group_int(&m, &text, 1);
    if year > env.current_year + 1 {
        return text;
    }
    st.year = Some(year);
    st.bare_year_taken = true;
    text[..m.start].to_vec()
}

/// Dart `_looksLikeNonTitle`。
fn looks_like_non_title(p: &Patterns, text: &[u16]) -> bool {
    let t = trim(text);
    t.is_empty() || p.non_title_digits.has_match(t) || p.non_title_device.has_match(t)
}

/// [FilenameParser.takeTrailingNumericSeason]：`(季号, 去季号标题)`。
pub fn take_trailing_numeric_season(text: &[u16]) -> Option<(i64, &[u16])> {
    let p = patterns();
    let m = p.trailing_numeric_season.first_match(text)?;
    let head = &text[..m.start];
    if !has_title_chars(head) {
        return None;
    }
    Some((group_int(&m, text, 1), trim(head)))
}

/// Dart `_parseTitleText`。
fn parse_title_text(p: &Patterns, raw: &[u16], st: &mut State, env: &ParseEnv) -> U16s {
    let mut text = normalize_separators(p, raw);
    if text.is_empty() {
        return Vec::new();
    }
    if p.plain_episode_block.has_match(&text) {
        if st.episode.is_none() {
            st.episode = Some(parse_digits(&text));
        }
        return Vec::new();
    }
    if looks_like_non_title(p, &text) {
        return Vec::new();
    }
    // ① SxxExx。
    if let Some(se) = p.season_episode.first_match(&text) {
        if st.season.is_none() {
            st.season = Some(group_int(&se, &text, 1));
        }
        if st.episode.is_none() {
            st.episode = Some(group_int(&se, &text, 2));
        }
        let head = text[..se.start].to_vec();
        if has_title_chars(&head) {
            let after = cleanup_title(p, &text[se.end..]);
            let cut = cut_trailing_noise_tokens(p, &after, st);
            let tail = cleanup_title(p, &cut);
            if !tail.is_empty() && st.secondary_title.is_none() {
                st.secondary_title = Some(tail);
            }
            text = head;
        } else {
            text = replace_range_space(&text, se.start, se.end);
        }
    }
    // ② 其余集数模式。
    for re in [
        &p.cn_episode,
        &p.cn_episode_suffix,
        &p.ep_token,
        &p.hash_episode,
        &p.dash_episode,
    ] {
        if st.episode.is_none() {
            text = extract_first(text, re, |m, t| st.episode = Some(group_int(m, t, 1)));
        }
    }
    // ③ 电影提示。
    if p.cjk_movie_inline.has_match(&text) {
        st.is_movie_hint = true;
        text = p.cjk_movie_inline.replace_all(&text, &[0x20]);
    }
    for re in [&p.cjk_eiga_token, &p.ascii_movie_token, &p.gekijouban_token] {
        text = extract_first(text, re, |_, _| st.is_movie_hint = true);
    }
    // ④ 季度模式。
    if st.season.is_none() {
        text = extract_first(text, &p.cn_season, |m, t| {
            st.season = parse_cn_numeral(p, group_text(m, t, 1).expect("group"))
        });
    }
    if st.season.is_none() {
        for re in [&p.word_ordinal_season, &p.season_cardinal_word] {
            if st.season.is_none() {
                text = extract_first(text, re, |m, t| {
                    st.season = english_number_word(group_text(m, t, 1).expect("group"))
                });
            }
        }
    }
    for re in [
        &p.ordinal_season,
        &p.season_word,
        &p.s_token,
        &p.part_season,
    ] {
        if st.season.is_none() {
            text = extract_first(text, re, |m, t| st.season = Some(group_int(m, t, 1)));
        }
    }
    // ⑤ 尾部噪音截断。
    text = cut_trailing_noise_tokens(p, &text, st);
    // ⑥ 尾部裸集数。
    if st.episode.is_none() {
        if let Some(bare) = p.bare_trailing_episode.first_match(&text) {
            if has_title_chars(&text[..bare.start]) {
                st.episode = Some(group_int(&bare, &text, 1));
                let len = text.len();
                text = replace_range_space(&text, bare.start, len);
            }
        }
    }
    // ⑥' 尾部裸年份。
    text = take_trailing_year(p, text, st, env);
    // ⑦ `～xxx～` 副标题。
    text = extract_first(text, &p.tilde_secondary, |m, t| {
        let sub = cleanup_title(p, group_text(m, t, 1).expect("group"));
        if !sub.is_empty() && st.secondary_title.is_none() {
            st.secondary_title = Some(sub);
        }
    });
    // ⑧ ` - xxx` 副标题；冒号只在罗马数字季度之后才算分隔。
    let mut divider = p.dash_split.first_match(&text);
    if divider.is_none() {
        if let Some(colon) = p.colon_split.first_match(&text) {
            let head = trim_right(&text[..colon.start]);
            if p.ascii_roman_tail.has_match(head) || p.unicode_roman_tail.has_match(head) {
                divider = Some(colon);
            }
        }
    }
    if let Some(d) = divider {
        let head = text[..d.start].to_vec();
        let tail = cleanup_title(p, &text[d.end..]);
        if !trim(&head).is_empty() && !tail.is_empty() && !p.all_digits.has_match(&tail) {
            if st.secondary_title.is_none() {
                st.secondary_title = Some(tail);
            }
            text = head;
        }
    }
    // ⑨ 结尾罗马数字季度。
    if st.season.is_none() {
        text = extract_first(text, &p.unicode_roman_tail, |m, t| {
            let unit = group_text(m, t, 1).expect("group")[0];
            st.season = Some(unit as i64 - 0x2160 + 1);
        });
    }
    if st.season.is_none() {
        text = extract_first(text, &p.ascii_roman_tail, |m, t| {
            let g = group_text(m, t, 1).expect("group");
            st.season = Some(match g.len() {
                2 if g == w("II").as_slice() => 2,
                3 => 3,
                _ => 4,
            });
        });
    }
    // ⑩ 结尾裸数字季号（门槛：已解出集号）。
    if st.season.is_none() && st.episode.is_some() {
        if let Some((season, title)) = take_trailing_numeric_season(&text) {
            st.season = Some(season);
            text = title.to_vec();
        }
    }
    let title = cleanup_title(p, &text);
    if looks_like_non_title(p, &title) {
        return Vec::new();
    }
    title
}

/// Dart `FilenameParser.parse`。
pub fn parse_name(raw: &[u16], env: &ParseEnv) -> ParsedName {
    let p = patterns();
    let name = strip_extension(trim(raw), env);
    let (blocks, outside) = extract_blocks(name);
    let mut st = State::default();
    let mut title_blocks: Vec<U16s> = Vec::new();
    for (i, b) in blocks.iter().enumerate() {
        let title_seen = has_title_chars(&b.outside_before) || !title_blocks.is_empty();
        classify_block(p, &b.content, i, title_seen, &mut st, &mut title_blocks);
    }
    let mut title_source: U16s = outside.clone();
    let mut before_title = st.clone();
    let mut title = parse_title_text(p, &outside, &mut st, env);
    if title.is_empty() {
        for tb in &title_blocks {
            title_source = tb.clone();
            before_title = st.clone();
            title = parse_title_text(p, tb, &mut st, env);
            if !title.is_empty() {
                break;
            }
        }
    }
    let mut title_with_trailing_year = None;
    if st.bare_year_taken && !before_title.bare_year_taken {
        before_title.keep_bare_year = true;
        let full = parse_title_text(p, &title_source, &mut before_title, env);
        if !full.is_empty() && full != title {
            title_with_trailing_year = Some(full);
        }
    }
    ParsedName {
        title,
        secondary_title: st.secondary_title,
        episode: st.episode,
        season: st.season,
        year: st.year,
        title_with_trailing_year,
        release_group: st.release_group,
        resolution: st.resolution,
        is_movie_hint: st.is_movie_hint,
    }
}

/// Dart `_isBadDirectoryName`。
fn is_bad_directory_name(p: &Patterns, name: &[u16]) -> bool {
    let t = trim(name);
    if t.len() <= 1 {
        return true;
    }
    if p.drive_letter.has_match(t) {
        return true;
    }
    if looks_like_non_title(p, t) {
        return true;
    }
    let lower = to_lower(t);
    if p.generic_dir_names.contains(&lower) {
        return true;
    }
    lower.starts_with(&w("新建文件夹")) || lower.starts_with(&w("new folder"))
}

/// Dart `FilenameParser.candidatesForPath`。
pub fn candidates_for_path(path: &[u16], env: &ParseEnv) -> Vec<ParsedName> {
    let p = patterns();
    let segments: Vec<&[u16]> = p
        .split_path
        .split(path)
        .into_iter()
        .map(trim)
        .filter(|s| !s.is_empty())
        .collect();
    let mut out = Vec::new();
    if segments.is_empty() {
        return out;
    }
    if segments.len() >= 2 {
        let dir = segments[segments.len() - 2];
        if !is_bad_directory_name(p, dir) {
            let parsed = parse_name(dir, env);
            if !parsed.title.is_empty() {
                out.push(parsed);
            }
        }
    }
    let file = parse_name(segments[segments.len() - 1], env);
    if !file.title.is_empty() || file.episode.is_some() {
        out.push(file);
    }
    out
}

// ─────────────────────────── 批量 C ABI ───────────────────────────

/// 每条记录的 i32 个数。布局（与 Dart 绑定一致）：
/// `[input, title.off, title.len, secondary.off, secondary.len, withYear.off, withYear.len,
///   group.off, group.len, resolution.off, resolution.len, episode, season, year, flags, 0]`；
/// 字符串 `len == -1` 表示 null；数值 `-1` 表示 null（所有取值都非负）；`flags` 位 0 = isMovieHint。
pub const RECORD_INTS: usize = 16;

/// 输出缓冲区：`[i32 记录数][记录 × RECORD_INTS 个 i32][u16 池]`，小端（主机序）。
pub fn encode_records(records: &[(usize, ParsedName)]) -> Vec<u8> {
    let mut ints: Vec<i32> = Vec::with_capacity(1 + records.len() * RECORD_INTS);
    let mut pool: Vec<u16> = Vec::new();
    ints.push(records.len() as i32);
    let put_str = |ints: &mut Vec<i32>, pool: &mut Vec<u16>, s: Option<&U16s>| match s {
        None => {
            ints.push(0);
            ints.push(-1);
        }
        Some(s) => {
            ints.push(pool.len() as i32);
            ints.push(s.len() as i32);
            pool.extend_from_slice(s);
        }
    };
    let num = |v: Option<i64>| -> i32 {
        match v {
            None => -1,
            Some(v) => {
                assert!(
                    (0..=i32::MAX as i64).contains(&v),
                    "parsed number out of range"
                );
                v as i32
            }
        }
    };
    for (input, r) in records {
        ints.push(*input as i32);
        put_str(&mut ints, &mut pool, Some(&r.title));
        put_str(&mut ints, &mut pool, r.secondary_title.as_ref());
        put_str(&mut ints, &mut pool, r.title_with_trailing_year.as_ref());
        put_str(&mut ints, &mut pool, r.release_group.as_ref());
        put_str(&mut ints, &mut pool, r.resolution.as_ref());
        ints.push(num(r.episode));
        ints.push(num(r.season));
        ints.push(num(r.year));
        ints.push(i32::from(r.is_movie_hint));
        ints.push(0);
    }
    let mut bytes = Vec::with_capacity(ints.len() * 4 + pool.len() * 2);
    for v in ints {
        bytes.extend_from_slice(&v.to_ne_bytes());
    }
    for u in pool {
        bytes.extend_from_slice(&u.to_ne_bytes());
    }
    bytes
}

/// 把 (池, 长度表) 切成各个字符串。长度和必须等于池长。
///
/// # Safety
/// 指针按长度可读（长度为 0 时可为空）。
pub(crate) unsafe fn split_pool<'a>(
    units: *const u16,
    units_len: usize,
    lens: *const u32,
    count: usize,
) -> Option<Vec<&'a [u16]>> {
    if (units_len > 0 && units.is_null()) || (count > 0 && lens.is_null()) {
        return None;
    }
    let pool: &[u16] = if units_len == 0 {
        &[]
    } else {
        std::slice::from_raw_parts(units, units_len)
    };
    let lens: &[u32] = if count == 0 {
        &[]
    } else {
        std::slice::from_raw_parts(lens, count)
    };
    let mut out = Vec::with_capacity(count);
    let mut offset = 0usize;
    for &len in lens {
        let end = offset.checked_add(len as usize)?;
        if end > pool.len() {
            return None;
        }
        out.push(&pool[offset..end]);
        offset = end;
    }
    (offset == pool.len()).then_some(out)
}

unsafe fn read_env(
    ext_units: *const u16,
    ext_units_len: usize,
    ext_lens: *const u32,
    ext_count: usize,
    current_year: i32,
) -> Option<ParseEnv> {
    let exts = split_pool(ext_units, ext_units_len, ext_lens, ext_count)?;
    Some(ParseEnv {
        extensions: exts.into_iter().map(<[u16]>::to_vec).collect(),
        current_year: current_year as i64,
    })
}

/// 批量 [parse_name]：输入 `count` 个字符串（`units` 池按 `lens` 切分），扩展名表同样按池给出。
/// 成功时 `*out_ptr` / `*out_len` 是 [encode_records] 布局的缓冲区（`ffc_free_bytes` 释放），
/// 记录与输入一一对应、`input` 字段即下标。
///
/// # Safety
/// 各指针按对应长度可读（长度 0 时可为空）；`out_ptr` / `out_len` 非空可写。
#[no_mangle]
pub unsafe extern "C" fn ffc_parse_filename_parse_batch(
    units: *const u16,
    units_len: usize,
    lens: *const u32,
    count: usize,
    ext_units: *const u16,
    ext_units_len: usize,
    ext_lens: *const u32,
    ext_count: usize,
    current_year: i32,
    out_ptr: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    if out_ptr.is_null() || out_len.is_null() {
        return status::NULL_ARGUMENT;
    }
    guard(|| {
        let Some(names) = split_pool(units, units_len, lens, count) else {
            return status::INVALID_ARGUMENT;
        };
        let Some(env) = read_env(ext_units, ext_units_len, ext_lens, ext_count, current_year)
        else {
            return status::INVALID_ARGUMENT;
        };
        let records: Vec<(usize, ParsedName)> = names
            .iter()
            .enumerate()
            .map(|(i, n)| (i, parse_name(n, &env)))
            .collect();
        hand_over_bytes(encode_records(&records), out_ptr, out_len);
        status::OK
    })
}

/// 批量 [candidates_for_path]：每个路径产出 0～2 条记录，`input` 字段是路径下标，
/// 同一路径的记录按「目录名候选 → 文件名候选」排列。参数与输出同
/// [ffc_parse_filename_parse_batch]。
///
/// # Safety
/// 同 [ffc_parse_filename_parse_batch]。
#[no_mangle]
pub unsafe extern "C" fn ffc_parse_filename_candidates_batch(
    units: *const u16,
    units_len: usize,
    lens: *const u32,
    count: usize,
    ext_units: *const u16,
    ext_units_len: usize,
    ext_lens: *const u32,
    ext_count: usize,
    current_year: i32,
    out_ptr: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    if out_ptr.is_null() || out_len.is_null() {
        return status::NULL_ARGUMENT;
    }
    guard(|| {
        let Some(paths) = split_pool(units, units_len, lens, count) else {
            return status::INVALID_ARGUMENT;
        };
        let Some(env) = read_env(ext_units, ext_units_len, ext_lens, ext_count, current_year)
        else {
            return status::INVALID_ARGUMENT;
        };
        let mut records: Vec<(usize, ParsedName)> = Vec::new();
        for (i, path) in paths.iter().enumerate() {
            records.extend(candidates_for_path(path, &env).into_iter().map(|r| (i, r)));
        }
        hand_over_bytes(encode_records(&records), out_ptr, out_len);
        status::OK
    })
}

/// 批量 [take_trailing_numeric_season]：`out` 由调用方分配 `count * 3` 个 i32，每个输入写
/// `[season, title_start, title_end]`（title 是输入的子串区间）；不是季号时 `season = -1`。
///
/// # Safety
/// `units` / `lens` 同上；`out` 指向 `count * 3` 个可写 i32。
#[no_mangle]
pub unsafe extern "C" fn ffc_parse_filename_trailing_season_batch(
    units: *const u16,
    units_len: usize,
    lens: *const u32,
    count: usize,
    out: *mut i32,
) -> i32 {
    if count > 0 && out.is_null() {
        return status::NULL_ARGUMENT;
    }
    guard(|| {
        let Some(texts) = split_pool(units, units_len, lens, count) else {
            return status::INVALID_ARGUMENT;
        };
        let out = if count == 0 {
            &mut [][..]
        } else {
            std::slice::from_raw_parts_mut(out, count * 3)
        };
        for (i, text) in texts.iter().enumerate() {
            let (season, start, end) = match take_trailing_numeric_season(text) {
                None => (-1, 0, 0),
                Some((season, title)) => {
                    let start = title.as_ptr() as usize - text.as_ptr() as usize;
                    let start = start / 2;
                    (season as i32, start as i32, (start + title.len()) as i32)
                }
            };
            out[i * 3] = season;
            out[i * 3 + 1] = start;
            out[i * 3 + 2] = end;
        }
        status::OK
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn env() -> ParseEnv {
        ParseEnv {
            extensions: [".mp4", ".mkv", ".avi", ".rmvb"]
                .iter()
                .map(|s| w(s))
                .collect(),
            current_year: 2026,
        }
    }

    fn s(v: &U16s) -> String {
        String::from_utf16_lossy(v)
    }

    #[test]
    fn all_patterns_compile() {
        let _ = patterns();
    }

    #[test]
    fn typical_fansub_name() {
        let r = parse_name(
            &w("[Lilith-Raws] Sousou no Frieren - 05 [Baha][WEB-DL][1080p][AVC AAC][CHT][MP4].mp4"),
            &env(),
        );
        assert_eq!(s(&r.title), "Sousou no Frieren");
        assert_eq!(r.episode, Some(5));
        assert_eq!(
            r.release_group.as_ref().map(s).as_deref(),
            Some("Lilith-Raws")
        );
        assert_eq!(r.resolution.as_ref().map(s).as_deref(), Some("1080p"));
    }

    /// kg41f2PGdC / BUG-3816 遗留：英文序数词 / 基数词季名。
    #[test]
    fn english_ordinal_season_words() {
        let cases: [(&str, &str, Option<i64>, Option<i64>); 11] = [
            (
                "[VCB-Studio] Yama no Susume Second Season [01][Ma10p_1080p][x265_flac].mkv",
                "Yama no Susume",
                Some(2),
                Some(1),
            ),
            (
                "[VCB-Studio] Yama no Susume Third Season [Ma10p_1080p]",
                "Yama no Susume",
                Some(3),
                None,
            ),
            ("Show THIRD SEASON - 05.mkv", "Show", Some(3), Some(5)),
            ("Show.second.season.07.mkv", "Show", Some(2), Some(7)),
            ("Show Season Two - 03.mkv", "Show", Some(2), Some(3)),
            ("Show season ten - 01.mkv", "Show", Some(10), Some(1)),
            ("Show First Season [12].mkv", "Show", Some(1), Some(12)),
            // 既有规则不变：数字序数仍由 ordinal_season 认。
            ("Show 2nd Season - 04.mkv", "Show", Some(2), Some(4)),
            // 不在 `Season` 词组里的序数词 / 基数词不算季。
            ("Second Chance - 01.mkv", "Second Chance", None, Some(1)),
            (
                "Two Seasons Later - 02.mkv",
                "Two Seasons Later",
                None,
                Some(2),
            ),
            (
                "The Seasoned Second - 03.mkv",
                "The Seasoned Second",
                None,
                Some(3),
            ),
        ];
        for (input, title, season, episode) in cases {
            let r = parse_name(&w(input), &env());
            assert_eq!(s(&r.title), title, "title of {input}");
            assert_eq!((r.season, r.episode), (season, episode), "{input}");
        }
    }

    #[test]
    fn season_episode_and_trailing_year() {
        let r = parse_name(&w("Mushoku.Tensei.S03E04.Title.1080p.WEB-DL.mkv"), &env());
        assert_eq!(s(&r.title), "Mushoku Tensei");
        assert_eq!((r.season, r.episode), (Some(3), Some(4)));
        assert_eq!(r.secondary_title.as_ref().map(s).as_deref(), Some("Title"));
        let r = parse_name(&w("Death Race 2000"), &env());
        assert_eq!(s(&r.title), "Death Race");
        assert_eq!(r.year, Some(2000));
        assert_eq!(
            r.title_with_trailing_year.as_ref().map(s).as_deref(),
            Some("Death Race 2000")
        );
        let r = parse_name(&w("Blade Runner 2049"), &env());
        assert_eq!(s(&r.title), "Blade Runner 2049");
    }

    #[test]
    fn trailing_season_offsets() {
        let text = w("  Hibike! Euphonium 2");
        let lens = [text.len() as u32];
        let mut out = [0i32; 3];
        let st = unsafe {
            ffc_parse_filename_trailing_season_batch(
                text.as_ptr(),
                text.len(),
                lens.as_ptr(),
                1,
                out.as_mut_ptr(),
            )
        };
        assert_eq!(st, status::OK);
        assert_eq!(out[0], 2);
        assert_eq!(
            s(&text[out[1] as usize..out[2] as usize].to_vec()),
            "Hibike! Euphonium"
        );
    }

    #[test]
    fn pool_length_mismatch_is_invalid() {
        let text = w("abc");
        let lens = [5u32];
        let mut ptr = std::ptr::null_mut();
        let mut len = 0usize;
        let st = unsafe {
            ffc_parse_filename_parse_batch(
                text.as_ptr(),
                text.len(),
                lens.as_ptr(),
                1,
                std::ptr::null(),
                0,
                std::ptr::null(),
                0,
                2026,
                &mut ptr,
                &mut len,
            )
        };
        assert_eq!(st, status::INVALID_ARGUMENT);
    }
}
