//! Fushi 计算内核：纯 Dart 实现太慢的 CPU 密集操作（哈希 / 图像 / 文本匹配）的 C ABI。
//!
//! ABI 约定（Dart 侧见 packages/fushi_compute）：
//! - 导出符号一律 `ffc_<域>_<动作>`，`#[no_mangle] pub extern "C"`；每个域一个模块文件
//!   （`hash.rs` / `image.rs` / `text.rs`），互不依赖。
//! - 数据走原始缓冲区（指针 + 长度），不走 JSON：这些接口按块 / 像素 / 字符批量调用，
//!   编码开销会吃掉收益（fushi_fsrs 实测逐次 JSON 往返 25～30 µs）。
//! - 能由调用方分配输出就由调用方分配；必须由 Rust 分配的缓冲区用 [ffc_free_bytes] 释放。
//! - 返回 `i32` 状态码：0 = 成功，负数 = 失败（见 [status]）；panic 一律接住转成
//!   [status::PANIC]，不越过 FFI 边界。
//! - 结果必须与 Dart 回退实现一致（纯算术内核逐位一致；涉及有损解码的在模块注释写明容差）：
//!   库缺失时各端退回 Dart，两条路径不一致会变成「同一份数据在不同设备上结果不同」。
//! - 新增符号不升 [ABI_VERSION]（Dart 侧按域单独 lookup，旧库缺符号只让该域退回 Dart）；
//!   改动既有符号的签名或语义才升。

use std::panic::{catch_unwind, AssertUnwindSafe};

pub mod font;
pub mod hash;
pub mod image;
pub mod text;

/// C ABI 版本。Dart 侧加载时比对，不一致视为库不可用（不崩）。
pub const ABI_VERSION: i32 = 1;

/// 各导出函数共用的返回码。
pub mod status {
    pub const OK: i32 = 0;
    /// 必需的指针为空。
    pub const NULL_ARGUMENT: i32 = -1;
    /// 参数取值非法（长度、尺寸、取值范围）。
    pub const INVALID_ARGUMENT: i32 = -2;
    /// 输入数据无法解析（坏图、截断的流）。
    pub const BAD_INPUT: i32 = -3;
    /// 调用方给的输出缓冲区不够大。
    pub const BUFFER_TOO_SMALL: i32 = -4;
    /// Rust 侧 panic（已接住）。
    pub const PANIC: i32 = -100;
}

/// 跑 [body]，把 panic 转成 [status::PANIC]。
#[allow(dead_code)]
pub(crate) fn guard(body: impl FnOnce() -> i32) -> i32 {
    catch_unwind(AssertUnwindSafe(body)).unwrap_or(status::PANIC)
}

/// 把 Rust 分配的字节交给调用方：写 `out_ptr` / `out_len`，之后用 [ffc_free_bytes] 释放。
///
/// # Safety
/// `out_ptr` / `out_len` 必须非空且可写。
#[allow(dead_code)]
pub(crate) unsafe fn hand_over_bytes(bytes: Vec<u8>, out_ptr: *mut *mut u8, out_len: *mut usize) {
    let boxed = bytes.into_boxed_slice();
    *out_len = boxed.len();
    *out_ptr = Box::into_raw(boxed) as *mut u8;
}

#[no_mangle]
pub extern "C" fn ffc_abi_version() -> i32 {
    ABI_VERSION
}

/// 释放本库分配并交给调用方的缓冲区（长度必须与交出时一致）。
#[no_mangle]
pub extern "C" fn ffc_free_bytes(ptr: *mut u8, len: usize) {
    if !ptr.is_null() {
        unsafe { drop(Box::from_raw(std::ptr::slice_from_raw_parts_mut(ptr, len))) };
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn guard_turns_panic_into_status() {
        assert_eq!(guard(|| panic!("boom")), status::PANIC);
        assert_eq!(guard(|| status::OK), status::OK);
    }

    #[test]
    fn handed_over_bytes_roundtrip() {
        let mut ptr = std::ptr::null_mut();
        let mut len = 0usize;
        unsafe { hand_over_bytes(vec![1, 2, 3], &mut ptr, &mut len) };
        assert_eq!(len, 3);
        assert_eq!(unsafe { std::slice::from_raw_parts(ptr, len) }, &[1, 2, 3]);
        ffc_free_bytes(ptr, len);
    }
}
