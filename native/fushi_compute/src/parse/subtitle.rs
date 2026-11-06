//! `ffc_parse_subtitle_*`：字幕（SRT / WebVTT / ASS）与行内 markup 解析。
//!
//! 原实现是 packages/fushi_audio 的 Dart 解析器（正则 + `package:characters`）；搬到这里后
//! **运行时只有这一份实现**，结果与旧 Dart 实现逐条、逐字段、逐位一致（回归向量见
//! packages/fushi_audio/test/parsers/subtitle_native_parity_test.dart）。一致性依赖：
//! - [dart]：Dart 核心库语义（trim 空白集合、`int.tryParse` / `double.tryParse` / `round()`、
//!   `split` 对空串返回空列表、`toLowerCase` 映射表）；
//! - [grapheme]：package:characters 的字素自动机（表由 `tool/gen_subtitle_tables.dart` 生成）；
//! - 旧实现会抛出的异常（`int.parse` 越界、`round()` 遇 Inf、`List[]` 越界）
//!   以 [dart::DartError] 返回，Dart 侧按原类型重新抛出。
//!
//! 输入：Dart String 的 UTF-16 码元（编码探测 / 读盘留在 Dart）。
//! 输出：一次性交出的字节块（`ffc_free_bytes` 释放），布局：
//! ```text
//! [0..4)   u32 结果：0 = 成功，1 = FormatException，2 = UnsupportedError，
//!          3 = RangeError
//! [4..8)   u32 数据区字节数 D
//! [8..12)  u32 字符串池码元数 P
//! [12..16) 保留
//! [16..16+D)                数据区（小端；字符串写成池内 u32 偏移 + u32 长度）
//! [16+align8(D)..+2P)       UTF-16 字符串池
//! ```
//! 数据区各记录的字段顺序见 [Out] 的各 `write_*` 与 Dart 侧 `subtitle_native_decode.dart`。

use crate::{guard, hand_over_bytes, status};

mod dart;
mod formats;
mod grapheme;
mod markup;
// 生成文件按生成器原样入库（`--check` 逐字比对），不让 rustfmt 重排。
#[rustfmt::skip]
mod tables;

use dart::DartError;
use formats::{AssResult, Cue, CueStyle};
use markup::{Clip, Drawing, Fade, Markup, Segment, Style};

/// 结果字节块的构造器。
struct Out {
    data: Vec<u8>,
    pool: Vec<u16>,
}

impl Out {
    fn new() -> Self {
        Out {
            data: Vec::with_capacity(4096),
            pool: Vec::with_capacity(4096),
        }
    }
    fn u8(&mut self, v: u8) {
        self.data.push(v);
    }
    fn u32(&mut self, v: u32) {
        self.data.extend_from_slice(&v.to_le_bytes());
    }
    fn i32(&mut self, v: i32) {
        self.data.extend_from_slice(&v.to_le_bytes());
    }
    fn i64(&mut self, v: i64) {
        self.data.extend_from_slice(&v.to_le_bytes());
    }
    fn f64(&mut self, v: f64) {
        self.data.extend_from_slice(&v.to_bits().to_le_bytes());
    }
    fn str(&mut self, s: &[u16]) {
        self.u32(self.pool.len() as u32);
        self.u32(s.len() as u32);
        self.pool.extend_from_slice(s);
    }

    fn finish(self, result: u32) -> Vec<u8> {
        let data_len = self.data.len();
        let pool_offset = 16 + data_len.div_ceil(8) * 8;
        let mut out = Vec::with_capacity(pool_offset + self.pool.len() * 2);
        out.extend_from_slice(&result.to_le_bytes());
        out.extend_from_slice(&(data_len as u32).to_le_bytes());
        out.extend_from_slice(&(self.pool.len() as u32).to_le_bytes());
        out.extend_from_slice(&0u32.to_le_bytes());
        out.extend_from_slice(&self.data);
        out.resize(pool_offset, 0);
        for &c in &self.pool {
            out.extend_from_slice(&c.to_le_bytes());
        }
        out
    }

