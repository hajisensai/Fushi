//! SRT / WebVTT / ASS 文件级解析（原 Dart `SrtParser` / `VttParser` / `AssParser` 的
//! `parseString`）。输入是去掉编码层后的 UTF-16 文本。

use super::dart::*;
use super::markup::{ass_color_to_argb, parse_markup, strip_html_tags, Markup};

/// 一条 cue 的解析结果（bookKey / chapterHref / sentenceIndex 等由 Dart 侧按下标补齐）。
pub struct Cue {
    pub start_ms: i64,
    pub end_ms: i64,
    pub markup: Markup,
    /// 仅 ASS：引用的样式对象下标（[AssResult::styles]），-1 = 无。
    pub style_id: i32,
    /// 仅 ASS：Dialogue 行级 MarginL / MarginR / MarginV 覆盖。
    pub event_margins: [Option<f64>; 3],
    /// 仅 ASS：本条解析时的 PlayResX / PlayResY（已应用 384 / 288 缺省）。
    pub play_res: Option<(f64, f64)>,
}

/// `[V4+ Styles]` 一行解析出的样式（原 `SubtitleCueStyle` 的 20 个字段）。
#[derive(Clone, Debug, Default, PartialEq)]
pub struct CueStyle {
    pub font_name: Option<Vec<u16>>,
    pub primary_color_argb: Option<i64>,
    pub outline_color_argb: Option<i64>,
    pub shadow_color_argb: Option<i64>,
    pub font_size_px: Option<f64>,
    pub outline_width_px: Option<f64>,
    pub shadow_depth_px: Option<f64>,
    pub bold: Option<bool>,
    pub italic: Option<bool>,
    pub underline: Option<bool>,
    pub strike_out: Option<bool>,
    /// `\an` 码 1..=9；None = 无。
    pub anchor: Option<u8>,
    pub margin_v: Option<f64>,
    pub margin_l: Option<f64>,
    pub margin_r: Option<f64>,
    pub secondary_color_argb: Option<i64>,
    pub spacing_px: Option<f64>,
    pub angle_deg: Option<f64>,
    pub scale_x_pct: Option<f64>,
    pub scale_y_pct: Option<f64>,
}

pub struct AssResult {
    pub styles: Vec<CueStyle>,
    pub cues: Vec<Cue>,
    /// `end <= start` 被丢弃的条数（原实现只在 debug 模式打印）。
    pub skipped: u32,
}

fn strip_bom(content: &[u16]) -> &[u16] {
    if !content.is_empty() && content[0] == 0xFEFF {
        &content[1..]
    } else {
        content
    }
}

/// `.replaceAll('\r\n', '\n').replaceAll('\r', '\n')`。
fn normalize_newlines(s: &[u16]) -> Vec<u16> {
    let mut out = Vec::with_capacity(s.len());
    let mut i = 0;
    while i < s.len() {
        let c = s[i];
        if c == 0x0D {
            out.push(0x0A);
            if i + 1 < s.len() && s[i + 1] == 0x0A {
                i += 1;
            }
        } else {
            out.push(c);
        }
        i += 1;
    }
    out
}

/// `.split(RegExp(r'\n{2,}'))`（空串 → `[""]`）。
fn split_blank_lines(s: &[u16]) -> Vec<&[u16]> {
    let mut out = Vec::new();
    let mut start = 0;
    let mut i = 0;
    while i < s.len() {
        if s[i] == 0x0A && i + 1 < s.len() && s[i + 1] == 0x0A {
            out.push(&s[start..i]);
            let mut j = i;
            while j < s.len() && s[j] == 0x0A {
                j += 1;
            }
            start = j;
            i = j;
        } else {
            i += 1;
        }
    }
    out.push(&s[start..]);
    out
}

/// `lines.skip(from).where((l) => l.isNotEmpty).join(r'\N')`：多行 cue 用 ASS 硬换行
/// `\N` 连接（#2312）。markup 解析把换行处记进 `line_breaks`（渲染层据此按作者的行
/// 分行），plain_text 里仍是空格——查词 / 制卡 / DB 文本与旧的空格连接逐字节一致。
/// 此前直接以空格连接，双语字幕（原文一行 + 译文一行）在屏上并成一排。
fn join_text_lines(lines: &[&[u16]], from: usize) -> Vec<u16> {
    let mut out = Vec::new();
    let mut first = true;
    for l in lines.iter().skip(from) {
        if l.is_empty() {
            continue;
        }
        if !first {
            out.push(u('\\'));
            out.push(u('N'));
        }
        out.extend_from_slice(l);
        first = false;
    }
    out
}

