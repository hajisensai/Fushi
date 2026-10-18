//! fushi_web_core：app 内**网页内容**的计算核心，给 Dart FFI（`packages/fushi_web_core`）用。
//!
//! 按「胖核心」设计：Rust 持有状态与业务逻辑、落盘，对外只给少量粗粒度命令 + 状态快照；
//! Dart 只做 UI、平台插件、WebView 桥、联网（必须走 app 的全局代理）与 i18n。
//!
//! 模块：
//! - [`adblock`]：网页广告 / 跟踪拦截（Brave adblock-rust）。订阅列表、缓存、过期、引擎编译与
//!   序列化缓存、白名单都在这里；Dart 按 `begin_sync` 的清单联网、把原始字节交回 `ingest`。
//! - [`comic_ad`]：网页漫画章末广告页识别（彩色 + 二维码定位图形），整批一次调用。
//! - [`article`]：网页小说正文提取（预留，尚未实现）。
//!
//! C ABI 约定（全部 `fwc_` 前缀，与 native/fushi_p2p 同一套纪律）：
//! - 永不 panic 过 FFI 边界（每个导出函数都包 `catch_unwind`，`panic = "unwind"`）；
//! - 字符串入参是 `(ptr, len)` 的 UTF-8，大块数据是字节指针，不来回编码成字符串；
//! - 返回的字节缓冲由调用方用 `fwc_bytes_free(ptr, len)` 释放；
//! - 失败原因用 `fwc_last_error()` 取（线程局部），用 `fwc_string_free` 释放。

pub mod adblock;
pub mod article;
pub mod comic_ad;
mod ffi_util;

pub use ffi_util::{fwc_bytes_free, fwc_last_error, fwc_string_free, fwc_version};
