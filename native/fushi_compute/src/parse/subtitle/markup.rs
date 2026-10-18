//! 单条字幕 cue 原文 → 结构化 markup（原 Dart `parseSubtitleMarkup`）与 HTML / VTT 行内
//! 标签剥离（原 Dart `stripHtmlTags`）。
//!
//! 原实现是一组正则；这里逐条手写成扫描器。每个匹配器的注释写着它复刻的原正则，并说明为什么
//! 贪婪匹配在该位置没有可行的回溯分支（有分支的地方按回溯顺序显式枚举）。数字文法
//! `-?\d+(?:\.\d+)?` 无歧义，所以「锚定到串尾」等价于「余下部分整体符合文法」。

use super::dart::*;
use super::grapheme;

/// 行内样式（原 `_Style`）。`k_mode`：1 = 'k'、2 = 'kf'、3 = 'ko'。
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Style {
    pub italic: bool,
    pub bold: bool,
    pub underline: bool,
    pub strike: bool,
    pub color_argb: Option<i64>,
    pub font_size_px: Option<f64>,
    pub font_name: Option<Vec<u16>>,
    pub outline_color_argb: Option<i64>,
    pub shadow_color_argb: Option<i64>,
    pub outline_width_px: Option<f64>,
    pub shadow_depth_px: Option<f64>,
    pub blur: Option<f64>,
    pub fill_opacity: Option<f64>,
    pub letter_spacing_px: Option<f64>,
    pub scale_x: Option<f64>,
    pub scale_y: Option<f64>,
    pub k_mode: Option<u8>,
    pub k_start_cs: Option<i64>,
    pub k_dur_cs: Option<i64>,
}

impl Style {
    pub fn has_style(&self) -> bool {
        self.italic
            || self.bold
            || self.underline
            || self.strike
            || self.color_argb.is_some()
            || self.font_size_px.is_some()
            || self.font_name.is_some()
            || self.outline_color_argb.is_some()
            || self.shadow_color_argb.is_some()
            || self.outline_width_px.is_some()
            || self.shadow_depth_px.is_some()
            || self.fill_opacity.is_some()
            || self.letter_spacing_px.is_some()
            || self.scale_x.is_some()
            || self.scale_y.is_some()
            || self.k_mode.is_some()
            || matches!(self.blur, Some(b) if b > 0.0)
    }
}

