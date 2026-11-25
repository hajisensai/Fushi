//! 高质量可分离重采样：Lanczos3 / Catmull-Rom / 面积平均，可选在线性光里算（Gamma 校正缩放）。
//!
//! 给漫画页图「按显示尺寸缩放」用（`ffc_image_fit_jpeg_hq`）。为什么不用 [super::resize_into]：
//! 那里的 `INTERP_AVERAGE` 是在 sRGB 编码值上做盒式平均，`INTERP_LINEAR` 缩小时不放宽核
//! （会混叠出网点摩尔纹）。这里：
//!
//! - **核按缩放比放宽**（缩小时支撑区 = 半径 / 比例），网点这类高频纹理被正确低通，不出摩尔纹；
//! - **线性光**（`linear = true`）：先把 sRGB 解码成线性光再加权平均，最后编回 sRGB。在 sRGB
//!   编码值上平均会把黑白相间的网点算暗（0 与 255 平均成 128，物理上应是约 188），整片网点
//!   缩小后发灰发闷；线性光里平均保住网点的明度。
//! - 负瓣带来的过冲夹回 [0, 1]。
//!
//! 只处理不透明的 1 / 3 通道 uint8（调用方已合掉 alpha）。

/// 重采样核。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Filter {
    /// 面积平均（盒式核，按比例放宽）。
    Box,
    /// Lanczos 窗口 sinc，a = 3。
    Lanczos3,
    /// Catmull-Rom 三次（Keys a = -0.5），半径 2。
    CatmullRom,
}

impl Filter {
    pub(crate) fn from_code(code: u32) -> Option<Self> {
        match code {
            0 => Some(Self::Box),
            1 => Some(Self::Lanczos3),
            2 => Some(Self::CatmullRom),
            _ => None,
        }
    }

    fn support(self) -> f64 {
        match self {
            Self::Box => 0.5,
            Self::Lanczos3 => 3.0,
            Self::CatmullRom => 2.0,
        }
    }

    fn weight(self, x: f64) -> f64 {
        let x = x.abs();
        match self {
            Self::Box => {
                if x < 0.5 {
                    1.0
                } else if x == 0.5 {
                    0.5
                } else {
                    0.0
                }
            }
            Self::Lanczos3 => {
                if x < 1e-8 {
                    1.0
                } else if x < 3.0 {
                    let px = std::f64::consts::PI * x;
                    3.0 * px.sin() * (px / 3.0).sin() / (px * px)
                } else {
                    0.0
                }
            }
            Self::CatmullRom => {
                if x < 1.0 {
                    1.5 * x * x * x - 2.5 * x * x + 1.0
                } else if x < 2.0 {
                    -0.5 * x * x * x + 2.5 * x * x - 4.0 * x + 2.0
                } else {
                    0.0
                }
            }
        }
    }
}

/// 一个输出坐标的权重：从源下标 `start` 起的连续若干个。
struct Taps {
    start: usize,
    weights: Vec<f32>,
}

/// 一维的全部输出位置的权重表（Pillow `precompute_coeffs` 同口径：像素中心对齐、缩小时
/// 核按 1 / 比例放宽、权重归一化）。
fn coefficients(src: usize, dst: usize, filter: Filter) -> Vec<Taps> {
    let scale = src as f64 / dst as f64;
    let filter_scale = scale.max(1.0);
    let support = filter.support() * filter_scale;
    (0..dst)
        .map(|i| {
            let center = (i as f64 + 0.5) * scale;
            let lo = ((center - support).floor().max(0.0)) as usize;
            let hi = ((center + support).ceil() as usize).min(src);
            let mut weights: Vec<f64> = (lo..hi)
                .map(|j| filter.weight((j as f64 + 0.5 - center) / filter_scale))
                .collect();
            let sum: f64 = weights.iter().sum();
            if sum.abs() > 1e-12 {
                for w in &mut weights {
                    *w /= sum;
                }
            } else {
                // 极端缩放下核落空：退回最近邻，避免整行全黑。
                let nearest = (center.floor() as usize).min(src - 1);
                return Taps {
                    start: nearest,
                    weights: vec![1.0],
                };
            }
            Taps {
                start: lo,
                weights: weights.into_iter().map(|w| w as f32).collect(),
            }
        })
        .collect()
}

