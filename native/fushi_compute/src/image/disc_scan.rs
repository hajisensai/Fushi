//! `ffc_image_disc_scan`：判断一张扫描图是不是**光盘盘面**（CD / DVD / BD 的印刷面）。
//!
//! 抓轨 / 扫图包里的扫描多按 `01.jpg`、`scan_03.jpg` 编号，盘面混在歌词本、背封、盘托里，
//! 文件名分不出来。盘面扫描有很稳的几何特征（2026-11-11 在真实曲库 178 张扫描上标注调参，
//! 22 张盘面全中、156 张其他全拒）：
//!
//! 1. 画幅近正方（宽高比 0.92～1.08）——盘面扫描都裁到盘的外接正方形；
//! 2. 四个角（内切圆外）是扫描仪底色：颜色均匀；
//! 3. 中心轴孔透出同一个底色；
//! 4. 孔外的透明夹持环与孔有明显色差（排除「中间恰好是白点」的图）；
//! 5. 盘的外缘：沿内切圆附近一圈，绝大多数方向上有明显的径向跳变。
//!
//! 全部在缩到 [GRID]×[GRID] 的灰度 / RGB 网格上算（盒式平均），与原图分辨率无关。宁可漏判
//! 不误判：任何一条不满足就不是盘面。

use super::{decode_image, open_decoder, slice, slice_mut};
use crate::{guard, status};

/// 判定用的网格边长。
const GRID: usize = 128;

/// 近正方的宽高比范围。
const MIN_ASPECT: f64 = 0.92;
const MAX_ASPECT: f64 = 1.08;

/// 超过这个像素数不解码（150 MP 的 TIFF 扫描会吃掉上 GB 内存；盘面扫描 1200 dpi 也才 ~32 MP）。
const MAX_PIXELS: u64 = 100_000_000;

/// 阈值（0..255 色阶上的平均绝对差 / 标准差）。实测盘面：角落 std ≤ 6.1、孔与底色差 ≤ 7.8、
/// 夹持环与孔差 ≥ 12.1、外缘跳变覆盖 ≥ 0.85；非盘面在这几条上至少一条差得远。
const MAX_BACKGROUND_STD: f64 = 9.0;
const MAX_HOLE_VS_BACKGROUND: f64 = 12.0;
const MIN_HUB_VS_HOLE: f64 = 10.0;
const MIN_EDGE_COVERAGE: f64 = 0.80;
/// 外缘一处算「有跳变」的灰度差。
const EDGE_STEP: f64 = 18.0;

/// 特征输出的槽位数（见 [ffc_image_disc_scan]）。
pub const DISC_SCAN_FEATURES: usize = 7;

/// 判定结果与各项特征。
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct DiscScan {
    pub is_disc: bool,
    pub aspect: f64,
    pub background_std: f64,
    pub hole_vs_background: f64,
    pub hub_vs_hole: f64,
    pub body_vs_background: f64,
    pub edge_coverage: f64,
}

impl DiscScan {
    fn not_square(aspect: f64) -> Self {
        Self {
            is_disc: false,
            aspect,
            background_std: f64::NAN,
            hole_vs_background: f64::NAN,
            hub_vs_hole: f64::NAN,
            body_vs_background: f64::NAN,
            edge_coverage: f64::NAN,
        }
    }

    fn to_slots(self) -> [f64; DISC_SCAN_FEATURES] {
        [
            if self.is_disc { 1.0 } else { 0.0 },
            self.aspect,
            self.background_std,
            self.hole_vs_background,
            self.hub_vs_hole,
            self.body_vs_background,
            self.edge_coverage,
        ]
    }
}

fn square_enough(aspect: f64) -> bool {
    (MIN_ASPECT..=MAX_ASPECT).contains(&aspect)
}

/// 盒式平均缩到 GRID×GRID 的 RGB（f64）。
fn box_grid(pixels: &[u8], w: usize, h: usize, ch: usize) -> Vec<[f64; 3]> {
    let mut sum = vec![[0.0f64; 3]; GRID * GRID];
    let mut count = vec![0u32; GRID * GRID];
    for y in 0..h {
        let gy = y * GRID / h;
        let row = &pixels[y * w * ch..(y + 1) * w * ch];
        for x in 0..w {
            let gx = x * GRID / w;
            let p = &row[x * ch..x * ch + ch];
            let (r, g, b) = if ch >= 3 {
                (p[0], p[1], p[2])
            } else {
                (p[0], p[0], p[0])
            };
            let cell = &mut sum[gy * GRID + gx];
            cell[0] += r as f64;
            cell[1] += g as f64;
            cell[2] += b as f64;
            count[gy * GRID + gx] += 1;
        }
    }
    for (cell, n) in sum.iter_mut().zip(count) {
        if n > 0 {
            for c in cell.iter_mut() {
                *c /= n as f64;
            }
        }
    }
    sum
}