/// `(\d{2})` 两位数。
fn two_digits(s: &[u16], p: usize) -> Option<i64> {
    if p + 2 <= s.len() && is_digit(s[p]) && is_digit(s[p + 1]) {
        Some(((s[p] - 0x30) * 10 + (s[p + 1] - 0x30)) as i64)
    } else {
        None
    }
}

/// `(\d{1,3})$` 补齐到 3 位后的毫秒（`padRight(3, '0')`）。
fn frac_ms(s: &[u16], p: usize) -> Option<i64> {
    let n = s.len().checked_sub(p)?;
    if !(1..=3).contains(&n) || !s[p..].iter().all(|&c| is_digit(c)) {
        return None;
    }
    let mut v = 0i64;
    for k in 0..3 {
        v = v * 10 + if k < n { (s[p + k] - 0x30) as i64 } else { 0 };
    }
    Some(v)
}

/// `^(\d+):(\d{2}):(\d{2})\.(\d{1,3})$`：返回 (h 的区间, m, s, ms)。`\d+` 后必须是 `:`，
/// 贪婪无回溯分支。
fn match_hms(s: &[u16]) -> Option<((usize, usize), i64, i64, i64)> {
    let h = count_while(s, 0, is_digit);
    if h == 0 || !(h < s.len() && s[h] == u(':')) {
        return None;
    }
    let m = two_digits(s, h + 1)?;
    if !(h + 3 < s.len() && s[h + 3] == u(':')) {
        return None;
    }
    let sec = two_digits(s, h + 4)?;
    if !(h + 6 < s.len() && s[h + 6] == u('.')) {
        return None;
    }
    let ms = frac_ms(s, h + 7)?;
    Some(((0, h), m, sec, ms))
}

/// `^(\d+):(\d{2})\.(\d{1,3})$`。
fn match_ms(s: &[u16]) -> Option<((usize, usize), i64, i64)> {
    let mdig = count_while(s, 0, is_digit);
    if mdig == 0 || !(mdig < s.len() && s[mdig] == u(':')) {
        return None;
    }
    let sec = two_digits(s, mdig + 1)?;
    if !(mdig + 3 < s.len() && s[mdig + 3] == u('.')) {
        return None;
    }
    let ms = frac_ms(s, mdig + 4)?;
    Some(((0, mdig), sec, ms))
}

fn hms_to_ms(h: i64, m: i64, s: i64, ms: i64) -> i64 {
    h.wrapping_mul(3_600_000)
        .wrapping_add(m * 60_000)
        .wrapping_add(s * 1000)
        .wrapping_add(ms)
}

/// `timecode.replaceAll(',', '.')`。
fn commas_to_dots(s: &[u16]) -> Vec<u16> {
    s.iter()
        .map(|&c| if c == u(',') { u('.') } else { c })
        .collect()
}

/// SRT / ASS 共用的 `H:MM:SS.x` → 毫秒（越界分 / 秒返回 None，`int.parse` 越界抛错）。
fn parse_hms(normalized: &[u16]) -> DResult<Option<i64>> {
    let Some(((hs, he), m, s, ms)) = match_hms(normalized) else {
        return Ok(None);
    };
    let h = parse_int_digits(&normalized[hs..he])?;
    if m >= 60 || s >= 60 {
        return Ok(None);
    }
    Ok(Some(hms_to_ms(h, m, s, ms)))
}

// ── SRT ─────────────────────────────────────────────────────────────────────

fn srt_time_line(line: &[u16]) -> DResult<Option<(i64, i64)>> {
    let parts = split_str(line, b"-->");
    if parts.len() != 2 {
        return Ok(None);
    }
    let start = parse_hms(&commas_to_dots(trim(parts[0])))?;
    let end = parse_hms(&commas_to_dots(trim(parts[1])))?;
    Ok(match (start, end) {
        (Some(a), Some(b)) => Some((a, b)),
        _ => None,
    })
}

