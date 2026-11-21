//! 一页的超分流程（设计文档 §4）：解码 → 框外 / 框内两路放大 2 倍 → 文字遮罩羽化混合 → JPEG。
//!
//! | 档 | 框外（网点、线稿） | 框内（文字） | 没有 OCR 文字框的页 |
//! |---|---|---|---|
//! | 轻量 | ArtCNN C4F32 | Catmull-Rom | 跳过（交回画质缩放） |
//! | 高质量 | waifu2x swin_unet art noise1 | waifu2x swin_unet art scale2x（只跑文字框所在的块） | 整页 scale2x |
//!
//! 评测（设计文档 §2.2）：没有一个模型单独在小字上稳定胜过三次插值，降噪 / 锐化模型把小字「修」错；
//! 文字框内保守、框外激进的融合在小字读数持平的同时把背景 PSNR 从 22.8 提到 27.4。没有框时不知道字在哪：
//! 高质量档整页用对文字最安全的 scale2x（小字 7.6% vs 三次 8.2%、正文 0.41% vs 0.82%），轻量档没有
//! 对文字安全且比 Catmull-Rom 好的选择，就不做。

use super::tile::{SrNet, TileSpec, upscale_tiled};
use crate::image::resample::{self, Filter};
use crate::image::{decode_opaque, encode_fit_jpeg};
use crate::status;

/// 超分档。
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub(crate) enum Tier {
    Light = 1,
    High = 2,
}

impl Tier {
    pub(crate) fn from_code(code: u32) -> Option<Self> {
        match code {
            1 => Some(Self::Light),
            2 => Some(Self::High),
            _ => None,
        }
    }
}

/// 输出 JPEG 质量（与画质缩放同档，4:4:4）。
pub(crate) const UPSCALE_JPEG_QUALITY: u8 = 94;
/// 输出像素上限（与 `FIT_HQ_MAX_PIXELS` 一致）。
pub(crate) const UPSCALE_MAX_OUTPUT_PIXELS: u64 = 48_000_000;
/// 文字框外扩多少输入像素去选「要跑文字模型的块」：遮罩外扩 2 + 羽化 3σ ≈ 7 输出像素，留够余量。
const WANT_MARGIN: usize = 8;

/// 一档用到的网络。
pub(crate) struct Nets {
    pub tier: Tier,
    /// 文字模型（高质量档 swin scale2x；轻量档没有，用 Catmull-Rom）。
    pub inside: Option<(Box<dyn SrNet + Send>, TileSpec)>,
    /// 背景模型。
    pub outside: (Box<dyn SrNet + Send>, TileSpec),
}

pub(crate) enum Outcome {
    /// 放大 2 倍后的 JPEG。
    Done(Vec<u8>),
    /// 这页不做（轻量档没有文字框 / 太大）。
    Skipped,
}

fn to_u8(v: f32) -> u8 {
    (v * 255.0).round().clamp(0.0, 255.0) as u8
}

/// 交错 u8（`ch` 通道）→ 每通道一个 0..1 平面。
fn planes(px: &[u8], ch: usize) -> Vec<Vec<f32>> {
    (0..ch)
        .map(|c| {
            px.iter()
                .skip(c)
                .step_by(ch)
                .map(|v| *v as f32 / 255.0)
                .collect()
        })
        .collect()
}

