//! `ffc_image_*`：图像域的纯算术内核（缩放 / 归一化成模型输入 / 马赛克 / dHash）。
//!
//! 这些操作只有这一份实现（Dart 侧经 `packages/fushi_compute` 绑定、
//! `packages/fushi_engine/lib/media/image_kernels.dart` 适配，没有 Dart 回退）。它们逐条复刻
//! 原先 `package:image` 4.3 逐像素循环（`copyResize` / `copyCrop` / `compositeImage` /
//! `getPixel`）的算术，结果**逐位一致**——回归向量由旧 Dart 实现生成，见
//! `packages/fushi_engine/test/media/image_kernels/`：
//! - 浮点运算按 Dart 的求值顺序、同为 IEEE-754 binary64（Dart 不做 FMA 收缩，Rust 默认也不做），
//!   `double → int` 一律截断（Dart `toInt()`），夹取规则同 `ImageDataUint8.getColor`。
//! - 写 float32 张量时先在 f64 里算完再舍入成 f32，与 Dart 往 `Float32List` 里存 double 相同。
//!
//! 只接 `Format.uint8`、无调色板、1～4 通道、行紧排的像素（`img.Image.toUint8List()` 原样）；
//! 1 / 2 通道按 `PixelUint8` 的 r/g/b/a 读写规则处理（与 Dart 逐位相同）。16 位 / 浮点 /
//! 调色板图由 Dart 侧先 `convert` 成 uint8，未转正的 EXIF 方向先 `bakeOrientation`
//! （`copyResize` 自己也这么做），多帧图由 Dart 侧逐帧调用。
//!
//! 解码 / 编码（JPEG / PNG）**不在本模块**，仍由 Dart 的 `package:image` 做。2026-10-18 实测
//! （真书漫画页 1350×1920 / 2000×2844 JPEG）：`zune-jpeg` 0.4 与 `jpeg-decoder` 0.3 解出的
//! RGB 与 `package:image` 有 3.5～4.8% 的通道值差 ±1（最大 1），dHash 不变，但 RT-DETR 输入
//! 张量有约 4% 的元素差 1/255，检测框 / OCR 结果无法保证逐位不变；解码因此不搬，以免同一张
//! 图在不同路径上得出不同的 OCR 缓存与分镜框。

use crate::{guard, status};

/// 缩放插值，取值与 `package:image` 的 `Interpolation` 对应（不支持 cubic）。
pub const INTERP_NEAREST: i32 = 0;
pub const INTERP_LINEAR: i32 = 1;
pub const INTERP_AVERAGE: i32 = 2;

/// 一张行主序 uint8 图上的矩形视图（`copyCrop` 的零拷贝等价物）。
#[derive(Clone, Copy)]
struct View<'a> {
    data: &'a [u8],
    stride: usize,
    ch: usize,
    x0: usize,
    y0: usize,
    w: usize,
    h: usize,
}

impl<'a> View<'a> {
    /// 校验后构造；失败返回状态码。
    #[allow(clippy::too_many_arguments)]
    fn new(
        data: &'a [u8],
        stride: usize,
        ch: u32,
        x0: u32,
        y0: u32,
        w: u32,
        h: u32,
    ) -> Result<Self, i32> {
        let ch = ch as usize;
        if !(1..=4).contains(&ch) {
            return Err(status::INVALID_ARGUMENT);
        }
        let (x0, y0, w, h) = (x0 as usize, y0 as usize, w as usize, h as usize);
        if w == 0 || h == 0 {
            return Err(status::INVALID_ARGUMENT);
        }
        let row_end = (x0 + w)
            .checked_mul(ch)
            .ok_or(status::INVALID_ARGUMENT)?;
        if row_end > stride {
            return Err(status::INVALID_ARGUMENT);
        }
        let need = (y0 + h - 1)
            .checked_mul(stride)
            .and_then(|v| v.checked_add(row_end))
            .ok_or(status::INVALID_ARGUMENT)?;
        if data.len() < need {
            return Err(status::BUFFER_TOO_SMALL);
        }
        Ok(Self {
            data,
            stride,
            ch,
            x0,
            y0,
            w,
            h,
        })
    }

    #[inline(always)]
    fn offset(&self, x: usize, y: usize) -> usize {
        (self.y0 + y) * self.stride + (self.x0 + x) * self.ch
    }

    /// `PixelUint8` 的 r/g/b/a 读法：1 通道 `[l, 0, 0, 255]`、2 通道 `[l, l, l, a]`、
    /// 3 通道 a 恒为 255。
    #[inline(always)]
    fn rgba(&self, x: usize, y: usize) -> [i64; 4] {
        let i = self.offset(x, y);
        let d = &self.data[i..i + self.ch];
        match self.ch {
            1 => [d[0] as i64, 0, 0, 255],
            2 => [d[0] as i64, d[0] as i64, d[0] as i64, d[1] as i64],
            3 => [d[0] as i64, d[1] as i64, d[2] as i64, 255],
            _ => [d[0] as i64, d[1] as i64, d[2] as i64, d[3] as i64],
        }
    }

    /// `getPixelSafe`：越界给 `Pixel.undefined`（全 0）。
    #[inline(always)]
    fn rgba_safe(&self, x: i64, y: i64) -> [i64; 4] {
        if x < 0 || y < 0 || x as usize >= self.w || y as usize >= self.h {
            [0; 4]
        } else {
            self.rgba(x as usize, y as usize)
        }
    }
}

