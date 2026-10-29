//! Fushi 计算内核：CPU 密集操作（哈希 / 图像 / 文本匹配 / 信号处理）的 C ABI。
//!
//! ABI 约定（Dart 侧见 packages/fushi_compute）：
//! - 导出符号一律 `ffc_<域>_<动作>`，`#[no_mangle] pub extern "C"`；每个域一个模块文件
//!   （`font.rs` / `galcal.rs` / `hash.rs` / `image.rs` / `ocr.rs` / `signal.rs` / `text.rs` / `ts.rs`），互不依赖；
//!   `dart.rs` 是共用的 Dart 数值语义复刻（`max` / `min` / `clamp` / `compareTo` / `List.sort`）。
//! - 数据走原始缓冲区（指针 + 长度），不走 JSON：这些接口按块 / 像素 / 字符批量调用，
//!   编码开销会吃掉收益（fushi_fsrs 实测逐次 JSON 往返 25～30 µs）。
//! - 能由调用方分配输出就由调用方分配；必须由 Rust 分配的缓冲区用 [ffc_free_bytes] 释放。
//! - 返回 `i32` 状态码：0 = 成功，负数 = 失败（见 [status]）；panic 一律接住转成
//!   [status::PANIC]，不越过 FFI 边界。
//! - **硬依赖、无 Dart 回退**：五个平台 app 与无头服务端都必须随包本库（缺产物构建失败），
//!   Dart 侧加载失败抛带原因的 `FushiComputeUnavailableError`。所以每个域只有这一份实现；
//!   从 Dart 迁过来的内核要先用旧 Dart 实现冻结输入 → 输出向量做回归测试，再删 Dart。
//! - 新增符号不升 [ABI_VERSION]（Dart 侧按域 lookup，库比绑定旧时那个域抛缺符号异常）；
//!   改动既有符号的签名或语义、或删掉符号才升（v2：有声书 cue 吸附 / 修边 / 余量的三个
//!   `ffc_signal_cue_*` 迁到上游 crate 后删除，改由 `fcp_*` 提供）。

use std::panic::{catch_unwind, AssertUnwindSafe};

pub mod crypto;
pub mod dart;
pub mod font;
pub mod galcal;
pub mod hash;
pub mod image;
pub mod ocr;
pub mod pano;
pub mod parse;
pub mod signal;
pub mod text;
pub mod ts;

// 上游 crate 的 `fcp_*` C 导出随本库一起导出（cdylib / staticlib / iOS 伞形库都靠这一行把它
// 链进来；不引用就会被当成没用的依赖丢掉）。见 Cargo.toml 的说明。
pub extern crate fushi_asr_cue_post;

/// C ABI 版本。Dart 侧加载时比对，不一致抛带原因的加载异常。
pub const ABI_VERSION: i32 = 2;

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
