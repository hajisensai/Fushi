//! 广告拦截核心的 C ABI（`fwc_adblock_*`）。
//!
//! 约定：
//! - 字符串一律 `(ptr, len)` 的 UTF-8，不要求 NUL 结尾（Dart 侧直接传 `utf8.encode` 的字节）；
//! - 返回字节缓冲的函数把长度写进 `*out_len`，调用方用 `fwc_bytes_free(ptr, len)` 释放；
//!   长度 0 / NULL 表示「没有」（例如 cosmetic 在白名单站点上）；
//! - 永不 panic 过 FFI 边界；
//! - 慢命令只有 `fwc_adblock_finish_sync`（可能要编译引擎），Dart 侧在后台 isolate 调；
//!   `fwc_adblock_check` 是微秒级、不分配、不回调的热路径，Dart 侧绑成 leaf 调用。

use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::PathBuf;

use serde_json::Value;

use super::{catalog, AdblockCore, CHECK_ERROR};
use crate::ffi_util::{
    bytes_in, clear_last_error, hand_out, panic_message, set_last_error, str_in,
};

unsafe fn core_ref<'a>(core: *const AdblockCore) -> Option<&'a AdblockCore> {
    core.as_ref()
}

unsafe fn json_out(v: Value, out_len: *mut usize) -> *mut u8 {
    hand_out(serde_json::to_vec(&v).unwrap_or_default(), out_len)
}

/// 包一层：NULL 句柄 / panic → 返回 NULL 并记错误；`out_len` 写 0。
unsafe fn guarded(
    core: *const AdblockCore,
    out_len: *mut usize,
    f: impl FnOnce(&AdblockCore) -> Vec<u8>,
) -> *mut u8 {
    if out_len.is_null() {
        return std::ptr::null_mut();
    }
    *out_len = 0;
    let Some(core) = core_ref(core) else {
        set_last_error("null adblock core handle".into());
        return std::ptr::null_mut();
    };
    match catch_unwind(AssertUnwindSafe(|| f(core))) {
        Ok(bytes) => hand_out(bytes, out_len),
        Err(p) => {
            set_last_error(panic_message(p));
            std::ptr::null_mut()
        }
    }
}

/// 打开数据目录 `dir`（不存在会在首次落盘时创建）。`want_content_blocking` 非 0：本平台需要
/// WebKit 内容拦截规则（iOS / macOS）。失败返回 NULL（原因见 `fwc_last_error`）。
///
/// # Safety
/// `dir` 指向 `dir_len` 个 UTF-8 字节。
#[no_mangle]
pub unsafe extern "C" fn fwc_adblock_open(
    dir: *const u8,
    dir_len: usize,
    want_content_blocking: u8,
) -> *mut AdblockCore {
    clear_last_error();
    let r = catch_unwind(AssertUnwindSafe(|| -> Result<AdblockCore, String> {
        let dir = str_in(dir, dir_len).ok_or("dir is not valid UTF-8")?;
        if dir.is_empty() {
            return Err("dir is empty".into());
        }
        Ok(AdblockCore::open(
            PathBuf::from(dir),
            want_content_blocking != 0,
        ))
    }));
    match r {
        Ok(Ok(core)) => Box::into_raw(Box::new(core)),
        Ok(Err(e)) => {
            set_last_error(e);
            std::ptr::null_mut()
        }
        Err(p) => {
            set_last_error(panic_message(p));
            std::ptr::null_mut()
        }
    }
}

/// 释放核心。NULL 为 no-op；之后句柄不可再用（Dart 侧须等在途的后台调用结束再关）。
///
/// # Safety
/// `core` 是 `fwc_adblock_open` 返回、尚未释放的句柄。
#[no_mangle]
pub unsafe extern "C" fn fwc_adblock_close(core: *mut AdblockCore) {
    if !core.is_null() {
        let _ = catch_unwind(AssertUnwindSafe(|| drop(Box::from_raw(core))));
    }
}

/// 内置列表目录 JSON：`[{"id","title","url","host","defaultEnabled"}]`（不需要句柄）。
///
/// # Safety
/// `out_len` 可写。
#[no_mangle]
pub unsafe extern "C" fn fwc_adblock_catalog(out_len: *mut usize) -> *mut u8 {
    if out_len.is_null() {
        return std::ptr::null_mut();
    }
    let v: Vec<Value> = catalog::CATALOG
        .iter()
        .map(|l| {
            serde_json::json!({
                "id": l.id,
                "title": l.title,
                "url": l.url,
                "host": super::allowlist::url_host(l.url),
                "defaultEnabled": l.default_enabled,
            })
        })
        .collect();
    json_out(Value::Array(v), out_len)
}

