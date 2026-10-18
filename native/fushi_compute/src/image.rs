//! `ffc_image_*`：图像域（解码 / 缩放 / 归一化成模型输入 / 马赛克 / dHash / DB 后处理 / 位图字幕
//! RLE 与合成 / EPUB 跨页边缘比较 / JPEG 编码）。
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
//! 解码也在本模块（`ffc_image_decode` / `ffc_image_probe`，`image` crate，纯 Rust；见文件后段
//! 「解码 / JPEG 编码」一节）：PNG 等无损格式与旧的 `package:image` 逐字节相同；JPEG 换成
//! zune-jpeg 后与旧解码有差。2026-10-18 实测：真书漫画页 / 截图 / 封面最大差 1（3.5～5% 的通道值），
//! 强色度边缘的 4:2:0 图上 `package:image` 自己偏离 libjpeg 更多（样本上差到 67），zune-jpeg 与
//! libjpeg 最多差 3。下游 OCR / 分镜 / dHash 的变化量见 PR #2330。
//!
//! 这些函数结果都在 f64 / 整数上与旧 Dart 实现逐位一致的前提是**同一份解码像素**；
//! DB 后处理（`ffc_image_db_components`）只回传原始矩，含超越函数的派生量仍在 Dart 算。

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
// 位图字幕：PGS / VobSub RLE 解码、DVB 像素串（测量 / 区域渲染）与黑底合成。逐位复刻
// packages/fushi_engine/lib/media/video/bitmap_subtitle/ 里原先的 Dart 实现。
// ---------------------------------------------------------------------------

/// `decodePgsRle`：PGS RLE → `width × height` 调色板索引平面（调用方已校验尺寸并给好
/// 清零的 [out]）；数据不足时余下像素保持 0。
///
/// # Safety
/// 指针按给定长度可读 / 可写。
#[no_mangle]
pub unsafe extern "C" fn ffc_image_pgs_rle_decode(
    rle: *const u8,
    rle_len: usize,
    width: u32,
    height: u32,
    out: *mut u8,
    out_len: usize,
) -> i32 {
    guard(|| {
        if (rle.is_null() && rle_len > 0) || out.is_null() {
            return status::NULL_ARGUMENT;
        }
        let (w, h) = (width as usize, height as usize);
        if w == 0 || h == 0 {
            return status::INVALID_ARGUMENT;
        }
        if out_len < w * h {
            return status::BUFFER_TOO_SMALL;
        }
        pgs_rle_decode(slice(rle, rle_len), w, h, slice_mut(out, w * h));
        status::OK
    })
}

fn pgs_rle_decode(rle: &[u8], w: usize, h: usize, out: &mut [u8]) {
    let (mut i, mut x, mut y) = (0usize, 0usize, 0usize);
    while i < rle.len() && y < h {
        let mut color = rle[i];
        i += 1;
        let mut run = 1usize;
        if color == 0 {
            if i >= rle.len() {
                break;
            }
            let flag = rle[i];
            i += 1;
            if flag == 0 {
                x = 0;
                y += 1;
                continue;
            }
            run = (flag & 0x3F) as usize;
            if flag & 0x40 != 0 {
                if i >= rle.len() {
                    break;
                }
                run = (run << 8) | rle[i] as usize;
                i += 1;
            }
            if flag & 0x80 != 0 {
                if i >= rle.len() {
                    break;
                }
                color = rle[i];
                i += 1;
            }
        }
        let end = if x + run > w { w } else { x + run };
        if color != 0 && end > x {
            out[y * w + x..y * w + end].fill(color);
        }
        x = end;
    }
}

/// `decodeDvdSubtitleRle`：SPU 两场 2 bit RLE → `width × height` 索引平面（0..3）。
///
/// # Safety
/// 指针按给定长度可读 / 可写；[out] 已清零。
#[no_mangle]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn ffc_image_dvd_rle_decode(
    packet: *const u8,
    packet_len: usize,
    width: u32,
    height: u32,
    top_field_offset: u32,
    bottom_field_offset: u32,
    out: *mut u8,
    out_len: usize,
) -> i32 {
    guard(|| {
        if (packet.is_null() && packet_len > 0) || out.is_null() {
            return status::NULL_ARGUMENT;
        }
        let (w, h) = (width as usize, height as usize);
        if w == 0 || h == 0 {
            return status::INVALID_ARGUMENT;
        }
        if out_len < w * h {
            return status::BUFFER_TOO_SMALL;
        }
        dvd_rle_decode(
            slice(packet, packet_len),
            w,
            h,
            [top_field_offset as usize, bottom_field_offset as usize],
            slice_mut(out, w * h),
        );
        status::OK
    })
}

