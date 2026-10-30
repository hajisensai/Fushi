//! Fushi 音乐胖核心：曲库扫描（目录遍历 + 标签 / 音频属性 + CUE 拆轨 + 内容派生 uid）的
//! C ABI。设计见 `docs/specs/2026-10-23-music-module-design.md` §4.1。
//!
//! ABI 约定（Dart 侧见 `packages/fushi_music`）：
//! - 导出符号一律 `ffm_<域>_<动作>`，`#[no_mangle] pub extern "C"`。
//! - **粗粒度**：一次扫描 = `ffm_scan_open` 建游标 → 反复 `ffm_scan_next` 取批（每批至多
//!   [scan::MAX_BATCH] 条记录，紧凑二进制，见 [wire]）→ `ffm_scan_close`。不逐文件跨 FFI、
//!   不拼 JSON；遍历 / 标签解析 / CUE 都在一次 `next` 调用里完成。
//! - Rust 分配的输出缓冲区用 [ffm_free_bytes] 释放。
//! - 返回 `i32` 状态码：0 = 成功，负数 = 失败（见 [status]）；panic 一律接住转成
//!   [status::PANIC]，不越过 FFI 边界。
//! - **硬依赖、无 Dart 回退**：Dart 侧加载失败抛带原因的 `FushiMusicUnavailableError`。

use std::panic::{catch_unwind, AssertUnwindSafe};

pub mod cd;
pub mod cue;
pub mod dsf;
pub mod fingerprint;
pub mod lyrics;
#[cfg(feature = "plugin")]
pub mod plugin;
pub mod scan;
pub mod tag_write;
pub mod tags;
pub mod uid;
pub mod wire;

/// C ABI 版本。Dart 侧加载时比对，不一致抛带原因的加载异常。
/// 批次二进制格式（[wire::BATCH_FORMAT_VERSION]）变化也必须升这里。
pub const ABI_VERSION: i32 = 1;

/// 各导出函数共用的返回码。
pub mod status {
    pub const OK: i32 = 0;
    /// 必需的指针为空。
    pub const NULL_ARGUMENT: i32 = -1;
    /// 参数取值非法（路径不是 UTF-8、句柄已关闭）。
    pub const INVALID_ARGUMENT: i32 = -2;
    /// 输入数据无法解析（已知文件清单格式不对）。
    pub const BAD_INPUT: i32 = -3;
    /// 扫描根不存在或不是目录。
    pub const NOT_FOUND: i32 = -5;
    /// 写文件失败（只读 / 被占用 / 格式不支持写标签）。
    pub const WRITE_FAILED: i32 = -6;
    /// 设备读失败（光驱打不开 / 没有盘 / 不是音频 CD）。
    pub const IO_FAILED: i32 = -7;
    /// 本平台不支持（移动端读物理光驱）。
    pub const UNSUPPORTED: i32 = -8;
    /// Rust 侧 panic（已接住）。
    pub const PANIC: i32 = -100;
}

pub(crate) fn guard(body: impl FnOnce() -> i32) -> i32 {
    catch_unwind(AssertUnwindSafe(body)).unwrap_or(status::PANIC)
}

/// 把 Rust 分配的字节交给调用方：写 `out_ptr` / `out_len`，之后用 [ffm_free_bytes] 释放。
///
/// # Safety
/// `out_ptr` / `out_len` 必须非空且可写。
pub(crate) unsafe fn hand_over_bytes(bytes: Vec<u8>, out_ptr: *mut *mut u8, out_len: *mut usize) {
    let boxed = bytes.into_boxed_slice();
    *out_len = boxed.len();
    *out_ptr = Box::into_raw(boxed) as *mut u8;
}

/// # Safety
/// `ptr` 为空或指向至少 `len` 字节的可读内存。
pub(crate) unsafe fn slice_arg<'a>(ptr: *const u8, len: usize) -> Option<&'a [u8]> {
    if ptr.is_null() {
        if len == 0 {
            return Some(&[]);
        }
        return None;
    }
    Some(std::slice::from_raw_parts(ptr, len))
}

