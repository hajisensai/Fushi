//! 全 crate 共用的 C ABI 约定：线程局部错误、字节缓冲移交、panic 隔离。

use std::cell::RefCell;
use std::ffi::{c_char, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};

thread_local! {
    static LAST_ERROR: RefCell<Option<String>> = const { RefCell::new(None) };
}

pub(crate) fn set_last_error(msg: String) {
    LAST_ERROR.with(|e| *e.borrow_mut() = Some(msg));
}

pub(crate) fn clear_last_error() {
    LAST_ERROR.with(|e| *e.borrow_mut() = None);
}

pub(crate) fn panic_message(p: Box<dyn std::any::Any + Send>) -> String {
    if let Some(s) = p.downcast_ref::<&str>() {
        format!("panic: {s}")
    } else if let Some(s) = p.downcast_ref::<String>() {
        format!("panic: {s}")
    } else {
        "panic".to_string()
    }
}

/// 把 `bytes` 交给调用方：返回指针，`*out_len` 写长度；调用方用 `fwc_bytes_free(ptr, len)` 还。
/// 空缓冲返回 NULL、长度 0（不分配）。
///
/// # Safety
/// `out_len` 非 NULL 且可写。
pub(crate) unsafe fn hand_out(bytes: Vec<u8>, out_len: *mut usize) -> *mut u8 {
    if out_len.is_null() {
        return std::ptr::null_mut();
    }
    if bytes.is_empty() {
        *out_len = 0;
        return std::ptr::null_mut();
    }
    let boxed = bytes.into_boxed_slice();
    *out_len = boxed.len();
    Box::into_raw(boxed) as *mut u8
}

/// `(ptr, len)` → `&[u8]`；NULL 或 0 长度为空切片。
///
/// # Safety
/// 非 NULL 时 `ptr` 指向 `len` 个可读字节，且在返回切片的生命周期内不被改写。
pub(crate) unsafe fn bytes_in<'a>(ptr: *const u8, len: usize) -> &'a [u8] {
    if ptr.is_null() || len == 0 {
        &[]
    } else {
        std::slice::from_raw_parts(ptr, len)
    }
}

/// `(ptr, len)` 的 UTF-8 → `&str`；非法 UTF-8 返回 None。
///
/// # Safety
/// 同 [`bytes_in`]。
pub(crate) unsafe fn str_in<'a>(ptr: *const u8, len: usize) -> Option<&'a str> {
    std::str::from_utf8(bytes_in(ptr, len)).ok()
}

fn into_c_string(s: String) -> *mut c_char {
    match CString::new(s) {
        Ok(c) => c.into_raw(),
        Err(e) => {
            let mut bytes = e.into_vec();
            bytes.retain(|b| *b != 0);
            CString::new(bytes)
                .map(CString::into_raw)
                .unwrap_or(std::ptr::null_mut())
        }
    }
}

/// 库版本（静态字符串，不要 free）。引擎序列化缓存键的一部分。
#[no_mangle]
pub extern "C" fn fwc_version() -> *const c_char {
    concat!(env!("CARGO_PKG_VERSION"), "\0").as_ptr() as *const c_char
}

/// 释放本库经 `(ptr, out_len)` 交出的任意字节缓冲。NULL 为 no-op。
///
/// # Safety
/// `ptr` / `len` 必须原样来自本库。
#[no_mangle]
pub unsafe extern "C" fn fwc_bytes_free(ptr: *mut u8, len: usize) {
    if !ptr.is_null() {
        let _ = catch_unwind(AssertUnwindSafe(|| {
            drop(Box::from_raw(std::ptr::slice_from_raw_parts_mut(ptr, len)));
        }));
    }
}

/// 释放 `fwc_last_error` 返回的字符串。NULL 为 no-op。
///
/// # Safety
/// `s` 必须是 `fwc_last_error` 返回、尚未释放的指针。
#[no_mangle]
pub unsafe extern "C" fn fwc_string_free(s: *mut c_char) {
    if !s.is_null() {
        let _ = catch_unwind(AssertUnwindSafe(|| drop(CString::from_raw(s))));
    }
}

/// 本线程最近一次失败的原因；无则 NULL。调用方用 `fwc_string_free` 释放。
#[no_mangle]
pub extern "C" fn fwc_last_error() -> *mut c_char {
    catch_unwind(|| LAST_ERROR.with(|e| e.borrow().clone()))
        .ok()
        .flatten()
        .map(into_c_string)
        .unwrap_or(std::ptr::null_mut())
}
