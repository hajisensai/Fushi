//! `ffc_parse_anidb_*`：AniDB 标题目录（每日标题包的流式解析 + 记录表 + 搜索索引）与
//! 单部 anime XML 的 DOM 解析。Dart 绑定：packages/fushi_compute/lib/src/parse/anidb.dart。
//!
//! 生命周期：
//! - 构建器：`builder_new` → 任意次 `builder_feed`（一次一块，块边界与 Dart 那边 gzip 解压器
//!   的输出一致）→ `builder_close` → `builder_finish`（产出目录句柄）→ `builder_free`
//!   （无论成败都要调；失败后可用 `builder_error` 取失败种类与说明）。
//! - 目录：不可变，`&self` 只读查询，可以在构建它的线程之外使用（Dart 侧在后台 isolate
//!   构建、把地址交回主 isolate 使用）；`catalog_free` 释放，之后句柄失效。
//!
//! 输出缓冲由本库分配、`ffc_free_bytes` 释放；格式见各函数注释。

use std::ffi::c_void;

use crate::parse::title_score::{encode_string_list, units_arg};
use crate::{guard, hand_over_bytes, status};

mod catalog;
mod dart_sort;
mod dom;
mod xml;

pub use catalog::{Catalog, CatalogError, MatchKind, SearchResult, StreamParser};

struct BuilderHandle {
    parser: Option<StreamParser>,
    error: Option<CatalogError>,
}

/// # Safety
/// `handle` 来自 [ffc_parse_anidb_catalog_builder_new] 且未释放。
unsafe fn builder<'a>(handle: *mut c_void) -> Option<&'a mut BuilderHandle> {
    (handle as *mut BuilderHandle).as_mut()
}

/// # Safety
/// `handle` 来自 [ffc_parse_anidb_catalog_builder_finish] 且未释放。
unsafe fn catalog<'a>(handle: *const c_void) -> Option<&'a Catalog> {
    (handle as *const Catalog).as_ref()
}

#[no_mangle]
pub extern "C" fn ffc_parse_anidb_catalog_builder_new() -> *mut c_void {
    let handle = Box::new(BuilderHandle {
        parser: Some(StreamParser::new()),
        error: None,
    });
    Box::into_raw(handle) as *mut c_void
}

fn record_result(handle: &mut BuilderHandle, result: Result<(), CatalogError>) -> i32 {
    match result {
        Ok(()) => status::OK,
        Err(error) => {
            handle.error = Some(error);
            status::BAD_INPUT
        }
    }
}

/// 喂一块解压后的字节。失败返回 [status::BAD_INPUT]（详情见 `builder_error`），之后
/// 不能再喂。
///
/// # Safety
/// `handle` 有效；`len > 0` 时 `bytes` 指向 `len` 个可读字节。
#[no_mangle]
pub unsafe extern "C" fn ffc_parse_anidb_catalog_builder_feed(
    handle: *mut c_void,
    bytes: *const u8,
    len: usize,
) -> i32 {
    let Some(h) = builder(handle) else {
        return status::NULL_ARGUMENT;
    };
    if len > 0 && bytes.is_null() {
        return status::NULL_ARGUMENT;
    }
    guard(|| {
        let Some(parser) = h.parser.as_mut() else {
            return status::INVALID_ARGUMENT;
        };
        let slice = if len == 0 {
            &[][..]
        } else {
            std::slice::from_raw_parts(bytes, len)
        };
        let result = parser.feed(slice);
        record_result(h, result)
    })
}

/// 输入结束（UTF-8 截断 / 残片 / 未闭合标签的检查）。
///
/// # Safety
/// `handle` 有效。
#[no_mangle]
pub unsafe extern "C" fn ffc_parse_anidb_catalog_builder_close(handle: *mut c_void) -> i32 {
    let Some(h) = builder(handle) else {
        return status::NULL_ARGUMENT;
    };
    guard(|| {
        let Some(parser) = h.parser.as_mut() else {
            return status::INVALID_ARGUMENT;
        };
        let result = parser.close();
        record_result(h, result)
    })
}

/// 汇总记录并建索引，成功时 `*out_catalog` 写目录句柄（用 `catalog_free` 释放）。
/// 构建器本身仍需 `builder_free`。
///
/// # Safety
/// `handle` 有效；`out_catalog` 非空可写。
#[no_mangle]
pub unsafe extern "C" fn ffc_parse_anidb_catalog_builder_finish(
    handle: *mut c_void,
    out_catalog: *mut *mut c_void,
) -> i32 {
    let Some(h) = builder(handle) else {
        return status::NULL_ARGUMENT;
    };
    if out_catalog.is_null() {
        return status::NULL_ARGUMENT;
    }
    guard(|| {
        let Some(parser) = h.parser.take() else {
            return status::INVALID_ARGUMENT;
        };
        match parser.finish() {
            Ok(catalog) => {
                *out_catalog = Box::into_raw(Box::new(catalog)) as *mut c_void;
                status::OK
            }
            Err(error) => {
                h.error = Some(error);
                status::BAD_INPUT
            }
        }
    })
}