fn srgb_to_linear(c: f32) -> f32 {
    if c <= 0.04045 {
        c / 12.92
    } else {
        ((c + 0.055) / 1.055).powf(2.4)
    }
}

fn linear_to_srgb(l: f32) -> f32 {
    if l <= 0.003_130_8 {
        l * 12.92
    } else {
        1.055 * l.powf(1.0 / 2.4) - 0.055
    }
}

/// 线性光 → sRGB 的查表精度（2^16 档；近黑处 1/255 sRGB 约等于 3e-4 线性，表步长 1.5e-5）。
const ENCODE_LUT_BITS: u32 = 16;

/// 逐行出图的可分离重采样器。
///
/// **工作集只有几行**：纵向第 `y` 行只用到源图 `[start, start + len)` 这几行的横向结果，所以横向结果
/// 放在一个按源行号取模的环形缓存里（容量 = 纵向最长的核），用到哪行算哪行；不为整张图留
/// `h × dw × ch` 的 f32 中间缓冲（1600×12000 RGB 缩到 1024×7680 时那块就是 147 MiB，HBK-AUDIT-044）。
/// 纵向起点随 `y` 单调不减，每个源行只横向算一次；算术与整张两遍的做法逐位相同。
struct RowResampler<'a> {
    src: &'a [u8],
    w: usize,
    ch: usize,
    row_len: usize,
    hx: Vec<Taps>,
    vy: Vec<Taps>,
    decode: [f32; 256],
    encode: Vec<u8>,
    /// 环形缓存：`cap` 行横向结果，槽 `r % cap` 存源行 `r`。
    ring: Vec<f32>,
    /// 各槽当前存的源行（`usize::MAX` = 空）。
    held: Vec<usize>,
    acc: Vec<f32>,
}

impl<'a> RowResampler<'a> {
    #[allow(clippy::too_many_arguments)]
    fn new(
        src: &'a [u8],
        w: usize,
        h: usize,
        ch: usize,
        dw: usize,
        dh: usize,
        filter: Filter,
        linear: bool,
    ) -> Self {
        debug_assert!(ch == 1 || ch == 3);
        debug_assert_eq!(src.len(), w * h * ch);
        let mut decode = [0f32; 256];
        for (v, d) in decode.iter_mut().enumerate() {
            let c = v as f32 / 255.0;
            *d = if linear { srgb_to_linear(c) } else { c };
        }
        let lut_len = 1usize << ENCODE_LUT_BITS;
        let encode: Vec<u8> = (0..lut_len)
            .map(|i| {
                let v = i as f32 / (lut_len - 1) as f32;
                let s = if linear { linear_to_srgb(v) } else { v };
                (s * 255.0 + 0.5).clamp(0.0, 255.0) as u8
            })
            .collect();
        let hx = coefficients(w, dw, filter);
        let vy = coefficients(h, dh, filter);
        let cap = vy.iter().map(|t| t.weights.len()).max().unwrap_or(1).max(1);
        let row_len = dw * ch;
        Self {
            src,
            w,
            ch,
            row_len,
            hx,
            vy,
            decode,
            encode,
            ring: vec![0f32; cap * row_len],
            held: vec![usize::MAX; cap],
            acc: vec![0f32; row_len],
        }
    }

    /// 保证源行 `r` 的横向结果在环里，返回它所在的槽。
    fn ensure(&mut self, r: usize) -> usize {
        let slot = r % self.held.len();
        if self.held[slot] != r {
            let (w, ch, row_len) = (self.w, self.ch, self.row_len);
            let row = &self.src[r * w * ch..(r + 1) * w * ch];
            let out = &mut self.ring[slot * row_len..(slot + 1) * row_len];
            for (x, taps) in self.hx.iter().enumerate() {
                for c in 0..ch {
                    let mut acc = 0f32;
                    for (k, wt) in taps.weights.iter().enumerate() {
                        acc += wt * self.decode[row[(taps.start + k) * ch + c] as usize];
                    }
                    out[x * ch + c] = acc;
                }
            }
            self.held[slot] = r;
        }
        slot
    }