    /// 行内样式：u32 掩码（bit0..3 = italic/bold/underline/strike 取值；bit4.. = 各可空字段
    /// 是否存在）后按序写存在的值。`with_k = false` 时不写卡拉 OK 三字段（绘图样式快照）。
    fn write_style(&mut self, s: &Style, with_k: bool) {
        let mut mask = 0u32;
        let bits: [bool; 19] = [
            s.italic,
            s.bold,
            s.underline,
            s.strike,
            s.color_argb.is_some(),
            s.font_size_px.is_some(),
            s.font_name.is_some(),
            s.outline_color_argb.is_some(),
            s.shadow_color_argb.is_some(),
            s.outline_width_px.is_some(),
            s.shadow_depth_px.is_some(),
            s.blur.is_some(),
            s.fill_opacity.is_some(),
            s.letter_spacing_px.is_some(),
            s.scale_x.is_some(),
            s.scale_y.is_some(),
            with_k && s.k_mode.is_some(),
            with_k && s.k_start_cs.is_some(),
            with_k && s.k_dur_cs.is_some(),
        ];
        for (k, &b) in bits.iter().enumerate() {
            if b {
                mask |= 1 << k;
            }
        }
        self.u32(mask);
        if let Some(v) = s.color_argb {
            self.i64(v);
        }
        if let Some(v) = s.font_size_px {
            self.f64(v);
        }
        if let Some(v) = &s.font_name {
            self.str(v);
        }
        if let Some(v) = s.outline_color_argb {
            self.i64(v);
        }
        if let Some(v) = s.shadow_color_argb {
            self.i64(v);
        }
        for v in [
            s.outline_width_px,
            s.shadow_depth_px,
            s.blur,
            s.fill_opacity,
            s.letter_spacing_px,
            s.scale_x,
            s.scale_y,
        ]
        .into_iter()
        .flatten()
        {
            self.f64(v);
        }
        if with_k {
            if let Some(v) = s.k_mode {
                self.u8(v);
            }
            if let Some(v) = s.k_start_cs {
                self.i64(v);
            }
            if let Some(v) = s.k_dur_cs {
                self.i64(v);
            }
        }
    }

    /// 路径段：u32 段数；每段 u8 op（0 move / 1 line / 2 cubic）+ x1,y1（cubic 再加 x2..y3）。
    fn write_segments(&mut self, segs: &[Segment]) {
        self.u32(segs.len() as u32);
        for s in segs {
            self.u8(s.op as u8);
            self.f64(s.x1);
            self.f64(s.y1);
            if s.op == markup::SegOp::Cubic {
                self.f64(s.x2);
                self.f64(s.y2);
                self.f64(s.x3);
                self.f64(s.y3);
            }
        }
    }

    fn opt_i64_pair(&mut self, a: Option<i64>, b: Option<i64>) {
        self.u8(u8::from(a.is_some()) | (u8::from(b.is_some()) << 1));
        if let Some(v) = a {
            self.i64(v);
        }
        if let Some(v) = b {
            self.i64(v);
        }
    }

    fn write_clip(&mut self, c: &Clip) {
        self.u8(u8::from(c.inverse));
        self.write_segments(&c.segments);
    }

    fn write_drawing(&mut self, d: &Drawing) {
        self.write_segments(&d.segments);
        self.f64(d.min_x);
        self.f64(d.min_y);
        self.f64(d.max_x);
        self.f64(d.max_y);
        self.f64(d.baseline_offset_fraction);
    }