/// 用 `net` 把 `px`（`w × h × ch` 交错）放大 2 倍，输出同通道数交错 u8。网络通道与图不同时：灰度图喂
/// RGB 网络就复制三份、输出取平均；彩图喂亮度网络就只放大 Y，CbCr 用 Catmull-Rom。
fn sr_page(
    net: &mut dyn SrNet,
    spec: TileSpec,
    px: &[u8],
    w: usize,
    h: usize,
    ch: usize,
    want: Option<&[[usize; 4]]>,
) -> Result<Vec<u8>, String> {
    if net.scale() != 2 {
        return Err(format!("model scale {} is not 2", net.scale()));
    }
    let (ow, oh) = (w * 2, h * 2);
    let n = ow * oh;
    match (net.channels(), ch) {
        (nc, ic) if nc == ic => {
            let input: Vec<f32> = planes(px, ch).concat();
            let out = upscale_tiled(net, &input, h, w, spec, want)?;
            Ok((0..n * ch)
                .map(|i| to_u8(out[(i % ch) * n + i / ch]))
                .collect())
        }
        (3, 1) => {
            let p: Vec<f32> = px.iter().map(|v| *v as f32 / 255.0).collect();
            let input = [p.as_slice(), p.as_slice(), p.as_slice()].concat();
            let out = upscale_tiled(net, &input, h, w, spec, want)?;
            Ok((0..n)
                .map(|i| to_u8((out[i] + out[n + i] + out[2 * n + i]) / 3.0))
                .collect())
        }
        (1, 3) => {
            let y: Vec<f32> = px
                .chunks_exact(3)
                .map(|p| (0.299 * p[0] as f32 + 0.587 * p[1] as f32 + 0.114 * p[2] as f32) / 255.0)
                .collect();
            let sy = upscale_tiled(net, &y, h, w, spec, want)?;
            let base = resample::resample(px, w, h, 3, ow, oh, Filter::CatmullRom, false);
            let mut out = vec![0u8; n * 3];
            for i in 0..n {
                let (r, g, b) = (
                    base[i * 3] as f32,
                    base[i * 3 + 1] as f32,
                    base[i * 3 + 2] as f32,
                );
                let yb = 0.299 * r + 0.587 * g + 0.114 * b;
                let d = sy[i] * 255.0 - yb;
                out[i * 3] = (r + d).round().clamp(0.0, 255.0) as u8;
                out[i * 3 + 1] = (g + d).round().clamp(0.0, 255.0) as u8;
                out[i * 3 + 2] = (b + d).round().clamp(0.0, 255.0) as u8;
            }
            Ok(out)
        }
        (nc, ic) => Err(format!("model channels {nc} vs image channels {ic}")),
    }
}

/// 文字框（归一化）→ 输入像素矩形，外扩 [WANT_MARGIN]。
fn want_rects(boxes: &[[f32; 4]], w: usize, h: usize) -> Vec<[usize; 4]> {
    boxes
        .iter()
        .filter(|b| b.iter().all(|v| v.is_finite()) && b[2] > b[0] && b[3] > b[1])
        .map(|b| {
            let x0 = ((b[0] * w as f32).floor() as isize - WANT_MARGIN as isize).max(0) as usize;
            let y0 = ((b[1] * h as f32).floor() as isize - WANT_MARGIN as isize).max(0) as usize;
            let x1 = (((b[2] * w as f32).ceil() as usize) + WANT_MARGIN).min(w);
            let y1 = (((b[3] * h as f32).ceil() as usize) + WANT_MARGIN).min(h);
            [x0, y0, x1, y1]
        })
        .collect()
}

/// 已解码的一页放大 2 倍（交错 u8 进出）。`Ok(None)` = 这页不做。
pub(crate) fn upscale_pixels(
    px: &[u8],
    w: usize,
    h: usize,
    ch: usize,
    boxes: &[[f32; 4]],
    nets: &mut Nets,
) -> Result<Option<Vec<u8>>, String> {
    let (ow, oh) = (w * 2, h * 2);
    if (ow as u64) * (oh as u64) > UPSCALE_MAX_OUTPUT_PIXELS {
        return Ok(None);
    }
    let rects = want_rects(boxes, w, h);
    match nets.tier {
        Tier::Light if rects.is_empty() => Ok(None),
        Tier::Light => {
            let (net, spec) = &mut nets.outside;
            let outside = sr_page(net.as_mut(), *spec, px, w, h, ch, None)?;
            let inside = resample::resample(px, w, h, ch, ow, oh, Filter::CatmullRom, false);
            let mask = resample::text_mask(boxes, ow, oh);
            Ok(Some(resample::blend(&inside, &outside, &mask, ch)))
        }
        Tier::High => {
            let Some((inside_net, inside_spec)) = nets.inside.as_mut() else {
                return Err("high tier needs the text model".into());
            };
            if rects.is_empty() {
                return sr_page(inside_net.as_mut(), *inside_spec, px, w, h, ch, None).map(Some);
            }
            let inside = sr_page(
                inside_net.as_mut(),
                *inside_spec,
                px,
                w,
                h,
                ch,
                Some(&rects),
            )?;
            let (net, spec) = &mut nets.outside;
            let outside = sr_page(net.as_mut(), *spec, px, w, h, ch, None)?;
            let mask = resample::text_mask(boxes, ow, oh);
            Ok(Some(resample::blend(&inside, &outside, &mask, ch)))
        }
    }
}