    /// 输出第 `y` 行（`dw × ch` 个 uint8）写进 `out`。
    fn row(&mut self, y: usize, out: &mut [u8]) {
        let (start, n) = (self.vy[y].start, self.vy[y].weights.len());
        // 本行要的源行一次备齐（容量 >= 最长的核，取模后互不覆盖）。
        for r in start..start + n {
            self.ensure(r);
        }
        let row_len = self.row_len;
        let cap = self.held.len();
        self.acc.iter_mut().for_each(|v| *v = 0.0);
        for (k, wt) in self.vy[y].weights.iter().enumerate() {
            let slot = (start + k) % cap;
            let line = &self.ring[slot * row_len..(slot + 1) * row_len];
            for (a, v) in self.acc.iter_mut().zip(line) {
                *a += wt * v;
            }
        }
        let scale = (self.encode.len() - 1) as f32;
        for (o, a) in out.iter_mut().zip(&self.acc) {
            let idx = (a.clamp(0.0, 1.0) * scale + 0.5) as usize;
            *o = self.encode[idx];
        }
    }
}

/// `src`（`w × h × ch`，行紧排）缩放到 `dw × dh`。`ch` 只能是 1 或 3。工作集 = 输出 + 几行
/// （[RowResampler]）。
#[allow(clippy::too_many_arguments)]
pub(crate) fn resample(
    src: &[u8],
    w: usize,
    h: usize,
    ch: usize,
    dw: usize,
    dh: usize,
    filter: Filter,
    linear: bool,
) -> Vec<u8> {
    let mut rows = RowResampler::new(src, w, h, ch, dw, dh, filter, linear);
    let row_len = dw * ch;
    let mut dst = vec![0u8; dh * row_len];
    for (y, out) in dst.chunks_exact_mut(row_len.max(1)).enumerate().take(dh) {
        rows.row(y, out);
    }
    dst
}

/// 文字框在目标分辨率上的像素矩形（外扩 [MASK_GROW] 后夹到画内；退化框 / 非有限值丢掉）。
fn mask_rects(boxes: &[[f32; 4]], dw: usize, dh: usize) -> Vec<[usize; 4]> {
    boxes
        .iter()
        .filter(|b| b.iter().all(|v| v.is_finite()) && b[2] > b[0] && b[3] > b[1])
        .filter_map(|b| {
            let x0 = ((b[0] * dw as f32).floor() - MASK_GROW).clamp(0.0, dw as f32) as usize;
            let y0 = ((b[1] * dh as f32).floor() - MASK_GROW).clamp(0.0, dh as f32) as usize;
            let x1 = ((b[2] * dw as f32).ceil() + MASK_GROW).clamp(0.0, dw as f32) as usize;
            let y1 = ((b[3] * dh as f32).ceil() + MASK_GROW).clamp(0.0, dh as f32) as usize;
            (x1 > x0 && y1 > y0).then_some([x0, y0, x1, y1])
        })
        .collect()
}

/// 逐行出文字保护遮罩（[text_mask] 的流式版本，逐位相同）：框内置 1、sigma = [MASK_SIGMA] 的可分离
/// 高斯羽化（边缘夹取）。横向模糊后的行放在 `2r + 1` 行的环里，工作集几行，不为整页留两张 f32 图。
struct MaskRows {
    rects: Vec<[usize; 4]>,
    dw: usize,
    dh: usize,
    r: isize,
    kernel: Vec<f32>,
    /// 环形缓存：槽 `y % len` 存第 `y` 行的横向模糊结果。
    ring: Vec<f32>,
    held: Vec<usize>,
    raw: Vec<f32>,
    out: Vec<f32>,
}

impl MaskRows {
    fn new(boxes: &[[f32; 4]], dw: usize, dh: usize) -> Self {
        let sigma = MASK_SIGMA;
        let r = (sigma * 3.0).ceil() as isize;
        let k: Vec<f32> = (-r..=r)
            .map(|i| (-((i * i) as f32) / (2.0 * sigma * sigma)).exp())
            .collect();
        let sum: f32 = k.iter().sum();
        let kernel: Vec<f32> = k.iter().map(|v| v / sum).collect();
        let span = kernel.len();
        Self {
            rects: mask_rects(boxes, dw, dh),
            dw,
            dh,
            r,
            kernel,
            ring: vec![0f32; span * dw],
            held: vec![usize::MAX; span],
            raw: vec![0f32; dw],
            out: vec![0f32; dw],
        }
    }

