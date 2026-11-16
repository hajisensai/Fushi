//! rar / 7z：经安装目录里随包的 `7z.dll`（7-Zip 的 `CreateObject` + `IInArchive` 接口）解包。
//!
//! 7-Zip 的接口是 IUnknown 派生的普通 COM vtable（`STDMETHOD` = stdcall，x64 下与系统 ABI
//! 相同），GUID 形如 `23170F69-40C1-278A-0000-00gg00ii0000`（gg = 组号，ii = 接口号），
//! 定义见 7-Zip 源码 `CPP/7zip/IStream.h`、`IProgress.h`、`Archive/IArchive.h`。

#![allow(non_snake_case)]

use std::cell::RefCell;
use std::ffi::c_void;
use std::io::SeekFrom;
use std::rc::Rc;
use std::sync::{Mutex, OnceLock};

use windows::Win32::Foundation::{E_FAIL, E_INVALIDARG, S_OK};
use windows::core::{
    BSTR, GUID, HRESULT, IUnknown, IUnknown_Vtbl, Interface, implement, interface,
};

use crate::extract::{ArchiveBackend, ArchiveSession};
use crate::sniff::ContainerKind;
use crate::{ReadSeek, ThumbError};

// ── 7-Zip 接口声明 ───────────────────────────────────────────────────────

#[interface("23170F69-40C1-278A-0000-000300010000")]
pub unsafe trait ISequentialInStream: IUnknown {
    fn Read(&self, data: *mut c_void, size: u32, processed: *mut u32) -> HRESULT;
}

#[interface("23170F69-40C1-278A-0000-000300030000")]
pub unsafe trait IInStream: ISequentialInStream {
    fn Seek(&self, offset: i64, origin: u32, new_position: *mut u64) -> HRESULT;
}

#[interface("23170F69-40C1-278A-0000-000300020000")]
pub unsafe trait ISequentialOutStream: IUnknown {
    fn Write(&self, data: *const c_void, size: u32, processed: *mut u32) -> HRESULT;
}

#[interface("23170F69-40C1-278A-0000-000000050000")]
pub unsafe trait IProgress: IUnknown {
    fn SetTotal(&self, total: u64) -> HRESULT;
    fn SetCompleted(&self, complete: *const u64) -> HRESULT;
}

#[interface("23170F69-40C1-278A-0000-000600100000")]
pub unsafe trait IArchiveOpenCallback: IUnknown {
    fn SetTotal(&self, files: *const u64, bytes: *const u64) -> HRESULT;
    fn SetCompleted(&self, files: *const u64, bytes: *const u64) -> HRESULT;
}

#[interface("23170F69-40C1-278A-0000-000600200000")]
pub unsafe trait IArchiveExtractCallback: IProgress {
    fn GetStream(&self, index: u32, out_stream: *mut *mut c_void, ask_mode: i32) -> HRESULT;
    fn PrepareOperation(&self, ask_mode: i32) -> HRESULT;
    fn SetOperationResult(&self, op_result: i32) -> HRESULT;
}

#[interface("23170F69-40C1-278A-0000-000600600000")]
pub unsafe trait IInArchive: IUnknown {
    fn Open(
        &self,
        stream: *mut c_void,
        max_check_start: *const u64,
        callback: *mut c_void,
    ) -> HRESULT;
    fn Close(&self) -> HRESULT;
    fn GetNumberOfItems(&self, count: *mut u32) -> HRESULT;
    fn GetProperty(&self, index: u32, prop_id: u32, value: *mut RawPropVariant) -> HRESULT;
    fn Extract(
        &self,
        indices: *const u32,
        count: u32,
        test_mode: i32,
        callback: *mut c_void,
    ) -> HRESULT;
    fn GetArchiveProperty(&self, prop_id: u32, value: *mut RawPropVariant) -> HRESULT;
    fn GetNumberOfProperties(&self, count: *mut u32) -> HRESULT;
    fn GetPropertyInfo(
        &self,
        index: u32,
        name: *mut *mut u16,
        prop_id: *mut u32,
        vt: *mut u16,
    ) -> HRESULT;
    fn GetNumberOfArchiveProperties(&self, count: *mut u32) -> HRESULT;
    fn GetArchivePropertyInfo(
        &self,
        index: u32,
        name: *mut *mut u16,
        prop_id: *mut u32,
        vt: *mut u16,
    ) -> HRESULT;
}

#[interface("23170F69-40C1-278A-0000-000600030000")]
pub unsafe trait ISetProperties: IUnknown {
    fn SetProperties(
        &self,
        names: *const *const u16,
        values: *const RawPropVariant,
        count: u32,
    ) -> HRESULT;
}