/// `ImageDataUint8.getColor` 的单通道换算：夹进 [0, 255] 后截断。
#[inline(always)]
fn to_u8(v: f64) -> u8 {
    if v < 0.0 {
        0
    } else if v > 255.0 {
        255
    } else {
        v as u8
    }
}

/// `copyResize(src, width: dw, height: dh, interpolation: ...)`（不保持比例、单帧）写进 [dst]
/// （行紧排、与源同通道数）。目标与源同尺寸时等价于 `clone`。
fn resize_into(src: &View, dst: &mut [u8], dw: usize, dh: usize, interp: i32) {
    let ch = src.ch;
    if dw == src.w && dh == src.h {
        for y in 0..dh {
            let s = src.offset(0, y);
            dst[y * dw * ch..(y + 1) * dw * ch].copy_from_slice(&src.data[s..s + dw * ch]);
        }
        return;
    }
    let dx = src.w as f64 / dw as f64;
    let dy = src.h as f64 / dh as f64;
    match interp {
        INTERP_NEAREST => {
            let scale_x: Vec<usize> = (0..dw).map(|x| (x as f64 * dx) as usize).collect();
            for y in 0..dh {
                let sy = (y as f64 * dy) as usize;
                let row = &mut dst[y * dw * ch..(y + 1) * dw * ch];
                for (x, &sx) in scale_x.iter().enumerate() {
                    // `dst.setPixel(x, y, src.getPixel(sx, sy))`：经 r/g/b/a 读写（2 通道时
                    // 第二通道写成亮度，与 Dart 相同）；3 / 4 通道时等价于原样拷字节。
                    if ch >= 3 {
                        let s = src.offset(sx, sy);
                        row[x * ch..x * ch + ch].copy_from_slice(&src.data[s..s + ch]);
                    } else {
                        let p = src.rgba(sx, sy);
                        for c in 0..ch {
                            row[x * ch + c] = p[c] as u8;
                        }
                    }
                }
            }
        }
        INTERP_AVERAGE => {
            for y in 0..dh {
                let ay1 = (y as f64 * dy) as usize;
                let mut ay2 = ((y + 1) as f64 * dy) as usize;
                if ay2 == ay1 {
                    ay2 += 1;
                }
                for x in 0..dw {
                    let ax1 = (x as f64 * dx) as usize;
                    let mut ax2 = ((x + 1) as f64 * dx) as usize;
                    if ax2 == ax1 {
                        ax2 += 1;
                    }
                    let mut sum = [0i64; 4];
                    let mut np = 0i64;
                    for sy in ay1..ay2 {
                        if ch >= 3 {
                            // 3 / 4 通道的逻辑通道就是原始字节。
                            let row = &src.data[src.offset(ax1, sy)..src.offset(ax2, sy)];
                            for p in row.chunks_exact(ch) {
                                for c in 0..ch {
                                    sum[c] += p[c] as i64;
                                }
                            }
                            np += (ax2 - ax1) as i64;
                        } else {
                            for sx in ax1..ax2 {
                                let p = src.rgba(sx, sy);
                                for c in 0..ch {
                                    sum[c] += p[c];
                                }
                                np += 1;
                            }
                        }
                    }
                    let o = (y * dw + x) * ch;
                    for c in 0..ch {
                        dst[o + c] = to_u8(sum[c] as f64 / np as f64);
                    }
                }
            }
        }
        _ => {
            // INTERP_LINEAR：`Image.getPixelLinear`。
            for y in 0..dh {
                let fy = y as f64 * dy;
                let yi = fy as i64 - if fy >= 0.0 { 0 } else { 1 };
                let ny = yi + 1;
                let ddy = fy - yi as f64;
                for x in 0..dw {
                    let fx = x as f64 * dx;
                    let xi = fx as i64 - if fx >= 0.0 { 0 } else { 1 };
                    let nx = xi + 1;
                    let ddx = fx - xi as f64;
                    let icc = src.rgba_safe(xi, yi);
                    let icn = if ny >= src.h as i64 {
                        icc
                    } else {
                        src.rgba_safe(xi, ny)
                    };
                    let inc = if nx >= src.w as i64 {
                        icc
                    } else {
                        src.rgba_safe(nx, yi)
                    };
                    let inn = if nx >= src.w as i64 || ny >= src.h as i64 {
                        icc
                    } else {
                        src.rgba_safe(nx, ny)
                    };
                    let o = (y * dw + x) * ch;
                    for c in 0..ch {
                        let v = icc[c] as f64
                            + ddx
                                * ((inc[c] - icc[c]) as f64
                                    + ddy * ((icc[c] + inn[c] - icn[c] - inc[c]) as f64))
                            + ddy * ((icn[c] - icc[c]) as f64);
                        dst[o + c] = to_u8(v);
                    }
                }
            }
        }
    }
}

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

fn valid_interp(interp: i32) -> bool {
    matches!(interp, INTERP_NEAREST | INTERP_LINEAR | INTERP_AVERAGE)
}