fn dvd_rle_decode(packet: &[u8], w: usize, h: usize, offsets: [usize; 2], out: &mut [u8]) {
    for (field, &offset) in offsets.iter().enumerate() {
        // `_NibbleReader`：以半字节计位置，越界读 0。
        let mut pos = offset * 2;
        let exhausted = |pos: usize| (pos >> 1) >= packet.len();
        let next = |pos: &mut usize| -> usize {
            let byte = *pos >> 1;
            let v = if byte >= packet.len() {
                0
            } else if (*pos).is_multiple_of(2) {
                (packet[byte] >> 4) as usize
            } else {
                (packet[byte] & 0x0F) as usize
            };
            *pos += 1;
            v
        };
        let mut y = field;
        while y < h {
            let mut x = 0usize;
            while x < w {
                if exhausted(pos) {
                    return;
                }
                let mut v = 0usize;
                let mut t = 1usize;
                while v < t && t <= 0x40 {
                    v = (v << 4) | next(&mut pos);
                    t <<= 2;
                }
                let color = (v & 3) as u8;
                let mut run = if v < 4 { w - x } else { v >> 2 };
                if run > w - x {
                    run = w - x;
                }
                if color != 0 {
                    out[y * w + x..y * w + x + run].fill(color);
                }
                x += run;
            }
            if !pos.is_multiple_of(2) {
                pos += 1;
            }
            y += 2;
        }
    }
}

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

// ---------------------------------------------------------------------------
// 解码 / JPEG 编码。
//
// 解码统一走 `image` crate（纯 Rust：JPEG = zune-jpeg、PNG、GIF、WebP、BMP、TIFF、TGA、ICO、
// PNM）。输出一律是行紧排的 uint8：有 alpha 的 RGBA，否则 RGB（灰度展开成 RGB，16 位截成
// 8 位），多帧格式只取首帧。`orient != 0` 时按 EXIF 方向转正（同 `bakeOrientation`）。
//
// 与旧的 `package:image` 解码相比：PNG 等无损格式逐字节相同；JPEG 的 IDCT / 上采样实现不同，
// 实测 3.5～4.8% 的通道值差 ±1（最大 1），下游影响见 PR 说明。`package:image` 能解而这里不能的：
// PSD、EXR、PVR（漫画 / 截图 / 封面管线里见不到）。
//
// JPEG 编码换成 `jpeg-encoder`（4:4:4、同质量参数），字节与 `encodeJpg` 不同、画质不降。
// ---------------------------------------------------------------------------

/// 解码结果的格式代码（Dart 侧 `FfcImageFormat`）。
pub const FORMAT_JPEG: u32 = 1;
pub const FORMAT_PNG: u32 = 2;
pub const FORMAT_GIF: u32 = 3;
pub const FORMAT_WEBP: u32 = 4;
pub const FORMAT_BMP: u32 = 5;
pub const FORMAT_TIFF: u32 = 6;
pub const FORMAT_TGA: u32 = 7;
pub const FORMAT_ICO: u32 = 8;
pub const FORMAT_PNM: u32 = 9;

fn format_code(f: image::ImageFormat) -> Option<u32> {
    use image::ImageFormat as F;
    Some(match f {
        F::Jpeg => FORMAT_JPEG,
        F::Png => FORMAT_PNG,
        F::Gif => FORMAT_GIF,
        F::WebP => FORMAT_WEBP,
        F::Bmp => FORMAT_BMP,
        F::Tiff => FORMAT_TIFF,
        F::Tga => FORMAT_TGA,
        F::Ico => FORMAT_ICO,
        F::Pnm => FORMAT_PNM,
        _ => return None,
    })
}

struct Decoded {
    pixels: Vec<u8>,
    width: u32,
    height: u32,
    channels: u32,
    format: u32,
}

fn open_decoder(
    data: &[u8],
) -> Result<(impl image::ImageDecoder + '_, u32), i32> {
    // TGA 没有文件头魔数，猜不出格式时按 TGA 试（其头部校验会拒掉别的字节）。
    let format = image::guess_format(data).unwrap_or(image::ImageFormat::Tga);
    let code = format_code(format).ok_or(status::BAD_INPUT)?;
    let reader = image::ImageReader::with_format(std::io::Cursor::new(data), format);
    let decoder = reader.into_decoder().map_err(|_| status::BAD_INPUT)?;
    Ok((decoder, code))
}

