//! 端到端：照资源管理器的调用顺序走 COM（DllGetClassObject → IClassFactory::CreateInstance →
//! IInitializeWithFile::Initialize → IThumbnailProvider::GetThumbnail），处理器再拉起真正的
//! `fushi_shell_thumbs_host.exe`（cargo 编出的那个，拷进模拟 `{app}` 的临时目录），断言拿回的
//! HBITMAP 尺寸与像素。
//!
//! rar / 7z / pdf 需要随包 DLL：
//! * `FUSHI_TEST_7Z_DIR`：含 `7z.dll` 与 `7z.exe` 的目录（与 `tools/bundle_7za.ps1` 随包的同一份）；
//! * `FUSHI_TEST_PDFIUM_DLL`：`pdfium.dll` 的路径（与 app 的 pdfrx 同一份）。
//!
//! 没设时这几条打印 SKIP 后返回；`FUSHI_THUMBS_REQUIRE_DEPS=1`（CI 门）时缺依赖直接判红。
#![cfg(windows)]

use std::ffi::c_void;
use std::io::{Cursor, Write};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::OnceLock;
use std::sync::atomic::{AtomicUsize, Ordering};

use fushi_shell_thumbs::DllGetClassObject;
use fushi_shell_thumbs::win::{com::clsid, set_dependency_dir};
use image::{DynamicImage, ImageFormat, Rgba, RgbaImage};
use windows::Win32::Graphics::Gdi::{DIBSECTION, DeleteObject, GetObjectW, HBITMAP, HGDIOBJ};
use windows::Win32::System::Com::{COINIT_APARTMENTTHREADED, CoInitializeEx, IClassFactory};
use windows::Win32::UI::Shell::PropertiesSystem::IInitializeWithFile;
use windows::Win32::UI::Shell::{IThumbnailProvider, WTS_ALPHATYPE, WTSAT_RGB};
use windows::core::{GUID, HSTRING, Interface, PCWSTR};

#[derive(Default)]
struct Deps {
    app_dir: PathBuf,
    seven_zip_dir: Option<PathBuf>,
    pdfium: bool,
}

/// 把宿主 exe 与测试用的随包 DLL 拷进一个临时目录，模拟 `{app}` 的布局（处理器只按自己所在
/// 目录找宿主，宿主只按自己所在目录找 DLL）。
fn deps() -> &'static Deps {
    static DEPS: OnceLock<Deps> = OnceLock::new();
    DEPS.get_or_init(|| {
        let dir =
            std::env::temp_dir().join(format!("fushi_shell_thumbs_app_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::copy(
            env!("CARGO_BIN_EXE_fushi_shell_thumbs_host"),
            dir.join("fushi_shell_thumbs_host.exe"),
        )
        .expect("copy host exe");
        let mut d = Deps {
            app_dir: dir.clone(),
            ..Deps::default()
        };
        if let Some(src) = std::env::var_os("FUSHI_TEST_7Z_DIR").map(PathBuf::from) {
            // 与安装目录同布局：7-Zip 在 {app}\7za\ 下（tools/bundle_7za.ps1）。
            std::fs::create_dir_all(dir.join("7za")).unwrap();
            std::fs::copy(src.join("7z.dll"), dir.join("7za").join("7z.dll")).expect("copy 7z.dll");
            d.seven_zip_dir = Some(src);
        }
        if let Some(src) = std::env::var_os("FUSHI_TEST_PDFIUM_DLL").map(PathBuf::from) {
            std::fs::copy(&src, dir.join("pdfium.dll")).expect("copy pdfium.dll");
            d.pdfium = true;
        }
        assert!(set_dependency_dir(dir), "dependency dir set twice");
        d
    })
}

fn require_or_skip(have: bool, what: &str) -> bool {
    if have {
        return true;
    }
    if std::env::var("FUSHI_THUMBS_REQUIRE_DEPS").as_deref() == Ok("1") {
        panic!("{what} is required (FUSHI_THUMBS_REQUIRE_DEPS=1) but not provided");
    }
    eprintln!("SKIP: {what} not provided");
    false
}

fn png(w: u32, h: u32, rgb: [u8; 3]) -> Vec<u8> {
    let img = RgbaImage::from_pixel(w, h, Rgba([rgb[0], rgb[1], rgb[2], 255]));
    let mut out = Cursor::new(Vec::new());
    DynamicImage::ImageRgba8(img)
        .write_to(&mut out, ImageFormat::Png)
        .unwrap();
    out.into_inner()
}

