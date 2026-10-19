//! `ffc_gal_*`：galgame 查词校准的像素扫描（Windows 消费端 `fushi/lib/src/lookup/
//! gal_lookup_calibration_image_fit.dart` 的截图拟合网格、`fushi/lib/src/ocr/
//! gal_lookup_ocr_ink_geometry.dart` 的墨迹几何搜索）。
//!
//! 只是对一张已冻结截图做几何测量，不碰任何 Hook / 引擎。逐位复刻旧 Dart 实现：浮点求值顺序
//! 相同，`List.sort` 用 [crate::dart::sort]（并列去向与 Dart 相同），`luminance` 平面按
//! `Float32List` 存成 f32。回归向量见 `fushi/test/lookup/gal_calibration_pixel_kernels_regression_test.dart`。

// 下标循环照抄旧 Dart 循环的形状（逐位一致比惯用写法要紧）。
#![allow(clippy::needless_range_loop)]

use crate::dart::{compare_f64, compare_i64, max_f64, median, round, sort};
use crate::image::{resize_into, View, INTERP_NEAREST};
use crate::{guard, status};

unsafe fn slice<'a, T>(ptr: *const T, len: usize) -> &'a [T] {
    if len == 0 {
        &[]
    } else {
        std::slice::from_raw_parts(ptr, len)
    }
}

unsafe fn slice_mut<'a, T>(ptr: *mut T, len: usize) -> &'a mut [T] {
    if len == 0 {
        &mut []
    } else {
        std::slice::from_raw_parts_mut(ptr, len)
    }
}

/// `_InkMode` 的顺序（`light, dark, brightColor, darkColor, localContrast, edge`）。
const MODES: usize = 6;
const MODE_LIGHT: usize = 0;
const MODE_DARK: usize = 1;
const MODE_BRIGHT_COLOR: usize = 2;
const MODE_DARK_COLOR: usize = 3;
const MODE_LOCAL_CONTRAST: usize = 4;
const MODE_EDGE: usize = 5;

struct InkRow {
    top: i64,
    bottom: i64,
    left: i64,
    right: i64,
    columns: Vec<i32>,
}

impl InkRow {
    fn height(&self) -> i64 {
        self.bottom - self.top
    }
}

/// `_removeIsolatedSpecks`。
fn remove_isolated_specks(columns: &mut [i32], row_height: i64) {
    let mut groups: Vec<(usize, usize)> = Vec::new();
    let mut start: i64 = -1;
    let mut previous: i64 = -1;
    let rh = row_height as f64;
    for x in 0..columns.len() {
        if columns[x] < 2 {
            continue;
        }
        if start < 0 {
            start = x as i64;
        } else if (x as i64 - previous) as f64 > rh * 1.5 {
            groups.push((start as usize, (previous + 1) as usize));
            start = x as i64;
        }
        previous = x as i64;
    }
    if start >= 0 {
        groups.push((start as usize, (previous + 1) as usize));
    }
    if groups.len() < 2 {
        return;
    }
    let total: i64 = columns.iter().map(|&v| v as i64).sum();
    for (left, right) in groups {
        if (right - left) as f64 > rh * 0.5 {
            continue;
        }
        let ink: i64 = columns[left..right].iter().map(|&v| v as i64).sum();
        if (ink as f64) <= max_f64(4.0, rh * 0.5) && (ink as f64) <= total as f64 * 0.01 {
            for v in &mut columns[left..right] {
                *v = 0;
            }
        }
    }
}

#[inline]
fn brightness(p: &[i64; 4]) -> f64 {
    p[0] as f64 * 0.299 + p[1] as f64 * 0.587 + p[2] as f64 * 0.114
}

