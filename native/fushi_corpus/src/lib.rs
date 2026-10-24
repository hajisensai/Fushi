//! Fushi 语料胖核心：「我库里的例句」（作品图谱 L4，设计见
//! `docs/specs/2026-10-24-cross-media-links.md` §3）的倒排索引与查询。
//!
//! 用户库里的书 / 字幕 / 歌词 / 游戏台词按句喂进来，每句带上 fushidicts 给出的**词典形**
//! 词元（`fushidicts_corpus_terms`，按已加载词典的词形还原归一，不分语言）；查词弹窗用词头
//! 一次查询拿回分组好的 top-N 例句。状态全在这里（[corpus::Corpus]），Dart 不另存镜像。
//!
//! ABI 约定（Dart 侧见 `packages/fushi_corpus`）：
//! - 导出符号一律 `fcorp_<动作>`，`#[no_mangle] pub extern "C"`。
//! - **粗粒度**：一份文档（一本书 / 一集字幕 / 一首歌词 / 一段游戏台词）一次 `fcorp_put`；
//!   一次查词一次 `fcorp_query`；一章正文一次 `fcorp_split`。
//! - 句柄可跨线程 / isolate 共用（内部读写锁）：后台 isolate 写入时 UI 侧照常查询。
//! - Rust 分配的输出缓冲区用 [fcorp_free_bytes] 释放。
//! - 返回 `i32` 状态码：0 = 成功，负数 = 失败（见 [status]）；panic 一律接住转成
//!   [status::PANIC]，不越过 FFI 边界。
//! - **硬依赖、无 Dart 回退**：Dart 侧加载失败抛带原因的 `FushiCorpusUnavailableError`。

use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::Path;

pub mod corpus;
pub mod split;
pub mod wire;

use corpus::{Corpus, PutError};

/// C ABI 版本。Dart 侧加载时比对，不一致抛带原因的加载异常。线格式（[wire]）或磁盘格式
/// （[corpus::FILE_VERSION]）变化也必须升这里。
pub const ABI_VERSION: i32 = 1;

/// 各导出函数共用的返回码（与 fushi_music 同一套）。
pub mod status {
    pub const OK: i32 = 0;
    /// 必需的指针为空。
    pub const NULL_ARGUMENT: i32 = -1;
    /// 参数取值非法（路径不是 UTF-8）。
    pub const INVALID_ARGUMENT: i32 = -2;
    /// 输入数据无法解析（线格式截断 / 词元与句数对不上）。
    pub const BAD_INPUT: i32 = -3;
    /// 读写语料目录失败。
    pub const IO: i32 = -4;
    /// Rust 侧 panic（已接住）。
    pub const PANIC: i32 = -100;
}

fn guard(body: impl FnOnce() -> i32) -> i32 {
    catch_unwind(AssertUnwindSafe(body)).unwrap_or(status::PANIC)
}

/// # Safety
/// `out_ptr` / `out_len` 必须非空且可写。
unsafe fn hand_over_bytes(bytes: Vec<u8>, out_ptr: *mut *mut u8, out_len: *mut usize) {
    let boxed = bytes.into_boxed_slice();
    *out_len = boxed.len();
    *out_ptr = Box::into_raw(boxed) as *mut u8;
}

/// # Safety
/// `ptr` 为空或指向至少 `len` 字节的可读内存。
unsafe fn slice_arg<'a>(ptr: *const u8, len: usize) -> Option<&'a [u8]> {
    if ptr.is_null() {
        if len == 0 {
            return Some(&[]);
        }
        return None;
    }
    Some(std::slice::from_raw_parts(ptr, len))
}

/// # Safety
/// 同 [slice_arg]。
unsafe fn str_arg<'a>(ptr: *const u8, len: usize) -> Result<&'a str, i32> {
    let bytes = slice_arg(ptr, len).ok_or(status::NULL_ARGUMENT)?;
    std::str::from_utf8(bytes).map_err(|_| status::INVALID_ARGUMENT)
}

