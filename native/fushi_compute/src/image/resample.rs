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

/// `src`（`w × h × ch`，行紧排）缩放到 `dw × dh`。`ch` 只能是 1 或 3。
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
    debug_assert!(ch == 1 || ch == 3);
    debug_assert_eq!(src.len(), w * h * ch);
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

    // 横向：w → dw，结果 h × dw × ch 的 f32（已是线性 / 编码域，按 linear 而定）。
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
    // 纵向：h → dh，再编回 uint8。
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

#[cfg(test)]
mod tests {
    use super::*;

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
}