/// 网格点到中心的距离（以内切圆半径为 1）。
fn radius(x: usize, y: usize) -> f64 {
    let c = (GRID as f64 - 1.0) / 2.0;
    let half = GRID as f64 / 2.0;
    ((x as f64 - c).powi(2) + (y as f64 - c).powi(2)).sqrt() / half
}

struct Ring {
    mean: [f64; 3],
    std: f64,
}

fn ring(grid: &[[f64; 3]], r0: f64, r1: f64) -> Option<Ring> {
    let mut acc = [0.0f64; 3];
    let mut n = 0usize;
    for y in 0..GRID {
        for x in 0..GRID {
            let d = radius(x, y);
            if d >= r0 && d < r1 {
                let p = grid[y * GRID + x];
                for c in 0..3 {
                    acc[c] += p[c];
                }
                n += 1;
            }
        }
    }
    if n == 0 {
        return None;
    }
    let mean = acc.map(|v| v / n as f64);
    let mut var = [0.0f64; 3];
    for y in 0..GRID {
        for x in 0..GRID {
            let d = radius(x, y);
            if d >= r0 && d < r1 {
                let p = grid[y * GRID + x];
                for c in 0..3 {
                    var[c] += (p[c] - mean[c]).powi(2);
                }
            }
        }
    }
    let std = var.iter().map(|v| (v / n as f64).sqrt()).sum::<f64>() / 3.0;
    Some(Ring { mean, std })
}

fn mean_abs_diff(a: [f64; 3], b: [f64; 3]) -> f64 {
    (0..3).map(|c| (a[c] - b[c]).abs()).sum::<f64>() / 3.0
}

/// 外缘覆盖率：72 个方向上，半径 0.85～1.04 之间相邻采样点的最大灰度差超过 [EDGE_STEP]
/// 的方向占比。
fn edge_coverage(grid: &[[f64; 3]]) -> f64 {
    let gray = |x: usize, y: usize| -> f64 {
        let p = grid[y * GRID + x];
        (p[0] + p[1] + p[2]) / 3.0
    };
    let c = (GRID as f64 - 1.0) / 2.0;
    let half = GRID as f64 / 2.0;
    const ANGLES: usize = 72;
    const STEPS: usize = 20;
    let mut hits = 0usize;
    for k in 0..ANGLES {
        let t = std::f64::consts::TAU * k as f64 / ANGLES as f64;
        let mut prev: Option<f64> = None;
        let mut best = 0.0f64;
        for s in 0..STEPS {
            let rr = 0.85 + (1.04 - 0.85) * s as f64 / (STEPS - 1) as f64;
            let x = (c + t.cos() * rr * half).round().clamp(0.0, GRID as f64 - 1.0) as usize;
            let y = (c + t.sin() * rr * half).round().clamp(0.0, GRID as f64 - 1.0) as usize;
            let v = gray(x, y);
            if let Some(p) = prev {
                best = best.max((v - p).abs());
            }
            prev = Some(v);
        }
        if best > EDGE_STEP {
            hits += 1;
        }
    }
    hits as f64 / ANGLES as f64
}

/// 在已解码像素上判定（`pixels` 行紧排，`ch` 为 1～4）。
pub fn classify_disc_scan(pixels: &[u8], w: usize, h: usize, ch: usize) -> DiscScan {
    let aspect = w as f64 / h as f64;
    if !square_enough(aspect) || w < GRID / 2 || h < GRID / 2 {
        return DiscScan::not_square(aspect);
    }
    let grid = box_grid(pixels, w, h, ch);
    let (Some(bg), Some(hole), Some(hub), Some(body)) = (
        ring(&grid, 1.06, 9.0),
        ring(&grid, 0.0, 0.07),
        ring(&grid, 0.16, 0.30),
        ring(&grid, 0.40, 0.90),
    ) else {
        return DiscScan::not_square(aspect);
    };
    let background_std = bg.std;
    let hole_vs_background = mean_abs_diff(hole.mean, bg.mean);
    let hub_vs_hole = mean_abs_diff(hub.mean, hole.mean);
    let body_vs_background = mean_abs_diff(body.mean, bg.mean);
    let edge = edge_coverage(&grid);
    DiscScan {
        is_disc: background_std <= MAX_BACKGROUND_STD
            && hole_vs_background <= MAX_HOLE_VS_BACKGROUND
            && hub_vs_hole >= MIN_HUB_VS_HOLE
            && edge >= MIN_EDGE_COVERAGE,
        aspect,
        background_std,
        hole_vs_background,
        hub_vs_hole,
        body_vs_background,
        edge_coverage: edge,
    }
}

