//! pdf：用安装目录里随包的 `pdfium.dll`（与 app 的 pdfrx 同一份）渲第一页。
//!
//! 文档经 `FPDF_LoadCustomDocument` 按块从流里读，不把整份 pdf 读进内存。pdfium 不是线程安全的：
//! 全部调用在一把全局锁里串行。

use std::ffi::{c_char, c_int, c_ulong, c_void};
use std::io::{Read, Seek, SeekFrom};
use std::sync::{Mutex, OnceLock};

use crate::extract::PdfBackend;
use crate::image_out::fit_within;
use crate::{ReadSeek, ThumbError, Thumbnail};

type FpdfDocument = *mut c_void;
type FpdfPage = *mut c_void;
type FpdfBitmap = *mut c_void;

#[repr(C)]
struct FpdfFileAccess {
    file_len: c_ulong,
    get_block: unsafe extern "C" fn(
        param: *mut c_void,
        position: c_ulong,
        buf: *mut u8,
        size: c_ulong,
    ) -> c_int,
    param: *mut c_void,
}

/// pdfium 的 C 导出（`fpdfview.h`）。
struct Api {
    load_custom_document: unsafe extern "C" fn(*mut FpdfFileAccess, *const c_char) -> FpdfDocument,
    close_document: unsafe extern "C" fn(FpdfDocument),
    get_page_count: unsafe extern "C" fn(FpdfDocument) -> c_int,
    load_page: unsafe extern "C" fn(FpdfDocument, c_int) -> FpdfPage,
    close_page: unsafe extern "C" fn(FpdfPage),
    page_width: unsafe extern "C" fn(FpdfPage) -> f32,
    page_height: unsafe extern "C" fn(FpdfPage) -> f32,
    bitmap_create: unsafe extern "C" fn(c_int, c_int, c_int) -> FpdfBitmap,
    bitmap_fill_rect:
        unsafe extern "C" fn(FpdfBitmap, c_int, c_int, c_int, c_int, c_ulong) -> c_int,
    render_page_bitmap:
        unsafe extern "C" fn(FpdfBitmap, FpdfPage, c_int, c_int, c_int, c_int, c_int, c_int),
    bitmap_buffer: unsafe extern "C" fn(FpdfBitmap) -> *mut c_void,
    bitmap_stride: unsafe extern "C" fn(FpdfBitmap) -> c_int,
    bitmap_destroy: unsafe extern "C" fn(FpdfBitmap),
}

// SAFETY: 只含函数指针；所有调用都在 Pdfium::lock 里串行。
unsafe impl Send for Api {}
unsafe impl Sync for Api {}

/// `FPDF_ANNOT`：渲染注释外观（表单、印章等）。
const FPDF_ANNOT: c_int = 0x01;

pub struct Pdfium {
    api: Api,
    lock: Mutex<()>,
}

impl Pdfium {
    /// 进程内单例；第一次调用时按 [`super::dependency_dir`] 加载并 `FPDF_InitLibrary`。
    pub fn get() -> Result<&'static Pdfium, ThumbError> {
        static INSTANCE: OnceLock<Result<Pdfium, ThumbError>> = OnceLock::new();
        INSTANCE
            .get_or_init(Pdfium::load)
            .as_ref()
            .map_err(Clone::clone)
    }

    // sym! 里的 transmute 目标类型由 Api 字段类型推断，逐个标注只会重复一遍签名。
    #[allow(clippy::missing_transmute_annotations)]
    fn load() -> Result<Pdfium, ThumbError> {
        let m = super::load_bundled_library("pdfium.dll")?;
        macro_rules! sym {
            ($name:literal) => {{
                let f = super::proc_address(m, concat!($name, "\0").as_bytes())?;
                // SAFETY: 签名照 pdfium 公开头文件 fpdfview.h。
                unsafe { std::mem::transmute(f) }
            }};
        }
        let init: unsafe extern "C" fn() = sym!("FPDF_InitLibrary");
        let api = Api {
            load_custom_document: sym!("FPDF_LoadCustomDocument"),
            close_document: sym!("FPDF_CloseDocument"),
            get_page_count: sym!("FPDF_GetPageCount"),
            load_page: sym!("FPDF_LoadPage"),
            close_page: sym!("FPDF_ClosePage"),
            page_width: sym!("FPDF_GetPageWidthF"),
            page_height: sym!("FPDF_GetPageHeightF"),
            bitmap_create: sym!("FPDFBitmap_Create"),
            bitmap_fill_rect: sym!("FPDFBitmap_FillRect"),
            render_page_bitmap: sym!("FPDF_RenderPageBitmap"),
            bitmap_buffer: sym!("FPDFBitmap_GetBuffer"),
            bitmap_stride: sym!("FPDFBitmap_GetStride"),
            bitmap_destroy: sym!("FPDFBitmap_Destroy"),
        };
        // SAFETY: 进程内只调一次（OnceLock），之后不 Destroy（模块活到进程结束）。
        unsafe { init() };
        Ok(Pdfium {
            api,
            lock: Mutex::new(()),
        })
    }
}