#[no_mangle]
pub extern "C" fn ffm_abi_version() -> i32 {
    ABI_VERSION
}

/// 释放本库分配并交给调用方的缓冲区（长度必须与交出时一致）。
#[no_mangle]
pub extern "C" fn ffm_free_bytes(ptr: *mut u8, len: usize) {
    if !ptr.is_null() {
        unsafe { drop(Box::from_raw(std::ptr::slice_from_raw_parts_mut(ptr, len))) };
    }
}

/// 打开一个扫描游标：`root` 是 UTF-8 绝对路径。成功时写 `out_handle`（不透明指针，
/// 用 [ffm_scan_close] 释放）。根不存在 / 不是目录返回 [status::NOT_FOUND]。
///
/// # Safety
/// `root_ptr` 指向 `root_len` 字节；`out_handle` 可写。
#[no_mangle]
pub unsafe extern "C" fn ffm_scan_open(
    root_ptr: *const u8,
    root_len: usize,
    recursive: u8,
    out_handle: *mut *mut scan::Scanner,
) -> i32 {
    guard(|| {
        if out_handle.is_null() {
            return status::NULL_ARGUMENT;
        }
        let Some(bytes) = slice_arg(root_ptr, root_len) else {
            return status::NULL_ARGUMENT;
        };
        let Ok(root) = std::str::from_utf8(bytes) else {
            return status::INVALID_ARGUMENT;
        };
        match scan::Scanner::open(root, recursive != 0) {
            Some(scanner) => {
                *out_handle = Box::into_raw(Box::new(scanner));
                status::OK
            }
            None => status::NOT_FOUND,
        }
    })
}

/// 告诉游标「这些文件库里已有、且（修改时刻, 大小）没变就别再解析」：缓冲区格式见
/// [wire::parse_known_files]。没变的文件只回一条 `unchanged` 记录（只带路径）。
/// 必须在第一次 [ffm_scan_next] 之前调用。
///
/// # Safety
/// `handle` 来自 [ffm_scan_open] 且未关闭；`ptr` 指向 `len` 字节。
#[no_mangle]
pub unsafe extern "C" fn ffm_scan_set_known(
    handle: *mut scan::Scanner,
    ptr: *const u8,
    len: usize,
) -> i32 {
    guard(|| {
        if handle.is_null() {
            return status::NULL_ARGUMENT;
        }
        let Some(bytes) = slice_arg(ptr, len) else {
            return status::NULL_ARGUMENT;
        };
        match wire::parse_known_files(bytes) {
            Some(known) => {
                (*handle).set_known(known);
                status::OK
            }
            None => status::BAD_INPUT,
        }
    })
}

/// 取下一批记录（至多 `max_records`，0 或超过上限按 [scan::MAX_BATCH]）。批次二进制格式见
/// [wire]；批头的 `done` 标志为 1 表示扫描结束（该批仍可能带记录）。
///
/// # Safety
/// `handle` 来自 [ffm_scan_open] 且未关闭；`out_ptr` / `out_len` 可写。
#[no_mangle]
pub unsafe extern "C" fn ffm_scan_next(
    handle: *mut scan::Scanner,
    max_records: u32,
    out_ptr: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    guard(|| {
        if handle.is_null() || out_ptr.is_null() || out_len.is_null() {
            return status::NULL_ARGUMENT;
        }
        let bytes = (*handle).next_batch(max_records as usize);
        hand_over_bytes(bytes, out_ptr, out_len);
        status::OK
    })
}

/// 关闭扫描游标。
///
/// # Safety
/// `handle` 来自 [ffm_scan_open]，只能关一次。
#[no_mangle]
pub unsafe extern "C" fn ffm_scan_close(handle: *mut scan::Scanner) {
    if !handle.is_null() {
        let _ = catch_unwind(AssertUnwindSafe(|| drop(Box::from_raw(handle))));
    }
}