fn decode_image(data: &[u8], orient: bool) -> Result<Decoded, i32> {
    use image::ImageDecoder;
    let (mut decoder, format) = open_decoder(data)?;
    let orientation = if orient {
        decoder
            .orientation()
            .unwrap_or(image::metadata::Orientation::NoTransforms)
    } else {
        image::metadata::Orientation::NoTransforms
    };
    let mut img = image::DynamicImage::from_decoder(decoder).map_err(|_| status::BAD_INPUT)?;
    img.apply_orientation(orientation);
    let (width, height) = (img.width(), img.height());
    if width == 0 || height == 0 {
        return Err(status::BAD_INPUT);
    }
    let (pixels, channels) = if img.color().has_alpha() {
        (img.into_rgba8().into_raw(), 4)
    } else {
        (img.into_rgb8().into_raw(), 3)
    };
    Ok(Decoded {
        pixels,
        width,
        height,
        channels,
        format,
    })
}

/// 解码成 uint8 RGB / RGBA（见本节说明），像素经 `out_ptr` / `out_len` 交出（
/// [crate::ffc_free_bytes] 释放），`out_meta` 写 `[width, height, channels, format]`。
/// 认不出 / 解不开返回 [status::BAD_INPUT]。
///
/// # Safety
/// 指针按给定长度可读 / 可写；`out_meta` 可写 4 个 u32。
#[no_mangle]
pub unsafe extern "C" fn ffc_image_decode(
    data: *const u8,
    len: usize,
    orient: i32,
    out_ptr: *mut *mut u8,
    out_len: *mut usize,
    out_meta: *mut u32,
) -> i32 {
    guard(|| {
        if data.is_null() || out_ptr.is_null() || out_len.is_null() || out_meta.is_null() {
            return status::NULL_ARGUMENT;
        }
        match decode_image(slice(data, len), orient != 0) {
            Ok(d) => {
                let meta = slice_mut(out_meta, 4);
                meta.copy_from_slice(&[d.width, d.height, d.channels, d.format]);
                crate::hand_over_bytes(d.pixels, out_ptr, out_len);
                status::OK
            }
            Err(code) => code,
        }
    })
}

/// 只读头：宽高（`orient != 0` 时按 EXIF 方向换算，5～8 宽高互换）与格式，写
/// `out_meta = [width, height, format]`。认不出返回 [status::BAD_INPUT]。
///
/// # Safety
/// 指针按给定长度可读；`out_meta` 可写 3 个 u32。
#[no_mangle]
pub unsafe extern "C" fn ffc_image_probe(
    data: *const u8,
    len: usize,
    orient: i32,
    out_meta: *mut u32,
) -> i32 {
    guard(|| {
        use image::ImageDecoder;
        if data.is_null() || out_meta.is_null() {
            return status::NULL_ARGUMENT;
        }
        let (mut decoder, format) = match open_decoder(slice(data, len)) {
            Ok(v) => v,
            Err(code) => return code,
        };
        let (mut w, mut h) = decoder.dimensions();
        if orient != 0 {
            use image::metadata::Orientation as O;
            if matches!(
                decoder.orientation(),
                Ok(O::Rotate90 | O::Rotate270 | O::Rotate90FlipH | O::Rotate270FlipH)
            ) {
                std::mem::swap(&mut w, &mut h);
            }
        }
        if w == 0 || h == 0 {
            return status::BAD_INPUT;
        }
        slice_mut(out_meta, 3).copy_from_slice(&[w, h, format]);
        status::OK
    })
}

/// 解码（转正 EXIF 方向）后编码成 JPEG（4:4:4，`quality` 1..=100，忽略 alpha，同
/// `encodeJpg` 的通道取法），经 `out_ptr` / `out_len` 交出。解不开返回 [status::BAD_INPUT]。
///
/// # Safety
/// 指针按给定长度可读 / 可写。
#[no_mangle]
pub unsafe extern "C" fn ffc_image_to_jpeg(
    data: *const u8,
    len: usize,
    quality: u32,
    out_ptr: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    guard(|| {
        if data.is_null() || out_ptr.is_null() || out_len.is_null() {
            return status::NULL_ARGUMENT;
        }
        if !(1..=100).contains(&quality) {
            return status::INVALID_ARGUMENT;
        }
        let d = match decode_image(slice(data, len), true) {
            Ok(v) => v,
            Err(code) => return code,
        };
        if d.width > u16::MAX as u32 || d.height > u16::MAX as u32 {
            return status::INVALID_ARGUMENT;
        }
        let color = if d.channels == 4 {
            jpeg_encoder::ColorType::Rgba
        } else {
            jpeg_encoder::ColorType::Rgb
        };
        let mut jpeg = Vec::new();
        let mut enc = jpeg_encoder::Encoder::new(&mut jpeg, quality as u8);
        enc.set_sampling_factor(jpeg_encoder::SamplingFactor::F_1_1);
        if enc
            .encode(&d.pixels, d.width as u16, d.height as u16, color)
            .is_err()
        {
            return status::BAD_INPUT;
        }
        crate::hand_over_bytes(jpeg, out_ptr, out_len);
        status::OK
    })
}