/// 上半红、下半蓝。
fn png_red_over_blue(w: u32, h: u32) -> Vec<u8> {
    let img = RgbaImage::from_fn(w, h, |_, y| {
        if y < h / 2 {
            Rgba([255, 0, 0, 255])
        } else {
            Rgba([0, 0, 255, 255])
        }
    });
    let mut out = Cursor::new(Vec::new());
    DynamicImage::ImageRgba8(img)
        .write_to(&mut out, ImageFormat::Png)
        .unwrap();
    out.into_inner()
}

struct Bitmap {
    width: i32,
    height: i32,
    /// 内存里第一个像素：自上而下位图的左上角。
    first_pixel_bgra: [u8; 4],
    /// 内存里最后一个像素：自上而下位图的右下角。
    last_pixel_bgra: [u8; 4],
}

/// 把夹具写成一个文件（资源管理器给处理器的是路径）。
fn fixture_file(bytes: &[u8]) -> PathBuf {
    static NEXT: AtomicUsize = AtomicUsize::new(0);
    let dir = deps().app_dir.join("fixtures");
    std::fs::create_dir_all(&dir).unwrap();
    // 文件名带非 ASCII 字符：路径要原样穿过 COM → 命令行 → 宿主进程。
    let path = dir.join(format!("封面 {}.bin", NEXT.fetch_add(1, Ordering::SeqCst)));
    std::fs::write(&path, bytes).unwrap();
    path
}

fn new_provider() -> IInitializeWithFile {
    unsafe {
        let _ = CoInitializeEx(None, COINIT_APARTMENTTHREADED);
        let mut factory: *mut c_void = std::ptr::null_mut();
        DllGetClassObject(&clsid(), &IClassFactory::IID, &mut factory)
            .ok()
            .unwrap();
        let factory = IClassFactory::from_raw(factory);
        factory
            .CreateInstance(None::<&windows::core::IUnknown>)
            .unwrap()
    }
}

/// 走一遍资源管理器的 COM 调用序列；失败返回 HRESULT。
fn thumbnail_via_com(bytes: &[u8], cx: u32) -> windows::core::Result<Bitmap> {
    let path = fixture_file(bytes);
    let init = new_provider();
    unsafe {
        let wide = HSTRING::from(path.as_os_str());
        init.Initialize(PCWSTR(wide.as_ptr()), 0)?;
        let provider: IThumbnailProvider = init.cast()?;
        let mut hbmp = HBITMAP::default();
        let mut alpha = WTS_ALPHATYPE::default();
        provider.GetThumbnail(cx, &mut hbmp, &mut alpha)?;
        assert_eq!(alpha, WTSAT_RGB);
        let mut ds = DIBSECTION::default();
        let n = GetObjectW(
            HGDIOBJ(hbmp.0),
            std::mem::size_of::<DIBSECTION>() as i32,
            Some(&mut ds as *mut DIBSECTION as *mut c_void),
        );
        assert_eq!(n as usize, std::mem::size_of::<DIBSECTION>());
        assert_eq!(ds.dsBm.bmBitsPixel, 32);
        // GetObject 对 DIB section 总把 biHeight 报成正数，行序只能看像素（见 cbz 用例的上下两色图）。
        let len = (ds.dsBm.bmWidth * ds.dsBm.bmHeight * 4) as usize;
        let px = std::slice::from_raw_parts(ds.dsBm.bmBits as *const u8, len);
        let out = Bitmap {
            width: ds.dsBm.bmWidth,
            height: ds.dsBm.bmHeight,
            first_pixel_bgra: [px[0], px[1], px[2], px[3]],
            last_pixel_bgra: [px[len - 4], px[len - 3], px[len - 2], px[len - 1]],
        };
        let _ = DeleteObject(HGDIOBJ(hbmp.0));
        Ok(out)
    }
}

fn zip_of(entries: &[(&str, &[u8])]) -> Vec<u8> {
    let mut w = zip::ZipWriter::new(Cursor::new(Vec::new()));
    for (name, data) in entries {
        w.start_file(*name, zip::write::SimpleFileOptions::default())
            .unwrap();
        w.write_all(data).unwrap();
    }
    w.finish().unwrap().into_inner()
}

#[test]
fn cbz_cover_through_com() {
    let bytes = zip_of(&[
        ("002.png", &png(100, 150, [0, 255, 0])),
        ("001.png", &png_red_over_blue(300, 450)),
    ]);
    let bmp = thumbnail_via_com(&bytes, 256).unwrap();
    assert_eq!((bmp.width, bmp.height), (171, 256));
    // 自上而下：内存开头是红（上半），结尾是蓝（下半）。
    assert_eq!(bmp.first_pixel_bgra, [0, 0, 255, 255]);
    assert_eq!(bmp.last_pixel_bgra, [255, 0, 0, 255]);
}