/// 取一个音频文件的内嵌封面（第一张 front cover，没有则第一张图）。没有封面时
/// `out_len = 0`、返回 OK；文件读不了返回 [status::BAD_INPUT]。
///
/// # Safety
/// `path_ptr` 指向 `path_len` 字节；`out_ptr` / `out_len` 可写。
#[no_mangle]
pub unsafe extern "C" fn ffm_tags_embedded_cover(
    path_ptr: *const u8,
    path_len: usize,
    out_ptr: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    guard(|| {
        if out_ptr.is_null() || out_len.is_null() {
            return status::NULL_ARGUMENT;
        }
        let Some(bytes) = slice_arg(path_ptr, path_len) else {
            return status::NULL_ARGUMENT;
        };
        let Ok(path) = std::str::from_utf8(bytes) else {
            return status::INVALID_ARGUMENT;
        };
        match tags::embedded_cover(std::path::Path::new(path)) {
            Ok(Some(cover)) => {
                hand_over_bytes(cover, out_ptr, out_len);
                status::OK
            }
            Ok(None) => {
                *out_ptr = std::ptr::null_mut();
                *out_len = 0;
                status::OK
            }
            Err(_) => status::BAD_INPUT,
        }
    })
}

fn utf8_path_arg<'a>(ptr: *const u8, len: usize) -> Result<&'a str, i32> {
    let Some(bytes) = (unsafe { slice_arg(ptr, len) }) else {
        return Err(status::NULL_ARGUMENT);
    };
    std::str::from_utf8(bytes).map_err(|_| status::INVALID_ARGUMENT)
}

/// 读出文件主标签里「写回」白名单字段（[tag_write::FIELDS]），线格式见 [tag_write]。
/// 文件读不了返回 [status::BAD_INPUT]。
///
/// # Safety
/// `path_ptr` 指向 `path_len` 字节；`out_ptr` / `out_len` 可写。
#[no_mangle]
pub unsafe extern "C" fn ffm_tags_read_fields(
    path_ptr: *const u8,
    path_len: usize,
    out_ptr: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    guard(|| {
        if out_ptr.is_null() || out_len.is_null() {
            return status::NULL_ARGUMENT;
        }
        let path = match utf8_path_arg(path_ptr, path_len) {
            Ok(p) => p,
            Err(code) => return code,
        };
        match tag_write::read_fields(std::path::Path::new(path)) {
            Ok(pairs) => {
                hand_over_bytes(tag_write::encode_kv(&pairs), out_ptr, out_len);
                status::OK
            }
            Err(_) => status::BAD_INPUT,
        }
    })
}

/// 把一组白名单字段写进文件主标签（值为空串 = 删除）。线格式坏 / 键不认识 / 数字字段
/// 非法 → [status::INVALID_ARGUMENT]（文件不动）；文件读不了 → [status::BAD_INPUT]；
/// 写盘失败 → [status::WRITE_FAILED]。
///
/// # Safety
/// `path_ptr` 指向 `path_len` 字节；`kv_ptr` 指向 `kv_len` 字节。
#[no_mangle]
pub unsafe extern "C" fn ffm_tags_write_fields(
    path_ptr: *const u8,
    path_len: usize,
    kv_ptr: *const u8,
    kv_len: usize,
) -> i32 {
    guard(|| {
        let path = match utf8_path_arg(path_ptr, path_len) {
            Ok(p) => p,
            Err(code) => return code,
        };
        let Some(kv) = slice_arg(kv_ptr, kv_len) else {
            return status::NULL_ARGUMENT;
        };
        let Some(pairs) = tag_write::parse_kv(kv) else {
            return status::INVALID_ARGUMENT;
        };
        match tag_write::write_fields(std::path::Path::new(path), &pairs) {
            Ok(()) => status::OK,
            Err(tag_write::TagWriteError::BadInput(_)) => status::INVALID_ARGUMENT,
            Err(tag_write::TagWriteError::Unreadable(_)) => status::BAD_INPUT,
            Err(tag_write::TagWriteError::WriteFailed(_)) => status::WRITE_FAILED,
        }
    })
}

