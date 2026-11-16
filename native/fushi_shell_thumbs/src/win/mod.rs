//! Windows 侧：COM 服务器（跑在 explorer.exe 里，只转交路径）、宿主进程客户端、
//! 宿主进程用的随包 DLL（7z.dll / pdfium.dll）加载。

pub mod bitmap;
pub mod com;
pub mod host_client;
pub mod pdfium;
pub mod sevenzip;

use std::path::{Path, PathBuf};
use std::sync::OnceLock;

use windows::Win32::Foundation::HMODULE;
use windows::Win32::System::LibraryLoader::{
    GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS, GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
    GetModuleFileNameW, GetModuleHandleExW, GetProcAddress, LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR,
    LOAD_LIBRARY_SEARCH_SYSTEM32, LoadLibraryExW,
};
use windows::core::PCWSTR;

use crate::extract::{ArchiveBackend, Backends, PdfBackend, extract_thumbnail};
use crate::{ThumbError, Thumbnail};

static DEPENDENCY_DIR_OVERRIDE: OnceLock<PathBuf> = OnceLock::new();

/// 测试专用：把「随包 DLL 所在目录」指到别处（生产上就是本模块所在的安装目录）。
/// 只能在第一次加载 7z.dll / pdfium.dll 之前设，之后设不再生效。
#[doc(hidden)]
pub fn set_dependency_dir(dir: PathBuf) -> bool {
    DEPENDENCY_DIR_OVERRIDE.set(dir).is_ok()
}

/// 随包 DLL 所在目录：本模块（fushi_shell_thumbs.dll）所在目录，即 `{app}`。
pub fn dependency_dir() -> Option<PathBuf> {
    if let Some(dir) = DEPENDENCY_DIR_OVERRIDE.get() {
        return Some(dir.clone());
    }
    static ANCHOR: u8 = 0;
    let mut module = HMODULE::default();
    // SAFETY: FROM_ADDRESS 模式下第二个参数是本模块内任一地址；UNCHANGED_REFCOUNT 不加引用计数。
    unsafe {
        GetModuleHandleExW(
            GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
            PCWSTR(&ANCHOR as *const u8 as *const u16),
            &mut module,
        )
        .ok()?;
    }
    let mut buf = vec![0u16; 32_768];
    // SAFETY: buf 可写，长度由切片给出。
    let len = unsafe { GetModuleFileNameW(Some(module), &mut buf) } as usize;
    if len == 0 || len >= buf.len() {
        return None;
    }
    let path = PathBuf::from(String::from_utf16_lossy(&buf[..len]));
    path.parent().map(Path::to_path_buf)
}

/// 按绝对路径加载随包 DLL，并只在它自己的目录 + System32 里解析它的依赖（不走 PATH / CWD）。
/// 模块故意不释放：它活到宿主进程结束。
pub(crate) fn load_bundled_library(file_name: &str) -> Result<HMODULE, ThumbError> {
    let dir = dependency_dir()
        .ok_or_else(|| ThumbError::MissingDependency("cannot locate module directory".into()))?;
    let path = dir.join(file_name);
    if !path.is_file() {
        return Err(ThumbError::MissingDependency(path.display().to_string()));
    }
    let wide: Vec<u16> = path
        .as_os_str()
        .to_string_lossy()
        .encode_utf16()
        .chain(std::iter::once(0))
        .collect();
    // SAFETY: wide 以 NUL 结尾、在调用期间存活。
    unsafe {
        LoadLibraryExW(
            PCWSTR(wide.as_ptr()),
            None,
            LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32,
        )
    }
    .map_err(|e| ThumbError::MissingDependency(format!("{}: {e}", path.display())))
}

/// 取导出函数地址；`name` 必须以 NUL 结尾。
pub(crate) fn proc_address(
    module: HMODULE,
    name: &'static [u8],
) -> Result<unsafe extern "system" fn() -> isize, ThumbError> {
    debug_assert_eq!(name.last(), Some(&0));
    // SAFETY: name 以 NUL 结尾。
    unsafe { GetProcAddress(module, windows::core::PCSTR(name.as_ptr())) }.ok_or_else(|| {
        ThumbError::MissingDependency(format!(
            "export {} not found",
            String::from_utf8_lossy(&name[..name.len() - 1])
        ))
    })
}

/// 宿主进程里的真正工作：打开文件、按内容识别、用随包 7z.dll / pdfium.dll 取封面。
/// 缺哪个 DLL，对应格式就报 [`ThumbError::MissingDependency`]。
pub fn thumbnail_for_path(path: &Path, cx: u32) -> Result<Thumbnail, ThumbError> {
    let file = std::fs::File::open(path)?;
    let seven_zip = sevenzip::SevenZip::get().ok();
    let pdfium = pdfium::Pdfium::get().ok();
    let backends = Backends {
        archive: seven_zip.map(|s| s as &dyn ArchiveBackend),
        pdf: pdfium.map(|p| p as &dyn PdfBackend),
    };
    extract_thumbnail(Box::new(std::io::BufReader::new(file)), cx, backends)
}