/// # Safety
/// `handle` 为空或来自 [fcorp_open] 且尚未 [fcorp_close]。
unsafe fn corpus_arg<'a>(handle: *const Corpus) -> Option<&'a Corpus> {
    handle.as_ref()
}

#[no_mangle]
pub extern "C" fn fcorp_abi_version() -> i32 {
    ABI_VERSION
}

/// 释放本库分配并交给调用方的缓冲区（长度必须与交出时一致）。
#[no_mangle]
pub extern "C" fn fcorp_free_bytes(ptr: *mut u8, len: usize) {
    if !ptr.is_null() {
        unsafe { drop(Box::from_raw(std::ptr::slice_from_raw_parts_mut(ptr, len))) };
    }
}

/// 打开（不存在则建）语料目录并载入全部文档；成功时 `*out` = 句柄。
///
/// # Safety
/// `dir` 指向 `dir_len` 字节 UTF-8；`out` 可写。
#[no_mangle]
pub unsafe extern "C" fn fcorp_open(dir: *const u8, dir_len: usize, out: *mut *mut Corpus) -> i32 {
    guard(|| {
        if out.is_null() {
            return status::NULL_ARGUMENT;
        }
        let dir = match str_arg(dir, dir_len) {
            Ok(d) if !d.is_empty() => d,
            Ok(_) => return status::INVALID_ARGUMENT,
            Err(code) => return code,
        };
        match Corpus::open(Path::new(dir)) {
            Ok(corpus) => {
                *out = Box::into_raw(Box::new(corpus));
                status::OK
            }
            Err(_) => status::IO,
        }
    })
}

/// 关闭句柄。调用方保证此后没有任何线程再用它。
///
/// # Safety
/// `handle` 为空或来自 [fcorp_open]，且只关一次。
#[no_mangle]
pub unsafe extern "C" fn fcorp_close(handle: *mut Corpus) {
    if !handle.is_null() {
        let _ = catch_unwind(AssertUnwindSafe(|| drop(Box::from_raw(handle))));
    }
}

/// 写入（替换）一个文档：[doc] 是文档线格式，[terms] 是 fushidicts 词元线格式（见 [wire]）。
///
/// # Safety
/// 指针各指向给定长度的可读内存。
#[no_mangle]
pub unsafe extern "C" fn fcorp_put(
    handle: *const Corpus,
    doc: *const u8,
    doc_len: usize,
    terms: *const u8,
    terms_len: usize,
) -> i32 {
    guard(|| {
        let Some(corpus) = corpus_arg(handle) else { return status::NULL_ARGUMENT };
        let (Some(doc), Some(terms)) = (slice_arg(doc, doc_len), slice_arg(terms, terms_len)) else {
            return status::NULL_ARGUMENT;
        };
        match corpus.put(doc, terms) {
            Ok(()) => status::OK,
            Err(PutError::BadInput(_)) => status::BAD_INPUT,
            Err(PutError::Io(_)) => status::IO,
        }
    })
}

/// 删除文档：`part < 0 且 all_parts != 0` 时删该条目全部 part；返回删掉的文档数（≥ 0）或错误码。
///
/// # Safety
/// `key` 指向 `key_len` 字节 UTF-8。
#[no_mangle]
pub unsafe extern "C" fn fcorp_remove(
    handle: *const Corpus,
    kind: u8,
    key: *const u8,
    key_len: usize,
    part: i32,
    all_parts: u8,
) -> i32 {
    guard(|| {
        let Some(corpus) = corpus_arg(handle) else { return status::NULL_ARGUMENT };
        let key = match str_arg(key, key_len) {
            Ok(k) => k,
            Err(code) => return code,
        };
        let part = if all_parts != 0 { None } else { Some(part) };
        corpus.remove(kind, key, part).min(i32::MAX as usize) as i32
    })
}

