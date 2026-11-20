//! [`Thumbnail`] → 自上而下 32 位 DIB section（资源管理器接管 HBITMAP 的所有权）。

use windows::Win32::Graphics::Gdi::{
    BI_RGB, BITMAPINFO, BITMAPINFOHEADER, CreateDIBSection, DIB_RGB_COLORS, HBITMAP,
};

use crate::{ThumbError, Thumbnail};

pub fn to_hbitmap(t: &Thumbnail) -> Result<HBITMAP, ThumbError> {
    let expected = t.width as usize * t.height as usize * 4;
    if t.width == 0 || t.height == 0 || t.bgra.len() != expected {
        return Err(ThumbError::Corrupt("bad thumbnail buffer".into()));
    }
    let info = BITMAPINFO {
        bmiHeader: BITMAPINFOHEADER {
            biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
            biWidth: t.width as i32,
            // 负高度 = 自上而下，与 Thumbnail 的行序一致。
            biHeight: -(t.height as i32),
            biPlanes: 1,
            biBitCount: 32,
            biCompression: BI_RGB.0,
            ..Default::default()
        },
        ..Default::default()
    };
    let mut bits: *mut core::ffi::c_void = std::ptr::null_mut();
    // SAFETY: info 有效；bits 接收 GDI 分配的像素缓冲区。
    let bmp = unsafe { CreateDIBSection(None, &info, DIB_RGB_COLORS, &mut bits, None, 0) }
        .map_err(|e| ThumbError::Io(e.to_string()))?;
    if bits.is_null() {
        return Err(ThumbError::Io("CreateDIBSection returned no bits".into()));
    }
    // SAFETY: 32 位 DIB 每行恰好 width*4 字节（已 4 字节对齐），缓冲区大小 = expected。
    unsafe { std::ptr::copy_nonoverlapping(t.bgra.as_ptr(), bits.cast::<u8>(), expected) };
    Ok(bmp)
}