/// `EpubEdgeMatcher.compareEdges`：两张图各自解码（转正）、最近邻缩到高 [sample_height]
/// （宽按比例四舍五入，同 `copyResize(height:)`），比较左图右缘与右图左缘各 [strip_width]
/// 列的 RGB 差，写 `out = 1 - 平均差`（0..1；没有可比像素时写 0）。任一张解不开返回
/// [status::BAD_INPUT]。
///
/// # Safety
/// 指针按给定长度可读；`out` 可写一个 f64。
#[no_mangle]
pub unsafe extern "C" fn ffc_image_edge_similarity(
    left: *const u8,
    left_len: usize,
    right: *const u8,
    right_len: usize,
    strip_width: u32,
    sample_height: u32,
    out: *mut f64,
) -> i32 {
    guard(|| {
        if left.is_null() || right.is_null() || out.is_null() {
            return status::NULL_ARGUMENT;
        }
        if sample_height == 0 {
            return status::INVALID_ARGUMENT;
        }
        let l = match decode_image(slice(left, left_len), true) {
            Ok(v) => v,
            Err(code) => return code,
        };
        let r = match decode_image(slice(right, right_len), true) {
            Ok(v) => v,
            Err(code) => return code,
        };
        let sh = sample_height as usize;
        let shrink = |d: &Decoded| -> Vec<u8> {
            // copyResize(height: h)：width = round(h * (src.width / src.height))。
            let w = (sh as f64 * (d.width as f64 / d.height as f64)).round() as usize;
            if w == 0 {
                return Vec::new();
            }
            let v = View::new(
                &d.pixels,
                d.width as usize * d.channels as usize,
                d.channels,
                0,
                0,
                d.width,
                d.height,
            )
            .expect("decoded image view");
            let mut dst = vec![0u8; w * sh * d.channels as usize];
            resize_into(&v, &mut dst, w, sh, INTERP_NEAREST);
            dst
        };
        let (lp, rp) = (shrink(&l), shrink(&r));
        let lw = lp.len() / (sh * l.channels as usize);
        let rw = rp.len() / (sh * r.channels as usize);
        let (lc, rc) = (l.channels as usize, r.channels as usize);
        let mut total = 0f64;
        let mut count = 0usize;
        for y in 0..sh {
            for dx in 0..strip_width as usize {
                if lw < 1 + dx || dx >= rw {
                    continue;
                }
                let lx = lw - 1 - dx;
                let a = &lp[(y * lw + lx) * lc..(y * lw + lx) * lc + 3];
                let b = &rp[(y * rw + dx) * rc..(y * rw + dx) * rc + 3];
                let dr = (a[0] as i32 - b[0] as i32).abs() as f64;
                let dg = (a[1] as i32 - b[1] as i32).abs() as f64;
                let db = (a[2] as i32 - b[2] as i32).abs() as f64;
                total += (dr + dg + db) / (3.0 * 255.0);
                count += 1;
            }
        }
        *out = if count == 0 { 0.0 } else { 1.0 - total / count as f64 };
        status::OK
    })
}

// ---------------------------------------------------------------------------
// PP-OCR DB 后处理的洪泛（`ppDetPostprocess`）。按与旧 Dart 实现相同的栈序洪泛，各域的浮点
// 累加顺序因此相同；主轴角等含超越函数的派生量不在这里算，只回传原始矩，由 Dart 同一段代码
// 求（避免两边 libm 末位差）。
// ---------------------------------------------------------------------------

/// DB 连通域每条记录的 f64 个数：
/// `[minX, minY, maxX, maxY, count, sum, mx, my, mxx, myy, mxy]`。
pub const DB_RECORD_FIELDS: usize = 11;

/// 概率图 [prob]（`width × height` 行主序）按 `> thresh` 4 连通分域，滤掉均值
/// `< box_thresh` 或外接矩形宽 / 高 `< 2` 的域，其余每域一条 [DB_RECORD_FIELDS] 个 f64 的
/// 记录（扫描序），经 `out_ptr` / `out_len`（字节数）交出，用 [crate::ffc_free_bytes] 释放。
///
/// # Safety
/// 指针按给定长度可读；`out_ptr` / `out_len` 可写。
#[no_mangle]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn ffc_image_db_components(
    prob: *const f32,
    len: usize,
    width: u32,
    height: u32,
    thresh: f64,
    box_thresh: f64,
    out_ptr: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    guard(|| {
        if prob.is_null() || out_ptr.is_null() || out_len.is_null() {
            return status::NULL_ARGUMENT;
        }
        let (w, h) = (width as usize, height as usize);
        if w == 0 || h == 0 || len != w * h {
            return status::INVALID_ARGUMENT;
        }
        let records = db_components(slice(prob, len), w, h, thresh, box_thresh);
        let mut bytes = Vec::with_capacity(records.len() * 8);
        for v in records {
            bytes.extend_from_slice(&v.to_ne_bytes());
        }
        crate::hand_over_bytes(bytes, out_ptr, out_len);
        status::OK
    })
}