/// `_measure` 的像素部分（解码之后）：在（必要时缩到宽 1600 的）图上按 [mode] 取墨迹掩码、
/// 找文字行。返回 `(image_w, image_h, rows)`；找不到行 / 区域太小返回 `None`。
fn measure(
    img: &View,
    rect: [f64; 4],
    mode: usize,
) -> Result<Option<(usize, usize, Vec<InkRow>)>, i32> {
    let iw = img.w as i64;
    let ih = img.h as i64;
    let left = (rect[0] * img.w as f64).floor() as i64;
    let right = ((rect[2] * img.w as f64).ceil() as i64).clamp(0, iw);
    let top = (rect[1] * img.h as f64).floor() as i64;
    let bottom = ((rect[3] * img.h as f64).ceil() as i64).clamp(0, ih);
    let width = right - left;
    let height = bottom - top;
    if width < 16 || height < 8 {
        return Ok(None);
    }
    if left < 0 || top < 0 {
        // 旧实现在越界 getPixel 上抛 RangeError。
        return Err(status::INVALID_ARGUMENT);
    }
    let (w, h) = (width as usize, height as usize);
    let (l0, t0) = (left as usize, top as usize);
    let mut mask = vec![0u8; w * h];
    let mut totals = vec![0i64; h];
    let mut integral: Vec<f64> = Vec::new();
    let istride = w + 1;
    let mut luminance: Vec<f32> = Vec::new();
    if mode == MODE_LOCAL_CONTRAST {
        integral = vec![0f64; (h + 1) * istride];
        for y in 0..h {
            let mut row_sum = 0.0f64;
            for x in 0..w {
                let value = brightness(&img.rgba(l0 + x, t0 + y));
                row_sum += value;
                integral[(y + 1) * istride + x + 1] = integral[y * istride + x + 1] + row_sum;
            }
        }
    } else if mode == MODE_EDGE {
        luminance = vec![0f32; w * h];
        for y in 0..h {
            for x in 0..w {
                luminance[y * w + x] = brightness(&img.rgba(l0 + x, t0 + y)) as f32;
            }
        }
    }
    for y in 0..h {
        for x in 0..w {
            let p = img.rgba(l0 + x, t0 + y);
            let low = p[0].min(p[1].min(p[2]));
            let high = p[0].max(p[1].max(p[2]));
            let b = brightness(&p);
            let ink = match mode {
                MODE_LIGHT => high - low < 65 && low >= 195,
                MODE_DARK => high - low < 65 && high <= 60,
                MODE_BRIGHT_COLOR => b >= 175.0,
                MODE_DARK_COLOR => b <= 100.0,
                MODE_LOCAL_CONTRAST => {
                    const RADIUS: i64 = 4;
                    let (lx, ly) = (x as i64, y as i64);
                    let x0 = 0i64.max(lx - RADIUS) as usize;
                    let y0 = 0i64.max(ly - RADIUS) as usize;
                    let x1 = (width - 1).min(lx + RADIUS) as usize;
                    let y1 = (height - 1).min(ly + RADIUS) as usize;
                    let area = (x1 - x0 + 1) as f64 * ((y1 - y0 + 1) as f64);
                    let sum = integral[(y1 + 1) * istride + x1 + 1]
                        - integral[y0 * istride + x1 + 1]
                        - integral[(y1 + 1) * istride + x0]
                        + integral[y0 * istride + x0];
                    (b - sum / area).abs() >= 12.0
                }
                _ => {
                    let offset = y * w + x;
                    let center = luminance[offset] as f64;
                    let mut edge = 0.0f64;
                    if x > 0 {
                        edge = max_f64(edge, (center - luminance[offset - 1] as f64).abs());
                    }
                    if x + 1 < w {
                        edge = max_f64(edge, (center - luminance[offset + 1] as f64).abs());
                    }
                    if y > 0 {
                        edge = max_f64(edge, (center - luminance[offset - w] as f64).abs());
                    }
                    if y + 1 < h {
                        edge = max_f64(edge, (center - luminance[offset + w] as f64).abs());
                    }
                    edge >= 10.0
                }
            };
            if ink {
                mask[y * w + x] = 1;
                totals[y] += 1;
            }
        }
    }
    let peak = totals.iter().copied().fold(0i64, i64::max) as f64;
    let threshold = if mode == MODE_EDGE {
        max_f64(4.0, peak * 0.07)
    } else {
        max_f64(3.0, peak * 0.04)
    };
    let min_band = max_f64(6.0, ih as f64 * 0.012);
    let mut bands: Vec<(usize, usize)> = Vec::new();
    let mut start: i64 = -1;
    let mut end: i64 = -1;
    for y in 0..=h {
        if y < h && totals[y] as f64 >= threshold {
            if start < 0 {
                start = y as i64;
            }
            end = y as i64 + 1;
        } else if start >= 0 && (y == h || y as i64 - end >= 2) {
            if (end - start) as f64 >= min_band {
                bands.push((start as usize, end as usize));
            }
            start = -1;
        }
    }
    let mut rows: Vec<InkRow> = Vec::new();
    for (a, b) in bands {
        if (b - a) as f64 > ih as f64 * 0.12 {
            continue;
        }
        let mut columns = vec![0i32; img.w];
        for y in a..b {
            for x in 0..w {
                columns[l0 + x] += mask[y * w + x] as i32;
            }
        }
        remove_isolated_specks(&mut columns, (b - a) as i64);
        let first = columns.iter().position(|&v| v >= 2);
        let last = columns.iter().rposition(|&v| v >= 2);
        let (Some(first), Some(last)) = (first, last) else {
            continue;
        };
        if ((last - first) as f64) < (b - a) as f64 * 1.2 {
            continue;
        }
        rows.push(InkRow {
            top: top + a as i64,
            bottom: top + b as i64,
            left: first as i64,
            right: last as i64 + 1,
            columns,
        });
    }
    if rows.is_empty() {
        return Ok(None);
    }
    let tallest = rows.iter().map(|r| r.height()).max().unwrap() as f64;
    let text_rows: Vec<InkRow> = rows
        .into_iter()
        .filter(|r| r.height() as f64 >= tallest * 0.7)
        .collect();
    if text_rows.is_empty() || text_rows.len() > 6 {
        return Ok(None);
    }
    Ok(Some((img.w, img.h, text_rows)))
}