/// 与 Win32 `PROPVARIANT` 同布局（x64：8 字节头 + 16 字节联合体）。只用到 BSTR / BOOL / UI4 / UI8。
#[repr(C)]
#[derive(Default)]
pub struct RawPropVariant {
    pub vt: u16,
    pub reserved: [u16; 3],
    pub data: [u64; 2],
}

const VT_EMPTY: u16 = 0;
const VT_BSTR: u16 = 8;
const VT_BOOL: u16 = 11;
const VT_UI4: u16 = 19;

const KPID_PATH: u32 = 3;
const KPID_IS_DIR: u32 = 6;

const ASK_MODE_EXTRACT: i32 = 0;
const OP_RESULT_OK: i32 = 0;

impl RawPropVariant {
    /// 取 BSTR 值并释放（PropVariantClear 的 BSTR 分支）。
    fn take_string(&mut self) -> Option<String> {
        if self.vt != VT_BSTR {
            self.clear();
            return None;
        }
        let ptr = self.data[0] as *const u16;
        self.vt = VT_EMPTY;
        self.data = [0; 2];
        if ptr.is_null() {
            return None;
        }
        // SAFETY: 7z.dll 用 SysAllocString 分配了这个 BSTR，所有权交给调用方；BSTR 的 Drop 释放它。
        let bstr = unsafe { BSTR::from_raw(ptr) };
        Some(bstr.to_string())
    }

    fn take_bool(&mut self) -> bool {
        let v = self.vt == VT_BOOL && (self.data[0] as u16) != 0;
        self.clear();
        v
    }

    fn clear(&mut self) {
        if self.vt == VT_BSTR && self.data[0] != 0 {
            // SAFETY: 同 take_string。
            drop(unsafe { BSTR::from_raw(self.data[0] as *const u16) });
        }
        self.vt = VT_EMPTY;
        self.data = [0; 2];
    }
}

impl Drop for RawPropVariant {
    fn drop(&mut self) {
        self.clear();
    }
}

// ── 我们实现给 7z.dll 调的对象 ───────────────────────────────────────────

#[implement(IInStream, ISequentialInStream)]
struct InStream {
    // Mutex：7z 的解码器理论上可以从别的线程读输入（已用 mt=1 关多线程，这里再兜一层）。
    reader: Mutex<Box<dyn ReadSeek>>,
}

impl ISequentialInStream_Impl for InStream_Impl {
    unsafe fn Read(&self, data: *mut c_void, size: u32, processed: *mut u32) -> HRESULT {
        if !processed.is_null() {
            *processed = 0;
        }
        if size == 0 {
            return S_OK;
        }
        if data.is_null() {
            return E_INVALIDARG;
        }
        let Ok(mut reader) = self.reader.lock() else {
            return E_FAIL;
        };
        let buf = std::slice::from_raw_parts_mut(data.cast::<u8>(), size as usize);
        match reader.read(buf) {
            Ok(n) => {
                if !processed.is_null() {
                    *processed = n as u32;
                }
                S_OK
            }
            Err(_) => E_FAIL,
        }
    }
}

impl IInStream_Impl for InStream_Impl {
    unsafe fn Seek(&self, offset: i64, origin: u32, new_position: *mut u64) -> HRESULT {
        let pos = match origin {
            0 => match u64::try_from(offset) {
                Ok(o) => SeekFrom::Start(o),
                Err(_) => return E_INVALIDARG,
            },
            1 => SeekFrom::Current(offset),
            2 => SeekFrom::End(offset),
            _ => return E_INVALIDARG,
        };
        let Ok(mut reader) = self.reader.lock() else {
            return E_FAIL;
        };
        match reader.seek(pos) {
            Ok(p) => {
                if !new_position.is_null() {
                    *new_position = p;
                }
                S_OK
            }
            Err(_) => E_FAIL,
        }
    }
}

#[implement(IArchiveOpenCallback)]
struct OpenCallback;

impl IArchiveOpenCallback_Impl for OpenCallback_Impl {
    unsafe fn SetTotal(&self, _files: *const u64, _bytes: *const u64) -> HRESULT {
        S_OK
    }
    unsafe fn SetCompleted(&self, _files: *const u64, _bytes: *const u64) -> HRESULT {
        S_OK
    }
}

/// 抽取目标条目的共享状态。
struct ExtractState {
    target: u32,
    max: u64,
    data: Vec<u8>,
    overflow: bool,
    result: Option<i32>,
}

