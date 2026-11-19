//! 将整页 straight-alpha RGBA 覆盖层一次合进原页图；上传副本使用，原图不改。

use super::{INTERP_AVERAGE, View, decode_image, resize_into};
use crate::{guard, status};

const MAX_SIDE: u32 = 1280;

fn overlay_length(width: u32, height: u32) -> Result<usize, i32> {
    if width == 0 || height == 0 || width > MAX_SIDE || height > MAX_SIDE {
        return Err(status::INVALID_ARGUMENT);
    }
    (width as usize)
        .checked_mul(height as usize)
        .and_then(|pixels| pixels.checked_mul(4))
        .ok_or(status::INVALID_ARGUMENT)
}

/// 解码并转正源图，在白色底上按面积平均缩小，合成 straight RGBA 覆盖层。
/// 不放大；输出永远是 RGB，避免透明源留下黑底或产生黑边。
fn composite_pixels(data: &[u8], overlay: &[u8], width: u32, height: u32) -> Result<Vec<u8>, i32> {
    let overlay_len = overlay_length(width, height)?;
    if overlay.len() != overlay_len {
        return Err(status::INVALID_ARGUMENT);
    }
    let mut decoded = decode_image(data, true)?;
    if width > decoded.width || height > decoded.height {
        return Err(status::INVALID_ARGUMENT);
    }
    // 先合白底再缩放：透明像素中隐藏的颜色不能污染缩小后的边缘。
    if decoded.channels == 4 {
        decoded.pixels = decoded
            .pixels
            .chunks_exact(4)
            .flat_map(|pixel| {
                let alpha = pixel[3] as u32;
                [0, 1, 2]
                    .map(|c| ((pixel[c] as u32 * alpha + 255 * (255 - alpha) + 127) / 255) as u8)
            })
            .collect();
        decoded.channels = 3;
    }
    let mut output = if width == decoded.width && height == decoded.height {
        decoded.pixels
    } else {
        let source = View::new(
            &decoded.pixels,
            decoded.width as usize * 3,
            3,
            0,
            0,
            decoded.width,
            decoded.height,
        )?;
        let mut output = vec![0u8; overlay_len / 4 * 3];
        resize_into(
            &source,
            &mut output,
            width as usize,
            height as usize,
            INTERP_AVERAGE,
        );
        output
    };
    for (base, layer) in output.chunks_exact_mut(3).zip(overlay.chunks_exact(4)) {
        let alpha = layer[3] as u32;
        if alpha == 0 {
            continue;
        }
        for channel in 0..3 {
            base[channel] = ((layer[channel] as u32 * alpha
                + base[channel] as u32 * (255 - alpha)
                + 127)
                / 255) as u8;
        }
    }
    Ok(output)
}

fn composite_jpeg(
    data: &[u8],
    overlay: &[u8],
    width: u32,
    height: u32,
    quality: u32,
) -> Result<Vec<u8>, i32> {
    if !(1..=100).contains(&quality) {
        return Err(status::INVALID_ARGUMENT);
    }
    let pixels = composite_pixels(data, overlay, width, height)?;
    let mut output = Vec::new();
    let mut encoder = jpeg_encoder::Encoder::new(&mut output, quality as u8);
    encoder.set_sampling_factor(jpeg_encoder::SamplingFactor::F_1_1);
    encoder
        .encode(
            &pixels,
            width as u16,
            height as u16,
            jpeg_encoder::ColorType::Rgb,
        )
        .map_err(|_| status::BAD_INPUT)?;
    Ok(output)
}