/// 解码后的截图（`decodePng` 布局，1～4 通道）先按 `_measure` 的规则缩到宽 ≤ 1600（最近邻
/// `copyResize`），再对 6 种墨迹模式各测一次（`rect` = 搜索框归一化 ltrb）。结果按模式顺序
/// 序列化：`[i32 found]`，found 时接 `[u32 imageW][u32 imageH][u32 rowCount]`，每行
/// `[i32 top][i32 bottom][i32 left][i32 right][i32 columns × imageW]`（本机字节序），经
/// `out_ptr` / `out_len` 交出（[crate::ffc_free_bytes] 释放）。搜索框落到图外返回
/// [status::INVALID_ARGUMENT]（旧实现抛 RangeError）。
///
/// # Safety
/// 指针按给定长度可读 / 可写；`rect` 可读 4 个 f64。
#[no_mangle]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn ffc_gal_measure_ink(
    pixels: *const u8,
    len: usize,
    stride: usize,
    channels: u32,
    width: u32,
    height: u32,
    rect: *const f64,
    out_ptr: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    guard(|| {
        if pixels.is_null() || rect.is_null() || out_ptr.is_null() || out_len.is_null() {
            return status::NULL_ARGUMENT;
        }
        let src = match View::new(slice(pixels, len), stride, channels, 0, 0, width, height) {
            Ok(v) => v,
            Err(code) => return code,
        };
        let rect = slice(rect, 4);
        let rect = [rect[0], rect[1], rect[2], rect[3]];
        // `math.min(1, 1600 / width)`：不大于 1 才缩。
        let scale = 1600.0 / src.w as f64;
        let resized: Vec<u8>;
        let view = if scale >= 1.0 {
            src
        } else {
            let dw = round(src.w as f64 * scale) as usize;
            let dh = round(src.h as f64 * scale) as usize;
            let mut dst = vec![0u8; dw * dh * src.ch];
            resize_into(&src, &mut dst, dw, dh, INTERP_NEAREST);
            resized = dst;
            match View::new(
                &resized,
                dw * src.ch,
                src.ch as u32,
                0,
                0,
                dw as u32,
                dh as u32,
            ) {
                Ok(v) => v,
                Err(code) => return code,
            }
        };
        let mut out: Vec<u8> = Vec::new();
        for mode in 0..MODES {
            match measure(&view, rect, mode) {
                Err(code) => return code,
                Ok(None) => out.extend_from_slice(&0i32.to_ne_bytes()),
                Ok(Some((iw, ih, rows))) => {
                    out.extend_from_slice(&1i32.to_ne_bytes());
                    out.extend_from_slice(&(iw as u32).to_ne_bytes());
                    out.extend_from_slice(&(ih as u32).to_ne_bytes());
                    out.extend_from_slice(&(rows.len() as u32).to_ne_bytes());
                    for r in rows {
                        for v in [r.top, r.bottom, r.left, r.right] {
                            out.extend_from_slice(&(v as i32).to_ne_bytes());
                        }
                        for c in r.columns {
                            out.extend_from_slice(&c.to_ne_bytes());
                        }
                    }
                }
            }
        }
        crate::hand_over_bytes(out, out_ptr, out_len);
        status::OK
    })
}