#[implement(ISequentialOutStream)]
struct OutStream {
    state: Rc<RefCell<ExtractState>>,
}

impl ISequentialOutStream_Impl for OutStream_Impl {
    unsafe fn Write(&self, data: *const c_void, size: u32, processed: *mut u32) -> HRESULT {
        if !processed.is_null() {
            *processed = 0;
        }
        let mut st = self.state.borrow_mut();
        if st.data.len() as u64 + size as u64 > st.max {
            st.overflow = true;
            return E_FAIL;
        }
        if size > 0 {
            if data.is_null() {
                return E_INVALIDARG;
            }
            st.data
                .extend_from_slice(std::slice::from_raw_parts(data.cast::<u8>(), size as usize));
        }
        if !processed.is_null() {
            *processed = size;
        }
        S_OK
    }
}

#[implement(IArchiveExtractCallback, IProgress)]
struct ExtractCallback {
    state: Rc<RefCell<ExtractState>>,
}

impl IProgress_Impl for ExtractCallback_Impl {
    unsafe fn SetTotal(&self, _total: u64) -> HRESULT {
        S_OK
    }
    unsafe fn SetCompleted(&self, _complete: *const u64) -> HRESULT {
        S_OK
    }
}

impl IArchiveExtractCallback_Impl for ExtractCallback_Impl {
    unsafe fn GetStream(&self, index: u32, out_stream: *mut *mut c_void, ask_mode: i32) -> HRESULT {
        if out_stream.is_null() {
            return E_INVALIDARG;
        }
        *out_stream = std::ptr::null_mut();
        if ask_mode != ASK_MODE_EXTRACT || index != self.state.borrow().target {
            return S_OK;
        }
        let stream: ISequentialOutStream = OutStream {
            state: self.state.clone(),
        }
        .into();
        *out_stream = stream.into_raw();
        S_OK
    }
    unsafe fn PrepareOperation(&self, _ask_mode: i32) -> HRESULT {
        S_OK
    }
    unsafe fn SetOperationResult(&self, op_result: i32) -> HRESULT {
        self.state.borrow_mut().result = Some(op_result);
        S_OK
    }
}

// ── 加载 7z.dll ─────────────────────────────────────────────────────────

type CreateObjectFn = unsafe extern "system" fn(
    clsid: *const GUID,
    iid: *const GUID,
    out: *mut *mut c_void,
) -> HRESULT;

/// 7z.dll 相对安装目录的位置：`tools/bundle_7za.ps1` 把整套 7-Zip（7z.exe + 7z.dll）放在
/// `{app}\7za\` 下（app 的离线解压也用它）。
pub const SEVEN_ZIP_DLL: &str = "7za\\7z.dll";

/// 已加载的 7z.dll（只存 `CreateObject` 指针，模块不释放）。
pub struct SevenZip {
    create_object: CreateObjectFn,
}

const CLSID_FORMAT_RAR: GUID = GUID::from_u128(0x23170F69_40C1_278A_1000_000110030000);
const CLSID_FORMAT_RAR5: GUID = GUID::from_u128(0x23170F69_40C1_278A_1000_000110CC0000);
const CLSID_FORMAT_7Z: GUID = GUID::from_u128(0x23170F69_40C1_278A_1000_000110070000);

impl SevenZip {
    /// 进程内单例；第一次调用时按 [`super::dependency_dir`] 加载。
    pub fn get() -> Result<&'static SevenZip, ThumbError> {
        static INSTANCE: OnceLock<Result<SevenZip, ThumbError>> = OnceLock::new();
        INSTANCE
            .get_or_init(|| {
                let module = super::load_bundled_library(SEVEN_ZIP_DLL)?;
                let f = super::proc_address(module, b"CreateObject\0")?;
                // SAFETY: CreateObject 的签名见 7-Zip `CPP/7zip/Archive/DllExports2.cpp`。
                let create_object: CreateObjectFn = unsafe { std::mem::transmute(f) };
                Ok(SevenZip { create_object })
            })
            .as_ref()
            .map_err(Clone::clone)
    }

    fn create_archive(&self, kind: ContainerKind) -> Result<IInArchive, ThumbError> {
        let clsid = match kind {
            ContainerKind::Rar4 => CLSID_FORMAT_RAR,
            ContainerKind::Rar5 => CLSID_FORMAT_RAR5,
            ContainerKind::SevenZip => CLSID_FORMAT_7Z,
            _ => return Err(ThumbError::UnknownFormat),
        };
        let mut out: *mut c_void = std::ptr::null_mut();
        // SAFETY: out 接收一个已 AddRef 的 IInArchive。
        let hr = unsafe { (self.create_object)(&clsid, &IInArchive::IID, &mut out) };
        if hr.is_err() || out.is_null() {
            return Err(ThumbError::MissingDependency(format!(
                "7z.dll CreateObject failed: {hr:?}"
            )));
        }
        // SAFETY: out 是 CreateObject 交来的 IInArchive，所有权转给 Rust 包装。
        Ok(unsafe { IInArchive::from_raw(out) })
    }
}