/// 把源图矩形 `(crop_x, crop_y, crop_w, crop_h)`（即 `copyCrop`）缩放到 `dst_w × dst_h`
/// 写进 [dst]（行紧排，与源同通道数）。`src_stride` 是源图每行字节数。
///
/// # Safety
/// 指针按给定长度可读 / 可写。
#[no_mangle]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn ffc_image_resize(
    src: *const u8,
    src_len: usize,
    src_stride: usize,
    channels: u32,
    crop_x: u32,
    crop_y: u32,
    crop_w: u32,
    crop_h: u32,
    dst: *mut u8,
    dst_len: usize,
    dst_w: u32,
    dst_h: u32,
    interp: i32,
) -> i32 {
    guard(|| {
        if src.is_null() || dst.is_null() {
            return status::NULL_ARGUMENT;
        }
        if !valid_interp(interp) || dst_w == 0 || dst_h == 0 {
            return status::INVALID_ARGUMENT;
        }
        let view = match View::new(
            slice(src, src_len),
            src_stride,
            channels,
            crop_x,
            crop_y,
            crop_w,
            crop_h,
        ) {
            Ok(v) => v,
            Err(code) => return code,
        };
        let (dw, dh) = (dst_w as usize, dst_h as usize);
        if dst_len < dw * dh * view.ch {
            return status::BUFFER_TOO_SMALL;
        }
        resize_into(&view, slice_mut(dst, dst_len), dw, dh, interp);
        status::OK
    })
}

/// letterbox 画布的填充灰（YOLO 惯例，`rtdetrPreprocess`）。
const LETTERBOX_FILL: u8 = 114;

/// `compositeImage(canvas, resized, dstX: pad_x, dstY: pad_y)`（默认 alpha 混合）到
/// 填满 [LETTERBOX_FILL] 的 3 通道画布上，逐位复刻 `drawPixel` 的浮点路径：
/// `((ov * oa) + (base * baseA) * (1 - oa)) * 255` 截断，`oa` 只有 4 通道源才取自 alpha。
fn letterbox_canvas(resized: &View, cw: usize, chh: usize, pad_x: i64, pad_y: i64) -> Vec<u8> {
    let mut canvas = vec![LETTERBOX_FILL; cw * chh * 3];
    let base = LETTERBOX_FILL as f64 / 255.0;
    let base_a = 1.0f64;
    for y in 0..resized.h {
        let ty = pad_y + y as i64;
        if ty < 0 || ty >= chh as i64 {
            continue;
        }
        for x in 0..resized.w {
            let tx = pad_x + x as i64;
            if tx < 0 || tx >= cw as i64 {
                continue;
            }
            let p = resized.rgba(x, y);
            let oa = if resized.ch == 4 { p[3] as f64 / 255.0 } else { 1.0 };
            if oa == 0.0 {
                continue;
            }
            let inv_a = 1.0 - oa;
            let o = (ty as usize * cw + tx as usize) * 3;
            for c in 0..3 {
                let ov = p[c] as f64 / 255.0;
                let v = (ov * oa + base * base_a * inv_a) * 255.0;
                // `data[i] = v.toInt()` 写进 Uint8List（取低 8 位）。
                canvas[o + c] = (v as i64 & 0xff) as u8;
            }
        }
    }
    canvas
}

/// 缩放（同 [ffc_image_resize]）到 `dst_w × dst_h`，再转成 CHW float32 模型输入：
/// `out[c][y][x] = (v / 255.0 - mean[c]) / std[c]`，`c` 是**输出**通道序（`bgr != 0` 时
/// 0 = B、2 = R，否则 0 = R）。
///
/// `canvas_w × canvas_h` 与缩放尺寸不同时走 letterbox：缩放结果按 `(pad_x, pad_y)` 合成到
/// [LETTERBOX_FILL] 灰画布上（[letterbox_canvas]），张量取画布；相同时 pad 不起作用。
/// 张量每行宽 `plane_w`（≥ 画布宽，右侧填充写 0），共 `3 × canvas_h × plane_w` 个值。
///
/// # Safety
/// 指针按给定长度可读 / 可写；`mean` / `std` 各 3 个 f64。
#[no_mangle]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn ffc_image_resize_chw(
    src: *const u8,
    src_len: usize,
    src_stride: usize,
    channels: u32,
    crop_x: u32,
    crop_y: u32,
    crop_w: u32,
    crop_h: u32,
    dst_w: u32,
    dst_h: u32,
    interp: i32,
    canvas_w: u32,
    canvas_h: u32,
    pad_x: i32,
    pad_y: i32,
    plane_w: u32,
    bgr: i32,
    mean: *const f64,
    std: *const f64,
    out: *mut f32,
    out_len: usize,
) -> i32 {
    guard(|| {
        if src.is_null() || out.is_null() || mean.is_null() || std.is_null() {
            return status::NULL_ARGUMENT;
        }
        if !valid_interp(interp)
            || dst_w == 0
            || dst_h == 0
            || canvas_w == 0
            || canvas_h == 0
            || plane_w < canvas_w
        {
            return status::INVALID_ARGUMENT;
        }
        let view = match View::new(
            slice(src, src_len),
            src_stride,
            channels,
            crop_x,
            crop_y,
            crop_w,
            crop_h,
        ) {
            Ok(v) => v,
            Err(code) => return code,
        };
        let (dw, dh) = (dst_w as usize, dst_h as usize);
        let (cw, chh, pw) = (canvas_w as usize, canvas_h as usize, plane_w as usize);
        let plane = chh * pw;
        if out_len < 3 * plane {
            return status::BUFFER_TOO_SMALL;
        }
        let mean = slice(mean, 3);
        let std = slice(std, 3);
        let mut resized = vec![0u8; dw * dh * view.ch];
        resize_into(&view, &mut resized, dw, dh, interp);
        let resized_view = View {
            data: &resized,
            stride: dw * view.ch,
            ch: view.ch,
            x0: 0,
            y0: 0,
            w: dw,
            h: dh,
        };
        let canvas;
        let img = if cw == dw && chh == dh {
            resized_view
        } else {
            canvas = letterbox_canvas(&resized_view, cw, chh, pad_x as i64, pad_y as i64);
            View {
                data: &canvas,
                stride: cw * 3,
                ch: 3,
                x0: 0,
                y0: 0,
                w: cw,
                h: chh,
            }
        };
        let ch = img.ch;
        let out = slice_mut(out, out_len);
        // 输出通道 c 取源逻辑通道 src_c[c]。
        let src_c: [usize; 3] = if bgr != 0 { [2, 1, 0] } else { [0, 1, 2] };
        for c in 0..3 {
            // 查表：256 个取值各算一次，结果与逐像素现算逐位相同（同一表达式）。
            let mut lut = [0f32; 256];
            for (v, slot) in lut.iter_mut().enumerate() {
                *slot = ((v as f64 / 255.0 - mean[c]) / std[c]) as f32;
            }
            let base = c * plane;
            let sc = src_c[c];
            for y in 0..img.h {
                let row = &mut out[base + y * pw..base + (y + 1) * pw];
                if ch == 3 || ch == 4 {
                    let src_row = &img.data[y * img.stride..y * img.stride + img.w * ch];
                    for x in 0..img.w {
                        row[x] = lut[src_row[x * ch + sc] as usize];
                    }
                } else {
                    // 1 / 2 通道：按 `Pixel` 的 r/g/b 读法（1 通道 g = b = 0）。
                    for (x, slot) in row.iter_mut().take(img.w).enumerate() {
                        *slot = lut[img.rgba(x, y)[sc] as usize];
                    }
                }
                for slot in row.iter_mut().skip(img.w) {
                    *slot = 0.0;
                }
            }
        }
        status::OK
    })
}