/// 一页（编码过的图片字节）→ 放大 2 倍的 JPEG（带源图 ICC）。
pub(crate) fn process(data: &[u8], boxes: &[[f32; 4]], nets: &mut Nets) -> Result<Outcome, String> {
    let (px, w, h, ch, icc) =
        decode_opaque(data).map_err(|code| format!("decode failed ({code})"))?;
    let (w, h, ch) = (w as usize, h as usize, ch as usize);
    match upscale_pixels(&px, w, h, ch, boxes, nets)? {
        None => Ok(Outcome::Skipped),
        Some(out) => {
            drop(px);
            encode_fit_jpeg(
                &out,
                (w * 2) as u32,
                (h * 2) as u32,
                ch,
                UPSCALE_JPEG_QUALITY,
                icc.as_deref(),
            )
            .map(Outcome::Done)
            .map_err(|code| {
                if code == status::BAD_INPUT {
                    "encode failed".into()
                } else {
                    format!("encode failed ({code})")
                }
            })
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::upscale::tile::tests::MockNet;

    fn mock(global: f32) -> (Box<dyn SrNet + Send>, TileSpec) {
        (
            Box::new(MockNet {
                r: 1,
                global,
                off: 0,
                align: 1,
                calls: 0,
            }),
            TileSpec { tile: 32, ctx: 4 },
        )
    }

    fn gray_page(w: usize, h: usize) -> Vec<u8> {
        (0..w * h)
            .map(|i| {
                if (i % w / 3 + i / w / 3) % 2 == 0 {
                    30
                } else {
                    220
                }
            })
            .collect()
    }

    #[test]
    fn light_tier_skips_pages_without_text_boxes() {
        let mut nets = Nets {
            tier: Tier::Light,
            inside: None,
            outside: mock(0.0),
        };
        let px = gray_page(40, 30);
        assert!(
            upscale_pixels(&px, 40, 30, 1, &[], &mut nets)
                .unwrap()
                .is_none()
        );
        let out = upscale_pixels(&px, 40, 30, 1, &[[0.1, 0.1, 0.4, 0.4]], &mut nets)
            .unwrap()
            .unwrap();
        assert_eq!(out.len(), 80 * 60);
    }

    /// 高质量档：框内取文字模型、框外取背景模型（两个 mock 用不同的全局偏置区分），没框整页文字模型。
    #[test]
    fn high_tier_uses_text_model_inside_boxes_only() {
        let (w, h) = (64usize, 64usize);
        let px = vec![100u8; w * h];
        let mut nets = Nets {
            tier: Tier::High,
            inside: Some(mock(0.5)),
            outside: mock(0.0),
        };
        let out = upscale_pixels(&px, w, h, 1, &[[0.0, 0.0, 0.25, 0.25]], &mut nets)
            .unwrap()
            .unwrap();
        let ow = 2 * w;
        // 框内（输出 10,10）：100/255 + 0.5 × 100/255 ≈ 150
        assert!(
            (out[10 * ow + 10] as i32 - 150).abs() <= 1,
            "inside {}",
            out[10 * ow + 10]
        );
        // 远离框（输出 120,120）：背景模型 = 100
        assert_eq!(out[120 * ow + 120], 100);
        let whole = upscale_pixels(&px, w, h, 1, &[], &mut nets)
            .unwrap()
            .unwrap();
        assert!(whole.iter().all(|v| (*v as i32 - 150).abs() <= 1));
    }

    #[test]
    fn color_pages_through_a_luma_model_keep_their_hue() {
        let (w, h) = (16usize, 16usize);
        let px: Vec<u8> = (0..w * h).flat_map(|_| [200u8, 40, 40]).collect();
        let mut nets = Nets {
            tier: Tier::Light,
            inside: None,
            outside: mock(0.0),
        };
        let out = upscale_pixels(&px, w, h, 3, &[[0.0, 0.0, 0.1, 0.1]], &mut nets)
            .unwrap()
            .unwrap();
        let p = &out[(20 * 32 + 20) * 3..(20 * 32 + 20) * 3 + 3];
        assert!(
            (p[0] as i32 - 200).abs() <= 2 && (p[1] as i32 - 40).abs() <= 2,
            "{p:?}"
        );
    }

    #[test]
    fn process_round_trips_a_png_to_a_2x_jpeg() {
        let img =
            image::GrayImage::from_fn(30, 20, |x, y| image::Luma([((x * 8 + y) % 256) as u8]));
        let mut png = Vec::new();
        image::DynamicImage::ImageLuma8(img)
            .write_to(&mut std::io::Cursor::new(&mut png), image::ImageFormat::Png)
            .unwrap();
        let mut nets = Nets {
            tier: Tier::Light,
            inside: None,
            outside: mock(0.0),
        };
        let Outcome::Done(jpeg) = process(&png, &[[0.0, 0.0, 0.5, 0.5]], &mut nets).unwrap() else {
            panic!("expected output");
        };
        let out = image::load_from_memory(&jpeg).unwrap();
        assert_eq!((out.width(), out.height()), (60, 40));
        assert!(matches!(process(b"junk", &[], &mut nets), Err(_)));
    }
}