    /// markup：u32 存在掩码、plainText、layer，再按掩码位序写各可选部分。
    fn write_markup(&mut self, m: &Markup) {
        let present: [bool; 16] = [
            !m.spans.is_empty(),
            m.anchor != 0,
            m.pos.is_some(),
            m.line_breaks.is_some(),
            m.fade.is_some(),
            m.rotation_deg.is_some(),
            m.scale.is_some(),
            m.mv.is_some(),
            m.clip.is_some(),
            !m.transitions.is_empty(),
            m.rotation_x_deg.is_some(),
            m.rotation_y_deg.is_some(),
            m.shear_x.is_some(),
            m.shear_y.is_some(),
            m.drawing.is_some(),
            m.drawing_style.is_some(),
        ];
        let mut mask = 0u32;
        for (k, &b) in present.iter().enumerate() {
            if b {
                mask |= 1 << k;
            }
        }
        self.u32(mask);
        self.str(&m.plain_text);
        self.i64(m.layer);
        if !m.spans.is_empty() {
            self.u32(m.spans.len() as u32);
            for s in &m.spans {
                self.i64(s.start);
                self.i64(s.end);
                self.write_style(&s.style, true);
            }
        }
        if m.anchor != 0 {
            self.u8(m.anchor);
        }
        if let Some((x, y)) = m.pos {
            self.f64(x);
            self.f64(y);
        }
        if let Some(b) = &m.line_breaks {
            self.u32(b.len() as u32);
            for &v in b {
                self.i64(v);
            }
        }
        match m.fade {
            Some(Fade::Simple {
                fade_in_ms,
                fade_out_ms,
            }) => {
                self.u8(0);
                self.i64(fade_in_ms);
                self.i64(fade_out_ms);
            }
            Some(Fade::Full {
                op1,
                op2,
                op3,
                t1,
                t2,
                t3,
                t4,
            }) => {
                self.u8(1);
                self.f64(op1);
                self.f64(op2);
                self.f64(op3);
                self.i64(t1);
                self.i64(t2);
                self.i64(t3);
                self.i64(t4);
            }
            None => {}
        }
        if let Some(v) = m.rotation_deg {
            self.f64(v);
        }
        if let Some(s) = m.scale {
            self.f64(s.from_x);
            self.f64(s.from_y);
            self.f64(s.to_x);
            self.f64(s.to_y);
            self.opt_i64_pair(s.t1, s.t2);
        }
        if let Some(v) = m.mv {
            self.f64(v.x1);
            self.f64(v.y1);
            self.f64(v.x2);
            self.f64(v.y2);
            self.opt_i64_pair(v.t1, v.t2);
        }
        if let Some(c) = &m.clip {
            self.write_clip(c);
        }
        if !m.transitions.is_empty() {
            self.u32(m.transitions.len() as u32);
            for t in &m.transitions {
                let bits = [
                    t.t1.is_some(),
                    t.t2.is_some(),
                    t.alpha_to.is_some(),
                    t.color_to_argb.is_some(),
                    t.blur_to.is_some(),
                    t.bord_to.is_some(),
                    t.frz_to_deg.is_some(),
                ];
                let mut tm = 0u8;
                for (k, &b) in bits.iter().enumerate() {
                    if b {
                        tm |= 1 << k;
                    }
                }
                self.u8(tm);
                if let Some(v) = t.t1 {
                    self.i64(v);
                }
                if let Some(v) = t.t2 {
                    self.i64(v);
                }
                self.f64(t.accel);
                if let Some(v) = t.alpha_to {
                    self.f64(v);
                }
                if let Some(v) = t.color_to_argb {
                    self.i64(v);
                }
                for v in [t.blur_to, t.bord_to, t.frz_to_deg].into_iter().flatten() {
                    self.f64(v);
                }
            }
        }
        for v in [m.rotation_x_deg, m.rotation_y_deg, m.shear_x, m.shear_y]
            .into_iter()
            .flatten()
        {
            self.f64(v);
        }
        if let Some(d) = &m.drawing {
            self.write_drawing(d);
        }
        if let Some(s) = &m.drawing_style {
            self.write_style(s, false);
        }
    }