/// 状态快照 JSON（结构见 `AdblockCore::snapshot`）。
///
/// # Safety
/// `core` 有效，`out_len` 可写。
#[no_mangle]
pub unsafe extern "C" fn fwc_adblock_snapshot(
    core: *const AdblockCore,
    out_len: *mut usize,
) -> *mut u8 {
    guarded(core, out_len, |c| {
        serde_json::to_vec(&c.snapshot()).unwrap_or_default()
    })
}

/// 总开关。返回新快照。
///
/// # Safety
/// 同 `fwc_adblock_snapshot`。
#[no_mangle]
pub unsafe extern "C" fn fwc_adblock_set_enabled(
    core: *const AdblockCore,
    enabled: u8,
    out_len: *mut usize,
) -> *mut u8 {
    guarded(core, out_len, |c| {
        serde_json::to_vec(&c.set_enabled(enabled != 0)).unwrap_or_default()
    })
}

/// 订阅 / 取消订阅一份目录里的列表。返回新快照（随后调用方发起同步）。
///
/// # Safety
/// `id` 指向 `id_len` 个 UTF-8 字节；其余同上。
#[no_mangle]
pub unsafe extern "C" fn fwc_adblock_set_list_enabled(
    core: *const AdblockCore,
    id: *const u8,
    id_len: usize,
    enabled: u8,
    out_len: *mut usize,
) -> *mut u8 {
    let id = str_in(id, id_len).unwrap_or("").to_string();
    guarded(core, out_len, |c| {
        serde_json::to_vec(&c.set_list_enabled(&id, enabled != 0)).unwrap_or_default()
    })
}

/// 白名单原文（逗号 / 空白分隔的域名，含子域名）。返回新快照。
///
/// # Safety
/// `raw` 指向 `raw_len` 个 UTF-8 字节；其余同上。
#[no_mangle]
pub unsafe extern "C" fn fwc_adblock_set_allowlist(
    core: *const AdblockCore,
    raw: *const u8,
    raw_len: usize,
    out_len: *mut usize,
) -> *mut u8 {
    let raw = String::from_utf8_lossy(bytes_in(raw, raw_len)).into_owned();
    guarded(core, out_len, |c| {
        serde_json::to_vec(&c.set_allowlist(&raw)).unwrap_or_default()
    })
}

/// 开始同步，返回取数计划 `{"run":b,"fetch":[{"id","url","etag","lastModified"}]}`。
///
/// # Safety
/// 同 `fwc_adblock_snapshot`。
#[no_mangle]
pub unsafe extern "C" fn fwc_adblock_begin_sync(
    core: *const AdblockCore,
    force: u8,
    out_len: *mut usize,
) -> *mut u8 {
    guarded(core, out_len, |c| {
        serde_json::to_vec(&c.begin_sync(force != 0)).unwrap_or_default()
    })
}

/// 交回一份列表的联网结果：HTTP `status`（联网失败传 0）+ 原始响应字节 + 响应头里的
/// ETag / Last-Modified + 失败原因。返回 0 成功，-1 失败（原因见 `fwc_last_error`）。
///
/// # Safety
/// 各 `(ptr, len)` 指向对应长度的可读字节（可为 NULL / 0）；`core` 有效。
#[no_mangle]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn fwc_adblock_ingest(
    core: *const AdblockCore,
    id: *const u8,
    id_len: usize,
    status: i32,
    body: *const u8,
    body_len: usize,
    etag: *const u8,
    etag_len: usize,
    last_modified: *const u8,
    last_modified_len: usize,
    error: *const u8,
    error_len: usize,
) -> i32 {
    clear_last_error();
    let Some(core) = core_ref(core) else {
        set_last_error("null adblock core handle".into());
        return -1;
    };
    let r = catch_unwind(AssertUnwindSafe(|| {
        let id = str_in(id, id_len).ok_or("id is not valid UTF-8")?;
        let opt = |p, l| str_in(p, l).filter(|s: &&str| !s.is_empty());
        core.ingest(
            id,
            status,
            bytes_in(body, body_len),
            opt(etag, etag_len),
            opt(last_modified, last_modified_len),
            opt(error, error_len),
        )
    }));
    match r {
        Ok(Ok(())) => 0,
        Ok(Err(e)) => {
            set_last_error(e);
            -1
        }
        Err(p) => {
            set_last_error(panic_message(p));
            -1
        }
    }
}