struct BlockSource {
    reader: Box<dyn ReadSeek>,
}

unsafe extern "C" fn get_block(
    param: *mut c_void,
    position: c_ulong,
    buf: *mut u8,
    size: c_ulong,
) -> c_int {
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        // SAFETY: param 是 render_first_page 里活着的 BlockSource；buf 至少 size 字节。
        let src = unsafe { &mut *(param as *mut BlockSource) };
        let out = unsafe { std::slice::from_raw_parts_mut(buf, size as usize) };
        src.reader.seek(SeekFrom::Start(position as u64)).ok()?;
        src.reader.read_exact(out).ok()
    }));
    matches!(result, Ok(Some(()))) as c_int
}

impl PdfBackend for Pdfium {
    fn render_first_page(
        &self,
        mut reader: Box<dyn ReadSeek>,
        cx: u32,
    ) -> Result<Thumbnail, ThumbError> {
        let len = reader.seek(SeekFrom::End(0))?;
        reader.seek(SeekFrom::Start(0))?;
        let file_len = c_ulong::try_from(len)
            .map_err(|_| ThumbError::Corrupt("pdf larger than 4 GiB".into()))?;
        let mut source = BlockSource { reader };
        let mut access = FpdfFileAccess {
            file_len,
            get_block,
            param: &mut source as *mut BlockSource as *mut c_void,
        };
        let _guard = self
            .lock
            .lock()
            .map_err(|_| ThumbError::Io("pdfium lock poisoned".into()))?;
        let a = &self.api;
        // SAFETY: access / source 在文档关闭之前一直存活（本函数结束前关闭）。
        unsafe {
            let doc = (a.load_custom_document)(&mut access, std::ptr::null());
            if doc.is_null() {
                return Err(ThumbError::Corrupt(
                    "pdfium could not open the document".into(),
                ));
            }
            let result = (|| {
                if (a.get_page_count)(doc) < 1 {
                    return Err(ThumbError::NoCover);
                }
                let page = (a.load_page)(doc, 0);
                if page.is_null() {
                    return Err(ThumbError::Corrupt("pdfium could not load page 1".into()));
                }
                let r = self.render_page(page, cx);
                (a.close_page)(page);
                r
            })();
            (a.close_document)(doc);
            result
        }
    }
}

impl Pdfium {
    /// SAFETY: 调用方持有 self.lock，page 有效。
    unsafe fn render_page(&self, page: FpdfPage, cx: u32) -> Result<Thumbnail, ThumbError> {
        let a = &self.api;
        let pw = (a.page_width)(page);
        let ph = (a.page_height)(page);
        if !(pw.is_finite() && ph.is_finite()) || pw <= 0.0 || ph <= 0.0 {
            return Err(ThumbError::Corrupt("pdf page has no size".into()));
        }
        // 页面尺寸是点（1/72 英寸）；直接按点数等比缩到 cx（不放大到超过 cx）。
        let scale_base = cx.max(1) as f32 / pw.max(ph);
        let (w, h) = fit_within(
            (pw * scale_base).round().max(1.0) as u32,
            (ph * scale_base).round().max(1.0) as u32,
            cx,
        );
        let bitmap = (a.bitmap_create)(w as c_int, h as c_int, 0);
        if bitmap.is_null() {
            return Err(ThumbError::Io("FPDFBitmap_Create failed".into()));
        }
        (a.bitmap_fill_rect)(bitmap, 0, 0, w as c_int, h as c_int, 0xFFFF_FFFF);
        (a.render_page_bitmap)(bitmap, page, 0, 0, w as c_int, h as c_int, 0, FPDF_ANNOT);
        let buf = (a.bitmap_buffer)(bitmap) as *const u8;
        let stride = (a.bitmap_stride)(bitmap) as usize;
        let result = if buf.is_null() || stride < w as usize * 4 {
            Err(ThumbError::Io("pdfium bitmap has no buffer".into()))
        } else {
            let mut bgra = Vec::with_capacity(w as usize * h as usize * 4);
            for y in 0..h as usize {
                let row = std::slice::from_raw_parts(buf.add(y * stride), w as usize * 4);
                for px in row.chunks_exact(4) {
                    bgra.extend_from_slice(&[px[0], px[1], px[2], 255]);
                }
            }
            Ok(Thumbnail {
                width: w,
                height: h,
                bgra,
            })
        };
        (a.bitmap_destroy)(bitmap);
        result
    }
}