    /// `[V4+ Styles]` 样式：u32 掩码（20 个可空字段的存在位，顺序同 [CueStyle]）后按序写值；
    /// bool 字段写 u8。
    fn write_cue_style(&mut self, s: &CueStyle) {
        let present = [
            s.font_name.is_some(),
            s.primary_color_argb.is_some(),
            s.outline_color_argb.is_some(),
            s.shadow_color_argb.is_some(),
            s.font_size_px.is_some(),
            s.outline_width_px.is_some(),
            s.shadow_depth_px.is_some(),
            s.bold.is_some(),
            s.italic.is_some(),
            s.underline.is_some(),
            s.strike_out.is_some(),
            s.anchor.is_some(),
            s.margin_v.is_some(),
            s.margin_l.is_some(),
            s.margin_r.is_some(),
            s.secondary_color_argb.is_some(),
            s.spacing_px.is_some(),
            s.angle_deg.is_some(),
            s.scale_x_pct.is_some(),
            s.scale_y_pct.is_some(),
        ];
        let mut mask = 0u32;
        for (k, &b) in present.iter().enumerate() {
            if b {
                mask |= 1 << k;
            }
        }
        self.u32(mask);
        if let Some(v) = &s.font_name {
            self.str(v);
        }
        for v in [
            s.primary_color_argb,
            s.outline_color_argb,
            s.shadow_color_argb,
        ]
        .into_iter()
        .flatten()
        {
            self.i64(v);
        }
        for v in [s.font_size_px, s.outline_width_px, s.shadow_depth_px]
            .into_iter()
            .flatten()
        {
            self.f64(v);
        }
        for v in [s.bold, s.italic, s.underline, s.strike_out]
            .into_iter()
            .flatten()
        {
            self.u8(u8::from(v));
        }
        if let Some(v) = s.anchor {
            self.u8(v);
        }
        for v in [s.margin_v, s.margin_l, s.margin_r].into_iter().flatten() {
            self.f64(v);
        }
        if let Some(v) = s.secondary_color_argb {
            self.i64(v);
        }
        for v in [s.spacing_px, s.angle_deg, s.scale_x_pct, s.scale_y_pct]
            .into_iter()
            .flatten()
        {
            self.f64(v);
        }
    }

    /// cue 列表：u32 条数；每条 i64 start、i64 end、（`with_ass` 时）i32 样式下标 + u8 行级
    /// Margin 存在掩码 + 各 f64 + f64 PlayResX + f64 PlayResY，最后 markup。
    fn write_cues(&mut self, cues: &[Cue], with_ass: bool) {
        self.u32(cues.len() as u32);
        for c in cues {
            self.i64(c.start_ms);
            self.i64(c.end_ms);
            if with_ass {
                self.i32(c.style_id);
                let mut mm = 0u8;
                for (k, m) in c.event_margins.iter().enumerate() {
                    if m.is_some() {
                        mm |= 1 << k;
                    }
                }
                self.u8(mm);
                for v in c.event_margins.iter().flatten() {
                    self.f64(*v);
                }
                let (x, y) = c.play_res.unwrap_or((384.0, 288.0));
                self.f64(x);
                self.f64(y);
            }
            self.write_markup(&c.markup);
        }
    }

    fn write_error(mut self, e: &DartError) -> Vec<u8> {
        match e {
            DartError::Format { message, source } => {
                self.str(&dart::ascii16(message));
                self.str(source);
                self.finish(1)
            }
            DartError::Unsupported(message) => {
                self.str(&dart::ascii16(message));
                self.finish(2)
            }
            DartError::Range {
                value,
                start,
                end,
                name,
            } => {
                self.i64(*value);
                self.i64(*start);
                self.i64(*end);
                self.str(&dart::ascii16(name));
                self.finish(3)
            }
        }
    }
}

fn encode_cues(result: Result<Vec<Cue>, DartError>) -> Vec<u8> {
    let mut out = Out::new();
    match result {
        Ok(cues) => {
            out.write_cues(&cues, false);
            out.finish(0)
        }
        Err(e) => out.write_error(&e),
    }
}

