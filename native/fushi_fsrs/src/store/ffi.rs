//! srs.db 的 C ABI（Dart 绑定：packages/fushi_srs/lib/src/ffi/fushi_fsrs_bindings.dart）。
//!
//! 约定与 lib.rs 其余部分相同：返回 i32 状态（0 成功，负数失败），失败时 `*error_out` 是新分配的
//! C 字符串（用 `ffsrs_free_string` 释放）；Rust 分配的字节用 `ffsrs_free_bytes` 释放；panic 一律
//! 接住转成 -100。句柄是 `SrsCore` 的裸指针，线程安全，可在任意 isolate 上用。

use std::ffi::{c_char, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::Path;

use super::SrsCore;

pub const STORE_OK: i32 = 0;
pub const STORE_ERROR: i32 = -1;
pub const STORE_BAD_ARGUMENT: i32 = -2;
pub const STORE_PANIC: i32 = -100;

fn set_error(error_out: *mut *mut c_char, message: &str) {
    if !error_out.is_null() {
        let text = CString::new(message.replace('\0', " ")).unwrap_or_default();
        unsafe { *error_out = text.into_raw() };
    }
}

fn bytes<'a>(ptr: *const u8, len: usize) -> Option<&'a [u8]> {
    if len == 0 {
        Some(&[])
    } else if ptr.is_null() {
        None
    } else {
        Some(unsafe { std::slice::from_raw_parts(ptr, len) })
    }
}

fn utf8<'a>(ptr: *const u8, len: usize) -> Result<&'a str, String> {
    let b = bytes(ptr, len).ok_or_else(|| "null string".to_string())?;
    std::str::from_utf8(b).map_err(|e| e.to_string())
}

/// 跑一段带句柄的操作，统一处理空指针、错误与 panic。
fn run(
    core: *const SrsCore,
    error_out: *mut *mut c_char,
    body: impl FnOnce(&SrsCore) -> Result<(), String>,
) -> i32 {
    if core.is_null() {
        set_error(error_out, "null srs core");
        return STORE_BAD_ARGUMENT;
    }
    let core = unsafe { &*core };
    match catch_unwind(AssertUnwindSafe(|| body(core))) {
        Ok(Ok(())) => STORE_OK,
        Ok(Err(e)) => {
            set_error(error_out, &e);
            STORE_ERROR
        }
        Err(_) => {
            set_error(error_out, "panic in srs store");
            STORE_PANIC
        }
    }
}

fn hand_out(buf: Vec<u8>, out: *mut *mut u8, out_len: *mut usize) {
    let boxed = buf.into_boxed_slice();
    unsafe {
        *out_len = boxed.len();
        *out = Box::into_raw(boxed) as *mut u8;
    }
}

/// 打开 / 新建 srs.db。成功写 `*core_out`；用 [ffsrs_store_close] 关闭。
#[no_mangle]
pub extern "C" fn ffsrs_store_open(
    path: *const u8,
    path_len: usize,
    core_out: *mut *mut SrsCore,
    error_out: *mut *mut c_char,
) -> i32 {
    if core_out.is_null() {
        set_error(error_out, "null core_out");
        return STORE_BAD_ARGUMENT;
    }
    let outcome = catch_unwind(AssertUnwindSafe(|| -> Result<SrsCore, String> {
        SrsCore::open(Path::new(utf8(path, path_len)?))
    }));
    match outcome {
        Ok(Ok(core)) => {
            unsafe { *core_out = Box::into_raw(Box::new(core)) };
            STORE_OK
        }
        Ok(Err(e)) => {
            set_error(error_out, &e);
            STORE_ERROR
        }
        Err(_) => {
            set_error(error_out, "panic in srs store open");
            STORE_PANIC
        }
    }
}

/// 关闭（NULL 无操作）。之后句柄不可再用。
#[no_mangle]
pub extern "C" fn ffsrs_store_close(core: *mut SrsCore) {
    if !core.is_null() {
        let _ = catch_unwind(AssertUnwindSafe(|| unsafe { drop(Box::from_raw(core)) }));
    }
}

/// `*out` = 1 已搬迁（或确认没有可搬的），0 未搬迁。
#[no_mangle]
pub extern "C" fn ffsrs_store_legacy_state(
    core: *const SrsCore,
    out: *mut i32,
    error_out: *mut *mut c_char,
) -> i32 {
    if out.is_null() {
        set_error(error_out, "null out");
        return STORE_BAD_ARGUMENT;
    }
    run(core, error_out, |c| {
        let v = c.legacy_imported()?;
        unsafe { *out = v as i32 };
        Ok(())
    })
}

#[no_mangle]
pub extern "C" fn ffsrs_store_legacy_begin(core: *const SrsCore, error_out: *mut *mut c_char) -> i32 {
    run(core, error_out, |c| c.legacy_begin())
}

/// 一页旧表行（rows.rs 编码）。
#[no_mangle]
pub extern "C" fn ffsrs_store_legacy_page(
    core: *const SrsCore,
    table: *const u8,
    table_len: usize,
    page: *const u8,
    page_len: usize,
    error_out: *mut *mut c_char,
) -> i32 {
    run(core, error_out, |c| {
        let t = utf8(table, table_len)?;
        let p = bytes(page, page_len).ok_or("null page")?;
        c.legacy_page(t, p).map(|_| ())
    })
}

#[no_mangle]
pub extern "C" fn ffsrs_store_legacy_commit(core: *const SrsCore, error_out: *mut *mut c_char) -> i32 {
    run(core, error_out, |c| c.legacy_commit())
}

#[no_mangle]
pub extern "C" fn ffsrs_store_legacy_abort(core: *const SrsCore, error_out: *mut *mut c_char) -> i32 {
    run(core, error_out, |c| c.legacy_abort())
}

#[no_mangle]
pub extern "C" fn ffsrs_store_legacy_mark_none(
    core: *const SrsCore,
    error_out: *mut *mut c_char,
) -> i32 {
    run(core, error_out, |c| c.legacy_mark_none())
}

/// `VACUUM INTO` 一份快照；`strip_device_local != 0` 时清空设备本地表。
#[no_mangle]
pub extern "C" fn ffsrs_store_snapshot(
    core: *const SrsCore,
    path: *const u8,
    path_len: usize,
    strip_device_local: i32,
    error_out: *mut *mut c_char,
) -> i32 {
    run(core, error_out, |c| {
        c.snapshot_into(Path::new(utf8(path, path_len)?), strip_device_local != 0)
    })
}

/// 只读调试查询（测试 / 诊断）。参数是一行 rows.rs 编码的页（列数 = 参数个数，可为空页）。
#[no_mangle]
pub extern "C" fn ffsrs_store_debug_query(
    core: *const SrsCore,
    sql: *const u8,
    sql_len: usize,
    params: *const u8,
    params_len: usize,
    out: *mut *mut u8,
    out_len: *mut usize,
    error_out: *mut *mut c_char,
) -> i32 {
    if out.is_null() || out_len.is_null() {
        set_error(error_out, "null out");
        return STORE_BAD_ARGUMENT;
    }
    run(core, error_out, |c| {
        let s = utf8(sql, sql_len)?;
        let p = bytes(params, params_len).ok_or("null params")?;
        let values = if p.is_empty() {
            Vec::new()
        } else {
            let (_, mut rows) = super::rows::decode(p)?;
            if rows.len() > 1 {
                return Err("params page must hold at most one row".into());
            }
            rows.pop().unwrap_or_default()
        };
        hand_out(c.debug_query(s, &values)?, out, out_len);
        Ok(())
    })
}