/// plainText 上 `[start, end)` 字素区间的行内样式。
#[derive(Clone, Debug, PartialEq)]
pub struct Span {
    pub start: i64,
    pub end: i64,
    pub style: Style,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum SegOp {
    Move = 0,
    Line = 1,
    Cubic = 2,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Segment {
    pub op: SegOp,
    pub x1: f64,
    pub y1: f64,
    pub x2: f64,
    pub y2: f64,
    pub x3: f64,
    pub y3: f64,
}

impl Segment {
    fn mv(x1: f64, y1: f64) -> Self {
        Segment {
            op: SegOp::Move,
            x1,
            y1,
            x2: 0.0,
            y2: 0.0,
            x3: 0.0,
            y3: 0.0,
        }
    }
    fn line(x1: f64, y1: f64) -> Self {
        Segment {
            op: SegOp::Line,
            x1,
            y1,
            x2: 0.0,
            y2: 0.0,
            x3: 0.0,
            y3: 0.0,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Clip {
    pub inverse: bool,
    pub segments: Vec<Segment>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Drawing {
    pub segments: Vec<Segment>,
    pub min_x: f64,
    pub min_y: f64,
    pub max_x: f64,
    pub max_y: f64,
    pub baseline_offset_fraction: f64,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Fade {
    Simple {
        fade_in_ms: i64,
        fade_out_ms: i64,
    },
    Full {
        op1: f64,
        op2: f64,
        op3: f64,
        t1: i64,
        t2: i64,
        t3: i64,
        t4: i64,
    },
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Move {
    pub x1: f64,
    pub y1: f64,
    pub x2: f64,
    pub y2: f64,
    pub t1: Option<i64>,
    pub t2: Option<i64>,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Scale {
    pub from_x: f64,
    pub from_y: f64,
    pub to_x: f64,
    pub to_y: f64,
    pub t1: Option<i64>,
    pub t2: Option<i64>,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Transition {
    pub t1: Option<i64>,
    pub t2: Option<i64>,
    pub accel: f64,
    pub alpha_to: Option<f64>,
    pub color_to_argb: Option<i64>,
    pub blur_to: Option<f64>,
    pub bord_to: Option<f64>,
    pub frz_to_deg: Option<f64>,
}

impl Transition {
    fn has_target(&self) -> bool {
        self.alpha_to.is_some()
            || self.color_to_argb.is_some()
            || self.blur_to.is_some()
            || self.bord_to.is_some()
            || self.frz_to_deg.is_some()
    }
}

/// 解析结果（`SubtitleMarkup` 里由解析产生的部分；cueStyle / playRes 由调用方透传）。
#[derive(Clone, Debug, PartialEq)]
pub struct Markup {
    pub plain_text: Vec<u16>,
    pub spans: Vec<Span>,
    /// 行内 `\an` 码（1..=9）；0 = 无（调用方再回退 cueStyle.anchor）。
    pub anchor: u8,
    pub pos: Option<(f64, f64)>,
    /// None = 无 `\N`（Dart 侧为 `const <int>[]`）。
    pub line_breaks: Option<Vec<i64>>,
    pub fade: Option<Fade>,
    pub rotation_deg: Option<f64>,
    pub scale: Option<Scale>,
    pub mv: Option<Move>,
    pub layer: i64,
    pub clip: Option<Clip>,
    pub transitions: Vec<Transition>,
    pub rotation_x_deg: Option<f64>,
    pub rotation_y_deg: Option<f64>,
    pub shear_x: Option<f64>,
    pub shear_y: Option<f64>,
    pub drawing: Option<Drawing>,
    /// 绘图样式快照（序列化时不带 k 字段，同原实现）。
    pub drawing_style: Option<Style>,
}

#[derive(Default)]
struct Transform {
    rotation_deg: Option<f64>,
    scale_x: f64,
    scale_y: f64,
    scale_set: bool,
    t_scale_x: Option<f64>,
    t_scale_y: Option<f64>,
    t_start_ms: Option<i64>,
    t_end_ms: Option<i64>,
    mv: Option<Move>,
    clip: Option<Clip>,
    frx_deg: Option<f64>,
    fry_deg: Option<f64>,
    fax_shear: Option<f64>,
    fay_shear: Option<f64>,
    transitions: Vec<Transition>,
    k_accum_cs: i64,
}

struct DrawingState {
    active: bool,
    scale: i64,
    baseline_offset_px: f64,
    buffer: Vec<u16>,
    style: Option<Style>,
}

impl DrawingState {
    fn set_scale(&mut self, n: i64) {
        self.active = n > 0;
        if n > 0 {
            self.scale = n;
        }
    }
}

struct Ctx<'a> {
    style: &'a mut Style,
    anchor: &'a mut u8,
    pos: &'a mut Option<(f64, f64)>,
    fade: &'a mut Option<Fade>,
    xf: &'a mut Transform,
    drawing: &'a mut DrawingState,
    play_res_x: Option<f64>,
    play_res_y: Option<f64>,
}

/// 原 `parseSubtitleMarkup(raw, playResX:, playResY:, layer:)`。
pub fn parse_markup(
    raw: &[u16],
    play_res_x: Option<f64>,
    play_res_y: Option<f64>,
    layer: i64,
) -> DResult<Markup> {
    let mut segments: Vec<(Vec<u16>, Style)> = Vec::new();
    let mut cur: Vec<u16> = Vec::new();
    let mut style = Style::default();
    let mut anchor = 0u8;
    let mut pos: Option<(f64, f64)> = None;
    let mut fade: Option<Fade> = None;
    let mut xf = Transform {
        scale_x: 1.0,
        scale_y: 1.0,
        ..Default::default()
    };
    let mut drawing = DrawingState {
        active: false,
        scale: 1,
        baseline_offset_px: 0.0,
        buffer: Vec::new(),
        style: None,
    };

    let n = raw.len();
    let mut i = 0;
    while i < n {
        let c = raw[i];
        if c == u('{') {
            match index_of_unit(raw, u('}'), i + 1) {
                None => {
                    // 无闭合括号：剩余当普通文本。
                    cur.extend_from_slice(&raw[i..]);
                    break;
                }
                Some(close) => {
                    if !cur.is_empty() {
                        segments.push((std::mem::take(&mut cur), style.clone()));
                    }
                    let mut ctx = Ctx {
                        style: &mut style,
                        anchor: &mut anchor,
                        pos: &mut pos,
                        fade: &mut fade,
                        xf: &mut xf,
                        drawing: &mut drawing,
                        play_res_x,
                        play_res_y,
                    };
                    apply_override_block(&raw[i + 1..close], &mut ctx)?;
                    i = close + 1;
                    continue;
                }
            }
        }
        if drawing.active {
            if drawing.style.is_none() {
                drawing.style = Some(style.clone());
            }
            drawing.buffer.push(c);
            i += 1;
            continue;
        }
        if c == u('\\') && i + 1 < n {
            let next = raw[i + 1];
            if next == u('N') {
                cur.push(u('\n'));
                i += 2;
                continue;
            }
            if next == u('n') || next == u('h') {
                cur.push(u(' '));
                i += 2;
                continue;
            }
        }
        cur.push(c);
        i += 1;
    }
    if !cur.is_empty() {
        segments.push((cur, style.clone()));
    }

    if !segments.is_empty() {
        let first = trim_left(&segments[0].0).to_vec();
        segments[0].0 = first;
        let last_index = segments.len() - 1;
        let last = trim_right(&segments[last_index].0).to_vec();
        segments[last_index].0 = last;
        segments.retain(|s| !s.0.is_empty());
    }

    let mut plain: Vec<u16> = Vec::new();
    let mut spans: Vec<Span> = Vec::new();
    let mut g: i64 = 0;
    for (text, seg_style) in segments {
        let len = grapheme::count(&text) as i64;
        if len > 0 && seg_style.has_style() {
            spans.push(Span {
                start: g,
                end: g + len,
                style: seg_style,
            });
        }
        plain.extend_from_slice(&text);
        g += len;
    }

    let has_scale = xf.scale_set || xf.t_scale_x.is_some() || xf.t_scale_y.is_some();
    let scale = if has_scale {
        Some(Scale {
            from_x: xf.scale_x,
            from_y: xf.scale_y,
            to_x: xf.t_scale_x.unwrap_or(xf.scale_x),
            to_y: xf.t_scale_y.unwrap_or(xf.scale_y),
            t1: xf.t_start_ms,
            t2: xf.t_end_ms,
        })
    } else {
        None
    };

    let drawing_shape = if trim(&drawing.buffer).is_empty() {
        None
    } else {
        parse_ass_drawing(
            &drawing.buffer,
            drawing.scale,
            play_res_x,
            play_res_y,
            drawing.baseline_offset_px,
        )
    };
    let drawing_style = match (&drawing_shape, drawing.style) {
        (Some(_), Some(ds)) if ds.has_style() => Some(ds),
        _ => None,
    };

    let mut line_breaks = None;
    if plain.contains(&u('\n')) {
        let mut breaks = Vec::new();
        let mut gi = 0i64;
        grapheme::for_each(&plain, |s, e| {
            if e - s == 1 && plain[s] == u('\n') {
                breaks.push(gi);
            }
            gi += 1;
        });
        for c in plain.iter_mut() {
            if *c == u('\n') {
                *c = u(' ');
            }
        }
        line_breaks = Some(breaks);
    }

    Ok(Markup {
        plain_text: plain,
        spans,
        anchor,
        pos,
        line_breaks,
        fade,
        rotation_deg: xf.rotation_deg,
        scale,
        mv: xf.mv,
        layer,
        clip: xf.clip,
        transitions: xf.transitions,
        rotation_x_deg: xf.frx_deg,
        rotation_y_deg: xf.fry_deg,
        shear_x: xf.fax_shear,
        shear_y: xf.fay_shear,
        drawing: drawing_shape,
        drawing_style,
    })
}

// ── 小型匹配工具 ─────────────────────────────────────────────────────────────

/// `-?\d+(?:\.\d+)?`（`neg` 时允许前导 `-`）从 [p] 起的贪婪匹配，返回结束位置。
fn num_at(s: &[u16], p: usize, neg: bool) -> Option<usize> {
    let mut q = p;
    if neg && q < s.len() && s[q] == u('-') {
        q += 1;
    }
    let d = count_while(s, q, is_digit);
    if d == 0 {
        return None;
    }
    q += d;
    if q + 1 < s.len() && s[q] == u('.') && is_digit(s[q + 1]) {
        q += 1;
        q += count_while(s, q, is_digit);
    }
    Some(q)
}

/// `\d+` 从 [p] 起的贪婪匹配。
fn int_at(s: &[u16], p: usize, neg: bool) -> Option<usize> {
    let mut q = p;
    if neg && q < s.len() && s[q] == u('-') {
        q += 1;
    }
    let d = count_while(s, q, is_digit);
    if d == 0 {
        None
    } else {
        Some(q + d)
    }
}

#[inline]
fn skip_ws(s: &[u16], p: usize) -> usize {
    p + count_while(s, p, is_js_ws)
}

#[inline]
fn at(s: &[u16], p: usize, c: char) -> bool {
    p < s.len() && s[p] == u(c)
}

/// `^<prefix>(-?\d+(?:\.\d+)?)$`：返回数字部分。
fn anchored_num<'a>(tag: &'a [u16], prefix: &[u8], neg: bool) -> Option<&'a [u16]> {
    if !starts_with_ascii(tag, prefix) {
        return None;
    }
    let p = prefix.len();
    match num_at(tag, p, neg) {
        Some(e) if e == tag.len() => Some(&tag[p..]),
        _ => None,
    }
}

/// `^<prefix>(\d+)$`。
fn anchored_int<'a>(tag: &'a [u16], prefix: &[u8]) -> Option<&'a [u16]> {
    if !starts_with_ascii(tag, prefix) || tag.len() == prefix.len() {
        return None;
    }
    let rest = &tag[prefix.len()..];
    if rest.iter().all(|&c| is_digit(c)) {
        Some(rest)
    } else {
        None
    }
}

/// `^<prefix>&H([0-9a-fA-F]{1,8})&?$`（prefix 后紧跟 `&H`）：返回十六进制部分。
fn anchored_color<'a>(tag: &'a [u16], p: usize) -> Option<&'a [u16]> {
    if !has_ascii_at(tag, p, b"&H") {
        return None;
    }
    let q = p + 2;
    let run = count_while(tag, q, is_hex);
    if run == 0 || run > 8 {
        // run > 8：贪婪取 8 位后下一个仍是十六进制，回溯更短也一样，失败。
        return None;
    }
    let after = q + run;
    if after == tag.len() || (after + 1 == tag.len() && tag[after] == u('&')) {
        Some(&tag[q..after])
    } else {
        None
    }
}

/// `\(\s*N\s*,\s*N ... \s*\)$` 形状的参数表：依次匹配 [kinds]（true = 浮点 `-?\d+(\.\d+)?`，
/// false = 整数 `\d+`），逗号分隔、两侧可有空白、以 `)` 收尾到串尾。返回各参数区间。
/// 数字后只能跟空白 / `,` / `)`，贪婪无回溯分支。
fn paren_args(tag: &[u16], open: usize, kinds: &[bool]) -> Option<Vec<(usize, usize)>> {
    if !at(tag, open, '(') {
        return None;
    }
    let mut p = open + 1;
    let mut out = Vec::with_capacity(kinds.len());
    for (k, &is_float) in kinds.iter().enumerate() {
        if k > 0 {
            if !at(tag, p, ',') {
                return None;
            }
            p += 1;
        }
        p = skip_ws(tag, p);
        let e = if is_float {
            num_at(tag, p, true)?
        } else {
            int_at(tag, p, false)?
        };
        out.push((p, e));
        p = skip_ws(tag, e);
    }
    if at(tag, p, ')') && p + 1 == tag.len() {
        Some(out)
    } else {
        None
    }
}

/// ASS 颜色十六进制（BGR，1..8 位）→ 0xFFRRGGBB（原 `assColorToArgb`）。
pub fn ass_color_to_argb(hex: &[u16]) -> i64 {
    let v = parse_hex_u32(hex);
    let b = (v >> 16) & 0xFF;
    let g = (v >> 8) & 0xFF;
    let r = v & 0xFF;
    0xFF000000 | (r << 16) | (g << 8) | b
}

fn alpha_to_opacity(hex: &[u16]) -> f64 {
    let v = 1.0 - parse_hex_u32(hex) as f64 / 255.0;
    v.clamp(0.0, 1.0)
}

/// `^(?:1a|alpha)&?H?([0-9A-Fa-f]{1,2})&?$`：按回溯顺序枚举 `&?` / `H?` / `{2,1}` / `&?`。
fn anchored_alpha(tag: &[u16]) -> Option<&[u16]> {
    let p = if starts_with_ascii(tag, b"1a") {
        2
    } else if starts_with_ascii(tag, b"alpha") {
        5
    } else {
        return None;
    };
    let amp_choices: &[usize] = if at(tag, p, '&') { &[1, 0] } else { &[0] };
    for &amp in amp_choices {
        let q = p + amp;
        let h_choices: &[usize] = if at(tag, q, 'H') { &[1, 0] } else { &[0] };
        for &h in h_choices {
            let r = q + h;
            let run = count_while(tag, r, is_hex).min(2);
            for len in (1..=run).rev() {
                let after = r + len;
                if after == tag.len() || (after + 1 == tag.len() && tag[after] == u('&')) {
                    return Some(&tag[r..after]);
                }
            }
        }
    }
    None
}

/// 解析单个 `{...}` 块（原 `_applyOverrideBlock`）。
fn apply_override_block(block: &[u16], ctx: &mut Ctx) -> DResult<()> {
    // \t(...) 先整体抽出（`\\t\(([^)]*)\)` 全局替换为空），按出现顺序解析。
    let mut working: Vec<u16> = Vec::with_capacity(block.len());
    let mut i = 0;
    let mut scan = 0;
    loop {
        let mut found = None;
        let mut j = scan;
        while j + 2 < block.len() {
            if block[j] == u('\\') && block[j + 1] == u('t') && block[j + 2] == u('(') {
                found = Some(j);
                break;
            }
            j += 1;
        }
        let Some(j) = found else { break };
        let Some(close) = index_of_unit(block, u(')'), j + 3) else {
            // 之后任何候选都需要一个 `)`，而 j+3 之后已经没有。
            break;
        };
        parse_transition(&block[j + 3..close], ctx.xf)?;
        working.extend_from_slice(&block[i..j]);
        i = close + 1;
        scan = i;
    }
    working.extend_from_slice(&block[i..]);

    let tags = split_unit(&working, u('\\'));
    for raw_tag in tags.iter().skip(1) {
        let tag = trim(raw_tag);
        if tag.is_empty() {
            continue;
        }
        apply_tag(tag, ctx)?;
    }
    Ok(())
}

/// `\pos` / `\move` 的门槛：`playResX != null && playResX > 0`（NaN 被拒）。
fn valid_play_res(x: Option<f64>, y: Option<f64>) -> Option<(f64, f64)> {
    match (x, y) {
        (Some(x), Some(y)) if x > 0.0 && y > 0.0 => Some((x, y)),
        _ => None,
    }
}

/// `\clip` / `\p` 绘图的门槛：`playResX == null || playResX <= 0` 才拒绝——写法与
/// [valid_play_res] 相反，所以 NaN **通过**（原实现如此，结果里是 NaN 坐标）。
fn drawing_play_res(x: Option<f64>, y: Option<f64>) -> Option<(f64, f64)> {
    match (x, y) {
        (Some(x), Some(y)) if !(x <= 0.0) && !(y <= 0.0) => Some((x, y)),
        _ => None,
    }
}

fn apply_tag(tag: &[u16], ctx: &mut Ctx) -> DResult<()> {
    let len = tag.len();

    // ^an?([1-9])$
    {
        let d = if len == 2 && tag[0] == u('a') {
            Some(tag[1])
        } else if len == 3 && tag[0] == u('a') && tag[1] == u('n') {
            Some(tag[2])
        } else {
            None
        };
        if let Some(d) = d {
            if (0x31..=0x39).contains(&d) {
                *ctx.anchor = (d - 0x30) as u8;
                return Ok(());
            }
        }
    }

    // ^pos\(\s*(N)\s*,\s*(N)\s*\)$（PlayRes 无效时落到后续规则）
    if starts_with_ascii(tag, b"pos") {
        if let Some(args) = paren_args(tag, 3, &[true, true]) {
            if let Some((rx, ry)) = valid_play_res(ctx.play_res_x, ctx.play_res_y) {
                let x = parse_decimal(&tag[args[0].0..args[0].1]);
                let y = parse_decimal(&tag[args[1].0..args[1].1]);
                *ctx.pos = Some((x / rx, y / ry));
                return Ok(());
            }
        }
    }

    // ^([ibus])(\d+)$
    if len >= 2
        && matches!(tag[0], 0x69 | 0x62 | 0x75 | 0x73)
        && tag[1..].iter().all(|&c| is_digit(c))
    {
        let on = parse_int_digits(&tag[1..])? > 0;
        match tag[0] {
            0x69 => ctx.style.italic = on,
            0x62 => ctx.style.bold = on,
            0x75 => ctx.style.underline = on,
            _ => ctx.style.strike = on,
        }
        return Ok(());
    }

    // ^fs(\d+(?:\.\d+)?)$
    if let Some(v) = anchored_num(tag, b"fs", false) {
        ctx.style.font_size_px = Some(parse_decimal(v));
        return Ok(());
    }

    // ^1?c&H(hex{1,8})&?$
    {
        let hex = if starts_with_ascii(tag, b"1c") {
            anchored_color(tag, 2)
        } else if starts_with_ascii(tag, b"c") {
            anchored_color(tag, 1)
        } else {
            None
        };
        if let Some(hex) = hex {
            ctx.style.color_argb = Some(ass_color_to_argb(hex));
            return Ok(());
        }
    }
    if starts_with_ascii(tag, b"3c") {
        if let Some(hex) = anchored_color(tag, 2) {
            ctx.style.outline_color_argb = Some(ass_color_to_argb(hex));
            return Ok(());
        }
    }
    if starts_with_ascii(tag, b"4c") {
        if let Some(hex) = anchored_color(tag, 2) {
            ctx.style.shadow_color_argb = Some(ass_color_to_argb(hex));
            return Ok(());
        }
    }

    // \fn<字体名>
    if starts_with_ascii(tag, b"fn") && len > 2 {
        let name = trim(&tag[2..]);
        if !name.is_empty() {
            ctx.style.font_name = Some(name.to_vec());
        }
        return Ok(());
    }

    if let Some(v) = anchored_num(tag, b"bord", false) {
        ctx.style.outline_width_px = Some(parse_decimal(v));
        return Ok(());
    }
    if let Some(v) = anchored_num(tag, b"shad", false) {
        ctx.style.shadow_depth_px = Some(parse_decimal(v));
        return Ok(());
    }

    // ^p(\d+)$
    if let Some(v) = anchored_int(tag, b"p") {
        let n = parse_int_digits(v)?;
        ctx.drawing.set_scale(n);
        return Ok(());
    }
    // ^pbo(-?N)$
    if let Some(v) = anchored_num(tag, b"pbo", true) {
        ctx.drawing.baseline_offset_px = parse_decimal(v);
        return Ok(());
    }

    // ^(?:blur|be)(N)$
    {
        let v = anchored_num(tag, b"blur", false).or_else(|| anchored_num(tag, b"be", false));
        if let Some(v) = v {
            let b = parse_decimal(v);
            ctx.style.blur = if b > 0.0 { Some(b) } else { None };
            return Ok(());
        }
    }

    // ^fad\(\s*(\d+)\s*,\s*(\d+)\s*\)$
    if starts_with_ascii(tag, b"fad") {
        if let Some(args) = paren_args(tag, 3, &[false, false]) {
            let a = parse_int_digits(&tag[args[0].0..args[0].1])?;
            let b = parse_int_digits(&tag[args[1].0..args[1].1])?;
            *ctx.fade = Some(Fade::Simple {
                fade_in_ms: a,
                fade_out_ms: b,
            });
            return Ok(());
        }
    }
    // ^fade\(\s*(\d+)\s*, ... 7 个 ... \)$
    if starts_with_ascii(tag, b"fade") {
        if let Some(args) = paren_args(tag, 4, &[false; 7]) {
            let mut v = [0i64; 7];
            for (k, &(s, e)) in args.iter().enumerate() {
                v[k] = parse_int_digits(&tag[s..e])?;
            }
            let to_op = |a: i64| 1.0 - (a.clamp(0, 255) as f64 / 255.0);
            *ctx.fade = Some(Fade::Full {
                op1: to_op(v[0]),
                op2: to_op(v[1]),
                op3: to_op(v[2]),
                t1: v[3],
                t2: v[4],
                t3: v[5],
                t4: v[6],
            });
            return Ok(());
        }
    }

    // tag == 'r' || ^r[A-Za-z0-9_ \-]+$
    if tag[0] == u('r')
        && (len == 1
            || tag[1..]
                .iter()
                .all(|&c| is_word(c) || c == u(' ') || c == u('-')))
    {
        *ctx.style = Style::default();
        return Ok(());
    }

    // ^frz?(-?N)$
    if starts_with_ascii(tag, b"fr") {
        let p = if at(tag, 2, 'z') { 3 } else { 2 };
        if let Some(e) = num_at(tag, p, true) {
            if e == len {
                ctx.xf.rotation_deg = Some(parse_decimal(&tag[p..]));
                return Ok(());
            }
        }
    }

    if let Some(v) = anchored_num(tag, b"fscx", false) {
        let s = parse_decimal(v) / 100.0;
        ctx.style.scale_x = if s == 1.0 { None } else { Some(s) };
        ctx.xf.scale_x = s;
        ctx.xf.scale_set = true;
        return Ok(());
    }
    if let Some(v) = anchored_num(tag, b"fscy", false) {
        let s = parse_decimal(v) / 100.0;
        ctx.style.scale_y = if s == 1.0 { None } else { Some(s) };
        ctx.xf.scale_y = s;
        ctx.xf.scale_set = true;
        return Ok(());
    }

    // ^move\(N,N,N,N(?:,\d+,\d+)?\)$（各处可有空白；PlayRes 无效时落到后续规则）
    if starts_with_ascii(tag, b"move") {
        let args = paren_args(tag, 4, &[true, true, true, true, false, false])
            .or_else(|| paren_args(tag, 4, &[true, true, true, true]));
        if let Some(args) = args {
            if let Some((rx, ry)) = valid_play_res(ctx.play_res_x, ctx.play_res_y) {
                let f = |k: usize| parse_decimal(&tag[args[k].0..args[k].1]);
                let x1 = f(0) / rx;
                let y1 = f(1) / ry;
                let x2 = f(2) / rx;
                let y2 = f(3) / ry;
                let (t1, t2) = if args.len() == 6 {
                    (
                        Some(parse_int_digits(&tag[args[4].0..args[4].1])?),
                        Some(parse_int_digits(&tag[args[5].0..args[5].1])?),
                    )
                } else {
                    (None, None)
                };
                ctx.xf.mv = Some(Move {
                    x1,
                    y1,
                    x2,
                    y2,
                    t1,
                    t2,
                });
                return Ok(());
            }
        }
    }

    if let Some(hex) = anchored_alpha(tag) {
        ctx.style.fill_opacity = Some(alpha_to_opacity(hex));
        return Ok(());
    }

    // ^(i?)clip\((.*)\)$（`.` 不跨行终止符）
    {
        let (inverse, p) = if has_ascii_at(tag, 0, b"iclip(") {
            (true, 6)
        } else if has_ascii_at(tag, 0, b"clip(") {
            (false, 5)
        } else {
            (false, usize::MAX)
        };
        if p != usize::MAX
            && len > p
            && tag[len - 1] == u(')')
            && !tag[p..len - 1].iter().any(|&c| is_line_terminator(c))
        {
            if let Some(clip) =
                parse_ass_clip(inverse, &tag[p..len - 1], ctx.play_res_x, ctx.play_res_y)
            {
                ctx.xf.clip = Some(clip);
            }
            return Ok(());
        }
    }

    if let Some(v) = anchored_num(tag, b"fsp", true) {
        ctx.style.letter_spacing_px = Some(parse_decimal(v));
        return Ok(());
    }
    if let Some(v) = anchored_num(tag, b"frx", true) {
        ctx.xf.frx_deg = Some(parse_decimal(v));
        return Ok(());
    }
    if let Some(v) = anchored_num(tag, b"fry", true) {
        ctx.xf.fry_deg = Some(parse_decimal(v));
        return Ok(());
    }
    if let Some(v) = anchored_num(tag, b"fax", true) {
        ctx.xf.fax_shear = Some(parse_decimal(v));
        return Ok(());
    }
    if let Some(v) = anchored_num(tag, b"fay", true) {
        ctx.xf.fay_shear = Some(parse_decimal(v));
        return Ok(());
    }

    // ^(k|K|kf|ko)(N)$（按交替顺序）
    {
        let hit = [
            (&b"k"[..], 1u8),
            (&b"K"[..], 2u8),
            (&b"kf"[..], 2u8),
            (&b"ko"[..], 3u8),
        ]
        .iter()
        .find_map(|&(prefix, mode)| anchored_num(tag, prefix, false).map(|v| (v, mode)));
        if let Some((v, mode)) = hit {
            let dur = round_to_int(parse_decimal(v))?;
            ctx.style.k_mode = Some(mode);
            ctx.style.k_start_cs = Some(ctx.xf.k_accum_cs);
            ctx.style.k_dur_cs = Some(dur);
            ctx.xf.k_accum_cs = ctx.xf.k_accum_cs.wrapping_add(dur);
            return Ok(());
        }
    }
    Ok(())
}

/// 无锚点搜索 `\\<prefix>(数字)`：最左出现处取贪婪数字。
fn search_prefix_num<'a>(s: &'a [u16], prefix: &[u8], neg: bool) -> Option<&'a [u16]> {
    let mut from = 0;
    while let Some(p) = index_of_ascii(s, prefix, from) {
        let q = p + prefix.len();
        if let Some(e) = num_at(s, q, neg) {
            return Some(&s[q..e]);
        }
        from = p + 1;
    }
    None
}

/// `\\frz?(-?N)`（无锚点）。
fn search_frz(s: &[u16]) -> Option<&[u16]> {
    let mut from = 0;
    while let Some(p) = index_of_ascii(s, b"\\fr", from) {
        let q = if at(s, p + 3, 'z') { p + 4 } else { p + 3 };
        if let Some(e) = num_at(s, q, true) {
            return Some(&s[q..e]);
        }
        from = p + 1;
    }
    None
}

/// `\\(?:1a|alpha)&?H?([0-9A-Fa-f]{1,2})&?`（无锚点）。
fn search_alpha(s: &[u16]) -> Option<&[u16]> {
    let mut from = 0;
    while let Some(p) = index_of_unit(s, u('\\'), from) {
        let q = if has_ascii_at(s, p + 1, b"1a") {
            Some(p + 3)
        } else if has_ascii_at(s, p + 1, b"alpha") {
            Some(p + 6)
        } else {
            None
        };
        if let Some(q) = q {
            let mut r = q;
            if at(s, r, '&') {
                r += 1;
            }
            if at(s, r, 'H') {
                r += 1;
            }
            // 取了 `&` / `H` 之后不是十六进制时，回溯不取它们只会让下一个字符变成 `&` / `H`，
            // 同样不是十六进制，所以只有这一种可能。
            let run = count_while(s, r, is_hex).min(2);
            if run > 0 {
                return Some(&s[r..r + run]);
            }
        }
        from = p + 1;
    }
    None
}

/// `\\1?c&H([0-9A-Fa-f]{1,8})&?`（无锚点）。
fn search_color(s: &[u16]) -> Option<&[u16]> {
    let mut from = 0;
    while let Some(p) = index_of_unit(s, u('\\'), from) {
        let q = if has_ascii_at(s, p + 1, b"1c&H") {
            Some(p + 5)
        } else if has_ascii_at(s, p + 1, b"c&H") {
            Some(p + 4)
        } else {
            None
        };
        if let Some(q) = q {
            let run = count_while(s, q, is_hex).min(8);
            if run > 0 {
                return Some(&s[q..q + run]);
            }
        }
        from = p + 1;
    }
    None
}

/// `\\(?:blur|be)(N)`（无锚点）。
fn search_blur(s: &[u16]) -> Option<&[u16]> {
    let mut from = 0;
    while let Some(p) = index_of_unit(s, u('\\'), from) {
        for prefix in [&b"blur"[..], &b"be"[..]] {
            if has_ascii_at(s, p + 1, prefix) {
                let q = p + 1 + prefix.len();
                if let Some(e) = num_at(s, q, false) {
                    return Some(&s[q..e]);
                }
            }
        }
        from = p + 1;
    }
    None
}

/// 原 `_parseTransition`。
fn parse_transition(inner: &[u16], xf: &mut Transform) -> DResult<()> {
    let mut t1 = None;
    let mut t2 = None;
    let mut accel = 1.0;
    let mut rest = inner;
    let mut has_times = false;

    // ^\s*(-?\d+)\s*,\s*(-?\d+)\s*(?:,\s*(-?N)\s*)?,
    let times = (|| {
        let mut p = skip_ws(inner, 0);
        let e1 = int_at(inner, p, true)?;
        let g1 = (p, e1);
        p = skip_ws(inner, e1);
        if !at(inner, p, ',') {
            return None;
        }
        p = skip_ws(inner, p + 1);
        let e2 = int_at(inner, p, true)?;
        let g2 = (p, e2);
        p = skip_ws(inner, e2);
        // 可选组 `,\s*N\s*` 之后必须是 `,`；组失败时退回直接匹配这个位置的 `,`。
        if at(inner, p, ',') {
            let mut q = skip_ws(inner, p + 1);
            if let Some(e3) = num_at(inner, q, true) {
                let g3 = (q, e3);
                q = skip_ws(inner, e3);
                if at(inner, q, ',') {
                    return Some((g1, g2, Some(g3), q + 1));
                }
            }
            return Some((g1, g2, None, p + 1));
        }
        None
    })();
    if let Some((g1, g2, g3, end)) = times {
        t1 = Some(parse_int_digits(&inner[g1.0..g1.1])?);
        t2 = Some(parse_int_digits(&inner[g2.0..g2.1])?);
        if let Some(g3) = g3 {
            accel = parse_decimal(&inner[g3.0..g3.1]);
        }
        rest = &inner[end..];
        has_times = true;
    } else {
        // ^\s*(-?N)\s*,
        let p = skip_ws(inner, 0);
        if let Some(e) = num_at(inner, p, true) {
            let q = skip_ws(inner, e);
            if at(inner, q, ',') {
                accel = parse_decimal(&inner[p..e]);
                rest = &inner[q + 1..];
            }
        }
    }
    if has_times {
        xf.t_start_ms = t1;
        xf.t_end_ms = t2;
    }
    if let Some(v) = search_prefix_num(rest, b"\\fscx", false) {
        xf.t_scale_x = Some(parse_decimal(v) / 100.0);
    }
    if let Some(v) = search_prefix_num(rest, b"\\fscy", false) {
        xf.t_scale_y = Some(parse_decimal(v) / 100.0);
    }
    let tr = Transition {
        t1,
        t2,
        accel,
        alpha_to: search_alpha(rest).map(alpha_to_opacity),
        color_to_argb: search_color(rest).map(ass_color_to_argb),
        blur_to: search_blur(rest).map(parse_decimal),
        bord_to: search_prefix_num(rest, b"\\bord", false).map(parse_decimal),
        frz_to_deg: search_frz(rest).map(parse_decimal),
    };
    if tr.has_target() {
        xf.transitions.push(tr);
    }
    Ok(())
}

/// 原 `parseAssDrawingSegments`。
pub fn parse_drawing_segments(drawing: &[u16], divisor: f64, prx: f64, pry: f64) -> Vec<Segment> {
    let mut segments: Vec<Segment> = Vec::new();
    let mut mode: Vec<u16> = Vec::new();
    let mut nums: Vec<f64> = Vec::new();
    fn flush(
        mode: &[u16],
        nums: &mut Vec<f64>,
        segments: &mut Vec<Segment>,
        d: f64,
        rx: f64,
        ry: f64,
    ) {
        if eq_ascii(mode, b"m") || eq_ascii(mode, b"n") {
            let mut k = 0;
            while k + 1 < nums.len() {
                segments.push(Segment::mv(nums[k] / d / rx, nums[k + 1] / d / ry));
                k += 2;
            }
        } else if eq_ascii(mode, b"l") || eq_ascii(mode, b"s") || eq_ascii(mode, b"p") {
            if eq_ascii(mode, b"p") {
                // 原实现在这里 return，**不清空** nums（累积到下一次 flush）。
                return;
            }
            let mut k = 0;
            while k + 1 < nums.len() {
                segments.push(Segment::line(nums[k] / d / rx, nums[k + 1] / d / ry));
                k += 2;
            }
        } else if eq_ascii(mode, b"b") {
            let mut k = 0;
            while k + 5 < nums.len() {
                segments.push(Segment {
                    op: SegOp::Cubic,
                    x1: nums[k] / d / rx,
                    y1: nums[k + 1] / d / ry,
                    x2: nums[k + 2] / d / rx,
                    y2: nums[k + 3] / d / ry,
                    x3: nums[k + 4] / d / rx,
                    y3: nums[k + 5] / d / ry,
                });
                k += 6;
            }
        }
        nums.clear();
    }
    for t in ws_tokens(drawing) {
        match double_try_parse(t) {
            Some(v) => nums.push(v),
            None => {
                flush(&mode, &mut nums, &mut segments, divisor, prx, pry);
                mode = to_lower(t);
            }
        }
    }
    flush(&mode, &mut nums, &mut segments, divisor, prx, pry);
    if segments.is_empty() || segments[0].op != SegOp::Move {
        return Vec::new();
    }
    segments
}

/// 原 `parseAssDrawing`。
pub fn parse_ass_drawing(
    drawing: &[u16],
    scale: i64,
    prx: Option<f64>,
    pry: Option<f64>,
    baseline_offset_px: f64,
) -> Option<Drawing> {
    let (rx, ry) = drawing_play_res(prx, pry)?;
    let shift = if scale >= 1 { scale - 1 } else { 0 };
    let divisor = dart_shl1(shift) as f64;
    let segments = parse_drawing_segments(drawing, divisor, rx, ry);
    if segments.is_empty() {
        return None;
    }
    let (mut min_x, mut min_y) = (f64::INFINITY, f64::INFINITY);
    let (mut max_x, mut max_y) = (f64::NEG_INFINITY, f64::NEG_INFINITY);
    let mut grow = |x: f64, y: f64| {
        if x < min_x {
            min_x = x;
        }
        if x > max_x {
            max_x = x;
        }
        if y < min_y {
            min_y = y;
        }
        if y > max_y {
            max_y = y;
        }
    };
    for s in &segments {
        grow(s.x1, s.y1);
        if s.op == SegOp::Cubic {
            grow(s.x2, s.y2);
            grow(s.x3, s.y3);
        }
    }
    if !min_x.is_finite() || !min_y.is_finite() || !max_x.is_finite() || !max_y.is_finite() {
        return None;
    }
    Some(Drawing {
        segments,
        min_x,
        min_y,
        max_x,
        max_y,
        baseline_offset_fraction: baseline_offset_px / divisor / ry,
    })
}

/// 原 `parseAssClip`。
pub fn parse_ass_clip(
    inverse: bool,
    inner: &[u16],
    prx: Option<f64>,
    pry: Option<f64>,
) -> Option<Clip> {
    let (rx, ry) = drawing_play_res(prx, pry)?;
    let csv: Vec<&[u16]> = split_unit(inner, u(',')).into_iter().map(trim).collect();
    if csv.len() == 4 {
        let vals: Vec<Option<f64>> = csv.iter().map(|p| double_try_parse(p)).collect();
        if vals.iter().all(Option::is_some) {
            let x1 = vals[0].unwrap() / rx;
            let y1 = vals[1].unwrap() / ry;
            let x2 = vals[2].unwrap() / rx;
            let y2 = vals[3].unwrap() / ry;
            return Some(Clip {
                inverse,
                segments: vec![
                    Segment::mv(x1, y1),
                    Segment::line(x2, y1),
                    Segment::line(x2, y2),
                    Segment::line(x1, y2),
                ],
            });
        }
    }
    let mut drawing = inner;
    let mut divisor = 1.0;
    if let Some(comma) = index_of_unit(inner, u(','), 0) {
        if comma > 0 {
            if let Some(scale) = int_try_parse(trim(&inner[..comma])) {
                if scale >= 1 {
                    drawing = &inner[comma + 1..];
                    let sh = dart_shl1(scale - 1);
                    divisor = if sh == 0 { 1.0 } else { sh as f64 };
                }
            }
        }
    }
    let path = parse_drawing_segments(drawing, divisor, rx, ry);
    if path.is_empty() {
        return None;
    }
    Some(Clip {
        inverse,
        segments: path,
    })
}

// ── stripHtmlTags ────────────────────────────────────────────────────────────

/// ASCII 大小写无关地比较 [s] 在 [p] 起是否为小写字面量 [lit]（irregexp 非 unicode 模式
/// ignoreCase：非 ASCII 字符不会规范化成 ASCII 字母）。
fn has_ci_at(s: &[u16], p: usize, lit: &[u8]) -> bool {
    if p + lit.len() > s.len() {
        return false;
    }
    lit.iter().enumerate().all(|(k, &b)| {
        let c = s[p + k];
        c == b as u16 || (b.is_ascii_lowercase() && c == (b - 32) as u16)
    })
}

#[inline]
fn word_boundary_after(s: &[u16], q: usize) -> bool {
    // 前一个字符是字母（单词字符），所以 \b 等价于「后面不是单词字符」。
    q >= s.len() || !is_word(s[q])
}

/// `(?:a|b|...)\b`：按顺序找第一个带 \b 成功的名字，返回结束位置。
fn names_wb(s: &[u16], p: usize, names: &[&[u8]]) -> Option<usize> {
    names
        .iter()
        .find(|n| has_ci_at(s, p, n) && word_boundary_after(s, p + n.len()))
        .map(|n| p + n.len())
}

/// 前瞻 `</?(?:ruby|rt|rp|rtc)\b` 在 [j] 处是否成立。
fn ruby_family_at(s: &[u16], j: usize) -> bool {
    if !at(s, j, '<') {
        return false;
    }
    let p = if at(s, j + 1, '/') { j + 2 } else { j + 1 };
    names_wb(s, p, &[&b"ruby"[..], &b"rt"[..], &b"rp"[..], &b"rtc"[..]]).is_some()
}

/// 从 [i]（`<`）起匹配注音元素，返回匹配结束位置：
/// `<(?:rt|rp|rtc)\b(?:[^<>/]|/(?!>))*>(?:(?!</?(?:ruby|rt|rp|rtc)\b).)*(?:</(?:rt|rp|rtc)\s*>)?`
/// （caseSensitive: false, dotAll: true）。
fn ruby_annotation_at(s: &[u16], i: usize) -> Option<usize> {
    let mut q = names_wb(s, i + 1, &[&b"rt"[..], &b"rp"[..], &b"rtc"[..]])?;
    while q < s.len() {
        let c = s[q];
        if c == u('<') || c == u('>') {
            break;
        }
        if c == u('/') && at(s, q + 1, '>') {
            break;
        }
        q += 1;
    }
    if !at(s, q, '>') {
        return None;
    }
    let mut e = q + 1;
    while e < s.len() && !ruby_family_at(s, e) {
        e += 1;
    }
    if at(s, e, '<') && at(s, e + 1, '/') {
        for name in [&b"rt"[..], &b"rp"[..], &b"rtc"[..]] {
            if has_ci_at(s, e + 2, name) {
                let r = skip_ws(s, e + 2 + name.len());
                if at(s, r, '>') {
                    return Some(r + 1);
                }
            }
        }
    }
    Some(e)
}

/// 原 `stripHtmlTags`：先整段删注音元素，再删 `<[^>]+>`，最后 `trim()`。
pub fn strip_html_tags(text: &[u16]) -> Vec<u16> {
    // 第一遍：注音元素（无 `<` 时整串原样）。
    let mut pass1: Vec<u16> = Vec::with_capacity(text.len());
    let mut i = 0;
    let mut copied = 0;
    while let Some(lt) = index_of_unit(text, u('<'), i) {
        match ruby_annotation_at(text, lt) {
            Some(end) => {
                pass1.extend_from_slice(&text[copied..lt]);
                copied = end;
                i = end;
            }
            None => i = lt + 1,
        }
    }
    pass1.extend_from_slice(&text[copied..]);

    // 第二遍：`<[^>]+>`。
    let s = &pass1;
    let mut out: Vec<u16> = Vec::with_capacity(s.len());
    let mut copied = 0;
    let mut i = 0;
    while let Some(lt) = index_of_unit(s, u('<'), i) {
        match index_of_unit(s, u('>'), lt + 1) {
            None => break, // 之后再无 `>`，不会再有匹配。
            Some(gt) if gt > lt + 1 => {
                out.extend_from_slice(&s[copied..lt]);
                copied = gt + 1;
                i = gt + 1;
            }
            Some(_) => i = lt + 1, // `<>`：内容至少一个字符，此处不匹配。
        }
    }
    out.extend_from_slice(&s[copied..]);
    trim(&out).to_vec()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn w(s: &str) -> Vec<u16> {
        s.encode_utf16().collect()
    }
    fn st(v: &[u16]) -> String {
        String::from_utf16_lossy(v)
    }

    #[test]
    fn strip_ruby_and_tags() {
        for (input, want) in [
            ("<ruby>震<rt>ふる</rt></ruby>", "震"),
            ("<ruby>震<rt>ふる</ruby>え", "震え"),
            ("<i>こんにちは</i>", "こんにちは"),
            ("<ruby>漢<rt かん</ruby>の話", "漢の話"),
            ("a<rt/>b", "ab"),
            ("<RT>x</Rt>y", "y"),
            ("<rtc><rt>a</rt></rtc>b", "b"),
            ("a <> b", "a <> b"),
            ("  <b>x</b>  ", "x"),
        ] {
            assert_eq!(st(&strip_html_tags(&w(input))), want, "{input:?}");
        }
    }

    #[test]
    fn markup_basics() {
        let m = parse_markup(&w(r"{\an8\i1}上{\i0}下\N行"), Some(384.0), Some(288.0), 0).unwrap();
        assert_eq!(st(&m.plain_text), "上下 行");
        assert_eq!(m.anchor, 8);
        assert_eq!(m.spans.len(), 1);
        assert_eq!((m.spans[0].start, m.spans[0].end), (0, 1));
        assert_eq!(m.line_breaks, Some(vec![2]));
    }

    #[test]
    fn int_overflow_in_tag_is_format_error() {
        let r = parse_markup(&w(r"{\b99999999999999999999}x"), None, None, 0);
        assert!(matches!(r, Err(DartError::Format { .. })));
    }

    #[test]
    fn karaoke_huge_duration_is_unsupported() {
        let raw = format!(r"{{\k{}}}x", "9".repeat(400));
        let r = parse_markup(&w(&raw), None, None, 0);
        assert!(matches!(r, Err(DartError::Unsupported(_))));
    }
}