/// 删除 [kind_mask] 里各 kind 的全部文档；返回删掉的文档数。
///
/// # Safety
/// `handle` 来自 [fcorp_open]。
#[no_mangle]
pub unsafe extern "C" fn fcorp_remove_kinds(handle: *const Corpus, kind_mask: u32) -> i32 {
    guard(|| {
        let Some(corpus) = corpus_arg(handle) else { return status::NULL_ARGUMENT };
        corpus.remove_kinds(kind_mask).min(i32::MAX as usize) as i32
    })
}

/// 文档清单 JSON（见 [Corpus::docs_json]）。`kind < 0` 列全部；`key_len == 0` 不按条目过滤。
///
/// # Safety
/// `key` 为空（`key_len == 0`）或指向 `key_len` 字节 UTF-8；`out` / `out_len` 可写。
#[no_mangle]
pub unsafe extern "C" fn fcorp_docs(
    handle: *const Corpus,
    kind: i32,
    key: *const u8,
    key_len: usize,
    out: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    guard(|| {
        let Some(corpus) = corpus_arg(handle) else { return status::NULL_ARGUMENT };
        if out.is_null() || out_len.is_null() {
            return status::NULL_ARGUMENT;
        }
        let key = match str_arg(key, key_len) {
            Ok(k) => k,
            Err(code) => return code,
        };
        let kind = if (0..=255).contains(&kind) { Some(kind as u8) } else { None };
        let json = corpus.docs_json(kind, if key.is_empty() { None } else { Some(key) });
        hand_over_bytes(json.into_bytes(), out, out_len);
        status::OK
    })
}

/// 统计 JSON：`{docs, sentences, terms, postings, droppedOnOpen}`。
///
/// # Safety
/// `out` / `out_len` 可写。
#[no_mangle]
pub unsafe extern "C" fn fcorp_stats(handle: *const Corpus, out: *mut *mut u8, out_len: *mut usize) -> i32 {
    guard(|| {
        let Some(corpus) = corpus_arg(handle) else { return status::NULL_ARGUMENT };
        if out.is_null() || out_len.is_null() {
            return status::NULL_ARGUMENT;
        }
        hand_over_bytes(corpus.stats_json().into_bytes(), out, out_len);
        status::OK
    })
}

/// 查询（查询线格式见 [wire]）→ 分组结果 JSON（见 [Corpus::query_json]）。
///
/// # Safety
/// `query` 指向 `query_len` 字节；`out` / `out_len` 可写。
#[no_mangle]
pub unsafe extern "C" fn fcorp_query(
    handle: *const Corpus,
    query: *const u8,
    query_len: usize,
    out: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    guard(|| {
        let Some(corpus) = corpus_arg(handle) else { return status::NULL_ARGUMENT };
        if out.is_null() || out_len.is_null() {
            return status::NULL_ARGUMENT;
        }
        let Some(query) = slice_arg(query, query_len) else { return status::NULL_ARGUMENT };
        match corpus.query_json(query) {
            Ok(json) => {
                hand_over_bytes(json.into_bytes(), out, out_len);
                status::OK
            }
            Err(_) => status::BAD_INPUT,
        }
    })
}

/// 句子切分（见 [split]）：输出 `u32 N, N × { u32 start16, u32 end16 }`。
///
/// # Safety
/// `text` 指向 `text_len` 字节 UTF-8；`out` / `out_len` 可写。
#[no_mangle]
pub unsafe extern "C" fn fcorp_split(
    text: *const u8,
    text_len: usize,
    max_units: u32,
    out: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    guard(|| {
        if out.is_null() || out_len.is_null() {
            return status::NULL_ARGUMENT;
        }
        let text = match str_arg(text, text_len) {
            Ok(t) => t,
            Err(code) => return code,
        };
        let spans = split::split_sentences(text, max_units);
        let mut w = wire::Writer::default();
        w.u32(spans.len() as u32);
        for s in spans {
            w.u32(s.start);
            w.u32(s.end);
        }
        hand_over_bytes(w.buf, out, out_len);
        status::OK
    })
}