// ---------------------------------------------------------------------------
// 网格拟合（`_lines` / `_score` / `_fitSample`）。
// ---------------------------------------------------------------------------

#[inline]
fn is_space(u: u32) -> bool {
    u == 0x20 || u == 0x3000
}

#[inline]
fn is_newline(u: u32) -> bool {
    u == 10 || u == 13
}

#[inline]
fn is_centered(u: u32) -> bool {
    (0x3041..=0x3096).contains(&u)
        || (0x30a1..=0x30fa).contains(&u)
        || (0x3400..=0x9fff).contains(&u)
}

/// `_lines`：按容量 / 续行缩进把逻辑单元切成行（Hook 自带换行时只按换行切）。
fn lines(units: &[u32], hook_break: bool, capacity: i64, indent: i64) -> Vec<Vec<u32>> {
    let mut lines: Vec<Vec<u32>> = vec![Vec::new()];
    let mut previous = 0u32;
    for &unit in units {
        if is_newline(unit) {
            if unit != 10 || previous != 13 {
                lines.push(Vec::new());
            }
        } else {
            let limit = capacity - if lines.len() == 1 { 0 } else { indent };
            if !hook_break && lines.last().unwrap().len() as i64 == limit {
                lines.push(Vec::new());
            }
            lines.last_mut().unwrap().push(unit);
        }
        previous = unit;
    }
    while lines.len() > 1 && lines.last().unwrap().is_empty() {
        lines.pop();
    }
    lines
}

struct Sample<'a> {
    rows: Vec<RowRef<'a>>,
    width: i64,
}

struct RowRef<'a> {
    top: i64,
    bottom: i64,
    left: i64,
    right: i64,
    columns: &'a [i32],
}

impl RowRef<'_> {
    fn height(&self) -> i64 {
        self.bottom - self.top
    }
}

/// `_score`（[lines] 已按 capacity / indent 切好）。
fn score(sample: &Sample, lines: &[Vec<u32>], indent: i64, pitch: f64, origin: f64) -> f64 {
    if lines.len() != sample.rows.len() {
        return f64::INFINITY;
    }
    let mut score = 0.0f64;
    let mut glyphs = 0i64;
    for (r, units) in lines.iter().enumerate() {
        let row = &sample.rows[r];
        let start = origin + if r == 0 { 0.0 } else { indent as f64 * pitch };
        let n = units.len() as f64;
        if units.is_empty()
            || start > (row.left + 1) as f64
            || start + n * pitch < (row.right - 1) as f64
        {
            return f64::INFINITY;
        }
        if row.left as f64 - start > pitch * 0.85
            || start + n * pitch - row.right as f64 > pitch * 0.85
        {
            return f64::INFINITY;
        }
        for (c, &unit) in units.iter().enumerate() {
            let a = round(start + c as f64 * pitch).clamp(0, sample.width);
            let b = round(start + (c + 1) as f64 * pitch).clamp(0, sample.width);
            let mut ink = 0i64;
            let mut first = -1i64;
            let mut last = -1i64;
            let mut boundary = 0i64;
            let margin = 1i64.max(round(pitch * 0.055));
            let mut x = a;
            while x < b {
                let value = row.columns[x as usize] as i64;
                ink += value;
                if value >= 2 {
                    if first < 0 {
                        first = x;
                    }
                    last = x;
                }
                if x - a < margin || b - x <= margin {
                    boundary += value;
                }
                x += 1;
            }
            if is_space(unit) {
                if ink as f64 > row.height() as f64 * 0.3 {
                    return f64::INFINITY;
                }
                continue;
            }
            if first < 0 || ink < 4 {
                return f64::INFINITY;
            }
            glyphs += 1;
            score += (4 * boundary) as f64 / ink as f64;
            if is_centered(unit) {
                let offset = ((first + last + 1) as f64 / 2.0 - (a + b) as f64 / 2.0) / pitch;
                score += offset * offset * 4.0;
            }
        }
    }
    if glyphs < 4 {
        f64::INFINITY
    } else {
        score / glyphs as f64
    }
}