/// 行紧排的 3 / 4 通道 uint8 → RGBA8888（3 通道补 a = 255；同
/// `convert(format: uint8, numChannels: 4, alpha: 255)`）。
///
/// # Safety
/// 指针按给定长度可读 / 可写。
#[no_mangle]
pub unsafe extern "C" fn ffc_image_to_rgba8(
    src: *const u8,
    src_len: usize,
    channels: u32,
    width: u32,
    height: u32,
    out: *mut u8,
    out_len: usize,
) -> i32 {
    guard(|| {
        if src.is_null() || out.is_null() {
            return status::NULL_ARGUMENT;
        }
        let ch = channels as usize;
        if (ch != 3 && ch != 4) || width == 0 || height == 0 {
            return status::INVALID_ARGUMENT;
        }
        let n = width as usize * height as usize;
        if src_len < n * ch || out_len < n * 4 {
            return status::BUFFER_TOO_SMALL;
        }
        let src = slice(src, n * ch);
        let out = slice_mut(out, n * 4);
        if ch == 4 {
            out.copy_from_slice(src);
        } else {
            for (o, s) in out.chunks_exact_mut(4).zip(src.chunks_exact(3)) {
                o[0] = s[0];
                o[1] = s[1];
                o[2] = s[2];
                o[3] = 255;
            }
        }
        status::OK
    })
}

/// 就地给 RGBA8888 缓冲打码（`applyMosaicRgba` 的内核）。`rects` 是 `rect_count` 组
/// `[x0, y0, x1, y1)`（像素、已夹进图像，即 `mosaicPixelBounds` 的结果），`block` 是块边长。
///
/// # Safety
/// 指针按给定长度可读 / 可写；`rects` 有 `4 * rect_count` 个 i32。
#[no_mangle]
pub unsafe extern "C" fn ffc_image_mosaic_rgba8(
    buf: *mut u8,
    len: usize,
    width: u32,
    height: u32,
    block: u32,
    rects: *const i32,
    rect_count: usize,
) -> i32 {
    guard(|| {
        if buf.is_null() || (rects.is_null() && rect_count > 0) {
            return status::NULL_ARGUMENT;
        }
        let (w, h, s) = (width as usize, height as usize, block as usize);
        if w == 0 || h == 0 || s == 0 {
            return status::INVALID_ARGUMENT;
        }
        if len < w * h * 4 {
            return status::BUFFER_TOO_SMALL;
        }
        let raw = slice(rects, rect_count * 4);
        let mut bounds: Vec<[usize; 4]> = Vec::with_capacity(rect_count);
        for r in raw.chunks_exact(4) {
            if r.iter().any(|&v| v < 0) {
                return status::INVALID_ARGUMENT;
            }
            let b = [r[0] as usize, r[1] as usize, r[2] as usize, r[3] as usize];
            if b[2] > w || b[3] > h || b[2] <= b[0] || b[3] <= b[1] {
                return status::INVALID_ARGUMENT;
            }
            bounds.push(b);
        }
        if bounds.is_empty() {
            return status::OK;
        }
        mosaic_rgba(slice_mut(buf, w * h * 4), w, h, s, &bounds);
        status::OK
    })
}