fn db_components(prob: &[f32], w: usize, h: usize, thresh: f64, box_thresh: f64) -> Vec<f64> {
    let n = w * h;
    // Dart 版用 Int32List 打域号；这里只需要「是否已访问」，栈序不变。
    let mut seen = vec![false; n];
    let mut stack: Vec<u32> = Vec::with_capacity(1024);
    let mut out = Vec::new();
    let above = |q: usize| prob[q] as f64 > thresh;
    for start in 0..n {
        if seen[start] || !above(start) {
            continue;
        }
        seen[start] = true;
        stack.push(start as u32);
        let (mut min_x, mut min_y, mut max_x, mut max_y) = (w as i64, h as i64, -1i64, -1i64);
        let mut sum = 0f64;
        let mut count = 0i64;
        let ox = (start % w) as i64;
        let oy = (start / w) as i64;
        let (mut mx, mut my, mut mxx, mut myy, mut mxy) = (0f64, 0f64, 0f64, 0f64, 0f64);
        while let Some(p) = stack.pop() {
            let p = p as usize;
            let px = (p % w) as i64;
            let py = (p / w) as i64;
            sum += prob[p] as f64;
            count += 1;
            let rx = (px - ox) as f64;
            let ry = (py - oy) as f64;
            mx += rx;
            my += ry;
            mxx += rx * rx;
            myy += ry * ry;
            mxy += rx * ry;
            min_x = min_x.min(px);
            max_x = max_x.max(px);
            min_y = min_y.min(py);
            max_y = max_y.max(py);
            // 压栈顺序与 Dart 相同：左、右、上、下。
            let mut push = |q: usize| {
                if !seen[q] && above(q) {
                    seen[q] = true;
                    stack.push(q as u32);
                }
            };
            if px > 0 {
                push(p - 1);
            }
            if px < w as i64 - 1 {
                push(p + 1);
            }
            if py > 0 {
                push(p - w);
            }
            if py < h as i64 - 1 {
                push(p + w);
            }
        }
        let score = sum / count as f64;
        if score < box_thresh {
            continue;
        }
        let bw = (max_x - min_x + 1) as f64;
        let bh = (max_y - min_y + 1) as f64;
        if bw < 2.0 || bh < 2.0 {
            continue;
        }
        out.extend_from_slice(&[
            min_x as f64,
            min_y as f64,
            max_x as f64,
            max_y as f64,
            count as f64,
            sum,
            mx,
            my,
            mxx,
            myy,
            mxy,
        ]);
    }
    out
}

// ---------------------------------------------------------------------------
// 封面比对特征（`fushi_engine/lib/leaderboard/cover_compare.dart`）。
// ---------------------------------------------------------------------------

/// 比对网格边长（`kCoverCompareGrid`）。
const COVER_GRID: usize = 32;

/// `coverSignatureOfImage`：按面积平均缩成 32×32 灰度（BT.601，0–1），空格子取同行左侧
/// 最近的非空格。逐像素累加顺序与旧 Dart 循环相同（行主序）。
fn cover_grid(v: &View) -> [f64; COVER_GRID * COVER_GRID] {
    const N: usize = COVER_GRID;
    let mut sum = [0f64; N * N];
    let mut count = [0i32; N * N];
    for y in 0..v.h {
        let row = (y * N / v.h) * N;
        for x in 0..v.w {
            let cell = row + x * N / v.w;
            let p = v.rgba(x, y);
            sum[cell] += 0.299 * (p[0] as f64 / 255.0)
                + 0.587 * (p[1] as f64 / 255.0)
                + 0.114 * (p[2] as f64 / 255.0);
            count[cell] += 1;
        }
    }
    let mut grid = [0f64; N * N];
    for y in 0..N {
        let mut last = 0.0;
        for x in 0..N {
            let i = y * N + x;
            if count[i] > 0 {
                last = sum[i] / count[i] as f64;
            }
            grid[i] = last;
        }
    }
    grid
}