#[derive(Clone, Copy)]
struct GridFit {
    columns: i64,
    indent: i64,
    pitch: f64,
    left: f64,
    score: f64,
}

/// `_fitSample`。
fn fit_sample(sample: &Sample, units: &[u32], hook_break: bool) -> Option<GridFit> {
    if sample.rows.len() < 2 {
        return None;
    }
    let length = units.len() as i64;
    let mut heights: Vec<f64> = sample.rows.iter().map(|r| r.height() as f64).collect();
    let ink_height = median(&mut heights);
    let mut candidates: Vec<GridFit> = Vec::new();
    let mut capacity = 4i64;
    while capacity <= 128.min(length) {
        let mut indent = 0i64;
        while indent <= 8 && indent < capacity {
            let ls = lines(units, hook_break, capacity, indent);
            if ls.len() != sample.rows.len() || ls.iter().any(|l| l.is_empty()) {
                indent += 1;
                continue;
            }
            let mut widths: Vec<f64> = (0..ls.len())
                .map(|r| (sample.rows[r].right - sample.rows[r].left) as f64 / ls[r].len() as f64)
                .collect();
            let nominal = median(&mut widths);
            let mut best: Option<GridFit> = None;
            for step in -50i64..=50 {
                let pitch = nominal * (1.0 + step as f64 * 0.003);
                if pitch < ink_height * 0.65 || pitch > ink_height * 1.6 {
                    continue;
                }
                for phase in 0i64..=20 {
                    let origin = sample.rows[0].left as f64 - pitch * phase as f64 * 0.025;
                    if origin < 0.0 || origin + capacity as f64 * pitch > sample.width as f64 {
                        continue;
                    }
                    let s = score(sample, &ls, indent, pitch, origin);
                    if best.is_none_or(|b| s < b.score) {
                        best = Some(GridFit {
                            columns: capacity,
                            indent,
                            pitch,
                            left: origin,
                            score: s,
                        });
                    }
                }
            }
            if let Some(b) = best {
                if b.score.is_finite() {
                    candidates.push(b);
                }
            }
            indent += 1;
        }
        capacity += 1;
    }
    sort(&mut candidates, &mut |a, b| compare_f64(a.score, b.score));
    let first = *candidates.first()?;
    if first.score >= 0.09 {
        return None;
    }
    if candidates.len() > 1 && candidates[1].score - first.score < 0.025 {
        return None;
    }
    Some(first)
}

/// 解析 Dart 传来的行描述：每行 `[top, bottom, left, right]`（`rows`，i32 × 4）+ 每行
/// `width` 个列计数（`columns`，行主序拼接）。
unsafe fn sample_from<'a>(
    rows: *const i32,
    row_count: usize,
    columns: *const i32,
    width: usize,
) -> Sample<'a> {
    let rows = slice(rows, row_count * 4);
    let columns = slice(columns, row_count * width);
    Sample {
        rows: (0..row_count)
            .map(|i| RowRef {
                top: rows[i * 4] as i64,
                bottom: rows[i * 4 + 1] as i64,
                left: rows[i * 4 + 2] as i64,
                right: rows[i * 4 + 3] as i64,
                columns: &columns[i * width..(i + 1) * width],
            })
            .collect(),
        width: width as i64,
    }
}