#[test]
fn epub_cover_through_com() {
    let container =
        br#"<container><rootfiles><rootfile full-path="content.opf"/></rootfiles></container>"#;
    let opf = br#"<package><metadata><meta name="cover" content="cv"/></metadata><manifest>
<item id="p" href="p.png" media-type="image/png"/><item id="cv" href="c.png" media-type="image/png"/>
</manifest></package>"#;
    let bytes = zip_of(&[
        ("mimetype", b"application/epub+zip"),
        ("META-INF/container.xml", container),
        ("content.opf", opf),
        ("p.png", &png(10, 10, [0, 0, 255])),
        ("c.png", &png(40, 60, [0, 255, 0])),
    ]);
    let bmp = thumbnail_via_com(&bytes, 256).unwrap();
    assert_eq!((bmp.width, bmp.height), (40, 60));
    assert_eq!(bmp.first_pixel_bgra, [0, 255, 0, 255]);
}

#[test]
fn unknown_and_broken_files_fail_without_crashing_the_host() {
    for bytes in [
        b"plain text, no cover".to_vec(),
        b"PK\x03\x04garbage".to_vec(),
        b"Rar!\x1A\x07\x01\x00garbage".to_vec(),
        b"%PDF-1.7 garbage".to_vec(),
        Vec::new(),
    ] {
        assert!(thumbnail_via_com(&bytes, 256).is_err());
    }
}

#[test]
fn initialize_twice_is_rejected() {
    let path = fixture_file(b"x");
    let init = new_provider();
    let wide = HSTRING::from(path.as_os_str());
    unsafe {
        init.Initialize(PCWSTR(wide.as_ptr()), 0).unwrap();
        assert!(init.Initialize(PCWSTR(wide.as_ptr()), 0).is_err());
    }
}

#[test]
fn missing_file_fails_cleanly() {
    let init = new_provider();
    let wide = HSTRING::from(deps().app_dir.join("does-not-exist.cbz").as_os_str());
    unsafe {
        init.Initialize(PCWSTR(wide.as_ptr()), 0).unwrap();
        let provider: IThumbnailProvider = init.cast().unwrap();
        let mut hbmp = HBITMAP::default();
        let mut alpha = WTS_ALPHATYPE::default();
        assert!(provider.GetThumbnail(256, &mut hbmp, &mut alpha).is_err());
        assert!(hbmp.is_invalid());
    }
}

/// 宿主进程自己的契约：成功写一帧、失败不写任何东西并以非零退出。
#[test]
fn host_process_contract() {
    let host = deps().app_dir.join("fushi_shell_thumbs_host.exe");
    let good = fixture_file(&zip_of(&[("1.png", &png(20, 10, [1, 2, 3]))]));
    let out = Command::new(&host).arg("256").arg(&good).output().unwrap();
    assert!(out.status.success());
    let t = fushi_shell_thumbs::wire::decode(&out.stdout, 256).unwrap();
    assert_eq!((t.width, t.height), (20, 10));
    assert_eq!(&t.bgra[..4], &[3, 2, 1, 255]);

    let bad = fixture_file(b"PK\x03\x04garbage");
    let out = Command::new(&host).arg("256").arg(&bad).output().unwrap();
    assert!(!out.status.success());
    assert!(out.stdout.is_empty());

    let out = Command::new(&host)
        .arg("not-a-number")
        .arg(&good)
        .output()
        .unwrap();
    assert!(!out.status.success());
    assert!(out.stdout.is_empty());
}

#[test]
fn foreign_clsid_is_refused() {
    let other = GUID::from_u128(0x0123_4567_89ab_cdef_0123_4567_89ab_cdef);
    let mut out: *mut c_void = std::ptr::null_mut();
    let hr = unsafe { DllGetClassObject(&other, &IClassFactory::IID, &mut out) };
    assert_eq!(hr, windows::Win32::Foundation::CLASS_E_CLASSNOTAVAILABLE);
    assert!(out.is_null());
}

// ── RAR5（store）夹具：按 RAR 5.0 格式规范手搓，不依赖 rar.exe ──────────

fn vint(mut v: u64) -> Vec<u8> {
    let mut out = Vec::new();
    loop {
        let b = (v & 0x7f) as u8;
        v >>= 7;
        if v == 0 {
            out.push(b);
            return out;
        }
        out.push(b | 0x80);
    }
}

fn rar5_block(body: &[u8]) -> Vec<u8> {
    let mut sized = vint(body.len() as u64);
    sized.extend_from_slice(body);
    let mut out = crc32fast::hash(&sized).to_le_bytes().to_vec();
    out.extend_from_slice(&sized);
    out
}