pub fn parse_srt(content: &[u16]) -> DResult<Vec<Cue>> {
    let normalized = normalize_newlines(strip_bom(content));
    let mut cues = Vec::new();
    for block in split_blank_lines(&normalized) {
        let lines: Vec<&[u16]> = split_unit(block, 0x0A).into_iter().map(trim).collect();
        if lines.len() < 3 {
            continue;
        }
        let Some(idx) = lines.iter().position(|l| contains_ascii(l, b"-->")) else {
            continue;
        };
        let Some((start, end)) = srt_time_line(lines[idx])? else {
            continue;
        };
        let raw = join_text_lines(&lines, idx + 1);
        let markup = parse_markup(&strip_html_tags(&raw), None, None, 0)?;
        if markup.plain_text.is_empty() {
            continue;
        }
        cues.push(Cue {
            start_ms: start,
            end_ms: end,
            markup,
            style_id: -1,
            event_margins: [None; 3],
            play_res: None,
        });
    }
    Ok(cues)
}

// ── VTT ─────────────────────────────────────────────────────────────────────

/// `parts[k].trim().split(RegExp(r'\s+')).first`：trim 之后开头不可能是 `\s`（Dart trim 的
/// 空白集合包含它），所以就是第一个 `\s` 之前的部分（空串得到空串）。
fn first_ws_token(part: &[u16]) -> &[u16] {
    let t = trim(part);
    let end = t.iter().position(|&c| is_js_ws(c)).unwrap_or(t.len());
    &t[..end]
}

fn vtt_timecode(timecode: &[u16]) -> DResult<Option<i64>> {
    let normalized = commas_to_dots(timecode);
    if let Some(((hs, he), m, s, ms)) = match_hms(&normalized) {
        let h = parse_int_digits(&normalized[hs..he])?;
        if m >= 60 || s >= 60 {
            return Ok(None);
        }
        return Ok(Some(hms_to_ms(h, m, s, ms)));
    }
    if let Some(((ms_, me), s, ms)) = match_ms(&normalized) {
        let m = parse_int_digits(&normalized[ms_..me])?;
        if s >= 60 {
            return Ok(None);
        }
        return Ok(Some(
            m.wrapping_mul(60_000)
                .wrapping_add(s * 1000)
                .wrapping_add(ms),
        ));
    }
    Ok(None)
}

fn vtt_time_line(line: &[u16]) -> DResult<Option<(i64, i64)>> {
    let parts = split_str(line, b"-->");
    if parts.len() < 2 {
        return Ok(None);
    }
    let start = vtt_timecode(first_ws_token(parts[0]))?;
    let end = vtt_timecode(first_ws_token(parts[1]))?;
    Ok(match (start, end) {
        (Some(a), Some(b)) => Some((a, b)),
        _ => None,
    })
}

pub fn parse_vtt(content: &[u16]) -> DResult<Vec<Cue>> {
    let normalized = normalize_newlines(strip_bom(content));
    let mut cues = Vec::new();
    for block in split_blank_lines(&normalized) {
        let lines: Vec<&[u16]> = split_unit(block, 0x0A)
            .into_iter()
            .map(trim)
            .filter(|l| !l.is_empty())
            .collect();
        if lines.is_empty() {
            continue;
        }
        let first = lines[0];
        if starts_with_ascii(first, b"WEBVTT")
            || starts_with_ascii(first, b"NOTE")
            || starts_with_ascii(first, b"STYLE")
            || starts_with_ascii(first, b"REGION")
        {
            continue;
        }
        let Some(idx) = lines.iter().position(|l| contains_ascii(l, b"-->")) else {
            continue;
        };
        let Some((start, end)) = vtt_time_line(lines[idx])? else {
            continue;
        };
        let raw = join_text_lines(&lines, idx + 1);
        let markup = parse_markup(&strip_html_tags(&raw), None, None, 0)?;
        if markup.plain_text.is_empty() {
            continue;
        }
        cues.push(Cue {
            start_ms: start,
            end_ms: end,
            markup,
            style_id: -1,
            event_margins: [None; 3],
            play_res: None,
        });
    }
    Ok(cues)
}

// ── ASS ─────────────────────────────────────────────────────────────────────

/// `List<String>.indexOf(name)`。
fn index_of_col(cols: &[Vec<u16>], name: &[u8]) -> i64 {
    cols.iter()
        .position(|c| eq_ascii(c, name))
        .map_or(-1, |p| p as i64)
}