fn encode_ass(result: Result<AssResult, DartError>) -> Vec<u8> {
    let mut out = Out::new();
    match result {
        Ok(r) => {
            out.u32(r.skipped);
            out.u32(r.styles.len() as u32);
            for s in &r.styles {
                out.write_cue_style(s);
            }
            out.write_cues(&r.cues, true);
            out.finish(0)
        }
        Err(e) => out.write_error(&e),
    }
}

/// 公共入口骨架：校验指针、借出输入切片、在 [guard] 里跑 [body] 并交出结果。
unsafe fn run(
    units: *const u16,
    len: usize,
    out_ptr: *mut *mut u8,
    out_len: *mut usize,
    body: impl FnOnce(&[u16]) -> Vec<u8>,
) -> i32 {
    if out_ptr.is_null() || out_len.is_null() || (len > 0 && units.is_null()) {
        return status::NULL_ARGUMENT;
    }
    guard(|| {
        let input: &[u16] = if len == 0 {
            &[]
        } else {
            std::slice::from_raw_parts(units, len)
        };
        let bytes = body(input);
        hand_over_bytes(bytes, out_ptr, out_len);
        status::OK
    })
}

/// SRT 全文 → cue 列表。
///
/// # Safety
/// `len > 0` 时 `units` 指向 `len` 个可读 `u16`；`out_ptr` / `out_len` 非空可写。
#[no_mangle]
pub unsafe extern "C" fn ffc_parse_subtitle_srt(
    units: *const u16,
    len: usize,
    out_ptr: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    run(units, len, out_ptr, out_len, |s| {
        encode_cues(formats::parse_srt(s))
    })
}

/// WebVTT 全文 → cue 列表。
///
/// # Safety
/// 同 [ffc_parse_subtitle_srt]。
#[no_mangle]
pub unsafe extern "C" fn ffc_parse_subtitle_vtt(
    units: *const u16,
    len: usize,
    out_ptr: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    run(units, len, out_ptr, out_len, |s| {
        encode_cues(formats::parse_vtt(s))
    })
}

/// ASS / SSA 全文 → 样式表 + cue 列表。`include_drawings != 0` 时保留无正文的 `\p` 绘图事件。
///
/// # Safety
/// 同 [ffc_parse_subtitle_srt]。
#[no_mangle]
pub unsafe extern "C" fn ffc_parse_subtitle_ass(
    units: *const u16,
    len: usize,
    include_drawings: u8,
    out_ptr: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    run(units, len, out_ptr, out_len, |s| {
        encode_ass(formats::parse_ass(s, include_drawings != 0))
    })
}

/// 单条 cue 原文 → markup（原 `parseSubtitleMarkup`）。`flags` bit0 = 有 PlayResX，
/// bit1 = 有 PlayResY（否则对应参数视为 null）。数据区是一条 markup 记录。
///
/// # Safety
/// 同 [ffc_parse_subtitle_srt]。
#[no_mangle]
pub unsafe extern "C" fn ffc_parse_subtitle_markup(
    units: *const u16,
    len: usize,
    flags: u32,
    play_res_x: f64,
    play_res_y: f64,
    layer: i64,
    out_ptr: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    run(units, len, out_ptr, out_len, |s| {
        let prx = (flags & 1 != 0).then_some(play_res_x);
        let pry = (flags & 2 != 0).then_some(play_res_y);
        let mut out = Out::new();
        match markup::parse_markup(s, prx, pry, layer) {
            Ok(m) => {
                out.write_markup(&m);
                out.finish(0)
            }
            Err(e) => out.write_error(&e),
        }
    })
}