fn rar5_stored(files: &[(&str, &[u8])]) -> Vec<u8> {
    let mut out = b"Rar!\x1A\x07\x01\x00".to_vec();
    // 主头：type 1，无标志。
    out.extend(rar5_block(&[vint(1), vint(0), vint(0)].concat()));
    for (name, data) in files {
        let body = [
            vint(2),                 // 文件头
            vint(0x02),              // 头标志：有数据区
            vint(data.len() as u64), // 数据区大小
            vint(0x04),              // 文件标志：带 CRC32
            vint(data.len() as u64), // 解包大小
            vint(0x20),              // 属性
            crc32fast::hash(data).to_le_bytes().to_vec(),
            vint(0), // 压缩信息：版本 0、store
            vint(0), // 宿主系统：Windows
            vint(name.len() as u64),
            name.as_bytes().to_vec(),
        ]
        .concat();
        out.extend(rar5_block(&body));
        out.extend_from_slice(data);
    }
    // 结束头：type 5。
    out.extend(rar5_block(&[vint(5), vint(0), vint(0)].concat()));
    out
}

#[test]
fn cbr_rar5_cover_through_com() {
    if !require_or_skip(deps().seven_zip_dir.is_some(), "FUSHI_TEST_7Z_DIR") {
        return;
    }
    let bytes = rar5_stored(&[
        ("chapter/10.png", &png(20, 20, [0, 0, 255])),
        ("chapter/9.png", &png(64, 32, [255, 0, 0])),
    ]);
    let bmp = thumbnail_via_com(&bytes, 256).unwrap();
    assert_eq!((bmp.width, bmp.height), (64, 32));
    assert_eq!(bmp.first_pixel_bgra, [0, 0, 255, 255]);
}

#[test]
fn cb7_cover_through_com() {
    let Some(dir) = deps().seven_zip_dir.as_deref() else {
        require_or_skip(false, "FUSHI_TEST_7Z_DIR");
        return;
    };
    let work = std::env::temp_dir().join(format!("fushi_cb7_{}", std::process::id()));
    std::fs::create_dir_all(work.join("pages")).unwrap();
    std::fs::write(work.join("pages/b.png"), png(8, 8, [0, 0, 255])).unwrap();
    std::fs::write(work.join("pages/Cover.png"), png(30, 10, [0, 255, 0])).unwrap();
    let archive = work.join("book.cb7");
    let _ = std::fs::remove_file(&archive);
    let status = Command::new(dir.join("7z.exe"))
        .current_dir(&work)
        .args(["a", "-t7z", "-mx=5", "-bd", "-y"])
        .arg(&archive)
        .arg(Path::new("pages"))
        .output()
        .expect("run 7z.exe");
    assert!(status.status.success(), "7z.exe failed: {status:?}");
    let bytes = std::fs::read(&archive).unwrap();
    let bmp = thumbnail_via_com(&bytes, 256).unwrap();
    assert_eq!((bmp.width, bmp.height), (30, 10));
    assert_eq!(bmp.first_pixel_bgra, [0, 255, 0, 255]);
}

/// 一页 200×300 点、整页填红的最小 pdf（xref 偏移现算）。
fn red_pdf() -> Vec<u8> {
    let content = b"1 0 0 rg 0 0 200 300 re f";
    let objects: Vec<Vec<u8>> = vec![
        b"<< /Type /Catalog /Pages 2 0 R >>".to_vec(),
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>".to_vec(),
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 300] /Contents 4 0 R /Resources << >> >>"
            .to_vec(),
        [
            format!("<< /Length {} >>\nstream\n", content.len()).into_bytes(),
            content.to_vec(),
            b"\nendstream".to_vec(),
        ]
        .concat(),
    ];
    let mut out = b"%PDF-1.4\n".to_vec();
    let mut offsets = Vec::new();
    for (i, body) in objects.iter().enumerate() {
        offsets.push(out.len());
        out.extend(format!("{} 0 obj\n", i + 1).into_bytes());
        out.extend_from_slice(body);
        out.extend_from_slice(b"\nendobj\n");
    }
    let xref = out.len();
    out.extend(format!("xref\n0 {}\n0000000000 65535 f \n", objects.len() + 1).into_bytes());
    for o in offsets {
        out.extend(format!("{o:010} 00000 n \n").into_bytes());
    }
    out.extend(
        format!(
            "trailer\n<< /Size {} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n",
            objects.len() + 1
        )
        .into_bytes(),
    );
    out
}

#[test]
fn pdf_first_page_through_com() {
    if !require_or_skip(deps().pdfium, "FUSHI_TEST_PDFIUM_DLL") {
        return;
    }
    let bmp = thumbnail_via_com(&red_pdf(), 256).unwrap();
    assert_eq!((bmp.width, bmp.height), (171, 256));
    assert_eq!(bmp.first_pixel_bgra, [0, 0, 255, 255]);
}