fn mosaic_rgba(px: &mut [u8], w: usize, h: usize, s: usize, bounds: &[[usize; 4]]) {
    let cols = w.div_ceil(s);
    let rows = h.div_ceil(s);
    let mut touched = vec![false; cols * rows];
    for b in bounds {
        let mut cy = b[1] / s;
        while cy * s < b[3] {
            let mut cx = b[0] / s;
            while cx * s < b[2] {
                touched[cy * cols + cx] = true;
                cx += 1;
            }
            cy += 1;
        }
    }
    let covered =
        |x: usize, y: usize| bounds.iter().any(|b| x >= b[0] && x < b[2] && y >= b[1] && y < b[3]);
    for (cell, _) in touched.iter().enumerate().filter(|(_, &t)| t) {
        let cx0 = (cell % cols) * s;
        let cy0 = (cell / cols) * s;
        let cx1 = (cx0 + s).min(w);
        let cy1 = (cy0 + s).min(h);
        let mut sum = [0u64; 4];
        for y in cy0..cy1 {
            let row = &px[(y * w + cx0) * 4..(y * w + cx1) * 4];
            for p in row.chunks_exact(4) {
                for c in 0..4 {
                    sum[c] += p[c] as u64;
                }
            }
        }
        let n = ((cx1 - cx0) * (cy1 - cy0)) as f64;
        // Dart `(r / n).round()`：非负数上与 f64::round（远离零取整）相同。
        let avg = sum.map(|v| (v as f64 / n).round() as u8);
        for y in cy0..cy1 {
            for x in cx0..cx1 {
                if covered(x, y) {
                    let i = (y * w + x) * 4;
                    px[i..i + 4].copy_from_slice(&avg);
                }
            }
        }
    }
}

const DHASH_COLS: usize = 9;
const DHASH_ROWS: usize = 8;

/// 封面 dHash（`coverDHashOfImage`）：64 位按 Dart 输出的位序写成 8 字节大端到 [out]。
///
/// # Safety
/// 指针按给定长度可读；`out` 可写 8 字节。
#[no_mangle]
pub unsafe extern "C" fn ffc_image_dhash(
    src: *const u8,
    src_len: usize,
    src_stride: usize,
    channels: u32,
    width: u32,
    height: u32,
    out: *mut u8,
) -> i32 {
    guard(|| {
        if src.is_null() || out.is_null() {
            return status::NULL_ARGUMENT;
        }
        let view = match View::new(
            slice(src, src_len),
            src_stride,
            channels,
            0,
            0,
            width,
            height,
        ) {
            Ok(v) => v,
            Err(code) => return code,
        };
        let bits = dhash(&view);
        slice_mut(out, 8).copy_from_slice(&bits.to_be_bytes());
        status::OK
    })
}

fn dhash(v: &View) -> u64 {
    let (w, h) = (v.w, v.h);
    let mut sum = [0f64; DHASH_COLS * DHASH_ROWS];
    let mut count = [0u64; DHASH_COLS * DHASH_ROWS];
    // 列号只随 x 变：先算好。
    let col_of: Vec<usize> = (0..w).map(|x| x * DHASH_COLS / w).collect();
    // `0.299 * p.rNormalized + 0.587 * p.gNormalized + 0.114 * p.bNormalized`：三个乘积各自
    // 只取决于一个 0..255 的通道值，查表得到的是同一个 double，加法顺序不变，结果逐位相同。
    let mut lr = [0f64; 256];
    let mut lg = [0f64; 256];
    let mut lb = [0f64; 256];
    for i in 0..256 {
        lr[i] = 0.299 * (i as f64 / 255.0);
        lg[i] = 0.587 * (i as f64 / 255.0);
        lb[i] = 0.114 * (i as f64 / 255.0);
    }
    for y in 0..h {
        let cy = y * DHASH_ROWS / h;
        if v.ch >= 3 {
            let row = &v.data[v.offset(0, y)..v.offset(0, y) + w * v.ch];
            for (p, &cx) in row.chunks_exact(v.ch).zip(col_of.iter()) {
                let cell = cy * DHASH_COLS + cx;
                sum[cell] += lr[p[0] as usize] + lg[p[1] as usize] + lb[p[2] as usize];
                count[cell] += 1;
            }
        } else {
            for (x, &cx) in col_of.iter().enumerate() {
                let cell = cy * DHASH_COLS + cx;
                let d = v.rgba(x, y);
                sum[cell] += lr[d[0] as usize] + lg[d[1] as usize] + lb[d[2] as usize];
                count[cell] += 1;
            }
        }
    }
    let mut mean = [0f64; DHASH_COLS * DHASH_ROWS];
    for y in 0..DHASH_ROWS {
        let mut last = 0f64;
        for x in 0..DHASH_COLS {
            let i = y * DHASH_COLS + x;
            if count[i] > 0 {
                last = sum[i] / count[i] as f64;
            }
            mean[i] = last;
        }
    }
    let mut bits = 0u64;
    for y in 0..DHASH_ROWS {
        for x in 0..DHASH_COLS - 1 {
            let brighter = mean[y * DHASH_COLS + x] > mean[y * DHASH_COLS + x + 1];
            bits = (bits << 1) | brighter as u64;
        }
    }
    bits
}