    /// 保证第 `y` 行的横向模糊在环里，返回槽。
    fn ensure(&mut self, y: usize) -> usize {
        let slot = y % self.held.len();
        if self.held[slot] != y {
            let dw = self.dw;
            self.raw.iter_mut().for_each(|v| *v = 0.0);
            for &[x0, y0, x1, y1] in &self.rects {
                if (y0..y1).contains(&y) {
                    self.raw[x0..x1].fill(1.0);
                }
            }
            let line = &mut self.ring[slot * dw..(slot + 1) * dw];
            for (x, o) in line.iter_mut().enumerate() {
                let mut acc = 0.0;
                for (j, kv) in self.kernel.iter().enumerate() {
                    let xx = (x as isize + j as isize - self.r).clamp(0, dw as isize - 1) as usize;
                    acc += self.raw[xx] * kv;
                }
                *o = acc;
            }
            self.held[slot] = y;
        }
        slot
    }

    /// 第 `y` 行的遮罩（`dw` 个 0..1）。
    fn row(&mut self, y: usize) -> &[f32] {
        let (dw, dh, r) = (self.dw, self.dh, self.r);
        let rows: Vec<usize> = (0..self.kernel.len())
            .map(|j| (y as isize + j as isize - r).clamp(0, dh as isize - 1) as usize)
            .collect();
        // 夹取后的行号是 [y-r, y+r] 内连续的一段（重复的是同一行），环的容量 2r+1 装得下。
        for &yy in &rows {
            self.ensure(yy);
        }
        let len = self.held.len();
        for x in 0..dw {
            let mut acc = 0.0;
            for (j, kv) in self.kernel.iter().enumerate() {
                let slot = rows[j] % len;
                acc += self.ring[slot * dw + x] * kv;
            }
            self.out[x] = acc;
        }
        &self.out
    }
}

/// 文字保护遮罩（`dw × dh`，0..1）：`boxes` 是归一化矩形 `[x0, y0, x1, y1]`（0..1，相对整页），
/// 每个框在目标分辨率上外扩 [MASK_GROW] 像素后置 1，再做 sigma = [MASK_SIGMA] 的可分离高斯羽化。
/// 退化框（x1 <= x0 等）、非有限值忽略。
pub(crate) fn text_mask(boxes: &[[f32; 4]], dw: usize, dh: usize) -> Vec<f32> {
    let mut mask = vec![0f32; dw * dh];
    if dw == 0 || dh == 0 {
        return mask;
    }
    let mut rows = MaskRows::new(boxes, dw, dh);
    for (y, out) in mask.chunks_exact_mut(dw).enumerate() {
        out.copy_from_slice(rows.row(y));
    }
    mask
}

/// 文字框外扩（目标像素）。
pub(crate) const MASK_GROW: f32 = 2.0;
/// 羽化高斯 sigma（目标像素）。
pub(crate) const MASK_SIGMA: f32 = 1.5;

/// 一个像素按遮罩混合：`m = 1` 取 `a`，`0` 取 `b`。
#[inline]
fn mix(a: u8, b: u8, m: f32) -> u8 {
    (a as f32 * m + b as f32 * (1.0 - m))
        .round()
        .clamp(0.0, 255.0) as u8
}

/// 按遮罩逐像素混合：`mask = 1` 取 `inside`，`0` 取 `outside`。`ch` 通道交错。
pub(crate) fn blend(inside: &[u8], outside: &[u8], mask: &[f32], ch: usize) -> Vec<u8> {
    debug_assert_eq!(inside.len(), outside.len());
    debug_assert_eq!(inside.len(), mask.len() * ch);
    inside
        .iter()
        .zip(outside)
        .enumerate()
        .map(|(i, (&a, &b))| mix(a, b, mask[i / ch]))
        .collect()
}

