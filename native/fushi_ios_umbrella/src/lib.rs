//! iOS 伞形静态库：把 fushi_p2p、fushi_fsrs、fushi_compute、fushi_web_core 与 fushi_rwkv 编进同一个
//! staticlib。
//!
//! 五个 crate 的 `#[no_mangle] pub extern "C"` 函数（`fp2p_*` / `ffsrs_*` / `ffc_*` / `fwc_*` / `frwkv_*`）在
//! staticlib 里按 C 级导出保留（fat LTO 也不会内部化上游 crate 的 C 导出符号）；这里只需要
//! 让它们真的被链接进来——显式 `extern crate` + 重新导出，防止「依赖没被引用就不加载」。
//! fushi_compute 是 app 的硬依赖：伞形库缺失或不含 `ffc_*` 时 Runner 的
//! 「Check fushi_compute (iOS umbrella)」构建阶段让构建失败；fushi_rwkv（RWKV-Instant 排程推理，
//! AGPL-3.0-or-later——链进来后本库与 Runner 整体受 AGPL 约束，见 Cargo.toml）同为硬依赖，由
//! 「Check fushi_rwkv (iOS umbrella)」把关。
//!
//! 本 crate 不加任何自己的符号；ABI 以各子 crate 的 lib.rs 为准，核对用各自的
//! verify_abi.sh（期望集取自 Dart 绑定的 lookup 名）。

// fushi_compute 以 crate 名整体重新导出、不 glob：它与 fushi_fsrs 都有 `ABI_VERSION` /
// `status`，两个 glob 并列会触发 ambiguous_glob_reexports。C 级导出不受影响（链进来即导出）。
// fushi_rwkv 同理（它也有 `ABI_VERSION`）。
pub extern crate fushi_compute;
pub extern crate fushi_rwkv;
// 音乐胖核心 ffm_*（也有 `ABI_VERSION` / `status`，同理按 crate 名重新导出、不 glob）。
pub extern crate fushi_music;
extern crate fushi_web_core;
extern crate fushi_fsrs;
extern crate fushi_p2p;

pub use fushi_web_core::*;
pub use fushi_fsrs::*;
pub use fushi_p2p::*;