// ---------------------------------------------------------------------------
// 位图字幕：DVB 像素串（测量 / 区域渲染）与黑底合成。逐位复刻
// packages/fushi_engine/lib/media/video/bitmap_subtitle/ 里原先的 Dart 实现。
// ---------------------------------------------------------------------------

/// DVB 像素串的位读取器（`_BitReader`）：越界读 0。
struct BitReader<'a> {
    data: &'a [u8],
    bit: usize,
}

impl BitReader<'_> {
    fn exhausted(&self) -> bool {
        (self.bit >> 3) >= self.data.len()
    }

    fn byte_pos_aligned(&self) -> usize {
        (self.bit + 7) >> 3
    }

    fn read(&mut self, n: u32) -> usize {
        let mut v = 0usize;
        for _ in 0..n {
            let byte = self.bit >> 3;
            let b = if byte < self.data.len() {
                ((self.data[byte] >> (7 - (self.bit & 7))) & 1) as usize
            } else {
                0
            };
            v = (v << 1) | b;
            self.bit += 1;
        }
        v
    }
}

fn read_2bit(r: &mut BitReader, emit: &mut dyn FnMut(usize, usize)) {
    while !r.exhausted() {
        let code = r.read(2);
        if code != 0 {
            emit(1, code);
            continue;
        }
        if r.read(1) == 1 {
            let run = r.read(3) + 3;
            let c = r.read(2);
            emit(run, c);
            continue;
        }
        if r.read(1) == 1 {
            emit(1, 0);
            continue;
        }
        match r.read(2) {
            0 => return,
            1 => emit(2, 0),
            2 => {
                let run = r.read(4) + 12;
                let c = r.read(2);
                emit(run, c);
            }
            _ => {
                let run = r.read(8) + 29;
                let c = r.read(2);
                emit(run, c);
            }
        }
    }
}

fn read_4bit(r: &mut BitReader, emit: &mut dyn FnMut(usize, usize)) {
    while !r.exhausted() {
        let code = r.read(4);
        if code != 0 {
            emit(1, code);
            continue;
        }
        if r.read(1) == 0 {
            let run = r.read(3);
            if run == 0 {
                return;
            }
            emit(run + 2, 0);
            continue;
        }
        if r.read(1) == 0 {
            let run = r.read(2) + 4;
            let c = r.read(4);
            emit(run, c);
            continue;
        }
        match r.read(2) {
            0 => emit(1, 0),
            1 => emit(2, 0),
            2 => {
                let run = r.read(4) + 9;
                let c = r.read(4);
                emit(run, c);
            }
            _ => {
                let run = r.read(8) + 25;
                let c = r.read(4);
                emit(run, c);
            }
        }
    }
}

fn read_8bit(r: &mut BitReader, emit: &mut dyn FnMut(usize, usize)) {
    while !r.exhausted() {
        let code = r.read(8);
        if code != 0 {
            emit(1, code);
            continue;
        }
        if r.read(1) == 0 {
            let run = r.read(7);
            if run == 0 {
                return;
            }
            emit(run, 0);
            continue;
        }
        let run = r.read(7);
        let c = r.read(8);
        emit(run, c);
    }
}

/// `walkDvbPixelData`：每个游程回调 (场内行号, 行内起点, 长度, 映射到 [depth] 后的码)。
fn walk_dvb(
    data: &[u8],
    depth: u32,
    on_run: &mut dyn FnMut(usize, usize, usize, usize),
    on_line_end: &mut dyn FnMut(usize),
) {
    let mut map2to4: [usize; 4] = [0x0, 0x7, 0x8, 0xF];
    let mut map2to8: [usize; 4] = [0x00, 0x77, 0x88, 0xFF];
    let mut map4to8: [usize; 16] = std::array::from_fn(|i| i * 0x11);
    let mut line = 0usize;
    let mut x = 0usize;
    let mut o = 0usize;
    let mut saw_pixels = false;
    while o < data.len() {
        let kind = data[o];
        o += 1;
        match kind {
            0x10..=0x12 => {
                let mut r = BitReader { data, bit: o * 8 };
                let bits = match kind {
                    0x10 => 2,
                    0x11 => 4,
                    _ => 8,
                };
                let fits = bits <= depth;
                {
                    let mut emit = |run: usize, code: usize| {
                        if run == 0 {
                            return;
                        }
                        let mapped = if !fits {
                            0
                        } else {
                            match (bits, depth) {
                                (2, 4) => map2to4[code],
                                (2, 8) => map2to8[code],
                                (4, 8) => map4to8[code],
                                _ => code,
                            }
                        };
                        on_run(line, x, run, mapped);
                        x += run;
                    };
                    match bits {
                        2 => read_2bit(&mut r, &mut emit),
                        4 => read_4bit(&mut r, &mut emit),
                        _ => read_8bit(&mut r, &mut emit),
                    }
                }
                saw_pixels = true;
                o = r.byte_pos_aligned();
            }
            0x20 => {
                if o + 2 > data.len() {
                    return;
                }
                map2to4 = [
                    (data[o] >> 4) as usize,
                    (data[o] & 0x0F) as usize,
                    (data[o + 1] >> 4) as usize,
                    (data[o + 1] & 0x0F) as usize,
                ];
                o += 2;
            }
            0x21 => {
                if o + 4 > data.len() {
                    return;
                }
                map2to8 = std::array::from_fn(|i| data[o + i] as usize);
                o += 4;
            }
            0x22 => {
                if o + 16 > data.len() {
                    return;
                }
                map4to8 = std::array::from_fn(|i| data[o + i] as usize);
                o += 16;
            }
            0xF0 => {
                on_line_end(line);
                line += 1;
                x = 0;
                saw_pixels = false;
            }
            _ => {
                if saw_pixels {
                    on_line_end(line);
                }
                return;
            }
        }
    }
    if saw_pixels {
        on_line_end(line);
    }
}

