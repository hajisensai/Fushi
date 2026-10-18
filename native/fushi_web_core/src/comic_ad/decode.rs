//! 图片解码 + 与旧 Dart 实现（package:image 4.3.0 的 `copyResize`）逐像素一致的缩放。
//!
//! 统一落成 RGB8：灰度 / 灰度 + alpha 展开成 r = g = b，alpha 丢弃（不合成背景，Dart 也是
//! 直接读通道值）。**唯一刻意的偏差**：Dart 把 8 位灰度 PNG 解成单通道图且 `Pixel.g/b`
//! 读出 0，黑白页因此全被当成彩色（见回归向量 expected.json 的 note）；这里灰度就是灰度。

use image::{DynamicImage, ImageFormat};

/// 解码后的 RGB8 图（行主序，每像素 3 字节）。
pub struct Rgb8 {
    pub width: usize,
    pub height: usize,
    pub data: Vec<u8>,
    /// 源图是调色板图（索引 PNG / GIF / ≤8 位 BMP）：Dart 对它们缩放时退化成最近邻。
    pub paletted: bool,
}

impl Rgb8 {
    #[inline]
    pub fn pixel(&self, x: usize, y: usize) -> (u8, u8, u8) {
        let i = (y * self.width + x) * 3;
        (self.data[i], self.data[i + 1], self.data[i + 2])
    }
}

/// 解码失败 / 不认识的格式返回 None（调用方按「不是广告」处理）。
pub fn decode_rgb8(bytes: &[u8]) -> Option<Rgb8> {
    if bytes.is_empty() {
        return None;
    }
    let format = image::guess_format(bytes).ok()?;
    if format == ImageFormat::Jpeg && !has_jpeg_eoi(bytes) {
        // 截断的 JPEG（没下完）：zune-jpeg 会把缺的部分补灰照常交图，Dart 的解码器直接报错。
        // 按旧行为算「解码失败」——半张图不该参与判定（回归向量 py_truncated_color_qr.jpg）。
        return None;
    }
    let paletted = is_paletted(format, bytes);
    let mut reader = image::ImageReader::with_format(std::io::Cursor::new(bytes), format);
    let mut limits = image::Limits::default();
    limits.max_image_width = Some(30_000);
    limits.max_image_height = Some(30_000);
    limits.max_alloc = Some(512 * 1024 * 1024);
    reader.limits(limits);
    let img = reader.decode().ok()?;
    let width = img.width() as usize;
    let height = img.height() as usize;
    let data = match img {
        DynamicImage::ImageRgb8(b) => b.into_raw(),
        other => other.to_rgb8().into_raw(),
    };
    Some(Rgb8 {
        width,
        height,
        data,
        paletted,
    })
}

/// 文件尾 4 KiB 内有 EOI（`FF D9`）。熵编码段里 `FF` 后只会跟 `00` 填充或 `D0..D7` 复位标记，
/// 不会误认；EOI 之后允许有少量尾随垃圾（部分站点会追加）。
fn has_jpeg_eoi(bytes: &[u8]) -> bool {
    let tail = &bytes[bytes.len().saturating_sub(4096)..];
    tail.windows(2).any(|w| w == [0xFF, 0xD9])
}

fn is_paletted(format: ImageFormat, bytes: &[u8]) -> bool {
    match format {
        // IHDR 的 color type 在第 25 字节：3 = indexed。
        ImageFormat::Png => bytes.len() > 25 && bytes[25] == 3,
        ImageFormat::Gif => true,
        // BITMAPINFOHEADER 的 biBitCount 在第 28 字节（u16 LE）。
        ImageFormat::Bmp => bytes.len() > 29 && u16::from_le_bytes([bytes[28], bytes[29]]) <= 8,
        _ => false,
    }
}

/// 长边超过 `max_side` 时按 Dart `copyResize(width|height: max_side, interpolation: average)`
/// 缩小（调色板图退化为最近邻，与 Dart 相同）；否则原样返回。
pub fn fit_within(src: Rgb8, max_side: usize) -> Rgb8 {
    if src.width.max(src.height) <= max_side {
        return src;
    }
    let (w, h) = if src.width >= src.height {
        let h = (max_side as f64 * (src.height as f64 / src.width as f64)).round() as usize;
        (max_side, h)
    } else {
        let w = (max_side as f64 * (src.width as f64 / src.height as f64)).round() as usize;
        (w, max_side)
    };
    if w == src.width && h == src.height {
        return src;
    }
    if src.paletted {
        resize_nearest(&src, w, h)
    } else {
        resize_average(&src, w, h)
    }
}