/// 文字感知的 Gamma 校正缩放：文字框内在 sRGB 编码值上重采样（细笔画不变淡），框外在线性光里
/// （网点明度准），羽化遮罩混合。`boxes` 为空时等同 sRGB 重采样（没有 OCR 数据就不做线性光）。
///
/// 逐行出图：两路 [RowResampler] 与 [MaskRows] 各留几行，混合结果直接写进输出。工作集 = 输出
/// `dw × dh × ch` 字节 + O(核长 × dw) 的行缓存（源图由调用方持有）。
#[allow(clippy::too_many_arguments)]
pub(crate) fn resample_text_aware(
    src: &[u8],
    w: usize,
    h: usize,
    ch: usize,
    dw: usize,
    dh: usize,
    filter: Filter,
    boxes: &[[f32; 4]],
) -> Vec<u8> {
    if boxes.is_empty() || dw == 0 || dh == 0 {
        return resample(src, w, h, ch, dw, dh, filter, false);
    }
    let mut srgb = RowResampler::new(src, w, h, ch, dw, dh, filter, false);
    let mut linear = RowResampler::new(src, w, h, ch, dw, dh, filter, true);
    let mut mask = MaskRows::new(boxes, dw, dh);
    let row_len = dw * ch;
    let mut a = vec![0u8; row_len];
    let mut b = vec![0u8; row_len];
    let mut dst = vec![0u8; dh * row_len];
    for (y, out) in dst.chunks_exact_mut(row_len).enumerate() {
        srgb.row(y, &mut a);
        linear.row(y, &mut b);
        let m = mask.row(y);
        for (i, o) in out.iter_mut().enumerate() {
            *o = mix(a[i], b[i], m[i / ch]);
        }
    }
    dst
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 旧的整张两遍实现（横向结果整张 f32），只作逐位比对的参照。
    #[allow(clippy::too_many_arguments)]
    fn resample_reference(
        src: &[u8],
        w: usize,
        h: usize,
        ch: usize,
        dw: usize,
        dh: usize,
        filter: Filter,
        linear: bool,
    ) -> Vec<u8> {
        let decode: Vec<f32> = (0..256)
            .map(|v| {
                let c = v as f32 / 255.0;
                if linear { srgb_to_linear(c) } else { c }
            })
            .collect();
        let lut_len = 1usize << ENCODE_LUT_BITS;
        let encode: Vec<u8> = (0..lut_len)
            .map(|i| {
                let v = i as f32 / (lut_len - 1) as f32;
                let s = if linear { linear_to_srgb(v) } else { v };
                (s * 255.0 + 0.5).clamp(0.0, 255.0) as u8
            })
            .collect();
        let hx = coefficients(w, dw, filter);
        let mut mid = vec![0f32; h * dw * ch];
        for y in 0..h {
            let row = &src[y * w * ch..(y + 1) * w * ch];
            let out = &mut mid[y * dw * ch..(y + 1) * dw * ch];
            for (x, taps) in hx.iter().enumerate() {
                for c in 0..ch {
                    let mut acc = 0f32;
                    for (k, wt) in taps.weights.iter().enumerate() {
                        acc += wt * decode[row[(taps.start + k) * ch + c] as usize];
                    }
                    out[x * ch + c] = acc;
                }
            }
        }
        let vy = coefficients(h, dh, filter);
        let mut dst = vec![0u8; dw * dh * ch];
        let row_len = dw * ch;
        let mut acc = vec![0f32; row_len];
        let scale = (lut_len - 1) as f32;
        for (y, taps) in vy.iter().enumerate() {
            acc.iter_mut().for_each(|v| *v = 0.0);
            for (k, wt) in taps.weights.iter().enumerate() {
                let line = &mid[(taps.start + k) * row_len..(taps.start + k + 1) * row_len];
                for (a, v) in acc.iter_mut().zip(line) {
                    *a += wt * v;
                }
            }
            let out = &mut dst[y * row_len..(y + 1) * row_len];
            for (o, a) in out.iter_mut().zip(&acc) {
                let idx = (a.clamp(0.0, 1.0) * scale + 0.5) as usize;
                *o = encode[idx];
            }
        }
        dst
    }

    /// 旧的整张遮罩（置 1 后整张两遍高斯），只作逐位比对的参照。
    fn text_mask_reference(boxes: &[[f32; 4]], dw: usize, dh: usize) -> Vec<f32> {
        let mut mask = vec![0f32; dw * dh];
        for b in boxes {
            if !b.iter().all(|v| v.is_finite()) || b[2] <= b[0] || b[3] <= b[1] {
                continue;
            }
            let x0 = ((b[0] * dw as f32).floor() - MASK_GROW).clamp(0.0, dw as f32) as usize;
            let y0 = ((b[1] * dh as f32).floor() - MASK_GROW).clamp(0.0, dh as f32) as usize;
            let x1 = ((b[2] * dw as f32).ceil() + MASK_GROW).clamp(0.0, dw as f32) as usize;
            let y1 = ((b[3] * dh as f32).ceil() + MASK_GROW).clamp(0.0, dh as f32) as usize;
            if x1 <= x0 {
                continue;
            }
            for y in y0..y1 {
                mask[y * dw + x0..y * dw + x1].fill(1.0);
            }
        }
        let sigma = MASK_SIGMA;
        let (w, h) = (dw, dh);
        let r = (sigma * 3.0).ceil() as isize;
        let k: Vec<f32> = (-r..=r)
            .map(|i| (-((i * i) as f32) / (2.0 * sigma * sigma)).exp())
            .collect();
        let sum: f32 = k.iter().sum();
        let k: Vec<f32> = k.iter().map(|v| v / sum).collect();
        let mut tmp = vec![0f32; w * h];
        for y in 0..h {
            let row = &mask[y * w..(y + 1) * w];
            for x in 0..w {
                let mut acc = 0.0;
                for (j, kv) in k.iter().enumerate() {
                    let xx = (x as isize + j as isize - r).clamp(0, w as isize - 1) as usize;
                    acc += row[xx] * kv;
                }
                tmp[y * w + x] = acc;
            }
        }
        for y in 0..h {
            for x in 0..w {
                let mut acc = 0.0;
                for (j, kv) in k.iter().enumerate() {
                    let yy = (y as isize + j as isize - r).clamp(0, h as isize - 1) as usize;
                    acc += tmp[yy * w + x] * kv;
                }
                mask[y * w + x] = acc;
            }
        }
        mask
    }

    /// 流式实现与旧的整张实现逐位相同：各核、各域、放大 / 缩小 / 不变、1 / 3 通道、极端比例（核落空退
    /// 最近邻）、文字感知混合。
    #[test]
    fn streaming_matches_the_whole_image_reference_bit_for_bit() {
        let (w, h) = (37usize, 53usize);
        for ch in [1usize, 3] {
            let src: Vec<u8> = (0..w * h * ch).map(|i| (i * 97 % 253) as u8).collect();
            for filter in [Filter::Box, Filter::Lanczos3, Filter::CatmullRom] {
                for (dw, dh) in [(11, 7), (37, 53), (90, 140), (1, 1), (5, 200), (148, 3)] {
                    for linear in [false, true] {
                        assert_eq!(
                            resample(&src, w, h, ch, dw, dh, filter, linear),
                            resample_reference(&src, w, h, ch, dw, dh, filter, linear),
                            "{filter:?} ch={ch} {dw}x{dh} linear={linear}"
                        );
                    }
                    let boxes = [
                        [0.1f32, 0.2, 0.5, 0.45],
                        [0.6, 0.0, 1.0, 0.3],
                        [0.3, 0.9, 0.31, 0.95],
                    ];
                    let srgb = resample_reference(&src, w, h, ch, dw, dh, filter, false);
                    let lin = resample_reference(&src, w, h, ch, dw, dh, filter, true);
                    let mask = text_mask_reference(&boxes, dw, dh);
                    assert_eq!(
                        resample_text_aware(&src, w, h, ch, dw, dh, filter, &boxes),
                        blend(&srgb, &lin, &mask, ch),
                        "text-aware {filter:?} ch={ch} {dw}x{dh}"
                    );
                }
            }
        }
        for (dw, dh) in [(100, 100), (7, 300), (300, 7), (1, 1)] {
            let boxes = [
                [0.25f32, 0.25, 0.5, 0.5],
                [0.0, 0.0, 0.05, 1.0],
                [0.9, 0.95, 1.0, 1.0],
                [0.5, 0.5, 0.4, 0.6],
                [f32::NAN, 0.0, 1.0, 1.0],
            ];
            assert_eq!(
                text_mask(&boxes, dw, dh),
                text_mask_reference(&boxes, dw, dh),
                "{dw}x{dh}"
            );
        }
    }

    /// 黑白逐像素相间的「网点」缩一半：线性光平均出物理正确的 50% 明度（sRGB ≈ 188），
    /// 编码值平均出 128（偏暗）——这正是 Gamma 校正缩放要修的。
    #[test]
    fn checkerboard_halves_to_physical_mid_gray_in_linear_light() {
        let (w, h) = (64, 64);
        let src: Vec<u8> = (0..w * h)
            .map(|i| if (i % w + i / w) % 2 == 0 { 0 } else { 255 })
            .collect();
        let lin = resample(&src, w, h, 1, 32, 32, Filter::Box, true);
        let enc = resample(&src, w, h, 1, 32, 32, Filter::Box, false);
        let mean = |v: &[u8]| v.iter().map(|&x| x as f64).sum::<f64>() / v.len() as f64;
        assert!(
            (mean(&lin) - 188.0).abs() < 2.0,
            "linear mean {}",
            mean(&lin)
        );
        assert!(
            (mean(&enc) - 127.5).abs() < 2.0,
            "encoded mean {}",
            mean(&enc)
        );
    }

    /// 均匀灰不随核 / 域变化（权重归一化 + LUT 往返无漂移）。
    #[test]
    fn flat_gray_is_preserved_by_every_filter() {
        for filter in [Filter::Box, Filter::Lanczos3, Filter::CatmullRom] {
            for linear in [false, true] {
                for v in [0u8, 1, 17, 128, 254, 255] {
                    let src = vec![v; 40 * 30];
                    for (dw, dh) in [(13, 9), (40, 30), (97, 71)] {
                        let out = resample(&src, 40, 30, 1, dw, dh, filter, linear);
                        assert!(
                            out.iter().all(|&x| x == v),
                            "{filter:?} linear={linear} v={v} {dw}x{dh}"
                        );
                    }
                }
            }
        }
    }

    /// 缩小时核按比例放宽：1 像素周期的条纹缩到 1/3 不得留下混叠条纹（输出近乎平坦）。
    #[test]
    fn downscale_widens_kernel_so_stripes_do_not_alias() {
        let (w, h) = (300, 8);
        let src: Vec<u8> = (0..w * h)
            .map(|i| if (i % w) % 2 == 0 { 0 } else { 255 })
            .collect();
        let out = resample(&src, w, h, 1, 100, 8, Filter::Lanczos3, false);
        // 只看内部：边界处核被截断后重新归一化，本来就不对称。
        let interior: Vec<u8> = (0..8)
            .flat_map(|y| out[y * 100 + 3..y * 100 + 97].to_vec())
            .collect();
        let (lo, hi) = interior
            .iter()
            .fold((255u8, 0u8), |(lo, hi), &x| (lo.min(x), hi.max(x)));
        assert!(hi - lo <= 12, "residual stripe amplitude {}", hi - lo);
    }

    /// 放大：Lanczos3 保持边缘比双线性陡（台阶两侧 1 像素内跨过更多明度）。
    #[test]
    fn upscale_lanczos_keeps_step_edges_sharp() {
        let src: Vec<u8> = (0..16).map(|x| if x < 8 { 0 } else { 255 }).collect();
        let up = resample(&src, 16, 1, 1, 64, 1, Filter::Lanczos3, false);
        // 台阶在输出 x = 32 处；31 与 32 之间至少跨过半个量程。
        assert!(up[33] as i32 - up[30] as i32 > 160, "{:?}", &up[28..36]);
    }

    #[test]
    fn rgb_channels_are_resampled_independently() {
        let mut src = vec![0u8; 10 * 10 * 3];
        for px in src.chunks_mut(3) {
            px.copy_from_slice(&[255, 0, 40]);
        }
        let out = resample(&src, 10, 10, 3, 4, 4, Filter::Lanczos3, true);
        assert!(out.chunks(3).all(|p| p == [255, 0, 40]));
    }

    #[test]
    fn text_mask_is_one_inside_feathered_at_edges_and_zero_far_away() {
        let m = text_mask(&[[0.25, 0.25, 0.5, 0.5]], 100, 100);
        assert!(m[37 * 100 + 37] > 0.99, "centre {}", m[37 * 100 + 37]);
        assert!(m[90 * 100 + 90] < 1e-6);
        // 框外扩 2 px 的边上：羽化（0..1 之间），不是硬边
        let edge = m[37 * 100 + 52];
        assert!(edge > 0.05 && edge < 0.95, "edge {edge}");
        // 退化框 / NaN 忽略
        let none = text_mask(&[[0.5, 0.5, 0.4, 0.6], [f32::NAN, 0.0, 1.0, 1.0]], 20, 20);
        assert!(none.iter().all(|v| *v == 0.0));
    }

    #[test]
    fn text_aware_keeps_strokes_srgb_inside_boxes_and_tone_linear_outside() {
        // 左半：1 px 黑竖线间隔 3 px 白（细笔画）；右半：黑白棋盘（网点）。
        let (w, h) = (200usize, 100usize);
        let mut src = vec![255u8; w * h];
        for y in 0..h {
            for x in 0..w {
                let black = if x < 100 {
                    x % 4 == 0
                } else {
                    (x + y) % 2 == 0
                };
                if black {
                    src[y * w + x] = 0;
                }
            }
        }
        let (dw, dh) = (100usize, 50usize);
        let boxes = [[0.0f32, 0.0, 0.45, 1.0]];
        let out = resample_text_aware(&src, w, h, 1, dw, dh, Filter::Box, &boxes);
        let srgb = resample(&src, w, h, 1, dw, dh, Filter::Box, false);
        let lin = resample(&src, w, h, 1, dw, dh, Filter::Box, true);
        let mean = |img: &[u8], x0: usize, x1: usize| -> f32 {
            let (mut s, mut n) = (0.0f32, 0.0f32);
            for y in 10..40 {
                for x in x0..x1 {
                    s += img[y * dw + x] as f32;
                    n += 1.0;
                }
            }
            s / n
        };
        // 文字区与 sRGB 一致（笔画不被线性光提亮）
        assert!((mean(&out, 5, 35) - mean(&srgb, 5, 35)).abs() < 0.5);
        assert!(mean(&lin, 5, 35) > mean(&srgb, 5, 35) + 20.0);
        // 网点区与线性光一致（明度约 188 而不是 128）
        assert!((mean(&out, 60, 95) - mean(&lin, 60, 95)).abs() < 0.5);
        assert!(mean(&out, 60, 95) > 170.0);
        // 没有框：完全等于 sRGB
        assert_eq!(
            resample_text_aware(&src, w, h, 1, dw, dh, Filter::Box, &[]),
            srgb
        );
    }
    /// HBK-AUDIT-044：常见 RGB 长条页（1600×12000）按显示缩到 1024×7680。工作集（不含调用方持有的
    /// 源图）应约等于输出本身加几行缓存，不能为整张图留 f32 中间缓冲（旧实现横向结果整张 h×dw×ch×4 =
    /// 147 MiB；文字感知再叠两份输出 + 两张 f32 遮罩）。
    #[test]
    fn long_strip_resample_working_set_stays_near_the_output_size() {
        let (w, h, ch, dw, dh) = (1600usize, 12000usize, 3usize, 1024usize, 7680usize);
        let src: Vec<u8> = (0..w * h * ch).map(|i| (i * 31 % 251) as u8).collect();
        let text = [[0.1f32, 0.05, 0.4, 0.15], [0.55, 0.6, 0.9, 0.7]];
        let out_bytes = dw * dh * ch;
        let mib = |b: usize| b as f64 / (1 << 20) as f64;
        let mut over = Vec::new();
        for (label, boxes) in [("plain", &[][..]), ("text-aware", &text[..])] {
            let (out, peak) = crate::test_alloc::peak_bytes_during(|| {
                resample_text_aware(&src, w, h, ch, dw, dh, Filter::Lanczos3, boxes)
            });
            assert_eq!(out.len(), out_bytes);
            eprintln!(
                "{label}: peak working set {:.1} MiB (output {:.1} MiB)",
                mib(peak),
                mib(out_bytes)
            );
            if peak > out_bytes + (8 << 20) {
                over.push(format!("{label}: {:.1} MiB", mib(peak)));
            }
        }
        assert!(
            over.is_empty(),
            "working set exceeds output {:.1} MiB + 8 MiB: {over:?}",
            mib(out_bytes)
        );
    }
}