/// `DvbObject._measure`：两场像素串实际覆盖的宽高，写 `out[0] = width, out[1] = height`。
/// `bottom` 为空指针 = 底场重复顶场。
///
/// # Safety
/// 指针按给定长度可读；`out` 可写 2 个 u32。
#[no_mangle]
pub unsafe extern "C" fn ffc_image_dvb_object_size(
    top: *const u8,
    top_len: usize,
    bottom: *const u8,
    bottom_len: usize,
    out: *mut u32,
) -> i32 {
    guard(|| {
        if (top.is_null() && top_len > 0) || out.is_null() {
            return status::NULL_ARGUMENT;
        }
        let top = slice(top, top_len);
        let bottom = if bottom.is_null() {
            top
        } else {
            slice(bottom, bottom_len)
        };
        let (w, h) = dvb_object_size(top, bottom);
        let out = slice_mut(out, 2);
        out[0] = w as u32;
        out[1] = h as u32;
        status::OK
    })
}

fn dvb_object_size(top: &[u8], bottom: &[u8]) -> (usize, usize) {
    let mut width = 0usize;
    let mut height = 0usize;
    for (field, data) in [top, bottom].into_iter().enumerate() {
        let mut lines = 0usize;
        walk_dvb(
            data,
            8,
            &mut |_, x, run, _| {
                if x + run > width {
                    width = x + run;
                }
            },
            &mut |line| lines = line + 1,
        );
        let field_height = if lines == 0 {
            0
        } else {
            (lines - 1) * 2 + 1 + field
        };
        if field_height > height {
            height = field_height;
        }
    }
    (width, height)
}

/// 一个 DVB 对象在区域里的摆放（`ffc_image_dvb_render_region` 的输入）。
#[repr(C)]
pub struct FfcDvbObject {
    pub top: *const u8,
    pub top_len: usize,
    /// 空指针 = 底场重复顶场。
    pub bottom: *const u8,
    pub bottom_len: usize,
    pub x: i32,
    pub y: i32,
}

/// `DvbRegion.render`：`width × height` 区域平面先填 [background]，再按序画各对象
/// （`DvbObject.drawInto`，色深 [depth]）。
///
/// # Safety
/// 指针按给定长度可读 / 可写；`objects` 有 `object_count` 项，各项指针按其长度可读。
#[no_mangle]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn ffc_image_dvb_render_region(
    width: u32,
    height: u32,
    depth: u32,
    background: u32,
    objects: *const FfcDvbObject,
    object_count: usize,
    out: *mut u8,
    out_len: usize,
) -> i32 {
    guard(|| {
        if out.is_null() || (objects.is_null() && object_count > 0) {
            return status::NULL_ARGUMENT;
        }
        let (w, h) = (width as usize, height as usize);
        if out_len < w * h {
            return status::BUFFER_TOO_SMALL;
        }
        let buf = slice_mut(out, w * h);
        // 输出缓冲由调用方分配、未清零：背景（含 0）整块写一遍。
        buf.fill(background as u8);
        for o in slice(objects, object_count) {
            let top = slice(o.top, o.top_len);
            let bottom = if o.bottom.is_null() {
                top
            } else {
                slice(o.bottom, o.bottom_len)
            };
            for (field, data) in [top, bottom].into_iter().enumerate() {
                let (ox, oy) = (o.x as i64, o.y as i64);
                walk_dvb(
                    data,
                    depth,
                    &mut |line, x, run, code| {
                        let y = oy + line as i64 * 2 + field as i64;
                        if y < 0 || y >= h as i64 || code == 0 {
                            return;
                        }
                        let start = (ox + x as i64).clamp(0, w as i64) as usize;
                        let end = (ox + x as i64 + run as i64).clamp(0, w as i64) as usize;
                        if end > start {
                            let row = y as usize * w;
                            buf[row + start..row + end].fill(code as u8);
                        }
                    },
                    &mut |_| {},
                );
            }
        }
        status::OK
    })
}

/// 合成的一层（`BitmapSubtitleLayer`）。
#[repr(C)]
pub struct FfcIndexedLayer {
    pub indices: *const u8,
    pub indices_len: usize,
    /// ARGB。
    pub palette: *const u32,
    pub palette_len: usize,
    pub x: i32,
    pub y: i32,
    pub width: i32,
    pub height: i32,
    pub stride: i32,
    pub source_x: i32,
    pub source_y: i32,
}