/// 收尾同步（可能编译引擎，慢——后台 isolate 调）。返回新快照。
///
/// # Safety
/// 同 `fwc_adblock_snapshot`。
#[no_mangle]
pub unsafe extern "C" fn fwc_adblock_finish_sync(
    core: *const AdblockCore,
    out_len: *mut usize,
) -> *mut u8 {
    guarded(core, out_len, |c| {
        serde_json::to_vec(&c.finish_sync()).unwrap_or_default()
    })
}

/// 热路径：判一个子资源请求。返回 0 放行 / 1 拦截 / 3 被例外抵消 / -1 参数无效（按放行）。
/// 总开关、白名单（按 `page_url` 的主机名）、引擎就绪与否都在这里判。微秒级、不分配结果、
/// 不回调 Dart：可作 leaf 调用。
///
/// # Safety
/// 各 `(ptr, len)` 指向对应长度的可读 UTF-8 字节（`source` / `page` 可为空）。
#[no_mangle]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn fwc_adblock_check(
    core: *const AdblockCore,
    url: *const u8,
    url_len: usize,
    source: *const u8,
    source_len: usize,
    page: *const u8,
    page_len: usize,
    request_type: u8,
) -> i32 {
    catch_unwind(AssertUnwindSafe(|| {
        let Some(core) = core_ref(core) else {
            return CHECK_ERROR;
        };
        let (Some(url), Some(source), Some(page)) = (
            str_in(url, url_len),
            str_in(source, source_len),
            str_in(page, page_len),
        ) else {
            return CHECK_ERROR;
        };
        core.check(url, source, page, request_type)
    }))
    .unwrap_or(CHECK_ERROR)
}

/// 页面 cosmetic 载荷（JSON，直接交给页内 JS）；未激活 / 白名单时长度 0。
///
/// # Safety
/// 各 `(ptr, len)` 指向对应长度的可读 UTF-8 字节；`out_len` 可写。
#[no_mangle]
pub unsafe extern "C" fn fwc_adblock_cosmetic(
    core: *const AdblockCore,
    href: *const u8,
    href_len: usize,
    page: *const u8,
    page_len: usize,
    out_len: *mut usize,
) -> *mut u8 {
    let href = str_in(href, href_len).unwrap_or("").to_string();
    let page = str_in(page, page_len).unwrap_or("").to_string();
    guarded(core, out_len, |c| {
        if href.is_empty() {
            Vec::new()
        } else {
            c.cosmetic(&href, &page)
        }
    })
}

/// 通用 hide 选择器载荷（JSON 数组，直接交给页内 JS）。`classes` / `ids` 是换行分隔的原文。
///
/// # Safety
/// 同 `fwc_adblock_cosmetic`。
#[no_mangle]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn fwc_adblock_generic(
    core: *const AdblockCore,
    href: *const u8,
    href_len: usize,
    page: *const u8,
    page_len: usize,
    classes: *const u8,
    classes_len: usize,
    ids: *const u8,
    ids_len: usize,
    out_len: *mut usize,
) -> *mut u8 {
    let href = str_in(href, href_len).unwrap_or("").to_string();
    let page = str_in(page, page_len).unwrap_or("").to_string();
    let classes = str_in(classes, classes_len).unwrap_or("").to_string();
    let ids = str_in(ids, ids_len).unwrap_or("").to_string();
    guarded(core, out_len, |c| {
        if href.is_empty() {
            Vec::new()
        } else {
            c.generic(&href, &page, &classes, &ids)
        }
    })
}

/// 当前引擎的 WebKit 内容拦截规则 JSON（已筛选、已截断；只在 open 时要了的平台有）。
///
/// # Safety
/// 同 `fwc_adblock_snapshot`。
#[no_mangle]
pub unsafe extern "C" fn fwc_adblock_content_blockers(
    core: *const AdblockCore,
    out_len: *mut usize,
) -> *mut u8 {
    guarded(core, out_len, |c| c.content_blockers())
}
