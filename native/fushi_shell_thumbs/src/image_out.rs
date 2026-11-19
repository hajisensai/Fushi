//! 图片解码 + 缩放成资源管理器要的 BGRA 缩略图。

use image::{DynamicImage, ImageReader, Limits};

use crate::{ThumbError, Thumbnail};

/// 单张封面图压缩后允许的最大字节数（超了按坏文件处理，不往 surrogate 进程里塞巨块）。
pub const MAX_COVER_BYTES: u64 = 128 * 1024 * 1024;

/// 解码时的像素 / 内存上限。
fn decode_limits() -> Limits {
    let mut l = Limits::default();
    l.max_image_width = Some(32_768);
    l.max_image_height = Some(32_768);
    l.max_alloc = Some(512 * 1024 * 1024);
    l
}

/// 资源管理器要求的边长 `cx` 下，等比缩放后的尺寸（只缩不放，至少 1 像素）。
pub fn fit_within(width: u32, height: u32, cx: u32) -> (u32, u32) {
    let cx = cx.max(1);
    let longest = width.max(height);
    if longest <= cx || longest == 0 {
        return (width.max(1), height.max(1));
    }
    let scale = cx as f64 / longest as f64;
    let w = ((width as f64 * scale).round() as u32).clamp(1, cx);
    let h = ((height as f64 * scale).round() as u32).clamp(1, cx);
    (w, h)
}

/// 解码一张封面图并缩到 `cx` 以内。
pub fn thumbnail_from_image_bytes(bytes: &[u8], cx: u32) -> Result<Thumbnail, ThumbError> {
    let mut reader = ImageReader::new(std::io::Cursor::new(bytes))
        .with_guessed_format()
        .map_err(|e| ThumbError::Corrupt(e.to_string()))?;
    reader.limits(decode_limits());
    let img = reader
        .decode()
        .map_err(|e| ThumbError::Corrupt(e.to_string()))?;
    Ok(thumbnail_from_image(img, cx))
}

fn thumbnail_from_image(img: DynamicImage, cx: u32) -> Thumbnail {
    let (w, h) = fit_within(img.width(), img.height(), cx);
    let img = if (w, h) != (img.width(), img.height()) {
        img.thumbnail_exact(w, h)
    } else {
        img
    };
    let rgba = img.to_rgba8();
    let (width, height) = rgba.dimensions();
    let mut bgra = Vec::with_capacity(rgba.len());
    for px in rgba.pixels() {
        let [r, g, b, a] = px.0;
        // 透明处垫白（与纸面一致），统一按不透明位图交给资源管理器。
        let blend = |c: u8| -> u8 { ((c as u32 * a as u32 + 255 * (255 - a as u32)) / 255) as u8 };
        bgra.extend_from_slice(&[blend(b), blend(g), blend(r), 255]);
    }
    Thumbnail {
        width,
        height,
        bgra,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::{ImageFormat, Rgba, RgbaImage};

    fn encode(img: &RgbaImage, fmt: ImageFormat) -> Vec<u8> {
        let mut out = std::io::Cursor::new(Vec::new());
        DynamicImage::ImageRgba8(img.clone())
            .write_to(&mut out, fmt)
            .unwrap();
        out.into_inner()
    }

    #[test]
    fn fit_keeps_aspect_and_never_upscales() {
        assert_eq!(fit_within(1000, 1500, 256), (171, 256));
        assert_eq!(fit_within(1500, 1000, 256), (256, 171));
        assert_eq!(fit_within(100, 50, 256), (100, 50));
        assert_eq!(fit_within(10_000, 1, 256), (256, 1));
        assert_eq!(fit_within(0, 0, 256), (1, 1));
    }

    #[test]
    fn decodes_png_into_bgra_and_downscales() {
        let img = RgbaImage::from_pixel(400, 600, Rgba([200, 10, 30, 255]));
        let t = thumbnail_from_image_bytes(&encode(&img, ImageFormat::Png), 96).unwrap();
        assert_eq!((t.width, t.height), (64, 96));
        assert_eq!(t.bgra.len(), 64 * 96 * 4);
        assert_eq!(&t.bgra[0..4], &[30, 10, 200, 255]);
    }

    #[test]
    fn transparent_pixels_are_flattened_onto_white() {
        let img = RgbaImage::from_pixel(4, 4, Rgba([0, 0, 0, 0]));
        let t = thumbnail_from_image_bytes(&encode(&img, ImageFormat::Png), 256).unwrap();
        assert_eq!(&t.bgra[0..4], &[255, 255, 255, 255]);
    }

    #[test]
    fn garbage_is_an_error_not_a_panic() {
        assert!(matches!(
            thumbnail_from_image_bytes(b"\x89PNG\r\n\x1a\nnot really", 256),
            Err(ThumbError::Corrupt(_))
        ));
        assert!(thumbnail_from_image_bytes(b"", 256).is_err());
    }
}