/// `_fitSample`：在一张样本的墨迹行上搜容量 / 续行缩进 / 字距 / 起点。[units] 是文本的逻辑
/// 单元（`_logicalUnits`），[hook_break] = 文本（去尾空白后）含 `\r` / `\n`。找到时 `out` 写
/// `[columns, indent, pitch, left, score]` 并返回 1，否则返回 0；负数是错误码。
///
/// # Safety
/// 指针按给定长度可读 / 可写；`out` 可写 5 个 f64。
#[no_mangle]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn ffc_gal_fit_sample(
    rows: *const i32,
    row_count: usize,
    columns: *const i32,
    width: usize,
    units: *const u32,
    unit_count: usize,
    hook_break: i32,
    out: *mut f64,
) -> i32 {
    guard(|| {
        if out.is_null() || (row_count > 0 && (rows.is_null() || columns.is_null())) {
            return status::NULL_ARGUMENT;
        }
        if unit_count > 0 && units.is_null() {
            return status::NULL_ARGUMENT;
        }
        let sample = sample_from(rows, row_count, columns, width);
        match fit_sample(&sample, slice(units, unit_count), hook_break != 0) {
            Some(f) => {
                slice_mut(out, 5).copy_from_slice(&[
                    f.columns as f64,
                    f.indent as f64,
                    f.pitch,
                    f.left,
                    f.score,
                ]);
                1
            }
            None => 0,
        }
    })
}

/// `_score(sample, capacity, indent, pitch, origin)`（留出样本校验用），写 `out`。
///
/// # Safety
/// 指针按给定长度可读；`out` 可写 1 个 f64。
#[no_mangle]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn ffc_gal_score(
    rows: *const i32,
    row_count: usize,
    columns: *const i32,
    width: usize,
    units: *const u32,
    unit_count: usize,
    hook_break: i32,
    capacity: i64,
    indent: i64,
    pitch: f64,
    origin: f64,
    out: *mut f64,
) -> i32 {
    guard(|| {
        if out.is_null() || (row_count > 0 && (rows.is_null() || columns.is_null())) {
            return status::NULL_ARGUMENT;
        }
        if unit_count > 0 && units.is_null() {
            return status::NULL_ARGUMENT;
        }
        let sample = sample_from(rows, row_count, columns, width);
        let ls = lines(slice(units, unit_count), hook_break != 0, capacity, indent);
        *out = score(&sample, &ls, indent, pitch, origin);
        status::OK
    })
}

// ---------------------------------------------------------------------------
// OCR 墨迹几何：前景色候选 + 字格边界搜索（`_measureInkLine` 的像素部分）。
// ---------------------------------------------------------------------------

/// `_retainGlyphComponents`：去掉横跨多个字格的连通块（面板、横线、背景）。
fn retain_glyph_components(mask: &mut [u8], width: usize, height: usize, pitch: f64) {
    let n = mask.len();
    let mut visited = vec![0u8; n];
    let mut queue = vec![0usize; n];
    for seed in 0..n {
        if mask[seed] == 0 || visited[seed] != 0 {
            continue;
        }
        let mut read = 0usize;
        let mut count = 1usize;
        queue[0] = seed;
        visited[seed] = 1;
        let mut left = seed % width;
        let mut right = left;
        let mut top = seed / width;
        let mut bottom = top;
        while read < count {
            let at = queue[read];
            read += 1;
            let (x, y) = (at % width, at / width);
            left = left.min(x);
            right = right.max(x);
            top = top.min(y);
            bottom = bottom.max(y);
            let mut visit = |next: usize| {
                if mask[next] != 0 && visited[next] == 0 {
                    visited[next] = 1;
                    queue[count] = next;
                    count += 1;
                }
            };
            if x > 0 {
                visit(at - 1);
            }
            if x + 1 < width {
                visit(at + 1);
            }
            if y > 0 {
                visit(at - width);
            }
            if y + 1 < height {
                visit(at + width);
            }
        }
        if count < 2
            || (right - left + 1) as f64 > pitch * 1.15
            || (bottom - top + 1) as f64 > pitch * 1.5
        {
            for &i in &queue[..count] {
                mask[i] = 0;
            }
        }
    }
}