/// `s.substring(n).split(',').map((c) => c.trim().toLowerCase()).toList()`。
fn format_cols(rest: &[u16]) -> Vec<Vec<u16>> {
    split_unit(rest, u(','))
        .into_iter()
        .map(|c| to_lower(trim(c)))
        .collect()
}

/// `&H([0-9a-fA-F]{1,8})&?$`（不锚定开头，`firstMatch` 取最左成功位置）。
fn search_style_color(raw: &[u16]) -> Option<&[u16]> {
    let mut from = 0;
    while let Some(p) = index_of_ascii(raw, b"&H", from) {
        let q = p + 2;
        let run = count_while(raw, q, is_hex);
        if (1..=8).contains(&run) {
            let after = q + run;
            if after == raw.len() || (after + 1 == raw.len() && raw[after] == u('&')) {
                return Some(&raw[q..after]);
            }
        }
        from = p + 1;
    }
    None
}

/// 原 `_parseStyleRow`。
fn parse_style_row(body: &[u16], cols: &[Vec<u16>]) -> CueStyle {
    let cells: Vec<&[u16]> = split_unit(body, u(',')).into_iter().map(trim).collect();
    let cell = |name: &[u8]| -> Option<&[u16]> {
        let idx = index_of_col(cols, name);
        if idx < 0 || idx as usize >= cells.len() {
            return None;
        }
        let v = cells[idx as usize];
        if v.is_empty() {
            None
        } else {
            Some(v)
        }
    };
    let color = |name: &[u8]| {
        cell(name)
            .and_then(search_style_color)
            .map(ass_color_to_argb)
    };
    let number = |name: &[u8]| cell(name).and_then(double_try_parse);
    let flag = |name: &[u8]| cell(name).and_then(int_try_parse).map(|v| v != 0);
    let anchor = cell(b"alignment")
        .and_then(int_try_parse)
        .filter(|a| (1..=9).contains(a))
        .map(|a| a as u8);
    CueStyle {
        font_name: cell(b"fontname").map(<[u16]>::to_vec),
        primary_color_argb: color(b"primarycolour"),
        outline_color_argb: color(b"outlinecolour"),
        shadow_color_argb: color(b"backcolour"),
        font_size_px: number(b"fontsize"),
        outline_width_px: number(b"outline"),
        shadow_depth_px: number(b"shadow"),
        bold: flag(b"bold"),
        italic: flag(b"italic"),
        underline: flag(b"underline"),
        strike_out: flag(b"strikeout"),
        anchor,
        margin_v: number(b"marginv"),
        margin_l: number(b"marginl"),
        margin_r: number(b"marginr"),
        secondary_color_argb: color(b"secondarycolour"),
        spacing_px: number(b"spacing"),
        angle_deg: number(b"angle"),
        scale_x_pct: number(b"scalex"),
        scale_y_pct: number(b"scaley"),
    }
}

struct RawCue {
    start: i64,
    end: Option<i64>,
    markup: Markup,
    style_id: i32,
    event_margins: [Option<f64>; 3],
    play_res: (f64, f64),
}