/// 解码（按 EXIF 转正）并算封面比对特征，写进 `out_grid`（32×32 个 f64，行优先）。解不开或
/// 宽高为 0 返回 [status::BAD_INPUT]。
///
/// # Safety
/// 指针按给定长度可读；`out_grid` 可写 1024 个 f64。
#[no_mangle]
pub unsafe extern "C" fn ffc_image_cover_signature(
    data: *const u8,
    len: usize,
    out_grid: *mut f64,
) -> i32 {
    guard(|| {
        if data.is_null() || out_grid.is_null() {
            return status::NULL_ARGUMENT;
        }
        let d = match decode_image(slice(data, len), true) {
            Ok(d) => d,
            Err(code) => return code,
        };
        let stride = d.width as usize * d.channels as usize;
        let view = match View::new(&d.pixels, stride, d.channels, 0, 0, d.width, d.height) {
            Ok(v) => v,
            Err(code) => return code,
        };
        slice_mut(out_grid, COVER_GRID * COVER_GRID).copy_from_slice(&cover_grid(&view));
        status::OK
    })
}

/// `_detail`：减去 9×8 粗格（dHash 的格子划分）均值后的残差。
fn cover_detail(g: &[f64]) -> Vec<f64> {
    const N: usize = COVER_GRID;
    let mut sum = [0f64; 72];
    let mut count = [0i32; 72];
    let cell_of = |x: usize, y: usize| (y * 8 / N) * 9 + x * 9 / N;
    for y in 0..N {
        for x in 0..N {
            let c = cell_of(x, y);
            sum[c] += g[y * N + x];
            count[c] += 1;
        }
    }
    let mut out = vec![0f64; N * N];
    for y in 0..N {
        for x in 0..N {
            let c = cell_of(x, y);
            out[y * N + x] = g[y * N + x] - sum[c] / count[c] as f64;
        }
    }
    out
}

/// `_ncc`：归一化互相关；两边都平坦时按均值是否接近给 1 / 0，只有一边平坦给 0。
fn cover_ncc(a: &[f64], b: &[f64]) -> f64 {
    const FLAT_VARIANCE: f64 = 1e-6;
    let mut ma = 0.0;
    let mut mb = 0.0;
    for i in 0..a.len() {
        ma += a[i];
        mb += b[i];
    }
    ma /= a.len() as f64;
    mb /= b.len() as f64;
    let (mut sab, mut saa, mut sbb) = (0.0, 0.0, 0.0);
    for i in 0..a.len() {
        let da = a[i] - ma;
        let db = b[i] - mb;
        sab += da * db;
        saa += da * da;
        sbb += db * db;
    }
    let flat_a = saa / (a.len() as f64) < FLAT_VARIANCE;
    let flat_b = sbb / (b.len() as f64) < FLAT_VARIANCE;
    if flat_a && flat_b {
        return if (ma - mb).abs() < 0.05 { 1.0 } else { 0.0 };
    }
    if flat_a || flat_b {
        return 0.0;
    }
    sab / (saa * sbb).sqrt()
}

/// `compareCoverSignatures`：两份 32×32 特征的整体 NCC 与细节 NCC，写 `out = [ncc, detail]`。
///
/// # Safety
/// `a` / `b` 可读 1024 个 f64；`out` 可写 2 个 f64。
#[no_mangle]
pub unsafe extern "C" fn ffc_image_cover_compare(
    a: *const f64,
    b: *const f64,
    out: *mut f64,
) -> i32 {
    guard(|| {
        if a.is_null() || b.is_null() || out.is_null() {
            return status::NULL_ARGUMENT;
        }
        let a = slice(a, COVER_GRID * COVER_GRID);
        let b = slice(b, COVER_GRID * COVER_GRID);
        let out = slice_mut(out, 2);
        out[0] = cover_ncc(a, b);
        out[1] = cover_ncc(&cover_detail(a), &cover_detail(b));
        status::OK
    })
}

// ---------------------------------------------------------------------------
// 交给大模型的文字块裁图（`fushi_engine/lib/ocr/manga_ai_ocr_refiner.dart`
// `cropMangaAiOcrBlocks`）：外扩、长边超限均值缩小 / 短边不足立方放大，编成 PNG。
// ---------------------------------------------------------------------------

/// `getPixelCubic` 里的一维三次插值（`package:image` 的写法）。第一层的四个输入是整数通道值，
/// Dart 在 int 上算的中间式在这里以整值 f64 计算，结果相同（量级远小于 2^53）。
#[inline(always)]
fn cubic(dx: f64, ipp: f64, icp: f64, inp: f64, iap: f64) -> f64 {
    icp + 0.5
        * (dx * (-ipp + inp)
            + dx * dx * (2.0 * ipp - 5.0 * icp + 4.0 * inp - iap)
            + dx * dx * dx * (-ipp + 3.0 * icp - 3.0 * inp + iap))
}