/// `_measureInkLine` 第 259–356 行：在裁剪框 `(x0, y0, width, height)` 内取出现最多的 10 种
/// 量化颜色作前景候选，各自做掩码、去掉跨字格连通块，按锚点处的列投影搜字距 / 起点，返回
/// 得分最低的 `(score, left, pitch, mask)`。[anchors] 每条 `[centerX, cellOffset]`。
#[allow(clippy::too_many_arguments)]
fn ink_search(
    img: &View,
    x0: usize,
    y0: usize,
    width: usize,
    height: usize,
    pitch: f64,
    initial_left: f64,
    anchors: &[(f64, i64)],
) -> Option<(f64, f64, f64, Vec<u8>)> {
    let mut rgb = vec![0u8; width * height * 3];
    let mut histogram = vec![0i64; 512];
    let mut sums = vec![[0i64; 3]; 512];
    for y in 0..height {
        for x in 0..width {
            let p = img.rgba(x0 + x, y0 + y);
            let (r, g, b) = (p[0], p[1], p[2]);
            let o = (y * width + x) * 3;
            rgb[o] = r as u8;
            rgb[o + 1] = g as u8;
            rgb[o + 2] = b as u8;
            let bucket = ((r / 32) * 64 + (g / 32) * 8 + b / 32) as usize;
            histogram[bucket] += 1;
            sums[bucket][0] += r;
            sums[bucket][1] += g;
            sums[bucket][2] += b;
        }
    }
    let mut colors: Vec<usize> = (0..512).collect();
    sort(&mut colors, &mut |a, b| {
        compare_i64(histogram[b], histogram[a])
    });
    let x0f = x0 as f64;
    let wf = width as i64;
    // 每个候选色的掩码留着，最优解只记下标（不在每次刷新最优时拷贝掩码）。
    let mut masks: Vec<Vec<u8>> = Vec::new();
    let mut best: Option<(f64, f64, f64, usize)> = None;
    for &color in colors.iter().take(10) {
        let count = histogram[color];
        if count == 0 {
            continue;
        }
        let mean = [
            sums[color][0] as f64 / count as f64,
            sums[color][1] as f64 / count as f64,
            sums[color][2] as f64 / count as f64,
        ];
        let mut mask = vec![0u8; width * height];
        let mut projection = vec![0f64; width];
        for i in 0..width * height {
            let o = i * 3;
            if (rgb[o] as f64 - mean[0]).abs() < 25.0
                && (rgb[o + 1] as f64 - mean[1]).abs() < 25.0
                && (rgb[o + 2] as f64 - mean[2]).abs() < 25.0
            {
                mask[i] = 1;
            }
        }
        retain_glyph_components(&mut mask, width, height, pitch);
        for y in 0..height {
            for x in 0..width {
                projection[x] += mask[y * width + x] as f64;
            }
        }
        let mut support: Vec<f64> = Vec::with_capacity(anchors.len());
        for &(center_x, _) in anchors {
            let a = ((center_x - pitch * 0.35 - x0f).floor() as i64).clamp(0, wf);
            let b = ((center_x + pitch * 0.35 - x0f).ceil() as i64).clamp(a, wf);
            let mut sum = 0.0f64;
            for v in &projection[a as usize..b as usize] {
                sum += v;
            }
            support.push(if b == a {
                0.0
            } else {
                sum / ((b - a) * height as i64) as f64
            });
        }
        sort(&mut support, &mut |a, b| compare_f64(a, b));
        let q20 = support[(support.len() as f64 * 0.2).floor() as usize];
        if q20 < 0.045 || median(&mut support.clone()) > 0.65 {
            continue;
        }
        let smooth: Vec<f64> = (0..width)
            .map(|x| {
                (projection[x.saturating_sub(1)]
                    + projection[x]
                    + projection[(width - 1).min(x + 1)])
                    / 3.0
            })
            .collect();
        let mut total = projection[0];
        for v in &projection[1..] {
            total += v;
        }
        let average = total / width as f64;
        for step in -14i64..=14 {
            let trial_pitch = pitch * (1.0 + step as f64 * 0.0025);
            for phase in -16i64..=16 {
                let left = initial_left + phase as f64 * 0.02 * pitch;
                let mut cut = 0.0f64;
                let mut edges = 0i64;
                for &(_, cell_offset) in anchors {
                    for side in 0..=1i64 {
                        let x = left + (cell_offset + side) as f64 * trial_pitch - x0f;
                        if x < 1.0 || x >= (width - 1) as f64 {
                            continue;
                        }
                        let lo = x.floor() as i64;
                        let frac = x - lo as f64;
                        cut += smooth[lo as usize] * (1.0 - frac) + smooth[lo as usize + 1] * frac;
                        edges += 1;
                    }
                }
                if (edges as f64) < anchors.len() as f64 * 1.6 {
                    continue;
                }
                let score = cut / edges as f64 / (average + 0.01)
                    + 0.03 * (phase as f64 * 0.02).abs()
                    + 0.2 * (step as f64 * 0.0025).abs();
                if best.is_none_or(|b| score < b.0) {
                    best = Some((score, left, trial_pitch, masks.len()));
                }
            }
        }
        masks.push(mask);
    }
    best.map(|(score, left, trial_pitch, i)| {
        (score, left, trial_pitch, std::mem::take(&mut masks[i]))
    })
}

