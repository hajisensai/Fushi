//! COM 进程内服务器：`DllGetClassObject` / `DllCanUnloadNow` + 缩略图处理器对象。
//!
//! 处理器跑在 explorer.exe 里（`DisableProcessIsolation=1`，原因见 [`super::host_client`]），
//! 所以它自己**不解析任何文件**：只拿到路径，交给一次性的宿主进程，再把校验过的像素做成
//! HBITMAP。

use std::cell::RefCell;
use std::ffi::c_void;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};

use windows::Win32::Foundation::{
    CLASS_E_CLASSNOTAVAILABLE, CLASS_E_NOAGGREGATION, E_FAIL, E_INVALIDARG, E_POINTER,
    E_UNEXPECTED, S_FALSE, S_OK,
};
use windows::Win32::Graphics::Gdi::HBITMAP;
use windows::Win32::System::Com::{IClassFactory, IClassFactory_Impl};
use windows::Win32::UI::Shell::PropertiesSystem::{IInitializeWithFile, IInitializeWithFile_Impl};
use windows::Win32::UI::Shell::{
    IThumbnailProvider, IThumbnailProvider_Impl, WTS_ALPHATYPE, WTSAT_RGB,
};
use windows::core::{BOOL, GUID, HRESULT, Interface, PCWSTR, Ref, implement};

use super::bitmap::to_hbitmap;
use super::host_client::request_thumbnail;
use crate::THUMBNAIL_PROVIDER_CLSID;

/// 活着的 COM 对象数 + LockServer 计数；为 0 时 `DllCanUnloadNow` 才允许卸载。
static LIVE: AtomicUsize = AtomicUsize::new(0);

pub fn clsid() -> GUID {
    let s = THUMBNAIL_PROVIDER_CLSID.trim_matches(|c| c == '{' || c == '}');
    GUID::try_from(s).expect("THUMBNAIL_PROVIDER_CLSID is a valid GUID")
}

struct LiveToken;

impl LiveToken {
    fn new() -> Self {
        LIVE.fetch_add(1, Ordering::SeqCst);
        LiveToken
    }
}

impl Drop for LiveToken {
    fn drop(&mut self) {
        LIVE.fetch_sub(1, Ordering::SeqCst);
    }
}

#[implement(IInitializeWithFile, IThumbnailProvider)]
pub struct ThumbnailProvider {
    path: RefCell<Option<PathBuf>>,
    _live: LiveToken,
}

impl ThumbnailProvider {
    pub fn new() -> Self {
        ThumbnailProvider {
            path: RefCell::new(None),
            _live: LiveToken::new(),
        }
    }
}

impl Default for ThumbnailProvider {
    fn default() -> Self {
        Self::new()
    }
}

impl IInitializeWithFile_Impl for ThumbnailProvider_Impl {
    fn Initialize(&self, pszfilepath: &PCWSTR, _grfmode: u32) -> windows::core::Result<()> {
        if pszfilepath.is_null() {
            return Err(E_INVALIDARG.into());
        }
        // SAFETY: 非空、以 NUL 结尾的宽字符串（调用约定）。
        let path = unsafe { pszfilepath.to_string() }.map_err(|_| E_INVALIDARG)?;
        let mut slot = self.path.borrow_mut();
        if slot.is_some() {
            // 规范：同一个对象只能初始化一次。
            return Err(E_UNEXPECTED.into());
        }
        *slot = Some(PathBuf::from(path));
        Ok(())
    }
}

impl IThumbnailProvider_Impl for ThumbnailProvider_Impl {
    // 签名由 COM 接口定死（不能标 unsafe）；两个输出指针在解引用前判空。
    #[allow(clippy::not_unsafe_ptr_arg_deref)]
    fn GetThumbnail(
        &self,
        cx: u32,
        phbmp: *mut HBITMAP,
        pdwalpha: *mut WTS_ALPHATYPE,
    ) -> windows::core::Result<()> {
        if phbmp.is_null() || pdwalpha.is_null() {
            return Err(E_POINTER.into());
        }
        let path = self
            .path
            .borrow()
            .clone()
            .ok_or_else(|| windows::core::Error::from(E_UNEXPECTED))?;
        // 任何 panic 都挡在 FFI 边界内，回 E_FAIL 让资源管理器退回图标。
        let result = catch_unwind(AssertUnwindSafe(|| {
            request_thumbnail(&path, cx).and_then(|t| to_hbitmap(&t))
        }));
        match result {
            Ok(Ok(bmp)) => {
                // SAFETY: 两个输出指针已判空；HBITMAP 所有权交给调用方。
                unsafe {
                    *phbmp = bmp;
                    *pdwalpha = WTSAT_RGB;
                }
                Ok(())
            }
            _ => Err(E_FAIL.into()),
        }
    }
}

#[implement(IClassFactory)]
struct ClassFactory {
    _live: LiveToken,
}

impl IClassFactory_Impl for ClassFactory_Impl {
    fn CreateInstance(
        &self,
        punkouter: Ref<windows::core::IUnknown>,
        riid: *const GUID,
        ppvobject: *mut *mut c_void,
    ) -> windows::core::Result<()> {
        if ppvobject.is_null() || riid.is_null() {
            return Err(E_POINTER.into());
        }
        // SAFETY: 已判空。
        unsafe { *ppvobject = std::ptr::null_mut() };
        if punkouter.is_some() {
            return Err(CLASS_E_NOAGGREGATION.into());
        }
        let unknown: windows::core::IUnknown = ThumbnailProvider::new().into();
        // SAFETY: riid / ppvobject 有效；query 失败时 ppvobject 保持 null。
        unsafe { unknown.query(riid, ppvobject) }.ok()
    }

    fn LockServer(&self, flock: BOOL) -> windows::core::Result<()> {
        if flock.as_bool() {
            LIVE.fetch_add(1, Ordering::SeqCst);
        } else {
            LIVE.fetch_sub(1, Ordering::SeqCst);
        }
        Ok(())
    }
}

/// COM 入口：只认本处理器的 CLSID。
///
/// # Safety
/// 由 COM 运行时按约定调用：三个指针都有效。
#[no_mangle]
pub unsafe extern "system" fn DllGetClassObject(
    rclsid: *const GUID,
    riid: *const GUID,
    ppv: *mut *mut c_void,
) -> HRESULT {
    if ppv.is_null() || rclsid.is_null() || riid.is_null() {
        return E_POINTER;
    }
    *ppv = std::ptr::null_mut();
    if *rclsid != clsid() {
        return CLASS_E_CLASSNOTAVAILABLE;
    }
    let factory: IClassFactory = ClassFactory {
        _live: LiveToken::new(),
    }
    .into();
    factory.query(riid, ppv)
}

/// COM 入口：没有活对象、没有 LockServer 时允许卸载本 DLL。
#[no_mangle]
pub extern "system" fn DllCanUnloadNow() -> HRESULT {
    if LIVE.load(Ordering::SeqCst) == 0 {
        S_OK
    } else {
        S_FALSE
    }
}