/// `composeBitmapSubtitleImage`：把各层合成到 `canvas_w × canvas_h` 的不透明黑底 RGBA
/// 画布上，画布原点在 `(origin_x, origin_y)`。Alpha 按所有层调色板的最大不透明度归一化，
/// 半透明像素按 `round(c * a / maxAlpha)` 预乘到黑底（Dart `double.round`：远离零）。
///
/// # Safety
/// 指针按给定长度可读 / 可写；`layers` 有 `layer_count` 项，各项指针按其长度可读。
#[no_mangle]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn ffc_image_compose_indexed(
    layers: *const FfcIndexedLayer,
    layer_count: usize,
    origin_x: i32,
    origin_y: i32,
    canvas_w: u32,
    canvas_h: u32,
    out: *mut u8,
    out_len: usize,
) -> i32 {
    guard(|| {
        if out.is_null() || (layers.is_null() && layer_count > 0) {
            return status::NULL_ARGUMENT;
        }
        let (w, h) = (canvas_w as i64, canvas_h as i64);
        if w <= 0 || h <= 0 {
            return status::INVALID_ARGUMENT;
        }
        let n = (w * h) as usize;
        if out_len < n * 4 {
            return status::BUFFER_TOO_SMALL;
        }
        let canvas = slice_mut(out, n * 4);
        for p in canvas.chunks_exact_mut(4) {
            p.copy_from_slice(&[0, 0, 0, 255]);
        }
        let layers = slice(layers, layer_count);
        let mut max_alpha = 0u32;
        for l in layers {
            for &argb in slice(l.palette, l.palette_len) {
                max_alpha = max_alpha.max(argb >> 24);
            }
        }
        if max_alpha == 0 {
            return status::OK;
        }
        for l in layers {
            let indices = slice(l.indices, l.indices_len);
            let palette = slice(l.palette, l.palette_len);
            // 每个 alpha 的系数与三通道结果只取决于 (alpha, 通道值)：按调色板项预算一次。
            let mut rgb: Vec<Option<[u8; 3]>> = Vec::with_capacity(palette.len());
            for &argb in palette {
                let a = argb >> 24;
                if a == 0 {
                    rgb.push(None);
                    continue;
                }
                let ch = [(argb >> 16) & 0xFF, (argb >> 8) & 0xFF, argb & 0xFF];
                rgb.push(Some(if a >= max_alpha {
                    [ch[0] as u8, ch[1] as u8, ch[2] as u8]
                } else {
                    let k = a as f64 / max_alpha as f64;
                    ch.map(|c| (c as f64 * k).round() as u8)
                }));
            }
            for y in 0..l.height as i64 {
                let row = (l.source_y as i64 + y) * l.stride as i64 + l.source_x as i64;
                let cy = l.y as i64 + y - origin_y as i64;
                if cy < 0 || cy >= h {
                    continue;
                }
                for x in 0..l.width as i64 {
                    let at = row + x;
                    if at >= indices.len() as i64 {
                        break;
                    }
                    let index = indices[at as usize] as usize;
                    if index >= rgb.len() {
                        continue;
                    }
                    let Some(c) = rgb[index] else {
                        continue;
                    };
                    let cx = l.x as i64 + x - origin_x as i64;
                    if cx < 0 || cx >= w {
                        continue;
                    }
                    let o = ((cy * w + cx) * 4) as usize;
                    canvas[o..o + 3].copy_from_slice(&c);
                }
            }
        }
        status::OK
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn view(data: &[u8], w: u32, h: u32, ch: u32) -> View<'_> {
        View::new(data, (w * ch) as usize, ch, 0, 0, w, h).unwrap()
    }

    #[test]
    fn same_size_resize_is_a_copy() {
        let data: Vec<u8> = (0..36).map(|v| v as u8).collect();
        let mut dst = vec![0u8; 36];
        resize_into(&view(&data, 3, 4, 3), &mut dst, 3, 4, INTERP_LINEAR);
        assert_eq!(dst, data);
    }

    #[test]
    fn nearest_picks_truncated_source_coordinates() {
        // 4x1 → 2x1：取 x = 0, 2。
        let data = [1, 1, 1, 2, 2, 2, 3, 3, 3, 4, 4, 4];
        let mut dst = vec![0u8; 6];
        resize_into(&view(&data, 4, 1, 3), &mut dst, 2, 1, INTERP_NEAREST);
        assert_eq!(dst, [1, 1, 1, 3, 3, 3]);
    }

    #[test]
    fn average_truncates_mean() {
        // 2x1 → 1x1：(1 + 2) / 2 = 1.5 → 1。
        let data = [1, 10, 255, 2, 11, 254];
        let mut dst = vec![0u8; 3];
        resize_into(&view(&data, 2, 1, 3), &mut dst, 1, 1, INTERP_AVERAGE);
        assert_eq!(dst, [1, 10, 254]);
    }

    #[test]
    fn mosaic_averages_touched_blocks_only_inside_regions() {
        // 4x1 RGBA，块 2，区域只盖 x = 1。
        let mut px = vec![0u8, 0, 0, 255, 10, 10, 10, 255, 100, 0, 0, 255, 0, 0, 0, 255];
        mosaic_rgba(&mut px, 4, 1, 2, &[[1, 0, 2, 1]]);
        assert_eq!(&px[0..8], &[0, 0, 0, 255, 5, 5, 5, 255]);
        assert_eq!(&px[8..16], &[100, 0, 0, 255, 0, 0, 0, 255]);
    }

    #[test]
    fn rejects_bad_views() {
        let data = [0u8; 12];
        assert!(View::new(&data, 12, 5, 0, 0, 2, 1).is_err()); // 5 通道
        assert!(View::new(&data, 6, 3, 0, 0, 2, 3).is_err()); // 越界
        assert!(View::new(&data, 6, 3, 0, 0, 2, 2).is_ok());
    }
}