/// [ink_search] 的 C ABI。像素是 `decodePng` 布局的整张截图（1～4 通道），裁剪框必须在图内。
/// 找到时 `out = [score, left, pitch]`、`out_mask` 写 `width × height` 字节掩码并返回 1，
/// 否则返回 0；负数是错误码。
///
/// # Safety
/// 指针按给定长度可读 / 可写；`out` 可写 3 个 f64，`out_mask` 可写 `width * height` 字节。
#[no_mangle]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn ffc_gal_ink_search(
    pixels: *const u8,
    len: usize,
    stride: usize,
    channels: u32,
    image_w: u32,
    image_h: u32,
    x0: u32,
    y0: u32,
    width: u32,
    height: u32,
    pitch: f64,
    initial_left: f64,
    anchor_centers: *const f64,
    anchor_cells: *const i32,
    anchor_count: usize,
    out: *mut f64,
    out_mask: *mut u8,
) -> i32 {
    guard(|| {
        if pixels.is_null() || out.is_null() || out_mask.is_null() {
            return status::NULL_ARGUMENT;
        }
        if anchor_count == 0 || anchor_centers.is_null() || anchor_cells.is_null() {
            return status::INVALID_ARGUMENT;
        }
        let img = match View::new(slice(pixels, len), stride, channels, 0, 0, image_w, image_h) {
            Ok(v) => v,
            Err(code) => return code,
        };
        let (x0, y0, w, h) = (x0 as usize, y0 as usize, width as usize, height as usize);
        if w == 0 || h == 0 || x0 + w > img.w || y0 + h > img.h {
            return status::INVALID_ARGUMENT;
        }
        let centers = slice(anchor_centers, anchor_count);
        let cells = slice(anchor_cells, anchor_count);
        let anchors: Vec<(f64, i64)> = centers
            .iter()
            .zip(cells)
            .map(|(&c, &o)| (c, o as i64))
            .collect();
        match ink_search(&img, x0, y0, w, h, pitch, initial_left, &anchors) {
            Some((score, left, trial_pitch, mask)) => {
                slice_mut(out, 3).copy_from_slice(&[score, left, trial_pitch]);
                slice_mut(out_mask, w * h).copy_from_slice(&mask);
                1
            }
            None => 0,
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lines_wrap_at_capacity_with_indent() {
        let units: Vec<u32> = (0..10).map(|i| 0x3042 + i).collect();
        let ls = lines(&units, false, 4, 1);
        assert_eq!(
            ls.iter().map(|l| l.len()).collect::<Vec<_>>(),
            vec![4, 3, 3]
        );
        // CRLF 只换一次行，尾部空行去掉。
        let ls = lines(&[0x3042, 13, 10, 0x3043, 13, 10], true, 4, 0);
        assert_eq!(ls.len(), 2);
    }

    #[test]
    fn specks_far_from_the_run_are_removed() {
        let mut columns = vec![0i32; 100];
        for c in &mut columns[10..60] {
            *c = 5;
        }
        columns[95] = 2;
        remove_isolated_specks(&mut columns, 10);
        assert_eq!(columns[95], 0);
        assert_eq!(columns[30], 5);
    }
}