/// 关掉 7z 解码的多线程：输入流只在调用线程上读（资源管理器的 `IStream` 可能是套间绑定的）。
fn force_single_thread(archive: &IInArchive) {
    let Ok(props) = archive.cast::<ISetProperties>() else {
        return; // rar handler 不支持 ISetProperties，它本来就单线程。
    };
    let name: Vec<u16> = "mt\0".encode_utf16().collect();
    let names = [name.as_ptr()];
    let value = RawPropVariant {
        vt: VT_UI4,
        reserved: [0; 3],
        data: [1, 0],
    };
    // SAFETY: names / value 在调用期间存活；失败无害（只是可能多线程解码）。
    let _ = unsafe { props.SetProperties(names.as_ptr(), &value, 1) };
}

impl ArchiveBackend for SevenZip {
    fn open(
        &self,
        kind: ContainerKind,
        reader: Box<dyn ReadSeek>,
    ) -> Result<Box<dyn ArchiveSession>, ThumbError> {
        let archive = self.create_archive(kind)?;
        force_single_thread(&archive);
        let stream: IInStream = InStream {
            reader: Mutex::new(reader),
        }
        .into();
        let callback: IArchiveOpenCallback = OpenCallback.into();
        let max_check: u64 = 1 << 20;
        // SAFETY: 两个接口指针在调用期间存活，7z 需要时自行 AddRef。
        let hr = unsafe { archive.Open(stream.as_raw(), &max_check, callback.as_raw()) };
        if hr != S_OK {
            return Err(ThumbError::Corrupt(format!("7z.dll Open failed: {hr:?}")));
        }
        let mut count = 0u32;
        // SAFETY: count 是有效输出指针。
        unsafe { archive.GetNumberOfItems(&mut count) }
            .ok()
            .map_err(|e| ThumbError::Corrupt(e.to_string()))?;
        let mut names = Vec::with_capacity(count as usize);
        for i in 0..count {
            let mut path = RawPropVariant::default();
            let mut is_dir = RawPropVariant::default();
            // SAFETY: 输出 PROPVARIANT 由我们持有并在 Drop 里释放。
            unsafe {
                let _ = archive.GetProperty(i, KPID_PATH, &mut path);
                let _ = archive.GetProperty(i, KPID_IS_DIR, &mut is_dir);
            }
            let mut name = path.take_string().unwrap_or_default().replace('\\', "/");
            if is_dir.take_bool() {
                name.push('/');
            }
            names.push(name);
        }
        Ok(Box::new(SevenZipSession { archive, names }))
    }
}

struct SevenZipSession {
    archive: IInArchive,
    names: Vec<String>,
}

impl ArchiveSession for SevenZipSession {
    fn names(&self) -> &[String] {
        &self.names
    }

    fn read(&mut self, index: usize, max: u64) -> Result<Vec<u8>, ThumbError> {
        let target = u32::try_from(index).map_err(|_| ThumbError::NoCover)?;
        let state = Rc::new(RefCell::new(ExtractState {
            target,
            max,
            data: Vec::new(),
            overflow: false,
            result: None,
        }));
        let callback: IArchiveExtractCallback = ExtractCallback {
            state: state.clone(),
        }
        .into();
        let indices = [target];
        // SAFETY: indices / callback 在调用期间存活。
        let hr = unsafe {
            self.archive
                .Extract(indices.as_ptr(), 1, 0, callback.as_raw())
        };
        drop(callback);
        let st = state.borrow();
        if st.overflow {
            return Err(ThumbError::Corrupt(format!(
                "entry larger than {max} bytes"
            )));
        }
        if hr != S_OK || st.result != Some(OP_RESULT_OK) {
            return Err(ThumbError::Corrupt(format!(
                "7z.dll Extract failed: {hr:?} / op {:?}",
                st.result
            )));
        }
        Ok(st.data.clone())
    }
}

impl Drop for SevenZipSession {
    fn drop(&mut self) {
        // SAFETY: Close 之后不再用这个 archive。
        let _ = unsafe { self.archive.Close() };
    }
}