fn resize_average(src: &Rgb8, w: usize, h: usize) -> Rgb8 {
    let dy = src.height as f64 / h as f64;
    let dx = src.width as f64 / w as f64;
    let mut out = vec![0u8; w * h * 3];
    // 每列的源区间只与 x 有关：先算好，内层循环不再做浮点。
    let xs: Vec<(usize, usize)> = (0..w)
        .map(|x| {
            let ax1 = (x as f64 * dx) as usize;
            let mut ax2 = ((x + 1) as f64 * dx) as usize;
            if ax2 == ax1 {
                ax2 += 1;
            }
            (ax1, ax2)
        })
        .collect();
    for y in 0..h {
        let ay1 = (y as f64 * dy) as usize;
        let mut ay2 = ((y + 1) as f64 * dy) as usize;
        if ay2 == ay1 {
            ay2 += 1;
        }
        for (x, &(ax1, ax2)) in xs.iter().enumerate() {
            let (mut r, mut g, mut b) = (0u32, 0u32, 0u32);
            let mut np = 0u32;
            for sy in ay1..ay2 {
                let row = &src.data[sy * src.width * 3..];
                for sx in ax1..ax2 {
                    let i = sx * 3;
                    r += row[i] as u32;
                    g += row[i + 1] as u32;
                    b += row[i + 2] as u32;
                    np += 1;
                }
            }
            let o = (y * w + x) * 3;
            // Dart：`(sum / np)` 再 `clamp(0,255).toInt()`，即向零截断 = 整数除法。
            out[o] = (r / np) as u8;
            out[o + 1] = (g / np) as u8;
            out[o + 2] = (b / np) as u8;
        }
    }
    Rgb8 {
        width: w,
        height: h,
        data: out,
        paletted: false,
    }
}

fn resize_nearest(src: &Rgb8, w: usize, h: usize) -> Rgb8 {
    let dx = src.width as f64 / w as f64;
    let dy = src.height as f64 / h as f64;
    let mut out = vec![0u8; w * h * 3];
    for y in 0..h {
        let sy = (y as f64 * dy) as usize;
        for x in 0..w {
            let sx = (x as f64 * dx) as usize;
            let s = (sy * src.width + sx) * 3;
            let o = (y * w + x) * 3;
            out[o..o + 3].copy_from_slice(&src.data[s..s + 3]);
        }
    }
    Rgb8 {
        width: w,
        height: h,
        data: out,
        paletted: false,
    }
}

/// 「彩色像素」的通道差下限（max(r,g,b) - min(r,g,b)）。
const COLORFUL_CHANNEL_SPREAD: i32 = 48;

/// 彩色像素占比（按步长 `max(1, min(w,h) / 160)` 抽样）。
pub fn colorful_fraction(image: &Rgb8) -> f64 {
    let step = 1.max(image.width.min(image.height) / 160);
    let mut total = 0u64;
    let mut colorful = 0u64;
    let mut y = 0;
    while y < image.height {
        let mut x = 0;
        while x < image.width {
            let (r, g, b) = image.pixel(x, y);
            let (r, g, b) = (r as i32, g as i32, b as i32);
            let spread = r.max(g.max(b)) - r.min(g.min(b));
            total += 1;
            if spread >= COLORFUL_CHANNEL_SPREAD {
                colorful += 1;
            }
            x += step;
        }
        y += step;
    }
    if total == 0 {
        0.0
    } else {
        colorful as f64 / total as f64
    }
}

/// 亮度图（与 Dart 同式：0.299 r + 0.587 g + 0.114 b，各通道先归一化，四舍五入）。
pub fn luminance(image: &Rgb8) -> Vec<u8> {
    image
        .data
        .chunks_exact(3)
        .map(|p| {
            let l = 0.299 * (p[0] as f64 / 255.0)
                + 0.587 * (p[1] as f64 / 255.0)
                + 0.114 * (p[2] as f64 / 255.0);
            (l * 255.0).round().clamp(0.0, 255.0) as u8
        })
        .collect()
}