/// 上一次失败：`*out_kind` 写种类（0 = 没有失败；1 禁止的声明 / 2 根元素不对 / 3 记录过多 /
/// 4 单部标题过多 / 5 XML 非法 / 6 UTF-8 非法 / 7 没有可用记录），说明文字（UTF-16）
/// 交给 `out_ptr` / `out_len`。
///
/// # Safety
/// `handle` 有效；三个输出指针非空可写。
#[no_mangle]
pub unsafe extern "C" fn ffc_parse_anidb_catalog_builder_error(
    handle: *mut c_void,
    out_kind: *mut u32,
    out_ptr: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    let Some(h) = builder(handle) else {
        return status::NULL_ARGUMENT;
    };
    if out_kind.is_null() || out_ptr.is_null() || out_len.is_null() {
        return status::NULL_ARGUMENT;
    }
    guard(|| {
        let (kind, detail) = match &h.error {
            Some(error) => (
                error.kind(),
                error.detail().encode_utf16().collect::<Vec<u16>>(),
            ),
            None => (0, Vec::new()),
        };
        *out_kind = kind;
        let bytes: Vec<u8> = detail.iter().flat_map(|u| u.to_le_bytes()).collect();
        hand_over_bytes(bytes, out_ptr, out_len);
        status::OK
    })
}

/// # Safety
/// `handle` 为空或来自 `builder_new` 且未释放。
#[no_mangle]
pub unsafe extern "C" fn ffc_parse_anidb_catalog_builder_free(handle: *mut c_void) {
    if !handle.is_null() {
        let handle = handle as *mut BuilderHandle;
        let _ =
            std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| drop(Box::from_raw(handle))));
    }
}

/// 释放目录（签名 `void(void*)`，Dart 侧直接拿来当 `NativeFinalizer`）。
///
/// # Safety
/// `handle` 为空或来自 `builder_finish` 且未释放。
#[no_mangle]
pub unsafe extern "C" fn ffc_parse_anidb_catalog_free(handle: *mut c_void) {
    if !handle.is_null() {
        let handle = handle as *mut Catalog;
        let _ =
            std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| drop(Box::from_raw(handle))));
    }
}

/// 全部记录的 anime id（升序，`i64` 小端数组）。
///
/// # Safety
/// `handle` 有效；输出指针非空可写。
#[no_mangle]
pub unsafe extern "C" fn ffc_parse_anidb_catalog_anime_ids(
    handle: *const c_void,
    out_ptr: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    let Some(c) = catalog(handle) else {
        return status::NULL_ARGUMENT;
    };
    if out_ptr.is_null() || out_len.is_null() {
        return status::NULL_ARGUMENT;
    }
    guard(|| {
        let bytes: Vec<u8> = c
            .table()
            .ids
            .iter()
            .flat_map(|id| id.to_le_bytes())
            .collect();
        hand_over_bytes(bytes, out_ptr, out_len);
        status::OK
    })
}

/// `ffc_parse_anidb_catalog_record_table` 写进 `out_words` 的字数。
pub const RECORD_TABLE_WORDS: usize = 7;

/// 借出目录的扁平记录表（见 `catalog::RecordTable`），供 Dart 侧在原生内存上建零拷贝视图、
/// 取记录时不再逐条跨 FFI。`out_words` 依次写入：
/// `ids` 指针（`i64[记录数]`，升序）、记录数、`title_start` 指针（`u32[记录数 + 1]`）、
/// `titles` 指针（`u32[标题数 * 6]`：value 偏移 / 长度、normalized 偏移 / 长度、type 下标、
/// language 下标）、标题数、`units` 指针（`u16[码元数]`）、码元数。这些指针归目录所有，
/// 在 `catalog_free` 之前一直有效、内容不变；数组为空时指针仍非空（悬空但对齐）。
/// type / language 去重后的字符串表另外复制一份交出（`encode_string_list`，调用方
/// `ffc_free_bytes`）。
///
/// # Safety
/// `handle` 有效；`out_words` 指向至少 [RECORD_TABLE_WORDS] 个可写 `usize`；输出指针非空可写。
#[no_mangle]
pub unsafe extern "C" fn ffc_parse_anidb_catalog_record_table(
    handle: *const c_void,
    out_words: *mut usize,
    out_ptr: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    let Some(c) = catalog(handle) else {
        return status::NULL_ARGUMENT;
    };
    if out_words.is_null() || out_ptr.is_null() || out_len.is_null() {
        return status::NULL_ARGUMENT;
    }
    guard(|| {
        let t = c.table();
        let words = [
            t.ids.as_ptr() as usize,
            t.len(),
            t.title_start.as_ptr() as usize,
            t.titles.as_ptr() as usize,
            t.title_count(),
            t.units.as_ptr() as usize,
            t.units.len(),
        ];
        std::ptr::copy_nonoverlapping(words.as_ptr(), out_words, RECORD_TABLE_WORDS);
        hand_over_bytes(encode_string_list(&t.strings), out_ptr, out_len);
        status::OK
    })
}