/// 将编码原图（自动转正）与整页 straight RGBA 覆盖层合成成 JPEG（4:4:4）。
/// `width` / `height` 为覆盖层与输出尺寸，须为 1..=1280 且不超过转正后的源图尺寸。
/// 覆盖层长度必须恰为 `width * height * 4`；源图透明部分合白底。
/// 失败不交出原图：调用方必须停止发送该页，以免旧文字泄漏到 AI。
///
/// # Safety
/// 输入指针须按给定长度可读；`out_ptr` / `out_len` 须可写。
#[no_mangle]
pub unsafe extern "C" fn ffc_image_composite_rgba_jpeg(
    data: *const u8,
    len: usize,
    overlay: *const u8,
    overlay_len: usize,
    width: u32,
    height: u32,
    quality: u32,
    out_ptr: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    guard(|| {
        if out_ptr.is_null() || out_len.is_null() {
            return status::NULL_ARGUMENT;
        }
        *out_ptr = std::ptr::null_mut();
        *out_len = 0;
        if data.is_null() || overlay.is_null() {
            return status::NULL_ARGUMENT;
        }
        if len == 0 || len > isize::MAX as usize {
            return status::BAD_INPUT;
        }
        if overlay_length(width, height) != Ok(overlay_len) {
            return status::INVALID_ARGUMENT;
        }
        let data = std::slice::from_raw_parts(data, len);
        let overlay = std::slice::from_raw_parts(overlay, overlay_len);
        match composite_jpeg(data, overlay, width, height, quality) {
            Ok(jpeg) => {
                crate::hand_over_bytes(jpeg, out_ptr, out_len);
                status::OK
            }
            Err(code) => code,
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn png(image: image::DynamicImage) -> Vec<u8> {
        let mut out = std::io::Cursor::new(Vec::new());
        image.write_to(&mut out, image::ImageFormat::Png).unwrap();
        out.into_inner()
    }

    #[test]
    fn composite_opaque_layer_replaces_old_pixels_and_transparent_layer_keeps_them() {
        let src = image::RgbImage::from_fn(8, 8, |x, _| {
            image::Rgb(if x < 4 { [0, 0, 0] } else { [30, 90, 150] })
        });
        let data = png(image::DynamicImage::ImageRgb8(src));
        let mut overlay = vec![0u8; 8 * 8 * 4];
        for y in 0..8 {
            for x in 0..4 {
                overlay[(y * 8 + x) * 4..(y * 8 + x) * 4 + 4]
                    .copy_from_slice(&[255, 255, 255, 255]);
            }
        }
        let pixels = composite_pixels(&data, &overlay, 8, 8).unwrap();
        for (i, pixel) in pixels.chunks_exact(3).enumerate() {
            assert_eq!(
                pixel,
                if i % 8 < 4 {
                    &[255, 255, 255]
                } else {
                    &[30, 90, 150]
                }
            );
        }
        let jpeg = composite_jpeg(&data, &overlay, 8, 8, 100).unwrap();
        let decoded = image::load_from_memory(&jpeg).unwrap().to_rgb8();
        assert_eq!(decoded.dimensions(), (8, 8));
        assert!(decoded.get_pixel(1, 4).0.iter().all(|&c| c >= 253));
    }

    #[test]
    fn composite_uses_straight_alpha_and_rounds_channels() {
        let src = image::RgbImage::from_pixel(1, 1, image::Rgb([40, 80, 120]));
        let data = png(image::DynamicImage::ImageRgb8(src));
        let pixels = composite_pixels(&data, &[240, 160, 80, 128], 1, 1).unwrap();
        assert_eq!(pixels, [140, 120, 100]);
    }

    #[test]
    fn composite_flattens_source_alpha_on_white_before_resizing() {
        let src = image::RgbaImage::from_raw(2, 1, vec![0, 0, 0, 0, 0, 0, 0, 255]).unwrap();
        let data = png(image::DynamicImage::ImageRgba8(src));
        assert_eq!(
            composite_pixels(&data, &[0, 0, 0, 0], 1, 1).unwrap(),
            [127, 127, 127]
        );
    }

    #[test]
    fn composite_scales_base_to_overlay_canvas_and_keeps_overlay_coordinates() {
        let src = image::RgbImage::from_fn(4, 2, |x, _| image::Rgb([x as u8 * 60; 3]));
        let data = png(image::DynamicImage::ImageRgb8(src));
        let overlay = [0, 0, 0, 0, 255, 0, 0, 255];
        assert_eq!(
            composite_pixels(&data, &overlay, 2, 1).unwrap(),
            [30, 30, 30, 255, 0, 0]
        );
        assert_eq!(
            composite_pixels(&data, &[0; 5 * 2 * 4], 5, 2),
            Err(status::INVALID_ARGUMENT)
        );
    }

    #[test]
    fn composite_validates_dimensions_lengths_and_image_data() {
        assert_eq!(overlay_length(0, 1), Err(status::INVALID_ARGUMENT));
        assert_eq!(
            overlay_length(u32::MAX, u32::MAX),
            Err(status::INVALID_ARGUMENT)
        );
        assert_eq!(overlay_length(1281, 1), Err(status::INVALID_ARGUMENT));
        assert_eq!(
            composite_pixels(b"bad", &[], 1, 1),
            Err(status::INVALID_ARGUMENT)
        );
        assert_eq!(
            composite_pixels(b"bad", &[0; 4], 1, 1),
            Err(status::BAD_INPUT)
        );
        assert_eq!(
            composite_jpeg(b"bad", &[0; 4], 1, 1, 101),
            Err(status::INVALID_ARGUMENT)
        );
        unsafe {
            let mut ptr = 1usize as *mut u8;
            let mut len = 99usize;
            let result = ffc_image_composite_rgba_jpeg(
                b"bad".as_ptr(),
                3,
                [0u8; 3].as_ptr(),
                3,
                1,
                1,
                85,
                &mut ptr,
                &mut len,
            );
            assert_eq!(result, status::INVALID_ARGUMENT);
            assert!(ptr.is_null());
            assert_eq!(len, 0);
        }
    }

    #[test]
    fn composite_applies_overlay_after_exif_orientation() {
        let src =
            image::RgbImage::from_fn(16, 8, |x, y| image::Rgb([x as u8 * 12, y as u8 * 25, 60]));
        let mut jpeg = Vec::new();
        jpeg_encoder::Encoder::new(&mut jpeg, 100)
            .encode(src.as_raw(), 16, 8, jpeg_encoder::ColorType::Rgb)
            .unwrap();
        // EXIF IFD0 Orientation = 6（顺时针转 90°），TIFF little endian。
        let exif = [
            b'E', b'x', b'i', b'f', 0, 0, b'I', b'I', 42, 0, 8, 0, 0, 0, 1, 0, 0x12, 1, 3, 0, 1, 0,
            0, 0, 6, 0, 0, 0, 0, 0, 0, 0,
        ];
        let mut oriented = jpeg[..2].to_vec();
        oriented.extend_from_slice(&[0xff, 0xe1]);
        oriented.extend_from_slice(&((exif.len() + 2) as u16).to_be_bytes());
        oriented.extend_from_slice(&exif);
        oriented.extend_from_slice(&jpeg[2..]);
        let base = decode_image(&oriented, true).unwrap();
        assert_eq!((base.width, base.height), (8, 16));
        let mut overlay = vec![0u8; 8 * 16 * 4];
        overlay[..8 * 8 * 4].fill(255);
        let pixels = composite_pixels(&oriented, &overlay, 8, 16).unwrap();
        assert!(pixels[..8 * 8 * 3].iter().all(|&c| c == 255));
        assert_eq!(&pixels[8 * 8 * 3..], &base.pixels[8 * 8 * 3..]);
    }

    #[test]
    fn composite_ffi_returns_owned_jpeg_and_releases_it() {
        let data = png(image::DynamicImage::ImageRgb8(image::RgbImage::from_pixel(
            1,
            1,
            image::Rgb([0, 0, 0]),
        )));
        let overlay = [255u8; 4];
        unsafe {
            let mut ptr = std::ptr::null_mut();
            let mut len = 0;
            assert_eq!(
                ffc_image_composite_rgba_jpeg(
                    data.as_ptr(),
                    data.len(),
                    overlay.as_ptr(),
                    overlay.len(),
                    1,
                    1,
                    100,
                    &mut ptr,
                    &mut len,
                ),
                status::OK,
            );
            assert!(!ptr.is_null());
            let bytes = std::slice::from_raw_parts(ptr, len);
            assert_eq!(&bytes[..2], &[0xff, 0xd8]);
            let pixel = image::load_from_memory(bytes)
                .unwrap()
                .to_rgb8()
                .get_pixel(0, 0)
                .0;
            crate::ffc_free_bytes(ptr, len);
            assert!(pixel.iter().all(|&c| c >= 253));
        }
    }
}