/// `copyResize(src, width: dw, height: dh, interpolation: cubic)`：逐位复刻
/// `Image.getPixelCubic`，包括它对越界邻点的取法（上一行 / 左一列越界时有的取中心像素、
/// 有的取 `Pixel.undefined` 即全 0）与 `getColor` 的「先截断再夹进 [0, 255]」。
fn resize_cubic(src: &View, dw: usize, dh: usize) -> Vec<u8> {
    let ch = src.ch;
    let mut dst = vec![0u8; dw * dh * ch];
    let (w, h) = (src.w as i64, src.h as i64);
    let dx_step = src.w as f64 / dw as f64;
    let dy_step = src.h as f64 / dh as f64;
    let s = |xx: i64, yy: i64| {
        let p = src.rgba_safe(xx, yy);
        [p[0] as f64, p[1] as f64, p[2] as f64, p[3] as f64]
    };
    for y in 0..dh {
        let fy = y as f64 * dy_step;
        let yi = fy as i64; // fy >= 0
        let (py, ny, ay) = (yi - 1, yi + 1, yi + 2);
        let dy = fy - yi as f64;
        for x in 0..dw {
            let fx = x as f64 * dx_step;
            let xi = fx as i64;
            let (px, nx, ax) = (xi - 1, xi + 1, xi + 2);
            let dx = fx - xi as f64;
            let icc = s(xi, yi);
            let ipp = if px < 0 || py < 0 { icc } else { s(px, py) };
            let icp = if px < 0 { icc } else { s(xi, py) };
            let inp = if py < 0 || nx >= w { icc } else { s(nx, py) };
            let iap = if ax >= w || py < 0 { icc } else { s(ax, py) };
            let ipc = if px < 0 { icc } else { s(px, yi) };
            let inc = if nx >= w { icc } else { s(nx, yi) };
            let iac = if ax >= w { icc } else { s(ax, yi) };
            let ipn = if px < 0 || ny >= h { icc } else { s(px, ny) };
            let icn = if ny >= h { icc } else { s(xi, ny) };
            let inn = if nx >= w || ny >= h { icc } else { s(nx, ny) };
            let ian = if ax >= w || ny >= h { icc } else { s(ax, ny) };
            let ipa = if px < 0 || ay >= h { icc } else { s(px, ay) };
            let ica = if ay >= h { icc } else { s(xi, ay) };
            let ina = if nx >= w || ay >= h { icc } else { s(nx, ay) };
            let iaa = if ax >= w || ay >= h { icc } else { s(ax, ay) };
            let o = (y * dw + x) * ch;
            for c in 0..ch {
                let ip = cubic(dx, ipp[c], icp[c], inp[c], iap[c]);
                let ic = cubic(dx, ipc[c], icc[c], inc[c], iac[c]);
                let in_ = cubic(dx, ipn[c], icn[c], inn[c], ian[c]);
                let ia = cubic(dx, ipa[c], ica[c], ina[c], iaa[c]);
                let v = cubic(dy, ip, ic, in_, ia) as i64; // toInt：截断
                dst[o + c] = v.clamp(0, 255) as u8;
            }
        }
    }
    dst
}

fn encode_png(pixels: &[u8], w: u32, h: u32, ch: usize) -> Result<Vec<u8>, i32> {
    use image::ImageEncoder;
    let color = if ch == 4 {
        image::ExtendedColorType::Rgba8
    } else {
        image::ExtendedColorType::Rgb8
    };
    let mut out = Vec::new();
    image::codecs::png::PngEncoder::new(&mut out)
        .write_image(pixels, w, h, color)
        .map_err(|_| status::BAD_INPUT)?;
    Ok(out)
}

fn copy_view(v: &View) -> Vec<u8> {
    let mut out = Vec::with_capacity(v.w * v.h * v.ch);
    for y in 0..v.h {
        let o = v.offset(0, y);
        out.extend_from_slice(&v.data[o..o + v.w * v.ch]);
    }
    out
}