/// 搜索（`query` 必须已归一化）。输出：`u32 count, u32 0`，之后 `count` 条
/// `[i64 anime_id, u32 title_index, u32 kind, f64 similarity]`（24 字节）。
///
/// # Safety
/// `handle` 有效；`query` 按 `len` 可读；输出指针非空可写。
#[no_mangle]
pub unsafe extern "C" fn ffc_parse_anidb_catalog_search(
    handle: *const c_void,
    query: *const u16,
    len: usize,
    limit: u32,
    out_ptr: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    let Some(c) = catalog(handle) else {
        return status::NULL_ARGUMENT;
    };
    if out_ptr.is_null() || out_len.is_null() {
        return status::NULL_ARGUMENT;
    }
    let Some(query) = units_arg(query, len) else {
        return status::NULL_ARGUMENT;
    };
    guard(|| {
        let results = c.search(query, limit as usize);
        let mut out: Vec<u8> = Vec::with_capacity(8 + results.len() * 24);
        out.extend_from_slice(&(results.len() as u32).to_le_bytes());
        out.extend_from_slice(&0u32.to_le_bytes());
        for r in &results {
            out.extend_from_slice(&c.table().ids[r.record as usize].to_le_bytes());
            out.extend_from_slice(&r.title.to_le_bytes());
            out.extend_from_slice(&(r.kind as u32).to_le_bytes());
            out.extend_from_slice(&r.similarity.to_bits().to_le_bytes());
        }
        hand_over_bytes(out, out_ptr, out_len);
        status::OK
    })
}

/// 单部 anime XML → 元素树（格式见 `dom.rs` 模块注释），返回 [status::OK]；XML 不合格时
/// 返回 [status::BAD_INPUT]，缓冲改为错误记录：`u32 kind`（1 禁止的声明 / 2 解析失败 /
/// 3 闭合标签错位 / 4 多余的闭合标签 / 5 缺闭合标签）、`u32 position`（码元下标），之后是
/// 字符串列表 [message, expected, actual]。
///
/// # Safety
/// `units` 按 `len` 可读；输出指针非空可写。
#[no_mangle]
pub unsafe extern "C" fn ffc_parse_anidb_anime_xml(
    units: *const u16,
    len: usize,
    out_ptr: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    if out_ptr.is_null() || out_len.is_null() {
        return status::NULL_ARGUMENT;
    }
    let Some(input) = units_arg(units, len) else {
        return status::NULL_ARGUMENT;
    };
    guard(|| match dom::parse_dom(input) {
        Ok(tree) => {
            hand_over_bytes(tree, out_ptr, out_len);
            status::OK
        }
        Err(error) => {
            let (position, items): (usize, Vec<Vec<u16>>) = match &error {
                dom::DomError::Forbidden => (0, vec![Vec::new(), Vec::new(), Vec::new()]),
                dom::DomError::Parser { message, position } => (
                    *position,
                    vec![message.encode_utf16().collect(), Vec::new(), Vec::new()],
                ),
                dom::DomError::TagMismatch {
                    expected,
                    actual,
                    position,
                } => (
                    *position,
                    vec![Vec::new(), expected.clone(), actual.clone()],
                ),
                dom::DomError::TagUnexpected { actual, position } => {
                    (*position, vec![Vec::new(), Vec::new(), actual.clone()])
                }
                dom::DomError::TagMissing { expected, position } => {
                    (*position, vec![Vec::new(), expected.clone(), Vec::new()])
                }
            };
            let mut out = Vec::new();
            out.extend_from_slice(&error.kind().to_le_bytes());
            out.extend_from_slice(&(position as u32).to_le_bytes());
            out.extend_from_slice(&encode_string_list(&items));
            hand_over_bytes(out, out_ptr, out_len);
            status::BAD_INPUT
        }
    })
}
