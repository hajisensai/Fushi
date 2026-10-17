//! iOS 伞形静态库：把 fushi_p2p 与 fushi_fsrs 编进同一个 staticlib。
//!
//! 两个 crate 的 `#[no_mangle] pub extern "C"` 函数（`fp2p_*` / `ffsrs_*`）在 staticlib
//! 里按 C 级导出保留（fat LTO 也不会内部化上游 crate 的 C 导出符号）；这里只需要让两个
//! crate 真的被链接进来——显式 `extern crate` + 重新导出，防止「依赖没被引用就不加载」。
//!
//! 本 crate 不加任何自己的符号；ABI 以两个子 crate 的 lib.rs 为准，核对用各自的
//! verify_abi.sh（期望集取自 Dart 绑定的 lookup 名）。

extern crate fushi_fsrs;
extern crate fushi_p2p;

pub use fushi_fsrs::*;
pub use fushi_p2p::*;