pub fn parse_ass(content: &[u16], include_drawings: bool) -> DResult<AssResult> {
    let normalized = normalize_newlines(strip_bom(content));
    let lines = split_unit(&normalized, 0x0A);

    let mut in_events = false;
    let mut in_styles = false;
    let (mut start_col, mut end_col, mut text_col, mut style_col) = (-1i64, -1i64, -1i64, -1i64);
    let (mut margin_l_col, mut margin_r_col, mut margin_v_col, mut layer_col) =
        (-1i64, -1i64, -1i64, -1i64);
    let mut play_res_x: Option<f64> = None;
    let mut play_res_y: Option<f64> = None;

    let mut style_objects: Vec<CueStyle> = Vec::new();
    // 小写样式名 → 样式对象下标（同名后者覆盖，同 Dart Map 赋值）。
    let mut style_map: std::collections::HashMap<Vec<u16>, i32> = std::collections::HashMap::new();
    let mut style_format_cols: Option<Vec<Vec<u16>>> = None;
    let mut raw_cues: Vec<RawCue> = Vec::new();

    for line in lines {
        let trimmed = trim(line);
        let low_section = to_lower(trimmed);

        if eq_ascii(&low_section, b"[events]") {
            in_events = true;
            in_styles = false;
            continue;
        }
        if starts_with_ascii(&low_section, b"[v4") && ends_with_ascii(&low_section, b"styles]") {
            in_styles = true;
            in_events = false;
            style_format_cols = None;
            continue;
        }
        if starts_with_ascii(trimmed, b"[") && ends_with_ascii(trimmed, b"]") {
            if in_events {
                break;
            }
            in_styles = false;
            in_events = false;
        }

        if in_styles {
            if starts_with_ascii(trimmed, b"Format:") {
                style_format_cols = Some(format_cols(&trimmed[7..]));
                continue;
            }
            if starts_with_ascii(trimmed, b"Style:") {
                if let Some(cols) = &style_format_cols {
                    let body = &trimmed[6..];
                    let parsed = parse_style_row(body, cols);
                    let name_idx = index_of_col(cols, b"name");
                    if name_idx >= 0 {
                        let cells = split_unit(body, u(','));
                        let ni = name_idx as usize;
                        if ni < cells.len() {
                            let name = trim(cells[ni]);
                            if !name.is_empty() {
                                let id = style_objects.len() as i32;
                                style_objects.push(parsed);
                                style_map.insert(to_lower(name), id);
                            }
                        }
                    }
                }
            }
            continue;
        }

        if !in_events {
            // low_section 即 trimmed.toLowerCase()；映射不改长度，下标与 trimmed 对齐。
            if starts_with_ascii(&low_section, b"playresx:") {
                play_res_x = double_try_parse(trim(&trimmed[9..]));
            } else if starts_with_ascii(&low_section, b"playresy:") {
                play_res_y = double_try_parse(trim(&trimmed[9..]));
            }
            continue;
        }

        if starts_with_ascii(trimmed, b"Format:") {
            let cols = format_cols(&trimmed[7..]);
            start_col = index_of_col(&cols, b"start");
            end_col = index_of_col(&cols, b"end");
            text_col = index_of_col(&cols, b"text");
            style_col = index_of_col(&cols, b"style");
            margin_l_col = index_of_col(&cols, b"marginl");
            margin_r_col = index_of_col(&cols, b"marginr");
            margin_v_col = index_of_col(&cols, b"marginv");
            layer_col = index_of_col(&cols, b"layer");
            continue;
        }

        if starts_with_ascii(trimmed, b"Dialogue:") && start_col >= 0 && text_col >= 0 {
            let data = trim(&trimmed[9..]);
            let parts = split_unit(data, u(','));
            let len = parts.len() as i64;
            if len <= text_col {
                continue;
            }
            if start_col >= len {
                // 原实现 `parts[startCol]` 越界：增长型 List 抛 RangeError.range(i, 0, len-1, 'length')。
                return Err(DartError::Range {
                    value: start_col,
                    start: 0,
                    end: len - 1,
                    name: "length",
                });
            }
            let Some(start_ms) = parse_hms(trim(parts[start_col as usize]))? else {
                continue;
            };
            let end_ms = if end_col >= 0 && end_col < len {
                parse_hms(trim(parts[end_col as usize]))?
            } else {
                None
            };
            let mut style_id = -1i32;
            if style_col >= 0 && style_col < len {
                if let Some(&id) = style_map.get(&to_lower(trim(parts[style_col as usize]))) {
                    style_id = id;
                }
            }
            let event_margin = |col: i64| -> Option<f64> {
                if col < 0 || col >= len {
                    return None;
                }
                match double_try_parse(trim(parts[col as usize])) {
                    // 刻意写成 !(v <= 0.0)：NaN 也通过（同旧 Dart 实现），不能改成 v > 0.0。
                    #[allow(clippy::neg_cmp_op_on_partial_ord)]
                    Some(v) if !(v <= 0.0) => Some(v),
                    _ => None,
                }
            };
            let margins = [
                event_margin(margin_l_col),
                event_margin(margin_r_col),
                event_margin(margin_v_col),
            ];
            let mut raw_text: Vec<u16> = Vec::new();
            for (k, p) in parts.iter().enumerate().skip(text_col as usize) {
                if k > text_col as usize {
                    raw_text.push(u(','));
                }
                raw_text.extend_from_slice(p);
            }
            let layer = if layer_col >= 0 && layer_col < len {
                int_try_parse(trim(parts[layer_col as usize])).unwrap_or(0)
            } else {
                0
            };
            let prx = play_res_x.unwrap_or(384.0);
            let pry = play_res_y.unwrap_or(288.0);
            let markup = parse_markup(&raw_text, Some(prx), Some(pry), layer)?;
            if markup.plain_text.is_empty() && !(include_drawings && markup.drawing.is_some()) {
                continue;
            }
            raw_cues.push(RawCue {
                start: start_ms,
                end: end_ms,
                markup,
                style_id,
                event_margins: margins,
                play_res: (prx, pry),
            });
        }
    }

    // 按起始时间稳定排序（同起始保持文件序）。
    raw_cues.sort_by_key(|c| c.start);

    let mut cues: Vec<Cue> = Vec::with_capacity(raw_cues.len());
    let mut skipped = 0u32;
    let starts: Vec<i64> = raw_cues.iter().map(|c| c.start).collect();
    for (i, rc) in raw_cues.into_iter().enumerate() {
        let fallback = if i + 1 < starts.len() {
            starts[i + 1]
        } else {
            rc.start.wrapping_add(5000)
        };
        let end = rc.end.unwrap_or(fallback);
        if end <= rc.start {
            skipped += 1;
            continue;
        }
        cues.push(Cue {
            start_ms: rc.start,
            end_ms: end,
            markup: rc.markup,
            style_id: rc.style_id,
            event_margins: rc.event_margins,
            play_res: Some(rc.play_res),
        });
    }
    Ok(AssResult {
        styles: style_objects,
        cues,
        skipped,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn w(s: &str) -> Vec<u16> {
        s.encode_utf16().collect()
    }

    #[test]
    fn srt_basic() {
        let cues = parse_srt(&w("1\r\n00:00:01,000 --> 00:00:04,230\r\n吾輩は<i>猫</i>である。\r\n\r\n2\n00:00:04.5 --> 00:00:08.100\n名前は\nまだない。\n")).unwrap();
        assert_eq!(cues.len(), 2);
        assert_eq!((cues[0].start_ms, cues[0].end_ms), (1000, 4230));
        assert_eq!(
            String::from_utf16_lossy(&cues[0].markup.plain_text),
            "吾輩は猫である。"
        );
        assert_eq!((cues[1].start_ms, cues[1].end_ms), (4500, 8100));
        assert_eq!(
            String::from_utf16_lossy(&cues[1].markup.plain_text),
            "名前は まだない。"
        );
        // 多行 cue 在原行边界处记硬换行（#2312），plain_text 仍以空格连接。
        assert_eq!(cues[1].markup.line_breaks, Some(vec![3]));
        assert_eq!(cues[0].markup.line_breaks, None);
    }

    #[test]
    fn vtt_basic_and_empty_start() {
        let cues = parse_vtt(&w("WEBVTT\n\n01:02.5 --> 01:03.000 align:left\n<b>x</b>\n")).unwrap();
        assert_eq!(cues.len(), 1);
        assert_eq!((cues[0].start_ms, cues[0].end_ms), (62500, 63000));
        assert_eq!(parse_vtt(&w("--> 00:01.000\nx")).unwrap().len(), 0);
    }

    #[test]
    fn ass_basic() {
        let src = "[Script Info]\nPlayResX: 1920\nPlayResY: 1080\n\n[V4+ Styles]\nFormat: Name, Fontname, Fontsize, PrimaryColour, Alignment\nStyle: Default,Arial,60,&H00FFFFFF,2\n\n[Events]\nFormat: Layer, Start, End, Style, Text\nDialogue: 1,0:00:02.00,0:00:03.00,default,b,c\nDialogue: 0,0:00:01.00,,Default,{\\an8}a\n";
        let r = parse_ass(&w(src), false).unwrap();
        assert_eq!(r.styles.len(), 1);
        assert_eq!(r.cues.len(), 2);
        assert_eq!((r.cues[0].start_ms, r.cues[0].end_ms), (1000, 2000));
        assert_eq!(r.cues[0].markup.anchor, 8);
        assert_eq!(
            String::from_utf16_lossy(&r.cues[1].markup.plain_text),
            "b,c"
        );
        assert_eq!(r.cues[1].markup.layer, 1);
        assert_eq!(r.cues[1].style_id, 0);
        assert_eq!(r.cues[1].play_res, Some((1920.0, 1080.0)));
    }
}