/// 音频 CD：MMC READ TOC 格式 0 / 格式 5 的原始响应 → 盘信息（[cd::encode_info] 线格式）。
/// 纯计算（Disc ID、CD-TEXT 解析），不碰设备；`cdtext` 可为空。TOC 不合法返回
/// [status::BAD_INPUT]。
///
/// # Safety
/// `toc_ptr` 指向 `toc_len` 字节，`text_ptr` 为空（`text_len == 0`）或指向 `text_len` 字节；
/// `out_ptr` / `out_len` 可写。
#[no_mangle]
pub unsafe extern "C" fn ffm_cd_info_from_raw(
    toc_ptr: *const u8,
    toc_len: usize,
    text_ptr: *const u8,
    text_len: usize,
    out_ptr: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    guard(|| {
        if out_ptr.is_null() || out_len.is_null() {
            return status::NULL_ARGUMENT;
        }
        let (Some(toc), Some(text)) = (slice_arg(toc_ptr, toc_len), slice_arg(text_ptr, text_len))
        else {
            return status::NULL_ARGUMENT;
        };
        match cd::info_from_raw(toc, text) {
            Some(info) => {
                hand_over_bytes(cd::encode_info(&info), out_ptr, out_len);
                status::OK
            }
            None => status::BAD_INPUT,
        }
    })
}

/// 音频 CD：读物理光驱（`device` = Windows 盘符 `E:` / Linux `/dev/srN` / macOS `/dev/rdiskN`）的
/// TOC 与 CD-TEXT，一次返回盘信息（Disc ID 已算好）。打不开 / 没有盘 / 不是音频 CD 返回
/// [status::IO_FAILED]，移动端返回 [status::UNSUPPORTED]。可能阻塞数百毫秒（光驱转起来），
/// 调用方放后台 isolate。
///
/// # Safety
/// `device_ptr` 指向 `device_len` 字节；`out_ptr` / `out_len` 可写。
#[no_mangle]
pub unsafe extern "C" fn ffm_cd_read(
    device_ptr: *const u8,
    device_len: usize,
    out_ptr: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    guard(|| {
        if out_ptr.is_null() || out_len.is_null() {
            return status::NULL_ARGUMENT;
        }
        let device = match utf8_path_arg(device_ptr, device_len) {
            Ok(d) => d,
            Err(code) => return code,
        };
        let (toc, text) = match cd::device::read(device) {
            Ok(raw) => raw,
            Err(cd::DeviceError::Unsupported) => return status::UNSUPPORTED,
            Err(cd::DeviceError::Io(_)) => return status::IO_FAILED,
        };
        match cd::info_from_raw(&toc, &text) {
            Some(info) => {
                hand_over_bytes(cd::encode_info(&info), out_ptr, out_len);
                status::OK
            }
            // 读到了 TOC 但不像音频盘（全是数据轨 / 地址不单调）。
            None => status::IO_FAILED,
        }
    })
}

/// 本机光驱列表（[cd::encode_drives] 线格式）。移动端为空表。
///
/// # Safety
/// `out_ptr` / `out_len` 可写。
#[no_mangle]
pub unsafe extern "C" fn ffm_cd_list_drives(out_ptr: *mut *mut u8, out_len: *mut usize) -> i32 {
    guard(|| {
        if out_ptr.is_null() || out_len.is_null() {
            return status::NULL_ARGUMENT;
        }
        hand_over_bytes(
            cd::encode_drives(&cd::device::list_drives()),
            out_ptr,
            out_len,
        );
        status::OK
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn guard_turns_panic_into_status() {
        assert_eq!(guard(|| panic!("boom")), status::PANIC);
        assert_eq!(guard(|| status::OK), status::OK);
    }
}
