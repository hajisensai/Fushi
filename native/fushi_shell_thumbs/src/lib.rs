//! Fushi 的 Windows 资源管理器封面缩略图（`IThumbnailProvider`）。
//!
//! 资源管理器里的书 / 漫画文件（epub、cbz、cbr、cb7、pdf）显示封面，而不是 `Fushi.Book` 的
//! exe 图标。两个产物（设计与边界见 `README.md`）：
//!
//! * `fushi_shell_thumbs.dll`：COM 进程内服务器，安装器按用户注册。它跑在 explorer.exe 里
//!   （HKCU 注册的处理器进不了系统的 COM Surrogate 隔离进程，见 `win::host_client`），所以
//!   **不解析任何文件**，只把路径交给宿主进程，限时、限内存地取回像素并校验。
//! * `fushi_shell_thumbs_host.exe`：一次性的宿主进程，真正解析不可信文件。容器按**内容**识别
//!   （不看扩展名，后缀写错的 cbr 照样出封面）；zip / epub 纯 Rust 解，rar / 7z 走安装目录里
//!   随包的 `7za\7z.dll`，pdf 走随包的 `pdfium.dll` 渲首页（都按绝对路径加载，缺了只是该格式没封面）。
//! * 所有 COM 入口用 `catch_unwind` 兜住，失败一律回 `E_FAIL`，资源管理器回退到图标。

use std::io::{Read, Seek};

pub mod cover;
pub mod extract;
pub mod image_out;
pub mod sniff;
pub mod wire;

#[cfg(windows)]
pub mod win;

#[cfg(windows)]
pub use win::com::{DllCanUnloadNow, DllGetClassObject};

// 让 cargo 把 worktree 根记进新鲜度指纹（见仓库根 .cargo/config.toml）；值不进产物。
const _: Option<&str> = option_env!("FUSHI_WORKTREE_ROOT");

/// 资源管理器缩略图处理器的 CLSID。安装器 `fushi/windows/installer/fushi.iss` 的
/// `FushiThumbClsid` 必须与它逐字一致（守卫：`tests/registration_contract.rs`）。
pub const THUMBNAIL_PROVIDER_CLSID: &str = "{7CEC7E60-07B9-4389-BFC1-7B83D334456E}";

/// 可读可寻址的字节源（资源管理器给的 `IStream`、测试里的 `Cursor`）。
pub trait ReadSeek: Read + Seek {}
impl<T: Read + Seek> ReadSeek for T {}

/// 自上而下、每像素 4 字节 BGRA（alpha 恒为 255，透明处已垫白）的缩略图。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Thumbnail {
    pub width: u32,
    pub height: u32,
    pub bgra: Vec<u8>,
}

/// 缩略图提取失败的原因（只用于日志 / 测试断言；对外一律映射成 `E_FAIL`）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ThumbError {
    /// 不认识的容器（不是 zip / epub / rar / 7z / pdf）。
    UnknownFormat,
    /// 容器里找不到能当封面的图。
    NoCover,
    /// 容器或图片损坏 / 超出体积上限。
    Corrupt(String),
    /// 需要的随包 DLL（7z.dll / pdfium.dll）不在或加载失败。
    MissingDependency(String),
    Io(String),
}

impl std::fmt::Display for ThumbError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ThumbError::UnknownFormat => write!(f, "unknown container format"),
            ThumbError::NoCover => write!(f, "no cover image found"),
            ThumbError::Corrupt(m) => write!(f, "corrupt input: {m}"),
            ThumbError::MissingDependency(m) => write!(f, "missing dependency: {m}"),
            ThumbError::Io(m) => write!(f, "io error: {m}"),
        }
    }
}

impl std::error::Error for ThumbError {}

impl From<std::io::Error> for ThumbError {
    fn from(e: std::io::Error) -> Self {
        ThumbError::Io(e.to_string())
    }
}