/// 一块的裁图；框落在图外 / 退化返回 `Ok(None)`，坐标非有限返回 [status::INVALID_ARGUMENT]
/// （旧实现在 `floor()` / `ceil()` 上抛 `UnsupportedError`）。
#[allow(clippy::too_many_arguments)]
fn ai_crop_one(
    page: &View,
    b: &[f64],
    sx: f64,
    sy: f64,
    padding: i64,
    max_side: i64,
    min_side: i64,
) -> Result<Option<Vec<u8>>, i32> {
    let edges = [b[0] * sx, b[1] * sy, b[2] * sx, b[3] * sy];
    if edges.iter().any(|v| !v.is_finite()) {
        return Err(status::INVALID_ARGUMENT);
    }
    let (pw, ph) = (page.w as i64, page.h as i64);
    let left = 0i64.max((edges[0].floor() as i64).wrapping_sub(padding));
    let top = 0i64.max((edges[1].floor() as i64).wrapping_sub(padding));
    let right = pw.min((edges[2].ceil() as i64).wrapping_add(padding));
    let bottom = ph.min((edges[3].ceil() as i64).wrapping_add(padding));
    if right.wrapping_sub(left) < 2 || bottom.wrapping_sub(top) < 2 {
        return Ok(None);
    }
    let (cw, chh) = ((right - left) as usize, (bottom - top) as usize);
    let crop = View {
        data: page.data,
        stride: page.stride,
        ch: page.ch,
        x0: page.x0 + left as usize,
        y0: page.y0 + top as usize,
        w: cw,
        h: chh,
    };
    let short = cw.min(chh) as i64;
    let long = cw.max(chh) as i64;
    let (pixels, ow, oh) = if long > max_side {
        let scale = max_side as f64 / long as f64;
        let ow = 1i64.max(crate::dart::round(cw as f64 * scale)) as usize;
        let oh = 1i64.max(crate::dart::round(chh as f64 * scale)) as usize;
        let mut dst = vec![0u8; ow * oh * crop.ch];
        resize_into(&crop, &mut dst, ow, oh, INTERP_AVERAGE);
        (dst, ow, oh)
    } else if short < min_side {
        let up = (min_side as f64 / 1i64.max(short) as f64).ceil() as i64;
        let factor = up.min(1i64.max(max_side / long));
        if factor > 1 {
            let (ow, oh) = (cw * factor as usize, chh * factor as usize);
            (resize_cubic(&crop, ow, oh), ow, oh)
        } else {
            (copy_view(&crop), cw, chh)
        }
    } else {
        (copy_view(&crop), cw, chh)
    };
    encode_png(&pixels, ow as u32, oh as u32, crop.ch).map(Some)
}

/// 解码整页（按 EXIF 转正）并裁出每个框（[boxes] 每条 4 个 f64：ltrb，坐标系为
/// `page_w × page_h`；`<= 0` 时按解码尺寸），各编码成 PNG。结果序列化成每块
/// `[u32 len][len 字节]`（本机字节序），`len == u32::MAX` 表示该块裁不出（null），经
/// `out_ptr` / `out_len` 交出（[crate::ffc_free_bytes] 释放）。整页解不开返回
/// [status::BAD_INPUT]；某个框坐标换算后非有限返回 [status::INVALID_ARGUMENT]。
///
/// # Safety
/// 指针按给定长度可读 / 可写。
#[no_mangle]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn ffc_image_ai_crops(
    data: *const u8,
    len: usize,
    page_w: f64,
    page_h: f64,
    boxes: *const f64,
    box_count: usize,
    padding: i32,
    max_side: i32,
    min_side: i32,
    out_ptr: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    guard(|| {
        if data.is_null() || out_ptr.is_null() || out_len.is_null() {
            return status::NULL_ARGUMENT;
        }
        if box_count > 0 && boxes.is_null() {
            return status::NULL_ARGUMENT;
        }
        if max_side <= 0 || min_side <= 0 {
            return status::INVALID_ARGUMENT;
        }
        let d = match decode_image(slice(data, len), true) {
            Ok(d) => d,
            Err(code) => return code,
        };
        let stride = d.width as usize * d.channels as usize;
        let page = match View::new(&d.pixels, stride, d.channels, 0, 0, d.width, d.height) {
            Ok(v) => v,
            Err(code) => return code,
        };
        let sx = if page_w > 0.0 {
            d.width as f64 / page_w
        } else {
            1.0
        };
        let sy = if page_h > 0.0 {
            d.height as f64 / page_h
        } else {
            1.0
        };
        let boxes = slice(boxes, box_count * 4);
        let mut out = Vec::new();
        for b in boxes.chunks_exact(4) {
            match ai_crop_one(
                &page,
                b,
                sx,
                sy,
                padding as i64,
                max_side as i64,
                min_side as i64,
            ) {
                Ok(Some(png)) => {
                    out.extend_from_slice(&(png.len() as u32).to_ne_bytes());
                    out.extend_from_slice(&png);
                }
                Ok(None) => out.extend_from_slice(&u32::MAX.to_ne_bytes()),
                Err(code) => return code,
            }
        }
        crate::hand_over_bytes(out, out_ptr, out_len);
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