/// 从编码字节判定：先只读头看宽高比（不近正方 / 过大直接判否，不解码），再解码判定。
fn disc_scan_bytes(data: &[u8]) -> Result<DiscScan, i32> {
    use image::ImageDecoder;
    if !super::avif::is_avif(data) {
        let (decoder, _) = open_decoder(data)?;
        let (w, h) = decoder.dimensions();
        if w == 0 || h == 0 {
            return Err(status::BAD_INPUT);
        }
        let aspect = w as f64 / h as f64;
        if !square_enough(aspect) || (w as u64) * (h as u64) > MAX_PIXELS {
            return Ok(DiscScan::not_square(aspect));
        }
    }
    let d = decode_image(data, true)?;
    Ok(classify_disc_scan(
        &d.pixels,
        d.width as usize,
        d.height as usize,
        d.channels as usize,
    ))
}

/// 判断编码图片字节是不是光盘盘面扫描。`out_features` 写 [DISC_SCAN_FEATURES] 个 f64：
/// `[is_disc(0/1), aspect, background_std, hole_vs_background, hub_vs_hole,
/// body_vs_background, edge_coverage]`（不近正方时后五项为 NaN）。解不开返回
/// [status::BAD_INPUT]。
///
/// # Safety
/// `data` 按 `len` 可读；`out_features` 可写 [DISC_SCAN_FEATURES] 个 f64。
#[no_mangle]
pub unsafe extern "C" fn ffc_image_disc_scan(
    data: *const u8,
    len: usize,
    out_features: *mut f64,
) -> i32 {
    guard(|| {
        if data.is_null() || out_features.is_null() {
            return status::NULL_ARGUMENT;
        }
        match disc_scan_bytes(slice(data, len)) {
            Ok(scan) => {
                slice_mut(out_features, DISC_SCAN_FEATURES).copy_from_slice(&scan.to_slots());
                status::OK
            }
            Err(code) => code,
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 合成一张盘面扫描（按真实 CD 比例：孔 Ø15 mm / 盘 Ø120 mm ≈ 半径 0.125）：白底、
    /// 盘体、外缘深色描边、浅色夹持环、中心孔透出白底。
    fn synth_disc(n: usize, body: [u8; 3]) -> Vec<u8> {
        let mut px = vec![255u8; n * n * 3];
        let c = (n as f64 - 1.0) / 2.0;
        let r = n as f64 / 2.0;
        for y in 0..n {
            for x in 0..n {
                let d = ((x as f64 - c).powi(2) + (y as f64 - c).powi(2)).sqrt() / r;
                let color = if d < 0.125 {
                    [255, 255, 255]
                } else if d < 0.32 {
                    [170, 175, 180]
                } else if d < 0.96 {
                    body
                } else if d < 1.0 {
                    [60, 60, 60]
                } else {
                    [255, 255, 255]
                };
                let i = (y * n + x) * 3;
                px[i..i + 3].copy_from_slice(&color);
            }
        }
        px
    }

    #[test]
    fn synthetic_disc_is_detected() {
        let px = synth_disc(400, [40, 90, 200]);
        let scan = classify_disc_scan(&px, 400, 400, 3);
        assert!(scan.is_disc, "{scan:?}");
    }

    #[test]
    fn white_printed_disc_on_white_is_detected() {
        // 白色印刷面（只有外缘描边与夹持环），底色同为白：靠孔 / 夹持环 / 外缘判。
        let px = synth_disc(300, [245, 245, 245]);
        assert!(classify_disc_scan(&px, 300, 300, 3).is_disc);
    }

    #[test]
    fn non_square_is_rejected_without_features() {
        let px = vec![255u8; 600 * 300 * 3];
        let scan = classify_disc_scan(&px, 600, 300, 3);
        assert!(!scan.is_disc);
        assert!(scan.background_std.is_nan());
    }

    #[test]
    fn busy_square_artwork_is_rejected() {
        // 满幅渐变插画：角落不均匀、没有孔。
        let n = 256;
        let mut px = vec![0u8; n * n * 3];
        for y in 0..n {
            for x in 0..n {
                let i = (y * n + x) * 3;
                px[i] = (x * 255 / n) as u8;
                px[i + 1] = (y * 255 / n) as u8;
                px[i + 2] = ((x + y) * 127 / n) as u8;
            }
        }
        assert!(!classify_disc_scan(&px, n, n, 3).is_disc);
    }

    #[test]
    fn plain_white_page_is_rejected() {
        // 纯白页（歌词本空白页）：角落 / 孔都是白，但夹持环与孔没有色差、没有外缘。
        let px = vec![250u8; 200 * 200 * 3];
        assert!(!classify_disc_scan(&px, 200, 200, 3).is_disc);
    }

    #[test]
    fn ffi_rejects_null_and_garbage() {
        let mut out = [0.0f64; DISC_SCAN_FEATURES];
        unsafe {
            assert_eq!(
                ffc_image_disc_scan(std::ptr::null(), 0, out.as_mut_ptr()),
                status::NULL_ARGUMENT
            );
            let junk = [1u8, 2, 3, 4];
            assert_eq!(
                ffc_image_disc_scan(junk.as_ptr(), junk.len(), out.as_mut_ptr()),
                status::BAD_INPUT
            );
        }
    }
}