/// 行内 HTML / VTT 标签剥离（原 `stripHtmlTags`）。数据区是一个字符串引用。
///
/// # Safety
/// 同 [ffc_parse_subtitle_srt]。
#[no_mangle]
pub unsafe extern "C" fn ffc_parse_subtitle_strip_html_tags(
    units: *const u16,
    len: usize,
    out_ptr: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    run(units, len, out_ptr, out_len, |s| {
        let mut out = Out::new();
        out.str(&markup::strip_html_tags(s));
        out.finish(0)
    })
}

/// 一批行内标签剥离（[ffc_parse_subtitle_strip_html_tags] 的批量版：增强 LRC 每行都带
/// `<MM:SS.xx>`，整份一次调用，循环在这里）。`units[0..len]` 是各条首尾相接的 UTF-16，
/// `ends[i]` 是第 `i` 条的结束下标（第 `i` 条 = `units[ends[i-1]..ends[i]]`，`ends[-1]` 记 0），
/// 必须单调不减且 `ends[count-1] == len`，否则返回 `INVALID_ARGUMENT`。数据区是 `count` 个
/// 字符串引用，第 `i` 个与对第 `i` 条单独调用单条入口的结果逐码元相同（各条互不影响：标签
/// 不会跨条匹配）。
///
/// # Safety
/// `len > 0` 时 `units` 指向 `len` 个可读 `u16`；`count > 0` 时 `ends` 指向 `count` 个可读
/// `u32`；`out_ptr` / `out_len` 非空可写。
#[no_mangle]
pub unsafe extern "C" fn ffc_parse_subtitle_strip_html_tags_batch(
    units: *const u16,
    len: usize,
    ends: *const u32,
    count: usize,
    out_ptr: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    if count > 0 && ends.is_null() {
        return status::NULL_ARGUMENT;
    }
    let ends: &[u32] = if count == 0 {
        &[]
    } else {
        std::slice::from_raw_parts(ends, count)
    };
    let mut prev = 0usize;
    for &end in ends {
        let end = end as usize;
        if end < prev || end > len {
            return status::INVALID_ARGUMENT;
        }
        prev = end;
    }
    if prev != len {
        return status::INVALID_ARGUMENT;
    }
    run(units, len, out_ptr, out_len, |s| {
        let mut out = Out::new();
        let mut start = 0usize;
        for &end in ends {
            let end = end as usize;
            out.str(&markup::strip_html_tags(&s[start..end]));
            start = end;
        }
        out.finish(0)
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ffc_free_bytes;

    #[test]
    fn ffi_roundtrip_and_null_checks() {
        let text: Vec<u16> = "1\n00:00:01,000 --> 00:00:02,000\nhi\n"
            .encode_utf16()
            .collect();
        let mut ptr = std::ptr::null_mut();
        let mut len = 0usize;
        let rc = unsafe { ffc_parse_subtitle_srt(text.as_ptr(), text.len(), &mut ptr, &mut len) };
        assert_eq!(rc, status::OK);
        let bytes = unsafe { std::slice::from_raw_parts(ptr, len) };
        assert_eq!(u32::from_le_bytes(bytes[0..4].try_into().unwrap()), 0);
        let data_len = u32::from_le_bytes(bytes[4..8].try_into().unwrap()) as usize;
        let pool_units = u32::from_le_bytes(bytes[8..12].try_into().unwrap()) as usize;
        assert_eq!(16 + data_len.div_ceil(8) * 8 + pool_units * 2, len);
        assert_eq!(u32::from_le_bytes(bytes[16..20].try_into().unwrap()), 1);
        ffc_free_bytes(ptr, len);
        let rc = unsafe { ffc_parse_subtitle_srt(std::ptr::null(), 3, &mut ptr, &mut len) };
        assert_eq!(rc, status::NULL_ARGUMENT);
        let rc = unsafe { ffc_parse_subtitle_vtt(std::ptr::null(), 0, &mut ptr, &mut len) };
        assert_eq!(rc, status::OK);
        ffc_free_bytes(ptr, len);
    }

    /// 结果字节块数据区里的第 `k` 个字符串引用（池偏移 + 长度）。
    fn nth_string(bytes: &[u8], k: usize) -> Vec<u16> {
        let data_len = u32::from_le_bytes(bytes[4..8].try_into().unwrap()) as usize;
        let pool_offset = 16 + data_len.div_ceil(8) * 8;
        let at = 16 + 8 * k;
        let start = u32::from_le_bytes(bytes[at..at + 4].try_into().unwrap()) as usize;
        let n = u32::from_le_bytes(bytes[at + 4..at + 8].try_into().unwrap()) as usize;
        (0..n)
            .map(|i| {
                let p = pool_offset + 2 * (start + i);
                u16::from_le_bytes([bytes[p], bytes[p + 1]])
            })
            .collect()
    }

    #[test]
    fn strip_batch_matches_single_entry_per_item() {
        let items: Vec<Vec<u16>> = [
            "<00:12.34>こん<00:12.99>にちは",
            "",
            "  吾輩は猫である。  ",
            "<ruby>震<rt>ふる</rt></ruby>",
            // 未闭合的 `<` 在条尾：不能借下一条的 `>` 吃掉下一条的正文。
            "a<b",
            "c>d",
            "<ruby>漢<rt かん</ruby>の話",
            "震<rt>ふる",
            "<i>x</i>",
        ]
        .iter()
        .map(|s| s.encode_utf16().collect())
        .collect();
        let mut units: Vec<u16> = Vec::new();
        let mut ends: Vec<u32> = Vec::new();
        for item in &items {
            units.extend_from_slice(item);
            ends.push(units.len() as u32);
        }
        let mut ptr = std::ptr::null_mut();
        let mut len = 0usize;
        let rc = unsafe {
            ffc_parse_subtitle_strip_html_tags_batch(
                units.as_ptr(),
                units.len(),
                ends.as_ptr(),
                ends.len(),
                &mut ptr,
                &mut len,
            )
        };
        assert_eq!(rc, status::OK);
        let bytes = unsafe { std::slice::from_raw_parts(ptr, len) }.to_vec();
        ffc_free_bytes(ptr, len);
        assert_eq!(u32::from_le_bytes(bytes[0..4].try_into().unwrap()), 0);
        for (k, item) in items.iter().enumerate() {
            assert_eq!(
                nth_string(&bytes, k),
                markup::strip_html_tags(item),
                "item {k}"
            );
        }
        assert_eq!(
            String::from_utf16(&nth_string(&bytes, 4)).unwrap(),
            "a<b",
            "标签不能跨条匹配"
        );
    }

    #[test]
    fn strip_batch_rejects_bad_ends() {
        let units: Vec<u16> = "abcd".encode_utf16().collect();
        let mut ptr = std::ptr::null_mut();
        let mut len = 0usize;
        for bad in [&[3u32, 2, 4][..], &[2, 5][..], &[1, 3][..]] {
            let rc = unsafe {
                ffc_parse_subtitle_strip_html_tags_batch(
                    units.as_ptr(),
                    units.len(),
                    bad.as_ptr(),
                    bad.len(),
                    &mut ptr,
                    &mut len,
                )
            };
            assert_eq!(rc, status::INVALID_ARGUMENT, "{bad:?}");
        }
        let rc = unsafe {
            ffc_parse_subtitle_strip_html_tags_batch(
                units.as_ptr(),
                units.len(),
                std::ptr::null(),
                2,
                &mut ptr,
                &mut len,
            )
        };
        assert_eq!(rc, status::NULL_ARGUMENT);
        // 空批：零条、零长度。
        let rc = unsafe {
            ffc_parse_subtitle_strip_html_tags_batch(
                std::ptr::null(),
                0,
                std::ptr::null(),
                0,
                &mut ptr,
                &mut len,
            )
        };
        assert_eq!(rc, status::OK);
        ffc_free_bytes(ptr, len);
    }
}
